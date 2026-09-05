//! Shared physical rules for autorouter via placement.
//!
//! Kept separate from `router.zig` so every via-producing path uses the same
//! copper-spacing and exact-outline arithmetic without growing the maze core.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const outline = @import("outline.zig");

const eps: f64 = 1e-6;
const staging_exempt_mm: f64 = 10.0;

/// Required node inset for routed tracks. Vias use `clearsOutline` at their
/// exact candidate coordinates, so their larger radius does not wall traces
/// out of a legal edge corridor.
pub fn edgeInset(track_width: f64, via_dia: f64, edge: f64) f64 {
    _ = via_dia;
    return track_width / 2 + edge;
}

fn rectInset(br: optimizer.BoardRect, x: f64, y: f64) f64 {
    return @min(@min(x - br.minx, br.minx + br.w - x), @min(y - br.miny, br.miny + br.h - y));
}

fn boardInset(placement: optimizer.Placement, br: optimizer.BoardRect, x: f64, y: f64) f64 {
    if (placement.board_poly) |poly| {
        if (poly.len >= 3) return outline.signedInset(poly, x, y);
    }
    return rectInset(br, x, y);
}

/// Signed point inset from a placement's exact outline, when one exists.
pub fn pointInset(placement: optimizer.Placement, x: f64, y: f64) ?f64 {
    const br = placement.board_rect orelse return null;
    return boardInset(placement, br, x, y);
}

/// Whether an off-grid via keeps its copper radius and edge rule inside the
/// exact board outline. Far-off staging copper retains the DRC exemption.
pub fn clearsOutline(
    br: ?optimizer.BoardRect,
    poly: ?[]const [2]f64,
    via_dia: f64,
    edge: f64,
    x: f64,
    y: f64,
) bool {
    const board = br orelse return true;
    const inset = if (poly) |points|
        if (points.len >= 3) outline.signedInset(points, x, y) else rectInset(board, x, y)
    else
        rectInset(board, x, y);
    const radius = via_dia / 2;
    if (inset < -(radius + staging_exempt_mm)) return true;
    return inset - radius >= edge - eps;
}

/// Build the shared maze node mask at the routed-track edge inset.
pub fn buildOutlineMask(
    comptime GridType: type,
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    grid: GridType,
    inset_req: f64,
) std.mem.Allocator.Error!?[]const bool {
    const br = placement.board_rect orelse return null;
    const mask = try arena.alloc(bool, grid.nx * grid.ny);
    for (0..grid.ny) |iy| {
        for (0..grid.nx) |ix| {
            mask[grid.node(ix, iy)] = boardInset(placement, br, grid.worldX(ix), grid.worldY(iy)) < inset_req;
        }
    }
    return mask;
}

/// Flag nets whose pad centres sit beyond the DRC staging band.
pub fn netOffboard(
    comptime Obs: type,
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    obs: []const Obs,
    threshold: f64,
) std.mem.Allocator.Error![]const bool {
    if (placement.board_rect == null) return &.{};
    const flags = try arena.alloc(bool, placement.nets.len);
    @memset(flags, false);
    for (obs) |pad| {
        if (pad.net < 0) continue;
        const net: usize = @intCast(pad.net);
        if (net >= flags.len) continue;
        if (pointInset(placement, (pad.x0 + pad.x1) / 2, (pad.y0 + pad.y1) / 2).? < -threshold) flags[net] = true;
    }
    return flags;
}

/// Copper geometry needed by the via-spacing functions.
pub const CopperRule = struct {
    via_to_via: f64,
    via_dia: f64,
    ordinary: f64,
};

/// Whether a check covers all vias or only the same-net subset that the maze's
/// connective occupancy raster intentionally ignores.
pub const Scope = enum { all, same_net };

/// Required centre spacing for two via copper discs.
pub fn pairCenterNeed(rule: CopperRule, other_dia: f64, scope: Scope) f64 {
    const clearance = if (scope == .same_net and rule.via_to_via > 0) rule.via_to_via else rule.ordinary;
    return rule.via_dia / 2 + other_dia / 2 + clearance;
}

/// Whether a candidate via clears the selected subset of a placed-via slice.
pub fn clears(
    comptime ViaType: type,
    placed: []const ViaType,
    rule: CopperRule,
    point: [2]f64,
    net: i32,
    scope: Scope,
) bool {
    for (placed) |via| {
        const same = via.net == net;
        if (scope == .same_net and !same) continue;
        const need = pairCenterNeed(rule, via.dia, if (same) .same_net else .all);
        if (std.math.hypot(point[0] - via.x, point[1] - via.y) < need - eps) return false;
    }
    return true;
}

/// Validate every layer-change site in one pending maze path against existing
/// same-net vias and the other transitions in that path before emission.
pub fn pathClears(
    comptime Input: type,
    input: Input,
    path: []const usize,
    comptime ViaType: type,
    existing: []const ViaType,
) std.mem.Allocator.Error!bool {
    var pending: std.ArrayList([2]f64) = .empty;
    for (path[1..], 0..) |key, i| {
        const previous = path[i];
        if (key / input.nodes == previous / input.nodes) continue;
        const node = previous % input.nodes;
        const point = [2]f64{ input.grid.worldX(node % input.grid.nx), input.grid.worldY(node / input.grid.nx) };
        if (!clears(ViaType, existing, input.rule, point, input.net, .same_net)) return false;
        const need = pairCenterNeed(input.rule, input.rule.via_dia, .same_net);
        for (pending.items) |other| {
            if (std.math.hypot(point[0] - other[0], point[1] - other[1]) < need - eps) return false;
        }
        try pending.append(input.arena, point);
    }
    return true;
}

// spec: placement/router-via-rules - same-net via copper spacing overrides the drill-wall-only placement that produced TXDATA's doubled vias
test "same-net via copper spacing rejects the TXDATA drill-wall-only pitch" {
    const rule = CopperRule{ .via_to_via = 0, .via_dia = 0.4, .ordinary = 0.127 };
    try std.testing.expect(pairCenterNeed(rule, 0.4, .same_net) > 0.4);
    try std.testing.expect(pairCenterNeed(.{ .via_to_via = 0.3, .via_dia = 0.4, .ordinary = 0.127 }, 0.4, .same_net) > 0.69);

    const Via = struct { x: f64, y: f64, dia: f64, net: i32 };
    const placed = [_]Via{.{ .x = 1, .y = 1, .dia = 0.4, .net = 0 }};
    try std.testing.expect(!clears(Via, &placed, rule, .{ 1.4, 1 }, 0, .all));
    try std.testing.expect(clears(Via, &placed, rule, .{ 1.53, 1 }, 0, .all));

    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const Grid = struct {
        nx: usize = 10,
        g: f64 = 0.1,
        fn worldX(self: @This(), node: usize) f64 {
            return @as(f64, @floatFromInt(node)) * self.g;
        }
        fn worldY(_: @This(), _: usize) f64 {
            return 0;
        }
    };
    const input = .{ .arena = arena_inst.allocator(), .grid = Grid{}, .nodes = @as(usize, 10), .rule = rule, .net = @as(i32, 0) };
    // Two layer changes only 0.4 mm apart inside one not-yet-emitted path.
    const path = [_]usize{ 0, 10, 14, 4 };
    try std.testing.expect(!try pathClears(@TypeOf(input), input, &path, Via, &.{}));
}

// spec: placement/router-via-rules - exact off-grid via clearance measures the via radius against the physical outline
test "exact outline clearance rejects the board-a edge geometry" {
    const br = optimizer.BoardRect{ .minx = 128.5, .miny = 100, .w = 10, .h = 10 };
    try std.testing.expect(!clearsOutline(br, null, 0.4, 0.2, 128.897, 105));
    try std.testing.expect(clearsOutline(br, null, 0.4, 0.2, 128.9, 105));
}
