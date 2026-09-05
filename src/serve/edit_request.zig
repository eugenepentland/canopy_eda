//! One JSON decode and type validation before an edit reaches source text.
const std = @import("std");

/// Parsed edit fields borrow the request arena, including decoded escapes.
pub const Request = struct {
    root: std.json.Value,

    /// Return a validated optional string field.
    pub fn string(self: Request, key: []const u8) ?[]const u8 {
        const value = self.root.object.get(key) orelse return null;
        return if (value == .string) value.string else null;
    }

    /// Byte offset is an integer, never a numeric string or floating point value.
    pub fn offset(self: Request) usize {
        const value = self.root.object.get("srcOff") orelse return 0;
        return std.math.cast(usize, value.integer) orelse 0;
    }

    /// Return a validated optional boolean field.
    pub fn boolean(self: Request, key: []const u8) bool {
        const value = self.root.object.get(key) orelse return false;
        return value.bool;
    }
};

/// Reject malformed JSON, duplicate keys and incorrectly typed edit arguments.
pub fn decode(allocator: std.mem.Allocator, body: []const u8) (std.mem.Allocator.Error || error{InvalidEditRequest})!Request {
    const root = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEditRequest,
    };
    if (root != .object) return error.InvalidEditRequest;
    const strings = [_][]const u8{ "ref", "value", "component", "oldComponent", "sourceName", "section", "kind", "name", "args", "title", "role", "subtitle", "from", "to", "net", "dir", "pin", "ic", "old_pin", "new_pin", "pin_a", "pin_b", "sourceRevision", "sourceLabel", "mpn", "manufacturer", "source" };
    for (strings) |key| {
        if (root.object.get(key)) |value| {
            if (value != .string) return error.InvalidEditRequest;
        }
    }
    if (root.object.get("srcOff")) |value| {
        if (value != .integer) return error.InvalidEditRequest;
        if (value.integer < 0) return error.InvalidEditRequest;
        if (std.math.cast(usize, value.integer) == null) return error.InvalidEditRequest;
    }
    for ([_][]const u8{ "dnp", "import", "enabled" }) |key| {
        if (root.object.get(key)) |value| {
            if (value != .bool) return error.InvalidEditRequest;
        }
    }
    if (root.object.get("pins")) |pins| {
        if (pins != .object) return error.InvalidEditRequest;
        for (pins.object.keys()) |key| {
            if (!atom(key)) return error.InvalidEditRequest;
        }
        for (pins.object.values()) |value| {
            if (value != .string) return error.InvalidEditRequest;
        }
    }
    for ([_][]const u8{ "component", "oldComponent", "pin", "old_pin", "new_pin", "pin_a", "pin_b" }) |key| {
        if (root.object.get(key)) |value| {
            if (!atom(value.string)) return error.InvalidEditRequest;
        }
    }
    return .{ .root = root };
}

fn atom(value: []const u8) bool {
    return value.len > 0 and std.mem.indexOfAny(u8, value, " \t\r\n\"\\();") == null;
}

// spec: Web Server - Edit JSON decodes escaped values exactly once and rejects malformed or wrongly typed fields
test "edit request decodes escapes and refuses wrong types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const request = try decode(a, "{\"ref\":\"R1\",\"value\":\"a\\\"b\\\\c\",\"srcOff\":42}");
    try std.testing.expectEqualStrings("a\"b\\c", request.string("value").?);
    try std.testing.expectEqual(@as(usize, 42), request.offset());
    try std.testing.expectError(error.InvalidEditRequest, decode(a, "{\"value\":10,\"srcOff\":42}"));
    try std.testing.expectError(error.InvalidEditRequest, decode(a, "{\"srcOff\":-1}"));
    try std.testing.expectError(error.InvalidEditRequest, decode(a, "{\"srcOff\":\"42\"}"));
    try std.testing.expectError(error.InvalidEditRequest, decode(a, "[]"));
    for ([_][]const u8{ "{", "{\"ref\":\"R1\",\"ref\":\"R2\"}", "{\"dnp\":1}", "{\"pins\":{\"1\":3}}" }) |invalid| {
        try std.testing.expectError(error.InvalidEditRequest, decode(a, invalid));
    }
}
