const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
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

/// Conservative filename whitelist for `lib/datasheets/`. Drops any path
/// component the client tried to smuggle in, replaces non-`[a-zA-Z0-9_.-]`
/// bytes with `_`, and forces a trailing `.pdf`. Caller owns the returned
/// slice. Used by both transports — kept here so the policy is one-place.
pub fn sanitizeFilename(allocator: std.mem.Allocator, raw: []const u8) SanitizeError![]u8 {
    if (raw.len == 0) return error.InvalidName;
    // Drop any path component the client tried to smuggle in.
    const base = blk: {
        if (std.mem.lastIndexOfAny(u8, raw, "/\\")) |idx| break :blk raw[idx + 1 ..];
        break :blk raw;
    };
    if (base.len == 0 or std.mem.eql(u8, base, "..") or std.mem.eql(u8, base, ".")) return error.InvalidName;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (base) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
        try out.append(allocator, if (ok) c else '_');
    }
    if (out.items.len == 0) return error.InvalidName;

    if (!std.mem.endsWith(u8, out.items, ".pdf")) {
        try out.appendSlice(allocator, ".pdf");
    }
    return out.toOwnedSlice(allocator);
}

/// Errors from `storeDatasheet`. `NotPdf` and `InvalidName` map to HTTP 400;
/// `WriteFailed` to 500. The MCP tool maps them to `{"ok":false,"error":…}`.
pub const StoreError = error{ NotPdf, InvalidName, WriteFailed, OutOfMemory };

/// JSON body for a store error, ready to embed in a response. `null` for
/// `OutOfMemory` — the caller must propagate that one. Centralises the
/// error → message mapping so HTTP and MCP transports stay in sync.
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
pub fn uploadDatasheetApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"ok\":true,\"name\":\"");
    try w.writeAll(stored.name);
    try w.print("\",\"size\":{d}}}", .{stored.size});
    res.content_type = .JSON;
    res.body = buf.items;
}

/// GET /api/datasheets — JSON list of uploaded PDFs in `lib/datasheets/`.
/// Used by the schematic sidebar to populate any "link datasheet" UI and by
/// the review page to cross-reference what's on disk vs what's declared.
pub fn listDatasheetsApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    _ = req;
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/datasheets", .{ctx.project_dir});
    defer ctx.allocator.free(dir_path);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"files\":[");

    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
        try w.writeAll("]}");
        res.content_type = .JSON;
        res.body = buf.items;
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
    res.body = buf.items;
}

/// GET /datasheets/:filename — serve a PDF inline. Path-traversal guard
/// rejects `..` and slashes so the URL space stays rooted at the
/// datasheets dir.
pub fn serveDatasheetApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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

test "isPdfMagic rejects non-PDF bytes" {
    // spec: serve/upload_datasheet - isPdfMagic gates non-PDF input
    try std.testing.expect(isPdfMagic("%PDF-1.7\nrest"));
    try std.testing.expect(!isPdfMagic("not a pdf"));
    try std.testing.expect(!isPdfMagic(""));
    try std.testing.expect(!isPdfMagic("PDF"));
}
