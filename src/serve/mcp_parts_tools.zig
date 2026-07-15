//! Parts-sourcing MCP tool handlers, extracted from `mcp_tools.zig` (which
//! stays the dispatcher): Component Search Engine footprint import + keyword
//! search (`download_footprint` / `search_components`), the two-provider
//! datasheet fetch (`download_datasheet` — CSE first, DigiKey fallback), the
//! DigiKey MPN resolve / stock-and-pricing lookups (`resolve_mpn` /
//! `check_stock`), and `read_datasheet` windowed text extraction. CSE model
//! downloads authenticate via `cse_auth` (HTTP Basic, `CSE_EMAIL` /
//! `CSE_PASSWORD`); the CSE suggestion API and datasheet fetches need no auth;
//! DigiKey uses `DIGIKEY_CLIENT_ID`/`DIGIKEY_CLIENT_SECRET`. All credentials
//! are read server-side, never over MCP.
const std = @import("std");
const json_writer = @import("../json_writer.zig");
const config = @import("../config.zig");
const component_search = @import("component_search.zig");
const cse_auth = @import("cse_auth.zig");
const digikey = @import("digikey.zig");
const upload = @import("upload.zig");
const datasheet = @import("datasheet.zig");
const mcp_tools = @import("mcp_tools.zig");

// Arg parsing + shared JSON keys live with the dispatcher; reused verbatim so
// the handlers behave identically to their pre-extraction selves.
const requireString = mcp_tools.requireString;
const optionalString = mcp_tools.optionalString;
const optionalU64 = mcp_tools.optionalU64;
const missingArg = mcp_tools.missingArg;
const json_description_key = mcp_tools.json_description_key;

// ── Constants ─────────────────────────────────────────────────────
const json_manufacturer_key = ",\"manufacturer\":";
const json_err_open = "{\"ok\":false,\"error\":";
// Shared opening of the part-search envelopes (search_components / resolve_mpn /
// check_stock): `{"ok":true,"query":<q>` then `,"count":N,"results":[`.
const json_ok_query_open = "{\"ok\":true,\"query\":";
const json_count_results_open = ",\"count\":{d},\"results\":[";
const key_part_number = "part_number";
// search_components `limit` arg: default and hard cap.
const search_limit_default: usize = 10;
const search_limit_max: u64 = 50;
// check_stock default is smaller — each result carries full per-packaging price
// ladders, so a handful of exact-ish matches is the useful payload (cap shared).
const stock_limit_default: usize = 5;

/// Fetch a part's ECAD model ZIP from Component Search Engine and run it
/// through the same import pipeline as the `/api/upload-zip` route, creating
/// `lib/{components,footprints,pinouts,models}` entries. The model download uses
/// HTTP Basic auth resolved server-side by `cse_auth` (the `CSE_EMAIL` /
/// `CSE_PASSWORD` account) — credentials are never passed over MCP. Returns the
/// created library names on success, or `{ok:false,error}` if search, download,
/// or import fails.
pub fn toolDownloadFootprint(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const part_number = requireString(args_val, key_part_number) orelse
        return missingArg(out, allocator, key_part_number);
    const manufacturer = optionalString(args_val, "manufacturer");
    const w = out.writer(allocator);

    const auth = (try cse_auth.resolveOrWrite(w, allocator)) orelse return false;

    const dl = component_search.downloadFootprint(allocator, part_number, manufacturer, auth) catch |err| {
        try w.writeAll("{\"ok\":false,\"stage\":\"download\",\"error\":");
        try json_writer.writeString(w, component_search.errorMessage(err));
        try w.writeAll("}");
        return false;
    };

    const imp = upload.importZipBytes(allocator, project_dir, dl.zip_bytes, dl.suggested_filename) catch |err| {
        try w.writeAll("{\"ok\":false,\"stage\":\"import\",\"downloaded\":");
        try json_writer.writeString(w, dl.suggested_filename);
        try w.writeAll(",\"error\":");
        try json_writer.writeString(w, upload.importErrorMessage(err));
        try w.writeAll("}");
        return false;
    };

    try w.writeAll("{\"ok\":true,\"part_name\":");
    try json_writer.writeString(w, dl.part_name);
    try w.writeAll(json_manufacturer_key);
    try json_writer.writeString(w, dl.manufacturer);
    try w.writeAll(",\"samac_id\":");
    try json_writer.writeString(w, dl.samac_id);
    try w.writeAll(",\"zip\":");
    try json_writer.writeString(w, dl.suggested_filename);
    try w.print(",\"zip_size\":{d},\"component\":", .{dl.zip_bytes.len});
    try json_writer.writeString(w, imp.component_name);
    try w.writeAll(",\"footprint\":");
    try json_writer.writeString(w, imp.footprint_name);
    try w.writeAll(",\"pinout\":");
    try json_writer.writeString(w, imp.pinout_name);
    try w.print(",\"has_3d_model\":{s}", .{if (imp.has_3d) "true" else "false"});
    try w.writeAll(",\"component_action\":");
    try json_writer.writeString(w, @tagName(imp.component));
    try w.writeAll("}");
    return true;
}

/// Fetch a part's datasheet PDF and store it under `lib/datasheets/`, where
/// `read_datasheet` can extract its text. Tries Component Search Engine first
/// (the suggestion API's datasheet link + an off-site PDF fetch, both
/// unauthenticated); if CSE has no datasheet on file, falls back to DigiKey's
/// `datasheet_url` (`DIGIKEY_CLIENT_ID` / `DIGIKEY_CLIENT_SECRET`), unwrapping
/// any manufacturer interstitial and validating the `%PDF` magic. DigiKey
/// credentials are read server-side, never over MCP. The success envelope's
/// `source` says which provider supplied it; when both fail,
/// `{ok:false,error,cse_error,digikey_error}`.
pub fn toolDownloadDatasheet(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const part_number = requireString(args_val, key_part_number) orelse
        return missingArg(out, allocator, key_part_number);
    const manufacturer = optionalString(args_val, "manufacturer");
    const w = out.writer(allocator);

    var cse_msg: []const u8 = "";
    switch (try tryCseDatasheet(w, allocator, project_dir, part_number, manufacturer)) {
        .ok => return true,
        .store_failed => return false,
        .unavailable => |m| cse_msg = m,
    }

    var dk_msg: []const u8 = "";
    switch (try tryDigikeyDatasheet(w, allocator, project_dir, part_number, manufacturer)) {
        .ok => return true,
        .store_failed => return false,
        .unavailable => |m| dk_msg = m,
    }

    try w.writeAll(json_err_open);
    try json_writer.writeString(w, "no datasheet found via Component Search Engine or DigiKey");
    try w.writeAll(",\"cse_error\":");
    try json_writer.writeString(w, cse_msg);
    try w.writeAll(",\"digikey_error\":");
    try json_writer.writeString(w, dk_msg);
    try w.writeAll("}");
    return false;
}

/// Outcome of one datasheet provider: `ok`/`store_failed` mean the envelope is
/// already written (success / a terminal store error); `unavailable` carries a
/// reason and means "try the next provider".
const DatasheetOutcome = union(enum) {
    ok,
    store_failed,
    unavailable: []const u8,
};

/// Try Component Search Engine (unauthenticated). `unavailable` when CSE has no
/// datasheet for the part.
fn tryCseDatasheet(
    w: anytype,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    part_number: []const u8,
    manufacturer: ?[]const u8,
) !DatasheetOutcome {
    const ds = component_search.downloadDatasheet(allocator, part_number, manufacturer) catch |err|
        return .{ .unavailable = component_search.datasheetErrorMessage(err) };
    const ok = try finishDatasheet(w, allocator, project_dir, .{
        .source = "componentsearchengine",
        .filename = ds.filename,
        .pdf_bytes = ds.pdf_bytes,
        .part = ds.part_name,
        .manufacturer = ds.manufacturer,
        .url = ds.source_url,
    });
    return if (ok) .ok else .store_failed;
}

/// Try DigiKey's `datasheet_url`. `unavailable` when DigiKey credentials are
/// unset or it has no resolvable datasheet PDF for the part.
fn tryDigikeyDatasheet(
    w: anytype,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    part_number: []const u8,
    manufacturer: ?[]const u8,
) !DatasheetOutcome {
    const client_id = config.digikeyClientId(allocator) orelse
        return .{ .unavailable = "DIGIKEY_CLIENT_ID not set" };
    const client_secret = config.digikeyClientSecret(allocator) orelse
        return .{ .unavailable = "DIGIKEY_CLIENT_SECRET not set" };
    const base: []const u8 = config.digikeyApiBase(allocator) orelse digikey.default_base;
    const ds = digikey.downloadDatasheet(
        allocator,
        base,
        client_id,
        client_secret,
        part_number,
        manufacturer,
    ) catch |err|
        return .{ .unavailable = digikey.datasheetErrorMessage(err) };
    const ok = try finishDatasheet(w, allocator, project_dir, .{
        .source = "digikey",
        .filename = ds.mpn,
        .pdf_bytes = ds.pdf_bytes,
        .part = ds.mpn,
        .manufacturer = ds.manufacturer,
        .url = ds.source_url,
    });
    return if (ok) .ok else .store_failed;
}

/// One provider's fetched datasheet, ready to store: the provider tag, the PDF
/// bytes with their store filename, and the part identity/provenance echoed in
/// the success envelope.
const FetchedDatasheet = struct {
    source: []const u8,
    filename: []const u8,
    pdf_bytes: []const u8,
    part: []const u8,
    manufacturer: []const u8,
    url: []const u8,
};

/// Store a fetched datasheet PDF and emit the success envelope.
fn finishDatasheet(
    w: anytype,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    ds: FetchedDatasheet,
) std.mem.Allocator.Error!bool {
    const upload_datasheet = @import("upload_datasheet.zig");
    const stored = upload_datasheet.storeDatasheet(allocator, project_dir, ds.filename, ds.pdf_bytes) catch |err| {
        // Reuse the HTTP route's error→JSON mapping; null means OutOfMemory.
        try w.writeAll(upload_datasheet.storeErrorBody(err) orelse return error.OutOfMemory);
        return false;
    };
    try w.writeAll("{\"ok\":true,\"source\":");
    try json_writer.writeString(w, ds.source);
    try w.writeAll(",\"file\":");
    try json_writer.writeString(w, stored.name);
    try w.print(",\"size\":{d},\"part\":", .{stored.size});
    try json_writer.writeString(w, ds.part);
    try w.writeAll(json_manufacturer_key);
    try json_writer.writeString(w, ds.manufacturer);
    try w.writeAll(",\"datasheet_url\":");
    try json_writer.writeString(w, ds.url);
    try w.writeAll("}");
    return true;
}

/// Search Component Search Engine and return candidate parts without importing
/// anything — the read-only counterpart to `download_footprint`. The agent
/// searches here, then passes a chosen `part_number` (with the reported
/// `manufacturer` to disambiguate) to download_footprint/download_datasheet.
/// The suggestion API is public, so this needs no CSE credentials. Returns
/// `{ok:true,query,count,results:[{part_number,manufacturer,has_model,has_datasheet}]}`,
/// or `{ok:false,error}` on a network failure.
pub fn toolSearchComponents(
    allocator: std.mem.Allocator,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const query = requireString(args_val, "query") orelse return missingArg(out, allocator, "query");
    const limit: usize = if (optionalU64(args_val, "limit")) |l|
        @intCast(@min(l, search_limit_max))
    else
        search_limit_default;
    const w = out.writer(allocator);

    const hits = component_search.searchComponents(allocator, query, limit) catch |err| {
        try w.writeAll(json_err_open);
        try json_writer.writeString(w, component_search.searchErrorMessage(err));
        try w.writeAll("}");
        return false;
    };

    try w.writeAll(json_ok_query_open);
    try json_writer.writeString(w, query);
    try w.print(json_count_results_open, .{hits.len});
    for (hits, 0..) |h, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"part_number\":");
        try json_writer.writeString(w, h.part_name);
        try w.writeAll(json_manufacturer_key);
        try json_writer.writeString(w, h.manufacturer);
        try w.print(",\"has_model\":{s},\"has_datasheet\":{s}}}", .{
            if (h.samac_id != null) "true" else "false",
            if (h.datasheet_url != null) "true" else "false",
        });
    }
    try w.writeAll("]}");
    return true;
}

/// Resolve a fuzzy query (vague description or partial part number) to real
/// manufacturer part numbers via the DigiKey Product Information API v4 —
/// read-only, imports nothing. Pairs with `search_components` /
/// `download_footprint` / `download_datasheet`: take a returned `mpn` and pass
/// it on. Credentials (`DIGIKEY_CLIENT_ID` / `DIGIKEY_CLIENT_SECRET`, optional
/// `DIGIKEY_API_BASE` for the sandbox) are read server-side, never over MCP.
/// Returns `{ok:true,query,count,results:[{mpn,manufacturer,description,
/// datasheet_url,product_url,digikey_part_number}]}` or `{ok:false,error}`.
pub fn toolResolveMpn(
    allocator: std.mem.Allocator,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const query = requireString(args_val, "query") orelse return missingArg(out, allocator, "query");
    const limit: usize = if (optionalU64(args_val, "limit")) |l|
        @intCast(@min(l, search_limit_max))
    else
        search_limit_default;
    const w = out.writer(allocator);

    const creds = (try digikeyCreds(allocator, w)) orelse return false;
    const products = digikey.resolveMpn(
        allocator,
        creds.base,
        creds.client_id,
        creds.client_secret,
        query,
        limit,
    ) catch |err| {
        try w.writeAll(json_err_open);
        try json_writer.writeString(w, digikey.searchErrorMessage(err));
        try w.writeAll("}");
        return false;
    };

    try w.writeAll(json_ok_query_open);
    try json_writer.writeString(w, query);
    try w.print(json_count_results_open, .{products.len});
    for (products, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"mpn\":");
        try json_writer.writeString(w, p.mpn);
        try w.writeAll(json_manufacturer_key);
        try json_writer.writeString(w, p.manufacturer);
        try w.writeAll(json_description_key);
        try json_writer.writeString(w, p.description);
        try w.writeAll(",\"datasheet_url\":");
        try writeOptString(w, p.datasheet_url);
        try w.writeAll(",\"product_url\":");
        try writeOptString(w, p.product_url);
        try w.writeAll(",\"digikey_part_number\":");
        try writeOptString(w, p.digikey_part_number);
        // At-a-glance stock + price + lifecycle (full ladders via check_stock).
        try w.print(",\"quantity_available\":{d},\"unit_price\":", .{p.quantity_available});
        try writeOptNum(w, p.unit_price);
        try w.writeAll(",\"product_status\":");
        try writeOptString(w, p.product_status);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
    return true;
}

/// Live DigiKey stock + pricing for a known MPN/orderable number. Resolves the
/// query through the same keyword search as `resolve_mpn`, then emits the full
/// per-packaging inventory and quantity price-break ladder for each match — the
/// "is it actually on the shelf, and what does qty-N cost" step. Read-only.
/// Returns `{ok:true,query,count,results:[{mpn,manufacturer,description,
/// product_status,quantity_available,unit_price,product_url,digikey_part_number,
/// variations:[{digikey_part_number,package_type,quantity_available,
/// minimum_order_quantity,price_breaks:[{break_quantity,unit_price,
/// total_price}]}]}]}` or `{ok:false,error}`.
pub fn toolCheckStock(
    allocator: std.mem.Allocator,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const query = requireString(args_val, "query") orelse return missingArg(out, allocator, "query");
    const limit: usize = if (optionalU64(args_val, "limit")) |l|
        @intCast(@min(l, search_limit_max))
    else
        stock_limit_default;
    const w = out.writer(allocator);

    const creds = (try digikeyCreds(allocator, w)) orelse return false;
    const products = digikey.resolveMpn(
        allocator,
        creds.base,
        creds.client_id,
        creds.client_secret,
        query,
        limit,
    ) catch |err| {
        try w.writeAll(json_err_open);
        try json_writer.writeString(w, digikey.searchErrorMessage(err));
        try w.writeAll("}");
        return false;
    };

    try w.writeAll(json_ok_query_open);
    try json_writer.writeString(w, query);
    try w.print(json_count_results_open, .{products.len});
    for (products, 0..) |p, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"mpn\":");
        try json_writer.writeString(w, p.mpn);
        try w.writeAll(json_manufacturer_key);
        try json_writer.writeString(w, p.manufacturer);
        try w.writeAll(json_description_key);
        try json_writer.writeString(w, p.description);
        try w.writeAll(",\"product_status\":");
        try writeOptString(w, p.product_status);
        try w.print(",\"quantity_available\":{d},\"unit_price\":", .{p.quantity_available});
        try writeOptNum(w, p.unit_price);
        try w.writeAll(",\"product_url\":");
        try writeOptString(w, p.product_url);
        try w.writeAll(",\"digikey_part_number\":");
        try writeOptString(w, p.digikey_part_number);
        try w.writeAll(",\"variations\":[");
        for (p.variations, 0..) |v, vi| {
            if (vi > 0) try w.writeAll(",");
            try w.writeAll("{\"digikey_part_number\":");
            try writeOptString(w, v.digikey_part_number);
            try w.writeAll(",\"package_type\":");
            try writeOptString(w, v.package_type);
            try w.print(",\"quantity_available\":{d},\"minimum_order_quantity\":{d},\"price_breaks\":[", .{
                v.quantity_available, v.minimum_order_quantity,
            });
            for (v.price_breaks, 0..) |b, bi| {
                if (bi > 0) try w.writeAll(",");
                try w.print("{{\"break_quantity\":{d},\"unit_price\":{d},\"total_price\":{d}}}", .{
                    b.break_quantity, b.unit_price, b.total_price,
                });
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
    return true;
}

/// DigiKey OAuth credentials + API base, read server-side. On a missing
/// credential this writes the `{ok:false,error}` envelope into `w` and returns
/// null, so a caller does `(try digikeyCreds(a, w)) orelse return false;`.
const DigiKeyCreds = struct { client_id: []u8, client_secret: []u8, base: []const u8 };
fn digikeyCreds(allocator: std.mem.Allocator, w: anytype) !?DigiKeyCreds {
    const client_id = config.digikeyClientId(allocator) orelse {
        try w.writeAll("{\"ok\":false,\"error\":\"DIGIKEY_CLIENT_ID is not set on the server; add it to .env\"}");
        return null;
    };
    const client_secret = config.digikeyClientSecret(allocator) orelse {
        try w.writeAll("{\"ok\":false,\"error\":\"DIGIKEY_CLIENT_SECRET is not set on the server; add it to .env\"}");
        return null;
    };
    return .{
        .client_id = client_id,
        .client_secret = client_secret,
        .base = config.digikeyApiBase(allocator) orelse digikey.default_base,
    };
}

/// Emit a JSON string, or `null` when the optional is absent.
fn writeOptString(w: anytype, s: ?[]const u8) !void {
    if (s) |v| {
        try json_writer.writeString(w, v);
    } else {
        try w.writeAll("null");
    }
}

/// Emit a JSON number (decimal, never scientific), or `null` when absent.
fn writeOptNum(w: anytype, n: ?f64) !void {
    if (n) |v| {
        try w.print("{d}", .{v});
    } else {
        try w.writeAll("null");
    }
}

/// Read a window of a stored datasheet's extracted text — the read-side twin
/// of `download_datasheet`.
pub fn toolReadDatasheet(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const raw_name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const offset = optionalU64(args_val, "offset");
    const limit = optionalU64(args_val, "limit");
    return datasheet.read(allocator, project_dir, raw_name, offset, limit, out);
}

// ── Tests ─────────────────────────────────────────────────────────

test "finishDatasheet returns false when the store rejects the bytes" {
    // spec: serve/mcp_tools - finishDatasheet returns false when the store rejects the bytes
    // The `return false` after a store failure must signal failure; a
    // `false`->`true` flip would report success on a rejected datasheet.
    // Non-PDF bytes make storeDatasheet fail with NotPdf before any write.
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    const w = out.writer(alloc);
    const ok = try finishDatasheet(w, alloc, "/proj", .{
        .source = "digikey",
        .filename = "x.pdf",
        .pdf_bytes = "not a pdf",
        .part = "PART",
        .manufacturer = "MFR",
        .url = "url",
    });
    try std.testing.expect(!ok);
}
