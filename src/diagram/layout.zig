//! Layered (Sugiyama-style) auto-layout for one diagram view.
//!
//! Pipeline: filter edges to the view → break cycles (DFS back-edge reversal)
//! → longest-path layering (columns left→right by signal flow) → median
//! crossing-reduction within each layer → coordinate assignment → orthogonal
//! routing through per-channel lanes. Long edges get *dummy* vertices at each
//! intermediate rank so their horizontal runs sit in a free row and never
//! cross a node body. Everything is allocated in the caller-supplied arena.
//!
//! The power view is the exception: it uses `powerLayout`, a left→right supply
//! tree — source (battery/mezzanine) → regulators → one load bucket per rail —
//! ranked by feed depth, with cascade LDOs hidden and fed from their parent.

const std = @import("std");
const types = @import("types.zig");
const env_mod = @import("../eval/env.zig");

const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const ClassId = types.ClassId;
const Pt = types.Pt;

// ── geometry (shared with render.zig) ──────────────────────────────────
// Boxes are wide + tall enough to carry a title plus a two-line wrapped
// description (what the hardware *is*), so a block reads without a tooltip.
pub const node_w: f64 = 300;
pub const node_h: f64 = 84;
pub const h_gap: f64 = 132;
pub const v_gap: f64 = 34;
pub const pad: f64 = 20;
pub const dummy_h: f64 = 14;
/// Vertical room reserved above the columns for the System view's functional
/// band headers ("Power In", "Core", …). Internal to the System layout.
const band_h: f64 = 46;
/// Row spacing for the free (Mermaid-style) Layout view. Looser than the column
/// views' `v_gap` so above/below stacks read as deliberate vertical steps.
const free_v_gap: f64 = 60;
/// Column gap between independent `(anchor …)` roots in the free layout, so two
/// unrelated placement trees don't collide. Wide enough to clear a few cells.
const anchor_col_stride: i32 = 6;

/// A placed real node: its global graph id and top-left corner (width/height
/// are the module `node_w`/`node_h` constants).
pub const LNode = struct { gid: u32, x: f64, y: f64 };

/// One routed edge: the orthogonal polyline `pts` plus the metadata the
/// renderer needs for its label and arrowhead.
pub const Route = struct {
    from_gid: u32,
    to_gid: u32,
    class: ClassId,
    label: []const u8,
    voltage: ?f64,
    fanout: u16,
    pts: []Pt,
    /// True when the logical arrow points at the *first* point (the edge was a
    /// reversed back-edge, so `to` sits on the lower-rank side).
    arrow_at_start: bool,
};

/// Kind of box in the power view's supply tree.
pub const PowerKind = enum { source, regulator, bucket };

/// A box in the power view. `source`/`regulator` boxes wrap one graph node
/// (`gid`); a `bucket` groups every consumer of rail `v` (its node ids in
/// `members`, listed as pills). `v` is the regulator's output rail / the
/// bucket's rail voltage (NaN ⇒ none).
pub const PowerBox = struct {
    kind: PowerKind,
    gid: u32 = 0,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    v: f64 = std.math.nan(f64),
    members: []const u32 = &.{},
};

/// A laid-out view: placed real nodes, routed edges, the SVG canvas size, and
/// (power view only) the supply-tree boxes (source / regulators / load buckets).
pub const Layout = struct {
    nodes: []LNode,
    routes: []Route,
    width: f64,
    height: f64,
    power_boxes: []const PowerBox = &.{},
    /// System view only: one functional-region label per column (indexed by
    /// rank), drawn as a band header above the diagram. Empty for the focused
    /// per-class views, which have no functional banding.
    stage_labels: []const []const u8 = &.{},
};

const Vertex = struct {
    is_dummy: bool,
    gid: u32,
    rank: u32,
    h: f64,
    y: f64 = 0,
};

const RawEdge = struct { from_l: u32, to_l: u32, eidx: usize };
const Chain = struct { verts: []u32, eidx: usize, arrow_at_start: bool };

/// Compute the layout for `view`. Returns `null` when the view has no edges.
/// The power view uses a dedicated voltage-band layout (`powerLayout`); the
/// other views use the layered/Sugiyama pipeline below.
pub fn computeLayout(arena: Allocator, graph: *const Graph, view: ClassId) Allocator.Error!?Layout {
    if (view == types.CLASS_POWER) return powerLayout(arena, graph);

    // Filter edges to this view + collect participating nodes.
    var local_of = std.AutoHashMapUnmanaged(u32, u32){};
    var gids: std.ArrayListUnmanaged(u32) = .empty;
    var raw: std.ArrayListUnmanaged(RawEdge) = .empty;
    for (graph.edges, 0..) |e, eidx| {
        if (e.class != view) continue;
        const fl = try internNode(arena, &local_of, &gids, e.from);
        const tl = try internNode(arena, &local_of, &gids, e.to);
        if (fl == tl) continue;
        try raw.append(arena, .{ .from_l = fl, .to_l = tl, .eidx = eidx });
    }
    if (raw.items.len == 0) return null;
    return try layeredLayout(arena, graph, gids.items, raw.items, null);
}

/// True for a real on-page block (it has a card slug). Synthesised endpoints
/// (antennas / crystals) carry no slug; they still join the System view when
/// an edge reaches them, but never seed it as isolated boxes.
fn isBlock(n: types.Node) bool {
    return n.slug.len > 0 and !n.is_boundary;
}

/// True when the combined System view has anything to draw — any inter-block
/// edge, or (failing that) any real block to show as a box.
pub fn hasSystemView(graph: *const Graph) bool {
    if (graph.edges.len > 0) return true;
    for (graph.nodes) |n| if (isBlock(n)) return true;
    return false;
}

// ── System view: functional-flow staging ────────────────────────────────
//
// The combined System view does not rank by raw signal flow (which, on a
// partial design, scatters blocks by whatever happens to be wired). Instead it
// places every block into a fixed *functional stage* and flows the stages
// left→right, so the diagram reads as an architecture: power on the left feeds
// the compute core, which fans out to peripherals and I/O on the right.

/// Functional stages, in left→right order. A block's column is its stage; the
/// header above the column is the matching label. Unused stages are compacted
/// out so a design with no power blocks (or no MCU) shows no empty column.
const StageLabel = struct { idx: u8, label: []const u8 };
const stages = [_]StageLabel{
    .{ .idx = 0, .label = "Power" },
    .{ .idx = 1, .label = "Core" },
    .{ .idx = 2, .label = "Peripherals & I/O" },
};

/// Place one block into a functional stage from its declared category:
///   - power delivery (sources, regulators, converters — `category == .power`)
///     → Power, the left band;
///   - the compute cluster (MCU + its crystal + boot memory) → Core;
///   - everything else (comms, sensors, analog, connectors, protection) → I/O.
/// Category alone is used (not power-port direction): on a partial design a
/// source and a regulator carry indistinguishable port sets, and the user's
/// mental model groups all power delivery into one region anyway.
fn systemStage(n: types.Node) u8 {
    if (n.category == .power) return 0;
    return switch (n.category) {
        .mcu, .clock, .memory => 1,
        else => 2,
    };
}

/// The combined **System** view: one block diagram over *every* signal class at
/// once (each edge keeps its own class, so the renderer can color it), laid out
/// by functional stage (`systemStage`) rather than raw signal flow. Shows every
/// block that participates in a connection; when the design has no inter-block
/// edge at all, it falls back to the real blocks as isolated boxes so the view
/// isn't blank. Returns null only when there is nothing to draw.
pub fn computeSystemLayout(arena: Allocator, graph: *const Graph) Allocator.Error!?Layout {
    var local_of = std.AutoHashMapUnmanaged(u32, u32){};
    var gids: std.ArrayListUnmanaged(u32) = .empty;
    var raw: std.ArrayListUnmanaged(RawEdge) = .empty;
    for (graph.edges, 0..) |e, eidx| {
        const fl = try internNode(arena, &local_of, &gids, e.from);
        const tl = try internNode(arena, &local_of, &gids, e.to);
        if (fl == tl) continue;
        try raw.append(arena, .{ .from_l = fl, .to_l = tl, .eidx = eidx });
    }
    // A declared function box is shown even with no edges (force_show), so an
    // author-declared subsystem appears whether or not its parts are wired yet.
    for (graph.nodes, 0..) |n, i| {
        if (n.force_show) _ = try internNode(arena, &local_of, &gids, @intCast(i));
    }
    if (gids.items.len == 0) {
        for (graph.nodes, 0..) |n, i| {
            if (isBlock(n)) _ = try internNode(arena, &local_of, &gids, @intCast(i));
        }
        if (gids.items.len == 0) return null;
    }

    // Stage each block, then compact the *used* stages to consecutive columns
    // (rank) so empty stages leave no gap. `col_label[rank]` is that column's
    // band header.
    var used = [_]bool{false} ** stages.len;
    const raw_stage = try arena.alloc(u8, gids.items.len);
    for (gids.items, 0..) |gid, i| {
        raw_stage[i] = systemStage(graph.nodes[gid]);
        used[raw_stage[i]] = true;
    }
    var col_of_stage = [_]u32{0} ** stages.len;
    var col_label: std.ArrayListUnmanaged([]const u8) = .empty;
    var ncols: u32 = 0;
    for (stages) |s| {
        if (!used[s.idx]) continue;
        col_of_stage[s.idx] = ncols;
        ncols += 1;
        try col_label.append(arena, s.label);
    }
    const ranks = try arena.alloc(u32, gids.items.len);
    for (raw_stage, 0..) |s, i| ranks[i] = col_of_stage[s];

    var lay = try layeredLayout(arena, graph, gids.items, raw.items, ranks);
    // The layered pipeline ordered the columns well, but its left→right lane
    // routing loops same-column edges and crosses boxes on long hops. Re-route
    // every edge from the side of its source nearest the target (`routeSystemEdges`).
    lay.routes = try routeSystemEdges(arena, graph, lay.nodes, lay.height);
    // Reserve a header strip above the columns and hang the band labels off it.
    for (lay.nodes) |*n| n.y += band_h;
    for (lay.routes) |r| for (r.pts) |*p| {
        p.y += band_h;
    };
    lay.height += band_h;
    lay.stage_labels = try col_label.toOwnedSlice(arena);
    return lay;
}

// ── Free (Mermaid-style) layout: relative `(place …)` directives ─────────
//
// The author positions blocks relative to one another with `(layout (anchor
// "a") (place "b" (right-of "a")) …)`. We resolve each block to an absolute
// grid cell (col, row) in dependency order — an anchor at (0,0), and each
// placed block one cell off its reference's cell — then convert cells to x,y
// with the same box+gap spacing the column views use. Blocks the author didn't
// place (and ones whose reference is missing or cyclic) flow into a fallback
// row beneath the placed cluster, so nothing silently disappears.

/// True when the design declared a `(layout …)` with at least one placement —
/// gates whether the **Layout** tab renders.
pub fn hasFreeLayout(graph: *const Graph) bool {
    return graph.layout.placements.len > 0;
}

const Cell = struct { col: i32, row: i32 };

/// Resolve `(place …)` directives into absolute cells. `cell_of[i]` is node i's
/// cell once resolved; `placed[i]` marks it. Iterates to a fixed point so a
/// directive whose reference resolves later still lands (bounded by placement
/// count, which also breaks cycles). A directive naming an unknown block, or
/// one stuck in a cycle, simply never resolves → caller flows it into the
/// fallback row.
fn resolvePlacements(
    graph: *const Graph,
    cell_of: []Cell,
    placed: []bool,
) void {
    const ps = graph.layout.placements;
    // Anchors first: each is its own root at a distinct column so independent
    // trees don't overlap.
    var next_anchor_col: i32 = 0;
    for (ps) |p| {
        if (p.rel != .anchor) continue;
        const gi = nodeByKey(graph, p.name) orelse continue;
        if (placed[gi]) continue;
        cell_of[gi] = .{ .col = next_anchor_col, .row = 0 };
        placed[gi] = true;
        next_anchor_col += anchor_col_stride;
    }
    // Relative placements: sweep until no further progress (≤ placements.len
    // passes resolves any acyclic chain; a cycle just stops making progress).
    var pass: usize = 0;
    while (pass <= ps.len) : (pass += 1) {
        var progressed = false;
        for (ps) |p| {
            if (p.rel == .anchor) continue;
            const gi = nodeByKey(graph, p.name) orelse continue;
            if (placed[gi]) continue;
            const ri = nodeByKey(graph, p.reference) orelse continue;
            if (!placed[ri]) continue;
            cell_of[gi] = offsetCell(cell_of[ri], p.rel);
            placed[gi] = true;
            progressed = true;
        }
        if (!progressed) break;
    }
}

/// Offset a reference cell by one step in the directive's direction.
fn offsetCell(ref: Cell, rel: env_mod.PlaceRel) Cell {
    return switch (rel) {
        .right_of => .{ .col = ref.col + 1, .row = ref.row },
        .left_of => .{ .col = ref.col - 1, .row = ref.row },
        .above => .{ .col = ref.col, .row = ref.row - 1 },
        .below => .{ .col = ref.col, .row = ref.row + 1 },
        .anchor => ref,
    };
}

/// First graph node whose authoring `key` equals `name`, or null. Placeable
/// nodes (sections, sub-blocks, stubs) carry a key; synthesised ones don't.
fn nodeByKey(graph: *const Graph, name: []const u8) ?u32 {
    for (graph.nodes, 0..) |nd, i| {
        if (nd.key.len > 0 and std.mem.eql(u8, nd.key, name)) return @intCast(i);
    }
    return null;
}

/// The free **Layout** view: place blocks at the cells their `(place …)`
/// directives imply, convert to pixels, route edges face-to-face, and flow any
/// un-placed block into a row below. Returns null when no `(layout …)` was
/// declared or there are no placeable blocks.
pub fn computeFreeLayout(arena: Allocator, graph: *const Graph) Allocator.Error!?Layout {
    if (graph.layout.placements.len == 0) return null;
    const n = graph.nodes.len;
    const cell_of = try arena.alloc(Cell, n);
    const placed = try arena.alloc(bool, n);
    @memset(placed, false);
    resolvePlacements(graph, cell_of, placed);

    // Normalise placed cells so the minimum col/row is 0 (anchors/left-of can
    // go negative), then find the fallback row (one below the lowest placed).
    var min_col: i32 = std.math.maxInt(i32);
    var min_row: i32 = std.math.maxInt(i32);
    var max_row: i32 = std.math.minInt(i32);
    var any_placed = false;
    for (graph.nodes, 0..) |_, i| {
        if (!placed[i]) continue;
        any_placed = true;
        min_col = @min(min_col, cell_of[i].col);
        min_row = @min(min_row, cell_of[i].row);
        max_row = @max(max_row, cell_of[i].row);
    }
    if (!any_placed) {
        min_col = 0;
        min_row = 0;
        max_row = -1; // fallback row becomes 0
    }

    // Lay out: placed nodes at their normalised cell; un-placed (and un-keyed
    // real) blocks flow left-to-right along the fallback row beneath them.
    var lnodes: std.ArrayListUnmanaged(LNode) = .empty;
    const fallback_row = max_row - min_row + 1;
    var fallback_col: i32 = 0;
    var max_x: f64 = 0;
    var max_y: f64 = 0;
    for (graph.nodes, 0..) |nd, i| {
        if (!isBlock(nd) and nd.key.len == 0) continue; // skip antennas etc.
        var col: i32 = undefined;
        var row: i32 = undefined;
        if (placed[i]) {
            col = cell_of[i].col - min_col;
            row = cell_of[i].row - min_row;
        } else {
            col = fallback_col;
            row = fallback_row;
            fallback_col += 1;
        }
        const x = pad + @as(f64, @floatFromInt(col)) * (node_w + h_gap);
        const y = pad + @as(f64, @floatFromInt(row)) * (node_h + free_v_gap);
        try lnodes.append(arena, .{ .gid = @intCast(i), .x = x, .y = y });
        max_x = @max(max_x, x + node_w);
        max_y = @max(max_y, y + node_h);
    }
    if (lnodes.items.len == 0) return null;

    const nodes = try lnodes.toOwnedSlice(arena);
    const routes = try routeFreeEdges(arena, graph, nodes);
    return .{
        .nodes = nodes,
        .routes = routes,
        .width = max_x + pad,
        .height = max_y + pad,
    };
}

/// Route every edge whose endpoints are both placed as a simple face-to-face
/// connection: exit the source on the side facing the target, enter the target
/// on its facing side. No lane packing — the free view trusts the author's
/// placement, so a short two-point stub per edge keeps it legible.
fn routeFreeEdges(arena: Allocator, graph: *const Graph, nodes: []const LNode) Allocator.Error![]Route {
    const n = graph.nodes.len;
    const present = try arena.alloc(bool, n);
    @memset(present, false);
    const px = try arena.alloc(f64, n);
    const py = try arena.alloc(f64, n);
    for (nodes) |ln| {
        present[ln.gid] = true;
        px[ln.gid] = ln.x;
        py[ln.gid] = ln.y;
    }
    var routes: std.ArrayListUnmanaged(Route) = .empty;
    for (graph.edges) |e| {
        if (e.from == e.to) continue;
        if (!present[e.from] or !present[e.to]) continue;
        const a = boxCenter(px[e.from], py[e.from]);
        const b = boxCenter(px[e.to], py[e.to]);
        // Attach on the dominant axis: horizontal if the boxes are further apart
        // in x than y, else vertical. Endpoints sit on the facing faces.
        const dx = b.x - a.x;
        const dy = b.y - a.y;
        var sp: Pt = undefined;
        var tp: Pt = undefined;
        if (@abs(dx) >= @abs(dy)) {
            sp = portPoint(px[e.from], py[e.from], if (dx >= 0) side_r else side_l, 0.5);
            tp = portPoint(px[e.to], py[e.to], if (dx >= 0) side_l else side_r, 0.5);
        } else {
            sp = portPoint(px[e.from], py[e.from], if (dy >= 0) side_b else side_t, 0.5);
            tp = portPoint(px[e.to], py[e.to], if (dy >= 0) side_t else side_b, 0.5);
        }
        const pts = try arena.alloc(Pt, 2);
        pts[0] = sp;
        pts[1] = tp;
        try routes.append(arena, .{
            .from_gid = e.from,
            .to_gid = e.to,
            .class = e.class,
            .label = e.label,
            .voltage = e.voltage,
            .fanout = e.fanout,
            .pts = pts,
            .arrow_at_start = false,
        });
    }
    return routes.toOwnedSlice(arena);
}

fn boxCenter(x: f64, y: f64) Pt {
    return .{ .x = x + node_w / 2, .y = y + node_h / 2 };
}

// ── System view: side-aware orthogonal edge routing ─────────────────────
//
// The stage layout fixes each block's column, so connected blocks routinely sit
// in the *same* column (a rail above its PSU) or several columns apart (power
// feeding a far peripheral). A single right→left anchor then loops a same-column
// edge out into the gap and back, or drags a long hop straight across the boxes
// between its endpoints. Instead, attach each edge to the face of its source
// nearest the target and the matching face of the target:
//   - same column      → exit bottom/top into the facing top/bottom (a short
//     vertical); if a block sits between them, hop into the right-hand gap lane
//     and back (a ⊐) so nothing is crossed;
//   - adjacent columns → exit right/left, one jog in the gap, enter the facing side;
//   - columns apart     → exit into the first gap, cross in a *free* horizontal
//     band (clear of every block in the columns between), drop into the gap
//     before the target, enter its facing side.
// Ports fan out along each face so edges sharing a side read as a comb.

// Which face of a box an edge attaches to.
const side_r: u8 = 0;
const side_l: u8 = 1;
const side_t: u8 = 2;
const side_b: u8 = 3;

/// One placed edge resolved to its attachment geometry: endpoint graph ids, the
/// face each end attaches to, and the columns the two endpoints sit in.
const SideEdge = struct { eidx: usize, from: u32, to: u32, ss: u8, ts: u8, cs: u32, ct: u32 };

fn colLeftX(col: u32) f64 {
    return pad + @as(f64, @floatFromInt(col)) * (node_w + h_gap);
}
fn colRightX(col: u32) f64 {
    return colLeftX(col) + node_w;
}
fn colOf(x: f64) u32 {
    return @intFromFloat(@round((x - pad) / (node_w + h_gap)));
}
fn absDiff(a: u32, b: u32) u32 {
    return if (a > b) a - b else b - a;
}

/// A port point on the box with top-left `(bx,by)`: `side` picks the face,
/// `frac` the position along it (so a fanned bundle spreads instead of stacking).
fn portPoint(bx: f64, by: f64, side: u8, frac: f64) Pt {
    if (side == side_r) return .{ .x = bx + node_w, .y = by + frac * node_h };
    if (side == side_l) return .{ .x = bx, .y = by + frac * node_h };
    if (side == side_t) return .{ .x = bx + frac * node_w, .y = by };
    return .{ .x = bx + frac * node_w, .y = by + node_h };
}

fn portFrac(idx: u16, cnt: u16) f64 {
    return (@as(f64, @floatFromInt(idx)) + 1) / (@as(f64, @floatFromInt(cnt)) + 1);
}

/// True when another box in the same column sits vertically between the two
/// box tops `fy`/`ty` — so a straight vertical edge between them would cross it.
fn blockedVert(tops: []const f64, fy: f64, ty: f64) bool {
    const lo = @min(fy, ty);
    const hi = @max(fy, ty);
    for (tops) |o| if (o > lo + 1 and o < hi - 1) return true;
    return false;
}

/// True when horizontal line `y` would clip any box in columns `lo_col..hi_col`
/// (a small margin keeps the run off box edges).
fn bandBlocked(col_tops: []const std.ArrayListUnmanaged(f64), lo_col: u32, hi_col: u32, y: f64) bool {
    var c = lo_col;
    while (c <= hi_col) : (c += 1) {
        for (col_tops[c].items) |t| if (y > t - band_clear and y < t + node_h + band_clear) return true;
    }
    return false;
}

const band_clear: f64 = 14; // vertical margin a cross-column run keeps off a box

/// A horizontal-run y clear of every box in the spanned middle columns, as close
/// to `preferred` as possible (so a long edge crosses through a gap between
/// block rows, not over them). Falls back to `preferred` if nothing is free.
fn freeBandY(col_tops: []const std.ArrayListUnmanaged(f64), lo_col: u32, hi_col: u32, preferred: f64, lo: f64, hi: f64) f64 {
    if (!bandBlocked(col_tops, lo_col, hi_col, preferred)) return preferred;
    var d: f64 = 10;
    while (d < hi - lo) : (d += 10) {
        const dn = preferred + d;
        const up = preferred - d;
        if (dn <= hi and !bandBlocked(col_tops, lo_col, hi_col, dn)) return dn;
        if (up >= lo and !bandBlocked(col_tops, lo_col, hi_col, up)) return up;
    }
    return preferred;
}

/// Build the orthogonal polyline for one resolved edge: vertical for a
/// same-column hop, a single gap jog for adjacent columns, a free-band staircase
/// for columns apart. `content_h` bounds the free-band search.
fn buildSidePts(arena: Allocator, col_tops: []const std.ArrayListUnmanaged(f64), se: SideEdge, sp: Pt, tp: Pt, content_h: f64) Allocator.Error![]Pt {
    var pts: std.ArrayListUnmanaged(Pt) = .empty;
    try pts.append(arena, sp);
    if (se.cs == se.ct) {
        if (se.ss == side_r) {
            // Blocked vertical: ⊐ out into the right-hand gap and back.
            const lanex = colRightX(se.cs) + h_gap * 0.45;
            try pts.append(arena, .{ .x = lanex, .y = sp.y });
            try pts.append(arena, .{ .x = lanex, .y = tp.y });
        } else {
            const midy = (sp.y + tp.y) / 2;
            try pts.append(arena, .{ .x = sp.x, .y = midy });
            try pts.append(arena, .{ .x = tp.x, .y = midy });
        }
    } else if (absDiff(se.cs, se.ct) == 1) {
        const jx = (sp.x + tp.x) / 2;
        try pts.append(arena, .{ .x = jx, .y = sp.y });
        try pts.append(arena, .{ .x = jx, .y = tp.y });
    } else {
        const right = se.ct > se.cs;
        const jx1 = if (right) colRightX(se.cs) + h_gap * 0.5 else colLeftX(se.cs) - h_gap * 0.5;
        const jx2 = if (right) colLeftX(se.ct) - h_gap * 0.5 else colRightX(se.ct) + h_gap * 0.5;
        const lo_col = @min(se.cs, se.ct) + 1;
        const hi_col = @max(se.cs, se.ct) - 1;
        const band = freeBandY(col_tops, lo_col, hi_col, tp.y, pad, content_h - pad);
        try pts.append(arena, .{ .x = jx1, .y = sp.y });
        try pts.append(arena, .{ .x = jx1, .y = band });
        try pts.append(arena, .{ .x = jx2, .y = band });
        try pts.append(arena, .{ .x = jx2, .y = tp.y });
    }
    try pts.append(arena, tp);
    return pts.toOwnedSlice(arena);
}

/// Re-route every System/Function edge from the box face nearest its target
/// (see the section header above). Replaces the layered pipeline's left→right
/// lane routes with side-aware orthogonal paths over the final box geometry.
fn routeSystemEdges(arena: Allocator, graph: *const Graph, nodes: []const LNode, content_h: f64) Allocator.Error![]Route {
    const n = graph.nodes.len;
    const present = try arena.alloc(bool, n);
    @memset(present, false);
    const nx = try arena.alloc(f64, n);
    const ny = try arena.alloc(f64, n);
    var maxcol: u32 = 0;
    for (nodes) |ln| {
        present[ln.gid] = true;
        nx[ln.gid] = ln.x;
        ny[ln.gid] = ln.y;
        maxcol = @max(maxcol, colOf(ln.x));
    }
    const col_tops = try arena.alloc(std.ArrayListUnmanaged(f64), maxcol + 1);
    for (col_tops) |*c| c.* = .empty;
    for (nodes) |ln| try col_tops[colOf(ln.x)].append(arena, ln.y);

    // Pass 1: resolve each placed edge to its attachment faces and tally the
    // per-(box,face) fanout so the ports can spread.
    var edges_l: std.ArrayListUnmanaged(SideEdge) = .empty;
    const side_n = try arena.alloc(u16, n * 4);
    @memset(side_n, 0);
    for (graph.edges, 0..) |e, eidx| {
        if (e.from == e.to) continue;
        if (!present[e.from] or !present[e.to]) continue;
        const cs = colOf(nx[e.from]);
        const ct = colOf(nx[e.to]);
        var ss: u8 = side_r;
        var ts: u8 = side_l;
        if (cs == ct) {
            if (blockedVert(col_tops[cs].items, ny[e.from], ny[e.to])) {
                ss = side_r;
                ts = side_r;
            } else {
                const down = ny[e.to] > ny[e.from];
                ss = if (down) side_b else side_t;
                ts = if (down) side_t else side_b;
            }
        } else if (ct < cs) {
            ss = side_l;
            ts = side_r;
        }
        try edges_l.append(arena, .{ .eidx = eidx, .from = e.from, .to = e.to, .ss = ss, .ts = ts, .cs = cs, .ct = ct });
        side_n[e.from * 4 + ss] += 1;
        side_n[e.to * 4 + ts] += 1;
    }

    // Pass 2: build the routed polyline for each, spreading ports by face index.
    const side_i = try arena.alloc(u16, n * 4);
    @memset(side_i, 0);
    const routes = try arena.alloc(Route, edges_l.items.len);
    for (edges_l.items, 0..) |se, ri| {
        const sk = se.from * 4 + se.ss;
        const tk = se.to * 4 + se.ts;
        const sp = portPoint(nx[se.from], ny[se.from], se.ss, portFrac(side_i[sk], side_n[sk]));
        const tp = portPoint(nx[se.to], ny[se.to], se.ts, portFrac(side_i[tk], side_n[tk]));
        side_i[sk] += 1;
        side_i[tk] += 1;
        const e = graph.edges[se.eidx];
        routes[ri] = .{
            .from_gid = e.from,
            .to_gid = e.to,
            .class = e.class,
            .label = e.label,
            .voltage = e.voltage,
            .fanout = e.fanout,
            .pts = try buildSidePts(arena, col_tops, se, sp, tp, content_h),
            .arrow_at_start = false,
        };
    }
    return routes;
}

/// The shared layered/Sugiyama pipeline: cycle-break → longest-path ranks →
/// crossing reduction → coordinate assignment → orthogonal routing. `gids` is
/// the participating node set; `raw` the edges among them (local indices). When
/// `fixed_ranks` is non-null it supplies each node's column directly (the System
/// view's functional staging), bypassing the flow-based ranking; routing still
/// inserts dummies for any edge that spans more than one column.
fn layeredLayout(arena: Allocator, graph: *const Graph, gids: []const u32, raw: []const RawEdge, fixed_ranks: ?[]const u32) Allocator.Error!Layout {
    const m: u32 = @intCast(gids.len);

    // Cycle break → effective DAG; longest-path ranks. A caller-supplied stage
    // assignment (fixed_ranks) overrides both.
    const rank = fixed_ranks orelse blk: {
        const reversed = try breakCycles(arena, m, raw);
        break :blk try assignRanks(arena, m, raw, reversed);
    };
    var max_rank: u32 = 0;
    for (rank) |r| max_rank = @max(max_rank, r);

    // Vertices (reals + dummies) and per-edge waypoint chains, bucketed into
    // layers.
    var verts: std.ArrayListUnmanaged(Vertex) = .empty;
    for (gids, 0..) |gid, i| try verts.append(arena, .{ .is_dummy = false, .gid = gid, .rank = rank[i], .h = node_h });
    var layers = try arena.alloc(std.ArrayListUnmanaged(u32), max_rank + 1);
    for (layers) |*l| l.* = .empty;
    for (0..m) |i| try layers[rank[i]].append(arena, @intCast(i));

    const chains = try buildChains(arena, raw, rank, &verts, layers);

    // Crossing reduction + coordinates.
    try orderLayers(arena, verts.items, layers, chains);
    const dims = try assignCoords(arena, verts.items, layers, chains);

    // Routing + materialise nodes.
    const routes = try routeChains(arena, graph, verts.items, rank, chains, max_rank);
    const nodes = try arena.alloc(LNode, m);
    for (0..m) |i| nodes[i] = .{ .gid = gids[i], .x = colX(verts.items[i].rank), .y = verts.items[i].y };

    return .{ .nodes = nodes, .routes = routes, .width = dims.w, .height = dims.h };
}

fn internNode(
    arena: Allocator,
    local_of: *std.AutoHashMapUnmanaged(u32, u32),
    gids: *std.ArrayListUnmanaged(u32),
    gid: u32,
) Allocator.Error!u32 {
    const gop = try local_of.getOrPut(arena, gid);
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(gids.items.len);
        try gids.append(arena, gid);
    }
    return gop.value_ptr.*;
}

// ── cycle breaking ─────────────────────────────────────────────────────

fn breakCycles(arena: Allocator, m: u32, raw: []const RawEdge) Allocator.Error![]bool {
    const reversed = try arena.alloc(bool, raw.len);
    @memset(reversed, false);
    // adjacency: node → list of (rawIdx)
    var adj = try arena.alloc(std.ArrayListUnmanaged(u32), m);
    for (adj) |*a| a.* = .empty;
    for (raw, 0..) |e, i| try adj[e.from_l].append(arena, @intCast(i));
    const color = try arena.alloc(u8, m); // 0 white, 1 gray, 2 black
    @memset(color, 0);
    for (0..m) |s| {
        if (color[s] == 0) dfsBreak(@intCast(s), raw, adj, color, reversed);
    }
    return reversed;
}

fn dfsBreak(u: u32, raw: []const RawEdge, adj: []std.ArrayListUnmanaged(u32), color: []u8, reversed: []bool) void {
    color[u] = 1;
    for (adj[u].items) |ri| {
        const v = raw[ri].to_l;
        if (color[v] == 1) {
            reversed[ri] = true; // back-edge
        } else if (color[v] == 0) {
            dfsBreak(v, raw, adj, color, reversed);
        }
    }
    color[u] = 2;
}

// ── layering ───────────────────────────────────────────────────────────

fn assignRanks(arena: Allocator, m: u32, raw: []const RawEdge, reversed: []const bool) Allocator.Error![]u32 {
    // Effective edges src→dst (reversed back-edges flipped) for a DAG.
    var out = try arena.alloc(std.ArrayListUnmanaged(u32), m);
    for (out) |*o| o.* = .empty;
    const indeg = try arena.alloc(u32, m);
    @memset(indeg, 0);
    for (raw, 0..) |e, i| {
        const src = if (reversed[i]) e.to_l else e.from_l;
        const dst = if (reversed[i]) e.from_l else e.to_l;
        try out[src].append(arena, dst);
        indeg[dst] += 1;
    }
    const rank = try arena.alloc(u32, m);
    @memset(rank, 0);
    var queue: std.ArrayListUnmanaged(u32) = .empty;
    for (0..m) |i| if (indeg[i] == 0) try queue.append(arena, @intCast(i));
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const u = queue.items[head];
        for (out[u].items) |w| {
            if (rank[u] + 1 > rank[w]) rank[w] = rank[u] + 1;
            indeg[w] -= 1;
            if (indeg[w] == 0) try queue.append(arena, w);
        }
    }
    return rank;
}

// ── vertices + chains ──────────────────────────────────────────────────

fn buildChains(
    arena: Allocator,
    raw: []const RawEdge,
    rank: []const u32,
    verts: *std.ArrayListUnmanaged(Vertex),
    layers: []std.ArrayListUnmanaged(u32),
) Allocator.Error![]Chain {
    const chains = try arena.alloc(Chain, raw.len);
    for (raw, 0..) |e, i| {
        const lo: u32 = if (rank[e.from_l] <= rank[e.to_l]) e.from_l else e.to_l;
        const hi: u32 = if (rank[e.from_l] <= rank[e.to_l]) e.to_l else e.from_l;
        const rl = rank[lo];
        const rh = rank[hi];
        var verts_list: std.ArrayListUnmanaged(u32) = .empty;
        try verts_list.append(arena, lo);
        var r = rl + 1;
        while (r < rh) : (r += 1) {
            const di: u32 = @intCast(verts.items.len);
            try verts.append(arena, .{ .is_dummy = true, .gid = 0, .rank = r, .h = dummy_h });
            try layers[r].append(arena, di);
            try verts_list.append(arena, di);
        }
        try verts_list.append(arena, hi);
        chains[i] = .{
            .verts = try verts_list.toOwnedSlice(arena),
            .eidx = e.eidx,
            .arrow_at_start = (e.to_l == lo),
        };
    }
    return chains;
}

// ── crossing reduction (median heuristic) ──────────────────────────────

fn orderLayers(arena: Allocator, verts: []const Vertex, layers: []std.ArrayListUnmanaged(u32), chains: []const Chain) Allocator.Error!void {
    var adj = try arena.alloc(std.ArrayListUnmanaged(u32), verts.len);
    for (adj) |*a| a.* = .empty;
    for (chains) |c| {
        var i: usize = 0;
        while (i + 1 < c.verts.len) : (i += 1) {
            try adj[c.verts[i]].append(arena, c.verts[i + 1]);
            try adj[c.verts[i + 1]].append(arena, c.verts[i]);
        }
    }
    const order = try arena.alloc(f64, verts.len);
    const keys = try arena.alloc(f64, verts.len);
    refreshOrder(layers, order);

    var sweep: usize = 0;
    while (sweep < 4) : (sweep += 1) {
        const down = (sweep % 2 == 0);
        var ri: usize = 0;
        while (ri < layers.len) : (ri += 1) {
            const r: usize = if (down) ri else layers.len - 1 - ri;
            const adj_rank: i64 = if (down) @as(i64, @intCast(r)) - 1 else @as(i64, @intCast(r)) + 1;
            if (adj_rank < 0 or adj_rank >= @as(i64, @intCast(layers.len))) continue;
            medianKeys(verts, layers[r].items, adj[0..], order, @intCast(adj_rank), keys);
            stableSortByKey(layers[r].items, keys);
            refreshLayerOrder(layers[r].items, order);
        }
    }
}

fn refreshOrder(layers: []std.ArrayListUnmanaged(u32), order: []f64) void {
    for (layers) |l| refreshLayerOrder(l.items, order);
}
fn refreshLayerOrder(layer: []const u32, order: []f64) void {
    for (layer, 0..) |v, i| order[v] = @floatFromInt(i);
}

fn medianKeys(verts: []const Vertex, layer: []const u32, adj: []std.ArrayListUnmanaged(u32), order: []const f64, adj_rank: u32, keys: []f64) void {
    var buf: [256]f64 = undefined;
    for (layer, 0..) |v, idx| {
        var n: usize = 0;
        for (adj[v].items) |nb| {
            if (verts[nb].rank == adj_rank and n < buf.len) {
                buf[n] = order[nb];
                n += 1;
            }
        }
        if (n == 0) {
            keys[idx] = @floatFromInt(idx); // no fixed neighbor → keep position
        } else {
            std.mem.sort(f64, buf[0..n], {}, std.sort.asc(f64));
            keys[idx] = buf[n / 2];
        }
    }
}

/// Stable insertion sort of `layer` by parallel `keys` (keys aligned by
/// position). Layers are small, so insertion sort is cheap and keeps equal
/// keys in place (important for median stability).
fn stableSortByKey(layer: []u32, keys: []f64) void {
    var i: usize = 1;
    while (i < layer.len) : (i += 1) {
        const v = layer[i];
        const k = keys[i];
        var j = i;
        while (j > 0 and keys[j - 1] > k) : (j -= 1) {
            layer[j] = layer[j - 1];
            keys[j] = keys[j - 1];
        }
        layer[j] = v;
        keys[j] = k;
    }
}

// ── coordinates ────────────────────────────────────────────────────────

fn colX(rank: u32) f64 {
    return pad + @as(f64, @floatFromInt(rank)) * (node_w + h_gap);
}

const Dims = struct { w: f64, h: f64 };

/// Per-vertex coordinate assignment. Stacks each layer in its crossing-reduced
/// order, then straightens with a single top-down sweep: each vertex is pulled
/// to the median centre of its neighbours in the *previous* column, then the
/// layer is packed downward (greedy — a vertex is only ever pushed down to clear
/// the one above it, never up). So a vertex fed 1-to-1 lands exactly on its
/// predecessor's row and a series chain (and long-edge dummies) renders as one
/// straight horizontal run, anchored to the source column.
fn assignCoords(arena: Allocator, verts: []Vertex, layers: []std.ArrayListUnmanaged(u32), chains: []const Chain) Allocator.Error!Dims {
    var max_h: f64 = node_h;
    for (layers) |l| {
        var sum: f64 = 0;
        for (l.items) |v| sum += verts[v].h;
        if (l.items.len > 0) sum += @as(f64, @floatFromInt(l.items.len - 1)) * v_gap;
        max_h = @max(max_h, sum);
    }
    for (layers) |l| {
        var sum: f64 = 0;
        for (l.items) |v| sum += verts[v].h;
        if (l.items.len > 0) sum += @as(f64, @floatFromInt(l.items.len - 1)) * v_gap;
        var cursor = pad + (max_h - sum) / 2;
        for (l.items) |v| {
            verts[v].y = cursor;
            cursor += verts[v].h + v_gap;
        }
    }

    // Cross-layer adjacency (consecutive chain vertices touch).
    const adj = try arena.alloc(std.ArrayListUnmanaged(u32), verts.len);
    for (adj) |*a| a.* = .empty;
    for (chains) |c| {
        var i: usize = 0;
        while (i + 1 < c.verts.len) : (i += 1) {
            try adj[c.verts[i]].append(arena, c.verts[i + 1]);
            try adj[c.verts[i + 1]].append(arena, c.verts[i]);
        }
    }

    // Lane assignment: a vertex with a single lower-rank neighbour (fed 1-to-1)
    // inherits that neighbour's exact centre, so a whole series chain — and any
    // long-edge dummies along it — sits on one straight row anchored to its
    // source column. A vertex with several feeders centres on their mean.
    const ctr = try arena.alloc(f64, verts.len); // working centre per vertex (filled per rank below)
    for (layers, 0..) |layer, r| {
        for (layer.items) |v| {
            if (r == 0) {
                ctr[v] = verts[v].y + verts[v].h / 2;
                continue;
            }
            // Centre on *direct* feeders (real lower-rank neighbours): a single
            // one ⇒ exact 1-to-1 alignment, several ⇒ midpoint between them.
            // Long-edge dummies (a re-routed signal like an LO passing through)
            // only anchor a vertex that has no direct feeder, so they neither
            // bend a chain nor drag a multi-feed node toward the routed input.
            var rs: f64 = 0;
            var rc: f64 = 0;
            var ds: f64 = 0;
            var dc: f64 = 0;
            for (adj[v].items) |nb| {
                if (verts[nb].rank >= verts[v].rank) continue;
                if (verts[nb].is_dummy) {
                    ds += ctr[nb];
                    dc += 1;
                } else {
                    rs += ctr[nb];
                    rc += 1;
                }
            }
            ctr[v] = if (rc > 0) rs / rc else if (dc > 0) ds / dc else verts[v].y + verts[v].h / 2;
        }
        // Keep this column's *real* boxes from overlapping after lane snapping;
        // thin routing dummies are left to ride their lane.
        resolveRankOverlap(verts, layer.items, ctr);
        for (layer.items) |v| verts[v].y = ctr[v] - verts[v].h / 2;
    }

    // Shift everything below the top pad; size from the lowest box.
    var min_y: f64 = std.math.floatMax(f64);
    var max_b: f64 = 0;
    for (verts) |v| {
        min_y = @min(min_y, v.y);
        max_b = @max(max_b, v.y + v.h);
    }
    for (verts) |*v| v.y += pad - min_y;

    const cols: f64 = @floatFromInt(layers.len);
    const w = pad * 2 + cols * node_w + @max(0, cols - 1) * h_gap;
    return .{ .w = w, .h = (max_b - min_y) + pad * 2 };
}

/// Push apart any *real* boxes in one column whose lane-snapped centres overlap,
/// in ascending-centre order (min gap `v_gap`). Well-separated lanes need no
/// push, so straight chains are preserved; only a crowded feeder gets nudged.
/// Thin long-edge dummies are excluded — they ride their lane as routing points.
fn resolveRankOverlap(verts: []Vertex, layer: []const u32, ctr: []f64) void {
    var ord_buf: [256]u32 = undefined;
    var n: usize = 0;
    for (layer) |v| {
        if (verts[v].is_dummy or n >= ord_buf.len) continue;
        ord_buf[n] = v;
        n += 1;
    }
    if (n < 2) return;
    const ord = ord_buf[0..n];
    std.mem.sort(u32, ord, @as([]const f64, ctr), cmpByCenter);
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const floor = ctr[ord[i - 1]] + verts[ord[i - 1]].h / 2 + v_gap + verts[ord[i]].h / 2;
        if (ctr[ord[i]] < floor) ctr[ord[i]] = floor;
    }
}

fn cmpByCenter(ctr: []const f64, a: u32, b: u32) bool {
    return ctr[a] < ctr[b];
}

fn cy(v: Vertex) f64 {
    return v.y + v.h / 2;
}

// ── orthogonal routing with per-channel lanes ──────────────────────────

fn routeChains(arena: Allocator, graph: *const Graph, verts: []const Vertex, rank: []const u32, chains: []const Chain, max_rank: u32) Allocator.Error![]Route {
    _ = rank;
    // Vertical lane per channel, keyed by source vertex: every edge leaving the
    // same node shares one trunk x, so a fanout reads as a clean comb. `lane_of`
    // is indexed by (channel rank × vertex-count + source vertex); `distinct`
    // counts the distinct sources per channel.
    const slots = verts.len;
    const lane_of = try arena.alloc(i32, (max_rank + 1) * slots);
    @memset(lane_of, -1);
    const distinct = try arena.alloc(u32, max_rank + 1);
    @memset(distinct, 0);
    for (chains) |c| {
        var i: usize = 0;
        while (i + 1 < c.verts.len) : (i += 1) {
            const src = c.verts[i];
            const r = verts[src].rank;
            const key = r * slots + src;
            if (lane_of[key] < 0) {
                lane_of[key] = @intCast(distinct[r]);
                distinct[r] += 1;
            }
        }
    }

    const routes = try arena.alloc(Route, chains.len);
    for (chains, 0..) |c, ci| {
        var pts: std.ArrayListUnmanaged(Pt) = .empty;
        const w0 = verts[c.verts[0]];
        try pts.append(arena, .{ .x = colX(w0.rank) + node_w, .y = cy(w0) });
        var i: usize = 0;
        while (i + 1 < c.verts.len) : (i += 1) {
            const a = verts[c.verts[i]];
            const b = verts[c.verts[i + 1]];
            const r = a.rank;
            const lane: u32 = @intCast(lane_of[r * slots + c.verts[i]]);
            const frac = (@as(f64, @floatFromInt(lane)) + 1) / (@as(f64, @floatFromInt(distinct[r])) + 1);
            const chx = colX(r) + node_w + frac * h_gap;
            try pts.append(arena, .{ .x = chx, .y = cy(a) });
            try pts.append(arena, .{ .x = chx, .y = cy(b) });
        }
        const wk = verts[c.verts[c.verts.len - 1]];
        try pts.append(arena, .{ .x = colX(wk.rank), .y = cy(wk) });

        const e = graph.edges[c.eidx];
        routes[ci] = .{
            .from_gid = e.from,
            .to_gid = e.to,
            .class = e.class,
            .label = e.label,
            .voltage = e.voltage,
            .fanout = e.fanout,
            .pts = try pts.toOwnedSlice(arena),
            .arrow_at_start = c.arrow_at_start,
        };
    }
    return routes;
}

// ── power view: source → regulators → load buckets ──────────────────────
//
// A left→right supply tree. Producers are ranked by feed depth on the
// cycle-broken producer graph: depth-0 roots are the INPUT source (battery /
// mezzanine), depth-1 producers are the REGULATORS, and depth-≥2 producers are
// cascade stages (an LDO fed by another regulated rail). Cascades are hidden;
// the rail they make is fed in the diagram straight from their depth-1 ancestor
// (a 3.3 V→1.8 V LDO renders as "1.8 V loads, fed from the 3.3 V buck"). Pure
// consumers group into one LOADS bucket per rail voltage, listed as pills.

const volt_eps: f64 = 0.05; // group voltages within 50 mV as one rail

// geometry
// Columns are kept tight so the four-column Power view fits the ~1200px page
// width and scales *up* (like the narrower Clocks/RF views) rather than being
// shrunk to fit — which is what makes its larger fonts actually read bigger.
const pw_col_gap: f64 = 84; // gap between columns
const pw_src_w: f64 = 216;
const pw_src_h: f64 = 180;
const pw_reg_w: f64 = 216;
const pw_reg_h: f64 = 106;
const pw_reg_gap: f64 = 30; // vertical gap between source / regulator cards
const pw_bucket_w: f64 = 330;
const pw_bucket_gap: f64 = 26; // vertical gap between buckets
// Pill-grid geometry is shared with render.zig so the bucket height computed
// here matches the pills drawn there.
pub const pw_head_h: f64 = 40; // bucket heading height
pub const pw_pill_cols: usize = 2; // pills per row in a bucket
pub const pw_pill_h: f64 = 30;
pub const pw_pill_gap: f64 = 8;
pub const pw_bucket_pad: f64 = 14; // inner padding in a bucket

const InfraEdge = struct { from: u32, to: u32 };

fn cmpDescF64(_: void, a: f64, b: f64) bool {
    return a > b;
}

fn railsHas(rails: []const f64, v: f64) bool {
    for (rails) |r| if (@abs(r - v) < volt_eps) return true;
    return false;
}

/// True when `node` has an incoming power edge carrying voltage `v`.
fn hasInEdgeVolt(graph: *const Graph, node: u32, v: f64) bool {
    for (graph.edges) |e| {
        if (e.class != types.CLASS_POWER or e.to != node) continue;
        if (e.voltage) |ev| {
            if (@abs(ev - v) < volt_eps) return true;
        }
    }
    return false;
}

const ProducerInfo = struct { depth: []u8, parent: []i64, has_chain: bool, battery_v: f64 };

fn dfsBack(u: u32, elist: []const InfraEdge, adj: []const std.ArrayListUnmanaged(u32), color: []u8, back: []bool) void {
    color[u] = 1;
    for (adj[u].items) |ei| {
        const v = elist[ei].to;
        if (color[v] == 1) {
            back[ei] = true;
        } else if (color[v] == 0) {
            dfsBack(v, elist, adj, color, back);
        }
    }
    color[u] = 2;
}

/// Feed depth per producer on the cycle-broken producer→producer graph
/// (0 = source root, 1 = regulator, ≥2 = cascade), a parent pointer along the
/// longest feed path, and the battery rail voltage (the source→regulator edge).
/// Cycle-broken so a rail looping back to the source doesn't demote it.
fn producerDepths(arena: Allocator, graph: *const Graph, is_producer: []const bool) Allocator.Error!ProducerInfo {
    const n = is_producer.len;
    var elist: std.ArrayListUnmanaged(InfraEdge) = .empty;
    for (graph.edges) |e| {
        if (e.class != types.CLASS_POWER or e.from == e.to) continue;
        if (!is_producer[e.from] or !is_producer[e.to]) continue;
        try elist.append(arena, .{ .from = e.from, .to = e.to });
    }
    const adj = try arena.alloc(std.ArrayListUnmanaged(u32), n);
    for (adj) |*a| a.* = .empty;
    for (elist.items, 0..) |ed, i| try adj[ed.from].append(arena, @intCast(i));
    const back = try arena.alloc(bool, elist.items.len);
    @memset(back, false);
    const color = try arena.alloc(u8, n);
    @memset(color, 0);
    for (0..n) |s| if (is_producer[s] and color[s] == 0) dfsBack(@intCast(s), elist.items, adj, color, back);

    // Longest-path depth over the forward (non-back) producer edges.
    const out = try arena.alloc(std.ArrayListUnmanaged(u32), n);
    for (out) |*o| o.* = .empty;
    const indeg = try arena.alloc(u32, n);
    @memset(indeg, 0);
    for (elist.items, 0..) |ed, i| {
        if (back[i]) continue;
        try out[ed.from].append(arena, ed.to);
        indeg[ed.to] += 1;
    }
    const depth = try arena.alloc(u8, n);
    @memset(depth, 0);
    const parent = try arena.alloc(i64, n);
    @memset(parent, -1);
    var queue: std.ArrayListUnmanaged(u32) = .empty;
    for (0..n) |i| if (is_producer[i] and indeg[i] == 0) try queue.append(arena, @intCast(i));
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const u = queue.items[head];
        for (out[u].items) |w| {
            if (depth[u] + 1 > depth[w]) {
                depth[w] = depth[u] + 1;
                parent[w] = @intCast(u);
            }
            indeg[w] -= 1;
            if (indeg[w] == 0) try queue.append(arena, w);
        }
    }
    var has_chain = false;
    for (0..n) |i| {
        if (is_producer[i] and depth[i] > 0) has_chain = true;
    }
    var battery_v: f64 = std.math.nan(f64);
    for (graph.edges) |e| {
        if (e.class != types.CLASS_POWER) continue;
        if (!is_producer[e.from] or !is_producer[e.to]) continue;
        if (depth[e.from] == 0 and depth[e.to] == 1) {
            if (e.voltage) |ev| battery_v = ev;
        }
    }
    return .{ .depth = depth, .parent = parent, .has_chain = has_chain, .battery_v = battery_v };
}

// Producer roles in the supply tree.
const role_source: u8 = 0; // battery / mezzanine (INPUT column)
const role_reg: u8 = 1; // primary regulator fed by the source (REGULATION)
const role_derived: u8 = 2; // cascade LDO that re-regulates a rail (DERIVED)
const role_hidden: u8 = 3; // pass-through filter (folded; rail feeds from parent)

/// Voltage of the incoming producer→`p` power edge (the rail feeding `p`).
fn producerInVolt(graph: *const Graph, is_producer: []const bool, p: u32) f64 {
    for (graph.edges) |e| {
        if (e.class != types.CLASS_POWER or e.to != p or !is_producer[e.from]) continue;
        if (e.voltage) |ev| return ev;
    }
    return std.math.nan(f64);
}

/// Classify every producer into a supply-tree role. A depth-0 root (with a chain
/// below it) is the source; a producer fed directly by the source is a primary
/// regulator; a deeper cascade stage is a *derived* regulator when it changes
/// voltage (an LDO — shown in its own column) or a folded pass-through when it
/// doesn't (a ferrite/π filter — hidden, its rail fed from the regulator above).
fn computeRoles(arena: Allocator, graph: *const Graph, is_producer: []const bool, info: ProducerInfo) Allocator.Error![]u8 {
    const n = is_producer.len;
    const roles = try arena.alloc(u8, n);
    @memset(roles, role_hidden);
    const reg_depth: u8 = if (info.has_chain) 1 else 0;
    for (0..n) |i| {
        if (!is_producer[i]) continue;
        const p: u32 = @intCast(i);
        if (info.has_chain and info.depth[p] == 0) {
            roles[p] = role_source;
        } else if (info.depth[p] == reg_depth) {
            roles[p] = role_reg;
        } else {
            const in_v = producerInVolt(graph, is_producer, p);
            const out_v = producerOutVolt(graph, p);
            const transforms = !std.math.isNan(in_v) and !std.math.isNan(out_v) and @abs(in_v - out_v) >= volt_eps;
            roles[p] = if (transforms) role_derived else role_hidden;
        }
    }
    return roles;
}

/// The nearest shown producer at or above `p` on the feed path, so a folded
/// filter's rail feeds from the regulator above it.
fn shownAncestor(info: ProducerInfo, roles: []const u8, p: u32) u32 {
    var cur = p;
    while (roles[cur] == role_hidden and info.parent[cur] >= 0) cur = @intCast(info.parent[cur]);
    return cur;
}

/// The downstream rail a producer drives (voltage of its first outgoing power
/// edge). NaN when it drives nothing.
fn producerOutVolt(graph: *const Graph, g: u32) f64 {
    for (graph.edges) |e| {
        if (e.class != types.CLASS_POWER or e.from != g) continue;
        if (e.voltage) |ev| return ev;
    }
    return std.math.nan(f64);
}

const RegCtx = struct { graph: *const Graph };

fn regVoltDesc(ctx: RegCtx, a: u32, b: u32) bool {
    const va = producerOutVolt(ctx.graph, a);
    const vb = producerOutVolt(ctx.graph, b);
    const fa: f64 = if (std.math.isNan(va)) -1 else va;
    const fb: f64 = if (std.math.isNan(vb)) -1 else vb;
    if (@abs(fa - fb) >= volt_eps) return fa > fb;
    return a < b;
}

/// The shown producer that should feed rail `v`'s bucket: the deepest producer
/// driving `v` (the cascade LDO if there is one, else the regulator), collapsed
/// to its nearest shown ancestor so a folded filter feeds from the regulator.
fn railFeeder(graph: *const Graph, is_producer: []const bool, info: ProducerInfo, roles: []const u8, v: f64) ?u32 {
    var best: ?u32 = null;
    var best_depth: i32 = -1;
    for (graph.edges) |e| {
        if (e.class != types.CLASS_POWER or !is_producer[e.from]) continue;
        const ev = e.voltage orelse continue;
        if (@abs(ev - v) >= volt_eps) continue;
        if (@as(i32, info.depth[e.from]) > best_depth) {
            best_depth = info.depth[e.from];
            best = e.from;
        }
    }
    if (best) |b| return shownAncestor(info, roles, b);
    return null;
}

fn addVolt(arena: Allocator, list: *std.ArrayListUnmanaged(f64), v: f64, battery_v: f64) Allocator.Error!void {
    if (!std.math.isNan(battery_v) and @abs(v - battery_v) < volt_eps) return;
    if (railsHas(list.items, v)) return;
    try list.append(arena, v);
}

/// Every load-rail voltage a consumer touches (rail set + incoming power-edge
/// voltages), minus the battery rail.
fn collectConsumerVolts(arena: Allocator, graph: *const Graph, node: u32, battery_v: f64, list: *std.ArrayListUnmanaged(f64)) Allocator.Error!void {
    for (graph.nodes[node].rails) |r| try addVolt(arena, list, r, battery_v);
    for (graph.edges) |e| {
        if (e.class != types.CLASS_POWER or e.to != node) continue;
        if (e.voltage) |ev| try addVolt(arena, list, ev, battery_v);
    }
}

fn pwElbow(arena: Allocator, x0: f64, y0: f64, x1: f64, y1: f64) Allocator.Error![]Pt {
    const midx = (x0 + x1) / 2;
    var pts: std.ArrayListUnmanaged(Pt) = .empty;
    try pts.append(arena, .{ .x = x0, .y = y0 });
    try pts.append(arena, .{ .x = midx, .y = y0 });
    try pts.append(arena, .{ .x = midx, .y = y1 });
    try pts.append(arena, .{ .x = x1, .y = y1 });
    return pts.toOwnedSlice(arena);
}

fn pwRoute(from: u32, to: u32, v: f64, pts: []Pt) Route {
    return .{
        .from_gid = from,
        .to_gid = to,
        .class = types.CLASS_POWER,
        .label = "",
        .voltage = if (std.math.isNan(v)) null else v,
        .fanout = 1,
        .pts = pts,
        .arrow_at_start = false,
    };
}

fn powerLayout(arena: Allocator, graph: *const Graph) Allocator.Error!?Layout {
    const n = graph.nodes.len;
    const is_producer = try arena.alloc(bool, n);
    @memset(is_producer, false);
    var any = false;
    for (graph.edges) |e| {
        if (e.class != types.CLASS_POWER) continue;
        any = true;
        is_producer[e.from] = true;
    }
    if (!any) return null;

    const info = try producerDepths(arena, graph, is_producer);
    const roles = try computeRoles(arena, graph, is_producer, info);

    // Distinct load-rail voltages, highest first so each bucket sits beside its
    // (descending) regulator.
    var rails: std.ArrayListUnmanaged(f64) = .empty;
    for (0..n) |i| {
        if (is_producer[i]) continue;
        try collectConsumerVolts(arena, graph, @intCast(i), info.battery_v, &rails);
    }
    std.mem.sort(f64, rails.items, {}, cmpDescF64);

    // Gather producers by role; regulators + derived LDOs sorted highest-rail-first.
    var sources: std.ArrayListUnmanaged(u32) = .empty;
    var regs: std.ArrayListUnmanaged(u32) = .empty;
    var deriveds: std.ArrayListUnmanaged(u32) = .empty;
    for (0..n) |i| {
        if (!is_producer[i]) continue;
        switch (roles[i]) {
            role_source => try sources.append(arena, @intCast(i)),
            role_reg => try regs.append(arena, @intCast(i)),
            role_derived => try deriveds.append(arena, @intCast(i)),
            else => {},
        }
    }
    std.sort.block(u32, regs.items, RegCtx{ .graph = graph }, regVoltDesc);
    std.sort.block(u32, deriveds.items, RegCtx{ .graph = graph }, regVoltDesc);
    const buckets = try buildBuckets(arena, graph, is_producer, rails.items);

    // Columns: INPUT → REGULATION → (DERIVED, only if any) → LOADS.
    const input_x = pad;
    const reg_x = if (sources.items.len > 0) input_x + pw_src_w + pw_col_gap else input_x;
    const have_derived = deriveds.items.len > 0;
    const derived_x = reg_x + pw_reg_w + pw_col_gap;
    const loads_x = (if (have_derived) derived_x + pw_reg_w else reg_x + pw_reg_w) + pw_col_gap;

    // Column content heights; the tallest decides the canvas.
    const src_total = stackHeight(sources.items.len, pw_src_h, pw_reg_gap);
    const reg_total = stackHeight(regs.items.len, pw_reg_h, pw_reg_gap);
    const der_total = stackHeight(deriveds.items.len, pw_reg_h, pw_reg_gap);
    var bucket_total: f64 = 0;
    for (buckets) |b| bucket_total += b.h + pw_bucket_gap;
    if (bucket_total > 0) bucket_total -= pw_bucket_gap;
    const inner_h = @max(@max(@max(src_total, reg_total), der_total), bucket_total);

    var boxes: std.ArrayListUnmanaged(PowerBox) = .empty;
    var routes: std.ArrayListUnmanaged(Route) = .empty;
    const prx = try arena.alloc(f64, n); // shown producer right-edge x
    const pcy = try arena.alloc(f64, n); // shown producer centre y
    @memset(prx, 0);
    @memset(pcy, 0);

    // ── INPUT: source card(s), vertically centred ──
    const src_right = input_x + pw_src_w;
    var src_top: f64 = pad;
    {
        var y = pad + (inner_h - src_total) / 2;
        for (sources.items, 0..) |g, i| {
            if (i == 0) src_top = y;
            try boxes.append(arena, .{ .kind = .source, .gid = g, .x = input_x, .y = y, .w = pw_src_w, .h = pw_src_h, .v = info.battery_v });
            prx[g] = src_right;
            pcy[g] = y + pw_src_h / 2;
            y += pw_src_h + pw_reg_gap;
        }
    }

    // ── REGULATION: primary regulators, fed by the source ──
    {
        var y = pad + (inner_h - reg_total) / 2;
        const reg_count: f64 = @floatFromInt(regs.items.len);
        for (regs.items, 0..) |g, i| {
            try boxes.append(arena, .{ .kind = .regulator, .gid = g, .x = reg_x, .y = y, .w = pw_reg_w, .h = pw_reg_h, .v = producerOutVolt(graph, g) });
            prx[g] = reg_x + pw_reg_w;
            pcy[g] = y + pw_reg_h / 2;
            if (sources.items.len > 0) {
                const frac = (@as(f64, @floatFromInt(i)) + 1) / (reg_count + 1);
                const pts = try pwElbow(arena, src_right, src_top + frac * pw_src_h, reg_x, pcy[g]);
                try routes.append(arena, pwRoute(0, g, info.battery_v, pts));
            }
            y += pw_reg_h + pw_reg_gap;
        }
    }

    // ── DERIVED: cascade LDOs, fed from the rail they re-regulate ──
    {
        var y = pad + (inner_h - der_total) / 2;
        for (deriveds.items) |d| {
            try boxes.append(arena, .{ .kind = .regulator, .gid = d, .x = derived_x, .y = y, .w = pw_reg_w, .h = pw_reg_h, .v = producerOutVolt(graph, d) });
            prx[d] = derived_x + pw_reg_w;
            pcy[d] = y + pw_reg_h / 2;
            if (info.parent[d] >= 0) {
                const from = shownAncestor(info, roles, @intCast(info.parent[d]));
                const pts = try pwElbow(arena, prx[from], pcy[from], derived_x, pcy[d]);
                try routes.append(arena, pwRoute(from, d, producerInVolt(graph, is_producer, d), pts));
            }
            y += pw_reg_h + pw_reg_gap;
        }
    }

    // ── LOADS: rail buckets, fed from their (shown) producer ──
    {
        var y = pad + (inner_h - bucket_total) / 2;
        for (buckets) |b| {
            try boxes.append(arena, .{ .kind = .bucket, .x = loads_x, .y = y, .w = pw_bucket_w, .h = b.h, .v = b.v, .members = b.members });
            if (railFeeder(graph, is_producer, info, roles, b.v)) |fg| {
                const pts = try pwElbow(arena, prx[fg], pcy[fg], loads_x, y + b.h / 2);
                try routes.append(arena, pwRoute(fg, 0, b.v, pts));
            }
            y += b.h + pw_bucket_gap;
        }
    }

    return .{
        .nodes = &.{},
        .routes = try routes.toOwnedSlice(arena),
        .power_boxes = try boxes.toOwnedSlice(arena),
        .width = loads_x + pw_bucket_w + pad,
        .height = pad * 2 + inner_h,
    };
}

/// Total height of a vertical stack of `count` items of height `item_h` with
/// `gap` between them.
fn stackHeight(count: usize, item_h: f64, gap: f64) f64 {
    if (count == 0) return 0;
    const c: f64 = @floatFromInt(count);
    return c * item_h + (c - 1) * gap;
}

/// A test-point / mechanical / debug node — instrumentation that taps a rail to
/// measure or access it, not a real load. Kept out of the power view's load
/// buckets so they don't inflate the consumer count with non-loads.
fn isInstrumentation(label: []const u8) bool {
    const kw = [_][]const u8{ "Test Point", "Mounting", "Fiducial", "Standoff", "Bring-up", "Debug" };
    for (kw) |k| if (std.ascii.indexOfIgnoreCase(label, k) != null) return true;
    return false;
}

const Bucket = struct { v: f64, members: []const u32, h: f64 };

/// One bucket per rail voltage (in `rails` order): its consuming nodes and the
/// box height needed for their pill grid. Rails with no consumer are dropped.
fn buildBuckets(arena: Allocator, graph: *const Graph, is_producer: []const bool, rail_volts: []const f64) Allocator.Error![]Bucket {
    const n = graph.nodes.len;
    var out: std.ArrayListUnmanaged(Bucket) = .empty;
    for (rail_volts) |v| {
        var members: std.ArrayListUnmanaged(u32) = .empty;
        for (0..n) |i| {
            if (is_producer[i]) continue;
            if (isInstrumentation(graph.nodes[i].label)) continue;
            if (railsHas(graph.nodes[i].rails, v) or hasInEdgeVolt(graph, @intCast(i), v)) try members.append(arena, @intCast(i));
        }
        if (members.items.len == 0) continue;
        const rows = (members.items.len + pw_pill_cols - 1) / pw_pill_cols;
        const bh = pw_head_h + @as(f64, @floatFromInt(rows)) * (pw_pill_h + pw_pill_gap) + pw_bucket_pad;
        try out.append(arena, .{ .v = v, .members = try members.toOwnedSlice(arena), .h = bh });
    }
    return out.toOwnedSlice(arena);
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkNode(label: []const u8) types.Node {
    return .{ .label = label, .subtitle = "", .category = .peripheral, .slug = "", .inputs = &.{}, .outputs = &.{} };
}

// spec: diagram/layout - Treats test-point and mechanical nodes as instrumentation, excluded from load buckets
test "isInstrumentation flags test-point and mechanical nodes" {
    try testing.expect(isInstrumentation("Test Points"));
    try testing.expect(isInstrumentation("Mounting"));
    try testing.expect(isInstrumentation("Bring-up & Debug"));
    try testing.expect(!isInstrumentation("RP2350B Core"));
    try testing.expect(!isInstrumentation("Channel 1 PSU"));
}

// spec: diagram/layout - Returns null for a view with no edges
test "computeLayout returns null when the view has no edges" {
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B") };
    const graph = Graph{ .nodes = &nodes, .edges = &.{} };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = try computeLayout(arena.allocator(), &graph, types.CLASS_RF);
    try testing.expect(lay == null);
}

// spec: diagram/layout - Ranks nodes left-to-right by signal flow, breaking cycles for layering
test "computeLayout breaks a cycle and ranks across columns" {
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B"), mkNode("C") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_RF, .label = "x" },
        .{ .from = 1, .to = 2, .class = types.CLASS_RF, .label = "y" },
        .{ .from = 2, .to = 0, .class = types.CLASS_RF, .label = "z" }, // back-edge → cycle
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, types.CLASS_RF)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), lay.nodes.len);
    // Three ranks ⇒ at least three columns wide.
    try testing.expect(lay.width > node_w * 2);
}

// spec: diagram/layout - Routes edges sharing a source through one common vertical trunk
test "computeLayout gives a shared-source fanout one common bend x" {
    var nodes = [_]types.Node{ mkNode("SRC"), mkNode("A"), mkNode("B"), mkNode("C") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_CLOCK, .label = "r1" },
        .{ .from = 0, .to = 2, .class = types.CLASS_CLOCK, .label = "r2" },
        .{ .from = 0, .to = 3, .class = types.CLASS_CLOCK, .label = "r3" },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, types.CLASS_CLOCK)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), lay.routes.len);
    // The first vertical channel segment is pts[1]→pts[2]; its x is the bend.
    // All three edges leave the same source, so they must share one trunk x.
    const bend = lay.routes[0].pts[1].x;
    for (lay.routes) |r| {
        try testing.expect(r.pts.len >= 4);
        try testing.expectApproxEqAbs(bend, r.pts[1].x, 0.01);
    }
}

// spec: diagram/layout - Flows the power source left of the regulators it feeds
test "computeLayout puts the power source left of the regulators it feeds" {
    var nodes = [_]types.Node{ mkNode("MEZZ"), mkNode("REG"), mkNode("LOAD") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "VBATT", .voltage = 3.7 },
        .{ .from = 1, .to = 2, .class = types.CLASS_POWER, .label = "v5", .voltage = 5.0 },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, types.CLASS_POWER)) orelse return error.TestUnexpectedResult;
    var sx: f64 = -1;
    var rx: f64 = -1;
    var bx: f64 = -1;
    for (lay.power_boxes) |pb| {
        if (pb.kind == .source) sx = pb.x;
        if (pb.kind == .regulator) rx = pb.x;
        if (pb.kind == .bucket) bx = pb.x;
    }
    try testing.expect(sx >= 0 and rx >= 0 and bx >= 0);
    try testing.expect(sx < rx);
    try testing.expect(rx < bx);
}

// spec: diagram/layout - Groups power consumers into one load bucket per rail
test "computeLayout groups power consumers into per-rail buckets" {
    var nodes = [_]types.Node{ mkNode("REG18"), mkNode("REG33"), mkNode("A"), mkNode("B"), mkNode("C") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 2, .class = types.CLASS_POWER, .label = "v18", .voltage = 1.8 },
        .{ .from = 1, .to = 3, .class = types.CLASS_POWER, .label = "v33", .voltage = 3.3 },
        .{ .from = 1, .to = 4, .class = types.CLASS_POWER, .label = "v33b", .voltage = 3.3 },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, types.CLASS_POWER)) orelse return error.TestUnexpectedResult;
    var n18: usize = 0;
    var n33: usize = 0;
    var buckets: usize = 0;
    for (lay.power_boxes) |pb| {
        if (pb.kind != .bucket) continue;
        buckets += 1;
        if (@abs(pb.v - 1.8) < 0.01) n18 = pb.members.len;
        if (@abs(pb.v - 3.3) < 0.01) n33 = pb.members.len;
    }
    try testing.expectEqual(@as(usize, 2), buckets);
    try testing.expectEqual(@as(usize, 1), n18);
    try testing.expectEqual(@as(usize, 2), n33);
}

// spec: diagram/layout - Lists a dual-rail consumer in both of its rail buckets
test "computeLayout lists a dual-rail consumer in both rail buckets" {
    var dual = mkNode("DUAL");
    dual.rails = &[_]f64{ 1.8, 3.3 };
    dual.power_rail = 3.3;
    var nodes = [_]types.Node{ mkNode("REG"), dual };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "v", .voltage = 3.3 }};
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, types.CLASS_POWER)) orelse return error.TestUnexpectedResult;
    var in18 = false;
    var in33 = false;
    for (lay.power_boxes) |pb| {
        if (pb.kind != .bucket) continue;
        if (@abs(pb.v - 1.8) < 0.01 and pb.members.len == 1) in18 = true;
        if (@abs(pb.v - 3.3) < 0.01 and pb.members.len == 1) in33 = true;
    }
    try testing.expect(in18 and in33);
}

// spec: diagram/layout - Shows a cascade LDO that re-regulates a rail in its own column
test "computeLayout shows a voltage-changing cascade LDO" {
    var nodes = [_]types.Node{ mkNode("MEZZ"), mkNode("BUCK33"), mkNode("LDO18"), mkNode("LOAD") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "VBATT", .voltage = 3.7 },
        .{ .from = 1, .to = 2, .class = types.CLASS_POWER, .label = "V3P3", .voltage = 3.3 }, // buck → LDO (3.3 V in)
        .{ .from = 2, .to = 3, .class = types.CLASS_POWER, .label = "V1P8", .voltage = 1.8 }, // LDO → load (1.8 V out)
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, types.CLASS_POWER)) orelse return error.TestUnexpectedResult;
    // The LDO changes voltage (3.3 → 1.8) so it is shown — two regulator cards
    // (BUCK33 + LDO18) at different columns, plus the 1.8 V bucket.
    var regs: usize = 0;
    var xs: [2]f64 = .{ -1, -1 };
    var has18bucket = false;
    for (lay.power_boxes) |pb| {
        if (pb.kind == .regulator) {
            if (regs < 2) xs[regs] = pb.x;
            regs += 1;
        }
        if (pb.kind == .bucket and @abs(pb.v - 1.8) < 0.01) has18bucket = true;
    }
    try testing.expectEqual(@as(usize, 2), regs);
    try testing.expect(xs[0] != xs[1]); // regulator and derived LDO in different columns
    try testing.expect(has18bucket);
}

// spec: diagram/layout - Folds a pass-through filter stage and feeds its rail from the parent regulator
test "computeLayout folds a same-voltage filter stage" {
    var nodes = [_]types.Node{ mkNode("MEZZ"), mkNode("BUCK5"), mkNode("FILTER"), mkNode("LOAD") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "VBATT", .voltage = 3.7 },
        .{ .from = 1, .to = 2, .class = types.CLASS_POWER, .label = "V5RAW", .voltage = 5.0 }, // buck → filter (5 V)
        .{ .from = 2, .to = 3, .class = types.CLASS_POWER, .label = "V5", .voltage = 5.0 }, // filter → load (still 5 V)
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, types.CLASS_POWER)) orelse return error.TestUnexpectedResult;
    // The filter passes 5 V through unchanged, so it is folded: only BUCK5 shows.
    var regs: usize = 0;
    var has5bucket = false;
    for (lay.power_boxes) |pb| {
        if (pb.kind == .regulator) regs += 1;
        if (pb.kind == .bucket and @abs(pb.v - 5.0) < 0.01) has5bucket = true;
    }
    try testing.expectEqual(@as(usize, 1), regs);
    try testing.expect(has5bucket);
}

fn mkBlock(label: []const u8, slug: []const u8) types.Node {
    return .{ .label = label, .subtitle = "", .category = .peripheral, .slug = slug, .inputs = &.{}, .outputs = &.{} };
}

/// A placeable block with a layout key (its authoring name), used by the free
/// layout tests where `(place …)` matches on `key`.
fn mkKeyed(key: []const u8) types.Node {
    return .{ .label = key, .subtitle = "", .category = .peripheral, .slug = key, .key = key, .inputs = &.{}, .outputs = &.{} };
}

// spec: diagram/layout - computeFreeLayout pins each anchor and resolves placed blocks in dependency order
test "computeFreeLayout resolves relative placements from an anchor" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b"), mkKeyed("c") };
    const placements = [_]env_mod.Placement{
        .{ .name = "a", .rel = .anchor },
        // declared out of dependency order: c depends on b, b depends on a.
        .{ .name = "c", .rel = .below, .reference = "b" },
        .{ .name = "b", .rel = .right_of, .reference = "a" },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &.{}, .layout = .{ .placements = &placements } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), lay.nodes.len);
    const xy = nodeXY(lay.nodes);
    // a at origin cell; b one column right of a; c one row below b.
    try testing.expectApproxEqAbs(xy[0].x + node_w + h_gap, xy[1].x, 0.5);
    try testing.expectApproxEqAbs(xy[0].y, xy[1].y, 0.5);
    try testing.expectApproxEqAbs(xy[1].x, xy[2].x, 0.5);
    try testing.expect(xy[2].y > xy[1].y);
}

// spec: diagram/layout - computeFreeLayout flows un-placed blocks into a fallback row below the placed cluster
test "computeFreeLayout flows an un-placed block into the fallback row" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("orphan") };
    const placements = [_]env_mod.Placement{.{ .name = "a", .rel = .anchor }};
    const graph = Graph{ .nodes = &nodes, .edges = &.{}, .layout = .{ .placements = &placements } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), lay.nodes.len);
    const xy = nodeXY(lay.nodes);
    // The un-placed "orphan" (gid 1) sits in a row below the placed "a" (gid 0).
    try testing.expect(xy[1].y > xy[0].y);
}

// spec: diagram/layout - computeFreeLayout places a block with a missing reference into the fallback row without aborting
test "computeFreeLayout tolerates a placement naming an unknown reference" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b") };
    const placements = [_]env_mod.Placement{
        .{ .name = "a", .rel = .anchor },
        .{ .name = "b", .rel = .right_of, .reference = "ghost" }, // no such block
    };
    const graph = Graph{ .nodes = &nodes, .edges = &.{}, .layout = .{ .placements = &placements } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    // b never resolved (ghost reference) → it flows to the fallback row, below a.
    try testing.expectEqual(@as(usize, 2), lay.nodes.len);
    const xy = nodeXY(lay.nodes);
    try testing.expect(xy[1].y > xy[0].y);
}

// spec: diagram/layout - computeFreeLayout breaks a placement cycle instead of looping forever
test "computeFreeLayout breaks a placement cycle" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b") };
    // a right-of b, b right-of a — a cycle with no anchor; neither can resolve.
    const placements = [_]env_mod.Placement{
        .{ .name = "a", .rel = .right_of, .reference = "b" },
        .{ .name = "b", .rel = .right_of, .reference = "a" },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &.{}, .layout = .{ .placements = &placements } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Terminates (no infinite loop) and still emits both blocks via the fallback.
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), lay.nodes.len);
}

/// Map placed nodes back to (x,y) indexed by their graph id, for assertions.
fn nodeXY(nodes: []const LNode) [8]Pt {
    var out = [_]Pt{.{ .x = 0, .y = 0 }} ** 8;
    for (nodes) |n| out[n.gid] = .{ .x = n.x, .y = n.y };
    return out;
}

// spec: diagram/layout - System layout combines edges from every class in one diagram
test "computeSystemLayout includes edges of all classes at once" {
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B"), mkNode("C") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "v", .voltage = 3.3 },
        .{ .from = 1, .to = 2, .class = types.CLASS_CLOCK, .label = "clk" },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeSystemLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), lay.routes.len);
    var has_power = false;
    var has_clock = false;
    for (lay.routes) |r| {
        if (r.class == types.CLASS_POWER) has_power = true;
        if (r.class == types.CLASS_CLOCK) has_clock = true;
    }
    try testing.expect(has_power and has_clock);
}

// spec: diagram/layout - System view flows blocks by functional stage: Power → Core → Peripherals
test "computeSystemLayout stages blocks power→core→peripheral left to right" {
    var nodes = [_]types.Node{
        .{ .label = "Buck", .subtitle = "", .category = .power, .slug = "", .inputs = &.{}, .outputs = &.{} },
        .{ .label = "MCU", .subtitle = "", .category = .mcu, .slug = "", .inputs = &.{}, .outputs = &.{} },
        .{ .label = "Sensor", .subtitle = "", .category = .sensor, .slug = "", .inputs = &.{}, .outputs = &.{} },
    };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_POWER, .label = "3V3", .voltage = 3.3 },
        .{ .from = 1, .to = 2, .class = types.CLASS_CONTROL, .label = "I2C" },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeSystemLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    // Three used stages, labeled left→right.
    try testing.expectEqual(@as(usize, 3), lay.stage_labels.len);
    try testing.expectEqualStrings("Power", lay.stage_labels[0]);
    try testing.expectEqualStrings("Core", lay.stage_labels[1]);
    try testing.expectEqualStrings("Peripherals & I/O", lay.stage_labels[2]);
    // Nodes are placed in intern order (edge endpoints first seen): gid 0 power,
    // 1 mcu, 2 sensor. Each sits in its stage's column — power left of core left
    // of peripheral.
    try testing.expectEqual(@as(u32, 0), lay.nodes[0].gid);
    try testing.expectEqual(@as(u32, 1), lay.nodes[1].gid);
    try testing.expectEqual(@as(u32, 2), lay.nodes[2].gid);
    try testing.expect(lay.nodes[0].x < lay.nodes[1].x);
    try testing.expect(lay.nodes[1].x < lay.nodes[2].x);
}

// spec: diagram/layout - Attaches a same-column edge to a vertical face so it does not loop into the gap
test "computeSystemLayout routes a same-column edge on a vertical face" {
    // Two peripherals share a stage (column); the edge between them must attach
    // top/bottom and arrive vertically, not loop out into the column gap.
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B") };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "x" }};
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeSystemLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), lay.routes.len);
    const pts = lay.routes[0].pts;
    const last = pts.len - 1;
    // The final segment is vertical: it shares an x with the prior waypoint.
    try testing.expectApproxEqAbs(pts[last].x, pts[last - 1].x, 0.5);
    // The source port sits along the box top/bottom (an x strictly inside the
    // box), never on the right face (which would loop into the gap).
    try testing.expect(pts[0].x < lay.nodes[0].x + node_w - 0.5);
}

// spec: diagram/layout - Attaches a cross-column edge to the source's horizontal face nearest the target
test "computeSystemLayout routes a cross-column edge on a horizontal face" {
    var nodes = [_]types.Node{
        .{ .label = "Buck", .subtitle = "", .category = .power, .slug = "", .inputs = &.{}, .outputs = &.{} },
        .{ .label = "MCU", .subtitle = "", .category = .mcu, .slug = "", .inputs = &.{}, .outputs = &.{} },
    };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "x" }};
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeSystemLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    const pts = lay.routes[0].pts;
    // Power is left of core, so the source exits its right face toward the target.
    try testing.expectApproxEqAbs(pts[0].x, lay.nodes[0].x + node_w, 0.5);
    // The edge arrives horizontally on the target's left face.
    const last = pts.len - 1;
    try testing.expectApproxEqAbs(pts[last].y, pts[last - 1].y, 0.5);
}

// spec: diagram/layout - Falls back to isolated block boxes when there are no connections
test "computeSystemLayout shows isolated blocks when there are no edges" {
    var nodes = [_]types.Node{ mkBlock("Block A", "a"), mkBlock("Block B", "b") };
    const graph = Graph{ .nodes = &nodes, .edges = &.{} };
    try testing.expect(hasSystemView(&graph));
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeSystemLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), lay.nodes.len);
    try testing.expectEqual(@as(usize, 0), lay.routes.len);
}

// spec: diagram/layout - Omits an unconnected block from the System view when edges exist
test "computeSystemLayout omits an unconnected block when edges exist" {
    var nodes = [_]types.Node{ mkBlock("A", "a"), mkBlock("B", "b"), mkBlock("Lonely", "lonely") };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "x" }};
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeSystemLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    // Only the two connected blocks are placed; the lonely one (gid 2) is omitted.
    try testing.expectEqual(@as(usize, 2), lay.nodes.len);
    for (lay.nodes) |n| try testing.expect(n.gid != 2);
}

// spec: diagram/layout - Keeps a force-shown block in the layout even when it has no edges
test "computeSystemLayout keeps a force-shown isolated block" {
    var lonely = mkBlock("Declared", "declared");
    lonely.force_show = true; // a declared function box, unwired
    var nodes = [_]types.Node{ mkBlock("A", "a"), mkBlock("B", "b"), lonely };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "x" }};
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeSystemLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    // All three are placed: the two wired blocks plus the force-shown one (gid 2).
    try testing.expectEqual(@as(usize, 3), lay.nodes.len);
    var saw_forced = false;
    for (lay.nodes) |n| {
        if (n.gid == 2) saw_forced = true;
    }
    try testing.expect(saw_forced);
}
