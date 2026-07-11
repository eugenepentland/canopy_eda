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
const rate_limiter = @import("rate_limiter.zig");
const numeric = @import("../numeric.zig");

// ── Endpoints / tunables ──────────────────────────────────────────
/// Production host. A deployment can point at the sandbox by setting
/// `DIGIKEY_API_BASE=https://sandbox-api.digikey.com`.
pub const default_base = "https://api.digikey.com";
const TOKEN_PATH = "/v1/oauth2/token";
const KEYWORD_PATH = "/products/v4/search/keyword";
const TOKEN_TIMEOUT_SECS = "20";
const SEARCH_TIMEOUT_SECS = "30";
const DOWNLOAD_TIMEOUT_SECS = "60";
/// JSON responses are small; datasheet PDFs are not.
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const MAX_DOWNLOAD_BYTES: usize = 64 * 1024 * 1024;
const BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " ++
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36";

/// One quantity price break from a variation's `StandardPricing` ladder —
/// "at `break_quantity` units, each costs `unit_price` (`total_price` for the
/// break)". Prices are in the catalog currency DigiKey returns for the locale.
pub const PriceBreak = struct {
    break_quantity: u64,
    unit_price: f64,
    total_price: f64,
};

/// One orderable packaging option of a product (Cut Tape, Tape & Reel, Tube …)
/// with its own live stock, minimum order quantity, and price-break ladder.
/// All slices are owned by the allocator passed to `resolveMpn`.
pub const Variation = struct {
    digikey_part_number: ?[]const u8,
    package_type: ?[]const u8,
    /// Live stock for this packaging (DigiKey `QuantityAvailableforPackageType`).
    quantity_available: u64,
    minimum_order_quantity: u64,
    price_breaks: []const PriceBreak,
};

/// One resolved catalog match. All slices are owned by the allocator passed to
/// `resolveMpn` (a request arena on the MCP path). `datasheet_url`,
/// `product_url`, `digikey_part_number`, `unit_price`, and `product_status` are
/// null when DigiKey omits them or returns them empty.
pub const Product = struct {
    mpn: []const u8,
    manufacturer: []const u8,
    description: []const u8,
    datasheet_url: ?[]const u8,
    product_url: ?[]const u8,
    digikey_part_number: ?[]const u8,
    /// Total live stock across every packaging variation (DigiKey
    /// `QuantityAvailable`); 0 when out of stock or absent.
    quantity_available: u64,
    /// Single-unit catalog price for the default packaging, or null when absent.
    unit_price: ?f64,
    /// Lifecycle status ("Active", "Obsolete", "Last Time Buy", …), or null.
    product_status: ?[]const u8,
    /// Per-packaging stock + price ladder; empty when DigiKey returns none.
    variations: []const Variation,
};

pub const SearchError = error{
    TokenFailed,
    SearchFailed,
} || std.mem.Allocator.Error;

/// A datasheet PDF fetched via DigiKey. `pdf_bytes` and the strings are owned by
/// the allocator. `source_url` is the URL actually downloaded (after unwrapping
/// any manufacturer interstitial), for traceability.
pub const DatasheetResult = struct {
    pdf_bytes: []const u8,
    mpn: []const u8,
    manufacturer: []const u8,
    source_url: []const u8,
};

pub const DatasheetError = error{
    TokenFailed,
    NotFound,
    NoDatasheet,
    DownloadFailed,
    NotPdf,
} || std.mem.Allocator.Error;

/// Stable, user-facing message for a `DatasheetError`.
pub fn datasheetErrorMessage(err: DatasheetError) []const u8 {
    return switch (err) {
        error.TokenFailed => "DigiKey OAuth token request failed (check DIGIKEY_CLIENT_ID / DIGIKEY_CLIENT_SECRET)",
        error.NotFound => "DigiKey found no part matching this number",
        error.NoDatasheet => "DigiKey has no datasheet URL on file for this part",
        error.DownloadFailed => "datasheet download request failed (network error)",
        error.NotPdf => "the DigiKey datasheet URL did not resolve to a PDF",
        error.OutOfMemory => "out of memory",
    };
}

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
    }, TOKEN_TIMEOUT_SECS, MAX_RESPONSE_BYTES) orelse return null;
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
    }, SEARCH_TIMEOUT_SECS, MAX_RESPONSE_BYTES);
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
/// without a `ManufacturerProductNumber` are skipped. Live stock, unit price,
/// lifecycle status, and the per-packaging price ladders all come from the same
/// keyword-search response — DigiKey returns them inline, so no second call.
fn mapProducts(allocator: std.mem.Allocator, items: []std.json.Value, limit: usize) std.mem.Allocator.Error![]Product {
    var list: std.ArrayListUnmanaged(Product) = .empty;
    for (items) |item| {
        if (list.items.len >= limit) break;
        const mpn = strField(item, "ManufacturerProductNumber") orelse continue;
        const variations = try mapVariations(allocator, item);
        try list.append(allocator, .{
            .mpn = try allocator.dupe(u8, mpn),
            .manufacturer = try allocator.dupe(u8, nestedStr(item, "Manufacturer", "Name") orelse ""),
            .description = try allocator.dupe(u8, nestedStr(item, "Description", "ProductDescription") orelse ""),
            .datasheet_url = try dupeOpt(allocator, nonEmpty(strField(item, "DatasheetUrl"))),
            .product_url = try dupeOpt(allocator, nonEmpty(strField(item, "ProductUrl"))),
            // The orderable DK number on the first (default) packaging; duped
            // fresh so it never aliases variations[0]'s owned copy.
            .digikey_part_number = if (variations.len > 0) try dupeOpt(allocator, variations[0].digikey_part_number) else null,
            .quantity_available = u64Field(item, "QuantityAvailable"),
            .unit_price = numField(item, "UnitPrice"),
            .product_status = try dupeOpt(allocator, nonEmpty(nestedStr(item, "ProductStatus", "Status"))),
            .variations = variations,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Map a product's `ProductVariations` array to owned `Variation`s, each with
/// its packaging, live stock, MOQ, and price-break ladder. Empty when absent.
fn mapVariations(allocator: std.mem.Allocator, product: std.json.Value) std.mem.Allocator.Error![]const Variation {
    if (product != .object) return &.{};
    const pv = product.object.get("ProductVariations") orelse return &.{};
    if (pv != .array) return &.{};
    var list: std.ArrayListUnmanaged(Variation) = .empty;
    for (pv.array.items) |v| {
        try list.append(allocator, .{
            .digikey_part_number = try dupeOpt(allocator, nonEmpty(strField(v, "DigiKeyProductNumber"))),
            .package_type = try dupeOpt(allocator, nonEmpty(nestedStr(v, "PackageType", "Name"))),
            .quantity_available = u64Field(v, "QuantityAvailableforPackageType"),
            .minimum_order_quantity = u64Field(v, "MinimumOrderQuantity"),
            .price_breaks = try mapPriceBreaks(allocator, v),
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Map a variation's `StandardPricing` array to owned `PriceBreak`s. Empty when
/// absent (e.g. a marketplace part with no public ladder).
fn mapPriceBreaks(allocator: std.mem.Allocator, variation: std.json.Value) std.mem.Allocator.Error![]const PriceBreak {
    if (variation != .object) return &.{};
    const sp = variation.object.get("StandardPricing") orelse return &.{};
    if (sp != .array) return &.{};
    var list: std.ArrayListUnmanaged(PriceBreak) = .empty;
    for (sp.array.items) |b| {
        try list.append(allocator, .{
            .break_quantity = u64Field(b, "BreakQuantity"),
            .unit_price = numField(b, "UnitPrice") orelse 0,
            .total_price = numField(b, "TotalPrice") orelse 0,
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

/// `obj[key]` as an f64, or null when missing/not numeric. DigiKey returns
/// prices as JSON floats and quantities as integers; both decode here.
fn numField(v: std.json.Value, key: []const u8) ?f64 {
    if (v != .object) return null;
    return jsonNum(v.object.get(key) orelse return null);
}

/// A JSON number as f64, spanning the integer / float / number_string encodings
/// `std.json` may produce. Null for any non-numeric value.
fn jsonNum(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| x,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// `obj[key]` as a non-negative u64 (floored), or 0 when missing/not numeric —
/// the natural "unknown == none" reading for a stock or quantity field.
fn u64Field(v: std.json.Value, key: []const u8) u64 {
    const n = numField(v, key) orelse return 0;
    if (n <= 0) return 0;
    return numeric.checkedInt(u64, n) orelse 0;
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
fn curl(allocator: std.mem.Allocator, extra: []const []const u8, timeout_secs: []const u8, max_bytes: usize) ?[]u8 {
    rate_limiter.digikey.acquire();
    defer rate_limiter.digikey.release();
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.appendSlice(allocator, &.{ "curl", "-sS", "--max-time", timeout_secs }) catch return null;
    argv.appendSlice(allocator, extra) catch return null;

    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = max_bytes,
    }) catch return null;
    if (res.term != .Exited or res.term.Exited != 0) return null;
    return res.stdout;
}

// ── Datasheet download (fallback source for download_datasheet) ────

/// Resolve `part_number` via the keyword search, pick the best match, unwrap any
/// manufacturer interstitial on its `datasheet_url`, download the PDF (following
/// redirects), and validate the `%PDF` magic. The DigiKey-side counterpart to
/// `component_search.downloadDatasheet`, used as a fallback when CSE has no
/// datasheet on file.
pub fn downloadDatasheet(
    allocator: std.mem.Allocator,
    base: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    part_number: []const u8,
    manufacturer: ?[]const u8,
) DatasheetError!DatasheetResult {
    const products = resolveMpn(allocator, base, client_id, client_secret, part_number, 5) catch |err| switch (err) {
        error.TokenFailed => return error.TokenFailed,
        error.SearchFailed => return error.NotFound,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const product = pickProduct(products, part_number, manufacturer) orelse return error.NotFound;
    const raw = product.datasheet_url orelse return error.NoDatasheet;

    const url = try normalizeDatasheetUrl(allocator, raw);
    const pdf = downloadPdf(allocator, url) orelse return error.DownloadFailed;
    if (!looksLikePdf(pdf)) return error.NotPdf;

    return .{
        .pdf_bytes = pdf,
        .mpn = product.mpn,
        .manufacturer = product.manufacturer,
        .source_url = url,
    };
}

/// Choose the product whose MPN matches `part_number` exactly (case-insensitive),
/// preferring one whose manufacturer matches `manufacturer` when given; falls
/// back to the first product. Null only when the list is empty.
fn pickProduct(products: []const Product, part_number: []const u8, manufacturer: ?[]const u8) ?Product {
    if (products.len == 0) return null;
    var first_exact: ?Product = null;
    for (products) |p| {
        if (!std.ascii.eqlIgnoreCase(p.mpn, part_number)) continue;
        if (first_exact == null) first_exact = p;
        if (manufacturer) |want| {
            if (std.ascii.indexOfIgnoreCase(p.manufacturer, want) != null) return p;
        }
    }
    return first_exact orelse products[0];
}

const GOTO_MARKER = "gotoUrl=";

/// Some DigiKey `datasheet_url`s point at a manufacturer interstitial that wraps
/// the real target in a `gotoUrl=<percent-encoded url>` query param (e.g. TI's
/// `suppproductinfo.tsp`). Return that decoded target when present, else the URL
/// unchanged. Following redirects on the result reaches the actual PDF.
fn normalizeDatasheetUrl(allocator: std.mem.Allocator, url: []const u8) std.mem.Allocator.Error![]u8 {
    const idx = std.mem.indexOf(u8, url, GOTO_MARKER) orelse return allocator.dupe(u8, url);
    const start = idx + GOTO_MARKER.len;
    var end = start;
    while (end < url.len and url[end] != '&') : (end += 1) {}
    return percentDecode(allocator, url[start..end]);
}

/// Percent-decode `%XX` escapes; non-escapes pass through verbatim.
fn percentDecode(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const hi = if (s[i] == '%' and i + 2 < s.len) hexVal(s[i + 1]) else null;
        const lo = if (hi != null) hexVal(s[i + 2]) else null;
        if (lo) |l| {
            try out.append(allocator, (hi.? << 4) | l);
            i += 3;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// GET `url` as a browser, following redirects, into a byte buffer.
fn downloadPdf(allocator: std.mem.Allocator, url: []const u8) ?[]u8 {
    // `--` stops curl option parsing so a `-`-leading vendor URL can't be
    // reparsed as a flag (arg-injection / SSRF hardening).
    return curl(allocator, &.{ "-L", "-A", BROWSER_UA, "--", url }, DOWNLOAD_TIMEOUT_SECS, MAX_DOWNLOAD_BYTES);
}

/// PDF magic — distinguishes a real datasheet from an HTML interstitial page.
fn looksLikePdf(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "%PDF");
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

test "normalizeDatasheetUrl unwraps a gotoUrl interstitial" {
    // spec: serve/digikey - normalizeDatasheetUrl unwraps a gotoUrl interstitial
    const a = std.testing.allocator;
    const wrapped = "https://www.ti.com/general/docs/suppproductinfo.tsp?distId=10&gotoUrl=http%3A%2F%2Fwww.ti.com%2Flit%2Fgpn%2Fina228";
    const u = try normalizeDatasheetUrl(a, wrapped);
    defer a.free(u);
    try std.testing.expectEqualStrings("http://www.ti.com/lit/gpn/ina228", u);

    // A plain URL passes through unchanged.
    const p = try normalizeDatasheetUrl(a, "https://example.com/ds.pdf");
    defer a.free(p);
    try std.testing.expectEqualStrings("https://example.com/ds.pdf", p);

    // PDF magic gates a real datasheet vs. an HTML interstitial.
    try std.testing.expect(looksLikePdf("%PDF-1.7\nrest"));
    try std.testing.expect(!looksLikePdf("<!DOCTYPE html>"));
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

test "collectProducts captures live stock, unit price, status, and price breaks" {
    // spec: serve/digikey - collectProducts captures live stock, unit price, status, and per-variation price breaks
    const a = std.testing.allocator;
    const json =
        \\{"Products":[
        \\ {"ManufacturerProductNumber":"INA228AIDGSR",
        \\  "Manufacturer":{"Name":"Texas Instruments"},
        \\  "Description":{"ProductDescription":"IC CURRENT/POWER MONITOR"},
        \\  "QuantityAvailable":15000,"UnitPrice":1.23,
        \\  "ProductStatus":{"Id":0,"Status":"Active"},
        \\  "ProductVariations":[
        \\   {"DigiKeyProductNumber":"296-INA228-NDCT","PackageType":{"Name":"Cut Tape (CT)"},
        \\    "QuantityAvailableforPackageType":15000,"MinimumOrderQuantity":1,
        \\    "StandardPricing":[{"BreakQuantity":1,"UnitPrice":1.23,"TotalPrice":1.23},
        \\     {"BreakQuantity":10,"UnitPrice":0.98,"TotalPrice":9.80}]},
        \\   {"DigiKeyProductNumber":"296-INA228-NDTR","PackageType":{"Name":"Tape & Reel (TR)"},
        \\    "QuantityAvailableforPackageType":3000,"MinimumOrderQuantity":3000,
        \\    "StandardPricing":[]}]},
        \\ {"ManufacturerProductNumber":"NOSTOCK","Manufacturer":{"Name":"Acme"}}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const ps = try collectProducts(a, parsed.value, 10);
    defer freeProducts(a, ps);
    try std.testing.expectEqual(@as(usize, 2), ps.len);

    // Product-level stock / price / lifecycle come off the same response.
    try std.testing.expectEqual(@as(u64, 15000), ps[0].quantity_available);
    try std.testing.expectApproxEqAbs(@as(f64, 1.23), ps[0].unit_price.?, 1e-9);
    try std.testing.expectEqualStrings("Active", ps[0].product_status.?);
    // The top-level DK number tracks the first (default) packaging variation.
    try std.testing.expectEqualStrings("296-INA228-NDCT", ps[0].digikey_part_number.?);

    // Each packaging variation carries its own stock, MOQ, and price ladder.
    try std.testing.expectEqual(@as(usize, 2), ps[0].variations.len);
    const ct = ps[0].variations[0];
    try std.testing.expectEqualStrings("Cut Tape (CT)", ct.package_type.?);
    try std.testing.expectEqual(@as(u64, 15000), ct.quantity_available);
    try std.testing.expectEqual(@as(u64, 1), ct.minimum_order_quantity);
    try std.testing.expectEqual(@as(usize, 2), ct.price_breaks.len);
    try std.testing.expectEqual(@as(u64, 10), ct.price_breaks[1].break_quantity);
    try std.testing.expectApproxEqAbs(@as(f64, 0.98), ct.price_breaks[1].unit_price, 1e-9);
    // A reel with no published ladder maps to an empty price_breaks slice.
    try std.testing.expectEqual(@as(u64, 3000), ps[0].variations[1].minimum_order_quantity);
    try std.testing.expectEqual(@as(usize, 0), ps[0].variations[1].price_breaks.len);

    // A product with no stock/price/variations fields reads as zero/null/empty.
    try std.testing.expectEqual(@as(u64, 0), ps[1].quantity_available);
    try std.testing.expect(ps[1].unit_price == null);
    try std.testing.expect(ps[1].product_status == null);
    try std.testing.expectEqual(@as(usize, 0), ps[1].variations.len);
}

/// Test-only: free the joined terms + backing slice of a variant list.
fn freeVariants(a: std.mem.Allocator, variants: []const []const u8) void {
    for (variants) |v| a.free(v);
    a.free(variants);
}

/// Test-only: free the owned strings + backing slice of a `Product` list,
/// including each product's per-packaging variations and their price ladders.
fn freeProducts(a: std.mem.Allocator, products: []Product) void {
    for (products) |p| {
        a.free(p.mpn);
        a.free(p.manufacturer);
        a.free(p.description);
        if (p.datasheet_url) |x| a.free(x);
        if (p.product_url) |x| a.free(x);
        if (p.digikey_part_number) |x| a.free(x);
        if (p.product_status) |x| a.free(x);
        for (p.variations) |v| {
            if (v.digikey_part_number) |x| a.free(x);
            if (v.package_type) |x| a.free(x);
            a.free(v.price_breaks);
        }
        a.free(p.variations);
    }
    a.free(products);
}
