//! JSON codec for versioned board-outline and copper-pour shape sketches.
//!
//! This stays independent of the layout-page types so the sidecar parser and
//! writer can share one strict schema without adding more code to the already
//! large page module.

const std = @import("std");
const numeric = @import("../numeric.zig");
const sketch_mod = @import("../shape_sketch.zig");

fn number(v: ?std.json.Value) ?f64 {
    const value = v orelse return null;
    const n: f64 = switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return null,
    };
    return if (std.math.isFinite(n)) n else null;
}

fn id(v: ?std.json.Value) ?u32 {
    const n = number(v) orelse return null;
    if (n < 1 or n > std.math.maxInt(u32)) return null;
    if (@floor(n) != n) return null;
    return numeric.checkedInt(u32, n);
}

fn flag(v: ?std.json.Value, fallback: bool) bool {
    const value = v orelse return fallback;
    return if (value == .bool) value.bool else fallback;
}

fn pointPair(v: ?std.json.Value) ?[2]f64 {
    const value = v orelse return null;
    if (value != .array or value.array.items.len != 2) return null;
    return .{
        number(value.array.items[0]) orelse return null,
        number(value.array.items[1]) orelse return null,
    };
}

fn hasOnlyKeys(value: std.json.Value, comptime allowed: anytype) bool {
    if (value != .object) return false;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        var known = false;
        inline for (allowed) |key| if (std.mem.eql(u8, entry.key_ptr.*, key)) {
            known = true;
        };
        if (!known) return false;
    }
    return true;
}

fn pointMatches(value: std.json.Value, point: sketch_mod.Point) bool {
    if (!hasOnlyKeys(value, .{ "id", "x", "y", "construction" })) return false;
    if (value.object.get("construction")) |construction| if (construction != .bool) return false;
    return id(value.object.get("id")) == point.id and
        number(value.object.get("x")) == point.x and
        number(value.object.get("y")) == point.y and
        flag(value.object.get("construction"), false) == point.construction;
}

fn curveMatches(value: std.json.Value, curve: sketch_mod.Curve) bool {
    if (!hasOnlyKeys(value, .{ "id", "kind", "a", "b", "mid", "construction" })) return false;
    const kind_value = value.object.get("kind") orelse return false;
    if (kind_value != .string or std.meta.stringToEnum(sketch_mod.CurveKind, kind_value.string) != curve.kind) return false;
    if (value.object.get("construction")) |construction| if (construction != .bool) return false;
    if (id(value.object.get("id")) != curve.id or id(value.object.get("a")) != curve.a or
        id(value.object.get("b")) != curve.b or flag(value.object.get("construction"), false) != curve.construction) return false;
    if (curve.mid) |mid| {
        const raw_mid = pointPair(value.object.get("mid")) orelse return false;
        return raw_mid[0] == mid[0] and raw_mid[1] == mid[1];
    }
    return value.object.get("mid") == null;
}

fn constraintMatches(value: std.json.Value, constraint: sketch_mod.Constraint) bool {
    if (!hasOnlyKeys(value, .{ "id", "kind", "a", "b", "c", "value", "enabled", "driving" })) return false;
    const kind_value = value.object.get("kind") orelse return false;
    if (kind_value != .string or std.meta.stringToEnum(sketch_mod.ConstraintKind, kind_value.string) != constraint.kind) return false;
    inline for (.{ "enabled", "driving" }) |key| if (value.object.get(key)) |state| if (state != .bool) return false;
    if (id(value.object.get("id")) != constraint.id or id(value.object.get("a")) != constraint.a) return false;
    const raw_b = if (value.object.get("b")) |b| id(b) orelse return false else null;
    const raw_c = if (value.object.get("c")) |c| id(c) orelse return false else null;
    const raw_value = if (value.object.get("value")) |n| number(n) orelse return false else null;
    const raw_mode: sketch_mod.ConstraintMode = if (!flag(value.object.get("enabled"), true))
        .disabled
    else if (!flag(value.object.get("driving"), true))
        .reference
    else
        .driving;
    return raw_b == constraint.b and raw_c == constraint.c and raw_value == constraint.value and raw_mode == constraint.mode;
}

/// Return true only when `sketch` is an exact, lossless interpretation of the
/// raw v1 object. Release evidence uses this after the compatibility parser so
/// allocation failure cannot be mistaken for a valid fallback polygon.
pub fn matches(value: std.json.Value, sketch: sketch_mod.Sketch) bool {
    if (!hasOnlyKeys(value, .{ "version", "points", "curves", "constraints" })) return false;
    if (id(value.object.get("version")) != sketch.version) return false;
    const points = value.object.get("points") orelse return false;
    const curves = value.object.get("curves") orelse return false;
    if (points != .array or curves != .array) return false;
    if (points.array.items.len != sketch.points.len or curves.array.items.len != sketch.curves.len) return false;
    for (points.array.items, sketch.points) |raw, parsed| if (!pointMatches(raw, parsed)) return false;
    for (curves.array.items, sketch.curves) |raw, parsed| if (!curveMatches(raw, parsed)) return false;
    const constraints = value.object.get("constraints");
    if (constraints == null) return sketch.constraints.len == 0;
    if (constraints.? != .array or constraints.?.array.items.len != sketch.constraints.len) return false;
    for (constraints.?.array.items, sketch.constraints) |raw, parsed| if (!constraintMatches(raw, parsed)) return false;
    return true;
}

/// Parse a strict v1 sketch. Structural/profile validity is deliberately left
/// to `shape_sketch.compile`, which returns a specific geometry error.
pub fn parse(alloc: std.mem.Allocator, v: ?std.json.Value) ?sketch_mod.Sketch {
    const value = v orelse return null;
    if (value != .object) return null;
    const version_n = id(value.object.get("version")) orelse return null;
    if (version_n != sketch_mod.current_version) return null;
    const point_values = value.object.get("points") orelse return null;
    const curve_values = value.object.get("curves") orelse return null;
    if (point_values != .array or curve_values != .array) return null;
    if (point_values.array.items.len > sketch_mod.max_entities) return null;
    if (curve_values.array.items.len > sketch_mod.max_entities) return null;

    var points: std.ArrayList(sketch_mod.Point) = .empty;
    for (point_values.array.items) |item| {
        if (item != .object) return null;
        points.append(alloc, .{
            .id = id(item.object.get("id")) orelse return null,
            .x = number(item.object.get("x")) orelse return null,
            .y = number(item.object.get("y")) orelse return null,
            .construction = flag(item.object.get("construction"), false),
        }) catch return null;
    }

    var curves: std.ArrayList(sketch_mod.Curve) = .empty;
    for (curve_values.array.items) |item| {
        if (item != .object) return null;
        const kind_value = item.object.get("kind") orelse return null;
        if (kind_value != .string) return null;
        const kind = std.meta.stringToEnum(sketch_mod.CurveKind, kind_value.string) orelse return null;
        curves.append(alloc, .{
            .id = id(item.object.get("id")) orelse return null,
            .kind = kind,
            .a = id(item.object.get("a")) orelse return null,
            .b = id(item.object.get("b")) orelse return null,
            .mid = if (kind == .arc) pointPair(item.object.get("mid")) orelse return null else null,
            .construction = flag(item.object.get("construction"), false),
        }) catch return null;
    }

    var constraints: std.ArrayList(sketch_mod.Constraint) = .empty;
    if (value.object.get("constraints")) |constraint_values| {
        if (constraint_values != .array or constraint_values.array.items.len > sketch_mod.max_constraints) return null;
        for (constraint_values.array.items) |item| {
            if (item != .object) return null;
            const kind_value = item.object.get("kind") orelse return null;
            if (kind_value != .string) return null;
            const kind = std.meta.stringToEnum(sketch_mod.ConstraintKind, kind_value.string) orelse return null;
            constraints.append(alloc, .{
                .id = id(item.object.get("id")) orelse return null,
                .kind = kind,
                .a = id(item.object.get("a")) orelse return null,
                .b = if (item.object.get("b")) |b| id(b) orelse return null else null,
                .c = if (item.object.get("c")) |c| id(c) orelse return null else null,
                .value = if (item.object.get("value")) |n| number(n) orelse return null else null,
                .mode = if (!flag(item.object.get("enabled"), true))
                    .disabled
                else if (!flag(item.object.get("driving"), true))
                    .reference
                else
                    .driving,
            }) catch return null;
        }
    }
    return .{
        .version = sketch_mod.current_version,
        .points = points.toOwnedSlice(alloc) catch return null,
        .curves = curves.toOwnedSlice(alloc) catch return null,
        .constraints = constraints.toOwnedSlice(alloc) catch return null,
    };
}

/// Write the compact sidecar representation of one parametric shape sketch.
pub fn write(w: *std.Io.Writer, sketch: sketch_mod.Sketch) std.Io.Writer.Error!void {
    try w.print("{{\"version\":{d},\"points\":[", .{sketch.version});
    for (sketch.points, 0..) |point, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":{d},\"x\":{d},\"y\":{d}", .{ point.id, point.x, point.y });
        if (point.construction) try w.writeAll(",\"construction\":true");
        try w.writeAll("}");
    }
    try w.writeAll("],\"curves\":[");
    for (sketch.curves, 0..) |curve, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":{d},\"kind\":\"{s}\",\"a\":{d},\"b\":{d}", .{
            curve.id, @tagName(curve.kind), curve.a, curve.b,
        });
        if (curve.mid) |mid| try w.print(",\"mid\":[{d},{d}]", .{ mid[0], mid[1] });
        if (curve.construction) try w.writeAll(",\"construction\":true");
        try w.writeAll("}");
    }
    try w.writeAll("],\"constraints\":[");
    for (sketch.constraints, 0..) |constraint, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":{d},\"kind\":\"{s}\",\"a\":{d}", .{
            constraint.id, @tagName(constraint.kind), constraint.a,
        });
        if (constraint.b) |b| try w.print(",\"b\":{d}", .{b});
        if (constraint.c) |c| try w.print(",\"c\":{d}", .{c});
        if (constraint.value) |dimension| try w.print(",\"value\":{d}", .{dimension});
        if (constraint.mode == .reference) try w.writeAll(",\"driving\":false");
        if (constraint.mode == .disabled) try w.writeAll(",\"enabled\":false");
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

test "outline sketch JSON round trips stable entities and dimensions" {
    const alloc = std.testing.allocator;
    const source =
        "{\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":10,\"y\":0}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"arc\",\"a\":1,\"b\":2,\"mid\":[5,-2]}]," ++
        "\"constraints\":[{\"id\":21,\"kind\":\"radius\",\"a\":11,\"value\":7.25}]}";
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, source, .{});
    defer parsed.deinit();
    const sketch = parse(alloc, parsed.value) orelse return error.TestUnexpectedResult;
    defer alloc.free(sketch.points);
    defer alloc.free(sketch.curves);
    defer alloc.free(sketch.constraints);
    try std.testing.expectEqual(sketch_mod.CurveKind.arc, sketch.curves[0].kind);
    try std.testing.expectEqual(@as(f64, 7.25), sketch.constraints[0].value.?);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try write(&out.writer, sketch);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"kind\":\"arc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"value\":7.25") != null);
}

test "persisted outline sketch recompiles exact arcs after a JSON round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const source =
        "{\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":10,\"y\":0}," ++
        "{\"id\":3,\"x\":10,\"y\":10},{\"id\":4,\"x\":0,\"y\":10}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"arc\",\"a\":1,\"b\":2,\"mid\":[5,-2]}," ++
        "{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4}," ++
        "{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[]}";
    var tree = try std.json.parseFromSlice(std.json.Value, alloc, source, .{});
    defer tree.deinit();
    const first = parse(alloc, tree.value) orelse return error.TestUnexpectedResult;
    const compiled = try sketch_mod.compile(alloc, first, sketch_mod.default_sagitta_mm);
    try std.testing.expectEqual(@as(usize, 1), compiled.arcs.len);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try write(&encoded.writer, first);
    var second_tree = try std.json.parseFromSlice(std.json.Value, alloc, encoded.written(), .{});
    defer second_tree.deinit();
    const second = parse(alloc, second_tree.value) orelse return error.TestUnexpectedResult;
    const recompiled = try sketch_mod.compile(alloc, second, sketch_mod.default_sagitta_mm);
    try std.testing.expectEqualDeep(compiled.arcs[0], recompiled.arcs[0]);
}

test "collinear line constraints round trip through the sketch sidecar" {
    const alloc = std.testing.allocator;
    const source =
        "{\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":10,\"y\":0}," ++
        "{\"id\":3,\"x\":10,\"y\":10},{\"id\":4,\"x\":0,\"y\":10}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3}," ++
        "{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}]," ++
        "\"constraints\":[{\"id\":21,\"kind\":\"collinear\",\"a\":11,\"b\":13}]}";
    var tree = try std.json.parseFromSlice(std.json.Value, alloc, source, .{});
    defer tree.deinit();
    const sketch = parse(alloc, tree.value) orelse return error.TestUnexpectedResult;
    defer alloc.free(sketch.points);
    defer alloc.free(sketch.curves);
    defer alloc.free(sketch.constraints);
    try std.testing.expectEqual(sketch_mod.ConstraintKind.collinear, sketch.constraints[0].kind);

    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();
    try write(&encoded.writer, sketch);
    try std.testing.expect(std.mem.indexOf(u8, encoded.written(), "\"kind\":\"collinear\"") != null);
}
