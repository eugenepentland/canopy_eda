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
const free_v_gap: f64 = 130;
/// Column gap in the free Layout view — wider than the System view's `h_gap` so
/// the `(group …)` regions read as well-separated sections with routing room.
const free_h_gap: f64 = 184;
/// Column gap between independent `(anchor …)` roots in the free layout, so two
/// unrelated placement trees don't collide. Wide enough to clear a few cells.
const anchor_col_stride: i32 = 6;
/// Per-card offset of a multi-channel stacked block — mirrors render.zig's
/// `stack_offset`. The free layout reserves canvas margin for the cards a stack
/// pushes up and to the right so the "×N" badge and rear cards never clip.
const stack_card_offset: f64 = 7;
/// Vertical room the "×N" badge needs above the rearmost stacked card (font
/// height + gap) — mirrors render.zig's badge font-size + `stack_badge_gap`.
const stack_badge_h: f64 = 22;
/// How far a `(group …)` box extends past its members on the left/right/bottom.
/// Kept well under `free_v_gap`/`h_gap` so vertically/horizontally adjacent
/// group boxes keep a visible gap instead of touching.
const group_pad: f64 = 12;
/// Top strip a `(group …)` box reserves above its members for the group label.
const group_label_h: f64 = 24;

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

/// A labeled visual region in the free Layout view: the padded bounding box of a
/// `(group …)` directive's members, drawn behind the nodes with `label` in the
/// top-left. `color_idx` cycles a small palette so adjacent groups differ.
pub const GroupBox = struct {
    label: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    color_idx: usize = 0,
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
    /// Free Layout view only: labeled `(group …)` regions, drawn behind the
    /// nodes. Empty when no groups were declared.
    groups: []const GroupBox = &.{},
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

/// The System view's functional-stage band labels, in left→right order; a
/// block's column is its `systemStage` index into this. Unused stages are
/// compacted out so a design with no power blocks (or no MCU) shows no gap.
const system_labels = [_][]const u8{ "Power", "Core", "Peripherals & I/O" };

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
    if (!try internStaged(arena, graph, &local_of, &gids, &raw)) return null;
    const raw_stage = try arena.alloc(u8, gids.items.len);
    for (gids.items, 0..) |gid, i| raw_stage[i] = systemStage(graph.nodes[gid]);
    return try finishStagedLayout(arena, graph, gids.items, raw.items, raw_stage, &system_labels);
}

/// One narrative stage of the **Signal Chain** view: a band `label` and the
/// super-node labels (function names) that belong in it. Built from the design's
/// `(function … (chain pos "label"))` declarations (`diagram.zig`).
pub const StageSpec = struct { label: []const u8, members: []const []const u8 };

/// The **Signal Chain** view: the same coarsened blocks as the Function view,
/// but laid out by a *declared narrative order* (`stages`) instead of by
/// category — power-in → control → stimulus → DUT → measure → … so the diagram
/// reads as the instrument's story. A block not named by any stage falls into a
/// trailing "Other" band. Returns null when there's nothing to draw.
pub fn computeChainLayout(arena: Allocator, graph: *const Graph, stages: []const StageSpec) Allocator.Error!?Layout {
    var local_of = std.AutoHashMapUnmanaged(u32, u32){};
    var gids: std.ArrayListUnmanaged(u32) = .empty;
    var raw: std.ArrayListUnmanaged(RawEdge) = .empty;
    if (!try internStaged(arena, graph, &local_of, &gids, &raw)) return null;

    // Stage each node by matching its label to a declared stage; unmatched nodes
    // share a trailing "Other" band (only labelled when something lands there).
    const other: u8 = @intCast(stages.len);
    var any_other = false;
    const raw_stage = try arena.alloc(u8, gids.items.len);
    for (gids.items, 0..) |gid, i| {
        raw_stage[i] = chainStageOf(graph.nodes[gid].label, stages) orelse blk: {
            any_other = true;
            break :blk other;
        };
    }
    var labels: std.ArrayListUnmanaged([]const u8) = .empty;
    for (stages) |s| try labels.append(arena, s.label);
    if (any_other) try labels.append(arena, "Other");
    return try finishStagedLayout(arena, graph, gids.items, raw.items, raw_stage, labels.items);
}

/// The stage index of the first declared stage that lists `label` as a member
/// (exact match), or null when none does.
fn chainStageOf(label: []const u8, stages: []const StageSpec) ?u8 {
    for (stages, 0..) |s, i| {
        for (s.members) |m| if (std.mem.eql(u8, label, m)) return @intCast(i);
    }
    return null;
}

/// Shared front half of the staged layouts: intern every edge endpoint, plus any
/// `force_show` block (so a declared-but-unwired subsystem still appears), then
/// fall back to the isolated real blocks when there are no edges at all. Returns
/// false (nothing to draw) only when not a single node was interned.
fn internStaged(
    arena: Allocator,
    graph: *const Graph,
    local_of: *std.AutoHashMapUnmanaged(u32, u32),
    gids: *std.ArrayListUnmanaged(u32),
    raw: *std.ArrayListUnmanaged(RawEdge),
) Allocator.Error!bool {
    for (graph.edges, 0..) |e, eidx| {
        const fl = try internNode(arena, local_of, gids, e.from);
        const tl = try internNode(arena, local_of, gids, e.to);
        if (fl == tl) continue;
        try raw.append(arena, .{ .from_l = fl, .to_l = tl, .eidx = eidx });
    }
    for (graph.nodes, 0..) |n, i| {
        if (n.force_show) _ = try internNode(arena, local_of, gids, @intCast(i));
    }
    if (gids.items.len == 0) {
        for (graph.nodes, 0..) |n, i| {
            if (isBlock(n)) _ = try internNode(arena, local_of, gids, @intCast(i));
        }
    }
    return gids.items.len > 0;
}

/// Shared back half: compact the *used* stages to consecutive columns (so empty
/// stages leave no gap), lay the blocks out with those fixed ranks, route the
/// edges nearest-side, and hang the (compacted) stage labels as band headers.
fn finishStagedLayout(
    arena: Allocator,
    graph: *const Graph,
    gids: []const u32,
    raw: []const RawEdge,
    raw_stage: []const u8,
    all_labels: []const []const u8,
) Allocator.Error!Layout {
    const used = try arena.alloc(bool, all_labels.len);
    @memset(used, false);
    for (raw_stage) |s| used[s] = true;
    const col_of_stage = try arena.alloc(u32, all_labels.len);
    var col_label: std.ArrayListUnmanaged([]const u8) = .empty;
    var ncols: u32 = 0;
    for (all_labels, 0..) |label, s| {
        if (!used[s]) continue;
        col_of_stage[s] = ncols;
        ncols += 1;
        try col_label.append(arena, label);
    }
    const ranks = try arena.alloc(u32, gids.len);
    for (raw_stage, 0..) |s, i| ranks[i] = col_of_stage[s];

    var lay = try layeredLayout(arena, graph, gids, raw, ranks);
    // The layered pipeline ordered the columns well, but its left→right lane
    // routing loops same-column edges and crosses boxes on long hops. Re-route
    // every edge from the side of its source nearest the target.
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

/// True when the design declared a `(layout …)` with at least one placement or
/// row band — gates whether the **Layout** tab renders.
pub fn hasFreeLayout(graph: *const Graph) bool {
    return graph.layout.placements.len > 0 or graph.layout.rows.len > 0 or graph.layout.edges.len > 0;
}

const Cell = struct { col: i32, row: i32 };

/// Assign every `(row …)` band to absolute cells: row *r*'s members land on row
/// *r*, columns 0,1,2,… in list order. Runs before `resolvePlacements`, so a
/// later `(place …)` can still anchor off a row-placed block. A member key that
/// matches no node is skipped but still consumes its column, keeping the band's
/// remaining blocks aligned.
fn resolveRows(graph: *const Graph, cell_of: []Cell, placed: []bool) void {
    for (graph.layout.rows, 0..) |band, ri| {
        var col: i32 = 0;
        for (band.members) |name| {
            if (nodeByKey(graph, name)) |gi| {
                if (!placed[gi]) {
                    cell_of[gi] = .{ .col = col, .row = @intCast(ri) };
                    placed[gi] = true;
                }
            }
            col += 1;
        }
    }
}

/// Resolve `(place …)` directives into absolute cells. `cell_of[i]` is node i's
/// cell once resolved; `placed[i]` marks it. A placement with no constraints is
/// a pinned anchor; one with constraints resolves only when *every* block it
/// references is already placed — so a block can be positioned by several
/// neighbours at once (e.g. `(right-of "a") (below "b")` takes its column from a
/// and its row from b). Horizontal constraints (right/left) drive the column,
/// vertical (above/below) the row; the last of each axis wins. The sweep runs to
/// a fixed point (≤ placements.len passes resolves any acyclic dependency
/// graph), so a directive whose references resolve later still lands. A
/// placement referencing an unknown block, or stuck in a cycle, never resolves →
/// caller flows it into the fallback row.
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
        if (p.constraints.len != 0) continue;
        const gi = nodeByKey(graph, p.name) orelse continue;
        if (placed[gi]) continue;
        cell_of[gi] = .{ .col = next_anchor_col, .row = 0 };
        placed[gi] = true;
        next_anchor_col += anchor_col_stride;
    }
    // Constrained placements: sweep until no further progress.
    var pass: usize = 0;
    while (pass <= ps.len) : (pass += 1) {
        var progressed = false;
        for (ps) |p| {
            if (p.constraints.len == 0) continue;
            const gi = nodeByKey(graph, p.name) orelse continue;
            if (placed[gi]) continue;
            if (resolveConstraints(graph, p.constraints, cell_of, placed)) |cell| {
                cell_of[gi] = cell;
                placed[gi] = true;
                progressed = true;
            }
        }
        if (!progressed) break;
    }
}

/// True when `gid` is named by any `(edge …)` directive — such blocks are
/// excluded from the content-bounds scan so they don't push the edge columns out.
fn isEdgePinned(graph: *const Graph, gid: u32) bool {
    for (graph.layout.edges) |e| {
        for (e.members) |name| {
            if (nodeByKey(graph, name)) |g| if (g == gid) return true;
        }
    }
    return false;
}

/// Pin each `(edge …)` directive's blocks to a column just outside everything
/// else: left-edge blocks one column left of the leftmost content, right-edge
/// blocks one column right of the rightmost. Members stack vertically, centered
/// on the content's row span. Runs last so the edges hold regardless of the
/// relative/row placement between them.
fn resolveEdges(graph: *const Graph, cell_of: []Cell, placed: []bool) void {
    if (graph.layout.edges.len == 0) return;
    var min_col: i32 = std.math.maxInt(i32);
    var max_col: i32 = std.math.minInt(i32);
    var min_row: i32 = std.math.maxInt(i32);
    var max_row: i32 = std.math.minInt(i32);
    var any = false;
    for (graph.nodes, 0..) |_, i| {
        if (!placed[i]) continue;
        if (isEdgePinned(graph, @intCast(i))) continue;
        any = true;
        min_col = @min(min_col, cell_of[i].col);
        max_col = @max(max_col, cell_of[i].col);
        min_row = @min(min_row, cell_of[i].row);
        max_row = @max(max_row, cell_of[i].row);
    }
    if (!any) {
        min_col = 0;
        max_col = 0;
        min_row = 0;
        max_row = 0;
    }
    const center = @divFloor(min_row + max_row, 2);
    for (graph.layout.edges) |e| {
        const col: i32 = if (e.side == .left) min_col - 1 else max_col + 1;
        const k: i32 = @intCast(e.members.len);
        var i: i32 = 0;
        for (e.members) |name| {
            const gid = nodeByKey(graph, name) orelse continue;
            cell_of[gid] = .{ .col = col, .row = center - @divFloor(k - 1, 2) + i };
            placed[gid] = true;
            i += 1;
        }
    }
}

/// Combine a placement's constraints into one cell, or null if any referenced
/// block isn't placed yet (so the caller retries next sweep) or every reference
/// is unknown (so it never resolves → fallback row). Each constraint offsets the
/// cell of its reference by one step; a horizontal constraint (right/left) owns
/// the column, a vertical one (above/below) owns the row — so two constraints on
/// different axes pin both independently. An axis with *no* owning constraint
/// inherits from the last constraint's offset, so a lone `(right-of "a")` keeps
/// a's row (and `(below "b")` keeps b's column) — single-reference behaviour.
fn resolveConstraints(
    graph: *const Graph,
    constraints: []const env_mod.PlaceConstraint,
    cell_of: []const Cell,
    placed: []const bool,
) ?Cell {
    var col: ?i32 = null;
    var row: ?i32 = null;
    var last: ?Cell = null; // last resolved constraint's full offset (axis fallback)
    for (constraints) |con| {
        const ri = nodeByKey(graph, con.reference) orelse continue; // unknown ref: ignore
        if (!placed[ri]) return null; // a real reference isn't ready yet → retry
        const off = offsetCell(cell_of[ri], con.rel);
        last = off;
        switch (con.rel) {
            .right_of, .left_of => col = off.col,
            .above, .below => row = off.row,
        }
    }
    const base = last orelse return null; // every reference was unknown
    return .{ .col = col orelse base.col, .row = row orelse base.row };
}

/// Offset a reference cell by one step in the constraint's direction.
fn offsetCell(ref: Cell, rel: env_mod.PlaceRel) Cell {
    return switch (rel) {
        .right_of => .{ .col = ref.col + 1, .row = ref.row },
        .left_of => .{ .col = ref.col - 1, .row = ref.row },
        .above => .{ .col = ref.col, .row = ref.row - 1 },
        .below => .{ .col = ref.col, .row = ref.row + 1 },
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
    if (graph.layout.placements.len == 0 and graph.layout.rows.len == 0 and graph.layout.edges.len == 0) return null;
    const n = graph.nodes.len;
    const cell_of = try arena.alloc(Cell, n);
    const placed = try arena.alloc(bool, n);
    @memset(placed, false);
    resolveRows(graph, cell_of, placed);
    resolvePlacements(graph, cell_of, placed);
    resolveEdges(graph, cell_of, placed);

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
    // Reserve room at the top for the tallest stacked block's offset cards +
    // its "×N" badge, which extend above the front box. The whole layout shifts
    // down by this so nothing clips the canvas top.
    var top_reserve: f64 = 0;
    for (graph.nodes) |nd| {
        if (nd.stack > 1) top_reserve = @max(top_reserve, stackTopExtent(nd.stack));
    }
    // With `(group …)` boxes present, reserve a left margin (so a group's left
    // padding doesn't clip the canvas) and a top margin (for the group label).
    const has_groups = graph.layout.groups.len > 0;
    const gx: f64 = if (has_groups) group_pad else 0;
    const gy: f64 = if (has_groups) group_label_h else 0;
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
        const x = pad + gx + @as(f64, @floatFromInt(col)) * (node_w + free_h_gap);
        const y = pad + top_reserve + gy + @as(f64, @floatFromInt(row)) * (node_h + free_v_gap);
        try lnodes.append(arena, .{ .gid = @intCast(i), .x = x, .y = y });
        // A stacked block's cards extend right by (stack-1)*offset.
        const right_extent: f64 = if (nd.stack > 1)
            @as(f64, @floatFromInt(nd.stack - 1)) * stack_card_offset
        else
            0;
        max_x = @max(max_x, x + node_w + right_extent);
        max_y = @max(max_y, y + node_h);
    }
    if (lnodes.items.len == 0) return null;

    const nodes = try lnodes.toOwnedSlice(arena);
    const groups = try computeGroupBoxes(arena, graph, nodes);
    for (groups) |gb| {
        max_x = @max(max_x, gb.x + gb.w);
        max_y = @max(max_y, gb.y + gb.h);
    }
    const gobs = try collectGroupObstacles(arena, graph, nodes);
    const routes = try routeFreeEdges(arena, graph, nodes, gobs);
    return .{
        .nodes = nodes,
        .routes = routes,
        .width = max_x + pad,
        .height = max_y + pad,
        .groups = groups,
    };
}

/// The **Groups** view: the free-layout group boxes with the individual blocks
/// removed, plus one synthetic connector per pair of groups that any net crosses
/// (deduplicated, drawn centroid-to-centroid). Reuses `computeFreeLayout` so the
/// boxes keep their Layout-view positions. Returns null when no groups exist.
///
/// `base.groups` indices are NOT `graph.layout.groups` indices — empty groups
/// are dropped by `computeGroupBoxes` — so boxes are keyed by `color_idx`, which
/// `computeGroupBoxes` set to the original group index.
pub fn computeGroupsLayout(arena: Allocator, graph: *const Graph) Allocator.Error!?Layout {
    const base = (try computeFreeLayout(arena, graph)) orelse return null;
    if (base.groups.len == 0) return null;

    // gid → original group index (first declaring group wins).
    var gid_group: std.AutoHashMapUnmanaged(u32, usize) = .{};
    for (graph.layout.groups, 0..) |g, gi| {
        for (g.members) |name| {
            if (nodeByKey(graph, name)) |gid| {
                const gop = try gid_group.getOrPut(arena, gid);
                if (!gop.found_existing) gop.value_ptr.* = gi;
            }
        }
    }
    // original group index → its drawn box (only groups that survived).
    var box_of: std.AutoHashMapUnmanaged(usize, GroupBox) = .{};
    for (base.groups) |gb| try box_of.put(arena, gb.color_idx, gb);

    var routes: std.ArrayListUnmanaged(Route) = .empty;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .{};
    for (graph.edges) |e| {
        if (e.from == e.to) continue;
        const fg = gid_group.get(e.from) orelse continue;
        const tg = gid_group.get(e.to) orelse continue;
        if (fg == tg) continue;
        const lo = @min(fg, tg);
        const hi = @max(fg, tg);
        const key = (@as(u64, lo) << 32) | @as(u64, hi);
        if ((try seen.getOrPut(arena, key)).found_existing) continue;
        const ba = box_of.get(lo) orelse continue;
        const bb = box_of.get(hi) orelse continue;
        const pts = try arena.alloc(Pt, 2);
        pts[0] = .{ .x = ba.x + ba.w / 2, .y = ba.y + ba.h / 2 };
        pts[1] = .{ .x = bb.x + bb.w / 2, .y = bb.y + bb.h / 2 };
        try routes.append(arena, .{
            .from_gid = @intCast(lo),
            .to_gid = @intCast(hi),
            .class = e.class,
            .label = "",
            .voltage = e.voltage,
            .fanout = e.fanout,
            .pts = pts,
            .arrow_at_start = false,
        });
    }
    return .{
        .nodes = &.{},
        .routes = try routes.toOwnedSlice(arena),
        .width = base.width,
        .height = base.height,
        .groups = base.groups,
    };
}

/// One LNode by graph id, or null when not laid out.
fn lnodeOf(nodes: []const LNode, gid: u32) ?LNode {
    for (nodes) |ln| if (ln.gid == gid) return ln;
    return null;
}

/// Build a `GroupBox` per `(group …)`: the padded bounding box of its placed
/// members (counting a stacked block's rear-card extents), with a top strip for
/// the label. Groups whose members are all missing are dropped.
fn computeGroupBoxes(arena: Allocator, graph: *const Graph, nodes: []const LNode) Allocator.Error![]const GroupBox {
    if (graph.layout.groups.len == 0) return &.{};
    var out: std.ArrayListUnmanaged(GroupBox) = .empty;
    for (graph.layout.groups, 0..) |g, gi| {
        var minx: f64 = std.math.floatMax(f64);
        var miny: f64 = std.math.floatMax(f64);
        var maxx: f64 = -std.math.floatMax(f64);
        var maxy: f64 = -std.math.floatMax(f64);
        var any = false;
        for (g.members) |name| {
            const id = nodeByKey(graph, name) orelse continue;
            const ln = lnodeOf(nodes, id) orelse continue;
            const nd = graph.nodes[id];
            const right_extent: f64 = if (nd.stack > 1)
                @as(f64, @floatFromInt(nd.stack - 1)) * stack_card_offset
            else
                0;
            const top_extent: f64 = if (nd.stack > 1) stackTopExtent(nd.stack) else 0;
            minx = @min(minx, ln.x);
            miny = @min(miny, ln.y - top_extent);
            maxx = @max(maxx, ln.x + node_w + right_extent);
            maxy = @max(maxy, ln.y + node_h);
            any = true;
        }
        if (!any) continue;
        try out.append(arena, .{
            .label = g.label,
            .x = minx - group_pad,
            .y = miny - group_label_h,
            .w = (maxx - minx) + 2 * group_pad,
            .h = (maxy - miny) + group_label_h + group_pad,
            .color_idx = gi,
        });
    }
    return out.toOwnedSlice(arena);
}

/// How far a stacked block's rearmost card + its "×N" badge reach above the
/// front box's top — kept in sync with render.zig's `stack_offset` /
/// `stack_badge_gap` and the badge font height.
fn stackTopExtent(stack: u8) f64 {
    return @as(f64, @floatFromInt(stack - 1)) * stack_card_offset + stack_badge_h;
}

// ── Free Layout view: obstacle-aware orthogonal edge routing ─────────────
//
// The author places the blocks; the router connects them with right-angle wires
// that (a) never cross a `(group …)` box neither endpoint belongs to, (b) never
// run through another block, and (c) spread across parallel gap-lanes so wires
// sharing a corridor don't overlap. A direct one-jog path is taken whenever it
// is already clear; otherwise the wire detours through the nearest gap channel
// (a row/column gap, or the perimeter ring around everything) whose staircase
// clears every foreign group.

/// An axis-aligned obstacle rectangle in layout pixels.
const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// A `(group …)` box plus the gids it contains — an obstacle for every edge
/// with neither endpoint inside it.
const GroupObs = struct { box: Rect, members: []const u32 };

const route_clear: f64 = 6; // margin a wire keeps off a block it merely passes
const lane_gap: f64 = 9; // perpendicular spacing between wires sharing a lane

fn nodeRect(x: f64, y: f64) Rect {
    return .{ .x0 = x, .y0 = y, .x1 = x + node_w, .y1 = y + node_h };
}

fn inflateRect(r: Rect, m: f64) Rect {
    return .{ .x0 = r.x0 - m, .y0 = r.y0 - m, .x1 = r.x1 + m, .y1 = r.y1 + m };
}

/// True when the axis-aligned segment a→b overlaps `r`'s interior. For an
/// orthogonal segment the segment's bounding box is the segment itself, so a
/// box-overlap test is exact.
fn segHitsRect(ax: f64, ay: f64, bx: f64, by: f64, r: Rect) bool {
    return @max(ax, bx) > r.x0 and @min(ax, bx) < r.x1 and
        @max(ay, by) > r.y0 and @min(ay, by) < r.y1;
}

fn segHitsAny(ax: f64, ay: f64, bx: f64, by: f64, obs: []const Rect) bool {
    for (obs) |r| if (segHitsRect(ax, ay, bx, by, r)) return true;
    return false;
}

/// True when any segment of the polyline `pts` hits any obstacle.
fn pathHitsAny(pts: []const Pt, obs: []const Rect) bool {
    var i: usize = 0;
    while (i + 1 < pts.len) : (i += 1) {
        if (segHitsAny(pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y, obs)) return true;
    }
    return false;
}

fn memberOf(members: []const u32, gid: u32) bool {
    for (members) |m| if (m == gid) return true;
    return false;
}

/// The padded box + member gids of each declared `(group …)`, mirroring the
/// geometry `computeGroupBoxes` draws so wires dodge the visible box.
fn collectGroupObstacles(arena: Allocator, graph: *const Graph, nodes: []const LNode) Allocator.Error![]GroupObs {
    if (graph.layout.groups.len == 0) return &.{};
    var out: std.ArrayListUnmanaged(GroupObs) = .empty;
    for (graph.layout.groups) |g| {
        var minx: f64 = std.math.floatMax(f64);
        var miny: f64 = std.math.floatMax(f64);
        var maxx: f64 = -std.math.floatMax(f64);
        var maxy: f64 = -std.math.floatMax(f64);
        var members: std.ArrayListUnmanaged(u32) = .empty;
        for (g.members) |name| {
            const id = nodeByKey(graph, name) orelse continue;
            const ln = lnodeOf(nodes, id) orelse continue;
            const nd = graph.nodes[id];
            const re: f64 = if (nd.stack > 1) @as(f64, @floatFromInt(nd.stack - 1)) * stack_card_offset else 0;
            const te: f64 = if (nd.stack > 1) stackTopExtent(nd.stack) else 0;
            minx = @min(minx, ln.x);
            miny = @min(miny, ln.y - te);
            maxx = @max(maxx, ln.x + node_w + re);
            maxy = @max(maxy, ln.y + node_h);
            try members.append(arena, id);
        }
        if (members.items.len == 0) continue;
        try out.append(arena, .{
            .box = .{ .x0 = minx - group_pad, .y0 = miny - group_label_h, .x1 = maxx + group_pad, .y1 = maxy + group_pad },
            .members = try members.toOwnedSlice(arena),
        });
    }
    return out.toOwnedSlice(arena);
}

/// De-duplicated gap-channel coordinates: the perimeter just outside the first
/// block, plus the gap past every distinct column (`vertical`) or row.
fn channelCoords(arena: Allocator, nodes: []const LNode, vertical: bool) Allocator.Error![]f64 {
    const span: f64 = if (vertical) free_h_gap else free_v_gap;
    const box: f64 = if (vertical) node_w else node_h;
    var list: std.ArrayListUnmanaged(f64) = .empty;
    var mn: f64 = std.math.floatMax(f64);
    for (nodes) |ln| mn = @min(mn, if (vertical) ln.x else ln.y);
    try pushUnique(arena, &list, mn - span / 2);
    for (nodes) |ln| try pushUnique(arena, &list, (if (vertical) ln.x else ln.y) + box + span / 2);
    return list.toOwnedSlice(arena);
}

fn pushUnique(arena: Allocator, list: *std.ArrayListUnmanaged(f64), v: f64) Allocator.Error!void {
    for (list.items) |e| if (@abs(e - v) < 1) return;
    try list.append(arena, v);
}

/// The channel coordinate just outside `edge` on the `toward_plus` side; falls
/// back to `edge + fallback` when no channel lies that way.
fn channelBeside(chans: []const f64, edge: f64, toward_plus: bool, fallback: f64) f64 {
    var best: f64 = 0;
    var found = false;
    for (chans) |c| {
        const ok = if (toward_plus) c > edge + 1 else c < edge - 1;
        if (!ok) continue;
        const better = if (toward_plus) c < best else c > best;
        if (!found or better) {
            best = c;
            found = true;
        }
    }
    return if (found) best else edge + fallback;
}

/// Lane bookkeeping: the running count for `key`, then incremented.
fn bumpLane(arena: Allocator, map: *std.AutoHashMapUnmanaged(i64, u16), key: i64) Allocator.Error!u16 {
    const gop = try map.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = 0;
    const n = gop.value_ptr.*;
    gop.value_ptr.* = n + 1;
    return n;
}

/// Symmetric lane spread for the n-th wire sharing a corridor: 0, +g, −g, +2g…
fn laneDelta(n: u16) f64 {
    const step: f64 = @floatFromInt((n + 1) / 2);
    const sign: f64 = if (n % 2 == 1) 1.0 else -1.0;
    return sign * step * lane_gap;
}

/// Fanned attachment point along a box face for the n-th wire on that side,
/// spread symmetrically around the middle and clamped off the corners.
fn faceFrac(n: u16) f64 {
    const step: f64 = @floatFromInt((n + 1) / 2);
    const sign: f64 = if (n % 2 == 1) 1.0 else -1.0;
    return std.math.clamp(0.5 + sign * step * 0.16, 0.14, 0.86);
}

fn sideKey(gid: u32, side: u8) i64 {
    return @as(i64, gid) * 4 + side;
}

/// Drop duplicate and colinear interior points so the path has clean corners.
fn collapsePts(arena: Allocator, raw: []const Pt) Allocator.Error![]Pt {
    var out: std.ArrayListUnmanaged(Pt) = .empty;
    for (raw) |p| {
        if (out.items.len > 0) {
            const last = out.items[out.items.len - 1];
            if (@abs(last.x - p.x) < 0.5 and @abs(last.y - p.y) < 0.5) continue;
        }
        try out.append(arena, p);
    }
    var i: usize = 1;
    while (i + 1 < out.items.len) {
        const a = out.items[i - 1];
        const b = out.items[i];
        const c = out.items[i + 1];
        const colinear = (@abs(a.x - b.x) < 0.5 and @abs(b.x - c.x) < 0.5) or
            (@abs(a.y - b.y) < 0.5 and @abs(b.y - c.y) < 0.5);
        if (colinear) _ = out.orderedRemove(i) else i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// The horizontal channel y nearest `pref` whose staircase (drop at vxA, run to
/// vxB, drop to the target face) clears every obstacle; null when none does.
fn clearHy(hys: []const f64, vxa: f64, vxb: f64, ay: f64, by: f64, pref: f64, obs: []const Rect) ?f64 {
    var best: ?f64 = null;
    var bestd: f64 = std.math.floatMax(f64);
    for (hys) |hy| {
        if (segHitsAny(vxa, ay, vxa, hy, obs)) continue;
        if (segHitsAny(vxa, hy, vxb, hy, obs)) continue;
        if (segHitsAny(vxb, hy, vxb, by, obs)) continue;
        const d = @abs(hy - pref);
        if (d < bestd) {
            bestd = d;
            best = hy;
        }
    }
    return best;
}

/// Vertical-channel twin of `clearHy`.
fn clearVx(vxs: []const f64, hya: f64, hyb: f64, ax: f64, bx: f64, pref: f64, obs: []const Rect) ?f64 {
    var best: ?f64 = null;
    var bestd: f64 = std.math.floatMax(f64);
    for (vxs) |vx| {
        if (segHitsAny(ax, hya, vx, hya, obs)) continue;
        if (segHitsAny(vx, hya, vx, hyb, obs)) continue;
        if (segHitsAny(vx, hyb, bx, hyb, obs)) continue;
        const d = @abs(vx - pref);
        if (d < bestd) {
            bestd = d;
            best = vx;
        }
    }
    return best;
}

/// Build the orthogonal polyline for one edge: a direct jog when clear, else a
/// staircase through the nearest obstacle-free gap channel.
fn buildFreeRoute(
    arena: Allocator,
    ends: [4]f64, // ax, ay, bx, by (top-left of each box)
    ids: [2]u32, // from, to
    obs: []const Rect,
    chans: [2][]const f64, // vxs, hys
    maps: [3]*std.AutoHashMapUnmanaged(i64, u16), // side, h-lane, v-lane
) Allocator.Error![]Pt {
    const ax = ends[0];
    const ay = ends[1];
    const bx = ends[2];
    const by = ends[3];
    const horizontal = @abs((bx - ax)) >= @abs((by - ay));
    if (horizontal) {
        const right = bx >= ax;
        const sa: u8 = if (right) side_r else side_l;
        const ta: u8 = if (right) side_l else side_r;
        const ea = portPoint(ax, ay, sa, faceFrac(try bumpLane(arena, maps[0], sideKey(ids[0], sa))));
        const eb = portPoint(bx, by, ta, faceFrac(try bumpLane(arena, maps[0], sideKey(ids[1], ta))));
        var simple = [_]Pt{ ea, .{ .x = (ea.x + eb.x) / 2, .y = ea.y }, .{ .x = (ea.x + eb.x) / 2, .y = eb.y }, eb };
        if (!pathHitsAny(&simple, obs)) return collapsePts(arena, &simple);
        const vxa = channelBeside(chans[0], if (right) ax + node_w else ax, right, if (right) free_h_gap / 2 else -free_h_gap / 2);
        const vxb = channelBeside(chans[0], if (right) bx else bx + node_w, !right, if (right) -free_h_gap / 2 else free_h_gap / 2);
        const hy0 = clearHy(chans[1], vxa, vxb, ea.y, eb.y, (ea.y + eb.y) / 2, obs) orelse return collapsePts(arena, &simple);
        const hy = hy0 + laneDelta(try bumpLane(arena, maps[1], @intFromFloat(@round(hy0 / 4))));
        const stair = [_]Pt{ ea, .{ .x = vxa, .y = ea.y }, .{ .x = vxa, .y = hy }, .{ .x = vxb, .y = hy }, .{ .x = vxb, .y = eb.y }, eb };
        return collapsePts(arena, &stair);
    }
    const down = by >= ay;
    const sa: u8 = if (down) side_b else side_t;
    const ta: u8 = if (down) side_t else side_b;
    const ea = portPoint(ax, ay, sa, faceFrac(try bumpLane(arena, maps[0], sideKey(ids[0], sa))));
    const eb = portPoint(bx, by, ta, faceFrac(try bumpLane(arena, maps[0], sideKey(ids[1], ta))));
    var simple = [_]Pt{ ea, .{ .x = ea.x, .y = (ea.y + eb.y) / 2 }, .{ .x = eb.x, .y = (ea.y + eb.y) / 2 }, eb };
    if (!pathHitsAny(&simple, obs)) return collapsePts(arena, &simple);
    const hya = channelBeside(chans[1], if (down) ay + node_h else ay, down, if (down) free_v_gap / 2 else -free_v_gap / 2);
    const hyb = channelBeside(chans[1], if (down) by else by + node_h, !down, if (down) -free_v_gap / 2 else free_v_gap / 2);
    const vx0 = clearVx(chans[0], hya, hyb, ea.x, eb.x, (ea.x + eb.x) / 2, obs) orelse return collapsePts(arena, &simple);
    const vx = vx0 + laneDelta(try bumpLane(arena, maps[2], @intFromFloat(@round(vx0 / 4))));
    const stair = [_]Pt{ ea, .{ .x = ea.x, .y = hya }, .{ .x = vx, .y = hya }, .{ .x = vx, .y = hyb }, .{ .x = eb.x, .y = hyb }, eb };
    return collapsePts(arena, &stair);
}

/// Route every placed edge as an obstacle-aware orthogonal polyline (see the
/// section header above). Foreign `(group …)` boxes and other blocks are
/// obstacles; the author's own endpoints' groups are not.
fn routeFreeEdges(arena: Allocator, graph: *const Graph, nodes: []const LNode, gobs: []const GroupObs) Allocator.Error![]Route {
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
    const vxs = try channelCoords(arena, nodes, true);
    const hys = try channelCoords(arena, nodes, false);
    var sidemap: std.AutoHashMapUnmanaged(i64, u16) = .{};
    var hmap: std.AutoHashMapUnmanaged(i64, u16) = .{};
    var vmap: std.AutoHashMapUnmanaged(i64, u16) = .{};
    var routes: std.ArrayListUnmanaged(Route) = .empty;
    for (graph.edges) |e| {
        if (e.from == e.to) continue;
        if (!present[e.from] or !present[e.to]) continue;
        var obs: std.ArrayListUnmanaged(Rect) = .empty;
        for (gobs) |g| {
            if (!memberOf(g.members, e.from) and !memberOf(g.members, e.to)) try obs.append(arena, g.box);
        }
        for (nodes) |ln| {
            if (ln.gid != e.from and ln.gid != e.to) try obs.append(arena, inflateRect(nodeRect(ln.x, ln.y), route_clear));
        }
        const pts = try buildFreeRoute(
            arena,
            .{ px[e.from], py[e.from], px[e.to], py[e.to] },
            .{ e.from, e.to },
            obs.items,
            .{ vxs, hys },
            .{ &sidemap, &hmap, &vmap },
        );
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
    // Constraint arrays are stack consts so the slices stay valid for the call.
    const c_below_b = [_]env_mod.PlaceConstraint{.{ .rel = .below, .reference = "b" }};
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const placements = [_]env_mod.Placement{
        .{ .name = "a" }, // anchor: no constraints
        // declared out of dependency order: c depends on b, b depends on a.
        .{ .name = "c", .constraints = &c_below_b },
        .{ .name = "b", .constraints = &b_right_a },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &.{}, .layout = .{ .placements = &placements } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), lay.nodes.len);
    const xy = nodeXY(lay.nodes);
    // a at origin cell; b one column right of a (same row); c one row below b.
    try testing.expectApproxEqAbs(xy[0].x + node_w + free_h_gap, xy[1].x, 0.5);
    try testing.expectApproxEqAbs(xy[0].y, xy[1].y, 0.5);
    try testing.expectApproxEqAbs(xy[1].x, xy[2].x, 0.5);
    try testing.expect(xy[2].y > xy[1].y);
}

// spec: diagram/layout - computeFreeLayout positions a block from several references at once
test "computeFreeLayout places a block from two references" {
    // c takes its column from b (right-of) and its row from a (below): the
    // recursive multi-reference case — c is pinned by two different neighbours.
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b"), mkKeyed("c") };
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const c_two = [_]env_mod.PlaceConstraint{
        .{ .rel = .right_of, .reference = "b" },
        .{ .rel = .below, .reference = "a" },
    };
    const placements = [_]env_mod.Placement{
        .{ .name = "a" },
        .{ .name = "b", .constraints = &b_right_a }, // one col right of a, same row
        .{ .name = "c", .constraints = &c_two },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &.{}, .layout = .{ .placements = &placements } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    const xy = nodeXY(lay.nodes);
    // c's column == right-of b == b.x + one step; c's row == below a == a.y + one step.
    try testing.expectApproxEqAbs(xy[1].x + node_w + free_h_gap, xy[2].x, 0.5);
    try testing.expect(xy[2].y > xy[0].y);
    try testing.expectApproxEqAbs(xy[0].y + node_h + free_v_gap, xy[2].y, 0.5);
}

// spec: diagram/layout - computeFreeLayout lays each layout row as a horizontal band, stacking bands top-to-bottom
test "computeFreeLayout bands rows top-to-bottom" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b"), mkKeyed("c") };
    const r0 = [_][]const u8{ "a", "b" };
    const r1 = [_][]const u8{"c"};
    const rows = [_]env_mod.LayoutRow{ .{ .members = &r0 }, .{ .members = &r1 } };
    const graph = Graph{ .nodes = &nodes, .edges = &.{}, .layout = .{ .rows = &rows } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    const xy = nodeXY(lay.nodes);
    // a and b share the top band (same y); b is one column right of a.
    try testing.expectApproxEqAbs(xy[0].y, xy[1].y, 0.5);
    try testing.expectApproxEqAbs(xy[0].x + node_w + free_h_gap, xy[1].x, 0.5);
    // c sits in the band one row below a, in the same (leftmost) column.
    try testing.expectApproxEqAbs(xy[0].x, xy[2].x, 0.5);
    try testing.expectApproxEqAbs(xy[0].y + node_h + free_v_gap, xy[2].y, 0.5);
}

// spec: diagram/layout - computeFreeLayout boxes each layout group around its members with a labeled top strip
test "computeFreeLayout boxes a layout group around its members" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b") };
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const placements = [_]env_mod.Placement{ .{ .name = "a" }, .{ .name = "b", .constraints = &b_right_a } };
    const members = [_][]const u8{ "a", "b" };
    const groups = [_]env_mod.LayoutGroup{.{ .label = "Pair", .members = &members }};
    const graph = Graph{ .nodes = &nodes, .edges = &.{}, .layout = .{ .placements = &placements, .groups = &groups } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), lay.groups.len);
    const g = lay.groups[0];
    try testing.expectEqualStrings("Pair", g.label);
    const xy = nodeXY(lay.nodes);
    // The box wraps both nodes: left of a, above a (label strip), right of b's far edge.
    try testing.expect(g.x < xy[0].x);
    try testing.expect(g.y < xy[0].y);
    try testing.expect(g.x + g.w > xy[1].x + node_w);
    try testing.expect(g.y + g.h > xy[0].y + node_h);
}

// spec: diagram/layout - computeFreeLayout routes each edge as an orthogonal polyline around any group box neither endpoint belongs to
test "computeFreeLayout routes an edge around a foreign group" {
    // a — b — c in a row; b alone is boxed in group "G". The a→c wire would run
    // straight through G, so the router must detour around G's box.
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b"), mkKeyed("c") };
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const c_right_b = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "b" }};
    const placements = [_]env_mod.Placement{
        .{ .name = "a" },
        .{ .name = "b", .constraints = &b_right_a },
        .{ .name = "c", .constraints = &c_right_b },
    };
    const gmem = [_][]const u8{"b"};
    const groups = [_]env_mod.LayoutGroup{.{ .label = "G", .members = &gmem }};
    var edges = [_]types.Edge{.{ .from = 0, .to = 2, .class = types.CLASS_CONTROL, .label = "x" }};
    const graph = Graph{ .nodes = &nodes, .edges = &edges, .layout = .{ .placements = &placements, .groups = &groups } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), lay.routes.len);
    try testing.expectEqual(@as(usize, 1), lay.groups.len);
    const r = lay.routes[0];
    const g = lay.groups[0];
    try testing.expect(r.pts.len >= 2);
    try expectRouteOrthAndClear(r, g);
}

/// Assert every segment of route `r` is axis-aligned and none crosses box `g`.
/// A free function (not a test) so the loop stays out of the test body.
fn expectRouteOrthAndClear(r: Route, g: GroupBox) !void {
    var i: usize = 0;
    while (i + 1 < r.pts.len) : (i += 1) {
        const same_x = @abs(r.pts[i].x - r.pts[i + 1].x) < 0.6;
        const same_y = @abs(r.pts[i].y - r.pts[i + 1].y) < 0.6;
        try testing.expect(same_x or same_y);
        const sx0 = @min(r.pts[i].x, r.pts[i + 1].x);
        const sx1 = @max(r.pts[i].x, r.pts[i + 1].x);
        const sy0 = @min(r.pts[i].y, r.pts[i + 1].y);
        const sy1 = @max(r.pts[i].y, r.pts[i + 1].y);
        try testing.expect(!(sx1 > g.x and sx0 < g.x + g.w and sy1 > g.y and sy0 < g.y + g.h));
    }
}

// spec: diagram/layout - computeFreeLayout spreads wires sharing a corridor into parallel lanes instead of overlapping
test "computeFreeLayout lanes parallel wires apart" {
    // Two edges both run a→c around the same group, so they share a detour
    // corridor; their traversal bands must land on different y's.
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b"), mkKeyed("c") };
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const c_right_b = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "b" }};
    const placements = [_]env_mod.Placement{
        .{ .name = "a" },
        .{ .name = "b", .constraints = &b_right_a },
        .{ .name = "c", .constraints = &c_right_b },
    };
    const gmem = [_][]const u8{"b"};
    const groups = [_]env_mod.LayoutGroup{.{ .label = "G", .members = &gmem }};
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 2, .class = types.CLASS_CONTROL, .label = "x" },
        .{ .from = 0, .to = 2, .class = types.CLASS_RF, .label = "y" },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges, .layout = .{ .placements = &placements, .groups = &groups } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), lay.routes.len);
    // The two detours pick distinct horizontal bands (their middle segment y differs).
    const y0 = lay.routes[0].pts[lay.routes[0].pts.len / 2].y;
    const y1 = lay.routes[1].pts[lay.routes[1].pts.len / 2].y;
    try testing.expect(@abs(y0 - y1) > 1);
}

// spec: diagram/layout - computeGroupsLayout shows only the group boxes with one connector per pair of groups a net crosses, and no individual nodes
test "computeGroupsLayout boxes-only with one connector per crossing pair" {
    // a in group G1; b,c in group G2. Edge a→b crosses groups; edge b→c is
    // within G2. Expect 2 boxes, 0 nodes, exactly 1 inter-group connector.
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b"), mkKeyed("c") };
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const c_right_b = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "b" }};
    const placements = [_]env_mod.Placement{
        .{ .name = "a" },
        .{ .name = "b", .constraints = &b_right_a },
        .{ .name = "c", .constraints = &c_right_b },
    };
    const g1mem = [_][]const u8{"a"};
    const g2mem = [_][]const u8{ "b", "c" };
    const groups = [_]env_mod.LayoutGroup{ .{ .label = "G1", .members = &g1mem }, .{ .label = "G2", .members = &g2mem } };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "x" }, // a→b crosses G1↔G2
        .{ .from = 1, .to = 2, .class = types.CLASS_RF, .label = "y" }, // b→c within G2
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges, .layout = .{ .placements = &placements, .groups = &groups } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeGroupsLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), lay.nodes.len);
    try testing.expectEqual(@as(usize, 2), lay.groups.len);
    try testing.expectEqual(@as(usize, 1), lay.routes.len); // only the crossing pair
}

// spec: diagram/layout - computeFreeLayout pins edge-directive blocks to the column just outside the rest of the content
test "computeFreeLayout pins edge blocks to the outer columns" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("b"), mkKeyed("L"), mkKeyed("R") };
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const placements = [_]env_mod.Placement{ .{ .name = "a" }, .{ .name = "b", .constraints = &b_right_a } };
    const lmem = [_][]const u8{"L"};
    const rmem = [_][]const u8{"R"};
    const edges = [_]env_mod.LayoutEdge{
        .{ .side = .left, .members = &lmem },
        .{ .side = .right, .members = &rmem },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &.{}, .layout = .{ .placements = &placements, .edges = &edges } };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeFreeLayout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    const xy = nodeXY(lay.nodes);
    // L is left of the content (a,b); R is right of all of it.
    try testing.expect(xy[2].x < xy[0].x); // L left of a
    try testing.expect(xy[3].x > xy[1].x); // R right of b
}

// spec: diagram/layout - computeFreeLayout flows un-placed blocks into a fallback row below the placed cluster
test "computeFreeLayout flows an un-placed block into the fallback row" {
    var nodes = [_]types.Node{ mkKeyed("a"), mkKeyed("orphan") };
    const placements = [_]env_mod.Placement{.{ .name = "a" }};
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
    const b_right_ghost = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "ghost" }};
    const placements = [_]env_mod.Placement{
        .{ .name = "a" },
        .{ .name = "b", .constraints = &b_right_ghost }, // no such block
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
    const a_right_b = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "b" }};
    const b_right_a = [_]env_mod.PlaceConstraint{.{ .rel = .right_of, .reference = "a" }};
    const placements = [_]env_mod.Placement{
        .{ .name = "a", .constraints = &a_right_b },
        .{ .name = "b", .constraints = &b_right_a },
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

// spec: diagram/layout - Signal Chain layout orders blocks by declared narrative stage instead of category
test "computeChainLayout orders blocks by declared narrative stage" {
    // Declare a chain B → A → C — NOT the nodes' gid/category order — so the
    // narrative ranking, not the layout default, must drive the columns.
    var a = mkNode("A");
    var b = mkNode("B");
    var c = mkNode("C");
    a.force_show = true;
    b.force_show = true;
    c.force_show = true;
    var nodes = [_]types.Node{ a, b, c };
    const graph = Graph{ .nodes = &nodes, .edges = &.{} };
    const m_b = [_][]const u8{"B"};
    const m_a = [_][]const u8{"A"};
    const m_c = [_][]const u8{"C"};
    const stage_specs = [_]StageSpec{
        .{ .label = "First", .members = &m_b },
        .{ .label = "Second", .members = &m_a },
        .{ .label = "Third", .members = &m_c },
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeChainLayout(arena.allocator(), &graph, &stage_specs)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), lay.stage_labels.len);
    try testing.expectEqualStrings("First", lay.stage_labels[0]);
    try testing.expectEqualStrings("Third", lay.stage_labels[2]);
    var x_a: f64 = -1;
    var x_b: f64 = -1;
    var x_c: f64 = -1;
    for (lay.nodes) |n| {
        if (n.gid == 0) x_a = n.x;
        if (n.gid == 1) x_b = n.x;
        if (n.gid == 2) x_c = n.x;
    }
    try testing.expect(x_b < x_a); // B (stage 0) sits left of A (stage 1)
    try testing.expect(x_a < x_c); // A (stage 1) sits left of C (stage 2)
}
