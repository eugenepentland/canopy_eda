const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const bom_html = @import("bom_html.zig");
const assets_css = @import("assets_css.zig");
const assets_js = @import("assets_js.zig");
const library = @import("library.zig");
const mcp_tools = @import("mcp_tools.zig");

pub fn indexPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.writeAll("<title>EDA Designs</title><link rel=\"stylesheet\" href=\"/style.css\"><style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(
        \\.designs-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(260px,1fr));gap:12px;padding:16px}
        \\.design-card{background:#161b22;border:1px solid #21262d;border-radius:10px;padding:20px;text-decoration:none;display:block;transition:border-color 0.15s}
        \\.design-card:hover{border-color:#58a6ff}
        \\.design-card-name{color:#58a6ff;font-size:1.1rem;font-weight:600;margin-bottom:8px}
        \\.design-card-links{display:flex;gap:12px;margin-top:12px}
        \\.design-card-link{color:#8b949e;font-size:13px;padding:6px 14px;border:1px solid #30363d;border-radius:6px;text-decoration:none;text-align:center;flex:1}
        \\.design-card-link:hover{border-color:#58a6ff;color:#c9d1d9}
        \\@media(max-width:600px){.designs-grid{grid-template-columns:1fr;padding:12px;gap:10px}.design-card{padding:16px}}
    );
    try w.writeAll("</style></head><body>");
    try assets_css.writeNavbar(w, "designs");
    try w.writeAll("<div style=\"max-width:960px;margin:0 auto\"><h1 style=\"padding:16px 16px 0;color:#f0f6fc\">Designs</h1><div class=\"designs-grid\">");

    const design_names = mcp_tools.listDesignNames(ctx.allocator, ctx.project_dir) catch &[_][]const u8{};
    for (design_names) |design_name| {
        try w.print("<div class=\"design-card\"><div class=\"design-card-name\">{s}</div><div class=\"design-card-links\"><a class=\"design-card-link\" href=\"/schematics/{s}\">Schematic</a><a class=\"design-card-link\" href=\"/pcb/{s}\">PCB</a></div></div>", .{ design_name, design_name, design_name });
    }

    try w.writeAll("</div></div></body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}

pub fn cssPage(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    res.body = assets_css.INDEX_CSS;
}
