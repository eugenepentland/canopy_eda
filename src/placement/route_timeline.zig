//! Route timeline + progress recording — the router's audit trail.
//!
//! One meaningful router decision per event, in chronological order, each
//! carrying the exact board copper immediately after it. This deliberately
//! records net / pass / rip-up decisions rather than every Dijkstra node
//! expansion: the former is the useful audit trail, while the latter would be
//! millions of implementation-detail frames on a full board.
//!
//! Recording is opt-in (`TimelineRecorder.enabled`) and costs nothing when off,
//! so the batch/CLI path pays for none of it. A live routing job additionally
//! hangs a `route_policy.ProgressSink` off the recorder and streams each event
//! to the browser as it is decided.
//!
//! Split out of `router.zig`: the recorder observes the copper the maze
//! produces and never influences it, so it shares only the plain `Track`/`Via`
//! /`RouteResult` types with the engine.

const std = @import("std");
const router = @import("router.zig");
const route_policy = @import("route_policy.zig");

const Track = router.Track;
const Via = router.Via;

/// Total centreline length of `tracks` (mm) — the timeline's per-event trace
/// metric, and the tie-break a rip-up transaction scores candidates on.
pub fn traceLen(tracks: []const Track) f64 {
    var s: f64 = 0;
    for (tracks) |t| s += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    return s;
}

/// One meaningful router decision in chronological order. This deliberately
/// records net/pass/rip-up decisions rather than every Dijkstra node expansion:
/// the former is the useful audit trail, while the latter would be millions of
/// implementation-detail frames on a full board.
pub const RouteEventKind = enum {
    /// The pre-route board state (retained copper only). A live progress sink
    /// that sees a SECOND `.initial` should reset its accumulated view: it means
    /// the run restarted from scratch on a finer grid (see `routeWithCapture`).
    initial,
    plane_routed,
    plane_failed,
    net_routed,
    net_failed,
    ripup,
    reroute_candidate,
    reroute_accepted,
    reroute_rejected,
    escape_stubs,
    return_stitching,
    /// Redundant layer hops were deleted — a via pair whose detour redrew on
    /// the layer both its ends already used (`dropRedundantViaPairs`).
    via_hops,
    bend_smoothing,
    /// An interactive routing session presented this net as a stuck-point
    /// (the standard pipeline's automatic passes could not route it).
    stuck,
    /// A human hint was applied to the current stuck net before its retry;
    /// the one-line hint description rides in `RouteEvent.detail`.
    hint_applied,
    complete,
};

/// A decision label plus the exact copper state immediately after it.
pub const RouteEvent = struct {
    kind: RouteEventKind,
    /// Primary net index, when this decision concerns one net.
    net: ?usize = null,
    /// All nets participating in a rip-up transaction (target first).
    related_nets: []const usize = &.{},
    /// One-based rip-up round, 0 outside the bounded rip-up pass.
    round: usize = 0,
    /// Free-form one-line label for a `hint_applied` decision (the interactive
    /// session's human-readable hint description); empty for every other kind.
    detail: []const u8 = "",
    /// The routing geometry the attempt that captured this event searched on.
    /// Constant across an attempt; carried per event so any single event is
    /// self-sufficient for rebuilding the router's view of the board.
    pass: PassContext = .{},
    state: RouteEventState,
};

/// The cumulative route metrics and exact board copper at one decision.
pub const RouteEventState = struct {
    routed: usize,
    total: usize,
    trace_mm: f64,
    tracks: []const Track,
    vias: []const Via,
};

/// The routing geometry one attempt searched on — everything about the maze's
/// view of the board that a caller holding only the design and this timeline
/// cannot re-derive.
///
/// It exists so the route-vision overlay can rebuild the router's free-space
/// mask for a recorded decision *exactly*. The grid is resolved from the widest
/// net class, the selected-net subset and the resolution scale, and a run may
/// restart on a finer grid — so "recompute the grid from the design" is not
/// reproducible in general. Recording the resolved lattice makes it so.
///
/// One value per `routeOnce` attempt: the grid is fixed for an attempt's whole
/// life (a fine-grid restart is a *new* attempt, announced by a second
/// `.initial` event), so it is stamped once at context construction and rides
/// every event that attempt captures.
///
/// `g == 0` means "not recorded" — a timeline replayed from before this was
/// captured. Consumers must treat that as "vision unavailable" rather than
/// guessing a lattice.
/// `null` grid means "not recorded" — a timeline replayed from before this was
/// captured. Consumers must treat that as "vision unavailable" rather than
/// guessing a lattice.
pub const PassContext = struct {
    /// The resolved lattice this attempt searched on.
    grid: ?router.Grid = null,
    /// Signal-layer count this attempt routed on (`Ctx.occ.len`).
    n_signal: u8 = 0,
    /// The caller's BASE geometry, before any per-net `(net-class …)` overlay.
    /// The overlay is a pure function of the net index, so it is reapplied at
    /// reconstruction rather than recorded per event.
    base: router.RouteParams = .{},
    /// Whether a declared pour covers the top / bottom outer signal layer.
    pour: [2]bool = .{ false, false },
    /// Resolution scale this attempt resolved to (1 = base pitch).
    grid_scale: f64 = 1,

    /// True when this context carries a usable lattice.
    pub fn recorded(self: PassContext) bool {
        const grid = self.grid orelse return false;
        return grid.g > 0 and grid.nx > 0 and grid.ny > 0 and self.n_signal > 0;
    }
};

/// Opt-in review result. Ordinary `routeWithOptions` callers still receive the
/// compact final `RouteResult`; review callers explicitly request this wrapper.
pub const RouteRun = struct {
    routed: router.RouteResult,
    timeline: []const RouteEvent,
    /// The geometry the run's final attempt searched on (see `PassContext`).
    pass: PassContext = .{},
};

/// One decision label about to be captured, before the copper is duped in.
pub const TimelineMark = struct {
    kind: RouteEventKind,
    net: ?usize = null,
    related_nets: []const usize = &.{},
    round: usize = 0,
    detail: []const u8 = "",
    routed: usize,
};

/// The timeline itself: an append-only event log plus the optional live sink.
pub const TimelineRecorder = struct {
    arena: std.mem.Allocator,
    enabled: bool,
    events: std.ArrayList(RouteEvent) = .empty,
    /// Live streaming hook: invoked synchronously after each event is appended,
    /// so a background job can push a route to the browser as it is decided.
    /// Null (the batch/CLI default) and never fires unless the timeline is
    /// enabled — the live job always enables it.
    sink: ?route_policy.ProgressSink = null,
    /// The routing geometry this attempt searched on, stamped once at context
    /// construction (`router.notePass`) and copied onto every event captured
    /// afterwards. Left at its zero default by callers that never stamp it,
    /// which reads downstream as "vision unavailable".
    pass: PassContext = .{},

    /// Append one decision plus a private copy of the board copper as it stands
    /// right now, then stream it to the live sink. A no-op when recording is
    /// off, so the batch path pays nothing for the hook.
    pub fn capture(
        self: *TimelineRecorder,
        mark: TimelineMark,
        tracks: []const Track,
        vias: []const Via,
    ) std.mem.Allocator.Error!void {
        if (!self.enabled) return;
        try self.events.append(self.arena, .{
            .kind = mark.kind,
            .net = mark.net,
            .related_nets = try self.arena.dupe(usize, mark.related_nets),
            .round = mark.round,
            .detail = try self.arena.dupe(u8, mark.detail),
            .pass = self.pass,
            .state = .{
                .routed = mark.routed,
                .total = 0,
                .trace_mm = traceLen(tracks),
                .tracks = try self.arena.dupe(Track, tracks),
                .vias = try self.arena.dupe(Via, vias),
            },
        });
        // Stream the just-appended, arena-owned event. The pointer is valid only
        // for this synchronous call — a later capture may grow (reallocate)
        // `events` — and `state.total` is still 0 here (backfilled at `finish`).
        if (self.sink) |sink| {
            const ev: *const RouteEvent = &self.events.items[self.events.items.len - 1];
            sink.emit(sink.ctx, ev);
        }
    }

    /// Close the log and hand over its events. `total` is backfilled into every
    /// event's state (the net count is only known once the run ends), so a
    /// replay can show each decision against the run's final denominator.
    pub fn finish(self: *TimelineRecorder, total: usize) std.mem.Allocator.Error![]const RouteEvent {
        if (!self.enabled) return &.{};
        for (self.events.items) |*event| event.state.total = total;
        return self.events.toOwnedSlice(self.arena);
    }
};

/// A run's cumulative counters plus its timeline.
pub const RouteProgress = struct {
    routed: usize = 0,
    total: usize = 0,
    plane_routed: usize = 0,
    failed: std.ArrayList([]const u8) = .empty,
    timeline: TimelineRecorder,
};
