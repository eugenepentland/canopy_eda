//! Interaction log: what the server and the browser actually DID, on disk, in
//! one append-only JSONL file per day.
//!
//! It exists because "which part of this request is slow" had no tool
//! (FEEDBACK.md, 2026-08-28): `bench-page` measures page renders, `drc-dump`
//! measures the two DRC seams, and neither sees a handler. A `std.debug.print`
//! from a serve worker is banned by Guardian and does not reach the server log
//! anyway, so every past investigation needed a throwaway instrumentation
//! patch and three rebuilds. This module is that instrumentation, shipped.
//!
//! One JSON object per line, appended to
//! `<project_dir>/logs/interactions-YYYY-MM-DD.jsonl`. Every line carries
//! `ts` / `build` / `src` / `evt`:
//!
//!     evt "req"           one per dispatched request (method, path, status,
//!                         ms, bytes in/out) — the whole-handler cost
//!     evt "stages"        the phase breakdown of an instrumented handler
//!     evt "server.start"  one line per process, naming port + project dir
//!     src "client"        a browser event posted to /api/client-log/:name
//!
//! `build` is `build_id.current()`, because this tree moves fast enough that a
//! log which does not say which code produced it is not evidence.
//!
//! THREE RULES, all of them load-bearing:
//!
//!  1. **Never fail a request.** Every path here swallows its own errors and
//!     returns; a full disk must cost a log line, not a save.
//!  2. **Never log design content.** Sizes, counts, names, timings only. A
//!     board's copper is not diagnostic data.
//!  3. **Never format a duration from the wall clock.** `clock.monotonicNanos`
//!     is what a stage timer subtracts, so an NTP step cannot invent a
//!     negative stage.
//!
//! Writes are serialized by the store's own mutex (the `live_version_mutex`
//! pattern in `serve.zig`), which covers every httpz worker thread in this
//! process. Two SERVERS sharing one project directory can still interleave —
//! the append is a `stat` then a positioned write, not `O_APPEND` — which is a
//! deliberate trade: nothing in this tree runs two servers on one project dir,
//! and the alternative is a held handle that outlives the day boundary.
//!
//! A default-constructed `Store` has no project directory and writes nothing,
//! so a bare test `ServerState` logs nowhere; `serve()` is what turns it on.

const std = @import("std");
const httpz = @import("httpz");

const build_id = @import("../build_id.zig");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const serve_root = @import("../serve.zig");

const Server = serve_root.Server;

/// Directory under the project root that holds the daily log files. Production
/// serves out of `projects/designs`, whose `/projects/` is gitignored, so the
/// logs never reach a commit.
const logs_subdir = "logs";

/// Paths whose successful, fast requests are noise: the browser's 2 s version
/// poll and the static asset fetches behind it. They are logged only when they
/// are slow enough to be interesting (`noisy_floor_ms`).
const noisy_prefixes = [_][]const u8{ "/api/version/", "/assets/", "/static/" };

/// How slow a `noisy_prefixes` request has to be before it earns a line.
const noisy_floor_ms: f64 = 100;

/// Only `/api/*` responses carry the server-time header the client reads back.
const api_prefix = "/api/";

/// Response header carrying whole-handler milliseconds, so a client-side
/// `save.end` can separate server work from network + parse.
const server_ms_header = "X-Netlisp-Server-Ms";

/// Largest `POST /api/client-log/:name` body accepted; a bigger one is 413.
const max_client_log_bytes: usize = 256 * 1024;

/// Most events one client-log post may carry; more is a 400.
const max_events: usize = 200;

/// Field names the server owns on a client line. An event that spells one of
/// them is ignored for that key rather than emitting it twice — a duplicate
/// JSON key is last-wins in every parser, so a client could otherwise
/// overwrite the design name its own line is filed under.
const reserved_keys = [_][]const u8{ "ts", "build", "src", "evt", "design", "page_build", "t_client", "t" };

const err_no_body = "no body";
const err_bad_json = "malformed client-log JSON";
const err_no_events = "no events array";
const err_too_many = "too many events";
const err_too_large = "client-log body too large";

/// Which side of the wire produced a line.
pub const Source = enum { server, client };

/// A scalar a log line may carry beside the four common fields. Nested values
/// are deliberately absent: a log line is a flat record, and the one nested
/// object that exists (`stages`) is built by this module, not by a caller.
pub const Value = union(enum) {
    text: []const u8,
    int: i64,
    /// A wall-clock duration in milliseconds, printed to 0.1 ms so two runs of
    /// one request diff as measurements rather than as float noise.
    duration_ms: f64,
    /// A number a client reported, printed at full precision.
    number: f64,
    flag: bool,
};

/// One `"key":<scalar>` pair on a log line.
pub const Field = struct {
    key: []const u8,
    value: Value,
};

/// One named phase of an instrumented handler.
pub const Stage = struct {
    name: []const u8 = "",
    ms: f64 = 0,
};

/// The per-server appender. Held on `ServerState` rather than at module scope
/// so two servers in one process stay independent, and so the OFF state is the
/// default rather than something a test has to remember to arrange.
pub const Store = struct {
    /// Project directory whose `logs/` subdirectory receives the file. Null
    /// (the default) disables logging entirely.
    project_dir: ?[]const u8 = null,
    /// Serializes the stat+write pair across httpz worker threads.
    mutex: infra_fs.Mutex = .{},

    /// Whether this store writes anything at all.
    pub fn enabled(self: *const Store) bool {
        return self.project_dir != null;
    }
};

// ── Time ───────────────────────────────────────────────────────────────

/// A broken-down UTC instant — enough for both the `ts` field and the file
/// name, computed once per line so the two can never name different days.
const Utc = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    milli: u16,
};

/// Break the current wall-clock instant into UTC parts.
fn utcNow() Utc {
    return utcFromMillis(@intCast(@divFloor(clock.nanoTimestamp(), clock.ns_per_ms)));
}

/// Break a Unix epoch millisecond count into UTC parts. Pre-epoch input is
/// clamped rather than refused: a machine with a broken clock should still get
/// a parseable line.
fn utcFromMillis(unix_ms: i64) Utc {
    const total = @max(unix_ms, 0);
    const secs = @divFloor(total, std.time.ms_per_s);
    const es = clock.epoch.EpochSeconds{ .secs = @intCast(secs) };
    const day = es.getDaySeconds();
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return .{
        .year = yd.year,
        .month = @backingInt(md.month),
        .day = md.day_index + 1,
        .hour = day.getHoursIntoDay(),
        .minute = day.getMinutesIntoHour(),
        .second = day.getSecondsIntoMinute(),
        .milli = @intCast(total - secs * std.time.ms_per_s),
    };
}

/// Milliseconds elapsed since a `clock.monotonicNanos` reading.
fn elapsedMs(started_ns: i128) f64 {
    const delta: f64 = @floatFromInt(clock.monotonicNanos() - started_ns);
    return delta / @as(f64, @floatFromInt(clock.ns_per_ms));
}

// ── Line composition ───────────────────────────────────────────────────

/// Write the `ts` value: ISO-8601 UTC with milliseconds, no quotes.
fn writeTs(w: *std.Io.Writer, at: Utc) std.Io.Writer.Error!void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        at.year, at.month, at.day, at.hour, at.minute, at.second, at.milli,
    });
}

fn writeValue(w: *std.Io.Writer, v: Value) json_writer.WriteError!void {
    switch (v) {
        .text => |s| try json_writer.writeString(w, s),
        .int => |i| try w.print("{d}", .{i}),
        .duration_ms => |ms| try w.print("{d:.1}", .{ms}),
        .number => |n| try w.print("{d}", .{n}),
        .flag => |b| try w.writeAll(if (b) "true" else "false"),
    }
}

/// Compose one whole line, newline included: the four common fields, then
/// `fields` in order, then the nested `stages` object when there is one.
fn writeLine(
    w: *std.Io.Writer,
    at: Utc,
    source: Source,
    evt: []const u8,
    fields: []const Field,
    stages: []const Stage,
) json_writer.WriteError!void {
    try w.writeAll("{\"ts\":\"");
    try writeTs(w, at);
    try w.writeAll("\",\"build\":");
    try json_writer.writeString(w, build_id.current());
    try w.writeAll(",\"src\":\"");
    try w.writeAll(@tagName(source));
    try w.writeAll("\",\"evt\":");
    try json_writer.writeString(w, evt);
    for (fields) |f| {
        try w.writeByte(',');
        try json_writer.writeString(w, f.key);
        try w.writeByte(':');
        try writeValue(w, f.value);
    }
    if (stages.len > 0) {
        try w.writeAll(",\"stages\":{");
        for (stages, 0..) |s, i| {
            if (i > 0) try w.writeByte(',');
            try json_writer.writeString(w, s.name);
            try w.print(":{d:.1}", .{s.ms});
        }
        try w.writeByte('}');
    }
    try w.writeAll("}\n");
}

// ── The append itself ──────────────────────────────────────────────────

/// The one spelling of a log file's name, so the writer and every reader that
/// goes looking for it can never disagree about which file a line landed in.
fn logPath(alloc: std.mem.Allocator, project_dir: []const u8, at: Utc) ?[]u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/interactions-{d:0>4}-{d:0>2}-{d:0>2}.jsonl", .{
        project_dir, logs_subdir, at.year, at.month, at.day,
    }) catch null;
}

/// The log file for `store` at `at_ms` (null = now), allocated on `alloc`.
/// Null when logging is off or the path cannot be built — the same "then
/// nothing happens" answer every failure here gives.
pub fn currentPath(store: *const Store, alloc: std.mem.Allocator, at_ms: ?i64) ?[]u8 {
    const dir = store.project_dir orelse return null;
    return logPath(alloc, dir, if (at_ms) |ms| utcFromMillis(ms) else utcNow());
}

/// Open today's file for appending, creating the `logs/` directory only when
/// its absence is what stopped us. Null on any failure.
fn openLog(alloc: std.mem.Allocator, project_dir: []const u8, path: []const u8) ?infra_fs.File {
    if (infra_fs.cwd().createFile(path, .{ .truncate = false })) |file| return file else |_| {}
    const dir = std.fmt.allocPrint(alloc, "{s}/{s}", .{ project_dir, logs_subdir }) catch return null;
    infra_fs.cwd().makePath(dir) catch return null;
    return infra_fs.cwd().createFile(path, .{ .truncate = false }) catch null;
}

/// Append one composed line. Returns whether the bytes reached the file; only
/// the client-log endpoint's `n` reads that, and nothing anywhere retries.
fn append(store: *Store, alloc: std.mem.Allocator, at: Utc, line: []const u8) bool {
    const project_dir = store.project_dir orelse return false;
    const path = logPath(alloc, project_dir, at) orelse return false;
    store.mutex.lock();
    defer store.mutex.unlock();
    const file = openLog(alloc, project_dir, path) orelse return false;
    defer file.close();
    const stat = file.stat() catch return false;
    file.writeAllAt(line, stat.size) catch return false;
    return true;
}

fn emitLine(
    store: *Store,
    alloc: std.mem.Allocator,
    source: Source,
    evt: []const u8,
    fields: []const Field,
    stages: []const Stage,
) bool {
    if (!store.enabled()) return false;
    const at = utcNow();
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    writeLine(&aw.writer, at, source, evt, fields, stages) catch return false;
    return append(store, alloc, at, aw.written());
}

/// Append one flat line. Returns whether it was written.
pub fn emit(
    store: *Store,
    alloc: std.mem.Allocator,
    source: Source,
    evt: []const u8,
    fields: []const Field,
) bool {
    return emitLine(store, alloc, source, evt, fields, &.{});
}

// ── Stage timing ───────────────────────────────────────────────────────

/// The phase timer an instrumented handler carries down its own call chain.
///
/// It is a plain value, not a heap object, because the point is that adding
/// timing to a handler costs one local and one `lap` per phase — instrumenting
/// a request must never be a thing that itself has to be torn down.
pub const StageTimer = struct {
    /// Phases one handler may name. Both instrumented handlers use six; the
    /// cap only bounds the struct, and laps past it are dropped rather than
    /// growing the line.
    pub const max_stages: usize = 12;

    started_ns: i128 = 0,
    marked_ns: i128 = 0,
    recorded: [max_stages]Stage = @splat(.{}),
    count: usize = 0,

    /// Begin timing. The first `lap` closes the phase that starts here.
    pub fn start() StageTimer {
        const now = clock.monotonicNanos();
        return .{ .started_ns = now, .marked_ns = now };
    }

    /// Close the phase ending at this call and file it under `name`.
    pub fn lap(self: *StageTimer, name: []const u8) void {
        const now = clock.monotonicNanos();
        const ms: f64 = @as(f64, @floatFromInt(now - self.marked_ns)) /
            @as(f64, @floatFromInt(clock.ns_per_ms));
        self.marked_ns = now;
        if (self.count >= max_stages) return;
        self.recorded[self.count] = .{ .name = name, .ms = ms };
        self.count += 1;
    }

    /// Every named phase, in the order they were closed.
    pub fn stages(self: *const StageTimer) []const Stage {
        return self.recorded[0..self.count];
    }

    /// Wall time since `start` — read at emit time, so it also covers whatever
    /// happened after the last `lap`.
    pub fn totalMs(self: *const StageTimer) f64 {
        return elapsedMs(self.started_ns);
    }
};

/// Emit the `evt:"stages"` line one instrumented handler reports its phases
/// on. `path` is the request path; `design` the `:name` it acted on.
pub fn emitStages(
    store: *Store,
    alloc: std.mem.Allocator,
    path: []const u8,
    design: []const u8,
    timer: *const StageTimer,
) void {
    if (!store.enabled()) return;
    const fields = [_]Field{
        .{ .key = "path", .value = .{ .text = path } },
        .{ .key = "design", .value = .{ .text = design } },
        .{ .key = "ms_total", .value = .{ .duration_ms = timer.totalMs() } },
    };
    _ = emitLine(store, alloc, .server, "stages", &fields, timer.stages());
}

// ── The dispatch seam ──────────────────────────────────────────────────

/// The response body httpz will actually serialize — the writer buffer when a
/// handler used `res.json`, else `res.body`. Mirrors `serve.maybeCompress`'s
/// own pick, so `bytes_out` is what goes on the wire.
fn responseLen(res: *httpz.Response) usize {
    if (res.buffer.writer.end > 0) return res.buffer.writer.buffered().len;
    return res.body.len;
}

fn methodName(req: *httpz.Request) []const u8 {
    if (req.method == .OTHER) return req.method_string;
    return @tagName(req.method);
}

/// Whether a fast, successful request on this path is poll/static noise.
fn noisy(path: []const u8) bool {
    for (noisy_prefixes) |prefix| {
        if (std.mem.startsWith(u8, path, prefix)) return true;
    }
    return false;
}

/// Emit the dispatch seam's `evt:"req"` line. `started_ns` is a
/// `clock.monotonicNanos` reading taken before auth ran, so `ms` is the whole
/// cost of answering — middleware, handler and compression included.
pub fn emitRequest(
    store: *Store,
    alloc: std.mem.Allocator,
    req: *httpz.Request,
    res: *httpz.Response,
    started_ns: i128,
) void {
    if (!store.enabled()) return;
    const ms = elapsedMs(started_ns);
    const path = req.url.path;
    if (ms < noisy_floor_ms and noisy(path)) return;
    const body_len: i64 = if (req.body()) |b| @intCast(b.len) else 0;
    const fields = [_]Field{
        .{ .key = "method", .value = .{ .text = methodName(req) } },
        .{ .key = "path", .value = .{ .text = path } },
        .{ .key = "status", .value = .{ .int = res.status } },
        .{ .key = "ms", .value = .{ .duration_ms = ms } },
        .{ .key = "bytes_in", .value = .{ .int = body_len } },
        .{ .key = "bytes_out", .value = .{ .int = @intCast(responseLen(res)) } },
    };
    _ = emit(store, alloc, .server, "req", &fields);
}

/// Stamp `X-Netlisp-Server-Ms` on an `/api/*` response so the browser can
/// subtract server work from its own `fetch` timing. Silent no-op once the
/// response has been written or streamed — httpz asserts on a late header.
pub fn stampServerMs(req: *httpz.Request, res: *httpz.Response, started_ns: i128) void {
    if (res.written or res.chunked) return;
    if (!std.mem.startsWith(u8, req.url.path, api_prefix)) return;
    const text = std.fmt.allocPrint(res.arena, "{d:.1}", .{elapsedMs(started_ns)}) catch return;
    res.header(server_ms_header, text);
}

/// Emit the one-per-process `evt:"server.start"` line.
pub fn emitServerStart(store: *Store, alloc: std.mem.Allocator, port: u16) void {
    const project_dir = store.project_dir orelse return;
    const fields = [_]Field{
        .{ .key = "port", .value = .{ .int = port } },
        .{ .key = "project_dir", .value = .{ .text = project_dir } },
    };
    _ = emit(store, alloc, .server, "server.start", &fields);
}

// ── POST /api/client-log/:name ─────────────────────────────────────────

fn fail(res: *httpz.Response, status: u16, msg: []const u8) void {
    res.status = status;
    res.body = msg;
}

/// One JSON value as a log scalar, or null for anything nested (object,
/// array, null) — the client may send whatever it likes and only flat facts
/// are kept.
fn scalarOf(v: std.json.Value) ?Value {
    return switch (v) {
        .string => |s| .{ .text = s },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .number = f },
        .bool => |b| .{ .flag = b },
        else => null,
    };
}

fn isReserved(key: []const u8) bool {
    for (reserved_keys) |reserved| {
        if (std.mem.eql(u8, reserved, key)) return true;
    }
    return false;
}

/// Turn one posted event object into a `src:"client"` line. Returns whether a
/// line was written; a malformed entry is skipped, never fatal to the batch.
fn appendClientEvent(
    store: *Store,
    alloc: std.mem.Allocator,
    design: []const u8,
    page_build: []const u8,
    ev: std.json.Value,
) std.mem.Allocator.Error!bool {
    if (ev != .object) return false;
    const evt = ev.object.get("evt") orelse return false;
    if (evt != .string) return false;
    var fields: std.ArrayList(Field) = .empty;
    try fields.append(alloc, .{ .key = "design", .value = .{ .text = design } });
    try fields.append(alloc, .{ .key = "page_build", .value = .{ .text = page_build } });
    if (ev.object.get("t")) |t| {
        if (scalarOf(t)) |v| try fields.append(alloc, .{ .key = "t_client", .value = v });
    }
    var it = ev.object.iterator();
    while (it.next()) |entry| {
        if (isReserved(entry.key_ptr.*)) continue;
        const v = scalarOf(entry.value_ptr.*) orelse continue;
        try fields.append(alloc, .{ .key = entry.key_ptr.*, .value = v });
    }
    return emit(store, alloc, .client, evt.string, fields.items);
}

/// The `page_build` a batch declares, or `"unknown"` — the client sends the
/// build id the PAGE was rendered at, which is the whole point of the field:
/// a page held open across a deploy reports events under the code that drew
/// it, not the code that received them.
fn pageBuild(root: std.json.Value) []const u8 {
    const v = root.object.get("page_build") orelse return "unknown";
    if (v != .string or v.string.len == 0) return "unknown";
    return v.string;
}

/// `POST /api/client-log/:name` — ingest a batch of browser events into the
/// same interaction log the server writes its own lines to, so one file
/// answers "what did the user do, and what did it cost".
///
/// Body: `{"page_build":"<9hex|unknown>","events":[{"t":…,"evt":"…", …}, …]}`.
/// Caps: 256 KiB body (413), 200 events (400), non-JSON (400). Answers
/// `{"ok":true,"n":<lines written>}`.
pub fn clientLogApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) std.mem.Allocator.Error!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse return fail(res, 400, err_no_body);
    if (body.len > max_client_log_bytes) return fail(res, 413, err_too_large);
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch
        return fail(res, 400, err_bad_json);
    if (root != .object) return fail(res, 400, err_bad_json);
    const events = root.object.get("events") orelse return fail(res, 400, err_no_events);
    if (events != .array) return fail(res, 400, err_no_events);
    if (events.array.items.len > max_events) return fail(res, 400, err_too_many);
    const build = pageBuild(root);
    var n: usize = 0;
    for (events.array.items) |ev| {
        if (try appendClientEvent(&ctx.state.request_log, req.arena, name, build, ev)) n += 1;
    }
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"n\":{d}}}", .{n});
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A store rooted at a temp directory, plus the directory itself.
fn tmpStore(dir: *std.testing.TmpDir, alloc: std.mem.Allocator) !Store {
    return .{ .project_dir = try dir.dir.realPathFileAlloc(testing.io, ".", alloc) };
}

/// Today's log file contents, or "" when nothing was written.
fn logBody(store: *const Store, alloc: std.mem.Allocator) []const u8 {
    const path = currentPath(store, alloc, null) orelse return "";
    return infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch "";
}

// spec: Web Server - Every interaction-log line carries an ISO-8601 timestamp, the build id, its source and its event name, with JSON-escaped values
test "an interaction-log line carries the common fields and escapes its values" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const at = utcFromMillis(1_787_936_645_123);
    const fields = [_]Field{
        .{ .key = "path", .value = .{ .text = "/api/pcb-layouts/a\"b\nc" } },
        .{ .key = "status", .value = .{ .int = 200 } },
        .{ .key = "ms", .value = .{ .duration_ms = 8123.37 } },
        .{ .key = "automatic", .value = .{ .flag = true } },
    };
    try writeLine(&aw.writer, at, .server, "req", &fields, &.{});
    try testing.expectEqualStrings(
        "{\"ts\":\"2026-08-28T17:04:05.123Z\",\"build\":\"test\",\"src\":\"server\",\"evt\":\"req\"," ++
            "\"path\":\"/api/pcb-layouts/a\\\"b\\nc\",\"status\":200,\"ms\":8123.4,\"automatic\":true}\n",
        aw.written(),
    );

    // The nested stages object is the one structure a line may carry, and it
    // only appears when a handler named a phase.
    var sw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer sw.deinit();
    const stages = [_]Stage{ .{ .name = "score_resolve", .ms = 3512.04 }, .{ .name = "write", .ms = 9 } };
    try writeLine(&sw.writer, at, .client, "stages", &.{}, &stages);
    try testing.expectEqualStrings(
        "{\"ts\":\"2026-08-28T17:04:05.123Z\",\"build\":\"test\",\"src\":\"client\",\"evt\":\"stages\"," ++
            "\"stages\":{\"score_resolve\":3512.0,\"write\":9.0}}\n",
        sw.written(),
    );
}

// spec: Web Server - The interaction log appends one line per event to a dated file under the project's logs directory, creating it on demand, and writes nothing at all when no project directory is set
test "the interaction log appends to a dated file and stays silent when disabled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try tmpStore(&tmp, alloc);

    // The `logs/` directory does not exist yet: the first line creates it.
    try testing.expect(emit(&store, alloc, .server, "server.start", &.{
        .{ .key = "port", .value = .{ .int = 7050 } },
    }));
    try testing.expect(emit(&store, alloc, .server, "req", &.{
        .{ .key = "path", .value = .{ .text = "/api/pcb-drc/barracuda" } },
    }));
    const body = logBody(&store, alloc);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "\n"));
    try testing.expect(std.mem.indexOf(u8, body, "\"evt\":\"server.start\",\"port\":7050") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"evt\":\"req\"") != null);
    // The name is the UTC day, and `currentPath` is how anything finds it.
    const path = currentPath(&store, alloc, 1_787_936_645_123).?;
    try testing.expect(std.mem.endsWith(u8, path, "/logs/interactions-2026-08-28.jsonl"));

    // A default store is OFF: nothing is written and nothing is created.
    var off = Store{};
    try testing.expect(!off.enabled());
    try testing.expect(!emit(&off, alloc, .server, "req", &.{}));
    try testing.expect(currentPath(&off, alloc, null) == null);
}

/// The named phases' total — the floor a timer's own `totalMs` must clear,
/// since the total also covers whatever ran after the last `lap`.
fn stageSum(timer: *const StageTimer) f64 {
    var sum: f64 = 0;
    for (timer.stages()) |s| sum += s.ms;
    return sum;
}

/// The shortest phase on a timer. The clock is monotonic, so this can never be
/// negative — a negative would mean a duration was subtracted from wall time.
fn shortestStage(timer: *const StageTimer) f64 {
    var least: f64 = std.math.floatMax(f64);
    for (timer.stages()) |s| least = @min(least, s.ms);
    return least;
}

fn lapRepeatedly(timer: *StageTimer, times: usize, name: []const u8) void {
    for (0..times) |_| timer.lap(name);
}

// spec: Web Server - A handler's stage timer reports every phase it names and a total that covers the work after the last one
test "a stage timer names each phase and totals the whole handler" {
    var timer = StageTimer.start();
    try testing.expectEqual(@as(usize, 0), timer.stages().len);
    timer.lap("parse");
    timer.lap("score_resolve");
    try testing.expectEqual(@as(usize, 2), timer.stages().len);
    try testing.expectEqualStrings("parse", timer.stages()[0].name);
    try testing.expectEqualStrings("score_resolve", timer.stages()[1].name);
    // Monotonic, so no phase and no total can come out negative…
    try testing.expect(shortestStage(&timer) >= 0);
    try testing.expect(timer.totalMs() >= 0);
    // …and the total covers at least the phases named so far.
    try testing.expect(timer.totalMs() >= stageSum(&timer));

    // Past the cap a lap is dropped rather than growing the line.
    lapRepeatedly(&timer, StageTimer.max_stages + 4, "extra");
    try testing.expectEqual(StageTimer.max_stages, timer.stages().len);
}

/// Post one body to `clientLogApi` against a store rooted at `project`.
fn postClientLog(
    alloc: std.mem.Allocator,
    state: *serve_root.ServerState,
    project: []const u8,
    body: []const u8,
) !struct { status: u16, body: []const u8 } {
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", "barracuda");
    ht.body(body);
    try clientLogApi(&srv, ht.req, ht.res);
    return .{ .status = ht.res.status, .body = try alloc.dupe(u8, ht.res.body) };
}

// spec: Web Server - The client-log endpoint appends one line per posted browser event, passing its scalar fields through, and refuses an oversized body or event burst without writing anything
test "the client-log endpoint stores each event and refuses oversized batches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    var state = serve_root.ServerState{ .request_log = .{ .project_dir = project } };

    const happy = try postClientLog(alloc, &state, project,
        \\{"page_build":"834d4421a","events":[
        \\ {"t":1756400645123,"evt":"save.start","verb":"autosave","automatic":true,"bytes":184213},
        \\ {"t":1756400653246,"evt":"save.end","result":"saved","server_ms":8123.4},
        \\ {"evt":"log.drop","n":7,"nested":{"ignored":1},"src":"spoofed"}]}
    );
    try testing.expectEqual(@as(u16, 200), happy.status);
    try testing.expectEqualStrings("{\"ok\":true,\"n\":3}", happy.body);

    const body = logBody(&state.request_log, alloc);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, body, "\n"));
    try testing.expect(std.mem.indexOf(u8, body, "\"src\":\"client\",\"evt\":\"save.start\"," ++
        "\"design\":\"barracuda\",\"page_build\":\"834d4421a\",\"t_client\":1756400645123," ++
        "\"verb\":\"autosave\",\"automatic\":true,\"bytes\":184213}") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"result\":\"saved\",\"server_ms\":8123.4") != null);
    // A nested field is dropped, and a client may not overwrite a server field.
    try testing.expect(std.mem.indexOf(u8, body, "\"nested\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"spoofed\"") == null);
    try testing.expect(std.mem.indexOf(u8, body, "\"evt\":\"log.drop\",\"design\":\"barracuda\"," ++
        "\"page_build\":\"834d4421a\",\"n\":7}") != null);

    // Refusals write nothing more: the file still holds exactly three lines.
    const big = try alloc.alloc(u8, max_client_log_bytes + 1);
    @memset(big, 'x');
    try testing.expectEqual(@as(u16, 413), (try postClientLog(alloc, &state, project, big)).status);
    try testing.expectEqual(@as(u16, 400), (try postClientLog(alloc, &state, project, "not json")).status);
    try testing.expectEqual(@as(u16, 400), (try postClientLog(alloc, &state, project, "{}")).status);
    try testing.expectEqual(@as(u16, 400), (try postClientLog(alloc, &state, project, "[1,2]")).status);

    var burst: std.Io.Writer.Allocating = .init(alloc);
    try burst.writer.writeAll("{\"events\":[");
    for (0..max_events + 1) |i| {
        if (i > 0) try burst.writer.writeByte(',');
        try burst.writer.writeAll("{\"evt\":\"dirty\"}");
    }
    try burst.writer.writeAll("]}");
    try testing.expectEqual(@as(u16, 400), (try postClientLog(alloc, &state, project, burst.written())).status);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, logBody(&state.request_log, alloc), "\n"));
}
