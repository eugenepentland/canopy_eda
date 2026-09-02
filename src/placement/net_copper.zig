//! One net's copper, gathered out of a board for the length measures.
//!
//! Both length rules — the diff-pair skew measure and the `(match-group …)`
//! measure — start by filtering the board's tracks and vias down to one net
//! and re-shaping them into `copper_length`'s vocabulary, and both used to
//! carry their own copy of that filter. The copies agreed, which is exactly
//! the risk: the VIAS are the part that is easy to leave out, and a net whose
//! vias are missing measures as several islands instead of one path, so the
//! rule silently stops reporting the skew it exists to report.

const std = @import("std");
const router = @import("router.zig");
const copper_length = @import("copper_length.zig");

/// The routed copper both length rules read. Bundled because a length measure
/// needs the VIAS too — a leg's electrical path crosses layers only through a
/// barrel, so a track-only view cannot tell joined copper from stacked copper.
pub const Copper = struct { tracks: []const router.Track, vias: []const router.Via };

/// One net's copper in `copper_length`'s shape. Both slices are arena-owned
/// and may be empty (an unrouted net).
pub const OneNet = struct {
    segs: []const copper_length.Seg,
    vias: []const copper_length.Via,
};

/// Everything on net index `ni`, in board order.
pub fn collect(
    arena: std.mem.Allocator,
    copper: Copper,
    ni: i32,
) std.mem.Allocator.Error!OneNet {
    var segs: std.ArrayList(copper_length.Seg) = .empty;
    for (copper.tracks) |t| {
        if (t.net != ni) continue;
        try segs.append(arena, .{ .a = .{ t.x1, t.y1 }, .b = .{ t.x2, t.y2 }, .layer = t.layer });
    }
    var vias: std.ArrayList(copper_length.Via) = .empty;
    for (copper.vias) |v| {
        if (v.net == ni) try vias.append(arena, .{ .at = .{ v.x, v.y } });
    }
    return .{ .segs = segs.items, .vias = vias.items };
}
