//! Human-readable documentation page for the MCP tool surface. Renders
//! `GET /mcp-tools`: every tool Claude Code (or any MCP client) can call,
//! with its description, read-only/mutation badge, parameter table, and a
//! synthesized example invocation.
//!
//! The data is parsed straight from `assets/tools_list_result.json` — the
//! same payload the server returns for the MCP `tools/list` request — so the
//! page can never drift from what the server actually advertises. The
//! mutation flag is the one authoritative source in `mcp_tools.isMutationTool`.

const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const mcp_tools = @import("mcp_tools.zig");
const mcp_docs_template = @import("templates/mcp_docs.zig");

/// Error set for this module's HTTP handler: only writer-side errors reach
/// httpz; JSON-parse failures degrade to an empty tool list.
const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// One parameter of an MCP tool, projected from its JSON Schema `properties`
/// entry plus the schema's `required` list.
pub const ParamDoc = struct {
    name: []const u8,
    type_str: []const u8,
    required: bool,
    description: []const u8,
    enum_values: []const []const u8,
};

/// One MCP tool, ready to feed the `mcp_docs.zt` template.
pub const ToolDoc = struct {
    name: []const u8,
    description: []const u8,
    is_mutation: bool,
    params: []const ParamDoc,
    /// Pre-rendered example invocation (tool name + a JSON object of the
    /// required params with type-appropriate placeholder values).
    example: []const u8,
    /// `name + " " + description`, lower-cased client-side, for the search box.
    search_text: []const u8,
};

/// GET /mcp-tools — render the MCP tool reference page.
pub fn mcpDocsPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const tools = buildToolDocs(req.arena) catch &[_]ToolDoc{};

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try mcp_docs_template.Mcp.render(.{tools}, &aw.writer);
    res.body = aw.written();
    res.content_type = .HTML;
}

// ── JSON projection ───────────────────────────────────────────────────

fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn asArray(v: std.json.Value) ?std.json.Array {
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

fn asStr(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn objStr(o: std.json.ObjectMap, key: []const u8) []const u8 {
    return if (o.get(key)) |v| asStr(v) else "";
}

/// Parse `tools_list_result.json` and project it into `[]ToolDoc`. Allocations
/// (parse tree + model) all come from `arena`; the caller owns nothing
/// individually and frees by dropping the arena.
fn buildToolDocs(arena: std.mem.Allocator) ![]ToolDoc {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, mcp_tools.tools_list_result, .{});
    const root_obj = asObject(root) orelse return &.{};
    const tools_arr = asArray(root_obj.get("tools") orelse return &.{}) orelse return &.{};

    var out: std.ArrayList(ToolDoc) = .empty;
    for (tools_arr.items) |tv| {
        const obj = asObject(tv) orelse continue;
        const name = objStr(obj, "name");
        if (name.len == 0) continue;
        const description = objStr(obj, "description");
        const params = try buildParams(arena, obj);
        try out.append(arena, .{
            .name = name,
            .description = description,
            .is_mutation = mcp_tools.isMutationTool(name),
            .params = params,
            .example = try buildExample(arena, name, params),
            .search_text = try std.fmt.allocPrint(arena, "{s} {s}", .{ name, description }),
        });
    }
    return out.items;
}

/// Project a tool's `inputSchema.properties` (in declared order) into
/// `[]ParamDoc`, marking each param required iff its key is in the schema's
/// `required` array.
fn buildParams(arena: std.mem.Allocator, tool_obj: std.json.ObjectMap) ![]ParamDoc {
    const schema = asObject(tool_obj.get("inputSchema") orelse return &.{}) orelse return &.{};
    const props = asObject(schema.get("properties") orelse return &.{}) orelse return &.{};

    var required = std.StringHashMapUnmanaged(void).empty;
    if (schema.get("required")) |req_v| {
        if (asArray(req_v)) |req_arr| {
            for (req_arr.items) |rv| try required.put(arena, asStr(rv), {});
        }
    }

    var out: std.ArrayList(ParamDoc) = .empty;
    var it = props.iterator();
    while (it.next()) |entry| {
        const pname = entry.key_ptr.*;
        const pobj = asObject(entry.value_ptr.*) orelse continue;
        var enums: []const []const u8 = &.{};
        if (pobj.get("enum")) |ev| {
            if (asArray(ev)) |earr| {
                var el: std.ArrayList([]const u8) = .empty;
                for (earr.items) |x| try el.append(arena, asStr(x));
                enums = el.items;
            }
        }
        try out.append(arena, .{
            .name = pname,
            .type_str = objStr(pobj, "type"),
            .required = required.contains(pname),
            .description = objStr(pobj, "description"),
            .enum_values = enums,
        });
    }
    return out.items;
}

fn placeholderFor(type_str: []const u8) []const u8 {
    if (std.mem.eql(u8, type_str, "integer")) return "0";
    if (std.mem.eql(u8, type_str, "number")) return "0";
    if (std.mem.eql(u8, type_str, "boolean")) return "true";
    return "\"...\"";
}

/// Build a copy-pasteable example call: the tool name followed by a JSON
/// object of just its required params (placeholder values). Tools with no
/// required params render `name {}`.
fn buildExample(arena: std.mem.Allocator, name: []const u8, params: []const ParamDoc) ![]u8 {
    var required_count: usize = 0;
    for (params) |p| {
        if (p.required) required_count += 1;
    }
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(arena);
    if (required_count == 0) {
        try w.print("{s} {{}}", .{name});
        return buf.items;
    }
    try w.print("{s} {{\n", .{name});
    var emitted: usize = 0;
    for (params) |p| {
        if (!p.required) continue;
        emitted += 1;
        const comma = if (emitted < required_count) "," else "";
        try w.print("  \"{s}\": {s}{s}\n", .{ p.name, placeholderFor(p.type_str), comma });
    }
    try w.writeAll("}");
    return buf.items;
}

// ── Tests ─────────────────────────────────────────────────────────────

fn findTool(tools: []const ToolDoc, name: []const u8) ?ToolDoc {
    for (tools) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn hasRequiredParam(tool: ToolDoc, name: []const u8) bool {
    for (tool.params) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.required;
    }
    return false;
}

test "buildToolDocs parses every tool from the embedded schema" {
    // spec: serve/mcp_docs - buildToolDocs projects each tool from the embedded schema
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tools = try buildToolDocs(arena.allocator());
    try std.testing.expect(tools.len >= 20);

    const ld = findTool(tools, "list_designs").?;
    try std.testing.expect(!ld.is_mutation);
    try std.testing.expectEqual(@as(usize, 0), ld.params.len);

    const dc = findTool(tools, "describe_component").?;
    try std.testing.expect(hasRequiredParam(dc, "name"));
}

test "buildToolDocs marks mutating tools and required params" {
    // spec: serve/mcp_docs - buildToolDocs marks mutating tools and required params
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tools = try buildToolDocs(arena.allocator());

    const add = findTool(tools, "add_component_requirement").?;
    try std.testing.expect(add.is_mutation);
    try std.testing.expect(hasRequiredParam(add, "name"));
    try std.testing.expect(hasRequiredParam(add, "text"));
    // `check` is present but optional.
    var saw_check = false;
    for (add.params) |p| {
        if (std.mem.eql(u8, p.name, "check")) {
            saw_check = true;
            try std.testing.expect(!p.required);
        }
    }
    try std.testing.expect(saw_check);
}

test "buildExample emits required params with placeholders" {
    // spec: serve/mcp_docs - buildExample renders an example invocation
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const a = arena.allocator();
    defer arena.deinit();

    const none = try buildExample(a, "list_designs", &[_]ParamDoc{});
    try std.testing.expectEqualStrings("list_designs {}", none);

    const params = [_]ParamDoc{
        .{ .name = "name", .type_str = "string", .required = true, .description = "", .enum_values = &.{} },
        .{ .name = "page", .type_str = "integer", .required = true, .description = "", .enum_values = &.{} },
        .{ .name = "filter", .type_str = "string", .required = false, .description = "", .enum_values = &.{} },
    };
    const ex = try buildExample(a, "get_thing", &params);
    try std.testing.expectEqualStrings(
        "get_thing {\n  \"name\": \"...\",\n  \"page\": 0\n}",
        ex,
    );
}
