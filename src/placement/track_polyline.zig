//! One emitter for "turn a centreline point chain back into tracks".
//!
//! Every post-route pass that rewrites a chain (`pad_entry`'s terminal trim,
//! `straighten`'s gloss) ends by re-emitting the surviving points as segments,
//! and both used to carry their own copy of the loop. The copies had stopped
//! agreeing about the degenerate input: `pad_entry`'s guarded `pts.len < 2`
//! because a trim may DROP a chain outright, `straighten`'s did not — and
//! `for (1..0)` on an empty chain is illegal behaviour, i.e. a panic in a safe
//! build rather than "emits nothing". One copy is the fix for the other.
//!
//! Deliberately a leaf: it imports only the copper value types, never the
//! router, so either pass can use it without a cycle.

const std = @import("std");
const route_result = @import("route_result.zig");

/// Coincidence tolerance for two consecutive chain points, well below fab
/// resolution — it only absorbs the drift of a world→grid→world round trip.
const eps: f64 = 1e-9;

/// Append one track per non-degenerate hop of `pts`, all on `layer`/`width`
/// and carrying net index `net`.
///
/// A chain of fewer than two points emits NOTHING rather than panicking: a
/// pass that dropped a chain hands over an empty slice, and a single surviving
/// point is a terminal with no copper left to draw. Consecutive points closer
/// than `eps` are skipped, so a chain that a simplifier collapsed does not
/// produce zero-length copper.
pub fn emit(
    arena: std.mem.Allocator,
    out: *std.ArrayList(route_result.Track),
    pts: []const [2]f64,
    layer: u8,
    width: f64,
    net: i32,
) std.mem.Allocator.Error!void {
    if (pts.len < 2) return;
    for (1..pts.len) |k| {
        if (std.math.hypot(pts[k][0] - pts[k - 1][0], pts[k][1] - pts[k - 1][1]) < eps) continue;
        try out.append(arena, .{
            .x1 = pts[k - 1][0],
            .y1 = pts[k - 1][1],
            .x2 = pts[k][0],
            .y2 = pts[k][1],
            .layer = layer,
            .width = width,
            .net = net,
        });
    }
}
