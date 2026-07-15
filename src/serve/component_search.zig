//! Component Search Engine (componentsearchengine.com) ECAD-model + datasheet
//! fetcher.
//!
//! Resolution goes through the `partApi/suggestion` JSON endpoint, NOT the HTML
//! pages: the search/part-view HTML sits behind a Cloudflare JS challenge (403
//! to non-browser clients), but the suggestion API returns JSON, is not
//! challenged, and needs NO authentication. One suggestion carries everything
//! we need — `part_name`, `manufacturer`, the SamacSys `partID` (inside the
//! `3D View` URL, used for the model ZIP download) and `Current Datasheet Url`.
//! The suggestion API also fuzzy-matches on its own (e.g. `W25Q128FVPIP` →
//! `W25Q128FVPIG`) — but it can fuzzy-MISS the exact part on a full-string
//! query while a relaxed variant lists it, so resolution tries every
//! `searchVariants` term for an exact part-number match before settling for a
//! fuzzy pick.
//!
//! The model ZIP is fetched from the `ga/model.php?partID=<id>` endpoint with
//! plain HTTP Basic auth (the Library Loader desktop app's protocol) — the
//! `CSE_EMAIL`/`CSE_PASSWORD` account, no session cookie / CSRF / Cloudflare
//! dance. HTTP transport is the system `curl` (same shell-out pattern as
//! `read_datasheet` / the zip upload path), so TLS and redirects are handled
//! outside Zig. `downloadFootprint`'s ZIP is fed to `upload.importZipBytes`;
//! `downloadDatasheet`'s PDF (an off-site, unauthenticated fetch) to
//! `storeDatasheet`.
const std = @import("std");
const rate_limiter = @import("rate_limiter.zig");

// ── Endpoints / headers ───────────────────────────────────────────
const host_name = "https://componentsearchengine.com";
const part_id_marker = "partID=";
/// Suggestion-API URL template — `{HOST}` then the percent-encoded query.
const suggestion_url_fmt = "{s}/partApi/suggestion?partNumber={s}";
/// Model-ZIP download URL template — `{HOST}` then the SamacSys part id. Served
/// over HTTP Basic auth (the Library Loader protocol).
const model_url_fmt = "{s}/ga/model.php?partID={s}";
const user_agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " ++
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36";
const referer_header = "referer: " ++ host_name ++ "/";

// ── Tunables ──────────────────────────────────────────────────────
const page_timeout_secs = "20";
const download_timeout_secs = "60";
const max_page_bytes: usize = 8 * 1024 * 1024;
const max_download_bytes: usize = 64 * 1024 * 1024;

// Repeated literals, hoisted so the suggestion parsers and error tables share one copy.
const field_manufacturer = "manufacturer";
const field_part_name = "part_name";
const oom_msg = "out of memory";

/// Outcome of a successful footprint fetch. All slices are owned by the
/// allocator passed to `downloadFootprint` (a request arena in the MCP path).
pub const DownloadResult = struct {
    zip_bytes: []u8,
    part_name: []const u8,
    manufacturer: []const u8,
    samac_id: []const u8,
    /// Path-safe `LIB_<part>.zip`, suitable as the import temp-file name.
    suggested_filename: []const u8,
};

pub const DownloadError = error{
    SearchFailed,
    PartNotFound,
    SamacIdNotFound,
    ModelUnavailable,
    DownloadFailed,
    InvalidCredentials,
} || std.mem.Allocator.Error;

/// Stable, user-facing message for a `DownloadError`, for the MCP envelope.
pub fn errorMessage(err: DownloadError) []const u8 {
    return switch (err) {
        error.SearchFailed => "search request failed (curl/network error)",
        error.PartNotFound => "no matching part found on Component Search Engine",
        error.SamacIdNotFound => "the suggestion has no SamacSys part id (no ECAD model for this part)",
        error.ModelUnavailable => "Component Search Engine has no downloadable model for this part yet (data entry incomplete)",
        error.DownloadFailed => "model download request failed (curl/network error)",
        error.InvalidCredentials => "CSE rejected the account credentials (HTTP 401) — check " ++
            "CSE_EMAIL / CSE_PASSWORD, or sign in at componentsearchengine.com and accept " ++
            "the updated terms, then retry",
        error.OutOfMemory => oom_msg,
    };
}

/// Full pipeline: resolve via the (unauthenticated) suggestion API → download
/// the model ZIP by SamacSys part id over HTTP Basic auth. `basic_auth` is the
/// curl `-u` value (`email:password`) — see `cse_auth.resolve`.
pub fn downloadFootprint(
    allocator: std.mem.Allocator,
    part_number: []const u8,
    manufacturer: ?[]const u8,
    basic_auth: []const u8,
) DownloadError!DownloadResult {
    const part = (try resolvePart(allocator, part_number, manufacturer)) orelse
        return error.PartNotFound;
    const samac_id = part.samac_id orelse return error.SamacIdNotFound;

    const zip = try downloadModel(allocator, samac_id, basic_auth);
    return .{
        .zip_bytes = zip,
        .part_name = part.part_name,
        .manufacturer = part.manufacturer,
        .samac_id = samac_id,
        .suggested_filename = try safeFilename(allocator, part.part_name),
    };
}

/// A datasheet fetched from CSE. Slices are owned by the allocator.
pub const DatasheetResult = struct {
    pdf_bytes: []u8,
    /// Suggested filename (the resolved part name); the caller's store step
    /// sanitises it and forces `.pdf`.
    filename: []const u8,
    part_name: []const u8,
    manufacturer: []const u8,
    source_url: []const u8,
};

pub const DatasheetError = error{
    SearchFailed,
    PartNotFound,
    NoDatasheet,
    DownloadFailed,
    NotPdf,
} || std.mem.Allocator.Error;

/// Stable, user-facing message for a `DatasheetError`.
pub fn datasheetErrorMessage(err: DatasheetError) []const u8 {
    return switch (err) {
        error.SearchFailed => "CSE search request failed (curl/network error)",
        error.PartNotFound => "no matching part found on Component Search Engine",
        error.NoDatasheet => "Component Search Engine has no datasheet on file for this part",
        error.DownloadFailed => "datasheet download request failed (curl/network error)",
        error.NotPdf => "the datasheet URL did not return a valid PDF",
        error.OutOfMemory => oom_msg,
    };
}

/// Resolve via the (unauthenticated) suggestion API → download the
/// `Current Datasheet Url` PDF (an off-site, unauthenticated fetch).
pub fn downloadDatasheet(
    allocator: std.mem.Allocator,
    part_number: []const u8,
    manufacturer: ?[]const u8,
) DatasheetError!DatasheetResult {
    const part = (try resolvePart(allocator, part_number, manufacturer)) orelse
        return error.PartNotFound;
    const url = part.datasheet_url orelse return error.NoDatasheet;

    // The datasheet host (e.g. IHS) just wants a browser UA + referer, both of
    // which `httpGet` always sends; no CSE cookie needed off-site.
    const pdf = httpGet(allocator, url, null, max_download_bytes, download_timeout_secs) orelse
        return error.DownloadFailed;
    if (!looksLikePdf(pdf)) return error.NotPdf;

    return .{
        .pdf_bytes = pdf,
        .filename = part.part_name,
        .part_name = part.part_name,
        .manufacturer = part.manufacturer,
        .source_url = url,
    };
}

// ── Search (multi-result) ─────────────────────────────────────────

/// One candidate from a component search. Slices are owned by the allocator
/// passed to `searchComponents`. `samac_id` is null when CSE has no ECAD model
/// for the part; `datasheet_url` is null when it has no datasheet on file.
pub const SearchHit = struct {
    part_name: []const u8,
    manufacturer: []const u8,
    samac_id: ?[]const u8,
    datasheet_url: ?[]const u8,
};

pub const SearchError = error{SearchFailed} || std.mem.Allocator.Error;

/// Stable, user-facing message for a `SearchError`.
pub fn searchErrorMessage(err: SearchError) []const u8 {
    return switch (err) {
        error.SearchFailed => "CSE search request failed (network error or Cloudflare block)",
        error.OutOfMemory => oom_msg,
    };
}

/// Search CSE via `partApi/suggestion` and return up to `limit` candidates.
/// Hits are AGGREGATED across the exact query and every relaxed
/// `searchVariants` term (de-duplicated by part name) — not first-variant-wins:
/// the suggestion API sometimes fuzzy-misses the exact part on the full-string
/// query while a relaxed term lists it (e.g. `DAT-31A-SP+` returns only the
/// PP+/PN+ siblings, but `DAT-31A` surfaces the exact SP+). A hit whose name
/// exactly matches `query` is hoisted to the front. An empty slice means the
/// API responded but matched nothing; `error.SearchFailed` means no request
/// succeeded at all (network failure or Cloudflare block). Needs no auth — the
/// suggestion API is public.
pub fn searchComponents(
    allocator: std.mem.Allocator,
    query: []const u8,
    limit: usize,
) SearchError![]SearchHit {
    var any_ok = false;
    var list: std.ArrayList(SearchHit) = .empty;
    for (try searchVariants(allocator, query)) |term| {
        if (list.items.len >= limit) break;
        for (try suggestList(allocator, term, limit, &any_ok)) |hit| {
            if (list.items.len >= limit) break;
            if (containsHit(list.items, hit.part_name)) continue;
            try list.append(allocator, hit);
        }
    }
    if (list.items.len == 0 and !any_ok) return error.SearchFailed;
    hoistExact(list.items, query);
    return list.toOwnedSlice(allocator);
}

/// True when `hits` already carries `part_name` (ASCII case-insensitive) —
/// the aggregation dedup, since relaxed variants re-list earlier hits.
fn containsHit(hits: []const SearchHit, part_name: []const u8) bool {
    for (hits) |h| {
        if (std.ascii.eqlIgnoreCase(h.part_name, part_name)) return true;
    }
    return false;
}

/// Move the first hit whose part name equals `query` (ASCII case-insensitive)
/// to the front, preserving the order of everything else — so callers that
/// take the first hit resolve the queried part, not a more popular sibling.
fn hoistExact(hits: []SearchHit, query: []const u8) void {
    for (hits, 0..) |h, i| {
        if (!std.ascii.eqlIgnoreCase(h.part_name, query)) continue;
        std.mem.rotate(SearchHit, hits[0 .. i + 1], i);
        return;
    }
}

// ── Resolution via the suggestion API ─────────────────────────────

/// A part resolved from the CSE suggestion API. Strings are owned by the
/// allocator. `samac_id` / `datasheet_url` are null when the suggestion omits
/// them (no ECAD model / no datasheet on file).
const ResolvedPart = struct {
    part_name: []const u8,
    manufacturer: []const u8,
    samac_id: ?[]const u8,
    datasheet_url: ?[]const u8,
};

/// Resolve a part via `partApi/suggestion` (JSON; not Cloudflare-challenged;
/// no auth). Every relaxed `searchVariants` term is tried until one yields an
/// EXACT part-number match — a fuzzy pick from an early variant must not shadow
/// an exact hit from a later one, because the API sometimes fuzzy-misses the
/// exact part on the full-string query while a relaxed term lists it (e.g.
/// `DAT-31A-SP+` returns only the PP+/PN+ siblings, but `DAT-31A` surfaces
/// the exact SP+). The first fuzzy pick is kept as the fallback when no
/// variant matches exactly.
fn resolvePart(
    allocator: std.mem.Allocator,
    part_number: []const u8,
    manufacturer: ?[]const u8,
) std.mem.Allocator.Error!?ResolvedPart {
    var fallback: ?ResolvedPart = null;
    for (try searchVariants(allocator, part_number)) |term| {
        const got = (try suggestQuery(allocator, term, part_number, manufacturer)) orelse continue;
        if (got.exact) return got.part;
        if (fallback == null) fallback = got.part;
    }
    return fallback;
}

/// One variant query's pick, flagged with whether its part name exactly
/// matched the original part number (the resolvePart early-exit signal).
const SuggestPick = struct { part: ResolvedPart, exact: bool };

/// Query the suggestion API for one `term` and build a `SuggestPick` from the
/// chosen suggestion, or null when the request fails / has no usable result.
/// `part_number` is the caller's ORIGINAL query — exactness is judged against
/// it, not the (possibly relaxed) `term`.
fn suggestQuery(
    allocator: std.mem.Allocator,
    term: []const u8,
    part_number: []const u8,
    manufacturer: ?[]const u8,
) std.mem.Allocator.Error!?SuggestPick {
    const enc = try percentEncode(allocator, term);
    const url = try std.fmt.allocPrint(allocator, suggestion_url_fmt, .{ host_name, enc });
    const body = httpGet(allocator, url, null, max_page_bytes, page_timeout_secs) orelse return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const chosen = pickSuggestion(parsed.value, part_number, manufacturer) orelse return null;

    const pn = strField(chosen, field_part_name) orelse return null;
    const mfg = strField(chosen, field_manufacturer) orelse "";
    const samac = extractPartId(chosen);
    const ds_url = suggestionDatasheetUrl(chosen);
    return .{
        .part = .{
            .part_name = try allocator.dupe(u8, pn),
            .manufacturer = try allocator.dupe(u8, mfg),
            .samac_id = if (samac) |s| try allocator.dupe(u8, s) else null,
            .datasheet_url = if (ds_url) |u| try allocator.dupe(u8, u) else null,
        },
        .exact = std.ascii.eqlIgnoreCase(pn, part_number),
    };
}

/// The `data.suggestions` array from a suggestion-API response, or null when
/// the shape is unexpected or the array is empty.
fn suggestionsArray(root: std.json.Value) ?[]std.json.Value {
    if (root != .object) return null;
    const data = root.object.get("data") orelse return null;
    if (data != .object) return null;
    const suggestions = data.object.get("suggestions") orelse return null;
    if (suggestions != .array or suggestions.array.items.len == 0) return null;
    return suggestions.array.items;
}

/// Choose a suggestion from `data.suggestions`: an exact `term` match first
/// (callers pass the ORIGINAL part number here, even when the query used a
/// relaxed variant), then the manufacturer filter (case-insensitive
/// substring), else the first. Returns the chosen `Value` (a slice into the
/// parsed tree).
fn pickSuggestion(root: std.json.Value, term: []const u8, manufacturer: ?[]const u8) ?std.json.Value {
    const items = suggestionsArray(root) orelse return null;
    // Prefer a suggestion whose part_name exactly matches the query so a search
    // for "TXS0108EPWR" isn't silently resolved to the more popular
    // "TXS0108EDGSR" that CSE happens to list first. The manufacturer filter,
    // when given, still applies among the exact matches.
    var first_exact: ?std.json.Value = null;
    for (items) |s| {
        const pn = strField(s, field_part_name) orelse continue;
        if (!std.ascii.eqlIgnoreCase(pn, term)) continue;
        if (first_exact == null) first_exact = s;
        if (manufacturer) |want| {
            const mfg = strField(s, field_manufacturer) orelse "";
            if (std.ascii.indexOfIgnoreCase(mfg, want) != null) return s;
        } else return s;
    }
    if (first_exact) |s| return s;
    // No exact part match — fall back to the manufacturer filter, else the first.
    const want = manufacturer orelse return items[0];
    for (items) |s| {
        const mfg = strField(s, field_manufacturer) orelse continue;
        if (std.ascii.indexOfIgnoreCase(mfg, want) != null) return s;
    }
    return items[0];
}

/// Fetch one suggestion page and map every suggestion to a `SearchHit`. Sets
/// `any_ok` once the request returned parseable JSON, so the caller can tell
/// "API matched nothing" from "request never succeeded". Returns an empty slice
/// on a transport/parse failure or an empty suggestion list.
fn suggestList(
    allocator: std.mem.Allocator,
    term: []const u8,
    limit: usize,
    any_ok: *bool,
) std.mem.Allocator.Error![]SearchHit {
    const enc = try percentEncode(allocator, term);
    const url = try std.fmt.allocPrint(allocator, suggestion_url_fmt, .{ host_name, enc });
    const body = httpGet(allocator, url, null, max_page_bytes, page_timeout_secs) orelse return &.{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return &.{};
    defer parsed.deinit();
    any_ok.* = true;
    return collectHits(allocator, parsed.value, limit);
}

/// Map `data.suggestions` to owned `SearchHit`s, capped at `limit`.
fn collectHits(allocator: std.mem.Allocator, root: std.json.Value, limit: usize) std.mem.Allocator.Error![]SearchHit {
    const items = suggestionsArray(root) orelse return &.{};
    var list: std.ArrayList(SearchHit) = .empty;
    for (items) |s| {
        if (list.items.len >= limit) break;
        const pn = strField(s, field_part_name) orelse continue;
        const mfg = strField(s, field_manufacturer) orelse "";
        const samac = extractPartId(s);
        const ds = suggestionDatasheetUrl(s);
        try list.append(allocator, .{
            .part_name = try allocator.dupe(u8, pn),
            .manufacturer = try allocator.dupe(u8, mfg),
            .samac_id = if (samac) |x| try allocator.dupe(u8, x) else null,
            .datasheet_url = if (ds) |x| try allocator.dupe(u8, x) else null,
        });
    }
    return list.toOwnedSlice(allocator);
}

/// Extract the SamacSys `partID` from a suggestion's `3D View` URL
/// (`…/3D.php?partID=231980`). Slice into the parsed tree.
fn extractPartId(suggestion: std.json.Value) ?[]const u8 {
    const view = strField(suggestion, "3D View") orelse return null;
    const idx = std.mem.indexOf(u8, view, part_id_marker) orelse return null;
    const start = idx + part_id_marker.len;
    var end = start;
    while (end < view.len and view[end] >= '0' and view[end] <= '9') : (end += 1) {}
    return if (end == start) null else view[start..end];
}

/// `parametric_data["Current Datasheet Url"]` from a suggestion (already an
/// absolute URL), or null.
fn suggestionDatasheetUrl(suggestion: std.json.Value) ?[]const u8 {
    if (suggestion != .object) return null;
    const pd = suggestion.object.get("parametric_data") orelse return null;
    return strField(pd, "Current Datasheet Url");
}

fn strField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

// ── Search-term relaxation ────────────────────────────────────────

/// Minimum length for a relaxed search variant — shorter prefixes match too
/// much to be useful.
const min_variant_len = 3;

/// Ordered, de-duplicated search terms to try: the exact part number first,
/// then relaxations that recover the base/family when the full orderable part
/// number isn't indexed — strip a trailing `+`, take the text before the last
/// or first `-`, and the prefix through the last digit (drops a trailing
/// package/grade letter cluster, e.g. `INA228AIDGSR` → `INA228`). Each is
/// only added when it is at least `MIN_VARIANT_LEN` long and not already listed.
fn searchVariants(allocator: std.mem.Allocator, part_number: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    try list.append(allocator, part_number);

    try addVariant(allocator, &list, std.mem.trimRight(u8, part_number, "+"));
    if (std.mem.lastIndexOfScalar(u8, part_number, '-')) |i| try addVariant(allocator, &list, part_number[0..i]);
    if (std.mem.indexOfScalar(u8, part_number, '-')) |i| try addVariant(allocator, &list, part_number[0..i]);

    var last_digit: ?usize = null;
    for (part_number, 0..) |c, i| {
        if (c >= '0' and c <= '9') last_digit = i;
    }
    if (last_digit) |ld| try addVariant(allocator, &list, part_number[0 .. ld + 1]);

    return list.toOwnedSlice(allocator);
}

fn addVariant(allocator: std.mem.Allocator, list: *std.ArrayList([]const u8), term: []const u8) std.mem.Allocator.Error!void {
    if (term.len < min_variant_len) return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, term)) return;
    }
    try list.append(allocator, term);
}

// ── Download ──────────────────────────────────────────────────────

/// GET the model ZIP for `samac_id` from `ga/model.php` with HTTP Basic auth,
/// then classify the body: a ZIP is success; an `Error: …` text body means CSE
/// has no complete model for this part yet; anything else (a 401 HTML login
/// page) means the credentials were rejected — or the account must accept CSE's
/// updated terms.
fn downloadModel(
    allocator: std.mem.Allocator,
    samac_id: []const u8,
    basic_auth: []const u8,
) DownloadError![]u8 {
    const url = try modelUrl(allocator, samac_id);
    const body = httpGet(allocator, url, basic_auth, max_download_bytes, download_timeout_secs) orelse
        return error.DownloadFailed;
    if (looksLikeZip(body)) return body;
    if (std.mem.startsWith(u8, body, "Error")) return error.ModelUnavailable;
    return error.InvalidCredentials;
}

/// Build the model-ZIP download URL for SamacSys `samac_id` — the HTTP
/// Basic-auth `ga/model.php` endpoint.
fn modelUrl(allocator: std.mem.Allocator, samac_id: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, model_url_fmt, .{ host_name, samac_id });
}

// ── curl transport ────────────────────────────────────────────────

/// GET `url` with browser-like headers and an optional HTTP Basic-auth
/// credential (`basic_auth`, the curl `-u` value `email:password`), following
/// redirects. curl splits `-u` on the FIRST colon, and an email can't contain a
/// colon, so a password with colons is preserved. Returns the response body, or
/// null on a spawn failure or non-zero exit. Note: curl exits 0 on an HTTP 401
/// (no `-f`), so a rejected-credential body is returned for the caller to
/// classify, not swallowed as an error.
fn httpGet(
    allocator: std.mem.Allocator,
    url: []const u8,
    basic_auth: ?[]const u8,
    max_bytes: usize,
    timeout_secs: []const u8,
) ?[]u8 {
    rate_limiter.cse.acquire();
    defer rate_limiter.cse.release();
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(allocator, &.{
        "curl", "-sS",      "-L", "--max-time",   timeout_secs,
        "-A",   user_agent, "-H", referer_header,
    }) catch return null;
    if (basic_auth) |a| argv.appendSlice(allocator, &.{ "-u", a }) catch return null;
    // `--` terminates option parsing so a vendor-supplied URL beginning with
    // `-` can't be reinterpreted as a curl flag (arg-injection / SSRF hardening).
    argv.appendSlice(allocator, &.{ "--", url }) catch return null;

    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = max_bytes,
    }) catch return null;
    if (res.term != .Exited or res.term.Exited != 0) return null;
    return res.stdout;
}

// ── Pure helpers ──────────────────────────────────────────────────

const hex = "0123456789ABCDEF";

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
}

/// Percent-encode every non-RFC-3986-unreserved byte. Mirrors Python's
/// `urllib.parse.quote(s, safe="")` — used for query params and path
/// segments alike.
fn percentEncode(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.appendSlice(allocator, &.{ '%', hex[c >> 4], hex[c & 0x0F] });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// ZIP local-file-header magic ("PK") — a real model archive vs. an error
/// text or HTML page.
fn looksLikeZip(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 'P' and bytes[1] == 'K';
}

/// PDF magic — distinguishes a real datasheet from an HTML page.
fn looksLikePdf(bytes: []const u8) bool {
    return bytes.len >= 4 and std.mem.eql(u8, bytes[0..4], "%PDF");
}

/// `LIB_<part>.zip` with every non-`[A-Za-z0-9._-]` byte replaced by `_`,
/// so it is safe as a temp-file path component.
fn safeFilename(allocator: std.mem.Allocator, part_name: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "LIB_");
    for (part_name) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '_';
        try out.append(allocator, if (ok) c else '_');
    }
    try out.appendSlice(allocator, ".zip");
    return out.toOwnedSlice(allocator);
}

// ── Tests ─────────────────────────────────────────────────────────

test "percentEncode encodes non-unreserved bytes" {
    // spec: serve/component_search - percentEncode escapes spaces and reserved chars
    const a = std.testing.allocator;
    const out = try percentEncode(a, "Texas Instruments/LMX2595+");
    defer a.free(out);
    try std.testing.expectEqualStrings("Texas%20Instruments%2FLMX2595%2B", out);
}

test "searchVariants relaxes the part number for non-exact matches" {
    // spec: serve/component_search - searchVariants relaxes the part number
    const a = std.testing.allocator;
    const v1 = try searchVariants(a, "INA228AIDGSR");
    defer a.free(v1);
    try std.testing.expectEqual(@as(usize, 2), v1.len);
    try std.testing.expectEqualStrings("INA228AIDGSR", v1[0]);
    try std.testing.expectEqualStrings("INA228", v1[1]);

    const v2 = try searchVariants(a, "ADP7118AUJZ-3.3-R7");
    defer a.free(v2);
    try std.testing.expectEqualStrings("ADP7118AUJZ-3.3-R7", v2[0]);
    try std.testing.expectEqualStrings("ADP7118AUJZ-3.3", v2[1]);
    try std.testing.expectEqualStrings("ADP7118AUJZ", v2[2]);
}

test "suggestion parsing picks the part, id and datasheet url" {
    // spec: serve/component_search - parses part id and datasheet url from a suggestion
    const a = std.testing.allocator;
    const json =
        \\{"data":{"suggestions":[
        \\{"part_name":"OTHER","manufacturer":"Onsemi",
        \\ "3D View":"v?partID=111","parametric_data":{"Current Datasheet Url":"a.pdf"}},
        \\{"part_name":"W25Q128FVPIG","manufacturer":"Winbond Electronics Corp",
        \\ "3D View":"v?partID=231980","parametric_data":{"Current Datasheet Url":"ds.pdf"}}
        \\]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();

    // Non-matching query term ("") → manufacturer filter selects the part.
    const chosen = pickSuggestion(parsed.value, "", "winbond").?;
    try std.testing.expectEqualStrings("W25Q128FVPIG", strField(chosen, "part_name").?);
    try std.testing.expectEqualStrings("231980", extractPartId(chosen).?);
    try std.testing.expectEqualStrings("ds.pdf", suggestionDatasheetUrl(chosen).?);

    // An exact part_name match wins over the first suggestion and over mfr.
    try std.testing.expectEqualStrings("W25Q128FVPIG", strField(pickSuggestion(parsed.value, "w25q128fvpig", null).?, "part_name").?);

    // No manufacturer (and an unmatched one) fall back to the first suggestion.
    try std.testing.expectEqualStrings("OTHER", strField(pickSuggestion(parsed.value, "", null).?, "part_name").?);
    try std.testing.expectEqualStrings("OTHER", strField(pickSuggestion(parsed.value, "", "nope").?, "part_name").?);

    var empty = try std.json.parseFromSlice(std.json.Value, a, "{\"data\":{\"suggestions\":[]}}", .{});
    defer empty.deinit();
    try std.testing.expect(pickSuggestion(empty.value, "", null) == null);
}

test "looksLikeZip gates on PK magic" {
    // spec: serve/component_search - looksLikeZip detects the ZIP magic bytes
    try std.testing.expect(looksLikeZip("PK\x03\x04rest"));
    try std.testing.expect(!looksLikeZip("<!DOCTYPE html>"));
    try std.testing.expect(!looksLikeZip("P"));
}

test "modelUrl targets the ga/model.php Basic-auth endpoint" {
    // spec: serve/component_search - modelUrl targets the ga/model.php endpoint by part id
    const a = std.testing.allocator;
    const url = try modelUrl(a, "11481054");
    defer a.free(url);
    try std.testing.expectEqualStrings("https://componentsearchengine.com/ga/model.php?partID=11481054", url);
}

test "safeFilename sanitises into LIB_<part>.zip" {
    // spec: serve/component_search - safeFilename builds a path-safe LIB_<part>.zip
    const a = std.testing.allocator;
    const out = try safeFilename(a, "LMX2595/RHAT R7");
    defer a.free(out);
    try std.testing.expectEqualStrings("LIB_LMX2595_RHAT_R7.zip", out);
}

test "collectHits maps suggestions to search hits" {
    // spec: serve/component_search - collectHits maps suggestions to search hits
    const a = std.testing.allocator;
    const json =
        \\{"data":{"suggestions":[
        \\{"part_name":"W25Q128FVPIG","manufacturer":"Winbond",
        \\ "3D View":"v?partID=231980","parametric_data":{"Current Datasheet Url":"ds.pdf"}},
        \\{"part_name":"GENERIC","manufacturer":"Acme","parametric_data":{}}
        \\]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();

    const hits = try collectHits(a, parsed.value, 10);
    defer freeHits(a, hits);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqualStrings("W25Q128FVPIG", hits[0].part_name);
    try std.testing.expectEqualStrings("231980", hits[0].samac_id.?);
    try std.testing.expectEqualStrings("ds.pdf", hits[0].datasheet_url.?);
    try std.testing.expect(hits[1].samac_id == null);
    try std.testing.expect(hits[1].datasheet_url == null);

    // limit caps the result count.
    const one = try collectHits(a, parsed.value, 1);
    defer freeHits(a, one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
}

test "containsHit dedups aggregated hits by part name" {
    // spec: serve/component_search - containsHit dedups aggregated hits by part name
    const hits = [_]SearchHit{
        .{ .part_name = "DAT-31A-PP+", .manufacturer = "Mini-Circuits", .samac_id = null, .datasheet_url = null },
        .{ .part_name = "DAT-31A-SP+", .manufacturer = "Mini-Circuits", .samac_id = null, .datasheet_url = null },
    };
    try std.testing.expect(containsHit(&hits, "DAT-31A-SP+"));
    try std.testing.expect(containsHit(&hits, "dat-31a-pp+"));
    try std.testing.expect(!containsHit(&hits, "DAT-31A-PN+"));
    try std.testing.expect(!containsHit(hits[0..0], "DAT-31A-SP+"));
}

test "hoistExact moves the exact query match to the front" {
    // spec: serve/component_search - hoistExact moves the exact query match to the front
    var hits = [_]SearchHit{
        .{ .part_name = "DAT-31A-PP+", .manufacturer = "", .samac_id = null, .datasheet_url = null },
        .{ .part_name = "DAT-31A-PN+", .manufacturer = "", .samac_id = null, .datasheet_url = null },
        .{ .part_name = "DAT-31A-SP+", .manufacturer = "", .samac_id = null, .datasheet_url = null },
    };
    hoistExact(&hits, "dat-31a-sp+");
    try std.testing.expectEqualStrings("DAT-31A-SP+", hits[0].part_name);
    // The others keep their relative order.
    try std.testing.expectEqualStrings("DAT-31A-PP+", hits[1].part_name);
    try std.testing.expectEqualStrings("DAT-31A-PN+", hits[2].part_name);
    // No exact match → order untouched.
    hoistExact(&hits, "LMX2595");
    try std.testing.expectEqualStrings("DAT-31A-SP+", hits[0].part_name);
}

/// Test-only: free the owned strings + backing slice of a `SearchHit` list.
fn freeHits(a: std.mem.Allocator, hits: []SearchHit) void {
    for (hits) |h| {
        a.free(h.part_name);
        a.free(h.manufacturer);
        if (h.samac_id) |s| a.free(s);
        if (h.datasheet_url) |d| a.free(d);
    }
    a.free(hits);
}
