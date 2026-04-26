const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const fmt_mod = @import("fmt.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;

/// Evaluate `(let name expr)`: bind `name` in the current env to the
/// evaluated value of `expr`. Returns `.nil` since let is a side-effecting
/// statement, not a value-producing form.
pub fn evalLet(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    if (args.len != 2) return EvalError.ArityError;
    const name = args[0].asAtom() orelse return EvalError.InvalidForm;
    const value = try self.evalNode(args[1], env);
    try env.put(name, value);
    return .nil;
}

/// Evaluate `(if cond then else)`: short-circuits — only the matching
/// branch is evaluated, mirroring Lisp semantics so designers can guard
/// expensive sub-block calls behind compile-time flags.
pub fn evalIf(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    if (args.len != 3) return EvalError.ArityError;
    const cond = try self.evalNode(args[0], env);
    if (cond.isTruthy()) {
        return self.evalNode(args[1], env);
    } else {
        return self.evalNode(args[2], env);
    }
}

/// Evaluate `(cond (test1 expr1) … (else exprN))`: walks each clause in
/// order, returning the first matching expression's value. The `else`
/// keyword on a clause head matches unconditionally, like Scheme's `cond`.
pub fn evalCond(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    for (args) |clause| {
        const clause_children = clause.asList() orelse return EvalError.InvalidForm;
        if (clause_children.len != 2) return EvalError.InvalidForm;

        // Check for (else ...)
        if (clause_children[0].asAtom()) |name| {
            if (std.mem.eql(u8, name, "else")) {
                return self.evalNode(clause_children[1], env);
            }
        }

        const cond = try self.evalNode(clause_children[0], env);
        if (cond.isTruthy()) {
            return self.evalNode(clause_children[1], env);
        }
    }
    return .nil;
}

/// Evaluate `(fmt "template" args…)` and return the formatted string. The
/// template uses the `~V` / `~R` / `~C` / `~A` / `~S` directives from
/// `eval/fmt.zig` so module names can render computed voltages / resistances
/// without manually formatting the numbers.
pub fn evalFmt(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    if (args.len < 1) return EvalError.ArityError;
    const template_val = try self.evalNode(args[0], env);
    const template = template_val.asString() orelse return EvalError.TypeError;

    var fmt_args: std.ArrayListUnmanaged(Value) = .empty;
    defer fmt_args.deinit(self.allocator);
    for (args[1..]) |arg| {
        const v = try self.evalNode(arg, env);
        try fmt_args.append(self.allocator, v);
    }

    const result = fmt_mod.format(self.allocator, template, fmt_args.items) catch |err| switch (err) {
        error.OutOfMemory => return EvalError.OutOfMemory,
        error.FormatError => return EvalError.FormatError,
        error.TypeError => return EvalError.TypeError,
        error.NotEnoughArgs => return EvalError.NotEnoughArgs,
    };
    return .{ .string = result };
}

/// Evaluate `(assert cond "message")`: append a pass/fail entry to the
/// evaluator's assertions list. The build never aborts on failure — the
/// review page surfaces the failures so the designer can decide.
pub fn evalAssert(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    if (args.len != 2) return EvalError.ArityError;
    const cond = try self.evalNode(args[0], env);
    const msg_val = try self.evalNode(args[1], env);
    const msg = msg_val.asString() orelse return EvalError.TypeError;
    try self.assertions.append(self.allocator, .{
        .passed = cond.isTruthy(),
        .message = msg,
    });
    return .nil;
}

/// Evaluate `(assert-range value lo hi "label")` and record a pass/fail
/// assertion with a formatted message like `VOUT = 3.3000 (range 0.6-16.0)`.
/// Used by power-supply modules to verify computed Vout sits inside the
/// regulator's datasheet envelope.
pub fn evalAssertRange(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    if (args.len != 4) return EvalError.ArityError;
    const val = try self.evalNode(args[0], env);
    const min = try self.evalNode(args[1], env);
    const max = try self.evalNode(args[2], env);
    const label_val = try self.evalNode(args[3], env);

    const v = val.asNumber() orelse return EvalError.TypeError;
    const lo = min.asNumber() orelse return EvalError.TypeError;
    const hi = max.asNumber() orelse return EvalError.TypeError;
    const label = label_val.asString() orelse return EvalError.TypeError;

    const passed = v >= lo and v <= hi;

    // Build message
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "{s} = {d:.4} (range {d:.1}-{d:.1})", .{ label, v, lo, hi }) catch "assertion";
    const msg_copy = self.allocator.dupe(u8, msg) catch return EvalError.OutOfMemory;

    try self.assertions.append(self.allocator, .{
        .passed = passed,
        .message = msg_copy,
    });
    return .nil;
}
