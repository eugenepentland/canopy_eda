//! PCB-page component metadata that does not belong in the manufacturing
//! FlatInstance contract: browser source-edit provenance plus small shared
//! part JSON fields.

const std = @import("std");
const source_transaction = @import("../infra/source_transaction.zig");
const env_mod = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const json_writer = @import("../json_writer.zig");
const optimizer = @import("../placement/optimizer.zig");

// Every design-derived string below — ref-des, footprint, value, component,
// MPN, pad shape/number, pad net, edit-source names — is serialized with
// `json_writer.writeScriptString`, NOT the plain JSON writer. Both of this
// module's consumers are page paths: `writePartJson` feeds the PCB page's
// `<script>const PCB=…` blob (and the `/api/…` package-refresh response),
// while `buildEditSources` is spliced into that same blob as `part_edits`.
// The script-safe form encodes every `<` as a unicode JSON escape, so no value
// can close the script element; that escape is ordinary JSON, so the API
// consumers parse the original string back unchanged.

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
    try json_writer.writeScriptString(w, if (index < instances.len) instances[index].component else "");
}

/// Add the resolved manufacturer part number used by the Properties inspector.
/// Property keys may come from source-authored fields or KiCad imports, so the
/// lookup follows the rest of the BOM pipeline and remains case-insensitive.
fn writeMpnField(w: *std.Io.Writer, inst: ?export_kicad.FlatInstance) std.Io.Writer.Error!void {
    var mpn: []const u8 = "";
    if (inst) |item| {
        for (item.properties) |property| {
            if (std.ascii.eqlIgnoreCase(property.key, "mpn")) {
                mpn = property.value;
                break;
            }
        }
    }
    try w.writeAll(",\"mpn\":");
    try json_writer.writeScriptString(w, mpn);
}

/// Emit one part's browser pad array, including exact shape/drill metadata and
/// the net resolved by the caller for each `ref|pad` key.
pub fn writePadsJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    part: optimizer.Part,
    pin_net: std.StringHashMapUnmanaged([]const u8),
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    try w.writeAll(",\"pads\":[");
    for (part.pads, 0..) |pad, j| {
        if (j > 0) try w.writeByte(',');
        try w.print("{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"shape\":", .{ pad.x, pad.y, pad.w, pad.h });
        try json_writer.writeScriptString(w, pad.shape);
        try w.writeAll(",\"num\":");
        try json_writer.writeScriptString(w, pad.number);
        if (pad.rot != 0) try w.print(",\"rot\":{d}", .{pad.rot});
        if (pad.rratio() != 0) try w.print(",\"rratio\":{d}", .{pad.rratio()});
        if (pad.isSlot()) try w.print(",\"slot_half\":[{d},{d}]", .{ pad.slot_half[0], pad.slot_half[1] });
        if (pad.thru) try w.writeAll(",\"thru\":true");
        if (pad.poly.len >= 3) {
            try w.writeAll(",\"poly\":[");
            for (pad.poly, 0..) |point, k| {
                if (k > 0) try w.writeByte(',');
                try w.print("[{d},{d}]", .{ point[0], point[1] });
            }
            try w.writeByte(']');
        }
        if (pad.drill > 0) {
            try w.print(",\"drill\":{d}", .{pad.drill});
            if (pad.npth) try w.writeAll(",\"npth\":true");
        }
        const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ part.ref_des, pad.number });
        if (pin_net.get(key)) |net| {
            try w.writeAll(",\"net\":");
            try json_writer.writeScriptString(w, net);
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

/// Geometry-bearing JSON for one PCB part. Shared by the initial board blob
/// and the live passive-footprint refresh response.
pub fn writePartJson(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    index: usize,
    blame: f64,
    pin_net: std.StringHashMapUnmanaged([]const u8),
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    const part = placement.parts[index];
    const inst: ?export_kicad.FlatInstance = if (index < placement.instances.len) placement.instances[index] else null;
    try w.writeAll("{\"ref\":");
    try json_writer.writeScriptString(w, part.ref_des);
    try w.writeAll(",\"origin\":");
    try json_writer.writeScriptString(w, if (inst) |item| item.origin_key else "");
    try w.print(",\"x\":{d},\"y\":{d},\"rot\":{d},\"hw\":{d},\"hh\":{d},\"kind\":\"{s}\",\"fb\":{s}", .{
        part.x,                                      part.y,                                 part.rot, part.hw, part.hh,
        if (part.kind == .hub) "hub" else "passive", if (part.fallback) "true" else "false",
    });
    if (part.ccx != 0 or part.ccy != 0) try w.print(",\"ccx\":{d},\"ccy\":{d}", .{ part.ccx, part.ccy });
    try writePoseSideLocked(w, part.side, part.locked);
    try w.print(",\"blame\":{d:.4},\"fp\":", .{blame});
    try json_writer.writeScriptString(w, if (inst) |item| item.footprint else "");
    try w.writeAll(",\"val\":");
    try json_writer.writeScriptString(w, if (inst) |item| instanceLabel(item) else "");
    try writeComponentField(w, placement.instances, index);
    try writeMpnField(w, inst);
    try writePadsJson(w, alloc, part, pin_net);
    try w.writeAll(",\"silk\":{\"l\":[");
    for (part.features.silk_lines, 0..) |line, j| {
        if (j > 0) try w.writeByte(',');
        try w.print("[{d},{d},{d},{d}]", .{ line.x1, line.y1, line.x2, line.y2 });
    }
    try w.writeAll("],\"c\":[");
    for (part.features.silk_circles, 0..) |circle, j| {
        if (j > 0) try w.writeByte(',');
        try w.print("[{d},{d},{d}]", .{ circle.cx, circle.cy, circle.r });
    }
    try w.writeAll("]}}");
}

fn instanceLabel(inst: export_kicad.FlatInstance) []const u8 {
    if (inst.value.len > 0) return inst.value;
    for (inst.properties) |property| {
        if (std.mem.eql(u8, property.key, "value") and property.value.len > 0) return property.value;
    }
    return inst.component;
}

/// Build {ref:{src,srcName,srcRef}} for every source-backed instance. Root
/// instances edit root_source; recursion switches to each sub-block's actual
/// module source so a flattened parent board never patches the wrong file.
pub const SourceLocation = struct { name: []const u8, project_dir: []const u8 = "" };

pub fn buildEditSources(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    root_source: SourceLocation,
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
    source: SourceLocation,
    first: *bool,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    const source_name = editableSourceName(source.name);
    const revision = source_transaction.revisionFor(allocator, source.project_dir, source_name);
    for (block.instances) |inst| {
        if (inst.source_offset == 0 or source_name.len == 0) continue;
        const ref = try joinedRef(allocator, prefix, inst.ref_des);
        if (!first.*) try w.writeByte(',');
        first.* = false;
        try json_writer.writeScriptString(w, ref);
        try w.print(":{{\"src\":{d},\"srcName\":", .{inst.source_offset});
        try json_writer.writeScriptString(w, source_name);
        try w.writeAll(",\"srcRef\":");
        try json_writer.writeScriptString(w, if (inst.label.len > 0) inst.label else inst.ref_des);
        if (revision) |value| {
            try w.writeAll(",\"sourceRevision\":");
            try json_writer.writeScriptString(w, &value);
        }
        try w.writeByte('}');
    }
    for (block.sub_blocks) |sub| {
        const sub_prefix = try joinedRef(allocator, prefix, sub.name);
        try emitBlock(allocator, w, sub.block, sub_prefix, .{ .name = sub.source, .project_dir = source.project_dir }, first);
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
    const json = buildEditSources(a, &root, .{ .name = "black-canyon" });
    try std.testing.expect(std.mem.indexOf(u8, json, "\"R1\":{\"src\":19,\"srcName\":\"black-canyon\",\"srcRef\":\"R_BIAS\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"filter/C7\":{\"src\":73,\"srcName\":\"rf-filter\",\"srcRef\":\"C_FILTER\"}") != null);
    try std.testing.expectEqualStrings("", editableSourceName("custom/rf-filter.sexp"));
}

test "live PCB part JSON carries replacement footprint geometry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.8,
        .hh = 0.5,
        .pads = &.{.{ .number = "1", .x = -0.5, .y = 0, .w = 0.6, .h = 0.7, .shape = "roundrect" }},
        .fallback = false,
        .features = .{ .silk_lines = &.{.{ .x1 = -0.2, .y1 = -0.2, .x2 = 0.2, .y2 = -0.2 }} },
    }};
    const properties = [_]env_mod.Property{.{ .key = "MPN", .value = "GRM155R71C104KA88" }};
    const instances = [_]export_kicad.FlatInstance{.{
        .ref_des = "C1",
        .component = "cap-0201",
        .origin_key = "C_FILTER",
        .value = "100nF",
        .footprint = "c-0201",
        .properties = &properties,
        .uuid = "",
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 2,
        .maxy = 1,
        .generated = false,
    };
    var writer: std.Io.Writer.Allocating = .init(alloc);
    defer writer.deinit();
    try writePartJson(&writer.writer, alloc, placement, 0, 0, .empty);
    const json = writer.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"component\":\"cap-0201\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mpn\":\"GRM155R71C104KA88\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"fp\":\"c-0201\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"pads\":[{\"x\":-0.5") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
}

// spec: Web Server - Part fields in the PCB blob are escaped for the script element they sit in, so no ref-des, value, MPN, footprint, pad or pad-net name can close the tag
test "part JSON escapes a closing script tag in every design-derived string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // The tag break is planted in every string this writer takes from a design:
    // ref-des, origin key, footprint, value, component, MPN, pad shape, pad
    // number, and the pad's net. The blob it lands in is written straight into
    // `<script>const PCB=…`, and MPN is editable over HTTP, so reaching this
    // needs no saved design at all.
    const evil = "</script><script>alert(1)</script>";
    var parts = [_]optimizer.Part{.{
        .ref_des = evil,
        .kind = .passive,
        .hw = 0.8,
        .hh = 0.5,
        .pads = &.{.{ .number = evil, .x = -0.5, .y = 0, .w = 0.6, .h = 0.7, .shape = evil }},
        .fallback = false,
    }};
    const properties = [_]env_mod.Property{.{ .key = "MPN", .value = evil }};
    const instances = [_]export_kicad.FlatInstance{.{
        .ref_des = evil,
        .component = evil,
        .origin_key = evil,
        .value = evil,
        .footprint = evil,
        .properties = &properties,
        .uuid = "",
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 2,
        .maxy = 1,
        .generated = false,
    };
    var pin_net = std.StringHashMapUnmanaged([]const u8).empty;
    try pin_net.put(alloc, try std.fmt.allocPrint(alloc, "{s}|{s}", .{ evil, evil }), evil);

    var writer: std.Io.Writer.Allocating = .init(alloc);
    try writePartJson(&writer.writer, alloc, placement, 0, 0, pin_net);
    const json = writer.written();

    // Nothing an HTML parser reads as a tag survives anywhere in the part…
    try std.testing.expect(std.mem.indexOf(u8, json, "</script>") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, json, '<') == null);
    // …and every one of the nine fields is escaped, not merely dropped.
    try std.testing.expectEqual(
        @as(usize, 9),
        std.mem.count(u8, json, "\\u003c/script>\\u003cscript>alert(1)\\u003c/script>"),
    );

    // The escape is ordinary JSON, so the plain-JSON consumer of this same
    // writer — the package-refresh response — still reads the exact strings.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    try std.testing.expectEqualStrings(evil, parsed.object.get("ref").?.string);
    try std.testing.expectEqualStrings(evil, parsed.object.get("val").?.string);
    try std.testing.expectEqualStrings(evil, parsed.object.get("mpn").?.string);
    try std.testing.expectEqualStrings(evil, parsed.object.get("fp").?.string);
    try std.testing.expectEqualStrings(evil, parsed.object.get("component").?.string);
    const pad = parsed.object.get("pads").?.array.items[0].object;
    try std.testing.expectEqualStrings(evil, pad.get("net").?.string);
    try std.testing.expectEqualStrings(evil, pad.get("shape").?.string);

    // A lexical gate cannot protect this file any more: the `<` in the
    // assertion above makes the whole FILE read as script-safe, so
    // `script-string-safety` is pinned green here and a SECOND, private escaper
    // added later would slip past it. This is that guard — it fails on the
    // quote-escaping switch arm every hand-rolled JSON escaper starts from, and
    // on the plain sink. Both needles are split so neither is its own
    // counterexample.
    const source = @embedFile("pcb_part_json.zig");
    const private_quote_arm = "'\"'" ++ " =>";
    try std.testing.expect(std.mem.indexOf(u8, source, private_quote_arm) == null);
    const unsafe_sink = "json_writer." ++ "writeString(";
    try std.testing.expect(std.mem.indexOf(u8, source, unsafe_sink) == null);
}

// spec: Web Server - Edit-source provenance in the PCB blob is escaped for the script element, so neither a ref-des key nor an instance label can close the tag
test "PCB edit-source provenance escapes a closing script tag in ref-des and label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `buildEditSources` output is spliced verbatim into the same blob as the
    // `part_edits` member, so its keys and labels need the same escaping.
    const evil = "</script><script>alert(1)</script>";
    const root_instances = [_]env_mod.Instance{.{
        .ref_des = evil,
        .label = evil,
        .component = "res-0402",
        .value = "10k",
        .footprint = "r-0402",
        .symbol = "generic-res",
        .source_offset = 19,
    }};
    const root = env_mod.DesignBlock{
        .name = "Board",
        .instances = &root_instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const json = buildEditSources(a, &root, .{ .name = "black-canyon" });
    try std.testing.expect(std.mem.indexOf(u8, json, "</script>") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, json, '<') == null);

    // Key and `srcRef` both round-trip through JSON unchanged.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    const entry = parsed.object.get(evil).?.object;
    try std.testing.expectEqualStrings(evil, entry.get("srcRef").?.string);
    try std.testing.expectEqualStrings("black-canyon", entry.get("srcName").?.string);
}
