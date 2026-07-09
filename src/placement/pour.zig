//! Real copper-pour engine — a single COMPUTED fill shared by every consumer
//! (Gerber export, fab-readiness connectivity, the viewer), replacing the old
//! analytic "outline pullback minus per-hole antipads" that each consumer
//! recomputed independently and that assumed connectivity it never verified.
//!
//! `compute` rasterizes one poured/plane layer at a fine pitch: it starts from
//! the board outline inset by the copper-to-edge clearance (respecting a
//! non-rectangular `board_poly`), carves every FOREIGN copper feature (a pad,
//! track, or via whose net the plane does NOT carry) with the pour clearance,
//! then connected-component labels the surviving cells and keeps ONLY the
//! components that contain a same-net SEED (a same-net pad or via landing on
//! that layer). The result answers two questions honestly:
//!
//!   * membership — `componentAt(x,y)` / `planeConnect` say which kept
//!     component (if any) a point/pad lands in, so a pad isolated by its
//!     antipad ring, a plane split by a foreign trace, or an orphan island are
//!     all VISIBLE (the fab-readiness short-circuit is gone), and
//!   * shape — `Fill.contours` are the kept components' outer boundary polygons
//!     (marching-squares edge tracing + Douglas-Peucker), so the Gerber emits
//!     real copper (islands dropped) and the viewer paints the true extent.
//!
//! The engine is a pure function of `(placement, copper, layer)` — no server,
//! no disk — so it is unit-testable and shares the export's frame/net model.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const pad_shape = @import("pad_shape.zig");
const router = @import("router.zig");
const outline = @import("outline.zig");

/// Which net a poured/plane layer carries: a declared `(plane IDX "NET")` name,
/// or the legacy implicit model's "every ground-named net".
pub const PlaneNet = union(enum) { named: []const u8, ground };

/// Identity of one poured copper layer for the fill. `side` non-null marks an
/// OUTER copper face (its side's SMD pads are present, and foreign tracks on
/// `track_layer` are carved); null marks an INNER plane (only drilled barrels
/// and vias interact — SMD pads and signal tracks live on other layers).
pub const LayerSpec = struct {
    net: PlaneNet,
    side: ?optimizer.Side = null,
    track_layer: ?u8 = null,
};

/// One kept component's outer boundary, a closed polygon in world mm.
const Contour = []const [2]f64;

/// Upper bound on grid cells before `compute` coarsens the pitch (and flags
/// `coarsened`). A 100×100 mm board at the 0.15 mm default pitch is ~445 k
/// cells; the cap leaves generous headroom while bounding a pathological board.
const MAX_CELLS: usize = 3_000_000;

const BLOCKED: i32 = -2;
const UNLABELED: i32 = -1;

/// The computed fill for one layer: the label grid (for point/pad membership)
/// plus the kept components' outer contours (for emission).
pub const Fill = struct {
    minx: f64,
    miny: f64,
    pitch: f64,
    nx: usize,
    ny: usize,
    /// Per cell: a kept-component index (0..n_comp) or -1 (blocked / unseeded).
    labels: []const i32,
    n_comp: usize,
    contours: []const Contour,
    /// The pitch was coarsened to stay under `MAX_CELLS` — a surfaced warning
    /// (the fill is lower-resolution than the design's clearance would want).
    coarsened: bool,

    /// The kept-component index covering world point (x,y), or -1 when the
    /// point is blocked, in an unseeded region, or off the grid.
    fn componentAt(self: Fill, x: f64, y: f64) i32 {
        if (self.pitch <= 0) return -1;
        const fi = @floor((x - self.minx) / self.pitch);
        const fj = @floor((y - self.miny) / self.pitch);
        if (fi < 0 or fj < 0) return -1;
        const i: usize = @intFromFloat(fi);
        const j: usize = @intFromFloat(fj);
        if (i >= self.nx or j >= self.ny) return -1;
        return self.labels[j * self.nx + i];
    }

    /// The kept component a pad lands in: its centre, else any sampled point of
    /// its bounding box (a pad whose centre grazes the edge keep-out can still
    /// have copper reaching the pour). -1 when it touches no kept component.
    fn padComponent(self: Fill, cx: f64, cy: f64, x0: f64, y0: f64, x1: f64, y1: f64) i32 {
        const c = self.componentAt(cx, cy);
        if (c >= 0) return c;
        const xs = [_]f64{ x0, x1, cx };
        const ys = [_]f64{ y0, y1, cy };
        for (xs) |sx| for (ys) |sy| {
            const s = self.componentAt(sx, sy);
            if (s >= 0) return s;
        };
        return -1;
    }
};

/// A pad reduced to what membership needs: its world box + centre, whether it
/// is a through-hole (present on every copper layer) and which side it sits on.
pub const PadQuery = struct {
    cx: f64,
    cy: f64,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    thru: bool,
    side: optimizer.Side,
};

/// The plane-connectivity answer for one net across all the layers that pour
/// it: each query pad/via's CANONICAL kept-component id (or -1 = isolated),
/// with ids unified across layers by through-hole pads and vias (so a net
/// poured on both an inner plane and an outer face reads as one piece).
pub const Join = struct {
    pad_comp: []const i32,
    via_comp: []const i32,
    n_comp: usize,
    coarsened: bool,
};

/// Does a plane carrying `net` carry the feature-net `name`? Named planes match
/// the full flattened name or its `/`-leaf; the implicit model carries every
/// ground-named net. Unconnected ("") is never carried.
fn planeCarries(net: PlaneNet, name: []const u8) bool {
    if (name.len == 0) return false;
    if (net == .ground) return optimizer.isGroundName(leafName(name));
    return std.ascii.eqlIgnoreCase(net.named, name) or std.ascii.eqlIgnoreCase(net.named, leafName(name));
}

/// The net name's leaf after the last `/` (sub-block flatten prefix).
fn leafName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// The outline rectangle the fill rasterizes over: the authored/drawn
/// `board_rect`, else the parts' bounding box (matching `export_fab.outlineRect`
/// so the pour aligns with the edge layer). Replicated here to avoid an import
/// cycle through `export_fab`/`export_gerber`.
fn boundsRect(placement: optimizer.Placement) optimizer.BoardRect {
    if (placement.board_rect) |r| return r;
    return .{
        .minx = placement.minx - 1.0,
        .miny = placement.miny - 1.0,
        .w = (placement.maxx - placement.minx) + 2.0,
        .h = (placement.maxy - placement.miny) + 2.0,
    };
}

// ── Fill computation ─────────────────────────────────────────────────────────

/// Compute the poured fill for `spec` over `placement` + `copper`. All output
/// is arena-owned. An empty/degenerate outline yields an empty fill.
pub fn compute(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    spec: LayerSpec,
) std.mem.Allocator.Error!Fill {
    const r = boundsRect(placement);
    const rules = placement.rules;
    const pc = rules.design.pour_clearance;
    const inset = rules.design.pourEdge();

    var pitch = @max(0.05, pc / 2.0);
    var coarsened = false;
    var nx = gridCount(r.w, pitch);
    var ny = gridCount(r.h, pitch);
    while (nx * ny > MAX_CELLS) {
        pitch *= 1.5;
        nx = gridCount(r.w, pitch);
        ny = gridCount(r.h, pitch);
        coarsened = true;
    }
    if (nx < 1 or ny < 1) return emptyFill(r, pitch, coarsened);

    // Half a cell diagonal — obstacles/inset are inflated by this so the traced
    // CORNER polygon (offset ~½ cell outward from the last kept cell centre)
    // still respects the true clearance / edge pullback.
    const half = pitch * 0.7071068;

    const labels = try arena.alloc(i32, nx * ny);
    const grid = Grid{ .minx = r.minx, .miny = r.miny, .pitch = pitch, .nx = nx, .ny = ny, .labels = labels };
    initInset(grid, placement, r, inset + half);

    const nets = try padNets(arena, placement);
    stampForeign(grid, placement, copper, spec, nets, pc + half);

    const k = labelComponents(arena, grid) catch return emptyFill(r, pitch, coarsened);
    const kept = try arena.alloc(bool, k);
    @memset(kept, false);
    markSeeds(grid, placement, copper, spec, nets, kept);

    const n_comp = try remapKept(arena, grid, kept);
    var contours: std.ArrayListUnmanaged(Contour) = .empty;
    var c: usize = 0;
    while (c < n_comp) : (c += 1) {
        if (try traceOuter(arena, grid, @intCast(c))) |poly| try contours.append(arena, poly);
    }
    return .{
        .minx = r.minx,
        .miny = r.miny,
        .pitch = pitch,
        .nx = nx,
        .ny = ny,
        .labels = labels,
        .n_comp = n_comp,
        .contours = try contours.toOwnedSlice(arena),
        .coarsened = coarsened,
    };
}

/// The routed copper a layout persisted — mirrors `export_gerber.Copper` so the
/// pour carves/seeds the same tracks/vias the Gerber draws (kept a separate
/// type to avoid an import cycle).
pub const Copper = struct {
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
};

/// Grid geometry + the mutable label buffer, threaded through the raster steps.
const Grid = struct {
    minx: f64,
    miny: f64,
    pitch: f64,
    nx: usize,
    ny: usize,
    labels: []i32,

    fn cellCenter(g: Grid, i: usize, j: usize) [2]f64 {
        return .{ g.minx + (@as(f64, @floatFromInt(i)) + 0.5) * g.pitch, g.miny + (@as(f64, @floatFromInt(j)) + 0.5) * g.pitch };
    }
};

fn gridCount(extent: f64, pitch: f64) usize {
    if (extent <= 0 or pitch <= 0) return 0;
    return @intFromFloat(@ceil(extent / pitch));
}

fn emptyFill(r: optimizer.BoardRect, pitch: f64, coarsened: bool) Fill {
    return .{ .minx = r.minx, .miny = r.miny, .pitch = pitch, .nx = 0, .ny = 0, .labels = &.{}, .n_comp = 0, .contours = &.{}, .coarsened = coarsened };
}

/// Mark every cell inside the outline (inset by `inset`) UNLABELED, the rest
/// BLOCKED. Honours a non-rectangular `board_poly`, else the plain rectangle.
fn initInset(g: Grid, placement: optimizer.Placement, r: optimizer.BoardRect, inset: f64) void {
    var j: usize = 0;
    while (j < g.ny) : (j += 1) {
        var i: usize = 0;
        while (i < g.nx) : (i += 1) {
            const c = g.cellCenter(i, j);
            const ok = if (placement.board_poly) |poly|
                outline.signedInset(poly, c[0], c[1]) >= inset
            else
                c[0] >= r.minx + inset and c[0] <= r.minx + r.w - inset and
                    c[1] >= r.miny + inset and c[1] <= r.miny + r.h - inset;
            g.labels[j * g.nx + i] = if (ok) UNLABELED else BLOCKED;
        }
    }
}

// ── Obstacle + seed stamping ────────────────────────────────────────────────

/// (ref-des NUL pad) → net name, so the pour can classify each pad foreign vs
/// carried. Arena-owned.
fn padNets(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error!std.StringHashMap([]const u8) {
    var map = std.StringHashMap([]const u8).init(arena);
    for (placement.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ pin.ref_des, pin.pin });
            try map.put(key, net.name);
        }
    }
    return map;
}

fn netOfPad(nets: std.StringHashMap([]const u8), ref: []const u8, pad: []const u8) []const u8 {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ ref, pad }) catch return "";
    return nets.get(key) orelse "";
}

/// Is a pad present (has copper/hole) on `spec`'s layer? Outer layers see their
/// own side's SMD pads plus every through/NPTH pad; inner planes see only
/// drilled barrels.
fn padOnLayer(part: optimizer.Part, pad: geometry.Pad, spec: LayerSpec) bool {
    const drilled = pad.thru or pad.npth;
    if (spec.side) |s| return drilled or part.side == s;
    return drilled;
}

/// BLOCK every cell within `reach` of a FOREIGN copper feature on this layer
/// (a pad/track/via whose net the plane does not carry). Same-net features are
/// left fillable — they are the pour, and seed it.
fn stampForeign(g: Grid, placement: optimizer.Placement, copper: Copper, spec: LayerSpec, nets: std.StringHashMap([]const u8), reach: f64) void {
    const inner = spec.side == null;
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (!padOnLayer(p, pad, spec)) continue;
            if (planeCarries(spec.net, netOfPad(nets, p.ref_des, pad.number))) continue;
            const c = optimizer.worldPadCenter(p, pad.x, pad.y);
            if (inner) {
                if (pad.drill > 0) stampDisc(g, c[0], c[1], pad.drill / 2 + reach);
            } else {
                stampPad(g, p, pad, reach);
            }
        }
    }
    if (spec.track_layer) |tl| {
        for (copper.tracks) |t| {
            if (t.layer != tl) continue;
            if (planeCarries(spec.net, netName(placement, t.net))) continue;
            stampSeg(g, t.x1, t.y1, t.x2, t.y2, t.width / 2 + reach);
        }
    }
    for (copper.vias) |v| {
        if (planeCarries(spec.net, netName(placement, v.net))) continue;
        stampDisc(g, v.x, v.y, v.dia / 2 + reach);
    }
}

/// Mark the component under each same-net SEED (a carried pad/via present on
/// the layer) KEPT. A component with no seed is an orphan island — dropped.
fn markSeeds(g: Grid, placement: optimizer.Placement, copper: Copper, spec: LayerSpec, nets: std.StringHashMap([]const u8), kept: []bool) void {
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (!padOnLayer(p, pad, spec)) continue;
            if (!planeCarries(spec.net, netOfPad(nets, p.ref_des, pad.number))) continue;
            seedPad(g, p, pad, kept);
        }
    }
    for (copper.vias) |v| {
        if (!planeCarries(spec.net, netName(placement, v.net))) continue;
        seedAt(g, v.x, v.y, kept);
    }
}

/// Seed the pour from a same-net pad by sampling its centre and four rotated
/// edge-midpoints (so a pad whose centre grazes an obstacle/edge cell still
/// keeps the component its copper actually reaches).
fn seedPad(g: Grid, p: optimizer.Part, pad: geometry.Pad, kept: []bool) void {
    const hw = pad.w * 0.4;
    const hh = pad.h * 0.4;
    const local = [_][2]f64{ .{ pad.x, pad.y }, .{ pad.x + hw, pad.y }, .{ pad.x - hw, pad.y }, .{ pad.x, pad.y + hh }, .{ pad.x, pad.y - hh } };
    for (local) |lp| {
        const c = optimizer.worldPadCenter(p, lp[0], lp[1]);
        seedAt(g, c[0], c[1], kept);
    }
}

fn seedAt(g: Grid, x: f64, y: f64, kept: []bool) void {
    const lbl = labelAtWorld(g, x, y);
    if (lbl >= 0) kept[@intCast(lbl)] = true;
}

fn labelAtWorld(g: Grid, x: f64, y: f64) i32 {
    if (g.pitch <= 0) return BLOCKED;
    const fi = @floor((x - g.minx) / g.pitch);
    const fj = @floor((y - g.miny) / g.pitch);
    if (fi < 0 or fj < 0) return BLOCKED;
    const i: usize = @intFromFloat(fi);
    const j: usize = @intFromFloat(fj);
    if (i >= g.nx or j >= g.ny) return BLOCKED;
    return g.labels[j * g.nx + i];
}

fn stampDisc(g: Grid, cx: f64, cy: f64, rad: f64) void {
    if (rad <= 0) return;
    const lo = cellRange(g, cx - rad, cy - rad);
    const hi = cellRange(g, cx + rad, cy + rad);
    const r2 = rad * rad;
    var j = lo[1];
    while (j <= hi[1] and j < g.ny) : (j += 1) {
        var i = lo[0];
        while (i <= hi[0] and i < g.nx) : (i += 1) {
            const c = g.cellCenter(i, j);
            const dx = c[0] - cx;
            const dy = c[1] - cy;
            if (dx * dx + dy * dy <= r2) g.labels[j * g.nx + i] = BLOCKED;
        }
    }
}

fn stampSeg(g: Grid, x1: f64, y1: f64, x2: f64, y2: f64, rad: f64) void {
    if (rad <= 0) return;
    const lo = cellRange(g, @min(x1, x2) - rad, @min(y1, y2) - rad);
    const hi = cellRange(g, @max(x1, x2) + rad, @max(y1, y2) + rad);
    var j = lo[1];
    while (j <= hi[1] and j < g.ny) : (j += 1) {
        var i = lo[0];
        while (i <= hi[0] and i < g.nx) : (i += 1) {
            const c = g.cellCenter(i, j);
            if (segPointDist(x1, y1, x2, y2, c[0], c[1]) <= rad) g.labels[j * g.nx + i] = BLOCKED;
        }
    }
}

fn stampPad(g: Grid, p: optimizer.Part, pad: geometry.Pad, reach: f64) void {
    var arena_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const sh = pad_shape.worldShape(fba.allocator(), p, pad) catch return;
    const lo = cellRange(g, sh.x0 - reach, sh.y0 - reach);
    const hi = cellRange(g, sh.x1 + reach, sh.y1 + reach);
    var j = lo[1];
    while (j <= hi[1] and j < g.ny) : (j += 1) {
        var i = lo[0];
        while (i <= hi[0] and i < g.nx) : (i += 1) {
            const c = g.cellCenter(i, j);
            if (pad_shape.pointDist(sh.x0, sh.y0, sh.x1, sh.y1, sh.poly, c[0], c[1], reach) <= reach)
                g.labels[j * g.nx + i] = BLOCKED;
        }
    }
}

/// Clamp world (x,y) to a grid cell index (saturating at 0 — the callers clamp
/// the high end against nx/ny in their loops).
fn cellRange(g: Grid, x: f64, y: f64) [2]usize {
    const fi = @floor((x - g.minx) / g.pitch);
    const fj = @floor((y - g.miny) / g.pitch);
    return .{
        if (fi < 0) 0 else @intFromFloat(fi),
        if (fj < 0) 0 else @intFromFloat(fj),
    };
}

fn netName(placement: optimizer.Placement, net: i32) []const u8 {
    if (net < 0) return "";
    const i: usize = @intCast(net);
    if (i >= placement.nets.len) return "";
    return placement.nets[i].name;
}

// ── Connected-component labelling ───────────────────────────────────────────

/// Flood-fill 4-connected UNLABELED cells into components 0..k-1 (relabelled in
/// place). Returns k. Uses an explicit stack (no recursion).
fn labelComponents(arena: std.mem.Allocator, g: Grid) std.mem.Allocator.Error!usize {
    var stack: std.ArrayListUnmanaged(u32) = .empty;
    var next: i32 = 0;
    var start: usize = 0;
    while (start < g.labels.len) : (start += 1) {
        if (g.labels[start] != UNLABELED) continue;
        g.labels[start] = next;
        stack.clearRetainingCapacity();
        try stack.append(arena, @intCast(start));
        while (stack.pop()) |idx| {
            const i = idx % g.nx;
            const j = idx / g.nx;
            if (i > 0) try floodPush(arena, g, &stack, j * g.nx + (i - 1), next);
            if (i + 1 < g.nx) try floodPush(arena, g, &stack, j * g.nx + (i + 1), next);
            if (j > 0) try floodPush(arena, g, &stack, (j - 1) * g.nx + i, next);
            if (j + 1 < g.ny) try floodPush(arena, g, &stack, (j + 1) * g.nx + i, next);
        }
        next += 1;
    }
    return @intCast(next);
}

fn floodPush(arena: std.mem.Allocator, g: Grid, stack: *std.ArrayListUnmanaged(u32), idx: usize, comp: i32) std.mem.Allocator.Error!void {
    if (g.labels[idx] != UNLABELED) return;
    g.labels[idx] = comp;
    try stack.append(arena, @intCast(idx));
}

/// Remap kept components to a dense 0..n; every other cell becomes -1 (blocked
/// or dropped orphan). Returns the kept count n.
fn remapKept(arena: std.mem.Allocator, g: Grid, kept: []bool) std.mem.Allocator.Error!usize {
    const dense = try arena.alloc(i32, kept.len);
    var n: i32 = 0;
    for (kept, 0..) |k, i| {
        if (k) {
            dense[i] = n;
            n += 1;
        } else dense[i] = -1;
    }
    for (g.labels) |*l| {
        l.* = if (l.* >= 0) dense[@intCast(l.*)] else -1;
    }
    return @intCast(n);
}

// ── Contour tracing (marching-squares edge stitch + Douglas-Peucker) ─────────

/// Directions, clockwise in the y-down grid: E, S, W, N.
const Dir = enum(u2) { e, s, w, n };
const Edge = struct { a: u32, b: u32, dir: Dir, used: bool = false };
/// Corner code → indices of the (still-unused) boundary edges leaving it.
const TailMap = std.AutoHashMap(u32, std.ArrayListUnmanaged(usize));

/// Trace component `comp`'s OUTER boundary as a simplified world polygon. The
/// boundary is the set of lattice edges between a `comp` cell and a non-`comp`
/// neighbour, oriented with copper on the right; stitched into loops (turning
/// to hug the copper at saddles), the largest-area loop is the outer boundary
/// (holes are smaller loops — dropped; the Gerber re-punches them as antipads).
fn traceOuter(arena: std.mem.Allocator, g: Grid, comp: i32) std.mem.Allocator.Error!?Contour {
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    const w: u32 = @intCast(g.nx + 1);
    var j: usize = 0;
    while (j < g.ny) : (j += 1) {
        var i: usize = 0;
        while (i < g.nx) : (i += 1) {
            if (g.labels[j * g.nx + i] != comp) continue;
            try emitCellEdges(arena, &edges, g, comp, i, j, w);
        }
    }
    if (edges.items.len == 0) return null;

    // corner code → indices of unused edges with that tail.
    var by_tail = TailMap.init(arena);
    for (edges.items, 0..) |e, idx| {
        const gop = try by_tail.getOrPut(e.a);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, idx);
    }

    var best: ?[]const [2]f64 = null;
    var best_area: i64 = -1;
    for (edges.items, 0..) |_, idx| {
        if (edges.items[idx].used) continue;
        const loop = try stitchLoop(arena, edges.items, &by_tail, idx);
        var area = shoelace2(loop, w);
        if (area < 0) area = -area;
        if (area > best_area) {
            best_area = area;
            best = try cornersToWorld(arena, g, loop, w);
        }
    }
    if (best) |poly| return try simplify(arena, poly, g.pitch * 0.5);
    return null;
}

fn emitCellEdges(arena: std.mem.Allocator, edges: *std.ArrayListUnmanaged(Edge), g: Grid, comp: i32, i: usize, j: usize, w: u32) std.mem.Allocator.Error!void {
    const ii: u32 = @intCast(i);
    const jj: u32 = @intCast(j);
    const solid = struct {
        fn at(gg: Grid, cc: i32, x: i64, y: i64) bool {
            if (x < 0 or y < 0 or x >= @as(i64, @intCast(gg.nx)) or y >= @as(i64, @intCast(gg.ny))) return false;
            return gg.labels[@as(usize, @intCast(y)) * gg.nx + @as(usize, @intCast(x))] == cc;
        }
    }.at;
    // top: neighbour above empty → edge (i+1,j)→(i,j), dir W
    if (!solid(g, comp, ii, @as(i64, jj) - 1)) try edges.append(arena, .{ .a = jj * w + ii + 1, .b = jj * w + ii, .dir = .w });
    // bottom: neighbour below empty → edge (i,j+1)→(i+1,j+1), dir E
    if (!solid(g, comp, ii, @as(i64, jj) + 1)) try edges.append(arena, .{ .a = (jj + 1) * w + ii, .b = (jj + 1) * w + ii + 1, .dir = .e });
    // left: neighbour left empty → edge (i,j)→(i,j+1), dir S
    if (!solid(g, comp, @as(i64, ii) - 1, jj)) try edges.append(arena, .{ .a = jj * w + ii, .b = (jj + 1) * w + ii, .dir = .s });
    // right: neighbour right empty → edge (i+1,j+1)→(i+1,j), dir N
    if (!solid(g, comp, @as(i64, ii) + 1, jj)) try edges.append(arena, .{ .a = (jj + 1) * w + ii + 1, .b = jj * w + ii + 1, .dir = .n });
}

/// Follow boundary edges from `start` back to its tail, choosing at each corner
/// the unused outgoing edge that turns most sharply right (copper on the right)
/// — the standard rule that keeps 4-connected regions separate at saddles.
fn stitchLoop(arena: std.mem.Allocator, edges: []Edge, by_tail: *TailMap, start: usize) std.mem.Allocator.Error![]const u32 {
    var corners: std.ArrayListUnmanaged(u32) = .empty;
    var cur = start;
    const loop_start = edges[start].a;
    while (true) {
        edges[cur].used = true;
        try corners.append(arena, edges[cur].a);
        const head = edges[cur].b;
        if (head == loop_start) break;
        const nxt = pickNext(edges, by_tail, head, edges[cur].dir) orelse break;
        cur = nxt;
    }
    return corners.toOwnedSlice(arena);
}

fn pickNext(edges: []Edge, by_tail: *TailMap, tail: u32, din: Dir) ?usize {
    const list = by_tail.get(tail) orelse return null;
    var best: ?usize = null;
    var best_pref: u8 = 255;
    for (list.items) |idx| {
        if (edges[idx].used) continue;
        const pref = turnPref(din, edges[idx].dir);
        if (pref < best_pref) {
            best_pref = pref;
            best = idx;
        }
    }
    return best;
}

/// Preference (0 = best) for turning from `din` to `dout`, hugging copper on
/// the right: right turn, then straight, then left, then reverse.
fn turnPref(din: Dir, dout: Dir) u8 {
    const d: u8 = @intFromEnum(din);
    const o: u8 = @intFromEnum(dout);
    const right = (d + 1) & 3;
    const straight = d;
    const left = (d + 3) & 3;
    if (o == right) return 0;
    if (o == straight) return 1;
    if (o == left) return 2;
    return 3;
}

/// Twice the signed lattice area of a corner loop (shoelace, integer grid
/// coords decoded from the corner codes). Magnitude picks the outer boundary
/// (it always encloses more area than any hole loop of the same component).
fn shoelace2(corners: []const u32, w: u32) i64 {
    if (corners.len < 3) return 0;
    var sum: i64 = 0;
    var prev = corners[corners.len - 1];
    for (corners) |code| {
        const pi: i64 = @intCast(prev % w);
        const pj: i64 = @intCast(prev / w);
        const ci: i64 = @intCast(code % w);
        const cj: i64 = @intCast(code / w);
        sum += pi * cj - ci * pj;
        prev = code;
    }
    return sum;
}

fn cornersToWorld(arena: std.mem.Allocator, g: Grid, corners: []const u32, w: u32) std.mem.Allocator.Error![]const [2]f64 {
    const out = try arena.alloc([2]f64, corners.len);
    for (corners, 0..) |code, k| {
        const i = code % w;
        const j = code / w;
        out[k] = .{ g.minx + @as(f64, @floatFromInt(i)) * g.pitch, g.miny + @as(f64, @floatFromInt(j)) * g.pitch };
    }
    return out;
}

/// Colinear-merge then Douglas-Peucker with a small tolerance (well under the
/// clearance, since obstacles were inflated by ½-cell): reduces the axis-
/// aligned staircase to a compact polygon without eroding the pour.
fn simplify(arena: std.mem.Allocator, pts: []const [2]f64, tol: f64) std.mem.Allocator.Error!Contour {
    if (pts.len < 4) return pts;
    var merged: std.ArrayListUnmanaged([2]f64) = .empty;
    for (pts, 0..) |p, i| {
        const prev = pts[(i + pts.len - 1) % pts.len];
        const next = pts[(i + 1) % pts.len];
        const cross = (p[0] - prev[0]) * (next[1] - prev[1]) - (p[1] - prev[1]) * (next[0] - prev[0]);
        if (@abs(cross) > 1e-9) try merged.append(arena, p);
    }
    if (merged.items.len < 4) return merged.toOwnedSlice(arena);
    return dp(arena, merged.items, tol);
}

fn dp(arena: std.mem.Allocator, pts: []const [2]f64, tol: f64) std.mem.Allocator.Error!Contour {
    var keep = try arena.alloc(bool, pts.len);
    @memset(keep, false);
    keep[0] = true;
    keep[pts.len - 1] = true;
    var stack: std.ArrayListUnmanaged([2]usize) = .empty;
    try stack.append(arena, .{ 0, pts.len - 1 });
    while (stack.pop()) |seg| {
        const a = seg[0];
        const b = seg[1];
        var best: f64 = tol;
        var split: usize = 0;
        var i = a + 1;
        while (i < b) : (i += 1) {
            const d = perpDist(pts[a], pts[b], pts[i]);
            if (d > best) {
                best = d;
                split = i;
            }
        }
        if (split != 0) {
            keep[split] = true;
            try stack.append(arena, .{ a, split });
            try stack.append(arena, .{ split, b });
        }
    }
    var out: std.ArrayListUnmanaged([2]f64) = .empty;
    for (pts, 0..) |p, i| if (keep[i]) try out.append(arena, p);
    return out.toOwnedSlice(arena);
}

fn perpDist(a: [2]f64, b: [2]f64, p: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len < 1e-12) return std.math.hypot(p[0] - a[0], p[1] - a[1]);
    return @abs((p[0] - a[0]) * dy - (p[1] - a[1]) * dx) / len;
}

fn segPointDist(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return std.math.hypot(px - ax, py - ay);
    const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    return std.math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

// ── Carrying-layer resolution + cross-layer connectivity ────────────────────

/// The layers that pour `net_name` on `rules`: declared `(plane IDX "NET")`
/// entries whose net matches (outer faces carry a `side`/`track_layer`; inner
/// planes don't), plus — for the legacy implicit model with no stackup form —
/// one inner ground plane when the net is ground-named.
fn carryingLayers(arena: std.mem.Allocator, rules: optimizer.BoardRules, net_name: []const u8) std.mem.Allocator.Error![]const LayerSpec {
    var out: std.ArrayListUnmanaged(LayerSpec) = .empty;
    if (rules.plane_nets == null) {
        if (optimizer.isGroundName(leafName(net_name))) try out.append(arena, .{ .net = .ground });
        return out.toOwnedSlice(arena);
    }
    const bottom: u8 = if (rules.copper_layers >= 2) rules.copper_layers else 0;
    for (rules.planes) |pl| {
        if (!planeCarries(.{ .named = pl.net }, net_name)) continue;
        if (pl.index == 1) {
            try out.append(arena, .{ .net = .{ .named = pl.net }, .side = .top, .track_layer = 0 });
        } else if (bottom != 0 and pl.index == bottom) {
            try out.append(arena, .{ .net = .{ .named = pl.net }, .side = .bottom, .track_layer = 1 });
        } else {
            try out.append(arena, .{ .net = .{ .named = pl.net } });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Honest plane connectivity for one net: compute the fill of every carrying
/// layer, then assign each query pad/via a CANONICAL component id, unifying ids
/// across layers through the through-hole pads and vias that bridge them. A pad
/// touching no kept component gets -1 (an isolated pad — an honest airwire).
pub fn planeConnect(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    net_name: []const u8,
    pads: []const PadQuery,
    vias: []const router.Via,
) std.mem.Allocator.Error!Join {
    const layers = try carryingLayers(arena, placement.rules, net_name);
    const pad_comp = try arena.alloc(i32, pads.len);
    const via_comp = try arena.alloc(i32, vias.len);
    @memset(pad_comp, -1);
    @memset(via_comp, -1);
    if (layers.len == 0) return .{ .pad_comp = pad_comp, .via_comp = via_comp, .n_comp = 0, .coarsened = false };

    // Global component ids are (layer_offset[l] + local), unified by a
    // union-find so a through pad / via that lands in two layers' components
    // fuses them.
    var total: usize = 0;
    const fills = try arena.alloc(Fill, layers.len);
    const offset = try arena.alloc(usize, layers.len);
    var coarsened = false;
    for (layers, 0..) |spec, l| {
        fills[l] = try compute(arena, placement, copper, spec);
        offset[l] = total;
        total += fills[l].n_comp;
        coarsened = coarsened or fills[l].coarsened;
    }
    const uf = try arena.alloc(usize, total);
    for (uf, 0..) |*u, i| u.* = i;

    assignPads(pads, layers, fills, offset, uf, pad_comp);
    assignVias(vias, layers, fills, offset, uf, via_comp);
    const n = denseRoots(arena, uf, pad_comp, via_comp);
    return .{ .pad_comp = pad_comp, .via_comp = via_comp, .n_comp = n, .coarsened = coarsened };
}

fn assignPads(pads: []const PadQuery, layers: []const LayerSpec, fills: []const Fill, offset: []const usize, uf: []usize, out: []i32) void {
    for (pads, 0..) |q, pi| {
        var first: i32 = -1;
        for (layers, 0..) |spec, l| {
            if (!padPresent(q, spec)) continue;
            const c = fills[l].padComponent(q.cx, q.cy, q.x0, q.y0, q.x1, q.y1);
            if (c < 0) continue;
            const gid: i32 = @intCast(offset[l] + @as(usize, @intCast(c)));
            if (first < 0) first = gid else ufUnite(uf, @intCast(first), @intCast(gid));
        }
        out[pi] = first;
    }
}

fn assignVias(vias: []const router.Via, layers: []const LayerSpec, fills: []const Fill, offset: []const usize, uf: []usize, out: []i32) void {
    for (vias, 0..) |v, vi| {
        var first: i32 = -1;
        for (layers, 0..) |_, l| {
            const c = fills[l].componentAt(v.x, v.y);
            if (c < 0) continue;
            const gid: i32 = @intCast(offset[l] + @as(usize, @intCast(c)));
            if (first < 0) first = gid else ufUnite(uf, @intCast(first), @intCast(gid));
        }
        out[vi] = first;
    }
}

/// Is a pad present on `spec`'s layer? Outer: its own side's SMD, or any thru
/// pad. Inner: only thru pads.
fn padPresent(q: PadQuery, spec: LayerSpec) bool {
    if (spec.side) |s| return q.thru or q.side == s;
    return q.thru;
}

/// Canonicalise every assigned id through the union-find and renumber the live
/// roots to a dense 0..n. Returns n.
fn denseRoots(arena: std.mem.Allocator, uf: []usize, pad_comp: []i32, via_comp: []i32) usize {
    var map = std.AutoHashMap(usize, i32).init(arena);
    var n: i32 = 0;
    for ([_][]i32{ pad_comp, via_comp }) |slice| {
        for (slice) |*id| {
            if (id.* < 0) continue;
            const root = ufFind(uf, @intCast(id.*));
            const gop = map.getOrPut(root) catch {
                id.* = 0;
                continue;
            };
            if (!gop.found_existing) {
                gop.value_ptr.* = n;
                n += 1;
            }
            id.* = gop.value_ptr.*;
        }
    }
    return @intCast(n);
}

fn ufFind(uf: []usize, i: usize) usize {
    var r = i;
    while (uf[r] != r) r = uf[r];
    var x = i;
    while (uf[x] != r) {
        const nx = uf[x];
        uf[x] = r;
        x = nx;
    }
    return r;
}

fn ufUnite(uf: []usize, a: usize, b: usize) void {
    const ra = ufFind(uf, a);
    const rb = ufFind(uf, b);
    if (ra != rb) uf[rb] = ra;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// The pitch guard is load-bearing: a zero pitch would divide by zero and feed
// @ceil(inf) into @intFromFloat. (The sibling `extent <= 0` term is equivalent
// under ≤ vs <, since ⌈0/pitch⌉ is also 0 — only the pitch guard is testable.)
test "gridCount guards a non-positive pitch against division by zero" {
    try testing.expectEqual(@as(usize, 0), gridCount(10, 0));
    // A normal extent/pitch counts the covering cells: ⌈10/2⌉ = 5.
    try testing.expectEqual(@as(usize, 5), gridCount(10, 2));
}

test "emitCellEdges emits the bottom boundary edge for a cell empty below" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // 3×3 label grid (component 1). Cell (1,1) has solid top/left/right
    // neighbours and an EMPTY cell below (index 7). So exactly one boundary
    // edge is emitted: the bottom, dir .e, between vertices (2*w+1)=9 and 10.
    // The `jj + 1` neighbour offset and the vertex-index arithmetic must all
    // hold — a +→− flip either checks the wrong neighbour or misnumbers a vertex.
    var labels = [_]i32{ 0, 1, 0, 1, 1, 1, 0, 0, 0 };
    const g = Grid{ .minx = 0, .miny = 0, .pitch = 1, .nx = 3, .ny = 3, .labels = &labels };
    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    try emitCellEdges(arena, &edges, g, 1, 1, 1, 4);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqual(Dir.e, edges.items[0].dir);
    try testing.expectEqual(@as(u32, 9), edges.items[0].a);
    try testing.expectEqual(@as(u32, 10), edges.items[0].b);
}

fn testPlacement(parts: []optimizer.Part, nets: []const @import("../export_kicad.zig").FlatNet, rules: optimizer.BoardRules) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 },
        .rules = rules,
    };
}

// spec: placement/pour - a seeded pour keeps its component and drops an unseeded orphan island
test "island removal keeps seeded components and drops orphans" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A GND pad on the bottom pour (seed) and, across a full-height VIN wall,
    // an unseeded right half. The right component must be dropped.
    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 10, .side = .bottom },
    };
    const gnd_pins = [_]@import("../export_kicad.zig").FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]@import("../export_kicad.zig").FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = &planes });

    // A foreign VIN wall on the bottom layer splitting the board in two.
    const wall = [_]router.Track{.{ .x1 = 10, .y1 = -2, .x2 = 10, .y2 = 22, .layer = 1, .width = 0.5, .net = 1 }};
    const fill = try compute(arena, placement, .{ .tracks = &wall }, .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 });

    // Exactly one kept component (the left, seeded half); the right half orphan
    // is dropped, and it survives as a real polygon contour.
    try testing.expectEqual(@as(usize, 1), fill.n_comp);
    try testing.expect(fill.contours.len == 1);
    try testing.expect(fill.componentAt(3, 10) == 0); // seed side kept
    try testing.expect(fill.componentAt(17, 10) < 0); // orphan side dropped
}

// spec: placement/pour - a foreign trace that splits a plane leaves its same-net pads in separate components
test "planeConnect splits pads across a severed plane" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 10, .side = .bottom },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 17, .y = 10, .side = .bottom },
    };
    const gnd_pins = [_]@import("../export_kicad.zig").FlatPin{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]@import("../export_kicad.zig").FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = &planes });

    const qpads = [_]PadQuery{
        .{ .cx = 3, .cy = 10, .x0 = 2.7, .y0 = 9.7, .x1 = 3.3, .y1 = 10.3, .thru = false, .side = .bottom },
        .{ .cx = 17, .cy = 10, .x0 = 16.7, .y0 = 9.7, .x1 = 17.3, .y1 = 10.3, .thru = false, .side = .bottom },
    };

    // No wall: one plane, both pads share a component.
    const whole = try planeConnect(arena, placement, .{}, "GND", &qpads, &.{});
    try testing.expectEqual(@as(usize, 1), whole.n_comp);
    try testing.expectEqual(whole.pad_comp[0], whole.pad_comp[1]);

    // A full-height foreign wall severs the plane: the pads land in different
    // components — an honest split.
    const wall = [_]router.Track{.{ .x1 = 10, .y1 = -2, .x2 = 10, .y2 = 22, .layer = 1, .width = 0.5, .net = 1 }};
    const cut = try planeConnect(arena, placement, .{ .tracks = &wall }, "GND", &qpads, &.{});
    try testing.expectEqual(@as(usize, 2), cut.n_comp);
    try testing.expect(cut.pad_comp[0] != cut.pad_comp[1]);
    try testing.expect(cut.pad_comp[0] >= 0 and cut.pad_comp[1] >= 0);
}

// spec: placement/pour - the fill respects a non-rectangular board outline
test "polygon outline restricts the fill to inside the board" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 3, .side = .bottom },
    };
    const gnd_pins = [_]@import("../export_kicad.zig").FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]@import("../export_kicad.zig").FlatNet{.{ .name = "GND", .pins = &gnd_pins }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    var placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = &planes });
    // L-shape: the (10..20, 4..20) corner is notched out.
    const l_poly = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 4 }, .{ 10, 4 }, .{ 10, 20 }, .{ 0, 20 } };
    placement.board_poly = &l_poly;
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 };

    const fill = try compute(arena, placement, .{}, .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 });
    try testing.expect(fill.componentAt(3, 3) == 0); // main body, poured
    try testing.expect(fill.componentAt(15, 15) < 0); // inside the notch — not poured
    try testing.expect(fill.componentAt(15, 2) == 0); // the upper arm, poured
}

// spec: placement/pour - an isolated same-net pad reports no pour component
test "planeConnect isolates a same-net pad on the wrong side of a single-sided pour" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A bottom-only GND pour. C1's GND pad is on the bottom (connects); C2's GND
    // pad is on the TOP, with no via down — the pour cannot reach it, an honest
    // airwire rather than a believed-connected pad.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 10, .side = .bottom },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 15, .y = 10, .side = .top },
    };
    const gnd_pins = [_]@import("../export_kicad.zig").FlatPin{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]@import("../export_kicad.zig").FlatNet{.{ .name = "GND", .pins = &gnd_pins }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = &planes });

    const qpads = [_]PadQuery{
        .{ .cx = 3, .cy = 10, .x0 = 2.7, .y0 = 9.7, .x1 = 3.3, .y1 = 10.3, .thru = false, .side = .bottom },
        .{ .cx = 15, .cy = 10, .x0 = 14.7, .y0 = 9.7, .x1 = 15.3, .y1 = 10.3, .thru = false, .side = .top },
    };
    const join = try planeConnect(arena, placement, .{}, "GND", &qpads, &.{});
    try testing.expect(join.pad_comp[0] >= 0); // C1 (bottom) reaches the pour
    try testing.expectEqual(@as(i32, -1), join.pad_comp[1]); // C2 (top) does not
}

// spec: placement/pour - carryingLayers resolves declared planes and the implicit ground model
test "carryingLayers picks the poured layers for a net" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Implicit model: ground nets pour one inner plane; signals pour nothing.
    const imp = try carryingLayers(arena, .{}, "GND");
    try testing.expectEqual(@as(usize, 1), imp.len);
    try testing.expect(imp[0].net == .ground);
    try testing.expect(imp[0].side == null);
    try testing.expectEqual(@as(usize, 0), (try carryingLayers(arena, .{}, "SIG")).len);

    // Declared bottom pour: an outer face with its track layer.
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const layers = try carryingLayers(arena, .{ .plane_nets = &[_][]const u8{"GND"}, .copper_layers = 2, .planes = &planes }, "GND");
    try testing.expectEqual(@as(usize, 1), layers.len);
    try testing.expect(layers[0].side.? == .bottom);
    try testing.expectEqual(@as(u8, 1), layers[0].track_layer.?);
}
