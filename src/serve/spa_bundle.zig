const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

pub const SPA_JS = @embedFile("spa_js");
pub const SPA_CSS = @embedFile("spa_css");

pub fn jsApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .JS;
    res.header("cache-control", "no-cache");
    res.body = SPA_JS;
}

pub fn cssApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    res.header("cache-control", "no-cache");
    res.body = SPA_CSS;
}
