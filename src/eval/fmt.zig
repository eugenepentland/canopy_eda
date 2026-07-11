//! The `(fmt …)` string formatter: parses the `~V`/`~R`/`~C`/`~A`/`~S`
//! directives (voltage, resistance, capacitance, amperage, string) and renders
//! them from SI-suffixed values. Its directive table is one of the dispatch
//! tables the auto-generated language reference is built from — keep it in sync
//! (docgen enforces this on every build).

const std = @import("std");
const env_mod = @import("env.zig");
const numeric = @import("../numeric.zig");
const Value = env_mod.Value;
pub const FmtError = error{
    OutOfMemory,
    FormatError,
    TypeError,
    NotEnoughArgs,
};

// ── Constants ─────────────────────────────────────────────────────
const one_unit: f64 = 1.0;
const zero_unit: f64 = 0.0;
const milli_threshold: f64 = 0.001;
const micro_threshold: f64 = 0.000001;
const nano_threshold: f64 = 0.000000001;
const kilo: f64 = 1000.0;
const mega: f64 = 1_000_000.0;
const giga: f64 = 1_000_000_000.0;
const tera: f64 = 1_000_000_000_000.0;
const whole_number_limit: f64 = 1e15;

/// What a `~X` directive consumes from the argument list.
pub const DirectiveArg = enum { number, string, none };

/// One `(fmt …)` template directive. This table is the single source of
/// truth for the language docs (`src/docgen.zig` renders it into
/// `docs/language-forms.md`); the "directive table matches format()
/// dispatch" test below proves the `format` switch and this table
/// recognise exactly the same specifier characters, so they can't drift.
pub const Directive = struct {
    spec: u8,
    arg: DirectiveArg,
    summary: []const u8,
};

pub const directives = [_]Directive{
    .{ .spec = 'V', .arg = .number, .summary = "Voltage: plain number + `V` (`3.41` → `3.41V`)." },
    .{ .spec = 'R', .arg = .number, .summary = "Resistance: SI-scaled with `k`/`M` (`4700` → `4.7k`)." },
    .{ .spec = 'C', .arg = .number, .summary = "Capacitance: SI-scaled `F`/`mF`/`uF`/`nF`/`pF` (`1e-7` → `100nF`)." },
    .{ .spec = 'A', .arg = .number, .summary = "Current: SI-scaled `A`/`mA`/`uA` (`0.002` → `2mA`)." },
    .{ .spec = 'S', .arg = .string, .summary = "Verbatim string argument." },
    .{ .spec = '~', .arg = .none, .summary = "Literal `~` (consumes no argument)." },
};

/// Format a string with ~V, ~R, ~C, ~A, ~S, ~~ specifiers.
pub fn format(allocator: std.mem.Allocator, template: []const u8, args: []const Value) FmtError![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
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
    if (abs >= mega) {
        try formatNumber(writer, v / mega);
        try writer.writeByte('M');
    } else if (abs >= kilo) {
        try formatNumber(writer, v / kilo);
        try writer.writeByte('k');
    } else {
        try formatNumber(writer, v);
    }
}

fn formatCapacitance(writer: anytype, v: f64) !void {
    const abs = @abs(v);
    if (abs >= one_unit) {
        try formatNumber(writer, v);
        try writer.writeByte('F');
    } else if (abs >= milli_threshold) {
        try formatNumber(writer, v * kilo);
        try writer.writeAll("mF");
    } else if (abs >= micro_threshold) {
        try formatNumber(writer, v * mega);
        try writer.writeAll("uF");
    } else if (abs >= nano_threshold) {
        try formatNumber(writer, v * giga);
        try writer.writeAll("nF");
    } else {
        try formatNumber(writer, v * tera);
        try writer.writeAll("pF");
    }
}

fn formatAmperage(writer: anytype, v: f64) !void {
    const abs = @abs(v);
    if (abs >= one_unit) {
        try formatNumber(writer, v);
        try writer.writeAll("A");
    } else if (abs >= milli_threshold) {
        try formatNumber(writer, v * kilo);
        try writer.writeAll("mA");
    } else if (abs == zero_unit) {
        try writer.writeAll("0A");
    } else {
        try formatNumber(writer, v * mega);
        try writer.writeAll("uA");
    }
}

fn formatNumber(writer: anytype, v: f64) !void {
    // If it's a whole number, print without decimals
    if (v == @floor(v) and @abs(v) < whole_number_limit) {
        const i: i64 = numeric.checkedInt(i64, v) orelse 0;
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
    {
        // Exactly the milli threshold (0.001 A) must land in mA, not fall to uA
        // — guards the `>=` bound (a `>` flip renders "1000uA").
        const args = [_]Value{.{ .number = 0.001 }};
        const r = try format(alloc, "~A", &args);
        defer alloc.free(r);
        try std.testing.expectEqualStrings("1mA", r);
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

// spec: eval/fmt - The directives table and format()'s dispatch recognise exactly the same specifier characters
test "directive table matches format() dispatch" {
    try std.testing.expect(directiveTableMatchesDispatch(std.testing.allocator));
}

/// Try every possible specifier byte: `format()` must reject it with
/// FormatError exactly when `directives` doesn't list it. This keeps the
/// documented directive set (rendered into docs/language-forms.md)
/// mechanically in sync with the switch in `format()`.
fn directiveTableMatchesDispatch(alloc: std.mem.Allocator) bool {
    for (0..256) |c| {
        const spec: u8 = @intCast(c);
        const in_table = for (directives) |d| {
            if (d.spec == spec) break true;
        } else false;
        const recognized = specRecognized(alloc, spec);
        if (in_table != recognized) {
            std.debug.print("fmt directive '~{c}' (0x{x:0>2}): in table={}, dispatched={}\n", .{ spec, spec, in_table, recognized });
            return false;
        }
    }
    return true;
}

/// True when `format()` dispatches the specifier — any outcome other
/// than FormatError counts (TypeError / NotEnoughArgs still prove the
/// switch recognised it). Tries a number argument, then a string.
fn specRecognized(alloc: std.mem.Allocator, spec: u8) bool {
    const template = [_]u8{ '~', spec };
    const num_args = [_]Value{.{ .number = 1.0 }};
    if (format(alloc, &template, &num_args)) |out| {
        alloc.free(out);
        return true;
    } else |err| if (err != FmtError.FormatError) return true;
    const str_args = [_]Value{.{ .string = "x" }};
    if (format(alloc, &template, &str_args)) |out| {
        alloc.free(out);
        return true;
    } else |err| if (err != FmtError.FormatError) return true;
    return false;
}
