//! EFFECTIVE copper length: the shortest electrical path across a net's own
//! copper, rather than the sum of its segment lengths.
//!
//! Summing segments is the obvious measure and it is wrong in exactly the way
//! that matters for a length-matched pair. Same-net copper may legally overlap —
//! no clearance rule separates a net from itself — so a leg that runs out and
//! retraces its own track measures LONGER while being electrically no longer at
//! all. Anything that reads the sum then lies in the same direction: a
//! length-match target thinks it has spent copper it has not, a skew check
//! reports a match that is not there, and a report quotes a number nobody can
//! measure on the board.
//!
//! So the length is taken over the MERGED copper graph: segments are split at
//! every crossing and at every point another segment lands on them, coincident
//! copper collapses to one edge (an overlap counts once), and the answer is the
//! shortest path from one terminal to the other (a spur off the path counts for
//! nothing).
//!
//! A via is charged whatever z-travel the CALLER says a barrel costs, because
//! that is a stackup fact this module cannot see. `shortest` charges ZERO, which
//! is the right answer for a differential pair — both legs hop together and the
//! barrel cancels out of the skew — and it is the number `diff_route` and
//! `drc_diffpair` have always measured. `shortestVia` takes the charge, which is
//! what a `(match-group …)` needs: members of one group may cross layers a
//! different number of times, and then the barrels do NOT cancel.
//!
//! Pure geometry over plain data: callers convert their own track/leg types into
//! `Seg`/`Via` and get one number back, so `diff_route`'s construction and
//! `drc_diffpair`'s post-route check measure the same way by construction.

const std = @import("std");
const numeric = @import("../numeric.zig");

/// One piece of copper on one layer.
pub const Seg = struct { a: [2]f64, b: [2]f64, layer: u8 };

/// A barrel joining every layer that carries copper at this point.
pub const Via = struct { at: [2]f64 };

/// Coordinate quantum (mm) for treating two positions as the same node. The
/// router emits grid-node coordinates and pad centres verbatim, so copper that
/// means "the same point" agrees far inside this.
const node_eps: f64 = 1e-4;

/// How far a requested terminal may sit from the nearest copper node and still
/// be taken as that node — a pad centre the copper lands on is exact, but a
/// caller measuring to a pad the leg only grazes should still resolve.
const terminal_snap_mm: f64 = 0.35;

/// Below this length a split piece is a rounding artifact, not copper.
const min_piece_mm: f64 = 1e-7;

/// A node key: quantized position plus layer, so copper stacked on two layers
/// stays two nodes and only a via joins them.
const Key = struct {
    x: i64,
    y: i64,
    layer: u8,

    fn of(p: [2]f64, layer: u8) ?Key {
        return .{ .x = quant(p[0]) orelse return null, .y = quant(p[1]) orelse return null, .layer = layer };
    }
};

fn quant(v: f64) ?i64 {
    return numeric.checkedInt(i64, v / node_eps);
}

/// An undirected edge between two node indices, with its geometric length.
const Edge = struct { to: usize, len: f64 };

/// The merged copper graph: one node per distinct (position, layer), one edge
/// per distinct piece of copper between two nodes.
const Graph = struct {
    keys: std.ArrayList(Key),
    pos: std.ArrayList([2]f64),
    adj: std.ArrayList(std.ArrayList(Edge)),

    fn nodeOf(self: *Graph, arena: std.mem.Allocator, p: [2]f64, layer: u8) (std.mem.Allocator.Error || error{InvalidGeometry})!usize {
        const want = Key.of(p, layer) orelse return error.InvalidGeometry;
        for (self.keys.items, 0..) |k, i| {
            if (k.x == want.x and k.y == want.y and k.layer == want.layer) return i;
        }
        try self.keys.append(arena, want);
        try self.pos.append(arena, p);
        try self.adj.append(arena, .empty);
        return self.keys.items.len - 1;
    }

    /// Add copper between two nodes, or keep the SHORTER of two parallel edges —
    /// which is how coincident copper stops being counted twice.
    fn link(self: *Graph, arena: std.mem.Allocator, a: usize, b: usize, len: f64) std.mem.Allocator.Error!void {
        if (a == b or len < min_piece_mm) return;
        for (self.adj.items[a].items) |*e| {
            if (e.to != b) continue;
            if (len < e.len) e.len = len;
            for (self.adj.items[b].items) |*back| {
                if (back.to == a and len < back.len) back.len = len;
            }
            return;
        }
        try self.adj.items[a].append(arena, .{ .to = b, .len = len });
        try self.adj.items[b].append(arena, .{ .to = a, .len = len });
    }
};

/// Shortest electrical distance (mm) from `from` to `to` across `segs` + `vias`,
/// or null when the two terminals are not connected by this copper at all.
///
/// `from`/`to` are positions, not layers: a terminal is a pad, which the copper
/// may reach on either face, so whichever node is nearest is taken.
pub fn shortest(
    arena: std.mem.Allocator,
    segs: []const Seg,
    vias: []const Via,
    from: [2]f64,
    to: [2]f64,
) std.mem.Allocator.Error!?f64 {
    return shortestVia(arena, segs, vias, from, to, 0);
}

/// `shortest`, with every via barrel traversal charged `via_len_mm` of path
/// instead of nothing. A group of nets matched on length may hop layers a
/// different number of times, so the barrels no longer cancel and the z-travel
/// is part of what the reader has to compare; `via_len_mm = 0` reproduces
/// `shortest` exactly, edge for edge.
pub fn shortestVia(
    arena: std.mem.Allocator,
    segs: []const Seg,
    vias: []const Via,
    from: [2]f64,
    to: [2]f64,
    via_len_mm: f64,
) std.mem.Allocator.Error!?f64 {
    var g = Graph{ .keys = .empty, .pos = .empty, .adj = .empty };
    buildGraph(arena, &g, segs, vias, via_len_mm) catch |err| switch (err) {
        error.InvalidGeometry => return null,
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (g.keys.items.len == 0) return null;
    const src = nearestNode(g, from) orelse return null;
    const dst = nearestNode(g, to) orelse return null;
    return dijkstra(arena, g, src, dst);
}

/// The two most distant endpoints among `segs` — the copper's electrical
/// extremes, which for a routed net are the pads it lands on. Callers measure
/// between these, so the answer is the whole run rather than some interior hop.
pub fn farthestEnds(segs: []const Seg) [2][2]f64 {
    var best: [2][2]f64 = .{ segs[0].a, segs[0].a };
    var far: f64 = -1;
    for (segs) |s| {
        for ([2][2]f64{ s.a, s.b }) |p| {
            for (segs) |o| {
                for ([2][2]f64{ o.a, o.b }) |q| {
                    const d = dist(p, q);
                    if (d <= far) continue;
                    far = d;
                    best = .{ p, q };
                }
            }
        }
    }
    return best;
}

/// Split every segment at each point another same-layer segment touches or
/// crosses it, then link the pieces.
fn buildGraph(
    arena: std.mem.Allocator,
    g: *Graph,
    segs: []const Seg,
    vias: []const Via,
    via_len_mm: f64,
) (std.mem.Allocator.Error || error{InvalidGeometry})!void {
    for (segs) |s| {
        const cuts = try splitParams(arena, segs, s);
        var prev = s.a;
        for (cuts) |t| {
            const at = lerp(s.a, s.b, t);
            try linkPiece(arena, g, prev, at, s.layer);
            prev = at;
        }
        try linkPiece(arena, g, prev, s.b, s.layer);
    }
    for (vias) |v| try linkVia(arena, g, segs, v, via_len_mm);
}

/// One piece of copper as a graph edge.
fn linkPiece(
    arena: std.mem.Allocator,
    g: *Graph,
    a: [2]f64,
    b: [2]f64,
    layer: u8,
) (std.mem.Allocator.Error || error{InvalidGeometry})!void {
    const len = dist(a, b);
    if (len < min_piece_mm) return;
    const na = try g.nodeOf(arena, a, layer);
    const nb = try g.nodeOf(arena, b, layer);
    try g.link(arena, na, nb, len);
}

/// Join every layer carrying copper at a barrel, each hop charged `via_len_mm`
/// (0 = free, the differential-pair reading). The barrel's own layers are joined
/// to the FIRST one found, so a via touching three layers charges one hop from
/// that layer to either other — netlisp's router only emits through vias, which
/// span the whole stack, so a hop is one full board thickness whichever pair it
/// lands on and there is no shorter partial barrel to distinguish.
fn linkVia(
    arena: std.mem.Allocator,
    g: *Graph,
    segs: []const Seg,
    v: Via,
    via_len_mm: f64,
) (std.mem.Allocator.Error || error{InvalidGeometry})!void {
    var first: ?usize = null;
    for (segs) |s| {
        if (dist(s.a, v.at) > node_eps and dist(s.b, v.at) > node_eps) continue;
        const n = try g.nodeOf(arena, v.at, s.layer);
        if (first) |f| {
            if (f != n) try forceLink(arena, g, f, n, via_len_mm);
        } else first = n;
    }
}

/// A barrel join, at `len` — including the zero length `Graph.link` refuses as a
/// degenerate piece, which is why this bypasses it.
fn forceLink(arena: std.mem.Allocator, g: *Graph, a: usize, b: usize, len: f64) std.mem.Allocator.Error!void {
    for (g.adj.items[a].items) |e| {
        if (e.to == b) return;
    }
    try g.adj.items[a].append(arena, .{ .to = b, .len = len });
    try g.adj.items[b].append(arena, .{ .to = a, .len = len });
}

/// Sorted interior parameters along `s` where other same-layer copper meets it.
fn splitParams(
    arena: std.mem.Allocator,
    segs: []const Seg,
    s: Seg,
) std.mem.Allocator.Error![]const f64 {
    var out: std.ArrayList(f64) = .empty;
    const len = dist(s.a, s.b);
    if (len < min_piece_mm) return out.toOwnedSlice(arena);
    for (segs) |o| {
        if (o.layer != s.layer) continue;
        for ([2][2]f64{ o.a, o.b }) |p| {
            const t = projectOn(s, p) orelse continue;
            try addParam(arena, &out, t, len);
        }
        if (crossParam(s, o)) |t| try addParam(arena, &out, t, len);
    }
    std.mem.sort(f64, out.items, {}, comptime std.sort.asc(f64));
    return out.toOwnedSlice(arena);
}

/// Record an interior split parameter, skipping the two ends and duplicates.
fn addParam(
    arena: std.mem.Allocator,
    out: *std.ArrayList(f64),
    t: f64,
    len: f64,
) std.mem.Allocator.Error!void {
    const margin = node_eps / len;
    if (t <= margin or t >= 1 - margin) return;
    for (out.items) |had| {
        if (@abs(had - t) <= margin) return;
    }
    try out.append(arena, t);
}

/// Where `p` lands on `s` as a parameter, when it lies ON `s` (within a node
/// quantum) — how a segment ending mid-way along another one gets a node there.
fn projectOn(s: Seg, p: [2]f64) ?f64 {
    const dx = s.b[0] - s.a[0];
    const dy = s.b[1] - s.a[1];
    const l2 = dx * dx + dy * dy;
    if (l2 <= min_piece_mm * min_piece_mm) return null;
    const t = ((p[0] - s.a[0]) * dx + (p[1] - s.a[1]) * dy) / l2;
    if (t <= 0 or t >= 1) return null;
    const foot = [2]f64{ s.a[0] + t * dx, s.a[1] + t * dy };
    return if (dist(foot, p) <= node_eps) t else null;
}

/// Where two non-parallel same-layer segments properly cross, as a parameter
/// along `s`. Null when they are parallel or meet outside either span.
fn crossParam(s: Seg, o: Seg) ?f64 {
    const r = [2]f64{ s.b[0] - s.a[0], s.b[1] - s.a[1] };
    const q = [2]f64{ o.b[0] - o.a[0], o.b[1] - o.a[1] };
    const den = r[0] * q[1] - r[1] * q[0];
    if (@abs(den) < min_piece_mm) return null;
    const w = [2]f64{ o.a[0] - s.a[0], o.a[1] - s.a[1] };
    const t = (w[0] * q[1] - w[1] * q[0]) / den;
    const u = (w[0] * r[1] - w[1] * r[0]) / den;
    if (t <= 0 or t >= 1 or u <= 0 or u >= 1) return null;
    return t;
}

/// The graph node nearest `p`, when one is within `terminal_snap_mm`.
fn nearestNode(g: Graph, p: [2]f64) ?usize {
    var best: ?usize = null;
    var best_d: f64 = terminal_snap_mm;
    for (g.pos.items, 0..) |q, i| {
        const d = dist(q, p);
        if (d > best_d) continue;
        best_d = d;
        best = i;
    }
    return best;
}

/// Shortest distance from `src` to `dst`, or null when unreachable. A linear
/// scan for the next node: these graphs are tens of nodes, so a heap would cost
/// more in code than it saves in time.
fn dijkstra(
    arena: std.mem.Allocator,
    g: Graph,
    src: usize,
    dst: usize,
) std.mem.Allocator.Error!?f64 {
    const n = g.keys.items.len;
    const best = try arena.alloc(f64, n);
    const seen = try arena.alloc(bool, n);
    @memset(seen, false);
    for (best) |*b| b.* = std.math.inf(f64);
    best[src] = 0;
    while (true) {
        var at: ?usize = null;
        var lo = std.math.inf(f64);
        for (0..n) |i| {
            if (seen[i] or best[i] >= lo) continue;
            lo = best[i];
            at = i;
        }
        const cur = at orelse break;
        if (cur == dst) return best[dst];
        seen[cur] = true;
        for (g.adj.items[cur].items) |e| {
            const via_cur = best[cur] + e.len;
            if (via_cur < best[e.to]) best[e.to] = via_cur;
        }
    }
    return if (std.math.isInf(best[dst])) null else best[dst];
}

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

fn lerp(a: [2]f64, b: [2]f64, t: f64) [2]f64 {
    return .{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) };
}

/// Whether any two pieces of same-layer copper in `segs` OVERLAP (share more
/// than a point) or properly CROSS.
///
/// Both are legal for a net against itself — no clearance rule separates copper
/// from its own net — and both are exactly what makes a summed length a lie. A
/// construction that can promise neither cannot promise its own reported length,
/// so this is the property to assert rather than the measurement to correct.
pub fn selfSimple(segs: []const Seg) bool {
    for (segs, 0..) |s, i| {
        if (dist(s.a, s.b) < min_piece_mm) continue;
        for (segs[i + 1 ..]) |o| {
            if (o.layer != s.layer or dist(o.a, o.b) < min_piece_mm) continue;
            if (overlaps(s, o) or crossParam(s, o) != null) return false;
        }
    }
    return true;
}

/// Whether two same-layer segments share a stretch, not merely a point.
fn overlaps(s: Seg, o: Seg) bool {
    const r = [2]f64{ s.b[0] - s.a[0], s.b[1] - s.a[1] };
    const q = [2]f64{ o.b[0] - o.a[0], o.b[1] - o.a[1] };
    if (@abs(r[0] * q[1] - r[1] * q[0]) >= min_piece_mm) return false; // not parallel
    // Collinear? Then the offset between the two lines is zero.
    const w = [2]f64{ o.a[0] - s.a[0], o.a[1] - s.a[1] };
    const len = dist(s.a, s.b);
    if (@abs(w[0] * r[1] - w[1] * r[0]) / len > node_eps) return false; // parallel, apart
    const ta = ((o.a[0] - s.a[0]) * r[0] + (o.a[1] - s.a[1]) * r[1]) / (len * len);
    const tb = ((o.b[0] - s.a[0]) * r[0] + (o.b[1] - s.a[1]) * r[1]) / (len * len);
    const lo = @max(@min(ta, tb), 0);
    const hi = @min(@max(ta, tb), 1);
    return (hi - lo) * len > node_eps;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/router - effective copper length is the shortest path over merged copper, so a retraced or spurred leg measures its real electrical length
test "copper_length ignores a retraced overlap and a dead-end spur" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A 10 mm run that overshoots to 12 mm and comes back — the fold is legal
    // copper (same net) and adds 4 mm to the SUM while adding nothing at all to
    // the path from (0,0) to (10,0).
    const folded = [_]Seg{
        .{ .a = .{ 0, 0 }, .b = .{ 12, 0 }, .layer = 0 },
        .{ .a = .{ 12, 0 }, .b = .{ 10, 0 }, .layer = 0 },
    };
    var sum: f64 = 0;
    for (folded) |s| sum += dist(s.a, s.b);
    try testing.expectApproxEqAbs(@as(f64, 14), sum, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), (try shortest(arena, &folded, &.{}, .{ 0, 0 }, .{ 10, 0 })).?, 1e-9);
    // …and that copper is not self-simple, which is the property that lets the
    // sum lie in the first place.
    try testing.expect(!selfSimple(&folded));

    // A clean run with a spur hanging off it: the spur is real copper, but the
    // electrical length between the terminals does not include it.
    const spurred = [_]Seg{
        .{ .a = .{ 0, 0 }, .b = .{ 10, 0 }, .layer = 0 },
        .{ .a = .{ 4, 0 }, .b = .{ 4, 3 }, .layer = 0 },
    };
    try testing.expectApproxEqAbs(@as(f64, 10), (try shortest(arena, &spurred, &.{}, .{ 0, 0 }, .{ 10, 0 })).?, 1e-9);
    try testing.expect(selfSimple(&spurred)); // touching at a point is fine
}

// spec: placement/router - effective copper length crosses layers only through a via, and reports unreachable copper as unmeasurable
test "copper_length joins layers at a via and refuses disconnected copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two 5 mm runs stacked on different layers, joined end to end by a barrel.
    const hopped = [_]Seg{
        .{ .a = .{ 0, 0 }, .b = .{ 5, 0 }, .layer = 0 },
        .{ .a = .{ 5, 0 }, .b = .{ 10, 0 }, .layer = 1 },
    };
    const vias = [_]Via{.{ .at = .{ 5, 0 } }};
    try testing.expectApproxEqAbs(@as(f64, 10), (try shortest(arena, &hopped, &vias, .{ 0, 0 }, .{ 10, 0 })).?, 1e-9);
    // WITHOUT the barrel the two layers are separate copper, so the terminals
    // are not connected — a length would be fiction.
    try testing.expect((try shortest(arena, &hopped, &.{}, .{ 0, 0 }, .{ 10, 0 })) == null);
    // Copper that merely crosses on two layers never joins.
    const crossing = [_]Seg{
        .{ .a = .{ 0, 0 }, .b = .{ 10, 0 }, .layer = 0 },
        .{ .a = .{ 5, -5 }, .b = .{ 5, 5 }, .layer = 1 },
    };
    try testing.expect((try shortest(arena, &crossing, &.{}, .{ 0, 0 }, .{ 5, 5 })) == null);
    try testing.expect(selfSimple(&crossing)); // different layers never conflict
}

// spec: Web Server - Copper graph quantization refuses nonfinite and unrepresentable geometry instead of trapping
test "numeric copper quantization rejects invalid geometry" {
    try std.testing.expect(Key.of(.{ std.math.inf(f64), 0 }, 0) == null);
    try std.testing.expect(Key.of(.{ 0, std.math.nan(f64) }, 0) == null);
    try std.testing.expect(Key.of(.{ 1e100, 0 }, 0) == null);
    try std.testing.expectEqual(@as(i64, 0), quant(0).?);
}
