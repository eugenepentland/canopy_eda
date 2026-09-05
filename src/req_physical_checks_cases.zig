//! Evaluation tests for the three physical requirement-check primitives.
//! Test-only, mirroring `req_checks_cases.zig`: the production checker stays a
//! short file and the fixtures — a pinout on disk, a block literal, a derived
//! envelope table — live here.
//!
//! Every fixture is built from a real prose requirement in
//! `projects/designs/lib/components`, quoted at its test, so the primitives are
//! exercised against the sentences they were written to make executable.

const std = @import("std");
const env = @import("eval/env.zig");
const req = @import("req_checks.zig");
const physical = @import("req_physical_checks.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// A project directory holding one pinout file, plus an evaluator pointed at
/// it. `tmp` must outlive the evaluator; the caller cleans it up.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    eval: Evaluator,

    /// Deliberately not named `init`: it performs several fallible steps whose
    /// only resource is the TmpDir, which `deinit` releases wholesale.
    fn open(allocator: std.mem.Allocator, pinout_name: []const u8, pinout: []const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
        const path = try std.fmt.allocPrint(allocator, "lib/pinouts/{s}.sexp", .{pinout_name});
        defer allocator.free(path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = pinout });
        const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        return .{ .tmp = tmp, .eval = Evaluator.init(allocator, project) };
    }

    fn deinit(self: *Fixture) void {
        self.eval.deinit();
        self.tmp.cleanup();
    }
};

/// Run every requirement on `block` and return U1's outcomes. The map and its
/// messages are page-allocator owned, matching the other checker fixtures.
fn statusOf(allocator: std.mem.Allocator, fixture: *Fixture, block: *const env.DesignBlock) ![]req.Result {
    var results = try req.runChecks(allocator, &fixture.eval, block);
    return results.get("U1") orelse error.NoResults;
}

/// Unwrap an evaluated top-level form as the design block it must be.
fn designBlockOf(value: env.Value) !*env.DesignBlock {
    return switch (value) {
        .design_block => |b| b,
        else => error.TestNotADesign,
    };
}

// ── (cap-rating …) ────────────────────────────────────────────────────────

const bq25185_pinout = "(pinout charger (pin 10 \"IN\") (pin 4 \"GND\"))";

/// BQ25185DLHR: "IN (pin 10) operates from 3.2 V to 5.5 V for charging;
/// absolute maximum is -2 V to 18.5 V (VIN_OVP). The input cap must be rated
/// for the worst-case IN voltage."
const bq25185_requirement = "The input cap must be rated for the worst-case IN voltage.";

const cap_rating_check: env.Check = .{ .cap_rating = .{
    .pin_a = "IN",
    .pin_b = "GND",
    .min_ratio = 1.5,
    .min_v = 0,
} };

const charger_nets = [_]env.Net{
    .{ .name = "VBUS", .pins = &.{ .{ .ref_des = "U1", .pin = "10" }, .{ .ref_des = "C1", .pin = "1" } } },
    .{ .name = "GND", .pins = &.{ .{ .ref_des = "U1", .pin = "4" }, .{ .ref_des = "C1", .pin = "2" } } },
};

/// VBUS reaches 5.5 V worst case, so a 1.5x rule demands 8.25 V.
const vbus_envelope = [_]env.NetEnvelope{.{ .net = "VBUS", .min = 0, .max = 5.5 }};

fn chargerInstances(cap: env.Instance) [2]env.Instance {
    return .{
        .{
            .ref_des = "U1",
            .component = "charger",
            .value = "charger",
            .footprint = "x",
            .symbol = "charger",
            .pinout = "charger",
            .requirements = &.{.{ .text = bq25185_requirement, .id = "bq251850", .check = cap_rating_check }},
        },
        cap,
    };
}

fn chargerCap(attrs: []const []const u8) env.Instance {
    return .{
        .ref_des = "C1",
        .component = "cap-0402",
        .value = "1uF",
        .footprint = "c0402",
        .symbol = "cap",
        .attrs = attrs,
    };
}

fn chargerBlock(instances: []const env.Instance, envelopes: []const env.NetEnvelope) env.DesignBlock {
    return .{
        .name = "charger",
        .instances = instances,
        .nets = &charger_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .envelopes = .{ .published = envelopes },
    };
}

// spec: req_physical_checks - cap-rating passes a capacitor rated above the derived envelope and fails one rated below it
test "cap-rating judges a bridging capacitor against the derived DC envelope" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator, "charger", bq25185_pinout);
    defer fixture.deinit();

    const rated = chargerInstances(chargerCap(&.{ "x7r", "10%", "16V" }));
    const ok_block = chargerBlock(&rated, &vbus_envelope);
    const ok = try statusOf(allocator, &fixture, &ok_block);
    try std.testing.expectEqual(req.Status.pass, ok[0].status);

    // 6.3 V is over the 5.5 V the net reaches but under the 8.25 V the 1.5x
    // ceramic derating rule demands — exactly the case a bare "rated for what
    // it sees" comparison would wave through.
    const underrated = chargerInstances(chargerCap(&.{ "x7r", "10%", "6.3V" }));
    const bad_block = chargerBlock(&underrated, &vbus_envelope);
    const bad = try statusOf(allocator, &fixture, &bad_block);
    try std.testing.expectEqual(req.Status.fail, bad[0].status);
    try std.testing.expect(std.mem.indexOf(u8, bad[0].message, "8.250 V") != null);
}

// spec: req_physical_checks - cap-rating reports an unrated capacitor and an underivable net envelope as unproven rather than passing either
test "cap-rating never passes a capacitor it could not judge" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator, "charger", bq25185_pinout);
    defer fixture.deinit();

    // No voltage attribute at all: the rule cannot be decided, and calling
    // that a pass is the exact failure the primitive exists to close.
    const unrated = chargerInstances(chargerCap(&.{ "x7r", "10%" }));
    const unrated_block = chargerBlock(&unrated, &vbus_envelope);
    const no_rating = try statusOf(allocator, &fixture, &unrated_block);
    try std.testing.expectEqual(req.Status.unproven, no_rating[0].status);
    try std.testing.expect(std.mem.indexOf(u8, no_rating[0].message, "C1") != null);

    // Rated cap, but nothing in the design bounds VBUS: unproven, naming the
    // net so the author knows which declaration is missing.
    const rated = chargerInstances(chargerCap(&.{"16V"}));
    const no_envelope_block = chargerBlock(&rated, &.{});
    const no_envelope = try statusOf(allocator, &fixture, &no_envelope_block);
    try std.testing.expectEqual(req.Status.unproven, no_envelope[0].status);
    try std.testing.expect(std.mem.indexOf(u8, no_envelope[0].message, "VBUS") != null);
}

// ── (max-distance …) ──────────────────────────────────────────────────────

const adp7118_pinout = "(pinout ldo (pin 1 \"VIN\") (pin 2 \"GND\"))";

/// ADP7118: "Input decoupling: place a 1 uF ceramic capacitor from VIN to GND
/// as close to the device as possible."
const adp7118_requirement = "Input decoupling: place a 1 uF ceramic capacitor from VIN to GND as close to the device as possible.";

const max_distance_check: env.Check = .{ .max_distance = .{
    .pin = "VIN",
    .kind = .C,
    .max_mm = 3.0,
    .min_value = 0.9,
} };

const ldo_nets = [_]env.Net{
    .{ .name = "VIN", .pins = &.{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } } },
    .{ .name = "GND", .pins = &.{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C1", .pin = "2" } } },
};

fn ldoInstances(cap_value: []const u8) [2]env.Instance {
    return .{
        .{
            .ref_des = "U1",
            .component = "ldo",
            .value = "ldo",
            .footprint = "x",
            .symbol = "ldo",
            .pinout = "ldo",
            .requirements = &.{.{ .text = adp7118_requirement, .id = "ad971180", .check = max_distance_check }},
        },
        .{ .ref_des = "C1", .component = "cap-0402", .value = cap_value, .footprint = "c0402", .symbol = "cap" },
    };
}

fn ldoBlock(instances: []const env.Instance) env.DesignBlock {
    return .{
        .name = "ldo board",
        .instances = instances,
        .nets = &ldo_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

// spec: req_physical_checks - max-distance defers to the layout lint when a qualifying passive exists and fails at build time when the netlist has none
test "max-distance separates a layout question from an unsatisfiable one" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator, "ldo", adp7118_pinout);
    defer fixture.deinit();

    const with_cap = ldoInstances("1uF");
    const deferred_block = ldoBlock(&with_cap);
    const deferred = try statusOf(allocator, &fixture, &deferred_block);
    try std.testing.expectEqual(req.Status.layout_deferred, deferred[0].status);
    // The message must name the lint that actually decides it.
    try std.testing.expect(std.mem.indexOf(u8, deferred[0].message, "req-distance-far") != null);

    // A 100 nF cap does not satisfy "1 uF", and no placement can change that,
    // so this is a build-time failure rather than a deferral.
    const wrong_value = ldoInstances("100nF");
    const fail_block = ldoBlock(&wrong_value);
    const failed = try statusOf(allocator, &fixture, &fail_block);
    try std.testing.expectEqual(req.Status.fail, failed[0].status);
}

// spec: req_physical_checks - resolving a max-distance rule records the measured pad and every qualifying passive on its net for the layout lint
test "resolveDistanceRules hands the layout lint a pad and its candidates" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator, "ldo", adp7118_pinout);
    defer fixture.deinit();

    var instances = ldoInstances("1uF");
    var block = ldoBlock(&instances);
    physical.resolveDistanceRules(&fixture.eval, &block);

    const rules = block.instances[0].distance_rules;
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqualStrings("1", rules[0].pad);
    try std.testing.expectEqualStrings("ad971180", rules[0].req_id);
    try std.testing.expectEqual(@as(usize, 1), rules[0].candidates.len);
    try std.testing.expectEqualStrings("C1", rules[0].candidates[0]);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), rules[0].max_mm, 1e-9);
}

// ── (sequence …) ──────────────────────────────────────────────────────────

/// The rail the enable graph cannot order: a battery input straight off the
/// board edge, not a regulator output, so nothing in the design gates it.
const unordered_rail = "VBATT";

const bno08x_pinout = "(pinout imu (pin 1 \"VDD\") (pin 2 \"VDDIO\") (pin 3 \"" ++ unordered_rail ++ "\"))";

/// BNO080/085: "VDD must reach its specified level before or at the same time
/// as VDDIO during power-up; reverse sequencing is not permitted".
const bno08x_requirement = "VDD must reach its specified level before or at the same time as VDDIO during power-up; reverse sequencing is not permitted";

const imu_nets = [_]env.Net{
    .{ .name = "VDD", .pins = &.{.{ .ref_des = "U1", .pin = "1" }} },
    .{ .name = "VDDIO", .pins = &.{.{ .ref_des = "U1", .pin = "2" }} },
    .{ .name = unordered_rail, .pins = &.{.{ .ref_des = "U1", .pin = "3" }} },
};

/// The buck sources VDD; the LDO sources VDDIO and is enabled by VDD, which is
/// the edge that gives the two rails an order at all.
const imu_ties = [_]env.NetTie{
    .{ .a = "buck/VOUT", .b = "VDD" },
    .{ .a = "ldo/VOUT", .b = "VDDIO" },
};

const buck_ports = [_]env.Port{.{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 3.3 }};
const ldo_ports = [_]env.Port{.{ .name = "VOUT", .net = "VOUT", .direction = "out", .nominal = 1.8, .enable_net = "VDD" }};

/// A regulator sub-block: one power output port and nothing else. The caller
/// keeps it in a `var` so the `SubBlock` can point at it.
fn regulator(name: []const u8, ports: []const env.Port) env.DesignBlock {
    return .{
        .name = name,
        .instances = &.{},
        .nets = &.{},
        .ports = ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

/// The board around a caller-owned sub-block list and instance list. Every
/// other slice is file-scope, so nothing here points into a callee frame.
fn imuBlock(subs: []const env.SubBlock, instances: []const env.Instance) env.DesignBlock {
    return .{
        .name = "imu board",
        .instances = instances,
        .nets = &imu_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = subs,
        .net_ties = &imu_ties,
    };
}

fn imuRequirement(first: []const u8, second: []const u8) [1]env.Requirement {
    return .{.{
        .text = bno08x_requirement,
        .id = "bn008000",
        .check = .{ .sequence = .{ .pin_a = first, .pin_b = second } },
    }};
}

fn imuInstances(requirements: []const env.Requirement) [1]env.Instance {
    return .{.{
        .ref_des = "U1",
        .component = "imu",
        .value = "imu",
        .footprint = "x",
        .symbol = "imu",
        .pinout = "imu",
        .requirements = requirements,
    }};
}

// spec: req_physical_checks - sequence passes a derived power-up order that satisfies it and fails one that reverses it
test "sequence judges the derived rail order" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator, "imu", bno08x_pinout);
    defer fixture.deinit();

    var buck = regulator("buck", &buck_ports);
    var ldo = regulator("ldo", &ldo_ports);
    const subs = [_]env.SubBlock{ .{ .name = "buck", .block = &buck }, .{ .name = "ldo", .block = &ldo } };

    const good_req = imuRequirement("VDD", "VDDIO");
    const good_insts = imuInstances(&good_req);
    const good_block = imuBlock(&subs, &good_insts);
    const pass = try statusOf(allocator, &fixture, &good_block);
    try std.testing.expectEqual(req.Status.pass, pass[0].status);

    const bad_req = imuRequirement("VDDIO", "VDD");
    const bad_insts = imuInstances(&bad_req);
    const bad_block = imuBlock(&subs, &bad_insts);
    const violated = try statusOf(allocator, &fixture, &bad_block);
    try std.testing.expectEqual(req.Status.fail, violated[0].status);
    try std.testing.expect(std.mem.indexOf(u8, violated[0].message, "VDDIO") != null);
}

// spec: req_physical_checks - sequence reports an undetermined power-up order as unproven and names what would prove it
test "sequence leaves an unordered pair unproven" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator, "imu", bno08x_pinout);
    defer fixture.deinit();

    var buck = regulator("buck", &buck_ports);
    var ldo = regulator("ldo", &ldo_ports);
    const subs = [_]env.SubBlock{ .{ .name = "buck", .block = &buck }, .{ .name = "ldo", .block = &ldo } };

    // The third rail is a board input, not a sub-block output, so the enable
    // graph puts it nowhere in the order and the rule cannot be decided.
    const reqs = imuRequirement(unordered_rail, "VDDIO");
    const insts = imuInstances(&reqs);
    const block = imuBlock(&subs, &insts);
    const results = try statusOf(allocator, &fixture, &block);
    try std.testing.expectEqual(req.Status.unproven, results[0].status);
    try std.testing.expect(std.mem.indexOf(u8, results[0].message, unordered_rail) != null);
    try std.testing.expect(std.mem.indexOf(u8, results[0].message, "enable") != null);
}

// spec: req_physical_checks - evaluating a design resolves its max-distance requirements onto the instances the placement layer reads
test "the design-block build wires distance rules onto the placed part" {
    // The unit above proves the resolver; this proves it is actually CALLED,
    // which is the half a hand-built block literal can never show.
    const allocator = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/ldo.sexp", .data = adp7118_pinout });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/ldo.sexp",
        .data =
        \\(component "ldo"
        \\  (pinout "ldo")
        \\  (footprint "sot23-5")
        \\  (requirement "place a 1 uF capacitor at VIN"
        \\    (id ad971180)
        \\    (check (max-distance (pin "VIN") (kind C) (mm 3.0) (min-value 0.9)))))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/cap-0402.sexp",
        .data =
        \\(component-family "cap-0402"
        \\  (symbol generic-cap)
        \\  (footprint c-0402)
        \\  (parameter "value" capacitance))
        ,
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var evaluator = Evaluator.init(allocator, project);
    defer evaluator.deinit();

    const result = try evaluator.evalSource(
        \\(import ldo cap-0402)
        \\(design-block "board"
        \\  (instance "U1" ldo (pin 1 "VIN") (pin 2 "GND"))
        \\  (instance "C1" (cap-0402 "1uF") (pin 1 "VIN") (pin 2 "GND")))
    );
    const block = try designBlockOf(result);
    const rules = block.instances[0].distance_rules;
    try std.testing.expectEqual(@as(usize, 1), rules.len);
    try std.testing.expectEqualStrings("1", rules[0].pad);
    try std.testing.expectEqual(@as(usize, 1), rules[0].candidates.len);
    try std.testing.expectEqualStrings("C1", rules[0].candidates[0]);
    try std.testing.expect(std.mem.indexOf(u8, rules[0].what, "capacitor") != null);
}

// spec: req_physical_checks - parseVolts reads a rating attribute and rejects the foreign units that sit beside it
test "parseVolts accepts volt spellings only" {
    try std.testing.expectApproxEqAbs(@as(f64, 16), req.parseVolts("16V").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.3), req.parseVolts("6.3 V").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), req.parseVolts("250mV").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1000), req.parseVolts("1kV").?, 1e-9);
    // The attribute list a capacitor carries also holds these; reading any of
    // them as volts is how a 63 mW resistor would "prove" a 63 V rating.
    try std.testing.expect(req.parseVolts("63mW") == null);
    try std.testing.expect(req.parseVolts("1A") == null);
    try std.testing.expect(req.parseVolts("10%") == null);
    try std.testing.expect(req.parseVolts("25") == null);
    try std.testing.expect(req.parseVolts("x7r") == null);
}
