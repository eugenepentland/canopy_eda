//! Pure JSON → saved-layout-type parsers for the `.layouts.json` sidecar
//! (and the request bodies that reuse its shapes). Split from
//! `pcb_layout_page.zig`, which holds the types and every read/write path;
//! this module is the leaf layer with no filesystem access, so the parse
//! rules live in one place whichever surface feeds them JSON.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const numeric = @import("../numeric.zig");
const font5x7 = @import("../font5x7.zig");
const optimizer = @import("../placement/optimizer.zig");
const outline_mod = @import("../placement/outline.zig");
const outline_sketch = @import("../outline_sketch.zig");
const outline_sketch_json = @import("outline_sketch_json.zig");
const invalid_zone_sketch: outline_sketch.Sketch = .{ .points = &.{}, .curves = &.{} };
const page = @import("pcb_layout_page.zig");
const env_mod = @import("../eval/env.zig");
const SavedRfPath = @typeInfo(@FieldType(page.SavedRoutes, "rf_paths")).pointer.child;

/// Parse a pose object's optional `"side"` field ("bottom" → bottom, else top).
pub fn jsonSide(v: ?std.json.Value) optimizer.Side {
    const s = v orelse return .top;
    return if (s == .string) optimizer.Side.fromStr(s.string) else .top;
}

/// Parse a pose object's optional boolean field (absent/non-bool → false).
pub fn jsonFlag(v: ?std.json.Value) bool {
    const b = v orelse return false;
    return b == .bool and b.bool;
}

/// A JSON integer field (float lossy-cast), or 0 when absent/non-numeric.
pub fn jsonInt(v: ?std.json.Value) i64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| i,
        .float => |f| std.math.lossyCast(i64, f),
        else => 0,
    };
}

/// A JSON numeric field as f64 (integer or float), or 0 when absent/non-numeric.
pub fn jsonNum(v: ?std.json.Value) f64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => 0,
    };
}

/// As `jsonNum`, but absent/non-numeric reads as null instead of 0.
pub fn jsonOptNum(v: ?std.json.Value) ?f64 {
    const val = v orelse return null;
    const n: f64 = switch (val) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}

/// Parse a `[{"ref","x","y","rot"}, …]` JSON array into `page.PartPose`s. Null when
/// the value is missing or not an array; bad elements are skipped.
pub fn parsePartPoses(alloc: std.mem.Allocator, v: ?std.json.Value) ?[]const page.PartPose {
    const arr = v orelse return null;
    if (arr != .array) return null;
    var list: std.ArrayList(page.PartPose) = .empty;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        if (ref != .string) continue;
        const origin: []const u8 = blk: {
            const ov = it.object.get("origin") orelse break :blk "";
            break :blk if (ov == .string) ov.string else "";
        };
        list.append(alloc, .{
            .ref = ref.string,
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = jsonNum(it.object.get("rot")),
            .origin = origin,
            .side = jsonSide(it.object.get("side")),
            .locked = jsonFlag(it.object.get("locked")),
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch null;
}

/// Parse a `{"tracks":[…],"vias":[…],"zones":[…]}` saved-routes object (the
/// same shape the live route JSON and the layouts sidecar use). `zones` is
/// optional for backward compatibility. Null when absent, malformed, or empty.
/// Public so the KiCad-sync tests can build a `page.SavedRoutes` from JSON (the
/// `page.SavedTrack`/`page.SavedVia` element types stay private).
pub fn parseSavedRoutes(alloc: std.mem.Allocator, v: ?std.json.Value) ?page.SavedRoutes {
    const obj = v orelse return null;
    if (obj != .object) return null;
    var tracks: std.ArrayList(page.SavedTrack) = .empty;
    if (obj.object.get("tracks")) |tv| if (tv == .array) {
        for (tv.array.items) |it| {
            if (it != .object) continue;
            tracks.append(alloc, .{
                .x1 = jsonNum(it.object.get("x1")),
                .y1 = jsonNum(it.object.get("y1")),
                .x2 = jsonNum(it.object.get("x2")),
                .y2 = jsonNum(it.object.get("y2")),
                .xm = jsonOptNum(it.object.get("xm")),
                .ym = jsonOptNum(it.object.get("ym")),
                // Signal-layer index (0=top, 1=bottom, 2..=inner). Legacy
                // entries with no "l" stay top copper; out-of-range values
                // clamp defensively rather than wrapping.
                .l = layerIndexFromJson(it.object.get("l")),
                .w = jsonNum(it.object.get("w")),
                .net = jsonStrField(it.object.get("net")),
                .g = jsonStrField(it.object.get("g")),
                .source = jsonStrField(it.object.get("source")),
                .id = jsonStrField(it.object.get("id")),
            }) catch return null;
        }
    };
    var vias: std.ArrayList(page.SavedVia) = .empty;
    if (obj.object.get("vias")) |vv| if (vv == .array) {
        for (vv.array.items) |it| {
            if (it != .object) continue;
            vias.append(alloc, .{
                .x = jsonNum(it.object.get("x")),
                .y = jsonNum(it.object.get("y")),
                .d = jsonNum(it.object.get("d")),
                .drill = jsonNum(it.object.get("drill")),
                .net = jsonStrField(it.object.get("net")),
                .g = jsonStrField(it.object.get("g")),
                .f = jsonStrField(it.object.get("f")),
                .source = jsonStrField(it.object.get("source")),
                .s = parseViaSpan(it.object.get("s")),
                .id = jsonStrField(it.object.get("id")),
            }) catch return null;
        }
    };
    var zones: std.ArrayList(page.SavedZone) = .empty;
    if (obj.object.get("zones")) |zv| if (zv == .array) {
        for (zv.array.items) |it| {
            if (it != .object) continue;
            var sketch: ?outline_sketch.Sketch = null;
            const poly = if (it.object.get("sketch")) |sketch_value| blk: {
                sketch = outline_sketch_json.parse(alloc, sketch_value) orelse invalid_zone_sketch;
                const compiled = outline_sketch.compile(alloc, sketch.?, outline_sketch.default_sagitta_mm) catch {
                    break :blk parseOutlinePts(alloc, it.object.get("poly")) orelse &.{};
                };
                break :blk compiled.poly;
            } else parseOutlinePts(alloc, it.object.get("poly")) orelse continue;
            zones.append(alloc, .{
                .net = jsonStrField(it.object.get("net")),
                .layer = jsonStrField(it.object.get("layer")),
                .poly = poly,
                .filled = jsonFlag(it.object.get("filled")),
                .keepout = jsonFlag(it.object.get("keepout")),
                .priority = jsonInt(it.object.get("priority")),
                .sketch = sketch,
            }) catch return null;
        }
    };
    var rf_paths: std.ArrayList(SavedRfPath) = .empty;
    if (obj.object.get("rf_paths")) |rv| if (rv == .array) {
        for (rv.array.items) |it| {
            if (it != .object) continue;
            const net = jsonStrField(it.object.get("net"));
            if (net.len == 0) continue;
            const sv = it.object.get("samples") orelse continue;
            if (sv != .array or sv.array.items.len < 2) continue;
            var samples: std.ArrayList(@import("../placement/rf_path_solver.zig").Sample) = .empty;
            var previous: ?[2]f64 = null;
            var s_mm: f64 = 0;
            for (sv.array.items) |sample| {
                if (sample != .array or sample.array.items.len < 3) continue;
                const at = [2]f64{ jsonNum(sample.array.items[0]), jsonNum(sample.array.items[1]) };
                if (previous) |before| s_mm += std.math.hypot(at[0] - before[0], at[1] - before[1]);
                samples.append(alloc, .{ .at = at, .s_mm = s_mm, .curvature = 0, .width_mm = jsonNum(sample.array.items[2]) }) catch return null;
                previous = at;
            }
            if (samples.items.len < 2) continue;
            rf_paths.append(alloc, .{
                .net = net,
                .layer = layerIndexFromJson(it.object.get("l")),
                .samples = samples.toOwnedSlice(alloc) catch return null,
            }) catch return null;
        }
    };
    if (tracks.items.len == 0 and vias.items.len == 0 and zones.items.len == 0 and rf_paths.items.len == 0) return null;
    return .{
        .tracks = tracks.toOwnedSlice(alloc) catch return null,
        .vias = vias.toOwnedSlice(alloc) catch return null,
        .zones = zones.toOwnedSlice(alloc) catch return null,
        .rf_paths = rf_paths.toOwnedSlice(alloc) catch return null,
    };
}

/// Serialize zone records in the sidecar/embedded `PCB.zones` shape. Kept by
/// the sidecar codec so adding authoring metadata does not grow the page/API
/// module that merely embeds the result.
pub fn writeSavedZonesJson(w: *std.Io.Writer, zones: []const page.SavedZone) std.Io.Writer.Error!void {
    try w.writeAll("[");
    for (zones, 0..) |zone, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try page.writeJsonStr(w, zone.net);
        try w.writeAll(",\"layer\":");
        try page.writeJsonStr(w, zone.layer);
        try w.writeAll(",\"poly\":[");
        for (zone.poly, 0..) |point, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.print("[{d},{d}]", .{ point[0], point[1] });
        }
        try w.print("],\"filled\":{s},\"keepout\":{s}", .{
            if (zone.filled) "true" else "false",
            if (zone.keepout) "true" else "false",
        });
        if (zone.sketch) |sketch| {
            try w.writeAll(",\"sketch\":");
            try outline_sketch_json.write(w, sketch);
        }
        if (zone.priority != 0) try w.print(",\"priority\":{d}", .{zone.priority});
        try w.writeByte('}');
    }
    try w.writeAll("]");
}

/// A via's optional `"s":[from,to]` LAYER SPAN → the two routable indices, or
/// null when absent/malformed — the full-stack through barrel every board here
/// has today (see `page.SavedVia`). Each end is read through the same clamp
/// track layers take, so a corrupt file cannot wrap a u8; a single-element or
/// non-array value is simply no span rather than half of one.
pub fn parseViaSpan(v: ?std.json.Value) ?[2]u8 {
    const arr = v orelse return null;
    if (arr != .array or arr.array.items.len != 2) return null;
    return .{
        layerIndexFromJson(arr.array.items[0]),
        layerIndexFromJson(arr.array.items[1]),
    };
}

/// A JSON `l` field → signal-layer index: absent/negative ⇒ 0 (top, the
/// legacy meaning), clamped into u8 so a corrupt sidecar can't wrap.
pub fn layerIndexFromJson(v: ?std.json.Value) u8 {
    const n = jsonNum(v);
    if (!(n >= 1)) return 0;
    if (n >= board_layers.max_sidecar_layer) return board_layers.max_sidecar_layer;
    return numeric.checkedInt(u8, @floor(n)) orelse 0;
}

/// Parse an `{"x","y","w","h"[,"pts":[[x,y],…]]}` outline object; null when
/// absent/malformed or degenerate (w/h must be positive real board
/// dimensions). A valid `pts` closed polygon (≥3 vertices) wins: x/y/w/h are
/// re-derived from its bounding box so the rect fields can never drift from
/// the polygon (old rect-only sidecars keep loading unchanged).
pub fn parseSavedOutline(alloc: std.mem.Allocator, v: ?std.json.Value) ?page.SavedOutline {
    const obj = v orelse return null;
    if (obj != .object) return null;
    if (outline_sketch_json.parse(alloc, obj.object.get("sketch"))) |sketch| {
        const compiled = outline_sketch.compile(alloc, sketch, outline_sketch.default_sagitta_mm) catch return null;
        return .{
            .x = compiled.rect.minx,
            .y = compiled.rect.miny,
            .w = compiled.rect.w,
            .h = compiled.rect.h,
            .pts = compiled.pts,
            .derived = .{ .poly = compiled.poly, .arcs = compiled.arcs },
            .sketch = sketch,
        };
    }
    if (parseOutlinePts(alloc, obj.object.get("pts"))) |pts| {
        const radii = parseOutlineRadii(alloc, obj.object.get("radii"), pts.len);
        const fillet = if (radii) |rs| outline_mod.filletPath(alloc, pts, rs, 0.01) catch null else null;
        const poly = if (fillet) |f| f.poly else pts;
        const bb = outline_mod.bboxRect(poly);
        if (bb.w > 0 and bb.h > 0) return .{
            .x = bb.minx,
            .y = bb.miny,
            .w = bb.w,
            .h = bb.h,
            .pts = pts,
            .radii = radii,
            .derived = .{ .poly = poly, .arcs = if (fillet) |f| f.arcs else &.{} },
        };
        alloc.free(pts);
    }
    const o = page.SavedOutline{
        .x = jsonNum(obj.object.get("x")),
        .y = jsonNum(obj.object.get("y")),
        .w = jsonNum(obj.object.get("w")),
        .h = jsonNum(obj.object.get("h")),
    };
    if (!(o.w > 0) or !(o.h > 0)) return null;
    return o;
}

test "saved outline prefers the versioned sketch and compiles its native arcs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const source =
        "{\"x\":99,\"y\":99,\"w\":1,\"h\":1,\"sketch\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":10,\"y\":0}," ++
        "{\"id\":3,\"x\":10,\"y\":10},{\"id\":4,\"x\":0,\"y\":10}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"arc\",\"a\":1,\"b\":2,\"mid\":[5,-2]}," ++
        "{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4}," ++
        "{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}}";
    var tree = try std.json.parseFromSlice(std.json.Value, alloc, source, .{});
    defer tree.deinit();
    const got = parseSavedOutline(alloc, tree.value) orelse return error.TestUnexpectedResult;
    try std.testing.expect(got.sketch != null);
    try std.testing.expectEqual(@as(usize, 1), got.derived.arcs.len);
    try std.testing.expect(got.derived.poly.?.len > got.pts.?.len);
    try std.testing.expectEqual(@as(f64, 10), got.w);
    try std.testing.expect(got.y < 0);
}

// spec: Web Server - Custom copper pours and board outlines use one versioned shape-sketch engine: a pour exposes the outline editor's rectangle/line creation, vertex and edge editing, dimensions, geometric constraints, arc/line conversion, fillet removal/addition, chamfer, offset, mirror, selection deletion and undo/redo; its native sketch round-trips while fill, routing, DRC and export consume the compiled polygon
test "saved copper zone sketch compiles native arcs and rejects an open profile" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const closed =
        "{\"tracks\":[],\"vias\":[],\"zones\":[{\"net\":\"GND\",\"layer\":\"F.Cu\",\"filled\":true," ++
        "\"poly\":[[99,99],[100,99],[100,100]],\"sketch\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":10,\"y\":0},{\"id\":3,\"x\":10,\"y\":10},{\"id\":4,\"x\":0,\"y\":10}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"arc\",\"a\":1,\"b\":2,\"mid\":[5,-2]},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}}]}";
    const closed_value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, closed, .{});
    const routes = parseSavedRoutes(alloc, closed_value) orelse return error.TestUnexpectedResult;
    try std.testing.expect(routes.zones[0].sketch != null);
    try std.testing.expect(routes.zones[0].poly.len > 4);
    try std.testing.expect(routes.zones[0].poly[0][0] < 1);
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    try encoded.writer.writeAll("{\"tracks\":[],\"vias\":[],\"zones\":");
    try writeSavedZonesJson(&encoded.writer, routes.zones);
    try encoded.writer.writeByte('}');
    const encoded_value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, encoded.written(), .{});
    const round_trip = parseSavedRoutes(alloc, encoded_value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(outline_sketch.CurveKind.arc, round_trip.zones[0].sketch.?.curves[0].kind);

    const open = "{\"tracks\":[],\"vias\":[],\"zones\":[{\"net\":\"GND\",\"layer\":\"F.Cu\",\"poly\":[[0,0],[1,0],[0,1]],\"sketch\":{\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":1,\"y\":0}],\"curves\":[{\"id\":3,\"kind\":\"line\",\"a\":1,\"b\":2}],\"constraints\":[]}}]}";
    const open_value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, open, .{});
    const invalid_routes = parseSavedRoutes(alloc, open_value) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.OpenProfile, outline_sketch.compile(alloc, invalid_routes.zones[0].sketch.?, outline_sketch.default_sagitta_mm));
    const rejection = saveRejection(alloc, null, tSavedWithZones(invalid_routes.zones)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, rejection, "invalid copper pour sketch") != null);
}

/// Parse visually edited backing polygons from a saved layout. Invalid
/// regions are dropped independently; a layer with none is ignored.
pub fn parseSavedFabricationLayers(alloc: std.mem.Allocator, v: ?std.json.Value) []const page.SavedFabricationLayer {
    const arr = v orelse return &.{};
    if (arr != .array) return &.{};
    var layers: std.ArrayList(page.SavedFabricationLayer) = .empty;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const nv = item.object.get("name") orelse continue;
        const rv = item.object.get("regions") orelse continue;
        if (nv != .string or nv.string.len == 0 or rv != .array) continue;
        var regions: std.ArrayList([]const [2]f64) = .empty;
        for (rv.array.items) |region_value| {
            const points = parseOutlinePts(alloc, region_value) orelse continue;
            if (!outline_mod.valid(points)) {
                alloc.free(points);
                continue;
            }
            regions.append(alloc, points) catch return layers.items;
        }
        if (regions.items.len == 0) continue;
        layers.append(alloc, .{
            .name = nv.string,
            .regions = regions.toOwnedSlice(alloc) catch return layers.items,
        }) catch return layers.items;
    }
    return layers.toOwnedSlice(alloc) catch layers.items;
}

/// Parse one saved physical heatsink. Malformed or non-physical geometry is
/// rejected as a unit: silently retaining half an assembly would make the 3D
/// preview and thermal solve describe different hardware.
pub fn parseSavedHeatsink(v: ?std.json.Value) ?page.SavedHeatsink {
    const value = v orelse return null;
    if (value != .object) return null;
    const obj = value.object;
    const x = jsonOptNum(obj.get("x")) orelse return null;
    const y = jsonOptNum(obj.get("y")) orelse return null;
    const w = jsonOptNum(obj.get("w")) orelse return null;
    const h = jsonOptNum(obj.get("h")) orelse return null;
    const base = jsonOptNum(obj.get("base_mm")) orelse 2;
    const fin_height = jsonOptNum(obj.get("fin_height_mm")) orelse 10;
    const fin_thickness = jsonOptNum(obj.get("fin_thickness_mm")) orelse 1;
    const fin_gap = jsonOptNum(obj.get("fin_gap_mm")) orelse 1.5;
    const pad_thickness = jsonOptNum(obj.get("pad_thickness_mm")) orelse 0.5;
    const pad_k = jsonOptNum(obj.get("pad_k_w_mk")) orelse 6;
    if (!(w > 0) or !(h > 0)) return null;
    if (!(base > 0) or !(fin_height >= 0)) return null;
    if (!(fin_thickness > 0) or !(fin_gap >= 0)) return null;
    if (!(pad_thickness >= 0) or !(pad_k > 0)) return null;

    const side = stringChoice(obj.get("side"), &.{ "top", "bottom" }, "bottom");
    const material = stringChoice(obj.get("material"), &.{ "aluminum_6063", "aluminum_6061", "copper_c110", "steel" }, "aluminum_6063");
    const fin_axis = stringChoice(obj.get("fin_axis"), &.{ "length", "width" }, "length");
    const target = obj.get("target_ref") orelse return null;
    if (target != .string or target.string.len == 0) return null;
    return .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .side = side,
        .target_ref = target.string,
        .material = material,
        .base_mm = base,
        .fin_height_mm = fin_height,
        .fin_thickness_mm = fin_thickness,
        .fin_gap_mm = fin_gap,
        .fin_axis = fin_axis,
        .pad_thickness_mm = pad_thickness,
        .pad_k_w_mk = pad_k,
    };
}

fn stringChoice(v: ?std.json.Value, choices: []const []const u8, fallback: []const u8) []const u8 {
    const value = v orelse return fallback;
    if (value != .string) return fallback;
    for (choices) |choice| if (std.mem.eql(u8, value.string, choice)) return choice;
    return fallback;
}

test "saved fabrication backing parses named valid polygons only" {
    const source =
        \\[
        \\  {"name":"psb_tape.gbr","side":"top","material":"wrong",
        \\   "regions":[[[0,0],[8,0],[8,4],[0,4]],[[0,0],[4,4],[0,4],[4,0]]]},
        \\  {"name":"","regions":[[[0,0],[1,0],[0,1]]]}
        \\]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();
    const layers = parseSavedFabricationLayers(std.testing.allocator, parsed.value);
    defer {
        for (layers) |layer| {
            for (layer.regions) |region| std.testing.allocator.free(region);
            std.testing.allocator.free(layer.regions);
        }
        std.testing.allocator.free(layers);
    }
    try std.testing.expectEqual(@as(usize, 1), layers.len);
    try std.testing.expectEqualStrings("psb_tape.gbr", layers[0].name);
    try std.testing.expectEqual(@as(usize, 1), layers[0].regions.len);
    try std.testing.expectEqual(@as(f64, 8), layers[0].regions[0][1][0]);
}

/// Parse a per-vertex fillet-radius array (index-aligned with `pts`); null
/// when absent, mis-sized, malformed, or all-zero (nothing to fillet).
pub fn parseOutlineRadii(alloc: std.mem.Allocator, v: ?std.json.Value, count: usize) ?[]const f64 {
    const arr = v orelse return null;
    if (arr != .array or arr.array.items.len != count) return null;
    const radii = alloc.alloc(f64, count) catch return null;
    var any = false;
    for (arr.array.items, 0..) |item, i| {
        const radius = jsonOptNum(item) orelse {
            alloc.free(radii);
            return null;
        };
        radii[i] = @max(0, radius);
        any = any or radii[i] > 0;
    }
    if (!any) {
        alloc.free(radii);
        return null;
    }
    return radii;
}

/// Parse a `[[x,y],…]` polygon vertex array: ≥3 well-formed 2-number pairs,
/// else null (malformed entries reject the whole polygon rather than
/// silently reshaping the board).
pub fn parseOutlinePts(alloc: std.mem.Allocator, v: ?std.json.Value) ?[]const [2]f64 {
    const arr = v orelse return null;
    if (arr != .array or arr.array.items.len < 3) return null;
    const pts = alloc.alloc([2]f64, arr.array.items.len) catch return null;
    for (arr.array.items, 0..) |it, i| {
        if (it != .array or it.array.items.len != 2) {
            alloc.free(pts);
            return null;
        }
        pts[i] = .{ jsonNum(it.array.items[0]), jsonNum(it.array.items[1]) };
    }
    return pts;
}

/// Parse a `[{"x","y","rot","side","size","text","subcircuit"?,"testpoint"?,"fabrication_id"?}, …]`
/// board-text array. Empty
/// slice when absent/malformed; entries with an empty `text` are dropped (a
/// blank label has nothing to stroke). `side` is "bottom" ⇒ bottom silk; `size`
/// defaults to the conventional 1 mm nominal size; `rot` snaps to
/// 0/90/180/270.
pub fn parseSavedTexts(alloc: std.mem.Allocator, v: ?std.json.Value) []const font5x7.BoardText {
    const arr = v orelse return &.{};
    if (arr != .array) return &.{};
    var list: std.ArrayList(font5x7.BoardText) = .empty;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const tv = it.object.get("text") orelse continue;
        if (tv != .string or tv.string.len == 0) continue;
        const side = jsonStrField(it.object.get("side"));
        const subcircuit = jsonStrField(it.object.get("subcircuit"));
        const testpoint = jsonStrField(it.object.get("testpoint"));
        const fabrication_id = it.object.get("fabrication_id");
        const size = jsonNum(it.object.get("size"));
        list.append(alloc, .{
            .x = jsonNum(it.object.get("x")),
            .y = jsonNum(it.object.get("y")),
            .rot = @mod(@round(jsonNum(it.object.get("rot")) / 90) * 90, 360),
            .bottom = std.mem.eql(u8, side, "bottom"),
            .size = if (size > 0) size else font5x7.default_size_mm,
            .text = tv.string,
            .owner = if (subcircuit.len > 0)
                .{ .subcircuit = subcircuit }
            else if (testpoint.len > 0)
                .{ .testpoint = testpoint }
            else
                null,
            .fabrication_id = fabrication_id != null and fabrication_id.? == .bool and fabrication_id.?.bool,
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

/// A pose/route JSON string field, or "" when absent/not a string.
pub fn jsonStrField(v: ?std.json.Value) []const u8 {
    const sv = v orelse return "";
    return if (sv == .string) sv.string else "";
}

/// What a layout SAVE learns from resolving the block: the optimizer score for
/// the posted poses, plus the layer half of that block's board rules — null
/// when the block did not resolve, which switches the zone-layer check below
/// off rather than judging a zone against a stackup nobody could read.
pub const SavedLayoutCheck = struct {
    score: @FieldType(page.SavedLayout, "score") = null,
    layers: ?optimizer.BoardRules = null,
};

/// The layer-NAME half of a block's board rules — copper count and declared
/// planes, straight off its `(stackup …)` form. That is everything
/// `BoardRules.signalIndexOfName` reads, and it costs none of the net flatten a
/// full board-rules build needs, so a save can check a zone's layer without
/// solving the board.
pub fn stackupLayerRules(arena: std.mem.Allocator, block: *const env_mod.DesignBlock) std.mem.Allocator.Error!optimizer.BoardRules {
    if (!block.stackup.present) return .{};
    const planes = try arena.alloc(optimizer.PlaneAt, block.stackup.planes.len);
    for (block.stackup.planes, planes) |pl, *out| out.* = .{ .index = pl.index, .net = pl.net };
    return .{ .copper_layers = block.stackup.layers, .planes = .{ .declared = planes } };
}

/// Whether a conductive saved zone may name `layer`. A pour must name copper:
/// a ROUTABLE signal layer (`signalIndexOfName` — everything the browser's
/// pour tool can pick), or one of the copper spellings a KiCad import copies
/// verbatim: a `(plane …)`-claimed inner, `F&B.Cu`, `*.Cu`. Those last ones
/// fill nothing here (the page's `userPourLayer` skips them) but they are real
/// imported board data that round-trips through the editor, so a Save must not
/// be refused over them. Anything else is a client bug — it would persist as a
/// pour that silently never fills.
fn zoneLayerLegal(rules: optimizer.BoardRules, layer: []const u8) bool {
    if (rules.signalIndexOfName(layer) != null) return true;
    return board_layers.isImportedCopperName(layer);
}

/// This board's routable layer names, comma-joined — the "legal set" a
/// rejected zone save is told about.
fn routableLayerNames(arena: std.mem.Allocator, rules: optimizer.BoardRules) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [16]u8 = undefined;
    var sig: u8 = 0;
    while (sig < rules.signalLayerCount()) : (sig += 1) {
        if (sig > 0) out.appendSlice(arena, ", ") catch return out.items;
        out.appendSlice(arena, rules.signalLayerName(sig, &buf)) catch return out.items;
    }
    return out.items;
}

/// Why a posted layout must be refused with a 400, or null to write it. Both
/// rules are WRITE-path only — the sidecar read stays lenient, and the KiCad
/// import writes the sidecar directly — so this judges exactly what a client
/// sends: a self-intersecting / zero-area custom outline (a bow-tie profile
/// cannot be cut as one Edge.Cuts loop), then the zone layers.
pub fn saveRejection(arena: std.mem.Allocator, rules: ?optimizer.BoardRules, entry: page.SavedLayout) ?[]const u8 {
    if (entry.outline) |o| if (o.pts) |pts| {
        if (!outline_mod.valid(pts)) return "invalid board outline — the polygon self-intersects or has zero area";
    };
    return zoneLayerError(arena, rules, entry.routes);
}

/// The message a layout SAVE is refused with when it carries a conductive zone
/// on a layer this board has not got, or null when every zone is fine.
/// Keepouts are skipped: they conduct nothing and netlisp never reads their
/// layer. Null `rules` — the block did not resolve — checks nothing rather than
/// judging against a stackup nobody could read.
fn zoneLayerError(arena: std.mem.Allocator, rules: ?optimizer.BoardRules, routes: ?page.SavedRoutes) ?[]const u8 {
    const r = routes orelse return null;
    for (r.zones) |z| if (z.sketch) |sketch| {
        _ = outline_sketch.compile(arena, sketch, outline_sketch.default_sagitta_mm) catch return "invalid copper pour sketch — repair its open, crossing, or malformed geometry";
    };
    const lr = rules orelse return null;
    for (r.zones) |z| {
        if (z.keepout or zoneLayerLegal(lr, z.layer)) continue;
        return std.fmt.allocPrint(
            arena,
            "zone layer \"{s}\" is not a copper layer on this board — routable layers: {s}",
            .{ z.layer, routableLayerNames(arena, lr) },
        ) catch null;
    }
    return null;
}

/// A minimal posted layout carrying `routes` — with the outline absent, the
/// zone layers are all `saveRejection` has left to judge.
fn tSavedWithZones(zones: []const page.SavedZone) page.SavedLayout {
    return .{ .name = "t", .kind = "manual", .ts = 0, .score = null, .parts = &.{}, .routes = .{ .tracks = &.{}, .vias = &.{}, .zones = zones } };
}

// spec: Web Server - A layout save refuses a copper pour on a layer this board has not got while keeping the spellings a KiCad import carries
test "layout save rejects an unknown zone layer and keeps imported copper spellings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // 4 copper layers, In1.Cu planed: routable = F.Cu, B.Cu, In2.Cu.
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const rules = optimizer.BoardRules{ .plane_nets = &.{"GND"}, .copper_layers = 4, .planes = .{ .declared = &planes } };
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    // Routable layers pass, and so do the copper spellings only an import
    // produces: the planed inner, KiCad's multi-layer names, any case.
    for ([_][]const u8{ "F.Cu", "B.Cu", "In2.Cu", "In1.Cu", "In3.Cu", "F&B.Cu", "*.Cu", "in2.cu" }) |ln| {
        const ok = [_]page.SavedZone{.{ .net = "GND", .layer = ln, .poly = &poly, .filled = true }};
        try std.testing.expect(saveRejection(arena, rules, tSavedWithZones(&ok)) == null);
    }
    // Junk is refused, naming the layer and the legal set.
    const bad = [_]page.SavedZone{.{ .net = "GND", .layer = "Top", .poly = &poly, .filled = true }};
    const msg = saveRejection(arena, rules, tSavedWithZones(&bad)) orelse
        return error.TestExpectedZoneLayerRejection;
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"Top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "F.Cu, B.Cu, In2.Cu") != null);
    // A keepout conducts nothing and its layer is never read, so it is skipped;
    // and with no resolved block there is no stackup to judge against.
    const ko = [_]page.SavedZone{.{ .layer = "Top", .poly = &poly, .keepout = true }};
    try std.testing.expect(saveRejection(arena, rules, tSavedWithZones(&ko)) == null);
    try std.testing.expect(saveRejection(arena, null, tSavedWithZones(&bad)) == null);
}
