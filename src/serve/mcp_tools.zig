const std = @import("std");
const edit = @import("edit.zig");
const history = @import("history.zig");
const serve_root = @import("../serve.zig");
const render_json = @import("../render_json.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const erc_mod = @import("../erc.zig");
const drc_mod = @import("../drc.zig");
const layout_mod = @import("../layout.zig");
const bom = @import("../bom.zig");
const sexpr_parser = @import("../sexpr/parser.zig");

/// Tools that mutate .sexp files — gated to writer/admin roles.
pub fn isMutationTool(name: []const u8) bool {
    const mutators = [_][]const u8{ "edit_value", "write_design", "restore_version" };
    for (mutators) |m| if (std.mem.eql(u8, name, m)) return true;
    return false;
}

pub const tools_list_result =
    \\{"tools":[
    \\{"name":"list_designs","description":"List design names available in this project (one per .sexp file in src/).","inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
    \\{"name":"read_design","description":"Return the full .sexp source text for a design. Agents should read, then optionally call write_design with an edited version.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Design name (without .sexp)"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"write_design","description":"Create or overwrite a design's .sexp with the full new source text. The previous version is auto-snapshotted before the write. Triggers a live rebuild and returns the new version + snapshot id.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"source":{"type":"string","description":"Full S-expression source for the design"}},"required":["name","source"],"additionalProperties":false}},
    \\{"name":"edit_value","description":"Quick single-value tweak: change a component's value by reference designator (e.g. set C3 to 100nF). Same snapshot/rebuild semantics as write_design.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"ref":{"type":"string","description":"Reference designator like C3, R1, U2"},"value":{"type":"string","description":"New value string"}},"required":["name","ref","value"],"additionalProperties":false}},
    \\{"name":"get_schematic","description":"Fetch the current scene graph JSON for a design. This is the same payload the browser viewer renders.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"get_version","description":"Return the current live version integer for a design. Increments on every mutation.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"run_checks","description":"Run ERC and DRC together on a design. Returns {erc: [...violations], drc: {violations,count} | null}. DRC is null when there's no companion {name}-board.sexp.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"list_history","description":"List snapshot ids for a design, newest first. Each id is a timestamp usable with restore_version.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"restore_version","description":"Restore a design to a prior snapshot. The current state is itself snapshotted first, so the restore is undoable.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"id":{"type":"string","description":"Snapshot id from list_history"}},"required":["name","id"],"additionalProperties":false}}
    \\]}
;

/// Dispatch a tool call. Writes a textual result into `out`. Returns true on
/// success, false on error (caller sets isError on the MCP envelope).
pub fn call(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) bool {
    return callInner(allocator, project_dir, tool_name, args_val, out) catch |err| {
        const msg = @errorName(err);
        const w = out.writer(allocator);
        w.print("error: {s}", .{msg}) catch {};
        return false;
    };
}

fn callInner(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) !bool {
    const w = out.writer(allocator);

    if (std.mem.eql(u8, tool_name, "list_designs")) {
        const names = try listDesignNames(allocator, project_dir);
        try w.writeAll("[");
        for (names, 0..) |n, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(n);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "read_design")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const src = edit.readDesignSourcePub(allocator, project_dir, name) catch |err| return editErrorMsg(out, allocator, err);
        try w.writeAll("{\"source\":");
        try writeJsonString(w, src);
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "write_design")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const source = requireString(args_val, "source") orelse return missingArg(out, allocator, "source");
        const result = edit.writeDesignCore(allocator, project_dir, name, source) catch |err| return editErrorMsg(out, allocator, err);
        try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
        if (result.snapshot) |s| {
            try writeJsonString(w, s);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "get_schematic")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const graph = try renderSceneGraph(allocator, project_dir, name);
        try w.writeAll(graph);
        return true;
    }

    if (std.mem.eql(u8, tool_name, "get_version")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const v = serve_root.getLiveVersion(name);
        try w.print("{{\"version\":{d}}}", .{v});
        return true;
    }

    if (std.mem.eql(u8, tool_name, "edit_value")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const ref = requireString(args_val, "ref") orelse return missingArg(out, allocator, "ref");
        const value = requireString(args_val, "value") orelse return missingArg(out, allocator, "value");
        const result = edit.editValueCore(allocator, project_dir, name, ref, value) catch |err| return editErrorMsg(out, allocator, err);
        try w.print("{{\"ok\":true,\"version\":{d}}}", .{result.version});
        return true;
    }

    if (std.mem.eql(u8, tool_name, "run_checks")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        return try runChecks(allocator, project_dir, name, w);
    }

    if (std.mem.eql(u8, tool_name, "list_history")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const ids = try history.listSnapshots(allocator, project_dir, name);
        try w.writeAll("{\"snapshots\":[");
        for (ids, 0..) |id, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"id\":");
            try writeJsonString(w, id);
            try w.writeAll("}");
        }
        try w.writeAll("]}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "restore_version")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const id = requireString(args_val, "id") orelse return missingArg(out, allocator, "id");
        const result = edit.restoreDesignCore(allocator, project_dir, name, id) catch |err| return editErrorMsg(out, allocator, err);
        try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
        if (result.snapshot) |s| {
            try writeJsonString(w, s);
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("}");
        return true;
    }

    try w.print("error: unknown tool \"{s}\"", .{tool_name});
    return false;
}

fn runChecks(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    w: anytype,
) !bool {
    const path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll("error: build failed");
        return false;
    };

    var block: *env_mod.DesignBlock = undefined;
    var board_def: ?*env_mod.Board = null;
    switch (result) {
        .design_block => |db| {
            block = db;
            const bd_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}-board.sexp", .{ project_dir, name });
            defer allocator.free(bd_path);
            var eval2 = Evaluator.init(allocator, project_dir);
            defer eval2.deinit();
            if (eval2.evalFile(bd_path)) |bd_result| {
                switch (bd_result) {
                    .board => |b| board_def = b,
                    else => {},
                }
            } else |_| {}
        },
        .board => |b| {
            block = b.design;
            board_def = b;
        },
        else => {
            try w.writeAll("error: not a design");
            return false;
        },
    }

    const bom_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, name });
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch {};

    const erc_violations = try erc_mod.runErc(allocator, block);
    const erc_json = try erc_mod.writeViolationsJson(allocator, erc_violations);

    try w.writeAll("{\"erc\":");
    try w.writeAll(erc_json);
    try w.writeAll(",\"drc\":");

    if (board_def) |bd| {
        _ = bd;
        const layout_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.layout", .{ project_dir, name });
        defer allocator.free(layout_path);
        const lay = layout_mod.loadLayout(allocator, layout_path) catch layout_mod.Layout{
            .placements = &.{},
            .traces = &.{},
            .vias = &.{},
            .zone_fills = &.{},
            .rules = null,
        };
        const drc_violations = try drc_mod.runDrc(allocator, block, board_def, project_dir, &lay);
        try w.writeAll("{\"violations\":[");
        for (drc_violations, 0..) |v, i| {
            if (i > 0) try w.writeAll(",");
            const sev: []const u8 = if (v.severity == .error_) "error" else "warning";
            try w.print("{{\"kind\":\"{s}\",\"message\":\"{s}\",\"x\":{d:.4},\"y\":{d:.4},\"severity\":\"{s}\"}}", .{ v.kind, v.message, v.x, v.y, sev });
        }
        try w.print("],\"count\":{d}}}", .{drc_violations.len});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}");
    return true;
}

fn missingArg(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8) !bool {
    const w = out.writer(allocator);
    try w.print("error: missing argument \"{s}\"", .{key});
    return false;
}

fn editErrorMsg(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, err: edit.EditError) !bool {
    const w = out.writer(allocator);
    try w.print("error: {s}", .{@errorName(err)});
    return false;
}

fn requireString(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    return optionalString(args_val, key);
}

fn optionalString(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

/// Write `s` as a JSON string literal (with escapes) to `w`.
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
}

pub fn listDesignNames(allocator: std.mem.Allocator, project_dir: []const u8) ![][]const u8 {
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_path);

    var dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch return &[_][]const u8{};
    defer dir.close();

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.name });
        defer allocator.free(full_path);
        if (!hasTopLevelDesignBlock(allocator, full_path)) continue;
        const base = entry.name[0 .. entry.name.len - ".sexp".len];
        try names.append(allocator, try allocator.dupe(u8, base));
    }
    return names.toOwnedSlice(allocator);
}

/// Parse the file's top-level forms and return true iff any is a
/// `(design-block ...)`. Used to filter out board definitions and auxiliary
/// .sexp files from list_designs.
fn hasTopLevelDesignBlock(allocator: std.mem.Allocator, path: []const u8) bool {
    const src = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch return false;
    defer allocator.free(src);
    const nodes = sexpr_parser.parse(allocator, src) catch return false;
    for (nodes) |n| if (n.isForm("design-block")) return true;
    return false;
}

pub fn renderSceneGraph(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = try eval.evalFile(path);
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => return error.NotADesign,
    };

    const bom_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, name });
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, @constCast(block), bom_path, project_dir) catch {};

    return render_json.renderSceneGraph(allocator, block);
}
