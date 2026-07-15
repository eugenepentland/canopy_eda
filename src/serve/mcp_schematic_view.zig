//! Compact "summary" projection of an evaluated design/module block, shared by
//! the `get_schematic` and `preview_module` MCP tools so both surfaces emit an
//! identical shape. The full scene-graph JSON (`src/render_json.zig`) overflows
//! MCP tool-result token limits on real boards, so `summary` is the default and
//! agents opt into the scene graph explicitly.
const std = @import("std");
const json_writer = @import("../json_writer.zig");
const erc_mod = @import("../erc.zig");
const env_mod = @import("../eval/env.zig");
const mcp_checks = @import("mcp_checks.zig");
const mcp_tools = @import("mcp_tools.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;

/// The identity field a summary leads with: `"module"` for preview_module,
/// `"name"` for get_schematic. Bundled so `writeBlockSummary` stays under the
/// parameter-count cap while both tools stay shape-consistent.
pub const Ident = struct {
    key: []const u8,
    value: []const u8,
};

/// Evaluate a design (or standalone module) by name and write the compact
/// summary the `get_schematic` default view returns — the design-facing twin
/// of preview_module's summary, through the same `writeBlockSummary`
/// serializer. The full scene graph overflows MCP token limits on real boards,
/// so agents opt into it with `view=scene_graph`.
pub fn renderNamedSummary(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    out: *std.ArrayList(u8),
) mcp_tools.ToolError!bool {
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const nb = try mcp_tools.evalNamedBlock(allocator, project_dir, name, &eval);
    const w = out.writer(allocator);
    const ident: Ident = .{ .key = "name", .value = name };
    try writeBlockSummary(allocator, w, project_dir, ident, nb.block, eval.assertions.items);
    return true;
}

/// Compact JSON summary of an evaluated block: the `ident` identity field,
/// title, ports, instances (ref_des + component + value, no per-pin detail),
/// nets (name + pin_count), nested sub-block names, ERC violations, and the
/// assertions recorded during evaluation (a block's `(assert / assert-range)`
/// design math surfaces here). Reused verbatim by both MCP tools so their
/// summaries stay shape-identical. Boundary `(port …)` nets look floating when
/// a module is evaluated in isolation — the tool descriptions warn agents.
pub fn writeBlockSummary(
    allocator: std.mem.Allocator,
    w: anytype,
    project_dir: []const u8,
    ident: Ident,
    block: *const env_mod.DesignBlock,
    assertions: []const env_mod.AssertionResult,
) !void {
    try w.writeAll("{\"ok\":true,\"");
    try w.writeAll(ident.key);
    try w.writeAll("\":");
    try json_writer.writeString(w, ident.value);
    try w.writeAll(",\"title\":");
    try json_writer.writeString(w, block.name);
    try w.writeAll(",\"ports\":[");
    for (block.ports, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, p.name);
        try w.writeAll(",\"net\":");
        try json_writer.writeString(w, p.net);
        try w.writeAll(",\"dir\":");
        try json_writer.writeString(w, p.direction);
        try w.writeAll("}");
    }
    try w.writeAll("],\"instances\":[");
    for (block.instances, 0..) |inst, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref_des\":");
        try json_writer.writeString(w, inst.ref_des);
        try w.writeAll(",\"component\":");
        try json_writer.writeString(w, inst.component);
        try w.writeAll(",\"value\":");
        try json_writer.writeString(w, inst.value);
        try w.writeAll("}");
    }
    try w.writeAll("],\"nets\":[");
    for (block.nets, 0..) |net, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, net.name);
        try w.print(",\"pin_count\":{d}}}", .{net.pins.len});
    }
    try w.writeAll("],\"sub_blocks\":[");
    for (block.sub_blocks, 0..) |sb, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, sb.name);
    }
    try w.writeAll("],\"erc\":[");
    const violations = try erc_mod.runErc(allocator, block, project_dir);
    var first = true;
    for (violations) |v| {
        if (!first) try w.writeAll(",");
        first = false;
        try mcp_checks.writeErcViolationJson(w, v);
    }
    try w.writeAll("],\"assertions\":[");
    for (assertions, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"passed\":{},\"warning\":{},\"message\":", .{ a.passed, a.is_warning });
        try json_writer.writeString(w, a.message);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

// spec: serve/mcp_tools - get_schematic defaults to a compact summary far smaller than the full scene graph
test "writeBlockSummary is compact and carries the orienting fields" {
    const render_json = @import("../render_json.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A block with several instances, nets, a port, and a sub-block — enough
    // that the geometry-laden scene graph dwarfs the summary projection.
    var inner: env_mod.DesignBlock = .{
        .name = "pwr-sub",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const insts = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res", .value = "10k", .footprint = "", .symbol = "" },
        .{ .ref_des = "R2", .component = "res", .value = "20k", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "C2", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "C3", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
    };
    const p_vin = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" },
    };
    const p_gnd = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" }, .{ .ref_des = "C3", .pin = "2" },
    };
    const p_out = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "3" }, .{ .ref_des = "R2", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "VIN", .pins = &p_vin },
        .{ .name = "GND", .pins = &p_gnd },
        .{ .name = "OUT", .pins = &p_out },
    };
    const ports = [_]env_mod.Port{.{ .name = "VIN", .net = "VIN", .direction = "in" }};
    const subs = [_]env_mod.SubBlock{.{ .name = "pwr", .block = &inner }};
    var block: env_mod.DesignBlock = .{
        .name = "Test Design",
        .instances = &insts,
        .nets = &nets,
        .ports = &ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
    };

    var summary: std.ArrayList(u8) = .empty;
    const ident: Ident = .{ .key = "name", .value = "test-design" };
    try writeBlockSummary(alloc, summary.writer(alloc), "", ident, &block, &.{});

    // The identity field, orienting sections, an instance ref, a net name, and
    // the sub-block name are all present.
    const needles = [_][]const u8{
        "\"name\":\"test-design\"", "\"instances\"",  "\"nets\"",           "\"erc\"",
        "\"assertions\"",           "\"sub_blocks\"", "\"ref_des\":\"R1\"", "VIN",
        "\"pwr\"",
    };
    for (needles) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, summary.items, needle) != null);
    }

    // The full scene graph is much larger — the summary is a small fraction.
    const scene = try render_json.renderSceneGraph(alloc, &block, "");
    try std.testing.expect(scene.len > summary.items.len * 3);
}
