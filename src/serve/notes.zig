//! Design-level notes sidecar: structured TODO log stored as
//! `<design>.notes.md` next to the source `.sexp`. Each TODO becomes a
//! markdown checkbox line so the file stays human-readable; the parser
//! is tolerant — any non-task line is preserved as free-form scratchpad
//! content. The same file backs both the web UI and the MCP tools, so
//! agents can `add_design_note`, `complete_design_note`, etc.
//!
//! Canonical line format:
//!     - [ ] YYYY-MM-DD (id8) free-form text
//!     - [x] YYYY-MM-DD -> YYYY-MM-DD (id8) free-form text
//!
//! `id8` is an 8-char lowercase hex id. The completion arrow + date are
//! only present when the task is done. On serialize, tasks float to the
//! top of the file with the scratchpad text below a blank line.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const infra_random = @import("../infra/random.zig");
const clock = @import("../infra/clock.zig");
const paths = @import("../paths.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const json_writer = @import("../json_writer.zig");

const max_notes_bytes: usize = 1 * 1024 * 1024;
const iso_date_len: usize = 10; // YYYY-MM-DD
const note_id_hex_len: usize = 8;
const arrow_glyph = " -> ";
const task_open_prefix = "- [ ] ";
const task_done_prefix = "- [x] ";

// HTTP status codes
const http_bad_request: u16 = 400;
const http_not_found: u16 = 404;
const http_payload_too_large: u16 = 413;
const http_internal_error: u16 = 500;

// JSON / header literals reused across handlers
const cors_header = "access-control-allow-origin";
const err_missing_name = "{\"error\":\"missing name\"}";
const err_no_body = "{\"error\":\"no body\"}";
const err_invalid_json = "{\"error\":\"invalid json\"}";
const err_resolve_path = "{\"error\":\"cannot resolve notes path\"}";
const err_read_notes = "{\"error\":\"cannot read notes\"}";
const err_write_notes = "{\"error\":\"cannot write notes\"}";
const err_not_object = "{\"error\":\"body must be a JSON object\"}";
const ok_json = "{\"ok\":true}";

pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    error{ StreamTooLong, EndOfStream };

pub const NoteStatus = enum { open, done };

pub const Note = struct {
    id: []const u8,
    text: []const u8,
    created: []const u8, // YYYY-MM-DD
    completed: ?[]const u8 = null, // YYYY-MM-DD when status == .done
};

pub const Notes = struct {
    tasks: []Note,
    scratchpad: []const u8,
};

fn notesPath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]u8 {
    const src = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(src);
    const dir = std.fs.path.dirname(src) orelse "";
    if (dir.len == 0) return std.fmt.allocPrint(allocator, "{s}.notes.md", .{name});
    return std.fmt.allocPrint(allocator, "{s}/{s}.notes.md", .{ dir, name });
}

/// Parse a notes-file body into structured tasks + scratchpad. The task
/// slice and the scratchpad are both allocated and owned by the caller
/// (free each via `allocator`); the string fields *inside* each Note still
/// borrow from `raw`, so the caller must keep `raw` alive while using the
/// task text/ids.
pub fn parseNotes(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error!Notes {
    var tasks: std.ArrayList(Note) = .empty;
    var scratch: std.ArrayList(u8) = .empty;
    var first_scratch = true;

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line| {
        if (parseTaskLine(line)) |task| {
            try tasks.append(allocator, task);
            continue;
        }
        if (!first_scratch) try scratch.append(allocator, '\n');
        try scratch.appendSlice(allocator, line);
        first_scratch = false;
    }

    // Trim surrounding blank lines: trailing ones so we don't re-emit them on
    // every save, and any leading blank lines — the separator renderNotes puts
    // between the task list and the scratchpad — so a save/load round-trip stays
    // stable instead of accreting blank lines each cycle. The scratchpad is
    // returned as an owned slice: `scratch` is heap-backed whenever any
    // scratchpad line exists, and prior code leaked it (returned a view without
    // freeing the buffer).
    defer scratch.deinit(allocator);
    defer tasks.deinit(allocator); // no-op after a successful toOwnedSlice; frees the buffer if it OOMs
    const scratch_trimmed = std.mem.trimRight(u8, std.mem.trimLeft(u8, scratch.items, "\n\r"), "\n\r \t");

    const tasks_owned = try tasks.toOwnedSlice(allocator);
    errdefer allocator.free(tasks_owned);
    return .{
        .tasks = tasks_owned,
        .scratchpad = try allocator.dupe(u8, scratch_trimmed),
    };
}

/// Match `- [ ] YYYY-MM-DD (id) text` or `- [x] YYYY-MM-DD -> YYYY-MM-DD (id) text`.
fn parseTaskLine(line: []const u8) ?Note {
    var rest: []const u8 = line;
    var status: NoteStatus = .open;
    if (std.mem.startsWith(u8, rest, task_open_prefix)) {
        rest = rest[task_open_prefix.len..];
    } else if (std.mem.startsWith(u8, rest, task_done_prefix) or std.mem.startsWith(u8, rest, "- [X] ")) {
        rest = rest[task_done_prefix.len..];
        status = .done;
    } else return null;

    if (rest.len < iso_date_len or !isIsoDate(rest[0..iso_date_len])) return null;
    const created = rest[0..iso_date_len];
    rest = rest[iso_date_len..];

    var completed: ?[]const u8 = null;
    if (status == .done) {
        if (!std.mem.startsWith(u8, rest, arrow_glyph) or rest.len < arrow_glyph.len + iso_date_len) return null;
        rest = rest[arrow_glyph.len..];
        if (!isIsoDate(rest[0..iso_date_len])) return null;
        completed = rest[0..iso_date_len];
        rest = rest[iso_date_len..];
    }

    if (rest.len < 4 or rest[0] != ' ' or rest[1] != '(') return null;
    rest = rest[2..];
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse return null;
    const id = rest[0..close];
    if (id.len == 0 or id.len > 32) return null;
    for (id) |c| if (!std.ascii.isHex(c)) return null;
    rest = rest[close + 1 ..];

    if (rest.len < 2 or rest[0] != ' ') return null;
    const text = rest[1..];

    return .{ .id = id, .text = text, .created = created, .completed = completed };
}

fn isIsoDate(s: []const u8) bool {
    if (s.len != iso_date_len) return false;
    for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| if (!std.ascii.isDigit(s[i])) return false;
    if (s[4] != '-' or s[7] != '-') return false;
    return true;
}

/// Render `Notes` as canonical markdown: tasks first (in given order),
/// blank line, then scratchpad. Returns allocated bytes the caller owns.
pub fn renderNotes(allocator: std.mem.Allocator, notes: Notes) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = out.writer(allocator);
    for (notes.tasks) |t| try writeTaskLine(w, t);
    if (notes.scratchpad.len > 0) {
        if (notes.tasks.len > 0) try w.writeAll("\n");
        try w.writeAll(notes.scratchpad);
        if (notes.scratchpad[notes.scratchpad.len - 1] != '\n') try w.writeAll("\n");
    }
    return out.toOwnedSlice(allocator);
}

fn writeTaskLine(w: anytype, t: Note) !void {
    if (t.completed) |done| {
        try w.print("{s}{s} -> {s} ({s}) {s}\n", .{ task_done_prefix, t.created, done, t.id, t.text });
    } else {
        try w.print("{s}{s} ({s}) {s}\n", .{ task_open_prefix, t.created, t.id, t.text });
    }
}

/// Generate a random 8-char lowercase hex id. Collisions across a
/// per-design TODO list are astronomically unlikely for a 32-bit space.
fn generateNoteId(allocator: std.mem.Allocator) ![]u8 {
    var bytes: [4]u8 = undefined;
    infra_random.bytes(&bytes);
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
}

/// Return today's UTC date as `YYYY-MM-DD`. Allocates 10 bytes.
fn todayIsoDate(allocator: std.mem.Allocator) ![]u8 {
    const now_s: i64 = clock.timestamp();
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(now_s) };
    const ed = es.getEpochDay();
    const yd = ed.calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u32, yd.year),
        @intFromEnum(md.month),
        md.day_index + 1,
    });
}

/// Read and parse the notes file. Returns an empty `Notes` when the
/// file doesn't exist yet. The returned slices borrow from `out_raw`,
/// which the caller owns and must free after using the parse result.
pub fn loadNotes(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    out_raw: *?[]u8,
) !Notes {
    const path = try notesPath(allocator, project_dir, name);
    defer allocator.free(path);
    const data = infra_fs.cwd().readFileAlloc(allocator, path, max_notes_bytes) catch |e| switch (e) {
        error.FileNotFound => {
            out_raw.* = null;
            return .{ .tasks = &.{}, .scratchpad = "" };
        },
        else => return e,
    };
    out_raw.* = data;
    return parseNotes(allocator, data);
}

/// Serialize and write `notes` to the file. Overwrites whatever was
/// there. Creates the file if missing.
fn writeNotesFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    notes: Notes,
) !void {
    const path = try notesPath(allocator, project_dir, name);
    defer allocator.free(path);
    const body = try renderNotes(allocator, notes);
    defer allocator.free(body);
    const file = try infra_fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(body);
}

// ── HTTP handlers ────────────────────────────────────────────────────

fn writeNoteJson(w: anytype, t: Note) !void {
    try w.writeAll("{\"id\":");
    try json_writer.writeString(w, t.id);
    try w.writeAll(",\"text\":");
    try json_writer.writeString(w, t.text);
    try w.writeAll(",\"created\":");
    try json_writer.writeString(w, t.created);
    if (t.completed) |c| {
        try w.writeAll(",\"completed\":");
        try json_writer.writeString(w, c);
    } else {
        try w.writeAll(",\"completed\":null");
    }
    try w.writeAll("}");
}

fn writeTasksJson(allocator: std.mem.Allocator, w: anytype, notes: Notes) !void {
    try w.writeAll("{\"tasks\":[");
    for (notes.tasks, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try writeNoteJson(w, t);
    }
    try w.writeAll("],\"scratchpad\":");
    try json_writer.writeString(w, notes.scratchpad);
    try w.writeAll("}");
    _ = allocator;
}

fn jsonError(res: *httpz.Response, status: u16, msg: []const u8) void {
    res.status = status;
    res.body = msg;
}

fn setJsonHeaders(res: *httpz.Response) void {
    res.content_type = .JSON;
    res.header(cors_header, "*");
}

/// GET /api/notes/:name — `{"text":"<raw markdown>"}`. Kept for the
/// raw textarea fallback and any caller that wants the full document.
pub fn getNotesApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    setJsonHeaders(res);

    const name = req.param("name") orelse return jsonError(res, http_not_found, err_missing_name);

    const path = notesPath(ctx.allocator, ctx.project_dir, name) catch return jsonError(res, http_internal_error, err_resolve_path);
    defer ctx.allocator.free(path);

    const data: ?[]u8 = infra_fs.cwd().readFileAlloc(ctx.allocator, path, max_notes_bytes) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return jsonError(res, http_internal_error, err_read_notes),
    };
    defer if (data) |d| ctx.allocator.free(d);
    const text: []const u8 = data orelse "";

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"text\":");
    try json_writer.writeString(w, text);
    try w.writeAll("}");
    res.body = buf.items;
}

/// PUT /api/notes/:name — body `{"text":"<raw markdown>"}`. Writes the
/// full file. Kept for the raw textarea editor; the structured ops
/// below are preferred for programmatic edits.
pub fn saveNotesApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    setJsonHeaders(res);

    const name = req.param("name") orelse return jsonError(res, http_not_found, err_missing_name);
    const body = req.body() orelse return jsonError(res, http_bad_request, err_no_body);

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch
        return jsonError(res, http_bad_request, err_invalid_json);
    defer parsed.deinit();
    if (parsed.value != .object) return jsonError(res, http_bad_request, err_not_object);
    const text_val = parsed.value.object.get("text") orelse return jsonError(res, http_bad_request, "{\"error\":\"missing text\"}");
    if (text_val != .string) return jsonError(res, http_bad_request, "{\"error\":\"text must be a string\"}");
    if (text_val.string.len > max_notes_bytes) return jsonError(res, http_payload_too_large, "{\"error\":\"notes too large\"}");

    const path = notesPath(ctx.allocator, ctx.project_dir, name) catch return jsonError(res, http_internal_error, err_resolve_path);
    defer ctx.allocator.free(path);
    const file = infra_fs.cwd().createFile(path, .{}) catch return jsonError(res, http_internal_error, err_write_notes);
    defer file.close();
    file.writeAll(text_val.string) catch return jsonError(res, http_internal_error, "{\"error\":\"write failed\"}");

    res.body = ok_json;
}

/// GET /api/notes/:name/tasks — `{"tasks":[…],"scratchpad":"…"}`. Used
/// by the web UI to render the structured TODO list.
pub fn getTasksApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    setJsonHeaders(res);
    const name = req.param("name") orelse return jsonError(res, http_not_found, err_missing_name);

    var raw: ?[]u8 = null;
    const notes = loadNotes(ctx.allocator, ctx.project_dir, name, &raw) catch
        return jsonError(res, http_internal_error, err_read_notes);
    defer if (raw) |d| ctx.allocator.free(d);

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try writeTasksJson(ctx.allocator, w, notes);
    res.body = buf.items;
}

/// POST /api/notes/:name/tasks/add — body `{"text":"…"}`. Appends a new
/// open task with today's date and a fresh id. Returns the new task.
pub fn addTaskApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    setJsonHeaders(res);
    const name = req.param("name") orelse return jsonError(res, http_not_found, err_missing_name);
    const body = req.body() orelse return jsonError(res, http_bad_request, err_no_body);

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch
        return jsonError(res, http_bad_request, err_invalid_json);
    defer parsed.deinit();
    if (parsed.value != .object) return jsonError(res, http_bad_request, err_not_object);
    const text_val = parsed.value.object.get("text") orelse return jsonError(res, http_bad_request, "{\"error\":\"missing text\"}");
    if (text_val != .string or text_val.string.len == 0)
        return jsonError(res, http_bad_request, "{\"error\":\"text must be a non-empty string\"}");

    const new_task = addTaskCore(ctx.allocator, ctx.project_dir, name, text_val.string) catch
        return jsonError(res, http_internal_error, "{\"error\":\"add failed\"}");

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"ok\":true,\"task\":");
    try writeNoteJson(w, new_task);
    try w.writeAll("}");
    res.body = buf.items;
}

/// POST /api/notes/:name/tasks/complete — body `{"id":"…"}`. Stamps
/// today's date into `completed`. No-ops if already done.
pub fn completeTaskApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    try mutateTaskByIdApi(ctx, req, res, .complete);
}

/// POST /api/notes/:name/tasks/reopen — body `{"id":"…"}`. Clears the
/// completion date so the task moves back to the open list.
pub fn reopenTaskApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    try mutateTaskByIdApi(ctx, req, res, .reopen);
}

/// POST /api/notes/:name/tasks/remove — body `{"id":"…"}`. Deletes the
/// task from the file (the scratchpad is left intact).
pub fn removeTaskApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    try mutateTaskByIdApi(ctx, req, res, .remove);
}

pub const TaskMutation = enum { complete, reopen, remove };

fn mutateTaskByIdApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response, mode: TaskMutation) HandlerError!void {
    setJsonHeaders(res);
    const name = req.param("name") orelse return jsonError(res, http_not_found, err_missing_name);
    const body = req.body() orelse return jsonError(res, http_bad_request, err_no_body);

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch
        return jsonError(res, http_bad_request, err_invalid_json);
    defer parsed.deinit();
    if (parsed.value != .object) return jsonError(res, http_bad_request, err_not_object);
    const id_val = parsed.value.object.get("id") orelse return jsonError(res, http_bad_request, "{\"error\":\"missing id\"}");
    if (id_val != .string or id_val.string.len == 0)
        return jsonError(res, http_bad_request, "{\"error\":\"id must be a non-empty string\"}");

    const result = mutateTaskCore(ctx.allocator, ctx.project_dir, name, id_val.string, mode) catch
        return jsonError(res, http_internal_error, "{\"error\":\"mutate failed\"}");
    if (result == null) return jsonError(res, http_not_found, "{\"error\":\"task id not found\"}");

    res.body = ok_json;
}

// ── Core mutation helpers (shared with MCP) ──────────────────────────

/// Add a task with today's date. Caller owns the returned `Note`'s
/// slices via the design's notes file (which becomes the source of
/// truth after this call). Returns the new task fields.
pub fn addTaskCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    text: []const u8,
) !Note {
    var raw: ?[]u8 = null;
    const notes = try loadNotes(allocator, project_dir, name, &raw);
    defer if (raw) |d| allocator.free(d);

    const id = try generateNoteId(allocator);
    const today = try todayIsoDate(allocator);

    var list = std.ArrayList(Note).fromOwnedSlice(notes.tasks);
    try list.append(allocator, .{ .id = id, .text = text, .created = today, .completed = null });

    const new_notes: Notes = .{ .tasks = list.items, .scratchpad = notes.scratchpad };
    try writeNotesFile(allocator, project_dir, name, new_notes);

    return .{ .id = id, .text = text, .created = today, .completed = null };
}

/// Apply `mode` to the task with the given id. Returns `null` when the
/// id is not present so callers can surface a 404. Returns `true` on
/// any other outcome (state change or no-op for an already-complete
/// task being completed again).
pub fn mutateTaskCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    id: []const u8,
    mode: TaskMutation,
) !?bool {
    var raw: ?[]u8 = null;
    const notes = try loadNotes(allocator, project_dir, name, &raw);
    defer if (raw) |d| allocator.free(d);

    var found = false;
    var out_tasks: std.ArrayList(Note) = .empty;
    for (notes.tasks) |t| {
        const is_target = std.mem.eql(u8, t.id, id);
        if (is_target) found = true;
        const next = if (is_target) try applyMutation(allocator, t, mode) else t;
        if (mode == .remove and is_target) continue;
        try out_tasks.append(allocator, next);
    }
    if (!found) return null;

    const new_notes: Notes = .{ .tasks = out_tasks.items, .scratchpad = notes.scratchpad };
    try writeNotesFile(allocator, project_dir, name, new_notes);
    return true;
}

/// Apply the mutation to a single task. `remove` returns the task
/// unchanged; the caller drops it via the `mode == .remove` check.
fn applyMutation(allocator: std.mem.Allocator, t: Note, mode: TaskMutation) !Note {
    return switch (mode) {
        .complete => if (t.completed != null) t else .{
            .id = t.id,
            .text = t.text,
            .created = t.created,
            .completed = try todayIsoDate(allocator),
        },
        .reopen => .{ .id = t.id, .text = t.text, .created = t.created, .completed = null },
        .remove => t,
    };
}

// ── Tests ────────────────────────────────────────────────────────────

// spec: serve/notes - Parses open and done task lines and preserves scratchpad
test "parse round-trips open and done tasks" {
    const allocator = std.testing.allocator;
    const raw =
        \\- [ ] 2026-05-15 (a1b2c3d4) Screen LED pins backwards, swap PE5 and PE6
        \\- [x] 2026-05-13 -> 2026-05-15 (e5f6a7b8) Decoupling on VDDCORE rebalanced
        \\
        \\Free-form scratchpad note here.
    ;
    const notes = try parseNotes(allocator, raw);
    defer allocator.free(notes.tasks);
    defer allocator.free(notes.scratchpad);
    try std.testing.expectEqual(@as(usize, 2), notes.tasks.len);
    try std.testing.expectEqualStrings("a1b2c3d4", notes.tasks[0].id);
    try std.testing.expect(notes.tasks[0].completed == null);
    try std.testing.expectEqualStrings("e5f6a7b8", notes.tasks[1].id);
    try std.testing.expectEqualStrings("2026-05-15", notes.tasks[1].completed.?);
    try std.testing.expectEqualStrings("Free-form scratchpad note here.", notes.scratchpad);

    const rendered = try renderNotes(allocator, notes);
    defer allocator.free(rendered);
    // Render is canonical: tasks then blank line then scratch + trailing newline.
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Screen LED pins backwards") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "Decoupling on VDDCORE rebalanced") != null);
    try std.testing.expect(std.mem.endsWith(u8, rendered, "Free-form scratchpad note here.\n"));
}

// spec: serve/notes - Ignores lines that don't match the structured task format
test "parse treats malformed task-like lines as scratchpad" {
    const allocator = std.testing.allocator;
    const notes = try parseNotes(allocator, "- [ ] not a date (abc) text\n- [?] unknown\n");
    defer allocator.free(notes.tasks);
    defer allocator.free(notes.scratchpad);
    try std.testing.expectEqual(@as(usize, 0), notes.tasks.len);
    try std.testing.expect(std.mem.indexOf(u8, notes.scratchpad, "not a date") != null);
}
