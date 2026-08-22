//! Return-path continuity — a routed-result signal-integrity metric.
//!
//! On a 4-layer GND/PWR stack a signal via swaps its reference plane (top
//! references GND, bottom references PWR), so its return current must hop
//! planes — which needs a nearby GND stitching via to stay continuous. A
//! broken or long return path dominates EMI far more than trace length
//! (TI SNVA638A), so a signal via with no ground via in reach is counted here.
//!
//! Split out of `router.zig`: this reads a FINISHED `RouteResult` and the
//! placement, and takes no part in routing.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");

const RouteResult = router.RouteResult;
const isGroundName = optimizer.isGroundName;
const shortName = router.shortName;

/// A signal via needs a GND stitching via within this radius (mm) for its return
/// current to stay continuous across the layer change. ~2 mm is a common
/// stitching guideline for the low-MHz–GHz range these modules operate in.
pub const return_path_radius_mm: f64 = 2.0;

/// True when via net index `net` is a ground (plane-drop / stitching) via.
pub fn isGndVia(placement: optimizer.Placement, net: i32) bool {
    if (net < 0) return false;
    const ni: usize = @intCast(net);
    if (ni >= placement.nets.len) return false;
    return isGroundName(shortName(placement.nets[ni].name));
}

/// Count return-path discontinuities in a routed board: signal-net layer-change
/// vias that lack a GND stitching via within `radius` mm. On a 4-layer GND/PWR
/// stack a signal via swaps its reference plane (top references GND, bottom
/// references PWR), so its return current must hop planes — which needs a nearby
/// GND via to stay continuous. A broken/long return path dominates EMI far more
/// than trace length (TI SNVA638A), so this flags the discontinuity. Ground vias
/// are the stitching vias themselves and are never counted. O(vias²); routed
/// boards have only dozens of vias, and this runs only on an explicit route.
pub fn returnPathViolations(placement: optimizer.Placement, routed: RouteResult, radius: f64) usize {
    return returnPathViolationsForNets(placement, routed, radius, &.{});
}

/// Count return-path discontinuities only for signal vias whose net name is in
/// `selected_names`. An empty selection means all signal vias. Ground stitching
/// vias remain visible to every selected net when checking proximity.
pub fn returnPathViolationsForNets(
    placement: optimizer.Placement,
    routed: RouteResult,
    radius: f64,
    selected_names: []const []const u8,
) usize {
    var count: usize = 0;
    for (routed.vias) |v| {
        if (isGndVia(placement, v.net)) continue; // a stitching via, not a signal hop
        if (!returnPathNetSelected(placement, v.net, selected_names)) continue;
        var stitched = false;
        for (routed.vias) |g| {
            if (!isGndVia(placement, g.net)) continue;
            if (std.math.hypot(v.x - g.x, v.y - g.y) <= radius) {
                stitched = true;
                break;
            }
        }
        if (!stitched) count += 1;
    }
    return count;
}

fn returnPathNetSelected(
    placement: optimizer.Placement,
    net: i32,
    selected_names: []const []const u8,
) bool {
    if (selected_names.len == 0) return true;
    if (net < 0) return false;
    const net_i: usize = @intCast(net);
    if (net_i >= placement.nets.len) return false;
    for (selected_names) |name| {
        if (std.ascii.eqlIgnoreCase(placement.nets[net_i].name, name)) return true;
    }
    return false;
}
