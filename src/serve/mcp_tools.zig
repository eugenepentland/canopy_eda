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
const ids = @import("../eval/ids.zig");
const review_mod = @import("../review.zig");
const review_json_mod = @import("../review_json.zig");
const review_state_mod = @import("../review_state.zig");

/// One entry per MCP tool. Keep in sync with `tools_list_result` below and
/// with the dispatch arms in `callInner`. Adding a new tool should start here,
/// not with a scatter across three separate sites.
const ToolEntry = struct {
    name: []const u8,
    is_mutation: bool,
};

const tools = [_]ToolEntry{
    .{ .name = "list_designs", .is_mutation = false },
    .{ .name = "read_design", .is_mutation = false },
    .{ .name = "write_design", .is_mutation = true },
    .{ .name = "edit_value", .is_mutation = true },
    .{ .name = "edit_section", .is_mutation = true },
    .{ .name = "replace_instance", .is_mutation = true },
    .{ .name = "get_schematic", .is_mutation = false },
    .{ .name = "get_version", .is_mutation = false },
    .{ .name = "run_checks", .is_mutation = false },
    .{ .name = "list_history", .is_mutation = false },
    .{ .name = "restore_version", .is_mutation = true },
    .{ .name = "list_library", .is_mutation = false },
    .{ .name = "read_library_file", .is_mutation = false },
    .{ .name = "edit_note", .is_mutation = true },
    .{ .name = "add_import", .is_mutation = true },
    .{ .name = "set_instance_pin", .is_mutation = true },
    .{ .name = "list_instances", .is_mutation = false },
    .{ .name = "list_free_pins", .is_mutation = false },
    .{ .name = "get_net", .is_mutation = false },
    .{ .name = "add_component_parameter", .is_mutation = true },
    .{ .name = "get_review_state", .is_mutation = false },
    .{ .name = "set_review_state", .is_mutation = true },
};

/// Tools that mutate .sexp files — gated to writer/admin roles.
pub fn isMutationTool(name: []const u8) bool {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t.is_mutation;
    }
    return false;
}

pub const tools_list_result =
    \\{"tools":[
    \\{"name":"list_designs","description":"List designs available in this project (one per .sexp file in src/ containing a top-level design-block). Returns an array of objects with fields: name (file basename), title (human-readable design-block title), sections (array of top-level section names), instance_count, net_count, mtime (Unix seconds of last source modification), build_ok (false if the design failed to evaluate, in which case counts and sections are empty).","inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
    \\{"name":"read_design","description":"Return the full .sexp source text for a design. Agents should read, then optionally call write_design with an edited version.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Design name (without .sexp)"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"write_design","description":"Create or overwrite a design's .sexp with the full new source text. The previous version is auto-snapshotted before the write. Triggers a live rebuild and returns the new version + snapshot id.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"source":{"type":"string","description":"Full S-expression source for the design"}},"required":["name","source"],"additionalProperties":false}},
    \\{"name":"edit_value","description":"Quick single-value tweak: change a component's value by reference designator (e.g. set C3 to 100nF). Same snapshot/rebuild semantics as write_design.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"ref":{"type":"string","description":"Reference designator like C3, R1, U2"},"value":{"type":"string","description":"New value string"}},"required":["name","ref","value"],"additionalProperties":false}},
    \\{"name":"edit_section","description":"Replace an entire (section \"SECTION_NAME\" ...) form with new_source. Use this when changing one section of the design instead of rewriting the whole file. new_source must include the outer (section ...) parens. Fails with AmbiguousMatch if the section name appears more than once. Snapshots and rebuilds like write_design.","inputSchema":{"type":"object","properties":{"name":{"type":"string","description":"Design name"},"section_name":{"type":"string","description":"Exact name of the section to replace, as in (section \"Name\" ...)"},"new_source":{"type":"string","description":"Full replacement (section ...) form"}},"required":["name","section_name","new_source"],"additionalProperties":false}},
    \\{"name":"replace_instance","description":"Replace an entire (instance \"REF\" ...) form by reference designator. Use this to add/remove pins, swap the component family, or change any single-instance detail without rewriting the surrounding section. new_source must include the outer (instance ...) parens. Snapshots and rebuilds.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"ref":{"type":"string","description":"Reference designator of the instance to replace"},"new_source":{"type":"string","description":"Full replacement (instance ...) form"}},"required":["name","ref","new_source"],"additionalProperties":false}},
    \\{"name":"get_schematic","description":"Fetch the current scene graph JSON for a design. This is the same payload the browser viewer renders.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"get_version","description":"Return the current live version integer for a design. Increments on every mutation.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"run_checks","description":"Run ERC and/or DRC on a design. Optional filters: scope (\"erc\"|\"drc\"|\"both\", default \"both\"); severity (\"error\"|\"warning\"|\"info\", default all); changed_since (snapshot id from list_history — only ERC violations whose ref_des or net was added/removed since that snapshot are returned). DRC is not filtered by changed_since because its violations carry no structured ref. Returns {scope,filtered,changed_refs,changed_nets,erc:[...],drc:{violations,count}|null}.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"scope":{"type":"string","enum":["erc","drc","both"]},"severity":{"type":"string","enum":["error","warning","info"]},"changed_since":{"type":"string","description":"Snapshot id to diff the current design against; ERC violations are filtered to those touching instances or nets that differ."}},"required":["name"],"additionalProperties":false}},
    \\{"name":"generate_review","description":"Build a structured design review document. Returns the same JSON shape as GET /api/review/:name: {design_name,title,generated_at,summary,sections[],power_budget[],bom[],assertions[],unresolved[]}. summary.status is pass|warn|fail. Rails in power_budget are sorted tightest first. unresolved is the flat list of error+warning ERC/DRC violations. Use this for a top-to-bottom audit before declaring a design done.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"list_history","description":"List snapshot ids for a design, newest first. Each id is a timestamp usable with restore_version.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"restore_version","description":"Restore a design to a prior snapshot. The current state is itself snapshotted first, so the restore is undoable.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"id":{"type":"string","description":"Snapshot id from list_history"}},"required":["name","id"],"additionalProperties":false}},
    \\{"name":"list_library","description":"List all names available in the project's lib/. Returns {components,modules,pinouts,footprints}, each entry with name + optional description. Use these names in (import ...) forms and instance definitions.","inputSchema":{"type":"object","properties":{},"additionalProperties":false}},
    \\{"name":"read_library_file","description":"Return the .sexp source for a library file — use this to inspect a component's pin list, a module's parameters, or a footprint's pads before wiring them up.","inputSchema":{"type":"object","properties":{"kind":{"type":"string","enum":["component","module","pinout","footprint"],"description":"Which lib/ subdirectory to read from"},"name":{"type":"string","description":"File name without .sexp"}},"required":["kind","name"],"additionalProperties":false}},
    \\{"name":"edit_note","description":"Replace the text of a single (note \"...\") form, located by a substring match on the note's current text. Returns AmbiguousMatch if the substring matches more than one note; use the full current text to disambiguate.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"match":{"type":"string","description":"Substring of the note's current text used to locate it; must uniquely identify one note"},"new_text":{"type":"string","description":"Full replacement text for the note body (no surrounding quotes)"}},"required":["name","match","new_text"],"additionalProperties":false}},
    \\{"name":"add_import","description":"Add one item to the top-level (import ...) list. Dedup is word-boundary aware; returns DuplicateImport if the item already appears.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"item":{"type":"string","description":"Library item name (atom-like; no whitespace, quotes, or parens)"}},"required":["name","item"],"additionalProperties":false}},
    \\{"name":"set_instance_pin","description":"Change one pin on an instance to a new net without rewriting the whole instance. Lighter-weight alternative to replace_instance for single-pin edits.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"ref":{"type":"string"},"pin":{"type":"string"},"net":{"type":"string"}},"required":["name","ref","pin","net"],"additionalProperties":false}},
    \\{"name":"list_instances","description":"List every instance in the design with its ref_des (auto-assigned), label (user-given name from source), component family, symbol, value, and pin count. Use this to bridge between source-side names (stm32, expansion) and board-side ref_des (U1, U8).","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"list_free_pins","description":"List unassigned pins on an instance with their default pinout function names and a best-effort category (gpio|power|clock|analog|other). Use for picking GPIOs for new peripherals without scanning the full pinout file.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"ref":{"type":"string","description":"Reference designator of the instance (e.g. U1)"},"filter":{"type":"string","enum":["gpio","power","clock","analog","other"],"description":"Optional category filter"}},"required":["name","ref"],"additionalProperties":false}},
    \\{"name":"get_net","description":"Return every pin connection on a net plus any passive instances (R/L/C/F/D) on it. Use to audit decoupling or verify wiring without scanning the whole source.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"net":{"type":"string"}},"required":["name","net"],"additionalProperties":false}},
    \\{"name":"add_component_parameter","description":"Append a (parameter \"NAME\" TYPE) declaration to a library component file under lib/components/. Use to fix ERC \"missing value\" errors on user-uploaded components that lack a parameter slot. Snapshots the prior library file to history/_lib. Does not rebuild any design — re-run a build to pick up the change.","inputSchema":{"type":"object","properties":{"component":{"type":"string","description":"Component file name (without .sexp)"},"param_name":{"type":"string","description":"Parameter name (e.g. value, color)"},"param_type":{"type":"string","description":"Parameter type atom (e.g. string, capacitance, resistance, number)"}},"required":["component","param_name","param_type"],"additionalProperties":false}},
    \\{"name":"get_review_state","description":"Return the per-section review state: the checklist items (with id, text, checked) and per-section approval (approved, approved_by, approved_at). One entry per section slug present in the design. Use this to see which sections are still pending review.","inputSchema":{"type":"object","properties":{"name":{"type":"string"}},"required":["name"],"additionalProperties":false}},
    \\{"name":"set_review_state","description":"Mutate one section's review state in one call: optionally append new checklist items, toggle existing ones by id, delete items by id, and/or set the approval flag + reviewer. At least one of add_items/toggle/delete/approved must be present. approved=true stamps approved_at with the current UTC time.","inputSchema":{"type":"object","properties":{"name":{"type":"string"},"section_slug":{"type":"string","description":"Slug of the section to edit (match what generate_review returns)"},"add_items":{"type":"array","items":{"type":"string"},"description":"Texts for new checklist items to append"},"toggle":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"checked":{"type":"boolean"}},"required":["id","checked"]},"description":"Existing items to toggle by id"},"delete":{"type":"array","items":{"type":"string"},"description":"Item ids to delete"},"approved":{"type":"boolean","description":"Set the section-level approval flag"},"reviewer":{"type":"string","description":"Reviewer name stamped when approved=true"}},"required":["name","section_slug"],"additionalProperties":false}}
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
        const summaries = try listDesignSummaries(allocator, project_dir);
        try w.writeAll("[");
        for (summaries, 0..) |s, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try writeJsonString(w, s.name);
            try w.writeAll(",\"title\":");
            try writeJsonString(w, s.title);
            try w.writeAll(",\"sections\":[");
            for (s.sections, 0..) |sec, si| {
                if (si > 0) try w.writeAll(",");
                try writeJsonString(w, sec);
            }
            try w.print("],\"instance_count\":{d},\"net_count\":{d},\"mtime\":{d},\"build_ok\":{s}}}", .{
                s.instance_count,
                s.net_count,
                s.mtime_sec,
                if (s.build_ok) "true" else "false",
            });
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

    if (std.mem.eql(u8, tool_name, "edit_section")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const section_name = requireString(args_val, "section_name") orelse return missingArg(out, allocator, "section_name");
        const new_source = requireString(args_val, "new_source") orelse return missingArg(out, allocator, "new_source");
        const result = edit.editSectionCore(allocator, project_dir, name, section_name, new_source) catch |err| return editErrorMsg(out, allocator, err);
        try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
        if (result.snapshot) |s| try writeJsonString(w, s) else try w.writeAll("null");
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "replace_instance")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const ref = requireString(args_val, "ref") orelse return missingArg(out, allocator, "ref");
        const new_source = requireString(args_val, "new_source") orelse return missingArg(out, allocator, "new_source");
        const result = edit.replaceInstanceCore(allocator, project_dir, name, ref, new_source) catch |err| return editErrorMsg(out, allocator, err);
        try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
        if (result.snapshot) |s| try writeJsonString(w, s) else try w.writeAll("null");
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "run_checks")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const scope = optionalString(args_val, "scope") orelse "both";
        const severity = optionalString(args_val, "severity");
        const changed_since = optionalString(args_val, "changed_since");
        return try runChecks(allocator, project_dir, name, scope, severity, changed_since, w);
    }

    if (std.mem.eql(u8, tool_name, "generate_review")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        return try generateReview(allocator, project_dir, name, w);
    }

    if (std.mem.eql(u8, tool_name, "list_history")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
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

    if (std.mem.eql(u8, tool_name, "list_library")) {
        try w.writeAll("{");
        const kinds = [_]struct { field: []const u8, sub: []const u8 }{
            .{ .field = "components", .sub = "components" },
            .{ .field = "modules", .sub = "modules" },
            .{ .field = "pinouts", .sub = "pinouts" },
            .{ .field = "footprints", .sub = "footprints" },
        };
        for (kinds, 0..) |k, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("\"{s}\":", .{k.field});
            try listLibrarySubdir(allocator, project_dir, k.sub, w);
        }
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "read_library_file")) {
        const kind = requireString(args_val, "kind") orelse return missingArg(out, allocator, "kind");
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const sub = libraryKindSubdir(kind) orelse {
            try w.print("error: invalid kind \"{s}\" (expected component|module|pinout|footprint)", .{kind});
            return false;
        };
        // Path-traversal guard.
        if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null or std.mem.indexOfAny(u8, name, "/\\") != null) {
            try w.writeAll("error: invalid name");
            return false;
        }
        const path = try std.fmt.allocPrint(allocator, "{s}/lib/{s}/{s}.sexp", .{ project_dir, sub, name });
        defer allocator.free(path);
        const src = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch {
            try w.print("error: not found: lib/{s}/{s}.sexp", .{ sub, name });
            return false;
        };
        try w.writeAll("{\"source\":");
        try writeJsonString(w, src);
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "edit_note")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const match = requireString(args_val, "match") orelse return missingArg(out, allocator, "match");
        const new_text = requireString(args_val, "new_text") orelse return missingArg(out, allocator, "new_text");
        const result = edit.editNoteCore(allocator, project_dir, name, match, new_text) catch |err| return editErrorMsg(out, allocator, err);
        try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
        if (result.snapshot) |s| try writeJsonString(w, s) else try w.writeAll("null");
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "add_import")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const item = requireString(args_val, "item") orelse return missingArg(out, allocator, "item");
        const result = edit.addImportCore(allocator, project_dir, name, item) catch |err| return editErrorMsg(out, allocator, err);
        try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
        if (result.snapshot) |s| try writeJsonString(w, s) else try w.writeAll("null");
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "set_instance_pin")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const ref = requireString(args_val, "ref") orelse return missingArg(out, allocator, "ref");
        const pin = requireString(args_val, "pin") orelse return missingArg(out, allocator, "pin");
        const net = requireString(args_val, "net") orelse return missingArg(out, allocator, "net");
        const result = edit.setInstancePinCore(allocator, project_dir, name, ref, pin, net) catch |err| return editErrorMsg(out, allocator, err);
        try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
        if (result.snapshot) |s| try writeJsonString(w, s) else try w.writeAll("null");
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "list_instances")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        return try listInstances(allocator, project_dir, name, w);
    }

    if (std.mem.eql(u8, tool_name, "list_free_pins")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const ref = requireString(args_val, "ref") orelse return missingArg(out, allocator, "ref");
        const filter = optionalString(args_val, "filter");
        return try listFreePins(allocator, project_dir, name, ref, filter, w);
    }

    if (std.mem.eql(u8, tool_name, "get_net")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const net = requireString(args_val, "net") orelse return missingArg(out, allocator, "net");
        return try getNet(allocator, project_dir, name, net, w);
    }

    if (std.mem.eql(u8, tool_name, "add_component_parameter")) {
        const component = requireString(args_val, "component") orelse return missingArg(out, allocator, "component");
        const param_name = requireString(args_val, "param_name") orelse return missingArg(out, allocator, "param_name");
        const param_type = requireString(args_val, "param_type") orelse return missingArg(out, allocator, "param_type");
        const result = edit.addComponentParameterCore(allocator, project_dir, component, param_name, param_type) catch |err| return editErrorMsg(out, allocator, err);
        try w.writeAll("{\"ok\":true,\"snapshot\":");
        if (result.snapshot) |s| try writeJsonString(w, s) else try w.writeAll("null");
        try w.writeAll("}");
        return true;
    }

    if (std.mem.eql(u8, tool_name, "get_review_state")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const state = review_state_mod.loadState(allocator, project_dir, name) catch review_mod.ReviewState{};
        const json = review_state_mod.renderState(allocator, state) catch {
            try w.writeAll("error: render failed");
            return false;
        };
        try w.writeAll(json);
        return true;
    }

    if (std.mem.eql(u8, tool_name, "set_review_state")) {
        const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
        const slug = requireString(args_val, "section_slug") orelse return missingArg(out, allocator, "section_slug");

        // Each field is optional but at least one should meaningfully
        // mutate the state. We apply them in a fixed order: deletes,
        // toggles, adds, approval — matches how a reviewer would act.
        if (args_val) |av| if (av == .object) {
            if (av.object.get("delete")) |d| if (d == .array) for (d.array.items) |id_val| {
                if (id_val != .string) continue;
                review_state_mod.deleteItem(allocator, project_dir, name, slug, id_val.string) catch |err| {
                    try w.print("error: delete failed: {s}", .{@errorName(err)});
                    return false;
                };
            };
            if (av.object.get("toggle")) |t| if (t == .array) for (t.array.items) |row| {
                if (row != .object) continue;
                const id_v = row.object.get("id") orelse continue;
                const ck_v = row.object.get("checked") orelse continue;
                if (id_v != .string or ck_v != .bool) continue;
                review_state_mod.toggleItem(allocator, project_dir, name, slug, id_v.string, ck_v.bool) catch |err| {
                    try w.print("error: toggle failed: {s}", .{@errorName(err)});
                    return false;
                };
            };
            if (av.object.get("add_items")) |a| if (a == .array) for (a.array.items) |text_val| {
                if (text_val != .string) continue;
                _ = review_state_mod.addItem(allocator, project_dir, name, slug, text_val.string) catch |err| {
                    try w.print("error: add failed: {s}", .{@errorName(err)});
                    return false;
                };
            };
            if (av.object.get("approved")) |ap| if (ap == .bool) {
                const reviewer: []const u8 = optionalString(args_val, "reviewer") orelse "";
                review_state_mod.setApproval(allocator, project_dir, name, slug, ap.bool, reviewer) catch |err| {
                    try w.print("error: approve failed: {s}", .{@errorName(err)});
                    return false;
                };
            };
        };

        const v = serve_root.bumpLiveVersion(name);
        try w.print("{{\"ok\":true,\"version\":{d}}}", .{v});
        return true;
    }

    try w.print("error: unknown tool \"{s}\"", .{tool_name});
    return false;
}

fn libraryKindSubdir(kind: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, kind, "component")) return "components";
    if (std.mem.eql(u8, kind, "module")) return "modules";
    if (std.mem.eql(u8, kind, "pinout")) return "pinouts";
    if (std.mem.eql(u8, kind, "footprint")) return "footprints";
    return null;
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

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
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
        try w.writeAll("{\"name\":");
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
    const src = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return null;
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
    scope: []const u8,
    severity_filter: ?[]const u8,
    changed_since: ?[]const u8,
    w: anytype,
) !bool {
    const want_erc = std.mem.eql(u8, scope, "erc") or std.mem.eql(u8, scope, "both");
    const want_drc = std.mem.eql(u8, scope, "drc") or std.mem.eql(u8, scope, "both");
    if (!want_erc and !want_drc) {
        try w.print("error: invalid scope \"{s}\" (expected erc|drc|both)", .{scope});
        return false;
    }

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

    // If changed_since is set, compute the symmetric-difference sets of
    // ref_des and net names between the prior snapshot and the current
    // design. ERC violations are filtered to those touching these sets.
    // DRC filtering is not supported — documented in the schema.
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
                .board => |b| b.design,
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

    try w.print("{{\"scope\":\"{s}\",\"filtered\":{s}", .{ scope, if (have_change_filter or severity_filter != null) "true" else "false" });

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

    try w.writeAll(",\"erc\":");
    if (want_erc) {
        const erc_all = try erc_mod.runErc(allocator, block, project_dir);
        try w.writeAll("[");
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
                try w.writeAll(",\"net\":");
                try writeJsonString(w, v.net);
            }
            try w.writeAll("}");
        }
        try w.writeAll("]");
    } else {
        try w.writeAll("null");
    }

    try w.writeAll(",\"drc\":");
    if (want_drc and board_def != null) {
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
        var first = true;
        var emitted: usize = 0;
        for (drc_violations) |v| {
            const sev = @tagName(v.severity);
            if (severity_filter) |sf| if (!std.mem.eql(u8, sev, sf)) continue;
            if (!first) try w.writeAll(",");
            first = false;
            emitted += 1;
            try w.writeAll("{\"kind\":");
            try writeJsonString(w, v.kind);
            try w.writeAll(",\"message\":");
            try writeJsonString(w, v.message);
            try w.print(",\"x\":{d:.4},\"y\":{d:.4},\"severity\":\"{s}\"", .{ v.x, v.y, sev });
            try w.writeAll("}");
        }
        try w.print("],\"count\":{d}}}", .{emitted});
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}");
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
    const path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll("error: build failed");
        return false;
    };
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            try w.writeAll("error: not a design");
            return false;
        },
    };

    const bom_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, name });
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, @constCast(block), bom_path, project_dir) catch {};

    const violations = try erc_mod.runErc(allocator, block, project_dir);
    const doc = try review_mod.buildReview(allocator, name, block, eval.assertions.items, violations);
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
    const path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll("error: build failed");
        return false;
    };
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            try w.writeAll("error: not a design");
            return false;
        },
    };

    try w.writeAll("{\"instances\":[");
    for (block.instances, 0..) |inst, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"ref_des\":");
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
) !bool {
    const path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll("error: build failed");
        return false;
    };
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            try w.writeAll("error: not a design");
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
        try w.writeAll(",\"function\":");
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
        try w.writeAll(",\"function\":");
        try writeJsonString(w, fname);
        try w.writeAll(",\"net\":");
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
    const path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch {
        try w.writeAll("error: build failed");
        return false;
    };
    const block: *const env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        .board => |b| b.design,
        else => {
            try w.writeAll("error: not a design");
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

    try w.writeAll("{\"name\":");
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
        try w.writeAll("{\"ref_des\":");
        try writeJsonString(w, p.ref_des);
        try w.writeAll(",\"pin\":");
        try writeJsonString(w, p.pin);
        try w.writeAll(",\"function\":");
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
            try w.writeAll("{\"ref_des\":");
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
) ![]DesignSummary {
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_path);

    var dir = std.fs.cwd().openDir(src_path, .{ .iterate = true }) catch return &[_]DesignSummary{};
    defer dir.close();

    var summaries: std.ArrayListUnmanaged(DesignSummary) = .empty;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.name });
        defer allocator.free(full_path);
        if (!hasTopLevelDesignBlock(allocator, full_path)) continue;

        const base = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".sexp".len]);

        var mtime_sec: i64 = 0;
        if (dir.statFile(entry.name)) |st| {
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
                .board => |b| b.design,
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

    return render_json.renderSceneGraph(allocator, block, project_dir);
}
