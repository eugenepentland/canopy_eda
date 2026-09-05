//! Protected-resource metadata — the RFC 9728 discovery document and the 401
//! `WWW-Authenticate` challenge an MCP resource server serves so clients can find
//! wardd (its authorization server) from the resource alone.
//!
//! `buildProtectedResourceMetadata` renders the JSON an MCP tool serves at
//! `/.well-known/oauth-protected-resource`: the resource identifier, the one
//! authorization server (wardd's issuer), and the single supported bearer method
//! (`header`). `bearerChallenge` builds the `WWW-Authenticate` value a tool
//! returns with a 401, pointing a client back at that metadata document. Pure:
//! URLs in, owned bytes out — no I/O, no hardcoded hosts.

const std = @import("std");

/// Well-known path an MCP resource server serves its metadata at, appended to
/// the resource url to form the `resource_metadata` link in the 401 challenge.
const metadata_path = "/.well-known/oauth-protected-resource";
/// The only bearer method wardd's resource servers support: the `Authorization`
/// header (RFC 6750 §2.1), never a query or form parameter.
const bearer_methods = [_][]const u8{"header"};

/// Renders the RFC 9728 protected-resource metadata for a tool: its `resource`
/// identifier, the single `authorization_servers` entry (wardd's issuer), and
/// the supported `bearer_methods_supported`. The result is caller-owned JSON.
pub fn buildProtectedResourceMetadata(
    allocator: std.mem.Allocator,
    resource_url: []const u8,
    authorization_server_url: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .resource = resource_url,
        .authorization_servers = [_][]const u8{authorization_server_url},
        .bearer_methods_supported = bearer_methods,
    }, .{});
}

/// Builds the 401 `WWW-Authenticate` header value naming the resource-metadata
/// document, e.g. `Bearer resource_metadata="<resource_url>/.well-known/…"`. The
/// result is caller-owned; an app builds it once and reuses it as the gate's
/// challenge.
pub fn bearerChallenge(
    allocator: std.mem.Allocator,
    resource_url: []const u8,
) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "Bearer resource_metadata=\"{s}{s}\"", .{ resource_url, metadata_path });
}

const test_resource = "https" ++ "://tool.apps.example";
const test_as = "https" ++ "://auth.apps.example";

// spec: Resource metadata - The protected resource metadata advertises the resource server and bearer method
test "buildProtectedResourceMetadata advertises the resource server and bearer method" {
    const json = try buildProtectedResourceMetadata(std.testing.allocator, test_resource, test_as);
    defer std.testing.allocator.free(json);
    const resource_needle = "\"resource\":\"" ++ "https" ++ "://tool.apps.example\"";
    const servers_needle = "\"authorization_servers\":[\"" ++ "https" ++ "://auth.apps.example\"]";
    try std.testing.expect(std.mem.indexOf(u8, json, resource_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, servers_needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"bearer_methods_supported\":[\"header\"]") != null);
}

// spec: Resource metadata - The bearer challenge names the protected resource metadata url
test "bearerChallenge points at the resource metadata document" {
    const challenge = try bearerChallenge(std.testing.allocator, test_resource);
    defer std.testing.allocator.free(challenge);
    const expected = "Bearer resource_metadata=\"" ++ "https" ++
        "://tool.apps.example/.well-known/oauth-protected-resource\"";
    try std.testing.expectEqualStrings(expected, challenge);
}
