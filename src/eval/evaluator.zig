const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const builtins = @import("builtins.zig");

// Sub-modules
const special_forms = @import("special_forms.zig");
const modules = @import("modules.zig");
const design_block = @import("design_block.zig");
const instance_mod = @import("instance.zig");
const builders = @import("builders.zig");
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

    pub const PendingId = struct {
        /// Byte offset of the opening paren of the form
        form_offset: u32,
        /// The generated 8-char hex ID to insert
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
    }

    /// Evaluate a file and return the top-level design block. Routes
    /// through `loadDesignFile` so a sibling `<name>.checks.sexp` file —
    /// when present — has its forms spliced into the design-block body
    /// before evaluation.
    pub fn evalFile(self: *Evaluator, path: []const u8) EvalError!Value {
        const nodes = builders.loadDesignFile(self, path) orelse return EvalError.ImportError;
        var env = Env.init(self.allocator, null);
        defer env.deinit();
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

    fn evalForm(self: *Evaluator, children: []const Node, env: *Env) EvalError!Value {
        const head = children[0];
        const head_name = head.asAtom() orelse {
            // Head is not an atom -- could be a computed form
            return EvalError.InvalidForm;
        };
        const args = children[1..];

        // Special forms (don't evaluate arguments eagerly)
        if (std.mem.eql(u8, head_name, "let")) return special_forms.evalLet(self, args, env);
        if (std.mem.eql(u8, head_name, "if")) return special_forms.evalIf(self, args, env);
        if (std.mem.eql(u8, head_name, "cond")) return special_forms.evalCond(self, args, env);
        if (std.mem.eql(u8, head_name, "import")) return modules.evalImport(self, args, env);
        if (std.mem.eql(u8, head_name, "defmodule")) return modules.evalDefmodule(self, args, env);
        if (std.mem.eql(u8, head_name, "design-block")) return design_block.evalDesignBlock(self, args, env);
        if (std.mem.eql(u8, head_name, "assert")) return special_forms.evalAssert(self, args, env);
        if (std.mem.eql(u8, head_name, "assert-range")) return special_forms.evalAssertRange(self, args, env);
        if (std.mem.eql(u8, head_name, "fmt")) return special_forms.evalFmt(self, args, env);
        if (std.mem.eql(u8, head_name, "id")) return .nil;

        // Builtins (evaluate arguments first)
        if (builtins.isBuiltin(head_name)) {
            var eval_args: std.ArrayListUnmanaged(Value) = .empty;
            defer eval_args.deinit(self.allocator);
            for (args) |arg| {
                const v = try self.evalNode(arg, env);
                try eval_args.append(self.allocator, v);
            }
            return builtins.evalBuiltin(head_name, eval_args.items) catch |err| switch (err) {
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

        return EvalError.UnboundVariable;
    }

    // Public re-exports for backward compatibility (used by external callers via Evaluator.foo)
    pub const parseId = ids.parseId;
    pub const isStandardRefDes = ids.isStandardRefDes;
    pub const generateId = ids.generateId;
    pub const deriveChildId = ids.deriveChildId;
};

// ── Tests ──────────────────────────────────────────────────────────────

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

// Force test runner to pick up sub-module tests
test {
    _ = ids;
    _ = special_forms;
    _ = modules;
    _ = design_block;
    _ = instance_mod;
    _ = builders;
}
