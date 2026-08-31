//! Datasheet (PDF) upload, listing, and serving: validates the PDF magic
//! bytes, sanitizes the filename (traversal-safe), and stores the file under
//! the project datasheet dir. `StoreError` maps to the HTTP status returned.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const datasheet_ref = @import("datasheet_ref.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    infra_fs.File.WriteError || infra_fs.File.OpenError || infra_fs.File.ReadError ||
    infra_fs.Dir.MakeError || infra_fs.Dir.StatFileError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, InvalidEscapeSequence, ReadOnlyFileSystem, LinkQuotaExceeded };

/// True iff the buffer starts with the four `%PDF` magic bytes — gates
/// every datasheet write so the HTTP route can't accept arbitrary content
/// into `lib/datasheets/<name>.pdf`. Kept public so future binary-write
/// callers (if any) can share the same gate as `/api/upload-datasheet`.
pub fn isPdfMagic(body: []const u8) bool {
    return body.len >= 4 and std.mem.eql(u8, body[0..4], "%PDF");
}

/// Filename-validation errors. `InvalidName` covers empty / single-dot /
/// double-dot inputs and any path-component-only smuggling attempts.
pub const SanitizeError = error{ InvalidName, OutOfMemory };

/// Strip a trailing OS/browser duplicate-download marker — a parenthesised
/// counter like ` (1)`, `(2)`, `_(3)` — from a filename stem (no extension).
/// This is what produces stale `tps55289 (1).pdf` second copies; normalising it
/// away makes a re-download/re-upload land on the same canonical name and
/// overwrite, instead of creating a divergent file the component never links.
/// A stem that merely ends in digits (`lm2596`) is left untouched — only a
/// parenthesised counter is removed.
fn stripDuplicateMarker(stem: []const u8) []const u8 {
    if (stem.len < 3 or stem[stem.len - 1] != ')') return stem;
    const open = std.mem.lastIndexOfScalar(u8, stem, '(') orelse return stem;
    const inner = stem[open + 1 .. stem.len - 1];
    if (inner.len == 0) return stem;
    for (inner) |c| if (c < '0' or c > '9') return stem;
    return std.mem.trimEnd(u8, stem[0..open], " _");
}

/// The one whitelist of bytes a stored datasheet filename may contain.
///
/// `+` is DATA, not an option or a separator. Mini-Circuits part numbers end in
/// one (`YAT-0A+`, `TSY-83LNW+`), and folding it to `_` on the way in made the
/// file unreadable on the way out: `read_datasheet "TSY-83LNW+.pdf"` sanitized
/// its own argument to `TSY-83LNW_.pdf` and reported "datasheet not found" for
/// a file sitting on disk. It is safe in every consumer: the name only ever
/// becomes a `lib/datasheets/<name>` path (no separator, no `..`, and never
/// leading — the stem always carries a real character before it), and the
/// ps2ascii extraction passes that path as an argv element, never through a
/// shell. Everything outside this set still collapses to `_`.
///
/// Kept in step with `datasheet_ref.isLocal`, which validates the same names
/// coming from a `(datasheet "…")` declaration — a name this function can WRITE
/// but that one rejects is the same round-trip bug in a different surface.
fn nameByte(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return c == '_' or c == '-' or c == '.' or c == '+';
}

/// Conservative filename whitelist for `lib/datasheets/`. Drops any path
/// component the client tried to smuggle in, strips a duplicate-download
/// marker (`foo (1).pdf` → `foo.pdf`), replaces every byte `nameByte` rejects
/// with `_`, and forces a trailing `.pdf`. Caller owns the returned slice.
/// Used by both transports — kept here so the policy is one-place.
pub fn sanitizeFilename(allocator: std.mem.Allocator, raw: []const u8) SanitizeError![]u8 {
    if (raw.len == 0) return error.InvalidName;
    // Drop any path component the client tried to smuggle in.
    const base = blk: {
        if (std.mem.lastIndexOfAny(u8, raw, "/\\")) |idx| break :blk raw[idx + 1 ..];
        break :blk raw;
    };
    if (base.len == 0 or std.mem.eql(u8, base, "..") or std.mem.eql(u8, base, ".")) return error.InvalidName;

    // Normalise a duplicate-download marker on the stem before whitelisting,
    // while the original ` (1)` form is still intact (whitelisting would
    // otherwise turn it into the opaque `__1_` that no dedupe recognises).
    const had_pdf = std.ascii.endsWithIgnoreCase(base, ".pdf");
    const stem = if (had_pdf) base[0 .. base.len - 4] else base;
    const cleaned = stripDuplicateMarker(stem);

    var out: std.ArrayList(u8) = .empty;
    for (cleaned) |c| {
        try out.append(allocator, if (nameByte(c)) c else '_');
    }
    if (out.items.len == 0) return error.InvalidName;

    if (!std.mem.endsWith(u8, out.items, ".pdf")) {
        try out.appendSlice(allocator, ".pdf");
    }
    return out.toOwnedSlice(allocator);
}

/// Errors from `storeDatasheet`. `NotPdf` and `InvalidName` map to HTTP 400;
/// `WriteFailed` to 500. The CLI tool maps them to `{"ok":false,"error":…}`.
pub const StoreError = error{ NotPdf, InvalidName, WriteFailed, OutOfMemory };

/// JSON body for a store error, ready to embed in a response. `null` for
/// `OutOfMemory` — the caller must propagate that one. Centralises the
/// error → message mapping so HTTP and structured CLI callers stay in sync.
pub fn storeErrorBody(e: StoreError) ?[]const u8 {
    return switch (e) {
        error.NotPdf => "{\"ok\":false,\"error\":\"not a PDF (missing %PDF header)\"}",
        error.InvalidName => "{\"ok\":false,\"error\":\"invalid filename\"}",
        error.WriteFailed => "{\"ok\":false,\"error\":\"write failed\"}",
        error.OutOfMemory => null,
    };
}

/// HTTP status code for a store error. 400 for client mistakes, 500 for
/// disk failures. Pairs with `storeErrorBody`.
pub fn storeErrorStatus(e: StoreError) u16 {
    return switch (e) {
        error.NotPdf, error.InvalidName => 400,
        error.WriteFailed, error.OutOfMemory => 500,
    };
}

/// Write `body` (raw PDF bytes) to `<project_dir>/lib/datasheets/<sanitized
/// filename>`. Returns the sanitized name (caller owns the slice). Validates
/// `%PDF` magic and the filename whitelist, both shared with the HTTP path.
pub fn storeDatasheet(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    raw_filename: []const u8,
    body: []const u8,
) StoreError!struct { name: []u8, size: usize } {
    if (!isPdfMagic(body)) return error.NotPdf;
    const safe = sanitizeFilename(allocator, raw_filename) catch |e| switch (e) {
        error.InvalidName => return error.InvalidName,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer allocator.free(safe);

    const dir = std.fmt.allocPrint(allocator, "{s}/lib/datasheets", .{project_dir}) catch return error.OutOfMemory;
    defer allocator.free(dir);
    infra_fs.cwd().makePath(dir) catch return error.WriteFailed;

    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, safe }) catch return error.OutOfMemory;
    defer allocator.free(path);
    const f = infra_fs.cwd().createFile(path, .{ .truncate = true }) catch return error.WriteFailed;
    defer f.close();
    f.writeAll(body) catch return error.WriteFailed;
    return .{ .name = safe, .size = body.len };
}

/// POST /api/upload-datasheet — raw PDF body + `x-filename` header. Writes
/// to `{project_dir}/lib/datasheets/{sanitized}`. Filenames pass through a
/// conservative whitelist (alphanum + `_-.`) and are forced to end in `.pdf`
/// so component-library references can only ever address this directory.
/// Size is capped at 64 MiB by the httpz config. The actual write goes
/// through `storeDatasheet` so the policy stays in one place.
pub fn uploadDatasheetApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"error\":\"empty upload\"}";
        return;
    };
    const raw_name = req.header("x-filename") orelse "datasheet.pdf";

    const stored = storeDatasheet(ctx.allocator, ctx.project_dir, raw_name, body) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        res.content_type = .JSON;
        res.status = storeErrorStatus(e);
        res.body = storeErrorBody(e) orelse "{\"ok\":false,\"error\":\"upload failed\"}";
        return;
    };
    defer ctx.allocator.free(stored.name);

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &buf.writer;
    try w.writeAll("{\"ok\":true,\"name\":\"");
    try w.writeAll(stored.name);
    try w.print("\",\"size\":{d}}}", .{stored.size});
    res.content_type = .JSON;
    res.body = buf.written();
}

/// GET /api/datasheets — JSON list of uploaded PDFs in `lib/datasheets/`.
/// Used by the schematic sidebar to populate any "link datasheet" UI and by
/// the review page to cross-reference what's on disk vs what's declared.
pub fn listDatasheetsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    _ = req;
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/datasheets", .{ctx.project_dir});
    defer ctx.allocator.free(dir_path);

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &buf.writer;
    try w.writeAll("{\"files\":[");

    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        try w.writeAll("]}");
        res.content_type = .JSON;
        res.body = buf.written();
        return;
    };
    defer dir.close();

    var it = dir.iterate();
    var first = true;
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".pdf")) continue;
        const stat = dir.statFile(entry.name) catch continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"name\":\"");
        try w.writeAll(entry.name);
        try w.print("\",\"size\":{d}}}", .{stat.size});
    }
    try w.writeAll("]}");
    res.content_type = .JSON;
    res.body = buf.written();
}

/// GET /datasheets/:filename — serve a PDF inline. Path-traversal guard
/// rejects `..` and slashes so the URL space stays rooted at the
/// datasheets dir.
pub fn serveDatasheetApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const filename = req.param("filename") orelse {
        res.status = 404;
        return;
    };
    if (filename.len == 0 or std.mem.indexOfAny(u8, filename, "/\\") != null or std.mem.indexOf(u8, filename, "..") != null) {
        res.status = 400;
        res.body = "invalid filename";
        return;
    }
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/datasheets/{s}", .{ ctx.project_dir, filename });
    defer ctx.allocator.free(path);
    const data = infra_fs.cwd().readFileAlloc(ctx.allocator, path, 64 * 1024 * 1024) catch {
        res.status = 404;
        res.body = "datasheet not found";
        return;
    };
    const disposition = try std.fmt.allocPrint(ctx.allocator, "inline; filename=\"{s}\"", .{filename});
    res.header("Content-Type", "application/pdf");
    res.header("Content-Disposition", disposition);
    res.body = data;
}

// ── Tests ─────────────────────────────────────────────────────────

test "sanitizeFilename strips path components" {
    // spec: serve/upload_datasheet - sanitize strips path segments
    const alloc = std.testing.allocator;
    const out = try sanitizeFilename(alloc, "../../../etc/passwd");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("passwd.pdf", out);
}

test "sanitizeFilename forces pdf extension" {
    // spec: serve/upload_datasheet - sanitize forces .pdf extension
    const alloc = std.testing.allocator;
    const out = try sanitizeFilename(alloc, "datasheet.txt");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("datasheet.txt.pdf", out);
}

test "sanitizeFilename replaces non-whitelist chars with underscore" {
    // spec: serve/upload_datasheet - sanitize replaces unsafe chars
    const alloc = std.testing.allocator;
    const out = try sanitizeFilename(alloc, "weird name with spaces & symbols.pdf");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("weird_name_with_spaces___symbols.pdf", out);
}

test "sanitizeFilename strips a duplicate-download marker" {
    // spec: serve/upload_datasheet - sanitize strips duplicate-download marker
    const alloc = std.testing.allocator;
    const a = try sanitizeFilename(alloc, "tps55289 (1).pdf");
    defer alloc.free(a);
    try std.testing.expectEqualStrings("tps55289.pdf", a);
    const b = try sanitizeFilename(alloc, "foo(12).pdf");
    defer alloc.free(b);
    try std.testing.expectEqualStrings("foo.pdf", b);
}

test "sanitizeFilename keeps a part number that merely ends in digits" {
    // spec: serve/upload_datasheet - sanitize preserves trailing-digit names
    const alloc = std.testing.allocator;
    const out = try sanitizeFilename(alloc, "lm2596.pdf");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("lm2596.pdf", out);
}

test "sanitizeFilename keeps the plus of a Mini-Circuits part number" {
    // spec: serve/upload_datasheet - sanitize keeps `+` so a Mini-Circuits filename survives its own round trip
    const alloc = std.testing.allocator;
    // The name a store writes must be the name a read of that same string
    // resolves — sanitizing is idempotent, which folding `+` to `_` was not.
    const out = try sanitizeFilename(alloc, "TSY-83LNW+.pdf");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("TSY-83LNW+.pdf", out);
    const again = try sanitizeFilename(alloc, out);
    defer alloc.free(again);
    try std.testing.expectEqualStrings("TSY-83LNW+.pdf", again);
    // `+` is data; everything that could steer a path or a shell still is not.
    const hostile = try sanitizeFilename(alloc, "../lib/YAT-0A+;rm -rf $HOME.pdf");
    defer alloc.free(hostile);
    try std.testing.expectEqualStrings("YAT-0A+_rm_-rf__HOME.pdf", hostile);
    try std.testing.expect(datasheet_ref.isLocal(hostile));
    try std.testing.expect(datasheet_ref.isLocal("TSY-83LNW+.pdf"));
    try std.testing.expect(!datasheet_ref.isLocal("../TSY-83LNW+.pdf"));
}

test "isPdfMagic rejects non-PDF bytes" {
    // spec: serve/upload_datasheet - isPdfMagic gates non-PDF input
    try std.testing.expect(isPdfMagic("%PDF-1.7\nrest"));
    try std.testing.expect(!isPdfMagic("not a pdf"));
    try std.testing.expect(!isPdfMagic(""));
    try std.testing.expect(!isPdfMagic("PDF"));
}
