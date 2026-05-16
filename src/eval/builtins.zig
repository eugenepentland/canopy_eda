const std = @import("std");
const env_mod = @import("env.zig");
const forms = @import("forms.zig");
const Value = env_mod.Value;
const Builtin = forms.Builtin;

pub const BuiltinError = error{
    TypeError,
    ArityError,
    DivisionByZero,
};

// ── Constants ─────────────────────────────────────────────────────
const ZERO_DIVISOR: f64 = 0.0;

/// Evaluate a builtin given its enum tag (preferred path — the evaluator
/// has already resolved the head atom via `Builtin.fromAtom`).
pub fn evalBuiltinOp(op: Builtin, args: []const Value) BuiltinError!Value {
    return switch (op) {
        .add => arithmetic(args, .add),
        .sub => arithmetic(args, .sub),
        .mul => arithmetic(args, .mul),
        .div => arithmetic(args, .div),
        .mod => arithmetic(args, .mod),
        .gt => comparison(args, .gt),
        .gte => comparison(args, .gte),
        .lt => comparison(args, .lt),
        .lte => comparison(args, .lte),
        .eq => equality(args, true),
        .neq => equality(args, false),
        .and_ => logicAnd(args),
        .or_ => logicOr(args),
        .not_ => logicNot(args),
    };
}

/// Name-based dispatch — kept private for the tests in this file. The
/// evaluator goes straight to `evalBuiltinOp` via `Builtin.fromAtom`.
fn evalBuiltin(op: []const u8, args: []const Value) BuiltinError!Value {
    const tag = Builtin.fromAtom(op) orelse return BuiltinError.TypeError;
    return evalBuiltinOp(tag, args);
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
            if (b == ZERO_DIVISOR) return BuiltinError.DivisionByZero;
            break :blk a / b;
        },
        .mod => blk: {
            if (b == ZERO_DIVISOR) return BuiltinError.DivisionByZero;
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

// ── Tests ──────────────────────────────────────────────────────────────

// spec: eval/builtins - Evaluates arithmetic operations on numeric values
test "arithmetic operations" {
    const args2 = [_]Value{ .{ .number = 10.0 }, .{ .number = 3.0 } };
    try std.testing.expectEqual(@as(f64, 13.0), (try evalBuiltin("+", &args2)).asNumber().?);
    try std.testing.expectEqual(@as(f64, 7.0), (try evalBuiltin("-", &args2)).asNumber().?);
    try std.testing.expectEqual(@as(f64, 30.0), (try evalBuiltin("*", &args2)).asNumber().?);
}

// spec: eval/builtins - Evaluates a voltage divider formula combining arithmetic operators
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

// spec: eval/builtins - Evaluates comparison operations returning boolean results
test "comparison operations" {
    const args = [_]Value{ .{ .number = 5.0 }, .{ .number = 3.0 } };
    try std.testing.expectEqual(true, (try evalBuiltin(">", &args)).asBool().?);
    try std.testing.expectEqual(false, (try evalBuiltin("<", &args)).asBool().?);
    try std.testing.expectEqual(true, (try evalBuiltin(">=", &args)).asBool().?);
}

// spec: eval/builtins - Evaluates logic operations on boolean values
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
