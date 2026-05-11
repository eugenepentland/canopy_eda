const std = @import("std");
const httpz = @import("httpz");
const clock = @import("../infra/clock.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const bom_html = @import("bom_html.zig");
const assets_css = @import("assets_css.zig");
const library = @import("library.zig");
const mcp_tools = @import("mcp_tools.zig");

// ── Constants ─────────────────────────────────────────────────────
const SECONDS_PER_MINUTE: i64 = 60;
const SECONDS_PER_HOUR: i64 = 3600;
const SECONDS_PER_DAY: i64 = 86400;
const DAYS_PER_MONTH_APPROX: i64 = 30;

/// Error set for HTTP handlers in this module: only writer-side errors
/// propagate back to httpz; everything else is caught internally and
/// translated to a 5xx body.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// GET / — render the home page: a card grid of every `.sexp` design under
/// `src/` with title, instance/net counts, recent-mtime badge, section
/// chips, and links to Schematic / Review for each.
pub fn indexPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.writeAll("<title>EDA Designs</title><link rel=\"stylesheet\" href=\"/style.css\"><style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(
        \\.designs-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px;padding:16px}
        \\.design-card{background:#161b22;border:1px solid #21262d;
        \\border-radius:10px;padding:18px 20px;display:flex;flex-direction:column;
        \\gap:10px;transition:border-color 0.15s}
        \\.design-card:hover{border-color:#58a6ff}
        \\.design-card-header{display:flex;flex-direction:column;gap:2px}
        \\.design-card-title{color:#f0f6fc;font-size:1.05rem;font-weight:600;line-height:1.3}
        \\.design-card-name{color:#6e7681;font-size:12px;font-family:monospace}
        \\.design-card-stats{display:flex;gap:8px;font-size:12px;color:#8b949e;align-items:center;flex-wrap:wrap}
        \\.design-card-stats .sep{color:#30363d}
        \\.design-card-stats .warn{color:#d29922}
        \\.design-card-sections{display:flex;flex-wrap:wrap;gap:4px}
        \\.section-chip{background:#1a1a2e;color:#8b949e;font-size:11px;padding:2px 8px;border-radius:10px;border:1px solid #21262d}
        \\.section-chip-more{color:#6e7681;font-size:11px;padding:2px 4px}
        \\.design-card-links{display:flex;gap:8px;margin-top:auto;padding-top:4px}
        \\.design-card-link{color:#8b949e;font-size:13px;padding:6px 14px;
        \\border:1px solid #30363d;border-radius:6px;text-decoration:none;
        \\text-align:center;flex:1}
        \\.design-card-link:hover{border-color:#58a6ff;color:#c9d1d9}
        \\.empty-hint{color:#6e7681;font-size:13px;padding:24px;text-align:center}
        \\@media(max-width:600px){.designs-grid{grid-template-columns:1fr;padding:12px;gap:10px}.design-card{padding:16px}}
    );
    try w.writeAll("</style></head><body>");
    try assets_css.writeNavbar(w, "designs");
    try w.writeAll("<div style=\"max-width:960px;margin:0 auto\"><h1 style=\"padding:16px 16px 0;color:#f0f6fc\">Designs</h1><div class=\"designs-grid\">");

    const summaries = mcp_tools.listDesignSummaries(ctx.allocator, ctx.project_dir) catch &[_]mcp_tools.DesignSummary{};
    const now_sec: i64 = @intCast(@divTrunc(clock.nanoTimestamp(), clock.ns_per_s));
    for (summaries) |s| {
        try w.writeAll("<div class=\"design-card\"><div class=\"design-card-header\">");

        // Title + filename
        const has_title = s.title.len > 0 and !std.mem.eql(u8, s.title, s.name);
        if (has_title) {
            try w.print("<div class=\"design-card-title\">{s}</div><div class=\"design-card-name\">{s}.sexp</div>", .{ s.title, s.name });
        } else {
            try w.print("<div class=\"design-card-title\">{s}</div>", .{s.name});
        }
        try w.writeAll("</div>");

        // Stats row
        try w.writeAll("<div class=\"design-card-stats\">");
        if (s.build_ok) {
            try w.print("<span>{d} part{s}</span><span class=\"sep\">·</span><span>{d} net{s}</span>", .{
                s.instance_count,
                if (s.instance_count == 1) "" else "s",
                s.net_count,
                if (s.net_count == 1) "" else "s",
            });
        } else {
            try w.writeAll("<span class=\"warn\">build failed</span>");
        }
        if (s.mtime_sec > 0) {
            try w.writeAll("<span class=\"sep\">·</span><span>");
            try writeRelativeTime(w, now_sec - s.mtime_sec);
            try w.writeAll("</span>");
        }
        try w.writeAll("</div>");

        // Section chips (cap to 6, then "+N more")
        if (s.sections.len > 0) {
            try w.writeAll("<div class=\"design-card-sections\">");
            const max_chips: usize = 6;
            const shown = @min(s.sections.len, max_chips);
            for (s.sections[0..shown]) |sec| {
                try w.print("<span class=\"section-chip\">{s}</span>", .{sec});
            }
            if (s.sections.len > max_chips) {
                try w.print("<span class=\"section-chip-more\">+{d} more</span>", .{s.sections.len - max_chips});
            }
            try w.writeAll("</div>");
        }

        // Action links
        try w.print(
            "<div class=\"design-card-links\">" ++
                "<a class=\"design-card-link\" href=\"/schematics/{s}\">Schematic</a>" ++
                "</div></div>",
            .{s.name},
        );
    }
    if (summaries.len == 0) {
        try w.writeAll("<div class=\"empty-hint\">No designs found in src/.</div>");
    }

    try w.writeAll("</div></div></body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}

/// Format an age in seconds as a short human-readable relative time like
/// "5m ago" or "3d ago". Values below a minute render as "just now".
fn writeRelativeTime(w: anytype, age_sec: i64) !void {
    if (age_sec < 0) {
        try w.writeAll("just now");
        return;
    }
    if (age_sec < SECONDS_PER_MINUTE) {
        try w.writeAll("just now");
        return;
    }
    if (age_sec < SECONDS_PER_HOUR) {
        try w.print("{d}m ago", .{@divTrunc(age_sec, SECONDS_PER_MINUTE)});
        return;
    }
    if (age_sec < SECONDS_PER_DAY) {
        try w.print("{d}h ago", .{@divTrunc(age_sec, SECONDS_PER_HOUR)});
        return;
    }
    if (age_sec < DAYS_PER_MONTH_APPROX * SECONDS_PER_DAY) {
        try w.print("{d}d ago", .{@divTrunc(age_sec, SECONDS_PER_DAY)});
        return;
    }
    try w.print("{d}mo ago", .{@divTrunc(age_sec, DAYS_PER_MONTH_APPROX * SECONDS_PER_DAY)});
}

/// GET /style.css — serve the static stylesheet shared by the index page
/// and other plain-HTML pages so they pick up the dark theme without
/// inlining the CSS into every response.
pub fn cssPage(_: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .CSS;
    res.body = assets_css.INDEX_CSS;
}
