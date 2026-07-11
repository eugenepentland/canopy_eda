const std = @import("std");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const edit = @import("edit.zig");
const diag_format = @import("diag_format.zig");
const vfs = @import("vfs.zig");
const history = @import("history.zig");
const serve_root = @import("../serve.zig");
const render_json = @import("../render_json.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const eval_modules = @import("../eval/modules.zig");
const erc_mod = @import("../erc.zig");
const log = @import("../infra/log.zig");
const bom = @import("../bom.zig");
const sexpr_parser = @import("../sexpr/parser.zig");
const ids = @import("../eval/ids.zig");
const review_json_mod = @import("../review_json.zig");
const req_checks = @import("../req_checks.zig");
const component_info = @import("component_info.zig");
const notes = @import("notes.zig");
const symbol_conv = @import("../convert/symbol.zig");
const config = @import("../config.zig");
const component_search = @import("component_search.zig");
const digikey = @import("digikey.zig");
const upload = @import("upload.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const pcb_describe = @import("pcb_describe.zig");
const layout_match = @import("layout_match.zig");
const render_pcb_png = @import("../render_pcb_png.zig");
const docgen = @import("../docgen.zig");
const page_cache = @import("page_cache.zig");

// ── Constants ─────────────────────────────────────────────────────
const name_field_prefix = "{\"name\":";
const ref_des_field_prefix = "{\"ref_des\":";
const function_field = ",\"function\":";
const key_components = "components";
const key_footprints = "footprints";
const err_not_design = "error: not a design";
const err_build_failed = "error: build failed";
const err_line_template = "error: {s}";
const version_snapshot_template = "{{\"ok\":true,\"version\":{d},\"snapshot\":";
const json_net_key = ",\"net\":";
const json_component_key = ",\"component\":";
const json_value_key = ",\"value\":";
const json_manufacturer_key = ",\"manufacturer\":";
const json_description_key = ",\"description\":";
const json_err_open = "{\"ok\":false,\"error\":";
// Shared opening of the part-search envelopes (search_components / resolve_mpn /
// check_stock): `{"ok":true,"query":<q>` then `,"count":N,"results":[`.
const json_ok_query_open = "{\"ok\":true,\"query\":";
const json_count_results_open = ",\"count\":{d},\"results\":[";
const key_part_number = "part_number";
// search_components `limit` arg: default and hard cap.
const search_limit_default: usize = 10;
const search_limit_max: u64 = 50;
// check_stock default is smaller — each result carries full per-packaging price
// ladders, so a handful of exact-ish matches is the useful payload (cap shared).
const stock_limit_default: usize = 5;

const EvalError = @import("../eval/evaluator.zig").EvalError;
const RenderError = render_json.RenderError;
const numeric = @import("../numeric.zig");
/// Error set used by mcp_tools helper fns that orchestrate eval + render
/// + filesystem walks, plus any writer in JSON-emitting helpers.
pub const ToolError = std.mem.Allocator.Error || std.Io.Writer.Error || EvalError || RenderError ||
    std.fs.Dir.Iterator.Error || std.fs.Dir.OpenError || std.fs.File.OpenError || std.fs.File.ReadError ||
    error{ InvalidName, NotADesign, FileTooBig, StreamTooLong, NotOpenForReading, ReadOnlyFileSystem, LinkQuotaExceeded };

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
    .{ .name = "get_pcb_layout_image", .is_mutation = false },
    .{ .name = "describe_pcb_layout", .is_mutation = false },
    .{ .name = "compare_layout_to_starred", .is_mutation = false },
    // PCB layout MUTATION tools — edit the `<design>.layouts.json` sidecar so an
    // agent can take a board schematic → gated Gerbers headless: place parts,
    // draw the board outline, autoroute, save/star, clear copper. Read-only twin
    // `run_fab_readiness` returns the pre-fab gate report. Handlers live in
    // pcb_layout_page.zig (reusing the viewer's own save/route/fab helpers).
    .{ .name = "set_part_poses", .is_mutation = true },
    .{ .name = "set_board_outline", .is_mutation = true },
    .{ .name = "route_pcb", .is_mutation = true },
    .{ .name = "save_pcb_layout", .is_mutation = true },
    .{ .name = "clear_routes", .is_mutation = true },
    .{ .name = "run_fab_readiness", .is_mutation = false },
    .{ .name = "get_version", .is_mutation = false },
    .{ .name = "run_checks", .is_mutation = false },
    // The auto-generated S-expression language reference, rendered live from
    // the evaluator's own dispatch tables (same content as docs/language-forms.md).
    .{ .name = "get_language_reference", .is_mutation = false },
    // Evaluate a lib/modules defmodule standalone (with caller-chosen args)
    // and return its schematic summary / scene graph — module-level design
    // without instantiating it in a real board first.
    .{ .name = "preview_module", .is_mutation = false },
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
    // Fetch a part's ECAD model ZIP from Component Search Engine and import
    // it into the library (component + footprint + pinout + 3D model).
    .{ .name = "download_footprint", .is_mutation = true },
    // Fetch a part's datasheet PDF from Component Search Engine into
    // lib/datasheets/, where read_datasheet can then extract its text.
    .{ .name = "download_datasheet", .is_mutation = true },
    // Search Component Search Engine and return candidate parts (read-only).
    // Pairs with download_footprint / download_datasheet to import a chosen one.
    .{ .name = "search_components", .is_mutation = false },
    // Resolve a fuzzy query to real manufacturer part numbers (+ datasheet
    // URLs, live stock, unit price) via the DigiKey Product Information API
    // (read-only). Feed a chosen MPN to search_components / download_footprint
    // / download_datasheet, or to check_stock for the full price ladder.
    .{ .name = "resolve_mpn", .is_mutation = false },
    // Live DigiKey stock + pricing for a known MPN/orderable number: per-packaging
    // quantity available, MOQ, and the full quantity price-break ladder (read-only).
    .{ .name = "check_stock", .is_mutation = false },
    // Per-design TODO notes (sidecar `<design>.notes.md`). Lets agents
    // log follow-ups for the next revision and mark them complete with
    // a date stamp once the design has been updated.
    .{ .name = "list_design_notes", .is_mutation = false },
    .{ .name = "add_design_note", .is_mutation = true },
    .{ .name = "complete_design_note", .is_mutation = true },
    .{ .name = "reopen_design_note", .is_mutation = true },
    .{ .name = "remove_design_note", .is_mutation = true },
    // Library component `(requirement ...)` rules — datasheet-derived design
    // constraints that live on the part itself and are inherited by every
    // design that instantiates it (vs. design_note, which is per-design).
    .{ .name = "list_component_requirements", .is_mutation = false },
    .{ .name = "add_component_requirement", .is_mutation = true },
    .{ .name = "remove_component_requirement", .is_mutation = true },
    .{ .name = "read_datasheet", .is_mutation = false },
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
    /// When set, `out` holds base64-encoded image bytes and the caller emits an
    /// MCP image content block with this MIME type instead of a text block.
    image_mime: ?[]const u8 = null,
};

/// Dispatch a tool call. Writes the result into `out` and returns how the
/// caller should frame it in the MCP envelope.
pub fn call(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) CallResult {
    // The image tool returns binary content, so it's handled here (not in
    // `callInner`, which only ever produces text) and tagged with its MIME type
    // so the MCP layer frames it as an image content block.
    if (std.mem.eql(u8, tool_name, "get_pcb_layout_image")) {
        const ok = toolGetPcbImage(allocator, project_dir, args_val, out) catch |err| {
            const w = out.writer(allocator);
            w.print(err_line_template, .{@errorName(err)}) catch |e| {
                log.warn("failed to write error msg: {s}", .{@errorName(e)});
            };
            return .{ .ok = false };
        };
        return .{ .ok = ok, .image_mime = if (ok) "image/png" else null };
    }
    const ok = callInner(allocator, project_dir, tool_name, args_val, out) catch |err| {
        const msg = @errorName(err);
        const w = out.writer(allocator);
        w.print(err_line_template, .{msg}) catch |e| {
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
    out: *std.ArrayList(u8),
) !bool {
    if (try dispatchVfs(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchProject(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchInfo(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchPcbLayout(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchParts(allocator, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchLanguage(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchReview(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchNotes(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;
    if (try dispatchRequirements(allocator, project_dir, tool_name, args_val, out)) |ok| return ok;

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
    out: *std.ArrayList(u8),
) !?bool {
    const w = out.writer(allocator);
    if (std.mem.eql(u8, tool_name, "list_designs")) return try toolListDesigns(allocator, project_dir, w);
    if (std.mem.eql(u8, tool_name, "list_library")) return try toolListLibrary(allocator, project_dir, args_val, w);
    if (std.mem.eql(u8, tool_name, "list_history")) return try toolListHistory(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "list_instances")) return try toolListInstances(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "list_free_pins")) return try toolListFreePins(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "get_net")) return try toolGetNet(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "describe_component")) return try toolDescribeComponent(allocator, project_dir, args_val, out);
    return null;
}

/// Diagnostic / introspection tools that don't change project state:
/// scene graph, version counter, run_checks.
fn dispatchInfo(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) !?bool {
    const w = out.writer(allocator);
    if (std.mem.eql(u8, tool_name, "get_schematic")) return try toolGetSchematic(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "describe_pcb_layout")) return try toolDescribePcbLayout(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "compare_layout_to_starred")) return try toolCompareLayoutToStarred(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "get_version")) return try toolGetVersion(args_val, out, allocator);
    if (std.mem.eql(u8, tool_name, "run_checks")) return try toolRunChecks(allocator, project_dir, args_val, out, w);
    if (std.mem.eql(u8, tool_name, "read_datasheet")) return try toolReadDatasheet(allocator, project_dir, args_val, out);
    return null;
}

/// PCB layout mutation tools (+ the read-only fab-readiness twin). These write
/// the `<design>.layouts.json` sidecar (set poses / outline, autoroute, save,
/// clear copper) so an agent can drive a board to gated Gerbers without a
/// browser; the handlers live in `pcb_layout_page.zig` beside the viewer's own
/// save/route/fab endpoints they reuse. Returns null when the tool name matches
/// none of these.
fn dispatchPcbLayout(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) !?bool {
    if (std.mem.eql(u8, tool_name, "set_part_poses")) return try pcb_layout_page.mcpSetPartPoses(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "set_board_outline")) return try pcb_layout_page.mcpSetBoardOutline(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "route_pcb")) return try pcb_layout_page.mcpRoutePcb(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "save_pcb_layout")) return try pcb_layout_page.mcpSavePcbLayout(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "clear_routes")) return try pcb_layout_page.mcpClearRoutes(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "run_fab_readiness")) return try pcb_layout_page.mcpRunFabReadiness(allocator, project_dir, args_val, out);
    return null;
}

/// External part-catalog lookups (read-only, network): Component Search Engine
/// keyword search and the DigiKey resolve-MPN / stock-and-pricing tools. Grouped
/// apart from `dispatchInfo` so each dispatcher stays small. Returns null when
/// the tool name doesn't match any of these.
fn dispatchParts(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) !?bool {
    if (std.mem.eql(u8, tool_name, "search_components")) return try toolSearchComponents(allocator, args_val, out);
    if (std.mem.eql(u8, tool_name, "resolve_mpn")) return try toolResolveMpn(allocator, args_val, out);
    if (std.mem.eql(u8, tool_name, "check_stock")) return try toolCheckStock(allocator, args_val, out);
    return null;
}

/// Language-level tools: the auto-generated S-expression reference and
/// standalone module preview — the agent-facing surface for authoring
/// design/module .sexp files without a host design.
fn dispatchLanguage(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) !?bool {
    if (std.mem.eql(u8, tool_name, "get_language_reference")) return try toolGetLanguageReference(allocator, args_val, out);
    if (std.mem.eql(u8, tool_name, "preview_module")) return try toolPreviewModule(allocator, project_dir, args_val, out);
    return null;
}

/// Mutations on history snapshots — the only mutator outside the VFS
/// surface, since it doesn't touch source files.
fn dispatchReview(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
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
    out: *std.ArrayList(u8),
) !?bool {
    if (std.mem.eql(u8, tool_name, "list_design_notes")) return try toolListDesignNotes(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "add_design_note")) return try toolAddDesignNote(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "complete_design_note")) return try toolMutateDesignNote(allocator, project_dir, args_val, out, notes.TaskMutation.complete);
    if (std.mem.eql(u8, tool_name, "reopen_design_note")) return try toolMutateDesignNote(allocator, project_dir, args_val, out, notes.TaskMutation.reopen);
    if (std.mem.eql(u8, tool_name, "remove_design_note")) return try toolMutateDesignNote(allocator, project_dir, args_val, out, notes.TaskMutation.remove);
    return null;
}

/// Library component `(requirement ...)` editing — list/add/remove the
/// datasheet-derived rules attached to a part. Backed by `component_info`,
/// which splices the component `.sexp` source directly to preserve formatting.
fn dispatchRequirements(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) !?bool {
    if (std.mem.eql(u8, tool_name, "list_component_requirements")) return try toolListComponentRequirements(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "add_component_requirement")) return try toolAddComponentRequirement(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "remove_component_requirement")) return try toolRemoveComponentRequirement(allocator, project_dir, args_val, out);
    return null;
}

fn toolListComponentRequirements(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return component_info.listRequirements(allocator, project_dir, name, out);
}

fn toolAddComponentRequirement(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
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

fn toolRemoveComponentRequirement(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
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

fn toolListDesignNotes(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
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

fn toolAddDesignNote(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
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
    out: *std.ArrayList(u8),
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

fn toolListDesigns(allocator: std.mem.Allocator, project_dir: []const u8, w: anytype) !bool {
    const summaries = try listDesignSummaries(allocator, project_dir);
    try w.writeAll("[");
    for (summaries, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(name_field_prefix);
        try json_writer.writeString(w, s.name);
        try w.writeAll(",\"title\":");
        try json_writer.writeString(w, s.title);
        try w.writeAll(",\"sections\":[");
        for (s.sections, 0..) |sec, si| {
            if (si > 0) try w.writeAll(",");
            try json_writer.writeString(w, sec);
        }
        try w.print("],\"instance_count\":{d},\"net_count\":{d},\"mtime\":{d},\"build_ok\":{s}}}", .{
            s.instance_count, s.net_count, s.mtime_sec, if (s.build_ok) "true" else "false",
        });
    }
    try w.writeAll("]");
    return true;
}

fn toolListLibrary(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, w: anytype) !bool {
    // A blank/whitespace-only query is treated as "no filter" so callers can
    // pass an empty box without accidentally hiding the whole library.
    const query: ?[]const u8 = blk: {
        const q = optionalString(args_val, "query") orelse break :blk null;
        const trimmed = std.mem.trim(u8, q, " \t\r\n");
        break :blk if (trimmed.len == 0) null else trimmed;
    };
    try w.writeAll("{");
    const kinds = [_]struct { field: []const u8, sub: []const u8 }{
        .{ .field = key_components, .sub = key_components },
        .{ .field = "modules", .sub = "modules" },
        .{ .field = "pinouts", .sub = "pinouts" },
        .{ .field = key_footprints, .sub = key_footprints },
    };
    for (kinds, 0..) |k, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\"{s}\":", .{k.field});
        try listLibrarySubdir(allocator, project_dir, k.sub, query, w);
    }
    try w.writeAll("}");
    return true;
}

fn toolListHistory(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const w = out.writer(allocator);
    const snaps = try history.listSnapshots(allocator, project_dir, name);
    try w.writeAll("{\"snapshots\":[");
    for (snaps, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try json_writer.writeString(w, s.id);
        try w.writeAll(json_description_key);
        if (s.description) |d| try json_writer.writeString(w, d) else try w.writeAll("null");
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return true;
}

fn toolListInstances(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return listInstances(allocator, project_dir, name, out.writer(allocator));
}

fn toolListFreePins(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const ref = requireString(args_val, "ref") orelse return missingArg(out, allocator, "ref");
    return listFreePins(allocator, project_dir, name, ref, optionalString(args_val, "filter"), out.writer(allocator));
}

fn toolGetNet(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const net = requireString(args_val, "net") orelse return missingArg(out, allocator, "net");
    return getNet(allocator, project_dir, name, net, out.writer(allocator));
}

fn toolDescribeComponent(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return component_info.describeComponent(allocator, project_dir, name, out);
}

fn toolGetSchematic(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const graph = try renderSceneGraph(allocator, project_dir, name);
    try out.writer(allocator).writeAll(graph);
    return true;
}

/// `get_language_reference` — the auto-generated S-expression language
/// reference, rendered live from the same dispatch tables the evaluator
/// runs on (identical content to docs/language-forms.md, so it can never
/// be stale). Optional `section` returns just one `## ` section; an
/// unknown title errors with the list of valid ones.
fn toolGetLanguageReference(allocator: std.mem.Allocator, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const doc = try docgen.renderLanguageReference(allocator);
    const section = optionalString(args_val, "section") orelse {
        try out.appendSlice(allocator, doc);
        return true;
    };
    if (docgen.extractSection(doc, section)) |body| {
        try out.appendSlice(allocator, body);
        return true;
    }
    const w = out.writer(allocator);
    try w.print("error: unknown section \"{s}\" — valid sections: ", .{section});
    var it = docgen.SectionIterator{ .doc = doc };
    var first = true;
    while (it.next()) |sec| {
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("\"{s}\"", .{sec.title});
    }
    return false;
}

/// `preview_module` — evaluate a lib/modules `(defmodule …)` standalone with
/// caller-chosen arguments against a request-local evaluator (nothing
/// written). This closes the module-level design loop: edit
/// `lib/modules/<m>.sexp` via the VFS tools, preview here (netlist summary +
/// ERC + assertions, or the full scene graph), iterate — no host design
/// needed. For module-level *layout*, pass the module name straight to
/// `get_pcb_layout_image` / `describe_pcb_layout`, which resolve module names
/// via a real instantiation (else a zero-arg call).
fn toolPreviewModule(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const w = out.writer(allocator);
    const module = requireString(args_val, "module") orelse return missingArg(out, allocator, "module");
    if (!isBareModuleName(module)) {
        try w.writeAll("{\"ok\":false,\"error\":\"invalid module name (bare lib/modules name expected)\"}");
        return false;
    }
    const args_text = optionalString(args_val, "args") orelse "";
    const view = optionalString(args_val, "view") orelse "summary";

    // Synthesize a one-sub-block wrapper design and evaluate it in-memory —
    // the same shape modules.resolveModuleBlock uses for the /modules page.
    const source = try std.fmt.allocPrint(
        allocator,
        "(import {s})\n(design-block \"preview\" (sub-block \"{s}\" ({s} {s})))",
        .{ module, module, module, args_text },
    );
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalSource(source) catch |e| {
        try w.writeAll("{\"ok\":false,\"error\":\"module eval failed\",\"diagnostic\":");
        const diag = try diag_format.build(allocator, "<preview>", source, @errorName(e), eval.last_error);
        try diag_format.writeJson(w, diag);
        try w.writeAll("}");
        return false;
    };
    const wrapper: *env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => {
            try w.writeAll("{\"ok\":false,\"error\":\"module did not evaluate to a design block\"}");
            return false;
        },
    };
    if (wrapper.sub_blocks.len == 0) {
        try w.writeAll("{\"ok\":false,\"error\":\"module call produced no sub-block\"}");
        return false;
    }
    const block = wrapper.sub_blocks[0].block;

    if (std.mem.eql(u8, view, "scene_graph")) {
        const graph = try render_json.renderSceneGraph(allocator, block, project_dir);
        try out.appendSlice(allocator, graph);
        return true;
    }
    if (!std.mem.eql(u8, view, "summary")) {
        try w.writeAll("{\"ok\":false,\"error\":\"unknown view (expected summary or scene_graph)\"}");
        return false;
    }
    try writeModuleSummary(allocator, w, project_dir, module, block, eval.assertions.items);
    return true;
}

/// Bare module-name guard for the synthesized preview source — atom
/// characters only, so a crafted name can't splice extra forms into the
/// wrapper design.
fn isBareModuleName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Emit one ERC violation as a JSON object {kind,severity,message[,ref][,net]}.
/// Shared by run_checks, the build report, and preview_module so the three
/// surfaces stay shape-identical.
fn writeErcViolationJson(w: anytype, v: erc_mod.Violation) !void {
    try w.writeAll("{\"kind\":\"");
    try w.writeAll(@tagName(v.kind));
    try w.writeAll("\",\"severity\":\"");
    try w.writeAll(@tagName(v.severity));
    try w.writeAll("\",\"message\":");
    try json_writer.writeString(w, v.message);
    if (v.ref_des.len > 0) {
        try w.writeAll(",\"ref\":");
        try json_writer.writeString(w, v.ref_des);
    }
    if (v.net.len > 0) {
        try w.writeAll(json_net_key);
        try json_writer.writeString(w, v.net);
    }
    try w.writeAll("}");
}

/// Compact JSON summary of an evaluated module block: title, ports,
/// instances, nets, nested sub-blocks, ERC violations, and the assertions
/// recorded during evaluation (a module's design math surfaces here).
/// Boundary `(port …)` nets are expected to look floating in isolation —
/// the description in tools_list_result.json warns agents accordingly.
fn writeModuleSummary(
    allocator: std.mem.Allocator,
    w: anytype,
    project_dir: []const u8,
    module: []const u8,
    block: *const env_mod.DesignBlock,
    assertions: []const env_mod.AssertionResult,
) !void {
    try w.writeAll("{\"ok\":true,\"module\":");
    try json_writer.writeString(w, module);
    try w.writeAll(",\"title\":");
    try json_writer.writeString(w, block.name);
    try w.writeAll(",\"ports\":[");
    for (block.ports, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(name_field_prefix);
        try json_writer.writeString(w, p.name);
        try w.writeAll(json_net_key);
        try json_writer.writeString(w, p.net);
        try w.writeAll(",\"dir\":");
        try json_writer.writeString(w, p.direction);
        try w.writeAll("}");
    }
    try w.writeAll("],\"instances\":[");
    for (block.instances, 0..) |inst, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(ref_des_field_prefix);
        try json_writer.writeString(w, inst.ref_des);
        try w.writeAll(json_component_key);
        try json_writer.writeString(w, inst.component);
        try w.writeAll(json_value_key);
        try json_writer.writeString(w, inst.value);
        try w.writeAll("}");
    }
    try w.writeAll("],\"nets\":[");
    for (block.nets, 0..) |net, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(name_field_prefix);
        try json_writer.writeString(w, net.name);
        try w.print(",\"pin_count\":{d}}}", .{net.pins.len});
    }
    try w.writeAll("],\"sub_blocks\":[");
    for (block.sub_blocks, 0..) |sb, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, sb.name);
    }
    try w.writeAll("],\"erc\":[");
    const violations = try erc_mod.runErc(allocator, block, project_dir);
    var first = true;
    for (violations) |v| {
        if (!first) try w.writeAll(",");
        first = false;
        try writeErcViolationJson(w, v);
    }
    try w.writeAll("],\"assertions\":[");
    for (assertions, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"passed\":{},\"warning\":{},\"message\":", .{ a.passed, a.is_warning });
        try json_writer.writeString(w, a.message);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// Structured spatial facts about the solved placement — the textual twin of
/// `get_pcb_layout_image`, built from the identical placement so the facts
/// always describe the board the image shows.
fn toolDescribePcbLayout(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const opts = pcb_layout_page.PngRequest{
        .route = optionalBool(args_val, "route") orelse false,
        .layout = optionalString(args_val, "layout"),
        .regen = optionalBool(args_val, "regen") orelse false,
        .rough = optionalBool(args_val, "rough") orelse true,
        .sub = optionalString(args_val, "sub"),
    };
    const body = pcb_describe.describeDesign(allocator, project_dir, name, opts) catch |e| {
        try out.writer(allocator).print("error describing pcb layout: {s}", .{@errorName(e)});
        return false;
    };
    try out.appendSlice(allocator, body);
    return true;
}

/// `compare_layout_to_starred` — score the `?rough=1` seed against the starred
/// (default) saved layout: interchangeable-class-matched same-edge agreement +
/// drag, the "is the rough in the right general area to finish by hand" check.
fn toolCompareLayoutToStarred(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const body = layout_match.layoutMatchJson(allocator, project_dir, name) catch |e| {
        try out.writer(allocator).print("error comparing layout to starred: {s}", .{@errorName(e)});
        return false;
    };
    try out.appendSlice(allocator, body);
    return true;
}

/// Render a design's PCB layout to a PNG and write it base64-encoded into `out`
/// (the caller emits it as an MCP image content block). Optional `nets`/`refs`
/// (arrays or comma-separated strings) spotlight a subsystem; `route` overlays
/// copper; `width`/`layout`/`sub`/`regen` mirror the HTTP endpoint. Diagnostic
/// overlays: `blame` (cost heatmap + worst-offenders), `loops` (per-loop nH
/// labels), `dims` (mm dimension leaders), `grid` (mm reference grid), and
/// `compare` (a saved-layout name to diff against — ghosts + movement arrows).
fn toolGetPcbImage(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    var opts = pcb_layout_page.PngRequest{
        .highlight_nets = jsonStrList(allocator, args_val, "nets"),
        .highlight_refs = jsonStrList(allocator, args_val, "refs"),
        .route = optionalBool(args_val, "route") orelse false,
        .layout = optionalString(args_val, "layout"),
        .regen = optionalBool(args_val, "regen") orelse false,
        .sub = optionalString(args_val, "sub"),
        .blame = optionalBool(args_val, "blame") orelse false,
        .loop_labels = optionalBool(args_val, "loops") orelse false,
        .dims = optionalBool(args_val, "dims") orelse false,
        .grid = optionalBool(args_val, "grid") orelse false,
        .compare = optionalString(args_val, "compare"),
        .pins = jsonStrList(allocator, args_val, "pins"),
        .crop = optionalString(args_val, "crop"),
        .sheet = optionalBool(args_val, "sheet") orelse false,
        .critique = optionalBool(args_val, "critique") orelse false,
        .rough = optionalBool(args_val, "rough") orelse true,
    };
    if (optionalU64(args_val, "width")) |w| opts.width = @intCast(@min(w, @as(u64, 4000)));
    if (optionalU64(args_val, "r")) |r| opts.crop_r = @floatFromInt(r);
    if (optionalString(args_val, "names")) |s| opts.names = std.meta.stringToEnum(render_pcb_png.NameMode, s);

    const png_bytes = pcb_layout_page.renderDesignPng(allocator, project_dir, name, opts) catch |e| {
        try out.writer(allocator).print("error rendering pcb layout: {s}", .{@errorName(e)});
        return false;
    };
    const enc = std.base64.standard.Encoder;
    const b64 = try allocator.alloc(u8, enc.calcSize(png_bytes.len));
    _ = enc.encode(b64, png_bytes);
    try out.appendSlice(allocator, b64);
    return true;
}

/// Parse a JSON arg that may be a string array or a comma-separated string into
/// a list of trimmed, non-empty tokens (slices into the parsed JSON, valid for
/// the request). Absent/empty → empty slice.
fn jsonStrList(allocator: std.mem.Allocator, args_val: ?std.json.Value, key: []const u8) []const []const u8 {
    const av = args_val orelse return &.{};
    if (av != .object) return &.{};
    const v = av.object.get(key) orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    if (v == .array) {
        for (v.array.items) |item| {
            if (item == .string and item.string.len > 0) list.append(allocator, item.string) catch break;
        }
    } else if (v == .string) {
        var it = std.mem.tokenizeScalar(u8, v.string, ',');
        while (it.next()) |tok| {
            const t = std.mem.trim(u8, tok, " \t");
            if (t.len > 0) list.append(allocator, t) catch break;
        }
    }
    return list.toOwnedSlice(allocator) catch &.{};
}

fn toolGetVersion(args_val: ?std.json.Value, out: *std.ArrayList(u8), allocator: std.mem.Allocator) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const w = out.writer(allocator);
    try w.print("{{\"version\":{d}}}", .{serve_root.getLiveVersion(name)});
    return true;
}

fn toolRunChecks(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8), w: anytype) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    return runChecks(allocator, project_dir, name, optionalString(args_val, "severity"), optionalString(args_val, "changed_since"), w);
}

fn toolRestoreVersion(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const id = requireString(args_val, "id") orelse return missingArg(out, allocator, "id");
    const result = edit.restoreDesignCore(allocator, project_dir, name, id) catch |err| return editErrorMsg(out, allocator, err);
    const w = out.writer(allocator);
    try w.print(version_snapshot_template, .{result.version});
    if (result.snapshot) |s| try json_writer.writeString(w, s) else try w.writeAll("null");
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
    out: *std.ArrayList(u8),
) !?bool {
    const Ctx = struct { allocator: std.mem.Allocator, project_dir: []const u8, args: ?std.json.Value, out: *std.ArrayList(u8) };
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
    if (std.mem.eql(u8, tool_name, "download_footprint")) return try toolDownloadFootprint(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    if (std.mem.eql(u8, tool_name, "download_datasheet")) return try toolDownloadDatasheet(ctx.allocator, ctx.project_dir, ctx.args, ctx.out);
    return null;
}

fn toolReadFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const path = requireString(args_val, "path") orelse return missingArg(out, allocator, "path");
    return vfs.readFile(allocator, project_dir, path, optionalU64(args_val, "offset"), optionalU64(args_val, "limit"), out);
}

fn toolWriteFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const path = requireString(args_val, "path") orelse return missingArg(out, allocator, "path");
    const content = requireString(args_val, "content") orelse return missingArg(out, allocator, "content");
    return vfs.writeFile(allocator, project_dir, path, content, optionalString(args_val, "expected_sha256"), out);
}

fn toolEditFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const path = requireString(args_val, "path") orelse return missingArg(out, allocator, "path");
    const old_s = requireString(args_val, "old_string") orelse return missingArg(out, allocator, "old_string");
    const new_s = requireString(args_val, "new_string") orelse return missingArg(out, allocator, "new_string");
    const replace_mode: vfs.ReplaceMode = if (optionalBool(args_val, "replace_all") orelse false) .all else .single;
    return vfs.editFile(allocator, project_dir, path, old_s, new_s, optionalString(args_val, "expected_sha256"), replace_mode, out);
}

fn toolListDir(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const path = optionalString(args_val, "path") orelse "";
    const list_mode: vfs.ListMode = if (optionalBool(args_val, "recursive") orelse false) .recursive else .flat;
    return vfs.listDir(allocator, project_dir, path, list_mode, optionalU64(args_val, "max_entries"), out);
}

fn toolGlob(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const pattern = requireString(args_val, "pattern") orelse return missingArg(out, allocator, "pattern");
    return vfs.glob(allocator, project_dir, pattern, optionalString(args_val, "base"), out);
}

fn toolDeleteFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const path = requireString(args_val, "path") orelse return missingArg(out, allocator, "path");
    return vfs.deleteFile(allocator, project_dir, path, out);
}

fn toolMoveFile(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const from = requireString(args_val, "from") orelse return missingArg(out, allocator, "from");
    const to = requireString(args_val, "to") orelse return missingArg(out, allocator, "to");
    return vfs.moveFile(allocator, project_dir, from, to, out);
}

fn toolBuild(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const report = edit.rebuildDesign(allocator, project_dir, name);
    const w = out.writer(allocator);
    try writeBuildReport(w, report);
    return true;
}

/// Fetch a part's ECAD model ZIP from Component Search Engine and run it
/// through the same import pipeline as the `/api/upload-zip` route, creating
/// `lib/{components,footprints,pinouts,models}` entries. The `connect.sid`
/// session cookie is read server-side from `CSE_CONNECT_SID` (via
/// `config.cseConnectSid`) — never passed over MCP. Returns the created
/// library names on success, or `{ok:false,error}` if search, download
/// (expired cookie), or import fails.
fn toolDownloadFootprint(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const part_number = requireString(args_val, key_part_number) orelse return missingArg(out, allocator, key_part_number);
    const manufacturer = optionalString(args_val, "manufacturer");
    const w = out.writer(allocator);

    const sid = config.cseConnectSid(allocator) orelse {
        try w.writeAll("{\"ok\":false,\"error\":\"CSE_CONNECT_SID is not set on the server; cannot authenticate to Component Search Engine\"}");
        return false;
    };

    const dl = component_search.downloadFootprint(allocator, part_number, manufacturer, sid) catch |err| {
        try w.writeAll("{\"ok\":false,\"stage\":\"download\",\"error\":");
        try json_writer.writeString(w, component_search.errorMessage(err));
        try w.writeAll("}");
        return false;
    };

    const imp = upload.importZipBytes(allocator, project_dir, dl.zip_bytes, dl.suggested_filename) catch |err| {
        try w.writeAll("{\"ok\":false,\"stage\":\"import\",\"downloaded\":");
        try json_writer.writeString(w, dl.suggested_filename);
        try w.writeAll(",\"error\":");
        try json_writer.writeString(w, upload.importErrorMessage(err));
        try w.writeAll("}");
        return false;
    };

    try w.writeAll("{\"ok\":true,\"part_name\":");
    try json_writer.writeString(w, dl.part_name);
    try w.writeAll(json_manufacturer_key);
    try json_writer.writeString(w, dl.manufacturer);
    try w.writeAll(",\"samac_id\":");
    try json_writer.writeString(w, dl.samac_id);
    try w.writeAll(",\"zip\":");
    try json_writer.writeString(w, dl.suggested_filename);
    try w.print(",\"zip_size\":{d},\"component\":", .{dl.zip_bytes.len});
    try json_writer.writeString(w, imp.component_name);
    try w.writeAll(",\"footprint\":");
    try json_writer.writeString(w, imp.footprint_name);
    try w.writeAll(",\"pinout\":");
    try json_writer.writeString(w, imp.pinout_name);
    try w.print(",\"has_3d_model\":{s}", .{if (imp.has_3d) "true" else "false"});
    try w.writeAll(",\"component_action\":");
    try json_writer.writeString(w, @tagName(imp.component));
    try w.writeAll("}");
    return true;
}

/// Fetch a part's datasheet PDF and store it under `lib/datasheets/`, where
/// `read_datasheet` can extract its text. Tries Component Search Engine first
/// (scraping the datasheet link via `CSE_CONNECT_SID`); if CSE has no datasheet
/// on file (or isn't configured), falls back to DigiKey's `datasheet_url`
/// (`DIGIKEY_CLIENT_ID` / `DIGIKEY_CLIENT_SECRET`), unwrapping any manufacturer
/// interstitial and validating the `%PDF` magic. All credentials are read
/// server-side, never over MCP. The success envelope's `source` says which
/// provider supplied it; when both fail, `{ok:false,error,cse_error,digikey_error}`.
fn toolDownloadDatasheet(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const part_number = requireString(args_val, key_part_number) orelse return missingArg(out, allocator, key_part_number);
    const manufacturer = optionalString(args_val, "manufacturer");
    const w = out.writer(allocator);

    var cse_msg: []const u8 = "";
    switch (try tryCseDatasheet(w, allocator, project_dir, part_number, manufacturer)) {
        .ok => return true,
        .store_failed => return false,
        .unavailable => |m| cse_msg = m,
    }

    var dk_msg: []const u8 = "";
    switch (try tryDigikeyDatasheet(w, allocator, project_dir, part_number, manufacturer)) {
        .ok => return true,
        .store_failed => return false,
        .unavailable => |m| dk_msg = m,
    }

    try w.writeAll(json_err_open);
    try json_writer.writeString(w, "no datasheet found via Component Search Engine or DigiKey");
    try w.writeAll(",\"cse_error\":");
    try json_writer.writeString(w, cse_msg);
    try w.writeAll(",\"digikey_error\":");
    try json_writer.writeString(w, dk_msg);
    try w.writeAll("}");
    return false;
}

/// Outcome of one datasheet provider: `ok`/`store_failed` mean the envelope is
/// already written (success / a terminal store error); `unavailable` carries a
/// reason and means "try the next provider".
const DatasheetOutcome = union(enum) {
    ok,
    store_failed,
    unavailable: []const u8,
};

/// Try Component Search Engine. `unavailable` when `CSE_CONNECT_SID` is unset or
/// CSE has no datasheet for the part.
fn tryCseDatasheet(
    w: anytype,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    part_number: []const u8,
    manufacturer: ?[]const u8,
) !DatasheetOutcome {
    const sid = config.cseConnectSid(allocator) orelse return .{ .unavailable = "CSE_CONNECT_SID not set" };
    const ds = component_search.downloadDatasheet(allocator, part_number, manufacturer, sid) catch |err|
        return .{ .unavailable = component_search.datasheetErrorMessage(err) };
    const ok = try finishDatasheet(w, allocator, project_dir, "componentsearchengine", ds.filename, ds.pdf_bytes, ds.part_name, ds.manufacturer, ds.source_url);
    return if (ok) .ok else .store_failed;
}

/// Try DigiKey's `datasheet_url`. `unavailable` when DigiKey credentials are
/// unset or it has no resolvable datasheet PDF for the part.
fn tryDigikeyDatasheet(
    w: anytype,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    part_number: []const u8,
    manufacturer: ?[]const u8,
) !DatasheetOutcome {
    const client_id = config.digikeyClientId(allocator) orelse return .{ .unavailable = "DIGIKEY_CLIENT_ID not set" };
    const client_secret = config.digikeyClientSecret(allocator) orelse return .{ .unavailable = "DIGIKEY_CLIENT_SECRET not set" };
    const base: []const u8 = config.digikeyApiBase(allocator) orelse digikey.default_base;
    const ds = digikey.downloadDatasheet(allocator, base, client_id, client_secret, part_number, manufacturer) catch |err|
        return .{ .unavailable = digikey.datasheetErrorMessage(err) };
    const ok = try finishDatasheet(w, allocator, project_dir, "digikey", ds.mpn, ds.pdf_bytes, ds.mpn, ds.manufacturer, ds.source_url);
    return if (ok) .ok else .store_failed;
}

/// Store a fetched datasheet PDF and emit the success envelope.
fn finishDatasheet(
    w: anytype,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    source: []const u8,
    filename: []const u8,
    pdf_bytes: []const u8,
    part: []const u8,
    manufacturer: []const u8,
    url: []const u8,
) !bool {
    const upload_datasheet = @import("upload_datasheet.zig");
    const stored = upload_datasheet.storeDatasheet(allocator, project_dir, filename, pdf_bytes) catch |err| {
        // Reuse the HTTP route's error→JSON mapping; null means OutOfMemory.
        try w.writeAll(upload_datasheet.storeErrorBody(err) orelse return err);
        return false;
    };
    try w.writeAll("{\"ok\":true,\"source\":");
    try json_writer.writeString(w, source);
    try w.writeAll(",\"file\":");
    try json_writer.writeString(w, stored.name);
    try w.print(",\"size\":{d},\"part\":", .{stored.size});
    try json_writer.writeString(w, part);
    try w.writeAll(json_manufacturer_key);
    try json_writer.writeString(w, manufacturer);
    try w.writeAll(",\"datasheet_url\":");
    try json_writer.writeString(w, url);
    try w.writeAll("}");
    return true;
}

/// Search Component Search Engine and return candidate parts without importing
/// anything — the read-only counterpart to `download_footprint`. The agent
/// searches here, then passes a chosen `part_number` (with the reported
/// `manufacturer` to disambiguate) to download_footprint/download_datasheet.
/// `CSE_CONNECT_SID` is read server-side (never over MCP). Returns
/// `{ok:true,query,count,results:[{part_number,manufacturer,has_model,has_datasheet}]}`,
/// or `{ok:false,error}` on a network/auth failure.
fn toolSearchComponents(allocator: std.mem.Allocator, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const query = requireString(args_val, "query") orelse return missingArg(out, allocator, "query");
    const limit: usize = if (optionalU64(args_val, "limit")) |l| @intCast(@min(l, search_limit_max)) else search_limit_default;
    const w = out.writer(allocator);

    const sid = config.cseConnectSid(allocator) orelse {
        try w.writeAll("{\"ok\":false,\"error\":\"CSE_CONNECT_SID is not set on the server; add it to .env\"}");
        return false;
    };

    const hits = component_search.searchComponents(allocator, query, sid, limit) catch |err| {
        try w.writeAll(json_err_open);
        try json_writer.writeString(w, component_search.searchErrorMessage(err));
        try w.writeAll("}");
        return false;
    };

    try w.writeAll(json_ok_query_open);
    try json_writer.writeString(w, query);
    try w.print(json_count_results_open, .{hits.len});
    for (hits, 0..) |h, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"part_number\":");
        try json_writer.writeString(w, h.part_name);
        try w.writeAll(json_manufacturer_key);
        try json_writer.writeString(w, h.manufacturer);
        try w.print(",\"has_model\":{s},\"has_datasheet\":{s}}}", .{
            if (h.samac_id != null) "true" else "false",
            if (h.datasheet_url != null) "true" else "false",
        });
    }
    try w.writeAll("]}");
    return true;
}

/// Resolve a fuzzy query (vague description or partial part number) to real
/// manufacturer part numbers via the DigiKey Product Information API v4 —
/// read-only, imports nothing. Pairs with `search_components` /
/// `download_footprint` / `download_datasheet`: take a returned `mpn` and pass
/// it on. Credentials (`DIGIKEY_CLIENT_ID` / `DIGIKEY_CLIENT_SECRET`, optional
/// `DIGIKEY_API_BASE` for the sandbox) are read server-side, never over MCP.
/// Returns `{ok:true,query,count,results:[{mpn,manufacturer,description,
/// datasheet_url,product_url,digikey_part_number}]}` or `{ok:false,error}`.
fn toolResolveMpn(allocator: std.mem.Allocator, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const query = requireString(args_val, "query") orelse return missingArg(out, allocator, "query");
    const limit: usize = if (optionalU64(args_val, "limit")) |l| @intCast(@min(l, search_limit_max)) else search_limit_default;
    const w = out.writer(allocator);

    const creds = (try digikeyCreds(allocator, w)) orelse return false;
    const products = digikey.resolveMpn(allocator, creds.base, creds.client_id, creds.client_secret, query, limit) catch |err| {
        try w.writeAll(json_err_open);
        try json_writer.writeString(w, digikey.searchErrorMessage(err));
        try w.writeAll("}");
        return false;
    };

    try w.writeAll(json_ok_query_open);
    try json_writer.writeString(w, query);
    try w.print(json_count_results_open, .{products.len});
    for (products, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"mpn\":");
        try json_writer.writeString(w, p.mpn);
        try w.writeAll(json_manufacturer_key);
        try json_writer.writeString(w, p.manufacturer);
        try w.writeAll(json_description_key);
        try json_writer.writeString(w, p.description);
        try w.writeAll(",\"datasheet_url\":");
        try writeOptString(w, p.datasheet_url);
        try w.writeAll(",\"product_url\":");
        try writeOptString(w, p.product_url);
        try w.writeAll(",\"digikey_part_number\":");
        try writeOptString(w, p.digikey_part_number);
        // At-a-glance stock + price + lifecycle (full ladders via check_stock).
        try w.print(",\"quantity_available\":{d},\"unit_price\":", .{p.quantity_available});
        try writeOptNum(w, p.unit_price);
        try w.writeAll(",\"product_status\":");
        try writeOptString(w, p.product_status);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return true;
}

/// Live DigiKey stock + pricing for a known MPN/orderable number. Resolves the
/// query through the same keyword search as `resolve_mpn`, then emits the full
/// per-packaging inventory and quantity price-break ladder for each match — the
/// "is it actually on the shelf, and what does qty-N cost" step. Read-only.
/// Returns `{ok:true,query,count,results:[{mpn,manufacturer,description,
/// product_status,quantity_available,unit_price,product_url,digikey_part_number,
/// variations:[{digikey_part_number,package_type,quantity_available,
/// minimum_order_quantity,price_breaks:[{break_quantity,unit_price,
/// total_price}]}]}]}` or `{ok:false,error}`.
fn toolCheckStock(allocator: std.mem.Allocator, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const query = requireString(args_val, "query") orelse return missingArg(out, allocator, "query");
    const limit: usize = if (optionalU64(args_val, "limit")) |l| @intCast(@min(l, search_limit_max)) else stock_limit_default;
    const w = out.writer(allocator);

    const creds = (try digikeyCreds(allocator, w)) orelse return false;
    const products = digikey.resolveMpn(allocator, creds.base, creds.client_id, creds.client_secret, query, limit) catch |err| {
        try w.writeAll(json_err_open);
        try json_writer.writeString(w, digikey.searchErrorMessage(err));
        try w.writeAll("}");
        return false;
    };

    try w.writeAll(json_ok_query_open);
    try json_writer.writeString(w, query);
    try w.print(json_count_results_open, .{products.len});
    for (products, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"mpn\":");
        try json_writer.writeString(w, p.mpn);
        try w.writeAll(json_manufacturer_key);
        try json_writer.writeString(w, p.manufacturer);
        try w.writeAll(json_description_key);
        try json_writer.writeString(w, p.description);
        try w.writeAll(",\"product_status\":");
        try writeOptString(w, p.product_status);
        try w.print(",\"quantity_available\":{d},\"unit_price\":", .{p.quantity_available});
        try writeOptNum(w, p.unit_price);
        try w.writeAll(",\"product_url\":");
        try writeOptString(w, p.product_url);
        try w.writeAll(",\"digikey_part_number\":");
        try writeOptString(w, p.digikey_part_number);
        try w.writeAll(",\"variations\":[");
        for (p.variations, 0..) |v, vi| {
            if (vi > 0) try w.writeAll(",");
            try w.writeAll("{\"digikey_part_number\":");
            try writeOptString(w, v.digikey_part_number);
            try w.writeAll(",\"package_type\":");
            try writeOptString(w, v.package_type);
            try w.print(",\"quantity_available\":{d},\"minimum_order_quantity\":{d},\"price_breaks\":[", .{
                v.quantity_available, v.minimum_order_quantity,
            });
            for (v.price_breaks, 0..) |b, bi| {
                if (bi > 0) try w.writeAll(",");
                try w.print("{{\"break_quantity\":{d},\"unit_price\":{d},\"total_price\":{d}}}", .{
                    b.break_quantity, b.unit_price, b.total_price,
                });
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
    return true;
}

/// DigiKey OAuth credentials + API base, read server-side. On a missing
/// credential this writes the `{ok:false,error}` envelope into `w` and returns
/// null, so a caller does `(try digikeyCreds(a, w)) orelse return false;`.
const DigiKeyCreds = struct { client_id: []u8, client_secret: []u8, base: []const u8 };
fn digikeyCreds(allocator: std.mem.Allocator, w: anytype) !?DigiKeyCreds {
    const client_id = config.digikeyClientId(allocator) orelse {
        try w.writeAll("{\"ok\":false,\"error\":\"DIGIKEY_CLIENT_ID is not set on the server; add it to .env\"}");
        return null;
    };
    const client_secret = config.digikeyClientSecret(allocator) orelse {
        try w.writeAll("{\"ok\":false,\"error\":\"DIGIKEY_CLIENT_SECRET is not set on the server; add it to .env\"}");
        return null;
    };
    return .{
        .client_id = client_id,
        .client_secret = client_secret,
        .base = config.digikeyApiBase(allocator) orelse digikey.default_base,
    };
}

/// Emit a JSON string, or `null` when the optional is absent.
fn writeOptString(w: anytype, s: ?[]const u8) !void {
    if (s) |v| {
        try json_writer.writeString(w, v);
    } else {
        try w.writeAll("null");
    }
}

/// Emit a JSON number (decimal, never scientific), or `null` when absent.
fn writeOptNum(w: anytype, n: ?f64) !void {
    if (n) |v| {
        try w.print("{d}", .{v});
    } else {
        try w.writeAll("null");
    }
}

/// Regenerate `lib/pinouts/<name>.sexp` from `<source>` (a `.kicad_sym`
/// in `lib/sources/`). Mirrors what the `netlisp convert-pinout` CLI does
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
    out: *std.ArrayList(u8),
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
    var read_buf: std.ArrayList(u8) = .empty;
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

    var write_buf: std.ArrayList(u8) = .empty;
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
    try json_writer.writeString(w, source);
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

/// One scored library entry, used when `list_library` is given a `query`.
/// Names are duped because the directory iterator reuses its name buffer
/// across `next()` calls.
const LibMatch = struct {
    name: []const u8,
    description: ?[]const u8,
    score: u32,

    /// Higher score first; ties broken alphabetically so output is stable.
    fn better(_: void, a: LibMatch, b: LibMatch) bool {
        if (a.score != b.score) return a.score > b.score;
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

// Fuzzy-match scoring weights for `fuzzyScore` / `libEntryScore`. A
// contiguous substring lands in the ~1000+ band; a scattered subsequence
// stays well below it. Magnitudes only matter relative to each other — they
// decide ranking order, never a pass/fail threshold.
const substring_base: u32 = 1000; // any contiguous hit
const prefix_bonus: u32 = 500; // hit at index 0
const word_boundary_bonus: u32 = 250; // hit right after a non-alphanumeric
const proximity_credit: u32 = 600; // budget the position/length penalties eat into
const max_pos_penalty: u32 = 400; // cap on the later-in-string penalty
const max_len_penalty: u32 = 200; // cap on the longer-haystack penalty
const len_penalty_divisor: u32 = 4; // 1 penalty point per 4 chars of haystack
const subsequence_base: u32 = 100; // floor for an in-order subsequence hit
const subsequence_run_bonus: u32 = 10; // per char of the longest contiguous run
const name_weight: u32 = 4; // a name hit outweighs a description-only hit

/// Case-insensitive fuzzy score of `needle` against `haystack`. Returns 0
/// for no match; higher is a better match. A contiguous (substring) hit
/// outranks a scattered subsequence hit, a hit at the start or on a word
/// boundary outranks one buried mid-token, and a shorter haystack outranks
/// a longer one for the same hit. This lets `list_library` rank "stm32" →
/// "stm32n657l0h3q" first without the caller needing an exact name.
fn fuzzyScore(needle: []const u8, haystack: []const u8) u32 {
    if (needle.len == 0) return 1;
    if (haystack.len == 0) return 0;

    // Contiguous substring is the strong signal.
    if (std.ascii.indexOfIgnoreCase(haystack, needle)) |pos| {
        var score: u32 = substring_base;
        if (pos == 0) {
            score += prefix_bonus;
        } else if (!std.ascii.isAlphanumeric(haystack[pos - 1])) {
            score += word_boundary_bonus;
        }
        const pos_penalty: u32 = @min(@as(u32, @intCast(pos)), max_pos_penalty);
        const len_penalty: u32 = @min(@as(u32, @intCast(haystack.len)) / len_penalty_divisor, max_len_penalty);
        return score + proximity_credit - pos_penalty - len_penalty;
    }

    // Subsequence fallback: needle chars appear in order but not adjacent.
    // Greedy left-to-right matching correctly decides subsequence existence.
    var ni: usize = 0;
    var run: u32 = 0;
    var best_run: u32 = 0;
    for (haystack) |hc| {
        if (ni >= needle.len) break;
        if (std.ascii.toLower(hc) == std.ascii.toLower(needle[ni])) {
            ni += 1;
            run += 1;
            best_run = @max(best_run, run);
        } else {
            run = 0;
        }
    }
    if (ni < needle.len) return 0; // not every needle char was consumed
    // Always below any substring hit; longer contiguous runs rank higher.
    return subsequence_base + best_run * subsequence_run_bonus;
}

/// Combine name + description scores. The name dominates (×4) so a name
/// match always outranks a description-only match, but description text
/// still surfaces a part whose name doesn't contain the query.
fn libEntryScore(query: []const u8, name: []const u8, description: ?[]const u8) u32 {
    const name_score = fuzzyScore(query, name);
    const desc_score = if (description) |d| fuzzyScore(query, d) else 0;
    return name_score *| name_weight +| desc_score;
}

/// Write a JSON array of {name, description} objects for every .sexp file
/// in `{project_dir}/lib/{sub}/`. Description is extracted from the first
/// top-level (description "...") form in the file, or empty if absent.
/// With a non-null `query`, only entries whose name or description fuzzily
/// match are emitted, ranked best-first; with null `query`, every entry is
/// emitted in directory order.
pub fn listLibrarySubdir(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    sub: []const u8,
    query: ?[]const u8,
    w: anytype,
) !void {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/{s}", .{ project_dir, sub });
    defer allocator.free(dir_path);

    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        try w.writeAll("[]");
        return;
    };
    defer dir.close();

    const q = query orelse {
        // No filter — stream every entry in directory order.
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
            try writeLibEntry(w, base, description);
        }
        try w.writeAll("]");
        return;
    };

    // Filtered — score every entry, keep matches, emit ranked best-first.
    var matches: std.ArrayList(LibMatch) = .empty;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        const base = entry.name[0 .. entry.name.len - ".sexp".len];
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(full_path);
        const description = extractDescription(allocator, full_path);

        const score = libEntryScore(q, base, description);
        if (score == 0) {
            if (description) |d| allocator.free(d);
            continue;
        }
        try matches.append(allocator, .{
            .name = try allocator.dupe(u8, base),
            .description = description,
            .score = score,
        });
    }
    std.sort.heap(LibMatch, matches.items, {}, LibMatch.better);

    try w.writeAll("[");
    for (matches.items, 0..) |m, i| {
        if (i > 0) try w.writeAll(",");
        try writeLibEntry(w, m.name, m.description);
    }
    try w.writeAll("]");
}

/// Emit one `{"name":..,"description":..}` library entry.
fn writeLibEntry(w: anytype, name: []const u8, description: ?[]const u8) !void {
    try w.writeAll(name_field_prefix);
    try json_writer.writeString(w, name);
    try w.writeAll(json_description_key);
    if (description) |d| try json_writer.writeString(w, d) else try w.writeAll("\"\"");
    try w.writeAll("}");
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
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const nb = evalNamedBlock(allocator, project_dir, name, &eval) catch |e| switch (e) {
        error.NotADesign => {
            try w.writeAll(err_not_design);
            return false;
        },
        else => {
            try w.writeAll(err_build_failed);
            return false;
        },
    };
    const block = nb.block;

    if (!nb.is_module) {
        const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
        defer allocator.free(bom_path);
        bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);
    }

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
            try json_writer.writeString(w, e.key_ptr.*);
        }
        try w.writeAll("],\"changed_nets\":[");
        var it2 = changed_nets.iterator();
        first = true;
        while (it2.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
            try json_writer.writeString(w, e.key_ptr.*);
        }
        try w.writeAll("]");
    }

    try w.writeAll(",\"erc\":[");
    const erc_all = try runErcForNamedBlock(allocator, nb, project_dir);
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
        try writeErcViolationJson(w, v);
    }
    try w.writeAll("]}");
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
pub fn listInstances(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    w: anytype,
) !bool {
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const nb = evalNamedBlock(allocator, project_dir, name, &eval) catch |e| switch (e) {
        error.NotADesign => {
            try w.writeAll(err_not_design);
            return false;
        },
        else => {
            try w.writeAll(err_build_failed);
            return false;
        },
    };
    const block = nb.block;

    try w.writeAll("{\"instances\":[");
    for (block.instances, 0..) |inst, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(ref_des_field_prefix);
        try json_writer.writeString(w, inst.ref_des);
        try w.writeAll(",\"label\":");
        try json_writer.writeString(w, inst.label);
        try w.writeAll(json_component_key);
        try json_writer.writeString(w, inst.component);
        try w.writeAll(",\"symbol\":");
        try json_writer.writeString(w, inst.symbol);
        try w.writeAll(json_value_key);
        try json_writer.writeString(w, inst.value);

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
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const nb = evalNamedBlock(allocator, project_dir, name, &eval) catch |e| switch (e) {
        error.NotADesign => {
            try w.writeAll(err_not_design);
            return false;
        },
        else => {
            try w.writeAll(err_build_failed);
            return false;
        },
    };
    const block = nb.block;

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
        try json_writer.writeString(w, pin_id);
        try w.writeAll(function_field);
        try json_writer.writeString(w, fname);
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
        try json_writer.writeString(w, pin_id);
        try w.writeAll(function_field);
        try json_writer.writeString(w, fname);
        try w.writeAll(json_net_key);
        try json_writer.writeString(w, net_name);
        try w.print(",\"category\":\"{s}\"}}", .{categoryName(cat)});
    }
    try w.writeAll("]}");
    return true;
}

/// Emit every pin connected to `net_name`, plus every passive instance
/// (ref_des starting with R/L/C/F/D) whose ref_des appears on the net.
pub fn getNet(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    net_name: []const u8,
    w: anytype,
) !bool {
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const nb = evalNamedBlock(allocator, project_dir, name, &eval) catch |e| switch (e) {
        error.NotADesign => {
            try w.writeAll(err_not_design);
            return false;
        },
        else => {
            try w.writeAll(err_build_failed);
            return false;
        },
    };
    const block = nb.block;

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

    try w.writeAll(name_field_prefix);
    try json_writer.writeString(w, net.name);
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
            const is_passive = switch (c0) {
                'R', 'L', 'C', 'F', 'D' => true,
                else => false,
            };
            if (is_passive) {
                try passive_refs.put(allocator, inst.ref_des, {});
            }
            break;
        }
        try w.writeAll(ref_des_field_prefix);
        try json_writer.writeString(w, p.ref_des);
        try w.writeAll(",\"pin\":");
        try json_writer.writeString(w, p.pin);
        try w.writeAll(function_field);
        try json_writer.writeString(w, fname);
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
            try w.writeAll(ref_des_field_prefix);
            try json_writer.writeString(w, inst.ref_des);
            try w.writeAll(json_component_key);
            try json_writer.writeString(w, inst.component);
            try w.writeAll(json_value_key);
            try json_writer.writeString(w, inst.value);
            try w.writeAll("}");
            break;
        }
    }
    try w.writeAll("]}");
    return true;
}

fn missingArg(out: *std.ArrayList(u8), allocator: std.mem.Allocator, key: []const u8) !bool {
    const w = out.writer(allocator);
    try w.print("error: missing argument \"{s}\"", .{key});
    return false;
}

fn editErrorMsg(out: *std.ArrayList(u8), allocator: std.mem.Allocator, err: edit.EditError) !bool {
    const w = out.writer(allocator);
    try w.print(err_line_template, .{@errorName(err)});
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
        return numeric.checkedInt(u64, v.float);
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
    if (report.snapshot) |s| try json_writer.writeString(w, s) else try w.writeAll("null");
    try w.writeAll(",\"error\":");
    if (report.error_message) |m| try json_writer.writeString(w, m) else try w.writeAll("null");
    // Structured source-located build diagnostic (file/line/col/message/
    // source_line) so an agent can jump straight to the failing form.
    try w.writeAll(",\"diagnostic\":");
    if (report.diagnostic) |d| try diag_format.writeJson(w, d) else try w.writeAll("null");
    try w.writeAll(",\"assertion_failures\":[");
    for (report.assertion_failures, 0..) |a, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"message\":");
        try json_writer.writeString(w, a.message);
        try w.print(",\"is_warning\":{s}}}", .{if (a.is_warning) "true" else "false"});
    }
    try w.writeAll("],\"erc\":[");
    for (report.erc, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try writeErcViolationJson(w, v);
    }
    try w.writeAll("]}");
}

/// Write `s` as a JSON string literal (with escapes) to `w`.
/// Scan `{project_dir}/src/` recursively and return the basename of every
/// file whose top-level form is a `(design-block …)`. Helper for the MCP
/// `list_designs` tool and the index page's design list. Sibling
/// `<name>.checks.sexp` files (autoloaded verifications) are skipped.
pub fn listDesignNames(allocator: std.mem.Allocator, project_dir: []const u8) ToolError![][]const u8 {
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_path);

    var dir = infra_fs.cwd().openDir(src_path, .{ .iterate = true }) catch return &[_][]const u8{};
    defer dir.close();

    var names: std.ArrayList([]const u8) = .empty;
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
    /// ERC violation counts by severity (0 when the build failed). Drive the
    /// home dashboard's red/yellow status chips.
    erc_errors: usize = 0,
    erc_warnings: usize = 0,
    /// Distinct lib/modules names instantiated anywhere in the design's
    /// sub-block tree. Lets the home page show "used by …" on module cards
    /// without re-evaluating every design a second time.
    modules_used: []const []const u8 = &.{},
    /// Failed (non-warning) `(assert …)` results from the evaluation.
    assert_fails: usize = 0,
    /// Still-open tasks in the design's `.notes.md` sidecar.
    open_notes: usize = 0,
    /// True when the design declares placement-cohesion `(group …)` forms
    /// (`block.groups`) — the grouping the rough seed coheres. Surfaced as the
    /// home page's "grouping" tag so the layout workflow (author grouping →
    /// rough → star) is visible at a glance.
    has_groups: bool = false,
    /// True when the evaluated design declares fabrication intent — a
    /// top-level `(board …)` outline or a `(kicad-pcb …)` target. Such a block
    /// is a fabricable *board*; otherwise it is a reusable *subcircuit*. Drives
    /// the home page's Board/Subcircuit role tag + filter (the role is
    /// content-derived, not folder-derived).
    is_board: bool = false,
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

// ── Design-summary cache ───────────────────────────────────────────────
//
// The home page (GET /), /api/designs, and the MCP list_designs tool all call
// listDesignSummaries, which fully evaluates every design and runs ERC +
// BOM resolution + the notes scan — ~60 ms
// for the current design set, recomputed identically on every load. We cache
// each design's summary across requests, keyed by name and invalidated by the
// evaluation's file read-set (page_cache.FileSet — design, checks, every
// imported lib file, plus the .bom/.refdes.json/.notes.md siblings) and the
// live version. A valid hit is a handful of stat() calls plus a memcpy. The
// stored copy lives in page_allocator (the request arena dies per response);
// hits dupe back into the request arena. Bounded by the design-file count.

const page = std.heap.page_allocator;

const SummaryCacheEntry = struct {
    summary: DesignSummary,
    files: page_cache.FileSet,
    live_version: u32,
};

var summary_cache_mutex: std.Thread.Mutex = .{};
var summary_cache: std.StringHashMapUnmanaged(SummaryCacheEntry) = .empty;

/// Deep-copy a summary's owned strings into `alloc` (every `[]const u8` /
/// `[]const []const u8` field). Scalars copy by value.
fn dupeSummary(alloc: std.mem.Allocator, s: DesignSummary) std.mem.Allocator.Error!DesignSummary {
    const sections = try alloc.alloc([]const u8, s.sections.len);
    for (s.sections, 0..) |sec, i| sections[i] = try alloc.dupe(u8, sec);
    const mods = try alloc.alloc([]const u8, s.modules_used.len);
    for (s.modules_used, 0..) |m, i| mods[i] = try alloc.dupe(u8, m);
    return .{
        .name = try alloc.dupe(u8, s.name),
        .title = try alloc.dupe(u8, s.title),
        .sections = sections,
        .instance_count = s.instance_count,
        .net_count = s.net_count,
        .mtime_sec = s.mtime_sec,
        .build_ok = s.build_ok,
        .erc_errors = s.erc_errors,
        .erc_warnings = s.erc_warnings,
        .modules_used = mods,
        .assert_fails = s.assert_fails,
        .open_notes = s.open_notes,
        .has_groups = s.has_groups,
        .is_board = s.is_board,
    };
}

/// Free a page_allocator-owned summary's strings (used when an entry is
/// replaced).
fn freeSummary(alloc: std.mem.Allocator, s: DesignSummary) void {
    alloc.free(s.name);
    alloc.free(s.title);
    for (s.sections) |sec| alloc.free(sec);
    alloc.free(s.sections);
    for (s.modules_used) |m| alloc.free(m);
    alloc.free(s.modules_used);
}

/// Return a request-arena copy of the cached summary for `name` when a valid
/// entry exists (read-set unchanged and live version matches), else null.
fn summaryCacheGet(arena: std.mem.Allocator, name: []const u8, live_version: u32) ?DesignSummary {
    summary_cache_mutex.lock();
    defer summary_cache_mutex.unlock();
    const e = summary_cache.getPtr(name) orelse return null;
    if (e.live_version != live_version or !e.files.isValid()) return null;
    return dupeSummary(arena, e.summary) catch null;
}

/// Cache `summary` for `name`, duping it + the read-set into page_allocator and
/// freeing any prior entry. `scratch` is the request arena.
fn summaryCachePut(
    scratch: std.mem.Allocator,
    eval: *const Evaluator,
    project_dir: []const u8,
    name: []const u8,
    summary: DesignSummary,
    live_version: u32,
) void {
    const files = page_cache.capture(scratch, eval, project_dir, name) catch return;
    const stored = dupeSummary(page, summary) catch {
        files.deinit();
        return;
    };
    const key = page.dupe(u8, name) catch {
        files.deinit();
        freeSummary(page, stored);
        return;
    };

    summary_cache_mutex.lock();
    defer summary_cache_mutex.unlock();
    const gop = summary_cache.getOrPut(page, key) catch {
        files.deinit();
        freeSummary(page, stored);
        page.free(key);
        return;
    };
    if (gop.found_existing) {
        page.free(key); // map keeps the original key
        gop.value_ptr.files.deinit();
        freeSummary(page, gop.value_ptr.summary);
    }
    gop.value_ptr.* = .{ .summary = stored, .files = files, .live_version = live_version };
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

    var summaries: std.ArrayList(DesignSummary) = .empty;
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".sexp")) continue;
        if (std.mem.endsWith(u8, entry.basename, ".checks.sexp")) continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.path });
        defer allocator.free(full_path);
        const base = try allocator.dupe(u8, entry.basename[0 .. entry.basename.len - ".sexp".len]);

        // Serve the cached summary when this design's source files are
        // unchanged. Checked BEFORE hasTopLevelDesignBlock (a full re-parse of
        // the file) so a hit skips that parse too — a cached entry is proof the
        // file is a design. live_version is read before the eval so a bump
        // mid-build is treated as a miss next time rather than baked in.
        const live_version = serve_root.getLiveVersion(base);
        if (summaryCacheGet(allocator, base, live_version)) |cached| {
            try summaries.append(allocator, cached);
            continue;
        }

        if (!hasTopLevelDesignBlock(allocator, full_path)) continue;

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
                var names: std.ArrayList([]const u8) = .empty;
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
                summary.has_groups = block.groups.len > 0;
                // Content-derived board/subcircuit role: a block is a fabricable
                // *board* iff it declares fabrication intent (a (board …) outline
                // or a (kicad-pcb …) target); otherwise it is a reusable
                // subcircuit. Folder is not consulted.
                summary.is_board = block.board.present or
                    block.kicad_pcb_path != null;

                // Status-chip roll-up for the home dashboard: ERC severities
                // (same .bom-resolved path the review endpoint uses), failed
                // non-warning assertions, and open .notes.md tasks. Each
                // degrades to 0 on failure rather than dropping the summary.
                const bom_path = paths.designSiblingPath(allocator, project_dir, base, ".bom") catch null;
                if (bom_path) |bp| {
                    defer allocator.free(bp);
                    bom.resolveIdentities(allocator, @constCast(block), bp, project_dir) catch |e| warnResolveIdentities(base, e);
                }
                const violations = erc_mod.runErc(allocator, @constCast(block), project_dir) catch &[_]erc_mod.Violation{};
                for (violations) |v| {
                    if (v.severity == .@"error") {
                        summary.erc_errors += 1;
                    } else if (v.severity == .warning) {
                        summary.erc_warnings += 1;
                    }
                }
                for (eval.assertions.items) |a| {
                    if (!a.passed and !a.is_warning) summary.assert_fails += 1;
                }

                var used: std.ArrayList([]const u8) = .empty;
                try collectModuleUses(allocator, block, &used);
                summary.modules_used = try used.toOwnedSlice(allocator);
            }
        } else |_| {}
        summary.open_notes = countOpenNotes(allocator, project_dir, base);

        // Cache only successful builds: a failed eval has an incomplete read-set
        // (it may have errored before reaching some imports), so its
        // invalidation set can't be trusted. Failed builds are rare and cheap to
        // recompute.
        if (summary.build_ok) summaryCachePut(allocator, &eval, project_dir, base, summary, live_version);

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

/// Open-task count from `<design>.notes.md` — 0 when the sidecar doesn't
/// exist or can't be parsed. Backs the home dashboard's notes chip.
fn countOpenNotes(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) usize {
    var raw: ?[]u8 = null;
    const parsed = notes.loadNotes(allocator, project_dir, name, &raw) catch return 0;
    var open: usize = 0;
    for (parsed.tasks) |t| {
        if (t.completed == null) open += 1;
    }
    return open;
}

/// Walk a block's sub-block tree and append each distinct `source` (the
/// module name a `(sub-block …)` instantiates) to `out`, depth-first.
fn collectModuleUses(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    out: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    for (block.sub_blocks) |sb| {
        if (sb.source.len > 0) {
            var seen = false;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, sb.source)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) try out.append(allocator, try allocator.dupe(u8, sb.source));
        }
        try collectModuleUses(allocator, sb.block, out);
    }
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

/// How `evalNamedBlock` resolved a name: a design source under `src/`, or
/// a `lib/modules/` module synthesized as a zero-arg call (parameter
/// defaults supply the arguments).
pub const NamedBlock = struct {
    block: *env_mod.DesignBlock,
    is_module: bool,
};

/// Evaluate `name` as a design, or — when no `src/<name>.sexp` exists and
/// `lib/modules/<name>.sexp` does — as a standalone module instantiation.
/// This is what lets the read-only by-name tools (get_schematic,
/// run_checks, list_instances, …) accept module names the
/// same way the PCB tools already do. The module path returns the module's
/// own evaluated block (the wrapper's sole sub-block). `eval` is
/// caller-owned and must outlive the returned block.
pub fn evalNamedBlock(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    eval: *Evaluator,
) ToolError!NamedBlock {
    const path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(path);
    const have_design = blk: {
        infra_fs.cwd().access(path, .{}) catch break :blk false;
        break :blk true;
    };
    if (have_design) {
        const result = try eval.evalFile(path);
        switch (result) {
            .design_block => |b| return .{ .block = b, .is_module = false },
            // A defmodule file (returns .nil) means `name` resolved via the
            // lib/modules fallback in designSourcePath — not a real src/ design.
            // Fall through to instantiate it as a module below.
            else => {},
        }
    }

    if (!isBareModuleName(name)) return error.FileNotFound;
    const mod_path = try std.fmt.allocPrint(allocator, "{s}/lib/modules/{s}.sexp", .{ project_dir, name });
    defer allocator.free(mod_path);
    infra_fs.cwd().access(mod_path, .{}) catch return error.FileNotFound;
    // Instantiate the module by name with zero arguments — its (param default)s
    // supply the values (defaults-first), via the single shared helper. The
    // returned block borrows `eval`'s arena — the caller keeps `eval` alive —
    // and is stamped `.embedded` by `callModule`.
    const result = try eval_modules.instantiateStandalone(eval, name);
    switch (result) {
        .design_block => |b| return .{ .block = b, .is_module = true },
        else => return error.NotADesign,
    }
}

/// Run ERC on a named block. A standalone module render and a full design go
/// through the same checks; nothing is suppressed by role.
pub fn runErcForNamedBlock(
    allocator: std.mem.Allocator,
    nb: NamedBlock,
    project_dir: []const u8,
) std.mem.Allocator.Error![]const erc_mod.Violation {
    return erc_mod.runErc(allocator, nb.block, project_dir);
}

/// Evaluate a design (or module) and return the schematic scene-graph JSON
/// the MCP `get_schematic` tool ships back to Claude Code. Same renderer
/// the browser viewer consumes via `/api/scene-graph/:name`.
pub fn renderSceneGraph(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) ToolError![]const u8 {
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const nb = try evalNamedBlock(allocator, project_dir, name, &eval);

    if (!nb.is_module) {
        const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
        defer allocator.free(bom_path);
        bom.resolveIdentities(allocator, nb.block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);
    }

    return render_json.renderSceneGraph(allocator, nb.block, project_dir);
}

fn toolReadDatasheet(allocator: std.mem.Allocator, project_dir: []const u8, args_val: ?std.json.Value, out: *std.ArrayList(u8)) !bool {
    const raw_name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const w = out.writer(allocator);

    const upload_datasheet = @import("upload_datasheet.zig");
    const sanitized = upload_datasheet.sanitizeFilename(allocator, raw_name) catch |e| {
        try w.print("{{\"ok\":false,\"error\":\"invalid name: {s}\"}}", .{@errorName(e)});
        return false;
    };
    defer allocator.free(sanitized);

    const path = try std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, sanitized });
    defer allocator.free(path);

    // Check if the file exists
    infra_fs.cwd().access(path, .{}) catch {
        try w.writeAll("{\"ok\":false,\"error\":\"datasheet not found\"}");
        return false;
    };

    const run_res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "ps2ascii", path },
    }) catch |err| {
        try w.print("{{\"ok\":false,\"error\":\"failed to run ps2ascii: {s}\"}}", .{@errorName(err)});
        return false;
    };
    defer {
        allocator.free(run_res.stdout);
        allocator.free(run_res.stderr);
    }

    if (run_res.term != .Exited or run_res.term.Exited != 0) {
        try w.writeAll("{\"ok\":false,\"error\":\"ps2ascii returned error\"}");
        return false;
    }

    try w.writeAll("{\"ok\":true,\"content\":");
    try json_writer.writeString(w, run_res.stdout);
    try w.writeAll("}");
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────

test "fuzzyScore returns 0 for a non-match" {
    // spec: serve/mcp_tools - fuzzyScore returns 0 when the needle does not match the haystack as a substring or subsequence
    try std.testing.expectEqual(@as(u32, 0), fuzzyScore("xyz", "stm32n6"));
    // 'q' and 'z' never appear, so not even a subsequence.
    try std.testing.expectEqual(@as(u32, 0), fuzzyScore("qz", "buck"));
}

test "fuzzyScore ranks a substring above a subsequence" {
    // spec: serve/mcp_tools - fuzzyScore ranks a contiguous substring hit above a scattered subsequence hit
    const contiguous = fuzzyScore("stm32", "stm32n657l0h3q"); // substring (prefix)
    const scattered = fuzzyScore("s3q", "stm32n657l0h3q"); // subsequence only
    try std.testing.expect(scattered > 0);
    try std.testing.expect(contiguous > scattered);
}

test "fuzzyScore ranks a prefix above a mid-token hit" {
    // spec: serve/mcp_tools - fuzzyScore ranks a prefix hit above a mid-token hit for the same needle
    const prefix = fuzzyScore("cap", "cap-0402"); // hit at index 0
    const mid = fuzzyScore("cap", "decap-tool"); // hit mid-token (after 'e')
    try std.testing.expect(mid > 0);
    try std.testing.expect(prefix > mid);
}

test "libEntryScore ranks a name match above a description-only match" {
    // spec: serve/mcp_tools - libEntryScore ranks a name match above a description-only match
    const name_hit = libEntryScore("buck", "buck-converter", "a power thing");
    const desc_hit = libEntryScore("buck", "tps62823", "12V-to-3.3V buck regulator");
    try std.testing.expect(desc_hit > 0);
    try std.testing.expect(name_hit > desc_hit);
}

test "list_library query returns only matching entries ranked best-first" {
    // spec: serve/mcp_tools - list_library with a query returns only fuzzily-matching entries ranked best-first
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/stm32n657l0h3q.sexp", .data = "(component \"stm32n657l0h3q\" (description \"STM32 MCU\"))\n" });
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/cap-0402.sexp", .data = "(component \"cap-0402\" (description \"100nF cap\"))\n" });
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/lt3045.sexp", .data = "(component \"lt3045\" (description \"LDO designed for STM32 rails\"))\n" });
    const proj = try tmp.dir.realpathAlloc(alloc, ".");

    var out: std.ArrayList(u8) = .empty;
    try listLibrarySubdir(alloc, proj, "components", "stm32", out.writer(alloc));

    // The matching part appears; the unrelated cap is filtered out.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "stm32n657l0h3q") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "cap-0402") == null);
    // lt3045 matches only via its description, so it ranks after the name hit.
    const name_pos = std.mem.indexOf(u8, out.items, "stm32n657l0h3q").?;
    const desc_pos = std.mem.indexOf(u8, out.items, "lt3045").?;
    try std.testing.expect(name_pos < desc_pos);
}

test "list_library without a query lists every entry" {
    // spec: serve/mcp_tools - list_library without a query (or a blank one) lists every entry
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/aaa.sexp", .data = "(component \"aaa\")\n" });
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/bbb.sexp", .data = "(component \"bbb\")\n" });
    const proj = try tmp.dir.realpathAlloc(alloc, ".");

    var out: std.ArrayList(u8) = .empty;
    try listLibrarySubdir(alloc, proj, "components", null, out.writer(alloc));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "aaa") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "bbb") != null);
}

/// (test helper) True when `name` is a registered tool in the `tools` table.
fn isKnownTool(name: []const u8) bool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return true;
    }
    return false;
}

/// (test helper) The embedded tools/list JSON and the `tools` registration
/// table declare exactly the same tool names — checked both directions plus
/// a count match, so adding a tool to one site without the other fails.
fn jsonMatchesToolTable(alloc: std.mem.Allocator) !bool {
    var arena_inst = std.heap.ArenaAllocator.init(alloc);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, tools_list_result, .{});
    const list = (root.object.get("tools") orelse return false).array.items;
    if (list.len != tools.len) return false;
    for (list) |item| {
        const jname = item.object.get("name") orelse return false;
        if (!isKnownTool(jname.string)) return false;
    }
    for (tools) |t| {
        var found = false;
        for (list) |item| {
            const jname = item.object.get("name") orelse continue;
            if (std.mem.eql(u8, jname.string, t.name)) found = true;
        }
        if (!found) return false;
    }
    return true;
}

// spec: serve/mcp_tools - The tools registration table and the embedded tools_list_result.json declare exactly the same tool names
test "tools table matches tools_list_result.json" {
    try std.testing.expect(try jsonMatchesToolTable(std.testing.allocator));
}

test "finishDatasheet returns false when the store rejects the bytes" {
    // The `return false` after a store failure must signal failure; a
    // `false`->`true` flip would report success on a rejected datasheet.
    // Non-PDF bytes make storeDatasheet fail with NotPdf before any write.
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const w = out.writer(alloc);
    const ok = try finishDatasheet(w, alloc, "/proj", "digikey", "x.pdf", "not a pdf", "PART", "MFR", "url");
    try std.testing.expect(!ok);
}
