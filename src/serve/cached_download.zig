//! The preamble and epilogue every cached download endpoint repeats.
//!
//! `/api/kicad-sch/:name` and `/api/schematic-pdf/:name` both: resolve and
//! percent-decode `:name`, read the design's live version BEFORE doing any
//! work (so an edit that lands mid-request is a miss next time instead of
//! being baked into the retained body), ask `read_cache` for a hit, frame the
//! answer with the same headers whether it was built or recalled, and on the
//! way out hand the fresh body plus the read-set back to the cache along with
//! the version read at the start.
//!
//! Only the middle differs — one exports a ZIP, one composes a PDF, and their
//! failure taxonomies are genuinely different — so only the middle stays in
//! the handlers.
//!
//! Getting the two ends right is what makes the cache CORRECT rather than
//! merely fast: a copy that read the live version after producing the body
//! would retain a document for an edit that already happened, and a copy that
//! framed a hit differently from a miss would serve the same design under two
//! different `Content-Disposition` names.

const std = @import("std");
const httpz = @import("httpz");
const page_cache = @import("page_cache.zig");
const urlcodec = @import("urlcodec.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

const http_not_found: u16 = 404;
const http_internal_error: u16 = 500;

/// Sets the content type and headers of one answer. Applied to a cache hit and
/// to a freshly built body alike, which is what makes the two indistinguishable
/// to the client.
pub const Frame = *const fn (
    allocator: std.mem.Allocator,
    res: *httpz.Response,
    name: []const u8,
) std.mem.Allocator.Error!void;

/// One endpoint's fixed request context: the server, the request/response pair,
/// the plain-text body for an unresolvable `:name`, and how its answers are
/// framed.
pub const Endpoint = struct {
    ctx: *Server,
    req: *httpz.Request,
    res: *httpz.Response,
    not_found_body: []const u8,
    frame: Frame,
};

/// A request the cache could not answer: the decoded design name and the live
/// version read before any work started. Hand it back to `finish` unchanged.
pub const Miss = struct {
    name: []const u8,
    version: ?u32,
};

/// One endpoint's fixed context, in one line at the top of a handler. The
/// literal form is seven lines and both handlers opened with the same seven.
pub fn endpointFor(
    ctx: *Server,
    req: *httpz.Request,
    res: *httpz.Response,
    not_found_body: []const u8,
    frame: Frame,
) Endpoint {
    return .{ .ctx = ctx, .req = req, .res = res, .not_found_body = not_found_body, .frame = frame };
}

/// Answer a producer failure whose cause is an unresolvable `:name`, and say
/// whether it did.
///
/// `FileNotFound`/`NotADesign`/`InvalidName` is how `mcp_tools.evalNamedBlock`
/// reports a name that resolves to neither a design nor a `lib/modules` module
/// — the same three for every endpoint that resolves one, which is why the
/// mapping is here and not copied per handler. Every OTHER error belongs to
/// the producer and is the handler's own to classify.
pub fn answeredNotFound(ep: Endpoint, err: anyerror) bool {
    switch (err) {
        error.FileNotFound, error.NotADesign, error.InvalidName => {},
        else => return false,
    }
    ep.res.status = http_not_found;
    ep.res.body = ep.not_found_body;
    return true;
}

/// Answer a producer failure as a 500 with `body`. Plain text, and it never
/// reads as success: the download is a file, so a browser that ignored the
/// status would otherwise save an error page under the document's name.
pub fn fail(ep: Endpoint, body: []const u8) void {
    ep.res.status = http_internal_error;
    ep.res.body = body;
}

/// Resolve `:name` and answer straight from `cache` when it holds a current
/// body for this request.
///
/// Returns null when the request is already fully answered — either a 404 for
/// a missing `:name` or a framed cache hit. A non-null `Miss` means the caller
/// must produce the body itself and then call `finish`.
pub fn begin(ep: Endpoint, cache: anytype) std.mem.Allocator.Error!?Miss {
    const name_raw = ep.req.param("name") orelse {
        ep.res.status = http_not_found;
        ep.res.body = ep.not_found_body;
        return null;
    };
    // httpz hands `:params` over verbatim, so every filesystem-facing use
    // decodes first.
    const name = try urlcodec.decodeAlloc(ep.ctx.allocator, name_raw);

    // Read the live version BEFORE the caller does any work, so a design edit
    // that lands mid-request is treated as a miss next time instead of being
    // baked into the retained body.
    const live_version = serve_root.getLiveVersion(name);
    var miss_version: ?u32 = null;
    if (cache.serve(.{
        .scratch = ep.ctx.allocator,
        .req = ep.req,
        .res = ep.res,
        .name = name,
        .live_version = live_version,
    }, &miss_version)) {
        // The producer's own structural self-check is NOT re-run: these exact
        // bytes passed it when they were built and nothing has touched them.
        try ep.frame(ep.ctx.allocator, ep.res, name);
        return null;
    }
    return .{ .name = name, .version = miss_version };
}

/// Frame and send a freshly produced `body`, then offer it to `cache` under the
/// version `begin` read. `deps` is the read-set the producer captured; the
/// cache takes ownership of it (and refuses to retain an empty one).
pub fn finish(
    ep: Endpoint,
    cache: anytype,
    miss: Miss,
    body: []const u8,
    deps: ?page_cache.FileSet,
) std.mem.Allocator.Error!void {
    try ep.frame(ep.ctx.allocator, ep.res, miss.name);
    ep.res.body = body;
    cache.store(.{
        .scratch = ep.ctx.allocator,
        .req = ep.req,
        .res = ep.res,
        .name = miss.name,
        .body = body,
        .files = deps,
        .live_version = miss.version,
        // Re-read now: a design edited while the body was being produced must
        // not have that body retained against the pre-edit version.
        .current_version = serve_root.getLiveVersion(miss.name),
    });
}
