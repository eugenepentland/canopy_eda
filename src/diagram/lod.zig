//! Glance (LOD 0) layer for the free Layout view — the top level of semantic
//! zoom. At fit-to-screen the diagram shows only the author's `(group …)`
//! regions, drawn as large solid chips, plus one aggregated connection per
//! group-pair-and-class (width scaling with the number of nets it stands in
//! for). Blocks outside every group keep their own chip so nothing vanishes.
//! The layer is emitted into a `<g class="dg-glance">` sibling of the normal
//! block/wire body (`dg-base`); CSS keyed on the SVG's `data-lod` attribute
//! cross-fades the two as the viewer zooms (see schematic_viewer.js).

const std = @import("std");
const types = @import("types.zig");
const layout = @import("layout.zig");
const rb = @import("../render_block_types.zig");

const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const Writer = std.Io.Writer;

/// Entity a glance chip stands for: one `(group …)` region (with its member
/// node ids) or one ungrouped block promoted to a chip of its own.
pub const Entity = struct {
    label: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    /// Zoom target stamped into the chip's `data-*` attributes: the entity's
    /// ORIGINAL bounds, before the overlap-separation pass moved the chip.
    /// Clicking a chip must zoom to where its member blocks actually are, not
    /// to wherever the chip was pushed.
    zx: f64,
    zy: f64,
    zw: f64,
    zh: f64,
    color: []const u8,
    /// Number of member blocks (1 for a solo chip).
    count: usize,
    /// Up to the first few member labels, for the chip caption. Empty for solo.
    members: []const []const u8,
};

/// Minimum clear gap the separation pass keeps between two glance chips.
const chip_gap: f64 = 28;
/// Pass cap for the push-apart relaxation; real diagrams settle in a handful.
const sep_pass_cap = 256;

/// One aggregated glance edge: every base edge of `class` between the same
/// entity pair collapses into a single line whose `nets` counts the parallel
/// nets (sum of edge fanouts).
const AggEdge = struct {
    a: usize,
    b: usize,
    class: types.ClassId,
    nets: usize,
};

const chip_caption_members = 3;
/// Stroke width = base + gain·√nets, capped — a 16-net ADC bus reads fat but
/// never cartoonish.
const agg_w_base: f64 = 2.5;
const agg_w_gain: f64 = 2.2;
const agg_w_max: f64 = 13;
/// Parallel same-pair edges (different classes) fan out perpendicular by this.
const agg_lane_gap: f64 = 16;
/// Two chips whose projections overlap at least this much connect with a
/// straight face-to-face perpendicular; less and they are corner neighbours.
const min_face_overlap: f64 = 60;
/// The ×N net tag sits this far along the line from the smaller chip's border
/// (that end's gap is the part of the line guaranteed visible), riding beside
/// the stroke by `tag_side`.
const tag_inset: f64 = 34;
const tag_side: f64 = 15;
const tag_stagger: f64 = 30;
/// Chip text sizing: preferred size, the floor it may shrink to before
/// truncation kicks in, and the average glyph width as a fraction of size —
/// one set for the title (sans) and one for the member caption (mono).
const chip_title_fs: f64 = 38;
const chip_title_fs_min: f64 = 16;
const title_char_w: f64 = 0.62;
const chip_sub_fs: f64 = 21;
const chip_sub_fs_min: f64 = 13;
const sub_char_w: f64 = 0.60;

/// Build the glance chips and push overlapping ones apart. A group chip is the
/// raw `(group …)` bounding box, and a group with spatially scattered members
/// produces a huge box that can overlap — or swallow whole — other chips;
/// drawn as-is the glance layer stacks unreadably. Separation moves chips
/// apart along the smaller-overlap axis (half each way) until disjoint; each
/// chip's `z*` zoom target keeps its original bounds. The caller must size the
/// SVG canvas to cover the returned entities, which can end up past the base
/// layout's extent.
pub fn buildGlanceEntities(
    arena: Allocator,
    graph: *const Graph,
    lay: layout.Layout,
    palette: []const []const u8,
) Allocator.Error![]Entity {
    const ents = try buildEntities(arena, graph, lay, palette);
    separateEntities(ents);
    // Keep every chip on-canvas: shift the whole layer right/down when the
    // push-apart drove a chip past the top/left padding.
    var minx: f64 = std.math.floatMax(f64);
    var miny: f64 = std.math.floatMax(f64);
    for (ents) |e| {
        minx = @min(minx, e.x);
        miny = @min(miny, e.y);
    }
    if (ents.len > 0) {
        const dx: f64 = if (minx < layout.pad) layout.pad - minx else 0;
        const dy: f64 = if (miny < layout.pad) layout.pad - miny else 0;
        for (ents) |*e| {
            e.x += dx;
            e.y += dy;
        }
    }
    return ents;
}

/// Push-apart relaxation: any two chips overlapping (or closer than
/// `chip_gap`) on both axes move half the required distance each, along the
/// axis needing the smaller correction. Deterministic (fixed pair order, no
/// randomness) so the same design always renders the same glance layer.
fn separateEntities(ents: []Entity) void {
    var pass: usize = 0;
    while (pass < sep_pass_cap) : (pass += 1) {
        var moved = false;
        for (ents, 0..) |*a, i| {
            for (ents[i + 1 ..]) |*b| {
                const dx = @min(a.x + a.w, b.x + b.w) - @max(a.x, b.x) + chip_gap;
                const dy = @min(a.y + a.h, b.y + b.h) - @max(a.y, b.y) + chip_gap;
                if (dx <= 0 or dy <= 0) continue;
                moved = true;
                if (dx <= dy) {
                    const s: f64 = if (a.x + a.w / 2 <= b.x + b.w / 2) 1 else -1;
                    a.x -= s * dx / 2;
                    b.x += s * dx / 2;
                } else {
                    const s: f64 = if (a.y + a.h / 2 <= b.y + b.h / 2) 1 else -1;
                    a.y -= s * dy / 2;
                    b.y += s * dy / 2;
                }
            }
        }
        if (!moved) return;
    }
}

/// Emit the `<g class="dg-glance">` layer: chips for every entity, aggregated
/// class-colored connections between them, and a ×N net-count tag per line.
/// `ents` comes from `buildGlanceEntities` (chips already separated).
pub fn writeGlanceLayer(
    arena: Allocator,
    w: *Writer,
    graph: *const Graph,
    lay: layout.Layout,
    ents: []const Entity,
) (Allocator.Error || Writer.Error)!void {
    if (ents.len == 0) return;
    const ent_of = try entityOf(arena, graph, lay, ents);
    const aggs = try aggregateEdges(arena, graph, ent_of);
    try w.writeAll("<g class=\"dg-glance\">");
    for (aggs) |agg| try writeAggEdge(w, graph, aggGeometry(ents, aggs, agg), agg);
    for (ents) |e| try writeChip(arena, w, e);
    for (aggs) |agg| try writeAggTag(w, graph, ents, aggs, agg);
    try w.writeAll("</g>");
}

/// Draw the same aggregated group-to-group links the glance layer shows, but at
/// the base layer's *original* group geometry (the `z*` bounds, not the
/// overlap-separated chip positions) — so the coarse connectivity stays visible
/// and aligned with the blocks at LOD 1/2, where the per-net wires are
/// suppressed. The caller emits this inside `dg-base`, so it fades out at LOD 0
/// (the glance layer draws its own copy at the separated positions there).
/// Drawn before the blocks so the opaque block bodies sit on top; the links run
/// border-to-border and so live in the gaps between groups.
pub fn writeBaseAggLinks(
    arena: Allocator,
    w: *Writer,
    graph: *const Graph,
    lay: layout.Layout,
    ents: []const Entity,
) (Allocator.Error || Writer.Error)!void {
    if (ents.len == 0) return;
    const base = try arena.alloc(Entity, ents.len);
    for (ents, 0..) |e, i| {
        base[i] = e;
        base[i].x = e.zx;
        base[i].y = e.zy;
        base[i].w = e.zw;
        base[i].h = e.zh;
    }
    const ent_of = try entityOf(arena, graph, lay, ents);
    const aggs = try aggregateEdges(arena, graph, ent_of);
    try w.writeAll("<g class=\"dg-agglinks\">");
    for (aggs) |agg| try writeAggEdge(w, graph, aggGeometry(base, aggs, agg), agg);
    for (aggs) |agg| try writeAggTag(w, graph, base, aggs, agg);
    try w.writeAll("</g>");
}

/// Build the chip list: one per placed `(group …)` (bounds from the already
/// computed `GroupBox`, members re-resolved from the source spec via the same
/// key match the layout used), then one solo chip per laid-out block no group
/// claimed.
fn buildEntities(
    arena: Allocator,
    graph: *const Graph,
    lay: layout.Layout,
    palette: []const []const u8,
) Allocator.Error![]Entity {
    var ents: std.ArrayListUnmanaged(Entity) = .empty;
    var grouped = try arena.alloc(bool, graph.nodes.len);
    @memset(grouped, false);
    for (lay.groups) |gb| {
        // `color_idx` is the group's index in the *source* spec — stable even
        // when groups with no placed members were dropped from `lay.groups`.
        const src = graph.layout.groups[gb.color_idx];
        var labels: std.ArrayListUnmanaged([]const u8) = .empty;
        var count: usize = 0;
        for (src.members) |name| {
            const id = nodeByKey(graph, name) orelse continue;
            if (grouped[id]) continue;
            grouped[id] = true;
            count += 1;
            // Caption the cluster with its members' headline parts (the group
            // label already says what the cluster does), falling back to the
            // block label when a member has no part token.
            if (labels.items.len < chip_caption_members) {
                const nd = graph.nodes[id];
                try labels.append(arena, if (nd.parts.len > 0) nd.parts[0] else nd.label);
            }
        }
        if (count == 0) continue;
        try ents.append(arena, .{
            .label = gb.label,
            .x = gb.x,
            .y = gb.y,
            .w = gb.w,
            .h = gb.h,
            .zx = gb.x,
            .zy = gb.y,
            .zw = gb.w,
            .zh = gb.h,
            .color = palette[gb.color_idx % palette.len],
            .count = count,
            .members = try labels.toOwnedSlice(arena),
        });
    }
    for (lay.nodes) |ln| {
        if (grouped[ln.gid]) continue;
        const nd = graph.nodes[ln.gid];
        try ents.append(arena, .{
            .label = nd.label,
            .x = ln.x,
            .y = ln.y,
            .w = layout.node_w,
            .h = layout.node_h,
            .zx = ln.x,
            .zy = ln.y,
            .zw = layout.node_w,
            .zh = layout.node_h,
            .color = rb.categoryColor(nd.category),
            .count = 1,
            .members = &.{},
        });
    }
    return ents.toOwnedSlice(arena);
}

/// Map every graph node id to the entity that owns it (group chip or its own
/// solo chip); null for nodes that were never laid out.
fn entityOf(
    arena: Allocator,
    graph: *const Graph,
    lay: layout.Layout,
    ents: []const Entity,
) Allocator.Error![]?usize {
    const ent_of = try arena.alloc(?usize, graph.nodes.len);
    @memset(ent_of, null);
    for (lay.groups) |gb| {
        const src = graph.layout.groups[gb.color_idx];
        const ei = entityByLabel(ents, gb.label) orelse continue;
        for (src.members) |name| {
            const id = nodeByKey(graph, name) orelse continue;
            if (ent_of[id] == null) ent_of[id] = ei;
        }
    }
    for (lay.nodes) |ln| {
        if (ent_of[ln.gid] != null) continue;
        const nd = graph.nodes[ln.gid];
        if (entityByLabel(ents, nd.label)) |ei| ent_of[ln.gid] = ei;
    }
    return ent_of;
}

fn entityByLabel(ents: []const Entity, label: []const u8) ?usize {
    for (ents, 0..) |e, i| {
        if (std.mem.eql(u8, e.label, label)) return i;
    }
    return null;
}

/// Same stable-key match `layout.zig` uses to resolve `(place …)`/`(group …)`
/// names to graph nodes. Pub so the block-reference builder resolves group
/// members exactly as the diagram does (the two views agree by construction).
pub fn nodeByKey(graph: *const Graph, name: []const u8) ?u32 {
    for (graph.nodes, 0..) |nd, i| {
        if (nd.key.len > 0 and std.mem.eql(u8, nd.key, name)) return @intCast(i);
    }
    return null;
}

/// How well a design's `(group …)` cohesion clusters cover its diagram blocks.
pub const GroupCoverage = struct {
    /// Count of real, placeable blocks — those carrying an authoring key and not
    /// a synthesised boundary node (an off-board antenna / crystal can't be
    /// grouped, so it never counts).
    total: u32,
    /// Labels of the real blocks that no `(group …)` cluster names. Borrowed
    /// from `graph.nodes[i].label`; allocated in the caller's arena.
    ungrouped: []const []const u8,
};

/// Measure `(group …)` coverage of `graph`'s blocks. Members resolve through
/// `nodeByKey` and the same boundary/key filter the Block-overview "Other"
/// bucket uses (`render.zig`), so the ERC grouping check and the diagram agree
/// on what counts as ungrouped. Result lives in `arena`.
pub fn groupCoverage(arena: Allocator, graph: *const Graph) Allocator.Error!GroupCoverage {
    const claimed = try arena.alloc(bool, graph.nodes.len);
    @memset(claimed, false);
    for (graph.layout.groups) |grp| {
        for (grp.members) |name| {
            if (nodeByKey(graph, name)) |id| claimed[id] = true;
        }
    }
    var total: u32 = 0;
    var ungrouped: std.ArrayListUnmanaged([]const u8) = .empty;
    for (graph.nodes, 0..) |nd, i| {
        if (nd.is_boundary or nd.key.len == 0) continue;
        total += 1;
        if (!claimed[i]) try ungrouped.append(arena, nd.label);
    }
    return .{ .total = total, .ungrouped = try ungrouped.toOwnedSlice(arena) };
}

/// Collapse the base edge list to one aggregate per (entity pair, class),
/// counting nets (each base edge contributes its fanout). Intra-entity edges
/// and reference classes (ground) drop out.
fn aggregateEdges(
    arena: Allocator,
    graph: *const Graph,
    ent_of: []const ?usize,
) Allocator.Error![]AggEdge {
    var aggs: std.ArrayListUnmanaged(AggEdge) = .empty;
    for (graph.edges) |e| {
        if (e.class < graph.classes.len and graph.classes[e.class].is_reference) continue;
        const ea = ent_of[e.from] orelse continue;
        const eb = ent_of[e.to] orelse continue;
        if (ea == eb) continue;
        const a = @min(ea, eb);
        const b = @max(ea, eb);
        const nets: usize = @max(1, e.fanout);
        var found = false;
        for (aggs.items) |*agg| {
            if (agg.a == a and agg.b == b and agg.class == e.class) {
                agg.nets += nets;
                found = true;
                break;
            }
        }
        if (!found) try aggs.append(arena, .{ .a = a, .b = b, .class = e.class, .nets = nets });
    }
    return aggs.toOwnedSlice(arena);
}

/// Point where the segment from this entity's centre toward (tx,ty) crosses
/// its border — glance lines run border-to-border, not centre-to-centre.
fn borderPoint(e: Entity, tx: f64, ty: f64) types.Pt {
    const cx = e.x + e.w / 2;
    const cy = e.y + e.h / 2;
    const dx = tx - cx;
    const dy = ty - cy;
    var t: f64 = std.math.floatMax(f64);
    if (@abs(dx) > 0.001) t = @min(t, (e.w / 2) / @abs(dx));
    if (@abs(dy) > 0.001) t = @min(t, (e.h / 2) / @abs(dy));
    if (t == std.math.floatMax(f64)) return .{ .x = cx, .y = cy };
    return .{ .x = cx + dx * t, .y = cy + dy * t };
}

/// How many classes connect this pair, and this edge's rank among them — used
/// to fan parallel class-lines apart so e.g. a power and a control aggregate
/// between the same two groups stay distinct.
fn laneOf(aggs: []const AggEdge, agg: AggEdge) struct { idx: usize, n: usize } {
    var idx: usize = 0;
    var n: usize = 0;
    for (aggs) |o| {
        if (o.a != agg.a or o.b != agg.b) continue;
        if (o.class == agg.class) idx = n;
        n += 1;
    }
    return .{ .idx = idx, .n = @max(n, 1) };
}

/// The two border endpoints of an aggregate. Chips whose horizontal (or
/// vertical) projections overlap connect with a straight perpendicular between
/// the facing borders — the tidy "block diagram" look; corner neighbours fall
/// back to the fanned centre-to-centre diagonal. Parallel classes between the
/// same pair shift by their lane offset so they stay distinct.
fn aggGeometry(ents: []const Entity, aggs: []const AggEdge, agg: AggEdge) [2]types.Pt {
    const ea = ents[agg.a];
    const eb = ents[agg.b];
    const lane = laneOf(aggs, agg);
    const off = (@as(f64, @floatFromInt(lane.idx)) - (@as(f64, @floatFromInt(lane.n - 1)) / 2.0)) * agg_lane_gap;
    const xo_lo = @max(ea.x, eb.x);
    const xo_hi = @min(ea.x + ea.w, eb.x + eb.w);
    const yo_lo = @max(ea.y, eb.y);
    const yo_hi = @min(ea.y + ea.h, eb.y + eb.h);
    if (xo_hi - xo_lo > min_face_overlap) {
        const cx = (xo_lo + xo_hi) / 2 + off;
        if (ea.y + ea.h / 2 < eb.y + eb.h / 2) {
            return .{ .{ .x = cx, .y = ea.y + ea.h }, .{ .x = cx, .y = eb.y } };
        }
        return .{ .{ .x = cx, .y = ea.y }, .{ .x = cx, .y = eb.y + eb.h } };
    }
    if (yo_hi - yo_lo > min_face_overlap) {
        const cy = (yo_lo + yo_hi) / 2 + off;
        if (ea.x + ea.w / 2 < eb.x + eb.w / 2) {
            return .{ .{ .x = ea.x + ea.w, .y = cy }, .{ .x = eb.x, .y = cy } };
        }
        return .{ .{ .x = ea.x, .y = cy }, .{ .x = eb.x + eb.w, .y = cy } };
    }
    const acx = ea.x + ea.w / 2;
    const acy = ea.y + ea.h / 2;
    const bcx = eb.x + eb.w / 2;
    const bcy = eb.y + eb.h / 2;
    var dx = bcx - acx;
    var dy = bcy - acy;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return .{ .{ .x = acx, .y = acy }, .{ .x = bcx, .y = bcy } };
    dx /= len;
    dy /= len;
    // Perpendicular offset applied to both targets so the lanes stay parallel.
    const px = -dy * off;
    const py = dx * off;
    const pa = borderPoint(ea, bcx + px, bcy + py);
    const pb = borderPoint(eb, acx + px, acy + py);
    return .{ .{ .x = pa.x + px, .y = pa.y + py }, .{ .x = pb.x + px, .y = pb.y + py } };
}

fn writeAggEdge(w: *Writer, graph: *const Graph, pts: [2]types.Pt, agg: AggEdge) Writer.Error!void {
    const width = @min(agg_w_max, agg_w_base + agg_w_gain * @sqrt(@as(f64, @floatFromInt(agg.nets))));
    try w.print(
        "<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"{s}\" " ++
            "stroke-width=\"{d:.1}\" stroke-opacity=\"0.75\" stroke-linecap=\"round\"/>",
        .{ pts[0].x, pts[0].y, pts[1].x, pts[1].y, classColor(graph, agg.class), width },
    );
}

/// The ×N net-count tag (skipped for single nets), anchored a fixed inset
/// along the line from the smaller chip's border — long aggregates can pass
/// behind intermediate chips, but the stretch next to an endpoint is always
/// in open gap, so the count stays readable. Parallel classes between the
/// same pair stagger further along the line so their tags never pile up.
fn writeAggTag(w: *Writer, graph: *const Graph, ents: []const Entity, aggs: []const AggEdge, agg: AggEdge) Writer.Error!void {
    if (agg.nets < 2) return;
    const pts = aggGeometry(ents, aggs, agg);
    const a_smaller = entArea(ents[agg.a]) <= entArea(ents[agg.b]);
    const p_end = if (a_smaller) pts[0] else pts[1];
    const p_far = if (a_smaller) pts[1] else pts[0];
    var dx = p_far.x - p_end.x;
    var dy = p_far.y - p_end.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    dx /= len;
    dy /= len;
    const lane = laneOf(aggs, agg);
    const inset = @min(tag_inset + @as(f64, @floatFromInt(lane.idx)) * tag_stagger, @max(len - 12, len / 2));
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-glance-count\" fill=\"{s}\">\u{00d7}{d}</text>",
        .{ p_end.x + dx * inset - dy * tag_side, p_end.y + dy * inset + dx * tag_side + 5, classColor(graph, agg.class), agg.nets },
    );
}

fn entArea(e: Entity) f64 {
    return e.w * e.h;
}

fn classColor(graph: *const Graph, id: types.ClassId) []const u8 {
    if (id < graph.classes.len) return graph.classes[id].color;
    return "#8b949e";
}

/// One glance chip: solid backing (so the cross-fade never shows base wiring
/// through it), a tinted fill + border in the entity color, the title centred,
/// and a caption naming the member count + first member parts. The `data-*`
/// rect lets the viewer JS zoom into the chip's region on click — the `z*`
/// original bounds, so the zoom lands on the member blocks even when the
/// separation pass moved the chip itself.
fn writeChip(arena: Allocator, w: *Writer, e: Entity) (Allocator.Error || Writer.Error)!void {
    try w.print(
        "<g class=\"dg-chip\" data-x=\"{d:.1}\" data-y=\"{d:.1}\" data-w=\"{d:.1}\" data-h=\"{d:.1}\">",
        .{ e.zx, e.zy, e.zw, e.zh },
    );
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"14\" fill=\"#0d1117\"/>",
        .{ e.x, e.y, e.w, e.h },
    );
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"14\" class=\"dg-chip-tint\" " ++
            "fill=\"{s}\" fill-opacity=\"0.09\" stroke=\"{s}\" stroke-width=\"2\"/>",
        .{ e.x, e.y, e.w, e.h, e.color, e.color },
    );
    const cx = e.x + e.w / 2;
    const cy = e.y + e.h / 2;
    const caption = try chipCaption(arena, e);
    // Shrink text toward a floor before truncating, so a narrow chip
    // ("Control & Connectivity" over a single stacked column) keeps its
    // whole name at a smaller size instead of losing the end. Same for the
    // caption, so a narrow chip's full member list survives.
    const len_f: f64 = @floatFromInt(@max(e.label.len, 1));
    const fit: f64 = (e.w - 28) / (title_char_w * len_f);
    const fs = @min(chip_title_fs, @max(chip_title_fs_min, fit));
    // fit ≥ floor ⇒ the shrink made the whole label fit (fs ≤ fit), so only a
    // floor-pinned label truncates — and computing the budget that way avoids
    // the float round-trip dropping a fitting label's last character.
    const title_max: usize = if (fit >= chip_title_fs_min)
        e.label.len
    else
        @max(8, @as(usize, @intFromFloat((e.w - 28) / (title_char_w * chip_title_fs_min))));
    // Centre the title+caption pair vertically; a captionless solo chip
    // centres the title alone.
    const ty: f64 = if (caption.len > 0) cy - fs * 0.10 else cy + fs * 0.36;
    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-chip-title\" style=\"font-size:{d:.0}px\">", .{ cx, ty, fs });
    try writeEscaped(w, try truncate(arena, e.label, title_max));
    try w.writeAll("</text>");
    if (caption.len > 0) {
        const cap_len: f64 = @floatFromInt(@max(caption.len, 1));
        const cap_fit: f64 = (e.w - 24) / (sub_char_w * cap_len);
        const cfs = @min(chip_sub_fs, @max(chip_sub_fs_min, cap_fit));
        const cap_max: usize = if (cap_fit >= chip_sub_fs_min)
            caption.len
        else
            @max(10, @as(usize, @intFromFloat((e.w - 24) / (sub_char_w * chip_sub_fs_min))));
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-chip-sub\" style=\"font-size:{d:.0}px\">", .{ cx, cy + cfs * 1.35, cfs });
        try writeEscaped(w, try truncate(arena, caption, cap_max));
        try w.writeAll("</text>");
    }
    try w.writeAll("</g>");
}

/// "N blocks — first · second · third" (or just the member list when it is
/// complete); empty for solo chips, whose label already names the block.
fn chipCaption(arena: Allocator, e: Entity) Allocator.Error![]const u8 {
    if (e.members.len == 0) return "";
    const list = try std.mem.join(arena, " \u{00b7} ", e.members);
    if (e.count > e.members.len) {
        return std.fmt.allocPrint(arena, "{d} blocks \u{2014} {s} \u{2026}", .{ e.count, list });
    }
    return list;
}

fn truncate(arena: Allocator, text: []const u8, max: usize) Allocator.Error![]const u8 {
    if (text.len <= max) return text;
    if (max < 2) return "";
    // Back the cut up to a UTF-8 boundary so a multi-byte glyph ("·", "—")
    // never splits into an invalid sequence.
    var end = max - 1;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return std.fmt.allocPrint(arena, "{s}\u{2026}", .{text[0..end]});
}

fn writeEscaped(w: *Writer, text: []const u8) Writer.Error!void {
    for (text) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const env_mod = @import("../eval/env.zig");

fn testNode(label: []const u8) types.Node {
    return .{
        .label = label,
        .subtitle = "",
        .category = .peripheral,
        .slug = "",
        .key = label,
        .inputs = &.{},
        .outputs = &.{},
    };
}

// spec: diagram/lod - Aggregates base edges into one glance connection per entity pair and class, summing fanouts
test "aggregateEdges collapses same-pair same-class edges and sums fanout" {
    var nodes = [_]types.Node{ testNode("a"), testNode("b"), testNode("c"), testNode("d") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 2, .class = types.CLASS_CONTROL, .label = "SPI_SCK" },
        .{ .from = 1, .to = 3, .class = types.CLASS_CONTROL, .label = "SPI_MISO", .fanout = 3 },
        .{ .from = 0, .to = 3, .class = types.CLASS_POWER, .label = "VDD" },
        .{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "INTRA" },
    };
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    // Nodes a+b form entity 0, c+d entity 1.
    const ent_of = [_]?usize{ 0, 0, 1, 1 };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const aggs = try aggregateEdges(arena_state.allocator(), &graph, &ent_of);
    try testing.expectEqual(@as(usize, 2), aggs.len);
    try testing.expectEqual(@as(usize, 4), aggs[0].nets); // 1 + 3 control nets
    try testing.expectEqual(types.CLASS_CONTROL, aggs[0].class);
    try testing.expectEqual(@as(usize, 1), aggs[1].nets);
    try testing.expectEqual(types.CLASS_POWER, aggs[1].class);
}

// spec: diagram/lod - Renders a glance chip per group and per ungrouped block with member captions
test "writeGlanceLayer emits group chips plus solo chips for ungrouped blocks" {
    var nodes = [_]types.Node{ testNode("MCU"), testNode("Flash"), testNode("Sensor") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = types.CLASS_CONTROL, .label = "BUS", .fanout = 2 },
        .{ .from = 0, .to = 2, .class = types.CLASS_CONTROL, .label = "I2C" },
    };
    const members = [_][]const u8{ "MCU", "Flash" };
    const groups = [_]env_mod.LayoutGroup{.{ .label = "Compute", .members = &members }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    graph.layout.groups = &groups;
    var lnodes = [_]layout.LNode{
        .{ .gid = 0, .x = 0, .y = 0 },
        .{ .gid = 1, .x = 400, .y = 0 },
        .{ .gid = 2, .x = 800, .y = 0 },
    };
    const gboxes = [_]layout.GroupBox{.{ .label = "Compute", .x = 0, .y = 0, .w = 700, .h = 120, .color_idx = 0 }};
    const lay = layout.Layout{
        .nodes = &lnodes,
        .routes = &.{},
        .width = 1100,
        .height = 200,
        .groups = &gboxes,
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const palette = [_][]const u8{"#58a6ff"};
    const ents = try buildGlanceEntities(arena_state.allocator(), &graph, lay, &palette);
    try writeGlanceLayer(arena_state.allocator(), &aw.writer, &graph, lay, ents);
    const svg = aw.written();
    // One group chip whose caption lists both members, one solo chip for the
    // ungrouped sensor; the intra-group BUS edge aggregates away.
    try testing.expect(std.mem.indexOf(u8, svg, "dg-glance") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "Compute") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "MCU \u{00b7} Flash") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "Sensor") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "data-w=\"700.0\"") != null);
}

// spec: diagram/lod - Separates overlapping glance chips so chips never stack while keeping each chip's original zoom target
test "buildGlanceEntities pushes overlapping group chips apart" {
    // Two groups with interleaved members: "Wide" spans a…d so its bounding
    // box swallows "Inner" (b…c) whole — the raw boxes render stacked.
    var nodes = [_]types.Node{ testNode("a"), testNode("b"), testNode("c"), testNode("d") };
    const g1m = [_][]const u8{ "a", "d" };
    const g2m = [_][]const u8{ "b", "c" };
    const groups = [_]env_mod.LayoutGroup{
        .{ .label = "Wide", .members = &g1m },
        .{ .label = "Inner", .members = &g2m },
    };
    var graph = Graph{ .nodes = &nodes, .edges = &.{} };
    graph.layout.groups = &groups;
    var lnodes = [_]layout.LNode{
        .{ .gid = 0, .x = 0, .y = 0 },
        .{ .gid = 1, .x = 400, .y = 0 },
        .{ .gid = 2, .x = 800, .y = 0 },
        .{ .gid = 3, .x = 1200, .y = 0 },
    };
    const gboxes = [_]layout.GroupBox{
        .{ .label = "Wide", .x = 0, .y = 0, .w = 1500, .h = 150, .color_idx = 0 },
        .{ .label = "Inner", .x = 400, .y = 20, .w = 700, .h = 110, .color_idx = 1 },
    };
    const lay = layout.Layout{ .nodes = &lnodes, .routes = &.{}, .width = 1600, .height = 200, .groups = &gboxes };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const palette = [_][]const u8{ "#58a6ff", "#d29922" };
    const ents = try buildGlanceEntities(arena_state.allocator(), &graph, lay, &palette);
    try testing.expectEqual(@as(usize, 2), ents.len);
    // Disjoint after separation…
    const a = ents[0];
    const b = ents[1];
    const ox = @min(a.x + a.w, b.x + b.w) - @max(a.x, b.x);
    const oy = @min(a.y + a.h, b.y + b.h) - @max(a.y, b.y);
    try testing.expect(ox <= 0 or oy <= 0);
    // …sizes untouched, and the zoom target keeps the ORIGINAL (overlapping)
    // box so clicking still lands on the member blocks.
    try testing.expectApproxEqAbs(@as(f64, 1500), a.w, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 0), a.zx, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 400), b.zx, 0.5);
    try testing.expectApproxEqAbs(@as(f64, 20), b.zy, 0.5);
}

// spec: diagram/lod - Reports the block count and which blocks no group cluster claims
test "groupCoverage flags blocks outside every group cluster" {
    var nodes = [_]types.Node{ testNode("MCU"), testNode("Flash"), testNode("Sensor") };
    var edges = [_]types.Edge{};
    const members = [_][]const u8{ "MCU", "Flash" };
    const groups = [_]env_mod.LayoutGroup{.{ .label = "Compute", .members = &members }};
    var graph = Graph{ .nodes = &nodes, .edges = &edges };
    graph.layout.groups = &groups;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const cov = try groupCoverage(arena_state.allocator(), &graph);
    // 3 real blocks; "Sensor" is named by no (group …) cluster.
    try testing.expectEqual(@as(u32, 3), cov.total);
    try testing.expectEqual(@as(usize, 1), cov.ungrouped.len);
    try testing.expectEqualStrings("Sensor", cov.ungrouped[0]);
}
