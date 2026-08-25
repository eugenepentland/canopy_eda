//! Stable pad-transition shaping seam shared by route lowering and the solver.
//!
//! The web layer must not import placement implementation modules directly.
//! This small root-level adapter keeps that boundary while ensuring replayed
//! sub-circuit copper uses the exact same fabrication profile as a normal
//! router result.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const pad_neck = @import("placement/pad_neck.zig");

/// Restore selected replay tracks to their authored nominal class width, then
/// apply the ordinary authored neck or controlled-impedance taper profile at
/// SMD endpoints.
pub fn restoreGeneratedTracks(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    selected: []const bool,
    routed: router.RouteResult,
) std.mem.Allocator.Error!router.RouteResult {
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, routed.tracks);
    for (tracks.items) |*track| {
        if (track.net < 0) continue;
        const ni: usize = @intCast(track.net);
        if (ni >= selected.len or !selected[ni] or ni >= placement.rules.net.len) continue;
        const rule = placement.rules.net[ni];
        if (rule.width > 0) track.width = rule.width;
    }
    _ = try pad_neck.shapeGeneratedTracks(arena, placement, selected, &tracks);
    var out = routed;
    out.tracks = tracks.items;
    return out;
}
