const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

pub const SPA_JS = @embedFile("spa_js");
pub const SPA_CSS = @embedFile("spa_css");

/// GET /v2/app.js — serve the embedded SPA bundle. `cache-control: no-cache`
/// keeps the dev workflow honest: every page reload picks up a freshly
/// rebuilt binary without the browser holding onto a stale script.
pub fn jsApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JS;
    res.header("cache-control", "no-cache");
    res.body = SPA_JS;
}

/// GET /v2/app.css — serve the embedded SPA stylesheet, also marked
/// `no-cache` so a recompile is enough to update the styling on the next
/// reload without manual cache busting.
pub fn cssApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    res.header("cache-control", "no-cache");
    res.body = SPA_CSS;
}
