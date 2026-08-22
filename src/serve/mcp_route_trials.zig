//! Per-design routing trial-memory sidecar (`<design>.trials.json`) + its CLI
//! tool handlers — the loop-hygiene half of the constraint-DSL routing loop.
//!
//! The loop is: an agent calls the read-only `route_experiment` tool with a
//! `(pcb-plan …)` override, reads back {score, routed, stuck[]…}, then edits the
//! DSL and tries again. Without a durable record of (plan tried → score),
//! agents re-propose reverted edits and oscillate (A→B→A). On a saturated board
//! ordering experiments trade failures 1:1, so knowing what was already tried is
//! as valuable as the next idea. These tools supply that memory:
//!
//!     experiment  → `route_experiment` (elsewhere; routes, scores, never writes)
//!     record      → `record_route_trial` (append the numbers you got + a note)
//!     list-before-next-edit → `list_route_trials` (what did I already try?)
//!
//! `route_order_search` writes its OWN rows here through `recordSearchTrials`
//! (tagged `source:"order_search"`): it runs up to 48 whole-board routes per
//! call, and leaving the most expensive search in the system unrecorded meant a
//! later call could not tell it had already measured an ordering.
//!
//! The server only REMEMBERS — it does not re-route and does not judge. Spotting
//! an A→B→A oscillation in the recorded history is the AGENT's job.
//!
//! Storage mirrors the notes sidecar (`notes.zig`): a JSON file beside the
//! design source, monotonic integer ids (`max+1`, never reused), capped at
//! `max_trials` entries — recording past the cap drops the OLDEST entry so the
//! newest 100 always survive. No timestamps: Guardian bans wall-clock reads, and
//! every CLI mutation is git-autocommitted with author attribution by the
//! existing seam, so ordering + history come from git for free.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const mcp_tools = @import("mcp_tools.zig");

const requireString = mcp_tools.requireString;
const optionalString = mcp_tools.optionalString;
const optionalU64 = mcp_tools.optionalU64;
const missingArg = mcp_tools.missingArg;
const AllocatingWriter = @import("../allocating_writer.zig").AllocatingWriter;

/// Retention cap. Recording the (cap+1)th trial evicts the oldest so the newest
/// `max_trials` always survive; monotonic ids are never reused after eviction.
const max_trials: usize = 100;
/// Upper bound on the sidecar file read — a wide margin over `max_trials`
/// entries even with large `(pcb-plan …)` bodies.
const max_trials_bytes: usize = 1 * 1024 * 1024;
const trials_ext = ".trials.json";

/// One recorded routing experiment. The agent supplies every numeric field from
/// the `route_experiment` result it is memorializing (the server records; it
/// does not re-route to verify). `id` is assigned by `recordTrialCore`.
const Trial = struct {
    id: u64 = 0,
    /// The `(pcb-plan …)` override text that was tried, or a short human label.
    plan: []const u8 = "",
    score: f64 = 0,
    routed: u64 = 0,
    total: u64 = 0,
    vias: u64 = 0,
    trace_mm: f64 = 0,
    drc_errors: u64 = 0,
    /// The agent's free-form observation about this trial.
    note: []const u8 = "",
    /// WHO recorded this row: `"agent"` for a hand `record_route_trial` call,
    /// `"order_search"` for a trial `route_order_search` ran itself. Defaulted
    /// (and read with `ignore_unknown_fields`), so every sidecar written before
    /// the field existed still parses — those rows read as `"agent"`, which is
    /// what they were.
    source: []const u8 = source_agent,
};

/// `Trial.source` for a row a caller recorded by hand through the CLI tool.
const source_agent = "agent";
/// `Trial.source` for a row `route_order_search` recorded from its own run.
const source_order_search = "order_search";

/// What one trial measured — the numbers a reader compares rows by. Grouped so
/// a caller passes a board's result as one value rather than six loose args.
pub const TrialOutcome = struct {
    /// The deterministic `route_score` of this board (higher is better).
    score: f64 = 0,
    routed: u64 = 0,
    total: u64 = 0,
    vias: u64 = 0,
    trace_mm: f64 = 0,
    drc_errors: u64 = 0,
};

/// One row a routing SEARCH asks to have recorded (`recordSearchTrials`). The
/// id and the `source` tag are the sidecar's to assign, so a search supplies
/// only what it measured.
pub const SearchTrial = struct {
    /// What was tried — for an ordering search, the routing order itself.
    plan: []const u8,
    /// Which trial of which run this was, and under what scope/layout.
    note: []const u8 = "",
    outcome: TrialOutcome = .{},
};

/// Failures `recordSearchTrials` reports. Everything the sidecar path can throw
/// (path building, the file read/write, a malformed existing file) collapses
/// into `RecordFailed`: the caller is a best-effort recorder that logs and moves
/// on, and a public error set naming every `std.fs` error would be a wide,
/// churn-prone surface for no reader.
pub const RecordError = error{ OutOfMemory, DesignNotFound, RecordFailed };

/// The sidecar's on-disk shape. `ignore_unknown_fields` + per-field defaults on
/// `Trial` keep a partially-hand-edited or forward-versioned file loadable.
const Sidecar = struct { trials: []Trial = &.{} };

/// `{id, count}` after a successful record — the new entry's monotonic id (the
/// LAST one, for a batch) and the post-eviction total.
pub const RecordResult = struct { id: u64, count: usize };

// ── Sidecar path + load/store ─────────────────────────────────────────

/// Path to `<design>.trials.json` beside the design source. Resolves the source
/// `.sexp` first (so grouped `src/<group>/<name>.sexp` and `lib/modules/<name>`
/// both land the sidecar next to their source, not in a flat fallback dir) —
/// identical placement to `notes.zig`'s `notesPath`.
fn trialsPath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) paths.PathError![]u8 {
    const src = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(src);
    const dir = std.fs.path.dirname(src) orelse "";
    if (dir.len == 0) return std.fmt.allocPrint(allocator, "{s}{s}", .{ name, trials_ext });
    return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ dir, name, trials_ext });
}

/// True when a design (or module) of this name has a source file. `name` is
/// validated traversal-safe by `designSourcePath`; a rejected or absent name
/// reads as "does not exist" so the tools error rather than touch a stray path.
fn designExists(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) bool {
    const src = paths.designSourcePath(allocator, project_dir, name) catch return false;
    defer allocator.free(src);
    infra_fs.cwd().access(src, .{}) catch return false;
    return true;
}

/// Load + parse the sidecar. A missing file is an empty log (not an error). All
/// strings are copied into the parse arena (`alloc_always`) so the caller may
/// free the file bytes immediately; the caller owns the returned `Parsed` and
/// must `deinit()` it.
fn loadTrials(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) !std.json.Parsed(Sidecar) {
    const path = try trialsPath(allocator, project_dir, name);
    defer allocator.free(path);
    const data = infra_fs.cwd().readFileAlloc(allocator, path, max_trials_bytes) catch |e| switch (e) {
        error.FileNotFound => return std.json.parseFromSlice(Sidecar, allocator, "{\"trials\":[]}", .{}),
        else => return e,
    };
    defer allocator.free(data);
    return std.json.parseFromSlice(Sidecar, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.MalformedSidecar;
}

/// Serialize `trials` and overwrite the sidecar. Renders into an in-memory
/// buffer first (like `notes.zig`), so the JSON writer only ever sees an
/// allocator-backed writer.
fn writeTrials(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    trials: []const Trial,
) !void {
    const path = try trialsPath(allocator, project_dir, name);
    defer allocator.free(path);
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeAll("{\"trials\":[");
    for (trials, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        try writeTrialJson(w, t);
    }
    try w.writeAll("]}");
    const file = try infra_fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.written());
}

/// Write one `Trial` as a JSON object. `score`/`trace_mm` use the same 2/3
/// decimal precision `route_experiment` emits them at, so a recorded value
/// round-trips exactly what the agent read.
fn writeTrialJson(w: anytype, t: Trial) json_writer.WriteError!void {
    try w.print("{{\"id\":{d},\"plan\":", .{t.id});
    try json_writer.writeString(w, t.plan);
    try w.print(",\"score\":{d:.2},\"routed\":{d},\"total\":{d},\"vias\":{d},\"trace_mm\":{d:.3},\"drc_errors\":{d}", .{
        t.score, t.routed, t.total, t.vias, t.trace_mm, t.drc_errors,
    });
    try w.writeAll(",\"note\":");
    try json_writer.writeString(w, t.note);
    try w.writeAll(",\"source\":");
    try json_writer.writeString(w, if (t.source.len == 0) source_agent else t.source);
    try w.writeByte('}');
}

// ── Core mutations (shared with tests) ────────────────────────────────

/// Append `trial` (its `id` is assigned here as `max existing id + 1`) and
/// persist. Enforces the retention cap by dropping oldest-first. Returns the new
/// id + post-eviction count. `error.DesignNotFound` when the design is unknown.
fn recordTrialCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    trial: Trial,
) !RecordResult {
    if (!designExists(allocator, project_dir, name)) return error.DesignNotFound;

    const parsed = try loadTrials(allocator, project_dir, name);
    defer parsed.deinit();
    const existing = parsed.value.trials;

    var max_id: u64 = 0;
    for (existing) |t| {
        if (t.id > max_id) max_id = t.id;
    }
    const new_id = max_id + 1;

    var list: std.ArrayList(Trial) = .empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, existing);
    var stamped = trial;
    stamped.id = new_id;
    try list.append(allocator, stamped);

    // Retention cap: keep the newest `max_trials`, dropping oldest-first.
    var kept: []const Trial = list.items;
    if (kept.len > max_trials) kept = kept[kept.len - max_trials ..];

    try writeTrials(allocator, project_dir, name, kept);
    return .{ .id = new_id, .count = kept.len };
}

/// Append every row in `batch` in ONE load-write cycle, continuing the same
/// monotonic id sequence and honouring the same retention cap a single
/// `recordTrialCore` does, each row tagged `source:"order_search"`. Returns the
/// id of the LAST appended row plus the post-eviction count; an empty batch
/// writes nothing at all.
///
/// This exists for `route_order_search`, which runs up to 48 whole-board routes
/// per call and used to persist none of them: the most expensive search in the
/// system left no trace, while every hand experiment did. One write for the
/// whole run rather than one per trial, because the file is rewritten wholesale
/// and each write is separately git-autocommitted.
pub fn recordSearchTrials(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    batch: []const SearchTrial,
) RecordError!RecordResult {
    if (!designExists(allocator, project_dir, name)) return error.DesignNotFound;
    if (batch.len == 0) return .{ .id = 0, .count = 0 };
    return appendSearchTrials(allocator, project_dir, name, batch) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.RecordFailed,
    };
}

/// `recordSearchTrials`' load-append-write body, with the sidecar path's own
/// wide error set (which the caller collapses).
fn appendSearchTrials(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    batch: []const SearchTrial,
) !RecordResult {
    const parsed = try loadTrials(allocator, project_dir, name);
    defer parsed.deinit();

    var next_id: u64 = 0;
    for (parsed.value.trials) |t| {
        if (t.id > next_id) next_id = t.id;
    }

    var list: std.ArrayList(Trial) = .empty;
    defer list.deinit(allocator);
    try list.appendSlice(allocator, parsed.value.trials);
    for (batch) |t| {
        next_id += 1;
        try list.append(allocator, .{
            .id = next_id,
            .plan = t.plan,
            .score = t.outcome.score,
            .routed = t.outcome.routed,
            .total = t.outcome.total,
            .vias = t.outcome.vias,
            .trace_mm = t.outcome.trace_mm,
            .drc_errors = t.outcome.drc_errors,
            .note = t.note,
            .source = source_order_search,
        });
    }

    var kept: []const Trial = list.items;
    if (kept.len > max_trials) kept = kept[kept.len - max_trials ..];

    try writeTrials(allocator, project_dir, name, kept);
    return .{ .id = next_id, .count = kept.len };
}

/// Remove the trial with the given id. Returns true when one was removed, false
/// when no entry had that id. `error.DesignNotFound` when the design is unknown.
fn removeTrialCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    id: u64,
) !bool {
    if (!designExists(allocator, project_dir, name)) return error.DesignNotFound;

    const parsed = try loadTrials(allocator, project_dir, name);
    defer parsed.deinit();

    var kept: std.ArrayList(Trial) = .empty;
    defer kept.deinit(allocator);
    var found = false;
    for (parsed.value.trials) |t| {
        if (t.id == id) {
            found = true;
            continue;
        }
        try kept.append(allocator, t);
    }
    if (!found) return false;

    try writeTrials(allocator, project_dir, name, kept.items);
    return true;
}

// ── CLI dispatch + handlers ───────────────────────────────────────────

/// Route-trial memory tools (sidecar `<design>.trials.json`): record a routing
/// experiment's result, list what was already tried before the next DSL edit,
/// and prune a junk entry. Returns null when the tool name matches none of
/// these. The oscillation check is the caller's — the server only remembers.
pub fn dispatchRouteTrials(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    tool_name: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!?bool {
    if (std.mem.eql(u8, tool_name, "record_route_trial"))
        return try recordRouteTrial(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "list_route_trials"))
        return try listRouteTrials(allocator, project_dir, args_val, out);
    if (std.mem.eql(u8, tool_name, "remove_route_trial"))
        return try removeRouteTrial(allocator, project_dir, args_val, out);
    return null;
}

/// `record_route_trial` — append one experiment's result to the design's trial
/// log and return `{ok:true, id, count}`. The agent passes the numbers it got
/// back from `route_experiment` (the server records them verbatim; it does NOT
/// re-route). `note` is optional. Ids are monotonic; the log caps at 100 (the
/// oldest is dropped past that). Every write is git-autocommitted for free.
fn recordRouteTrial(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const plan = requireString(args_val, "plan") orelse return missingArg(out, allocator, "plan");
    const score = argF64(args_val, "score") orelse return missingArg(out, allocator, "score");
    const routed = optionalU64(args_val, "routed") orelse return missingArg(out, allocator, "routed");
    const total = optionalU64(args_val, "total") orelse return missingArg(out, allocator, "total");
    const vias = optionalU64(args_val, "vias") orelse return missingArg(out, allocator, "vias");
    const trace_mm = argF64(args_val, "trace_mm") orelse return missingArg(out, allocator, "trace_mm");
    const drc_errors = optionalU64(args_val, "drc_errors") orelse return missingArg(out, allocator, "drc_errors");
    const note = optionalString(args_val, "note") orelse "";

    const trial: Trial = .{
        .plan = plan,
        .score = score,
        .routed = routed,
        .total = total,
        .vias = vias,
        .trace_mm = trace_mm,
        .drc_errors = drc_errors,
        .note = note,
    };
    const result = recordTrialCore(allocator, project_dir, name, trial) catch |e| switch (e) {
        error.DesignNotFound => return notFound(out, allocator, name),
        else => return failWith(out, allocator, "record failed", e),
    };
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    try w.print("{{\"ok\":true,\"id\":{d},\"count\":{d}}}", .{ result.id, result.count });
    return true;
}

/// `list_route_trials` — return the design's recorded trials oldest→newest as
/// `{trials:[…], count}`, so the agent can check "did I already try this?"
/// before proposing the next DSL edit. Read-only.
fn listRouteTrials(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    if (!designExists(allocator, project_dir, name)) return notFound(out, allocator, name);

    const parsed = loadTrials(allocator, project_dir, name) catch |e|
        return failWith(out, allocator, "cannot read trials", e);
    defer parsed.deinit();
    const trials = parsed.value.trials;

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    try w.writeAll("{\"trials\":[");
    for (trials, 0..) |t, i| {
        if (i > 0) try w.writeAll(",");
        writeTrialJson(w, t) catch return error.OutOfMemory;
    }
    try w.print("],\"count\":{d}}}", .{trials.len});
    return true;
}

/// `remove_route_trial` — delete one trial by id (parity with the notes tools;
/// for pruning a junk/superseded entry). Returns `{ok:true}` or an error when no
/// entry has that id.
fn removeRouteTrial(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    const id = optionalU64(args_val, "id") orelse return missingArg(out, allocator, "id");

    const removed = removeTrialCore(allocator, project_dir, name, id) catch |e| switch (e) {
        error.DesignNotFound => return notFound(out, allocator, name),
        else => return failWith(out, allocator, "remove failed", e),
    };
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    if (!removed) {
        try w.print("error: trial id {d} not found", .{id});
        return false;
    }
    try w.writeAll("{\"ok\":true}");
    return true;
}

// ── Small helpers ─────────────────────────────────────────────────────

/// `args.key` as an f64 (accepting an integer JSON literal too — `score` /
/// `trace_mm` may arrive as `42` or `42.5`; `score` may be negative). Null when
/// absent or non-numeric. There is no float twin of `optionalU64` in mcp_tools.
fn argF64(args_val: ?std.json.Value, key: []const u8) ?f64 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    if (v == .float) return v.float;
    if (v == .integer) return @floatFromInt(v.integer);
    return null;
}

/// Plain-text "unknown design" error line (notes-tool error style). Returns
/// false so the CLI layer flags the result `isError`.
fn notFound(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    try w.print("error: design \"{s}\" not found", .{name});
    return false;
}

/// Plain-text error line naming the operation and the underlying error.
fn failWith(out: *std.ArrayList(u8), allocator: std.mem.Allocator, what: []const u8, e: anyerror) std.mem.Allocator.Error!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    try w.print("error: {s}: {s}", .{ what, @errorName(e) });
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

/// Build a tmp project with one real design source so `designExists` passes and
/// the sidecar lands beside it. Caller `defer`s `.cleanup()`.
fn newProject() !testing.TmpDir {
    var tmp = testing.tmpDir(.{});
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/tiny.sexp", .data = "(design-block \"tiny\")\n" });
    return tmp;
}

/// A sample trial with distinctive, exactly-representable float values so a
/// record→load round-trip compares equal.
fn sampleTrial() Trial {
    return .{
        .plan = "(pcb-plan (route (wave \"exp\" (rest))))",
        .score = 42.5,
        .routed = 10,
        .total = 12,
        .vias = 3,
        .trace_mm = 88.125,
        .drc_errors = 1,
        .note = "tighter than baseline",
    };
}

/// Pre-build a sidecar already holding `n` trials (ids 1..n) directly on disk,
/// so the cap test can start from a full log without N record calls in a test
/// body. Loops live here (a helper), never in a test.
fn seedTrials(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8, n: usize) !void {
    var list: std.ArrayList(Trial) = .empty;
    defer list.deinit(allocator);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try list.append(allocator, .{ .id = @intCast(i + 1), .plan = "seed", .note = "seed" });
    }
    try writeTrials(allocator, project_dir, name, list.items);
}

// spec: Web Server - record_route_trial then list_route_trials round-trips a recorded routing trial
test "record then load round-trips a trial" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = try newProject();
    defer tmp.cleanup();
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const rec = try recordTrialCore(arena, proj, "tiny", sampleTrial());
    try testing.expectEqual(@as(u64, 1), rec.id);
    try testing.expectEqual(@as(usize, 1), rec.count);

    const parsed = try loadTrials(arena, proj, "tiny");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.trials.len);
    const t = parsed.value.trials[0];
    try testing.expectEqual(@as(u64, 1), t.id);
    try testing.expectEqualStrings("(pcb-plan (route (wave \"exp\" (rest))))", t.plan);
    try testing.expectEqual(@as(f64, 42.5), t.score);
    try testing.expectEqual(@as(u64, 10), t.routed);
    try testing.expectEqual(@as(u64, 12), t.total);
    try testing.expectEqual(@as(u64, 3), t.vias);
    try testing.expectEqual(@as(f64, 88.125), t.trace_mm);
    try testing.expectEqual(@as(u64, 1), t.drc_errors);
    try testing.expectEqualStrings("tighter than baseline", t.note);
}

// spec: Web Server - route-trial ids stay monotonic and are never reused after a remove
test "ids stay monotonic after a remove" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = try newProject();
    defer tmp.cleanup();
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const r1 = try recordTrialCore(arena, proj, "tiny", sampleTrial());
    const r2 = try recordTrialCore(arena, proj, "tiny", sampleTrial());
    const r3 = try recordTrialCore(arena, proj, "tiny", sampleTrial());
    try testing.expectEqual(@as(u64, 1), r1.id);
    try testing.expectEqual(@as(u64, 2), r2.id);
    try testing.expectEqual(@as(u64, 3), r3.id);

    try testing.expect(try removeTrialCore(arena, proj, "tiny", 2));

    // The next id is max-existing (3) + 1 = 4 — id 2 is never reused.
    const r4 = try recordTrialCore(arena, proj, "tiny", sampleTrial());
    try testing.expectEqual(@as(u64, 4), r4.id);
    try testing.expectEqual(@as(usize, 3), r4.count);
}

// spec: Web Server - recording past the route-trial retention cap drops the oldest trial
test "recording past the cap drops the oldest trial" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = try newProject();
    defer tmp.cleanup();
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    try seedTrials(arena, proj, "tiny", max_trials); // ids 1..100 on disk

    const rec = try recordTrialCore(arena, proj, "tiny", sampleTrial());
    try testing.expectEqual(@as(u64, 101), rec.id); // monotonic: max+1
    try testing.expectEqual(max_trials, rec.count); // capped, not grown

    const parsed = try loadTrials(arena, proj, "tiny");
    defer parsed.deinit();
    try testing.expectEqual(max_trials, parsed.value.trials.len);
    try testing.expectEqual(@as(u64, 2), parsed.value.trials[0].id); // oldest (id 1) evicted
    try testing.expectEqual(@as(u64, 101), parsed.value.trials[max_trials - 1].id); // newest kept
}

// spec: Web Server - recording a route trial on an unknown design is rejected
test "recording on an unknown design errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = try newProject();
    defer tmp.cleanup();
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    try testing.expectError(error.DesignNotFound, recordTrialCore(arena, proj, "ghost", sampleTrial()));
}

// spec: Web Server - a batch of search trials appends in one write, continuing the same id sequence and cap
test "a search batch appends in one write and keeps the id sequence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = try newProject();
    defer tmp.cleanup();
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    // One hand-recorded row first, so the batch has to continue an existing id.
    _ = try recordTrialCore(arena, proj, "tiny", sampleTrial());

    const batch = [_]SearchTrial{
        .{ .plan = "baseline", .outcome = .{ .routed = 70, .total = 90 } },
        .{ .plan = "transpose", .outcome = .{ .routed = 72, .total = 90 } },
    };
    const rec = try recordSearchTrials(arena, proj, "tiny", &batch);
    try testing.expectEqual(@as(u64, 3), rec.id); // the LAST id written
    try testing.expectEqual(@as(usize, 3), rec.count);

    const parsed = try loadTrials(arena, proj, "tiny");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.trials.len);
    // The hand row keeps the default source; the search rows carry their own.
    try testing.expectEqualStrings(source_agent, parsed.value.trials[0].source);
    try testing.expectEqualStrings(source_order_search, parsed.value.trials[1].source);
    try testing.expectEqualStrings("transpose", parsed.value.trials[2].plan);
    try testing.expectEqual(@as(u64, 3), parsed.value.trials[2].id);
}

// spec: Web Server - an empty search batch writes nothing at all
test "an empty batch writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = try newProject();
    defer tmp.cleanup();
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    const rec = try recordSearchTrials(arena, proj, "tiny", &.{});
    try testing.expectEqual(@as(usize, 0), rec.count);
    // No sidecar was created — a no-op run leaves the design exactly as it was.
    const path = try trialsPath(arena, proj, "tiny");
    try testing.expectError(error.FileNotFound, infra_fs.cwd().access(path, .{}));
}

// spec: Web Server - a trial sidecar written before the source field existed still loads, as agent-recorded rows
test "a sidecar without the source field loads as agent-recorded" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = try newProject();
    defer tmp.cleanup();
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    // Exactly the bytes the pre-`source` writer produced.
    const path = try trialsPath(arena, proj, "tiny");
    try infra_fs.cwd().writeFile(.{
        .sub_path = path,
        .data =
        \\{"trials":[{"id":7,"plan":"legacy","score":1.00,"routed":5,"total":6,"vias":0,"trace_mm":0.000,"drc_errors":0,"note":""}]}
        ,
    });

    const parsed = try loadTrials(arena, proj, "tiny");
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.value.trials.len);
    try testing.expectEqualStrings("legacy", parsed.value.trials[0].plan);
    try testing.expectEqualStrings(source_agent, parsed.value.trials[0].source);

    // And the next id still continues past it rather than colliding.
    const rec = try recordTrialCore(arena, proj, "tiny", sampleTrial());
    try testing.expectEqual(@as(u64, 8), rec.id);
}

// spec: Web Server - record_route_trial is a registered mutation CLI tool
test "record_route_trial is a registered mutation tool" {
    try testing.expect(mcp_tools.isKnownTool("record_route_trial"));
    try testing.expect(mcp_tools.isMutationTool("record_route_trial"));
}

// spec: Web Server - list_route_trials is a registered read-only CLI tool
test "list_route_trials is a registered read-only tool" {
    try testing.expect(mcp_tools.isKnownTool("list_route_trials"));
    try testing.expect(!mcp_tools.isMutationTool("list_route_trials"));
}

// spec: Web Server - remove_route_trial is a registered mutation CLI tool
test "remove_route_trial is a registered mutation tool" {
    try testing.expect(mcp_tools.isKnownTool("remove_route_trial"));
    try testing.expect(mcp_tools.isMutationTool("remove_route_trial"));
}
