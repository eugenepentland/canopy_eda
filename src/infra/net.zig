//! Network adapter seam — the single serve-layer module permitted to name
//! `std.http` (see the `src/infra/net*` carve-out for the ban-net gate). It
//! owns the HTTP client type the ward auth adapter borrows to reach the wardd
//! server; every other module injects `HttpClient` from here instead of
//! touching `std.http` directly, so the network boundary stays in one place.

const std = @import("std");

/// HTTP client the ward verifiers borrow to call wardd's verify and token
/// introspection endpoints. Aliased here so consumers never name `std.http`.
pub const HttpClient = std.http.Client;

/// Build an HTTP client bound to `allocator` (process-lifetime in practice, so
/// the connection pool survives across requests). The caller owns it.
pub fn initHttpClient(allocator: std.mem.Allocator) HttpClient {
    return .{ .allocator = allocator };
}
