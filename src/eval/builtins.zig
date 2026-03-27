const std = @import("std");
const env_mod = @import("env.zig");
const Value = env_mod.Value;

pub const BuiltinError = error{
    TypeError,
    ArityError,
    DivisionByZero,
};

/// Evaluate an arithmetic or logic builtin given the operator name and evaluated arguments.
pub fn evalBuiltin(op: []const u8, args: []const Value) BuiltinError!Value {
    // Arithmetic: +, -, *, /, %
    if (std.mem.eql(u8, op, "+")) return arithmetic(args, .add);
    if (std.mem.eql(u8, op, "-")) return arithmetic(args, .sub);
    if (std.mem.eql(u8, op, "*")) return arithmetic(args, .mul);
    if (std.mem.eql(u8, op, "/")) return arithmetic(args, .div);
    if (std.mem.eql(u8, op, "%")) return arithmetic(args, .mod);

    // Comparison: >, >=, <, <=, ==, !=
    if (std.mem.eql(u8, op, ">")) return comparison(args, .gt);
    if (std.mem.eql(u8, op, ">=")) return comparison(args, .gte);
    if (std.mem.eql(u8, op, "<")) return comparison(args, .lt);
    if (std.mem.eql(u8, op, "<=")) return comparison(args, .lte);
    if (std.mem.eql(u8, op, "==")) return equality(args, true);
    if (std.mem.eql(u8, op, "!=")) return equality(args, false);

    // Logic: and, or, not
    if (std.mem.eql(u8, op, "and")) return logicAnd(args);
    if (std.mem.eql(u8, op, "or")) return logicOr(args);
    if (std.mem.eql(u8, op, "not")) return logicNot(args);

    return BuiltinError.TypeError;
}

const ArithOp = enum { add, sub, mul, div, mod };

fn arithmetic(args: []const Value, op: ArithOp) BuiltinError!Value {
    if (args.len != 2) return BuiltinError.ArityError;
    const a = args[0].asNumber() orelse return BuiltinError.TypeError;
    const b = args[1].asNumber() orelse return BuiltinError.TypeError;
    const result = switch (op) {
        .add => a + b,
        .sub => a - b,
        .mul => a * b,
        .div => blk: {
            if (b == 0.0) return BuiltinError.DivisionByZero;
            break :blk a / b;
        },
        .mod => blk: {
            if (b == 0.0) return BuiltinError.DivisionByZero;
            break :blk @mod(a, b);
        },
    };
    return .{ .number = result };
}

const CmpOp = enum { gt, gte, lt, lte };

fn comparison(args: []const Value, op: CmpOp) BuiltinError!Value {
    if (args.len != 2) return BuiltinError.ArityError;
    const a = args[0].asNumber() orelse return BuiltinError.TypeError;
    const b = args[1].asNumber() orelse return BuiltinError.TypeError;
    const result = switch (op) {
        .gt => a > b,
        .gte => a >= b,
        .lt => a < b,
        .lte => a <= b,
    };
    return .{ .boolean = result };
}

fn equality(args: []const Value, expect_equal: bool) BuiltinError!Value {
    if (args.len != 2) return BuiltinError.ArityError;
    // Support number-number and string-string equality
    if (args[0].asNumber()) |a| {
        const b = args[1].asNumber() orelse return BuiltinError.TypeError;
        const eq = a == b;
        return .{ .boolean = if (expect_equal) eq else !eq };
    }
    if (args[0].asString()) |a| {
        const b = args[1].asString() orelse return BuiltinError.TypeError;
        const eq = std.mem.eql(u8, a, b);
        return .{ .boolean = if (expect_equal) eq else !eq };
    }
    return BuiltinError.TypeError;
}

fn logicAnd(args: []const Value) BuiltinError!Value {
    if (args.len != 2) return BuiltinError.ArityError;
    return .{ .boolean = args[0].isTruthy() and args[1].isTruthy() };
}

fn logicOr(args: []const Value) BuiltinError!Value {
    if (args.len != 2) return BuiltinError.ArityError;
    return .{ .boolean = args[0].isTruthy() or args[1].isTruthy() };
}

fn logicNot(args: []const Value) BuiltinError!Value {
    if (args.len != 1) return BuiltinError.ArityError;
    return .{ .boolean = !args[0].isTruthy() };
}

/// Check if a name is a builtin operator.
pub fn isBuiltin(name: []const u8) bool {
    const builtins = [_][]const u8{
        "+", "-", "*", "/", "%",
        ">", ">=", "<", "<=", "==", "!=",
        "and", "or", "not",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "arithmetic operations" {
    const args2 = [_]Value{ .{ .number = 10.0 }, .{ .number = 3.0 } };
    try std.testing.expectEqual(@as(f64, 13.0), (try evalBuiltin("+", &args2)).asNumber().?);
    try std.testing.expectEqual(@as(f64, 7.0), (try evalBuiltin("-", &args2)).asNumber().?);
    try std.testing.expectEqual(@as(f64, 30.0), (try evalBuiltin("*", &args2)).asNumber().?);
}

test "voltage divider formula" {
    // VOUT = 0.6 * (1 + 220k/47k) = 0.6 * (1 + 4.68085...) = 0.6 * 5.68085... = 3.4085...
    const div_args = [_]Value{ .{ .number = 220000.0 }, .{ .number = 47000.0 } };
    const ratio = try evalBuiltin("/", &div_args);

    const add_args = [_]Value{ .{ .number = 1.0 }, ratio };
    const sum = try evalBuiltin("+", &add_args);

    const mul_args = [_]Value{ .{ .number = 0.6 }, sum };
    const vout = try evalBuiltin("*", &mul_args);

    try std.testing.expectApproxEqAbs(@as(f64, 3.4085), vout.asNumber().?, 0.001);
}

test "comparison operations" {
    const args = [_]Value{ .{ .number = 5.0 }, .{ .number = 3.0 } };
    try std.testing.expectEqual(true, (try evalBuiltin(">", &args)).asBool().?);
    try std.testing.expectEqual(false, (try evalBuiltin("<", &args)).asBool().?);
    try std.testing.expectEqual(true, (try evalBuiltin(">=", &args)).asBool().?);
}

test "logic operations" {
    const t = Value{ .boolean = true };
    const f = Value{ .boolean = false };
    const and_args = [_]Value{ t, f };
    try std.testing.expectEqual(false, (try evalBuiltin("and", &and_args)).asBool().?);
    const or_args = [_]Value{ t, f };
    try std.testing.expectEqual(true, (try evalBuiltin("or", &or_args)).asBool().?);
    const not_args = [_]Value{t};
    try std.testing.expectEqual(false, (try evalBuiltin("not", &not_args)).asBool().?);
}
