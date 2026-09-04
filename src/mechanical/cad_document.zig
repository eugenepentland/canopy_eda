//! Persisted system mechanical-CAD document.
//!
//! PCBs are reference geometry. Mechanical solids exist only when the author
//! creates a sketch and explicitly extrudes it; opening a system never infers
//! or generates an enclosure from the occupied board envelope.

const std = @import("std");
const shape_sketch = @import("../shape_sketch.zig");
const json_writer = @import("../json_writer.zig");

const schema_name = "netlisp-mechanical-v2";
const legacy_enclosure_schema = "netlisp-mechanical-v1";
/// Maximum accepted mechanical document size.
pub const mechanical_document_byte_limit: usize = 256 * 1024;

/// Saved assembly pose for one imported PCB reference.
const BoardPose = struct {
    name: []const u8,
    enabled: bool = true,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 5,
    rotation: f64 = 0,
};

/// One XY work-plane sketch. Geometry remains authored even while open; only
/// a closed sketch may be referenced by an extrusion.
const ProfileSketch = struct {
    id: []const u8,
    name: []const u8,
    plane_z: f64 = 0,
    geometry: shape_sketch.Sketch,
};

/// Explicit additive solid operation. Boolean add/cut is intentionally not
/// implied: every extrusion is exported as its own named body for now.
const Extrusion = struct {
    id: []const u8,
    name: []const u8,
    sketch: []const u8,
    distance: f64,
    enabled: bool = true,
};

/// Versioned, source-controlled mechanical state for one system.
pub const Document = struct {
    schema: []const u8 = schema_name,
    boards: []const BoardPose = &.{},
    sketches: []const ProfileSketch = &.{},
    extrusions: []const Extrusion = &.{},
};

pub const DocumentError = error{ InvalidDocument, LegacyEnclosureDocument };
/// Parsing preserves allocation failure but normalizes malformed input.
pub const ParseError = std.mem.Allocator.Error || DocumentError;

fn finiteBetween(value: f64, minimum: f64, maximum: f64) bool {
    return std.math.isFinite(value) and value >= minimum and value <= maximum;
}

fn safeId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-') continue;
        if (c != '_' and c != '.') return false;
    }
    return true;
}

fn validBoardPose(board: BoardPose) bool {
    if (!safeId(board.name)) return false;
    const xy_valid = finiteBetween(board.x, -10_000, 10_000) and finiteBetween(board.y, -10_000, 10_000);
    const zr_valid = finiteBetween(board.z, -10_000, 10_000) and finiteBetween(board.rotation, -36_000, 36_000);
    return xy_valid and zr_valid;
}

fn sketchIndex(document: Document, id: []const u8) ?usize {
    for (document.sketches, 0..) |sketch, index| if (std.mem.eql(u8, sketch.id, id)) return index;
    return null;
}

fn sketchPoint(sketch: shape_sketch.Sketch, id: u32) ?shape_sketch.Point {
    for (sketch.points) |point| if (point.id == id) return point;
    return null;
}

fn structurallyValidSketch(sketch: shape_sketch.Sketch) bool {
    for (sketch.points) |point| {
        if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y)) return false;
    }
    for (sketch.curves) |curve| {
        const a = sketchPoint(sketch, curve.a) orelse return false;
        const b = sketchPoint(sketch, curve.b) orelse return false;
        if (curve.a == curve.b or std.math.hypot(a.x - b.x, a.y - b.y) <= 1e-9) return false;
        switch (curve.kind) {
            .line => if (curve.mid != null) return false,
            .arc => {
                const mid = curve.mid orelse return false;
                if (!std.math.isFinite(mid[0]) or !std.math.isFinite(mid[1])) return false;
            },
        }
    }
    return true;
}

fn validateSketch(allocator: std.mem.Allocator, sketch: ProfileSketch) ParseError!void {
    if (!safeId(sketch.id) or sketch.name.len == 0 or sketch.name.len > 128) return error.InvalidDocument;
    if (!finiteBetween(sketch.plane_z, -10_000, 10_000)) return error.InvalidDocument;
    if (!structurallyValidSketch(sketch.geometry)) return error.InvalidDocument;
    const compiled = shape_sketch.compile(allocator, sketch.geometry, shape_sketch.default_sagitta_mm) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Open profiles are valid saved authoring drafts; an extrusion may not
        // reference one until it is closed.
        error.OpenProfile => return,
        else => return error.InvalidDocument,
    };
    allocator.free(compiled.pts);
    allocator.free(compiled.poly);
    allocator.free(compiled.arcs);
}

/// Check all document bounds and sketch/extrusion references without writing.
pub fn validate(allocator: std.mem.Allocator, document: Document) ParseError!void {
    if (std.mem.eql(u8, document.schema, legacy_enclosure_schema)) return error.LegacyEnclosureDocument;
    if (!std.mem.eql(u8, document.schema, schema_name)) return error.InvalidDocument;
    if (document.boards.len > 256 or document.sketches.len > 128 or document.extrusions.len > 256) return error.InvalidDocument;
    for (document.boards, 0..) |board, index| {
        if (!validBoardPose(board)) return error.InvalidDocument;
        for (document.boards[0..index]) |prior| if (std.mem.eql(u8, prior.name, board.name)) return error.InvalidDocument;
    }
    for (document.sketches, 0..) |sketch, index| {
        try validateSketch(allocator, sketch);
        for (document.sketches[0..index]) |prior| if (std.mem.eql(u8, prior.id, sketch.id)) return error.InvalidDocument;
    }
    for (document.extrusions, 0..) |extrusion, index| {
        if (!safeId(extrusion.id) or extrusion.name.len == 0 or extrusion.name.len > 128) return error.InvalidDocument;
        if (!finiteBetween(extrusion.distance, 0.01, 10_000)) return error.InvalidDocument;
        const sketch_i = sketchIndex(document, extrusion.sketch) orelse return error.InvalidDocument;
        const compiled = shape_sketch.compile(allocator, document.sketches[sketch_i].geometry, shape_sketch.default_sagitta_mm) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidDocument,
        };
        allocator.free(compiled.pts);
        allocator.free(compiled.poly);
        allocator.free(compiled.arcs);
        for (document.extrusions[0..index]) |prior| if (std.mem.eql(u8, prior.id, extrusion.id)) return error.InvalidDocument;
    }
}

/// Parse and fully validate an authored mechanical JSON document.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!std.json.Parsed(Document) {
    if (source.len == 0 or source.len > mechanical_document_byte_limit) return error.InvalidDocument;
    var parsed = std.json.parseFromSlice(Document, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            var tree = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch return error.InvalidDocument;
            defer tree.deinit();
            if (tree.value == .object) if (tree.value.object.get("schema")) |schema| {
                if (schema == .string and std.mem.eql(u8, schema.string, legacy_enclosure_schema)) return error.LegacyEnclosureDocument;
            };
            return error.InvalidDocument;
        },
    };
    errdefer parsed.deinit();
    try validate(allocator, parsed.value);
    return parsed;
}

fn writeSketch(writer: *std.Io.Writer, sketch: shape_sketch.Sketch) json_writer.WriteError!void {
    try writer.print("{{\"version\":{d},\"points\":[", .{sketch.version});
    for (sketch.points, 0..) |point, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"x\":{d},\"y\":{d}", .{ point.id, point.x, point.y });
        if (point.construction) try writer.writeAll(",\"construction\":true");
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"curves\":[");
    for (sketch.curves, 0..) |curve, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"kind\":\"{s}\",\"a\":{d},\"b\":{d}", .{ curve.id, @tagName(curve.kind), curve.a, curve.b });
        if (curve.mid) |mid| try writer.print(",\"mid\":[{d},{d}]", .{ mid[0], mid[1] });
        if (curve.construction) try writer.writeAll(",\"construction\":true");
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"constraints\":[");
    for (sketch.constraints, 0..) |constraint, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"id\":{d},\"kind\":\"{s}\",\"a\":{d}", .{ constraint.id, @tagName(constraint.kind), constraint.a });
        if (constraint.b) |b| try writer.print(",\"b\":{d}", .{b});
        if (constraint.c) |c| try writer.print(",\"c\":{d}", .{c});
        if (constraint.value) |value| try writer.print(",\"value\":{d}", .{value});
        try writer.print(",\"mode\":\"{s}\"}}", .{@tagName(constraint.mode)});
    }
    try writer.writeAll("]}");
}

/// Canonical, stable JSON used for source control and request bodies.
pub fn write(writer: *std.Io.Writer, document: Document) json_writer.WriteError!void {
    try writer.writeAll("{\"schema\":\"");
    try writer.writeAll(schema_name);
    try writer.writeAll("\",\"boards\":[");
    for (document.boards, 0..) |board, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try json_writer.writeString(writer, board.name);
        try writer.print(",\"enabled\":{s},\"x\":{d},\"y\":{d},\"z\":{d},\"rotation\":{d}}}", .{
            if (board.enabled) "true" else "false", board.x, board.y, board.z, board.rotation,
        });
    }
    try writer.writeAll("],\"sketches\":[");
    for (document.sketches, 0..) |sketch, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try json_writer.writeString(writer, sketch.id);
        try writer.writeAll(",\"name\":");
        try json_writer.writeString(writer, sketch.name);
        try writer.print(",\"plane_z\":{d},\"geometry\":", .{sketch.plane_z});
        try writeSketch(writer, sketch.geometry);
        try writer.writeByte('}');
    }
    try writer.writeAll("],\"extrusions\":[");
    for (document.extrusions, 0..) |extrusion, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try json_writer.writeString(writer, extrusion.id);
        try writer.writeAll(",\"name\":");
        try json_writer.writeString(writer, extrusion.name);
        try writer.writeAll(",\"sketch\":");
        try json_writer.writeString(writer, extrusion.sketch);
        try writer.print(",\"distance\":{d},\"enabled\":{s}}}", .{ extrusion.distance, if (extrusion.enabled) "true" else "false" });
    }
    try writer.writeAll("]}\n");
}

test "blank mechanical document is valid and canonical" {
    const source = "{\"schema\":\"netlisp-mechanical-v2\",\"boards\":[{\"name\":\"barracuda\",\"z\":5}],\"sketches\":[],\"extrusions\":[]}";
    var parsed = try parse(std.testing.allocator, source);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.extrusions.len);
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, parsed.value);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"sketches\":[]") != null);
}

test "closed sketch extrusion round trips and open extrusion is rejected" {
    const source =
        "{\"schema\":\"netlisp-mechanical-v2\",\"sketches\":[{\"id\":\"sketch-1\",\"name\":\"Floor\",\"geometry\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":-20,\"y\":-15},{\"id\":2,\"x\":20,\"y\":-15},{\"id\":3,\"x\":20,\"y\":15},{\"id\":4,\"x\":-20,\"y\":15}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[{\"id\":21,\"kind\":\"horizontal\",\"a\":11,\"mode\":\"driving\"}]}}]," ++
        "\"extrusions\":[{\"id\":\"extrude-1\",\"name\":\"Floor\",\"sketch\":\"sketch-1\",\"distance\":2}]}";
    var parsed = try parse(std.testing.allocator, source);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 2), parsed.value.extrusions[0].distance);
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try write(&encoded.writer, parsed.value);
    var round_trip = try parse(std.testing.allocator, encoded.written());
    defer round_trip.deinit();
    try std.testing.expectEqualStrings("sketch-1", round_trip.value.extrusions[0].sketch);

    const open =
        "{\"schema\":\"netlisp-mechanical-v2\",\"sketches\":[{\"id\":\"open\",\"name\":\"Open\",\"geometry\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":10,\"y\":0}],\"curves\":[{\"id\":3,\"kind\":\"line\",\"a\":1,\"b\":2}],\"constraints\":[]}}]," ++
        "\"extrusions\":[{\"id\":\"bad\",\"name\":\"Bad\",\"sketch\":\"open\",\"distance\":2}]}";
    try std.testing.expectError(error.InvalidDocument, parse(std.testing.allocator, open));

    const malformed_draft =
        "{\"schema\":\"netlisp-mechanical-v2\",\"sketches\":[{\"id\":\"bad-draft\",\"name\":\"Bad draft\",\"geometry\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0}],\"curves\":[{\"id\":3,\"kind\":\"line\",\"a\":1,\"b\":2}],\"constraints\":[]}}]}";
    try std.testing.expectError(error.InvalidDocument, parse(std.testing.allocator, malformed_draft));
}

test "legacy generated enclosure document is identified rather than loaded" {
    const source = "{\"schema\":\"netlisp-mechanical-v1\",\"occupied\":{\"width\":90,\"depth\":55}}";
    try std.testing.expectError(error.LegacyEnclosureDocument, parse(std.testing.allocator, source));
}
