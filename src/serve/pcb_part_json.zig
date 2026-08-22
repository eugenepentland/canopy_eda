//! PCB-page component metadata that does not belong in the manufacturing
//! FlatInstance contract: browser source-edit provenance plus small shared
//! part JSON fields.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const optimizer = @import("../placement/optimizer.zig");

/// Append the non-default pose fields used by sidecars, caches, and PCB blobs.
pub fn writePoseSideLocked(w: *std.Io.Writer, side: optimizer.Side, locked: bool) std.Io.Writer.Error!void {
    if (side == .bottom) try w.writeAll(",\"side\":\"bottom\"");
    if (locked) try w.writeAll(",\"locked\":true");
}

/// Emit a pad rect as `{"x","y","w","h"}` (footprint-local mm).
pub fn writePadRect(w: *std.Io.Writer, pr: optimizer.PadRect) std.Io.Writer.Error!void {
    try w.print("{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}", .{ pr.x, pr.y, pr.w, pr.h });
}

/// Emit a list of pad rects as a JSON array.
pub fn writePadRectList(w: *std.Io.Writer, list: []const optimizer.PadRect) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (list, 0..) |pr, i| {
        if (i > 0) try w.writeByte(',');
        try writePadRect(w, pr);
    }
    try w.writeByte(']');
}

/// Add the current component family to a part. Placements normally keep parts
/// and instances index-aligned; an empty value makes a malformed fixture safe.
pub fn writeComponentField(w: *std.Io.Writer, instances: []const export_kicad.FlatInstance, index: usize) std.Io.Writer.Error!void {
    try w.writeAll(",\"component\":");
    try writeJsonString(w, if (index < instances.len) instances[index].component else "");
}

/// Build {ref:{src,srcName,srcRef}} for every source-backed instance. Root
/// instances edit root_source; recursion switches to each sub-block's actual
/// module source so a flattened parent board never patches the wrong file.
pub fn buildEditSources(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    root_source: []const u8,
) []const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    const w = &aw.writer;
    w.writeByte('{') catch return "{}";
    var first = true;
    emitBlock(allocator, w, block, "", root_source, &first) catch return "{}";
    w.writeByte('}') catch return "{}";
    return aw.written();
}

fn emitBlock(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    source_name_raw: []const u8,
    first: *bool,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    const source_name = editableSourceName(source_name_raw);
    for (block.instances) |inst| {
        if (inst.source_offset == 0 or source_name.len == 0) continue;
        const ref = try joinedRef(allocator, prefix, inst.ref_des);
        if (!first.*) try w.writeByte(',');
        first.* = false;
        try writeJsonString(w, ref);
        try w.print(":{{\"src\":{d},\"srcName\":", .{inst.source_offset});
        try writeJsonString(w, source_name);
        try w.writeAll(",\"srcRef\":");
        try writeJsonString(w, if (inst.label.len > 0) inst.label else inst.ref_des);
        try w.writeByte('}');
    }
    for (block.sub_blocks) |sub| {
        const sub_prefix = try joinedRef(allocator, prefix, sub.name);
        try emitBlock(allocator, w, sub.block, sub_prefix, sub.source, first);
    }
}

fn joinedRef(allocator: std.mem.Allocator, prefix: []const u8, ref: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return ref;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, ref });
}

/// Only bare design/module names can go through paths.designSourcePath.
/// Relative .sexp sources stay visible but read-only instead of being reduced
/// to a potentially different basename.
fn editableSourceName(name: []const u8) []const u8 {
    if (name.len == 0 or name[0] == '.') return "";
    if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, '\\') != null) return "";
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.endsWith(u8, name, ".sexp")) return "";
    return name;
}

fn writeJsonString(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

// spec: Web Server - PCB passive footprint edits update the exact owning schematic source
test "PCB edit metadata resolves root and nested module sources without flattening paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const child_instances = [_]env_mod.Instance{.{
        .ref_des = "C7",
        .label = "C_FILTER",
        .component = "cap-0402",
        .value = "100nF",
        .footprint = "c-0402",
        .symbol = "generic-cap",
        .source_offset = 73,
    }};
    var child = env_mod.DesignBlock{
        .name = "Filter",
        .instances = &child_instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const root_instances = [_]env_mod.Instance{.{
        .ref_des = "R1",
        .label = "R_BIAS",
        .component = "res-0402",
        .value = "10k",
        .footprint = "r-0402",
        .symbol = "generic-res",
        .source_offset = 19,
    }};
    const subs = [_]env_mod.SubBlock{.{ .name = "filter", .block = &child, .source = "rf-filter" }};
    const root = env_mod.DesignBlock{
        .name = "Board",
        .instances = &root_instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
    };
    const json = buildEditSources(a, &root, "black-canyon");
    try std.testing.expect(std.mem.indexOf(u8, json, "\"R1\":{\"src\":19,\"srcName\":\"black-canyon\",\"srcRef\":\"R_BIAS\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filter/C7\":{\"src\":73,\"srcName\":\"rf-filter\",\"srcRef\":\"C_FILTER\"}") != null);
    try std.testing.expectEqualStrings("", editableSourceName("custom/rf-filter.sexp"));
}
