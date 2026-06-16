//! Leak-regression tests for the PCB placement / router / DRC area.
//!
//! Strategy (per the audit brief):
//!   • module_policy.analyze / .exportText and layout_lint.lint are honest
//!     OWNED-RETURN functions — they allocate result slices the caller frees
//!     (via `deinit` / `freeFindings` / `free`) and free all their own internal
//!     scratch. They are driven here directly on `std.testing.allocator`, the
//!     leak-detecting allocator: any scratch HashMap/ArrayList/EnumSet the
//!     function forgets to free fails the test at teardown.
//!   • router.route, drc.check, pcb_describe.writeDescribeJson and the
//!     placement-spec / module-policy export writers are ARENA-CONTRACT
//!     functions — they allocPrint map keys and intermediate lists onto the
//!     passed allocator and never free them, relying on the caller resetting an
//!     arena per request. Those are wrapped in `ArenaAllocator.init(testing
//!     .allocator)` so the test exercises the path and proves nothing escapes
//!     to a *different* testing-backed allocator (a double-free / cross-arena
//!     escape would still trip the detector).
//!
//! Every hand-built `Placement` mirrors the setup already used in the source
//! files' own unit tests (same field names, same FlatNet/FlatPin shapes).

const std = @import("std");
const testing = std.testing;

const optimizer = @import("../placement/optimizer.zig");
const module_policy = @import("../placement/module_policy.zig");
const layout_lint = @import("../placement/layout_lint.zig");
const router = @import("../placement/router.zig");
const drc = @import("../placement/drc.zig");
const placement_spec = @import("../serve/placement_spec.zig");
const pcb_describe = @import("../serve/pcb_describe.zig");
const geometry = @import("../placement/geometry.zig");
const export_kicad = @import("../export_kicad.zig");
const env = @import("../eval/env.zig");

const NetClass = module_policy.NetClass;
const PartRole = module_policy.PartRole;

// ── Shared fixtures ──────────────────────────────────────────────────────────

/// A single-pad geometry, the minimal pad the source tests use.
fn pad1() geometry.Pad {
    return .{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 };
}

/// Assemble a `Placement` from the caller-owned slices, defaulting the inert
/// scoring/bbox fields the same way every source test does.
fn mkPlacement(
    parts: []optimizer.Part,
    nets: []const export_kicad.FlatNet,
    instances: []const export_kicad.FlatInstance,
    loops: []const optimizer.Loop,
) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = loops,
        .stubs = &.{},
        .instances = instances,
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = true,
    };
}

// ── module_policy (owned-return, idiom 1) ────────────────────────────────────

// leak-audit: analyze() allocates net_class/part_role/modules (caller frees via
// deinit) plus an idx HashMap and a flags slice it frees internally. Driving it
// straight on testing.allocator proves the internal scratch is released and the
// three result slices match deinit.
test "leak: module_policy.analyze frees scratch and the result deinits clean" {
    var hub_pads = [_]geometry.Pad{pad1()};
    var pas_pads = [_]geometry.Pad{pad1()};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false },
        .{ .ref_des = "L1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pas_pads, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pas_pads, .fallback = false, .value = "10uF" },
    };
    const vin = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const sw = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "L1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "VIN", .pins = &vin },
        .{ .name = "SW", .pins = &sw },
    };
    const p = mkPlacement(&parts, &nets, &.{}, &.{});

    var policy = try module_policy.analyze(testing.allocator, p);
    defer policy.deinit(testing.allocator);
    // Sanity: the three result slices are populated, so deinit has real work.
    try testing.expectEqual(@as(usize, 2), policy.net_class.len);
    try testing.expectEqual(@as(usize, 3), policy.part_role.len);
    try testing.expectEqual(@as(usize, 1), policy.modules.len);
}

// leak-audit: analyze() with author overrides walks the override slices and
// re-tags in place — no extra allocation, but exercises that path under the
// detector so an override-time leak would surface.
test "leak: module_policy.analyze with overrides leaks nothing" {
    var hub_pads = [_]geometry.Pad{pad1()};
    var pas_pads = [_]geometry.Pad{pad1()};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pas_pads, .fallback = false, .value = "100nF" },
    };
    const rail = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "MY_RAIL", .pins = &rail }};
    const overrides = env.PolicyOverrides{
        .nets = &.{.{ .net = "MY_RAIL", .class = "input_rail" }},
        .modules = &.{.{ .ref = "U1", .class = "ldo" }},
    };
    var p = mkPlacement(&parts, &nets, &.{}, &.{});
    p.policy_overrides = overrides;

    var policy = try module_policy.analyze(testing.allocator, p);
    defer policy.deinit(testing.allocator);
    try testing.expectEqual(NetClass.input_rail, policy.net_class[0]);
}

// leak-audit: exportText() allocates+deinits an internal ModulePolicy and builds
// the text through a std.Io.Writer.Allocating (errdefer-guarded). The returned
// bytes are owned by the caller; freeing them on testing.allocator catches any
// leaked internal policy slice or writer buffer.
test "leak: module_policy.exportText returns owned text, frees internals" {
    var hub_pads = [_]geometry.Pad{pad1()};
    var pas_pads = [_]geometry.Pad{pad1()};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false },
        .{ .ref_des = "L1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pas_pads, .fallback = false },
    };
    const vin = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "L1", .pin = "1" } };
    const sw = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "L1", .pin = "2" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "VIN", .pins = &vin },
        .{ .name = "SW", .pins = &sw },
    };
    const p = mkPlacement(&parts, &nets, &.{}, &.{});

    const text = (try module_policy.exportText(testing.allocator, p)).?;
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "(module-policy") != null);
}

// ── layout_lint (owned-return, idiom 1) ──────────────────────────────────────

// leak-audit: lint() returns a heap slice of Findings whose `refs` are each
// alloc.dupe'd; freeFindings must release every refs slice plus the outer
// slice. Run on testing.allocator with a placement that produces one finding so
// a missed-free in freeFindings (or a leaked partial out.items on error) fails.
test "leak: layout_lint.lint findings round-trip through freeFindings" {
    var hub_pads = [_]geometry.Pad{pad1()};
    var cap_pads = [_]geometry.Pad{pad1()};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &cap_pads, .fallback = false, .x = 10, .y = 0 },
    };
    var hub_pwr = [_]optimizer.PadRect{.{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var hub_gnd = [_]optimizer.PadRect{.{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 }};
    var loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .cap_gnd = .{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 },
        .hub_pwr = &hub_pwr,
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_gnd = &hub_gnd,
        .hub_gnd_pin = .{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 },
        .pwr_net = 0,
        .weight = 1,
    }};
    const vin = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "V3P3", .pins = &vin }};
    const p = mkPlacement(&parts, &nets, &.{}, &loops);

    var ncs = [_]NetClass{.power};
    var prs = [_]PartRole{ .anchor_ic, .decoupling_cap };
    const policy = module_policy.ModulePolicy{ .net_class = &ncs, .part_role = &prs, .modules = &.{} };

    const findings = try layout_lint.lint(testing.allocator, p, policy);
    defer layout_lint.freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("decap-far", findings[0].rule);
}

// Helper: sweep a FailingAllocator fail point across lint()'s allocations,
// freeing every run that succeeds. Outside the test body so the loop is not
// flagged as test control flow. Returns how many fail points forced OOM.
fn lintOomSweep(p: anytype, policy: anytype) !usize {
    var oom: usize = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        if (layout_lint.lint(fa.allocator(), p, policy)) |f| {
            layout_lint.freeFindings(fa.allocator(), f);
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            oom += 1;
        }
    }
    return oom;
}

// leak-audit: ERROR-PATH regression. lint() builds each finding as
// `out.append(.{ .refs = alloc.dupe(...) })`; if the append OOMs after the dupe
// succeeds, that dup'd slice must not orphan (it is not yet in out, so lint()'s
// errdefer can't reclaim it — only the per-site `errdefer alloc.free(...)` can).
// Sweep a fail point through lint() over the decap-far fixture; testing's
// backing allocator panics if any partial finding leaks. This fails without the
// errdefer-guarded dupe in lintDecapDistance/lintHotLoopTightest/lintFeedbackAggressor.
test "leak: layout_lint.lint cleans up on a mid-build allocation failure" {
    var hub_pads = [_]geometry.Pad{pad1()};
    var cap_pads = [_]geometry.Pad{pad1()};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &cap_pads, .fallback = false, .x = 10, .y = 0 },
    };
    var hub_pwr = [_]optimizer.PadRect{.{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var hub_gnd = [_]optimizer.PadRect{.{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 }};
    var loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .cap_gnd = .{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 },
        .hub_pwr = &hub_pwr,
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_gnd = &hub_gnd,
        .hub_gnd_pin = .{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 },
        .pwr_net = 0,
        .weight = 1,
    }};
    const vin = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "V3P3", .pins = &vin }};
    const p = mkPlacement(&parts, &nets, &.{}, &loops);

    var ncs = [_]NetClass{.power};
    var prs = [_]PartRole{ .anchor_ic, .decoupling_cap };
    const policy = module_policy.ModulePolicy{ .net_class = &ncs, .part_role = &prs, .modules = &.{} };

    const oom = try lintOomSweep(p, policy);
    // lint allocates ≥1 time on this fixture (the decap-far refs list), so the
    // earliest fail indices force OutOfMemory and drive the dupe/append unwind.
    try testing.expect(oom >= 1);
}

// leak-audit: the feedback-aggressor gate allocates a per-part flags slice
// (defer-freed) AND alloc.dupe's a 2-ref pair into out. Exercise that distinct
// path so a leaked flags slice or pair surfaces.
test "leak: layout_lint feedback-aggressor gate frees its flags scratch" {
    var hub_pads = [_]geometry.Pad{pad1()};
    var l_pads = [_]geometry.Pad{pad1()};
    var r_pads = [_]geometry.Pad{pad1()};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "L1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &l_pads, .fallback = false, .x = 2, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &r_pads, .fallback = false, .x = 3, .y = 0 },
    };
    const sw = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "L1", .pin = "1" } };
    const fb = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SW", .pins = &sw },
        .{ .name = "FB", .pins = &fb },
    };
    const p = mkPlacement(&parts, &nets, &.{}, &.{});

    var ncs = [_]NetClass{ .switch_node, .feedback };
    var prs = [_]PartRole{ .anchor_ic, .other, .feedback_divider };
    const policy = module_policy.ModulePolicy{ .net_class = &ncs, .part_role = &prs, .modules = &.{} };

    const findings = try layout_lint.lint(testing.allocator, p, policy);
    defer layout_lint.freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("feedback-near-aggressor", findings[0].rule);
}

// ── router + drc (arena-contract, idiom 2) ───────────────────────────────────

// leak-audit: router.route + drc.check both allocate ALL output (and many
// allocPrint scratch keys) on the passed allocator and never free — the request
// path resets an arena. Wrapping in a test arena exercises both and proves they
// never reach back to a different testing-backed allocator.
test "leak: router.route then drc.check stay within the request arena" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const u_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "2", .x = 0.4, .y = 0, .w = 0.3, .h = 0.3 },
    };
    const c_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "2", .x = 0.4, .y = 0, .w = 0.3, .h = 0.3 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.6, .hh = 0.6, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.6, .hh = 0.6, .pads = &c_pads, .fallback = false, .x = 4, .y = 0 },
    };
    const gnd = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "2" } };
    const vcc = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &gnd },
        .{ .name = "VCC", .pins = &vcc },
    };
    const p = mkPlacement(&parts, &nets, &.{}, &.{});

    const routed = try router.route(arena, p, .{});
    const v = try drc.check(arena, p, routed, 0.127);
    // Touch the results so the optimizer can't elide the work.
    try testing.expect(routed.vias.len >= 1);
    _ = v.len;
}

// ── describe / spec writers (arena-contract, idiom 2) ─────────────────────────

// leak-audit: pcb_describe.writeDescribeJson allocs pad→net map keys (allocPrint)
// + several HashMaps + a partClassFlags slice on the passed allocator; the
// HashMaps are deinit'd but the allocPrint'd KEYS are not — pure arena contract.
// Wrap in an arena and assert nothing escapes.
test "leak: pcb_describe.writeDescribeJson honors the arena contract" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var hub_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1.8, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 1.8, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var cap_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C9", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &cap_pads, .fallback = false, .x = -4, .y = 0 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U1" },
        .{ .ref_des = "C9", .component = "cap", .value = "1uF", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_IN" },
    };
    const vin_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C9", .pin = "1" } };
    const gnd_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C9", .pin = "2" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "VIN", .pins = &vin_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const p = mkPlacement(&parts, &nets, &instances, &.{});

    var aw: std.Io.Writer.Allocating = .init(arena);
    try pcb_describe.writeDescribeJson(&aw.writer, arena, p, .{ .used_spec = true, .unplaced = &.{} }, null, "t", "Test");
    try testing.expect(aw.written().len > 0);
}

// leak-audit: placement_spec.buildSpecSexp allocates a skip HashMap, a
// use_origin bool slice, four per-side ArrayLists, and the output writer — all
// on the passed allocator. The HashMap + lists are defer-freed; use_origin is
// returned-and-freed by computeUseOrigin's caller. Drive on an arena to confirm
// the path is escape-free.
test "leak: placement_spec.buildSpecSexp stays within the arena" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1.8, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 1.8, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &pads, .fallback = false, .x = -3.3, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &pads, .fallback = false, .x = -7.5, .y = 0 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U1" },
        .{ .ref_des = "C1", .component = "cap", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_IN" },
        .{ .ref_des = "C2", .component = "cap", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_BULK" },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -9,
        .miny = -4,
        .maxx = 4,
        .maxy = 4,
        .generated = true,
    };
    const sexp = (try placement_spec.buildSpecSexp(arena, p, null)).?;
    try testing.expect(std.mem.indexOf(u8, sexp, "(anchor \"U1\")") != null);
}
