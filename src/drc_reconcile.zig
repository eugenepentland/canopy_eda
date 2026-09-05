//! The editor's DRC reconcile, kept between edits.
//!
//! `POST /api/pcb-drc/:name` is what the PCB editor asks after every routing
//! edit, and it used to answer by rebuilding the world: evaluate the design,
//! place every part at the posted poses, pour every plane and pour, and run the
//! whole rule set. On board-a that is eight to thirteen seconds of work to
//! answer a question about one moved track — and the ONLY thing that changed
//! between two of those requests is a handful of copper.
//!
//! This module retains what did not change. Per design it keeps the evaluated
//! block and the placement built from the poses, the board-edge margin field
//! every pour starts from, the copper the last answer was computed over, the
//! rasters that answer used, and the evidence a scoped recheck needs
//! (`drc_rules.Prior`). The next request diffs its board against that one and
//! re-checks what the difference can reach.
//!
//! ## Why the SERVER does the diffing
//!
//! The client keeps posting the whole board, unchanged — not one line of
//! `pcb_board.js` moves for this. That is deliberate: the editor's copper edits
//! are already correct, and a protocol change would put the burden of deciding
//! what a DRC recheck may skip in the browser, where it cannot be verified
//! against a full check. Here it can: `netlisp drc-dump --scoped` runs the same
//! seam over the corpus and diffs every step against a cold full check.
//!
//! ## What invalidates a session
//!
//! Everything that is not copper. A session answers only while the design's
//! live version and layout sidecar revision are the ones it was built at, every
//! file the evaluator read still has the mtime it had, and the request's poses,
//! outline, zones, clearance and non-track copper (arcs, RF paths) hash to what
//! it holds. Any mismatch is a full check that builds a fresh session — a
//! routine path, not an error, and the only one a cold server ever takes.
//!
//! ## Lifetimes
//!
//! Handler allocations die with the response (`serve.Server.dispatch` hands
//! every route `res.arena`), so a session owns an arena of its own and the
//! design is evaluated and placed INTO it. What it keeps of a DRC pass is
//! copied there too — never the pass's own arena memory — with one deliberate
//! exception: the pour rasters, which are owned by the process fill memo and
//! held by a refcounted borrow the session releases when it drops them.
//!
//! ## The background sweep's foothold
//!
//! A scoped answer is trusted because a FULL reporting pass over the same
//! accepted state agrees with it, and that pass runs behind the editor rather
//! than in front of it (`drc_sweep.zig`). It needs to read a session's
//! placement and board snapshot for seconds while the editor keeps replacing
//! both, so both arenas are REFERENCE-COUNTED (`Arena`) and a sweep holds a
//! reference for exactly as long as it reads them. Nothing else would do: W3
//! found two use-after-frees from handing session memory out by value, and the
//! session already solves this shape of problem for its pour rasters with a
//! refcounted borrow. The sweep gets the same mechanism, never a raw pointer.
//!
//! Because a sweep reads those fields off the reconcile path, every mutation of
//! a live session's fields is made under `Store.mutex` — the `*Locked` methods
//! below assume it is held, and the entry points take it around the swap alone,
//! never around the copying that precedes it.

const std = @import("std");
const drc = @import("placement/drc.zig");
const optimizer = @import("placement/optimizer.zig");
const pour = @import("placement/pour.zig");
const router = @import("placement/router.zig");
const rf_port_report = @import("placement/rf_port_report.zig");
const clock = @import("infra/clock.zig");
const drc_rules = @import("serve/drc_rules.zig");
const page_cache = @import("serve/page_cache.zig");
const fab_readiness = @import("fab_readiness.zig");
const infra_fs = @import("infra/fs.zig");
const paths = @import("paths.zig");
const httpz = @import("httpz");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const serve_root = @import("serve.zig");
const pcb_query = @import("serve/pcb_query.zig");
const sidecar_json = @import("serve/layout_sidecar_json.zig");
const modules_mod = @import("serve/modules.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// Designs held at once. Two, because the thing being reconciled is the board
/// under the cursor: one open editor, plus the one its user just came from.
/// Each entry pins an evaluated design, a placement and a board's worth of
/// pour borrows, so this is a working set, not a cache to grow.
const max_sessions: usize = 2;

/// How long after the last accepted answer the background sweep starts.
///
/// Long enough that a continuous drag or a burst of keystrokes arms exactly one
/// sweep behind it, short enough that the deferred kinds refresh while the edit
/// is still the thing on screen.
pub const sweep_debounce_ns: i128 = 3 * std.time.ns_per_s;

/// What decides whether a retained PLACEMENT still describes this request: the
/// design as it is on disk, and the poses and outline it would be built at.
pub const Design = struct {
    /// The design's live edit counter (`serve.getLiveVersion`).
    live_version: u32 = 0,
    /// The layout sidecar's optimistic-concurrency revision, so a Save landing
    /// between two rechecks retires the session that predates it.
    layout_rev: i64 = -1,
    /// Ordered digest of the posted part poses.
    poses: u64 = 0,
    /// Digest of the board outline this request resolved to.
    outline: u64 = 0,

    /// Do two requests describe a placement built from the same design at the
    /// same poses and the same board edge?
    pub fn eql(a: Design, b: Design) bool {
        return a.live_version == b.live_version and a.layout_rev == b.layout_rev and
            a.poses == b.poses and a.outline == b.outline;
    }
};

/// What decides whether a retained DRC ANSWER can be rechecked incrementally,
/// given the placement already matched. Copper is deliberately absent: tracks
/// and vias are what a scoped recheck exists to absorb.
pub const Board = struct {
    /// Digest of the posted copper zones.
    zones: u64 = 0,
    /// Digest of the copper a scoped diff does NOT cover: arcs and solved RF
    /// paths. They are inputs to every fill raster, and `pour.fillKeyStable`
    /// deliberately refuses to reason about them, so a change here is a full
    /// check rather than a quietly wrong one.
    aux: u64 = 0,
    /// The clearance rule the check measures against.
    clearance: f64 = 0,

    /// Do two requests measure the same board under the same pours and rule?
    pub fn eql(a: Board, b: Board) bool {
        return a.zones == b.zones and a.aux == b.aux and a.clearance == b.clearance;
    }
};

/// Digest the posted poses in the order they were posted — the order decides the
/// placement, so two orderings are two placements even when the set matches.
pub fn posesKey(poses: []const optimizer.RefPose) u64 {
    var h = std.hash.Wyhash.init(0x706f7365); // "pose"
    for (poses) |p| {
        h.update(p.ref);
        h.update("\x00");
        for ([_]f64{ p.x, p.y, p.rot }) |v| h.update(std.mem.asBytes(&v));
        h.update(std.mem.asBytes(&p.side));
        h.update(std.mem.asBytes(&p.locked));
    }
    return h.final();
}

/// Digest the outline this request resolved to — the submitted polygon when the
/// body carried one, the design's blessed outline otherwise. Both reach here as
/// the same `OutlineSource` the placement is built from, so an outline edit
/// through either door retires the session.
pub fn outlineKey(source: optimizer.OutlineSource) u64 {
    var h = std.hash.Wyhash.init(0x6f75746c); // "outl"
    switch (source) {
        .authored_only => h.update("\x00"),
        .drawn => |d| {
            h.update("\x01");
            for ([_]f64{ d.rect.minx, d.rect.miny, d.rect.w, d.rect.h }) |v| h.update(std.mem.asBytes(&v));
            if (d.poly) |poly| for (poly) |p| for (p) |v| h.update(std.mem.asBytes(&v));
            h.update(std.mem.asBytes(&d.arcs.len));
            for (d.arcs) |arc| h.update(std.mem.asBytes(&arc));
        },
    }
    return h.final();
}

/// Digest the posted user zones: their nets, layers, priorities and boundaries.
pub fn zonesKey(zones: []const pour.UserZone) u64 {
    var h = std.hash.Wyhash.init(0x7a6f6e65); // "zone"
    for (zones) |z| {
        h.update(z.net);
        h.update("\x00");
        h.update(std.mem.asBytes(&z.layer));
        h.update(std.mem.asBytes(&z.priority));
        for (z.poly) |p| for (p) |v| h.update(std.mem.asBytes(&v));
    }
    return h.final();
}

/// Digest the copper the scoped diff does not model: arcs, RF path outcomes,
/// and the router's recorded sharp bends (retained for the sweep — a
/// bends-only change must invalidate the session rather than slip past it).
pub fn auxKey(routed: router.RouteResult) u64 {
    var h = std.hash.Wyhash.init(0x61757863); // "auxc"
    for (routed.sharp_bends) |b| {
        h.update(std.mem.asBytes(&b.x));
        h.update(std.mem.asBytes(&b.y));
        h.update(std.mem.asBytes(&b.layer));
        h.update(std.mem.asBytes(&b.net));
        h.update(std.mem.asBytes(&b.radius));
        h.update(std.mem.asBytes(&b.required));
    }
    for (routed.arcs) |arc| {
        for ([_][2]f64{ arc.p1, arc.pm, arc.p2 }) |p| for (p) |v| h.update(std.mem.asBytes(&v));
        h.update(std.mem.asBytes(&arc.layer));
        h.update(std.mem.asBytes(&arc.width));
        h.update(std.mem.asBytes(&arc.net));
    }
    for (routed.rf_port_outcomes) |o| {
        h.update(std.mem.asBytes(&o.net));
        h.update(std.mem.asBytes(&o.success));
        h.update(std.mem.asBytes(&o.physical.layer));
        h.update(std.mem.asBytes(&o.physical.gate_removed));
        for (o.physical.samples) |sample| {
            for (sample.at) |v| h.update(std.mem.asBytes(&v));
            h.update(std.mem.asBytes(&sample.width_mm));
        }
    }
    return h.final();
}

/// An arena with more than one owner.
///
/// A session's two arenas are replaced while a background sweep is still
/// reading out of them — the design arena when the design is rebuilt, the board
/// arena on every accepted answer — and the sweep's read runs for seconds off
/// the store lock. Handing it the arena's contents by value is exactly the
/// use-after-free W3 found twice, so it is handed a REFERENCE instead: the same
/// mechanism the session already uses for its pour rasters. Every `refs`
/// mutation happens under `Store.mutex`.
const Arena = struct {
    arena: std.heap.ArenaAllocator,
    refs: usize = 1,

    /// Box an arena the caller already owns. Null on OOM, which every caller
    /// treats as "retain nothing" rather than as an error.
    fn wrap(backing: std.mem.Allocator, taken: std.heap.ArenaAllocator) ?*Arena {
        const box = backing.create(Arena) catch {
            var owned = taken;
            owned.deinit();
            return null;
        };
        box.* = .{ .arena = taken };
        return box;
    }

    fn fresh(backing: std.mem.Allocator) ?*Arena {
        return wrap(backing, std.heap.ArenaAllocator.init(backing));
    }

    fn allocator(self: *Arena) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Take a second reference. Caller holds `Store.mutex`.
    fn pin(self: *Arena) *Arena {
        self.refs += 1;
        return self;
    }

    /// Hand one reference back, freeing the arena with the last. Caller holds
    /// `Store.mutex`.
    fn release(self: *Arena) void {
        if (self.refs > 1) {
            self.refs -= 1;
            return;
        }
        const backing = self.arena.child_allocator;
        self.arena.deinit();
        backing.destroy(self);
    }
};

/// One design's retained reconcile state.
///
/// TWO arenas, because the two things retained have different lifetimes. The
/// DESIGN arena holds the evaluated block, the placement and the board-edge
/// field, and is replaced wholesale when the design or the poses move. The
/// BOARD arena holds one edit's worth of snapshot — the accepted copper, the
/// answer it produced, and the evidence a scoped recheck measures against — and
/// is replaced on every accepted answer. One arena for both would grow by a
/// placement per design reload and by a snapshot per keystroke, which is a leak
/// with a slow fuse rather than a bounded working set.
const Session = struct {
    /// The store's long-lived allocator, kept here so a method that has to make
    /// a fresh arena does not have to reach back through one.
    backing: std.mem.Allocator,
    /// The evaluated design and the placement built from it.
    design_arena: *Arena,
    /// The board state, the answer, and the scoping evidence of the last
    /// accepted answer.
    board_arena: *Arena,
    /// A design being rebuilt this request, not yet adopted. Freed by `adopt`
    /// (which promotes it) or by `Lease.release` (which discards it).
    pending: ?std.heap.ArenaAllocator = null,
    /// Design name and sub-circuit slug, owned by the store's allocator so that
    /// replacing either arena cannot pull them out from under the store.
    name: []const u8,
    sub: ?[]const u8,
    design: Design = .{},
    board: Board = .{},
    /// The files the evaluation read, so an edit on disk retires the session
    /// through the same contract every cached page validates against.
    files: ?page_cache.FileSet = null,
    placement: ?optimizer.Placement = null,
    /// The board-edge margin field every fill of this placement starts from.
    edge: ?pour.EdgeField = null,
    /// Every pad's world collision ring. Like `edge` it is a function of the
    /// PLACEMENT alone, so it is built when the placement is adopted and read
    /// by every pass until the placement is replaced.
    pads: ?drc_rules.PadShapes = null,
    /// The copper the retained answer was computed over, in the form a full
    /// re-check consumes it: everything `Board.aux` and `Board.zones` digest,
    /// so a sweep re-checks the same board and not a narrowed one.
    copper: Copper = .{},
    /// The FINDINGS of the last accepted answer — the ledger a background sweep
    /// reconciles its full pass against. Board arena; the strings inside point
    /// into the placement, never into this arena (see `retainPrior`).
    ledger: []const drc.Violation = &.{},
    prior: drc_rules.Prior = .{},
    /// The borrow the retained rasters live in.
    held: drc_rules.FillHold = .{},
    /// Which accepted answer the board arena currently holds. Bumped by every
    /// `retain`, and the whole of a sweep's staleness test: a sweep publishes
    /// only into the generation it snapshotted.
    gen: u64 = 0,
    /// True once a DRC answer has been retained; before that only the placement
    /// is usable and the next check must be a full priming pass.
    primed: bool = false,
    /// Live claims. A session is unlinked on eviction and freed by the last
    /// reader, so a reconcile in flight is never overtaken.
    refs: usize = 0,
    dropped: bool = false,
    use: u64 = 0,
    /// Background sweep bookkeeping — see `drc_sweep.zig`. `sweep_live` is
    /// true while a sweep thread exists for this design (armed or running), so
    /// a burst of edits arms one thread rather than one per keystroke.
    sweep_live: bool = false,
    /// When the armed sweep may start. Pushed forward by every accepted answer,
    /// which is what makes the arming debounced rather than per-edit.
    sweep_due_ns: i128 = 0,
    /// Arm counter and the arm a run has already claimed. A thread that finds
    /// them equal has nothing new to sweep and exits; a re-arm during a run
    /// makes them differ, and the run repeats instead of a second thread
    /// starting.
    sweep_arm: u64 = 0,
    sweep_served: u64 = 0,
    /// The generation the last published sweep agreed about, and when it
    /// finished. Both are reported additively on `/api/pcb-drc`.
    swept_gen: u64 = 0,
    swept_at_ns: i128 = 0,
    /// Sweeps published into this session, and the disagreements they found.
    sweeps: u64 = 0,
    discrepancies: u64 = 0,

    fn owns(self: *const Session, name: []const u8, sub: ?[]const u8) bool {
        if (!std.mem.eql(u8, self.name, name)) return false;
        if (self.sub) |mine| return sub != null and std.mem.eql(u8, mine, sub.?);
        return sub == null;
    }

    /// Drop the retained ANSWER — its fill borrow, its copper, its findings and
    /// its evidence — and hand back the arena that held them. The design and its
    /// placement stay. Caller holds `Store.mutex`.
    fn dropBoardLocked(self: *Session) void {
        self.held.release();
        self.held = .{};
        self.prior = .{};
        self.copper = .{};
        self.ledger = &.{};
        self.primed = false;
        // A reference-counted arena cannot be RESET: a sweep may still be
        // reading the snapshot in it. Hand this one back and take a new one.
        const stale = self.board_arena;
        if (Arena.fresh(self.backing)) |next| {
            self.board_arena = next;
            stale.release();
        }
        self.gen +%= 1;
    }

    /// Drop the retained DESIGN as well: the placement, its read-set, and the
    /// arena all three lived in. Caller holds `Store.mutex`.
    fn dropDesignLocked(self: *Session) void {
        self.dropBoardLocked();
        if (self.files) |files| files.deinit();
        self.files = null;
        self.placement = null;
        self.edge = null;
        self.pads = null;
        self.design = .{};
        const stale = self.design_arena;
        if (Arena.fresh(self.backing)) |next| {
            self.design_arena = next;
            stale.release();
        }
    }

    /// Discard a rebuild that was never adopted. Never shared, so no lock.
    fn dropPending(self: *Session) void {
        if (self.pending) |*pending| pending.deinit();
        self.pending = null;
    }

    fn destroy(self: *Session, backing: std.mem.Allocator) void {
        self.held.release();
        if (self.files) |files| files.deinit();
        self.dropPending();
        self.board_arena.release();
        self.design_arena.release();
        backing.free(self.name);
        if (self.sub) |sub| backing.free(sub);
        backing.destroy(self);
    }
};

/// The copper one accepted answer was computed over, retained so a background
/// sweep re-checks the SAME board.
///
/// It is the whole of `CopperCheck` that does not already live in the design
/// arena: the routed copper, the posted user zones and the clearance. The
/// placement and the board-edge field are the design's, and a sweep reads those
/// through its design-arena reference.
const Copper = struct {
    routed: router.RouteResult = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 },
    zones: []const pour.UserZone = &.{},
    clearance: f64 = 0,
};

/// Copy one request's copper into the arena that will outlive it.
///
/// Everything a fill or a rule reads is copied. `RouteResult`'s diagnostic
/// fields are NOT: `trials`, `failed`, `search_limited` and friends are
/// router-run commentary, no DRC layer reads them, and `trials` in particular
/// is a tree of solver state that would have to be walked to be copied safely.
/// The narrowing is exactly the field set `auxKey` digests plus the plain
/// geometry, so a board that would re-check differently invalidates the session
/// instead of reaching a sweep half-copied.
fn retainCopper(alloc: std.mem.Allocator, in: drc_rules.CopperCheck) ?Copper {
    const routed = in.routed;
    const tracks = alloc.dupe(router.Track, routed.tracks) catch return null;
    const vias = alloc.dupe(router.Via, routed.vias) catch return null;
    const arcs = alloc.dupe(router.Arc, routed.arcs) catch return null;
    const bends = alloc.dupe(router.SharpBend, routed.sharp_bends) catch return null;
    const outcomes = alloc.alloc(rf_port_report.Outcome, routed.rf_port_outcomes.len) catch return null;
    for (routed.rf_port_outcomes, outcomes) |src, *dst| {
        dst.* = src;
        dst.trials = &.{};
        dst.physical.gate_first_error = "";
        dst.physical.samples = alloc.dupe(@TypeOf(src.physical.samples[0]), src.physical.samples) catch return null;
    }
    const zones = alloc.alloc(pour.UserZone, in.zones.len) catch return null;
    for (in.zones, zones) |src, *dst| {
        dst.* = src;
        dst.net = alloc.dupe(u8, src.net) catch return null;
        dst.poly = alloc.dupe([2]f64, src.poly) catch return null;
    }
    return .{
        .routed = .{
            .tracks = tracks,
            .vias = vias,
            .arcs = arcs,
            .sharp_bends = bends,
            .rf_port_outcomes = outcomes,
            .routed = routed.routed,
            .total = routed.total,
        },
        .zones = zones,
        .clearance = in.clearance,
    };
}

/// One server's retained reconcile sessions.
///
/// `allocator = null` disables retention entirely, which is what a handler test
/// constructing a bare `ServerState` gets: every request then takes the full
/// path, which is the same answer.
pub const Store = struct {
    allocator: ?std.mem.Allocator = null,
    mutex: infra_fs.Mutex = .{},
    changed: infra_fs.Condition = .{},
    sessions: [max_sessions]?*Session = @splat(null),
    /// Design names with a reconcile in flight. A second request for the same
    /// design waits for the first rather than racing it into the same session
    /// with a different board. Sized past `max_sessions` so an unrelated design
    /// arriving mid-reconcile is never turned away for want of a slot.
    busy: [max_sessions * 2]?[]const u8 = @splat(null),
    clock: u64 = 0,
    /// Everything the background sweep keeps per server (see `drc_sweep.zig`).
    sweep: Sweeps = .{},

    pub fn deinit(self: *Store) void {
        const backing = self.allocator orelse return;
        self.mutex.lock();
        // A detached sweep thread reads sessions through this store, so tearing
        // it down means asking those threads to leave and waiting for them.
        // They check `stopping` at every wake, so this is bounded by one sweep.
        self.sweep.stopping = true;
        self.changed.broadcast();
        while (self.sweep.threads > 0) self.changed.wait(&self.mutex);
        for (&self.sessions) |*slot| {
            if (slot.*) |session| session.destroy(backing);
            slot.* = null;
        }
        // Cleared field by field rather than `self.* = .{}`: a sweep thread that
        // has just handed its registration back is still inside `unlock`, and
        // overwriting the mutex out from under it is the one race waiting for
        // the threads cannot close. `stopping` stays set — a deinitialised store
        // is finished, not reusable.
        self.allocator = null;
        self.busy = @splat(null);
        self.clock = 0;
        self.sweep.starter = null;
        self.sweep.discrepancies = 0;
        self.mutex.unlock();
    }

    fn nextUse(self: *Store) u64 {
        self.clock +%= 1;
        return self.clock;
    }

    fn busyWith(self: *const Store, name: []const u8) bool {
        for (self.busy) |slot| {
            if (slot) |held| if (std.mem.eql(u8, held, name)) return true;
        }
        return false;
    }

    /// Take the single-flight reservation for `name`, waiting while another
    /// request holds it. With every slot taken the reservation is skipped rather
    /// than waited for: two designs reconciling at once must not deadlock on a
    /// third, and an unreserved pass is merely a pass that cannot coalesce.
    /// Caller holds `mutex`.
    fn claim(self: *Store, name: []const u8) void {
        while (self.busyWith(name)) self.changed.wait(&self.mutex);
        for (&self.busy) |*slot| {
            if (slot.* != null) continue;
            slot.* = name;
            return;
        }
    }

    fn finish(self: *Store, name: []const u8) void {
        for (&self.busy) |*slot| {
            if (slot.*) |held| {
                if (std.mem.eql(u8, held, name)) {
                    slot.* = null;
                    break;
                }
            }
        }
        self.changed.broadcast();
    }

    /// The session for this design, freshly created when there is none. Caller
    /// holds `mutex`; the returned session carries one claim.
    fn sessionFor(self: *Store, backing: std.mem.Allocator, name: []const u8, sub: ?[]const u8) ?*Session {
        for (self.sessions) |slot| {
            if (slot) |session| {
                if (!session.owns(name, sub)) continue;
                session.use = self.nextUse();
                session.refs += 1;
                return session;
            }
        }
        const owned = backing.dupe(u8, name) catch return null;
        const session = backing.create(Session) catch {
            backing.free(owned);
            return null;
        };
        const design_arena = Arena.fresh(backing) orelse {
            backing.free(owned);
            backing.destroy(session);
            return null;
        };
        const board_arena = Arena.fresh(backing) orelse {
            design_arena.release();
            backing.free(owned);
            backing.destroy(session);
            return null;
        };
        session.* = .{
            .backing = backing,
            .design_arena = design_arena,
            .board_arena = board_arena,
            .name = owned,
            .sub = if (sub) |slug| (backing.dupe(u8, slug) catch null) else null,
        };
        session.use = self.nextUse();
        session.refs = 1;
        self.admit(backing, session);
        return session;
    }

    /// Link a new session, unlinking the least recently used when full. An
    /// unlinked session with a reader still on it is freed by that reader, so a
    /// reconcile in flight is never overtaken by another design's arrival.
    fn admit(self: *Store, backing: std.mem.Allocator, session: *Session) void {
        for (&self.sessions) |*slot| {
            if (slot.* != null) continue;
            slot.* = session;
            return;
        }
        var victim: usize = 0;
        for (self.sessions, 0..) |slot, i| {
            const other = slot orelse continue;
            if (other.use < self.sessions[victim].?.use) victim = i;
        }
        const evicted = self.sessions[victim].?;
        self.sessions[victim] = session;
        evicted.dropped = true;
        if (evicted.refs == 0) evicted.destroy(backing);
    }

    /// Drop one claim. The last claim on an unlinked session frees it — which is
    /// where an evicted session's pour borrows are finally handed back.
    fn drop(self: *Store, backing: std.mem.Allocator, session: *Session) void {
        _ = self;
        if (session.refs > 0) session.refs -= 1;
        if (session.dropped and session.refs == 0) session.destroy(backing);
    }
};

/// A borrowed session for the duration of one request.
///
/// `session` is null when retention is off or unavailable, in which case every
/// method degrades to "no session": the caller builds its placement in the
/// request arena and takes the full check, which is the answer it would have
/// given anyway.
pub const Lease = struct {
    store: ?*Store = null,
    session: ?*Session = null,
    request: std.mem.Allocator,
    design: Design = .{},
    name: []const u8 = "",

    /// Where a caller that has to build the design should allocate it: the
    /// session's arena when there is one, the request arena otherwise.
    pub fn arena(self: Lease) std.mem.Allocator {
        const session = self.session orelse return self.request;
        if (session.pending == null) session.pending = std.heap.ArenaAllocator.init(session.backing);
        return (&session.pending.?).allocator();
    }

    /// The retained placement, when this session already holds one built from
    /// the same design at the same poses and outline.
    pub fn placement(self: Lease) ?optimizer.Placement {
        const session = self.session orelse return null;
        if (!session.design.eql(self.design)) return null;
        if (session.files) |files| {
            if (!files.isValid()) return null;
        } else return null;
        return session.placement;
    }

    /// Retain a freshly built placement and the read-set it was built from.
    /// `files` null means "not retainable" — the placement is used for this
    /// request and dropped.
    pub fn adopt(self: *Lease, board: optimizer.Placement, files: ?page_cache.FileSet) void {
        const session = self.session orelse return;
        const store = self.store orelse return;
        const set = files orelse return;
        var pending = session.pending orelse return;
        // Seeded BEFORE the swap, out of the arena that is about to become the
        // design arena: a three-million-cell outline walk has no business
        // running under the store lock.
        const edge = drc_rules.sharedEdgeField(pending.allocator(), board) catch null;
        const pads = drc_rules.padShapes(pending.allocator(), board) catch null;
        const promoted = Arena.wrap(session.backing, pending) orelse {
            session.pending = null;
            return;
        };
        session.pending = null;
        store.mutex.lock();
        defer store.mutex.unlock();
        // A rebuilt design invalidates every board answer taken against the old
        // one, its read-set, and the arena all of it lived in.
        session.dropBoardLocked();
        if (session.files) |old| old.deinit();
        const stale = session.design_arena;
        session.design_arena = promoted;
        stale.release();
        session.files = set;
        session.placement = board;
        session.design = self.design;
        session.edge = edge;
        session.pads = pads;
    }

    /// The board-edge margin field this placement's fills all start from.
    pub fn edgeField(self: Lease) ?drc_rules.EdgeField {
        const session = self.session orelse return null;
        return session.edge;
    }

    /// Run the check, scoped when this session can answer for the board the
    /// last one left and the request did not ask for a full pass.
    pub fn reconcile(self: *Lease, alloc: std.mem.Allocator, in: Check) Report {
        // The placement-derived caches ride in on the session rather than
        // being asked for at the call site: a handler that hands over poses and
        // copper should not also have to know which per-placement tables the
        // rule layers happen to want.
        var check = in;
        if (self.session) |session| check.copper.pads = session.pads;
        var out = self.answer(alloc, check);
        out.sweep = self.sweepStatus();
        // Arm the full-board sweep BEHIND this answer, never in front of it:
        // a few seconds after the edits stop it re-checks the accepted state in
        // full, refreshes the kinds a scoped pass defers, and reconciles the
        // rest against what was just returned (`drc_sweep.zig`). Debounced and
        // coalesced, so a drag arms one sweep rather than one per frame.
        self.armSweep(check.project_dir);
        return out;
    }

    /// Arm (or re-arm) this design's background sweep after an accepted answer,
    /// starting a thread for it when none is alive.
    ///
    /// Best-effort in every direction: an unprimed session, a full cap, or no
    /// installed starter all mean the design goes un-swept for now, which costs
    /// correctness nothing — the deferred kinds still refresh whenever
    /// something invalidates the session, exactly as they did before. The
    /// common case is two field writes under a lock nobody is contending.
    fn armSweep(self: *Lease, project_dir: []const u8) void {
        const store = self.store orelse return;
        const session = self.session orelse return;
        const start = blk: {
            store.mutex.lock();
            defer store.mutex.unlock();
            if (store.sweep.stopping or !session.primed) break :blk false;
            session.sweep_arm +%= 1;
            session.sweep_due_ns = clock.nanoTimestamp() + sweep_debounce_ns;
            // One thread per design, one arm counter it serves: a re-arm while
            // one is asleep or running moves the deadline and is picked up by
            // the thread already there.
            if (session.sweep_live) break :blk false;
            if (store.sweep.threads >= Sweeps.max_concurrent) break :blk false;
            if (store.sweep.starter == null) break :blk false;
            session.sweep_live = true;
            store.sweep.threads += 1;
            break :blk true;
        };
        if (!start) return;
        // From here the store believes a thread exists for this design, so a
        // starter that could not make one has to hand the registration back.
        const starter = store.sweep.starter.?;
        if (!starter(store, project_dir, session.name, session.sub)) endSweep(store, session.name, session.sub);
    }

    /// What the last background sweep of this design established, read after the
    /// answer has been retained so the figures describe the state being
    /// returned. Off a session-less lease it is all zeroes, which is the honest
    /// answer: nothing sweeps a board nothing retains.
    fn sweepStatus(self: Lease) SweepStatus {
        const store = self.store orelse return .{};
        const session = self.session orelse return .{};
        store.mutex.lock();
        defer store.mutex.unlock();
        return .{
            .runs = session.sweeps,
            .rev = session.swept_gen,
            .age_ms = if (session.sweeps == 0) -1 else @intCast(@divFloor(clock.nanoTimestamp() - session.swept_at_ns, clock.ns_per_ms)),
            .discrepancies_total = store.sweep.discrepancies,
        };
    }

    fn answer(self: *Lease, alloc: std.mem.Allocator, in: Check) Report {
        const session = self.session orelse return .{ .report = fullCheck(alloc, in), .scoped = false };
        // Read the retained snapshot ONCE, under the lock: a background sweep
        // replaces `prior.deferred` and can retire `primed` while this runs, and
        // the scoped pass must not be handed a slice mid-swap. What is read
        // stays valid afterwards — only a reconcile replaces the board arena,
        // and this request holds that design's single-flight reservation.
        const held = self.snapshotLocked(session);
        if (in.full or !held.primed) return self.prime(alloc, in);
        if (!held.design.eql(self.design) or !held.board.eql(in.board)) return self.prime(alloc, in);
        const delta = drc_rules.diffCopper(alloc, held.copper.routed, in.copper.routed, in.copper.placement.nets.len) catch
            return self.prime(alloc, in);
        const scoped = drc_rules.checkScopedZonesTally(alloc, in.project_dir, in.name, in.copper, held.prior, delta);
        if (!scoped.scoped) return self.prime(alloc, in);
        self.retain(scoped, in);
        return .{
            .report = .{ .violations = scoped.violations, .tally = scoped.tally },
            .scoped = true,
            .fills = scoped.reuse.fills,
            .fills_repoured = scoped.reuse.repoured,
            .delta = delta.count,
        };
    }

    /// The retained answer this request may scope against, taken as one
    /// consistent reading rather than field by field.
    const Retained = struct {
        primed: bool = false,
        design: Design = .{},
        board: Board = .{},
        copper: Copper = .{},
        prior: drc_rules.Prior = .{},
    };

    fn snapshotLocked(self: Lease, session: *Session) Retained {
        const store = self.store orelse return .{};
        store.mutex.lock();
        defer store.mutex.unlock();
        return .{
            .primed = session.primed,
            .design = session.design,
            .board = session.board,
            .copper = session.copper,
            .prior = session.prior,
        };
    }

    /// A full check that also leaves the session able to scope the next one.
    fn prime(self: *Lease, alloc: std.mem.Allocator, in: Check) Report {
        if (self.session == null) return .{ .report = fullCheck(alloc, in), .scoped = false };
        const primed = drc_rules.checkPrimingZonesTally(alloc, in.project_dir, in.name, in.copper);
        if (!primed.scoped) return .{ .report = fullCheck(alloc, in), .scoped = false };
        self.retain(primed, in);
        return .{
            .report = .{ .violations = primed.violations, .tally = primed.tally },
            .scoped = false,
            .fills = primed.reuse.fills,
            .fills_repoured = primed.reuse.repoured,
        };
    }

    /// Keep what the next recheck measures against. Every slice is copied into
    /// the session arena — the pass that produced them is about to end — except
    /// the rasters, which the borrow keeps alive.
    fn retain(self: *Lease, result: drc_rules.ScopedApiReport, in: Check) void {
        const session = self.session orelse return;
        const store = self.store orelse return;
        // Build the new snapshot in a FRESH arena and swap it in, rather than
        // resetting the old one and copying into the space it just gave back.
        // A scoped pass carries the previous snapshot's deferred findings
        // forward BY REFERENCE, so the memory being copied from is the memory a
        // reset would have handed straight back to the copy — an alias, and a
        // panic on the first edit after the first one. (A reference-counted
        // arena could not be reset in any case: a sweep may be reading it.)
        var next = result;
        const fresh = Arena.fresh(session.backing) orelse {
            next.held.release();
            store.mutex.lock();
            defer store.mutex.unlock();
            session.dropBoardLocked();
            return;
        };
        const alloc = fresh.allocator();
        const kept = retainPrior(alloc, result.prior);
        const copper = retainCopper(alloc, in.copper);
        // The answer itself, so a background sweep has something to reconcile
        // its own full pass against.
        const ledger = alloc.dupe(drc.Violation, result.violations) catch null;
        if (kept == null or copper == null or ledger == null) {
            // Nothing can be retained, so nothing may claim to be: release this
            // pass's borrow and let the next request prime again.
            store.mutex.lock();
            defer store.mutex.unlock();
            fresh.release();
            next.held.release();
            session.dropBoardLocked();
            return;
        }
        store.mutex.lock();
        defer store.mutex.unlock();
        const old = session.board_arena;
        var prior_held = session.held;
        session.board_arena = fresh;
        session.prior = kept.?;
        session.held = next.held;
        session.copper = copper.?;
        session.ledger = ledger.?;
        session.design = self.design;
        session.board = in.board;
        session.primed = true;
        session.gen +%= 1;
        // The previous generation's borrow goes back only now: every raster
        // this snapshot reuses was re-borrowed through the memo by the pass
        // above, so it holds its own reference and outlives this release.
        prior_held.release();
        old.release();
    }

    /// End the lease: hand back the single-flight reservation and drop this
    /// request's claim on the session. Idempotent, so a `defer` beside the
    /// acquisition covers every path out of the handler.
    pub fn release(self: *Lease) void {
        const store = self.store orelse return;
        const session = self.session orelse return;
        self.session = null;
        // A rebuild the handler never adopted (a design that failed to resolve,
        // or one built for a request that could not retain it) dies here rather
        // than accumulating a placement per failed request.
        session.dropPending();
        store.mutex.lock();
        defer store.mutex.unlock();
        store.finish(self.name);
        if (store.allocator) |backing| store.drop(backing, session);
    }
};

/// Copy one pass's scoping evidence into a longer-lived allocator. The
/// violations' own strings are pad numbers and net names owned by the placement
/// the session already holds, so only the arrays move.
fn retainPrior(alloc: std.mem.Allocator, prior: drc_rules.Prior) ?drc_rules.Prior {
    const fill_keys = alloc.dupe(drc_rules.FillKey, prior.fill_keys) catch return null;
    const spec_keys = alloc.dupe(u64, prior.spec_keys) catch return null;
    const deferred = alloc.dupe(drc.Violation, prior.deferred) catch return null;
    const audit = retainAudit(alloc, prior.pour_audit) orelse return null;
    const answers = retainNetAnswers(alloc, prior.net_answers) orelse return null;
    return .{
        .fill_keys = fill_keys,
        .spec_keys = spec_keys,
        .pour_audit = audit,
        .deferred = deferred,
        .net_answers = answers,
    };
}

/// Copy the connectivity layer's per-net record. Each net's findings get their
/// own array: the pass's own list is one contiguous buffer the answers window
/// into, and a session must not keep a window onto memory the response arena is
/// about to reclaim. The strings inside — net names and pad numbers — belong to
/// the placement the session already holds, exactly as the ledger's do.
fn retainNetAnswers(alloc: std.mem.Allocator, answers: []const drc_rules.NetAnswer) ?[]const drc_rules.NetAnswer {
    const out = alloc.alloc(drc_rules.NetAnswer, answers.len) catch return null;
    for (answers, out) |src, *dst| {
        dst.* = .{
            .status = src.status,
            .violations = alloc.dupe(drc.Violation, src.violations) catch return null,
        };
    }
    return out;
}

fn retainAudit(alloc: std.mem.Allocator, audit: drc_rules.PourAudit) ?drc_rules.PourAudit {
    const violations = alloc.dupe(drc.Violation, audit.violations) catch return null;
    const owners = alloc.dupe(drc_rules.PourOwner, audit.owners) catch return null;
    const issues = alloc.alloc([]const ?[2]f64, audit.issues.len) catch return null;
    for (audit.issues, issues) |src, *dst| dst.* = alloc.dupe(?[2]f64, src) catch return null;
    return .{ .violations = violations, .owners = owners, .issues = issues };
}

/// The copper one reconcile measures, plus where to load the design's severity
/// overrides from.
pub const Check = struct {
    project_dir: []const u8,
    name: []const u8,
    board: Board,
    copper: drc_rules.CopperCheck,
    /// `?full=1` — take the full path and re-prime, whatever the session holds.
    full: bool = false,
};

/// One reconcile's answer, plus how it was reached. The counters are additive
/// response fields and a test's evidence that the scoped path actually ran; no
/// viewer reads them.
pub const Report = struct {
    report: drc_rules.ApiReport,
    scoped: bool,
    fills: usize = 0,
    fills_repoured: usize = 0,
    delta: usize = 0,
    /// What the background full-board sweep has to say about this session — see
    /// `drc_sweep.zig`. Additive on the response; nothing reads it but a test
    /// and a human with curl.
    sweep: SweepStatus = .{},
};

/// The last background sweep's standing, as of the answer being written.
pub const SweepStatus = struct {
    /// How many sweeps have been published into this session.
    runs: u64 = 0,
    /// The accepted generation the last published sweep agreed about. Zero
    /// means none has landed yet — a cold session, or one still inside its
    /// first debounce.
    rev: u64 = 0,
    /// Milliseconds since that sweep finished, or -1 when there has been none.
    age_ms: i64 = -1,
    /// Disagreements found over this server's life, across every design.
    discrepancies_total: u64 = 0,
};

fn fullCheck(alloc: std.mem.Allocator, in: Check) drc_rules.ApiReport {
    return drc_rules.checkFilteredZonesTally(alloc, in.project_dir, in.name, in.copper);
}

/// Lease this design's session for one request. Blocks while another request is
/// reconciling the same design, so two editor tabs cannot interleave their
/// board states into one session.
pub fn acquire(
    store: *Store,
    request: std.mem.Allocator,
    name: []const u8,
    sub: ?[]const u8,
    design: Design,
) Lease {
    const backing = store.allocator orelse return .{ .request = request, .design = design, .name = name };
    store.mutex.lock();
    store.claim(name);
    const session = store.sessionFor(backing, name, sub);
    if (session == null) {
        store.finish(name);
        store.mutex.unlock();
        return .{ .request = request, .design = design, .name = name };
    }
    store.mutex.unlock();
    return .{ .store = store, .session = session, .request = request, .design = design, .name = name };
}

/// One design's placement plus the session lease it came from. The caller must
/// `release()` the lease when its response is written.
pub const Resolved = struct {
    lease: Lease,
    placement: optimizer.Placement,
};

/// Lease this design's reconcile session and hand back the placement it holds,
/// building one into the session's arena when it holds none.
///
/// This is the whole of the endpoint's "get me a board" step, and it lives here
/// rather than in the handler because the interesting half is the retention:
/// which allocator the design is evaluated into, what invalidates it, and what
/// happens to the previous board's answer when it is rebuilt. Null means the
/// response has already been given a status and a body.
pub fn resolvePlacement(
    ctx: *serve_root.Server,
    req: *httpz.Request,
    res: *httpz.Response,
    body: std.json.Value,
    poses: []const optimizer.RefPose,
    name: []const u8,
) ?Resolved {
    const sub = pcb_query.subSlug(req);
    // A submitted outline becomes the board edge so the board-edge DRC check
    // sees it (a drawn polygon carries its exact points, so the polygon check
    // measures the real shape, not just its bbox). Absent one, fall back to the
    // design's blessed drawn outline — a bare-API caller that omits the body
    // outline must not silently get an edge-blind DRC (parity with the route
    // endpoint, which routes against this same resolution).
    const probe = pcb_layout_page.outlineForBody(ctx.allocator, ctx.project_dir, name, sub, sidecar_json.parseSavedOutline(ctx.allocator, body.object.get("outline")));
    var lease = acquire(&ctx.state.drc_sessions, ctx.allocator, name, sub, .{
        .live_version = serve_root.getLiveVersion(name),
        .layout_rev = pcb_layout_page.readLayoutRev(ctx.allocator, ctx.project_dir, name, sub),
        .poses = posesKey(poses),
        .outline = outlineKey(probe),
    });
    if (lease.placement()) |retained| return .{ .lease = lease, .placement = retained };

    // Build INTO the session's arena (the request arena when there is no
    // session), so what is retained outlives the response that produced it.
    const own = lease.arena();
    const eval = own.create(Evaluator) catch return fail(&lease, res, 500, pcb_layout_page.placement_err_msg);
    eval.* = Evaluator.init(own, ctx.project_dir);
    var module_res: ?modules_mod.ResolvedBlock = null;
    const block = pcb_layout_page.resolveBlock(own, ctx.project_dir, name, eval, &module_res) orelse
        return fail(&lease, res, 500, pcb_layout_page.no_block_msg);
    const eff_block = if (sub) |slug|
        (pcb_layout_page.descendToSub(own, block, slug) orelse
            return fail(&lease, res, 404, pcb_layout_page.no_sub_msg)).block
    else
        block;
    const seed = pcb_layout_page.outlineForBody(own, ctx.project_dir, name, sub, sidecar_json.parseSavedOutline(own, body.object.get("outline")));
    const built = optimizer.placeFromPoses(own, eff_block, ctx.project_dir, .{
        .poses = own.dupe(optimizer.RefPose, poses) catch poses,
        .outline = seed,
    }, optimizer.Params{}) catch return fail(&lease, res, 500, pcb_layout_page.placement_err_msg);
    // Retain it against the same read-set contract every cached page validates
    // through: a `.sexp` edit anywhere in the import graph, or a layout sidecar
    // write, retires this placement on the next request.
    lease.adopt(built, page_cache.captureMerged(
        ctx.allocator,
        if (module_res) |mr| &.{ eval, mr.eval } else &.{eval},
        ctx.project_dir,
        name,
        &.{},
    ));
    return .{ .lease = lease, .placement = built };
}

// ── The background sweep's view of a session ────────────────────────────────
//
// `drc_sweep.zig` decides WHEN a full reporting pass runs and WHAT its
// disagreement with the ledger means. This half decides what it is allowed to
// touch: it hands out a reference-counted snapshot, and it is the only code
// that writes a sweep's answer back into a live session. Keeping the two apart
// is what makes the lifetime argument reviewable — every pointer the sweep
// holds is pinned right here, and handed back right here.

/// How a sweep thread is started, installed by `drc_sweep.install` when the
/// server builds its state.
///
/// A function pointer rather than a direct call because the dependency only
/// runs one way: the sweep knows about sessions, sessions know nothing about
/// threads. It also makes the default — no starter — the right one for a test:
/// a bare `Store` arms sweeps and starts none, so every committed test runs the
/// sweep body in line and asserts what it did instead of racing it.
pub const Starter = *const fn (store: *Store, project_dir: []const u8, name: []const u8, sub: ?[]const u8) bool;

/// The background sweep's per-server state. One struct rather than five fields
/// on `Store`, so the store stays a table of sessions with one guest.
pub const Sweeps = struct {
    /// Installed by `drc_sweep.install`; null means sweeps are armed and never
    /// started, which is exactly what a test wants.
    starter: ?Starter = null,
    /// Threads alive on this store, armed or running. A store cannot be torn
    /// down under one, so `deinit` waits them out.
    threads: usize = 0,
    /// Set by `deinit`: every thread exits at its next wake rather than
    /// touching a store that is going away.
    stopping: bool = false,
    /// Every disagreement a sweep has found between a scoped answer and a full
    /// pass, over this server's life. Zero is the claim the scoped path makes;
    /// a non-zero number here is a bug in it, which is why the figure rides out
    /// on every `/api/pcb-drc` answer rather than being logged and forgotten.
    /// Per store rather than per process, so two server instances stay
    /// independent as every other counter here is.
    discrepancies: u64 = 0,

    /// Sweeps allowed to exist at once, across every design.
    ///
    /// Two, mirroring `serve/pcb_derived.zig`'s `WarmLimit` and for the same
    /// reason: a sweep is a complete reporting DRC over board-sized rasters, and
    /// a burst of edits across designs must not put one on every core. It is
    /// also exactly `max_sessions`, so the working set can always be covered.
    const max_concurrent: usize = 2;
};

/// One design's accepted state, pinned for a background sweep.
///
/// `check` points into the session's two arenas; `design` and `board` are the
/// references that keep them alive. Nothing here may outlive `publish`, and it
/// may not be published twice.
pub const Snapshot = struct {
    session: *Session,
    design: *Arena,
    board: *Arena,
    /// The generation of the accepted answer this covers. A sweep publishes
    /// into this generation or into nothing.
    gen: u64,
    /// The design's live edit counter when the snapshot was taken.
    live_version: u32,
    /// The board a full reporting pass must re-check.
    check: drc_rules.CopperCheck,
    /// The findings the scoped path produced for this exact board.
    ledger: []const drc.Violation,
};

/// What one published sweep says about the session it swept.
pub const Sweep = struct {
    /// The full pass's `reference_plane_gap` / `reference_transition` /
    /// `loop_area` findings. They REPLACE the ones the session has been
    /// carrying — that is what the sweep is for — and are never a discrepancy.
    deferred: []const drc.Violation = &.{},
    /// Every finding the full pass produced, adopted as the new ledger when the
    /// two disagreed.
    violations: []const drc.Violation = &.{},
    /// Non-deferred findings the sweep and the ledger disagreed about.
    discrepancies: usize = 0,
};

/// Whether a sweep's answer reached the session it was taken from.
pub const Publish = enum {
    /// Applied: deferred findings refreshed, and the ledger corrected if the
    /// two disagreed.
    published,
    /// The session moved (a newer accepted answer, a live edit, an eviction, a
    /// shutdown) while the sweep ran. Dropped in silence — the state it
    /// measured is not the state anyone is looking at.
    stale,
};

/// What an armed sweep thread should do next.
pub const Turn = union(enum) {
    /// Nothing left to serve, or the session/store is going away.
    exit,
    /// The debounce has not elapsed; wait this many nanoseconds (at most).
    wait: u64,
    /// Take a snapshot and run.
    go,
};

/// Find a linked session without creating one or disturbing the LRU order.
/// Caller holds `mutex`.
fn peek(store: *Store, name: []const u8, sub: ?[]const u8) ?*Session {
    for (store.sessions) |slot| {
        if (slot) |session| {
            if (session.owns(name, sub)) return session;
        }
    }
    return null;
}

/// Hand back the registration an arm took out. Idempotent enough to sit in a
/// `defer` beside a thread body.
pub fn endSweep(store: *Store, name: []const u8, sub: ?[]const u8) void {
    store.mutex.lock();
    defer store.mutex.unlock();
    if (peek(store, name, sub)) |session| session.sweep_live = false;
    if (store.sweep.threads > 0) store.sweep.threads -= 1;
    store.changed.broadcast();
}

/// What the armed thread should do at this moment. `.go` claims the current
/// arm, so a run that nothing re-armed is followed by `.exit` rather than by
/// another run.
pub fn sweepTurn(store: *Store, name: []const u8, sub: ?[]const u8, now_ns: i128) Turn {
    store.mutex.lock();
    defer store.mutex.unlock();
    if (store.sweep.stopping) return .exit;
    const session = peek(store, name, sub) orelse return .exit;
    if (session.dropped) return .exit;
    if (session.sweep_arm == session.sweep_served) return .exit;
    if (now_ns < session.sweep_due_ns) {
        const remaining = session.sweep_due_ns - now_ns;
        return .{ .wait = std.math.cast(u64, remaining) orelse std.math.maxInt(u64) };
    }
    session.sweep_served = session.sweep_arm;
    return .go;
}

/// Pin this design's accepted state for a full re-check.
///
/// Null when there is nothing to sweep: no store, no session, or a session that
/// has not accepted an answer yet. The two arena references and the session
/// claim are handed back by `publish`, which the caller must reach.
pub fn snapshotFor(store: *Store, name: []const u8, sub: ?[]const u8, live_version: u32) ?Snapshot {
    if (store.allocator == null) return null;
    store.mutex.lock();
    defer store.mutex.unlock();
    if (store.sweep.stopping) return null;
    const session = peek(store, name, sub) orelse return null;
    if (session.dropped or !session.primed) return null;
    const placement = session.placement orelse return null;
    session.refs += 1;
    return .{
        .session = session,
        .design = session.design_arena.pin(),
        .board = session.board_arena.pin(),
        .gen = session.gen,
        .live_version = live_version,
        .check = .{
            .placement = placement,
            .routed = session.copper.routed,
            .clearance = session.copper.clearance,
            .zones = session.copper.zones,
            .base_edge = session.edge,
            .pads = session.pads,
        },
        .ledger = session.ledger,
    };
}

/// Write one sweep's answer back into the session it was taken from, and hand
/// back everything the snapshot pinned.
///
/// The staleness test is pointer- and generation-exact rather than a heuristic:
/// the session must still hold the very arenas that were pinned, at the very
/// generation that was snapshotted, at the live version it was taken at. Any
/// drift and the answer describes a board nobody is looking at, so it is
/// dropped in silence and the sweep re-arms if the session is still live.
pub fn publish(store: *Store, snap: Snapshot, sweep: Sweep, now_ns: i128, live_version: u32) Publish {
    store.mutex.lock();
    defer store.mutex.unlock();
    defer releaseLocked(store, snap);
    const session = snap.session;
    if (store.sweep.stopping or session.dropped) return .stale;
    if (session.gen != snap.gen) return .stale;
    if (session.design_arena != snap.design or session.board_arena != snap.board) return .stale;
    if (live_version != snap.live_version) return .stale;

    const alloc = session.board_arena.allocator();
    // Copied into the session's own arena before it can be replaced — the
    // sweep's arena dies with the sweep. The pad/net strings inside are the
    // PLACEMENT's, which this session still holds, so only the array moves
    // (the same contract `retainPrior` documents).
    const refreshed = alloc.dupe(drc.Violation, sweep.deferred) catch return .stale;
    session.prior.deferred = refreshed;
    if (sweep.discrepancies > 0) {
        // The scoped path and a full pass disagreed about a kind the scoped
        // path claims to compute exactly. The sweep is the truth: adopt its
        // findings as the ledger, and retire the incremental state so the very
        // next request re-primes from a full pass rather than continuing to
        // scope against evidence that has been shown wrong.
        if (alloc.dupe(drc.Violation, sweep.violations)) |truth| {
            session.ledger = truth;
        } else |_| {}
        session.primed = false;
        session.discrepancies +|= sweep.discrepancies;
        store.sweep.discrepancies +|= sweep.discrepancies;
    }
    session.sweeps +%= 1;
    session.swept_gen = session.gen;
    session.swept_at_ns = now_ns;
    return .published;
}

/// Caller holds `mutex`.
fn releaseLocked(store: *Store, snap: Snapshot) void {
    snap.board.release();
    snap.design.release();
    if (store.allocator) |backing| store.drop(backing, snap.session);
    store.changed.broadcast();
}

/// Answer this request with a status and end the lease. Always null, so a
/// caller writes `orelse return fail(...)`.
fn fail(lease: *Lease, res: *httpz.Response, status: u16, message: []const u8) ?Resolved {
    if (lease.session) |session| if (lease.store) |store| {
        store.mutex.lock();
        session.dropDesignLocked();
        store.mutex.unlock();
    };
    lease.release();
    res.status = status;
    res.body = message;
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const drc_sweep = @import("drc_sweep.zig");
const request_log = @import("serve/request_log.zig");

/// A placement with no parts and no nets. Real enough to be retained and
/// pinned; the retention tests are about arena lifetimes, not about copper.
fn emptyPlacement() optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = false,
    };
}

/// A `Check` over that empty board.
fn emptyCheck() Check {
    return .{
        .project_dir = "",
        .name = "alpha",
        .board = .{},
        .copper = .{
            .placement = emptyPlacement(),
            .routed = .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 },
            .clearance = 0,
        },
    };
}

// spec: Web Server - The DRC reconcile session answers only for a board whose non-copper inputs are unchanged
test "a reconcile identity separates copper edits from every other change" {
    const poses = [_]optimizer.RefPose{
        .{ .ref = "U1", .x = 1, .y = 2, .rot = 0 },
        .{ .ref = "R1", .x = 3, .y = 4, .rot = 90 },
    };
    var moved = poses;
    moved[1].x = 3.001;
    try testing.expect(posesKey(&poses) != posesKey(&moved));
    try testing.expectEqual(posesKey(&poses), posesKey(&poses));
    // Order is part of the identity: it decides the placement.
    const swapped = [_]optimizer.RefPose{ poses[1], poses[0] };
    try testing.expect(posesKey(&poses) != posesKey(&swapped));

    const rect = optimizer.BoardRect{ .minx = 0, .miny = 0, .w = 10, .h = 10 };
    try testing.expect(outlineKey(.authored_only) != outlineKey(.{ .drawn = .{ .rect = rect } }));
    var wider = rect;
    wider.w = 11;
    try testing.expect(outlineKey(.{ .drawn = .{ .rect = rect } }) != outlineKey(.{ .drawn = .{ .rect = wider } }));

    const poly = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } };
    const zones = [_]pour.UserZone{.{ .net = "GND", .layer = 0, .poly = &poly }};
    var other = zones;
    other[0].layer = 1;
    try testing.expect(zonesKey(&zones) != zonesKey(&other));
    try testing.expectEqual(zonesKey(&zones), zonesKey(&zones));

    // Copper is deliberately NOT in the identity — that is the whole point.
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const a = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 0, .total = 0 };
    const b = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    try testing.expectEqual(auxKey(a), auxKey(b));

    // …but an ARC is, because no scoped rule reasons about one.
    const arcs = [_]router.Arc{.{ .p1 = .{ 0, 0 }, .pm = .{ 1, 1 }, .p2 = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 }};
    try testing.expect(auxKey(.{ .tracks = &.{}, .vias = &.{}, .arcs = &arcs, .routed = 0, .total = 0 }) != auxKey(b));

    // …and so are the recorded sharp bends: the diff does not model them, so a
    // bends-only change must invalidate the session, not slip past it.
    const bends = [_]router.SharpBend{.{ .x = 1, .y = 2, .layer = 0, .net = 0, .radius = 0.1, .required = 0.3 }};
    try testing.expect(auxKey(.{ .tracks = &.{}, .vias = &.{}, .sharp_bends = &bends, .routed = 0, .total = 0 }) != auxKey(b));

    const base = Design{ .live_version = 3, .layout_rev = 7, .poses = posesKey(&poses) };
    var bumped = base;
    bumped.live_version = 4;
    try testing.expect(!base.eql(bumped));
    var saved = base;
    saved.layout_rev = 8;
    try testing.expect(!base.eql(saved));
    try testing.expect(base.eql(base));

    const board = Board{ .zones = zonesKey(&zones), .clearance = 0.127 };
    var looser = board;
    looser.clearance = 0.15;
    try testing.expect(!board.eql(looser));
    try testing.expect(board.eql(board));
}

// spec: Web Server - A DRC reconcile store with no allocator retains nothing and every request takes the full check
test "a disabled reconcile store leases nothing and degrades to the full check" {
    var store = Store{};
    defer store.deinit();
    var lease = acquire(&store, testing.allocator, "board", null, .{});
    defer lease.release();
    try testing.expect(lease.session == null);
    try testing.expect(lease.placement() == null);
    try testing.expect(lease.edgeField() == null);
    try testing.expectEqual(testing.allocator.ptr, lease.arena().ptr);
    // Adopting into a disabled lease is a no-op rather than a leak or a crash.
    lease.adopt(undefined, null);
}

// spec: Web Server - The DRC reconcile store keeps two designs and evicts the least recently leased
test "the reconcile store holds two designs and evicts the least recently leased" {
    var store = Store{ .allocator = testing.allocator };
    defer store.deinit();

    var first = acquire(&store, testing.allocator, "alpha", null, .{});
    const alpha = first.session.?;
    first.release();
    var second = acquire(&store, testing.allocator, "beta", null, .{});
    try testing.expect(second.session.? != alpha);
    second.release();

    // Both linked: leasing either again is the SAME session, and touching alpha
    // makes beta the older of the two.
    var again = acquire(&store, testing.allocator, "alpha", null, .{});
    try testing.expectEqual(alpha, again.session.?);
    again.release();

    // A third design displaces beta, not alpha.
    var third = acquire(&store, testing.allocator, "gamma", null, .{});
    const gamma = third.session.?;
    third.release();
    var alpha_again = acquire(&store, testing.allocator, "alpha", null, .{});
    try testing.expectEqual(alpha, alpha_again.session.?);
    alpha_again.release();
    var gamma_again = acquire(&store, testing.allocator, "gamma", null, .{});
    try testing.expectEqual(gamma, gamma_again.session.?);
    gamma_again.release();

    // Beta really did go: it comes back as a fresh, unprimed session.
    var beta_again = acquire(&store, testing.allocator, "beta", null, .{});
    try testing.expect(!beta_again.session.?.primed);
    try testing.expect(beta_again.session.?.placement == null);
    beta_again.release();
}

// spec: Web Server - A reconcile session is claimed by one design name and one sub-circuit slug
test "a session answers only for its own design and sub-circuit" {
    var store = Store{ .allocator = testing.allocator };
    defer store.deinit();
    var top = acquire(&store, testing.allocator, "alpha", null, .{});
    const top_session = top.session.?;
    top.release();
    var sub = acquire(&store, testing.allocator, "alpha", "power", .{});
    try testing.expect(sub.session.? != top_session);
    sub.release();
}

/// A minimal routed board: two capacitors joined by three top-layer segments
/// over a declared ground plane and pour, so the endpoint has real copper, a
/// real fill and a real connectivity verdict to answer about.
fn writeReconcileFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(testing.io, "lib/components");
    try dir.createDirPath(testing.io, "lib/footprints");
    try dir.createDirPath(testing.io, "src");
    try dir.writeFile(testing.io, .{ .sub_path = "lib/components/cap.sexp", .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
    });
    try dir.writeFile(testing.io, .{ .sub_path = "lib/footprints/0402.sexp", .data =
        \\(footprint "0402"
        \\  (pad 1 smd roundrect (pos -0.48 0.00) (size 0.56 0.62))
        \\  (pad 2 smd roundrect (pos 0.48 0.00) (size 0.56 0.62))
        \\  (courtyard (rect -0.91 -0.46 0.91 0.46)))
    });
    try dir.writeFile(testing.io, .{ .sub_path = "src/fabsel.sexp", .data =
        \\(design-block "Reconcile Fixture"
        \\  (import cap)
        \\  (board (size 20 10))
        \\  (stackup 4 (plane 2 "GND"))
        \\  (net-class "sig" (return-path (max-loop-area 0.001)) (nets "SIG"))
        \\  (design-rules (pour top "GND") (ground-via-max 1.0))
        \\  (instance "C1" (cap "10nF") (pin 1 "SIG") (pin 2 "GND"))
        \\  (instance "C2" (cap "10nF") (pin 1 "SIG") (pin 2 "GND")))
    });
}

/// POST `/api/pcb-drc/fabsel` through the real handler with a retained
/// reconcile store, so the session is exercised exactly as the editor does it.
fn drcApiBody(
    alloc: std.mem.Allocator,
    state: *serve_root.ServerState,
    project: []const u8,
    body: []const u8,
    full: bool,
) ![]const u8 {
    var srv = serve_root.Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", "fabsel");
    if (full) ht.query("full", "1");
    ht.body(body);
    paths.beginRequest();
    try pcb_layout_page.pcbDrcApi(&srv, ht.req, ht.res);
    try testing.expectEqual(@as(u16, 200), ht.res.status);
    return alloc.dupe(u8, ht.res.body);
}

/// The board the DRC endpoint test posts: the fab fixture's own routed layout,
/// with `shift` added to the middle segment's y so a second post is one copper
/// edit away from the first.
fn drcApiRequestBody(alloc: std.mem.Allocator, shift: f64) ![]const u8 {
    return std.fmt.allocPrint(alloc,
        \\{{"parts":[{{"ref":"C1","x":5,"y":5,"rot":0}},{{"ref":"C2","x":10,"y":5,"rot":0}}],
        \\ "tracks":[
        \\  {{"x1":4.52,"y1":5,"x2":4.52,"y2":{d},"l":0,"w":0.2,"net":"SIG"}},
        \\  {{"x1":4.52,"y1":{d},"x2":9.52,"y2":{d},"l":0,"w":0.2,"net":"SIG"}},
        \\  {{"x1":9.52,"y1":{d},"x2":9.52,"y2":5,"l":0,"w":0.2,"net":"SIG"}}],
        \\ "vias":[]}}
    , .{ 3 + shift, 3 + shift, 3 + shift, 3 + shift });
}

/// The `"drc":[…]` array of one response, so two answers compare as findings
/// rather than as whole payloads (the additive counters differ by design).
fn drcApiFindings(body: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, body, "\"drc\":[") orelse return "";
    const end = std.mem.indexOf(u8, body[start..], "],\"n\":") orelse return "";
    return body[start .. start + end];
}

/// The three kinds a scoped recheck DEFERS, as the words they appear under in
/// the response (`serve/drc_json.zig`'s `kindStr`).
const deferred_labels = [_][]const u8{ "reference plane gap", "reference transition", "return loop area" };

/// One response's findings with the deferred kinds removed, and the deferred
/// kinds alone — the two halves a scoped answer makes different promises about.
///
/// A scoped pass computes the first half exactly and CARRIES the second from the
/// last full pass, so "scoped equals full" is a claim about `plain` only. This
/// is the same split `drc-dump --scoped` makes over the corpus, spelled against
/// the JSON because that is the surface the endpoint test measures.
fn drcApiSplit(alloc: std.mem.Allocator, body: []const u8, want_deferred: bool) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    const findings = drcApiFindings(body);
    // Brace depth, not the next `}`: a finding carries nested `a`/`b` party
    // objects, and a splitter that stopped at the first close would cut two-
    // party findings (every `net_open`) in half and compare the halves.
    var depth: usize = 0;
    var start: usize = 0;
    var quoted = false;
    for (findings, 0..) |ch, i| {
        if (quoted) {
            if (ch == '"') quoted = false;
            continue;
        }
        switch (ch) {
            '"' => quoted = true,
            '{' => {
                if (depth == 0) start = i;
                depth += 1;
            },
            '}' => {
                depth -= 1;
                if (depth != 0) continue;
                const item = findings[start .. i + 1];
                var is_deferred = false;
                for (deferred_labels) |label| {
                    if (std.mem.indexOf(u8, item, label) != null) is_deferred = true;
                }
                if (is_deferred != want_deferred) continue;
                out.append(alloc, ';') catch return out.items;
                out.appendSlice(alloc, item) catch return out.items;
            },
            else => {},
        }
    }
    return out.items;
}

/// How many findings one split holds.
fn drcApiCount(split: []const u8) usize {
    return std.mem.count(u8, split, ";");
}

/// The `routed`/`total`/`unique_*` run of one response — the completion pair the
/// editor header reads, isolated from the additive scoping counters after it.
fn drcApiTally(body: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, body, ",\"routed\":") orelse return "";
    const end = std.mem.indexOf(u8, body[start..], ",\"scoped\":") orelse return "";
    return body[start .. start + end];
}

// spec: Web Server - The DRC endpoint re-checks a copper edit against the board state it last accepted and returns the answer a full check returns
test "the DRC endpoint scopes a copper edit, matches ?full=1, and re-primes when the design moves" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    try writeReconcileFixture(tmp.dir);

    // Retention ON, exactly as `serve()` turns it on — and on the leak-checked
    // allocator, so a session that forgets an arena or a fill borrow fails here.
    var state = serve_root.ServerState{ .drc_sessions = .{ .allocator = testing.allocator } };
    defer state.drc_sessions.deinit();

    const first = try drcApiRequestBody(alloc, 0);
    const edited = try drcApiRequestBody(alloc, 0.4);

    // The first request has nothing to measure against and primes the session.
    const primed = try drcApiBody(alloc, &state, project, first, false);
    try testing.expect(std.mem.indexOf(u8, primed, "\"scoped\":false") != null);

    // The second is one copper edit away and takes the scoped path.
    const scoped = try drcApiBody(alloc, &state, project, edited, false);
    try testing.expect(std.mem.indexOf(u8, scoped, "\"scoped\":true") != null);
    // …and it really did diff rather than re-do: three segments moved.
    try testing.expect(std.mem.indexOf(u8, scoped, "\"delta\":6") != null);

    // The same state through the forced-full escape hatch is the same answer —
    // for every kind the scoped path claims to compute. The three it DEFERS are
    // excluded here and asserted below: comparing them would be comparing the
    // scoped path against the thing it deliberately does not do.
    const forced = try drcApiBody(alloc, &state, project, edited, true);
    try testing.expect(std.mem.indexOf(u8, forced, "\"scoped\":false") != null);
    const plain_forced = drcApiSplit(alloc, forced, false);
    try testing.expectEqualStrings(plain_forced, drcApiSplit(alloc, scoped, false));
    // The split is load-bearing, so assert it actually splits: this board has
    // two ground-via warnings and one open net on the plain side, and three
    // reference-plane gaps plus one loop area on the deferred side.
    try testing.expectEqual(@as(usize, 3), drcApiCount(plain_forced));
    try testing.expectEqual(@as(usize, 4), drcApiCount(drcApiSplit(alloc, forced, true)));
    // The deferred half of the scoped answer is the PRIMED board's, carried
    // verbatim — and the full pass's is the edited board's, which is different.
    // That difference is the staleness the background sweep exists to end
    // (`drc_sweep.zig`), and it is real on this fixture rather than assumed.
    try testing.expectEqualStrings(drcApiSplit(alloc, primed, true), drcApiSplit(alloc, scoped, true));
    try testing.expect(!std.mem.eql(u8, drcApiSplit(alloc, forced, true), drcApiSplit(alloc, scoped, true)));
    // The routed tally the editor header reads is the same number too.
    try testing.expectEqualStrings(drcApiTally(forced), drcApiTally(scoped));
    try testing.expect(std.mem.indexOf(u8, drcApiTally(scoped), "\"unique_total\":") != null);

    // Several scoped rechecks in a row, each measured against the snapshot the
    // last one left.
    for (0..4) |i| {
        const step = try drcApiRequestBody(alloc, 0.1 * @as(f64, @floatFromInt(i + 1)));
        const answer = try drcApiBody(alloc, &state, project, step, false);
        try testing.expect(std.mem.indexOf(u8, answer, "\"scoped\":true") != null);
    }

    // A live edit to the design retires the session: the next request may not
    // answer from a placement built before it.
    const back_to_scoped = try drcApiBody(alloc, &state, project, first, false);
    try testing.expect(std.mem.indexOf(u8, back_to_scoped, "\"scoped\":true") != null);
    _ = serve_root.bumpLiveVersion("fabsel");
    const after_edit = try drcApiBody(alloc, &state, project, first, false);
    try testing.expect(std.mem.indexOf(u8, after_edit, "\"scoped\":false") != null);
    try testing.expectEqualStrings(drcApiSplit(alloc, back_to_scoped, false), drcApiSplit(alloc, after_edit, false));

    // With no store at all every request is a full check — and the same one.
    var bare = serve_root.ServerState{};
    const unretained = try drcApiBody(alloc, &bare, project, edited, false);
    try testing.expect(std.mem.indexOf(u8, unretained, "\"scoped\":false") != null);
    try testing.expectEqualStrings(drcApiFindings(forced), drcApiFindings(unretained));
    // A store that retains nothing sweeps nothing, and says so.
    try testing.expect(std.mem.indexOf(u8, unretained, "\"runs\":0,\"rev\":0,\"age_ms\":-1") != null);
}

/// The six phases `pcbDrcApi` names, as they appear inside a `"stages":{…}`
/// object. `resolve` is the one W3 was briefed wrongly about: the design
/// evaluation and `placeFromPoses` behind this endpoint, not DRC at all.
const drc_stage_keys = [_][]const u8{ "\"parse\":", "\"resolve\":", "\"restore\":", "\"drc\":", "\"respond\":" };

/// Whether `line` names every phase the DRC endpoint promises to report.
fn namesEveryDrcStage(line: []const u8) bool {
    for (drc_stage_keys) |key| {
        if (std.mem.indexOf(u8, line, key) == null) return false;
    }
    return true;
}

// spec: Web Server - An instrumented handler files its own phase breakdown in the interaction log, naming every stage it ran and the total that covers them
test "the DRC endpoint writes its phase breakdown to the interaction log" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    try writeReconcileFixture(tmp.dir);

    // Logging on, exactly as `serve()` turns it on.
    var state = serve_root.ServerState{ .request_log = .{ .project_dir = project } };
    _ = try drcApiBody(alloc, &state, project, try drcApiRequestBody(alloc, 0), false);

    const log_path = request_log.currentPath(&state.request_log, alloc, null).?;
    const logged = try infra_fs.cwd().readFileAlloc(alloc, log_path, 1 << 20);
    // One line: the handler's own stages. The dispatch seam's `req` line comes
    // from `serve.dispatch`, which a direct handler call never goes through.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, logged, "\n"));
    try testing.expect(std.mem.indexOf(u8, logged, "\"src\":\"server\",\"evt\":\"stages\"") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "\"design\":\"fabsel\"") != null);
    try testing.expect(std.mem.indexOf(u8, logged, "\"ms_total\":") != null);
    try testing.expect(namesEveryDrcStage(logged));

    // A default store logs nowhere, so instrumenting the handler cannot leave
    // stray files beside a project a test (or the CLI) merely read.
    var off = serve_root.ServerState{};
    _ = try drcApiBody(alloc, &off, project, try drcApiRequestBody(alloc, 0.4), false);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, try infra_fs.cwd().readFileAlloc(alloc, log_path, 1 << 20), "\n"));
}

// spec: Web Server - A reconcile snapshot that carries the previous one's deferred findings forward is retained without aliasing the memory it copies from
test "a retained snapshot survives being replaced by one that carries it forward" {
    var store = Store{ .allocator = testing.allocator };
    defer store.deinit();
    var lease = acquire(&store, testing.allocator, "alpha", null, .{});
    defer lease.release();
    const session = lease.session.?;
    const empty = emptyCheck();

    // A first accepted answer carrying one deferred finding.
    const first = [_]drc.Violation{.{ .x = 1, .y = 2, .gap = 0, .clearance = 0, .kind = .loop_area, .severity = .warn }};
    lease.retain(.{ .scoped = true, .prior = .{ .deferred = &first } }, empty);
    try testing.expect(session.primed);
    try testing.expectEqual(@as(usize, 1), session.prior.deferred.len);

    // The second answer CARRIES the first's findings — and its source is the
    // session's own retained slice. A snapshot store that reclaimed the old
    // arena before copying would be copying out of the memory it had just
    // handed to the copy, which is an alias and a panic on the first edit after
    // the first one. Ten generations, each carrying the last.
    for (0..10) |_| {
        lease.retain(.{ .scoped = true, .prior = .{ .deferred = session.prior.deferred } }, empty);
        try testing.expectEqual(@as(usize, 1), session.prior.deferred.len);
        try testing.expectEqual(drc.Kind.loop_area, session.prior.deferred[0].kind);
        try testing.expectEqual(@as(f64, 1), session.prior.deferred[0].x);
    }
}

/// The `loop_area` finding of one response, as its whole JSON object.
///
/// It is the deferred kind this fixture produces (`(return-path (max-loop-area
/// …))` on the SIG net), and its `y` is the midpoint of the segment the test
/// moves — so "did the carried deferred finding refresh?" is a string compare.
fn drcApiLoopArea(body: []const u8) []const u8 {
    const key = "\"k\":\"return loop area\"";
    const at = std.mem.indexOf(u8, body, key) orelse return "";
    const start = std.mem.lastIndexOfScalar(u8, body[0..at], '{') orelse return "";
    const end = std.mem.indexOfScalarPos(u8, body, at, '}') orelse return "";
    return body[start .. end + 1];
}

/// One sweep of `fabsel`, run on this thread. The store under test has no
/// starter installed, so nothing races this and nothing has to be slept on.
fn sweepFixture(state: *serve_root.ServerState, project: []const u8) drc_sweep.Outcome {
    return drc_sweep.sweepOnce(&state.drc_sessions, project, "fabsel", null);
}

// spec: Web Server - A background full-board DRC sweep refreshes the kinds a scoped recheck defers, and the next reconcile answer carries them
test "a background sweep refreshes the deferred findings a scoped answer carried" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    try writeReconcileFixture(tmp.dir);

    var state = serve_root.ServerState{ .drc_sessions = .{ .allocator = testing.allocator } };
    defer state.drc_sessions.deinit();

    // Prime, then move the middle segment. `loop_area` is reported at the
    // longest segment's midpoint, so the truth for the edited board is a
    // finding 0.4 mm away from the primed one.
    const primed = try drcApiBody(alloc, &state, project, try drcApiRequestBody(alloc, 0), false);
    const at_prime = try alloc.dupe(u8, drcApiLoopArea(primed));
    try testing.expect(at_prime.len > 0);
    // Nothing has swept yet, and the response says so.
    try testing.expect(std.mem.indexOf(u8, primed, "\"sweep\":{\"runs\":0,\"rev\":0,\"age_ms\":-1,\"discrepancies_total\":0}") != null);

    const edited = try drcApiRequestBody(alloc, 0.4);
    const scoped = try drcApiBody(alloc, &state, project, edited, false);
    try testing.expect(std.mem.indexOf(u8, scoped, "\"scoped\":true") != null);
    // The scoped answer CARRIED the primed board's deferred finding: it is
    // stale by design, and this is the staleness the sweep exists to end.
    try testing.expectEqualStrings(at_prime, drcApiLoopArea(scoped));
    const forced = try drcApiBody(alloc, &state, project, edited, true);
    const truth = try alloc.dupe(u8, drcApiLoopArea(forced));
    try testing.expect(!std.mem.eql(u8, at_prime, truth));
    // …and re-prime the session back into the carrying state that a real
    // editing session is in, so the sweep is the only thing that can fix it.
    const back = try drcApiBody(alloc, &state, project, edited, false);
    _ = back;

    // The sweep: one full pass over the accepted state, published into it.
    const out = sweepFixture(&state, project);
    try testing.expect(out.ran and out.published);
    try testing.expect(out.deferred > 0);
    // Refreshing a deferred kind is NOT a disagreement.
    try testing.expectEqual(@as(usize, 0), out.discrepancies);

    // The next answer carries the correction out with no protocol change: the
    // client asked for nothing, changed nothing, and gets the fresh finding.
    const after = try drcApiBody(alloc, &state, project, edited, false);
    try testing.expect(std.mem.indexOf(u8, after, "\"scoped\":true") != null);
    try testing.expectEqualStrings(truth, drcApiLoopArea(after));
    try testing.expect(std.mem.indexOf(u8, after, "\"runs\":1") != null);
    try testing.expect(std.mem.indexOf(u8, after, "\"discrepancies_total\":0") != null);
}

// spec: Web Server - A background full-board DRC sweep corrects a ledger that lost a finding or invented one, and counts the disagreement
test "a background sweep restores a lost finding and retires an invented one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    try writeReconcileFixture(tmp.dir);

    var state = serve_root.ServerState{ .drc_sessions = .{ .allocator = testing.allocator } };
    defer state.drc_sessions.deinit();
    const board = try drcApiRequestBody(alloc, 0);
    _ = try drcApiBody(alloc, &state, project, board, false);
    const store = &state.drc_sessions;

    // A clean session sweeps clean: this is the claim the whole scoped path
    // rests on, asserted before anything is broken on purpose.
    const clean = sweepFixture(&state, project);
    try testing.expect(clean.published);
    try testing.expectEqual(@as(usize, 0), clean.discrepancies);
    try testing.expectEqual(@as(u64, 0), store.sweep.discrepancies);

    // A ledger with a finding the board does not have. Only a bug in the
    // scoped path could produce one, so a test has to plant it.
    const session = peekTest(store).?;
    const invented = drc.Violation{ .x = 7, .y = 7, .gap = 0.01, .clearance = 0.2, .kind = .track_track };
    const grown = try session.board_arena.allocator().alloc(drc.Violation, session.ledger.len + 1);
    @memcpy(grown[0..session.ledger.len], session.ledger);
    grown[session.ledger.len] = invented;
    session.ledger = grown;

    const caught = sweepFixture(&state, project);
    try testing.expect(caught.published);
    try testing.expectEqual(@as(usize, 1), caught.discrepancies);
    try testing.expectEqual(@as(u64, 1), store.sweep.discrepancies);
    // The sweep wins: its findings are the ledger now, and the invented one is
    // gone from it.
    for (session.ledger) |v| try testing.expect(v.kind != .track_track or v.x != 7);
    // …and the session is retired, so the very next answer is a full pass
    // rather than more scoping against evidence shown to be wrong.
    try testing.expect(!session.primed);

    // The inverse: a ledger MISSING a finding the board really has. The next
    // request re-primes (the session was retired above), so drop one entry from
    // the ledger it leaves behind.
    _ = try drcApiBody(alloc, &state, project, board, false);
    const after = peekTest(store).?;
    try testing.expect(after.ledger.len > 0);
    after.ledger = after.ledger[0 .. after.ledger.len - 1];
    const restored = sweepFixture(&state, project);
    try testing.expect(restored.published);
    try testing.expectEqual(@as(usize, 1), restored.discrepancies);
    try testing.expectEqual(@as(u64, 2), store.sweep.discrepancies);
    try testing.expect(!after.primed);

    // The count is visible on the wire, additively.
    const answer = try drcApiBody(alloc, &state, project, board, false);
    try testing.expect(std.mem.indexOf(u8, answer, "\"discrepancies_total\":2") != null);
}

/// The store's single session, for a test that has to reach past the sweep API
/// to break a ledger on purpose.
fn peekTest(store: *Store) ?*Session {
    store.mutex.lock();
    defer store.mutex.unlock();
    for (store.sessions) |slot| {
        if (slot) |session| return session;
    }
    return null;
}

// spec: Web Server - A background DRC sweep answer for a state the session has left is dropped without touching its ledger
test "a sweep answer is dropped when the session moved under it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    try writeReconcileFixture(tmp.dir);

    var state = serve_root.ServerState{ .drc_sessions = .{ .allocator = testing.allocator } };
    defer state.drc_sessions.deinit();
    const store = &state.drc_sessions;
    _ = try drcApiBody(alloc, &state, project, try drcApiRequestBody(alloc, 0), false);

    const session = peekTest(store).?;
    const before_deferred = session.prior.deferred;
    const before_ledger = session.ledger;
    const before_gen = session.gen;

    // A LIVE EDIT between snapshot and publish. Everything else about the
    // session is untouched, so only the version check can catch this.
    const snap = snapshotFor(store, "fabsel", null, serve_root.getLiveVersion("fabsel")).?;
    const bumped = serve_root.bumpLiveVersion("fabsel");
    const planted = [_]drc.Violation{.{ .x = 3, .y = 3, .gap = 0, .clearance = 0, .kind = .loop_area, .severity = .warn }};
    try testing.expectEqual(Publish.stale, publish(store, snap, .{
        .deferred = &planted,
        .violations = &planted,
        .discrepancies = 3,
    }, clock.nanoTimestamp(), bumped));
    try testing.expectEqual(before_deferred.ptr, session.prior.deferred.ptr);
    try testing.expectEqual(before_ledger.ptr, session.ledger.ptr);
    try testing.expectEqual(before_gen, session.gen);
    try testing.expectEqual(@as(u64, 0), store.sweep.discrepancies);
    try testing.expectEqual(@as(u64, 0), session.sweeps);
    try testing.expect(session.primed);

    // A NEWER ACCEPTED ANSWER between snapshot and publish is the other half:
    // the generation moves, and the answer describes a board nobody is on.
    const moved = snapshotFor(store, "fabsel", null, bumped).?;
    _ = try drcApiBody(alloc, &state, project, try drcApiRequestBody(alloc, 0.4), false);
    try testing.expect(session.gen != moved.gen);
    try testing.expectEqual(Publish.stale, publish(store, moved, .{
        .deferred = &planted,
        .violations = &planted,
        .discrepancies = 3,
    }, clock.nanoTimestamp(), bumped));
    try testing.expectEqual(@as(u64, 0), store.sweep.discrepancies);
    try testing.expectEqual(@as(u64, 0), session.sweeps);

    // The snapshot's own arena references went back on both drops: the store
    // tears down clean under the leak-checking allocator, which is the whole
    // proof that a dropped sweep does not strand a session.
}

/// The nanoseconds a turn asks a thread to wait, or 0 for any other verdict.
fn waitOf(turn: Turn) u64 {
    return switch (turn) {
        .wait => |ns| ns,
        else => 0,
    };
}

/// A `Starter` that records rather than spawns, so the scheduling can be tested
/// without a thread to synchronise with.
const StartLog = struct {
    var calls: usize = 0;
    var refuse: bool = false;

    fn start(_: *Store, _: []const u8, _: []const u8, _: ?[]const u8) bool {
        calls += 1;
        return !refuse;
    }
};

// spec: Web Server - Background DRC sweeps are one thread per design, capped across designs, and a re-arm during one coalesces into it
test "arming a sweep starts one thread per design, capped, and coalesces re-arms" {
    var store = Store{ .allocator = testing.allocator };
    defer store.deinit();
    StartLog.calls = 0;
    StartLog.refuse = false;
    store.sweep.starter = StartLog.start;

    var alpha = acquire(&store, testing.allocator, "alpha", null, .{});
    const a = alpha.session.?;
    // Nothing is armed before an answer is accepted: an unprimed session has no
    // state a sweep could measure.
    alpha.armSweep("p");
    try testing.expectEqual(@as(usize, 0), StartLog.calls);
    try testing.expectEqual(@as(u64, 0), a.sweep_arm);

    alpha.retain(.{ .scoped = true }, emptyCheck());
    alpha.armSweep("p");
    try testing.expectEqual(@as(usize, 1), StartLog.calls);
    try testing.expectEqual(@as(usize, 1), store.sweep.threads);
    try testing.expect(a.sweep_live);

    // A second answer while one is armed COALESCES: the deadline moves and the
    // arm counter rises, but no second thread is asked for.
    const first_due = a.sweep_due_ns;
    alpha.armSweep("p");
    alpha.armSweep("p");
    try testing.expectEqual(@as(usize, 1), StartLog.calls);
    try testing.expectEqual(@as(u64, 3), a.sweep_arm);
    try testing.expect(a.sweep_due_ns >= first_due);
    alpha.release();

    // A second DESIGN gets its own thread — that is what the cap of two is for.
    var beta = acquire(&store, testing.allocator, "beta", null, .{});
    beta.retain(.{ .scoped = true }, emptyCheck());
    beta.armSweep("p");
    try testing.expectEqual(@as(usize, 2), StartLog.calls);
    try testing.expectEqual(@as(usize, 2), store.sweep.threads);
    beta.release();

    // The armed thread serves the arms it was given and then leaves: `.go`
    // claims the current arm, and a turn with nothing new is `.exit`.
    try testing.expectEqual(Turn.go, sweepTurn(&store, "alpha", null, a.sweep_due_ns));
    try testing.expectEqual(Turn.exit, sweepTurn(&store, "alpha", null, a.sweep_due_ns));
    // A re-arm DURING the run makes the same thread go round again rather than
    // a second one starting.
    var again = acquire(&store, testing.allocator, "alpha", null, .{});
    again.retain(.{ .scoped = true }, emptyCheck());
    again.armSweep("p");
    again.release();
    try testing.expectEqual(@as(usize, 2), StartLog.calls);
    try testing.expectEqual(Turn.go, sweepTurn(&store, "alpha", null, a.sweep_due_ns + std.time.ns_per_s));

    // Before the deadline a thread waits rather than sweeping.
    var third = acquire(&store, testing.allocator, "alpha", null, .{});
    third.retain(.{ .scoped = true }, emptyCheck());
    third.armSweep("p");
    third.release();
    try testing.expect(waitOf(sweepTurn(&store, "alpha", null, a.sweep_due_ns - std.time.ns_per_s)) > 0);

    // Hand both registrations back, as the threads' own `defer` would.
    endSweep(&store, "alpha", null);
    endSweep(&store, "beta", null);
    try testing.expectEqual(@as(usize, 0), store.sweep.threads);

    // With both slots taken, a third design is refused rather than queued: the
    // cap is a cap, and an unswept design is only unswept, never wrong.
    store.sweep.threads = Sweeps.max_concurrent;
    var gamma = acquire(&store, testing.allocator, "gamma", null, .{});
    gamma.retain(.{ .scoped = true }, emptyCheck());
    gamma.armSweep("p");
    try testing.expectEqual(@as(usize, 2), StartLog.calls);
    try testing.expect(!gamma.session.?.sweep_live);
    gamma.release();
    store.sweep.threads = 0;

    // A starter that cannot make a thread hands the registration straight back,
    // so a failed spawn does not leave the design permanently "swept by
    // someone else".
    StartLog.refuse = true;
    var delta = acquire(&store, testing.allocator, "delta", null, .{});
    delta.retain(.{ .scoped = true }, emptyCheck());
    delta.armSweep("p");
    try testing.expectEqual(@as(usize, 3), StartLog.calls);
    try testing.expectEqual(@as(usize, 0), store.sweep.threads);
    try testing.expect(!delta.session.?.sweep_live);
    delta.release();
    StartLog.refuse = false;
}
