//! Persisted `.layouts.json` domain types.
//!
//! This leaf module deliberately owns no filesystem or JSON behavior.  Both
//! the page and the sidecar codec depend on these records, so keeping them
//! here prevents the codec from importing the very large page module merely
//! to name its data model.

const font5x7 = @import("font5x7.zig");
const optimizer = @import("placement/optimizer.zig");
const rf_path_solver = @import("placement/rf_path_solver.zig");
const saved_zone = @import("serve/saved_zone.zig");
const shape_sketch = @import("shape_sketch.zig");

/// One placed part within a saved layout: ref-des + centre (mm) + rotation,
/// plus the renumber-stable module-local `origin` identity.
pub const PartPose = struct {
    ref: []const u8,
    x: f64,
    y: f64,
    rot: f64,
    origin: []const u8 = "",
    side: optimizer.Side = .top,
    locked: bool = false,
};

/// One driving PCB-editor dimension from a footprint origin to an outline
/// edge. `offset` is the signed origin coordinate minus the edge coordinate.
pub const SavedPartEdgeDimension = struct {
    ref: []const u8,
    axis: []const u8,
    edge_id: u32,
    offset: f64,
};

/// The optimizer objective and the visible HPWL/decoupling-loop terms stored
/// beside a saved layout.
pub const LayoutScore = struct { hpwl: f64, loop: f64, caps: usize, objective: f64 = 0 };

/// One physical finned heatsink authored on a saved PCB layout.
pub const SavedHeatsink = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    side: []const u8 = "bottom",
    target_ref: []const u8 = "",
    material: []const u8 = "aluminum_6063",
    base_mm: f64 = 2,
    fin_height_mm: f64 = 10,
    fin_thickness_mm: f64 = 1,
    fin_gap_mm: f64 = 1.5,
    fin_axis: []const u8 = "length",
    pad_thickness_mm: f64 = 0.5,
    pad_k_w_mk: f64 = 6,
};

/// Canonical creator tags persisted on saved tracks and vias.
pub const route_source_human = "human";
pub const route_source_agent = "agent";
pub const route_source_autorouter = "autorouter";
pub const route_source_imported = "imported";

/// One persisted routed-copper segment of a saved layout.
pub const SavedTrack = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    xm: ?f64 = null,
    ym: ?f64 = null,
    l: u8 = 0,
    w: f64,
    net: []const u8 = "",
    g: []const u8 = "",
    source: []const u8 = "",
    id: []const u8 = "",
};

/// One persisted via of a saved layout.
pub const SavedVia = struct {
    x: f64,
    y: f64,
    d: f64,
    drill: f64 = 0,
    net: []const u8 = "",
    g: []const u8 = "",
    f: []const u8 = "",
    source: []const u8 = "",
    s: ?[2]u8 = null,
    id: []const u8 = "",
};

/// Persisted custom/KiCad copper-zone geometry.
pub const SavedZone = saved_zone.SavedZone;

/// One RF path's persisted swept-region evidence.
pub const SavedRfPath = struct {
    net: []const u8,
    layer: u8,
    samples: []const rf_path_solver.Sample,
    track_ids: []const []const u8 = &.{},
    portal: bool = false,
};

/// A saved layout's persisted copper.
pub const SavedRoutes = struct {
    tracks: []const SavedTrack,
    vias: []const SavedVia,
    zones: []const SavedZone = &.{},
    rf_paths: []const SavedRfPath = &.{},
};

/// A user-drawn board outline captured with a saved layout.
pub const SavedOutline = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    pts: ?[]const [2]f64 = null,
    radii: ?[]const f64 = null,
    derived: struct {
        poly: ?[]const [2]f64 = null,
        arcs: []const optimizer.BoardArc = &.{},
    } = .{},
    sketch: ?shape_sketch.Sketch = null,
};

/// Per-layout editable positive polygons for one authored backing layer.
pub const SavedFabricationLayer = struct {
    name: []const u8,
    regions: []const []const [2]f64,
    sketches: []const ?shape_sketch.Sketch = &.{},
};

/// A named saved layout and all persisted physical authoring attached to it.
pub const SavedLayout = struct {
    name: []const u8,
    kind: []const u8,
    ts: i64,
    score: ?LayoutScore,
    parts: []const PartPose,
    default: bool = false,
    rough: bool = false,
    routes: ?SavedRoutes = null,
    outline: ?SavedOutline = null,
    fabrication_layers: []const SavedFabricationLayer = &.{},
    heatsink: ?SavedHeatsink = null,
    texts: []const font5x7.BoardText = &.{},
    dimensions: []const SavedPartEdgeDimension = &.{},
};
