const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const electrical_mod = @import("electrical.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;
const ComponentData = Evaluator.ComponentData;
const BusDef = Evaluator.BusDef;

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;
const ModuleDef = env_mod.ModuleDef;

// ── Constants ─────────────────────────────────────────────────────
const FOOTPRINT_FORM = "footprint";

/// Standard passive families auto-imported into every design and module
/// before their body evaluates. The list mirrors the inventory in
/// projects/designs/lib/components/ — keep both in sync when adding a new
/// 04xx/06xx package family.
const PASSIVES_PRELUDE = [_][]const u8{
    "cap-0201", "cap-0402", "cap-0603",     "cap-0805",
    "res-0201", "res-0402", "res-0603",     "res-0805",
    "ind-0201", "ind-0402", "ind-0603",     "ind-0805",
    "ind-1616", "ind-2016", "ferrite-0402", "led-0402",
};

/// Pre-import the standard passive families so design and module files
/// don't need to list them in `(import …)` headers. Idempotent: the
/// `passives_prelude_loaded` flag short-circuits subsequent calls, which
/// also guards against recursion if a module load triggers prelude load
/// for a name that happens to itself be a module. Failures (missing
/// library files) are intentionally swallowed — projects that haven't
/// stocked every package size still build, and the resolver later raises
/// `UnboundVariable` at the actual use site if a referenced part is
/// genuinely missing.
pub fn loadPassivesPrelude(self: *Evaluator, env: *Env) void {
    if (self.passives_prelude_loaded) return;
    self.passives_prelude_loaded = true;
    for (PASSIVES_PRELUDE) |name| {
        resolveImport(self, name, env) catch continue;
    }
}

/// Evaluate `(import name1 name2 …)`, resolving each name against the
/// project's `lib/components/` and `lib/modules/` folders (project_dir then
/// lib_dir fallback) and registering the resulting component or module in
/// the caller's environment.
pub fn evalImport(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    // Support multi-import: (import a b c ...)
    if (args.len < 1) return EvalError.ArityError;
    for (args) |arg| {
        const name = arg.asAtom() orelse return EvalError.InvalidForm;
        try resolveImport(self, name, env);
    }
    return .nil;
}

/// Locate `name` on disk and load it as the right kind of file. Searches
/// `lib/components/` then `lib/modules/`, under both the project_dir and
/// the shared lib_dir. Components get cached in `component_cache`; modules
/// are evaluated against a heap-owned env and bound into the caller's env.
pub fn resolveImport(self: *Evaluator, name: []const u8, env: *Env) EvalError!void {
    // Already loaded?
    if (self.component_cache.contains(name)) return;
    if (env.get(name) != null) return;

    // Search path: components first, then modules.
    // Search project_dir first, then lib_dir (shared library fallback).
    const search_prefixes = [_][]const u8{
        "lib/components/",
        "lib/modules/",
    };
    const search_roots = if (std.mem.eql(u8, self.project_dir, self.lib_dir))
        &[_][]const u8{self.project_dir}
    else
        &[_][]const u8{ self.project_dir, self.lib_dir };

    for (search_roots) |root| {
        for (search_prefixes) |prefix| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}.sexp", .{ root, prefix, name }) catch return EvalError.OutOfMemory;
            defer self.allocator.free(path);

            // Note: don't free file_content — AST nodes reference slices into it
            const file_content = infra_fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch continue;

            const nodes = parser_mod.parse(self.allocator, file_content) catch return EvalError.ImportError;

            // Determine what kind of file this is
            if (nodes.len > 0) {
                if (nodes[0].isForm("component")) {
                    try loadComponent(self, name, nodes[0]);
                    return;
                }
                if (nodes[0].isForm("component-family")) {
                    try loadComponentFamily(self, name, nodes[0]);
                    return;
                }
                // Module file — evaluate in a heap-allocated env (must outlive module def)
                const mod_env = self.allocator.create(Env) catch return EvalError.OutOfMemory;
                mod_env.* = Env.init(self.allocator, null);
                loadPassivesPrelude(self, mod_env);
                _ = self.evalNodes(nodes, mod_env) catch return EvalError.ImportError;
                // The defmodule should have been registered; copy module binding to caller env
                if (mod_env.get(name)) |v| {
                    try env.put(name, v);
                    return;
                }
            }
        }
    }
    return EvalError.ImportError;
}

/// Parse a `(component …)` library file into a `ComponentData` cache entry,
/// extracting the symbol/footprint/pinout names, properties, declared buses,
/// datasheet PDFs, library `(requirement …)` rules, and the
/// `(ignore-requirements)` opt-out flag.
pub fn loadComponent(self: *Evaluator, name: []const u8, node: Node) EvalError!void {
    const children = node.asList() orelse return EvalError.InvalidForm;
    var symbol_name: []const u8 = "";
    var footprint_name: []const u8 = "";
    var pinout_name: []const u8 = "";

    // Known structural fields (not properties)
    const skip_fields = [_][]const u8{
        "symbol",              FOOTPRINT_FORM,
        "pinout",              "component",
        "parameter",           "component-family",
        "bus",                 "note",
        "datasheet",           "requirement",
        "ignore-requirements", "electrical",
    };

    var props: std.ArrayListUnmanaged(env_mod.Property) = .empty;
    var buses: std.ArrayListUnmanaged(BusDef) = .empty;
    var datasheets: std.ArrayListUnmanaged([]const u8) = .empty;
    var requirements: std.ArrayListUnmanaged(env_mod.Requirement) = .empty;
    var electrical: std.ArrayListUnmanaged(env_mod.ElectricalDecl) = .empty;
    var requirements_ignored = false;

    for (children[1..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len >= 1) {
            // Zero-arg marker forms have to be checked before the cl.len < 2
            // gate below — `(ignore-requirements)` has no body.
            if (cl[0].asAtom()) |head| {
                if (std.mem.eql(u8, head, "ignore-requirements")) {
                    requirements_ignored = true;
                    continue;
                }
            }
        }
        if (cl.len < 2) continue;
        const field = cl[0].asAtom() orelse continue;

        if (std.mem.eql(u8, field, "description")) {
            // Surface the library description on every instance that uses
            // this component so downstream renderers (schematic overview,
            // review doc, BOM) can show it without re-reading lib files.
            const val = cl[1].asText() orelse continue;
            props.append(self.allocator, .{ .key = "description", .value = val }) catch continue;
        } else if (std.mem.eql(u8, field, "symbol")) {
            symbol_name = cl[1].asText() orelse "";
        } else if (std.mem.eql(u8, field, FOOTPRINT_FORM)) {
            footprint_name = cl[1].asText() orelse "";
        } else if (std.mem.eql(u8, field, "pinout")) {
            pinout_name = cl[1].asText() orelse "";
        } else if (std.mem.eql(u8, field, "datasheet")) {
            const ds = cl[1].asText() orelse continue;
            datasheets.append(self.allocator, ds) catch continue;
        } else if (std.mem.eql(u8, field, "requirement")) {
            const text = cl[1].asString() orelse continue;
            var ref: ?env_mod.NoteRef = null;
            var chk: ?env_mod.Check = null;
            var explicit_id: []const u8 = "";
            for (cl[2..]) |extra| {
                if (env_mod.parseNoteRef(extra)) |r| {
                    ref = r;
                } else if (env_mod.parseCheck(extra)) |c| {
                    chk = c;
                } else if (extra.asList()) |sub| {
                    if (sub.len >= 2) {
                        if (sub[0].asAtom()) |sub_head| {
                            if (std.mem.eql(u8, sub_head, "id")) {
                                if (sub[1].asText()) |id_str| {
                                    explicit_id = id_str;
                                }
                            }
                        }
                    }
                }
            }
            const rid: []const u8 = if (explicit_id.len > 0)
                explicit_id
            else
                env_mod.requirementIdForText(self.allocator, text) catch "";
            requirements.append(self.allocator, .{ .text = text, .ref = ref, .check = chk, .id = rid }) catch continue;
        } else if (std.mem.eql(u8, field, "electrical")) {
            if (electrical_mod.parse(cl)) |d| {
                electrical.append(self.allocator, d) catch continue;
            }
        } else if (std.mem.eql(u8, field, "bus")) {
            // (bus "name" pin1 pin2 pin3 ...)
            const bus_name = cl[1].asText() orelse continue;
            var bus_pins: std.ArrayListUnmanaged([]const u8) = .empty;
            for (cl[2..]) |pin_node| {
                const pin_name = pin_node.asText() orelse continue;
                bus_pins.append(self.allocator, pin_name) catch continue;
            }
            buses.append(self.allocator, .{
                .name = bus_name,
                .pins = bus_pins.toOwnedSlice(self.allocator) catch &.{},
            }) catch continue;
        } else if (!env_mod.containsString(&skip_fields, field)) {
            // Unknown, non-structural field -- treat as inline property.
            const val = cl[1].asText() orelse continue;
            props.append(self.allocator, .{ .key = field, .value = val }) catch continue;
        }
    }

    try self.component_cache.put(self.allocator, name, .{
        .name = name,
        .symbol_name = symbol_name,
        .footprint_name = footprint_name,
        .pinout_name = pinout_name,
        .properties = props.toOwnedSlice(self.allocator) catch &.{},
        .buses = buses.toOwnedSlice(self.allocator) catch &.{},
        .is_family = false,
        .param_type = "",
        .datasheets = datasheets.toOwnedSlice(self.allocator) catch &.{},
        .requirements = requirements.toOwnedSlice(self.allocator) catch &.{},
        .requirements_ignored = requirements_ignored,
        .electrical = electrical.toOwnedSlice(self.allocator) catch &.{},
    });
}

/// Parse a `(component-family …)` library file into a `ComponentData` entry
/// flagged `is_family = true`. Families are parameterized: a call site like
/// `(cap "100nF")` instantiates the family with the value as its parameter.
pub fn loadComponentFamily(self: *Evaluator, name: []const u8, node: Node) EvalError!void {
    const children = node.asList() orelse return EvalError.InvalidForm;
    var symbol_name: []const u8 = "";
    var footprint_name: []const u8 = "";
    var param_type: []const u8 = "";

    for (children[1..]) |child| {
        if (child.isForm("symbol")) {
            const cl = child.asList().?;
            if (cl.len >= 2) symbol_name = cl[1].asText() orelse "";
        }
        if (child.isForm(FOOTPRINT_FORM)) {
            const cl = child.asList().?;
            if (cl.len >= 2) footprint_name = cl[1].asText() orelse "";
        }
        if (child.isForm("parameter")) {
            const cl = child.asList().?;
            if (cl.len >= 3) param_type = cl[2].asText() orelse "";
        }
    }

    try self.component_cache.put(self.allocator, name, .{
        .name = name,
        .symbol_name = symbol_name,
        .footprint_name = footprint_name,
        .is_family = true,
        .param_type = param_type,
    });
}

/// Evaluate `(defmodule name (params…) "doc?" body…)` and bind the resulting
/// `ModuleDef` in the current env. The body nodes are stored verbatim for
/// later evaluation when the module is called; the param list is captured
/// alongside the module file's import scope so calls resolve correctly.
pub fn evalDefmodule(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    // (defmodule name (params...) docstring? body...)
    if (args.len < 2) return EvalError.ArityError;
    const name = args[0].asAtom() orelse return EvalError.InvalidForm;
    const params_node = args[1].asList() orelse return EvalError.InvalidForm;

    var params: std.ArrayListUnmanaged([]const u8) = .empty;
    defer params.deinit(self.allocator);
    for (params_node) |p| {
        const pname = p.asAtom() orelse return EvalError.InvalidForm;
        try params.append(self.allocator, pname);
    }

    // Skip docstring if present
    var body_start: usize = 2;
    if (args.len > 2) {
        if (args[2].asString() != null) body_start = 3;
    }

    const param_slice = self.allocator.dupe([]const u8, params.items) catch return EvalError.OutOfMemory;
    const mod = ModuleDef{
        .name = name,
        .params = param_slice,
        .body = args[body_start..],
        .imports = env,
    };

    try env.put(name, .{ .module = mod });
    return .nil;
}

/// Index of the declared parameter a call arg names, when the arg uses the
/// named form `(param expr)` — a 2-element list whose head atom matches one
/// of the module's parameter names. Anything else (including 2-element lists
/// like `(cap-0402 "100nF")` whose head is not a param) is a positional
/// expression and returns null.
fn namedParamIndex(mod: ModuleDef, arg: Node) ?usize {
    const pair = arg.asList() orelse return null;
    if (pair.len != 2) return null;
    const name = pair[0].asAtom() orelse return null;
    for (mod.params, 0..) |param, i| {
        if (std.mem.eql(u8, param, name)) return i;
    }
    return null;
}

/// Record a formatted diagnostic on the evaluator. The message is allocated
/// from the evaluator's allocator and intentionally never freed (project
/// memory convention — diagnostics outlive the eval call).
fn setErrorFmt(self: *Evaluator, span: ast.Span, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
    self.setError(span, msg);
}

/// Call a module: bind each call-site argument — positional in declaration
/// order, or named via `(param expr)` — into a fresh child scope rooted at
/// the module file's import env, then run the module body. Positional args
/// may not follow a named arg; duplicate and missing bindings are
/// diagnosed with the parameter names. Returns the last body expression's
/// value — typically a `(design-block …)`.
pub fn callModule(self: *Evaluator, mod: ModuleDef, call_args: []const Node, call_span: ast.Span, caller_env: *Env) EvalError!Value {
    const bound = self.allocator.alloc(?Value, mod.params.len) catch return EvalError.OutOfMemory;
    defer self.allocator.free(bound);
    for (bound) |*b| b.* = null;

    var pos_idx: usize = 0;
    var seen_named = false;
    for (call_args) |arg| {
        if (namedParamIndex(mod, arg)) |pi| {
            if (bound[pi] != null) {
                setErrorFmt(self, arg.span, "parameter '{s}' bound twice in call to module '{s}'", .{ mod.params[pi], mod.name });
                return EvalError.InvalidForm;
            }
            const pair = arg.asList().?;
            bound[pi] = try self.evalNode(pair[1], caller_env);
            seen_named = true;
            continue;
        }
        if (seen_named) {
            setErrorFmt(self, arg.span, "positional argument after named argument in call to module '{s}'", .{mod.name});
            return EvalError.InvalidForm;
        }
        if (pos_idx >= mod.params.len) {
            setErrorFmt(self, arg.span, "module '{s}' expects {d} argument(s), got {d}", .{ mod.name, mod.params.len, call_args.len });
            return EvalError.ArityError;
        }
        bound[pos_idx] = try self.evalNode(arg, caller_env);
        pos_idx += 1;
    }

    try checkMissingParams(self, mod, bound, call_span);

    // Create module scope with parameter bindings
    var mod_env = Env.init(self.allocator, mod.imports);
    defer mod_env.deinit();
    for (mod.params, 0..) |param, i| {
        try mod_env.put(param, bound[i].?);
    }

    // Evaluate module body
    return self.evalNodes(mod.body, &mod_env);
}

/// Diagnose any parameter left unbound after the call args are processed:
/// `module 'tpsm84338' missing argument(s): rled`.
fn checkMissingParams(self: *Evaluator, mod: ModuleDef, bound: []const ?Value, call_span: ast.Span) EvalError!void {
    var missing: std.ArrayListUnmanaged(u8) = .empty;
    defer missing.deinit(self.allocator);
    for (mod.params, 0..) |param, i| {
        if (bound[i] != null) continue;
        if (missing.items.len > 0) try missing.appendSlice(self.allocator, ", ");
        try missing.appendSlice(self.allocator, param);
    }
    if (missing.items.len == 0) return;
    setErrorFmt(self, call_span, "module '{s}' missing argument(s): {s}", .{ mod.name, missing.items });
    return EvalError.ArityError;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Evaluate `source` (defmodule + call) with a fresh evaluator, returning
/// the final value or the error. `eval_out` receives the evaluator so the
/// test can inspect `last_error`. Callers pass page_allocator: defmodule's
/// captured param slice and diagnostic messages are intentionally never freed.
fn evalModuleSource(alloc: std.mem.Allocator, eval_out: *Evaluator, source: []const u8) EvalError!Value {
    eval_out.* = Evaluator.init(alloc, ".");
    var env = Env.init(alloc, null);
    defer env.deinit();
    const nodes = parser_mod.parse(alloc, source) catch return EvalError.ImportError;
    return eval_out.evalNodes(nodes, &env);
}

// spec: eval/modules - Module calls bind purely positional arguments in declaration order
test "callModule positional arguments" {
    var eval: Evaluator = undefined;
    const v = try evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a b) (- a b)) (m 10 4)");
    try testing.expectEqual(@as(f64, 6.0), v.asNumber().?);
}

// spec: eval/modules - Module calls accept named (param expr) arguments in any order
test "callModule named arguments" {
    var eval: Evaluator = undefined;
    const v = try evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a b) (- a b)) (m (b 4) (a 10))");
    try testing.expectEqual(@as(f64, 6.0), v.asNumber().?);
}

// spec: eval/modules - Module calls mix leading positional with trailing named arguments
test "callModule mixed positional then named" {
    var eval: Evaluator = undefined;
    const v = try evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a b c) (- (- a b) c)) (m 10 (c 1) (b 4))");
    try testing.expectEqual(@as(f64, 5.0), v.asNumber().?);
}

// spec: eval/modules - A 2-list whose head is not a declared param stays a positional expression
test "callModule non-param 2-list evaluates positionally" {
    var eval: Evaluator = undefined;
    // (fmt "hi") is a 2-element list with an atom head that matches no
    // param — it must evaluate as an expression, not be rejected as a
    // named arg or misparsed into a binding.
    const v = try evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a) a) (m (fmt \"hi\"))");
    try testing.expectEqualStrings("hi", v.asString().?);
}

// spec: eval/modules - Binding the same module parameter twice is diagnosed by name
test "callModule duplicate binding errors" {
    var eval: Evaluator = undefined;
    const r = evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a b) (- a b)) (m 10 (a 3))");
    try testing.expectError(EvalError.InvalidForm, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "parameter 'a' bound twice") != null);
}

// spec: eval/modules - A positional argument after a named argument is rejected
test "callModule positional after named errors" {
    var eval: Evaluator = undefined;
    const r = evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a b) (- a b)) (m (a 10) 4)");
    try testing.expectError(EvalError.InvalidForm, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "positional argument after named argument") != null);
}

// spec: eval/modules - Unbound module parameters are diagnosed by name at the call site
test "callModule missing arguments errors" {
    var eval: Evaluator = undefined;
    const r = evalModuleSource(std.heap.page_allocator, &eval, "(defmodule tps (rfbt rfbb rled) (+ rfbt rfbb)) (tps 220000)");
    try testing.expectError(EvalError.ArityError, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "module 'tps' missing argument(s): rfbb, rled") != null);
}

// spec: eval/modules - Surplus positional arguments are diagnosed with expected and actual counts
test "callModule too many arguments errors" {
    var eval: Evaluator = undefined;
    const r = evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a) a) (m 1 2)");
    try testing.expectError(EvalError.ArityError, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "module 'm' expects 1 argument(s), got 2") != null);
}
