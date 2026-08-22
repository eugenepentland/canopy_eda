//! Gridless constrained-Delaunay-triangulation (CDT) + funnel channel router —
//! the ROUTER's last-resort rescue tier for a net the fine-grid maze cannot
//! thread. The maze rasters the window at `track_width + clearance` pitch; an
//! off-grid pad escape whose legal channel is narrower than that pitch is
//! invisible to the lattice even when free space exists. This module instead
//! triangulates the FREE space between Minkowski-inflated obstacles and pulls a
//! taut centreline through it, so a sub-grid channel becomes routable.
//!
//! Pure geometry over plain data (the `bend_smooth` / `fine_window` precedent):
//! the caller (`router.zig`) hands a narrow `Input` bundle — the window, the
//! foreign copper to avoid, and two terminals — and gets back a funnel polyline
//! (or null). The router emits it as tracks and runs the SAME DRC-clean gate the
//! grid rescue uses, so the CDT tier can never introduce a violation: an
//! ill-formed or grazing path is simply rolled back and the net stays failed.
//!
//! Robustness: all coordinates are translated to a window-local integer
//! NANOMETRE lattice (== the router's 1e-6 mm clearance epsilon) and every
//! geometric decision goes through EXACT i128 `orient2d` / `inCircle`
//! predicates. No floating-point orientation, no RNG, no clock — the same input
//! always yields the same path, byte for byte, on every platform.

const std = @import("std");
const router = @import("router.zig");
const fine_window = @import("fine_window.zig");
const numeric = @import("../numeric.zig");

/// Integer lattice quantum: 1 nanometre = 1e-6 mm == the router's clearance_eps.
const nm_per_mm: f64 = 1_000_000.0;
/// Extra offset (mm) beyond the DRC clearance baked into every obstacle so the
/// taut path sits STRICTLY inside the min-clearance boundary and survives the
/// router's `fineCopperClean` `< need - clearance_eps` test.
const eps_safety_mm: f64 = 2e-6;
/// Ring samples per obstacle core point. The disc radius is outer-corrected
/// (÷cos(π/steps)) so the sampled convex hull provably CONTAINS the true disc
/// offset — a point outside the hull is ≥ the clearance from the pad copper.
const ring_steps: usize = 16;
/// Bail caps so a pathological window fails fast (→ null → the net stays failed)
/// rather than spinning.
///
/// `max_points` is sized for a WHOLE-BOARD mesh, not just a two-terminal rescue
/// pocket: every foreign pad, track and via reaching the window contributes one
/// inflated hull of up to `ring_steps + 4` vertices, and barracuda's busiest
/// signal layer carries 644 tracks + 467 vias + its share of 187 parts' pads —
/// about 25k vertices. The old 6000 cap silently refused a board-scale mesh.
const max_points: usize = 400_000;
const max_flip_iters: usize = 400_000;
/// GLOBAL work budget for one `route` call, in units of "elementary mesh steps"
/// — one walk hop, one fan rotation, one flip-loop iteration. Every loop below
/// charges it, so the TOTAL meshing cost is bounded no matter how many
/// constraint edges thrash. Meshing is best-effort (`route` returns null on any
/// give-up and every consumer handles it), so a budget-exhausted mesh simply
/// yields no path.
///
/// The UNIT changed with the scalable mesh. `locate`, `edgeExists` and
/// `pickCrossing` used to scan EVERY triangle and charge the whole mesh per
/// call, which made both the cost and the budget quadratic in the point count —
/// the reason a board-scale mesh was unreachable rather than merely slow. They
/// are now O(walk), O(1) and O(crossings), so one unit is a genuine
/// constant-time step. A board-scale mesh (~25k points) inserts for roughly
/// 30-60 steps per point, so 60M leaves a healthy build an order of magnitude of
/// headroom while still stopping a degenerate one in well under a second.
const max_total_work: usize = 60_000_000;
/// Walk caps before a point location or a constraint walk gives up. A straight
/// walk is only guaranteed to terminate in a Delaunay mesh, and constraint flips
/// leave this one non-Delaunay, so both are bounded: `locate` falls back to the
/// exact linear scan (correct, just slow, and vanishingly rare) and the
/// constraint walk abandons its edge — best-effort, exactly as a non-resolving
/// flip already does.
const max_walk_steps: usize = 4096;
const max_cross_walk: usize = 4096;
/// Cells per axis in the obstacle bucket grid. Classifying which triangles lie
/// inside an obstacle is O(triangles × obstacles) unless the obstacles are
/// indexed: at board scale that is 50k × 1500 polygon tests, which dwarfs the
/// meshing itself. 128² buckets leave ~1 obstacle in the average cell of a
/// 70 x 25 mm board.
const grid_divs: usize = 128;
/// Width of the sealed band along the window hull, in lattice units (1 µm).
///
/// An obstacle reaching past the window is CLAMPED to the hull, not clipped to
/// it, which leaves a lattice-thin ribbon of nominally free space between the
/// clamped boundary and the hull. That ribbon is a LIE: the copper the polygon
/// was clamped from really does extend past the window, so a centreline in the
/// ribbon is not clear of it. Left open, a wall spanning the whole window can be
/// walked around through a one-nanometre gap and the engine reports a route
/// where none exists. Sealing a 1 µm band closes every such ribbon while sitting
/// three orders of magnitude below any dimension a real route occupies (the
/// window is margined 3.5 mm around its terminals, so nothing legitimate ever
/// runs this close to its edge).
const hull_seal_nm: i64 = 1_000;
/// Steiner lattice: the larger window span is divided into this many cells for
/// the mesh-quality grid (finer near-square meshes cost more; coarser corridors
/// neck). A purely geometric aid — the funnel path stays sub-grid.
const steiner_divs: i64 = 10;
const steiner_min_nm: i64 = 400_000; // never finer than 0.4 mm
/// Integer-hash coefficients for the Steiner jitter (a fixed permutation, not an
/// RNG); the span (121) keeps the offset a sub-quantum ±60 nm.
const jitter_mul: i64 = 2246822519;
const jitter_add: i64 = 3266489917;
const jitter_span: i64 = 121;

/// A window-local lattice point in nanometres.
const Point = struct { x: i64, y: i64 };

/// One non-copper region a path must clear (see `Obstacles.keepouts`). A pour or
/// a routing keepout belongs to ONE signal layer; a board-edge band belongs to
/// all of them, which is what `every_layer` says.
pub const Keepout = struct {
    poly: []const [2]f64,
    layer: u8 = 0,
    every_layer: bool = false,
};

/// Which of a caller's four obstacle sources one inflated polygon came from.
pub const OwnerKind = enum { pad, track, via, keepout };

/// What one inflated obstacle polygon in a scene came FROM.
///
/// The mesh itself needs none of this — free space is free space, whoever made
/// it — but a search that FAILS has to be able to say what walled it, and by
/// then the polygons are anonymous rings of lattice points. One tag per polygon,
/// in the same order as the polygons themselves, is the whole record: which
/// source it came from, its index in that source (so the caller can measure the
/// real body against its own slices), and the net it carries — `-1` for a
/// keepout, which carries none.
pub const Owner = struct { kind: OwnerKind, net: i32 = -1, src: u32 = 0 };

/// The foreign copper a CDT route must clear, plus the net being routed (whose
/// own pads/copper are skipped — same-net needs no clearance).
pub const Obstacles = struct {
    pads: []const router.PadObs,
    tracks: []const router.Track,
    vias: []const router.Via,
    skip_net: i32,
    /// Extra keep-out radius (mm) an obstacle demands OVER ordinary clearance,
    /// indexed by its net. Empty (the default) is the plain-clearance model,
    /// byte-identical to what every caller had before this field existed.
    ///
    /// Parity, not decoration. The caller that emits a path this module finds
    /// gates every segment against its own clearance rule, and an authored
    /// `(keepout …)` widens that rule for the halo's owner. Modelling copper at
    /// ordinary clearance while the gate measures it at halo distance means the
    /// search spends its single Dijkstra answer on a corridor the gate then
    /// refuses — and a refused answer is not retried, so the legal corridor
    /// beside it is never found.
    halo: []const f64 = &.{},
    /// Regions the path must stay out of that are not copper at all, resolved by
    /// the caller for the net being routed: blocking zones, and the band inside
    /// the board edge where copper may not sit. Plain mm polygons, inflated by
    /// the same `need` as copper.
    ///
    /// Kept apart from `pads` because these carry no net — nothing here is ever
    /// skipped for belonging to the routing net — and because whether a zone
    /// blocks THIS net at all is a question the caller has already answered.
    keepouts: []const Keepout = &.{},

    /// The extra radius `net`'s copper demands, or zero where the board
    /// declares no halo for it.
    fn haloOf(self: Obstacles, net: i32) f64 {
        if (net < 0) return 0;
        const i: usize = @intCast(net);
        return if (i < self.halo.len) self.halo[i] else 0;
    }
};

/// A narrow plain-data request: the search window, the signal layer to route on,
/// the obstacles to avoid, the two terminals (world mm), and this net's geometry.
/// Deliberately NOT the router's 44-field `Ctx` — the router lowers plain slices
/// into this at the seam.
pub const Input = struct {
    rect: fine_window.WindowRect,
    layer: u8,
    obstacles: Obstacles,
    start: [2]f64,
    goal: [2]f64,
    track_width: f64,
    clearance: f64,
};

// ── Exact predicates (i128, integer lattice) ─────────────────────────────────

/// Twice the signed area of triangle a,b,c: > 0 iff c is left of a→b (CCW).
fn orient2d(a: Point, b: Point, c: Point) i128 {
    const bx: i128 = @as(i128, b.x) - a.x;
    const by: i128 = @as(i128, b.y) - a.y;
    const cx: i128 = @as(i128, c.x) - a.x;
    const cy: i128 = @as(i128, c.y) - a.y;
    return bx * cy - by * cx;
}

/// > 0 iff d lies strictly inside the circumcircle of the CCW triangle a,b,c.
fn inCircle(a: Point, b: Point, c: Point, d: Point) i128 {
    const ax: i128 = @as(i128, a.x) - d.x;
    const ay: i128 = @as(i128, a.y) - d.y;
    const bx: i128 = @as(i128, b.x) - d.x;
    const by: i128 = @as(i128, b.y) - d.y;
    const cx: i128 = @as(i128, c.x) - d.x;
    const cy: i128 = @as(i128, c.y) - d.y;
    const a2 = ax * ax + ay * ay;
    const b2 = bx * bx + by * by;
    const c2 = cx * cx + cy * cy;
    return ax * (by * c2 - b2 * cy) - ay * (bx * c2 - b2 * cx) + a2 * (bx * cy - by * cx);
}

fn vEq(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

/// True when segments a→b and u→w cross at an interior point of both (strict —
/// collinear/touching is not a crossing).
fn segCross(a: Point, b: Point, u: Point, w: Point) bool {
    const d1 = orient2d(a, b, u);
    const d2 = orient2d(a, b, w);
    const d3 = orient2d(u, w, a);
    const d4 = orient2d(u, w, b);
    return (d1 > 0) != (d2 > 0) and (d1 != 0 and d2 != 0) and
        (d3 > 0) != (d4 > 0) and (d3 != 0 and d4 != 0);
}

// ── Triangulation mesh (Lawson incremental Delaunay + constraints) ────────────

/// One mesh triangle: CCW vertex indices `v` and the neighbour triangle across
/// each edge (`adj[e]` is opposite `v[e]`, i.e. the edge v[(e+1)%3]→v[(e+2)%3]);
/// -1 marks a hull edge.
const Tri = struct { v: [3]u32, adj: [3]i32 };

const Mesh = struct {
    a: std.mem.Allocator,
    pts: std.ArrayList(Point),
    tris: std.ArrayList(Tri),
    /// Constraint edges (obstacle boundaries) that flips must never remove,
    /// keyed by normalised vertex pair.
    con: std.AutoHashMapUnmanaged(u64, void),
    /// EVERY edge currently in the triangulation, same key as `con`. Maintained
    /// by `splitTri` (three new spokes) and `flipEdge` (old diagonal out, new
    /// one in), which turns `edgeExists` — the innermost test of constraint
    /// insertion — from a scan of every triangle into one hash lookup.
    edges: std.AutoHashMapUnmanaged(u64, void),
    /// Vertex → one triangle incident to it. Enough to start a rotation around
    /// the vertex (`Fan`), which is how constraint insertion finds the wedge its
    /// segment leaves through without scanning the mesh.
    vt: std.ArrayList(i32),
    /// Lattice point → vertex index, so inserting a point that already exists is
    /// a hash lookup rather than a scan of every vertex. (Obstacle hulls share
    /// vertices constantly, so the dedup path is the common one.)
    pmap: std.AutoHashMapUnmanaged(Point, u32),
    /// Last triangle `locate` settled in — the start hint for the next walk.
    /// Consecutive inserts are near each other (hull vertices arrive in polygon
    /// order), so this alone keeps almost every walk to a handful of steps.
    last: usize = 0,
    /// Cumulative meshing work this `route` call has spent, in elementary steps.
    /// Checked against `max_total_work` so every walk/flip loop gives up together
    /// once the global budget is gone. Never resets mid-call.
    work: usize = 0,

    /// Charge `n` units of work (saturating, so a huge mesh can never wrap it).
    fn charge(m: *Mesh, n: usize) void {
        m.work +|= n;
    }
    /// True once the global work budget is spent — every loop below bails on it.
    fn exhausted(m: *const Mesh) bool {
        return m.work >= max_total_work;
    }

    fn conKey(x: u32, y: u32) u64 {
        const lo = @min(x, y);
        const hi = @max(x, y);
        return (@as(u64, lo) << 32) | hi;
    }
    fn isCon(m: *const Mesh, x: u32, y: u32) bool {
        return m.con.contains(conKey(x, y));
    }
    fn addCon(m: *Mesh, x: u32, y: u32) std.mem.Allocator.Error!void {
        try m.con.put(m.a, conKey(x, y), {});
    }
    fn pt(m: *const Mesh, i: u32) Point {
        return m.pts.items[i];
    }

    /// Append a lattice point as a new vertex (caller has already checked it is
    /// not a duplicate), registering it in the dedup index with no incident
    /// triangle yet.
    fn addVertex(m: *Mesh, p: Point) std.mem.Allocator.Error!u32 {
        const vi: u32 = @intCast(m.pts.items.len);
        try m.pts.append(m.a, p);
        try m.vt.append(m.a, -1);
        try m.pmap.put(m.a, p, vi);
        return vi;
    }

    /// Record that edge `x`–`y` is present in the triangulation.
    fn addEdge(m: *Mesh, x: u32, y: u32) std.mem.Allocator.Error!void {
        try m.edges.put(m.a, conKey(x, y), {});
    }
    /// Forget edge `x`–`y` (a flip replaced it with the other diagonal).
    fn dropEdge(m: *Mesh, x: u32, y: u32) void {
        _ = m.edges.remove(conKey(x, y));
    }

    /// Point all three of `ti`'s vertices at it. Called on every triangle a
    /// split or flip rewrote, so no vertex is ever left pointing at a triangle
    /// that no longer contains it.
    fn noteIncidence(m: *Mesh, ti: usize) void {
        for (m.tris.items[ti].v) |v| m.vt.items[v] = @intCast(ti);
    }
};

/// The slot at which triangle `t` carries vertex `v` (3 when it does not).
fn slotOf(t: Tri, v: u32) usize {
    if (t.v[0] == v) return 0;
    if (t.v[1] == v) return 1;
    if (t.v[2] == v) return 2;
    return 3;
}

/// Rotation around one vertex: yields every triangle incident to `v`, starting
/// at `vt[v]`. Walks CCW until it closes the cycle or runs off the hull, then
/// resumes CW from the start so a hull vertex's whole fan is still covered.
/// Purely topological (no predicates), so it is exact by construction.
const Fan = struct {
    m: *Mesh,
    v: u32,
    first: i32,
    cur: i32,
    phase: enum { forward, backward, done },

    /// Begin a rotation around `v`. Deliberately not named `init`: it picks a
    /// starting phase from the vertex's state rather than assigning fields
    /// straight through, which is a walk cursor, not a constructor.
    fn around(m: *Mesh, v: u32) Fan {
        const t0 = m.vt.items[v];
        return .{ .m = m, .v = v, .first = t0, .cur = t0, .phase = if (t0 < 0) .done else .forward };
    }

    /// Step to the neighbour sharing `v` across slot `step` of triangle `ti`.
    fn hop(self: *Fan, ti: usize, step: usize) i32 {
        const t = self.m.tris.items[ti];
        const i = slotOf(t, self.v);
        if (i >= 3) return -1;
        return t.adj[(i + step) % 3];
    }

    fn next(self: *Fan) ?usize {
        self.m.charge(1);
        if (self.m.exhausted()) return null;
        switch (self.phase) {
            .done => return null,
            .forward => {
                const out: usize = @intCast(self.cur);
                const nxt = self.hop(out, 2);
                if (nxt < 0) {
                    // Hull edge: the fan is open, so sweep the other way next.
                    self.phase = .backward;
                    self.cur = self.first;
                } else if (nxt == self.first) {
                    self.phase = .done; // closed the ring
                } else {
                    self.cur = nxt;
                }
                return out;
            },
            .backward => {
                const back = self.hop(@intCast(self.cur), 1);
                if (back < 0) {
                    self.phase = .done;
                    return null;
                }
                self.cur = back;
                return @intCast(back);
            },
        }
    }
};

/// Point of `tri[ti]` at edge-slot `e`'s tail/head (the CCW edge v[(e+1)]→v[(e+2)]).
fn edgeTail(t: Tri, e: usize) u32 {
    return t.v[(e + 1) % 3];
}
fn edgeHead(t: Tri, e: usize) u32 {
    return t.v[(e + 2) % 3];
}

/// The edge-slot of `nt` whose neighbour is `ti`.
fn backEdge(m: *const Mesh, nt: usize, ti: i32) usize {
    const t = m.tris.items[nt];
    if (t.adj[0] == ti) return 0;
    if (t.adj[1] == ti) return 1;
    return 2;
}

/// Point the neighbour `n` back to `to` (rewrites whichever of its edges pointed
/// at `from`). No-op for a hull edge (`n < 0`).
fn relink(m: *Mesh, n: i32, from: i32, to: i32) void {
    if (n < 0) return;
    const ni: usize = @intCast(n);
    for (&m.tris.items[ni].adj) |*a| {
        if (a.* == from) {
            a.* = to;
            return;
        }
    }
}

/// Start a mesh whose hull is the rectangle `lo`..`hi` (two CCW triangles over
/// the four corners). All later points are inserted strictly inside it.
fn initMesh(a: std.mem.Allocator, lo: Point, hi: Point) std.mem.Allocator.Error!Mesh {
    var m = Mesh{ .a = a, .pts = .empty, .tris = .empty, .con = .empty, .edges = .empty, .vt = .empty, .pmap = .empty };
    _ = try m.addVertex(.{ .x = lo.x, .y = lo.y }); // 0
    _ = try m.addVertex(.{ .x = hi.x, .y = lo.y }); // 1
    _ = try m.addVertex(.{ .x = hi.x, .y = hi.y }); // 2
    _ = try m.addVertex(.{ .x = lo.x, .y = hi.y }); // 3
    // Two CCW triangles: (0,1,2) and (0,2,3). Shared edge 0→2.
    try m.tris.append(a, .{ .v = .{ 0, 1, 2 }, .adj = .{ -1, 1, -1 } });
    try m.tris.append(a, .{ .v = .{ 0, 2, 3 }, .adj = .{ -1, -1, 0 } });
    for ([_][2]u32{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 0 }, .{ 2, 3 }, .{ 3, 0 } }) |e| try m.addEdge(e[0], e[1]);
    m.noteIncidence(0);
    m.noteIncidence(1);
    return m;
}

const EdgeRef = struct { t: usize, e: usize };

/// The triangle containing `p` (interior or on an edge), by exact scan. A walk
/// would be faster but is only guaranteed to terminate in a Delaunay mesh, and
/// constraint flips + tie/convexity skips leave this one non-Delaunay; the scan
/// cannot cycle and the rescue meshes are tiny. Null only when `p` is outside
/// the hull (never, since every inserted point is clamped strictly inside).
fn locate(m: *Mesh, p: Point) ?usize {
    if (m.tris.items.len == 0) return null;
    var ti: usize = @min(m.last, m.tris.items.len - 1);
    var step: usize = 0;
    while (step < max_walk_steps) : (step += 1) {
        m.charge(1);
        if (m.exhausted()) return null;
        const t = m.tris.items[ti];
        var moved = false;
        // Rotate which edge is tested first each step. A fixed order can lock a
        // straight walk into a two-triangle cycle on a non-Delaunay mesh; the
        // rotation is a deterministic function of the step count, NOT an RNG.
        for (0..3) |k| {
            const e = (k + step) % 3;
            if (orient2d(m.pt(edgeTail(t, e)), m.pt(edgeHead(t, e)), p) >= 0) continue;
            if (t.adj[e] < 0) return null; // p is outside the hull
            ti = @intCast(t.adj[e]);
            moved = true;
            break;
        }
        if (moved) continue;
        m.last = ti;
        return ti;
    }
    return locateScan(m, p);
}

/// Exact O(mesh) fallback for `locate`: the walk is bounded because constraint
/// flips leave the mesh non-Delaunay, where a straight walk has no termination
/// guarantee. Correctness never depends on the walk succeeding — only speed.
fn locateScan(m: *Mesh, p: Point) ?usize {
    m.charge(m.tris.items.len);
    for (m.tris.items, 0..) |t, i| {
        if (orient2d(m.pt(edgeTail(t, 0)), m.pt(edgeHead(t, 0)), p) < 0) continue;
        if (orient2d(m.pt(edgeTail(t, 1)), m.pt(edgeHead(t, 1)), p) < 0) continue;
        if (orient2d(m.pt(edgeTail(t, 2)), m.pt(edgeHead(t, 2)), p) < 0) continue;
        m.last = i;
        return i;
    }
    return null;
}

/// True when `p` is strictly inside triangle `ti` (all three CCW edges positive).
fn strictlyInside(m: *Mesh, ti: usize, p: Point) bool {
    const t = m.tris.items[ti];
    for (0..3) |e| {
        if (orient2d(m.pt(edgeTail(t, e)), m.pt(edgeHead(t, e)), p) <= 0) return false;
    }
    return true;
}

/// Nudge `p` one lattice step toward triangle `ti`'s centroid so a point that
/// landed exactly on an edge becomes strictly interior (avoids the on-edge split
/// case). The ≤√2 nm shift is far below `eps_safety_mm`.
fn nudgeInside(m: *Mesh, ti: usize, p: Point) Point {
    const t = m.tris.items[ti];
    const cx = @divTrunc(m.pt(t.v[0]).x + m.pt(t.v[1]).x + m.pt(t.v[2]).x, 3);
    const cy = @divTrunc(m.pt(t.v[0]).y + m.pt(t.v[1]).y + m.pt(t.v[2]).y, 3);
    return .{ .x = p.x + std.math.sign(cx - p.x), .y = p.y + std.math.sign(cy - p.y) };
}

/// Flip the shared edge `e` of triangle `ti` (diagonal swap of the two triangles
/// meeting there). Rebuilds both triangles CCW with the new diagonal and fixes
/// all four outer neighbour back-links. Returns the neighbour's slot; both
/// rebuilt triangles carry the apex `v[e]` at index 0 afterwards.
fn flipEdge(m: *Mesh, ti: usize, e: usize) std.mem.Allocator.Error!usize {
    const t = m.tris.items[ti];
    const vp = t.v[e];
    const p1 = edgeTail(t, e);
    const p2 = edgeHead(t, e);
    const x2 = t.adj[(e + 2) % 3]; // neighbour across vp→p1
    const x1 = t.adj[(e + 1) % 3]; // neighbour across p2→vp
    const nti: usize = @intCast(t.adj[e]);
    const f = backEdge(m, nti, @intCast(ti));
    const nt = m.tris.items[nti];
    const d = nt.v[f];
    const y_p1d = nt.adj[(f + 1) % 3]; // neighbour across p1→d
    const y_dp2 = nt.adj[(f + 2) % 3]; // neighbour across d→p2
    m.tris.items[ti] = .{ .v = .{ vp, p1, d }, .adj = .{ y_p1d, @intCast(nti), x2 } };
    m.tris.items[nti] = .{ .v = .{ vp, d, p2 }, .adj = .{ y_dp2, x1, @intCast(ti) } };
    relink(m, y_p1d, @intCast(nti), @intCast(ti));
    relink(m, x1, @intCast(ti), @intCast(nti));
    // The diagonal swapped: p1–p2 is gone, vp–d took its place. Both rebuilt
    // triangles together carry all four vertices, so re-noting them leaves no
    // vertex pointing at a triangle it no longer belongs to.
    m.dropEdge(p1, p2);
    try m.addEdge(vp, d);
    m.noteIncidence(ti);
    m.noteIncidence(nti);
    return nti;
}

/// Split triangle `ti` at interior vertex `vp` into three, and push the three
/// outer edges (opposite `vp`) for Delaunay legalisation.
fn splitTri(m: *Mesh, ti: usize, vp: u32, stack: *std.ArrayList(EdgeRef)) std.mem.Allocator.Error!void {
    const t = m.tris.items[ti];
    const av = t.v[0];
    const bv = t.v[1];
    const cv = t.v[2];
    const na = t.adj[0];
    const nb = t.adj[1];
    const nc = t.adj[2];
    const t0: i32 = @intCast(ti);
    const t1: i32 = @intCast(m.tris.items.len);
    const t2: i32 = t1 + 1;
    m.tris.items[ti] = .{ .v = .{ bv, cv, vp }, .adj = .{ t1, t2, na } };
    try m.tris.append(m.a, .{ .v = .{ cv, av, vp }, .adj = .{ t2, t0, nb } });
    try m.tris.append(m.a, .{ .v = .{ av, bv, vp }, .adj = .{ t0, t1, nc } });
    relink(m, nb, t0, t1);
    relink(m, nc, t0, t2);
    // Three new spokes from the apex; the outer triangle edges are unchanged.
    try m.addEdge(av, vp);
    try m.addEdge(bv, vp);
    try m.addEdge(cv, vp);
    m.noteIncidence(ti);
    m.noteIncidence(@intCast(t1));
    m.noteIncidence(@intCast(t2));
    try stack.append(m.a, .{ .t = ti, .e = 2 });
    try stack.append(m.a, .{ .t = @intCast(t1), .e = 2 });
    try stack.append(m.a, .{ .t = @intCast(t2), .e = 2 });
}

/// Restore the empty-circumcircle property around the freshly inserted apex
/// `vp0` by flipping any non-Delaunay edge opposite it (never a constraint edge).
/// Each suspect is the edge opposite `vp0` in a triangle carrying it; a stale
/// entry — whose slot a flip reused so it no longer holds `vp0` there — is
/// skipped, its current suspect having been re-pushed by that flip.
fn legalize(m: *Mesh, vp0: u32, stack: *std.ArrayList(EdgeRef)) std.mem.Allocator.Error!void {
    var iter: usize = 0;
    while (stack.items.len > 0) {
        iter += 1;
        if (iter > max_flip_iters or m.exhausted()) return;
        m.charge(1);
        const ref = stack.pop().?;
        const t = m.tris.items[ref.t];
        if (ref.e >= 3 or t.adj[ref.e] < 0 or t.v[ref.e] != vp0) continue;
        const p1 = edgeTail(t, ref.e);
        const p2 = edgeHead(t, ref.e);
        if (m.isCon(p1, p2)) continue;
        const nti: usize = @intCast(t.adj[ref.e]);
        const f = backEdge(m, nti, @intCast(ref.t));
        const d = m.tris.items[nti].v[f];
        if (inCircle(m.pt(vp0), m.pt(p1), m.pt(p2), m.pt(d)) <= 0) continue;
        // Convexity guard: only flip a strictly convex quad, so a near-degenerate
        // incircle result can never invert a triangle and corrupt the mesh.
        if (orient2d(m.pt(vp0), m.pt(p1), m.pt(d)) <= 0 or orient2d(m.pt(vp0), m.pt(d), m.pt(p2)) <= 0) continue;
        const other = try flipEdge(m, ref.t, ref.e);
        try stack.append(m.a, .{ .t = ref.t, .e = 0 });
        try stack.append(m.a, .{ .t = other, .e = 0 });
    }
}

/// Insert world point `p` (deduplicating against existing vertices), returning
/// its vertex index. Null on a walk/allocation failure.
fn insertPoint(m: *Mesh, p_in: Point, stack: *std.ArrayList(EdgeRef)) std.mem.Allocator.Error!?u32 {
    if (m.pmap.get(p_in)) |vi| return vi;
    if (m.exhausted()) return null; // budget spent — stop growing the mesh
    if (m.pts.items.len >= max_points) return null;
    const ti = locate(m, p_in) orelse return null;
    var p = p_in;
    if (!strictlyInside(m, ti, p)) {
        p = nudgeInside(m, ti, p);
        if (!strictlyInside(m, ti, p)) return null;
        if (m.pmap.get(p)) |vi| return vi;
    }
    const vp = try m.addVertex(p);
    try splitTri(m, ti, vp, stack);
    try legalize(m, vp, stack);
    return vp;
}

/// True when vertices `a` and `b` are already joined by a mesh edge — one hash
/// lookup into the edge set `splitTri`/`flipEdge` maintain.
fn edgeExists(m: *Mesh, a: u32, b: u32) bool {
    m.charge(1);
    return m.edges.contains(Mesh.conKey(a, b));
}

/// A flippable, non-constraint edge that the segment a→b crosses. `resolves` is
/// true when flipping it replaces the crossed diagonal with one that NO LONGER
/// meets a→b — a monotone-progress flip that strictly drops the crossing count.
/// `pickCrossing` prefers such an edge; when only non-resolving (fallback) edges
/// cross a→b it still returns one, tagged `resolves = false`, so the caller can
/// abandon rather than cycle on it.
const Crossing = struct { ref: EdgeRef, resolves: bool };

/// The triangle incident to `a` whose interior the segment a→b enters, together
/// with the edge-slot opposite `a` — the first edge the segment crosses.
///
/// Found by ROTATING around `a` (`Fan`), not by scanning the mesh: `a` is always
/// a mesh vertex here, so its own fan is the only place the segment can leave
/// from. Null when the segment leaves along an existing edge (collinear with a
/// spoke), which is the "constraint passes through a third vertex" case this
/// module deliberately abandons rather than splitting — best-effort meshing,
/// with the router's DRC gate as the backstop.
fn firstCrossed(m: *Mesh, a: u32, b: u32) ?EdgeRef {
    const pa = m.pt(a);
    const pb = m.pt(b);
    var fan = Fan.around(m, a);
    while (fan.next()) |ti| {
        const t = m.tris.items[ti];
        const i = slotOf(t, a);
        if (i >= 3) continue;
        const u = t.v[(i + 1) % 3];
        const w = t.v[(i + 2) % 3];
        if (u == b or w == b) return null; // already joined
        // b strictly inside the CCW wedge (a→u, a→w) ⇒ the segment crosses u–w.
        if (orient2d(pa, m.pt(u), pb) > 0 and orient2d(pa, pb, m.pt(w)) > 0) return .{ .t = ti, .e = i };
    }
    return null;
}

/// The slot of triangle `ti` (other than `skip`) whose edge the segment pa→pb
/// crosses, or null when the segment ends inside it or grazes a vertex.
fn nextCrossed(m: *Mesh, ti: usize, skip: usize, pa: Point, pb: Point) ?usize {
    const t = m.tris.items[ti];
    for (0..3) |e| {
        if (e == skip) continue;
        if (segCross(pa, pb, m.pt(edgeTail(t, e)), m.pt(edgeHead(t, e)))) return e;
    }
    return null;
}

/// Walk the triangles the segment a→b passes through, returning the first
/// crossed edge that a flip would RESOLVE (see `Crossing`), else the first
/// merely-flippable one. O(crossings) — the walk visits only the corridor the
/// segment actually threads, where the old implementation scanned every triangle
/// in the mesh on every call, which is what made constraint insertion quadratic.
fn pickCrossing(m: *Mesh, a: u32, b: u32) ?Crossing {
    const pa = m.pt(a);
    const pb = m.pt(b);
    var cur = firstCrossed(m, a, b) orelse return null;
    var fallback: ?EdgeRef = null;
    var steps: usize = 0;
    while (steps < max_cross_walk) : (steps += 1) {
        m.charge(1);
        if (m.exhausted()) break;
        const t = m.tris.items[cur.t];
        if (t.adj[cur.e] < 0) break; // ran off the hull
        const u = edgeTail(t, cur.e);
        const w = edgeHead(t, cur.e);
        const nti: usize = @intCast(t.adj[cur.e]);
        if (!m.isCon(u, w)) {
            const d = m.tris.items[nti].v[backEdge(m, nti, @intCast(cur.t))];
            const vp = t.v[cur.e];
            // Only a strictly convex quad is flippable without inverting a triangle.
            if (orient2d(m.pt(vp), m.pt(u), m.pt(d)) > 0 and orient2d(m.pt(vp), m.pt(d), m.pt(w)) > 0) {
                if (!segCross(pa, pb, m.pt(vp), m.pt(d))) return .{ .ref = cur, .resolves = true };
                if (fallback == null) fallback = cur;
            }
        }
        if (hasVertex(m.tris.items[nti], b)) break; // reached the far endpoint
        const back = backEdge(m, nti, @intCast(cur.t));
        cur = .{ .t = nti, .e = nextCrossed(m, nti, back, pa, pb) orelse break };
    }
    if (fallback) |fb| return .{ .ref = fb, .resolves = false };
    return null;
}

/// Force the constraint edge `a`–`b` into the mesh by flipping the edges it
/// crosses (best-effort: a missing edge only degrades the navmesh, never breaks
/// DRC — the router's clean gate is the backstop).
///
/// Only a RESOLVING flip is applied: it removes one edge crossing a→b and adds a
/// diagonal that does not cross it, so the crossing count strictly decreases and
/// the loop provably terminates in ≤ (initial crossings) steps. A non-resolving
/// fallback flip could swap the same pair of near-collinear diagonals forever (the
/// old thrash), so the edge is abandoned the moment no resolving flip remains. The
/// global work budget is the belt-and-suspenders backstop for any residual case.
fn forceEdge(m: *Mesh, a: u32, b: u32) std.mem.Allocator.Error!void {
    if (a == b) return;
    if (m.exhausted()) return;
    while (!edgeExists(m, a, b)) {
        if (m.exhausted()) break;
        const cr = pickCrossing(m, a, b) orelse break;
        if (!cr.resolves) break; // no progress possible — abandon (best-effort)
        _ = try flipEdge(m, cr.ref.t, cr.ref.e);
    }
    if (edgeExists(m, a, b)) try m.addCon(a, b);
}

// ── Obstacle inflation (Minkowski sum with the clearance disc) ────────────────

fn snap(mm: f64, origin: f64) ?i64 {
    return numeric.checkedInt(i64, (mm - origin) * nm_per_mm);
}

/// Convex hull (CCW) of `src` via Andrew's monotone chain, on the exact integer
/// lattice. Returns the ≥3-vertex hull, else the deduped points as-is.
fn convexHull(a: std.mem.Allocator, src: []const Point) std.mem.Allocator.Error![]const Point {
    var pts = try a.dupe(Point, src);
    std.sort.pdq(Point, pts, {}, ptLess);
    var uniq: usize = 0;
    for (pts) |p| {
        if (uniq == 0 or !vEq(pts[uniq - 1], p)) {
            pts[uniq] = p;
            uniq += 1;
        }
    }
    pts = pts[0..uniq];
    if (pts.len < 3) return pts;
    var hull = try a.alloc(Point, pts.len * 2);
    var k: usize = 0;
    for (pts) |p| {
        while (k >= 2 and orient2d(hull[k - 2], hull[k - 1], p) <= 0) k -= 1;
        hull[k] = p;
        k += 1;
    }
    const lower = k + 1;
    var i: usize = pts.len - 1;
    while (i > 0) : (i -= 1) {
        const p = pts[i - 1];
        while (k >= lower and orient2d(hull[k - 2], hull[k - 1], p) <= 0) k -= 1;
        hull[k] = p;
        k += 1;
    }
    return hull[0 .. k - 1];
}

fn ptLess(_: void, a: Point, b: Point) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
}

/// Minkowski-inflate a set of core points by `radius` mm into a CCW hull polygon
/// on the lattice: ring samples (outer-corrected so the hull contains the disc)
/// around each core point, then their convex hull. Null on a bad conversion.
fn inflate(a: std.mem.Allocator, core: []const [2]f64, radius: f64, origin: [2]f64) std.mem.Allocator.Error!?[]const Point {
    const rr = radius / @cos(std.math.pi / @as(f64, @floatFromInt(ring_steps)));
    var samples: std.ArrayList(Point) = .empty;
    for (core) |c| {
        for (0..ring_steps) |k| {
            const ang = 2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(ring_steps));
            const sx = snap(c[0] + rr * @cos(ang), origin[0]) orelse return null;
            const sy = snap(c[1] + rr * @sin(ang), origin[1]) orelse return null;
            try samples.append(a, .{ .x = sx, .y = sy });
        }
    }
    return try convexHull(a, samples.items);
}

/// Axis-aligned overlap of two mm rectangles, each `[x0, y0, x1, y1]`.
fn rectsOverlap(a: [4]f64, b: [4]f64) bool {
    return a[0] <= b[2] and b[0] <= a[2] and a[1] <= b[3] and b[1] <= a[3];
}

/// The four inflated core corners of a pad in mm (its exact outline when present,
/// else its rotated bounding box).
fn padCore(a: std.mem.Allocator, o: router.PadObs) std.mem.Allocator.Error![]const [2]f64 {
    if (o.poly.len >= 3) return o.poly;
    const box = try a.alloc([2]f64, 4);
    box[0] = .{ o.x0, o.y0 };
    box[1] = .{ o.x1, o.y0 };
    box[2] = .{ o.x1, o.y1 };
    box[3] = .{ o.x0, o.y1 };
    return box;
}

/// Build one inflated CCW polygon per foreign obstacle that reaches the window
/// on the routed layer. `need` = track_width/2 + clearance + ε_safety.
fn buildObstacles(a: std.mem.Allocator, in: Field, need: f64, origin: [2]f64) std.mem.Allocator.Error!Built {
    var out: std.ArrayList([]const Point) = .empty;
    var who: std.ArrayList(Owner) = .empty;
    const r = in.rect;
    for (in.obstacles.pads, 0..) |o, i| {
        if (o.net == in.obstacles.skip_net) continue;
        if (!o.thru and o.layer != in.layer) continue;
        const rad = need + in.obstacles.haloOf(o.net);
        if (!rectsOverlap(.{ o.x0 - rad, o.y0 - rad, o.x1 + rad, o.y1 + rad }, .{ r.x0, r.y0, r.x1, r.y1 })) continue;
        const poly = (try inflate(a, try padCore(a, o), rad, origin)) orelse continue;
        if (poly.len < 3) continue;
        try out.append(a, poly);
        try who.append(a, .{ .kind = .pad, .net = o.net, .src = @intCast(i) });
    }
    // A zone/edge band carries no net and no width — it IS the forbidden region,
    // so it is inflated by the path's own half-width plus clearance and nothing
    // more, which is exactly the reach the caller's own point test applies.
    for (in.obstacles.keepouts, 0..) |k, i| {
        if (!k.every_layer and k.layer != in.layer) continue;
        const poly_mm = k.poly;
        if (poly_mm.len < 3) continue;
        var lo = poly_mm[0];
        var hi = poly_mm[0];
        for (poly_mm) |p| {
            lo = .{ @min(lo[0], p[0]), @min(lo[1], p[1]) };
            hi = .{ @max(hi[0], p[0]), @max(hi[1], p[1]) };
        }
        if (!rectsOverlap(.{ lo[0] - need, lo[1] - need, hi[0] + need, hi[1] + need }, .{ r.x0, r.y0, r.x1, r.y1 })) continue;
        const poly = (try inflate(a, poly_mm, need, origin)) orelse continue;
        if (poly.len < 3) continue;
        try out.append(a, poly);
        try who.append(a, .{ .kind = .keepout, .src = @intCast(i) });
    }
    for (in.obstacles.tracks, 0..) |t, i| {
        if (t.net == in.obstacles.skip_net or t.layer != in.layer) continue;
        const rad = need + t.width / 2 + in.obstacles.haloOf(t.net);
        const lo_x = @min(t.x1, t.x2);
        const lo_y = @min(t.y1, t.y2);
        const hi_x = @max(t.x1, t.x2);
        const hi_y = @max(t.y1, t.y2);
        if (!rectsOverlap(.{ lo_x - rad, lo_y - rad, hi_x + rad, hi_y + rad }, .{ r.x0, r.y0, r.x1, r.y1 })) continue;
        const core = [_][2]f64{ .{ t.x1, t.y1 }, .{ t.x2, t.y2 } };
        const poly = (try inflate(a, &core, rad, origin)) orelse continue;
        if (poly.len < 3) continue;
        try out.append(a, poly);
        try who.append(a, .{ .kind = .track, .net = t.net, .src = @intCast(i) });
    }
    for (in.obstacles.vias, 0..) |v, i| {
        if (v.net == in.obstacles.skip_net) continue;
        const rad = need + v.dia / 2 + in.obstacles.haloOf(v.net);
        if (!rectsOverlap(.{ v.x - rad, v.y - rad, v.x + rad, v.y + rad }, .{ r.x0, r.y0, r.x1, r.y1 })) continue;
        const core = [_][2]f64{.{ v.x, v.y }};
        const poly = (try inflate(a, &core, rad, origin)) orelse continue;
        if (poly.len < 3) continue;
        try out.append(a, poly);
        try who.append(a, .{ .kind = .via, .net = v.net, .src = @intCast(i) });
    }
    return .{ .polys = try out.toOwnedSlice(a), .owners = try who.toOwnedSlice(a) };
}

/// The inflated obstacle polygons and, index for index, what each came from.
const Built = struct { polys: []const []const Point, owners: []const Owner };

// ── Navmesh assembly + channel search + funnel ───────────────────────────────

/// The assembled navmesh for ONE layer: the triangulation, the (window-clamped)
/// inflated obstacle polygons, the per-triangle blocked flag, the mm origin and
/// the window corners.
///
/// Deliberately carries no terminals. One layer's free space is the same mesh
/// whichever pair of points is being joined across it, and the multi-layer
/// engine joins several pairs (terminal→via, via→via, via→terminal) over one
/// scene, so the endpoints belong to the query rather than to the mesh.
pub const Scene = struct {
    mesh: Mesh,
    obstacles: []const []const Point,
    /// Bucket index over `obstacles`, shared by the blocked classification, the
    /// line-of-sight shortcut and the wall diagnosis, so none of the three ever
    /// sweeps the whole set — and the carrier of each polygon's `Owner`, which
    /// is the record a FAILED search names its wall by.
    grid: ObGrid,
    blocked: []bool,
    origin: [2]f64,
    lo: Point,
    hi: Point,
};

/// The geometry a navmesh is built over, without the terminals: the window, the
/// signal layer, the foreign copper to clear, and the width/clearance the path
/// must keep. `Input` is this plus the two terminals — the single-layer entry
/// point — so the two can never disagree about what a layer's free space is.
pub const Field = struct {
    rect: fine_window.WindowRect,
    layer: u8,
    obstacles: Obstacles,
    track_width: f64,
    clearance: f64,
};

/// A scene plus the vertex index of each point the caller asked to be forced
/// into it (null where insertion failed — a full mesh or a spent budget).
pub const LayerScene = struct {
    scene: Scene,
    verts: []const ?u32,
};

/// The layer-geometry half of a single-layer `Input` — what a navmesh is built
/// over once the two terminals are set aside.
pub fn fieldOf(in: Input) Field {
    return .{ .rect = in.rect, .layer = in.layer, .obstacles = in.obstacles, .track_width = in.track_width, .clearance = in.clearance };
}

/// Deterministic sub-quantum jitter (nm) from a lattice index — a fixed integer
/// hash, NOT randomness — so no three Steiner points are collinear and no four
/// cocircular. Keeps the incremental Delaunay and the funnel out of the
/// degenerate (orient2d == 0 / incircle == 0) cases the raw grid triggers.
fn jitterNm(k: i64) i64 {
    return @rem(k *% jitter_mul +% jitter_add, jitter_span) - @divTrunc(jitter_span, 2);
}

/// Insert a coarse free-space lattice of Steiner points across the window (each
/// jittered off the exact grid), skipping any inside an obstacle. Purely a
/// mesh-quality aid so corridors don't neck at the window corners (buildField
/// pass 0); the funnel path itself stays sub-grid, hugging the real obstacles.
fn insertSteiner(m: *Mesh, grid: *const ObGrid, lo: Point, hi: Point, stack: *std.ArrayList(EdgeRef)) std.mem.Allocator.Error!void {
    const span = @max(hi.x - lo.x, hi.y - lo.y);
    const step = @max(@divTrunc(span, steiner_divs), steiner_min_nm);
    var iy: i64 = 0;
    var y = lo.y + step;
    while (y < hi.y) : ({
        y += step;
        iy += 1;
    }) {
        var ix: i64 = 0;
        var x = lo.x + step;
        while (x < hi.x) : ({
            x += step;
            ix += 1;
        }) {
            const p = Point{ .x = x + jitterNm(ix *% 131 +% iy), .y = y + jitterNm(iy *% 131 +% ix +% 7) };
            if (!grid.blocks(p)) _ = try insertPoint(m, p, stack);
        }
    }
}

fn pointInPoly(poly: []const Point, p: Point) bool {
    var prev = poly[poly.len - 1];
    for (poly) |cur| {
        if (orient2d(prev, cur, p) < 0) return false; // CCW poly: inside ⇒ all left/on
        prev = cur;
    }
    return true;
}

/// A uniform bucket index over the window's inflated obstacle polygons.
///
/// Both remaining whole-obstacle sweeps are quadratic without it: classifying
/// every triangle as inside/outside an obstacle is O(triangles × obstacles) —
/// 50k × 1500 on a board-scale mesh — and the line-of-sight `shortcut` asks the
/// same question once per candidate segment. Bucketing by bounding box makes
/// both proportional to the obstacles actually near the query.
///
/// Built by counting sort (two passes, no per-cell allocation) so construction
/// is O(obstacles) and the layout is deterministic.
const ObGrid = struct {
    polys: []const []const Point,
    /// What each entry of `polys` came from, index for index (see `Owner`).
    owners: []const Owner,
    lo: Point,
    cw: i64,
    ch: i64,
    nx: usize,
    ny: usize,
    /// `nx*ny + 1` offsets into `items` (cell c owns `items[start[c]..start[c+1]]`).
    start: []const usize,
    items: []const u32,

    fn cellX(g: *const ObGrid, x: i64) usize {
        const i = @divFloor(x - g.lo.x, g.cw);
        return @intCast(std.math.clamp(i, 0, @as(i64, @intCast(g.nx - 1))));
    }
    fn cellY(g: *const ObGrid, y: i64) usize {
        const i = @divFloor(y - g.lo.y, g.ch);
        return @intCast(std.math.clamp(i, 0, @as(i64, @intCast(g.ny - 1))));
    }

    /// True when `p` lies inside any obstacle.
    fn blocks(g: *const ObGrid, p: Point) bool {
        const c = g.cellY(p.y) * g.nx + g.cellX(p.x);
        for (g.items[g.start[c]..g.start[c + 1]]) |pi| {
            if (pointInPoly(g.polys[pi], p)) return true;
        }
        return false;
    }

    /// True when segment `u`→`v` crosses any obstacle boundary. Visits the cells
    /// the segment's own band covers rather than the whole grid: the major axis
    /// is stepped one cell at a time and the exact minor-axis range of that
    /// slab, widened by one cell, is scanned. Widening makes the cell set a
    /// conservative SUPERSET of the crossed cells, so a candidate obstacle can
    /// never be missed by a rounding error — the query only ever over-reports
    /// work, never under-reports a crossing.
    fn segHits(g: *const ObGrid, u: Point, v: Point) bool {
        const ux: f64 = @floatFromInt(u.x);
        const uy: f64 = @floatFromInt(u.y);
        const vx: f64 = @floatFromInt(v.x);
        const vy: f64 = @floatFromInt(v.y);
        const x_major = @abs(vx - ux) >= @abs(vy - uy);
        const a_lo = if (x_major) g.cellX(@min(u.x, v.x)) else g.cellY(@min(u.y, v.y));
        const a_hi = if (x_major) g.cellX(@max(u.x, v.x)) else g.cellY(@max(u.y, v.y));
        var ai = a_lo;
        while (ai <= a_hi) : (ai += 1) {
            const span = g.slabRange(ai, x_major, .{ ux, uy }, .{ vx, vy });
            var bi = span[0];
            while (bi <= span[1]) : (bi += 1) {
                const c = if (x_major) bi * g.nx + ai else ai * g.nx + bi;
                for (g.items[g.start[c]..g.start[c + 1]]) |pi| {
                    const poly = g.polys[pi];
                    for (0..poly.len) |k| {
                        if (segCross(u, v, poly[k], poly[(k + 1) % poly.len])) return true;
                    }
                }
            }
        }
        return false;
    }

    /// Minor-axis cell range (inclusive, widened by one) the segment occupies in
    /// major-axis slab `ai`.
    fn slabRange(g: *const ObGrid, ai: usize, x_major: bool, u: [2]f64, v: [2]f64) [2]usize {
        const cell: f64 = @floatFromInt(if (x_major) g.cw else g.ch);
        const origin: f64 = @floatFromInt(if (x_major) g.lo.x else g.lo.y);
        const s0 = origin + @as(f64, @floatFromInt(ai)) * cell;
        const along_u = if (x_major) u[0] else u[1];
        const along_v = if (x_major) v[0] else v[1];
        const d = along_v - along_u;
        const other_u = if (x_major) u[1] else u[0];
        const other_v = if (x_major) v[1] else v[0];
        var q0 = other_u;
        var q1 = other_v;
        if (@abs(d) > 1e-9) {
            const t0 = std.math.clamp((s0 - along_u) / d, 0, 1);
            const t1 = std.math.clamp((s0 + cell - along_u) / d, 0, 1);
            q0 = other_u + t0 * (other_v - other_u);
            q1 = other_u + t1 * (other_v - other_u);
        }
        const nmax = if (x_major) g.ny else g.nx;
        const lo_i = g.crossCell(@min(q0, q1), x_major);
        const hi_i = g.crossCell(@max(q0, q1), x_major);
        return .{ lo_i -| 1, @min(hi_i + 1, nmax - 1) };
    }

    fn crossCell(g: *const ObGrid, q: f64, x_major: bool) usize {
        const qi = numeric.checkedInt(i64, q) orelse 0;
        return if (x_major) g.cellY(qi) else g.cellX(qi);
    }
};

/// Bucket `polys` into a `grid_divs`² index over the window `lo`..`hi`.
fn buildObGrid(
    a: std.mem.Allocator,
    polys: []const []const Point,
    owners: []const Owner,
    lo: Point,
    hi: Point,
) std.mem.Allocator.Error!ObGrid {
    const nx = grid_divs;
    const ny = grid_divs;
    var g = ObGrid{
        .polys = polys,
        .owners = owners,
        .lo = lo,
        .cw = @max(@divTrunc(hi.x - lo.x, @as(i64, @intCast(nx))) + 1, 1),
        .ch = @max(@divTrunc(hi.y - lo.y, @as(i64, @intCast(ny))) + 1, 1),
        .nx = nx,
        .ny = ny,
        .start = &.{},
        .items = &.{},
    };
    const counts = try a.alloc(usize, nx * ny + 1);
    @memset(counts, 0);
    for (polys) |poly| {
        const box = polyCells(&g, poly);
        for (box[1]..box[3] + 1) |iy| {
            for (box[0]..box[2] + 1) |ix| counts[iy * nx + ix] += 1;
        }
    }
    var total: usize = 0;
    for (counts) |*c| {
        const n = c.*;
        c.* = total;
        total += n;
    }
    const items = try a.alloc(u32, total);
    const cursor = try a.alloc(usize, nx * ny);
    for (0..nx * ny) |i| cursor[i] = counts[i];
    for (polys, 0..) |poly, pi| {
        const box = polyCells(&g, poly);
        for (box[1]..box[3] + 1) |iy| {
            for (box[0]..box[2] + 1) |ix| {
                items[cursor[iy * nx + ix]] = @intCast(pi);
                cursor[iy * nx + ix] += 1;
            }
        }
    }
    g.start = counts;
    g.items = items;
    return g;
}

/// A polygon's inclusive cell box `{x0, y0, x1, y1}`.
fn polyCells(g: *const ObGrid, poly: []const Point) [4]usize {
    var lo = poly[0];
    var hi = poly[0];
    for (poly) |p| {
        lo.x = @min(lo.x, p.x);
        lo.y = @min(lo.y, p.y);
        hi.x = @max(hi.x, p.x);
        hi.y = @max(hi.y, p.y);
    }
    return .{ g.cellX(lo.x), g.cellY(lo.y), g.cellX(hi.x), g.cellY(hi.y) };
}

fn centroid(m: *Mesh, t: Tri) Point {
    return .{
        .x = @divTrunc(m.pt(t.v[0]).x + m.pt(t.v[1]).x + m.pt(t.v[2]).x, 3),
        .y = @divTrunc(m.pt(t.v[0]).y + m.pt(t.v[1]).y + m.pt(t.v[2]).y, 3),
    };
}

/// Assemble the navmesh for `in`. The window rectangle is the HARD hull — every
/// obstacle vertex and terminal is clamped strictly inside it, so an obstacle
/// that spans the window (a wall) leaves no channel and the route fails, and a
/// path can never wander off the window (or, on an outlined board, off the
/// board). Null when the window degenerates or a terminal cannot be inserted.
/// Assemble the navmesh for `in`, forcing every point of `points` in as a
/// vertex and reporting where each landed. The window rectangle is the HARD hull
/// — every obstacle vertex and requested point is clamped strictly inside it, so
/// an obstacle that spans the window (a wall) leaves no channel and a path can
/// never wander off the window (or, on an outlined board, off the board). Null
/// when the window degenerates or the meshing budget is spent.
pub fn buildField(a: std.mem.Allocator, in: Field, points: []const [2]f64) std.mem.Allocator.Error!?LayerScene {
    const need = in.track_width / 2 + in.clearance + eps_safety_mm;
    const origin = [2]f64{ in.rect.x0, in.rect.y0 };
    const lo = worldPoint(.{ in.rect.x0, in.rect.y0 }, origin) orelse return null;
    const hi = worldPoint(.{ in.rect.x1, in.rect.y1 }, origin) orelse return null;
    if (hi.x - lo.x < 4 or hi.y - lo.y < 4) return null; // degenerate window
    const built = try buildObstacles(a, in, need, origin);
    const obstacles = try clampPolys(a, built.polys, lo, hi);
    const grid = try buildObGrid(a, obstacles, built.owners, lo, hi);
    var mesh = try initMesh(a, lo, hi);
    var stack: std.ArrayList(EdgeRef) = .empty;
    // Pass 0: a coarse lattice of free-space Steiner points. Without them the
    // window corners are huge triangle fans and a corridor can NECK at a corner,
    // forcing the funnel path to detour there. These only improve mesh quality —
    // the funnel still hugs the exact inflated obstacle boundaries sub-grid, so
    // no grid-quantization limit returns. Points inside an obstacle are skipped.
    try insertSteiner(&mesh, &grid, lo, hi, &stack);
    // Pass 1: insert EVERY point (obstacle vertices + the caller's) into the
    // plain Delaunay triangulation. Constraints must follow all point inserts.
    const none: u32 = std.math.maxInt(u32);
    const poly_idx = try a.alloc([]u32, obstacles.len);
    for (obstacles, 0..) |poly, pi| {
        const idxs = try a.alloc(u32, poly.len);
        for (poly, 0..) |vtx, j| idxs[j] = (try insertPoint(&mesh, vtx, &stack)) orelse none;
        poly_idx[pi] = idxs;
    }
    const verts = try a.alloc(?u32, points.len);
    for (points, 0..) |q, i| {
        const lp = clampPt(worldPoint(q, origin) orelse {
            verts[i] = null;
            continue;
        }, lo, hi);
        verts[i] = try insertPoint(&mesh, lp, &stack);
    }
    // Pass 2: force each obstacle's boundary edges as constraints (now safe —
    // no more locate walks happen after the mesh stops being Delaunay).
    for (obstacles, 0..) |poly, pi| {
        const idxs = poly_idx[pi];
        for (0..poly.len) |j| {
            const va = idxs[j];
            const vb = idxs[(j + 1) % poly.len];
            if (va != none and vb != none) try forceEdge(&mesh, va, vb);
        }
    }
    // Budget spent during meshing → give up (best-effort null) rather than
    // classify a corridor off a half-built, possibly-degenerate mesh.
    if (mesh.exhausted()) return null;
    const blocked = try a.alloc(bool, mesh.tris.items.len);
    for (mesh.tris.items, 0..) |t, i| {
        const c = centroid(&mesh, t);
        blocked[i] = grid.blocks(c) or inHullSeal(c, lo, hi);
    }
    return .{
        .scene = .{
            .mesh = mesh,
            .obstacles = obstacles,
            .grid = grid,
            .blocked = blocked,
            .origin = origin,
            .lo = lo,
            .hi = hi,
        },
        .verts = verts,
    };
}

/// True when `c` lies in the sealed ribbon hugging the window hull.
fn inHullSeal(c: Point, lo: Point, hi: Point) bool {
    return c.x - lo.x < hull_seal_nm or hi.x - c.x < hull_seal_nm or
        c.y - lo.y < hull_seal_nm or hi.y - c.y < hull_seal_nm;
}

/// The lattice point a world mm point occupies in `sc` (clamped into the window).
fn scenePoint(sc: *const Scene, p: [2]f64) ?Point {
    return clampPt(worldPoint(p, sc.origin) orelse return null, sc.lo, sc.hi);
}

fn worldPoint(p: [2]f64, origin: [2]f64) ?Point {
    return .{ .x = snap(p[0], origin[0]) orelse return null, .y = snap(p[1], origin[1]) orelse return null };
}

/// Clamp `p` one lattice step inside the window rectangle `lo`..`hi`.
fn clampPt(p: Point, lo: Point, hi: Point) Point {
    return .{ .x = std.math.clamp(p.x, lo.x + 1, hi.x - 1), .y = std.math.clamp(p.y, lo.y + 1, hi.y - 1) };
}

/// Clamp every vertex of every obstacle polygon into the window interior so the
/// window edge caps them (an obstacle poking past the window is trimmed to it).
fn clampPolys(a: std.mem.Allocator, polys: []const []const Point, lo: Point, hi: Point) std.mem.Allocator.Error![]const []const Point {
    const out = try a.alloc([]const Point, polys.len);
    for (polys, 0..) |poly, i| {
        const cp = try a.alloc(Point, poly.len);
        for (poly, 0..) |v, j| cp[j] = clampPt(v, lo, hi);
        out[i] = cp;
    }
    return out;
}

const QItem = struct { d: f64, t: u32 };
fn qLess(_: void, a: QItem, b: QItem) std.math.Order {
    const by_d = std.math.order(a.d, b.d);
    return if (by_d == .eq) std.math.order(a.t, b.t) else by_d;
}

fn hasVertex(t: Tri, vi: u32) bool {
    return t.v[0] == vi or t.v[1] == vi or t.v[2] == vi;
}

/// World midpoint (lattice units, as f64) of edge-slot `e` of triangle `t` — the
/// portal centre the channel search hops between.
fn edgeMid(sc: *Scene, t: Tri, e: usize) [2]f64 {
    const p1 = sc.mesh.pt(edgeTail(t, e));
    const p2 = sc.mesh.pt(edgeHead(t, e));
    return .{ @as(f64, @floatFromInt(p1.x + p2.x)) / 2.0, @as(f64, @floatFromInt(p1.y + p2.y)) / 2.0 };
}

/// Dijkstra over the free-triangle dual (portal-crossing steps only, never a
/// constraint or hull edge), from every free triangle on the start terminal to
/// the nearest free triangle on the goal terminal. The step cost is the distance
/// between successive PORTAL MIDPOINTS (the corridor centre-line), so the channel
/// tracks the geodesic instead of wandering through fat corner triangles the way
/// a centroid-hop metric does. Returns the triangle channel, or null when the
/// terminal is sealed or no free corridor connects them.
fn channel(a: std.mem.Allocator, sc: *Scene, start_i: u32, goal_i: u32, start_pt: Point) std.mem.Allocator.Error!?[]const u32 {
    const n = sc.mesh.tris.items.len;
    const dist = try a.alloc(f64, n);
    const prev = try a.alloc(i64, n);
    const emid = try a.alloc([2]f64, n); // portal midpoint each triangle was entered by
    @memset(dist, std.math.inf(f64));
    @memset(prev, -1);
    const sp = [2]f64{ @floatFromInt(start_pt.x), @floatFromInt(start_pt.y) };
    var pq = std.PriorityQueue(QItem, void, qLess).initContext({});
    defer pq.deinit(a);
    var seeded = false;
    for (sc.mesh.tris.items, 0..) |t, i| {
        if (sc.blocked[i] or !hasVertex(t, start_i)) continue;
        dist[i] = 0;
        prev[i] = -2; // source marker
        emid[i] = sp;
        try pq.push(a, .{ .d = 0, .t = @intCast(i) });
        seeded = true;
    }
    if (!seeded) return null;
    while (pq.pop()) |it| {
        if (it.d > dist[it.t]) continue;
        const t = sc.mesh.tris.items[it.t];
        if (hasVertex(t, goal_i)) return try tracePath(a, prev, it.t);
        for (0..3) |e| {
            if (t.adj[e] < 0 or sc.mesh.isCon(edgeTail(t, e), edgeHead(t, e))) continue;
            const nt: u32 = @intCast(t.adj[e]);
            if (sc.blocked[nt]) continue;
            const mp = edgeMid(sc, t, e);
            const nd = it.d + std.math.hypot(emid[it.t][0] - mp[0], emid[it.t][1] - mp[1]);
            if (nd < dist[nt]) {
                dist[nt] = nd;
                prev[nt] = @intCast(it.t);
                emid[nt] = mp;
                try pq.push(a, .{ .d = nd, .t = nt });
            }
        }
    }
    return null;
}

fn tracePath(a: std.mem.Allocator, prev: []const i64, goal: u32) std.mem.Allocator.Error![]const u32 {
    var rev: std.ArrayList(u32) = .empty;
    var cur: i64 = goal;
    while (cur >= 0) {
        try rev.append(a, @intCast(cur));
        if (prev[@intCast(cur)] < 0) break; // reached a source
        cur = prev[@intCast(cur)];
    }
    const path = try a.alloc(u32, rev.items.len);
    for (rev.items, 0..) |v, i| path[path.len - 1 - i] = v;
    return path;
}

/// The shared edge-slot of `t` whose neighbour is `nt`.
fn sharedEdge(t: Tri, nt: u32) usize {
    if (t.adj[0] == nt) return 0;
    if (t.adj[1] == nt) return 1;
    return 2;
}

/// Simple Stupid Funnel over the triangle channel: walk the left/right portal
/// vertices tightening the funnel, emitting a taut corner whenever a side would
/// cross the apex. Endpoints are the exact terminals. Returns the lattice path.
fn funnel(a: std.mem.Allocator, sc: *Scene, chan: []const u32, start: Point, goal: Point) std.mem.Allocator.Error![]const Point {
    var lefts: std.ArrayList(Point) = .empty;
    var rights: std.ArrayList(Point) = .empty;
    try lefts.append(a, start);
    try rights.append(a, start);
    for (0..chan.len -| 1) |k| {
        const t = sc.mesh.tris.items[chan[k]];
        const e = sharedEdge(t, chan[k + 1]);
        try lefts.append(a, sc.mesh.pt(edgeHead(t, e)));
        try rights.append(a, sc.mesh.pt(edgeTail(t, e)));
    }
    try lefts.append(a, goal);
    try rights.append(a, goal);
    return stringPull(a, lefts.items, rights.items);
}

/// Append `p` unless it repeats the last emitted vertex (a degenerate zero-length
/// hop the apex-switch can produce on collinear portals).
fn pushPt(a: std.mem.Allocator, out: *std.ArrayList(Point), p: Point) std.mem.Allocator.Error!void {
    if (out.items.len > 0 and vEq(out.items[out.items.len - 1], p)) return;
    try out.append(a, p);
}

fn stringPull(a: std.mem.Allocator, lefts: []const Point, rights: []const Point) std.mem.Allocator.Error![]const Point {
    var out: std.ArrayList(Point) = .empty;
    var apex = lefts[0];
    var pl = lefts[0];
    var pr = rights[0];
    var ai: usize = 0;
    var li: usize = 0;
    var ri: usize = 0;
    try pushPt(a, &out, apex);
    var i: usize = 1;
    while (i < lefts.len) {
        const l = lefts[i];
        const r = rights[i];
        if (orient2d(apex, pr, r) <= 0) {
            if (vEq(apex, pr) or orient2d(apex, pl, r) > 0) {
                pr = r;
                ri = i;
            } else {
                try pushPt(a, &out, pl);
                apex = pl;
                ai = li;
                pl = apex;
                pr = apex;
                li = ai;
                ri = ai;
                i = ai + 1;
                continue;
            }
        }
        if (orient2d(apex, pl, l) >= 0) {
            if (vEq(apex, pl) or orient2d(apex, pr, l) < 0) {
                pl = l;
                li = i;
            } else {
                try pushPt(a, &out, pr);
                apex = pr;
                ai = ri;
                pl = apex;
                pr = apex;
                li = ai;
                ri = ai;
                i = ai + 1;
                continue;
            }
        }
        i += 1;
    }
    try pushPt(a, &out, lefts[lefts.len - 1]);
    return out.toOwnedSlice(a);
}

/// True when segment `u`→`v` stays out of every inflated obstacle: it crosses no
/// obstacle-boundary edge. Both endpoints are free-space points, and the
/// obstacles are convex, so no boundary crossing ⇒ the whole segment is clear
/// (≥ the clearance from the pad, since the polygons are Minkowski-inflated).
fn segFree(u: Point, v: Point, grid: *const ObGrid) bool {
    return !grid.segHits(u, v);
}

/// Line-of-sight string-pull: greedily replace each maximal run of path points
/// with the direct segment to the farthest point still clear of every obstacle.
/// Turns any valid in-corridor polyline (however the channel snaked) into the
/// taut geodesic that only bends at obstacle corners.
fn shortcut(a: std.mem.Allocator, path: []const Point, grid: *const ObGrid) std.mem.Allocator.Error![]const Point {
    if (path.len <= 2) return path;
    var out: std.ArrayList(Point) = .empty;
    try out.append(a, path[0]);
    var i: usize = 0;
    while (i + 1 < path.len) {
        var j = path.len - 1;
        while (j > i + 1 and !segFree(path[i], path[j], grid)) j -= 1;
        try out.append(a, path[j]);
        i = j;
    }
    return out.toOwnedSlice(a);
}

/// Route the two terminals of `in` through the free space between the inflated
/// obstacles, returning a taut polyline (world mm) or null when no legal channel
/// exists. The funnel yields an in-corridor path; a line-of-sight shortcut pulls
/// it taut. The endpoints are the exact terminals; the router emits consecutive
/// pairs as tracks and DRC-gates the result.
pub fn route(a: std.mem.Allocator, in: Input) std.mem.Allocator.Error!?[]const [2]f64 {
    const built = (try buildField(a, fieldOf(in), &.{ in.start, in.goal })) orelse return null;
    var sc = built.scene;
    const si = built.verts[0] orelse return null;
    const gi = built.verts[1] orelse return null;
    const sp = scenePoint(&sc, in.start) orelse return null;
    const gp = scenePoint(&sc, in.goal) orelse return null;
    const chan = (try channel(a, &sc, si, gi, sp)) orelse return null;
    return try tautWorld(a, &sc, chan, .{ .pt = sp, .mm = in.start }, .{ .pt = gp, .mm = in.goal });
}

/// One end of a funnel query: the lattice point inside the scene and the exact
/// world mm the emitted polyline must terminate at.
const End = struct { pt: Point, mm: [2]f64 };

/// Funnel `chan` between `from` and `to`, pull it taut, and return it in world
/// mm with both endpoints pinned exactly. Null when nothing survives.
fn tautWorld(a: std.mem.Allocator, sc: *Scene, chan: []const u32, from: End, to: End) std.mem.Allocator.Error!?[]const [2]f64 {
    const raw = try funnel(a, sc, chan, from.pt, to.pt);
    const path = try shortcut(a, raw, &sc.grid);
    if (path.len < 2) return null;
    const out = try a.alloc([2]f64, path.len);
    for (path, 0..) |p, i| {
        out[i] = .{ sc.origin[0] + @as(f64, @floatFromInt(p.x)) / nm_per_mm, sc.origin[1] + @as(f64, @floatFromInt(p.y)) / nm_per_mm };
    }
    out[0] = from.mm;
    out[out.len - 1] = to.mm;
    return out;
}

/// A crossable door out of a triangle: the neighbour it leads to and the shared
/// edge's midpoint in world mm — the waypoint a channel search hops between.
pub const Portal = struct { to: u32, mid: [2]f64 };

/// Triangles in a layer's navmesh. Node indices for a search are `0..triCount`.
pub fn triCount(sc: *const Scene) usize {
    return sc.mesh.tris.items.len;
}

/// True when triangle `i` is free space rather than obstacle interior.
pub fn triFree(sc: *const Scene, i: u32) bool {
    return !sc.blocked[i];
}

/// The portal out of triangle `i` across edge-slot `e`, or null where that edge
/// is the window hull or an obstacle boundary — a constraint edge is a wall,
/// never a door, which is what keeps a channel inside the free space.
pub fn portalOut(sc: *const Scene, i: u32, e: usize) ?Portal {
    const t = sc.mesh.tris.items[i];
    if (t.adj[e] < 0) return null;
    if (sc.mesh.isCon(edgeTail(t, e), edgeHead(t, e))) return null;
    const p1 = sc.mesh.pt(edgeTail(t, e));
    const p2 = sc.mesh.pt(edgeHead(t, e));
    return .{ .to = @intCast(t.adj[e]), .mid = .{
        sc.origin[0] + @as(f64, @floatFromInt(p1.x + p2.x)) / (2.0 * nm_per_mm),
        sc.origin[1] + @as(f64, @floatFromInt(p1.y + p2.y)) / (2.0 * nm_per_mm),
    } };
}

/// Triangle `t`'s centroid in world millimetres — where on the board it sits.
///
/// The mesh searches never need it (they hop portal midpoints, which track the
/// corridor centre-line), but a diagnosis that names a wall has to say WHERE,
/// and the centroid is the exact point the free/blocked classification was made
/// at (see `triBlockers`).
pub fn triCenter(sc: *Scene, t: u32) [2]f64 {
    const c = centroid(&sc.mesh, sc.mesh.tris.items[t]);
    return .{
        sc.origin[0] + @as(f64, @floatFromInt(c.x)) / nm_per_mm,
        sc.origin[1] + @as(f64, @floatFromInt(c.y)) / nm_per_mm,
    };
}

/// The neighbour across edge-slot `e` of triangle `i` WHATEVER that edge is —
/// an open portal, an obstacle boundary, or the seam between two obstacles.
///
/// The routing searches must never use it: a constraint edge is a wall, and
/// `portalOut` returning null across one is what keeps a channel inside the free
/// space. This is the DIAGNOSIS door. When no free corridor joins two terminals,
/// the only way to say what stands between them is to walk through the walls and
/// name what was crossed, which is exactly what a min-cut across the free space
/// is (`cdt_layers.routeDiagnosed`). Nothing it finds may ever become copper.
pub fn wallOut(sc: *const Scene, i: u32, e: usize) ?Portal {
    const t = sc.mesh.tris.items[i];
    if (t.adj[e] < 0) return null;
    const p1 = sc.mesh.pt(edgeTail(t, e));
    const p2 = sc.mesh.pt(edgeHead(t, e));
    return .{ .to = @intCast(t.adj[e]), .mid = .{
        sc.origin[0] + @as(f64, @floatFromInt(p1.x + p2.x)) / (2.0 * nm_per_mm),
        sc.origin[1] + @as(f64, @floatFromInt(p1.y + p2.y)) / (2.0 * nm_per_mm),
    } };
}

/// Every obstacle whose inflated polygon covers triangle `t` — the owners of the
/// copper that made it un-free, deduplicated and in scene order.
///
/// The triangle's CENTROID is the probe, because that is the exact point
/// `buildField` classified it by: a triangle is blocked when its centroid lies
/// inside some obstacle, so asking which obstacles contain that centroid asks
/// the same question that produced the flag rather than a second one that could
/// disagree with it. A triangle blocked only by the window's own hull seal is
/// owned by nobody and comes back empty.
pub fn triBlockers(a: std.mem.Allocator, sc: *Scene, t: u32) std.mem.Allocator.Error![]const Owner {
    if (t >= sc.mesh.tris.items.len) return &.{};
    const c = centroid(&sc.mesh, sc.mesh.tris.items[t]);
    const cell = sc.grid.cellY(c.y) * sc.grid.nx + sc.grid.cellX(c.x);
    var out: std.ArrayList(Owner) = .empty;
    for (sc.grid.items[sc.grid.start[cell]..sc.grid.start[cell + 1]]) |pi| {
        if (pi >= sc.grid.owners.len) continue;
        if (!pointInPoly(sc.grid.polys[pi], c)) continue;
        try out.append(a, sc.grid.owners[pi]);
    }
    return out.toOwnedSlice(a);
}

/// One obstacle's own BODY, as a pinch diagnosis measures it: the copper (or
/// keepout) outline in world millimetres, and the extra radius that body demands
/// beyond a path's own half-width and clearance.
///
/// The scene's polygons are already inflated by both, which is why they overlap
/// wherever no path fits — so a gap read off them would be a penetration depth
/// rather than the physical clearance a reader wants. The body is the same
/// geometry `buildObstacles` inflated, taken back off the caller's own slices by
/// the owner's `src` index, so the two can never describe different copper.
pub const Body = struct { core: []const [2]f64, extra: f64 };

/// The body of `o` on `in`'s own obstacle slices, or null when the index does
/// not resolve (a scene read against a different field than it was built from).
pub fn ownerBody(a: std.mem.Allocator, in: Field, o: Owner) std.mem.Allocator.Error!?Body {
    const i: usize = o.src;
    switch (o.kind) {
        .pad => {
            if (i >= in.obstacles.pads.len) return null;
            const pad = in.obstacles.pads[i];
            return .{ .core = try padCore(a, pad), .extra = in.obstacles.haloOf(pad.net) };
        },
        .track => {
            if (i >= in.obstacles.tracks.len) return null;
            const t = in.obstacles.tracks[i];
            const core = try a.alloc([2]f64, 2);
            core[0] = .{ t.x1, t.y1 };
            core[1] = .{ t.x2, t.y2 };
            return .{ .core = core, .extra = t.width / 2 + in.obstacles.haloOf(t.net) };
        },
        .via => {
            if (i >= in.obstacles.vias.len) return null;
            const v = in.obstacles.vias[i];
            const core = try a.alloc([2]f64, 1);
            core[0] = .{ v.x, v.y };
            return .{ .core = core, .extra = v.dia / 2 + in.obstacles.haloOf(v.net) };
        },
        .keepout => {
            if (i >= in.obstacles.keepouts.len) return null;
            return .{ .core = in.obstacles.keepouts[i].poly, .extra = 0 };
        },
    }
}

/// The clear millimetres between two obstacles' bodies — what a path squeezing
/// between them would actually have to fit through. Null when either body does
/// not resolve; negative is possible and honest (two bodies that overlap, e.g. a
/// pad and the track landing on it).
pub fn ownerGap(a: std.mem.Allocator, in: Field, x: Owner, y: Owner) std.mem.Allocator.Error!?f64 {
    const bx = (try ownerBody(a, in, x)) orelse return null;
    const by = (try ownerBody(a, in, y)) orelse return null;
    return setDist(bx.core, by.core) - bx.extra - by.extra;
}

/// The millimetres a path of this field's own width needs between two bodies:
/// its trace plus a clearance either side. The `need` half of a pinch verdict.
pub fn requiredGap(in: Field) f64 {
    return in.track_width + 2 * in.clearance;
}

/// Closest approach between two point sets read as outlines — a point, a
/// segment, or a closed polygon, whichever each set's length makes it.
fn setDist(x: []const [2]f64, y: []const [2]f64) f64 {
    if (x.len == 0 or y.len == 0) return 0;
    var best = std.math.inf(f64);
    for (0..edgeCount(x)) |i| {
        const a0 = x[i];
        const a1 = x[(i + 1) % x.len];
        for (0..edgeCount(y)) |j| {
            best = @min(best, segDist(a0, a1, y[j], y[(j + 1) % y.len]));
        }
    }
    return if (std.math.isInf(best)) 0 else best;
}

/// How many edges an outline of `n` points has: none for a single point (its one
/// "edge" is the point itself), one for a segment, and one per vertex once it
/// closes.
fn edgeCount(pts: []const [2]f64) usize {
    return switch (pts.len) {
        0 => 0,
        1 => 1,
        2 => 1,
        else => pts.len,
    };
}

/// Closest approach between two segments (either may be degenerate to a point).
fn segDist(a0: [2]f64, a1: [2]f64, b0: [2]f64, b1: [2]f64) f64 {
    return @min(
        @min(ptSegDist(a0, b0, b1), ptSegDist(a1, b0, b1)),
        @min(ptSegDist(b0, a0, a1), ptSegDist(b1, a0, a1)),
    );
}

/// Distance from `p` to the segment `a`→`b`.
fn ptSegDist(p: [2]f64, a: [2]f64, b: [2]f64) f64 {
    const vx = b[0] - a[0];
    const vy = b[1] - a[1];
    const len2 = vx * vx + vy * vy;
    if (!(len2 > 0)) return std.math.hypot(p[0] - a[0], p[1] - a[1]);
    const t = std.math.clamp(((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / len2, 0, 1);
    return std.math.hypot(p[0] - (a[0] + t * vx), p[1] - (a[1] + t * vy));
}

/// Every triangle incident to vertex `vi` — the fan a route may leave a terminal
/// or a via site through, in the rotation's deterministic order.
pub fn fanTris(a: std.mem.Allocator, sc: *Scene, vi: u32) std.mem.Allocator.Error![]const u32 {
    var out: std.ArrayList(u32) = .empty;
    var fan = Fan.around(&sc.mesh, vi);
    while (fan.next()) |ti| try out.append(a, @intCast(ti));
    return out.toOwnedSlice(a);
}

/// Funnel the triangle run `chan` between two world-mm points and pull it taut —
/// the same geodesic `route` extracts, over a channel the caller already has.
pub fn tautLeg(a: std.mem.Allocator, sc: *Scene, chan: []const u32, from: [2]f64, to: [2]f64) std.mem.Allocator.Error!?[]const [2]f64 {
    const fp = scenePoint(sc, from) orelse return null;
    const tp = scenePoint(sc, to) orelse return null;
    return try tautWorld(a, sc, chan, .{ .pt = fp, .mm = from }, .{ .pt = tp, .mm = to });
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// Test fixture: the two-terminal scene `route` builds, without the routing.
fn buildScene(a: std.mem.Allocator, in: Input) std.mem.Allocator.Error!?Scene {
    const built = (try buildField(a, fieldOf(in), &.{ in.start, in.goal })) orelse return null;
    return built.scene;
}

/// Minimum clearance (mm) from any point of `path` to any foreign pad — the
/// DRC-parity proxy the router's `fineCopperClean` enforces board-side.
fn minPadGap(path: []const [2]f64, pads: []const router.PadObs, skip: i32) f64 {
    var best = std.math.inf(f64);
    for (0..path.len -| 1) |i| {
        const a = path[i];
        const b = path[i + 1];
        var s: usize = 0;
        while (s <= 40) : (s += 1) {
            const f = @as(f64, @floatFromInt(s)) / 40.0;
            const px = a[0] + f * (b[0] - a[0]);
            const py = a[1] + f * (b[1] - a[1]);
            for (pads) |o| {
                if (o.net == skip) continue;
                const dx = @max(@max(o.x0 - px, px - o.x1), 0);
                const dy = @max(@max(o.y0 - py, py - o.y1), 0);
                best = @min(best, @sqrt(dx * dx + dy * dy));
            }
        }
    }
    return best;
}

// spec: placement/router - the CDT rescue threads a sub-grid pocket the coarse grid pitch cannot represent
test "CDT threads a sub-grid channel and keeps DRC clearance" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // Two blockers leave a 0.5 mm gap centred at x=5. A DRC-legal 0.127 track
    // needs 0.127+2·0.127 = 0.381 mm — the gap fits it — yet the maze pitch is
    // 0.254 mm and the pads are off-grid, so no lattice node lands in the lane.
    const pads = [_]router.PadObs{
        .{ .x0 = 3.0, .y0 = 4.75, .x1 = 4.75, .y1 = 5.25, .net = 1 },
        .{ .x0 = 5.25, .y0 = 4.75, .x1 = 7.0, .y1 = 5.25, .net = 2 },
    };
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = &pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 5.0, 2.0 },
        .goal = .{ 5.0, 8.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    const path = (try route(a, in)) orelse return error.NoPath;
    try testing.expect(path.len >= 2);
    try testing.expectApproxEqAbs(@as(f64, 5.0), path[0][0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8.0), path[path.len - 1][1], 1e-9);
    // Every point clears both pads by ≥ track/2 + clearance (the DRC rule).
    try testing.expect(minPadGap(path, &pads, 0) >= 0.127 / 2.0 + 0.127);
}

/// The sub-grid-lane scene above, as a reusable base: two pads leaving a 0.5 mm
/// lane at x = 5, and a route that has to cross it.
fn laneInput(pads: []const router.PadObs) Input {
    return .{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 5.0, 2.0 },
        .goal = .{ 5.0, 8.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
}

/// The two 0.5 mm-lane blockers, on nets 1 and 2.
fn lanePads() [2]router.PadObs {
    return .{
        .{ .x0 = 3.0, .y0 = 4.75, .x1 = 4.75, .y1 = 5.25, .net = 1 },
        .{ .x0 = 5.25, .y0 = 4.75, .x1 = 7.0, .y1 = 5.25, .net = 2 },
    };
}

// spec: placement/router - a CDT obstacle whose net declares a keepout halo is inflated by it, so the path keeps the halo distance the emitting caller's own clearance gate measures rather than the ordinary clearance the mesh used to model
test "a keepout halo widens the berth a CDT path keeps from its owner" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const pads = lanePads();
    const need = 0.127 / 2.0 + 0.127;
    const halo_mm = 0.4;
    // Without a halo the taut path threads the 0.5 mm lane, hugging net 1's pad
    // at about the ordinary clearance — which is all the mesh knew to keep.
    const plain = (try route(a, laneInput(&pads))) orelse return error.NoPath;
    const plain_gap = minPadGap(plain, pads[0..1], 0);
    try testing.expect(plain_gap >= need);
    try testing.expect(plain_gap < need + halo_mm);
    // Net 1 declares a 0.4 mm halo over ordinary clearance. The lane no longer
    // fits, so the path must go around rather than hand back copper the caller's
    // gate would refuse — and it keeps the FULL halo distance where it passes.
    var halo = [_]f64{ 0, halo_mm, 0 };
    var walled = laneInput(&pads);
    walled.obstacles.halo = &halo;
    const around = (try route(a, walled)) orelse return error.NoPath;
    try testing.expect(minPadGap(around, pads[0..1], 0) >= need + halo_mm - 1e-6);
    // The halo is charged to its OWN net. Moved onto net 0 — the net being
    // routed, whose own copper is skipped entirely — the lane is open again and
    // the path threads it exactly as it did with no halo declared at all.
    halo = .{ halo_mm, 0, 0 };
    var mine = laneInput(&pads);
    mine.obstacles.halo = &halo;
    const threaded = (try route(a, mine)) orelse return error.NoPath;
    try testing.expectApproxEqAbs(plain_gap, minPadGap(threaded, pads[0..1], 0), 1e-9);
}

// spec: placement/router - a CDT keepout region blocks the free space of the layer it names, and of every layer when it is declared board-wide
test "a CDT keepout region blocks its own layer, and every layer when board-wide" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // A band across the whole window between the terminals — the shape a pour or
    // a board-edge inset takes. No copper is involved, so nothing about it is
    // skippable for belonging to the routing net.
    const band = [_][2]f64{ .{ 0, 4.6 }, .{ 10, 4.6 }, .{ 10, 5.4 }, .{ 0, 5.4 } };
    const on_layer_0 = [_]Keepout{.{ .poly = &band, .layer = 0 }};
    var blocked = laneInput(&.{});
    blocked.obstacles.keepouts = &on_layer_0;
    try testing.expect((try route(a, blocked)) == null);
    // The same region declared on ANOTHER layer leaves this one's free space
    // alone — a pour belongs to one layer and the mesh is built per layer.
    const on_layer_1 = [_]Keepout{.{ .poly = &band, .layer = 1 }};
    var elsewhere = laneInput(&.{});
    elsewhere.obstacles.keepouts = &on_layer_1;
    try testing.expect((try route(a, elsewhere)) != null);
    // Declared board-wide it blocks regardless of which layer is being meshed,
    // which is what a copper-edge inset is: not a layer's business.
    const everywhere = [_]Keepout{.{ .poly = &band, .layer = 1, .every_layer = true }};
    var universal = laneInput(&.{});
    universal.obstacles.keepouts = &everywhere;
    try testing.expect((try route(a, universal)) == null);
}

// spec: placement/router - an obstacle-free CDT window routes a straight terminal-to-terminal segment
test "CDT with no obstacles is a straight segment" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = &.{}, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 2.0, 3.0 },
        .goal = .{ 8.0, 6.0 },
        .track_width = 0.15,
        .clearance = 0.15,
    };
    const path = (try route(a, in)) orelse return error.NoPath;
    // Endpoints are exact; with no obstacle the funnel path is the straight line
    // (its length matches the terminal distance to well within a micron).
    try testing.expectApproxEqAbs(@as(f64, 2.0), path[0][0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.0), path[0][1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8.0), path[path.len - 1][0], 1e-9);
    const straight = std.math.hypot(@as(f64, 6.0), @as(f64, 3.0));
    try testing.expect(pathLen(path) >= straight - 1e-6 and pathLen(path) < straight * 1.05);
}

// spec: placement/router - a fully sealed CDT pocket yields no path
test "CDT returns null when the terminal is walled in" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // A ring of four pads seals the start terminal — no legal channel out.
    const pads = [_]router.PadObs{
        .{ .x0 = 4.6, .y0 = 4.6, .x1 = 5.4, .y1 = 4.75, .net = 1 },
        .{ .x0 = 4.6, .y0 = 5.25, .x1 = 5.4, .y1 = 5.4, .net = 1 },
        .{ .x0 = 4.6, .y0 = 4.6, .x1 = 4.75, .y1 = 5.4, .net = 1 },
        .{ .x0 = 5.25, .y0 = 4.6, .x1 = 5.4, .y1 = 5.4, .net = 1 },
    };
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = &pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 5.0, 5.0 },
        .goal = .{ 9.0, 9.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    try testing.expect((try route(a, in)) == null);
}

/// Total polyline length (mm).
fn pathLen(path: []const [2]f64) f64 {
    var sum: f64 = 0;
    for (0..path.len -| 1) |i| sum += std.math.hypot(path[i + 1][0] - path[i][0], path[i + 1][1] - path[i][1]);
    return sum;
}

// spec: placement/router - the CDT funnel detours around a single convex blocker keeping clearance
test "CDT funnel detours a single blocker taut and clear" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // One blocker straddling the straight line between the terminals: the funnel
    // must bend around it (more than a straight segment) while staying taut (a
    // short detour, not a lap of the window) and clearing the pad.
    const pads = [_]router.PadObs{
        .{ .x0 = 4.5, .y0 = 3.0, .x1 = 5.5, .y1 = 5.0, .net = 1 },
    };
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 8 },
        .layer = 0,
        .obstacles = .{ .pads = &pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 1.0, 4.0 },
        .goal = .{ 9.0, 4.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    const path = (try route(a, in)) orelse return error.NoPath;
    try testing.expect(path.len >= 3); // a genuine detour, not a straight segment
    try testing.expect(pathLen(path) > 8.0 and pathLen(path) < 9.5); // taut: barely over the 8 mm straight line
    try testing.expect(minPadGap(path, &pads, 0) >= 0.127 / 2.0 + 0.127);
}

// spec: placement/router - the CDT rescue routes deterministically across identical runs
test "CDT is deterministic across identical runs" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const pads = [_]router.PadObs{
        .{ .x0 = 3.0, .y0 = 4.75, .x1 = 4.75, .y1 = 5.25, .net = 1 },
        .{ .x0 = 5.25, .y0 = 4.75, .x1 = 7.0, .y1 = 5.25, .net = 2 },
        .{ .x0 = 4.0, .y0 = 6.0, .x1 = 6.0, .y1 = 6.4, .net = 3 },
    };
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = &pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 5.0, 2.0 },
        .goal = .{ 5.0, 8.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    const p1 = (try route(a, in)) orelse return error.NoPath;
    const p2 = (try route(a, in)) orelse return error.NoPath;
    try testing.expectEqual(p1.len, p2.len);
    for (p1, p2) |x, y| {
        try testing.expectApproxEqAbs(x[0], y[0], 1e-12);
        try testing.expectApproxEqAbs(x[1], y[1], 1e-12);
    }
}

// spec: placement/router - exact orient2d and inCircle predicates agree with the geometric sign
test "CDT exact predicates carry the right sign" {
    const a = Point{ .x = 0, .y = 0 };
    const b = Point{ .x = 4, .y = 0 };
    const c = Point{ .x = 0, .y = 4 };
    try testing.expect(orient2d(a, b, c) > 0); // c left of a→b
    try testing.expect(orient2d(a, c, b) < 0); // mirror
    try testing.expect(orient2d(a, b, .{ .x = 2, .y = 0 }) == 0); // collinear
    // Circumcircle of the CCW right triangle a,b,c passes through (4,4); its
    // centre is (2,2) radius √8, so (2,2) is inside and (4,4) is on the circle.
    try testing.expect(inCircle(a, b, c, .{ .x = 2, .y = 2 }) > 0);
    try testing.expect(inCircle(a, b, c, .{ .x = 4, .y = 4 }) == 0);
    try testing.expect(inCircle(a, b, c, .{ .x = 10, .y = 10 }) < 0);
}

// spec: placement/router - a CDT constraint edge survives in the triangulation and bounds a blocked interior
test "CDT constraint edges bound a blocked obstacle interior" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const pads = [_]router.PadObs{
        .{ .x0 = 4.0, .y0 = 4.0, .x1 = 6.0, .y1 = 6.0, .net = 1 },
    };
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = &pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 1.0, 1.0 },
        .goal = .{ 9.0, 9.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    var sc = (try buildScene(a, in)) orelse return error.NoScene;
    try testing.expect(sc.obstacles.len == 1);
    // Constraint edges were recorded, and every recorded one SURVIVES as a real
    // edge of the final triangulation (flips never removed an obstacle boundary).
    try testing.expect(sc.mesh.con.count() > 0);
    try testing.expect(allConstraintsPresent(&sc.mesh));
    // The obstacle interior classifies blocked, and the window keeps free space.
    const blocked_n = countTrue(sc.blocked);
    try testing.expect(blocked_n > 0 and blocked_n < sc.blocked.len);
}

/// Every recorded constraint edge is present as a real triangulation edge.
fn allConstraintsPresent(m: *Mesh) bool {
    var it = m.con.keyIterator();
    while (it.next()) |k| {
        const va: u32 = @intCast(k.* >> 32);
        const vb: u32 = @intCast(k.* & 0xffff_ffff);
        if (!edgeExists(m, va, vb)) return false;
    }
    return true;
}

fn countTrue(flags: []const bool) usize {
    var n: usize = 0;
    for (flags) |b| {
        if (b) n += 1;
    }
    return n;
}

// spec: placement/router - a CDT route bounds its total meshing work with a global budget and gives up (no path) instead of spinning on a degenerate scene
test "CDT bounds total meshing work and gives up instead of spinning" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();

    // (1) Budget guard is hard: once the global work budget is spent, meshing
    // stops cold — insertPoint refuses to grow the mesh and forceEdge is a
    // no-op — so no scan or flip loop in the probe can outrun the budget.
    var m = try initMesh(a, .{ .x = 0, .y = 0 }, .{ .x = 1_000_000, .y = 1_000_000 });
    var stack: std.ArrayList(EdgeRef) = .empty;
    m.work = max_total_work; // pretend the budget is already gone
    try testing.expect(m.exhausted());
    const tris_before = m.tris.items.len;
    try testing.expect((try insertPoint(&m, .{ .x = 500_000, .y = 500_000 }, &stack)) == null);
    try forceEdge(&m, 1, 3); // corners 1,3 are NOT joined initially; guard must skip the flips
    try testing.expectEqual(tris_before, m.tris.items.len); // nothing meshed past the budget

    // (2) A row of near-collinear, heavily-overlapping obstacle hulls (all on the
    // same y=4.9–5.1 band, 0.5 mm pitch, 0.4 mm wide, inflated so they merge) —
    // the degenerate shape whose constraint edges used to cycle the flip loop for
    // minutes on the stuck-net probe. It must now BUILD to completion with total
    // work well inside the budget (the resolving-only flip guard makes forceEdge
    // terminate in ≤ crossings steps), and route must RETURN (path or null).
    const pads = [_]router.PadObs{
        .{ .x0 = 0.5, .y0 = 4.9, .x1 = 0.9, .y1 = 5.1, .net = 1 },
        .{ .x0 = 1.0, .y0 = 4.9, .x1 = 1.4, .y1 = 5.1, .net = 2 },
        .{ .x0 = 1.5, .y0 = 4.9, .x1 = 1.9, .y1 = 5.1, .net = 3 },
        .{ .x0 = 2.0, .y0 = 4.9, .x1 = 2.4, .y1 = 5.1, .net = 4 },
        .{ .x0 = 2.5, .y0 = 4.9, .x1 = 2.9, .y1 = 5.1, .net = 5 },
        .{ .x0 = 3.0, .y0 = 4.9, .x1 = 3.4, .y1 = 5.1, .net = 6 },
        .{ .x0 = 3.5, .y0 = 4.9, .x1 = 3.9, .y1 = 5.1, .net = 7 },
        .{ .x0 = 4.0, .y0 = 4.9, .x1 = 4.4, .y1 = 5.1, .net = 8 },
        .{ .x0 = 4.5, .y0 = 4.9, .x1 = 4.9, .y1 = 5.1, .net = 9 },
        .{ .x0 = 5.0, .y0 = 4.9, .x1 = 5.4, .y1 = 5.1, .net = 10 },
        .{ .x0 = 5.5, .y0 = 4.9, .x1 = 5.9, .y1 = 5.1, .net = 11 },
        .{ .x0 = 6.0, .y0 = 4.9, .x1 = 6.4, .y1 = 5.1, .net = 12 },
    };
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 7, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = &pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 3.0, 1.0 },
        .goal = .{ 3.0, 9.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    const built = (try buildScene(a, in)) orelse return error.NoScene;
    try testing.expect(built.mesh.work < max_total_work); // built well under budget
    _ = try route(a, in); // terminates (path or null) — before the fix it did not
}

/// A synthetic board-scale obstacle field: `rows` x `cols` pads on a regular
/// pitch with a deliberate free lane down the middle column, plus a stub of
/// track and via copper — the shape of a real signal layer (barracuda's busiest
/// carries 644 tracks, 467 vias and its share of 187 parts' pads), at a size the
/// old scan-per-query mesh could not reach at all.
fn scalePads(a: std.mem.Allocator, rows: usize, cols: usize) std.mem.Allocator.Error![]router.PadObs {
    const pads = try a.alloc(router.PadObs, rows * cols);
    for (0..rows) |r| {
        for (0..cols) |c| {
            const x = 1.0 + @as(f64, @floatFromInt(c)) * 1.2;
            const y = 1.0 + @as(f64, @floatFromInt(r)) * 0.8;
            pads[r * cols + c] = .{ .x0 = x, .y0 = y, .x1 = x + 0.6, .y1 = y + 0.4, .net = @intCast(r * cols + c + 1) };
        }
    }
    return pads;
}

// spec: placement/router - a board-scale CDT scene of a thousand-plus obstacles meshes inside the work budget and routes the channel between them
test "CDT meshes and routes a board-scale obstacle field" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // 40 x 30 = 1200 pads. Each inflates to a hull of up to ring_steps + 4
    // vertices, so the mesh carries well over 20k points — an order of magnitude
    // past the old 6000-point cap, and past the point where an O(mesh) scan per
    // insertion could finish. A free lane runs along x = 0.5 (left of every pad).
    const pads = try scalePads(a, 30, 40);
    try testing.expectEqual(@as(usize, 1200), pads.len);
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 50, .y1 = 26 },
        .layer = 0,
        .obstacles = .{ .pads = pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 0.4, 1.0 },
        .goal = .{ 0.4, 25.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    var sc = (try buildScene(a, in)) orelse return error.NoScene;
    // The mesh really is board-scale, and it built INSIDE the budget rather than
    // giving up (the old engine's only possible outcome at this size).
    try testing.expect(sc.mesh.pts.items.len > 20_000);
    try testing.expect(!sc.mesh.exhausted());
    try testing.expect(sc.mesh.work < max_total_work);
    // The lane down the left edge is free, so the channel exists and the route
    // is taut: barely longer than the 24 mm straight run between the terminals.
    const path = (try route(a, in)) orelse return error.NoPath;
    try testing.expect(pathLen(path) >= 24.0 - 1e-6 and pathLen(path) < 24.0 * 1.25);
    try testing.expect(minPadGap(path, pads, 0) >= 0.127 / 2.0 + 0.127);
}

// spec: placement/router - a board-scale CDT route is deterministic and every obstacle boundary survives as a constraint edge
test "CDT board-scale meshing is deterministic and keeps its constraints" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const pads = try scalePads(a, 20, 25);
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 34, .y1 = 18 },
        .layer = 0,
        .obstacles = .{ .pads = pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 0.4, 1.0 },
        .goal = .{ 0.4, 17.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    var sc = (try buildScene(a, in)) orelse return error.NoScene;
    // Every recorded obstacle boundary is still a real triangulation edge: the
    // walking constraint insertion never abandons an edge it claimed to force.
    try testing.expect(sc.mesh.con.count() > 0);
    try testing.expect(allConstraintsPresent(&sc.mesh));
    const p1 = (try route(a, in)) orelse return error.NoPath;
    const p2 = (try route(a, in)) orelse return error.NoPath;
    try testing.expectEqual(p1.len, p2.len);
    for (p1, p2) |x, y| {
        try testing.expectApproxEqAbs(x[0], y[0], 1e-12);
        try testing.expectApproxEqAbs(x[1], y[1], 1e-12);
    }
}

/// Every triangulation edge is in the edge set and the set holds nothing else —
/// the invariant that lets `edgeExists` be a hash lookup instead of a scan.
fn checkEdgeSet(a: std.mem.Allocator, m: *Mesh) !void {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (m.tris.items) |t| {
        for (0..3) |e| {
            try seen.put(a, Mesh.conKey(edgeTail(t, e), edgeHead(t, e)), {});
            try testing.expect(edgeExists(m, edgeTail(t, e), edgeHead(t, e)));
        }
    }
    try testing.expectEqual(seen.count(), m.edges.count());
}

/// Every vertex points at a triangle that really carries it, so a fan rotation
/// can never start off the vertex it was asked about.
fn checkIncidence(m: *Mesh) !void {
    for (m.vt.items, 0..) |ti, vi| {
        try testing.expect(ti >= 0);
        try testing.expect(slotOf(m.tris.items[@intCast(ti)], @intCast(vi)) < 3);
    }
}

/// The dedup index resolves every vertex back to its own index.
fn checkPointIndex(m: *Mesh) !void {
    for (m.pts.items, 0..) |p, vi| try testing.expectEqual(@as(u32, @intCast(vi)), m.pmap.get(p).?);
}

/// A fan visits every triangle incident to `probe`, and only those.
fn checkFanCovers(m: *Mesh, probe: u32) !void {
    var fan = Fan.around(m, probe);
    var fanned: usize = 0;
    while (fan.next()) |ti| {
        try testing.expect(slotOf(m.tris.items[ti], probe) < 3);
        fanned += 1;
    }
    try testing.expectEqual(countIncident(m, probe), fanned);
}

fn countIncident(m: *const Mesh, v: u32) usize {
    var n: usize = 0;
    for (m.tris.items) |t| {
        if (slotOf(t, v) < 3) n += 1;
    }
    return n;
}

// spec: placement/router - a CDT mesh keeps its edge set, vertex incidence and point index consistent with the triangles after splits and constraint flips
test "CDT mesh indices stay consistent with the triangulation" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const pads = [_]router.PadObs{
        .{ .x0 = 3.0, .y0 = 4.75, .x1 = 4.75, .y1 = 5.25, .net = 1 },
        .{ .x0 = 5.25, .y0 = 4.75, .x1 = 7.0, .y1 = 5.25, .net = 2 },
        .{ .x0 = 4.0, .y0 = 6.0, .x1 = 6.0, .y1 = 6.4, .net = 3 },
    };
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = &pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 5.0, 2.0 },
        .goal = .{ 5.0, 8.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    var sc = (try buildScene(a, in)) orelse return error.NoScene;
    try checkEdgeSet(a, &sc.mesh);
    try checkIncidence(&sc.mesh);
    try checkPointIndex(&sc.mesh);
    try checkFanCovers(&sc.mesh, @intCast(sc.mesh.pts.items.len / 2));
}

// spec: placement/router - a CDT window seals the lattice-thin ribbon along its hull so an obstacle clamped to the window cannot be walked around
test "CDT seals the hull ribbon against a window-spanning wall" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // A wall of pads from below the window's bottom edge to above its top edge.
    // Its inflated hulls are CLAMPED to the window, which leaves a nanometre of
    // nominally free space between the clamped boundary and the hull — copper
    // the clamp discarded really is out there, so a path through that ribbon
    // would not clear it. The wall must seal the window.
    const wall = try a.alloc(router.PadObs, 14);
    for (wall, 0..) |*p, i| {
        const y = -1.0 + @as(f64, @floatFromInt(i)) * 0.9;
        p.* = .{ .x0 = 4.6, .y0 = y, .x1 = 5.4, .y1 = y + 0.9, .net = @intCast(i + 1) };
    }
    const in = Input{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = wall, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = .{ 2.0, 5.0 },
        .goal = .{ 8.0, 5.0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    try testing.expect((try route(a, in)) == null);
    // The seal is a thin ribbon, not a blunt margin: the same window with the
    // wall removed still routes, and straight.
    const open_in = Input{
        .rect = in.rect,
        .layer = 0,
        .obstacles = .{ .pads = &.{}, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
        .start = in.start,
        .goal = in.goal,
        .track_width = in.track_width,
        .clearance = in.clearance,
    };
    const path = (try route(a, open_in)) orelse return error.NoPath;
    try testing.expect(pathLen(path) < 6.0 * 1.01);
}

// spec: placement/router - a CDT scene records which of the caller's obstacles each inflated polygon came from, so a failed search names real copper and measures the two bodies rather than the anonymous rings that hid them
test "a CDT scene names its obstacles and measures their real bodies" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // Two pads 0.2 mm apart, a track, and a via — one of each source the scene
    // inflates, so every arm of the owner tag is exercised at once.
    const pads = [_]router.PadObs{
        .{ .x0 = 4.6, .y0 = 0, .x1 = 5.4, .y1 = 4.9, .net = 1, .layer = 0 },
        .{ .x0 = 4.6, .y0 = 5.1, .x1 = 5.4, .y1 = 10, .net = 2, .layer = 0 },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 1, .y1 = 1, .x2 = 2, .y2 = 1, .layer = 0, .width = 0.2, .net = 3 },
    };
    const vias = [_]router.Via{.{ .x = 8, .y = 8, .dia = 0.6, .net = 4 }};
    const field = Field{
        .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
        .layer = 0,
        .obstacles = .{ .pads = &pads, .tracks = &tracks, .vias = &vias, .skip_net = 0 },
        .track_width = 0.127,
        .clearance = 0.127,
    };
    const built = (try buildField(a, field, &.{})) orelse return error.TestNoScene;
    var scene = built.scene;

    // One tag per inflated polygon, in the same order, naming the source slice
    // and the index within it.
    try testing.expectEqual(scene.obstacles.len, scene.grid.owners.len);
    try testing.expectEqual(@as(usize, 4), scene.grid.owners.len);
    try testing.expectEqual(OwnerKind.pad, scene.grid.owners[0].kind);
    try testing.expectEqual(@as(i32, 1), scene.grid.owners[0].net);
    try testing.expectEqual(@as(u32, 1), scene.grid.owners[1].src);
    try testing.expectEqual(OwnerKind.track, scene.grid.owners[2].kind);
    try testing.expectEqual(OwnerKind.via, scene.grid.owners[3].kind);

    // The gap measured is between the real COPPER, not between the inflated
    // rings, which overlap wherever no path fits.
    const between = (try ownerGap(a, field, scene.grid.owners[0], scene.grid.owners[1])) orelse
        return error.TestNoBody;
    try testing.expectApproxEqAbs(@as(f64, 0.2), between, 1e-9);
    // A via's own radius is part of its body, so the reach to it is measured
    // from its copper edge (2.6 mm to the pad's x edge, less the 0.3 mm barrel)
    // rather than from its centre.
    const to_via = (try ownerGap(a, field, scene.grid.owners[1], scene.grid.owners[3])) orelse
        return error.TestNoBody;
    try testing.expectApproxEqAbs(@as(f64, 2.6 - 0.3), to_via, 1e-9);
    // And what a path needs there is its own trace plus a clearance either side.
    try testing.expectApproxEqAbs(@as(f64, 0.381), requiredGap(field), 1e-9);
    try testing.expect(between < requiredGap(field));

    // A triangle in the channel between the two pads is owned by both of them;
    // one in open board is owned by nobody.
    _ = &scene;
    try testing.expectEqual(@as(usize, 0), (try triBlockers(a, &scene, freeTriangleAt(&scene))).len);
}

/// Some free triangle of `sc` — the first the mesh classified as open space.
fn freeTriangleAt(sc: *Scene) u32 {
    for (0..sc.mesh.tris.items.len) |i| {
        if (triFree(sc, @intCast(i))) return @intCast(i);
    }
    return 0;
}
