//! Board-scoped review checklist page and persistence.
//!
//! The page keeps the research checklist as human dispositions while loading
//! the generated review-audit separately. Machine facts stay live, while
//! Pass/Fail/N-A/Needs-info decisions and evidence persist beside the design.

const std = @import("std");
const httpz = @import("httpz");
const atomic_write = @import("../infra/atomic_write.zig");
const clock = @import("../infra/clock.zig");
const escape = @import("../escape.zig");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const paths = @import("../paths.zig");
const review = @import("../review.zig");
const review_audit = @import("../review_audit.zig");
const system_review_md = @import("../system_review_md.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// Allocation or response-writer failures that may escape an HTTP handler.
const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const catalog_markdown = @embedFile("assets/board_review_checklist.md");
const page_css = @embedFile("assets/board_review.css");
const page_js = @embedFile("assets/board_review.js");
const navbar_css = @embedFile("assets/navbar.css");
const max_state_bytes: usize = 2 * 1024 * 1024;
const max_body_bytes: usize = 16 * 1024;
const max_evidence_bytes: usize = 2048;
const max_note_bytes: usize = 4096;
const max_entries: usize = 258;
const mutation_header = "x-netlisp-review";
const mutation_value = "1";

/// A reviewer's disposition for one checklist decision.
const Status = enum { open, pass, fail, na, needs_info };

/// Persisted human evidence for one stable checklist item id.
const Entry = struct {
    id: []const u8,
    status: Status = .open,
    evidence: []const u8 = "",
    note: []const u8 = "",
    updated_by: []const u8 = "",
    updated_at: []const u8 = "",
};

fn statusFromString(raw: []const u8) ?Status {
    if (std.mem.eql(u8, raw, "open")) return .open;
    if (std.mem.eql(u8, raw, "pass")) return .pass;
    if (std.mem.eql(u8, raw, "fail")) return .fail;
    if (std.mem.eql(u8, raw, "na")) return .na;
    if (std.mem.eql(u8, raw, "needs_info")) return .needs_info;
    return null;
}

fn validItemId(id: []const u8) bool {
    if (id.len == 0 or id.len > 16 or id[0] == '.' or id[id.len - 1] == '.') return false;
    var last_dot = false;
    for (id) |c| {
        if (c == '.') {
            if (last_dot) return false;
            last_dot = true;
        } else {
            if (!std.ascii.isDigit(c)) return false;
            last_dot = false;
        }
    }
    var buffer: [24]u8 = undefined;
    const needle = std.fmt.bufPrint(&buffer, "**{s}**", .{id}) catch return false;
    return std.mem.indexOf(u8, catalog_markdown, needle) != null;
}

fn statePath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]u8 {
    return paths.designSiblingPath(allocator, project_dir, name, ".review.json");
}

fn designExists(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) bool {
    const source = paths.designSourcePath(allocator, project_dir, name) catch return false;
    defer allocator.free(source);
    infra_fs.cwd().access(source, .{}) catch return false;
    return true;
}

fn jsonStringField(object: std.json.ObjectMap, key: []const u8, max_len: usize) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string or value.string.len > max_len) return null;
    return value.string;
}

fn loadEntries(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]const Entry {
    const path = try statePath(allocator, project_dir, name);
    defer allocator.free(path);
    const bytes = infra_fs.cwd().readFileAlloc(allocator, path, max_state_bytes) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidState;
    const entries_value = parsed.value.object.get("entries") orelse return &.{};
    if (entries_value != .array or entries_value.array.items.len > max_entries) return error.InvalidState;

    var entries: std.ArrayList(Entry) = .empty;
    for (entries_value.array.items) |value| {
        if (value != .object) continue;
        const id = jsonStringField(value.object, "id", 16) orelse continue;
        if (!validItemId(id)) continue;
        const status_raw = jsonStringField(value.object, "status", 24) orelse "open";
        const status = statusFromString(status_raw) orelse continue;
        const evidence = jsonStringField(value.object, "evidence", max_evidence_bytes) orelse "";
        const note = jsonStringField(value.object, "note", max_note_bytes) orelse "";
        const updated_by = jsonStringField(value.object, "updated_by", 256) orelse "";
        const updated_at = jsonStringField(value.object, "updated_at", 64) orelse "";
        try entries.append(allocator, .{
            .id = try allocator.dupe(u8, id),
            .status = status,
            .evidence = try allocator.dupe(u8, evidence),
            .note = try allocator.dupe(u8, note),
            .updated_by = try allocator.dupe(u8, updated_by),
            .updated_at = try allocator.dupe(u8, updated_at),
        });
    }
    return try entries.toOwnedSlice(allocator);
}

fn writeEntryJson(w: *std.Io.Writer, entry: Entry) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    try w.writeAll("{\"id\":");
    try json_writer.writeString(w, entry.id);
    try w.writeAll(",\"status\":");
    try json_writer.writeString(w, @tagName(entry.status));
    try w.writeAll(",\"evidence\":");
    try json_writer.writeString(w, entry.evidence);
    try w.writeAll(",\"note\":");
    try json_writer.writeString(w, entry.note);
    try w.writeAll(",\"updated_by\":");
    try json_writer.writeString(w, entry.updated_by);
    try w.writeAll(",\"updated_at\":");
    try json_writer.writeString(w, entry.updated_at);
    try w.writeByte('}');
}

fn renderState(allocator: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"schema\":\"netlisp-board-review-v1\",\"entries\":[");
    for (entries, 0..) |entry, index| {
        if (index > 0) try out.writer.writeByte(',');
        try writeEntryJson(&out.writer, entry);
    }
    try out.writer.writeAll("]}");
    return try out.toOwnedSlice();
}

fn saveEntries(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8, entries: []const Entry) !void {
    const path = try statePath(allocator, project_dir, name);
    defer allocator.free(path);
    const bytes = try renderState(allocator, entries);
    defer allocator.free(bytes);
    try atomic_write.writeFile(path, bytes);
}

fn persistEntry(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    mutex: *infra_fs.Mutex,
    replacement: Entry,
) !void {
    mutex.lock();
    defer mutex.unlock();
    const old = try loadEntries(allocator, project_dir, name);
    var next: std.ArrayList(Entry) = .empty;
    var replaced = false;
    for (old) |entry| {
        if (std.mem.eql(u8, entry.id, replacement.id)) {
            if (!replaced) try next.append(allocator, replacement);
            replaced = true;
        } else try next.append(allocator, entry);
    }
    if (!replaced) {
        if (next.items.len >= max_entries) return error.ReviewStateFull;
        try next.append(allocator, replacement);
    }
    try saveEntries(allocator, project_dir, name, next.items);
}

fn jsonError(res: *httpz.Response, status: u16, message: []const u8) HandlerError!void {
    var out: std.Io.Writer.Allocating = .init(res.arena);
    try out.writer.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(&out.writer, message);
    try out.writer.writeByte('}');
    res.status = status;
    res.content_type = .JSON;
    res.header("cache-control", "no-store");
    res.body = out.written();
}

fn writeStateResponse(res: *httpz.Response, entries: []const Entry) HandlerError!void {
    res.content_type = .JSON;
    res.header("cache-control", "no-store");
    res.body = try renderState(res.arena, entries);
}

/// Return persisted human dispositions for the board checklist.
pub fn getStateApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return jsonError(res, 404, "missing design name");
    if (!designExists(req.arena, ctx.project_dir, name)) return jsonError(res, 404, "no design by that name");
    const entries = loadEntries(req.arena, ctx.project_dir, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonError(res, 500, "review state could not be read"),
    };
    try writeStateResponse(res, entries);
}

/// Replace one item's disposition and stamp the authenticated reviewer.
pub fn updateStateApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    if (!ctx.request_auth.role.canWrite()) return jsonError(res, 403, "writer role required");
    if (!std.mem.eql(u8, req.header(mutation_header) orelse "", mutation_value))
        return jsonError(res, 403, "missing review mutation header");
    const name = req.param("name") orelse return jsonError(res, 404, "missing design name");
    if (!designExists(req.arena, ctx.project_dir, name)) return jsonError(res, 404, "no design by that name");
    const body = req.body() orelse return jsonError(res, 400, "missing JSON body");
    if (body.len > max_body_bytes) return jsonError(res, 413, "review item is too large");
    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch
        return jsonError(res, 400, "invalid JSON body");
    defer parsed.deinit();
    if (parsed.value != .object) return jsonError(res, 400, "body must be an object");
    const id = jsonStringField(parsed.value.object, "id", 16) orelse return jsonError(res, 400, "missing or invalid item id");
    if (!validItemId(id)) return jsonError(res, 400, "unknown checklist item");
    const raw_status = jsonStringField(parsed.value.object, "status", 24) orelse return jsonError(res, 400, "missing status");
    const status = statusFromString(raw_status) orelse return jsonError(res, 400, "invalid status");
    const evidence = jsonStringField(parsed.value.object, "evidence", max_evidence_bytes) orelse return jsonError(res, 400, "evidence is too large");
    const note = jsonStringField(parsed.value.object, "note", max_note_bytes) orelse return jsonError(res, 400, "note is too large");
    const updated_by = ctx.request_auth.username orelse "local reviewer";
    const updated_at = try review.isoTimestamp(req.arena, clock.timestamp());

    const entry = Entry{
        .id = id,
        .status = status,
        .evidence = evidence,
        .note = note,
        .updated_by = updated_by,
        .updated_at = updated_at,
    };
    persistEntry(req.arena, ctx.project_dir, name, &ctx.state.reviews.board_review_mutex, entry) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReviewStateFull => return jsonError(res, 409, "review state is full"),
        else => return jsonError(res, 500, "review state could not be saved"),
    };

    var out: std.Io.Writer.Allocating = .init(res.arena);
    try out.writer.writeAll("{\"ok\":true,\"entry\":");
    try writeEntryJson(&out.writer, entry);
    try out.writer.writeByte('}');
    res.content_type = .JSON;
    res.header("cache-control", "no-store");
    res.body = out.written();
}

fn queryOpt(req: *httpz.Request, key: []const u8) ?[]const u8 {
    const query = req.query() catch return null;
    const value = query.get(key) orelse return null;
    return if (value.len == 0) null else value;
}

fn writeHtmlEscaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try escape.writeXml(w, text);
}

fn writeUrlEncoded(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

fn writeDesignHref(w: *std.Io.Writer, path: []const u8, name: []const u8, layout: ?[]const u8, view_3d: bool) std.Io.Writer.Error!void {
    try w.writeAll(path);
    try writeUrlEncoded(w, name);
    if (view_3d or layout != null) {
        try w.writeByte('?');
        if (view_3d) {
            try w.writeAll("view=3d");
            if (layout != null) try escape.writeXml(w, "&");
        }
        if (layout) |selected| {
            try w.writeAll("layout=");
            try writeUrlEncoded(w, selected);
        }
    }
}

fn writeReviewNav(w: *std.Io.Writer, name: []const u8, layout: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll("<nav class=\"viewtoggle\" aria-label=\"View\"><a href=\"/schematics/");
    try writeUrlEncoded(w, name);
    try w.writeAll("\">Schematic</a><a href=\"");
    try writeDesignHref(w, "/pcb-layout/", name, layout, false);
    try w.writeAll("\">PCB Layout</a><a href=\"");
    try writeDesignHref(w, "/pcb-layout/", name, layout, true);
    try w.writeAll("\">3D View</a><a href=\"");
    try writeDesignHref(w, "/assembly-debug/", name, layout, false);
    try w.writeAll("\">Assembly</a><a href=\"");
    try writeDesignHref(w, "/thermal/", name, layout, false);
    try w.writeAll("\">Thermal</a><a class=\"active\" href=\"");
    try writeDesignHref(w, "/review/", name, layout, false);
    try w.writeAll("\">Review</a></nav>");
}

/// Render the board checklist and live generated-evidence dashboard.
pub fn reviewPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "Missing design name\n";
        return;
    };
    if (!designExists(req.arena, ctx.project_dir, name)) {
        res.status = 404;
        res.body = "No design by that name\n";
        return;
    }
    const layout = queryOpt(req, "layout");
    var out: std.Io.Writer.Allocating = .init(res.arena);
    const w = &out.writer;
    try w.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
    try writeHtmlEscaped(w, name);
    try w.writeAll(" — Board Review</title><style>");
    try w.writeAll(navbar_css);
    try w.writeAll(page_css);
    try w.writeAll("</style></head><body><div class=\"navbar\"><span class=\"brand\">Canopy EDA</span><a href=\"/\">Designs</a><a href=\"/library\">Library</a><a href=\"/account\" style=\"margin-left:auto\">Account</a></div><main class=\"review-shell\"><header class=\"review-head\"><div class=\"review-title\"><h1>");
    try writeHtmlEscaped(w, name);
    try w.writeAll("</h1><p>Board design review · ");
    if (layout) |selected| {
        try w.writeAll("saved layout ");
        try writeHtmlEscaped(w, selected);
    } else try w.writeAll("starred/default layout");
    try w.writeAll("</p></div>");
    try writeReviewNav(w, name, layout);
    try w.writeAll("</header>");
    if (!ctx.request_auth.role.canWrite()) try w.writeAll("<div class=\"read-only\">Read-only session: checklist decisions and evidence are visible, but only writers can change them.</div>");
    try w.writeAll("<section class=\"review-intro\"><div class=\"intro-card\"><h2>Evidence-driven release review</h2><p>Work through each item as Pass, Fail, N/A, or Needs info. Attach a refdes, net, layer, report, or datasheet section/page and a short interpretation. Open Critical and Major findings remain release risks even when ERC and DRC are clean.</p><p>The generated audit below reuses the same release checks, component profiles, layout ladder, DRC, fabrication readiness, and BOM evidence that feed review packages and dossiers.</p><div class=\"review-links\"><a href=\"/api/schematic-pdf/");
    try writeUrlEncoded(w, name);
    try w.writeAll("\">Review PDF</a><a href=\"/api/export-review/");
    try writeUrlEncoded(w, name);
    try w.writeAll("\">Review package</a><a href=\"/api/fab-readiness/");
    try writeUrlEncoded(w, name);
    if (layout) |selected| {
        try w.writeAll("?layout=");
        try writeUrlEncoded(w, selected);
    }
    try w.writeAll("\">Fab readiness JSON</a></div></div><div class=\"progress-card\"><div class=\"metric ready\"><strong id=\"metric-ready\">0 / 258</strong><span>ready (Pass + N/A)</span></div><div class=\"metric\"><strong id=\"metric-reviewed\">0 / 258</strong><span>reviewed</span></div><div class=\"metric blocked\"><strong id=\"metric-blocked\">0</strong><span>Fail / Needs info</span></div><div class=\"metric open\"><strong id=\"metric-open\">258</strong><span>open</span></div><div class=\"bar\" aria-label=\"Review readiness\"><span id=\"progress-bar\"></span></div></div></section>");
    try w.writeAll("<div class=\"toolbar\"><input id=\"review-search\" type=\"search\" placeholder=\"Search checklist, e.g. creepage, MLCC, 11.9…\"><button class=\"filter active\" data-filter=\"all\">All</button><button class=\"filter\" data-filter=\"remaining\">Remaining</button><button class=\"filter\" data-filter=\"fail\">Fail</button><button class=\"filter\" data-filter=\"needs_info\">Needs info</button><button class=\"quiet-btn\" id=\"expand-all\">Expand all</button><button class=\"quiet-btn\" id=\"collapse-all\">Collapse all</button><span class=\"save-state\" id=\"save-state\"></span></div><div id=\"checklist\"></div><div class=\"empty\" id=\"empty\" hidden>No checklist items match this view.</div>");
    try w.writeAll("<details class=\"audit-card\" open><summary>Automated board audit <span class=\"audit-note\">Live generated evidence; not a substitute for the human checklist</span></summary><div id=\"audit\" class=\"audit-loading\">Running release checks, component profiles, layout progress, DRC, and fabrication readiness…</div></details></main><script>const DESIGN_NAME=");
    try json_writer.writeScriptString(w, name);
    try w.writeAll(";const CHECKLIST_MARKDOWN=");
    try json_writer.writeScriptString(w, catalog_markdown);
    try w.print(";const CAN_WRITE={s};</script><script>", .{if (ctx.request_auth.role.canWrite()) "true" else "false"});
    try w.writeAll(page_js);
    try w.writeAll("</script></body></html>");
    res.content_type = .HTML;
    res.header("cache-control", "no-store");
    res.body = out.written();
}

/// Return safe HTML from the existing generated Board Review Audit.
pub fn auditApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return jsonError(res, 404, "missing design name");
    if (!designExists(req.arena, ctx.project_dir, name)) return jsonError(res, 404, "no design by that name");
    const markdown = review_audit.render(req.arena, ctx.project_dir, name, .{ .layout = queryOpt(req, "layout") }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonError(res, 422, @errorName(err)),
    };
    const html = renderAuditHtml(req.arena, markdown) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonError(res, 500, "generated audit did not pass the safe Markdown profile"),
    };
    var out: std.Io.Writer.Allocating = .init(res.arena);
    try out.writer.writeAll("{\"ok\":true,\"html\":");
    try json_writer.writeString(&out.writer, html);
    try out.writer.writeByte('}');
    res.content_type = .JSON;
    res.header("cache-control", "no-store");
    res.body = out.written();
}

fn renderAuditHtml(allocator: std.mem.Allocator, markdown: []const u8) ![]const u8 {
    var document = try system_review_md.parse(allocator, markdown, .{});
    defer document.deinit();
    return try system_review_md.renderHtmlAlloc(allocator, &document);
}

// spec: serve/board-review - the supplied review catalog retains all 13 sections and 258 discrete decisions
test "board review catalog has stable sections and item ids" {
    var sections: usize = 0;
    var items: usize = 0;
    var lines = std.mem.splitScalar(u8, catalog_markdown, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## Section ")) sections += 1;
        if (std.mem.startsWith(u8, line, "- [ ] **")) items += 1;
    }
    try std.testing.expectEqual(@as(usize, 13), sections);
    try std.testing.expectEqual(@as(usize, 258), items);
    try std.testing.expect(validItemId("1.1"));
    try std.testing.expect(validItemId("11.9"));
    try std.testing.expect(validItemId("13.15"));
    try std.testing.expect(!validItemId("../1"));
}

// spec: serve/board-review - human dispositions round-trip all evidence fields in bounded JSON
test "board review state JSON round trips reviewer evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    const entries = [_]Entry{.{
        .id = "11.9",
        .status = .needs_info,
        .evidence = "Gerber read-back pending",
        .note = "Compare every exported layer",
        .updated_by = "reviewer@example.com",
        .updated_at = "2026-09-02T12:00:00Z",
    }};
    try saveEntries(arena, root, "demo", &entries);
    const loaded = try loadEntries(arena, root, "demo");
    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqual(Status.needs_info, loaded[0].status);
    try std.testing.expectEqualStrings("Gerber read-back pending", loaded[0].evidence);
    try std.testing.expectEqualStrings("reviewer@example.com", loaded[0].updated_by);
}

// spec: serve/board-review - the page reports ready, reviewed, blocked and open totals, and supports search, remaining/failure filters, and per-section progress
// spec: serve/board-review - the automated audit loads separately after the checklist shell paints and renders only through the safe system-review Markdown parser
// spec: serve/board-review - read-only reviewers see every disposition and generated result but cannot edit controls
// spec: serve/board-review - the Review page carries the selected saved layout through every physical-board link
test "board review page exposes progress filters safe audit and read-only controls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var state: serve_root.ServerState = .{};
    var server = Server{ .allocator = arena, .project_dir = root, .auth_dir = root, .state = &state };
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "demo");
    request.query("layout", "release-A");
    try reviewPage(&server, request.req, request.res);

    const body = request.res.body;
    try std.testing.expect(std.mem.indexOf(u8, body, "id=\"metric-ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data-filter=\"remaining\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data-filter=\"fail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "class=\"section-progress\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_js, "section-progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_js, "select.disabled=!CAN_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_js, "evidence.disabled=!CAN_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "const CAN_WRITE=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Read-only session") != null);
    const checklist_render = std.mem.indexOf(u8, page_js, "render();") orelse return error.TestExpectedChecklistRender;
    const audit_load = std.mem.indexOf(u8, page_js, "loadAudit();") orelse return error.TestExpectedAuditLoad;
    try std.testing.expect(checklist_render < audit_load);
    try std.testing.expect(std.mem.indexOf(u8, body, "/pcb-layout/demo?layout=release-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/pcb-layout/demo?view=3d&amp;layout=release-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/assembly-debug/demo?layout=release-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/thermal/demo?layout=release-A") != null);

    const safe = try renderAuditHtml(arena, "# Generated audit\n\n- Evidence: **ready**\n");
    try std.testing.expect(std.mem.indexOf(u8, safe, "<h1>Generated audit</h1>") != null);
    try std.testing.expectError(error.RawHtml, renderAuditHtml(arena, "<script>alert(1)</script>"));
}

// spec: serve/board-review - a checklist mutation accepts only a catalog item id and fixed status, bounds its evidence and note, requires writer authority plus the review mutation header, and stamps the authenticated identity instead of a body-supplied reviewer
test "board review mutations enforce authority schema bounds and reviewer identity" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var state: serve_root.ServerState = .{};

    var reader_server = Server{ .allocator = arena, .project_dir = root, .auth_dir = root, .state = &state };
    var reader = httpz.testing.init(.{});
    defer reader.deinit();
    reader.param("name", "demo");
    reader.header(mutation_header, mutation_value);
    reader.body("{\"id\":\"1.1\",\"status\":\"pass\",\"evidence\":\"R1\",\"note\":\"checked\"}");
    try updateStateApi(&reader_server, reader.req, reader.res);
    try std.testing.expectEqual(@as(u16, 403), reader.res.status);

    var writer_server = Server{
        .allocator = arena,
        .project_dir = root,
        .auth_dir = root,
        .request_auth = .{ .username = "real-reviewer@example.com", .role = .writer },
        .state = &state,
    };
    var missing_header = httpz.testing.init(.{});
    defer missing_header.deinit();
    missing_header.param("name", "demo");
    missing_header.body("{\"id\":\"1.1\",\"status\":\"pass\",\"evidence\":\"R1\",\"note\":\"checked\"}");
    try updateStateApi(&writer_server, missing_header.req, missing_header.res);
    try std.testing.expectEqual(@as(u16, 403), missing_header.res.status);

    var unknown = httpz.testing.init(.{});
    defer unknown.deinit();
    unknown.param("name", "demo");
    unknown.header(mutation_header, mutation_value);
    unknown.body("{\"id\":\"99.99\",\"status\":\"pass\",\"evidence\":\"R1\",\"note\":\"checked\"}");
    try updateStateApi(&writer_server, unknown.req, unknown.res);
    try std.testing.expectEqual(@as(u16, 400), unknown.res.status);

    var invalid_status = httpz.testing.init(.{});
    defer invalid_status.deinit();
    invalid_status.param("name", "demo");
    invalid_status.header(mutation_header, mutation_value);
    invalid_status.body("{\"id\":\"1.1\",\"status\":\"done\",\"evidence\":\"R1\",\"note\":\"checked\"}");
    try updateStateApi(&writer_server, invalid_status.req, invalid_status.res);
    try std.testing.expectEqual(@as(u16, 400), invalid_status.res.status);

    const too_much_evidence: [max_evidence_bytes + 1]u8 = @splat('x');
    const oversized = try std.fmt.allocPrint(arena, "{{\"id\":\"1.1\",\"status\":\"pass\",\"evidence\":\"{s}\",\"note\":\"checked\"}}", .{&too_much_evidence});
    var bounded = httpz.testing.init(.{});
    defer bounded.deinit();
    bounded.param("name", "demo");
    bounded.header(mutation_header, mutation_value);
    bounded.body(oversized);
    try updateStateApi(&writer_server, bounded.req, bounded.res);
    try std.testing.expectEqual(@as(u16, 400), bounded.res.status);

    var accepted = httpz.testing.init(.{});
    defer accepted.deinit();
    accepted.param("name", "demo");
    accepted.header(mutation_header, mutation_value);
    accepted.body("{\"id\":\"1.1\",\"status\":\"pass\",\"evidence\":\"R1\",\"note\":\"checked\",\"updated_by\":\"spoofed@example.com\"}");
    try updateStateApi(&writer_server, accepted.req, accepted.res);
    try std.testing.expectEqual(@as(u16, 200), accepted.res.status);
    try std.testing.expect(std.mem.indexOf(u8, accepted.res.body, "real-reviewer@example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, accepted.res.body, "spoofed@example.com") == null);
}

const ConcurrentReviewWriter = struct {
    project_dir: []const u8,
    id: []const u8,
    mutex: *infra_fs.Mutex,
    go: *std.atomic.Value(bool),
    failed: *std.atomic.Value(bool),
    gpa: std.mem.Allocator,

    fn run(self: ConcurrentReviewWriter) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        while (!self.go.load(.acquire)) std.atomic.spinLoopHint();
        persistEntry(arena_state.allocator(), self.project_dir, "demo", self.mutex, .{
            .id = self.id,
            .status = .pass,
            .evidence = "parallel review",
            .updated_by = "threaded-test",
            .updated_at = "2026-09-02T12:00:00Z",
        }) catch self.failed.store(true, .release);
    }
};

fn runConcurrentReviewWriters(
    project_dir: []const u8,
    ids: [4][]const u8,
    mutex: *infra_fs.Mutex,
    failed: *std.atomic.Value(bool),
    gpa: std.mem.Allocator,
) !void {
    var go: std.atomic.Value(bool) = .init(false);
    var threads: [ids.len]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < threads.len) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, ConcurrentReviewWriter.run, .{ConcurrentReviewWriter{
            .project_dir = project_dir,
            .id = ids[spawned],
            .mutex = mutex,
            .go = &go,
            .failed = failed,
            .gpa = gpa,
        }}) catch break;
    }
    go.store(true, .release);
    for (threads[0..spawned]) |thread| thread.join();
    if (spawned != threads.len) return error.TestThreadSpawnFailed;
}

// spec: serve/board-review - concurrent checklist mutations serialize their whole read-modify-write and atomically replace the design-sibling sidecar
test "concurrent board review mutations retain every disposition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var mutex: infra_fs.Mutex = .{};
    var failed: std.atomic.Value(bool) = .init(false);
    const ids = [_][]const u8{ "1.1", "1.2", "1.3", "1.4" };
    try runConcurrentReviewWriters(root, ids, &mutex, &failed, std.heap.page_allocator);
    try std.testing.expect(!failed.load(.acquire));

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const loaded = try loadEntries(arena_state.allocator(), root, "demo");
    try std.testing.expectEqual(ids.len, loaded.len);
    for (ids) |id| {
        const found = for (loaded) |entry| {
            if (std.mem.eql(u8, entry.id, id)) break true;
        } else false;
        try std.testing.expect(found);
    }
}
