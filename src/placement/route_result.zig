//! Stable copper and diagnostic value types returned by the autorouter.

const rf_port_report = @import("rf_port_report.zig");

/// A routed copper segment. `layer` 0 = top, 1 = bottom signal. `net` is the
/// flattened-net index it carries.
pub const Track = struct { x1: f64, y1: f64, x2: f64, y2: f64, layer: u8, width: f64, net: i32 };

/// A via spanning the signal layers. `drill == 0` denotes legacy geometry.
pub const Via = struct { x: f64, y: f64, dia: f64, net: i32, drill: f64 = 0 };

/// A routed copper arc in KiCad's three-point start/mid/end form.
pub const Arc = struct {
    p1: [2]f64,
    pm: [2]f64,
    p2: [2]f64,
    layer: u8,
    width: f64,
    net: i32,
};

/// A bend-constrained corner that could not reach its required radius.
pub const SharpBend = struct {
    x: f64,
    y: f64,
    layer: u8,
    net: i32,
    radius: f64,
    required: f64,
};

/// Router output: physical copper, completion facts, and RF diagnostics.
pub const RouteResult = struct {
    tracks: []const Track,
    vias: []const Via,
    /// True-arc metadata; copper is also present in `tracks` as bounded chords.
    arcs: []const Arc = &.{},
    /// Under-radius RF corners surfaced by DRC.
    sharp_bends: []const SharpBend = &.{},
    /// Deterministic G2 port-frame search outcomes, ordered by net index.
    rf_port_outcomes: []const rf_port_report.Outcome = &.{},
    routed: usize,
    total: usize,
    failed: []const []const u8 = &.{},
    search_limited: []const usize = &.{},
    reference_replayed: []const usize = &.{},
    grid_overflow: bool = false,
    ripup_rounds: usize = 0,
    grid_scale: f64 = 1,
    cancelled: bool = false,
};
