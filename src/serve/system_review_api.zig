//! Authenticated browser/API surface for system-level review workspaces.
//!
//! The manifest is the authority for every document the browser may read or
//! mutate. Callers never supply a filesystem path: `:name` resolves the fixed
//! `src/systems/<name>/system.json`, and `:doc` resolves one declared document
//! id. Authored writes use the VFS sandbox/CAS path plus the ordinary
//! autocommit seam. Attestation updates replace only the manifest's top-level
//! `attestation` value so the human-authored manifest stays otherwise intact.

const std = @import("std");
const httpz = @import("httpz");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const system_review = @import("../system_review.zig");
const system_review_assets = @import("../system_review_assets.zig");
const system_review_md = @import("../system_review_md.zig");
const system_review_package = @import("../system_review_package.zig");
const serve_root = @import("../serve.zig");
const autocommit = @import("autocommit.zig");
const fab_release_service = @import("fab_release_service.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const vfs = @import("vfs.zig");

const Server = serve_root.Server;

/// Mirrors system_review_package's authored-document ceiling so the editor can
/// round-trip every document the package composer accepts.
const max_document_bytes: usize = 4 * 1024 * 1024;
const max_system_name_bytes: usize = 128;
const max_release_request_bytes: usize = 4 * 1024;
const mutation_header_name = "x-netlisp-review";
const mutation_header_value = "1";

pub const HandlerError = vfs.VfsError || pcb_layout_page.HandlerError || error{InvalidManifest};

const LoadedSystem = struct {
    manifest_rel: []const u8,
    raw: []const u8,
    parsed: system_review.ParsedSystemSpec,
    sha256: [64]u8,
    has_attestation_value: bool,
    recovered_stale_attestation: bool,

    fn deinit(self: *LoadedSystem, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.raw);
        allocator.free(self.manifest_rel);
    }
};

const FieldSpan = struct {
    value_start: usize,
    value_end: usize,
};

fn sendJsonError(res: *httpz.Response, status: u16, message: []const u8) HandlerError!void {
    var out: std.Io.Writer.Allocating = .init(res.arena);
    try out.writer.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(&out.writer, message);
    try out.writer.writeByte('}');
    res.status = status;
    res.content_type = .JSON;
    res.header("cache-control", "private, no-store");
    res.body = out.written();
}

fn sendDiagnostic(
    res: *httpz.Response,
    status: u16,
    message: []const u8,
    diagnostic: system_review.Diagnostic,
) HandlerError!void {
    var out: std.Io.Writer.Allocating = .init(res.arena);
    const writer = &out.writer;
    try writer.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(writer, message);
    try writer.writeAll(",\"diagnostic\":{\"code\":");
    try json_writer.writeString(writer, @tagName(diagnostic.code));
    try writer.writeAll(",\"field\":");
    try json_writer.writeString(writer, diagnostic.field);
    try writer.writeAll(",\"message\":");
    try json_writer.writeString(writer, diagnostic.message);
    try writer.writeAll(",\"value\":");
    try json_writer.writeString(writer, diagnostic.value);
    try writer.writeAll("}}");
    res.status = status;
    res.content_type = .JSON;
    res.header("cache-control", "private, no-store");
    res.body = out.written();
}

fn isSimpleName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_system_name_bytes or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name[1..]) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') continue;
        return false;
    }
    return true;
}

fn manifestRelativePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "src/systems/{s}/system.json", .{name});
}

fn allowedProjectReadPath(path: []const u8) bool {
    if (!system_review.isSafeRelativePath(path)) return false;
    return std.mem.startsWith(u8, path, "src/") or std.mem.startsWith(u8, path, "lib/");
}

fn readProjectFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
    max_bytes: usize,
) ![]const u8 {
    if (!allowedProjectReadPath(relative)) return error.AccessDenied;
    return system_review_assets.readContainedFile(allocator, project_dir, relative, max_bytes);
}

fn topLevelFieldValueSpan(source: []const u8, key: []const u8) ?FieldSpan {
    var index: usize = skipWhitespace(source, 0);
    if (index >= source.len or source[index] != '{') return null;
    index += 1;
    while (true) {
        index = skipWhitespace(source, index);
        if (index >= source.len or source[index] == '}') return null;
        const key_start = index;
        const key_end = jsonStringEnd(source, key_start) orelse return null;
        const exact_key = jsonStringEquals(source, key_start, key_end, key);
        index = skipWhitespace(source, key_end);
        if (index >= source.len or source[index] != ':') return null;
        const value_start = skipWhitespace(source, index + 1);
        const value_end = jsonValueEnd(source, value_start) orelse return null;
        if (exact_key) return .{ .value_start = value_start, .value_end = value_end };
        index = skipWhitespace(source, value_end);
        if (index >= source.len) return null;
        if (source[index] == '}') return null;
        if (source[index] != ',') return null;
        index += 1;
    }
}

fn jsonStringEquals(source: []const u8, start: usize, end: usize, expected: []const u8) bool {
    if (end <= start + 1 or source[start] != '"' or source[end - 1] != '"') return false;
    var at = start + 1;
    var expected_at: usize = 0;
    while (at < end - 1) {
        var byte = source[at];
        at += 1;
        if (byte == '\\') {
            byte = jsonEscapedAscii(source, &at, end - 1) orelse return false;
        }
        if (expected_at >= expected.len or expected[expected_at] != byte) return false;
        expected_at += 1;
    }
    return expected_at == expected.len;
}

fn jsonEscapedAscii(source: []const u8, at: *usize, limit: usize) ?u8 {
    if (at.* >= limit) return null;
    const escape = source[at.*];
    at.* += 1;
    return switch (escape) {
        '"', '\\', '/' => escape,
        'b' => 0x08,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'u' => decodedAsciiHexEscape(source, at, limit),
        else => null,
    };
}

fn decodedAsciiHexEscape(source: []const u8, at: *usize, limit: usize) ?u8 {
    if (at.* + 4 > limit) return null;
    var value: u16 = 0;
    for (source[at.* .. at.* + 4]) |hex|
        value = value * 16 + (std.fmt.charToDigit(hex, 16) catch return null);
    at.* += 4;
    if (value > 0x7f) return null;
    return @intCast(value);
}

fn skipWhitespace(source: []const u8, start: usize) usize {
    var index = start;
    while (index < source.len and std.ascii.isWhitespace(source[index])) index += 1;
    return index;
}

fn jsonStringEnd(source: []const u8, start: usize) ?usize {
    if (start >= source.len or source[start] != '"') return null;
    var escaped = false;
    var index = start + 1;
    while (index < source.len) : (index += 1) {
        const c = source[index];
        if (escaped) {
            escaped = false;
        } else if (c == '\\') {
            escaped = true;
        } else if (c == '"') {
            return index + 1;
        }
    }
    return null;
}

fn jsonValueEnd(source: []const u8, start: usize) ?usize {
    if (start >= source.len) return null;
    if (source[start] == '"') return jsonStringEnd(source, start);
    if (source[start] == '{' or source[start] == '[') return jsonContainerEnd(source, start);
    var index = start;
    while (index < source.len and source[index] != ',' and source[index] != '}') index += 1;
    while (index > start and std.ascii.isWhitespace(source[index - 1])) index -= 1;
    return if (index > start) index else null;
}

fn jsonContainerEnd(source: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    var index = start;
    while (index < source.len) : (index += 1) {
        const c = source[index];
        if (in_string) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
        } else if (c == '{' or c == '[') {
            depth += 1;
        } else if (c == '}' or c == ']') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return index + 1;
        }
    }
    return null;
}

fn patchTopLevelAttestation(
    allocator: std.mem.Allocator,
    source: []const u8,
    value_json: []const u8,
) ![]const u8 {
    if (topLevelFieldValueSpan(source, "attestation")) |span| {
        return std.mem.concat(allocator, u8, &.{ source[0..span.value_start], value_json, source[span.value_end..] });
    }
    const close = topLevelObjectClose(source) orelse return error.InvalidManifest;
    var body_end = close;
    while (body_end > 0 and std.ascii.isWhitespace(source[body_end - 1])) body_end -= 1;
    const separator = if (body_end > 0 and source[body_end - 1] == '{') "" else ",";
    const multiline = std.mem.indexOfScalar(u8, source, '\n') != null;
    const field = if (multiline)
        try std.fmt.allocPrint(allocator, "{s}\n  \"attestation\": {s}", .{ separator, value_json })
    else
        try std.fmt.allocPrint(allocator, "{s}\"attestation\":{s}", .{ separator, value_json });
    defer allocator.free(field);
    return std.mem.concat(allocator, u8, &.{ source[0..body_end], field, source[body_end..] });
}

fn topLevelObjectClose(source: []const u8) ?usize {
    const start = skipWhitespace(source, 0);
    const end = jsonContainerEnd(source, start) orelse return null;
    if (end == 0 or source[end - 1] != '}') return null;
    if (skipWhitespace(source, end) != source.len) return null;
    return end - 1;
}

fn hasNonNullAttestation(source: []const u8) bool {
    const span = topLevelFieldValueSpan(source, "attestation") orelse return false;
    return !std.mem.eql(u8, std.mem.trim(u8, source[span.value_start..span.value_end], " \t\r\n"), "null");
}

fn loadSystem(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    diagnostic: *system_review.Diagnostic,
) !LoadedSystem {
    if (!isSimpleName(name)) return error.InvalidSystemName;
    const manifest_rel = try manifestRelativePath(allocator, name);
    errdefer allocator.free(manifest_rel);
    const raw = try readProjectFile(allocator, project_dir, manifest_rel, system_review.max_manifest_bytes);
    errdefer allocator.free(raw);
    var syntax = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        diagnostic.* = .{
            .code = .invalid_json,
            .field = "manifest",
            .message = "invalid system-review JSON",
            .value = @errorName(err),
        };
        return error.InvalidJson;
    };
    defer syntax.deinit();
    const has_attestation = hasNonNullAttestation(raw);
    var parsed = system_review.parseSystemSpec(allocator, raw, diagnostic) catch |first_error| blk: {
        if (!has_attestation) return first_error;
        const without_attestation = try patchTopLevelAttestation(allocator, raw, "null");
        defer allocator.free(without_attestation);
        break :blk system_review.parseSystemSpec(allocator, without_attestation, diagnostic) catch return first_error;
    };
    if (!std.mem.eql(u8, parsed.value.name, name)) {
        parsed.deinit();
        return error.SystemNameMismatch;
    }
    return .{
        .manifest_rel = manifest_rel,
        .raw = raw,
        .parsed = parsed,
        .sha256 = system_review.sha256Hex(raw),
        .has_attestation_value = has_attestation,
        .recovered_stale_attestation = has_attestation and parsed.value.attestation == null,
    };
}

fn loadSystemForRequest(
    ctx: *Server,
    req: *httpz.Request,
    res: *httpz.Response,
    diagnostic: *system_review.Diagnostic,
) !?LoadedSystem {
    const name = req.param("name") orelse {
        try sendJsonError(res, 404, "missing system name");
        return null;
    };
    return loadSystem(ctx.allocator, ctx.project_dir, name, diagnostic) catch |err| {
        switch (err) {
            error.InvalidSystemName, error.SystemNameMismatch => try sendJsonError(res, 400, "invalid system name"),
            error.FileNotFound => try sendJsonError(res, 404, "system not found"),
            error.UnsafePath, error.AccessDenied => try sendJsonError(res, 422, "system manifest path escapes the project"),
            error.InvalidJson, error.InvalidManifest, error.ManifestTooLarge => try sendDiagnostic(res, 422, "invalid system manifest", diagnostic.*),
            else => try sendJsonError(res, 500, "cannot read system manifest"),
        }
        return null;
    };
}

fn findDocument(spec: system_review.SystemSpec, id: []const u8) ?system_review.DocumentSpec {
    if (!isSimpleName(id)) return null;
    for (spec.documents) |document| if (std.mem.eql(u8, document.id, id)) return document;
    return null;
}

fn documentForRequest(
    loaded: *const LoadedSystem,
    req: *httpz.Request,
    res: *httpz.Response,
) !?system_review.DocumentSpec {
    const id = req.param("doc") orelse {
        try sendJsonError(res, 404, "missing document id");
        return null;
    };
    return findDocument(loaded.parsed.value, id) orelse {
        try sendJsonError(res, 404, "document is not declared by this system");
        return null;
    };
}

fn writableDocumentPath(
    allocator: std.mem.Allocator,
    system_name: []const u8,
    document: system_review.DocumentSpec,
) !bool {
    if (document.status != .active or !std.mem.endsWith(u8, document.path, ".md")) return false;
    const prefix = try std.fmt.allocPrint(allocator, "src/systems/{s}/", .{system_name});
    defer allocator.free(prefix);
    return std.mem.startsWith(u8, document.path, prefix);
}

fn stripGeneratedMarkerLines(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var lines = std.mem.splitScalar(u8, source, '\n');
    var in_fence = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var marker = false;
        if (in_fence) {
            if (std.mem.eql(u8, trimmed, "```")) in_fence = false;
        } else if (std.mem.startsWith(u8, trimmed, "```")) {
            in_fence = true;
        } else {
            marker = (std.mem.startsWith(u8, trimmed, system_review.generated_region_open) and
                std.mem.endsWith(u8, trimmed, " -->")) or
                std.mem.eql(u8, trimmed, system_review.generated_region_close);
        }
        if (!marker) try out.writer.print("{s}\n", .{line});
    }
    return out.toOwnedSlice();
}

fn renderSafeDocumentHtml(
    allocator: std.mem.Allocator,
    source: []const u8,
) ![]const u8 {
    const without_markers = try stripGeneratedMarkerLines(allocator, source);
    defer allocator.free(without_markers);
    var parsed = try system_review_md.parse(allocator, without_markers, .{});
    defer parsed.deinit();
    return system_review_md.renderHtmlAlloc(allocator, &parsed);
}

fn utcTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    const seconds = @max(@as(i64, 0), clock.timestamp());
    const epoch = clock.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const day = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, year_day.year),
        @backingInt(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

fn canWrite(ctx: *const Server) bool {
    return ctx.request_auth.username != null and ctx.request_auth.role.canWrite();
}

fn canRelease(ctx: *const Server) bool {
    return canWrite(ctx);
}

fn requireMutationHeader(req: *httpz.Request, res: *httpz.Response) HandlerError!bool {
    const value = req.header(mutation_header_name) orelse {
        try sendJsonError(res, 403, "missing system-review mutation header");
        return false;
    };
    if (!std.mem.eql(u8, std.mem.trim(u8, value, " \t"), mutation_header_value)) {
        try sendJsonError(res, 403, "invalid system-review mutation header");
        return false;
    }
    return true;
}

fn commitMutation(
    ctx: *Server,
    session: ?autocommit.Session,
    tool_name: []const u8,
    manifest_path: ?[]const u8,
    content_path: ?[]const u8,
) void {
    var paths: [2][]const u8 = undefined;
    var count: usize = 0;
    if (manifest_path) |path| {
        paths[count] = path;
        count += 1;
    }
    if (content_path) |path| {
        paths[count] = path;
        count += 1;
    }
    autocommit.commitPaths(session, ctx.request_auth.username, tool_name, paths[0..count]);
}

fn writeVfsFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
    content: []const u8,
    expected_sha256: ?[]const u8,
    out: *std.ArrayList(u8),
) !bool {
    return vfs.writeFile(allocator, project_dir, relative, content, .{
        .expected_sha256 = expected_sha256,
    }, out);
}

fn createVfsFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    relative: []const u8,
    content: []const u8,
    out: *std.ArrayList(u8),
) !bool {
    return vfs.writeFile(allocator, project_dir, relative, content, .{
        .require_absent = true,
    }, out);
}

fn invalidateManifestAttestation(
    ctx: *Server,
    loaded: *const LoadedSystem,
    response: *std.ArrayList(u8),
) !bool {
    if (!loaded.has_attestation_value) return true;
    const patched = try patchTopLevelAttestation(ctx.allocator, loaded.raw, "null");
    defer ctx.allocator.free(patched);
    return writeVfsFile(
        ctx.allocator,
        ctx.project_dir,
        loaded.manifest_rel,
        patched,
        &loaded.sha256,
        response,
    );
}

fn sendVfsFailure(res: *httpz.Response, body: []const u8) HandlerError!void {
    res.status = if (std.mem.indexOf(u8, body, "\"stale\":true") != null) 409 else 500;
    res.content_type = .JSON;
    res.body = try res.arena.dupe(u8, body);
}

/// One system workspace as the listing surfaces summarise it. Shared with the
/// home page, which renders the same set as cards — the JSON endpoint must
/// never be the only way to discover that a system exists.
pub const SystemSummary = struct {
    name: []const u8,
    title: []const u8,
    part_number: []const u8,
    revision: []const u8,
    boards: usize,
    documents: usize,
    attested: bool,
};

fn lessSystemSummary(_: void, a: SystemSummary, b: SystemSummary) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Everything enumeration can fail with, derived from the implementation the
/// way system_review_package.zig derives its own — a hand-written set would
/// drift the moment the path or directory helpers widen theirs. A malformed
/// individual manifest is NOT in here: that system is skipped, so one bad
/// workspace cannot blank the home page or the listing endpoint.
pub const ListSystemsError = @typeInfo(@typeInfo(@TypeOf(collectSystemSummariesImpl)).@"fn".return_type.?).error_union.error_set;

/// Enumerate `src/systems/*/system.json`, sorted by name. Empty (not an
/// error) when the project has no `src/systems` at all, so a project that
/// never adopted system review renders a home page with no systems section.
pub fn collectSystemSummaries(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
) ListSystemsError![]const SystemSummary {
    return collectSystemSummariesImpl(allocator, project_dir);
}

fn collectSystemSummariesImpl(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
) ![]const SystemSummary {
    const root = system_review_assets.resolveContainedPathAlloc(allocator, project_dir, "src/systems") catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer allocator.free(root);
    var directory = infra_fs.cwd().openDir(root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer directory.close();

    var summaries: std.ArrayList(SystemSummary) = .empty;
    var iterator = directory.iterate();
    while (try iterator.next()) |entry| {
        if (entry.kind != .directory or !isSimpleName(entry.name)) continue;
        var diagnostic: system_review.Diagnostic = .{};
        var loaded = loadSystem(allocator, project_dir, entry.name, &diagnostic) catch continue;
        defer loaded.deinit(allocator);
        const spec = loaded.parsed.value;
        try summaries.append(allocator, .{
            .name = try allocator.dupe(u8, spec.name),
            .title = try allocator.dupe(u8, spec.title),
            .part_number = try allocator.dupe(u8, spec.part_number),
            .revision = try allocator.dupe(u8, spec.revision),
            .boards = spec.boards.len,
            .documents = spec.documents.len,
            .attested = loaded.has_attestation_value and !loaded.recovered_stale_attestation,
        });
    }
    std.mem.sort(SystemSummary, summaries.items, {}, lessSystemSummary);
    return summaries.toOwnedSlice(allocator);
}

/// GET /api/systems — discover valid `src/systems/*/system.json` workspaces.
pub fn listSystemsApi(ctx: *Server, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const summaries = collectSystemSummaries(res.arena, ctx.project_dir) catch {
        return sendJsonError(res, 500, "cannot list system workspaces");
    };
    var out: std.Io.Writer.Allocating = .init(res.arena);
    const writer = &out.writer;
    try writer.writeAll("{\"systems\":[");
    for (summaries, 0..) |summary, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"name\":");
        try json_writer.writeString(writer, summary.name);
        try writer.writeAll(",\"title\":");
        try json_writer.writeString(writer, summary.title);
        try writer.writeAll(",\"part_number\":");
        try json_writer.writeString(writer, summary.part_number);
        try writer.writeAll(",\"revision\":");
        try json_writer.writeString(writer, summary.revision);
        try writer.print(",\"boards\":{d},\"documents\":{d},\"attested\":{s}}}", .{
            summary.boards,
            summary.documents,
            if (summary.attested) "true" else "false",
        });
    }
    try writer.writeAll("]}");
    res.content_type = .JSON;
    res.header("cache-control", "private, no-store");
    res.body = out.written();
}

/// GET /api/systems/:name — strict manifest plus current request permissions.
pub fn getSystemApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var diagnostic: system_review.Diagnostic = .{};
    var loaded = (try loadSystemForRequest(ctx, req, res, &diagnostic)) orelse return;
    defer loaded.deinit(ctx.allocator);

    var out: std.Io.Writer.Allocating = .init(res.arena);
    const writer = &out.writer;
    try writer.writeAll("{\"manifest\":");
    try writer.writeAll(loaded.raw);
    try writer.writeAll(",\"manifest_sha256\":");
    try json_writer.writeString(writer, &loaded.sha256);
    try writer.writeAll(",\"attestation_recoverable_stale\":");
    try writer.writeAll(if (loaded.recovered_stale_attestation) "true" else "false");
    try writer.writeAll(",\"permissions\":{\"write\":");
    try writer.writeAll(if (canWrite(ctx)) "true" else "false");
    try writer.writeAll(",\"release\":");
    try writer.writeAll(if (canRelease(ctx)) "true" else "false");
    try writer.writeAll(",\"role\":");
    try json_writer.writeString(writer, ctx.request_auth.role.toString());
    try writer.writeAll("}}");
    res.content_type = .JSON;
    res.header("cache-control", "private, no-store");
    res.body = out.written();
}

fn writeDocumentDiagnostic(
    writer: *std.Io.Writer,
    diagnostic: system_review.Diagnostic,
) !void {
    try writer.writeAll("{\"code\":");
    try json_writer.writeString(writer, @tagName(diagnostic.code));
    try writer.writeAll(",\"field\":");
    try json_writer.writeString(writer, diagnostic.field);
    try writer.writeAll(",\"message\":");
    try json_writer.writeString(writer, diagnostic.message);
    try writer.writeAll(",\"value\":");
    try json_writer.writeString(writer, diagnostic.value);
    try writer.writeByte('}');
}

/// GET /api/systems/:name/docs/:doc — authored Markdown, inert HTML and CAS id.
pub fn getDocumentApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var manifest_diagnostic: system_review.Diagnostic = .{};
    var loaded = (try loadSystemForRequest(ctx, req, res, &manifest_diagnostic)) orelse return;
    defer loaded.deinit(ctx.allocator);
    const document = (try documentForRequest(&loaded, req, res)) orelse return;
    const content: ?[]const u8 = readProjectFile(ctx.allocator, ctx.project_dir, document.path, max_document_bytes) catch |err| switch (err) {
        error.FileNotFound => null,
        error.UnsafePath, error.AccessDenied => return sendJsonError(res, 422, "declared document path escapes the project"),
        else => return sendJsonError(res, 500, "cannot read declared document"),
    };
    defer if (content) |bytes| ctx.allocator.free(bytes);
    const present = content != null;
    const content_bytes = content orelse "";
    if (present and !std.unicode.utf8ValidateSlice(content_bytes))
        return sendJsonError(res, 422, "declared document is not valid UTF-8");

    var document_diagnostic: system_review.Diagnostic = .{};
    const inspected = if (present)
        system_review.inspectDocumentContent(document, content_bytes, &document_diagnostic) catch null
    else
        null;
    const rendered_html: ?[]const u8 = if (present)
        renderSafeDocumentHtml(ctx.allocator, content_bytes) catch null
    else
        null;
    defer if (rendered_html) |html| ctx.allocator.free(html);
    const content_valid = present and inspected != null and rendered_html != null;
    const digest: ?[64]u8 = if (present) system_review.sha256Hex(content_bytes) else null;

    var out: std.Io.Writer.Allocating = .init(res.arena);
    const writer = &out.writer;
    try writer.writeAll("{\"id\":");
    try json_writer.writeString(writer, document.id);
    try writer.writeAll(",\"title\":");
    try json_writer.writeString(writer, document.title);
    try writer.writeAll(",\"classification\":");
    try json_writer.writeString(writer, @tagName(document.classification));
    try writer.writeAll(",\"status\":");
    try json_writer.writeString(writer, @tagName(document.status));
    try writer.writeAll(",\"path\":");
    try json_writer.writeString(writer, document.path);
    try writer.writeAll(",\"editable\":");
    const editable = canWrite(ctx) and try writableDocumentPath(ctx.allocator, loaded.parsed.value.name, document);
    try writer.writeAll(if (editable) "true" else "false");
    try writer.writeAll(",\"exists\":");
    try writer.writeAll(if (present) "true" else "false");
    try writer.writeAll(",\"sha256\":");
    if (digest) |value| try json_writer.writeString(writer, &value) else try writer.writeAll("null");
    try writer.writeAll(",\"markdown\":");
    try json_writer.writeString(writer, content_bytes);
    try writer.writeAll(",\"html\":");
    if (rendered_html) |html| try json_writer.writeString(writer, html) else try writer.writeAll("null");
    try writer.writeAll(",\"content_valid\":");
    try writer.writeAll(if (content_valid) "true" else "false");
    try writer.writeAll(",\"diagnostic\":");
    if (!present) {
        try writer.writeAll("{\"code\":\"missing_document\",\"field\":\"document\",\"message\":\"declared document has not been created\",\"value\":\"\"}");
    } else if (inspected == null) {
        try writeDocumentDiagnostic(writer, document_diagnostic);
    } else if (rendered_html == null) {
        try writer.writeAll("{\"code\":\"unsafe_markdown\",\"field\":\"document\",\"message\":\"document is outside the safe bounded Markdown profile\",\"value\":\"\"}");
    } else {
        try writer.writeAll("null");
    }
    if (inspected) |facts| {
        try writer.print(",\"checklist\":{{\"total\":{d},\"complete\":{d},\"open\":{d}}}", .{
            facts.checklist.total,
            facts.checklist.complete,
            facts.checklist.open,
        });
    } else {
        try writer.writeAll(",\"checklist\":null");
    }
    try writer.writeByte('}');
    res.content_type = .JSON;
    if (digest) |value| res.header("etag", try res.arena.dupe(u8, &value));
    res.header("cache-control", "no-store");
    res.body = out.written();
}

fn requestEtag(req: *httpz.Request) ?[]const u8 {
    var value = std.mem.trim(u8, req.header("if-match") orelse return null, " \t");
    if (std.mem.startsWith(u8, value, "W/")) value = std.mem.trimStart(u8, value[2..], " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    return value;
}

fn validateDocumentForSave(
    allocator: std.mem.Allocator,
    content: []const u8,
    document: system_review.DocumentSpec,
    diagnostic: *system_review.Diagnostic,
) !void {
    _ = try system_review.inspectDocumentContent(document, content, diagnostic);
    const without_markers = try stripGeneratedMarkerLines(allocator, content);
    defer allocator.free(without_markers);
    var parsed = try system_review_md.parse(allocator, without_markers, .{});
    defer parsed.deinit();
}

fn validateExpectedDocument(
    req: *httpz.Request,
    res: *httpz.Response,
    current_sha256: ?[64]u8,
) !bool {
    if (current_sha256 == null) {
        const absent = std.mem.trim(u8, req.header("if-none-match") orelse "", " \t");
        if (std.mem.eql(u8, absent, "*")) return true;
        res.status = 428;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"error\":\"If-None-Match: * is required for document creation\"}";
        return false;
    }
    const expected = requestEtag(req) orelse {
        res.status = 428;
        res.content_type = .JSON;
        res.body = "{\"ok\":false,\"error\":\"If-Match is required for document replacement\"}";
        return false;
    };
    if (current_sha256) |current| {
        if (std.mem.eql(u8, expected, &current)) return true;
    }
    res.status = 409;
    res.content_type = .JSON;
    res.body = "{\"ok\":false,\"error\":\"stale document\",\"stale\":true}";
    return false;
}

/// PUT /api/systems/:name/docs/:doc — CAS-safe replacement of an active,
/// system-owned Markdown document. Any prior release attestation is revoked
/// before the authored bytes become visible.
pub fn putDocumentApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    if (!try requireMutationHeader(req, res)) return;
    if (!canWrite(ctx)) return sendJsonError(res, 403, "writer role required");
    const body = req.body() orelse return sendJsonError(res, 400, "missing Markdown body");
    if (body.len > max_document_bytes) return sendJsonError(res, 413, "document too large");

    var mutation = vfs.beginMutation();
    defer mutation.deinit();
    var manifest_diagnostic: system_review.Diagnostic = .{};
    var loaded = (try loadSystemForRequest(ctx, req, res, &manifest_diagnostic)) orelse return;
    defer loaded.deinit(ctx.allocator);
    const document = (try documentForRequest(&loaded, req, res)) orelse return;
    if (!try writableDocumentPath(ctx.allocator, loaded.parsed.value.name, document))
        return sendJsonError(res, 409, "only active system-owned Markdown documents are editable");

    const current: ?[]const u8 = readProjectFile(ctx.allocator, ctx.project_dir, document.path, max_document_bytes) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return sendJsonError(res, 500, "cannot read current document"),
    };
    defer if (current) |bytes| ctx.allocator.free(bytes);
    const current_digest: ?[64]u8 = if (current) |bytes| system_review.sha256Hex(bytes) else null;
    if (!try validateExpectedDocument(req, res, current_digest)) return;

    var document_diagnostic: system_review.Diagnostic = .{};
    validateDocumentForSave(ctx.allocator, body, document, &document_diagnostic) catch |err| {
        if (err == error.InvalidDocument) return sendDiagnostic(res, 422, "invalid document", document_diagnostic);
        return sendJsonError(res, 422, "document is outside the safe Markdown profile");
    };

    var ac_session = autocommit.begin(ctx.allocator, ctx.project_dir);
    defer if (ac_session) |*session| session.deinit();
    var vfs_response: std.ArrayList(u8) = .empty;
    defer vfs_response.deinit(ctx.allocator);
    if (!try invalidateManifestAttestation(ctx, &loaded, &vfs_response))
        return sendVfsFailure(res, vfs_response.items);

    vfs_response.clearRetainingCapacity();
    const document_written = if (current_digest) |*digest|
        try writeVfsFile(ctx.allocator, ctx.project_dir, document.path, body, digest, &vfs_response)
    else
        try createVfsFile(ctx.allocator, ctx.project_dir, document.path, body, &vfs_response);
    if (!document_written) {
        if (loaded.has_attestation_value)
            commitMutation(ctx, ac_session, "system_review_invalidate", loaded.manifest_rel, null);
        return sendVfsFailure(res, vfs_response.items);
    }
    commitMutation(
        ctx,
        ac_session,
        "system_review_document",
        if (loaded.has_attestation_value) loaded.manifest_rel else null,
        document.path,
    );

    const digest = system_review.sha256Hex(body);
    var out: std.Io.Writer.Allocating = .init(res.arena);
    try out.writer.writeAll("{\"ok\":true,\"sha256\":");
    try json_writer.writeString(&out.writer, &digest);
    try out.writer.writeAll(",\"attestation_invalidated\":");
    try out.writer.writeAll(if (loaded.has_attestation_value) "true" else "false");
    try out.writer.writeByte('}');
    res.content_type = .JSON;
    res.header("etag", try res.arena.dupe(u8, &digest));
    res.body = out.written();
}

/// POST /api/systems/:name/assets — bounded raw upload named by X-Filename.
pub fn uploadAssetApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    if (!try requireMutationHeader(req, res)) return;
    if (!canWrite(ctx)) return sendJsonError(res, 403, "writer role required");
    const body = req.body() orelse return sendJsonError(res, 400, "missing asset body");
    if (body.len == 0 or body.len > system_review_assets.max_asset_bytes)
        return sendJsonError(res, 413, "asset is empty or too large");
    const filename = req.header("x-filename") orelse return sendJsonError(res, 400, "missing X-Filename header");
    if (!system_review_assets.validFilename(filename))
        return sendJsonError(res, 400, "unsafe or unsupported asset filename");
    const kind = system_review_assets.kind(filename).?;
    if (!system_review_assets.validContent(kind, body))
        return sendJsonError(res, 400, "asset content does not match its extension");

    var mutation = vfs.beginMutation();
    defer mutation.deinit();
    var diagnostic: system_review.Diagnostic = .{};
    var loaded = (try loadSystemForRequest(ctx, req, res, &diagnostic)) orelse return;
    defer loaded.deinit(ctx.allocator);
    var scratch = std.heap.ArenaAllocator.init(ctx.allocator);
    defer scratch.deinit();
    const existing_assets = system_review_assets.enumerate(
        scratch.allocator(),
        ctx.project_dir,
        loaded.parsed.value.name,
    ) catch |err| return sendAssetPolicyFailure(res, err);
    for (existing_assets) |asset| {
        if (std.mem.eql(u8, asset.name, filename)) return sendJsonError(res, 409, "asset already exists");
    }
    system_review_assets.validateAddition(existing_assets, body.len) catch |err|
        return sendAssetPolicyFailure(res, err);

    const relative = try system_review_assets.relativePath(ctx.allocator, loaded.parsed.value.name, filename);
    defer ctx.allocator.free(relative);

    var ac_session = autocommit.begin(ctx.allocator, ctx.project_dir);
    defer if (ac_session) |*session| session.deinit();
    var vfs_response: std.ArrayList(u8) = .empty;
    defer vfs_response.deinit(ctx.allocator);
    if (!try invalidateManifestAttestation(ctx, &loaded, &vfs_response))
        return sendVfsFailure(res, vfs_response.items);
    vfs_response.clearRetainingCapacity();
    if (!try createVfsFile(ctx.allocator, ctx.project_dir, relative, body, &vfs_response)) {
        if (loaded.has_attestation_value)
            commitMutation(ctx, ac_session, "system_review_invalidate", loaded.manifest_rel, null);
        return sendVfsFailure(res, vfs_response.items);
    }
    commitMutation(
        ctx,
        ac_session,
        "system_review_asset",
        if (loaded.has_attestation_value) loaded.manifest_rel else null,
        relative,
    );

    var out: std.Io.Writer.Allocating = .init(res.arena);
    try out.writer.writeAll("{\"ok\":true,\"path\":");
    try json_writer.writeString(&out.writer, relative);
    try out.writer.print(",\"bytes\":{d}}}", .{body.len});
    res.content_type = .JSON;
    res.body = out.written();
}

fn sendAssetPolicyFailure(res: *httpz.Response, err: anyerror) HandlerError!void {
    if (err == error.TooManyAssets) return sendJsonError(res, 409, "workspace asset count limit reached");
    if (err == error.AssetTooLarge or err == error.AssetsTooLarge)
        return sendJsonError(res, 413, "workspace assets exceed their byte limit");
    const invalid = err == error.UnsafePath or err == error.UnsafeAssetEntry or
        err == error.UnsupportedAsset or err == error.InvalidAssetContent;
    if (invalid) return sendJsonError(res, 422, "workspace contains an unsafe or invalid asset");
    return sendJsonError(res, 500, "cannot inspect workspace assets");
}

fn setAssetContentType(res: *httpz.Response, kind: system_review_assets.Kind) void {
    switch (kind) {
        .png => res.content_type = .PNG,
        .jpeg => res.header("content-type", "image/jpeg"),
        .text => res.content_type = .TEXT,
    }
}

/// GET /api/systems/:name/assets/:asset — serve only whitelisted workspace assets.
pub fn getAssetApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const system_name = req.param("name") orelse return sendJsonError(res, 404, "missing system name");
    const filename = req.param("asset") orelse return sendJsonError(res, 404, "missing asset name");
    if (!isSimpleName(system_name) or !system_review_assets.validFilename(filename))
        return sendJsonError(res, 400, "invalid asset path");
    var diagnostic: system_review.Diagnostic = .{};
    var loaded = (try loadSystemForRequest(ctx, req, res, &diagnostic)) orelse return;
    defer loaded.deinit(ctx.allocator);
    const asset = system_review_assets.readAsset(
        res.arena,
        ctx.project_dir,
        loaded.parsed.value.name,
        filename,
    ) catch |err| {
        if (err == error.FileNotFound) return sendJsonError(res, 404, "asset not found");
        return sendAssetPolicyFailure(res, err);
    };
    setAssetContentType(res, system_review_assets.kind(filename).?);
    res.header("x-content-type-options", "nosniff");
    res.header("cache-control", "no-store");
    res.body = asset.data;
}

/// POST /api/systems/:name/attest — approve the complete current input set.
pub fn attestSystemApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    if (!try requireMutationHeader(req, res)) return;
    if (!canWrite(ctx)) return sendJsonError(res, 403, "writer role required");
    const actor = ctx.request_auth.username orelse return sendJsonError(res, 403, "authenticated writer required");
    const expected_content_lock = (try attestationConfirmation(ctx.allocator, req, res)) orelse return;

    var mutation = vfs.beginMutation();
    defer mutation.deinit();
    var diagnostic: system_review.Diagnostic = .{};
    var loaded = (try loadSystemForRequest(ctx, req, res, &diagnostic)) orelse return;
    defer loaded.deinit(ctx.allocator);

    const timestamp = try utcTimestamp(ctx.allocator);
    const result = system_review_package.attest(
        ctx.allocator,
        ctx.project_dir,
        loaded.parsed.value.name,
        expected_content_lock,
        actor,
        timestamp,
    ) catch |err| return sendPackageFailure(res, err, .attest);

    const patched = try patchTopLevelAttestation(ctx.allocator, loaded.raw, result.attestation_json);
    defer ctx.allocator.free(patched);
    if (patched.len > system_review.max_manifest_bytes)
        return sendJsonError(res, 422, "attested system manifest exceeds the 1 MiB limit");

    var ac_session = autocommit.begin(ctx.allocator, ctx.project_dir);
    defer if (ac_session) |*session| session.deinit();
    var vfs_response: std.ArrayList(u8) = .empty;
    defer vfs_response.deinit(ctx.allocator);
    if (!try writeVfsFile(
        ctx.allocator,
        ctx.project_dir,
        loaded.manifest_rel,
        patched,
        &loaded.sha256,
        &vfs_response,
    )) return sendVfsFailure(res, vfs_response.items);
    commitMutation(ctx, ac_session, "system_review_attest", loaded.manifest_rel, null);

    var out: std.Io.Writer.Allocating = .init(res.arena);
    try out.writer.writeAll("{\"ok\":true,\"content_lock\":");
    try json_writer.writeString(&out.writer, &result.readiness.content_lock);
    try out.writer.writeByte('}');
    res.content_type = .JSON;
    res.body = out.written();
}

const PackageOperation = enum { readiness, draft, attest, release };

fn sendPackageFailure(
    res: *httpz.Response,
    err: anyerror,
    operation: PackageOperation,
) HandlerError!void {
    const invalid_name = err == error.InvalidSystemName or err == error.SystemNameMismatch;
    if (invalid_name) return sendJsonError(res, 400, "invalid system name");
    if (err == error.FileNotFound or err == error.BoardNotFound)
        return sendJsonError(res, 404, "system review input not found");
    const gate_conflict = err == error.SystemReleaseBlocked or err == error.ConfirmationRequired or
        err == error.ChecklistIncomplete;
    const release_conflict = err == error.WaiverRequired or err == error.InputsChanged;
    const conflict = gate_conflict or release_conflict;
    if (conflict) return sendJsonError(res, 409, packageConflictMessage(err));
    const package_too_large = err == error.ArchiveTooLarge or err == error.BoardReleaseTooLarge or
        err == error.TooManyArchiveEntries;
    if (package_too_large) return sendJsonError(res, 413, "system review package exceeds the configured limit");
    const invalid_source = err == error.InvalidJson or err == error.InvalidManifest or
        err == error.InvalidDocument or err == error.ManifestTooLarge or
        err == error.SourceOutsideProject or err == error.UnsafeArchivePath or
        err == error.DuplicateArchiveEntry;
    const invalid_layout = err == error.LayoutNotFound or err == error.NoSavedLayout;
    const unsafe_asset = err == error.UnsafePath or err == error.UnsafeAssetEntry;
    const malformed_asset = err == error.UnsupportedAsset or err == error.InvalidAssetContent;
    const bounded_asset = err == error.AssetTooLarge or err == error.TooManyAssets or err == error.AssetsTooLarge;
    const invalid_assets = unsafe_asset or malformed_asset or bounded_asset;
    if (invalid_source or invalid_layout or invalid_assets)
        return sendJsonError(res, 422, "system review inputs are not package-valid");
    const message = switch (operation) {
        .readiness => "cannot compute system release readiness",
        .draft => "cannot compose system review draft",
        .attest => "cannot attest current system review inputs",
        .release => "cannot compose final system release",
    };
    return sendJsonError(res, 500, message);
}

fn packageConflictMessage(err: anyerror) []const u8 {
    if (err == error.ConfirmationRequired) return "content confirmation is missing or stale";
    if (err == error.ChecklistIncomplete) return "required release checklist is incomplete";
    if (err == error.WaiverRequired) return "explicit waiver acceptance is required";
    if (err == error.InputsChanged) return "release inputs changed during composition";
    return "system review workspace is not release-ready";
}

fn attachmentDisposition(allocator: std.mem.Allocator, filename: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "attachment; filename=\"{s}\"", .{filename});
}

const ReleaseRequest = struct {
    confirm: []const u8,
    waive: bool,
};

const ReleasePayload = struct {
    confirm: ?[]const u8 = null,
    waive: ?bool = null,
};

const AttestationPayload = struct {
    confirm: ?[]const u8 = null,
};

fn attestationConfirmation(
    allocator: std.mem.Allocator,
    req: *httpz.Request,
    res: *httpz.Response,
) HandlerError!?[]const u8 {
    const body = req.body() orelse {
        try sendJsonError(res, 400, "content-lock confirmation is required");
        return null;
    };
    if (body.len > max_release_request_bytes) {
        try sendJsonError(res, 413, "attestation request JSON is too large");
        return null;
    }
    var parsed = std.json.parseFromSlice(AttestationPayload, allocator, body, .{
        .ignore_unknown_fields = false,
    }) catch {
        try sendJsonError(res, 400, "invalid attestation JSON");
        return null;
    };
    defer parsed.deinit();
    const confirm = parsed.value.confirm orelse {
        try sendJsonError(res, 400, "content-lock confirmation is required");
        return null;
    };
    if (confirm.len != 64) {
        try sendJsonError(res, 400, "content-lock confirmation must be a SHA-256 value");
        return null;
    }
    return try allocator.dupe(u8, confirm);
}

fn releaseRequest(
    allocator: std.mem.Allocator,
    req: *httpz.Request,
    res: *httpz.Response,
) HandlerError!?ReleaseRequest {
    var body_confirm: ?[]const u8 = null;
    var body_waive: ?bool = null;
    if (req.body()) |body| {
        if (body.len > max_release_request_bytes) {
            try sendJsonError(res, 413, "release request JSON is too large");
            return null;
        }
        if (body.len > 0) {
            var parsed = std.json.parseFromSlice(ReleasePayload, allocator, body, .{
                .ignore_unknown_fields = false,
            }) catch {
                try sendJsonError(res, 400, "invalid release JSON");
                return null;
            };
            defer parsed.deinit();
            if (parsed.value.confirm) |confirm| body_confirm = try allocator.dupe(u8, confirm);
            body_waive = parsed.value.waive;
        }
    }
    const confirm = body_confirm orelse queryValue(req, "confirm") orelse {
        try sendJsonError(res, 400, "release confirmation token is required");
        return null;
    };
    if (confirm.len == 0) {
        try sendJsonError(res, 400, "release confirmation token is required");
        return null;
    }
    return .{
        .confirm = confirm,
        .waive = body_waive orelse queryFlag(req, "waive"),
    };
}

fn queryValue(req: *httpz.Request, key: []const u8) ?[]const u8 {
    const query = req.query() catch return null;
    return query.get(key);
}

fn queryFlag(req: *httpz.Request, key: []const u8) bool {
    const value = queryValue(req, key) orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

const AssemblyRenderContext = struct {
    ctx: *Server,
    req: *httpz.Request,
};

fn renderAssembly(
    raw_context: *anyopaque,
    input: fab_release_service.AssemblyInput,
) pcb_layout_page.HandlerError![]const u8 {
    const context: *AssemblyRenderContext = @ptrCast(@alignCast(raw_context));
    return pcb_layout_page.standaloneReleaseAssemblyHtml(
        context.ctx,
        context.req,
        input.name,
        input.block,
        input.view,
        input.identity,
    );
}

/// GET /api/systems/:name/readiness — the package composer's exact final gate.
pub fn readinessApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return sendJsonError(res, 404, "missing system name");
    const ready = system_review_package.readiness(ctx.allocator, ctx.project_dir, name) catch |err|
        return sendPackageFailure(res, err, .readiness);
    res.content_type = .JSON;
    res.header("cache-control", "no-store");
    res.body = ready.json;
}

/// GET /api/systems/:name/draft.zip — review-only archive with no CAM members.
pub fn draftPackageApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return sendJsonError(res, 404, "missing system name");
    const result = system_review_package.draft(ctx.allocator, ctx.project_dir, name) catch |err|
        return sendPackageFailure(res, err, .draft);
    const disposition = try attachmentDisposition(ctx.allocator, result.filename);
    res.header("content-type", "application/zip");
    res.header("content-disposition", disposition);
    res.header("cache-control", "no-store");
    res.body = result.zip;
}

/// POST /api/systems/:name/release — authenticated-writer final package after a fresh lock.
pub fn releaseApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    if (!try requireMutationHeader(req, res)) return;
    if (!canRelease(ctx)) return sendJsonError(res, 403, "writer role and authenticated identity required");
    const name = req.param("name") orelse return sendJsonError(res, 404, "missing system name");
    const options = (try releaseRequest(ctx.allocator, req, res)) orelse return;
    const actor = ctx.request_auth.username.?;

    var mutation = vfs.beginMutation();
    defer mutation.deinit();
    const timestamp = try utcTimestamp(ctx.allocator);
    var render_context = AssemblyRenderContext{ .ctx = ctx, .req = req };
    const result = system_review_package.release(
        ctx.allocator,
        ctx.project_dir,
        name,
        .{
            .confirm = options.confirm,
            .accept_waivers = options.waive,
            .actor = actor,
            .role = ctx.request_auth.role.toString(),
            .attested_at = timestamp,
        },
        .{ .context = &render_context, .render = renderAssembly },
    ) catch |err| return sendPackageFailure(res, err, .release);
    const disposition = try attachmentDisposition(ctx.allocator, result.filename);
    res.header("content-type", "application/zip");
    res.header("content-disposition", disposition);
    res.header("cache-control", "no-store");
    res.body = result.zip;
}

/// GET /systems/:name — focused browser workspace over the JSON endpoints.
pub fn systemPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var diagnostic: system_review.Diagnostic = .{};
    var loaded = (try loadSystemForRequest(ctx, req, res, &diagnostic)) orelse return;
    defer loaded.deinit(ctx.allocator);

    var out: std.Io.Writer.Allocating = .init(res.arena);
    const writer = &out.writer;
    try writer.writeAll(
        "<!doctype html><html><head><meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
            "<title>System review</title><style>" ++
            ":root{color-scheme:dark;font:14px/1.45 system-ui,sans-serif;background:#0b1020;color:#e8edf7}" ++
            "*{box-sizing:border-box}body{margin:0}button,input,textarea{font:inherit}" ++
            "header{display:flex;gap:18px;align-items:center;padding:18px 22px;border-bottom:1px solid #293249}" ++
            "header h1{font-size:20px;margin:0}header p{margin:2px 0 0;color:#9eabc2}.grow{flex:1}" ++
            "button,.button{border:1px solid #42506c;background:#172139;color:#e8edf7;border-radius:7px;padding:7px 11px;cursor:pointer;text-decoration:none}" ++
            "button.primary{background:#2864dc;border-color:#3977ef}button:disabled{opacity:.45;cursor:not-allowed}" ++
            "main{display:grid;grid-template-columns:260px minmax(360px,1fr) minmax(360px,1fr);height:calc(100vh - 76px)}" ++
            "aside,.editor,.preview{min-width:0;overflow:auto;padding:16px;border-right:1px solid #293249}" ++
            "#docs{display:grid;gap:6px;margin:14px 0}#docs button{text-align:left;background:transparent}" ++
            "#docs button.active{background:#1d2b49;border-color:#5b86d7}.tag{font-size:11px;color:#9eabc2;display:block}" ++
            "textarea{width:100%;height:calc(100vh - 205px);resize:none;border:1px solid #35415b;background:#090e19;color:#e8edf7;border-radius:8px;padding:14px;font:13px/1.5 ui-monospace,monospace}" ++
            ".toolbar{display:flex;gap:8px;align-items:center;margin-bottom:10px;min-height:34px}.toolbar strong{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" ++
            "#rendered{max-width:850px;margin:auto;color:#dfe6f2}#rendered img{max-width:100%}#rendered table{border-collapse:collapse;width:100%}" ++
            "#rendered td,#rendered th{border:1px solid #39455f;padding:6px}pre{white-space:pre-wrap}.status{padding:10px;border:1px solid #35415b;border-radius:8px;color:#aebbd0}" ++
            ".ok{color:#65d38e}.blocked{color:#ffb85c}#message{position:fixed;right:18px;bottom:18px;max-width:520px;background:#172139;border:1px solid #53617d;border-radius:8px;padding:10px;display:none}" ++
            "@media(max-width:1000px){main{grid-template-columns:220px 1fr}.preview{display:none}}" ++
            "</style></head><body><header><div><h1 id=\"title\">System review</h1><p id=\"identity\">Loading manifest…</p></div>" ++
            "<div class=\"grow\"></div><a class=\"button\" id=\"draft\">Download draft</a>" ++
            "<label><input id=\"waive\" type=\"checkbox\"> accept waivers</label><button id=\"release\">Final release</button></header>" ++
            "<main><aside><strong>Documents</strong><div id=\"docs\"></div><div class=\"status\" id=\"readiness\">Computing readiness…</div>" ++
            "<hr><label class=\"button\">Upload asset<input id=\"asset\" type=\"file\" accept=\".png,.jpg,.jpeg,.txt\" hidden></label></aside>" ++
            "<section class=\"editor\"><div class=\"toolbar\"><strong class=\"grow\" id=\"doc-title\">Select a document</strong>" ++
            "<button id=\"save\" class=\"primary\">Save</button><button id=\"attest\" disabled>Approve current inputs</button></div><textarea id=\"source\" spellcheck=\"false\" disabled></textarea></section>" ++
            "<section class=\"preview\"><div class=\"toolbar\"><strong>Safe preview</strong></div><article id=\"rendered\"></article></section></main>" ++
            "<div id=\"message\" role=\"status\"></div><script>\"use strict\";const SYSTEM=",
    );
    try json_writer.writeScriptString(writer, loaded.parsed.value.name);
    try writer.writeAll(
        ";const $=s=>document.querySelector(s);const state={manifest:null,permissions:null,current:null,ready:null};" ++
            "const endpoint=p=>'/api/systems/'+encodeURIComponent(SYSTEM)+p;" ++
            "function note(text,bad=false){const n=$('#message');n.textContent=text;n.style.display='block';n.style.borderColor=bad?'#a94b55':'#53617d';setTimeout(()=>n.style.display='none',5000)}" ++
            "async function request(url,options){const response=await fetch(url,options);const type=response.headers.get('content-type')||'';" ++
            "const value=type.includes('json')?await response.json():await response.text();if(!response.ok)throw new Error(value.error||value||('HTTP '+response.status));return {response,value}}" ++
            "function rewriteAssets(){for(const node of $('#rendered').querySelectorAll('[src],[href]')){const attr=node.hasAttribute('src')?'src':'href';const value=node.getAttribute(attr);" ++
            "if(value&&value.startsWith('assets/')&&!value.slice(7).includes('/'))node.setAttribute(attr,endpoint('/assets/'+encodeURIComponent(value.slice(7))))}}" ++
            "async function openDoc(spec,button){document.querySelectorAll('#docs button').forEach(b=>b.classList.remove('active'));button.classList.add('active');" ++
            "const {value}=await request(endpoint('/docs/'+encodeURIComponent(spec.id)));state.current=value;$('#doc-title').textContent=value.title+' · '+value.classification;" ++
            "$('#source').value=value.markdown;$('#source').disabled=!value.editable;$('#save').disabled=!value.editable;$('#attest').disabled=!state.permissions.write||!state.ready||!state.ready.checks.checklists;" ++
            "$('#rendered').innerHTML=value.html||'<pre></pre>';if(!value.html)$('#rendered pre').textContent=value.markdown;rewriteAssets()}" ++
            "async function refreshReady(){try{const {value}=await request(endpoint('/readiness'));state.ready=value;const r=$('#readiness');" ++
            "r.className='status '+(value.blocked?'blocked':'ok');r.textContent=(value.blocked?'Blocked':'Ready')+' · checklists '+(value.checks&&value.checks.checklists?'complete':'open')+' · attestation '+(value.attested?'current':'needed');" ++
            "$('#attest').disabled=!state.permissions.write||!value.checks||!value.checks.checklists;" ++
            "$('#release').disabled=!state.permissions.release||value.blocked}catch(error){$('#readiness').textContent=error.message;$('#readiness').className='status blocked'}}" ++
            "async function boot(){try{const {value}=await request(endpoint(''));state.manifest=value.manifest;state.permissions=value.permissions;$('#attest').disabled=!value.permissions.write;" ++
            "$('#title').textContent=value.manifest.title;$('#identity').textContent=value.manifest.part_number+' · revision '+value.manifest.revision+' · '+value.permissions.role;" ++
            "$('#draft').href=endpoint('/draft.zip');const host=$('#docs');let first=null;for(const doc of value.manifest.documents){const button=document.createElement('button');" ++
            "button.type='button';button.append(document.createTextNode(doc.title));const tag=document.createElement('span');tag.className='tag';tag.textContent=doc.classification+' · '+(doc.status||'active');button.append(tag);" ++
            "button.onclick=()=>openDoc(doc,button).catch(e=>note(e.message,true));host.append(button);if(!first&&doc.status!=='historical')first=[doc,button]}if(!first&&value.manifest.documents.length)first=[value.manifest.documents[0],host.firstElementChild];" ++
            "if(first)await openDoc(first[0],first[1]);await refreshReady()}catch(error){note(error.message,true)}}" ++
            "$('#save').onclick=async()=>{if(!state.current)return;try{const headers={'content-type':'text/markdown; charset=utf-8','x-netlisp-review':'1'};if(state.current.sha256)headers['if-match']=state.current.sha256;else headers['if-none-match']='*';const {value}=await request(endpoint('/docs/'+encodeURIComponent(state.current.id)),{method:'PUT',headers:headers,body:$('#source').value});" ++
            "state.current.sha256=value.sha256;note('Saved; prior attestation invalidated');await refreshReady();const active=document.querySelector('#docs button.active');if(active)active.click()}catch(error){note(error.message,true)}};" ++
            "$('#attest').onclick=async()=>{if(!state.ready)return;try{await request(endpoint('/attest'),{method:'POST',headers:{'content-type':'application/json','x-netlisp-review':'1'},body:JSON.stringify({confirm:state.ready.content_lock})});note('Current review inputs approved');await refreshReady()}catch(error){note(error.message,true)}};" ++
            "$('#asset').onchange=async event=>{const file=event.target.files[0];if(!file)return;try{await request(endpoint('/assets'),{method:'POST',headers:{'x-filename':file.name,'x-netlisp-review':'1'},body:file});note('Asset uploaded: '+file.name);await refreshReady()}catch(error){note(error.message,true)}event.target.value=''};" ++
            "$('#release').onclick=async()=>{if(!state.ready||!confirm('Compose the final fabrication release for this exact review lock?'))return;try{const result=await fetch(endpoint('/release'),{method:'POST',headers:{'content-type':'application/json','x-netlisp-review':'1'},body:JSON.stringify({confirm:state.ready.release_token,waive:$('#waive').checked})});" ++
            "if(!result.ok){const error=await result.json();throw new Error(error.error||'release failed')}const blob=await result.blob();const disposition=result.headers.get('content-disposition')||'';const match=/filename=\"([^\"]+)\"/.exec(disposition);" ++
            "const link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download=match?match[1]:(SYSTEM+'-release.zip');link.click();setTimeout(()=>URL.revokeObjectURL(link.href),1000)}catch(error){note(error.message,true)}};boot();" ++
            "</script></body></html>",
    );
    res.content_type = .HTML;
    res.header("cache-control", "no-store");
    res.header("content-security-policy", "frame-ancestors 'none'");
    res.header("x-frame-options", "DENY");
    res.body = out.written();
}

test "system review API path and asset policy rejects traversal and active content" {
    try std.testing.expect(isSimpleName("barracuda_2"));
    try std.testing.expect(!isSimpleName("../barracuda"));
    try std.testing.expect(system_review_assets.validFilename("scope-front.png"));
    try std.testing.expect(!system_review_assets.validFilename("../scope.png"));
    try std.testing.expect(!system_review_assets.validFilename("active.svg"));
    try std.testing.expect(!system_review_assets.validFilename("active.pdf"));
    try std.testing.expect(!system_review_assets.validContent(.png, "not a png"));
    try std.testing.expectEqualStrings(
        "required release checklist is incomplete",
        packageConflictMessage(error.ChecklistIncomplete),
    );
}

// spec: system-review - system-review mutations require the custom review header, document replacement requires If-Match, and release JSON is size-bounded
test "system review API enforces mutation header document CAS and release body bounds" {
    var missing_header = httpz.testing.init(.{});
    defer missing_header.deinit();
    try std.testing.expect(!try requireMutationHeader(missing_header.req, missing_header.res));
    try std.testing.expectEqual(@as(u16, 403), missing_header.res.status);

    var approved_header = httpz.testing.init(.{});
    defer approved_header.deinit();
    approved_header.header(mutation_header_name, mutation_header_value);
    try std.testing.expect(try requireMutationHeader(approved_header.req, approved_header.res));

    var missing_match = httpz.testing.init(.{});
    defer missing_match.deinit();
    try std.testing.expect(!try validateExpectedDocument(missing_match.req, missing_match.res, @splat('a')));
    try std.testing.expectEqual(@as(u16, 428), missing_match.res.status);

    var stale_match = httpz.testing.init(.{});
    defer stale_match.deinit();
    stale_match.header("if-match", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    try std.testing.expect(!try validateExpectedDocument(stale_match.req, stale_match.res, @splat('a')));
    try std.testing.expectEqual(@as(u16, 409), stale_match.res.status);

    var current_match = httpz.testing.init(.{});
    defer current_match.deinit();
    const current_digest: [64]u8 = @splat('a');
    current_match.header("if-match", &current_digest);
    try std.testing.expect(try validateExpectedDocument(current_match.req, current_match.res, current_digest));

    var missing_create_match = httpz.testing.init(.{});
    defer missing_create_match.deinit();
    try std.testing.expect(!try validateExpectedDocument(missing_create_match.req, missing_create_match.res, null));
    try std.testing.expectEqual(@as(u16, 428), missing_create_match.res.status);

    var create_match = httpz.testing.init(.{});
    defer create_match.deinit();
    create_match.header("if-none-match", "*");
    try std.testing.expect(try validateExpectedDocument(create_match.req, create_match.res, null));

    var oversized_release = httpz.testing.init(.{});
    defer oversized_release.deinit();
    const oversized: [max_release_request_bytes + 1]u8 = @splat('x');
    oversized_release.body(&oversized);
    try std.testing.expect((try releaseRequest(std.testing.allocator, oversized_release.req, oversized_release.res)) == null);
    try std.testing.expectEqual(@as(u16, 413), oversized_release.res.status);
}

test "system review API patches only the top-level attestation value" {
    const source =
        "{\"title\":\"attestation in a string\",\"nested\":{\"attestation\":false},\"attestation\":null}";
    const patched = try patchTopLevelAttestation(std.testing.allocator, source, "{\"system_lock_sha256\":\"lock\"}");
    defer std.testing.allocator.free(patched);
    try std.testing.expect(std.mem.indexOf(u8, patched, "\"nested\":{\"attestation\":false}") != null);
    try std.testing.expect(std.mem.endsWith(u8, patched, "\"attestation\":{\"system_lock_sha256\":\"lock\"}}"));
}

test "system review API denies document mutation without authenticated write role" {
    var state: serve_root.ServerState = .{};
    var server = Server{
        .allocator = std.testing.allocator,
        .project_dir = ".",
        .auth_dir = ".",
        .state = &state,
    };
    var request = httpz.testing.init(.{});
    defer request.deinit();
    request.param("name", "barracuda");
    request.param("doc", "overview");
    request.header(mutation_header_name, mutation_header_value);
    request.body("# Unauthorized edit\n");
    try putDocumentApi(&server, request.req, request.res);
    try std.testing.expectEqual(@as(u16, 403), request.res.status);
    try std.testing.expect(std.mem.indexOf(u8, request.res.body, "writer role required") != null);
}

test "system review API creates a declared missing document with an absent-only precondition" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "project/src/systems/demo");
    // Prevent git from walking out of the fixture into the enclosing checkout;
    // this test exercises VFS/API semantics, not auto-commit integration.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/.git",
        .data = "gitdir: /nonexistent/system-review-fixture\n",
    });
    const manifest =
        \\{"schema":"netlisp-system-review-v1","name":"demo","title":"Demo","part_number":"SYS-1","revision":"A","boards":[{"name":"board","role":"main","source":"src/board.sexp","part_number":"PCB-1","revision":"A"}],"documents":[{"id":"release-checklist","title":"Release checklist","path":"src/systems/demo/release.md","classification":"checklist","required":true}]}
    ;
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "project/src/systems/demo/system.json",
        .data = manifest,
    });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, "project", allocator);
    defer allocator.free(project);

    var state: serve_root.ServerState = .{};
    var server = Server{
        .allocator = allocator,
        .project_dir = project,
        .auth_dir = project,
        .request_auth = .{ .username = "writer@example.com", .role = .writer },
        .state = &state,
    };

    var get_request = httpz.testing.init(.{});
    defer get_request.deinit();
    server.allocator = get_request.res.arena;
    get_request.param("name", "demo");
    get_request.param("doc", "release-checklist");
    try getDocumentApi(&server, get_request.req, get_request.res);
    try std.testing.expect(std.mem.indexOf(u8, get_request.res.body, "\"exists\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, get_request.res.body, "\"sha256\":null") != null);

    var put_request = httpz.testing.init(.{});
    defer put_request.deinit();
    server.allocator = put_request.res.arena;
    put_request.param("name", "demo");
    put_request.param("doc", "release-checklist");
    put_request.header(mutation_header_name, mutation_header_value);
    put_request.header("if-none-match", "*");
    put_request.body("# Release checklist\n\n- [ ] Review board evidence\n");
    try putDocumentApi(&server, put_request.req, put_request.res);
    try std.testing.expect(std.mem.indexOf(u8, put_request.res.body, "\"ok\":true") != null);

    const created = try tmp.dir.readFileAlloc(
        std.testing.io,
        "project/src/systems/demo/release.md",
        allocator,
        .limited64(1024),
    );
    defer allocator.free(created);
    try std.testing.expectEqualStrings("# Release checklist\n\n- [ ] Review board evidence\n", created);
}
