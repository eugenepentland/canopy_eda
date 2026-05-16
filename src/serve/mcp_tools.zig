const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const edit = @import("edit.zig");
const vfs = @import("vfs.zig");
const history = @import("history.zig");
const serve_root = @import("../serve.zig");
const render_json = @import("../render_json.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const erc_mod = @import("../erc.zig");
const log = @import("../infra/log.zig");
const bom = @import("../bom.zig");
const sexpr_parser = @import("../sexpr/parser.zig");
const ids = @import("../eval/ids.zig");
const review_mod = @import("../review.zig");
const review_json_mod = @import("../review_json.zig");
const req_checks = @import("../req_checks.zig");
const component_info = @import("component_info.zig");
const notes = @import("notes.zig");
const symbol_conv = @import("../convert/symbol.zig");

// ── Constants ─────────────────────────────────────────────────────
const NAME_FIELD_PREFIX = "{\"name\":";
const REF_DES_FIELD_PREFIX = "{\"ref_des\":";
const FUNCTION_FIELD = ",\"function\":";
const KEY_COMPONENTS = "components";
const KEY_FOOTPRINTS = "footprints";
const ERR_NOT_DESIGN = "error: not a design";
const ERR_BUILD_FAILED = "error: build failed";
const ERR_LINE_TEMPLATE = "error: {s}";
const VERSION_SNAPSHOT_TEMPLATE = "{{\"ok\":true,\"version\":{d},\"snapshot\":";
const JSON_NET_KEY = ",\"net\":";

const EvalError = @import("../eval/evaluator.zig").EvalError;
const RenderError = render_json.RenderError;

/// Error set used by mcp_tools helper fns that orchestrate eval + render
/// + filesystem walks, plus any writer in JSON-emitting helpers.
pub const ToolError = std.mem.Allocator.Error || std.Io.Writer.Error || EvalError || RenderError ||
    std.fs.Dir.Iterator.Error || std.fs.Dir.OpenError || std.fs.File.OpenError || std.fs.File.ReadError ||
    error{ NotADesign, FileTooBig, StreamTooLong, NotOpenForReading, ReadOnlyFileSystem, LinkQuotaExceeded };

fn warnResolveIdentities(name: []const u8, err: anyerror) void {
    log.warn("resolveIdentities {s} failed: {s}", .{ name, @errorName(err) });
}

/// One entry per MCP tool. Keep in sync with `tools_list_result` below and
/// with the dispatch arms in `callInner`. Adding a new tool should start here,
/// not with a scatter across three separate sites.
const ToolEntry = struct {
    name: []const u8,
    is_mutation: bool,
};

const tools = [_]ToolEntry{
    // Project / library metadata (structured semantic data, not derivable from raw FS).
    .{ .name = "list_designs", .is_mutation = false },
    .{ .name = "list_library", .is_mutation = false },
    .{ .name = "list_history", .is_mutation = false },
    .{ .name = "list_instances", .is_mutation = false },
    .{ .name = "list_free_pins", .is_mutation = false },
    .{ .name = "get_net", .is_mutation = false },
    .{ .name = "describe_component", .is_mutation = false },
    .{ .name = "get_schematic", .is_mutation = false },
    .{ .name = "get_version", .is_mutation = false },
    .{ .name = "run_checks", .is_mutation = false },
    .{ .name = "generate_review", .is_mutation = false },
    // Mutations on history.
    .{ .name = "restore_version", .is_mutation = true },
    // Virtual filesystem — agent reads/edits files like a local checkout.
    .{ .name = "read_file", .is_mutation = false },
    .{ .name = "list_dir", .is_mutation = false },
    .{ .name = "glob", .is_mutation = false },
    .{ .name = "write_file", .is_mutation = true },
    .{ .name = "edit_file", .is_mutation = true },
    .{ .name = "delete_file", .is_mutation = true },
    .{ .name = "move_file", .is_mutation = true },
    // Re-evaluate a design and push the result to live viewers.
    .{ .name = "build", .is_mutation = true },
    // KiCad-source-driven regeneration of an auto-generated pinout file.
    .{ .name = "regenerate_pinout", .is_mutation = true },
    // Per-design TODO notes (sidecar `<design>.notes.md`). Lets agents
    // log follow-ups for the next revision and mark them complete with
    // a date stamp once the design has been updated.
    .{ .name = "list_design_notes", .is_mutation = false },
    .{ .name = "add_design_note", .is_mutation = true },
    .{ .name = "complete_design_note", .is_mutation = true },
    .{ .name = "reopen_design_note", .is_mutation = true },
    .{ .name = "remove_design_note", .is_mutation = true },
};

/// Tools that mutate .sexp files — gated to writer/admin roles.
pub fn isMutationTool(name: []const u8) bool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t.is_mutation;
    }
    return false;
}

pub const tools_list_result = @embedFile("assets/tools_list_result.json");

/// Result of a tool call for the MCP envelope writer. `ok=false` flips the
/// `isError` flag on the response. `out` always holds plain text that the
/// caller wraps in a single `{"type":"text","text":...}` block.
pub const CallResult = struct {
    ok: bool,
};

/// Dispatch a tool call. Writes the result into `out` and returns how the
/// caller should frame it in the MCP envelope.
pub fn call(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) CallResult {
    const ok = callInner(allocator, project_dir, tool_name, args_val, out) catch |err| {
        const msg = @errorName(err);
        const w = out.writer(allocator);
        w.print(ERR_LINE_TEMPLATE, .{msg}) catch |e| {
            log.warn("failed to write error msg: {s}", .{@errorName(e)});
        };
        return .{ .ok = false };
    };
    return .{ .ok = ok };
}

fn callInner(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) !bool {
    if (try dispatchVfs(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchProject(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchInfo(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchReview(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchNotes(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;

    const w = out.writer(allocator);
    try w.print("error: unknown tool \"{s}\"", .{tool_name});
    return false;
}

/// Listing tools that scan the project tree (designs, library, history,
/// instances, free pins, net membership). Returns null when the tool name
/// doesn't match any of these.
fn dispatchProject(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) !?bool {
    const w = out.writer(allocator);
    if (std.mem.eql(u8, tool_name, "list_designs")) return try toolListDesigns(allocator, project_dir, w);
    if (std.mem.eql(u8, tool_name, "list_library")) return try toolListLibrary(allocator, project_dir, w);
    if (std.mem.eql(u8, tool_name, "list_history")) return try toolListHistory(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "list_instances")) return try toolListInstances(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "list_free_pins")) return try toolListFreePins(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "get_net")) return try toolGetNet(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "describe_component")) return try toolDescribeComponent(allocator, project_dir, args_val, out);
    return null;
}

/// Diagnostic / introspection tools that don't change project state:
/// scene graph, version counter, run_checks, generate_review.
fn dispatchInfo(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) !?bool {
    const w = out.writer(allocator);
    if (std.mem.eql(u8, tool_name, "get_schematic")) return try toolGetSchematic(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "get_version")) return try toolGetVersion(args_val, out, allocator);
    if (std.mem.eql(u8, tool_name, "run_checks")) return try toolRunChecks(allocator, project_dir, args_val, out, w);
    if (std.mem.eql(u8, tool_name, "generate_review")) return try toolGenerateReview(allocator, project_dir, args_val, w, out);
    return null;
}

/// Mutations on history snapshots — the only mutator outside the VFS
/// surface, since it doesn't touch source files.
fn dispatchReview(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) !?bool {
    if (std.mem.eql(u8, tool_name, "restore_version")) return try toolRestoreVersion(allocator, project_dir, args_val, out);
    return null;
}

/// Per-design TODO notes — sidecar markdown file edited via structured
/// tools so the agent can record follow-ups and stamp completion dates.
fn dispatchNotes(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) !?bool {
    if (std.mem.eql(u8, tool_name, "list_design_notes")) return try toolListDesignNotes(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "add_design_note")) return try toolAddDesignNote(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "complete_design_note")) return try toolMutateDesignNote(allocator, project_dir, args_val, out, notes.TaskMutation.complete);
    if (std.mem.eql(u8, tool_name, "reopen_design_note")) return try toolMutateDesignNote(allocator, project_dir, args_val, out, notes.TaskMutation.reopen);
    if (std.mem.eql(u8, tool_name, "remove_design_note")) return try toolMutateDesignNote(allocator, project_dir, args_val, out, notes.TaskMutation.remove);
    return null;
}

fn toolListDesignNotes(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    var raw: ?[]u8 = null;
    const parsed = notes.loadNotes(allocator, project_dir, name, &raw) catch |e| {
        const w = out.writer(allocator);
        try w.print("error: cannot read notes: {s}", .{@errorName(e)});
        return false;
    };
    defer if (raw) |d| allocator.free(d);
    const w = out.writer(allocator);
    try w.writeAll("{\"tasks\":[");
    for (parsed.tasks, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try writeNoteJsonMcp(w, t);
    }
    try w.writeAll("],\"scratchpad\":");
    try writeJsonString(w, parsed.scratchpad);
    try w.writeAll("}");
    return true;
}

fn toolAddDesignNote(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const text = requireString(args_val, "text") orelse return missingArg(out, allocator, "text");
    if (text.len == 0) {
        const w = out.writer(allocator);
        try w.writeAll("error: text must be a non-empty string");
        return false;
    }
    const new_task = notes.addTaskCore(allocator, project_dir, name, text) catch |e| {
        const w = out.writer(allocator);
        try w.print("error: add failed: {s}", .{@errorName(e)});
        return false;
    };
    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":true,\"task\":");
    try writeNoteJsonMcp(w, new_task);
    try w.writeAll("}");
    return true;
}

fn toolMutateDesignNote(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
    mode: notes.TaskMutation,
) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const id = requireString(args_val, "id") orelse return missingArg(out, allocator, "id");
    const result = notes.mutateTaskCore(allocator, project_dir, name, id, mode) catch |e| {
        const w = out.writer(allocator);
        try w.print("error: mutate failed: {s}", .{@errorName(e)});
        return false;
    };
    if (result == null) {
        const w = out.writer(allocator);
        try w.print("error: task id \"{s}\" not found", .{id});
        return false;
    }
    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":true}");
    return true;
}

fn writeNoteJsonMcp(w: anytype, t: notes.Note) !void {
    try w.writeAll("{\"id\":");
    try writeJsonString(w, t.id);
    try w.writeAll(",\"text\":");
    try writeJsonString(w, t.text);
    try w.writeAll(",\"created\":");
    try writeJsonString(w, t.created);
    if (t.completed) |c| {
        try w.writeAll(",\"completed\":");
        try writeJsonString(w, c);
    } else {
        try w.writeAll(",\"completed\":null");
    }
    try w.writeAll("}");
}

fn toolListDesigns(allocator: std.mem.Allocator, project_dir: []const u8, w: anytype) !bool {
    const summaries = try listDesignSummaries(allocator, project_dir);
    try w.writeAll("[");
    for (summaries, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(NAME_FIELD_PREFIX);
        try writeJsonString(w, s.name);
        try w.writeAll(",\"title\":");
        try writeJsonString(w, s.title);
        try w.writeAll(",\"sections\":[");
        for (s.sections, 0..) |sec, si| {
            if (si > 0) try w.writeAll(",");
            try writeJsonString(w, sec);
        }
        try w.print("],\"instance_count\":{d},\"net_count\":{d},\"mtime\":{d},\"build_ok\":{s}}}", .{
            s.instance_count, s.net_count, s.mtime_sec, if (s.build_ok) "true" else "false",
        });
    }
    try w.writeAll("]");
    return true;
}

fn toolListLibrary(allocator: std.mem.Allocator, project_dir: []const u8, w: anytype) !bool {
    try w.writeAll("{");
    const kinds = [_]struct { field: []const u8, sub: []const u8 }{
        .{ .field = KEY_COMPONENTS, .sub = KEY_COMPONENTS },
        .{ .field = "modules", .sub = "modules" },
        .{ .field = "pinouts", .sub = "pinouts" },
        .{ .field = KEY_FOOTPRINTS, .sub = KEY_FOOTPRINTS },
    };
    for (kinds, 0..) |k, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\":", .{k.field});
        try listLibrarySubdir(allocator, project_dir, k.sub, w);
    }
    try w.writeAll("}");
    return true;
}

fn toolListHistory(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const w = out.writer(allocator);
    const snaps = try history.listSnapshots(allocator, project_dir, name);
    try w.writeAll("{\"snapshots\":[");
    for (snaps, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try writeJsonString(w, s.id);
        try w.writeAll(",\"description\":");
        if (s.description) |d| try writeJsonString(w, d) else try w.writeAll("null");
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return true;
}

fn toolListInstances(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return listInstances(allocator, project_dir, name, out.writer(allocator));
}

fn toolListFreePins(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const ref = requireString(args_val, "ref") orelse return missingArg(out, allocator, "ref");
    return listFreePins(allocator, project_dir, name, ref, optionalString(args_val, "filter"), out.writer(allocator));
}

fn toolGetNet(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const net = requireString(args_val, "net") orelse return missingArg(out, allocator, "net");
    return getNet(allocator, project_dir, name, net, out.writer(allocator));
}

fn toolDescribeComponent(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return component_info.describeComponent(allocator, project_dir, name, out);
}

fn toolGetSchematic(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const graph = try renderSceneGraph(allocator, project_dir, name);
    try out.writer(allocator).writeAll(graph);
    return true;
}

fn toolGetVersion(args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const w = out.writer(allocator);
    try w.print("{{\"version\":{d}}}", .{serve_root.getLiveVersion(name)});
    return true;
}

fn toolRunChecks(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8), w: anytype) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return runChecks(allocator, project_dir, name, optionalString(args_val, "severity"), optionalString(args_val, "changed_since"), w);
}

fn toolGenerateReview(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, w: anytype, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return generateReview(allocator, project_dir, name, w);
}

fn toolRestoreVersion(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const id = requireString(args_val, "id") orelse return missingArg(out, allocator, "id");
    const result = edit.restoreDesignCore(allocator, project_dir, name, id) catch |err| return editErrorMsg(out, allocator, err);
    const w = out.writer(allocator);
    try w.print(VERSION_SNAPSHOT_TEMPLATE, .{result.version});
    if (result.snapshot) |s| try writeJsonString(w, s) else try w.writeAll("null");
    try w.writeAll("}");
    return true;
}

/// Dispatch the virtual-filesystem tools (read_file/write_file/edit_file/
/// list_dir/glob/delete_file/move_file) and the `build` worker. Returns
/// `null` when `tool_name` is none of those, so the caller can keep
/// matching against the project-tools and review arms.
fn dispatchVfs(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) !?bool {
    const Ctx = struct { allocator: std.mem.Allocator, project_dir: []const u8, args: ?std.json.Value, out: *std.ArrayListUnmanaged(u8) };
    const ctx = Ctx{ .allocator = allocator, .project_dir = project_dir, .args = args_val, .out = out };
    if (std.mem.eql(u8, tool_name, "read_file")) return try toolReadFile(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    if (std.mem.eql(u8, tool_name, "write_file")) return try toolWriteFile(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    if (std.mem.eql(u8, tool_name, "edit_file")) return try toolEditFile(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    if (std.mem.eql(u8, tool_name, "list_dir")) return try toolListDir(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    if (std.mem.eql(u8, tool_name, "glob")) return try toolGlob(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    if (std.mem.eql(u8, tool_name, "delete_file")) return try toolDeleteFile(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    if (std.mem.eql(u8, tool_name, "move_file")) return try toolMoveFile(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    if (std.mem.eql(u8, tool_name, "build")) return try toolBuild(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    if (std.mem.eql(u8, tool_name, "regenerate_pinout")) return try toolRegeneratePinout(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    return null;
}

fn toolReadFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const path = requireString(args_val, "path") orelse return missingArg(out, allocator, "path");
    return vfs.readFile(allocator, project_dir, path, optionalU64(args_val, "offset"), optionalU64(args_val, "limit"), out);
}

fn toolWriteFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const path = requireString(args_val, "path") orelse return missingArg(out, allocator, "path");
    const content = requireString(args_val, "content") orelse return missingArg(out, allocator, "content");
    return vfs.writeFile(allocator, project_dir, path, content, optionalString(args_val, "expected_sha256"), out);
}

fn toolEditFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const path = requireString(args_val, "path") orelse return missingArg(out, allocator, "path");
    const old_s = requireString(args_val, "old_string") orelse return missingArg(out, allocator, "old_string");
    const new_s = requireString(args_val, "new_string") orelse return missingArg(out, allocator, "new_string");
    const replace_mode: vfs.ReplaceMode = if (optionalBool(args_val, "replace_all") orelse false) .all else .single;
    return vfs.editFile(allocator, project_dir, path, old_s, new_s, optionalString(args_val, "expected_sha256"), replace_mode, out);
}

fn toolListDir(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const path = optionalString(args_val, "path") orelse "";
    const list_mode: vfs.ListMode = if (optionalBool(args_val, "recursive") orelse false) .recursive else .flat;
    return vfs.listDir(allocator, project_dir, path, list_mode, optionalU64(args_val, "max_entries"), out);
}

fn toolGlob(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const pattern = requireString(args_val, "pattern") orelse return missingArg(out, allocator, "pattern");
    return vfs.glob(allocator, project_dir, pattern, optionalString(args_val, "base"), out);
}

fn toolDeleteFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const path = requireString(args_val, "path") orelse return missingArg(out, allocator, "path");
    return vfs.deleteFile(allocator, project_dir, path, out);
}

fn toolMoveFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const from = requireString(args_val, "from") orelse return missingArg(out, allocator, "from");
    const to = requireString(args_val, "to") orelse return missingArg(out, allocator, "to");
    return vfs.moveFile(allocator, project_dir, from, to, out);
}

fn toolBuild(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayListUnmanaged(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const report = edit.rebuildDesign(allocator, project_dir, name);
    const w = out.writer(allocator);
    try writeBuildReport(w, report);
    return true;
}

/// Regenerate `lib/pinouts/<name>.sexp` from `<source>` (a `.kicad_sym`
/// in `lib/sources/`). Mirrors what the `eda convert-pinout` CLI does
/// — same `generatePinout` function, same `;; Auto-generated pinout`
/// header — but routes the write through the VFS so sandbox checks
/// apply and the response carries `dirty_designs`/`library_changes`
/// alongside the path written.
///
/// Defaults: `name` falls back to the source file's basename (minus
/// `.kicad_sym`); `filter` is forwarded straight to generatePinout for
/// multi-symbol library files.
fn toolRegeneratePinout(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayListUnmanaged(u8),
) !bool {
    const source = requireString(args_val, "source") orelse return missingArg(out, allocator, "source");
    const w = out.writer(allocator);

    // Source must live under lib/sources/ (read access from there is in the
    // sandbox; we don't go through writeFile so we must check explicitly).
    if (!std.mem.startsWith(u8, source, "lib/sources/")) {
        try w.writeAll("{\"ok\":false,\"error\":\"source must be a path under lib/sources/\"}");
        return false;
    }

    // Read the .kicad_sym through the VFS surface — same path validation,
    // same deny-list rules, no new code path for traversal escapes.
    var read_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer read_buf.deinit(allocator);
    const read_ok = try vfs.readFile(allocator, project_dir, source, null, null, &read_buf);
    if (!read_ok) {
        // Forward the structured error from readFile verbatim.
        try w.writeAll(read_buf.items);
        return false;
    }

    // readFile returns JSON; pull `content` out for symbol_conv. Errors
    // here mean the source was a binary extension (so we'd have got base64)
    // or the JSON was malformed — both are bugs, not user errors.
    const source_text = try extractFileContent(allocator, read_buf.items);
    defer allocator.free(source_text);

    const filter = optionalString(args_val, "filter");
    const raw_pinout = symbol_conv.generatePinout(allocator, source_text, filter) catch |err| {
        try w.print("{{\"ok\":false,\"error\":\"convert failed: {s}\"}}", .{@errorName(err)});
        return false;
    };
    defer allocator.free(raw_pinout);

    // Inject a `;; source: <path>` header so describe_component can surface
    // the source-of-truth linkage. Future regenerations stay idempotent —
    // generatePinout always re-emits the standard header so the previous
    // source line is overwritten by the next regenerate_pinout call.
    const pinout_text = try std.fmt.allocPrint(
        allocator,
        ";; source: {s}\n{s}",
        .{ source, raw_pinout },
    );
    defer allocator.free(pinout_text);

    // Default the output basename from the source filename, stripping the
    // .kicad_sym extension. Caller can override with `name`.
    const default_name = blk: {
        const base = std.fs.path.basename(source);
        break :blk if (std.mem.endsWith(u8, base, ".kicad_sym"))
            base[0 .. base.len - ".kicad_sym".len]
        else
            base;
    };
    const out_name = optionalString(args_val, "name") orelse default_name;
    if (out_name.len == 0 or std.mem.indexOfAny(u8, out_name, "/\\") != null or std.mem.indexOf(u8, out_name, "..") != null) {
        try w.writeAll("{\"ok\":false,\"error\":\"invalid output name\"}");
        return false;
    }

    const out_path = try std.fmt.allocPrint(allocator, "lib/pinouts/{s}.sexp", .{out_name});
    defer allocator.free(out_path);

    var write_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer write_buf.deinit(allocator);
    const wrote_ok = try vfs.writeFile(allocator, project_dir, out_path, pinout_text, null, &write_buf);
    if (!wrote_ok) {
        // writeFile already emitted a structured `{"error":"..."}`.
        try w.writeAll(write_buf.items);
        return false;
    }

    // Wrap the write response with `ok:true` and the source we converted
    // from. Splice in writeFile's existing JSON object verbatim by
    // stripping its outer braces and re-emitting them with the extra
    // fields prepended.
    if (write_buf.items.len < 2 or write_buf.items[0] != '{' or write_buf.items[write_buf.items.len - 1] != '}') {
        // writeFile contract: always object literal. If that ever changes,
        // surface the raw response so the failure is debuggable.
        try w.writeAll(write_buf.items);
        return true;
    }
    try w.writeAll("{\"ok\":true,\"source\":");
    try writeJsonString(w, source);
    try w.writeAll(",");
    try w.writeAll(write_buf.items[1..]);
    return true;
}

/// Extract the `content` string from a successful `vfs.readFile` JSON
/// response. The schema is `{"path":"…","size":N,"sha256":"…","truncated":B,
/// "binary":false,"content":"…"}` — we only need to unescape `content`.
/// Returns an allocator-owned slice so the caller can free it.
fn extractFileContent(allocator: std.mem.Allocator, json_str: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFormat;
    const v = parsed.value.object.get("content") orelse return error.InvalidFormat;
    if (v != .string) return error.InvalidFormat;
    return allocator.dupe(u8, v.string);
}

/// Write a JSON array of {name, description} objects for every .sexp file
/// in `{project_dir}/lib/{sub}/`. Description is extracted from the first
/// top-level (description "...") form in the file, or empty if absent.
fn listLibrarySubdir(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    sub: []const u8,
    w: anytype,
) !void {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/{s}", .{ project_dir, sub });
    defer allocator.free(dir_path);

    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        try w.writeAll("[]");
        return;
    };
    defer dir.close();

    try w.writeAll("[");
    var first = true;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        const base = entry.name[0 .. entry.name.len - ".sexp".len];
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);
        const description = extractDescription(allocator, full_path);
        defer if (description) |d| allocator.free(d);

        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll(NAME_FIELD_PREFIX);
        try writeJsonString(w, base);
        try w.writeAll(",\"description\":");
        if (description) |d| try writeJsonString(w, d) else try w.writeAll("\"\"");
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// Find the first `(description "...")` form in the file and return its
/// string value. Returns null if absent. Caller owns the returned memory.
fn extractDescription(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const src = infra_fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
    defer allocator.free(src);
    const marker = "(description \"";
    const idx = std.mem.indexOf(u8, src, marker) orelse return null;
    const start = idx + marker.len;
    const end = std.mem.indexOfScalarPos(u8, src, start, '"') orelse return null;
    return allocator.dupe(u8, src[start..end]) catch null;
}

fn runChecks(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    severity_filter: ?[]const u8,
    changed_since: ?[]const u8,
    w: anytype,
) !bool {
    const path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll(ERR_BUILD_FAILED);
        return false;
    };

    const block: *env_mod.DesignBlock = switch (result) {
        .design_block => |db| db,
        else => {
            try w.writeAll(ERR_NOT_DESIGN);
            return false;
        },
    };

    const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);

    // If changed_since is set, compute the symmetric-difference sets of
    // ref_des and net names between the prior snapshot and the current
    // design. ERC violations are filtered to those touching these sets.
    var changed_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer changed_refs.deinit(allocator);
    var changed_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer changed_nets.deinit(allocator);
    var have_change_filter = false;
    if (changed_since) |cs| {
        // Validate snapshot id for path traversal.
        if (cs.len == 0 or std.mem.indexOf(u8, cs, "..") != null or std.mem.indexOfAny(u8, cs, "/\\") != null) {
            try w.writeAll("error: invalid changed_since id");
            return false;
        }
        const snap_path = try std.fmt.allocPrint(allocator, "{s}/history/{s}/{s}/{s}.sexp", .{ project_dir, name, cs, name });
        defer allocator.free(snap_path);
        var eval_old = Evaluator.init(allocator, project_dir);
        defer eval_old.deinit();
        if (eval_old.evalFile(snap_path)) |old_result| {
            const old_block: *const env_mod.DesignBlock = switch (old_result) {
                .design_block => |b| b,
                else => {
                    try w.writeAll("error: snapshot did not evaluate to a design");
                    return false;
                },
            };
            try diffSets(allocator, old_block, block, &changed_refs, &changed_nets);
            have_change_filter = true;
        } else |_| {
            try w.writeAll("error: could not load snapshot");
            return false;
        }
    }

    try w.print("{{\"filtered\":{s}", .{if (have_change_filter or severity_filter != null) "true" else "false"});

    if (have_change_filter) {
        try w.writeAll(",\"changed_refs\":[");
        var it = changed_refs.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
            try writeJsonString(w, e.key_ptr.*);
        }
        try w.writeAll("],\"changed_nets\":[");
        var it2 = changed_nets.iterator();
        first = true;
        while (it2.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
            try writeJsonString(w, e.key_ptr.*);
        }
        try w.writeAll("]");
    }

    try w.writeAll(",\"erc\":[");
    const erc_all = try erc_mod.runErc(allocator, block, project_dir);
    var first = true;
    for (erc_all) |v| {
        if (severity_filter) |sf| if (!std.mem.eql(u8, @tagName(v.severity), sf)) continue;
        if (have_change_filter) {
            const ref_hit = v.ref_des.len > 0 and changed_refs.contains(v.ref_des);
            const net_hit = v.net.len > 0 and changed_nets.contains(v.net);
            if (!ref_hit and !net_hit) continue;
        }
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"kind\":\"");
        try w.writeAll(@tagName(v.kind));
        try w.writeAll("\",\"severity\":\"");
        try w.writeAll(@tagName(v.severity));
        try w.writeAll("\",\"message\":");
        try writeJsonString(w, v.message);
        if (v.ref_des.len > 0) {
            try w.writeAll(",\"ref\":");
            try writeJsonString(w, v.ref_des);
        }
        if (v.net.len > 0) {
            try w.writeAll(JSON_NET_KEY);
            try writeJsonString(w, v.net);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return true;
}

/// Build and serialize the review document for a design. Returns the JSON
/// body directly; mirrors the HTTP handler so the browser and MCP tool
/// consume the same shape.
fn generateReview(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    w: anytype,
) !bool {
    const path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll(ERR_BUILD_FAILED);
        return false;
    };
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => {
            try w.writeAll(ERR_NOT_DESIGN);
            return false;
        },
    };

    const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, @constCast(block), bom_path, project_dir) catch |e| warnResolveIdentities(name, e);

    const violations = try erc_mod.runErc(allocator, block, project_dir);
    var check_results = req_checks.runChecks(allocator, &eval, block) catch
        std.StringHashMapUnmanaged([]req_checks.Result).empty;
    req_checks.applyVerifications(&check_results, block, block.instances);
    const doc = try review_mod.buildReview(allocator, name, block, eval.assertions.items, violations, &check_results);
    const json = try review_json_mod.renderToJson(allocator, doc);
    try w.writeAll(json);
    return true;
}

fn diffSets(
    allocator: std.mem.Allocator,
    old_block: *const env_mod.DesignBlock,
    new_block: *const env_mod.DesignBlock,
    changed_refs: *std.StringHashMapUnmanaged(void),
    changed_nets: *std.StringHashMapUnmanaged(void),
) !void {
    var old_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer old_refs.deinit(allocator);
    var new_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer new_refs.deinit(allocator);
    var old_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer old_nets.deinit(allocator);
    var new_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer new_nets.deinit(allocator);

    for (old_block.instances) |i| try old_refs.put(allocator, i.ref_des, {});
    for (new_block.instances) |i| try new_refs.put(allocator, i.ref_des, {});
    for (old_block.nets) |n| try old_nets.put(allocator, n.name, {});
    for (new_block.nets) |n| try new_nets.put(allocator, n.name, {});

    var it = old_refs.iterator();
    while (it.next()) |e| if (!new_refs.contains(e.key_ptr.*)) try changed_refs.put(allocator, e.key_ptr.*, {});
    var it2 = new_refs.iterator();
    while (it2.next()) |e| if (!old_refs.contains(e.key_ptr.*)) try changed_refs.put(allocator, e.key_ptr.*, {});

    var it3 = old_nets.iterator();
    while (it3.next()) |e| if (!new_nets.contains(e.key_ptr.*)) try changed_nets.put(allocator, e.key_ptr.*, {});
    var it4 = new_nets.iterator();
    while (it4.next()) |e| if (!old_nets.contains(e.key_ptr.*)) try changed_nets.put(allocator, e.key_ptr.*, {});
}

/// Best-effort classification of a pinout function name. Used by
/// `list_free_pins` to filter and annotate unassigned pins. Heuristics are
/// tuned for STM32 / common MCU pinouts and will degrade gracefully (return
/// `.other`) on unfamiliar names — callers should not treat this as authoritative.
const PinCategory = enum { gpio, power, clock, analog, other };

fn classifyPin(function: []const u8) PinCategory {
    if (function.len == 0) return .other;
    // STM32-style port pin: P[A-Z][digits], optionally followed by alt-function text.
    if (function.len >= 3 and function[0] == 'P' and function[1] >= 'A' and function[1] <= 'Z') {
        var all_digits = true;
        for (function[2..]) |c| {
            if (c < '0' or c > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return .gpio;
    }
    // Power: VDD, VSS, VCC, VBAT, VBUS, VREF, VDDA…
    if (std.mem.startsWith(u8, function, "V") and function.len >= 2) {
        const rest = function[1..];
        if (std.mem.startsWith(u8, rest, "DD")) return .power;
        if (std.mem.startsWith(u8, rest, "SS")) return .power;
        if (std.mem.startsWith(u8, rest, "CC")) return .power;
        if (std.mem.startsWith(u8, rest, "BAT")) return .power;
        if (std.mem.startsWith(u8, rest, "BUS")) return .power;
        if (std.mem.startsWith(u8, rest, "REF")) return .power;
    }
    if (std.mem.eql(u8, function, "GND") or std.mem.startsWith(u8, function, "GND_")) return .power;
    // Analog: ADC_IN*, A[DI]C prefix, AIN*
    if (std.mem.startsWith(u8, function, "ADC") or
        std.mem.startsWith(u8, function, "AIN") or
        std.mem.startsWith(u8, function, "DAC"))
        return .analog;
    // Clock: OSC*, XTAL*, CLK / CLKIN / CLKOUT prefix
    if (std.mem.startsWith(u8, function, "OSC") or
        std.mem.startsWith(u8, function, "XTAL") or
        std.mem.startsWith(u8, function, "CLK"))
        return .clock;
    return .other;
}

fn categoryName(c: PinCategory) []const u8 {
    return switch (c) {
        .gpio => "gpio",
        .power => "power",
        .clock => "clock",
        .analog => "analog",
        .other => "other",
    };
}

/// Return a pointer to the evaluated DesignBlock for `name`, or an error string
/// written to `w` and null return. Caller must call `eval.deinit()` on the
/// returned evaluator pointer's memory arena (via `defer` in the caller).
fn listInstances(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    w: anytype,
) !bool {
    const path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll(ERR_BUILD_FAILED);
        return false;
    };
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => {
            try w.writeAll(ERR_NOT_DESIGN);
            return false;
        },
    };

    try w.writeAll("{\"instances\":[");
    for (block.instances, 0..) |inst, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(REF_DES_FIELD_PREFIX);
        try writeJsonString(w, inst.ref_des);
        try w.writeAll(",\"label\":");
        try writeJsonString(w, inst.label);
        try w.writeAll(",\"component\":");
        try writeJsonString(w, inst.component);
        try w.writeAll(",\"symbol\":");
        try writeJsonString(w, inst.symbol);
        try w.writeAll(",\"value\":");
        try writeJsonString(w, inst.value);

        // Pin count: prefer explicit parts if present (multi-part symbol);
        // else fall back to the symbol's pinout map size.
        var pin_count: usize = 0;
        if (inst.parts.len > 0) {
            for (inst.parts) |p| pin_count += p.pins.len;
        } else if (inst.symbol.len > 0) {
            if (ids.getSymbolPins(&eval, inst.symbol)) |pm| pin_count = pm.count();
        }
        try w.print(",\"pin_count\":{d}}}", .{pin_count});
    }
    try w.writeAll("]}");
    return true;
}

/// Collect every pin of the given instance that does not appear in any
/// `(pin_groups)` or net mapping inside the design, and emit them as JSON
/// with function names and classification.
pub fn listFreePins(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    filter: ?[]const u8,
    w: anytype,
) ToolError!bool {
    const path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll(ERR_BUILD_FAILED);
        return false;
    };
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => {
            try w.writeAll(ERR_NOT_DESIGN);
            return false;
        },
    };

    var target: ?*const env_mod.Instance = null;
    for (block.instances) |*inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) {
            target = inst;
            break;
        }
    }
    if (target == null) {
        try w.writeAll("error: instance not found");
        return false;
    }
    const inst = target.?;
    // Prefer the component's explicit pinout name (common case: component
    // declares `(pinout foo)`), falling back to symbol_name, then inst.symbol.
    const lookup_name = if (eval.component_cache.get(inst.component)) |cd|
        (if (cd.pinout_name.len > 0) cd.pinout_name else if (cd.symbol_name.len > 0) cd.symbol_name else inst.symbol)
    else
        inst.symbol;
    if (lookup_name.len == 0) {
        try w.writeAll("{\"free_pins\":[],\"assigned_pins\":[],\"note\":\"instance has no associated symbol pinout\"}");
        return true;
    }

    const pin_map = ids.getSymbolPins(&eval, lookup_name) orelse {
        try w.writeAll("{\"free_pins\":[],\"assigned_pins\":[],\"note\":\"pinout file not found for symbol\"}");
        return true;
    };

    // Map each assigned pin on this instance to its current net name.
    var assigned: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer assigned.deinit(allocator);
    for (block.nets) |net| {
        for (net.pins) |p| {
            if (std.mem.eql(u8, p.ref_des, ref_des)) {
                try assigned.put(allocator, p.pin, net.name);
            }
        }
    }

    try w.writeAll("{\"free_pins\":[");
    var it = pin_map.iterator();
    var first = true;
    while (it.next()) |e| {
        const pin_id = e.key_ptr.*;
        if (assigned.contains(pin_id)) continue;
        const fname = e.value_ptr.*;
        const cat = classifyPin(fname);
        if (filter) |f| if (!std.mem.eql(u8, f, categoryName(cat))) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"pin\":");
        try writeJsonString(w, pin_id);
        try w.writeAll(FUNCTION_FIELD);
        try writeJsonString(w, fname);
        try w.print(",\"category\":\"{s}\"}}", .{categoryName(cat)});
    }
    try w.writeAll("],\"assigned_pins\":[");
    var it2 = pin_map.iterator();
    var first2 = true;
    while (it2.next()) |e| {
        const pin_id = e.key_ptr.*;
        const net_name = assigned.get(pin_id) orelse continue;
        const fname = e.value_ptr.*;
        const cat = classifyPin(fname);
        if (filter) |f| if (!std.mem.eql(u8, f, categoryName(cat))) continue;
        if (!first2) try w.writeAll(",");
        first2 = false;
        try w.writeAll("{\"pin\":");
        try writeJsonString(w, pin_id);
        try w.writeAll(FUNCTION_FIELD);
        try writeJsonString(w, fname);
        try w.writeAll(JSON_NET_KEY);
        try writeJsonString(w, net_name);
        try w.print(",\"category\":\"{s}\"}}", .{categoryName(cat)});
    }
    try w.writeAll("]}");
    return true;
}

/// Emit every pin connected to `net_name`, plus every passive instance
/// (ref_des starting with R/L/C/F/D) whose ref_des appears on the net.
fn getNet(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    net_name: []const u8,
    w: anytype,
) !bool {
    const path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll(ERR_BUILD_FAILED);
        return false;
    };
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => {
            try w.writeAll(ERR_NOT_DESIGN);
            return false;
        },
    };

    var target: ?*const env_mod.Net = null;
    for (block.nets) |*n| {
        if (std.mem.eql(u8, n.name, net_name)) {
            target = n;
            break;
        }
    }
    if (target == null) {
        try w.writeAll("error: net not found");
        return false;
    }
    const net = target.?;

    try w.writeAll(NAME_FIELD_PREFIX);
    try writeJsonString(w, net.name);
    try w.writeAll(",\"pins\":[");

    var passive_refs: std.StringHashMapUnmanaged(void) = .empty;
    defer passive_refs.deinit(allocator);

    for (net.pins, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        // Look up the function name for this pin via the instance's symbol pinout.
        var fname: []const u8 = "";
        for (block.instances) |inst| {
            if (!std.mem.eql(u8, inst.ref_des, p.ref_des)) continue;
            if (inst.symbol.len == 0) break;
            if (ids.getSymbolPins(&eval, inst.symbol)) |pm| {
                if (pm.get(p.pin)) |f| fname = f;
            }
            // Flag passives for the `passives` array below.
            const c0 = if (inst.ref_des.len > 0) inst.ref_des[0] else 0;
            if (c0 == 'R' or c0 == 'L' or c0 == 'C' or c0 == 'F' or c0 == 'D') {
                try passive_refs.put(allocator, inst.ref_des, {});
            }
            break;
        }
        try w.writeAll(REF_DES_FIELD_PREFIX);
        try writeJsonString(w, p.ref_des);
        try w.writeAll(",\"pin\":");
        try writeJsonString(w, p.pin);
        try w.writeAll(FUNCTION_FIELD);
        try writeJsonString(w, fname);
        try w.writeAll("}");
    }
    try w.writeAll("],\"passives\":[");

    var it = passive_refs.iterator();
    var first = true;
    while (it.next()) |e| {
        for (block.instances) |inst| {
            if (!std.mem.eql(u8, inst.ref_des, e.key_ptr.*)) continue;
            if (!first) try w.writeAll(",");
            first = false;
            try w.writeAll(REF_DES_FIELD_PREFIX);
            try writeJsonString(w, inst.ref_des);
            try w.writeAll(",\"component\":");
            try writeJsonString(w, inst.component);
            try w.writeAll(",\"value\":");
            try writeJsonString(w, inst.value);
            try w.writeAll("}");
            break;
        }
    }
    try w.writeAll("]}");
    return true;
}

fn missingArg(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8) !bool {
    const w = out.writer(allocator);
    try w.print("error: missing argument \"{s}\"", .{key});
    return false;
}

fn editErrorMsg(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, err: edit.EditError) !bool {
    const w = out.writer(allocator);
    try w.print(ERR_LINE_TEMPLATE, .{@errorName(err)});
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

fn optionalU64(args_val: ?std.json.Value, key: []const u8) ?u64 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    // If/else chain rather than `switch (v)` so this doesn't trip the
    // `repeated-switch-on-enum` check (the same shape lives in edit.zig).
    if (v == .integer) {
        if (v.integer < 0) return null;
        return @intCast(v.integer);
    }
    if (v == .float) {
        if (v.float < 0) return null;
        return @intFromFloat(v.float);
    }
    return null;
}

fn optionalBool(args_val: ?std.json.Value, key: []const u8) ?bool {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

/// Render a `BuildReport` from `edit.rebuildDesign` as the JSON the MCP
/// `build` tool returns. Failures keep the live_version unchanged but
/// still report the error message and any partial assertion results.
fn writeBuildReport(w: anytype, report: edit.BuildReport) !void {
    try w.writeAll("{\"ok\":");
    try w.writeAll(if (report.ok) "true" else "false");
    try w.print(",\"version\":{d},\"eval_ok\":{s}", .{
        report.version,
        if (report.eval_ok) "true" else "false",
    });
    try w.writeAll(",\"snapshot\":");
    if (report.snapshot) |s| try writeJsonString(w, s) else try w.writeAll("null");
    try w.writeAll(",\"error\":");
    if (report.error_message) |m| try writeJsonString(w, m) else try w.writeAll("null");
    try w.writeAll(",\"assertion_failures\":[");
    for (report.assertion_failures, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"message\":");
        try writeJsonString(w, a.message);
        try w.print(",\"is_warning\":{s}}}", .{if (a.is_warning) "true" else "false"});
    }
    try w.writeAll("],\"erc\":[");
    for (report.erc, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"kind\":\"");
        try w.writeAll(@tagName(v.kind));
        try w.writeAll("\",\"severity\":\"");
        try w.writeAll(@tagName(v.severity));
        try w.writeAll("\",\"message\":");
        try writeJsonString(w, v.message);
        if (v.ref_des.len > 0) {
            try w.writeAll(",\"ref\":");
            try writeJsonString(w, v.ref_des);
        }
        if (v.net.len > 0) {
            try w.writeAll(JSON_NET_KEY);
            try writeJsonString(w, v.net);
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}");
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

/// Scan `{project_dir}/src/` recursively and return the basename of every
/// file whose top-level form is a `(design-block …)`. Helper for the MCP
/// `list_designs` tool and the index page's design list. Sibling
/// `<name>.checks.sexp` files (autoloaded verifications) are skipped.
pub fn listDesignNames(allocator: std.mem.Allocator, project_dir: []const u8) ToolError![][]const u8 {
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_path);

    var dir = infra_fs.cwd().openDir(src_path, .{ .iterate = true }) catch return &[_][]const u8{};
    defer dir.close();

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".sexp")) continue;
        if (std.mem.endsWith(u8, entry.basename, ".checks.sexp")) continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.path });
        defer allocator.free(full_path);
        if (!hasTopLevelDesignBlock(allocator, full_path)) continue;
        const base = entry.basename[0 .. entry.basename.len - ".sexp".len];
        try names.append(allocator, try allocator.dupe(u8, base));
    }
    return names.toOwnedSlice(allocator);
}

/// Summary of a single design used by both the index page and the MCP
/// `list_designs` tool. All owned slices are duped into `allocator`.
pub const DesignSummary = struct {
    /// File basename without extension.
    name: []const u8,
    /// Human-readable title from the design-block form (empty if not evaluable).
    title: []const u8,
    /// Top-level section names.
    sections: []const []const u8,
    /// Number of instances after evaluation (0 if build failed).
    instance_count: usize,
    /// Number of nets after evaluation (0 if build failed).
    net_count: usize,
    /// Source file mtime in Unix seconds.
    mtime_sec: i64,
    /// Whether the file evaluated cleanly.
    build_ok: bool,
};

/// Count instances flattened across a design plus every sub-block. Does NOT
/// add section.instances — they are already in block.instances (evaluator
/// puts each section instance in both lists), so summing sections here would
/// double-count.
fn countInstances(block: *const env_mod.DesignBlock) usize {
    var n: usize = block.instances.len;
    for (block.sub_blocks) |sb| n += countInstances(sb.block);
    return n;
}

fn countNets(block: *const env_mod.DesignBlock) usize {
    var n: usize = block.nets.len;
    for (block.sub_blocks) |sb| n += countNets(sb.block);
    return n;
}

/// Scan `{project_dir}/src/` for design files and return a summary for each.
/// Designs that fail to evaluate are still included with build_ok=false so
/// the UI can surface them instead of silently dropping them.
pub fn listDesignSummaries(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
) ToolError![]DesignSummary {
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_path);

    var dir = infra_fs.cwd().openDir(src_path, .{ .iterate = true }) catch return &[_]DesignSummary{};
    defer dir.close();

    var summaries: std.ArrayListUnmanaged(DesignSummary) = .empty;
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".sexp")) continue;
        if (std.mem.endsWith(u8, entry.basename, ".checks.sexp")) continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.path });
        defer allocator.free(full_path);
        if (!hasTopLevelDesignBlock(allocator, full_path)) continue;

        const base = try allocator.dupe(u8, entry.basename[0 .. entry.basename.len - ".sexp".len]);

        var mtime_sec: i64 = 0;
        if (dir.statFile(entry.path)) |st| {
            mtime_sec = @intCast(@divTrunc(st.mtime, std.time.ns_per_s));
        } else |_| {}

        var summary = DesignSummary{
            .name = base,
            .title = "",
            .sections = &.{},
            .instance_count = 0,
            .net_count = 0,
            .mtime_sec = mtime_sec,
            .build_ok = false,
        };

        var eval = Evaluator.init(allocator, project_dir);
        defer eval.deinit();
        if (eval.evalFile(full_path)) |result| {
            const block_opt: ?*const env_mod.DesignBlock = switch (result) {
                .design_block => |b| b,
                else => null,
            };
            if (block_opt) |block| {
                summary.title = try allocator.dupe(u8, block.name);
                var names: std.ArrayListUnmanaged([]const u8) = .empty;
                for (block.sections) |s| {
                    try names.append(allocator, try allocator.dupe(u8, s.name));
                }
                // Sub-blocks appear as sections on the block diagram too —
                // include their names so designs that are pure-composition
                // (e.g. a single sub-block wrapper) still show structure.
                if (names.items.len == 0) {
                    for (block.sub_blocks) |sb| {
                        try names.append(allocator, try allocator.dupe(u8, sb.name));
                    }
                }
                summary.sections = try names.toOwnedSlice(allocator);
                summary.instance_count = countInstances(block);
                summary.net_count = countNets(block);
                summary.build_ok = true;
            }
        } else |_| {}

        try summaries.append(allocator, summary);
    }
    const slice = try summaries.toOwnedSlice(allocator);
    std.mem.sort(DesignSummary, slice, {}, struct {
        fn lessThan(_: void, a: DesignSummary, b: DesignSummary) bool {
            return a.mtime_sec > b.mtime_sec;
        }
    }.lessThan);
    return slice;
}

/// Parse the file's top-level forms and return true iff any is a
/// `(design-block ...)`. Used to filter out board definitions and auxiliary
/// .sexp files from list_designs.
fn hasTopLevelDesignBlock(allocator: std.mem.Allocator, path: []const u8) bool {
    const src = infra_fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch return false;
    defer allocator.free(src);
    const nodes = sexpr_parser.parse(allocator, src) catch return false;
    for (nodes) |n| if (n.isForm("design-block")) return true;
    return false;
}

/// Evaluate a design and return the schematic scene-graph JSON the MCP
/// `get_schematic` tool ships back to Claude Code. Same renderer the
/// browser viewer consumes via `/api/scene-graph/:name`.
pub fn renderSceneGraph(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) ToolError![]const u8 {
    const path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = try eval.evalFile(path);
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => return error.NotADesign,
    };

    const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, @constCast(block), bom_path, project_dir) catch |e| warnResolveIdentities(name, e);

    return render_json.renderSceneGraph(allocator, block, project_dir);
}
