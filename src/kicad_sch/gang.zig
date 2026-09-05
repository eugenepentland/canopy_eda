//! Same-net pin gangs on one placed symbol.
//!
//! A hub's power and ground pads are the same net repeated ten or twenty times.
//! Labelling each one separately is correct and unreadable: fifteen ground
//! symbols under one edge print `GNDGNDGNDGND…` in a smear, and five `VDD`
//! hexagons stack above another. A sheet drawn by hand joins them — one short
//! wire along the edge through every stub tip, a dot at each tap, and ONE
//! adornment for the lot.
//!
//! That wire is why membership is strict. A global label attaches to any wire
//! its anchor lies on, interior included, so a foreign pin's stub tip caught
//! between two gang members would have its own label joined to the gang — a
//! silently merged net, the one failure this exporter must never risk. So a
//! gang is only planned when its members' tips are collinear along one edge and
//! nothing else on that symbol has a tip on the run between them. The pin
//! ordering that makes that common lives in `shape.zig`, which puts same-net
//! pads side by side on their edge; this module never assumes it, and re-checks
//! the geometry it is handed — which is also what lets a vendor body gang when
//! its pins happen to line up, and keep its labels when they do not.
//!
//! A gang is short and local by construction: it never leaves its own symbol's
//! edge, so two gangs on one net are two independent runs, joined — exactly as
//! the separate labels were — by the single label each one keeps.

const std = @import("std");
const shape_mod = @import("shape.zig");
const wire = @import("wire.zig");

/// Fewest pins that make a gang. One pin on a net is the label pair it already
/// had.
pub const min_members: usize = 2;

/// One pin offered to the planner: where its net label or rail symbol would
/// sit, which edge it leaves from, and what it carries. `net` is the LABEL
/// spelling, so per-pin bypass stubs collapsed onto one rail gang together —
/// the same merge their shared label text already made.
pub const PinAt = struct {
    index: u32,
    side: shape_mod.Side,
    net: []const u8,
    at: wire.Point,
};

/// One planned gang: the pins it joins, in order along the edge. `pins[0]` is
/// the one that keeps the adornment — the single global label or ground symbol
/// that names the whole run.
pub const Gang = struct {
    net: []const u8,
    side: shape_mod.Side,
    pins: []const PinAt,
};

/// Plan every gang on one placed unit. Order is first appearance of each
/// (edge, net) pair among `pins`, so the same symbol always gangs the same way.
pub fn plan(
    arena: std.mem.Allocator,
    pins: []const PinAt,
) std.mem.Allocator.Error![]const Gang {
    var by_net: std.array_hash_map.String(std.ArrayList(PinAt)) = .empty;
    defer by_net.deinit(arena);
    for (pins) |p| {
        if (p.net.len == 0) continue;
        const key = try std.fmt.allocPrint(arena, "{d}\x00{s}", .{ @backingInt(p.side), p.net });
        const gop = try by_net.getOrPut(arena, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, p);
    }

    var out: std.ArrayList(Gang) = .empty;
    for (by_net.values()) |*run| {
        if (run.items.len < min_members) continue;
        std.mem.sort(PinAt, run.items, {}, before);
        try cutRuns(arena, &out, pins, run.items);
    }
    return out.items;
}

/// Gang the CONTIGUOUS, COLLINEAR stretches of one edge's same-net pins. Either
/// break cuts the run rather than losing all of it: a vendor body with two
/// grounds low on an edge and a third high up still gangs the pair, and so does
/// one whose net was dealt into two stub columns (`kicad_sch/stagger.zig`) —
/// each column's stretch is a straight line of its own, which is exactly what a
/// gang's wire needs.
fn cutRuns(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Gang),
    all: []const PinAt,
    sorted: []const PinAt,
) std.mem.Allocator.Error!void {
    var start: usize = 0;
    for (1..sorted.len) |i| {
        if (joinable(all, sorted[i - 1], sorted[i])) continue;
        try keepRun(arena, out, sorted[start..i]);
        start = i;
    }
    try keepRun(arena, out, sorted[start..]);
}

/// True when two of a net's pins may sit on one wire: their tips are on the same
/// line along the edge, and nothing foreign has a tip between them.
fn joinable(all: []const PinAt, a: PinAt, b: PinAt) bool {
    if (across(a) != across(b)) return false;
    return adjacent(all, a, b);
}

fn keepRun(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Gang),
    run: []const PinAt,
) std.mem.Allocator.Error!void {
    if (run.len < min_members) return;
    try out.append(arena, .{ .net = run[0].net, .side = run[0].side, .pins = run });
}

/// The coordinate an edge fixes: a left or right edge fixes x, a top or bottom
/// edge fixes y.
fn across(p: PinAt) i32 {
    return switch (p.side) {
        .left, .right => p.at.x,
        .top, .bottom => p.at.y,
    };
}

/// The coordinate that varies along an edge — the one a gang's wire runs in.
fn alongOf(p: PinAt) i32 {
    return switch (p.side) {
        .left, .right => p.at.y,
        .top, .bottom => p.at.x,
    };
}

fn before(_: void, a: PinAt, b: PinAt) bool {
    if (alongOf(a) != alongOf(b)) return alongOf(a) < alongOf(b);
    return a.index < b.index;
}

/// True when no OTHER pin of the same symbol has its tip on the line between
/// two members. Such a tip carries its own label, which KiCad would attach to
/// the gang's wire and so to the gang's net — the silent merge this rule exists
/// to prevent.
fn adjacent(all: []const PinAt, a: PinAt, b: PinAt) bool {
    for (all) |p| {
        if (p.index == a.index or p.index == b.index) continue;
        if (across(p) != across(a)) continue;
        if (alongOf(p) < alongOf(a) or alongOf(p) > alongOf(b)) continue;
        return false;
    }
    return true;
}

/// The gang's wire: its members' tips in order, one point each. Consecutive
/// points become separate two-point wires, so every tap is a real wire END —
/// a wire ending on another wire's interior does not connect in KiCad — which
/// also puts three ends, and so a junction dot, at every interior tap.
pub fn runPts(
    arena: std.mem.Allocator,
    g: Gang,
) std.mem.Allocator.Error![]const wire.Point {
    const pts = try arena.alloc(wire.Point, g.pins.len);
    for (g.pins, pts) |p, *pt| pt.* = p.at;
    return pts;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn pinAt(index: u32, side: shape_mod.Side, net: []const u8, x: i32, y: i32) PinAt {
    return .{ .index = index, .side = side, .net = net, .at = .{ .x = x, .y = y } };
}

// spec: export_kicad_sch - Two or more same-net pins on one edge of a symbol form a gang, and a lone pin on a net does not
test "kicad-sch: gang planning keys on the edge and the net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pins = [_]PinAt{
        pinAt(0, .bottom, "GND", 0, 500),
        pinAt(1, .bottom, "GND", 254, 500),
        pinAt(2, .bottom, "GND", 508, 500),
        pinAt(3, .top, "VDD", 0, -500),
        // Alone on its net, and on the other edge from the grounds.
        pinAt(4, .top, "VBAT", 254, -500),
    };
    const gangs = try plan(a, &pins);
    try testing.expectEqual(@as(usize, 1), gangs.len);
    try testing.expectEqualStrings("GND", gangs[0].net);
    try testing.expectEqual(@as(usize, 3), gangs[0].pins.len);
    // In order along the edge, and the first member is the one that keeps the
    // adornment.
    try testing.expectEqual(@as(u32, 0), gangs[0].pins[0].index);
    try testing.expectEqual(@as(u32, 2), gangs[0].pins[2].index);
    try testing.expectEqual(@as(usize, 0), (try plan(a, &.{})).len);
}

// spec: export_kicad_sch - A gang is refused when a foreign pin's stub tip lies on the run, or when its own tips are not collinear
test "kicad-sch: a gang refuses a run that would cross a foreign tip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A VDD pin sits between two grounds: joining them would run the gang's
    // wire under VDD's own label and merge the two nets.
    const split = [_]PinAt{
        pinAt(0, .bottom, "GND", 0, 500),
        pinAt(1, .bottom, "VDD", 254, 500),
        pinAt(2, .bottom, "GND", 508, 500),
    };
    try testing.expectEqual(@as(usize, 0), (try plan(a, &split)).len);

    // The same three with the grounds side by side gang cleanly.
    const sorted = [_]PinAt{
        pinAt(0, .bottom, "GND", 0, 500),
        pinAt(1, .bottom, "GND", 254, 500),
        pinAt(2, .bottom, "VDD", 508, 500),
    };
    try testing.expectEqual(@as(usize, 1), (try plan(a, &sorted)).len);

    // A vendor body whose same-net pins are not on one line keeps its labels.
    const scattered = [_]PinAt{
        pinAt(0, .left, "GND", -500, 0),
        pinAt(1, .left, "GND", -627, 254),
    };
    try testing.expectEqual(@as(usize, 0), (try plan(a, &scattered)).len);
}

// spec: export_kicad_sch - A foreign pin part-way along an edge cuts the same-net run in two rather than losing both halves
test "kicad-sch: gang planning gangs each contiguous stretch of one net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pins = [_]PinAt{
        pinAt(0, .bottom, "GND", 0, 500),
        pinAt(1, .bottom, "GND", 254, 500),
        pinAt(2, .bottom, "VDD", 508, 500),
        pinAt(3, .bottom, "GND", 762, 500),
        pinAt(4, .bottom, "GND", 1016, 500),
        pinAt(5, .bottom, "GND", 1270, 500),
    };
    const gangs = try plan(a, &pins);
    try testing.expectEqual(@as(usize, 2), gangs.len);
    try testing.expectEqual(@as(usize, 2), gangs[0].pins.len);
    try testing.expectEqual(@as(usize, 3), gangs[1].pins.len);
    try testing.expectEqual(@as(u32, 3), gangs[1].pins[0].index);
}

// spec: export_kicad_sch - A net whose pins were dealt into two stub columns still gangs each column's own stretch
test "kicad-sch: gang planning cuts a net at a column change instead of losing it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Four grounds on one edge, the middle pair pushed out to the far column by
    // the label spreading. Each column's pair is a straight line of its own.
    const pins = [_]PinAt{
        pinAt(0, .left, "GND", -500, 0),
        pinAt(1, .left, "GND", -500, 127),
        pinAt(2, .left, "GND", -2000, 254),
        pinAt(3, .left, "GND", -2000, 381),
    };
    const gangs = try plan(a, &pins);
    try testing.expectEqual(@as(usize, 2), gangs.len);
    try testing.expectEqual(@as(usize, 2), gangs[0].pins.len);
    try testing.expectEqual(@as(usize, 2), gangs[1].pins.len);
    try testing.expectEqual(@as(i32, -500), gangs[0].pins[0].at.x);
    try testing.expectEqual(@as(i32, -2000), gangs[1].pins[0].at.x);
}

// spec: export_kicad_sch - A gang's wire is one span per tap so every member joins it end to end
test "kicad-sch: runPts walks the gang's tips in order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pins = [_]PinAt{
        pinAt(0, .left, "GND", -500, 508),
        pinAt(1, .left, "GND", -500, 0),
        pinAt(2, .left, "GND", -500, 254),
    };
    const gangs = try plan(a, &pins);
    try testing.expectEqual(@as(usize, 1), gangs.len);
    const pts = try runPts(a, gangs[0]);
    try testing.expectEqual(@as(usize, 3), pts.len);
    try testing.expectEqual(@as(i32, 0), pts[0].y);
    try testing.expectEqual(@as(i32, 254), pts[1].y);
    try testing.expectEqual(@as(i32, 508), pts[2].y);
}
