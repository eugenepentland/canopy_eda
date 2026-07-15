//! Server configuration: credentials, session secrets, and tunables read from
//! the real environment first, then a `.env` file in the working directory.
//! Centralised here (not in request handlers) so the `ban-env` policy holds —
//! values are fetched once and threaded down as plain parameters. Every getter
//! treats an empty value as unset.
const std = @import("std");
const infra_fs = @import("infra/fs.zig");

// Credentials and session secrets are read here (not in the request handlers)
// so the `ban-env` policy holds — values are fetched once and threaded down as
// plain parameters. Each getter checks the real environment first (so a
// deployment can always override) and falls back to a `.env` file in the
// working directory, letting the operator drop credentials in one place.

const dotenv_path = ".env";
const max_dotenv_bytes: usize = 64 * 1024;
const whitespace = " \t\r";

/// Component Search Engine account email for the model-download HTTP Basic
/// auth. From `CSE_EMAIL`.
pub fn cseEmail(allocator: std.mem.Allocator) ?[]u8 {
    return nonEmpty(lookup(allocator, "CSE_EMAIL"));
}

/// Component Search Engine account password for the model-download HTTP Basic
/// auth. From `CSE_PASSWORD`.
pub fn csePassword(allocator: std.mem.Allocator) ?[]u8 {
    return nonEmpty(lookup(allocator, "CSE_PASSWORD"));
}

/// Treat an empty value the same as unset (a bare `KEY=` in `.env`).
fn nonEmpty(v: ?[]u8) ?[]u8 {
    const s = v orelse return null;
    return if (s.len == 0) null else s;
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
    return std.fmt.parseInt(u64, std.mem.trim(u8, v, whitespace), 10) catch default;
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

/// Whether the server's per-mutation git auto-commit is enabled. On by default
/// (when `--project-dir` is a git repo); the operator disables it by setting
/// `NETLISP_GIT_AUTOCOMMIT=0` (env or `.env`). Any other value — including
/// unset — leaves it enabled. The env read lives here so the `ban-env` policy
/// holds; callers receive a plain bool.
pub fn gitAutocommitEnabled(allocator: std.mem.Allocator) bool {
    const v = lookup(allocator, "NETLISP_GIT_AUTOCOMMIT") orelse return true;
    defer allocator.free(v);
    return gitAutocommitEnabledFromRaw(v);
}

/// Map a raw `NETLISP_GIT_AUTOCOMMIT` value onto the enabled bool: only a bare
/// `0` disables; every other value (and, via the caller, unset) is enabled. A
/// pure helper so the gate is testable without touching the process environment.
fn gitAutocommitEnabledFromRaw(raw: []const u8) bool {
    return !std.mem.eql(u8, std.mem.trim(u8, raw, whitespace), "0");
}

/// Ward verify endpoint (`WARD_VERIFY_URL`, e.g. http://127.0.0.1:9000/verify)
/// the session middleware asks about each `ward_session` cookie. Null when
/// unset — the serve layer then fails every session-gated request closed.
pub fn wardVerifyUrl(allocator: std.mem.Allocator) ?[]u8 {
    return lookup(allocator, "WARD_VERIFY_URL");
}

/// Ward login page (`WARD_LOGIN_URL`) an unauthenticated session is redirected
/// to; wardd appends its own `?rd=` return target. Null when unset.
pub fn wardLoginUrl(allocator: std.mem.Allocator) ?[]u8 {
    return lookup(allocator, "WARD_LOGIN_URL");
}

/// Ward token-introspection endpoint (`WARD_INTROSPECT_URL`) the MCP bearer
/// path POSTs `token=…` to. Null when unset — the bearer path then fails
/// closed rather than admit an unverifiable token.
pub fn wardIntrospectUrl(allocator: std.mem.Allocator) ?[]u8 {
    return lookup(allocator, "WARD_INTROSPECT_URL");
}

/// This service's ward name/scope (`WARD_SERVICE_NAME`), sent as the
/// `X-Ward-Service` header and matched against a bearer token's scope. Null
/// when unset — the caller substitutes its own default.
pub fn wardServiceName(allocator: std.mem.Allocator) ?[]u8 {
    return lookup(allocator, "WARD_SERVICE_NAME");
}

/// Optional explicit ward authorization-server base URL (`WARD_AUTH_SERVER_URL`)
/// published in the RFC 9728 protected-resource metadata document. Null when
/// unset — the serve layer then derives it by stripping the `/login` suffix off
/// `WARD_LOGIN_URL` (correct whenever the login URL ends in `/login`).
pub fn wardAuthServerUrl(allocator: std.mem.Allocator) ?[]u8 {
    return lookup(allocator, "WARD_AUTH_SERVER_URL");
}

/// Ward verdict-cache lifetime in seconds (`WARD_CACHE_TTL_SECS`), bounding
/// how long a logout/revocation lags. Falls back to `default` when unset or
/// non-numeric.
pub fn wardCacheTtlSecs(allocator: std.mem.Allocator, default: i64) i64 {
    return wardCacheTtlFromRaw(lookupU64(allocator, "WARD_CACHE_TTL_SECS", 0), default);
}

/// Map a raw parsed TTL onto i64: an unset/zero value and any value that would
/// overflow i64 both fall back to `default`. A checked cast (not `@intCast`)
/// keeps a hostile `WARD_CACHE_TTL_SECS` in (i64_max, u64_max] from panicking
/// the server on boot under ReleaseSafe.
fn wardCacheTtlFromRaw(raw: u64, default: i64) i64 {
    if (raw == 0) return default;
    return std.math.cast(i64, raw) orelse default;
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
    const data = infra_fs.cwd().readFileAlloc(allocator, dotenv_path, max_dotenv_bytes) catch return null;
    defer allocator.free(data);

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, whitespace);
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trim(u8, line["export ".len..], whitespace);
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], whitespace), key)) continue;
        const value = stripQuotes(std.mem.trim(u8, line[eq + 1 ..], whitespace));
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

test "gitAutocommitEnabledFromRaw disables only on a bare zero" {
    // spec: config - The git auto-commit env gate disables only on a bare 0 and is enabled otherwise
    // A bare 0 (with surrounding whitespace tolerated) disables auto-commit.
    try std.testing.expect(!gitAutocommitEnabledFromRaw("0"));
    try std.testing.expect(!gitAutocommitEnabledFromRaw(" 0 "));
    // Every other value keeps it enabled: the affirmative 1, a word, and the
    // empty string (a bare `NETLISP_GIT_AUTOCOMMIT=` in `.env`).
    try std.testing.expect(gitAutocommitEnabledFromRaw("1"));
    try std.testing.expect(gitAutocommitEnabledFromRaw("true"));
    try std.testing.expect(gitAutocommitEnabledFromRaw(""));
    // A lookalike ("00") is not the disable sentinel.
    try std.testing.expect(gitAutocommitEnabledFromRaw("00"));
}

test "wardCacheTtlFromRaw guards the i64 cast" {
    // spec: config - The ward cache ttl maps a zero or out-of-range value to the default and keeps valid values
    const default: i64 = 30;
    // Unset/zero → default (preserves the raw==0 fallback).
    try std.testing.expectEqual(default, wardCacheTtlFromRaw(0, default));
    // A normal value passes through.
    try std.testing.expectEqual(@as(i64, 45), wardCacheTtlFromRaw(45, default));
    // The i64 boundary passes through; one past it and the u64 max both fall
    // back to default instead of panicking on the cast (the boot-safety fix).
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), wardCacheTtlFromRaw(std.math.maxInt(i64), default));
    try std.testing.expectEqual(default, wardCacheTtlFromRaw(@as(u64, std.math.maxInt(i64)) + 1, default));
    try std.testing.expectEqual(default, wardCacheTtlFromRaw(std.math.maxInt(u64), default));
}
