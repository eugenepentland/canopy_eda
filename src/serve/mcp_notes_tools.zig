//! Per-design note and library-component `(requirement …)` MCP tool handlers,
//! extracted from `mcp_tools.zig` (which stays the top-level dispatcher). The
//! two `dispatch*` fns are the public entry points; the note handlers edit the
//! `<design>.notes.md` sidecar via `notes.zig` and the requirement handlers
//! splice a component's `.sexp` source via `component_info.zig`. Arg parsing +
//! the JSON string writer are reused from `mcp_tools` / `json_writer` verbatim,
//! so the handlers behave identically to their pre-extraction selves.
const std = @import("std");
const json_writer = @import("../json_writer.zig");
const notes = @import("notes.zig");
const component_info = @import("component_info.zig");
const mcp_tools = @import("mcp_tools.zig");

const requireString = mcp_tools.requireString;
const optionalString = mcp_tools.optionalString;
const optionalU64 = mcp_tools.optionalU64;
const missingArg = mcp_tools.missingArg;

// ── Library component requirements ────────────────────────────────────

/// Library component `(requirement …)` editing — list/add/remove the
/// datasheet-derived rules attached to a part. Backed by `component_info`,
/// which splices the component `.sexp` source directly to preserve formatting.
/// Returns null when the tool name matches none of these.
pub fn dispatchRequirements(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) component_info.ReqError!?bool {
    if (std.mem.eql(u8, tool_name, "list_component_requirements"))
        return try listComponentRequirements(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "add_component_requirement"))
        return try addComponentRequirement(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "remove_component_requirement"))
        return try removeComponentRequirement(allocator, project_dir, args_val, out);
    return null;
}

fn listComponentRequirements(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) component_info.ReqError!bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return component_info.listRequirements(allocator, project_dir, name, out);
}

fn addComponentRequirement(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) component_info.ReqError!bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const text = requireString(args_val, "text") orelse return missingArg(out, allocator, "text");
    const ref_page: ?u32 = if (optionalU64(args_val, "ref_page")) |p| @intCast(p) else null;
    return component_info.addRequirement(
        allocator,
        project_dir,
        name,
        text,
        optionalString(args_val, "ref_pdf"),
        ref_page,
        optionalString(args_val, "ref_quote"),
        optionalString(args_val, "check"),
        out,
    );
}

fn removeComponentRequirement(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) component_info.ReqError!bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return component_info.removeRequirement(
        allocator,
        project_dir,
        name,
        optionalString(args_val, "id"),
        optionalString(args_val, "text"),
        out,
    );
}

// ── Per-design notes ──────────────────────────────────────────────────

/// Per-design note sidecar (`<design>.notes.md`) editing — list follow-ups,
/// add a new one, and stamp/clear completion dates. Returns null when the tool
/// name matches none of these.
pub fn dispatchNotes(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!?bool {
    if (std.mem.eql(u8, tool_name, "list_design_notes"))
        return try listDesignNotes(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "add_design_note"))
        return try addDesignNote(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "complete_design_note"))
        return try mutateDesignNote(allocator, project_dir, args_val, out, notes.TaskMutation.complete);
    if (std.mem.eql(u8, tool_name, "reopen_design_note"))
        return try mutateDesignNote(allocator, project_dir, args_val, out, notes.TaskMutation.reopen);
    if (std.mem.eql(u8, tool_name, "remove_design_note"))
        return try mutateDesignNote(allocator, project_dir, args_val, out, notes.TaskMutation.remove);
    return null;
}

fn listDesignNotes(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
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
    try json_writer.writeString(w, parsed.scratchpad);
    try w.writeAll("}");
    return true;
}

fn addDesignNote(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
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

fn mutateDesignNote(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
    mode: notes.TaskMutation,
) std.mem.Allocator.Error!bool {
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

fn writeNoteJsonMcp(w: anytype, t: notes.Note) std.mem.Allocator.Error!void {
    try w.writeAll("{\"id\":");
    try json_writer.writeString(w, t.id);
    try w.writeAll(",\"text\":");
    try json_writer.writeString(w, t.text);
    try w.writeAll(",\"created\":");
    try json_writer.writeString(w, t.created);
    if (t.completed) |c| {
        try w.writeAll(",\"completed\":");
        try json_writer.writeString(w, c);
    } else {
        try w.writeAll(",\"completed\":null");
    }
    try w.writeAll("}");
}
