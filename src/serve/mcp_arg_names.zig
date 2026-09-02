//! One parser for the name-list argument every PCB MCP tool accepts.
//!
//! `nets`, `refs` and their relatives are documented as "a JSON array of
//! names, or one comma-separated string", and each tool had its own copy of
//! the three-way switch that reads them. A copy that trimmed differently — or
//! forgot that an absent argument means "every net" rather than "no nets" —
//! would silently change which nets a pass operates on for that one tool,
//! which is exactly the kind of divergence no test in either file would catch.

const std = @import("std");

/// The name list under `key`, on `alloc`.
///
/// Empty when the argument is absent, when `args_val` is not an object, and
/// for any JSON type that is neither an array nor a string — an absent
/// restriction means "unrestricted" at every call site, so a malformed one
/// degrades to the same thing rather than to an empty allowlist that would
/// silently do nothing. Array entries must be non-empty strings; a comma
/// string is split on `,` with surrounding spaces trimmed and empty pieces
/// dropped, so `"GND, , 3V3"` yields two names. The returned slices borrow the
/// parsed JSON.
pub fn parse(
    alloc: std.mem.Allocator,
    args_val: ?std.json.Value,
    key: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const av = args_val orelse return &.{};
    if (av != .object) return &.{};
    const v = av.object.get(key) orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    switch (v) {
        .array => |arr| for (arr.items) |it| {
            if (it == .string and it.string.len > 0) try out.append(alloc, it.string);
        },
        .string => |s| {
            var parts = std.mem.splitScalar(u8, s, ',');
            while (parts.next()) |p| {
                const t = std.mem.trim(u8, p, " ");
                if (t.len > 0) try out.append(alloc, t);
            }
        },
        else => {},
    }
    return out.items;
}

// spec: serve/mcp_tools - A name-list tool argument reads the same from a JSON array and from a comma string
test "parse reads a name list from either accepted shape" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"array":["GND","",  "3V3"],
        \\ "comma":"GND, , 3V3",
        \\ "wrong_type":7}
    , .{});
    defer parsed.deinit();

    const from_array = try parse(alloc, parsed.value, "array");
    const from_comma = try parse(alloc, parsed.value, "comma");
    try testing.expectEqual(@as(usize, 2), from_array.len);
    try testing.expectEqual(@as(usize, 2), from_comma.len);
    for (from_array, from_comma) |a, c| try testing.expectEqualStrings(a, c);
    try testing.expectEqualStrings("GND", from_array[0]);
    try testing.expectEqualStrings("3V3", from_array[1]);

    // Absent, non-object and unusable types all mean "no restriction".
    try testing.expectEqual(@as(usize, 0), (try parse(alloc, parsed.value, "absent")).len);
    try testing.expectEqual(@as(usize, 0), (try parse(alloc, parsed.value, "wrong_type")).len);
    try testing.expectEqual(@as(usize, 0), (try parse(alloc, null, "array")).len);
    try testing.expectEqual(@as(usize, 0), (try parse(alloc, std.json.Value{ .integer = 1 }, "array")).len);
}
