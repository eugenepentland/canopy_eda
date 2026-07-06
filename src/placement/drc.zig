//! Post-route design-rule check. Given a placement and the router's output,
//! it flags every pair of copper features on *different* nets that sit closer
//! than the clearance rule — the common offender being a ground via dropped on
//! a pad whose copper then crowds a neighbouring pad of another net.
//!
//! Scope: via↔pad, via↔via, via↔track, track↔track, track↔pad, and pad↔pad
//! (across parts). Track↔track and track↔pad are checked geometrically
//! because not all copper comes from the maze grid — breakout/escape stubs,
//! hand-drawn tracks, and stamped module copper are all drawn at arbitrary
//! points, so the grid-pitch spacing guarantee doesn't cover them. Both are
//! layer-aware: an SMD pad only clashes with copper on its own side;
//! through-hole pads clash on every layer. Coordinates are millimetres; gaps
//! are edge-to-edge (0 ⇒ touching, negative ⇒ overlapping).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const pad_shape = @import("pad_shape.zig");
const export_kicad = @import("../export_kicad.zig");

const FlatNet = export_kicad.FlatNet;

/// What two features clash. Used for the marker label on the page.
/// `annular` = a via's copper ring around its drill is thinner than the
/// fab minimum; `board_edge` = routed copper closer to the board outline than
/// the copper-to-edge rule; `courtyard` = two placed parts' courtyards overlap
/// (on the same board side); `hole_hole` = two drilled holes' walls sit closer
/// than the hole-to-hole rule; `min_drill` = a drilled hole below the minimum
/// drill diameter.
pub const Kind = enum {
    via_pad,
    via_via,
    via_track,
    track_track,
    track_pad,
    pad_pad,
    annular,
    board_edge,
    courtyard,
    hole_hole,
    min_drill,
};

// The drill-station rule DEFAULTS (min-annular 0.1, min-drill 0.2,
// hole-to-hole 0.25 mm) live on `optimizer.DesignRules` — one source of truth
// resolved from the design's `(design-rules …)` form. This DRC reads them from
// `placement.rules.design`; an absent form leaves each at its default. The
// router's default via (0.4 ⌀ / 0.2 drill) sits exactly on the 0.1 mm annular
// floor, so default routing is legal by construction and only a deliberately
// thinner (net-class) via trips the annular check.

/// One clearance violation, located at the midpoint of the offending gap.
pub const Violation = struct {
    x: f64,
    y: f64,
    gap: f64, // actual edge-to-edge distance (mm); < clearance
    clearance: f64, // the rule that was broken (mm)
    kind: Kind,
};

/// A pad reduced to its world bounding box, its real copper outline (`poly`;
/// empty ⇒ the box is exact), the net it carries, its part index (so two
/// pads of the same part are never checked against each other), and the
/// signal layer its copper lives on (0 = top, 1 = bottom — the part's side;
/// `thru` pads exist on every layer). `drill`/`hx`,`hy` carry the pad's
/// drilled-hole diameter (0 ⇒ no hole) and world centre, for the drill-related
/// checks.
const PadBox = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64 = &.{},
    net: i32,
    part: usize,
    layer: u8 = 0,
    thru: bool = false,
    drill: f64 = 0,
    hx: f64 = 0,
    hy: f64 = 0,
};

/// One drilled hole reduced to its world centre + diameter — a pad hole or a
/// via, unified so the min-drill and hole-to-hole checks treat them alike.
const Hole = struct { x: f64, y: f64, drill: f64 };

const EPS: f64 = 1e-6;

/// Run the check. All output is allocated in `arena`. `clearance` is the
/// copper-to-copper rule (mm); two features of different nets must be at least
/// this far apart, edge to edge. The board-level `(design-rules …)` values
/// (min-annular, min-drill, hole-to-hole, copper-edge) are read from
/// `placement.rules.design`; an absent form leaves each at its built-in
/// default, so the output is unchanged for existing designs.
pub fn check(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    clearance: f64,
) std.mem.Allocator.Error![]Violation {
    var out: std.ArrayListUnmanaged(Violation) = .empty;
    const pads = try padBoxes(arena, placement);
    const vias = routed.vias;
    const tracks = routed.tracks;
    const rules = placement.rules.design;

    // via ↔ pad
    for (vias) |v| {
        const vr = v.dia / 2;
        for (pads) |p| {
            if (sameNet(v.net, p.net)) continue;
            const gap = pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, v.x, v.y, vr + clearance) - vr;
            if (gap < clearance - EPS) {
                try out.append(arena, .{ .x = v.x, .y = v.y, .gap = gap, .clearance = clearance, .kind = .via_pad });
            }
        }
    }
    // via ↔ via
    for (vias, 0..) |a, i| {
        for (vias[i + 1 ..]) |b| {
            if (sameNet(a.net, b.net)) continue;
            const gap = std.math.hypot(a.x - b.x, a.y - b.y) - a.dia / 2 - b.dia / 2;
            if (gap < clearance - EPS) {
                try out.append(arena, .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2, .gap = gap, .clearance = clearance, .kind = .via_via });
            }
        }
    }
    // via ↔ track
    for (vias) |v| {
        const vr = v.dia / 2;
        for (tracks) |t| {
            if (sameNet(v.net, t.net)) continue;
            const gap = segPointDist(t.x1, t.y1, t.x2, t.y2, v.x, v.y) - vr - t.width / 2;
            if (gap < clearance - EPS) {
                try out.append(arena, .{ .x = v.x, .y = v.y, .gap = gap, .clearance = clearance, .kind = .via_track });
            }
        }
    }
    // track ↔ track (same layer, different nets). Maze copper satisfies this
    // by grid construction (adjacent occupied lines are width + clearance
    // apart, and diagonal corner cells are reserved), so what this really
    // polices is copper drawn OFF the grid: escape/breakout stubs, hand-drawn
    // tracks, stamped module copper. A crossing shows up as gap = −(w_a+w_b)/2.
    for (tracks, 0..) |a, i| {
        for (tracks[i + 1 ..]) |b| {
            if (a.layer != b.layer or sameNet(a.net, b.net)) continue;
            const gap = segSegDist(a.x1, a.y1, a.x2, a.y2, b.x1, b.y1, b.x2, b.y2) - a.width / 2 - b.width / 2;
            if (gap < clearance - EPS) {
                const mx = (a.x1 + a.x2 + b.x1 + b.x2) / 4;
                const my = (a.y1 + a.y2 + b.y1 + b.y2) / 4;
                try out.append(arena, .{ .x = mx, .y = my, .gap = gap, .clearance = clearance, .kind = .track_track });
            }
        }
    }
    // track ↔ pad (layer-aware). The maze keeps every grid NODE `reach` from
    // foreign pads, but stubs, hand-drawn tracks, and stamped copper are
    // off-grid — this is what catches a breakout stub drawn across a QFN
    // neighbour pad. Sampled along the track against the pad's real outline.
    for (tracks) |t| {
        const need = t.width / 2 + clearance;
        for (pads) |p| {
            if (sameNet(t.net, p.net)) continue;
            if (!p.thru and p.layer != t.layer) continue;
            // Cheap reject: track bbox vs pad bbox inflated by the rule.
            if (@min(t.x1, t.x2) > p.x1 + need or @max(t.x1, t.x2) < p.x0 - need or
                @min(t.y1, t.y2) > p.y1 + need or @max(t.y1, t.y2) < p.y0 - need) continue;
            const gap = segShapeDist(t, p, need) - t.width / 2;
            if (gap < clearance - EPS) {
                const mx = std.math.clamp((p.x0 + p.x1) / 2, @min(t.x1, t.x2), @max(t.x1, t.x2));
                const my = std.math.clamp((p.y0 + p.y1) / 2, @min(t.y1, t.y2), @max(t.y1, t.y2));
                try out.append(arena, .{ .x = mx, .y = my, .gap = gap, .clearance = clearance, .kind = .track_pad });
            }
        }
    }
    // Drill-related checks (annular ring, min-drill, hole-to-hole) and the
    // copper-to-edge + courtyard-overlap checks live in helpers to keep `check`
    // legible — each reads the board-level `(design-rules …)` value.
    try checkDrillRules(arena, &out, pads, vias, rules);
    try checkBoardEdge(arena, &out, placement, tracks, vias, rules.edgeClearance());
    try checkCourtyards(arena, &out, placement);
    // pad ↔ pad (different parts)
    for (pads, 0..) |a, i| {
        for (pads[i + 1 ..]) |b| {
            if (a.part == b.part or sameNet(a.net, b.net)) continue;
            const gap = pad_shape.shapeGap(
                .{ .x0 = a.x0, .y0 = a.y0, .x1 = a.x1, .y1 = a.y1, .poly = a.poly },
                .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1, .poly = b.poly },
                clearance,
            );
            if (gap < clearance - EPS) {
                const mx = (std.math.clamp((a.x0 + a.x1) / 2, b.x0, b.x1) + std.math.clamp((b.x0 + b.x1) / 2, a.x0, a.x1)) / 2;
                const my = (std.math.clamp((a.y0 + a.y1) / 2, b.y0, b.y1) + std.math.clamp((b.y0 + b.y1) / 2, a.y0, a.y1)) / 2;
                try out.append(arena, .{ .x = mx, .y = my, .gap = gap, .clearance = clearance, .kind = .pad_pad });
            }
        }
    }
    return out.toOwnedSlice(arena);
}

const Viol = std.ArrayListUnmanaged(Violation);

/// The drill-station rules: via annular ring (`min_annular`), minimum drill
/// diameter (`min_drill`), and hole-to-hole wall clearance (`hole_to_hole`).
/// Every drilled feature (vias + drilled pads) is measured; drill=0 legacy /
/// synthetic features are skipped, so an all-SMD board flags nothing.
fn checkDrillRules(
    arena: std.mem.Allocator,
    out: *Viol,
    pads: []const PadBox,
    vias: []const router.Via,
    rules: optimizer.DesignRules,
) std.mem.Allocator.Error!void {
    // annular ring: copper ring around a via drill must meet the fab minimum.
    for (vias) |v| {
        if (v.drill <= 0) continue;
        const ring = (v.dia - v.drill) / 2;
        if (ring < rules.min_annular - EPS) {
            try out.append(arena, .{ .x = v.x, .y = v.y, .gap = ring, .clearance = rules.min_annular, .kind = .annular });
        }
    }
    // min drill: no drilled hole smaller than the minimum drill (vias + pads).
    for (vias) |v| {
        if (v.drill > 0 and v.drill < rules.min_drill - EPS) {
            try out.append(arena, .{ .x = v.x, .y = v.y, .gap = v.drill, .clearance = rules.min_drill, .kind = .min_drill });
        }
    }
    for (pads) |p| {
        if (p.drill > 0 and p.drill < rules.min_drill - EPS) {
            try out.append(arena, .{ .x = p.hx, .y = p.hy, .gap = p.drill, .clearance = rules.min_drill, .kind = .min_drill });
        }
    }
    // hole ↔ hole: two drilled holes whose walls sit closer than the rule risk
    // breakout / a merged slot. Wall-to-wall = centre distance − both radii.
    // Coincident holes (a via on a thru-hole barrel — the same physical hole)
    // are skipped rather than flagged against themselves.
    const holes = try allHoles(arena, pads, vias);
    for (holes, 0..) |a, i| {
        for (holes[i + 1 ..]) |b| {
            const dist = std.math.hypot(a.x - b.x, a.y - b.y);
            if (dist < EPS) continue;
            const gap = dist - a.drill / 2 - b.drill / 2;
            if (gap < rules.hole_to_hole - EPS) {
                try out.append(arena, .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2, .gap = gap, .clearance = rules.hole_to_hole, .kind = .hole_hole });
            }
        }
    }
}

/// copper ↔ board edge: when the design declares a `(board (size W H) …)`
/// outline, routed copper (vias + tracks) must keep the copper-to-edge rule
/// (`edge`) from it. Features clearly OUTSIDE the outline (the off-board
/// staging band) are skipped — a workflow state, not an edge-clearance defect.
fn checkBoardEdge(
    arena: std.mem.Allocator,
    out: *Viol,
    placement: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
    edge: f64,
) std.mem.Allocator.Error!void {
    const br = placement.board_rect orelse return;
    for (vias) |v| {
        const vr = v.dia / 2;
        const inset = edgeInset(br, v.x, v.y);
        if (inset < -vr) continue; // fully off-board (staged)
        const gap = inset - vr;
        if (gap < edge - EPS) {
            try out.append(arena, .{ .x = v.x, .y = v.y, .gap = gap, .clearance = edge, .kind = .board_edge });
        }
    }
    for (tracks) |t| {
        const hw = t.width / 2;
        // The inset function is concave over a segment, so its minimum is at an
        // endpoint — checking both ends covers the whole track.
        const ends = [_][2]f64{ .{ t.x1, t.y1 }, .{ t.x2, t.y2 } };
        var worst: f64 = std.math.inf(f64);
        var wx: f64 = t.x1;
        var wy: f64 = t.y1;
        for (ends) |e| {
            const inset = edgeInset(br, e[0], e[1]);
            if (inset < worst) {
                worst = inset;
                wx = e[0];
                wy = e[1];
            }
        }
        if (worst < -hw) continue; // fully off-board (staged)
        const gap = worst - hw;
        if (gap < edge - EPS) {
            try out.append(arena, .{ .x = wx, .y = wy, .gap = gap, .clearance = edge, .kind = .board_edge });
        }
    }
}

/// courtyard ↔ courtyard: two placed parts whose keep-out courtyards overlap
/// can't both be assembled. Parts on OPPOSITE board sides never clash (their
/// courtyards live on different faces). A strict interpenetration is the
/// violation (negative gap = penetration depth); touching exactly is legal.
fn checkCourtyards(
    arena: std.mem.Allocator,
    out: *Viol,
    placement: optimizer.Placement,
) std.mem.Allocator.Error!void {
    for (placement.parts, 0..) |a, i| {
        const ca = optimizer.worldCourtyard(a);
        if (ca.w <= 0 or ca.h <= 0) continue;
        for (placement.parts[i + 1 ..]) |b| {
            if (a.side != b.side) continue;
            const cb = optimizer.worldCourtyard(b);
            if (cb.w <= 0 or cb.h <= 0) continue;
            const ov = rectOverlap(ca, cb);
            if (ov.depth > EPS) {
                try out.append(arena, .{ .x = ov.x, .y = ov.y, .gap = -ov.depth, .clearance = 0, .kind = .courtyard });
            }
        }
    }
}

/// Two features may touch only if they share a (real) net. Net index -1 means
/// "no net" (not-connected); two such features still need clearance.
fn sameNet(a: i32, b: i32) bool {
    return a == b and a != -1;
}

/// Build the pad-rect list with net + part index, mirroring the world-rect
/// the router and renderer use (rotation-aware for the 0/90/180/270° poses).
fn padBoxes(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]PadBox {
    var pin_net = std.StringHashMap(i32).init(arena);
    for (placement.nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pin_net.put(key, @intCast(ni));
        }
    }
    var list: std.ArrayListUnmanaged(PadBox) = .empty;
    for (placement.parts, 0..) |part, pi| {
        const layer: u8 = if (part.side == .bottom) 1 else 0;
        for (part.pads) |pad| {
            const sh = try pad_shape.worldShape(arena, part, pad);
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ part.ref_des, pad.number });
            const net = pin_net.get(key) orelse -1;
            const c = optimizer.worldPadCenter(part, pad.x, pad.y);
            try list.append(arena, .{
                .x0 = sh.x0,
                .y0 = sh.y0,
                .x1 = sh.x1,
                .y1 = sh.y1,
                .poly = sh.poly,
                .net = net,
                .part = pi,
                .layer = layer,
                .thru = pad.thru,
                .drill = pad.drill,
                .hx = c[0],
                .hy = c[1],
            });
        }
    }
    return list.toOwnedSlice(arena);
}

/// Every drilled hole on the board unified into one list: each pad with
/// drill>0 (world centre + diameter) plus each via with drill>0. Arena-owned.
fn allHoles(arena: std.mem.Allocator, pads: []const PadBox, vias: []const router.Via) std.mem.Allocator.Error![]Hole {
    var list: std.ArrayListUnmanaged(Hole) = .empty;
    for (pads) |p| {
        if (p.drill <= 0) continue;
        try list.append(arena, .{ .x = p.hx, .y = p.hy, .drill = p.drill });
    }
    for (vias) |v| {
        if (v.drill <= 0) continue;
        try list.append(arena, .{ .x = v.x, .y = v.y, .drill = v.drill });
    }
    return list.toOwnedSlice(arena);
}

/// Overlap of two axis-aligned rects: penetration depth (min of the x/y
/// overlaps; ≤0 ⇒ disjoint or merely touching) and the centre of the shared
/// region (the marker location). Used by the courtyard check.
fn rectOverlap(a: optimizer.BoardRect, b: optimizer.BoardRect) struct { depth: f64, x: f64, y: f64 } {
    const ax1 = a.minx + a.w;
    const ay1 = a.miny + a.h;
    const bx1 = b.minx + b.w;
    const by1 = b.miny + b.h;
    const ox = @min(ax1, bx1) - @max(a.minx, b.minx);
    const oy = @min(ay1, by1) - @max(a.miny, b.miny);
    if (ox <= 0 or oy <= 0) return .{ .depth = 0, .x = 0, .y = 0 };
    const cx = (@max(a.minx, b.minx) + @min(ax1, bx1)) / 2;
    const cy = (@max(a.miny, b.miny) + @min(ay1, by1)) / 2;
    return .{ .depth = @min(ox, oy), .x = cx, .y = cy };
}

/// Signed distance from (x,y) to the nearest board-outline edge — positive
/// inside the rectangle, negative outside.
fn edgeInset(br: optimizer.BoardRect, x: f64, y: f64) f64 {
    const dl = x - br.minx;
    const dr = br.minx + br.w - x;
    const dt = y - br.miny;
    const db = br.miny + br.h - y;
    return @min(@min(dl, dr), @min(dt, db));
}

/// Shortest distance from point (px,py) to segment (ax,ay)-(bx,by).
fn segPointDist(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < EPS) return std.math.hypot(px - ax, py - ay);
    const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    return std.math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

/// Shortest distance from a track's centreline to a pad's copper (0 when the
/// centreline enters the pad), or +inf when the whole segment stays farther
/// than `win` from the pad's bbox (can't violate a `win` rule). The sampled
/// span is slab-clipped to the pad's `win`-inflated bbox first, so a long rail
/// passing one small pad samples only the short stretch beside it. 0.05 mm
/// steps against the pad's real outline via `pad_shape.pointDist` — exact
/// enough for a pass/fail against a 0.127 mm rule, and it handles polygon
/// (thermal/EP) pads the same way the router's stub checks do.
fn segShapeDist(t: router.Track, p: PadBox, win: f64) f64 {
    const dx = t.x2 - t.x1;
    const dy = t.y2 - t.y1;
    var f0: f64 = 0;
    var f1: f64 = 1;
    if (@abs(dx) > 1e-12) {
        const a = (p.x0 - win - t.x1) / dx;
        const b = (p.x1 + win - t.x1) / dx;
        f0 = @max(f0, @min(a, b));
        f1 = @min(f1, @max(a, b));
    } else if (t.x1 < p.x0 - win or t.x1 > p.x1 + win) return std.math.inf(f64);
    if (@abs(dy) > 1e-12) {
        const a = (p.y0 - win - t.y1) / dy;
        const b = (p.y1 + win - t.y1) / dy;
        f0 = @max(f0, @min(a, b));
        f1 = @min(f1, @max(a, b));
    } else if (t.y1 < p.y0 - win or t.y1 > p.y1 + win) return std.math.inf(f64);
    if (f0 > f1) return std.math.inf(f64);
    const len = std.math.hypot(dx, dy) * (f1 - f0);
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(len / 0.05))));
    var best = std.math.inf(f64);
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const f = f0 + (f1 - f0) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const d = pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, t.x1 + f * dx, t.y1 + f * dy, best);
        if (d < best) best = d;
    }
    return best;
}

/// Shortest distance between two segments (0 when they properly cross).
fn segSegDist(ax1: f64, ay1: f64, ax2: f64, ay2: f64, bx1: f64, by1: f64, bx2: f64, by2: f64) f64 {
    const d1x = ax2 - ax1;
    const d1y = ay2 - ay1;
    const d2x = bx2 - bx1;
    const d2y = by2 - by1;
    const den = d1x * d2y - d1y * d2x;
    if (@abs(den) > 1e-12) {
        const t = ((bx1 - ax1) * d2y - (by1 - ay1) * d2x) / den;
        const u = ((bx1 - ax1) * d1y - (by1 - ay1) * d1x) / den;
        if (t >= 0 and t <= 1 and u >= 0 and u <= 1) return 0;
    }
    var d = segPointDist(ax1, ay1, ax2, ay2, bx1, by1);
    d = @min(d, segPointDist(ax1, ay1, ax2, ay2, bx2, by2));
    d = @min(d, segPointDist(bx1, by1, bx2, by2, ax1, ay1));
    d = @min(d, segPointDist(bx1, by1, bx2, by2, ax2, ay2));
    return d;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/drc - flags a via that crowds a foreign pad's clearance
test "check flags a via overlapping a foreign pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // One part with a single pad on net SIG at the origin; a via on net GND
    // sits 0.3 mm away — via edge (dia 0.6 ⇒ r 0.3) lands right on the pad edge,
    // far inside a 0.127 mm clearance.
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    const vias = [_]router.Via{.{ .x = 0.5, .y = 0, .dia = 0.6, .net = 99 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };

    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), v.len);
    try testing.expectEqual(Kind.via_pad, v[0].kind);
    try testing.expect(v[0].gap < 0.127);
}

// spec: placement/drc - passes a via that shares the pad's net
test "check ignores a via on the same net as the pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    // net index 0 == the SIG pad's net ⇒ same net, allowed to sit on the pad.
    const vias = [_]router.Via{.{ .x = 0.2, .y = 0, .dia = 0.6, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };

    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 0), v.len);
}

// spec: placement/drc - flags a via whose annular ring is under the fab minimum
test "check flags a thin annular ring" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    // dia 0.4 / drill 0.3 ⇒ 0.05 mm ring, far under the 0.13 mm floor; the
    // second via has a healthy ring and a legacy via records no drill at all.
    const vias = [_]router.Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .drill = 0.3, .net = 0 },
        .{ .x = 5, .y = 0, .dia = 0.6, .drill = 0.3, .net = 0 },
        .{ .x = 9, .y = 0, .dia = 0.4, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), v.len);
    try testing.expectEqual(Kind.annular, v[0].kind);
}

// spec: placement/drc - flags copper crowding the board outline and skips the off-board staging band
test "check flags copper at the board edge, not staged copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = optimizer.Placement{
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
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    // Track ends 0.05 mm from the left edge (violation); a via sits 20 mm
    // outside the outline — the staging band — and must be skipped.
    const tracks = [_]router.Track{
        .{ .x1 = 0.05, .y1 = 5, .x2 = 3, .y2 = 5, .layer = 0, .width = 0.127, .net = 0 },
    };
    const vias = [_]router.Via{.{ .x = -20, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 };
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), v.len);
    try testing.expectEqual(Kind.board_edge, v[0].kind);
}

// spec: placement/drc - a routed module with a crowded ground pad has no clearance violations
test "route then check is clean when a ground pad abuts a foreign pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // A hub whose small GND pad (1) sits at 0.4 mm pitch hard against a foreign
    // VCC pad (2): a via dropped at the GND pad centre (0.4 mm ⌀ ⇒ 0.2 mm
    // radius) would crowd the VCC pad. The router must fan the via clear so the
    // fully routed module passes its own clearance DRC.
    const u_pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "2", .x = 0.4, .y = 0, .w = 0.3, .h = 0.3 },
    };
    const c_pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "2", .x = 0.4, .y = 0, .w = 0.3, .h = 0.3 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.6, .hh = 0.6, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.6, .hh = 0.6, .pads = &c_pads, .fallback = false, .x = 4, .y = 0 },
    };
    const gnd = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "2" } };
    const vcc = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "GND", .pins = &gnd }, .{ .name = "VCC", .pins = &vcc } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = true,
    };

    const routed = try router.route(arena, placement, .{});
    // Both GND pads are still served by a via (connectivity preserved)…
    try testing.expect(routed.vias.len >= 2);
    // …and the routed module has zero clearance violations.
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 0), v.len);
}

// spec: placement/drc - flags same-layer track crossings and sub-clearance pairs between nets
test "check flags track-to-track crossings but not exact-pitch neighbours" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{};
    const placement = optimizer.Placement{
        .parts = &parts,
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
        .generated = true,
    };
    const w = 0.127;
    const clearance = 0.127;

    // An X crossing between two nets on the top layer — the escape-stub short
    // this check exists to expose. Gap comes out negative (overlap).
    const crossing = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 2, .layer = 0, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = 2, .x2 = 2, .y2 = 0, .layer = 0, .width = w, .net = 1 },
    };
    const crossed = router.RouteResult{ .tracks = &crossing, .vias = &.{}, .routed = 2, .total = 2 };
    const v1 = try check(arena, placement, crossed, clearance);
    try testing.expectEqual(@as(usize, 1), v1.len);
    try testing.expectEqual(Kind.track_track, v1[0].kind);
    try testing.expect(v1[0].gap < 0);

    // The same two tracks on DIFFERENT layers never interact.
    const stacked = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 2, .layer = 0, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = 2, .x2 = 2, .y2 = 0, .layer = 1, .width = w, .net = 1 },
    };
    const layered = router.RouteResult{ .tracks = &stacked, .vias = &.{}, .routed = 2, .total = 2 };
    try testing.expectEqual(@as(usize, 0), (try check(arena, placement, layered, clearance)).len);

    // Two parallel tracks at exactly grid pitch (width + clearance centre to
    // centre) are the router's legal adjacency — must NOT flag.
    const pitch = w + clearance;
    const parallel = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = pitch, .x2 = 5, .y2 = pitch, .layer = 0, .width = w, .net = 1 },
    };
    const legal = router.RouteResult{ .tracks = &parallel, .vias = &.{}, .routed = 2, .total = 2 };
    try testing.expectEqual(@as(usize, 0), (try check(arena, placement, legal, clearance)).len);

    // Nudge one inside the clearance rule → sub-clearance pair flags.
    const close = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = pitch * 0.7, .x2 = 5, .y2 = pitch * 0.7, .layer = 0, .width = w, .net = 1 },
    };
    const tight = router.RouteResult{ .tracks = &close, .vias = &.{}, .routed = 2, .total = 2 };
    const v2 = try check(arena, placement, tight, clearance);
    try testing.expectEqual(@as(usize, 1), v2.len);
    try testing.expectEqual(Kind.track_track, v2[0].kind);
}

// spec: placement/drc - flags a track crossing a foreign pad on its layer; other-layer SMD pads don't clash
test "check flags track-to-pad clashes layer-aware" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // One top-side part with an SMD pad on net PAD (index 0) at the origin,
    // plus a through-hole pad on the same part further out.
    const pads = [_]@import("geometry.zig").Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 3, .y = 0, .w = 0.6, .h = 0.6, .thru = true },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const p1 = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const p2 = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "2" }};
    const nets = [_]FlatNet{ .{ .name = "PAD", .pins = &p1 }, .{ .name = "SIG", .pins = &.{} }, .{ .name = "THRU", .pins = &p2 } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -5,
        .maxx = 5,
        .maxy = 5,
        .generated = true,
    };

    // A SIG track slicing across the SMD pad on the pad's own layer → flagged.
    const across = [_]router.Track{.{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.127, .net = 1 }};
    const top = router.RouteResult{ .tracks = &across, .vias = &.{}, .routed = 1, .total = 1 };
    const v1 = try check(arena, placement, top, 0.127);
    try testing.expectEqual(@as(usize, 1), v1.len);
    try testing.expectEqual(Kind.track_pad, v1[0].kind);
    try testing.expect(v1[0].gap < 0);

    // The same track on the BOTTOM layer passes under the top SMD pad — legal.
    const under = [_]router.Track{.{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 1, .width = 0.127, .net = 1 }};
    const bot = router.RouteResult{ .tracks = &under, .vias = &.{}, .routed = 1, .total = 1 };
    try testing.expectEqual(@as(usize, 0), (try check(arena, placement, bot, 0.127)).len);

    // A through-hole pad clashes on EVERY layer — the bottom track under it flags.
    const under_thru = [_]router.Track{.{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 1, .width = 0.127, .net = 1 }};
    const bt = router.RouteResult{ .tracks = &under_thru, .vias = &.{}, .routed = 1, .total = 1 };
    const v2 = try check(arena, placement, bt, 0.127);
    try testing.expectEqual(@as(usize, 1), v2.len);
    try testing.expectEqual(Kind.track_pad, v2[0].kind);

    // A track on the pad's OWN net may touch it — never flagged.
    const own = [_]router.Track{.{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 }};
    const ok = router.RouteResult{ .tracks = &own, .vias = &.{}, .routed = 1, .total = 1 };
    try testing.expectEqual(@as(usize, 0), (try check(arena, placement, ok, 0.127)).len);
}

/// A bare `Placement` around `parts` with default rules — the common shell for
/// the courtyard/drill tests, which need no nets or routed copper.
fn partsOnly(parts: []optimizer.Part) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -10,
        .miny = -10,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
}

/// Count the violations of one kind — the drill/courtyard tests share layouts
/// that could in principle trip more than the check under test. Public so
/// other modules' tests (e.g. the router's escape-stub test) can isolate the
/// copper-clearance kinds from an unrelated courtyard finding.
pub fn countKind(v: []const Violation, k: Kind) usize {
    var n: usize = 0;
    for (v) |x| {
        if (x.kind == k) n += 1;
    }
    return n;
}

/// The first violation of kind `k`, or null — lets a test assert a field on a
/// specific finding without an `if` in the test body.
fn firstOfKind(v: []const Violation, k: Kind) ?Violation {
    for (v) |x| {
        if (x.kind == k) return x;
    }
    return null;
}

// spec: placement/drc - flags two placed parts whose courtyards overlap, but not disjoint or opposite-side ones
test "check flags overlapping courtyards only on the same side" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    // Two 2×2 mm courtyards centred 1 mm apart interpenetrate by 1 mm.
    var overlap = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 1, .y = 0 },
    };
    const v1 = try check(arena, partsOnly(&overlap), routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v1, .courtyard));
    // The one courtyard violation records the interpenetration as a negative
    // gap (the check only appends when depth > 0, so gap < 0 by construction).
    try testing.expect(firstOfKind(v1, .courtyard).?.gap < 0);

    // Slide U2 to 2.5 mm — the 2×2 boxes now sit 0.5 mm apart (edge-to-edge),
    // so they don't overlap and nothing flags.
    var apart = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 2.5, .y = 0 },
    };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&apart), routed, 0.127), .courtyard));

    // Same interpenetrating pair but on OPPOSITE board sides never clashes —
    // their courtyards live on different faces.
    var two_sided = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0, .side = .top },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 1, .y = 0, .side = .bottom },
    };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&two_sided), routed, 0.127), .courtyard));
}

// spec: placement/drc - flags two drilled holes whose walls sit closer than the hole-to-hole rule
test "check flags hole-to-hole clearance and passes well-spaced holes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // Two through-hole pads (0.4 mm drill ⇒ 0.2 mm radius each) whose centres
    // are 0.5 mm apart ⇒ 0.1 mm wall-to-wall, under the 0.25 mm default rule.
    const pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const v = try check(arena, partsOnly(&parts), routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .hole_hole));

    // Space them 1 mm apart ⇒ 0.6 mm wall-to-wall, clear of the rule.
    const far = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
        .{ .number = "2", .x = 1.0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
    };
    var far_parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1.5, .hh = 1, .pads = &far, .fallback = false, .x = 0, .y = 0 },
    };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&far_parts), routed, 0.127), .hole_hole));
}

// spec: placement/drc - flags a drilled hole below the minimum drill diameter (pads and vias); SMD pads exempt
test "check flags sub-minimum drills" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // One SMD pad (no drill — exempt), one drilled pad at 0.15 mm (under the
    // 0.2 mm default), well away from each other so hole-to-hole stays clean.
    const pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "2", .x = 5, .y = 0, .w = 0.5, .h = 0.5, .thru = true, .drill = 0.15 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 3, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    // A via drilled at 0.1 mm (under) and one at 0.3 mm (over); legacy via has
    // no drill and is exempt.
    const vias = [_]router.Via{
        .{ .x = 0, .y = 5, .dia = 0.4, .drill = 0.1, .net = 0 },
        .{ .x = 5, .y = 5, .dia = 0.6, .drill = 0.3, .net = 0 },
        .{ .x = 9, .y = 5, .dia = 0.4, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };
    const v = try check(arena, partsOnly(&parts), routed, 0.127);
    // The 0.15 mm pad + the 0.1 mm via = 2 min-drill violations; the SMD pad,
    // the 0.3 mm via, and the drill-less via are all exempt.
    try testing.expectEqual(@as(usize, 2), countKind(v, .min_drill));
}

// spec: placement/drc - board-level design rules default to the toolchain's legacy constants when no form is authored
test "check default rules equal the legacy constants" {
    // The no-form `DesignRules{}` must reproduce every old constant so existing
    // designs are unchanged: annular 0.1, min-drill 0.2, hole-to-hole 0.25.
    const d = optimizer.DesignRules{};
    try testing.expectEqual(@as(f64, 0.1), d.min_annular);
    try testing.expectEqual(@as(f64, 0.2), d.min_drill);
    try testing.expectEqual(@as(f64, 0.25), d.hole_to_hole);
    try testing.expectEqual(@as(f64, 0.05), d.mask_margin);
    try testing.expectEqual(@as(f64, 0.3), d.pour_clearance);
    // copper_edge unset ⇒ the DRC edge clearance falls back to the plain
    // copper clearance (the old board_edge behaviour) and the Gerber pour
    // pullback falls back to the fab-safe 0.3 mm.
    try testing.expectEqual(@as(f64, 0.127), d.edgeClearance());
    try testing.expectEqual(@as(f64, 0.3), d.pourEdge());
}

// spec: placement/drc - a (design-rules …) value overrides the matching default in the DRC
test "check honours a design-rules override" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // Two drilled pads 0.5 mm apart ⇒ 0.1 mm wall-to-wall. At the 0.25 mm
    // default this flags; loosening the design's hole-to-hole rule to 0.05 mm
    // makes the same layout legal.
    const pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    var loose = partsOnly(&parts);
    loose.rules = .{ .design = .{ .hole_to_hole = 0.05 } };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, loose, routed, 0.127), .hole_hole));

    // The default (no override) still flags it.
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, partsOnly(&parts), routed, 0.127), .hole_hole));
}
