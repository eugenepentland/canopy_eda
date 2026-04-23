const std = @import("std");
const env_mod = @import("env.zig");
const Value = env_mod.Value;

pub const FmtError = error{
    OutOfMemory,
    FormatError,
    TypeError,
    NotEnoughArgs,
};

/// Format a string with ~V, ~R, ~C, ~A, ~S, ~~ specifiers.
pub fn format(allocator: std.mem.Allocator, template: []const u8, args: []const Value) FmtError![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    var arg_idx: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '~' and i + 1 < template.len) {
            const spec = template[i + 1];
            i += 2;
            switch (spec) {
                '~' => writer.writeByte('~') catch return FmtError.OutOfMemory,
                'V' => {
                    if (arg_idx >= args.len) return FmtError.NotEnoughArgs;
                    const v = args[arg_idx].asNumber() orelse return FmtError.TypeError;
                    arg_idx += 1;
                    try formatVoltage(writer, v);
                },
                'R' => {
                    if (arg_idx >= args.len) return FmtError.NotEnoughArgs;
                    const v = args[arg_idx].asNumber() orelse return FmtError.TypeError;
                    arg_idx += 1;
                    try formatResistance(writer, v);
                },
                'C' => {
                    if (arg_idx >= args.len) return FmtError.NotEnoughArgs;
                    const v = args[arg_idx].asNumber() orelse return FmtError.TypeError;
                    arg_idx += 1;
                    try formatCapacitance(writer, v);
                },
                'A' => {
                    if (arg_idx >= args.len) return FmtError.NotEnoughArgs;
                    const v = args[arg_idx].asNumber() orelse return FmtError.TypeError;
                    arg_idx += 1;
                    try formatAmperage(writer, v);
                },
                'S' => {
                    if (arg_idx >= args.len) return FmtError.NotEnoughArgs;
                    const v = args[arg_idx].asString() orelse return FmtError.TypeError;
                    arg_idx += 1;
                    writer.writeAll(v) catch return FmtError.OutOfMemory;
                },
                else => return FmtError.FormatError,
            }
        } else {
            writer.writeByte(template[i]) catch return FmtError.OutOfMemory;
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn formatVoltage(writer: anytype, v: f64) !void {
    try formatNumber(writer, v);
    try writer.writeByte('V');
}

fn formatResistance(writer: anytype, v: f64) !void {
    const abs = @abs(v);
    if (abs >= 1_000_000.0) {
        try formatNumber(writer, v / 1_000_000.0);
        try writer.writeByte('M');
    } else if (abs >= 1000.0) {
        try formatNumber(writer, v / 1000.0);
        try writer.writeByte('k');
    } else {
        try formatNumber(writer, v);
    }
}

fn formatCapacitance(writer: anytype, v: f64) !void {
    const abs = @abs(v);
    if (abs >= 1.0) {
        try formatNumber(writer, v);
        try writer.writeByte('F');
    } else if (abs >= 0.001) {
        try formatNumber(writer, v * 1000.0);
        try writer.writeAll("mF");
    } else if (abs >= 0.000001) {
        try formatNumber(writer, v * 1_000_000.0);
        try writer.writeAll("uF");
    } else if (abs >= 0.000000001) {
        try formatNumber(writer, v * 1_000_000_000.0);
        try writer.writeAll("nF");
    } else {
        try formatNumber(writer, v * 1_000_000_000_000.0);
        try writer.writeAll("pF");
    }
}

fn formatAmperage(writer: anytype, v: f64) !void {
    const abs = @abs(v);
    if (abs >= 1.0) {
        try formatNumber(writer, v);
        try writer.writeAll("A");
    } else if (abs >= 0.001) {
        try formatNumber(writer, v * 1000.0);
        try writer.writeAll("mA");
    } else if (abs == 0.0) {
        try writer.writeAll("0A");
    } else {
        try formatNumber(writer, v * 1_000_000.0);
        try writer.writeAll("uA");
    }
}

fn formatNumber(writer: anytype, v: f64) !void {
    // If it's a whole number, print without decimals
    if (v == @floor(v) and @abs(v) < 1e15) {
        const i: i64 = @intFromFloat(v);
        writer.print("{d}", .{i}) catch return error.OutOfMemory;
    } else {
        // Print with reasonable precision, trim trailing zeros
        var buf: [64]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d:.4}", .{v}) catch {
            writer.print("{d}", .{v}) catch return error.OutOfMemory;
            return;
        };
        var end: usize = formatted.len;
        if (std.mem.indexOfScalar(u8, formatted, '.') != null) {
            while (end > 1 and formatted[end - 1] == '0') : (end -= 1) {}
            if (end > 0 and formatted[end - 1] == '.') end -= 1;
        }
        writer.writeAll(formatted[0..end]) catch return error.OutOfMemory;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: eval/fmt - Formats voltage values with SI prefix and V suffix
test "format voltage" {
    const alloc = std.testing.allocator;
    const args = [_]Value{.{ .number = 3.41 }};
    const result = try format(alloc, "~V Buck", &args);
    defer alloc.free(result);
    try std.testing.expectEqualStrings("3.41V Buck", result);
}

// spec: eval/fmt - Formats resistance values with SI prefix and ohm suffix
test "format resistance" {
    const alloc = std.testing.allocator;
    {
        const args = [_]Value{.{ .number = 220000.0 }};
        const r = try format(alloc, "~R", &args);
        defer alloc.free(r);
        try std.testing.expectEqualStrings("220k", r);
    }
    {
        const args = [_]Value{.{ .number = 47000.0 }};
        const r = try format(alloc, "~R", &args);
        defer alloc.free(r);
        try std.testing.expectEqualStrings("47k", r);
    }
    {
        const args = [_]Value{.{ .number = 1000.0 }};
        const r = try format(alloc, "~R", &args);
        defer alloc.free(r);
        try std.testing.expectEqualStrings("1k", r);
    }
}

// spec: eval/fmt - Formats capacitance values with SI prefix and F suffix
test "format capacitance" {
    const alloc = std.testing.allocator;
    {
        const args = [_]Value{.{ .number = 0.000001 }};
        const r = try format(alloc, "~C", &args);
        defer alloc.free(r);
        try std.testing.expectEqualStrings("1uF", r);
    }
    {
        const args = [_]Value{.{ .number = 0.000000022 }};
        const r = try format(alloc, "~C", &args);
        defer alloc.free(r);
        try std.testing.expectEqualStrings("22nF", r);
    }
}

// spec: eval/fmt - Formats amperage values with SI prefix (uA/mA/A)
test "format amperage" {
    const alloc = std.testing.allocator;
    {
        const args = [_]Value{.{ .number = 2.0 }};
        const r = try format(alloc, "~A", &args);
        defer alloc.free(r);
        try std.testing.expectEqualStrings("2A", r);
    }
    {
        const args = [_]Value{.{ .number = 0.15 }};
        const r = try format(alloc, "~A", &args);
        defer alloc.free(r);
        try std.testing.expectEqualStrings("150mA", r);
    }
    {
        const args = [_]Value{.{ .number = 0.00005 }};
        const r = try format(alloc, "~A", &args);
        defer alloc.free(r);
        try std.testing.expectEqualStrings("50uA", r);
    }
}

// spec: eval/fmt - Formats tilde escape sequences in format strings
test "format tilde escape" {
    const alloc = std.testing.allocator;
    const result = try format(alloc, "hello ~~ world", &[_]Value{});
    defer alloc.free(result);
    try std.testing.expectEqualStrings("hello ~ world", result);
}

// spec: eval/fmt - Formats mixed specifiers in a single format string
test "format mixed" {
    const alloc = std.testing.allocator;
    const args = [_]Value{
        .{ .number = 220000.0 },
        .{ .number = 47000.0 },
    };
    const r = try format(alloc, "RFBT = ~R, RFBB = ~R", &args);
    defer alloc.free(r);
    try std.testing.expectEqualStrings("RFBT = 220k, RFBB = 47k", r);
}
