//! Module and component loading: `(import …)` resolution (searches
//! `lib/components/` then `lib/modules/`), `(defmodule …)` with lexical closure
//! capture, and parsing library `component` / `component-family` files into the
//! component cache. Loaded source buffers are never freed — the cached
//! component data borrows them directly.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const check_grammar = @import("check_grammar.zig");
const electrical_mod = @import("electrical.zig");
const thermal = @import("thermal.zig");
const design_block_mod = @import("design_block.zig");
const special_forms = @import("special_forms.zig");
const forms_mod = @import("forms.zig");
const lib_limits = @import("../lib_limits.zig");
const stdlib_mod = @import("../stdlib.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;
const ComponentData = Evaluator.ComponentData;
const BusDef = Evaluator.BusDef;

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;
const BlockDef = env_mod.BlockDef;

// ── Constants ─────────────────────────────────────────────────────
const footprint_form = "footprint";
const datasheet_form = "datasheet";
const thermal_form = "thermal";

/// Cap on one `(import …)` library file read. The class figure, so a component
/// or module file the editor loads is never refused here.
const lib_read_max_bytes: usize = lib_limits.max_lib_file_bytes;

/// Maximum module call nesting. A self-recursive module — an authoring typo
/// like `(defmodule m () (m))`, or two modules calling each other — would
/// otherwise recurse until the process stack overflows and takes down the
/// shared server. Real module trees nest only a handful deep; this cap is
/// generous but finite.
const max_module_depth: usize = 64;

/// Standard passive families auto-imported into every design and module
/// before their body evaluates. Every name here is carried by the bundled
/// standard library (`stdlib/components/`), which is what lets a project with
/// no `lib/` of its own evaluate — a test in `src/stdlib.zig` holds the two
/// lists together, so adding a package family here without shipping its file
/// (and its land pattern) fails the suite rather than the user's first build.
/// A project that carries its own copy still wins; see docs/standard-library.md.
const passives_prelude = [_][]const u8{
    "cap-0201", "cap-0402", "cap-0603",     "cap-0805",
    "res-0201", "res-0402", "res-0603",     "res-0805",
    "ind-0201", "ind-0402", "ind-0603",     "ind-0805",
    "ind-1616", "ind-2016", "ferrite-0402", "led-0402",
};

/// Pre-import the standard passive families so design and module files
/// don't need to list them in `(import …)` headers. Idempotent: the
/// `passives_prelude_loaded` flag short-circuits subsequent calls, which
/// also guards against recursion if a module load triggers prelude load
/// for a name that happens to itself be a module. Failures are still
/// swallowed — a project may deliberately replace a family with a file that
/// does not parse, and the resolver raises `UnboundVariable` at the actual use
/// site — but they are now rare rather than the norm: with the bundle behind
/// every name, an empty project library resolves all sixteen.
pub fn loadPassivesPrelude(self: *Evaluator, env: *Env) void {
    if (self.passives_prelude_loaded) return;
    self.passives_prelude_loaded = true;
    for (passives_prelude) |name| {
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

/// Locate `name` and load it as the right kind of file. Searches
/// `lib/components/` then `lib/modules/` under every on-disk root
/// (`libSearchRoots`), then the bundled standard library. Components get
/// cached in `component_cache`; modules are evaluated against a heap-owned env
/// and bound into the caller's env.
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
    const search_prefixes = [_][]const u8{
        "lib/components/",
        "lib/modules/",
    };
    var roots_buf: [3][]const u8 = undefined;
    const search_roots = libSearchRoots(self, &roots_buf);

    // A module-shaped file that parsed but didn't define `name` (a name ≠
    // filename mismatch). Remembered so, if no other search location resolves,
    // the tail emits a precise diagnostic instead of the misleading
    // "no lib/... file". Buffers are `self.allocator`-owned and outlive eval.
    var mismatch: Mismatch = .{};

    for (search_roots) |root| {
        for (search_prefixes) |prefix| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}.sexp", .{ root, prefix, name }) catch return EvalError.OutOfMemory;
            defer self.allocator.free(path);

            // Note: don't free file_content — AST nodes reference slices into it
            const file_content = infra_fs.cwd().readFileAlloc(self.allocator, path, lib_read_max_bytes) catch continue;
            if (try loadLibraryFile(self, name, env, path, file_content, &mismatch)) return;
        }
    }

    // The bundled standard library, last: a project's own files always win, so
    // a new project evaluates without a `lib/` while an established one never
    // has a shipped part shadow the one it curated. Same loader, same
    // diagnostics; only the path is synthetic (see src/stdlib.zig).
    for (search_prefixes) |prefix| {
        const sub_path = std.fmt.allocPrint(self.allocator, "{s}{s}.sexp", .{ prefix, name }) catch return EvalError.OutOfMemory;
        defer self.allocator.free(sub_path);
        const found = stdlib_mod.standard(self.allocator, sub_path, lib_read_max_bytes) orelse continue;
        defer self.allocator.free(found.path);
        if (try loadLibraryFile(self, name, env, found.path, found.bytes, &mismatch)) return;
    }

    if (mismatch.path) |mp| {
        if (mismatch.actual) |actual| {
            self.setErrorFmt(.{ .line = 1, .col = 1, .offset = 0 }, "'{s}' defines module '{s}', not '{s}' — rename the file or the (defmodule …)", .{ mp, actual, name });
        } else {
            self.setErrorFmt(.{ .line = 1, .col = 1, .offset = 0 }, "'{s}' defines no module named '{s}'", .{ mp, name });
        }
    }
    return EvalError.ImportError;
}

/// A module-shaped library file that parsed but defined no `(defmodule name)`
/// matching the name being imported. Carried across the whole search so a
/// later root can still resolve the import, and only reported if none does.
const Mismatch = struct {
    /// The offending file, duped into an eval-lifetime buffer.
    path: ?[]const u8 = null,
    /// The module that file DOES define, when it defines exactly one.
    actual: ?[]const u8 = null,
};

/// The on-disk roots `(import …)` searches, in order: the project, the
/// evaluator's shared `lib_dir` when it differs, and the process-wide
/// `--lib-dir` / `NETLISP_LIB_DIR` root when it differs from both. The bundled
/// standard library is deliberately NOT a root — it has no directory — and is
/// consulted only after every root has missed.
fn libSearchRoots(self: *Evaluator, buf: *[3][]const u8) [][]const u8 {
    var count: usize = 0;
    buf[count] = self.project_dir;
    count += 1;
    if (!std.mem.eql(u8, self.project_dir, self.lib_dir)) {
        buf[count] = self.lib_dir;
        count += 1;
    }
    if (stdlib_mod.libRoot()) |root| {
        if (!std.mem.eql(u8, root, self.project_dir) and !std.mem.eql(u8, root, self.lib_dir)) {
            buf[count] = root;
            count += 1;
        }
    }
    return buf[0..count];
}

/// Load one candidate library file whose bytes are already in hand, from
/// wherever the search found it. True when `name` was resolved — the component
/// is cached, or the module is bound into `env`. False means "keep looking",
/// with a module-name mismatch recorded in `mismatch` for the failure message.
///
/// `content` is never freed: the AST nodes reference slices into it.
fn loadLibraryFile(
    self: *Evaluator,
    name: []const u8,
    env: *Env,
    path: []const u8,
    content: []const u8,
    mismatch: *Mismatch,
) EvalError!bool {
    // A parse failure here means the library file EXISTS but is malformed —
    // record a diagnostic naming the file AND the failing location within it
    // (carried out of the parser via `parseDiag`), so `evalImport`'s fallback
    // doesn't misreport it as "no lib/... file" and the user is pointed at the
    // exact line/col to fix. The span is into the imported file's buffer, so
    // `diag_format` blanks the (design-file) source line, but the message is
    // self-describing.
    var pdiag: parser_mod.ParseDiagnostic = .{};
    const nodes = parser_mod.parseDiag(self.allocator, content, &pdiag) catch {
        self.setErrorFmt(pdiag.span, "syntax error in '{s}' at {d}:{d}: {s}", .{ path, pdiag.span.line, pdiag.span.col, pdiag.message });
        return EvalError.ImportError;
    };

    // Record this read in `loaded_files` so a caller can reconstruct the
    // evaluator's complete file read-set (design + checks + every imported lib
    // file) for mtime-based cache invalidation. `path` is freed when the search
    // moves on, so key on a dup owned by `self.allocator` (the request arena on
    // the serve path). That same eval-lifetime buffer is what diagnostics
    // raised inside this file carry as their `file`, so the read-set key and
    // the diagnostic path can never disagree.
    const owned_path = ownedFilePath(self, path, nodes);

    // Everything this file evaluates — its component/family load, its
    // `(defmodule …)` registration — reports against the file itself.
    const saved_file = self.current_file;
    self.current_file = owned_path;
    defer self.current_file = saved_file;

    if (nodes.len == 0) return false;
    if (nodes[0].isForm("component")) {
        try loadComponent(self, name, nodes[0]);
        return true;
    }
    if (nodes[0].isForm("component-family")) {
        try loadComponentFamily(self, name, nodes[0]);
        return true;
    }

    // Module file — evaluate in a heap-allocated env (must outlive module def)
    const mod_env = self.allocator.create(Env) catch return EvalError.OutOfMemory;
    mod_env.* = Env.init(self.allocator, null);
    loadPassivesPrelude(self, mod_env);
    _ = self.evalNodes(nodes, mod_env) catch return EvalError.ImportError;
    // The defmodule should have been registered; copy module binding to caller env
    if (mod_env.get(name)) |v| {
        try env.put(name, v);
        return true;
    }
    // The file exists and parses but defines no module named `name` (a name ≠
    // filename mismatch). Destroy the orphaned env (nothing references it now)
    // and remember the mismatch so the search can still try the remaining
    // roots/prefixes; if none resolve, the tail emits a precise diagnostic.
    // `path` is freed when the search moves on, so dup it.
    mod_env.deinit();
    self.allocator.destroy(mod_env);
    if (mismatch.path == null) {
        mismatch.path = self.allocator.dupe(u8, path) catch null;
        mismatch.actual = firstDefmoduleName(nodes);
    }
    return false;
}

/// The eval-lifetime copy of `path` used as this file's `loaded_files` key.
/// Duplicates on first read and returns the stored key afterwards, so every
/// diagnostic from the file borrows one buffer that outlives the import call.
/// Returns "" only when the dup itself fails — diagnostics then fall back to
/// the design path, exactly as before.
fn ownedFilePath(self: *Evaluator, path: []const u8, nodes: []const Node) []const u8 {
    if (self.loaded_files.getKey(path)) |key| return key;
    const key = self.allocator.dupe(u8, path) catch return "";
    self.loaded_files.put(self.allocator, key, nodes) catch {
        self.allocator.free(key);
        return "";
    };
    return key;
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

    // Known structural fields (not properties), derived from the documented
    // registry so the reference names exactly what never becomes a property.
    const skip_fields = &forms_mod.component_reserved_fields;

    var props: std.ArrayList(env_mod.Property) = .empty;
    var buses: std.ArrayList(BusDef) = .empty;
    var datasheets: std.ArrayList([]const u8) = .empty;
    var datasheet_review: ?env_mod.DatasheetReview = null;
    var requirements: std.ArrayList(env_mod.Requirement) = .empty;
    var electrical: std.ArrayList(env_mod.ElectricalDecl) = .empty;
    var thermal_decl: ?env_mod.ThermalDecl = null;
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
            try props.append(self.allocator, .{ .key = "description", .value = val });
        } else if (std.mem.eql(u8, field, "symbol")) {
            symbol_name = cl[1].asText() orelse "";
        } else if (std.mem.eql(u8, field, footprint_form)) {
            footprint_name = cl[1].asText() orelse "";
        } else if (std.mem.eql(u8, field, "pinout")) {
            pinout_name = cl[1].asText() orelse "";
        } else if (std.mem.eql(u8, field, datasheet_form)) {
            const ds = cl[1].asText() orelse continue;
            try datasheets.append(self.allocator, ds);
        } else if (std.mem.eql(u8, field, "datasheet-review")) {
            datasheet_review = parseDatasheetReview(self.allocator, cl);
        } else if (std.mem.eql(u8, field, "requirement")) {
            if (parseComponentRequirement(self, cl)) |req| {
                try requirements.append(self.allocator, req);
            } else {
                self.warnFmt(child.span, "malformed (requirement …) in component \"{s}\" — expected quoted rule text", .{name});
            }
        } else if (std.mem.eql(u8, field, thermal_form)) {
            thermal_decl = thermal.parseThermal(cl) orelse {
                self.warnFmt(child.span, "malformed (thermal …) in component \"{s}\" — ignored", .{name});
                continue;
            };
        } else if (std.mem.eql(u8, field, "electrical")) {
            if (electrical_mod.parse(cl)) |d| {
                try electrical.append(self.allocator, d);
            } else {
                self.warnFmt(child.span, "malformed (electrical …) declaration in component \"{s}\" — ignored", .{name});
            }
        } else if (std.mem.eql(u8, field, "bus")) {
            // (bus "name" pin1 pin2 pin3 ...)
            const bus_name = cl[1].asText() orelse continue;
            var bus_pins: std.ArrayList([]const u8) = .empty;
            for (cl[2..]) |pin_node| {
                const pin_name = pin_node.asText() orelse continue;
                try bus_pins.append(self.allocator, pin_name);
            }
            try buses.append(self.allocator, .{
                .name = bus_name,
                .pins = bus_pins.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            });
        } else if (std.mem.eql(u8, field, "refdes")) {
            // (refdes "Y") — declare this part's ref-des class explicitly, so
            // its instances get that prefix regardless of the family-name
            // heuristic. The first character is the single-letter prefix.
            const val = cl[1].asText() orelse continue;
            if (val.len > 0) refdes_prefix = val[0];
        } else if (!env_mod.containsString(skip_fields, field)) {
            // Unknown, non-structural field -- treat as inline property.
            const val = cl[1].asText() orelse continue;
            try props.append(self.allocator, .{ .key = field, .value = val });
        }
    }

    try self.component_cache.put(self.allocator, name, .{
        .name = name,
        .symbol_name = symbol_name,
        .footprint_name = footprint_name,
        .pinout_name = pinout_name,
        .properties = props.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .buses = buses.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .is_family = false,
        .param_type = "",
        .docs = .{
            .datasheets = datasheets.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            .review = datasheet_review,
        },
        .thermal = thermal_decl,
        .requirements = requirements.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .requirements_ignored = requirements_ignored,
        .electrical = electrical.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .refdes_prefix = refdes_prefix,
    });
}

fn parseComponentRequirement(self: *Evaluator, children: []const Node) ?env_mod.Requirement {
    const text = children[1].asString() orelse return null;
    var ref: ?env_mod.NoteRef = null;
    var check: ?env_mod.Check = null;
    var explicit_id: []const u8 = "";
    for (children[2..]) |extra| {
        if (env_mod.parseNoteRef(extra)) |parsed_ref| {
            ref = parsed_ref;
        } else if (check_grammar.parseCheck(self.allocator, extra)) |parsed_check| {
            check = parsed_check;
        } else if (extra.isForm("check")) {
            self.warnFmt(
                extra.span,
                "malformed or unknown requirement (check …); recognised checks: {s}",
                .{check_grammar.check_keyword_list},
            );
        } else if (extra.asList()) |sub| {
            if (sub.len >= 2 and std.mem.eql(u8, sub[0].asAtom() orelse "", "id")) {
                explicit_id = sub[1].asText() orelse explicit_id;
            }
        }
    }
    const id = if (explicit_id.len > 0)
        explicit_id
    else
        env_mod.requirementIdForText(self.allocator, text) catch "";
    return .{ .text = text, .ref = ref, .check = check, .id = id };
}

/// Parse the provenance/completeness form attached to a component datasheet.
/// Unknown fields are ignored for forwards compatibility; strict preflight
/// owns the semantic completeness checks and reports malformed/missing data.
fn parseDatasheetReview(allocator: std.mem.Allocator, children: []const Node) ?env_mod.DatasheetReview {
    var datasheet: []const u8 = "";
    var sha256: []const u8 = "";
    var status: env_mod.DatasheetReviewStatus = .draft;
    var reviewed_by: []const u8 = "";
    var date: []const u8 = "";
    var categories: std.ArrayList([]const u8) = .empty;
    var not_applicable: std.ArrayList(env_mod.DatasheetReviewNa) = .empty;

    for (children[1..]) |child| {
        const sub = child.asList() orelse continue;
        if (sub.len < 2) continue;
        const head = sub[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, datasheet_form)) {
            datasheet = sub[1].asText() orelse "";
        } else if (std.mem.eql(u8, head, "sha256")) {
            sha256 = sub[1].asText() orelse "";
        } else if (std.mem.eql(u8, head, "status")) {
            const word = sub[1].asText() orelse continue;
            status = std.meta.stringToEnum(env_mod.DatasheetReviewStatus, word) orelse .draft;
        } else if (std.mem.eql(u8, head, "reviewed-by")) {
            reviewed_by = sub[1].asText() orelse "";
        } else if (std.mem.eql(u8, head, "date")) {
            date = sub[1].asText() orelse "";
        } else if (std.mem.eql(u8, head, "category")) {
            const category = sub[1].asText() orelse continue;
            categories.append(allocator, category) catch return null;
        } else if (std.mem.eql(u8, head, "category-na") and sub.len >= 3) {
            const category = sub[1].asText() orelse continue;
            const rationale = sub[2].asText() orelse "";
            not_applicable.append(allocator, .{
                .category = category,
                .rationale = rationale,
            }) catch return null;
        }
    }
    return .{
        .datasheet = datasheet,
        .sha256 = sha256,
        .status = status,
        .reviewed_by = reviewed_by,
        .date = date,
        .categories = categories.toOwnedSlice(allocator) catch return null,
        .not_applicable = not_applicable.toOwnedSlice(allocator) catch return null,
    };
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
    var thermal_decl: ?env_mod.ThermalDecl = null;

    for (children[1..]) |child| {
        if (child.isForm("symbol")) {
            const cl = child.asList().?;
            if (cl.len >= 2) symbol_name = cl[1].asText() orelse "";
        }
        if (child.isForm(footprint_form)) {
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
        // A family's members share one package, so its `(thermal …)` envelope
        // is the whole family's — a `cap-0402` is a `cap-0402` at any value.
        if (child.isForm(thermal_form)) {
            thermal_decl = thermal.parseThermal(child.asList().?) orelse {
                self.warnFmt(child.span, "malformed (thermal …) in component-family \"{s}\" — ignored", .{name});
                continue;
            };
        }
    }

    try self.component_cache.put(self.allocator, name, .{
        .name = name,
        .symbol_name = symbol_name,
        .footprint_name = footprint_name,
        .is_family = true,
        .param_type = param_type,
        .refdes_prefix = refdes_prefix,
        .thermal = thermal_decl,
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

    var params: std.ArrayList([]const u8) = .empty;
    defer params.deinit(self.allocator);
    var defaults: std.ArrayList(?Node) = .empty;
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
        .source_file = self.current_file,
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
///
/// The structural statements `when`/`unless`/`for`/`repeat` count too: a body
/// whose parts are all conditional or looped is still a raw design body, and
/// evaluating it as an expression would reach `(instance …)` in value
/// position. `if` deliberately does NOT count — the corpus idiom
/// `(if cond (design-block …) (design-block …))` selects a whole block as a
/// VALUE, and must keep running through `evalNodes`.
fn bodyHasScopeForm(body: []const Node) bool {
    for (body) |node| {
        const children = node.asList() orelse continue;
        if (children.len == 0) continue;
        const head = children[0].asAtom() orelse continue;
        if (forms_mod.ScopeForm.fromAtom(head) != null) return true;
        const sf = forms_mod.SpecialForm.fromAtom(head) orelse continue;
        switch (sf) {
            .when_, .unless_, .for_, .repeat => return true,
            else => {},
        }
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
    if (self.module_stack.items.len >= max_module_depth) {
        self.setErrorFmt(call_span, "module recursion too deep (>{d}) calling '{s}' — check for a module that calls itself (directly or in a cycle)", .{ max_module_depth, mod.name });
        return EvalError.InvalidForm;
    }

    // Evaluate with a call-stack frame so any diagnostic recorded inside the
    // body — or inside a default expression — carries `in module 'x'
    // (called at L:C)` context lines (innermost first).
    try self.module_stack.append(self.allocator, .{ .name = mod.name, .call_span = call_span });
    defer _ = self.module_stack.pop();

    // The body's spans point into the module's OWN file, so diagnostics raised
    // while it evaluates must name that file — not the design whose build
    // happens to be running. Restored on exit so the caller's file resumes.
    const saved_file = self.current_file;
    if (mod.source_file.len > 0) self.current_file = mod.source_file;
    defer self.current_file = saved_file;

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
    if (result == .design_block) {
        result.design_block.origin = .embedded;
        result.design_block.module_name = mod.name;
    }
    return result;
}

/// Diagnose any parameter left unbound after the call args are processed,
/// excluding parameters that declare a default:
/// `module 'tpsm84338' missing argument(s): rled`.
fn checkMissingParams(self: *Evaluator, mod: BlockDef, bound: []const ?Value, call_span: ast.Span) EvalError!void {
    var missing: std.ArrayList(u8) = .empty;
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
/// shared by the CLI `evalNamedBlock` resolver and the CLI build/check/
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

// spec: eval/modules - a component's (thermal …) form is cached on the component and a component-family declares one for its whole package
test "loadComponent and loadComponentFamily cache the thermal envelope" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(component hot-part
        \\  (footprint "SOT-223")
        \\  (thermal (theta-ja 60) (tj-max 150) (operating -40 125)))
    ;
    const nodes = try parser_mod.parse(alloc, source);
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    try loadComponent(&eval, "hot-part", nodes[0]);
    const decl = eval.component_cache.get("hot-part").?.thermal.?;
    try testing.expectEqual(@as(f64, 60), decl.theta_ja.?);
    try testing.expectEqual(@as(f64, 150), decl.tj_max.?);
    try testing.expectEqual(@as(f64, -40), decl.operating_min.?);
    try testing.expectEqual(@as(f64, 125), decl.operating_max.?);

    const family_source =
        \\(component-family res-0402
        \\  (parameter value "resistance")
        \\  (thermal (theta-ja 250)))
    ;
    const family_nodes = try parser_mod.parse(alloc, family_source);
    try loadComponentFamily(&eval, "res-0402", family_nodes[0]);
    try testing.expectEqual(@as(f64, 250), eval.component_cache.get("res-0402").?.thermal.?.theta_ja.?);
}

// spec: eval/modules - component datasheet-review records preserve digest provenance, categories, and N/A rationale
test "loadComponent parses datasheet-review evidence" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(component reviewed-part
        \\  (datasheet "reviewed.pdf")
        \\  (datasheet-review
        \\    (datasheet "reviewed.pdf")
        \\    (sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        \\    (status complete)
        \\    (reviewed-by "netlisp-agent")
        \\    (date "2026-07-16")
        \\    (category supply)
        \\    (category-na thermal "junction stays below rating")))
    ;
    const nodes = try parser_mod.parse(alloc, source);
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    try loadComponent(&eval, "reviewed-part", nodes[0]);
    const review = eval.component_cache.get("reviewed-part").?.docs.review.?;
    try testing.expectEqual(env_mod.DatasheetReviewStatus.complete, review.status);
    try testing.expectEqualStrings("reviewed.pdf", review.datasheet);
    try testing.expectEqualStrings("netlisp-agent", review.reviewed_by);
    try testing.expectEqualStrings("supply", review.categories[0]);
    try testing.expectEqualStrings("thermal", review.not_applicable[0].category);
    try testing.expectEqualStrings("junction stays below rating", review.not_applicable[0].rationale);
}

// spec: eval/modules - malformed executable requirements and electrical declarations produce diagnostics
test "loadComponent warns when enforceable declarations are malformed" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(component malformed-part
        \\  (requirement "bypass it" (check (decouplng (pin "VDD") (pin "GND"))))
        \\  (electrical "VDD" (type mystery)))
    ;
    const nodes = try parser_mod.parse(alloc, source);
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    try loadComponent(&eval, "malformed-part", nodes[0]);

    try testing.expectEqual(@as(usize, 2), eval.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, eval.warnings.items[0].message, "recognised checks") != null);
    try testing.expect(std.mem.indexOf(u8, eval.warnings.items[1].message, "electrical") != null);
}

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

test "implements metadata is inert when a wrapped module evaluates" {
    // spec: eval/modules - implementation metadata is evaluable but has no runtime value
    var eval: Evaluator = undefined;
    const source = "(defmodule m () (implements chip (policy canonical) (role regulator)) 7) (m)";
    const value = try evalModuleSource(std.heap.page_allocator, &eval, source);
    try testing.expectEqual(@as(f64, 7), value.asNumber().?);
}

test "wrapped module stamps definition name separately from display title" {
    // spec: eval/modules - wrapped module roots retain defmodule provenance independently of their design-block title
    var eval: Evaluator = undefined;
    const source = "(defmodule buck () (implements chip (policy canonical)) " ++
        "(design-block \"3V3 Supply\")) (buck)";
    const value = try evalModuleSource(std.heap.page_allocator, &eval, source);
    try testing.expectEqualStrings("3V3 Supply", value.design_block.name);
    try testing.expectEqualStrings("buck", value.design_block.module_name);
    try testing.expectEqual(env_mod.BlockOrigin.embedded, value.design_block.origin);
}

// spec: eval/modules - a module body whose parts are all inside structural statements is still a raw design body
test "a module body of only structural statements materializes a design" {
    var eval: Evaluator = undefined;
    const source = "(defmodule m ((fit 1)) (when (== fit 1) (port \"VOUT\" out))) (m)";
    const value = try evalModuleSource(std.heap.page_allocator, &eval, source);
    try testing.expectEqual(@as(usize, 1), value.design_block.ports.len);
    try testing.expectEqualStrings("VOUT", value.design_block.ports[0].name);
}

// spec: eval/modules - a module body that selects a whole design-block with if still yields that block as a value
test "if selecting a design-block in a module body stays an expression" {
    var eval: Evaluator = undefined;
    const source = "(defmodule m ((v 1)) (if (== v 1) (design-block \"A\") (design-block \"B\"))) (m)";
    const value = try evalModuleSource(std.heap.page_allocator, &eval, source);
    try testing.expectEqualStrings("A", value.design_block.name);
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

// spec: eval/modules - A syntax error in an imported library file is diagnosed with the file path and location
test "resolveImport reports imported file syntax error with path and location" {
    // page_allocator: resolveImport dups the in-progress key + diagnostic
    // message into self.allocator and intentionally never frees them.
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    // Malformed module: a stray '@' (unexpected character) at line 2, col 3.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/broken.sexp", .data = "(defmodule broken ()\n  @bad)\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, root);
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    try testing.expectError(EvalError.ImportError, resolveImport(&eval, "broken", &env));
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    // The message names the imported file and its accurate in-file location.
    try testing.expect(std.mem.indexOf(u8, diag.message, "lib/modules/broken.sexp") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "2:3") != null);
    // And the recorded span points into the imported file, not a bare 1:1.
    try testing.expectEqual(@as(u32, 2), diag.span.line);
    try testing.expectEqual(@as(u32, 3), diag.span.col);
}

// spec: eval/modules - Surplus positional arguments are diagnosed with expected and actual counts
test "callModule too many arguments errors" {
    var eval: Evaluator = undefined;
    const r = evalModuleSource(std.heap.page_allocator, &eval, "(defmodule m (a) a) (m 1 2)");
    try testing.expectError(EvalError.ArityError, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "module 'm' expects 1 argument(s), got 2") != null);
}

// spec: eval/modules - a warning raised inside an imported module is attributed to the module's own file
test "module warnings carry the module file, not the importing design" {
    // page_allocator: warning messages and the loaded_files key outlive eval.
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    // `(rolle …)` is not a design-block sub-form: the builder warns and skips.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/modules/warner.sexp",
        .data = "(defmodule warner ()\n  (design-block \"warner\"\n    (rolle \"typo\")))\n",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, root);
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const nodes = try parser_mod.parse(alloc, "(import warner)\n(warner)\n");
    _ = try eval.evalNodes(nodes, &env);
    try testing.expectEqual(@as(usize, 1), eval.warnings.items.len);
    const w = eval.warnings.items[0];
    try testing.expect(std.mem.indexOf(u8, w.file, "lib/modules/warner.sexp") != null);
    // Line 3 of the MODULE file — the design that called it is one line long.
    try testing.expectEqual(@as(u32, 3), w.span.line);
}

// spec: eval/modules - an error raised inside an imported module is attributed to the module's own file
test "module errors carry the module file, not the importing design" {
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/modules/thrower.sexp",
        .data = "(defmodule thrower ()\n  (design-block \"thrower\"\n    (note no-such-name)))\n",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var eval = Evaluator.init(alloc, root);
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const nodes = try parser_mod.parse(alloc, "(import thrower)\n(thrower)\n");
    try testing.expectError(EvalError.ArityError, eval.evalNodes(nodes, &env));
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.file, "lib/modules/thrower.sexp") != null);
    try testing.expectEqual(@as(u32, 3), diag.span.line);
}

/// Write `design` as the sole source of a temp project and evaluate it. The
/// project has whatever `tmp` already holds and nothing else — in particular no
/// `lib/` unless the caller made one — so what resolves is exactly what the
/// library search order provides.
fn evalTempDesign(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir, design: []const u8) !*env_mod.DesignBlock {
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/board.sexp", .data = design });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/board.sexp", .{project});
    // The evaluator retains its parsed source and component cache for the
    // life of the design, so it is deliberately not deinit'd here (the caller
    // uses page_allocator, matching production's lifecycle).
    const eval = try alloc.create(Evaluator);
    eval.* = Evaluator.init(alloc, project);
    const value = try eval.evalFile(design_path);
    return switch (value) {
        .design_block => |b| b,
        else => error.TestUnexpectedResult,
    };
}

/// The instance with `ref_des`, or null when the design has none.
fn instanceByRef(block: *const env_mod.DesignBlock, ref_des: []const u8) ?env_mod.Instance {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) return inst;
    }
    return null;
}

// spec: eval/modules - a design in a project with no lib/ of its own resolves every passive from the bundled standard library, footprint included
test "a project with no library still resolves the standard passives" {
    // page_allocator for the same lifecycle production uses: parsed AST and
    // component cache are retained for the design's life, never freed.
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const block = try evalTempDesign(alloc, &tmp,
        \\(design-block "No Library Here"
        \\  (instance "C1" (cap-0402 "100nF") (pin 1 "VDD") (pin 2 "GND"))
        \\  (instance "R1" (res-0402 "10k") (pin 1 "VDD") (pin 2 "LED_A"))
        \\  (instance "L1" (ind-0603 "10uH") (pin 1 "VDD") (pin 2 "VFILT"))
        \\  (instance "D1" (led-0402 "red") (pin 1 "LED_A") (pin 2 "GND")))
    );

    try testing.expectEqual(@as(usize, 4), block.instances.len);
    // Every instance resolved to a real family AND to the land pattern that
    // family names — a footprint-less instance builds but cannot be fabricated.
    const expected = [_]struct { ref: []const u8, footprint: []const u8 }{
        .{ .ref = "C1", .footprint = "c-0402" },
        .{ .ref = "R1", .footprint = "r-0402" },
        .{ .ref = "L1", .footprint = "l-0603" },
        .{ .ref = "D1", .footprint = "led-0402" },
    };
    for (expected) |want| {
        const inst = instanceByRef(block, want.ref) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(want.footprint, inst.footprint);
    }
}

// spec: eval/modules - a project's own lib/components file overrides the bundled family of the same name
test "a project component file shadows the bundled one" {
    const alloc = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/cap-0402.sexp",
        .data =
        \\(component-family "cap-0402"
        \\  (description "house 0402 capacitor")
        \\  (symbol generic-cap)
        \\  (footprint house-c-0402)
        \\  (parameter "value" capacitance))
        ,
    });

    const block = try evalTempDesign(alloc, &tmp,
        \\(design-block "House Rules"
        \\  (instance "C1" (cap-0402 "100nF") (pin 1 "VDD") (pin 2 "GND"))
        \\  (instance "C2" (cap-0603 "1uF") (pin 1 "VDD") (pin 2 "GND")))
    );

    // The project's own file wins for the name it defines …
    const c1 = instanceByRef(block, "C1") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("house-c-0402", c1.footprint);
    // … and shadows nothing else: every other family still comes from the bundle.
    const c2 = instanceByRef(block, "C2") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("c-0603", c2.footprint);
}
