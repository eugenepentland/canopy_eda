//! Datasheet acquisition and text extraction for the `fetch_datasheet` /
//! `read_datasheet` CLI tools.
//!
//! `fetch` is the URL half: an agent that has found a manufacturer PDF link
//! points this at it and the bytes land in `lib/datasheets/<sanitized>.pdf`,
//! ready for `read_datasheet` and for a `(datasheet "…")` declaration. It is
//! deliberately narrow — it writes ONLY into that directory, never into a
//! design source — and it is content-sniffed (`%PDF` magic, not a
//! `Content-Type` header), byte- and time-bounded, and refuses to replace an
//! existing file whose bytes DIFFER, because every `(datasheet-review …)`
//! record cites a sha256 that a silent overwrite would invalidate. Re-fetching
//! the same bytes is a no-op that reports the same digest, so the campaign
//! that attaches datasheets across a board can re-run safely.
//!
//! ps2ascii is a `/bin/sh` wrapper around `gs`, which streams the extracted
//! text straight to stdout. On a real (multi-hundred-KB) datasheet that output
//! can wedge the stdout pipe, so extraction goes through
//! `subprocess.runCaptured`, which drains both pipes concurrently, caps the
//! output, and kills the whole process group on timeout. The result is cached
//! as a `<stem>.txt` sidecar so repeat reads never re-shell out, and
//! offset/limit window the response — a full datasheet is far too large to
//! hand an agent in one blob.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const log = @import("../infra/log.zig");
const upload_datasheet = @import("upload_datasheet.zig");
const datasheet_ref = @import("datasheet_ref.zig");
const subprocess = @import("subprocess.zig");
const AllocatingWriter = @import("../allocating_writer.zig").AllocatingWriter;

/// Extracted-text byte cap (also the sidecar read ceiling).
const max_output_bytes: usize = 8 * 1024 * 1024;
/// Hard wall-clock ceiling for one ps2ascii run before its group is killed.
const extract_timeout_ms: u64 = 45_000;
/// Bytes returned when the caller gives no explicit `limit`.
const default_limit: u64 = 20_000;
/// Upper bound for hashing the source PDF returned as review identity.
const max_pdf_bytes: usize = 256 * 1024 * 1024;

const Loaded = struct {
    /// Owned extracted text, or null on failure.
    text: ?[]const u8 = null,
    /// Static failure message, set when `text` is null.
    err: []const u8 = "",
};

const Window = struct {
    slice: []const u8,
    total: usize,
    offset: usize,
    truncated: bool,
};

/// Resolve datasheet `name` under lib/datasheets/, extract (or read the cached)
/// text, and write a windowed JSON result to `out`. Returns false — after
/// writing the `{"ok":false,"error":…}` object — on any failure, true on
/// success. Never blocks unboundedly: extraction is time- and size-bounded.
pub fn read(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    offset: ?u64,
    limit: ?u64,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };

    const sanitized = upload_datasheet.sanitizeFilename(allocator, name) catch |e| {
        try w.print("{{\"ok\":false,\"error\":\"invalid name: {s}\"}}", .{@errorName(e)});
        return false;
    };
    defer allocator.free(sanitized);

    const pdf_path = try std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, sanitized });
    defer allocator.free(pdf_path);
    infra_fs.cwd().access(pdf_path, .{}) catch {
        try w.writeAll("{\"ok\":false,\"error\":\"datasheet not found\"}");
        return false;
    };
    const pdf = infra_fs.cwd().readFileAlloc(allocator, pdf_path, max_pdf_bytes) catch {
        try w.writeAll("{\"ok\":false,\"error\":\"datasheet cannot be hashed\"}");
        return false;
    };
    defer allocator.free(pdf);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pdf, &digest, .{});
    const sha256 = std.fmt.bytesToHex(digest, .lower);

    // Cache sidecar: <stem>.txt — sanitizeFilename guarantees a .pdf suffix.
    const stem = sanitized[0 .. sanitized.len - ".pdf".len];
    const txt_path = try std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}.txt", .{ project_dir, stem });
    defer allocator.free(txt_path);

    const loaded = try loadText(allocator, pdf_path, txt_path);
    if (loaded.text == null) {
        try w.print("{{\"ok\":false,\"error\":\"{s}\"}}", .{loaded.err});
        return false;
    }
    const text = loaded.text.?;
    defer allocator.free(text);

    return writeResult(w, sanitized, &sha256, window(text, offset, limit)) catch return error.OutOfMemory;
}

/// Return the datasheet's extracted text (owned) from the fresh sidecar cache
/// when available, else by running ps2ascii under `subprocess.runCaptured` and
/// caching the result. Failures are reported via `Loaded.err`.
fn loadText(allocator: std.mem.Allocator, pdf_path: []const u8, txt_path: []const u8) !Loaded {
    if (cacheFresh(pdf_path, txt_path)) {
        const cached: ?[]const u8 = infra_fs.cwd().readFileAlloc(allocator, txt_path, max_output_bytes) catch null;
        if (cached) |c| return .{ .text = c };
    }

    var res = try subprocess.runCaptured(
        allocator,
        &[_][]const u8{ "ps2ascii", pdf_path },
        max_output_bytes,
        extract_timeout_ms,
    );
    defer res.deinit(allocator);

    const outcome_err = extractError(res);
    if (outcome_err.len != 0) return .{ .err = outcome_err };

    const text = try allocator.dupe(u8, res.stdout);
    writeSidecar(txt_path, text); // best-effort cache; ignore failures
    return .{ .text = text };
}

/// Map a non-success extraction to a stable error message, or "" on success.
/// An if/else chain (not a switch) keeps the Outcome enum single-switched.
fn extractError(res: subprocess.Result) []const u8 {
    if (res.outcome == .timed_out) return "ps2ascii timed out extracting the datasheet";
    if (res.outcome == .output_too_long) return "datasheet text exceeds the extraction size limit";
    if (res.outcome == .spawn_failed) return "failed to run ps2ascii";
    if (res.exit_code != @as(?u8, 0)) return "ps2ascii returned an error";
    return "";
}

/// True when the sidecar exists and is at least as new as the source PDF.
fn cacheFresh(pdf_path: []const u8, txt_path: []const u8) bool {
    const txt_stat = infra_fs.cwd().statFile(txt_path) catch return false;
    const pdf_stat = infra_fs.cwd().statFile(pdf_path) catch return false;
    return txt_stat.mtime.nanoseconds >= pdf_stat.mtime.nanoseconds;
}

/// Best-effort write of the extraction cache; failure just means no cache, so
/// a read-only filesystem still returns the extracted text.
fn writeSidecar(txt_path: []const u8, text: []const u8) void {
    const file = infra_fs.cwd().createFile(txt_path, .{}) catch return;
    defer file.close();
    file.writeAll(text) catch |e|
        log.warn("datasheet: cache write failed: {s}", .{@errorName(e)});
}

/// Clamp `offset`/`limit` to `text` and report the windowed slice plus enough
/// metadata (total size, truncation) for the caller to page through.
fn window(text: []const u8, offset: ?u64, limit: ?u64) Window {
    const off: usize = if (offset) |o| @intCast(@min(o, text.len)) else 0;
    const want: u64 = @as(u64, off) + (limit orelse default_limit);
    const end: usize = @intCast(@min(want, text.len));
    return .{
        .slice = text[off..end],
        .total = text.len,
        .offset = off,
        .truncated = end < text.len,
    };
}

fn writeResult(w: anytype, name: []const u8, sha256: []const u8, win: Window) !bool {
    try w.writeAll("{\"ok\":true,\"name\":");
    try json_writer.writeString(w, name);
    try w.writeAll(",\"sha256\":");
    try json_writer.writeString(w, sha256);
    try w.print(",\"total_bytes\":{d},\"offset\":{d},\"returned_bytes\":{d},\"truncated\":{s},\"content\":", .{
        win.total, win.offset, win.slice.len, if (win.truncated) "true" else "false",
    });
    try json_writer.writeString(w, win.slice);
    try w.writeAll("}");
    return true;
}

// ── Fetch (`fetch_datasheet`) ─────────────────────────────────────

/// Byte ceiling for one fetched PDF — the same 64 MiB the upload route and the
/// CSE / DigiKey downloaders accept, so every way a datasheet can enter
/// `lib/datasheets/` shares one size policy.
const max_download_bytes: usize = 64 * 1024 * 1024;
/// Hard wall-clock ceiling for one fetch, in milliseconds and in curl's own
/// seconds spelling. Slow vendor CDNs are common; a wedged one is not waited on.
const download_timeout_ms: u64 = 90_000;
const download_timeout_secs = "90";
/// curl's own size guard, so an oversized body is abandoned at the socket
/// rather than after `runCaptured` has buffered 64 MiB of it.
const max_filesize_arg = "67108864";
/// Vendor download pages routinely 403 a default curl UA.
const browser_ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) " ++
    "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36";
/// Fallback stem when the URL's last path segment is empty (a directory-style
/// link). `sanitizeFilename` appends the `.pdf`.
const fallback_name = "datasheet";

/// One transport attempt: the retrieved bytes (owned by the caller's
/// allocator) or a stable failure message when nothing came back.
pub const Fetched = struct {
    bytes: []const u8 = "",
    err: []const u8 = "",
};

/// The HTTP transport seam. Production passes `curlFetch`; tests pass a stub,
/// so no unit test ever opens a socket.
pub const Transport = *const fn (std.mem.Allocator, []const u8, ?[]const u8) std.mem.Allocator.Error!Fetched;

/// A `fetch_datasheet` request.
pub const FetchRequest = struct {
    /// Absolute HTTP(S) URL of the PDF, validated by `datasheet_ref.isRemote`.
    url: []const u8,
    /// Target filename under `lib/datasheets/`; null derives one from the URL.
    name: ?[]const u8 = null,
    /// Optional manufacturer product page sent as the HTTP Referer. Some
    /// vendor download endpoints reject an otherwise direct PDF request
    /// unless it came from that page.
    source_page: ?[]const u8 = null,
    /// Replace an existing file whose bytes DIFFER. Off by default: a
    /// same-name/different-content fetch is refused rather than silently
    /// invalidating the sha256 every `(datasheet-review …)` citing it records.
    overwrite: bool = false,
    /// How the bytes are retrieved.
    transport: Transport = curlFetch,
};

/// Download `req.url` into `<project_dir>/lib/datasheets/<sanitized name>` and
/// write the JSON result to `out`. Returns true after an `{"ok":true,…}`
/// envelope carrying `{name, sha256, bytes, status}`; false after an
/// `{"ok":false,"error":…}` one. Never writes outside `lib/datasheets/`.
pub fn fetch(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    req: FetchRequest,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };

    if (!datasheet_ref.isRemote(req.url)) {
        try writeFetchError(w, "url must be an absolute http(s) URL with no spaces or control characters");
        return false;
    }
    if (req.source_page) |source_page| {
        if (!datasheet_ref.isRemote(source_page)) {
            try writeFetchError(w, "source_page must be an absolute http(s) URL with no spaces or control characters");
            return false;
        }
    }
    const sanitized = upload_datasheet.sanitizeFilename(allocator, req.name orelse nameFromUrl(req.url)) catch {
        try writeFetchError(w, "invalid target filename");
        return false;
    };
    defer allocator.free(sanitized);

    const got = try req.transport(allocator, req.url, req.source_page);
    defer if (got.bytes.len != 0) allocator.free(got.bytes);
    if (got.err.len != 0) {
        try writeFetchError(w, got.err);
        return false;
    }
    if (!upload_datasheet.isPdfMagic(got.bytes)) {
        try writeNotPdf(w, got.bytes.len);
        return false;
    }
    return storeFetched(w, allocator, project_dir, sanitized, got.bytes, req.overwrite);
}

/// Write `bytes` to `lib/datasheets/<name>`, honouring the overwrite policy,
/// and emit the result envelope. Split out so the whole store/idempotence/
/// conflict policy is unit-testable without a transport.
fn storeFetched(
    w: AllocatingWriter,
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    bytes: []const u8,
    overwrite: bool,
) std.mem.Allocator.Error!bool {
    const sha256 = hexDigest(bytes);
    const path = try std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, name });
    defer allocator.free(path);

    if (try existingDigest(allocator, path)) |existing| {
        if (std.mem.eql(u8, &existing, &sha256)) return writeFetchResult(w, name, &sha256, bytes.len, "unchanged");
        if (!overwrite) {
            try writeConflict(w, name, &existing, &sha256);
            return false;
        }
    }
    const stored = upload_datasheet.storeDatasheet(allocator, project_dir, name, bytes) catch |err| {
        try w.writeAll(upload_datasheet.storeErrorBody(err) orelse return error.OutOfMemory);
        return false;
    };
    defer allocator.free(stored.name);
    return writeFetchResult(w, stored.name, &sha256, stored.size, "written");
}

/// Lowercase hex sha256 of `bytes`.
fn hexDigest(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Hex digest of the file already at `path`, or null when there is none (or it
/// cannot be read — an unreadable file is treated as absent and the store step
/// reports the real write failure).
fn existingDigest(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!?[64]u8 {
    const old = infra_fs.cwd().readFileAlloc(allocator, path, max_pdf_bytes) catch return null;
    defer allocator.free(old);
    return hexDigest(old);
}

/// Derive a filename from `url`'s last path segment, dropping any query or
/// fragment (vendor links routinely append `?ts=…`). `sanitizeFilename` then
/// whitelists it and forces the `.pdf` suffix.
fn nameFromUrl(url: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    const scheme = std.mem.indexOf(u8, url[0..end], "://") orelse return fallback_name;
    // Search inside the authority only, so a scheme-relative host with no path
    // (`https://ti.com`) falls back instead of naming the file after the host.
    const authority = url[scheme + "://".len .. end];
    const slash = std.mem.lastIndexOfAny(u8, authority, "/") orelse return fallback_name;
    const segment = authority[slash + 1 ..];
    return if (segment.len == 0) fallback_name else segment;
}

/// Retrieve `url` with the system curl, following redirects, bounded in bytes
/// and wall-clock. `--` ends option parsing so a `-`-leading URL can never be
/// reinterpreted as a flag; `fetch` has already whitelisted the URL's bytes.
/// curl rather than `std.http.Client` because TLS, redirect chains and vendor
/// CDNs are exactly what the system client already handles for every other
/// off-site fetch in this tree (CSE, DigiKey), and `runCaptured` gives it the
/// timeout + process-group kill that a wedged download needs.
fn curlFetch(allocator: std.mem.Allocator, url: []const u8, source_page: ?[]const u8) std.mem.Allocator.Error!Fetched {
    const res = if (source_page) |referer|
        try subprocess.runCaptured(allocator, &[_][]const u8{
            "curl",                "-sS",
            "-L",                  "--max-time",
            download_timeout_secs, "--max-filesize",
            max_filesize_arg,      "-e",
            referer,               "--",
            url,
        }, max_download_bytes, download_timeout_ms)
    else
        try subprocess.runCaptured(allocator, &[_][]const u8{
            "curl",                "-sS",
            "-L",                  "--max-time",
            download_timeout_secs, "--max-filesize",
            max_filesize_arg,      "-A",
            browser_ua,            "--",
            url,
        }, max_download_bytes, download_timeout_ms);
    if (res.outcome != .ok) {
        res.deinit(allocator);
        return .{ .err = transportError(res.outcome) };
    }
    if (res.exit_code != @as(?u8, 0)) {
        res.deinit(allocator);
        return .{ .err = "curl could not retrieve the URL (network error, TLS failure, or HTTP error status)" };
    }
    return .{ .bytes = res.stdout };
}

/// Stable message for a non-`ok` subprocess outcome.
fn transportError(outcome: subprocess.Outcome) []const u8 {
    if (outcome == .timed_out) return "the download timed out";
    if (outcome == .output_too_long) return "the download exceeds the 64 MiB datasheet size limit";
    return "failed to run curl";
}

/// `{"ok":false,"error":…}` for a fetch failure.
fn writeFetchError(w: AllocatingWriter, message: []const u8) std.mem.Allocator.Error!void {
    try w.writeAll("{\"ok\":false,\"error\":");
    json_writer.writeString(w, message) catch return error.OutOfMemory;
    try w.writeAll("}");
}

/// Refusal for bytes that are not a PDF. Content sniffing, not `Content-Type`:
/// a vendor login wall or cookie interstitial answers 200 with `text/html` or
/// even `application/pdf`, and only the magic bytes tell them apart.
fn writeNotPdf(w: AllocatingWriter, bytes: usize) std.mem.Allocator.Error!void {
    try w.print(
        "{{\"ok\":false,\"error\":\"the URL returned {d} bytes with no %PDF header" ++
            " (an HTML interstitial or login wall, not a datasheet)\"}}",
        .{bytes},
    );
}

/// Refusal for a same-name fetch whose bytes differ from the stored file.
fn writeConflict(
    w: AllocatingWriter,
    name: []const u8,
    existing: []const u8,
    fetched: []const u8,
) std.mem.Allocator.Error!void {
    try w.writeAll("{\"ok\":false,\"error\":\"a different file is already stored under this name;" ++
        " pass overwrite:true to replace it, or choose another name\",\"name\":");
    json_writer.writeString(w, name) catch return error.OutOfMemory;
    try w.writeAll(",\"existing_sha256\":");
    json_writer.writeString(w, existing) catch return error.OutOfMemory;
    try w.writeAll(",\"sha256\":");
    json_writer.writeString(w, fetched) catch return error.OutOfMemory;
    try w.writeAll("}");
}

/// `{"ok":true,…}` for a stored (or already-identical) datasheet.
fn writeFetchResult(
    w: AllocatingWriter,
    name: []const u8,
    sha256: []const u8,
    bytes: usize,
    status: []const u8,
) std.mem.Allocator.Error!bool {
    try w.writeAll("{\"ok\":true,\"name\":");
    json_writer.writeString(w, name) catch return error.OutOfMemory;
    try w.writeAll(",\"sha256\":");
    json_writer.writeString(w, sha256) catch return error.OutOfMemory;
    try w.print(",\"bytes\":{d},\"status\":", .{bytes});
    json_writer.writeString(w, status) catch return error.OutOfMemory;
    try w.writeAll("}");
    return true;
}

// ── Tests ─────────────────────────────────────────────────────────

test "window clamps offset and limit and flags truncation" {
    // spec: serve/datasheet - window clamps offset and limit to the text and flags truncation
    const text = "0123456789";
    // A limit shorter than the remaining text truncates.
    const mid = window(text, 2, 3);
    try std.testing.expectEqualStrings("234", mid.slice);
    try std.testing.expectEqual(@as(usize, 10), mid.total);
    try std.testing.expectEqual(@as(usize, 2), mid.offset);
    try std.testing.expect(mid.truncated);
    // An offset past the end clamps to len → empty and not truncated.
    const past = window(text, 100, 5);
    try std.testing.expectEqualStrings("", past.slice);
    try std.testing.expectEqual(@as(usize, 10), past.offset);
    try std.testing.expect(!past.truncated);
    // A limit reaching the end is not truncated.
    const tail = window(text, 5, 100);
    try std.testing.expectEqualStrings("56789", tail.slice);
    try std.testing.expect(!tail.truncated);
}

/// Stub transport: a minimal but real PDF. sha256 94b8f2a1…02a0 (verified
/// against `sha256sum` outside the tree, so the assertion is independent of
/// `hexDigest`).
fn stubPdf(allocator: std.mem.Allocator, url: []const u8, source_page: ?[]const u8) std.mem.Allocator.Error!Fetched {
    _ = url;
    _ = source_page;
    return .{ .bytes = try allocator.dupe(u8, "%PDF-1.7\nstub datasheet\n") };
}

/// Stub transport: a different, equally valid PDF. sha256 f448092d…a634.
fn stubOtherPdf(allocator: std.mem.Allocator, url: []const u8, source_page: ?[]const u8) std.mem.Allocator.Error!Fetched {
    _ = url;
    _ = source_page;
    return .{ .bytes = try allocator.dupe(u8, "%PDF-1.7\nDIFFERENT datasheet\n") };
}

/// Stub transport: what a login wall or cookie interstitial actually serves.
fn stubHtml(allocator: std.mem.Allocator, url: []const u8, source_page: ?[]const u8) std.mem.Allocator.Error!Fetched {
    _ = url;
    _ = source_page;
    return .{ .bytes = try allocator.dupe(u8, "<!doctype html><title>Sign in</title>") };
}

fn stubReferrerPdf(allocator: std.mem.Allocator, url: []const u8, source_page: ?[]const u8) std.mem.Allocator.Error!Fetched {
    _ = url;
    if (!std.mem.eql(u8, source_page orelse "", "https" ++ "://vendor.invalid/product"))
        return .{ .err = "missing source page" };
    return .{ .bytes = try allocator.dupe(u8, "%PDF-1.7\nreferrer-gated datasheet\n") };
}

const stub_pdf_sha = "94b8f2a1a771cb19c88ad2fa269c58f20a50a9cb6183ab05d0ea71700c7802a0";
const stub_other_sha = "f448092d256efb8663458bd7f2422438294740216be383811f29e492492fa634";

/// Run one `fetch` against a scratch project dir, returning the JSON envelope
/// (caller owns). Keeps the tests free of the tmp-dir boilerplate.
fn fetchInto(allocator: std.mem.Allocator, root: []const u8, req: FetchRequest) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    _ = try fetch(allocator, root, req, &out);
    return out.toOwnedSlice(allocator);
}

// spec: serve/datasheet - fetch_datasheet stores a fetched PDF under a sanitized lib/datasheets name and reports its sha256 and byte count
test "fetch stores a PDF under a sanitized name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    // The URL's last segment carries a query and unsafe bytes; the stored name
    // is whitelisted and forced to .pdf, and nothing escapes lib/datasheets/.
    const body = try fetchInto(std.testing.allocator, root, .{
        .url = "https" ++ "://example.invalid/lit/ds/lm;66100(1).pdf?ts=17",
        .transport = stubPdf,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"lm_66100.pdf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"sha256\":\"" ++ stub_pdf_sha ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"bytes\":24") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"status\":\"written\"") != null);

    const stored = try tmp.dir.readFileAlloc(std.testing.io, "lib/datasheets/lm_66100.pdf", std.testing.allocator, .limited64(1024));
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualStrings("%PDF-1.7\nstub datasheet\n", stored);
}

// spec: serve/datasheet - a fetched Mini-Circuits filename keeps its trailing `+` and read_datasheet resolves that exact stored name
test "fetch then read round-trips a name containing a plus" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const body = try fetchInto(std.testing.allocator, root, .{
        .url = "https" ++ "://example.invalid/pdfs/YAT-0A+.pdf",
        .transport = stubPdf,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"YAT-0A+.pdf\"") != null);
    // The bytes really landed under the `+` name, not a folded one.
    const stored = try tmp.dir.readFileAlloc(std.testing.io, "lib/datasheets/YAT-0A+.pdf", std.testing.allocator, .limited64(1024));
    defer std.testing.allocator.free(stored);
    try std.testing.expectEqualStrings("%PDF-1.7\nstub datasheet\n", stored);

    // `read` sanitizes its own argument, so the round trip is what proves the
    // two halves agree. Extraction needs ps2ascii, which a test host may not
    // have: assert that resolution got PAST the name — a found file reports its
    // digest or an extraction failure, never "datasheet not found".
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    _ = try read(std.testing.allocator, root, "YAT-0A+.pdf", null, null, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "datasheet not found") == null);

    // A name that never was stored still resolves to the honest miss.
    var missing: std.ArrayList(u8) = .empty;
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(!try read(std.testing.allocator, root, "YAT-0B+.pdf", null, null, &missing));
    try std.testing.expect(std.mem.indexOf(u8, missing.items, "datasheet not found") != null);
}

// spec: serve/datasheet - fetch_datasheet re-fetching identical bytes is idempotent and reports the unchanged digest
test "fetch is idempotent for identical bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const req: FetchRequest = .{ .url = "https" ++ "://example.invalid/lt3045.pdf", .transport = stubPdf };

    const first = try fetchInto(std.testing.allocator, root, req);
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"status\":\"written\"") != null);

    const second = try fetchInto(std.testing.allocator, root, req);
    defer std.testing.allocator.free(second);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"status\":\"unchanged\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"sha256\":\"" ++ stub_pdf_sha ++ "\"") != null);
}

// spec: serve/datasheet - fetch_datasheet refuses to replace a stored datasheet whose bytes differ unless overwrite is requested
test "fetch refuses a silent overwrite of different bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const url = "https" ++ "://example.invalid/lt3045.pdf";

    const first = try fetchInto(std.testing.allocator, root, .{ .url = url, .transport = stubPdf });
    defer std.testing.allocator.free(first);

    const clash = try fetchInto(std.testing.allocator, root, .{ .url = url, .transport = stubOtherPdf });
    defer std.testing.allocator.free(clash);
    try std.testing.expect(std.mem.indexOf(u8, clash, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, clash, "\"existing_sha256\":\"" ++ stub_pdf_sha ++ "\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, clash, "\"sha256\":\"" ++ stub_other_sha ++ "\"") != null);
    // The refusal left the stored bytes alone.
    const kept = try tmp.dir.readFileAlloc(std.testing.io, "lib/datasheets/lt3045.pdf", std.testing.allocator, .limited64(1024));
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("%PDF-1.7\nstub datasheet\n", kept);

    // overwrite:true is the explicit opt-in and does replace them.
    const forced = try fetchInto(std.testing.allocator, root, .{ .url = url, .transport = stubOtherPdf, .overwrite = true });
    defer std.testing.allocator.free(forced);
    try std.testing.expect(std.mem.indexOf(u8, forced, "\"status\":\"written\"") != null);
    const replaced = try tmp.dir.readFileAlloc(std.testing.io, "lib/datasheets/lt3045.pdf", std.testing.allocator, .limited64(1024));
    defer std.testing.allocator.free(replaced);
    try std.testing.expectEqualStrings("%PDF-1.7\nDIFFERENT datasheet\n", replaced);
}

// spec: serve/datasheet - fetch_datasheet content-sniffs the %PDF magic and rejects a non-PDF body and any non-http(s) URL without writing
test "fetch rejects non-PDF bodies and non-http URLs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const html = try fetchInto(std.testing.allocator, root, .{ .url = "https" ++ "://example.invalid/x.pdf", .transport = stubHtml });
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "%PDF header") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "lib/datasheets/x.pdf", .{}));

    // A non-http scheme never reaches the transport at all.
    const scheme = try fetchInto(std.testing.allocator, root, .{ .url = "file:///etc/passwd", .transport = stubPdf });
    defer std.testing.allocator.free(scheme);
    try std.testing.expect(std.mem.indexOf(u8, scheme, "absolute http(s) URL") != null);
}

// spec: serve/datasheet - fetch_datasheet accepts a validated manufacturer source_page and forwards it as the HTTP Referer for product-gated PDF endpoints
test "fetch forwards a validated source page to the transport" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const body = try fetchInto(std.testing.allocator, root, .{
        .url = "https" ++ "://vendor.invalid/download.pdf",
        .source_page = "https" ++ "://vendor.invalid/product",
        .transport = stubReferrerPdf,
    });
    defer std.testing.allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ok\":true") != null);

    const rejected = try fetchInto(std.testing.allocator, root, .{
        .url = "https" ++ "://vendor.invalid/download.pdf",
        .source_page = "file:///tmp/product",
        .transport = stubReferrerPdf,
    });
    defer std.testing.allocator.free(rejected);
    try std.testing.expect(std.mem.indexOf(u8, rejected, "source_page must be an absolute http(s) URL") != null);
}

// spec: serve/datasheet - fetch_datasheet derives its target name from the URL path segment, dropping query and fragment
test "nameFromUrl drops query and fragment" {
    try std.testing.expectEqualStrings("lm66100.pdf", nameFromUrl("https" ++ "://ti.com/lit/ds/lm66100.pdf?ts=1#page=3"));
    try std.testing.expectEqualStrings("datasheet", nameFromUrl("https" ++ "://ti.com/lit/ds/"));
    try std.testing.expectEqualStrings("datasheet", nameFromUrl("https" ++ "://ti.com"));
}

// spec: serve/datasheet - read_datasheet result exposes the current PDF digest for datasheet-review provenance
test "writeResult includes sha256 identity" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    _ = try writeResult(&out.writer, "part.pdf", sha, window("abc", null, null));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"sha256\":\"0123456789abcdef") != null);
}
