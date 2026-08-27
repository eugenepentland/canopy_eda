//! The bridge between the DESIGN's `(stackup …)` / `(net-class …)` forms and
//! the pure impedance model in `impedance.zig`. Two jobs, both small:
//!
//!   • `stackOf` — turn an evaluated `env.StackupSpec` into the `impedance.Stack`
//!     the model reads (foils, dielectric intervals, plane indices, εr).
//!   • `deriveWidths` — resolve each grounded-coplanar gap against the copper
//!     clearance floor, then fill in the track width of every resolved
//!     `NetRule` whose class declared `(impedance OHMS)` but no `(width MM)`.
//!
//! Kept out of `optimizer.zig` deliberately: that file already carries the
//! solver, the scoring and the whole net-class resolution, and this is a
//! self-contained translation between two representations with its own tests.

const std = @import("std");
const env = @import("../eval/env.zig");
const power_budget = @import("../eval/power_budget.zig");
const impedance = @import("impedance.zig");
const optimizer = @import("optimizer.zig");

const DesignBlock = env.DesignBlock;
const NetRule = optimizer.NetRule;

/// Physical/electrical facts a `BoardRules` carries off the evaluated design:
/// finished thickness for the Gerber job file, the εr/height buildup the
/// impedance model reads (`stack.layers == 0` = no stackup declared), and the
/// canonical rail budget used by post-route power-integrity screening. Keeping
/// the rails beside the stackup is intentional: a current number without the
/// copper thickness it flows through cannot produce a capacity verdict.
pub const Physical = struct {
    /// Complete boards print the deterministic short fabrication identity;
    /// reusable sub-circuits keep only the package digest.
    role: env.BoardRole = .board,
    board_thickness: f64 = 0,
    via_plating_mm: f64 = env.default_via_plating_mm,
    stack: impedance.Stack = .{},
    rails: []const power_budget.Rail = &.{},
    /// Voltage-resolved physical rail identities. PDN component models use
    /// these nominal voltages to evaluate authored DC-bias curves rather than
    /// applying one package-wide capacitance factor to every supply voltage.
    rail_specs: []const env.PowerRail = &.{},
    pdn_intents: []const env.PdnIntent = &.{},
};

/// The design's `(stackup …)` as the impedance model's `Stack`. An undeclared
/// stackup gives `layers = 0`, under which every impedance query returns null —
/// the legacy implicit 4-layer routing model is a ROUTING assumption and says
/// nothing about dielectric heights, so synthesising one here would be
/// inventing electrical facts the design never stated.
pub fn stackOf(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error!impedance.Stack {
    const s = block.stackup;
    if (!s.present) return .{};
    const planes = try arena.alloc(u8, s.planes.len);
    for (s.planes, planes) |pl, *out| out.* = pl.index;
    const dielectrics = try arena.alloc(impedance.Dielectric, s.dielectrics.len);
    for (s.dielectrics, dielectrics) |d, *out| out.* = .{
        .after_layer = d.after_layer,
        .thickness_mm = d.thickness,
        // An interval that declared no `(er X)` gets the generic FR-4 value —
        // resolved HERE rather than inside the model, so the `0 = unset`
        // sentinel never leaves the evaluator's representation.
        .er = if (d.er > 0) d.er else impedance.default_er,
    };
    const foils = try arena.alloc(impedance.Foil, s.copper.len);
    for (s.copper, foils) |c, *out| out.* = .{ .index = c.index, .thickness_mm = c.thickness };
    return .{
        .layers = s.layers,
        .planes = planes,
        .dielectrics = dielectrics,
        .foils = foils,
        .board_mm = s.thickness,
    };
}

/// Fill in the track width of every rule that declared `(impedance OHMS)` but
/// no `(width MM)`, solving it against the design's stackup on the preferred
/// signal layer.
///
/// A rule that declared no target is untouched, so this is a no-op for every
/// board that authored no impedance. A target the stackup cannot reach (no
/// reference plane, or no width inside the formula's published domain) leaves
/// `width` at 0 — the router's default — and `pcb-describe`'s `impedance`
/// block reports that layer as uncomputable rather than the width as solved.
pub fn deriveWidths(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    rules: []NetRule,
) std.mem.Allocator.Error!void {
    const board_clearance = if (block.design_rules.clearance > 0)
        block.design_rules.clearance
    else
        (optimizer.DesignRules{}).clearance;
    var needs_stack = false;
    for (rules) |*r| {
        if (r.rf.impedance.ground_gap_mm > 0) {
            // The requested CPWG slot cannot waive ordinary copper DRC. Store
            // the ACTUAL gap once so the calculator, report and pour consume
            // the same resolved geometry.
            r.rf.impedance.ground_gap_mm = @max(r.rf.impedance.ground_gap_mm, @max(board_clearance, r.clearance));
            if (r.rf.impedance.ground_gap_max_mm > 0) {
                r.rf.impedance.ground_gap_max_mm = @max(r.rf.impedance.ground_gap_max_mm, r.rf.impedance.ground_gap_mm);
            }
        }
        needs_stack = needs_stack or r.rf.impedance.ohms > 0 or r.rf.impedance.diff_ohms > 0;
    }
    if (!needs_stack) return; // no target: gap still resolves, no stack needed
    const stack = try stackOf(arena, block);
    for (rules) |*r| {
        if (r.rf.impedance.ohms <= 0 and r.rf.impedance.diff_ohms <= 0) continue;
        if (r.width > 0) continue; // an authored width always wins
        const w = if (r.rf.impedance.diff_ohms > 0) blk: {
            if (r.diff_gap < 0) continue;
            break :blk impedance.resolvedDiffWidthMmOnLayer(
                stack,
                r.rf.impedance.layer,
                r.rf.impedance.diff_ohms,
                resolvedPairGap(r.*, board_clearance),
            ) orelse continue;
        } else impedance.resolvedWidthMmOnLayerWithGroundGap(
            stack,
            r.rf.impedance.layer,
            r.rf.impedance.ohms,
            r.rf.impedance.ground_gap_mm,
        ) orelse continue;
        r.width = w;
        r.rf.impedance.width_derived = true;
    }
}

/// Actual edge-to-edge spacing used by differential impedance analysis. A
/// bare `(diff-pair)` inherits clearance; an explicit gap can never waive the
/// class/board copper-clearance floor.
pub fn resolvedPairGap(r: NetRule, board_clearance: f64) f64 {
    const clearance = @max(board_clearance, r.clearance);
    if (r.diff_gap > 0) return @max(r.diff_gap, clearance);
    return clearance;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const flat_netlist = @import("../flat_netlist.zig");

const single_net_fixture = struct {
    const pins = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]env.Net{.{ .name = "RF_IN", .pins = &pins }};
    const copper = [_]env.StackupCopper{
        .{ .index = 1, .thickness = 0.035 },
        .{ .index = 2, .thickness = 0.0152 },
        .{ .index = 3, .thickness = 0.0152 },
        .{ .index = 4, .thickness = 0.035 },
    };
    const dielectrics = [_]env.StackupDielectric{
        .{ .after_layer = 1, .kind = .prepreg, .thickness = 0.2104, .er = 4.4 },
        .{ .after_layer = 2, .kind = .core, .thickness = 1.065, .er = 4.4 },
        .{ .after_layer = 3, .kind = .prepreg, .thickness = 0.2104, .er = 4.4 },
    };
    const planes = [_]env.StackupPlane{.{ .index = 2, .net = "GND" }};
};

const differential_fixture = struct {
    const pins_p = [_]env.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const pins_n = [_]env.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const nets = [_]env.Net{
        .{ .name = "REF_P", .pins = &pins_p },
        .{ .name = "REF_N", .pins = &pins_n },
    };
    const copper = [_]env.StackupCopper{
        .{ .index = 1, .thickness = 0.035 },
        .{ .index = 2, .thickness = 0.0152 },
        .{ .index = 3, .thickness = 0.0152 },
        .{ .index = 4, .thickness = 0.0152 },
        .{ .index = 5, .thickness = 0.0152 },
        .{ .index = 6, .thickness = 0.035 },
    };
    const dielectrics = [_]env.StackupDielectric{
        .{ .after_layer = 1, .kind = .prepreg, .thickness = 0.2104, .er = 4.4 },
        .{ .after_layer = 2, .kind = .core, .thickness = 0.4, .er = 4.6 },
        .{ .after_layer = 3, .kind = .prepreg, .thickness = 0.2028, .er = 4.4 },
        .{ .after_layer = 4, .kind = .core, .thickness = 0.4, .er = 4.6 },
        .{ .after_layer = 5, .kind = .prepreg, .thickness = 0.2104, .er = 4.4 },
    };
    const planes = [_]env.StackupPlane{
        .{ .index = 2, .net = "GND" },
        .{ .index = 5, .net = "GND" },
    };
};

/// A one-net design carrying `classes`, with barracuda's real four-layer
/// buildup when `stackup` is true.
fn fixture(classes: []const env.NetClassSpec, stackup: bool) DesignBlock {
    return .{
        .name = "board",
        .instances = &.{},
        .nets = &single_net_fixture.nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_classes = classes,
        .stackup = if (stackup) .{
            .layers = 4,
            .planes = &single_net_fixture.planes,
            .copper = &single_net_fixture.copper,
            .dielectrics = &single_net_fixture.dielectrics,
            .present = true,
            .thickness = 1.6,
        } else .{},
    };
}

fn rulesFor(arena: std.mem.Allocator, block: *const DesignBlock) ![]const NetRule {
    var flat: std.ArrayList(flat_netlist.FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, block, &flat);
    return optimizer.resolvedNetRules(arena, block, flat.items);
}

fn differentialFixture(classes: []const env.NetClassSpec) DesignBlock {
    return .{
        .name = "pair-board",
        .instances = &.{},
        .nets = &differential_fixture.nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_classes = classes,
        .stackup = .{
            .layers = 6,
            .planes = &differential_fixture.planes,
            .copper = &differential_fixture.copper,
            .dielectrics = &differential_fixture.dielectrics,
            .present = true,
            .thickness = 1.6,
        },
    };
}

// spec: placement/impedance_rules - a net class declaring only (impedance …) has its width solved from the stackup
test "an impedance-only class derives its track width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const classes = [_]env.NetClassSpec{.{
        .name = "rf",
        .rf = .{ .impedance = .{ .ohms = 50 } },
        .nets = &.{"RF_IN"},
    }};
    const block = fixture(&classes, true);
    const rules = try rulesFor(arena, &block);

    try testing.expectEqual(@as(f64, 50), rules[0].rf.impedance.ohms);
    try testing.expect(rules[0].rf.impedance.width_derived);
    // Layer 1 over the 0.2104 mm prepreg to the GND plane on layer 2 — the
    // classic ~0.36 mm 50 Ω microstrip of a 4-layer 1.6 mm FR-4 board.
    try testing.expect(rules[0].width > 0.30);
    try testing.expect(rules[0].width < 0.45);
    // And it is exactly what the model alone says, so nothing re-derives it.
    const stack = try stackOf(arena, &block);
    try testing.expectEqual(impedance.resolvedWidthMm(stack, 50).?, rules[0].width);
}

// spec: placement/impedance_rules - a differential target derives both members' width from the selected layer and pair gap
test "a differential target derives its pair width on the selected layer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const classes = [_]env.NetClassSpec{.{
        .name = "lvds",
        .clearance = 0.127,
        .diff_gap = 0.1524,
        .rf = .{ .impedance = .{ .diff_ohms = 100, .layer = 3 } },
        .nets = &.{ "REF_P", "REF_N" },
    }};
    const block = differentialFixture(&classes);
    const rules = try rulesFor(arena, &block);
    try testing.expectEqual(@as(usize, 2), rules.len);
    for (rules) |rule| {
        try testing.expect(rule.rf.impedance.width_derived);
        try testing.expectEqual(@as(f64, 100), rule.rf.impedance.diff_ohms);
        try testing.expectEqual(@as(u8, 3), rule.rf.impedance.layer);
        try testing.expectApproxEqAbs(@as(f64, 0.1617), rule.width, 0.0001);
    }
}

// spec: placement/impedance_rules - an authored width beats a declared impedance target and is not re-derived
test "an authored width wins over its class impedance target" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const classes = [_]env.NetClassSpec{.{
        .name = "rf",
        .width = 0.2,
        .rf = .{ .impedance = .{ .ohms = 50 } },
        .nets = &.{"RF_IN"},
    }};
    const block = fixture(&classes, true);
    const rules = try rulesFor(arena, &block);

    try testing.expectEqual(@as(f64, 0.2), rules[0].width);
    try testing.expect(!rules[0].rf.impedance.width_derived);
    try testing.expectEqual(@as(f64, 50), rules[0].rf.impedance.ohms);
}

// spec: placement/impedance_rules - a ground-gap selects grounded-coplanar synthesis and resolves to at least the DRC clearance
test "a ground gap derives grounded-coplanar width and honors clearance" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const classes = [_]env.NetClassSpec{.{
        .name = "rf",
        .clearance = 0.127,
        .rf = .{ .impedance = .{ .ohms = 50, .ground_gap_mm = 0.1, .ground_gap_max_mm = 1.75 } },
        .nets = &.{"RF_IN"},
    }};
    const block = fixture(&classes, true);
    const rules = try rulesFor(arena, &block);
    try testing.expectApproxEqAbs(@as(f64, 0.127), rules[0].rf.impedance.ground_gap_mm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.75), rules[0].rf.impedance.ground_gap_max_mm, 1e-12);
    try testing.expect(rules[0].rf.impedance.width_derived);
    try testing.expectApproxEqAbs(@as(f64, 0.29483), rules[0].width, 0.0001);
}

// spec: placement/impedance_rules - a class with no impedance target, or a board with no stackup, derives no width
test "width derivation is a no-op without a target or a stackup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // No target at all: the corpus case. The width stays exactly as authored.
    const plain = [_]env.NetClassSpec{.{ .name = "rf", .width = 0.2, .nets = &.{"RF_IN"} }};
    const with_stack = fixture(&plain, true);
    const rules_a = try rulesFor(arena, &with_stack);
    try testing.expectEqual(@as(f64, 0.2), rules_a[0].width);
    try testing.expect(!rules_a[0].rf.impedance.width_derived);
    try testing.expectEqual(@as(f64, 0), rules_a[0].rf.impedance.ohms);

    // A target but NO (stackup …): nothing to solve against, so the width stays
    // at the router default rather than being guessed off an assumed buildup.
    const target = [_]env.NetClassSpec{.{
        .name = "rf",
        .rf = .{ .impedance = .{ .ohms = 50 } },
        .nets = &.{"RF_IN"},
    }};
    const no_stack = fixture(&target, false);
    const rules_b = try rulesFor(arena, &no_stack);
    try testing.expectEqual(@as(f64, 0), rules_b[0].width);
    try testing.expect(!rules_b[0].rf.impedance.width_derived);
    try testing.expectEqual(@as(u8, 0), (try stackOf(arena, &no_stack)).layers);
}

// spec: placement/impedance_rules - the stack bridge carries every authored foil, interval and plane through unchanged
test "stackOf mirrors the authored stackup" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const block = fixture(&.{}, true);
    const stack = try stackOf(arena, &block);
    try testing.expectEqual(@as(u8, 4), stack.layers);
    try testing.expectEqualSlices(u8, &.{2}, stack.planes);
    try testing.expectEqual(@as(usize, 3), stack.dielectrics.len);
    try testing.expectApproxEqAbs(@as(f64, 0.2104), stack.gapMm(1), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.065), stack.gapMm(2), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0152), stack.foilMm(2), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.6), stack.board_mm, 1e-12);
    try testing.expect(!stack.assumed());
    try testing.expect(stack.isPlane(2));
    try testing.expect(!stack.isPlane(1));
}

// spec: placement/impedance_rules - an empty rule list derives nothing and never builds a stack
test "deriveWidths on an empty rule list is a no-op" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const block = fixture(&.{}, true);
    var none: [0]NetRule = undefined;
    try deriveWidths(arena, &block, &none);
    // A design with no net classes at all resolves to no rules, and the whole
    // impedance path never runs.
    const rules = try rulesFor(arena, &block);
    try testing.expectEqual(@as(usize, 0), rules.len);
    // A stackup with no layers is likewise empty rather than an error.
    const bare = fixture(&.{}, false);
    const stack = try stackOf(arena, &bare);
    try testing.expectEqual(@as(u8, 0), stack.layers);
    try testing.expectEqual(@as(usize, 0), stack.dielectrics.len);
    try testing.expectEqual(@as(usize, 0), stack.planes.len);
    try testing.expectEqual(@as(usize, 0), stack.foils.len);
}

// spec: placement/impedance_rules - an unreachable or uncomputable target leaves the width alone; the bridge never panics
test "an unreachable target leaves the width at the router default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 250 Ω on a 0.2104 mm prepreg microstrip needs a strip far narrower than
    // Hammerstad's u >= 0.05 floor: unreachable, so nothing is written.
    const classes = [_]env.NetClassSpec{.{
        .name = "rf",
        .rf = .{ .impedance = .{ .ohms = 250 } },
        .nets = &.{"RF_IN"},
    }};
    const block = fixture(&classes, true);
    const rules = try rulesFor(arena, &block);
    try testing.expectEqual(@as(f64, 250), rules[0].rf.impedance.ohms);
    try testing.expectEqual(@as(f64, 0), rules[0].width);
    try testing.expect(!rules[0].rf.impedance.width_derived);

    // Same for a stackup whose layers carry no reference plane at all.
    var plane_less = fixture(&classes, true);
    plane_less.stackup.planes = &.{};
    const rules2 = try rulesFor(arena, &plane_less);
    try testing.expectEqual(@as(f64, 0), rules2[0].width);
    try testing.expect(!rules2[0].rf.impedance.width_derived);
}

// spec: placement/impedance_rules - a dielectric with no authored (er …) takes the generic FR-4 default
test "an undeclared permittivity resolves to the FR-4 default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dielectrics = [_]env.StackupDielectric{
        .{ .after_layer = 1, .kind = .prepreg, .thickness = 0.2, .er = 0 }, // undeclared
        .{ .after_layer = 2, .kind = .core, .thickness = 1.0, .er = 3.66 }, // Rogers-ish
    };
    var block = fixture(&.{}, true);
    block.stackup.dielectrics = &dielectrics;
    const stack = try stackOf(arena, &block);
    try testing.expectApproxEqAbs(impedance.default_er, stack.gapEr(1), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 3.66), stack.gapEr(2), 1e-12);
}
