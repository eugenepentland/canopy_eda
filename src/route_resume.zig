//! Request-local hard waypoints for manual-route autocomplete.

const std = @import("std");
const numeric = @import("numeric.zig");
const optimizer = @import("placement/optimizer.zig");
const route_policy = @import("placement/route_policy.zig");

/// Parses manual-completion input and overlays it on one routing run.
pub const ManualCompletion = struct {
    /// One ordered hard waypoint assigned to a concrete flattened net.
    pub const Point = struct {
        net: usize,
        point: route_policy.Waypoint,
    };

    fn number(value: ?std.json.Value) ?f64 {
        const v = value orelse return null;
        const n: f64 = switch (v) {
            .integer => |n| @floatFromInt(n),
            .float => |n| n,
            else => return null,
        };
        return if (std.math.isFinite(n)) n else null;
    }

    fn netIndex(placement: optimizer.Placement, name: []const u8) ?usize {
        for (placement.nets, 0..) |net, i| if (std.mem.eql(u8, net.name, name)) return i;
        return null;
    }

    /// Parse valid named-net completion points from a route request body.
    pub fn parse(
        alloc: std.mem.Allocator,
        root: std.json.Value,
        placement: optimizer.Placement,
    ) std.mem.Allocator.Error![]const Point {
        var out: std.ArrayList(Point) = .empty;
        if (root != .object) return out.items;
        const value = root.object.get("resume_points") orelse return out.items;
        if (value != .array) return out.items;
        for (value.array.items) |item| {
            if (item != .object) continue;
            const net_value = item.object.get("net") orelse continue;
            if (net_value != .string) continue;
            const net = netIndex(placement, net_value.string) orelse continue;
            const x = number(item.object.get("x")) orelse continue;
            const y = number(item.object.get("y")) orelse continue;
            const layer_value = number(item.object.get("layer")) orelse continue;
            const layer = numeric.checkedInt(u8, @floor(layer_value)) orelse continue;
            try out.append(alloc, .{ .net = net, .point = .{
                .x = x,
                .y = y,
                .layer = layer,
            } });
        }
        return out.toOwnedSlice(alloc);
    }

    /// Overlay ordered completion points without disturbing other net policy.
    pub fn apply(
        alloc: std.mem.Allocator,
        placement: optimizer.Placement,
        base: []const route_policy.NetPolicy,
        resume_points: []const Point,
    ) []const route_policy.NetPolicy {
        if (resume_points.len == 0) return base;
        const policies = alloc.alloc(route_policy.NetPolicy, placement.nets.len) catch return base;
        for (policies, 0..) |*policy, net_i| policy.* = if (net_i < base.len) base[net_i] else .{};
        const points = alloc.alloc(std.ArrayList(route_policy.Waypoint), policies.len) catch return base;
        for (points) |*list| list.* = .empty;
        for (resume_points) |resume_point| {
            if (resume_point.net >= points.len) continue;
            points[resume_point.net].append(alloc, resume_point.point) catch return base;
        }
        for (points, policies) |*list, *policy| {
            if (list.items.len == 0) continue;
            policy.waypoints = list.toOwnedSlice(alloc) catch return base;
            // RF routing normally gets an axis-only first attempt that may use
            // plain waypoints as advisory shape hints. A one-limb authored
            // tree makes this request's points hard without changing the
            // persisted plan; two-terminal nets lower it back to this chain,
            // while multi-drop nets retain the shared hard trunk.
            const hard = alloc.alloc(route_policy.GuideBranch, 1) catch return base;
            hard[0] = .{ .waypoints = policy.waypoints };
            policy.wave.branches = hard;
        }
        return policies;
    }

    /// Resolve an optional request effort while preserving the caller fallback.
    pub fn effort(root: std.json.Value, default: ?route_policy.Effort) ?route_policy.Effort {
        if (root != .object) return default;
        const value = root.object.get("effort") orelse return default;
        if (value != .string) return default;
        return route_policy.Effort.fromName(value.string) orelse default;
    }
};

test "manual completion points become ordered hard waypoints" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const nets = [_]optimizer.FlatNet{.{ .name = "RFOUT", .pins = &.{} }};
    const placement = optimizer.Placement{ .parts = &.{}, .nets = &nets, .links = &.{}, .loops = &.{}, .stubs = &.{}, .instances = &.{}, .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 }, .minx = 0, .miny = 0, .maxx = 10, .maxy = 10, .generated = false };
    const root = try std.json.parseFromSliceLeaky(std.json.Value, alloc,
        \\{"resume_points":[{"net":"RFOUT","x":1.25,"y":2.5,"layer":0},{"net":"RFOUT","x":4.5,"y":5.75,"layer":1}]}
    , .{});
    const parsed = try ManualCompletion.parse(alloc, root, placement);
    try std.testing.expectEqual(@as(usize, 2), parsed.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), parsed[0].point.x, 1e-9);
    const policies = ManualCompletion.apply(alloc, placement, &.{}, parsed);
    try std.testing.expectEqual(@as(usize, 2), policies[0].waypoints.len);
    try std.testing.expectEqual(@as(usize, 1), policies[0].wave.branches.len);
    try std.testing.expectEqual(policies[0].waypoints.ptr, policies[0].wave.branches[0].waypoints.ptr);
    try std.testing.expectApproxEqAbs(@as(f64, 5.75), policies[0].waypoints[1].y, 1e-9);
    try std.testing.expectEqual(@as(u8, 1), policies[0].waypoints[1].layer);
}
