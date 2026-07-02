const std = @import("std");
const infra_fs = @import("infra/fs.zig");

// Credentials and session secrets are read here (not in the request handlers)
// so the `ban-env` policy holds — values are fetched once and threaded down as
// plain parameters. Each getter checks the real environment first (so a
// deployment can always override) and falls back to a `.env` file in the
// working directory, letting the operator drop credentials in one place.

const DOTENV_PATH = ".env";
const MAX_DOTENV_BYTES: usize = 64 * 1024;
const WHITESPACE = " \t\r";

/// Component Search Engine session cookie (`connect.sid` value) for
/// `download_footprint`. From `CSE_CONNECT_SID`.
pub fn cseConnectSid(allocator: std.mem.Allocator) ?[]u8 {
    return lookup(allocator, "CSE_CONNECT_SID");
}

/// DigiKey Product Information API OAuth2 client id, for `resolve_mpn`.
/// From `DIGIKEY_CLIENT_ID`.
pub fn digikeyClientId(allocator: std.mem.Allocator) ?[]u8 {
    return lookup(allocator, "DIGIKEY_CLIENT_ID");
}

/// DigiKey OAuth2 client secret, for `resolve_mpn`. From `DIGIKEY_CLIENT_SECRET`.
pub fn digikeyClientSecret(allocator: std.mem.Allocator) ?[]u8 {
    return lookup(allocator, "DIGIKEY_CLIENT_SECRET");
}

/// Optional DigiKey API base-URL override (e.g. the sandbox host) for
/// `resolve_mpn`. From `DIGIKEY_API_BASE`; null falls back to the production host.
pub fn digikeyApiBase(allocator: std.mem.Allocator) ?[]u8 {
    return lookup(allocator, "DIGIKEY_API_BASE");
}

/// Minimum interval (ms) between Component Search Engine API calls — the rate
/// limiter spaces call starts at least this far apart. From `CSE_MIN_INTERVAL_MS`.
pub fn cseMinIntervalMs(allocator: std.mem.Allocator) u64 {
    return lookupU64(allocator, "CSE_MIN_INTERVAL_MS", 200);
}

/// Max concurrent CSE API calls allowed in flight. From `CSE_MAX_IN_FLIGHT`.
pub fn cseMaxInFlight(allocator: std.mem.Allocator) u32 {
    return @intCast(lookupU64(allocator, "CSE_MAX_IN_FLIGHT", 2));
}

/// Minimum interval (ms) between DigiKey API calls. From `DIGIKEY_MIN_INTERVAL_MS`.
pub fn digikeyMinIntervalMs(allocator: std.mem.Allocator) u64 {
    return lookupU64(allocator, "DIGIKEY_MIN_INTERVAL_MS", 250);
}

/// Max concurrent DigiKey API calls allowed in flight. From `DIGIKEY_MAX_IN_FLIGHT`.
pub fn digikeyMaxInFlight(allocator: std.mem.Allocator) u32 {
    return @intCast(lookupU64(allocator, "DIGIKEY_MAX_IN_FLIGHT", 2));
}

/// Resolve `key` as a u64, falling back to `default` when unset or unparseable.
fn lookupU64(allocator: std.mem.Allocator, key: []const u8, default: u64) u64 {
    const v = lookup(allocator, key) orelse return default;
    defer allocator.free(v);
    return std.fmt.parseInt(u64, std.mem.trim(u8, v, WHITESPACE), 10) catch default;
}

/// True when `NETLISP_DEV` is set (env or `.env`) to a non-empty value. Gates
/// the serve layer's local-development auth bypass. The env read lives here so
/// the `ban-env` policy holds (config.zig is the one module that touches the
/// environment; callers receive a plain bool).
pub fn devMode(allocator: std.mem.Allocator) bool {
    const v = lookup(allocator, "NETLISP_DEV") orelse return false;
    allocator.free(v);
    return true;
}

/// Resolve `key` from the real environment first, then from `.env`. Returns
/// null when unset or empty. Caller owns the slice.
fn lookup(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    if (std.process.getEnvVarOwned(allocator, key)) |v| {
        if (v.len > 0) return v;
        allocator.free(v);
    } else |_| {}
    return dotenvValue(allocator, key);
}

/// Parse `.env` in the working directory for `KEY=VALUE` (allowing a leading
/// `export ` and surrounding quotes) and return a dup of VALUE, or null. The
/// file is re-read per call — config reads are rare and this avoids a global.
fn dotenvValue(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    const data = infra_fs.cwd().readFileAlloc(allocator, DOTENV_PATH, MAX_DOTENV_BYTES) catch return null;
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, WHITESPACE);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trim(u8, line["export ".len..], WHITESPACE);
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], WHITESPACE), key)) continue;
        const value = stripQuotes(std.mem.trim(u8, line[eq + 1 ..], WHITESPACE));
        if (value.len == 0) return null;
        return allocator.dupe(u8, value) catch null;
    }
    return null;
}

/// Strip one layer of matching surrounding single or double quotes.
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) {
        return s[1 .. s.len - 1];
    }
    return s;
}

// ── Tests ─────────────────────────────────────────────────────────

test "stripQuotes removes matching quotes only" {
    // spec: config - stripQuotes removes one layer of matching quotes
    try std.testing.expectEqualStrings("abc", stripQuotes("\"abc\""));
    try std.testing.expectEqualStrings("abc", stripQuotes("'abc'"));
    try std.testing.expectEqualStrings("a\"b", stripQuotes("a\"b"));
    try std.testing.expectEqualStrings("\"abc'", stripQuotes("\"abc'"));
}
