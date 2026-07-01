const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const electrical_mod = @import("electrical.zig");
const design_block_mod = @import("design_block.zig");
const special_forms = @import("special_forms.zig");
const forms_mod = @import("forms.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;
const ComponentData = Evaluator.ComponentData;
const BusDef = Evaluator.BusDef;

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;
const BlockDef = env_mod.BlockDef;

// ── Constants ─────────────────────────────────────────────────────
const FOOTPRINT_FORM = "footprint";

/// Maximum module call nesting. A self-recursive module — an authoring typo
/// like `(defmodule m () (m))`, or two modules calling each other — would
/// otherwise recurse until the process stack overflows and takes down the
/// shared server. Real module trees nest only a handful deep; this cap is
/// generous but finite.
const MAX_MODULE_DEPTH: usize = 64;

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
    // Support multi-import: (import a b c ...). Route through the shared
    // arity checker so a bare `(import)` records a diagnostic instead of
    // returning a bare ArityError that leaves a stale `last_error` behind.
    try special_forms.checkArity(self, .import, args);
    for (args) |arg| {
        const name = arg.asAtom() orelse {
            self.setError(arg.span, "(import …) names must be bare atoms, e.g. (import cap-0402)");
            return EvalError.InvalidForm;
        };
        resolveImport(self, name, env) catch |err| {
            if (self.last_error == null)
                self.setErrorFmt(arg.span, "cannot import '{s}' — no lib/components/{s}.sexp or lib/modules/{s}.sexp", .{ name, name, name });
            return err;
        };
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

    // Cycle guard: if `name` is already mid-resolution higher on the stack,
    // a module file imports (transitively) itself. Without this, each hop
    // re-reads + re-evaluates the other file in a fresh env forever until the
    // process stack overflows. Diagnose it as a circular import instead.
    if (self.imports_in_progress.contains(name)) {
        self.setErrorFmt(.{ .line = 1, .col = 1, .offset = 0 }, "circular import of '{s}' — a module file imports itself (directly or through a cycle)", .{name});
        return EvalError.ImportError;
    }
    const in_progress_key = self.allocator.dupe(u8, name) catch return EvalError.OutOfMemory;
    self.imports_in_progress.put(self.allocator, in_progress_key, {}) catch {
        self.allocator.free(in_progress_key);
        return EvalError.OutOfMemory;
    };
    defer {
        if (self.imports_in_progress.fetchRemove(name)) |kv| self.allocator.free(kv.key);
    }

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

    // A module-shaped file that parsed but didn't define `name` (a name ≠
    // filename mismatch). Remembered so, if no other search location resolves,
    // the tail emits a precise diagnostic instead of the misleading
    // "no lib/... file". Buffers are `self.allocator`-owned and outlive eval.
    var mismatch_path: ?[]const u8 = null;
    var mismatch_actual: ?[]const u8 = null;

    for (search_roots) |root| {
        for (search_prefixes) |prefix| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}.sexp", .{ root, prefix, name }) catch return EvalError.OutOfMemory;
            defer self.allocator.free(path);

            // Note: don't free file_content — AST nodes reference slices into it
            const file_content = infra_fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch continue;

            // A parse failure here means the library file EXISTS but is
            // malformed — record a diagnostic naming the file so `evalImport`'s
            // fallback doesn't misreport it as "no lib/... file" to the very
            // user who needs to fix the syntax error.
            const nodes = parser_mod.parse(self.allocator, file_content) catch |err| {
                self.setErrorFmt(.{ .line = 1, .col = 1, .offset = 0 }, "syntax error in '{s}': {s}", .{ path, @errorName(err) });
                return EvalError.ImportError;
            };

            // Record this read in `loaded_files` so a caller can reconstruct the
            // evaluator's complete file read-set (design + checks + every
            // imported lib file) for mtime-based cache invalidation. `path` is
            // freed when this call returns, so key on a dup owned by
            // `self.allocator` (the request arena on the serve path).
            if (!self.loaded_files.contains(path)) {
                if (self.allocator.dupe(u8, path)) |key| {
                    self.loaded_files.put(self.allocator, key, nodes) catch self.allocator.free(key);
                } else |_| {}
            }

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
                // The file exists and parses but defines no module named `name`
                // (a name ≠ filename mismatch). Destroy the orphaned env
                // (nothing references it now) and remember the mismatch so the
                // search can still try the remaining roots/prefixes; if none
                // resolve, the tail emits a precise diagnostic. `path` is freed
                // on loop exit, so dup it into an eval-lifetime buffer.
                mod_env.deinit();
                self.allocator.destroy(mod_env);
                if (mismatch_path == null) {
                    mismatch_path = self.allocator.dupe(u8, path) catch null;
                    mismatch_actual = firstDefmoduleName(nodes);
                }
            }
        }
    }
    if (mismatch_path) |mp| {
        if (mismatch_actual) |actual| {
            self.setErrorFmt(.{ .line = 1, .col = 1, .offset = 0 }, "'{s}' defines module '{s}', not '{s}' — rename the file or the (defmodule …)", .{ mp, actual, name });
        } else {
            self.setErrorFmt(.{ .line = 1, .col = 1, .offset = 0 }, "'{s}' defines no module named '{s}'", .{ mp, name });
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
        "refdes",
    };

    var props: std.ArrayListUnmanaged(env_mod.Property) = .empty;
    var buses: std.ArrayListUnmanaged(BusDef) = .empty;
    var datasheets: std.ArrayListUnmanaged([]const u8) = .empty;
    var requirements: std.ArrayListUnmanaged(env_mod.Requirement) = .empty;
    var electrical: std.ArrayListUnmanaged(env_mod.ElectricalDecl) = .empty;
    var requirements_ignored = false;
    // Explicit ref-des class: `(refdes "Y")` declares the single-letter prefix
    // this part's instances get, overriding the name heuristic. 0 = unset.
    var refdes_prefix: u8 = 0;

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
                } else if (env_mod.parseCheck(self.allocator, extra)) |c| {
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
        } else if (std.mem.eql(u8, field, "refdes")) {
            // (refdes "Y") — declare this part's ref-des class explicitly, so
            // its instances get that prefix regardless of the family-name
            // heuristic. The first character is the single-letter prefix.
            const val = cl[1].asText() orelse continue;
            if (val.len > 0) refdes_prefix = val[0];
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
        .refdes_prefix = refdes_prefix,
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
    var refdes_prefix: u8 = 0; // (refdes "X") — explicit ref-des class; 0 = unset

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
        if (child.isForm("refdes")) {
            const cl = child.asList().?;
            if (cl.len >= 2) {
                if (cl[1].asText()) |val| {
                    if (val.len > 0) refdes_prefix = val[0];
                }
            }
        }
    }

    try self.component_cache.put(self.allocator, name, .{
        .name = name,
        .symbol_name = symbol_name,
        .footprint_name = footprint_name,
        .is_family = true,
        .param_type = param_type,
        .refdes_prefix = refdes_prefix,
    });
}

/// Evaluate `(defmodule name (params…) "doc?" body…)` and bind the resulting
/// `BlockDef` in the current env. The body nodes are stored verbatim for
/// later evaluation when the module is called; the param list is captured
/// alongside the module file's import scope so calls resolve correctly.
/// A parameter is either a bare atom (required) or a `(param default)` pair
/// — the default expression is stored unevaluated and only runs at call
/// time when the caller omits that argument.
pub fn evalDefmodule(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    // (defmodule name (params...) docstring? body...)
    try special_forms.checkArity(self, .defmodule, args);
    const name = args[0].asAtom() orelse {
        self.setError(args[0].span, "(defmodule …) name must be a bare atom");
        return EvalError.InvalidForm;
    };
    const params_node = args[1].asList() orelse {
        self.setErrorFmt(args[1].span, "(defmodule {s} …) expects a parameter list, e.g. (defmodule {s} (rfbt rfbb) …)", .{ name, name });
        return EvalError.InvalidForm;
    };

    var params: std.ArrayListUnmanaged([]const u8) = .empty;
    defer params.deinit(self.allocator);
    var defaults: std.ArrayListUnmanaged(?Node) = .empty;
    defer defaults.deinit(self.allocator);
    for (params_node) |p| {
        if (p.asAtom()) |pname| {
            try params.append(self.allocator, pname);
            try defaults.append(self.allocator, null);
            continue;
        }
        if (p.asList()) |pair| {
            if (pair.len == 2) {
                if (pair[0].asAtom()) |pname| {
                    try params.append(self.allocator, pname);
                    try defaults.append(self.allocator, pair[1]);
                    continue;
                }
            }
        }
        self.setErrorFmt(p.span, "(defmodule {s} …) parameters must be bare atoms or (param default) pairs", .{name});
        return EvalError.InvalidForm;
    }

    // Skip docstring if present
    var body_start: usize = 2;
    if (args.len > 2) {
        if (args[2].asString() != null) body_start = 3;
    }

    const param_slice = self.allocator.dupe([]const u8, params.items) catch return EvalError.OutOfMemory;
    const default_slice = self.allocator.dupe(?Node, defaults.items) catch return EvalError.OutOfMemory;
    const mod = BlockDef{
        .name = name,
        .params = param_slice,
        .defaults = default_slice,
        .body = args[body_start..],
        .imports = env,
    };

    try env.put(name, .{ .block_def = mod });
    return .nil;
}

/// The name declared by the first top-level `(defmodule <name> …)` /
/// `(block <name-atom> …)` in `nodes`, or null if none is found. Used to make
/// a name ≠ filename import mismatch diagnostic name the actual module.
fn firstDefmoduleName(nodes: []const Node) ?[]const u8 {
    for (nodes) |node| {
        const children = node.asList() orelse continue;
        if (children.len < 2) continue;
        const head = children[0].asAtom() orelse continue;
        const is_defmodule = std.mem.eql(u8, head, "defmodule");
        // `(block <atom> …)` is the unified module-definition form.
        const is_block_def = std.mem.eql(u8, head, "block") and children[1].asAtom() != null;
        if (is_defmodule or is_block_def) {
            if (children[1].asAtom()) |mod_name| return mod_name;
        }
    }
    return null;
}

/// Index of the declared parameter a call arg names, when the arg uses the
/// named form `(param expr)` — a 2-element list whose head atom matches one
/// of the module's parameter names. Anything else (including 2-element lists
/// like `(cap-0402 "100nF")` whose head is not a param) is a positional
/// expression and returns null.
fn namedParamIndex(mod: BlockDef, arg: Node) ?usize {
    const pair = arg.asList() orelse return null;
    if (pair.len != 2) return null;
    const name = pair[0].asAtom() orelse return null;
    for (mod.params, 0..) |param, i| {
        if (std.mem.eql(u8, param, name)) return i;
    }
    return null;
}

/// True if a module body holds a top-level wrapper block that materializes on
/// its own: an inner `(design-block …)`, or a string-named `(block "…" …)`
/// (which routes to `evalDesignBlock`). Such a body is run through `evalNodes`
/// so the inner block (and any preceding setup forms) evaluate normally.
fn bodyHasInnerBlock(body: []const Node) bool {
    for (body) |node| {
        const children = node.asList() orelse continue;
        if (children.len == 0) continue;
        const head = children[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "design-block")) return true;
        if (std.mem.eql(u8, head, "block") and children.len > 1 and children[1].asString() != null) return true;
    }
    return false;
}

/// True if a module body carries any top-level design-scope (`ScopeForm`) form
/// — `instance`/`port`/`section`/`sub-block`/`net`/`decouple`/… — i.e. it is a
/// "raw" body that builds a design directly, with no inner block wrapper. A
/// body that is only setup forms (`let`/`assert`/`import`) or a delegating
/// expression (a call to another module) has no scope form and is NOT raw — it
/// runs through `evalNodes` so its final expression's value flows out and any
/// error inside it (e.g. an unbound name) propagates with the call stack.
fn bodyHasScopeForm(body: []const Node) bool {
    for (body) |node| {
        const children = node.asList() orelse continue;
        if (children.len == 0) continue;
        const head = children[0].asAtom() orelse continue;
        if (forms_mod.ScopeForm.fromAtom(head) != null) return true;
    }
    return false;
}

/// Call a module: bind each call-site argument — positional in declaration
/// order, or named via `(param expr)` — into a fresh child scope rooted at
/// the module file's import env, then run the module body. Positional args
/// may not follow a named arg; duplicate and missing bindings are
/// diagnosed with the parameter names. Returns the last body expression's
/// value — typically a `(design-block …)`.
pub fn callModule(self: *Evaluator, mod: BlockDef, call_args: []const Node, call_span: ast.Span, caller_env: *Env) EvalError!Value {
    const bound = self.allocator.alloc(?Value, mod.params.len) catch return EvalError.OutOfMemory;
    defer self.allocator.free(bound);
    for (bound) |*b| b.* = null;

    var pos_idx: usize = 0;
    var seen_named = false;
    for (call_args) |arg| {
        if (namedParamIndex(mod, arg)) |pi| {
            if (bound[pi] != null) {
                self.setErrorFmt(arg.span, "parameter '{s}' bound twice in call to module '{s}'", .{ mod.params[pi], mod.name });
                return EvalError.InvalidForm;
            }
            const pair = arg.asList().?;
            bound[pi] = try self.evalNode(pair[1], caller_env);
            seen_named = true;
            continue;
        }
        if (seen_named) {
            self.setErrorFmt(arg.span, "positional argument after named argument in call to module '{s}'", .{mod.name});
            return EvalError.InvalidForm;
        }
        if (pos_idx >= mod.params.len) {
            self.setErrorFmt(arg.span, "module '{s}' expects {d} argument(s), got {d}", .{ mod.name, mod.params.len, call_args.len });
            return EvalError.ArityError;
        }
        bound[pos_idx] = try self.evalNode(arg, caller_env);
        pos_idx += 1;
    }

    try checkMissingParams(self, mod, bound, call_span);

    // Bound recursion: a module that (transitively) calls itself would spin
    // `callModule` until the native stack overflows. The `module_stack` depth
    // already tracks the active call chain, so cap it here with a diagnostic
    // that still carries the frames leading in.
    if (self.module_stack.items.len >= MAX_MODULE_DEPTH) {
        self.setErrorFmt(call_span, "module recursion too deep (>{d}) calling '{s}' — check for a module that calls itself (directly or in a cycle)", .{ MAX_MODULE_DEPTH, mod.name });
        return EvalError.InvalidForm;
    }

    // Evaluate with a call-stack frame so any diagnostic recorded inside the
    // body — or inside a default expression — carries `in module 'x'
    // (called at L:C)` context lines (innermost first).
    try self.module_stack.append(self.allocator, .{ .name = mod.name, .call_span = call_span });
    defer _ = self.module_stack.pop();

    // Create module scope with parameter bindings. Parameters the caller
    // left unbound fall back to their declared default, evaluated inside
    // the module scope in declaration order — a later parameter's default
    // may therefore reference an earlier parameter.
    var mod_env = Env.init(self.allocator, mod.imports);
    defer mod_env.deinit();
    for (mod.params, 0..) |param, i| {
        if (bound[i]) |v| {
            try mod_env.put(param, v);
        } else if (mod.defaults[i]) |dflt| {
            try mod_env.put(param, try self.evalNode(dflt, &mod_env));
        }
    }

    // A module body comes in two shapes. A "raw" body holds design-scope forms
    // (instance/port/net/…) straight at the top level with no inner block — it
    // is materialized in place, named after the module, reusing the identical
    // scope-form walk. Every other body — the classic "wrapped" form ending in
    // an inner `(design-block …)`/string-named `(block "…" …)`, a body that is
    // only setup forms, or one that delegates to another module call — runs
    // through `evalNodes` so its inner block / final expression evaluates and
    // any error inside propagates with the module call stack. (An inner block
    // is itself a wrapper, never a `ScopeForm`, so the two checks don't
    // overlap; guarding on it explicitly keeps the wrapped path obvious.)
    const result = if (!bodyHasInnerBlock(mod.body) and bodyHasScopeForm(mod.body))
        try design_block_mod.materializeBlock(self, mod.name, mod.body, &mod_env)
    else
        try self.evalNodes(mod.body, &mod_env);
    // Mark the produced block as embedded (vs a top-level design root) so the
    // PCB placer engages role-based auto-placement for module roots only.
    // Propagates to sub-block instantiations, standalone previews, and zero-arg
    // resolves — every module root flows through here.
    if (result == .design_block) result.design_block.origin = .embedded;
    return result;
}

/// Diagnose any parameter left unbound after the call args are processed,
/// excluding parameters that declare a default:
/// `module 'tpsm84338' missing argument(s): rled`.
fn checkMissingParams(self: *Evaluator, mod: BlockDef, bound: []const ?Value, call_span: ast.Span) EvalError!void {
    var missing: std.ArrayListUnmanaged(u8) = .empty;
    defer missing.deinit(self.allocator);
    for (mod.params, 0..) |param, i| {
        if (bound[i] != null) continue;
        if (mod.defaults[i] != null) continue;
        if (missing.items.len > 0) try missing.appendSlice(self.allocator, ", ");
        try missing.appendSlice(self.allocator, param);
    }
    if (missing.items.len == 0) return;
    self.setErrorFmt(call_span, "module '{s}' missing argument(s): {s}", .{ mod.name, missing.items });
    return EvalError.ArityError;
}

/// Instantiate a `lib/modules/<name>.sexp` module standalone via its
/// parameter defaults (zero args). Resolves the module file, then calls it
/// with no arguments so every `(param default)` supplies its value
/// (defaults-first). Returns the module's evaluated design block (stamped
/// `origin = .embedded` by `callModule`), or an error when the module is
/// missing or needs required args it has no defaults for. The returned
/// block borrows `self`'s arena — keep the evaluator alive while using it.
/// This is the single source of the "render a module standalone" logic
/// shared by the MCP `evalNamedBlock` resolver and the CLI build/check/
/// export paths.
pub fn instantiateStandalone(self: *Evaluator, name: []const u8) EvalError!Value {
    var env = Env.init(self.allocator, null);
    defer env.deinit();
    try resolveImport(self, name, &env);
    const bound = env.get(name) orelse return EvalError.ImportError;
    const bd = switch (bound) {
        .block_def => |b| b,
        else => return EvalError.ImportError,
    };
    return callModule(self, bd, &.{}, .{ .line = 1, .col = 1, .offset = 0 }, &env);
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

// spec: eval/modules - Omitted parameters fall back to their declared (param default) value
test "callModule default fills omitted argument" {
    var eval: Evaluator = undefined;
    const v = try evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a (b 4)) (- a b)) (m 10)");
    try testing.expectEqual(@as(f64, 6.0), v.asNumber().?);
}

// spec: eval/modules - A supplied argument overrides the parameter's declared default
test "callModule explicit argument overrides default" {
    var eval: Evaluator = undefined;
    const v = try evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m ((a 2) (b 3)) (- a b)) (m (b 1))");
    try testing.expectEqual(@as(f64, 1.0), v.asNumber().?);
}

// spec: eval/modules - A later parameter's default may reference an earlier parameter
test "callModule default references earlier param" {
    var eval: Evaluator = undefined;
    const v = try evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a (b a)) (+ a b)) (m 5)");
    try testing.expectEqual(@as(f64, 10.0), v.asNumber().?);
}

// spec: eval/modules - Required parameters are still diagnosed when only defaulted ones are unbound
test "callModule missing required param with defaults present" {
    var eval: Evaluator = undefined;
    const r = evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a (b 2)) (+ a b)) (m)");
    try testing.expectError(EvalError.ArityError, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "module 'm' missing argument(s): a") != null);
}

// spec: eval/modules - Surplus positional arguments are diagnosed with expected and actual counts
test "callModule too many arguments errors" {
    var eval: Evaluator = undefined;
    const r = evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a) a) (m 1 2)");
    try testing.expectError(EvalError.ArityError, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "module 'm' expects 1 argument(s), got 2") != null);
}
