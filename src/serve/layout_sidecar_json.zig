//! Pure JSON → saved-layout-type parsers for the `.layouts.json` sidecar
//! (and the request bodies that reuse its shapes). Split from
//! `layout_sidecar_types.zig`, which holds the shared data model;
//! this module is the leaf layer with no filesystem access, so the parse
//! rules live in one place whichever surface feeds them JSON.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const board_layers = @import("../board_layers.zig");
const numeric = @import("../numeric.zig");
const font5x7 = @import("../font5x7.zig");
const optimizer = @import("../placement/optimizer.zig");
const outline_mod = @import("../placement/outline.zig");
const shape_sketch = @import("../shape_sketch.zig");
const shape_sketch_json = @import("shape_sketch_json.zig");
const invalid_zone_sketch: shape_sketch.Sketch = .{ .points = &.{}, .curves = &.{} };
const page = @import("../layout_sidecar_types.zig");
const saved_zone = @import("saved_zone.zig");
const env_mod = @import("../eval/env.zig");
const SavedRfPath = @typeInfo(@FieldType(page.SavedRoutes, "rf_paths")).pointer.child;
const copper_ids = @import("copper_ids.zig");
const segment_id_prefix = "seg-";
const via_id_prefix = "via-";
const track_json_fmt = "{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"w\":{d},\"net\":";
const via_json_fmt = "{{\"x\":{d},\"y\":{d},\"d\":{d},\"drill\":{d},\"net\":";

fn segmentIdHashFloat(hash: *std.hash.Wyhash, value: f64) void {
    hash.update(std.mem.asBytes(&value));
}

fn fallbackSegmentId(track: page.SavedTrack, ordinal: usize, buf: *[segment_id_prefix.len + 16]u8) []const u8 {
    var hash = std.hash.Wyhash.init(0x5345474d454e545f);
    segmentIdHashFloat(&hash, track.x1);
    segmentIdHashFloat(&hash, track.y1);
    segmentIdHashFloat(&hash, track.x2);
    segmentIdHashFloat(&hash, track.y2);
    const has_mid: u8 = @intFromBool(track.xm != null and track.ym != null);
    hash.update(std.mem.asBytes(&has_mid));
    if (track.xm) |xm| segmentIdHashFloat(&hash, xm);
    if (track.ym) |ym| segmentIdHashFloat(&hash, ym);
    segmentIdHashFloat(&hash, track.w);
    const layer = track.l;
    const stable_ordinal: u64 = @intCast(ordinal);
    hash.update(std.mem.asBytes(&layer));
    hash.update(track.net);
    hash.update(std.mem.asBytes(&stable_ordinal));
    return std.fmt.bufPrint(buf, segment_id_prefix ++ "{x:0>16}", .{hash.final()}) catch segment_id_prefix ++ "0000000000000000";
}

/// Write a saved track's persisted or deterministic legacy segment identity.
pub fn writeTrackSegmentId(w: *std.Io.Writer, track: page.SavedTrack, ordinal: usize) std.Io.Writer.Error!void {
    var buf: [segment_id_prefix.len + 16]u8 = undefined;
    try w.writeAll(",\"id\":");
    return writeJsonStr(w, if (track.id.len > 0) track.id else fallbackSegmentId(track, ordinal, &buf));
}

/// Write a saved via's persisted or deterministic legacy identity.
pub fn writeViaId(w: *std.Io.Writer, via: page.SavedVia, ordinal: usize) std.Io.Writer.Error!void {
    var buf: [via_id_prefix.len + 16]u8 = undefined;
    try w.writeAll(",\"id\":");
    return writeJsonStr(w, if (via.id.len > 0) via.id else copper_ids.legacyVia(via, ordinal, &buf));
}

fn writeStringList(w: *std.Io.Writer, values: []const []const u8) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (values, 0..) |value, i| {
        if (i > 0) try w.writeByte(',');
        try writeJsonStr(w, value);
    }
    try w.writeByte(']');
}

/// Serialize persisted RF path swept-region evidence.
pub fn writeSavedRfPathsJson(w: *std.Io.Writer, saved_paths: []const SavedRfPath) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (saved_paths, 0..) |path, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"net\":");
        try writeJsonStr(w, path.net);
        try w.print(",\"l\":{d}", .{path.layer});
        if (path.track_ids.len > 0) {
            try w.writeAll(",\"track_ids\":");
            try writeStringList(w, path.track_ids);
        }
        if (path.portal) try w.writeAll(",\"portal\":true");
        try w.writeAll(",\"samples\":[");
        for (path.samples, 0..) |sample, si| {
            if (si > 0) try w.writeByte(',');
            try w.print("[{d},{d},{d}]", .{ sample.at[0], sample.at[1], sample.width_mm });
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

/// Serialize saved routes in the exact shared sidecar/live-JSON shape.
pub fn writeSavedRoutesJson(w: *std.Io.Writer, sr: page.SavedRoutes) std.Io.Writer.Error!void {
    try w.writeAll("{\"tracks\":[");
    for (sr.tracks, 0..) |track, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(track_json_fmt, .{ track.x1, track.y1, track.x2, track.y2, track.l, track.w });
        try writeJsonStr(w, track.net);
        if (track.xm) |xm| if (track.ym) |ym| try w.print(",\"xm\":{d},\"ym\":{d}", .{ xm, ym });
        if (track.g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, track.g);
        }
        if (track.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, track.source);
        }
        try writeTrackSegmentId(w, track, i);
        try w.writeByte('}');
    }
    try w.writeAll("],\"vias\":[");
    for (sr.vias, 0..) |via, i| {
        if (i > 0) try w.writeByte(',');
        try w.print(via_json_fmt, .{ via.x, via.y, via.d, via.drill });
        try writeJsonStr(w, via.net);
        if (via.g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, via.g);
        }
        if (via.f.len > 0) {
            try w.writeAll(",\"f\":");
            try writeJsonStr(w, via.f);
        }
        if (via.source.len > 0) {
            try w.writeAll(",\"source\":");
            try writeJsonStr(w, via.source);
        }
        if (via.s) |span| try w.print(",\"s\":[{d},{d}]", .{ span[0], span[1] });
        try writeViaId(w, via, i);
        try w.writeByte('}');
    }
    try w.writeByte(']');
    if (sr.zones.len > 0) {
        try w.writeAll(",\"zones\":");
        try writeSavedZonesJson(w, sr.zones);
    }
    if (sr.rf_paths.len > 0) {
        try w.writeAll(",\"rf_paths\":");
        try writeSavedRfPathsJson(w, sr.rf_paths);
    }
    try w.writeByte('}');
}

/// Canonical quoted JSON string writer, safe inside an HTML `script` element.
pub const writeJsonStr = json_writer.writeScriptString;

const ParsedZoneSketch = struct {
    sketch: shape_sketch.Sketch,
    poly: []const [2]f64,
};

fn parseZoneSketch(
    alloc: std.mem.Allocator,
    sketch_value: std.json.Value,
    poly_value: ?std.json.Value,
) ParsedZoneSketch {
    const sketch = shape_sketch_json.parse(alloc, sketch_value) orelse invalid_zone_sketch;
    const compiled = shape_sketch.compile(alloc, sketch, shape_sketch.default_sagitta_mm) catch |err| {
        const fallback_owned = parseOutlinePts(alloc, poly_value);
        const fallback = fallback_owned orelse &.{};
        if (err == error.OpenProfile) {
            if (shape_sketch.closeSingleGap(alloc, sketch) catch null) |closed| {
                const closed_compiled = shape_sketch.compile(alloc, closed, shape_sketch.default_sagitta_mm) catch
                    return .{ .sketch = sketch, .poly = fallback };
                if (fallback_owned) |owned| alloc.free(owned);
                return .{ .sketch = closed, .poly = closed_compiled.poly };
            }
        }
        const rebuilt = (shape_sketch.fromPolygon(alloc, fallback) catch null) orelse
            return .{ .sketch = sketch, .poly = fallback };
        const rebuilt_compiled = shape_sketch.compile(alloc, rebuilt, shape_sketch.default_sagitta_mm) catch
            return .{ .sketch = sketch, .poly = fallback };
        if (fallback_owned) |owned| alloc.free(owned);
        return .{ .sketch = rebuilt, .poly = rebuilt_compiled.poly };
    };
    return .{ .sketch = sketch, .poly = compiled.poly };
}

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

fn strictNumber(v: ?std.json.Value) ?f64 {
    return jsonOptNum(v);
}

fn strictInteger(v: ?std.json.Value, minimum: i64, maximum: i64) bool {
    const number = strictNumber(v) orelse return false;
    return number >= @as(f64, @floatFromInt(minimum)) and
        number <= @as(f64, @floatFromInt(maximum)) and @floor(number) == number;
}

fn strictString(v: ?std.json.Value, allow_empty: bool) bool {
    const value = v orelse return false;
    return value == .string and (allow_empty or value.string.len > 0);
}

fn strictOptionalString(v: ?std.json.Value) bool {
    const value = v orelse return true;
    return value == .string;
}

fn strictOptionalBool(v: ?std.json.Value) bool {
    const value = v orelse return true;
    return value == .bool;
}

fn objectHasOnlyKeys(value: std.json.Value, comptime allowed: anytype) bool {
    if (value != .object) return false;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        var recognized = false;
        inline for (allowed) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) recognized = true;
        }
        if (!recognized) return false;
    }
    return true;
}

fn strictStringArray(v: ?std.json.Value) bool {
    const value = v orelse return true;
    if (value != .array) return false;
    for (value.array.items) |item| if (item != .string) return false;
    return true;
}

fn strictNonemptyStringSet(v: ?std.json.Value) bool {
    const value = v orelse return false;
    if (value != .array or value.array.items.len == 0) return false;
    for (value.array.items, 0..) |item, index| {
        if (item != .string or item.string.len == 0) return false;
        for (value.array.items[0..index]) |earlier| {
            if (std.ascii.eqlIgnoreCase(earlier.string, item.string)) return false;
        }
    }
    return true;
}

fn strictPoint(value: std.json.Value) bool {
    if (value != .array or value.array.items.len != 2) return false;
    return strictNumber(value.array.items[0]) != null and strictNumber(value.array.items[1]) != null;
}

fn strictPolygon(v: ?std.json.Value, minimum: usize) bool {
    const value = v orelse return false;
    if (value != .array or value.array.items.len < minimum) return false;
    for (value.array.items) |point| if (!strictPoint(point)) return false;
    return true;
}

fn strictPolygonGeometry(alloc: std.mem.Allocator, v: ?std.json.Value) bool {
    const value = v orelse return false;
    if (!strictPolygon(value, 3)) return false;
    const points = alloc.alloc([2]f64, value.array.items.len) catch return false;
    for (value.array.items, points) |point, *out| {
        out.* = .{ jsonNum(point.array.items[0]), jsonNum(point.array.items[1]) };
    }
    return outline_mod.valid(points);
}

fn strictSketch(alloc: std.mem.Allocator, v: std.json.Value) bool {
    const sketch = shape_sketch_json.parse(alloc, v) orelse return false;
    if (!shape_sketch_json.matches(v, sketch)) return false;
    _ = shape_sketch.compile(alloc, sketch, shape_sketch.default_sagitta_mm) catch return false;
    return true;
}

fn strictPartPose(value: std.json.Value) bool {
    if (value != .object) return false;
    if (!objectHasOnlyKeys(value, .{ "ref", "x", "y", "rot", "origin", "locked", "side" })) return false;
    if (!strictString(value.object.get("ref"), false)) return false;
    if (strictNumber(value.object.get("x")) == null) return false;
    if (strictNumber(value.object.get("y")) == null) return false;
    if (strictNumber(value.object.get("rot")) == null) return false;
    if (!strictOptionalString(value.object.get("origin"))) return false;
    if (!strictOptionalBool(value.object.get("locked"))) return false;
    if (value.object.get("side")) |side| {
        if (side != .string) return false;
        if (!std.mem.eql(u8, side.string, "top") and !std.mem.eql(u8, side.string, "bottom")) return false;
    }
    return true;
}

fn strictTrack(value: std.json.Value) bool {
    if (value != .object) return false;
    if (!objectHasOnlyKeys(value, .{ "x1", "y1", "x2", "y2", "xm", "ym", "l", "w", "net", "g", "source", "id" })) return false;
    inline for (.{ "x1", "y1", "x2", "y2" }) |key| {
        if (strictNumber(value.object.get(key)) == null) return false;
    }
    const width = strictNumber(value.object.get("w")) orelse return false;
    if (!(width > 0)) return false;
    if (!strictString(value.object.get("net"), false)) return false;
    if (value.object.get("l") != null and !strictInteger(value.object.get("l"), 0, board_layers.max_sidecar_layer)) return false;
    const has_xm = value.object.get("xm") != null;
    const has_ym = value.object.get("ym") != null;
    if (has_xm != has_ym) return false;
    if (has_xm) {
        const xm = strictNumber(value.object.get("xm")) orelse return false;
        const ym = strictNumber(value.object.get("ym")) orelse return false;
        const arc: optimizer.BoardArc = .{
            .p1 = .{ jsonNum(value.object.get("x1")), jsonNum(value.object.get("y1")) },
            .pm = .{ xm, ym },
            .p2 = .{ jsonNum(value.object.get("x2")), jsonNum(value.object.get("y2")) },
        };
        if (outline_mod.arcCircle(arc) == null) return false;
    }
    inline for (.{ "g", "source", "id" }) |key| if (!strictOptionalString(value.object.get(key))) return false;
    return true;
}

/// The ball inside which a persisted track's own ends are the same point.
/// Numerically this is `copper_contact.join_slack_mm` — the tolerance every
/// contact predicate already treats as "one place" — and physically it is a
/// hundredth of the finest drawable feature, so nothing a fabricator could
/// make falls inside it.
const collapsed_track_mm: f64 = 1e-3;

/// True when a stored track record has collapsed into one `collapsed_track_mm`
/// ball: a corner-drag residue rather than copper. `strictTrack` above still
/// ACCEPTS such a row — a board that already carries crumbs must keep
/// autosaving — and `parseSavedRoutes` culls it instead, so the crumb never
/// reaches the connectivity model that would report it as a broken net.
///
/// An arc is judged on all three of its points. A mid-point outside the ball
/// still describes real copper (a near-full circle whose chord is short), and
/// it is kept whenever the three points define a circle at all. Coincident
/// ends define none — `arcCircle` is exactly the degenerate case there — so
/// that row is a shape no surface can draw and is culled with the rest.
fn collapsedTrack(p1: [2]f64, p2: [2]f64, pm: ?[2]f64) bool {
    if (std.math.hypot(p2[0] - p1[0], p2[1] - p1[1]) >= collapsed_track_mm) return false;
    const mid = pm orelse return true;
    if (std.math.hypot(mid[0] - p1[0], mid[1] - p1[1]) < collapsed_track_mm) return true;
    return outline_mod.arcCircle(.{ .p1 = p1, .pm = mid, .p2 = p2 }) == null;
}

/// The arc mid-point of a track record: only a complete `xm`+`ym` pair bends
/// copper, matching what the writer emits and what `strictTrack` demands.
fn arcMidpoint(xm: ?f64, ym: ?f64) ?[2]f64 {
    const x = xm orelse return null;
    const y = ym orelse return null;
    return .{ x, y };
}

/// `collapsedTrack` for one raw JSON track row, read exactly the way
/// `parseSavedRoutes` reads it so evidence and parse cull the same rows.
fn rawTrackCollapsed(value: std.json.Value) bool {
    if (value != .object) return false;
    return collapsedTrack(
        .{ jsonNum(value.object.get("x1")), jsonNum(value.object.get("y1")) },
        .{ jsonNum(value.object.get("x2")), jsonNum(value.object.get("y2")) },
        arcMidpoint(jsonOptNum(value.object.get("xm")), jsonOptNum(value.object.get("ym"))),
    );
}

fn strictVia(value: std.json.Value) bool {
    if (value != .object) return false;
    if (!objectHasOnlyKeys(value, .{ "x", "y", "d", "drill", "net", "g", "f", "s", "source", "id" })) return false;
    if (strictNumber(value.object.get("x")) == null or strictNumber(value.object.get("y")) == null) return false;
    const diameter = strictNumber(value.object.get("d")) orelse return false;
    const drill = strictNumber(value.object.get("drill")) orelse return false;
    if (!(diameter > 0)) return false;
    if (!(drill > 0)) return false;
    if (drill > diameter) return false;
    if (!strictString(value.object.get("net"), false)) return false;
    inline for (.{ "g", "f", "source", "id" }) |key| if (!strictOptionalString(value.object.get(key))) return false;
    if (value.object.get("s")) |span| {
        if (span != .array or span.array.items.len != 2) return false;
        for (span.array.items) |layer| if (!strictInteger(layer, 0, board_layers.max_sidecar_layer)) return false;
    }
    return true;
}

fn strictZone(alloc: std.mem.Allocator, value: std.json.Value) bool {
    if (value != .object) return false;
    if (!objectHasOnlyKeys(value, .{ "net", "layer", "layers", "poly", "filled", "keepout", "g", "sketch", "priority" })) return false;
    if (!strictOptionalString(value.object.get("net"))) return false;
    const layer_value = value.object.get("layer");
    if (layer_value != null and !strictString(layer_value, false)) return false;
    const has_layer = layer_value != null;
    const has_layers = value.object.get("layers") != null;
    if (!has_layer and !has_layers) return false;
    if (has_layers and !strictNonemptyStringSet(value.object.get("layers"))) return false;
    if (has_layer and has_layers) {
        const first = value.object.get("layers").?.array.items[0].string;
        if (!std.mem.eql(u8, layer_value.?.string, first)) return false;
    }
    if (!strictPolygonGeometry(alloc, value.object.get("poly"))) return false;
    if (value.object.get("sketch")) |sketch| if (!strictSketch(alloc, sketch)) return false;
    if (!strictOptionalBool(value.object.get("filled"))) return false;
    if (!strictOptionalBool(value.object.get("keepout"))) return false;
    if (!strictOptionalString(value.object.get("g"))) return false;
    if (value.object.get("priority") != null and !strictInteger(value.object.get("priority"), std.math.minInt(i32), std.math.maxInt(i32))) return false;
    return true;
}

fn strictRfPath(value: std.json.Value) bool {
    if (value != .object) return false;
    if (!objectHasOnlyKeys(value, .{ "net", "l", "track_ids", "portal", "samples" })) return false;
    if (!strictString(value.object.get("net"), false)) return false;
    if (value.object.get("l") != null and !strictInteger(value.object.get("l"), 0, board_layers.max_sidecar_layer)) return false;
    if (!strictStringArray(value.object.get("track_ids"))) return false;
    if (!strictOptionalBool(value.object.get("portal"))) return false;
    const samples = value.object.get("samples") orelse return false;
    if (samples != .array or samples.array.items.len < 2) return false;
    for (samples.array.items) |sample| {
        if (sample != .array or sample.array.items.len != 3) return false;
        if (strictNumber(sample.array.items[0]) == null or strictNumber(sample.array.items[1]) == null) return false;
        const width = strictNumber(sample.array.items[2]) orelse return false;
        if (!(width > 0)) return false;
    }
    return true;
}

fn strictRoutes(alloc: std.mem.Allocator, v: ?std.json.Value) bool {
    const value = v orelse return true;
    if (value != .object) return false;
    if (!objectHasOnlyKeys(value, .{ "tracks", "vias", "zones", "rf_paths" })) return false;
    inline for (.{ "tracks", "vias", "zones", "rf_paths" }) |key| {
        if (value.object.get(key)) |rows| {
            if (rows != .array) return false;
            for (rows.array.items) |row| {
                const valid = if (std.mem.eql(u8, key, "tracks"))
                    strictTrack(row)
                else if (std.mem.eql(u8, key, "vias"))
                    strictVia(row)
                else if (std.mem.eql(u8, key, "zones"))
                    strictZone(alloc, row)
                else
                    strictRfPath(row);
                if (!valid) return false;
            }
        }
    }
    return true;
}

fn strictOutline(alloc: std.mem.Allocator, v: ?std.json.Value) bool {
    const value = v orelse return true;
    if (value != .object) return false;
    if (!objectHasOnlyKeys(value, .{ "x", "y", "w", "h", "pts", "radii", "sketch" })) return false;
    const has_sketch = value.object.get("sketch") != null;
    if (value.object.get("sketch")) |sketch| if (!strictSketch(alloc, sketch)) return false;
    inline for (.{ "x", "y", "w", "h" }) |key| {
        if (value.object.get(key) != null and strictNumber(value.object.get(key)) == null) return false;
    }
    if (value.object.get("pts")) |points| {
        if (!strictPolygonGeometry(alloc, points)) return false;
        if (value.object.get("radii")) |radii| {
            if (radii != .array or radii.array.items.len != points.array.items.len) return false;
            const parsed_points = alloc.alloc([2]f64, points.array.items.len) catch return false;
            const parsed_radii = alloc.alloc(f64, radii.array.items.len) catch return false;
            var rounded_corners: usize = 0;
            for (points.array.items, parsed_points) |point, *parsed| {
                parsed.* = .{ jsonNum(point.array.items[0]), jsonNum(point.array.items[1]) };
            }
            for (radii.array.items, parsed_radii) |radius, *parsed| {
                const number = strictNumber(radius) orelse return false;
                if (number < 0) return false;
                parsed.* = number;
                if (number > 0) rounded_corners += 1;
            }
            const fillet = outline_mod.filletPath(alloc, parsed_points, parsed_radii, 0.01) catch return false;
            if (fillet.arcs.len != rounded_corners or !outline_mod.valid(fillet.poly)) return false;
        }
        return true;
    }
    if (value.object.get("radii") != null) return false;
    if (has_sketch) return true;
    const width = strictNumber(value.object.get("w")) orelse return false;
    const height = strictNumber(value.object.get("h")) orelse return false;
    return strictNumber(value.object.get("x")) != null and strictNumber(value.object.get("y")) != null and
        width > 0 and height > 0;
}

fn strictFabricationLayers(alloc: std.mem.Allocator, v: ?std.json.Value) bool {
    const value = v orelse return true;
    if (value != .array) return false;
    for (value.array.items) |layer| {
        if (layer != .object or !strictString(layer.object.get("name"), false)) return false;
        if (!objectHasOnlyKeys(layer, .{ "name", "regions", "sketches" })) return false;
        const regions = layer.object.get("regions") orelse return false;
        if (regions != .array or regions.array.items.len == 0) return false;
        for (regions.array.items) |region| if (!strictPolygonGeometry(alloc, region)) return false;
        if (layer.object.get("sketches")) |sketches| {
            if (sketches != .array or sketches.array.items.len != regions.array.items.len) return false;
            for (sketches.array.items) |sketch| {
                if (sketch == .null) continue;
                if (!strictSketch(alloc, sketch)) return false;
            }
        }
    }
    return true;
}

fn strictTexts(v: ?std.json.Value) bool {
    const value = v orelse return true;
    if (value != .array) return false;
    for (value.array.items) |text| {
        if (text != .object or !strictString(text.object.get("text"), false)) return false;
        if (!objectHasOnlyKeys(text, .{ "x", "y", "rot", "side", "size", "text", "subcircuit", "testpoint", "fabrication_id" })) return false;
        if (strictNumber(text.object.get("x")) == null or strictNumber(text.object.get("y")) == null) return false;
        const rotation = strictNumber(text.object.get("rot")) orelse return false;
        if (rotation != 0 and rotation != 90 and rotation != 180 and rotation != 270) return false;
        const size = strictNumber(text.object.get("size")) orelse return false;
        if (!(size > 0)) return false;
        if (text.object.get("side")) |side| {
            if (side != .string) return false;
            if (!std.mem.eql(u8, side.string, "top") and !std.mem.eql(u8, side.string, "bottom")) return false;
        }
        if (!strictOptionalString(text.object.get("subcircuit"))) return false;
        if (!strictOptionalString(text.object.get("testpoint"))) return false;
        const subcircuit = jsonStrField(text.object.get("subcircuit"));
        const testpoint = jsonStrField(text.object.get("testpoint"));
        if (subcircuit.len > 0 and testpoint.len > 0) return false;
        if (!strictOptionalBool(text.object.get("fabrication_id"))) return false;
    }
    return true;
}

fn strictFan(v: ?std.json.Value) bool {
    const value = v orelse return true;
    if (value != .object) return false;
    if (!objectHasOnlyKeys(value, .{ "model", "x", "y", "w", "h", "side", "distance_mm", "free_air_flow_m3_s", "max_static_pressure_pa", "operating_flow_fraction" })) return false;
    if (!strictString(value.object.get("model"), false)) return false;
    if (strictNumber(value.object.get("x")) == null or strictNumber(value.object.get("y")) == null) return false;
    const w = strictNumber(value.object.get("w")) orelse return false;
    const h = strictNumber(value.object.get("h")) orelse return false;
    if (!(w > 0) or !(h > 0)) return false;
    const distance = strictNumber(value.object.get("distance_mm")) orelse return false;
    const flow = strictNumber(value.object.get("free_air_flow_m3_s")) orelse return false;
    if (!(distance >= 0) or !(flow > 0)) return false;
    const pressure = strictNumber(value.object.get("max_static_pressure_pa")) orelse return false;
    const fraction = strictNumber(value.object.get("operating_flow_fraction")) orelse return false;
    if (!(pressure > 0) or !(fraction > 0)) return false;
    if (fraction > 1) return false;
    const side = value.object.get("side") orelse return false;
    if (side != .string) return false;
    return std.mem.eql(u8, side.string, "top") or std.mem.eql(u8, side.string, "bottom");
}

fn strictSelectedRow(alloc: std.mem.Allocator, value: std.json.Value) bool {
    if (value != .object) return false;
    if (!objectHasOnlyKeys(value, .{
        "name", "kind", "ts",   "rough",     "routes", "outline", "fabrication_layers", "heatsink", "fan", "texts", "dimensions",
        "hpwl", "loop", "caps", "objective", "parts",  "default",
    })) return false;
    if (!strictString(value.object.get("name"), false)) return false;
    if (value.object.get("kind")) |kind| {
        if (kind != .string) return false;
        if (!std.mem.eql(u8, kind.string, "auto") and !std.mem.eql(u8, kind.string, "manual")) return false;
    }
    const parts = value.object.get("parts") orelse return false;
    if (parts != .array or parts.array.items.len == 0) return false;
    for (parts.array.items, 0..) |part, index| {
        if (!strictPartPose(part)) return false;
        const ref = part.object.get("ref").?.string;
        for (parts.array.items[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.object.get("ref").?.string, ref)) return false;
        }
    }
    if (!strictRoutes(alloc, value.object.get("routes"))) return false;
    if (!strictOutline(alloc, value.object.get("outline"))) return false;
    if (!strictFabricationLayers(alloc, value.object.get("fabrication_layers"))) return false;
    if (!strictFan(value.object.get("fan"))) return false;
    return strictTexts(value.object.get("texts"));
}

/// Prove that the selected manufacturing row was interpreted without dropping
/// or defaulting any placement, copper, RF-path, zone, or outline record.
fn selectedLayoutEvidence(alloc: std.mem.Allocator, root: std.json.Value, selected_name: []const u8) bool {
    if (root != .object) return false;
    const layouts = root.object.get("layouts") orelse return false;
    if (layouts != .array) return false;
    var selected: ?std.json.Value = null;
    var selected_count: usize = 0;
    for (layouts.array.items) |row| {
        if (row != .object) continue;
        const row_name = row.object.get("name") orelse continue;
        if (row_name != .string or !std.mem.eql(u8, row_name.string, selected_name)) continue;
        selected_count += 1;
        selected = row;
    }
    if (selected_count != 1) return false;
    if (root.object.get("default")) |default| {
        if (default != .string) return false;
        var default_count: usize = 0;
        for (layouts.array.items) |row| {
            if (row != .object) continue;
            const row_name = row.object.get("name") orelse continue;
            if (row_name == .string and std.mem.eql(u8, row_name.string, default.string)) default_count += 1;
        }
        if (default_count != 1) return false;
    }
    return strictSelectedRow(alloc, selected.?);
}

fn selectedRow(root: std.json.Value, selected_name: []const u8) ?std.json.Value {
    if (root != .object) return null;
    const layouts = root.object.get("layouts") orelse return null;
    if (layouts != .array) return null;
    var selected: ?std.json.Value = null;
    for (layouts.array.items) |row| {
        if (row != .object) continue;
        const name = row.object.get("name") orelse continue;
        if (name != .string or !std.mem.eql(u8, name.string, selected_name)) continue;
        if (selected != null) return null;
        selected = row;
    }
    return selected;
}

fn rawArrayLength(object: std.json.Value, key: []const u8) usize {
    const value = object.object.get(key) orelse return 0;
    return if (value == .array) value.array.items.len else 0;
}

fn nearlyEqual(a: f64, b: f64) bool {
    return @abs(a - b) <= 1e-9;
}

fn rawPointsMatch(value: std.json.Value, parsed: []const [2]f64) bool {
    if (value != .array or value.array.items.len != parsed.len) return false;
    for (value.array.items, parsed) |raw, point| {
        if (raw != .array or raw.array.items.len != 2) return false;
        if (!nearlyEqual(jsonNum(raw.array.items[0]), point[0]) or
            !nearlyEqual(jsonNum(raw.array.items[1]), point[1])) return false;
    }
    return true;
}

fn rawString(value: ?std.json.Value) []const u8 {
    return jsonStrField(value);
}

fn partPoseMatches(raw: std.json.Value, parsed: page.PartPose) bool {
    if (!std.mem.eql(u8, rawString(raw.object.get("ref")), parsed.ref)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("x")), parsed.x)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("y")), parsed.y)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("rot")), parsed.rot)) return false;
    if (!std.mem.eql(u8, rawString(raw.object.get("origin")), parsed.origin)) return false;
    if (jsonFlag(raw.object.get("locked")) != parsed.locked) return false;
    return jsonSide(raw.object.get("side")) == parsed.side;
}

fn trackMatches(raw: std.json.Value, parsed: page.SavedTrack) bool {
    if (!nearlyEqual(jsonNum(raw.object.get("x1")), parsed.x1)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("y1")), parsed.y1)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("x2")), parsed.x2)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("y2")), parsed.y2)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("w")), parsed.w)) return false;
    if (jsonOptNum(raw.object.get("xm")) != parsed.xm) return false;
    if (jsonOptNum(raw.object.get("ym")) != parsed.ym) return false;
    if (layerIndexFromJson(raw.object.get("l")) != parsed.l) return false;
    inline for (.{ "net", "g", "source", "id" }) |key| {
        if (!std.mem.eql(u8, rawString(raw.object.get(key)), @field(parsed, key))) return false;
    }
    return true;
}

fn viaMatches(raw: std.json.Value, parsed: page.SavedVia) bool {
    if (!nearlyEqual(jsonNum(raw.object.get("x")), parsed.x)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("y")), parsed.y)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("d")), parsed.d)) return false;
    if (!nearlyEqual(jsonNum(raw.object.get("drill")), parsed.drill)) return false;
    const raw_span = parseViaSpan(raw.object.get("s"));
    if ((raw_span == null) != (parsed.s == null)) return false;
    if (raw_span) |span| {
        if (span[0] != parsed.s.?[0] or span[1] != parsed.s.?[1]) return false;
    }
    inline for (.{ "net", "g", "f", "source", "id" }) |key| {
        if (!std.mem.eql(u8, rawString(raw.object.get(key)), @field(parsed, key))) return false;
    }
    return true;
}

fn zoneMatches(raw: std.json.Value, parsed: page.SavedZone) bool {
    if (!std.mem.eql(u8, rawString(raw.object.get("net")), parsed.net) or
        !std.mem.eql(u8, rawString(raw.object.get("g")), parsed.g)) return false;
    if (jsonFlag(raw.object.get("filled")) != parsed.flags.filled or
        jsonFlag(raw.object.get("keepout")) != parsed.flags.keepout or
        jsonInt(raw.object.get("priority")) != parsed.priority) return false;
    if (!rawPointsMatch(raw.object.get("poly").?, parsed.poly)) return false;
    if (raw.object.get("layers")) |layers| {
        if (layers.array.items.len != parsed.layers.len) return false;
        for (layers.array.items, parsed.layers) |raw_layer, parsed_layer| {
            if (!std.mem.eql(u8, raw_layer.string, parsed_layer)) return false;
        }
    } else if (parsed.layers.len != 0) return false;
    const raw_layer = rawString(raw.object.get("layer"));
    const expected_layer = if (raw_layer.len > 0) raw_layer else if (parsed.layers.len > 0) parsed.layers[0] else "";
    if (!std.mem.eql(u8, expected_layer, parsed.layer)) return false;
    if (raw.object.get("sketch")) |raw_sketch| {
        const parsed_sketch = parsed.sketch orelse return false;
        return shape_sketch_json.matches(raw_sketch, parsed_sketch);
    }
    return parsed.sketch == null;
}

fn rfPathMatches(raw: std.json.Value, parsed: SavedRfPath) bool {
    if (!std.mem.eql(u8, rawString(raw.object.get("net")), parsed.net)) return false;
    if (layerIndexFromJson(raw.object.get("l")) != parsed.layer) return false;
    if (jsonFlag(raw.object.get("portal")) != parsed.portal) return false;
    const samples = raw.object.get("samples").?;
    if (samples.array.items.len != parsed.samples.len) return false;
    for (samples.array.items, parsed.samples) |raw_sample, sample| {
        if (!nearlyEqual(jsonNum(raw_sample.array.items[0]), sample.at[0])) return false;
        if (!nearlyEqual(jsonNum(raw_sample.array.items[1]), sample.at[1])) return false;
        if (!nearlyEqual(jsonNum(raw_sample.array.items[2]), sample.width_mm)) return false;
    }
    const track_ids = raw.object.get("track_ids");
    if (track_ids == null) return parsed.track_ids.len == 0;
    if (track_ids.?.array.items.len != parsed.track_ids.len) return false;
    for (track_ids.?.array.items, parsed.track_ids) |raw_id, parsed_id| {
        if (!std.mem.eql(u8, raw_id.string, parsed_id)) return false;
    }
    return true;
}

/// How many raw track rows survive the collapsed-crumb cull — the count the
/// typed model must carry, since a crumb is deliberately not copper.
fn keptTrackCount(raw: std.json.Value) usize {
    const tracks = raw.object.get("tracks") orelse return 0;
    if (tracks != .array) return 0;
    var kept: usize = 0;
    for (tracks.array.items) |row_track| {
        if (row_track != .object or rawTrackCollapsed(row_track)) continue;
        kept += 1;
    }
    return kept;
}

fn routesMatchParsed(row: std.json.Value, parsed: ?page.SavedRoutes) bool {
    const raw = row.object.get("routes") orelse return parsed == null;
    if (raw != .object) return false;
    const track_count = keptTrackCount(raw);
    const via_count = rawArrayLength(raw, "vias");
    const zone_count = rawArrayLength(raw, "zones");
    const rf_count = rawArrayLength(raw, "rf_paths");
    if (track_count + via_count + zone_count + rf_count == 0) return parsed == null;
    const routes = parsed orelse return false;
    if (routes.tracks.len != track_count or routes.vias.len != via_count or
        routes.zones.len != zone_count or routes.rf_paths.len != rf_count) return false;
    if (raw.object.get("tracks")) |tracks| if (tracks == .array) {
        var kept: usize = 0;
        for (tracks.array.items) |row_track| {
            if (row_track != .object or rawTrackCollapsed(row_track)) continue;
            if (kept >= routes.tracks.len or !trackMatches(row_track, routes.tracks[kept])) return false;
            kept += 1;
        }
        if (kept != routes.tracks.len) return false;
    };
    if (raw.object.get("vias")) |vias| for (vias.array.items, routes.vias) |raw_via, via| {
        if (!viaMatches(raw_via, via)) return false;
    };
    if (raw.object.get("zones")) |zones| for (zones.array.items, routes.zones) |raw_zone, zone| {
        if (!zoneMatches(raw_zone, zone)) return false;
    };
    if (raw.object.get("rf_paths")) |paths| for (paths.array.items, routes.rf_paths) |raw_path, path| {
        if (!rfPathMatches(raw_path, path)) return false;
    };
    return true;
}

fn outlineMatchesParsed(row: std.json.Value, parsed: ?page.SavedOutline) bool {
    const raw = row.object.get("outline") orelse return parsed == null;
    const outline = parsed orelse return false;
    inline for (.{ "x", "y", "w", "h" }) |key| if (raw.object.get(key)) |value| {
        if (!nearlyEqual(jsonNum(value), @field(outline, key))) return false;
    };
    if (raw.object.get("sketch")) |raw_sketch| {
        const parsed_sketch = outline.sketch orelse return false;
        if (!shape_sketch_json.matches(raw_sketch, parsed_sketch)) return false;
    } else if (outline.sketch != null) return false;
    if (raw.object.get("pts")) |points| {
        const parsed_points = outline.pts orelse return false;
        if (!rawPointsMatch(points, parsed_points)) return false;
    } else if (outline.pts != null) {
        return false;
    }
    if (raw.object.get("radii")) |radii| {
        const parsed_radii = outline.radii orelse return false;
        if (parsed_radii.len != radii.array.items.len) return false;
        var rounded: usize = 0;
        for (radii.array.items, parsed_radii) |radius, parsed_radius| {
            if (!nearlyEqual(jsonNum(radius), parsed_radius)) return false;
            if (parsed_radius > 0) rounded += 1;
        }
        if (outline.derived.arcs.len != rounded) return false;
    } else if (outline.radii != null) {
        return false;
    }
    return true;
}

fn fabricationLayersMatchParsed(row: std.json.Value, parsed: []const page.SavedFabricationLayer) bool {
    const raw = row.object.get("fabrication_layers") orelse return parsed.len == 0;
    if (raw.array.items.len != parsed.len) return false;
    for (raw.array.items, parsed) |raw_layer, layer| {
        if (!std.mem.eql(u8, rawString(raw_layer.object.get("name")), layer.name)) return false;
        const regions = raw_layer.object.get("regions").?;
        if (regions.array.items.len != layer.regions.len) return false;
        for (regions.array.items, layer.regions) |raw_region, region| {
            if (!rawPointsMatch(raw_region, region)) return false;
        }
        if (raw_layer.object.get("sketches")) |sketches| {
            if (sketches.array.items.len != layer.sketches.len) return false;
            for (sketches.array.items, layer.sketches) |raw_sketch, sketch| {
                if ((raw_sketch != .null) != (sketch != null)) return false;
                if (raw_sketch != .null and !shape_sketch_json.matches(raw_sketch, sketch.?)) return false;
            }
        } else if (layer.sketches.len != 0) return false;
    }
    return true;
}

/// Prove the strict raw row and the separately allocated typed model are a
/// one-to-one interpretation. This catches allocation failures in the editor's
/// compatibility parsers that would otherwise turn valid copper or silk into
/// a partial/empty model after raw validation succeeded.
pub fn selectedLayoutParsedEvidence(
    alloc: std.mem.Allocator,
    root: std.json.Value,
    layout: page.SavedLayout,
) bool {
    if (!selectedLayoutEvidence(alloc, root, layout.name)) return false;
    const row = selectedRow(root, layout.name) orelse return false;
    const parts = row.object.get("parts").?;
    if (parts.array.items.len != layout.parts.len) return false;
    for (parts.array.items, layout.parts) |raw_part, part| if (!partPoseMatches(raw_part, part)) return false;
    if (!routesMatchParsed(row, layout.routes)) return false;
    if (!outlineMatchesParsed(row, layout.outline)) return false;
    if (!fabricationLayersMatchParsed(row, layout.fabrication_layers)) return false;
    const raw_texts = row.object.get("texts") orelse return layout.texts.len == 0;
    if (raw_texts.array.items.len != layout.texts.len) return false;
    for (raw_texts.array.items, layout.texts) |raw_text, text| {
        if (!nearlyEqual(jsonNum(raw_text.object.get("x")), text.x)) return false;
        if (!nearlyEqual(jsonNum(raw_text.object.get("y")), text.y)) return false;
        if (!nearlyEqual(jsonNum(raw_text.object.get("rot")), text.rot)) return false;
        if (!nearlyEqual(jsonNum(raw_text.object.get("size")), text.size)) return false;
        if (!std.mem.eql(u8, rawString(raw_text.object.get("text")), text.text)) return false;
        if ((std.mem.eql(u8, rawString(raw_text.object.get("side")), "bottom")) != text.bottom) return false;
        if (jsonFlag(raw_text.object.get("fabrication_id")) != text.fabrication_id) return false;
        const subcircuit = rawString(raw_text.object.get("subcircuit"));
        const testpoint = rawString(raw_text.object.get("testpoint"));
        if (subcircuit.len == 0 and testpoint.len == 0) {
            if (text.owner != null) return false;
        } else if (text.owner) |owner| switch (owner) {
            .subcircuit => |value| if (!std.mem.eql(u8, subcircuit, value)) return false,
            .testpoint => |value| if (!std.mem.eql(u8, testpoint, value)) return false,
        } else return false;
    }
    return true;
}

// spec: fabrication-release - selected layout evidence rejects every malformed or silently defaulted manufacturing record before release
test "strict selected layout evidence rejects dropped manufacturing geometry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const valid =
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"kind\":\"manual\"," ++
        "\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{" ++
        "\"tracks\":[{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"w\":0.2,\"net\":\"N\"}]," ++
        "\"vias\":[{\"x\":1,\"y\":1,\"d\":0.5,\"drill\":0.25,\"net\":\"N\"}]," ++
        "\"zones\":[{\"net\":\"GND\",\"layer\":\"F.Cu\",\"poly\":[[0,0],[2,0],[2,2]]}]," ++
        "\"rf_paths\":[{\"net\":\"RF\",\"samples\":[[0,0,0.2],[1,0,0.2]]}]}," ++
        "\"outline\":{\"x\":0,\"y\":0,\"w\":10,\"h\":5}}]}";
    const valid_root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, valid, .{});
    try std.testing.expect(selectedLayoutEvidence(alloc, valid_root, "release"));

    const invalid = [_][]const u8{
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"tracks\":[{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"net\":\"N\"}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"tracks\":[{\"x1\":0,\"y1\":0,\"x2\":2,\"y2\":2,\"xm\":1,\"ym\":1,\"w\":0.2,\"net\":\"N\"}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"vias\":[{\"x\":1,\"y\":1,\"d\":0.5,\"drill\":\"bad\",\"net\":\"N\"}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"zones\":[{\"net\":\"GND\",\"layer\":\"F.Cu\",\"poly\":[[0,0],[1],[1,1]]}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"zones\":[{\"net\":\"GND\",\"layer\":\"F.Cu\",\"poly\":[[0,0],[1,0],[2,0]]}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"zones\":[{\"net\":\"GND\",\"layers\":[],\"poly\":[[0,0],[2,0],[2,2]]}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"zones\":[{\"net\":\"GND\",\"layers\":[\"\"],\"poly\":[[0,0],[2,0],[2,2]]}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"track\":[{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"w\":0.2,\"net\":\"N\"}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"tracks\":[{\"x1\":0,\"y1\":0,\"x2\":1,\"y2\":1,\"w\":0.2,\"net\":\"N\",\"widht\":0.3}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"zones\":[{\"net\":\"GND\",\"layer\":42,\"layers\":[\"F.Cu\"],\"poly\":[[0,0],[2,0],[2,2]]}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"zones\":[{\"net\":\"GND\",\"layer\":\"B.Cu\",\"layers\":[\"F.Cu\"],\"poly\":[[0,0],[2,0],[2,2]]}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"rf_paths\":[{\"net\":\"RF\",\"samples\":[[0,0],[1,0,0.2]]}]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"outline\":{\"pts\":[[0,0],[1],[1,1]]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"outline\":{\"pts\":[[0,0],[1,0],[2,0]]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"outline\":{\"pts\":[[0,0],[2,0],[2,2],[1,2],[0,2]],\"radii\":[0,0,0,1,0]}}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"fabrication_layers\":[{\"name\":\"adhesive.gbr\",\"regions\":[[[0,0],[1],[1,1]]]}]}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"texts\":[{\"text\":\"REV A\",\"x\":1,\"y\":2,\"rot\":0,\"size\":\"bad\"}]}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"texts\":[{\"text\":\"REV A\",\"x\":1,\"y\":2,\"rot\":45,\"size\":1}]}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"texts\":[{\"text\":\"REV A\",\"x\":1,\"y\":2,\"rot\":0,\"size\":1,\"subcircuit\":\"a\",\"testpoint\":\"b\"}]}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0},{\"ref\":\"U1\",\"x\":3,\"y\":4,\"rot\":0}]}]}",
        "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}]},{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}]}]}",
        "{\"default\":\"missing\",\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}]}]}",
    };
    for (invalid) |source| {
        const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{});
        try std.testing.expect(!selectedLayoutEvidence(alloc, root, "release"));
    }
}

fn parsedEvidenceTestLayout(alloc: std.mem.Allocator, row: std.json.Value) page.SavedLayout {
    return .{
        .name = jsonStrField(row.object.get("name")),
        .kind = jsonStrField(row.object.get("kind")),
        .ts = jsonInt(row.object.get("ts")),
        .score = null,
        .parts = parsePartPoses(alloc, row.object.get("parts")) orelse &.{},
        .routes = parseSavedRoutes(alloc, row.object.get("routes")),
        .outline = parseSavedOutline(alloc, row.object.get("outline")),
        .fabrication_layers = parseSavedFabricationLayers(alloc, row.object.get("fabrication_layers")),
        .texts = parseSavedTexts(alloc, row.object.get("texts")),
    };
}

fn redundantGeometryConflictsAreRejected(alloc: std.mem.Allocator, sources: []const []const u8) !bool {
    for (sources) |source| {
        const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{});
        const row = root.object.get("layouts").?.array.items[0];
        if (!selectedLayoutEvidence(alloc, root, "release")) return false;
        if (selectedLayoutParsedEvidence(alloc, root, parsedEvidenceTestLayout(alloc, row))) return false;
    }
    return true;
}

// spec: fabrication-release - redundant saved polygons and dimensions must match the exact sketch-derived manufacturing geometry or release evidence is incomplete
test "selected layout rejects conflicting redundant sketch geometry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const square_sketch =
        "{\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":4,\"y\":0},{\"id\":3,\"x\":4,\"y\":4},{\"id\":4,\"x\":0,\"y\":4}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}";
    const sources = [_][]const u8{
        "{\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":1,\"rot\":0}],\"routes\":{\"zones\":[{\"net\":\"GND\",\"layer\":\"F.Cu\",\"poly\":[[10,10],[14,10],[14,14],[10,14]],\"sketch\":" ++ square_sketch ++ "}]}}]}",
        "{\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":1,\"rot\":0}],\"outline\":{\"x\":10,\"y\":10,\"w\":4,\"h\":4,\"pts\":[[10,10],[14,10],[14,14],[10,14]],\"sketch\":" ++ square_sketch ++ "}}]}",
        "{\"layouts\":[{\"name\":\"release\",\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":1,\"rot\":0}],\"fabrication_layers\":[{\"name\":\"adhesive.gbr\",\"regions\":[[[10,10],[14,10],[14,14],[10,14]]],\"sketches\":[" ++ square_sketch ++ "]}]}]}",
    };
    try std.testing.expect(try redundantGeometryConflictsAreRejected(arena_state.allocator(), &sources));
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

/// Parse persistent footprint-origin → outline-edge driving dimensions. Bad
/// rows are skipped so removing/replacing an outline curve cannot make an old
/// layout unreadable; the editor surfaces an unmatched edge as a dangling
/// dimension and lets the user remove it.
pub fn parsePartEdgeDimensions(alloc: std.mem.Allocator, v: ?std.json.Value) []const page.SavedPartEdgeDimension {
    const arr = v orelse return &.{};
    if (arr != .array) return &.{};
    var list: std.ArrayList(page.SavedPartEdgeDimension) = .empty;
    for (arr.array.items) |it| {
        if (it != .object) continue;
        const ref = it.object.get("ref") orelse continue;
        const axis = it.object.get("axis") orelse continue;
        const edge_raw = jsonInt(it.object.get("edge_id"));
        const offset = jsonOptNum(it.object.get("offset")) orelse continue;
        if (ref != .string or ref.string.len == 0) continue;
        if (axis != .string) continue;
        if (!std.mem.eql(u8, axis.string, "x") and !std.mem.eql(u8, axis.string, "y")) continue;
        if (edge_raw <= 0 or edge_raw > std.math.maxInt(u32)) continue;
        list.append(alloc, .{
            .ref = ref.string,
            .axis = axis.string,
            .edge_id = @intCast(edge_raw),
            .offset = offset,
        }) catch return list.items;
    }
    return list.toOwnedSlice(alloc) catch list.items;
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
            // A corner drag can leave a neighbour segment collapsed onto its
            // own end. That crumb is copper no contact predicate can join, so
            // on its layer it is an island the connectivity model reports as a
            // broken net. Cull it here — silently, in BOTH directions, because
            // this parser is the one seam the editor's save and the sidecar
            // load share: rejecting the row would 400 every autosave of a
            // board that already carries one, and keeping it would keep the
            // phantom island. The next save writes the healed copper back.
            if (rawTrackCollapsed(it)) continue;
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
            const zone = parseSavedZone(alloc, it) orelse continue;
            zones.append(alloc, zone) catch return null;
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
                .track_ids = jsonStringList(alloc, it.object.get("track_ids")),
                .portal = jsonFlag(it.object.get("portal")),
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

/// The saved-routes rows a collapse test needs: one ordinary segment, three
/// shapes that have collapsed into a sub-micron ball, and two that only look
/// like they have. Every row here is one `strictTrack` accepts, so each is a
/// row a save must keep accepting. Shared by the parse, round-trip and
/// evidence tests below.
const crumb_track_rows =
    "{\"x1\":0,\"y1\":0,\"x2\":4,\"y2\":0,\"w\":0.2,\"net\":\"N\",\"id\":\"seg-line\"}," ++
    // Exactly the barracuda crumb: a segment dragged onto its own end.
    "{\"x1\":182.21,\"y1\":93.1,\"x2\":182.21,\"y2\":93.1,\"l\":1,\"w\":0.127,\"net\":\"N\",\"id\":\"seg-zero\"}," ++
    // Sub-micron but not exactly zero — still nothing a fabricator can make.
    "{\"x1\":1,\"y1\":1,\"x2\":1.0004,\"y2\":1.0003,\"w\":0.2,\"net\":\"N\",\"id\":\"seg-sub\"}," ++
    // An arc whose three points have all collapsed into the same ball. They
    // still describe a circle, so only the ball rule culls this one.
    "{\"x1\":2,\"y1\":2,\"x2\":2.0001,\"y2\":2,\"xm\":2.00005,\"ym\":2.00001,\"w\":0.2,\"net\":\"N\",\"id\":\"seg-arc-ball\"}," ++
    // A near-full circle: the chord is sub-micron but the bulge is 1 mm of
    // real copper, and the three points still describe a circle.
    "{\"x1\":10,\"y1\":10,\"x2\":10.0005,\"y2\":10,\"xm\":10.00025,\"ym\":11,\"w\":0.2,\"net\":\"N\",\"id\":\"seg-bulge\"}," ++
    // Exactly one micron long: the shortest copper that is still copper.
    "{\"x1\":20,\"y1\":20,\"x2\":20.001,\"y2\":20,\"w\":0.2,\"net\":\"N\",\"id\":\"seg-micron\"}";

/// Coincident ends with a distant mid-point: three points that define no
/// circle at all, so the record describes a shape no surface can draw.
const no_circle_track_row =
    "{\"x1\":5,\"y1\":5,\"x2\":5,\"y2\":5,\"xm\":6,\"ym\":6,\"w\":0.2,\"net\":\"N\",\"id\":\"seg-no-circle\"}";

fn crumbTestRoutes(alloc: std.mem.Allocator, rows: []const u8) !?page.SavedRoutes {
    const source = try std.fmt.allocPrint(alloc, "{{\"tracks\":[{s}]}}", .{rows});
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{});
    return parseSavedRoutes(alloc, value);
}

/// The persisted identity of every track a parse kept, in order.
fn crumbTestKeptIds(alloc: std.mem.Allocator, tracks: []const page.SavedTrack) ![]const []const u8 {
    var ids: std.ArrayList([]const u8) = .empty;
    for (tracks) |track| try ids.append(alloc, track.id);
    return ids.items;
}

/// How many leading rows of a raw track array the strict validator accepts.
fn crumbTestStrictPrefix(rows: []const std.json.Value) usize {
    var accepted: usize = 0;
    for (rows) |row| {
        if (!strictTrack(row)) break;
        accepted += 1;
    }
    return accepted;
}

/// True when the serialized copper still names any of these track ids.
fn crumbTestMentionsAny(written: []const u8, ids: []const []const u8) bool {
    for (ids) |id| {
        if (std.mem.indexOf(u8, written, id) != null) return true;
    }
    return false;
}

// spec: Web Server - The saved-routes parser silently culls a track that has collapsed into a sub-micron ball, on the save and the sidecar load alike, judging an arc on all three of its points and keeping one whose points still describe a circle
test "collapsed sub-micron track crumbs are culled from parsed copper, arcs judged on all three points" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const routes = (try crumbTestRoutes(alloc, crumb_track_rows ++ "," ++ no_circle_track_row)).?;
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "seg-line", "seg-bulge", "seg-micron" }),
        try crumbTestKeptIds(alloc, routes.tracks),
    );

    // Every crumb the parser culls is a row the strict validator ACCEPTS —
    // rejecting instead of culling would 400 every autosave of a board that
    // already carries one. Only the trailing record, the one that describes no
    // circle, is refused there, and for its geometry rather than its length.
    const raw = try std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        try std.fmt.allocPrint(alloc, "[{s},{s}]", .{ crumb_track_rows, no_circle_track_row }),
        .{},
    );
    try std.testing.expectEqual(raw.array.items.len - 1, crumbTestStrictPrefix(raw.array.items));

    // The save path persists what it parsed, so the crumbs leave the board on
    // the next write instead of being copied forward.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try writeSavedRoutesJson(&aw.writer, routes);
    try std.testing.expect(!crumbTestMentionsAny(
        aw.written(),
        &.{ "seg-zero", "seg-sub", "seg-arc-ball", "seg-no-circle" },
    ));
    try std.testing.expect(crumbTestMentionsAny(aw.written(), &.{"seg-bulge"}));

    // Copper that is nothing but crumbs parses as no copper at all rather than
    // an empty routes record.
    try std.testing.expect((try crumbTestRoutes(
        alloc,
        "{\"x1\":3,\"y1\":3,\"x2\":3,\"y2\":3,\"w\":0.2,\"net\":\"N\",\"id\":\"seg-only\"}",
    )) == null);
}

// spec: fabrication-release - a collapsed sub-micron track crumb the parser culls is not dropped manufacturing copper, while any other missing track still fails release evidence
test "release evidence accepts culled crumbs but still counts real dropped copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const source = "{\"default\":\"release\",\"layouts\":[{\"name\":\"release\",\"kind\":\"manual\"," ++
        "\"parts\":[{\"ref\":\"U1\",\"x\":1,\"y\":2,\"rot\":0}],\"routes\":{\"tracks\":[" ++ crumb_track_rows ++ "]}}]}";
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{});
    const row = root.object.get("layouts").?.array.items[0];
    try std.testing.expect(selectedLayoutEvidence(alloc, root, "release"));
    try std.testing.expect(selectedLayoutParsedEvidence(alloc, root, parsedEvidenceTestLayout(alloc, row)));

    // The cull is the only copper the model may be missing: dropping a track
    // that is real is still incomplete evidence.
    var thinned = parsedEvidenceTestLayout(alloc, row);
    thinned.routes = .{
        .tracks = thinned.routes.?.tracks[0 .. thinned.routes.?.tracks.len - 1],
        .vias = &.{},
    };
    try std.testing.expect(!selectedLayoutParsedEvidence(alloc, root, thinned));
}

fn parseSavedZone(alloc: std.mem.Allocator, value: std.json.Value) ?page.SavedZone {
    if (value != .object) return null;
    var sketch: ?shape_sketch.Sketch = null;
    const poly = if (value.object.get("sketch")) |sketch_value| blk: {
        const parsed = parseZoneSketch(alloc, sketch_value, value.object.get("poly"));
        sketch = parsed.sketch;
        break :blk parsed.poly;
    } else parseOutlinePts(alloc, value.object.get("poly")) orelse return null;
    const layers = jsonStringList(alloc, value.object.get("layers"));
    const legacy_layer = jsonStrField(value.object.get("layer"));
    return .{
        .net = jsonStrField(value.object.get("net")),
        .layer = if (legacy_layer.len > 0) legacy_layer else if (layers.len > 0) layers[0] else "",
        .layers = layers,
        .poly = poly,
        .flags = .{
            .filled = jsonFlag(value.object.get("filled")),
            .keepout = jsonFlag(value.object.get("keepout")),
        },
        .g = jsonStrField(value.object.get("g")),
        .priority = jsonInt(value.object.get("priority")),
        .sketch = sketch,
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
        try writeJsonStr(w, zone.net);
        try w.writeAll(",\"layer\":");
        try writeJsonStr(w, saved_zone.primaryLayer(&zone));
        if (zone.layers.len > 1) {
            try w.writeAll(",\"layers\":[");
            for (zone.layers, 0..) |layer_name, li| {
                if (li > 0) try w.writeByte(',');
                try writeJsonStr(w, layer_name);
            }
            try w.writeByte(']');
        }
        try w.writeAll(",\"poly\":[");
        for (zone.poly, 0..) |point, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.print("[{d},{d}]", .{ point[0], point[1] });
        }
        try w.print("],\"filled\":{s},\"keepout\":{s}", .{
            if (zone.flags.filled) "true" else "false",
            if (zone.flags.keepout) "true" else "false",
        });
        if (zone.g.len > 0) {
            try w.writeAll(",\"g\":");
            try writeJsonStr(w, zone.g);
        }
        if (zone.sketch) |sketch| {
            try w.writeAll(",\"sketch\":");
            try shape_sketch_json.write(w, sketch);
        }
        if (zone.priority != 0) try w.print(",\"priority\":{d}", .{zone.priority});
        try w.writeByte('}');
    }
    try w.writeAll("]");
}

/// Write physical backing polygons plus any index-aligned native sketches.
pub fn writeSavedFabricationLayersJson(w: *std.Io.Writer, layers: []const page.SavedFabricationLayer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (layers, 0..) |layer, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try writeJsonStr(w, layer.name);
        try w.writeAll(",\"regions\":[");
        for (layer.regions, 0..) |region, ri| {
            if (ri > 0) try w.writeByte(',');
            try w.writeByte('[');
            for (region, 0..) |point, pi| {
                if (pi > 0) try w.writeByte(',');
                try w.print("[{d},{d}]", .{ point[0], point[1] });
            }
            try w.writeByte(']');
        }
        try w.writeByte(']');
        var has_sketch = false;
        for (layer.sketches) |sketch| if (sketch != null) {
            has_sketch = true;
            break;
        };
        if (has_sketch) {
            try w.writeAll(",\"sketches\":[");
            for (layer.regions, 0..) |_, ri| {
                if (ri > 0) try w.writeByte(',');
                if (ri < layer.sketches.len) {
                    if (layer.sketches[ri]) |sketch| try shape_sketch_json.write(w, sketch) else try w.writeAll("null");
                } else try w.writeAll("null");
            }
            try w.writeByte(']');
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

/// Serialize the exact editable outline shape retained by a saved layout.
pub fn writeSavedOutlineJson(w: *std.Io.Writer, outline: page.SavedOutline) std.Io.Writer.Error!void {
    try w.print("{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}", .{ outline.x, outline.y, outline.w, outline.h });
    if (outline.pts) |points| {
        try w.writeAll(",\"pts\":[");
        for (points, 0..) |point, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("[{d},{d}]", .{ point[0], point[1] });
        }
        try w.writeByte(']');
    }
    if (outline.radii) |radii| {
        try w.writeAll(",\"radii\":[");
        for (radii, 0..) |radius, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("{d}", .{radius});
        }
        try w.writeByte(']');
    }
    if (outline.sketch) |sketch| {
        try w.writeAll(",\"sketch\":");
        try shape_sketch_json.write(w, sketch);
    }
    try w.writeByte('}');
}

/// Serialize footprint-origin driving dimensions in the saved-layout shape.
pub fn writePartEdgeDimensionsJson(w: *std.Io.Writer, dimensions: []const page.SavedPartEdgeDimension) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (dimensions, 0..) |dimension, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"ref\":");
        try writeJsonStr(w, dimension.ref);
        try w.writeAll(",\"axis\":");
        try writeJsonStr(w, dimension.axis);
        try w.print(",\"edge_id\":{d},\"offset\":{d}}}", .{ dimension.edge_id, dimension.offset });
    }
    try w.writeByte(']');
}

/// Serialize one saved physical heatsink assembly.
pub fn writeSavedHeatsinkJson(w: *std.Io.Writer, sink: page.SavedHeatsink) std.Io.Writer.Error!void {
    try w.print("{{\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"side\":", .{ sink.x, sink.y, sink.w, sink.h });
    try writeJsonStr(w, sink.side);
    try w.writeAll(",\"target_ref\":");
    try writeJsonStr(w, sink.target_ref);
    try w.writeAll(",\"material\":");
    try writeJsonStr(w, sink.material);
    try w.print(",\"base_mm\":{d}", .{sink.base_mm});
    switch (sink.profile) {
        .finned => |fins| {
            try w.print(",\"shape\":\"finned\",\"fin_height_mm\":{d},\"fin_thickness_mm\":{d},\"fin_gap_mm\":{d},\"fin_axis\":", .{ fins.height_mm, fins.thickness_mm, fins.gap_mm });
            try writeJsonStr(w, fins.axis);
        },
        .stepped => |lower| try w.print(",\"shape\":\"stepped\",\"lower_width_mm\":{d},\"lower_length_mm\":{d},\"lower_height_mm\":{d}", .{ lower.width_mm, lower.length_mm, lower.height_mm }),
    }
    try w.print(",\"pad_thickness_mm\":{d},\"pad_k_w_mk\":{d}}}", .{ sink.pad_thickness_mm, sink.pad_k_w_mk });
}

/// Serialize one saved axial fan assembly.
pub fn writeSavedFanJson(w: *std.Io.Writer, fan: page.SavedFan) std.Io.Writer.Error!void {
    try w.writeAll("{\"model\":");
    try writeJsonStr(w, fan.model);
    try w.print(",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d},\"side\":", .{ fan.rect.x, fan.rect.y, fan.rect.w, fan.rect.h });
    try writeJsonStr(w, fan.side);
    try w.print(",\"distance_mm\":{d},\"free_air_flow_m3_s\":{d},\"max_static_pressure_pa\":{d},\"operating_flow_fraction\":{d}}}", .{
        fan.distance_mm,
        fan.curve.free_air_flow_m3_s,
        fan.curve.max_static_pressure_pa,
        fan.operating_flow_fraction,
    });
}

/// Serialize one board-level fabrication text label.
pub fn writeBoardTextJson(w: *std.Io.Writer, text: font5x7.BoardText) std.Io.Writer.Error!void {
    try w.print("{{\"x\":{d},\"y\":{d},\"rot\":{d},\"side\":\"{s}\",\"size\":{d},\"text\":", .{ text.x, text.y, text.rot, if (text.bottom) "bottom" else "top", text.size });
    try writeJsonStr(w, text.text);
    if (text.owner) |owner| switch (owner) {
        .subcircuit => |subcircuit| {
            try w.writeAll(",\"subcircuit\":");
            try writeJsonStr(w, subcircuit);
        },
        .testpoint => |testpoint| {
            try w.writeAll(",\"testpoint\":");
            try writeJsonStr(w, testpoint);
        },
    };
    if (text.fabrication_id) try w.writeAll(",\"fabrication_id\":true");
    try w.writeByte('}');
}

/// Serialize an optional board text as its object or JSON null.
pub fn writeOptionalBoardTextJson(w: *std.Io.Writer, text: ?font5x7.BoardText) std.Io.Writer.Error!void {
    if (text) |value| try writeBoardTextJson(w, value) else try w.writeAll("null");
}

/// Serialize the board-text array retained by a saved layout.
pub fn writeSavedTextsJson(w: *std.Io.Writer, texts: []const font5x7.BoardText) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (texts, 0..) |text, i| {
        if (i > 0) try w.writeByte(',');
        try writeBoardTextJson(w, text);
    }
    try w.writeByte(']');
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
    if (shape_sketch_json.parse(alloc, obj.object.get("sketch"))) |sketch| {
        const compiled = shape_sketch.compile(alloc, sketch, shape_sketch.default_sagitta_mm) catch return null;
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
    try std.testing.expectEqual(shape_sketch.CurveKind.arc, round_trip.zones[0].sketch.?.curves[0].kind);

    const one_gap =
        "{\"tracks\":[],\"vias\":[],\"zones\":[{\"net\":\"V_3V3A\",\"layer\":\"F.Cu\",\"filled\":true," ++
        "\"poly\":[[0,0],[10,0],[10,10],[0,10]],\"sketch\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":10,\"y\":0},{\"id\":3,\"x\":10,\"y\":10},{\"id\":4,\"x\":0,\"y\":10}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4}],\"constraints\":[]}}]}";
    const one_gap_value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, one_gap, .{});
    const repaired_routes = parseSavedRoutes(alloc, one_gap_value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), repaired_routes.zones[0].sketch.?.curves.len);
    try std.testing.expect(saveRejection(alloc, null, tSavedWithZones(repaired_routes.zones)) == null);
    var repaired_encoded: std.Io.Writer.Allocating = .init(alloc);
    try writeSavedZonesJson(&repaired_encoded.writer, repaired_routes.zones);
    try std.testing.expect(std.mem.indexOf(u8, repaired_encoded.written(), "\"id\":14") != null);

    const open = "{\"tracks\":[],\"vias\":[],\"zones\":[{\"net\":\"GND\",\"layer\":\"F.Cu\",\"poly\":[[0,0],[1,0],[0,1]],\"sketch\":{\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":1,\"y\":0}],\"curves\":[{\"id\":3,\"kind\":\"line\",\"a\":1,\"b\":2}],\"constraints\":[]}}]}";
    const open_value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, open, .{});
    const normalized_routes = parseSavedRoutes(alloc, open_value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), normalized_routes.zones[0].sketch.?.curves.len);
    try std.testing.expect(saveRejection(alloc, null, tSavedWithZones(normalized_routes.zones)) == null);
}

// spec: Web Server - When a copper-area sketch cannot compile as a closed contour but its persisted visible polygon is valid, Update rebuilds a clean closed line sketch from that exact polygon and saves the remaining layout edits; crossing or zero-area visible polygons are still rejected
test "saved copper zones rebuild complex OpenProfile topology from their visible polygon" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const branched =
        "{\"tracks\":[],\"vias\":[],\"zones\":[{\"net\":\"V_3V3A\",\"layer\":\"F.Cu\",\"poly\":[[0,0],[6,0],[6,4],[0,4]],\"sketch\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":6,\"y\":0},{\"id\":3,\"x\":6,\"y\":4},{\"id\":4,\"x\":0,\"y\":4}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1},{\"id\":15,\"kind\":\"line\",\"a\":1,\"b\":3}],\"constraints\":[]}}]}";
    const branched_value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, branched, .{});
    const repaired = parseSavedRoutes(alloc, branched_value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 4), repaired.zones[0].sketch.?.curves.len);
    try std.testing.expectEqual(@as(u32, shape_sketch.max_entities + 1), repaired.zones[0].sketch.?.curves[0].id);
    try std.testing.expect(saveRejection(alloc, null, tSavedWithZones(repaired.zones)) == null);

    const invalid =
        "{\"tracks\":[],\"vias\":[],\"zones\":[{\"net\":\"GND\",\"layer\":\"F.Cu\",\"poly\":[[0,0],[4,4],[0,4],[4,0]],\"sketch\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":1,\"y\":0}],\"curves\":[{\"id\":3,\"kind\":\"line\",\"a\":1,\"b\":2}],\"constraints\":[]}}]}";
    const invalid_value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, invalid, .{});
    const invalid_routes = parseSavedRoutes(alloc, invalid_value) orelse return error.TestUnexpectedResult;
    try std.testing.expectError(error.OpenProfile, shape_sketch.compile(alloc, invalid_routes.zones[0].sketch.?, shape_sketch.default_sagitta_mm));
    const rejection = saveRejection(alloc, null, tSavedWithZones(invalid_routes.zones)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, rejection, "invalid custom copper-area sketch") != null);
    try std.testing.expect(std.mem.indexOf(u8, rejection, "zone #1 (GND on F.Cu): OpenProfile") != null);
}

test "saved copper zones discard other broken hidden authoring state" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const source =
        "{\"tracks\":[],\"vias\":[],\"zones\":[" ++
        "{\"net\":\"A\",\"layer\":\"F.Cu\",\"poly\":[[0,0],[4,0],[4,3],[0,3]],\"sketch\":{\"version\":2,\"points\":[],\"curves\":[],\"constraints\":[]}}," ++
        "{\"net\":\"B\",\"layer\":\"F.Cu\",\"poly\":[[5,0],[9,0],[9,3],[5,3]],\"sketch\":{\"version\":1,\"points\":[{\"id\":1,\"x\":5,\"y\":0},{\"id\":2,\"x\":9,\"y\":0},{\"id\":3,\"x\":9,\"y\":3},{\"id\":4,\"x\":5,\"y\":3}],\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":11,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}}," ++
        "{\"net\":\"C\",\"layer\":\"F.Cu\",\"poly\":[[10,0],[14,0],[14,3],[10,3]],\"sketch\":{\"version\":1,\"points\":[{\"id\":1,\"x\":10,\"y\":0},{\"id\":2,\"x\":14,\"y\":3},{\"id\":3,\"x\":10,\"y\":3},{\"id\":4,\"x\":14,\"y\":0}],\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}}]}";
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{});
    const repaired = parseSavedRoutes(alloc, value) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), repaired.zones.len);
    for (repaired.zones) |zone| {
        try std.testing.expectEqual(@as(usize, 4), zone.sketch.?.curves.len);
        try std.testing.expectEqual(@as(u32, shape_sketch.max_entities + 1), zone.sketch.?.curves[0].id);
    }
    try std.testing.expect(saveRejection(alloc, null, tSavedWithZones(repaired.zones)) == null);
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
        const sketches_value = item.object.get("sketches");
        var regions: std.ArrayList([]const [2]f64) = .empty;
        var sketches: std.ArrayList(?shape_sketch.Sketch) = .empty;
        for (rv.array.items, 0..) |region_value, region_index| {
            var sketch: ?shape_sketch.Sketch = null;
            var points = parseOutlinePts(alloc, region_value) orelse continue;
            if (parseFabricationSketch(alloc, sketches_value, region_index)) |parsed| {
                alloc.free(points);
                points = parsed.compiled;
                sketch = parsed.sketch;
            }
            if (!outline_mod.valid(points)) {
                alloc.free(points);
                continue;
            }
            regions.append(alloc, points) catch return layers.items;
            if (sketches_value != null) sketches.append(alloc, sketch) catch return layers.items;
        }
        if (regions.items.len == 0) continue;
        layers.append(alloc, .{
            .name = nv.string,
            .regions = regions.toOwnedSlice(alloc) catch return layers.items,
            .sketches = if (sketches_value != null) sketches.toOwnedSlice(alloc) catch return layers.items else &.{},
        }) catch return layers.items;
    }
    return layers.toOwnedSlice(alloc) catch layers.items;
}

const ParsedFabricationSketch = struct { sketch: shape_sketch.Sketch, compiled: []const [2]f64 };
fn parseFabricationSketch(alloc: std.mem.Allocator, value: ?std.json.Value, index: usize) ?ParsedFabricationSketch {
    const array = value orelse return null;
    if (array != .array or index >= array.array.items.len) return null;
    const sketch = shape_sketch_json.parse(alloc, array.array.items[index]) orelse return null;
    const compiled = shape_sketch.compile(alloc, sketch, shape_sketch.default_sagitta_mm) catch return null;
    alloc.free(compiled.pts);
    alloc.free(compiled.arcs);
    return .{ .sketch = sketch, .compiled = compiled.poly };
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
    const lower_width = jsonOptNum(obj.get("lower_width_mm")) orelse 0;
    const lower_length = jsonOptNum(obj.get("lower_length_mm")) orelse 0;
    const lower_height = jsonOptNum(obj.get("lower_height_mm")) orelse 0;
    const pad_thickness = jsonOptNum(obj.get("pad_thickness_mm")) orelse 0.5;
    const pad_k = jsonOptNum(obj.get("pad_k_w_mk")) orelse 6;
    if (!(w > 0) or !(h > 0)) return null;
    if (!(base > 0) or !(fin_height >= 0)) return null;
    if (!(pad_thickness >= 0) or !(pad_k > 0)) return null;

    const side = stringChoice(obj.get("side"), &.{ "top", "bottom" }, "bottom");
    const material = stringChoice(obj.get("material"), &.{ "aluminum_6063", "aluminum_6061", "copper_c110", "steel" }, "aluminum_6063");
    const shape = stringChoice(obj.get("shape"), &.{ "finned", "stepped" }, "finned");
    const fin_axis = stringChoice(obj.get("fin_axis"), &.{ "length", "width" }, "length");
    const is_finned = std.mem.eql(u8, shape, "finned");
    if (is_finned) {
        if (!(fin_thickness > 0) or !(fin_gap >= 0)) return null;
    }
    const lower_block_ok = lower_width > 0 and lower_length > 0 and lower_height > 0;
    if (!is_finned and !lower_block_ok) return null;
    const target_ref = if (obj.get("target_ref")) |target| blk: {
        if (target != .string) return null;
        break :blk target.string;
    } else "";
    return .{
        .x = x,
        .y = y,
        .w = w,
        .h = h,
        .side = side,
        .target_ref = target_ref,
        .material = material,
        .base_mm = base,
        .profile = if (is_finned) .{ .finned = .{
            .height_mm = fin_height,
            .thickness_mm = fin_thickness,
            .gap_mm = fin_gap,
            .axis = fin_axis,
        } } else .{ .stepped = .{
            .width_mm = lower_width,
            .length_mm = lower_length,
            .height_mm = lower_height,
        } },
        .pad_thickness_mm = pad_thickness,
        .pad_k_w_mk = pad_k,
    };
}

/// Parse one saved axial fan. All physical and catalog fields are required so
/// an editor override can never silently change the thermal operating point.
pub fn parseSavedFan(v: ?std.json.Value) ?page.SavedFan {
    const value = v orelse return null;
    if (value != .object) return null;
    const obj = value.object;
    const model = obj.get("model") orelse return null;
    if (model != .string or model.string.len == 0) return null;
    const x = jsonOptNum(obj.get("x")) orelse return null;
    const y = jsonOptNum(obj.get("y")) orelse return null;
    const w = jsonOptNum(obj.get("w")) orelse return null;
    const h = jsonOptNum(obj.get("h")) orelse return null;
    const distance = jsonOptNum(obj.get("distance_mm")) orelse return null;
    const flow = jsonOptNum(obj.get("free_air_flow_m3_s")) orelse return null;
    const pressure = jsonOptNum(obj.get("max_static_pressure_pa")) orelse return null;
    const fraction = jsonOptNum(obj.get("operating_flow_fraction")) orelse return null;
    if (!(w > 0) or !(h > 0)) return null;
    if (!(distance >= 0) or !(flow > 0)) return null;
    if (!(pressure > 0) or !(fraction > 0)) return null;
    if (fraction > 1) return null;
    return .{
        .model = model.string,
        .rect = .{ .x = x, .y = y, .w = w, .h = h },
        .side = stringChoice(obj.get("side"), &.{ "top", "bottom" }, "top"),
        .distance_mm = distance,
        .curve = .{ .free_air_flow_m3_s = flow, .max_static_pressure_pa = pressure },
        .operating_flow_fraction = fraction,
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

test "saved fabrication regions round trip native shape sketches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const source =
        "[{\"name\":\"stiffener\",\"regions\":[[[9,9],[10,9],[9,10]]],\"sketches\":[{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":4,\"y\":0},{\"id\":3,\"x\":4,\"y\":3},{\"id\":4,\"x\":0,\"y\":3}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}]}]";
    const value = try std.json.parseFromSliceLeaky(std.json.Value, alloc, source, .{});
    const layers = parseSavedFabricationLayers(alloc, value);
    try std.testing.expectEqual(@as(usize, 1), layers.len);
    try std.testing.expect(layers[0].sketches[0] != null);
    try std.testing.expectEqual(@as(f64, 4), layers[0].regions[0][1][0]);
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    try writeSavedFabricationLayersJson(&encoded.writer, layers);
    try std.testing.expect(std.mem.indexOf(u8, encoded.written(), "\"sketches\"") != null);
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

fn jsonStringList(alloc: std.mem.Allocator, v: ?std.json.Value) []const []const u8 {
    const value = v orelse return &.{};
    if (value != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (value.array.items) |item| {
        if (item != .string or item.string.len == 0) continue;
        var duplicate = false;
        for (out.items) |existing| if (std.ascii.eqlIgnoreCase(existing, item.string)) {
            duplicate = true;
            break;
        };
        if (!duplicate) out.append(alloc, item.string) catch return out.items;
    }
    return out.toOwnedSlice(alloc) catch out.items;
}

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
    for (entry.fabrication_layers) |layer| for (layer.sketches) |maybe_sketch| if (maybe_sketch) |sketch| {
        _ = shape_sketch.compile(arena, sketch, shape_sketch.default_sagitta_mm) catch return "invalid fabrication-region sketch — repair its open, crossing, or malformed geometry";
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
    for (r.zones, 0..) |z, zone_index| if (z.sketch) |sketch| {
        _ = shape_sketch.compile(arena, sketch, shape_sketch.default_sagitta_mm) catch |err| return std.fmt.allocPrint(
            arena,
            "invalid custom copper-area sketch in zone #{d} ({s} on {s}): {s} — repair its open, crossing, or malformed geometry",
            .{ zone_index + 1, if (z.flags.keepout) "keepout" else z.net, saved_zone.primaryLayer(&z), @errorName(err) },
        ) catch "invalid custom copper-area sketch — repair its open, crossing, or malformed geometry";
    };
    const lr = rules orelse return null;
    for (r.zones) |z| {
        if (z.flags.keepout) continue;
        var legacy: [1][]const u8 = undefined;
        for (saved_zone.layers(&z, &legacy)) |layer_name| {
            if (zoneLayerLegal(lr, layer_name)) continue;
            return std.fmt.allocPrint(
                arena,
                "zone layer \"{s}\" is not a copper layer on this board — routable layers: {s}",
                .{ layer_name, routableLayerNames(arena, lr) },
            ) catch null;
        }
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
        const ok = [_]page.SavedZone{.{ .net = "GND", .layer = ln, .poly = &poly, .flags = .{ .filled = true } }};
        try std.testing.expect(saveRejection(arena, rules, tSavedWithZones(&ok)) == null);
    }
    // Junk is refused, naming the layer and the legal set.
    const bad = [_]page.SavedZone{.{ .net = "GND", .layer = "Top", .poly = &poly, .flags = .{ .filled = true } }};
    const msg = saveRejection(arena, rules, tSavedWithZones(&bad)) orelse
        return error.TestExpectedZoneLayerRejection;
    try std.testing.expect(std.mem.indexOf(u8, msg, "\"Top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "F.Cu, B.Cu, In2.Cu") != null);
    // A keepout conducts nothing and its layer is never read, so it is skipped;
    // and with no resolved block there is no stackup to judge against.
    const ko = [_]page.SavedZone{.{ .layer = "Top", .poly = &poly, .flags = .{ .keepout = true } }};
    try std.testing.expect(saveRejection(arena, rules, tSavedWithZones(&ko)) == null);
    try std.testing.expect(saveRejection(arena, null, tSavedWithZones(&bad)) == null);
}
