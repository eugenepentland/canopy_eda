//! Real copper-pour engine — a single COMPUTED fill shared by every consumer
//! (Gerber export, fab-readiness connectivity, the viewer), replacing the old
//! analytic "outline pullback minus per-hole antipads" that each consumer
//! recomputed independently and that assumed connectivity it never verified.
//!
//! `compute` rasterizes one poured/plane layer at a fine pitch onto a SIGNED
//! MARGIN FIELD: each cell holds the true geometric distance from its centre to
//! the nearest keep-out boundary — the board outline inset by the copper-to-edge
//! clearance (respecting a non-rectangular `board_poly`), and every FOREIGN
//! copper feature (a pad, track, or via whose net the plane does NOT carry)
//! grown by the pour clearance. Each stamp lowers the field by `min()` with the
//! feature's exact signed margin over a window that reaches a few cells past the
//! clearance boundary, so the composite field is accurate on BOTH sides of that
//! boundary. Cells whose margin clears `iso_guard` are fillable; connected-
//! component labelling keeps ONLY components that contain a same-net SEED (a
//! same-net pad or via landing on that layer). The result answers two questions
//! honestly:
//!
//!   * membership — `componentAt(x,y)` / `planeConnect` say which kept
//!     component (if any) a point/pad lands in, so a pad isolated by its
//!     antipad ring, a plane split by a foreign trace, or an orphan island are
//!     all VISIBLE (the fab-readiness short-circuit is gone), and
//!   * shape — `Fill.contours` are the kept components' outer boundary polygons,
//!     traced as the width-filtered `iso_guard` iso-line of the margin field with sub-cell
//!     linear interpolation (dual marching squares), so the emitted copper
//!     follows a smooth clearance offset instead of a grid staircase, never dips
//!     under the true clearance, and the Gerber emits real copper / the viewer
//!     paints the true extent (islands dropped).
//!
//! The engine is a pure function of `(placement, copper, layer)` — no server,
//! no disk — so it is unit-testable and shares the export's frame/net model.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const pad_shape = @import("pad_shape.zig");
const implicit_plane = @import("implicit_plane.zig");
const router = @import("router.zig");
const outline = @import("outline.zig");
const via_antipad = @import("via_antipad.zig");
const impedance = @import("impedance.zig");
const rf_port_report = @import("rf_port_report.zig");
const variable_width_copper = @import("variable_width_copper.zig");
const path_copper = @import("path_copper.zig");
const numeric = @import("../numeric.zig");

/// Which net a poured/plane layer carries: a declared `(plane IDX "NET")` name,
/// or the legacy implicit model's "every ground-named net".
pub const PlaneNet = union(enum) { named: []const u8, ground };

/// Identity of one poured copper layer for the fill. `side` non-null marks an
/// OUTER copper face (its side's SMD pads are present, and foreign tracks on
/// `track_layer` are carved); null marks an INNER plane (only drilled barrels
/// and vias interact — SMD pads and signal tracks live on other layers).
pub const LayerSpec = struct {
    net: PlaneNet,
    /// Physical 1-based copper stack position when this spec comes from a
    /// declared plane/pour. Zero for an ad-hoc user zone or legacy caller.
    /// Geometry does not read it; audits use it to pair an exact fill with the
    /// signal layer that references that physical plane.
    stack: u8 = 0,
    side: ?optimizer.Side = null,
    track_layer: ?u8 = null,
    /// A user-drawn clip polygon (world mm) for a hand-authored pour: the fill
    /// is additionally confined to this region — the margin field becomes
    /// `min(board-outline inset, clip-polygon inset)` — so the copper never
    /// spills past the drawn boundary. Empty (`<3` pts) = a full-face declared
    /// pour (no extra clip).
    clip: []const [2]f64 = &.{},
    /// Keep ALL kept-candidate components when the fill has NO same-net seed —
    /// so a freshly drawn user pour with no same-net copper inside still
    /// renders (islands reported honestly). Declared pours leave this false, so
    /// their orphan-island drop (see `markSeeds`) is unchanged.
    keep_unseeded: bool = false,
    /// Boundary polygons (world mm) of the HIGHER-priority overlapping pours on
    /// this same layer that carry a DIFFERENT net — the copper this (lower-
    /// priority) fill must clear so it leaves a gap instead of shorting to a
    /// higher-ranked neighbour (KiCad's zone-priority resolution). Each is
    /// stamped as foreign copper grown by the pour clearance (`stampHigher`).
    /// Empty for declared pours and for the top-priority pour on a layer.
    higher: []const []const [2]f64 = &.{},
};

/// A user-drawn copper pour reduced to what CONNECTIVITY credit and the Gerber
/// writer need: the net NAME (stable identity, matching the flattened net), the
/// routable signal-layer index (0 = top / F.Cu, 1 = bottom / B.Cu, ≥2 = a
/// plane-free INNER signal layer — `BoardRules.signalIndexOfName` resolves the
/// KiCad name to it), and the boundary polygon. Connectivity membership is a
/// cheap point-in-polygon test (no fill raster) — an outer zone unites its
/// face's SMD pads plus through-hole pads/vias, an inner zone only the
/// through-hole pads/vias that reach it — so this rides the hot fab / net-open
/// path safely.
pub const UserZone = struct {
    net: []const u8,
    layer: u8,
    poly: []const [2]f64,
    /// Zone-fill priority (KiCad's `(priority N)`): on one layer, a pour outranks
    /// a DIFFERENT-net pour it overlaps when its priority is strictly greater —
    /// the higher pour fills the overlap and the lower one recedes by the pour
    /// clearance. Default 0; equal-priority overlaps are left untouched (they
    /// short, exactly as before priority existed — resolve them by ranking).
    priority: i64 = 0,
};

/// Does higher-priority pour `hi` outrank lower pour `lo` for overlap
/// resolution — same routable layer, strictly greater priority, and a
/// DIFFERENT net (same-net pours merge, never clip each other)? The single
/// predicate `higherPolys` applies for every consumer (viewer refill, Gerber,
/// PNG), so the gap the viewer shows is exactly the gap the fab cuts.
fn outranks(hi: UserZone, lo: UserZone) bool {
    return hi.layer == lo.layer and hi.priority > lo.priority and !sameZoneNet(hi.net, lo.net);
}

/// Two zone net names refer to the same net (exact or `/`-leaf match, case-
/// insensitive) — so a sub-block-flattened rail (`pwr/VOUT`) and its parent
/// spelling never clip each other.
fn sameZoneNet(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b) or std.ascii.eqlIgnoreCase(leafName(a), leafName(b));
}

/// The boundary polygons of every pour that OUTRANKS `zones[i]` (see
/// `outranks`) — the higher-priority different-net copper `zones[i]`'s fill must
/// clear. Arena-owned; empty when `zones[i]` is the top rank on its layer. Fed
/// into `LayerSpec.higher` so `compute` knocks the lower fill back.
pub fn higherPolys(arena: std.mem.Allocator, zones: []const UserZone, i: usize) std.mem.Allocator.Error![]const []const [2]f64 {
    var out: std.ArrayList([]const [2]f64) = .empty;
    for (zones, 0..) |z, j| {
        if (j == i) continue;
        if (outranks(z, zones[i])) try out.append(arena, z.poly);
    }
    return out.items;
}

/// Boundary polygons of the user pours that OUTRANK a DECLARED pour/plane —
/// the `(pour top|bottom "NET")` / `(plane IDX "NET")` background copper on
/// signal layer `layer` carrying `net`. A declared pour is the board's blanket
/// background fill and always ranks BELOW a hand-drawn/imported user pour: a
/// user zone is a deliberate region, so it wins the overlap whatever its
/// `priority` (which only orders user pours against each other) and the
/// declared copper recedes by the pour clearance around it. Without this a
/// `(pour bottom "GND")` pours straight through a rail zone on the same face and
/// shorts to it. Same-net zones are skipped — that copper simply merges.
pub fn higherThanDeclared(
    arena: std.mem.Allocator,
    zones: []const UserZone,
    layer: u8,
    net: PlaneNet,
) std.mem.Allocator.Error![]const []const [2]f64 {
    var out: std.ArrayList([]const [2]f64) = .empty;
    for (zones) |z| {
        if (z.layer != layer) continue;
        if (planeCarries(net, z.net)) continue; // same net → the two copper areas merge
        try out.append(arena, z.poly);
    }
    return out.items;
}

/// Does world point (x,y) fall inside a pour that OUTRANKS `zones[i]` — a higher-
/// priority, different-net pour on the same layer? Then `zones[i]`'s fill was
/// knocked back there (the higher pour owns the overlap), so its copper does not
/// reach the point. Connectivity uses this to mirror the priority gap on the
/// coarse point-in-polygon membership path (see `LayerSpec.higher`): a pad in a
/// clipped-away region must not be credited to the lower pour.
pub fn clippedByHigher(zones: []const UserZone, i: usize, x: f64, y: f64) bool {
    for (zones, 0..) |z, j| {
        if (j == i) continue;
        if (outranks(z, zones[i]) and outline.contains(z.poly, x, y)) return true;
    }
    return false;
}

/// The copper FACE a signal-layer index sits on, or null for an inner layer:
/// 0 → top (F.Cu), 1 → bottom (B.Cu), ≥2 → null (a plane-free inner signal
/// layer has no outer face — its pour interacts only with drilled barrels and
/// same-layer inner tracks). The `?Side` a `LayerSpec`/`ZoneFillReq` wants.
pub fn sideOfSignal(layer: u8) ?optimizer.Side {
    return switch (layer) {
        0 => .top,
        1 => .bottom,
        else => null,
    };
}

/// The `LayerSpec` for a hand-drawn user pour on any routable signal layer:
/// `side` is the outer face (null for an inner layer), `track_layer` the signal
/// index whose same-layer tracks the fill carves as foreign copper, plus the
/// drawn `clip` polygon and the keep-when-unseeded fallback (a user pour is
/// intentional copper, not an orphan island to drop). An inner pour therefore
/// stamps only drilled barrels/vias + its own inner tracks (`compute`'s
/// `side == null` path), never SMD pads — matching what physically touches an
/// inner copper layer.
pub fn zoneLayerSpec(net_name: []const u8, side: ?optimizer.Side, track_layer: u8, clip: []const [2]f64) LayerSpec {
    return .{
        .net = .{ .named = net_name },
        .side = side,
        .track_layer = track_layer,
        .clip = clip,
        .keep_unseeded = true,
    };
}

/// The `LayerSpec` for a hand-drawn OUTER-face user pour — the `zoneLayerSpec`
/// specialisation for the two outer faces (top → track layer 0, bottom → 1),
/// kept as the outer-only entry point the Gerber/PNG paths call directly.
pub fn userZoneSpec(net_name: []const u8, side: optimizer.Side, clip: []const [2]f64) LayerSpec {
    return zoneLayerSpec(net_name, side, if (side == .top) 0 else 1, clip);
}

/// The `LayerSpec` for a declared OUTER-face pour on `side`. Owns the
/// routed-copper layer convention (the top face carries track layer 0, the
/// bottom 1 — the router's outer-layer numbering), so pour consumers never
/// restate it; `carryingLayers` applies the same mapping for connectivity.
pub fn outerSpec(net_name: []const u8, side: optimizer.Side) LayerSpec {
    return .{
        .net = .{ .named = net_name },
        .side = side,
        .track_layer = if (side == .top) 0 else 1,
    };
}

/// One kept component's outer boundary, a closed polygon in world mm.
const Contour = []const [2]f64;

/// Upper bound on grid cells before `compute` coarsens the pitch (and flags
/// `coarsened`). A 100×100 mm board at the 0.15 mm default pitch is ~445 k
/// cells; the cap leaves generous headroom while bounding a pathological board.
const max_cells: usize = 3_000_000;

const blocked_marker: i32 = -2;
const fringe_marker: i32 = -3;
const unlabeled: i32 = -1;

/// The traced contour follows the margin field's guard iso-line, i.e. it sits
/// at clearance + guard mm from foreign copper (and the edge inset). Minimum
/// width is enforced separately by `openMinimumWidth`: erode to a half-width
/// core, then regrow surviving components to this original boundary. The guard
/// band absorbs, so the emitted polygon NEVER dips under the true clearance:
/// (a) linear-interpolation error on a curved field (~pitch²/(8R) ≈ 0.009 mm
/// at R = 0.3 mm, default pitch), (b) the Douglas-Peucker chord deviation
/// (`dp_tol`), and (c) float noise. 0.03 is the floor at the default pitch;
/// `isoGuardFor` grows it when the cell cap coarsens the pitch (interpolation
/// error is quadratic in pitch, so a fixed guard would under-protect there).
const iso_guard: f64 = 0.03;

/// The guard band for a fill at `pitch`: the 0.03 floor, or — once coarsening
/// grows the pitch — the pitch-scaled interpolation sagitta pitch²/(8·r_min)
/// plus `dp_tol`. `r_min` is the tightest iso-line curvature radius the design
/// can produce: copper reaches floor at `pour_clearance` (per-net clearances
/// only grow them), while a reflex board vertex curves at the edge inset
/// (`pourEdge`, which a small `copper_edge` can shrink) — so the caller passes
/// min of the two, floored at 0.1. At the default 0.15 mm pitch the formula
/// stays under the floor, so uncoarsened fills keep the calibrated 0.03
/// exactly.
fn isoGuardFor(pitch: f64, r_min: f64) f64 {
    return @max(iso_guard, pitch * pitch / (8 * r_min) + dp_tol);
}

/// Douglas-Peucker tolerance (mm): kept below `iso_guard` so simplification can
/// never push a chord under the true clearance, yet small enough that a curved
/// wall stays smooth (chord sagitta 0.01 at R = 0.5 mm → ~0.28 mm segments).
const dp_tol: f64 = 0.01;

/// Extra halo (in cells) each feature stamp writes PAST its clearance reach, so
/// the margin field carries accurate values a few cells beyond the iso-line —
/// enough for the sub-cell interpolation to read a true gradient on the fillable
/// side. Beyond the halo other features' own stamps govern; `min()` composes.
const window_cells: f64 = 2.5;

/// The raster frame a fill's `labels` grid is indexed in: world origin, cell
/// pitch, and cell counts — one value shared by every world↔cell conversion.
const Frame = struct { minx: f64, miny: f64, pitch: f64, nx: usize, ny: usize };

/// The computed fill for one layer: the label grid (for point/pad membership)
/// plus the kept components' outer contours and their interior holes (for
/// emission / painting).
pub const Fill = struct {
    /// False when contour tracing found geometry that could not be represented
    /// as valid simple Gerber regions. Keep this distinct from a legitimate
    /// empty pour so DRC and fabrication export fail closed.
    integrity_ok: bool = true,
    /// The raster frame `labels` is indexed in.
    frame: Frame,
    /// Per cell: a kept-component index (0..n_comp) or -1 (blocked / unseeded).
    labels: []const i32,
    n_comp: usize,
    contours: []const Contour,
    /// Interior hole loops, PARALLEL to `contours`: `holes[i]` are the loops
    /// fully enclosed by `contours[i]` — an antipad ring around a foreign
    /// via/pad inside the pour, or the slot around an interior foreign track —
    /// each already simplified (empty slice when the contour has none). The
    /// solid is `contours[i]` minus these clear masks. Sibling holes may meet
    /// only at zero-area point tangencies: Gerber's ordered clear polarity and
    /// the viewers' even-odd fill then agree. Positive-area overlap, nesting,
    /// crossing, and shared-edge overlap are rejected fail-closed.
    holes: []const []const Contour,
    /// The pitch was coarsened to stay under `MAX_CELLS` — a surfaced warning
    /// (the fill is lower-resolution than the design's clearance would want).
    coarsened: bool,

    /// The kept-component index covering world point (x,y), or -1 when the
    /// point is blocked, in an unseeded region, or off the grid.
    pub fn componentAt(self: Fill, x: f64, y: f64) i32 {
        const f = self.frame;
        if (f.pitch <= 0) return -1;
        const fi = @floor((x - f.minx) / f.pitch);
        const fj = @floor((y - f.miny) / f.pitch);
        if (fi < 0 or fj < 0) return -1;
        const i: usize = numeric.checkedInt(usize, fi) orelse return -1;
        const j: usize = numeric.checkedInt(usize, fj) orelse return -1;
        if (i >= f.nx or j >= f.ny) return -1;
        return self.labels[j * f.nx + i];
    }

    /// Whether the computed, kept pour contains world point (x,y). Fab
    /// readiness uses this so filtered user-pour necks are not credited as
    /// connected copper when Gerber has removed them.
    pub fn contains(self: Fill, x: f64, y: f64) bool {
        return self.componentAt(x, y) >= 0;
    }

    /// Representative points where a segment crosses each kept component.
    /// One point per component is enough for electrical graph consumers to
    /// join a routed conductor to the equipotential copper region without
    /// expanding the whole fill raster into circuit nodes.
    pub fn segmentContacts(
        self: Fill,
        arena: std.mem.Allocator,
        x1: f64,
        y1: f64,
        x2: f64,
        y2: f64,
    ) std.mem.Allocator.Error![]const ComponentContact {
        var out: std.ArrayList(ComponentContact) = .empty;
        if (!(self.frame.pitch > 0)) return out.toOwnedSlice(arena);
        const length = std.math.hypot(x2 - x1, y2 - y1);
        const steps = @max(@as(usize, 1), numeric.checkedInt(usize, @ceil(length / (self.frame.pitch / 2))) orelse 1);
        for (0..steps + 1) |i| {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const at = [2]f64{ x1 + (x2 - x1) * t, y1 + (y2 - y1) * t };
            const component = self.componentAt(at[0], at[1]);
            if (component < 0) continue;
            var seen = false;
            for (out.items) |old| if (old.component == component) {
                seen = true;
                break;
            };
            if (!seen) try out.append(arena, .{ .component = component, .at = at });
        }
        return out.toOwnedSlice(arena);
    }

    /// The kept component a pad lands in: its centre, else any sampled point of
    /// its bounding box (a pad whose centre grazes the edge keep-out can still
    /// have copper reaching the pour). -1 when it touches no kept component.
    fn padComponent(self: Fill, cx: f64, cy: f64, x0: f64, y0: f64, x1: f64, y1: f64) i32 {
        const c = self.componentAt(cx, cy);
        if (c >= 0) return c;
        const xs = [_]f64{ x0, x1, cx };
        const ys = [_]f64{ y0, y1, cy };
        for (xs) |sx| for (ys) |sy| {
            const s = self.componentAt(sx, sy);
            if (s >= 0) return s;
        };
        return -1;
    }
};

/// One computed fill-component index and a representative world-space point
/// at which routed copper touches it.
pub const ComponentContact = struct {
    component: i32,
    at: [2]f64,
};

/// Every kept fill component crossed by a line segment. Sampling at half the
/// fill pitch guarantees a segment cannot step across a labelled raster cell
/// without observing it; callers use this for tracks whose endpoints both sit
/// outside a pour but whose centreline passes through fabricated copper.
pub fn segmentComponents(
    arena: std.mem.Allocator,
    fill: Fill,
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
) std.mem.Allocator.Error![]const i32 {
    var out: std.ArrayList(i32) = .empty;
    if (!(fill.frame.pitch > 0)) return out.toOwnedSlice(arena);
    const length = std.math.hypot(x2 - x1, y2 - y1);
    const steps = @max(@as(usize, 1), numeric.checkedInt(usize, @ceil(length / (fill.frame.pitch / 2))) orelse 1);
    for (0..steps + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const component = fill.componentAt(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t);
        if (component < 0) continue;
        var seen = false;
        for (out.items) |old| if (old == component) {
            seen = true;
            break;
        };
        if (!seen) try out.append(arena, component);
    }
    return out.toOwnedSlice(arena);
}

// spec: placement/pour - a track crossing a fill is assigned to every fabricated component it traverses even when both endpoints lie outside
test "segment components sees fill between two outside endpoints" {
    const labels = [_]i32{ -1, 0, -1 };
    const fill = Fill{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 3, .ny = 1 },
        .labels = &labels,
        .n_comp = 1,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
    const found = try segmentComponents(std.testing.allocator, fill, -0.5, 0.5, 3.5, 0.5);
    defer std.testing.allocator.free(found);
    try std.testing.expectEqualSlices(i32, &.{0}, found);
}

/// A pad reduced to what membership needs: its world box + copper anchor and,
/// for custom pads, the authored world-space copper outline. `poly` is empty
/// when the box is exact. Through-hole pads are present on every copper layer;
/// SMD pads only on their own side.
pub const PadQuery = struct {
    cx: f64,
    cy: f64,
    shape: pad_shape.Shape,
    thru: bool,
    side: optimizer.Side,
};

/// The plane-connectivity answer for one net across all the layers that pour
/// it: each query pad/via's CANONICAL kept-component id (or -1 = isolated),
/// with ids unified across layers by through-hole pads and vias (so a net
/// poured on both an inner plane and an outer face reads as one piece).
pub const Join = struct {
    pad_comp: []const i32,
    via_comp: []const i32,
    n_comp: usize,
    coarsened: bool,
};

/// Does a plane carrying `net` carry the feature-net `name`? Named planes match
/// the full flattened name or its `/`-leaf; the implicit model carries every
/// ground-named net. Unconnected ("") is never carried.
fn planeCarries(net: PlaneNet, name: []const u8) bool {
    if (name.len == 0) return false;
    if (net == .ground) return optimizer.isGroundName(leafName(name));
    return std.ascii.eqlIgnoreCase(net.named, name) or std.ascii.eqlIgnoreCase(net.named, leafName(name));
}

/// The net name's leaf after the last `/` (sub-block flatten prefix).
fn leafName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// The outline rectangle the fill rasterizes over: the authored/drawn
/// `board_rect`, else the parts' bounding box (matching `export_fab.outlineRect`
/// so the pour aligns with the edge layer). Replicated here to avoid an import
/// cycle through `export_fab`/`export_gerber`.
fn boundsRect(placement: optimizer.Placement) optimizer.BoardRect {
    if (placement.board_rect) |r| return r;
    return .{
        .minx = placement.minx - 1.0,
        .miny = placement.miny - 1.0,
        .w = (placement.maxx - placement.minx) + 2.0,
        .h = (placement.maxy - placement.miny) + 2.0,
    };
}

// ── Fill computation ─────────────────────────────────────────────────────────

/// The fill lattice for a placement: the board rect plus the cell pitch (half
/// the smallest pour/CPWG clearance, coarsened until the raster fits `max_cells`) and its
/// extent. Derived from the placement ALONE — no layer, no net, no copper — so
/// every fill of one board shares it, which is what lets `planeConnect` reuse a
/// single edge-margin field across the layers that carry its net.
const Lattice = struct { r: optimizer.BoardRect, pitch: f64, nx: usize, ny: usize, coarsened: bool };

fn lattice(placement: optimizer.Placement) Lattice {
    const r = boundsRect(placement);
    var pitch = @max(0.05, smallestPourGap(placement) / 2.0);
    var coarsened = false;
    var nx = gridCount(r.w, pitch);
    var ny = gridCount(r.h, pitch);
    while (nx * ny > max_cells) {
        pitch *= 1.5;
        nx = gridCount(r.w, pitch);
        ny = gridCount(r.h, pitch);
        coarsened = true;
    }
    return .{ .r = r, .pitch = pitch, .nx = nx, .ny = ny, .coarsened = coarsened };
}

/// The BASE isolation gap one fill holds off foreign copper, by layer class:
/// an INNER plane (`spec.side == null`) takes the fab-safe `pour_clearance`,
/// an OUTER copper face the tighter `pour.clearance_outer` — an outer pour is
/// photo-defined against finished copper as a trace is, rather than etched
/// blind between two foils. One helper because every consumer of the number
/// must agree: the margin stamps, the priority knock-back and the shared
/// raster pitch all read the gap through here, so a fill can never be traced
/// at a gap the lattice cannot represent. A per-net class clearance (a CPWG
/// `(ground-gap …)`, a solved impedance antipad) still overrides this per
/// feature — this is only the floor it starts from.
fn baseGapFor(design: optimizer.DesignRules, spec: LayerSpec) f64 {
    return if (spec.side == null) design.pour_clearance else design.pour.clearance_outer;
}

/// The tightest declared ground-pour opening controls the shared raster pitch.
/// Without this, a 0.127 mm CPWG slot would be sampled on the legacy 0.15 mm
/// lattice and could not be represented consistently on the two outer faces.
/// The two layer-class defaults enter the same way: the lattice is shared by
/// every fill of one board (that is what lets `planeConnect` copy one edge
/// field across layers), so it must be pitched for the TIGHTER of them, or an
/// outer face's 0.2 mm gap would be sampled on a lattice cut for the inner
/// plane's 0.3. An authored `(design-rules (pour-clearance …))` sets both, so
/// a board that states its own gap keeps exactly the pitch it always had.
fn smallestPourGap(placement: optimizer.Placement) f64 {
    var gap = @min(placement.rules.design.pour_clearance, placement.rules.design.pour.clearance_outer);
    for (placement.rules.net) |r| {
        if (r.rf.impedance.ground_gap_mm > 0) gap = @min(gap, r.rf.impedance.ground_gap_mm);
    }
    return gap;
}

/// The board-edge margin field: every cell centre's signed inset into the board
/// outline, before any clip polygon or foreign-copper stamp lowers it. It is a
/// function of the outline, the edge inset, and the lattice — all layer-blind —
/// so a `planeConnect` filling the three layers that carry one net (an inner
/// declared plane plus a top and a bottom pour, barracuda's stackup) walks the
/// outline polygon per cell ONCE and copies the field into each layer's grid.
/// Recomputing it per layer cost 16 ms of barracuda's 150 ms DRC.
///
/// Public because the same argument holds ACROSS callers, not just across the
/// layers of one `planeConnect`: a page render pours the identical board a
/// couple of dozen times (the Gerber package, the viewer's pour JSON, the
/// filled-DRC zones, the connectivity zones), and each of those callers seeds
/// this field once via `sharedEdgeField` and threads it into `computeShared`.
pub const EdgeField = struct {
    nx: usize,
    ny: usize,
    pitch: f64,
    margin: []const f32,

    /// Does this field describe the lattice `computeFill` just derived? The
    /// lattice is a pure function of the placement, so a mismatch means the
    /// caller paired a field with a different board — fall back to computing it
    /// rather than reading a stale raster.
    fn fits(self: EdgeField, lat: Lattice) bool {
        return self.nx == lat.nx and self.ny == lat.ny and self.pitch == lat.pitch;
    }
};

/// Shared board-edge field supplied by callers that pour several surfaces.
/// Every fill traces its final boundary so conservative topology repairs can
/// clear affected raster cells; sampling-only callers omit that traced shape
/// from the returned Fill after its labels have been corrected.
const FillOpts = struct {
    base: ?EdgeField = null,
    contours: bool = true,
};

/// The layer-invariant edge-margin field for `placement`, or null when the
/// board has no fillable lattice (the degenerate cases `compute` answers with
/// an empty fill).
fn edgeField(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error!?EdgeField {
    const lat = lattice(placement);
    if (lat.nx < 1 or lat.ny < 1) return null;
    const margin = try arena.alloc(f32, lat.nx * lat.ny);
    const grid = Grid{ .minx = lat.r.minx, .miny = lat.r.miny, .pitch = lat.pitch, .nx = lat.nx, .ny = lat.ny, .labels = &.{}, .margin = margin, .iso = 0 };
    initMargin(grid, placement, lat.r, placement.rules.design.pourEdge());
    return .{ .nx = lat.nx, .ny = lat.ny, .pitch = lat.pitch, .margin = margin };
}

/// The board-edge margin field every fill over `placement` starts from, for a
/// caller that computes SEVERAL fills of one board and wants the outline walk
/// done once instead of once per fill. Pair it with `computeShared`. Null means
/// the board has no fillable lattice, which `computeShared` answers exactly as
/// `compute` does — with the empty fill.
pub fn sharedEdgeField(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error!?EdgeField {
    return edgeField(arena, placement);
}

/// `compute` seeded from a caller-shared edge field (`sharedEdgeField`), and
/// otherwise identical to it in every respect. The field is a pure function of
/// the placement, each fill gets its own mutable copy, and a field built for a
/// DIFFERENT board is rejected by `EdgeField.fits` and re-seeded rather than
/// read stale — so passing null, or a foreign field, is exactly `compute`.
pub fn computeShared(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    spec: LayerSpec,
    base: ?EdgeField,
) std.mem.Allocator.Error!Fill {
    return computeFill(arena, placement, copper, spec, .{ .base = base });
}

/// Membership-only computed fill seeded from a caller-shared edge field. PDN,
/// connectivity, and other analysis consumers retain conservatively corrected
/// labels but omit the traced render contours from the returned Fill.
pub fn computeMaskShared(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    spec: LayerSpec,
    base: ?EdgeField,
) std.mem.Allocator.Error!Fill {
    return computeFill(arena, placement, copper, spec, .{ .base = base, .contours = false });
}

/// Compute the poured fill for `spec` over `placement` + `copper`. All output
/// is arena-owned. An empty/degenerate outline yields an empty fill.
pub fn compute(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    spec: LayerSpec,
) std.mem.Allocator.Error!Fill {
    return computeFill(arena, placement, copper, spec, .{});
}

/// Fills for several specs over the same board when the caller only samples
/// membership. The board-edge field is built once; tracing still corrects any
/// topology-repair cells, then the public contours are omitted.
pub fn computeMasks(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    specs: []const LayerSpec,
) std.mem.Allocator.Error![]Fill {
    const base = try edgeField(arena, placement);
    const fills = try arena.alloc(Fill, specs.len);
    for (specs, 0..) |spec, i| {
        fills[i] = try computeFill(arena, placement, copper, spec, .{ .base = base, .contours = false });
    }
    return fills;
}

fn computeFill(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    spec: LayerSpec,
    opts: FillOpts,
) std.mem.Allocator.Error!Fill {
    const lat = lattice(placement);
    const r = lat.r;
    const rules = placement.rules;
    const pc = baseGapFor(rules.design, spec);
    const inset = rules.design.pourEdge();
    const pitch = lat.pitch;
    const coarsened = lat.coarsened;
    const nx = lat.nx;
    const ny = lat.ny;
    if (nx < 1 or ny < 1) return emptyFill(r, pitch, coarsened);

    const labels = try arena.alloc(i32, nx * ny);
    const margin = try arena.alloc(f32, nx * ny);
    const r_min = @max(0.1, @min(smallestPourGap(placement), inset));
    const guard = isoGuardFor(pitch, r_min);
    const grid = Grid{
        .minx = r.minx,
        .miny = r.miny,
        .pitch = pitch,
        .nx = nx,
        .ny = ny,
        .labels = labels,
        .margin = margin,
        .iso = guard,
    };
    if (opts.base) |b| {
        if (b.fits(lat)) @memcpy(margin, b.margin) else initMargin(grid, placement, r, inset);
    } else initMargin(grid, placement, r, inset);
    // A user pour's drawn boundary further confines the fillable field: min the
    // board-edge margin with the signed inset into the clip polygon, so the
    // traced contour hugs the drawn outline (blocked cells being those the guard
    // band inside it) and copper never escapes past the user's line.
    if (spec.clip.len >= 3) clipMargin(grid, spec.clip);

    const nets = try padNets(arena, placement);
    try stampForeign(arena, grid, placement, copper, spec, nets);
    try stampFootprintKeepouts(arena, grid, placement, spec);
    // Knock this fill back from any higher-priority overlapping pour on the same
    // layer (different net), so it leaves a clearance gap instead of shorting to
    // the higher-ranked copper. No-op when `spec.higher` is empty (declared
    // pours, the top-ranked pour, or any board that sets no priorities).
    if (spec.higher.len > 0) stampHigher(grid, spec.higher, pc);
    const min_width = effectiveMinimumWidth(placement, spec);
    const k = if (min_width > 0)
        openMinimumWidth(arena, grid, min_width / 2.0) catch return emptyFill(r, pitch, coarsened)
    else blk: {
        thresholdLabels(grid);
        break :blk labelComponents(arena, grid) catch return emptyFill(r, pitch, coarsened);
    };
    const kept = try arena.alloc(bool, k);
    @memset(kept, false);
    markSeeds(grid, placement, copper, spec, nets, kept);
    // A hand-drawn pour with no same-net copper inside would otherwise drop
    // every component as an unseeded orphan and render nothing; keep them all so
    // the user's polygon fills (its islands are reported honestly, same as any
    // seeded pour). Declared plane pours never set this, so their island drop is
    // untouched.
    if (spec.keep_unseeded and !anyTrue(kept)) @memset(kept, true);

    const n_comp = try remapKept(arena, grid, kept);
    const traced = traceComponents(arena, grid, n_comp, @max(0, rules.design.pour.corner_radius)) catch |err| switch (err) {
        // A broken boundary must never reach a G36 Gerber region. Collapse
        // the whole fill, including its membership labels, so electrical
        // checks cannot credit copper that fabrication will not receive.
        error.InvalidBoundary => return invalidFill(r, pitch, coarsened),
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{
        .frame = .{ .minx = r.minx, .miny = r.miny, .pitch = pitch, .nx = nx, .ny = ny },
        .labels = labels,
        .n_comp = traced.n_comp,
        .contours = if (opts.contours) traced.contours else &.{},
        .holes = if (opts.contours) traced.holes else &.{},
        .coarsened = coarsened,
    };
}

/// Manufacturing floor raised by a named power rail's conservative
/// maximum-current neck. Ground / unknown-current pours keep the authored
/// board rule exactly.
fn effectiveMinimumWidth(placement: optimizer.Placement, spec: LayerSpec) f64 {
    const rules = placement.rules;
    const power_min = switch (spec.net) {
        .named => |name| rules.powerWidthForNet(name) orelse 0,
        .ground => 0,
    };
    return @max(@max(0, rules.design.pour.min_width), power_min);
}

/// The routed copper a layout persisted — mirrors `routed_copper.Copper` so the
/// pour carves/seeds the same tracks/vias the Gerber draws (kept a separate
/// type to avoid an import cycle: that bundle names `UserZone`, so it imports
/// this module and this module cannot import it back).
pub const Copper = struct {
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
    /// Stored native routed arcs. The persisted chord tracks are retained for
    /// editing, but the physical curved envelope is authoritative for carving.
    arcs: []const router.Arc = &.{},
    /// Successful sampled variable-width paths. Their exact swept polygons
    /// replace the compact editor handles in `tracks` when foreign copper is
    /// carved, so a pour follows a taper's finished sloped flanks.
    rf_paths: []const rf_port_report.Outcome = &.{},
    /// The board's hand-drawn/imported user copper pours. A DECLARED plane fill
    /// recedes around these (`higherThanDeclared`), so plane connectivity sees
    /// the same copper the Gerber emits. Defaults empty — callers that only
    /// carve routed copper are unaffected.
    zones: []const UserZone = &.{},
};

/// Grid geometry + the mutable label and margin buffers, threaded through the
/// raster steps. `margin[idx]` is the signed clearance margin at the cell centre
/// (mm, +inside the fillable region); `labels[idx]` is the thresholded/component
/// state derived from it; `iso` is this fill's clearance-preserving guard
/// threshold (`isoGuardFor`). Both
/// `margin` and `iso` are required — a Grid whose margin is not co-sized with
/// `labels` panics on the first field access, so construction sites must state
/// what they pass (the trace-only unit test passes an explicit empty slice).
/// Low-level signed-margin raster shared with trace free-space analysis. Pour
/// owns the implementation so its existing fill and the route experiment use
/// identical obstacle stamping and component semantics.
pub const Grid = struct {
    minx: f64,
    miny: f64,
    pitch: f64,
    nx: usize,
    ny: usize,
    labels: []i32,
    margin: []f32,
    iso: f64,

    fn cellCenter(g: Grid, i: usize, j: usize) [2]f64 {
        return .{ g.minx + (@as(f64, @floatFromInt(i)) + 0.5) * g.pitch, g.miny + (@as(f64, @floatFromInt(j)) + 0.5) * g.pitch };
    }
};

fn gridCount(extent: f64, pitch: f64) usize {
    if (extent <= 0 or pitch <= 0) return 0;
    return numeric.toCount(@ceil(extent / pitch));
}

fn emptyFill(r: optimizer.BoardRect, pitch: f64, coarsened: bool) Fill {
    return .{ .frame = .{ .minx = r.minx, .miny = r.miny, .pitch = pitch, .nx = 0, .ny = 0 }, .labels = &.{}, .n_comp = 0, .contours = &.{}, .holes = &.{}, .coarsened = coarsened };
}

fn invalidFill(r: optimizer.BoardRect, pitch: f64, coarsened: bool) Fill {
    var fill = emptyFill(r, pitch, coarsened);
    fill.integrity_ok = false;
    return fill;
}

/// Seed each cell's margin from the OUTLINE alone: how far the cell centre sits
/// inside the board edge-inset (positive = that much fillable slack, negative =
/// outside it). Honours a non-rectangular `board_poly`, else the plain
/// rectangle. NO cell-diagonal inflation — this is the true geometric margin the
/// foreign stamps then `min()` against.
pub fn initMargin(g: Grid, placement: optimizer.Placement, r: optimizer.BoardRect, inset: f64) void {
    var j: usize = 0;
    while (j < g.ny) : (j += 1) {
        // Cell-centre y is constant across the row (hoisted out of the i-loop);
        // the expression matches `cellCenter`, so the field is bit-identical.
        const cy = g.miny + (@as(f64, @floatFromInt(j)) + 0.5) * g.pitch;
        const row = j * g.nx;
        var i: usize = 0;
        // A polygon outline walks every edge per cell, which is the whole cost
        // of seeding a poly-outline board's field (8 ms of a barracuda DRC on a
        // 20-point rounded rectangle). Whole lanes of the row take that walk
        // together; the ragged tail falls back to the scalar form.
        if (placement.board_poly) |poly| {
            if (poly.len >= 3) {
                var lane: [lanes]f64 = undefined;
                while (i + lanes <= g.nx) : (i += lanes) {
                    polyInsetLanes(poly, cellXs(g, i), cy, &lane);
                    for (lane, 0..) |m, k| g.margin[row + i + k] = @floatCast(m - inset);
                }
            }
        }
        while (i < g.nx) : (i += 1) {
            const cx = g.minx + (@as(f64, @floatFromInt(i)) + 0.5) * g.pitch;
            const m = if (placement.board_poly) |poly|
                polySignedInset(poly, cx, cy) - inset
            else
                rectInset(r, inset, cx, cy);
            g.margin[row + i] = @floatCast(m);
        }
    }
}

/// Lanes per vector pass over a raster row — the target's natural f64 width
/// (4 on AVX2, 8 on AVX-512), falling back to a width that still compiles to
/// sensible scalar code where the target has no SIMD.
const lanes: usize = std.simd.suggestVectorLength(f64) orelse 4;
const Lanes = @Vector(lanes, f64);

/// The cell-centre x of `lanes` consecutive cells starting at `i`. Built one
/// lane at a time from the SAME expression the scalar loop uses, so a lane's
/// coordinate is the identical f64 — the vector path is a batching of the
/// scalar path, not an approximation of it.
fn cellXs(g: Grid, i: usize) Lanes {
    var v: Lanes = @splat(0);
    inline for (0..lanes) |k| v[k] = g.minx + (@as(f64, @floatFromInt(i + k)) + 0.5) * g.pitch;
    return v;
}

/// `polySignedInset` for `lanes` cell centres sharing one row's `y`, written
/// into `out`.
///
/// The scalar form's cost is the per-cell sweep over every polygon edge; each
/// edge contributes the same three scalars to every lane (its direction, its
/// length², and — since `y` is fixed across the row — its ray-cast crossing),
/// so a whole lane group sweeps the outline once. Every lane's arithmetic is
/// the elementwise twin of the scalar expression in the same association order,
/// and the single closing `hypot` stays scalar per lane, so a lane's result is
/// the value `polySignedInset` would have returned for that cell.
fn polyInsetLanes(poly: []const [2]f64, x: Lanes, y: f64, out: *[lanes]f64) void {
    const zero: Lanes = @splat(0);
    const one: Lanes = @splat(1);
    var inside: @Vector(lanes, u1) = @splat(0);
    var best2: Lanes = @splat(std.math.inf(f64));
    var bdx: Lanes = zero;
    var bdy: Lanes = zero;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        const q = poly[j];
        // Even-odd ray cast. The row's `y` is fixed, so an edge either crosses
        // it for every lane or for none, and the crossing's x is one scalar —
        // only the `x <` test is per-lane.
        if ((p[1] > y) != (q[1] > y)) {
            const t = (y - p[1]) / (q[1] - p[1]);
            const xc: Lanes = @splat(p[0] + t * (q[0] - p[0]));
            inside ^= @intFromBool(x < xc);
        }
        const ex = p[0] - q[0];
        const ey = p[1] - q[1];
        const len2 = ex * ex + ey * ey;
        var t: Lanes = zero;
        if (len2 > 0) {
            const along = (x - @as(Lanes, @splat(q[0]))) * @as(Lanes, @splat(ex)) +
                @as(Lanes, @splat((y - q[1]) * ey));
            t = @max(zero, @min(along / @as(Lanes, @splat(len2)), one));
        }
        const ddx = x - (@as(Lanes, @splat(q[0])) + t * @as(Lanes, @splat(ex)));
        const ddy = @as(Lanes, @splat(y)) - (@as(Lanes, @splat(q[1])) + t * @as(Lanes, @splat(ey)));
        const d2 = ddx * ddx + ddy * ddy;
        const closer = d2 < best2;
        best2 = @select(f64, closer, d2, best2);
        bdx = @select(f64, closer, ddx, bdx);
        bdy = @select(f64, closer, ddy, bdy);
        j = i;
    }
    inline for (out, 0..) |*o, k| {
        const d = std.math.hypot(bdx[k], bdy[k]);
        o.* = if (inside[k] == 1) d else -d;
    }
}

/// Signed inset of (x,y) into `poly` — bit-identical to `outline.signedInset`
/// (`±distToEdge`, sign from `outline.contains`) but computed with ONE @sqrt
/// instead of one per edge: `std.math.hypot` is monotonic in the squared
/// closest-point distance, so the min-distance edge is the argmin of the cheap
/// per-edge SQUARED distances and only that edge needs the root. The even-odd
/// ray cast folds into the same single edge pass. Localised here so the hot
/// `initMargin` loop avoids `distToEdge`'s per-edge hypot (the pour's dominant
/// cost on a poly-outline board); `outline.signedInset` itself is untouched, so
/// every other consumer is unaffected. A sub-triangle poly defers to the
/// original for exact edge-case parity.
fn polySignedInset(poly: []const [2]f64, x: f64, y: f64) f64 {
    if (poly.len < 3) return outline.signedInset(poly, x, y);
    var inside = false;
    var best2: f64 = std.math.inf(f64);
    var bdx: f64 = 0;
    var bdy: f64 = 0;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        const q = poly[j];
        // Even-odd ray cast — identical to `outline.contains`.
        if ((p[1] > y) != (q[1] > y)) {
            const t = (y - p[1]) / (q[1] - p[1]);
            if (x < p[0] + t * (q[0] - p[0])) inside = !inside;
        }
        // Squared distance to edge q→p — identical to `outline.segDist` up to
        // (but not including) its final hypot; keep the closest-point delta of
        // the running minimum so a single hypot recovers the exact `distToEdge`.
        const ex = p[0] - q[0];
        const ey = p[1] - q[1];
        const len2 = ex * ex + ey * ey;
        var t: f64 = 0;
        if (len2 > 0) t = std.math.clamp(((x - q[0]) * ex + (y - q[1]) * ey) / len2, 0, 1);
        const ddx = x - (q[0] + t * ex);
        const ddy = y - (q[1] + t * ey);
        const d2 = ddx * ddx + ddy * ddy;
        if (d2 < best2) {
            best2 = d2;
            bdx = ddx;
            bdy = ddy;
        }
        j = i;
    }
    const d = std.math.hypot(bdx, bdy);
    return if (inside) d else -d;
}

/// Confine the margin field to a user pour's drawn `clip` polygon: lower each
/// cell's margin to its signed inset into the clip (positive inside, negative
/// outside), so `min()` with the board-edge field leaves only cells that clear
/// the guard band inside BOTH the board edge and the drawn boundary fillable.
/// The clip edge is the user's own line (not a fab board edge), so no extra
/// edge clearance is subtracted here — the guard band alone insets the traced
/// contour a hair inside the polygon.
fn clipMargin(g: Grid, clip: []const [2]f64) void {
    if (clip.len < 3) return;
    // The drawn zone is usually a fraction of the board, and outside its
    // bounding box the walk can only ever answer "outside" — so bound the
    // polygon once and spend the per-edge walk on the cells that can still
    // change the answer. Cells beyond the box get their Chebyshev distance to
    // it, which stays at least `pad` below zero and so is blocked exactly as
    // the walk would have blocked it; the band of `pad` cells around the box is
    // walked exactly, so every contour the fill later interpolates sits on real
    // values.
    const box = polyBounds(clip);
    const pad = 4 * g.pitch;
    const x0 = box[0] - pad;
    const y0 = box[1] - pad;
    const x1 = box[2] + pad;
    const y1 = box[3] + pad;
    var j: usize = 0;
    while (j < g.ny) : (j += 1) {
        const cy = g.miny + (@as(f64, @floatFromInt(j)) + 0.5) * g.pitch;
        const row = j * g.nx;
        const dy = @max(@max(y0 - cy, cy - y1), 0);
        var i: usize = 0;
        if (dy == 0) {
            var lane: [lanes]f64 = undefined;
            while (i + lanes <= g.nx) : (i += lanes) {
                const xs = cellXs(g, i);
                const cxs: [lanes]f64 = xs;
                if (cxs[lanes - 1] < x0 or cxs[0] > x1) {
                    for (cxs, 0..) |cx, k| lowerMargin(g, row + i + k, -@max(x0 - cx, cx - x1));
                    continue;
                }
                polyInsetLanes(clip, xs, cy, &lane);
                for (lane, 0..) |m, k| lowerMargin(g, row + i + k, m);
            }
        }
        while (i < g.nx) : (i += 1) {
            const cx = g.minx + (@as(f64, @floatFromInt(i)) + 0.5) * g.pitch;
            const dx = @max(@max(x0 - cx, cx - x1), 0);
            const m = if (dx == 0 and dy == 0) polySignedInset(clip, cx, cy) else -@max(dx, dy);
            lowerMargin(g, row + i, m);
        }
    }
}

/// The `[minx, miny, maxx, maxy]` bounding box of a polygon ring.
fn polyBounds(poly: []const [2]f64) [4]f64 {
    var b: [4]f64 = .{ poly[0][0], poly[0][1], poly[0][0], poly[0][1] };
    for (poly[1..]) |p| {
        b[0] = @min(b[0], p[0]);
        b[1] = @min(b[1], p[1]);
        b[2] = @max(b[2], p[0]);
        b[3] = @max(b[3], p[1]);
    }
    return b;
}

/// True when any component in `kept` is marked — the "did the pour seed at all"
/// test that gates the user-pour keep-everything fallback.
fn anyTrue(kept: []const bool) bool {
    for (kept) |x| if (x) return true;
    return false;
}

/// Signed inset of (x,y) into rectangle `r` shrunk by `inset` on every side:
/// the min of the four side gaps, negative when the point is outside.
fn rectInset(r: optimizer.BoardRect, inset: f64, x: f64, y: f64) f64 {
    const left = x - (r.minx + inset);
    const right = (r.minx + r.w - inset) - x;
    const top = y - (r.miny + inset);
    const bottom = (r.miny + r.h - inset) - y;
    return @min(@min(left, right), @min(top, bottom));
}

/// Threshold the completed margin field into the label grid the component
/// labeller consumes: a cell is fillable (UNLABELED) iff its margin clears the
/// fill's guard threshold. Everything at or under that threshold is BLOCKED.
fn thresholdLabels(g: Grid) void {
    for (g.labels, g.margin) |*lbl, m| {
        lbl.* = if (@as(f64, m) <= g.iso) blocked_marker else unlabeled;
    }
}

/// Remove copper sections narrower than `2 * radius` without shrinking every
/// legal pour boundary. Cells farther than `radius` inside the ordinary guard
/// contour form the manufacturable cores. Each surviving core is regrown into
/// the ordinary fillable fringe by the same radius (a raster morphological
/// opening); a fringe claimed by two formerly disconnected cores remains
/// blocked so a short neck cannot reconnect during regrowth.
///
/// The returned component count already matches the non-negative labels left
/// in `g`; unlike the zero-width path, callers must not relabel them afterward.
fn openMinimumWidth(arena: std.mem.Allocator, g: Grid, radius: f64) std.mem.Allocator.Error!usize {
    if (!(radius > 0) or g.pitch <= 0) {
        thresholdLabels(g);
        return labelComponents(arena, g);
    }

    const core_iso = g.iso + radius;
    for (g.labels, g.margin) |*lbl, m| {
        const margin: f64 = m;
        lbl.* = if (margin <= g.iso)
            blocked_marker
        else if (margin <= core_iso)
            fringe_marker
        else
            unlabeled;
    }
    const n_core = try labelComponents(arena, g);
    if (n_core == 0) {
        @memset(g.labels, blocked_marker);
        return 0;
    }

    // Read only this immutable eroded snapshot while writing the regrown
    // labels; otherwise scan order would let newly-grown fringe grow again.
    const core = try arena.dupe(i32, g.labels);
    const cells: i64 = @intCast(numeric.toCount(@ceil(radius / g.pitch)));
    const reach2 = radius * radius + 1e-12;
    for (g.labels, 0..) |*lbl, idx| {
        if (lbl.* != fringe_marker) continue;
        const i: i64 = @intCast(idx % g.nx);
        const j: i64 = @intCast(idx / g.nx);
        var owner: i32 = -1;
        var conflict = false;
        var dy: i64 = -cells;
        while (dy <= cells and !conflict) : (dy += 1) {
            const y = j + dy;
            if (y < 0 or y >= @as(i64, @intCast(g.ny))) continue;
            var dx: i64 = -cells;
            while (dx <= cells) : (dx += 1) {
                if (@as(f64, @floatFromInt(dx * dx + dy * dy)) * g.pitch * g.pitch > reach2) continue;
                const x = i + dx;
                if (x < 0 or x >= @as(i64, @intCast(g.nx))) continue;
                const candidate = core[@as(usize, @intCast(y)) * g.nx + @as(usize, @intCast(x))];
                if (candidate < 0) continue;
                if (owner < 0) {
                    owner = candidate;
                } else if (owner != candidate) {
                    conflict = true;
                    break;
                }
            }
        }
        lbl.* = if (!conflict and owner >= 0) owner else blocked_marker;
    }
    return n_core;
}

/// margin[idx] = min(margin[idx], m); one place so the field's min() composition
/// (each stamp contributes its feature's margin, the smallest wins) is obvious.
fn lowerMargin(g: Grid, idx: usize, m: f64) void {
    const mf: f32 = @floatCast(m);
    if (mf < g.margin[idx]) g.margin[idx] = mf;
}

// ── Obstacle + seed stamping ────────────────────────────────────────────────

/// (ref-des NUL pad) → net name, so the pour can classify each pad foreign vs
/// carried. Arena-owned.
fn padNets(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error!std.StringHashMapUnmanaged([]const u8) {
    var map = std.StringHashMapUnmanaged([]const u8).empty;
    for (placement.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ pin.ref_des, pin.pin });
            try map.put(arena, key, net.name);
        }
    }
    return map;
}

fn netOfPad(nets: std.StringHashMapUnmanaged([]const u8), ref: []const u8, pad: []const u8) []const u8 {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ ref, pad }) catch return "";
    return nets.get(key) orelse "";
}

/// Is a pad present (has copper/hole) on `spec`'s layer? Outer layers see their
/// own side's SMD pads plus every through/NPTH pad; inner planes see only
/// drilled barrels.
fn padOnLayer(part: optimizer.Part, pad: geometry.Pad, spec: LayerSpec) bool {
    const drilled = pad.thru or pad.npth;
    if (spec.side) |s| return drilled or part.side == s;
    return drilled;
}

/// Lower the margin field around every FOREIGN copper feature on this layer (a
/// pad/track/via whose net the plane does not carry) by the feature's true
/// clearance margin. Same-net features are left fillable — they are the pour,
/// and seed it. `reach` is the clearance-based radius WITHOUT any cell inflation
/// (a disc/seg reach folds in the feature's own half-width); the stamps write
/// `distance − reach` so the field's zero contour is the true clearance line.
fn stampForeign(
    arena: std.mem.Allocator,
    g: Grid,
    placement: optimizer.Placement,
    copper: Copper,
    spec: LayerSpec,
    nets: std.StringHashMapUnmanaged([]const u8),
) std.mem.Allocator.Error!void {
    const inner = spec.side == null;
    const base = baseGapFor(placement.rules.design, spec);
    const active = foreignActiveBounds(g, spec.clip);
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (!padOnLayer(p, pad, spec)) continue;
            const net_name = netOfPad(nets, p.ref_des, pad.number);
            if (planeCarries(spec.net, net_name)) continue;
            const reach = classPourClearance(placement, net_name, spec.net, base);
            const c = optimizer.worldPadCenter(&p, pad.x, pad.y);
            if (inner) {
                if (pad.thru and !pad.npth)
                    stampPadWithin(g, active, p, pad, reach)
                else if (pad.drill > 0)
                    stampDiscWithin(g, active, c[0], c[1], pad.drill / 2 + reach);
            } else {
                stampPadWithin(g, active, p, pad, reach);
            }
        }
    }
    if (spec.track_layer) |tl| {
        const physical_arcs = try path_copper.filterArcs(arena, copper.rf_paths, copper.arcs);
        for (copper.tracks) |t| {
            if (t.layer != tl) continue;
            if (rfPathOwnsTrack(copper.rf_paths, t)) continue;
            if (nativeArcOwnsTrack(physical_arcs, t)) continue;
            if (planeCarries(spec.net, netName(placement, t.net))) continue;
            const reach = trackPourStampClearance(placement, t, spec.net, base, g.iso);
            stampSegWithin(g, active, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, t.width / 2 + reach);
        }
        for (physical_arcs) |arc| {
            if (arc.layer != tl) continue;
            if (planeCarries(spec.net, netName(placement, arc.net))) continue;
            const probe = router.Track{
                .x1 = arc.p1[0],
                .y1 = arc.p1[1],
                .x2 = arc.p2[0],
                .y2 = arc.p2[1],
                .layer = arc.layer,
                .width = arc.width,
                .net = arc.net,
            };
            const reach = trackPourStampClearance(placement, probe, spec.net, base, g.iso);
            stampArcWithin(g, active, arc, arc.width / 2 + reach);
        }
        for (copper.rf_paths) |path| {
            if (!path.success or path.physical.gate_removed) continue;
            if (path.physical.layer != tl or path.physical.samples.len < 2) continue;
            if (planeCarries(spec.net, netName(placement, path.net))) continue;
            for (try variable_width_copper.pieces(arena, path.physical.samples)) |piece| {
                const probe = router.Track{
                    .x1 = 0,
                    .y1 = 0,
                    .x2 = 0,
                    .y2 = 0,
                    .layer = path.physical.layer,
                    .width = piece.width_mm,
                    .net = path.net,
                };
                const reach = trackPourStampClearance(placement, probe, spec.net, base, g.iso);
                stampPolygonWithin(g, active, piece.poly, reach);
            }
        }
    }
    for (copper.vias) |v| {
        if (planeCarries(spec.net, netName(placement, v.net))) continue;
        const reach = viaPlaneClearance(placement, v, spec.net, base);
        stampDiscWithin(g, active, v.x, v.y, v.dia / 2 + reach);
    }
}

fn nativeArcOwnsTrack(arcs: []const router.Arc, track: router.Track) bool {
    const a = [2]f64{ track.x1, track.y1 };
    const b = [2]f64{ track.x2, track.y2 };
    for (arcs) |arc| {
        if (arc.layer != track.layer or arc.net != track.net or @abs(arc.width - track.width) > 0.0001) continue;
        if (outline.arcOwnsSegment(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }, a, b, 0.0001)) return true;
    }
    return false;
}

fn rfPathOwnsTrack(paths: []const rf_port_report.Outcome, track: router.Track) bool {
    for (paths) |path| {
        if (!path.success or path.physical.gate_removed) continue;
        if (path.net != track.net or path.physical.layer != track.layer) continue;
        if (variable_width_copper.ownsTrack(path.physical.samples, track)) return true;
    }
    return false;
}

/// The only clipped-fill cells whose obstacle margins can affect membership or
/// a traced boundary. `clipMargin` evaluates the polygon exactly through this
/// same four-cell halo; farther cells are already blocked by their distance to
/// the clip box and cannot neighbour kept copper. A full-face pour returns null
/// and retains the ordinary board-wide stamping path.
fn foreignActiveBounds(g: Grid, clip: []const [2]f64) ?[4]f64 {
    if (clip.len < 3) return null;
    var box = polyBounds(clip);
    const halo = 4 * g.pitch;
    box[0] -= halo;
    box[1] -= halo;
    box[2] += halo;
    box[3] += halo;
    return box;
}

/// Does a feature's COMPLETE stamp window overlap the portion of a clipped
/// fill that can survive? Bounds are inclusive so a just-touching clearance
/// window is retained; false is therefore a conservative, geometry-safe cull.
fn stampWindowActive(active: ?[4]f64, x0: f64, y0: f64, x1: f64, y1: f64) bool {
    const box = active orelse return true;
    return x1 >= box[0] and y1 >= box[1] and x0 <= box[2] and y0 <= box[3];
}

fn stampDiscWithin(g: Grid, active: ?[4]f64, cx: f64, cy: f64, rad: f64) void {
    const win = rad + window_cells * g.pitch;
    if (!stampWindowActive(active, cx - win, cy - win, cx + win, cy + win)) return;
    stampDisc(g, cx, cy, rad);
}

fn stampSegWithin(g: Grid, active: ?[4]f64, a: [2]f64, b: [2]f64, rad: f64) void {
    const win = rad + window_cells * g.pitch;
    if (!stampWindowActive(active, @min(a[0], b[0]) - win, @min(a[1], b[1]) - win, @max(a[0], b[0]) + win, @max(a[1], b[1]) + win)) return;
    stampSeg(g, a[0], a[1], b[0], b[1], rad);
}

fn arcAngleOnSweep(circle: outline.ArcCircle, angle: f64) bool {
    if (circle.sweep >= 0)
        return @mod(angle - circle.start_angle, std.math.tau) <= circle.sweep + 1e-12;
    return @mod(circle.start_angle - angle, std.math.tau) <= -circle.sweep + 1e-12;
}

fn routedArcCircle(arc: router.Arc) ?outline.ArcCircle {
    return outline.arcCircle(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 });
}

fn arcBounds(arc: router.Arc, circle: outline.ArcCircle) [4]f64 {
    var bounds = [4]f64{
        @min(arc.p1[0], arc.p2[0]),
        @min(arc.p1[1], arc.p2[1]),
        @max(arc.p1[0], arc.p2[0]),
        @max(arc.p1[1], arc.p2[1]),
    };
    const pi: f64 = std.math.pi;
    const cardinal = [_]f64{ 0, pi / 2.0, pi, 3.0 * pi / 2.0 };
    for (cardinal) |angle| {
        if (!arcAngleOnSweep(circle, angle)) continue;
        const point = [2]f64{ circle.cx + circle.radius * @cos(angle), circle.cy + circle.radius * @sin(angle) };
        bounds[0] = @min(bounds[0], point[0]);
        bounds[1] = @min(bounds[1], point[1]);
        bounds[2] = @max(bounds[2], point[0]);
        bounds[3] = @max(bounds[3], point[1]);
    }
    return bounds;
}

fn pointArcDistance(arc: router.Arc, circle: outline.ArcCircle, point: [2]f64) f64 {
    const dx = point[0] - circle.cx;
    const dy = point[1] - circle.cy;
    const radius_at_point = std.math.hypot(dx, dy);
    if (arcAngleOnSweep(circle, std.math.atan2(dy, dx))) return @abs(radius_at_point - circle.radius);
    return @min(
        std.math.hypot(point[0] - arc.p1[0], point[1] - arc.p1[1]),
        std.math.hypot(point[0] - arc.p2[0], point[1] - arc.p2[1]),
    );
}

/// Lower the margin by the exact directed circular-arc envelope. The stamp
/// uses the same recovered three-point circle/sweep as Gerber G02/G03 output;
/// an undefined arc follows the writer's p1→p2 straight fallback.
fn stampArcWithin(g: Grid, active: ?[4]f64, arc: router.Arc, rad: f64) void {
    if (!(rad > 0)) return;
    const circle = routedArcCircle(arc) orelse {
        stampSegWithin(g, active, arc.p1, arc.p2, rad);
        return;
    };
    const bounds = arcBounds(arc, circle);
    const win = rad + window_cells * g.pitch;
    if (!stampWindowActive(active, bounds[0] - win, bounds[1] - win, bounds[2] + win, bounds[3] + win)) return;
    const lo = cellRange(g, bounds[0] - win, bounds[1] - win);
    const hi = cellRange(g, bounds[2] + win, bounds[3] + win);
    var j = lo[1];
    while (j <= hi[1] and j < g.ny) : (j += 1) {
        const cy = g.miny + (@as(f64, @floatFromInt(j)) + 0.5) * g.pitch;
        const row = j * g.nx;
        var i = lo[0];
        while (i <= hi[0] and i < g.nx) : (i += 1) {
            const cx = g.minx + (@as(f64, @floatFromInt(i)) + 0.5) * g.pitch;
            const distance = pointArcDistance(arc, circle, .{ cx, cy });
            if (distance > win) continue;
            lowerMargin(g, row + i, distance - rad);
        }
    }
}

/// Carve footprint-authored copper-pour keepouts on their outer face. The
/// polygons are transformed with the part pose (including bottom-side mirror)
/// and stamped with zero added clearance: the authored boundary itself is the
/// no-pour boundary. Inner planes intentionally ignore these surface-launch
/// keepouts.
fn stampFootprintKeepouts(
    arena: std.mem.Allocator,
    g: Grid,
    placement: optimizer.Placement,
    spec: LayerSpec,
) std.mem.Allocator.Error!void {
    const layer_side = spec.side orelse return;
    for (placement.parts) |p| {
        for (p.features.copper_pour_keepouts) |keepout| {
            const board_side: optimizer.Side = switch (keepout.side) {
                .front => p.side,
                .back => if (p.side == .top) .bottom else .top,
            };
            if (board_side != layer_side or keepout.poly.len < 3) continue;
            const world = try arena.alloc([2]f64, keepout.poly.len);
            for (keepout.poly, world) |local, *out| out.* = optimizer.worldPadCenter(&p, local[0], local[1]);
            const one = [_][]const [2]f64{world};
            stampHigher(g, &one, 0);
        }
    }
}

/// Lower the margin field inside / within `clearance` of every HIGHER-priority
/// overlapping pour on this layer (see `LayerSpec.higher`). Each cell drops to
/// its signed distance OUT of the foreign pour minus the clearance: a cell
/// inside the pour, or nearer than the clearance, goes blocked, so this lower-
/// priority fill recedes and a clearance gap opens instead of a short. The
/// margin model matches `stampForeign` (the pour's boundary polygon is the
/// foreign copper); the bbox+clearance window bounds the cost like the disc/seg
/// stamps — cells beyond it contribute margin > clearance and never win `min()`.
fn stampHigher(g: Grid, polys: []const []const [2]f64, clearance: f64) void {
    for (polys) |poly| {
        if (poly.len < 3) continue;
        var minx = poly[0][0];
        var maxx = minx;
        var miny = poly[0][1];
        var maxy = miny;
        for (poly[1..]) |p| {
            minx = @min(minx, p[0]);
            maxx = @max(maxx, p[0]);
            miny = @min(miny, p[1]);
            maxy = @max(maxy, p[1]);
        }
        const win = clearance + window_cells * g.pitch;
        const lo = cellRange(g, minx - win, miny - win);
        const hi = cellRange(g, maxx + win, maxy + win);
        var j = lo[1];
        while (j <= hi[1] and j < g.ny) : (j += 1) {
            const cy = g.miny + (@as(f64, @floatFromInt(j)) + 0.5) * g.pitch;
            const row = j * g.nx;
            var i = lo[0];
            while (i <= hi[0] and i < g.nx) : (i += 1) {
                const cx = g.minx + (@as(f64, @floatFromInt(i)) + 0.5) * g.pitch;
                // +inside the foreign pour → strongly negative; outside, the
                // margin grows with distance and clears 0 at exactly `clearance`.
                lowerMargin(g, row + i, -polySignedInset(poly, cx, cy) - clearance);
            }
        }
    }
}

fn classPourClearance(placement: optimizer.Placement, name: []const u8, plane_net: PlaneNet, base: f64) f64 {
    for (placement.nets, 0..) |net, i| {
        if (std.ascii.eqlIgnoreCase(net.name, name)) {
            return pourClearanceForNet(placement, @intCast(i), plane_net, base);
        }
    }
    return base;
}

fn planeIsGround(net: PlaneNet) bool {
    return switch (net) {
        .ground => true,
        .named => |name| optimizer.isGroundName(leafName(name)),
    };
}

/// A `(ground-gap …)` is intentionally allowed to be smaller than the generic
/// 0.3 mm POUR opening, but only when the receiving pour is ground. Its value
/// was already raised to the signal's DRC clearance in `deriveWidths`, so this
/// does not waive copper legality. Non-ground pours keep the ordinary rule.
fn pourClearanceForNet(placement: optimizer.Placement, net: i32, plane_net: PlaneNet, base: f64) f64 {
    if (planeIsGround(plane_net) and net >= 0) {
        const i: usize = @intCast(net);
        if (i < placement.rules.net.len) {
            const gap = placement.rules.net[i].rf.impedance.ground_gap_mm;
            if (gap > 0) return gap;
        }
    }
    return placement.rules.clearanceForNet(net, base);
}

/// Edge-to-edge opening a poured plane keeps from this routed section. An
/// opt-in `(ground-gap MIN (max MAX))` grows the same-layer GND slot as the
/// trace widens, using the actual stack reference and copper foil. The inverse
/// solve returns MAX when 50 ohms is not reachable before the cap, so generated
/// copper and the trace analyzer share the same honest best-effort geometry.
/// Non-ground pours, fixed-gap classes, striplines and incomplete stackups keep
/// the ordinary per-net clearance unchanged.
fn trackPourClearance(placement: optimizer.Placement, track: router.Track, plane_net: PlaneNet, base: f64) f64 {
    const fixed = pourClearanceForNet(placement, track.net, plane_net, base);
    if (!planeIsGround(plane_net) or track.net < 0) return fixed;
    const net_index: usize = @intCast(track.net);
    if (net_index >= placement.rules.net.len) return fixed;
    const rule = placement.rules.net[net_index];
    const gap = rule.rf.impedance.ground_gap_mm;
    const cap = rule.rf.impedance.ground_gap_max_mm;
    if (!(rule.rf.impedance.ohms > 0) or rule.rf.impedance.diff_ohms > 0) return fixed;
    if (!(gap > 0) or !(cap > gap)) return fixed;

    if (track.layer >= placement.rules.signalLayerCount()) return fixed;
    const physical_layer = placement.rules.signalStackIndex(track.layer);
    const ref = impedance.reference(placement.rules.physical.stack, physical_layer) orelse return fixed;
    const solved = impedance.refGroundGapForZ0(
        ref,
        track.width,
        placement.rules.physical.stack.foilMm(physical_layer),
        rule.rf.impedance.ohms,
        fixed,
        @max(fixed, cap),
    ) catch return fixed;
    return solved.gap_mm;
}

/// Clearance stamped into the signed field for a same-layer controlled GND
/// opening. Ordinary clearances are minimum legal spacings, so the tracer's
/// conservative guard belongs on top of them. A `(ground-gap ...)`, however,
/// is the FINISHED edge-to-edge CPWG geometry used by the impedance model. The
/// contour tracer subsequently offsets every stamped obstacle by `guard`; take
/// that known offset out here so the emitted Gerber lands on the authored /
/// solved gap instead of silently widening every RF slot by 0.03 mm.
///
/// This is only a representation correction: the resolved ground gap was
/// already raised to the applicable copper clearance by `deriveWidths`, and
/// final-polygon DRC still checks the manufactured pour against foreign copper.
/// If a coarsened raster needs a guard at least as large as the requested gap,
/// retain a zero stamp clearance rather than going negative; that fill remains
/// visibly coarsened and cannot masquerade as a tighter result.
fn trackPourStampClearance(
    placement: optimizer.Placement,
    track: router.Track,
    plane_net: PlaneNet,
    base: f64,
    guard: f64,
) f64 {
    const finished = trackPourClearance(placement, track, plane_net, base);
    if (!planeIsGround(plane_net) or track.net < 0) return finished;
    const i: usize = @intCast(track.net);
    if (i >= placement.rules.net.len or !(placement.rules.net[i].rf.impedance.ground_gap_mm > 0)) return finished;
    return @max(0, finished - guard);
}

/// Clearance from an RF signal via's copper land to every foreign plane/pour.
/// Single-ended controlled-impedance classes use the stackup-aware antipad
/// estimate; a `(max-freq …)` class with no authored target solves the same
/// antipad at the 50 ohm RF system default, so an RF trace's via keeps its
/// designed impedance without restating the near-universal number. All other
/// vias preserve the ordinary pour/ground-gap behaviour. Applying one
/// diameter on every layer keeps the saved fill, Gerber planes, and viewer
/// identical and keeps the transition's plane coupling consistent.
pub fn viaPlaneClearance(placement: optimizer.Placement, via: router.Via, plane_net: PlaneNet, base: f64) f64 {
    if (via.net >= 0) {
        const i: usize = @intCast(via.net);
        if (i < placement.rules.net.len) {
            const r = placement.rules.net[i];
            const target = if (r.rf.impedance.ohms > 0)
                r.rf.impedance.ohms
            else if (r.rf.max_freq_hz > 0)
                via_antipad.default_system_ohms
            else
                0;
            if (target > 0 and r.rf.impedance.diff_ohms <= 0) {
                const minimum = placement.rules.clearanceForNet(via.net, placement.rules.design.clearance);
                if (via_antipad.solve(
                    placement.rules.physical.stack,
                    target,
                    via.dia,
                    via.drill,
                    minimum,
                )) |result| return (result.antipad_dia_mm - via.dia) / 2.0;
            }
        }
    }
    return pourClearanceForNet(placement, via.net, plane_net, base);
}

/// Mark the component under each same-net SEED (a carried pad/via present on
/// the layer) KEPT. A component with no seed is an orphan island — dropped.
fn markSeeds(g: Grid, placement: optimizer.Placement, copper: Copper, spec: LayerSpec, nets: std.StringHashMapUnmanaged([]const u8), kept: []bool) void {
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (!padOnLayer(p, pad, spec)) continue;
            if (!planeCarries(spec.net, netOfPad(nets, p.ref_des, pad.number))) continue;
            seedPad(g, p, pad, kept);
        }
    }
    for (copper.vias) |v| {
        if (!planeCarries(spec.net, netName(placement, v.net))) continue;
        seedAt(g, v.x, v.y, kept);
    }
}

/// Seed the pour from a same-net pad by sampling its centre and four rotated
/// edge-midpoints (so a pad whose centre grazes an obstacle/edge cell still
/// keeps the component its copper actually reaches).
fn seedPad(g: Grid, p: optimizer.Part, pad: geometry.Pad, kept: []bool) void {
    const hw = pad.w * 0.4;
    const hh = pad.h * 0.4;
    const local = [_][2]f64{ .{ pad.x, pad.y }, .{ pad.x + hw, pad.y }, .{ pad.x - hw, pad.y }, .{ pad.x, pad.y + hh }, .{ pad.x, pad.y - hh } };
    for (local) |lp| {
        const c = optimizer.worldPadCenter(&p, lp[0], lp[1]);
        seedAt(g, c[0], c[1], kept);
    }
}

fn seedAt(g: Grid, x: f64, y: f64, kept: []bool) void {
    const lbl = labelAtWorld(g, x, y);
    if (lbl >= 0) kept[@intCast(lbl)] = true;
}

fn labelAtWorld(g: Grid, x: f64, y: f64) i32 {
    if (g.pitch <= 0) return blocked_marker;
    const fi = @floor((x - g.minx) / g.pitch);
    const fj = @floor((y - g.miny) / g.pitch);
    if (fi < 0 or fj < 0) return blocked_marker;
    const i: usize = numeric.checkedInt(usize, fi) orelse return blocked_marker;
    const j: usize = numeric.checkedInt(usize, fj) orelse return blocked_marker;
    if (i >= g.nx or j >= g.ny) return blocked_marker;
    return g.labels[j * g.nx + i];
}

/// Lower the field to `dist_to_centre − rad` over a disc feature of clearance-
/// radius `rad` (a via/drill barrel plus its clearance). The window reaches
/// `window_cells` past the reach so the field is accurate on both sides of the
/// iso-line.
pub fn stampDisc(g: Grid, cx: f64, cy: f64, rad: f64) void {
    if (rad <= 0) return;
    const win = rad + window_cells * g.pitch;
    const lo = cellRange(g, cx - win, cy - win);
    const hi = cellRange(g, cx + win, cy + win);
    const win2 = win * win;
    // Deep-interior sentinel: a cell more than two cells inside the reach is
    // certainly blocked (−2·pitch < 0 ≤ iso) and is never read by the crossing
    // interpolation (every neighbour of a kept cell sits within a cell of the
    // iso-line, hence in the exact annulus), so a constant margin skips its
    // @sqrt. Sign-guarded: for a small disc (rad ≤ 2·pitch) the annulus covers
    // the whole interior and the sentinel is disabled. Cells beyond `win` are
    // skipped outright — their margin from this disc exceeds 2.5·pitch, which
    // can never govern a crossing (a crossing pair's margins stay under
    // iso + √2·pitch).
    const inner = rad - 2.0 * g.pitch;
    const inner2 = if (inner > 0) inner * inner else -1.0;
    var j = lo[1];
    while (j <= hi[1] and j < g.ny) : (j += 1) {
        // Row-constant dy² hoisted out of the i-loop; `dx*dx + dy2` is the same
        // float sum as the per-cell `dx*dx + dy*dy`, so the field is unchanged.
        const dy = (g.miny + (@as(f64, @floatFromInt(j)) + 0.5) * g.pitch) - cy;
        const dy2 = dy * dy;
        const row = j * g.nx;
        var i = lo[0];
        while (i <= hi[0] and i < g.nx) : (i += 1) {
            const dx = (g.minx + (@as(f64, @floatFromInt(i)) + 0.5) * g.pitch) - cx;
            const d2 = dx * dx + dy2;
            if (d2 > win2) continue;
            const m = if (d2 < inner2) -2.0 * g.pitch else @sqrt(d2) - rad;
            lowerMargin(g, row + i, m);
        }
    }
}

/// Lower the field to `dist_to_centreline − rad` over a track feature of
/// clearance-radius `rad` (half-width plus clearance), windowed as `stampDisc`.
pub fn stampSeg(g: Grid, x1: f64, y1: f64, x2: f64, y2: f64, rad: f64) void {
    if (rad <= 0) return;
    const win = rad + window_cells * g.pitch;
    const win2 = win * win;
    const lo = cellRange(g, @min(x1, x2) - win, @min(y1, y2) - win);
    const hi = cellRange(g, @max(x1, x2) + win, @max(y1, y2) + win);
    // Segment direction + length² are constant over the window (hoisted out of
    // both loops); `segDelta` reuses them, matching `segPointDist` exactly.
    const sdx = x2 - x1;
    const sdy = y2 - y1;
    const len2 = sdx * sdx + sdy * sdy;
    var j = lo[1];
    while (j <= hi[1] and j < g.ny) : (j += 1) {
        const cy = g.miny + (@as(f64, @floatFromInt(j)) + 0.5) * g.pitch;
        const row = j * g.nx;
        var i = lo[0];
        while (i <= hi[0] and i < g.nx) : (i += 1) {
            const cx = g.minx + (@as(f64, @floatFromInt(i)) + 0.5) * g.pitch;
            const dd = segDelta(.{ x1, y1 }, .{ sdx, sdy }, len2, .{ cx, cy });
            const d2 = dd[0] * dd[0] + dd[1] * dd[1];
            // A cell farther than the window contributes margin > window_cells·
            // pitch — it can never be a boundary cell, so skipping its write is
            // exactly the min-composition `stampDisc` already relies on.
            if (d2 > win2) continue;
            lowerMargin(g, row + i, std.math.hypot(dd[0], dd[1]) - rad);
        }
    }
}

/// The (Δx, Δy) from point `p` to its closest point on the segment from `a` in
/// direction `dir` (= end − a), given the precomputed length² of `dir`. Its
/// magnitude (`std.math.hypot`) equals `segPointDist`; splitting the delta out
/// lets `stampSeg` square it for the cheap window test and take the hypot only
/// on the cells that actually govern the field.
fn segDelta(a: [2]f64, dir: [2]f64, len2: f64, p: [2]f64) [2]f64 {
    if (len2 < 1e-12) return .{ p[0] - a[0], p[1] - a[1] };
    const t = std.math.clamp(((p[0] - a[0]) * dir[0] + (p[1] - a[1]) * dir[1]) / len2, 0, 1);
    return .{ p[0] - (a[0] + t * dir[0]), p[1] - (a[1] + t * dir[1]) };
}

/// Lower the field to `dist_to_pad_copper − reach` over a pad feature (`reach` =
/// the pure clearance; the pad's own extent lives in its shape). The `pointDist`
/// slack is the full window radius, so its box early-out stays exact everywhere
/// the field feeds the iso-line interpolation.
pub fn stampPad(g: Grid, p: optimizer.Part, pad: geometry.Pad, reach: f64) void {
    stampPadWithin(g, null, p, pad, reach);
}

fn stampPadWithin(g: Grid, active: ?[4]f64, p: optimizer.Part, pad: geometry.Pad, reach: f64) void {
    var arena_buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    const sh = pad_shape.worldShape(fba.allocator(), p, pad) catch return;
    const win = reach + window_cells * g.pitch;
    if (!stampWindowActive(active, sh.x0 - win, sh.y0 - win, sh.x1 + win, sh.y1 + win)) return;
    stampPadShape(g, sh, reach);
}

/// Lower a signed-margin field around one already-world-space pad shape.
/// Route free-space analysis owns `router.PadObs` rather than the original
/// part/pad pair, so this is the common geometric seam it shares with pours.
pub fn stampPadShape(g: Grid, sh: pad_shape.Shape, reach: f64) void {
    const win = reach + window_cells * g.pitch;
    const win2 = win * win;
    const lo = cellRange(g, sh.x0 - win, sh.y0 - win);
    const hi = cellRange(g, sh.x1 + win, sh.y1 + win);
    var j = lo[1];
    while (j <= hi[1] and j < g.ny) : (j += 1) {
        const cy = g.miny + (@as(f64, @floatFromInt(j)) + 0.5) * g.pitch;
        const gy = @max(@max(sh.y0 - cy, cy - sh.y1), 0);
        const row = j * g.nx;
        var i = lo[0];
        while (i <= hi[0] and i < g.nx) : (i += 1) {
            const cx = g.minx + (@as(f64, @floatFromInt(i)) + 0.5) * g.pitch;
            const gx = @max(@max(sh.x0 - cx, cx - sh.x1), 0);
            // Box-gap window early-out: the bounding box contains the copper, so
            // a cell farther than the window from the box is farther than
            // window_cells·pitch from the copper — a non-boundary cell whose
            // write never governs the field (`pointDist` would just return that
            // box gap). gx²+gy² is exactly `pointDist`'s own `bd²`.
            if (gx * gx + gy * gy > win2) continue;
            const d = pad_shape.pointDist(sh.x0, sh.y0, sh.x1, sh.y1, sh.poly, cx, cy, win);
            lowerMargin(g, row + i, d - reach);
        }
    }
}

/// Stamp polygonal foreign copper into a signed-margin field. The route-space
/// provider uses the same polygon distance transform that overlapping pours
/// use, with `clearance` already including the candidate trace radius.
pub fn stampPolygon(g: Grid, poly: []const [2]f64, clearance: f64) void {
    const one = [_][]const [2]f64{poly};
    stampHigher(g, &one, clearance);
}

fn stampPolygonWithin(g: Grid, active: ?[4]f64, poly: []const [2]f64, clearance: f64) void {
    if (poly.len < 3) return;
    const bounds = polyBounds(poly);
    const win = clearance + window_cells * g.pitch;
    if (!stampWindowActive(active, bounds[0] - win, bounds[1] - win, bounds[2] + win, bounds[3] + win)) return;
    stampPolygon(g, poly, clearance);
}

/// Clamp world (x,y) to a grid cell index (saturating at 0 — the callers clamp
/// the high end against nx/ny in their loops).
fn cellRange(g: Grid, x: f64, y: f64) [2]usize {
    const fi = @floor((x - g.minx) / g.pitch);
    const fj = @floor((y - g.miny) / g.pitch);
    return .{
        numeric.toCount(fi),
        numeric.toCount(fj),
    };
}

fn netName(placement: optimizer.Placement, net: i32) []const u8 {
    if (net < 0) return "";
    const i: usize = @intCast(net);
    if (i >= placement.nets.len) return "";
    return placement.nets[i].name;
}

// ── Connected-component labelling ───────────────────────────────────────────

/// Flood-fill 4-connected UNLABELED cells into components 0..k-1 (relabelled in
/// place). Returns k. Uses an explicit stack (no recursion).
fn labelComponents(arena: std.mem.Allocator, g: Grid) std.mem.Allocator.Error!usize {
    var stack: std.ArrayList(u32) = .empty;
    var next: i32 = 0;
    var start: usize = 0;
    while (start < g.labels.len) : (start += 1) {
        if (g.labels[start] != unlabeled) continue;
        g.labels[start] = next;
        stack.clearRetainingCapacity();
        try stack.append(arena, @intCast(start));
        while (stack.pop()) |idx| {
            const i = idx % g.nx;
            const j = idx / g.nx;
            if (i > 0) try floodPush(arena, g, &stack, j * g.nx + (i - 1), next);
            if (i + 1 < g.nx) try floodPush(arena, g, &stack, j * g.nx + (i + 1), next);
            if (j > 0) try floodPush(arena, g, &stack, (j - 1) * g.nx + i, next);
            if (j + 1 < g.ny) try floodPush(arena, g, &stack, (j + 1) * g.nx + i, next);
        }
        next += 1;
    }
    return @intCast(next);
}

fn floodPush(arena: std.mem.Allocator, g: Grid, stack: *std.ArrayList(u32), idx: usize, comp: i32) std.mem.Allocator.Error!void {
    if (g.labels[idx] != unlabeled) return;
    g.labels[idx] = comp;
    try stack.append(arena, @intCast(idx));
}

/// Remap kept components to a dense 0..n; every other cell becomes -1 (blocked
/// or dropped orphan). Returns the kept count n.
fn remapKept(arena: std.mem.Allocator, g: Grid, kept: []bool) std.mem.Allocator.Error!usize {
    const dense = try arena.alloc(i32, kept.len);
    var n: i32 = 0;
    for (kept, 0..) |k, i| {
        if (k) {
            dense[i] = n;
            n += 1;
        } else dense[i] = -1;
    }
    for (g.labels) |*l| {
        l.* = if (l.* >= 0) dense[@intCast(l.*)] else -1;
    }
    return @intCast(n);
}

// ── Contour tracing (margin-field iso-line, interpolated dual squares) ────────

/// Directions, clockwise in the y-down grid: E, S, W, N.
const Dir = enum(u2) { e, s, w, n };
/// One boundary edge between a kept `comp` cell and an empty neighbour. `a`/`b`
/// are the lattice corner codes it runs between (the stitcher connects loops on
/// these); `dir` orients it copper-on-the-left in this y-down grid AND names
/// which neighbour is
/// empty; `cell` is the kept cell's linear index (`j*nx+i`), from which — with
/// `dir` — the interpolation recovers the kept/empty cell-centre pair.
const Edge = struct { a: u32, b: u32, dir: Dir, cell: u32, used: bool = false };
/// Corner code → indices of the (still-unused) boundary edges leaving it.
const TailMap = std.AutoHashMapUnmanaged(u32, std.ArrayList(usize));

/// One kept component realised as boundary polygons: its outer contour plus the
/// interior holes fully enclosed by it (empty when solid).
const TracedComponent = struct { outer: Contour, holes: []const Contour };

/// The kept components' contours and their per-component holes, PARALLEL arrays
/// (`contours[i]`/`holes[i]` describe the same final solid) built for `Fill`.
const Traced = struct {
    contours: []const Contour,
    holes: []const []const Contour,
    n_comp: usize,
};

/// One triangular sliver deliberately removed when an opposite-winding pinch
/// is opened. Membership is raster-based, so every labelled cell whose area
/// intersects this sliver is cleared conservatively after tracing.
const RepairClear = [3][2]f64;

/// Contour tracing can fail geometrically even when every allocation succeeds.
/// The public fill API handles this internally with an empty `integrity_ok=false`
/// fill: no invalid polygon is emitted and no connectivity check credits copper
/// that fabrication cannot receive; DRC/export therefore fail closed.
const TraceError = std.mem.Allocator.Error || error{InvalidBoundary};

/// Trace every kept component 0..n_comp, dropping the ones that yield no
/// boundary (degenerate). Keeps `contours` and `holes` parallel — a component
/// contributes to both or neither.
fn traceComponents(arena: std.mem.Allocator, g: Grid, n_comp: usize, corner_radius: f64) TraceError!Traced {
    var contours: std.ArrayList(Contour) = .empty;
    var holes: std.ArrayList([]const Contour) = .empty;
    var repair_clears: std.ArrayList(RepairClear) = .empty;
    var c: usize = 0;
    while (c < n_comp) : (c += 1) {
        for (try traceOuters(arena, g, @intCast(c), corner_radius, &repair_clears)) |tc| {
            try contours.append(arena, tc.outer);
            try holes.append(arena, tc.holes);
        }
    }
    clearRepairLabels(g, repair_clears.items);
    const repaired_n_comp = if (repair_clears.items.len > 0)
        try relabelKeptAfterRepair(arena, g)
    else
        n_comp;
    return .{
        .contours = try contours.toOwnedSlice(arena),
        .holes = try holes.toOwnedSlice(arena),
        .n_comp = repaired_n_comp,
    };
}

/// Trace component `comp`'s boundary loops (the lattice edges between a `comp`
/// cell and a non-`comp` neighbour, oriented copper-on-the-left, stitched into
/// loops that hug the copper at saddles and realised as one interpolated guard
/// crossing per edge). A raster component may resolve into several simple
/// outer rings when its iso-line only touches at a point; each emitted outer is
/// paired with the directly contained holes that belong to it.
fn traceOuters(
    arena: std.mem.Allocator,
    g: Grid,
    comp: i32,
    corner_radius: f64,
    repair_clears: *std.ArrayList(RepairClear),
) TraceError![]const TracedComponent {
    var edges: std.ArrayList(Edge) = .empty;
    try collectBoundaryEdges(arena, &edges, g, comp);
    if (edges.items.len == 0) return &.{};

    var by_tail: TailMap = .empty;
    try indexTails(arena, &by_tail, edges.items);
    const loops = try realiseLoops(arena, g, edges.items, &by_tail, repair_clears);
    return classifyLoops(arena, loops, g.pitch, corner_radius, repair_clears);
}

/// Emit every boundary edge of component `comp` (a `comp` cell adjacent to a
/// non-`comp` neighbour), oriented copper-on-the-left in the y-down grid.
fn collectBoundaryEdges(arena: std.mem.Allocator, edges: *std.ArrayList(Edge), g: Grid, comp: i32) std.mem.Allocator.Error!void {
    const w: u32 = @intCast(g.nx + 1);
    var j: usize = 0;
    while (j < g.ny) : (j += 1) {
        var i: usize = 0;
        while (i < g.nx) : (i += 1) {
            if (g.labels[j * g.nx + i] != comp) continue;
            try emitCellEdges(arena, edges, g, comp, i, j, w);
        }
    }
}

/// Index boundary edges by their tail corner code, so the stitcher can find the
/// unused outgoing edges at each corner.
fn indexTails(arena: std.mem.Allocator, by_tail: *TailMap, edges: []const Edge) std.mem.Allocator.Error!void {
    for (edges, 0..) |e, idx| {
        const gop = try by_tail.getOrPut(arena, e.a);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, idx);
    }
}

/// Stitch every still-unused boundary edge into a loop and realise it as an
/// interpolated world polygon. The loops partition the component's boundary into
/// one outer contour and its interior holes.
fn realiseLoops(
    arena: std.mem.Allocator,
    g: Grid,
    edges: []Edge,
    by_tail: *TailMap,
    repair_clears: *std.ArrayList(RepairClear),
) TraceError![]const Contour {
    var loops: std.ArrayList(Contour) = .empty;
    for (edges, 0..) |_, idx| {
        if (edges[idx].used) continue;
        const loop = try stitchLoop(arena, edges, by_tail, idx);
        try resolvePinchedWalk(arena, try loopToWorld(arena, g, edges, loop), g.pitch, &loops, repair_clears);
    }
    return loops.toOwnedSlice(arena);
}

/// First non-consecutive recurrence of one exact interpolated point. Distinct
/// boundary edges can land on the same iso point at a tangency even though the
/// lattice walk itself is closed and complete.
fn repeatedVertex(arena: std.mem.Allocator, poly: Contour) std.mem.Allocator.Error!?[2]usize {
    var seen: std.StringHashMapUnmanaged(usize) = .empty;
    defer seen.deinit(arena);
    for (poly, 0..) |_, i| {
        const gop = try seen.getOrPut(arena, std.mem.asBytes(&poly[i]));
        if (gop.found_existing) return .{ gop.value_ptr.*, i };
        gop.value_ptr.* = i;
    }
    return null;
}

fn withoutVertex(arena: std.mem.Allocator, poly: Contour, skip: usize) std.mem.Allocator.Error!Contour {
    const out = try arena.alloc([2]f64, poly.len - 1);
    @memcpy(out[0..skip], poly[0..skip]);
    @memcpy(out[skip..], poly[skip + 1 ..]);
    return out;
}

fn otherCycle(arena: std.mem.Allocator, poly: Contour, first: usize, again: usize) std.mem.Allocator.Error!Contour {
    const len = first + 1 + poly.len - again - 1;
    const out = try arena.alloc([2]f64, len);
    @memcpy(out[0 .. first + 1], poly[0 .. first + 1]);
    @memcpy(out[first + 1 ..], poly[again + 1 ..]);
    return out;
}

/// Resolve an iso-line walk that revisits an exact point without discarding its
/// valid copper. Same-winding lobes are independent dark outers. Opposite-
/// winding cycles are an outer and a tangent clearance pocket; removing one
/// copy of their shared point opens the zero-width pinch as one simple,
/// conservatively smaller notched ring. Further pinches are handled
/// iteratively, so every returned walk has unique vertices.
fn resolvePinchedWalk(
    arena: std.mem.Allocator,
    raw: Contour,
    pitch: f64,
    out: *std.ArrayList(Contour),
    repair_clears: *std.ArrayList(RepairClear),
) TraceError!void {
    var pending: std.ArrayList(Contour) = .empty;
    try pending.append(arena, try cleanContour(arena, raw));
    while (pending.pop()) |poly| {
        const pair = try repeatedVertex(arena, poly) orelse {
            if (poly.len >= 3) try out.append(arena, poly);
            continue;
        };
        if (pair[1] <= pair[0] + 1) return error.InvalidBoundary;
        const one = poly[pair[0]..pair[1]];
        const two = try otherCycle(arena, poly, pair[0], pair[1]);
        const area_one = outline.signedArea2(one);
        const area_two = outline.signedArea2(two);
        if (one.len < 3 or @abs(area_one) < 2e-9) {
            if (two.len >= 3) try pending.append(arena, two);
            continue;
        }
        if (two.len < 3 or @abs(area_two) < 2e-9) {
            try pending.append(arena, one);
            continue;
        }
        if (area_one * area_two > 0) {
            if (one.len >= 3) try pending.append(arena, one);
            if (two.len >= 3) try pending.append(arena, two);
            continue;
        }

        const skip_first = try withoutVertex(arena, poly, pair[0]);
        const skip_again = try withoutVertex(arena, poly, pair[1]);
        const first_area = @abs(outline.signedArea2(skip_first));
        const again_area = @abs(outline.signedArea2(skip_again));
        const original_area = @abs(area_one + area_two);
        const max_removed_area2 = 2 * pitch * pitch + 1e-9;
        const first_ok = first_area <= original_area + 1e-9 and original_area - first_area <= max_removed_area2;
        const again_ok = again_area <= original_area + 1e-9 and original_area - again_area <= max_removed_area2;
        const Choice = struct { poly: Contour, skipped: usize, area2: f64 };
        const chosen: Choice = if (first_ok and (!again_ok or first_area >= again_area))
            .{ .poly = skip_first, .skipped = pair[0], .area2 = first_area }
        else if (again_ok)
            .{ .poly = skip_again, .skipped = pair[1], .area2 = again_area }
        else
            return error.InvalidBoundary;
        if (original_area - chosen.area2 > contour_eps) {
            const previous = if (chosen.skipped == 0) poly.len - 1 else chosen.skipped - 1;
            try repair_clears.append(arena, .{
                poly[previous],
                poly[chosen.skipped],
                poly[(chosen.skipped + 1) % poly.len],
            });
        }
        try pending.append(arena, chosen.poly);
    }
}

/// Clear every labelled raster cell with positive-area overlap against a
/// deliberately removed repair triangle. Clearing the whole cell is the safe
/// direction: it may under-credit at most the local raster pitch, but can never
/// claim a wedge that the final Gerber contour no longer contains.
fn clearRepairLabels(g: Grid, repairs: []const RepairClear) void {
    for (repairs) |repair| {
        const bounds = polyBounds(&repair);
        const lo = cellRange(g, bounds[0], bounds[1]);
        const hi = cellRange(g, bounds[2], bounds[3]);
        var j = lo[1];
        while (j <= hi[1] and j < g.ny) : (j += 1) {
            var i = lo[0];
            while (i <= hi[0] and i < g.nx) : (i += 1) {
                const idx = j * g.nx + i;
                if (g.labels[idx] < 0) continue;
                const x0 = g.minx + @as(f64, @floatFromInt(i)) * g.pitch;
                const y0 = g.miny + @as(f64, @floatFromInt(j)) * g.pitch;
                if (repairIntersectsCell(repair, x0, y0, x0 + g.pitch, y0 + g.pitch)) g.labels[idx] = -1;
            }
        }
    }
}

/// Rebuild component ids after a conservative repair clear. Only cells that
/// were already in a kept component participate; blocked cells and components
/// dropped by the seed/unseeded policy remain blocked. This prevents one old
/// id from electrically joining islands separated by a cleared articulation
/// cell while keeping componentAt a constant-time grid lookup.
fn relabelKeptAfterRepair(arena: std.mem.Allocator, g: Grid) std.mem.Allocator.Error!usize {
    for (g.labels) |*label| label.* = if (label.* >= 0) unlabeled else blocked_marker;
    const n_comp = try labelComponents(arena, g);
    for (g.labels) |*label| if (label.* < 0) {
        label.* = -1;
    };
    return n_comp;
}

/// Positive-area convex triangle/axis-aligned-cell intersection by separating
/// axes. Boundary-only contact does not clear the neighbouring cell.
fn repairIntersectsCell(repair: RepairClear, x0: f64, y0: f64, x1: f64, y1: f64) bool {
    if (@abs(outline.signedArea2(&repair)) <= contour_eps) return false;
    const axes = [5][2]f64{
        .{ 1, 0 },
        .{ 0, 1 },
        .{ repair[0][1] - repair[1][1], repair[1][0] - repair[0][0] },
        .{ repair[1][1] - repair[2][1], repair[2][0] - repair[1][0] },
        .{ repair[2][1] - repair[0][1], repair[0][0] - repair[2][0] },
    };
    const centre = [2]f64{ (x0 + x1) / 2, (y0 + y1) / 2 };
    const half = [2]f64{ (x1 - x0) / 2, (y1 - y0) / 2 };
    for (axes) |axis| {
        const axis_len = std.math.hypot(axis[0], axis[1]);
        if (!(axis_len > contour_eps)) continue;
        var tri_min = repair[0][0] * axis[0] + repair[0][1] * axis[1];
        var tri_max = tri_min;
        for (repair[1..]) |point| {
            const projection = point[0] * axis[0] + point[1] * axis[1];
            tri_min = @min(tri_min, projection);
            tri_max = @max(tri_max, projection);
        }
        const cell_mid = centre[0] * axis[0] + centre[1] * axis[1];
        const cell_radius = half[0] * @abs(axis[0]) + half[1] * @abs(axis[1]);
        const overlap = @min(tri_max, cell_mid + cell_radius) - @max(tri_min, cell_mid - cell_radius);
        if (overlap <= contour_eps * axis_len) return false;
    }
    return true;
}

const LoopInfo = struct {
    poly: Contour,
    sample: [2]f64,
    area2: f64,
};

fn interiorSample(poly: Contour, pitch: f64) [2]f64 {
    var edge: usize = 0;
    var best_len2: f64 = -1;
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const len2 = dx * dx + dy * dy;
        if (len2 > best_len2) {
            best_len2 = len2;
            edge = i;
        }
    }
    const a = poly[edge];
    const b = poly[(edge + 1) % poly.len];
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @sqrt(best_len2);
    if (!(len > 0)) return a;
    const inward_sign: f64 = if (outline.signedArea2(poly) > 0) 1 else -1;
    const step = @min(pitch * 1e-4, len * 1e-4);
    return .{
        (a[0] + b[0]) / 2 - inward_sign * dy / len * step,
        (a[1] + b[1]) / 2 + inward_sign * dx / len * step,
    };
}

/// Classify all simple cycles of one raster component by the winding of its
/// largest (outer) cycle and geometric containment. This supports several dark
/// outers for one label component and attaches each opposite-winding hole to
/// the smallest outer that contains it.
fn classifyLoops(
    arena: std.mem.Allocator,
    loops: []const Contour,
    pitch: f64,
    corner_radius: f64,
    repair_clears: *std.ArrayList(RepairClear),
) TraceError![]const TracedComponent {
    return classifyLoopsAtTolerance(arena, loops, pitch, corner_radius, dp_tol, repair_clears);
}

fn classifyLoopsAtTolerance(
    arena: std.mem.Allocator,
    loops: []const Contour,
    pitch: f64,
    corner_radius: f64,
    simplify_tolerance: f64,
    repair_clears: *std.ArrayList(RepairClear),
) TraceError![]const TracedComponent {
    var info: std.ArrayList(LoopInfo) = .empty;
    for (loops) |poly| {
        if (poly.len < 3) continue;
        const final = try finalizeContourAtTolerance(arena, poly, corner_radius, simplify_tolerance);
        try info.append(arena, .{ .poly = final, .sample = interiorSample(final, pitch), .area2 = outline.signedArea2(final) });
    }
    if (info.items.len == 0) return &.{};

    var largest: usize = 0;
    for (info.items[1..], 1..) |candidate, i| {
        if (@abs(candidate.area2) > @abs(info.items[largest].area2)) largest = i;
    }
    const outer_positive = info.items[largest].area2 > 0;
    const hole_lists = try arena.alloc(std.ArrayList(Contour), info.items.len);
    @memset(hole_lists, .empty);
    const area2_floor = pitch * pitch;

    for (info.items, 0..) |hole, hole_i| {
        if ((hole.area2 > 0) == outer_positive) continue;
        if (@abs(hole.area2) < area2_floor) continue;
        var parent: ?usize = null;
        for (info.items, 0..) |outer_ring, outer_i| {
            if ((outer_ring.area2 > 0) != outer_positive) continue;
            if (!(polySignedInset(outer_ring.poly, hole.sample[0], hole.sample[1]) > 0)) continue;
            if (parent == null or @abs(outer_ring.area2) < @abs(info.items[parent.?].area2)) parent = outer_i;
        }
        const outer_i = parent orelse return error.InvalidBoundary;
        _ = hole_i;
        try hole_lists[outer_i].append(arena, hole.poly);
    }

    var components: std.ArrayList(TracedComponent) = .empty;
    for (info.items, 0..) |outer_ring, i| {
        if ((outer_ring.area2 > 0) != outer_positive) continue;
        try components.append(arena, .{ .outer = outer_ring.poly, .holes = try hole_lists[i].toOwnedSlice(arena) });
    }
    const result = try components.toOwnedSlice(arena);
    if (try tracedComponentsValid(arena, result)) return result;

    // Filleting each simple ring independently is insufficient: in a narrow
    // clearance pocket two individually valid rounded rings can touch one
    // another. Preserve the complete copper topology by retrying the component
    // as sharp rings. A sharp component that is still malformed is irreparable
    // unless it is the raster's other representation of the same topology: a
    // clearance hole tangent to its outer. Open that zero-width pinch as a
    // conservative notch; every other sharp defect remains fail-closed.
    if (corner_radius > 0) return classifyLoopsAtTolerance(arena, loops, pitch, 0, simplify_tolerance, repair_clears);
    // Douglas-Peucker can leave every ring individually simple while moving an
    // outer and a nearby hole through one another. Retry the whole component
    // with progressively less loss, so the first topology-safe compact form is
    // retained; exact raw geometry is the final fallback before tangent repair.
    if (simplify_tolerance > 0) {
        const next_tolerance = if (simplify_tolerance > 0.0005) simplify_tolerance / 2 else 0;
        return classifyLoopsAtTolerance(arena, loops, pitch, 0, next_tolerance, repair_clears);
    }
    const repaired = try repairTangentHoles(arena, result, pitch, repair_clears);
    if (try tracedComponentsValid(arena, repaired)) return repaired;
    return error.InvalidBoundary;
}

fn emitCellEdges(arena: std.mem.Allocator, edges: *std.ArrayList(Edge), g: Grid, comp: i32, i: usize, j: usize, w: u32) std.mem.Allocator.Error!void {
    const ii: u32 = @intCast(i);
    const jj: u32 = @intCast(j);
    const cell: u32 = jj * @as(u32, @intCast(g.nx)) + ii;
    const solid = struct {
        fn at(gg: Grid, cc: i32, x: i64, y: i64) bool {
            if (x < 0 or y < 0 or x >= @as(i64, @intCast(gg.nx)) or y >= @as(i64, @intCast(gg.ny))) return false;
            return gg.labels[@as(usize, @intCast(y)) * gg.nx + @as(usize, @intCast(x))] == cc;
        }
    }.at;
    // top: neighbour above empty → edge (i+1,j)→(i,j), dir W
    if (!solid(g, comp, ii, @as(i64, jj) - 1)) try edges.append(arena, .{ .a = jj * w + ii + 1, .b = jj * w + ii, .dir = .w, .cell = cell });
    // bottom: neighbour below empty → edge (i,j+1)→(i+1,j+1), dir E
    if (!solid(g, comp, ii, @as(i64, jj) + 1)) try edges.append(arena, .{ .a = (jj + 1) * w + ii, .b = (jj + 1) * w + ii + 1, .dir = .e, .cell = cell });
    // left: neighbour left empty → edge (i,j)→(i,j+1), dir S
    if (!solid(g, comp, @as(i64, ii) - 1, jj)) try edges.append(arena, .{ .a = jj * w + ii, .b = (jj + 1) * w + ii, .dir = .s, .cell = cell });
    // right: neighbour right empty → edge (i+1,j+1)→(i+1,j), dir N
    if (!solid(g, comp, @as(i64, ii) + 1, jj)) try edges.append(arena, .{ .a = (jj + 1) * w + ii + 1, .b = jj * w + ii + 1, .dir = .n, .cell = cell });
}

/// Follow boundary edges from `start` back to its tail, choosing at each corner
/// the unused outgoing edge that turns most sharply left (copper on the left in
/// this y-down grid) — the standard rule that keeps 4-connected regions
/// separate at saddles.
/// Returns the ordered EDGE indices of the loop (one interpolated vertex each).
fn stitchLoop(arena: std.mem.Allocator, edges: []Edge, by_tail: *TailMap, start: usize) TraceError![]const usize {
    var idxs: std.ArrayList(usize) = .empty;
    errdefer idxs.deinit(arena);
    var cur = start;
    const loop_start = edges[start].a;
    while (true) {
        edges[cur].used = true;
        try idxs.append(arena, cur);
        const head = edges[cur].b;
        if (head == loop_start) break;
        // A boundary chain that cannot get back to its starting corner is not
        // a polygon. Do not turn the traversed prefix into an open G36 region.
        const nxt = pickNext(edges, by_tail, head, edges[cur].dir) orelse return error.InvalidBoundary;
        cur = nxt;
    }
    return idxs.toOwnedSlice(arena);
}

fn pickNext(edges: []Edge, by_tail: *TailMap, tail: u32, din: Dir) ?usize {
    const list = by_tail.get(tail) orelse return null;
    var best: ?usize = null;
    var best_pref: u8 = 255;
    for (list.items) |idx| {
        if (edges[idx].used) continue;
        const pref = turnPref(din, edges[idx].dir);
        if (pref < best_pref) {
            best_pref = pref;
            best = idx;
        }
    }
    return best;
}

/// Preference (0 = best) for turning from `din` to `dout`, hugging copper on
/// the left: left turn, then straight, then right, then reverse.
fn turnPref(din: Dir, dout: Dir) u8 {
    const d: u8 = @backingInt(din);
    const o: u8 = @backingInt(dout);
    const right = (d + 1) & 3;
    const straight = d;
    const left = (d + 3) & 3;
    if (o == left) return 0;
    if (o == straight) return 1;
    if (o == right) return 2;
    return 3;
}

/// Realise a stitched loop of boundary-edge indices as an interpolated world
/// polygon: one vertex per edge, the guard crossing of the margin field on
/// the segment from the kept cell centre to its empty neighbour's centre.
fn loopToWorld(
    arena: std.mem.Allocator,
    g: Grid,
    edges: []const Edge,
    loop: []const usize,
) std.mem.Allocator.Error![]const [2]f64 {
    const out = try arena.alloc([2]f64, loop.len);
    for (loop, 0..) |ei, k| out[k] = edgeCrossing(g, edges[ei]);
    return out;
}

/// The guard threshold crossing on the segment between edge `e`'s kept
/// cell centre and its empty neighbour's centre. `dir` names the empty
/// neighbour; an off-grid neighbour uses a value below the threshold so the
/// crossing stays a fraction of a cell inside.
fn edgeCrossing(g: Grid, e: Edge) [2]f64 {
    const nx: i64 = @intCast(g.nx);
    const kept: i64 = @intCast(e.cell);
    const ik = @mod(kept, nx);
    const jk = @divFloor(kept, nx);
    const ck = g.cellCenter(@intCast(ik), @intCast(jk));
    const mk: f64 = g.margin[e.cell];
    const d = neighborDelta(e.dir);
    const ie = ik + d[0];
    const je = jk + d[1];
    const dxf: f64 = @floatFromInt(d[0]);
    const dyf: f64 = @floatFromInt(d[1]);
    var ce: [2]f64 = .{ ck[0] + dxf * g.pitch, ck[1] + dyf * g.pitch };
    var me: f64 = g.iso - g.pitch;
    if (ie >= 0 and je >= 0 and ie < nx and je < @as(i64, @intCast(g.ny))) {
        ce = g.cellCenter(@intCast(ie), @intCast(je));
        me = g.margin[@as(usize, @intCast(je)) * g.nx + @as(usize, @intCast(ie))];
    }
    const denom = mk - me;
    const t = if (@abs(denom) < 1e-12) 0.5 else std.math.clamp((mk - g.iso) / denom, 0, 1);
    return .{ ck[0] + t * (ce[0] - ck[0]), ck[1] + t * (ce[1] - ck[1]) };
}

/// (Δi, Δj) from a kept cell to the EMPTY neighbour named by the edge direction
/// (mirrors the four `emitCellEdges` cases: .w above, .e below, .s left, .n
/// right).
fn neighborDelta(dir: Dir) [2]i64 {
    return switch (dir) {
        .w => .{ 0, -1 },
        .e => .{ 0, 1 },
        .s => .{ -1, 0 },
        .n => .{ 1, 0 },
    };
}

/// Colinear-merge then Douglas-Peucker at `dp_tol` (below `iso_guard`, so no
/// chord can ever fall under the true clearance): collapses the interpolated
/// iso-line's dense per-edge vertices to a compact smooth polygon.
fn simplify(arena: std.mem.Allocator, pts: []const [2]f64, tol: f64) std.mem.Allocator.Error!Contour {
    return simplifyClean(arena, try cleanContour(arena, pts), tol);
}

/// Remove zero-length boundary steps before testing collinearity. Iso-line
/// interpolation legitimately maps both sides of a grid corner to the kept
/// cell centre when its margin equals the guard. Treating that repeated point
/// as two vertices makes each copy appear collinear and can erase the corner —
/// or, for a loop made entirely of paired crossings, erase the whole ring.
fn cleanContour(arena: std.mem.Allocator, pts: Contour) std.mem.Allocator.Error!Contour {
    var clean: std.ArrayList([2]f64) = .empty;
    for (pts) |p| {
        if (clean.items.len == 0 or !sameContourPoint(clean.items[clean.items.len - 1], p)) try clean.append(arena, p);
    }
    if (clean.items.len > 1 and sameContourPoint(clean.items[0], clean.items[clean.items.len - 1])) _ = clean.pop();
    return clean.toOwnedSlice(arena);
}

fn sameContourPoint(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) <= 1e-12 and @abs(a[1] - b[1]) <= 1e-12;
}

fn simplifyClean(arena: std.mem.Allocator, pts: Contour, tol: f64) std.mem.Allocator.Error!Contour {
    if (pts.len < 4) return pts;
    var merged: std.ArrayList([2]f64) = .empty;
    for (pts, 0..) |p, i| {
        const prev = pts[(i + pts.len - 1) % pts.len];
        const next = pts[(i + 1) % pts.len];
        const cross = (p[0] - prev[0]) * (next[1] - prev[1]) - (p[1] - prev[1]) * (next[0] - prev[0]);
        if (@abs(cross) > 1e-9) try merged.append(arena, p);
    }
    if (merged.items.len < 4) return merged.toOwnedSlice(arena);
    return dp(arena, merged.items, tol);
}

const contour_eps: f64 = 1e-9;

const OrderedSegment = struct {
    index: usize,
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,
};

const TaggedSegment = struct {
    ring: usize,
    edge: usize,
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,
};

const RingContact = struct {
    outer_edge: usize,
    hole_edge: usize,
    point: [2]f64,
};

const ContactRing = struct {
    poly: Contour,
    contact: usize,
};

fn segmentOrder(_: void, a: OrderedSegment, b: OrderedSegment) bool {
    if (a.minx != b.minx) return a.minx < b.minx;
    if (a.miny != b.miny) return a.miny < b.miny;
    return a.index < b.index;
}

fn taggedSegmentOrder(_: void, a: TaggedSegment, b: TaggedSegment) bool {
    if (a.minx != b.minx) return a.minx < b.minx;
    if (a.miny != b.miny) return a.miny < b.miny;
    if (a.ring != b.ring) return a.ring < b.ring;
    return a.edge < b.edge;
}

fn contourOrient(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

fn contourOpposite(a: f64, b: f64, tolerance: f64) bool {
    return (a > tolerance and b < -tolerance) or (a < -tolerance and b > tolerance);
}

fn contourPointOnSegment(point: [2]f64, a: [2]f64, b: [2]f64, tolerance: f64) bool {
    return point[0] >= @min(a[0], b[0]) - tolerance and point[0] <= @max(a[0], b[0]) + tolerance and
        point[1] >= @min(a[1], b[1]) - tolerance and point[1] <= @max(a[1], b[1]) + tolerance;
}

fn contourSegmentsTouch(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) bool {
    const scale = @max(1, @max(std.math.hypot(b[0] - a[0], b[1] - a[1]), std.math.hypot(d[0] - c[0], d[1] - c[1])));
    const tolerance = contour_eps * scale;
    const abc = contourOrient(a, b, c);
    const abd = contourOrient(a, b, d);
    const cda = contourOrient(c, d, a);
    const cdb = contourOrient(c, d, b);
    if (contourOpposite(abc, abd, tolerance) and contourOpposite(cda, cdb, tolerance)) return true;
    if (@abs(abc) <= tolerance and contourPointOnSegment(c, a, b, tolerance)) return true;
    if (@abs(abd) <= tolerance and contourPointOnSegment(d, a, b, tolerance)) return true;
    if (@abs(cda) <= tolerance and contourPointOnSegment(a, c, d, tolerance)) return true;
    return @abs(cdb) <= tolerance and contourPointOnSegment(b, c, d, tolerance);
}

fn contourAdjacentRetrace(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) bool {
    const ab = [2]f64{ b[0] - a[0], b[1] - a[1] };
    const cd = [2]f64{ d[0] - c[0], d[1] - c[1] };
    const scale = @max(1, std.math.hypot(ab[0], ab[1]) * std.math.hypot(cd[0], cd[1]));
    return @abs(ab[0] * cd[1] - ab[1] * cd[0]) <= contour_eps * scale and
        ab[0] * cd[0] + ab[1] * cd[1] < -contour_eps * scale;
}

fn finiteContourPoint(point: [2]f64) bool {
    return std.math.isFinite(point[0]) and std.math.isFinite(point[1]);
}

/// Strict simple-ring validation with an x-sorted segment sweep. Unlike the
/// outline authoring predicate this rejects zero edges, repeated endpoint
/// touches, collinear overlap, and adjacent retrace; unlike the former nested
/// pair scan it stays near O(n log n) for the long raster boundaries.
fn validClosedContour(arena: std.mem.Allocator, pts: Contour) std.mem.Allocator.Error!bool {
    if (pts.len < 3 or @abs(outline.signedArea2(pts)) < 2e-9) return false;
    const ordered = try arena.alloc(OrderedSegment, pts.len);
    for (pts, 0..) |a, i| {
        const b = pts[(i + 1) % pts.len];
        if (!finiteContourPoint(a) or !finiteContourPoint(b)) return false;
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        if (dx * dx + dy * dy <= contour_eps * contour_eps) return false;
        ordered[i] = .{
            .index = i,
            .minx = @min(a[0], b[0]),
            .miny = @min(a[1], b[1]),
            .maxx = @max(a[0], b[0]),
            .maxy = @max(a[1], b[1]),
        };
    }
    std.mem.sort(OrderedSegment, ordered, {}, segmentOrder);
    for (ordered, 0..) |left, pos| {
        const a = pts[left.index];
        const b = pts[(left.index + 1) % pts.len];
        for (ordered[pos + 1 ..]) |right| {
            if (right.minx > left.maxx + contour_eps) break;
            if (right.maxy < left.miny - contour_eps or right.miny > left.maxy + contour_eps) continue;
            const c = pts[right.index];
            const d = pts[(right.index + 1) % pts.len];
            const adjacent = (left.index + 1) % pts.len == right.index or (right.index + 1) % pts.len == left.index;
            if (adjacent) {
                if (contourAdjacentRetrace(a, b, c, d)) return false;
            } else if (contourSegmentsTouch(a, b, c, d)) return false;
        }
    }
    return true;
}

/// Validate the topology between the already-simple rings of every emitted
/// component. The combined x sweep rejects outer/hole boundary contact without
/// reintroducing the old raw-ring O(n^2) scan, and containment proves every
/// clear ring is strictly inside its dark outer. Sibling clear rings may meet
/// only at zero-area point tangencies; overlap, nesting, and crossing would
/// make even-odd viewers disagree with Gerber's ordered clear polarity.
fn tracedComponentsValid(arena: std.mem.Allocator, components: []const TracedComponent) std.mem.Allocator.Error!bool {
    for (components) |component| if (!try tracedComponentValid(arena, component)) return false;
    return true;
}

fn tracedComponentValid(arena: std.mem.Allocator, component: TracedComponent) std.mem.Allocator.Error!bool {
    const rings = try arena.alloc(Contour, component.holes.len + 1);
    rings[0] = component.outer;
    @memcpy(rings[1..], component.holes);

    var segment_count: usize = 0;
    for (rings) |ring| segment_count += ring.len;
    const ordered = try arena.alloc(TaggedSegment, segment_count);
    var at: usize = 0;
    for (rings, 0..) |ring, ring_i| {
        for (ring, 0..) |a, edge_i| {
            const b = ring[(edge_i + 1) % ring.len];
            ordered[at] = .{
                .ring = ring_i,
                .edge = edge_i,
                .minx = @min(a[0], b[0]),
                .miny = @min(a[1], b[1]),
                .maxx = @max(a[0], b[0]),
                .maxy = @max(a[1], b[1]),
            };
            at += 1;
        }
    }
    std.mem.sort(TaggedSegment, ordered, {}, taggedSegmentOrder);
    for (ordered, 0..) |left, pos| {
        const a = rings[left.ring][left.edge];
        const b = rings[left.ring][(left.edge + 1) % rings[left.ring].len];
        for (ordered[pos + 1 ..]) |right| {
            if (right.minx > left.maxx + contour_eps) break;
            if (right.ring == left.ring or right.maxy < left.miny - contour_eps or right.miny > left.maxy + contour_eps) continue;
            const c = rings[right.ring][right.edge];
            const d = rings[right.ring][(right.edge + 1) % rings[right.ring].len];
            if (!contourSegmentsTouch(a, b, c, d)) continue;
            if (left.ring == 0 or right.ring == 0) return false;
            if (siblingContactHasArea(a, b, c, d)) return false;
        }
    }

    for (component.holes, 0..) |hole, i| {
        if (!(polySignedInset(component.outer, hole[0][0], hole[0][1]) > 0)) return false;
        for (component.holes[0..i]) |prior| {
            for (hole) |point| if (pointStrictlyInContour(prior, point)) return false;
            for (prior) |point| if (pointStrictlyInContour(hole, point)) return false;
        }
    }
    return true;
}

fn pointStrictlyInContour(poly: Contour, point: [2]f64) bool {
    for (poly, 0..) |a, i| {
        const b = poly[(i + 1) % poly.len];
        const tolerance = contour_eps * @max(1, std.math.hypot(b[0] - a[0], b[1] - a[1]));
        if (@abs(contourOrient(a, b, point)) <= tolerance and contourPointOnSegment(point, a, b, tolerance)) return false;
    }
    return polySignedInset(poly, point[0], point[1]) > 0;
}

fn siblingContactHasArea(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) bool {
    const scale = @max(1, @max(std.math.hypot(b[0] - a[0], b[1] - a[1]), std.math.hypot(d[0] - c[0], d[1] - c[1])));
    const tolerance = contour_eps * scale;
    const abc = contourOrient(a, b, c);
    const abd = contourOrient(a, b, d);
    const cda = contourOrient(c, d, a);
    const cdb = contourOrient(c, d, b);
    if (contourOpposite(abc, abd, tolerance) and contourOpposite(cda, cdb, tolerance)) return true;
    if (@abs(abc) > tolerance or @abs(abd) > tolerance or @abs(cda) > tolerance or @abs(cdb) > tolerance) return false;

    const use_x = @abs(b[0] - a[0]) >= @abs(b[1] - a[1]);
    const a0 = if (use_x) a[0] else a[1];
    const a1 = if (use_x) b[0] else b[1];
    const b0 = if (use_x) c[0] else c[1];
    const b1 = if (use_x) d[0] else d[1];
    const overlap = @min(@max(a0, a1), @max(b0, b1)) - @max(@min(a0, a1), @min(b0, b1));
    return overlap > tolerance;
}

/// Convert a hole that touches its outer at one point into an open clearance
/// notch. This removes, never adds, at most one raster-pitch square of copper
/// through `resolvePinchedWalk`; proper crossings, collinear overlap, or a
/// second non-local outer/hole crossing remain irreparable and fail closed.
fn repairTangentHoles(
    arena: std.mem.Allocator,
    components: []const TracedComponent,
    pitch: f64,
    repair_clears: *std.ArrayList(RepairClear),
) TraceError![]const TracedComponent {
    var repaired: std.ArrayList(TracedComponent) = .empty;
    for (components) |component| {
        var outer = component.outer;
        var holes: std.ArrayList(Contour) = .empty;
        for (component.holes) |hole| {
            const contact = try firstOuterHoleContact(arena, outer, hole) orelse {
                try holes.append(arena, hole);
                continue;
            };
            outer = try openTangentHole(arena, outer, hole, contact, pitch, repair_clears);
        }
        try repaired.append(arena, .{ .outer = outer, .holes = try holes.toOwnedSlice(arena) });
    }
    return repaired.toOwnedSlice(arena);
}

fn firstOuterHoleContact(arena: std.mem.Allocator, outer: Contour, hole: Contour) std.mem.Allocator.Error!?RingContact {
    const rings = [2]Contour{ outer, hole };
    const ordered = try arena.alloc(TaggedSegment, outer.len + hole.len);
    var at: usize = 0;
    for (&rings, 0..) |ring, ring_i| {
        for (ring, 0..) |a, edge_i| {
            const b = ring[(edge_i + 1) % ring.len];
            ordered[at] = .{
                .ring = ring_i,
                .edge = edge_i,
                .minx = @min(a[0], b[0]),
                .miny = @min(a[1], b[1]),
                .maxx = @max(a[0], b[0]),
                .maxy = @max(a[1], b[1]),
            };
            at += 1;
        }
    }
    std.mem.sort(TaggedSegment, ordered, {}, taggedSegmentOrder);
    for (ordered, 0..) |left, pos| {
        const a = rings[left.ring][left.edge];
        const b = rings[left.ring][(left.edge + 1) % rings[left.ring].len];
        for (ordered[pos + 1 ..]) |right| {
            if (right.minx > left.maxx + contour_eps) break;
            if (right.ring == left.ring or right.maxy < left.miny - contour_eps or right.miny > left.maxy + contour_eps) continue;
            const c = rings[right.ring][right.edge];
            const d = rings[right.ring][(right.edge + 1) % rings[right.ring].len];
            const point = segmentContactPoint(a, b, c, d) orelse continue;
            return if (left.ring == 0)
                .{ .outer_edge = left.edge, .hole_edge = right.edge, .point = point }
            else
                .{ .outer_edge = right.edge, .hole_edge = left.edge, .point = point };
        }
    }
    return null;
}

fn segmentContactPoint(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) ?[2]f64 {
    if (!contourSegmentsTouch(a, b, c, d)) return null;
    const scale = @max(1, @max(std.math.hypot(b[0] - a[0], b[1] - a[1]), std.math.hypot(d[0] - c[0], d[1] - c[1])));
    const tolerance = contour_eps * scale;
    if (@abs(contourOrient(c, d, a)) <= tolerance and contourPointOnSegment(a, c, d, tolerance)) return a;
    if (@abs(contourOrient(c, d, b)) <= tolerance and contourPointOnSegment(b, c, d, tolerance)) return b;
    if (@abs(contourOrient(a, b, c)) <= tolerance and contourPointOnSegment(c, a, b, tolerance)) return c;
    if (@abs(contourOrient(a, b, d)) <= tolerance and contourPointOnSegment(d, a, b, tolerance)) return d;

    const ab = [2]f64{ b[0] - a[0], b[1] - a[1] };
    const cd = [2]f64{ d[0] - c[0], d[1] - c[1] };
    const denominator = ab[0] * cd[1] - ab[1] * cd[0];
    if (@abs(denominator) <= tolerance) return null;
    const ac = [2]f64{ c[0] - a[0], c[1] - a[1] };
    const t = (ac[0] * cd[1] - ac[1] * cd[0]) / denominator;
    return .{ a[0] + t * ab[0], a[1] + t * ab[1] };
}

fn ringWithContact(arena: std.mem.Allocator, ring: Contour, edge: usize, point: [2]f64) std.mem.Allocator.Error!ContactRing {
    if (sameContourPoint(ring[edge], point)) return .{ .poly = ring, .contact = edge };
    const next = (edge + 1) % ring.len;
    if (sameContourPoint(ring[next], point)) return .{ .poly = ring, .contact = next };
    const inserted = try arena.alloc([2]f64, ring.len + 1);
    @memcpy(inserted[0 .. edge + 1], ring[0 .. edge + 1]);
    inserted[edge + 1] = point;
    @memcpy(inserted[edge + 2 ..], ring[edge + 1 ..]);
    return .{ .poly = inserted, .contact = edge + 1 };
}

fn openTangentHole(
    arena: std.mem.Allocator,
    outer: Contour,
    hole: Contour,
    contact: RingContact,
    pitch: f64,
    repair_clears: *std.ArrayList(RepairClear),
) TraceError!Contour {
    const a = try ringWithContact(arena, outer, contact.outer_edge, contact.point);
    const b = try ringWithContact(arena, hole, contact.hole_edge, contact.point);
    const walk = try arena.alloc([2]f64, a.poly.len + b.poly.len);
    for (0..a.poly.len) |i| walk[i] = a.poly[(a.contact + i) % a.poly.len];
    for (0..b.poly.len) |i| walk[a.poly.len + i] = b.poly[(b.contact + i) % b.poly.len];

    var resolved: std.ArrayList(Contour) = .empty;
    try resolvePinchedWalk(arena, walk, pitch, &resolved, repair_clears);
    if (resolved.items.len != 1) return error.InvalidBoundary;
    return finalizeContour(arena, resolved.items[0], 0);
}

/// Compact and optionally round one authoritative raw boundary without ever
/// sacrificing its topology. Douglas-Peucker and distant corner fillets can
/// each introduce a non-local crossing in a narrow, winding loop, so every
/// lossy stage is accepted only when it remains a valid closed contour.
fn finalizeContour(arena: std.mem.Allocator, raw: Contour, radius: f64) TraceError!Contour {
    return finalizeContourAtTolerance(arena, raw, radius, dp_tol);
}

fn finalizeContourAtTolerance(arena: std.mem.Allocator, raw: Contour, radius: f64, simplify_tolerance: f64) TraceError!Contour {
    const clean = try cleanContour(arena, raw);
    const simplified = try simplifyClean(arena, clean, simplify_tolerance);
    const simple = if (try validClosedContour(arena, simplified))
        simplified
    else if (try validClosedContour(arena, clean))
        clean
    else
        return error.InvalidBoundary;
    const rounded = try roundContour(arena, simple, radius);
    return if (try validClosedContour(arena, rounded)) rounded else simple;
}

/// Apply the board-level pour corner radius to a traced contour. The shared
/// fillet helper clamps a radius against adjacent edges and tessellates the
/// circular arc to the same 0.01 mm sagitta used by the board-outline path.
/// Keeping zero as a fast path preserves the legacy contour byte-for-byte.
fn roundContour(arena: std.mem.Allocator, pts: Contour, radius: f64) std.mem.Allocator.Error!Contour {
    if (!(radius > 0) or pts.len < 3) return pts;
    const radii = try arena.alloc(f64, pts.len);
    @memset(radii, radius);
    const fillet = try outline.filletPath(arena, pts, radii, 0.01);
    return fillet.poly;
}

fn dp(arena: std.mem.Allocator, pts: []const [2]f64, tol: f64) std.mem.Allocator.Error!Contour {
    var keep = try arena.alloc(bool, pts.len);
    @memset(keep, false);
    keep[0] = true;
    keep[pts.len - 1] = true;
    var stack: std.ArrayList([2]usize) = .empty;
    try stack.append(arena, .{ 0, pts.len - 1 });
    while (stack.pop()) |seg| {
        const a = seg[0];
        const b = seg[1];
        var best: f64 = tol;
        var split: usize = 0;
        var i = a + 1;
        while (i < b) : (i += 1) {
            const d = perpDist(pts[a], pts[b], pts[i]);
            if (d > best) {
                best = d;
                split = i;
            }
        }
        if (split != 0) {
            keep[split] = true;
            try stack.append(arena, .{ a, split });
            try stack.append(arena, .{ split, b });
        }
    }
    var out: std.ArrayList([2]f64) = .empty;
    for (pts, 0..) |p, i| if (keep[i]) try out.append(arena, p);
    return out.toOwnedSlice(arena);
}

fn perpDist(a: [2]f64, b: [2]f64, p: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len < 1e-12) return std.math.hypot(p[0] - a[0], p[1] - a[1]);
    return @abs((p[0] - a[0]) * dy - (p[1] - a[1]) * dx) / len;
}

fn segPointDist(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return std.math.hypot(px - ax, py - ay);
    const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    return std.math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

// ── Carrying-layer resolution + cross-layer connectivity ────────────────────

/// The layers that pour `net_name` on `rules`: declared `(plane IDX "NET")`
/// entries whose net matches (outer faces carry a `side`/`track_layer`; inner
/// planes don't), plus — for the legacy implicit model with no stackup form —
/// one INNER plane, ground (In1) when the net is ground-named and the block's
/// dominant supply rail (In2) when it is that rail. Both are inner, so neither
/// carries a `side`/`track_layer`, and a net is never on both.
pub fn carryingLayers(arena: std.mem.Allocator, rules: optimizer.BoardRules, net_name: []const u8) std.mem.Allocator.Error![]const LayerSpec {
    var out: std.ArrayList(LayerSpec) = .empty;
    if (!rules.declaredStackup()) {
        if (optimizer.isGroundName(leafName(net_name))) {
            try out.append(arena, .{ .net = .ground, .stack = 2 });
        } else if (implicit_plane.carriesRail(rules, net_name)) {
            try out.append(arena, .{ .net = .{ .named = rules.planes.implicit_rail.? }, .stack = 3 });
        }
        return out.toOwnedSlice(arena);
    }
    const bottom: u8 = if (rules.copper_layers >= 2) rules.copper_layers else 0;
    for (rules.planes.declared) |pl| {
        if (!planeCarries(.{ .named = pl.net }, net_name)) continue;
        if (pl.index == 1) {
            try out.append(arena, .{ .net = .{ .named = pl.net }, .stack = pl.index, .side = .top, .track_layer = 0 });
        } else if (bottom != 0 and pl.index == bottom) {
            try out.append(arena, .{ .net = .{ .named = pl.net }, .stack = pl.index, .side = .bottom, .track_layer = 1 });
        } else {
            try out.append(arena, .{ .net = .{ .named = pl.net }, .stack = pl.index });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Honest plane connectivity for one net: compute the fill of every carrying
/// layer, then assign each query pad/via a CANONICAL component id, unifying ids
/// across layers through the through-hole pads and vias that bridge them. A pad
/// touching no kept component gets -1 (an isolated pad — an honest airwire).
/// A declared plane recedes around the user copper pours in `copper.zones` on
/// its layer (see `higherThanDeclared`), so a pad sitting under a user pour is
/// NOT credited to the plane it no longer touches.
/// Everything one net's plane-connect query needs beyond the board itself:
/// which net is asking, the pad queries and vias it carries, and the caller's
/// shared board-edge margin field. Bundled so `planeConnect` stays under the
/// function-size cap and the per-net sweep can hand the same field to every net.
pub const PlaneQuery = struct {
    net_name: []const u8,
    pads: []const PadQuery,
    vias: []const router.Via,
    base: ?EdgeField = null,
};

/// Already-computed carrying-layer fills for one net. Full DRC needs their
/// contours for topology and their labels for connectivity; retaining both
/// views lets those consumers share one rasterization.
pub const NetFills = struct {
    net_name: []const u8,
    layers: []const LayerSpec,
    fills: []const Fill,
};

/// Assign pads and vias to a net's retained fill components, applying the same
/// cross-layer through-feature union and dense component numbering as
/// `planeConnect`.
pub fn planeConnectPrepared(arena: std.mem.Allocator, q: PlaneQuery, prepared: NetFills) std.mem.Allocator.Error!Join {
    return joinPlaneFills(arena, q, prepared.layers, prepared.fills);
}

/// Fuse one net's pads, tracks and vias through the plane fills that carry
/// that net, answering which same-net copper lands in the same kept component
/// and which pads the plane actually connects. `q` carries the net's name, pad
/// queries, vias and the caller's shared edge-margin field (`PlaneQuery`).
pub fn planeConnect(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    q: PlaneQuery,
) std.mem.Allocator.Error!Join {
    const layers = try carryingLayers(arena, placement.rules, q.net_name);
    // Most nets are not plane-carried. Preserve the empty-layer fast path
    // before constructing the board-wide edge field: on Barracuda that raster
    // costs roughly 150 ms and must not be repeated for every ordinary net.
    if (layers.len == 0) return joinPlaneFills(arena, q, layers, &.{});
    const fills = try arena.alloc(Fill, layers.len);
    // Every carrying layer rasters the SAME board on the SAME lattice, so the
    // outline walk that seeds each cell's edge margin is done once here and
    // copied per layer. Connectivity traces the final boundary just long
    // enough to clear repaired-away copper, then omits it from the returned
    // sampling fill.
    // `q.base` is the caller's shared field — the net-open sweep calls this per
    // NET, so without it the outline walk repeats for every net on the board.
    const base_eff = if (q.base) |b| b else try edgeField(arena, placement);
    for (layers, 0..) |spec, l| {
        var s = spec;
        // The plane recedes around user pours on its own layer, so connectivity
        // sees the same copper the fill/Gerber emit. An INNER plane has no
        // track_layer and no user zone can sit on a plane-claimed layer, so it
        // is left untouched.
        if (s.track_layer) |tl| s.higher = try higherThanDeclared(arena, copper.zones, tl, s.net);
        fills[l] = try computeFill(arena, placement, copper, s, .{ .base = base_eff, .contours = false });
    }
    return joinPlaneFills(arena, q, layers, fills);
}

fn joinPlaneFills(arena: std.mem.Allocator, q: PlaneQuery, layers: []const LayerSpec, fills: []const Fill) std.mem.Allocator.Error!Join {
    const pad_comp = try arena.alloc(i32, q.pads.len);
    const via_comp = try arena.alloc(i32, q.vias.len);
    @memset(pad_comp, -1);
    @memset(via_comp, -1);
    if (layers.len == 0) return .{ .pad_comp = pad_comp, .via_comp = via_comp, .n_comp = 0, .coarsened = false };

    // Global component ids are (layer_offset[l] + local), unified by a
    // union-find so a through pad / via that lands in two layers' components
    // fuses them.
    var total: usize = 0;
    const offset = try arena.alloc(usize, layers.len);
    var coarsened = false;
    for (fills, 0..) |fill, l| {
        offset[l] = total;
        total += fill.n_comp;
        coarsened = coarsened or fill.coarsened;
    }
    const uf = try arena.alloc(usize, total);
    for (uf, 0..) |*u, i| u.* = i;

    assignPads(q.pads, layers, fills, offset, uf, pad_comp);
    assignVias(q.vias, layers, fills, offset, uf, via_comp);
    const n = denseRoots(arena, uf, pad_comp, via_comp);
    return .{ .pad_comp = pad_comp, .via_comp = via_comp, .n_comp = n, .coarsened = coarsened };
}

fn joinPadComponent(component: i32, layer_offset: usize, uf: []usize, first: *i32) void {
    if (component < 0) return;
    const gid: i32 = @intCast(layer_offset + @as(usize, @intCast(component)));
    if (first.* < 0) first.* = gid else ufUnite(uf, @intCast(first.*), @intCast(gid));
}

fn assignCustomPad(fill: Fill, q: PadQuery, layer_offset: usize, uf: []usize, first: *i32) void {
    joinPadComponent(fill.componentAt(q.cx, q.cy), layer_offset, uf, first);
    const f = fill.frame;
    if (!(f.pitch > 0) or f.nx == 0 or f.ny == 0) return;
    const fi0 = @max(@floor((q.shape.x0 - f.minx) / f.pitch), 0);
    const fj0 = @max(@floor((q.shape.y0 - f.miny) / f.pitch), 0);
    const fi1 = @min(@floor((q.shape.x1 - f.minx) / f.pitch), @as(f64, @floatFromInt(f.nx - 1)));
    const fj1 = @min(@floor((q.shape.y1 - f.miny) / f.pitch), @as(f64, @floatFromInt(f.ny - 1)));
    const col0 = numeric.checkedInt(usize, fi0) orelse return;
    const row0 = numeric.checkedInt(usize, fj0) orelse return;
    const col1 = numeric.checkedInt(usize, fi1) orelse return;
    const row1 = numeric.checkedInt(usize, fj1) orelse return;
    if (col0 > col1 or row0 > row1) return;
    for (row0..row1 + 1) |j| {
        for (col0..col1 + 1) |i| {
            const point = [2]f64{
                f.minx + (@as(f64, @floatFromInt(i)) + 0.5) * f.pitch,
                f.miny + (@as(f64, @floatFromInt(j)) + 0.5) * f.pitch,
            };
            if (pad_shape.pointDist(q.shape.x0, q.shape.y0, q.shape.x1, q.shape.y1, q.shape.poly, point[0], point[1], std.math.inf(f64)) != 0) continue;
            joinPadComponent(fill.componentAt(point[0], point[1]), layer_offset, uf, first);
        }
    }
}

fn assignPads(pads: []const PadQuery, layers: []const LayerSpec, fills: []const Fill, offset: []const usize, uf: []usize, out: []i32) void {
    for (pads, 0..) |q, pi| {
        var first: i32 = -1;
        for (layers, 0..) |spec, l| {
            if (!padPresent(q, spec)) continue;
            if (q.shape.poly.len >= 3) {
                assignCustomPad(fills[l], q, offset[l], uf, &first);
                continue;
            }
            const c = fills[l].padComponent(q.cx, q.cy, q.shape.x0, q.shape.y0, q.shape.x1, q.shape.y1);
            joinPadComponent(c, offset[l], uf, &first);
        }
        out[pi] = first;
    }
}

fn assignVias(vias: []const router.Via, layers: []const LayerSpec, fills: []const Fill, offset: []const usize, uf: []usize, out: []i32) void {
    for (vias, 0..) |v, vi| {
        var first: i32 = -1;
        for (layers, 0..) |_, l| {
            const c = fills[l].componentAt(v.x, v.y);
            if (c < 0) continue;
            const gid: i32 = @intCast(offset[l] + @as(usize, @intCast(c)));
            if (first < 0) first = gid else ufUnite(uf, @intCast(first), @intCast(gid));
        }
        out[vi] = first;
    }
}

/// Is a pad present on `spec`'s layer? Outer: its own side's SMD, or any thru
/// pad. Inner: only thru pads.
fn padPresent(q: PadQuery, spec: LayerSpec) bool {
    if (spec.side) |s| return q.thru or q.side == s;
    return q.thru;
}

/// Canonicalise every assigned id through the union-find and renumber the live
/// roots to a dense 0..n. Returns n.
fn denseRoots(arena: std.mem.Allocator, uf: []usize, pad_comp: []i32, via_comp: []i32) usize {
    var map = std.AutoHashMapUnmanaged(usize, i32).empty;
    var n: i32 = 0;
    for ([_][]i32{ pad_comp, via_comp }) |slice| {
        for (slice) |*id| {
            if (id.* < 0) continue;
            const root = ufFind(uf, @intCast(id.*));
            const gop = map.getOrPut(arena, root) catch {
                id.* = 0;
                continue;
            };
            if (!gop.found_existing) {
                gop.value_ptr.* = n;
                n += 1;
            }
            id.* = gop.value_ptr.*;
        }
    }
    return @intCast(n);
}

fn ufFind(uf: []usize, i: usize) usize {
    var r = i;
    while (uf[r] != r) r = uf[r];
    var x = i;
    while (uf[x] != r) {
        const nx = uf[x];
        uf[x] = r;
        x = nx;
    }
    return r;
}

fn ufUnite(uf: []usize, a: usize, b: usize) void {
    const ra = ufFind(uf, a);
    const rb = ufFind(uf, b);
    if (ra != rb) uf[rb] = ra;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const flat_netlist = @import("../flat_netlist.zig");

// `polySignedInset` is a hot-path re-implementation of `outline.signedInset`
// with a SINGLE hypot (argmin of the per-edge squared distances, hypot only on
// the winner) — the pour's byte-identical field rests on it being exactly equal.
// Pin that across inside / outside / edge-proximate points of a non-axis-aligned
// quad, where both the min-distance edge and the ray-cast sign are exercised. An
// exact `expectEqual` (not approx) is deliberate: an off-by-a-ULP re-derivation
// would silently shift the f32 margin field and the emitted contours.
test "polySignedInset matches outline.signedInset bit-for-bit" {
    const poly = [_][2]f64{ .{ 1.0, 0.5 }, .{ 9.3, 1.1 }, .{ 8.7, 7.9 }, .{ 0.4, 6.2 } };
    const samples = [_][2]f64{
        .{ 5.0, 4.0 },
        .{ 0.2, 0.2 },
        .{ 9.9, 9.9 },
        .{ 1.05, 3.0 },
        .{ 5.0, 0.7 },
        .{ 8.9, 4.0 },
        .{ 5.0, 7.0 },
        .{ -1.0, 4.0 },
        .{ 4.999, 3.999 },
        .{ 2.3, 6.05 },
    };
    for (samples) |s| {
        try testing.expectEqual(outline.signedInset(&poly, s[0], s[1]), polySignedInset(poly[0..], s[0], s[1]));
    }
}

// The pitch guard is load-bearing: a zero pitch would divide by zero and feed
// @ceil(inf) into @intFromFloat. (The sibling `extent <= 0` term is equivalent
// under ≤ vs <, since ⌈0/pitch⌉ is also 0 — only the pitch guard is testable.)
test "gridCount guards a non-positive pitch against division by zero" {
    try testing.expectEqual(@as(usize, 0), gridCount(10, 0));
    // A normal extent/pitch counts the covering cells: ⌈10/2⌉ = 5.
    try testing.expectEqual(@as(usize, 5), gridCount(10, 2));
}

// spec: placement/pour - gridCount collapses a non-finite extent to zero cells instead of an unchecked narrowing
test "gridCount collapses a non-finite extent to zero cells" {
    // A NaN/±inf extent (e.g. a corrupt board bound) reaches the count after the
    // extent<=0 guard; numeric.toCount collapses it to 0 rather than feeding a
    // bare @intFromFloat, which would be UB in the safety-off prod build.
    try testing.expectEqual(@as(usize, 0), gridCount(std.math.inf(f64), 0.1));
    try testing.expectEqual(@as(usize, 0), gridCount(std.math.nan(f64), 0.1));
}

test "emitCellEdges emits the bottom boundary edge for a cell empty below" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // 3×3 label grid (component 1). Cell (1,1) has solid top/left/right
    // neighbours and an EMPTY cell below (index 7). So exactly one boundary
    // edge is emitted: the bottom, dir .e, between vertices (2*w+1)=9 and 10.
    // The `jj + 1` neighbour offset and the vertex-index arithmetic must all
    // hold — a +→− flip either checks the wrong neighbour or misnumbers a vertex.
    var labels = [_]i32{ 0, 1, 0, 1, 1, 1, 0, 0, 0 };
    const g = Grid{ .minx = 0, .miny = 0, .pitch = 1, .nx = 3, .ny = 3, .labels = &labels, .margin = &.{}, .iso = iso_guard };
    var edges: std.ArrayList(Edge) = .empty;
    try emitCellEdges(arena, &edges, g, 1, 1, 1, 4);
    try testing.expectEqual(@as(usize, 1), edges.items.len);
    try testing.expectEqual(Dir.e, edges.items[0].dir);
    try testing.expectEqual(@as(u32, 9), edges.items[0].a);
    try testing.expectEqual(@as(u32, 10), edges.items[0].b);
}

// spec: placement/pour - contour tracing closes every boundary, decomposes pinched walks into strict simple regions, allows only zero-area sibling-hole tangency, and fails closed on irreparable topology
test "contour topology rejects an incomplete boundary stitch" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // 0->1->2 has no outgoing edge at 2, so it is an open chain rather than a
    // closed cell boundary. The old stitcher returned both edges as a polygon.
    var edges = [_]Edge{
        .{ .a = 0, .b = 1, .dir = .e, .cell = 0 },
        .{ .a = 1, .b = 2, .dir = .e, .cell = 1 },
    };
    var by_tail: TailMap = .empty;
    try indexTails(arena, &by_tail, &edges);
    try testing.expectError(error.InvalidBoundary, stitchLoop(arena, &edges, &by_tail, 0));
}

test "contour topology leaves a diagonal saddle as one simple open notch" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // One 4-connected C-shaped component has diagonal copper cells at the
    // centre saddle. Copper lies on the LEFT of every y-down boundary edge, so
    // left-first pairing keeps those diagonal cells disconnected at the saddle
    // and leaves the empty centre joined to the exterior by one simple notch.
    var labels = [_]i32{
        -1, -1, -1, -1,
        0,  0,  -1, -1,
        0,  -1, 0,  -1,
        0,  0,  0,  -1,
    };
    var margin = [_]f32{
        -1, -1, -1, -1,
        1,  1,  -1, -1,
        1,  -1, 1,  -1,
        1,  1,  1,  -1,
    };
    const g = Grid{ .minx = 0, .miny = 0, .pitch = 1, .nx = 4, .ny = 4, .labels = &labels, .margin = &margin, .iso = 0 };
    var edges: std.ArrayList(Edge) = .empty;
    try collectBoundaryEdges(arena, &edges, g, 0);
    var by_tail: TailMap = .empty;
    try indexTails(arena, &by_tail, edges.items);
    var repair_clears: std.ArrayList(RepairClear) = .empty;
    const loops = try realiseLoops(arena, g, edges.items, &by_tail, &repair_clears);
    try testing.expectEqual(@as(usize, 1), loops.len);
    try testing.expectEqual(@as(usize, 0), repair_clears.items.len);
    for (loops) |loop| try testing.expect(try validClosedContour(arena, loop));
}

test "contour topology removes paired iso duplicates before simplification" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const paired = [_][2]f64{
        .{ 0, 0 }, .{ 0, 0 },
        .{ 2, 0 }, .{ 2, 0 },
        .{ 2, 2 }, .{ 2, 2 },
        .{ 0, 2 }, .{ 0, 2 },
    };
    const final = try finalizeContour(arena, &paired, 0);
    try testing.expectEqual(@as(usize, 4), final.len);
    try testing.expect(try validClosedContour(arena, final));
}

test "contour topology rejects contact between an outer and its hole" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const outer = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const clear_hole = [_][2]f64{ .{ 2, 2 }, .{ 2, 4 }, .{ 4, 4 }, .{ 4, 2 } };
    const tangent_hole = [_][2]f64{ .{ 0, 5 }, .{ 2, 6 }, .{ 2, 4 } };
    const clear = TracedComponent{ .outer = &outer, .holes = &.{&clear_hole} };
    const tangent = TracedComponent{ .outer = &outer, .holes = &.{&tangent_hole} };

    try testing.expect(try tracedComponentValid(arena, clear));
    try testing.expect(!try tracedComponentValid(arena, tangent));
}

test "contour topology allows sibling point tangency but rejects overlap and nesting" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const outer = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const left = [_][2]f64{ .{ 2, 2 }, .{ 2, 5 }, .{ 5, 5 }, .{ 5, 2 } };
    const tangent = [_][2]f64{ .{ 5, 5 }, .{ 5, 8 }, .{ 8, 8 }, .{ 8, 5 } };
    const crossing = [_][2]f64{ .{ 4, 3 }, .{ 4, 7 }, .{ 7, 7 }, .{ 7, 3 } };
    const nested = [_][2]f64{ .{ 3, 3 }, .{ 3, 4 }, .{ 4, 4 }, .{ 4, 3 } };

    try testing.expect(try tracedComponentValid(arena, .{ .outer = &outer, .holes = &.{ &left, &tangent } }));
    try testing.expect(!try tracedComponentValid(arena, .{ .outer = &outer, .holes = &.{ &left, &crossing } }));
    try testing.expect(!try tracedComponentValid(arena, .{ .outer = &outer, .holes = &.{ &left, &nested } }));
}

test "contour topology opens a separately traced tangent hole" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const outer = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    // Opposite winding to `outer`, with its left point tangent to the outer's
    // left edge. This is the separate-loop form of the same raster saddle as
    // the repeated-vertex fixture below.
    const hole = [_][2]f64{ .{ 0, 2 }, .{ 1, 3 }, .{ 2, 2 }, .{ 1, 1 } };
    const component = TracedComponent{ .outer = &outer, .holes = &.{&hole} };
    var repair_clears: std.ArrayList(RepairClear) = .empty;
    const repaired = try repairTangentHoles(arena, &.{component}, 1, &repair_clears);

    try testing.expectEqual(@as(usize, 1), repaired.len);
    try testing.expectEqual(@as(usize, 1), repair_clears.items.len);
    try testing.expectEqual(@as(usize, 0), repaired[0].holes.len);
    try testing.expect(try tracedComponentValid(arena, repaired[0]));
    const original_area2 = @abs(outline.signedArea2(&outer) + outline.signedArea2(&hole));
    const repaired_area2 = @abs(outline.signedArea2(repaired[0].outer));
    try testing.expect(repaired_area2 <= original_area2 + 1e-9);
    try testing.expect(original_area2 - repaired_area2 <= 2 + 1e-9);
}

test "contour topology opens an opposite-winding tangent pocket conservatively" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A clearance diamond touches the outer square at P. The combined non-zero
    // winding walk repeats P; the repair removes at most one pitch-squared of
    // copper per eliminated copy and emits one notch with no retrace/touch.
    const p = [2]f64{ 0, 2 };
    const pinched = [_][2]f64{
        p,
        .{ 1, 1 },
        .{ 2, 2 },
        .{ 1, 3 },
        p,
        .{ 0, 4 },
        .{ 4, 4 },
        .{ 4, 0 },
        .{ 0, 0 },
    };
    var loops: std.ArrayList(Contour) = .empty;
    var repair_clears: std.ArrayList(RepairClear) = .empty;
    try resolvePinchedWalk(arena, &pinched, 1, &loops, &repair_clears);
    try testing.expectEqual(@as(usize, 1), loops.items.len);
    try testing.expectEqual(@as(usize, 1), repair_clears.items.len);
    const repaired = loops.items[0];
    try testing.expect(try validClosedContour(arena, repaired));
    const removed_area2 = @abs(outline.signedArea2(&pinched)) - @abs(outline.signedArea2(repaired));
    try testing.expect(removed_area2 >= -1e-9);
    try testing.expect(removed_area2 <= 2 + 1e-9);
}

// spec: placement/pour - an opposite-winding pinch repair clears every raster cell intersecting its removed wedge, so connectivity cannot credit copper absent from the final contour
// spec: placement/pour - a repair-cleared articulation cell relabels its surviving sides as different fill components while previously dropped cells stay dropped
test "opposite-winding notch repair clears removed-wedge membership" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const p = [2]f64{ 0, 2 };
    const pinched = [_][2]f64{
        p,
        .{ 1, 1 },
        .{ 2, 2 },
        .{ 1, 3 },
        p,
        .{ 0, 4 },
        .{ 4, 4 },
        .{ 4, 0 },
        .{ 0, 0 },
    };
    var loops: std.ArrayList(Contour) = .empty;
    var repair_clears: std.ArrayList(RepairClear) = .empty;
    try resolvePinchedWalk(arena, &pinched, 1, &loops, &repair_clears);
    try testing.expectEqual(@as(usize, 1), repair_clears.items.len);

    var labels: [16]i32 = @splat(2);
    const g = Grid{ .minx = 0, .miny = 0, .pitch = 1, .nx = 4, .ny = 4, .labels = &labels, .margin = &.{}, .iso = 0 };
    const removed_wedge = [2]f64{ 0.2, 1 };
    try testing.expect(polySignedInset(loops.items[0], removed_wedge[0], removed_wedge[1]) < 0);
    clearRepairLabels(g, repair_clears.items);

    const fill = Fill{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 4, .ny = 4 },
        .labels = &labels,
        .n_comp = 3,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
    try testing.expect(fill.componentAt(removed_wedge[0], removed_wedge[1]) < 0);
    // The triangle only touches this neighbouring cell at one vertex; the SAT
    // clear must not turn boundary contact into a full extra-cell removal.
    try testing.expectEqual(@as(i32, 2), fill.componentAt(1.5, 0.5));
    try testing.expectEqual(@as(i32, 2), fill.componentAt(3, 2));

    // At a coarser sampling pitch the same removed triangle occupies exactly
    // the middle cell of a three-cell bridge. Clearing it must split the two
    // surviving sides into distinct component ids, not leave the old id 2 on
    // both and electrically join them across empty space.
    var bridge_labels = [_]i32{ -1, 2, 2, 2 };
    const bridge_grid = Grid{ .minx = -4, .miny = 0, .pitch = 2, .nx = 4, .ny = 1, .labels = &bridge_labels, .margin = &.{}, .iso = 0 };
    clearRepairLabels(bridge_grid, repair_clears.items);
    try testing.expectEqual(@as(usize, 2), try relabelKeptAfterRepair(arena, bridge_grid));
    try testing.expectEqual(@as(i32, -1), bridge_labels[0]);
    try testing.expect(bridge_labels[1] >= 0);
    try testing.expectEqual(@as(i32, -1), bridge_labels[2]);
    try testing.expect(bridge_labels[3] >= 0);
    try testing.expect(bridge_labels[1] != bridge_labels[3]);
}

// spec: placement/pour - contour simplification and corner rounding fall back to the last strict simple boundary instead of emitting a crossing
test "contour topology falls back when Douglas-Peucker crosses a simple loop" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A simple narrow loop whose two low-deviation vertices are both discarded
    // at the production 0.01 mm tolerance. Their replacement chord crosses a
    // distant retained edge even though the source polygon is valid.
    const raw = [_][2]f64{
        .{ 0.19280, 0.06850 },
        .{ -0.07305, 0.07275 },
        .{ -0.05335, 0.09815 },
        .{ -0.12550, 0.15495 },
        .{ -0.06625, 0.04995 },
        .{ 0.03385, -0.10520 },
        .{ 0.05550, -0.12445 },
    };
    try testing.expect(try validClosedContour(arena, &raw));
    const folded = try simplify(arena, &raw, dp_tol);
    try testing.expect(outline.selfIntersects(folded));

    const final = try finalizeContour(arena, &raw, 0);
    try testing.expect(try validClosedContour(arena, final));
    try testing.expectEqualSlices([2]f64, &raw, final);
}

test "contour topology falls back when corner fillets cross a simple loop" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Local 45%-of-edge fillet clamps do not prevent an arc from meeting a
    // distant edge in a strongly concave polygon. Preserve the last simple
    // (sharp) contour when that non-local interaction occurs.
    const raw = [_][2]f64{
        .{ -3.4510, 1.0645 },
        .{ -1.4143, 0.5396 },
        .{ -4.5908, 1.6897 },
        .{ 2.9951, -2.5165 },
        .{ 0.6295, -0.0657 },
    };
    const simple = try simplify(arena, &raw, dp_tol);
    try testing.expect(try validClosedContour(arena, simple));
    const folded = try roundContour(arena, simple, 0.2);
    try testing.expect(outline.selfIntersects(folded));

    const final = try finalizeContour(arena, &raw, 0.2);
    try testing.expect(try validClosedContour(arena, final));
    try testing.expectEqualSlices([2]f64, simple, final);
}

test "contour topology rejects the known Barracuda Base clearance crossing" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Exact copper-bottom clearance region captured from Barracuda Base. It has
    // proper crossings at (192.307635, 81.186883) and
    // (209.191433, 85.692483), so it must never be accepted as a raw loop or
    // written as one ambiguous G36 region.
    const barracuda = [_][2]f64{
        .{ 187.3293, 79.2355 },
        .{ 187.4817, 79.3065 },
        .{ 190.3773, 79.3117 },
        .{ 193.0443, 81.9025 },
        .{ 199.6737, 86.7031 },
        .{ 207.8271, 86.7031 },
        .{ 209.8845, 85.1791 },
        .{ 210.0369, 85.102142 },
        .{ 210.3417, 85.094089 },
        .{ 210.4941, 85.1791 },
        .{ 210.5703, 85.2553 },
        .{ 210.573751, 85.7125 },
        .{ 209.9607, 85.8649 },
        .{ 209.8083, 85.7935 },
        .{ 209.6559, 85.7935 },
        .{ 194.5683, 82.5121 },
        .{ 190.1487, 79.9213 },
        .{ 187.4055, 79.9213 },
        .{ 187.2531, 80.001779 },
        .{ 186.9483, 80.002306 },
        .{ 186.7197, 79.3879 },
        .{ 186.8721, 79.235364 },
    };
    try testing.expect(outline.selfIntersects(&barracuda));
    try testing.expectError(error.InvalidBoundary, finalizeContour(arena, &barracuda, 0));
}

fn testPlacement(parts: []optimizer.Part, nets: []const flat_netlist.FlatNet, rules: optimizer.BoardRules) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 },
        .rules = rules,
    };
}

test "footprint copper-pour keepout carves the attached outer face" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const keep_poly = [_][2]f64{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    const keepouts = [_]geometry.CopperPourKeepout{.{ .side = .front, .poly = &keep_poly }};
    const pads = [_]geometry.Pad{.{ .number = "1", .x = -3, .y = 0, .w = 1, .h = 1, .thru = true }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "J1",
        .kind = .hub,
        .hw = 4,
        .hh = 4,
        .pads = &pads,
        .features = .{ .copper_pour_keepouts = &keepouts },
        .fallback = false,
        .x = 10,
        .y = 10,
        .rot = 45,
    }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &pins }};
    const placement = testPlacement(&parts, &nets, .{});

    const top = try compute(arena, placement, .{}, .{ .net = .{ .named = "GND" }, .side = .top, .track_layer = 0 });
    try testing.expect(top.contains(7, 10));
    try testing.expect(!top.contains(10, 10));

    const bottom = try compute(arena, placement, .{}, .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 });
    try testing.expect(bottom.contains(10, 10));
}

// spec: placement/pour - the configured minimum pour width erodes and regrows the fill, removing a connected neck narrower than the fabrication floor while restoring broad copper to its ordinary clearance boundary
test "minimum pour width removes a narrow neck" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const parts: []optimizer.Part = &.{};
    const nets: []flat_netlist.FlatNet = &.{};
    var rules = optimizer.BoardRules{};
    rules.design.pour.min_width = 3.0;
    const placement = testPlacement(parts, nets, rules);
    // Two broad chambers joined by a 2 mm square neck. A 3 mm finished-width
    // floor must drop the neck and leave two independent fill components.
    const poly = [_][2]f64{
        .{ 1, 1 },   .{ 9, 1 },   .{ 9, 9 },   .{ 11, 9 }, .{ 11, 1 }, .{ 19, 1 },
        .{ 19, 19 }, .{ 11, 19 }, .{ 11, 11 }, .{ 9, 11 }, .{ 9, 19 }, .{ 1, 19 },
    };
    const fill = try compute(arena, placement, .{}, zoneLayerSpec("GND", .bottom, 1, &poly));
    try testing.expectEqual(@as(usize, 2), fill.n_comp);
    try testing.expect(fill.contains(5, 5));
    try testing.expect(fill.contains(15, 15));
    try testing.expect(!fill.contains(10, 10));
    // The former implementation stopped after erosion, so even broad legal
    // copper vanished within half the floor of every boundary. Regrowth keeps
    // the chamber near its authored edge while still deleting the neck.
    try testing.expect(fill.contains(1.2, 5));
}

// spec: placement/power-routing - a power pour's effective minimum neck is raised above the board fabrication floor by the rail maximum and actual stack foil
test "power pour minimum follows the conservative rail envelope" {
    const foils = [_]impedance.Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.0152 },
        .{ .index = 3, .thickness_mm = 0.0152 },
        .{ .index = 4, .thickness_mm = 0.035 },
    };
    const rails = [_]@import("../eval/power_budget.zig").Rail{.{
        .net = "VDD",
        .load_max_a = 0.34,
        .any_max_load = true,
        .status = .no_source,
    }};
    var rules = optimizer.BoardRules{};
    rules.design.pour.min_width = 0.127;
    rules.physical.stack = .{ .layers = 4, .foils = &foils };
    rules.physical.rails = &rails;
    const placement = testPlacement(&.{}, &.{}, rules);
    const width = effectiveMinimumWidth(placement, .{ .net = .{ .named = "VDD" } });
    try testing.expect(width > 0.40 and width < 0.42);
    try testing.expectEqual(@as(f64, 0.127), effectiveMinimumWidth(placement, .{ .net = .ground }));
}

// spec: placement/pour - the configured pour corner radius fillets emitted contour corners
test "pour corner radius rounds emitted contour" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const parts: []optimizer.Part = &.{};
    const nets: []flat_netlist.FlatNet = &.{};
    const poly = [_][2]f64{ .{ 2, 2 }, .{ 18, 2 }, .{ 18, 18 }, .{ 2, 18 } };
    const sharp = testPlacement(parts, nets, .{});
    const rounded_rules = optimizer.BoardRules{ .design = .{ .pour = .{ .corner_radius = 1.0 } } };
    const rounded = testPlacement(parts, nets, rounded_rules);
    const sharp_fill = try compute(arena, sharp, .{}, zoneLayerSpec("GND", .bottom, 1, &poly));
    const rounded_fill = try compute(arena, rounded, .{}, zoneLayerSpec("GND", .bottom, 1, &poly));
    try testing.expectEqual(@as(usize, 1), sharp_fill.contours.len);
    try testing.expectEqual(@as(usize, 1), rounded_fill.contours.len);
    try testing.expect(rounded_fill.contours[0].len > sharp_fill.contours[0].len);
}

// spec: placement/pour - a seeded pour keeps its component and drops an unseeded orphan island
test "island removal keeps seeded components and drops orphans" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A GND pad on the bottom pour (seed) and, across a full-height VIN wall,
    // an unseeded right half. The right component must be dropped.
    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 10, .side = .bottom },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } });

    // A foreign VIN wall on the bottom layer splitting the board in two.
    const wall = [_]router.Track{.{ .x1 = 10, .y1 = -2, .x2 = 10, .y2 = 22, .layer = 1, .width = 0.5, .net = 1 }};
    const fill = try compute(arena, placement, .{ .tracks = &wall }, .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 });

    // Exactly one kept component (the left, seeded half); the right half orphan
    // is dropped, and it survives as a real polygon contour.
    try testing.expectEqual(@as(usize, 1), fill.n_comp);
    try testing.expect(fill.contours.len == 1);
    try testing.expect(fill.componentAt(3, 10) == 0); // seed side kept
    try testing.expect(fill.componentAt(17, 10) < 0); // orphan side dropped
}

// spec: placement/pour - a clipped user pour confines the fill to the drawn polygon, carves foreign copper, and keeps its region when no same-net seed lies inside
test "user-zone clip confines the fill, carves a foreign pad, and keeps an unseeded region" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A GND user pour drawn as a 10 mm square in the middle of a 20 mm board,
    // top layer. It has NO same-net GND copper inside — just one FOREIGN VIN SMD
    // pad dead centre. keep_unseeded must still render the region; the foreign
    // pad must be carved out; and the clip must confine the copper to the drawn
    // square (nothing poured out at the board's own corner).
    const vin_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &vin_pad, .fallback = false, .x = 10, .y = 10, .side = .top },
    };
    const vin_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "VIN", .pins = &vin_pins },
    };
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &.{}, .copper_layers = 2 });

    const clip = [_][2]f64{ .{ 5, 5 }, .{ 15, 5 }, .{ 15, 15 }, .{ 5, 15 } };
    const fill = try compute(arena, placement, .{}, userZoneSpec("GND", .top, &clip));

    // The unseeded pour still renders (keep_unseeded), so it has real copper.
    try testing.expect(fill.contours.len >= 1);
    // Interior of the clip, clear of the foreign pad → filled copper.
    try testing.expect(fill.componentAt(6, 6) >= 0);
    // The foreign VIN pad centre is carved out of the ground copper.
    try testing.expect(fill.componentAt(10, 10) < 0);
    // Outside the drawn clip (but inside the board) → NOT poured; the clip
    // confines the fill to the user's polygon.
    try testing.expect(fill.componentAt(2, 2) < 0);
    try testing.expect(fill.componentAt(18, 18) < 0);
}

// spec: placement/pour - a clipped user pour skips foreign-copper stamp windows wholly outside the clip's boundary halo
test "clip active bounds retain touching stamp windows and reject distant ones" {
    const clip = [_][2]f64{ .{ 5, 5 }, .{ 15, 5 }, .{ 15, 15 }, .{ 5, 15 } };
    const g = Grid{
        .minx = 0,
        .miny = 0,
        .pitch = 0.1,
        .nx = 200,
        .ny = 200,
        .labels = &.{},
        .margin = &.{},
        .iso = 0,
    };
    const active = foreignActiveBounds(g, &clip);
    // The active box is the clip plus the same four-cell halo `clipMargin`
    // evaluates exactly: [4.6, 4.6]..[15.4, 15.4].
    try testing.expect(stampWindowActive(active, 15.4, 7, 16, 8));
    try testing.expect(!stampWindowActive(active, 15.400001, 7, 16, 8));
    try testing.expect(!stampWindowActive(active, -20, -20, -10, -10));
    // A declared/full-face pour has no clip cull at all.
    try testing.expect(stampWindowActive(foreignActiveBounds(g, &.{}), -20, -20, -10, -10));
}

// spec: placement/pour - native routed arcs carve their exact directed envelope and suppress only stored implementation chords with matching layer, net, and width
test "native arc stamp follows the directed circle instead of its chord" {
    var labels: [10_000]i32 = @splat(-1);
    var margin: [10_000]f32 = @splat(100);
    const g = Grid{ .minx = 0, .miny = 0, .pitch = 0.1, .nx = 100, .ny = 100, .labels = &labels, .margin = &margin, .iso = 0 };
    const arc = router.Arc{
        .p1 = .{ 7, 5 },
        .pm = .{ 6.414213562, 6.414213562 },
        .p2 = .{ 5, 7 },
        .layer = 0,
        .width = 0.2,
        .net = 1,
    };
    stampArcWithin(g, null, arc, 0.25);

    const curved = cellRange(g, arc.pm[0], arc.pm[1]);
    const chord = cellRange(g, 6, 6);
    try testing.expect(margin[curved[1] * g.nx + curved[0]] < 0);
    try testing.expectEqual(@as(f32, 100), margin[chord[1] * g.nx + chord[0]]);

    const owned = router.Track{ .x1 = arc.p1[0], .y1 = arc.p1[1], .x2 = arc.pm[0], .y2 = arc.pm[1], .layer = arc.layer, .width = arc.width, .net = arc.net };
    var wider = owned;
    wider.width *= 2;
    try testing.expect(nativeArcOwnsTrack(&.{arc}, owned));
    try testing.expect(!nativeArcOwnsTrack(&.{arc}, wider));
}

// spec: placement/pour - a small drawn zone lands its copper edge on the clip boundary no matter how much board lies outside it
test "a corner user zone keeps an exact clip boundary" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A 4 mm square drawn in the corner of a 20 mm board: 96% of the raster is
    // outside the zone's bounding box, which is the part the clip walk skips.
    // The skipping is only sound if the kept/blocked edge still falls exactly
    // where the polygon puts it, so probe both sides of that edge.
    const vin_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &vin_pad, .fallback = false, .x = 18, .y = 18, .side = .top },
    };
    const vin_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "VIN", .pins = &vin_pins },
    };
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &.{}, .copper_layers = 2 });

    const clip = [_][2]f64{ .{ 2, 2 }, .{ 6, 2 }, .{ 6, 6 }, .{ 2, 6 } };
    const fill = try compute(arena, placement, .{}, userZoneSpec("GND", .top, &clip));

    try testing.expect(fill.componentAt(4, 4) >= 0); // middle of the zone
    try testing.expect(fill.componentAt(5.6, 4) >= 0); // still inside, near the edge
    try testing.expect(fill.componentAt(6.2, 4) < 0); // just outside the drawn edge
    try testing.expect(fill.componentAt(4, 6.2) < 0);
    try testing.expect(fill.componentAt(15, 15) < 0); // far outside the zone's box
}

// spec: placement/pour - an inner-layer user pour carves a clipped fill, stamping only through-hole/via copper as foreign while SMD pads leave it intact
// spec: placement/pour - an inner-layer foreign plated through-hole carves its full copper land rather than only its drill
test "inner-layer user pour carves foreign plated copper and ignores an SMD pad" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // The barracuda case: an In2.Cu rail pour (signal index 2 on a 4-layer board
    // whose In1 is a GND plane). A same-net V_3V3A THROUGH-HOLE pad seeds it, a
    // foreign GND VIA and plated through-hole land are carved out (both reach
    // the inner layer), and a foreign GND SMD pad DIRECTLY OVER the pour is left
    // intact (SMD copper lives on the outer face, never touches an inner layer).
    const rail_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.9, .thru = true, .drill = 0.4 }};
    const smd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const foreign_thru_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.2, .h = 0.8, .thru = true, .drill = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.6, .hh = 0.6, .pads = &rail_pad, .fallback = false, .x = 10, .y = 10, .side = .top },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &smd_pad, .fallback = false, .x = 6, .y = 6, .side = .top },
        .{ .ref_des = "J1", .kind = .passive, .hw = 0.8, .hh = 0.8, .pads = &foreign_thru_pad, .fallback = false, .x = 8, .y = 8, .side = .top },
    };
    const rail_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const gnd_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "J1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "V_3V3A", .pins = &rail_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &.{"GND"}, .copper_layers = 4, .planes = .{ .declared = &planes } });

    // A foreign GND through-via inside the drawn square.
    const vias = [_]router.Via{.{ .x = 13, .y = 13, .dia = 0.6, .net = 1 }};
    const clip = [_][2]f64{ .{ 5, 5 }, .{ 15, 5 }, .{ 15, 15 }, .{ 5, 15 } };
    // Inner signal layer 2 (In2.Cu) → side=null, track_layer=2.
    const fill = try compute(arena, placement, .{ .vias = &vias }, zoneLayerSpec("V_3V3A", null, 2, &clip));

    // The same-net through-hole pad seeds the pour, so it renders.
    try testing.expect(fill.contours.len >= 1);
    try testing.expect(fill.componentAt(10, 10) >= 0);
    // The foreign GND via barrel is carved out of the inner copper.
    try testing.expect(fill.componentAt(13, 13) < 0);
    // A plated through-hole exposes its full copper land on the inner layer;
    // carving only the drill would leave an annular foreign-copper overlap.
    try testing.expect(fill.componentAt(8, 8) < 0);
    // The foreign GND SMD pad does NOT reach the inner layer → its footprint is
    // still poured copper (not carved).
    try testing.expect(fill.componentAt(6, 6) >= 0);
    // The clip confines the fill to the drawn polygon.
    try testing.expect(fill.componentAt(2, 2) < 0);
    try testing.expect(fill.componentAt(18, 18) < 0);
}

// Native routed arcs carve only pours on their matching outer or inner signal layer.
test "native arcs carve matching outer and inner pours without leaking across layers" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const seed_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true, .drill = 0.3 }};
    var parts = [_]optimizer.Part{.{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &seed_pad, .fallback = false, .x = 3, .y = 3, .side = .top }};
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{ .{ .name = "GND", .pins = &gnd_pins }, .{ .name = "VIN", .pins = &.{} } };
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &.{"GND"}, .copper_layers = 4 });
    const top_arc = router.Arc{
        .p1 = .{ 15, 11 },
        .pm = .{ 13.828427125, 13.828427125 },
        .p2 = .{ 11, 15 },
        .layer = 0,
        .width = 0.2,
        .net = 1,
    };
    const inner_arc = router.Arc{
        .p1 = top_arc.p1,
        .pm = top_arc.pm,
        .p2 = top_arc.p2,
        .layer = 2,
        .width = top_arc.width,
        .net = top_arc.net,
    };

    const top = try compute(arena, placement, .{ .arcs = &.{top_arc} }, outerSpec("GND", .top));
    const bottom = try compute(arena, placement, .{ .arcs = &.{top_arc} }, outerSpec("GND", .bottom));
    const clip = [_][2]f64{ .{ 1, 1 }, .{ 19, 1 }, .{ 19, 19 }, .{ 1, 19 } };
    const inner = try compute(arena, placement, .{ .arcs = &.{inner_arc} }, zoneLayerSpec("GND", null, 2, &clip));

    try testing.expect(top.integrity_ok and bottom.integrity_ok and inner.integrity_ok);
    try testing.expect(top.componentAt(top_arc.pm[0], top_arc.pm[1]) < 0);
    try testing.expect(bottom.componentAt(top_arc.pm[0], top_arc.pm[1]) >= 0);
    try testing.expect(inner.componentAt(inner_arc.pm[0], inner_arc.pm[1]) < 0);
}

// spec: placement/pour - a pour outranks a different-net overlapping pour only with strictly greater priority on the same layer
test "priority: outranks needs same layer, strictly greater priority, and a different net" {
    const hi_va = UserZone{ .net = "VA", .layer = 0, .poly = &.{}, .priority = 2 };
    const lo_vb = UserZone{ .net = "VB", .layer = 0, .poly = &.{}, .priority = 1 };
    try testing.expect(outranks(hi_va, lo_vb)); // higher rank, different net, same layer
    try testing.expect(!outranks(lo_vb, hi_va)); // the lower pour never clips the higher one
    const lo_va = UserZone{ .net = "VA", .layer = 0, .poly = &.{}, .priority = 1 };
    try testing.expect(!outranks(hi_va, lo_va)); // same net → the two pours merge, never clip
    const eq_vb = UserZone{ .net = "VB", .layer = 0, .poly = &.{}, .priority = 2 };
    try testing.expect(!outranks(hi_va, eq_vb)); // equal priority → left to short (must be ranked)
    const hi_other_layer = UserZone{ .net = "VA", .layer = 1, .poly = &.{}, .priority = 2 };
    try testing.expect(!outranks(hi_other_layer, lo_vb)); // a different layer can never short
}

// spec: placement/pour - a higher-priority overlapping pour knocks the lower pour back by the clearance so they do not short
test "priority: a higher-ranked overlapping pour clears a gap in the lower pour" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two overlapping TOP-layer user pours on a 20 mm board, different nets: a
    // big low-priority VA pour, and a small high-priority VB island sitting
    // inside it. VB outranks VA, so VA's fill must recede from VB by the pour
    // clearance — the short becomes a gap.
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "VA", .pins = &.{} },
        .{ .name = "VB", .pins = &.{} },
    };
    var parts = [_]optimizer.Part{};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &.{}, .copper_layers = 2 });

    const va_clip = [_][2]f64{ .{ 2, 2 }, .{ 18, 2 }, .{ 18, 18 }, .{ 2, 18 } };
    const vb_clip = [_][2]f64{ .{ 8, 8 }, .{ 12, 8 }, .{ 12, 12 }, .{ 8, 12 } };

    // Baseline: with NO priority (higher empty) VA pours straight through the VB
    // region — the unresolved short.
    const va_plain = try compute(arena, placement, .{}, userZoneSpec("VA", .top, &va_clip));
    try testing.expect(va_plain.componentAt(10, 10) >= 0);

    // With VB ranked above VA, VA is knocked back inside VB (a clearance gap)…
    var va_spec = userZoneSpec("VA", .top, &va_clip);
    const higher = [_][]const [2]f64{&vb_clip};
    va_spec.higher = &higher;
    const va = try compute(arena, placement, .{}, va_spec);
    try testing.expect(va.componentAt(10, 10) < 0); // deep inside VB → cleared
    // …while VA copper well away from VB is untouched.
    try testing.expect(va.componentAt(5, 10) >= 0);
    try testing.expect(va.componentAt(15, 10) >= 0);
    try testing.expect(va.componentAt(10, 5) >= 0);

    // VB itself (nothing outranks it) fills its own region solidly.
    const vb = try compute(arena, placement, .{}, userZoneSpec("VB", .top, &vb_clip));
    try testing.expect(vb.componentAt(10, 10) >= 0);
}

// spec: placement/pour - a declared pour recedes around any user pour on the same face whatever its priority
test "priority: a user zone clears the declared background pour at any priority" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // The barracuda B.Cu case: a declared `(pour bottom "GND")` background fill
    // with a hand-drawn rail pour of a DIFFERENT net sitting on the same face.
    // The declared pour is the blanket background, so the rail clears it at ANY
    // priority — including the 0 a freshly drawn pour starts at (else that pour
    // silently shorts to the background copper).
    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 10, .side = .bottom },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VRAIL", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } });

    const rail = [_][2]f64{ .{ 8, 8 }, .{ 12, 8 }, .{ 12, 12 }, .{ 8, 12 } };

    // Ranked (priority 1): the declared GND pour is cleared over the rail.
    const ranked = [_]UserZone{.{ .net = "VRAIL", .layer = 1, .poly = &rail, .priority = 1 }};
    var spec = outerSpec("GND", .bottom);
    spec.higher = try higherThanDeclared(arena, &ranked, 1, spec.net);
    const fill = try compute(arena, placement, .{}, spec);
    try testing.expect(fill.componentAt(10, 10) < 0); // rail region cleared out of GND
    try testing.expect(fill.componentAt(3, 10) >= 0); // GND intact away from the rail

    // Unranked (priority 0, a freshly drawn pour): still clears the background.
    const unranked = [_]UserZone{.{ .net = "VRAIL", .layer = 1, .poly = &rail, .priority = 0 }};
    var spec0 = outerSpec("GND", .bottom);
    spec0.higher = try higherThanDeclared(arena, &unranked, 1, spec0.net);
    const fill0 = try compute(arena, placement, .{}, spec0);
    try testing.expect(fill0.componentAt(10, 10) < 0);
    try testing.expect(fill0.componentAt(3, 10) >= 0);

    // A SAME-NET zone is not a foreign region — the copper merges, nothing clears.
    const same = [_]UserZone{.{ .net = "GND", .layer = 1, .poly = &rail, .priority = 5 }};
    var specs = outerSpec("GND", .bottom);
    specs.higher = try higherThanDeclared(arena, &same, 1, specs.net);
    const fills = try compute(arena, placement, .{}, specs);
    try testing.expect(fills.componentAt(10, 10) >= 0);
}

// spec: placement/pour - plane connectivity stops crediting a pad the declared plane receded from under a user pour
test "priority: planeConnect drops a pad sitting under a user pour" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Two GND pads on a declared bottom GND plane. The second sits inside a
    // VRAIL user pour, so the plane recedes there and can no longer connect it.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 10, .side = .bottom },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 10, .y = 10, .side = .bottom },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VRAIL", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } });

    const qpads = [_]PadQuery{
        .{ .cx = 3, .cy = 10, .shape = .{ .x0 = 2.7, .y0 = 9.7, .x1 = 3.3, .y1 = 10.3 }, .thru = false, .side = .bottom },
        .{ .cx = 10, .cy = 10, .shape = .{ .x0 = 9.7, .y0 = 9.7, .x1 = 10.3, .y1 = 10.3 }, .thru = false, .side = .bottom },
    };

    // No user pours: the solid plane connects both pads.
    const bare = try planeConnect(arena, placement, .{}, .{ .net_name = "GND", .pads = &qpads, .vias = &.{} });
    try testing.expectEqual(bare.pad_comp[0], bare.pad_comp[1]);
    try testing.expect(bare.pad_comp[1] >= 0);

    // A VRAIL pour over the second pad: the plane receded, so that pad is no
    // longer plane-connected (an honest airwire) while the first is untouched.
    const rail = [_][2]f64{ .{ 8, 8 }, .{ 12, 8 }, .{ 12, 12 }, .{ 8, 12 } };
    const zones = [_]UserZone{.{ .net = "VRAIL", .layer = 1, .poly = &rail, .priority = 1 }};
    const poured = try planeConnect(arena, placement, .{ .zones = &zones }, .{ .net_name = "GND", .pads = &qpads, .vias = &.{} });
    try testing.expect(poured.pad_comp[1] < 0);
    try testing.expect(poured.pad_comp[0] >= 0);
}

// spec: placement/pour - a point inside a higher-ranked overlapping pour is reported clipped from the lower pour
test "priority: clippedByHigher flags a point the higher pour owns" {
    const big = [_][2]f64{ .{ 2, 2 }, .{ 18, 2 }, .{ 18, 18 }, .{ 2, 18 } };
    const small = [_][2]f64{ .{ 8, 8 }, .{ 12, 8 }, .{ 12, 12 }, .{ 8, 12 } };
    const zones = [_]UserZone{
        .{ .net = "VA", .layer = 0, .poly = &big, .priority = 0 },
        .{ .net = "VB", .layer = 0, .poly = &small, .priority = 1 },
    };
    // Inside VB (the higher pour) → the lower VA (index 0) is clipped there.
    try testing.expect(clippedByHigher(&zones, 0, 10, 10));
    // Inside VA but outside VB → VA's copper still reaches it.
    try testing.expect(!clippedByHigher(&zones, 0, 4, 10));
    // The higher pour (index 1) is never clipped by the lower one.
    try testing.expect(!clippedByHigher(&zones, 1, 10, 10));
}

// spec: placement/pour - a foreign net-class clearance widens the ground-pour gap around its track
test "net-class clearance controls the foreign track pour gap" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &pad,
        .fallback = false,
        .x = 3,
        .y = 3,
        .side = .bottom,
    }};
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "RF", .pins = &.{} },
    };
    const net_rules = [_]optimizer.NetRule{ .{}, .{ .class = .{ .name = "rf-cpwg-50" }, .clearance = 0.8 } };
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    // The base gap this bottom face holds is STATED as the inner plane's 0.3
    // rather than inherited: the test measures a class clearance against the
    // base it widens, so the probe millimetres below belong to the fixture and
    // not to whichever default an outer face happens to resolve.
    const design = optimizer.DesignRules{ .pour = .{ .clearance_outer = 0.3 } };
    const placement = testPlacement(&parts, &nets, .{
        .design = design,
        .copper_layers = 2,
        .planes = .{ .declared = &planes },
        .net = &net_rules,
    });
    const rf = [_]router.Track{.{
        .x1 = 5,
        .y1 = 10,
        .x2 = 15,
        .y2 = 10,
        .layer = 1,
        .width = 0.4,
        .net = 1,
    }};
    const fill = try compute(
        arena,
        placement,
        .{ .tracks = &rf },
        .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 },
    );

    // One millimetre from the centreline is the 0.2 mm copper radius plus the
    // 0.8 mm class gap, so it is outside the pour. A farther point is copper.
    try testing.expect(fill.componentAt(10, 11.0) < 0);
    try testing.expect(fill.componentAt(10, 11.5) >= 0);
}

// spec: placement/pour - a grounded-coplanar ground gap overrides the generic ground-pour clearance without changing non-ground pours
test "grounded-coplanar gap controls only a ground pour opening" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &pad,
        .fallback = false,
        .x = 3,
        .y = 3,
        .side = .bottom,
    }};
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "RF", .pins = &.{} },
    };
    const net_rules = [_]optimizer.NetRule{
        .{},
        .{ .class = .{ .name = "rf-cpwg-50" }, .clearance = 0.127, .rf = .{
            .impedance = .{ .ohms = 50, .ground_gap_mm = 0.127 },
        } },
    };
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    // The generic gap this test contrasts the CPWG slot against is STATED as
    // the inner plane's 0.3 — the number the 0.45 mm probe below is derived
    // from — so the contrast stays the class rule versus the base, instead of
    // shifting with the tighter default an outer face would otherwise take.
    const design = optimizer.DesignRules{ .pour = .{ .clearance_outer = 0.3 } };
    const placement = testPlacement(&parts, &nets, .{
        .design = design,
        .copper_layers = 2,
        .planes = .{ .declared = &planes },
        .net = &net_rules,
    });
    const rf = [_]router.Track{.{
        .x1 = 5,
        .y1 = 10,
        .x2 = 15,
        .y2 = 10,
        .layer = 1,
        .width = 0.4,
        .net = 1,
    }};
    const ground_fill = try compute(
        arena,
        placement,
        .{ .tracks = &rf },
        .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 },
    );
    // At 0.45 mm from centre, the point clears 0.2 mm of trace + the 0.127 mm
    // CPWG slot (+ raster guard), but would still be inside the generic 0.3 mm
    // pour opening. This proves the lower, intentional ground-only path won.
    try testing.expect(ground_fill.componentAt(10, 10.45) >= 0);

    const rail_fill = try compute(
        arena,
        placement,
        .{ .tracks = &rf },
        .{ .net = .{ .named = "VCC" }, .side = .bottom, .track_layer = 1, .keep_unseeded = true },
    );
    try testing.expect(rail_fill.componentAt(10, 10.45) < 0);
}

// spec: placement/pour - the finished Gerber contour, rather than the raster's conservative guard offset, realizes the controlled-impedance ground gap
test "grounded-coplanar straight wall finishes at the authored ground gap" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &pad,
        .fallback = false,
        .x = 3,
        .y = 3,
        .side = .bottom,
    }};
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "RF", .pins = &.{} },
    };
    const gap: f64 = 0.1524;
    const rules = [_]optimizer.NetRule{
        .{},
        .{ .class = .{ .name = "rf-cpwg-50" }, .clearance = gap, .rf = .{
            .impedance = .{ .ohms = 50, .ground_gap_mm = gap },
        } },
    };
    const placement = testPlacement(&parts, &nets, .{
        .design = .{ .pour = .{ .clearance_outer = 0.3 } },
        .copper_layers = 2,
        .net = &rules,
    });
    const trace_width: f64 = 0.1899;
    const rf = [_]router.Track{.{
        .x1 = -1,
        .y1 = 10,
        .x2 = 21,
        .y2 = 10,
        .layer = 1,
        .width = trace_width,
        .net = 1,
    }};
    const samples = [_]@import("rf_path_solver.zig").Sample{
        .{ .at = .{ -1, 10 }, .s_mm = 0, .curvature = 0, .width_mm = trace_width },
        .{ .at = .{ 21, 10 }, .s_mm = 22, .curvature = 0, .width_mm = trace_width },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 1,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 1 },
    }};
    const fill = try compute(arena, placement, .{ .tracks = &rf, .rf_paths = &paths }, .{
        .net = .{ .named = "GND" },
        .side = .bottom,
        .track_layer = 1,
    });

    // C1 seeds the lower half. Find the long horizontal clearance wall in the
    // final contour and measure copper edge to poured-ground edge, exactly as
    // a CAM audit measures the resulting G36 region.
    var measured: ?f64 = null;
    for (fill.contours) |poly| {
        for (poly, 0..) |a, k| {
            const b = poly[(k + 1) % poly.len];
            const length = std.math.hypot(b[0] - a[0], b[1] - a[1]);
            const mx = (a[0] + b[0]) / 2;
            const my = (a[1] + b[1]) / 2;
            if (length < 5 or mx < 2 or mx > 18 or @abs(my - 10) > 0.5) continue;
            measured = @abs(my - 10) - trace_width / 2;
            break;
        }
    }
    try testing.expect(measured != null);
    try testing.expectApproxEqAbs(gap, measured.?, 1e-6);
}

// spec: placement/pour - an opt-in CPWG gap profile follows taper width and stops at its authored maximum
test "ground pour gap follows controlled-impedance taper up to its cap" {
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "RF", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{},
        .{ .class = .{ .name = "rf-cpwg-50" }, .clearance = 0.127, .rf = .{
            .impedance = .{ .ohms = 50, .ground_gap_mm = 0.127, .ground_gap_max_mm = 1.75 },
        } },
    };
    const dielectrics = [_]impedance.Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
        .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.4 },
        .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
    };
    const planes = [_]u8{ 2, 3 };
    const placement = testPlacement(&.{}, &nets, .{
        .net = &rules,
        .physical = .{ .board_thickness = 1.6, .stack = .{
            .layers = 4,
            .planes = &planes,
            .dielectrics = &dielectrics,
            .board_mm = 1.6,
        } },
    });
    const taper = router.Track{ .x1 = 5, .y1 = 10, .x2 = 10, .y2 = 10, .layer = 0, .width = 0.4, .net = 1 };
    const launch = router.Track{ .x1 = 10, .y1 = 10, .x2 = 15, .y2 = 10, .layer = 0, .width = 0.5588, .net = 1 };
    try testing.expectApproxEqAbs(@as(f64, 0.36121), trackPourClearance(placement, taper, .{ .named = "GND" }, 0.3), 0.0001);
    try testing.expectEqual(@as(f64, 1.75), trackPourClearance(placement, launch, .{ .named = "GND" }, 0.3));
    try testing.expectEqual(placement.rules.clearanceForNet(1, 0.3), trackPourClearance(placement, launch, .{ .named = "VCC" }, 0.3));
}

// spec: placement/pour - restored variable-width RF paths carve their exact swept taper polygon instead of the compact constant-width editor handle
test "a pour opening follows a restored taper from its wide edge to its narrow edge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &pad,
        .fallback = false,
        .x = 3,
        .y = 3,
        .side = .bottom,
    }};
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "RF", .pins = &.{} },
    };
    const placement = testPlacement(&parts, &nets, .{
        .design = .{ .pour = .{ .clearance_outer = 0.3 } },
        .copper_layers = 2,
        .net = &.{ .{}, .{} },
    });
    const samples = [_]@import("rf_path_solver.zig").Sample{
        .{ .at = .{ 5, 10 }, .s_mm = 0, .curvature = 0, .width_mm = 2 },
        .{ .at = .{ 15, 10 }, .s_mm = 10, .curvature = 0, .width_mm = 0.2 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 1,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 1 },
    }};
    const handle = [_]router.Track{.{
        .x1 = 5,
        .y1 = 10,
        .x2 = 15,
        .y2 = 10,
        .layer = 1,
        .width = 0.2,
        .net = 1,
    }};
    const fill = try compute(arena, placement, .{ .tracks = &handle, .rf_paths = &paths }, .{
        .net = .{ .named = "GND" },
        .side = .bottom,
        .track_layer = 1,
    });
    try testing.expect(fill.componentAt(6, 10.8) < 0);
    try testing.expect(fill.componentAt(14, 10.8) >= 0);
}

// spec: placement/pour - a bottom CPWG gap uses the bottom physical stackup on multilayer boards
test "bottom CPWG gap uses the bottom physical stackup" {
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "RF", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{},
        .{ .class = .{ .name = "rf-cpwg-50" }, .clearance = 0.127, .rf = .{
            .impedance = .{ .ohms = 50, .ground_gap_mm = 0.127, .ground_gap_max_mm = 1.75 },
        } },
    };
    const dielectrics = [_]impedance.Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.0994, .er = 4.4 },
        .{ .after_layer = 5, .thickness_mm = 0.0994, .er = 4.4 },
    };
    const physical_planes = [_]u8{ 2, 5 };
    const plane_rows = [_]optimizer.PlaneAt{
        .{ .index = 2, .net = "GND" },
        .{ .index = 5, .net = "GND" },
    };
    const placement = testPlacement(&.{}, &nets, .{
        .net = &rules,
        .plane_nets = &.{},
        .copper_layers = 6,
        .planes = .{ .declared = &plane_rows },
        .physical = .{ .board_thickness = 1.6, .stack = .{
            .layers = 6,
            .planes = &physical_planes,
            .dielectrics = &dielectrics,
            .board_mm = 1.6,
        } },
    });
    const bottom = router.Track{ .x1 = 5, .y1 = 10, .x2 = 10, .y2 = 10, .layer = 1, .width = 0.17098977764861645, .net = 1 };
    try testing.expectApproxEqAbs(@as(f64, 0.127), trackPourClearance(placement, bottom, .{ .named = "GND" }, 0.3), 0.0001);
}

// spec: placement/pour - a single-ended controlled-impedance via gets the same stackup-derived antipad clearance on every foreign pour
test "controlled-impedance via uses a stackup-derived plane clearance" {
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "RF", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{},
        .{ .class = .{ .name = "rf-cpwg-50" }, .clearance = 0.127, .rf = .{
            .impedance = .{ .ohms = 50, .ground_gap_mm = 0.127 },
        } },
    };
    const dielectrics = [_]@import("impedance.zig").Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
        .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.4 },
        .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
    };
    const placement = testPlacement(&.{}, &nets, .{
        .net = &rules,
        .physical = .{ .board_thickness = 1.6, .stack = .{
            .layers = 4,
            .dielectrics = &dielectrics,
            .board_mm = 1.6,
        } },
    });
    const via = router.Via{ .x = 10, .y = 10, .dia = 0.4, .drill = 0.2, .net = 1 };

    const ground_gap = viaPlaneClearance(placement, via, .{ .named = "GND" }, 0.3);
    const rail_gap = viaPlaneClearance(placement, via, .{ .named = "VCC" }, 0.3);
    try testing.expectApproxEqAbs(@as(f64, 0.1368), ground_gap, 0.001);
    try testing.expectApproxEqAbs(ground_gap, rail_gap, 1e-12);
    try testing.expect(ground_gap > placement.rules.design.clearance);
    try testing.expect(ground_gap < placement.rules.design.pour_clearance);
}

// spec: placement/pour - a max-freq via with no authored impedance target synthesizes its antipad at the 50 ohm default
test "max-freq via with no impedance target antipads at the 50 ohm default" {
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "RF", .pins = &.{} },
    };
    // The class states only the physical fact — 12 GHz — with no (impedance …)
    // target, the way barracuda's rf classes author their hand-computed width.
    const rules = [_]optimizer.NetRule{
        .{},
        .{ .class = .{ .name = "rf" }, .clearance = 0.127, .rf = .{ .max_freq_hz = 12e9 } },
    };
    const dielectrics = [_]@import("impedance.zig").Dielectric{
        .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
        .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.4 },
        .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
    };
    const placement = testPlacement(&.{}, &nets, .{
        .net = &rules,
        .physical = .{ .board_thickness = 1.6, .stack = .{
            .layers = 4,
            .dielectrics = &dielectrics,
            .board_mm = 1.6,
        } },
    });
    const via = router.Via{ .x = 10, .y = 10, .dia = 0.4, .drill = 0.2, .net = 1 };

    // Same buildup and via as the authored-50-ohm test above ⇒ the same
    // synthesized antipad, without the class restating the universal number.
    const gap = viaPlaneClearance(placement, via, .{ .named = "GND" }, 0.3);
    try testing.expectApproxEqAbs(@as(f64, 0.1368), gap, 0.001);
    try testing.expect(gap > placement.rules.design.clearance);
}

/// A bottom GND pour split by a foreign VIN diagonal spanning the board edge-to-
/// edge (its keep-out band dents the OUTER contour; an interior capsule would
/// trace as a dropped hole), plus a foreign VIN via. Shared by the clearance +
/// smoothness contour tests. The GND seed keeps the x>y triangle.
fn diagonalTrackFill(arena: std.mem.Allocator, parts: []optimizer.Part) std.mem.Allocator.Error!Fill {
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    // The bottom face is PINNED to the 0.3 mm gap an inner plane defaults to,
    // rather than taking the tighter outer default. These two tests measure the
    // guard band and the iso-line interpolation — properties of the tracer at
    // whatever gap it is handed — so they state the gap their arithmetic below
    // is written against instead of inheriting one that is a different number.
    const design = optimizer.DesignRules{ .pour = .{ .clearance_outer = 0.3 } };
    const placement = testPlacement(parts, &nets, .{ .design = design, .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } });
    const track = [_]router.Track{.{ .x1 = -1, .y1 = -1, .x2 = 21, .y2 = 21, .layer = 1, .width = 0.4, .net = 1 }};
    const vias = [_]router.Via{.{ .x = 13, .y = 3, .dia = 0.6, .net = 1 }};
    return compute(
        arena,
        placement,
        .{ .tracks = &track, .vias = &vias },
        .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 },
    );
}

/// A C1 GND seed pad on the bottom, on the x>y side of the diagonal.
fn seedPart(pad: *const [1]geometry.Pad) [1]optimizer.Part {
    return .{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = pad,
        .fallback = false,
        .x = 15,
        .y = 5,
        .side = .bottom,
    }};
}

// spec: placement/pour - every emitted contour point keeps at least the pour clearance from foreign copper
test "every contour point clears the pour clearance from foreign copper" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = seedPart(&gnd_pad);
    const fill = try diagonalTrackFill(arena, &parts);

    // The class stays at base, so the pour keeps `pour_clearance` (0.3 mm) from
    // both the track's and the via's COPPER edge (centre distance − half-width).
    const clearance: f64 = 0.3;
    try testing.expect(fill.contours.len >= 1);
    for (fill.contours) |poly| {
        var k: usize = 0;
        while (k < poly.len) : (k += 1) {
            const a = poly[k];
            const b = poly[(k + 1) % poly.len];
            var s: usize = 0;
            while (s <= 4) : (s += 1) { // endpoints + 3 interior samples
                const f = @as(f64, @floatFromInt(s)) / 4.0;
                const px = a[0] + f * (b[0] - a[0]);
                const py = a[1] + f * (b[1] - a[1]);
                const d_track = segPointDist(-1, -1, 21, 21, px, py) - 0.2;
                const d_via = std.math.hypot(px - 13, py - 3) - 0.3;
                try testing.expect(d_track >= clearance - 1e-6);
                try testing.expect(d_via >= clearance - 1e-6);
            }
        }
    }
}

// spec: placement/pour - contour vertices interpolate the clearance iso-line instead of snapping to grid corners
test "contour interpolates a smooth diagonal wall along a foreign track" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = seedPart(&gnd_pad);
    const fill = try diagonalTrackFill(arena, &parts);

    // Wall segments = contour segments whose midpoint lies in the corridor along
    // the 45° track; board-edge runs sit far from the centreline and are skipped.
    var total: usize = 0;
    var diagonal: usize = 0;
    var max_gap: f64 = 0;
    for (fill.contours) |poly| {
        var k: usize = 0;
        while (k < poly.len) : (k += 1) {
            const a = poly[k];
            const b = poly[(k + 1) % poly.len];
            const mx = (a[0] + b[0]) / 2;
            const my = (a[1] + b[1]) / 2;
            if (segPointDist(-1, -1, 21, 21, mx, my) > 0.9) continue;
            total += 1;
            if (@abs(b[0] - a[0]) > 1e-9 and @abs(b[1] - a[1]) > 1e-9) diagonal += 1;
            // Sample the copper gap only along the long FLAT wall; the short
            // corner-transition segments legitimately bulge away from the track
            // where the wall meets a board edge (farther from copper, not closer).
            if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < 1.0) continue;
            var s: usize = 0;
            while (s <= 4) : (s += 1) {
                const f = @as(f64, @floatFromInt(s)) / 4.0;
                const px = a[0] + f * (b[0] - a[0]);
                const py = a[1] + f * (b[1] - a[1]);
                max_gap = @max(max_gap, segPointDist(-1, -1, 21, 21, px, py) - 0.2);
            }
        }
    }
    try testing.expect(total > 0);
    try testing.expect(max_gap > 0); // the flat wall was actually sampled
    // The interpolated iso-line runs diagonally; the old grid-snapped trace made
    // only axis-aligned staircase steps in this corridor (0% diagonal).
    try testing.expect(diagonal * 100 >= total * 30);
    // The flat wall hugs the clearance offset — no ½-cell staircase overshoot.
    try testing.expect(max_gap <= 0.3 + 3 * iso_guard + 1e-9);
}

/// The first hole loop that encircles (x,y) by the even-odd rule
/// (`outline.contains` — the same ray-cast the viewer's even-odd fill
/// realises), or null when none does.
fn holeEnclosing(holes: []const Contour, x: f64, y: f64) ?Contour {
    for (holes) |hole| if (outline.contains(hole, x, y)) return hole;
    return null;
}

// spec: placement/pour - a round NPTH on an outer face punches a round antipad instead of its bounding square
test "outer pour keeps a round antipad around a circular NPTH" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const seed_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const hole_pad = [_]geometry.Pad{.{
        .number = "None",
        .x = 0,
        .y = 0,
        .w = 1,
        .h = 1,
        .shape = "circle",
        .thru = true,
        .npth = true,
        .drill = 1,
    }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &seed_pad, .fallback = false, .x = 3, .y = 3, .side = .top },
        .{ .ref_des = "H1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &hole_pad, .fallback = false, .x = 10, .y = 10, .side = .top },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &gnd_pins }};
    const placement = testPlacement(&parts, &nets, .{
        .design = .{ .pour = .{ .clearance_outer = 0.3 } },
    });

    const fill = try compute(arena, placement, .{}, .{ .net = .{ .named = "GND" }, .side = .top, .track_layer = 0 });
    try testing.expectEqual(@as(usize, 1), fill.contours.len);
    const ring = holeEnclosing(fill.holes[0], 10, 10) orelse return error.TestExpectedRoundAntipad;

    var min_radius = std.math.inf(f64);
    var max_radius: f64 = 0;
    for (ring) |point| {
        const radius = std.math.hypot(point[0] - 10, point[1] - 10);
        min_radius = @min(min_radius, radius);
        max_radius = @max(max_radius, radius);
    }
    // The old bounding-box stamp reached about 0.2 mm farther on the diagonals.
    // A round stamp varies only by the contour lattice/interpolation tolerance.
    try testing.expect(max_radius - min_radius < 0.08);
    try testing.expect(min_radius >= 0.8 - 1e-6); // 0.5 mm bore + 0.3 mm clearance
}

// spec: placement/pour - a foreign via interior to a seeded pour punches an antipad hole that encircles it at clearance
test "interior foreign via punches an antipad hole in the pour" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A bottom GND pour seeded by a corner pad, with a FOREIGN VIN via dead
    // centre — fully enclosed by ground copper, so the pour must trace an
    // antipad HOLE around it instead of overdrawing copper across it.
    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 3, .side = .bottom },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    // The bottom face is pinned to the inner plane's 0.3 mm gap (see
    // `diagonalTrackFill`): this test is about the antipad LOOP — that a fully
    // enclosed foreign via is traced as a hole rather than overdrawn — not
    // about which default an outer face resolves, which the layer-class test
    // below covers head-on.
    const design = optimizer.DesignRules{ .pour = .{ .clearance_outer = 0.3 } };
    const placement = testPlacement(&parts, &nets, .{ .design = design, .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } });

    const vias = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.6, .net = 1 }};
    const fill = try compute(arena, placement, .{ .vias = &vias }, .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 });

    // One kept component (the surrounding GND pour); its holes are parallel to
    // its contours and carry the antipad loop.
    try testing.expectEqual(@as(usize, 1), fill.n_comp);
    try testing.expectEqual(fill.contours.len, fill.holes.len);
    try testing.expect(fill.contours.len == 1);

    // (a) some hole of the pour encircles the via centre (even-odd point-in-poly).
    const ring = holeEnclosing(fill.holes[0], 10, 10);
    try testing.expect(ring != null);

    // (b) every vertex of that hole keeps at least `pour_clearance` (0.3 mm) from
    // the via's copper edge (centre distance − the 0.3 mm barrel radius).
    const clearance: f64 = 0.3;
    const barrel: f64 = 0.3; // dia / 2
    for (ring.?) |v| {
        const d = std.math.hypot(v[0] - 10, v[1] - 10) - barrel;
        try testing.expect(d >= clearance - 1e-6);
    }
}

/// The smallest gap any vertex of `ring` leaves from the copper edge of a
/// `dia`-wide barrel centred at (cx, cy) — how close the traced antipad
/// actually comes to the foreign via it encircles.
fn ringGap(ring: Contour, cx: f64, cy: f64, dia: f64) f64 {
    var min_gap: f64 = std.math.floatMax(f64);
    for (ring) |v| min_gap = @min(min_gap, std.math.hypot(v[0] - cx, v[1] - cy) - dia / 2);
    return min_gap;
}

// spec: placement/pour - an outer-face pour holds the tighter outer default gap while an inner plane keeps the fab-safe one
test "an outer face pours to the outer default and an inner plane to the fab-safe one" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // ONE board, ONE foreign via, no authored `(design-rules …)` — so the only
    // thing separating the two fills is the layer class each spec names.
    // The GND seed pad is through-hole so it seeds the inner plane as well as
    // the bottom face (an inner plane sees only drilled copper).
    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 3, .side = .bottom },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } });

    const vias = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.6, .net = 1 }};
    const outer = try compute(arena, placement, .{ .vias = &vias }, .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 });
    const inner = try compute(arena, placement, .{ .vias = &vias }, .{ .net = .{ .named = "GND" } });
    try testing.expect(outer.holes.len >= 1 and inner.holes.len >= 1);

    const outer_ring = holeEnclosing(outer.holes[0], 10, 10) orelse return error.TestUnexpectedResult;
    const inner_ring = holeEnclosing(inner.holes[0], 10, 10) orelse return error.TestUnexpectedResult;
    const outer_gap = ringGap(outer_ring, 10, 10, 0.6);
    const inner_gap = ringGap(inner_ring, 10, 10, 0.6);

    // Each antipad clears its own layer class's default, and the outer face
    // comes strictly closer — copper an outer pour may hold because it is
    // photo-defined against finished copper, not etched between two foils.
    const def = optimizer.DesignRules{};
    try testing.expect(outer_gap >= def.pour.clearance_outer - 1e-6);
    try testing.expect(inner_gap >= def.pour_clearance - 1e-6);
    try testing.expect(outer_gap < def.pour_clearance);
}

// spec: placement/pour - the shared fill lattice is pitched for the tighter of the two pour-clearance defaults
test "the fill lattice pitch follows the tighter outer pour default" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const parts: []optimizer.Part = &.{};
    const nets: []flat_netlist.FlatNet = &.{};
    const poly = [_][2]f64{ .{ 2, 2 }, .{ 18, 2 }, .{ 18, 18 }, .{ 2, 18 } };

    // One lattice serves every fill of a board, so it is cut for the SMALLEST
    // gap the board can ask for — here the 0.2 outer default, not the 0.3 inner
    // one, or an outer face's isolation could not be sampled consistently.
    const bare = try compute(arena, testPlacement(parts, nets, .{}), .{}, zoneLayerSpec("GND", .bottom, 1, &poly));
    try testing.expectApproxEqAbs((optimizer.DesignRules{}).pour.clearance_outer / 2, bare.frame.pitch, 1e-12);

    // An authored `(pour-clearance …)` sets BOTH classes, so a board that
    // states 0.3 keeps exactly the 0.15 lattice it has always had.
    const authored = optimizer.BoardRules{ .design = .{ .pour_clearance = 0.3, .pour = .{ .clearance_outer = 0.3 } } };
    const pinned = try compute(arena, testPlacement(parts, nets, authored), .{}, zoneLayerSpec("GND", .bottom, 1, &poly));
    try testing.expectApproxEqAbs(@as(f64, 0.15), pinned.frame.pitch, 1e-12);
}

// spec: placement/pour - a foreign trace that splits a plane leaves its same-net pads in separate components
test "planeConnect splits pads across a severed plane" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 10, .side = .bottom },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 17, .y = 10, .side = .bottom },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } });

    const qpads = [_]PadQuery{
        .{ .cx = 3, .cy = 10, .shape = .{ .x0 = 2.7, .y0 = 9.7, .x1 = 3.3, .y1 = 10.3 }, .thru = false, .side = .bottom },
        .{ .cx = 17, .cy = 10, .shape = .{ .x0 = 16.7, .y0 = 9.7, .x1 = 17.3, .y1 = 10.3 }, .thru = false, .side = .bottom },
    };

    // No wall: one plane, both pads share a component.
    const whole = try planeConnect(arena, placement, .{}, .{ .net_name = "GND", .pads = &qpads, .vias = &.{} });
    try testing.expectEqual(@as(usize, 1), whole.n_comp);
    try testing.expectEqual(whole.pad_comp[0], whole.pad_comp[1]);

    // A full-height foreign wall severs the plane: the pads land in different
    // components — an honest split.
    const wall = [_]router.Track{.{ .x1 = 10, .y1 = -2, .x2 = 10, .y2 = 22, .layer = 1, .width = 0.5, .net = 1 }};
    const cut = try planeConnect(arena, placement, .{ .tracks = &wall }, .{ .net_name = "GND", .pads = &qpads, .vias = &.{} });
    try testing.expectEqual(@as(usize, 2), cut.n_comp);
    try testing.expect(cut.pad_comp[0] != cut.pad_comp[1]);
    try testing.expect(cut.pad_comp[0] >= 0 and cut.pad_comp[1] >= 0);

    // Full DRC retains this same fill after producing topology contours. Its
    // prepared-connectivity path must classify pads exactly like a fresh fill.
    const layers = try carryingLayers(arena, placement.rules, "GND");
    const fills = [_]Fill{try compute(arena, placement, .{ .tracks = &wall }, layers[0])};
    const prepared = try planeConnectPrepared(
        arena,
        .{ .net_name = "GND", .pads = &qpads, .vias = &.{} },
        .{ .net_name = "GND", .layers = layers, .fills = &fills },
    );
    try testing.expectEqual(cut.n_comp, prepared.n_comp);
    try testing.expectEqual(cut.coarsened, prepared.coarsened);
    try testing.expectEqualSlices(i32, cut.pad_comp, prepared.pad_comp);
    try testing.expectEqualSlices(i32, cut.via_comp, prepared.via_comp);
}

test "a concave custom pad joins every fill component touched by its copper" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // The Π-shaped custom land reaches the left and right fill islands around
    // an empty bounding-box centre. Either centre-only or box-corner sampling
    // sees at most one island; the authored copper joins both electrically.
    const custom_poly = [_][2]f64{
        .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1.4 }, .{ 2, 1.4 },
        .{ 2, 0 }, .{ 3, 0 }, .{ 3, 2 },   .{ 0, 2 },
    };
    const pads = [_]PadQuery{
        .{ .cx = 0.5, .cy = 0.5, .shape = .{ .x0 = 0, .y0 = 0, .x1 = 3, .y1 = 2, .poly = &custom_poly }, .thru = false, .side = .top },
        .{ .cx = 0.5, .cy = 0.5, .shape = .{ .x0 = 0.25, .y0 = 0.25, .x1 = 0.75, .y1 = 0.75 }, .thru = false, .side = .top },
        .{ .cx = 2.5, .cy = 0.5, .shape = .{ .x0 = 2.25, .y0 = 0.25, .x1 = 2.75, .y1 = 0.75 }, .thru = false, .side = .top },
    };
    const labels = [_]i32{ 0, -1, 1 };
    const layers = [_]LayerSpec{.{ .net = .ground, .side = .top, .track_layer = 0 }};
    const fills = [_]Fill{.{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 3, .ny = 1 },
        .labels = &labels,
        .n_comp = 2,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    }};
    const joined = try planeConnectPrepared(
        arena,
        .{ .net_name = "GND", .pads = &pads, .vias = &.{} },
        .{ .net_name = "GND", .layers = &layers, .fills = &fills },
    );
    try testing.expectEqual(@as(usize, 1), joined.n_comp);
    try testing.expectEqual(joined.pad_comp[0], joined.pad_comp[1]);
    try testing.expectEqual(joined.pad_comp[0], joined.pad_comp[2]);
}

// spec: placement/pour - the fill respects a non-rectangular board outline
test "polygon outline restricts the fill to inside the board" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 3, .side = .bottom },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &gnd_pins }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    var placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } });
    // L-shape: the (10..20, 4..20) corner is notched out.
    const l_poly = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 4 }, .{ 10, 4 }, .{ 10, 20 }, .{ 0, 20 } };
    placement.board_poly = &l_poly;
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 };

    const fill = try compute(arena, placement, .{}, .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 });
    try testing.expect(fill.componentAt(3, 3) == 0); // main body, poured
    try testing.expect(fill.componentAt(15, 15) < 0); // inside the notch — not poured
    try testing.expect(fill.componentAt(15, 2) == 0); // the upper arm, poured
}

/// Assert one lane group of cell centres — `x0`, `x0+step`, … on row `y` —
/// reproduces the scalar walk exactly, lane by lane.
fn expectLanesMatchScalar(ring: []const [2]f64, x0: f64, step: f64, y: f64) !void {
    var xs: Lanes = @splat(0);
    inline for (0..lanes) |k| xs[k] = x0 + @as(f64, @floatFromInt(k)) * step;
    var lane: [lanes]f64 = undefined;
    polyInsetLanes(ring, xs, y, &lane);
    inline for (lane, 0..) |got, k| try testing.expectEqual(polySignedInset(ring, xs[k], y), got);
}

// spec: placement/pour - the vectorised row kernel seeds every lane with the value the scalar outline walk gives
test "polyInsetLanes matches polySignedInset lane for lane" {
    // The lane kernel is a batching of `polySignedInset`, not an approximation
    // of it — a lane that drifted would move the pour's blocked/kept threshold
    // and silently reshape a plane. Probe an L-ring: rows above and below the
    // reflex notch, a row where the ray cast flips INSIDE a lane group, groups
    // straddling an edge, and groups wholly outside on either side.
    const ring = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 4 }, .{ 10, 4 }, .{ 10, 20 }, .{ 0, 20 } };
    const groups = [_][2]f64{
        .{ -1.7, 2.0 }, .{ 8.6, 2.0 },   .{ 18.4, 2.0 }, .{ 19.6, 2.0 },
        .{ 3.3, 12.0 }, .{ 8.9, 12.0 },  .{ 9.7, 12.0 }, .{ 10.4, 12.0 },
        .{ 0.1, 3.9 },  .{ 9.55, 4.05 }, .{ 5.0, -1.3 }, .{ 5.0, 21.4 },
    };
    for (groups) |g| try expectLanesMatchScalar(&ring, g[0], 0.37, g[1]);
}

// spec: placement/pour - a connectivity fill reuses one edge-margin field, applies topology-repair clears, and omits returned contours while labelling exactly what a rendering fill labels
// spec: placement/pour - a batch of sampling fills shares one edge field, applies topology-repair clears, and omits returned contours
test "a sampling fill on a shared edge field labels exactly what a rendering fill labels" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // `planeConnect` reads only `labels`, so it reuses ONE edge-margin field
    // across its carrying layers and asks for no contours. Both shortcuts must
    // be invisible in the labelling — otherwise plane connectivity would answer
    // a different question from the pour the Gerber emits.
    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 3, .side = .bottom },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{ .{ .name = "GND", .pins = &gnd_pins }, .{ .name = "VIN", .pins = &.{} } };
    const gnd_names = [_][]const u8{"GND"};
    var placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2 });
    const l_poly = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 4 }, .{ 10, 4 }, .{ 10, 20 }, .{ 0, 20 } };
    placement.board_poly = &l_poly;
    // A foreign wall so the fill has more than one component to label.
    const wall = [_]router.Track{.{ .x1 = 5, .y1 = -2, .x2 = 5, .y2 = 22, .layer = 1, .width = 0.5, .net = 1 }};
    const spec = LayerSpec{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 };

    const rendered = try compute(arena, placement, .{ .tracks = &wall }, spec);
    const base = try edgeField(arena, placement);
    try testing.expect(base != null);
    const connectivity = try computeFill(arena, placement, .{ .tracks = &wall }, spec, .{ .base = base, .contours = false });

    try testing.expectEqual(rendered.n_comp, connectivity.n_comp);
    try testing.expectEqualSlices(i32, rendered.labels, connectivity.labels);
    try testing.expectEqual(@as(usize, 0), connectivity.contours.len);
    try testing.expect(rendered.contours.len > 0);

    // The external sampling path takes both internal shortcuts at once.
    const specs = [_]LayerSpec{ spec, spec };
    const masks = try computeMasks(arena, placement, .{ .tracks = &wall }, &specs);
    try testing.expectEqual(specs.len, masks.len);
    for (masks) |mask| {
        try testing.expectEqualSlices(i32, rendered.labels, mask.labels);
        try testing.expectEqual(@as(usize, 0), mask.contours.len);
        try testing.expectEqual(rendered.contains(3, 3), mask.contains(3, 3));
    }
}

// spec: placement/pour - a board's fills seed from one shared edge-margin field and each still traces exactly the contours an unshared fill traces
test "computeShared over one edge field matches compute for every spec on the board" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // The edge-margin field is the outline walk, and a page render pours the
    // same board a couple of dozen times (Gerber package, viewer pour JSON,
    // filled DRC, connectivity). Seeding it once for all of them is only sound
    // if the fill it produces is indistinguishable from a fill that seeded its
    // own — including for specs that clip to a drawn polygon, which `min()`s
    // the shared field down rather than reading it whole.
    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 3, .side = .bottom },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{ .{ .name = "GND", .pins = &gnd_pins }, .{ .name = "VIN", .pins = &.{} } };
    const gnd_names = [_][]const u8{"GND"};
    var placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2 });
    // A non-rectangular outline: the poly walk is the cost being shared, so a
    // plain rectangle would not exercise what the field actually carries.
    const l_poly = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 4 }, .{ 10, 4 }, .{ 10, 20 }, .{ 0, 20 } };
    placement.board_poly = &l_poly;
    const wall = [_]router.Track{.{ .x1 = 5, .y1 = -2, .x2 = 5, .y2 = 22, .layer = 1, .width = 0.5, .net = 1 }};
    const copper = Copper{ .tracks = &wall };

    const zone_poly = [_][2]f64{ .{ 1, 1 }, .{ 9, 1 }, .{ 9, 18 }, .{ 1, 18 } };
    // A seeded outer pour, an unseeded inner plane, and a clipped user zone —
    // the three shapes a page render actually asks for.
    const specs = [_]LayerSpec{
        .{ .net = .{ .named = "GND" }, .side = .bottom, .track_layer = 1 },
        .{ .net = .ground, .keep_unseeded = true },
        zoneLayerSpec("GND", .bottom, 1, &zone_poly),
    };

    // ONE field for every spec on this board — exactly how the callers use it.
    const base = try sharedEdgeField(arena, placement);
    try testing.expect(base != null);
    for (specs) |spec| {
        const alone = try compute(arena, placement, copper, spec);
        const shared = try computeShared(arena, placement, copper, spec, base);
        try testing.expectEqual(alone.n_comp, shared.n_comp);
        try testing.expectEqualSlices(i32, alone.labels, shared.labels);
        try testing.expectEqual(alone.contours.len, shared.contours.len);
        // Non-vacuous: each spec really does pour copper on this outline, so
        // the comparison above is between traced contours, not two empty fills.
        try testing.expect(alone.contours.len > 0);
        for (alone.contours, shared.contours) |a, b| {
            try testing.expectEqualSlices([2]f64, a, b);
        }
    }
}

// spec: placement/pour - an isolated same-net pad reports no pour component
test "planeConnect isolates a same-net pad on the wrong side of a single-sided pour" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A bottom-only GND pour. C1's GND pad is on the bottom (connects); C2's GND
    // pad is on the TOP, with no via down — the pour cannot reach it, an honest
    // airwire rather than a believed-connected pad.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 10, .side = .bottom },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 15, .y = 10, .side = .top },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &gnd_pins }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = testPlacement(&parts, &nets, .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } });

    const qpads = [_]PadQuery{
        .{ .cx = 3, .cy = 10, .shape = .{ .x0 = 2.7, .y0 = 9.7, .x1 = 3.3, .y1 = 10.3 }, .thru = false, .side = .bottom },
        .{ .cx = 15, .cy = 10, .shape = .{ .x0 = 14.7, .y0 = 9.7, .x1 = 15.3, .y1 = 10.3 }, .thru = false, .side = .top },
    };
    const join = try planeConnect(arena, placement, .{}, .{ .net_name = "GND", .pads = &qpads, .vias = &.{} });
    try testing.expect(join.pad_comp[0] >= 0); // C1 (bottom) reaches the pour
    try testing.expectEqual(@as(i32, -1), join.pad_comp[1]); // C2 (top) does not
}

// spec: placement/pour - carryingLayers resolves declared planes and the implicit ground model
test "carryingLayers picks the poured layers for a net" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // Implicit model: ground nets pour one inner plane; signals pour nothing.
    const imp = try carryingLayers(arena, .{}, "GND");
    try testing.expectEqual(@as(usize, 1), imp.len);
    try testing.expect(imp[0].net == .ground);
    try testing.expect(imp[0].side == null);
    try testing.expectEqual(@as(usize, 0), (try carryingLayers(arena, .{}, "SIG")).len);

    // Declared bottom pour: an outer face with its track layer.
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const layers = try carryingLayers(arena, .{ .plane_nets = &[_][]const u8{"GND"}, .copper_layers = 2, .planes = .{ .declared = &planes } }, "GND");
    try testing.expectEqual(@as(usize, 1), layers.len);
    try testing.expect(layers[0].side.? == .bottom);
    try testing.expectEqual(@as(u8, 1), layers[0].track_layer.?);
}
