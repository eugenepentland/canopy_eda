//! Source-to-load copper voltage budgets. Unknown resistance is never zero.
/// Electrical comparison tolerance (one microvolt), unrelated to geometry.
const voltage_epsilon_v: f64 = 1e-6;

/// One load's maximum-current copper loss. Values are volts, never millimetres.
pub const Assessment = struct {
    net: usize,
    load: []const u8 = "",
    budget: @import("../eval/env.zig").NetClassSpec.VoltageDrop,
    supply_drop_v: ?f64 = null,
    return_drop_v: ?f64 = null,
    return_net: ?usize = null,
    /// Empty only when both conductors and all maximum loads were modeled.
    reason: []const u8 = "",

    pub fn knownDrop(self: Assessment) f64 {
        return (self.supply_drop_v orelse 0) + (self.return_drop_v orelse 0);
    }

    pub fn exceeded(self: Assessment) bool {
        return self.budget.limit_v > 0 and self.knownDrop() > self.budget.limit_v + voltage_epsilon_v;
    }

    /// A widening proposal, not a proof: barrel resistance and clearance can
    /// prevent convergence, and DRC always measures the final copper again.
    pub fn scale(self: Assessment) f64 {
        if (!self.exceeded()) return 1;
        return @min(16, self.knownDrop() / self.budget.limit_v * 1.1);
    }
};
