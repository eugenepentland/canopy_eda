//! MCP server transport layer: the JSON-RPC frame dispatcher plus both
//! carriers — `POST /mcp` (streamable HTTP, the Claude Code connector) and the
//! `GET /mcp` WebSocket upgrade. Authenticates the bearer token, then routes
//! each `tools/call` into `mcp_tools.zig`, where the tool bodies live.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const httpz = @import("httpz");
const websocket = httpz.websocket;
const log = @import("../infra/log.zig");

const server_mod = @import("../serve.zig");
const auth = @import("auth.zig");
const users = @import("users.zig");
const mcp_tools = @import("mcp_tools.zig");

// ── Constants ─────────────────────────────────────────────────────
// JSON-RPC 2.0 standard error codes (RFC).
const jsonrpc_invalid_request: i32 = -32600;
const jsonrpc_method_not_found: i32 = -32601;
const jsonrpc_invalid_params: i32 = -32602;
const jsonrpc_server_error: i32 = -32000;

const jsonrpc_envelope_prefix: []const u8 = "{\"jsonrpc\":\"2.0\",\"id\":";

const http_bad_request: u16 = 400;
const http_accepted: u16 = 202;
const http_internal_error: u16 = 500;

/// Error set for HTTP/WebSocket handlers in this module and the JSON-RPC
/// dispatcher. Wide enough to cover JSON parsing, allocation, websocket
/// upgrade, and httpz writer errors.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    error{ NoSpaceLeft, InvalidCompressionServerMaxBits };

/// Per-connection MCP context: ties a streaming Client back to the parent
/// HTTP `Server` and carries the authenticated user's email so role
/// resolution can decide which mutation tools the session may invoke.
pub const Context = struct {
    handler: *server_mod.Server,
    email: []const u8,
};

fn resolveRole(ctx: *server_mod.Server, req: *httpz.Request) users.Role {
    // Bearer-token path: look up the token's email.
    if (auth.getBearerEmail(ctx, req)) |em| return users.getRole(ctx.allocator, ctx.auth_dir, em);
    // Session path: look up the session's email.
    if (auth.getSessionToken(req)) |tok| {
        if (ctx.state.sessions.validate(ctx.allocator, ctx.auth_dir, tok)) |em| return users.getRole(ctx.allocator, ctx.auth_dir, em);
    }
    // Localhost dev bypass (opt-in NETLISP_DEV + loopback + not proxied).
    if (auth.isLocalhostRequest(ctx, req)) return .admin;
    return .reader;
}

/// Parse a JSON-RPC frame and return the JSON response bytes (or null for a
/// notification that requires no response). The returned slice is allocated
/// from `allocator` — caller is expected to pass in an arena/temp allocator.
///
/// This is the single source of truth for MCP dispatch; both the WebSocket
/// Client (streaming) and the HTTP POST /mcp handler call it.
pub fn dispatchFrame(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    data: []const u8,
    role: users.Role,
) HandlerError!?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        return parseErrorEnvelope(allocator);
    };
    const root = parsed.value;
    if (root != .object) {
        return try errorEnvelope(allocator, null, jsonrpc_invalid_request, "invalid request");
    }
    const obj = root.object;

    const method = if (obj.get("method")) |m| (if (m == .string) m.string else "") else "";
    const id_val = obj.get("id");
    const params = obj.get("params");

    if (std.mem.eql(u8, method, "initialize")) {
        const result =
            \\{"protocolVersion":"2024-11-05","capabilities":{"tools":{},"resources":{}},"serverInfo":{"name":"eda","version":"0.1.0"}}
        ;
        return try resultEnvelope(allocator, id_val, result);
    }
    if (std.mem.eql(u8, method, "notifications/initialized") or std.mem.eql(u8, method, "initialized")) {
        return null;
    }
    if (std.mem.eql(u8, method, "ping")) {
        return try resultEnvelope(allocator, id_val, "{}");
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        return try resultEnvelope(allocator, id_val, mcp_tools.tools_list_result);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        return try handleToolCall(allocator, project_dir, id_val, params, role);
    }
    if (std.mem.eql(u8, method, "resources/list")) {
        return try handleResourcesList(allocator, project_dir, id_val);
    }
    if (std.mem.eql(u8, method, "resources/read")) {
        return try handleResourcesRead(allocator, project_dir, id_val, params);
    }
    if (id_val == null) {
        // Unknown notification — no response per JSON-RPC spec.
        return null;
    }
    return try errorEnvelope(allocator, id_val, jsonrpc_method_not_found, "method not found");
}

fn handleToolCall(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    id_val: ?std.json.Value,
    params: ?std.json.Value,
    role: users.Role,
) ![]const u8 {
    const p = params orelse return errorEnvelope(allocator, id_val, jsonrpc_invalid_params, "missing params");
    if (p != .object) return errorEnvelope(allocator, id_val, jsonrpc_invalid_params, "params must be an object");

    const tool_name = if (p.object.get("name")) |n| (if (n == .string) n.string else "") else "";
    if (tool_name.len == 0) return errorEnvelope(allocator, id_val, jsonrpc_invalid_params, "missing tool name");

    if (mcp_tools.isMutationTool(tool_name) and !role.canWrite()) {
        var msg: std.ArrayList(u8) = .empty;
        const mw = msg.writer(allocator);
        try mw.print("Your role \"{s}\" cannot use tool \"{s}\" (writer or admin required)", .{ role.toString(), tool_name });
        var result: std.ArrayList(u8) = .empty;
        const rw = result.writer(allocator);
        try rw.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try json_writer.writeString(rw, msg.items);
        try rw.writeAll("}],\"isError\":true}");
        return resultEnvelope(allocator, id_val, result.items);
    }

    const args_val: ?std.json.Value = p.object.get("arguments");

    var content_buf: std.ArrayList(u8) = .empty;
    const call_result = mcp_tools.call(allocator, project_dir, tool_name, args_val, &content_buf);

    var result: std.ArrayList(u8) = .empty;
    const rw = result.writer(allocator);
    if (call_result.image_mime) |mime| {
        // `content_buf` holds base64 (no characters needing JSON escaping), so
        // it's written raw between the quotes.
        try rw.writeAll("{\"content\":[{\"type\":\"image\",\"data\":\"");
        try rw.writeAll(content_buf.items);
        try rw.writeAll("\",\"mimeType\":\"");
        try rw.writeAll(mime);
        try rw.writeAll("\"}]");
    } else {
        try rw.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try json_writer.writeString(rw, content_buf.items);
        try rw.writeAll("}]");
    }
    if (!call_result.ok) try rw.writeAll(",\"isError\":true");
    try rw.writeAll("}");

    return resultEnvelope(allocator, id_val, result.items);
}

/// Static help document advertised as the `eda://docs/workspace` resource.
/// Markdown rather than JSON so MCP clients render it as prose. Covers the
/// sandbox layout, mutation response shape, pinout regeneration workflow,
/// and the `(id …)` / Unicode quirks that aren't obvious from tool docs.
const workspace_doc: []const u8 = @embedFile("assets/workspace.md");

fn handleResourcesList(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    id_val: ?std.json.Value,
) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"resources\":[");
    // Static help resource — emitted first so clients with a UI for
    // "important resources" surface it without having to scroll through
    // every design schematic.
    try w.writeAll("{\"uri\":\"eda://docs/workspace\",\"name\":\"workspace\",");
    try w.writeAll("\"description\":\"Sandbox layout, mutation response shapes, pinout regeneration, (id ...) semantics, Unicode in strings.\",");
    try w.writeAll("\"mimeType\":\"text/markdown\"}");
    const names = mcp_tools.listDesignNames(allocator, project_dir) catch &[_][]const u8{};
    for (names) |design| {
        try w.writeAll(",{\"uri\":\"eda://schematic/");
        try w.writeAll(design);
        try w.writeAll("\",\"name\":\"");
        try w.writeAll(design);
        try w.writeAll("\",\"mimeType\":\"application/json\"}");
    }
    try w.writeAll("]}");
    return resultEnvelope(allocator, id_val, buf.items);
}

fn handleResourcesRead(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    id_val: ?std.json.Value,
    params: ?std.json.Value,
) ![]const u8 {
    const p = params orelse return errorEnvelope(allocator, id_val, jsonrpc_invalid_params, "missing params");
    if (p != .object) return errorEnvelope(allocator, id_val, jsonrpc_invalid_params, "params must be an object");

    const uri = if (p.object.get("uri")) |u| (if (u == .string) u.string else "") else "";

    // Static workspace help — embedded markdown, no project access needed.
    if (std.mem.eql(u8, uri, "eda://docs/workspace")) {
        var buf: std.ArrayList(u8) = .empty;
        const w = buf.writer(allocator);
        try w.writeAll("{\"contents\":[{\"uri\":\"");
        try w.writeAll(uri);
        try w.writeAll("\",\"mimeType\":\"text/markdown\",\"text\":");
        try json_writer.writeString(w, workspace_doc);
        try w.writeAll("}]}");
        return resultEnvelope(allocator, id_val, buf.items);
    }

    const prefix = "eda://schematic/";
    if (!std.mem.startsWith(u8, uri, prefix)) {
        return errorEnvelope(allocator, id_val, jsonrpc_invalid_params, "unknown resource uri");
    }
    const design = uri[prefix.len..];
    const graph = mcp_tools.renderSceneGraph(allocator, project_dir, design) catch |err| {
        return errorEnvelope(allocator, id_val, jsonrpc_server_error, @errorName(err));
    };

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"contents\":[{\"uri\":\"");
    try w.writeAll(uri);
    try w.writeAll("\",\"mimeType\":\"application/json\",\"text\":");
    try json_writer.writeString(w, graph);
    try w.writeAll("}]}");
    return resultEnvelope(allocator, id_val, buf.items);
}

// ── JSON-RPC envelope writers ──────────────────────────────────────────

fn resultEnvelope(allocator: std.mem.Allocator, id_val: ?std.json.Value, result_json: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll(jsonrpc_envelope_prefix);
    try writeIdTo(w, id_val);
    try w.writeAll(",\"result\":");
    try w.writeAll(result_json);
    try w.writeAll("}");
    return buf.items;
}

fn errorEnvelope(allocator: std.mem.Allocator, id_val: ?std.json.Value, code: i32, msg: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll(jsonrpc_envelope_prefix);
    try writeIdTo(w, id_val);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try json_writer.writeString(w, msg);
    try w.writeAll("}}");
    return buf.items;
}

fn parseErrorEnvelope(_: std.mem.Allocator) ?[]const u8 {
    return @as([]const u8, 
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}
    );
}

fn writeIdTo(w: anytype, id_val: ?std.json.Value) !void {
    const id = id_val orelse {
        try w.writeAll("null");
        return;
    };
    switch (id) {
        .integer => |i| try w.print("{d}", .{i}),
        .string => |s| try json_writer.writeString(w, s),
        .null => try w.writeAll("null"),
        else => try w.writeAll("null"),
    }
}

// ── WebSocket transport ────────────────────────────────────────────────

/// Long-lived WebSocket peer used by the local MCP transport. Each frame
/// is dispatched through the shared `dispatchFrame` with the role pinned
/// at upgrade time — clients can't escalate mid-connection.
pub const Client = struct {
    conn: *websocket.Conn,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    auth_dir: []const u8,
    email: []const u8,

    pub fn init(conn: *websocket.Conn, ctx: *const Context) !Client {
        return .{
            .conn = conn,
            // The Client outlives the upgrade request, whose handler now
            // carries a per-request arena — pin the connection's base
            // allocator to the process allocator (per-message work runs in
            // its own arena over it in `clientMessage`).
            .allocator = std.heap.page_allocator,
            .project_dir = ctx.handler.project_dir,
            .auth_dir = ctx.handler.auth_dir,
            // Dupe into the process allocator: `ctx.email` may be borrowed from
            // the upgrade request's arena, which is reset once upgrade returns.
            .email = try std.heap.page_allocator.dupe(u8, ctx.email),
        };
    }

    pub fn clientMessage(self: *Client, data: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        // WebSocket sessions are authenticated at upgrade time; role is fixed
        // for the duration of the connection. An empty email means we could not
        // identify the user (no session cookie AND no bearer token) — default
        // to the least-privileged role, NEVER admin. (Previously an empty email
        // fell through to admin, so any bearer-authenticated client — which has
        // no session cookie — became admin over the WebSocket transport.)
        const role = if (self.email.len > 0)
            users.getRole(self.allocator, self.auth_dir, self.email)
        else
            users.Role.reader;
        const reply_opt = dispatchFrame(aa, self.project_dir, data, role) catch |err| blk: {
            log.warn("mcp dispatch error: {s}", .{@errorName(err)});
            break :blk @as(?[]const u8, null);
        };
        if (reply_opt) |reply| try self.conn.write(reply);
    }
};

/// GET /mcp — perform the WebSocket upgrade for the local MCP transport,
/// resolving the requesting user's email from their session cookie so the
/// `Client` instance carries it for the lifetime of the connection.
pub fn upgrade(ctx: *server_mod.Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = blk: {
        // Bearer token first (remote MCP clients authenticate with one and
        // carry no session cookie), then the session cookie for local browsers.
        if (auth.getBearerEmail(ctx, req)) |em| break :blk em;
        if (auth.getSessionToken(req)) |tok| {
            if (ctx.state.sessions.validate(ctx.allocator, ctx.auth_dir, tok)) |em| break :blk em;
        }
        break :blk "";
    };

    const upgrade_ctx = Context{ .handler = ctx, .email = email };
    if (try httpz.upgradeWebsocket(Client, req, res, &upgrade_ctx) == false) {
        res.status = http_bad_request;
        res.body = "expected websocket upgrade";
    }
}

// ── HTTP streamable transport ─────────────────────────────────────────

/// POST /mcp — streamable-HTTP transport used by Claude Code's remote MCP
/// connector. Resolves the role from the bearer/session cookie, dispatches
/// one JSON-RPC frame, and returns 202 for notifications (no body).
pub fn postApi(ctx: *server_mod.Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = http_bad_request;
        res.body = "missing body";
        return;
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const role = resolveRole(ctx, req);
    const reply_opt = dispatchFrame(aa, ctx.project_dir, body, role) catch |err| {
        log.warn("mcp dispatch error: {s}", .{@errorName(err)});
        res.status = http_internal_error;
        res.body = "internal error";
        return;
    };

    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    if (reply_opt) |reply| {
        // Must copy to response arena — aa is freed at return.
        res.body = try req.arena.dupe(u8, reply);
    } else {
        // Notification: MCP spec says return 202 Accepted with no body.
        res.status = http_accepted;
    }
}
