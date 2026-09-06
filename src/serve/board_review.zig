//! Board-scoped review checklist page and persistence — the REFERENCE view of
//! `/review/:name`.
//!
//! `/review/:name` answers the Board Review Card
//! (`serve/review_card_page.zig`): twelve fixed categories, every row citing a
//! registered check. This module keeps the 258-item research catalogue that
//! used to be that page, now one query parameter away at `?view=reference`,
//! with its saved `.review.json` dispositions, its generated assessment and
//! its MCP tools unchanged. Each generated item names the registry rows that
//! prove it, so a reference criterion links to the card row that actually ran
//! rather than carrying a second opinion.
//!
//! The catalogue keeps the research checklist as human dispositions while
//! loading the generated review-audit separately. Machine facts stay live,
//! while Pass/Fail/N-A/Needs-info decisions and evidence persist beside the
//! design.

const std = @import("std");
const httpz = @import("httpz");
const catalog = @import("../board_review_catalog.zig");
const review_state = @import("../board_review_state.zig");
const clock = @import("../infra/clock.zig");
const escape = @import("../escape.zig");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const paths = @import("../paths.zig");
const review = @import("../review.zig");
const review_audit = @import("../review_audit.zig");
const review_assessment = @import("../review_assessment.zig");
const review_card_page = @import("review_card_page.zig");
const review_datasheets = @import("../review_datasheet_inventory.zig");
const serve_root = @import("../serve.zig");
const navbar = @import("navbar.zig");
const Server = serve_root.Server;

/// Allocation or response-writer failures that may escape an HTTP handler.
const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const catalog_markdown = catalog.markdown;
const page_css = @embedFile("assets/board_review.css");
const page_js = @embedFile("assets/board_review.js");
const max_body_bytes: usize = 16 * 1024;
const max_evidence_bytes = review_state.max_evidence_bytes;
const max_note_bytes = review_state.max_note_bytes;
const mutation_header = "x-netlisp-review";
const mutation_value = "1";

const Status = review_state.Status;
const Entry = review_state.Entry;
const statusFromString = review_state.statusFromString;
const validItemId = catalog.validItemId;
const loadEntries = review_state.loadEntries;
const writeEntryJson = review_state.writeEntryJson;
const renderState = review_state.renderState;
const saveEntries = review_state.saveEntries;
const persistEntry = review_state.persistEntry;

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

const writeUrlEncoded = review_card_page.writeUrlEncoded;
const writeReviewNav = review_card_page.writeReviewNav;
const writeDesignHref = review_card_page.writeDesignHref;

/// `GET /review/:name` — the Board Review Card by default, the 258-item
/// research catalogue at `?view=reference`.
///
/// One URL answers both because the Review tab on every board surface links
/// here: demoting the catalogue must not break a bookmark or a tab.
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
    const reference = std.mem.eql(u8, queryOpt(req, "view") orelse "", "reference");
    if (!reference) return review_card_page.render(res, name, layout);
    return referencePage(ctx, res, name, layout);
}

/// The 258-item research catalogue: applicability, generated verdicts, saved
/// human dispositions, and the registry rows that prove each item.
fn referencePage(ctx: *Server, res: *httpz.Response, name: []const u8, layout: ?[]const u8) HandlerError!void {
    var out: std.Io.Writer.Allocating = .init(res.arena);
    const w = &out.writer;
    try w.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
    try writeHtmlEscaped(w, name);
    try w.writeAll(" — Reference checklist</title><style>");
    try w.writeAll(navbar.css);
    try w.writeAll(page_css);
    try w.writeAll("</style></head><body>");
    try navbar.write(w, .none);
    try w.writeAll("<main class=\"review-shell\"><header class=\"review-head\"><div class=\"review-title\"><h1>");
    try writeHtmlEscaped(w, name);
    try w.writeAll("</h1><p>Reference checklist · ");
    if (layout) |selected| {
        try w.writeAll("saved layout ");
        try writeHtmlEscaped(w, selected);
    } else try w.writeAll("starred/default layout");
    try w.writeAll("</p></div>");
    try writeReviewNav(w, name, layout);
    try w.writeAll("</header>");
    if (!ctx.request_auth.role.canWrite()) try w.writeAll("<div class=\"read-only\">Read-only session: checklist decisions and evidence are visible, but only writers can change them.</div>");
    try w.writeAll("<section class=\"review-intro\"><div class=\"intro-card\"><h2>Generated engineering review</h2><p>The board is inspected first. Exact machine-verifiable criteria close as Static pass/fail, clearly absent component families close as N/A, and the remainder is routed to an Agent review or Human / measurement queue.</p><p>Agent review is datasheet-first: it inventories exact fitted BOM part numbers, uploads missing PDFs with the datasheet tools, reads them, and performs board-operating-point checks before it may ask for information. Purchase sourcing and fabrication-output paperwork are out of scope. The configured DRC profile remains the fabrication-rule authority, and actual DRC violations still fail their engineering checks.</p><p id=\"datasheet-status\">Exact fitted-part datasheet coverage is loading…</p><div class=\"review-links\"><a href=\"/api/schematic-pdf/");
    try writeUrlEncoded(w, name);
    try w.writeAll("\">Review PDF</a><a href=\"/api/export-review/");
    try writeUrlEncoded(w, name);
    try w.writeAll("\">Review package</a><a class=\"card-back-link\" href=\"");
    try writeDesignHref(w, "/review/", name, layout, false);
    try w.writeAll("\">Board Review Card</a></div></div><div class=\"progress-card\"><div class=\"metric ready\"><strong id=\"metric-ready\">0 / 258</strong><span>ready (Pass + N/A)</span></div><div class=\"metric\"><strong id=\"metric-static\">0</strong><span>closed statically</span></div><div class=\"metric agent\"><strong id=\"metric-agent\">258</strong><span>agent queue</span></div><div class=\"metric manual\"><strong id=\"metric-manual\">0</strong><span>human / measurement</span></div><div class=\"metric blocked\"><strong id=\"metric-blocked\">0</strong><span>Fail / Needs info</span></div><div class=\"metric open\"><strong id=\"metric-open\">258</strong><span>remaining</span></div><div class=\"bar\" aria-label=\"Review readiness\"><span id=\"progress-bar\"></span></div></div></section>");
    try w.writeAll("<div class=\"toolbar\"><input id=\"review-search\" type=\"search\" placeholder=\"Search criteria and generated evidence…\"><button class=\"filter active\" data-filter=\"all\">All</button><button class=\"filter\" data-filter=\"remaining\">Remaining</button><button class=\"filter\" data-filter=\"fail\">Fail</button><button class=\"filter\" data-filter=\"agent\">Agent queue</button><button class=\"filter\" data-filter=\"manual\">Human</button><button class=\"filter\" data-filter=\"na\">N/A</button><button class=\"filter\" data-filter=\"needs_info\">Needs info</button><button class=\"quiet-btn\" id=\"expand-all\">Expand all</button><button class=\"quiet-btn\" id=\"collapse-all\">Collapse all</button><span class=\"save-state\" id=\"save-state\"></span></div><div id=\"checklist\"></div><div class=\"empty\" id=\"empty\" hidden>No checklist items match this view.</div>");
    try w.writeAll("</main><script>const DESIGN_NAME=");
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

/// Return scoped machine assessment and fitted-part datasheet coverage.
pub fn auditApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return jsonError(res, 404, "missing design name");
    if (!designExists(req.arena, ctx.project_dir, name)) return jsonError(res, 404, "no design by that name");
    const facts = review_audit.collectFacts(req.arena, ctx.project_dir, name, .{ .layout = queryOpt(req, "layout") }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonError(res, 422, @errorName(err)),
    };
    const assessments = try review_assessment.build(req.arena, facts);
    const datasheets = review_datasheets.collect(req.arena, ctx.project_dir, name) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return jsonError(res, 422, @errorName(err)),
    };
    var out: std.Io.Writer.Allocating = .init(res.arena);
    try out.writer.writeAll("{\"ok\":true,\"assessment\":");
    try review_assessment.writeAssessmentJson(&out.writer, assessments);
    try out.writer.writeAll(",\"datasheets\":");
    try review_datasheets.writeInventory(&out.writer, datasheets);
    try out.writer.writeByte('}');
    res.content_type = .JSON;
    res.header("cache-control", "no-store");
    res.body = out.written();
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
    try std.testing.expectEqual(review_state.Origin.human, loaded[0].origin);
    try std.testing.expectEqualStrings("Gerber read-back pending", loaded[0].evidence);
    try std.testing.expectEqualStrings("reviewer@example.com", loaded[0].updated_by);
}

// spec: serve/board-review - the page reports ready, static pass, agent queue, human/measurement, blocked and open totals, and supports search plus generated-work filters
// spec: serve/board-review - the automated assessment loads separately after the checklist shell paints and returns only scoped item verdicts plus exact fitted-part datasheet coverage
// spec: serve/board-review - read-only reviewers see every disposition and generated result but cannot edit controls
// spec: serve/board-review - the Review page carries the selected saved layout through every physical-board link
test "board review page exposes scoped progress filters and read-only controls" {
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
    request.query("view", "reference");
    try reviewPage(&server, request.req, request.res);

    const body = request.res.body;
    try std.testing.expect(std.mem.indexOf(u8, body, "<nav class=\"navbar\" aria-label=\"Primary\"><a href=\"/\" class=\"brand\">Netlisp</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "href=\"/account\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "id=\"metric-ready\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "id=\"metric-static\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "id=\"metric-agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "id=\"metric-manual\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data-filter=\"remaining\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data-filter=\"fail\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data-filter=\"agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "data-filter=\"manual\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "class=\"section-progress\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, page_js, "section-progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_js, "select.disabled=!CAN_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_js, "evidence.disabled=!CAN_WRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_js, "generated-evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_js, "value.assessment") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "const CAN_WRITE=false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Read-only session") != null);
    const checklist_render = std.mem.indexOf(u8, page_js, "render();") orelse return error.TestExpectedChecklistRender;
    const audit_load = std.mem.indexOf(u8, page_js, "loadAudit();") orelse return error.TestExpectedAuditLoad;
    try std.testing.expect(checklist_render < audit_load);
    try std.testing.expect(std.mem.indexOf(u8, body, "/pcb-layout/demo?layout=release-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/pcb-layout/demo?view=3d&amp;layout=release-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/assembly-debug/demo?layout=release-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "/thermal/demo?layout=release-A") != null);

    try std.testing.expect(std.mem.indexOf(u8, body, "fabrication readiness") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Generated evidence register") == null);
}

// spec: serve/board-review - the Review tab answers the Board Review Card by default and the 258-item catalogue only at view=reference
test "the review route defaults to the card and keeps the catalogue behind view=reference" {
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

    var default_view = httpz.testing.init(.{});
    defer default_view.deinit();
    default_view.param("name", "demo");
    try reviewPage(&server, default_view.req, default_view.res);
    try std.testing.expect(std.mem.indexOf(u8, default_view.res.body, "id=\"card-categories\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_view.res.body, "/review/demo?view=reference") != null);
    try std.testing.expect(std.mem.indexOf(u8, default_view.res.body, "id=\"checklist\"") == null);

    var reference = httpz.testing.init(.{});
    defer reference.deinit();
    reference.param("name", "demo");
    reference.query("view", "reference");
    try reviewPage(&server, reference.req, reference.res);
    // The catalogue is intact: its shell, its saved-state script and its
    // 258 items are exactly what they were before the card took the URL.
    try std.testing.expect(std.mem.indexOf(u8, reference.res.body, "id=\"checklist\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reference.res.body, "0 / 258") != null);
    try std.testing.expect(std.mem.indexOf(u8, reference.res.body, "Board Review Card") != null);
    try std.testing.expect(std.mem.indexOf(u8, reference.res.body, "id=\"card-categories\"") == null);
    // Each generated item shows the registry rows that prove it, as links
    // onto the card row that ran.
    try std.testing.expect(std.mem.indexOf(u8, page_js, "auto.registry_ids") != null);
    try std.testing.expect(std.mem.indexOf(u8, page_js, "\"#row-\"+id") != null);
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
