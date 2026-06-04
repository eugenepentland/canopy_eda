//! Post-route design-rule check. Given a placement and the router's output,
//! it flags every pair of copper features on *different* nets that sit closer
//! than the clearance rule — the common offender being a ground via dropped on
//! a pad whose copper then crowds a neighbouring pad of another net.
//!
//! Scope (v1): via↔pad, via↔via, via↔track, and pad↔pad (across parts). The
//! router already enforces track↔track and track↔pad spacing through its grid
//! pitch + obstacle halo, so those aren't re-checked here. Coordinates are
//! millimetres; gaps are edge-to-edge (0 ⇒ touching, negative ⇒ overlapping).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const export_kicad = @import("../export_kicad.zig");

const FlatNet = export_kicad.FlatNet;

/// What two features clash. Used for the marker label on the page.
pub const Kind = enum { via_pad, via_via, via_track, pad_pad };

/// One clearance violation, located at the midpoint of the offending gap.
pub const Violation = struct {
    x: f64,
    y: f64,
    gap: f64, // actual edge-to-edge distance (mm); < clearance
    clearance: f64, // the rule that was broken (mm)
    kind: Kind,
};

/// A pad reduced to its world rect, the net it carries, and its part index
/// (so two pads of the same part are never checked against each other).
const PadBox = struct { x0: f64, y0: f64, x1: f64, y1: f64, net: i32, part: usize };

const EPS: f64 = 1e-6;

/// Run the check. All output is allocated in `arena`. `clearance` is the
/// copper-to-copper rule (mm); two features of different nets must be at least
/// this far apart, edge to edge.
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

    // via ↔ pad
    for (vias) |v| {
        const vr = v.dia / 2;
        for (pads) |p| {
            if (sameNet(v.net, p.net)) continue;
            const gap = distPointRect(v.x, v.y, p) - vr;
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
    // pad ↔ pad (different parts)
    for (pads, 0..) |a, i| {
        for (pads[i + 1 ..]) |b| {
            if (a.part == b.part or sameNet(a.net, b.net)) continue;
            const gap = rectRectGap(a, b);
            if (gap < clearance - EPS) {
                const mx = (std.math.clamp((a.x0 + a.x1) / 2, b.x0, b.x1) + std.math.clamp((b.x0 + b.x1) / 2, a.x0, a.x1)) / 2;
                const my = (std.math.clamp((a.y0 + a.y1) / 2, b.y0, b.y1) + std.math.clamp((b.y0 + b.y1) / 2, a.y0, a.y1)) / 2;
                try out.append(arena, .{ .x = mx, .y = my, .gap = gap, .clearance = clearance, .kind = .pad_pad });
            }
        }
    }
    return out.toOwnedSlice(arena);
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
        const q = @mod(@round(part.rot), 360);
        for (part.pads) |pad| {
            const c = optimizer.worldPadCenter(part, pad.x, pad.y);
            const hw = if (q == 90 or q == 270) pad.h / 2 else pad.w / 2;
            const hh = if (q == 90 or q == 270) pad.w / 2 else pad.h / 2;
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ part.ref_des, pad.number });
            const net = pin_net.get(key) orelse -1;
            try list.append(arena, .{ .x0 = c[0] - hw, .y0 = c[1] - hh, .x1 = c[0] + hw, .y1 = c[1] + hh, .net = net, .part = pi });
        }
    }
    return list.toOwnedSlice(arena);
}

/// Distance from a point to an axis-aligned rect (0 if inside).
fn distPointRect(px: f64, py: f64, r: PadBox) f64 {
    const dx = @max(@max(r.x0 - px, px - r.x1), 0);
    const dy = @max(@max(r.y0 - py, py - r.y1), 0);
    return std.math.hypot(dx, dy);
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

/// Edge-to-edge gap between two axis-aligned rects (0 if they overlap/touch).
fn rectRectGap(a: PadBox, b: PadBox) f64 {
    const gx = @max(@max(a.x0 - b.x1, b.x0 - a.x1), 0);
    const gy = @max(@max(a.y0 - b.y1, b.y0 - a.y1), 0);
    return std.math.hypot(gx, gy);
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
