//! The schematic traversal both backends drive.
//!
//! One schematic is rendered twice: `render_svg/*` draws it as inline SVG for
//! the page, and `render_json` collects the same picture into the scene-graph
//! JSON the live-push pipeline sends. They are two BACKENDS of one traversal,
//! and the traversal had been copied into each — so a fix to the SVG's spoke
//! ordering or bus geometry left the JSON scene describing a different
//! schematic than the one on screen, silently, since nothing compares them.
//!
//! What lives here is only the walk: which spokes are visited, in what order,
//! and at what coordinates. Emitting a wire, a passive body or a terminal
//! label is the backend's business and reaches it through a small sink:
//!
//!   `wire(...)`      — a straight segment
//!   `passive(...)`   — one passive body at the chain cursor
//!   `significant(t)` — does this terminal name get drawn at all?
//!   `branchEnd(r)`   — the x a branch body ends at (the SVG backend
//!                      materialises a deferred series here; the JSON one
//!                      already knows it)
//!   `terminal(...)`  — the terminal symbol/label
//!
//! Sinks are `anytype` rather than an interface: this is a hot inner loop with
//! two implementations, both known at compile time.

const std = @import("std");
const ctx_mod = @import("context.zig");

const Side = ctx_mod.Side;
const FlatInst = ctx_mod.FlatInst;

/// The pin-to-pin gap between two bodies in a series chain, and the offset a
/// grouped terminal's shared bus stands off its nearest branch end. One value:
/// `render_json`, `render_svg/branch` and `render_svg/connection` each used to
/// declare their own `20.0`.
pub const chain_gap: f64 = 20.0;

/// A drawn passive body's width. Re-exported so a caller of `passiveChain`
/// need not reach into `draw` for the constant the walk advances by.
pub const passive_bw = @import("draw.zig").passive_bw;

/// Sentinel for a per-side extremum search — larger than any schematic
/// coordinate this layout produces.
const far_x_sentinel: f64 = 99999.0;

/// One straight segment a terminal group closes with: which net it belongs to,
/// its two endpoints, and whether it is the group's vertical collector bus
/// (the JSON backend records that distinction; the SVG one draws the same line
/// either way).
pub const Segment = struct {
    term: []const u8,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    vertical: bool = false,
};

/// Which way a chain grows from its anchor. `left` chains hang the hub on the
/// right of each body and advance in −x; `right` is the mirror.
pub const Direction = enum { left, right };

/// Walk one horizontal series chain of passive spokes from `start_x`, and
/// return the x the chain ends at so the caller can attach a terminal.
///
/// `sink.wire(x1, y1, x2, y2)` draws the pin gap between two bodies;
/// `sink.passive(inst, x, cy, dir)` draws one body at the chain CURSOR — the
/// backend applies its own body offset, since the SVG drawer measures a left
/// body from its right edge and the scene graph records its left edge.
pub fn passiveChain(
    sink: anytype,
    dir: Direction,
    start_x: f64,
    cy: f64,
    spokes: []const FlatInst,
) !f64 {
    if (spokes.len == 0) return start_x;
    const sign: f64 = switch (dir) {
        .left => -1.0,
        .right => 1.0,
    };
    var x = start_x;
    for (spokes, 0..) |inst, i| {
        if (i > 0) {
            try sink.wire(x, cy, x + sign * chain_gap, cy);
            x += sign * chain_gap;
        }
        try sink.passive(inst, x, cy, dir);
        x += sign * passive_bw;
    }
    return x;
}

/// Walk the finished branch bodies in `results`, grouping the consecutive run
/// that shares a terminal name, and emit each group's closing geometry.
///
/// `results` must already be ordered so equal terminal names are adjacent (both
/// backends sort by terminal before calling). A group of one closes straight to
/// `term_x`; a group of several first collects onto a shared vertical bus one
/// `chain_gap` beyond the group's NEAREST branch end, then closes to `term_x`
/// from the last row — which is what makes several branches on one net read as
/// one labelled net rather than as several.
///
/// An insignificant terminal is skipped whole: its branches are already drawn,
/// but nothing closes them to a label.
///
/// Sink: `significant(term) bool`, `branchEnd(r) !f64`,
/// `wire(Segment) !void`, `terminal(x, cy, term, anchor) !void`.
pub fn terminalGroups(
    sink: anytype,
    results: anytype,
    term_x: f64,
    side: Side,
) !void {
    if (results.len == 0) return;

    const anchor: []const u8 = switch (side) {
        .left => "end",
        .right => "start",
    };

    var i: usize = 0;
    while (i < results.len) {
        const term = results[i].terminal;
        var j = i + 1;
        while (j < results.len) : (j += 1) {
            if (!std.mem.eql(u8, results[j].terminal, term)) break;
        }
        const group = results[i..j];
        i = j;

        if (!sink.significant(term)) continue;

        if (group.len == 1) {
            const r = group[0];
            const end_x = try sink.branchEnd(r);
            try sink.wire(Segment{ .term = term, .x1 = end_x, .y1 = r.cy, .x2 = term_x, .y2 = r.cy });
            try sink.terminal(term_x, r.cy, term, anchor);
            continue;
        }

        var nearest_x: f64 = switch (side) {
            .left => far_x_sentinel,
            .right => -far_x_sentinel,
        };
        for (group) |r| switch (side) {
            .left => nearest_x = @min(nearest_x, r.end_x),
            .right => nearest_x = @max(nearest_x, r.end_x),
        };
        const bus_x = switch (side) {
            .left => nearest_x - chain_gap,
            .right => nearest_x + chain_gap,
        };

        const first_cy = group[0].cy;
        const last_cy = group[group.len - 1].cy;

        for (group) |r| {
            const end_x = try sink.branchEnd(r);
            try sink.wire(Segment{ .term = term, .x1 = end_x, .y1 = r.cy, .x2 = bus_x, .y2 = r.cy });
        }
        try sink.wire(Segment{ .term = term, .x1 = bus_x, .y1 = first_cy, .x2 = bus_x, .y2 = last_cy, .vertical = true });
        try sink.wire(Segment{ .term = term, .x1 = bus_x, .y1 = last_cy, .x2 = term_x, .y2 = last_cy });
        try sink.terminal(term_x, last_cy, term, anchor);
    }
}

// ── Tests ─────────────────────────────────────────────────────────────

/// Records the op sequence a walk emits, so a test can assert the ORDER and
/// the coordinates rather than either backend's output format.
const RecordingSink = struct {
    ops: std.ArrayList([]const u8),
    alloc: std.mem.Allocator,
    insignificant: []const u8 = "",

    fn wire(self: *RecordingSink, seg: Segment) !void {
        try self.ops.append(self.alloc, try std.fmt.allocPrint(
            self.alloc,
            "wire {s} {d}:{d}->{d}:{d}{s}",
            .{ seg.term, seg.x1, seg.y1, seg.x2, seg.y2, if (seg.vertical) " v" else "" },
        ));
    }

    fn significant(self: *RecordingSink, term: []const u8) bool {
        return !std.mem.eql(u8, term, self.insignificant);
    }

    fn branchEnd(_: *RecordingSink, r: anytype) !f64 {
        return r.end_x;
    }

    fn terminal(self: *RecordingSink, x: f64, cy: f64, term: []const u8, anchor: []const u8) !void {
        try self.ops.append(self.alloc, try std.fmt.allocPrint(
            self.alloc,
            "term {s} {d}:{d} {s}",
            .{ term, x, cy, anchor },
        ));
    }
};

const Body = struct { end_x: f64, cy: f64, terminal: []const u8 };

// spec: render_svg - The shared terminal-group walk buses a repeated terminal off its nearest branch end and skips an insignificant one
test "terminalGroups buses a repeated terminal and skips an insignificant one" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const results = [_]Body{
        .{ .end_x = 100, .cy = 10, .terminal = "VDD" },
        .{ .end_x = 120, .cy = 30, .terminal = "VDD" },
        .{ .end_x = 110, .cy = 50, .terminal = "NC" },
        .{ .end_x = 130, .cy = 70, .terminal = "OUT" },
    };
    var sink = RecordingSink{ .ops = .empty, .alloc = alloc, .insignificant = "NC" };
    try terminalGroups(&sink, &results, 200, .right);

    // The VDD pair collects onto a bus one chain_gap past its FARTHEST end on
    // a right-hand side (120 + 20), closes from the last row, then labels
    // there. NC is skipped whole. OUT is a group of one and closes directly.
    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "wire VDD 100:10->140:10",
        "wire VDD 120:30->140:30",
        "wire VDD 140:10->140:30 v",
        "wire VDD 140:30->200:30",
        "term VDD 200:30 start",
        "wire OUT 130:70->200:70",
        "term OUT 200:70 start",
    }), sink.ops.items);
}

/// Records the passive chain as `(cursor x, direction)` per body plus the gap
/// wires between them.
const ChainSink = struct {
    ops: std.ArrayList([]const u8),
    alloc: std.mem.Allocator,

    fn wire(self: *ChainSink, x1: f64, _: f64, x2: f64, _: f64) !void {
        try self.ops.append(self.alloc, try std.fmt.allocPrint(self.alloc, "gap {d}->{d}", .{ x1, x2 }));
    }

    fn passive(self: *ChainSink, _: FlatInst, x: f64, _: f64, dir: Direction) !void {
        try self.ops.append(self.alloc, try std.fmt.allocPrint(self.alloc, "body {d} {s}", .{ x, @tagName(dir) }));
    }
};

// spec: render_svg - The shared passive-chain walk advances one body width and one pin gap per spoke, mirrored per side
test "passiveChain advances by body width and pin gap, mirrored per side" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const spokes = [_]FlatInst{
        .{ .ref_des = "R1", .component = "res-0402", .value = "10k", .symbol = "generic-res" },
        .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .symbol = "generic-cap" },
    };

    var right = ChainSink{ .ops = .empty, .alloc = alloc };
    try testing.expectEqual(@as(f64, 200), try passiveChain(&right, .right, 100, 0, &spokes));
    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "body 100 right",
        "gap 140->160",
        "body 160 right",
    }), right.ops.items);

    var left = ChainSink{ .ops = .empty, .alloc = alloc };
    try testing.expectEqual(@as(f64, 0), try passiveChain(&left, .left, 100, 0, &spokes));
    try testing.expectEqualDeep(@as([]const []const u8, &.{
        "body 100 left",
        "gap 60->40",
        "body 40 left",
    }), left.ops.items);

    // An empty chain draws nothing and leaves the cursor where it started.
    var none = ChainSink{ .ops = .empty, .alloc = alloc };
    try testing.expectEqual(@as(f64, 7), try passiveChain(&none, .left, 7, 0, &.{}));
    try testing.expectEqual(@as(usize, 0), none.ops.items.len);
}
