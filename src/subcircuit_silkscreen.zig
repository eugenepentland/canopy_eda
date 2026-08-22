//! Automatically generated board-level silkscreen for flattened sub-circuits.
//!
//! A top-level sub-block is visible in a placement as the prefix before the
//! first slash (`buck/U1`, `buck/C1`, ...). Every prefix gets four short
//! corner L marks around the union of its courtyards; overlapping boxes no
//! longer merge into one shared envelope. Same-face boxes whose facing edges
//! come within 1.5 mm snap both edges to the shared midpoint so adjacent
//! envelopes align instead of drawing a thin double edge, and a box whose
//! corner marks a keepout would clip shifts itself a little so the marks
//! still draw whole. Every prefix keeps its own fixed-size horizontal name.
//! The label placer searches corner-near slots along the top and bottom edges,
//! repeats them at ±1 mm, then searches inside the box. Names reject
//! board-outline, keepout, generated art, and same-side pad collisions;
//! strokes are clipped into every printable fragment around those obstacles.
//! Artwork lands on the side of the group's main IC: prefer a `U...` hub,
//! then any hub, and use the largest candidate when there is more than one.

const std = @import("std");
const geometry = @import("placement/geometry.zig");
const optimizer = @import("placement/optimizer.zig");
const outline = @import("placement/outline.zig");
const pad_shape = @import("placement/pad_shape.zig");
const perimeter_fence = @import("placement/perimeter_fence.zig");
const mask_relief = @import("placement/mask_relief.zig");
const font = @import("font5x7.zig");
const silk_font = @import("silk_font.zig");

/// Keep generated silk clear of the annotated parts' own courtyards.
const courtyard_margin_mm: f64 = 0.5;
/// Nominal corner-arm length. Small groups shrink it proportionally.
const max_corner_mm: f64 = 2.0;
const min_corner_mm: f64 = 0.75;
/// Nominal font size for the sub-circuit name.
const subcircuit_label_size_mm: f64 = 1.0;
/// Tangential air between the name and either corner arm.
const label_edge_gap_mm: f64 = 0.15;
/// Second-tier displacement above/below a failed top/bottom edge slot.
const label_edge_offset_mm: f64 = 1.0;
/// Distance the four L-shaped corner brackets sit inside the annotation box.
const corner_inset_mm: f64 = 0.2;
/// Same-face annotation boxes whose facing edges come this close share one
/// aligned edge at the midpoint instead of drawing a thin double edge.
const edge_snap_gap_mm: f64 = 1.5;
/// Furthest a sub-circuit box may translate so its corner marks clear a
/// keepout; the search prefers the smallest movement.
const keepout_shift_max_mm: f64 = 2.0;
/// Step size of the keepout-avoidance box translation search.
const keepout_shift_step_mm: f64 = 0.1;
/// Grid used only after the edge and interior searches fail. The fallback
/// expands around the annotation until it finds the nearest printable board
/// location, instead of silently dropping the sub-circuit name.
const nearby_search_step_mm: f64 = 0.5;
/// Fabrication IDs use the same conservative 0.8 mm visible-cap floor as
/// generated test-point text while remaining compact enough for a board edge.
const fabrication_id_cap_height_mm: f64 = 0.8;
const fabrication_id_size_mm: f64 = fabrication_id_cap_height_mm * silk_font.em_units / silk_font.cap_units;
/// Finished generated-silk clearance from pads, keepouts, and Edge.Cuts.
const silk_clearance_mm: f64 = 0.2;
/// Clearance from a label's ink box to a pad, keepout, or another name.
const label_clearance_mm: f64 = silk_clearance_mm;
/// Keep the complete text ink box this far inside Edge.Cuts.
const label_board_inset_mm: f64 = silk_clearance_mm;
const silk_stroke_mm: f64 = 0.15;
/// Footprint circles below this outside diameter are treated as authored
/// pin-one dots. They remain untouched in the library; board renderers replace
/// them with one uniform, collision-placed marker.
pub const pin_one_indicator_limit_mm: f64 = 0.5;
/// Finished diameter of every generated pin-one dot.
pub const pin_one_marker_diameter_mm: f64 = 0.3;
const pin_one_marker_radius_mm: f64 = pin_one_marker_diameter_mm / 2;
const pin_one_search_step_mm: f64 = 0.1;
const pin_one_search_radius_mm: f64 = 4.0;
/// A stroke's centreline must clear an obstacle by the finished clearance plus
/// half its own width, leaving the visible ink itself exactly 0.2 mm away.
const fragment_center_clearance_mm: f64 = silk_clearance_mm + silk_stroke_mm / 2;
/// Fine enough that the stroke-radius inflation of even a point-like obstacle
/// spans several samples. Transitions are then refined by binary search.
const fragment_sample_mm: f64 = 0.025;
/// Search near both corners before moving toward the centre.
const corner_fractions = [_]f64{ 0, 1, 0.125, 0.875, 0.25, 0.75, 0.375, 0.625, 0.5 };

/// One straight silkscreen stroke in placement/world millimetres.
pub const Segment = struct { x1: f64, y1: f64, x2: f64, y2: f64 };

/// A no-silkscreen polygon restored from a saved/imported layout. It applies
/// to both board faces: generated annotation ink never enters it.
pub const Keepout = struct { polygon: []const [2]f64 };

/// One generated, filled pin-one dot in placement/world millimetres.
pub const PinOneMarker = struct {
    ref_des: []const u8,
    side: optimizer.Side,
    x: f64,
    y: f64,
};

/// Whether a footprint-authored silk circle is the small directional marker
/// the board layer replaces. The strict comparison implements "less than
/// 0.5 mm diameter" literally; larger body outlines remain authored art.
pub fn isAuthoredPinOneIndicator(circle: geometry.SilkCircle) bool {
    return circle.r > 0 and circle.r * 2 < pin_one_indicator_limit_mm;
}

const Artwork = struct {
    /// Unclipped annotation geometry. Null (the normal case) means the eight
    /// L-shaped corner marks computed from the annotation's own bounds.
    raw: ?[]const Segment = null,
    /// Printable pieces left after pad, keepout, and Edge.Cuts clipping.
    clipped: []const Segment = &.{},
};

/// Generated board-silkscreen identity, side, and expanded courtyard bounds
/// for one flattened top-level sub-circuit.
pub const Annotation = struct {
    name: []const u8,
    side: optimizer.Side,
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,
    label_text: font.BoardText,
    /// Printable stroke geometry; null means the annotation's own four corner
    /// brackets are drawn.
    artwork: Artwork = .{},

    /// Length in millimetres of each horizontal and vertical L-shaped arm.
    pub fn cornerLen(self: Annotation) f64 {
        const short = @min(self.maxx - self.minx, self.maxy - self.miny);
        return std.math.clamp(short * 0.22, min_corner_mm, max_corner_mm);
    }

    /// The eight strokes that make four L-shaped corner marks.
    pub fn segments(self: Annotation) [8]Segment {
        const l = self.cornerLen();
        const d = corner_inset_mm;
        return .{
            .{ .x1 = self.minx + d + l, .y1 = self.miny + d, .x2 = self.minx + d, .y2 = self.miny + d },
            .{ .x1 = self.minx + d, .y1 = self.miny + d, .x2 = self.minx + d, .y2 = self.miny + d + l },
            .{ .x1 = self.maxx - d - l, .y1 = self.miny + d, .x2 = self.maxx - d, .y2 = self.miny + d },
            .{ .x1 = self.maxx - d, .y1 = self.miny + d, .x2 = self.maxx - d, .y2 = self.miny + d + l },
            .{ .x1 = self.minx + d + l, .y1 = self.maxy - d, .x2 = self.minx + d, .y2 = self.maxy - d },
            .{ .x1 = self.minx + d, .y1 = self.maxy - d, .x2 = self.minx + d, .y2 = self.maxy - d - l },
            .{ .x1 = self.maxx - d - l, .y1 = self.maxy - d, .x2 = self.maxx - d, .y2 = self.maxy - d },
            .{ .x1 = self.maxx - d, .y1 = self.maxy - d, .x2 = self.maxx - d, .y2 = self.maxy - d - l },
        };
    }

    /// All printable corner-stroke fragments after physical clipping.
    pub fn visibleSegments(self: Annotation) []const Segment {
        return self.artwork.clipped;
    }

    /// Collision-aware name position chosen while the annotations are
    /// collected. Kept as a method so Gerber and raster callers share one API.
    pub fn label(self: Annotation) font.BoardText {
        return self.label_text;
    }
};

const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
const PadObstacle = struct { shape: pad_shape.Shape, top: bool, bottom: bool };

/// Uniform-grid index over the pad obstacles a silk label must clear.
///
/// Every label placement asks the same question — "does any pad come within
/// `label_clearance_mm` of THIS box?" — and a label box is small next to a
/// board, so answering it by scanning every pad costs (candidate positions x
/// every pad on the board). On a dense board that one sweep was over 90% of the
/// PCB page's cold render. Bucketing each pad into the cells its bounding box
/// covers turns a query into a walk of the handful of cells the label actually
/// overlaps, and the ANSWER is unchanged: `shapeGap` is never smaller than the
/// bounding-box gap, so a pad whose box misses the expanded label box cannot
/// be the one that blocks it.
const PadField = struct {
    pads: []const PadObstacle = &.{},
    /// Pad indices bucketed by cell, concatenated; cell `i` owns the span
    /// `starts[i]..starts[i + 1]`. A pad straddling a cell edge is listed in
    /// each cell it touches — a query may test it twice, which is harmless
    /// because the test is pure and the first block short-circuits.
    cells: []const u32 = &.{},
    starts: []const u32 = &.{},
    minx: f64 = 0,
    miny: f64 = 0,
    cw: f64 = 1,
    ch: f64 = 1,
    /// 0 means "no grid" — an empty field, or one the caller never indexed —
    /// and every query falls back to the flat scan.
    nx: usize = 0,
    ny: usize = 0,

    const Span = struct { x0: usize, x1: usize, y0: usize, y1: usize };

    fn spanOf(f: PadField, x0: f64, y0: f64, x1: f64, y1: f64) Span {
        return .{
            .x0 = f.cellX(x0),
            .x1 = f.cellX(x1),
            .y0 = f.cellY(y0),
            .y1 = f.cellY(y1),
        };
    }

    fn cellX(f: PadField, x: f64) usize {
        const i = @floor((x - f.minx) / f.cw);
        if (i <= 0) return 0;
        if (i >= @as(f64, @floatFromInt(f.nx - 1))) return f.nx - 1;
        return @intFromFloat(i);
    }

    fn cellY(f: PadField, y: f64) usize {
        const i = @floor((y - f.miny) / f.ch);
        if (i <= 0) return 0;
        if (i >= @as(f64, @floatFromInt(f.ny - 1))) return f.ny - 1;
        return @intFromFloat(i);
    }

    fn deinit(f: PadField, alloc: std.mem.Allocator) void {
        alloc.free(f.cells);
        alloc.free(f.starts);
    }
};

/// Index `pads` for `padsBlock`. The grid is sized to about one pad per cell so
/// the buckets stay short without the cell count outrunning the pad count.
/// Borrows `pads` — the field must not outlive it.
fn buildPadField(alloc: std.mem.Allocator, pads: []const PadObstacle) std.mem.Allocator.Error!PadField {
    if (pads.len == 0) return .{ .pads = pads };
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (pads) |p| {
        minx = @min(minx, p.shape.x0);
        miny = @min(miny, p.shape.y0);
        maxx = @max(maxx, p.shape.x1);
        maxy = @max(maxy, p.shape.y1);
    }
    // Floor a degenerate extent (every pad on one line) so the cell size stays
    // finite; 1 um is far below any real board dimension.
    const min_extent_mm = 0.001;
    const w = @max(maxx - minx, min_extent_mm);
    const h = @max(maxy - miny, min_extent_mm);
    const n: f64 = @floatFromInt(pads.len);
    // nx * ny ~= pads.len, split to match the board's aspect, capped so a
    // pathological aspect ratio cannot allocate an enormous grid.
    const nx: usize = @intFromFloat(@max(1, @min(512, @ceil(@sqrt(n * w / h)))));
    const ny: usize = @intFromFloat(@max(1, @min(512, @ceil(@sqrt(n * h / w)))));
    var f = PadField{
        .pads = pads,
        .minx = minx,
        .miny = miny,
        .cw = w / @as(f64, @floatFromInt(nx)),
        .ch = h / @as(f64, @floatFromInt(ny)),
        .nx = nx,
        .ny = ny,
    };

    const starts = try alloc.alloc(u32, nx * ny + 1);
    errdefer alloc.free(starts);
    @memset(starts, 0);
    var total: usize = 0;
    for (pads) |p| {
        const span = f.spanOf(p.shape.x0, p.shape.y0, p.shape.x1, p.shape.y1);
        for (span.y0..span.y1 + 1) |cy| for (span.x0..span.x1 + 1) |cx| {
            starts[cy * nx + cx + 1] += 1;
            total += 1;
        };
    }
    for (1..starts.len) |i| starts[i] += starts[i - 1];

    const cells = try alloc.alloc(u32, total);
    errdefer alloc.free(cells);
    const cursor = try alloc.alloc(u32, nx * ny);
    defer alloc.free(cursor);
    @memcpy(cursor, starts[0 .. nx * ny]);
    for (pads, 0..) |p, pi| {
        const span = f.spanOf(p.shape.x0, p.shape.y0, p.shape.x1, p.shape.y1);
        for (span.y0..span.y1 + 1) |cy| for (span.x0..span.x1 + 1) |cx| {
            const c = cy * nx + cx;
            cells[cursor[c]] = @intCast(pi);
            cursor[c] += 1;
        };
    }
    f.starts = starts;
    f.cells = cells;
    return f;
}

/// True if any pad on `side` comes within `label_clearance_mm` of box `b`.
fn padsBlock(field: PadField, side: optimizer.Side, b: Rect) bool {
    const label_shape = pad_shape.Shape{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 };
    if (field.nx == 0) {
        for (field.pads) |pad| if (padTouches(pad, side, label_shape)) return true;
        return false;
    }
    const span = field.spanOf(
        b.x0 - label_clearance_mm,
        b.y0 - label_clearance_mm,
        b.x1 + label_clearance_mm,
        b.y1 + label_clearance_mm,
    );
    for (span.y0..span.y1 + 1) |cy| for (span.x0..span.x1 + 1) |cx| {
        const c = cy * field.nx + cx;
        for (field.cells[field.starts[c]..field.starts[c + 1]]) |pi| {
            if (padTouches(field.pads[pi], side, label_shape)) return true;
        }
    };
    return false;
}

fn padTouches(pad: PadObstacle, side: optimizer.Side, label_shape: pad_shape.Shape) bool {
    const blocks_side = switch (side) {
        .top => pad.top,
        .bottom => pad.bottom,
    };
    if (!blocks_side) return false;
    return pad_shape.shapeGap(label_shape, pad.shape, label_clearance_mm) < label_clearance_mm;
}

/// True if any pad on `side` sits within `fragment_center_clearance_mm` of
/// `point` — the same index answering the clipper's point query.
fn padsHitPoint(field: PadField, side: optimizer.Side, point: [2]f64) bool {
    if (field.nx == 0) {
        for (field.pads) |pad| if (padCovers(pad, side, point)) return true;
        return false;
    }
    const span = field.spanOf(
        point[0] - fragment_center_clearance_mm,
        point[1] - fragment_center_clearance_mm,
        point[0] + fragment_center_clearance_mm,
        point[1] + fragment_center_clearance_mm,
    );
    for (span.y0..span.y1 + 1) |cy| for (span.x0..span.x1 + 1) |cx| {
        const c = cy * field.nx + cx;
        for (field.cells[field.starts[c]..field.starts[c + 1]]) |pi| {
            if (padCovers(field.pads[pi], side, point)) return true;
        }
    };
    return false;
}

fn padCovers(pad: PadObstacle, side: optimizer.Side, point: [2]f64) bool {
    const blocks_side = switch (side) {
        .top => pad.top,
        .bottom => pad.bottom,
    };
    if (!blocks_side) return false;
    const shape = pad.shape;
    return pad_shape.pointDist(shape.x0, shape.y0, shape.x1, shape.y1, shape.poly, point[0], point[1], fragment_center_clearance_mm) <= fragment_center_clearance_mm;
}
const Edge = enum { top, bottom };
const Candidate = struct { text: font.BoardText, score: f64 };

fn textWidth(name: []const u8, size: f64) f64 {
    return silk_font.widthMm(name, size);
}

fn textHeight(size: f64) f64 {
    return silk_font.heightMm(size);
}

fn textBox(text: font.BoardText) Rect {
    const w = textWidth(text.text, text.size);
    const q = @mod(text.rot, 180.0);
    const vertical = @abs(q - 90.0) < 0.001;
    const h = textHeight(text.size);
    const bw = if (vertical) h else w;
    const bh = if (vertical) w else h;
    return .{ .x0 = text.x - bw / 2, .y0 = text.y - bh / 2, .x1 = text.x + bw / 2, .y1 = text.y + bh / 2 };
}

fn overlaps(a: Rect, b: Rect, clearance: f64) bool {
    return !(a.x1 + clearance <= b.x0 or b.x1 + clearance <= a.x0 or
        a.y1 + clearance <= b.y0 or b.y1 + clearance <= a.y0);
}

fn labelBoardInset(placement: optimizer.Placement) f64 {
    const fixed_keepout = perimeter_fence.keepoutLimit(placement);
    return @max(label_board_inset_mm, fixed_keepout + silk_clearance_mm);
}

fn boxInsideBoard(placement: optimizer.Placement, b: Rect) bool {
    const br = placement.board_rect orelse return true;
    const inset = labelBoardInset(placement);
    if (b.x0 < br.minx + inset or b.x1 > br.minx + br.w - inset or
        b.y0 < br.miny + inset or b.y1 > br.miny + br.h - inset) return false;
    const poly = placement.board_poly orelse return true;
    if (poly.len < 3) return true;
    const cx = (b.x0 + b.x1) / 2;
    const cy = (b.y0 + b.y1) / 2;
    const samples = [_][2]f64{
        .{ b.x0, b.y0 }, .{ cx, b.y0 }, .{ b.x1, b.y0 },
        .{ b.x0, cy },   .{ cx, cy },   .{ b.x1, cy },
        .{ b.x0, b.y1 }, .{ cx, b.y1 }, .{ b.x1, b.y1 },
    };
    for (samples) |p| if (outline.signedInset(poly, p[0], p[1]) < inset) return false;
    const corners = [_][2]f64{ .{ b.x0, b.y0 }, .{ b.x1, b.y0 }, .{ b.x1, b.y1 }, .{ b.x0, b.y1 } };
    for (corners, 0..) |a, i| {
        const z = corners[(i + 1) % corners.len];
        if (outline.segCrossesEdge(poly, a[0], a[1], z[0], z[1]) != null) return false;
    }
    return true;
}

fn pointInRect(p: [2]f64, r: Rect) bool {
    return p[0] >= r.x0 and p[0] <= r.x1 and p[1] >= r.y0 and p[1] <= r.y1;
}

fn boxHitsKeepout(b: Rect, keepout: Keepout) bool {
    const poly = keepout.polygon;
    if (poly.len < 3) return false;
    const r = Rect{
        .x0 = b.x0 - label_clearance_mm,
        .y0 = b.y0 - label_clearance_mm,
        .x1 = b.x1 + label_clearance_mm,
        .y1 = b.y1 + label_clearance_mm,
    };
    const corners = [_][2]f64{ .{ r.x0, r.y0 }, .{ r.x1, r.y0 }, .{ r.x1, r.y1 }, .{ r.x0, r.y1 } };
    for (corners) |p| if (outline.contains(poly, p[0], p[1])) return true;
    for (poly) |p| if (pointInRect(p, r)) return true;
    for (corners, 0..) |a, i| {
        const z = corners[(i + 1) % corners.len];
        if (outline.segCrossesEdge(poly, a[0], a[1], z[0], z[1]) != null) return true;
    }
    return false;
}

const LabelObstacles = struct {
    pads: PadField,
    keepouts: []const Keepout,
    placed: []const Annotation,
    user_texts: []const font.BoardText,
};

const LabelPlacementContext = struct {
    placement: optimizer.Placement,
    pads: PadField,
    keepouts: []const Keepout,
    user_texts: []const font.BoardText,
    art: []const Annotation,
};

fn labelClear(
    placement: optimizer.Placement,
    obstacles: LabelObstacles,
    side: optimizer.Side,
    b: Rect,
) bool {
    if (!boxInsideBoard(placement, b)) return false;
    for (obstacles.keepouts) |keepout| if (boxHitsKeepout(b, keepout)) return false;
    if (padsBlock(obstacles.pads, side, b)) return false;
    for (obstacles.placed) |annotation| {
        if (annotation.side != side or annotation.label_text.text.len == 0) continue;
        if (overlaps(b, textBox(annotation.label_text), label_clearance_mm)) return false;
    }
    for (obstacles.user_texts) |text| {
        if (text.text.len == 0 or text.bottom != (side == .bottom)) continue;
        if (overlaps(b, textBox(text), label_clearance_mm)) return false;
    }
    return true;
}

fn edgeCandidate(annotation: Annotation, edge: Edge, fraction: f64, shift: f64) ?font.BoardText {
    const extent = textWidth(annotation.name, subcircuit_label_size_mm);
    const lo = annotation.minx + annotation.cornerLen() + label_edge_gap_mm + corner_inset_mm + extent / 2;
    const hi = annotation.maxx - annotation.cornerLen() - label_edge_gap_mm - corner_inset_mm - extent / 2;
    if (lo > hi + 1e-9) return null;
    return .{
        .x = lo + fraction * (hi - lo),
        .y = (if (edge == .top) annotation.miny else annotation.maxy) + shift,
        .bottom = annotation.side == .bottom,
        .size = subcircuit_label_size_mm,
        .text = annotation.name,
        .rot = 0,
    };
}

fn segmentHitsLabel(segment: Segment, b: Rect) bool {
    const clearance = label_clearance_mm + silk_stroke_mm / 2;
    const stroke_box = Rect{
        .x0 = @min(segment.x1, segment.x2) - clearance,
        .y0 = @min(segment.y1, segment.y2) - clearance,
        .x1 = @max(segment.x1, segment.x2) + clearance,
        .y1 = @max(segment.y1, segment.y2) + clearance,
    };
    return overlaps(b, stroke_box, 0);
}

fn labelHitsCornerArt(annotation: Annotation, b: Rect) bool {
    for (annotation.segments()) |segment| if (segmentHitsLabel(segment, b)) return true;
    return false;
}

fn labelHitsGeneratedArt(art: []const Annotation, annotation: Annotation, b: Rect) bool {
    if (art.len == 0) return labelHitsCornerArt(annotation, b);
    for (art) |candidate| {
        if (candidate.side != annotation.side) continue;
        if (candidate.artwork.raw) |segments| {
            for (segments) |segment| if (segmentHitsLabel(segment, b)) return true;
        } else {
            for (candidate.segments()) |segment| if (segmentHitsLabel(segment, b)) return true;
        }
    }
    return false;
}

fn labelHitsArtOnSide(art: []const Annotation, side: optimizer.Side, b: Rect) bool {
    for (art) |candidate| {
        if (candidate.side != side) continue;
        if (candidate.artwork.raw) |segments| {
            for (segments) |segment| if (segmentHitsLabel(segment, b)) return true;
        } else {
            for (candidate.segments()) |segment| if (segmentHitsLabel(segment, b)) return true;
        }
    }
    return false;
}

fn appendPadObstacles(
    alloc: std.mem.Allocator,
    shape_arena: std.mem.Allocator,
    pads: *std.ArrayList(PadObstacle),
    placement: optimizer.Placement,
    excluded_refs: []const []const u8,
    relief: mask_relief.Relief,
) std.mem.Allocator.Error!void {
    for (placement.parts) |part| {
        if (excluded(part.ref_des, excluded_refs)) continue;
        for (part.pads) |pad| {
            const both = pad.thru or pad.npth;
            try pads.append(alloc, .{
                .shape = try pad_shape.worldShape(shape_arena, part, pad),
                .top = both or part.side == .top,
                .bottom = both or part.side == .bottom,
            });
        }
    }
    // Match generated sub-circuit placement: exposed RF strokes reserve their
    // actual square-cap mask-opening polygon on the affected face.
    for (relief.strokes) |s| {
        const poly = try shape_arena.dupe([2]f64, &mask_relief.strokePoly(s));
        var x0 = poly[0][0];
        var y0 = poly[0][1];
        var x1 = x0;
        var y1 = y0;
        for (poly[1..]) |pt| {
            x0 = @min(x0, pt[0]);
            y0 = @min(y0, pt[1]);
            x1 = @max(x1, pt[0]);
            y1 = @max(y1, pt[1]);
        }
        try pads.append(alloc, .{
            .shape = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .poly = poly },
            .top = s.layer == 0,
            .bottom = s.layer == 1,
        });
    }
}

fn pinOnePad(part: optimizer.Part) ?geometry.Pad {
    for (part.pads) |pad| if (std.mem.eql(u8, pad.number, "1")) return pad;
    // Ball-grid and connector pin-one naming uses A1 rather than bare 1.
    for (part.pads) |pad| if (std.ascii.eqlIgnoreCase(pad.number, "A1")) return pad;
    return null;
}

fn isDirectionalPart(part: optimizer.Part, has_authored_indicator: bool) bool {
    if (has_authored_indicator) return true;
    // Hubs are the placement model's IC/connector class. A multi-pad hub has
    // an orientation that matters; single-pad test points, fiducials and
    // mounting features deliberately stay unmarked.
    if (part.kind == .hub and part.pads.len > 1) return true;

    // Two-terminal diodes and LEDs are classified as passives, but their
    // reference designator still carries the polarity information.
    const leaf = if (std.mem.lastIndexOfScalar(u8, part.ref_des, '/')) |slash|
        part.ref_des[slash + 1 ..]
    else
        part.ref_des;
    return part.pads.len == 2 and leaf.len > 0 and
        (std.ascii.toUpper(leaf[0]) == 'D' or std.ascii.toUpper(leaf[0]) == 'Q');
}

fn pinOneBox(x: f64, y: f64) Rect {
    return .{
        .x0 = x - pin_one_marker_radius_mm,
        .y0 = y - pin_one_marker_radius_mm,
        .x1 = x + pin_one_marker_radius_mm,
        .y1 = y + pin_one_marker_radius_mm,
    };
}

const PinOneContext = struct {
    placement: optimizer.Placement,
    pads: PadField,
    footprint_silk: []const FootprintSilkObstacle,
    keepouts: []const Keepout,
    annotations: []const Annotation,
    reserved_texts: []const font.BoardText,
};

const FootprintSilkObstacle = struct {
    side: optimizer.Side,
    circle: bool,
    x1: f64,
    y1: f64,
    x2: f64 = 0,
    y2: f64 = 0,
    radius: f64 = 0,
};

fn appendFootprintSilkObstacles(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(FootprintSilkObstacle),
    placement: optimizer.Placement,
    excluded_refs: []const []const u8,
) std.mem.Allocator.Error!void {
    for (placement.parts) |part| {
        if (excluded(part.ref_des, excluded_refs)) continue;
        for (part.features.silk_lines) |line| {
            const a = optimizer.worldPadCenter(&part, line.x1, line.y1);
            const b = optimizer.worldPadCenter(&part, line.x2, line.y2);
            try out.append(alloc, .{ .side = part.side, .circle = false, .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1] });
        }
        for (part.features.silk_circles) |circle| {
            if (isAuthoredPinOneIndicator(circle)) continue;
            const center = optimizer.worldPadCenter(&part, circle.cx, circle.cy);
            try out.append(alloc, .{ .side = part.side, .circle = true, .x1 = center[0], .y1 = center[1], .radius = circle.r });
        }
    }
}

fn pinOneHitsFootprintSilk(obstacles: []const FootprintSilkObstacle, side: optimizer.Side, point: [2]f64) bool {
    const required_gap = pin_one_marker_radius_mm + silk_stroke_mm / 2 + label_clearance_mm;
    for (obstacles) |obstacle| {
        if (obstacle.side != side) continue;
        const distance = if (obstacle.circle)
            @abs(std.math.hypot(point[0] - obstacle.x1, point[1] - obstacle.y1) - obstacle.radius)
        else
            pointSegmentDistance(point, .{ obstacle.x1, obstacle.y1 }, .{ obstacle.x2, obstacle.y2 });
        if (distance < required_gap) return true;
    }
    return false;
}

fn pinOneCandidateClear(
    ctx: PinOneContext,
    placed: []const PinOneMarker,
    side: optimizer.Side,
    point: [2]f64,
) bool {
    const box = pinOneBox(point[0], point[1]);
    if (pinOneHitsFootprintSilk(ctx.footprint_silk, side, point)) return false;
    if (labelHitsArtOnSide(ctx.annotations, side, box)) return false;
    if (!labelClear(ctx.placement, .{
        .pads = ctx.pads,
        .keepouts = ctx.keepouts,
        .placed = ctx.annotations,
        .user_texts = ctx.reserved_texts,
    }, side, box)) return false;
    for (placed) |marker| {
        if (marker.side != side) continue;
        if (overlaps(box, pinOneBox(marker.x, marker.y), label_clearance_mm)) return false;
    }
    return true;
}

fn appendPinOneCandidate(
    out: *std.ArrayList(PinOneMarker),
    alloc: std.mem.Allocator,
    ctx: PinOneContext,
    part: optimizer.Part,
    point: [2]f64,
) std.mem.Allocator.Error!bool {
    if (!pinOneCandidateClear(ctx, out.items, part.side, point)) return false;
    try out.append(alloc, .{ .ref_des = part.ref_des, .side = part.side, .x = point[0], .y = point[1] });
    return true;
}

/// Collision sources reserved while generated pin-one dots are placed.
pub const PinOneObstacles = struct {
    excluded_refs: []const []const u8 = &.{},
    keepouts: []const Keepout = &.{},
    relief: mask_relief.Relief = .{},
    annotations: []const Annotation = &.{},
    reserved_texts: []const font.BoardText = &.{},
};

/// Place a uniform 0.3 mm filled dot beside pad 1 (or BGA/connector pad A1) of
/// every directional part. An authored sub-0.5 mm circle supplies the preferred
/// corner and is replaced in rendered/fabricated output; otherwise multi-pad
/// hubs and two-pad D/Q parts search outward from pin 1. Placement uses the same
/// board-edge, exact-pad, keepout, footprint/generated-art and text collision
/// checks as sub-circuit labels.
pub fn collectPinOneMarkers(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    obstacles: PinOneObstacles,
) std.mem.Allocator.Error![]PinOneMarker {
    var shape_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer shape_arena_state.deinit();
    var pads: std.ArrayList(PadObstacle) = .empty;
    defer pads.deinit(alloc);
    try appendPadObstacles(alloc, shape_arena_state.allocator(), &pads, placement, obstacles.excluded_refs, obstacles.relief);
    const pad_field = try buildPadField(alloc, pads.items);
    defer pad_field.deinit(alloc);
    var footprint_silk: std.ArrayList(FootprintSilkObstacle) = .empty;
    defer footprint_silk.deinit(alloc);
    try appendFootprintSilkObstacles(alloc, &footprint_silk, placement, obstacles.excluded_refs);
    const ctx = PinOneContext{
        .placement = placement,
        .pads = pad_field,
        .footprint_silk = footprint_silk.items,
        .keepouts = obstacles.keepouts,
        .annotations = obstacles.annotations,
        .reserved_texts = obstacles.reserved_texts,
    };

    var out: std.ArrayList(PinOneMarker) = .empty;
    errdefer out.deinit(alloc);
    for (placement.parts) |part| {
        if (excluded(part.ref_des, obstacles.excluded_refs)) continue;
        const pad = pinOnePad(part) orelse continue;
        var authored: ?geometry.SilkCircle = null;
        for (part.features.silk_circles) |circle| {
            if (!isAuthoredPinOneIndicator(circle)) continue;
            authored = circle;
            break;
        }
        if (!isDirectionalPart(part, authored != null)) continue;
        const pin = optimizer.worldPadCenter(&part, pad.x, pad.y);
        const old = if (authored) |indicator|
            optimizer.worldPadCenter(&part, indicator.cx, indicator.cy)
        else
            pin;
        var dx = if (authored != null) old[0] - pin[0] else pin[0] - part.x;
        var dy = if (authored != null) old[1] - pin[1] else pin[1] - part.y;
        var length = std.math.hypot(dx, dy);
        if (length < 1e-9) {
            dx = pin[0] - part.x;
            dy = pin[1] - part.y;
            length = std.math.hypot(dx, dy);
        }
        if (length < 1e-9) {
            dx = -1;
            dy = -1;
            length = std.math.sqrt(2.0);
        }
        const base_angle = std.math.atan2(dy / length, dx / length);

        // Preserve an already-good authored location before searching; this
        // keeps the generated dot on the package's intended pin-one corner.
        if (authored != null and try appendPinOneCandidate(&out, alloc, ctx, part, old)) continue;

        const pad_radius = @max(pad.w, pad.h) / 2;
        const first_radius = pad_radius + label_clearance_mm + pin_one_marker_radius_mm;
        const steps: usize = @intFromFloat(@ceil(pin_one_search_radius_mm / pin_one_search_step_mm));
        var placed = false;
        for (0..steps + 1) |ri| {
            const radius = first_radius + @as(f64, @floatFromInt(ri)) * pin_one_search_step_mm;
            // Authored direction first, then alternate around the pin so equal-
            // distance candidates retain the footprint designer's corner.
            const offsets = [_]f64{ 0, -1, 1, -2, 2, -3, 3, 4 };
            for (offsets) |octant| {
                const angle = base_angle + octant * std.math.pi / 4;
                const x = pin[0] + radius * @cos(angle);
                const y = pin[1] + radius * @sin(angle);
                if (try appendPinOneCandidate(&out, alloc, ctx, part, .{ x, y })) {
                    placed = true;
                    break;
                }
            }
            if (placed) break;
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Free a marker slice returned by `collectPinOneMarkers`.
pub fn deinitPinOneMarkers(alloc: std.mem.Allocator, markers: []PinOneMarker) void {
    alloc.free(markers);
}

fn fabricationIdCandidateClear(
    placement: optimizer.Placement,
    pads: PadField,
    keepouts: []const Keepout,
    annotations: []const Annotation,
    reserved_texts: []const font.BoardText,
    candidate: font.BoardText,
) bool {
    const side: optimizer.Side = if (candidate.bottom) .bottom else .top;
    const box = textBox(candidate);
    if (labelHitsArtOnSide(annotations, side, box)) return false;
    return labelClear(placement, .{
        .pads = pads,
        .keepouts = keepouts,
        .placed = annotations,
        .user_texts = reserved_texts,
    }, side, box);
}

fn searchFabricationIdOrientation(
    placement: optimizer.Placement,
    pad_field: PadField,
    obstacles: FabricationIdObstacles,
    identity: []const u8,
    board: optimizer.BoardRect,
    rot: f64,
) ?font.BoardText {
    const inset = labelBoardInset(placement);
    const vertical = @abs(@mod(rot, 180.0) - 90.0) < 0.001;
    const text_width = textWidth(identity, fabrication_id_size_mm);
    const text_height = textHeight(fabrication_id_size_mm);
    const half_width = (if (vertical) text_height else text_width) / 2;
    const half_height = (if (vertical) text_width else text_height) / 2;
    const xlo = board.minx + inset + half_width;
    const xhi = board.minx + board.w - inset - half_width;
    const ylo = board.miny + inset + half_height;
    const yhi = board.miny + board.h - inset - half_height;
    if (xlo > xhi or ylo > yhi) return null;

    // Exact bottom-right, with face fallback before moving away from it.
    for ([_]bool{ false, true }) |bottom| {
        const candidate = font.BoardText{ .x = xhi, .y = yhi, .rot = rot, .bottom = bottom, .size = fabrication_id_size_mm, .text = identity, .fabrication_id = true };
        if (fabricationIdCandidateClear(placement, pad_field, obstacles.keepouts, obstacles.annotations, obstacles.reserved_texts, candidate)) return candidate;
    }

    const nx: usize = @max(1, @as(usize, @intFromFloat(@ceil((xhi - xlo) / nearby_search_step_mm))));
    // Finish the bottom edge right-to-left, top face first and then bottom.
    for ([_]bool{ false, true }) |bottom| {
        for (1..nx + 1) |xi| {
            const x = if (xi == nx) xlo else xhi - @as(f64, @floatFromInt(xi)) * nearby_search_step_mm;
            const candidate = font.BoardText{ .x = x, .y = yhi, .rot = rot, .bottom = bottom, .size = fabrication_id_size_mm, .text = identity, .fabrication_id = true };
            if (fabricationIdCandidateClear(placement, pad_field, obstacles.keepouts, obstacles.annotations, obstacles.reserved_texts, candidate)) return candidate;
        }
    }

    // A packed bottom edge should not erase the identifier: scan remaining
    // board rows from bottom to top, preserving top-before-bottom preference.
    const ny: usize = @max(1, @as(usize, @intFromFloat(@ceil((yhi - ylo) / nearby_search_step_mm))));
    for (1..ny + 1) |yi| {
        const y = if (yi == ny) ylo else yhi - @as(f64, @floatFromInt(yi)) * nearby_search_step_mm;
        for ([_]bool{ false, true }) |bottom| {
            for (0..nx + 1) |xi| {
                const x = if (xi == nx) xlo else xhi - @as(f64, @floatFromInt(xi)) * nearby_search_step_mm;
                const candidate = font.BoardText{ .x = x, .y = y, .rot = rot, .bottom = bottom, .size = fabrication_id_size_mm, .text = identity, .fabrication_id = true };
                if (fabricationIdCandidateClear(placement, pad_field, obstacles.keepouts, obstacles.annotations, obstacles.reserved_texts, candidate)) return candidate;
            }
        }
    }
    return null;
}

/// Place a short fabrication identity with the generated-label collision
/// rules. Priority is the exact bottom-right of top silk, then bottom silk,
/// then the rest of that bottom edge (top before bottom), followed by higher
/// rows as a last resort. Returned text borrows `identity`.
pub const FabricationIdObstacles = struct {
    keepouts: []const Keepout,
    relief: mask_relief.Relief,
    annotations: []const Annotation,
    reserved_texts: []const font.BoardText,
};

/// Search both silk faces for a collision-free fabrication-ID position.
/// Horizontal text remains preferred; narrow boards fall back to a quarter
/// turn so a long identity can run along a flex cable or board edge.
pub fn placeFabricationId(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    obstacles: FabricationIdObstacles,
    identity: []const u8,
) std.mem.Allocator.Error!?font.BoardText {
    return placeFabricationIdWithPreferred(alloc, placement, obstacles, identity, null);
}

/// As `placeFabricationId`, but preserve a previously adopted editor position.
/// The persisted mark is still replaced with the newly derived identity, so a
/// board geometry change cannot leave stale ID text behind.
pub fn placeFabricationIdWithPreferred(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    obstacles: FabricationIdObstacles,
    identity: []const u8,
    preferred: ?font.BoardText,
) std.mem.Allocator.Error!?font.BoardText {
    if (preferred) |old| return .{
        .x = old.x,
        .y = old.y,
        .rot = old.rot,
        .bottom = old.bottom,
        .size = if (old.size > 0) old.size else fabrication_id_size_mm,
        .text = identity,
        .fabrication_id = true,
    };
    const board = placement.board_rect orelse optimizer.BoardRect{
        .minx = placement.minx,
        .miny = placement.miny,
        .w = placement.maxx - placement.minx,
        .h = placement.maxy - placement.miny,
    };
    var shape_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer shape_arena_state.deinit();
    var pads: std.ArrayList(PadObstacle) = .empty;
    defer pads.deinit(alloc);
    try appendPadObstacles(alloc, shape_arena_state.allocator(), &pads, placement, &.{}, obstacles.relief);
    const pad_field = try buildPadField(alloc, pads.items);
    defer pad_field.deinit(alloc);
    return searchFabricationIdOrientation(placement, pad_field, obstacles, identity, board, 0) orelse
        searchFabricationIdOrientation(placement, pad_field, obstacles, identity, board, 90);
}

fn cornerScore(x_fraction: f64, y_fraction: f64) f64 {
    return @min(
        @min(x_fraction + y_fraction, (1 - x_fraction) + y_fraction),
        @min(x_fraction + (1 - y_fraction), (1 - x_fraction) + (1 - y_fraction)),
    );
}

fn placeInside(
    ctx: LabelPlacementContext,
    placed: []const Annotation,
    annotation: Annotation,
) ?font.BoardText {
    const obstacles = LabelObstacles{ .pads = ctx.pads, .keepouts = ctx.keepouts, .placed = placed, .user_texts = ctx.user_texts };
    const width = textWidth(annotation.name, subcircuit_label_size_mm);
    const xlo = annotation.minx + width / 2;
    const xhi = annotation.maxx - width / 2;
    const half_h = textHeight(subcircuit_label_size_mm) / 2;
    const ylo = annotation.miny + half_h;
    const yhi = annotation.maxy - half_h;
    if (xlo > xhi or ylo > yhi) return null;
    var best: ?Candidate = null;
    for (corner_fractions) |yf| {
        for (corner_fractions) |xf| {
            const text = font.BoardText{
                .x = xlo + xf * (xhi - xlo),
                .y = ylo + yf * (yhi - ylo),
                .bottom = annotation.side == .bottom,
                .size = subcircuit_label_size_mm,
                .text = annotation.name,
                .rot = 0,
            };
            const b = textBox(text);
            if (labelHitsGeneratedArt(ctx.art, annotation, b)) continue;
            if (!labelClear(ctx.placement, obstacles, annotation.side, b)) continue;
            const candidate = Candidate{ .text = text, .score = cornerScore(xf, yf) };
            if (best == null or candidate.score < best.?.score) best = candidate;
        }
    }
    return if (best) |candidate| candidate.text else null;
}

fn distanceToInterval(v: f64, lo: f64, hi: f64) f64 {
    if (v < lo) return lo - v;
    if (v > hi) return v - hi;
    return 0;
}

/// Exhaust the printable board on a deterministic half-millimetre grid and
/// choose the location nearest the annotation box. This path is deliberately
/// last: ordinary boards take the compact edge/interior slots above, while a
/// crowded box still keeps its name somewhere nearby instead of losing it.
fn placeNearby(
    ctx: LabelPlacementContext,
    placed: []const Annotation,
    annotation: Annotation,
) ?font.BoardText {
    const obstacles = LabelObstacles{ .pads = ctx.pads, .keepouts = ctx.keepouts, .placed = placed, .user_texts = ctx.user_texts };
    const width = textWidth(annotation.name, subcircuit_label_size_mm);
    const board = ctx.placement.board_rect orelse optimizer.BoardRect{
        .minx = ctx.placement.minx,
        .miny = ctx.placement.miny,
        .w = ctx.placement.maxx - ctx.placement.minx,
        .h = ctx.placement.maxy - ctx.placement.miny,
    };
    const inset = labelBoardInset(ctx.placement);
    const xlo = board.minx + inset + width / 2;
    const xhi = board.minx + board.w - inset - width / 2;
    const half_h = textHeight(subcircuit_label_size_mm) / 2;
    const ylo = board.miny + inset + half_h;
    const yhi = board.miny + board.h - inset - half_h;
    if (xlo > xhi or ylo > yhi) return null;

    const nx: usize = @max(1, @as(usize, @intFromFloat(@ceil((xhi - xlo) / nearby_search_step_mm))));
    const ny: usize = @max(1, @as(usize, @intFromFloat(@ceil((yhi - ylo) / nearby_search_step_mm))));
    var best: ?Candidate = null;
    for (0..ny + 1) |yi| {
        const y = if (yi == ny) yhi else x: {
            break :x ylo + @as(f64, @floatFromInt(yi)) * nearby_search_step_mm;
        };
        for (0..nx + 1) |xi| {
            const x = if (xi == nx) xhi else x_: {
                break :x_ xlo + @as(f64, @floatFromInt(xi)) * nearby_search_step_mm;
            };
            const text = font.BoardText{
                .x = x,
                .y = y,
                .bottom = annotation.side == .bottom,
                .size = subcircuit_label_size_mm,
                .text = annotation.name,
                .rot = 0,
            };
            const b = textBox(text);
            if (labelHitsGeneratedArt(ctx.art, annotation, b)) continue;
            if (!labelClear(ctx.placement, obstacles, annotation.side, b)) continue;
            const dx = distanceToInterval(x, annotation.minx, annotation.maxx);
            const dy = distanceToInterval(y, annotation.miny, annotation.maxy);
            const candidate = Candidate{ .text = text, .score = dx * dx + dy * dy };
            if (best == null or candidate.score < best.?.score) best = candidate;
        }
    }
    return if (best) |candidate| candidate.text else null;
}

fn placeLabel(
    placement: optimizer.Placement,
    pads: PadField,
    keepouts: []const Keepout,
    placed: []const Annotation,
    user_texts: []const font.BoardText,
    annotation: Annotation,
) ?font.BoardText {
    return placeLabelWithArt(.{
        .placement = placement,
        .pads = pads,
        .keepouts = keepouts,
        .user_texts = user_texts,
        .art = &.{},
    }, placed, annotation);
}

fn placeLabelWithArt(
    ctx: LabelPlacementContext,
    placed: []const Annotation,
    annotation: Annotation,
) ?font.BoardText {
    const obstacles = LabelObstacles{ .pads = ctx.pads, .keepouts = ctx.keepouts, .placed = placed, .user_texts = ctx.user_texts };
    const edges = [_]Edge{ .top, .bottom };
    // Tier 1: horizontal, inline, and as close to a corner as space permits.
    for (corner_fractions) |fraction| for (edges) |edge| {
        const candidate = edgeCandidate(annotation, edge, fraction, 0) orelse continue;
        if (labelHitsGeneratedArt(ctx.art, annotation, textBox(candidate))) continue;
        if (labelClear(ctx.placement, obstacles, annotation.side, textBox(candidate))) return candidate;
    };
    // Tier 2: retain the same X slots and move one millimetre off the edge;
    // search inward first, then outward when the board has room.
    for (corner_fractions) |fraction| for (edges) |edge| {
        const inward = if (edge == .top) label_edge_offset_mm else -label_edge_offset_mm;
        for ([_]f64{ inward, -inward }) |shift| {
            const candidate = edgeCandidate(annotation, edge, fraction, shift) orelse continue;
            if (labelHitsGeneratedArt(ctx.art, annotation, textBox(candidate))) continue;
            if (labelClear(ctx.placement, obstacles, annotation.side, textBox(candidate))) return candidate;
        }
    };
    // Tier 3: search the whole box, preferring open positions nearest a corner.
    if (placeInside(ctx, placed, annotation)) |label| return label;
    // Tier 4: keep expanding across valid board space. A crowded box should
    // move its name, not erase it.
    return placeNearby(ctx, placed, annotation);
}

fn pointSegmentDistance(p: [2]f64, a: [2]f64, b: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    const t = if (len2 > 0)
        std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2, 0, 1)
    else
        0;
    return std.math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

fn pointInsideBoardArtwork(placement: optimizer.Placement, point: [2]f64) bool {
    const br = placement.board_rect orelse return true;
    const inset = perimeter_fence.keepoutLimit(placement) + fragment_center_clearance_mm;
    const d = if (placement.board_poly) |points|
        outline.signedInset(points, point[0], point[1])
    else
        @min(
            @min(point[0] - br.minx, br.minx + br.w - point[0]),
            @min(point[1] - br.miny, br.miny + br.h - point[1]),
        );
    return d >= inset;
}

fn pointHitsKeepout(point: [2]f64, keepout: Keepout) bool {
    const poly = keepout.polygon;
    if (poly.len < 3) return false;
    if (outline.contains(poly, point[0], point[1])) return true;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        if (pointSegmentDistance(point, poly[j], p) <= fragment_center_clearance_mm) return true;
        j = i;
    }
    return false;
}

fn pointPrintable(
    ctx: ClipContext,
    point: [2]f64,
) bool {
    if (!pointInsideBoardArtwork(ctx.placement, point)) return false;
    if (padsHitPoint(ctx.pads, ctx.side, point)) return false;
    for (ctx.keepouts) |keepout| if (pointHitsKeepout(point, keepout)) return false;
    return true;
}

const ClipContext = struct {
    placement: optimizer.Placement,
    pads: PadField,
    keepouts: []const Keepout,
    side: optimizer.Side,
};

fn pointAlong(segment: Segment, t: f64) [2]f64 {
    return .{
        segment.x1 + (segment.x2 - segment.x1) * t,
        segment.y1 + (segment.y2 - segment.y1) * t,
    };
}

fn transitionAt(
    ctx: ClipContext,
    segment: Segment,
    t0: f64,
    t1: f64,
    printable0: bool,
) f64 {
    var lo = t0;
    var hi = t1;
    for (0..14) |_| {
        const mid = (lo + hi) / 2;
        if (pointPrintable(ctx, pointAlong(segment, mid)) == printable0)
            lo = mid
        else
            hi = mid;
    }
    return (lo + hi) / 2;
}

fn appendFragment(out: *std.ArrayList(Segment), alloc: std.mem.Allocator, raw: Segment, t0: f64, t1: f64) !void {
    const len = std.math.hypot(raw.x2 - raw.x1, raw.y2 - raw.y1) * (t1 - t0);
    if (len < 0.01) return;
    const a = pointAlong(raw, t0);
    const b = pointAlong(raw, t1);
    try out.append(alloc, .{ .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1] });
}

fn appendClippedArm(
    out: *std.ArrayList(Segment),
    alloc: std.mem.Allocator,
    ctx: ClipContext,
    raw: Segment,
) !void {
    const len = std.math.hypot(raw.x2 - raw.x1, raw.y2 - raw.y1);
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(len / fragment_sample_mm))));
    var previous_t: f64 = 0;
    var previous_printable = pointPrintable(ctx, pointAlong(raw, 0));
    var run_start: ?f64 = if (previous_printable) 0 else null;
    for (1..steps + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const printable = pointPrintable(ctx, pointAlong(raw, t));
        if (printable != previous_printable) {
            const edge = transitionAt(ctx, raw, previous_t, t, previous_printable);
            if (previous_printable)
                try appendFragment(out, alloc, raw, run_start.?, edge)
            else
                run_start = edge;
        }
        previous_t = t;
        previous_printable = printable;
    }
    if (previous_printable) try appendFragment(out, alloc, raw, run_start.?, 1);
}

fn clipSegments(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    pads: PadField,
    keepouts: []const Keepout,
    annotation: *Annotation,
) !void {
    var fragments: std.ArrayList(Segment) = .empty;
    defer fragments.deinit(alloc);
    const ctx = ClipContext{ .placement = placement, .pads = pads, .keepouts = keepouts, .side = annotation.side };
    if (annotation.artwork.raw) |raw_segments| {
        for (raw_segments) |raw| try appendClippedArm(&fragments, alloc, ctx, raw);
    } else {
        for (annotation.segments()) |raw| try appendClippedArm(&fragments, alloc, ctx, raw);
    }
    annotation.artwork.clipped = try fragments.toOwnedSlice(alloc);
}

const Accum = struct {
    name: []const u8,
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,
    side: optimizer.Side,
    main_rank: u8 = 0,
    main_area: f64 = 0,
};

fn groupName(ref: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, ref, '/') orelse return null;
    if (slash == 0) return null;
    return ref[0..slash];
}

fn leafName(ref: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, ref, '/') orelse return ref;
    return ref[slash + 1 ..];
}

/// Main-side preference: an IC-style U hub outranks another hub; passives are
/// only the fallback for an unusual one-part/passive-only module.
fn mainRank(part: optimizer.Part) u8 {
    if (part.kind != .hub) return 0;
    const leaf = leafName(part.ref_des);
    return if (leaf.len > 0 and std.ascii.toUpper(leaf[0]) == 'U') 2 else 1;
}

fn excluded(ref: []const u8, refs: []const []const u8) bool {
    for (refs) |candidate| if (std.mem.eql(u8, ref, candidate)) return true;
    return false;
}

/// Move two facing edges of nearby same-side annotation boxes to their shared
/// midpoint when the gap between them is under `edge_snap_gap_mm`. The four
/// span arguments are the perpendicular-axis projections of the two boxes;
/// they must overlap for the edges to actually face one another.
fn snapEdgePair(e0: *f64, e1: *f64, p0lo: f64, p0hi: f64, p1lo: f64, p1hi: f64) bool {
    const gap = e1.* - e0.*;
    if (gap <= 0 or gap >= edge_snap_gap_mm) return false;
    if (@max(p0lo, p1lo) >= @min(p0hi, p1hi)) return false;
    const midpoint = (e0.* + e1.*) / 2;
    e0.* = midpoint;
    e1.* = midpoint;
    return true;
}

/// Align facing edges of same-face annotation boxes that come within
/// `edge_snap_gap_mm` of each other. Iterating to a fixed point lets a chain
/// of close boxes settle on one common line; every pass only closes gaps, so
/// the result is stable and the pass count is bounded by the box count.
fn snapNearbyEdges(annotations: []Annotation) void {
    const n = annotations.len;
    var changed = true;
    var passes: usize = 0;
    while (changed and passes <= n) : (passes += 1) {
        changed = false;
        for (0..n) |i| {
            for (i + 1..n) |j| {
                if (annotations[i].side != annotations[j].side) continue;
                const a = &annotations[i];
                const b = &annotations[j];
                const a_y0 = a.miny;
                const a_y1 = a.maxy;
                const b_y0 = b.miny;
                const b_y1 = b.maxy;
                changed = snapEdgePair(&a.maxx, &b.minx, a_y0, a_y1, b_y0, b_y1) or changed;
                changed = snapEdgePair(&b.maxx, &a.minx, b_y0, b_y1, a_y0, a_y1) or changed;
                const a_x0 = a.minx;
                const a_x1 = a.maxx;
                const b_x0 = b.minx;
                const b_x1 = b.maxx;
                changed = snapEdgePair(&a.maxy, &b.miny, a_x0, a_x1, b_x0, b_x1) or changed;
                changed = snapEdgePair(&b.maxy, &a.miny, b_x0, b_x1, a_x0, a_x1) or changed;
            }
        }
    }
}

/// Axis-aligned bounds of a keepout polygon, used to reject far segments
/// before the exact point sampling.
const KeepoutBounds = struct { minx: f64, miny: f64, maxx: f64, maxy: f64 };

fn keepoutBounds(polygon: []const [2]f64) KeepoutBounds {
    var b = KeepoutBounds{
        .minx = std.math.inf(f64),
        .miny = std.math.inf(f64),
        .maxx = -std.math.inf(f64),
        .maxy = -std.math.inf(f64),
    };
    for (polygon) |p| {
        b.minx = @min(b.minx, p[0]);
        b.miny = @min(b.miny, p[1]);
        b.maxx = @max(b.maxx, p[0]);
        b.maxy = @max(b.maxy, p[1]);
    }
    return b;
}

/// True if any point of `segment` comes within the finished-stroke clearance
/// of a keepout, meaning the clipping pass would cut the stroke there.
fn segmentHitsKeepout(segment: Segment, keepouts: []const Keepout) bool {
    const x0 = @min(segment.x1, segment.x2) - fragment_center_clearance_mm;
    const x1 = @max(segment.x1, segment.x2) + fragment_center_clearance_mm;
    const y0 = @min(segment.y1, segment.y2) - fragment_center_clearance_mm;
    const y1 = @max(segment.y1, segment.y2) + fragment_center_clearance_mm;
    const len = std.math.hypot(segment.x2 - segment.x1, segment.y2 - segment.y1);
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(len / fragment_sample_mm))));
    for (keepouts) |keepout| {
        const poly = keepout.polygon;
        if (poly.len < 3) continue;
        const b = keepoutBounds(poly);
        if (x1 < b.minx or x0 > b.maxx or y1 < b.miny or y0 > b.maxy) continue;
        for (0..steps + 1) |i| {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            if (pointHitsKeepout(pointAlong(segment, t), keepout)) return true;
        }
    }
    return false;
}

/// True when none of the annotation's eight corner strokes would be clipped by
/// a keepout.
fn boxClearOfKeepouts(annotation: Annotation, keepouts: []const Keepout) bool {
    for (annotation.segments()) |segment| {
        if (segmentHitsKeepout(segment, keepouts)) return false;
    }
    return true;
}

/// A keepout that would clip a sub-circuit box's corner marks translates the
/// whole box by the smallest step that lets every mark draw whole, so the
/// annotation survives next to a no-silkscreen area instead of showing a cut
/// bracket. Pads and Edge.Cuts still clip afterwards as a safety net.
fn shiftBoxesClearOfKeepouts(annotations: []Annotation, keepouts: []const Keepout) void {
    if (keepouts.len == 0) return;
    const max_steps: usize = @intFromFloat(@floor(keepout_shift_max_mm / keepout_shift_step_mm));
    const max_i: i32 = @intCast(max_steps);
    for (annotations) |*a| {
        if (boxClearOfKeepouts(a.*, keepouts)) continue;
        var best: ?[2]f64 = null;
        var best_score: f64 = std.math.inf(f64);
        var dx_i: i32 = -max_i;
        while (dx_i <= max_i) : (dx_i += 1) {
            const dx = @as(f64, @floatFromInt(dx_i)) * keepout_shift_step_mm;
            var dy_i: i32 = -max_i;
            while (dy_i <= max_i) : (dy_i += 1) {
                const dy = @as(f64, @floatFromInt(dy_i)) * keepout_shift_step_mm;
                const score = @abs(dx) + @abs(dy);
                if (score >= best_score) continue;
                var shifted = a.*;
                shifted.minx += dx;
                shifted.miny += dy;
                shifted.maxx += dx;
                shifted.maxy += dy;
                if (boxClearOfKeepouts(shifted, keepouts)) {
                    best = .{ dx, dy };
                    best_score = score;
                }
            }
        }
        if (best) |offset| {
            a.minx += offset[0];
            a.miny += offset[1];
            a.maxx += offset[0];
            a.maxy += offset[1];
        }
    }
}

/// Collect one annotation per top-level flattened sub-circuit, preserving
/// first appearance order so JSON/render output stays deterministic. Refs in
/// `excluded_refs` do not stretch an annotation (the PNG/browser pass staged
/// parts here; fabrication passes an empty slice after its readiness gate).
pub fn collect(alloc: std.mem.Allocator, placement: optimizer.Placement, excluded_refs: []const []const u8) std.mem.Allocator.Error![]Annotation {
    return collectWithKeepouts(alloc, placement, excluded_refs, &.{});
}

/// `collect` with saved/imported no-silkscreen polygons included in both label
/// placement and corner-stroke clipping.
pub fn collectWithKeepouts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    excluded_refs: []const []const u8,
    keepouts: []const Keepout,
) std.mem.Allocator.Error![]Annotation {
    return collectWithObstacles(alloc, placement, excluded_refs, keepouts, .{});
}

/// `collectWithKeepouts` plus the board's solder-mask relief: silkscreen ink
/// on bare (mask-relieved) RF copper is scrap, so every relieved stroke and
/// opening is an obstacle exactly like a pad — corner legs crossing one are
/// suppressed and labels search past it.
pub fn collectWithObstacles(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    excluded_refs: []const []const u8,
    keepouts: []const Keepout,
    relief: mask_relief.Relief,
) std.mem.Allocator.Error![]Annotation {
    return collectWithBoardTexts(alloc, placement, excluded_refs, keepouts, relief, &.{});
}

/// Full collection path for board renderers. Editable board text is treated as
/// a placement obstacle; a text tagged with a matching `subcircuit` identity
/// also replaces that group's generated name.
pub fn collectWithBoardTexts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    excluded_refs: []const []const u8,
    keepouts: []const Keepout,
    relief: mask_relief.Relief,
    user_texts: []const font.BoardText,
) std.mem.Allocator.Error![]Annotation {
    var by_name = std.StringHashMapUnmanaged(usize).empty;
    defer by_name.deinit(alloc);
    var groups: std.ArrayList(Accum) = .empty;
    defer groups.deinit(alloc);

    for (placement.parts) |part| {
        if (excluded(part.ref_des, excluded_refs)) continue;
        const name = groupName(part.ref_des) orelse continue;
        const got = try by_name.getOrPut(alloc, name);
        var gi: usize = undefined;
        if (got.found_existing) {
            gi = got.value_ptr.*;
        } else {
            const r = optimizer.worldCourtyard(&part);
            gi = groups.items.len;
            got.value_ptr.* = gi;
            try groups.append(alloc, .{
                .name = name,
                .minx = r.minx,
                .miny = r.miny,
                .maxx = r.minx + r.w,
                .maxy = r.miny + r.h,
                .side = part.side,
            });
        }

        const r = optimizer.worldCourtyard(&part);
        const g = &groups.items[gi];
        g.minx = @min(g.minx, r.minx);
        g.miny = @min(g.miny, r.miny);
        g.maxx = @max(g.maxx, r.minx + r.w);
        g.maxy = @max(g.maxy, r.miny + r.h);
        const rank = mainRank(part);
        const area = 4 * part.hw * part.hh;
        if (rank > g.main_rank or (rank == g.main_rank and area > g.main_area)) {
            g.main_rank = rank;
            g.main_area = area;
            g.side = part.side;
        }
    }

    // Cache each world pad shape once. Courtyards define the annotation box but
    // are intentionally not exclusions: only real pads forbid silk ink.
    var shape_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer shape_arena_state.deinit();
    const shape_arena = shape_arena_state.allocator();
    var pads: std.ArrayList(PadObstacle) = .empty;
    defer pads.deinit(alloc);
    try appendPadObstacles(alloc, shape_arena, &pads, placement, excluded_refs, relief);
    const pad_field = try buildPadField(alloc, pads.items);
    defer pad_field.deinit(alloc);
    const out = try alloc.alloc(Annotation, groups.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |annotation| {
            if (annotation.artwork.raw) |segments| alloc.free(segments);
            alloc.free(annotation.artwork.clipped);
        }
        alloc.free(out);
    }
    for (groups.items, out) |g, *a| {
        a.* = .{
            .name = g.name,
            .side = g.side,
            .minx = g.minx - courtyard_margin_mm,
            .miny = g.miny - courtyard_margin_mm,
            .maxx = g.maxx + courtyard_margin_mm,
            .maxy = g.maxy + courtyard_margin_mm,
            // Filled by the collision-aware search below. An empty label is
            // the safe last resort for a physically full board: never print
            // silk across a pad/keepout or outside Edge.Cuts.
            .label_text = .{ .x = 0, .y = 0, .bottom = g.side == .bottom, .size = subcircuit_label_size_mm, .text = "" },
        };
        initialized += 1;
    }
    // Each sub-circuit draws its own four corner marks. Nearby same-face boxes
    // first align their close edges on the shared midpoint, and a box whose
    // marks a keepout would clip shifts itself so they still draw whole.
    snapNearbyEdges(out);
    shiftBoxesClearOfKeepouts(out, keepouts);
    const label_ctx = LabelPlacementContext{
        .placement = placement,
        .pads = pad_field,
        .keepouts = keepouts,
        .user_texts = user_texts,
        .art = out,
    };
    for (out, 0..) |*a, i| {
        var overridden = false;
        for (user_texts) |text| {
            const owner = text.owner orelse continue;
            const subcircuit = switch (owner) {
                .subcircuit => |subcircuit| subcircuit,
                else => continue,
            };
            if (std.mem.eql(u8, subcircuit, a.name)) {
                overridden = true;
                break;
            }
        }
        if (!overridden) {
            if (placeLabelWithArt(label_ctx, out[0..i], a.*)) |label| a.label_text = label;
        }
        try clipSegments(alloc, placement, pad_field, keepouts, a);
    }
    return out;
}

/// Release annotations returned by `collect` or `collectWithKeepouts`, including
/// the variable-length stroke fragments owned by each annotation.
pub fn deinitCollected(alloc: std.mem.Allocator, annotations: []Annotation) void {
    for (annotations) |annotation| {
        if (annotation.artwork.raw) |segments| alloc.free(segments);
        alloc.free(annotation.artwork.clipped);
    }
    alloc.free(annotations);
}

fn labelIsInline(annotation: Annotation, label: font.BoardText) bool {
    if (label.text.len == 0) return false;
    return @abs(@mod(label.rot, 180.0)) < 0.001 and
        (@abs(label.y - annotation.miny) < 1e-9 or @abs(label.y - annotation.maxy) < 1e-9);
}

fn labelTestPlacement() optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -5,
        .maxx = 15,
        .maxy = 15,
        .generated = false,
        .board_rect = .{ .minx = -5, .miny = -5, .w = 20, .h = 20 },
    };
}

fn labelTestAnnotation(name: []const u8) Annotation {
    return .{
        .name = name,
        .side = .top,
        .minx = 0,
        .miny = 2,
        .maxx = 10,
        .maxy = 8,
        .label_text = .{ .x = 0, .y = 0, .size = subcircuit_label_size_mm, .text = "" },
    };
}

// spec: export_gerber - every fabrication package prints its eight-hex content ID at the bottom-right of top silk when that exact slot is clear
test "fabrication ID prefers exact bottom-right top silk" {
    const p = labelTestPlacement();
    const got = (try placeFabricationId(std.testing.allocator, p, .{
        .keepouts = &.{},
        .relief = .{},
        .annotations = &.{},
        .reserved_texts = &.{},
    }, "ID 01234567")).?;
    const board = p.board_rect.?;
    const expected = textBox(got);
    try std.testing.expect(!got.bottom);
    try std.testing.expectEqualStrings("ID 01234567", got.text);
    try std.testing.expectApproxEqAbs(@as(f64, 0), got.rot, 1e-9);
    try std.testing.expectApproxEqAbs(board.minx + board.w - labelBoardInset(p), expected.x1, 1e-9);
    try std.testing.expectApproxEqAbs(board.miny + board.h - labelBoardInset(p), expected.y1, 1e-9);
    try std.testing.expectApproxEqAbs(fabrication_id_cap_height_mm, textHeight(got.size), 1e-9);
}

// spec: export_gerber - a fabrication ID that is too wide for a narrow board rotates along its long axis instead of aborting page and CAM rendering
test "fabrication ID rotates to fit a narrow flex board" {
    var p = labelTestPlacement();
    p.minx = 0;
    p.miny = 0;
    p.maxx = 2;
    p.maxy = 20;
    p.board_rect = .{ .minx = 0, .miny = 0, .w = 2, .h = 20 };

    const got = (try placeFabricationId(std.testing.allocator, p, .{
        .keepouts = &.{},
        .relief = .{},
        .annotations = &.{},
        .reserved_texts = &.{},
    }, "ID 01234567")).?;
    const box = textBox(got);
    const inset = labelBoardInset(p);
    try std.testing.expectApproxEqAbs(@as(f64, 90), got.rot, 1e-9);
    try std.testing.expect(box.x0 >= p.board_rect.?.minx + inset);
    try std.testing.expect(box.x1 <= p.board_rect.?.minx + p.board_rect.?.w - inset);
    try std.testing.expect(box.y0 >= p.board_rect.?.miny + inset);
    try std.testing.expect(box.y1 <= p.board_rect.?.miny + p.board_rect.?.h - inset);
}

// spec: export_gerber - a blocked top-side bottom-right fabrication ID retries that exact slot on bottom silk before moving along the bottom edge
test "fabrication ID falls through to exact bottom-right bottom silk" {
    const identity = "ID 89ABCDEF";
    const empty = labelTestPlacement();
    const preferred = (try placeFabricationId(std.testing.allocator, empty, .{
        .keepouts = &.{},
        .relief = .{},
        .annotations = &.{},
        .reserved_texts = &.{},
    }, identity)).?;
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &pad,
        .fallback = false,
        .x = preferred.x,
        .y = preferred.y,
        .side = .top,
    }};
    var p = empty;
    p.parts = &parts;
    const got = (try placeFabricationId(std.testing.allocator, p, .{
        .keepouts = &.{},
        .relief = .{},
        .annotations = &.{},
        .reserved_texts = &.{},
    }, identity)).?;
    try std.testing.expect(got.bottom);
    try std.testing.expectApproxEqAbs(preferred.x, got.x, 1e-9);
    try std.testing.expectApproxEqAbs(preferred.y, got.y, 1e-9);
}

// spec: export_gerber - when both bottom-right silk faces are blocked, fabrication-ID placement scans the bottom edge right-to-left before using another row
test "fabrication ID scans bottom edge after both corners collide" {
    const identity = "ID FEDCBA98";
    const empty = labelTestPlacement();
    const preferred = (try placeFabricationId(std.testing.allocator, empty, .{
        .keepouts = &.{},
        .relief = .{},
        .annotations = &.{},
        .reserved_texts = &.{},
    }, identity)).?;
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true, .drill = 0.4 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "J1",
        .kind = .hub,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &pad,
        .fallback = false,
        .x = preferred.x,
        .y = preferred.y,
        .side = .top,
    }};
    var p = empty;
    p.parts = &parts;
    const got = (try placeFabricationId(std.testing.allocator, p, .{
        .keepouts = &.{},
        .relief = .{},
        .annotations = &.{},
        .reserved_texts = &.{},
    }, identity)).?;
    try std.testing.expect(!got.bottom);
    try std.testing.expect(got.x < preferred.x);
    try std.testing.expectApproxEqAbs(preferred.y, got.y, 1e-9);
}

// spec: export_gerber - Four L corners bound each isolated flattened sub-circuit, and its fixed-size horizontal label first tries a corner-near slot on the top or bottom edge
test "collects bounded corner marks and chooses the main IC side" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "buck/C1", .kind = .passive, .hw = 0.5, .hh = 0.25, .pads = &.{}, .fallback = false, .x = 8, .y = 5, .side = .top },
        .{ .ref_des = "buck/J1", .kind = .hub, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .x = 4, .y = 5, .side = .top },
        .{ .ref_des = "buck/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 6, .y = 5, .side = .bottom },
        .{ .ref_des = "R9", .kind = .passive, .hw = 0.5, .hh = 0.25, .pads = &.{}, .fallback = false },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("buck", got[0].name);
    try std.testing.expectEqual(optimizer.Side.bottom, got[0].side);
    try std.testing.expectApproxEqAbs(1.5, got[0].minx, 1e-9);
    try std.testing.expectApproxEqAbs(9.0, got[0].maxx, 1e-9);
    const segs = got[0].segments();
    try std.testing.expectApproxEqAbs(got[0].minx + corner_inset_mm, segs[0].x2, 1e-9);
    try std.testing.expectApproxEqAbs(got[0].miny + corner_inset_mm, segs[0].y2, 1e-9);
    const label = got[0].label();
    try std.testing.expect(label.bottom);
    try std.testing.expectEqualStrings("buck", label.text);
    try std.testing.expectApproxEqAbs(subcircuit_label_size_mm, label.size, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), label.rot, 1e-12);
    try std.testing.expect(labelIsInline(got[0], label));
    try std.testing.expectEqual(@as(usize, 8), got[0].visibleSegments().len);

    const staged = [_][]const u8{ "buck/C1", "buck/J1", "buck/U1" };
    const none = try collect(std.testing.allocator, p, &staged);
    defer deinitCollected(std.testing.allocator, none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

// spec: export_gerber - overlapping same-face sub-circuit bounds each keep their own four-corner envelope instead of merging
test "overlapping horizontal sub-circuits keep independent corner envelopes" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "alpha/U1", .kind = .hub, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .x = 4, .y = 5, .side = .top },
        .{ .ref_des = "beta/U1", .kind = .hub, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .x = 7, .y = 5, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 12,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 12, .h = 10 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    // Overlapping boxes no longer merge into one envelope: each keeps its own
    // four corner marks and no edge-T divider is added anywhere.
    try std.testing.expectEqual(@as(usize, 8), got[0].visibleSegments().len);
    try std.testing.expectEqual(@as(usize, 8), got[1].visibleSegments().len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), got[0].minx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.5), got[0].maxx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), got[1].minx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 9.5), got[1].maxx, 1e-9);
}

// spec: export_gerber - chained overlapping sub-circuits keep one independent corner envelope per member instead of merging transitively
test "chained overlapping sub-circuits each keep their own corner envelope" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "a/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 4, .y = 4, .side = .top },
        .{ .ref_des = "b/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 5.8, .y = 5.8, .side = .top },
        .{ .ref_des = "c/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 7.6, .y = 7.6, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 12,
        .maxy = 12,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 12, .h = 12 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 3), got.len);
    // No shared envelope and no edge-T dividers: every member of the overlap
    // chain keeps its own full four-corner envelope.
    try std.testing.expectEqual(@as(usize, 8), got[0].visibleSegments().len);
    try std.testing.expectEqual(@as(usize, 8), got[1].visibleSegments().len);
    try std.testing.expectEqual(@as(usize, 8), got[2].visibleSegments().len);
    // The diagonal neighbours do not face each other on either axis, so their
    // edges keep their own positions (b x∈[4.3,7.3], c x∈[6.1,9.1]).
    try std.testing.expectApproxEqAbs(@as(f64, 7.3), got[1].maxx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.1), got[2].minx, 1e-9);
}

// spec: export_gerber - overlapping sub-circuit bounds on opposite board faces keep independent corner envelopes
test "overlapping opposite-face sub-circuits do not merge" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "top/U1", .kind = .hub, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .side = .top },
        .{ .ref_des = "bottom/U1", .kind = .hub, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .side = .bottom },
    };
    var p = labelTestPlacement();
    p.parts = @constCast(&parts);
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqual(@as(usize, 8), got[0].visibleSegments().len);
    try std.testing.expectEqual(@as(usize, 8), got[1].visibleSegments().len);
}

// spec: export_gerber - same-face sub-circuit boxes whose facing edges come within 1.5 mm snap both edges to the shared midpoint so adjacent envelopes align
test "nearby same-side sub-circuit boxes snap facing edges to the midpoint" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "left/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 2, .y = 5, .side = .top },
        .{ .ref_des = "right/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 5.8, .y = 5, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    // left box x∈[0.5,3.5], right box x∈[4.3,7.3]: the 0.8 mm gap snaps both
    // facing edges to x=3.9 so the envelopes share one aligned edge.
    try std.testing.expectApproxEqAbs(@as(f64, 3.9), got[0].maxx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.9), got[1].minx, 1e-9);
    // Edges on the other axis stay put, and both boxes keep their own marks.
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), got[0].miny, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.5), got[0].maxy, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), got[1].miny, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 6.5), got[1].maxy, 1e-9);
    try std.testing.expectEqual(@as(usize, 8), got[0].visibleSegments().len);
    try std.testing.expectEqual(@as(usize, 8), got[1].visibleSegments().len);
}

// spec: export_gerber - nearby sub-circuit boxes on opposite board faces keep their own edge positions
test "nearby opposite-face sub-circuit boxes do not snap" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "top/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 2, .y = 5, .side = .top },
        .{ .ref_des = "bottom/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 5.8, .y = 5, .side = .bottom },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    // The 0.8 mm gap would snap same-face boxes, but these live on opposite
    // faces so their edges keep their own positions.
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), got[0].maxx, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.3), got[1].minx, 1e-9);
    try std.testing.expectEqual(@as(usize, 8), got[0].visibleSegments().len);
    try std.testing.expectEqual(@as(usize, 8), got[1].visibleSegments().len);
}

// spec: export_gerber - a keepout that would clip a sub-circuit box's corner marks shifts the box slightly so the marks still draw whole
test "keepout near a corner shifts the sub-circuit box so its marks draw whole" {
    const parts = [_]optimizer.Part{.{ .ref_des = "rf/U1", .kind = .hub, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .side = .top }};
    const keepout_poly = [_][2]f64{ .{ 6.8, 3.0 }, .{ 8.6, 3.0 }, .{ 8.6, 7.0 }, .{ 6.8, 7.0 } };
    const keepouts = [_]Keepout{.{ .polygon = &keepout_poly }};
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 12,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 12, .h = 10 },
    };
    const got = try collectWithKeepouts(std.testing.allocator, p, &.{}, &keepouts);
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    // The keepout straddles the box's right edge and would clip the right
    // corner arms, so the whole box shifts left (0.8 mm) until every mark
    // draws clear of it and survives unclipped.
    try std.testing.expect(got[0].maxx < 7.5);
    try std.testing.expectApproxEqAbs(@as(f64, 6.7), got[0].maxx, 1e-6);
    try std.testing.expectEqual(@as(usize, 8), got[0].visibleSegments().len);
    try std.testing.expectEqualStrings("rf", got[0].label().text);
}

// spec: export_gerber - generated sub-circuit legs and names avoid mask-relieved bare copper like pads
test "relieved bare copper clips crossing legs and moves the label" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "rf/U1", .kind = .hub, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .side = .top },
        .{ .ref_des = "rf/C1", .kind = .passive, .hw = 0.5, .hh = 0.25, .pads = &.{}, .fallback = false, .x = 8, .y = 5, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 12,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 12, .h = 10 },
    };
    const clear = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, clear);
    try std.testing.expectEqual(@as(usize, 1), clear.len);
    try std.testing.expectEqual(@as(usize, 8), clear[0].visibleSegments().len);
    const top_y = clear[0].miny;

    // A bare RF band running along the box's top edge: the arms riding that
    // edge are clipped away entirely, the rest of the marks survive, and the
    // name lands clear of the exposed copper.
    const strokes = [_]mask_relief.Stroke{.{
        .x1 = 0,
        .y1 = top_y,
        .x2 = 12,
        .y2 = top_y,
        .layer = 0,
        .widths = .{ .opening = 0.6, .copper = 0.3 },
    }};
    const got = try collectWithObstacles(std.testing.allocator, p, &.{}, &.{}, .{ .strokes = &strokes });
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqual(@as(usize, 0), fragmentsOnRow(got[0], top_y));
    try std.testing.expect(got[0].visibleSegments().len > 0);
    const label = got[0].label();
    try std.testing.expectEqualStrings("rf", label.text);
    try std.testing.expect(@abs(label.y - top_y) > 0.5);
}

/// Test helper: how many printable fragments lie exactly on the row `y`.
fn fragmentsOnRow(a: Annotation, y: f64) usize {
    var n: usize = 0;
    for (a.visibleSegments()) |s| {
        if (@abs(s.y1 - y) < 1e-9 and @abs(s.y2 - y) < 1e-9) n += 1;
    }
    return n;
}

// The 0.2 mm inset brackets leave this 1.6 mm-tall box too short for the
// 0.9 mm name, so the fallback moves it to the nearest printable board space
// just below the box instead of dropping it.
// spec: export_gerber - sub-circuit labels stay horizontal and inside Edge.Cuts by falling back inside their box when a fixed-size name cannot fit inline
test "label search stays on the board near an edge" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "power/U1", .kind = .hub, .hw = 2, .hh = 0.3, .pads = &.{}, .fallback = false, .x = 5, .y = 0.8, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 6,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 6 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    const label = got[0].label();
    try std.testing.expectEqualStrings("power", label.text);
    try std.testing.expectApproxEqAbs(subcircuit_label_size_mm, label.size, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), label.rot, 1e-12);
    try std.testing.expect(!labelIsInline(got[0], label));
    const b = textBox(label);
    // The 0.2 mm inset brackets plus the 0.2 mm finished-ink clearance leave
    // this 1.6 mm-tall box too short for a 0.9 mm name, so the fallback moves
    // the name to the nearest printable board space just below the box.
    try std.testing.expect(b.y0 >= got[0].maxy);
    try std.testing.expect(boxInsideBoard(p, textBox(label)));
}

// spec: export_gerber - fixed-size horizontal sub-circuit labels search left and right near the corners of top and bottom edges before using any fallback
test "label search prefers a corner-near horizontal edge slot" {
    const p = labelTestPlacement();
    const annotation = labelTestAnnotation("edge");
    const label = placeLabel(p, .{}, &.{}, &.{}, &.{}, annotation).?;
    const first = edgeCandidate(annotation, .top, corner_fractions[0], 0).?;
    const expected = edgeCandidate(annotation, .top, corner_fractions[2], 0).?;
    try std.testing.expect(labelHitsCornerArt(annotation, textBox(first)));
    try std.testing.expectApproxEqAbs(expected.x, label.x, 1e-12);
    try std.testing.expectApproxEqAbs(expected.y, label.y, 1e-12);
    try std.testing.expectApproxEqAbs(subcircuit_label_size_mm, label.size, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), label.rot, 1e-12);
}

// spec: export_gerber - blocked inline sub-circuit labels retry the same horizontal corner-near slots 1 mm inward or outward from the top and bottom edges
test "label search shifts one millimetre off blocked edge centerlines" {
    const p = labelTestPlacement();
    const annotation = labelTestAnnotation("off");
    const top = [_][2]f64{ .{ -1, 1.9 }, .{ 11, 1.9 }, .{ 11, 2.1 }, .{ -1, 2.1 } };
    const bottom = [_][2]f64{ .{ -1, 7.9 }, .{ 11, 7.9 }, .{ 11, 8.1 }, .{ -1, 8.1 } };
    const keepouts = [_]Keepout{ .{ .polygon = &top }, .{ .polygon = &bottom } };
    const label = placeLabel(p, .{}, &keepouts, &.{}, &.{}, annotation).?;
    try std.testing.expectApproxEqAbs(annotation.miny + label_edge_offset_mm, label.y, 1e-12);
    try std.testing.expectApproxEqAbs(subcircuit_label_size_mm, label.size, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), label.rot, 1e-12);
}

// spec: export_gerber - a crowded sub-circuit box keeps its name by searching the nearest valid board space beyond the box fallbacks
test "label search expands across the board instead of dropping a crowded name" {
    const p = labelTestPlacement();
    const annotation = labelTestAnnotation("crowded");
    const blocked = [_][2]f64{ .{ -1, 0.5 }, .{ 11, 0.5 }, .{ 11, 9.5 }, .{ -1, 9.5 } };
    const keepouts = [_]Keepout{.{ .polygon = &blocked }};
    const label = placeLabel(p, .{}, &keepouts, &.{}, &.{}, annotation).?;
    try std.testing.expectEqualStrings("crowded", label.text);
    try std.testing.expect(boxInsideBoard(p, textBox(label)));
    try std.testing.expect(!boxHitsKeepout(textBox(label), keepouts[0]));
    try std.testing.expect(!overlaps(textBox(label), .{ .x0 = annotation.minx, .y0 = annotation.miny, .x1 = annotation.maxx, .y1 = annotation.maxy }, 0));
}

// spec: export_gerber - an editable board text tagged with a sub-circuit identity replaces exactly that generated name
test "tagged board text overrides its generated sub-circuit name" {
    const parts = [_]optimizer.Part{.{
        .ref_des = "buck/U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
        .x = 5,
        .y = 5,
        .side = .top,
    }};
    var p = labelTestPlacement();
    p.parts = @constCast(&parts);
    const texts = [_]font.BoardText{.{ .x = 8, .y = 8, .text = "buck", .owner = .{ .subcircuit = "buck" } }};
    const got = try collectWithBoardTexts(std.testing.allocator, p, &.{}, &.{}, .{}, &texts);
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("buck", got[0].name);
    try std.testing.expectEqualStrings("", got[0].label().text);
}

// spec: export_gerber - when edge and 1 mm offset slots are blocked, a fixed-size horizontal sub-circuit label searches anywhere inside its box while preferring corners
test "label search falls back anywhere inside its box" {
    const p = labelTestPlacement();
    const annotation = labelTestAnnotation("box");
    const upper = [_][2]f64{ .{ -1, 0 }, .{ 11, 0 }, .{ 11, 3.8 }, .{ -1, 3.8 } };
    const lower = [_][2]f64{ .{ -1, 6.2 }, .{ 11, 6.2 }, .{ 11, 10 }, .{ -1, 10 } };
    const keepouts = [_]Keepout{ .{ .polygon = &upper }, .{ .polygon = &lower } };
    const label = placeLabel(p, .{}, &keepouts, &.{}, &.{}, annotation).?;
    const b = textBox(label);
    try std.testing.expectApproxEqAbs(@as(f64, 5), label.y, 1e-12);
    try std.testing.expectApproxEqAbs(subcircuit_label_size_mm, label.size, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), label.rot, 1e-12);
    try std.testing.expect(b.x0 >= annotation.minx and b.x1 <= annotation.maxx);
    try std.testing.expect(b.y0 >= annotation.miny and b.y1 <= annotation.maxy);
    try std.testing.expect(label.x < (annotation.minx + annotation.maxx) / 2);
}

// spec: export_gerber - sub-circuit labels respect concave Edge.Cuts instead of trusting the board bounding rectangle
test "label search honors a concave board outline" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "rf/U1", .kind = .hub, .hw = 1.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 8, .y = 7, .side = .top },
    };
    const l_board = [_][2]f64{ .{ 0, 0 }, .{ 6, 0 }, .{ 6, 6 }, .{ 10, 6 }, .{ 10, 10 }, .{ 0, 10 } };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .board_poly = &l_board,
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    const label = got[0].label();
    try std.testing.expectEqualStrings("rf", label.text);
    try std.testing.expect(labelIsInline(got[0], label));
    try std.testing.expectApproxEqAbs(got[0].maxy, label.y, 1e-9);
    try std.testing.expect(boxInsideBoard(p, textBox(label)));
}

// spec: export_gerber - sub-circuit labels may cross courtyards when their inline slot is clear of actual pads
test "label search ignores courtyard-only overlap" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "buck/U1", .kind = .hub, .hw = 3, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .side = .top },
        .{ .ref_des = "J9", .kind = .hub, .hw = 3, .hh = 0.4, .pads = &.{}, .fallback = false, .x = 5, .y = 2.8, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    const label = got[0].label();
    try std.testing.expectEqualStrings("buck", label.text);
    try std.testing.expect(labelIsInline(got[0], label));
    try std.testing.expectApproxEqAbs(got[0].miny, label.y, 1e-9);
    const courtyard = optimizer.worldCourtyard(&parts[1]);
    try std.testing.expect(overlaps(
        textBox(label),
        .{ .x0 = courtyard.minx, .y0 = courtyard.miny, .x1 = courtyard.minx + courtyard.w, .y1 = courtyard.miny + courtyard.h },
        0,
    ));
}

// spec: export_gerber - sub-circuit labels search away from same-side pads instead of printing across them
test "label search avoids pads blocking its preferred edge" {
    const blocker_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 6, .h = 0.4 },
    };
    const parts = [_]optimizer.Part{
        .{ .ref_des = "buck/U1", .kind = .hub, .hw = 3, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .side = .top },
        .{ .ref_des = "J9", .kind = .hub, .hw = 3, .hh = 0.4, .pads = &blocker_pads, .fallback = false, .x = 5, .y = 3.5, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("buck", got[0].label().text);
    try std.testing.expectApproxEqAbs(got[0].maxy, got[0].label().y, 1e-9);
}

// spec: export_gerber - generated sub-circuit names reserve their chosen silk space from later labels on the same face
test "label search keeps generated names from overlapping" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "alpha/U1", .kind = .hub, .hw = 2.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 4, .y = 5, .side = .top },
        .{ .ref_des = "beta/U1", .kind = .hub, .hw = 2.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 7, .y = 5, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 12,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 12, .h = 10 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(got[0].label().text.len > 0);
    try std.testing.expect(got[1].label().text.len > 0);
    try std.testing.expect(!overlaps(textBox(got[0].label()), textBox(got[1].label()), label_clearance_mm));
}

// spec: export_gerber - generated sub-circuit corner arms retain every printable fragment while clipping only the spans crossing Edge.Cuts or same-face pads
test "corner arms clip only their board-edge and same-face-pad spans" {
    const blocker_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
    };
    const parts = [_]optimizer.Part{
        .{ .ref_des = "box/U1", .kind = .hub, .hw = 0.6, .hh = 1, .pads = &.{}, .fallback = false, .x = 1, .y = 5, .side = .top },
        .{ .ref_des = "J9", .kind = .hub, .hw = 0.15, .hh = 0.15, .pads = &blocker_pads, .fallback = false, .x = 2.1, .y = 4.25, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    var has_left_edge = false;
    for (got[0].visibleSegments()) |segment| {
        has_left_edge = has_left_edge or (@abs(segment.x1 - got[0].minx - corner_inset_mm) < 1e-9 and @abs(segment.x2 - got[0].minx - corner_inset_mm) < 1e-9);
        const ctx = ClipContext{
            .placement = p,
            .pads = .{ .pads = &.{.{ .shape = .{ .x0 = 1.95, .y0 = 4.10, .x1 = 2.25, .y1 = 4.40 }, .top = true, .bottom = false }} },
            .keepouts = &.{},
            .side = .top,
        };
        try std.testing.expect(pointPrintable(ctx, pointAlong(segment, 0.5)));
    }
    try std.testing.expect(!has_left_edge);
}

// spec: export_gerber - a pad crossing the middle of one corner arm splits that arm into two silk fragments without removing its printable ends or neighboring arm
test "pad collision splits only the crossing span out of a corner arm" {
    const blocker_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 },
    };
    const parts = [_]optimizer.Part{
        .{ .ref_des = "box/U1", .kind = .hub, .hw = 4, .hh = 4, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .side = .top },
        .{ .ref_des = "J9", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &blocker_pads, .fallback = false, .x = 1.49, .y = 0.5, .side = .top },
    };
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collect(std.testing.allocator, p, &.{});
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    const fragments = got[0].visibleSegments();
    try std.testing.expectEqual(@as(usize, 9), fragments.len);
    try std.testing.expectApproxEqAbs(2.68, fragments[0].x1, 1e-6);
    try std.testing.expectApproxEqAbs(1.84617, fragments[0].x2, 0.001);
    try std.testing.expectApproxEqAbs(1.13383, fragments[1].x1, 0.001);
    try std.testing.expectApproxEqAbs(0.70, fragments[1].x2, 1e-6);
    try std.testing.expectApproxEqAbs(0.70, fragments[2].x1, 1e-6);
    try std.testing.expectApproxEqAbs(0.70, fragments[2].x2, 1e-6);
}

// spec: export_gerber - generated sub-circuit names and stroke fragments keep 0.2 mm of finished-silk clearance from pads, keepouts, and Edge.Cuts
test "generated silk keeps its finished ink 0.2 mm clear" {
    const p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const pad = PadObstacle{ .shape = .{ .x0 = 4, .y0 = 4, .x1 = 6, .y1 = 6 }, .top = true, .bottom = false };
    const keepout_poly = [_][2]f64{ .{ 4, 4 }, .{ 6, 4 }, .{ 6, 6 }, .{ 4, 6 } };
    const pad_ctx = ClipContext{ .placement = p, .pads = .{ .pads = &.{pad} }, .keepouts = &.{}, .side = .top };
    const keepout_ctx = ClipContext{ .placement = p, .pads = .{}, .keepouts = &.{.{ .polygon = &keepout_poly }}, .side = .top };
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), label_clearance_mm, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.275), fragment_center_clearance_mm, 1e-12);
    try std.testing.expect(!pointPrintable(pad_ctx, .{ 6.274, 5 }));
    try std.testing.expect(pointPrintable(pad_ctx, .{ 6.276, 5 }));
    try std.testing.expect(!pointPrintable(keepout_ctx, .{ 6.274, 5 }));
    try std.testing.expect(pointPrintable(keepout_ctx, .{ 6.276, 5 }));
    try std.testing.expect(!pointPrintable(pad_ctx, .{ 0.274, 2 }));
    try std.testing.expect(pointPrintable(pad_ctx, .{ 0.276, 2 }));
}

// spec: export_gerber - saved keepout polygons move generated sub-circuit names away and suppress corner legs that would enter them
test "keepout polygons suppress generated annotation ink" {
    const parts = [_]optimizer.Part{
        .{ .ref_des = "quiet/U1", .kind = .hub, .hw = 2, .hh = 1, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .side = .top },
    };
    const keepout_poly = [_][2]f64{ .{ 2.4, 3.4 }, .{ 7.6, 3.4 }, .{ 7.6, 6.6 }, .{ 2.4, 6.6 } };
    const keepouts = [_]Keepout{.{ .polygon = &keepout_poly }};
    const p = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collectWithKeepouts(std.testing.allocator, p, &.{}, &keepouts);
    defer deinitCollected(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("quiet", got[0].label().text);
    try std.testing.expect(!boxHitsKeepout(textBox(got[0].label()), keepouts[0]));
    try std.testing.expectEqual(@as(usize, 0), got[0].visibleSegments().len);
}

// Regression: footprint circles strictly below 0.5 mm diameter become one
// uniform 0.3 mm filled pin-one dot beside pad 1.
test "pin-one marker replaces a small authored circle at its clear corner" {
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1 }};
    const circles = [_]geometry.SilkCircle{
        .{ .cx = -1, .cy = 0, .r = 0.13 },
        .{ .cx = 0, .cy = 0, .r = 0.25 },
    };
    const parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1.5,
        .hh = 1.5,
        .pads = &pads,
        .fallback = false,
        .features = .{ .silk_circles = &circles },
        .x = 5,
        .y = 5,
    }};
    const placement = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    try std.testing.expect(isAuthoredPinOneIndicator(circles[0]));
    try std.testing.expect(!isAuthoredPinOneIndicator(circles[1]));
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), pin_one_marker_diameter_mm, 1e-12);
    const got = try collectPinOneMarkers(std.testing.allocator, placement, .{});
    defer deinitPinOneMarkers(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("U1", got[0].ref_des);
    try std.testing.expectApproxEqAbs(@as(f64, 4), got[0].x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5), got[0].y, 1e-9);
}

// Directional parts do not need a pre-existing footprint dot. Multi-pad hubs
// and two-terminal D/Q passives are marked, while one-pad physical features
// such as test points remain unmarked.
test "pin-one marker covers directional parts without authored circles" {
    const two_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.4, .h = 0.4 },
    };
    const one_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &two_pads, .fallback = false, .x = 3, .y = 3 },
        .{ .ref_des = "power/D1", .kind = .passive, .hw = 1, .hh = 1, .pads = &two_pads, .fallback = false, .x = 7, .y = 3 },
        .{ .ref_des = "TP1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &one_pad, .fallback = false, .x = 5, .y = 7 },
    };
    const placement = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collectPinOneMarkers(std.testing.allocator, placement, .{});
    defer deinitPinOneMarkers(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("U1", got[0].ref_des);
    try std.testing.expectEqualStrings("power/D1", got[1].ref_des);
}

fn expectMarkerClearOfPads(alloc: std.mem.Allocator, parts: []const optimizer.Part, marker: PinOneMarker) !void {
    var shape_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer shape_arena_state.deinit();
    const dot = pad_shape.Shape{
        .x0 = marker.x - pin_one_marker_radius_mm,
        .y0 = marker.y - pin_one_marker_radius_mm,
        .x1 = marker.x + pin_one_marker_radius_mm,
        .y1 = marker.y + pin_one_marker_radius_mm,
    };
    for (parts) |part| for (part.pads) |pad| {
        const obstacle = try pad_shape.worldShape(shape_arena_state.allocator(), part, pad);
        try std.testing.expect(pad_shape.shapeGap(dot, obstacle, label_clearance_mm) >= label_clearance_mm);
    };
}

// Regression: generated pin-one dots use the sub-circuit text collision checks
// and move away from same-side pads while staying near A1.
test "pin-one marker searches away from a pad collision" {
    const pin_pads = [_]geometry.Pad{.{ .number = "A1", .x = 0, .y = 0, .w = 1, .h = 1 }};
    const blocker_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const circles = [_]geometry.SilkCircle{.{ .cx = -1, .cy = 0, .r = 0.1 }};
    const parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &pin_pads, .fallback = false, .features = .{ .silk_circles = &circles }, .x = 5, .y = 5 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &blocker_pads, .fallback = false, .x = 4, .y = 5 },
    };
    const placement = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collectPinOneMarkers(std.testing.allocator, placement, .{});
    defer deinitPinOneMarkers(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(@abs(got[0].x - 4) > 1e-6 or @abs(got[0].y - 5) > 1e-6);
    try expectMarkerClearOfPads(std.testing.allocator, &parts, got[0]);
}

// Regression: authored footprint outlines share the physical silk layer with
// the generated dot, so their stroked lines must displace it too.
test "pin-one marker searches away from authored footprint silk" {
    const pin_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const indicator = [_]geometry.SilkCircle{.{ .cx = -1, .cy = 0, .r = 0.1 }};
    const blocker_silk = [_]geometry.SilkLine{.{ .x1 = 0, .y1 = -0.5, .x2 = 0, .y2 = 0.5 }};
    const blocker_ring = [_]geometry.SilkCircle{.{ .cx = 3, .cy = 0, .r = 0.5 }};
    const parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &pin_pads, .fallback = false, .features = .{ .silk_circles = &indicator }, .x = 5, .y = 5 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.2, .hh = 0.5, .pads = &.{}, .fallback = false, .features = .{ .silk_lines = &blocker_silk, .silk_circles = &blocker_ring }, .x = 4, .y = 5 },
    };
    const placement = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const got = try collectPinOneMarkers(std.testing.allocator, placement, .{});
    defer deinitPinOneMarkers(std.testing.allocator, got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expect(@abs(got[0].x - 4) > 1e-6 or @abs(got[0].y - 5) > 1e-6);

    var silk: std.ArrayList(FootprintSilkObstacle) = .empty;
    defer silk.deinit(std.testing.allocator);
    try appendFootprintSilkObstacles(std.testing.allocator, &silk, placement, &.{});
    try std.testing.expect(!pinOneHitsFootprintSilk(silk.items, got[0].side, .{ got[0].x, got[0].y }));
    try std.testing.expect(pinOneHitsFootprintSilk(silk.items, .top, .{ 7.5, 5 }));
    try std.testing.expect(!pinOneHitsFootprintSilk(silk.items, .bottom, .{ 7.5, 5 }));
}

/// A dense, deliberately unaligned pad grid for the index test. Offsets that do
/// not divide the cell size are what would expose an off-by-one at a bucket
/// boundary.
fn indexProbePads(alloc: std.mem.Allocator) std.mem.Allocator.Error![]PadObstacle {
    var pads: std.ArrayList(PadObstacle) = .empty;
    errdefer pads.deinit(alloc);
    for (0..200) |i| {
        const x = @as(f64, @floatFromInt(i % 20)) * 2.3 + 0.17;
        const y = @as(f64, @floatFromInt(i / 20)) * 3.1 + 0.29;
        try pads.append(alloc, .{
            .shape = .{ .x0 = x, .y0 = y, .x1 = x + 0.9, .y1 = y + 0.6 },
            .top = i % 3 != 0,
            .bottom = i % 3 != 1,
        });
    }
    return pads.toOwnedSlice(alloc);
}

/// Label-sized probe boxes covering the pad grid and the empty margin around it.
fn indexProbeBoxes(alloc: std.mem.Allocator) std.mem.Allocator.Error![]Rect {
    var out: std.ArrayList(Rect) = .empty;
    errdefer out.deinit(alloc);
    var px: f64 = -2;
    while (px < 48) : (px += 0.9) {
        var py: f64 = -2;
        while (py < 34) : (py += 1.1) {
            try out.append(alloc, .{ .x0 = px, .y0 = py, .x1 = px + 1.2, .y1 = py + 0.5 });
        }
    }
    return out.toOwnedSlice(alloc);
}

// spec: export_gerber - silk label placement clears pads through a spatial index that answers every clearance probe exactly as a full pad scan
test "the pad index answers every clearance probe exactly as a flat scan" {
    const alloc = std.testing.allocator;
    const pads = try indexProbePads(alloc);
    defer alloc.free(pads);
    const boxes = try indexProbeBoxes(alloc);
    defer alloc.free(boxes);
    // nx == 0 is the un-indexed field, i.e. the flat scan.
    const flat = PadField{ .pads = pads };
    const field = try buildPadField(alloc, pads);
    defer field.deinit(alloc);
    try std.testing.expect(field.nx > 1 and field.ny > 1);

    var probes: usize = 0;
    var blocked: usize = 0;
    for (boxes) |b| {
        for ([_]optimizer.Side{ .top, .bottom }) |side| {
            const want = padsBlock(flat, side, b);
            try std.testing.expectEqual(want, padsBlock(field, side, b));
            try std.testing.expectEqual(
                padsHitPoint(flat, side, .{ b.x0, b.y0 }),
                padsHitPoint(field, side, .{ b.x0, b.y0 }),
            );
            probes += 1;
            if (want) blocked += 1;
        }
    }
    // The sweep has to have seen both answers, or agreement is vacuous.
    try std.testing.expect(blocked > 0);
    try std.testing.expect(blocked < probes);
}
