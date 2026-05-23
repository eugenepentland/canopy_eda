const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const builtins = @import("builtins.zig");

// Sub-modules
const special_forms = @import("special_forms.zig");
const modules = @import("modules.zig");
const design_block = @import("design_block.zig");
const instance_mod = @import("instance.zig");
const builders = @import("builders.zig");
const forms = @import("forms.zig");
const SpecialForm = forms.SpecialForm;
const Builtin = forms.Builtin;
pub const ids = @import("ids.zig");

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;
const PinRef = env_mod.PinRef;
const Port = env_mod.Port;
const Note = env_mod.Note;
const Group = env_mod.Group;
const SubBlock = env_mod.SubBlock;
const ModuleDef = env_mod.ModuleDef;
const AssertionResult = env_mod.AssertionResult;

/// Source-located explanation for the most recent `EvalError`. Zig
/// error sets can't carry data, so the evaluator stashes the location
/// + a short borrowed message here. Callers (CLI / server) read
/// `Evaluator.last_error` after a failed eval and render a diagnostic
/// like `port form at sexp:42:7: expected atom, got list`.
pub const EvalDiagnostic = struct {
    span: ast.Span,
    /// Human-readable summary. Borrowed; lives as long as the source
    /// buffer or the static string the caller passed in.
    message: []const u8,
};

pub const EvalError = error{
    TypeError,
    ArityError,
    DivisionByZero,
    UnboundVariable,
    InvalidForm,
    ImportError,
    OutOfMemory,
    FormatError,
    NotEnoughArgs,
    AssertionFailed,
    /// `generateId` could not find an unused 8-char token after the bounded
    /// number of attempts — effectively impossible at ~30 bits of entropy,
    /// but kept so the re-roll loop has a defined exit.
    IdSpaceExhausted,
};

/// One pin-to-net binding gathered while evaluating an instance or
/// `(decouple …)` form. The design-block builder collects these into a flat
/// list and then groups them by net name to produce `Net` records.
pub const PinNetDecl = struct {
    ref_des: []const u8,
    pin: []const u8,
    net: []const u8,
    /// Alternate functions asserted via `(as "FN1" "FN2" ...)`. Empty slice when none were
    /// asserted. Multiple entries let a pin declare more than one simultaneous role.
    asserted_fns: []const []const u8 = &.{},
    /// Typical current (A) the instance draws on this net — set only on the first
    /// pin of a pin-group so sums across nets don't double-count.
    i_typ: ?f64 = null,
    /// Absolute-max current (A) on this net — same first-pin-only semantics as i_typ.
    i_max: ?f64 = null,
};

/// A single alternate function entry for a multi-function pin.
pub const AltFunc = struct {
    name: []const u8,
    /// Electrical type (io / input / output / bidi / …). Empty if unspecified.
    etype: []const u8 = "",
};

/// Per-design decouple defaults set by `(decouple-defaults (ic …) (bypass …))`.
/// `ic` is the fallback host ref a `(decouple …)` per-pin list resolves against
/// when no explicit ref is given; `bypass` is the component node substituted
/// when the decouple omits its own. Empty/null means "no default declared", in
/// which case `(decouple …)` keeps its legacy fully-explicit form.
pub const DecoupleDefaults = struct {
    ic: []const u8 = "",
    bypass: ?ast.Node = null,
};

/// The S-expression evaluator. Holds the project + library directories,
/// caches loaded files, parsed library components, and per-symbol pinouts,
/// and accumulates assertion results plus the pending-ID write-back list
/// the build command uses to freeze freshly-generated 8-char hex IDs into
/// the source files.
pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    /// Shared library directory for component/module fallback resolution.
    /// Defaults to project_dir; set separately when using per-project folders.
    lib_dir: []const u8,
    assertions: std.ArrayListUnmanaged(AssertionResult),
    /// Cache of loaded file contents (path -> parsed nodes)
    loaded_files: std.StringHashMapUnmanaged([]const Node),
    /// Cache of loaded component/symbol/footprint data
    component_cache: std.StringHashMapUnmanaged(ComponentData),
    /// Cache of symbol pin names: symbol_name -> (pin_id -> pin_function_name)
    symbol_pin_cache: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),
    /// Cache of per-pin alternate functions: symbol_name -> (pin_id -> []AltFunc)
    symbol_alt_cache: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const AltFunc)),
    /// Auto ref-des counter per prefix letter
    auto_refdes: std.AutoHashMapUnmanaged(u8, u32),
    /// Forms that need (id ...) auto-inserted: (source_offset, generated_id)
    pending_ids: std.ArrayListUnmanaged(PendingId),
    /// Child-id sidecars that need `(ids ("key" token) …)` written/extended on
    /// a parent shorthand form (decouple/series). Keyed by the parent's
    /// `form_offset`; one entry per synthesized child. See `id_insert.zig`.
    pending_child_ids: std.ArrayListUnmanaged(PendingChildId),
    /// Every 8-char hex id token seen anywhere in the design tree — existing
    /// source tokens (registered by `prescanIds`) plus every token
    /// `generateId` mints this session. `generateId` re-rolls against this set
    /// so no two components ever share an id (incl. after copy-paste from
    /// another design built by the same evaluator).
    design_ids: std.StringHashMapUnmanaged(void),
    /// True once `loadPassivesPrelude` has run. Guards against re-entering
    /// the prelude when a module load itself triggers another module load,
    /// and lets `evalFile` skip the work after the first design.
    passives_prelude_loaded: bool = false,
    /// Set while evaluating a design-block that declared `(hierarchical-ids)`.
    /// Switches `buildSubBlock` to Option-4 identity (one auto-minted uuid per
    /// sub-block, children derived from it + their `origin_key`) instead of the
    /// legacy `(ids …)` sidecar. Inherited into nested module evaluation and
    /// restored on exit, so a marked design propagates to its sub-modules.
    hierarchical_ids: bool = false,
    /// Per-design decouple defaults from `(decouple-defaults (ic …) (bypass …))`.
    /// Design-block-scoped: saved/restored across nested module evaluation in
    /// `evalDesignBlock` so a parent's defaults never leak into a sub-block module.
    decouple_defaults: DecoupleDefaults = .{},
    /// Span + short message describing the most recent `EvalError`.
    /// Populated by the form handlers when they return an error so the
    /// CLI / server can render a diagnostic that points at the source.
    last_error: ?EvalDiagnostic = null,

    pub const PendingId = struct {
        /// Byte offset of the opening paren of the form
        form_offset: u32,
        /// The generated 8-char hex ID to insert
        id: []const u8,
    };

    pub const PendingChildId = struct {
        /// Byte offset of the opening paren of the PARENT shorthand form
        /// (decouple/series) the child belongs to.
        parent_form_offset: u32,
        /// Stable structural key for this child within the parent
        /// (e.g. "15uF@P7#0" for decouple, "100nF#1" for series).
        key: []const u8,
        /// The generated 8-char hex token for this child.
        id: []const u8,
    };

    pub const NetTie = struct {
        a: []const u8,
        b: []const u8,
        /// True for ties synthesized from symbol pin-function matching
        /// (appendAutoAliases). These are block-local — buildNets consumes
        /// them for pin-name consolidation, but they must NOT leak into
        /// block.net_ties, because function names like "VDD_1" repeat across
        /// components and would falsely bridge unrelated nets during the
        /// cross-block flatten in export_kicad_netlist.applyNetTies.
        is_auto: bool = false,
    };

    pub const BusDef = struct {
        name: []const u8,
        pins: []const []const u8,
    };

    pub const ComponentData = struct {
        name: []const u8,
        symbol_name: []const u8,
        footprint_name: []const u8,
        pinout_name: []const u8 = "",
        properties: []const env_mod.Property = &.{},
        buses: []const BusDef = &.{},
        is_family: bool,
        param_type: []const u8, // "resistance", "capacitance", etc.
        /// PDF filenames in `lib/datasheets/` that document this part.
        /// Parsed from `(datasheet "file.pdf")` in the component file.
        datasheets: []const []const u8 = &.{},
        /// Rules for using this part correctly (e.g. "VDD must be decoupled
        /// with 100nF within 3mm"). Parsed from
        /// `(requirement "text" (ref "file.pdf" (page N)))`. Shared across
        /// every design that uses the part — used by the review page to
        /// cross-check design work against the part's rules.
        requirements: []const env_mod.Requirement = &.{},
        /// Set by `(ignore-requirements)` in the component file. Marks parts
        /// where requirement coverage is intentionally skipped (mounting
        /// hardware, simple debug headers, etc.) so they don't show up in
        /// the schematic-summary "missing requirements" list.
        requirements_ignored: bool = false,
        /// Per-pin electrical-level metadata declared via
        /// `(electrical "PIN_FN" (type X) (v-ih-min Y) …)` inside the
        /// `(component …)` file. Sparse on purpose — Phase 2A's ERC
        /// silently skips pins without electrical data so the library
        /// can grow annotations incrementally.
        electrical: []const env_mod.ElectricalDecl = &.{},
    };

    pub fn init(allocator: std.mem.Allocator, project_dir: []const u8) Evaluator {
        return initWithLibDir(allocator, project_dir, project_dir);
    }

    pub fn initWithLibDir(allocator: std.mem.Allocator, project_dir: []const u8, lib_dir: []const u8) Evaluator {
        return .{
            .allocator = allocator,
            .project_dir = project_dir,
            .lib_dir = lib_dir,
            .assertions = .empty,
            .loaded_files = .empty,
            .component_cache = .empty,
            .symbol_pin_cache = .empty,
            .symbol_alt_cache = .empty,
            .auto_refdes = .empty,
            .pending_ids = .empty,
            .pending_child_ids = .empty,
            .design_ids = .empty,
            .passives_prelude_loaded = false,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.assertions.deinit(self.allocator);
        self.loaded_files.deinit(self.allocator);
        self.component_cache.deinit(self.allocator);
        self.symbol_pin_cache.deinit(self.allocator);
        self.symbol_alt_cache.deinit(self.allocator);
        self.auto_refdes.deinit(self.allocator);
        self.pending_ids.deinit(self.allocator);
        self.pending_child_ids.deinit(self.allocator);
        self.design_ids.deinit(self.allocator);
    }

    /// Evaluate a file and return the top-level design block. Routes
    /// through `loadDesignFile` so a sibling `<name>.checks.sexp` file —
    /// when present — has its forms spliced into the design-block body
    /// before evaluation.
    pub fn evalFile(self: *Evaluator, path: []const u8) EvalError!Value {
        const nodes = builders.loadDesignFile(self, path) orelse return EvalError.ImportError;
        var env = Env.init(self.allocator, null);
        defer env.deinit();
        modules.loadPassivesPrelude(self, &env);
        return self.evalNodes(nodes, &env);
    }

    /// Evaluate raw S-expression source text in a fresh top-level env, with
    /// the passives prelude loaded — the same setup as `evalFile` but for an
    /// in-memory string rather than a file, and without the `.checks.sexp`
    /// autoloader. Used by the `/modules` viewer to instantiate a
    /// zero-parameter module inside a synthetic one-line `design-block`.
    pub fn evalSource(self: *Evaluator, source: []const u8) EvalError!Value {
        const nodes = parser_mod.parse(self.allocator, source) catch return EvalError.ImportError;
        var env = Env.init(self.allocator, null);
        defer env.deinit();
        modules.loadPassivesPrelude(self, &env);
        return self.evalNodes(nodes, &env);
    }

    /// Evaluate a sequence of top-level nodes.
    pub fn evalNodes(self: *Evaluator, nodes: []const Node, env: *Env) EvalError!Value {
        var result: Value = .nil;
        for (nodes) |node| {
            result = try self.evalNode(node, env);
        }
        return result;
    }

    /// Evaluate a single node.
    pub fn evalNode(self: *Evaluator, node: Node, env: *Env) EvalError!Value {
        switch (node.tag) {
            .atom => |name| {
                // Look up variable
                if (env.get(name)) |v| return v;
                // Might be a bare component reference
                if (self.component_cache.get(name)) |_| return .{ .component = name };
                return EvalError.UnboundVariable;
            },
            .string => |s| return .{ .string = s },
            .int => |i| return .{ .number = @floatFromInt(i) },
            .float => |f| return .{ .number = f },
            .unit_val => |u| return .{ .number = u },
            .list => |children| {
                if (children.len == 0) return .nil;
                return self.evalForm(children, env);
            },
        }
    }

    /// Record a source-located diagnostic for the most recent error.
    /// The message slice is borrowed; pass a static string or a slice
    /// that outlives the next `evalNode` call.
    pub fn setError(self: *Evaluator, span: ast.Span, message: []const u8) void {
        self.last_error = .{ .span = span, .message = message };
    }

    fn evalForm(self: *Evaluator, children: []const Node, env: *Env) EvalError!Value {
        const head = children[0];
        const head_name = head.asAtom() orelse {
            // Head is not an atom -- could be a computed form
            self.setError(head.span, "form head must be an atom");
            return EvalError.InvalidForm;
        };
        const args = children[1..];

        // Special forms (don't evaluate arguments eagerly)
        if (SpecialForm.fromAtom(head_name)) |sf| return switch (sf) {
            .let => special_forms.evalLet(self, args, env),
            .if_ => special_forms.evalIf(self, args, env),
            .cond => special_forms.evalCond(self, args, env),
            .import => modules.evalImport(self, args, env),
            .defmodule => modules.evalDefmodule(self, args, env),
            .design_block => design_block.evalDesignBlock(self, args, env),
            .assert_ => special_forms.evalAssert(self, args, env),
            .assert_range => special_forms.evalAssertRange(self, args, env),
            .fmt_ => special_forms.evalFmt(self, args, env),
            .id_ => .nil,
        };

        // Builtins (evaluate arguments first). Looking the operator up
        // once skips the second name match `evalBuiltin` would do.
        if (Builtin.fromAtom(head_name)) |op| {
            var eval_args: std.ArrayListUnmanaged(Value) = .empty;
            defer eval_args.deinit(self.allocator);
            for (args) |arg| {
                const v = try self.evalNode(arg, env);
                try eval_args.append(self.allocator, v);
            }
            return builtins.evalBuiltinOp(op, eval_args.items) catch |err| switch (err) {
                error.TypeError => return EvalError.TypeError,
                error.ArityError => return EvalError.ArityError,
                error.DivisionByZero => return EvalError.DivisionByZero,
            };
        }

        // Module or component-family invocation
        if (env.get(head_name)) |v| {
            switch (v) {
                .module => |mod| return modules.callModule(self, mod, args, env),
                else => {},
            }
        }

        // Component-family invocation: (cap "100nF") or (cap "10pF" np0)
        if (self.component_cache.get(head_name)) |comp| {
            if (comp.is_family and args.len >= 1) {
                const val = try self.evalNode(args[0], env);
                const val_str = val.asString() orelse return EvalError.TypeError;
                // Collect additional args as schematic attributes
                var attrs: std.ArrayListUnmanaged([]const u8) = .empty;
                for (args[1..]) |attr_node| {
                    const attr = attr_node.asAtom() orelse (attr_node.asString() orelse continue);
                    attrs.append(self.allocator, attr) catch continue;
                }
                return .{ .component_instance = .{
                    .family = head_name,
                    .value = val_str,
                    .attrs = attrs.toOwnedSlice(self.allocator) catch &.{},
                } };
            }
            return .{ .component = head_name };
        }

        // Nothing in the dispatch table, no module, no component — the
        // head atom is undefined. Stash it so the caller can render
        // "unknown form `foo` at sexp:42:7" instead of a bare error.
        self.setError(head.span, head_name);
        return EvalError.UnboundVariable;
    }

    // Public re-exports for backward compatibility (used by external callers via Evaluator.foo)
    pub const parseId = ids.parseId;
    pub const isStandardRefDes = ids.isStandardRefDes;
    pub const generateId = ids.generateId;
    pub const deriveChildId = ids.deriveChildId;
};

// ── Tests ──────────────────────────────────────────────────────────────

// spec: eval/evaluator - last_error records the source span of an unknown form so callers can report file:line:col
test "unknown form populates last_error with span" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const parser = @import("../sexpr/parser.zig");
    // Put the bogus form on its own line so the recorded span is non-trivial.
    const nodes = try parser.parse(alloc,
        \\(let x 1)
        \\(definitely-not-a-form 1 2)
    );
    defer parser.freeNodes(alloc, nodes);

    const result = eval.evalNodes(nodes, &env);
    try std.testing.expectError(EvalError.UnboundVariable, result);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try std.testing.expectEqual(@as(u32, 2), diag.span.line);
    try std.testing.expectEqualStrings("definitely-not-a-form", diag.message);
}

// spec: eval/evaluator - last_error records the source span of an arity mismatch in a special form
test "arity error populates last_error with span" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const parser = @import("../sexpr/parser.zig");
    // `let` needs exactly 2 args; this gives it 3. Span should point at
    // the first argument's position.
    const nodes = try parser.parse(alloc, "(let x 1 2)");
    defer parser.freeNodes(alloc, nodes);

    const result = eval.evalNodes(nodes, &env);
    try std.testing.expectError(EvalError.ArityError, result);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try std.testing.expect(diag.span.line == 1 and diag.span.col > 1);
    try std.testing.expectEqualStrings("wrong number of arguments", diag.message);
}

// spec: eval/evaluator - Evaluates arithmetic expressions from S-expression AST
test "eval arithmetic" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const parser = @import("../sexpr/parser.zig");
    const nodes = try parser.parse(alloc, "(* 0.6 (+ 1.0 (/ 220000.0 47000.0)))");
    defer parser.freeNodes(alloc, nodes);

    const result = try eval.evalNode(nodes[0], &env);
    try std.testing.expectApproxEqAbs(@as(f64, 3.4085), result.asNumber().?, 0.001);
}

// spec: eval/evaluator - Evaluates let bindings that define named values in scope
test "eval let bindings" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const parser = @import("../sexpr/parser.zig");
    const nodes = try parser.parse(alloc, "(let x 5) (let y (+ x 3)) y");
    defer parser.freeNodes(alloc, nodes);

    const result = try eval.evalNodes(nodes, &env);
    try std.testing.expectEqual(@as(f64, 8.0), result.asNumber().?);
}

// spec: eval/evaluator - Evaluates if conditionals selecting a branch by predicate
test "eval if conditional" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const parser = @import("../sexpr/parser.zig");
    const nodes = try parser.parse(alloc, "(if (> 5 3) \"yes\" \"no\")");
    defer parser.freeNodes(alloc, nodes);

    const result = try eval.evalNode(nodes[0], &env);
    try std.testing.expectEqualStrings("yes", result.asString().?);
}

// spec: eval/evaluator - Evaluates fmt expressions producing formatted strings
test "eval fmt" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const parser = @import("../sexpr/parser.zig");
    const nodes = try parser.parse(alloc, "(fmt \"~V Buck (TPSM84338)\" 3.41)");
    defer parser.freeNodes(alloc, nodes);

    const result = try eval.evalNode(nodes[0], &env);
    const s = result.asString().?;
    defer alloc.free(s);
    try std.testing.expectEqualStrings("3.41V Buck (TPSM84338)", s);
}

// spec: eval/evaluator - Evaluates assert-range that passes when value is in bounds
test "eval assert-range pass" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const parser = @import("../sexpr/parser.zig");
    const nodes = try parser.parse(alloc, "(let v 3.3) (assert-range v 0.6 16.0 \"VOUT\")");
    defer parser.freeNodes(alloc, nodes);

    _ = try eval.evalNodes(nodes, &env);
    try std.testing.expectEqual(@as(usize, 1), eval.assertions.items.len);
    try std.testing.expect(eval.assertions.items[0].passed);

    // Clean up allocated message
    alloc.free(eval.assertions.items[0].message);
}

// spec: eval/evaluator - Evaluates assert-range that fails when value is out of bounds
test "eval assert-range fail" {
    const alloc = std.testing.allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    const parser = @import("../sexpr/parser.zig");
    const nodes = try parser.parse(alloc, "(let v 20.0) (assert-range v 0.6 16.0 \"VOUT\")");
    defer parser.freeNodes(alloc, nodes);

    _ = try eval.evalNodes(nodes, &env);
    try std.testing.expectEqual(@as(usize, 1), eval.assertions.items.len);
    try std.testing.expect(!eval.assertions.items[0].passed);

    // Clean up allocated message
    alloc.free(eval.assertions.items[0].message);
}

// ── Passives-prelude fixtures ─────────────────────────────────────────

const passives_prelude_files = [_]struct { name: []const u8, body: []const u8 }{
    .{ .name = "cap-0201", .body = "(component-family \"cap-0201\" (symbol generic-cap) (footprint c-0201) (parameter \"value\" capacitance))" },
    .{ .name = "cap-0402", .body = "(component-family \"cap-0402\" (symbol generic-cap) (footprint c-0402) (parameter \"value\" capacitance))" },
    .{ .name = "cap-0603", .body = "(component-family \"cap-0603\" (symbol generic-cap) (footprint c-0603) (parameter \"value\" capacitance))" },
    .{ .name = "cap-0805", .body = "(component-family \"cap-0805\" (symbol generic-cap) (footprint c-0805) (parameter \"value\" capacitance))" },
    .{ .name = "res-0201", .body = "(component-family \"res-0201\" (symbol generic-res) (footprint r-0201) (parameter \"value\" resistance))" },
    .{ .name = "res-0402", .body = "(component-family \"res-0402\" (symbol generic-res) (footprint r-0402) (parameter \"value\" resistance))" },
    .{ .name = "res-0603", .body = "(component-family \"res-0603\" (symbol generic-res) (footprint r-0603) (parameter \"value\" resistance))" },
    .{ .name = "res-0805", .body = "(component-family \"res-0805\" (symbol generic-res) (footprint r-0805) (parameter \"value\" resistance))" },
    .{ .name = "ind-0201", .body = "(component-family \"ind-0201\" (symbol generic-ind) (footprint l-0201) (parameter \"value\" inductance))" },
    .{ .name = "ind-0402", .body = "(component-family \"ind-0402\" (symbol generic-ind) (footprint l-0402) (parameter \"value\" inductance))" },
    .{ .name = "ind-0603", .body = "(component-family \"ind-0603\" (symbol generic-ind) (footprint l-0603) (parameter \"value\" inductance))" },
    .{ .name = "ind-0805", .body = "(component-family \"ind-0805\" (symbol generic-ind) (footprint l-0805) (parameter \"value\" inductance))" },
    .{ .name = "ind-1616", .body = "(component-family \"ind-1616\" (symbol generic-ind) (footprint l-1616) (parameter \"value\" inductance))" },
    .{ .name = "ind-2016", .body = "(component-family \"ind-2016\" (symbol generic-ind) (footprint l-2016) (parameter \"value\" inductance))" },
    .{ .name = "ferrite-0402", .body = "(component-family \"ferrite-0402\" (symbol generic-ferrite) (footprint fb-0402) (parameter \"value\" string))" },
    .{ .name = "led-0402", .body = "(component-family \"led-0402\" (symbol generic-led) (footprint led-0402) (parameter \"color\" string))" },
};

fn makePassivesTmp(alloc: std.mem.Allocator) !struct { tmp: std.testing.TmpDir, path: []const u8 } {
    var tmp = std.testing.tmpDir(.{});
    try tmp.dir.makePath("lib/components");
    for (passives_prelude_files) |f| {
        const sub_path = try std.fmt.allocPrint(alloc, "lib/components/{s}.sexp", .{f.name});
        defer alloc.free(sub_path);
        try tmp.dir.writeFile(.{ .sub_path = sub_path, .data = f.body });
    }
    const path = try tmp.dir.realpathAlloc(alloc, ".");
    return .{ .tmp = tmp, .path = path };
}

// spec: eval/evaluator - Passives prelude resolves the standard cap/res/ind/ferrite/led families when their files exist
test "passives prelude loads all standard families" {
    // Production code never frees parsed AST or file_content (they back the
    // component cache for the evaluator's lifetime), so use page_allocator
    // for the same lifecycle the build uses. testing.allocator would flag
    // those intentional allocations as leaks.
    const alloc = std.heap.page_allocator;
    var fx = try makePassivesTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    var eval = Evaluator.init(alloc, fx.path);
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    modules.loadPassivesPrelude(&eval, &env);

    for (passives_prelude_files) |f| {
        try std.testing.expect(eval.component_cache.contains(f.name));
    }
}

// spec: eval/evaluator - Passives prelude silently skips library entries whose files are missing instead of failing the build
test "passives prelude tolerates missing files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(path);

    // No lib/components dir at all — every prelude entry is unresolvable.
    var eval = Evaluator.init(alloc, path);
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    modules.loadPassivesPrelude(&eval, &env);
    try std.testing.expectEqual(@as(u32, 0), eval.component_cache.count());
}

// spec: eval/evaluator - Explicit import after prelude pre-loads is a no-op (resolveImport short-circuits on cached components)
test "explicit import after prelude is idempotent" {
    const alloc = std.heap.page_allocator;
    var fx = try makePassivesTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    var eval = Evaluator.init(alloc, fx.path);
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    modules.loadPassivesPrelude(&eval, &env);
    const after_prelude = eval.component_cache.count();

    try modules.resolveImport(&eval, "cap-0402", &env);
    try std.testing.expectEqual(after_prelude, eval.component_cache.count());
}

// spec: eval/evaluator - evalFile auto-imports the standard passives prelude before user nodes run
test "evalFile auto-imports passives prelude" {
    const alloc = std.heap.page_allocator;
    var fx = try makePassivesTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    // Design uses cap-0402 with no explicit import. If the prelude doesn't
    // fire before user nodes evaluate, this errors with UnboundVariable.
    try fx.tmp.dir.makePath("src/sample");
    try fx.tmp.dir.writeFile(.{
        .sub_path = "src/sample/sample.sexp",
        .data =
        \\(design-block "Sample"
        \\  (instance "C1" (cap-0402 "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
        ,
    });

    var eval = Evaluator.init(alloc, fx.path);
    defer eval.deinit();

    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/sample/sample.sexp", .{fx.path});
    defer alloc.free(design_path);

    _ = try eval.evalFile(design_path);
    try std.testing.expect(eval.component_cache.contains("cap-0402"));
}

// spec: eval/evaluator - Module files loaded via resolveImport get the same passives prelude before their body evaluates
test "module loading triggers passives prelude" {
    const alloc = std.heap.page_allocator;
    var fx = try makePassivesTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    // Module body uses cap-0402 inside its design-block without an explicit
    // import — only succeeds if module loading runs the prelude first.
    try fx.tmp.dir.makePath("lib/modules");
    try fx.tmp.dir.writeFile(.{
        .sub_path = "lib/modules/sample-mod.sexp",
        .data =
        \\(defmodule sample-mod ()
        \\  (design-block "Sample Module"
        \\    (instance "C1" (cap-0402 "10nF")
        \\      (pin 1 "VDD")
        \\      (pin 2 "GND"))))
        ,
    });

    var eval = Evaluator.init(alloc, fx.path);
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();

    try modules.resolveImport(&eval, "sample-mod", &env);
    try std.testing.expect(eval.component_cache.contains("cap-0402"));
}

// Force test runner to pick up sub-module tests
test {
    _ = ids;
    _ = special_forms;
    _ = modules;
    _ = design_block;
    _ = instance_mod;
    _ = builders;
    _ = forms;
}
