//! Library-declared facts that BOUND a net, lifted to flat net names.
//!
//! `eval/net_envelopes` derives what TOPOLOGY proves — a rail crossing a bead,
//! a series resistor carrying a potential onto the node beyond it. That walk
//! sees the netlist and nothing else, so the two nodes a regulator module is
//! actually built around stay unnameable: the FB tap the loop servos to an
//! internal reference, and the SET node a precision current programs. Their
//! potentials are stated in the part's own `(requirement … (check …))` forms,
//! which the netlist walk has no vocabulary for.
//!
//! This module reads them. It walks the design tree with the same
//! `sub-block/` prefix the flatten uses, resolves each check's pin against the
//! block the part actually lives in, and emits seeds keyed by the flat name the
//! derivation will look up. Kept apart from `net_envelopes` because everything
//! here needs the EVALUATOR (a pin function name resolves only through the
//! part's pinout), and the derivation itself must stay a pure function of an
//! already-evaluated block.
//!
//! Nothing here ever overwrites a seeded or authored envelope: `build` applies
//! these only to nets still unknown, so a datasheet default can never rewrite
//! something the design states outright.

const std = @import("std");
const env_mod = @import("env.zig");
const req = @import("../req_checks.zig");

const Evaluator = @import("evaluator.zig").Evaluator;
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;

/// Amperes per microampere — `(current-ua …)` is in µA, Ohm's law is in amperes.
const amps_per_microamp: f64 = 1e-6;

/// One net's potential established by a library declaration rather than by
/// topology. `net` is the FLAT name; `rule` is the provenance text published on
/// the resulting envelope.
pub const Seed = struct {
    net: []const u8,
    min: f64,
    max: f64,
    rule: []const u8,
};

/// A library `(electrical "PIN" … (max-voltage V))` absolute maximum, resolved
/// to the flat ref-des and the flat net that pin sits on. A device pin cannot
/// push a node past its own declared ceiling, so this is what lets a driven
/// node be bounded by the PIN rather than by the widest supply the part reaches.
pub const PinLimit = struct {
    ref_des: []const u8,
    net: []const u8,
    max_voltage: f64,
};

/// Everything this pass found, both slices caller-owned.
pub const Facts = struct {
    seeds: []const Seed = &.{},
    pin_limits: []const PinLimit = &.{},
};

/// Collect every library-declared bound in the design tree. `allocator` must be
/// an arena or the page allocator: the flat names minted here are never freed,
/// the same contract `flat_netlist` has with every other post-eval consumer.
pub fn collect(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
) std.mem.Allocator.Error!Facts {
    var seeds: std.ArrayList(Seed) = .empty;
    errdefer seeds.deinit(allocator);
    var limits: std.ArrayList(PinLimit) = .empty;
    errdefer limits.deinit(allocator);
    try walk(allocator, eval, block, "", &seeds, &limits);
    return .{
        .seeds = try seeds.toOwnedSlice(allocator),
        .pin_limits = try limits.toOwnedSlice(allocator),
    };
}

/// One hierarchy level. `prefix` is the `sub-block/…` path of `block` ("" at
/// the top); every name that leaves this frame carries it, because a check's
/// pin resolves against the block the part lives in and the derivation looks
/// the answer up by its flattened name.
fn walk(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    prefix: []const u8,
    seeds: *std.ArrayList(Seed),
    limits: *std.ArrayList(PinLimit),
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        for (inst.electrical) |decl| {
            const ceiling = decl.max_voltage orelse continue;
            const found = req.padAndNetForPin(eval, block, inst, decl.pin) orelse continue;
            try limits.append(allocator, .{
                .ref_des = try flatten(allocator, prefix, inst.ref_des),
                .net = try flatten(allocator, prefix, found.net),
                .max_voltage = ceiling,
            });
        }
        for (inst.requirements) |requirement| {
            const check = requirement.check orelse continue;
            const seed = switch (check) {
                .feedback_divider => |c| feedbackSeed(allocator, eval, block, inst, c),
                .set_resistor_output => |c| try setResistorSeed(allocator, eval, block, inst, c),
                else => null,
            } orelse continue;
            try seeds.append(allocator, .{
                .net = try flatten(allocator, prefix, seed.net),
                .min = seed.min,
                .max = seed.max,
                .rule = seed.rule,
            });
        }
    }
    for (block.sub_blocks) |sb| {
        try walk(allocator, eval, sb.block, try flatten(allocator, prefix, sb.name), seeds, limits);
    }
}

fn flatten(allocator: std.mem.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, name });
}

/// A `(feedback-divider … (reference-v V) …)` pin sits at the reference: the
/// loop servos FB to V whatever the divider ratio is, which is the whole point
/// of the topology. The check's `(tolerance-pct …)` deliberately does NOT widen
/// this — it bounds how far the divider's PROGRAMMED OUTPUT may sit from the
/// declared rail, not how far this node moves. A datasheet that publishes
/// reference corners states them with `(net-envelope …)`, which must cover this.
fn feedbackSeed(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: @FieldType(env_mod.Check, "feedback_divider"),
) ?Seed {
    if (!(check.reference_v > 0)) return null;
    const net = req.netForPinFn(eval, block, inst, check.pin) orelse return null;
    const rule = std.fmt.allocPrint(
        allocator,
        "feedback reference {s}.{s} = {d} V",
        .{ inst.ref_des, check.pin, check.reference_v },
    ) catch "feedback reference";
    return .{ .net = net, .min = check.reference_v, .max = check.reference_v, .rule = rule };
}

/// A `(set-resistor-output …)` pin sits at I_SET x R_SET. Unlike a feedback
/// reference this node's OWN potential is what the tolerance describes — both
/// the sourced current and the resistor vary — so the seed spans it.
///
/// Two resistors between SET and the return net are in PARALLEL and program a
/// different current, so an ambiguous node seeds nothing rather than picking
/// one by instance order — the same discipline `req_derived_checks` applies.
fn setResistorSeed(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: @FieldType(env_mod.Check, "set_resistor_output"),
) std.mem.Allocator.Error!?Seed {
    if (!(check.current_ua > 0)) return null;
    const net = req.netForPinFn(eval, block, inst, check.pin) orelse return null;
    var ohms: ?f64 = null;
    for (block.instances) |candidate| {
        if (candidate.dnp or candidate.ref_des.len == 0 or candidate.ref_des[0] != 'R') continue;
        if (!req.instancePinOnNet(block, candidate, net)) continue;
        if (!req.instancePinOnNet(block, candidate, check.return_net)) continue;
        if (ohms != null) return null;
        ohms = req.parseOhms(candidate.value) orelse return null;
    }
    const resistance = ohms orelse return null;
    if (!(resistance > 0)) return null;
    const programmed = resistance * check.current_ua * amps_per_microamp;
    const spread = programmed * check.tolerance_pct / 100.0;
    const rule = try std.fmt.allocPrint(
        allocator,
        "set resistor {s}.{s} = {d:.1} uA x {d:.0} ohm",
        .{ inst.ref_des, check.pin, check.current_ua, resistance },
    );
    return .{
        .net = net,
        .min = programmed - @abs(spread),
        .max = programmed + @abs(spread),
        .rule = rule,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn passive(ref: []const u8, value: []const u8) Instance {
    return .{ .ref_des = ref, .component = "res-0402", .value = value, .footprint = "", .symbol = "" };
}

/// A regulator carrying one library requirement, wired to `nets`. No pinout is
/// registered, so every check names its PHYSICAL pin id — the fallback
/// `req.padAndNetForPin` takes for a part whose pin functions are generic.
fn regulatorBlock(
    instances: []const Instance,
    nets: []const env_mod.Net,
) DesignBlock {
    return .{
        .name = "reg",
        .instances = instances,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

// spec: eval/net-envelope-rules - A feedback-divider requirement bounds its FB pin at the declared reference
test "a feedback-divider check seeds the FB node at its reference" {
    const alloc = testing.allocator;
    var eval = Evaluator.init(alloc, "");
    defer eval.deinit();
    const reqs = [_]env_mod.Requirement{.{
        .text = "FB is the tap of an external divider",
        .check = .{ .feedback_divider = .{
            .pin = "3",
            .return_net = "GND",
            .reference_v = 0.6,
            .tolerance_pct = 2,
        } },
    }};
    var buck = Instance{ .ref_des = "U1", .component = "buck", .value = "", .footprint = "", .symbol = "" };
    buck.requirements = &reqs;
    const instances = [_]Instance{ buck, passive("R1", "86.6k"), passive("R2", "10k") };
    const nets = [_]env_mod.Net{
        .{ .name = "V_5V75", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R1", .pin = "1" }} },
        .{ .name = "FB", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "3" }, .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "R2", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R2", .pin = "2" }} },
    };
    const block = regulatorBlock(&instances, &nets);
    const facts = try collect(alloc, &eval, &block);
    defer alloc.free(facts.seeds);
    defer alloc.free(facts.pin_limits);
    defer for (facts.seeds) |seed| alloc.free(seed.rule);
    try testing.expectEqual(@as(usize, 1), facts.seeds.len);
    try testing.expectEqualStrings("FB", facts.seeds[0].net);
    // The loop servos FB to the reference; the check's tolerance bounds the
    // divider's agreement with the RAIL, not this node's own spread.
    try testing.expectEqual(@as(f64, 0.6), facts.seeds[0].min);
    try testing.expectEqual(@as(f64, 0.6), facts.seeds[0].max);
}

// spec: eval/net-envelope-rules - A set-resistor-output requirement bounds its SET pin at the programmed voltage
test "a set-resistor check seeds the SET node at I_SET x R_SET" {
    const alloc = testing.allocator;
    var eval = Evaluator.init(alloc, "");
    defer eval.deinit();
    const reqs = [_]env_mod.Requirement{.{
        .text = "SET programs VOUT",
        .check = .{ .set_resistor_output = .{
            .pin = "7",
            .return_net = "GND",
            .output_pin = "10",
            .current_ua = 100,
            .tolerance_pct = 2,
        } },
    }};
    var ldo = Instance{ .ref_des = "U1", .component = "lt3045", .value = "", .footprint = "", .symbol = "" };
    ldo.requirements = &reqs;
    const instances = [_]Instance{ ldo, passive("R_SET", "49.9k") };
    const nets = [_]env_mod.Net{
        .{ .name = "SET", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "7" }, .{ .ref_des = "R_SET", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{.{ .ref_des = "R_SET", .pin = "2" }} },
    };
    const block = regulatorBlock(&instances, &nets);
    const facts = try collect(alloc, &eval, &block);
    defer alloc.free(facts.seeds);
    defer alloc.free(facts.pin_limits);
    defer for (facts.seeds) |seed| alloc.free(seed.rule);
    try testing.expectEqual(@as(usize, 1), facts.seeds.len);
    try testing.expectEqualStrings("SET", facts.seeds[0].net);
    // 100 uA x 49.9k = 4.99 V, spanned by the declared 2 % programming tolerance.
    try testing.expectApproxEqAbs(@as(f64, 4.8902), facts.seeds[0].min, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.0898), facts.seeds[0].max, 1e-9);
}

// spec: eval/net-envelope-rules - Two resistors in parallel on a SET node are ambiguous and seed nothing
test "an ambiguous SET node seeds nothing rather than picking a resistor" {
    const alloc = testing.allocator;
    var eval = Evaluator.init(alloc, "");
    defer eval.deinit();
    const reqs = [_]env_mod.Requirement{.{
        .text = "SET programs VOUT",
        .check = .{ .set_resistor_output = .{
            .pin = "7",
            .return_net = "GND",
            .output_pin = "10",
            .current_ua = 100,
            .tolerance_pct = 2,
        } },
    }};
    var ldo = Instance{ .ref_des = "U1", .component = "lt3045", .value = "", .footprint = "", .symbol = "" };
    ldo.requirements = &reqs;
    const instances = [_]Instance{ ldo, passive("R_SET", "49.9k"), passive("R_TRIM", "1M") };
    const nets = [_]env_mod.Net{
        .{ .name = "SET", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "7" }, .{ .ref_des = "R_SET", .pin = "1" }, .{ .ref_des = "R_TRIM", .pin = "1" } } },
        .{ .name = "GND", .pins = &[_]env_mod.PinRef{ .{ .ref_des = "R_SET", .pin = "2" }, .{ .ref_des = "R_TRIM", .pin = "2" } } },
    };
    const block = regulatorBlock(&instances, &nets);
    const facts = try collect(alloc, &eval, &block);
    defer alloc.free(facts.seeds);
    defer alloc.free(facts.pin_limits);
    try testing.expectEqual(@as(usize, 0), facts.seeds.len);
}

// spec: eval/net-envelope-rules - A library pin max-voltage is lifted to the flat net that pin sits on
test "collect lifts an (electrical … (max-voltage V)) ceiling to its sub-block net" {
    const alloc = testing.allocator;
    var eval = Evaluator.init(alloc, "");
    defer eval.deinit();
    const electrical = [_]env_mod.ElectricalDecl{.{ .pin = "4", .max_voltage = 6.0 }};
    var part = Instance{ .ref_des = "U1", .component = "ldo", .value = "", .footprint = "", .symbol = "" };
    part.electrical = &electrical;
    const instances = [_]Instance{part};
    const nets = [_]env_mod.Net{
        .{ .name = "SS", .pins = &[_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "4" }} },
    };
    var inner = regulatorBlock(&instances, &nets);
    const sbs = [_]env_mod.SubBlock{.{ .name = "ldo_5v", .block = &inner }};
    const outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
    };
    const facts = try collect(alloc, &eval, &outer);
    defer alloc.free(facts.seeds);
    defer alloc.free(facts.pin_limits);
    defer for (facts.pin_limits) |limit| {
        alloc.free(limit.ref_des);
        alloc.free(limit.net);
    };
    try testing.expectEqual(@as(usize, 1), facts.pin_limits.len);
    try testing.expectEqualStrings("ldo_5v/U1", facts.pin_limits[0].ref_des);
    try testing.expectEqualStrings("ldo_5v/SS", facts.pin_limits[0].net);
    try testing.expectEqual(@as(f64, 6.0), facts.pin_limits[0].max_voltage);
}
