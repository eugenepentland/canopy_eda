//! Component Search Engine (componentsearchengine.com) ECAD-model + datasheet
//! fetcher.
//!
//! Resolution goes through the `partApi/suggestion` JSON endpoint, NOT the HTML
//! pages: the search/part-view HTML sits behind a Cloudflare JS challenge (403
//! to non-browser clients), but the suggestion API returns JSON and is not
//! challenged. One suggestion carries everything we need — `part_name`,
//! `manufacturer`, the SamacSys `partID` (inside the `3D View` URL, used for the
//! model ZIP download) and `Current Datasheet Url`. The suggestion API also
//! fuzzy-matches on its own (e.g. `W25Q128FVPIP` → `W25Q128FVPIG`).
//!
//! HTTP transport is the system `curl` (same shell-out pattern as
//! `read_datasheet` / the zip upload path), so TLS, redirects, and cookies are
//! handled outside Zig. `downloadFootprint`'s ZIP is fed to
//! `upload.importZipBytes`; `downloadDatasheet`'s PDF to `storeDatasheet`.
const std = @import("std");

// ── Endpoints / headers ───────────────────────────────────────────
const HOST = "https://componentsearchengine.com";
const PART_VIEW_PREFIX = "/part-view/";
const PART_ID_MARKER = "partID=";
/// Suggestion-API URL template — `{HOST}` then the percent-encoded query.
const SUGGESTION_URL_FMT = "{s}/partApi/suggestion?partNumber={s}";
const USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " ++
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36";
const REFERER_HEADER = "referer: " ++ HOST ++ "/";
const COOKIE_NAME = "connect.sid=";

// ── Tunables ──────────────────────────────────────────────────────
const PAGE_TIMEOUT_SECS = "20";
const DOWNLOAD_TIMEOUT_SECS = "60";
const MAX_PAGE_BYTES: usize = 8 * 1024 * 1024;
const MAX_DOWNLOAD_BYTES: usize = 64 * 1024 * 1024;

// Repeated literals, hoisted so the suggestion parsers and error tables share one copy.
const FIELD_MANUFACTURER = "manufacturer";
const FIELD_PART_NAME = "part_name";
const OOM_MSG = "out of memory";

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
    InvalidCookie,
} || std.mem.Allocator.Error;

/// Stable, user-facing message for a `DownloadError`, for the MCP envelope.
pub fn errorMessage(err: DownloadError) []const u8 {
    return switch (err) {
        error.SearchFailed => "search request failed (curl/network error)",
        error.PartNotFound => "no matching part found on Component Search Engine",
        error.SamacIdNotFound => "the suggestion has no SamacSys part id (no ECAD model for this part)",
        error.ModelUnavailable => "Component Search Engine has no downloadable model for this part yet (data entry incomplete)",
        error.DownloadFailed => "model download request failed (curl/network error)",
        error.InvalidCookie => "CSE_CONNECT_SID was rejected or has expired (got a login page, not a zip)",
        error.OutOfMemory => OOM_MSG,
    };
}

/// Full pipeline: resolve via the suggestion API → download the model ZIP by
/// SamacSys part id. `connect_sid` is the raw `connect.sid` cookie value.
pub fn downloadFootprint(
    allocator: std.mem.Allocator,
    part_number: []const u8,
    manufacturer: ?[]const u8,
    connect_sid: []const u8,
) DownloadError!DownloadResult {
    const part = (try resolvePart(allocator, part_number, manufacturer, connect_sid)) orelse
        return error.PartNotFound;
    const samac_id = part.samac_id orelse return error.SamacIdNotFound;

    const zip = try downloadModel(allocator, part.detail_path, samac_id, connect_sid);
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
        error.OutOfMemory => OOM_MSG,
    };
}

/// Resolve via the suggestion API → download the `Current Datasheet Url` PDF.
pub fn downloadDatasheet(
    allocator: std.mem.Allocator,
    part_number: []const u8,
    manufacturer: ?[]const u8,
    connect_sid: []const u8,
) DatasheetError!DatasheetResult {
    const part = (try resolvePart(allocator, part_number, manufacturer, connect_sid)) orelse
        return error.PartNotFound;
    const url = part.datasheet_url orelse return error.NoDatasheet;

    // The datasheet host (e.g. IHS) just wants a browser UA + referer, both of
    // which `httpGet` always sends; no CSE cookie needed off-site.
    const pdf = httpGet(allocator, url, null, MAX_DOWNLOAD_BYTES, DOWNLOAD_TIMEOUT_SECS) orelse
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
        error.SearchFailed => "CSE search request failed (network error, or CSE_CONNECT_SID rejected)",
        error.OutOfMemory => OOM_MSG,
    };
}

/// Search CSE via `partApi/suggestion` and return up to `limit` candidates.
/// The exact query is tried first; if it yields no suggestions (but the request
/// succeeded) the relaxed `searchVariants` are tried in turn until one returns
/// hits. An empty slice means the API responded but matched nothing;
/// `error.SearchFailed` means no request succeeded at all (network failure,
/// rejected cookie, or Cloudflare block).
pub fn searchComponents(
    allocator: std.mem.Allocator,
    query: []const u8,
    connect_sid: []const u8,
    limit: usize,
) SearchError![]SearchHit {
    var any_ok = false;
    for (try searchVariants(allocator, query)) |term| {
        const hits = try suggestList(allocator, term, connect_sid, limit, &any_ok);
        if (hits.len > 0) return hits;
    }
    if (!any_ok) return error.SearchFailed;
    return &.{};
}

// ── Resolution via the suggestion API ─────────────────────────────

/// A part resolved from the CSE suggestion API. Strings are owned by the
/// allocator. `samac_id` / `datasheet_url` are null when the suggestion omits
/// them (no ECAD model / no datasheet on file).
const ResolvedPart = struct {
    part_name: []const u8,
    manufacturer: []const u8,
    /// `/part-view/<enc name>/<enc mfg>` — the model download's `from` param.
    detail_path: []const u8,
    samac_id: ?[]const u8,
    datasheet_url: ?[]const u8,
};

/// Resolve a part via `partApi/suggestion` (JSON; not Cloudflare-challenged).
/// The API fuzzy-matches on its own; we additionally retry with relaxed
/// `searchVariants` when a term yields nothing. The session cookie is sent on
/// every request so an authenticated session is served real data.
fn resolvePart(
    allocator: std.mem.Allocator,
    part_number: []const u8,
    manufacturer: ?[]const u8,
    connect_sid: []const u8,
) std.mem.Allocator.Error!?ResolvedPart {
    for (try searchVariants(allocator, part_number)) |term| {
        if (try suggestQuery(allocator, term, manufacturer, connect_sid)) |rp| return rp;
    }
    return null;
}

/// Query the suggestion API for one term and build a `ResolvedPart` from the
/// chosen suggestion, or null when the request fails / has no usable result.
fn suggestQuery(
    allocator: std.mem.Allocator,
    term: []const u8,
    manufacturer: ?[]const u8,
    connect_sid: []const u8,
) std.mem.Allocator.Error!?ResolvedPart {
    const enc = try percentEncode(allocator, term);
    const url = try std.fmt.allocPrint(allocator, SUGGESTION_URL_FMT, .{ HOST, enc });
    const body = httpGet(allocator, url, connect_sid, MAX_PAGE_BYTES, PAGE_TIMEOUT_SECS) orelse return null;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const chosen = pickSuggestion(parsed.value, term, manufacturer) orelse return null;

    const pn = strField(chosen, FIELD_PART_NAME) orelse return null;
    const mfg = strField(chosen, FIELD_MANUFACTURER) orelse "";
    const enc_name = try percentEncode(allocator, pn);
    const enc_mfg = try percentEncode(allocator, mfg);
    const samac = extractPartId(chosen);
    const ds_url = suggestionDatasheetUrl(chosen);
    return .{
        .part_name = try allocator.dupe(u8, pn),
        .manufacturer = try allocator.dupe(u8, mfg),
        .detail_path = try std.fmt.allocPrint(allocator, "{s}{s}/{s}", .{ PART_VIEW_PREFIX, enc_name, enc_mfg }),
        .samac_id = if (samac) |s| try allocator.dupe(u8, s) else null,
        .datasheet_url = if (ds_url) |u| try allocator.dupe(u8, u) else null,
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

/// Choose a suggestion from `data.suggestions`: the first whose manufacturer
/// matches `manufacturer` (case-insensitive substring) when given, else the
/// first. Returns the chosen `Value` (a slice into the parsed tree).
fn pickSuggestion(root: std.json.Value, term: []const u8, manufacturer: ?[]const u8) ?std.json.Value {
    const items = suggestionsArray(root) orelse return null;
    // Prefer a suggestion whose part_name exactly matches the query so a search
    // for "TXS0108EPWR" isn't silently resolved to the more popular
    // "TXS0108EDGSR" that CSE happens to list first. The manufacturer filter,
    // when given, still applies among the exact matches.
    var first_exact: ?std.json.Value = null;
    for (items) |s| {
        const pn = strField(s, FIELD_PART_NAME) orelse continue;
        if (!std.ascii.eqlIgnoreCase(pn, term)) continue;
        if (first_exact == null) first_exact = s;
        if (manufacturer) |want| {
            const mfg = strField(s, FIELD_MANUFACTURER) orelse "";
            if (std.ascii.indexOfIgnoreCase(mfg, want) != null) return s;
        } else return s;
    }
    if (first_exact) |s| return s;
    // No exact part match — fall back to the manufacturer filter, else the first.
    const want = manufacturer orelse return items[0];
    for (items) |s| {
        const mfg = strField(s, FIELD_MANUFACTURER) orelse continue;
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
    connect_sid: []const u8,
    limit: usize,
    any_ok: *bool,
) std.mem.Allocator.Error![]SearchHit {
    const enc = try percentEncode(allocator, term);
    const url = try std.fmt.allocPrint(allocator, SUGGESTION_URL_FMT, .{ HOST, enc });
    const body = httpGet(allocator, url, connect_sid, MAX_PAGE_BYTES, PAGE_TIMEOUT_SECS) orelse return &.{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return &.{};
    defer parsed.deinit();
    any_ok.* = true;
    return collectHits(allocator, parsed.value, limit);
}

/// Map `data.suggestions` to owned `SearchHit`s, capped at `limit`.
fn collectHits(allocator: std.mem.Allocator, root: std.json.Value, limit: usize) std.mem.Allocator.Error![]SearchHit {
    const items = suggestionsArray(root) orelse return &.{};
    var list: std.ArrayListUnmanaged(SearchHit) = .empty;
    for (items) |s| {
        if (list.items.len >= limit) break;
        const pn = strField(s, FIELD_PART_NAME) orelse continue;
        const mfg = strField(s, FIELD_MANUFACTURER) orelse "";
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
    const idx = std.mem.indexOf(u8, view, PART_ID_MARKER) orelse return null;
    const start = idx + PART_ID_MARKER.len;
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
const MIN_VARIANT_LEN = 3;

/// Ordered, de-duplicated search terms to try: the exact part number first,
/// then relaxations that recover the base/family when the full orderable part
/// number isn't indexed — strip a trailing `+`, take the text before the last
/// or first `-`, and the prefix through the last digit (drops a trailing
/// package/grade letter cluster, e.g. `INA228AIDGSR` → `INA228`). Each is
/// only added when it is at least `MIN_VARIANT_LEN` long and not already listed.
fn searchVariants(allocator: std.mem.Allocator, part_number: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
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

fn addVariant(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), term: []const u8) std.mem.Allocator.Error!void {
    if (term.len < MIN_VARIANT_LEN) return;
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, term)) return;
    }
    try list.append(allocator, term);
}

// ── Download ──────────────────────────────────────────────────────

/// GET the model ZIP for `samac_id` with the session cookie attached, then
/// classify the body: a ZIP is success; an `Error: …` text body means the part
/// has no complete model yet; anything else (e.g. a login/Cloudflare HTML page)
/// means the cookie was rejected.
fn downloadModel(
    allocator: std.mem.Allocator,
    detail_path: []const u8,
    samac_id: []const u8,
    connect_sid: []const u8,
) DownloadError![]u8 {
    const from_param = try percentEncode(allocator, detail_path);
    const url = try std.fmt.allocPrint(
        allocator,
        "{s}/partApi/model/download?from={s}&id={s}",
        .{ HOST, from_param, samac_id },
    );
    const body = httpGet(allocator, url, connect_sid, MAX_DOWNLOAD_BYTES, DOWNLOAD_TIMEOUT_SECS) orelse
        return error.DownloadFailed;
    if (looksLikeZip(body)) return body;
    if (std.mem.startsWith(u8, body, "Error")) return error.ModelUnavailable;
    return error.InvalidCookie;
}

// ── curl transport ────────────────────────────────────────────────

/// GET `url` with browser-like headers (and an optional `connect.sid`
/// cookie), following redirects. Returns the response body, or null on a
/// spawn failure or non-zero exit.
fn httpGet(
    allocator: std.mem.Allocator,
    url: []const u8,
    cookie: ?[]const u8,
    max_bytes: usize,
    timeout_secs: []const u8,
) ?[]u8 {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    argv.appendSlice(allocator, &.{
        "curl", "-sS",      "-L", "--max-time",   timeout_secs,
        "-A",   USER_AGENT, "-H", REFERER_HEADER,
    }) catch return null;
    if (cookie) |c| {
        const cookie_arg = std.fmt.allocPrint(allocator, "{s}{s}", .{ COOKIE_NAME, c }) catch return null;
        argv.appendSlice(allocator, &.{ "-b", cookie_arg }) catch return null;
    }
    argv.append(allocator, url) catch return null;

    const res = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = max_bytes,
    }) catch return null;
    if (res.term != .Exited or res.term.Exited != 0) return null;
    return res.stdout;
}

// ── Pure helpers ──────────────────────────────────────────────────

const HEX = "0123456789ABCDEF";

fn isUnreserved(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
}

/// Percent-encode every non-RFC-3986-unreserved byte. Mirrors Python's
/// `urllib.parse.quote(s, safe="")` — used for query params and path
/// segments alike.
fn percentEncode(allocator: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.appendSlice(allocator, &.{ '%', HEX[c >> 4], HEX[c & 0x0F] });
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
    var out: std.ArrayListUnmanaged(u8) = .empty;
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
