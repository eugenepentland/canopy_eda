//! Thin auth facade for the serve layer. The homegrown passkey/WebAuthn,
//! cookie-session, invite, and OAuth-authorization-server code was removed in
//! the ward migration (Phase 2 demolition) — netlisp is now a pure resource
//! server that verifies sessions and OAuth bearers against wardd via
//! `ward_auth`. What survives here is the request-dispatch entry point that
//! delegates to that adapter, the local-dev bypass (deliberately derived from
//! the TCP peer, never a header), and the plugin-token bearer check for the
//! KiCad sync path.

const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const ward_auth = @import("ward_auth.zig");

/// Error set for the auth middleware entry point. Only allocation failure
/// escapes — every auth decision is written into the response by the ward
/// adapter and reported as a bool return.
pub const HandlerError = std.mem.Allocator.Error;

// ── Local-dev bypass ─────────────────────────────────────────────────

/// True when the request's *actual TCP peer* is a loopback address
/// (127.0.0.0/8 or ::1). Reads `req.address` (the connected socket), NEVER a
/// request header — a header is fully attacker-controlled.
fn peerIsLoopback(req: *httpz.Request) bool {
    return switch (req.address.any.family) {
        std.posix.AF.INET => (std.mem.bigToNative(u32, req.address.in.sa.addr) >> 24) == 127,
        std.posix.AF.INET6 => blk: {
            const a = req.address.in6.sa.addr;
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
        else => false,
    };
}

/// True when the request was relayed by a reverse proxy (carries a
/// `Forwarded`/`X-Forwarded-*`/`X-Real-IP` header). The prod server sits behind
/// a same-host proxy, so such requests reach us over loopback even though they
/// originated on the internet — they must NOT be treated as local.
fn viaProxy(req: *httpz.Request) bool {
    return req.header("x-forwarded-for") != null or
        req.header("x-forwarded-host") != null or
        req.header("x-real-ip") != null or
        req.header("forwarded") != null;
}

/// The local-development auth bypass. Requires ALL of: the operator opted in
/// (`ctx.dev_mode`, from the `NETLISP_DEV` env var), the TCP peer is genuinely
/// loopback, and the request did not come through a reverse proxy. Deriving
/// "local" from the `Host` header — the previous behaviour — let any remote
/// client send `Host: localhost` and obtain unauthenticated admin.
pub fn isLocalhostRequest(ctx: *Server, req: *httpz.Request) bool {
    if (!ctx.dev_mode) return false;
    if (viaProxy(req)) return false;
    return peerIsLoopback(req);
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
/// token from `plugin_tokens`. Plugin tokens are scoped to read-only
/// schematic/PCB consumers (the KiCad sync helper) and never expire.
pub fn validatePluginBearerToken(ctx: *Server, req: *httpz.Request) bool {
    const raw = getBearerToken(req) orelse return false;
    return ctx.state.plugin_tokens.validate(ctx.allocator, ctx.auth_dir, raw);
}

// ── Middleware ───────────────────────────────────────────────────────

/// Gate every incoming request. Delegates to the ward auth adapter
/// (`ward_auth.authMiddleware`), which verifies the `ward_session` cookie and
/// OAuth bearer tokens against wardd; the local-dev bypass and the plugin-token
/// sync path are preserved there. Returns `true` to continue dispatch, `false`
/// when the middleware has already written the response.
pub fn authMiddleware(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!bool {
    return ward_auth.authMiddleware(ctx, req, res);
}
