//! Physical connectivity projection shared by routing and its inspection tools.
const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const pour = @import("placement/pour.zig");
const fab_readiness = @import("fab_readiness.zig");
/// The same generated perimeter copper used by persisted routing.
pub const appendPerimeter = @import("placement/perimeter_fence.zig").append;

/// Measure physical connectivity, including saved arcs, RF paths and pours.
/// Empty copper still has the placement's routable terminals.
pub fn tally(alloc: std.mem.Allocator, placement: optimizer.Placement, result: ?router.RouteResult, zones: []const pour.UserZone) std.mem.Allocator.Error!fab_readiness.Tally {
    const r = result orelse router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0, .failed = &.{} };
    return fab_readiness.routableTally(alloc, placement, .{
        .tracks = r.tracks,
        .vias = r.vias,
        .arcs = r.arcs,
        .rf_paths = r.rf_port_outcomes,
        .zones = zones,
    });
}

/// Reconcile even a cancelled candidate without searching or changing copper.
pub fn reconcile(alloc: std.mem.Allocator, placement: optimizer.Placement, result: router.RouteResult, zones: []const pour.UserZone) std.mem.Allocator.Error!router.RouteResult {
    const counts = try tally(alloc, placement, result, zones);
    var out = result;
    out.routed = counts.routed;
    out.total = counts.total;
    out.failed = counts.open;
    return out;
}
