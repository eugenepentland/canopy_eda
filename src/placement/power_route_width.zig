//! Route-search versus electrical-target width policy for power nets.
//!
//! Current capacity is not a fabrication clearance rule. An unpoured rail may
//! search at an ordinary legal width and grow after routing; a plane/pour
//! fanout, controlled-impedance line, or differential pair keeps exact authored
//! geometry.

const optimizer = @import("optimizer.zig");
const plane_stitch = @import("plane_stitch.zig");
const route_policy = @import("route_policy.zig");

fn pourCarried(zones: []const route_policy.ExistingZone, placement: optimizer.Placement, net_i: usize) bool {
    if (net_i >= placement.nets.len) return false;
    if (plane_stitch.netHasPlane(placement, placement.nets[net_i].name)) return true;
    const net: i32 = @intCast(net_i);
    for (zones) |zone| if (zone.copper and zone.net == net) return true;
    return false;
}

/// Width used when adaptive growth is inapplicable: authored geometry for a
/// carried rail, otherwise the larger of authored and whole-rail IPC target.
pub fn exactWidth(
    zones: []const route_policy.ExistingZone,
    placement: optimizer.Placement,
    net_i: usize,
    authored: f64,
) f64 {
    if (pourCarried(zones, placement, net_i) or net_i >= placement.nets.len) {
        if (net_i < placement.nets.len and net_i < placement.rules.net.len) {
            const branch = placement.rules.net[net_i].pad_neck.power_branch_width;
            if (branch > 0) return @max(branch, placement.rules.design.min_width);
        }
        return authored;
    }
    return @max(authored, placement.rules.powerWidthForNet(placement.nets[net_i].name) orelse 0);
}

/// The fabrication-legal centreline the router searches for a rail this pass
/// may widen afterwards.
///
/// TWIN of the width branch in `router.setNetParams`, which is where the route
/// context's own copy is resolved. Spelled again here because the finisher has
/// to know every net's floor BEFORE it configures the context for any one of
/// them, and reaching into `setNetParams` for that answer would clear per-net
/// route policy the passes after it still read.
pub fn adaptiveFloorWidth(placement: optimizer.Placement, net_i: usize, base_width: f64) f64 {
    var authored = base_width;
    if (net_i < placement.rules.net.len and placement.rules.net[net_i].width > 0)
        authored = placement.rules.net[net_i].width;
    return @max(placement.rules.design.min_width, @min(authored, base_width));
}

/// Desired width for a rail that can be routed narrow and widened after the
/// centreline is known. Null preserves exact geometry.
///
/// This is the WHOLE-RAIL answer: one width for every segment of the net. It is
/// the ceiling and the fallback, not the final target — `power_branch_width`
/// refines it per segment from the power-integrity solve's local branch current
/// once the copper exists, and returns to this width exactly where that solve
/// cannot judge a branch.
pub fn adaptiveTargetWidth(
    zones: []const route_policy.ExistingZone,
    placement: optimizer.Placement,
    net_i: usize,
    authored: f64,
) ?f64 {
    if (net_i >= placement.nets.len or pourCarried(zones, placement, net_i)) return null;
    const required = placement.rules.powerWidthForNet(placement.nets[net_i].name) orelse return null;
    if (net_i < placement.rules.net.len) {
        const rule = placement.rules.net[net_i];
        if (rule.rf.impedance.ohms > 0 or rule.rf.impedance.diff_ohms > 0) return null;
    }
    for (placement.diff_pairs) |pair| if (pair.p == net_i or pair.n == net_i) return null;
    return @max(authored, required);
}
