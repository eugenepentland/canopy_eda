//! `netlisp drc-dump` — the whole violation multiset of a saved board, printed.
//!
//! Nothing else in the tool produces one. `netlisp check` is schematic ERC,
//! `bench-page` reports three aggregate DRC counts, and `describe_pcb_layout`
//! summarises. Aggregate counts cannot distinguish "the same NUMBER of
//! findings" from "the same findings", which is the only claim that matters
//! when a change is supposed to be a pure speedup: three DRC refactors in a row
//! (grid-culled sweeps, de-quadratic'd topology, and this per-fill memo) each
//! had to add a throwaway dump command, build two binaries with it, diff the
//! corpus and then strip the patch again. This is that command, kept.
//!
//!   netlisp drc-dump [--project-dir <dir>] [--mutate <k>] [--prime] <design>…
//!
//! It is READ-ONLY: it evaluates the design, restores the saved layout exactly
//! as the PCB page does, runs the two DRC seams, and writes to stdout. It
//! writes no file and starts no server. `--mutate` edits copper IN MEMORY only.
//!
//! Both seams are dumped, because they are different verdicts:
//!
//!   `geom`   — `drc_rules.checkGeometry`, the geometry-only rules the server
//!              runs and the client's wasm twin mirrors.
//!   `report` — `drc_rules.checkFilteredZones`, the full composed report:
//!              geometry against the fabricated fill, plus copper topology,
//!              plus the `net_open` connectivity layer, plus the design's
//!              `<name>.drc-rules.json` severity overrides.
//!
//! Every field of every violation is printed and the lines are SORTED, so two
//! dumps compare with `diff` and a reordering is not a difference. Each seam's
//! wall time is printed on its own `#` comment line, which `diff -I '^#'`
//! ignores — timing is information, never part of the identity claim.
//!
//! ## Proving a memo
//!
//! `--mutate k` applies one deterministic in-memory copper edit before the
//! second dump, and `--prime` runs a discarded DRC pass over the UNMUTATED
//! board first. That pair is what tests a fill memo end to end on a real board:
//!
//!   netlisp drc-dump --mutate 2 --prime barracuda > warm.txt   # borrows fills
//!   netlisp drc-dump --mutate 2         barracuda > cold.txt   # pours them
//!   diff -I '^#' warm.txt cold.txt                             # must be empty
//!
//! A borrowed fill that is not bit-identical to a poured one shows up here as a
//! moved contour, a different component count, or a changed connectivity
//! verdict — all of which are violations that differ.

const std = @import("std");
const clock = @import("infra/clock.zig");
const infra_fs = @import("infra/fs.zig");
const drc = @import("placement/drc.zig");
const drc_rules = @import("serve/drc_rules.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const router = @import("placement/router.zig");
const modules_mod = @import("serve/modules.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

const ns_per_ms: f64 = 1_000_000.0;

pub const DumpError = std.mem.Allocator.Error || std.Io.Writer.Error || error{DrcDumpUsage};

/// One deterministic in-memory copper edit, named by `--mutate`. Each is chosen
/// to invalidate a DIFFERENT slice of a per-fill memo: a track edit reaches only
/// its own layer's fills, a via edit reaches every layer, and an addition
/// reaches whatever its new copper is near.
pub const Mutation = enum(u8) {
    /// The board exactly as saved.
    none = 0,
    /// Nudge the first track 0.05 mm in +x (both endpoints).
    move_track = 1,
    /// Drop the last track.
    delete_track = 2,
    /// Add a copy of the first track, offset 0.3 mm in +y.
    add_track = 3,
    /// Drop the last via.
    delete_via = 4,
    /// Nudge the first via 0.05 mm in +x.
    move_via = 5,
};

/// The mutation `--mutate k` names, or null for a number that names none —
/// rejected rather than defaulted, so a typo cannot silently dump an unmutated
/// board and "match" the comparison it was meant to make.
fn mutationOf(k: u8) ?Mutation {
    inline for (@typeInfo(Mutation).@"enum".field_values) |value| {
        if (value == k) return @fromBackingInt(@intCast(value));
    }
    return null;
}

const Args = struct {
    project_dir: []const u8 = "projects/designs",
    names: []const []const u8 = &.{},
    mutate: Mutation = .none,
    prime: bool = false,
};

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) DumpError!Args {
    var out: Args = .{};
    var names: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project-dir") and i + 1 < args.len) {
            i += 1;
            out.project_dir = args[i];
        } else if (std.mem.eql(u8, a, "--mutate") and i + 1 < args.len) {
            i += 1;
            const k = std.fmt.parseInt(u8, args[i], 10) catch return error.DrcDumpUsage;
            out.mutate = mutationOf(k) orelse return error.DrcDumpUsage;
        } else if (std.mem.eql(u8, a, "--prime")) {
            out.prime = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.DrcDumpUsage;
        } else try names.append(arena, a);
    }
    if (names.items.len == 0) return error.DrcDumpUsage;
    out.names = names.items;
    return out;
}

/// Apply `m` to a copy of `routed`. The copy is deliberate: the caller's
/// restored copper stays intact so the priming pass and the mutated pass are
/// genuinely two board states rather than one aliased one.
pub fn mutate(arena: std.mem.Allocator, routed: router.RouteResult, m: Mutation) std.mem.Allocator.Error!router.RouteResult {
    var out = routed;
    switch (m) {
        .none => return out,
        .move_track, .add_track => {
            if (routed.tracks.len == 0) return out;
            const grown = try arena.alloc(router.Track, routed.tracks.len + @intFromBool(m == .add_track));
            @memcpy(grown[0..routed.tracks.len], routed.tracks);
            if (m == .move_track) {
                grown[0].x1 += 0.05;
                grown[0].x2 += 0.05;
            } else {
                grown[routed.tracks.len] = routed.tracks[0];
                grown[routed.tracks.len].y1 += 0.3;
                grown[routed.tracks.len].y2 += 0.3;
            }
            out.tracks = grown;
        },
        .delete_track => {
            if (routed.tracks.len == 0) return out;
            out.tracks = routed.tracks[0 .. routed.tracks.len - 1];
        },
        .delete_via => {
            if (routed.vias.len == 0) return out;
            out.vias = routed.vias[0 .. routed.vias.len - 1];
        },
        .move_via => {
            if (routed.vias.len == 0) return out;
            const moved = try arena.dupe(router.Via, routed.vias);
            moved[0].x += 0.05;
            out.vias = moved;
        },
    }
    return out;
}

/// One violation as one sortable line. Every field is present — including
/// `who.track_a`, which decides whether a `dangling_copper` finding is offered
/// to automatic cleanup and which `describe_pcb_layout` omits.
fn writeViolation(w: *std.Io.Writer, v: drc.Violation) std.Io.Writer.Error!void {
    try w.print("{s} sev={s} x={d:.6} y={d:.6} gap={d:.6} clr={d:.6} layer=", .{
        @tagName(v.kind), @tagName(v.severity), v.x, v.y, v.gap, v.clearance,
    });
    if (v.layer) |l| try w.print("{d}", .{@backingInt(l)}) else try w.writeAll("-");
    try w.print(" net_a={d} net_b={d} part_a={d} part_b={d} track_a={d} pad_a={s} pad_b={s} bridge=", .{
        v.who.net_a, v.who.net_b, v.who.part_a, v.who.part_b, v.who.track_a, v.who.pad_a, v.who.pad_b,
    });
    if (v.who.bridge) |b| {
        try w.print("{d:.6},{d:.6},{d:.6},{d:.6}", .{ b[0], b[1], b[2], b[3] });
    } else try w.writeAll("-");
}

fn lines(arena: std.mem.Allocator, violations: []const drc.Violation) DumpError![]const []const u8 {
    const out = try arena.alloc([]const u8, violations.len);
    for (violations, out) |v, *line| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try writeViolation(&aw.writer, v);
        line.* = aw.written();
    }
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Dump one seam: its wall time on a `#` line, then its sorted violations.
fn writeSeam(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    name: []const u8,
    seam: []const u8,
    ns: i128,
    violations: []const drc.Violation,
) DumpError!void {
    try w.print("# {s} {s} ms={d:.1} count={d}\n", .{ name, seam, @as(f64, @floatFromInt(ns)) / ns_per_ms, violations.len });
    for (try lines(arena, violations)) |line| try w.print("{s} {s} {s}\n", .{ name, seam, line });
}

fn dumpOne(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    args: Args,
    name: []const u8,
) DumpError!void {
    var eval = Evaluator.init(alloc, args.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = pcb_layout_page.solveForRequest(alloc, args.project_dir, name, .{}, &eval, &module_res) catch {
        try w.print("# {s} UNRESOLVED\n", .{name});
        return;
    };
    const saved = solved.restored.routes orelse router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const clearance = solved.placement.rules.design.routeParams().clearance;
    const zones = solved.shown_zones.user;

    // The priming pass: exactly the work a viewer already did before the edit,
    // discarded. What it leaves behind is a populated memo, which is the state
    // the mutated pass below is meant to be measured (and verified) against.
    if (args.prime) {
        _ = drc_rules.checkFilteredZones(alloc, args.project_dir, name, .{
            .placement = solved.placement,
            .routed = saved,
            .clearance = clearance,
            .zones = zones,
        });
        _ = drc_rules.checkGeometry(alloc, solved.placement, saved, clearance) catch &.{};
    }

    const routed = try mutate(alloc, saved, args.mutate);
    try w.print("# {s} mutate={s} prime={} tracks={d} vias={d} zones={d}\n", .{
        name, @tagName(args.mutate), args.prime, routed.tracks.len, routed.vias.len, zones.len,
    });

    const t_geom = clock.nanoTimestamp();
    const geom = drc_rules.checkGeometry(alloc, solved.placement, routed, clearance) catch &.{};
    const geom_ns = clock.nanoTimestamp() - t_geom;
    try writeSeam(alloc, w, name, "geom", geom_ns, geom);

    const t_report = clock.nanoTimestamp();
    const report = drc_rules.checkFilteredZones(alloc, args.project_dir, name, .{
        .placement = solved.placement,
        .routed = routed,
        .clearance = clearance,
        .zones = zones,
    });
    const report_ns = clock.nanoTimestamp() - t_report;
    try writeSeam(alloc, w, name, "report", report_ns, report);

    const memo = drc_rules.fillMemoStats();
    try w.print("# {s} memo boards={d}/{d} fills={d}/{d} retained={d}+{d} bytes={d}\n", .{
        name,
        memo.tally.board_hits,
        memo.tally.board_hits + memo.tally.board_misses,
        memo.tally.fill_hits,
        memo.tally.fill_hits + memo.tally.fill_misses,
        memo.boards,
        memo.fills,
        memo.bytes,
    });
}

/// CLI entry: `netlisp drc-dump [--project-dir <dir>] [--mutate <k>] [--prime]
/// <design>…`.
pub fn cmdDrcDump(allocator: std.mem.Allocator, args: []const []const u8) DumpError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parseArgs(arena, args);

    var buf: [64 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(infra_fs.currentIo(), &buf);
    for (parsed.names) |name| {
        // A per-board arena: a barracuda-class board's DRC holds hundreds of
        // megabytes, and a corpus dump must peak at one board's worth.
        var board_state = std.heap.ArenaAllocator.init(allocator);
        defer board_state.deinit();
        try dumpOne(board_state.allocator(), &fw.interface, parsed, name);
        try fw.interface.flush();
    }
    try fw.interface.flush();
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: drc-dump - the CLI parses the project dir, the mutation selector and the priming flag with positionals as design names
test "drc-dump CLI parses flags and positionals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parseArgs(arena, &.{ "--project-dir", "p", "--mutate", "3", "--prime", "barracuda", "cyclops" });
    try testing.expectEqualStrings("p", parsed.project_dir);
    try testing.expectEqual(Mutation.add_track, parsed.mutate);
    try testing.expect(parsed.prime);
    try testing.expectEqual(@as(usize, 2), parsed.names.len);
    // A dump with no board named, or an unknown mutation, is a usage error
    // rather than a silent empty dump that would "pass" any diff.
    try testing.expectError(error.DrcDumpUsage, parseArgs(arena, &.{"--prime"}));
    try testing.expectError(error.DrcDumpUsage, parseArgs(arena, &.{ "--mutate", "9", "b" }));
}

// spec: drc-dump - every violation renders one line carrying every field, including the track identity automatic cleanup reads, and the lines sort deterministically
test "a dumped violation carries every field and sorts stably" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const violations = [_]drc.Violation{
        .{ .x = 2, .y = 0, .gap = 0.1, .clearance = 0.2, .kind = .track_track, .who = .{ .track_a = 7, .pad_a = "3" } },
        .{ .x = 1, .y = 0, .gap = 0, .clearance = 0, .kind = .net_open, .severity = .warn, .who = .{ .bridge = .{ 1, 2, 3, 4 } } },
    };
    const sorted = try lines(arena, &violations);
    try testing.expectEqual(@as(usize, 2), sorted.len);
    try testing.expect(std.mem.startsWith(u8, sorted[0], "net_open sev=warn"));
    try testing.expect(std.mem.indexOf(u8, sorted[0], "bridge=1.000000,2.000000,3.000000,4.000000") != null);
    try testing.expect(std.mem.startsWith(u8, sorted[1], "track_track sev=err"));
    try testing.expect(std.mem.indexOf(u8, sorted[1], "track_a=7") != null);
    try testing.expect(std.mem.indexOf(u8, sorted[1], "pad_a=3") != null);
    try testing.expect(std.mem.indexOf(u8, sorted[1], "layer=-") != null);

    // The same multiset in the other order dumps identically — a reordering
    // must never read as a difference.
    const flipped = [_]drc.Violation{ violations[1], violations[0] };
    for (try lines(arena, &flipped), sorted) |a, b| try testing.expectEqualStrings(b, a);
}

// spec: drc-dump - each mutation edits copper in memory only, leaving the board it was given untouched
test "a mutation copies the copper it edits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{ .{ .x = 1, .y = 1, .dia = 0.6, .drill = 0.3, .net = 0 }, .{ .x = 2, .y = 2, .dia = 0.6, .drill = 0.3, .net = 0 } };
    const saved = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 };

    try testing.expectEqual(saved.tracks.len, (try mutate(arena, saved, .none)).tracks.len);
    const moved = try mutate(arena, saved, .move_track);
    try testing.expectEqual(@as(f64, 0.05), moved.tracks[0].x1);
    try testing.expectEqual(@as(f64, 0), tracks[0].x1);
    try testing.expectEqual(@as(usize, 1), (try mutate(arena, saved, .delete_track)).tracks.len);
    try testing.expectEqual(@as(usize, 3), (try mutate(arena, saved, .add_track)).tracks.len);
    try testing.expectEqual(@as(usize, 1), (try mutate(arena, saved, .delete_via)).vias.len);
    try testing.expectEqual(@as(f64, 1.05), (try mutate(arena, saved, .move_via)).vias[0].x);
    try testing.expectEqual(@as(f64, 1), vias[0].x);
}
