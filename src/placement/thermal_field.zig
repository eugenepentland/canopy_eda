//! Steady-state 2D board thermal spreader, and the cooling-scenario ladder that
//! hangs off it.
//!
//! `eval/thermal.zig` answers the paper question — `Tj = Ta + P·θJA`, one part at
//! a time, no board, no neighbours. That is the right screen before a package is
//! chosen and the wrong one afterwards, because θJA already contains an assumed
//! board: it says nothing about a hot buck sitting 3 mm from the MCU, and it
//! cannot tell you that widening the board or adding a plane would fix either.
//! This module asks the layout question instead: given where the parts actually
//! sit, how hot does the COPPER get, and how much of each junction's rise is the
//! board it stands on rather than the part itself.
//!
//! The model is a uniform conducting sheet over the board outline, solved on a
//! square grid:
//!
//!   * every cell carries its own sheet conductance (`sheetConductance` — the
//!     stackup's copper and laminate, with the OUTER copper derated by how much
//!     of that cell is actually poured), and square cells make the W/L ratio
//!     exactly 1, so that conductance IS the cell's own; two neighbours couple
//!     through the harmonic mean of theirs, which is two half-cells in series;
//!   * every cell sheds to ambient through its two faces SEPARATELY at the
//!     scenario's film coefficient (convection plus linearized radiation,
//!     rolled into one number per scenario), and a face a part body sits on
//!     sheds at a fraction of that;
//!   * the board EDGE is adiabatic — a cell at the rim simply has fewer
//!     neighbours. Edge convection is already counted in the face term, and
//!     giving the rim a second path would make the answer depend on the grid
//!     rather than on the board;
//!   * a powered part injects its watts uniformly over the cells its
//!     courtyard/pad box covers, and its junction sits `P·(θJB + θ_transfer)`
//!     above the hottest cell underneath it, where the transfer term is how
//!     hard it is for that part's heat to reach the layers the sheet lumps
//!     together — short where a via array stitches the land to the planes, long
//!     where nothing but the outer foil and the dielectric does.
//!
//! Every constant is a screening convention, named and sourced below. This is a
//! spreading estimate, not a simulation: it lumps the whole stack into one
//! sheet (so the layers are perfectly coupled to each other, and only the
//! transfer term stands between a part and them), takes one dielectric, and
//! couples nothing through the air. Read it as "which corner of the board is
//! hot and roughly how hot", never as a substitute for a thermal camera.
//!
//! **Linearity is the load-bearing invariant.** The whole system is linear in
//! the injected power and is solved with ambient as the ZERO reference, so what
//! comes back is a RISE field, independent of the ambient it will be read at:
//! `T(Ta) = Ta + rise`, and `Tj(Ta) = Ta + tj_rise_c`. One solve per scenario
//! therefore serves every ambient a caller might ask about, and two independent
//! heat sources superpose exactly — both properties are tested, because the
//! moment either stops holding the per-ambient answers below become fiction.
//!
//! Read-only over its inputs: every number arrives in `Inputs` (the board
//! rectangle a caller resolved, the sheet its stackup implies, the coverage map
//! it rasterized, and one row per part projected out of `eval/thermal.zig`'s
//! analysis), and nothing here re-derives a part's dissipation.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const numeric = @import("../numeric.zig");

// ── Physical constants ────────────────────────────────────────────────────
// Screening conventions, not physics. The point is one documented yardstick
// every board is measured against, so two boards' numbers compare.

/// Finished board thickness (m) — the 1.6 mm standard stack. Stands in for the
/// laminate's own conducting cross-section.
const board_thickness_m: f64 = 1.6e-3;
/// Copper thickness per counted spreader layer (m) — 1 oz finished.
const copper_thickness_m: f64 = 35.0e-6;
/// Thermal conductivity of copper (W/m·K).
const k_copper: f64 = 390.0;
/// Thermal conductivity of FR-4 in plane (W/m·K). Three orders of magnitude
/// under copper, which is why the layer count dominates the answer.
const k_fr4: f64 = 0.3;

/// Film coefficient per face in still air (W/m²K) — natural convection plus
/// linearized radiation off a horizontal board.
const h_natural: f64 = 10.0;
/// Fraction of the bare-laminate film coefficient a face still sheds through
/// where a part body sits on it. Not zero: the package's own top surface
/// convects, and its plastic is a poor but real path off the land it stands on.
/// Not one either, which is what a face-blind model assumes — the laminate
/// under a QFN sees no moving air at all. Halfway-ish, and deliberately blunt:
/// the point is that a densely two-sided board sheds LESS than a bare one, not
/// that any particular package's top-side convection is known.
const covered_face_fraction: f64 = 0.4;
/// Film coefficient per face at roughly 1 m/s of forced air (W/m²K).
const h_airflow_1ms: f64 = 22.0;
/// Film coefficient per face at roughly 2 m/s of forced air (W/m²K).
const h_airflow_2ms: f64 = 35.0;
/// Lateral growth of a free axial-fan jet per millimetre of outlet-to-board
/// standoff. A 0.1 half-angle is the deliberately blunt screening convention:
/// it conserves the authored delivered flow while making distance widen and
/// slow the footprint instead of pretending an 80 mm fan is a uniform room
/// breeze.
const fan_jet_spread_per_side: f64 = 0.1;
/// Sink-to-ambient resistance of the heatsink scenario (K/W) — a small stamped
/// sink in natural convection, the sort that clips onto a TO-263 or gets stuck
/// to a QFN. Deliberately modest: a scenario that assumes a fan-cooled extrusion
/// would pass every board and screen nothing.
const default_theta_sa_c_per_w: f64 = 15.0;
/// Default geometry for the screening sink: a 20 x 20 mm aluminium extrusion
/// with a 2 mm base and 10 mm fins. Geometry is reported and rendered; theta-SA
/// remains an authored/rated input because fin efficiency cannot be inferred
/// reliably from an outline alone.
const default_sink_width_mm: f64 = 20.0;
const default_sink_length_mm: f64 = 20.0;
const default_sink_base_mm: f64 = 2.0;
const default_sink_fin_height_mm: f64 = 10.0;
const default_sink_fin_count: usize = 9;
const max_sink_fin_count: usize = 512;
/// User-requested thermal interface. Conductivity is deliberately explicit in
/// `Heatsink`; 6 W/mK is a common high-performance silicone-pad assumption.
const default_pad_thickness_mm: f64 = 0.5;
const default_pad_k_w_mk: f64 = 6.0;
const square_mm_to_m2: f64 = 1.0e-6;

/// Fraction of θJA used as θJB when a part declares no junction-to-board
/// resistance. Roughly half of a surface-mount package's junction-to-ambient
/// path is the board it stands on, so this is the conventional split — and every
/// row it feeds is flagged `jb_estimated`, because it is a convention and not a
/// datasheet figure.
const theta_jb_ja_fraction: f64 = 0.5;

/// Plating thickness of a via barrel (m) — 25 µm, one ounce of plated copper,
/// the class-2 fab minimum. A thermal via conducts through this annulus only;
/// its hole is either air or a filler with no useful conductivity.
const via_plating_m: f64 = 25.0e-6;
/// Finished drill assumed for a thermal via whose size the caller does not name
/// (mm) — the 0.3 mm hole a stitched thermal land is normally filled with.
const default_via_drill_mm: f64 = 0.3;
/// Dielectric hop from the outer foil down to the first inner plane (m) when no
/// stackup states one — the thin prepreg of a 4-layer 1.6 mm stack. Short,
/// which is why an unstitched land still transfers something.
const default_transfer_m: f64 = 0.2e-3;

// ── Grid + solver constants ───────────────────────────────────────────────

/// Cells the LONGER board dimension is divided into. 64 keeps a 100 mm board on
/// a ~1.6 mm cell — fine enough to separate two adjacent hot parts, coarse
/// enough that four scenarios solve in milliseconds.
const cells_long_axis: usize = 64;
/// Smallest cell the grid uses (mm). Below this the grid resolves detail the
/// uniform-sheet assumption cannot honestly carry.
const min_cell_mm: f64 = 1.0;
/// Largest cell the grid uses (mm). A big board gets more than
/// `cells_long_axis` cells rather than a cell too coarse to place a hotspot.
const max_cell_mm: f64 = 4.0;
/// Hard ceiling on cells per axis, so a nonsense board dimension cannot ask for
/// an unbounded allocation. At `max_cell_mm` this covers a 2 m board, well past
/// anything this screening model is meant for.
pub const max_cells_axis: usize = 512;

/// Convergence bound, as a fraction of the total injected power: the solve is
/// converged when no cell's power balance is off by more than this much of what
/// the whole board dissipates. Scaling by the total is what makes one tolerance
/// serve a 10 mW board and a 10 W one.
const residual_tolerance_frac: f64 = 1e-9;
/// Sweeps the solver will take before giving up. A converged solve takes a few
/// hundred; this exists so a pathological system reports `converged = false`
/// rather than hanging a request.
const max_iterations: usize = 10_000;
/// Floor and ceiling on the over-relaxation factor. Below 1 the sweep would
/// under-relax (slower than plain Gauss-Seidel); at 2 it diverges.
const min_omega: f64 = 1.0;
const max_omega: f64 = 1.95;

/// Spreader layers assumed when a caller has no stackup to count: the implicit
/// board model's four copper layers, which is what a design authoring no
/// `(stackup …)` runs on. The count itself belongs to `board_layers`, so
/// "no stackup form ⇒ 4 copper layers" is spelled once for the whole tree.
pub const default_spreader_layers: u8 = board_layers.implicit_copper_layers;

/// How many copper layers spread heat on a board with `inner_planes` inner
/// plane rows: the two outer faces, which every board has, plus one per plane.
///
/// Inner SIGNAL layers are deliberately not counted. A plane is continuous
/// copper and conducts across the whole board; a routed inner layer is a few
/// per cent copper by area and spreads almost nothing, so counting it would
/// overstate a 6-layer board's spreading by a third. For the implicit model
/// (`board_layers.implicit_copper_layers`) both inner layers ARE planes, so this
/// returns `default_spreader_layers`; for a declared `(stackup N (plane …) …)`
/// pass the number of `(plane …)` rows.
pub fn spreaderLayers(inner_planes: usize) u8 {
    const capped = @min(inner_planes, @as(usize, std.math.maxInt(u8) - 2));
    return @as(u8, @intCast(capped)) + 2;
}

/// In-plane conductance of one square of board (W/K): `k·t` summed over the
/// copper the stackup carries and the laminate itself, with the OUTER copper
/// scaled by `coverage` — the fraction of this square the outer pours actually
/// fill. Independent of cell size — a square is a square — which is why
/// refining the grid does not change the spreading, only where the hotspot is
/// resolved.
///
/// Inner copper is NOT derated: `Sheet.inner_cu_m` already counts only the
/// continuous planes, which are poured edge to edge by definition. Coverage at
/// 1 is the uniform board this module solved before there was a coverage map.
fn sheetConductance(sheet: Sheet, coverage: f64) f64 {
    const cov = if (std.math.isFinite(coverage)) std.math.clamp(coverage, 0, 1) else 1.0;
    return (sheet.inner_cu_m + sheet.outer_cu_m * cov) * k_copper + sheet.laminate_m * k_fr4;
}

// ── Public types ──────────────────────────────────────────────────────────

/// The board as a conducting sheet: how much copper is on the outer faces, how
/// much is in the inner planes, how much laminate carries heat alongside them,
/// and how far a part's land is from the layers below it. All metres.
///
/// Split outer from inner because only the outer copper is patchy — an inner
/// plane is continuous by definition, an outer pour has parts and tracks cut
/// out of it — so only the outer term is derated by a coverage map.
pub const Sheet = struct {
    /// Copper on the two outer faces, summed (m).
    outer_cu_m: f64 = 0,
    /// Copper in the counted inner planes, summed (m).
    inner_cu_m: f64 = 0,
    /// Finished laminate thickness, which conducts in its own right (m).
    laminate_m: f64 = 0,
    /// Dielectric hop from an outer foil to the first inner plane (m) — the
    /// distance a part's heat crosses to reach the layers this sheet lumps.
    transfer_m: f64 = default_transfer_m,
};

/// The sheet a board with `spreader_layers` counted copper layers and no
/// declared stackup is solved as: the screening convention this module has
/// always used — 1.6 mm finished, one ounce per counted layer, two of them on
/// the outer faces and the rest inner planes.
///
/// At coverage 1 this reproduces the pre-coverage uniform sheet exactly, which
/// is what keeps a design that declares no stackup answering the same number it
/// always did.
pub fn defaultSheet(spreader_layers: u8) Sheet {
    const layers: f64 = @floatFromInt(spreader_layers);
    return .{
        .outer_cu_m = @min(layers, 2.0) * copper_thickness_m,
        .inner_cu_m = @max(layers - 2.0, 0.0) * copper_thickness_m,
        .laminate_m = board_thickness_m,
        .transfer_m = default_transfer_m,
    };
}

/// Which face of the board a part is mounted on. Same sense as the placement's
/// own side: `top` is layer 1.
pub const Side = enum { top, bottom };

/// Where the sink contacts the target. `package_top` means the package face on
/// the component side; `board_backside` means the opposite PCB face under the
/// component, so a top-mounted U15 receives a physically bottom-side sink.
pub const HeatsinkSide = enum { package_top, board_backside };

/// Common extrusion materials. Conductivity is the screening value used for
/// base conduction and plate-fin efficiency; it is not a structural grade
/// claim.
pub const HeatsinkMaterial = enum {
    aluminum_6063,
    aluminum_6061,
    copper_c110,
    steel,

    /// Screening thermal conductivity in watts per metre-kelvin.
    pub fn conductivity(self: HeatsinkMaterial) f64 {
        return switch (self) {
            .aluminum_6063 => 201,
            .aluminum_6061 => 167,
            .copper_c110 => 391,
            .steel => 50,
        };
    }
};

/// Board-base dimension along which each straight fin runs.
pub const FinAxis = enum { length, width };

/// Visible aluminium extrusion dimensions. They do not replace the rated
/// theta-SA value; they make the screened assembly auditable and renderable.
pub const HeatsinkGeometry = struct {
    width_mm: f64 = default_sink_width_mm,
    length_mm: f64 = default_sink_length_mm,
    base_mm: f64 = default_sink_base_mm,
    fin_height_mm: f64 = default_sink_fin_height_mm,
    fin_count: usize = default_sink_fin_count,
    /// Positive thickness + non-negative gap switch the sink to a geometry-
    /// derived fin count and theta-SA. Zero thickness preserves the historical
    /// explicit `fin_count` / rated theta-SA path used by the CLI defaults.
    fin_thickness_mm: f64 = 0,
    fin_gap_mm: f64 = 0,
    fin_axis: FinAxis = .length,
};

/// Thermal-interface layer between the target surface and the sink base.
pub const ThermalPad = struct {
    thickness_mm: f64 = default_pad_thickness_mm,
    conductivity_w_mk: f64 = default_pad_k_w_mk,
};

/// One explicit heatsink assembly. Empty `ref_des` preserves the historical
/// automatic target selection; every physical dimension remains visible to
/// export/report surfaces instead of hiding behind a single theta-SA number.
pub const Heatsink = struct {
    ref_des: []const u8 = "",
    side: HeatsinkSide = .board_backside,
    /// Physical PCB face when a saved layout authored the assembly. Null for
    /// legacy CLI cases that only state package-relative contact.
    physical_face: ?Side = null,
    geometry: HeatsinkGeometry = .{},
    theta_sa_c_per_w: f64 = default_theta_sa_c_per_w,
    material: HeatsinkMaterial = .aluminum_6063,
    /// Exact drawn base/contact rectangle. Null keeps the legacy sink centred
    /// on the target package from `geometry.width_mm/length_mm`.
    contact: ?BoardRect = null,
    pad: ThermalPad = .{},
};

/// One axial fan aimed normal to a PCB face. `footprint` is the projection of
/// its outlet frame onto the board at zero standoff. The two catalog maxima are
/// kept separately because they are opposite endpoints of the P-Q curve, not a
/// simultaneously available operating point. `operating_flow_fraction` makes
/// the installed-flow assumption explicit until a measured/system-curve value
/// can replace it.
pub const Fan = struct {
    model: []const u8 = "",
    footprint: ?BoardRect = null,
    face: Side = .top,
    distance_mm: f64 = 0,
    free_air_flow_m3_s: f64 = 0,
    max_static_pressure_pa: f64 = 0,
    operating_flow_fraction: f64 = 0,

    /// True when the fan has enough finite geometry and flow data to solve.
    pub fn enabled(self: Fan) bool {
        const rect = self.footprint orelse return false;
        if (!(rect.w_mm > 0 and rect.h_mm > 0)) return false;
        if (!std.math.isFinite(self.free_air_flow_m3_s) or self.free_air_flow_m3_s <= 0) return false;
        return std.math.isFinite(self.operating_flow_fraction) and self.operating_flow_fraction > 0;
    }

    /// Installed volume flow used by the screen (m^3/s).
    pub fn operatingFlow(self: Fan) f64 {
        if (!self.enabled()) return 0;
        return self.free_air_flow_m3_s * std.math.clamp(self.operating_flow_fraction, 0, 1);
    }

    /// Pressure remaining on the quadratic endpoint-only P-Q approximation.
    /// This is audit metadata, not a substitute for the manufacturer's curve.
    pub fn estimatedPressure(self: Fan) f64 {
        if (!self.enabled()) return 0;
        if (!std.math.isFinite(self.max_static_pressure_pa) or self.max_static_pressure_pa <= 0) return 0;
        const f = std.math.clamp(self.operating_flow_fraction, 0, 1);
        return self.max_static_pressure_pa * (1 - f * f);
    }
};

/// The cooling scenarios, worst-first. `natural` is the board as designed;
/// the two airflow rungs raise the film coefficient; `heatsink` keeps still air
/// and bolts a sink to the one part with the least junction margin.
pub const Scenario = enum {
    natural,
    fan,
    airflow_1ms,
    airflow_2ms,
    heatsink,

    /// Film coefficient per face for this scenario (W/m²K). The heatsink
    /// scenario is still air everywhere — the sink is an extra path on one
    /// part's cells, not a change to the board's convection.
    pub fn filmCoefficient(self: Scenario) f64 {
        return switch (self) {
            .natural, .fan, .heatsink => h_natural,
            .airflow_1ms => h_airflow_1ms,
            .airflow_2ms => h_airflow_2ms,
        };
    }
};

/// An axis-aligned rectangle in board millimetres — the outline, or one part's
/// courtyard/pad box. Same frame the placement and the fab surfaces use
/// (x right, y down).
pub const BoardRect = struct {
    x_mm: f64,
    y_mm: f64,
    w_mm: f64,
    h_mm: f64,
};

/// One part as the spreader needs it: what it burns, what its junction hangs
/// off, and where it sits. Projected out of `eval/thermal.zig`'s `PartThermal`
/// by the caller — nothing here re-derives a dissipation.
///
/// There is no separate "θJA was estimated" flag, and none is needed: an
/// estimated θJA can only reach a junction through the `theta_jb_ja_fraction`
/// fallback, and every row that fallback feeds is already flagged
/// `jb_estimated`.
/// Where and how a part sits on the board — everything the LAYOUT decides,
/// as against the datasheet figures the part carries with it.
pub const Mount = struct {
    /// Courtyard/pad bounding box in board mm. Null ⇒ the part has no pose, and
    /// it is skipped and named in `ScenarioResult.skipped` rather than guessed
    /// onto the board.
    box: ?BoardRect = null,
    /// Which face the part is mounted on. Its body blocks convection off THAT
    /// face only, so two parts back to back cover a cell's two faces and a lone
    /// part leaves the other one bare.
    side: Side = .top,
    /// Vias standing inside the part's own box — the array under a thermal pad.
    /// Every one of them is a copper barrel short-circuiting the land to the
    /// layers below, which is the single biggest lever a layout has over a
    /// power part's junction.
    thermal_vias: usize = 0,
    /// Finished drill of those vias (mm). Zero or non-finite ⇒
    /// `default_via_drill_mm`.
    via_drill_mm: f64 = 0,
};

/// One part as the field sees it: what its datasheet says it dissipates and
/// how hot its junction may get, plus how the layout mounts it.
pub const PartInput = struct {
    ref_des: []const u8,
    origin_key: []const u8 = "",
    /// Dissipation (W). A non-finite or negative figure injects nothing.
    watts: f64 = 0,
    /// Junction-to-board resistance (K/W), the declared figure when there is one.
    theta_jb: ?f64 = null,
    /// Junction-to-package-top case resistance (K/W).
    theta_jc: struct {
        /// Direction-unspecified value, carried for audit but not consumed.
        generic: ?f64 = null,
        top: ?f64 = null,
        /// Junction-to-exposed-pad / package-bottom case resistance (K/W).
        bottom: ?f64 = null,
    } = .{},
    /// Junction-to-ambient resistance (K/W) — only used as the θJB fallback.
    theta_ja: ?f64 = null,
    /// Absolute-maximum junction temperature (°C).
    tj_max: ?f64 = null,
    /// How the layout mounts it.
    mount: Mount = .{},
};

/// A coverage map: what fraction of each grid cell the OUTER copper pours
/// actually fill, in the same row-major order and on the same cells as
/// `gridShape` resolves for the board.
///
/// A caller with no pours to sample should pass no coverage at all rather than
/// a map of zeros — no map means "solve the uniform board", a map of zeros
/// means "this board has no outer copper anywhere", and those are very
/// different claims.
pub const Coverage = struct {
    cols: usize = 0,
    rows: usize = 0,
    /// Fraction in `[0, 1]` per cell, `rows × cols`, row-major.
    outer_frac: []const f32 = &.{},
};

/// One end of an ambient window, and the part that sets it.
pub const AmbientLimit = struct {
    c: ?f64 = null,
    ref_des: []const u8 = "",
};

/// Everything one ladder run is computed from. The caller resolves the board
/// rectangle (the same outline the fab and describe surfaces resolve) and the
/// spreader layer count (`spreaderLayers`), so this module never has to guess
/// at a stackup it cannot see.
pub const Inputs = struct {
    board: BoardRect,
    /// Copper layers that spread — see `spreaderLayers`. Only consulted when
    /// `sheet` is null, as the fallback the screening convention is built from.
    spreader_layers: u8 = default_spreader_layers,
    /// The stackup's own sheet, when the caller could read one. Null ⇒
    /// `defaultSheet(spreader_layers)`.
    sheet: ?Sheet = null,
    /// Per-cell outer-copper coverage, when the caller could sample the pours.
    /// Null — or any map whose shape does not match the grid — solves the
    /// uniform board instead.
    coverage: ?Coverage = null,
    parts: []const PartInput = &.{},
    /// Optional physical cooling assemblies used by their named scenarios.
    cooling: CoolingAssembly = .{},
    /// The board's ratings ceiling, which caps every scenario's `max_ambient`
    /// however cool the junctions run. Pass `eval/thermal.zig`'s
    /// min-over-`operating_max` here; it is deliberately NOT recomputed, so the
    /// lumped screen and the field agree about what the parts are rated for.
    ratings_cap: AmbientLimit = .{},
};

/// Physical cooling declarations kept together so the board solver's primary
/// inputs remain the board, stackup, copper and parts.
pub const CoolingAssembly = struct {
    heatsink: Heatsink = .{},
    fan: Fan = .{},
};

/// The solved rise field: `rows × cols` cells in row-major order, each holding
/// its temperature RISE above ambient (°C), never an absolute temperature. Cell
/// `(col, row)` spans `[origin + col·cell, origin + (col+1)·cell]` in x and the
/// same in y.
pub const FieldGrid = struct {
    cols: usize,
    rows: usize,
    cell_mm: f64,
    origin_x_mm: f64,
    origin_y_mm: f64,
    rise_c: []f32,

    /// Rise in one cell (°C), 0 for an out-of-range index.
    pub fn at(self: FieldGrid, col: usize, row: usize) f32 {
        if (col >= self.cols or row >= self.rows) return 0;
        return self.rise_c[row * self.cols + col];
    }
};

/// The hottest point of a solved field, and how hot it is.
pub const Hotspot = struct {
    /// The board's maximum copper rise above ambient (°C).
    rise_c: f64 = 0,
    /// Centre of the hottest cell, in board mm.
    x_mm: f64 = 0,
    y_mm: f64 = 0,
};

/// One placed part's answer under one scenario.
pub const PartField = struct {
    ref_des: []const u8,
    origin_key: []const u8 = "",
    /// Hottest copper under the part's own cells (°C above ambient).
    board_rise_c: f64,
    /// Junction rise above ambient: the board under it, plus `P·θJB` (°C). Null
    /// when the part declares neither a θJB nor a θJA to fall back on.
    tj_rise_c: ?f64 = null,
    /// True when `tj_rise_c` was computed through the `theta_jb_ja_fraction`
    /// fallback rather than a declared θJB.
    jb_estimated: bool = false,
    /// Board-transfer resistance from this part's land into the spreading sheet
    /// (K/W) — in series with θJB, and the term a via array shortens. Zero for
    /// a part with no pose.
    theta_transfer_c_per_w: f64 = 0,
    /// Which package path produced `tj_rise_c` for this row.
    junction_path: JunctionPath = .board,
    /// Highest ambient this part alone tolerates, `tj_max − tj_rise_c` (°C).
    /// Null when either term is unknown.
    max_ambient_c: ?f64 = null,
};

/// Package branch used to estimate a part's junction for one scenario.
pub const JunctionPath = enum { board, package_top, package_bottom };

/// One scenario's whole answer.
pub const ScenarioResult = struct {
    scenario: Scenario,
    grid: FieldGrid,
    /// One row per PLACED part, in input order.
    parts: []const PartField = &.{},
    /// Ref-des of every part skipped for want of a pose, in input order.
    skipped: []const []const u8 = &.{},
    hotspot: Hotspot = .{},
    /// Tightest of every part's `max_ambient_c` and the caller's ratings cap.
    max_ambient: AmbientLimit = .{},
    /// False when the solve hit `max_iterations` without meeting the residual
    /// bound. The field is still returned — it is simply not to be trusted.
    converged: bool = true,
    /// Explicit assembly placement for the heatsink rung; null on the other
    /// scenarios. These fields let presentation surfaces name the physical
    /// face instead of assuming every sink is backside-mounted.
    cooling: ScenarioCooling = .{},
};

/// Scenario-specific physical assembly metadata for reports and exports.
pub const ScenarioCooling = struct {
    heatsink: struct {
        ref: []const u8 = "",
        side: ?HeatsinkSide = null,
        face: ?Side = null,
    } = .{},
    fan: struct {
        model: []const u8 = "",
        face: ?Side = null,
        velocity_m_s: f64 = 0,
        operating_flow_m3_s: f64 = 0,
        estimated_pressure_pa: f64 = 0,
    } = .{},
};

// ── The ladder ────────────────────────────────────────────────────────────

/// Solve the four screening scenarios plus the authored fan scenario when one
/// is enabled, returned in `Scenario` enum order.
///
/// `natural` is solved first because the heatsink scenario needs its answer: the
/// sink goes on the part with the WORST junction margin in still air, which is
/// the part a designer would actually reach for. Every result carries its own
/// rise field, so the caller can render or measure any of them; because the
/// fields are rises against a zero reference, none of them has to be re-solved
/// for a different ambient.
pub fn solveScenarios(
    allocator: std.mem.Allocator,
    inputs: Inputs,
) std.mem.Allocator.Error![]ScenarioResult {
    const has_fan = inputs.cooling.fan.enabled();
    const out = try allocator.alloc(ScenarioResult, if (has_fan) 5 else 4);
    const natural_grid = try makeGrid(allocator, inputs.board);
    var solver = try buildPackedSolver(allocator, natural_grid, inputs);

    // The natural field names the heatsink target. Solve it in every lane on
    // the first pass; the second pass reuses the same packed storage for the
    // three remaining scenarios. Two vector solves replace four scalar solves.
    const natural_lanes = [simd_scenarios]Scenario{ .natural, .natural, .natural, .natural };
    try configurePackedSolver(allocator, &solver, natural_grid, inputs, .{ .scenarios = natural_lanes });
    const natural_converged = solvePacked(&solver);
    packedLaneToGrid(&solver, 0, natural_grid);
    out[0] = try summarizeScenario(allocator, natural_grid, inputs, .natural, null, natural_converged);
    const target = configuredHeatsinkTarget(inputs, out[0].parts);

    const remaining = [simd_scenarios]Scenario{ .airflow_1ms, .airflow_2ms, .heatsink, .airflow_2ms };
    try configurePackedSolver(allocator, &solver, natural_grid, inputs, .{
        .scenarios = remaining,
        .sink_lane = 2,
        .target = target,
    });
    const remaining_converged = solvePacked(&solver);
    var offset: usize = 0;
    if (has_fan) {
        out[1] = try runScenario(allocator, inputs, .fan, null);
        offset = 1;
    }
    for (remaining[0..2], 0..) |scenario, lane| {
        const grid = try makeGrid(allocator, inputs.board);
        packedLaneToGrid(&solver, lane, grid);
        out[lane + 1 + offset] = try summarizeScenario(allocator, grid, inputs, scenario, null, remaining_converged);
    }
    const sink_grid = try makeGrid(allocator, inputs.board);
    packedLaneToGrid(&solver, 2, sink_grid);
    out[3 + offset] = try summarizeScenario(allocator, sink_grid, inputs, .heatsink, target, remaining_converged);
    return out;
}

/// Solve exactly ONE scenario over `inputs` — what a caller rendering a single
/// view needs, instead of paying for the whole ladder to throw three of it away.
///
/// The heatsink rung is the one that cannot stand alone: its sink goes on the
/// part with the least junction margin IN STILL AIR (see `solveScenarios`), so
/// asking for it also solves `natural` first and costs two solves. Every other
/// scenario costs exactly one, and returns the same result `solveScenarios`
/// would have put in that slot.
pub fn solveScenario(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    scenario: Scenario,
) std.mem.Allocator.Error!ScenarioResult {
    if (scenario != .heatsink) return runScenario(allocator, inputs, scenario, null);
    const still = try runScenario(allocator, inputs, .natural, null);
    return runScenario(allocator, inputs, .heatsink, configuredHeatsinkTarget(inputs, still.parts));
}

fn configuredHeatsinkTarget(inputs: Inputs, parts: []const PartField) ?[]const u8 {
    if (inputs.cooling.heatsink.ref_des.len == 0) return heatsinkTarget(parts);
    for (parts) |part| {
        if (std.mem.eql(u8, part.ref_des, inputs.cooling.heatsink.ref_des)) return part.ref_des;
    }
    return null;
}

/// The part a heatsink would go on: the least junction margin (the smallest
/// `max_ambient_c`), else — when nothing declares enough for a margin — simply
/// the hottest junction, with its board rise standing in where there is no θJB.
/// Null for a board with no placed parts. Ties keep input order.
///
/// Public because the surfaces that RENDER the ladder have to name the part the
/// heatsink rung is about ("Heatsink on U5"), and re-deriving that rule at the
/// presentation layer is exactly how two answers about one board come to
/// disagree.
pub fn heatsinkTarget(parts: []const PartField) ?[]const u8 {
    var by_margin: ?PartField = null;
    var by_heat: ?PartField = null;
    for (parts) |p| {
        if (p.max_ambient_c) |c| {
            if (by_margin == null or c < by_margin.?.max_ambient_c.?) by_margin = p;
        }
        if (by_heat == null or hotness(p) > hotness(by_heat.?)) by_heat = p;
    }
    if (by_margin) |p| return p.ref_des;
    if (by_heat) |p| return p.ref_des;
    return null;
}

/// How hot a part runs, junction first and board copper as the stand-in.
fn hotness(p: PartField) f64 {
    return p.tj_rise_c orelse p.board_rise_c;
}

/// Build, solve and summarize one scenario. `target` names the part the sink is
/// bolted to, and is meaningful only for `.heatsink`.
fn runScenario(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    scenario: Scenario,
    target: ?[]const u8,
) std.mem.Allocator.Error!ScenarioResult {
    const grid = try makeGrid(allocator, inputs.board);
    var solver = try buildSolver(allocator, grid, inputs, scenario, target);
    const converged = solveWork(&solver);
    for (grid.rise_c, solver.rise) |*out, rise| out.* = @floatCast(rise);

    return summarizeScenario(allocator, grid, inputs, scenario, target, converged);
}

fn summarizeScenario(
    allocator: std.mem.Allocator,
    grid: FieldGrid,
    inputs: Inputs,
    scenario: Scenario,
    target: ?[]const u8,
    converged: bool,
) std.mem.Allocator.Error!ScenarioResult {
    const rows = try partRows(allocator, grid, .{
        .sheet = resolvedSheet(inputs),
        .board = inputs.board,
    }, inputs.parts, .{ .scenario = scenario, .target = target, .heatsink = inputs.cooling.heatsink });
    return .{
        .scenario = scenario,
        .grid = grid,
        .parts = rows.parts,
        .skipped = rows.skipped,
        .hotspot = hotspotOf(grid),
        .max_ambient = maxAmbient(rows.parts, inputs.ratings_cap),
        .converged = converged,
        .cooling = .{
            .heatsink = .{
                .ref = if (scenario == .heatsink) target orelse "" else "",
                .side = if (scenario == .heatsink and target != null) inputs.cooling.heatsink.side else null,
                .face = if (scenario == .heatsink and target != null) inputs.cooling.heatsink.physical_face else null,
            },
            .fan = .{
                .model = if (scenario == .fan) inputs.cooling.fan.model else "",
                .face = if (scenario == .fan and inputs.cooling.fan.enabled()) inputs.cooling.fan.face else null,
                .velocity_m_s = if (scenario == .fan) fanVelocity(inputs.cooling.fan) else 0,
                .operating_flow_m3_s = if (scenario == .fan) inputs.cooling.fan.operatingFlow() else 0,
                .estimated_pressure_pa = if (scenario == .fan) inputs.cooling.fan.estimatedPressure() else 0,
            },
        },
    };
}

// ── Grid construction ─────────────────────────────────────────────────────

/// Square cell size for a board whose longer side is `long_mm` — the long axis
/// cut into `cells_long_axis`, clamped so the model neither resolves detail it
/// cannot carry nor smears a hotspot across a quarter of the board.
fn cellSize(long_mm: f64) f64 {
    if (!std.math.isFinite(long_mm) or long_mm <= 0) return min_cell_mm;
    return std.math.clamp(long_mm / @as(f64, @floatFromInt(cells_long_axis)), min_cell_mm, max_cell_mm);
}

/// Cells spanning `span_mm` at `cell_mm`, rounded to the nearest whole cell and
/// held inside `[1, max_cells_axis]`. The modelled board is therefore the
/// authored rectangle to within half a cell on each axis.
fn cellCount(span_mm: f64, cell_mm: f64) usize {
    const n = numeric.checkedInt(usize, span_mm / cell_mm) orelse 1;
    return std.math.clamp(n, 1, max_cells_axis);
}

/// The cells a board resolves to, without solving anything.
///
/// Public because a caller rasterizing a `Coverage` map has to hit EXACTLY the
/// cells the solve will use, and re-deriving the cell size at the projection
/// layer is precisely how a map comes to be silently half a cell out.
pub const GridShape = struct {
    cols: usize,
    rows: usize,
    cell_mm: f64,
    origin_x_mm: f64,
    origin_y_mm: f64,
};

/// Inclusive cell block covered by a board-space rectangle. Exporters use this
/// to measure the same cells the built-in solver assigns to a component.
pub const CellBlock = struct {
    col_lo: usize,
    col_hi: usize,
    row_lo: usize,
    row_hi: usize,
};

/// The cells `box` covers on `shape`, with the same edge clamping and
/// zero-area behavior as the built-in heat-source projection.
pub fn cellsForBox(shape: GridShape, box: BoardRect) CellBlock {
    const x0 = @min(box.x_mm, box.x_mm + box.w_mm);
    const x1 = @max(box.x_mm, box.x_mm + box.w_mm);
    const y0 = @min(box.y_mm, box.y_mm + box.h_mm);
    const y1 = @max(box.y_mm, box.y_mm + box.h_mm);
    return .{
        .col_lo = cellIndex(x0, shape.origin_x_mm, shape.cell_mm, shape.cols),
        .col_hi = cellIndex(x1, shape.origin_x_mm, shape.cell_mm, shape.cols),
        .row_lo = cellIndex(y0, shape.origin_y_mm, shape.cell_mm, shape.rows),
        .row_hi = cellIndex(y1, shape.origin_y_mm, shape.cell_mm, shape.rows),
    };
}

/// The grid `board` is cut into. Every cell is a board cell: the outline is a
/// rectangle and the grid is cut from it, so there is nothing outside to
/// exclude.
pub fn gridShape(board: BoardRect) GridShape {
    const cell = cellSize(@max(board.w_mm, board.h_mm));
    return .{
        .cols = cellCount(board.w_mm, cell),
        .rows = cellCount(board.h_mm, cell),
        .cell_mm = cell,
        .origin_x_mm = if (std.math.isFinite(board.x_mm)) board.x_mm else 0,
        .origin_y_mm = if (std.math.isFinite(board.y_mm)) board.y_mm else 0,
    };
}

/// The zeroed rise field over `gridShape(board)`.
fn makeGrid(allocator: std.mem.Allocator, board: BoardRect) std.mem.Allocator.Error!FieldGrid {
    const shape = gridShape(board);
    const rise = try allocator.alloc(f32, shape.cols * shape.rows);
    @memset(rise, 0);
    return .{
        .cols = shape.cols,
        .rows = shape.rows,
        .cell_mm = shape.cell_mm,
        .origin_x_mm = shape.origin_x_mm,
        .origin_y_mm = shape.origin_y_mm,
        .rise_c = rise,
    };
}

/// The inclusive cell index range a rectangle covers on one axis.
const Span = struct { lo: usize, hi: usize };

/// Which cell a board coordinate falls in, clamped into the grid — so a part
/// hanging off the edge docks onto the nearest cell instead of vanishing, and a
/// zero-area box resolves to the single cell containing it. `count` is a grid
/// axis, which `cellCount` guarantees is at least 1; the guard is belt and
/// braces against an underflow rather than a case that can arise.
fn cellIndex(v_mm: f64, origin_mm: f64, cell_mm: f64, count: usize) usize {
    if (count == 0) return 0;
    const raw = @floor((v_mm - origin_mm) / cell_mm);
    const hi: f64 = @floatFromInt(count - 1);
    return numeric.checkedInt(usize, std.math.clamp(raw, 0, hi)) orelse 0;
}

/// The cell block a part's box covers, as inclusive column and row spans.
fn boxSpans(grid: FieldGrid, box: BoardRect) [2]Span {
    const cells = cellsForBox(.{
        .cols = grid.cols,
        .rows = grid.rows,
        .cell_mm = grid.cell_mm,
        .origin_x_mm = grid.origin_x_mm,
        .origin_y_mm = grid.origin_y_mm,
    }, box);
    return .{
        .{ .lo = cells.col_lo, .hi = cells.col_hi },
        .{ .lo = cells.row_lo, .hi = cells.row_hi },
    };
}

/// How many cells that block holds — always at least one.
fn spanCells(spans: [2]Span) usize {
    return (spans[0].hi - spans[0].lo + 1) * (spans[1].hi - spans[1].lo + 1);
}

// ── The linear system ─────────────────────────────────────────────────────

/// One scenario's assembled system. Everything is per-cell: `sheet` because the
/// outer pours are patchy, `to_ambient` because a part body blocks the face it
/// sits on and the heatsink's extraction lands on one part's cells.
const Work = struct {
    cols: usize,
    rows: usize,
    /// In-plane conductance of each cell's own square of board (W/K). Two
    /// neighbours couple through `pairG` of theirs, not through either alone.
    sheet: []f64,
    /// Conductance from each cell to ambient (W/K): its two faces, plus any sink.
    to_ambient: []f64,
    /// Watts injected into each cell.
    power: []f64,
};

/// Immutable uniquely-owned edges for one board cell. Conductances are `f32`
/// because the public field is `f32` and the screening model does not carry
/// sub-microkelvin precision; the relaxation scale and iterated rise stay `f64`
/// so a tight residual can still converge without accumulating roundoff.
///
/// East and south are the two uniquely-owned edges. West is the preceding
/// cell's east edge and north is the preceding row's south edge, so each shared
/// conductance is stored once instead of twice.
const Stencil = struct {
    east: f32 = 0,
    south: f32 = 0,
};

/// Hot solver state. Stencils and ambient conductances are immutable, compact
/// streams; the only write-heavy stream is `rise`. Source reuses the public
/// f32 output grid until that grid is filled with the final rises, leaving 28
/// bytes/cell of solver-only state versus the old four-f64-array layout's 32.
/// The f64 `scale = omega / diagonal` removes every division and diagonal
/// rebuild from the hot sweep while preserving the original residual bound.
const Solver = struct {
    cols: usize,
    rows: usize,
    stencil: []Stencil,
    scale: []f64,
    source: []f32,
    to_ambient: []f32,
    rise: []f64,
    total_power: f64,
    omega: f64,
};

/// Four lanes match the four cooling scenarios and the target machine's AVX2
/// f64 width. The first packed pass duplicates natural cooling; after that
/// field identifies the heatsink target, the same storage is reconfigured for
/// airflow 1 m/s, airflow 2 m/s, heatsink, plus a duplicate of the fastest lane.
const simd_scenarios: usize = 4;
const ScenarioF64 = @Vector(simd_scenarios, f64);
const ScenarioF32 = @Vector(simd_scenarios, f32);

const PackedSolver = struct {
    cols: usize,
    rows: usize,
    stencil: []Stencil,
    scale: []ScenarioF64,
    source: []ScenarioF32,
    to_ambient: []ScenarioF32,
    rise: []ScenarioF64,
    total_power: ScenarioF64,
    omega: f64,
};

const PackedConfig = struct {
    scenarios: [simd_scenarios]Scenario,
    sink_lane: ?usize = null,
    target: ?[]const u8 = null,
};

/// Per-cell physical coefficients exported to an independent finite-element
/// solver. The arrays are row-major and index-aligned with `shape`.
pub const Discretized = struct {
    shape: GridShape,
    thickness_m: f64,
    /// Equivalent in-plane conductivity (W/m·K). Multiplying by
    /// `thickness_m` recovers the built-in sheet conductance.
    conductivity_w_mk: []const f64,
    /// Face-specific film/sink coefficients (W/m²K). Keeping these separate is
    /// what lets Elmer put a package sink and a backside cold plate on opposite
    /// physical boundaries while preserving the built-in total conductance.
    top_face_h_w_m2k: []const f64,
    bottom_face_h_w_m2k: []const f64,
    /// Volumetric heat generation (W/m³), one value per board cell.
    heat_source_w_m3: []const f64,
};

/// Assemble the same cell coefficients the built-in solver uses, expressed as
/// a one-element-through-thickness 3D continuum for Elmer or another FEM tool.
/// This is intentionally an export of the screening model, not a second set of
/// thermal assumptions.
pub fn discretize(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    scenario: Scenario,
) std.mem.Allocator.Error!Discretized {
    const grid = try makeGrid(allocator, inputs.board);
    var target: ?[]const u8 = null;
    if (scenario == .heatsink) {
        if (inputs.cooling.heatsink.ref_des.len > 0) {
            target = inputs.cooling.heatsink.ref_des;
        } else {
            const still = try runScenario(allocator, inputs, .natural, null);
            target = heatsinkTarget(still.parts);
        }
    }
    const work = try buildWork(allocator, grid, inputs, scenario, target);
    const n = grid.cols * grid.rows;
    const conductivity = try allocator.alloc(f64, n);
    const top_face_h = try allocator.alloc(f64, n);
    const bottom_face_h = try allocator.alloc(f64, n);
    const heat_source = try allocator.alloc(f64, n);
    const sheet = resolvedSheet(inputs);
    const thickness = if (std.math.isFinite(sheet.laminate_m) and sheet.laminate_m > 0)
        sheet.laminate_m
    else
        board_thickness_m;
    const cell_m = grid.cell_mm * 1.0e-3;
    const face_area = cell_m * cell_m;
    const volume = face_area * thickness;
    try fillDiscretizedFaces(allocator, .{ .top = top_face_h, .bottom = bottom_face_h }, grid, inputs, scenario, target);
    for (0..n) |i| {
        conductivity[i] = work.sheet[i] / thickness;
        heat_source[i] = work.power[i] / volume;
    }
    return .{
        .shape = .{
            .cols = grid.cols,
            .rows = grid.rows,
            .cell_mm = grid.cell_mm,
            .origin_x_mm = grid.origin_x_mm,
            .origin_y_mm = grid.origin_y_mm,
        },
        .thickness_m = thickness,
        .conductivity_w_mk = conductivity,
        .top_face_h_w_m2k = top_face_h,
        .bottom_face_h_w_m2k = bottom_face_h,
        .heat_source_w_m3 = heat_source,
    };
}

const FaceCoefficients = struct { top: []f64, bottom: []f64 };

fn fillDiscretizedFaces(
    allocator: std.mem.Allocator,
    faces_out: FaceCoefficients,
    grid: FieldGrid,
    inputs: Inputs,
    scenario: Scenario,
    target: ?[]const u8,
) std.mem.Allocator.Error!void {
    const covered = try allocator.alloc([2]bool, faces_out.top.len);
    defer allocator.free(covered);
    @memset(covered, .{ false, false });
    for (inputs.parts) |part| {
        const box = part.mount.box orelse continue;
        markFace(grid.cols, covered, boxSpans(grid, box), part.mount.side);
    }
    for (faces_out.top, faces_out.bottom, covered, 0..) |*top_h, *bottom_h, faces, i| {
        top_h.* = faceFilmCoefficient(inputs, scenario, grid, i, .top) * faceFactor(faces[@backingInt(Side.top)]);
        bottom_h.* = faceFilmCoefficient(inputs, scenario, grid, i, .bottom) * faceFactor(faces[@backingInt(Side.bottom)]);
    }
    const cell_m = grid.cell_mm * 1.0e-3;
    const face_area = cell_m * cell_m;
    for (inputs.parts) |part| {
        const effect = heatsinkEffect(part, inputs, grid, scenario, target) orelse continue;
        const share: f64 = @floatFromInt(spanCells(effect.spans));
        const extra_h = effect.conductance_w_per_k / share / face_area;
        var row = effect.spans[1].lo;
        while (row <= effect.spans[1].hi) : (row += 1) {
            var col = effect.spans[0].lo;
            while (col <= effect.spans[0].hi) : (col += 1) {
                const i = row * grid.cols + col;
                if (effect.face == .top) faces_out.top[i] += extra_h else faces_out.bottom[i] += extra_h;
            }
        }
    }
}

const HeatsinkEffect = struct {
    spans: [2]Span,
    conductance_w_per_k: f64,
    /// Fraction of package power that enters the board. A backside sink leaves
    /// this at one; a package-top sink splits heat between board and sink.
    source_fraction: f64,
    face: Side,
};

fn heatsinkEffect(
    part: PartInput,
    inputs: Inputs,
    grid: FieldGrid,
    scenario: Scenario,
    target: ?[]const u8,
) ?HeatsinkEffect {
    if (!isTarget(scenario, target, part.ref_des)) return null;
    const part_box = part.mount.box orelse return null;
    const hs = inputs.cooling.heatsink;
    return switch (hs.side) {
        .package_top => blk: {
            const jc = validNonnegative(part.theta_jc.top) orelse break :blk null;
            const contact = clippedRect(part_box, inputs.board) orelse break :blk null;
            const rb_package = validPositive(junctionToBoard(part)) orelse break :blk null;
            const land_m2 = contact.w_mm * contact.h_mm * square_mm_to_m2;
            const rb = rb_package + transferResistance(part, land_m2, .{
                .sheet = resolvedSheet(inputs),
                .board = inputs.board,
            });
            const rs = jc + padResistance(hs, land_m2) + sinkToAmbient(hs);
            const total = rb + rs;
            if (!(total > 0) or !std.math.isFinite(total)) break :blk null;
            break :blk .{
                .spans = boxSpans(grid, contact),
                .conductance_w_per_k = 1.0 / total,
                .source_fraction = rs / total,
                .face = part.mount.side,
            };
        },
        .board_backside => blk: {
            const contact = clippedRect(sinkRect(hs, part_box), inputs.board) orelse break :blk null;
            const area_m2 = contact.w_mm * contact.h_mm * square_mm_to_m2;
            const resistance = padResistance(hs, area_m2) + sinkToAmbient(hs);
            if (!(resistance > 0) or !std.math.isFinite(resistance)) break :blk null;
            break :blk .{
                .spans = boxSpans(grid, contact),
                .conductance_w_per_k = 1.0 / resistance,
                .source_fraction = 1.0,
                .face = opposite(part.mount.side),
            };
        },
    };
}

fn validPositive(value: ?f64) ?f64 {
    const v = value orelse return null;
    if (!(v > 0) or !std.math.isFinite(v)) return null;
    return v;
}

fn validNonnegative(value: ?f64) ?f64 {
    const v = value orelse return null;
    if (v < 0 or !std.math.isFinite(v)) return null;
    return v;
}

/// Resolved sink-to-ambient resistance. A saved drawn extrusion carries fin
/// thickness/gap and is estimated from plate-fin efficiency plus exposed
/// area; legacy/CLI sinks with zero fin thickness retain their rated theta-SA.
pub fn sinkToAmbient(hs: Heatsink) f64 {
    if (geometryDriven(hs.geometry)) return estimatedThetaSa(hs);
    if (std.math.isFinite(hs.theta_sa_c_per_w) and hs.theta_sa_c_per_w >= 0) return hs.theta_sa_c_per_w;
    return default_theta_sa_c_per_w;
}

/// Number of whole fins that fit the authored base at its stated pitch.
pub fn finCount(geometry: HeatsinkGeometry) usize {
    if (!geometryDriven(geometry)) return @max(geometry.fin_count, 1);
    const across = if (geometry.fin_axis == .length) geometry.width_mm else geometry.length_mm;
    const pitch = geometry.fin_thickness_mm + geometry.fin_gap_mm;
    if (!(across > 0 and pitch > 0)) return 1;
    const count = @floor((across + geometry.fin_gap_mm) / pitch);
    return @min(@max(numeric.checkedInt(usize, @max(count, 1)) orelse 1, 1), max_sink_fin_count);
}

fn geometryDriven(geometry: HeatsinkGeometry) bool {
    return std.math.isFinite(geometry.fin_thickness_mm) and geometry.fin_thickness_mm > 0 and
        std.math.isFinite(geometry.fin_gap_mm) and geometry.fin_gap_mm >= 0;
}

fn estimatedThetaSa(hs: Heatsink) f64 {
    const g = hs.geometry;
    const width_m = g.width_mm * 1.0e-3;
    const length_m = g.length_mm * 1.0e-3;
    const fin_h_m = g.fin_height_mm * 1.0e-3;
    const fin_t_m = g.fin_thickness_mm * 1.0e-3;
    const base_m = g.base_mm * 1.0e-3;
    if (!(width_m > 0)) return default_theta_sa_c_per_w;
    if (!(length_m > 0)) return default_theta_sa_c_per_w;
    if (!(fin_h_m >= 0)) return default_theta_sa_c_per_w;
    if (!(fin_t_m > 0)) return default_theta_sa_c_per_w;
    if (!(base_m > 0)) return default_theta_sa_c_per_w;

    const n: f64 = @floatFromInt(finCount(g));
    const fin_length_m = if (g.fin_axis == .length) length_m else width_m;
    const across_m = if (g.fin_axis == .length) width_m else length_m;
    const k = hs.material.conductivity();
    const m_l = fin_h_m * @sqrt(2.0 * h_natural / (k * fin_t_m));
    const efficiency = if (m_l > 1.0e-9) std.math.tanh(m_l) / m_l else 1.0;
    const fin_area = n * fin_length_m * (2.0 * fin_h_m + fin_t_m);
    const base_open = fin_length_m * @max(across_m - n * fin_t_m, 0);
    const effective_area = base_open + efficiency * fin_area;
    if (!(effective_area > 0)) return default_theta_sa_c_per_w;
    const convection = 1.0 / (h_natural * effective_area);
    const base_conduction = base_m / (k * width_m * length_m);
    return convection + base_conduction;
}

fn padResistance(hs: Heatsink, area_m2: f64) f64 {
    if (!(area_m2 > 0)) return std.math.inf(f64);
    const thickness_mm = if (std.math.isFinite(hs.pad.thickness_mm) and hs.pad.thickness_mm >= 0)
        hs.pad.thickness_mm
    else
        default_pad_thickness_mm;
    const k = if (std.math.isFinite(hs.pad.conductivity_w_mk) and hs.pad.conductivity_w_mk > 0)
        hs.pad.conductivity_w_mk
    else
        default_pad_k_w_mk;
    return thickness_mm * 1.0e-3 / (k * area_m2);
}

fn sinkRect(hs: Heatsink, part: BoardRect) BoardRect {
    if (hs.contact) |contact| return contact;
    const width = if (std.math.isFinite(hs.geometry.width_mm) and hs.geometry.width_mm > 0) hs.geometry.width_mm else default_sink_width_mm;
    const length = if (std.math.isFinite(hs.geometry.length_mm) and hs.geometry.length_mm > 0) hs.geometry.length_mm else default_sink_length_mm;
    const cx = part.x_mm + 0.5 * part.w_mm;
    const cy = part.y_mm + 0.5 * part.h_mm;
    return .{ .x_mm = cx - 0.5 * width, .y_mm = cy - 0.5 * length, .w_mm = width, .h_mm = length };
}

fn clippedRect(rect: BoardRect, board: BoardRect) ?BoardRect {
    const x0 = @max(rect.x_mm, board.x_mm);
    const y0 = @max(rect.y_mm, board.y_mm);
    const x1 = @min(rect.x_mm + rect.w_mm, board.x_mm + board.w_mm);
    const y1 = @min(rect.y_mm + rect.h_mm, board.y_mm + board.h_mm);
    if (!(x1 > x0) or !(y1 > y0)) return null;
    return .{ .x_mm = x0, .y_mm = y0, .w_mm = x1 - x0, .h_mm = y1 - y0 };
}

fn opposite(side: Side) Side {
    return if (side == .top) .bottom else .top;
}

/// Assemble the system for one scenario over `grid`.
fn buildWork(
    allocator: std.mem.Allocator,
    grid: FieldGrid,
    inputs: Inputs,
    scenario: Scenario,
    target: ?[]const u8,
) std.mem.Allocator.Error!Work {
    const n = grid.cols * grid.rows;

    var work = Work{
        .cols = grid.cols,
        .rows = grid.rows,
        .sheet = try allocator.alloc(f64, n),
        .to_ambient = try allocator.alloc(f64, n),
        .power = try allocator.alloc(f64, n),
    };
    fillSheet(&work, inputs);
    try fillFaces(allocator, &work, grid, inputs, scenario);
    @memset(work.power, 0);

    for (inputs.parts) |part| {
        const box = part.mount.box orelse continue;
        const spans = boxSpans(grid, box);
        const share: f64 = @floatFromInt(spanCells(spans));
        const effect = heatsinkEffect(part, inputs, grid, scenario, target);
        const source_fraction = if (effect) |e| e.source_fraction else 1.0;
        spread(&work, spans, injectedWatts(part) * source_fraction / share);
        if (effect) |e| {
            const sink_share: f64 = @floatFromInt(spanCells(e.spans));
            sink(&work, e.spans, e.conductance_w_per_k / sink_share);
        }
    }
    return work;
}

/// Assemble the compact, precomputed form used by the relaxation kernel. Sheet
/// and face coefficients are built directly into their final-width streams;
/// unlike `buildWork` (the FEM export path), this never allocates three f64
/// assembly arrays that the iterative solve would immediately stop needing.
fn buildSolver(
    allocator: std.mem.Allocator,
    grid: FieldGrid,
    inputs: Inputs,
    scenario: Scenario,
    target: ?[]const u8,
) std.mem.Allocator.Error!Solver {
    const n = grid.cols * grid.rows;
    const stencil = try allocator.alloc(Stencil, n);
    const scale = try allocator.alloc(f64, n);
    const source = grid.rise_c;
    const to_ambient = try allocator.alloc(f32, n);
    const rise = try allocator.alloc(f64, n);
    @memset(stencil, .{});
    @memset(source, 0);
    @memset(rise, 0);

    const sheet = resolvedSheet(inputs);
    const frac = solverCoverage(inputs.coverage, grid.cols, grid.rows);
    if (frac.len == 0) {
        @memset(scale, sheetConductance(sheet, 1.0));
    } else {
        for (scale, frac) |*conductance, coverage| conductance.* = sheetConductance(sheet, coverage);
    }
    try fillSolverFaces(allocator, to_ambient, grid, inputs, scenario);

    // A sink changes the diagonal and, for a package-top path, diverts a known
    // fraction of the source before it reaches the board. Apply conductance
    // before scale preparation; source is added after the final scale exists.
    for (inputs.parts) |part| {
        if (part.mount.box == null) continue;
        if (heatsinkEffect(part, inputs, grid, scenario, target)) |effect| {
            const share: f64 = @floatFromInt(spanCells(effect.spans));
            addSolverSink(to_ambient, grid.cols, effect.spans, effect.conductance_w_per_k / share);
        }
    }

    // During these two passes `scale` temporarily holds the sheet conductance.
    // Edges are prepared first so every neighbour's sheet value is still live;
    // only then may the field be overwritten with omega/diagonal.
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        var c: usize = 0;
        while (c < grid.cols) : (c += 1) {
            const i = r * grid.cols + c;
            const here = scale[i];
            if (c + 1 < grid.cols) stencil[i].east = @floatCast(pairG(here, scale[i + 1]));
            if (r + 1 < grid.rows) stencil[i].south = @floatCast(pairG(here, scale[i + grid.cols]));
        }
    }
    const omega = relaxationFactor(@max(grid.cols, grid.rows));
    r = 0;
    while (r < grid.rows) : (r += 1) {
        var c: usize = 0;
        while (c < grid.cols) : (c += 1) {
            const i = r * grid.cols + c;
            const diag = @as(f64, to_ambient[i]) +
                (if (c > 0) stencil[i - 1].east else 0) + stencil[i].east +
                (if (r > 0) stencil[i - grid.cols].south else 0) + stencil[i].south;
            scale[i] = if (diag > 0) omega / diag else 0;
        }
    }

    for (inputs.parts) |part| {
        const box = part.mount.box orelse continue;
        const effect = heatsinkEffect(part, inputs, grid, scenario, target);
        const watts = injectedWatts(part) * if (effect) |e| e.source_fraction else 1.0;
        const spans = boxSpans(grid, box);
        const share: f64 = @floatFromInt(spanCells(spans));
        addSolverSource(source, scale, grid.cols, spans, watts / share);
    }
    // Reconstruct the total represented by the quantized source stream. Global
    // rebalancing and local residuals must conserve the SAME number; using the
    // pre-quantization part sum here would leave a tiny, irreducible mismatch
    // larger than the intentionally tight convergence tolerance.
    var total_power: f64 = 0;
    for (source, scale) |cell_source, cell_scale| {
        if (cell_scale > 0) total_power += @as(f64, cell_source) / cell_scale;
    }
    return .{
        .cols = grid.cols,
        .rows = grid.rows,
        .stencil = stencil,
        .scale = scale,
        .source = source,
        .to_ambient = to_ambient,
        .rise = rise,
        .total_power = total_power,
        .omega = omega,
    };
}

/// Build scenario-independent sheet edges once. The vector streams are filled
/// by `configurePackedSolver` for each of the two packed passes.
fn buildPackedSolver(
    allocator: std.mem.Allocator,
    grid: FieldGrid,
    inputs: Inputs,
) std.mem.Allocator.Error!PackedSolver {
    const n = grid.cols * grid.rows;
    const stencil = try allocator.alloc(Stencil, n);
    const scale = try allocator.alloc(ScenarioF64, n);
    @memset(stencil, .{});

    const sheet = resolvedSheet(inputs);
    const frac = solverCoverage(inputs.coverage, grid.cols, grid.rows);
    if (frac.len == 0) {
        @memset(scale, @splat(sheetConductance(sheet, 1.0)));
    } else {
        for (scale, frac) |*conductance, coverage| {
            conductance.* = @splat(sheetConductance(sheet, coverage));
        }
    }
    var r: usize = 0;
    while (r < grid.rows) : (r += 1) {
        var c: usize = 0;
        while (c < grid.cols) : (c += 1) {
            const i = r * grid.cols + c;
            const here = scale[i][0];
            if (c + 1 < grid.cols) stencil[i].east = @floatCast(pairG(here, scale[i + 1][0]));
            if (r + 1 < grid.rows) stencil[i].south = @floatCast(pairG(here, scale[i + grid.cols][0]));
        }
    }
    return .{
        .cols = grid.cols,
        .rows = grid.rows,
        .stencil = stencil,
        .scale = scale,
        .source = try allocator.alloc(ScenarioF32, n),
        .to_ambient = try allocator.alloc(ScenarioF32, n),
        .rise = try allocator.alloc(ScenarioF64, n),
        .total_power = @splat(0),
        .omega = relaxationFactor(@max(grid.cols, grid.rows)),
    };
}

/// Refill scenario-dependent face conductance, relaxation scale and source
/// lanes while preserving the sheet-edge stencil. `sink_lane` is null for the
/// natural pass and lane 2 for the remaining-scenarios pass.
fn configurePackedSolver(
    allocator: std.mem.Allocator,
    work: *PackedSolver,
    grid: FieldGrid,
    inputs: Inputs,
    config: PackedConfig,
) std.mem.Allocator.Error!void {
    const covered = try allocator.alloc([2]bool, work.stencil.len);
    defer allocator.free(covered);
    @memset(covered, .{ false, false });
    for (inputs.parts) |part| {
        const box = part.mount.box orelse continue;
        markFace(work.cols, covered, boxSpans(grid, box), part.mount.side);
    }
    const cell_m = grid.cell_mm * 1.0e-3;
    const area = cell_m * cell_m;
    var open: ScenarioF64 = undefined;
    inline for (0..simd_scenarios) |lane| open[lane] = config.scenarios[lane].filmCoefficient() * area;
    for (work.to_ambient, covered) |*ambient, faces| {
        const factor = faceFactor(faces[0]) + faceFactor(faces[1]);
        ambient.* = @floatCast(open * @as(ScenarioF64, @splat(factor)));
    }
    if (config.sink_lane) |lane| {
        for (inputs.parts) |part| {
            const effect = heatsinkEffect(part, inputs, grid, .heatsink, config.target) orelse continue;
            const share: f64 = @floatFromInt(spanCells(effect.spans));
            var r = effect.spans[1].lo;
            while (r <= effect.spans[1].hi) : (r += 1) {
                var c = effect.spans[0].lo;
                while (c <= effect.spans[0].hi) : (c += 1) {
                    const i = r * work.cols + c;
                    var lanes: [simd_scenarios]f32 = work.to_ambient[i];
                    lanes[lane] += @floatCast(effect.conductance_w_per_k / share);
                    work.to_ambient[i] = lanes;
                }
            }
        }
    }

    var r: usize = 0;
    while (r < work.rows) : (r += 1) {
        var c: usize = 0;
        while (c < work.cols) : (c += 1) {
            const i = r * work.cols + c;
            const edge_sum =
                (if (c > 0) @as(f64, work.stencil[i - 1].east) else 0) + work.stencil[i].east +
                (if (r > 0) @as(f64, work.stencil[i - work.cols].south) else 0) + work.stencil[i].south;
            const diag = @as(ScenarioF64, @floatCast(work.to_ambient[i])) + @as(ScenarioF64, @splat(edge_sum));
            work.scale[i] = @as(ScenarioF64, @splat(work.omega)) / diag;
        }
    }

    @memset(work.source, @splat(0));
    @memset(work.rise, @splat(0));
    for (inputs.parts) |part| {
        const box = part.mount.box orelse continue;
        const spans = boxSpans(grid, box);
        const share: f64 = @floatFromInt(spanCells(spans));
        var watts: [simd_scenarios]f64 = @splat(injectedWatts(part));
        if (config.sink_lane) |lane| {
            if (heatsinkEffect(part, inputs, grid, .heatsink, config.target)) |effect| {
                watts[lane] *= effect.source_fraction;
            }
        }
        const watts_vec: ScenarioF64 = watts;
        const per_cell = watts_vec / @as(ScenarioF64, @splat(share));
        r = spans[1].lo;
        while (r <= spans[1].hi) : (r += 1) {
            var c = spans[0].lo;
            while (c <= spans[0].hi) : (c += 1) {
                const i = r * work.cols + c;
                work.source[i] += @floatCast(work.scale[i] * per_cell);
            }
        }
    }
    var total: ScenarioF64 = @splat(0);
    for (work.source, work.scale) |source, scale| total += @as(ScenarioF64, @floatCast(source)) / scale;
    work.total_power = total;
}

fn packedLaneToGrid(work: *const PackedSolver, lane: usize, grid: FieldGrid) void {
    for (grid.rise_c, work.rise) |*out, rise| {
        const lanes: [simd_scenarios]f64 = rise;
        out.* = @floatCast(lanes[lane]);
    }
}

fn solverCoverage(cov: ?Coverage, cols: usize, rows: usize) []const f32 {
    const coverage = cov orelse return &.{};
    if (coverage.cols != cols or coverage.rows != rows) return &.{};
    if (coverage.outer_frac.len != cols * rows) return &.{};
    return coverage.outer_frac;
}

fn fillSolverFaces(
    allocator: std.mem.Allocator,
    to_ambient: []f32,
    grid: FieldGrid,
    inputs: Inputs,
    scenario: Scenario,
) std.mem.Allocator.Error!void {
    const cell_m = grid.cell_mm * 1.0e-3;
    const area = cell_m * cell_m;
    const covered = try allocator.alloc([2]bool, to_ambient.len);
    defer allocator.free(covered);
    @memset(covered, .{ false, false });
    for (inputs.parts) |part| {
        const box = part.mount.box orelse continue;
        markFace(grid.cols, covered, boxSpans(grid, box), part.mount.side);
    }
    for (to_ambient, covered, 0..) |*g, faces, i| {
        var conductance: f64 = 0;
        inline for ([_]Side{ .top, .bottom }, 0..) |face, fi| {
            conductance += faceFilmCoefficient(inputs, scenario, grid, i, face) * area * faceFactor(faces[fi]);
        }
        g.* = @floatCast(conductance);
    }
}

fn addSolverSink(to_ambient: []f32, cols: usize, spans: [2]Span, per_cell: f64) void {
    var r = spans[1].lo;
    while (r <= spans[1].hi) : (r += 1) {
        var c = spans[0].lo;
        while (c <= spans[0].hi) : (c += 1) to_ambient[r * cols + c] += @floatCast(per_cell);
    }
}

fn addSolverSource(source: []f32, scale: []const f64, cols: usize, spans: [2]Span, per_cell: f64) void {
    var r = spans[1].lo;
    while (r <= spans[1].hi) : (r += 1) {
        var c = spans[0].lo;
        while (c <= spans[0].hi) : (c += 1) {
            const i = r * cols + c;
            source[i] += @floatCast(scale[i] * per_cell);
        }
    }
}

/// The sheet a run is solved with: the caller's declared stackup, else the
/// screening convention its spreader-layer count implies.
fn resolvedSheet(inputs: Inputs) Sheet {
    return inputs.sheet orelse defaultSheet(inputs.spreader_layers);
}

/// The coverage fractions to use over `work`, or an empty slice meaning "solve
/// the uniform board". A map whose shape does not match the grid is DROPPED
/// rather than stretched: a misaligned map would move copper to the wrong cells,
/// which is worse than the uniform sheet this module has always fallen back to.
fn coverageSlice(cov: ?Coverage, work: *const Work) []const f32 {
    const c = cov orelse return &.{};
    if (c.cols != work.cols or c.rows != work.rows) return &.{};
    if (c.outer_frac.len != work.sheet.len) return &.{};
    return c.outer_frac;
}

/// Fill each cell's in-plane conductance, derating the outer copper by the
/// caller's coverage map where there is one.
fn fillSheet(work: *Work, inputs: Inputs) void {
    const sheet = resolvedSheet(inputs);
    const frac = coverageSlice(inputs.coverage, work);
    if (frac.len == 0) {
        @memset(work.sheet, sheetConductance(sheet, 1.0));
        return;
    }
    for (work.sheet, frac) |*g, f| g.* = sheetConductance(sheet, f);
}

/// Fill each cell's path to ambient: its two faces, each at the scenario's film
/// coefficient unless a part body sits on it.
///
/// Coverage is tracked per face as a flag rather than accumulated, so two parts
/// overlapping one cell on the same side block that face once, not twice.
fn fillFaces(
    allocator: std.mem.Allocator,
    work: *Work,
    grid: FieldGrid,
    inputs: Inputs,
    scenario: Scenario,
) std.mem.Allocator.Error!void {
    const cell_m = grid.cell_mm * 1.0e-3;
    const area = cell_m * cell_m;
    const covered = try allocator.alloc([2]bool, work.sheet.len);
    defer allocator.free(covered);
    @memset(covered, .{ false, false });

    for (inputs.parts) |part| {
        const box = part.mount.box orelse continue;
        markFace(work.cols, covered, boxSpans(grid, box), part.mount.side);
    }
    for (work.to_ambient, covered, 0..) |*g, faces, i| {
        g.* = 0;
        inline for ([_]Side{ .top, .bottom }, 0..) |face, fi| {
            g.* += faceFilmCoefficient(inputs, scenario, grid, i, face) * area * faceFactor(faces[fi]);
        }
    }
}

/// Effective jet footprint at the PCB. Standoff widens both dimensions by a
/// conservative free-jet half-angle while preserving the fan centre.
fn fanImpactRect(fan: Fan) ?BoardRect {
    const base = fan.footprint orelse return null;
    if (!fan.enabled()) return null;
    const z = if (std.math.isFinite(fan.distance_mm)) @max(fan.distance_mm, 0) else 0;
    const grow = fan_jet_spread_per_side * z;
    return .{
        .x_mm = base.x_mm - grow,
        .y_mm = base.y_mm - grow,
        .w_mm = base.w_mm + 2 * grow,
        .h_mm = base.h_mm + 2 * grow,
    };
}

/// Area-average jet velocity at the PCB (m/s), from the explicitly assumed
/// installed volume flow divided by the distance-expanded footprint.
pub fn fanVelocity(fan: Fan) f64 {
    const rect = fanImpactRect(fan) orelse return 0;
    const area_m2 = rect.w_mm * rect.h_mm * square_mm_to_m2;
    if (!(area_m2 > 0)) return 0;
    return fan.operatingFlow() / area_m2;
}

/// Film coefficient fitted through the existing 1 m/s and 2 m/s screening
/// rungs: h(0)=10, h(1)=22, h(2)=35 W/m^2K. The velocity is capped because this
/// board-sheet model is not a high-speed impingement CFD solver.
pub fn fanFilmCoefficient(fan: Fan) f64 {
    const v = std.math.clamp(fanVelocity(fan), 0, 20);
    return h_natural + 11.5 * v + 0.5 * v * v;
}

fn faceFilmCoefficient(inputs: Inputs, scenario: Scenario, grid: FieldGrid, i: usize, face: Side) f64 {
    if (scenario != .fan or face != inputs.cooling.fan.face) return scenario.filmCoefficient();
    const impact = fanImpactRect(inputs.cooling.fan) orelse return h_natural;
    const col = i % grid.cols;
    const row = i / grid.cols;
    const x = grid.origin_x_mm + (@as(f64, @floatFromInt(col)) + 0.5) * grid.cell_mm;
    const y = grid.origin_y_mm + (@as(f64, @floatFromInt(row)) + 0.5) * grid.cell_mm;
    const inside = x >= impact.x_mm and x <= impact.x_mm + impact.w_mm and
        y >= impact.y_mm and y <= impact.y_mm + impact.h_mm;
    return if (inside) fanFilmCoefficient(inputs.cooling.fan) else h_natural;
}

/// Flag one side of every cell under a part's box as covered by its body.
fn markFace(cols: usize, covered: [][2]bool, spans: [2]Span, side: Side) void {
    const face = @backingInt(side);
    var r = spans[1].lo;
    while (r <= spans[1].hi) : (r += 1) {
        var c = spans[0].lo;
        while (c <= spans[0].hi) : (c += 1) covered[r * cols + c][face] = true;
    }
}

/// How much of one face's film coefficient survives what sits on it.
fn faceFactor(is_covered: bool) f64 {
    return if (is_covered) covered_face_fraction else 1.0;
}

/// Is this the part the heatsink scenario bolts its sink to?
fn isTarget(scenario: Scenario, target: ?[]const u8, ref_des: []const u8) bool {
    if (scenario != .heatsink) return false;
    const t = target orelse return false;
    return std.mem.eql(u8, t, ref_des);
}

/// What a part actually injects (W). A non-finite or negative figure injects
/// nothing rather than poisoning the whole field with a NaN.
fn injectedWatts(part: PartInput) f64 {
    if (!std.math.isFinite(part.watts) or part.watts <= 0) return 0;
    return part.watts;
}

/// Add `per_cell` watts to every cell of the block.
fn spread(work: *Work, spans: [2]Span, per_cell: f64) void {
    var r = spans[1].lo;
    while (r <= spans[1].hi) : (r += 1) {
        var c = spans[0].lo;
        while (c <= spans[0].hi) : (c += 1) work.power[r * work.cols + c] += per_cell;
    }
}

/// Add `per_cell` W/K of extra path to ambient over every cell of the block.
fn sink(work: *Work, spans: [2]Span, per_cell: f64) void {
    var r = spans[1].lo;
    while (r <= spans[1].hi) : (r += 1) {
        var c = spans[0].lo;
        while (c <= spans[0].hi) : (c += 1) work.to_ambient[r * work.cols + c] += per_cell;
    }
}

/// Conductance between two adjacent cells whose own square conductances are `a`
/// and `b`: the harmonic mean, which is the two half-cells in series. On a
/// uniform board `a == b` and this is just that shared value, so a board with no
/// coverage map solves exactly the system it always did.
fn pairG(a: f64, b: f64) f64 {
    const sum = a + b;
    if (!(sum > 0)) return 0;
    return 2.0 * a * b / sum;
}

/// Optimal-ish SOR factor for an `n`-cell axis (the classic
/// `2/(1 + sin(π/n))`), held inside the stable band. A fixed factor would be
/// either slow on a fine grid or unstable on a coarse one.
fn relaxationFactor(n: usize) f64 {
    const nf: f64 = @floatFromInt(@max(n, 1));
    return std.math.clamp(2.0 / (1.0 + @sin(std.math.pi / nf)), min_omega, max_omega);
}

/// One deterministic row-major SOR sweep. Returns the largest cell imbalance
/// seen BEFORE that cell was relaxed — a free convergence signal, since the
/// update is exactly `residual / diag`.
fn sweep(work: *Solver, tolerance: f64) bool {
    var settled = true;
    var r: usize = 0;
    while (r < work.rows) : (r += 1) {
        var c: usize = 0;
        while (c < work.cols) : (c += 1) {
            const i = r * work.cols + c;
            const cell = work.stencil[i];
            const flow =
                (if (c > 0) @as(f64, work.stencil[i - 1].east) * work.rise[i - 1] else 0) +
                (if (c + 1 < work.cols) @as(f64, cell.east) * work.rise[i + 1] else 0) +
                (if (r > 0) @as(f64, work.stencil[i - work.cols].south) * work.rise[i - work.cols] else 0) +
                (if (r + 1 < work.rows) @as(f64, cell.south) * work.rise[i + work.cols] else 0);
            // `delta == scale * residual`, so comparing it with
            // `tolerance * scale` is the same physical stopping test without
            // recovering the diagonal through a division.
            const delta = @as(f64, work.source[i]) + work.scale[i] * flow - work.omega * work.rise[i];
            if (@abs(delta) > tolerance * work.scale[i]) settled = false;
            work.rise[i] += delta;
        }
    }
    return settled;
}

/// Whether every cell's current power imbalance meets the physical tolerance.
fn residualSettled(work: *const Solver, tolerance: f64) bool {
    var r: usize = 0;
    while (r < work.rows) : (r += 1) {
        var c: usize = 0;
        while (c < work.cols) : (c += 1) {
            const i = r * work.cols + c;
            const cell = work.stencil[i];
            const flow =
                (if (c > 0) @as(f64, work.stencil[i - 1].east) * work.rise[i - 1] else 0) +
                (if (c + 1 < work.cols) @as(f64, cell.east) * work.rise[i + 1] else 0) +
                (if (r > 0) @as(f64, work.stencil[i - work.cols].south) * work.rise[i - work.cols] else 0) +
                (if (r + 1 < work.rows) @as(f64, cell.south) * work.rise[i + work.cols] else 0);
            const delta = @as(f64, work.source[i]) + work.scale[i] * flow - work.omega * work.rise[i];
            if (@abs(delta) > tolerance * work.scale[i]) return false;
        }
    }
    return true;
}

/// Shift the whole field by the constant that makes the board's GLOBAL power
/// balance exact: everything shed through the faces and the sink must equal
/// everything injected.
///
/// This is the mode plain relaxation is worst at, and it is worth solving
/// directly. A copper board is a nearly-isolated sheet — the lateral
/// conductance between two cells is thousands of times the conductance from a
/// cell to the air — so the field's SHAPE settles in a few hundred sweeps while
/// its MEAN, which only the tiny face term governs, moves by about one part in
/// ten thousand per sweep and would need six figures' worth of them. The balance
/// states the mean outright, so relaxation is left with only the shape to find.
fn rebalance(work: *Solver) void {
    var conductance: f64 = 0;
    var shed: f64 = 0;
    for (work.to_ambient, work.rise) |g, rise| {
        conductance += g;
        shed += @as(f64, g) * rise;
    }
    if (conductance <= 0) return;
    const delta = (work.total_power - shed) / conductance;
    for (work.rise) |*rise| rise.* += delta;
}

/// Relax until the field satisfies its power balance, or until
/// `max_iterations`. True ⇒ the returned field met the residual bound.
///
/// A board injecting nothing has a tolerance of zero and a field of zeros, whose
/// residual is exactly zero — so it converges on the first check rather than
/// spinning out the iteration budget.
fn solveWork(work: *Solver) bool {
    const tol = residual_tolerance_frac * work.total_power;

    var iter: usize = 0;
    while (iter < max_iterations) : (iter += 1) {
        const settled = sweep(work, tol);
        rebalance(work);
        if (settled) break;
    }
    return residualSettled(work, tol);
}

fn packedSweep(work: *PackedSolver, tolerance: ScenarioF64) bool {
    var settled = true;
    const omega: ScenarioF64 = @splat(work.omega);
    var r: usize = 0;
    while (r < work.rows) : (r += 1) {
        var c: usize = 0;
        while (c < work.cols) : (c += 1) {
            const i = r * work.cols + c;
            const cell = work.stencil[i];
            const flow =
                (if (c > 0) work.rise[i - 1] * @as(ScenarioF64, @splat(work.stencil[i - 1].east)) else @as(ScenarioF64, @splat(0))) +
                (if (c + 1 < work.cols) work.rise[i + 1] * @as(ScenarioF64, @splat(cell.east)) else @as(ScenarioF64, @splat(0))) +
                (if (r > 0) work.rise[i - work.cols] * @as(ScenarioF64, @splat(work.stencil[i - work.cols].south)) else @as(ScenarioF64, @splat(0))) +
                (if (r + 1 < work.rows) work.rise[i + work.cols] * @as(ScenarioF64, @splat(cell.south)) else @as(ScenarioF64, @splat(0)));
            const delta = @as(ScenarioF64, @floatCast(work.source[i])) + work.scale[i] * flow - omega * work.rise[i];
            if (@reduce(.Or, @abs(delta) > tolerance * work.scale[i])) settled = false;
            work.rise[i] += delta;
        }
    }
    return settled;
}

fn packedResidualSettled(work: *const PackedSolver, tolerance: ScenarioF64) bool {
    const omega: ScenarioF64 = @splat(work.omega);
    var r: usize = 0;
    while (r < work.rows) : (r += 1) {
        var c: usize = 0;
        while (c < work.cols) : (c += 1) {
            const i = r * work.cols + c;
            const cell = work.stencil[i];
            const flow =
                (if (c > 0) work.rise[i - 1] * @as(ScenarioF64, @splat(work.stencil[i - 1].east)) else @as(ScenarioF64, @splat(0))) +
                (if (c + 1 < work.cols) work.rise[i + 1] * @as(ScenarioF64, @splat(cell.east)) else @as(ScenarioF64, @splat(0))) +
                (if (r > 0) work.rise[i - work.cols] * @as(ScenarioF64, @splat(work.stencil[i - work.cols].south)) else @as(ScenarioF64, @splat(0))) +
                (if (r + 1 < work.rows) work.rise[i + work.cols] * @as(ScenarioF64, @splat(cell.south)) else @as(ScenarioF64, @splat(0)));
            const delta = @as(ScenarioF64, @floatCast(work.source[i])) + work.scale[i] * flow - omega * work.rise[i];
            if (@reduce(.Or, @abs(delta) > tolerance * work.scale[i])) return false;
        }
    }
    return true;
}

fn packedRebalance(work: *PackedSolver) void {
    var conductance: ScenarioF64 = @splat(0);
    var shed: ScenarioF64 = @splat(0);
    for (work.to_ambient, work.rise) |ambient, rise| {
        const g: ScenarioF64 = @floatCast(ambient);
        conductance += g;
        shed += g * rise;
    }
    const positive = conductance > @as(ScenarioF64, @splat(0));
    const delta = @select(f64, positive, (work.total_power - shed) / conductance, @as(ScenarioF64, @splat(0)));
    for (work.rise) |*rise| rise.* += delta;
}

fn solvePacked(work: *PackedSolver) bool {
    const tolerance = work.total_power * @as(ScenarioF64, @splat(residual_tolerance_frac));
    var iter: usize = 0;
    while (iter < max_iterations) : (iter += 1) {
        const settled = packedSweep(work, tolerance);
        packedRebalance(work);
        if (settled) break;
    }
    return packedResidualSettled(work, tolerance);
}

// ── Reporting ─────────────────────────────────────────────────────────────

/// The placed parts' rows and the ref-des of the ones with no pose.
const PartRows = struct { parts: []const PartField, skipped: []const []const u8 };

/// What a part's junction has to cross to reach the lumped sheet, other than
/// the part itself: bundled so the row builders stay well inside the runtime
/// parameter budget.
const Transfer = struct { sheet: Sheet, board: BoardRect };
const PartScenario = struct {
    scenario: Scenario,
    target: ?[]const u8,
    heatsink: Heatsink,
};

fn partRows(
    allocator: std.mem.Allocator,
    grid: FieldGrid,
    transfer: Transfer,
    parts: []const PartInput,
    context: PartScenario,
) std.mem.Allocator.Error!PartRows {
    var placed: std.ArrayList(PartField) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    for (parts) |part| {
        const box = part.mount.box orelse {
            try skipped.append(allocator, part.ref_des);
            continue;
        };
        try placed.append(allocator, partField(part, grid, boxSpans(grid, box), transfer, context));
    }
    return .{
        .parts = try placed.toOwnedSlice(allocator),
        .skipped = try skipped.toOwnedSlice(allocator),
    };
}

/// One placed part's row: the hottest copper under it, its junction above that,
/// and the ambient that junction leaves room for.
fn partField(
    part: PartInput,
    grid: FieldGrid,
    spans: [2]Span,
    transfer: Transfer,
    context: PartScenario,
) PartField {
    var board_rise: f64 = 0;
    var r = spans[1].lo;
    while (r <= spans[1].hi) : (r += 1) {
        var c = spans[0].lo;
        while (c <= spans[0].hi) : (c += 1) board_rise = @max(board_rise, grid.at(c, r));
    }

    const cell_m = grid.cell_mm * 1.0e-3;
    const land_m2 = @as(f64, @floatFromInt(spanCells(spans))) * cell_m * cell_m;
    var row = PartField{
        .ref_des = part.ref_des,
        .origin_key = part.origin_key,
        .board_rise_c = board_rise,
        .theta_transfer_c_per_w = transferResistance(part, land_m2, transfer),
    };
    if (isTarget(context.scenario, context.target, part.ref_des) and context.heatsink.side == .package_top) {
        const jb = validPositive(junctionToBoard(part)) orelse return row;
        const jc = validNonnegative(part.theta_jc.top) orelse return row;
        const rb = jb + row.theta_transfer_c_per_w;
        const rs = jc + padResistance(context.heatsink, land_m2) + sinkToAmbient(context.heatsink);
        const gb = 1.0 / rb;
        const gs = if (rs > 0) 1.0 / rs else std.math.inf(f64);
        row.jb_estimated = part.theta_jb == null;
        row.junction_path = .package_top;
        row.tj_rise_c = if (std.math.isInf(gs)) 0 else (injectedWatts(part) + gb * board_rise) / (gb + gs);
        if (part.tj_max) |tj| row.max_ambient_c = tj - row.tj_rise_c.?;
        return row;
    }
    if (isTarget(context.scenario, context.target, part.ref_des) and context.heatsink.side == .board_backside) {
        const package_r = validNonnegative(part.theta_jc.bottom) orelse junctionToBoard(part) orelse return row;
        row.jb_estimated = part.theta_jc.bottom == null and part.theta_jb == null;
        row.junction_path = .package_bottom;
        row.tj_rise_c = board_rise + injectedWatts(part) * (package_r + row.theta_transfer_c_per_w);
        if (part.tj_max) |tj| row.max_ambient_c = tj - row.tj_rise_c.?;
        return row;
    }
    const jb = junctionToBoard(part) orelse return row;
    row.jb_estimated = part.theta_jb == null;
    row.tj_rise_c = board_rise + injectedWatts(part) * (jb + row.theta_transfer_c_per_w);
    if (part.tj_max) |tj| row.max_ambient_c = tj - row.tj_rise_c.?;
    return row;
}

/// Resistance from a part's land into the sheet the solve lumps the stack into
/// (K/W): three paths in parallel, so the easiest one governs.
///
/// The 2D sheet assumes the layers are perfectly coupled to each other, which
/// is very nearly true — they are millimetres apart with copper planes between
/// them. What it silently also assumed, before this term existed, is that a
/// PART is perfectly coupled to them, which is not true at all: a QFN's land is
/// a few square millimetres of foil sitting on a dielectric. That is the gap
/// this closes, and it is exactly the gap a via array is drilled to close.
///
/// The constriction term is what keeps the answer bounded on a small land. With
/// only the dielectric and the vias, a vanishing land would give an unbounded
/// resistance; in reality heat also spreads sideways through the part's own
/// outer foil until it reaches copper the sheet is a fair model of, and that
/// path gets EASIER as the land shrinks relative to the board. No clamp needed.
fn transferResistance(part: PartInput, land_m2: f64, transfer: Transfer) f64 {
    if (!(land_m2 > 0)) return 0;
    const g = dielectricG(transfer.sheet, land_m2) +
        viaG(part, transfer.sheet) +
        constrictionG(transfer, land_m2);
    if (!(g > 0)) return 0;
    return 1.0 / g;
}

/// Straight down through the dielectric under the whole land (W/K).
fn dielectricG(sheet: Sheet, land_m2: f64) f64 {
    if (!(sheet.transfer_m > 0)) return 0;
    return k_fr4 * land_m2 / sheet.transfer_m;
}

/// Down the plated barrels of the thermal vias under the land (W/K). The hole
/// itself carries nothing, so each via conducts through its annulus alone, over
/// the full board thickness.
fn viaG(part: PartInput, sheet: Sheet) f64 {
    if (part.mount.thermal_vias == 0 or !(sheet.laminate_m > 0)) return 0;
    const drill_mm = if (std.math.isFinite(part.mount.via_drill_mm) and part.mount.via_drill_mm > 0)
        part.mount.via_drill_mm
    else
        default_via_drill_mm;
    const r_in = 0.5 * drill_mm * 1.0e-3;
    const r_out = r_in + via_plating_m;
    const annulus = std.math.pi * (r_out * r_out - r_in * r_in);
    const n: f64 = @floatFromInt(part.mount.thermal_vias);
    return n * k_copper * annulus / sheet.laminate_m;
}

/// Sideways through the part's OWN outer foil until the land looks like the
/// board (W/K) — the classic radial constriction conductance between a disc of
/// the land's area and one of the board's. The part stands on one face, so it
/// has half the sheet's outer copper under it.
fn constrictionG(transfer: Transfer, land_m2: f64) f64 {
    const board_w_m = @max(transfer.board.w_mm, 0) * 1.0e-3;
    const board_h_m = @max(transfer.board.h_mm, 0) * 1.0e-3;
    const board_m2 = board_w_m * board_h_m;
    const foil_m = 0.5 * transfer.sheet.outer_cu_m;
    if (!(board_m2 > land_m2) or !(foil_m > 0)) return 0;
    const reach = @log(@sqrt(board_m2 / land_m2));
    if (!(reach > 0)) return 0;
    return 2.0 * std.math.pi * k_copper * foil_m / reach;
}

/// The θJB a junction is computed through (K/W): the declared figure, else the
/// `theta_jb_ja_fraction` share of θJA. Null when the part declares neither, in
/// which case no junction is invented for it at all.
fn junctionToBoard(part: PartInput) ?f64 {
    if (part.theta_jb) |jb| return jb;
    if (part.theta_ja) |ja| return theta_jb_ja_fraction * ja;
    return null;
}

/// The hottest cell of a solved field and its centre. Deterministic: the first
/// maximum in row-major order wins a tie.
fn hotspotOf(grid: FieldGrid) Hotspot {
    var spot = Hotspot{};
    var best: f32 = -std.math.floatMax(f32);
    for (grid.rise_c, 0..) |rise, i| {
        if (rise <= best) continue;
        best = rise;
        const col: f64 = @floatFromInt(i % grid.cols);
        const row: f64 = @floatFromInt(i / grid.cols);
        spot = .{
            .rise_c = rise,
            .x_mm = grid.origin_x_mm + (col + 0.5) * grid.cell_mm,
            .y_mm = grid.origin_y_mm + (row + 0.5) * grid.cell_mm,
        };
    }
    return spot;
}

/// Highest ambient the board tolerates under this scenario: the tightest of
/// every part's junction-derived ceiling and the caller's ratings cap.
fn maxAmbient(parts: []const PartField, cap: AmbientLimit) AmbientLimit {
    var limit = AmbientLimit{};
    for (parts) |p| {
        const c = p.max_ambient_c orelse continue;
        if (limit.c == null or c < limit.c.?) limit = .{ .c = c, .ref_des = p.ref_des };
    }
    if (cap.c) |c| {
        if (limit.c == null or c < limit.c.?) return cap;
    }
    return limit;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A 51 × 51 mm board at the origin. Big enough for a real gradient, small
/// enough that every solve in this file is quick — and an ODD cell count on each
/// axis, so the board has a true centre cell to test symmetry about.
const test_board = BoardRect{ .x_mm = 0, .y_mm = 0, .w_mm = 51, .h_mm = 51 };
/// Centre of `test_board`'s centre cell (mm), at its 1 mm cell size.
const board_centre_mm: f64 = 25.5;

/// A point-sized part box at `(x, y)`, so the part lands in exactly one cell.
fn pointBox(x: f64, y: f64) BoardRect {
    return .{ .x_mm = x, .y_mm = y, .w_mm = 0, .h_mm = 0 };
}

/// A square part box `size` mm on a side, centred on `(x, y)`.
fn mountAt(x: f64, y: f64) Mount {
    return .{ .box = pointBox(x, y) };
}

fn mountSquare(x: f64, y: f64, size: f64) Mount {
    return .{ .box = squareBox(x, y, size) };
}

fn squareBox(x: f64, y: f64, size: f64) BoardRect {
    return .{ .x_mm = x - size / 2, .y_mm = y - size / 2, .w_mm = size, .h_mm = size };
}

/// The screening sheet for `layers`, fully poured — the number this module
/// spread heat through before there was a coverage map.
fn fullSheet(layers: u8) f64 {
    return sheetConductance(defaultSheet(layers), 1.0);
}

/// Solve the ladder over `parts` on `test_board`, with the caller's ratings cap.
fn solveOver(
    arena: std.mem.Allocator,
    parts: []const PartInput,
    cap: AmbientLimit,
) ![]ScenarioResult {
    return solveScenarios(arena, .{ .board = test_board, .parts = parts, .ratings_cap = cap });
}

/// The largest rise anywhere in a solved field (°C).
fn peakRise(grid: FieldGrid) f32 {
    var peak: f32 = 0;
    for (grid.rise_c) |v| peak = @max(peak, v);
    return peak;
}

/// Every cell along the row through `(col, row)`, walking outward to the right
/// edge, is strictly cooler than the one before it.
fn expectMonotoneRay(grid: FieldGrid, col: usize, row: usize) !void {
    var c = col;
    while (c + 1 < grid.cols) : (c += 1) {
        try testing.expect(grid.at(c + 1, row) < grid.at(c, row));
    }
}

/// The field matches itself reflected about `(col, row)` — left against right
/// and left against up — out to `reach` cells, to f32 precision.
fn expectSymmetricAbout(grid: FieldGrid, col: usize, row: usize, reach: usize) !void {
    var d: usize = 1;
    while (d <= reach) : (d += 1) {
        const left = grid.at(col - d, row);
        try testing.expectApproxEqAbs(left, grid.at(col + d, row), 1e-4);
        try testing.expectApproxEqAbs(left, grid.at(col, row - d), 1e-4);
    }
}

// spec: placement/thermal_field - every watt injected leaves through the cells' faces and any heatsink, so the solved field balances the board's power to within a tenth of a percent
test "the solved field conserves the injected power" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]PartInput{
        .{ .ref_des = "U1", .watts = 1.5, .theta_jb = 10, .tj_max = 125, .mount = mountAt(20, 20) },
        .{ .ref_des = "U2", .watts = 0.4, .theta_jb = 20, .tj_max = 125, .mount = mountAt(40, 35) },
    };
    const grid = try makeGrid(arena, test_board);

    // Both a plain scenario and the heatsink one, whose sink is an extra path to
    // ambient on U1's cells and must appear in the same balance.
    for ([_]Scenario{ .natural, .heatsink }) |scenario| {
        var work = try buildSolver(arena, grid, .{ .board = test_board, .parts = &parts }, scenario, "U1");
        try testing.expect(solveWork(&work));

        const injected = work.total_power;
        var extracted: f64 = 0;
        for (work.to_ambient, work.rise) |g, rise| extracted += g * rise;
        try testing.expectApproxEqRel(injected, extracted, 1e-3);
        // Source shares the public f32 output storage until the solve finishes;
        // its represented total stays within that field's precision.
        try testing.expectApproxEqAbs(@as(f64, 1.9), injected, 1e-6);
    }
}

test "heatsink side selects the package path pad resistance and FEM face" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const part = PartInput{
        .ref_des = "U1",
        .watts = 2,
        .theta_jb = 5,
        .theta_jc = .{ .top = 15, .bottom = 1 },
        .tj_max = 125,
        .mount = mountSquare(25, 25, 6),
    };
    const parts = [_]PartInput{part};
    const base = Inputs{
        .board = test_board,
        .parts = &parts,
        .cooling = .{ .heatsink = .{ .ref_des = "U1", .pad = .{ .thickness_mm = 0.5, .conductivity_w_mk = 6 } } },
    };
    const natural = try solveScenario(arena, base, .natural);

    var top_inputs = base;
    top_inputs.cooling.heatsink.side = .package_top;
    const top = try solveScenario(arena, top_inputs, .heatsink);
    try testing.expectEqual(JunctionPath.package_top, top.parts[0].junction_path);
    try testing.expect(top.parts[0].tj_rise_c.? < natural.parts[0].tj_rise_c.?);
    const top_model = try discretize(arena, top_inputs, .heatsink);
    const hot_cell = cellsForBox(top_model.shape, part.mount.box.?);
    const hot_i = hot_cell.row_lo * top_model.shape.cols + hot_cell.col_lo;
    try testing.expect(top_model.top_face_h_w_m2k[hot_i] > top_model.bottom_face_h_w_m2k[hot_i]);

    var back_inputs = base;
    back_inputs.cooling.heatsink.side = .board_backside;
    const back = try solveScenario(arena, back_inputs, .heatsink);
    try testing.expectEqual(JunctionPath.package_bottom, back.parts[0].junction_path);
    try testing.expect(back.parts[0].tj_rise_c.? < natural.parts[0].tj_rise_c.?);
    const back_model = try discretize(arena, back_inputs, .heatsink);
    try testing.expect(back_model.bottom_face_h_w_m2k[hot_i] > back_model.top_face_h_w_m2k[hot_i]);

    var thick_pad = top_inputs;
    thick_pad.cooling.heatsink.pad.thickness_mm = 5;
    const insulated = try solveScenario(arena, thick_pad, .heatsink);
    try testing.expect(insulated.parts[0].tj_rise_c.? > top.parts[0].tj_rise_c.?);
}

// spec: placement/thermal_field - a drawn straight-fin heatsink derives its fin count and theta-SA from material and geometry, and applies that sink over the exact authored contact rectangle
test "drawn heatsink geometry drives resistance and exact contact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const geometry = HeatsinkGeometry{
        .width_mm = 20,
        .length_mm = 20,
        .base_mm = 2,
        .fin_height_mm = 10,
        .fin_thickness_mm = 1,
        .fin_gap_mm = 1.5,
        .fin_axis = .length,
    };
    try testing.expectEqual(@as(usize, 8), finCount(geometry));
    const aluminum = Heatsink{ .geometry = geometry, .material = .aluminum_6063 };
    var taller = aluminum;
    taller.geometry.fin_height_mm = 20;
    try testing.expect(sinkToAmbient(taller) < sinkToAmbient(aluminum));
    var steel = aluminum;
    steel.material = .steel;
    try testing.expect(sinkToAmbient(aluminum) < sinkToAmbient(steel));

    const parts = [_]PartInput{.{
        .ref_des = "U1",
        .watts = 2,
        .theta_jb = 5,
        .mount = mountSquare(25, 25, 6),
    }};
    var inputs = Inputs{
        .board = test_board,
        .parts = &parts,
        .cooling = .{ .heatsink = aluminum },
    };
    inputs.cooling.heatsink.ref_des = "U1";
    inputs.cooling.heatsink.side = .board_backside;
    inputs.cooling.heatsink.contact = .{ .x_mm = 4, .y_mm = 4, .w_mm = 6, .h_mm = 6 };
    const model = try discretize(arena, inputs, .heatsink);
    const contact_cells = cellsForBox(model.shape, inputs.cooling.heatsink.contact.?);
    const contact_i = contact_cells.row_lo * model.shape.cols + contact_cells.col_lo;
    try testing.expect(model.bottom_face_h_w_m2k[contact_i] > model.top_face_h_w_m2k[contact_i]);
}

// spec: placement/thermal_field - a single centered source is hottest at the source, decays monotonically along a ray to the edge, and is symmetric about the board centre
test "a centered source spreads symmetrically and decays outward" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]PartInput{.{ .ref_des = "U1", .watts = 2.0, .mount = mountAt(board_centre_mm, board_centre_mm) }};
    const results = try solveOver(arena, &parts, .{});
    const grid = results[0].grid;

    // The hotspot is the source cell, not a corner.
    const src_col = cellIndex(board_centre_mm, grid.origin_x_mm, grid.cell_mm, grid.cols);
    const src_row = cellIndex(board_centre_mm, grid.origin_y_mm, grid.cell_mm, grid.rows);
    try testing.expect(grid.at(src_col, src_row) > grid.at(0, 0));
    try testing.expect(grid.at(src_col, src_row) > grid.at(grid.cols - 1, grid.rows - 1));

    // Monotone decay along the row through the source, out to the edge, and a
    // field that mirrors itself about that source.
    try expectMonotoneRay(grid, src_col, src_row);
    try expectSymmetricAbout(grid, src_col, src_row, 5);
}

// spec: placement/thermal_field - the rise field is linear in the injected power, so two sources solved together equal the two solved apart added cell by cell
test "two sources superpose exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Superposition is in the POWER. The two bodies stand on the board in all
    // three solves — they block the faces they block either way — and only the
    // injected watts differ, so the three share one system matrix.
    const a_mount = mountAt(12, 12);
    const b_mount = mountAt(38, 30);
    const hot_a = [_]PartInput{
        .{ .ref_des = "U1", .watts = 1.0, .mount = a_mount },
        .{ .ref_des = "U2", .watts = 0.0, .mount = b_mount },
    };
    const hot_b = [_]PartInput{
        .{ .ref_des = "U1", .watts = 0.0, .mount = a_mount },
        .{ .ref_des = "U2", .watts = 3.0, .mount = b_mount },
    };
    const hot_both = [_]PartInput{
        .{ .ref_des = "U1", .watts = 1.0, .mount = a_mount },
        .{ .ref_des = "U2", .watts = 3.0, .mount = b_mount },
    };
    const only_a = try solveOver(arena, &hot_a, .{});
    const only_b = try solveOver(arena, &hot_b, .{});
    const both = try solveOver(arena, &hot_both, .{});

    const peak = peakRise(both[0].grid);
    try testing.expect(peak > 0);

    for (both[0].grid.rise_c, only_a[0].grid.rise_c, only_b[0].grid.rise_c) |sum, ra, rb| {
        try testing.expectApproxEqAbs(sum, ra + rb, peak * 1e-4);
    }
}

// spec: placement/thermal_field - more airflow strictly lowers the board's maximum rise, and the heatsink scenario strictly lowers its target part's junction rise
test "the cooling ladder is strictly monotone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]PartInput{
        .{ .ref_des = "U1", .watts = 2.0, .theta_jb = 8, .tj_max = 125, .mount = mountAt(20, 25) },
        .{ .ref_des = "U2", .watts = 0.2, .theta_jb = 8, .tj_max = 125, .mount = mountAt(40, 25) },
    };
    const r = try solveOver(arena, &parts, .{});

    try testing.expectEqual(Scenario.natural, r[0].scenario);
    try testing.expectEqual(Scenario.heatsink, r[3].scenario);
    try testing.expect(r[1].hotspot.rise_c < r[0].hotspot.rise_c);
    try testing.expect(r[2].hotspot.rise_c < r[1].hotspot.rise_c);

    // The sink lands on U1 — the least junction margin in still air — and its
    // junction rise drops while the board stays in still air everywhere else.
    try testing.expectEqualStrings("U1", heatsinkTarget(r[0].parts).?);
    try testing.expect(r[3].parts[0].tj_rise_c.? < r[0].parts[0].tj_rise_c.?);
    try testing.expect(r[3].hotspot.rise_c < r[0].hotspot.rise_c);
    // …and still hotter than 1 m/s of air over the whole board, which is the
    // point of offering both rungs rather than one.
    try testing.expect(r[0].hotspot.rise_c > r[3].hotspot.rise_c);
}

// spec: placement/thermal_field - an authored fan adds a spatial cooling rung whose selected face, projected position, standoff and installed-flow assumption drive the per-cell film coefficient
test "an authored fan cools only its distance-expanded footprint on one face" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]PartInput{.{
        .ref_des = "U1",
        .watts = 2,
        .theta_jb = 8,
        .tj_max = 125,
        .mount = .{ .box = .{ .x_mm = 4, .y_mm = 8, .w_mm = 4, .h_mm = 4 } },
    }};
    const fan = Fan{
        .model = "9A0812G4D011",
        .footprint = .{ .x_mm = 0, .y_mm = 0, .w_mm = 20, .h_mm = 20 },
        .face = .top,
        .distance_mm = 0,
        .free_air_flow_m3_s = 0.008,
        .max_static_pressure_pa = 80.4,
        .operating_flow_fraction = 0.5,
    };
    const inputs = Inputs{
        .board = .{ .x_mm = 0, .y_mm = 0, .w_mm = 40, .h_mm = 20 },
        .parts = &parts,
        .cooling = .{ .fan = fan },
    };
    const model = try discretize(arena, inputs, .fan);
    const left = model.shape.rows / 2 * model.shape.cols + model.shape.cols / 4;
    const right = model.shape.rows / 2 * model.shape.cols + 3 * model.shape.cols / 4;
    try testing.expect(model.top_face_h_w_m2k[left] > h_natural);
    try testing.expectEqual(h_natural, model.top_face_h_w_m2k[right]);
    try testing.expectEqual(h_natural, model.bottom_face_h_w_m2k[right]);

    const ladder = try solveScenarios(arena, inputs);
    try testing.expectEqual(@as(usize, 5), ladder.len);
    try testing.expectEqual(Scenario.fan, ladder[1].scenario);
    try testing.expectEqualStrings(fan.model, ladder[1].cooling.fan.model);
    try testing.expect(ladder[1].parts[0].tj_rise_c.? < ladder[0].parts[0].tj_rise_c.?);

    var farther = fan;
    farther.distance_mm = 50;
    const farther_h = fanFilmCoefficient(farther);
    try testing.expect(farther_h < fanFilmCoefficient(fan));
    var faster = fan;
    faster.operating_flow_fraction = 0.8;
    try testing.expect(fanFilmCoefficient(faster) > fanFilmCoefficient(fan));
}

// spec: placement/thermal_field - one scenario can be solved on its own and matches the ladder's answer for it, and the heatsink asked for alone still bolts its sink to the part the still-air solve names
test "a single scenario solves alone and keeps the ladder's answer" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]PartInput{
        .{ .ref_des = "U1", .watts = 2.0, .theta_jb = 8, .tj_max = 125, .mount = mountAt(20, 25) },
        .{ .ref_des = "U2", .watts = 0.2, .theta_jb = 8, .tj_max = 125, .mount = mountAt(40, 25) },
    };
    const inputs = Inputs{ .board = test_board, .parts = &parts };
    const ladder = try solveScenarios(arena, inputs);

    // Every rung solved alone reproduces the ladder's packed-SIMD field to well
    // below the f32 field's useful precision — including the heatsink, whose
    // target the single-scenario path has to rediscover from still air itself.
    for ([_]Scenario{ .natural, .airflow_1ms, .airflow_2ms, .heatsink }, 0..) |scenario, i| {
        const one = try solveScenario(arena, inputs, scenario);
        try testing.expectEqual(scenario, one.scenario);
        for (ladder[i].grid.rise_c, one.grid.rise_c) |packed_rise, scalar_rise| {
            try testing.expectApproxEqAbs(packed_rise, scalar_rise, 1e-4);
        }
        try testing.expectApproxEqAbs(ladder[i].hotspot.rise_c, one.hotspot.rise_c, 1e-4);
    }

    // …and that target really is U1, so the heatsink rung solved alone is not
    // silently the still-air field with a sink bolted to nobody.
    try testing.expectEqualStrings("U1", heatsinkTarget(ladder[0].parts).?);
    const sunk = try solveScenario(arena, inputs, .heatsink);
    try testing.expect(sunk.parts[0].tj_rise_c.? < ladder[0].parts[0].tj_rise_c.?);
}

// spec: placement/thermal_field - a part with no pose is reported as skipped instead of placed, a part hanging off the board docks onto the nearest cell, and neither panics
test "an unplaced part is skipped and an off-board part docks to the edge" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]PartInput{
        .{ .ref_des = "U_NOPOSE", .watts = 5.0, .theta_jb = 10, .tj_max = 125 },
        .{ .ref_des = "U_OFF", .watts = 1.0, .mount = mountAt(-40, -40) },
    };
    const r = try solveOver(arena, &parts, .{});

    try testing.expectEqual(@as(usize, 1), r[0].skipped.len);
    try testing.expectEqualStrings("U_NOPOSE", r[0].skipped[0]);
    try testing.expectEqual(@as(usize, 1), r[0].parts.len);
    try testing.expectEqualStrings("U_OFF", r[0].parts[0].ref_des);

    // The off-board part's watts landed on the corner cell nearest it, so that
    // corner is the hotspot rather than the heat being dropped on the floor.
    try testing.expect(r[0].grid.at(0, 0) > 0);
    try testing.expectApproxEqAbs(@as(f64, r[0].grid.at(0, 0)), r[0].hotspot.rise_c, 1e-9);
}

// spec: placement/thermal_field - a board with nothing to dissipate solves to an all-zero field, converged and free of NaN
test "a board dissipating nothing solves to zero" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A placed part burning nothing, and no parts at all: both are quiet boards.
    const idle = [_]PartInput{.{ .ref_des = "U1", .watts = 0, .theta_jb = 10, .mount = mountAt(25, 25) }};
    for ([_][]const PartInput{ &idle, &.{} }) |parts| {
        for (try solveOver(arena, parts, .{})) |result| {
            try testing.expect(result.converged);
            try testing.expectEqual(@as(f64, 0), result.hotspot.rise_c);
            for (result.grid.rise_c) |rise| try testing.expectEqual(@as(f32, 0), rise);
            try testing.expect(result.max_ambient.c == null);
        }
    }
}

// spec: placement/thermal_field - a junction is computed through the declared theta-jb, else through half the theta-ja with the row flagged estimated, and through nothing at all when neither is declared
test "the theta-jb fallback is used and flagged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]PartInput{
        .{ .ref_des = "DECL", .watts = 1.0, .theta_jb = 10, .theta_ja = 80, .mount = mountAt(10, 10) },
        .{ .ref_des = "FALLBACK", .watts = 1.0, .theta_ja = 80, .mount = mountAt(40, 40) },
        .{ .ref_des = "BARE", .watts = 1.0, .mount = mountAt(25, 25) },
    };
    const rows = (try solveOver(arena, &parts, .{}))[0].parts;

    // A declared θJB is used verbatim — in series with the board transfer the
    // row reports — and the row says nothing was estimated, even though this
    // part also carries a θJA the fallback would have used.
    try testing.expect(!rows[0].jb_estimated);
    const declared = 10.0 + rows[0].theta_transfer_c_per_w;
    try testing.expectApproxEqAbs(rows[0].board_rise_c + declared, rows[0].tj_rise_c.?, 1e-9);

    // With no θJB, half the θJA stands in — and the row is flagged for it.
    try testing.expect(rows[1].jb_estimated);
    const fallback = 40.0 + rows[1].theta_transfer_c_per_w;
    try testing.expectApproxEqAbs(rows[1].board_rise_c + fallback, rows[1].tj_rise_c.?, 1e-9);

    // Neither declared: no junction is invented, so no ambient ceiling either.
    try testing.expect(rows[2].tj_rise_c == null);
    try testing.expect(rows[2].max_ambient_c == null);
    try testing.expect(!rows[2].jb_estimated);
}

// spec: placement/thermal_field - a scenario's maximum ambient is the tightest junction ceiling and the caller's ratings cap, each naming the part that sets it
test "the ratings cap tightens the scenario's ambient ceiling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parts = [_]PartInput{.{
        .ref_des = "U1",
        .watts = 1.0,
        .theta_jb = 10,
        .tj_max = 125,
        .mount = mountAt(25, 25),
    }};

    // Uncapped, the junction sets the ceiling and names its own part.
    const loose = try solveOver(arena, &parts, .{});
    const junction_ceiling = loose[0].max_ambient.c.?;
    try testing.expectEqualStrings("U1", loose[0].max_ambient.ref_des);
    try testing.expectApproxEqAbs(125.0 - loose[0].parts[0].tj_rise_c.?, junction_ceiling, 1e-9);

    // A tighter ratings cap wins and carries its own part's name through.
    const cap_c = junction_ceiling - 10;
    const capped = try solveOver(arena, &parts, .{ .c = cap_c, .ref_des = "OSC1" });
    try testing.expectApproxEqAbs(cap_c, capped[0].max_ambient.c.?, 1e-9);
    try testing.expectEqualStrings("OSC1", capped[0].max_ambient.ref_des);

    // A cap looser than the junction changes nothing.
    const slack = try solveOver(arena, &parts, .{ .c = junction_ceiling + 10, .ref_des = "OSC1" });
    try testing.expectEqualStrings("U1", slack[0].max_ambient.ref_des);
}

// spec: placement/thermal_field - the grid cuts the outline into square cells of one to four millimetres with at most sixty-four along the longer side
test "the grid sizes its cells from the board's longer side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // 128 mm long ⇒ exactly 64 cells of 2 mm; the short side keeps the same cell.
    const wide = try makeGrid(arena, .{ .x_mm = 5, .y_mm = -3, .w_mm = 128, .h_mm = 32 });
    try testing.expectEqual(@as(f64, 2), wide.cell_mm);
    try testing.expectEqual(@as(usize, 64), wide.cols);
    try testing.expectEqual(@as(usize, 16), wide.rows);
    try testing.expectEqual(@as(f64, 5), wide.origin_x_mm);
    try testing.expectEqual(@as(f64, -3), wide.origin_y_mm);

    // A small board bottoms out at the 1 mm floor rather than resolving detail
    // the uniform-sheet model cannot carry; a big one tops out at 4 mm.
    try testing.expectEqual(min_cell_mm, cellSize(20));
    try testing.expectEqual(max_cell_mm, cellSize(1000));
    // A degenerate or non-finite dimension yields the floor and a single cell,
    // not a division blow-up.
    try testing.expectEqual(min_cell_mm, cellSize(0));
    try testing.expectEqual(min_cell_mm, cellSize(std.math.nan(f64)));
    const degenerate = try makeGrid(arena, .{ .x_mm = 0, .y_mm = 0, .w_mm = 0, .h_mm = -5 });
    try testing.expectEqual(@as(usize, 1), degenerate.cols);
    try testing.expectEqual(@as(usize, 1), degenerate.rows);
}

// spec: placement/thermal_field - the spreading sheet counts the two outer faces plus one layer per inner plane, so a plane-less stack spreads strictly less than the implicit four-layer board
test "spreader layers count the outer faces plus the planes" {
    try testing.expectEqual(default_spreader_layers, spreaderLayers(2));
    try testing.expectEqual(@as(u8, 2), spreaderLayers(0));
    try testing.expectEqual(@as(u8, 6), spreaderLayers(4));
    // An absurd plane count saturates instead of wrapping the u8.
    try testing.expectEqual(@as(u8, 255), spreaderLayers(1_000_000));

    // Copper dominates the sheet, and the laminate alone is three orders down.
    try testing.expect(fullSheet(4) > fullSheet(2));
    try testing.expect(fullSheet(0) > 0);
    try testing.expectApproxEqRel(@as(f64, 0.0546 + 0.00048), fullSheet(4), 1e-9);

    // Fewer spreading layers ⇒ a hotter board under the same watt.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parts = [_]PartInput{.{ .ref_des = "U1", .watts = 1.0, .mount = mountAt(25, 25) }};
    const thin = try solveScenarios(arena, .{ .board = test_board, .spreader_layers = 2, .parts = &parts });
    const thick = try solveScenarios(arena, .{ .board = test_board, .spreader_layers = 6, .parts = &parts });
    try testing.expect(thin[0].hotspot.rise_c > thick[0].hotspot.rise_c);
}

// spec: placement/thermal_field - the conducting sheet is built from the stackup's own finished thickness and per-foil copper weights, and a caller declaring none keeps the 1.6 mm one-ounce screening convention
test "a declared stackup's own copper and thickness drive the sheet" {
    // The convention is exactly what the layer count used to buy: two outer
    // ounces, one per inner plane, on 1.6 mm of laminate.
    const convention = defaultSheet(4);
    try testing.expectApproxEqRel(@as(f64, 2 * copper_thickness_m), convention.outer_cu_m, 1e-12);
    try testing.expectApproxEqRel(@as(f64, 2 * copper_thickness_m), convention.inner_cu_m, 1e-12);
    try testing.expectApproxEqRel(board_thickness_m, convention.laminate_m, 1e-12);
    // A two-layer board is all outer copper and no planes at all.
    try testing.expectApproxEqRel(@as(f64, 2 * copper_thickness_m), defaultSheet(2).outer_cu_m, 1e-12);
    try testing.expectEqual(@as(f64, 0), defaultSheet(2).inner_cu_m);

    // Heavier foil on a thicker board spreads more than the convention does,
    // and a thin two-ounce-free stack spreads less — the sheet now moves with
    // the stackup rather than with a layer count alone.
    const heavy = Sheet{ .outer_cu_m = 70.0e-6, .inner_cu_m = 70.0e-6, .laminate_m = 2.4e-3 };
    const thin = Sheet{ .outer_cu_m = 18.0e-6, .inner_cu_m = 0, .laminate_m = 0.8e-3 };
    try testing.expect(sheetConductance(heavy, 1.0) > fullSheet(4));
    try testing.expect(sheetConductance(thin, 1.0) < fullSheet(4));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parts = [_]PartInput{.{ .ref_des = "U1", .watts = 1.0, .mount = mountAt(25, 25) }};

    // A caller declaring no sheet solves the very same board the layer count
    // always did, so nothing about an unstackuped design's answer moves.
    const implied = try solveScenarios(arena, .{ .board = test_board, .parts = &parts });
    const spelled = try solveScenarios(arena, .{
        .board = test_board,
        .sheet = defaultSheet(default_spreader_layers),
        .parts = &parts,
    });
    try testing.expectApproxEqRel(implied[0].hotspot.rise_c, spelled[0].hotspot.rise_c, 1e-9);

    // And the heavy stack really does run cooler under the same watt.
    const stout = try solveScenarios(arena, .{ .board = test_board, .sheet = heavy, .parts = &parts });
    try testing.expect(stout[0].hotspot.rise_c < implied[0].hotspot.rise_c);
}

// spec: placement/thermal_field - outer copper is derated cell by cell by the coverage map the caller sampled, so an unpoured cell spreads through the inner planes alone and a fully covered board reproduces the uniform sheet exactly
test "coverage derates the outer copper cell by cell" {
    const sheet = defaultSheet(4);
    // Fully poured is the uniform sheet; bare leaves the inner planes and the
    // laminate, which is strictly less and strictly more than nothing.
    try testing.expectApproxEqRel(fullSheet(4), sheetConductance(sheet, 1.0), 1e-12);
    const bare = sheetConductance(sheet, 0.0);
    try testing.expect(bare < fullSheet(4));
    try testing.expectApproxEqRel(sheet.inner_cu_m * k_copper + sheet.laminate_m * k_fr4, bare, 1e-12);
    // Out-of-range and non-finite fractions clamp rather than inventing copper.
    try testing.expectApproxEqRel(fullSheet(4), sheetConductance(sheet, 4.0), 1e-12);
    try testing.expectApproxEqRel(bare, sheetConductance(sheet, -1.0), 1e-12);
    try testing.expectApproxEqRel(fullSheet(4), sheetConductance(sheet, std.math.nan(f64)), 1e-12);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const shape = gridShape(test_board);
    const cells = shape.cols * shape.rows;
    const poured = try arena.alloc(f32, cells);
    @memset(poured, 1.0);
    const stripped = try arena.alloc(f32, cells);
    @memset(stripped, 0.0);

    const parts = [_]PartInput{.{ .ref_des = "U1", .watts = 1.0, .mount = mountAt(25, 25) }};
    const uniform = try solveScenarios(arena, .{ .board = test_board, .parts = &parts });
    const full = try solveScenarios(arena, .{
        .board = test_board,
        .parts = &parts,
        .coverage = .{ .cols = shape.cols, .rows = shape.rows, .outer_frac = poured },
    });
    const none = try solveScenarios(arena, .{
        .board = test_board,
        .parts = &parts,
        .coverage = .{ .cols = shape.cols, .rows = shape.rows, .outer_frac = stripped },
    });
    // A fully covered map is the uniform board to the last digit, and stripping
    // the outer pours makes the same watt run hotter.
    try testing.expectApproxEqRel(uniform[0].hotspot.rise_c, full[0].hotspot.rise_c, 1e-9);
    try testing.expect(none[0].hotspot.rise_c > uniform[0].hotspot.rise_c);

    // A map of the wrong shape is dropped, not stretched onto the wrong cells.
    const mismatched = try solveScenarios(arena, .{
        .board = test_board,
        .parts = &parts,
        .coverage = .{ .cols = shape.cols + 1, .rows = shape.rows, .outer_frac = stripped },
    });
    try testing.expectApproxEqRel(uniform[0].hotspot.rise_c, mismatched[0].hotspot.rise_c, 1e-9);
}

// spec: placement/thermal_field - the two board faces convect separately and a face a part body sits on sheds a fraction of the bare-laminate coefficient, so a cell with parts on both sides sheds least and a bare cell most
test "a part body blocks convection off the face it sits on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // One 6 mm part burning a watt in the middle of the board, and a passive
    // body of the same size either beside it, on top of it, or under it.
    const heater = PartInput{ .ref_des = "U1", .watts = 1.0, .mount = mountSquare(25, 25, 6) };
    const alone = [_]PartInput{heater};
    const beside = [_]PartInput{ heater, .{ .ref_des = "U2", .mount = mountSquare(45, 45, 6) } };
    const stacked = [_]PartInput{ heater, .{ .ref_des = "U2", .mount = mountSquare(25, 25, 6) } };
    const under = [_]PartInput{
        heater,
        .{ .ref_des = "U2", .mount = .{ .side = .bottom, .box = squareBox(25, 25, 6) } },
    };

    const a = (try solveOver(arena, &alone, .{}))[0].hotspot.rise_c;
    const b = (try solveOver(arena, &beside, .{}))[0].hotspot.rise_c;
    const s = (try solveOver(arena, &stacked, .{}))[0].hotspot.rise_c;
    const u = (try solveOver(arena, &under, .{}))[0].hotspot.rise_c;

    // A second body on the SAME side covers a face the heater already covers,
    // so it changes nothing — a face is blocked, not blocked twice.
    try testing.expectApproxEqRel(a, s, 1e-9);
    // Any body costs the board some convecting area, so the field lifts.
    try testing.expect(b > a);
    // But a body on the FAR side of the heater blocks the one face the hot
    // cells still had, which costs far more than the same area of cool board.
    try testing.expect(u > b);
}

// spec: placement/thermal_field - a junction sits above the board through theta-jb plus a board-transfer path, which thermal vias under the part shorten and the part's own outer-foil spreading bounds so it never runs away on a small land
test "thermal vias shorten the board-transfer path under a part" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const land = squareBox(25, 25, 5);
    const bare = [_]PartInput{.{ .ref_des = "U1", .watts = 1.0, .theta_jb = 5, .tj_max = 125, .mount = .{ .box = land } }};
    const stitched = [_]PartInput{.{
        .ref_des = "U1",
        .watts = 1.0,
        .theta_jb = 5,
        .tj_max = 125,
        .mount = .{ .box = land, .thermal_vias = 9 },
    }};

    const dry = (try solveOver(arena, &bare, .{}))[0].parts[0];
    const wet = (try solveOver(arena, &stitched, .{}))[0].parts[0];

    // An unstitched land already transfers something — the dielectric under it
    // and its own foil — but a via array is the bigger path by a good margin.
    try testing.expect(dry.theta_transfer_c_per_w > 0);
    try testing.expect(wet.theta_transfer_c_per_w < dry.theta_transfer_c_per_w);
    // The vias buy junction margin without touching the copper, which is the
    // whole point: same board rise, cooler junction, higher ambient ceiling.
    try testing.expectApproxEqAbs(dry.board_rise_c, wet.board_rise_c, 1e-9);
    try testing.expect(wet.tj_rise_c.? < dry.tj_rise_c.?);
    try testing.expect(wet.max_ambient_c.? > dry.max_ambient_c.?);
    // The junction is θJB and the transfer in series over the injected watt.
    try testing.expectApproxEqAbs(
        wet.board_rise_c + 5.0 + wet.theta_transfer_c_per_w,
        wet.tj_rise_c.?,
        1e-9,
    );

    // A tiny land transfers worse than a big one, but the foil it spreads
    // through keeps that bounded rather than letting it run away.
    const tiny = [_]PartInput{.{ .ref_des = "U1", .watts = 1.0, .theta_jb = 5, .mount = mountAt(25, 25) }};
    const point = (try solveOver(arena, &tiny, .{}))[0].parts[0];
    try testing.expect(point.theta_transfer_c_per_w > dry.theta_transfer_c_per_w);
    try testing.expect(point.theta_transfer_c_per_w < 200);
}

// spec: placement/thermal_field - the grid a board resolves to is answerable without solving it, so a caller can rasterize a coverage map onto exactly the cells the solve will use
test "the grid shape is answerable without solving the board" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const board = BoardRect{ .x_mm = 7, .y_mm = -2, .w_mm = 96, .h_mm = 40 };
    const shape = gridShape(board);
    const grid = try makeGrid(arena, board);
    try testing.expectEqual(grid.cols, shape.cols);
    try testing.expectEqual(grid.rows, shape.rows);
    try testing.expectEqual(grid.cell_mm, shape.cell_mm);
    try testing.expectEqual(grid.origin_x_mm, shape.origin_x_mm);
    try testing.expectEqual(grid.origin_y_mm, shape.origin_y_mm);
}

// spec: placement/thermal_field - the packed four-scenario solver uses less per-cell ladder storage than four independent sheet ambient power and rise arrays
test "packed scenario storage is smaller than four scalar solver states" {
    const old_per_scenario = 4 * @sizeOf(f64) + @sizeOf(f32);
    const old_ladder_per_cell = 4 * old_per_scenario;
    const packed_ladder_per_cell = 4 * @sizeOf(f32) +
        @sizeOf(Stencil) +
        @sizeOf(ScenarioF64) +
        2 * @sizeOf(ScenarioF32) +
        @sizeOf(ScenarioF64);
    try testing.expectEqual(@as(usize, 144), old_ladder_per_cell);
    try testing.expectEqual(@as(usize, 120), packed_ladder_per_cell);
    try testing.expect(packed_ladder_per_cell < old_ladder_per_cell);
}

// spec: placement/thermal_field - the exported FEM coefficients conserve component power and reproduce the built-in sheet and two-face still-air conductances cell for cell
test "the FEM discretization conserves the built in cell coefficients" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const board = BoardRect{ .x_mm = 0, .y_mm = 0, .w_mm = 1, .h_mm = 1 };
    const parts = [_]PartInput{.{
        .ref_des = "U1",
        .watts = 1,
        .mount = .{ .box = board, .side = .top },
    }};
    const inputs = Inputs{ .board = board, .parts = &parts };
    const model = try discretize(arena, inputs, .natural);
    try testing.expectEqual(@as(usize, 1), model.conductivity_w_mk.len);
    const cell_m = model.shape.cell_mm * 1.0e-3;
    const volume = cell_m * cell_m * model.thickness_m;
    try testing.expectApproxEqRel(@as(f64, 1), model.heat_source_w_m3[0] * volume, 1e-12);
    try testing.expectApproxEqRel(
        sheetConductance(defaultSheet(default_spreader_layers), 1),
        model.conductivity_w_mk[0] * model.thickness_m,
        1e-12,
    );
    // Top face covered at 40%, bottom face bare; the FEM keeps the two
    // coefficients on their physical boundaries instead of averaging them.
    try testing.expectApproxEqRel(@as(f64, 4), model.top_face_h_w_m2k[0], 1e-12);
    try testing.expectApproxEqRel(@as(f64, 10), model.bottom_face_h_w_m2k[0], 1e-12);
}
