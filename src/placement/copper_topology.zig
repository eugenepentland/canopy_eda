//! Copper-topology and route-intent probes shared by DRC and final cleanup.
//!
//! Clearance DRC proves that copper does not touch the WRONG net. These probes
//! prove the complementary physical facts: every routed trace end lands on
//! useful copper and every through-via joins at least two copper layers. The
//! separate route-intent probe requires an endpoint on the other centreline.
//! A geometric trace graze is neither: it remains open until cleanup inserts a
//! real centreline bridge. Keeping all three readings is deliberate: fabricated
//! connectivity requires a full bottleneck cross-section, while a generated
//! route additionally names every junction explicitly.

const std = @import("std");
const numeric = @import("../numeric.zig");
const pad_shape = @import("pad_shape.zig");
const copper_contact = @import("copper_contact.zig");

/// Connectivity slack shared with the net-open oracle. Copper inside this
/// 1 µm numeric tolerance may join after the full-cross-section test passes.
const touch_slack_mm = copper_contact.join_slack_mm;

/// Numerical slack for an EXPLICIT trace junction. This is one nanometre in
/// board units: enough to absorb a copied-coordinate round trip, far below any
/// fabrication tolerance, trace width, or router grid. Generated copper is
/// canonicalized to reuse the exact witness coordinate before persistence.
const junction_eps_mm: f64 = 1e-6;

/// One same-net pad terminal in world coordinates.
pub const Terminal = struct {
    shape: pad_shape.Shape,
    net: i32,
    layer: u8,
    thru: bool = false,
};

/// One routed trace projected into topology-only geometry.
pub const Track = struct {
    a: [2]f64,
    b: [2]f64,
    layer: u8,
    width: f64,
    net: i32,
};

/// One routed via projected into topology-only geometry.
pub const Via = struct {
    at: [2]f64,
    dia: f64,
    net: i32,
};

fn layerBit(layer: u8) u64 {
    return if (layer < 64) @as(u64, 1) << @intCast(layer) else 0;
}

fn terminalPointTouch(t: Terminal, x: f64, y: f64, radius: f64, layer: u8, net: i32) bool {
    if (t.net != net or (!t.thru and t.layer != layer)) return false;
    return pad_shape.pointDist(t.shape.x0, t.shape.y0, t.shape.x1, t.shape.y1, t.shape.poly, x, y, std.math.inf(f64)) <= radius + touch_slack_mm;
}

/// The first electrically loose endpoint of `tracks[track_i]`, or null when
/// both ends land on same-net copper. `pour_layers` marks full/filled same-net
/// regions known to cover the endpoint's layer.
///
/// This asks only whether each END is attached — plus the one shape whose ends
/// are attached and which is still not a branch: a route emitted wholly inside
/// the ONLY pad of a one-terminal net, where the land already joins both ends.
/// The GENERAL form of that shape (any net, a chain rather than a segment) is
/// `redundantSections`, which REPORTS rather than removes; this narrow case stays
/// here because the finish has always pruned it and a single-pin breakout's
/// unfinished stub is exactly it.
pub fn looseEnd(
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    track_i: usize,
    pour_layers: [2]u64,
) ?[2]f64 {
    const track = tracks[track_i];
    if (track.net < 0) return null;
    var net_terminals: usize = 0;
    var sole: ?Terminal = null;
    for (terminals) |terminal| {
        if (terminal.net != track.net) continue;
        net_terminals += 1;
        sole = terminal;
    }
    return looseEndOf(
        .{ .terminals = terminals, .tracks = tracks, .vias = vias },
        track_i,
        pour_layers,
        .{ .count = net_terminals, .sole = sole },
        .{ .{}, .{} },
    );
}

/// `looseEnd` once the net's terminal census and (optionally) the endpoint's
/// copper neighbourhood are known. Both entry points funnel through here so the
/// indexed batch below cannot drift from the single-shot answer.
fn looseEndOf(
    copper: Copper,
    track_i: usize,
    pour_layers: [2]u64,
    census: NetCensus.Seen,
    near: [2]Neighbours,
) ?[2]f64 {
    const track = copper.tracks[track_i];
    if (track.net < 0) return null;
    if (census.count == 1) {
        const terminal = census.sole.?;
        if (terminalPointTouch(terminal, track.a[0], track.a[1], track.width / 2, track.layer, track.net) and
            terminalPointTouch(terminal, track.b[0], track.b[1], track.width / 2, track.layer, track.net))
            return track.b;
    }
    for ([_][2]f64{ track.a, track.b }, 0..) |p, end_i| {
        if (!endSupported(copper, track_i, p, pour_layers[end_i], near[end_i])) return p;
    }
    return null;
}

/// `looseEnd` for every stored section at once. One copper-locality index over
/// the lands, traces, and barrels replaces the per-section sweep over all three
/// arrays, and one census replaces the per-section terminal count; every
/// verdict is the one `looseEnd` gives for the same section.
pub fn looseEnds(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    pour_layers: []const [2]u64,
) std.mem.Allocator.Error![]const ?[2]f64 {
    const out = try arena.alloc(?[2]f64, tracks.len);
    var indexes = try FeatureIndexes.build(arena, terminals, tracks, vias);
    const census = try netCensus(arena, terminals);
    var terminal_ids: [2]std.ArrayList(u32) = .{ .empty, .empty };
    var track_ids: [2]std.ArrayList(u32) = .{ .empty, .empty };
    var via_ids: [2]std.ArrayList(u32) = .{ .empty, .empty };
    for (tracks, 0..) |track, track_i| {
        const poured = if (track_i < pour_layers.len) pour_layers[track_i] else .{ 0, 0 };
        if (track.net < 0) {
            out[track_i] = null;
            continue;
        }
        var near: [2]Neighbours = .{ .{}, .{} };
        for ([_][2]f64{ track.a, track.b }, 0..) |p, end_i| {
            const probe = pointBox(p, track.width / 2);
            try indexes.terminal.near(arena, &terminal_ids[end_i], probe, touch_slack_mm);
            try indexes.track.near(arena, &track_ids[end_i], probe, touch_slack_mm);
            try indexes.via.near(arena, &via_ids[end_i], probe, touch_slack_mm);
            near[end_i] = .{
                .terminals = terminal_ids[end_i].items,
                .tracks = track_ids[end_i].items,
                .vias = via_ids[end_i].items,
            };
        }
        out[track_i] = looseEndOf(
            .{ .terminals = terminals, .tracks = tracks, .vias = vias },
            track_i,
            poured,
            census.of(track.net),
            near,
        );
    }
    return out;
}

/// How many lands each net owns, and which one when it owns exactly one — the
/// only two facts `looseEnd`'s one-terminal special case reads.
const NetCensus = struct {
    counts: []const usize,
    sole: []const ?Terminal,

    const Seen = struct { count: usize, sole: ?Terminal };

    fn of(self: NetCensus, net: i32) Seen {
        if (net < 0) return .{ .count = 0, .sole = null };
        const i: usize = @intCast(net);
        if (i >= self.counts.len) return .{ .count = 0, .sole = null };
        return .{ .count = self.counts[i], .sole = self.sole[i] };
    }
};

fn netCensus(arena: std.mem.Allocator, terminals: []const Terminal) std.mem.Allocator.Error!NetCensus {
    var highest: i32 = -1;
    for (terminals) |terminal| highest = @max(highest, terminal.net);
    const span: usize = if (highest < 0) 0 else @as(usize, @intCast(highest)) + 1;
    const counts = try arena.alloc(usize, span);
    const sole = try arena.alloc(?Terminal, span);
    @memset(counts, 0);
    @memset(sole, null);
    for (terminals) |terminal| {
        if (terminal.net < 0) continue;
        const i: usize = @intCast(terminal.net);
        counts[i] += 1;
        sole[i] = terminal;
    }
    return .{ .counts = counts, .sole = sole };
}

/// The three copper arrays every endpoint question reads together.
const Copper = struct {
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
};

/// Which lands / traces / barrels one endpoint question has to consider. A null
/// list means "every one of them" — the non-allocating single-shot entry point;
/// the batch entry narrows each list with the shared copper-locality index. The
/// predicates below only ever answer "is this end supported at all", so a
/// narrowed list changes the work, never the answer.
const Neighbours = struct {
    terminals: ?[]const u32 = null,
    tracks: ?[]const u32 = null,
    vias: ?[]const u32 = null,
};

/// Walk either an explicit ascending candidate list or the whole array, so one
/// predicate body serves the indexed and unindexed entry points.
const IdIter = struct {
    ids: ?[]const u32,
    len: usize,
    i: usize = 0,

    fn init(ids: ?[]const u32, len: usize) IdIter {
        return .{ .ids = ids, .len = len };
    }

    fn next(self: *IdIter) ?usize {
        if (self.ids) |ids| {
            if (self.i >= ids.len) return null;
            defer self.i += 1;
            return ids[self.i];
        }
        if (self.i >= self.len) return null;
        defer self.i += 1;
        return self.i;
    }
};

fn pointOnCenterline(track: Track, p: [2]f64) bool {
    return pad_shape.segPointDist(
        track.a[0],
        track.a[1],
        track.b[0],
        track.b[1],
        p[0],
        p[1],
    ) <= junction_eps_mm;
}

/// An intentional same-net/same-layer trace junction: at least one stored
/// endpoint lies on the other trace's centreline. This admits an ordinary T
/// without requiring the through-line to be serialized as two sections, while
/// refusing a cap-to-cap graze and a mid-span X whose route topology names no
/// junction at all.
fn tracksJoinExplicitly(a: Track, b: Track) bool {
    if (a.net != b.net or a.layer != b.layer) return false;
    return pointOnCenterline(b, a.a) or pointOnCenterline(b, a.b) or
        pointOnCenterline(a, b.a) or pointOnCenterline(a, b.b);
}

/// The fabrication reading: does one full cross-section of the narrower trace
/// lie in the other trace's copper? Kept separate from
/// `tracksJoinExplicitly`: a robust X crossing conducts but still needs an
/// explicit serialized junction before generated copper is accepted.
fn tracksJoinPhysically(a: Track, b: Track) bool {
    if (a.net != b.net or a.layer != b.layer) return false;
    return copper_contact.trackTrackConnects(
        .{ .a = a.a, .b = a.b, .width = a.width },
        .{ .a = b.a, .b = b.b, .width = b.width },
    );
}

/// The looser drawing-space relation used only to find contacts cleanup can
/// repair. It must never feed a connectivity graph directly.
fn tracksOverlapGeometrically(a: Track, b: Track) bool {
    if (a.net != b.net or a.layer != b.layer) return false;
    return copper_contact.trackTrackCapsulesOverlap(
        .{ .a = a.a, .b = a.b, .width = a.width },
        .{ .a = b.a, .b = b.b, .width = b.width },
    );
}

fn tracksJoin(a: Track, b: Track) bool {
    return tracksJoinPhysically(a, b);
}

// ── Spatial index ────────────────────────────────────────────────────────────
//
// Every contact predicate in this file is a LOCAL question: two copper features
// can only meet when their copper bounding boxes lie within `touch_slack_mm` of
// each other, because each predicate's own first test is a distance no larger
// than the sum of the two features' half widths plus that slack. This
// uniform-cell index answers "which features are near this box", so the
// all-pairs sweeps it replaces cost O(n · neighbours) instead of O(n²).
//
// It only PRUNES: every surviving candidate runs the identical predicate, and
// the boxes below CONTAIN their feature's copper, so a dropped pair is proven
// apart. Cells are CSR-packed rather than hashed because this file also
// compiles to the client's freestanding `drc.wasm`, where the only allocator is
// the caller's arena; queries return ascending indices, which is the order the
// nested loops visited.

const Box = [4]f64;

/// A trace's copper AABB: the centreline's box grown by the half width. A
/// non-positive width grows by nothing, which is still a container.
fn trackBox(track: Track) Box {
    const half = @max(track.width, 0) / 2;
    return .{
        @min(track.a[0], track.b[0]) - half,
        @min(track.a[1], track.b[1]) - half,
        @max(track.a[0], track.b[0]) + half,
        @max(track.a[1], track.b[1]) + half,
    };
}

/// A land's copper AABB. `pad_shape` keeps every outline inside this box, so it
/// contains a custom polygon's copper as well.
fn terminalBox(terminal: Terminal) Box {
    return .{ terminal.shape.x0, terminal.shape.y0, terminal.shape.x1, terminal.shape.y1 };
}

/// A barrel's outer copper AABB.
fn viaBox(via: Via) Box {
    const radius = @max(via.dia, 0) / 2;
    return .{ via.at[0] - radius, via.at[1] - radius, via.at[0] + radius, via.at[1] + radius };
}

/// The probe box for a trace ENDPOINT question: every endpoint predicate below
/// measures from the stored point and allows the probing trace's half width.
fn pointBox(p: [2]f64, radius: f64) Box {
    const grown = @max(radius, 0);
    return .{ p[0] - grown, p[1] - grown, p[0] + grown, p[1] + grown };
}

/// Cells spanning `span` at `cell` size, clamped so a degenerate extent can
/// never ask for an unbounded grid.
fn spanCells(span: f64, cell_mm: f64) usize {
    if (!(span > 0)) return 1;
    const wanted = @floor(span / cell_mm) + 1;
    if (!(wanted < 1.0e6)) return 1_000_000;
    if (!(wanted > 1)) return 1;
    return numeric.checkedInt(usize, wanted) orelse 1;
}

/// Uniform-cell bucket index over feature AABBs. `inv == 0` is the single-cell
/// fallback used for degenerate (empty or non-finite) input: every query then
/// returns every feature, which is exactly the loop this replaces.
const Index = struct {
    minx: f64 = 0,
    miny: f64 = 0,
    inv: f64 = 0,
    nx: usize = 1,
    ny: usize = 1,
    starts: []const u32 = &.{},
    items: []const u32 = &.{},
    stamp: []u32 = &.{},
    generation: u32 = 0,

    fn cellOf(self: Index, value: f64, origin: f64, limit: usize) usize {
        if (self.inv == 0) return 0;
        const scaled = @floor((value - origin) * self.inv);
        if (!(scaled > 0)) return 0; // below the origin, or not a number
        if (!(scaled < @as(f64, @floatFromInt(limit)))) return limit - 1;
        return numeric.checkedInt(usize, scaled) orelse 0;
    }

    /// Fill `out` with the ascending, deduplicated indices whose cells meet
    /// `box` grown by `delta`. `out` belongs to the caller so two queries may
    /// be live at once (an endpoint probe inside a feature sweep).
    fn near(
        self: *Index,
        arena: std.mem.Allocator,
        out: *std.ArrayList(u32),
        box: Box,
        delta: f64,
    ) std.mem.Allocator.Error!void {
        out.clearRetainingCapacity();
        if (self.stamp.len == 0) return;
        if (self.generation == std.math.maxInt(u32)) {
            @memset(self.stamp, 0);
            self.generation = 0;
        }
        self.generation += 1;
        const x1 = self.cellOf(box[2] + delta, self.minx, self.nx);
        const y1 = self.cellOf(box[3] + delta, self.miny, self.ny);
        var cx = self.cellOf(box[0] - delta, self.minx, self.nx);
        while (cx <= x1) : (cx += 1) {
            var cy = self.cellOf(box[1] - delta, self.miny, self.ny);
            while (cy <= y1) : (cy += 1) {
                const cell = cx * self.ny + cy;
                for (self.items[self.starts[cell]..self.starts[cell + 1]]) |item| {
                    if (self.stamp[item] == self.generation) continue;
                    self.stamp[item] = self.generation;
                    try out.append(arena, item);
                }
            }
        }
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    }
};

fn buildIndex(arena: std.mem.Allocator, boxes: []const Box) std.mem.Allocator.Error!Index {
    var index = Index{};
    index.stamp = try arena.alloc(u32, boxes.len);
    @memset(index.stamp, 0);
    if (boxes.len == 0) {
        const empty = try arena.alloc(u32, 2);
        empty[0] = 0;
        empty[1] = 0;
        index.starts = empty;
        return index;
    }

    var minx = boxes[0][0];
    var miny = boxes[0][1];
    var maxx = boxes[0][2];
    var maxy = boxes[0][3];
    var extent_sum: f64 = 0;
    var extent_max: f64 = 0;
    var finite = true;
    for (boxes) |box| {
        for (box) |value| finite = finite and std.math.isFinite(value);
        minx = @min(minx, box[0]);
        miny = @min(miny, box[1]);
        maxx = @max(maxx, box[2]);
        maxy = @max(maxy, box[3]);
        const extent = @max(box[2] - box[0], box[3] - box[1]);
        extent_sum += extent;
        extent_max = @max(extent_max, extent);
    }
    index.minx = minx;
    index.miny = miny;

    // One feature per cell on average, never finer than the widest feature's
    // 64th (so a long trace cannot be inserted into unboundedly many cells) and
    // never so fine that the cell table dwarfs the features it indexes.
    const count: f64 = @floatFromInt(boxes.len);
    var cell_mm = @max(
        @max(extent_sum / count, @sqrt(@max(maxx - minx, 0) * @max(maxy - miny, 0) / count)),
        extent_max / 64,
    );
    if (finite and std.math.isFinite(cell_mm) and cell_mm > 0) {
        index.inv = 1.0 / cell_mm;
        const cap = 8 * boxes.len + 64;
        var guard: usize = 0;
        while (guard < 64) : (guard += 1) {
            index.nx = spanCells(maxx - minx, cell_mm);
            index.ny = spanCells(maxy - miny, cell_mm);
            if (index.nx * index.ny <= cap) break;
            cell_mm *= 2;
            index.inv = 1.0 / cell_mm;
        }
        index.nx = spanCells(maxx - minx, cell_mm);
        index.ny = spanCells(maxy - miny, cell_mm);
    }

    const cells = index.nx * index.ny;
    const starts = try arena.alloc(u32, cells + 1);
    @memset(starts, 0);
    for (boxes) |box| {
        const x1 = index.cellOf(box[2], minx, index.nx);
        const y1 = index.cellOf(box[3], miny, index.ny);
        var cx = index.cellOf(box[0], minx, index.nx);
        while (cx <= x1) : (cx += 1) {
            var cy = index.cellOf(box[1], miny, index.ny);
            while (cy <= y1) : (cy += 1) starts[cx * index.ny + cy + 1] += 1;
        }
    }
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const items = try arena.alloc(u32, starts[cells]);
    const cursor = try arena.alloc(u32, cells);
    @memcpy(cursor, starts[0..cells]);
    for (boxes, 0..) |box, i| {
        const x1 = index.cellOf(box[2], minx, index.nx);
        const y1 = index.cellOf(box[3], miny, index.ny);
        var cx = index.cellOf(box[0], minx, index.nx);
        while (cx <= x1) : (cx += 1) {
            var cy = index.cellOf(box[1], miny, index.ny);
            while (cy <= y1) : (cy += 1) {
                const cell = cx * index.ny + cy;
                items[cursor[cell]] = @intCast(i);
                cursor[cell] += 1;
            }
        }
    }
    index.starts = starts;
    index.items = items;
    return index;
}

fn trackBoxes(arena: std.mem.Allocator, tracks: []const Track) std.mem.Allocator.Error![]const Box {
    const out = try arena.alloc(Box, tracks.len);
    for (tracks, out) |track, *box| box.* = trackBox(track);
    return out;
}

fn terminalBoxes(arena: std.mem.Allocator, terminals: []const Terminal) std.mem.Allocator.Error![]const Box {
    const out = try arena.alloc(Box, terminals.len);
    for (terminals, out) |terminal, *box| box.* = terminalBox(terminal);
    return out;
}

fn viaBoxes(arena: std.mem.Allocator, vias: []const Via) std.mem.Allocator.Error![]const Box {
    const out = try arena.alloc(Box, vias.len);
    for (vias, out) |via, *box| box.* = viaBox(via);
    return out;
}

/// The three feature indexes one via-redundancy pass shares between its graph
/// build and its per-candidate endpoint probes, so the board is bucketed once.
const FeatureIndexes = struct {
    track_boxes: []const Box,
    terminal_boxes: []const Box,
    via_boxes: []const Box,
    track: Index,
    terminal: Index,
    via: Index,

    fn build(
        arena: std.mem.Allocator,
        terminals: []const Terminal,
        tracks: []const Track,
        vias: []const Via,
    ) std.mem.Allocator.Error!FeatureIndexes {
        const track_boxes = try trackBoxes(arena, tracks);
        const terminal_boxes = try terminalBoxes(arena, terminals);
        const via_boxes = try viaBoxes(arena, vias);
        return .{
            .track_boxes = track_boxes,
            .terminal_boxes = terminal_boxes,
            .via_boxes = via_boxes,
            .track = try buildIndex(arena, track_boxes),
            .terminal = try buildIndex(arena, terminal_boxes),
            .via = try buildIndex(arena, via_boxes),
        };
    }
};

fn rootOf(parent: []usize, start: usize) usize {
    var node = start;
    while (parent[node] != node) node = parent[node];
    return node;
}

fn unite(parent: []usize, a: usize, b: usize) void {
    const ra = rootOf(parent, a);
    const rb = rootOf(parent, b);
    if (ra != rb) parent[rb] = ra;
}

/// One physical trace contact on which the route would rely despite having no
/// explicit centreline junction. `at` is the marker position; `a`/`b` are the
/// two stored section indices.
pub const ImplicitJoin = struct {
    a: usize,
    b: usize,
    at: [2]f64,
};

/// Every cross-component physical contact. Contacts between sections already
/// connected by an explicit path are harmless same-net overlap and are not
/// reported: deleting that incidental contact would not change route intent.
fn nonExplicitContacts(
    arena: std.mem.Allocator,
    tracks: []const Track,
    robust_only: bool,
) std.mem.Allocator.Error![]const ImplicitJoin {
    const parent = try arena.alloc(usize, tracks.len);
    for (parent, 0..) |*p, i| p.* = i;
    const boxes = try trackBoxes(arena, tracks);
    var index = try buildIndex(arena, boxes);
    var near: std.ArrayList(u32) = .empty;
    for (tracks, 0..) |track, i| {
        try index.near(arena, &near, boxes[i], touch_slack_mm);
        for (near.items) |candidate| {
            const j: usize = candidate;
            if (j <= i) continue;
            if (tracksJoinExplicitly(track, tracks[j])) unite(parent, i, j);
        }
    }
    var out: std.ArrayList(ImplicitJoin) = .empty;
    for (tracks, 0..) |track, i| {
        try index.near(arena, &near, boxes[i], touch_slack_mm);
        for (near.items) |candidate| {
            const j: usize = candidate;
            if (j <= i) continue;
            const other = tracks[j];
            if (rootOf(parent, i) == rootOf(parent, j)) continue;
            if (robust_only) {
                if (!tracksJoinPhysically(track, other)) continue;
            } else if (!tracksOverlapGeometrically(track, other)) continue;
            try out.append(arena, .{
                .a = i,
                .b = j,
                .at = pad_shape.segSegMid(track.a, track.b, other.a, other.b),
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Robust but unserialized contacts reported as `implicit_junction` warnings.
/// Weak capsule grazes are absent: the connectivity graph keeps them open.
pub fn implicitJoins(
    arena: std.mem.Allocator,
    tracks: []const Track,
) std.mem.Allocator.Error![]const ImplicitJoin {
    return nonExplicitContacts(arena, tracks, true);
}

/// Every geometric contact across explicit components, including weak grazes.
/// Only junction canonicalization may consume this looser relation, to insert
/// a real centreline bridge before connectivity is evaluated again.
pub fn repairableJoins(
    arena: std.mem.Allocator,
    tracks: []const Track,
) std.mem.Allocator.Error![]const ImplicitJoin {
    return nonExplicitContacts(arena, tracks, false);
}

/// Electrical supports beyond pads and tracks. `live_vias` are barrels that
/// reach at least two copper layers; `pour_layers[i][0..2]` carries the
/// filled/poured layer masks at track i's two endpoints. When present,
/// `pour_components` names the exact fabricated fill component at each
/// endpoint; two endpoints share pour conductivity only when those ids match.
/// Empty slices preserve the no-via/no-pour fixture shorthand.
pub const BranchSupport = struct {
    live_vias: []const Via = &.{},
    pour_layers: []const [2]u64 = &.{},
    pour_components: []const [2]u64 = &.{},
};

/// Exact fabricated-fill membership for the persistent nodes in the via
/// deletion graph. Component ids are opaque but globally unique within one DRC
/// pass; equal ids conduct. Nested slices let a through pad or barrel touch
/// several outer pours / inner planes without collapsing their identities.
pub const ViaSupport = struct {
    candidates: []const bool = &.{},
    terminal_components: []const []const u64 = &.{},
    track_components: []const [2]u64 = &.{},
    via_components: []const []const u64 = &.{},
};

fn endpointPourLayers(support: BranchSupport, track_i: usize) [2]u64 {
    return if (track_i < support.pour_layers.len) support.pour_layers[track_i] else .{ 0, 0 };
}

fn endpointPourComponents(support: BranchSupport, track_i: usize) [2]u64 {
    return if (track_i < support.pour_components.len) support.pour_components[track_i] else .{ 0, 0 };
}

fn endpointPourId(support: BranchSupport, track: Track, track_i: usize, end_i: usize) u64 {
    const exact = endpointPourComponents(support, track_i)[end_i];
    if (exact != 0) return exact;
    if (support.pour_components.len != 0 or track.net < 0) return 0;
    return (@as(u64, @intCast(track.net + 1)) << 8) | @as(u64, track.layer) + 1;
}

fn addNeighbour(
    arena: std.mem.Allocator,
    graph: []std.ArrayList(usize),
    a: usize,
    b: usize,
) std.mem.Allocator.Error!void {
    if (a == b) return;
    for (graph[a].items) |old| if (old == b) return;
    try graph[a].append(arena, b);
    try graph[b].append(arena, a);
}

const PourKey = struct { id: u64 };

fn trackTouchesTerminal(track: Track, terminal: Terminal) bool {
    if (terminal.net != track.net or (!terminal.thru and terminal.layer != track.layer)) return false;
    return copper_contact.padTrackConnects(terminal.shape, track.a, track.b, track.width);
}

fn trackTouchesVia(track: Track, via: Via) bool {
    if (track.net != via.net) return false;
    return copper_contact.trackViaConnects(
        .{ .a = track.a, .b = track.b, .width = track.width },
        .{ .at = via.at, .dia = via.dia },
    );
}

fn pourKeys(arena: std.mem.Allocator, tracks: []const Track, support: BranchSupport) std.mem.Allocator.Error![]const PourKey {
    var keys: std.ArrayList(PourKey) = .empty;
    for (tracks, 0..) |track, i| {
        const poured = endpointPourLayers(support, i);
        for (0..2) |end_i| {
            if (poured[end_i] & layerBit(track.layer) == 0) continue;
            const id = endpointPourId(support, track, i, end_i);
            if (id == 0) continue;
            var exists = false;
            for (keys.items) |old| if (old.id == id) {
                exists = true;
                break;
            };
            if (!exists) try keys.append(arena, .{ .id = id });
        }
    }
    return keys.items;
}

fn buildSupportGraph(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    support: BranchSupport,
    pours: []const PourKey,
) std.mem.Allocator.Error![]std.ArrayList(usize) {
    const terminal_start = tracks.len;
    const via_start = terminal_start + terminals.len;
    const pour_start = via_start + support.live_vias.len;
    const graph = try arena.alloc(std.ArrayList(usize), pour_start + pours.len);
    for (graph) |*neighbours| neighbours.* = .empty;

    const boxes = try trackBoxes(arena, tracks);
    var track_index = try buildIndex(arena, boxes);
    var terminal_index = try buildIndex(arena, try terminalBoxes(arena, terminals));
    var via_index = try buildIndex(arena, try viaBoxes(arena, support.live_vias));
    var near: std.ArrayList(u32) = .empty;

    for (tracks, 0..) |track, i| {
        try track_index.near(arena, &near, boxes[i], touch_slack_mm);
        for (near.items) |candidate| {
            const j: usize = candidate;
            if (j <= i) continue;
            if (tracksJoin(track, tracks[j])) try addNeighbour(arena, graph, i, j);
        }
        try terminal_index.near(arena, &near, boxes[i], touch_slack_mm);
        for (near.items) |candidate| {
            const terminal_i: usize = candidate;
            if (trackTouchesTerminal(track, terminals[terminal_i])) try addNeighbour(arena, graph, i, terminal_start + terminal_i);
        }
        try via_index.near(arena, &near, boxes[i], touch_slack_mm);
        for (near.items) |candidate| {
            const via_i: usize = candidate;
            if (trackTouchesVia(track, support.live_vias[via_i])) try addNeighbour(arena, graph, i, via_start + via_i);
        }
        const poured = endpointPourLayers(support, i);
        for (0..2) |end_i| {
            const id = endpointPourId(support, track, i, end_i);
            if (poured[end_i] & layerBit(track.layer) == 0 or id == 0) continue;
            for (pours, 0..) |pour, pour_i| {
                if (pour.id == id)
                    try addNeighbour(arena, graph, i, pour_start + pour_i);
            }
        }
    }
    return graph;
}

const Components = struct {
    id: []const usize,
    supports: []const usize,
    first_support: []const ?usize,
};

fn graphComponents(
    arena: std.mem.Allocator,
    graph: []const std.ArrayList(usize),
    track_count: usize,
) std.mem.Allocator.Error!Components {
    const unseen = std.math.maxInt(usize);
    const id = try arena.alloc(usize, graph.len);
    @memset(id, unseen);
    const supports = try arena.alloc(usize, graph.len);
    @memset(supports, 0);
    const first_support = try arena.alloc(?usize, graph.len);
    @memset(first_support, null);
    var queue: std.ArrayList(usize) = .empty;
    var component: usize = 0;
    for (graph, 0..) |_, start| {
        if (id[start] != unseen) continue;
        queue.clearRetainingCapacity();
        try queue.append(arena, start);
        id[start] = component;
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const vertex = queue.items[head];
            if (vertex >= track_count) {
                supports[component] += 1;
                if (first_support[component] == null) first_support[component] = vertex;
            }
            for (graph[vertex].items) |other| {
                if (id[other] != unseen) continue;
                id[other] = component;
                try queue.append(arena, other);
            }
        }
        component += 1;
    }
    return .{ .id = id, .supports = supports, .first_support = first_support };
}

/// Which trace sections of a support component are the SOLE path from some
/// support to that component's root support.
///
/// This used to be a whole breadth-first re-walk of the component per candidate
/// section. It is the textbook CUT-VERTEX question, so one depth-first pass
/// (Tarjan) settles every section of the component at once: rooted at the
/// component's first support, deleting `v` detaches exactly the child subtrees
/// `c` with `low[c] >= disc[v]`, so `v` is load bearing exactly when one of
/// those subtrees still holds a support. A section the walk cannot reach —
/// its copper already deleted by an accepted removal — detaches nothing, which
/// is the same verdict the re-walk gave it.
///
/// The joint deletion plan mutates the graph, so `analyze` is re-run for a
/// component when (and only when) a removal inside it is accepted; components
/// never share an edge, so no other component's answer can go stale.
const Cuts = struct {
    /// Discovery index, 0 while unvisited. Only ever compared within one run.
    disc: []u32,
    low: []u32,
    subtree_supports: []u32,
    /// Does deleting this vertex detach a support from the component root?
    separates: []bool,
    parent: []usize,
    edge: []usize,
    graph: []const std.ArrayList(usize),
    track_count: usize,
    /// The joint plan's live deletion set — read, never written, here.
    removed: []const bool,
    timer: u32 = 0,
    stack: std.ArrayList(usize) = .empty,

    fn prepare(
        arena: std.mem.Allocator,
        graph: []const std.ArrayList(usize),
        track_count: usize,
        removed: []const bool,
    ) std.mem.Allocator.Error!Cuts {
        const cuts = Cuts{
            .disc = try arena.alloc(u32, graph.len),
            .low = try arena.alloc(u32, graph.len),
            .subtree_supports = try arena.alloc(u32, graph.len),
            .separates = try arena.alloc(bool, graph.len),
            .parent = try arena.alloc(usize, graph.len),
            .edge = try arena.alloc(usize, graph.len),
            .graph = graph,
            .track_count = track_count,
            .removed = removed,
        };
        @memset(cuts.disc, 0);
        @memset(cuts.separates, false);
        return cuts;
    }

    fn analyze(
        self: *Cuts,
        arena: std.mem.Allocator,
        members: []const u32,
        root: usize,
    ) std.mem.Allocator.Error!void {
        const graph = self.graph;
        const track_count = self.track_count;
        const removed = self.removed;
        for (members) |member| {
            self.disc[member] = 0;
            self.separates[member] = false;
        }
        self.timer = 1;
        self.discover(root, root, track_count);
        self.stack.clearRetainingCapacity();
        try self.stack.append(arena, root);
        while (self.stack.items.len > 0) {
            const vertex = self.stack.items[self.stack.items.len - 1];
            if (self.edge[vertex] < graph[vertex].items.len) {
                const other = graph[vertex].items[self.edge[vertex]];
                self.edge[vertex] += 1;
                if (other < track_count and removed[other]) continue;
                if (other == self.parent[vertex]) continue;
                if (self.disc[other] == 0) {
                    self.discover(other, vertex, track_count);
                    try self.stack.append(arena, other);
                } else self.low[vertex] = @min(self.low[vertex], self.disc[other]);
                continue;
            }
            _ = self.stack.pop();
            if (vertex == root) continue;
            const up = self.parent[vertex];
            self.low[up] = @min(self.low[up], self.low[vertex]);
            self.subtree_supports[up] += self.subtree_supports[vertex];
            if (self.low[vertex] >= self.disc[up] and self.subtree_supports[vertex] > 0)
                self.separates[up] = true;
        }
    }

    fn discover(self: *Cuts, vertex: usize, from: usize, track_count: usize) void {
        self.disc[vertex] = self.timer;
        self.low[vertex] = self.timer;
        self.timer += 1;
        self.subtree_supports[vertex] = if (vertex >= track_count) 1 else 0;
        self.parent[vertex] = from;
        self.edge[vertex] = 0;
    }
};

/// The vertices of each component, ascending, CSR-packed — the reset list one
/// component's cut recompute walks.
const ComponentMembers = struct {
    starts: []const u32,
    items: []const u32,

    fn of(self: ComponentMembers, component: usize) []const u32 {
        return self.items[self.starts[component]..self.starts[component + 1]];
    }
};

fn componentMembers(arena: std.mem.Allocator, ids: []const usize) std.mem.Allocator.Error!ComponentMembers {
    var highest: usize = 0;
    for (ids) |id| highest = @max(highest, id);
    const count = if (ids.len == 0) 0 else highest + 1;
    const starts = try arena.alloc(u32, count + 1);
    @memset(starts, 0);
    for (ids) |id| starts[id + 1] += 1;
    for (1..starts.len) |i| starts[i] += starts[i - 1];
    const items = try arena.alloc(u32, ids.len);
    const cursor = try arena.alloc(u32, count);
    @memcpy(cursor, starts[0..count]);
    for (ids, 0..) |id, vertex| {
        items[cursor[id]] = @intCast(vertex);
        cursor[id] += 1;
    }
    return .{ .starts = starts, .items = items };
}

/// One result per stored trace section. A section is redundant when deleting
/// it leaves every pad, live via, and same-net poured region that was connected
/// before the deletion connected afterward. Copper-only limbs do not keep a
/// section alive: they are drawing artifacts, not circuit destinations.
pub fn redundantSections(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    support: BranchSupport,
) std.mem.Allocator.Error![]const bool {
    return (try analyzeRedundancy(arena, terminals, tracks, support)).individual;
}

/// Per-section warning verdicts plus one jointly safe automatic removal set.
pub const RedundancyAnalysis = struct {
    individual: []const bool,
    removal: []const bool,
    /// Does this section's copper component join MORE THAN ONE support? Only
    /// there does a redundancy verdict mean "the board keeps another path to
    /// the same places". A component reaching one support or none is copper
    /// that carries nothing at all — the same warning to a reader, but a
    /// different claim, and one a FILL-BLIND caller must not act on: the
    /// support it cannot see may be the pour the copper was drawn to reach.
    /// DRC reports both shapes; automatic cleanup consumes only the first.
    spanning: []const bool,
};

fn terminalsTouch(a: Terminal, b: Terminal) bool {
    if (a.net != b.net) return false;
    if (!a.thru and !b.thru) {
        if (a.layer != b.layer) return false;
    }
    return pad_shape.shapeGap(a.shape, b.shape, touch_slack_mm) <= touch_slack_mm;
}

fn terminalTouchesVia(terminal: Terminal, via: Via) bool {
    if (terminal.net != via.net) return false;
    return pad_shape.pointDist(
        terminal.shape.x0,
        terminal.shape.y0,
        terminal.shape.x1,
        terminal.shape.y1,
        terminal.shape.poly,
        via.at[0],
        via.at[1],
        std.math.inf(f64),
    ) <= via.dia / 2 + touch_slack_mm;
}

fn viasTouch(a: Via, b: Via) bool {
    if (a.net != b.net) return false;
    return std.math.hypot(a.at[0] - b.at[0], a.at[1] - b.at[1]) <=
        (a.dia + b.dia) / 2 + touch_slack_mm;
}

/// Physical copper graph used by redundant-via pruning. Exact fabricated fill
/// components supplied through `ViaSupport` are persistent vertices alongside
/// every pad, trace, and via. Callers protect any contact whose fill cannot be
/// named exactly, so an outline alone never receives conductivity credit.
fn buildViaGraph(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    support: ViaSupport,
    indexes: *FeatureIndexes,
) std.mem.Allocator.Error![]std.ArrayList(usize) {
    const terminal_start = tracks.len;
    const via_start = terminal_start + terminals.len;
    const component_start = via_start + vias.len;
    const components = try viaComponentKeys(arena, support);
    const graph = try arena.alloc(std.ArrayList(usize), component_start + components.len);
    for (graph) |*neighbours| neighbours.* = .empty;

    const track_boxes = indexes.track_boxes;
    const terminal_boxes = indexes.terminal_boxes;
    const via_boxes = indexes.via_boxes;
    const track_index = &indexes.track;
    const terminal_index = &indexes.terminal;
    const via_index = &indexes.via;
    var near: std.ArrayList(u32) = .empty;

    for (tracks, 0..) |track, track_i| {
        try track_index.near(arena, &near, track_boxes[track_i], touch_slack_mm);
        for (near.items) |candidate| {
            const other_i: usize = candidate;
            if (other_i <= track_i) continue;
            if (tracksJoin(track, tracks[other_i])) try addNeighbour(arena, graph, track_i, other_i);
        }
        try terminal_index.near(arena, &near, track_boxes[track_i], touch_slack_mm);
        for (near.items) |candidate| {
            const terminal_i: usize = candidate;
            if (trackTouchesTerminal(track, terminals[terminal_i]))
                try addNeighbour(arena, graph, track_i, terminal_start + terminal_i);
        }
        try via_index.near(arena, &near, track_boxes[track_i], touch_slack_mm);
        for (near.items) |candidate| {
            const via_i: usize = candidate;
            if (trackTouchesVia(track, vias[via_i]))
                try addNeighbour(arena, graph, track_i, via_start + via_i);
        }
    }
    for (terminals, 0..) |terminal, terminal_i| {
        try terminal_index.near(arena, &near, terminal_boxes[terminal_i], touch_slack_mm);
        for (near.items) |candidate| {
            const other_i: usize = candidate;
            if (other_i <= terminal_i) continue;
            if (terminalsTouch(terminal, terminals[other_i]))
                try addNeighbour(arena, graph, terminal_start + terminal_i, terminal_start + other_i);
        }
        try via_index.near(arena, &near, terminal_boxes[terminal_i], touch_slack_mm);
        for (near.items) |candidate| {
            const via_i: usize = candidate;
            if (terminalTouchesVia(terminal, vias[via_i]))
                try addNeighbour(arena, graph, terminal_start + terminal_i, via_start + via_i);
        }
    }
    for (vias, 0..) |via, via_i| {
        try via_index.near(arena, &near, via_boxes[via_i], touch_slack_mm);
        for (near.items) |candidate| {
            const other_i: usize = candidate;
            if (other_i <= via_i) continue;
            if (viasTouch(via, vias[other_i]))
                try addNeighbour(arena, graph, via_start + via_i, via_start + other_i);
        }
    }
    try connectViaSupport(
        arena,
        graph,
        components,
        .{ .component = component_start, .terminal = terminal_start, .via = via_start },
        .{ tracks.len, terminals.len, vias.len },
        support,
    );
    return graph;
}

fn viaComponentKeys(arena: std.mem.Allocator, support: ViaSupport) std.mem.Allocator.Error![]const u64 {
    var components: std.ArrayList(u64) = .empty;
    for (support.terminal_components) |ids| for (ids) |id| try appendComponent(arena, &components, id);
    for (support.track_components) |ends| for (ends) |id| try appendComponent(arena, &components, id);
    for (support.via_components) |ids| for (ids) |id| try appendComponent(arena, &components, id);
    return components.items;
}

const ViaGraphStarts = struct {
    component: usize,
    terminal: usize,
    via: usize,
};

fn connectViaSupport(
    arena: std.mem.Allocator,
    graph: []std.ArrayList(usize),
    components: []const u64,
    starts: ViaGraphStarts,
    counts: [3]usize,
    support: ViaSupport,
) std.mem.Allocator.Error!void {
    for (support.track_components, 0..) |ends, track_i| {
        if (track_i >= counts[0]) break;
        for (ends) |id| try connectComponent(arena, graph, components, starts.component, track_i, id);
    }
    for (support.terminal_components, 0..) |ids, terminal_i| {
        if (terminal_i >= counts[1]) break;
        for (ids) |id| try connectComponent(arena, graph, components, starts.component, starts.terminal + terminal_i, id);
    }
    for (support.via_components, 0..) |ids, via_i| {
        if (via_i >= counts[2]) break;
        for (ids) |id| try connectComponent(arena, graph, components, starts.component, starts.via + via_i, id);
    }
}

fn appendComponent(arena: std.mem.Allocator, components: *std.ArrayList(u64), id: u64) std.mem.Allocator.Error!void {
    if (id == 0) return;
    for (components.items) |old| if (old == id) return;
    try components.append(arena, id);
}

fn connectComponent(
    arena: std.mem.Allocator,
    graph: []std.ArrayList(usize),
    components: []const u64,
    component_start: usize,
    node: usize,
    id: u64,
) std.mem.Allocator.Error!void {
    if (id == 0) return;
    for (components, 0..) |component, component_i| {
        if (component != id) continue;
        try addNeighbour(arena, graph, node, component_start + component_i);
        return;
    }
}

const ViaConnectivityWalk = struct {
    arena: std.mem.Allocator,
    graph: []const std.ArrayList(usize),
    components: Components,
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    support: ViaSupport,
    via_start: usize,
    removed: []const bool,
    seen: []usize,
    queue: std.ArrayList(usize) = .empty,
    /// Copper-locality indexes over the same three feature arrays. They only
    /// narrow which features each endpoint/barrel question has to ask, never
    /// what it asks; see the spatial-index header.
    track_index: *Index,
    terminal_index: *Index,
    via_index: *Index,
    track_boxes: []const Box,
    via_boxes: []const Box,
    /// Two live candidate lists, because an endpoint probe runs INSIDE the
    /// sweep over the barrel's own touching traces.
    outer: std.ArrayList(u32) = .empty,
    inner: std.ArrayList(u32) = .empty,

    fn active(self: ViaConnectivityWalk, vertex: usize) bool {
        if (vertex < self.via_start or vertex >= self.via_start + self.vias.len) return true;
        return !self.removed[vertex - self.via_start];
    }

    fn endSupportedAfterRemoval(self: *ViaConnectivityWalk, track_i: usize, end_i: usize, p: [2]f64) std.mem.Allocator.Error!bool {
        const track = self.tracks[track_i];
        if (track_i < self.support.track_components.len and self.support.track_components[track_i][end_i] != 0)
            return true;
        const probe = pointBox(p, track.width / 2);
        try self.terminal_index.near(self.arena, &self.inner, probe, touch_slack_mm);
        for (self.inner.items) |candidate| {
            const terminal = self.terminals[candidate];
            if (!terminalPointTouch(terminal, p[0], p[1], track.width / 2, track.layer, track.net)) continue;
            if (trackTouchesTerminal(track, terminal)) return true;
        }
        try self.via_index.near(self.arena, &self.inner, probe, touch_slack_mm);
        for (self.inner.items) |candidate| {
            const via_i: usize = candidate;
            const via = self.vias[via_i];
            if (self.removed[via_i] or via.net != track.net) continue;
            if (std.math.hypot(via.at[0] - p[0], via.at[1] - p[1]) >
                via.dia / 2 + track.width / 2 + touch_slack_mm) continue;
            if (trackTouchesVia(track, via)) return true;
        }
        try self.track_index.near(self.arena, &self.inner, probe, touch_slack_mm);
        for (self.inner.items) |candidate| {
            const other_i: usize = candidate;
            const other = self.tracks[other_i];
            if (other_i == track_i or other.net != track.net or other.layer != track.layer) continue;
            if (pad_shape.segPointDist(other.a[0], other.a[1], other.b[0], other.b[1], p[0], p[1]) >
                other.width / 2 + track.width / 2 + touch_slack_mm) continue;
            if (tracksJoinPhysically(track, other)) return true;
        }
        return false;
    }

    /// A via may be a graph leaf without carrying pad-to-pad connectivity, yet
    /// still be the only copper supporting a stored trace endpoint. Removing it
    /// would turn that trace into a new `copper_stub`, so endpoint support is a
    /// second invariant beside component connectivity.
    fn keepsTrackEnds(self: *ViaConnectivityWalk, candidate: usize) std.mem.Allocator.Error!bool {
        const via = self.vias[candidate];
        try self.track_index.near(self.arena, &self.outer, self.via_boxes[candidate], touch_slack_mm);
        // Snapshot: the endpoint probes below query this same index again.
        const touching = try self.arena.dupe(u32, self.outer.items);
        for (touching) |entry| {
            const track_i: usize = entry;
            const track = self.tracks[track_i];
            if (!trackTouchesVia(track, via)) continue;
            for ([_][2]f64{ track.a, track.b }, 0..) |p, end_i| {
                if (std.math.hypot(via.at[0] - p[0], via.at[1] - p[1]) >
                    via.dia / 2 + track.width / 2 + touch_slack_mm) continue;
                if (!try self.endSupportedAfterRemoval(track_i, end_i, p)) return false;
            }
        }
        return true;
    }

    fn redundant(self: *ViaConnectivityWalk, candidate: usize, generation: usize) std.mem.Allocator.Error!bool {
        if (!try self.keepsTrackEnds(candidate)) return false;
        const candidate_node = self.via_start + candidate;
        const component = self.components.id[candidate_node];
        var expected: usize = 0;
        var start: ?usize = null;
        for (self.graph, 0..) |_, vertex| {
            if (vertex == candidate_node or self.components.id[vertex] != component or !self.active(vertex)) continue;
            expected += 1;
            if (start == null) start = vertex;
        }
        if (expected <= 1) return true;

        self.queue.clearRetainingCapacity();
        try self.queue.append(self.arena, start.?);
        self.seen[candidate_node] = generation;
        self.seen[start.?] = generation;
        var reached: usize = 0;
        var head: usize = 0;
        while (head < self.queue.items.len) : (head += 1) {
            const vertex = self.queue.items[head];
            reached += 1;
            for (self.graph[vertex].items) |other| {
                if (!self.active(other) or self.seen[other] == generation) continue;
                self.seen[other] = generation;
                try self.queue.append(self.arena, other);
            }
        }
        return reached == expected;
    }
};

/// Classify vias whose removal leaves every pad, trace, and other via component
/// exactly as connected as before, then derive one jointly safe newest-first
/// deletion plan. `support.candidates` is indexed like `vias`; false entries
/// protect ground, retained scope, and other intentional barrels.
pub fn analyzeViaRedundancy(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    support: ViaSupport,
) std.mem.Allocator.Error!RedundancyAnalysis {
    var indexes = try FeatureIndexes.build(arena, terminals, tracks, vias);
    const graph = try buildViaGraph(arena, terminals, tracks, vias, support, &indexes);
    const components = try graphComponents(arena, graph, tracks.len);
    const removed = try arena.alloc(bool, vias.len);
    @memset(removed, false);
    const individual = try arena.alloc(bool, vias.len);
    const seen = try arena.alloc(usize, graph.len);
    @memset(seen, 0);
    var walk = ViaConnectivityWalk{
        .arena = arena,
        .graph = graph,
        .components = components,
        .terminals = terminals,
        .tracks = tracks,
        .vias = vias,
        .support = support,
        .via_start = tracks.len + terminals.len,
        .removed = removed,
        .seen = seen,
        .track_index = &indexes.track,
        .terminal_index = &indexes.terminal,
        .via_index = &indexes.via,
        .track_boxes = indexes.track_boxes,
        .via_boxes = indexes.via_boxes,
    };
    for (vias, 0..) |via, via_i| {
        const eligible = via.net >= 0 and (support.candidates.len == 0 or
            (via_i < support.candidates.len and support.candidates[via_i]));
        removed[via_i] = eligible;
        individual[via_i] = eligible and try walk.redundant(via_i, via_i + 1);
        removed[via_i] = false;
    }
    const spanning = try arena.alloc(bool, vias.len);
    for (vias, 0..) |_, i| spanning[i] = components.supports[components.id[walk.via_start + i]] > 1;
    var generation: usize = vias.len + 1;
    var via_i = vias.len;
    while (via_i > 0) {
        via_i -= 1;
        const via = vias[via_i];
        const eligible = via.net >= 0 and (support.candidates.len == 0 or
            (via_i < support.candidates.len and support.candidates[via_i]));
        if (!eligible) continue;
        removed[via_i] = true;
        if (!try walk.redundant(via_i, generation)) removed[via_i] = false;
        generation += 1;
    }
    return .{ .individual = individual, .removal = removed, .spanning = spanning };
}

/// Classify every independently redundant section, mark which of those
/// verdicts rest on a real alternate path (`spanning`), and derive a
/// deterministic, jointly safe deletion plan from the same support graph.
pub fn analyzeRedundancy(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    support: BranchSupport,
) std.mem.Allocator.Error!RedundancyAnalysis {
    const pours = try pourKeys(arena, tracks, support);
    const graph = try buildSupportGraph(arena, terminals, tracks, support, pours);
    const components = try graphComponents(arena, graph, tracks.len);
    const members = try componentMembers(arena, components.id);
    const removed = try arena.alloc(bool, tracks.len);
    @memset(removed, false);
    const individual = try arena.alloc(bool, tracks.len);
    var cuts = try Cuts.prepare(arena, graph, tracks.len, removed);
    // A component reaching at most one support answers "redundant" for every
    // section in it without any walk, so only the rest are analysed.
    for (components.first_support, 0..) |first, component| {
        if (component + 1 >= members.starts.len) break;
        if (components.supports[component] <= 1) continue;
        try cuts.analyze(arena, members.of(component), first.?);
    }
    const spanning = try arena.alloc(bool, tracks.len);
    for (tracks, 0..) |track, i| {
        const component = components.id[i];
        individual[i] = track.net >= 0 and
            (components.supports[component] <= 1 or !cuts.separates[i]);
        spanning[i] = components.supports[component] > 1;
    }
    // Sections are considered newest-first so late detours disappear before
    // established trunks. Accepted deletions participate in all later checks —
    // which is exactly when the component's cut analysis has to be redone.
    var i = tracks.len;
    while (i > 0) {
        i -= 1;
        if (tracks[i].net < 0) continue;
        const component = components.id[i];
        if (components.supports[component] <= 1) {
            removed[i] = true;
            continue;
        }
        if (cuts.separates[i]) continue;
        removed[i] = true;
        try cuts.analyze(arena, members.of(component), components.first_support[component].?);
    }
    return .{ .individual = individual, .removal = removed, .spanning = spanning };
}

fn endSupported(
    copper: Copper,
    track_i: usize,
    p: [2]f64,
    pour_layers: u64,
    near: Neighbours,
) bool {
    const terminals = copper.terminals;
    const tracks = copper.tracks;
    const vias = copper.vias;
    const track = tracks[track_i];
    if (pour_layers & layerBit(track.layer) != 0) return true;
    var terminal_it = IdIter.init(near.terminals, terminals.len);
    while (terminal_it.next()) |terminal_i| {
        const terminal = terminals[terminal_i];
        if (!terminalPointTouch(terminal, p[0], p[1], track.width / 2, track.layer, track.net)) continue;
        if (trackTouchesTerminal(track, terminal)) return true;
    }
    var via_it = IdIter.init(near.vias, vias.len);
    while (via_it.next()) |via_i| {
        const via = vias[via_i];
        if (via.net != track.net) continue;
        if (std.math.hypot(via.at[0] - p[0], via.at[1] - p[1]) > via.dia / 2 + track.width / 2 + touch_slack_mm) continue;
        if (trackTouchesVia(track, via)) return true;
    }
    var track_it = IdIter.init(near.tracks, tracks.len);
    while (track_it.next()) |other_i| {
        const other = tracks[other_i];
        if (other_i == track_i or other.net != track.net or other.layer != track.layer) continue;
        if (pad_shape.segPointDist(other.a[0], other.a[1], other.b[0], other.b[1], p[0], p[1]) >
            other.width / 2 + track.width / 2 + touch_slack_mm) continue;
        if (tracksJoinPhysically(track, other)) return true;
    }
    return false;
}

/// Copper layers physically reached by `via`. `pour_layers` is the bitmask of
/// same-net filled regions covering the via coordinate; `plane_contacts` is the
/// count of same-net dedicated planes crossed by its barrel.
pub fn viaUseCount(
    terminals: []const Terminal,
    tracks: []const Track,
    via: Via,
    pour_layers: u64,
    plane_contacts: u8,
) usize {
    return viaUseCountNear(terminals, tracks, via, pour_layers, plane_contacts, .{});
}

/// `viaUseCount` for every barrel at once. One copper-locality index over the
/// traces and lands replaces the per-barrel sweep over both arrays; the layer
/// mask each barrel accumulates is an OR, so a narrowed candidate list gives
/// the identical count.
pub fn viaUseCounts(
    arena: std.mem.Allocator,
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    pour_layers: []const u64,
    plane_contacts: []const u8,
) std.mem.Allocator.Error![]const usize {
    const out = try arena.alloc(usize, vias.len);
    var indexes = try FeatureIndexes.build(arena, terminals, tracks, vias);
    var terminal_ids: std.ArrayList(u32) = .empty;
    var track_ids: std.ArrayList(u32) = .empty;
    for (vias, 0..) |via, via_i| {
        try indexes.terminal.near(arena, &terminal_ids, indexes.via_boxes[via_i], touch_slack_mm);
        try indexes.track.near(arena, &track_ids, indexes.via_boxes[via_i], touch_slack_mm);
        out[via_i] = viaUseCountNear(terminals, tracks, via, pour_layers[via_i], plane_contacts[via_i], .{
            .terminals = terminal_ids.items,
            .tracks = track_ids.items,
        });
    }
    return out;
}

fn viaUseCountNear(
    terminals: []const Terminal,
    tracks: []const Track,
    via: Via,
    pour_layers: u64,
    plane_contacts: u8,
    near: Neighbours,
) usize {
    var layers = pour_layers;
    if (via.net < 0) return @popCount(layers) + plane_contacts;
    var track_it = IdIter.init(near.tracks, tracks.len);
    while (track_it.next()) |track_i| {
        const track = tracks[track_i];
        if (trackTouchesVia(track, via)) layers |= layerBit(track.layer);
    }
    var terminal_it = IdIter.init(near.terminals, terminals.len);
    while (terminal_it.next()) |terminal_i| {
        const terminal = terminals[terminal_i];
        if (terminal.net != via.net) continue;
        if (pad_shape.pointDist(terminal.shape.x0, terminal.shape.y0, terminal.shape.x1, terminal.shape.y1, terminal.shape.poly, via.at[0], via.at[1], std.math.inf(f64)) >
            via.dia / 2 + touch_slack_mm) continue;
        if (terminal.thru) {
            // A via-in-through-pad is already a multi-layer terminal. Keeping
            // it is conservative; duplicate-drill cleanup is a separate rule.
            layers |= 0b11;
        } else {
            layers |= layerBit(terminal.layer);
        }
    }
    return @popCount(layers) + plane_contacts;
}

// spec: placement/copper-topology - a trace end must land on a same-net pad, via, pour, or trace; a free leaf remains loose
test "trace endpoints distinguish real terminals and a dangling leaf" {
    const pads = [_]Terminal{.{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 }};
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 2, 0 }, .b = .{ 3, 0 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    try std.testing.expect(looseEnd(&pads, &tracks, &.{}, 0, .{ 0, 0 }) == null);
    const loose = looseEnd(&pads, &tracks, &.{}, 1, .{ 0, 0 }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3), loose[0], 1e-9);
    try std.testing.expect(looseEnd(&.{}, tracks[1..2], &.{}, 0, .{ 1, 1 }) == null); // same-net pour
    // Copper wholly inside the ONE pad of a one-terminal net is still loose (the
    // finish has always pruned that shape), and `redundantSections` sees the
    // same copper as removable — the general form of it, on any net.
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const pad_only = [_]Track{.{ .a = .{ 0, 0 }, .b = .{ 0.1, 0 }, .layer = 0, .width = 0.2, .net = 0 }};
    try std.testing.expect(looseEnd(&pads, &pad_only, &.{}, 0, .{ 0, 0 }) != null);
    try std.testing.expect((try redundantSections(arena_inst.allocator(), &pads, &pad_only, .{}))[0]);
}

/// A lattice fixture for the shared-index checks: eight nets, each a land, a
/// two-section run to a barrel, a layer jump off that barrel, and one stub that
/// reaches nothing. Neighbouring cells sit close enough that a bucketed query
/// has to keep them apart.
const IndexFixture = struct {
    terminals: []const Terminal,
    tracks: []const Track,
    vias: []const Via,
    pours: []const [2]u64,
    poured: []const u64,
    planes: []const u8,
};

fn indexFixture(arena: std.mem.Allocator) std.mem.Allocator.Error!IndexFixture {
    var terminals: std.ArrayList(Terminal) = .empty;
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    for (0..8) |cell| {
        const net: i32 = @intCast(cell);
        const x0 = @as(f64, @floatFromInt(cell)) * 3.0;
        try terminals.append(arena, .{
            .shape = .{ .x0 = x0 - 0.3, .y0 = -0.3, .x1 = x0 + 0.3, .y1 = 0.3 },
            .net = net,
            .layer = 0,
        });
        try tracks.append(arena, .{ .a = .{ x0, 0 }, .b = .{ x0 + 1, 0 }, .layer = 0, .width = 0.2, .net = net });
        try tracks.append(arena, .{ .a = .{ x0 + 1, 0 }, .b = .{ x0 + 2, 0 }, .layer = 0, .width = 0.2, .net = net });
        try tracks.append(arena, .{ .a = .{ x0, 2 }, .b = .{ x0 + 1, 2 }, .layer = 0, .width = 0.2, .net = net });
        try tracks.append(arena, .{ .a = .{ x0 + 2, 0 }, .b = .{ x0 + 2, 1 }, .layer = 1, .width = 0.2, .net = net });
        try vias.append(arena, .{ .at = .{ x0 + 2, 0 }, .dia = 0.4, .net = net });
    }
    const pours = try arena.alloc([2]u64, tracks.items.len);
    @memset(pours, .{ 0, 0 });
    const poured = try arena.alloc(u64, vias.items.len);
    @memset(poured, 0);
    const planes = try arena.alloc(u8, vias.items.len);
    @memset(planes, 0);
    return .{
        .terminals = terminals.items,
        .tracks = tracks.items,
        .vias = vias.items,
        .pours = pours,
        .poured = poured,
        .planes = planes,
    };
}

/// How many of `ends` name a loose endpoint.
fn looseCount(ends: []const ?[2]f64) usize {
    var found: usize = 0;
    for (ends) |end| {
        if (end != null) found += 1;
    }
    return found;
}

// spec: placement/copper-topology - one shared copper index answers every section's endpoints and every barrel's layer count exactly as the per-feature sweep does
test "the batch endpoint and barrel queries match the per-feature sweep" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const f = try indexFixture(arena);
    const batched = try looseEnds(arena, f.terminals, f.tracks, f.vias, f.pours);
    const counts = try viaUseCounts(arena, f.terminals, f.tracks, f.vias, f.poured, f.planes);
    for (f.tracks, 0..) |_, i| {
        const single = looseEnd(f.terminals, f.tracks, f.vias, i, f.pours[i]);
        try std.testing.expectEqual(single == null, batched[i] == null);
        if (single) |p| {
            try std.testing.expectEqual(p[0], batched[i].?[0]);
            try std.testing.expectEqual(p[1], batched[i].?[1]);
        }
        if (i < f.vias.len) {
            try std.testing.expectEqual(viaUseCount(f.terminals, f.tracks, f.vias[i], 0, 0), counts[i]);
            try std.testing.expectEqual(@as(usize, 2), counts[i]); // both routed layers land on it
        }
    }
    // The fixture has to carry both verdicts or the agreement proves nothing.
    try std.testing.expect(looseCount(batched) > 0 and looseCount(batched) < f.tracks.len);
}

// spec: placement/copper-topology - a redundancy verdict is marked spanning only when the section's component joins more than one support, separating an alternate path from copper that reaches nothing
// spec: placement/copper-topology - a stored trace section is redundant when deleting it preserves the connectivity of every pad, live via, and poured region
test "copper that leaves a land and returns to it carries nothing" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 4.7, .y0 = -0.3, .x1 = 5.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
    };
    // A hook: out of the land by less than a half width and back. Both ends are
    // "supported" by the land, so `looseEnd` sees nothing — and it joins nothing.
    const hook = [_]Track{
        .{ .a = .{ 0.2, 0 }, .b = .{ 0.35, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0.35, 0 }, .b = .{ 0.2, 0.2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    try std.testing.expect(looseEnd(&pads, &hook, &.{}, 0, .{ 0, 0 }) == null);
    const dead = try analyzeRedundancy(arena, &pads, &hook, .{});
    try std.testing.expect(dead.individual[0] and dead.individual[1]);
    // …but the hook reaches only the one land, so nothing about it is an
    // ALTERNATE path. An automatic caller that cannot see fill must leave it.
    try std.testing.expect(!dead.spanning[0] and !dead.spanning[1]);
    // The same shape once it actually goes somewhere: a run to the second pad.
    const run = [_]Track{
        .{ .a = .{ 0.2, 0 }, .b = .{ 0.35, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0.2, 0 }, .b = .{ 4.8, 0 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const live = try analyzeRedundancy(arena, &pads, &run, .{});
    // The first short section is still wholly bypassed by pad 1; the long
    // section is the only connection to pad 2 and therefore remains essential.
    try std.testing.expect(live.individual[0] and !live.individual[1]);
    // Both now sit on a component joining both lands, so the verdict on the
    // short one is a genuine "the board has another way there".
    try std.testing.expect(live.spanning[0] and live.spanning[1]);
}

// spec: placement/copper-topology - separate fabricated fill components on one net and layer never form an alternate route for redundancy deletion
test "split pour components cannot make a direct route redundant" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 4.7, .y0 = -0.3, .x1 = 5.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
    };
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 5, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0, 0 }, .b = .{ 0, 2 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 5, 0 }, .b = .{ 5, 2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const layers = [_][2]u64{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 1 } };
    const split = [_][2]u64{ .{ 0, 0 }, .{ 0, 101 }, .{ 0, 202 } };
    const split_result = try redundantSections(arena, &pads, &tracks, .{
        .pour_layers = &layers,
        .pour_components = &split,
    });
    try std.testing.expect(!split_result[0]);

    const joined = [_][2]u64{ .{ 0, 0 }, .{ 0, 101 }, .{ 0, 101 } };
    const joined_result = try redundantSections(arena, &pads, &tracks, .{
        .pour_layers = &layers,
        .pour_components = &joined,
    });
    try std.testing.expect(joined_result[0]);
}

// spec: placement/copper-topology - a redundant-section removal plan considers newest copper first and preserves support connectivity after all planned deletions are applied together
test "alternate route sections are redundant while an anchored tee survives" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 4.7, .y0 = -0.3, .x1 = 5.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 2.7, .y0 = 1.7, .x1 = 3.3, .y1 = 2.3 }, .net = 0, .layer = 0 },
    };
    const tracks = [_]Track{
        // Direct pad-to-pad trunk plus a two-section alternate path. Deleting
        // any one of these three sections leaves both pads connected.
        .{ .a = .{ 0, 0 }, .b = .{ 5, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0, 0 }, .b = .{ 2.5, 1 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 2.5, 1 }, .b = .{ 5, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        // A real tee from the trunk to a third pad must remain useful.
        .{ .a = .{ 0, 0 }, .b = .{ 3, 2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const redundant = try redundantSections(arena, &pads, &tracks, .{});
    try std.testing.expect(redundant[0] and redundant[1] and redundant[2]);
    try std.testing.expect(!redundant[3]);
    const removal = (try analyzeRedundancy(arena, &pads, &tracks, .{})).removal;
    try std.testing.expect(!removal[0] and removal[1] and removal[2] and !removal[3]);

    const retained = [_]Track{ tracks[0], tracks[3] };
    const after = try redundantSections(arena, &pads, &retained, .{});
    try std.testing.expect(!after[0] and !after[1]);
}

// spec: placement/copper-topology - physical same-net contact does not join route topology unless an endpoint lands on the other centreline
test "mid-span trace crossing is reported as an implicit junction" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -2.3, .y0 = -0.3, .x1 = -1.7, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = -0.3, .y0 = -2.3, .x1 = 0.3, .y1 = -1.7 }, .net = 0, .layer = 0 },
    };
    const tracks = [_]Track{
        .{ .a = .{ -2, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0, -2 }, .b = .{ 0, 2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const redundant = try redundantSections(arena_inst.allocator(), &pads, &tracks, .{});
    try std.testing.expect(!redundant[0] and !redundant[1]);
    const implicit = try implicitJoins(arena_inst.allocator(), &tracks);
    try std.testing.expectEqual(@as(usize, 1), implicit.len);
    try std.testing.expectEqual(@as(usize, 0), implicit[0].a);
    try std.testing.expectEqual(@as(usize, 1), implicit[0].b);

    // A serialized T is explicit even when the through-line is one section.
    const tee = [_]Track{
        tracks[0],
        .{ .a = .{ 0, 0 }, .b = .{ 0, 2 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    try std.testing.expect(tracksJoinExplicitly(tee[0], tee[1]));
    try std.testing.expectEqual(@as(usize, 0), (try implicitJoins(arena_inst.allocator(), &tee)).len);
}

// spec: placement/copper-topology - overlapping round caps remain electrically open until a real centreline bridge gives them a full-width junction
test "wide trace caps cannot hide an open route junction" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 1.05, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    try std.testing.expect(tracksOverlapGeometrically(tracks[0], tracks[1]));
    try std.testing.expect(!tracksJoinPhysically(tracks[0], tracks[1]));
    try std.testing.expect(!tracksJoinExplicitly(tracks[0], tracks[1]));
    try std.testing.expect(looseEnd(&.{}, &tracks, &.{}, 0, .{ 1, 0 }) != null);
    try std.testing.expectEqual(@as(usize, 0), (try implicitJoins(arena_inst.allocator(), &tracks)).len);
    try std.testing.expectEqual(@as(usize, 1), (try repairableJoins(arena_inst.allocator(), &tracks)).len);
}

// spec: placement/copper-topology - a trace crossing a same-net land at mid-span electrically supports that land
test "mid-span pad contact keeps a load-bearing trace" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const pads = [_]Terminal{
        .{ .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
        .{ .shape = .{ .x0 = 1.7, .y0 = -0.3, .x1 = 2.3, .y1 = 0.3 }, .net = 0, .layer = 0 },
    };
    const tracks = [_]Track{.{ .a = .{ -1, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 }};
    const redundant = try redundantSections(arena_inst.allocator(), &pads, &tracks, .{});
    try std.testing.expect(!redundant[0]);
}

// spec: placement/copper-topology - a via used by one routed layer is dangling while a second layer, pad, pour, or plane makes it useful
test "via use counts distinct copper layers" {
    const via = Via{ .at = .{ 0, 0 }, .dia = 0.5, .net = 0 };
    const top = [_]Track{.{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 }};
    try std.testing.expectEqual(@as(usize, 1), viaUseCount(&.{}, &top, via, 0, 0));
    const both = [_]Track{
        top[0],
        .{ .a = .{ 0, 0 }, .b = .{ 0, 2 }, .layer = 1, .width = 0.2, .net = 0 },
    };
    try std.testing.expectEqual(@as(usize, 2), viaUseCount(&.{}, &both, via, 0, 0));
    try std.testing.expectEqual(@as(usize, 2), viaUseCount(&.{}, &top, via, 0, 1));
}

// spec: placement/copper-topology - redundant-via pruning preserves every persistent copper component and chooses a jointly safe subset of parallel layer jumps
test "via redundancy keeps one of two parallel layer jumps" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]Via{
        .{ .at = .{ 0.5, 0 }, .dia = 0.4, .net = 0 },
        .{ .at = .{ 1.5, 0 }, .dia = 0.4, .net = 0 },
    };
    const analysis = try analyzeViaRedundancy(arena_inst.allocator(), &.{}, &tracks, &vias, .{});
    try std.testing.expect(analysis.individual[0] and analysis.individual[1]);
    try std.testing.expectEqual(@as(usize, 1), @as(usize, @intFromBool(analysis.removal[0])) + @intFromBool(analysis.removal[1]));
    try std.testing.expect(!analysis.removal[0] and analysis.removal[1]);
}

// spec: placement/copper-topology - a via that is the only robust bridge between persistent copper features is never deletion-invariant
test "via redundancy retains an articulation and honors protection" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const tracks = [_]Track{
        .{ .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .width = 0.2, .net = 0 },
        .{ .a = .{ 1, 0 }, .b = .{ 2, 0 }, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]Via{.{ .at = .{ 1, 0 }, .dia = 0.4, .net = 0 }};
    const essential = try analyzeViaRedundancy(arena_inst.allocator(), &.{}, &tracks, &vias, .{});
    try std.testing.expect(!essential.individual[0]);
    try std.testing.expect(!essential.removal[0]);

    const isolated = [_]Via{.{ .at = .{ 4, 0 }, .dia = 0.4, .net = 0 }};
    const protected = [_]bool{false};
    const protected_analysis = try analyzeViaRedundancy(arena_inst.allocator(), &.{}, &tracks, &isolated, .{ .candidates = &protected });
    try std.testing.expect(!protected_analysis.individual[0]);
    try std.testing.expect(!protected_analysis.removal[0]);
}

// spec: placement/copper-topology - a via that is the sole support for a trace endpoint remains even when deleting its graph leaf would not split a component
test "via redundancy preserves trace endpoint support" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const pads = [_]Terminal{.{
        .shape = .{ .x0 = -0.3, .y0 = -0.3, .x1 = 0.3, .y1 = 0.3 },
        .net = 0,
        .layer = 0,
    }};
    const tracks = [_]Track{.{ .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .width = 0.2, .net = 0 }};
    const vias = [_]Via{.{ .at = .{ 2, 0 }, .dia = 0.4, .net = 0 }};
    const analysis = try analyzeViaRedundancy(arena_inst.allocator(), &pads, &tracks, &vias, .{});
    try std.testing.expect(!analysis.individual[0]);
    try std.testing.expect(!analysis.removal[0]);
}
