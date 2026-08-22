//! Non-eager evaluator forms: lexical bindings and loops, conditionals,
//! assertions, and string formatting with source-located diagnostics.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const numeric = @import("../numeric.zig");
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
pub fn checkArity(self: *Evaluator, sf: forms.SpecialForm, args: []const Node) EvalError!void {
    return checkAritySpan(self, sf, args, ast.Span.zero);
}

/// `checkArity` with an explicit head span used for the zero-args case, so a
/// diagnostic like `(import …) expects at least 1 argument` points at the
/// form's opening paren instead of file position 1:1. Handlers that hold the
/// form head node (import/defmodule/design-block) pass its span here.
pub fn checkAritySpan(self: *Evaluator, sf: forms.SpecialForm, args: []const Node, head_span: ast.Span) EvalError!void {
    const schema = forms.schemaFor(sf) orelse return;
    if (forms.validateArity(schema, args.len) == null) return;
    const span = if (args.len > 0) args[0].span else head_span;
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

/// Parsed shape of `(repeat name start end body…)`. The bounds are evaluated
/// once in the enclosing environment; each body evaluation gets a child scope
/// with `name` bound to the current integer.
pub const RepeatSpec = struct {
    name: []const u8,
    start: i64,
    end: i64,
    body: []const Node,

    /// Return a fresh iterator positioned at this repeat's inclusive start.
    pub fn iterator(self: RepeatSpec) RepeatIterator {
        return .{ .next_value = self.start, .end = self.end };
    }
};

/// Stateful inclusive iterator used by both expression and design-body repeat.
pub const RepeatIterator = struct {
    next_value: i64,
    end: i64,
    finished: bool = false,

    /// Inclusive in either direction: `(repeat i 3 1 …)` yields 3, 2, 1.
    pub fn next(self: *RepeatIterator) ?i64 {
        if (self.finished) return null;
        const value = self.next_value;
        if (value == self.end) {
            self.finished = true;
        } else if (value < self.end) {
            self.next_value += 1;
        } else {
            self.next_value -= 1;
        }
        return value;
    }
};

/// A repeat is intentionally bounded: design files are accepted by the HTTP
/// server, so a typo such as `1 1000000000` must fail before allocating or
/// evaluating a billion copies of the body.
const max_repeat_iterations: usize = 4096;

/// Validate and evaluate the binding + range portion of `(repeat …)`. Kept
/// public so design-block materialization can iterate scope forms (instance,
/// sub-block, net, …) through its normal builders while sharing the exact same
/// lexical/range semantics as expression-level repeat.
pub fn parseRepeat(self: *Evaluator, args: []const Node, env: *Env) EvalError!RepeatSpec {
    try checkArity(self, .repeat, args);
    const name = args[0].asAtom() orelse {
        self.setError(args[0].span, "(repeat …) first argument must be a bare name, e.g. (repeat ch 1 8 …)");
        return EvalError.InvalidForm;
    };
    const start = try repeatBound(self, args[1], env, "start");
    const end = try repeatBound(self, args[2], env, "end");
    const count_f = @abs(@as(f64, @floatFromInt(end)) - @as(f64, @floatFromInt(start))) + 1.0;
    if (count_f > @as(f64, @floatFromInt(max_repeat_iterations))) {
        self.setErrorFmt(args[2].span, "(repeat …) range contains more than {d} iterations", .{max_repeat_iterations});
        return EvalError.InvalidForm;
    }
    return .{ .name = name, .start = start, .end = end, .body = args[3..] };
}

fn repeatBound(self: *Evaluator, node: Node, env: *Env, label: []const u8) EvalError!i64 {
    const value = try self.evalNode(node, env);
    const number = value.asNumber() orelse {
        self.setErrorFmt(node.span, "(repeat …) {s} bound must be an integer", .{label});
        return EvalError.TypeError;
    };
    if (!std.math.isFinite(number) or @trunc(number) != number) {
        self.setErrorFmt(node.span, "(repeat …) {s} bound must be a finite integer", .{label});
        return EvalError.InvalidForm;
    }
    return numeric.checkedInt(i64, number) orelse {
        self.setErrorFmt(node.span, "(repeat …) {s} bound is outside the supported integer range", .{label});
        return EvalError.InvalidForm;
    };
}

/// Evaluate an expression-level repeat and return the final body value (or
/// `.nil` only when a future range policy permits an empty range). A new child
/// environment per iteration makes the loop variable and body-local lets
/// lexical: neither leaks outward or sideways into the next iteration.
pub fn evalRepeat(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    const spec = try parseRepeat(self, args, env);
    var result: Value = .nil;
    var it = spec.iterator();
    while (it.next()) |index| {
        var loop_env = Env.init(self.allocator, env);
        defer loop_env.deinit();
        try loop_env.put(spec.name, .{ .number = @floatFromInt(index) });
        for (spec.body) |form| result = try self.evalNode(form, &loop_env);
    }
    return result;
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

    var fmt_args: std.ArrayList(Value) = .empty;
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
