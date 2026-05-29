const std = @import("std");
const env_mod = @import("env.zig");
const Value = env_mod.Value;

pub const FmtError = error{
    OutOfMemory,
    FormatError,
    TypeError,
    NotEnoughArgs,
};

// ── Constants ─────────────────────────────────────────────────────
const ONE_UNIT: f64 = 1.0;
const ZERO_UNIT: f64 = 0.0;
const MILLI_THRESHOLD: f64 = 0.001;
const MICRO_THRESHOLD: f64 = 0.000001;
const NANO_THRESHOLD: f64 = 0.000000001;
const KILO: f64 = 1000.0;
const MEGA: f64 = 1_000_000.0;
const GIGA: f64 = 1_000_000_000.0;
const TERA: f64 = 1_000_000_000_000.0;
const WHOLE_NUMBER_LIMIT: f64 = 1e15;

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
                'V' => try formatVoltage(writer, try nextNumber(args, &arg_idx)),
                'R' => try formatResistance(writer, try nextNumber(args, &arg_idx)),
                'C' => try formatCapacitance(writer, try nextNumber(args, &arg_idx)),
                'A' => try formatAmperage(writer, try nextNumber(args, &arg_idx)),
                'S' => writer.writeAll(try nextString(args, &arg_idx)) catch return FmtError.OutOfMemory,
                else => return FmtError.FormatError,
            }
        } else {
            writer.writeByte(template[i]) catch return FmtError.OutOfMemory;
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Take the next argument as a number, advancing `idx`. Errors if the args are
/// exhausted or the value isn't numeric.
fn nextNumber(args: []const Value, idx: *usize) FmtError!f64 {
    if (idx.* >= args.len) return FmtError.NotEnoughArgs;
    const v = args[idx.*].asNumber() orelse return FmtError.TypeError;
    idx.* += 1;
    return v;
}

/// Take the next argument as a string, advancing `idx`. Errors if the args are
/// exhausted or the value isn't a string.
fn nextString(args: []const Value, idx: *usize) FmtError![]const u8 {
    if (idx.* >= args.len) return FmtError.NotEnoughArgs;
    const v = args[idx.*].asString() orelse return FmtError.TypeError;
    idx.* += 1;
    return v;
}

fn formatVoltage(writer: anytype, v: f64) !void {
    try formatNumber(writer, v);
    try writer.writeByte('V');
}

fn formatResistance(writer: anytype, v: f64) !void {
    const abs = @abs(v);
    if (abs >= MEGA) {
        try formatNumber(writer, v / MEGA);
        try writer.writeByte('M');
    } else if (abs >= KILO) {
        try formatNumber(writer, v / KILO);
        try writer.writeByte('k');
    } else {
        try formatNumber(writer, v);
    }
}

fn formatCapacitance(writer: anytype, v: f64) !void {
    const abs = @abs(v);
    if (abs >= ONE_UNIT) {
        try formatNumber(writer, v);
        try writer.writeByte('F');
    } else if (abs >= MILLI_THRESHOLD) {
        try formatNumber(writer, v * KILO);
        try writer.writeAll("mF");
    } else if (abs >= MICRO_THRESHOLD) {
        try formatNumber(writer, v * MEGA);
        try writer.writeAll("uF");
    } else if (abs >= NANO_THRESHOLD) {
        try formatNumber(writer, v * GIGA);
        try writer.writeAll("nF");
    } else {
        try formatNumber(writer, v * TERA);
        try writer.writeAll("pF");
    }
}

fn formatAmperage(writer: anytype, v: f64) !void {
    const abs = @abs(v);
    if (abs >= ONE_UNIT) {
        try formatNumber(writer, v);
        try writer.writeAll("A");
    } else if (abs >= MILLI_THRESHOLD) {
        try formatNumber(writer, v * KILO);
        try writer.writeAll("mA");
    } else if (abs == ZERO_UNIT) {
        try writer.writeAll("0A");
    } else {
        try formatNumber(writer, v * MEGA);
        try writer.writeAll("uA");
    }
}

fn formatNumber(writer: anytype, v: f64) !void {
    // If it's a whole number, print without decimals
    if (v == @floor(v) and @abs(v) < WHOLE_NUMBER_LIMIT) {
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
