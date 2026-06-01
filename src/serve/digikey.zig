//! DigiKey Product Information API v4 client — resolves a fuzzy query (a vague
//! description or a partial/orderable part number) to real *manufacturer* part
//! numbers, each with a manufacturer datasheet URL, so the MPN can be handed to
//! Component Search Engine (`download_footprint` / `download_datasheet`) and the
//! datasheet URL used as a second source.
//!
//! Two HTTP steps, both over the system `curl` (same shell-out transport as
//! `component_search.zig`, so TLS/redirects live outside Zig):
//!   1. OAuth2 client-credentials → a short-lived bearer token.
//!   2. POST `…/products/v4/search/keyword` with the token → a `Products` array.
//!
//! Credentials (`DIGIKEY_CLIENT_ID` / `DIGIKEY_CLIENT_SECRET`) are read
//! server-side by the caller (via `config`) and never travel over MCP.
const std = @import("std");
const json_writer = @import("../json_writer.zig");

// ── Endpoints / tunables ──────────────────────────────────────────
/// Production host. A deployment can point at the sandbox by setting
/// `DIGIKEY_API_BASE=https://sandbox-api.digikey.com`.
pub const default_base = "https://api.digikey.com";
const TOKEN_PATH = "/v1/oauth2/token";
const KEYWORD_PATH = "/products/v4/search/keyword";
const TOKEN_TIMEOUT_SECS = "20";
const SEARCH_TIMEOUT_SECS = "30";
const MAX_BYTES: usize = 4 * 1024 * 1024;

/// One resolved catalog match. All slices are owned by the allocator passed to
/// `resolveMpn` (a request arena on the MCP path). `datasheet_url`,
/// `product_url`, and `digikey_part_number` are null when DigiKey omits them or
/// returns them empty.
pub const Product = struct {
    mpn: []const u8,
    manufacturer: []const u8,
    description: []const u8,
    datasheet_url: ?[]const u8,
    product_url: ?[]const u8,
    digikey_part_number: ?[]const u8,
};

pub const SearchError = error{
    TokenFailed,
    SearchFailed,
} || std.mem.Allocator.Error;

/// Stable, user-facing message for a `SearchError`, for the MCP envelope.
pub fn searchErrorMessage(err: SearchError) []const u8 {
    return switch (err) {
        error.TokenFailed => "DigiKey OAuth token request failed — check DIGIKEY_CLIENT_ID / DIGIKEY_CLIENT_SECRET (or network)",
        error.SearchFailed => "DigiKey keyword search failed — token rejected, network error, or unexpected response",
        error.OutOfMemory => "out of memory",
    };
}

/// Full pipeline: fetch an OAuth token (once), then run the keyword search,
/// relaxing the query when it comes up empty. DigiKey's KeywordSearch is a
/// keyword AND-match, so a long parametric query ("buck converter 2A 12V input")
/// can over-constrain to zero hits; `keywordVariants` drops trailing keywords
/// one at a time ("buck converter 2A 12V" → … → "buck") and the first variant
/// with results wins. Mirrors the part-number relaxation `component_search`
/// does for CSE. An empty slice means every variant matched nothing;
/// `error.SearchFailed` means no search request succeeded (e.g. a rejected
/// token); `error.TokenFailed` means the OAuth grant failed.
pub fn resolveMpn(
    allocator: std.mem.Allocator,
    base: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    query: []const u8,
    limit: usize,
) SearchError![]Product {
    const token = fetchToken(allocator, base, client_id, client_secret) orelse return error.TokenFailed;

    var any_ok = false;
    for (try keywordVariants(allocator, query)) |term| {
        const body = keywordSearch(allocator, base, client_id, token, term, limit) orelse continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch continue;
        defer parsed.deinit();
        const items = productsArray(parsed.value) orelse continue;
        any_ok = true;
        if (items.len == 0) continue;
        return try mapProducts(allocator, items, limit);
    }
    if (!any_ok) return error.SearchFailed;
    return &.{};
}

/// Ordered, relaxed search terms: the full query first, then each prefix with
/// one more trailing whitespace-delimited keyword dropped, down to the first
/// keyword alone. Internal whitespace is normalised to single spaces. A blank
/// query yields a single empty term (the server then matches nothing). Caller
/// owns the slice and every joined term.
fn keywordVariants(allocator: std.mem.Allocator, query: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var toks: std.ArrayListUnmanaged([]const u8) = .empty;
    defer toks.deinit(allocator); // token slices point into `query`; only the list buffer is owned
    var it = std.mem.tokenizeAny(u8, query, " \t\r\n");
    while (it.next()) |t| try toks.append(allocator, t);

    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    if (toks.items.len == 0) {
        try out.append(allocator, try allocator.dupe(u8, query));
        return out.toOwnedSlice(allocator);
    }
    var k = toks.items.len;
    while (k >= 1) : (k -= 1) {
        try out.append(allocator, try std.mem.join(allocator, " ", toks.items[0..k]));
    }
    return out.toOwnedSlice(allocator);
}

// ── OAuth2 (client-credentials) ───────────────────────────────────

/// POST the client-credentials grant and return the bearer token, or null on a
/// transport failure or a response without an `access_token` (bad credentials).
fn fetchToken(allocator: std.mem.Allocator, base: []const u8, client_id: []const u8, client_secret: []const u8) ?[]const u8 {
    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, TOKEN_PATH }) catch return null;
    const id_arg = std.fmt.allocPrint(allocator, "client_id={s}", .{client_id}) catch return null;
    const secret_arg = std.fmt.allocPrint(allocator, "client_secret={s}", .{client_secret}) catch return null;
    const body = curl(allocator, &.{
        "-X",                            "POST",
        url,                             "-H",
        FORM_CT,                         FORM_FIELD,
        "grant_type=client_credentials", FORM_FIELD,
        id_arg,                          FORM_FIELD,
        secret_arg,
    }, TOKEN_TIMEOUT_SECS) orelse return null;
    return parseAccessToken(allocator, body);
}

const FORM_CT = "Content-Type: application/x-www-form-urlencoded";
const FORM_FIELD = "--data-urlencode";

/// Extract and dup the `access_token` string from an OAuth token response, or
/// null when the JSON is unparseable or carries no token (e.g. an error body).
fn parseAccessToken(allocator: std.mem.Allocator, body: []const u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const tok = strField(parsed.value, "access_token") orelse return null;
    return allocator.dupe(u8, tok) catch null;
}

// ── KeywordSearch ─────────────────────────────────────────────────

/// POST the keyword query with the bearer token + client-id headers; returns
/// the raw response body, or null on a transport failure.
fn keywordSearch(
    allocator: std.mem.Allocator,
    base: []const u8,
    client_id: []const u8,
    token: []const u8,
    query: []const u8,
    limit: usize,
) ?[]u8 {
    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, KEYWORD_PATH }) catch return null;
    const auth = std.fmt.allocPrint(allocator, "Authorization: Bearer {s}", .{token}) catch return null;
    const client = std.fmt.allocPrint(allocator, "X-DIGIKEY-Client-Id: {s}", .{client_id}) catch return null;

    var body: std.ArrayListUnmanaged(u8) = .empty;
    const bw = body.writer(allocator);
    bw.writeAll("{\"Keywords\":") catch return null;
    json_writer.writeString(bw, query) catch return null;
    bw.print(",\"Limit\":{d}}}", .{limit}) catch return null;

    return curl(allocator, &.{
        "-X",         "POST",
        url,          "-H",
        auth,         "-H",
        client,       "-H",
        JSON_ACCEPT,  "-H",
        JSON_CONTENT, "--data-binary",
        body.items,
    }, SEARCH_TIMEOUT_SECS);
}

const JSON_ACCEPT = "Accept: application/json";
const JSON_CONTENT = "Content-Type: application/json";

// ── Response mapping ──────────────────────────────────────────────

/// Resolve the `Products` array from a response root and map it to owned
/// `Product`s. A missing `Products` key (e.g. an auth-error body) is
/// `error.SearchFailed`; a present-but-empty array yields an empty slice.
fn collectProducts(allocator: std.mem.Allocator, root: std.json.Value, limit: usize) SearchError![]Product {
    const items = productsArray(root) orelse return error.SearchFailed;
    return mapProducts(allocator, items, limit);
}

/// Map a `Products` array to owned `Product`s, capped at `limit`. Entries
/// without a `ManufacturerProductNumber` are skipped.
fn mapProducts(allocator: std.mem.Allocator, items: []std.json.Value, limit: usize) std.mem.Allocator.Error![]Product {
    var list: std.ArrayListUnmanaged(Product) = .empty;
    for (items) |item| {
        if (list.items.len >= limit) break;
        const mpn = strField(item, "ManufacturerProductNumber") orelse continue;
        try list.append(allocator, .{
            .mpn = try allocator.dupe(u8, mpn),
            .manufacturer = try allocator.dupe(u8, nestedStr(item, "Manufacturer", "Name") orelse ""),
            .description = try allocator.dupe(u8, nestedStr(item, "Description", "ProductDescription") orelse ""),
            .datasheet_url = try dupeOpt(allocator, nonEmpty(strField(item, "DatasheetUrl"))),
            .product_url = try dupeOpt(allocator, nonEmpty(strField(item, "ProductUrl"))),
            .digikey_part_number = try dupeOpt(allocator, nonEmpty(firstVariationDk(item))),
        });
    }
    return list.toOwnedSlice(allocator);
}

/// The `Products` array of a response, or null when the shape is unexpected.
/// A present-but-empty array returns an empty slice (not null).
fn productsArray(root: std.json.Value) ?[]std.json.Value {
    if (root != .object) return null;
    const p = root.object.get("Products") orelse return null;
    if (p != .array) return null;
    return p.array.items;
}

/// `ProductVariations[0].DigiKeyProductNumber`, or null when absent.
fn firstVariationDk(product: std.json.Value) ?[]const u8 {
    if (product != .object) return null;
    const pv = product.object.get("ProductVariations") orelse return null;
    if (pv != .array or pv.array.items.len == 0) return null;
    return strField(pv.array.items[0], "DigiKeyProductNumber");
}

/// `obj[outer][inner]` as a string, or null at any missing/typed-wrong hop.
fn nestedStr(v: std.json.Value, outer: []const u8, inner: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const sub = v.object.get(outer) orelse return null;
    return strField(sub, inner);
}

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

/// Collapse an empty string to null — DigiKey returns `""` for absent URLs.
fn nonEmpty(s: ?[]const u8) ?[]const u8 {
    const v = s orelse return null;
    return if (v.len == 0) null else v;
}

fn dupeOpt(allocator: std.mem.Allocator, s: ?[]const u8) std.mem.Allocator.Error!?[]const u8 {
    const v = s orelse return null;
    return try allocator.dupe(u8, v);
}

// ── curl transport ────────────────────────────────────────────────

/// Run `curl -sS --max-time <t> <extra…>`, returning the response body or null
/// on a spawn failure or non-zero exit. The body is returned regardless of HTTP
/// status (no `-f`), so the JSON parsers can distinguish error bodies.
fn curl(allocator: std.mem.Allocator, extra: []const []const u8, timeout_secs: []const u8) ?[]u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.appendSlice(allocator, &.{ "curl", "-sS", "--max-time", timeout_secs }) catch return null;
    argv.appendSlice(allocator, extra) catch return null;

    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = MAX_BYTES,
    }) catch return null;
    if (res.term != .Exited or res.term.Exited != 0) return null;
    return res.stdout;
}

// ── Tests ─────────────────────────────────────────────────────────

test "parseAccessToken extracts the bearer token from the OAuth response" {
    // spec: serve/digikey - parseAccessToken extracts the bearer token from the OAuth response
    const a = std.testing.allocator;
    const tok = parseAccessToken(a, "{\"access_token\":\"abc123\",\"token_type\":\"Bearer\",\"expires_in\":599}").?;
    defer a.free(tok);
    try std.testing.expectEqualStrings("abc123", tok);
    try std.testing.expect(parseAccessToken(a, "{\"error\":\"invalid_client\"}") == null);
    try std.testing.expect(parseAccessToken(a, "not json") == null);
}

test "keywordVariants drops trailing keywords for graceful relaxation" {
    // spec: serve/digikey - keywordVariants drops trailing keywords for graceful relaxation
    const a = std.testing.allocator;
    const v = try keywordVariants(a, "buck converter 2A 12V input");
    defer freeVariants(a, v);
    try std.testing.expectEqual(@as(usize, 5), v.len);
    try std.testing.expectEqualStrings("buck converter 2A 12V input", v[0]);
    try std.testing.expectEqualStrings("buck converter 2A 12V", v[1]);
    try std.testing.expectEqualStrings("buck converter 2A", v[2]);
    try std.testing.expectEqualStrings("buck converter", v[3]);
    try std.testing.expectEqualStrings("buck", v[4]);

    // A single keyword has nothing to relax; extra whitespace is normalised.
    const one = try keywordVariants(a, "  INA228  ");
    defer freeVariants(a, one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("INA228", one[0]);
}

test "collectProducts maps the Products array to resolved parts" {
    // spec: serve/digikey - collectProducts maps the Products array to resolved parts
    const a = std.testing.allocator;
    const json =
        \\{"Products":[
        \\ {"ManufacturerProductNumber":"INA228AIDGSR",
        \\  "Manufacturer":{"Name":"Texas Instruments"},
        \\  "Description":{"ProductDescription":"IC CURRENT/POWER MONITOR"},
        \\  "DatasheetUrl":"https://ti.com/ina228.pdf",
        \\  "ProductUrl":"https://digikey.com/p/ina228",
        \\  "ProductVariations":[{"DigiKeyProductNumber":"296-INA228-ND"}]},
        \\ {"ManufacturerProductNumber":"BARE","DatasheetUrl":"",
        \\  "Manufacturer":{"Name":"Acme"}},
        \\ {"Description":{"ProductDescription":"no mpn, skipped"}}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();

    const ps = try collectProducts(a, parsed.value, 10);
    defer freeProducts(a, ps);
    try std.testing.expectEqual(@as(usize, 2), ps.len);
    try std.testing.expectEqualStrings("INA228AIDGSR", ps[0].mpn);
    try std.testing.expectEqualStrings("Texas Instruments", ps[0].manufacturer);
    try std.testing.expectEqualStrings("IC CURRENT/POWER MONITOR", ps[0].description);
    try std.testing.expectEqualStrings("https://ti.com/ina228.pdf", ps[0].datasheet_url.?);
    try std.testing.expectEqualStrings("296-INA228-ND", ps[0].digikey_part_number.?);
    // Empty DatasheetUrl collapses to null; a missing variation list → null DK part.
    try std.testing.expect(ps[1].datasheet_url == null);
    try std.testing.expect(ps[1].digikey_part_number == null);

    // A missing Products key is an error; a present-but-empty array is empty.
    var err_body = try std.json.parseFromSlice(std.json.Value, a, "{\"errors\":[]}", .{});
    defer err_body.deinit();
    try std.testing.expectError(error.SearchFailed, collectProducts(a, err_body.value, 10));

    var empty = try std.json.parseFromSlice(std.json.Value, a, "{\"Products\":[]}", .{});
    defer empty.deinit();
    const none = try collectProducts(a, empty.value, 10);
    defer a.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

/// Test-only: free the joined terms + backing slice of a variant list.
fn freeVariants(a: std.mem.Allocator, variants: []const []const u8) void {
    for (variants) |v| a.free(v);
    a.free(variants);
}

/// Test-only: free the owned strings + backing slice of a `Product` list.
fn freeProducts(a: std.mem.Allocator, products: []Product) void {
    for (products) |p| {
        a.free(p.mpn);
        a.free(p.manufacturer);
        a.free(p.description);
        if (p.datasheet_url) |x| a.free(x);
        if (p.product_url) |x| a.free(x);
        if (p.digikey_part_number) |x| a.free(x);
    }
    a.free(products);
}
