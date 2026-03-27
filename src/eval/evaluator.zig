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

    pub const ComponentData = struct {
        name: []const u8,
        symbol_name: []const u8,
        footprint_name: []const u8,
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
        };
    }

    pub fn deinit(self: *Evaluator) void {
        self.assertions.deinit(self.allocator);
        self.loaded_files.deinit(self.allocator);
        self.component_cache.deinit(self.allocator);
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

        // Component-family invocation: (res-0402 "220k")
        if (self.component_cache.get(head_name)) |comp| {
            if (comp.is_family and args.len == 1) {
                const val = try self.evalNode(args[0], env);
                const val_str = val.asString() orelse return EvalError.TypeError;
                return .{ .component_instance = .{
                    .family = head_name,
                    .value = val_str,
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
        if (args.len != 1) return EvalError.ArityError;
        const name = args[0].asAtom() orelse return EvalError.InvalidForm;
        try self.resolveImport(name, env);
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

        for (children[1..]) |child| {
            if (child.isForm("symbol")) {
                const cl = child.asList().?;
                if (cl.len >= 2) symbol_name = cl[1].asAtom() orelse "";
            }
            if (child.isForm("footprint")) {
                const cl = child.asList().?;
                if (cl.len >= 2) footprint_name = cl[1].asAtom() orelse "";
            }
        }

        try self.component_cache.put(self.allocator, name, .{
            .name = name,
            .symbol_name = symbol_name,
            .footprint_name = footprint_name,
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
        var sub_blocks: std.ArrayListUnmanaged(SubBlock) = .empty;

        for (args[1..]) |form| {
            const form_children = form.asList() orelse continue;
            if (form_children.len == 0) continue;
            const form_name = form_children[0].asAtom() orelse continue;

            if (std.mem.eql(u8, form_name, "instance")) {
                const result = try self.buildInstance(form_children[1..], env);
                try instances.append(self.allocator, result.instance);
                for (result.pin_nets) |pn| {
                    try all_pin_nets.append(self.allocator, pn);
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
                // (section "name" (row R) (col C))
                if (form_children.len >= 2) {
                    const sec_name_val = try self.evalNode(form_children[1], env);
                    const sec_name = sec_name_val.asString() orelse continue;
                    var sec_row: i32 = 0;
                    var sec_col: i32 = 0;
                    for (form_children[2..]) |sf| {
                        if (sf.isForm("row")) {
                            const rc = sf.asList().?;
                            if (rc.len >= 2) sec_row = @intFromFloat(rc[1].asNumber() orelse 0);
                        } else if (sf.isForm("col")) {
                            const rc = sf.asList().?;
                            if (rc.len >= 2) sec_col = @intFromFloat(rc[1].asNumber() orelse 0);
                        }
                    }
                    try sections.append(self.allocator, .{ .name = sec_name, .row = sec_row, .col = sec_col });
                }
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

    /// Result of building an instance: the instance + any inline pin-net declarations
    const InstanceResult = struct {
        instance: Instance,
        pin_nets: []const PinNetDecl,
    };

    const PinNetDecl = struct {
        ref_des: []const u8,
        pin: i64,
        net: []const u8,
    };

    fn buildInstance(self: *Evaluator, args: []const Node, env: *Env) EvalError!InstanceResult {
        // (instance "R4" (res-0402 "220k") (pin 1 "NET_A") (pin 2 "NET_B"))
        if (args.len < 2) return EvalError.ArityError;
        const ref_val = try self.evalNode(args[0], env);
        const ref_des = ref_val.asString() orelse return EvalError.TypeError;

        const comp_val = try self.evalNode(args[1], env);
        const inst = switch (comp_val) {
            .component => |comp_name| blk: {
                const comp = self.component_cache.get(comp_name) orelse return EvalError.UnboundVariable;
                break :blk Instance{
                    .ref_des = ref_des,
                    .component = comp_name,
                    .value = "",
                    .footprint = comp.footprint_name,
                    .symbol = comp.symbol_name,
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
                };
            },
            else => return EvalError.TypeError,
        };

        // Parse inline pin declarations and part groupings:
        //   (pin 1 "NET")               — single pin
        //   (pin 3 4 5 6 7 "NET")       — multiple pins on same net
        //   (part "Power" (pin 1 2 3 "VDD") (pin 4 "GND"))  — part grouping
        var pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
        var parts: std.ArrayListUnmanaged(env_mod.Part) = .empty;
        var inst_row: i32 = 0;
        var inst_col: i32 = 0;

        for (args[2..]) |form| {
            if (form.isForm("pin")) {
                try self.parsePinForm(form, ref_des, env, &pin_nets);
            } else if (form.isForm("row")) {
                const rc = form.asList().?;
                if (rc.len >= 2) inst_row = @intFromFloat(rc[1].asNumber() orelse 0);
            } else if (form.isForm("col")) {
                const rc = form.asList().?;
                if (rc.len >= 2) inst_col = @intFromFloat(rc[1].asNumber() orelse 0);
            } else if (form.isForm("part")) {
                const part_children = form.asList().?;
                if (part_children.len < 2) continue;
                const part_name_val = try self.evalNode(part_children[1], env);
                const part_name = part_name_val.asString() orelse continue;

                var part_pins: std.ArrayListUnmanaged(env_mod.PartPin) = .empty;
                var part_row: i32 = 0;
                var part_col: i32 = 0;
                for (part_children[2..]) |pin_form| {
                    if (pin_form.isForm("pin")) {
                        const pin_children = pin_form.asList().?;
                        if (pin_children.len < 3) continue;
                        const net_val = try self.evalNode(pin_children[pin_children.len - 1], env);
                        const net_name = net_val.asString() orelse continue;
                        for (pin_children[1 .. pin_children.len - 1]) |pin_node| {
                            const pin_num = pin_node.asNumber() orelse continue;
                            const pn = @as(i64, @intFromFloat(pin_num));
                            try pin_nets.append(self.allocator, .{
                                .ref_des = ref_des,
                                .pin = pn,
                                .net = net_name,
                            });
                            try part_pins.append(self.allocator, .{
                                .pin = pn,
                                .net = net_name,
                            });
                        }
                    } else if (pin_form.isForm("row")) {
                        const rc = pin_form.asList().?;
                        if (rc.len >= 2) part_row = @intFromFloat(rc[1].asNumber() orelse 0);
                    } else if (pin_form.isForm("col")) {
                        const rc = pin_form.asList().?;
                        if (rc.len >= 2) part_col = @intFromFloat(rc[1].asNumber() orelse 0);
                    }
                }
                try parts.append(self.allocator, .{
                    .name = part_name,
                    .pins = part_pins.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
                    .row = part_row,
                    .col = part_col,
                });
            }
        }

        var final_inst = inst;
        final_inst.parts = parts.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
        final_inst.row = inst_row;
        final_inst.col = inst_col;

        return InstanceResult{
            .instance = final_inst,
            .pin_nets = pin_nets.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        };
    }

    fn parsePinForm(self: *Evaluator, form: Node, ref_des: []const u8, env: *Env, pin_nets: *std.ArrayListUnmanaged(PinNetDecl)) EvalError!void {
        const pin_children = form.asList() orelse return;
        if (pin_children.len < 3) return;
        const net_val = try self.evalNode(pin_children[pin_children.len - 1], env);
        const net_name = net_val.asString() orelse return;
        for (pin_children[1 .. pin_children.len - 1]) |pin_node| {
            const pin_num = pin_node.asNumber() orelse continue;
            try pin_nets.append(self.allocator, .{
                .ref_des = ref_des,
                .pin = @intFromFloat(pin_num),
                .net = net_name,
            });
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
