//! Focused tests for the public requirement-checker surface. Keeping them in
//! a test-only module leaves the production checker below Guardian's file cap.

const std = @import("std");
const env = @import("eval/env.zig");
const req = @import("req_checks.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

// spec: req_checks - parseMicroFarads handles SI-suffixed cap values
test "parseMicroFarads" {
    try std.testing.expectApproxEqAbs(
        @as(f64, 4.7),
        req.parseMicroFarads("4.7uF").?,
        1e-9,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.1),
        req.parseMicroFarads("100nF").?,
        1e-9,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.0001),
        req.parseMicroFarads("100pF").?,
        1e-12,
    );
    try std.testing.expectApproxEqAbs(
        @as(f64, 10.0),
        req.parseMicroFarads("10µF").?,
        1e-9,
    );
    try std.testing.expect(req.parseMicroFarads("garbage") == null);
}

// spec: req_checks - parseOhms handles SI prefixes for resistor values
test "parseOhms" {
    try expectOhms(10000, "10k");
    try expectOhms(2200, "2.2k");
    try expectOhms(470, "470");
    try expectOhms(1000000, "1M");
}

// Regression: milliohm suffixes and R-notation retain their exact scaling.
test "parseOhms milliohm and R-notation" {
    try expectOhms(0.01, "10m");
    try expectOhms(0.05, "50mohm");
    try expectOhms(4.7, "4R7");
    try expectOhms(0.05, "0R05");
    try expectOhms(4.0, "4R");
    try expectOhms(100, "100R");
    try std.testing.expect(req.parseOhms("100kHz") == null);
    try std.testing.expect(req.parseOhms("10xyz") == null);
}

fn expectOhms(expected: f64, text: []const u8) !void {
    try std.testing.expectApproxEqAbs(expected, req.parseOhms(text).?, 1e-9);
}

// spec: req_checks - parseMicroHenries handles SI-suffixed inductor values
test "parseMicroHenries" {
    try expectMicroHenries(1.0, "1uH");
    try expectMicroHenries(2.2, "2.2µH");
    try expectMicroHenries(0.1, "100nH");
    try std.testing.expect(req.parseMicroHenries("garbage") == null);
}

fn expectMicroHenries(expected: f64, text: []const u8) !void {
    try std.testing.expectApproxEqAbs(
        expected,
        req.parseMicroHenries(text).?,
        1e-9,
    );
}

const VerifyFixture = struct {
    block: env.DesignBlock,
    results: []req.Result,
    map: std.StringHashMapUnmanaged([]req.Result),
};

fn verifyFixture(
    allocator: std.mem.Allocator,
    verifications: []const env.Verification,
) !VerifyFixture {
    const requirements = try allocator.dupe(
        env.Requirement,
        &.{.{ .text = "rule", .id = "r1" }},
    );
    const instances = try allocator.dupe(env.Instance, &.{.{
        .ref_des = "U6",
        .component = "x",
        .value = "",
        .footprint = "",
        .symbol = "",
        .id = "b894897b",
        .requirements = requirements,
    }});
    const results = try allocator.dupe(req.Result, &.{.{ .status = .na }});
    var map: std.StringHashMapUnmanaged([]req.Result) = .empty;
    try map.put(allocator, "U6", results);
    return .{
        .block = .{
            .name = "t",
            .instances = instances,
            .nets = &.{},
            .ports = &.{},
            .notes = &.{},
            .groups = &.{},
            .sub_blocks = &.{},
            .verifications = verifications,
        },
        .results = results,
        .map = map,
    };
}

// spec: req_checks - applyVerifications matches a verifies form to an instance by stable id when target-id is set
test "applyVerifications matches by stable id" {
    const allocator = std.heap.page_allocator;
    var fixture = try verifyFixture(allocator, &.{.{
        .target_id = "b894897b",
        .req_id = "r1",
        .rationale = "checked",
    }});
    req.applyVerifications(
        &fixture.map,
        &fixture.block,
        fixture.block.instances,
    );
    try std.testing.expectEqual(req.Status.verified, fixture.results[0].status);
    try std.testing.expect(fixture.results[0].verification != null);

    var unmatched = try verifyFixture(allocator, &.{.{
        .target_id = "deadbeef",
        .req_id = "r1",
        .rationale = "x",
    }});
    req.applyVerifications(
        &unmatched.map,
        &unmatched.block,
        unmatched.block.instances,
    );
    try std.testing.expectEqual(req.Status.na, unmatched.results[0].status);
}

// spec: req_checks - applyVerifications matches a verifies form to an instance by ref-des when target-id is empty
test "applyVerifications matches by ref-des fallback" {
    const allocator = std.heap.page_allocator;
    var fixture = try verifyFixture(allocator, &.{.{
        .ref_des = "U6",
        .req_id = "r1",
        .rationale = "checked",
    }});
    req.applyVerifications(
        &fixture.map,
        &fixture.block,
        fixture.block.instances,
    );
    try std.testing.expectEqual(req.Status.verified, fixture.results[0].status);
    try std.testing.expect(fixture.results[0].verification != null);
}

// spec: req_checks - applyVerifications honors verification forms declared inside nested reusable modules
test "applyVerifications includes nested module-local sign-offs" {
    const allocator = std.heap.page_allocator;
    var fixture = try verifyFixture(allocator, &.{.{
        .ref_des = "U6",
        .req_id = "r1",
        .rationale = "verified by the reusable module",
    }});
    const sub_blocks = [_]env.SubBlock{.{
        .name = "supply",
        .source = "regulator-module",
        .block = &fixture.block,
    }};
    const parent = env.DesignBlock{
        .name = "board",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sub_blocks,
    };
    req.applyVerifications(&fixture.map, &parent, parent.instances);
    try std.testing.expectEqual(req.Status.verified, fixture.results[0].status);
}

// spec: req_checks - runChecks frees a partial result on map allocation failure
test "runChecks cleans partial results on map allocation failure" {
    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 1 },
    );
    const allocator = failing.allocator();
    var evaluator = Evaluator.init(allocator, ".");
    defer evaluator.deinit();
    const requirement = env.Requirement{ .text = "manual", .id = "deadbeef" };
    const instance = env.Instance{
        .ref_des = "U1",
        .component = "part",
        .value = "part",
        .footprint = "x",
        .symbol = "x",
        .requirements = &.{requirement},
    };
    const block = env.DesignBlock{
        .name = "ownership",
        .instances = &.{instance},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    try std.testing.expectError(
        error.OutOfMemory,
        req.runChecks(allocator, &evaluator, &block),
    );
}

// spec: req_checks - pin connectivity checks accept physical pin ids as well as pinout function names
test "pin-not-floating accepts a physical pin id" {
    const allocator = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/pinouts/part.sexp",
        .data = "(pinout part (pin 4 \"EN/UV_4\"))",
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var evaluator = Evaluator.init(allocator, project);
    defer evaluator.deinit();
    const requirement = env.Requirement{
        .text = "EN must not float",
        .id = "deadbeef",
        .check = .{ .pin_not_floating = .{ .pin = "4" } },
    };
    const instances = [_]env.Instance{
        .{
            .ref_des = "U1",
            .component = "part",
            .value = "part",
            .footprint = "x",
            .symbol = "part",
            .pinout = "part",
            .requirements = &.{requirement},
        },
        .{ .ref_des = "R1", .component = "res", .value = "10k", .footprint = "x", .symbol = "res" },
    };
    const nets = [_]env.Net{.{ .name = "EN", .pins = &.{
        .{ .ref_des = "U1", .pin = "4" },
        .{ .ref_des = "R1", .pin = "1" },
    } }};
    const block = env.DesignBlock{
        .name = "physical pin",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var results = try req.runChecks(allocator, &evaluator, &block);
    defer req.deinit(allocator, &results);
    try std.testing.expectEqual(req.Status.pass, results.get("U1").?[0].status);
}

// spec: req_checks - decoupling-per-pin requires distinct physical capacitors
test "decoupling-per-pin does not count one capacitor for multiple pins" {
    const allocator = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/pinouts/part.sexp",
        .data = "(pinout part (pin 1 \"VDD_1\") (pin 2 \"VDD_2\") (pin 3 \"GND\"))",
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var evaluator = Evaluator.init(allocator, project);
    defer evaluator.deinit();

    const requirement = env.Requirement{
        .text = "one bypass capacitor per supply pin",
        .id = "dec0ffee",
        .check = .{ .decoupling_per_pin = .{
            .return_pin = "GND",
            .pins = &.{ "VDD_1", "VDD_2" },
            .min_uf = 0.09,
            .count = 2,
        } },
    };
    const instances = [_]env.Instance{
        .{ .ref_des = "U1", .component = "part", .value = "part", .footprint = "x", .symbol = "part", .pinout = "part", .requirements = &.{requirement} },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "x", .symbol = "cap" },
        .{ .ref_des = "C2", .component = "cap", .value = "100nF", .footprint = "x", .symbol = "cap" },
    };
    const one_cap_nets = [_]env.Net{
        .{ .name = "VDD", .pins = &.{
            .{ .ref_des = "U1", .pin = "1" },
            .{ .ref_des = "U1", .pin = "2" },
            .{ .ref_des = "C1", .pin = "1" },
        } },
        .{ .name = "GND", .pins = &.{
            .{ .ref_des = "U1", .pin = "3" },
            .{ .ref_des = "C1", .pin = "2" },
        } },
    };
    var block = env.DesignBlock{
        .name = "distinct bypasses",
        .instances = &instances,
        .nets = &one_cap_nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var one_cap = try req.runChecks(allocator, &evaluator, &block);
    defer req.deinit(allocator, &one_cap);
    try std.testing.expectEqual(req.Status.fail, one_cap.get("U1").?[0].status);

    const two_cap_nets = [_]env.Net{
        .{ .name = "VDD", .pins = &.{
            .{ .ref_des = "U1", .pin = "1" },
            .{ .ref_des = "U1", .pin = "2" },
            .{ .ref_des = "C1", .pin = "1" },
            .{ .ref_des = "C2", .pin = "1" },
        } },
        .{ .name = "GND", .pins = &.{
            .{ .ref_des = "U1", .pin = "3" },
            .{ .ref_des = "C1", .pin = "2" },
            .{ .ref_des = "C2", .pin = "2" },
        } },
    };
    block.nets = &two_cap_nets;
    var two_caps = try req.runChecks(allocator, &evaluator, &block);
    defer req.deinit(allocator, &two_caps);
    try std.testing.expectEqual(req.Status.pass, two_caps.get("U1").?[0].status);
}

// spec: req_checks - voltage-not-above compares the control worst-case maximum against the supply worst-case minimum plus margin
test "voltage-not-above enforces a relative pin voltage limit" {
    const allocator = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/pinouts/part.sexp",
        .data = "(pinout part (pin 1 \"EN\") (pin 2 \"VIN\"))",
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    var evaluator = Evaluator.init(allocator, project);
    defer evaluator.deinit();

    const requirement = env.Requirement{
        .text = "EN must not exceed VIN + 0.3 V",
        .id = "facade00",
        .check = .{ .voltage_range = .{
            .pin = "EN",
            .min_v = 0,
            .max_v = 0,
            .not_above_pin = "VIN",
            .margin_v = 0.3,
        } },
    };
    const instances = [_]env.Instance{.{
        .ref_des = "U1",
        .component = "part",
        .value = "part",
        .footprint = "x",
        .symbol = "part",
        .pinout = "part",
        .requirements = &.{requirement},
    }};
    const nets = [_]env.Net{
        .{ .name = "ENABLE", .pins = &.{.{ .ref_des = "U1", .pin = "1" }} },
        .{ .name = "INPUT", .pins = &.{.{ .ref_des = "U1", .pin = "2" }} },
    };
    var ports = [_]env.Port{
        .{ .name = "ENABLE", .net = "ENABLE", .direction = "in", .kind = "signal", .rated_min = 0.0, .rated_max = 3.6 },
        .{ .name = "INPUT", .net = "INPUT", .direction = "in", .kind = "power", .rated_min = 11.4, .rated_max = 12.6 },
    };
    const block = env.DesignBlock{
        .name = "relative voltage",
        .instances = &instances,
        .nets = &nets,
        .ports = &ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var passing = try req.runChecks(allocator, &evaluator, &block);
    defer req.deinit(allocator, &passing);
    try std.testing.expectEqual(req.Status.pass, passing.get("U1").?[0].status);

    ports[0].rated_max = 12.0;
    var failing = try req.runChecks(allocator, &evaluator, &block);
    defer req.deinit(allocator, &failing);
    try std.testing.expectEqual(req.Status.fail, failing.get("U1").?[0].status);
}
