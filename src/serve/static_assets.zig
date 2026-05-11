const std = @import("std");
const httpz = @import("httpz");

const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

const account_page_js = @embedFile("assets/account_page.js");
const account_page_css = @embedFile("assets/account_page.css");
const pdf_viewer_js = @embedFile("assets/pdf_viewer.js");
const pdf_viewer_css = @embedFile("assets/pdf_viewer.css");
const library_js = @embedFile("assets/library.js");
const auth_login_js = @embedFile("assets/auth_login.js");
const auth_setup_js = @embedFile("assets/auth_setup.js");
const auth_invite_js = @embedFile("assets/auth_invite.js");

/// Error set for the static-asset handler: only writer-side errors propagate
/// to httpz; the lookup itself is fallible only via a 404.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const Asset = struct {
    name: []const u8,
    body: []const u8,
    content_type: httpz.ContentType,
};

/// Registry of `@embedFile`-backed assets that page templates link to via
/// `<script src="/static/...">` / `<link href="/static/...">`. Adding a new
/// asset is a one-line entry here plus the `@embedFile` import above —
/// `staticAsset` does the lookup.
const REGISTRY = [_]Asset{
    .{ .name = "account_page.js", .body = account_page_js, .content_type = .JS },
    .{ .name = "account_page.css", .body = account_page_css, .content_type = .CSS },
    .{ .name = "pdf_viewer.js", .body = pdf_viewer_js, .content_type = .JS },
    .{ .name = "pdf_viewer.css", .body = pdf_viewer_css, .content_type = .CSS },
    .{ .name = "library.js", .body = library_js, .content_type = .JS },
    .{ .name = "auth_login.js", .body = auth_login_js, .content_type = .JS },
    .{ .name = "auth_setup.js", .body = auth_setup_js, .content_type = .JS },
    .{ .name = "auth_invite.js", .body = auth_invite_js, .content_type = .JS },
};

/// GET /static/:name — serve an embedded JS/CSS asset. 404 if the name is
/// unknown, so pages can't accidentally pull an asset that isn't registered.
pub fn staticAsset(_: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "asset not found";
        return;
    };
    for (REGISTRY) |a| {
        if (std.mem.eql(u8, a.name, name)) {
            res.content_type = a.content_type;
            res.body = a.body;
            return;
        }
    }
    res.status = 404;
    res.body = "asset not found";
}
