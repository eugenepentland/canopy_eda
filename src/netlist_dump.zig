//! `netlisp netlist-dump` — the flattened netlist of a design, printed.
//!
//! One line per electrical net, carrying that net's complete sorted pad list.
//! Nets are sorted by name and pads are sorted within their net, so two dumps
//! of the same design compare with `diff` and a reordering is never a
//! difference — the same contract `drc_dump.zig` holds for violations.
//!
//!   netlisp netlist-dump [--project-dir <dir>] <design>…
//!
//! It is READ-ONLY: it evaluates the design (loading the `.bom` sidecar the
//! same read-only way the PCB page does), flattens the hierarchy, and writes to
//! stdout. It writes no file, mints no id, and starts no server.
//!
//! ## What this catches that nothing else does
//!
//! Net and pin COUNTS are already reported in several places, and every one of
//! them reads the same for "the same number of pads" and "the same pads". The
//! bug this surface exists for changed neither count on any board: a pad number
//! emitted as a bare token was re-read by the SI-suffix tokenizer, so `5V`
//! came back as the number `5`, the pad matched nothing, and it silently
//! dropped out of its net. A net that quietly loses one member ships a board
//! with an unconnected pin, and no assertion, no ERC rule and no DRC count
//! moves. Here it is one changed line:
//!
//!   netlisp netlist-dump board-a > base.txt   # built from the base binary
//!   netlisp netlist-dump board-a > cand.txt   # …and from the candidate
//!   diff -I '^#' base.txt cand.txt              # must be empty
//!
//! `#`-prefixed lines carry the wall time and the summary counts, so
//! `diff -I '^#'` compares the netlist alone — timing is information, never
//! part of the identity claim. `scripts/corpus_diff.sh` runs exactly that over
//! the whole board corpus.
//!
//! The flatten itself is `flat_netlist.flattenAndMergeNets`, the same call the
//! KiCad netlist exporter, the placement layer and the server make. Nothing is
//! reimplemented here: a dump that walked the hierarchy its own way would agree
//! with itself while the shipped netlist was wrong.

const std = @import("std");
const clock = @import("infra/clock.zig");
const infra_fs = @import("infra/fs.zig");
const dump_args = @import("dump_args.zig");
const flat_netlist = @import("flat_netlist.zig");
const modules_mod = @import("serve/modules.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

const ns_per_ms: f64 = 1_000_000.0;

pub const DumpError = std.mem.Allocator.Error || std.Io.Writer.Error || error{ NetlistDumpUsage, UnresolvedDesign };

const Args = struct {
    project_dir: []const u8 = "projects/designs",
    names: []const []const u8 = &.{},
};

fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) DumpError!Args {
    var common: dump_args.Common = .{};
    if (!try common.parse(arena, args, {}, dump_args.noExtra)) return error.NetlistDumpUsage;
    return .{ .project_dir = common.project_dir, .names = common.named.items };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn lessNet(_: void, a: flat_netlist.FlatNet, b: flat_netlist.FlatNet) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// One net's members as sorted `refdes.pad` tokens. Duplicates are KEPT: a pad
/// listed twice on one net is itself a difference worth seeing, and silently
/// collapsing it here would hide exactly the class of bug this dump exists for.
fn padTokens(arena: std.mem.Allocator, net: flat_netlist.FlatNet) std.mem.Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, net.pins.len);
    for (net.pins, out) |pin, *token| {
        token.* = try std.fmt.allocPrint(arena, "{s}.{s}", .{ pin.ref_des, pin.pin });
    }
    std.mem.sort([]const u8, out, {}, lessThan);
    return out;
}

/// Render the whole flattened netlist as sorted lines. `nets` is sorted IN
/// PLACE, so the caller's list comes back in dump order too.
///
/// Public because the netlist is also the identity claim other surfaces need to
/// hold constant — `pins_by_name` proves a pad-token rewrite by comparing these
/// exact lines before and after. Rendering them any other way would let the two
/// answers drift.
pub fn lines(
    arena: std.mem.Allocator,
    name: []const u8,
    nets: []flat_netlist.FlatNet,
) DumpError![]const []const u8 {
    std.mem.sort(flat_netlist.FlatNet, nets, {}, lessNet);
    const out = try arena.alloc([]const u8, nets.len);
    for (nets, out) |net, *line| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try aw.writer.print("{s} net {s} pads={d}", .{ name, net.name, net.pins.len });
        for (try padTokens(arena, net)) |token| try aw.writer.print(" {s}", .{token});
        line.* = aw.written();
    }
    return out;
}

fn dumpOne(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    args: Args,
    name: []const u8,
) DumpError!bool {
    var eval = Evaluator.init(alloc, args.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const t0 = clock.nanoTimestamp();
    const block = pcb_layout_page.resolveBlock(alloc, args.project_dir, name, &eval, &module_res) orelse {
        try w.print("# {s} UNRESOLVED\n", .{name});
        return false;
    };
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(alloc, block, &nets);
    const rendered = try lines(alloc, name, nets.items);
    const ns = clock.nanoTimestamp() - t0;

    var pads: usize = 0;
    for (nets.items) |net| pads += net.pins.len;
    try w.print("# {s} ms={d:.1} nets={d} pads={d}\n", .{
        name, @as(f64, @floatFromInt(ns)) / ns_per_ms, rendered.len, pads,
    });
    for (rendered) |line| try w.print("{s}\n", .{line});
    return true;
}

/// CLI entry: `netlisp netlist-dump [--project-dir <dir>] <design>…`.
pub fn cmdNetlistDump(allocator: std.mem.Allocator, args: []const []const u8) DumpError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const parsed = try parseArgs(arena_state.allocator(), args);

    var buf: [64 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(infra_fs.currentIo(), &buf);
    try runParsed(allocator, &fw.interface, parsed);
}

fn runParsed(allocator: std.mem.Allocator, w: *std.Io.Writer, parsed: Args) DumpError!void {
    var unresolved: usize = 0;
    for (parsed.names) |name| {
        // A per-design arena: a large board's evaluated AST plus its flattened
        // netlist runs to hundreds of megabytes, and a corpus dump must peak at
        // one design's worth rather than the sum.
        var design_state = std.heap.ArenaAllocator.init(allocator);
        defer design_state.deinit();
        if (!try dumpOne(design_state.allocator(), w, parsed, name)) unresolved += 1;
        try w.flush();
    }
    try w.flush();
    // A design that never resolved compared nothing. Failing here is what stops
    // a corpus run from reading an empty dump — a wrong `--project-dir`, a
    // renamed board — as "no differences".
    if (unresolved > 0) return error.UnresolvedDesign;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: netlist-dump - the CLI parses the project dir with positionals as design names and refuses a run that names no design
test "netlist-dump CLI parses flags and positionals" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = try parseArgs(arena, &.{ "--project-dir", "p", "board-a", "board-b" });
    try testing.expectEqualStrings("p", parsed.project_dir);
    try testing.expectEqual(@as(usize, 2), parsed.names.len);
    try testing.expectEqualStrings("board-a", parsed.names[0]);
    // A dump naming no design, or carrying an unknown flag, is a usage error
    // rather than a silent empty dump that would "pass" any diff.
    try testing.expectError(error.NetlistDumpUsage, parseArgs(arena, &.{"--project-dir"}));
    try testing.expectError(error.NetlistDumpUsage, parseArgs(arena, &.{ "--wat", "b" }));
    try testing.expectEqualStrings("projects/designs", (try parseArgs(arena, &.{"b"})).project_dir);
}

// spec: netlist-dump - every net renders one compared line carrying its sorted refdes.pad members, nets sort by name, the same netlist dumps byte-identically twice, and a reordering of either is not a difference
test "a dumped netlist sorts its nets and their pads and reproduces byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vdd = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "5V" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const gnd = [_]flat_netlist.FlatPin{.{ .ref_des = "buck/C2", .pin = "2" }};
    var nets = [_]flat_netlist.FlatNet{
        .{ .name = "VDD", .pins = &vdd },
        .{ .name = "GND", .pins = &gnd },
    };
    const rendered = try lines(arena, "demo", &nets);
    try testing.expectEqual(@as(usize, 2), rendered.len);
    try testing.expectEqualStrings("demo net GND pads=1 buck/C2.2", rendered[0]);
    // The pad whose number is `5V` must survive as `5V`, not as `5`: an SI
    // re-read of a bare pad token is exactly the silent drop this dump exists
    // to expose, so the token is asserted verbatim.
    try testing.expectEqualStrings("demo net VDD pads=2 C1.1 U1.5V", rendered[1]);
    // Every emitted line is compared: the per-run number lives on the `#` header
    // `dumpOne` writes, never inside the netlist itself.
    for (rendered) |line| try testing.expect(line.len > 0 and line[0] != '#');

    // The same input dumps identically twice…
    var again = [_]flat_netlist.FlatNet{
        .{ .name = "VDD", .pins = &vdd },
        .{ .name = "GND", .pins = &gnd },
    };
    try expectSameLines(rendered, try lines(arena, "demo", &again));

    // …and so does the same netlist presented in the other order: neither a net
    // reordering nor a pin reordering may read as a difference.
    const vdd_flipped = [_]flat_netlist.FlatPin{ vdd[1], vdd[0] };
    var flipped = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd },
        .{ .name = "VDD", .pins = &vdd_flipped },
    };
    try expectSameLines(rendered, try lines(arena, "demo", &flipped));
}

/// Assert a re-render matches the reference line for line.
///
/// Hoisted out of the test body because `test-no-conditional` allows one
/// top-level loop and that one is spent asserting no netlist line is a comment.
/// The length check is the point of having a named helper: zipping two slices
/// stops at the shorter one, so a re-render that dropped its last net would
/// otherwise compare equal.
fn expectSameLines(want: []const []const u8, got: []const []const u8) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| try testing.expectEqualStrings(a, b);
}

// spec: netlist-dump - a design that fails to resolve marks the run UNRESOLVED and the command fails, producing no compared line at all rather than a vacuous match
test "an unresolvable design fails the netlist dump instead of passing vacuously" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A project dir that exists but contains no such design: the block never
    // resolves, which must surface as a hard error, not an empty green dump.
    const parsed = try parseArgs(arena, &.{ "--project-dir", "/nonexistent-netlisp-project", "no-such-design" });
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.UnresolvedDesign, runParsed(testing.allocator, &out.writer, parsed));
    try testing.expect(std.mem.indexOf(u8, out.written(), "# no-such-design UNRESOLVED") != null);
    // …and the only line it produced is the ignored one, so `diff -I '^#'` over
    // a failed run compares nothing rather than silently comparing equal — which
    // is why the error above, not the empty comparison, is the run's verdict.
    try testing.expectEqual(@as(usize, 0), comparedLines(out.written()));
}

/// How many lines `diff -I '^#'` would actually compare.
fn comparedLines(text: []const u8) usize {
    var kept: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        kept += 1;
    }
    return kept;
}
