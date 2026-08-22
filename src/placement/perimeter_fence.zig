//! Board-outline via fencing derived from `(board … (perimeter-fence …))`.
//!
//! The declaration is authoritative: callers regenerate these vias from the
//! exact current outline instead of treating them as hand-routed copper. Sites
//! lie on a polygon offset inward by the authored centre-to-edge distance and
//! are divided evenly around that closed path, so there is no oversized seam
//! gap. The declared spacing is a maximum; the final pitch is `perimeter/N`.

const std = @import("std");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const outline = @import("outline.zig");
const numeric = @import("../numeric.zig");

/// Saved-route provenance reserved for board-derived perimeter sites.
pub const provenance = "@perimeter";

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
    const vias = try alloc.alloc(router.Via, count);
    for (vias, 0..) |*via, i| {
        // Half-pitch phase avoids pinning a site to the polygon's arbitrary
        // seam while preserving a uniform closed-loop pitch.
        const pt = pointAt(path, (@as(f64, @floatFromInt(i)) + 0.5) * pitch);
        via.* = .{
            .x = pt[0],
            .y = pt[1],
            .dia = p.rules.perimeter_fence.via_dia,
            .drill = p.rules.perimeter_fence.via_drill,
            .net = net,
        };
    }
    return vias;
}

fn sameVia(a: router.Via, b: router.Via) bool {
    return a.net == b.net and std.math.hypot(a.x - b.x, a.y - b.y) < 1e-6;
}

/// Perimeter stitches are derived copper, so a component courtyard wins when
/// the two compete for the same edge real estate. This is deliberately
/// net-blind: a grounded header still must not have a fence barrel drilled
/// under its plastic body or lands.
fn crowdsComponent(p: optimizer.Placement, site: router.Via) bool {
    const radius = site.dia / 2;
    for (p.parts) |part| {
        const c = optimizer.worldCourtyard(&part);
        const qx = std.math.clamp(site.x, c.minx, c.minx + c.w);
        const qy = std.math.clamp(site.y, c.miny, c.miny + c.h);
        if (std.math.hypot(site.x - qx, site.y - qy) < radius - 1e-9) return true;
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
        if (crowdsComponent(p, site)) continue;
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

// spec: placement/perimeter-fence - derived perimeter sites yield to component courtyards even when the component shares the stitch net
test "perimeter append skips sites under a grounded edge component" {
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
    const raw = try generate(arena, p);
    const result = (try append(arena, p, null)).?;
    try testing.expect(result.vias.len < raw.len);
    for (result.vias) |via| try testing.expect(!crowdsComponent(p, via));
}
