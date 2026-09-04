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
const min_fan_flow_m3_s: f64 = 1e-6;
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

const FanDirection = enum { down, up };

/// One independently positioned axial fan. `z` is the fan-frame centre;
/// `direction` names the direction of discharge toward PCB faces.
const Fan = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool = true,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 25,
    rotation: f64 = 0,
    width: f64 = 80,
    depth: f64 = 80,
    direction: FanDirection = .down,
    free_air_flow_m3_s: f64 = 0.025,
    max_static_pressure_pa: f64 = 0,
    operating_flow_fraction: f64 = 0.6,
};

/// Principal origin planes use local sketch X/Y coordinates and a right-handed
/// outward normal. XZ therefore extrudes toward -Y, matching X cross Z.
const SketchPlane = enum { xy, xz, yz };

/// One principal-plane sketch. Geometry remains authored even while open;
/// only a closed sketch may be referenced by an extrusion.
const ProfileSketch = struct {
    id: []const u8,
    name: []const u8,
    plane: SketchPlane = .xy,
    /// Coordinate on the axis normal to the selected plane. The legacy field
    /// name remains source-compatible with documents written by the first v2
    /// workspace.
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
    /// Null distinguishes legacy v2 documents from an authored empty list:
    /// the browser imports board-attached fans only for the former.
    fans: ?[]const Fan = null,
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

fn validFan(fan: Fan) bool {
    if (!safeId(fan.id) or fan.name.len == 0 or fan.name.len > 128) return false;
    if (!finiteBetween(fan.x, -10_000, 10_000) or !finiteBetween(fan.y, -10_000, 10_000)) return false;
    if (!finiteBetween(fan.z, -10_000, 10_000) or !finiteBetween(fan.rotation, -36_000, 36_000)) return false;
    if (!finiteBetween(fan.width, 1, 1_000) or !finiteBetween(fan.depth, 1, 1_000)) return false;
    if (!finiteBetween(fan.free_air_flow_m3_s, min_fan_flow_m3_s, 100)) return false;
    if (!finiteBetween(fan.max_static_pressure_pa, 0, 1_000_000)) return false;
    return finiteBetween(fan.operating_flow_fraction, min_fan_flow_m3_s, 1);
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
    if (document.fans) |fans| if (fans.len > 64) return error.InvalidDocument;
    for (document.boards, 0..) |board, index| {
        if (!validBoardPose(board)) return error.InvalidDocument;
        for (document.boards[0..index]) |prior| if (std.mem.eql(u8, prior.name, board.name)) return error.InvalidDocument;
    }
    if (document.fans) |fans| for (fans, 0..) |fan, index| {
        if (!validFan(fan)) return error.InvalidDocument;
        for (fans[0..index]) |prior| if (std.mem.eql(u8, prior.id, fan.id)) return error.InvalidDocument;
    };
    for (document.sketches, 0..) |sketch, index| {
        try validateSketch(allocator, sketch);
        for (document.sketches[0..index]) |prior| if (std.mem.eql(u8, prior.id, sketch.id)) return error.InvalidDocument;
    }
    for (document.extrusions, 0..) |extrusion, index| {
        if (!safeId(extrusion.id) or extrusion.name.len == 0 or extrusion.name.len > 128) return error.InvalidDocument;
        if (!finiteBetween(extrusion.distance, 0.01, 10_000)) return error.InvalidDocument;
        const sketch_i = sketchIndex(document, extrusion.sketch) orelse return error.InvalidDocument;
        if (extrusion.enabled) {
            const compiled = shape_sketch.compile(allocator, document.sketches[sketch_i].geometry, shape_sketch.default_sagitta_mm) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidDocument,
            };
            allocator.free(compiled.pts);
            allocator.free(compiled.poly);
            allocator.free(compiled.arcs);
        }
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
        if (constraint.placement) |placement| try writer.print(",\"placement\":[{d},{d}]", .{ placement[0], placement[1] });
        if (constraint.measure) |measure| try writer.print(",\"measure\":\"{s}\"", .{@tagName(measure)});
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
    try writer.writeByte(']');
    if (document.fans) |fans| {
        try writer.writeAll(",\"fans\":[");
        for (fans, 0..) |fan, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"id\":");
            try json_writer.writeString(writer, fan.id);
            try writer.writeAll(",\"name\":");
            try json_writer.writeString(writer, fan.name);
            try writer.print(",\"enabled\":{s},\"x\":{d},\"y\":{d},\"z\":{d},\"rotation\":{d},\"width\":{d},\"depth\":{d},\"direction\":\"{s}\",\"free_air_flow_m3_s\":{d},\"max_static_pressure_pa\":{d},\"operating_flow_fraction\":{d}}}", .{
                if (fan.enabled) "true" else "false",
                fan.x,
                fan.y,
                fan.z,
                fan.rotation,
                fan.width,
                fan.depth,
                @tagName(fan.direction),
                fan.free_air_flow_m3_s,
                fan.max_static_pressure_pa,
                fan.operating_flow_fraction,
            });
        }
        try writer.writeByte(']');
    }
    try writer.writeAll(",\"sketches\":[");
    for (document.sketches, 0..) |sketch, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"id\":");
        try json_writer.writeString(writer, sketch.id);
        try writer.writeAll(",\"name\":");
        try json_writer.writeString(writer, sketch.name);
        try writer.print(",\"plane\":\"{s}\",\"plane_z\":{d},\"geometry\":", .{ @tagName(sketch.plane), sketch.plane_z });
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
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"fans\"") == null);
}

test "system fans round trip and an authored empty list remains distinct" {
    const source =
        "{\"schema\":\"netlisp-mechanical-v2\",\"boards\":[],\"fans\":[{" ++
        "\"id\":\"fan-1\",\"name\":\"Front intake\",\"x\":12,\"y\":-3,\"z\":42,\"rotation\":90," ++
        "\"width\":80,\"depth\":80,\"direction\":\"down\",\"free_air_flow_m3_s\":0.025," ++
        "\"max_static_pressure_pa\":80.4,\"operating_flow_fraction\":0.6}],\"sketches\":[],\"extrusions\":[]}";
    var parsed = try parse(std.testing.allocator, source);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.fans.?.len);
    try std.testing.expectEqualStrings("Front intake", parsed.value.fans.?[0].name);
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try write(&encoded.writer, parsed.value);
    var round_trip = try parse(std.testing.allocator, encoded.written());
    defer round_trip.deinit();
    try std.testing.expectEqual(FanDirection.down, round_trip.value.fans.?[0].direction);
    try std.testing.expectApproxEqAbs(@as(f64, 0.6), round_trip.value.fans.?[0].operating_flow_fraction, 1e-12);

    var empty = try parse(std.testing.allocator, "{\"schema\":\"netlisp-mechanical-v2\",\"boards\":[],\"fans\":[],\"sketches\":[],\"extrusions\":[]}");
    defer empty.deinit();
    var empty_encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer empty_encoded.deinit();
    try write(&empty_encoded.writer, empty.value);
    try std.testing.expect(std.mem.indexOf(u8, empty_encoded.written(), "\"fans\":[]") != null);
}

test "system fan validation rejects duplicate ids and invalid flow" {
    const duplicate =
        "{\"schema\":\"netlisp-mechanical-v2\",\"fans\":[" ++
        "{\"id\":\"fan-1\",\"name\":\"A\",\"free_air_flow_m3_s\":0.01}," ++
        "{\"id\":\"fan-1\",\"name\":\"B\",\"free_air_flow_m3_s\":0.02}]}";
    try std.testing.expectError(error.InvalidDocument, parse(std.testing.allocator, duplicate));
    const invalid_flow = "{\"schema\":\"netlisp-mechanical-v2\",\"fans\":[{\"id\":\"fan-1\",\"name\":\"A\",\"free_air_flow_m3_s\":0}]}";
    try std.testing.expectError(error.InvalidDocument, parse(std.testing.allocator, invalid_flow));
}

test "closed sketch extrusion round trips and open extrusion is rejected" {
    const source =
        "{\"schema\":\"netlisp-mechanical-v2\",\"sketches\":[{\"id\":\"sketch-1\",\"name\":\"Floor\",\"plane\":\"xz\",\"plane_z\":4,\"geometry\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":-20,\"y\":-15},{\"id\":2,\"x\":20,\"y\":-15},{\"id\":3,\"x\":20,\"y\":15},{\"id\":4,\"x\":-20,\"y\":15}]," ++
        "\"curves\":[{\"id\":11,\"kind\":\"line\",\"a\":1,\"b\":2},{\"id\":12,\"kind\":\"line\",\"a\":2,\"b\":3},{\"id\":13,\"kind\":\"line\",\"a\":3,\"b\":4},{\"id\":14,\"kind\":\"line\",\"a\":4,\"b\":1}],\"constraints\":[{\"id\":21,\"kind\":\"horizontal\",\"a\":11,\"mode\":\"driving\"},{\"id\":22,\"kind\":\"offset\",\"a\":11,\"b\":13,\"value\":30,\"placement\":[0,18],\"mode\":\"driving\"}]}}]," ++
        "\"extrusions\":[{\"id\":\"extrude-1\",\"name\":\"Floor\",\"sketch\":\"sketch-1\",\"distance\":2}]}";
    var parsed = try parse(std.testing.allocator, source);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(f64, 2), parsed.value.extrusions[0].distance);
    try std.testing.expectEqual(SketchPlane.xz, parsed.value.sketches[0].plane);
    try std.testing.expectEqual(@as(f64, 4), parsed.value.sketches[0].plane_z);
    try std.testing.expectEqualDeep(@as(?[2]f64, .{ 0, 18 }), parsed.value.sketches[0].geometry.constraints[1].placement);
    var encoded: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer encoded.deinit();
    try write(&encoded.writer, parsed.value);
    var round_trip = try parse(std.testing.allocator, encoded.written());
    defer round_trip.deinit();
    try std.testing.expectEqualStrings("sketch-1", round_trip.value.extrusions[0].sketch);
    try std.testing.expectEqual(SketchPlane.xz, round_trip.value.sketches[0].plane);
    try std.testing.expect(std.mem.indexOf(u8, encoded.written(), "\"placement\":[0,18]") != null);

    const open =
        "{\"schema\":\"netlisp-mechanical-v2\",\"sketches\":[{\"id\":\"open\",\"name\":\"Open\",\"geometry\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":10,\"y\":0}],\"curves\":[{\"id\":3,\"kind\":\"line\",\"a\":1,\"b\":2}],\"constraints\":[]}}]," ++
        "\"extrusions\":[{\"id\":\"bad\",\"name\":\"Bad\",\"sketch\":\"open\",\"distance\":2}]}";
    try std.testing.expectError(error.InvalidDocument, parse(std.testing.allocator, open));
    const disabled_open =
        "{\"schema\":\"netlisp-mechanical-v2\",\"sketches\":[{\"id\":\"open\",\"name\":\"Open\",\"plane\":\"yz\",\"geometry\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0},{\"id\":2,\"x\":10,\"y\":0}],\"curves\":[{\"id\":3,\"kind\":\"line\",\"a\":1,\"b\":2}],\"constraints\":[]}}]," ++
        "\"extrusions\":[{\"id\":\"paused\",\"name\":\"Paused\",\"sketch\":\"open\",\"distance\":2,\"enabled\":false}]}";
    var disabled = try parse(std.testing.allocator, disabled_open);
    disabled.deinit();

    const malformed_draft =
        "{\"schema\":\"netlisp-mechanical-v2\",\"sketches\":[{\"id\":\"bad-draft\",\"name\":\"Bad draft\",\"geometry\":{" ++
        "\"version\":1,\"points\":[{\"id\":1,\"x\":0,\"y\":0}],\"curves\":[{\"id\":3,\"kind\":\"line\",\"a\":1,\"b\":2}],\"constraints\":[]}}]}";
    try std.testing.expectError(error.InvalidDocument, parse(std.testing.allocator, malformed_draft));
}

test "legacy generated enclosure document is identified rather than loaded" {
    const source = "{\"schema\":\"netlisp-mechanical-v1\",\"occupied\":{\"width\":90,\"depth\":55}}";
    try std.testing.expectError(error.LegacyEnclosureDocument, parse(std.testing.allocator, source));
}
