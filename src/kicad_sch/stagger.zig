//! Spreading one symbol edge's net labels when its pins sit closer than text.
//!
//! A synthesised body puts its pins on a 2.54 mm pitch, which leaves a whole
//! line of air between one net label and the next. A vendor body owes nothing to
//! that: the Hirose BK13H board-to-board connector draws twenty pins per edge
//! **1.27 mm** apart, and a label is drawn 1.27 mm tall — so forty net names come
//! out stacked with no gap at all, each arrow outline through the next, which is
//! exactly what the schematic's reader reported.
//!
//! Pin geometry is the vendor's and must not move — it is what the pads mean —
//! so the space is made OUTSIDE the body. Each edge's adornments are dealt into
//! two columns by lengthening every other one's stub past the first column's
//! text, which halves the density along the edge without touching a pin.
//!
//! Three properties make that safe rather than merely tidier:
//!
//!   * **Columns are dealt per contiguous same-net RUN, never per pin.** A run
//!     is what `kicad_sch/gang.zig` draws as one wire under one adornment, so
//!     its members keep their tips collinear and the gang still forms.
//!   * **A run's neighbours end up in the other column**, so nothing a column-1
//!     stub crosses on its way out is ever a wire: a column-0 gang's wire spans
//!     only its own members, and a column-1 run sits strictly between two
//!     column-0 runs.
//!   * **The offset clears the widest adornment on the edge**, so a second
//!     column's arrow starts past where a first column's name ends.
//!
//! An edge whose pins are already a line of text apart is left alone, which is
//! every synthesised box and every vendor body on the usual pitch — the pass is
//! a no-op for them, byte for byte.

const std = @import("std");
const emit = @import("emit.zig");
const shape = @import("shape.zig");

/// Height of one drawn line of label text, and so the clearance two neighbouring
/// adornments need along an edge before they are drawn through each other. It is
/// the box `kicad_sch/textbox.zig` gives every string — one font size, the
/// 1.27 mm every label on these sheets is drawn at.
pub const line_h: i32 = shape.grid;

/// Air between the end of one column's text and the next column's arrow.
const column_gap: i32 = shape.grid;

/// Pad id -> the net its label spells, taken from the component's FIRST
/// instance — the same map that orders the symbol's edges, because a library
/// entry is shared by every instance placing it.
pub const NetMap = std.StringHashMapUnmanaged([]const u8);

/// `s` with every unit's per-pin stub extension worked out. Returns the shape
/// unchanged when no edge is crowded (the common case), so a symbol that needs
/// no spreading is emitted byte for byte as before.
pub fn spread(
    arena: std.mem.Allocator,
    s: shape.Shape,
    nets: ?*const NetMap,
) std.mem.Allocator.Error!shape.Shape {
    const map = nets orelse return s;
    const units = try arena.alloc(shape.Unit, s.units.len);
    var any = false;
    for (s.units, units) |u, *out| {
        out.* = u;
        out.stubs = try planUnit(arena, u, map);
        if (out.stubs.len > 0) any = true;
    }
    if (!any) return s;
    var copy = s;
    copy.units = units;
    return copy;
}

/// One unit's stub extensions, or an empty slice when none of its edges is
/// crowded enough to need spreading.
fn planUnit(
    arena: std.mem.Allocator,
    u: shape.Unit,
    map: *const NetMap,
) std.mem.Allocator.Error![]const i32 {
    const out = try arena.alloc(i32, u.pins.len);
    @memset(out, 0);
    var moved = false;
    for (0..4) |si| {
        if (try spreadEdge(arena, u, @fromBackingInt(@intCast(si)), map, out)) moved = true;
    }
    return if (moved) out else &.{};
}

/// One contiguous stretch of a single net along one edge — what a gang draws as
/// one run under one adornment, and so the unit a column holds. `first` and
/// `len` index the edge's own ordered pin list.
const Run = struct { first: usize, len: usize };

/// Deal one edge's runs into two columns. Two runs collide only when their
/// adornments sit within a line of text of each other, so an edge on the usual
/// 2.54 mm pitch never moves and neither does a run long enough to hold its
/// neighbours apart by itself.
fn spreadEdge(
    arena: std.mem.Allocator,
    u: shape.Unit,
    side: shape.Side,
    map: *const NetMap,
    out: []i32,
) std.mem.Allocator.Error!bool {
    const on = try onEdge(arena, u, side, map);
    if (on.len < 2) return false;
    const runs = try runsOf(arena, u, map, on);
    const delta = widest(u, map, on) + column_gap;
    var moved = false;
    var column: i32 = 0;
    for (runs, 0..) |r, j| {
        if (j > 0) column = nextColumn(u, side, on, runs[j - 1], r, column);
        if (column == 0) continue;
        moved = true;
        for (on[r.first..][0..r.len]) |i| out[i] = delta;
    }
    return moved;
}

/// The column a run takes given its predecessor's: the other one when their
/// adornments would be drawn through each other, and the near one otherwise —
/// so a sparse stretch of an edge returns to the body instead of drifting out.
fn nextColumn(
    u: shape.Unit,
    side: shape.Side,
    on: []const usize,
    prev: Run,
    here: Run,
    column: i32,
) i32 {
    const gap = axisOf(u, side, on[here.first]) - axisOf(u, side, on[prev.first]);
    return if (gap <= line_h) 1 - column else 0;
}

/// The edge's labelled pins, ordered the way the SHEET draws them. An unlabelled
/// pad carries a no-connect flag at the pin itself — no stub, no text — so it
/// neither needs a column nor crowds its neighbours, and the pins either side of
/// it are a full two pitches apart.
fn onEdge(
    arena: std.mem.Allocator,
    u: shape.Unit,
    side: shape.Side,
    map: *const NetMap,
) std.mem.Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    for (u.pins, 0..) |p, i| {
        if (p.side != side) continue;
        if (netOf(map, p).len == 0) continue;
        try out.append(arena, i);
    }
    const ctx = Order{ .u = u, .side = side };
    std.mem.sort(usize, out.items, ctx, Order.less);
    return out.items;
}

/// Sort key for one edge: the coordinate that varies along it, oriented the way
/// the sheet draws it. Library coordinates are y-UP and the sheet is y-DOWN, so
/// a left or right edge reads downward as `-y`; a top or bottom edge reads
/// rightward as `x` either way. Ties break on pin index so the order is total.
const Order = struct {
    u: shape.Unit,
    side: shape.Side,

    fn less(self: Order, a: usize, b: usize) bool {
        const ax = axisOf(self.u, self.side, a);
        const bx = axisOf(self.u, self.side, b);
        return if (ax != bx) ax < bx else a < b;
    }
};

fn axisOf(u: shape.Unit, side: shape.Side, i: usize) i32 {
    return switch (side) {
        .left, .right => -u.pins[i].y,
        .top, .bottom => u.pins[i].x,
    };
}

/// Cut the edge's ordered pins where the net changes. Every stretch of one net
/// is one run, whatever its length, so a single-pin net and a twelve-pin ground
/// row are treated alike: one adornment each.
fn runsOf(
    arena: std.mem.Allocator,
    u: shape.Unit,
    map: *const NetMap,
    on: []const usize,
) std.mem.Allocator.Error![]const Run {
    var out: std.ArrayList(Run) = .empty;
    var start: usize = 0;
    for (on, 0..) |i, k| {
        if (k > 0 and std.mem.eql(u8, netOf(map, u.pins[i]), netOf(map, u.pins[on[k - 1]]))) continue;
        if (k > 0) try out.append(arena, .{ .first = start, .len = k - start });
        start = k;
    }
    try out.append(arena, .{ .first = start, .len = on.len - start });
    return out.items;
}

/// How far the widest adornment on this edge reaches out from its pin's stub
/// end — the same rule the sheet reserves space by, so the second column starts
/// exactly past where the first column's text stops.
fn widest(u: shape.Unit, map: *const NetMap, on: []const usize) i32 {
    var out: i32 = 0;
    for (on) |i| out = @max(out, emit.labelSpan(netOf(map, u.pins[i])));
    return out;
}

fn netOf(map: *const NetMap, p: shape.Pin) []const u8 {
    return map.get(p.pad) orelse "";
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// One left-edge pin at library `y`, on `net`.
fn leftPin(pad: []const u8, y: i32) shape.Pin {
    return .{ .pad = pad, .name = pad, .side = .left, .x = -1270, .y = y };
}

/// A unit of `pins`, and the pad -> net map naming them.
fn unitOf(pins: []const shape.Pin) shape.Unit {
    return .{ .number = 1, .title = "", .pins = pins, .half_w = 1016, .half_h = 2540 };
}

fn netMap(a: std.mem.Allocator, pairs: []const [2][]const u8) !NetMap {
    var out: NetMap = .empty;
    for (pairs) |kv| try out.put(a, kv[0], kv[1]);
    return out;
}

// spec: export_kicad_sch - An edge whose pins sit closer together than a line of label text has its runs dealt into two columns, and one on the usual pitch is left alone
test "kicad-sch: a crowded edge spreads into two stub columns and a roomy one does not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Four distinct nets one grid step apart: exactly the board-to-board
    // connector's pitch, and half what a line of text needs.
    const tight = [_]shape.Pin{
        leftPin("1", 381),
        leftPin("2", 254),
        leftPin("3", 127),
        leftPin("4", 0),
    };
    var map = try netMap(a, &.{ .{ "1", "AAA" }, .{ "2", "BBB" }, .{ "3", "CCC" }, .{ "4", "DDD" } });
    const spread_unit = try spread(a, .{ .lib_name = "x", .units = &.{unitOf(&tight)} }, &map);
    const stubs = spread_unit.units[0].stubs;
    try testing.expectEqual(@as(usize, 4), stubs.len);
    // Alternating columns, and the far one clears the widest label on the edge.
    try testing.expectEqual(@as(i32, 0), stubs[0]);
    try testing.expectEqual(@as(i32, 0), stubs[2]);
    try testing.expect(stubs[1] > emit.labelSpan("AAA"));
    try testing.expectEqual(stubs[1], stubs[3]);

    // The same four nets on the 2.54 mm pitch every synthesised body uses have a
    // whole line of air between them already: nothing moves, and the shape comes
    // back untouched so its bytes cannot change.
    const roomy = [_]shape.Pin{
        leftPin("1", 762),
        leftPin("2", 508),
        leftPin("3", 254),
        leftPin("4", 0),
    };
    const kept = try spread(a, .{ .lib_name = "x", .units = &.{unitOf(&roomy)} }, &map);
    try testing.expectEqual(@as(usize, 0), kept.units[0].stubs.len);
    try testing.expectEqual(@as(i32, 0), shape.stubExtra(kept.units[0], 1));
}

// spec: export_kicad_sch - A stub column is dealt per contiguous same-net run, so the pads a gang joins keep one column and one adornment
test "kicad-sch: a same-net run shares one column and holds its neighbours apart" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // GND on three consecutive pads, then two distinct signals.
    const pins = [_]shape.Pin{
        leftPin("1", 508),
        leftPin("2", 381),
        leftPin("3", 254),
        leftPin("4", 127),
        leftPin("5", 0),
    };
    var map = try netMap(a, &.{
        .{ "1", "GND" }, .{ "2", "GND" }, .{ "3", "GND" },
        .{ "4", "SDA" }, .{ "5", "SCL" },
    });
    const out = try spread(a, .{ .lib_name = "x", .units = &.{unitOf(&pins)} }, &map);
    const stubs = out.units[0].stubs;
    // The three grounds are one run: one column, so their tips stay collinear
    // and the gang along that edge still forms.
    try testing.expectEqual(stubs[0], stubs[1]);
    try testing.expectEqual(stubs[1], stubs[2]);
    // The run is three pins long, so the next adornment is well clear of the
    // ground row's single label and stays in the near column…
    try testing.expectEqual(stubs[0], stubs[3]);
    // …and only the pad after THAT, one step from its neighbour, moves out.
    try testing.expect(stubs[4] > stubs[3]);
}

// spec: export_kicad_sch - Spreading an edge is deterministic and never moves a pad that carries no net
test "kicad-sch: spreading repeats exactly and skips unconnected pads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Pad 2 carries nothing: it draws a no-connect at the pin and no text at
    // all, so its neighbours are two pitches apart and none of the three moves.
    const pins = [_]shape.Pin{
        leftPin("1", 254),
        leftPin("2", 127),
        leftPin("3", 0),
    };
    var map = try netMap(a, &.{ .{ "1", "AAA" }, .{ "3", "CCC" } });
    const first = try spread(a, .{ .lib_name = "x", .units = &.{unitOf(&pins)} }, &map);
    try testing.expectEqual(@as(usize, 0), first.units[0].stubs.len);

    // With that pad connected the edge is crowded, and two runs of the same
    // input give the same columns every time.
    try map.put(a, "2", "BBB");
    const one = try spread(a, .{ .lib_name = "x", .units = &.{unitOf(&pins)} }, &map);
    const two = try spread(a, .{ .lib_name = "x", .units = &.{unitOf(&pins)} }, &map);
    try testing.expectEqualSlices(i32, one.units[0].stubs, two.units[0].stubs);
    try testing.expectEqual(@as(i32, 0), one.units[0].stubs[0]);
    try testing.expect(one.units[0].stubs[1] > 0);
    try testing.expectEqual(@as(i32, 0), one.units[0].stubs[2]);
}

// spec: export_kicad_sch - A symbol with no first-instance net map is never spread, so a shape built without one keeps its stubs
test "kicad-sch: spreading needs the net map and leaves a shape without one alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pins = [_]shape.Pin{ leftPin("1", 127), leftPin("2", 0) };
    const out = try spread(a, .{ .lib_name = "x", .units = &.{unitOf(&pins)} }, null);
    try testing.expectEqual(@as(usize, 0), out.units[0].stubs.len);
}

// spec: export_kicad_sch - Spreading a crowded edge moves only the stub and its label, never a vendor body's own pin geometry
test "kicad-sch: a spread unit keeps every pin endpoint, side and body it was given" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pins = [_]shape.Pin{ leftPin("1", 254), leftPin("2", 127), leftPin("3", 0) };
    var map = try netMap(a, &.{ .{ "1", "AAA" }, .{ "2", "BBB" }, .{ "3", "CCC" } });
    var before = unitOf(&pins);
    before.graphics = &.{};
    const after = (try spread(a, .{ .lib_name = "x", .units = &.{before}, .vendor = true }, &map)).units[0];

    // Something moved — this edge IS crowded — and it is only the stub column.
    try testing.expect(after.stubs.len == pins.len);
    try testing.expect(after.stubs[1] > 0);
    // The pads a vendor drew stay exactly where the vendor drew them: the pins
    // are the part, and moving one would move what the pad means.
    try testing.expectEqualSlices(shape.Pin, before.pins, after.pins);
    try testing.expectEqual(before.half_w, after.half_w);
    try testing.expectEqual(before.half_h, after.half_h);
    try testing.expectEqual(before.graphics.len, after.graphics.len);
}
