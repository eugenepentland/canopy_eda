//! Board-outline via fencing derived from `(board … (perimeter-fence …))`.
//!
//! The declaration is authoritative: callers regenerate these vias from the
//! exact current outline instead of treating them as hand-routed copper. Sites
//! lie on a polygon offset inward by the authored centre-to-edge distance and
//! are divided evenly around that closed path, so there is no oversized seam
//! gap. The declared spacing is a maximum; the final pitch is `perimeter/N`.

const std = @import("std");
const drc = @import("drc.zig");
const geometry = @import("geometry.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const outline = @import("outline.zig");
const pad_shape = @import("pad_shape.zig");
const numeric = @import("../numeric.zig");

/// Saved-route provenance reserved for board-derived perimeter sites.
pub const provenance = "@perimeter";

/// One exposed solder-mask stroke along the finished board outline. The
/// Gerber and KiCad writers consume these fragments instead of independently
/// guessing where an edge-mounted footprint interrupts the perimeter band.
pub const MaskSegment = struct {
    a: [2]f64,
    b: [2]f64,
};

/// Edge-to-edge separation between perimeter hardware and a component pad.
/// The same floor governs the via annulus and the solder-mask opening, so the
/// two derived features leave one predictable pad-shaped gap.
const pad_clearance_mm: f64 = 0.2;

/// Whether a placement carries an effective perimeter-fence declaration.
fn declared(p: optimizer.Placement) bool {
    const f = p.rules.perimeter_fence;
    return f.via_dia > 0 and f.via_drill > 0 and
        f.via_drill <= f.via_dia and f.spacing > 0 and f.edge_offset > 0 and
        p.board_rect != null;
}

fn shortName(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[slash + 1 ..];
}

/// Resolve the authored stitch-net name against flattened nets, accepting the
/// same case-insensitive full-name or leaf-name spelling as other board rules.
fn netIndex(p: optimizer.Placement) ?i32 {
    const wanted = p.rules.perimeter_fence.net;
    for (p.nets, 0..) |net, i| {
        if (std.ascii.eqlIgnoreCase(net.name, wanted) or
            std.ascii.eqlIgnoreCase(shortName(net.name), wanted))
            return @intCast(i);
    }
    return null;
}

fn sameNetName(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b) or
        std.ascii.eqlIgnoreCase(shortName(a), b) or
        std.ascii.eqlIgnoreCase(a, shortName(b)) or
        std.ascii.eqlIgnoreCase(shortName(a), shortName(b));
}

/// Whether a routed-copper net index names the requested flattened or leaf net.
pub fn routedNetMatches(p: optimizer.Placement, net: i32, name: []const u8) bool {
    if (net < 0) return false;
    const i: usize = @intCast(net);
    return i < p.nets.len and sameNetName(p.nets[i].name, name);
}

/// The matching ground pour on this outer face. A perimeter mask declaration
/// is not permission to uncover arbitrary copper or bare laminate: its opening
/// exists only where the fence net is the face's declared ground pour.
/// Return the matching ground-pour net that permits a perimeter opening.
pub fn maskPourNetForFace(p: optimizer.Placement, side: optimizer.Side) ?[]const u8 {
    const pour_net = p.rules.pourNetOnSide(side) orelse return null;
    if (!optimizer.isGroundName(shortName(pour_net))) return null;
    if (!sameNetName(pour_net, p.rules.perimeter_fence.net)) return null;
    return pour_net;
}

/// Exact finished-edge polygon. A plain board rectangle is materialized into
/// four vertices; authored and viewer-drawn polygons are returned unchanged.
pub fn outlinePoints(alloc: std.mem.Allocator, p: optimizer.Placement) std.mem.Allocator.Error![]const [2]f64 {
    if (p.board_poly) |poly| return poly;
    const r = p.board_rect orelse return &.{};
    const poly = try alloc.alloc([2]f64, 4);
    poly[0] = .{ r.minx, r.miny };
    poly[1] = .{ r.minx + r.w, r.miny };
    poly[2] = .{ r.minx + r.w, r.miny + r.h };
    poly[3] = .{ r.minx, r.miny + r.h };
    return poly;
}

fn cross(a: [2]f64, b: [2]f64) f64 {
    return a[0] * b[1] - a[1] * b[0];
}

fn add(a: [2]f64, b: [2]f64) [2]f64 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

fn scale(a: [2]f64, s: f64) [2]f64 {
    return .{ a[0] * s, a[1] * s };
}

fn sub(a: [2]f64, b: [2]f64) [2]f64 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

const ShiftedEdge = struct { p: [2]f64, d: [2]f64, n: [2]f64 };

fn shiftedEdge(poly: []const [2]f64, i: usize, offset: f64, winding: f64) ShiftedEdge {
    const a = poly[i];
    const b = poly[(i + 1) % poly.len];
    const d = sub(b, a);
    const len = std.math.hypot(d[0], d[1]);
    const n = if (len > 1e-12)
        [2]f64{ winding * -d[1] / len, winding * d[0] / len }
    else
        [2]f64{ 0, 0 };
    return .{ .p = add(a, scale(n, offset)), .d = d, .n = n };
}

/// Intersect adjacent inward-shifted edge lines to form the centre path.
fn insetPolygon(alloc: std.mem.Allocator, poly: []const [2]f64, distance: f64) std.mem.Allocator.Error![]const [2]f64 {
    if (!outline.valid(poly) or !(distance > 0)) return &.{};
    const winding: f64 = if (outline.signedArea2(poly) > 0) 1 else -1;
    const out = try alloc.alloc([2]f64, poly.len);
    for (poly, 0..) |vertex, i| {
        const prev = shiftedEdge(poly, (i + poly.len - 1) % poly.len, distance, winding);
        const next = shiftedEdge(poly, i, distance, winding);
        const denom = cross(prev.d, next.d);
        if (@abs(denom) > 1e-10) {
            const t = cross(sub(next.p, prev.p), next.d) / denom;
            out[i] = add(prev.p, scale(prev.d, t));
        } else {
            // Collinear outline subdivisions (common in imported rounded
            // rectangles) share the same shifted line; either normal gives
            // the same point without an unstable far-away intersection.
            const nsum = add(prev.n, next.n);
            const nlen = std.math.hypot(nsum[0], nsum[1]);
            const n = if (nlen > 1e-12) scale(nsum, 1 / nlen) else next.n;
            out[i] = add(vertex, scale(n, distance));
        }
    }
    if (!outline.valid(out)) {
        alloc.free(out);
        return &.{};
    }
    return out;
}

/// Exact outline inset used as the inner edge of a perimeter keepout band.
/// The returned slice is allocator-owned; an invalid/missing outline yields an
/// empty slice.
pub fn insetOutline(alloc: std.mem.Allocator, p: optimizer.Placement, distance: f64) std.mem.Allocator.Error![]const [2]f64 {
    const edge = try outlinePoints(alloc, p);
    defer if (p.board_poly == null and edge.len > 0) alloc.free(edge);
    return insetPolygon(alloc, edge, distance);
}

/// Inset from the finished board edge to the keepout band's inner boundary.
/// The authored clearance is measured beyond the fence via's inward copper
/// edge, making the visual/rule independent of drill diameter.
pub fn keepoutLimit(p: optimizer.Placement) f64 {
    const f = p.rules.perimeter_fence;
    if (!declared(p)) return 0;
    if (!(f.keepout.clearance > 0)) return 0;
    const b = f.keepout.blocks;
    const blocks_anything = b.components or b.tracks or b.vias;
    if (!blocks_anything) return 0;
    return f.edge_offset + f.via_dia / 2 + f.keepout.clearance;
}

/// Whether authored keepout policy admits copper on flattened net `net`.
pub fn keepoutAllowsNet(p: optimizer.Placement, net: i32) bool {
    if (net < 0 or @as(usize, @intCast(net)) >= p.nets.len) return false;
    const name = p.nets[@intCast(net)].name;
    for (p.rules.perimeter_fence.keepout.allow_nets) |allowed| {
        if (std.ascii.eqlIgnoreCase(name, allowed) or
            std.ascii.eqlIgnoreCase(shortName(name), allowed)) return true;
    }
    return false;
}

fn perimeter(poly: []const [2]f64) f64 {
    var total: f64 = 0;
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        total += std.math.hypot(b[0] - a[0], b[1] - a[1]);
    }
    return total;
}

fn pointAt(poly: []const [2]f64, distance: f64) [2]f64 {
    var left = distance;
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
        if (left <= len or i + 1 == poly.len) {
            const t = if (len > 1e-12) @min(left / len, 1) else 0;
            return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
        }
        left -= len;
    }
    return poly[0];
}

const Interval = struct { lo: f64, hi: f64 };
const Box = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

fn intervalLessThan(_: void, a: Interval, b: Interval) bool {
    return a.lo < b.lo;
}

fn clipAxis(origin: f64, delta: f64, min: f64, max: f64, lo: *f64, hi: *f64) bool {
    if (@abs(delta) <= 1e-12) return origin >= min and origin <= max;
    const ta = (min - origin) / delta;
    const tb = (max - origin) / delta;
    lo.* = @max(lo.*, @min(ta, tb));
    hi.* = @min(hi.*, @max(ta, tb));
    return lo.* <= hi.*;
}

/// Parameter interval where segment `a`→`b` crosses an axis-aligned box.
fn boxInterval(a: [2]f64, b: [2]f64, minx: f64, miny: f64, maxx: f64, maxy: f64) ?Interval {
    var lo: f64 = 0;
    var hi: f64 = 1;
    if (!clipAxis(a[0], b[0] - a[0], minx, maxx, &lo, &hi)) return null;
    if (!clipAxis(a[1], b[1] - a[1], miny, maxy, &lo, &hi)) return null;
    return .{ .lo = lo, .hi = hi };
}

fn lerp(a: [2]f64, b: [2]f64, t: f64) [2]f64 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
}

fn appendBoxInterval(
    blocked: *std.ArrayList(Interval),
    alloc: std.mem.Allocator,
    a: [2]f64,
    b: [2]f64,
    box: Box,
    grow: f64,
) std.mem.Allocator.Error!void {
    if (boxInterval(a, b, box.x0 - grow, box.y0 - grow, box.x1 + grow, box.y1 + grow)) |interval|
        try blocked.append(alloc, interval);
}

/// Finished mask dam retained around copper inside the perimeter opening.
pub fn retainedWeb(p: optimizer.Placement) f64 {
    return @max(pad_clearance_mm, p.rules.design.mask.web);
}

/// Perimeter mask strokes with pad-only gaps on both faces. This side-agnostic
/// compatibility form does not know which face pour will receive the opening.
pub fn maskSegments(alloc: std.mem.Allocator, p: optimizer.Placement) std.mem.Allocator.Error![]const MaskSegment {
    return maskSegmentsForFace(alloc, p, &.{}, null);
}

/// Face-aware perimeter mask artwork. The opening stops before every pad
/// aperture and every foreign track on this outer face. The central stroke
/// is clipped by its radius plus the requested web or pour clearance, so its
/// round caps cannot uncover non-ground copper or the GND antipad around it.
/// Pad growth includes the normal aperture margin because the useful dam lies
/// BETWEEN the pad opening and perimeter opening, not merely between copper
/// shapes. A concrete face emits no perimeter opening unless that face has a
/// declared ground pour matching the fence net. Passing `null` includes pads
/// from both faces and retains the compatibility behavior used by geometry-only
/// callers.
pub fn maskSegmentsForFace(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    tracks: []const router.Track,
    side: ?optimizer.Side,
) std.mem.Allocator.Error![]const MaskSegment {
    return maskSegmentsForFaceWithVias(alloc, p, tracks, &.{}, side);
}

/// Full routed-copper form used by fabrication, KiCad sync, and the physical
/// renderers. Kept separate so the existing track-only public call remains
/// source-compatible for downstream geometry consumers.
pub fn maskSegmentsForFaceWithVias(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
    side: ?optimizer.Side,
) std.mem.Allocator.Error![]const MaskSegment {
    const width = p.rules.perimeter_fence.mask_width;
    if (!(width > 0) or p.board_rect == null) return &.{};
    const ground_net = if (side) |face| maskPourNetForFace(p, face) orelse return &.{} else null;
    const poly = try outlinePoints(alloc, p);
    defer if (p.board_poly == null and poly.len > 0) alloc.free(poly);
    if (poly.len < 3) return &.{};

    var out: std.ArrayList(MaskSegment) = .empty;
    var blocked: std.ArrayList(Interval) = .empty;
    defer blocked.deinit(alloc);
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        blocked.clearRetainingCapacity();
        for (p.parts) |part| {
            for (part.pads) |pad| {
                const face_only = !pad.thru and !pad.npth;
                if (side) |face| if (face_only and part.side != face) continue;
                const shape = try pad_shape.worldShape(alloc, part, pad);
                const aperture_margin = @max(@as(f64, 0), pad.maskMargin(p.rules.design.mask.margin));
                try appendBoxInterval(
                    &blocked,
                    alloc,
                    a,
                    b,
                    .{ .x0 = shape.x0, .y0 = shape.y0, .x1 = shape.x1, .y1 = shape.y1 },
                    width + aperture_margin + retainedWeb(p),
                );
            }
        }
        if (side) |face| {
            const layer: u8 = if (face == .bottom) 1 else 0;
            for (tracks) |track| {
                if (track.layer != layer or !(track.width > 0)) continue;
                if (ground_net) |name| if (routedNetMatches(p, track.net, name)) continue;
                const clearance = @max(retainedWeb(p), p.rules.clearanceForNet(track.net, p.rules.design.pour.clearance_outer));
                try appendBoxInterval(
                    &blocked,
                    alloc,
                    a,
                    b,
                    .{
                        .x0 = @min(track.x1, track.x2),
                        .y0 = @min(track.y1, track.y2),
                        .x1 = @max(track.x1, track.x2),
                        .y1 = @max(track.y1, track.y2),
                    },
                    width + track.width / 2 + clearance,
                );
            }
            for (vias) |via| {
                if (!(via.dia > 0)) continue;
                if (ground_net) |name| if (routedNetMatches(p, via.net, name)) continue;
                const clearance = @max(retainedWeb(p), p.rules.clearanceForNet(via.net, p.rules.design.pour.clearance_outer));
                try appendBoxInterval(
                    &blocked,
                    alloc,
                    a,
                    b,
                    .{ .x0 = via.x, .y0 = via.y, .x1 = via.x, .y1 = via.y },
                    width + via.dia / 2 + clearance,
                );
            }
        }
        std.mem.sort(Interval, blocked.items, {}, intervalLessThan);
        var cursor: f64 = 0;
        for (blocked.items) |interval| {
            const lo = std.math.clamp(interval.lo, 0, 1);
            const hi = std.math.clamp(interval.hi, 0, 1);
            if (lo > cursor + 1e-9) try out.append(alloc, .{ .a = lerp(a, b, cursor), .b = lerp(a, b, lo) });
            cursor = @max(cursor, hi);
            if (cursor >= 1 - 1e-9) break;
        }
        if (cursor < 1 - 1e-9) try out.append(alloc, .{ .a = lerp(a, b, cursor), .b = b });
    }
    return out.toOwnedSlice(alloc);
}

fn collectPadShapes(alloc: std.mem.Allocator, p: optimizer.Placement) std.mem.Allocator.Error![]const pad_shape.Shape {
    var shapes: std.ArrayList(pad_shape.Shape) = .empty;
    for (p.parts) |part| {
        for (part.pads) |pad| try shapes.append(alloc, try pad_shape.worldShape(alloc, part, pad));
    }
    return shapes.toOwnedSlice(alloc);
}

/// Whether the via annulus comes within the fixed perimeter-hardware clearance
/// of any pad. This is deliberately net-blind: perimeter stitching beside a
/// GND land still retains the same 0.2 mm physical gap as every other land.
fn crowdsPad(shapes: []const pad_shape.Shape, site: router.Via) bool {
    const reach = site.dia / 2 + pad_clearance_mm;
    for (shapes) |shape| {
        if (pad_shape.pointDist(shape.x0, shape.y0, shape.x1, shape.y1, shape.poly, site.x, site.y, reach) < reach - 1e-9) return true;
    }
    return false;
}

/// Generate the perimeter sites for the current exact outline. An incomplete
/// declaration or unresolved stitch net produces no copper.
pub fn generate(alloc: std.mem.Allocator, p: optimizer.Placement) std.mem.Allocator.Error![]const router.Via {
    if (!declared(p)) return &.{};
    const net = netIndex(p) orelse return &.{};
    const edge = try outlinePoints(alloc, p);
    defer if (p.board_poly == null and edge.len > 0) alloc.free(edge);
    const path = try insetPolygon(alloc, edge, p.rules.perimeter_fence.edge_offset);
    defer if (path.len > 0) alloc.free(path);
    if (path.len < 3) return &.{};
    const length = perimeter(path);
    if (!std.math.isFinite(length) or !(length > 0)) return &.{};
    const needed = @ceil(length / p.rules.perimeter_fence.spacing);
    const count: usize = @max(3, numeric.checkedInt(usize, needed) orelse return &.{});
    const pitch = length / @as(f64, @floatFromInt(count));
    var scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer scratch_state.deinit();
    const pad_shapes = try collectPadShapes(scratch_state.allocator(), p);
    var vias: std.ArrayList(router.Via) = .empty;
    for (0..count) |i| {
        // Half-pitch phase avoids pinning a site to the polygon's arbitrary
        // seam while preserving a uniform closed-loop pitch.
        const pt = pointAt(path, (@as(f64, @floatFromInt(i)) + 0.5) * pitch);
        const site: router.Via = .{
            .x = pt[0],
            .y = pt[1],
            .dia = p.rules.perimeter_fence.via_dia,
            .drill = p.rules.perimeter_fence.via_drill,
            .net = net,
        };
        if (!crowdsPad(pad_shapes, site)) try vias.append(alloc, site);
    }
    return vias.toOwnedSlice(alloc);
}

fn sameVia(a: router.Via, b: router.Via) bool {
    return a.net == b.net and std.math.hypot(a.x - b.x, a.y - b.y) < 1e-6;
}

/// Whether a via barrel overlaps the exact authored copper of a same-net pad.
/// Used when an old generated fence tag is reinterpreted after an outline move:
/// a barrel that now serves a land has functional electrical meaning and must
/// not disappear with the rest of the stale ring. The exact outline matters
/// for concave custom pads whose bounding-box notch contains no copper.
pub fn viaServesPad(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    net_name: []const u8,
    x: f64,
    y: f64,
    dia: f64,
) std.mem.Allocator.Error!bool {
    const reach = dia / 2 + 1e-9;
    for (p.nets) |net| {
        if (!std.mem.eql(u8, net.name, net_name)) continue;
        for (net.pins) |pin| {
            const part = for (p.parts) |part| {
                if (std.mem.eql(u8, part.ref_des, pin.ref_des)) break part;
            } else continue;
            const pad = for (part.pads) |pad| {
                if (std.mem.eql(u8, pad.number, pin.pin)) break pad;
            } else continue;
            const shape = try pad_shape.worldShape(alloc, part, pad);
            if (pad_shape.pointDist(shape.x0, shape.y0, shape.x1, shape.y1, shape.poly, x, y, reach) <= reach) return true;
        }
        return false;
    }
    return false;
}

/// Append current board-derived sites to routed copper, deduplicating a hand
/// via at the same net and coordinates, and rejecting any site that would add
/// a DRC error. Creates a via-only result when no route exists. The verdict
/// comes from `drc.ViaAdditionGate` — the world is built once and each site
/// pays only its own via-scoped checks, where re-running the full board check
/// per site made every large routed board's page load quadratic.
pub fn append(alloc: std.mem.Allocator, p: optimizer.Placement, routed: ?router.RouteResult) std.mem.Allocator.Error!?router.RouteResult {
    const sites = try generate(alloc, p);
    if (sites.len == 0) return routed;
    const old = if (routed) |r| r.vias else &.{};
    const tracks = if (routed) |r| r.tracks else &.{};
    var gate = try drc.ViaAdditionGate.build(alloc, p, .{ .tracks = tracks, .vias = old, .routed = 0, .total = 0 }, p.rules.design.clearance, sites[0]);
    var vias: std.ArrayList(router.Via) = .empty;
    try vias.appendSlice(alloc, old);
    site_loop: for (sites) |site| {
        for (vias.items) |via| if (sameVia(site, via)) continue :site_loop;
        if (try gate.addsError(alloc, site)) continue;
        try vias.append(alloc, site);
        try gate.accept(alloc, site);
    }
    var result = routed orelse router.RouteResult{
        .tracks = &.{},
        .vias = &.{},
        .routed = 0,
        .total = 0,
    };
    result.vias = try vias.toOwnedSlice(alloc);
    return result;
}

fn signedInsetOf(p: optimizer.Placement, x: f64, y: f64) f64 {
    if (p.board_poly) |poly| return outline.signedInset(poly, x, y);
    const r = p.board_rect orelse return -std.math.inf(f64);
    if (x < r.minx or y < r.miny or x > r.minx + r.w or y > r.miny + r.h) {
        const dx = @max(@max(r.minx - x, x - (r.minx + r.w)), 0);
        const dy = @max(@max(r.miny - y, y - (r.miny + r.h)), 0);
        return -std.math.hypot(dx, dy);
    }
    return @min(@min(x - r.minx, r.minx + r.w - x), @min(y - r.miny, r.miny + r.h - y));
}

/// Recognize a generated site without allocating the entire ring. Used by
/// JSON persistence to attach the reserved provenance tag to fresh results.
pub fn isGenerated(p: optimizer.Placement, via: router.Via) bool {
    if (!declared(p)) return false;
    const net = netIndex(p) orelse return false;
    const f = p.rules.perimeter_fence;
    return via.net == net and @abs(via.dia - f.via_dia) < 1e-6 and
        @abs(via.drill - f.via_drill) < 1e-6 and
        @abs(signedInsetOf(p, via.x, via.y) - f.edge_offset) < 1e-5;
}

const testing = std.testing;
const flat_netlist = @import("../flat_netlist.zig");

fn fixture(poly: ?[]const [2]f64) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &[_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &.{} }},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
        .board_poly = poly,
        .rules = .{ .perimeter_fence = .{
            .via_dia = 0.4,
            .via_drill = 0.2,
            .spacing = 1,
            .edge_offset = 0.5,
            .mask_width = 0.7,
        } },
    };
}

// spec: placement/perimeter-fence - a rectangular fence closes at no more than the declared pitch and keeps every centre at its exact edge offset
test "rectangular perimeter fence is uniformly inset" {
    const vias = try generate(testing.allocator, fixture(null));
    defer testing.allocator.free(vias);
    try testing.expectEqual(@as(usize, 56), vias.len); // 19×9 mm centre path
    for (vias) |via| {
        try testing.expectApproxEqAbs(@as(f64, 0.5), signedInsetOf(fixture(null), via.x, via.y), 1e-8);
        try testing.expectEqual(@as(i32, 0), via.net);
        try testing.expect(isGenerated(fixture(null), via));
    }
}

// spec: placement/perimeter-fence - exact rounded/polygon outlines, not their bounding boxes, drive perimeter sites
test "polygon perimeter fence follows exact outline" {
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 4 }, .{ 14, 10 }, .{ 0, 10 } };
    const p = fixture(&poly);
    const vias = try generate(testing.allocator, p);
    defer testing.allocator.free(vias);
    try testing.expect(vias.len > 40);
    for (vias) |via| try testing.expectApproxEqAbs(@as(f64, 0.5), outline.signedInset(&poly, via.x, via.y), 1e-7);
}

test "a via under a pad-free component is classified as generated perimeter copper" {
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 0.4,
        .hh = 0.4,
        .pads = &.{},
        .fallback = false,
        .x = 0.5,
        .y = 5,
    }};
    var p = fixture(null);
    p.parts = &parts;
    const via = router.Via{ .x = 0.5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 };
    try testing.expect(isGenerated(p, via));
}

// spec: placement/perimeter-fence - incomplete declarations and unresolved stitch nets emit no copper
test "invalid perimeter declarations are inert" {
    var p = fixture(null);
    p.rules.perimeter_fence.spacing = 0;
    try testing.expectEqual(@as(usize, 0), (try generate(testing.allocator, p)).len);
    p = fixture(null);
    p.rules.perimeter_fence.net = "CHASSIS";
    try testing.expectEqual(@as(usize, 0), (try generate(testing.allocator, p)).len);
}

// spec: placement/perimeter-fence - a perimeter keepout begins at the fence via's inward copper edge, carries typed block policy, and admits named nets
test "perimeter keepout resolves its exact inner limit and net exceptions" {
    var p = fixture(null);
    p.rules.perimeter_fence.keepout = .{
        .clearance = 0.3,
        .blocks = .{ .components = true, .tracks = true, .vias = true },
        .allow_nets = &.{"GND"},
    };
    try testing.expectApproxEqAbs(@as(f64, 1.0), keepoutLimit(p), 1e-9);
    try testing.expect(keepoutAllowsNet(p, 0));
    const inner = try insetOutline(testing.allocator, p, keepoutLimit(p));
    defer testing.allocator.free(inner);
    try testing.expectEqual(@as(usize, 4), inner.len);
    try testing.expectApproxEqAbs(@as(f64, 1), inner[0][0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), inner[0][1], 1e-9);
}

test "perimeter append skips sites that crowd foreign tracks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]flat_netlist.FlatNet{ .{ .name = "GND", .pins = &.{} }, .{ .name = "SIG", .pins = &.{} } };
    var p = fixture(null);
    p.nets = &nets;
    const signal = router.Track{ .x1 = 1, .y1 = 0.8, .x2 = 19, .y2 = 0.8, .width = 0.2, .layer = 0, .net = 1 };
    const result = (try append(arena, p, .{ .tracks = &.{signal}, .vias = &.{}, .routed = 1, .total = 1 })).?;
    try testing.expect(result.vias.len < (try generate(arena, p)).len);
}

// The gate `append` uses answers per candidate via; the reference is the full
// board check the old gate re-ran per site. The two must agree on every site,
// including candidates judged against previously ACCEPTED candidates.
test "additive via gate matches the full-check verdict site by site" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]flat_netlist.FlatNet{ .{ .name = "GND", .pins = &.{} }, .{ .name = "SIG", .pins = &.{} } };
    var p = fixture(null);
    p.nets = &nets;
    // A foreign track along the bottom fence path and a foreign via on the left
    // one, so some sites are refused for different via-scoped rules.
    const signal = router.Track{ .x1 = 1, .y1 = 0.8, .x2 = 19, .y2 = 0.8, .width = 0.2, .layer = 0, .net = 1 };
    const blocker = router.Via{ .x = 0.5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 1 };
    const routed = router.RouteResult{ .tracks = &.{signal}, .vias = &.{blocker}, .routed = 1, .total = 2 };
    const sites = try generate(arena, p);
    const baseline = drc.errorCount(try drc.check(arena, p, routed, p.rules.design.clearance));
    var gate = try drc.ViaAdditionGate.build(arena, p, routed, p.rules.design.clearance, sites[0]);
    var accepted: std.ArrayList(router.Via) = .empty;
    try accepted.appendSlice(arena, routed.vias);
    var refused: usize = 0;
    for (sites) |site| {
        try accepted.append(arena, site);
        const errors = drc.errorCount(try drc.check(arena, p, .{ .tracks = routed.tracks, .vias = accepted.items, .routed = 0, .total = 0 }, p.rules.design.clearance));
        const full_check_refuses = errors > baseline;
        accepted.items.len -= 1;
        try testing.expectEqual(full_check_refuses, try gate.addsError(arena, site));
        if (full_check_refuses) {
            refused += 1;
            continue;
        }
        try accepted.append(arena, site);
        try gate.accept(arena, site);
    }
    try testing.expect(refused > 0); // the fixture must actually exercise refusals
    try testing.expect(accepted.items.len > routed.vias.len); // …and acceptances
}

// spec: placement/perimeter-fence - component bodies and courtyards do not interrupt generated perimeter vias
// spec: placement/perimeter-fence - pad proximity is the only component-derived reason to suppress a perimeter via site, retaining 0.2 mm from pad copper to the via annulus; ordinary copper and drill DRC legality still applies
test "perimeter generation ignores bodies and clears pads by 0.2 mm" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{.{
        .ref_des = "J1",
        .kind = .hub,
        .x = 0.5,
        .y = 5,
        .hw = 0.8,
        .hh = 1.2,
        .pads = &.{},
        .fallback = false,
    }};
    var p = fixture(null);
    p.parts = &parts;
    try testing.expectEqual(@as(usize, 56), (try generate(arena, p)).len);

    const pads = [_]geometry.Pad{.{
        .number = "1",
        .x = 0,
        .y = 0,
        .w = 0.6,
        .h = 1.0,
    }};
    parts[0].pads = &pads;
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &.{.{ .ref_des = "J1", .pin = "1" }} }};
    p.nets = &nets;
    const generated = try generate(arena, p);
    try testing.expect(generated.len < 56);
    const shape = try pad_shape.worldShape(arena, parts[0], pads[0]);
    for (generated) |via| {
        const gap = pad_shape.pointDist(shape.x0, shape.y0, shape.x1, shape.y1, shape.poly, via.x, via.y, std.math.inf(f64)) - via.dia / 2;
        try testing.expect(gap >= pad_clearance_mm - 1e-9);
    }
}
