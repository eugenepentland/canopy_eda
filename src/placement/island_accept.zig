//! Transactional commit for ONE island-joining hop on a pour-carried net.
//!
//! `closeGaps` reports each hop's copper independently precisely so the caller
//! can weigh it: the router cannot see the pour engine's credit rules, so a via
//! that lands where a higher-priority pour clips it — or beside a pad the fill
//! never reaches — is copper that joins nothing. The post-route gate keeps every
//! hop that did not RIP (`route_close.keepAdditiveOnly`), which is the right
//! rule for a two-pad bridge (the maze reached both pads or it produced nothing
//! at all) and the wrong one for a stitch: a barrel is "landed" whether or not
//! the metal it drops into is the metal its island needed.
//!
//! A poured rail is where that matters. Board A's `V_3V3A` is carried by a
//! retained In3.Cu zone and comes out of a timed route in EIGHT copper islands,
//! so closing it is eight independent stitches — and an earlier in-place stitch
//! pass that committed them unweighed measured 102 -> 98 connected nets.
//!
//! So each hop is a TRANSACTION here:
//!
//!   1. its copper is appended to a FRESH candidate array — the committed board
//!      is never written through, so a refusal has nothing to roll back;
//!   2. the fabrication oracle weighs the whole board with and without it, and
//!      the candidate is adopted only when no net the committed board connected
//!      is left open AND either one more net is connected or this net holds one
//!      fewer copper island (`fine_accept.mergesIslands`); and
//!   3. the geometric DRC error count must not rise, ratcheting DOWN whenever a
//!      hop lands with fewer — the same monotone promise `mcp_close_gaps` makes,
//!      and the reason a stitch cannot buy connectivity with illegal copper.
//!
//! Nothing here decides WHICH hop to try or where; that stays with the planner
//! that already reads the oracle's island report (`route_close.planHops`).

const std = @import("std");
const drc = @import("drc.zig");
const fine_accept = @import("fine_accept.zig");
const optimizer = @import("optimizer.zig");
const route_policy = @import("route_policy.zig");
const router = @import("router.zig");

// Per-hop accept/refuse trace (debug level: dev servers only).
const ledgerLog = std.log.debug;

/// Most oracle evaluations one ledger will pay for. Each is two whole-board
/// connectivity passes, so the bound is what keeps a transactional pass a small
/// share of a timed route: the planner's own hop budget is the other half, and
/// a pass arriving past this is refused rather than admitted unmeasured.
pub const max_evaluations: usize = 48;

/// One hop as the ledger judges it: the copper `closeGaps` produced, and the
/// flattened-net index it was requested for.
pub const Hop = struct {
    net_i: usize,
    path: router.GapPath,
};

/// The running board a sequence of island transactions is judged against.
///
/// Stateful for two reasons, both of which are what "one island at a time"
/// means: the connectivity gate is built once and reused (naming the board's
/// pours for the oracle is not free), and the DRC ceiling ratchets across hops
/// so errors can leave the board and never come back.
pub const Ledger = struct {
    placement: optimizer.Placement,
    params: router.RouteParams,
    zones: []const route_policy.ExistingZone,
    /// Built on first use: a route whose pour-carried nets are all whole never
    /// reaches a candidate, and should pay nothing for this pass.
    gate: ?fine_accept.Gate = null,
    /// Error-severity geometry violations on the copper this ledger last
    /// committed, ratcheted down whenever a hop lands with fewer. Null until the
    /// first candidate is weighed. Holding the STARTING count instead would let
    /// a pass spend, hop by hop, every error the board happened to open with.
    ceiling: ?usize = null,

    /// A ledger over `placement`, the route's copper rules and its retained
    /// zones. Allocation-free: the connectivity gate the first candidate needs
    /// is built then, against the arena that candidate arrives with.
    pub fn init(
        placement: optimizer.Placement,
        params: router.RouteParams,
        zones: []const route_policy.ExistingZone,
    ) Ledger {
        return .{ .placement = placement, .params = params, .zones = zones };
    }

    /// Release the connectivity gate's measurement scratch, if one was built.
    pub fn deinit(self: *Ledger) void {
        if (self.gate) |*g| g.deinit();
        self.gate = null;
    }

    /// Fold `hop`'s copper onto `board` when the fabrication oracle says the
    /// board improved and the geometry DRC says it did not get worse. Returns
    /// the new board, or null when the hop is refused — `board` is never written
    /// through, so a refusal costs nothing to undo and leaves the next hop
    /// routing against exactly the copper this one was offered.
    pub fn commit(
        self: *Ledger,
        arena: std.mem.Allocator,
        board: router.RouteResult,
        hop: Hop,
    ) std.mem.Allocator.Error!?router.RouteResult {
        // A hop that had to move foreign copper is a rip-and-repair
        // transaction, which belongs to the finishing pass rather than to a
        // post-route gate that must never be able to make a board worse.
        if (hop.path.ripped.len > 0) {
            ledgerLog("island hop net_i={d}: refused, ripped copper", .{hop.net_i});
            return null;
        }
        if (hop.path.tracks.len == 0 and hop.path.vias.len == 0) {
            ledgerLog("island hop net_i={d}: refused, empty path", .{hop.net_i});
            return null;
        }
        const candidate = try appended(arena, board, hop.path);
        const gate = try self.gateFor(arena);
        // Both boards carry their curved copper: this pass runs AFTER the route
        // finished, so the arcs and swept RF tapers a hop is weighed against are
        // the ones the oracle joins pads through (`appended` keeps them).
        const merged = try gate.acceptsIslandMerge(
            hop.net_i,
            .{
                .tracks = board.tracks,
                .vias = board.vias,
                .arcs = board.arcs,
                .rf_paths = board.rf_port_outcomes,
            },
            .{
                .tracks = candidate.tracks,
                .vias = candidate.vias,
                .arcs = candidate.arcs,
                .rf_paths = candidate.rf_port_outcomes,
            },
        );
        if (!merged) {
            ledgerLog("island hop net_i={d}: refused, no island merge credited", .{hop.net_i});
            return null;
        }
        if (!try self.geometryHolds(arena, board, candidate)) {
            ledgerLog("island hop net_i={d}: refused, geometry ratchet", .{hop.net_i});
            return null;
        }
        ledgerLog("island hop net_i={d}: accepted ({d}t {d}v)", .{
            hop.net_i, hop.path.tracks.len, hop.path.vias.len,
        });
        return candidate;
    }

    fn gateFor(self: *Ledger, home: std.mem.Allocator) std.mem.Allocator.Error!*fine_accept.Gate {
        if (self.gate == null) {
            var built = try fine_accept.Gate.init(home, self.placement, self.zones);
            built.budget = max_evaluations;
            self.gate = built;
        }
        return &self.gate.?;
    }

    /// Does `candidate` leave no more error-severity geometry violations than
    /// the copper already committed? `drc.errorCount` excludes `net_open` by
    /// construction: the airwire this hop exists to close fluctuates while a
    /// many-island net is only partly joined, so counting it would reject
    /// perfectly clean copper.
    fn geometryHolds(
        self: *Ledger,
        arena: std.mem.Allocator,
        board: router.RouteResult,
        candidate: router.RouteResult,
    ) std.mem.Allocator.Error!bool {
        const cap = self.ceiling orelse try self.errors(arena, board);
        const after = try self.errors(arena, candidate);
        if (after > cap) return false;
        self.ceiling = after;
        return true;
    }

    fn errors(self: *Ledger, arena: std.mem.Allocator, routed: router.RouteResult) std.mem.Allocator.Error!usize {
        return drc.errorCount(try drc.check(arena, self.placement, routed, self.params.clearance));
    }
};

/// `board` with `path`'s copper appended, in FRESH arrays. Building the
/// candidate separately is what makes a hop a transaction: no shared router
/// buffer is written before the verdict, so a refusal is a dropped allocation
/// rather than a rollback that has to be got exactly right.
fn appended(
    arena: std.mem.Allocator,
    board: router.RouteResult,
    path: router.GapPath,
) std.mem.Allocator.Error!router.RouteResult {
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, board.tracks);
    try tracks.appendSlice(arena, path.tracks);
    var vias: std.ArrayList(router.Via) = .empty;
    try vias.appendSlice(arena, board.vias);
    try vias.appendSlice(arena, path.vias);
    var out = board;
    out.tracks = try tracks.toOwnedSlice(arena);
    out.vias = try vias.toOwnedSlice(arena);
    return out;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

const one_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};

fn ledgerPart(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &one_pad, .fallback = false, .x = x, .y = y };
}

/// Three pads on one net, R1 and R2 a millimetre apart with R3 five further on.
/// A track between R2 and R3 leaves the net in two islands, which is the shape
/// every transaction below is judged against.
fn ledgerParts() [3]optimizer.Part {
    return .{ ledgerPart("R1", 0, 0), ledgerPart("R2", 1, 0), ledgerPart("R3", 6, 0) };
}

const ledger_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "R2", .pin = "1" },
    .{ .ref_des = "R3", .pin = "1" },
};

fn ledgerPlacement(parts: []optimizer.Part, nets: []const optimizer.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 7,
        .maxy = 1,
        .generated = true,
    };
}

/// The two-island board: `SIG` on all three pads, with only R2↔R3 joined.
const split_track = [_]router.Track{.{ .x1 = 1, .y1 = 0, .x2 = 6, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};

fn splitBoard() router.RouteResult {
    return .{ .tracks = &split_track, .vias = &.{}, .routed = 0, .total = 1 };
}

// spec: placement/route-close - a pour-carried net's island-joining hop is committed only when the connectivity oracle credits it with a merged island or a closed net
test "a hop that merges two islands is committed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = ledgerParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &ledger_pins }};
    const placement = ledgerPlacement(&parts, &nets);
    var ledger = Ledger.init(placement, .{}, &.{});
    defer ledger.deinit();

    const join = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const board = splitBoard();
    const next = try ledger.commit(arena, board, .{ .net_i = 0, .path = .{ .tracks = &join } });
    try testing.expect(next != null);
    // The candidate is the committed copper PLUS the hop's, in a fresh array —
    // the board it was judged against is byte-identical afterwards.
    try testing.expectEqual(@as(usize, 2), next.?.tracks.len);
    try testing.expectEqual(@as(usize, 1), board.tracks.len);
}

// spec: placement/route-close - an island-joining hop whose copper merges no island is refused, so a stitch that lands without reaching its net's metal is never committed
test "a hop that merges nothing is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = ledgerParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &ledger_pins }};
    const placement = ledgerPlacement(&parts, &nets);
    var ledger = Ledger.init(placement, .{}, &.{});
    defer ledger.deinit();

    // Same-net copper that touches neither island: exactly what a stitch barrel
    // beside a pad the fill never reaches produces, and what the old
    // "did it rip anything?" rule kept.
    const stranded = [_]router.Track{.{ .x1 = 3, .y1 = 0.8, .x2 = 4, .y2 = 0.8, .layer = 0, .width = 0.2, .net = 0 }};
    const refused = try ledger.commit(arena, splitBoard(), .{ .net_i = 0, .path = .{ .tracks = &stranded } });
    try testing.expect(refused == null);
}

// spec: placement/route-close - an island-joining hop that had to rip foreign copper is never committed, so the post-route gate stays additive
test "a hop that ripped copper is refused without asking the oracle" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = ledgerParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &ledger_pins }};
    const placement = ledgerPlacement(&parts, &nets);
    var ledger = Ledger.init(placement, .{}, &.{});
    defer ledger.deinit();

    const join = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const ripped = [_]usize{0};
    const refused = try ledger.commit(arena, splitBoard(), .{
        .net_i = 0,
        .path = .{ .tracks = &join, .ripped = &ripped, .ripped_nets = &.{1} },
    });
    try testing.expect(refused == null);
    // Refused before any measurement — the gate was never even built.
    try testing.expect(ledger.gate == null);
}

const plane_nets = [_][]const u8{"GND"};
const top_plane = [_]optimizer.PlaneAt{.{ .index = 1, .net = "GND" }};
const cut_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};

fn cutPart(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &cut_pad, .fallback = false, .x = x, .y = y };
}

const cut_sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
const cut_gnd = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
const cut_nets = [_]optimizer.FlatNet{
    .{ .name = "SIG", .pins = &cut_sig },
    .{ .name = "GND", .pins = &cut_gnd },
};

/// A 40 x 24 mm board whose top copper is a `GND` plane, with `SIG`'s two pads
/// at the top and bottom edges so the copper joining them runs clean through
/// that plane. The plane is `GND`'s only connecting metal, and it recedes around
/// foreign copper.
fn cutBoard(parts: *[4]optimizer.Part) optimizer.Placement {
    parts.* = .{ cutPart("R1", 20, 1), cutPart("R2", 20, 23), cutPart("R3", 12, 12), cutPart("R4", 28, 12) };
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &cut_nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 40,
        .maxy = 24,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 40, .h = 24 },
        // The plane is on the TOP face and this board is cut so the track below
        // either severs it or merely slits it — a verdict decided by tenths of
        // a millimetre of keepout. So the outer face is PINNED to the 0.3 mm
        // gap an inner plane defaults to rather than taking the tighter outer
        // default, which would quietly re-decide it.
        .rules = .{
            .design = .{ .pour = .{ .clearance_outer = 0.3 } },
            .plane_nets = &plane_nets,
            .copper_layers = 2,
            .planes = .{ .declared = &top_plane },
        },
    };
}

// spec: placement/route-close - an island-joining hop that closes its own net by islanding a net the board already connected is refused
test "a hop that disconnects a bystander net is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts: [4]optimizer.Part = undefined;
    const placement = cutBoard(&parts);
    var ledger = Ledger.init(placement, .{}, &.{});
    defer ledger.deinit();

    const cutting = [_]router.Track{.{ .x1 = 20, .y1 = 1, .x2 = 20, .y2 = 23, .layer = 0, .width = 0.5, .net = 0 }};
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 2 };
    const refused = try ledger.commit(arena, empty, .{ .net_i = 0, .path = .{ .tracks = &cutting } });
    try testing.expect(refused == null);
    // SIG really did close — the refusal is about what it cost `GND`, not about
    // a hop that failed to route.
    try testing.expect(ledger.gate.?.after[0] and !ledger.gate.?.before[0]);
    try testing.expect(ledger.gate.?.before[1] and !ledger.gate.?.after[1]);
}

// spec: placement/route-close - a transactional island pass refuses, rather than admits, a hop arriving past its oracle-evaluation budget
test "a hop past the evaluation budget is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = ledgerParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &ledger_pins }};
    const placement = ledgerPlacement(&parts, &nets);
    var ledger = Ledger.init(placement, .{}, &.{});
    defer ledger.deinit();

    const join = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const hop = Hop{ .net_i = 0, .path = .{ .tracks = &join } };
    try testing.expect((try ledger.commit(arena, splitBoard(), hop)) != null);
    try testing.expectEqual(max_evaluations, ledger.gate.?.budget);
    ledger.gate.?.evaluations = max_evaluations;
    try testing.expect((try ledger.commit(arena, splitBoard(), hop)) == null);
}
