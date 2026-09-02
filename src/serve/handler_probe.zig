//! Test-only harness: drive one httpz handler in process and capture what it
//! answered.
//!
//! Four download/page endpoints (`kicad_sch_export`, `schematic_pdf`,
//! `thermal_api`, `thermal_page`) each grew the same eight-line `fn serve`:
//! stand up a `ServerState` and a `Server` over a temp project, open an
//! `httpz.testing` pair, set `:name`, apply query keys, call the handler, and
//! copy the body out before the harness is torn down. That last step is the
//! one worth having in a single place — `ht.deinit()` frees the response
//! buffer, so a copy taken a line too late is a use-after-free that reads as a
//! flaky assertion rather than as a harness bug.
//!
//! The handler is `anytype` because each module declares its own
//! `HandlerError`; every one of them is a superset of `Allocator.Error`, so
//! the call is simply propagated.

const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// What one probed request answered: the status, a copy of the body owned by
/// the caller's allocator, and the content type the handler set (null when it
/// set none).
pub const Served = struct {
    status: u16,
    body: []const u8,
    content_type: ?httpz.ContentType,
};

/// Call `handler` as if httpz had routed `GET …/:name` to it with `query`
/// applied, and return what it wrote. `project` is the project dir the server
/// is rooted at; the caller owns `Served.body`.
pub fn drive(
    alloc: std.mem.Allocator,
    project: []const u8,
    name: []const u8,
    query: []const [2][]const u8,
    handler: anytype,
) !Served {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    for (query) |pair| ht.query(pair[0], pair[1]);
    try handler(&srv, ht.req, ht.res);
    return .{
        .status = ht.res.status,
        .body = try alloc.dupe(u8, ht.res.body),
        .content_type = ht.res.content_type,
    };
}
