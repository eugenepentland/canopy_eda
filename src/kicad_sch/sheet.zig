//! Shelf packing for a schematic sheet.
//!
//! Placement on a label-connected sheet is purely cosmetic — connectivity comes
//! from the net labels, not from where a symbol sits — so this is deliberately
//! the simplest arrangement that stays readable. One routine does the work at
//! all three levels the caller stacks:
//!
//!   * a *cluster* — an IC and the passives that belong to it — packs into a
//!     compact block, so a decoupling bank sits beside the pin it serves;
//!   * a *group* — a section's own parts, or one `(sub-block …)` — packs those
//!     cluster blocks under one caption;
//!   * the *sheet* packs the group blocks side by side.
//!
//! Groups flowing side by side rather than each claiming a full-width band is
//! what keeps a page near A3/A2 proportions: one band per group turned a
//! 20-module section into a page four screens tall and one wide, which is
//! exactly what the hierarchical split exists to avoid.
//!
//! Every position is a multiple of `shape.grid`, because KiCad's ERC reports
//! each off-grid endpoint and one misplaced symbol would bury the report.

const std = @import("std");
const shape_mod = @import("shape.zig");

const grid = shape_mod.grid;

const margin: i32 = 1270;
const gap: i32 = 508;
const min_page: i32 = 29700;
const max_page: i32 = 280000;
/// Target width:height ratio, times ten. A sheet aims at A3/A2 landscape
/// (1.41:1); a cluster or a group packs nearly square so it reads as one block.
const sheet_aspect: i64 = 14;
const block_aspect: i64 = 12;
const aspect_den: i64 = 10;

/// One item's footprint at any packing level: the box it occupies plus where
/// inside that box its own origin belongs (a symbol's cell is wider than its
/// body — net labels stick out on every edge; a group's is taller than its
/// content — the caption sits above).
pub const Cell = struct {
    w: i32,
    h: i32,
    ox: i32,
    oy: i32,
};

/// Position of one packed item's origin.
pub const Spot = struct { x: i32, y: i32 };

/// A packed block: member origins relative to the block's top-left corner,
/// plus the extents the block occupies.
pub const Block = struct {
    spots: []const Spot,
    w: i32,
    h: i32,
};

/// A packed sheet: absolute member origins plus the page they fit in.
pub const Layout = struct {
    spots: []const Spot,
    page_w: i32,
    page_h: i32,
};

/// Pack `cells` into a compact block whose corner is (0, 0). The order given is
/// preserved, so the caller's "hub first, then the passives that serve it"
/// ordering survives into the drawing.
pub fn packCells(arena: std.mem.Allocator, cells: []const Cell) std.mem.Allocator.Error!Block {
    return shelf(arena, cells, block_aspect, 0);
}

/// Pack `cells` across a page, and report the page they need.
pub fn packSheet(arena: std.mem.Allocator, cells: []const Cell) std.mem.Allocator.Error!Layout {
    const block = try shelf(arena, cells, sheet_aspect, margin);
    return .{
        .spots = block.spots,
        .page_w = clampPage(block.w + 2 * margin),
        .page_h = clampPage(block.h + 2 * margin),
    };
}

/// Left-to-right, wrap, top-to-bottom. `pad` offsets every spot (the page
/// margin) and widens the shelf budget to match.
fn shelf(
    arena: std.mem.Allocator,
    cells: []const Cell,
    aspect: i64,
    pad: i32,
) std.mem.Allocator.Error!Block {
    var area: i64 = 0;
    var widest: i32 = 0;
    for (cells) |c| {
        area += @as(i64, c.w) * @as(i64, c.h);
        widest = @max(widest, c.w);
    }
    const limit = rowLimit(area, widest, aspect);

    const spots = try arena.alloc(Spot, cells.len);
    var x: i32 = 0;
    var y: i32 = 0;
    var row_h: i32 = 0;
    var w: i32 = 0;
    for (cells, 0..) |c, i| {
        if (x > 0 and x + c.w > limit) {
            y += row_h + gap;
            x = 0;
            row_h = 0;
        }
        spots[i] = .{ .x = pad + x + c.ox, .y = pad + y + c.oy };
        x += c.w + gap;
        w = @max(w, x - gap);
        row_h = @max(row_h, c.h);
    }
    return .{ .spots = spots, .w = w, .h = if (cells.len == 0) 0 else y + row_h };
}

/// Target shelf width: wide enough for the widest single cell, otherwise sized
/// so the packed area comes out at roughly `aspect`:1.
fn rowLimit(area: i64, widest: i32, aspect: i64) i32 {
    const target = isqrt(@divTrunc(area * aspect, aspect_den));
    return snapUp(@max(widest, @as(i32, @intCast(@min(target, @as(i64, max_page))))));
}

/// Integer square root by Newton iteration — no float round-trip, so the shelf
/// width is bit-identical on every platform.
fn isqrt(v: i64) i64 {
    if (v <= 0) return 0;
    var x: i64 = v;
    var y: i64 = @divTrunc(x + 1, 2);
    while (y < x) {
        x = y;
        y = @divTrunc(x + @divTrunc(v, x), 2);
    }
    return x;
}

/// Round `v` up to the next multiple of the connection grid.
pub fn snapUp(v: i32) i32 {
    const r = @mod(v, grid);
    return if (r == 0) v else v + (grid - r);
}

/// Clamp a computed page extent to a size KiCad accepts — never below a sheet
/// of A4 height, never above the largest user page it will load — and keep it
/// on the connection grid.
pub fn clampPage(v: i32) i32 {
    return snapUp(std.math.clamp(v, min_page, max_page));
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: export_kicad_sch - Shelf packing keeps every origin on the grid, wraps into rows, and never reports a page below the minimum sheet
test "kicad-sch: packSheet grid-snaps every spot and wraps rather than running out" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cells: [12]Cell = @splat(.{ .w = 2540, .h = 2540, .ox = 1270, .oy = 1270 });
    const layout = try packSheet(a, &cells);
    try testing.expectEqual(@as(usize, 12), layout.spots.len);
    for (layout.spots) |s| {
        try testing.expectEqual(@as(i32, 0), @mod(s.x, grid));
        try testing.expectEqual(@as(i32, 0), @mod(s.y, grid));
        try testing.expect(s.x >= margin);
        try testing.expect(s.y >= margin);
    }
    // Twelve equal cells at 1.4:1 cannot fit on one row.
    try testing.expect(layout.spots[11].y > layout.spots[0].y);
    try testing.expect(layout.page_w >= min_page);
    try testing.expect(layout.page_h >= min_page);
    // An empty sheet still reports a legal page.
    const empty = try packSheet(a, &.{});
    try testing.expectEqual(@as(usize, 0), empty.spots.len);
    try testing.expect(empty.page_w >= min_page);
}

// spec: export_kicad_sch - A cluster packs into a compact block that keeps its members in the order given
test "kicad-sch: packCells reports block extents and preserves member order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // One tall hub followed by four small passives: the block must wrap rather
    // than run out in a single row, and its reported extents must cover it.
    const cells = [_]Cell{
        .{ .w = 5080, .h = 5080, .ox = 2540, .oy = 2540 },
        .{ .w = 1270, .h = 1270, .ox = 635, .oy = 635 },
        .{ .w = 1270, .h = 1270, .ox = 635, .oy = 635 },
        .{ .w = 1270, .h = 1270, .ox = 635, .oy = 635 },
        .{ .w = 1270, .h = 1270, .ox = 635, .oy = 635 },
    };
    const block = try packCells(a, &cells);
    try testing.expectEqual(@as(usize, 5), block.spots.len);
    // The hub is placed first, at the block's own top-left corner.
    try testing.expectEqual(@as(i32, 2540), block.spots[0].x);
    try testing.expectEqual(@as(i32, 2540), block.spots[0].y);
    for (block.spots, cells) |s, c| {
        try testing.expect(s.x - c.ox >= 0);
        try testing.expect(s.y - c.oy + c.h <= block.h);
        try testing.expect(s.x - c.ox + c.w <= block.w);
    }
    try testing.expectEqual(@as(usize, 0), (try packCells(a, &.{})).spots.len);
}

// spec: export_kicad_sch - Integer square root and grid snapping stay exact
test "kicad-sch: isqrt and page clamping stay integral" {
    try testing.expectEqual(@as(i64, 0), isqrt(0));
    try testing.expectEqual(@as(i64, 10), isqrt(100));
    try testing.expectEqual(@as(i64, 10), isqrt(120));
    try testing.expectEqual(@as(i32, 1270), snapUp(1200));
    try testing.expectEqual(@as(i32, 1270), snapUp(1270));
    try testing.expect(clampPage(100) >= min_page);
    try testing.expect(clampPage(max_page * 2) <= max_page + grid);
}
