//! One place that turns a `(start, end, width, layer, net)` snapshot segment
//! into a `route_policy` track record.
//!
//! `route_policy` has two structurally identical track types with opposite
//! meanings: `ExistingTrack` is copper the maze must treat as an obstacle (or
//! as its own net's source), while `GuideTrack` is a non-copper centreline hint
//! that only lowers cost. `reference_guides` built one and `router_adapter`
//! built the other, each with its own field-for-field constructor — so the two
//! could drift into mapping the same segment to different endpoints.
//!
//! The types stay distinct on purpose (the type IS the difference between a
//! keepout and a hint); only the mapping is shared. `T` is passed explicitly so
//! a caller must name which of the two it is asking for.

const snapshot_mod = @import("snapshot.zig");

/// Build `T` — `route_policy.ExistingTrack` or `route_policy.GuideTrack` — from
/// the two endpoints of a board segment. `net` is already the router's net
/// index, since the two callers resolve it from different sources.
pub fn from(
    comptime T: type,
    a: snapshot_mod.Point,
    b: snapshot_mod.Point,
    width: f64,
    layer: u8,
    net: i32,
) T {
    return .{
        .x1 = a.x,
        .y1 = a.y,
        .x2 = b.x,
        .y2 = b.y,
        .layer = layer,
        .net = net,
        .width = width,
    };
}
