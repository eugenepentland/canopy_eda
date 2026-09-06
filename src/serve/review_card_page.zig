//! The `/review/:name` card view: the Board Review Card as a page.
//!
//! `src/review_card.zig` already answers the whole unit review as ONE value —
//! twelve fixed categories, every row citing a registry id, every verdict in
//! the seven-word vocabulary. This module is only that value's page: a shell
//! the server renders immediately and a script that fetches
//! `GET /api/review-card/:name[?layout=]` and lays the card out.
//!
//! The split matters because the card is expensive. Composing it on a board
//! the size of Barracuda runs the release preflight, the ERC, the fabrication
//! gate, the DRC and the thermal screen; that is tens of seconds cold. A page
//! that waited for it server-side would answer nothing at all for that whole
//! time, so the shell paints first and the script shows what it is waiting on.
//!
//! The 258-item research catalogue that used to BE this page is still here,
//! one query parameter away (`?view=reference`, rendered by
//! `serve/board_review.zig`), with its saved dispositions and its MCP tools
//! untouched — demoted from the answer to the reference behind it.
//!
//! Read-only: the card view writes nothing. It is a sibling module rather than
//! more of `board_review.zig` because the two views share only their URL, the
//! navigation strip below and the stylesheet.

const std = @import("std");
const httpz = @import("httpz");
const escape = @import("../escape.zig");
const json_writer = @import("../json_writer.zig");
const navbar = @import("navbar.zig");

/// Allocation or response-writer failures that may escape an HTTP handler.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const page_css = @embedFile("assets/board_review.css");
const card_css = @embedFile("assets/board_review_card.css");
const card_js = @embedFile("assets/board_review_card.js");

/// Percent-encode `text` into a URL path or query segment.
pub fn writeUrlEncoded(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |c| {
        const safe = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
    }
}

/// Write a per-design href, carrying the selected saved layout and the 3D flag
/// so every board surface stays on the layout the reviewer is looking at.
pub fn writeDesignHref(
    w: *std.Io.Writer,
    path: []const u8,
    name: []const u8,
    layout: ?[]const u8,
    view_3d: bool,
) std.Io.Writer.Error!void {
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

/// The board-surface navigation strip, with Review marked active. Both review
/// views render it, so the tab a reviewer arrived on keeps working whichever
/// view answers.
pub fn writeReviewNav(w: *std.Io.Writer, name: []const u8, layout: ?[]const u8) std.Io.Writer.Error!void {
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

fn writeHead(w: *std.Io.Writer, name: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("<!doctype html><html><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>");
    try escape.writeXml(w, name);
    try w.writeAll(" — Board Review Card</title><style>");
    try w.writeAll(navbar.css);
    try w.writeAll(page_css);
    try w.writeAll(card_css);
    try w.writeAll("</style></head><body>");
}

fn writeTitle(w: *std.Io.Writer, name: []const u8, layout: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll("<main class=\"review-shell card-shell\"><header class=\"review-head\">" ++
        "<div class=\"review-title\"><h1>");
    try escape.writeXml(w, name);
    try w.writeAll("</h1><p>Board Review Card · ");
    if (layout) |selected| {
        try w.writeAll("saved layout ");
        try escape.writeXml(w, selected);
    } else try w.writeAll("starred/default layout");
    try w.writeAll("</p></div>");
    try writeReviewNav(w, name, layout);
    try w.writeAll("</header>");
}

/// The links out of the card: the demoted catalogue, the JSON the page itself
/// renders from, and the two export surfaces the old page offered.
fn writeActions(w: *std.Io.Writer, name: []const u8, layout: ?[]const u8) std.Io.Writer.Error!void {
    try w.writeAll("<div class=\"review-links card-links\"><a class=\"card-reference-link\" href=\"");
    try writeDesignHref(w, "/review/", name, layout, false);
    try w.writeAll(if (layout == null) "?view=reference" else "&amp;view=reference");
    try w.writeAll("\">Reference checklist (258 items)</a><a href=\"/api/review-card/");
    try writeUrlEncoded(w, name);
    if (layout) |selected| {
        try w.writeAll("?layout=");
        try writeUrlEncoded(w, selected);
    }
    try w.writeAll("\">Card JSON</a><a href=\"/api/schematic-pdf/");
    try writeUrlEncoded(w, name);
    try w.writeAll("\">Review PDF</a><a href=\"/api/export-review/");
    try writeUrlEncoded(w, name);
    try w.writeAll("\">Review package</a></div>");
}

const toolbar_html =
    "<div class=\"toolbar card-toolbar\">" ++
    "<input id=\"card-search\" type=\"search\" placeholder=\"Search check ids, subjects, results and evidence…\">" ++
    "<button class=\"filter active\" data-filter=\"all\">All</button>" ++
    "<button class=\"filter\" data-filter=\"fail\">Fail</button>" ++
    "<button class=\"filter\" data-filter=\"unproven\">Unproven</button>" ++
    "<button class=\"filter\" data-filter=\"not_declared\">Not declared</button>" ++
    "<button class=\"filter\" data-filter=\"waived\">Waived</button>" ++
    "<button class=\"filter\" data-filter=\"manual\">Manual</button>" ++
    "<button class=\"quiet-btn\" id=\"card-expand\">Expand all</button>" ++
    "<button class=\"quiet-btn\" id=\"card-collapse\">Collapse all</button>" ++
    "<span class=\"save-state\" id=\"card-state\"></span></div>";

const body_html =
    "<section class=\"card-head\" id=\"card-head\">" ++
    "<p class=\"card-progress\" id=\"card-progress\">Composing the Board Review Card — the release checks, " ++
    "the fabrication gate and the DRC all run for this. It can take a minute on a large board.</p></section>" ++
    toolbar_html ++
    "<div class=\"card-legend\" id=\"card-legend\"></div>" ++
    "<div id=\"card-categories\"></div>" ++
    "<div class=\"empty\" id=\"card-empty\" hidden>No registered check matches this view.</div>" ++
    "<section class=\"card-block\" id=\"card-parts\"></section>" ++
    "<section class=\"card-block\" id=\"card-fab\"></section>" ++
    "<section class=\"card-block\" id=\"card-ladder\"></section>";

/// Render the card view of `/review/:name` into `res`.
///
/// The body is the shell only: every value on the page arrives from
/// `GET /api/review-card/:name`, which the script below fetches. Nothing here
/// evaluates the design, so the page paints in the time it takes to write
/// these bytes however slow the card itself is.
pub fn render(res: *httpz.Response, name: []const u8, layout: ?[]const u8) HandlerError!void {
    var out: std.Io.Writer.Allocating = .init(res.arena);
    const w = &out.writer;
    try writeHead(w, name);
    try navbar.write(w, .none);
    try writeTitle(w, name, layout);
    try writeActions(w, name, layout);
    try w.writeAll(body_html);
    try w.writeAll("</main><script>const DESIGN_NAME=");
    try json_writer.writeScriptString(w, name);
    try w.writeAll(";const LAYOUT=");
    if (layout) |selected| try json_writer.writeScriptString(w, selected) else try w.writeAll("null");
    try w.writeAll(";</script><script>");
    try w.writeAll(card_js);
    try w.writeAll("</script></body></html>");
    res.content_type = .HTML;
    res.header("cache-control", "no-store");
    res.body = out.written();
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

fn renderTo(alloc: std.mem.Allocator, name: []const u8, layout: ?[]const u8) ![]const u8 {
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    try render(ht.res, name, layout);
    return alloc.dupe(u8, ht.res.body);
}

// spec: serve/board-review - the card view renders a shell that fetches the Board Review Card, the seven-verdict filters and a link to the reference checklist
test "the card page shell carries the card endpoint, the filters and the reference link" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body = try renderTo(alloc, "demo", null);
    try testing.expect(std.mem.indexOf(u8, body, "id=\"card-categories\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "id=\"card-parts\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "id=\"card-fab\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "id=\"card-ladder\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "id=\"card-progress\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "/review/demo?view=reference") != null);
    try testing.expect(std.mem.indexOf(u8, body, "/api/review-card/demo") != null);
    try testing.expect(std.mem.indexOf(u8, body, "const DESIGN_NAME=\"demo\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "const LAYOUT=null") != null);
    // The seven-word vocabulary drives the filters, spelled as the card's JSON
    // spells them.
    inline for (.{ "all", "fail", "unproven", "not_declared", "waived", "manual" }) |tag|
        try testing.expect(std.mem.indexOf(u8, body, "data-filter=\"" ++ tag ++ "\"") != null);
    // The script fetches the card rather than the page rendering it.
    try testing.expect(std.mem.indexOf(u8, card_js, "/api/review-card/") != null);
    try testing.expect(std.mem.indexOf(u8, card_js, "not_declared") != null);
}

// spec: serve/board-review - the card view carries the selected saved layout into every board link, the card request and the reference view
test "the card page threads a selected layout through its links and its request" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body = try renderTo(alloc, "demo", "release-A");
    try testing.expect(std.mem.indexOf(u8, body, "/pcb-layout/demo?layout=release-A") != null);
    try testing.expect(std.mem.indexOf(u8, body, "/thermal/demo?layout=release-A") != null);
    try testing.expect(std.mem.indexOf(u8, body, "/review/demo?layout=release-A&amp;view=reference") != null);
    try testing.expect(std.mem.indexOf(u8, body, "/api/review-card/demo?layout=release-A") != null);
    try testing.expect(std.mem.indexOf(u8, body, "const LAYOUT=\"release-A\"") != null);
    try testing.expect(std.mem.indexOf(u8, card_js, "LAYOUT") != null);
}

// spec: serve/board-review - the card page escapes a hostile design name everywhere it appears
test "the card page escapes a hostile design name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const body = try renderTo(alloc, "</script><img src=x>", null);
    try testing.expect(std.mem.indexOf(u8, body, "<img src=x>") == null);
    try testing.expect(std.mem.indexOf(u8, body, "</script><img") == null);
}
