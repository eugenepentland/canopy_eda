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

/// Desired width for a rail that can be routed narrow and widened after the
/// centreline is known. Null preserves exact geometry.
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
