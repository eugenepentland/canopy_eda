const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

const SHELL_HTML =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>EDA</title>
    \\<link rel="stylesheet" href="/v2/spa.css">
    \\<script src="https://cdn.jsdelivr.net/npm/pixi.js@8.6.6/dist/pixi.min.js"></script>
    \\</head>
    \\<body>
    \\<div id="app"></div>
    \\<script src="/v2/spa.js"></script>
    \\</body>
    \\</html>
    \\
;

pub fn shellApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.header("cache-control", "no-cache");
    res.body = SHELL_HTML;
}
