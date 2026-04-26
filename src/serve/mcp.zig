const std = @import("std");
const httpz = @import("httpz");
const websocket = httpz.websocket;

const server_mod = @import("../serve.zig");
const auth = @import("auth.zig");
const users = @import("users.zig");
const mcp_tools = @import("mcp_tools.zig");

/// Per-connection MCP context: ties a streaming Client back to the parent
/// HTTP `Handler` and carries the authenticated user's email so role
/// resolution can decide which mutation tools the session may invoke.
pub const Context = struct {
    handler: *server_mod.Handler,
    email: []const u8,
};

fn resolveRole(ctx: *server_mod.Handler, req: *httpz.Request) users.Role {
    // Bearer-token path: look up the token's email.
    if (auth.getBearerEmail(ctx, req)) |em| return users.getRole(ctx.allocator, ctx.project_dir, em);
    // Session path: look up the session's email.
    if (auth.getSessionToken(req)) |tok| {
        if (auth.validateSession(ctx.allocator, ctx.project_dir, tok)) |em| return users.getRole(ctx.allocator, ctx.project_dir, em);
    }
    // Localhost dev bypass — auth middleware already let us through.
    if (auth.isLocalhostRequest(req)) return .admin;
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
) !?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch {
        return parseErrorEnvelope(allocator);
    };
    const root = parsed.value;
    if (root != .object) {
        return try errorEnvelopeRawId(allocator, "null", -32600, "invalid request");
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
    return try errorEnvelope(allocator, id_val, -32601, "method not found");
}

fn handleToolCall(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    id_val: ?std.json.Value,
    params: ?std.json.Value,
    role: users.Role,
) ![]const u8 {
    const p = params orelse return errorEnvelope(allocator, id_val, -32602, "missing params");
    if (p != .object) return errorEnvelope(allocator, id_val, -32602, "params must be an object");

    const tool_name = if (p.object.get("name")) |n| (if (n == .string) n.string else "") else "";
    if (tool_name.len == 0) return errorEnvelope(allocator, id_val, -32602, "missing tool name");

    if (mcp_tools.isMutationTool(tool_name) and !role.canWrite()) {
        var msg: std.ArrayListUnmanaged(u8) = .empty;
        const mw = msg.writer(allocator);
        try mw.print("Your role \"{s}\" cannot use tool \"{s}\" (writer or admin required)", .{ role.toString(), tool_name });
        var result: std.ArrayListUnmanaged(u8) = .empty;
        const rw = result.writer(allocator);
        try rw.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
        try writeJsonStringTo(rw, msg.items);
        try rw.writeAll("}],\"isError\":true}");
        return resultEnvelope(allocator, id_val, result.items);
    }

    const args_val: ?std.json.Value = p.object.get("arguments");

    var content_buf: std.ArrayListUnmanaged(u8) = .empty;
    const call_result = mcp_tools.call(allocator, project_dir, tool_name, args_val, &content_buf);

    var result: std.ArrayListUnmanaged(u8) = .empty;
    const rw = result.writer(allocator);
    try rw.writeAll("{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonStringTo(rw, content_buf.items);
    try rw.writeAll("}]");
    if (!call_result.ok) try rw.writeAll(",\"isError\":true");
    try rw.writeAll("}");

    return resultEnvelope(allocator, id_val, result.items);
}

fn handleResourcesList(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    id_val: ?std.json.Value,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"resources\":[");
    const names = mcp_tools.listDesignNames(allocator, project_dir) catch &[_][]const u8{};
    for (names, 0..) |design, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"uri\":\"eda://schematic/");
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
    const p = params orelse return errorEnvelope(allocator, id_val, -32602, "missing params");
    if (p != .object) return errorEnvelope(allocator, id_val, -32602, "params must be an object");

    const uri = if (p.object.get("uri")) |u| (if (u == .string) u.string else "") else "";
    const prefix = "eda://schematic/";
    if (!std.mem.startsWith(u8, uri, prefix)) {
        return errorEnvelope(allocator, id_val, -32602, "unknown resource uri");
    }
    const design = uri[prefix.len..];
    const graph = mcp_tools.renderSceneGraph(allocator, project_dir, design) catch |err| {
        return errorEnvelope(allocator, id_val, -32000, @errorName(err));
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"contents\":[{\"uri\":\"");
    try w.writeAll(uri);
    try w.writeAll("\",\"mimeType\":\"application/json\",\"text\":");
    try writeJsonStringTo(w, graph);
    try w.writeAll("}]}");
    return resultEnvelope(allocator, id_val, buf.items);
}

// ── JSON-RPC envelope writers ──────────────────────────────────────────

fn resultEnvelope(allocator: std.mem.Allocator, id_val: ?std.json.Value, result_json: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeIdTo(w, id_val);
    try w.writeAll(",\"result\":");
    try w.writeAll(result_json);
    try w.writeAll("}");
    return buf.items;
}

fn errorEnvelope(allocator: std.mem.Allocator, id_val: ?std.json.Value, code: i32, msg: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeIdTo(w, id_val);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try writeJsonStringTo(w, msg);
    try w.writeAll("}}");
    return buf.items;
}

fn errorEnvelopeRawId(allocator: std.mem.Allocator, raw_id: []const u8, code: i32, msg: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try w.writeAll(raw_id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try writeJsonStringTo(w, msg);
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
        .string => |s| try writeJsonStringTo(w, s),
        .null => try w.writeAll("null"),
        else => try w.writeAll("null"),
    }
}

fn writeJsonStringTo(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{ch}),
            else => try w.writeByte(ch),
        }
    }
    try w.writeAll("\"");
}

// ── WebSocket transport ────────────────────────────────────────────────

/// Long-lived WebSocket peer used by the local MCP transport. Each frame
/// is dispatched through the shared `dispatchFrame` with the role pinned
/// at upgrade time — clients can't escalate mid-connection.
pub const Client = struct {
    conn: *websocket.Conn,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    email: []const u8,

    pub fn init(conn: *websocket.Conn, ctx: *const Context) !Client {
        return .{
            .conn = conn,
            .allocator = ctx.handler.allocator,
            .project_dir = ctx.handler.project_dir,
            .email = ctx.email,
        };
    }

    pub fn clientMessage(self: *Client, data: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        // WebSocket sessions are authenticated at upgrade time; role is fixed
        // for the duration of the connection. Fall back to admin on the dev
        // localhost path (same policy as resolveRole above).
        const role = if (self.email.len > 0)
            users.getRole(self.allocator, self.project_dir, self.email)
        else
            users.Role.admin;
        const reply_opt = dispatchFrame(aa, self.project_dir, data, role) catch |err| blk: {
            std.debug.print("mcp dispatch error: {s}\n", .{@errorName(err)});
            break :blk @as(?[]const u8, null);
        };
        if (reply_opt) |reply| try self.conn.write(reply);
    }
};

/// GET /mcp — perform the WebSocket upgrade for the local MCP transport,
/// resolving the requesting user's email from their session cookie so the
/// `Client` instance carries it for the lifetime of the connection.
pub fn upgrade(ctx: *server_mod.Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const email = blk: {
        if (auth.getSessionToken(req)) |tok| {
            if (auth.validateSession(ctx.allocator, ctx.project_dir, tok)) |em| break :blk em;
        }
        break :blk "";
    };

    const upgrade_ctx = Context{ .handler = ctx, .email = email };
    if (try httpz.upgradeWebsocket(Client, req, res, &upgrade_ctx) == false) {
        res.status = 400;
        res.body = "expected websocket upgrade";
    }
}

// ── HTTP streamable transport ─────────────────────────────────────────

/// POST /mcp — streamable-HTTP transport used by Claude Code's remote MCP
/// connector. Resolves the role from the bearer/session cookie, dispatches
/// one JSON-RPC frame, and returns 202 for notifications (no body).
pub fn postApi(ctx: *server_mod.Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "missing body";
        return;
    };

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const role = resolveRole(ctx, req);
    const reply_opt = dispatchFrame(aa, ctx.project_dir, body, role) catch |err| {
        std.debug.print("mcp dispatch error: {s}\n", .{@errorName(err)});
        res.status = 500;
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
        res.status = 202;
    }
}
