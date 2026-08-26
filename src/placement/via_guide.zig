//! The via-fence GUIDE LINE — the closed curve a fence's vias are marched
//! around, drawn the way a copper pour draws its isolation boundary.
//!
//! A fence must clear the net's COPPER, not its centrelines. A trace is only the
//! thinnest part of a net: the 0402 pads it lands on are wider than it, and a
//! QFN's RF pad is wider still, so a row offset from the centreline alone marches
//! straight through them. What a fence actually wants is one curve sitting a
//! uniform distance outside everything the net is made of — exactly the shape a
//! ground pour's edge takes as it wraps an RF chain.
//!
//! So this module answers one question: given a net's copper as a `Union` of
//! capsules (tracks), discs (via barrels), pad shapes and swept path polygons,
//! where is the set of points exactly `dist` mm from that union's boundary?
//!
//!   1. **Field.** An exact distance field over the union's bounding box grown
//!      by `dist` + a border, sampled at grid NODES. Each primitive lowers only
//!      the nodes inside its own inflated bounding box (the pour's stamping
//!      idea), so cost scales with the copper's area rather than with primitive
//!      count times node count. Nodes no primitive reaches keep a `far` sentinel
//!      comfortably beyond `dist`, which is what guarantees the field's border
//!      ring reads as outside and therefore that every contour CLOSES.
//!   2. **Contours.** Marching squares on `distance − dist`, with the crossing
//!      point linearly interpolated along each cell edge. The field is
//!      1-Lipschitz and near-linear at that scale, so a 0.05 mm cell places the
//!      curve within a few microns of the true level set.
//!   3. **Outer only.** Every cell's cut is emitted DIRECTED with the inside
//!      (within `dist`) on its left, so a blob's outer boundary comes out
//!      counter-clockwise (positive shoelace area) and any interior hole comes
//!      out clockwise. Keeping the positive loops keeps the boundaries a fence
//!      belongs on: a via inside a moat would be a via inside the copper it is
//!      meant to shield.
//!
//! Two chains that a pad joins are ONE blob of the union, so they trace as one
//! contour — the merge a per-chain construction could only approximate by
//! deduplicating the sites afterwards.

const std = @import("std");
const pad_shape = @import("pad_shape.zig");
const numeric = @import("../numeric.zig");

/// A track segment of a net's copper as a capsule: the centreline endpoints plus
/// the half width its copper extends either side of them.
pub const Capsule = struct { x1: f64, y1: f64, x2: f64, y2: f64, half: f64 };

/// A round copper feature of a net's copper (a via barrel) as centre + radius.
pub const Disc = struct { x: f64, y: f64, r: f64 };

/// One net's copper — the union a guide contour wraps. All three kinds are
/// optional: a net may be pure trace, or trace plus the pads it lands on, or carry
/// a layer-changing barrel as well. Which LAYERS the copper came from is the
/// caller's business: this module works in the plane, so a caller fencing with
/// through vias hands it every layer at once.
pub const Union = struct {
    caps: []const Capsule = &.{},
    discs: []const Disc = &.{},
    pads: []const pad_shape.Shape = &.{},
    /// Exact filled regions for variable-width paths. Multiple overlapping
    /// polygons are one copper union, just like overlapping track capsules.
    polys: []const []const [2]f64 = &.{},

    /// True when there is no copper here at all, so there is nothing to wrap.
    pub fn isEmpty(self: Union) bool {
        return self.caps.len == 0 and self.discs.len == 0 and self.pads.len == 0 and self.polys.len == 0;
    }
};

/// One closed guide contour: ordered world-mm vertices with the first NOT
/// repeated at the end, so a consumer closes it however it prefers.
pub const Contour = []const [2]f64;

/// Default distance-field cell (mm). Two orders of magnitude under a fence via
/// diameter and well under the tightest edge gap, so the traced curve is smooth
/// at the scale a via is placed; the interpolation error on a near-linear
/// distance field goes as the square of this, i.e. single-digit microns.
pub const default_cell_mm: f64 = 0.05;

/// Node ceiling for one net's field. A field is allocated per fenced net, so this
/// bounds the transient allocation of a whole fence run at a few tens of megabytes;
/// a net whose copper spans more board than that gets a coarser cell (reported as
/// `Guide.coarsened`) rather than a failed trace.
pub const max_nodes: usize = 8 << 20;

/// Border width, in cells, between the `dist`-grown copper bounds and the edge
/// of the field. Three cells keeps the whole border ring beyond every
/// primitive's stamping window, so those nodes hold the `far` sentinel and no
/// contour can run off the field and fail to close.
const border_cells: f64 = 3;

/// What one net's copper traced to: its outer guide contours plus the cell the
/// field actually used, which is `default_cell_mm` unless `coarsened`.
pub const Guide = struct {
    contours: []const Contour,
    cell_mm: f64,
    coarsened: bool = false,
};

/// The exact-distance field: `v[j*nx + i]` is the distance (mm) from node
/// (`minx` + i·cell, `miny` + j·cell) to the union's copper, or the `far`
/// sentinel where no primitive reached. Values inside copper are ≤ 0.
const Field = struct {
    minx: f64,
    miny: f64,
    cell: f64,
    nx: usize,
    ny: usize,
    v: []f64,

    /// World x of node column `i`.
    fn xAt(self: Field, i: usize) f64 {
        return self.minx + @as(f64, @floatFromInt(i)) * self.cell;
    }

    /// World y of node row `j`.
    fn yAt(self: Field, j: usize) f64 {
        return self.miny + @as(f64, @floatFromInt(j)) * self.cell;
    }

    /// Distance value at node (i,j).
    fn at(self: Field, i: usize, j: usize) f64 {
        return self.v[j * self.nx + i];
    }

    /// Lower node (i,j) to `d` when `d` is nearer than what is recorded.
    fn lower(self: Field, i: usize, j: usize, d: f64) void {
        const k = j * self.nx + i;
        self.v[k] = @min(self.v[k], d);
    }
};

/// The node index range [i0,i1] × [j0,j1] covering a world box.
const Window = struct { i0: usize, i1: usize, j0: usize, j1: usize };

/// Node window covering the world box (x0,y0)–(x1,y1), clamped to the field, or
/// null when the box misses the field entirely. In a well-formed field every
/// primitive's window is interior, so the null is a guard rather than a case.
fn windowOf(f: Field, x0: f64, y0: f64, x1: f64, y1: f64) ?Window {
    if (x1 < f.minx or y1 < f.miny) return null;
    if (x0 > f.xAt(f.nx - 1) or y0 > f.yAt(f.ny - 1)) return null;
    return .{
        .i0 = nodeAt(f, x0 - f.minx, f.nx),
        .i1 = nodeAt(f, x1 - f.minx + f.cell, f.nx),
        .j0 = nodeAt(f, y0 - f.miny, f.ny),
        .j1 = nodeAt(f, y1 - f.miny + f.cell, f.ny),
    };
}

/// The node index `span` mm from the field's origin, floored into [0, count−1].
fn nodeAt(f: Field, span: f64, count: usize) usize {
    return @min(numeric.toCount(@floor(@max(span, 0) / f.cell)), count - 1);
}

/// World bounding box (x0,y0,x1,y1) of everything in `u`, or null when empty.
fn unionBounds(u: Union) ?[4]f64 {
    var b = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (u.caps) |c| {
        grow(&b, @min(c.x1, c.x2) - c.half, @min(c.y1, c.y2) - c.half);
        grow(&b, @max(c.x1, c.x2) + c.half, @max(c.y1, c.y2) + c.half);
    }
    for (u.discs) |d| {
        grow(&b, d.x - d.r, d.y - d.r);
        grow(&b, d.x + d.r, d.y + d.r);
    }
    for (u.pads) |p| {
        grow(&b, p.x0, p.y0);
        grow(&b, p.x1, p.y1);
    }
    for (u.polys) |poly| for (poly) |p| grow(&b, p[0], p[1]);
    if (!std.math.isFinite(b[0])) return null;
    return b;
}

/// Grow bounding box `b` to include (x,y).
fn grow(b: *[4]f64, x: f64, y: f64) void {
    b[0] = @min(b[0], x);
    b[1] = @min(b[1], y);
    b[2] = @max(b[2], x);
    b[3] = @max(b[3], y);
}

/// Node count spanning `extent` mm at `cell`, with both end nodes included.
fn nodeCount(extent: f64, cell: f64) usize {
    return numeric.toCount(@ceil(extent / cell)) + 2;
}

/// Build the exact distance field around `u` for a contour at `dist`, at `cell`
/// or the coarser cell `max_nodes` allows. Null when `u` has no copper.
fn buildField(arena: std.mem.Allocator, u: Union, dist: f64, cell: f64) std.mem.Allocator.Error!?Field {
    const b = unionBounds(u) orelse return null;
    var use = cell;
    var nx = nodeCount(b[2] - b[0] + 2 * (dist + border_cells * use), use);
    var ny = nodeCount(b[3] - b[1] + 2 * (dist + border_cells * use), use);
    if (nx * ny > max_nodes) {
        const over = @as(f64, @floatFromInt(nx)) * @as(f64, @floatFromInt(ny)) /
            @as(f64, @floatFromInt(max_nodes));
        use = cell * @sqrt(over);
        nx = nodeCount(b[2] - b[0] + 2 * (dist + border_cells * use), use);
        ny = nodeCount(b[3] - b[1] + 2 * (dist + border_cells * use), use);
    }
    const margin = dist + border_cells * use;
    const far = dist + border_cells * use;
    const f = Field{
        .minx = b[0] - margin,
        .miny = b[1] - margin,
        .cell = use,
        .nx = nx,
        .ny = ny,
        .v = try arena.alloc(f64, nx * ny),
    };
    @memset(f.v, far);
    stampAll(f, u, dist);
    return f;
}

/// Lower the field around every primitive of `u`. The stamping window is the
/// primitive's bounding box grown by `dist` + two cells: a node outside it is
/// certainly farther than `dist` from that primitive, and a node whose value
/// matters to the interpolation near the level set is certainly inside it.
fn stampAll(f: Field, u: Union, dist: f64) void {
    const reach = dist + 2 * f.cell;
    for (u.caps) |c| stampCapsule(f, c, reach);
    for (u.discs) |d| stampDisc(f, d, reach);
    for (u.pads) |p| stampPad(f, p, reach);
    for (u.polys) |poly| stampPolygon(f, poly, reach);
}

/// Lower the field around one track capsule.
fn stampCapsule(f: Field, c: Capsule, reach: f64) void {
    const grown = c.half + reach;
    const w = windowOf(
        f,
        @min(c.x1, c.x2) - grown,
        @min(c.y1, c.y2) - grown,
        @max(c.x1, c.x2) + grown,
        @max(c.y1, c.y2) + grown,
    ) orelse return;
    var j = w.j0;
    while (j <= w.j1) : (j += 1) {
        const y = f.yAt(j);
        var i = w.i0;
        while (i <= w.i1) : (i += 1) {
            f.lower(i, j, pad_shape.segPointDist(c.x1, c.y1, c.x2, c.y2, f.xAt(i), y) - c.half);
        }
    }
}

/// Lower the field around one via barrel.
fn stampDisc(f: Field, d: Disc, reach: f64) void {
    const grown = d.r + reach;
    const w = windowOf(f, d.x - grown, d.y - grown, d.x + grown, d.y + grown) orelse return;
    var j = w.j0;
    while (j <= w.j1) : (j += 1) {
        const y = f.yAt(j);
        var i = w.i0;
        while (i <= w.i1) : (i += 1) {
            f.lower(i, j, std.math.hypot(f.xAt(i) - d.x, y - d.y) - d.r);
        }
    }
}

/// Lower the field around one pad's copper. `pointDist` is asked for the EXACT
/// outline distance (a slack past the window) rather than the bounding-box
/// distance, so a roundrect's corner and a thermal pad's notch shape the guide
/// the way they shape a pour, instead of over-stating the pad as its box.
fn stampPad(f: Field, s: pad_shape.Shape, reach: f64) void {
    const w = windowOf(f, s.x0 - reach, s.y0 - reach, s.x1 + reach, s.y1 + reach) orelse return;
    var j = w.j0;
    while (j <= w.j1) : (j += 1) {
        const y = f.yAt(j);
        var i = w.i0;
        while (i <= w.i1) : (i += 1) {
            f.lower(i, j, pad_shape.pointDist(s.x0, s.y0, s.x1, s.y1, s.poly, f.xAt(i), y, reach + f.cell));
        }
    }
}

/// Lower the field around an exact filled polygon. `pointDist` returns zero
/// inside the polygon and the true edge distance outside, which is precisely
/// the unsigned union field needed for a positive-distance guide contour.
fn stampPolygon(f: Field, poly: []const [2]f64, reach: f64) void {
    if (poly.len < 3) return;
    var x0 = poly[0][0];
    var y0 = poly[0][1];
    var x1 = x0;
    var y1 = y0;
    for (poly[1..]) |p| {
        x0 = @min(x0, p[0]);
        y0 = @min(y0, p[1]);
        x1 = @max(x1, p[0]);
        y1 = @max(y1, p[1]);
    }
    const w = windowOf(f, x0 - reach, y0 - reach, x1 + reach, y1 + reach) orelse return;
    var j = w.j0;
    while (j <= w.j1) : (j += 1) {
        const y = f.yAt(j);
        var i = w.i0;
        while (i <= w.i1) : (i += 1) {
            f.lower(i, j, pad_shape.pointDist(x0, y0, x1, y1, poly, f.xAt(i), y, reach + f.cell));
        }
    }
}

// ── Marching squares ────────────────────────────────────────────────────────
//
// Cell (i,j) has corners c0=(i,j), c1=(i+1,j), c2=(i+1,j+1), c3=(i,j+1) and
// edges e0 = c0–c1, e1 = c1–c2, e2 = c2–c3, e3 = c3–c0. A corner is INSIDE when
// its distance is under `dist`; the case index is the four inside bits. Each cut
// is directed so that the inside lies on its LEFT — with "left" the rotation
// (x,y) → (−y,x) — which is what makes an outer boundary come out with positive
// shoelace area and an interior hole negative.

/// Which side of an ambiguous (diagonal) case the cell's centre falls on: the
/// bilinear average of the four corners decides whether the two same-signed
/// corners join or stay apart.
const Center = enum { inside, outside };

/// A directed cut across one cell, from the crossing on edge `from` to the
/// crossing on edge `to`.
const Cut = struct { from: u2, to: u2 };

/// The cuts case `code` puts in a cell (up to two, for the diagonal cases).
const CellCut = struct { a: ?Cut = null, b: ?Cut = null };

/// The directed cuts for marching-squares case `code`, inside on the left.
fn cellCut(code: u4, center: Center) CellCut {
    return switch (code) {
        0, 15 => .{},
        1 => .{ .a = .{ .from = 0, .to = 3 } },
        2 => .{ .a = .{ .from = 1, .to = 0 } },
        3 => .{ .a = .{ .from = 1, .to = 3 } },
        4 => .{ .a = .{ .from = 2, .to = 1 } },
        5 => if (center == .inside)
            .{ .a = .{ .from = 0, .to = 1 }, .b = .{ .from = 2, .to = 3 } }
        else
            .{ .a = .{ .from = 0, .to = 3 }, .b = .{ .from = 2, .to = 1 } },
        6 => .{ .a = .{ .from = 2, .to = 0 } },
        7 => .{ .a = .{ .from = 2, .to = 3 } },
        8 => .{ .a = .{ .from = 3, .to = 2 } },
        9 => .{ .a = .{ .from = 0, .to = 2 } },
        10 => if (center == .inside)
            .{ .a = .{ .from = 3, .to = 0 }, .b = .{ .from = 1, .to = 2 } }
        else
            .{ .a = .{ .from = 1, .to = 0 }, .b = .{ .from = 3, .to = 2 } },
        11 => .{ .a = .{ .from = 1, .to = 2 } },
        12 => .{ .a = .{ .from = 3, .to = 1 } },
        13 => .{ .a = .{ .from = 0, .to = 1 } },
        14 => .{ .a = .{ .from = 3, .to = 0 } },
    };
}

/// A directed cut recorded by grid-edge id, so two cells sharing an edge share
/// the exact same endpoint and the loops stitch without a tolerance.
const Link = struct { tail: u32, head: u32 };

/// Grid-edge identity. Horizontal edge (i,j) — the one between nodes (i,j) and
/// (i+1,j) — is `j*(nx-1) + i`; vertical edge (i,j) — between (i,j) and (i,j+1)
/// — follows all the horizontal ones at `horiz + j*nx + i`.
const Edges = struct {
    nx: usize,
    horiz: usize,

    /// The id of the horizontal edge below node row `j`, at column `i`.
    fn h(self: Edges, i: usize, j: usize) u32 {
        return @intCast(j * (self.nx - 1) + i);
    }

    /// The id of the vertical edge right of node column `i`, at row `j`.
    fn v(self: Edges, i: usize, j: usize) u32 {
        return @intCast(self.horiz + j * self.nx + i);
    }

    /// The id of cell (i,j)'s local edge `e` (0 = bottom, 1 = right, 2 = top,
    /// 3 = left).
    fn of(self: Edges, i: usize, j: usize, e: u2) u32 {
        return switch (e) {
            0 => self.h(i, j),
            1 => self.v(i + 1, j),
            2 => self.h(i, j + 1),
            3 => self.v(i, j),
        };
    }
};

/// The edge index scheme for field `f`.
fn edgesOf(f: Field) Edges {
    return .{ .nx = f.nx, .horiz = (f.nx - 1) * f.ny };
}

/// The world point where the level set crosses grid edge `id`: the linear
/// interpolation of the two node distances against `dist`.
fn edgePoint(f: Field, e: Edges, dist: f64, id: u32) [2]f64 {
    if (id < e.horiz) {
        const j = id / (f.nx - 1);
        const i = id % (f.nx - 1);
        const t = lerpT(f.at(i, j) - dist, f.at(i + 1, j) - dist);
        return .{ f.xAt(i) + t * f.cell, f.yAt(j) };
    }
    const k = id - e.horiz;
    const j = k / f.nx;
    const i = k % f.nx;
    const t = lerpT(f.at(i, j) - dist, f.at(i, j + 1) - dist);
    return .{ f.xAt(i), f.yAt(j) + t * f.cell };
}

/// Where along an edge the zero of a sign change from `a` to `b` sits, clamped
/// to the edge so a degenerate pair still yields a point on it.
fn lerpT(a: f64, b: f64) f64 {
    const span = a - b;
    if (@abs(span) < 1e-300) return 0.5;
    return std.math.clamp(a / span, 0, 1);
}

/// The four-bit inside code of cell (i,j) — bit k set when corner k is within
/// `dist` of the copper.
fn cellCode(f: Field, i: usize, j: usize, dist: f64) u4 {
    var code: u4 = 0;
    if (f.at(i, j) < dist) code |= 1;
    if (f.at(i + 1, j) < dist) code |= 2;
    if (f.at(i + 1, j + 1) < dist) code |= 4;
    if (f.at(i, j + 1) < dist) code |= 8;
    return code;
}

/// Which side of `dist` the bilinear centre of cell (i,j) falls on.
fn cellCenter(f: Field, i: usize, j: usize, dist: f64) Center {
    const avg = (f.at(i, j) + f.at(i + 1, j) + f.at(i + 1, j + 1) + f.at(i, j + 1)) / 4;
    return if (avg < dist) .inside else .outside;
}

/// Every directed cut the field's cells produce, in scan order.
fn collectLinks(
    arena: std.mem.Allocator,
    f: Field,
    dist: f64,
) std.mem.Allocator.Error![]const Link {
    const e = edgesOf(f);
    var out: std.ArrayList(Link) = .empty;
    var j: usize = 0;
    while (j + 1 < f.ny) : (j += 1) {
        var i: usize = 0;
        while (i + 1 < f.nx) : (i += 1) {
            const cut = cellCut(cellCode(f, i, j, dist), cellCenter(f, i, j, dist));
            if (cut.a) |c| try out.append(arena, .{ .tail = e.of(i, j, c.from), .head = e.of(i, j, c.to) });
            if (cut.b) |c| try out.append(arena, .{ .tail = e.of(i, j, c.from), .head = e.of(i, j, c.to) });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Shoelace area of a closed loop, positive when the loop runs counter-clockwise
/// in the field's own coordinate orientation — the sign that says OUTER boundary,
/// because the cuts were emitted with the inside on their left.
fn signedArea(pts: []const [2]f64) f64 {
    var sum: f64 = 0;
    var k: usize = pts.len - 1;
    for (pts, 0..) |p, i| {
        sum += pts[k][0] * p[1] - p[0] * pts[k][1];
        k = i;
    }
    return sum / 2;
}

/// Fewest vertices a kept contour may have: below a triangle there is no
/// enclosed area to march around.
const min_contour_pts: usize = 3;

/// Stitch the directed cuts into closed loops and keep the outer ones. Each grid
/// edge carries at most one crossing, so a cut's head names exactly the cut that
/// continues it and the walk needs no geometric tolerance.
fn stitchOuter(
    arena: std.mem.Allocator,
    f: Field,
    dist: f64,
    links: []const Link,
) std.mem.Allocator.Error![]const Contour {
    const e = edgesOf(f);
    var by_tail: std.AutoHashMapUnmanaged(u32, u32) = .empty;
    for (links, 0..) |l, i| try by_tail.put(arena, l.tail, @intCast(i));
    const seen = try arena.alloc(bool, links.len);
    @memset(seen, false);

    var out: std.ArrayList(Contour) = .empty;
    for (links, 0..) |_, start| {
        if (seen[start]) continue;
        var pts: std.ArrayList([2]f64) = .empty;
        var cur: usize = start;
        var closed = false;
        while (true) {
            seen[cur] = true;
            try pts.append(arena, edgePoint(f, e, dist, links[cur].tail));
            const next = by_tail.get(links[cur].head) orelse break;
            closed = next == start;
            if (closed or seen[next]) break;
            cur = next;
        }
        if (!closed or pts.items.len < min_contour_pts) continue;
        if (signedArea(pts.items) <= 0) continue;
        try out.append(arena, try pts.toOwnedSlice(arena));
    }
    return out.toOwnedSlice(arena);
}

/// The outer guide contours of `u` at `dist` mm from its copper — the whole
/// point of this module. An empty union, or one whose level set somehow encloses
/// nothing, yields no contours rather than an error.
pub fn trace(arena: std.mem.Allocator, u: Union, dist: f64) std.mem.Allocator.Error!Guide {
    const built = try buildField(arena, u, dist, default_cell_mm);
    const f = built orelse return .{ .contours = &.{}, .cell_mm = default_cell_mm };
    const links = try collectLinks(arena, f, dist);
    return .{
        .contours = try stitchOuter(arena, f, dist, links),
        .cell_mm = f.cell,
        .coarsened = f.cell > default_cell_mm,
    };
}

/// Perimeter (mm) of a closed contour, the wrap included.
pub fn perimeter(c: Contour) f64 {
    if (c.len < 2) return 0;
    var sum = std.math.hypot(c[0][0] - c[c.len - 1][0], c[0][1] - c[c.len - 1][1]);
    for (c[1..], 0..) |p, i| sum += std.math.hypot(p[0] - c[i][0], p[1] - c[i][1]);
    return sum;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The {min, max} distance from `pts` to the capsule `c` — how a test asks
/// whether a whole contour really sits at one distance from the copper.
fn capsuleRange(pts: []const [2]f64, c: Capsule) [2]f64 {
    var r = [2]f64{ std.math.inf(f64), 0 };
    for (pts) |p| {
        const d = pad_shape.segPointDist(c.x1, c.y1, c.x2, c.y2, p[0], p[1]) - c.half;
        r[0] = @min(r[0], d);
        r[1] = @max(r[1], d);
    }
    return r;
}

/// How far above `y0` (mm) the highest vertex of `c` reaches — how a test asks
/// how far the guide had to bulge out around a pad.
fn topAbove(c: Contour, y0: f64) f64 {
    var top: f64 = 0;
    for (c) |p| top = @max(top, p[1] - y0);
    return top;
}

/// A square pad `w` mm wide centred at (x,y), as a `pad_shape.Shape`.
fn squarePad(x: f64, y: f64, w: f64) pad_shape.Shape {
    return .{ .x0 = x - w / 2, .y0 = y - w / 2, .x1 = x + w / 2, .y1 = y + w / 2 };
}

// spec: placement/via-fence - the guide contour is the level set at one distance from the net's copper, so a straight trace traces a racetrack that distance from its edge
test "a lone trace traces one contour at a constant distance from its copper edge" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const cap = Capsule{ .x1 = 10, .y1 = 10, .x2 = 20, .y2 = 10, .half = 0.15 };
    const g = try trace(arena, .{ .caps = &.{cap} }, 0.4);
    try testing.expectEqual(@as(usize, 1), g.contours.len);
    try testing.expect(!g.coarsened);
    try testing.expectEqual(default_cell_mm, g.cell_mm);

    // Every vertex sits 0.4 mm from the capsule's EDGE — flanks and end caps
    // alike, since a level set has no separate cases to get wrong.
    const r = capsuleRange(g.contours[0], cap);
    try testing.expectApproxEqAbs(@as(f64, 0.4), r[0], 0.01);
    try testing.expectApproxEqAbs(@as(f64, 0.4), r[1], 0.01);
    // …which makes the perimeter the racetrack's: two 10 mm flanks plus a full
    // circle of radius 0.4 + the trace's own half width.
    const want = 20 + 2 * std.math.pi * 0.55;
    try testing.expectApproxEqAbs(want, perimeter(g.contours[0]), want * 0.01);
}

// spec: placement/via-fence - a pad wider than the trace bulges the guide contour out around the pad's own edge at the same distance, so no site lands inside the pad
test "the guide follows a wide pad's edge at the same distance as the trace's" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A 0.3 mm trace running into a 0.6 mm square pad — four times as wide as
    // the trace's own half width.
    const cap = Capsule{ .x1 = 10, .y1 = 10, .x2 = 15, .y2 = 10, .half = 0.15 };
    const pad = squarePad(15, 10, 0.6);
    const g = try trace(arena, .{ .caps = &.{cap}, .pads = &.{pad} }, 0.4);
    try testing.expectEqual(@as(usize, 1), g.contours.len);

    for (g.contours[0]) |p| {
        const to_trace = pad_shape.segPointDist(cap.x1, cap.y1, cap.x2, cap.y2, p[0], p[1]) - cap.half;
        const to_pad = pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, p[0], p[1], 9);
        // Nothing is inside the pad, and nothing is nearer than the gap to
        // EITHER piece of copper — the guide clears the pad's edge, not the
        // centreline that runs through it.
        try testing.expect(to_pad > 0.4 - 0.01);
        try testing.expect(@min(to_trace, to_pad) > 0.4 - 0.01);
        // …and the near side of the curve hugs one of them: a level set never
        // wanders off.
        try testing.expect(@min(to_trace, to_pad) < 0.4 + 0.02);
    }
    // The contour has to bulge past the pad, which reaches 0.3 mm further out
    // than the trace's 0.15 mm flank.
    try testing.expectApproxEqAbs(@as(f64, 0.7), topAbove(g.contours[0], 10), 0.02);
}

// spec: placement/via-fence - a guide around a variable-width path follows the swept polygon's sloped copper edge instead of its compact constant-width edit handle
test "the guide follows a tapered polygon from its wide flank to its narrow flank" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const taper = [_][2]f64{ .{ 10, 11 }, .{ 20, 10.1 }, .{ 20, 9.9 }, .{ 10, 9 } };
    const g = try trace(arena, .{ .polys = &.{&taper} }, 0.4);
    try testing.expectEqual(@as(usize, 1), g.contours.len);

    var broad: f64 = 0;
    var narrow: f64 = 0;
    for (g.contours[0]) |p| {
        const offset = @abs(p[1] - 10);
        if (p[0] > 11 and p[0] < 13) broad = @max(broad, offset);
        if (p[0] > 17 and p[0] < 19) narrow = @max(narrow, offset);
    }
    try testing.expect(broad > 1.1);
    try testing.expect(narrow > 0.45);
    try testing.expect(narrow < 0.8);
    try testing.expect(broad > narrow + 0.5);
}

// spec: placement/via-fence - copper the net shares merges into one guide contour, so two chains joined by a pad are wrapped once instead of ringed separately
test "two chains joined by a pad trace as a single merged contour" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two collinear runs stopping 1.7 mm apart — more than twice the 0.4 mm level,
    // so their level sets do NOT touch on their own — and the pad that bridges
    // them. The union is one blob, so the level set is one loop.
    const left = Capsule{ .x1 = 8, .y1 = 10, .x2 = 9.5, .y2 = 10, .half = 0.15 };
    const right = Capsule{ .x1 = 11.5, .y1 = 10, .x2 = 13, .y2 = 10, .half = 0.15 };
    const pad = squarePad(10.5, 10, 1.8);
    const joined = try trace(arena, .{ .caps = &.{ left, right }, .pads = &.{pad} }, 0.4);
    try testing.expectEqual(@as(usize, 1), joined.contours.len);
    // That one loop wraps the whole chain end to end.
    var box = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (joined.contours[0]) |p| grow(&box, p[0], p[1]);
    try testing.expectApproxEqAbs(@as(f64, 7.45), box[0], 0.02);
    try testing.expectApproxEqAbs(@as(f64, 13.55), box[2], 0.02);
    // …and it bulges to the pad's own edge plus the level, not to the trace's.
    try testing.expectApproxEqAbs(@as(f64, 1.3), topAbove(joined.contours[0], 10), 0.02);

    // Take the pad away and the same two runs are two separate blobs — which is
    // what proves the merge above came from the shared copper, not from the tracer
    // collapsing everything it sees.
    const split = try trace(arena, .{ .caps = &.{ left, right } }, 0.4);
    try testing.expectEqual(@as(usize, 2), split.contours.len);
    try testing.expect(perimeter(split.contours[0]) < perimeter(joined.contours[0]));
}

// spec: placement/via-fence - only the outer boundaries of a net's copper union are traced, so an enclosed interior gap is never marched with vias
test "an interior hole in the copper union is not traced as a contour" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A closed 4 mm square ring of trace. Its inside is a hole in the union's
    // "within 0.4 mm" region, so the level set there is a second, CLOCKWISE
    // loop — the moat a via must never be dropped into.
    const ring = [_]Capsule{
        .{ .x1 = 10, .y1 = 10, .x2 = 14, .y2 = 10, .half = 0.15 },
        .{ .x1 = 14, .y1 = 10, .x2 = 14, .y2 = 14, .half = 0.15 },
        .{ .x1 = 14, .y1 = 14, .x2 = 10, .y2 = 14, .half = 0.15 },
        .{ .x1 = 10, .y1 = 14, .x2 = 10, .y2 = 10, .half = 0.15 },
    };
    const g = try trace(arena, .{ .caps = &ring }, 0.4);
    // One contour only, and it is the OUTER one: it reaches beyond the ring.
    try testing.expectEqual(@as(usize, 1), g.contours.len);
    var box = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (g.contours[0]) |p| grow(&box, p[0], p[1]);
    try testing.expectApproxEqAbs(@as(f64, 9.45), box[0], 0.02);
    try testing.expectApproxEqAbs(@as(f64, 14.55), box[2], 0.02);
    // Its own signed area is positive — the winding rule that made the hole drop
    // out is a property of the kept loop, not an accident of ordering.
    try testing.expect(signedArea(g.contours[0]) > 0);
}

// spec: placement/via-fence - a via barrel is copper of the union too, so a net whose only copper is a barrel still traces a circle around it
test "a via barrel is wrapped like any other copper and an empty union traces nothing" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const g = try trace(arena, .{ .discs = &.{.{ .x = 5, .y = 5, .r = 0.2 }} }, 0.4);
    try testing.expectEqual(@as(usize, 1), g.contours.len);
    for (g.contours[0]) |p| {
        try testing.expectApproxEqAbs(@as(f64, 0.6), std.math.hypot(p[0] - 5, p[1] - 5), 0.01);
    }
    const circle = 2 * std.math.pi * 0.6;
    try testing.expectApproxEqAbs(circle, perimeter(g.contours[0]), circle * 0.01);

    // Nothing in, nothing out — and the empty union says so before allocating a
    // field for it.
    const empty = Union{};
    try testing.expect(empty.isEmpty());
    const none = try trace(arena, empty, 0.4);
    try testing.expectEqual(@as(usize, 0), none.contours.len);
    try testing.expectEqual(@as(f64, 0), perimeter(&.{}));
}
