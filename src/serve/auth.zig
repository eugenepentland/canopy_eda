//! Local-first auth for the serve layer — the single seam every request passes
//! through before dispatch.
//!
//! netlisp is a local tool. `serve` binds `127.0.0.1` by default and treats a
//! request whose *TCP peer* is loopback, and which no reverse proxy relayed, as
//! an admin. Nothing else is admitted except a plugin bearer token on the KiCad
//! sync route. Everything else is refused with `403` and told about
//! `--allow-remote`, the deployment switch that hands authentication to an
//! operator-run reverse proxy in front of netlisp.
//!
//! Optional `NETLISP_AUTH=ward` verifies hosted sessions through Ward before
//! any local or allow-remote bypass. Local mode needs no external auth service.
//! In local mode,
//! locality is derived from the connected socket, never from a request header,
//! because a header is fully attacker-controlled (`Host: localhost` once bought
//! unauthenticated admin here).

const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// Error set the middleware surfaces to the dispatcher — only allocation
/// failure escapes; every auth decision is written into the response and
/// reported as a bool return.
pub const HandlerError = std.mem.Allocator.Error;

// ── Constants ────────────────────────────────────────────────────────

const http_forbidden: u16 = 403;

const sync_path_prefix = "/api/sync-kicad-pcb/";

/// Identity recorded for a loopback request (the normal single-user case).
const local_identity = "local";
/// Identity recorded when `--allow-remote` delegates authentication to the
/// operator's reverse proxy: netlisp itself knows nothing about the caller.
/// Both spellings are bare names, because the auto-commit author line
/// synthesizes an email from them (`<name> <name@netlisp>`).
const remote_identity = "remote";

const body_forbidden_json =
    "{\"error\":\"forbidden\",\"error_description\":\"netlisp serves loopback requests only; " ++
    "start it with --allow-remote when an authenticating reverse proxy sits in front of it\"}";
const body_forbidden_text =
    "403 Forbidden\n\nnetlisp serves loopback requests only.\n" ++
    "Run it with --allow-remote (or NETLISP_ALLOW_REMOTE=1) when an authenticating\n" ++
    "reverse proxy sits in front of it and is responsible for the auth.\n";

/// Routes served without any credential: the static assets a page pulls and the
/// deployment health probe. Both are non-sensitive and both must answer before
/// a locality decision so a probe or an asset fetch is never the thing that
/// breaks a proxied deployment.
const public_prefixes = [_][]const u8{"/static"};
const public_exact = [_][]const u8{"/healthz"};

// ── Types ────────────────────────────────────────────────────────────

/// Permission tier the serve layer gates writes and admin surfaces on. A
/// loopback (or `--allow-remote`) request is `admin`; the plugin-token sync
/// path keeps the request at the default `reader` exactly as it always has,
/// because that token authorizes one route rather than an identity.
pub const Role = enum {
    admin,
    writer,
    reader,

    /// The lowercase wire/display name of the role.
    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .admin => "admin",
            .writer => "writer",
            .reader => "reader",
        };
    }

    /// Can this role mutate designs via HTTP edit endpoints?
    pub fn canWrite(self: Role) bool {
        return self == .admin or self == .writer;
    }
};

// ── Locality ─────────────────────────────────────────────────────────

/// True when the request's *actual TCP peer* is a loopback address
/// (127.0.0.0/8 or ::1). Reads `req.address` (the connected socket), NEVER a
/// request header — a header is fully attacker-controlled.
fn peerIsLoopback(req: *httpz.Request) bool {
    return switch (req.address) {
        .ip4 => |a| a.bytes[0] == 127,
        .ip6 => |ip6| blk: {
            const a = ip6.bytes;
            // ::1
            var all_zero_hi = true;
            for (a[0..15]) |b| {
                if (b != 0) {
                    all_zero_hi = false;
                    break;
                }
            }
            break :blk all_zero_hi and a[15] == 1;
        },
    };
}

/// True when the request was relayed by a reverse proxy (carries a
/// `Forwarded`/`X-Forwarded-*`/`X-Real-IP` header). A proxy on the same host
/// relays internet traffic over loopback, so such a request must NOT be treated
/// as local however loopback its peer looks.
fn viaProxy(req: *httpz.Request) bool {
    return req.header("x-forwarded-for") != null or
        req.header("x-forwarded-host") != null or
        req.header("x-forwarded-proto") != null or
        req.header("x-forwarded-port") != null or
        req.header("x-real-ip") != null or
        req.header("forwarded") != null;
}

/// Whether this request earns the local admin identity: a genuinely loopback
/// TCP peer that no reverse proxy relayed.
fn isLocalRequest(req: *httpz.Request) bool {
    if (viaProxy(req)) return false;
    return peerIsLoopback(req);
}

/// Whether `path` is served without any credential (see `public_prefixes` /
/// `public_exact`). A prefix entry matches the path itself and its subtree, so
/// `/static` and `/static/app.css` are public while `/statics` is not.
fn isPublicPath(path: []const u8) bool {
    for (public_exact) |p| {
        if (std.mem.eql(u8, path, p)) return true;
    }
    for (public_prefixes) |p| {
        if (!std.mem.startsWith(u8, path, p)) continue;
        if (path.len == p.len or path[p.len] == '/') return true;
    }
    return false;
}

/// Whether `path` targets a JSON API route (its refusal is JSON, not text).
fn isApiPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/");
}

// ── Bearer helpers ───────────────────────────────────────────────────

fn getBearerToken(req: *httpz.Request) ?[]const u8 {
    const h = req.header("authorization") orelse return null;
    const prefix = "Bearer ";
    if (h.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(h[0..prefix.len], prefix)) return null;
    return std.mem.trim(u8, h[prefix.len..], " ");
}

/// True when the `Authorization: Bearer …` header matches a plugin-issued
/// token from `plugin_tokens`. These are NOT read-only credentials: the one
/// route that consults them is `POST /api/sync-kicad-pcb/:name`, which rewrites
/// the KiCad board file in place, and a match admits it outright — without any
/// role check. That is the token's whole purpose (the KiCad sync helper is a
/// machine, not a person at a loopback browser), so treat an `netlisp_p_*`
/// token as board-write capability that never expires; revocation means
/// removing its hash from `plugin_tokens.json`.
fn validatePluginBearerToken(ctx: *Server, req: *httpz.Request) bool {
    const raw = getBearerToken(req) orelse return false;
    return ctx.state.plugin_tokens.validate(ctx.allocator, ctx.auth_dir, raw);
}

// ── Middleware ───────────────────────────────────────────────────────

/// Gate every incoming request. Returns `true` to continue dispatch, `false`
/// when a `403` has already been written.
///
/// Order matters: the public routes answer first (a health probe must not
/// depend on the locality decision), then `--allow-remote` (the operator has
/// declared their proxy owns auth), then the loopback admin, then the plugin
/// token on the sync route alone. Anything left is refused.
pub fn authMiddleware(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!bool {
    const path = req.url.path;
    if (isPublicPath(path)) return true;
    if (ctx.state.ward.enabled) {
        if (req.method == .POST and std.mem.startsWith(u8, path, sync_path_prefix) and validatePluginBearerToken(ctx, req)) return true;
        return @import("ward_auth.zig").authMiddleware(ctx, req, res);
    }
    if (ctx.allow_remote) return grant(ctx, remote_identity);
    if (isLocalRequest(req)) return grant(ctx, local_identity);
    if (std.mem.startsWith(u8, path, sync_path_prefix) and validatePluginBearerToken(ctx, req)) return true;
    return forbidden(res, path);
}

/// Record `username` as this request's admin identity and continue dispatch.
fn grant(ctx: *Server, username: []const u8) bool {
    ctx.request_auth.username = username;
    ctx.request_auth.role = .admin;
    return true;
}

/// Write the 403 refusal (JSON for an api route, plain text for a page) and
/// stop dispatch.
fn forbidden(res: *httpz.Response, path: []const u8) bool {
    res.status = http_forbidden;
    if (isApiPath(path)) {
        res.content_type = .JSON;
        res.body = body_forbidden_json;
    } else {
        res.content_type = .TEXT;
        res.body = body_forbidden_text;
    }
    return false;
}

// ── Tests ────────────────────────────────────────────────────────────

// spec: serve - Admin and writer may write while reader may not, and roles stringify lowercase
test "role write predicate and toString" {
    try std.testing.expect(Role.admin.canWrite());
    try std.testing.expect(Role.writer.canWrite());
    try std.testing.expect(!Role.reader.canWrite());
    try std.testing.expectEqualStrings("admin", Role.admin.toString());
    try std.testing.expectEqualStrings("writer", Role.writer.toString());
    try std.testing.expectEqualStrings("reader", Role.reader.toString());
}

// spec: serve - Every public route entry is served without a credential while a sibling sharing its leading text is not
test "the public route list admits exactly its own entries" {
    const rows = [_]struct { path: []const u8, public: bool }{
        // "/static" — the subtree every page pulls its assets from.
        .{ .path = "/static", .public = true },
        .{ .path = "/static/app.css", .public = true },
        .{ .path = "/static/pcb/board.js", .public = true },
        .{ .path = "/statics/app.css", .public = false },
        .{ .path = "/staticx", .public = false },
        // "/healthz" — the exact deployment probe, not a subtree.
        .{ .path = "/healthz", .public = true },
        .{ .path = "/healthz/x", .public = false },
        .{ .path = "/healthzz", .public = false },
        // Nothing else skips the locality gate.
        .{ .path = "/", .public = false },
        .{ .path = "/api/scene-graph/x", .public = false },
        .{ .path = "/api/sync-kicad-pcb/x", .public = false },
    };
    for (rows) |r| try std.testing.expectEqual(r.public, isPublicPath(r.path));
    // The rows enumerate BOTH lists by hand; an entry added without its own
    // rows here fails rather than landing unpinned.
    try std.testing.expectEqual(@as(usize, 1), public_prefixes.len);
    try std.testing.expectEqual(@as(usize, 1), public_exact.len);
}

// spec: serve - An api path is distinguished from a page path for the json-versus-text refusal
test "isApiPath distinguishes api routes" {
    try std.testing.expect(isApiPath("/api/version/x"));
    try std.testing.expect(isApiPath("/api/"));
    try std.testing.expect(!isApiPath("/apix"));
    try std.testing.expect(!isApiPath("/schematics/x"));
    try std.testing.expect(!isApiPath("/"));
}
