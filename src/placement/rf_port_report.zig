//! Persistent diagnostic shape for final RF port-frame route trials.

const solver = @import("rf_path_solver.zig");
const std = @import("std");

/// One RF net's selected G2 result and complete deterministic trial history.
pub const Outcome = struct {
    net: i32,
    chosen: usize,
    feasible: bool,
    success: bool,
    metrics: solver.Metrics,
    trials: []const solver.Trial,
    physical: struct {
        sample_count: usize,
        emitted_tracks: usize = 0,
        retained_tracks: usize = 0,
        gate_removed: bool = false,
        gate_first_error: []const u8 = "",
        /// The exact variable-width solver centreline. Save/load keeps this
        /// compact path proof and render/fab surfaces sweep it into one region.
        samples: []const solver.Sample = &.{},
        layer: u8 = 0,
    },
};

/// Convert the solver's geometry-bearing result to persistent diagnostics.
pub fn fromResult(net: i32, solved: solver.Result) Outcome {
    return .{
        .net = net,
        .chosen = solved.chosen,
        .feasible = solved.feasible,
        .success = solved.success,
        .metrics = solved.metrics,
        .trials = solved.trials,
        .physical = .{ .sample_count = solved.samples.len, .samples = solved.samples },
    };
}

/// Gather a net-indexed outcome map in stable physical-net order.
pub fn collectOrdered(arena: std.mem.Allocator, map: anytype, net_count: usize) std.mem.Allocator.Error![]const Outcome {
    var outcomes: std.ArrayList(Outcome) = .empty;
    for (0..net_count) |net| if (map.get(@intCast(net))) |outcome| try outcomes.append(arena, outcome);
    return outcomes.toOwnedSlice(arena);
}
