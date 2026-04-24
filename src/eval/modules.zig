const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;
const ComponentData = Evaluator.ComponentData;
const BusDef = Evaluator.BusDef;

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;
const ModuleDef = env_mod.ModuleDef;

pub fn evalImport(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    // Support multi-import: (import a b c ...)
    if (args.len < 1) return EvalError.ArityError;
    for (args) |arg| {
        const name = arg.asAtom() orelse return EvalError.InvalidForm;
        try resolveImport(self, name, env);
    }
    return .nil;
}

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
            const file_content = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch continue;

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

pub fn loadComponent(self: *Evaluator, name: []const u8, node: Node) EvalError!void {
    const children = node.asList() orelse return EvalError.InvalidForm;
    var symbol_name: []const u8 = "";
    var footprint_name: []const u8 = "";
    var pinout_name: []const u8 = "";

    // Known structural fields (not properties)
    const skip_fields = [_][]const u8{ "symbol", "footprint", "pinout", "component", "parameter", "component-family", "bus", "note" };

    var props: std.ArrayListUnmanaged(env_mod.Property) = .empty;
    var buses: std.ArrayListUnmanaged(BusDef) = .empty;

    for (children[1..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        const field = cl[0].asAtom() orelse continue;

        if (std.mem.eql(u8, field, "description")) {
            // Surface the library description on every instance that uses
            // this component so downstream renderers (schematic overview,
            // review doc, BOM) can show it without re-reading lib files.
            const val = cl[1].asString() orelse (cl[1].asAtom() orelse continue);
            props.append(self.allocator, .{ .key = "description", .value = val }) catch continue;
        } else if (std.mem.eql(u8, field, "symbol")) {
            symbol_name = cl[1].asAtom() orelse cl[1].asString() orelse "";
        } else if (std.mem.eql(u8, field, "footprint")) {
            footprint_name = cl[1].asAtom() orelse cl[1].asString() orelse "";
        } else if (std.mem.eql(u8, field, "pinout")) {
            pinout_name = cl[1].asAtom() orelse cl[1].asString() orelse "";
        } else if (std.mem.eql(u8, field, "bus")) {
            // (bus "name" pin1 pin2 pin3 ...)
            const bus_name = cl[1].asString() orelse (cl[1].asAtom() orelse continue);
            var bus_pins: std.ArrayListUnmanaged([]const u8) = .empty;
            for (cl[2..]) |pin_node| {
                const pin_name = pin_node.asAtom() orelse (pin_node.asString() orelse continue);
                bus_pins.append(self.allocator, pin_name) catch continue;
            }
            buses.append(self.allocator, .{
                .name = bus_name,
                .pins = bus_pins.toOwnedSlice(self.allocator) catch &.{},
            }) catch continue;
        } else {
            // Check if it's a known structural field
            var is_structural = false;
            for (skip_fields) |sf| {
                if (std.mem.eql(u8, field, sf)) {
                    is_structural = true;
                    break;
                }
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
        .buses = buses.toOwnedSlice(self.allocator) catch &.{},
        .is_family = false,
        .param_type = "",
    });
}

pub fn loadComponentFamily(self: *Evaluator, name: []const u8, node: Node) EvalError!void {
    const children = node.asList() orelse return EvalError.InvalidForm;
    var symbol_name: []const u8 = "";
    var footprint_name: []const u8 = "";
    var param_type: []const u8 = "";

    for (children[1..]) |child| {
        if (child.isForm("symbol")) {
            const cl = child.asList().?;
            if (cl.len >= 2) symbol_name = cl[1].asAtom() orelse cl[1].asString() orelse "";
        }
        if (child.isForm("footprint")) {
            const cl = child.asList().?;
            if (cl.len >= 2) footprint_name = cl[1].asAtom() orelse cl[1].asString() orelse "";
        }
        if (child.isForm("parameter")) {
            const cl = child.asList().?;
            if (cl.len >= 3) param_type = cl[2].asAtom() orelse cl[2].asString() orelse "";
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

pub fn callModule(self: *Evaluator, mod: ModuleDef, call_args: []const Node, caller_env: *Env) EvalError!Value {
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
