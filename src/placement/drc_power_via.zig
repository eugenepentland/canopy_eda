//! Continuous-current capacity of every routed power VIA barrel.
//!
//! A separate file because `drc.zig` is at its guardian file-size cap, on the
//! precedent of `drc_diffpair.zig` / `drc_keepout.zig` / `drc_match.zig`: the
//! rule is called from one line in `checkImpl` and owns its own fixtures.
//!
//! The measurement it makes is the one the board never had. Trace width has
//! had an IPC-2221 rule for as long as rails have declared load; a via barrel
//! had none, and the pre-route geometry compensated by fattening EVERY barrel
//! on a rail to the drill ONE barrel would need for the whole rail current.
//! That is the wrong shape of answer twice over: the current solver splits a
//! rail between parallel barrels, so two ordinary vias side by side legitimately
//! share a load that neither could carry alone; and a fattened barrel that
//! cannot clear its neighbours turns an electrical margin into a routing
//! failure. So routing now uses the class/board via geometry, and this rule
//! says — after the fact, where the copper actually is — which transitions
//! need another barrel.
//!
//! Two verdicts, two kinds:
//!
//!   • `via_current` (`"via current"`), an ERROR. The net's current solve
//!     resolved, so `power_integrity` knows this barrel's own share, and more
//!     current through it than its plated area can carry is undersized power
//!     copper like any other. The number of barrels the transition needs is
//!     exactly `ceil(gap / clearance)`.
//!   • `via_current_envelope` (`"via current envelope"`), a WARNING. The solve
//!     did not resolve (a renamed source terminal, an incomplete consumer
//!     annotation), so every barrel is conservatively charged the WHOLE rail.
//!     That is an upper bound on any one barrel, not a measurement, so it must
//!     not block a fab — and it is raised only when the rail envelope also
//!     exceeds the SUMMED capacity of the same-net barrels stitched beside it.
//!     A properly stitched transition must not be flagged merely because a
//!     solve failed somewhere else on the board.
//!
//! Neither kind is DEFERRED. The rule lives inside `drc.checkImpl`, so a
//! scoped recheck (`drc_compose.checkScopedReport` → `checkWithPreparedCopper`)
//! recomputes it in full exactly as a cold pass does, and `netlisp drc-dump
//! --scoped` therefore compares both kinds on both sides rather than excluding
//! them the way it excludes the three return-path kinds. `--mutate` / `--prime`
//! need nothing either: the requirement is derived from the copper handed in,
//! and the fills it may consult are the same content-keyed fills every other
//! rule reuses. It IS deferred on the CLIENT, where the WASM bridge marshals no
//! rail current at all (`wasm_drc.zig`), which is a marshalling fact rather
//! than a scoping decision.
//!
//! TWO kinds rather than one kind at two severities, because `drc.zig` holds
//! the invariant that a kind's emitted severity is its `defaultSeverity` — the
//! same reason the track rule spells its unsolved verdict `power_width_envelope`
//! — and because a design overriding the severity of the measured rule should
//! not silently promote a conservative bound to a fab blocker.

const std = @import("std");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const pour = @import("pour.zig");
const power_integrity = @import("power_integrity.zig");
const router = @import("router.zig");

/// How far apart two same-net barrels may sit and still be credited as one
/// parallel group by the ENVELOPE verdict. A ground/power layer transition is
/// stitched with its return and redundancy vias inside a couple of millimetres;
/// beyond that the barrels belong to different parts of the rail and cannot be
/// assumed to share a transition's current.
const parallel_radius_mm: f64 = 2.0;

/// Slack on a current comparison. Capacity and solved current are both
/// floating-point results of the same screen, so a barrel resting exactly on
/// its rating is legal — the same convention `drc.eps` sets for geometry.
const current_eps_a: f64 = 1e-9;

/// Judge every routed barrel against the current it carries.
///
/// `prepared` is the reporting seam's already-poured fills (a plane-backed rail
/// is only locally solvable against them); `fills` is the memo an ordinary
/// caller can pour through. Exactly one is ever set, and both null is the
/// unmemoised spelling. A board with no declared rail current produces no
/// findings and pays for no solve, which is what makes this rule server-only:
/// the WASM bridge marshals no rail currents at all.
pub fn check(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    routed: router.RouteResult,
    prepared: ?drc.PreparedCopper,
    fills: ?pour.FillMemo,
) std.mem.Allocator.Error!void {
    const requirements = if (prepared) |copper|
        try power_integrity.routedViaRequirementsPrepared(
            arena,
            placement,
            routed,
            copper.plane_fills,
            copper.zones,
            copper.zone_fills,
        )
    else
        try power_integrity.routedViaRequirementsMemo(arena, placement, routed, fills);
    try report(arena, out, routed, requirements);
}

/// The verdict itself, over requirements already in hand.
fn report(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    routed: router.RouteResult,
    requirements: []const ?power_integrity.ViaCurrent,
) std.mem.Allocator.Error!void {
    for (routed.vias, 0..) |via, index| {
        if (index >= requirements.len) break;
        const want = requirements[index] orelse continue;
        // A barrel with no plated area has no capacity answer; its geometry is
        // the drill station's business (`min_drill` / `annular`), not this
        // rule's. A barrel carrying nothing is simply passing copper.
        if (!(want.capacity_a > 0) or !(want.current_a > 0)) continue;
        if (want.current_a <= want.capacity_a + current_eps_a) continue;
        if (!want.envelope) {
            try append(arena, out, via, index, want, .via_current);
            continue;
        }
        if (want.current_a <= parallelCapacityA(routed, requirements, index) + current_eps_a) continue;
        try append(arena, out, via, index, want, .via_current_envelope);
    }
}

/// Summed capacity of the same-net barrels within `parallel_radius_mm` of via
/// `index`, itself included — what a stitched transition can carry between them.
fn parallelCapacityA(
    routed: router.RouteResult,
    requirements: []const ?power_integrity.ViaCurrent,
    index: usize,
) f64 {
    const via = routed.vias[index];
    var total: f64 = 0;
    for (routed.vias, 0..) |other, j| {
        if (other.net != via.net or j >= requirements.len) continue;
        const near = requirements[j] orelse continue;
        if (!(near.capacity_a > 0)) continue;
        if (std.math.hypot(other.x - via.x, other.y - via.y) > parallel_radius_mm) continue;
        total += near.capacity_a;
    }
    return total;
}

/// One finding at the barrel: `gap` is the current through it, `clearance` the
/// current it can carry, so `ceil(gap / clearance)` is exactly the number of
/// barrels this transition needs and needs no field of its own. `track_a` is
/// the via index, the spelling `drc.Parties` already reserves for a barrel.
fn append(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    via: router.Via,
    index: usize,
    want: power_integrity.ViaCurrent,
    kind: drc.Kind,
) std.mem.Allocator.Error!void {
    try out.append(arena, .{
        .x = via.x,
        .y = via.y,
        .gap = want.current_a,
        .clearance = want.capacity_a,
        .kind = kind,
        .severity = drc.defaultSeverity(kind),
        .who = .{ .net_a = via.net, .track_a = drc.partyIndex(index) },
    });
}

const testing = std.testing;
const geometry = @import("geometry.zig");
const power_budget = @import("../eval/power_budget.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// A plated barrel this small carries about 0.57 A at the screen's 10 °C rise —
/// the ordinary board default, and the geometry every fixture below routes with.
const fixture_drill_mm: f64 = 0.2;
const fixture_dia_mm: f64 = 0.4;
const fixture_plating_mm: f64 = 0.020;

fn fixtureVia(x: f64, y: f64) router.Via {
    return .{ .x = x, .y = y, .dia = fixture_dia_mm, .drill = fixture_drill_mm, .net = 0 };
}

/// One VDD rail fed by `src/U1` and loaded by `load/U1`, on a two-layer board.
/// `source` is the declared source terminal path: the real one solves, a
/// missing one leaves the axis unsolved and exercises the envelope verdict.
fn fixture(
    parts: []optimizer.Part,
    nets: []const optimizer.FlatNet,
    rails: []const power_budget.Rail,
    foils: []const @import("impedance.zig").Foil,
) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = -1,
        .maxx = 4,
        .maxy = 1,
        .generated = true,
        .rules = .{
            .copper_layers = 2,
            .physical = .{
                .board_thickness = 1.6,
                .via_plating_mm = fixture_plating_mm,
                .stack = .{ .layers = 2, .foils = foils, .board_mm = 1.6 },
                .rails = rails,
            },
        },
    };
}

/// The one thru-hole land both fixture parts carry, so a contact joins copper
/// on either layer and the fixtures stay two-layer without a pad-side story.
const fixture_pad = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2, .thru = true };
const fixture_pads = [_]geometry.Pad{fixture_pad};
const fixture_foils = [_]@import("impedance.zig").Foil{
    .{ .index = 1, .thickness_mm = 0.035 },
    .{ .index = 2, .thickness_mm = 0.035 },
};

/// Every slice the placement hands the solver has to OUTLIVE `init`, so each
/// array lives in the rig and `placement` binds the slices to `self`. A
/// `&.{runtime}` literal inside `init` would be a pointer into its own frame.
const Rig = struct {
    arena: std.heap.ArenaAllocator,
    parts: [2]optimizer.Part,
    pins: [2]flat_netlist.FlatPin,
    nets: [1]optimizer.FlatNet,
    consumers: [1]power_budget.RailConsumer,
    terminals: [1][]const u8,
    rails: [1]power_budget.Rail,

    fn init(amps: f64, source: []const u8) Rig {
        return .{
            .arena = std.heap.ArenaAllocator.init(testing.allocator),
            .parts = .{
                .{ .ref_des = "src/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &fixture_pads, .fallback = false, .x = 0, .y = 0 },
                .{ .ref_des = "load/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &fixture_pads, .fallback = false, .x = 4, .y = 0 },
            },
            .pins = .{
                .{ .ref_des = "src/U1", .pin = "1" },
                .{ .ref_des = "load/U1", .pin = "1" },
            },
            .nets = .{.{ .name = "VDD", .pins = &.{} }},
            .consumers = .{.{ .ref_des = "load/U1", .net = "VDD", .pins = &.{"1"}, .i_typ = amps, .i_max = amps }},
            .terminals = .{source},
            .rails = .{.{
                .net = "VDD",
                .load_typ_a = amps,
                .load_max_a = amps,
                .any_typ_load = true,
                .any_max_load = true,
                .status = .no_source,
            }},
        };
    }

    fn placement(self: *Rig) optimizer.Placement {
        self.nets[0].pins = &self.pins;
        self.rails[0].consumers = &self.consumers;
        self.rails[0].source_terminals = &self.terminals;
        return fixture(&self.parts, &self.nets, &self.rails, &fixture_foils);
    }

    fn deinit(self: *Rig) void {
        self.arena.deinit();
    }
};

/// A source track, one barrel per site, and a return track — the series
/// spelling, where every barrel carries the whole load.
fn seriesCopper(vias: []const router.Via, tracks: []const router.Track) router.RouteResult {
    return .{ .tracks = tracks, .vias = vias, .routed = 1, .total = 1 };
}

// spec: placement/drc - a routed power via carrying more than its plated barrel can take is a fab-blocking error naming how many barrels the transition needs
test "an over-current power via is an error carrying its required barrel count" {
    var rig = Rig.init(0.62, "src/VOUT");
    defer rig.deinit();
    const arena = rig.arena.allocator();
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 1, .width = 0.5, .net = 0 },
    };
    const vias = [_]router.Via{fixtureVia(2, 0)};
    const routed = seriesCopper(&vias, &tracks);

    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, rig.placement(), routed, null, null);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    const hit = out.items[0];
    try testing.expectEqual(drc.Kind.via_current, hit.kind);
    try testing.expectEqual(drc.Severity.err, hit.severity);
    try testing.expectEqual(@as(i32, 0), hit.who.net_a);
    try testing.expectEqual(@as(i32, 0), hit.who.track_a);
    try testing.expectApproxEqAbs(@as(f64, 0.62), hit.gap, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.57), hit.clearance, 0.01);
    // The repair count a message reads out: two barrels for this current, so
    // one more than the board has. The finding carries it without a field of
    // its own — `ceil(gap/clearance)` IS `ViaCurrent.requiredCount`.
    const requirements = try power_integrity.routedViaRequirements(arena, rig.placement(), routed);
    try testing.expectEqual(@as(usize, 2), requirements[0].?.requiredCount());
    try testing.expect(hit.gap > hit.clearance and hit.gap < 2 * hit.clearance);
}

// spec: placement/drc - two parallel same-net barrels that the current solve proves share a load each pass on their own share, with no special case
test "parallel power vias sharing a solved load are not flagged" {
    var rig = Rig.init(0.8, "src/VOUT");
    defer rig.deinit();
    const arena = rig.arena.allocator();
    // Two symmetric stubs off one feed: the solver splits the rail between the
    // barrels by resistance, and neither share exceeds a barrel's capacity.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = 0.4, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = -0.4, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0.4, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = -0.4, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 1, .width = 0.5, .net = 0 },
    };
    const vias = [_]router.Via{ fixtureVia(2, 0.4), fixtureVia(2, -0.4) };
    const routed = seriesCopper(&vias, &tracks);
    const placement = rig.placement();

    // The solve really did resolve and really did split it — otherwise this
    // test would be passing on the envelope path instead of the one it names.
    const requirements = try power_integrity.routedViaRequirements(arena, placement, routed);
    try testing.expect(!requirements[0].?.envelope);
    try testing.expect(requirements[0].?.current_a < requirements[0].?.capacity_a);
    try testing.expectApproxEqAbs(
        @as(f64, 0.8),
        requirements[0].?.current_a + requirements[1].?.current_a,
        1e-6,
    );

    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, placement, routed, null, null);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// spec: placement/drc - an unsolved rail charges every barrel the whole envelope, warning only where the stitched same-net barrels beside it cannot carry it together
test "an unsolved rail credits a stitched barrel group and warns on a lone barrel" {
    // The declared source terminal names a module this board does not have, so
    // the axis cannot be solved and each barrel is charged the whole rail.
    var stitched = Rig.init(0.8, "missing/VOUT");
    defer stitched.deinit();
    const arena = stitched.arena.allocator();
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = 0.4, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = -0.4, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0.4, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = -0.4, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 1, .width = 0.5, .net = 0 },
    };
    const pair = [_]router.Via{ fixtureVia(2, 0.4), fixtureVia(2, -0.4) };
    const stitched_routed = seriesCopper(&pair, &tracks);
    const stitched_placement = stitched.placement();

    // Unsolved, and each barrel alone is under the 0.8 A envelope…
    const requirements = try power_integrity.routedViaRequirements(arena, stitched_placement, stitched_routed);
    try testing.expect(requirements[0].?.envelope);
    try testing.expectApproxEqAbs(@as(f64, 0.8), requirements[0].?.current_a, 1e-12);
    try testing.expect(requirements[0].?.capacity_a < 0.8);

    // …but 0.8 mm apart they are one transition, and together they carry it.
    var quiet: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &quiet, stitched_placement, stitched_routed, null, null);
    try testing.expectEqual(@as(usize, 0), quiet.items.len);

    // The same rail through ONE barrel has nothing beside it to credit.
    var lone = Rig.init(0.62, "missing/VOUT");
    defer lone.deinit();
    const lone_arena = lone.arena.allocator();
    const lone_tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 1, .width = 0.5, .net = 0 },
    };
    const one = [_]router.Via{fixtureVia(2, 0)};
    var warned: std.ArrayList(drc.Violation) = .empty;
    try check(lone_arena, &warned, lone.placement(), seriesCopper(&one, &lone_tracks), null, null);
    try testing.expectEqual(@as(usize, 1), warned.items.len);
    try testing.expectEqual(drc.Kind.via_current_envelope, warned.items[0].kind);
    // A conservative upper bound is not a measurement: it must not block a fab.
    // This is also where `drc.zig` delegates proving that kind's severity.
    try testing.expectEqual(drc.Severity.warn, warned.items[0].severity);
    try testing.expectEqual(drc.defaultSeverity(.via_current_envelope), warned.items[0].severity);
}

// spec: placement/drc - a board that declares no rail current runs no via-capacity solve and reports no barrel findings
test "a rail-less board produces no via-current findings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{};
    const nets = [_]optimizer.FlatNet{.{ .name = "VDD", .pins = &.{} }};
    const placement = fixture(&parts, &nets, &.{}, &fixture_foils);
    const vias = [_]router.Via{fixtureVia(2, 0)};

    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, placement, seriesCopper(&vias, &.{}), null, null);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
