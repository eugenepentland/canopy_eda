//! Small, fill-blind queries over authored bypass intent.
//!
//! These predicates deliberately depend only on the placement model so late
//! copper finishers can preserve exact cap-to-pin requirements without pulling
//! in the DRC or router and creating an import cycle.

const optimizer = @import("optimizer.zig");

/// Does `net_i` carry at least one authored, non-reservoir bypass leg whose
/// local surface path must terminate on an exact IC supply pad?
pub fn exactNet(placement: optimizer.Placement, net_i: usize) bool {
    for (placement.loops) |loop| {
        if (loop.explicit_pin.len == 0 or loop.rail_optout or loop.pwr_net < 0) continue;
        if (@as(usize, @intCast(loop.pwr_net)) == net_i) return true;
    }
    return false;
}
