const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const fmt_mod = @import("fmt.zig");
const forms = @import("forms.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;

/// Verify an argument count matches the schema for `sf`. Returns
/// `EvalError.ArityError` when the count is out of bounds. Centralises
/// what was previously a hand-written `if (args.len != N) return …`
/// at the top of every special-form handler. When the count is wrong,
/// stashes a diagnostic on the evaluator pointing at the first arg
/// (or the form itself, when there are no args) so the caller can
/// render `let takes 2 args at sexp:42:7`.
fn checkArity(self: *Evaluator, sf: forms.SpecialForm, args: []const Node) EvalError!void {
    const schema = forms.schemaFor(sf) orelse return;
    if (forms.validateArity(schema, args.len) == null) return;
    const span = if (args.len > 0) args[0].span else ast.Span.zero;
    const name = sf.sourceName();
    if (schema.max_args) |max| {
        if (max == schema.min_args) {
            self.setErrorFmt(span, "({s} …) expects {d} argument(s), got {d}", .{ name, schema.min_args, args.len });
        } else {
            self.setErrorFmt(span, "({s} …) expects {d}–{d} arguments, got {d}", .{ name, schema.min_args, max, args.len });
        }
    } else {
        self.setErrorFmt(span, "({s} …) expects at least {d} argument(s), got {d}", .{ name, schema.min_args, args.len });
    }
    return EvalError.ArityError;
}

/// Evaluate `(let name expr)`: bind `name` in the current env to the
/// evaluated value of `expr`. Returns `.nil` since let is a side-effecting
/// statement, not a value-producing form.
pub fn evalLet(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    try checkArity(self, .let, args);
    const name = args[0].asAtom() orelse {
        self.setError(args[0].span, "(let …) first argument must be a bare name, e.g. (let vout 3.3)");
        return EvalError.InvalidForm;
    };
    const value = try self.evalNode(args[1], env);
    try env.put(name, value);
    return .nil;
}

/// Evaluate `(if cond then else)`: short-circuits — only the matching
/// branch is evaluated, mirroring Lisp semantics so designers can guard
/// expensive sub-block calls behind compile-time flags.
pub fn evalIf(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    try checkArity(self, .if_, args);
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
        const clause_children = clause.asList() orelse {
            self.setError(clause.span, "(cond …) clauses must be (test expr) lists");
            return EvalError.InvalidForm;
        };
        if (clause_children.len != 2) {
            self.setError(clause.span, "(cond …) clauses must be (test expr) lists");
            return EvalError.InvalidForm;
        }

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
    try checkArity(self, .fmt_, args);
    const template_val = try self.evalNode(args[0], env);
    const template = template_val.asString() orelse {
        self.setError(args[0].span, "(fmt …) template must be a string");
        return EvalError.TypeError;
    };

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
    try checkArity(self, .assert_, args);
    const cond = try self.evalNode(args[0], env);
    const msg_val = try self.evalNode(args[1], env);
    const msg = msg_val.asString() orelse {
        self.setError(args[1].span, "(assert …) message must be a string");
        return EvalError.TypeError;
    };
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
    try checkArity(self, .assert_range, args);
    const val = try self.evalNode(args[0], env);
    const min = try self.evalNode(args[1], env);
    const max = try self.evalNode(args[2], env);
    const label_val = try self.evalNode(args[3], env);

    const v = val.asNumber() orelse {
        self.setError(args[0].span, "(assert-range …) value must be a number");
        return EvalError.TypeError;
    };
    const lo = min.asNumber() orelse {
        self.setError(args[1].span, "(assert-range …) lower bound must be a number");
        return EvalError.TypeError;
    };
    const hi = max.asNumber() orelse {
        self.setError(args[2].span, "(assert-range …) upper bound must be a number");
        return EvalError.TypeError;
    };
    const label = label_val.asString() orelse {
        self.setError(args[3].span, "(assert-range …) label must be a string");
        return EvalError.TypeError;
    };

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
