//! Process-lifetime memo of a board's reduced copper fill, PER FILL.
//!
//! Every reporting DRC pass begins by rastering the board twice over: each
//! net's declared plane/pour on each carrying layer plus each hand-drawn zone,
//! reduced to the kept fill components the Gerber cuts
//! (`drc_compose.filledTopology`), and then the connectivity layer's own
//! whole-board zone raster (`net_open.zoneFills`). Those two rasters ARE the
//! cost of the reporting seam, and both were paid from scratch on EVERY call —
//! the DRC endpoint, the page blob, the `?derived=1` payload, `describe` and
//! the fab gate each re-poured a board nobody had touched, and an editor
//! reconcile paid it several times per edit.
//!
//! Measured with `netlisp bench-page --reps 3` (2026-08-26, Debug, same
//! machine and same boards, memo forced off vs on): barracuda's reporting DRC
//! 3480 ms → 758 ms, barracuda-base 8140 ms → 542 ms, cyclops-interposer
//! 750 ms → 6 ms, with byte-identical DRC counts on every board in the corpus.
//! What is left is rule EVALUATION over the fill (`drc.checkWithZones` and the
//! return-path rule), which this does not touch.
//!
//! ## Two keys, because a board key alone only helps a board nobody touched
//!
//! The whole-board key below is a 128-bit fingerprint of the placement, the
//! routed copper and the user zones. It is exact, and it is all-or-nothing: any
//! copper edit mints a new board key, and the next reporting DRC re-poured every
//! fill on the board — 2.5–3 s of a barracuda-class board for moving one track.
//! An editor session is a sequence of edits, so that was the common case, not
//! the rare one.
//!
//! So each FILL is also memoised on its own content key (`pour.fillKey`), and a
//! board rebuilt for a new board key borrows every fill whose own inputs did not
//! change. What a fill's key covers is decided by the raster itself — `pour`
//! computes it from the same traversal that stamps the obstacles, so it cannot
//! omit an input the raster read — and the reuse that falls out is:
//!
//!   * an INNER plane stamps no track, arc or RF path at all, so no track edit
//!     anywhere on the board can change it;
//!   * an OUTER face keys only its OWN layer's tracks/arcs/paths;
//!   * a hand-drawn zone keys only the features whose stamp window reaches its
//!     clip box, so an edit elsewhere leaves it borrowable on its own layer;
//!   * two callers that pour the identical fill share ONE entry — which is not
//!     hypothetical: the topology pass and the connectivity pass each rastered
//!     every user zone, with identical specs, and now raster it once.
//!
//! A borrowed fill is bit-identical to a cold one, because the key is a function
//! of everything the pour reads. That claim is what
//! `drc_compose`'s edit-sequence tests exist to hold.
//!
//! ## Ownership
//!
//! Entries are pinned to the page allocator because every caller's allocator is
//! a per-request arena that outlives nothing. A hit therefore BORROWS — a
//! whole-board fill is tens of megabytes of label grid, so copying it back per
//! call would hand most of the saving straight back — and the borrow is
//! refcounted: eviction unlinks an entry and the last `release` frees it. A FILL
//! node is refcounted the same way, and its holders are both the board entries
//! that link it and the passes currently reading it, so a fill several board
//! generations share is stored once and freed when the last of them is gone.
//!
//! Retention is not a memory cost in practice: with the four largest boards in
//! the corpus held at once, peak RSS MEASURED LOWER than without the memo
//! (523 MB vs 618 MB), because what it retains is smaller than the per-request
//! arenas the repeated pours were allocating and freeing. Sharing fills between
//! generations lowers it further: consecutive board states differ in a handful
//! of fills, so a second generation costs its deltas rather than another copy.
//!
//! The borrow's rule, which every DRC layer beneath `drc_compose` already
//! obeys: NOTHING in a returned verdict may point into a fill. Violations carry
//! coordinates and indices, and their two strings (`Parties.pad_a`/`pad_b`) are
//! footprint pad numbers owned by the placement; the connectivity statuses name
//! `placement.nets`. A future rule that wants to report a fill CONTOUR must
//! copy it into the caller's arena, not hand out the borrowed one.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const content_key = @import("content_key.zig");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const pour = @import("pour.zig");
const router = @import("router.zig");

/// Two independent 64-bit hashes of every input the fill is derived from. Two
/// rather than one because a memo that answers with the WRONG board's copper is
/// a silently wrong DRC verdict, and 64 bits is not enough margin against that
/// failure mode — the route-space cache keys the same way for the same reason.
pub const Key = content_key.Key;

/// One board's whole reduced fill: the topology zones (one node per kept fill
/// component, with its holes), the per-net carrying-layer rasters whose labels
/// the connectivity layer samples, and that layer's own user-zone rasters.
pub const Fills = struct {
    zones: []const drc.TopologyZone = &.{},
    plane_fills: []const pour.NetFills = &.{},
    /// The user-zone rasters the CONNECTIVITY layer samples
    /// (`net_open.zoneFills`). Historically a different raster from the topology
    /// zones above; it is in fact the same fill of the same spec, so the per-fill
    /// memo now hands both consumers one entry.
    zone_fills: []const pour.Fill = &.{},
};

/// Boards retained at once. A design under edit mints a fresh key per change,
/// so this is a window over recent board states rather than a per-design table:
/// four leaves room for the board being edited plus the surfaces that trail it
/// by an edit (the page blob, the derived payload, describe).
const max_boards: usize = 4;
/// Byte ceiling over every retained fill together. One fill's label grid is
/// capped at `pour`'s three million cells (12 MB) and a dense board pours a
/// few dozen of them, so a barracuda-class board's fills are a few hundred
/// megabytes — which is exactly why generations SHARE their unchanged fills
/// rather than each holding a copy.
const max_fill_bytes: usize = 384 * 1024 * 1024;

/// What a retained thing — a board entry or one fill — needs to be freed at the
/// right moment: its size against the ceiling, who is still reading it, and
/// whether the store has already given it up. Shared between the two because
/// the rule is the same for both: eviction UNLINKS, and the last reader FREES,
/// so a pass reading a raster is never overtaken by a newer board.
const Retention = struct {
    bytes: usize = 0,
    /// Live claims: for a fill, the board entries linking it plus the passes
    /// reading it; for a board, the passes reading it.
    refs: usize = 0,
    /// Unlinked from the store already; the last release frees it.
    dropped: bool = false,
};

/// One memoised FILL: the unit of reuse across a board edit. Owned by the
/// store's fill table and referenced by every board entry that contains it and
/// every pass currently reading it.
pub const FillNode = struct {
    key: Key,
    arena: std.heap.ArenaAllocator,
    fill: pour.Fill,
    held: Retention,
};

/// What the store may retain. Bundled so a test can bound one store without
/// touching the process-wide one, and so both bounds are stated together: the
/// board count is a window over recent board STATES, the byte ceiling is the
/// real memory limit, and eviction reads them in that order.
pub const Limits = struct {
    boards: usize = max_boards,
    bytes: usize = max_fill_bytes,
};

/// What the store did since the process started: boards answered whole, and
/// fills borrowed versus poured.
pub const Tally = struct {
    board_hits: usize = 0,
    board_misses: usize = 0,
    fill_hits: usize = 0,
    fill_misses: usize = 0,
};

/// One memoised board, its light metadata, the fills it is made of, and the
/// readers currently borrowing it.
pub const Entry = struct {
    store: *Store,
    key: Key,
    /// Net names, layer specs and the topology-zone headers. The RASTERS are
    /// not here — they belong to `nodes`, so two board generations that differ
    /// by one track hold one copy of everything the edit did not touch.
    arena: std.heap.ArenaAllocator,
    nodes: []*FillNode,
    fills: Fills,
    held: Retention,
};

/// A live borrow of a memoised fill. The caller reads `fills` for as long as it
/// holds this and `release`s once its DRC pass is done. Either a whole-board
/// entry (the board was already retained) or the per-fill session that just
/// built one (the board was not, and its fills are borrowed one by one).
pub const Held = struct {
    entry: ?*Entry = null,
    session: ?*Session = null,
    /// The fills this pass built in its own arena, whose rasters point into the
    /// session's nodes. Unused when `entry` answers.
    own: Fills = .{},

    /// The borrowed fill, or the empty fill when nothing is held.
    pub fn fills(self: Held) Fills {
        if (self.entry) |entry| return entry.fills;
        return self.own;
    }

    /// True when something is actually held — a retained board or a live set of
    /// fill borrows.
    pub fn active(self: Held) bool {
        return self.entry != null or self.session != null;
    }

    /// End the borrow. Idempotent, so a `defer` beside the acquisition covers
    /// every path out of the DRC pass.
    pub fn release(self: *Held) void {
        if (self.entry) |entry| {
            self.entry = null;
            entry.store.releaseEntry(entry);
        }
        if (self.session) |session| {
            self.session = null;
            session.release();
        }
    }
};

/// The fill borrows one DRC pass is holding. Handed to `pour` as a `FillMemo`,
/// which knows nothing about lifetimes: every fill `pour` takes from the store
/// is refcounted here and released together when the pass ends.
pub const Session = struct {
    store: *Store,
    nodes: std.ArrayList(*FillNode) = .empty,
    /// False once any fill in this pass could NOT be retained (an allocation
    /// failure, or a board over the byte ceiling). Such a fill lives in the
    /// caller's arena, so the board entry built from it must not be retained —
    /// it would outlive the memory it points at.
    all_backed: bool = true,

    /// The `pour` seam this session answers. Borrow it for one pass only.
    pub fn memo(self: *Session) pour.FillMemo {
        return .{ .ctx = @ptrCast(self), .get = sessionGet, .put = sessionPut };
    }

    /// Drop every borrow and free the session.
    pub fn release(self: *Session) void {
        const store = self.store;
        for (self.nodes.items) |node| store.releaseFill(node);
        self.nodes.deinit(store.backing);
        store.backing.destroy(self);
    }

    fn hold(self: *Session, node: *FillNode) void {
        self.nodes.append(self.store.backing, node) catch {
            // The borrow cannot be tracked, so it cannot be released; give it
            // back now and let this pass pour the fill itself.
            self.store.releaseFill(node);
            self.all_backed = false;
        };
    }
};

fn sessionGet(ctx: *anyopaque, k: Key) ?pour.Fill {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const node = self.store.acquireFill(k) orelse return null;
    const before = self.nodes.items.len;
    self.hold(node);
    // `hold` failing gave the borrow straight back, so the fill is no longer
    // ours to hand out.
    if (self.nodes.items.len == before) return null;
    return node.fill;
}

/// Retain `fill` and hand back THE RETAINED COPY. Returning the store's copy
/// rather than the caller's is what lets a board entry reference the raster
/// afterwards: the caller's own copy dies with its request arena, so an entry
/// built from it would point at freed memory the moment the request ended.
fn sessionPut(ctx: *anyopaque, k: Key, fill: pour.Fill) ?pour.Fill {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const node = self.store.putFill(k, fill) orelse {
        self.all_backed = false;
        return null;
    };
    const before = self.nodes.items.len;
    self.hold(node);
    if (self.nodes.items.len == before) return null;
    return node.fill;
}

/// A bounded set of memoised board fills, least-recently-used first. One
/// process-wide instance backs the DRC seam (`acquire`/`put` below); tests own
/// their own so they can bound it and watch eviction without touching that one.
pub const Store = struct {
    mutex: infra_fs.Mutex = .{},
    /// Long-lived backing for the entries — deliberately NOT any caller's
    /// allocator, every one of which is an arena freed with its request.
    backing: std.mem.Allocator = std.heap.page_allocator,
    /// Retained boards, oldest borrow first: the LRU order eviction reads.
    entries: std.ArrayList(*Entry) = .empty,
    /// Retained fills, oldest borrow first. Deliberately a flat list rather
    /// than a hash map: it is dozens of entries per board, the lookup is two
    /// integer compares, and a list has ONE deterministic iteration order —
    /// which eviction, and therefore what a later pass finds, depends on.
    fills: std.ArrayList(*FillNode) = .empty,
    bytes: usize = 0,
    limits: Limits = .{},
    /// What the memo actually did, for the one question a memo has to be able
    /// to answer: how much of this board did it reuse? Counted rather than
    /// inferred, because a fill key that quietly stops matching looks exactly
    /// like a memo that is working (correct answers, full price) — `drc-dump`
    /// prints these so a regression in reuse is visible as a number.
    tally: Tally = .{},

    /// Borrow the memoised fill for `k`, or an empty hold on a miss.
    pub fn acquire(self: *Store, k: Key) Held {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items, 0..) |entry, i| {
            if (!Key.eql(entry.key, k)) continue;
            entry.held.refs += 1;
            self.tally.board_hits += 1;
            // Newest at the back: position IS the recency order eviction reads.
            self.entries.appendAssumeCapacity(self.entries.orderedRemove(i));
            return .{ .entry = entry };
        }
        self.tally.board_misses += 1;
        return .{};
    }

    /// Open a per-fill borrow session for one DRC pass. Null when the session
    /// itself cannot be allocated, which the caller answers by pouring
    /// unmemoised — a memo failure is never a DRC failure.
    pub fn beginSession(self: *Store) ?*Session {
        const session = self.backing.create(Session) catch return null;
        session.* = .{ .store = self };
        return session;
    }

    /// Borrow one memoised FILL, or null on a miss.
    pub fn acquireFill(self: *Store, k: Key) ?*FillNode {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.fills.items, 0..) |node, i| {
            if (!Key.eql(node.key, k)) continue;
            node.held.refs += 1;
            self.tally.fill_hits += 1;
            self.fills.appendAssumeCapacity(self.fills.orderedRemove(i));
            return node;
        }
        self.tally.fill_misses += 1;
        return null;
    }

    /// Retain one freshly poured fill, deep-copied out of the caller's arena,
    /// and hand back a borrow of the retained copy. Null when it cannot be
    /// retained; the caller then keeps its own fill and stops claiming the pass
    /// is memoisable.
    pub fn putFill(self: *Store, k: Key, fill: pour.Fill) ?*FillNode {
        // Built OUTSIDE the lock: the copy walks the whole label grid, and
        // holding the mutex across it would serialize DRC passes on unrelated
        // boards behind one board's copy.
        const node = self.buildFill(k, fill) orelse return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.fills.items) |existing| {
            // Another pass published this fill first. Take ITS copy, so the
            // whole process converges on one raster per content key.
            if (!Key.eql(existing.key, k)) continue;
            destroyFill(node);
            existing.held.refs += 1;
            return existing;
        }
        self.fills.append(self.backing, node) catch {
            destroyFill(node);
            return null;
        };
        self.bytes += node.held.bytes;
        self.trim();
        return node;
    }

    /// Retain a freshly built board. A memo failure is never a DRC failure: an
    /// allocation error, an oversized board, or a key another thread published
    /// first all leave the caller's own freshly poured fill standing.
    ///
    /// `session` is the pass's per-fill borrows. When it holds every raster in
    /// `fills`, the entry stores only the light metadata and REFERENCES those
    /// rasters, which is what makes a generation cost its deltas. A null (or
    /// incomplete) session means the rasters live in the caller's arena, so the
    /// entry deep-copies them exactly as it always did.
    pub fn put(self: *Store, k: Key, fills: Fills, session: ?*Session) void {
        const shared = if (session) |s| s.all_backed else false;
        const entry = self.build(k, fills, if (shared) session else null) orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |existing| {
            if (Key.eql(existing.key, k)) return destroyEntry(entry);
        }
        self.entries.append(self.backing, entry) catch return destroyEntry(entry);
        self.bytes += entry.held.bytes;
        self.trim();
    }

    /// Release every retained fill. Entries still borrowed are unlinked and
    /// freed by their last `release`, so a store may only be deinitialized once
    /// every pass reading it has ended.
    pub fn deinit(self: *Store) void {
        self.mutex.lock();
        for (self.entries.items) |entry| unlink(entry);
        self.entries.deinit(self.backing);
        self.entries = .empty;
        for (self.fills.items) |node| unlinkFill(node);
        self.fills.deinit(self.backing);
        self.fills = .empty;
        self.bytes = 0;
        self.mutex.unlock();
    }

    fn buildFill(self: *Store, k: Key, fill: pour.Fill) ?*FillNode {
        const node = self.backing.create(FillNode) catch return null;
        node.* = .{
            .key = k,
            .arena = std.heap.ArenaAllocator.init(self.backing),
            .fill = .{ .frame = fill.frame, .labels = &.{}, .n_comp = 0, .contours = &.{}, .holes = &.{}, .coarsened = fill.coarsened },
            .held = .{ .refs = 1 },
        };
        node.fill = dupeGrid(node.arena.allocator(), fill) catch {
            destroyFill(node);
            return null;
        };
        node.held.bytes = node.arena.queryCapacity();
        if (node.held.bytes > self.limits.bytes) {
            destroyFill(node);
            return null;
        }
        return node;
    }

    fn build(self: *Store, k: Key, fills: Fills, session: ?*Session) ?*Entry {
        const entry = self.backing.create(Entry) catch return null;
        entry.* = .{
            .store = self,
            .key = k,
            .arena = std.heap.ArenaAllocator.init(self.backing),
            .nodes = &.{},
            .fills = .{},
            .held = .{},
        };
        const alloc = entry.arena.allocator();
        entry.fills = (if (session != null) lightFills(alloc, fills) else dupeFills(alloc, fills)) catch {
            destroyEntry(entry);
            return null;
        };
        if (session) |s| {
            entry.nodes = distinctNodes(alloc, s.nodes.items) catch {
                destroyEntry(entry);
                return null;
            };
        }
        entry.held.bytes = entry.arena.queryCapacity();
        if (entry.held.bytes > self.limits.bytes) {
            destroyEntry(entry);
            return null;
        }
        // The entry's own claim on every raster it points at, taken LAST and
        // while the session still holds one, so no window exists where a raster
        // is reachable through the entry and owned by nobody, and no failure
        // path above has to give a claim back.
        self.mutex.lock();
        for (entry.nodes) |node| node.held.refs += 1;
        self.mutex.unlock();
        return entry;
    }

    /// Evict least-recently-borrowed boards and unreferenced fills until the
    /// store is inside both bounds. Called with the mutex held.
    fn trim(self: *Store) void {
        while (self.entries.items.len > self.limits.boards) self.evictOldestBoard();
        if (self.bytes <= self.limits.bytes) return;
        self.sweepFills();
        // A fill no board references is the cheapest thing to give up, so it
        // goes first; only when that is not enough does a whole board state go,
        // which is what releases the next batch of fills.
        while (self.bytes > self.limits.bytes and self.entries.items.len > 0) {
            self.evictOldestBoard();
            self.sweepFills();
        }
    }

    /// Drop retained fills nothing references, oldest borrow first, until the
    /// store is inside its byte ceiling. Called with the mutex held.
    fn sweepFills(self: *Store) void {
        var i: usize = 0;
        while (self.bytes > self.limits.bytes and i < self.fills.items.len) {
            const node = self.fills.items[i];
            if (node.held.refs > 0) {
                i += 1;
                continue;
            }
            _ = self.fills.orderedRemove(i);
            self.bytes -= node.held.bytes;
            unlinkFill(node);
        }
    }

    fn evictOldestBoard(self: *Store) void {
        self.evictBoard(0);
    }

    fn releaseEntry(self: *Store, entry: *Entry) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        entry.held.refs -= 1;
        if (entry.held.dropped and entry.held.refs == 0) destroyEntry(entry);
    }

    fn releaseFill(self: *Store, node: *FillNode) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        node.held.refs -= 1;
        if (node.held.dropped and node.held.refs == 0) destroyFill(node);
    }

    fn evictBoard(self: *Store, i: usize) void {
        const evicted = self.entries.orderedRemove(i);
        self.bytes -= evicted.held.bytes;
        unlink(evicted);
    }
};

/// Drop the store's own claim on an unlinked entry: free it now when nothing
/// reads it, otherwise leave it to the last reader's `release`. Called with the
/// mutex held.
fn unlink(entry: *Entry) void {
    if (entry.held.refs == 0) return destroyEntry(entry);
    entry.held.dropped = true;
}

/// Free an entry and give back its claim on every raster it referenced. Called
/// with the mutex held (or before the entry is reachable).
fn destroyEntry(entry: *Entry) void {
    for (entry.nodes) |node| {
        node.held.refs -= 1;
        if (node.held.dropped and node.held.refs == 0) destroyFill(node);
    }
    const backing = entry.arena.child_allocator;
    entry.arena.deinit();
    backing.destroy(entry);
}

fn unlinkFill(node: *FillNode) void {
    if (node.held.refs == 0) return destroyFill(node);
    node.held.dropped = true;
}

fn destroyFill(node: *FillNode) void {
    const backing = node.arena.child_allocator;
    node.arena.deinit();
    backing.destroy(node);
}

/// The pass's borrowed rasters, each named once — a session holds a borrow per
/// USE, and one fill is legitimately used twice (the topology pass and the
/// connectivity pass ask for the same user zone).
fn distinctNodes(a: std.mem.Allocator, used: []const *FillNode) std.mem.Allocator.Error![]*FillNode {
    var out: std.ArrayList(*FillNode) = .empty;
    for (used) |node| {
        var seen = false;
        for (out.items) |kept| {
            if (kept == node) {
                seen = true;
                break;
            }
        }
        if (!seen) try out.append(a, node);
    }
    return out.toOwnedSlice(a);
}

/// The one store the DRC seam reads. Process-wide rather than owned by the web
/// server because the surfaces that pour the same board include several that
/// never see a `Server` — the fab gate, `describe`, `bench-page`, the route
/// CLIs — and a content key makes sharing between them exact.
var process_store: Store = .{};

/// Borrow the process-wide memo of `k`. Release the hold when the DRC pass
/// reading it ends.
pub fn acquire(k: Key) Held {
    return process_store.acquire(k);
}

/// Retain a freshly poured fill in the process-wide memo.
pub fn put(k: Key, fills: Fills, session: ?*Session) void {
    process_store.put(k, fills, session);
}

/// Open a per-fill borrow session against the process-wide store.
pub fn beginSession() ?*Session {
    return process_store.beginSession();
}

/// What the process-wide memo has done so far, and what it is holding. Read by
/// `drc-dump` so a change in REUSE is reportable, not just a change in time.
pub fn stats() struct { tally: Tally, boards: usize, fills: usize, bytes: usize } {
    process_store.mutex.lock();
    defer process_store.mutex.unlock();
    return .{
        .tally = process_store.tally,
        .boards = process_store.entries.items.len,
        .fills = process_store.fills.items.len,
        .bytes = process_store.bytes,
    };
}

// ── Deep copy out of the caller's arena ───────────────────────────────────
// Every slice AND every string is duplicated: the source fill was poured into
// the request arena that computed it, and the net names inside it point into
// the evaluator's design buffers. A retained entry must outlive both.

fn dupeFills(a: std.mem.Allocator, src: Fills) std.mem.Allocator.Error!Fills {
    const zones = try a.alloc(drc.TopologyZone, src.zones.len);
    for (src.zones, zones) |s, *d| {
        d.* = s;
        d.net = try a.dupe(u8, s.net);
        d.poly = try a.dupe([2]f64, s.poly);
        d.holes = try dupePolys(a, s.holes);
    }
    const plane_fills = try a.alloc(pour.NetFills, src.plane_fills.len);
    for (src.plane_fills, plane_fills) |s, *d| d.* = .{
        .net_name = try a.dupe(u8, s.net_name),
        .layers = try dupeLayers(a, s.layers),
        .fills = try dupeGrids(a, s.fills),
    };
    return .{ .zones = zones, .plane_fills = plane_fills, .zone_fills = try dupeGrids(a, src.zone_fills) };
}

/// The same copy WITHOUT the rasters: every `pour.Fill` and every traced
/// contour already belongs to a retained fill node this entry references, so
/// duplicating them is what the per-fill memo exists to avoid. Only the light
/// metadata — names, layer specs, the topology-zone headers — is copied, and
/// the polygons those headers point at stay owned by the nodes.
fn lightFills(a: std.mem.Allocator, src: Fills) std.mem.Allocator.Error!Fills {
    const zones = try a.alloc(drc.TopologyZone, src.zones.len);
    for (src.zones, zones) |s, *d| {
        d.* = s;
        d.net = try a.dupe(u8, s.net);
    }
    const plane_fills = try a.alloc(pour.NetFills, src.plane_fills.len);
    for (src.plane_fills, plane_fills) |s, *d| d.* = .{
        .net_name = try a.dupe(u8, s.net_name),
        .layers = try dupeLayers(a, s.layers),
        .fills = try a.dupe(pour.Fill, s.fills),
    };
    return .{ .zones = zones, .plane_fills = plane_fills, .zone_fills = try a.dupe(pour.Fill, src.zone_fills) };
}

fn dupePolys(a: std.mem.Allocator, polys: []const []const [2]f64) std.mem.Allocator.Error![]const []const [2]f64 {
    const out = try a.alloc([]const [2]f64, polys.len);
    for (polys, out) |s, *d| d.* = try a.dupe([2]f64, s);
    return out;
}

fn dupeLayers(a: std.mem.Allocator, specs: []const pour.LayerSpec) std.mem.Allocator.Error![]const pour.LayerSpec {
    const out = try a.alloc(pour.LayerSpec, specs.len);
    for (specs, out) |s, *d| {
        d.* = s;
        d.net = switch (s.net) {
            .named => |name| .{ .named = try a.dupe(u8, name) },
            .ground => .ground,
        };
        d.clip = try a.dupe([2]f64, s.clip);
        d.higher = try dupePolys(a, s.higher);
    }
    return out;
}

fn dupeGrid(a: std.mem.Allocator, src: pour.Fill) std.mem.Allocator.Error!pour.Fill {
    var out = src;
    out.labels = try a.dupe(i32, src.labels);
    out.contours = try dupePolys(a, src.contours);
    const holes = try a.alloc([]const []const [2]f64, src.holes.len);
    for (src.holes, holes) |src_holes, *dst_holes| dst_holes.* = try dupePolys(a, src_holes);
    out.holes = holes;
    return out;
}

fn dupeGrids(a: std.mem.Allocator, fills: []const pour.Fill) std.mem.Allocator.Error![]const pour.Fill {
    const out = try a.alloc(pour.Fill, fills.len);
    for (fills, out) |s, *d| d.* = try dupeGrid(a, s);
    return out;
}

// ── Fingerprint ───────────────────────────────────────────────────────────

/// The board fingerprint the memo is keyed on: every field of the placement
/// except the three that record how the arrangement was ARRIVED at, plus the
/// routed copper and the user zones.
///
/// The walk is reflective on purpose. A hand-picked field list is exactly how a
/// memo goes stale — someone adds a rule that changes what a pour clears, and
/// the key never notices — so every field of every input is folded in unless it
/// is named below, and a new one is covered the day it is declared.
pub fn key(
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const pour.UserZone,
) Key {
    var fp: content_key.Fingerprint = .{};
    const info = @typeInfo(optimizer.Placement).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        if (comptime !skipped(name)) fp.put(Field, @field(placement, name));
    }
    fp.put(router.RouteResult, routed);
    fp.put([]const pour.UserZone, zones);
    return fp.final();
}

/// The only `Placement` fields left out of the fingerprint, and why each one is
/// safe to leave out:
///
///   `score`, `breakdown`, `generated` describe the SEARCH, not the board — the
///   objective, its decomposition, and whether the optimizer ran or the poses
///   came back from the layout cache. Two surfaces that resolve one saved board
///   legitimately disagree on all three while its copper is identical, so
///   folding them in would miss on every such pair and memoise nothing.
///
///   `pin_roles` is a per-component pad→class map the ROUTER and the pad-annular
///   rule read; no pour or fill consults it (grep `pin_roles` under
///   `placement/`: `drc.zig` only). It is also a `StringHashMap`, whose bucket
///   order is not a stable fingerprint of its contents.
///
/// Everything else is folded in, including every field added after this was
/// written — which is the point of walking the type rather than a list. A field
/// the walk cannot fingerprint (a hash map, a raw many-pointer) fails the BUILD
/// rather than going quietly unkeyed, so the next such field is a decision
/// somebody makes here on purpose.
fn skipped(comptime name: []const u8) bool {
    const out = [_][]const u8{ "score", "breakdown", "generated", "pin_roles" };
    for (out) |field| {
        if (std.mem.eql(u8, name, field)) return true;
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Two pads on one net, poses given, sharing one footprint. Enough of a board
/// for the fingerprint to have something to disagree about.
fn twoPartBoard(parts: []optimizer.Part) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = false,
    };
}

const empty_route: router.RouteResult = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

// spec: placement/fill-cache - one board fingerprints identically from two independently built copies and differently after any change to its copper
test "the board fingerprint follows content, not identity" {
    const geometry = @import("geometry.zig");
    const pad_a = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pad_b = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts_a = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad_a, .fallback = false, .x = 3, .y = 0 },
    };
    // Separate arrays, separate strings, identical board.
    var parts_b = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad_b, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad_b, .fallback = false, .x = 3, .y = 0 },
    };
    const one = key(twoPartBoard(&parts_a), empty_route, &.{});
    try testing.expectEqual(one, key(twoPartBoard(&parts_b), empty_route, &.{}));

    // A micron of movement is a different board.
    parts_b[1].x = 3.000001;
    try testing.expect(!std.meta.eql(one, key(twoPartBoard(&parts_b), empty_route, &.{})));
    parts_b[1].x = 3;
    try testing.expectEqual(one, key(twoPartBoard(&parts_b), empty_route, &.{}));

    // …and so is a track, a via or a drawn zone that was not there before.
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const routed: router.RouteResult = .{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    try testing.expect(!std.meta.eql(one, key(twoPartBoard(&parts_a), routed, &.{})));
    const square = [_][2]f64{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 3 }, .{ 0, 3 } };
    const zones = [_]pour.UserZone{.{ .net = "GND", .layer = 0, .poly = &square }};
    try testing.expect(!std.meta.eql(one, key(twoPartBoard(&parts_a), empty_route, &zones)));
}

// spec: placement/fill-cache - the fingerprint ignores the objective score and whether the optimizer ran, so one saved board shares an entry across the surfaces that resolve it
test "the board fingerprint ignores how the arrangement was arrived at" {
    const geometry = @import("geometry.zig");
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
    };
    var solved = twoPartBoard(&parts);
    const restored_key = key(solved, empty_route, &.{});
    // The same board, reported by the surface that just re-solved it.
    solved.generated = true;
    solved.score = .{ .hpwl_mm = 12.5, .loop_mm = 3, .loop_caps = 2 };
    solved.breakdown = .{ .hpwl = 12.5, .loop_raw = 3, .loop_weighted = 6, .alignment = 1, .objective = 19.5 };
    try testing.expectEqual(restored_key, key(solved, empty_route, &.{}));
}

/// A one-cell fill of one square contour on `net`, owned by `alloc`.
fn fakeFills(alloc: std.mem.Allocator, net: []const u8) std.mem.Allocator.Error!Fills {
    const square = try alloc.dupe([2]f64, &[_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } });
    const contours = try alloc.dupe([]const [2]f64, &[_][]const [2]f64{square});
    const zones = try alloc.dupe(drc.TopologyZone, &[_]drc.TopologyZone{.{
        .net = try alloc.dupe(u8, net),
        .layer = 0,
        .poly = square,
        .component = 1,
    }});
    const fills = try alloc.dupe(pour.Fill, &[_]pour.Fill{.{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 1, .ny = 1 },
        .labels = try alloc.dupe(i32, &[_]i32{0}),
        .n_comp = 1,
        .contours = contours,
        .holes = try alloc.dupe([]const []const [2]f64, &[_][]const []const [2]f64{&.{}}),
        .coarsened = false,
    }});
    const layers = try alloc.dupe(pour.LayerSpec, &[_]pour.LayerSpec{.{ .net = .{ .named = try alloc.dupe(u8, net) }, .track_layer = 0 }});
    const plane_fills = try alloc.dupe(pour.NetFills, &[_]pour.NetFills{.{
        .net_name = try alloc.dupe(u8, net),
        .layers = layers,
        .fills = fills,
    }});
    return .{ .zones = zones, .plane_fills = plane_fills };
}

// spec: placement/fill-cache - a retained fill is copied out of the request arena that poured it and stays readable after that arena is gone
test "a retained fill outlives the arena it was poured into" {
    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    const board: Key = .{ .lo = 1, .hi = 2 };
    store.put(board, try fakeFills(scratch.allocator(), "GND"), null);
    // Exactly what the server does to the request arena after it answers.
    scratch.deinit();

    var held = store.acquire(board);
    defer held.release();
    const fills = held.fills();
    try testing.expectEqual(@as(usize, 1), fills.zones.len);
    try testing.expectEqualStrings("GND", fills.zones[0].net);
    try testing.expectEqual(@as(usize, 4), fills.zones[0].poly.len);
    try testing.expectEqualStrings("GND", fills.plane_fills[0].net_name);
    try testing.expectEqualStrings("GND", fills.plane_fills[0].layers[0].net.named);
    try testing.expectEqual(@as(usize, 1), fills.plane_fills[0].fills[0].labels.len);
    try testing.expect(!store.acquire(.{ .lo = 9, .hi = 9 }).active());
}

// spec: placement/fill-cache - an evicted board is freed only once its last reader releases it, so a DRC pass reading a fill is never overtaken by a newer board
test "eviction under a live borrow defers the free to the last reader" {
    var store: Store = .{ .backing = testing.allocator, .limits = .{ .boards = 1 } };
    defer store.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const first: Key = .{ .lo = 1, .hi = 1 };
    const second: Key = .{ .lo = 2, .hi = 2 };
    store.put(first, try fakeFills(scratch.allocator(), "GND"), null);

    // A pass takes the first board, and a second board arrives mid-pass.
    var held = store.acquire(first);
    try testing.expect(held.entry != null);
    store.put(second, try fakeFills(scratch.allocator(), "VCC"), null);

    // The reader still sees its own board — the store no longer offers it.
    try testing.expectEqualStrings("GND", held.fills().zones[0].net);
    try testing.expect(!store.acquire(first).active());
    held.release();

    var newer = store.acquire(second);
    defer newer.release();
    try testing.expectEqualStrings("VCC", newer.fills().zones[0].net);
}

// spec: placement/fill-cache - a board already retained is never duplicated, and the least recently borrowed board is the one eviction takes
test "re-putting a retained board keeps the first copy and refreshes recency" {
    var store: Store = .{ .backing = testing.allocator, .limits = .{ .boards = 2 } };
    defer store.deinit();

    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const first: Key = .{ .lo = 1, .hi = 1 };
    const second: Key = .{ .lo = 2, .hi = 2 };
    const third: Key = .{ .lo = 3, .hi = 3 };
    store.put(first, try fakeFills(scratch.allocator(), "GND"), null);
    store.put(second, try fakeFills(scratch.allocator(), "VCC"), null);
    // A racing pass that poured the same board again must not double the memo.
    store.put(first, try fakeFills(scratch.allocator(), "OTHER"), null);
    try testing.expectEqual(@as(usize, 2), store.entries.items.len);

    // Borrowing `first` makes `second` the least recently used, so the third
    // board evicts `second` rather than the board still being asked for.
    var held = store.acquire(first);
    held.release();
    store.put(third, try fakeFills(scratch.allocator(), "SIG"), null);
    try testing.expect(!store.acquire(second).active());
    var kept = store.acquire(first);
    defer kept.release();
    try testing.expectEqualStrings("GND", kept.fills().zones[0].net);
}

// spec: placement/fill-cache - a board with no planes, pours or zones retains its empty fill so the surfaces after it skip the pour attempt too
test "an empty fill is a retained answer, not a missing one" {
    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();
    const bare: Key = .{ .lo = 7, .hi = 7 };
    store.put(bare, .{}, null);
    var held = store.acquire(bare);
    defer held.release();
    try testing.expect(held.entry != null);
    try testing.expectEqual(@as(usize, 0), held.fills().zones.len);
    try testing.expectEqual(@as(usize, 0), held.fills().plane_fills.len);
    try testing.expectEqual(@as(usize, 0), held.fills().zone_fills.len);
}

// spec: placement/fill-cache - a board whose fill alone exceeds the whole store's byte ceiling is declined rather than retained, and every later pass simply pours it again
test "a board too large for the whole budget is declined, not retained" {
    var store: Store = .{ .backing = testing.allocator, .limits = .{ .bytes = 1 } };
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const board: Key = .{ .lo = 5, .hi = 5 };
    store.put(board, try fakeFills(scratch.allocator(), "GND"), null);
    try testing.expectEqual(@as(usize, 0), store.entries.items.len);
    try testing.expectEqual(@as(usize, 0), store.bytes);
    try testing.expect(!store.acquire(board).active());
}

/// A one-cell fill whose single label is `label` — distinct content per call,
/// so a borrow can be told apart from a fresh pour.
fn fakeFill(alloc: std.mem.Allocator, label: i32) std.mem.Allocator.Error!pour.Fill {
    return .{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 1, .ny = 1 },
        .labels = try alloc.dupe(i32, &[_]i32{label}),
        .n_comp = 1,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
}

// spec: placement/fill-cache - one fill retained under its own content key is borrowed by the next pass over a DIFFERENT board, so an edit re-pours only what it changed
test "a fill is borrowed across two different board states" {
    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    const unchanged: Key = .{ .lo = 11, .hi = 11 };
    const edited: Key = .{ .lo = 22, .hi = 22 };
    var first = store.beginSession().?;
    const memo = first.memo();
    try testing.expect(memo.get(memo.ctx, unchanged) == null);
    _ = memo.put(memo.ctx, unchanged, try fakeFill(scratch.allocator(), 7));
    _ = memo.put(memo.ctx, edited, try fakeFill(scratch.allocator(), 8));
    first.release();

    // The next board state asks for the same unchanged fill and one new one.
    var second = store.beginSession().?;
    defer second.release();
    const next = second.memo();
    const borrowed = next.get(next.ctx, unchanged) orelse return error.TestExpectedBorrow;
    try testing.expectEqualSlices(i32, &[_]i32{7}, borrowed.labels);
    try testing.expect(next.get(next.ctx, .{ .lo = 33, .hi = 33 }) == null);
}

// spec: placement/fill-cache - a board entry built from a session references the retained fills instead of copying them, and they stay alive as long as the entry does
test "a session-backed board entry shares its rasters with the fills it borrowed" {
    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);

    const fill_key: Key = .{ .lo = 41, .hi = 41 };
    var session = store.beginSession().?;
    const memo = session.memo();
    _ = memo.put(memo.ctx, fill_key, try fakeFill(scratch.allocator(), 5));
    const shared = memo.get(memo.ctx, fill_key).?;

    const board: Key = .{ .lo = 42, .hi = 42 };
    const zones = try scratch.allocator().dupe(drc.TopologyZone, &[_]drc.TopologyZone{.{ .net = "GND", .layer = 0, .poly = &.{}, .component = 1 }});
    store.put(board, .{ .zones = zones, .zone_fills = try scratch.allocator().dupe(pour.Fill, &[_]pour.Fill{shared}) }, session);
    session.release();
    // The pass's own arena is gone; the entry must still read its raster.
    scratch.deinit();

    var held = store.acquire(board);
    defer held.release();
    try testing.expect(held.entry != null);
    try testing.expectEqualSlices(i32, &[_]i32{5}, held.fills().zone_fills[0].labels);
    try testing.expectEqual(@as(usize, 1), held.entry.?.nodes.len);
}

// spec: placement/fill-cache - a pass holding a fill the store could not retain publishes its board by COPYING the fill, never by referencing memory the pass owns
test "an unretainable fill makes the board entry copy rather than reference" {
    var tight: Store = .{ .backing = testing.allocator, .limits = .{ .bytes = 1 } };
    defer tight.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    var declined = tight.beginSession().?;
    const memo = declined.memo();
    // A fill the ceiling refuses: the pass keeps its own copy and says so.
    try testing.expect(memo.put(memo.ctx, .{ .lo = 51, .hi = 51 }, try fakeFill(scratch.allocator(), 3)) == null);
    try testing.expect(!declined.all_backed);
    declined.release();

    // A roomy store, and a session that reports the same partial state. The
    // board must still be retained — by value, so it survives the pass's arena.
    var store: Store = .{ .backing = testing.allocator };
    defer store.deinit();
    var session = store.beginSession().?;
    session.all_backed = false;
    const board: Key = .{ .lo = 52, .hi = 52 };
    store.put(board, try fakeFills(scratch.allocator(), "GND"), session);
    session.release();
    scratch.deinit();

    var held = store.acquire(board);
    defer held.release();
    try testing.expect(held.entry != null);
    try testing.expectEqual(@as(usize, 0), held.entry.?.nodes.len);
    try testing.expectEqualStrings("GND", held.fills().zones[0].net);
    try testing.expectEqual(@as(usize, 1), held.fills().plane_fills[0].fills[0].labels.len);
}

// spec: placement/fill-cache - retained fills nothing references are given up before a whole board state is, and a fill a live board entry still needs is never freed under it
test "the byte ceiling evicts unreferenced fills before referenced ones" {
    var store: Store = .{ .backing = testing.allocator, .limits = .{ .bytes = 1024 } };
    defer store.deinit();
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();

    // One fill kept alive by a board entry, one nothing references.
    var session = store.beginSession().?;
    const memo = session.memo();
    const kept: Key = .{ .lo = 61, .hi = 61 };
    _ = memo.put(memo.ctx, kept, try fakeFill(scratch.allocator(), 1));
    const shared = memo.get(memo.ctx, kept).?;
    store.put(.{ .lo = 62, .hi = 62 }, .{ .zone_fills = try scratch.allocator().dupe(pour.Fill, &[_]pour.Fill{shared}) }, session);
    session.release();

    var loose = store.beginSession().?;
    const loose_memo = loose.memo();
    _ = loose_memo.put(loose_memo.ctx, .{ .lo = 63, .hi = 63 }, try fakeFill(scratch.allocator(), 2));
    loose.release();
    try testing.expectEqual(@as(usize, 2), store.fills.items.len);

    // Squeeze the store: the unreferenced fill goes, the entry's fill stays —
    // a raster a live board entry still points at is never the one given up.
    store.mutex.lock();
    store.limits.bytes = 0;
    store.sweepFills();
    store.mutex.unlock();
    try testing.expectEqual(@as(usize, 1), store.fills.items.len);
    var held = store.acquire(.{ .lo = 62, .hi = 62 });
    defer held.release();
    try testing.expect(held.entry != null);
    try testing.expectEqualSlices(i32, &[_]i32{1}, held.fills().zone_fills[0].labels);
}
