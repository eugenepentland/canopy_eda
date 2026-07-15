//! Datasheet text extraction for the `read_datasheet` MCP tool.
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
const subprocess = @import("subprocess.zig");

/// Extracted-text byte cap (also the sidecar read ceiling).
const max_output_bytes: usize = 8 * 1024 * 1024;
/// Hard wall-clock ceiling for one ps2ascii run before its group is killed.
const extract_timeout_ms: u64 = 45_000;
/// Bytes returned when the caller gives no explicit `limit`.
const default_limit: u64 = 20_000;

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
    const w = out.writer(allocator);

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

    return writeResult(w, sanitized, window(text, offset, limit));
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
    return txt_stat.mtime >= pdf_stat.mtime;
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

fn writeResult(w: anytype, name: []const u8, win: Window) !bool {
    try w.writeAll("{\"ok\":true,\"name\":");
    try json_writer.writeString(w, name);
    try w.print(",\"total_bytes\":{d},\"offset\":{d},\"returned_bytes\":{d},\"truncated\":{s},\"content\":", .{
        win.total, win.offset, win.slice.len, if (win.truncated) "true" else "false",
    });
    try json_writer.writeString(w, win.slice);
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
