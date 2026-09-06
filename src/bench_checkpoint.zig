//! `bench-route --jsonl <path>` — each board's result on disk the moment that
//! board finishes, instead of after every board has.
//!
//! ## Why
//!
//! `bench-route --json` buffers the whole corpus and writes one document at the
//! end. A three-board run was killed with exit 137 under memory pressure after
//! several minutes; the two boards that HAD finished were lost with the one that
//! had not, and nothing in the logs said how far the run had got. The recorded
//! workaround was to run every board as its own process, which gives up the
//! shared corpus geomean the harness exists to compute.
//!
//! ## The record
//!
//! A JSON Lines stream, flushed and fsynced after every line, so a reader gets
//! each board as it lands:
//!
//!   {"kind":"run",      …}   inputs, tool revision and policy — always first
//!   {"kind":"board",    …}   one per FINISHED board, in corpus order
//!   {"kind":"complete", …}   only when every board finished
//!
//! The `board` payload is `bench_route.writeBoardJson`'s, the same renderer the
//! aggregate `--json` document uses, so a checkpoint row and an aggregate row
//! are the same bytes.
//!
//! ## A partial file cannot claim success
//!
//! The two failure modes a consumer must tell apart are a board that FAILED and
//! a corpus that never FINISHED, and the record distinguishes them structurally
//! rather than by a count:
//!
//!   * A board that failed to load or route is a `board` line with `"ok":false`.
//!     The board was measured; the answer is a failure.
//!   * A corpus that was interrupted has no `complete` line at all. There is no
//!     field to misread, no total to compare against, and nothing a consumer can
//!     mistake for a finished run — the terminator is simply absent.
//!
//! `complete` carries the geomean and the board count so a finished run is
//! self-describing without re-deriving anything.
//!
//! ## What a hard kill can still truncate
//!
//! Each line is composed in memory and written in ONE `writeAll` followed by a
//! sync, so a line either lands or does not. A process killed inside that write
//! can still leave a partial final line — the kernel is under no obligation to
//! make an arbitrary-length write atomic — so the documented read rule is:
//! parse line by line and DROP an unparseable final line. Every earlier line is
//! intact. `parseCountingRows` is that rule, and it is what the tests assert.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");

pub const CheckpointError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    infra_fs.File.WriteError || std.Io.File.SyncError || error{CheckpointOpenFailed};

/// What a run was measuring, recorded before the first board so an interrupted
/// file still identifies its own inputs.
pub const RunHeader = struct {
    /// The netlisp build the measurement came from (`main.process_build_id`).
    tool: []const u8,
    project_dir: []const u8,
    /// Path-director selection: `lattice` or `field`.
    route_space: []const u8,
    /// Whether saved module snapshot routes seeded the run.
    saved_module_routes: bool,
    /// The candidate layout each board's copper is captured to, if any.
    save_candidate: ?[]const u8 = null,
    /// Every board the run intends to measure, in order. A reader comparing
    /// this against the `board` lines present knows exactly which board was
    /// running when the process died.
    boards: []const []const u8,
};

/// The `run` record's bytes. A free function so a test can read the header
/// without a file, and so the record's shape lives in one place.
pub fn renderHeader(w: *std.Io.Writer, header: RunHeader) json_writer.WriteError!void {
    try w.writeAll("{\"kind\":\"run\",\"tool\":");
    try json_writer.writeString(w, header.tool);
    try w.writeAll(",\"project_dir\":");
    try json_writer.writeString(w, header.project_dir);
    try w.writeAll(",\"route_space\":");
    try json_writer.writeString(w, header.route_space);
    try w.print(",\"saved_module_routes\":{}", .{header.saved_module_routes});
    if (header.save_candidate) |target| {
        try w.writeAll(",\"save_candidate\":");
        try json_writer.writeString(w, target);
    }
    try w.writeAll(",\"boards\":[");
    for (header.boards, 0..) |name, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, name);
    }
    try w.writeAll("]}");
}

/// An open checkpoint stream. `deinit` closes the file; a caller that never
/// reaches `finish` deliberately leaves the stream without its `complete` line.
pub const Checkpoint = struct {
    file: infra_fs.File,
    /// Composed in memory so each record reaches the file as one write.
    line: std.Io.Writer.Allocating,

    pub fn create(allocator: std.mem.Allocator, path: []const u8, header: RunHeader) CheckpointError!Checkpoint {
        return createIn(allocator, infra_fs.cwd(), path, header);
    }

    /// `create` against an explicit directory, so a test can write into a
    /// temporary directory it owns rather than into the working tree.
    pub fn createIn(
        allocator: std.mem.Allocator,
        dir: infra_fs.Dir,
        sub_path: []const u8,
        header: RunHeader,
    ) CheckpointError!Checkpoint {
        const file = dir.createFile(sub_path, .{}) catch return error.CheckpointOpenFailed;
        var self: Checkpoint = .{ .file = file, .line = .init(allocator) };
        try self.writeHeader(header);
        return self;
    }

    fn writeHeader(self: *Checkpoint, header: RunHeader) CheckpointError!void {
        try renderHeader(&self.line.writer, header);
        try self.commit();
    }

    /// Append one already-rendered board row. `render` writes the row's JSON
    /// object into the writer it is handed — `bench_route.writeBoardJson`,
    /// bound to its board — so this module never learns a board's shape.
    pub fn writeBoard(self: *Checkpoint, context: anytype, comptime render: anytype) CheckpointError!void {
        const w = &self.line.writer;
        try w.writeAll("{\"kind\":\"board\",\"result\":");
        try render(w, context);
        try w.writeAll("}");
        try self.commit();
    }

    /// The terminator. Written ONLY when every board finished, so its absence
    /// is what marks an interrupted corpus.
    pub fn finish(self: *Checkpoint, boards: usize, geomean_completion: f64) CheckpointError!void {
        try self.line.writer.print(
            "{{\"kind\":\"complete\",\"boards\":{d},\"geomean_completion\":{d:.6}}}",
            .{ boards, geomean_completion },
        );
        try self.commit();
    }

    /// One line, one write, then a sync: a reader tailing the file sees a
    /// finished board the moment it finishes, and a crash cannot leave an
    /// earlier line half-written.
    fn commit(self: *Checkpoint) CheckpointError!void {
        try self.line.writer.writeAll("\n");
        try self.file.writeAll(self.line.written());
        // Durability IS the feature: a row that reached the page cache and no
        // further is exactly the row an OOM kill loses. A failed sync is
        // therefore reported, not swallowed — a caller told the run completed
        // when the record did not reach the disk is worse than a failed run.
        try self.file.sync();
        self.line.clearRetainingCapacity();
    }

    pub fn deinit(self: *Checkpoint) void {
        self.file.close();
        self.line.deinit();
    }
};

/// What a checkpoint file says happened, under the documented read rule: parse
/// line by line, drop an unparseable final line.
pub const Reading = struct {
    /// `run` header seen.
    header: bool = false,
    /// Complete `board` rows recovered.
    boards: usize = 0,
    /// Boards the header said the run intended to measure.
    planned: usize = 0,
    /// Boards whose row carries `"ok":false`.
    failed: usize = 0,
    /// True only when the `complete` terminator is present.
    complete: bool = false,
    /// True when a trailing line could not be parsed and was dropped — a
    /// process killed mid-write. Never true for a line other than the last.
    truncated_tail: bool = false,
};

/// Apply the read rule to `text`. Deliberately here rather than in a consumer
/// script: "an unfinished corpus is one with no `complete` line" is the
/// contract, and the contract deserves a tested implementation.
pub fn parseCountingRows(allocator: std.mem.Allocator, text: []const u8) std.mem.Allocator.Error!Reading {
    var out: Reading = .{};
    var it = std.mem.splitScalar(u8, text, '\n');
    var pending: ?[]const u8 = null;
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (pending) |prev| try countRow(allocator, prev, &out);
        pending = line;
    }
    // The final line is the only one a kill can truncate, so it is the only one
    // allowed to fail to parse.
    if (pending) |last| {
        if (!try parses(allocator, last)) {
            out.truncated_tail = true;
        } else try countRow(allocator, last, &out);
    }
    return out;
}

fn parses(allocator: std.mem.Allocator, line: []const u8) std.mem.Allocator.Error!bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    parsed.deinit();
    return true;
}

fn countRow(allocator: std.mem.Allocator, line: []const u8, out: *Reading) std.mem.Allocator.Error!void {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const kind = switch (obj.get("kind") orelse return) {
        .string => |v| v,
        else => return,
    };
    if (std.mem.eql(u8, kind, "run")) {
        out.header = true;
        if (obj.get("boards")) |b| switch (b) {
            .array => |a| out.planned = a.items.len,
            else => {},
        };
    } else if (std.mem.eql(u8, kind, "board")) {
        out.boards += 1;
        const result = obj.get("result") orelse return;
        const ok = switch (result) {
            .object => |o| o.get("ok") orelse return,
            else => return,
        };
        if (ok == .bool and !ok.bool) out.failed += 1;
    } else if (std.mem.eql(u8, kind, "complete")) {
        out.complete = true;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

const fake_header: RunHeader = .{
    .tool = "abc1234",
    .project_dir = "/scratch/bench",
    .route_space = "lattice",
    .saved_module_routes = true,
    .boards = &.{ "board-a", "board-b" },
};

/// A stand-in for `bench_route.writeBoardJson`: the checkpoint never learns a
/// board's shape, so a fake row is enough to exercise the record.
fn fakeBoard(w: *std.Io.Writer, ok: bool) json_writer.WriteError!void {
    try w.print("{{\"name\":\"board\",\"ok\":{},\"routed\":3,\"total\":4}}", .{ok});
}

fn writeStream(dir: infra_fs.Dir, path: []const u8, boards: usize, ok: bool, complete: bool) !void {
    var cp = try Checkpoint.createIn(testing.allocator, dir, path, fake_header);
    defer cp.deinit();
    for (0..boards) |_| try cp.writeBoard(ok, fakeBoard);
    if (complete) try cp.finish(boards, 0.75);
}

fn readAll(arena: std.mem.Allocator, dir: infra_fs.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(arena, path, 1 << 20);
}

// spec: bench checkpoint - a finished board is on disk and parseable before the next board is measured
test "a board row lands and is readable before the run ends" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const dir: infra_fs.Dir = .{ .d = tmp.dir };

    var cp = try Checkpoint.createIn(testing.allocator, dir, "run.jsonl", fake_header);
    try cp.writeBoard(true, fakeBoard);
    // Deliberately BEFORE the second board and before `finish`: this is the
    // whole claim — the first result survives whatever happens next.
    const mid = try parseCountingRows(testing.allocator, try readAll(arena_state.allocator(), dir, "run.jsonl"));
    try testing.expect(mid.header);
    try testing.expectEqual(@as(usize, 2), mid.planned);
    try testing.expectEqual(@as(usize, 1), mid.boards);
    try testing.expect(!mid.complete);
    cp.deinit();
}

// spec: bench checkpoint - an interrupted corpus has no completion record so a partial file can never read as a finished run
test "an interrupted run is missing its completion record" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const dir: infra_fs.Dir = .{ .d = tmp.dir };

    try writeStream(dir, "partial.jsonl", 1, true, false);
    try writeStream(dir, "whole.jsonl", 2, true, true);
    const stopped = try parseCountingRows(testing.allocator, try readAll(arena_state.allocator(), dir, "partial.jsonl"));
    const finished = try parseCountingRows(testing.allocator, try readAll(arena_state.allocator(), dir, "whole.jsonl"));
    // One board measured out of two planned, and no terminator.
    try testing.expectEqual(@as(usize, 1), stopped.boards);
    try testing.expectEqual(@as(usize, 2), stopped.planned);
    try testing.expect(!stopped.complete);
    try testing.expect(finished.complete);
    try testing.expectEqual(@as(usize, 2), finished.boards);
}

// spec: bench checkpoint - a board that failed to route is a recorded failure, distinct from a corpus that never finished
test "a failed board is recorded as a failure, not as a missing board" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const dir: infra_fs.Dir = .{ .d = tmp.dir };
    try writeStream(dir, "failed.jsonl", 2, false, true);
    const reading = try parseCountingRows(testing.allocator, try readAll(arena_state.allocator(), dir, "failed.jsonl"));
    // Both boards were MEASURED and both failed; the corpus itself finished.
    try testing.expectEqual(@as(usize, 2), reading.boards);
    try testing.expectEqual(@as(usize, 2), reading.failed);
    try testing.expect(reading.complete);
}

// spec: bench checkpoint - a line truncated by a kill is dropped and every earlier board survives
test "a truncated final line is dropped and the earlier rows survive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var whole = std.Io.Writer.Allocating.init(testing.allocator);
    defer whole.deinit();
    // Build the same stream in memory, then cut it mid-line the way SIGKILL
    // during a write would. No real OOM kill is needed to test the read rule.
    try renderHeader(&whole.writer, fake_header);
    try whole.writer.writeAll("\n");
    try whole.writer.writeAll("{\"kind\":\"board\",\"result\":");
    try fakeBoard(&whole.writer, true);
    try whole.writer.writeAll("}\n");
    const intact = try arena.dupe(u8, whole.written());
    try whole.writer.writeAll("{\"kind\":\"board\",\"result\":{\"name\":\"half");

    const cut = try parseCountingRows(testing.allocator, whole.written());
    try testing.expect(cut.truncated_tail);
    try testing.expectEqual(@as(usize, 1), cut.boards);
    try testing.expect(cut.header);
    try testing.expect(!cut.complete);
    // The same stream WITHOUT the severed tail reads identically apart from the
    // truncation flag, so nothing before the cut was affected by it.
    const clean = try parseCountingRows(testing.allocator, intact);
    try testing.expect(!clean.truncated_tail);
    try testing.expectEqual(cut.boards, clean.boards);
}

// spec: bench checkpoint - the run header records the tool revision, project and seed policy so an interrupted file identifies its own inputs
test "the run header identifies the tool, inputs and seed policy" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    var header = fake_header;
    header.saved_module_routes = false;
    header.save_candidate = "trial-3";
    header.route_space = "field";
    try renderHeader(&out.writer, header);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, std.mem.trimEnd(u8, out.written(), "\n"), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try testing.expectEqualStrings("abc1234", obj.get("tool").?.string);
    try testing.expectEqualStrings("/scratch/bench", obj.get("project_dir").?.string);
    try testing.expectEqualStrings("field", obj.get("route_space").?.string);
    try testing.expectEqualStrings("trial-3", obj.get("save_candidate").?.string);
    try testing.expect(!obj.get("saved_module_routes").?.bool);
    try testing.expectEqual(@as(usize, 2), obj.get("boards").?.array.items.len);
}

// spec: bench checkpoint - a checkpoint path that cannot be created fails the run instead of measuring without a record
test "an unopenable checkpoint path is an error, not a silent skip" {
    try testing.expectError(
        error.CheckpointOpenFailed,
        Checkpoint.create(testing.allocator, "/nonexistent-netlisp-dir/run.jsonl", fake_header),
    );
}
