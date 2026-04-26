const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// POST /api/upload-datasheet — raw PDF body + `x-filename` header. Writes
/// to `{project_dir}/lib/datasheets/{sanitized}`. Filenames pass through a
/// conservative whitelist (alphanum + `_-.`) and are forced to end in `.pdf`
/// so component-library references can only ever address this directory.
/// Size is capped at 64 MiB by the httpz config.
pub fn uploadDatasheetApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"error\":\"empty upload\"}";
        return;
    };
    const raw_name = req.header("x-filename") orelse "datasheet.pdf";

    if (body.len < 4 or !std.mem.eql(u8, body[0..4], "%PDF")) {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"error\":\"not a PDF (missing %PDF header)\"}";
        return;
    }

    const safe = sanitizeFilename(ctx.allocator, raw_name) catch {
        res.status = 400;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"error\":\"invalid filename\"}";
        return;
    };
    defer ctx.allocator.free(safe);

    const dir = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/datasheets", .{ctx.project_dir});
    defer ctx.allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ dir, safe });
    defer ctx.allocator.free(path);
    const f = std.fs.cwd().createFile(path, .{ .truncate = true }) catch {
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"error\":\"write failed\"}";
        return;
    };
    defer f.close();
    f.writeAll(body) catch {
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"error\":\"write failed\"}";
        return;
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"ok\":true,\"name\":\"");
    try w.writeAll(safe);
    try w.print("\",\"size\":{d}}}", .{body.len});
    res.content_type = .JSON;
    res.body = buf.items;
}

/// GET /api/datasheets — JSON list of uploaded PDFs in `lib/datasheets/`.
/// Used by the schematic sidebar to populate any "link datasheet" UI and by
/// the review page to cross-reference what's on disk vs what's declared.
pub fn listDatasheetsApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    _ = req;
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/datasheets", .{ctx.project_dir});
    defer ctx.allocator.free(dir_path);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"files\":[");

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
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
pub fn serveDatasheetApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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
    const data = std.fs.cwd().readFileAlloc(ctx.allocator, path, 64 * 1024 * 1024) catch {
        res.status = 404;
        res.body = "datasheet not found";
        return;
    };
    const disposition = try std.fmt.allocPrint(ctx.allocator, "inline; filename=\"{s}\"", .{filename});
    res.header("Content-Type", "application/pdf");
    res.header("Content-Disposition", disposition);
    res.body = data;
}

fn sanitizeFilename(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
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
