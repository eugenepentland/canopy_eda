//! The router's uniform-cell spatial index over axis-aligned obstacle boxes —
//! pads, routed tracks, and via barrels — plus the box type it indexes.
//!
//! Every exact clearance probe in `router.zig` has the same shape: "of the
//! thousands of boxes on this board, which few could possibly be within
//! clearance of this point or this segment?". A linear scan answers that in
//! O(all copper) per probe and the direct-synthesis lattice sweeps pay millions
//! of probes, so the answer is bucketed once into a grid of cells and looked up
//! per probe.
//!
//! The index is a SUPERSET filter and nothing more: a candidate still faces the
//! same exact distance test it would have faced in the full scan, so a routing
//! run's verdicts are identical with or without it (`padGridCoversFullScan` and
//! `nearSegmentCoversFullScan` below pin that property for the point and
//! segment queries). Anything that cannot be built — a degenerate board, an
//! oversized cell grid, an allocation failure — comes back null so the caller
//! falls back to the scan rather than trusting a partial index.
//!
//! It addresses its boxes BY POSITION IN THE SLICE it was built from, which is
//! the whole reason `router.Ctx` carries a generation stamp alongside it: the
//! router's copper lists are compacted in place by the cleanup passes, and a
//! surviving index then names a different track than it was built for. This
//! module holds no opinion about that — it is the caller's job never to query
//! an index whose backing slice has been reordered.

const std = @import("std");
const numeric = @import("../numeric.zig");

/// One axis-aligned obstacle the index buckets: a pad's copper box, a track's
/// bounding box, or a via barrel's centre point (a degenerate box). `poly`
/// carries the real pad outline where a caller measures against copper shape
/// rather than the box; `layer` / `thru` say which copper faces it occupies.
pub const PadObs = struct { x0: f64, y0: f64, x1: f64, y1: f64, poly: []const [2]f64 = &.{}, net: i32, layer: u8 = 0, thru: bool = false };

/// The world rectangle an index must cover at minimum — normally the routing
/// grid's own extent, so a query anywhere on the board lands in a real cell.
/// Boxes outside it widen the built index; they never fall out of it.
pub const Bounds = struct { minx: f64, miny: f64, maxx: f64, maxy: f64 };

/// Candidate-box scratch cap for `nearSegment`: a probe whose segment bbox
/// covers more candidates than this falls back to the full scan (same verdict,
/// more work — rare on the short lattice hops these serve).
pub const near_scratch_len: usize = 64;

/// Largest cell count an index may allocate. Past this the buckets cost more to
/// build and walk than the full scan they replace, so `build` declines.
const max_cells: usize = 1 << 22;

/// Uniform spatial bucket grid over obstacle boxes. Each box is inserted into
/// every cell its `reach`-expanded bounding box overlaps, so a query for the
/// cell containing a point returns every box within `reach` of that point (plus
/// a few harmless extras the exact distance test rejects).
pub const PadGrid = struct {
    ox: f64,
    oy: f64,
    cell: f64,
    nx: usize,
    ny: usize,
    cells: []const []const u32,

    /// The cell column/row holding world coordinate `w`, clamped into `[0, n)`
    /// so a query outside the built extent lands in the nearest edge cell
    /// rather than out of bounds.
    pub fn cellFor(w: f64, o: f64, cell: f64, n: usize) usize {
        const f = @floor((w - o) / cell);
        if (f < 0) return 0;
        const iu: usize = numeric.checkedInt(usize, f) orelse return 0;
        return @min(iu, n - 1);
    }

    /// Boxes whose expanded box overlaps the cell containing `(px, py)`.
    pub fn near(self: *const PadGrid, px: f64, py: f64) []const u32 {
        const cx = cellFor(px, self.ox, self.cell, self.nx);
        const cy = cellFor(py, self.oy, self.cell, self.ny);
        return self.cells[cy * self.nx + cx];
    }

    /// Build the index, or return null (degenerate board / oversized grid) so
    /// the caller falls back to the exact full scan. Any allocation failure
    /// returns null rather than a partially-populated (wrong) index.
    pub fn build(arena: std.mem.Allocator, obs: []const PadObs, bounds: Bounds, reach: f64) ?*const PadGrid {
        if (obs.len == 0) return null;
        const cell = @max(reach * 4.0, 1.0);
        var minx = bounds.minx;
        var miny = bounds.miny;
        var maxx = bounds.maxx;
        var maxy = bounds.maxy;
        for (obs) |p| {
            minx = @min(minx, p.x0 - reach);
            miny = @min(miny, p.y0 - reach);
            maxx = @max(maxx, p.x1 + reach);
            maxy = @max(maxy, p.y1 + reach);
        }
        const gnx = (numeric.checkedInt(usize, @floor((maxx - minx) / cell)) orelse return null) + 1;
        const gny = (numeric.checkedInt(usize, @floor((maxy - miny) / cell)) orelse return null) + 1;
        const total = std.math.mul(usize, gnx, gny) catch return null;
        if (total > max_cells) return null; // too big — full scan is cheaper
        const lists = arena.alloc(std.ArrayList(u32), total) catch return null;
        for (lists) |*l| l.* = .empty;
        for (obs, 0..) |p, i| {
            const cx0 = cellFor(p.x0 - reach, minx, cell, gnx);
            const cx1 = cellFor(p.x1 + reach, minx, cell, gnx);
            const cy0 = cellFor(p.y0 - reach, miny, cell, gny);
            const cy1 = cellFor(p.y1 + reach, miny, cell, gny);
            var cy = cy0;
            while (cy <= cy1) : (cy += 1) {
                var cx = cx0;
                while (cx <= cx1) : (cx += 1) {
                    lists[cy * gnx + cx].append(arena, @intCast(i)) catch return null;
                }
            }
        }
        const frozen = arena.alloc([]const u32, total) catch return null;
        for (lists, 0..) |l, i| frozen[i] = l.items;
        const self = arena.create(PadGrid) catch return null;
        self.* = .{ .ox = minx, .oy = miny, .cell = cell, .nx = gnx, .ny = gny, .cells = frozen };
        return self;
    }
};

/// Candidate box indexes (tracks then vias, mirroring the copper index's build
/// order) whose expanded boxes may touch the segment a→b. The segment's bbox is
/// expanded by `reach` and every cell it covers is scanned: a box within
/// `reach` of the segment has its centre inside that expanded bbox, and the
/// cell containing the closest point carries the box (the point form of the
/// `padGridCoversFullScan` invariant). Returns null when the candidate count
/// overflows `scratch`, meaning "full-scan instead" (identical verdicts).
pub fn nearSegment(idx: *const PadGrid, a: [2]f64, b: [2]f64, reach: f64, scratch: *[near_scratch_len]u32) ?[]const u32 {
    var count: usize = 0;
    const x0 = @min(a[0], b[0]) - reach;
    const y0 = @min(a[1], b[1]) - reach;
    const x1 = @max(a[0], b[0]) + reach;
    const y1 = @max(a[1], b[1]) + reach;
    const cx0 = PadGrid.cellFor(x0, idx.ox, idx.cell, idx.nx);
    const cx1 = PadGrid.cellFor(x1, idx.ox, idx.cell, idx.nx);
    const cy0 = PadGrid.cellFor(y0, idx.oy, idx.cell, idx.ny);
    const cy1 = PadGrid.cellFor(y1, idx.oy, idx.cell, idx.ny);
    var cy = cy0;
    while (cy <= cy1) : (cy += 1) {
        var cx = cx0;
        while (cx <= cx1) : (cx += 1) {
            for (idx.cells[cy * idx.nx + cx]) |ci| {
                if (count >= near_scratch_len) return null;
                scratch[count] = ci;
                count += 1;
            }
        }
    }
    return scratch[0..count];
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Distance from a point to an axis-aligned rect (0 when inside) — the exact
/// test the full scan applies, so the coverage checks below can compare the
/// index's candidate set against the truth.
fn distPointRect(px: f64, py: f64, r: PadObs) f64 {
    const dx = @max(@max(r.x0 - px, px - r.x1), 0);
    const dy = @max(@max(r.y0 - py, py - r.y1), 0);
    return @sqrt(dx * dx + dy * dy);
}

/// Every box within `reach` of a lattice node must be among that node's
/// candidates; extra candidates are fine (the exact distance test rejects them).
fn padGridCoversFullScan(arena: std.mem.Allocator) bool {
    const g: f64 = 0.1;
    const nx: usize = 64;
    const ny: usize = 64;
    const bounds = Bounds{ .minx = 0, .miny = 0, .maxx = g * @as(f64, @floatFromInt(nx - 1)), .maxy = g * @as(f64, @floatFromInt(ny - 1)) };
    const reach: f64 = 0.25;
    const pads = [_]PadObs{
        .{ .x0 = 1.0, .y0 = 1.0, .x1 = 1.5, .y1 = 1.3, .net = 1 },
        .{ .x0 = 1.45, .y0 = 1.2, .x1 = 1.9, .y1 = 1.5, .net = 3 }, // clearance-overlaps pad 0
        .{ .x0 = 3.0, .y0 = 2.0, .x1 = 3.4, .y1 = 2.4, .net = 2 },
        .{ .x0 = 5.2, .y0 = 5.2, .x1 = 5.4, .y1 = 5.4, .net = 1 },
        .{ .x0 = 0.0, .y0 = 0.0, .x1 = 0.15, .y1 = 6.3, .net = 4 }, // long edge pad
    };
    const idx = PadGrid.build(arena, &pads, bounds, reach) orelse return true;
    var iy: usize = 0;
    while (iy < ny) : (iy += 1) {
        var ix: usize = 0;
        while (ix < nx) : (ix += 1) {
            const px = g * @as(f64, @floatFromInt(ix));
            const py = g * @as(f64, @floatFromInt(iy));
            const cand = idx.near(px, py);
            for (pads, 0..) |p, i| {
                if (distPointRect(px, py, p) >= reach) continue;
                var found = false;
                for (cand) |c| {
                    if (c == @as(u32, @intCast(i))) found = true;
                }
                if (!found) return false;
            }
        }
    }
    return true;
}

test "PadGrid index is result-identical to the full scan" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    try testing.expect(padGridCoversFullScan(arena_inst.allocator()));
}

/// Every box whose expanded box touches the segment must be a candidate;
/// extra candidates are fine (the exact distance test rejects them).
fn nearSegmentCoversFullScan(arena: std.mem.Allocator) bool {
    const bounds = Bounds{ .minx = 0, .miny = 0, .maxx = 12.7, .maxy = 12.7 };
    const reach: f64 = 0.3;
    const boxes = [_]PadObs{
        .{ .x0 = 2.0, .y0 = 2.0, .x1 = 2.4, .y1 = 2.2, .net = 1 },
        .{ .x0 = 3.0, .y0 = 1.0, .x1 = 3.2, .y1 = 1.4, .net = 2 }, // long-ish box
        .{ .x0 = 0.5, .y0 = 5.0, .x1 = 0.7, .y1 = 5.1, .net = 3 }, // off-segment
        .{ .x0 = 6.0, .y0 = 6.0, .x1 = 6.0, .y1 = 6.0, .net = 4 }, // via point box
    };
    const idx = PadGrid.build(arena, &boxes, bounds, reach) orelse return true;
    const seg_a = [2]f64{ 2.2, 1.8 };
    const seg_b = [2]f64{ 3.2, 1.8 };
    var scratch: [near_scratch_len]u32 = undefined;
    const cand = nearSegment(idx, seg_a, seg_b, reach, &scratch) orelse return true;
    for (boxes, 0..) |b, i| {
        const need = reach; // the probe's need is ≤ the insertion reach
        const bbox_overlap = @max(seg_a[0], seg_b[0]) >= @min(b.x0, b.x1) - need and
            @min(seg_a[0], seg_b[0]) <= @max(b.x0, b.x1) + need and
            @max(seg_a[1], seg_b[1]) >= @min(b.y0, b.y1) - need and
            @min(seg_a[1], seg_b[1]) <= @max(b.y0, b.y1) + need;
        if (!bbox_overlap) continue;
        var found = false;
        for (cand) |c| {
            if (c == @as(u32, @intCast(i))) found = true;
        }
        if (!found) return false;
    }
    return true;
}

// spec: placement/router - the copper index's nearSegment query is a superset of the full scan: every box within reach of the segment appears in the candidates
test "copper index nearSegment covers every box the full scan would test" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    try testing.expect(nearSegmentCoversFullScan(arena_inst.allocator()));
}
