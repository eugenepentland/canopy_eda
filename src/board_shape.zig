//! Board-shape predicates for consumers ABOVE the placement layer.
//!
//! `placement/outline.zig` owns the board's exact shape maths — the even-odd
//! point-in-polygon test and the three-point-arc circumcircle recovery. Layers
//! above placement need the same answers: the STEP exporter turns the outline's
//! arcs into B-rep CIRCLE edges, and the sub-circuit router asks whether a point
//! falls inside a live pour. Before this module each of them carried a private
//! hand-copy, and the copies had already drifted (`guardian-check twin-drift`).
//!
//! They cannot simply import `placement/outline.zig`: the `[[layering]]`
//! rule `serve-placement-internals` forbids `src/serve/*` from compiling
//! against `src/placement/*`, and its baseline is frozen against growth. So
//! the shape MODEL is re-exported here, at the top level, where the serve layer
//! may read it — the same seam `export_gerber.zig` and `fab_readiness.zig`
//! already are. Nothing is re-implemented; these are aliases, so there is
//! exactly one implementation of each predicate in the tree.

const outline = @import("placement/outline.zig");

/// Even-odd ray-cast point-in-polygon test over a closed vertex list in board
/// mm. Points exactly on an edge may land on either side.
pub const contains = outline.contains;

/// Recovered centre, radius, and directed sweep of a three-point native arc.
pub const ArcCircle = outline.ArcCircle;

/// Recover the circumcircle and signed start→end sweep of a three-point arc,
/// or null when the three points are collinear.
pub const arcCircle = outline.arcCircle;
