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
        .e96 => eSeries(args, &E96),
        .e24 => eSeries(args, &E24),
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

// ── Standard resistor / capacitor E-series snapping ─────────────────────
// Snap an arbitrary value (e.g. a feedback resistor computed from a target
// voltage) to the nearest E96 (1%) or E24 (5%) decade value, so a module
// parameterised by `(vout X)` emits a buildable BOM part instead of an
// off-grid value like 400k. Decade is found by scaling into [1,10); the
// 10.0 top edge (= 1.0 of the next decade) is considered so 9.9 → 10.
const E96 = [_]f64{
    1.00, 1.02, 1.05, 1.07, 1.10, 1.13, 1.15, 1.18, 1.21, 1.24, 1.27, 1.30,
    1.33, 1.37, 1.40, 1.43, 1.47, 1.50, 1.54, 1.58, 1.62, 1.65, 1.69, 1.74,
    1.78, 1.82, 1.87, 1.91, 1.96, 2.00, 2.05, 2.10, 2.15, 2.21, 2.26, 2.32,
    2.37, 2.43, 2.49, 2.55, 2.61, 2.67, 2.74, 2.80, 2.87, 2.94, 3.01, 3.09,
    3.16, 3.24, 3.32, 3.40, 3.48, 3.57, 3.65, 3.74, 3.83, 3.92, 4.02, 4.12,
    4.22, 4.32, 4.42, 4.53, 4.64, 4.75, 4.87, 4.99, 5.11, 5.23, 5.36, 5.49,
    5.62, 5.76, 5.90, 6.04, 6.19, 6.34, 6.49, 6.65, 6.81, 6.98, 7.15, 7.32,
    7.50, 7.68, 7.87, 8.06, 8.25, 8.45, 8.66, 8.87, 9.09, 9.31, 9.53, 9.76,
};
const E24 = [_]f64{
    1.0, 1.1, 1.2, 1.3, 1.5, 1.6, 1.8, 2.0, 2.2, 2.4, 2.7, 3.0,
    3.3, 3.6, 3.9, 4.3, 4.7, 5.1, 5.6, 6.2, 6.8, 7.5, 8.2, 9.1,
};

fn eSeries(args: []const Value, series: []const f64) BuiltinError!Value {
    if (args.len != 1) return BuiltinError.ArityError;
    const x = args[0].asNumber() orelse return BuiltinError.TypeError;
    if (x <= 0) return .{ .number = x };
    var m = x;
    var decade: f64 = 1.0;
    while (m >= 10.0) {
        m /= 10.0;
        decade *= 10.0;
    }
    while (m < 1.0) {
        m *= 10.0;
        decade /= 10.0;
    }
    var best = series[0];
    var best_err = @abs(m - series[0]);
    for (series) |v| {
        const e = @abs(m - v);
        if (e < best_err) {
            best_err = e;
            best = v;
        }
    }
    if (@abs(m - 10.0) < best_err) return .{ .number = decade * 10.0 };
    return .{ .number = decade * best };
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

// spec: eval/builtins - Snaps a value to the nearest standard E-series resistor value
test "e-series snapping" {
    const a = [_]Value{.{ .number = 400000.0 }};
    try std.testing.expectApproxEqAbs(@as(f64, 402000.0), (try evalBuiltin("e96", &a)).asNumber().?, 1.0);
    const c = [_]Value{.{ .number = 33000.0 }};
    try std.testing.expectApproxEqAbs(@as(f64, 33000.0), (try evalBuiltin("e24", &c)).asNumber().?, 1.0);
    const z = [_]Value{.{ .number = 0.0 }};
    try std.testing.expectEqual(@as(f64, 0.0), (try evalBuiltin("e96", &z)).asNumber().?);
}
