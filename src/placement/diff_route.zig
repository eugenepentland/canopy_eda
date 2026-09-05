//! Coupled differential-pair route construction: the geometry that turns ONE
//! routed centreline into a pair's two legs.
//!
//! `router.zig` routes a declared `(net-class … (diff-pair GAP))` pair ONCE, as
//! a single centreline whose effective copper profile is the pair ENVELOPE
//! (`2·width + gap`), instead of searching the two members as independent nets
//! and hoping a cost discount pulls them together. This module owns the pure
//! geometry on both sides of that search:
//!
//!   • `pairEnds` splits the pair's pads into its two ENDS and produces each
//!     end's centreline terminal, landing pads, and daisy chain (a real LVDS
//!     end carries its termination resistor beside its AC-coupling cap, so
//!     "two pads a side" is the exception, not the rule).
//!   • `chain` re-reads the emitted copper as one ordered centreline — a
//!     sequence of same-layer runs joined by vias — or refuses (null) when that
//!     copper is not a simple path.
//!   • `build` splits the centreline into two legs at ±(width+gap)/2, with
//!     MITERED corners on every bend (the miter point sits on both offset lines,
//!     so the coupled spacing survives the bend — the same rule the browser
//!     hand-draw coupler `dpChainFor` uses), a via PAIR spread along the path
//!     normal at every layer change, a short fan at each end into the landing
//!     pad, and a daisy chain on to that end's remaining pads.
//!   • `minOppositeGap` is the pair's own centre-to-centre self-check, so a
//!     construction that folded onto itself is refused instead of shipped.
//!
//! Everything here is pure geometry: no router state, no obstacle model. The
//! router validates the produced copper against foreign obstacles with its own
//! exact probes and falls back to the legacy follower-corridor route whenever
//! the centreline search, this construction, or that validation fails — so a
//! board whose pair cannot be coupled routes exactly as it does today.

const std = @import("std");
const copper_length = @import("copper_length.zig");

/// A point in board millimetres.
pub const Pt = struct { x: f64, y: f64 };

/// One emitted copper segment of the centreline search (the router's `Track`
/// reduced to what chaining needs).
pub const Seg = struct { a: Pt, b: Pt, layer: u8 };

/// A pad terminal: world centre plus the signal layer its part sits on.
pub const Terminal = struct { x: f64, y: f64, layer: u8 };

/// One same-layer run of a centreline, in path order.
pub const Run = struct { layer: u8, pts: []const Pt };

/// A chained centreline: `runs` in path order, with `vias[i]` joining
/// `runs[i]` to `runs[i+1]` at the vertex they share.
pub const Centerline = struct { runs: []const Run, vias: []const Pt };

/// Which leg of the pair a piece of constructed copper belongs to.
pub const Side = enum(u1) { p, n };

/// What role a constructed leg segment plays.
pub const Kind = enum {
    /// Part of the coupled run: exactly `off` from its twin, by construction.
    coupled,
    /// The short uncoupled hop into the pad the coupled run lands on — the
    /// stretch `minOppositeGap` and the coupling DRC both exempt.
    fan,
    /// A hop of the pad-sequence WALK: pad to pad, or the last pad straight out
    /// along the escape. This copper lands on pads and threads the pad field
    /// between them, so unlike a fan it may never be reshaped — a length-match
    /// detour here swings an apex into whatever guards the next pin.
    chain,
};

/// One constructed leg segment.
pub const LegSeg = struct { a: Pt, b: Pt, layer: u8, side: Side, kind: Kind = .coupled };

/// One via PAIR at a centreline layer change: the P barrel and the N barrel,
/// spread symmetrically along the path normal — or, when `in_line` is set,
/// staggered ALONG the path so the legs swap sides through the transition.
pub const LegVia = struct { p: Pt, n: Pt, in_line: ?InLineEnds = null };

/// The extra geometry an IN-LINE (side-swapping) via transition needs.
///
/// A pair whose two ends demand opposite sides — the ends are twisted relative
/// to each other, which is the normal case when a connector's pinout and the
/// receiver's pinout disagree — has no legal construction with barrels spread
/// ACROSS the path: whichever way the legs leave, they cross on one layer.
/// Staggering the barrels ALONG the path instead lets each leg drop at its own
/// barrel and come up on the OTHER side, with the crossing absorbed inside the
/// two barrels where the legs are on different layers. The price is that one
/// leg must route PAST the other's barrel on each layer, which is what `hold`
/// carries: a lateral excursion held across the barrel pair, on the passing
/// leg's own side, so it clears both drills and never crosses its twin.
pub const InLineEnds = struct {
    /// Where each leg's coupled run stops short on the entry side.
    in_p: Pt,
    in_n: Pt,
    /// Where each leg's coupled run resumes on the exit side (sides swapped).
    out_p: Pt,
    out_n: Pt,
    /// The excursion the passing leg holds across the barrel pair — the same
    /// two points on both layers, since the two passes are mirror images.
    hold: [2]Pt,
};

/// The constructed pair copper.
pub const Legs = struct { segs: []const LegSeg, vias: []const LegVia };

/// One pad pair the coupled run passes THROUGH at an end: a P pad, its N
/// partner, and the centreline point between them.
pub const PadPair = struct { p: Pt, n: Pt, mid: Terminal };

/// The pair's two ends. Each carries the ordered pad pairs its legs walk —
/// terminus first, the pair the run exits through last — plus the centreline
/// terminal just beyond that last pair.
pub const Ends = struct {
    /// Where the pad field ends: the centreline's first vertex at each end.
    mid: [2]Terminal,
    /// Where the MAZE is asked to route to — further out along the escape, so
    /// the centreline's first segment runs straight out of the pad field. The
    /// legs' perpendicular offsets then line up with the axis the pads are
    /// separated on, which is the only way the taper from pad pitch to class
    /// gap stays a taper instead of a rotation.
    far: [2]Terminal,
    seq: [2][]const PadPair,
};

/// Construction options for `build`.
pub const Options = struct {
    /// Centre-to-centre leg spacing: track width + coupling gap.
    off: f64,
    /// Minimum centre-to-centre spacing of a via pair (see `viaSpread`).
    via_spread: f64,
    /// How far each barrel must stay from the OPPOSITE leg's track: the via
    /// radius plus half a track plus the class clearance. A via at a centreline
    /// CORNER needs a wider splay than a via mid-run to hold it, so the pair
    /// spread is solved per via from this (see `viaPairs`).
    via_clear: f64 = 0,
    /// Per end, the pad pairs the legs thread through before the coupled run
    /// begins — terminus first (see `Ends`).
    seq: [2][]const PadPair,
    /// Per end, the centreline terminal — gives the walk its escape heading.
    mid: [2]Terminal,
    /// Which layer change absorbs the pair's TWIST, as an IN-LINE side-swapping
    /// transition. Null asks for the all-perpendicular construction, which is
    /// the only legal one for an untwisted pair; an index is required for a
    /// twisted one, and every candidate index is worth probing (see
    /// `diff_couple`). A mismatch between this and the pair's actual twist
    /// declines, so a caller can simply walk the options.
    swap_via: ?usize = null,
    /// Which ends approach their terminal STRAIGHT, by deleting the overshoot the
    /// maze left there, instead of spending a layer change on the turn back.
    ///
    /// Both readings of such a turn are legitimate and only the board can say
    /// which: at a connector the maze arrives along the terminal's own axis and
    /// merely overran it, so the trim is free copper and a whole via pair saved;
    /// at a crowded pocket the same-shaped turn IS the escape, and trimming it
    /// drives the pair straight back into the pads it was leaving. So it is a
    /// CANDIDATE — the caller offers the trim, the exact clearance probe rules,
    /// and the layer change stays the fallback.
    trim: RunEnds = .{ .head = false, .tail = false },
};

/// Coordinate tolerance (mm) for treating two emitted endpoints as one vertex.
/// The router emits grid-node world coordinates and pad centres verbatim, so
/// endpoints that mean "the same point" are bit-identical or within rounding.
const weld_eps: f64 = 1e-6;

/// Miter denominator floor, mirroring the browser coupler: below it the two leg
/// directions are near-reversed and the miter would shoot to infinity, so the
/// plain perpendicular offset of the outgoing direction is used instead.
const miter_floor: f64 = 0.3;

/// Below this normal-axis pad offset the pads sit ON the first centreline
/// direction and give no side signal, so `sideFor` asks the other end.
const side_eps: f64 = 1e-9;

/// A unit direction.
const Vec = struct { x: f64, y: f64 };

/// Centre-to-centre spacing a via PAIR needs. Wide enough that the two barrels
/// clear each other (`via_dia + clearance`) AND that each barrel clears the
/// OPPOSITE leg's track, whose nearest approach is `spread/2 + off/2` once the
/// legs have converged back to the coupled offset. Never tighter than `off`,
/// so a pair with roomy geometry keeps its vias exactly on the leg lines.
pub fn viaSpread(off: f64, via_dia: f64, clearance: f64, width: f64) f64 {
    const via_via = via_dia + clearance;
    const via_track = via_dia + 2 * clearance + width - off;
    return @max(off, @max(via_via, via_track));
}

/// Distance between two terminals (mm).
fn span(a: Terminal, b: Terminal) f64 {
    return std.math.hypot(a.x - b.x, a.y - b.y);
}

/// Shortest span between a pair's two ends for the clustering to be meaningful.
/// Below it every pad is one blob and there is no run to couple.
const min_pair_span_mm: f64 = 1.0;

/// How far the centreline runs STRAIGHT along the escape before the maze is
/// free to turn — the reference holds this line for 0.66 mm out of its pocket.
const escape_run_mm: f64 = 0.6;

/// How far beyond its OUTERMOST pad pair the centreline terminal sits.
///
/// Far enough that the terminal — and the offset legs that start there — clear
/// the pad field entirely: a pair envelope reaches ~0.46 mm off its centreline
/// and a chip pad half-extent is ~0.2, so anything less leaves the constructed
/// leg grazing the pad its TWIN lands on, which is the one obstacle the search
/// cannot be told to ignore.
const escape_out_mm: f64 = 0.9;

/// Split the pair's pads into its two ENDS and resolve each end's pad-pair
/// sequence, escape direction and centreline terminal.
pub fn pairEnds(
    arena: std.mem.Allocator,
    p: []const Terminal,
    n: []const Terminal,
    max_span: f64,
) std.mem.Allocator.Error!?Ends {
    const all = try pairEndOptions(arena, p, n, max_span, 1);
    return if (all.len == 0) null else all[0];
}

/// Up to `max` end configurations, best first.
///
/// A real pair end is a SEQUENCE of pad pairs, not one landing pad. An LVDS
/// receive end carries its termination resistor and its AC-coupling caps in a
/// line, and the human route threads straight through both — cap pads, then
/// resistor pads, then out. Treating the resistor as a stub hanging off the
/// caps is what forces the coupled run to squeeze PAST it through a channel
/// that does not exist. So each end resolves to an ordered walk, and the only
/// thing searched is which way the run leaves: both escape directions are
/// offered, the one pointing away from the far end first.
pub fn pairEndOptions(
    arena: std.mem.Allocator,
    p: []const Terminal,
    n: []const Terminal,
    max_span: f64,
    max: usize,
) std.mem.Allocator.Error![]const Ends {
    if (p.len == 0 or n.len == 0 or max == 0) return &.{};
    const axis = spanAxis(p, n) orelse return &.{};
    var side: [2]Cluster = .{ .{}, .{} };
    try clusterInto(arena, &side, p, axis, .p);
    try clusterInto(arena, &side, n, axis, .n);
    const a_opts = try endOptions(arena, side[0], side[1], max_span);
    const b_opts = try endOptions(arena, side[1], side[0], max_span);
    if (a_opts.len == 0 or b_opts.len == 0) return &.{};
    var out: std.ArrayList(Ends) = .empty;
    var rank: usize = 0;
    while (rank < a_opts.len + b_opts.len and out.items.len < max) : (rank += 1) {
        try collectRank(arena, .{ .a = a_opts, .b = b_opts }, rank, &out, max);
    }
    return out.toOwnedSlice(arena);
}

/// One end's pads, split by net.
const Cluster = struct {
    p: std.ArrayList(Terminal) = .empty,
    n: std.ArrayList(Terminal) = .empty,
};

/// One resolved end: its pad-pair walk and the terminal beyond it.
const End = struct { seq: []const PadPair, mid: Terminal, far: Terminal };

/// The two ends' option lists.
const EndOpts = struct { a: []const End, b: []const End };

/// Append every (a,b) option pair whose ranks sum to `rank`, best-first.
fn collectRank(
    arena: std.mem.Allocator,
    opts: EndOpts,
    rank: usize,
    out: *std.ArrayList(Ends),
    max: usize,
) std.mem.Allocator.Error!void {
    for (opts.a, 0..) |a, i| {
        if (i > rank or rank - i >= opts.b.len or out.items.len >= max) continue;
        try out.append(arena, joinEnds(a, opts.b[rank - i]));
    }
}

/// Combine one option from each end into the canonical `Ends` order
/// (lexicographic by terminal, so a board always builds the same way).
fn joinEnds(one: End, two: End) Ends {
    const flip = two.mid.x < one.mid.x or (two.mid.x == one.mid.x and two.mid.y < one.mid.y);
    const a = if (flip) two else one;
    const b = if (flip) one else two;
    return .{ .mid = .{ a.mid, b.mid }, .far = .{ a.far, b.far }, .seq = .{ a.seq, b.seq } };
}

/// The two pads farthest apart across both nets — the run's axis. Null when
/// every pad sits within `min_pair_span_mm` (no run to couple).
fn spanAxis(p: []const Terminal, n: []const Terminal) ?[2]Terminal {
    var best: ?[2]Terminal = null;
    var far: f64 = min_pair_span_mm;
    for ([2][]const Terminal{ p, n }) |a_list| {
        for ([2][]const Terminal{ p, n }) |b_list| {
            for (a_list) |a| {
                for (b_list) |b| {
                    if (span(a, b) <= far) continue;
                    far = span(a, b);
                    best = .{ a, b };
                }
            }
        }
    }
    return best;
}

/// File each pad of one net into the end it is nearer.
fn clusterInto(
    arena: std.mem.Allocator,
    side: *[2]Cluster,
    pads: []const Terminal,
    axis: [2]Terminal,
    which: Side,
) std.mem.Allocator.Error!void {
    for (pads) |pad| {
        const at: usize = if (span(pad, axis[1]) < span(pad, axis[0])) 1 else 0;
        const bucket = if (which == .p) &side[at].p else &side[at].n;
        try bucket.append(arena, pad);
    }
}

/// Centroid of an end's pads — what the other end's escape aims away from.
fn centroid(c: Cluster) Terminal {
    var sx: f64 = 0;
    var sy: f64 = 0;
    var count: f64 = 0;
    for ([2][]const Terminal{ c.p.items, c.n.items }) |list| {
        for (list) |t| {
            sx += t.x;
            sy += t.y;
            count += 1;
        }
    }
    if (count == 0) return .{ .x = 0, .y = 0, .layer = 0 };
    return .{ .x = sx / count, .y = sy / count, .layer = 0 };
}

/// Pair up one end's pads greedily, tightest first: each P pad takes the
/// nearest unused same-layer N pad within `max_span`. Null when any pad is left
/// over — an end the construction cannot fully thread is one it must decline,
/// or the leftover pad would silently lose its copper.
fn padPairs(
    arena: std.mem.Allocator,
    here: Cluster,
    max_span: f64,
) std.mem.Allocator.Error!?[]PadPair {
    if (here.p.items.len != here.n.items.len or here.p.items.len == 0) return null;
    const used = try arena.alloc(bool, here.n.items.len);
    @memset(used, false);
    const out = try arena.alloc(PadPair, here.p.items.len);
    for (here.p.items, out) |pt, *slot| {
        var pick: ?usize = null;
        for (here.n.items, 0..) |nt, j| {
            if (used[j] or pt.layer != nt.layer or span(pt, nt) > max_span) continue;
            if (pick) |had| {
                if (span(pt, here.n.items[had]) <= span(pt, nt)) continue;
            }
            pick = j;
        }
        const j = pick orelse return null;
        used[j] = true;
        const nt = here.n.items[j];
        slot.* = .{
            .p = .{ .x = pt.x, .y = pt.y },
            .n = .{ .x = nt.x, .y = nt.y },
            .mid = .{ .x = (pt.x + nt.x) / 2, .y = (pt.y + nt.y) / 2, .layer = pt.layer },
        };
    }
    return out;
}

/// Both escape options for one end, the direction pointing AWAY from the far
/// end first — that is where a pocket's open side almost always is, because the
/// circuit the pair serves sits on the near side.
fn endOptions(
    arena: std.mem.Allocator,
    here: Cluster,
    other: Cluster,
    max_span: f64,
) std.mem.Allocator.Error![]const End {
    const pairs = (try padPairs(arena, here, max_span)) orelse return &.{};
    const dir = unitOf(.{ .x = pairs[0].n.x, .y = pairs[0].n.y }, .{ .x = pairs[0].p.x, .y = pairs[0].p.y }) orelse
        return &.{};
    const perp = normalOf(dir);
    const aim = centroid(other);
    const away = (aim.x - pairs[0].mid.x) * perp.x + (aim.y - pairs[0].mid.y) * perp.y;
    const first: f64 = if (away <= 0) 1 else -1;
    var out: std.ArrayList(End) = .empty;
    for ([2]f64{ first, -first }) |sign| {
        const u = Vec{ .x = perp.x * sign, .y = perp.y * sign };
        const walk = try orderAlong(arena, pairs, u);
        const last = walk[walk.len - 1].mid;
        const mid = Terminal{ .x = last.x + u.x * escape_out_mm, .y = last.y + u.y * escape_out_mm, .layer = last.layer };
        try out.append(arena, .{
            .seq = walk,
            .mid = mid,
            .far = .{ .x = mid.x + u.x * escape_run_mm, .y = mid.y + u.y * escape_run_mm, .layer = mid.layer },
        });
    }
    return out.toOwnedSlice(arena);
}

/// One end's pad pairs ordered along the escape `u`: the pair the run
/// terminates at first, the pair it exits through last.
fn orderAlong(
    arena: std.mem.Allocator,
    pairs: []const PadPair,
    u: Vec,
) std.mem.Allocator.Error![]const PadPair {
    const out = try arena.dupe(PadPair, pairs);
    const ctx = AlongCtx{ .u = u };
    std.mem.sort(PadPair, out, ctx, AlongCtx.less);
    return out;
}

/// Sort key for `orderAlong`: projection on the escape, ties by position.
const AlongCtx = struct {
    u: Vec,
    fn less(self: AlongCtx, a: PadPair, b: PadPair) bool {
        const pa = a.mid.x * self.u.x + a.mid.y * self.u.y;
        const pb = b.mid.x * self.u.x + b.mid.y * self.u.y;
        if (pa != pb) return pa < pb;
        if (a.mid.x != b.mid.x) return a.mid.x < b.mid.x;
        return a.mid.y < b.mid.y;
    }
};

// ── Centreline chaining ──────────────────────────────────────────────────────

/// One chaining graph vertex: a copper endpoint on one layer. `links` holds up
/// to three neighbours so an over-degree vertex (a branch — not a simple path)
/// is detectable rather than silently truncated.
const Node = struct {
    pt: Pt,
    layer: u8,
    n_links: u8 = 0,
    links: [3]usize = .{ 0, 0, 0 },
};

/// True when two points are the same vertex within `weld_eps`.
fn samePt(a: Pt, b: Pt) bool {
    return @abs(a.x - b.x) <= weld_eps and @abs(a.y - b.y) <= weld_eps;
}

/// Index of the graph vertex at (`pt`, `layer`), appending it when new.
fn nodeIndex(
    arena: std.mem.Allocator,
    nodes: *std.ArrayList(Node),
    pt: Pt,
    layer: u8,
) std.mem.Allocator.Error!usize {
    for (nodes.items, 0..) |nd, i| {
        if (nd.layer == layer and samePt(nd.pt, pt)) return i;
    }
    try nodes.append(arena, .{ .pt = pt, .layer = layer });
    return nodes.items.len - 1;
}

/// Join two vertices; false when either already has two neighbours (a branch).
fn linkNodes(nodes: []Node, a: usize, b: usize) bool {
    if (a == b or nodes[a].n_links >= 2 or nodes[b].n_links >= 2) return false;
    nodes[a].links[nodes[a].n_links] = b;
    nodes[a].n_links += 1;
    nodes[b].links[nodes[b].n_links] = a;
    nodes[b].n_links += 1;
    return true;
}

/// Link the two vertices a through-via joins. Exactly two may land on the
/// barrel — its copper on the two layers it connects — and they count as
/// landing on it anywhere inside `tol` (the barrel's own radius): the maze ends
/// a run wherever its grid node fell, which is often a fraction of a pad short
/// of the drill centre. Anything else is not a simple path.
fn linkVia(nodes: []Node, at: Pt, tol: f64) bool {
    var hit: [2]?Landing = .{ null, null };
    for (nodes, 0..) |nd, i| {
        const d = std.math.hypot(nd.pt.x - at.x, nd.pt.y - at.y);
        if (d > tol) continue;
        const slot = &hit[@intFromBool(hit[0] != null and hit[0].?.layer != nd.layer)];
        if (slot.*) |had| {
            if (had.layer != nd.layer) return false; // a third layer on one barrel
            if (had.dist <= d) continue;
        }
        slot.* = .{ .node = i, .layer = nd.layer, .dist = d };
    }
    const a = hit[0] orelse return false;
    const b = hit[1] orelse return false;
    return linkNodes(nodes, a.node, b.node);
}

/// One copper end landing on a via barrel: which node, on which layer, how far
/// from the drill centre.
const Landing = struct { node: usize, layer: u8, dist: f64 };

/// Walk the chain from `first`, returning vertex indices in path order, or null
/// when the walk does not cover every vertex (a disconnected fragment).
fn walkChain(
    arena: std.mem.Allocator,
    nodes: []const Node,
    first: usize,
) std.mem.Allocator.Error!?[]const usize {
    var order: std.ArrayList(usize) = .empty;
    var cur = first;
    var prev: ?usize = null;
    while (true) {
        try order.append(arena, cur);
        const nd = nodes[cur];
        var next: ?usize = null;
        for (nd.links[0..nd.n_links]) |cand| {
            if (prev != null and cand == prev.?) continue;
            next = cand;
        }
        prev = cur;
        cur = next orelse break;
        if (order.items.len > nodes.len) return null;
    }
    if (order.items.len != nodes.len) return null;
    return try order.toOwnedSlice(arena);
}

/// The chain's two degree-1 ends, ordered so the first is the one nearer
/// `start`. Null unless there are exactly two (a simple open path).
fn chainEnds(nodes: []const Node, start: Pt) ?[2]usize {
    var ends: [2]usize = .{ 0, 0 };
    var count: usize = 0;
    for (nodes, 0..) |nd, i| {
        if (nd.n_links != 1) continue;
        if (count == 2) return null;
        ends[count] = i;
        count += 1;
    }
    if (count != 2) return null;
    const d0 = std.math.hypot(nodes[ends[0]].pt.x - start.x, nodes[ends[0]].pt.y - start.y);
    const d1 = std.math.hypot(nodes[ends[1]].pt.x - start.x, nodes[ends[1]].pt.y - start.y);
    return if (d1 < d0) .{ ends[1], ends[0] } else ends;
}

/// Split an ordered vertex walk into same-layer runs joined by vias.
fn splitRuns(
    arena: std.mem.Allocator,
    nodes: []const Node,
    order: []const usize,
) std.mem.Allocator.Error!Centerline {
    var runs: std.ArrayList(Run) = .empty;
    var vias: std.ArrayList(Pt) = .empty;
    var cur: std.ArrayList(Pt) = .empty;
    var layer: u8 = nodes[order[0]].layer;
    for (order) |i| {
        const nd = nodes[i];
        if (cur.items.len > 0 and nd.layer != layer) {
            // Both runs meet AT the barrel. The maze ends each one on its own
            // grid node, which can sit a fraction of a pad short of the drill
            // centre; starting the next run at the barrel keeps the centreline
            // one continuous polyline, which is what lets the transition slide
            // along it (`shiftVia`).
            const at = cur.items[cur.items.len - 1];
            try vias.append(arena, at);
            try runs.append(arena, .{ .layer = layer, .pts = try cur.toOwnedSlice(arena) });
            cur = .empty;
            try cur.append(arena, at);
        }
        layer = nd.layer;
        if (cur.items.len == 0 or !samePt(cur.items[cur.items.len - 1], nd.pt))
            try cur.append(arena, nd.pt);
    }
    try runs.append(arena, .{ .layer = layer, .pts = try cur.toOwnedSlice(arena) });
    return .{ .runs = try runs.toOwnedSlice(arena), .vias = try vias.toOwnedSlice(arena) };
}

/// Re-read one net's emitted copper as a single ordered centreline beginning at
/// the end nearest `start`. Null when the copper branches, forms a cycle, has a
/// via that does not join exactly two layers, or leaves a disconnected fragment
/// — every shape the pair construction cannot split into two clean legs.
pub fn chain(
    arena: std.mem.Allocator,
    segs: []const Seg,
    vias: []const Pt,
    start: Pt,
    via_tol: f64,
) std.mem.Allocator.Error!?Centerline {
    var nodes: std.ArrayList(Node) = .empty;
    for (segs) |s| {
        if (samePt(s.a, s.b)) continue;
        const a = try nodeIndex(arena, &nodes, s.a, s.layer);
        const b = try nodeIndex(arena, &nodes, s.b, s.layer);
        if (!linkNodes(nodes.items, a, b)) return null;
    }
    if (nodes.items.len < 2) return null;
    for (vias) |v| {
        if (!linkVia(nodes.items, v, via_tol)) return null;
    }
    const ends = chainEnds(nodes.items, start) orelse return null;
    const order = (try walkChain(arena, nodes.items, ends[0])) orelse return null;
    return try splitRuns(arena, nodes.items, order);
}

// ── Leg construction ─────────────────────────────────────────────────────────

/// Unit direction a→b, or null when the two points coincide.
fn unitOf(a: Pt, b: Pt) ?Vec {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len = std.math.hypot(dx, dy);
    if (len <= weld_eps) return null;
    return .{ .x = dx / len, .y = dy / len };
}

/// Left normal of a unit direction.
fn normalOf(d: Vec) Vec {
    return .{ .x = -d.y, .y = d.x };
}

/// `c` shifted `dist` along `n`.
fn shift(c: Pt, n: Vec, dist: f64) Pt {
    return .{ .x = c.x + n.x * dist, .y = c.y + n.y * dist };
}

/// Mitered offset of corner `c` between unit directions `d1`→`d2` on side `s`:
/// the intersection of the two offset lines, so the coupled spacing is exact
/// through the bend. A near-reversal falls back to the outgoing perpendicular.
fn miter(c: Pt, d1: Vec, d2: Vec, off: f64, s: f64) Pt {
    const n1 = Vec{ .x = -d1.y * s, .y = d1.x * s };
    const n2 = Vec{ .x = -d2.y * s, .y = d2.x * s };
    const den = 1 + n1.x * n2.x + n1.y * n2.y;
    if (den < miter_floor) return shift(c, n2, off);
    return .{ .x = c.x + (n1.x + n2.x) * off / den, .y = c.y + (n1.y + n2.y) * off / den };
}

/// Offset one run's vertices by `off` on side `s`: perpendicular at the two
/// ends, mitered at every interior corner. Null when a degenerate vertex pair
/// leaves a corner without a direction.
fn offsetRun(
    arena: std.mem.Allocator,
    pts: []const Pt,
    off: f64,
    s: f64,
) std.mem.Allocator.Error!?[]Pt {
    const out = try arena.alloc(Pt, pts.len);
    const first = unitOf(pts[0], pts[1]) orelse return null;
    out[0] = shift(pts[0], normalOf(first), s * off);
    var i: usize = 1;
    while (i + 1 < pts.len) : (i += 1) {
        const a = unitOf(pts[i - 1], pts[i]) orelse return null;
        const b = unitOf(pts[i], pts[i + 1]) orelse return null;
        out[i] = miter(pts[i], a, b, off, s);
    }
    const last = unitOf(pts[pts.len - 2], pts[pts.len - 1]) orelse return null;
    out[pts.len - 1] = shift(pts[pts.len - 1], normalOf(last), s * off);
    return out;
}

/// Collapse any offset segment that runs BACKWARDS along its centreline
/// segment. That is the inside-corner overshoot: a miter deeper than the
/// segment it sits on would leave a stub jutting into the twin leg's
/// clearance. The pinned ends (a pad centre or a via) never move; an interior
/// overshoot closes onto the midpoint of the two offending vertices.
fn trimOvershoot(off_pts: []Pt, pts: []const Pt) void {
    var i: usize = 0;
    while (i + 1 < off_pts.len) : (i += 1) {
        const d = unitOf(pts[i], pts[i + 1]) orelse continue;
        const dx = off_pts[i + 1].x - off_pts[i].x;
        const dy = off_pts[i + 1].y - off_pts[i].y;
        if (dx * d.x + dy * d.y >= 0) continue;
        if (i == 0) {
            off_pts[1] = off_pts[0];
        } else if (i + 2 == off_pts.len) {
            off_pts[i] = off_pts[i + 1];
        } else {
            const mid = Pt{
                .x = (off_pts[i].x + off_pts[i + 1].x) / 2,
                .y = (off_pts[i].y + off_pts[i + 1].y) / 2,
            };
            off_pts[i] = mid;
            off_pts[i + 1] = mid;
        }
    }
}

/// Window (mm) the end-direction smoothing walks before reading a heading. The
/// centreline's first and last hops are the maze's pad stub — a fraction of a
/// grid cell, pointing wherever the access node happened to sit. Reading the
/// side off THAT is a coin toss; the pair only needs the direction it actually
/// arrives on.
const end_axis_window_mm: f64 = 1.0;

/// The smoothed heading a run leaves its first vertex on (`from_head`) or
/// arrives at its last on. Walks at least `end_axis_window_mm` of path before
/// taking the direction, falling back to the whole run when it is shorter.
fn endAxis(pts: []const Pt, from_head: bool) ?Vec {
    const at = if (from_head) pts[0] else pts[pts.len - 1];
    var walked: f64 = 0;
    var i: usize = 0;
    var far = at;
    while (i + 1 < pts.len) : (i += 1) {
        const step = if (from_head) pts[i + 1] else pts[pts.len - 2 - i];
        walked += std.math.hypot(step.x - far.x, step.y - far.y);
        far = step;
        if (walked >= end_axis_window_mm) break;
    }
    return if (from_head) unitOf(at, far) else unitOf(far, at);
}

/// How strongly the P pad sits on the `+normal` side of a run end.
fn sideVote(pts: []const Pt, pad: Pt, from_head: bool) f64 {
    const at = if (from_head) pts[0] else pts[pts.len - 1];
    const d = endAxis(pts, from_head) orelse return 0;
    const to_pad = unitOf(at, pad) orelse return 0;
    const n = normalOf(d);
    return to_pad.x * n.x + to_pad.y * n.y;
}

/// Which side of the FIRST run's path direction the P leg runs on (+1 / −1).
///
/// BOTH ends vote, because only one side assignment can be right for both: the
/// legs may never swap sides mid-run (that is a short), so the pair has to land
/// P-on-its-pad at each end with one consistent offset. Ends that disagree —
/// a pinout whose two ends twist relative to the path the maze found — leave
/// the majority vote, and the losing end's fan then crosses its twin, which the
/// caller's exact clearance probe refuses. A pair with no signal at either end
/// defaults to +1 (deterministic; the two legs simply swap which side is which).
///
/// The tail's vote is read through `parity` — the accumulated side flip between
/// the first run and the last (see `viaFlips`), because the two ends only speak
/// the same language when the path between them never reverses.
fn sideFor(c: Centerline, o: Options, parity: f64) f64 {
    const head = c.runs[0].pts;
    const tail = c.runs[c.runs.len - 1].pts;
    const score = sideVote(head, outerOf(o.seq[0], .p), true) +
        parity * sideVote(tail, outerOf(o.seq[1], .p), false);
    if (@abs(score) <= side_eps) return 1;
    return if (score > 0) 1 else -1;
}

/// Where the path REVERSES at a via: the run arriving and the run leaving point
/// more against each other than with each other.
///
/// This is the reference's own escape structure — run OUT of a crowded pocket,
/// change layer, come back over yourself — and it is the one place a pair's side
/// bookkeeping cannot be a single number. "Left of the path" names one physical
/// side before such a via and the opposite one after it, so a construction that
/// carries one sign through puts each leg's barrel, and then its whole coupled
/// run, on the side its TWIN's pad is on. The legs are then forced to cross at
/// both escapes to reach their own pads. Flipping the sign here instead keeps
/// each leg physically where its pad is; the two runs pass over each other on
/// DIFFERENT layers, which is exactly why the reference can do it at all.
fn viaFlips(arena: std.mem.Allocator, c: Centerline) std.mem.Allocator.Error![]bool {
    const out = try arena.alloc(bool, c.vias.len);
    for (out, 0..) |*slot, i| slot.* = reversesAt(c, i);
    return out;
}

/// Whether the centreline's run `i` and run `i+1` point more against each other
/// than with each other — the one predicate both the side-sign propagation and
/// `dropHairpinRuns` read, so they can never disagree about where a reversal is.
fn reversesAt(c: Centerline, i: usize) bool {
    const in_pts = c.runs[i].pts;
    const out_pts = c.runs[i + 1].pts;
    const d_in = unitOf(in_pts[in_pts.len - 2], in_pts[in_pts.len - 1]) orelse return false;
    const d_out = unitOf(out_pts[0], out_pts[1]) orelse return false;
    return d_in.x * d_out.x + d_in.y * d_out.y < 0;
}

/// The side sign each RUN's P leg is offset on, in that run's own direction
/// frame: seeded from the ends' vote, flipped at every reversal so the P leg
/// stays on one PHYSICAL side, and flipped again at the transition (if any)
/// asked to absorb the pair's twist.
///
/// Null when the requested arrangement cannot serve this pair's ends: an
/// untwisted pair given a swap, or a twisted pair given none. A twisted pair
/// has NO all-perpendicular construction — the two ends demand opposite sides
/// and one sign cannot be both — so declining here is what sends the caller to
/// the next candidate rather than to a construction its own probe will refuse.
fn runSides(
    arena: std.mem.Allocator,
    c: Centerline,
    o: Options,
    flips: []const bool,
) std.mem.Allocator.Error!?Sides {
    const swaps = try arena.alloc(bool, flips.len);
    @memset(swaps, false);
    if (o.swap_via) |k| {
        if (k >= swaps.len) return null;
        swaps[k] = true;
    }
    var parity: f64 = 1;
    for (flips, swaps) |f, s| {
        if (f != s) parity = -parity;
    }
    if (!servesBothEnds(c, o, parity)) return null;
    const out = try arena.alloc(f64, c.runs.len);
    out[0] = sideFor(c, o, parity);
    for (flips, swaps, 0..) |f, s, i| out[i + 1] = if (f != s) -out[i] else out[i];
    return .{ .run = out, .flips = flips, .swaps = swaps };
}

/// Whether one side assignment carried at `parity` can land BOTH ends on their
/// own pads. False is the pair's twist speaking: the head wants one sign, the
/// tail (read through the parity between them) wants the other.
fn servesBothEnds(c: Centerline, o: Options, parity: f64) bool {
    const head = sideVote(c.runs[0].pts, outerOf(o.seq[0], .p), true);
    const tail = sideVote(c.runs[c.runs.len - 1].pts, outerOf(o.seq[1], .p), false);
    if (@abs(head) <= side_eps or @abs(tail) <= side_eps) return true; // no signal to contradict
    return head * parity * tail > 0;
}

/// `d` negated — the outgoing direction read in the INCOMING run's frame, which
/// is what a reversal via's barrel axis has to be built from.
fn negate(d: Vec) Vec {
    return .{ .x = -d.x, .y = -d.y };
}

/// The pad one side reaches the coupled run at: the last pair of the walk.
fn outerOf(seq: []const PadPair, side: Side) Pt {
    const last = seq[seq.len - 1];
    return if (side == .p) last.p else last.n;
}

/// Via-pair positions for every centreline layer change: both barrels on the
/// normal of the BISECTOR of the incoming and outgoing directions.
///
/// The incoming direction alone is not enough. A centreline that turns at its
/// via would pin both barrels on the incoming normal and then demand the legs
/// leave on the outgoing one — swinging each leg through the other, which is a
/// short. Straddling the bisector splits that rotation evenly, so each leg stays
/// on its own side of the path the whole way through the layer change.
///
/// At a REVERSAL via the outgoing direction is read negated (`viaFlips`), so
/// both runs are described in one frame and every barrel is placed with the
/// INCOMING run's own side sign — which is what puts each barrel on the side its
/// own pad is on rather than its twin's.
fn viaPairs(
    arena: std.mem.Allocator,
    c: Centerline,
    o: Options,
    sides: Sides,
    coupled: []const bool,
    widen: f64,
) std.mem.Allocator.Error!?[]LegVia {
    const out = try arena.alloc(LegVia, c.vias.len);
    for (c.vias, 0..) |v, i| {
        const in_pts = c.runs[i].pts;
        const out_pts = c.runs[i + 1].pts;
        const d_in = unitOf(in_pts[in_pts.len - 2], in_pts[in_pts.len - 1]) orelse return null;
        const raw_out = unitOf(out_pts[0], out_pts[1]) orelse return null;
        const d_out = if (sides.flips[i]) negate(raw_out) else raw_out;
        // Only a run that actually carries coupled copper gets a say in the
        // barrel axis. A pad-escape hop is a free fan — letting its heading into
        // the bisector is what turns a hairpin escape (the maze doubling back to
        // reach its via) into a metre-wide splay for no coupling gain.
        const axis = if (!coupled[i]) d_out else if (!coupled[i + 1]) d_in else bisect(d_in, d_out);
        const ref = if (!coupled[i]) d_out else d_in;
        const n = normalOf(axis);
        const s = sides.run[i];
        if (sides.swaps[i]) {
            // A pad-escape hop has no room for a transition: its whole length is
            // shorter than the excursion the passing leg has to hold, so the
            // construction would sweep back through the pads. The twist waits
            // for a layer change with coupled run on both sides of it.
            if (!coupled[i] or !coupled[i + 1]) return null;
            // And it must be a REAL layer change. `resolveReversals` splits a
            // doubling-back escape and puts a via at the fold, which can leave
            // two same-layer runs joined by a via that changes nothing. Swapping
            // there lays both legs' hold on ONE layer — literally coincident
            // copper, 0.0000 mm apart (measured). The swap needs two layers to
            // pass the legs through each other on.
            if (c.runs[i].layer == c.runs[i + 1].layer) return null;
            // And it needs open board: a transition seated in the pair's own pad
            // field puts a barrel 0.03 mm off its twin's pad walk (measured).
            if (!clearOfPads(v, o, inLineReach(o))) return null;
            const u = bisect(d_in, d_out);
            out[i] = inLineVia(v, .{
                .u = u,
                .n = normalOf(u),
                .n_in = normalOf(d_in),
                .n_out = normalOf(d_out),
                .s = s,
            }, o);
            continue;
        }
        const half = viaHalfSpread(o, ref, axis) * widen;
        out[i] = .{
            .p = shift(v, n, s * half),
            .n = shift(v, n, -s * half),
        };
    }
    return out;
}

/// One centreline's side bookkeeping: which sign each run's P leg is offset on,
/// which vias the path reverses at, and which one (if any) swaps the legs.
const Sides = struct { run: []const f64, flips: []const bool, swaps: []const bool };

/// The frame one in-line transition is built in: along the path, across it, the
/// entry side sign, and the spread ladder's current widening.
const InLineFrame = struct { u: Vec, n: Vec, n_in: Vec, n_out: Vec, s: f64 };

/// Place one IN-LINE via pair and the geometry its legs need around it.
///
/// The barrels sit ON the centreline, staggered `via_spread` apart along the
/// path: `p` first, `n` beyond it. Each leg drops at its own barrel and comes up
/// on the OTHER side, so the pair's twist is absorbed inside the transition
/// where the two legs are on different layers and cannot short.
///
/// The passing leg holds its excursion only ACROSS the barrel pair — from the
/// first drill's station to the second's — and converges outside it. That is
/// what keeps every segment of the detour short: `diff_uncoupled` measures a
/// contiguous uncoupled run WITHIN one track segment, so a transition built
/// from half-millimetre pieces never accumulates the 1 mm it takes to trip,
/// while one long swing around both barrels would.
fn inLineVia(v: Pt, f: InLineFrame, o: Options) LegVia {
    // Deliberately NOT scaled by the spread ladder. A perpendicular pair widens
    // to buy clearance it lacks; an in-line one already holds exactly the
    // clearance it needs, so a widen rung only sweeps its excursion further —
    // on board-a, straight through the pad field it just escaped.
    const exc = o.via_clear * in_line_margin;
    const half_d = o.via_spread / 2;
    // The excursion is held until a full clearance PAST each drill, not merely
    // level with it: a 45° ramp starting level with a barrel dives straight back
    // through its clearance circle (0.33 of a needed 0.45 mm, measured). Held one
    // `exc` beyond, the ramp's own start IS the closest approach, at `exc·√2`.
    const hold_out = half_d + exc;
    // Where the coupled runs stop short: one 45° ramp off the class offset again.
    const lead = hold_out + @max(exc - o.off / 2, 0);
    const near = shift(v, f.u, -half_d);
    const far = shift(v, f.u, half_d);
    const back = shift(v, f.u, -lead);
    const fwd = shift(v, f.u, lead);
    const away = -f.s * exc; // the passing leg's own side, both layers
    // Each truncation point sits on ITS OWN run's offset line, not the
    // bisector's: a coupled run pinned to an anchor off its own line tilts its
    // last segment, and the two legs tilt by different amounts — which reads on
    // the self-check as the legs folding to 0.36 of a needed 0.38 mm.
    return .{
        .p = near,
        .n = far,
        .in_line = .{
            .in_p = shift(back, f.n_in, f.s * o.off / 2),
            .in_n = shift(back, f.n_in, -f.s * o.off / 2),
            .out_p = shift(fwd, f.n_out, -f.s * o.off / 2),
            .out_n = shift(fwd, f.n_out, f.s * o.off / 2),
            // The HOLD stays on the barrel axis' own normal. The barrels sit on
            // `u`, so a hold anchored on the two runs' differing normals tilts
            // relative to them and loses clearance (0.43 of a needed 0.45 mm,
            // measured); only the truncation points, which touch no barrel,
            // follow their own run.
            .hold = .{
                shift(shift(v, f.u, -hold_out), f.n, away),
                shift(shift(v, f.u, hold_out), f.n, away),
            },
        },
    };
}

/// How far an in-line transition reaches from its via centre — the outermost
/// copper it lays, which is what has to clear the pad field.
fn inLineReach(o: Options) f64 {
    const exc = o.via_clear * in_line_margin;
    return o.via_spread / 2 + exc + @max(exc - o.off / 2, 0);
}

/// Whether `v` is at least `reach` from every pad of both ends.
fn clearOfPads(v: Pt, o: Options, reach: f64) bool {
    for (o.seq) |seq| {
        for (seq) |pp| {
            if (std.math.hypot(v.x - pp.p.x, v.y - pp.p.y) < reach) return false;
            if (std.math.hypot(v.x - pp.n.x, v.y - pp.n.y) < reach) return false;
        }
    }
    return true;
}

/// One side's copper through an in-line transition, on both layers.
///
/// P drops at the near barrel and comes back over the pair on the exit layer; N
/// goes the other way round on the entry layer. The two passes are mirror
/// images through the barrel pair, so the legs come out exactly length-matched
/// and each holds its excursion on the side it is leaving towards.
fn emitInLine(
    arena: std.mem.Allocator,
    out: *std.ArrayList(LegSeg),
    side: Side,
    v: LegVia,
    layers: [2]u8,
) std.mem.Allocator.Error!void {
    const il = v.in_line orelse return;
    // .chain, not .fan: this copper threads two drills at exact clearance, so
    // the length-match detour may never reshape it — and it needs no reshaping,
    // being a mirror image of the twin's pass and therefore already matched.
    const tag_in = WalkTag{ .layer = layers[0], .side = side, .kind = .chain };
    const tag_out = WalkTag{ .layer = layers[1], .side = side, .kind = .chain };
    if (side == .p) {
        // Straight in to the near barrel, then back over the pair to the far side.
        try appendWalkSeg(arena, out, il.in_p, v.p, tag_in);
        try appendWalkSeg(arena, out, v.p, il.hold[0], tag_out);
        try appendWalkSeg(arena, out, il.hold[0], il.hold[1], tag_out);
        try appendWalkSeg(arena, out, il.hold[1], il.out_p, tag_out);
        return;
    }
    // N is the passing leg on the ENTRY layer and the straight one on the exit.
    try appendWalkSeg(arena, out, il.in_n, il.hold[0], tag_in);
    try appendWalkSeg(arena, out, il.hold[0], il.hold[1], tag_in);
    try appendWalkSeg(arena, out, il.hold[1], v.n, tag_in);
    try appendWalkSeg(arena, out, v.n, il.out_n, tag_out);
}

/// How far past the barrel pair the coupled runs stop short, and how far out the
/// passing leg holds while it clears both drills. The excursion is the honest
/// via-to-track clearance with a small margin, so the construction's own probe
/// is not deciding on an exact tie.
const in_line_margin: f64 = 1.1;

/// The closest the two legs come as a fraction of their coupled offset, where
/// they leave the coupled run into an in-line transition. Two segments starting
/// at the same station on different headings are nearer than their lateral gap
/// by the cosine of the angle between them; the passing leg turns out at 45°
/// while its twin dives more gently onto its barrel, so a few percent is spent
/// there. Widening the transition spends LESS (the dive gets shallower), and the
/// caller's exact clearance probe rules on the result either way.
const in_line_dip_floor: f64 = 0.95;

/// Half the centre-to-centre spread one via pair needs.
///
/// Straddling the bisector tilts each barrel `θ/2` off both runs' normals, so
/// only `2·half·cos(θ/2)` of the spread is measured ACROSS either run. Two
/// consequences, both solved here: the barrels must still sit at least the
/// coupled offset apart across the run (or the legs pinch below `off` as they
/// leave the via), and each barrel must clear the opposite leg's track, which
/// it approaches at `half·cos(θ/2) + off/2`. A via mid-run has `cos(θ/2) = 1`
/// and reduces to the flat `via_spread`.
fn viaHalfSpread(o: Options, d_in: Vec, axis: Vec) f64 {
    const cos_half = @max(d_in.x * axis.x + d_in.y * axis.y, miter_floor);
    const across = o.off / (2 * cos_half);
    const clear = (o.via_clear - o.off / 2) / cos_half;
    return @max(o.via_spread / 2, @max(across, clear));
}

/// Unit bisector of two directions; the incoming one when they near-reverse.
fn bisect(a: Vec, b: Vec) Vec {
    const sx = a.x + b.x;
    const sy = a.y + b.y;
    const len = std.math.hypot(sx, sy);
    if (len <= miter_floor) return a;
    return .{ .x = sx / len, .y = sy / len };
}

/// Where one leg's run `i` is PINNED: its own via barrel at each layer change,
/// and nothing at the chain's two outer ends — there the leg keeps its natural
/// perpendicular offset all the way to the terminal and a separate short fan
/// carries it out to the pad. Dragging the last coupled vertex onto the pad
/// instead would stretch a millimetre-long diagonal across the neighbouring
/// pads of the very connector it is landing on.
fn runAnchors(runs: usize, pairs: []const LegVia, side: Side, i: usize) [2]?Pt {
    const head: ?Pt = if (i == 0) null else anchorAt(pairs[i - 1], side, .out);
    const tail: ?Pt = if (i + 1 == runs) null else anchorAt(pairs[i], side, .in);
    return .{ head, tail };
}

/// Which side of a via a run meets it on.
const AnchorEnd = enum { in, out };

/// Where one leg's coupled run meets via `v`: the barrel itself for a
/// perpendicular pair, or — for an IN-LINE one — the point the run stops short
/// at, because everything between there and the barrel is the transition's own
/// copper and is not an offset of the centreline.
fn anchorAt(v: LegVia, side: Side, end: AnchorEnd) Pt {
    if (v.in_line) |il| return switch (end) {
        .in => if (side == .p) il.in_p else il.in_n,
        .out => if (side == .p) il.out_p else il.out_n,
    };
    return if (side == .p) v.p else v.n;
}

/// One leg's copper for one run: offset, anchored at its two ends, overshoot
/// trimmed, emitted as segments with the degenerate ones dropped.
fn emitRun(
    arena: std.mem.Allocator,
    out: *std.ArrayList(LegSeg),
    run: Run,
    plan: RunPlan,
) std.mem.Allocator.Error!?[2]Pt {
    const off_pts = (try offsetRun(arena, run.pts, plan.off, plan.s)) orelse return null;
    // Hold the class gap right up to each barrel's doorstep and neck out to it in
    // ONE 45° jog, rather than letting the whole last segment carry the spread.
    //
    // Anchoring the offset run straight onto a barrel spreads the neck over
    // however long that segment happens to be — 3.6 mm at board-a's connector,
    // i.e. 3.6 mm of line whose spacing (and so impedance) is wrong by a little
    // everywhere instead of a fifth of a millimetre that is wrong by design.
    const necks = [2]?Pt{
        neckDoorstep(off_pts, run.pts, plan.anchors[0], .head),
        neckDoorstep(off_pts, run.pts, plan.anchors[1], .tail),
    };
    if (plan.anchors[0]) |at| off_pts[0] = necks[0] orelse at;
    if (plan.anchors[1]) |at| off_pts[off_pts.len - 1] = necks[1] orelse at;
    trimOvershoot(off_pts, run.pts);
    const tag = WalkTag{ .layer = run.layer, .side = plan.side, .kind = .coupled };
    if (necks[0] != null) if (plan.anchors[0]) |at| try appendWalkSeg(arena, out, at, off_pts[0], tag);
    var i: usize = 0;
    while (i + 1 < off_pts.len) : (i += 1) {
        if (samePt(off_pts[i], off_pts[i + 1])) continue;
        // Tag by POSITION, not index: a collapsed head miter drops the first
        // segment, and the hop that then starts on the pad is still the fan.
        try out.append(arena, .{
            .a = off_pts[i],
            .b = off_pts[i + 1],
            .layer = run.layer,
            .side = plan.side,
            .kind = .coupled,
        });
    }
    const last = off_pts.len - 1;
    if (necks[1] != null) if (plan.anchors[1]) |at| try appendWalkSeg(arena, out, off_pts[last], at, tag);
    return .{
        if (necks[0] != null) plan.anchors[0].? else off_pts[0],
        if (necks[1] != null) plan.anchors[1].? else off_pts[last],
    };
}

/// Where a run stops short of a barrel so the neck out to it is one 45° jog:
/// the natural class-gap endpoint moved INTO the run by the barrel's own lateral
/// displacement. Null when there is no anchor, no displacement worth a jog, or
/// the end segment is too short to give the jog room — then the run anchors
/// directly onto the barrel, as it always did.
fn neckDoorstep(off_pts: []const Pt, pts: []const Pt, anchor: ?Pt, side: RunEndSide) ?Pt {
    const at = anchor orelse return null;
    const i: usize = if (side == .head) 0 else off_pts.len - 1;
    const nat = off_pts[i];
    const d = if (side == .head)
        unitOf(pts[0], pts[1]) orelse return null
    else
        unitOf(pts[pts.len - 1], pts[pts.len - 2]) orelse return null;
    // A neck is a LATERAL step out to a barrel. An IN-LINE via pair staggers its
    // barrels ALONG the run instead, so the offset endpoint and the anchor differ
    // mostly in station — and treating that as a neck builds a near-perpendicular
    // "jog" whose twin lands on top of it (0.08 of a needed 0.38 mm, measured).
    // Anything not predominantly lateral anchors directly, as it always did.
    const v = Vec{ .x = at.x - nat.x, .y = at.y - nat.y };
    const along = v.x * d.x + v.y * d.y;
    const lateral = std.math.hypot(v.x - along * d.x, v.y - along * d.y);
    if (lateral < miter_floor * neck_min_frac) return null;
    if (@abs(along) > lateral) return null;
    const j: usize = if (side == .head) 1 else off_pts.len - 2;
    if (std.math.hypot(off_pts[j].x - nat.x, off_pts[j].y - nat.y) <= lateral) return null;
    return shift(nat, d, lateral);
}

/// Smallest lateral step (as a fraction of the miter floor) worth spending a
/// separate 45° jog on. Below it the neck is inside the copper's own width and a
/// direct anchor is the tidier geometry.
const neck_min_frac: f64 = 0.1;

/// Per-run construction parameters for `emitRun`.
const RunPlan = struct {
    side: Side,
    off: f64,
    s: f64,
    anchors: [2]?Pt,
};

/// Un-couple the shorter run at every via the centreline HAIRPINS through.
///
/// A maze that doubles back to reach its layer change leaves the two runs
/// pointing more than 90° apart. The legs' sides are defined relative to the
/// direction of travel, so a turn that sharp swaps which side each leg is on —
/// mid-run, on one layer, which is a short. The short arm of such a turn is the
/// pad escape, never the haul, so dropping ITS coupling costs nothing: each leg
/// simply fans from its own barrel to its own pad.
fn dropHairpinRuns(c: Centerline, coupled: []bool) void {
    for (c.vias, 0..) |_, i| {
        if (!reversesAt(c, i)) continue;
        const drop = if (runLength(c.runs[i].pts) <= runLength(c.runs[i + 1].pts)) i else i + 1;
        coupled[drop] = false;
    }
}

/// A point found at some arc length along a polyline, plus how many leading
/// vertices lie strictly before it.
const Along = struct { at: Pt, before: usize };

/// The point `dist` along `pts` from its head. Null when the polyline is shorter.
fn walkAlong(pts: []const Pt, dist: f64) ?Along {
    var left = dist;
    for (pts[1..], 0..) |pt, i| {
        const seg = std.math.hypot(pt.x - pts[i].x, pt.y - pts[i].y);
        if (seg <= weld_eps) continue;
        if (left <= seg) return .{ .at = lerp(pts[i], pt, left / seg), .before = i + 1 };
        left -= seg;
    }
    return null;
}

/// The point `dist` back from the TAIL of `pts`. Null when it is shorter.
fn walkAlongBack(pts: []const Pt, dist: f64) ?Along {
    var left = dist;
    var i = pts.len - 1;
    while (i > 0) : (i -= 1) {
        const seg = std.math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
        if (seg <= weld_eps) continue;
        if (left <= seg) return .{ .at = lerp(pts[i], pts[i - 1], left / seg), .before = i };
        left -= seg;
    }
    return null;
}

/// Linear interpolation `a`→`b` at fraction `t`.
fn lerp(a: Pt, b: Pt, t: f64) Pt {
    return .{ .x = a.x + t * (b.x - a.x), .y = a.y + t * (b.y - a.y) };
}

/// Shortest either run may become when a transition slides — below this the run
/// stops being a coupled stretch and the move has bought nothing.
const min_run_after_shift_mm: f64 = 1.0;

/// Slide the layer change joining runs `i` and `i+1` `delta` mm along the path:
/// positive walks it FORWARD into run `i+1`, negative back into run `i`. The
/// copper it passes over changes layer with it; nothing else moves.
///
/// A pair crossing between board faces needs exactly ONE transition, and the
/// maze put it wherever ITS single-track search happened to change layers —
/// routinely inside the pad pocket it was escaping, where two barrels plus
/// their clearance do not fit however the spread is solved. The transition is
/// free to sit anywhere along the run, so the caller walks it out of the pocket
/// instead of abandoning the pair. Null when the shift would consume either run
/// or run off the end of the path.
pub fn shiftVia(
    arena: std.mem.Allocator,
    c: Centerline,
    i: usize,
    delta: f64,
) std.mem.Allocator.Error!?Centerline {
    if (i >= c.vias.len or @abs(delta) <= weld_eps) return null;
    const in_pts = c.runs[i].pts;
    const out_pts = c.runs[i + 1].pts;
    const moved: Split = if (delta > 0)
        (try splitForward(arena, in_pts, out_pts, delta)) orelse return null
    else
        (try splitBackward(arena, in_pts, out_pts, -delta)) orelse return null;
    if (runLength(moved.in) < min_run_after_shift_mm) return null;
    if (runLength(moved.out) < min_run_after_shift_mm) return null;
    const runs = try arena.dupe(Run, c.runs);
    runs[i] = .{ .layer = c.runs[i].layer, .pts = moved.in };
    runs[i + 1] = .{ .layer = c.runs[i + 1].layer, .pts = moved.out };
    const vias = try arena.dupe(Pt, c.vias);
    vias[i] = moved.at;
    return .{ .runs = runs, .vias = vias };
}

/// The two rewritten runs and the transition point between them.
const Split = struct { in: []const Pt, out: []const Pt, at: Pt };

/// Move the transition forward: the head of the outgoing run joins the incoming.
fn splitForward(
    arena: std.mem.Allocator,
    in_pts: []const Pt,
    out_pts: []const Pt,
    dist: f64,
) std.mem.Allocator.Error!?Split {
    const hit = walkAlong(out_pts, dist) orelse return null;
    var head: std.ArrayList(Pt) = .empty;
    try head.appendSlice(arena, in_pts);
    try head.appendSlice(arena, out_pts[1..hit.before]);
    try head.append(arena, hit.at);
    var tail: std.ArrayList(Pt) = .empty;
    try tail.append(arena, hit.at);
    try tail.appendSlice(arena, out_pts[hit.before..]);
    return .{ .in = try head.toOwnedSlice(arena), .out = try tail.toOwnedSlice(arena), .at = hit.at };
}

/// Move the transition back: the tail of the incoming run joins the outgoing.
fn splitBackward(
    arena: std.mem.Allocator,
    in_pts: []const Pt,
    out_pts: []const Pt,
    dist: f64,
) std.mem.Allocator.Error!?Split {
    const hit = walkAlongBack(in_pts, dist) orelse return null;
    var head: std.ArrayList(Pt) = .empty;
    try head.appendSlice(arena, in_pts[0..hit.before]);
    try head.append(arena, hit.at);
    var tail: std.ArrayList(Pt) = .empty;
    try tail.append(arena, hit.at);
    try tail.appendSlice(arena, in_pts[hit.before..]);
    try tail.appendSlice(arena, out_pts[1..]);
    return .{ .in = try head.toOwnedSlice(arena), .out = try tail.toOwnedSlice(arena), .at = hit.at };
}

/// Total path length of a polyline.
fn runLength(pts: []const Pt) f64 {
    var sum: f64 = 0;
    for (pts[1..], 0..) |pt, i| sum += std.math.hypot(pt.x - pts[i].x, pt.y - pts[i].y);
    return sum;
}

/// Drop centreline vertices closer together than `min_seg`, keeping every run's
/// two endpoints (they are the pad terminals and the via sites).
///
/// The maze's pad stub is a fraction of a grid cell: a couple of hops of a
/// tenth of a millimetre pointing wherever the access node sat. Offsetting THAT
/// by ±(width+gap)/2 folds the two legs through each other, because the miter
/// at each micro-corner is deeper than the segment it sits on. Simplifying
/// first costs at most `min_seg` of centreline fidelity — and every constructed
/// leg is exact-probed against real obstacles afterwards regardless.
fn simplify(
    arena: std.mem.Allocator,
    c: Centerline,
    min_seg: f64,
    trim: RunEnds,
) std.mem.Allocator.Error!Centerline {
    const thin = try arena.alloc(Run, c.runs.len);
    const trimmed = try arena.alloc(RunEnds, c.runs.len);
    for (c.runs, thin, trimmed, 0..) |run, *slot, *flags, ri| {
        // Retraced copper goes FIRST: it is the terminal walk-back artifact, and
        // left in place `resolveReversals` reads the fold as an escape and spends
        // a whole via pair turning redundant copper into a layer change.
        const cut = try dropSelfOverlap(arena, try thinPts(arena, run.pts, min_seg));
        var pts = cut.pts;
        flags.* = cut.ends;
        // A requested trim: this end approaches straight, and the turn it removed
        // is no longer an escape for `resolveReversals` to spend a via pair on.
        if (trim.head and ri == 0) {
            pts = try trimEnd(arena, pts, .head);
            flags.head = true;
        }
        if (trim.tail and ri + 1 == c.runs.len) {
            pts = try trimEnd(arena, pts, .tail);
            flags.tail = true;
        }
        slot.* = .{ .layer = run.layer, .pts = pts };
    }
    // A doubling-back at an escape is a LAYER CHANGE, not a corner to cut; only
    // what survives that is cut as a hairpin.
    const turned = try dropNoOpVias(arena, try resolveReversals(arena, .{ .runs = thin, .vias = c.vias }, trimmed));
    const runs = try arena.alloc(Run, turned.runs.len);
    for (turned.runs, runs) |run, *slot| slot.* = .{
        .layer = run.layer,
        // Re-normalize: CONCATENATING runs re-introduces exactly what the first
        // thinning removed. The joint the merge dissolved was a via site, so the
        // vertices either side of it were pinned and survived — and two of them
        // a tenth of a millimetre apart, offset by half the class gap, miter
        // deeper than the segment they sit on and fold the legs (0.12 of a
        // needed 0.38 mm, measured).
        .pts = try dropHairpins(arena, (try dropSelfOverlap(arena, try thinPts(arena, run.pts, min_seg))).pts),
    };
    return .{ .runs = runs, .vias = turned.vias };
}

/// Cosine below which two consecutive centreline segments count as RETRACING
/// each other — essentially anti-parallel, i.e. the path folded back along the
/// line it arrived on.
const retrace_cos: f64 = -0.9995;

/// How many rebuild passes the topology cleanups may take. Each removes at
/// least one via or vertex, so the bound is a safety net, not a policy.
const cleanup_rounds: usize = 8;

/// Delete every vertex a run folds back through, so no run retraces its own
/// copper.
///
/// Same-net copper may legally overlap — nothing separates a net from itself —
/// which is exactly why an overlap is so damaging: every clearance probe passes
/// it, and every length measured as a SUM of segments counts the overlapped
/// stretch twice. A pair whose leg retraces 0.24 mm of itself reports a skew it
/// does not have.
///
/// It arises structurally, not from bad routing: the maze is aimed at a terminal
/// set `escape_run_mm` BEYOND the pad-field exit so its approach is straight,
/// and the centreline is then carried back to that exit — which, when the
/// approach came in along the escape line, retraces the last stretch of it. The
/// fold vertex is redundant either way round (a longer return consumes the
/// outbound segment; a shorter one lies inside it), so the fix is the same:
/// drop it.
fn dropSelfOverlap(arena: std.mem.Allocator, pts: []const Pt) std.mem.Allocator.Error!Trimmed {
    var cur = pts;
    var ends = RunEnds{ .head = false, .tail = false };
    for (0..cleanup_rounds) |_| {
        const at = retraceVertex(cur) orelse return .{ .pts = cur, .ends = ends };
        if (at <= 1) ends.head = true;
        if (at + 2 >= cur.len) ends.tail = true;
        const out = try arena.alloc(Pt, cur.len - 1);
        @memcpy(out[0..at], cur[0..at]);
        @memcpy(out[at..], cur[at + 1 ..]);
        cur = out;
    }
    return .{ .pts = cur, .ends = ends };
}

/// A de-overlapped run, and which of its ends lost a fold vertex.
const Trimmed = struct { pts: []const Pt, ends: RunEnds };

/// The first interior vertex whose two segments are anti-parallel.
fn retraceVertex(pts: []const Pt) ?usize {
    if (pts.len < 3) return null;
    for (pts[1 .. pts.len - 1], 1..) |pt, i| {
        const a = unitOf(pts[i - 1], pt) orelse continue;
        const b = unitOf(pt, pts[i + 1]) orelse continue;
        if (a.x * b.x + a.y * b.y <= retrace_cos) return i;
    }
    return null;
}

/// Which end of a run a trim applies to.
const RunEndSide = enum { head, tail };

/// Delete the vertices an end OVERRUNS its terminal by, so the run approaches
/// straight.
///
/// A vertex overruns when the terminal and the vertex before it lie on the SAME
/// side of it — the run went out past where it was going and came back. Deleting
/// it shortens the copper and, by removing the turn, saves the entire via pair
/// `resolveReversals` would otherwise spend representing that turn. Whether the
/// shortcut is legal is not a question geometry can answer, which is exactly why
/// this is only ever offered as a candidate.
fn trimEnd(
    arena: std.mem.Allocator,
    pts: []const Pt,
    side: RunEndSide,
) std.mem.Allocator.Error![]const Pt {
    var cur = pts;
    for (0..cleanup_rounds) |_| {
        if (cur.len < 3) return cur;
        const at: usize = if (side == .tail) cur.len - 2 else 1;
        const term = if (side == .tail) cur[cur.len - 1] else cur[0];
        const prev = if (side == .tail) cur[cur.len - 3] else cur[2];
        const v = cur[at];
        const to_term = Vec{ .x = v.x - term.x, .y = v.y - term.y };
        const to_prev = Vec{ .x = v.x - prev.x, .y = v.y - prev.y };
        if (to_term.x * to_prev.x + to_term.y * to_prev.y <= 0) return cur;
        const out = try arena.alloc(Pt, cur.len - 1);
        @memcpy(out[0..at], cur[0..at]);
        @memcpy(out[at..], cur[at + 1 ..]);
        cur = out;
    }
    return cur;
}

/// Merge the runs either side of a via that changes nothing, dropping the via.
///
/// `resolveReversals` splits a run and puts a via at the fold, which can leave
/// the ORIGINAL via next door joining two runs that are now on the same layer.
/// Such a via is pure cost: a drill, an annular ring, two barrels the pair has
/// to spread, and no layer change.
fn dropNoOpVias(arena: std.mem.Allocator, c: Centerline) std.mem.Allocator.Error!Centerline {
    var cur = c;
    for (0..cleanup_rounds) |_| {
        const at = firstNoOp(cur) orelse return cur;
        cur = try mergeRuns(arena, cur, at, at + 1, cur.runs[at].layer);
    }
    return cur;
}

/// The first via with the same layer on both sides.
fn firstNoOp(c: Centerline) ?usize {
    for (c.vias, 0..) |_, i| {
        if (c.runs[i].layer == c.runs[i + 1].layer) return i;
    }
    return null;
}

/// Splice runs `lo..=hi` into ONE run on `layer`, dropping the vias between
/// them. The joint vertices are shared, so each run contributes all but its
/// first point after the first.
fn mergeRuns(
    arena: std.mem.Allocator,
    c: Centerline,
    lo: usize,
    hi: usize,
    layer: u8,
) std.mem.Allocator.Error!Centerline {
    var pts: std.ArrayList(Pt) = .empty;
    for (c.runs[lo .. hi + 1], lo..) |run, i| {
        try pts.appendSlice(arena, if (i == lo) run.pts else run.pts[1..]);
    }
    var runs: std.ArrayList(Run) = .empty;
    try runs.appendSlice(arena, c.runs[0..lo]);
    try runs.append(arena, .{ .layer = layer, .pts = try pts.toOwnedSlice(arena) });
    try runs.appendSlice(arena, c.runs[hi + 1 ..]);
    var vias: std.ArrayList(Pt) = .empty;
    try vias.appendSlice(arena, c.vias[0..lo]);
    try vias.appendSlice(arena, c.vias[hi..]);
    return .{ .runs = try runs.toOwnedSlice(arena), .vias = try vias.toOwnedSlice(arena) };
}

/// How far from an end terminal a reversal still counts as the escape's, rather
/// than a mid-route wiggle the maze should simply not have made.
const escape_reversal_mm: f64 = 2.5;

/// Turn each escape-end reversal into a layer transition.
///
/// A pair leaving a crowded pocket runs OUT of it, changes layer, and comes
/// back over itself on the other side — that is what the hand reference does,
/// and it is the only way a pair whose exit faces away from its destination
/// gets anywhere. The maze expresses the same intent as a same-layer doubling
/// back, which cannot be offset (the legs would swap sides mid-run). Splitting
/// the run at the reversal and putting the pair's via there recovers the
/// reference's structure exactly, and keeps the straight escape segment that
/// aligns the legs' offsets with the axis their pads are separated on.
///
/// Only reversals near an END are converted: a mid-route hairpin is a routing
/// artifact with no escape to serve, and `dropHairpins` still cuts those.
fn resolveReversals(
    arena: std.mem.Allocator,
    c: Centerline,
    trimmed: []const RunEnds,
) std.mem.Allocator.Error!Centerline {
    const alt = altLayers(c);
    var runs: std.ArrayList(Run) = .empty;
    var vias: std.ArrayList(Pt) = .empty;
    for (c.runs, 0..) |run, ri| {
        // An end that just lost a fold vertex is the walk-back to the pad-field
        // exit, not an escape: the maze arrived along the terminal's own axis and
        // overshot it. Spending a layer change on what is left of that fold buys
        // two barrels 0.24 mm from the next pair and no route.
        const at = escapeReversal(run.pts, .{
            .head = ri == 0 and !trimmed[ri].head,
            .tail = ri + 1 == c.runs.len and !trimmed[ri].tail,
        });
        if (at) |k| {
            try runs.append(arena, .{ .layer = run.layer, .pts = run.pts[0 .. k + 1] });
            try vias.append(arena, run.pts[k]);
            try runs.append(arena, .{ .layer = otherLayer(run.layer, alt), .pts = run.pts[k..] });
        } else {
            try runs.append(arena, run);
        }
        if (ri < c.vias.len) try vias.append(arena, c.vias[ri]);
    }
    return .{ .runs = try runs.toOwnedSlice(arena), .vias = try vias.toOwnedSlice(arena) };
}

/// Which ends of a run touch the centreline's own ends.
pub const RunEnds = struct { head: bool, tail: bool };

/// The first reversal vertex within `escape_reversal_mm` of an end this run
/// owns, or null.
fn escapeReversal(pts: []const Pt, ends: RunEnds) ?usize {
    if (pts.len < 3) return null;
    var from_head: f64 = 0;
    for (pts[1 .. pts.len - 1], 1..) |pt, i| {
        from_head += std.math.hypot(pt.x - pts[i - 1].x, pt.y - pts[i - 1].y);
        const a = unitOf(pts[i - 1], pt) orelse continue;
        const b = unitOf(pt, pts[i + 1]) orelse continue;
        if (a.x * b.x + a.y * b.y > hairpin_cos) continue;
        const near_head = ends.head and from_head <= escape_reversal_mm;
        const near_tail = ends.tail and runLength(pts[i..]) <= escape_reversal_mm;
        if (near_head or near_tail) return i;
    }
    return null;
}

/// The two outer layers this centreline lives on. A centreline already using
/// two layers names them; one using a single layer pairs it with its sibling
/// outer face, which is where a return run has to go.
fn altLayers(c: Centerline) [2]u8 {
    const first = c.runs[0].layer;
    for (c.runs) |run| {
        if (run.layer != first) return .{ first, run.layer };
    }
    return .{ first, if (first == 0) 1 else 0 };
}

/// The layer a return run takes: whichever of `alt` this one is not.
fn otherLayer(layer: u8, alt: [2]u8) u8 {
    return if (layer == alt[0]) alt[1] else alt[0];
}

/// Cosine below which a centreline corner counts as a HAIRPIN — a turn past
/// ~120°, which no offset construction survives.
const hairpin_cos: f64 = -0.5;

/// Shortcut every hairpin vertex out of one run.
///
/// A pair's legs sit on opposite sides of the path, and "side" is defined by
/// the direction of travel — so a centreline that doubles back swaps which side
/// each leg is on, mid-run, on one layer. That is a short, and no miter can
/// rescue it. A hairpin on the same layer is always a routing artifact (the
/// maze reaching out to a terminal and turning straight round), so the corner
/// is cut instead of mitered; the constructed legs are exact-probed afterwards
/// either way. Endpoints are pinned — they are pads and via barrels.
fn dropHairpins(arena: std.mem.Allocator, pts: []const Pt) std.mem.Allocator.Error![]const Pt {
    if (pts.len < 3) return pts;
    var out: std.ArrayList(Pt) = .empty;
    try out.append(arena, pts[0]);
    for (pts[1 .. pts.len - 1], 1..) |pt, i| {
        const prev = out.items[out.items.len - 1];
        const a = unitOf(prev, pt) orelse continue;
        const b = unitOf(pt, pts[i + 1]) orelse continue;
        if (a.x * b.x + a.y * b.y <= hairpin_cos) continue; // cut the corner
        try out.append(arena, pt);
    }
    try out.append(arena, pts[pts.len - 1]);
    return out.toOwnedSlice(arena);
}

/// One run's vertices thinned to `min_seg` spacing, endpoints preserved.
fn thinPts(
    arena: std.mem.Allocator,
    pts: []const Pt,
    min_seg: f64,
) std.mem.Allocator.Error![]const Pt {
    if (pts.len <= 2) return pts;
    var out: std.ArrayList(Pt) = .empty;
    try out.append(arena, pts[0]);
    for (pts[1 .. pts.len - 1]) |pt| {
        const last = out.items[out.items.len - 1];
        if (std.math.hypot(pt.x - last.x, pt.y - last.y) >= min_seg) try out.append(arena, pt);
    }
    // The tail vertex is mandatory, so drop whatever it crowds.
    const tail = pts[pts.len - 1];
    while (out.items.len > 1) {
        const last = out.items[out.items.len - 1];
        if (std.math.hypot(tail.x - last.x, tail.y - last.y) >= min_seg) break;
        _ = out.pop();
    }
    try out.append(arena, tail);
    return out.toOwnedSlice(arena);
}

/// Prepend/append the pad-field exit centres to a chained centreline, so its
/// first and last segments run straight along each end's escape.
pub fn extendEnds(
    arena: std.mem.Allocator,
    c: Centerline,
    head: Terminal,
    tail: Terminal,
) std.mem.Allocator.Error!Centerline {
    if (c.runs.len == 0) return c;
    const runs = try arena.dupe(Run, c.runs);
    runs[0] = .{ .layer = c.runs[0].layer, .pts = try prepend(arena, .{ .x = head.x, .y = head.y }, c.runs[0].pts) };
    const last = runs.len - 1;
    runs[last] = .{ .layer = c.runs[last].layer, .pts = try appendPt(arena, runs[last].pts, .{ .x = tail.x, .y = tail.y }) };
    return .{ .runs = runs, .vias = c.vias };
}

/// `pts` with `at` in front (skipped when it already starts there).
fn prepend(arena: std.mem.Allocator, at: Pt, pts: []const Pt) std.mem.Allocator.Error![]const Pt {
    if (pts.len > 0 and samePt(pts[0], at)) return pts;
    const out = try arena.alloc(Pt, pts.len + 1);
    out[0] = at;
    @memcpy(out[1..], pts);
    return out;
}

/// `pts` with `at` on the end (skipped when it already ends there).
fn appendPt(arena: std.mem.Allocator, pts: []const Pt, at: Pt) std.mem.Allocator.Error![]const Pt {
    if (pts.len > 0 and samePt(pts[pts.len - 1], at)) return pts;
    const out = try arena.alloc(Pt, pts.len + 1);
    @memcpy(out[0..pts.len], pts);
    out[pts.len] = at;
    return out;
}

/// Split `c` into the pair's two legs. Returns null when the centreline cannot
/// carry a coupled pair — an empty or malformed chain, a run with fewer than
/// two vertices, or a degenerate direction — leaving the caller on its
/// fallback path.
pub fn build(
    arena: std.mem.Allocator,
    raw: Centerline,
    o: Options,
) std.mem.Allocator.Error!?Legs {
    if (raw.runs.len == 0 or raw.vias.len + 1 != raw.runs.len) return null;
    for (raw.runs) |run| {
        if (run.pts.len < 2) return null;
    }
    const c = try simplify(arena, raw, o.off, o.trim);
    const flips = try viaFlips(arena, c);
    const sides = (try runSides(arena, c, o, flips)) orelse return null;
    const coupled = try arena.alloc(bool, c.runs.len);
    for (c.runs, coupled) |run, *slot| slot.* = runLength(run.pts) >= o.off * 2;
    dropHairpinRuns(c, coupled);
    var widen: f64 = 1;
    var last: ?Legs = null;
    for (0..via_widen_rungs) |_| {
        const legs = (try buildAt(arena, c, o, .{ .sides = sides, .coupled = coupled, .widen = widen })) orelse
            return last;
        if (barrelsClear(legs, o.via_clear) and try legsSelfSimple(arena, legs)) return legs;
        last = legs;
        widen += via_widen_step;
    }
    return last;
}

/// How far a via pair's spread may be grown looking for one its own barrels
/// clear the opposite leg's copper at, and the step it grows in.
const via_widen_rungs: usize = 6;
const via_widen_step: f64 = 0.15;

/// The per-attempt inputs `buildAt` shares with `build`.
const BuildPlan = struct { sides: Sides, coupled: []const bool, widen: f64 };

/// True when every via barrel clears the OPPOSITE leg's constructed copper.
///
/// `viaHalfSpread` sizes a pair against copper running PARALLEL at the coupling
/// offset, which is exactly what the coupled run does. A via terminating a
/// pad-escape fan faces something else entirely: copper aimed AT its twin
/// barrel, converging from the pads' own pitch, which comes closer than the
/// parallel model predicts (0.42 of a needed 0.45 mm on board-a's LMX
/// escape). A barrel is on every layer, so every opposite segment counts.
fn barrelsClear(legs: Legs, via_clear: f64) bool {
    return tightestBarrel(legs, via_clear) == null;
}

/// The barrel/segment pair that comes closest, when any is closer than
/// `via_clear`. The measurement the ladder reacts to, exposed so a construction
/// the ladder cannot rescue says WHICH of its own barrels it could not seat.
fn tightestBarrel(legs: Legs, via_clear: f64) ?BarrelClash {
    if (!(via_clear > 0)) return null;
    var worst: ?BarrelClash = null;
    for (legs.vias) |v| {
        for (legs.segs) |s| {
            const at = if (s.side == .p) v.n else v.p;
            const d = pointSeg(at, s.a, s.b);
            if (d >= via_clear) continue;
            if (worst) |w| {
                if (d >= w.gap) continue;
            }
            worst = .{ .at = at, .seg = s, .gap = d, .need = via_clear };
        }
    }
    return worst;
}

/// One barrel too close to the opposite leg's copper.
pub const BarrelClash = struct { at: Pt, seg: LegSeg, gap: f64, need: f64 };

/// The construction's own worst barrel seating, for the caller's census.
pub fn barrelClash(legs: Legs, via_clear: f64) ?BarrelClash {
    return tightestBarrel(legs, via_clear);
}

/// One construction attempt at a given via-pair spread.
fn buildAt(
    arena: std.mem.Allocator,
    c: Centerline,
    o: Options,
    plan: BuildPlan,
) std.mem.Allocator.Error!?Legs {
    const sides = plan.sides;
    const coupled = plan.coupled;
    const pairs = (try viaPairs(arena, c, o, sides, coupled, plan.widen)) orelse return null;
    var segs: std.ArrayList(LegSeg) = .empty;
    for ([2]Side{ .p, .n }) |side| {
        // Where each leg gets to by leaving its outermost pad STRAIGHT along the
        // escape. Everything downstream starts here, so a pad-escape run and a
        // coupled run leave the pad field the same way.
        const exits = [2]Pt{ endExit(o, side, 0), endExit(o, side, 1) };
        var reach: [2]?Pt = .{ null, null }; // the coupled chain's outer ends
        for (c.runs, 0..) |run, i| {
            const anchors = runAnchors(c.runs.len, pairs, side, i);
            // A run shorter than a couple of offsets is the pad-escape hop, not
            // a coupled stretch: offsetting it would fold the legs through each
            // other for no coupling benefit. Each leg just fans straight from
            // its anchor to the next — pad to barrel, exactly as a hand route
            // leaves a pad.
            if (!coupled[i]) {
                // A pad-escape hop: from whatever anchors it (a via barrel) to
                // the straight exit, never a diagonal off the pad itself.
                const from = anchors[0] orelse exits[0];
                const to = anchors[1] orelse exits[1];
                if (!samePt(from, to)) try segs.append(arena, .{
                    .a = from,
                    .b = to,
                    .layer = run.layer,
                    .side = side,
                    .kind = .fan,
                });
                if (anchors[0] == null) reach[0] = exits[0];
                if (anchors[1] == null) reach[1] = exits[1];
                continue;
            }
            const ends = (try emitRun(arena, &segs, run, .{
                .side = side,
                .off = o.off / 2,
                .s = if (side == .p) sides.run[i] else -sides.run[i],
                .anchors = anchors,
            })) orelse return null;
            if (i == 0) reach[0] = ends[0];
            if (i + 1 == c.runs.len) reach[1] = ends[1];
        }
        for (pairs, 0..) |v, i| {
            if (v.in_line == null) continue;
            try emitInLine(arena, &segs, side, v, .{ c.runs[i].layer, c.runs[i + 1].layer });
        }
        try emitEndWalks(arena, &segs, .{ .c = c, .o = o, .side = side, .reach = reach, .exits = exits });
    }
    return .{ .segs = try segs.toOwnedSlice(arena), .vias = pairs };
}

/// One side's end-walk inputs: the centreline (for layers), the options (for
/// the pad sequences), which leg, and where its coupled copper reaches.
const Walk = struct { c: Centerline, o: Options, side: Side, reach: [2]?Pt, exits: [2]Pt };

/// Thread one leg through both ends' pad sequences and on into the coupled run.
///
/// This is the whole point of the sequence model: the leg LANDS on every pad of
/// its end in order and keeps going, so the separation profile is dictated by
/// the pads' own pitches (0.80 mm across a cap pair, 0.64 across an 0201
/// termination) and converges to the class gap only once the run is clear of
/// them. Nothing is a stub, and nothing has to squeeze past a part that the run
/// is entitled to pass straight through.
fn emitEndWalks(
    arena: std.mem.Allocator,
    out: *std.ArrayList(LegSeg),
    w: Walk,
) std.mem.Allocator.Error!void {
    const layers = [2]u8{ w.c.runs[0].layer, w.c.runs[w.c.runs.len - 1].layer };
    for ([2]usize{ 0, 1 }) |end| {
        const seq = w.o.seq[end];
        if (seq.len == 0) continue;
        const tag = WalkTag{ .layer = layers[end], .side = w.side, .kind = .chain };
        var at = if (w.side == .p) seq[0].p else seq[0].n;
        for (seq[1..]) |pp| {
            const to = if (w.side == .p) pp.p else pp.n;
            try appendWalkSeg(arena, out, at, to, tag);
            at = to;
        }
        const reach = w.reach[end] orelse continue;
        try emitPadExit(arena, out, w, .{ .end = end, .pad = at, .reach = reach, .tag = tag });
    }
}

/// One end's pad exit: where the leg leaves its outermost pad, and where it has
/// to arrive.
const PadExit = struct { end: usize, pad: Pt, reach: Pt, tag: WalkTag };

/// Leave the outermost pad and reach the CLASS GAP in the shortest legal way:
/// straight out of the pad body, ONE 45° jog converging both legs to the coupled
/// offset, then class gap the whole rest of the way.
///
/// Impedance is the whole point. A pair leaving a connector at its PIN pitch and
/// holding that for a millimetre is a millimetre of wrong-impedance line, and a
/// taper spread over the approach is worse still — every part of it is off-spec
/// by a little. Converging in one ~0.12 mm jog immediately at the pad puts the
/// entire remaining approach, and the coupled run behind it, at the class gap.
/// The pads' own pitch is honoured only where the pads physically are.
///
/// The jog is 45° (octilinear, like every other corner here): a lateral step of
/// `delta` costs `delta` of longitudinal travel. Pads already TIGHTER than the
/// class gap need no jog and get the straight approach.
fn emitPadExit(
    arena: std.mem.Allocator,
    out: *std.ArrayList(LegSeg),
    w: Walk,
    e: PadExit,
) std.mem.Allocator.Error!void {
    const seq = w.o.seq[e.end];
    const from = seq[seq.len - 1].mid;
    // No escape heading to converge along (the terminal sits on the pad pair's own
    // midpoint): the hop into the coupled run is all there is, and it threads
    // nothing, so it stays reshapeable.
    const u = unitOf(.{ .x = from.x, .y = from.y }, .{ .x = w.o.mid[e.end].x, .y = w.o.mid[e.end].y }) orelse {
        try appendWalkSeg(arena, out, e.pad, e.reach, fanOf(e.tag));
        return;
    };
    // How far off the escape line this pad sits, and how far off it the coupled
    // run wants the leg: the difference is the jog.
    const lat = Vec{ .x = e.pad.x - from.x, .y = e.pad.y - from.y };
    const pitch = std.math.hypot(lat.x, lat.y);
    const delta = pitch - w.o.off / 2;
    if (!(pitch > weld_eps) or !(delta > weld_eps)) {
        // Already at or inside the class gap: straight out, nothing to converge.
        try appendWalkSeg(arena, out, e.pad, w.exits[e.end], e.tag);
        try appendWalkSeg(arena, out, w.exits[e.end], e.reach, fanOf(e.tag));
        return;
    }
    const side = Vec{ .x = lat.x / pitch, .y = lat.y / pitch };
    const stub = shift(e.pad, u, pad_exit_mm);
    const conv = shift(shift(stub, u, delta), side, -delta);
    // Out of the pad body, then the jog: both still WALK copper, unbendable —
    // they land on and thread the pad field.
    try appendWalkSeg(arena, out, e.pad, stub, e.tag);
    try appendWalkSeg(arena, out, stub, conv, e.tag);
    // At the class gap from here on. This last stretch is the fan: the only
    // place length matching may reshape, and it is already at spec.
    try appendWalkSeg(arena, out, conv, e.reach, fanOf(e.tag));
}

/// The same tag, re-marked as reshapeable fan copper.
fn fanOf(tag: WalkTag) WalkTag {
    return .{ .layer = tag.layer, .side = tag.side, .kind = .fan };
}

/// How far a leg runs straight out of its pad before it may start converging —
/// clear of the pad's own body along the escape. Short on purpose: everything
/// after it is at the class gap, so this is the only stretch spent at pad pitch.
const pad_exit_mm: f64 = 0.25;

/// How much ESCAPE RUN one end's pad exit consumes: the straight stub out of the
/// pad body plus the 45° jog that converges the two legs to the class gap.
///
/// This is `emitPadExit`'s own geometry read forwards. A caller placing that
/// end's centreline terminal must leave at least this much room between the pad
/// pair and the terminal, or the jog lands PAST the coupled run's start and the
/// leg has to double back into its twin — the shape that fails the clearance
/// probe (measured on straps-synth-lmx2595, 2026-08-11). Pads already at or
/// inside the class gap need only the stub.
pub fn padExitRun(outer: PadPair, off: f64) f64 {
    const pitch = std.math.hypot(outer.p.x - outer.n.x, outer.p.y - outer.n.y) / 2;
    const delta = pitch - off / 2;
    return pad_exit_mm + @max(0, delta);
}

/// Where one leg gets to by leaving its outermost pad parallel to the escape:
/// the pad translated by that end's outermost-pair-midpoint → terminal vector.
///
/// Deliberately the NOMINAL escape and not the centreline's actual heading at
/// that end. Following the real heading was tried and is worse: after a hairpin
/// cut the run can head back toward the board, and displacing the pad along
/// THAT walks the exit straight through the neighbouring pad. The escape vector
/// always points out of the pad field, which is the one property this hop needs.
fn endExit(o: Options, side: Side, end: usize) Pt {
    const seq = o.seq[end];
    const pad = outerOf(seq, side);
    const from = seq[seq.len - 1].mid;
    return .{ .x = pad.x + (o.mid[end].x - from.x), .y = pad.y + (o.mid[end].y - from.y) };
}

/// Layer + leg + kind tag shared by the segments of one end walk.
const WalkTag = struct { layer: u8, side: Side, kind: Kind = .chain };

/// Emit one walk hop, skipping a degenerate one.
fn appendWalkSeg(
    arena: std.mem.Allocator,
    out: *std.ArrayList(LegSeg),
    a: Pt,
    b: Pt,
    tag: WalkTag,
) std.mem.Allocator.Error!void {
    if (samePt(a, b)) return;
    try out.append(arena, .{ .a = a, .b = b, .layer = tag.layer, .side = tag.side, .kind = tag.kind });
}

/// One side's copper as plain segments, for the length/self-simplicity measures.
fn sideSegs(
    arena: std.mem.Allocator,
    legs: Legs,
    side: Side,
) std.mem.Allocator.Error![]const copper_length.Seg {
    var out: std.ArrayList(copper_length.Seg) = .empty;
    for (legs.segs) |sg| {
        if (sg.side != side) continue;
        try out.append(arena, .{ .a = .{ sg.a.x, sg.a.y }, .b = .{ sg.b.x, sg.b.y }, .layer = sg.layer });
    }
    return out.toOwnedSlice(arena);
}

/// One side's barrels as plain vias.
fn sideVias(
    arena: std.mem.Allocator,
    legs: Legs,
    side: Side,
) std.mem.Allocator.Error![]const copper_length.Via {
    const out = try arena.alloc(copper_length.Via, legs.vias.len);
    for (legs.vias, out) |v, *slot| {
        const at = if (side == .p) v.p else v.n;
        slot.* = .{ .at = .{ at.x, at.y } };
    }
    return out;
}

/// The pad one side TERMINATES at, at the given end: the first pair of the walk.
fn terminusOf(seq: []const PadPair, side: Side) Pt {
    return if (side == .p) seq[0].p else seq[0].n;
}

/// One leg's EFFECTIVE length (mm): the shortest electrical path across its own
/// merged copper, terminus pad to terminus pad. Null when the construction's
/// copper does not actually join the two — which is itself worth reporting,
/// since a summed length would have quoted a number regardless.
pub fn effectiveLength(
    arena: std.mem.Allocator,
    legs: Legs,
    side: Side,
    seq: [2][]const PadPair,
) std.mem.Allocator.Error!?f64 {
    if (seq[0].len == 0 or seq[1].len == 0) return null;
    const a = terminusOf(seq[0], side);
    const b = terminusOf(seq[1], side);
    return copper_length.shortest(
        arena,
        try sideSegs(arena, legs, side),
        try sideVias(arena, legs, side),
        .{ a.x, a.y },
        .{ b.x, b.y },
    );
}

/// Whether NEITHER leg retraces or crosses its own copper.
///
/// A leg that does is not merely untidy: same-net overlap passes every clearance
/// probe, so nothing else in the pipeline objects, and it makes the leg's summed
/// length — the number the length match and the skew check both read — larger
/// than the copper an electron sees. A construction that cannot promise this
/// cannot promise its own reported length, so it is refused outright.
fn legsSelfSimple(arena: std.mem.Allocator, legs: Legs) std.mem.Allocator.Error!bool {
    for ([2]Side{ .p, .n }) |side| {
        if (!copper_length.selfSimple(try sideSegs(arena, legs, side))) return false;
    }
    return true;
}

// ── Length matching ──────────────────────────────────────────────────────────

/// Largest lateral excursion (mm) a fan-region equalization bump may take. A
/// pair whose corner skew needs more than this is reported, not bent into the
/// pad field.
const max_bump_mm: f64 = 0.8;

/// Total copper length (mm) of one leg.
pub fn legLength(legs: Legs, side: Side) f64 {
    var sum: f64 = 0;
    for (legs.segs) |s| {
        if (s.side == side) sum += std.math.hypot(s.b.x - s.a.x, s.b.y - s.a.y);
    }
    return sum;
}

/// Distance from `p` to the nearest copper of `side`.
fn nearestOnSide(legs: Legs, side: Side, p: Pt) f64 {
    var lo: f64 = std.math.inf(f64);
    for (legs.segs) |s| {
        if (s.side != side) continue;
        lo = @min(lo, pointSeg(p, s.a, s.b));
    }
    return lo;
}

/// Longest stretch (mm) of a fan segment an equalization detour reshapes. A
/// bounded window keeps the excursion shallow: the apex height grows with the
/// window it spans, so bending a whole 10 mm fan to add 0.2 mm would swing five
/// times further out than bending 1 mm of it.
const bump_span_mm: f64 = 1.0;

/// A fan segment re-emitted with an equalization detour: up to four pieces (the
/// untouched lead-in, the two detour legs, the untouched lead-out).
const Bump = struct { segs: [4]LegSeg, len: usize };

/// One piece of a bumped fan, inheriting the original's layer/side/fan tags.
fn likeSeg(seg: LegSeg, a: Pt, b: Pt) LegSeg {
    return .{ .a = a, .b = b, .layer = seg.layer, .side = seg.side, .kind = seg.kind };
}

/// Re-emit fan segment `seg` `extra` mm longer, by bending a bounded window of
/// it into a shallow symmetric detour AWAY from the twin leg. Null when the
/// detour would swing further out than `max_bump_mm`.
fn bumpSeg(legs: Legs, seg: LegSeg, extra: f64) ?Bump {
    const len = std.math.hypot(seg.b.x - seg.a.x, seg.b.y - seg.a.y);
    const d = unitOf(seg.a, seg.b) orelse return null;
    const win = @min(len, bump_span_mm);
    const half = (win + extra) / 2;
    const h = @sqrt(@max(half * half - (win / 2) * (win / 2), 0));
    if (!(h > 0) or h > max_bump_mm) return null;
    const mid = Pt{ .x = (seg.a.x + seg.b.x) / 2, .y = (seg.a.y + seg.b.y) / 2 };
    const m1 = shift(mid, d, -win / 2);
    const m2 = shift(mid, d, win / 2);
    const n = normalOf(d);
    const twin: Side = if (seg.side == .p) .n else .p;
    const out = shift(mid, n, h);
    const back = shift(mid, n, -h);
    const apex = if (nearestOnSide(legs, twin, out) >= nearestOnSide(legs, twin, back)) out else back;
    const parts = [4]LegSeg{
        likeSeg(seg, seg.a, m1),
        likeSeg(seg, m1, apex),
        likeSeg(seg, apex, m2),
        likeSeg(seg, m2, seg.b),
    };
    var bump = Bump{ .segs = parts, .len = 0 };
    for (parts) |piece| {
        if (samePt(piece.a, piece.b)) continue;
        bump.segs[bump.len] = piece;
        bump.len += 1;
    }
    return bump;
}

/// How many fan segments the given side carries.
fn fanCount(legs: Legs, side: Side) usize {
    var n: usize = 0;
    for (legs.segs) |s| {
        if (s.side == side and s.kind == .fan) n += 1;
    }
    return n;
}

/// Match the two legs' lengths by detouring the SHORTER leg's pad fans.
///
/// A mitered offset pair is coupled by construction but not length-matched:
/// every centreline corner trades `off·tan(θ/2)` of length between the legs, so
/// a path with a net rotation leaves the outer leg longer. The coupled section
/// must stay clean (no mid-run serpentines on a controlled-impedance pair), so
/// the correction goes where the legs are already uncoupled: the short fan into
/// each pad, bulged away from the twin. Returns `legs` untouched when the skew
/// is already within `tol` or no fan can absorb it — the caller reports the
/// residual rather than bending copper into the pad field.
pub fn equalize(
    arena: std.mem.Allocator,
    legs: Legs,
    tol: f64,
    seq: [2][]const PadPair,
) std.mem.Allocator.Error!Legs {
    const diff = try legSkew(arena, legs, seq);
    if (@abs(diff) <= tol) return legs;
    const short: Side = if (diff > 0) .n else .p;
    const fans = fanCount(legs, short);
    if (fans == 0) return legs;
    const per = @abs(diff) / @as(f64, @floatFromInt(fans));
    var out: std.ArrayList(LegSeg) = .empty;
    var changed = false;
    for (legs.segs) |s| {
        const bump = if (s.side == short and s.kind == .fan) bumpSeg(legs, s, per) else null;
        if (bump) |made| {
            try out.appendSlice(arena, made.segs[0..made.len]);
            changed = true;
        } else {
            try out.append(arena, s);
        }
    }
    if (!changed) return legs;
    const bumped = Legs{ .segs = try out.toOwnedSlice(arena), .vias = legs.vias };
    // A detour that folded the leg onto itself buys length only on paper. Keep
    // the honest, unequalized pair instead and let the caller report the real
    // residual skew — a small true number beats a fabricated zero.
    if (!(try legsSelfSimple(arena, bumped))) return legs;
    if (@abs(try legSkew(arena, bumped, seq)) >= @abs(diff)) return legs;
    return bumped;
}

/// The pair's length mismatch (mm), P minus N, measured over each leg's MERGED
/// copper. Falls back to the segment sum only when the copper does not connect
/// its two terminals at all, where there is no path to measure.
fn legSkew(
    arena: std.mem.Allocator,
    legs: Legs,
    seq: [2][]const PadPair,
) std.mem.Allocator.Error!f64 {
    const p = try effectiveLength(arena, legs, .p, seq);
    const n = try effectiveLength(arena, legs, .n, seq);
    if (p) |pl| {
        if (n) |nl| return pl - nl;
    }
    return legLength(legs, .p) - legLength(legs, .n);
}

// ── Self-check ───────────────────────────────────────────────────────────────

/// Distance between the segments (a1,b1) and (a2,b2).
fn segDist(a1: Pt, b1: Pt, a2: Pt, b2: Pt) f64 {
    return @min(
        @min(pointSeg(a1, a2, b2), pointSeg(b1, a2, b2)),
        @min(pointSeg(a2, a1, b1), pointSeg(b2, a1, b1)),
    );
}

/// Distance from `p` to the segment (a,b).
fn pointSeg(p: Pt, a: Pt, b: Pt) f64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const len2 = dx * dx + dy * dy;
    if (len2 <= weld_eps * weld_eps) return std.math.hypot(p.x - a.x, p.y - a.y);
    const t = std.math.clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len2, 0, 1);
    return std.math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

/// Closest centre-to-centre approach between the two legs' COUPLED copper on a
/// shared layer — the construction's own sanity check. The pad fans are
/// excluded: there the legs deliberately diverge into pads whose own pitch, not
/// the coupling gap, sets the spacing. Infinite when the legs never share a
/// layer (nothing to compare).
pub fn minOppositeGap(legs: Legs) f64 {
    var lo: f64 = std.math.inf(f64);
    for (legs.segs) |a| {
        if (a.side != .p or a.kind != .coupled) continue;
        for (legs.segs) |b| {
            if (b.side != .n or b.kind != .coupled or b.layer != a.layer) continue;
            lo = @min(lo, segDist(a.a, a.b, b.a, b.b));
        }
    }
    return lo;
}

/// The closest-approaching pair of opposite-side COUPLED segments — what
/// `minOppositeGap` measured, named, so a fold census says which copper folded.
pub fn tightestOpposite(legs: Legs) ?[2]LegSeg {
    var out: ?[2]LegSeg = null;
    var lo = std.math.inf(f64);
    for (legs.segs) |a| {
        if (a.side != .p or a.kind != .coupled) continue;
        for (legs.segs) |b| {
            if (b.side != .n or b.kind != .coupled or b.layer != a.layer) continue;
            const d = segDist(a.a, a.b, b.a, b.b);
            if (d >= lo) continue;
            lo = d;
            out = .{ a, b };
        }
    }
    return out;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A straight two-vertex single-layer centreline from (x1,0) to (x2,0).
fn straightLine(arena: std.mem.Allocator, x1: f64, x2: f64) !Centerline {
    const pts = try arena.dupe(Pt, &.{ .{ .x = x1, .y = 0 }, .{ .x = x2, .y = 0 } });
    const runs = try arena.dupe(Run, &.{.{ .layer = 0, .pts = pts }});
    return .{ .runs = runs, .vias = &.{} };
}

/// How many COUPLED (non-fan) segments the construction emitted.
fn coupledSegs(legs: Legs) usize {
    var n: usize = 0;
    for (legs.segs) |s| {
        if (s.kind == .coupled) n += 1;
    }
    return n;
}

/// True when every segment's endpoints sit at `want` on the y axis for its side
/// (the straight-run landing check).
fn landsAtY(legs: Legs, p_y: f64, n_y: f64) bool {
    for (legs.segs) |s| {
        const want: f64 = if (s.side == .p) p_y else n_y;
        if (@abs(s.a.y - want) > 1e-9 or @abs(s.b.y - want) > 1e-9) return false;
    }
    return true;
}

/// A two-pad-pair end sequence: the terminus at x=10.6 and the pair the run
/// exits through at x=10 (an AC cap behind a termination resistor).
fn twoEnd(arena: std.mem.Allocator) std.mem.Allocator.Error![]const PadPair {
    const out = try arena.alloc(PadPair, 2);
    out[0] = .{ .p = .{ .x = 10.6, .y = -0.2 }, .n = .{ .x = 10.6, .y = 0.2 }, .mid = .{ .x = 10.6, .y = 0, .layer = 0 } };
    out[1] = .{ .p = .{ .x = 10, .y = -0.2 }, .n = .{ .x = 10, .y = 0.2 }, .mid = .{ .x = 10, .y = 0, .layer = 0 } };
    return out;
}

/// A single-pad-pair end sequence (the common test shape).
fn oneEnd(arena: std.mem.Allocator, p: Pt, n: Pt) std.mem.Allocator.Error![]const PadPair {
    const out = try arena.alloc(PadPair, 1);
    out[0] = .{ .p = p, .n = n, .mid = .{ .x = (p.x + n.x) / 2, .y = (p.y + n.y) / 2, .layer = 0 } };
    return out;
}

/// How many distinct escape terminals a set of end options covers.
fn distinctEscapes(opts: []const Ends) usize {
    var seen: usize = 0;
    for (opts, 0..) |e, i| {
        var first = true;
        for (opts[0..i]) |prev| {
            if (@abs(prev.mid[1].x - e.mid[1].x) < 1e-9 and @abs(prev.mid[1].y - e.mid[1].y) < 1e-9)
                first = false;
        }
        if (first) seen += 1;
    }
    return seen;
}

/// True when some segment of `side` has EITHER endpoint on `at` — a leg's head
/// segment starts on its pad, its tail segment ends on one.
fn touches(legs: Legs, side: Side, at: Pt) bool {
    for (legs.segs) |s| {
        if (s.side == side and (samePt(s.a, at) or samePt(s.b, at))) return true;
    }
    return false;
}

/// True when some segment of `side` ends exactly on `at`.
fn landsOn(legs: Legs, side: Side, at: Pt) bool {
    for (legs.segs) |s| {
        if (s.side == side and samePt(s.b, at)) return true;
    }
    return false;
}

// spec: placement/router - a coupled diff pair splits one centreline into two legs at the class offset, each landing on its own pad
test "dp_coupled build offsets both legs and fans each into its own pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const c = try straightLine(arena, 0, 10);
    const legs = (try build(arena, c, .{
        .off = 0.4,
        .via_spread = 0.4,
        .seq = .{
            try oneEnd(arena, .{ .x = 0, .y = -0.2 }, .{ .x = 0, .y = 0.2 }),
            try oneEnd(arena, .{ .x = 10, .y = -0.2 }, .{ .x = 10, .y = 0.2 }),
        },
        .mid = .{ .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 10, .y = 0, .layer = 0 } },
    })).?;
    // One segment per leg: the whole run is the fan-anchored straight.
    try testing.expectEqual(@as(usize, 2), legs.segs.len);
    try testing.expectEqual(@as(usize, 0), legs.vias.len);
    // P lands on the y=-0.2 pads, N on y=+0.2 — the legs never cross.
    try testing.expect(landsAtY(legs, -0.2, 0.2));
}

// spec: placement/router - a coupled diff pair miters every centreline bend so the legs hold the class offset through the corner
test "dp_coupled miters an outside corner and trims the inside corner back" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // An L with a straight tail: 10 mm east, then 20 mm south (the tail's mid
    // vertex is collinear, so the run carries ONE 90° corner and a coupled
    // middle segment neither pad fan touches). Total centreline 30 mm.
    const off: f64 = 0.4;
    const pts = try arena.dupe(Pt, &.{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 10, .y = 20 },
    });
    const runs = try arena.dupe(Run, &.{.{ .layer = 0, .pts = pts }});
    const c = Centerline{ .runs = runs, .vias = &.{} };
    const legs = (try build(arena, c, .{
        .off = off,
        .via_spread = off,
        // Pads exactly on each leg's own offset line, so the fans add nothing.
        .seq = .{
            try oneEnd(arena, .{ .x = 0, .y = -off / 2 }, .{ .x = 0, .y = off / 2 }),
            try oneEnd(arena, .{ .x = 10 + off / 2, .y = 20 }, .{ .x = 10 - off / 2, .y = 20 }),
        },
        .mid = .{ .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 10, .y = 20, .layer = 0 } },
    })).?;
    // The corner turns toward N: N is the inside leg, so the miter takes off/2
    // off each of its two legs while P gains off/2 on each.
    try testing.expectApproxEqAbs(30 + off, legLength(legs, .p), 1e-9);
    try testing.expectApproxEqAbs(30 - off, legLength(legs, .n), 1e-9);
    // Coupling holds THROUGH the bend: the legs stay exactly `off` apart.
    try testing.expectApproxEqAbs(off, minOppositeGap(legs), 1e-9);
}

// spec: placement/router - a coupled diff pair turns each centreline layer change into a via pair spread along the path normal
test "dp_coupled spreads a via pair on the path normal and necks the legs into it" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two runs joined by a via at (5,0): east on layer 0, east on layer 1.
    const r0 = try arena.dupe(Pt, &.{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 0 } });
    const r1 = try arena.dupe(Pt, &.{ .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 0 } });
    const runs = try arena.dupe(Run, &.{
        .{ .layer = 0, .pts = r0 },
        .{ .layer = 1, .pts = r1 },
    });
    const vias = try arena.dupe(Pt, &.{.{ .x = 5, .y = 0 }});
    const c = Centerline{ .runs = runs, .vias = vias };
    const spread: f64 = 0.8;
    const legs = (try build(arena, c, .{
        .off = 0.4,
        .via_spread = spread,
        .seq = .{
            try oneEnd(arena, .{ .x = 0, .y = -0.2 }, .{ .x = 0, .y = 0.2 }),
            try oneEnd(arena, .{ .x = 10, .y = -0.2 }, .{ .x = 10, .y = 0.2 }),
        },
        .mid = .{ .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 10, .y = 0, .layer = 0 } },
    })).?;
    try testing.expectEqual(@as(usize, 1), legs.vias.len);
    const v = legs.vias[0];
    // Barrels straddle the centreline via at the full spread, on its normal.
    try testing.expectApproxEqAbs(spread, std.math.hypot(v.p.x - v.n.x, v.p.y - v.n.y), 1e-9);
    try testing.expectApproxEqAbs(5, v.p.x, 1e-9);
    try testing.expectApproxEqAbs(5, v.n.x, 1e-9);
    // Each leg necks OUT to its own barrel: some segment ends exactly there.
    try testing.expect(landsOn(legs, .p, v.p));
    try testing.expect(landsOn(legs, .n, v.n));
}

// spec: placement/router - a coupled diff pair sizes its via-pair spread so both barrels clear each other and the opposite leg
test "dp_coupled viaSpread widens past the coupling offset only when the barrels need it" {
    // Roomy pair: offset already exceeds every barrel rule, so the vias stay on
    // the leg lines and the legs never neck.
    try testing.expectApproxEqAbs(@as(f64, 2.0), viaSpread(2.0, 0.4, 0.127, 0.2532), 1e-9);
    // Board A's lvds-ref geometry: 0.4056 offset cannot hold two 0.4 barrels,
    // so the pair spreads to the via-to-via wall.
    try testing.expectApproxEqAbs(@as(f64, 0.527), viaSpread(0.4056, 0.4, 0.127, 0.2532), 1e-9);
}

// spec: placement/router - a coupled diff pair length-matches its legs in the pad fans, leaving the coupled section untouched
test "dp_coupled equalize detours the shorter leg's fan and leaves a matched pair alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The L-bend pair from the miter test: outer P is `off` longer than N.
    const pts = try arena.dupe(Pt, &.{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
    });
    const runs = try arena.dupe(Run, &.{.{ .layer = 0, .pts = pts }});
    const off: f64 = 0.4;
    const legs = (try build(arena, .{ .runs = runs, .vias = &.{} }, .{
        .off = off,
        .via_spread = off,
        .seq = .{
            try oneEnd(arena, .{ .x = -1, .y = -off / 2 }, .{ .x = -1, .y = off / 2 }),
            try oneEnd(arena, .{ .x = 10 + off / 2, .y = 11 }, .{ .x = 10 - off / 2, .y = 11 }),
        },
        .mid = .{ .{ .x = -1, .y = 0, .layer = 0 }, .{ .x = 10, .y = 11, .layer = 0 } },
    })).?;
    const seq = [2][]const PadPair{
        try oneEnd(arena, .{ .x = -1, .y = -off / 2 }, .{ .x = -1, .y = off / 2 }),
        try oneEnd(arena, .{ .x = 10 + off / 2, .y = 11 }, .{ .x = 10 - off / 2, .y = 11 }),
    };
    const before = try legSkew(arena, legs, seq);
    try testing.expect(@abs(before) > 0.5);

    const matched = try equalize(arena, legs, 0.05, seq);
    // Matched on the EFFECTIVE length — the path an electron takes, not the sum
    // of segments, so a detour cannot buy the match with copper it retraces.
    try testing.expect(@abs(try legSkew(arena, matched, seq)) <= 0.05);
    // …and the detour it used is real geometry: neither leg folds onto itself.
    try testing.expect(try legsSelfSimple(arena, matched));
    // The coupled section is untouched: only fan segments were re-emitted.
    try testing.expectEqual(coupledSegs(legs), coupledSegs(matched));

    // An already-matched pair is returned verbatim (same slice, no work).
    const same = try equalize(arena, matched, 0.5, seq);
    try testing.expectEqual(matched.segs.ptr, same.segs.ptr);
}

// spec: placement/router - a coupled diff pair turns a doubling-back at its escape into a layer transition, cutting only the hairpins that cannot be one
test "dp_coupled resolves an escape reversal as a via and still cuts a mid-route hairpin" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A pair leaving a crowded pocket runs OUT of it, changes layer, and comes
    // back over itself — the hand reference's exact structure. The maze writes
    // that intent as a same-layer doubling back 0.6 mm from the terminal, which
    // cannot be offset (the legs would swap sides). It becomes a via there.
    const near = try arena.dupe(Pt, &.{
        .{ .x = 10, .y = 0 },
        .{ .x = 9.4, .y = 0 },
        .{ .x = 20, .y = 0 },
    });
    const untrimmed = [1]RunEnds{.{ .head = false, .tail = false }};
    const c = try resolveReversals(arena, .{ .runs = try arena.dupe(Run, &.{.{ .layer = 0, .pts = near }}), .vias = &.{} }, &untrimmed);
    try testing.expectEqual(@as(usize, 2), c.runs.len);
    try testing.expectEqual(@as(usize, 1), c.vias.len);
    try testing.expectApproxEqAbs(@as(f64, 9.4), c.vias[0].x, 1e-9);
    // The return run is on the other outer face — that is the whole point.
    try testing.expect(c.runs[0].layer != c.runs[1].layer);

    // A doubling-back in mid-route serves no escape and stays a hairpin to cut.
    const far = try arena.dupe(Pt, &.{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 4, .y = 0 },
        .{ .x = 20, .y = 0 },
    });
    const mid = try resolveReversals(arena, .{ .runs = try arena.dupe(Run, &.{.{ .layer = 0, .pts = far }}), .vias = &.{} }, &untrimmed);
    try testing.expectEqual(@as(usize, 1), mid.runs.len);
    try testing.expectEqual(@as(usize, 0), mid.vias.len);
}

// spec: placement/router - the coupled diff-pair construction cuts a hairpin corner out of its centreline instead of mitering the legs through each other
test "dp_coupled build cuts a same-layer hairpin instead of folding the legs" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A centreline that runs west to (9,0) then doubles straight back east: the
    // maze reaching out to a terminal and turning round. "Side" is defined by
    // the direction of travel, so mitering through that corner swaps which side
    // each leg is on — a short. The corner is cut instead.
    const pts = try arena.dupe(Pt, &.{
        .{ .x = 10, .y = 0 },
        .{ .x = 9, .y = 0 },
        .{ .x = 20, .y = 0.4 },
    });
    const runs = try arena.dupe(Run, &.{.{ .layer = 0, .pts = pts }});
    const off: f64 = 0.4;
    const legs = (try build(arena, .{ .runs = runs, .vias = &.{} }, .{
        .off = off,
        .via_spread = off,
        .via_clear = 0,
        .seq = .{
            try oneEnd(arena, .{ .x = 10, .y = -0.32 }, .{ .x = 10, .y = 0.32 }),
            try oneEnd(arena, .{ .x = 20, .y = 0.08 }, .{ .x = 20, .y = 0.72 }),
        },
        .mid = .{ .{ .x = 10, .y = 0, .layer = 0 }, .{ .x = 20, .y = 0.4, .layer = 0 } },
    })).?;
    // The legs hold the class offset: no crossing anywhere on the coupled run.
    try testing.expect(minOppositeGap(legs) >= off - 1e-9);
}

// spec: placement/router - a coupled diff pair leaves each end straight along its escape before tapering, so the legs never cut across their own pad field
test "dp_coupled extendEnds starts the centreline straight out of the pad field" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The maze routes between the FAR terminals; the centreline is then carried
    // back to the pad-field exits, so its first and last segments run along the
    // escape. Without that the maze is free to turn at the terminal, and the
    // legs' perpendicular offsets stop lining up with the axis the pads are
    // separated on — the taper becomes a rotation and the legs fold together.
    const c = try straightLine(arena, 1, 9);
    const out = try extendEnds(arena, c, .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 10, .y = 0, .layer = 0 });
    try testing.expectEqual(@as(usize, 1), out.runs.len);
    const pts = out.runs[0].pts;
    try testing.expectEqual(@as(usize, 4), pts.len);
    try testing.expectApproxEqAbs(@as(f64, 0), pts[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), pts[pts.len - 1].x, 1e-9);
    // Idempotent: a centreline already reaching the exits is returned as-is.
    const again = try extendEnds(arena, out, .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 10, .y = 0, .layer = 0 });
    try testing.expectEqual(pts.len, again.runs[0].pts.len);
}

// spec: placement/router - the coupled diff-pair chainer welds a run onto a barrel within half a track of the drill centre, not only dead on it
test "dp_coupled chain welds a run that stops short of the drill centre" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The maze ends each run on its own grid NODE, which lands a fraction of a
    // pad short of the barrel it is joining — here the layer-1 run stops
    // 0.28 mm away. Physically that is well inside the via land; refusing it
    // rejects a centreline the router itself considers connected.
    const segs = [_]Seg{
        .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 5, .y = 0 }, .layer = 0 },
        .{ .a = .{ .x = 5.2, .y = 0.2 }, .b = .{ .x = 10, .y = 0.2 }, .layer = 1 },
    };
    const via = [_]Pt{.{ .x = 5, .y = 0 }};
    // A barrel-radius tolerance is too tight to see the layer-1 end.
    try testing.expect((try chain(arena, &segs, &via, .{ .x = 0, .y = 0 }, 0.2)) == null);
    // Half a track on top of it welds the two runs into one centreline.
    const c = (try chain(arena, &segs, &via, .{ .x = 0, .y = 0 }, 0.33)).?;
    try testing.expectEqual(@as(usize, 2), c.runs.len);
    try testing.expectEqual(@as(usize, 1), c.vias.len);
}

// spec: placement/router - the coupled diff-pair chainer refuses copper that is not a simple two-ended path
test "dp_coupled chain orders a via-crossing path and refuses a branch" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Emitted out of path order (the maze emits goal→source, then pad stubs):
    // layer 1 leg first, then the via's layer-0 leg.
    const segs = [_]Seg{
        .{ .a = .{ .x = 5, .y = 0 }, .b = .{ .x = 10, .y = 0 }, .layer = 1 },
        .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 5, .y = 0 }, .layer = 0 },
    };
    const c = (try chain(arena, &segs, &.{.{ .x = 5, .y = 0 }}, .{ .x = 0, .y = 0 }, 0.2)).?;
    try testing.expectEqual(@as(usize, 2), c.runs.len);
    try testing.expectEqual(@as(usize, 1), c.vias.len);
    // Chained from the end nearest `start`, so run 0 is the layer-0 leg.
    try testing.expectEqual(@as(u8, 0), c.runs[0].layer);
    try testing.expectApproxEqAbs(@as(f64, 0), c.runs[0].pts[0].x, 1e-9);

    // A T-branch off the middle is not a pair centreline.
    const branched = segs ++ [_]Seg{.{ .a = .{ .x = 5, .y = 0 }, .b = .{ .x = 5, .y = 5 }, .layer = 0 }};
    try testing.expect((try chain(arena, &branched, &.{}, .{ .x = 0, .y = 0 }, 0.2)) == null);
}

// spec: placement/router - coupled diff-pair pad matching pairs the ends by proximity and refuses pads too far apart to launch a pair
test "dp_coupled pairEnds clusters an LVDS receive end and rejects pads too far apart" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A real pair: a connector end at x≈0 and a receive end at x≈10 carrying a
    // termination resistor (x=10) plus an AC-coupling cap BEHIND it (x=10.6).
    // Pads are listed out of order to prove the clustering does the work.
    const p = [_]Terminal{
        .{ .x = 10.6, .y = -0.2, .layer = 0 }, // C_OSCINP
        .{ .x = 0, .y = -0.2, .layer = 0 }, // connector
        .{ .x = 10, .y = -0.2, .layer = 0 }, // R_term
    };
    const n = [_]Terminal{
        .{ .x = 10, .y = 0.2, .layer = 0 },
        .{ .x = 10.6, .y = 0.2, .layer = 0 },
        .{ .x = 0, .y = 0.2, .layer = 0 },
    };
    const ends = (try pairEnds(arena, &p, &n, 5)).?;
    // End 0 is the connector: a single pad pair, nothing to thread.
    try testing.expectEqual(@as(usize, 1), ends.seq[0].len);
    try testing.expectApproxEqAbs(@as(f64, 0), ends.seq[0][0].p.x, 1e-9);
    // End 1 is a SEQUENCE the run threads: it terminates on the cap behind the
    // resistor (x=10.6) and exits through the resistor (x=10) — not a landing
    // pad with a stub, which is what forced the old squeeze past the resistor.
    try testing.expectEqual(@as(usize, 2), ends.seq[1].len);
    // Walk order is terminus-first: the preferred escape points AWAY from the
    // far end (east here), so the run terminates on the near pair and leaves
    // through the far one, reaching the coupled section beyond it.
    try testing.expectApproxEqAbs(@as(f64, 10), ends.seq[1][0].p.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10.6), ends.seq[1][1].p.x, 1e-9);
    // Terminals sit OUTSIDE the outermost pair, on the pair's normal, so the
    // maze starts clear of the pad field the legs walk through.
    try testing.expectApproxEqAbs(escape_out_mm, @abs(ends.mid[0].x - 0), 1e-9);
    try testing.expectApproxEqAbs(10.6 + escape_out_mm, ends.mid[1].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), ends.mid[1].y, 1e-9);

    // An end whose only N pad is 8 mm off is no launch pair at a 5 mm limit.
    const far = [_]Terminal{ .{ .x = 10, .y = 8, .layer = 0 }, .{ .x = 0, .y = 0.5, .layer = 0 } };
    try testing.expect((try pairEnds(arena, &p, &far, 5)) == null);

    // Cross-layer pads cannot share one centreline terminal.
    const other = [_]Terminal{ .{ .x = 10, .y = 0.2, .layer = 1 }, .{ .x = 0, .y = 0.2, .layer = 1 } };
    try testing.expect((try pairEnds(arena, &p, &other, 5)) == null);
}

// spec: placement/router - coupled diff-pair end options are capped and ordered every escape direction's preferred way out first
test "dp_coupled pairEndOptions caps its list and leads with each pairing's best escape" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Same LVDS receive end as above: the connector at x≈0, and at x≈10 a
    // termination resistor with an AC cap behind it — two landing choices a
    // side, so four pairings at that end.
    const p = [_]Terminal{
        .{ .x = 0, .y = -0.2, .layer = 0 },
        .{ .x = 10, .y = -0.2, .layer = 0 },
        .{ .x = 10.6, .y = -0.2, .layer = 0 },
    };
    const n = [_]Terminal{
        .{ .x = 0, .y = 0.2, .layer = 0 },
        .{ .x = 10, .y = 0.2, .layer = 0 },
        .{ .x = 10.6, .y = 0.2, .layer = 0 },
    };
    // The budget is honoured exactly.
    const two = try pairEndOptions(arena, &p, &n, 5, 2);
    try testing.expectEqual(@as(usize, 2), two.len);
    // A small budget still reaches a SECOND escape direction — the point when
    // the preferred way out of a pocket turns out to be the walled-off one.
    const few = try pairEndOptions(arena, &p, &n, 5, 4);
    try testing.expect(distinctEscapes(few) >= 2);
    // Every option escapes away from the pads it chains to (x below the cap).
    for (few) |e| try testing.expect(@abs(@abs(e.mid[1].x - 10.3) - (0.3 + escape_out_mm)) < 1e-9);
    // A budget of zero asks for nothing.
    try testing.expectEqual(@as(usize, 0), (try pairEndOptions(arena, &p, &n, 5, 0)).len);
}

// spec: placement/router - a coupled diff pair threads its end's pad pairs in sequence, terminus first, converging to the class gap beyond the last
test "dp_coupled build walks an end's pad sequence instead of stubbing off one landing pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const c = try straightLine(arena, 0, 10);
    const legs = (try build(arena, c, .{
        .off = 0.4,
        .via_spread = 0.4,
        .seq = .{
            try oneEnd(arena, .{ .x = 0, .y = -0.2 }, .{ .x = 0, .y = 0.2 }),
            try twoEnd(arena),
        },
        .mid = .{ .{ .x = -0.9, .y = 0, .layer = 0 }, .{ .x = 10.9, .y = 0, .layer = 0 } },
    })).?;
    // Each leg WALKS its end's two pads: a hop between them per side, tagged
    // uncoupled, so the pitch there is the pads' own, not the class gap.
    var walks: usize = 0;
    for (legs.segs) |s| {
        if (s.kind == .chain and @abs(s.a.x - 10.6) < 1e-9 and @abs(s.b.x - 10) < 1e-9) walks += 1;
    }
    try testing.expectEqual(@as(usize, 2), walks);
    // The walk terminates ON the outer pad, so the copper stays continuous.
    try testing.expect(landsOn(legs, .p, .{ .x = 10, .y = -0.2 }));
}

/// True when every COUPLED segment of `side` sits on the side of y=0 that `want`
/// names (−1 above, +1 below) — the "did the legs cross?" check.
fn coupledOnSide(legs: Legs, side: Side, want: f64) bool {
    for (legs.segs) |s| {
        if (s.side != side or s.kind != .coupled) continue;
        if (s.a.y * want <= 0 or s.b.y * want <= 0) return false;
    }
    return true;
}

// spec: placement/router - a coupled diff pair keeps each leg on the physical side its own pads are on, flipping its offset sign at every via the centreline reverses through
test "dp_coupled keeps each leg on its own pads' side across an escape reversal" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // board-a's LMX escape in miniature: the pair leaves its pad field
    // heading WEST (the only open side), changes layer at the pocket's mouth,
    // and the haul comes back EAST underneath. "Left of the path" names the
    // north side before that via and the south side after it, so a single
    // offset sign puts the whole coupled haul — and both barrels — on the side
    // the TWIN's pad is on, and the two escape fans have to cross to land.
    const off: f64 = 0.4;
    const west = try arena.dupe(Pt, &.{ .{ .x = 0, .y = 0 }, .{ .x = -0.6, .y = 0 } });
    const east = try arena.dupe(Pt, &.{ .{ .x = -0.6, .y = 0 }, .{ .x = 10, .y = 0 } });
    const c = Centerline{
        .runs = try arena.dupe(Run, &.{
            .{ .layer = 0, .pts = west },
            .{ .layer = 1, .pts = east },
        }),
        .vias = try arena.dupe(Pt, &.{.{ .x = -0.6, .y = 0 }}),
    };
    const legs = (try build(arena, c, .{
        .off = off,
        .via_spread = off,
        .seq = .{
            try oneEnd(arena, .{ .x = 0, .y = -0.32 }, .{ .x = 0, .y = 0.32 }),
            try oneEnd(arena, .{ .x = 10, .y = -0.2 }, .{ .x = 10, .y = 0.2 }),
        },
        .mid = .{ .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 10, .y = 0, .layer = 1 } },
    })).?;

    // P's pads are NORTH (y<0) at both ends, N's are SOUTH — so is every piece
    // of coupled copper, and so is each leg's own barrel.
    try testing.expect(coupledOnSide(legs, .p, -1));
    try testing.expect(coupledOnSide(legs, .n, 1));
    try testing.expectEqual(@as(usize, 1), legs.vias.len);
    try testing.expect(legs.vias[0].p.y < 0);
    try testing.expect(legs.vias[0].n.y > 0);
    // Still a coupled pair, not two strays: the haul holds the class offset.
    try testing.expectApproxEqAbs(off, minOppositeGap(legs), 1e-9);
}

/// Closest same-layer approach between ANY P segment and ANY N segment — the
/// blunt "did the legs cross?" measure, unlike `minOppositeGap` which asks only
/// about the coupled run.
fn minSameLayerGap(legs: Legs) f64 {
    var lo: f64 = std.math.inf(f64);
    for (legs.segs) |a| {
        if (a.side != .p) continue;
        for (legs.segs) |b| {
            if (b.side != .n or b.layer != a.layer) continue;
            lo = @min(lo, segDist(a.a, a.b, b.a, b.b));
        }
    }
    return lo;
}

/// A two-run centreline, straight, with one layer change at its middle.
fn viaLine(arena: std.mem.Allocator, at: f64, to: f64) std.mem.Allocator.Error!Centerline {
    const one = try arena.dupe(Pt, &.{ .{ .x = 0, .y = 0 }, .{ .x = at, .y = 0 } });
    const two = try arena.dupe(Pt, &.{ .{ .x = at, .y = 0 }, .{ .x = to, .y = 0 } });
    return .{
        .runs = try arena.dupe(Run, &.{ .{ .layer = 0, .pts = one }, .{ .layer = 1, .pts = two } }),
        .vias = try arena.dupe(Pt, &.{.{ .x = at, .y = 0 }}),
    };
}

// spec: placement/router - a coupled diff pair whose ends demand opposite sides absorbs the twist at ONE in-line via transition, and an untwisted pair keeps its barrels across the path
test "dp_coupled swaps a twisted pair's sides in-line and leaves an untwisted pair perpendicular" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const off: f64 = 0.4;
    const clear: f64 = 0.45;
    const c = try viaLine(arena, 5, 10);
    // TWISTED: P is north at the near end and SOUTH at the far one — a connector
    // wired pin-for-pin into a receiver whose pinout runs the other way. No
    // single offset sign lands both ends, so the perpendicular arrangement has
    // no construction at all and must decline rather than build a crossing.
    const twisted = Options{
        .off = off,
        .via_spread = 0.53,
        .via_clear = clear,
        .seq = .{
            try oneEnd(arena, .{ .x = 0, .y = -0.2 }, .{ .x = 0, .y = 0.2 }),
            try oneEnd(arena, .{ .x = 10, .y = 0.2 }, .{ .x = 10, .y = -0.2 }),
        },
        .mid = .{ .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 10, .y = 0, .layer = 1 } },
    };
    try testing.expect((try build(arena, c, twisted)) == null);

    var in_line = twisted;
    in_line.swap_via = 0;
    const legs = (try build(arena, c, in_line)).?;
    // The transition is in-line: barrels staggered ALONG the path, not across it.
    try testing.expectEqual(@as(usize, 1), legs.vias.len);
    try testing.expect(legs.vias[0].in_line != null);
    try testing.expectApproxEqAbs(@as(f64, 0), legs.vias[0].p.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), legs.vias[0].n.y, 1e-9);
    try testing.expect(legs.vias[0].p.x < legs.vias[0].n.x);
    // Each leg lands on its OWN pad at BOTH ends — the twist is absorbed.
    try testing.expect(touches(legs, .p, .{ .x = 0, .y = -0.2 }));
    try testing.expect(touches(legs, .p, .{ .x = 10, .y = 0.2 }));
    try testing.expect(touches(legs, .n, .{ .x = 0, .y = 0.2 }));
    try testing.expect(touches(legs, .n, .{ .x = 10, .y = -0.2 }));
    // Nothing crosses on either layer, and every barrel clears its twin's copper.
    try testing.expect(minSameLayerGap(legs) >= off * in_line_dip_floor);
    try testing.expect(barrelsClear(legs, clear));
    // Mirror-image passes, so the transition costs both legs the same copper.
    try testing.expectApproxEqAbs(legLength(legs, .p), legLength(legs, .n), 1e-9);

    // UNTWISTED: the same board with P north at both ends keeps the barrels
    // across the path, and refuses a swap it has no twist to spend on.
    var straight = twisted;
    straight.seq[1] = try oneEnd(arena, .{ .x = 10, .y = -0.2 }, .{ .x = 10, .y = 0.2 });
    const plain = (try build(arena, c, straight)).?;
    try testing.expect(plain.vias[0].in_line == null);
    try testing.expectApproxEqAbs(plain.vias[0].p.x, plain.vias[0].n.x, 1e-9);
    straight.swap_via = 0;
    try testing.expect((try build(arena, c, straight)) == null);
}

// spec: placement/router - a coupled diff pair's centreline drops copper it retraces and the no-op via a reversal split leaves behind, and spends no layer change on the fold it removed
test "dp_coupled simplify drops retraced copper and the no-op via a split leaves behind" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // One centreline carrying all three kinds of waste at once: a via that keeps
    // the same layer (what splitting a reversal leaves next to the maze's own
    // transition), a 0.5 mm hop to the far face and straight back, and a tail
    // that overshoots to 22 and retraces to 21 (what aiming the maze past the
    // pad-field exit leaves behind).
    const c = Centerline{
        .runs = try arena.dupe(Run, &.{
            .{ .layer = 0, .pts = try arena.dupe(Pt, &.{ .{ .x = 0, .y = 0 }, .{ .x = 5, .y = 0 } }) },
            .{ .layer = 0, .pts = try arena.dupe(Pt, &.{ .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 0 } }) },
            .{ .layer = 1, .pts = try arena.dupe(Pt, &.{ .{ .x = 10, .y = 0 }, .{ .x = 10.5, .y = 0 } }) },
            .{ .layer = 0, .pts = try arena.dupe(Pt, &.{
                .{ .x = 10.5, .y = 0 }, .{ .x = 20, .y = 0 }, .{ .x = 22, .y = 0 }, .{ .x = 21, .y = 0 },
            }) },
        }),
        .vias = try arena.dupe(Pt, &.{ .{ .x = 5, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 10.5, .y = 0 } }),
    };
    const out = try simplify(arena, c, 0.4, .{ .head = false, .tail = false });
    // The no-op via is gone (two L0 runs merged into one) and the retrace with
    // it, so three runs and two real layer changes remain — and NOT a fourth
    // barrel: the fold the trim removed no longer reads as an escape worth a
    // layer change, which is what used to put two of this leg's drills a
    // quarter of a millimetre apart at the connector.
    try testing.expectEqual(@as(usize, 3), out.runs.len);
    try testing.expectEqual(@as(usize, 2), out.vias.len);
    for (out.runs, 0..) |run, i| {
        if (i > 0) try testing.expect(run.layer != out.runs[i - 1].layer);
    }
    // The tail is the real 10.5 mm path, not the 12.5 mm a retrace sums to.
    try testing.expectApproxEqAbs(@as(f64, 10.5), runLength(out.runs[2].pts), 1e-9);
}

// spec: placement/router - a coupled diff pair refuses a construction whose leg overlaps or crosses its own copper, and matches lengths on the effective path
test "dp_coupled refuses a self-overlapping leg and skews on the effective path" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const off: f64 = 0.4;
    const seq = [2][]const PadPair{
        try oneEnd(arena, .{ .x = 0, .y = -off / 2 }, .{ .x = 0, .y = off / 2 }),
        try oneEnd(arena, .{ .x = 10, .y = -off / 2 }, .{ .x = 10, .y = off / 2 }),
    };
    // A hand-built pair whose P leg runs out to 12 and retraces to 10. Every
    // clearance rule passes it (a net may overlap itself), and its SUM is 14 mm
    // against N's 10 — so a summed skew reads 4 mm of mismatch that no electron
    // experiences, while the effective paths are identical.
    const folded = Legs{
        .segs = try arena.dupe(LegSeg, &.{
            .{ .a = .{ .x = 0, .y = -off / 2 }, .b = .{ .x = 12, .y = -off / 2 }, .layer = 0, .side = .p },
            .{ .a = .{ .x = 12, .y = -off / 2 }, .b = .{ .x = 10, .y = -off / 2 }, .layer = 0, .side = .p },
            .{ .a = .{ .x = 0, .y = off / 2 }, .b = .{ .x = 10, .y = off / 2 }, .layer = 0, .side = .n },
        }),
        .vias = &.{},
    };
    try testing.expectApproxEqAbs(@as(f64, 4), legLength(folded, .p) - legLength(folded, .n), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), try legSkew(arena, folded, seq), 1e-9);
    try testing.expect(!(try legsSelfSimple(arena, folded)));
    // An already-matched pair needs no detour, so equalize hands it straight
    // back rather than buying a "match" with copper that folds.
    const same = try equalize(arena, folded, 0.05, seq);
    try testing.expectEqual(folded.segs.ptr, same.segs.ptr);

    // The construction itself never emits such a leg.
    const straight = (try build(arena, try straightLine(arena, 0, 10), .{
        .off = off,
        .via_spread = off,
        .seq = seq,
        .mid = .{ .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 10, .y = 0, .layer = 0 } },
    })).?;
    try testing.expect(try legsSelfSimple(arena, straight));
}

// spec: placement/router - a coupled diff pair offers a straight approach at an end that overruns its terminal as a candidate alongside the layer change, so the probe picks between them
test "dp_coupled trims an overrunning end into a straight approach, one via cheaper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A tail that overruns its terminal on a genuine ~150° turn — not a
    // collinear retrace, so nothing removes it as overlapping copper, and
    // `resolveReversals` reads it as an escape and spends a whole via pair
    // representing it. That is right at a crowded pocket and pure waste at a
    // connector, and only the board can tell the two apart.
    const c = Centerline{
        .runs = try arena.dupe(Run, &.{
            .{ .layer = 0, .pts = try arena.dupe(Pt, &.{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 } }) },
            .{ .layer = 1, .pts = try arena.dupe(Pt, &.{
                .{ .x = 10, .y = 0 }, .{ .x = 11.5, .y = 0.6 }, .{ .x = 11, .y = 0 },
            }) },
        }),
        .vias = try arena.dupe(Pt, &.{.{ .x = 10, .y = 0 }}),
    };
    const kept = try simplify(arena, c, 0.4, .{ .head = false, .tail = false });
    const trimmed = try simplify(arena, c, 0.4, .{ .head = false, .tail = true });

    // Untrimmed: the turn becomes a second layer change, as it always has.
    try testing.expectEqual(@as(usize, 2), kept.vias.len);
    // Trimmed: the overrun is gone, the approach is straight, and that whole via
    // pair is never spent — one barrel per leg saved at the connector.
    try testing.expectEqual(@as(usize, 1), trimmed.vias.len);
    try testing.expectEqual(@as(usize, 2), trimmed.runs.len);
    const tail = trimmed.runs[1].pts;
    try testing.expectEqual(@as(usize, 2), tail.len);
    try testing.expectApproxEqAbs(@as(f64, 11), tail[tail.len - 1].x, 1e-9);
    // …and it is shorter copper, which is why it is offered first.
    try testing.expect(runLength(tail) < runLength(kept.runs[1].pts) + runLength(kept.runs[2].pts));
}

/// The separation profile of one construction: each same-layer stretch's
/// centre-to-centre spacing and how long it runs at it. `at_spec` counts only
/// copper that ought to be at the class gap — pad walks and via necks excluded.
fn spacingProfile(legs: Legs, off: f64) struct { at_spec: f64, off_spec: f64, worst_run: f64 } {
    var at: f64 = 0;
    var off_spec: f64 = 0;
    var worst: f64 = 0;
    for (legs.segs) |a| {
        if (a.side != .p or a.kind == .chain) continue;
        const len = std.math.hypot(a.b.x - a.a.x, a.b.y - a.a.y);
        var lo = std.math.inf(f64);
        for (legs.segs) |b| {
            if (b.side != .n or b.kind == .chain or b.layer != a.layer) continue;
            lo = @min(lo, segDist(a.a, a.b, b.a, b.b));
        }
        if (std.math.isInf(lo)) continue;
        if (@abs(lo - off) <= at_spec_window_mm) {
            at += len;
        } else {
            off_spec += len;
            worst = @max(worst, len);
        }
    }
    return .{ .at_spec = at, .off_spec = off_spec, .worst_run = worst };
}

/// How far from the class gap a stretch may sit and still count as at spec.
const at_spec_window_mm: f64 = 0.02;

// spec: placement/router - a coupled diff pair holds the class gap for the whole run, departing it only at a pad span or a via barrel and entering each departure by one 45 degree jog
test "dp_coupled holds the class gap out of a wide pad pair, converging in one jog" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Pads at 0.64 mm pitch — a connector's, well wider than a 0.4056 class gap —
    // with the escape running 0.9 mm out of the pad field to the terminal. The
    // legs must NOT hold 0.64 across that 0.9 mm: impedance is set by the
    // spacing, so every millimetre spent at pin pitch is a millimetre of wrong
    // line. One 45° jog at the pad, then class gap all the way.
    const off: f64 = 0.4056;
    const pitch: f64 = 0.64;
    const c = try straightLine(arena, -10, 0);
    const legs = (try build(arena, c, .{
        .off = off,
        .via_spread = off,
        .seq = .{
            try oneEnd(arena, .{ .x = -10, .y = -off / 2 }, .{ .x = -10, .y = off / 2 }),
            try oneEnd(arena, .{ .x = 0.9, .y = -pitch / 2 }, .{ .x = 0.9, .y = pitch / 2 }),
        },
        .mid = .{ .{ .x = -10, .y = 0, .layer = 0 }, .{ .x = 0, .y = 0, .layer = 0 } },
    })).?;

    // The jog is 45°: a lateral step of (pitch - off)/2 per leg costs the same
    // longitudinal distance, and nothing wider than the class gap survives past it.
    const jog = (pitch - off) / 2;
    var converged = false;
    for (legs.segs) |sg| {
        if (sg.side != .p or sg.kind != .chain) continue;
        const dx = @abs(sg.b.x - sg.a.x);
        const dy = @abs(sg.b.y - sg.a.y);
        if (dy <= weld_eps) continue; // the straight stub out of the pad body
        try testing.expectApproxEqAbs(dx, dy, 1e-9); // 45°
        try testing.expectApproxEqAbs(jog, dy, 1e-9);
        converged = true;
    }
    try testing.expect(converged);

    // And the run really is at spec for essentially all of its length.
    const prof = spacingProfile(legs, off);
    try testing.expect(prof.at_spec > 0);
    try testing.expect(prof.at_spec / (prof.at_spec + prof.off_spec) > 0.95);
    try testing.expect(prof.worst_run <= 0.3);
    try testing.expect(try legsSelfSimple(arena, legs));
}
