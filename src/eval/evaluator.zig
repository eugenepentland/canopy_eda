const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const builtins = @import("builtins.zig");
const fmt_mod = @import("fmt.zig");

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

pub const Evaluator = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    assertions: std.ArrayListUnmanaged(AssertionResult),
    /// Cache of loaded file contents (path -> parsed nodes)
    loaded_files: std.StringHashMapUnmanaged([]const Node),
    /// Cache of loaded component/symbol/footprint data
    component_cache: std.StringHashMapUnmanaged(ComponentData),
    /// Cache of symbol pin names: symbol_name → (pin_id → pin_function_name)
    symbol_pin_cache: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),
    /// Auto ref-des counter per prefix letter
    auto_refdes: std.AutoHashMapUnmanaged(u8, u32),

    pub const ComponentData = struct {
        name: []const u8,
        symbol_name: []const u8,
        footprint_name: []const u8,
        pinout_name: []const u8 = "",
        properties: []const env_mod.Property = &.{},
        is_family: bool,
        param_type: []const u8, // "resistance", "capacitance", etc.
    };

    pub fn init(allocator: std.mem.Allocator, project_dir: []const u8) Evaluator {
        return .{
            .allocator = allocator,
            .project_dir = project_dir,
            .assertions = .empty,
            .loaded_files = .empty,
            .component_cache = .empty,
            .symbol_pin_cache = .empty,
            .auto_refdes = .empty,
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.assertions.deinit(self.allocator);
        self.loaded_files.deinit(self.allocator);
        self.component_cache.deinit(self.allocator);
        self.symbol_pin_cache.deinit(self.allocator);
        self.auto_refdes.deinit(self.allocator);
    }

    /// Get the next auto ref-des for a given prefix (e.g., 'C' → "C1", "C2", ...).
    fn nextRefDes(self: *Evaluator, prefix: u8) ![]const u8 {
        const gop = self.auto_refdes.getOrPut(self.allocator, prefix) catch return EvalError.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
        return std.fmt.allocPrint(self.allocator, "{c}{d}", .{ prefix, gop.value_ptr.* }) catch return EvalError.OutOfMemory;
    }

    /// Bump auto ref-des counter to avoid conflicts with explicit ref-des.
    fn registerRefDes(self: *Evaluator, ref_des: []const u8) void {
        if (ref_des.len < 2) return;
        const prefix = ref_des[0];
        const num = std.fmt.parseInt(u32, ref_des[1..], 10) catch return;
        const gop = self.auto_refdes.getOrPut(self.allocator, prefix) catch return;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        if (num > gop.value_ptr.*) gop.value_ptr.* = num;
    }

    /// Get the ref-des prefix letter for a component family name.
    fn componentPrefix(family: []const u8) u8 {
        if (std.mem.eql(u8, family, "ind")) return 'L';
        if (std.mem.eql(u8, family, "led")) return 'D';
        if (family.len > 0) return std.ascii.toUpper(family[0]);
        return 'X';
    }

    /// Extract the source byte offset of the component family name from an AST node.
    /// For a list like (cap-0402 "100nF"), returns the offset of the first child atom.
    /// For a plain atom, returns the atom's own offset.
    fn componentSourceOffset(node: Node) u32 {
        switch (node.tag) {
            .list => |children| {
                if (children.len > 0) return children[0].span.offset;
            },
            else => {},
        }
        return node.span.offset;
    }

    /// Load pin names for a component from lib/pinouts/.
    fn getSymbolPins(self: *Evaluator, lookup_name: []const u8) ?*const std.StringHashMapUnmanaged([]const u8) {
        if (self.symbol_pin_cache.getPtr(lookup_name)) |cached| return cached;

        const pinout_path = std.fmt.allocPrint(self.allocator, "{s}/lib/pinouts/{s}.sexp", .{ self.project_dir, lookup_name }) catch return null;
        if (self.loadPinFile(pinout_path, "pinout")) |pin_map| {
            self.symbol_pin_cache.put(self.allocator, lookup_name, pin_map) catch return null;
            return self.symbol_pin_cache.getPtr(lookup_name);
        }

        return null;
    }

    /// Load pin definitions from a pinout file.
    fn loadPinFile(self: *Evaluator, path: []const u8, expected_form: []const u8) ?std.StringHashMapUnmanaged([]const u8) {
        const content = std.fs.cwd().readFileAlloc(self.allocator, path, 1024 * 256) catch return null;
        const nodes = parser_mod.parse(self.allocator, content) catch return null;
        if (nodes.len == 0) return null;
        const top = nodes[0].asList() orelse return null;
        if (top.len < 2) return null;
        const head = top[0].asAtom() orelse return null;
        if (!std.mem.eql(u8, head, expected_form)) return null;

        var pin_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (top[2..]) |child| {
            const cl = child.asList() orelse continue;
            if (cl.len < 3) continue;
            const ch = cl[0].asAtom() orelse continue;
            if (!std.mem.eql(u8, ch, "pin")) continue;
            const pin_id = self.pinId(cl[1]) orelse continue;
            const func_name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
            pin_map.put(self.allocator, pin_id, func_name) catch continue;
        }
        return pin_map;
    }

    /// Check symbol pins against the pinout (source of truth).
    fn validateSymbolAgainstPinout(self: *Evaluator, symbol_name: []const u8, sym_pins: *const std.StringHashMapUnmanaged([]const u8)) void {
        const pinout_path = std.fmt.allocPrint(self.allocator, "{s}/lib/pinouts/{s}.sexp", .{ self.project_dir, symbol_name }) catch return;
        const pinout_content = std.fs.cwd().readFileAlloc(self.allocator, pinout_path, 1024 * 256) catch return;
        const pinout_nodes = parser_mod.parse(self.allocator, pinout_content) catch return;
        if (pinout_nodes.len == 0) return;
        const pinout_top = pinout_nodes[0].asList() orelse return;
        if (pinout_top.len < 2) return;
        const head = pinout_top[0].asAtom() orelse return;
        if (!std.mem.eql(u8, head, "pinout")) return;

        // Build pinout map: pin_id → function_name
        var pinout_map: std.StringHashMapUnmanaged([]const u8) = .empty;
        defer pinout_map.deinit(self.allocator);
        for (pinout_top[2..]) |child| {
            const cl = child.asList() orelse continue;
            if (cl.len < 3) continue;
            const ch = cl[0].asAtom() orelse continue;
            if (!std.mem.eql(u8, ch, "pin")) continue;
            const pin_id = self.pinId(cl[1]) orelse continue;
            const func_name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
            pinout_map.put(self.allocator, pin_id, func_name) catch continue;
        }

        // Validate: every symbol pin must exist in pinout with matching name
        var sym_it = sym_pins.iterator();
        while (sym_it.next()) |entry| {
            const pin_id = entry.key_ptr.*;
            const sym_name = entry.value_ptr.*;
            if (pinout_map.get(pin_id)) |pinout_name| {
                if (!std.mem.eql(u8, sym_name, pinout_name)) {
                    std.debug.print("PINOUT ERROR: symbol '{s}' pin {s}: symbol says \"{s}\" but pinout says \"{s}\"\n", .{ symbol_name, pin_id, sym_name, pinout_name });
                }
            } else {
                std.debug.print("PINOUT ERROR: symbol '{s}' pin {s} (\"{s}\") does not exist in pinout\n", .{ symbol_name, pin_id, sym_name });
            }
        }
    }

    /// Convert a node to a pin identifier string (number → "123", atom → "A1").
    fn pinId(self: *Evaluator, node: Node) ?[]const u8 {
        if (node.asNumber()) |n| {
            const i: i64 = @intFromFloat(n);
            return std.fmt.allocPrint(self.allocator, "{d}", .{i}) catch return null;
        }
        return node.asAtom() orelse node.asString();
    }

    /// Evaluate a file and return the top-level design block.
    pub fn evalFile(self: *Evaluator, path: []const u8) EvalError!Value {
        const nodes = self.loadFile(path) orelse return EvalError.ImportError;
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
            // Head is not an atom — could be a computed form
            return EvalError.InvalidForm;
        };
        const args = children[1..];

        // Special forms (don't evaluate arguments eagerly)
        if (std.mem.eql(u8, head_name, "let")) return self.evalLet(args, env);
        if (std.mem.eql(u8, head_name, "if")) return self.evalIf(args, env);
        if (std.mem.eql(u8, head_name, "cond")) return self.evalCond(args, env);
        if (std.mem.eql(u8, head_name, "import")) return self.evalImport(args, env);
        if (std.mem.eql(u8, head_name, "defmodule")) return self.evalDefmodule(args, env);
        if (std.mem.eql(u8, head_name, "design-block")) return self.evalDesignBlock(args, env);
        if (std.mem.eql(u8, head_name, "assert")) return self.evalAssert(args, env);
        if (std.mem.eql(u8, head_name, "assert-range")) return self.evalAssertRange(args, env);
        if (std.mem.eql(u8, head_name, "fmt")) return self.evalFmt(args, env);

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
                .module => |mod| return self.callModule(mod, args, env),
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

    fn evalLet(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
        if (args.len != 2) return EvalError.ArityError;
        const name = args[0].asAtom() orelse return EvalError.InvalidForm;
        const value = try self.evalNode(args[1], env);
        try env.put(name, value);
        return .nil;
    }

    fn evalIf(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
        if (args.len != 3) return EvalError.ArityError;
        const cond = try self.evalNode(args[0], env);
        if (cond.isTruthy()) {
            return self.evalNode(args[1], env);
        } else {
            return self.evalNode(args[2], env);
        }
    }

    fn evalCond(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
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

    fn evalFmt(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
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

    fn evalAssert(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
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

    fn evalAssertRange(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
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

    fn evalImport(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
        // Support multi-import: (import a b c ...)
        if (args.len < 1) return EvalError.ArityError;
        for (args) |arg| {
            const name = arg.asAtom() orelse return EvalError.InvalidForm;
            try self.resolveImport(name, env);
        }
        return .nil;
    }

    fn resolveImport(self: *Evaluator, name: []const u8, env: *Env) EvalError!void {
        // Already loaded?
        if (self.component_cache.contains(name)) return;
        if (env.get(name) != null) return;

        // Search path: components first, then modules
        const search_paths = [_][]const u8{
            "lib/components/",
            "lib/modules/",
        };

        for (search_paths) |prefix| {
            const path = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}.sexp", .{ self.project_dir, prefix, name }) catch return EvalError.OutOfMemory;
            defer self.allocator.free(path);

            // Note: don't free file_content — AST nodes reference slices into it
            const file_content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch continue;

            const nodes = parser_mod.parse(self.allocator, file_content) catch return EvalError.ImportError;

            // Determine what kind of file this is
            if (nodes.len > 0) {
                if (nodes[0].isForm("component")) {
                    try self.loadComponent(name, nodes[0]);
                    return;
                }
                if (nodes[0].isForm("component-family")) {
                    try self.loadComponentFamily(name, nodes[0]);
                    return;
                }
                // Module file — evaluate in a heap-allocated env (must outlive module def)
                const mod_env = self.allocator.create(Env) catch return EvalError.OutOfMemory;
                mod_env.* = Env.init(self.allocator, null);
                _ = self.evalNodes(nodes, mod_env) catch return EvalError.ImportError;
                // The defmodule should have been registered; copy module binding to caller env
                if (mod_env.get(name)) |v| {
                    try env.put(name, v);
                    return;
                }
            }
        }
        return EvalError.ImportError;
    }

    fn loadComponent(self: *Evaluator, name: []const u8, node: Node) EvalError!void {
        const children = node.asList() orelse return EvalError.InvalidForm;
        var symbol_name: []const u8 = "";
        var footprint_name: []const u8 = "";
        var pinout_name: []const u8 = "";

        // Known structural fields (not properties)
        const skip_fields = [_][]const u8{ "description", "symbol", "footprint", "pinout", "component", "parameter", "component-family" };

        var props: std.ArrayListUnmanaged(env_mod.Property) = .empty;

        for (children[1..]) |child| {
            const cl = child.asList() orelse continue;
            if (cl.len < 2) continue;
            const field = cl[0].asAtom() orelse continue;

            if (std.mem.eql(u8, field, "symbol")) {
                symbol_name = cl[1].asAtom() orelse "";
            } else if (std.mem.eql(u8, field, "footprint")) {
                footprint_name = cl[1].asAtom() orelse "";
            } else if (std.mem.eql(u8, field, "pinout")) {
                pinout_name = cl[1].asAtom() orelse "";
            } else {
                // Check if it's a known structural field
                var is_structural = false;
                for (skip_fields) |sf| {
                    if (std.mem.eql(u8, field, sf)) { is_structural = true; break; }
                }
                if (!is_structural) {
                    const val = cl[1].asString() orelse (cl[1].asAtom() orelse continue);
                    props.append(self.allocator, .{ .key = field, .value = val }) catch continue;
                }
            }
        }

        try self.component_cache.put(self.allocator, name, .{
            .name = name,
            .symbol_name = symbol_name,
            .footprint_name = footprint_name,
            .pinout_name = pinout_name,
            .properties = props.toOwnedSlice(self.allocator) catch &.{},
            .is_family = false,
            .param_type = "",
        });
    }

    fn loadComponentFamily(self: *Evaluator, name: []const u8, node: Node) EvalError!void {
        const children = node.asList() orelse return EvalError.InvalidForm;
        var symbol_name: []const u8 = "";
        var footprint_name: []const u8 = "";
        var param_type: []const u8 = "";

        for (children[1..]) |child| {
            if (child.isForm("symbol")) {
                const cl = child.asList().?;
                if (cl.len >= 2) symbol_name = cl[1].asAtom() orelse "";
            }
            if (child.isForm("footprint")) {
                const cl = child.asList().?;
                if (cl.len >= 2) footprint_name = cl[1].asAtom() orelse "";
            }
            if (child.isForm("parameter")) {
                const cl = child.asList().?;
                if (cl.len >= 3) param_type = cl[2].asAtom() orelse "";
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

    fn evalDefmodule(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
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

    fn callModule(self: *Evaluator, mod: ModuleDef, call_args: []const Node, caller_env: *Env) EvalError!Value {
        // Evaluate call arguments
        var arg_values: std.ArrayListUnmanaged(Value) = .empty;
        defer arg_values.deinit(self.allocator);
        for (call_args) |arg| {
            const v = try self.evalNode(arg, caller_env);
            try arg_values.append(self.allocator, v);
        }

        if (arg_values.items.len != mod.params.len) return EvalError.ArityError;

        // Create module scope with parameter bindings
        var mod_env = Env.init(self.allocator, mod.imports);
        defer mod_env.deinit();
        for (mod.params, 0..) |param, i| {
            try mod_env.put(param, arg_values.items[i]);
        }

        // Evaluate module body
        return self.evalNodes(mod.body, &mod_env);
    }

    fn evalDesignBlock(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
        if (args.len < 1) return EvalError.ArityError;

        // First arg is name (could be computed via fmt)
        const name_val = try self.evalNode(args[0], env);
        const name = name_val.asString() orelse return EvalError.TypeError;

        var instances: std.ArrayListUnmanaged(Instance) = .empty;
        var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
        var ports: std.ArrayListUnmanaged(Port) = .empty;
        var notes: std.ArrayListUnmanaged(Note) = .empty;
        var groups: std.ArrayListUnmanaged(Group) = .empty;
        var sections: std.ArrayListUnmanaged(env_mod.Section) = .empty;

        const NetTie = struct { a: []const u8, b: []const u8 };
        var net_ties: std.ArrayListUnmanaged(NetTie) = .empty;
        var sub_blocks: std.ArrayListUnmanaged(SubBlock) = .empty;

        // Pre-scan: register all explicit ref-des to avoid auto-counter collisions
        for (args[1..]) |form| {
            const form_children = form.asList() orelse continue;
            if (form_children.len < 2) continue;
            const form_name = form_children[0].asAtom() orelse continue;
            if (std.mem.eql(u8, form_name, "instance") or std.mem.eql(u8, form_name, "to-gnd") or std.mem.eql(u8, form_name, "to-rail") or std.mem.eql(u8, form_name, "series")) {
                const ref_node = form_children[1];
                const ref_str = ref_node.asAtom() orelse (ref_node.asString() orelse continue);
                self.registerRefDes(ref_str);
            } else if (std.mem.eql(u8, form_name, "section")) {
                // Also scan inside sections for ref-des
                for (form_children[2..]) |sf| {
                    const sf_children = sf.asList() orelse continue;
                    if (sf_children.len < 2) continue;
                    const sf_name = sf_children[0].asAtom() orelse continue;
                    if (std.mem.eql(u8, sf_name, "instance") or std.mem.eql(u8, sf_name, "to-gnd") or std.mem.eql(u8, sf_name, "to-rail") or std.mem.eql(u8, sf_name, "series")) {
                        const ref_node = sf_children[1];
                        const ref_str = ref_node.asAtom() orelse (ref_node.asString() orelse continue);
                        self.registerRefDes(ref_str);
                    }
                }
            }
        }

        for (args[1..]) |form| {
            const form_children = form.asList() orelse continue;
            if (form_children.len == 0) continue;
            const form_name = form_children[0].asAtom() orelse continue;

            if (std.mem.eql(u8, form_name, "instance")) {
                const result = try self.buildInstance(form_children[1..], env);
                self.registerRefDes(result.instance.ref_des);
                try instances.append(self.allocator, result.instance);
                for (result.pin_nets) |pn| {
                    try all_pin_nets.append(self.allocator, pn);
                }
                for (result.inline_notes) |note| {
                    try notes.append(self.allocator, note);
                }
                // Auto pin aliases: if package/symbol has pin names, create net-ties
                {
                    const comp_data = self.component_cache.get(result.instance.component);
                    const pin_lookup_name = if (comp_data) |cd| (if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name) else result.instance.symbol;
                    if (pin_lookup_name.len > 0) {
                        if (self.getSymbolPins(pin_lookup_name)) |sym_pins| {
                            for (result.pin_nets) |pn| {
                                if (sym_pins.get(pn.pin)) |func_name| {
                                    if (pn.net.len > 0 and !std.mem.eql(u8, pn.net, func_name)) {
                                        try net_ties.append(self.allocator, .{ .a = pn.net, .b = func_name });
                                    }
                                }
                            }
                        }
                    }
                }
            } else if (std.mem.eql(u8, form_name, "port")) {
                const port = try self.buildPort(form_children[1..], env);
                try ports.append(self.allocator, port);
            } else if (std.mem.eql(u8, form_name, "note")) {
                const note = try self.buildNote(form_children[1..], env);
                try notes.append(self.allocator, note);
            } else if (std.mem.eql(u8, form_name, "group")) {
                const group = try self.buildGroup(form_children[1..], env);
                try groups.append(self.allocator, group);
            } else if (std.mem.eql(u8, form_name, "sub-block")) {
                const sb = try self.buildSubBlock(form_children[1..], env);
                try sub_blocks.append(self.allocator, sb);
            } else if (std.mem.eql(u8, form_name, "section")) {
                // (section "name" <child-forms...>)
                // Wrapping section: processes child forms and groups instances/pin_groups
                if (form_children.len < 2) continue;
                const sec_name_val = try self.evalNode(form_children[1], env);
                const sec_name = sec_name_val.asString() orelse continue;
                var sec_instances: std.ArrayListUnmanaged(Instance) = .empty;
                var sec_pin_groups: std.ArrayListUnmanaged(env_mod.PinGroup) = .empty;
                var sec_description: []const u8 = "";
                var sec_notes: std.ArrayListUnmanaged([]const u8) = .empty;
                var sec_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
                var sec_calcs: std.ArrayListUnmanaged(env_mod.CalcBlock) = .empty;

                for (form_children[2..]) |sf| {
                    const sf_children = sf.asList() orelse continue;
                    if (sf_children.len == 0) continue;
                    const sf_name = sf_children[0].asAtom() orelse continue;

                    if (std.mem.eql(u8, sf_name, "description")) {
                        if (sf_children.len >= 2) {
                            const desc_val = try self.evalNode(sf_children[1], env);
                            sec_description = desc_val.asString() orelse "";
                        }
                    } else if (std.mem.eql(u8, sf_name, "note")) {
                        if (sf_children.len >= 2) {
                            const note_val = try self.evalNode(sf_children[1], env);
                            if (note_val.asString()) |text| {
                                sec_notes.append(self.allocator, text) catch {};
                            }
                        }
                    } else if (std.mem.eql(u8, sf_name, "in") or std.mem.eql(u8, sf_name, "out") or std.mem.eql(u8, sf_name, "io")) {
                        // (in "NET" signal-type [voltage] [:role R] [:protocol P])
                        // (io "NET1" "NET2" ... [:protocol P])
                        if (sf_children.len < 2) continue;
                        const direction: env_mod.PortDirection = if (std.mem.eql(u8, sf_name, "in")) .in else if (std.mem.eql(u8, sf_name, "out")) .out else .io;
                        var port_name: []const u8 = "";
                        var sig_type: env_mod.SignalType = .signal;
                        var voltage: ?f64 = null;
                        var role: []const u8 = "";
                        var protocol: []const u8 = "";
                        var group_list: std.ArrayListUnmanaged([]const u8) = .empty;

                        var si: usize = 1;
                        while (si < sf_children.len) : (si += 1) {
                            const arg = sf_children[si];
                            // Check for keyword args (:role, :protocol)
                            if (arg.asAtom()) |atom| {
                                if (std.mem.eql(u8, atom, "role")) {
                                    si += 1;
                                    if (si < sf_children.len) {
                                        role = sf_children[si].asAtom() orelse (sf_children[si].asString() orelse "");
                                    }
                                    continue;
                                } else if (std.mem.eql(u8, atom, "protocol")) {
                                    si += 1;
                                    if (si < sf_children.len) {
                                        protocol = sf_children[si].asAtom() orelse (sf_children[si].asString() orelse "");
                                    }
                                    continue;
                                }
                                // Signal type keyword
                                if (std.mem.eql(u8, atom, "power")) { sig_type = .power; continue; }
                                if (std.mem.eql(u8, atom, "signal")) { sig_type = .signal; continue; }
                                if (std.mem.eql(u8, atom, "clock")) { sig_type = .clock; continue; }
                                if (std.mem.eql(u8, atom, "data")) { sig_type = .data; continue; }
                                if (std.mem.eql(u8, atom, "differential")) { sig_type = .differential; continue; }
                                // Unknown atom — skip (don't try to eval as variable)
                                continue;
                            }
                            // Try as string or number literal
                            if (arg.asString()) |s| {
                                if (port_name.len == 0) {
                                    port_name = s;
                                } else {
                                    try group_list.append(self.allocator, s);
                                }
                            } else if (arg.asNumber()) |n| {
                                voltage = n;
                            }
                        }
                        if (port_name.len > 0) {
                            try sec_ports.append(self.allocator, .{
                                .name = port_name,
                                .direction = direction,
                                .signal_type = sig_type,
                                .voltage = voltage,
                                .group = group_list.toOwnedSlice(self.allocator) catch &.{},
                                .role = role,
                                .protocol = protocol,
                            });
                        }
                    } else if (std.mem.eql(u8, sf_name, "calc")) {
                        // (calc "name" (let var expr) (assert-range ...) ...)
                        if (sf_children.len < 2) continue;
                        const calc_name_val = try self.evalNode(sf_children[1], env);
                        const calc_name = calc_name_val.asString() orelse continue;
                        var calc_env = env_mod.Env.init(self.allocator, env);
                        var calc_results: std.ArrayListUnmanaged(env_mod.CalcResult) = .empty;

                        for (sf_children[2..]) |cf| {
                            const cf_children = cf.asList() orelse continue;
                            if (cf_children.len == 0) continue;
                            const cf_name = cf_children[0].asAtom() orelse continue;
                            if (std.mem.eql(u8, cf_name, "let")) {
                                if (cf_children.len >= 3) {
                                    const var_name = cf_children[1].asAtom() orelse continue;
                                    const var_val = try self.evalNode(cf_children[2], &calc_env);
                                    try calc_env.put(var_name, var_val);
                                    if (var_val.asNumber()) |n| {
                                        try calc_results.append(self.allocator, .{ .name = var_name, .value = n });
                                    }
                                }
                            } else if (std.mem.eql(u8, cf_name, "assert-range")) {
                                if (cf_children.len >= 5) {
                                    const val = try self.evalNode(cf_children[1], &calc_env);
                                    const lo = try self.evalNode(cf_children[2], &calc_env);
                                    const hi = try self.evalNode(cf_children[3], &calc_env);
                                    const label_val = try self.evalNode(cf_children[4], &calc_env);
                                    const v = val.asNumber() orelse continue;
                                    const lo_v = lo.asNumber() orelse continue;
                                    const hi_v = hi.asNumber() orelse continue;
                                    const label = label_val.asString() orelse "?";
                                    const passed = v >= lo_v and v <= hi_v;
                                    const msg = std.fmt.allocPrint(self.allocator, "{s}: {d:.3} in [{d:.3}, {d:.3}]", .{ label, v, lo_v, hi_v }) catch continue;
                                    try self.assertions.append(self.allocator, .{ .passed = passed, .message = msg });
                                }
                            } else if (std.mem.eql(u8, cf_name, "assert")) {
                                if (cf_children.len >= 3) {
                                    const cond_val = try self.evalNode(cf_children[1], &calc_env);
                                    const msg_val = try self.evalNode(cf_children[2], &calc_env);
                                    const msg = msg_val.asString() orelse "assertion";
                                    try self.assertions.append(self.allocator, .{ .passed = cond_val.isTruthy(), .message = msg });
                                }
                            }
                        }
                        calc_env.deinit();
                        try sec_calcs.append(self.allocator, .{
                            .name = calc_name,
                            .results = calc_results.toOwnedSlice(self.allocator) catch &.{},
                        });
                    } else if (std.mem.eql(u8, sf_name, "instance")) {
                        const result = try self.buildInstance(sf_children[1..], env);
                        self.registerRefDes(result.instance.ref_des);
                        try instances.append(self.allocator, result.instance);
                        try sec_instances.append(self.allocator, result.instance);
                        for (result.pin_nets) |pn| try all_pin_nets.append(self.allocator, pn);
                        for (result.inline_notes) |note| try notes.append(self.allocator, note);
                        // Auto pin aliases
                        {
                            const comp_data = self.component_cache.get(result.instance.component);
                            const pin_lookup_name = if (comp_data) |cd| (if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name) else result.instance.symbol;
                            if (pin_lookup_name.len > 0) {
                                if (self.getSymbolPins(pin_lookup_name)) |sym_pins| {
                                    for (result.pin_nets) |pn| {
                                        if (sym_pins.get(pn.pin)) |func_name| {
                                            if (pn.net.len > 0 and !std.mem.eql(u8, pn.net, func_name)) {
                                                try net_ties.append(self.allocator, .{ .a = pn.net, .b = func_name });
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else if (std.mem.eql(u8, sf_name, "pins")) {
                        // (pins "REF" (pin ...) (pin ...))
                        if (sf_children.len < 2) continue;
                        const pins_ref_val = try self.evalNode(sf_children[1], env);
                        const pins_ref = pins_ref_val.asString() orelse continue;

                        // Resolve pinout for pin function names
                        const pin_func_map: ?*const std.StringHashMapUnmanaged([]const u8) = pfm_blk: {
                            // Find the instance to get its component
                            for (instances.items) |inst| {
                                if (std.mem.eql(u8, inst.ref_des, pins_ref)) {
                                    const comp_data = self.component_cache.get(inst.component);
                                    const pln = if (comp_data) |cd| (if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name) else inst.symbol;
                                    if (pln.len > 0) break :pfm_blk self.getSymbolPins(pln);
                                    break;
                                }
                            }
                            break :pfm_blk null;
                        };

                        var pg_pins: std.ArrayListUnmanaged(env_mod.PartPin) = .empty;
                        for (sf_children[2..]) |pin_form| {
                            if (pin_form.isForm("pin")) {
                                const pin_children = pin_form.asList() orelse continue;
                                if (pin_children.len < 3) continue;
                                const net_val = try self.evalNode(pin_children[pin_children.len - 1], env);
                                const net_name = net_val.asString() orelse continue;
                                for (pin_children[1 .. pin_children.len - 1]) |pin_node| {
                                    const raw = self.pinId(pin_node) orelse continue;
                                    // Resolve function name → physical pin ID
                                    const pn = if (pin_func_map) |pm| (self.resolvePinName(pm, raw) orelse raw) else raw;
                                    try all_pin_nets.append(self.allocator, .{
                                        .ref_des = pins_ref,
                                        .pin = pn,
                                        .net = net_name,
                                    });
                                    try pg_pins.append(self.allocator, .{
                                        .pin = pn,
                                        .net = net_name,
                                        .pin_name = if (pin_func_map) |m| (m.get(pn) orelse "") else "",
                                    });
                                    // Auto pin alias
                                    if (pin_func_map) |m| {
                                        if (m.get(pn)) |func_name| {
                                            if (net_name.len > 0 and !std.mem.eql(u8, net_name, func_name)) {
                                                try net_ties.append(self.allocator, .{ .a = net_name, .b = func_name });
                                            }
                                        }
                                    }
                                }
                            } else if (pin_form.isForm("bus")) {
                                // (bus "PREFIX" (pin1 pin2 pin3 ...))
                                // Expands to (pin pin1 "PREFIX0") (pin pin2 "PREFIX1") ...
                                const bus_children = pin_form.asList() orelse continue;
                                if (bus_children.len < 3) continue;
                                const bus_prefix_val = try self.evalNode(bus_children[1], env);
                                const bus_prefix = bus_prefix_val.asString() orelse continue;
                                // Remaining children are pin IDs (atoms), possibly in a nested list
                                var bus_idx: u32 = 0;
                                for (bus_children[2..]) |bus_node| {
                                    if (bus_node.asList()) |bus_list| {
                                        // Nested list of pin IDs: (pin1 pin2 ...)
                                        for (bus_list) |bp| {
                                            const raw = self.pinId(bp) orelse continue;
                                            const pn = if (pin_func_map) |pm| (self.resolvePinName(pm, raw) orelse raw) else raw;
                                            const bus_net = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ bus_prefix, bus_idx }) catch continue;
                                            try all_pin_nets.append(self.allocator, .{
                                                .ref_des = pins_ref,
                                                .pin = pn,
                                                .net = bus_net,
                                            });
                                            try pg_pins.append(self.allocator, .{
                                                .pin = pn,
                                                .net = bus_net,
                                                .pin_name = if (pin_func_map) |m| (m.get(pn) orelse "") else "",
                                            });
                                            if (pin_func_map) |m| {
                                                if (m.get(pn)) |func_name| {
                                                    if (bus_net.len > 0 and !std.mem.eql(u8, bus_net, func_name)) {
                                                        try net_ties.append(self.allocator, .{ .a = bus_net, .b = func_name });
                                                    }
                                                }
                                            }
                                            bus_idx += 1;
                                        }
                                    } else {
                                        // Individual pin ID atom
                                        const raw = self.pinId(bus_node) orelse continue;
                                        const pn = if (pin_func_map) |pm| (self.resolvePinName(pm, raw) orelse raw) else raw;
                                        const bus_net = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ bus_prefix, bus_idx }) catch continue;
                                        try all_pin_nets.append(self.allocator, .{
                                            .ref_des = pins_ref,
                                            .pin = pn,
                                            .net = bus_net,
                                        });
                                        try pg_pins.append(self.allocator, .{
                                            .pin = pn,
                                            .net = bus_net,
                                            .pin_name = if (pin_func_map) |m| (m.get(pn) orelse "") else "",
                                        });
                                        if (pin_func_map) |m| {
                                            if (m.get(pn)) |func_name| {
                                                if (bus_net.len > 0 and !std.mem.eql(u8, bus_net, func_name)) {
                                                    try net_ties.append(self.allocator, .{ .a = bus_net, .b = func_name });
                                                }
                                            }
                                        }
                                        bus_idx += 1;
                                    }
                                }
                            }
                        }
                        const pg_slice = pg_pins.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
                        try sec_pin_groups.append(self.allocator, .{
                            .ref_des = pins_ref,
                            .pins = pg_slice,
                        });
                        // Also create a Part on the referenced instance for the renderer
                        for (instances.items) |*inst| {
                            if (std.mem.eql(u8, inst.ref_des, pins_ref)) {
                                var existing_parts: std.ArrayListUnmanaged(env_mod.Part) = .empty;
                                for (inst.parts) |p| try existing_parts.append(self.allocator, p);
                                try existing_parts.append(self.allocator, .{
                                    .name = sec_name,
                                    .pins = pg_slice,
                                });
                                inst.parts = existing_parts.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
                                break;
                            }
                        }
                    } else if (std.mem.eql(u8, sf_name, "decouple")) {
                        if (sf_children.len < 3) continue;
                        const dec_first_val = try self.evalNode(sf_children[1], env);
                        const pre_count = instances.items.len;

                        // Multi-net form: (decouple (comp "val") COUNT per-pin REF "NET1" "NET2" ...)
                        if (dec_first_val == .component or dec_first_val == .component_instance) {
                            if (sf_children.len < 6) continue;
                            for (sf_children[5..]) |mn_node| {
                                const mn_val = try self.evalNode(mn_node, env);
                                const mn_net = mn_val.asString() orelse continue;
                                try self.emitDecoupleItems(sf_children[1..5], mn_net, env, &instances, &all_pin_nets);
                            }
                        } else {
                            const net_name = dec_first_val.asString() orelse continue;
                            var has_sub_forms = false;
                            for (sf_children[2..]) |ssf| {
                                if (ssf.isForm("bulk") or ssf.isForm("bypass")) { has_sub_forms = true; break; }
                            }
                            if (has_sub_forms) {
                                for (sf_children[2..]) |ssf| {
                                    if (ssf.isForm("bulk") or ssf.isForm("bypass")) {
                                        const sub = ssf.asList().?;
                                        try self.emitDecoupleItems(sub[1..], net_name, env, &instances, &all_pin_nets);
                                    }
                                }
                            } else {
                                try self.emitDecoupleItems(sf_children[2..], net_name, env, &instances, &all_pin_nets);
                            }
                        }
                        // Add newly created instances to section
                        for (instances.items[pre_count..]) |new_inst| {
                            try sec_instances.append(self.allocator, new_inst);
                        }
                    } else if (std.mem.eql(u8, sf_name, "to-gnd")) {
                        if (sf_children.len < 3) continue;
                        const tg_first_val = try self.evalNode(sf_children[1], env);

                        // Multi-net form: (to-gnd (comp "val") "NET1" "NET2" ...)
                        if (tg_first_val == .component or tg_first_val == .component_instance) {
                            const tg_comp_offset = componentSourceOffset(sf_children[1]);
                            for (sf_children[2..]) |net_node| {
                                const net_val = try self.evalNode(net_node, env);
                                const tg_net = net_val.asString() orelse continue;
                                const ref = try self.nextRefDes(componentPrefix(componentFamily(tg_first_val)));
                                const tg_inst = self.instanceFromValue(tg_first_val, ref, tg_comp_offset) orelse continue;
                                try instances.append(self.allocator, tg_inst);
                                try sec_instances.append(self.allocator, tg_inst);
                                try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "1", .net = tg_net });
                                try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "2", .net = "GND" });
                            }
                        } else {
                            // Original form: (to-gnd "REF" (comp "val") "NET")
                            if (sf_children.len < 4) continue;
                            const tg_ref_des = tg_first_val.asString() orelse continue;
                            const comp_val = try self.evalNode(sf_children[2], env);
                            const tg_comp_offset = componentSourceOffset(sf_children[2]);
                            const ta = try self.parseTrailingArgs(sf_children[3..], env);
                            if (ta.nets.items.len == 0) continue;
                            var tg_inst = self.instanceFromValue(comp_val, tg_ref_des, tg_comp_offset) orelse continue;
                            self.mergeInstanceProperties(&tg_inst, ta.props.items);
                            self.registerRefDes(tg_ref_des);
                            try instances.append(self.allocator, tg_inst);
                            try sec_instances.append(self.allocator, tg_inst);
                            try all_pin_nets.append(self.allocator, .{ .ref_des = tg_ref_des, .pin = "1", .net = ta.nets.items[0] });
                            try all_pin_nets.append(self.allocator, .{ .ref_des = tg_ref_des, .pin = "2", .net = "GND" });
                            if (ta.note) |text| try notes.append(self.allocator, .{ .ref_des = tg_ref_des, .text = text });
                        }
                    } else if (std.mem.eql(u8, sf_name, "to-rail")) {
                        if (sf_children.len < 5) continue;
                        const tr_ref_des = (try self.evalNode(sf_children[1], env)).asString() orelse continue;
                        const tr_comp_val = try self.evalNode(sf_children[2], env);
                        const tr_comp_offset = componentSourceOffset(sf_children[2]);
                        const ta = try self.parseTrailingArgs(sf_children[3..], env);
                        if (ta.nets.items.len < 2) continue;
                        var tr_inst = self.instanceFromValue(tr_comp_val, tr_ref_des, tr_comp_offset) orelse continue;
                        self.mergeInstanceProperties(&tr_inst, ta.props.items);
                        self.registerRefDes(tr_ref_des);
                        try instances.append(self.allocator, tr_inst);
                        try sec_instances.append(self.allocator, tr_inst);
                        try all_pin_nets.append(self.allocator, .{ .ref_des = tr_ref_des, .pin = "1", .net = ta.nets.items[0] });
                        try all_pin_nets.append(self.allocator, .{ .ref_des = tr_ref_des, .pin = "2", .net = ta.nets.items[1] });
                        if (ta.note) |text| try notes.append(self.allocator, .{ .ref_des = tr_ref_des, .text = text });
                    } else if (std.mem.eql(u8, sf_name, "series")) {
                        if (sf_children.len < 5) continue;
                        const s_ref = (try self.evalNode(sf_children[1], env)).asString() orelse continue;
                        const s_comp_val = try self.evalNode(sf_children[2], env);
                        const s_comp_offset = componentSourceOffset(sf_children[2]);
                        const ta = try self.parseTrailingArgs(sf_children[3..], env);
                        if (ta.nets.items.len < 2) continue;
                        var s_inst = self.instanceFromValue(s_comp_val, s_ref, s_comp_offset) orelse continue;
                        self.mergeInstanceProperties(&s_inst, ta.props.items);
                        self.registerRefDes(s_ref);
                        try instances.append(self.allocator, s_inst);
                        try sec_instances.append(self.allocator, s_inst);
                        try all_pin_nets.append(self.allocator, .{ .ref_des = s_ref, .pin = "1", .net = ta.nets.items[0] });
                        try all_pin_nets.append(self.allocator, .{ .ref_des = s_ref, .pin = "2", .net = ta.nets.items[1] });
                        if (ta.note) |text| try notes.append(self.allocator, .{ .ref_des = s_ref, .text = text });
                    } else if (std.mem.eql(u8, sf_name, "short") or std.mem.eql(u8, sf_name, "net-tie")) {
                        if (sf_children.len >= 3) {
                            const a_val = try self.evalNode(sf_children[1], env);
                            const b_val = try self.evalNode(sf_children[2], env);
                            const a = a_val.asString() orelse continue;
                            const b = b_val.asString() orelse continue;
                            try net_ties.append(self.allocator, .{ .a = a, .b = b });
                        }
                    }
                }

                try sections.append(self.allocator, .{
                    .name = sec_name,
                    .description = sec_description,
                    .notes = sec_notes.toOwnedSlice(self.allocator) catch &.{},
                    .instances = sec_instances.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
                    .pin_groups = sec_pin_groups.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
                    .ports = sec_ports.toOwnedSlice(self.allocator) catch &.{},
                    .calcs = sec_calcs.toOwnedSlice(self.allocator) catch &.{},
                });
            } else if (std.mem.eql(u8, form_name, "net-tie") or std.mem.eql(u8, form_name, "short")) {
                // (short "NET_A" "NET_B") or (net-tie "NET_A" "NET_B")
                if (form_children.len >= 3) {
                    const a_val = try self.evalNode(form_children[1], env);
                    const b_val = try self.evalNode(form_children[2], env);
                    const a = a_val.asString() orelse continue;
                    const b = b_val.asString() orelse continue;
                    try net_ties.append(self.allocator, .{ .a = a, .b = b });
                }
            } else if (std.mem.eql(u8, form_name, "series")) {
                if (form_children.len < 5) continue;
                const s_ref = (try self.evalNode(form_children[1], env)).asString() orelse continue;
                const s_comp_val = try self.evalNode(form_children[2], env);
                const s_comp_offset = componentSourceOffset(form_children[2]);
                const ta = try self.parseTrailingArgs(form_children[3..], env);
                if (ta.nets.items.len < 2) continue;
                var s_inst = self.instanceFromValue(s_comp_val, s_ref, s_comp_offset) orelse continue;
                self.mergeInstanceProperties(&s_inst, ta.props.items);
                self.registerRefDes(s_ref);
                try instances.append(self.allocator, s_inst);
                try all_pin_nets.append(self.allocator, .{ .ref_des = s_ref, .pin = "1", .net = ta.nets.items[0] });
                try all_pin_nets.append(self.allocator, .{ .ref_des = s_ref, .pin = "2", .net = ta.nets.items[1] });
                if (ta.note) |text| try notes.append(self.allocator, .{ .ref_des = s_ref, .text = text });
            } else if (std.mem.eql(u8, form_name, "decouple")) {
                // (decouple "NET" (comp "val") COUNT per-pin REF)
                // (decouple "NET" (bulk ...) (bypass ...))
                // (decouple (comp "val") COUNT per-pin REF "NET1" "NET2" ...)
                if (form_children.len < 3) continue;
                const first_val = try self.evalNode(form_children[1], env);

                // Multi-net form: (decouple (comp "val") COUNT per-pin REF "NET1" "NET2" ...)
                if (first_val == .component or first_val == .component_instance) {
                    if (form_children.len < 6) continue;
                    for (form_children[5..]) |mn_node| {
                        const mn_val = try self.evalNode(mn_node, env);
                        const mn_net = mn_val.asString() orelse continue;
                        try self.emitDecoupleItems(form_children[1..5], mn_net, env, &instances, &all_pin_nets);
                    }
                } else {
                    const net_name = first_val.asString() orelse continue;

                    // Check if children are (bulk ...) / (bypass ...) sub-forms
                    var has_sub_forms = false;
                    for (form_children[2..]) |sf| {
                        if (sf.isForm("bulk") or sf.isForm("bypass")) {
                            has_sub_forms = true;
                            break;
                        }
                    }

                    if (has_sub_forms) {
                        for (form_children[2..]) |sf| {
                            if (sf.isForm("bulk") or sf.isForm("bypass")) {
                                const sub = sf.asList().?;
                                try self.emitDecoupleItems(sub[1..], net_name, env, &instances, &all_pin_nets);
                            }
                        }
                    } else {
                        try self.emitDecoupleItems(form_children[2..], net_name, env, &instances, &all_pin_nets);
                    }
                }
            } else if (std.mem.eql(u8, form_name, "to-gnd")) {
                if (form_children.len < 3) continue;
                const tg_first_val = try self.evalNode(form_children[1], env);

                if (tg_first_val == .component or tg_first_val == .component_instance) {
                    const tg_comp_offset = componentSourceOffset(form_children[1]);
                    for (form_children[2..]) |net_node| {
                        const net_val = try self.evalNode(net_node, env);
                        const tg_net = net_val.asString() orelse continue;
                        const ref = try self.nextRefDes(componentPrefix(componentFamily(tg_first_val)));
                        const tg_inst = self.instanceFromValue(tg_first_val, ref, tg_comp_offset) orelse continue;
                        try instances.append(self.allocator, tg_inst);
                        try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "1", .net = tg_net });
                        try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "2", .net = "GND" });
                    }
                } else {
                    if (form_children.len < 4) continue;
                    const ref_des = tg_first_val.asString() orelse continue;
                    const comp_val = try self.evalNode(form_children[2], env);
                    const tg_comp_offset = componentSourceOffset(form_children[2]);
                    const ta = try self.parseTrailingArgs(form_children[3..], env);
                    if (ta.nets.items.len == 0) continue;
                    var tg_inst = self.instanceFromValue(comp_val, ref_des, tg_comp_offset) orelse continue;
                    self.mergeInstanceProperties(&tg_inst, ta.props.items);
                    self.registerRefDes(ref_des);
                    try instances.append(self.allocator, tg_inst);
                    try all_pin_nets.append(self.allocator, .{ .ref_des = ref_des, .pin = "1", .net = ta.nets.items[0] });
                    try all_pin_nets.append(self.allocator, .{ .ref_des = ref_des, .pin = "2", .net = "GND" });
                    if (ta.note) |text| try notes.append(self.allocator, .{ .ref_des = ref_des, .text = text });
                }
            } else if (std.mem.eql(u8, form_name, "to-rail")) {
                if (form_children.len < 5) continue;
                const tr_ref = (try self.evalNode(form_children[1], env)).asString() orelse continue;
                const tr_comp_val = try self.evalNode(form_children[2], env);
                const tr_comp_offset = componentSourceOffset(form_children[2]);
                const ta = try self.parseTrailingArgs(form_children[3..], env);
                if (ta.nets.items.len < 2) continue;
                var tr_inst = self.instanceFromValue(tr_comp_val, tr_ref, tr_comp_offset) orelse continue;
                self.mergeInstanceProperties(&tr_inst, ta.props.items);
                self.registerRefDes(tr_ref);
                try instances.append(self.allocator, tr_inst);
                try all_pin_nets.append(self.allocator, .{ .ref_des = tr_ref, .pin = "1", .net = ta.nets.items[0] });
                try all_pin_nets.append(self.allocator, .{ .ref_des = tr_ref, .pin = "2", .net = ta.nets.items[1] });
                if (ta.note) |text| try notes.append(self.allocator, .{ .ref_des = tr_ref, .text = text });
            }
            // Ignore config and other unknown forms for now
        }

        // Build nets from collected pin-net declarations
        // Group by net name, collecting all pins for each net
        var net_map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(PinRef)) = .empty;
        for (all_pin_nets.items) |pn| {
            const gop = net_map.getOrPut(self.allocator, pn.net) catch return EvalError.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            gop.value_ptr.append(self.allocator, .{ .ref_des = pn.ref_des, .pin = pn.pin }) catch return EvalError.OutOfMemory;
        }
        // Apply net-ties: merge two nets into one.
        // The surviving name is the net with more pins (keeps the "main" net name).
        for (net_ties.items) |nt| {
            const a_pins = net_map.get(nt.a);
            const b_pins = net_map.get(nt.b);
            if (a_pins == null and b_pins == null) continue;

            const a_count = if (a_pins) |p| p.items.len else 0;
            const b_count = if (b_pins) |p| p.items.len else 0;

            // Keep the net with more pins; merge the smaller into the larger
            const keep = if (b_count > a_count) nt.b else nt.a;
            const remove = if (b_count > a_count) nt.a else nt.b;

            if (net_map.get(remove)) |src_pins| {
                const gop = net_map.getOrPut(self.allocator, keep) catch return EvalError.OutOfMemory;
                if (!gop.found_existing) {
                    gop.value_ptr.* = .empty;
                }
                for (src_pins.items) |pin| {
                    gop.value_ptr.append(self.allocator, pin) catch return EvalError.OutOfMemory;
                }
                _ = net_map.remove(remove);
            }
        }

        // Convert to Net slice
        var nets: std.ArrayListUnmanaged(Net) = .empty;
        var net_iter = net_map.iterator();
        while (net_iter.next()) |entry| {
            nets.append(self.allocator, .{
                .name = entry.key_ptr.*,
                .pins = entry.value_ptr.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            }) catch return EvalError.OutOfMemory;
        }

        const block = self.allocator.create(DesignBlock) catch return EvalError.OutOfMemory;
        block.* = .{
            .name = name,
            .instances = instances.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            .nets = nets.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            .ports = ports.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            .notes = notes.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            .groups = groups.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            .sub_blocks = sub_blocks.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            .sections = sections.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        };
        return .{ .design_block = block };
    }

    /// Result of building an instance: the instance + any inline pin-net declarations + notes
    const InstanceResult = struct {
        instance: Instance,
        pin_nets: []const PinNetDecl,
        inline_notes: []const Note,
    };

    const PinNetDecl = struct {
        ref_des: []const u8,
        pin: []const u8,
        net: []const u8,
    };

    fn buildInstance(self: *Evaluator, args: []const Node, env: *Env) EvalError!InstanceResult {
        // (instance "R4" (res-0402 "220k") (pin 1 "NET_A") (pin 2 "NET_B"))
        if (args.len < 2) return EvalError.ArityError;
        const ref_val = try self.evalNode(args[0], env);
        const ref_des = ref_val.asString() orelse return EvalError.TypeError;

        const comp_val = try self.evalNode(args[1], env);
        const comp_offset = componentSourceOffset(args[1]);
        const inst = switch (comp_val) {
            .component => |comp_name| blk: {
                const comp = self.component_cache.get(comp_name) orelse return EvalError.UnboundVariable;
                break :blk Instance{
                    .ref_des = ref_des,
                    .component = comp_name,
                    .value = "",
                    .footprint = comp.footprint_name,
                    .symbol = comp.symbol_name,
                    .properties = comp.properties,
                    .source_offset = comp_offset,
                };
            },
            .component_instance => |ci| blk: {
                const comp = self.component_cache.get(ci.family) orelse return EvalError.UnboundVariable;
                break :blk Instance{
                    .ref_des = ref_des,
                    .component = ci.family,
                    .value = ci.value,
                    .footprint = comp.footprint_name,
                    .symbol = comp.symbol_name,
                    .properties = comp.properties,
                    .attrs = ci.attrs,
                    .source_offset = comp_offset,
                };
            },
            else => return EvalError.TypeError,
        };

        // Resolve pinout for reverse lookup (function_name → pin_id)
        const reverse_pinout: ?*const std.StringHashMapUnmanaged([]const u8) = blk: {
            const comp_data = self.component_cache.get(inst.component);
            const pln = if (comp_data) |cd| (if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name) else inst.symbol;
            if (pln.len > 0) break :blk self.getSymbolPins(pln);
            break :blk null;
        };

        // Parse inline pin declarations:
        //   (pin 1 "NET")               — single pin
        //   (pin 3 4 5 6 7 "NET")       — multiple pins on same net
        //   (connect FUNC "NET" ...)     — connect by function name from pinout
        var pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
        var inline_notes: std.ArrayListUnmanaged(Note) = .empty;
        var inline_props: std.ArrayListUnmanaged(env_mod.Property) = .empty;

        const known_forms = [_][]const u8{ "pin", "note" };

        for (args[2..]) |form| {
            if (form.isForm("note")) {
                const nc = form.asList().?;
                if (nc.len >= 2) {
                    const nv = try self.evalNode(nc[1], env);
                    if (nv.asString()) |text| {
                        try inline_notes.append(self.allocator, .{ .ref_des = ref_des, .text = text });
                    }
                }
            } else if (form.isForm("pin")) {
                try self.parsePinForm(form, ref_des, env, &pin_nets, reverse_pinout);
            } else {
                // Unknown form — treat as inline property: (key "value")
                const fc = form.asList() orelse continue;
                if (fc.len >= 2) {
                    const key = fc[0].asAtom() orelse continue;
                    var is_known = false;
                    for (known_forms) |kf| {
                        if (std.mem.eql(u8, key, kf)) { is_known = true; break; }
                    }
                    if (!is_known) {
                        const val = (try self.evalNode(fc[1], env)).asString() orelse continue;
                        try inline_props.append(self.allocator, .{ .key = key, .value = val });
                    }
                }
            }
        }

        var final_inst = inst;

        // Merge properties: start with component defaults, override with inline
        if (inline_props.items.len > 0) {
            var merged: std.ArrayListUnmanaged(env_mod.Property) = .empty;
            // Add component properties, skipping any overridden by inline
            for (final_inst.properties) |cp| {
                var overridden = false;
                for (inline_props.items) |ip| {
                    if (std.mem.eql(u8, cp.key, ip.key)) { overridden = true; break; }
                }
                if (!overridden) merged.append(self.allocator, cp) catch {};
            }
            // Add all inline properties
            for (inline_props.items) |ip| {
                merged.append(self.allocator, ip) catch {};
            }
            final_inst.properties = merged.toOwnedSlice(self.allocator) catch final_inst.properties;
        }

        return InstanceResult{
            .instance = final_inst,
            .pin_nets = pin_nets.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            .inline_notes = inline_notes.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        };
    }

    fn parsePinForm(self: *Evaluator, form: Node, ref_des: []const u8, env: *Env, pin_nets: *std.ArrayListUnmanaged(PinNetDecl), pinout: ?*const std.StringHashMapUnmanaged([]const u8)) EvalError!void {
        const pin_children = form.asList() orelse return;
        if (pin_children.len < 3) return;
        const net_val = try self.evalNode(pin_children[pin_children.len - 1], env);
        const net_name = net_val.asString() orelse return;
        for (pin_children[1 .. pin_children.len - 1]) |pin_node| {
            const raw = self.pinId(pin_node) orelse continue;
            // Resolve: try as function name first (via pinout), fall back to physical pin ID
            const pn = if (pinout) |pm| (self.resolvePinName(pm, raw) orelse raw) else raw;
            try pin_nets.append(self.allocator, .{
                .ref_des = ref_des,
                .pin = pn,
                .net = net_name,
            });
        }
    }

    /// Build an Instance from a Value (.component or .component_instance),
    /// looking up cached footprint/symbol/properties.
    fn instanceFromValue(self: *Evaluator, val: Value, ref_des: []const u8, source_offset: u32) ?Instance {
        return switch (val) {
            .component => |c| blk: {
                const cd = self.component_cache.get(c) orelse
                    break :blk Instance{ .ref_des = ref_des, .component = c, .value = "", .footprint = "", .symbol = "", .source_offset = source_offset };
                break :blk Instance{ .ref_des = ref_des, .component = c, .value = "", .footprint = cd.footprint_name, .symbol = cd.symbol_name, .properties = cd.properties, .source_offset = source_offset };
            },
            .component_instance => |ci| blk: {
                const cd = self.component_cache.get(ci.family) orelse
                    break :blk Instance{ .ref_des = ref_des, .component = ci.family, .value = ci.value, .footprint = "", .symbol = "", .attrs = ci.attrs, .source_offset = source_offset };
                break :blk Instance{ .ref_des = ref_des, .component = ci.family, .value = ci.value, .footprint = cd.footprint_name, .symbol = cd.symbol_name, .properties = cd.properties, .attrs = ci.attrs, .source_offset = source_offset };
            },
            else => null,
        };
    }

    /// Merge override properties into an instance, replacing matching keys.
    fn mergeInstanceProperties(self: *Evaluator, inst: *Instance, overrides: []const env_mod.Property) void {
        if (overrides.len == 0) return;
        var merged: std.ArrayListUnmanaged(env_mod.Property) = .empty;
        for (inst.properties) |cp| {
            var overridden = false;
            for (overrides) |ip| {
                if (std.mem.eql(u8, cp.key, ip.key)) { overridden = true; break; }
            }
            if (!overridden) merged.append(self.allocator, cp) catch {};
        }
        for (overrides) |ip| merged.append(self.allocator, ip) catch {};
        inst.properties = merged.toOwnedSlice(self.allocator) catch inst.properties;
    }

    /// Parse trailing arguments: extract net names, properties, and optional note.
    const TrailingArgs = struct {
        nets: std.ArrayListUnmanaged([]const u8),
        props: std.ArrayListUnmanaged(env_mod.Property),
        note: ?[]const u8,
    };

    fn parseTrailingArgs(self: *Evaluator, children: []const Node, env: *Env) EvalError!TrailingArgs {
        var result = TrailingArgs{
            .nets = .empty,
            .props = .empty,
            .note = null,
        };
        for (children) |fc| {
            if (fc.asList()) |cl| {
                if (cl.len >= 2) {
                    const k = cl[0].asAtom() orelse continue;
                    if (std.mem.eql(u8, k, "note")) {
                        result.note = cl[1].asString();
                    } else {
                        const v = cl[1].asString() orelse continue;
                        result.props.append(self.allocator, .{ .key = k, .value = v }) catch {};
                    }
                }
            } else {
                const v = (try self.evalNode(fc, env)).asString() orelse continue;
                result.nets.append(self.allocator, v) catch {};
            }
        }
        return result;
    }

    /// Get the component family name from a Value.
    fn componentFamily(val: Value) []const u8 {
        return switch (val) {
            .component => |c| c,
            .component_instance => |ci| ci.family,
            else => "",
        };
    }

    /// Resolve a function name to a physical pin ID using the pinout map.
    /// The pinout maps pin_id → function_name, so we need reverse lookup.
    fn resolvePinName(self: *Evaluator, pinout: *const std.StringHashMapUnmanaged([]const u8), name: []const u8) ?[]const u8 {
        _ = self;
        // Reverse lookup: find the pin_id whose function_name matches
        var iter = pinout.iterator();
        while (iter.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, name)) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }

    /// Emit decoupling cap instances from (comp "val") count/ref pairs.
    fn emitDecoupleItems(
        self: *Evaluator,
        items: []const Node,
        net_name: []const u8,
        env: *Env,
        instances: *std.ArrayListUnmanaged(Instance),
        all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    ) EvalError!void {
        var idx: usize = 0;
        while (idx + 1 < items.len) {
            const comp_val = try self.evalNode(items[idx], env);
            const dec_comp_offset = componentSourceOffset(items[idx]);

            const CompInfo = struct { comp: []const u8, value: []const u8, fp: []const u8, sym: []const u8, attrs: []const []const u8 };
            const comp_info: CompInfo = switch (comp_val) {
                .component => |c| blk: {
                    const cd = self.component_cache.get(c) orelse break :blk .{ .comp = c, .value = "", .fp = "", .sym = "", .attrs = &.{} };
                    break :blk .{ .comp = c, .value = "", .fp = cd.footprint_name, .sym = cd.symbol_name, .attrs = &.{} };
                },
                .component_instance => |ci| blk: {
                    const cd = self.component_cache.get(ci.family) orelse break :blk .{ .comp = ci.family, .value = ci.value, .fp = "", .sym = "", .attrs = ci.attrs };
                    break :blk .{ .comp = ci.family, .value = ci.value, .fp = cd.footprint_name, .sym = cd.symbol_name, .attrs = ci.attrs };
                },
                else => {
                    idx += 2;
                    continue;
                },
            };

            // Syntax: (comp "val") COUNT per-pin REF [PIN]
            // COUNT is required, per-pin keyword is required
            const count_val = items[idx + 1].asNumber() orelse {
                std.debug.print("Error: decouple requires a count after component (net: {s})\n", .{net_name});
                std.debug.print("  Use: (decouple \"{s}\" (comp \"val\") COUNT per-pin REF)\n", .{net_name});
                return EvalError.InvalidForm;
            };
            const count: u32 = @intFromFloat(count_val);
            if (count == 0) { idx += 2; continue; }

            // Expect "per-pin" keyword
            if (idx + 2 >= items.len) { idx += 2; continue; }
            const per_pin_kw = items[idx + 2].asAtom() orelse {
                std.debug.print("Error: decouple expects 'per-pin' keyword (net: {s})\n", .{net_name});
                return EvalError.InvalidForm;
            };
            if (!std.mem.eql(u8, per_pin_kw, "per-pin")) {
                std.debug.print("Error: decouple expects 'per-pin', got '{s}' (net: {s})\n", .{ per_pin_kw, net_name });
                return EvalError.InvalidForm;
            }

            // REF
            if (idx + 3 >= items.len) { idx += 3; continue; }
            const ref_str = items[idx + 3].asAtom() orelse
                (items[idx + 3].asString() orelse {
                idx += 4;
                continue;
            });

            // Check for optional pin specifier: ... REF PIN
            var specific_pin: ?[]const u8 = null;
            if (idx + 4 < items.len) {
                if (items[idx + 4].asList() == null) {
                    if (self.pinId(items[idx + 4])) |pid| {
                        specific_pin = pid;
                    }
                }
            }

            const sub_prefix = try std.fmt.allocPrint(self.allocator, "{s}.{s}.", .{ net_name, ref_str });
            var target_pins: std.ArrayListUnmanaged([]const u8) = .empty;
            defer target_pins.deinit(self.allocator);

            if (specific_pin) |pin| {
                try target_pins.append(self.allocator, pin);
            } else {
                for (all_pin_nets.items) |pn| {
                    if (!std.mem.eql(u8, pn.ref_des, ref_str)) continue;
                    if (std.mem.eql(u8, pn.net, net_name) or std.mem.startsWith(u8, pn.net, sub_prefix)) {
                        try target_pins.append(self.allocator, pn.pin);
                    }
                }
            }

            for (target_pins.items) |target_pin| {
                const sub_net = try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ net_name, ref_str, target_pin });

                var ci: u32 = 0;
                while (ci < count) : (ci += 1) {
                    const ref = try self.nextRefDes('C');
                    try instances.append(self.allocator, .{
                        .ref_des = ref,
                        .component = comp_info.comp,
                        .value = comp_info.value,
                        .footprint = comp_info.fp,
                        .symbol = comp_info.sym,
                        .attrs = comp_info.attrs,
                        .source_offset = dec_comp_offset,
                    });
                    try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "1", .net = sub_net });
                    try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "2", .net = "GND" });
                }

                // Reassign the target component's pin to sub-net
                for (all_pin_nets.items) |*pn| {
                    if (std.mem.eql(u8, pn.ref_des, ref_str) and
                        std.mem.eql(u8, pn.pin, target_pin) and
                        std.mem.eql(u8, pn.net, net_name))
                    {
                        pn.net = sub_net;
                        break;
                    }
                }
            }
            idx += if (specific_pin != null) @as(usize, 5) else @as(usize, 4);
        }
    }

    // buildNet removed — nets are now built from inline (pin N "NET") declarations on instances

    fn buildPort(self: *Evaluator, args: []const Node, env: *Env) EvalError!Port {
        if (args.len < 3) return EvalError.ArityError;
        const name_val = try self.evalNode(args[0], env);
        const net_val = try self.evalNode(args[1], env);
        const dir = args[2].asAtom() orelse return EvalError.InvalidForm;

        var rated_min: ?f64 = null;
        var rated_max: ?f64 = null;
        if (args.len >= 4 and args[3].isForm("rated")) {
            const rated_children = args[3].asList().?;
            if (rated_children.len >= 3) {
                rated_min = rated_children[1].asNumber();
                rated_max = rated_children[2].asNumber();
            }
        }

        return Port{
            .name = name_val.asString() orelse return EvalError.TypeError,
            .net = net_val.asString() orelse return EvalError.TypeError,
            .direction = dir,
            .rated_min = rated_min,
            .rated_max = rated_max,
        };
    }

    fn buildNote(self: *Evaluator, args: []const Node, env: *Env) EvalError!Note {
        if (args.len != 2) return EvalError.ArityError;
        const rd_val = try self.evalNode(args[0], env);
        const text_val = try self.evalNode(args[1], env);
        return Note{
            .ref_des = rd_val.asString() orelse return EvalError.TypeError,
            .text = text_val.asString() orelse return EvalError.TypeError,
        };
    }

    fn buildGroup(self: *Evaluator, args: []const Node, env: *Env) EvalError!Group {
        if (args.len != 2) return EvalError.ArityError;
        const name_val = try self.evalNode(args[0], env);
        const members_node = args[1].asList() orelse return EvalError.InvalidForm;

        var members: std.ArrayListUnmanaged([]const u8) = .empty;
        for (members_node) |m| {
            const s = m.asString() orelse return EvalError.TypeError;
            try members.append(self.allocator, s);
        }

        return Group{
            .name = name_val.asString() orelse return EvalError.TypeError,
            .members = members.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        };
    }

    fn buildSubBlock(self: *Evaluator, args: []const Node, env: *Env) EvalError!SubBlock {
        if (args.len != 2) return EvalError.ArityError;
        const name_val = try self.evalNode(args[0], env);
        const name = name_val.asString() orelse return EvalError.TypeError;

        // Second arg is a module call: (module-name arg1 arg2 ...)
        const call_val = try self.evalNode(args[1], env);
        const block = switch (call_val) {
            .design_block => |b| b,
            else => return EvalError.TypeError,
        };

        return SubBlock{
            .name = name,
            .block = block,
        };
    }

    // ── File loading ────────────────────────────────────────────────────

    fn loadFile(self: *Evaluator, path: []const u8) ?[]const Node {
        if (self.loaded_files.get(path)) |nodes| return nodes;

        const source = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return null;
        // Note: we don't free source because AST references slices into it
        const nodes = parser_mod.parse(self.allocator, source) catch return null;
        self.loaded_files.put(self.allocator, path, nodes) catch return null;
        return nodes;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

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
