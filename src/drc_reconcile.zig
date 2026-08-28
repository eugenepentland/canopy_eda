//! The editor's DRC reconcile, kept between edits.
//!
//! `POST /api/pcb-drc/:name` is what the PCB editor asks after every routing
//! edit, and it used to answer by rebuilding the world: evaluate the design,
//! place every part at the posted poses, pour every plane and pour, and run the
//! whole rule set. On barracuda that is eight to thirteen seconds of work to
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

const std = @import("std");
const drc = @import("placement/drc.zig");
const optimizer = @import("placement/optimizer.zig");
const pour = @import("placement/pour.zig");
const router = @import("placement/router.zig");
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

/// Digest the copper the scoped diff does not model: arcs and RF path outcomes.
pub fn auxKey(routed: router.RouteResult) u64 {
    var h = std.hash.Wyhash.init(0x61757863); // "auxc"
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

/// One design's retained reconcile state.
///
/// TWO arenas, because the two things retained have different lifetimes. The
/// DESIGN arena holds the evaluated block, the placement and the board-edge
/// field, and is replaced wholesale when the design or the poses move. The
/// BOARD arena holds one edit's worth of snapshot — the accepted copper and the
/// evidence a scoped recheck measures against — and is reset on every accepted
/// answer. One arena for both would grow by a placement per design reload and
/// by a snapshot per keystroke, which is a leak with a slow fuse rather than a
/// bounded working set.
const Session = struct {
    /// The evaluated design and the placement built from it.
    design_arena: std.heap.ArenaAllocator,
    /// The board state and scoping evidence of the last accepted answer.
    board_arena: std.heap.ArenaAllocator,
    /// A design being rebuilt this request, not yet adopted. Freed by `adopt`
    /// (which promotes it) or by `Lease.release` (which discards it).
    pending: ?std.heap.ArenaAllocator = null,
    /// Design name and sub-circuit slug, owned by the store's allocator so that
    /// resetting either arena cannot pull them out from under the store.
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
    /// The copper the retained answer was computed over.
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
    prior: drc_rules.Prior = .{},
    /// The borrow the retained rasters live in.
    held: drc_rules.FillHold = .{},
    /// True once a DRC answer has been retained; before that only the placement
    /// is usable and the next check must be a full priming pass.
    primed: bool = false,
    /// Live claims. A session is unlinked on eviction and freed by the last
    /// reader, so a reconcile in flight is never overtaken.
    refs: usize = 0,
    dropped: bool = false,
    use: u64 = 0,

    fn owns(self: *const Session, name: []const u8, sub: ?[]const u8) bool {
        if (!std.mem.eql(u8, self.name, name)) return false;
        if (self.sub) |mine| return sub != null and std.mem.eql(u8, mine, sub.?);
        return sub == null;
    }

    /// Drop the retained ANSWER — its fill borrow, its copper and its evidence —
    /// and reclaim the arena that held them. The design and its placement stay.
    fn dropBoard(self: *Session) void {
        self.held.release();
        self.prior = .{};
        self.tracks = &.{};
        self.vias = &.{};
        self.primed = false;
        _ = self.board_arena.reset(.retain_capacity);
    }

    /// Drop the retained DESIGN as well: the placement, its read-set, and the
    /// arena all three lived in.
    fn dropDesign(self: *Session) void {
        self.dropBoard();
        if (self.files) |files| files.deinit();
        self.files = null;
        self.placement = null;
        self.edge = null;
        self.design = .{};
        _ = self.design_arena.reset(.free_all);
    }

    /// Discard a rebuild that was never adopted.
    fn dropPending(self: *Session) void {
        if (self.pending) |*pending| pending.deinit();
        self.pending = null;
    }

    fn destroy(self: *Session, backing: std.mem.Allocator) void {
        self.held.release();
        if (self.files) |files| files.deinit();
        self.dropPending();
        self.board_arena.deinit();
        self.design_arena.deinit();
        backing.free(self.name);
        if (self.sub) |sub| backing.free(sub);
        backing.destroy(self);
    }
};

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

    pub fn deinit(self: *Store) void {
        const backing = self.allocator orelse return;
        for (&self.sessions) |*slot| {
            if (slot.*) |session| session.destroy(backing);
            slot.* = null;
        }
        self.* = .{};
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
        session.* = .{
            .design_arena = std.heap.ArenaAllocator.init(backing),
            .board_arena = std.heap.ArenaAllocator.init(backing),
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
        if (session.pending == null) session.pending = std.heap.ArenaAllocator.init(session.design_arena.child_allocator);
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
        const set = files orelse return;
        const pending = session.pending orelse return;
        // A rebuilt design invalidates every board answer taken against the old
        // one, its read-set, and the arena all of it lived in.
        session.dropBoard();
        if (session.files) |old| old.deinit();
        session.design_arena.deinit();
        session.design_arena = pending;
        session.pending = null;
        session.files = set;
        session.placement = board;
        session.design = self.design;
        session.edge = drc_rules.sharedEdgeField(session.design_arena.allocator(), board) catch null;
    }

    /// The board-edge margin field this placement's fills all start from.
    pub fn edgeField(self: Lease) ?drc_rules.EdgeField {
        const session = self.session orelse return null;
        return session.edge;
    }

    /// Run the check, scoped when this session can answer for the board the
    /// last one left and the request did not ask for a full pass.
    pub fn reconcile(self: *Lease, alloc: std.mem.Allocator, in: Check) Report {
        const session = self.session orelse return .{ .report = fullCheck(alloc, in), .scoped = false };
        if (!self.scopable(session, in)) return self.prime(alloc, in);
        const prior = router.RouteResult{ .tracks = session.tracks, .vias = session.vias, .routed = 0, .total = 0 };
        const delta = drc_rules.diffCopper(alloc, prior, in.copper.routed, in.copper.placement.nets.len) catch
            return self.prime(alloc, in);
        const scoped = drc_rules.checkScopedZonesTally(alloc, in.project_dir, in.name, in.copper, session.prior, delta);
        if (!scoped.scoped) return self.prime(alloc, in);
        self.retain(scoped, in.copper.routed);
        return .{
            .report = .{ .violations = scoped.violations, .tally = scoped.tally },
            .scoped = true,
            .fills = scoped.reuse.fills,
            .fills_repoured = scoped.reuse.repoured,
            .delta = delta.count,
        };
    }

    /// Can this session answer incrementally? Only when it already holds an
    /// answer for the same design and the same board, and the caller did not
    /// ask for the full path.
    fn scopable(self: Lease, session: *const Session, in: Check) bool {
        if (in.full or !session.primed) return false;
        if (!session.design.eql(self.design)) return false;
        return session.board.eql(in.board);
    }

    /// A full check that also leaves the session able to scope the next one.
    fn prime(self: *Lease, alloc: std.mem.Allocator, in: Check) Report {
        const session = self.session orelse return .{ .report = fullCheck(alloc, in), .scoped = false };
        const primed = drc_rules.checkPrimingZonesTally(alloc, in.project_dir, in.name, in.copper);
        if (!primed.scoped) return .{ .report = fullCheck(alloc, in), .scoped = false };
        session.design = self.design;
        session.board = in.board;
        self.retain(primed, in.copper.routed);
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
    fn retain(self: *Lease, result: drc_rules.ScopedApiReport, routed: router.RouteResult) void {
        const session = self.session orelse return;
        // Build the new snapshot in a FRESH arena and swap it in, rather than
        // resetting the old one and copying into the space it just gave back.
        // A scoped pass carries the previous snapshot's deferred findings
        // forward BY REFERENCE, so the memory being copied from is the memory a
        // reset would have handed straight back to the copy — an alias, and a
        // panic on the first edit after the first one.
        var fresh = std.heap.ArenaAllocator.init(session.design_arena.child_allocator);
        const alloc = fresh.allocator();
        var next = result;
        const kept = retainPrior(alloc, result.prior);
        const tracks = alloc.dupe(router.Track, routed.tracks) catch null;
        const vias = alloc.dupe(router.Via, routed.vias) catch null;
        if (kept == null or tracks == null or vias == null) {
            // Nothing can be retained, so nothing may claim to be: release this
            // pass's borrow and let the next request prime again.
            fresh.deinit();
            next.held.release();
            session.dropBoard();
            return;
        }
        var old = session.board_arena;
        var prior_held = session.held;
        session.board_arena = fresh;
        session.prior = kept.?;
        session.held = next.held;
        session.tracks = tracks.?;
        session.vias = vias.?;
        session.primed = true;
        // The previous generation's borrow goes back only now: every raster
        // this snapshot reuses was re-borrowed through the memo by the pass
        // above, so it holds its own reference and outlives this release.
        prior_held.release();
        old.deinit();
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
    return .{ .fill_keys = fill_keys, .spec_keys = spec_keys, .pour_audit = audit, .deferred = deferred };
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

/// Answer this request with a status and end the lease. Always null, so a
/// caller writes `orelse return fail(...)`.
fn fail(lease: *Lease, res: *httpz.Response, status: u16, message: []const u8) ?Resolved {
    if (lease.session) |session| session.dropDesign();
    lease.release();
    res.status = status;
    res.body = message;
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

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
        \\  (design-rules (stackup 4) (plane 2 "GND") (pour top "GND") (ground-via-max 1.0))
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

    // The same state through the forced-full escape hatch is the same answer.
    const forced = try drcApiBody(alloc, &state, project, edited, true);
    try testing.expect(std.mem.indexOf(u8, forced, "\"scoped\":false") != null);
    try testing.expectEqualStrings(drcApiFindings(forced), drcApiFindings(scoped));
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
    try testing.expectEqualStrings(drcApiFindings(back_to_scoped), drcApiFindings(after_edit));

    // With no store at all every request is a full check — and the same one.
    var bare = serve_root.ServerState{};
    const unretained = try drcApiBody(alloc, &bare, project, edited, false);
    try testing.expect(std.mem.indexOf(u8, unretained, "\"scoped\":false") != null);
    try testing.expectEqualStrings(drcApiFindings(forced), drcApiFindings(unretained));
}

// spec: Web Server - A reconcile snapshot that carries the previous one's deferred findings forward is retained without aliasing the memory it copies from
test "a retained snapshot survives being replaced by one that carries it forward" {
    var store = Store{ .allocator = testing.allocator };
    defer store.deinit();
    var lease = acquire(&store, testing.allocator, "alpha", null, .{});
    defer lease.release();
    const session = lease.session.?;
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

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
