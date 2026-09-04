//! Persisted system mechanical-CAD document.
//!
//! The browser edits this small, source-controlled JSON sidecar, while the
//! native enclosure generator and exporters consume the same typed values.

const std = @import("std");
const enclosure = @import("enclosure.zig");
const prismatic = @import("prismatic.zig");
const json_writer = @import("../json_writer.zig");

const schema_name = "netlisp-mechanical-v1";
/// Maximum accepted mechanical document size.
pub const mechanical_document_byte_limit: usize = 256 * 1024;

/// Saved assembly pose for one imported PCB.
const BoardPose = struct {
    name: []const u8,
    enabled: bool = true,
    x: f64 = 0,
    y: f64 = 0,
    z: f64 = 5,
    rotation: f64 = 0,
};

/// Native screw-boss recipe stored in a document.
const Boss = enclosure.Boss;
/// Native wall-opening recipe stored in a document.
const Cutout = prismatic.WallCutout;

/// Exterior and cavity construction values edited together in the UI.
const CaseSettings = struct {
    clearance: f64 = 2.5,
    wall: f64 = 2.4,
    floor: f64 = 2,
    height: f64 = 28,
    lid_thickness: f64 = 2.4,
    lid_explode: f64 = 24,
};

/// Current occupied PCB envelope in the enclosure XY frame.
const Occupied = struct { width: f64, depth: f64 };

/// Versioned, source-controlled mechanical state for one system.
pub const Document = struct {
    schema: []const u8 = schema_name,
    occupied: Occupied,
    settings: CaseSettings = .{},
    boards: []const BoardPose = &.{},
    bosses: []const Boss = &.{},
    cutouts: []const Cutout = &.{},
};

pub const DocumentError = error{InvalidDocument};
/// Parsing preserves allocation failure but normalizes malformed input.
pub const ParseError = std.mem.Allocator.Error || DocumentError;

fn finiteBetween(value: f64, minimum: f64, maximum: f64) bool {
    return std.math.isFinite(value) and value >= minimum and value <= maximum;
}

fn validBoardPose(board: BoardPose) bool {
    if (board.name.len == 0 or board.name.len > 128) return false;
    const xy_valid = finiteBetween(board.x, -2000, 2000) and finiteBetween(board.y, -2000, 2000);
    const zr_valid = finiteBetween(board.z, -500, 500) and finiteBetween(board.rotation, -36000, 36000);
    return xy_valid and zr_valid;
}

/// Check all document bounds and native feature constraints without writing.
pub fn validate(document: Document) DocumentError!void {
    if (!std.mem.eql(u8, document.schema, schema_name)) return error.InvalidDocument;
    if (!finiteBetween(document.occupied.width, 1, 2000) or !finiteBetween(document.occupied.depth, 1, 2000)) return error.InvalidDocument;
    if (!finiteBetween(document.settings.clearance, 0.1, 100) or !finiteBetween(document.settings.wall, 0.2, 100)) return error.InvalidDocument;
    if (!finiteBetween(document.settings.floor, 0.2, 100) or !finiteBetween(document.settings.height, 0.5, 500)) return error.InvalidDocument;
    if (document.settings.floor >= document.settings.height) return error.InvalidDocument;
    if (!finiteBetween(document.settings.lid_thickness, 0.2, 100) or !finiteBetween(document.settings.lid_explode, 0, 500)) return error.InvalidDocument;
    if (document.boards.len > 64 or document.bosses.len > 64 or document.cutouts.len > 32) return error.InvalidDocument;
    for (document.boards, 0..) |board, index| {
        if (!validBoardPose(board)) return error.InvalidDocument;
        for (document.boards[0..index]) |prior| if (std.mem.eql(u8, prior.name, board.name)) return error.InvalidDocument;
    }
    _ = enclosure.validateParameters(parameters(document), features(document)) catch return error.InvalidDocument;
}

/// Lower persisted case values into the semantic enclosure recipe.
pub fn parameters(document: Document) enclosure.Parameters {
    return .{
        .occupied_width = document.occupied.width,
        .occupied_depth = document.occupied.depth,
        .clearance = document.settings.clearance,
        .wall = document.settings.wall,
        .floor = document.settings.floor,
        .height = document.settings.height,
        .lid_thickness = document.settings.lid_thickness,
    };
}

/// Lower persisted additive details into native generator features.
pub fn features(document: Document) enclosure.Features {
    return .{ .cutouts = document.cutouts, .bosses = document.bosses };
}

/// Parse and fully validate an authored mechanical JSON document.
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!std.json.Parsed(Document) {
    if (source.len == 0 or source.len > mechanical_document_byte_limit) return error.InvalidDocument;
    var parsed = std.json.parseFromSlice(Document, allocator, source, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDocument,
    };
    errdefer parsed.deinit();
    try validate(parsed.value);
    return parsed;
}

/// Canonical, stable JSON used for source control and request bodies.
pub fn write(writer: *std.Io.Writer, document: Document) json_writer.WriteError!void {
    try writer.writeAll("{\"schema\":\"");
    try writer.writeAll(schema_name);
    try writer.writeByte('"');
    try writer.print(",\"occupied\":{{\"width\":{d},\"depth\":{d}}}", .{ document.occupied.width, document.occupied.depth });
    try writer.writeAll(",\"settings\":{");
    try writer.print("\"clearance\":{d},\"wall\":{d},\"floor\":{d},\"height\":{d},\"lid_thickness\":{d},\"lid_explode\":{d}}}", .{
        document.settings.clearance, document.settings.wall, document.settings.floor, document.settings.height, document.settings.lid_thickness, document.settings.lid_explode,
    });
    try writer.writeAll(",\"boards\":[");
    for (document.boards, 0..) |board, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try json_writer.writeString(writer, board.name);
        try writer.print(",\"enabled\":{s},\"x\":{d},\"y\":{d},\"z\":{d},\"rotation\":{d}}}", .{
            if (board.enabled) "true" else "false", board.x, board.y, board.z, board.rotation,
        });
    }
    try writer.writeAll("],\"bosses\":[");
    for (document.bosses, 0..) |boss, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"x\":{d},\"y\":{d},\"outer_diameter\":{d},\"hole_diameter\":{d},\"height\":{d}}}", .{
            boss.x, boss.y, boss.outer_diameter, boss.hole_diameter, boss.height,
        });
    }
    try writer.writeAll("],\"cutouts\":[");
    for (document.cutouts, 0..) |cutout, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("{{\"wall\":\"{s}\",\"center\":{d},\"width\":{d},\"bottom\":{d},\"height\":{d}}}", .{
            @tagName(cutout.wall), cutout.center, cutout.width, cutout.bottom, cutout.height,
        });
    }
    try writer.writeAll("]}\n");
}

test "mechanical document validates and canonical JSON round-trips" {
    const source =
        "{\"schema\":\"netlisp-mechanical-v1\",\"occupied\":{\"width\":90,\"depth\":55}," ++
        "\"boards\":[{\"name\":\"barracuda\",\"z\":5}]," ++
        "\"bosses\":[{\"x\":20,\"y\":10,\"outer_diameter\":6,\"hole_diameter\":2.8,\"height\":3}]," ++
        "\"cutouts\":[{\"wall\":\"front\",\"center\":0,\"width\":12,\"bottom\":5,\"height\":8}]}";
    var parsed = try parse(std.testing.allocator, source);
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, parsed.value);
    var again = try parse(std.testing.allocator, out.written());
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 1), again.value.bosses.len);
    try std.testing.expectEqual(prismatic.Wall.front, again.value.cutouts[0].wall);
}

test "mechanical document rejects bosses outside the case" {
    const source =
        "{\"occupied\":{\"width\":20,\"depth\":20}," ++
        "\"bosses\":[{\"x\":30,\"y\":0,\"outer_diameter\":6,\"hole_diameter\":2.8,\"height\":3}]}";
    try std.testing.expectError(error.InvalidDocument, parse(std.testing.allocator, source));
}
