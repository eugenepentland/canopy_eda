//! Force-directed component placement.
//!
//! The model is a small physics relaxation over a design's parts:
//!   • a decoupling cap (a passive on a single-hub net that also has a ground
//!     pad) is pulled to close its hot loop: its power and ground pads are
//!     drawn toward the *nearest* hub power / ground pad, measured and forced
//!     edge-to-edge (so the cap hugs the IC's large exposed pad at its edge,
//!     and current returns to the closest ground — see `Loop`),
//!   • any other passive on a single-hub net hugs that hub's pad centroid on
//!     the net (VIN across pins 1+2, VOUT across 10+11+12, both qualify),
//!   • other connections get a weak centre pull; ground nets are planes,
//!   • a gentle compaction force pulls parts toward the cluster centroid so
//!     the bounding box stays tight,
//!   • courtyards repel so parts don't overlap, then a legalization pass
//!     removes any residual overlap.
//!
//! Around that relaxation are three things a plain force model can't do:
//!   1. **Rotation** — each passive's orientation (0/90/180/270°) is chosen by
//!      coordinate descent over the score, interleaved with re-relaxing, so a
//!      cap flips to face its IC power/ground pins (shortening the hot loop).
//!      Hubs stay at 0° (for a single-hub module, rotating the hub is just a
//!      global frame turn that changes nothing).
//!   2. **Multi-start** — which passive shares which IC edge is a packing
//!      choice the relaxation can't resolve, so small boards are solved from
//!      many ring seeds and the lowest-scoring arrangement is kept.
//!   3. **Polish** — a greedy per-part grid search slides each passive to the
//!      tightest non-overlapping spot against its pin (the relaxation leaves
//!      resistors a millimetre loose).
//!
//! After a final grid-aware legalization, no two courtyards overlap. A closing
//! compaction then docks every passive still held off by the snap-safety gap
//! against its nearest neighbour, so each courtyard abuts at least one other
//! (hubs stay put as anchors) — the layout is provably as tight as it packs.
//! Large whole-board layouts skip steps 1–3 (they blob together regardless) and
//! take a single grid-seeded relax. It is deterministic — seeds derive from the
//! start index, not an RNG — so a design always yields the same layout.
//! Coordinates are millimetres, y-down (KiCad convention).

const std = @import("std");
const env = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const netlist_mod = @import("../export_kicad_netlist.zig");
const geometry = @import("geometry.zig");
const pin_roles = @import("pin_roles.zig");
const module_policy = @import("module_policy.zig");
const router = @import("router.zig");
const drc = @import("drc.zig");
const parser = @import("../sexpr/parser.zig");
const infra_fs = @import("../infra/fs.zig");

const DesignBlock = env.DesignBlock;
pub const FlatNet = export_kicad.FlatNet;

// ── Tunables ─────────────────────────────────────────────────────────────
const K_DECOUPLE: f64 = 0.95; // power/decoupling cap hug + ground-return (highest priority)
const K_PROX: f64 = 0.6; // single-hub signal passive hug (feedback divider, etc.)
const K_SIG: f64 = 0.12; // generic wirelength pull
const ITERS: usize = 600; // relaxation steps (cooling schedule length)
const RELAX_CONVERGE_MM: f64 = 0.01; // stop relaxing once the largest per-step move is this small
const LEGALIZE_ITERS: usize = 2000; // overlap-removal-only steps
const MAX_DISP_MM: f64 = 0.6; // per-step displacement clamp
const HUB_MASS: f64 = 4.0; // hubs move less → act as anchors
const PASSIVE_MASS: f64 = 1.0;
const SEED_GAP_MM: f64 = 1.5; // extra gap between seed grid cells
const LOOP_W: f64 = 12.0; // weight on the loop *inductance* term (nH; see
// `loopInductanceNh`). On a solid GND plane the loop is dominated by the power-leg
// (L1) trace — the return images directly under it (`loopGroundSpan` carries no
// lateral term) — so minimising the connection inductance minimises both the EMI
// loop area and the PDN bandwidth limit. 6.0 (which kept the term near the old
// length-based 3.0) was re-tuned by the 2026-06 coordinate sweep judged on the
// FIXED full-route metric (real trace + vias + DRC + unrouted at the prior
// weights): 12.0 won −1.5% alone and, combined with the swept align/boost,
// −3.7% geomean across the 10-design suite (tpsm84338c −11%, pma3-14ln −6.1%,
// tpsm84338 −3.1%; worst regression nestedarray +2.1%).
const K_COMPACT: f64 = 0.10; // pull toward the cluster centroid (keeps HPWL tight)
const GROUP_FORCE_PER_W: f64 = 0.05; // relaxation cohesion-force gain per unit `group_w`
// (g_group_force = group_w·this); default group_w=2 ⇒ 0.10, ≈ K_COMPACT.
const ZONE_FORCE_PER_W: f64 = 0.04; // relaxation zoning-force gain per unit `group_zone_w`
// Board-size threshold: at/below this a from-scratch seed rings the parts
// (`seedRing`), above it grid-seeds; also gates the denser collide-shrink band.
const MULTISTART_MAX_PARTS: usize = 32;
// Upper bound for the once-per-solve finishing passes (rotation refine via
// `optimizeRotations`, the priority-cap tuck, the routed polish) — cheap,
// run once on the arrangement, so they cover boards well above the seed-ring band.
const POLISH_MAX_PARTS: usize = 64;
// Routed-aware finishing polish (small boards only): a final local search that
// scores each candidate (position × rotation) with the *real* maze-routed loop
// length instead of the fixed-pad surrogate, so a cap settles at the rotation/
// offset that shortens the actual trace — a surrogate-driven tuck optimises
// a straight-gap proxy and can pick a different rotation/side than the router.
const ROUTED_POLISH_SWEEPS: usize = 2;
const ROUTED_POLISH_CELLS: i64 = 6; // ±0.6 mm window (6·GRID_MM) — local tuck/flip, not a re-place
// Routed polish routes once per candidate cell, so its cost grows with
// caps × window × loops. Keep it small so a mid-size module can't make an
// on-demand regenerate take tens of seconds. Small power modules — the case this
// helps most — sit comfortably under it.
const ROUTED_POLISH_MAX_PARTS: usize = 16;
const CAP_W_MAX: f64 = 3.0; // max value-priority boost for the smallest cap on a rail
// Extra loop-tightness multiplier for a switching regulator's INPUT decoupling
// loop (Cin→high-side switch→GND). That loop carries the high-dI/dt current and
// dominates radiated EMI (E ∝ f²·area·I; Richtek AN045, TI SNVA638A), so its caps
// are pulled tighter than generic / output decoupling. Applied only when an
// inductor marks the design a switcher. 2.0 → 3.0 per the 2026-06 sweep: on the
// fixed full-route metric, 3.0 improved tpsm84338c −13.5% with every other suite
// design byte-identical — a strictly-dominant move.
const INPUT_LOOP_BOOST: f64 = 3.0;
// Weight on the placement-regularizer term (`tidinessPenalty`). The row/column
// alignment reward keeps large boards compact (aligned parts route shorter —
// load-bearing on 200+ part designs) while staying a gentle nudge on small ones.
const ALIGN_CLAMP_MM: f64 = 1.5; // only finish near-alignments within this offset (no long pulls)
// `Params.w_align = W_ALIGN_AUTO` (the shipping default) resolves through
// `effAlignW` to `W_ALIGN_TIDINESS`; an explicit query/sidecar value overrides.
// `tidinessPenalty` is normalized by pair count (× 2/(n−1), i.e. n × the mean
// pairwise misalignment) so it grows ~linearly with part count like HPWL does —
// the raw O(n²) sum made the effective alignment-vs-wirelength balance a
// function of board size (weights tuned on a 10-part module meant something
// 25× stronger per part at 300 parts). 2.75 would mirror the long-shipped 0.5
// at the n≈12 module scale; the 2026-06 sweep (fixed full-route yardstick)
// picked 1.5 instead — geomean −0.8%, rf-switch-8way −14.5%, and two fewer
// unroutable nets across the suite, vs ≤+1% drift elsewhere. Alignment earns
// less than assumed once real copper is the judge.
const W_ALIGN_TIDINESS: f64 = 1.5;
const W_ALIGN_AUTO: f64 = -1.0; // sentinel: w_align unset → resolve to W_ALIGN_TIDINESS (effAlignW)
// Weight on the routing-congestion penalty (`congestionPenalty`). HPWL/RSMT alone
// does not predict routability — local congestion must be traded off against it
// (Spindler & Johannes RUDY; UCLA mPL). The penalty is ~0 until a region's
// estimated wire density exceeds the signal-layer budget, so it only steers parts
// apart out of genuine hotspots. PROVISIONAL — the research notes the optimal
// congestion weight is IC-derived and must be swept on real PCBs.
const W_CONGEST: f64 = 2.0;
// ── Full-route cost weights (`fullRouteCost`) ─────────────────────────────────
// `fullRouteCost` routes the whole board (the same maze router + DRC the layout
// page runs) and scores it on what actually matters: real copper length, via
// count, DRC violations, and unrouted nets. Costs are expressed in mm-equivalents
// so they blend with trace length.
const FULLROUTE_VIA_MM: f64 = 2.0; // one via ≈ this much extra trace (drill + return-path discontinuity)
const FULLROUTE_DRC_MM: f64 = 25.0; // one clearance violation outweighs a couple of vias, not the board
// An unroutable net costs far more than any detour that routes: it is a
// hand-fix on the real board. 50 proved too cheap — on rf-switch-8way it
// traded 4 extra unrouted nets for ~300 mm less copper, which no designer
// would take. 150 ≈ three full board crossings per failed net.
const FULLROUTE_UNROUTED_MM: f64 = 150.0;
const GRID_COURTYARDS = true; // round courtyard half-extents to GRID_MM so edges land on-grid
const COMPACT_EPS: f64 = 1e-4; // courtyard-gap tolerance for the "touching" test

// ── Phase-A constraint lowering weights (see docs/constraints_dsl.md) ─────────
// These weight the *search-only* guidance terms a `(constraints …)` form lowers
// into `objectiveCost`. They are deliberately kept OUT of the reported/compared
// objective (`scoreLayout`, `scorePoses`, `routedObjectiveCost`): constraints
// steer where SA looks, but the result is judged on the unmodified physical
// objective — so a hand layout and a constrained solve are scored identically
// and the constraints can't "game" the comparison. All PROVISIONAL (the doc's
// weight-tuning is an offline sweep, not the LLM's job).
const PROX_W: f64 = 1.5; // proximity pull: cost = PROX_W·priority·(edge gap, mm)
const KEEPOUT_W: f64 = 4.0; // keep-out hinge: cost = KEEPOUT_W·max(0, min−gap)
/// Courtyard gap (mm) a synthesized aggressor-avoidance keep-out (Phase 2b)
/// demands between a feedback passive and a switching/clock/RF passive — a touch
/// above the `feedback-near-aggressor` lint threshold so a satisfied solve also
/// clears the lint with margin.
const AGGRESSOR_KEEPOUT_MM: f64 = 2.5;
const DEPRIORITIZE_SCALE: f64 = 0.25; // scale a deprioritized part's net wirelength weight
const ZONE_GAP_MM: f64 = 2.0; // group zoning: cluster centroid sits this far beyond the hub edge on its connecting side
/// Soft-constraint priority → numeric multiplier (low/med/high).
fn constraintWeight(p: env.ConstraintPriority) f64 {
    return switch (p) {
        .low => 1.0,
        .med => 2.0,
        .high => 3.0,
    };
}

/// Runtime-tunable weights (the consts above are the defaults). Passed to
/// `solve` so the UI can adjust placement without a rebuild. Only the steering
/// weights are exposed; the structural tunables (iters, starts) stay fixed.
pub const Params = struct {
    loop_w: f64 = LOOP_W,
    /// Alignment/compactness weight. Defaults to the `W_ALIGN_AUTO` sentinel,
    /// which resolves to `W_ALIGN_TIDINESS` via `effAlignW`. Set ≥0 to override
    /// explicitly (query/sidecar values do).
    w_align: f64 = W_ALIGN_AUTO,
    w_congest: f64 = W_CONGEST,
    /// Extra loop-inductance weight multiplier on a switching regulator's INPUT
    /// decoupling loop (see `INPUT_LOOP_BOOST`). Exposed so the bench sweep can
    /// retune the provisional magnitude against routed outcomes.
    input_loop_boost: f64 = INPUT_LOOP_BOOST,
    cap_w_max: f64 = CAP_W_MAX,
    grid_courtyards: bool = GRID_COURTYARDS,
    /// Extra clearance (mm) added to every part's courtyard half-extents (on top
    /// of its F.CrtYd / pad bbox). The optimizer's density floor: two parts can
    /// never sit closer than the sum of their margins. Defaults to the geometry
    /// module's shipping value; exposed so a denser regime can be swept (a hand
    /// layout packed at courtyard-touching density needs a smaller margin to be
    /// reproducible — see the tpsm84338 constraint experiment).
    bbox_margin: f64 = geometry.BBOX_MARGIN_MM,
    /// How much (mm, total) two parts' *drawn* courtyards may overlap in the
    /// collision / legalization test. Default 0: courtyards may **touch** (their
    /// edges land on the shared `GRID_MM` grid line — grid-rounded extents +
    /// `compactToContact` dock to exact contact) but never overlap. That is the
    /// densest packing with no courtyard intersection, which is what a board
    /// review expects (KiCad flags overlapping courtyards).
    ///
    /// A value > 0 shrinks the collision box below the drawn courtyard, letting
    /// adjacent clearance bands intersect by that much. The real footprint extent
    /// still never collides (`ceilToGrid(extent+margin) − margin ≥ extent`, and
    /// the per-side shrink is capped at `bbox_margin`) — but the *drawn*
    /// courtyards then visibly overlap, so this is an experimental knob, off by
    /// default. Only affects fresh auto-placement; saved/hand layouts are applied
    /// verbatim.
    courtyard_overlap: f64 = 0,
    /// Functional-group cohesion weight: cost = `group_w·(bbox_w + bbox_h)` per
    /// `(group …)` (constraint-DSL *and* the design's own functional groups), so
    /// a declared cluster (e.g. an output filter's caps) packs into one tight
    /// block instead of scattering around the hub. Competes with `loop_w`.
    group_w: f64 = 2.0,
    /// Group-zoning weight: pulls each group's cluster to the side of its hub it
    /// connects to (input/output/sensitive land on distinct sides — a power-flow
    /// layout). 0 disables zoning (cohesion only).
    group_zone_w: f64 = 1.0,
    /// Extra clearance (mm) the collision/legalization leaves between courtyards,
    /// on top of touching — routing/copper room for the GND pour, thermal vias,
    /// and the SW pour on a power board. 0 = pack to touching (the default for
    /// dense jellybean boards). Set ~0.3–0.5 for switching-regulator layouts.
    route_gap: f64 = 0,
    /// Bank-loop relief (0–1): when several caps in one `(group …)` share one
    /// power rail they form a *bank* — collectively they only need the cluster
    /// close to the rail, not each cap independently hugging its own access point
    /// on the IC's (often tall, central) supply pad. The per-cap loop term pulls
    /// each cap to the nearest point on that pad, which on a tall pad scatters the
    /// bank along the pad's full height (top vs bottom of the IC). This knob
    /// removes that fraction of the loop pull for each cap in a ≥2-member same-rail
    /// bank (a search-only delta in `constraintCost`, never the reported score), so
    /// the group's cohesion can pack the bank into one tight block. 0 = off.
    group_loop_relief: f64 = 0,
    /// Constructive "zone-then-pack" floorplan (off by default): instead of the
    /// force-directed relaxation (which makes organic clusters), place the dominant
    /// IC at the origin and lay each functional `(group …)` as a crisp row/column
    /// docked to the IC side it wires to — `VIN-caps │ IC │ L │ VOUT-caps`. Only
    /// engages for a "one dominant IC + groups" shape; falls back to the force
    /// pipeline otherwise, so it can never degrade a non-switcher board.
    zone_pack: bool = false,
    /// Rough hierarchical seed — the default top-level engine. Solve each
    /// first-level sub-block internally, freeze it as a rigid block, and arrange
    /// the *blocks* by connectivity on a coarse grid. Every module stays intact
    /// and grid-aligned — a legible starting point a human drags to finish,
    /// deliberately not metric-optimal. Falls back to the flat pad-anchored ring,
    /// then a fast force relax, when there is too little structure to cluster. See
    /// `runRough`. Nested per-module solves explicitly set this `false`.
    rough: bool = true,
    /// Take the bare single seeded force relax (`runForce`: one `runStart` +
    /// legalize) instead of the rough engine. Set for the rough seed's per-module
    /// nested solves and the degenerate passives-only fallback — a quick force
    /// layout is enough for a starting point, and N full solves (one per module)
    /// would be far too slow for an interactive button.
    fast: bool = false,
};

/// The effective alignment weight: an explicit `w_align` (≥0) wins; the
/// `W_ALIGN_AUTO` sentinel resolves to the shipped tidiness default. Every
/// objective/score path multiplies the compactness term by this (never by
/// `params.w_align` raw), so the UI and the search always agree.
pub fn effAlignW(params: Params) f64 {
    if (params.w_align >= 0) return params.w_align;
    return W_ALIGN_TIDINESS;
}

/// Which phase of the solve a progress frame came from — drives the label the
/// live-preview overlay shows while watching the optimizer converge.
///   • `explore` — multi-start / surrogate search (rough arrangements as the
///     placer hunts the search space).
///   • `refine`  — finishing work (polished / routed-reranked arrangements).
pub const ProgressPass = enum {
    explore,
    refine,
    pub fn label(self: ProgressPass) []const u8 {
        return switch (self) {
            .explore => "explore",
            .refine => "refine",
        };
    }
};

/// Optional sink the solve calls each time its internal *best* arrangement
/// improves, so a caller (the live-regen background thread) can stream the
/// best-so-far poses to a watching browser. `onBest` receives the live `parts`
/// array — the callback must copy what it needs, the positions mutate after it
/// returns. `score` is the (lower-is-better) cost of this arrangement.
pub const ProgressSink = struct {
    ctx: *anyopaque,
    onBest: *const fn (ctx: *anyopaque, parts: []const Part, score: f64, pass: ProgressPass) void,
};

/// Thread-local so a background solve streams to its own watcher without a
/// synchronous page solve (which never sets it) paying anything but one null
/// check, and two concurrent regens (different designs/threads) stay isolated.
threadlocal var g_progress: ?ProgressSink = null;

/// Install (or clear, with `null`) the progress sink for the *current thread*.
/// The background regen thread sets this before `solve` and clears it after.
pub fn setProgressSink(sink: ?ProgressSink) void {
    g_progress = sink;
}

/// Report a new best arrangement to the thread's progress sink, if one is set.
inline fn emitBest(parts: []const Part, score: f64, pass: ProgressPass) void {
    if (g_progress) |s| s.onBest(s.ctx, parts, score, pass);
}

/// Placement grid: final positions snap to this (mm). The interactive page
/// drags on the same grid so manual edits and auto-placement stay aligned, and
/// courtyard half-extents round up to it (`ceilToGrid`). The cell-count search
/// windows below (`RELOCATE_MAX_CELLS`, `COARSE_STRIDE`, `ROUTED_POLISH_CELLS`,
/// `TIGHTEN_CELLS`) are sized in *cells*, so they're paired to this value to
/// keep their physical millimetre spans constant when the grid changes.
pub const GRID_MM: f64 = 0.1;

/// Whether a part anchors the layout (ICs/connectors) or hangs off a hub
/// pin (passives). Drives spring strength, mass, and rendering colour.
pub const PartKind = enum { hub, passive };

/// One placed part: courtyard half-extents, pads (origin-relative), a solved
/// centre position (mm), and a rotation (0/90/180/270°, CCW, matching the
/// page's `wpt()`). `hw`/`hh` are the *unrotated* half-extents — use `effHw`/
/// `effHh` for the rotation-aware footprint. `value` is the part value string
/// (e.g. "100nF") used for value-ordered decoupling.
pub const Part = struct {
    ref_des: []const u8,
    kind: PartKind,
    hw: f64,
    hh: f64,
    /// Courtyard-box centre offset from the footprint origin (footprint-local
    /// mm; (0,0) for origin-centred boxes). The pose (`x`,`y`) is always the
    /// footprint ORIGIN — collision/bounds add the rotated offset.
    ccx: f64 = 0,
    ccy: f64 = 0,
    pads: []const geometry.Pad,
    fallback: bool,
    value: []const u8 = "",
    silk_lines: []const geometry.SilkLine = &.{},
    silk_circles: []const geometry.SilkCircle = &.{},
    x: f64 = 0,
    y: f64 = 0,
    rot: f64 = 0,
    /// Rotation provenance: `.authored` (a spec `(rot …)`) and `.series` (a
    /// series part's pad-pairing — see `SeriesPair`) rotations are *decided*,
    /// not searched — the HPWL-driven rotation searches are blind to
    /// through-body detours, so they must not revisit them. `.series` may be
    /// re-derived (it's deterministic); `.authored` always wins.
    rot_pin: RotPin = .none,
    /// Collision keepout box (footprint-local). Defaults to the sentinel
    /// (`hw<0`), meaning "use the symmetric courtyard" (`effHw`/`effHh` about
    /// the part centre) — so a part with no escape stub behaves exactly as
    /// before. Escape stubs grow this box outward (see `applyKeepout`).
    keep: Keepout = .{},
    /// Copper side the part sits on. Manual state (viewer F-flip), carried
    /// through poses — the solver never changes it. Bottom parts mirror in
    /// `worldPt` and only collide with other bottom parts.
    side: Side = .top,
    /// Editor lock: the viewer refuses to drag/rotate/flip a locked part.
    /// Carried through poses; the auto-solver does not consult it (a full
    /// re-solve replaces the whole arrangement deliberately).
    locked: bool = false,
};

/// Footprint-local collision keepout: centre offset (`ox`,`oy`) + half-extents
/// (`hw`,`hh`). `hw<0` is the sentinel for "no override → use the courtyard".
const Keepout = struct { ox: f64 = 0, oy: f64 = 0, hw: f64 = -1, hh: f64 = -1 };

/// See `Part.rot_pin`.
const RotPin = enum { none, series, authored };

/// A breakout stub reserved in front of an *unaccounted* pad — one on a net
/// that touches only this part (a single-pin signal like RFIN/LNAOUT that
/// leaves the board), so the placer keeps its escape corridor clear instead of
/// dropping a neighbour over it. Endpoints are footprint-local (pad centre →
/// 2 mm out), so they rotate with the part. Drawn on the layout as a hint.
pub const Stub = struct {
    part: usize,
    ax: f64,
    ay: f64,
    bx: f64,
    by: f64,
    /// Flattened-net index this breakout carries, so the router can emit it as
    /// real net-tagged copper (and the DRC checks its clearance).
    net: i32,
};

/// How far an escape stub reaches out of its pad (mm) — the breakout room the
/// placer reserves so the signal can be routed off this part.
const ESCAPE_STUB_MM: f64 = 2.0;

/// A ratsnest line's origin: a strong pin-proximity hug, a ground-return
/// (the cap→IC ground leg that closes the decoupling loop), or a weak
/// generic signal pull. Drives the line's colour and weight in the preview.
pub const RatKind = enum { proximity, ground, signal };

/// A simple point in millimetres.
const Pt = struct { x: f64, y: f64 };

/// A pad in footprint-local coordinates: centre (mm) + full size (mm).
pub const PadRect = struct { x: f64, y: f64, w: f64, h: f64 };

/// A world-space axis-aligned rectangle (mm). Right-angle rotations keep pads
/// axis-aligned, so this captures a rotated pad exactly.
const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Layout-quality metrics, recomputed after the relaxation settles.
/// `hpwl_mm` is the total signal-net wirelength estimate (HPWL for ≤3-pin nets,
/// rectilinear MST for larger — see `wireScore`; lower = shorter routing);
/// `loop_mm` is the summed power+ground airwire length of the `loop_caps`
/// decoupling caps (lower = tighter hot loops). The field keeps its historical
/// `hpwl_mm` name though it now carries the RSMT estimate.
pub const Score = struct {
    hpwl_mm: f64,
    loop_mm: f64,
    loop_caps: usize,
};

/// Decoupling-loop totals over all loops, in two units: `*_mm` is the loop
/// *length* (displayed) and `*_nh` the loop *inductance* (the scored metric —
/// see `loopInductanceNh`). `raw_*` is the plain sum, `weighted_*` scales each
/// loop by its value/priority weight. Produced by both the analytic surrogate
/// (`surrogateLoops`) and the real router (`routedLoops`) — a named type so the
/// two are interchangeable (anonymous structs would be distinct types).
const LoopSums = struct { raw_mm: f64, weighted_mm: f64, raw_nh: f64, weighted_nh: f64 };

/// Full decomposition of the objective the optimizer actually minimizes — the
/// on-screen score bar only shows `hpwl` + the *raw* loop length, so this
/// surfaces the terms it hides (value-weighted loop inductance, alignment) for
/// the JSON export, so a layout that looks "worse" on the visible metric but wins
/// on the true objective can be told apart. `objective` is the weighted sum:
/// `hpwl + loop_w·loop_nh_weighted + w_align·alignment` (the loop term is the
/// value-weighted connection *inductance*, nH — not the length).
pub const Breakdown = struct {
    hpwl: f64, // signal wirelength estimate (mm), RSMT (HPWL ≤3-pin, RMST larger); objective weight 1
    loop_raw: f64, // summed unweighted hot-loop length (mm) = Score.loop_mm (display only)
    loop_weighted: f64, // value-priority-weighted loop-length sum (mm, display only)
    loop_nh: f64 = 0, // summed unweighted hot-loop connection inductance (nH)
    loop_nh_weighted: f64 = 0, // value-weighted loop inductance (nH) — the scored loop term
    alignment: f64, // tidiness penalty (mm): pairwise row/column misalignment (field name kept for wire-compat)
    footprint: f64 = 0, // courtyard bounding-box area (mm²) — always reported as the compactness yardstick
    congestion: f64 = 0, // RUDY routing-congestion overflow penalty
    objective: f64, // the weighted total the multi-start/polish minimize
};

/// A connection to draw as a ratsnest airwire: part indices plus each end's
/// footprint-local pad offset (mm), so the client can recompute endpoints as
/// parts are dragged. `a`/`b` index into `Placement.parts`.
pub const Link = struct {
    a: usize,
    b: usize,
    ax: f64,
    ay: f64,
    bx: f64,
    by: f64,
    kind: RatKind,
    /// Flattened name of the net this airwire belongs to (empty when unknown).
    /// Carried through so the viewer can colour airwires by net class without
    /// re-deriving connectivity. Slices the flattened netlist, not owned.
    net: []const u8 = "",
};

/// The optimizer's output: placed parts, ratsnest, and the overall bounding
/// box (mm) for framing the view. `instances` is index-aligned with `parts`
/// (same flatten order); `nets` is the flattened, tie-merged netlist — both
/// surfaced so callers can render a component/net sidebar without
/// re-flattening.
pub const Placement = struct {
    parts: []Part,
    links: []Link,
    loops: []const Loop,
    stubs: []const Stub,
    instances: []const export_kicad.FlatInstance,
    nets: []const FlatNet,
    /// Per-part `(placement-order …)` rank (index-aligned with `parts`/
    /// `instances`): 0 = unranked, higher = earlier in the declared list. The
    /// router routes higher-priority nets first so they claim the short path.
    /// Empty when no order was declared (then the router keeps net order).
    priority: []const u32 = &.{},
    score: Score,
    /// Full objective decomposition (defaults to zero so test fixtures that
    /// build a `Placement` directly needn't supply it).
    breakdown: Breakdown = .{ .hpwl = 0, .loop_raw = 0, .loop_weighted = 0, .alignment = 0, .objective = 0 },
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,
    /// True when the optimizer actually ran (cache miss / stale / regen);
    /// false when positions came straight from the cache. The caller persists
    /// the cache only when this is true.
    generated: bool,
    /// The physical outline rectangle from a `(board (size W H) …)` form,
    /// world coordinates (same frame as `parts`). Null when the design has no
    /// effective board form — renderers draw no outline.
    board_rect: ?BoardRect = null,
    /// Board-level routing rules resolved from the design's `(stackup …)` and
    /// `(net-class …)` forms — see `BoardRules`.
    rules: BoardRules = .{},
};

/// Routing rules a design declares for its board, carried on the `Placement`
/// so the router needs no separate lookup.
pub const BoardRules = struct {
    /// Net names that have a dedicated copper plane, from `(stackup …)`.
    /// **Null = no stackup declared** — the router keeps its legacy implicit
    /// model (ground nets get plane vias). An **empty slice** is a declared
    /// stackup with NO planes (e.g. `(stackup 2)`): every net, ground
    /// included, is routed as real copper.
    plane_nets: ?[]const []const u8 = null,
    /// Per-net routing geometry from `(net-class …)`, index-aligned with
    /// `Placement.nets`. Empty when no classes are declared; a zero field
    /// keeps the router's default for that quantity.
    net: []const NetRule = &.{},
};

/// One net's routing geometry override (mm) resolved from `(net-class …)`.
/// Zero = keep the router default for that quantity.
pub const NetRule = struct { width: f64 = 0, clearance: f64 = 0, via_dia: f64 = 0, via_drill: f64 = 0 };

/// A `(board …)` outline rectangle in world mm (top-left + size).
pub const BoardRect = struct { minx: f64, miny: f64, w: f64, h: f64 };

/// Which copper side a part sits on. `top` is the default. A `bottom` part is
/// drawn/placed mirrored about its own vertical axis (footprint-local x
/// negates *before* rotation) — the view stays "looking down at the top", the
/// KiCad convention — and it only collides with other `bottom` parts.
pub const Side = enum {
    top,
    bottom,

    /// Parse the persisted JSON spelling ("bottom"); anything else = top.
    pub fn fromStr(s: []const u8) Side {
        return if (std.mem.eql(u8, s, "bottom")) .bottom else .top;
    }
};

/// A cached part pose (ref-des + centre + rotation + board side + lock flag) —
/// the persisted form of an auto-generated layout, so the optimizer needn't
/// re-run on every page load. `side`/`locked` default so legacy poses parse
/// unchanged.
pub const RefPose = struct { ref: []const u8, x: f64, y: f64, rot: f64, side: Side = .top, locked: bool = false };

const Spring = struct {
    a: usize,
    b: usize,
    ax: f64,
    ay: f64,
    bx: f64,
    by: f64,
    k: f64,
    kind: RatKind,
    /// Net this spring's airwire belongs to (empty when unknown) — copied onto
    /// the emitted `Link` so the viewer can colour ratsnest by net class.
    net: []const u8 = "",
    /// Footprint-local pad offsets the rendered `Link` draws *from* (mm). The
    /// force uses `ax/ay/bx/by`; a weak inter-hub `.signal` spring keeps those at
    /// the part centre (0,0) so the tuned force model is unchanged, but the drawn
    /// airwire should still join the real pads — so it carries them here. Default
    /// 0; `weakCluster` is the only place force-centre ≠ draw-pad, and the
    /// link-build reads these only for `.signal` springs. Proximity/loop springs
    /// already hold pads in `ax/ay`, so their draw offsets equal the force ones.
    dax: f64 = 0,
    day: f64 = 0,
    dbx: f64 = 0,
    dby: f64 = 0,
};

/// One decoupling cap's hot loop. The loop length is measured **edge-to-edge
/// to the nearest hub pad** (not to a centroid): the power leg is the gap from
/// the cap's power pad to the nearest of the hub's power pads, the ground leg
/// likewise to the nearest hub ground pad. This reflects the real return loop
/// — current takes the shortest path to the closest ground, and the IC's large
/// exposed pad is reached at its edge, not its centre. All pads footprint-local.
pub const Loop = struct {
    cap: usize,
    hub: usize,
    cap_pwr: PadRect,
    cap_gnd: PadRect,
    /// All of the hub's supply pads on this rail — kept as a slice only so
    /// `classify` can group caps that share a rail (by pointer identity).
    hub_pwr: []const PadRect,
    /// The *one* hub pad the power leg targets (a fixed pad — no per-eval argmin,
    /// so the cost is continuous in the cap's position). Chosen in `hugToHub`:
    /// the explicitly-pinned pin (`(near <pin> …)`) if any, else the lowest-
    /// numbered true-supply pad. Footprint-local.
    hub_pwr_pin: PadRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    hub_gnd: []const PadRect,
    /// The *one* hub ground pad the ground return targets (the GND pad nearest the
    /// power pin — a fixed pad, no argmin flip). The return runs cap GND pad →
    /// via → plane → via → this pad; its lateral leg is measured to it. Set in
    /// `hugToHub`. Footprint-local.
    hub_gnd_pin: PadRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Flattened-net index of the power rail (into the `nets` slice scoring uses),
    /// so the score path can route a real trace on it. -1 ⇒ unset (test fixtures).
    pwr_net: i32 = -1,
    /// Value-priority weight (≥1): boosts the smaller of several caps sharing
    /// a rail toward the pin, and is raised further by a declared
    /// `(placement-order …)` rank. 1 for a lone, unranked cap. Set in `classify`.
    weight: f64 = 1,
    /// The hub pin the design EXPLICITLY pinned this cap to via `(near <pin> …)`,
    /// or "" when the target pin was auto-chosen (lowest-numbered supply). Lets a
    /// read surface (the PCB sidebar) show the authored decoupling target, not a
    /// solver default. Set in `hugToHub`.
    explicit_pin: []const u8 = "",
    /// `(decouples rail)` opt-out: this cap deliberately serves the whole rail,
    /// so the per-pin-decoupling lint must not demand a pad binding for it. Set
    /// in `hugToHub` from the cap's source instance.
    rail_optout: bool = false,
};

/// `buildSprings` output: the force list plus the decoupling loops to score.
const Built = struct {
    springs: []Spring,
    loops: []Loop,
    series: []SeriesPair = &.{},
};

/// A 2-pad *series* element between two pins of the same hub — the buck-boost
/// inductor across LX1/LX2, a feedback resistor between VOUT and FB. For these
/// parts the airwire metric is nearly blind to rotation: turning the part moves
/// one pad closer to its pin exactly as far as it moves the other away, and the
/// straight airwire passes through the part's own body, so HPWL can't see that
/// the "wrong" rotation routes one leg the long way around. The rotation is
/// therefore *decided geometrically* (`seriesPairRot`: align the part's pad
/// axis with its matched hub pads' axis) and pinned (`Part.rot_pinned`) so the
/// HPWL-driven polish can't flip it. Pads/targets are footprint-local; `a`/`b`
/// are the part's two legs in net order.
const SeriesPair = struct {
    part: usize,
    hub: usize,
    a: SeriesLeg,
    b: SeriesLeg,
};
/// One leg of a series pair: the part pad and the hub-side target it must
/// reach (the centroid of the hub's pads on that leg's net), footprint-local.
const SeriesLeg = struct { part_pad: PadRect, hub_pad: PadRect };

/// A `(proximity …)` pull lowered to geometry: keep `part`'s pad `part_pad`
/// within `max_mm` of `hub`'s pad `hub_pad` (both footprint-local). A *hinge*
/// penalty `w·max(0, gap − max_mm)` (see `constraintCost`): zero once the part is
/// inside the radius, so it only acts to drag a badly-placed part in, never to
/// fight HPWL/loop over a part that is already close. `max_mm == 0` ⇒ a plain
/// linear pull `w·gap` (no declared radius).
const ProxTerm = struct { part: usize, hub: usize, part_pad: PadRect, hub_pad: PadRect, w: f64, max_mm: f64 };

/// A `(keep-out …)` lowered to a part-vs-part minimum courtyard gap.
const KeepTerm = struct { a: usize, b: usize, min_mm: f64 };

/// A `(group …)` lowered to (a) a cohesion penalty on the group's bounding box,
/// so members pack into one tight block instead of scattering, and (b) optional
/// zoning: `hub` (the IC the group orbits, -1 = none) plus `dirx`/`diry`, the
/// hub-local unit direction toward the hub pads the group connects to — the
/// cluster is pulled to that side of the IC, so input/output/sensitive groups
/// land on distinct sides (a power-flow layout) instead of piling on the hub.
const GroupTerm = struct {
    members: []const usize,
    hub: i32 = -1,
    dirx: f64 = 0,
    diry: f64 = 0,
};

/// The resolved + lowered Phase-A constraints for the current solve. Every slice
/// defaults empty so a read on a path that didn't go through `prepare` is a
/// harmless no-op. Slices live in the solve's arena (valid for that solve only).
/// Consumed by `constraintCost` — a search-only delta added to `objectiveCost`,
/// never to the reported/compared objective (see `constraintCost`).
const Lowered = struct {
    prox: []const ProxTerm = &.{},
    keepouts: []const KeepTerm = &.{},
    /// Per-net wirelength weight (index-aligned with `nets`); 1.0 = default. >1
    /// from `(net-length … (priority …))`, <1 from `(deprioritize …)`.
    net_weight: []const f64 = &.{},
    /// Per-net "this is a switcher input rail" flag (index-aligned), from
    /// `(power-rail … (role input))` — fires the input-loop boost even when the
    /// inductor is integrated (so no discrete L reveals the switcher).
    input_rail: []const bool = &.{},
    /// Declared `(group …)` clusters (constraint-DSL + the design's functional
    /// groups) — each penalizes its bounding box (cohesion) and is zoned to a
    /// side of its hub.
    groups: []const GroupTerm = &.{},
    /// True when any term is live — the hot-path `constraintCost` fast-exits when
    /// false (a design with no constraints and no functional groups).
    active: bool = false,
};

/// Thread-local lowered constraints for the current solve — set by `prepare`,
/// read by `constraintCost`. Threadlocal (like `g_progress`) so the many
/// `objectiveCost` call sites needn't each thread a new parameter, and two
/// concurrent solves on different threads stay isolated. Default-empty so it is
/// inert until a design with a `(constraints …)` form sets it.
threadlocal var g_lowered: Lowered = .{};

/// Cohesion-force gain for the relaxation: each `(group …)` member is pulled
/// toward its group's centroid by `g_group_force·(centroid − pos)`, the
/// position-space twin of the scalar `group_w` cohesion in `constraintCost`.
/// Without it cohesion only *selects* among arrangements the spring relaxation
/// produces — it can't *create* a tight block (the relaxation never proposes
/// one). Set in `prepare` from `params.group_w`; 0 ⇒ no cohesion force.
threadlocal var g_group_force: f64 = 0;

/// Per-loop multiplier on the decoupling-loop *force* (index-aligned with the
/// solve's `built.loops`), the force-space twin of `group_loop_relief` in
/// `constraintCost`: 1.0 for a lone cap, `1 − group_loop_relief` for a cap in a
/// ≥2-member same-rail bank, so the relaxation stops yanking every bank cap onto
/// the rail pad and lets cohesion pack them. Set in `prepare`; empty ⇒ all 1.0.
threadlocal var g_loop_force_scale: []const f64 = &.{};

/// Zoning-force gain for the relaxation (position-space twin of the scalar
/// `group_zone_w`): each `(group …)` is pulled toward its hub's *connecting side*
/// (VIN caps left, VOUT caps right, …) so the board reads as a power-flow layout
/// instead of an isotropic blob. Set in `prepare` from `params.group_zone_w`;
/// 0 ⇒ no zoning force (cohesion only).
threadlocal var g_zone_force: f64 = 0;

/// Per-side amount (mm) the collision/legalization keepout boxes are shrunk so
/// adjacent courtyards may overlap their clearance margins (see
/// `Params.courtyard_overlap`). Set in `prepare`, read by `keepHw`/`keepHh`/
/// `keepBoxOf`. Threadlocal (like `g_lowered`) so the hot collision helpers need
/// no extra parameter and concurrent solves stay isolated. 0 ⇒ strict no-overlap.
threadlocal var g_collide_shrink: f64 = 0;

/// Extra clearance (mm) the collision/legalization grows each keepout box by, so
/// parts leave routing/copper room between courtyards instead of packing to
/// touching (see `Params.route_gap`). Set in `prepare`, read by the collision
/// helpers. 0 ⇒ touch (the default).
threadlocal var g_route_gap: f64 = 0;

/// Per-flattened-net declared current (A), index-aligned with the `nets` slice
/// `prepare` returns — resolved from `(current …)` on the design's own ports and
/// its sub-blocks' output ports (via their net-ties) plus the summed `(i-typ …)`
/// consumer pins per rail. Read by `congestPitch` to widen a power net's RUDY
/// corridor to the IPC-2221 trace width its current needs. Empty ⇒ all nets use
/// the signal pitch. Set in `prepare`; threadlocal like `g_lowered` so the hot
/// objective path needn't thread another parameter through every call site.
threadlocal var g_net_current: []const f64 = &.{};

/// Solve re-entrancy depth on this thread. `runRough`'s nested per-module solves
/// deliberately clobber the arena-backed threadlocals (and manage them via
/// `SolveState`), so only the *outermost* solve resets them on exit — a nested
/// reset would change what the parent reads after `runRough`. 0 outside any solve.
threadlocal var g_solve_depth: usize = 0;

/// Reset the request-arena-backed threadlocal slices to empty. Called on exit of
/// the *outermost* solve only, so they never dangle into a freed arena after the
/// solve returns (latent hardening — a later caller touching
/// `constraintCost`/`congestPitch`/`accumulateLoops` outside a solve then reads an
/// empty slice, a harmless no-op, instead of freed memory). Nested solves skip
/// it, preserving today's exact `runRough` behaviour byte-for-byte.
fn resetArenaGlobals() void {
    if (g_solve_depth != 0) return;
    g_lowered = .{};
    g_loop_force_scale = &.{};
    g_net_current = &.{};
}

/// Staging diagnostics from the most recent solve, so the PCB-layout JSON / PNG
/// can flag parts that didn't make the board. `unplaced` = parts still in a band
/// below the board (the `(board …)` edge-dock path stages anything it can't
/// place); `auto_filled` = parts `autofillUnlisted` pulled back out of the band;
/// `unresolved` = names that match no part. Reset in `prepare`. Threadlocal like
/// `g_lowered` so concurrent solves stay isolated.
pub const PlacementDiag = struct {
    /// Refs still in the staging band (auto-fill found no collision-free improving
    /// pose, or was gated off).
    unplaced: []const []const u8 = &.{},
    /// Refs `autofillUnlisted` placed automatically beside their pads.
    auto_filled: []const []const u8 = &.{},
    /// Names that resolve to NO part / sub-block — surfaced by the lint layer.
    unresolved: []const []const u8 = &.{},
};
threadlocal var g_placement_diag: PlacementDiag = .{};

/// The most recent solve's staging diagnostics (see `PlacementDiag`). Read by the
/// PCB-layout JSON / PNG right after `solve` on the same thread. Empty when the
/// last solve left nothing staged.
pub fn placementDiag() PlacementDiag {
    return g_placement_diag;
}

/// How `solve` treats an applied `cached` layout.
pub const SeedMode = enum {
    /// Apply `cached` verbatim when it covers every part (no optimization, fast);
    /// otherwise place from scratch. The normal load/regenerate path.
    place,
    /// Seed from `cached` and run only the local routed tuck (`routedPolish`) on
    /// it — improve an existing (e.g. hand) layout in place without re-placing.
    refine,
};

/// The smooth-surrogate objective (the value `scorePoses` reports and the viewer
/// shows) for the CURRENT poses in `parts`, computed in place — no `prepare()`
/// rebuild, so it is cheap to call mid-pipeline as a candidate comparator.
fn surrogateObjective(parts: []const Part, idx_of: *std.StringHashMap(usize), nets: []const FlatNet, loops: []const Loop, params: Params) f64 {
    const score = scoreLayout(parts, idx_of, nets, loops);
    const lsum = surrogateLoops(parts, loops);
    return breakdownWith(parts, idx_of, nets, params, score, lsum).objective;
}

/// The from-scratch placement pipeline, factored out so `solve` can run it twice
/// (the strict vs courtyard-overlap retry). Rough is the default top-level engine:
/// the hierarchical module-clustered seed, else the flat pad-anchored ring, else a
/// fast force relax for a degenerate passives-only board. The opt-in `zone_pack`
/// floorplan and the bare `runForce` relax serve the nested per-module solves.
/// Mutates `parts` in place; honours the thread's `g_collide_shrink`.
fn runPlacement(
    arena: std.mem.Allocator,
    parts: []Part,
    prep: *Prepared,
    nets: []const FlatNet,
    built: Built,
    params: Params,
) std.mem.Allocator.Error!void {
    // Rough hierarchical seed (explicit `?rough=1` / "Rough" button): cluster each
    // module into a rigid block and arrange the blocks by connectivity. Honours each
    // module's own internal spec (via the nested solve) but ignores the design-level
    // arrangement — the point is a predictable, legible module-clustered start.
    if (params.rough) {
        if (try runRough(arena, parts, prep, nets, params)) return;
        // Flat module/design: ring the anchor IC with each part on the side of the
        // pad it connects to (GND ignored; cap→VDD pad, R→signal pad), hugging the
        // edge. This is the pad-anchored hand-layout seed.
        if (try packPadAnchored(arena, parts, prep, nets, true)) return;
        // No hub to anchor on (e.g. a passives-only board): fall back to a declumped
        // fast force relax — kill the alignment term and force courtyard spacing so the
        // compaction can't collapse everything into one block. A quick relax is all the
        // degenerate passives-only board needs.
        var fp = params;
        fp.fast = true;
        fp.w_align = 0;
        if (fp.route_gap < ROUGH_DECLUMP_GAP_MM) fp.route_gap = ROUGH_DECLUMP_GAP_MM;
        // The compaction pass reads the courtyard spacing from the `g_route_gap`
        // global (set once in `prepare` from the original params), not from `fp` —
        // so bump the global here, restoring it after, or the spread won't apply.
        const saved_gap = g_route_gap;
        g_route_gap = @max(g_route_gap, ROUGH_DECLUMP_GAP_MM);
        defer g_route_gap = saved_gap;
        try runForce(arena, parts, prep, nets, built, fp);
        return;
    }
    // Constructive zone-then-pack floorplan (opt-in): crisp VIN│IC│L│VOUT rows the
    // force model can't make. Returns false (falls through to the force pipeline)
    // for any shape it doesn't handle, so it never degrades a non-switcher board.
    if (params.zone_pack and try packZoned(arena, parts, prep, nets, built, params)) {
        tightenPriorityLoops(arena, parts, built.loops, nets, prep.priority);
        return;
    }
    try runForce(arena, parts, prep, nets, built, params);
}

/// The bare seeded force relax: ONE seeded relax + legalize. This is the only
/// force layout the roughing engine needs — its per-module nested solves run it
/// (a spec, when present, already drove placement; this is the spec-less block),
/// and the no-hub passives-only fallback in `runPlacement` uses it. The former
/// standalone force *quality search* (multi-start / routed-rerank / best-of-rough)
/// has been removed — roughing is now the only top-level engine.
fn runForce(
    arena: std.mem.Allocator,
    parts: []Part,
    prep: *Prepared,
    nets: []const FlatNet,
    built: Built,
    params: Params,
) std.mem.Allocator.Error!void {
    _ = arena;
    runStart(parts, &prep.idx_of, nets, built, 0, 0, params);
    legalizeFinal(parts);
}

// ── Zone-then-pack constructive floorplan ────────────────────────────────────
// The force model makes organic clusters; a power layout wants crisp rows
// (`VIN-caps │ IC │ L │ VOUT-caps`). `packZoned` places the dominant IC at the
// origin and lays each functional `(group …)` — plus loose passives and a
// secondary hub (the inductor) — as a row/column docked to the IC side it wires
// to, then finishes with overlap-removal + grid-snap only (NEVER `relax`, which
// would dissolve the rows). Opt-in via `Params.zone_pack`; returns false for any
// shape it doesn't handle so the caller falls back to the force pipeline.

/// Which IC edge a packed block docks against.
pub const Edge = enum { left, right, top, bottom };

/// A packed cluster: its ordered members, their chosen rotations, their block-
/// local centre offsets, the block half-extents, and the IC edge it docks to.
const PackBlock = struct {
    members: []const usize,
    rots: []const f64,
    lx: []const f64,
    ly: []const f64,
    half_w: f64,
    half_h: f64,
    edge: Edge,
    /// Cross-coordinate (world) of this block's rail pin on the IC — the block is
    /// docked centred on it so a decoupling bank sits opposite its supply pad
    /// (short loop), not collectively centred on the IC. `target_set` false ⇒ fall
    /// back to the IC centre.
    target: f64 = 0,
    target_set: bool = false,
    /// Anchoring weight when co-edge blocks contend for cross space: a decoupling
    /// bank (heavy) holds its target; a lone resistor (light) yields and slides out.
    mass: f64 = 1,
};

const ZoneTopo = struct { ic: usize };

/// The "one dominant IC + groups" shape gate. Accept only when there is a single
/// hub whose courtyard dwarfs the next (≥2×), every group orbits it (or has no
/// hub), and the board is within the finisher band. Null ⇒ use the force path.
fn analyzeTopology(parts: []const Part, lowered: Lowered) ?ZoneTopo {
    if (!lowered.active or lowered.groups.len == 0) return null;
    if (parts.len < 2 or parts.len > POLISH_MAX_PARTS) return null;
    // The IC = largest-area hub.
    var ic: ?usize = null;
    var a1: f64 = -1;
    for (parts, 0..) |p, i| {
        if (p.kind != .hub) continue;
        const a = p.hw * p.hh;
        if (a > a1) {
            a1 = a;
            ic = i;
        }
    }
    const ici = ic orelse return null;
    // Reject multi-IC boards by the *group orbit* test: every functional group must
    // orbit the one IC (or carry no hub). A board with two comparable ICs has some
    // groups whose `hub` is the other IC — that's what disqualifies it, not raw
    // hub area (a power inductor is a big hub but anchors nothing, and may even
    // carry a U-prefix ref-des, so an area/prefix test misfires).
    for (lowered.groups) |g| {
        if (g.hub >= 0 and @as(usize, @intCast(g.hub)) != ici) return null;
    }
    return .{ .ic = ici };
}

/// A secondary hub (≠ `ic`) that `members` share a non-ground net with — the power
/// inductor for an output-cap bank, since a switcher's output rail terminates on
/// the inductor, not an IC pad. Used to recover a docking edge when the IC-anchored
/// `railDir` is zero (the bank touches no IC pad). Null when none.
fn nearestSharedHub(members: []const usize, ic: usize, parts: []const Part, nets: []const FlatNet, idx_of: *std.StringHashMap(usize)) ?usize {
    for (nets) |net| {
        if (isGroundName(shortName(net.name))) continue;
        var has_member = false;
        for (net.pins) |pp| {
            const pi = idx_of.get(pp.ref_des) orelse continue;
            if (memberOf(members, pi)) {
                has_member = true;
                break;
            }
        }
        if (!has_member) continue;
        for (net.pins) |pp| {
            const pi = idx_of.get(pp.ref_des) orelse continue;
            if (pi != ic and parts[pi].kind == .hub and !memberOf(members, pi)) return pi;
        }
    }
    return null;
}

/// Sum of the IC's non-ground pad offsets over the nets `members` connect to —
/// the direction (IC-local; IC is at rot 0 so == world) toward the group's rail
/// side. Ground is excluded (it is scattered all round the IC and would average
/// the side away). Zero when the members touch only ground / no IC pad.
fn railDir(members: []const usize, ic: usize, parts: []const Part, nets: []const FlatNet, idx_of: *std.StringHashMap(usize)) Pt {
    const ic_ref = parts[ic].ref_des;
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (nets) |net| {
        if (isGroundName(shortName(net.name))) continue;
        var touches = false;
        for (net.pins) |pp| {
            const pi = idx_of.get(pp.ref_des) orelse continue;
            if (memberOf(members, pi)) {
                touches = true;
                break;
            }
        }
        if (!touches) continue;
        for (net.pins) |pp| {
            if (!std.mem.eql(u8, pp.ref_des, ic_ref)) continue;
            const pad = padLocal(parts[ic], pp.pin);
            if (pad.w == 0 and pad.h == 0) continue;
            sx += pad.x;
            sy += pad.y;
        }
    }
    return .{ .x = sx, .y = sy };
}

/// World cross-coordinate (y for a side edge, x for a top/bottom edge) of the IC's
/// non-ground pads the members connect to — the point a block docks opposite, so
/// its decoupling pad sits across from the supply pad. Null when there's no rail pad.
fn railPadCross(members: []const usize, ic: usize, edge: Edge, parts: []const Part, nets: []const FlatNet, idx_of: *std.StringHashMap(usize)) ?f64 {
    const ic_ref = parts[ic].ref_des;
    const side = (edge == .left or edge == .right); // cross axis = y
    var s: f64 = 0;
    var n: f64 = 0;
    for (nets) |net| {
        if (isGroundName(shortName(net.name))) continue;
        var touches = false;
        for (net.pins) |pp| {
            const pi = idx_of.get(pp.ref_des) orelse continue;
            if (memberOf(members, pi)) {
                touches = true;
                break;
            }
        }
        if (!touches) continue;
        for (net.pins) |pp| {
            if (!std.mem.eql(u8, pp.ref_des, ic_ref)) continue;
            const pad = padLocal(parts[ic], pp.pin);
            if (pad.w == 0 and pad.h == 0) continue;
            // Area-weighted: the big supply pad dominates over small sense pins on
            // the same net (e.g. VOUT's wide pad vs ISP/ISN), so the bank docks
            // opposite the real power pad, not the average of all rail pins.
            const wgt = pad.w * pad.h;
            s += wgt * (if (side) pad.y else pad.x);
            n += wgt;
        }
    }
    if (n <= 0) return null;
    return (if (side) parts[ic].y else parts[ic].x) + s / n;
}

/// Snap a rail direction to the dominant edge (y-down). Null when ~zero.
fn snapEdge(d: Pt) ?Edge {
    if (@abs(d.x) < 1e-9 and @abs(d.y) < 1e-9) return null;
    if (@abs(d.x) >= @abs(d.y)) return if (d.x > 0) .right else .left;
    return if (d.y > 0) .bottom else .top;
}

/// Rotation (of {0,90,180,270}) that turns a cap's power pad toward the IC, so the
/// hot loop is short. Driven by the real loop power pad; (0,0) ⇒ rot 0 (resistor /
/// no loop). `inward` is the unit vector from the block toward the IC.
pub fn faceRotation(pwr: PadRect, edge: Edge) f64 {
    const inward: Pt = switch (edge) {
        .left => .{ .x = 1, .y = 0 },
        .right => .{ .x = -1, .y = 0 },
        .top => .{ .x = 0, .y = 1 },
        .bottom => .{ .x = 0, .y = -1 },
    };
    var best: f64 = 0;
    var best_dot: f64 = -std.math.inf(f64);
    for (ROT_CAND) |rot| {
        const p = rotateLocal(pwr.x, pwr.y, rot);
        const dot = p.x * inward.x + p.y * inward.y;
        if (dot > best_dot) {
            best_dot = dot;
            best = rot;
        }
    }
    return best;
}

/// Rotation-aware half-extents for a part at a given rotation (without mutating it).
fn extByRot(p: Part, rot: f64) Pt {
    return if (isQuarter(rot)) .{ .x = p.hh, .y = p.hw } else .{ .x = p.hw, .y = p.hh };
}

/// The decoupling loop whose cap is part index `cap`, if any.
fn loopForCap(loops: []const Loop, cap: usize) ?Loop {
    for (loops) |lp| {
        if (lp.cap == cap) return lp;
    }
    return null;
}

/// Co-edge anchoring weight of a block: heavier per decoupling-cap member so a
/// hot-loop bank holds its rail-pad target while a lone resistor (mass 1) yields.
fn blockMass(members: []const usize, loops: []const Loop) f64 {
    var caps: usize = 0;
    for (members) |m| {
        if (loopForCap(loops, m) != null) caps += 1;
    }
    return 1.0 + 3.0 * @as(f64, @floatFromInt(caps));
}

/// Order a block's members by *loop criticality*, most critical first (declared
/// `(placement-order …)` priority, then smallest capacitance — the HF bypass cap
/// needs the lowest-inductance path so it goes nearest the pin; bulk caps and
/// resistors trail). `centerOutOrder` then maps this onto column positions so the
/// most critical member lands at the centre. Deterministic, no RNG.
const OrderCtx = struct {
    parts: []const Part,
    priority: []const u32,
    fn lt(c: OrderCtx, a: usize, b: usize) bool {
        const pa = if (a < c.priority.len) c.priority[a] else 0;
        const pb = if (b < c.priority.len) c.priority[b] else 0;
        if (pa != pb) return pa > pb;
        const fa = capValueFarads(c.parts[a].value);
        const fb = capValueFarads(c.parts[b].value);
        const ca = fa > 0; // a is a (recognised) capacitor
        const cb = fb > 0;
        if (ca != cb) return ca; // caps are more central than resistors
        if (ca and fa != fb) return fa < fb; // smaller (HF) cap is more critical
        return std.mem.lessThan(u8, c.parts[a].ref_des, c.parts[b].ref_des);
    }
};
fn orderMembers(arena: std.mem.Allocator, members: []const usize, parts: []const Part, priority: []const u32) std.mem.Allocator.Error![]usize {
    const out = try arena.dupe(usize, members);
    std.mem.sortUnstable(usize, out, OrderCtx{ .parts = parts, .priority = priority }, OrderCtx.lt);
    return out;
}

/// Cross-spread (mm) beyond which a group's members are treated as *distributed*
/// (each maps to a distinct rail pin — e.g. the two boot caps to BOOT1/BOOT2) and
/// laid out in pin order, rather than a *shared*-rail bank centred on one pin.
const DISTRIBUTE_MM: f64 = 0.6;

/// Decide a group block's member layout. If members' own rail-pin cross-positions
/// spread past `DISTRIBUTE_MM` (distinct pins), sort them by pin so each sits above
/// its own pad (returns `pin_order=true`); otherwise keep the criticality order for
/// the centre-out HF placement (`pin_order=false`). Fixes boot caps landing on the
/// wrong lateral side of the IC.
fn orderForBlock(arena: std.mem.Allocator, ordered: []usize, ic: usize, edge: Edge, parts: []const Part, nets: []const FlatNet, idx_of: *std.StringHashMap(usize)) std.mem.Allocator.Error!bool {
    if (ordered.len < 2) return false;
    const tgt = try arena.alloc(f64, ordered.len);
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    const fallback = railPadCross(ordered, ic, edge, parts, nets, idx_of) orelse 0;
    for (ordered, 0..) |m, i| {
        tgt[i] = railPadCross(&.{m}, ic, edge, parts, nets, idx_of) orelse fallback;
        lo = @min(lo, tgt[i]);
        hi = @max(hi, tgt[i]);
    }
    if (hi - lo <= DISTRIBUTE_MM) return false; // shared rail → centre-out
    // Distributed: insertion-sort members by their pin cross (ascending = pack order).
    var a: usize = 1;
    while (a < ordered.len) : (a += 1) {
        var b = a;
        while (b > 0 and tgt[b - 1] > tgt[b]) : (b -= 1) {
            std.mem.swap(f64, &tgt[b - 1], &tgt[b]);
            std.mem.swap(usize, &ordered[b - 1], &ordered[b]);
        }
    }
    return true;
}

/// Re-order a criticality-sorted list (most critical first) into column/row
/// *positions* so the most critical member lands at the centre — nearest the rail
/// pad the block docks opposite — and less critical members flank it outward.
/// (A decoupling bank's HF cap belongs closest to the pin; bulk caps tolerate the
/// ends.) Offsets walk 0,−1,+1,−2,+2,… from the centre, skipping out-of-range.
fn centerOutOrder(arena: std.mem.Allocator, crit: []const usize) std.mem.Allocator.Error![]usize {
    const n = crit.len;
    const out = try arena.alloc(usize, n);
    const c: isize = @intCast(n / 2);
    const ni: isize = @intCast(n);
    var k: usize = 0;
    var step: isize = 0;
    while (k < n) : (step += 1) {
        const off: isize = if (step == 0) 0 else if (@rem(step, 2) == 1) -@divFloor(step + 1, 2) else @divFloor(step, 2);
        const pos = c + off;
        if (pos >= 0 and pos < ni) {
            out[@intCast(pos)] = crit[k];
            k += 1;
        }
    }
    return out;
}

/// Lay `ordered` members into a single row/column for `edge` (left/right ⇒ a
/// vertical column packed along Y; top/bottom ⇒ a horizontal row along X), each
/// rotated so its power pad faces the IC, packed edge-to-edge with `gap`.
///
/// `pin_order` true means `ordered` is already in pack-axis order by each member's
/// own rail pin (a *distributed* group like the two boot caps, which must sit above
/// their own BOOT pad) — laid in that order verbatim. False means a *shared*-rail
/// bank: the order is by criticality and `centerOutOrder` puts the HF cap at the
/// centre nearest the single pin. Members are aligned by their **inner (power-pad)
/// edge** toward the IC, not by centre, so a narrow cap isn't dragged outboard by
/// a wider neighbour (its power pad stays as close to the rail pad as the others').
fn packOneBlock(arena: std.mem.Allocator, ordered: []const usize, parts: []const Part, edge: Edge, loops: []const Loop, gap: f64, pin_order: bool) std.mem.Allocator.Error!PackBlock {
    const seq = if (pin_order) try arena.dupe(usize, ordered) else try centerOutOrder(arena, ordered);
    const n = seq.len;
    const rots = try arena.alloc(f64, n);
    const lx = try arena.alloc(f64, n);
    const ly = try arena.alloc(f64, n);
    const exts = try arena.alloc(Pt, n);
    const vertical = (edge == .left or edge == .right); // pack along Y
    // Inward (toward-IC) sign on the depth axis: left ⇒ +x, right ⇒ −x, top ⇒ +y,
    // bottom ⇒ −y (y is down).
    const inward: f64 = switch (edge) {
        .left, .top => 1,
        .right, .bottom => -1,
    };
    for (seq, 0..) |m, i| {
        var rot: f64 = 0;
        if (loopForCap(loops, m)) |lp| rot = faceRotation(lp.cap_pwr, edge);
        rots[i] = rot;
        exts[i] = extByRot(parts[m], rot);
    }
    var total: f64 = 0;
    for (exts) |e| total += 2 * (if (vertical) e.y else e.x);
    total += @as(f64, @floatFromInt(n - 1)) * gap;
    var cross_half: f64 = 0;
    for (exts) |e| cross_half = @max(cross_half, if (vertical) e.x else e.y);
    var cursor = -total / 2;
    for (0..n) |i| {
        const along = if (vertical) exts[i].y else exts[i].x;
        const depth_off = inward * (cross_half - (if (vertical) exts[i].x else exts[i].y));
        const pack = cursor + along;
        if (vertical) {
            lx[i] = depth_off; // align inner (power-pad) edge toward the IC
            ly[i] = pack;
        } else {
            lx[i] = pack;
            ly[i] = depth_off;
        }
        cursor += 2 * along + gap;
    }
    return .{
        .members = seq,
        .rots = rots,
        .lx = lx,
        .ly = ly,
        .half_w = if (vertical) cross_half else total / 2,
        .half_h = if (vertical) total / 2 else cross_half,
        .edge = edge,
    };
}

/// Dock every block assigned to `edge` against the IC's `edge` side. Each block is
/// placed centred on its rail pin's cross-coordinate (`target`) so a decoupling
/// bank sits opposite its supply pad (short loop); when co-edge blocks contend for
/// the same cross space the overlap is split by *inverse mass*, so a hot-loop bank
/// holds its target and a lone resistor yields. Records each member's aligned axis
/// in `lock_axis`/`lock_val` (1 ⇒ shared x column, 2 ⇒ shared y row) for the finish.
fn dockEdge(parts: []Part, ic: usize, blocks: []const PackBlock, edge: Edge, gap: f64, gap_dock: f64, lock_axis: []u8, lock_val: []f64) void {
    const vertical = (edge == .left or edge == .right); // cross axis = Y
    const ic_cross = if (vertical) parts[ic].y else parts[ic].x;
    // Gather this edge's blocks (index + cross geometry) into fixed local arrays;
    // bounded by the part count, which the topology gate caps at POLISH_MAX_PARTS.
    var bi: [POLISH_MAX_PARTS]usize = undefined;
    var center: [POLISH_MAX_PARTS]f64 = undefined;
    var half: [POLISH_MAX_PARTS]f64 = undefined;
    var mass: [POLISH_MAX_PARTS]f64 = undefined;
    var k: usize = 0;
    for (blocks, 0..) |b, idx| {
        if (b.edge != edge or k >= POLISH_MAX_PARTS) continue;
        bi[k] = idx;
        center[k] = if (b.target_set) b.target else ic_cross;
        half[k] = if (vertical) b.half_h else b.half_w;
        mass[k] = b.mass;
        k += 1;
    }
    if (k == 0) return;
    // Sort by target cross-position (insertion sort — k is tiny).
    var a: usize = 1;
    while (a < k) : (a += 1) {
        var b2 = a;
        while (b2 > 0 and center[b2 - 1] > center[b2]) : (b2 -= 1) {
            std.mem.swap(usize, &bi[b2 - 1], &bi[b2]);
            std.mem.swap(f64, &center[b2 - 1], &center[b2]);
            std.mem.swap(f64, &half[b2 - 1], &half[b2]);
            std.mem.swap(f64, &mass[b2 - 1], &mass[b2]);
        }
    }
    // Resolve overlaps by pushing neighbours apart, the lighter one moving more.
    var it: usize = 0;
    while (it < 128) : (it += 1) {
        var moved = false;
        for (1..k) |j| {
            const need = (center[j - 1] + half[j - 1] + gap) - (center[j] - half[j]);
            if (need > 1e-6) {
                const tot = mass[j - 1] + mass[j];
                center[j - 1] -= need * (mass[j] / tot);
                center[j] += need * (mass[j - 1] / tot);
                moved = true;
            }
        }
        if (!moved) break;
    }
    for (0..k) |j| {
        const b = blocks[bi[j]];
        const depth_center = switch (edge) {
            .left => parts[ic].x - effHw(parts[ic]) - gap_dock - b.half_w,
            .right => parts[ic].x + effHw(parts[ic]) + gap_dock + b.half_w,
            .top => parts[ic].y - effHh(parts[ic]) - gap_dock - b.half_h,
            .bottom => parts[ic].y + effHh(parts[ic]) + gap_dock + b.half_h,
        };
        const cx = if (vertical) depth_center else center[j];
        const cy = if (vertical) center[j] else depth_center;
        for (b.members, 0..) |m, mj| {
            parts[m].rot = b.rots[mj];
            parts[m].x = cx + b.lx[mj];
            parts[m].y = cy + b.ly[mj];
            if (vertical) {
                lock_axis[m] = 1;
                lock_val[m] = parts[m].x;
            } else {
                lock_axis[m] = 2;
                lock_val[m] = parts[m].y;
            }
        }
    }
}

/// Place a secondary hub (the power inductor) at the switch node: centred on the
/// IC's switch-pad x-centroid, docked tight to the less-crowded of the top/bottom
/// edge, so it straddles SW1/SW2 instead of floating off. Locks its x to the
/// switch-pad centroid so the finish keeps it centred. Falls back to the top edge
/// when no switch pad is found.
fn placeSwitchHub(parts: []Part, ic: usize, sec: usize, nets: []const FlatNet, idx_of: *std.StringHashMap(usize), blocks: []const PackBlock, gap: f64, lock_axis: []u8, lock_val: []f64) void {
    const ic_ref = parts[ic].ref_des;
    var sx: f64 = 0;
    var nsw: usize = 0;
    for (nets) |net| {
        if (isGroundName(shortName(net.name))) continue;
        var t_ic = false;
        var t_sec = false;
        for (net.pins) |pp| {
            const pi = idx_of.get(pp.ref_des) orelse continue;
            if (pi == ic) t_ic = true;
            if (pi == sec) t_sec = true;
        }
        if (!(t_ic and t_sec)) continue;
        for (net.pins) |pp| {
            if (!std.mem.eql(u8, pp.ref_des, ic_ref)) continue;
            const pad = padLocal(parts[ic], pp.pin);
            if (pad.w == 0 and pad.h == 0) continue;
            sx += pad.x;
            nsw += 1;
        }
    }
    const cx = parts[ic].x + (if (nsw > 0) sx / @as(f64, @floatFromInt(nsw)) else 0);
    // Dock to whichever of top/bottom carries fewer blocks (keeps the switch cell
    // off the busier edge). (Docking on the SW pad's own side edge was tried and
    // regressed tps54540-buck badly — the inductor collided with its output bank;
    // the acceptance gate below is the general safety net instead.)
    var top: usize = 0;
    var bot: usize = 0;
    for (blocks) |b| {
        if (b.edge == .top) top += 1;
        if (b.edge == .bottom) bot += 1;
    }
    parts[sec].rot = 0;
    const e = extByRot(parts[sec], 0);
    parts[sec].x = cx;
    parts[sec].y = if (top <= bot)
        parts[ic].y - effHh(parts[ic]) - gap - e.y
    else
        parts[ic].y + effHh(parts[ic]) + gap + e.y;
    lock_axis[sec] = 1; // keep it centred on the switch-pad x
    lock_val[sec] = cx;
}

/// Constructive zone-then-pack floorplan. Returns true when it produced a
/// complete, overlap-free arrangement; false ⇒ caller uses the force pipeline.
fn packZoned(
    arena: std.mem.Allocator,
    parts: []Part,
    prep: *Prepared,
    nets: []const FlatNet,
    built: Built,
    params: Params,
) std.mem.Allocator.Error!bool {
    _ = params;
    const topo = analyzeTopology(parts, g_lowered) orelse return false;
    const ic = topo.ic;
    parts[ic].x = 0;
    parts[ic].y = 0;
    parts[ic].rot = 0;

    const claimed = try arena.alloc(bool, parts.len);
    @memset(claimed, false);
    claimed[ic] = true;
    // Per-part aligned-axis lock (0 none, 1 shared-x column, 2 shared-y row) so the
    // finish can restore the crisp row/column line that `legalize` jitters.
    const lock_axis = try arena.alloc(u8, parts.len);
    @memset(lock_axis, 0);
    const lock_val = try arena.alloc(f64, parts.len);

    var blocks: std.ArrayListUnmanaged(PackBlock) = .empty;
    const gap = @max(g_route_gap, FINAL_CLEAR);

    // Functional-group blocks (hub members dropped — IC at origin, inductor below).
    for (g_lowered.groups) |g| {
        var ml: std.ArrayListUnmanaged(usize) = .empty;
        for (g.members) |m| {
            if (parts[m].kind == .hub or claimed[m]) continue;
            try ml.append(arena, m);
        }
        if (ml.items.len == 0) continue;
        const ordered = try orderMembers(arena, ml.items, parts, prep.priority);
        for (ordered) |m| claimed[m] = true;
        // Edge from the group's IC rail pin. A switcher OUTPUT bank touches no IC
        // pad (VOUT is made at the inductor), so IC-railDir is zero — then resolve
        // the edge from the inductor (a shared secondary hub) by its IC switch pin,
        // so the bank docks on the SW→L→VOUT side instead of the blind `.bottom`.
        var edge_anchor = ic;
        var dir = railDir(ordered, ic, parts, nets, &prep.idx_of);
        if (@abs(dir.x) < 1e-9 and @abs(dir.y) < 1e-9) {
            if (nearestSharedHub(ordered, ic, parts, nets, &prep.idx_of)) |sh| {
                const hubdir = railDir(&.{sh}, ic, parts, nets, &prep.idx_of);
                if (@abs(hubdir.x) > 1e-9 or @abs(hubdir.y) > 1e-9) {
                    dir = hubdir;
                    edge_anchor = sh;
                }
            }
        }
        const edge = snapEdge(dir) orelse .bottom;
        const pin_order = try orderForBlock(arena, ordered, ic, edge, parts, nets, &prep.idx_of);
        var blk = try packOneBlock(arena, ordered, parts, edge, built.loops, gap, pin_order);
        // Cross target: the rail pin on whichever anchor the edge came from (the IC,
        // or the inductor's IC switch pin for an output bank).
        const tgt = if (edge_anchor == ic)
            railPadCross(ordered, ic, edge, parts, nets, &prep.idx_of)
        else
            railPadCross(&.{edge_anchor}, ic, edge, parts, nets, &prep.idx_of);
        if (tgt) |t| {
            blk.target = t;
            blk.target_set = true;
        }
        blk.mass = blockMass(ordered, built.loops);
        try blocks.append(arena, blk);
    }
    // Loose passives (in no group) — each its own single-member block.
    for (parts, 0..) |p, i| {
        if (claimed[i] or p.kind == .hub) continue;
        claimed[i] = true;
        const single = try arena.dupe(usize, &.{i});
        const edge = snapEdge(railDir(single, ic, parts, nets, &prep.idx_of)) orelse .bottom;
        var blk = try packOneBlock(arena, single, parts, edge, built.loops, gap, false);
        if (railPadCross(single, ic, edge, parts, nets, &prep.idx_of)) |t| {
            blk.target = t;
            blk.target_set = true;
        }
        blk.mass = blockMass(single, built.loops);
        try blocks.append(arena, blk);
    }
    // Dock the group + loose blocks first so the switch-hub placement can see which
    // of the top/bottom edges is busier.
    dockEdge(parts, ic, blocks.items, .left, gap, gap, lock_axis, lock_val);
    dockEdge(parts, ic, blocks.items, .right, gap, gap, lock_axis, lock_val);
    dockEdge(parts, ic, blocks.items, .top, gap, gap, lock_axis, lock_val);
    dockEdge(parts, ic, blocks.items, .bottom, gap, gap, lock_axis, lock_val);

    // Secondary hubs (the power inductor) straddle the switch node — placed last,
    // centred on the IC's switch pads, on the less-crowded top/bottom edge.
    for (parts, 0..) |p, i| {
        if (claimed[i] or p.kind != .hub) continue;
        claimed[i] = true;
        placeSwitchHub(parts, ic, i, nets, &prep.idx_of, blocks.items, gap, lock_axis, lock_val);
    }

    legalize(parts, FINAL_CLEAR);
    // Restore the crisp row/column lines `legalize` nudged (a column's shared x, a
    // row's shared y); on-grid legalization then resolves any residual *cross-axis*
    // overlap by whole cells, leaving the aligned axis intact.
    for (parts, 0..) |*p, i| {
        if (lock_axis[i] == 1) p.x = lock_val[i] else if (lock_axis[i] == 2) p.y = lock_val[i];
    }
    snapToGrid(parts);
    legalizeOnGrid(parts);
    return !anyOverlap(parts);
}

/// Map a `(board …)` edge keyword to the optimizer's dock `Edge`. Used by
/// `packBoard` to dock connectors flush to a physical board edge.
fn edgeFromSide(s: env.PlacementSide) Edge {
    return switch (s) {
        .left => .left,
        .right => .right,
        .top => .top,
        .bottom => .bottom,
    };
}

/// Gap (mm) below the board where parts the spec didn't list are staged.
const STAGE_GAP_MM: f64 = 5.0;

/// Auto-fill cost guard: staged-part counts beyond this keep the band (each
/// fill is a windowed scan). Sized for the `(floorplan …)` usage on a real
/// board — list the modules + connectors, auto-fill ALL the loose glue (the
/// barracuda base board leaves 31 RC-filter parts loose; the original cap of
/// 24 silently skipped every one of them). The expensive routed veto is gated
/// separately (`AUTOFILL_VETO_MAX`), so a high cap costs only windowed scans.
const AUTOFILL_MAX: usize = 64;
/// Re-sweep the fills until none improves: placing one part gives the parts
/// that wire to it (and only it) their anchors, so chains fill over sweeps.
const AUTOFILL_SWEEPS: usize = 3;
/// Routed-veto gate: above this part count, skip the per-fill re-route check
/// (matches the routedLoops gate — routing large boards per move is too slow).
const AUTOFILL_VETO_MAX: usize = 48;
/// Search window margin (mm) beyond the anchor targets' bounding box.
const AUTOFILL_MARGIN_MM: f64 = 6.0;
/// Window cap (grid cells per axis) — bounds the scan on pathological boards.
/// 240·GRID_MM ≈ ±24 mm reach (the real bound is the board extent on normal
/// boards); paired to GRID_MM so the millimetre cap holds across grid sizes.
const RELOCATE_MAX_CELLS: i64 = 240;
/// Coarse stride (grid cells) for the first scan pass: sample the window every
/// N cells, then refine at full resolution around the coarse best. 4·GRID_MM ≈
/// 0.4 mm physical stride — paired to GRID_MM so the coarse pass keeps both its
/// stride and its iteration count when the grid changes.
const COARSE_STRIDE: i64 = 4;
/// Ground anchors pull weakly — the return is a via to the plane, not a trace
/// to one specific pad, so any nearby GND pad serves.
const AUTOFILL_GND_W: f64 = 0.25;

/// Place every part the `(placement …)` spec didn't list ("pin-hug" auto-fill):
/// instead of leaving them in the staging band below the board, move each to
/// the collision-free pose nearest the *already-placed* pads it wires to, while
/// every authored part stays exactly where the spec put it. A partial spec thus
/// yields a usable board: the author pins the structure they care about, the
/// solver fills in the rest.
///
/// Candidates are scored against placed parts ONLY (`autofillAnchors`): two
/// staged parts that share a net (a feedback R + its C) would otherwise anchor
/// each other inside the band and never leave — scoring against the placed set
/// breaks the coupling, and makes each candidate O(anchors) instead of a full-
/// board objective pass. A part whose nets touch only staged parts waits a
/// sweep until a partner lands. Each kept move is re-routed and reverted if it
/// would drop a net (gated on board size). Parts that find no spot stay in the
/// band and remain `unplaced`; filled parts move to `auto_filled` in the diag.
fn autofillUnlisted(
    arena: std.mem.Allocator,
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
) std.mem.Allocator.Error!void {
    const staged_refs = g_placement_diag.unplaced;
    if (staged_refs.len == 0 or staged_refs.len > AUTOFILL_MAX) return;

    var idxs: std.ArrayListUnmanaged(usize) = .empty;
    for (staged_refs) |ref| {
        if (idx_of.get(ref)) |i| try idxs.append(arena, i);
    }
    // Most-constrained first: loop-bearing caps must reach their hub pins, and
    // big parts need contiguous room — both go before small free placements so
    // late arrivals only have small holes left to fill.
    std.sort.insertion(usize, idxs.items, SortByLoopThenArea{ .parts = parts, .loops = loops }, SortByLoopThenArea.lessThan);

    const staged = try arena.alloc(bool, parts.len);
    @memset(staged, false);
    for (idxs.items) |i| staged[i] = true;

    // Routed veto per SWEEP, not per fill: one maze route per sweep (≤4 total
    // with the baseline) instead of one per part — if a sweep's fills cost a
    // routed net, the whole sweep is backed out and filling stops there.
    const veto = parts.len <= AUTOFILL_VETO_MAX;
    var baseline = if (veto) routedCount(arena, parts, nets) else 0;
    var sweep: usize = 0;
    while (sweep < AUTOFILL_SWEEPS) : (sweep += 1) {
        var improved = false;
        const sweep_poses = try capturePoses(arena, parts);
        var sweep_filled: std.ArrayListUnmanaged(usize) = .empty;
        for (idxs.items) |i| {
            if (!staged[i]) continue; // already filled in an earlier sweep
            const anchors = try autofillAnchors(arena, parts, nets, staged, i);
            if (anchors.len == 0) continue; // wires only to staged parts — wait a sweep
            if (!autofillOne(parts, anchors, i)) continue;
            staged[i] = false;
            try sweep_filled.append(arena, i);
            improved = true;
        }
        if (veto and sweep_filled.items.len > 0) {
            const rc = routedCount(arena, parts, nets);
            if (rc < baseline) {
                // One of this sweep's fills blocked a routed net. Back the whole
                // sweep out, then salvage: re-fill one part at a time with a
                // per-part route check, so only the true culprit stays staged.
                // (The sweep-level check exists for speed; this slower path only
                // runs when a sweep actually regresses.)
                restorePoses(parts, sweep_poses);
                for (sweep_filled.items) |i| staged[i] = true;
                for (sweep_filled.items) |i| {
                    const anchors = try autofillAnchors(arena, parts, nets, staged, i);
                    if (anchors.len == 0) continue;
                    const p = &parts[i];
                    const sx = p.x;
                    const sy = p.y;
                    const sr = p.rot;
                    if (!autofillOne(parts, anchors, i)) continue;
                    const rc2 = routedCount(arena, parts, nets);
                    if (rc2 < baseline) {
                        p.x = sx;
                        p.y = sy;
                        p.rot = sr;
                    } else {
                        baseline = rc2;
                        staged[i] = false;
                    }
                }
                break;
            }
            baseline = rc;
        }
        if (!improved) break;
    }

    var filled: std.ArrayListUnmanaged([]const u8) = .empty;
    // Append to (not replace) earlier fills — the board-dock path runs a
    // second pass for the connectors' partners.
    try filled.appendSlice(arena, g_placement_diag.auto_filled);
    var remaining: std.ArrayListUnmanaged([]const u8) = .empty;
    var any_filled = false;
    for (idxs.items) |i| {
        if (!staged[i]) {
            try filled.append(arena, parts[i].ref_des);
            any_filled = true;
        } else {
            try remaining.append(arena, parts[i].ref_des);
        }
    }
    if (any_filled) {
        snapToGrid(parts);
        legalizeOnGrid(parts);
    }
    g_placement_diag.auto_filled = try filled.toOwnedSlice(arena);
    g_placement_diag.unplaced = try remaining.toOwnedSlice(arena);
}

/// Auto-fill order: loop-bearing parts first, then larger courtyards first.
const SortByLoopThenArea = struct {
    parts: []const Part,
    loops: []const Loop,

    fn hasLoop(self: SortByLoopThenArea, i: usize) bool {
        for (self.loops) |L| {
            if (L.cap == i) return true;
        }
        return false;
    }
    fn lessThan(self: SortByLoopThenArea, a: usize, b: usize) bool {
        const la = self.hasLoop(a);
        const lb = self.hasLoop(b);
        if (la != lb) return la;
        return self.parts[a].hw * self.parts[a].hh > self.parts[b].hw * self.parts[b].hh;
    }
};

/// One pad of the part being filled, paired with the world positions of every
/// already-placed pad on the same net. The fill cost takes the min over
/// `targets` per pad, so a multi-pad net (GND) pulls toward whichever placed
/// pad is closest to the candidate pose.
const PadAnchor = struct {
    lx: f64,
    ly: f64,
    w: f64,
    targets: []const [2]f64,
};

/// Build staged part `i`'s anchor list against the placed set: for each of its
/// pads' nets, the world positions of that net's pads on non-staged parts.
/// Empty when the part wires only to other staged parts (wait a sweep).
fn autofillAnchors(
    arena: std.mem.Allocator,
    parts: []const Part,
    nets: []const FlatNet,
    staged: []const bool,
    i: usize,
) std.mem.Allocator.Error![]PadAnchor {
    var out: std.ArrayListUnmanaged(PadAnchor) = .empty;
    const me = parts[i];
    for (nets) |net| {
        for (net.pins) |pin| {
            if (!std.mem.eql(u8, pin.ref_des, me.ref_des)) continue;
            const pad = padByNumber(me, pin.pin) orelse continue;
            var targets: std.ArrayListUnmanaged([2]f64) = .empty;
            for (net.pins) |op| {
                if (std.mem.eql(u8, op.ref_des, me.ref_des)) continue;
                const j = indexOfRef(parts, op.ref_des) orelse continue;
                if (staged[j]) continue;
                const opad = padByNumber(parts[j], op.pin) orelse continue;
                const wp = worldPt(parts[j], opad.x, opad.y);
                try targets.append(arena, .{ wp.x, wp.y });
            }
            if (targets.items.len == 0) continue;
            try out.append(arena, .{
                .lx = pad.x,
                .ly = pad.y,
                .w = if (isGroundName(net.name)) AUTOFILL_GND_W else 1.0,
                .targets = try targets.toOwnedSlice(arena),
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Anchor cost of part `i`'s current pose: each anchored pad's weighted
/// distance to its nearest placed counterpart.
fn anchorCost(parts: []const Part, anchors: []const PadAnchor, i: usize) f64 {
    const p = parts[i];
    var sum: f64 = 0;
    for (anchors) |a| {
        const wp = worldPt(p, a.lx, a.ly);
        var best = std.math.floatMax(f64);
        for (a.targets) |t| {
            const d = std.math.hypot(wp.x - t[0], wp.y - t[1]);
            if (d < best) best = d;
        }
        sum += a.w * best;
    }
    return sum;
}

/// `std.math.clamp(v, lo, hi)` but tolerant of an inverted interval: when the
/// window would invert (`lo > hi`, i.e. the slot is wider than the range it
/// slides in), return `v` unchanged rather than asserting. Used by `autofillOne`
/// to centre a re-located window on the targets when there's no room to slide.
fn clampOrCenter(v: f64, lo: f64, hi: f64) f64 {
    if (lo > hi) return v;
    return std.math.clamp(v, lo, hi);
}

/// Move staged part `i` to the collision-free (position × rotation) with the
/// lowest anchor cost, scanning a window around the anchor targets' bounding
/// box coarse-to-fine. Returns true if an improving pose was found.
fn autofillOne(parts: []Part, anchors: []const PadAnchor, i: usize) bool {
    // Window: the targets' bounding box + margin, as cell offsets from here.
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (anchors) |a| for (a.targets) |t| {
        minx = @min(minx, t[0]);
        miny = @min(miny, t[1]);
        maxx = @max(maxx, t[0]);
        maxy = @max(maxy, t[1]);
    };
    const p = &parts[i];
    const ox = p.x;
    const oy = p.y;
    const m = AUTOFILL_MARGIN_MM + effHw(p.*) + effHh(p.*);
    var lo_x = @max(-RELOCATE_MAX_CELLS, cellOffset(minx - m - ox));
    var hi_x = @min(RELOCATE_MAX_CELLS, cellOffset(maxx + m - ox));
    var lo_y = @max(-RELOCATE_MAX_CELLS, cellOffset(miny - m - oy));
    var hi_y = @min(RELOCATE_MAX_CELLS, cellOffset(maxy + m - oy));
    // The part-relative clamp empties the window when the part is staged far
    // from every target (a band pushed below a (board …) outline) — then
    // re-centre the window on the targets' bbox instead, in absolute mm,
    // same span cap. Near-target fills keep the original window byte-for-byte.
    if (lo_x > hi_x or lo_y > hi_y) {
        const half_span = @as(f64, @floatFromInt(RELOCATE_MAX_CELLS)) * GRID_MM / 2.0;
        // The clamp keeps the window's centre inside the targets' bbox (± the
        // margin), but its bounds only order when the bbox+margin is at least as
        // wide as the window (2*half_span). A single target (span 0) with a small
        // part inverts them and `std.math.clamp` asserts lower<=upper — a Debug
        // panic and UB in ReleaseSmall. When the window is wider than the bbox,
        // there's nothing to slide against, so just centre on the targets.
        const cx0 = clampOrCenter((minx + maxx) / 2, minx - m + half_span, maxx + m - half_span);
        const cy0 = clampOrCenter((miny + maxy) / 2, miny - m + half_span, maxy + m - half_span);
        lo_x = cellOffset(cx0 - half_span - ox);
        hi_x = cellOffset(cx0 + half_span - ox);
        lo_y = cellOffset(cy0 - half_span - oy);
        hi_y = cellOffset(cy0 + half_span - oy);
    }

    var best = anchorCost(parts, anchors, i);
    var bx = ox;
    var by = oy;
    var br = p.rot;
    var moved = false;

    // A pinned rotation is decided (spec / series pairing) — search position only.
    const pinned = [_]f64{p.rot};
    const rot_cands: []const f64 = if (p.rot_pin != .none) &pinned else &ROT_CAND;

    // Coarse pass: every COARSE_STRIDE cells over the window.
    for (rot_cands) |r| {
        var dy: i64 = lo_y;
        while (dy <= hi_y) : (dy += COARSE_STRIDE) {
            var dx: i64 = lo_x;
            while (dx <= hi_x) : (dx += COARSE_STRIDE) {
                p.rot = r;
                p.x = ox + @as(f64, @floatFromInt(dx)) * GRID_MM;
                p.y = oy + @as(f64, @floatFromInt(dy)) * GRID_MM;
                if (overlapsAny(parts, p)) continue;
                const c = anchorCost(parts, anchors, i);
                if (c < best - 1e-9) {
                    best = c;
                    bx = p.x;
                    by = p.y;
                    br = r;
                    moved = true;
                }
            }
        }
    }

    // Fine pass: full resolution in a ±COARSE_STRIDE box around the coarse best.
    const cx = cellOffset(bx - ox);
    const cy = cellOffset(by - oy);
    for (rot_cands) |r| {
        var dy: i64 = @max(lo_y, cy - COARSE_STRIDE);
        while (dy <= @min(hi_y, cy + COARSE_STRIDE)) : (dy += 1) {
            var dx: i64 = @max(lo_x, cx - COARSE_STRIDE);
            while (dx <= @min(hi_x, cx + COARSE_STRIDE)) : (dx += 1) {
                p.rot = r;
                p.x = ox + @as(f64, @floatFromInt(dx)) * GRID_MM;
                p.y = oy + @as(f64, @floatFromInt(dy)) * GRID_MM;
                if (overlapsAny(parts, p)) continue;
                const c = anchorCost(parts, anchors, i);
                if (c < best - 1e-9) {
                    best = c;
                    bx = p.x;
                    by = p.y;
                    br = r;
                    moved = true;
                }
            }
        }
    }
    p.x = bx;
    p.y = by;
    p.rot = br;
    return moved;
}

/// `parts[i].pads` entry with the given pad number, or null.
fn padByNumber(p: Part, number: []const u8) ?geometry.Pad {
    for (p.pads) |pad| {
        if (std.mem.eql(u8, pad.number, number)) return pad;
    }
    return null;
}

/// Index of the part with this exact ref-des, or null.
fn indexOfRef(parts: []const Part, ref: []const u8) ?usize {
    for (parts, 0..) |p, j| {
        if (std.mem.eql(u8, p.ref_des, ref)) return j;
    }
    return null;
}

/// Round a millimetre offset to the nearest grid-cell count.
fn cellOffset(mm: f64) i64 {
    return @intFromFloat(@round(mm / GRID_MM));
}

/// Snapshot every part's pose — the strict/overlap retry in `solve` keeps the
/// better-routed of the two and restores it with `restorePoses`.
fn capturePoses(arena: std.mem.Allocator, parts: []const Part) std.mem.Allocator.Error![]Pose {
    const out = try arena.alloc(Pose, parts.len);
    for (parts, 0..) |p, i| out[i] = .{ .x = p.x, .y = p.y, .rot = p.rot };
    return out;
}

/// Restore poses captured by `capturePoses`.
fn restorePoses(parts: []Part, poses: []const Pose) void {
    for (parts, 0..) |*p, i| {
        p.x = poses[i].x;
        p.y = poses[i].y;
        p.rot = poses[i].rot;
    }
}

// ── (floorplan …) design-level macro pack ───────────────────────────────────

/// One rigid macro scheduled for docking: the design-part indices of its
/// members, their poses relative to the macro origin (a grid point, so a
/// grid-snapped dock keeps every member on grid), and its tight bbox.
const Macro = struct {
    members: []usize,
    lx: []f64,
    ly: []f64,
    rots: []f64,
    bminx: f64 = 0,
    bminy: f64 = 0,
    bmaxx: f64 = 0,
    bmaxy: f64 = 0,

    fn width(m: Macro) f64 {
        return m.bmaxx - m.bminx;
    }
    fn height(m: Macro) f64 {
        return m.bmaxy - m.bminy;
    }
};

/// The threadlocal state `prepare` publishes for a solve — snapshotted and
/// restored around the nested per-sub-block solves the rough hierarchical seed
/// runs, so the parent solve's own constraints/diagnostics survive. Progress is
/// muted during the nested solves (their frames would garble the live-regen view).
const SolveState = struct {
    lowered: Lowered,
    group_force: f64,
    zone_force: f64,
    loop_force_scale: []const f64,
    collide_shrink: f64,
    route_gap: f64,
    diag: PlacementDiag,
    progress: ?ProgressSink,

    fn snapshot() SolveState {
        return .{
            .lowered = g_lowered,
            .group_force = g_group_force,
            .zone_force = g_zone_force,
            .loop_force_scale = g_loop_force_scale,
            .collide_shrink = g_collide_shrink,
            .route_gap = g_route_gap,
            .diag = g_placement_diag,
            .progress = g_progress,
        };
    }

    fn restore(s: SolveState) void {
        g_lowered = s.lowered;
        g_group_force = s.group_force;
        g_zone_force = s.zone_force;
        g_loop_force_scale = s.loop_force_scale;
        g_collide_shrink = s.collide_shrink;
        g_route_gap = s.route_gap;
        g_placement_diag = s.diag;
        g_progress = s.progress;
    }
};

/// Round to the placement grid (member offsets are grid multiples, so a
/// grid-rounded origin keeps every member on grid).
fn gridRound(v: f64) f64 {
    return @round(v / GRID_MM) * GRID_MM;
}

/// Normalize raw member poses into a rigid macro: apply the quarter-step
/// whole-macro rotation about the centroid, re-origin on a grid point, and
/// measure the tight bbox from the members' rotated courtyards. The pose
/// slices are mutated in place and adopted by the returned macro.
fn finishMacro(
    members: []usize,
    xs: []f64,
    ys: []f64,
    rots: []f64,
    parts: []const Part,
    rot_override: ?f64,
) Macro {
    if (rot_override) |r0| {
        const r = @mod(@round(r0 / 90.0) * 90.0, 360.0);
        if (r != 0) {
            var rcx: f64 = 0;
            var rcy: f64 = 0;
            for (xs) |x| rcx += x;
            for (ys) |y| rcy += y;
            rcx /= @as(f64, @floatFromInt(xs.len));
            rcy /= @as(f64, @floatFromInt(ys.len));
            const a = r * std.math.pi / 180.0;
            // Exact quarter-turn sines keep grid-multiple offsets on grid.
            const c = @round(@cos(a));
            const s = @round(@sin(a));
            for (xs, ys, rots) |*x, *y, *rt| {
                const dx = x.* - rcx;
                const dy = y.* - rcy;
                x.* = rcx + dx * c - dy * s;
                y.* = rcy + dx * s + dy * c;
                rt.* = @mod(rt.* + r, 360.0);
            }
        }
    }
    const ox = gridRound(xs[0]);
    const oy = gridRound(ys[0]);
    var m = Macro{
        .members = members,
        .lx = xs,
        .ly = ys,
        .rots = rots,
        .bminx = std.math.inf(f64),
        .bminy = std.math.inf(f64),
        .bmaxx = -std.math.inf(f64),
        .bmaxy = -std.math.inf(f64),
    };
    for (members, 0..) |pi, k| {
        xs[k] = gridRound(xs[k] - ox);
        ys[k] = gridRound(ys[k] - oy);
        // Keepout-aware extents (escape-stub corridors included): the dock and
        // clash tests must respect the same boxes `anyOverlap` checks, or a
        // member's breakout corridor pokes into the neighbouring macro.
        var tmp = parts[pi];
        tmp.rot = rots[k];
        const kb = keepBoxOf(tmp);
        m.bminx = @min(m.bminx, xs[k] + kb.cxo - kb.hw);
        m.bmaxx = @max(m.bmaxx, xs[k] + kb.cxo + kb.hw);
        m.bminy = @min(m.bminy, ys[k] + kb.cyo - kb.hh);
        m.bmaxy = @max(m.bmaxy, ys[k] + kb.cyo + kb.hh);
    }
    return m;
}

/// Solve one `(sub-block …)` as its own board and lift the result into a rigid
/// macro of design-part indices (flattened ref = `slug/<module ref>`). The
/// nested solve trashes the thread's solve state — the caller brackets the
/// whole macro-building phase with a `SolveState` snapshot. Null when no
/// member maps into the flattened design.
fn buildSubMacro(
    arena: std.mem.Allocator,
    sub: env.SubBlock,
    rot_override: ?f64,
    prep: *Prepared,
    project_dir: []const u8,
    params: Params,
) std.mem.Allocator.Error!?Macro {
    // The nested solve's `prepare` overwrites the collision box globals
    // (`g_collide_shrink`/`g_route_gap`) with the *child's* values; `finishMacro`
    // below reads them (via `keepBoxOf`) to size the parent macro's keepout box.
    // Capture the parent's values now and restore them before `finishMacro`, so
    // the macro extents are measured under the parent's params, not the last
    // child's — inert at the defaults (both 0/equal), correct for any non-default
    // `courtyard_overlap` / `route_gap`.
    const saved_shrink = g_collide_shrink;
    const saved_gap = g_route_gap;
    const sp = try solve(arena, sub.block, project_dir, null, params, .place);
    // Design-side lookup: refs compose as `slug/<module ref>` when the flatten
    // kept the module's numbering, but a design-level renumber shifts it
    // (design `buck/U2` vs module `U1`) — fall back to the renumber-proof
    // origin-key match. Both fallback sides are restricted to first-level
    // children (no nested `/`), where module-local origin keys are unique.
    var origin_idx = std.StringHashMap(usize).init(arena);
    const prefix = try std.fmt.allocPrint(arena, "{s}/", .{sub.name});
    for (prep.instances, 0..) |inst, i| {
        if (!std.mem.startsWith(u8, inst.ref_des, prefix)) continue;
        if (inst.origin_key.len == 0) continue;
        if (std.mem.indexOfScalar(u8, inst.ref_des[prefix.len..], '/') != null) continue;
        try origin_idx.put(inst.origin_key, i);
    }
    var members: std.ArrayListUnmanaged(usize) = .empty;
    var xs: std.ArrayListUnmanaged(f64) = .empty;
    var ys: std.ArrayListUnmanaged(f64) = .empty;
    var rots: std.ArrayListUnmanaged(f64) = .empty;
    for (sp.parts, 0..) |part, j| {
        const ref = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sub.name, part.ref_des });
        const key = if (j < sp.instances.len and sp.instances[j].origin_key.len > 0)
            sp.instances[j].origin_key
        else
            part.ref_des;
        const top_level = std.mem.indexOfScalar(u8, part.ref_des, '/') == null;
        const pi = prep.idx_of.get(ref) orelse
            (if (top_level) origin_idx.get(key) else null) orelse continue;
        try members.append(arena, pi);
        try xs.append(arena, part.x);
        try ys.append(arena, part.y);
        try rots.append(arena, part.rot);
    }
    if (members.items.len == 0) return null;
    // Measure the macro's keepout extents under the *parent's* box params, not
    // whatever the nested solve left in the globals.
    g_collide_shrink = saved_shrink;
    g_route_gap = saved_gap;
    return finishMacro(members.items, xs.items, ys.items, rots.items, prep.parts, rot_override);
}

/// Penetration-driven separation after the macro re-stamp: a free part
/// overlapping a macro member moves away; two distinct macros overlapping
/// move the later one as a unit (the first stays — stamped order). Free-vs-
/// free pairs are skipped until a push has disturbed the (overlap-free)
/// force result. Pushes are grid-ceiled along the smaller penetration axis.
/// Sweeps cap out; the caller's `anyOverlap` accept-test decides whether
/// the result ships.
fn legalizeComposed(parts: []Part, macro_of: []const ?usize) void {
    var pushed_free = false;
    var sweep: usize = 0;
    while (sweep < 24) : (sweep += 1) {
        var moved = false;
        for (0..parts.len) |i| {
            for (i + 1..parts.len) |j| {
                const ma = macro_of[i];
                const mb = macro_of[j];
                if (ma != null and mb != null and ma.? == mb.?) continue;
                if (ma == null and mb == null and !pushed_free) continue;
                if (separateComposedPair(parts, macro_of, i, j)) {
                    moved = true;
                    if (ma == null or mb == null) pushed_free = true;
                }
            }
        }
        if (!moved) break;
    }
}

/// Resolve one overlapping pair for `legalizeComposed`: push the free side
/// (or the later-stamped macro as a unit) along the smaller-penetration
/// axis, away from the stationary box's centre. True when something moved.
fn separateComposedPair(parts: []Part, macro_of: []const ?usize, i: usize, j: usize) bool {
    const a = &parts[i];
    const b = &parts[j];
    const px = (keepHw(a.*) + keepHw(b.*)) - @abs(keepCx(a.*) - keepCx(b.*));
    const py = (keepHh(a.*) + keepHh(b.*)) - @abs(keepCy(a.*) - keepCy(b.*));
    if (px <= 1e-9 or py <= 1e-9) return false;
    const dx = if (px <= py) ceilToGrid(px) * (if (keepCx(b.*) >= keepCx(a.*)) @as(f64, 1) else -1) else 0;
    const dy = if (px <= py) 0 else ceilToGrid(py) * (if (keepCy(b.*) >= keepCy(a.*)) @as(f64, 1) else -1);
    if (macro_of[j] == null) {
        b.x += dx;
        b.y += dy;
        return true;
    }
    if (macro_of[i] == null) {
        a.x -= dx;
        a.y -= dy;
        return true;
    }
    const mb = macro_of[j].?;
    for (parts, 0..) |*p, k| {
        if (macro_of[k] != null and macro_of[k].? == mb) {
            p.x += dx;
            p.y += dy;
        }
    }
    return true;
}

// ── Rough hierarchical seed (`Params.rough`) ─────────────────────────────────
// The flat force solve interleaves parts across module boundaries to shave
// wirelength, which is exactly what makes its output annoying to hand-finish.
// The rough seed instead places HIERARCHICALLY: solve each first-level sub-block
// internally (reusing `buildSubMacro`, so a module's own `(placement …)` spec is
// honoured), freeze it as a rigid block, then arrange the *blocks* by connectivity
// on a coarse grid. Every module stays intact and grid-aligned — a legible start a
// human drags to finish, deliberately not metric-optimal. `runPlacement` calls it
// ahead of the force path when `params.rough`; it returns false (caller falls back
// to force) when the design has fewer than two clusters to arrange.

const ROUGH_ITERS: usize = 240;
/// Connectivity spring gain per shared net (linear; equilibrium ≈ box contact).
const ROUGH_K_ATT: f64 = 0.02;
/// Box-overlap repulsion gain (keeps blocks from sitting on top of each other).
const ROUGH_K_REP: f64 = 0.5;
/// Weak pull toward the centroid so disconnected blocks don't drift away.
const ROUGH_K_CENTER: f64 = 0.01;
const ROUGH_STEP: f64 = 0.5;
const ROUGH_MAX_STEP_MM: f64 = 4.0;
/// Breathing room left between blocks during the relaxation (mm).
const ROUGH_BLOCK_GAP_MM: f64 = 2.0;
/// Coarse grid the block centres snap to — legible + easy to grab (5× base grid).
const ROUGH_ORIGIN_GRID_MM: f64 = 1.0;
/// Courtyard spacing forced on a FLAT rough seed so the compaction pass spreads the
/// passives radially around the hub (in the direction of each part's pad) instead of
/// collapsing them into a block off to one side. Tuned on lmk05318b-clock.
const ROUGH_DECLUMP_GAP_MM: f64 = 3.0;

/// Wrap a single free top-level part as its own one-member rigid block, so the
/// arranger places it by connectivity and the legalizer keeps it clear.
fn singletonMacro(arena: std.mem.Allocator, parts: []const Part, pi: usize) std.mem.Allocator.Error!Macro {
    const members = try arena.alloc(usize, 1);
    members[0] = pi;
    const xs = try arena.alloc(f64, 1);
    xs[0] = parts[pi].x;
    const ys = try arena.alloc(f64, 1);
    ys[0] = parts[pi].y;
    const rots = try arena.alloc(f64, 1);
    rots[0] = parts[pi].rot;
    return finishMacro(members, xs, ys, rots, parts, null);
}

fn runRough(
    arena: std.mem.Allocator,
    parts: []Part,
    prep: *Prepared,
    nets: []const FlatNet,
    params: Params,
) std.mem.Allocator.Error!bool {
    // Nested per-module solves trash the thread's solve state and would stream
    // partial frames to a watcher — bracket the build phase with a snapshot.
    const saved = SolveState.snapshot();
    g_progress = null;
    var child_params = params;
    child_params.rough = false; // nested module solves place normally…
    child_params.fast = true; // …with the bare force relax — a quick seed, N modules deep
    var macros: std.ArrayListUnmanaged(Macro) = .empty;
    for (prep.block.sub_blocks) |sub| {
        if (try buildSubMacro(arena, sub, null, prep, prep.project_dir, child_params)) |m| {
            try macros.append(arena, m);
        }
    }
    saved.restore();

    // No sub-block macros means a FLAT design/module (or a grouped-refdes board
    // whose members didn't map): there are no modules to cluster, so hierarchical
    // arrangement adds nothing. Bail to the caller, which runs the pad-aware force
    // relax instead (parts settle toward the hub pad they connect to, not clumped).
    if (macros.items.len < 2) return false;

    const macro_of = try arena.alloc(?usize, parts.len);
    @memset(macro_of, null);
    for (macros.items, 0..) |m, mi| {
        for (m.members) |pi| macro_of[pi] = mi;
    }
    // Every top-level part with no module home becomes its own block, so it lands
    // by connectivity (a bare bypass cap beside the IC module it wires to).
    for (0..parts.len) |pi| {
        if (macro_of[pi] != null) continue;
        macro_of[pi] = macros.items.len;
        try macros.append(arena, try singletonMacro(arena, parts, pi));
    }

    const origins = try arrangeMacros(arena, macros.items, macro_of, nets, &prep.idx_of);
    stampMacros(parts, macros.items, origins);
    // Final hard de-overlap: push whole blocks apart on grid (same legalizer the
    // spec-composition path uses). A residual touch is acceptable for a rough seed.
    legalizeComposed(parts, macro_of);
    return true;
}

/// Drop each rigid block at its arranged origin: every member lands at
/// `origin + (lx,ly)` with the block's rotation, so the module's internal layout
/// is preserved exactly and only the block as a whole has moved.
fn stampMacros(parts: []Part, macros: []const Macro, origins: []const [2]f64) void {
    for (macros, 0..) |m, mi| {
        for (m.members, 0..) |pi, k| {
            parts[pi].x = origins[mi][0] + m.lx[k];
            parts[pi].y = origins[mi][1] + m.ly[k];
            parts[pi].rot = m.rots[k];
        }
    }
}

/// Keepout-aware world bounding box `{minx,miny,maxx,maxy}` of a set of member
/// parts — used to check two modules occupy disjoint regions after a rough seed.
fn membersBox(parts: []const Part, members: []const usize) [4]f64 {
    var b = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (members) |pi| {
        const kb = keepBoxOf(parts[pi]);
        b[0] = @min(b[0], parts[pi].x + kb.cxo - kb.hw);
        b[1] = @min(b[1], parts[pi].y + kb.cyo - kb.hh);
        b[2] = @max(b[2], parts[pi].x + kb.cxo + kb.hw);
        b[3] = @max(b[3], parts[pi].y + kb.cyo + kb.hh);
    }
    return b;
}

// ── Pad-anchored flat-module seed (`packPadAnchored`) ────────────────────────
// For a flat module (IC + passives, no sub-blocks) the natural hand-layout puts
// each passive on the SIDE of the IC where the pad it serves lives, hugging the
// edge. This rings the anchor IC's perimeter that way: each part is docked on the
// side of the IC pad it connects to, GND ignored for side-selection — a bypass cap
// follows its power (VDD) pad, a pull-up/down resistor follows its signal pad, any
// other part its first non-ground pad. Parts pack tight against the edge; parts
// touching the IC only through ground (or not at all) drop into a band below.
//
// An author `(rough …)` form steers two things: `(anchor "REF")` overrides the
// largest-hub anchor pick, and the `(group …)` priority tiers set how CLOSE each
// part packs — tier 0 takes the inner lane against the IC, later tiers fan out
// (radial distance = priority). The side still comes from connectivity, so the
// groups reorder lanes without breaking the pad-following rule.

/// Uppercased ref-des prefix letter of a part's leaf ref (after the last `/`),
/// e.g. `'C'` for "pwr/C3". 0 when empty. Distinguishes cap (C) from resistor (R).
fn leafRefPrefix(ref: []const u8) u8 {
    const leaf = if (std.mem.lastIndexOfScalar(u8, ref, '/')) |s| ref[s + 1 ..] else ref;
    return if (leaf.len > 0) std.ascii.toUpper(leaf[0]) else 0;
}

/// True when part index `pi` has a pin on `net`.
fn netHasPart(net: FlatNet, pi: usize, idx_of: *std.StringHashMap(usize)) bool {
    for (net.pins) |pr| {
        if ((idx_of.get(pr.ref_des) orelse continue) == pi) return true;
    }
    return false;
}

/// The hub's physical pad id on `net` (for pin-role lookup), or "" if absent.
fn hubPinOnNet(net: FlatNet, hi: usize, idx_of: *std.StringHashMap(usize)) []const u8 {
    for (net.pins) |pr| {
        if ((idx_of.get(pr.ref_des) orelse continue) == hi) return pr.pin;
    }
    return "";
}

/// Footprint-local centres of every hub pad on `net` — a rail lands on many, a
/// signal on one, so the caller can both rank nets and spread parts across pads.
fn hubPadsOnNet(arena: std.mem.Allocator, hub: Part, hi: usize, net: FlatNet, idx_of: *std.StringHashMap(usize)) std.mem.Allocator.Error![][2]f64 {
    var out: std.ArrayListUnmanaged([2]f64) = .empty;
    for (net.pins) |pr| {
        if ((idx_of.get(pr.ref_des) orelse continue) != hi) continue;
        const pad = padLocal(hub, pr.pin);
        if (pad.w == 0 and pad.h == 0) continue;
        try out.append(arena, .{ pad.x, pad.y });
    }
    return out.toOwnedSlice(arena);
}

/// Footprint-local centre of the anchor hub's pad named `tok` (a `(decouples "IC"
/// PIN)` binding or a generator's `value@PAD#replica` origin pad), but ONLY when
/// that pad lies on one of part `pi`'s own nets. The net scoping rejects a
/// cross-hub binding: a `(decouples "U2" 8)` cap names U2's pad 8, and the anchor
/// U1 may carry an unrelated pad 8 on a different net — without the on-net check it
/// would mis-resolve to U1's pad 8. Null when `tok` is empty or names no on-net hub pad.
fn servedPadLocal(parts: []const Part, hi: usize, pi: usize, tok: []const u8, nets: []const FlatNet, idx_of: *std.StringHashMap(usize)) ?[2]f64 {
    if (tok.len == 0) return null;
    for (nets) |net| {
        if (!netHasPart(net, pi, idx_of)) continue;
        for (net.pins) |pr| {
            if ((idx_of.get(pr.ref_des) orelse continue) != hi) continue;
            if (!std.mem.eql(u8, pr.pin, tok)) continue;
            const pad = padLocal(parts[hi], pr.pin);
            if (pad.w != 0 or pad.h != 0) return .{ pad.x, pad.y };
        }
    }
    return null;
}

/// True when a part's flattened ref-des or module-local origin name matches an
/// author token from a `(rough …)` anchor/group — exact or by leaf segment, the
/// same lenient match `(module-policy …)` uses so a token written in a module
/// file still binds after the part renumbers (e.g. U1→U17) in a parent board.
fn roughNameMatch(ref: []const u8, origin: []const u8, want: []const u8) bool {
    if (want.len == 0) return false;
    if (ref.len > 0 and (std.mem.eql(u8, ref, want) or std.mem.eql(u8, shortName(ref), want))) return true;
    if (origin.len > 0 and (std.mem.eql(u8, origin, want) or std.mem.eql(u8, shortName(origin), want))) return true;
    return false;
}

/// IC edge → first ring of parts (mm) and the spacing between parts along an edge.
const PAD_ANCHOR_IC_GAP_MM: f64 = 0.5;
const PAD_ANCHOR_PART_GAP_MM: f64 = 0.4;
/// Target lanes per IC side: a crowded side spreads ALONG the edge into about this
/// many lanes (sized to the part count) instead of stacking many lanes outward, so
/// even low-priority parts stay close to the IC radially. Smaller = tighter ring.
const ROUGH_PACK_LANES: f64 = 2;
/// `SidePart.along` sentinel meaning "no preferred tangential spot — pack me
/// sequentially from the lane start". `dockSidesByTier` clamps a part to
/// `max(along, cursor+half)`, so a literal 0 would pin every such part to x≥0
/// (a dense pile); a large-negative value lets them spread across the whole lane.
const ALONG_PACK_SEQ: f64 = -1e9;

/// Rough-output ring tightness, set per solve in `packPadAnchored` and consulted
/// by `dockSidesByTier` (so the value need not thread through `refineSidesByPull`).
/// The rough OUTPUT packs the ring flush against the IC — gaps at the legalize
/// floor (`FINAL_CLEAR`), the way a hand layout tucks decoupling parts right at
/// the pins (measured: median part→IC gap 1–5 mm → ~0.2 mm, loops ≈40 % shorter,
/// side assignment unchanged). The force SEED keeps the looser default so its
/// tuned solve is unchanged. Defaults equal the loose constants, so any path that
/// doesn't set them behaves as before.
threadlocal var g_rough_ic_gap: f64 = PAD_ANCHOR_IC_GAP_MM;
threadlocal var g_rough_part_gap: f64 = PAD_ANCHOR_PART_GAP_MM;

/// One part docked to a side of the anchor IC in `packPadAnchored`: its index,
/// priority `tier` (lower = tighter to the IC), desired coordinate ALONG the edge
/// (its IC pad's position), half-extent along the edge, and depth out from it.
const SidePart = struct { i: usize, tier: usize, along: f64, half_along: f64, depth: f64 };

/// Dock each side's parts into lanes hugging the IC edge, ordered by (tier, along):
/// the (rough …) priority groups are the FILL ORDER — the highest-priority parts
/// take the inner lane first and lower tiers spill outward only when the inner
/// lanes fill, so nothing is pushed far unless the side is genuinely crowded.
/// Lane along-extent is sized to the part count (≈ROUGH_PACK_LANES lanes) so a
/// busy side spreads tangentially rather than stacking many lanes radially; each
/// lane is flush at its inner radius and the next clears only the deepest part in
/// THIS lane (a per-lane pitch — one big part widens its own lane, not the side).
fn dockSidesByTier(parts: []Part, sides: *[4]std.ArrayListUnmanaged(SidePart), hkb: KeepBox) void {
    const lessTierAlong = struct {
        fn lt(_: void, a: SidePart, b: SidePart) bool {
            if (a.tier != b.tier) return a.tier < b.tier;
            return a.along < b.along;
        }
    }.lt;
    // Ring tightness (see `g_rough_ic_gap`): the rough output packs flush to the
    // IC; the force seed keeps the looser tuned default.
    const ic_gap = g_rough_ic_gap;
    const part_gap = g_rough_part_gap;
    for (sides, 0..) |*list, s| {
        if (list.items.len == 0) continue;
        std.mem.sort(SidePart, list.items, {}, lessTierAlong);
        const vert = s < 2; // 0 left / 1 right run vertically; 2 top / 3 bottom horizontally
        const span = if (vert) hkb.hh else hkb.hw; // how far the IC edge reaches each way
        const base = if (vert) hkb.hw else hkb.hh; // IC half-extent out toward the parts
        // Lane length = enough to spread the side's parts over ~`lanes` lanes,
        // but never shorter than the IC edge. A crowded side gets longer lanes
        // (tangential spread) instead of more lanes (radial stacking).
        var total: f64 = 0;
        for (list.items) |a| total += 2 * a.half_along + part_gap;
        const limit = @max(span, total / (2 * ROUGH_PACK_LANES));
        var lane_inner: f64 = base + ic_gap;
        var lane_maxd: f64 = 0;
        var cursor: f64 = -limit;
        for (list.items) |a| {
            var pos = @max(a.along, cursor + a.half_along);
            // Wrap to the next lane out only when this one runs past its length.
            if (pos + a.half_along > limit and cursor > -limit) {
                lane_inner += 2 * lane_maxd + part_gap;
                lane_maxd = 0;
                cursor = -limit;
                pos = @max(a.along, cursor + a.half_along);
            }
            cursor = pos + a.half_along + part_gap;
            lane_maxd = @max(lane_maxd, a.depth);
            const off = lane_inner + a.depth;
            switch (s) {
                0 => {
                    parts[a.i].x = gridRound(-off);
                    parts[a.i].y = gridRound(pos);
                },
                1 => {
                    parts[a.i].x = gridRound(off);
                    parts[a.i].y = gridRound(pos);
                },
                2 => {
                    parts[a.i].y = gridRound(-off);
                    parts[a.i].x = gridRound(pos);
                },
                else => {
                    parts[a.i].y = gridRound(off);
                    parts[a.i].x = gridRound(pos);
                },
            }
        }
    }
}

/// A net hitting ≥ this many anchor-hub pads is a power/ground rail, not a local
/// signal link; a net joining ≥ this many parts is a bus. Either disqualifies the
/// net from forming a cluster edge (they'd merge every part into one blob).
const CLUSTER_MAX_RAIL_PADS: usize = 3;
const CLUSTER_MAX_NET_PARTS: usize = 5;

/// Connected components of the NON-hub parts, joined by "local" nets (not ground,
/// not a wide rail, not a bus) — i.e. the signal subsystems: a crystal + its
/// coupling caps + term resistor, a series R + its cap. For each component we also
/// accumulate the centroid of the IC *signal* pads its members touch — the point
/// the subsystem attaches to the anchor IC — so a member with no IC pad of its own
/// (a TCXO wired only through its caps; a series R between two local nets) can dock
/// beside the rest of its cluster instead of scattering to the rail or the
/// leftover row. That scattering was the dominant source of ratsnest crossings.
const ClusterInfo = struct {
    root: []usize, // component id per part (flattened union-find)
    size: []usize, // non-hub members per root
    attach: [][2]f64, // summed IC-signal-pad local centre per root
    attach_n: []usize, // count, to average the attach centroid

    fn clustered(self: ClusterInfo, pi: usize) bool {
        return self.size[self.root[pi]] >= 2;
    }
    /// Average IC-signal-pad local centre of `pi`'s cluster, or null if its
    /// subsystem touches the IC only through rails/ground (no signal anchor).
    fn attachOf(self: ClusterInfo, pi: usize) ?[2]f64 {
        const r = self.root[pi];
        if (self.attach_n[r] == 0) return null;
        const n: f64 = @floatFromInt(self.attach_n[r]);
        return .{ self.attach[r][0] / n, self.attach[r][1] / n };
    }
};

fn ufFind(p: []usize, x0: usize) usize {
    var x = x0;
    while (p[x] != x) {
        p[x] = p[p[x]]; // path halving
        x = p[x];
    }
    return x;
}

fn buildClusters(
    arena: std.mem.Allocator,
    parts: []const Part,
    hi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
) std.mem.Allocator.Error!ClusterInfo {
    const n = parts.len;
    const p = try arena.alloc(usize, n);
    for (p, 0..) |*e, i| e.* = i;
    // Union non-hub parts that share a local net.
    for (nets) |net| {
        if (pin_roles.isGroundFn(shortName(net.name))) continue;
        var hubpads: usize = 0;
        var members: usize = 0;
        var first: ?usize = null;
        for (net.pins) |pr| {
            const idx = idx_of.get(pr.ref_des) orelse continue;
            if (idx == hi) {
                hubpads += 1;
            } else {
                members += 1;
                if (first == null) first = idx;
            }
        }
        if (hubpads >= CLUSTER_MAX_RAIL_PADS or members >= CLUSTER_MAX_NET_PARTS) continue;
        const f = first orelse continue;
        for (net.pins) |pr| {
            const idx = idx_of.get(pr.ref_des) orelse continue;
            if (idx == hi or idx == f) continue;
            p[ufFind(p, idx)] = ufFind(p, f);
        }
    }
    var size = try arena.alloc(usize, n);
    @memset(size, 0);
    for (parts, 0..) |part, i| {
        if (i == hi or part.kind == .hub) continue;
        size[ufFind(p, i)] += 1;
    }
    // Accumulate each cluster's IC-signal-pad attach centroid.
    var attach = try arena.alloc([2]f64, n);
    @memset(attach, .{ 0, 0 });
    var attach_n = try arena.alloc(usize, n);
    @memset(attach_n, 0);
    for (nets) |net| {
        if (pin_roles.isGroundFn(shortName(net.name))) continue;
        const pads = try hubPadsOnNet(arena, parts[hi], hi, net, idx_of);
        if (pads.len == 0 or pads.len > 2) continue; // need a single-ish IC signal pad
        for (net.pins) |pr| {
            const idx = idx_of.get(pr.ref_des) orelse continue;
            if (idx == hi or parts[idx].kind == .hub) continue;
            const r = ufFind(p, idx);
            attach[r][0] += pads[0][0];
            attach[r][1] += pads[0][1];
            attach_n[r] += 1;
        }
    }
    const root = try arena.alloc(usize, n);
    for (root, 0..) |*e, i| e.* = ufFind(p, i);
    return .{ .root = root, .size = size, .attach = attach, .attach_n = attach_n };
}

/// Choose each non-hub part's anchor pad and bucket it onto a side of the IC.
/// A decoupling CAP with a served-pad binding (`served_pad`, from `(decouples "IC"
/// PIN)` / a per-pin generator) docks on the edge of THAT pad — so the bypass caps
/// distribute around the package next to the pins they serve, like a hand layout;
/// an unbound cap spreads across its rail's pads (round-robin). A signal part sits
/// by its own IC pad; a cluster orphan (no IC signal pad) docks at its subsystem's
/// attach centroid so connected parts stay together; anything with no IC connection
/// drops to `leftover`. Pad offset → side + along-edge coordinate.
fn assignSides(
    arena: std.mem.Allocator,
    parts: []Part,
    hi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
    roles: pin_roles.PartRoles,
    ci: ClusterInfo,
    tier_of: []const usize,
    sig_side: []u8,
    served_pad: []const ?[2]f64,
    sides: *[4]std.ArrayListUnmanaged(SidePart),
    leftover: *std.ArrayListUnmanaged(usize),
) std.mem.Allocator.Error!void {
    var net_next: std.AutoHashMapUnmanaged(usize, usize) = .empty;
    for (parts, 0..) |p, pi| {
        if (pi == hi) continue; // only the anchor hub is fixed; other hubs (a TCXO) ring it too
        // Classify this part's IC nets into the most-signal-like (fewest hub pads,
        // ≤2) and the widest rail (most hub pads).
        var sig: ?[2]f64 = null;
        var sig_cnt: usize = 0;
        var rail: ?usize = null;
        var rail_cnt: usize = 0;
        // Cohesion anchor: the pad of a concentrated (≤2 hub-pad) NON-ground,
        // NON-power signal net — the inductor's switch node, the crystal's
        // XIN/XOUT, a reset pin. Tracked separately from `sig` (which the role
        // ground-test can miss, letting the GND pad win the fewest-pad pick) and
        // ground-excluded *by name*, so a pure VDD/GND bypass cap has no anchor
        // and casts no vote in `cohereGroups`.
        var anchor: ?[2]f64 = null;
        var anchor_cnt: usize = 0;
        for (nets, 0..) |net, ni| {
            if (!netHasPart(net, pi, idx_of)) continue;
            if (padOnNet(parts[hi], hi, net, idx_of).w == 0) continue; // hub not on net
            // Cohesion anchor (additive — does NOT affect sig/rail bucketing): a
            // ≤2-pad signal net that is ground by neither role NOR name. The name
            // test catches a hub GND pad the role data misses, so a pure VDD/GND
            // bypass cap gets no anchor. A power rail lands on many pads (cnt>2),
            // so it's excluded too. Checked before the role `continue` below so it
            // still runs on nets that pass the (unreliable) role ground-test.
            var cnt: usize = 0;
            for (net.pins) |pr| {
                if ((idx_of.get(pr.ref_des) orelse continue) == hi) cnt += 1;
            }
            if (cnt <= 2 and !pin_roles.isGroundFn(shortName(net.name)) and
                roles.classOf(hubPinOnNet(net, hi, idx_of)) != .ground and
                (anchor == null or cnt < anchor_cnt))
            {
                const apads = try hubPadsOnNet(arena, parts[hi], hi, net, idx_of);
                if (apads.len > 0) {
                    anchor = apads[0];
                    anchor_cnt = cnt;
                }
            }
            if (roles.classOf(hubPinOnNet(net, hi, idx_of)) == .ground) continue;
            if (cnt <= 2 and (sig == null or cnt < sig_cnt)) {
                const pads = try hubPadsOnNet(arena, parts[hi], hi, net, idx_of);
                if (pads.len > 0) {
                    sig = pads[0];
                    sig_cnt = cnt;
                }
            }
            if (rail == null or cnt > rail_cnt) {
                rail = ni;
                rail_cnt = cnt;
            }
        }
        // Record the side of this part's anchor signal pad, if any — the
        // directional vote `cohereGroups` tallies per schematic group. A pure
        // wide-rail bypass cap has no anchor (255) and casts no vote, which is
        // what keeps such groups distributed instead of cohered.
        if (anchor) |a| {
            const sv = @abs(a[0]) >= @abs(a[1]);
            sig_side[pi] = if (sv) (if (a[0] < 0) @as(u8, 0) else 1) else (if (a[1] < 0) @as(u8, 2) else 3);
        }
        const is_cap = leafRefPrefix(p.ref_des) == 'C';
        // Decide the anchor pad: a decoupling cap with a served-pad binding docks on
        // THAT pad (distributing the bypass caps to the pins they serve, like a hand
        // layout); else rail round-robin for an unbound cap; else the part's own
        // signal pad; else its cluster's attach; else leftover.
        var pad: [2]f64 = undefined;
        if (is_cap and served_pad[pi] != null) {
            pad = served_pad[pi].?;
        } else if (is_cap and rail != null and rail_cnt >= CLUSTER_MAX_RAIL_PADS) {
            pad = (try rrPad(arena, parts, hi, nets, idx_of, &net_next, rail.?)) orelse {
                try leftover.append(arena, pi);
                continue;
            };
        } else if (sig) |s| {
            pad = s;
        } else if (ci.clustered(pi) and ci.attachOf(pi) != null) {
            pad = ci.attachOf(pi).?;
        } else if (rail) |rn| {
            pad = (try rrPad(arena, parts, hi, nets, idx_of, &net_next, rn)) orelse {
                try leftover.append(arena, pi);
                continue;
            };
        } else {
            try leftover.append(arena, pi);
            continue;
        }
        const vert = @abs(pad[0]) >= @abs(pad[1]);
        const s: usize = if (vert) (if (pad[0] < 0) 0 else 1) else (if (pad[1] < 0) 2 else 3);
        parts[pi].rot = if (vert) 0 else 90;
        const pkb = keepBoxOf(parts[pi]);
        try sides[s].append(arena, .{
            .i = pi,
            .tier = tier_of[pi],
            .along = if (vert) pad[1] else pad[0],
            .half_along = if (vert) pkb.hh else pkb.hw,
            .depth = if (vert) pkb.hw else pkb.hh,
        });
    }
}

/// Cohere each authored schematic `(group …)` onto a single IC side — the way a
/// hand layout keeps a functional subsystem (VREG, crystal, reset) together on one
/// edge while spreading the general per-pin decoupling around the package. The
/// target side is the dominant vote among the group's *directionally-anchored*
/// members: a part with a concentrated ≤2-pad IC signal pad (the inductor's switch
/// node, the crystal's XIN/XOUT, the reset pin) votes that pad's side via
/// `sig_side`. A group of pure wide-rail bypass caps casts no vote and is left
/// distributed (each cap keeps its per-pad side from `assignSides`). On a clear,
/// tie-free majority every member is re-bucketed onto that side; `cohere_side`
/// records it so the want-side freeze keeps the crossing polish from scattering
/// the group again. Runs before `dockSidesByTier`, so cohered members lane-pack
/// together on their shared side.
fn cohereGroups(
    arena: std.mem.Allocator,
    parts: []Part,
    hi: usize,
    groups: []const env.Group,
    instances: []const export_kicad.FlatInstance,
    tier_of: []const usize,
    sig_side: []const u8,
    cohere_side: []u8,
    sides: *[4]std.ArrayListUnmanaged(SidePart),
) std.mem.Allocator.Error!void {
    for (groups) |g| {
        var members: std.ArrayListUnmanaged(usize) = .empty;
        var votes = [_]usize{ 0, 0, 0, 0 };
        for (g.members) |want| {
            for (parts, 0..) |p, pi| {
                if (pi == hi) continue; // the anchor IC is fixed; never re-sided
                const origin = if (pi < instances.len) instances[pi].origin_key else "";
                if (!roughNameMatch(p.ref_des, origin, want)) continue;
                try members.append(arena, pi);
                if (sig_side[pi] < 4) votes[sig_side[pi]] += 1;
            }
        }
        if (members.items.len < 2) continue;
        // Dominant anchored side: strictly most-voted, ≥1 vote, no tie. A group
        // with no anchored member (pure bypass) scores 0 everywhere → left spread.
        var dom: usize = 255;
        var best: usize = 0;
        var tie = false;
        for (votes, 0..) |v, s| {
            if (v > best) {
                best = v;
                dom = s;
                tie = false;
            } else if (v == best and v > 0) tie = true;
        }
        if (best == 0 or tie) continue;
        // Re-bucket every member onto `dom`, recomputing its lane geometry for the
        // side's orientation (vertical sides run at rot 0, horizontal at rot 90).
        const vert = dom < 2;
        for (members.items) |pi| {
            // Only re-side members already docked to a side; a ground-only member
            // sitting in the leftover row stays there (cohesion is a ring concern).
            var found = false;
            for (sides) |*lst| {
                var k: usize = 0;
                while (k < lst.items.len) : (k += 1) {
                    if (lst.items[k].i == pi) {
                        _ = lst.orderedRemove(k);
                        found = true;
                        break;
                    }
                }
                if (found) break;
            }
            if (!found) continue;
            cohere_side[pi] = @intCast(dom);
            parts[pi].rot = if (vert) 0 else 90;
            const pkb = keepBoxOf(parts[pi]);
            try sides[dom].append(arena, .{
                .i = pi,
                .tier = tier_of[pi],
                .along = ALONG_PACK_SEQ, // spread across the shared lane, not piled at x≥0
                .half_along = if (vert) pkb.hh else pkb.hw,
                .depth = if (vert) pkb.hw else pkb.hh,
            });
        }
    }
}

/// Round-robin the next hub pad on `net` so same-rail parts spread across the
/// rail's many IC pads instead of piling on one. Null when the hub has no pad.
fn rrPad(
    arena: std.mem.Allocator,
    parts: []const Part,
    hi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
    net_next: *std.AutoHashMapUnmanaged(usize, usize),
    net: usize,
) std.mem.Allocator.Error!?[2]f64 {
    const pads = try hubPadsOnNet(arena, parts[hi], hi, nets[net], idx_of);
    if (pads.len == 0) return null;
    const gop = try net_next.getOrPut(arena, net);
    const k = if (gop.found_existing) gop.value_ptr.* else 0;
    gop.value_ptr.* = k + 1;
    return pads[k % pads.len];
}

/// Refinement passes and pull weights for `refineSidesByPull`. A dedicated IC
/// signal pad is the firmest anchor; a connected neighbour part next; a wide
/// rail barely tugs (a decoupling cap must not be yanked to one arbitrary VDD
/// pad). Signal + neighbour pulls are *directional* — a part with neither stays
/// where the initial dock put it (the rail tug alone can't pick a side).
const ROUGH_RESIDE_PASSES: usize = 4;
const RESIDE_W_SIG: f64 = 2.0;
const RESIDE_W_NBR: f64 = 1.5;
const RESIDE_W_RAIL: f64 = 0.3;

/// A part's refinement pull: the weighted centroid of its real connections plus
/// `dir` — whether any of that pull is *directional* (a signal pad or a neighbour,
/// vs. a centred rail tug that can't choose a side). See `sidePullTarget`.
const PullTarget = struct { x: f64, y: f64, dir: bool };

/// Weighted centroid of part `pi`'s real connections for side refinement: an IC
/// signal pad pulls hardest, a connected neighbour next, a wide rail only weakly
/// toward its pad-centroid (a decoupling cap must not be yanked to one arbitrary
/// VDD pad). Ground and wide buses are excluded. `dir` is false when the only pull
/// is the centred rail — the caller then leaves the part on its seeded side.
fn sidePullTarget(
    arena: std.mem.Allocator,
    parts: []const Part,
    hi: usize,
    pi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
) std.mem.Allocator.Error!PullTarget {
    var sx: f64 = 0;
    var sy: f64 = 0;
    var sw: f64 = 0;
    var has_dir = false;
    for (nets) |net| {
        if (!netHasPart(net, pi, idx_of)) continue;
        if (pin_roles.isGroundFn(shortName(net.name))) continue;
        var hubpads: usize = 0;
        var members: usize = 0;
        for (net.pins) |pr| {
            const idx = idx_of.get(pr.ref_des) orelse continue;
            if (idx == hi) hubpads += 1 else members += 1;
        }
        if (hubpads > 0) {
            const pads = try hubPadsOnNet(arena, parts[hi], hi, net, idx_of);
            if (hubpads <= 2) {
                for (pads) |pd| {
                    sx += pd[0] * RESIDE_W_SIG;
                    sy += pd[1] * RESIDE_W_SIG;
                }
                sw += RESIDE_W_SIG * @as(f64, @floatFromInt(pads.len));
                if (pads.len > 0) has_dir = true;
            } else if (pads.len > 0) {
                // Wide rail: pull weakly toward the rail pads' centroid.
                var cx: f64 = 0;
                var cy: f64 = 0;
                for (pads) |pd| {
                    cx += pd[0];
                    cy += pd[1];
                }
                const np: f64 = @floatFromInt(pads.len);
                sx += (cx / np) * RESIDE_W_RAIL;
                sy += (cy / np) * RESIDE_W_RAIL;
                sw += RESIDE_W_RAIL;
            }
        }
        // Neighbour pull — only on a local net (not a wide rail, not a bus),
        // matching the clustering rules so VDD/GND don't drag every part toward
        // every other.
        if (hubpads >= CLUSTER_MAX_RAIL_PADS or members > CLUSTER_MAX_NET_PARTS) continue;
        for (net.pins) |pr| {
            const idx = idx_of.get(pr.ref_des) orelse continue;
            if (idx == hi or idx == pi) continue;
            sx += parts[idx].x * RESIDE_W_NBR;
            sy += parts[idx].y * RESIDE_W_NBR;
            sw += RESIDE_W_NBR;
            has_dir = true;
        }
    }
    if (!has_dir or sw <= 1e-6) return .{ .x = parts[pi].x, .y = parts[pi].y, .dir = false };
    return .{ .x = sx / sw, .y = sy / sw, .dir = true };
}

/// Connectivity-aware side refinement. `assignSides` buckets each part by ONE
/// chosen IC pad, blind to where the part's *other* ends sit — so a series R
/// whose far end is a connector on the opposite edge, or a cap that should hug a
/// neighbour, lands on the wrong side and its airwire crosses the IC. Once the
/// first dock has positioned everyone, this recomputes each ringed part's
/// preferred side from the weighted centroid of its real connections (IC pads +
/// neighbour centres; ground and wide buses excluded) and re-docks, repeating
/// until no part changes side (capped at `ROUGH_RESIDE_PASSES`). Parts with no
/// directional pull (pure VDD/GND decoupling caps) keep their seeded side, so the
/// even rail spread from `rrPad` survives.
fn refineSidesByPull(
    arena: std.mem.Allocator,
    parts: []Part,
    hi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
    tier_of: []const usize,
    cohere_side: []const u8,
    sides: *[4]std.ArrayListUnmanaged(SidePart),
    hkb: KeepBox,
) std.mem.Allocator.Error!void {
    // The ringed parts (everything currently docked to a side; leftover
    // ground-only parts stay put) and each one's current side, seeded from the
    // initial buckets so we can detect convergence.
    var ring: std.ArrayListUnmanaged(usize) = .empty;
    const cur_side = try arena.alloc(u8, parts.len);
    @memset(cur_side, 255);
    for (sides, 0..) |list, s| {
        for (list.items) |sp| {
            try ring.append(arena, sp.i);
            cur_side[sp.i] = @intCast(s);
        }
    }
    if (ring.items.len == 0) return;

    var pass: usize = 0;
    while (pass < ROUGH_RESIDE_PASSES) : (pass += 1) {
        var moved = false;
        for (sides) |*list| list.clearRetainingCapacity();
        for (ring.items) |pi| {
            if (pi == hi) continue;
            // Target the pull centroid when it points somewhere; a part with no
            // directional pull keeps its current spot (→ same side, same height).
            const t = try sidePullTarget(arena, parts, hi, pi, nets, idx_of);
            var vert = @abs(t.x) >= @abs(t.y);
            var s: usize = if (vert) (if (t.x < 0) 0 else 1) else (if (t.y < 0) 2 else 3);
            var along: f64 = if (vert) t.y else t.x;
            // A group-cohered part is pinned to its group's shared side, so the
            // per-part pull can't re-scatter a deliberately-grouped subsystem.
            if (cohere_side[pi] < 4) {
                s = cohere_side[pi];
                vert = s < 2;
                along = ALONG_PACK_SEQ;
            }
            if (cur_side[pi] != s) {
                moved = true;
                cur_side[pi] = @intCast(s);
            }
            parts[pi].rot = if (vert) 0 else 90;
            const pkb = keepBoxOf(parts[pi]);
            try sides[s].append(arena, .{
                .i = pi,
                .tier = tier_of[pi],
                .along = along,
                .half_along = if (vert) pkb.hh else pkb.hw,
                .depth = if (vert) pkb.hw else pkb.hh,
            });
        }
        dockSidesByTier(parts, sides, hkb);
        if (!moved) break; // stable — no part wants a different side
    }
}

fn orient2(p: [2]f64, q: [2]f64, r: [2]f64) f64 {
    return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]);
}
fn ptEq(p: [2]f64, q: [2]f64) bool {
    return @abs(p[0] - q[0]) < 1e-6 and @abs(p[1] - q[1]) < 1e-6;
}
/// Interior crossing of segments a1→a2 and b1→b2 — a shared endpoint (two airwires
/// meeting at the same pad) is not a crossing.
fn segsCross(a1: [2]f64, a2: [2]f64, b1: [2]f64, b2: [2]f64) bool {
    if (ptEq(a1, b1) or ptEq(a1, b2) or ptEq(a2, b1) or ptEq(a2, b2)) return false;
    const d1 = orient2(b1, b2, a1);
    const d2 = orient2(b1, b2, a2);
    const d3 = orient2(a1, a2, b1);
    const d4 = orient2(a1, a2, b2);
    const opp1 = (d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0);
    const opp2 = (d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0);
    return opp1 and opp2;
}

/// Euclidean minimum spanning tree (Prim's) over `pts`, appending its edges as
/// segments to `out`. An MST is planar, so a net never crosses ITSELF — the
/// crossing metric then measures only the inter-net tangle that placement controls.
fn primEdges(arena: std.mem.Allocator, pts: []const [2]f64, out: *std.ArrayListUnmanaged([4]f64)) std.mem.Allocator.Error!void {
    const n = pts.len;
    const intree = try arena.alloc(bool, n);
    @memset(intree, false);
    intree[0] = true;
    var added: usize = 1;
    while (added < n) : (added += 1) {
        var bi: usize = 0;
        var bj: usize = 0;
        var bd: f64 = std.math.inf(f64);
        for (pts, 0..) |a, i| {
            if (!intree[i]) continue;
            for (pts, 0..) |b, j| {
                if (intree[j]) continue;
                const dx = a[0] - b[0];
                const dy = a[1] - b[1];
                const d = dx * dx + dy * dy;
                if (d < bd) {
                    bd = d;
                    bi = i;
                    bj = j;
                }
            }
        }
        intree[bj] = true;
        try out.append(arena, .{ pts[bi][0], pts[bi][1], pts[bj][0], pts[bj][1] });
    }
}

/// Append a decoupling cap's power loop: its power pad → the nearest hub pad on
/// the same (non-ground) net. Mirrors the orange loop the viewer draws, so the
/// crossing metric sees the loops that dominate the rough layout's tangle.
fn appendCapLoop(
    arena: std.mem.Allocator,
    parts: []const Part,
    hi: usize,
    pi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
    out: *std.ArrayListUnmanaged([4]f64),
) std.mem.Allocator.Error!void {
    for (nets) |net| {
        if (!netHasPart(net, pi, idx_of)) continue;
        if (pin_roles.isGroundFn(shortName(net.name))) continue;
        const cap_pad = padOnNet(parts[pi], pi, net, idx_of);
        if (cap_pad.w == 0 and cap_pad.h == 0) continue;
        const pads = try hubPadsOnNet(arena, parts[hi], hi, net, idx_of);
        if (pads.len == 0) continue;
        const cw = worldPadCenter(parts[pi], cap_pad.x, cap_pad.y);
        var best: f64 = std.math.inf(f64);
        var bx: f64 = 0;
        var by: f64 = 0;
        for (pads) |hp| {
            const w = worldPadCenter(parts[hi], hp[0], hp[1]);
            const dx = w[0] - cw[0];
            const dy = w[1] - cw[1];
            const d = dx * dx + dy * dy;
            if (d < best) {
                best = d;
                bx = w[0];
                by = w[1];
            }
        }
        try out.append(arena, .{ cw[0], cw[1], bx, by });
        return; // one loop per cap
    }
}

/// Count airwire crossings of the current placement: a planar per-net MST (ground
/// skipped — it reaches every part, so its crossings are noise) plus each cap's
/// decoupling loop. The objective the swap polish minimizes.
fn crossingMetric(
    arena: std.mem.Allocator,
    parts: []const Part,
    hi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
) std.mem.Allocator.Error!usize {
    var segs: std.ArrayListUnmanaged([4]f64) = .empty;
    for (nets) |net| {
        if (pin_roles.isGroundFn(shortName(net.name))) continue;
        var pts: std.ArrayListUnmanaged([2]f64) = .empty;
        for (net.pins) |pr| {
            const idx = idx_of.get(pr.ref_des) orelse continue;
            const pad = padOnNet(parts[idx], idx, net, idx_of);
            if (pad.w == 0 and pad.h == 0) continue;
            try pts.append(arena, worldPadCenter(parts[idx], pad.x, pad.y));
        }
        if (pts.items.len >= 2) try primEdges(arena, pts.items, &segs);
    }
    for (parts, 0..) |p, pi| {
        if (pi == hi or p.kind == .hub or leafRefPrefix(p.ref_des) != 'C') continue;
        try appendCapLoop(arena, parts, hi, pi, nets, idx_of, &segs);
    }
    var n: usize = 0;
    for (segs.items, 0..) |s, i| {
        for (segs.items[i + 1 ..]) |t| {
            if (segsCross(.{ s[0], s[1] }, .{ s[2], s[3] }, .{ t[0], t[1] }, .{ t[2], t[3] })) n += 1;
        }
    }
    return n;
}

const ROUGH_POLISH_PASSES: usize = 6;
const ROUGH_POLISH_MAX_PARTS: usize = 80; // bound the O(parts²·segs²) search to module sizes

/// Side (0 left, 1 right, 2 top, 3 bottom) of point (x,y) relative to the anchor
/// at (ax,ay) — the same quadrant rule the side bucketing uses.
fn posSide(ax: f64, ay: f64, x: f64, y: f64) u8 {
    const dx = x - ax;
    const dy = y - ay;
    const vert = @abs(dx) >= @abs(dy);
    return if (vert) (if (dx < 0) 0 else 1) else (if (dy < 0) 2 else 3);
}

/// Crossing-reduction polish: repeatedly swap two SAME-footprint-size parts when it
/// lowers the crossing metric (same size ⇒ the swap stays overlap-free, so no
/// re-legalization is needed mid-search). Greedy hill-climb, a few passes; stops
/// early when a pass makes no improvement. `want_side[k]` pins a directionally-wired
/// part to the anchor side `refineSidesByPull` chose for it (255 = unconstrained,
/// e.g. a pure decoupling cap) — a swap that would park a constrained part on the
/// wrong side is rejected, so the crossing search never undoes the correct-side work.
fn polishCrossings(
    arena: std.mem.Allocator,
    parts: []Part,
    hi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
    want_side: []const u8,
) std.mem.Allocator.Error!void {
    const ax = parts[hi].x;
    const ay = parts[hi].y;
    var best = try crossingMetric(arena, parts, hi, nets, idx_of);
    var pass: usize = 0;
    while (best > 0 and pass < ROUGH_POLISH_PASSES) : (pass += 1) {
        var improved = false;
        for (parts, 0..) |_, i| {
            if (i == hi) continue;
            for (i + 1..parts.len) |j| {
                if (j == hi) continue;
                if (@abs(parts[i].hw - parts[j].hw) > 1e-6 or @abs(parts[i].hh - parts[j].hh) > 1e-6) continue;
                // i would move to j's spot and vice versa — skip if that lands a
                // side-constrained part on the wrong side of the anchor.
                if (want_side[i] != 255 and posSide(ax, ay, parts[j].x, parts[j].y) != want_side[i]) continue;
                if (want_side[j] != 255 and posSide(ax, ay, parts[i].x, parts[i].y) != want_side[j]) continue;
                const ip = .{ parts[i].x, parts[i].y, parts[i].rot };
                const jp = .{ parts[j].x, parts[j].y, parts[j].rot };
                parts[i].x = jp[0];
                parts[i].y = jp[1];
                parts[i].rot = jp[2];
                parts[j].x = ip[0];
                parts[j].y = ip[1];
                parts[j].rot = ip[2];
                const c = try crossingMetric(arena, parts, hi, nets, idx_of);
                if (c < best) {
                    best = c;
                    improved = true;
                } else {
                    parts[i].x = ip[0];
                    parts[i].y = ip[1];
                    parts[i].rot = ip[2];
                    parts[j].x = jp[0];
                    parts[j].y = jp[1];
                    parts[j].rot = jp[2];
                }
            }
        }
        if (!improved) break;
    }
}

/// The local centre of a part's "important" pad for IC-facing orientation: its pad
/// on the highest-priority net it shares with the anchor hub — ground excluded,
/// fewest-hub-pads (most signal-like) wins, so a bypass cap picks its power pad
/// over GND and a series/pull resistor picks its signal pad. Null when no
/// non-ground net of the part reaches the hub (nothing to orient toward).
fn importantPadLocal(
    part: Part,
    pi: usize,
    hi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
) ?[2]f64 {
    var best: ?FlatNet = null;
    var best_cnt: usize = std.math.maxInt(usize);
    for (nets) |net| {
        if (!netHasPart(net, pi, idx_of)) continue;
        if (pin_roles.isGroundFn(shortName(net.name))) continue;
        var hubpads: usize = 0;
        for (net.pins) |pr| {
            if ((idx_of.get(pr.ref_des) orelse continue) == hi) hubpads += 1;
        }
        if (hubpads == 0) continue; // the net must reach the IC
        if (hubpads < best_cnt) {
            best_cnt = hubpads;
            best = net;
        }
    }
    const net = best orelse return null;
    const pad = padOnNet(part, pi, net, idx_of);
    if (pad.w == 0 and pad.h == 0) return null;
    return .{ pad.x, pad.y };
}

/// Final rough-seed orientation pass: rotate each 2-pad passive 180° when its
/// important pad (see `importantPadLocal`) faces AWAY from the anchor IC, so the
/// pad that matters sits on the inner (IC-facing) side — a bypass cap's power pad
/// toward the IC power pin (short hot loop), a series/pull resistor's signal pad
/// toward the IC. A 180° flip of a symmetric 2-pad part keeps its bbox, so it can
/// never introduce an overlap; hubs/connectors and odd-pad parts keep their
/// rotation. Runs last, so "inner" is measured from each part's final position.
fn orientPadsToIC(
    parts: []Part,
    hi: usize,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
) void {
    for (parts, 0..) |*p, pi| {
        if (pi == hi or p.kind == .hub or p.pads.len != 2) continue;
        const lp = importantPadLocal(p.*, pi, hi, nets, idx_of) orelse continue;
        const off = rotateLocal(lp[0], lp[1], p.rot);
        // Inward = from the part toward the IC; flip when the pad points outward.
        const inx = parts[hi].x - p.x;
        const iny = parts[hi].y - p.y;
        if (off.x * inx + off.y * iny < 0) p.rot = @mod(p.rot + 180, 360);
    }
}

/// Anchor pick for the pad-anchored ring and for spatial attribution: the hub
/// with the most distinct nets on its pads. A reset button or a power FET can
/// out-measure the MCU on courtyard *area* (which mis-anchored whole modules —
/// w55rp20 once ringed 56 parts around its SW_RESET), but never on
/// connectivity. Area only breaks degree ties, so a two-hub board keeps the
/// physically dominant IC. Returns null when the board has no hub at all.
pub fn pickAnchorHub(parts: []const Part, nets: []const FlatNet) ?usize {
    var best: ?usize = null;
    var best_deg: usize = 0;
    var best_area: f64 = -1;
    for (parts, 0..) |p, i| {
        if (p.kind != .hub) continue;
        var deg: usize = 0;
        for (nets) |net| {
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, p.ref_des)) {
                    deg += 1;
                    break;
                }
            }
        }
        const area = p.hw * p.hh;
        const wins = if (best == null) true else if (deg != best_deg) deg > best_deg else area > best_area;
        if (wins) {
            best = i;
            best_deg = deg;
            best_area = area;
        }
    }
    return best;
}

fn packPadAnchored(
    arena: std.mem.Allocator,
    parts: []Part,
    prep: *Prepared,
    nets: []const FlatNet,
    // Cohere authored `(group …)` subsystems onto one IC edge. Only the explicit
    // `?rough=1` path wants this (a legible, hand-like seed the user reads as the
    // final layout); when `packPadAnchored` merely seeds the force solve, cohesion
    // is left off so the tuned force result is bit-identical to before.
    cohere: bool,
) std.mem.Allocator.Error!bool {
    // Anchor: the author's `(rough (anchor …))` IC when it resolves to a hub,
    // else the most-connected hub (see `pickAnchorHub` — courtyard area alone
    // let a reset button out-anchor the MCU). Matched by ref-des or
    // module-local origin name.
    const rough = prep.block.rough;
    var hi: usize = 0;
    var found = false;
    if (rough.anchor.len > 0) {
        for (parts, 0..) |p, i| {
            if (p.kind != .hub) continue;
            const origin = if (i < prep.instances.len) prep.instances[i].origin_key else "";
            if (roughNameMatch(p.ref_des, origin, rough.anchor)) {
                hi = i;
                found = true;
                break;
            }
        }
    }
    if (!found) {
        if (pickAnchorHub(parts, nets)) |i| {
            hi = i;
            found = true;
        }
    }
    if (!found) return false;

    parts[hi].x = 0;
    parts[hi].y = 0;
    parts[hi].rot = 0;
    const hkb = keepBoxOf(parts[hi]);
    const roles = pin_roles.load(arena, prep.project_dir, prep.instances[hi].component);

    // Rough-output ring tightness: pack flush to the IC on the rough OUTPUT path
    // (`cohere`); the force seed (`cohere=false`) keeps its looser tuned gap so its
    // solve is unchanged. (Corpus A/B vs the starred hand layouts: this roughly
    // halved the median part→IC gap and the decoupling-loop length with the side
    // assignment unchanged — see `g_rough_ic_gap`.)
    g_rough_ic_gap = if (cohere) FINAL_CLEAR else PAD_ANCHOR_IC_GAP_MM;
    g_rough_part_gap = if (cohere) FINAL_CLEAR else PAD_ANCHOR_PART_GAP_MM;

    // Priority tier per part from the `(rough …)` groups: group index = tier
    // (index 0 placed tightest to the anchor). A part in no group gets the last
    // tier (placed outermost); with no groups every part is tier 0, so the
    // tier sort below is a no-op and packing matches the heuristic default.
    const ntiers = rough.groups.len;
    const default_tier = if (ntiers == 0) 0 else ntiers;
    const tier_of = try arena.alloc(usize, parts.len);
    for (tier_of) |*t| t.* = default_tier;
    for (rough.groups, 0..) |g, gi| {
        for (g.members) |want| {
            for (parts, 0..) |p, pi| {
                const origin = if (pi < prep.instances.len) prep.instances[pi].origin_key else "";
                if (roughNameMatch(p.ref_des, origin, want)) tier_of[pi] = gi;
            }
        }
    }

    // One bucket per side (0 left, 1 right, 2 top, 3 bottom) of `SidePart`s; the
    // lane packing (tier order, per-lane pitch) lives in `dockSidesByTier`.
    var sides = [_]std.ArrayListUnmanaged(SidePart){ .empty, .empty, .empty, .empty };
    var leftover: std.ArrayListUnmanaged(usize) = .empty;

    // Cluster connected signal subsystems, then bucket each part onto a side of
    // the IC. Decoupling caps spread across their rail; signal parts sit by their
    // own IC pad; a subsystem's orphan members (a TCXO wired only through its caps,
    // a series R between two local nets) dock at the cluster's attach centroid so
    // connected parts stay together — keeping their airwires short instead of
    // spanning the board, which was the dominant ratsnest-crossing source.
    const ci = try buildClusters(arena, parts, hi, nets, &prep.idx_of);
    const sig_side = try arena.alloc(u8, parts.len);
    @memset(sig_side, 255);
    // Per-cap served decoupling pad (from `(decouples "IC" PIN)` or a per-pin
    // generator key), net-scoped to the anchor hub. Lets `assignSides` dock each
    // bound bypass cap on the edge of the pad it serves — the hand-layout spread —
    // instead of round-robining it. Rough path only (`cohere`): the force seed
    // keeps its round-robin spread so its tuned solve stays bit-identical to before.
    const served_pad = try arena.alloc(?[2]f64, parts.len);
    @memset(served_pad, null);
    if (cohere) {
        for (parts, 0..) |_, pi| {
            if (pi == hi) continue;
            var tok: []const u8 = "";
            if (pi < prep.instances.len) {
                const inst = prep.instances[pi];
                if (inst.decouple_pin.len > 0) {
                    tok = inst.decouple_pin;
                } else if (decouplePinFromOrigin(inst.origin_key)) |p| {
                    tok = p;
                }
            }
            served_pad[pi] = servedPadLocal(parts, hi, pi, tok, nets, &prep.idx_of);
        }
    }
    try assignSides(arena, parts, hi, nets, &prep.idx_of, roles, ci, tier_of, sig_side, served_pad, &sides, &leftover);

    // Cohere each authored `(group …)` onto one IC edge (the side its
    // directionally-anchored members vote for) so a functional subsystem stays
    // together like a hand layout; pure bypass groups stay distributed. Only on
    // the explicit rough path — a force seed stays uncohered (see `cohere`).
    const cohere_side = try arena.alloc(u8, parts.len);
    @memset(cohere_side, 255);
    if (cohere) try cohereGroups(arena, parts, hi, prep.block.groups, prep.instances, tier_of, sig_side, cohere_side, &sides);

    // Lay each side's parts into tier-ordered lanes around the IC.
    dockSidesByTier(parts, &sides, hkb);

    // Ground-only / unconnected parts: a single row below the IC.
    if (leftover.items.len > 0) {
        var x: f64 = -hkb.hw;
        const y = gridRound(hkb.hh + 6);
        for (leftover.items) |pi| {
            const pkb = keepBoxOf(parts[pi]);
            x += pkb.hw;
            parts[pi].x = gridRound(x);
            parts[pi].y = y;
            x += pkb.hw + PAD_ANCHOR_PART_GAP_MM;
        }
    }

    // Connectivity-aware re-side: now that everyone has a position, move parts to
    // the IC side their real neighbours pull toward (the initial dock chose by one
    // IC pad, blind to the part's far ends — the main wrong-side source).
    try refineSidesByPull(arena, parts, hi, nets, &prep.idx_of, tier_of, cohere_side, &sides, hkb);

    // Freeze each directionally-wired part's correct side so the crossing polish
    // can't undo it; a part with no directional pull (a pure decoupling cap) is
    // left unconstrained (255) and stays freely swappable — unless it was
    // group-cohered, in which case its group's side is frozen so the subsystem
    // stays together.
    const want_side = try arena.alloc(u8, parts.len);
    @memset(want_side, 255);
    for (parts, 0..) |_, pi| {
        if (pi == hi) continue;
        if (cohere_side[pi] < 4) {
            want_side[pi] = cohere_side[pi];
            continue;
        }
        const t = try sidePullTarget(arena, parts, hi, pi, nets, &prep.idx_of);
        if (t.dir) want_side[pi] = posSide(parts[hi].x, parts[hi].y, t.x, t.y);
    }

    // Crossing-reduction polish: same-size swaps that lower the airwire-crossing
    // count, on top of the cluster-aware seed (modules only — it's bounded but
    // O(parts²·segments²) per pass). `want_side` keeps it from re-siding parts.
    if (parts.len <= ROUGH_POLISH_MAX_PARTS) try polishCrossings(arena, parts, hi, nets, &prep.idx_of, want_side);

    // Orient each 2-pad passive so its important pad faces the IC (power pad of a
    // bypass cap toward the IC power pin, signal pad of a resistor toward the IC).
    orientPadsToIC(parts, hi, nets, &prep.idx_of);

    legalizeFinal(parts); // resolve any corner / cross-side overlaps
    return true;
}

/// Place rigid blocks by connectivity: a coarse spring relaxation on block centres
/// (springs weighted by how many nets cross each block pair) with box repulsion and
/// a weak centering pull, then snap each centre to a coarse grid. Returns one world
/// origin per macro — the reference a member's (lx,ly) offset adds to, so the block's
/// bounding box ends up centred on its relaxed centre. `legalizeComposed` does the
/// final hard de-overlap; this just gets connected blocks near each other.
fn arrangeMacros(
    arena: std.mem.Allocator,
    macros: []const Macro,
    macro_of: []const ?usize,
    nets: []const FlatNet,
    idx_of: *const std.StringHashMap(usize),
) std.mem.Allocator.Error![][2]f64 {
    const n = macros.len;
    // Pairwise shared-net weights: a net touching k distinct blocks adds 1 to each
    // of its block pairs, so heavily-interconnected modules attract hardest.
    const w = try arena.alloc(f64, n * n);
    @memset(w, 0);
    var touch: std.ArrayListUnmanaged(usize) = .empty;
    for (nets) |net| {
        touch.clearRetainingCapacity();
        for (net.pins) |pin| {
            const pi = idx_of.get(pin.ref_des) orelse continue;
            const mo = macro_of[pi] orelse continue;
            var dup = false;
            for (touch.items) |t| {
                if (t == mo) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try touch.append(arena, mo);
        }
        if (touch.items.len < 2) continue;
        for (touch.items, 0..) |a, ai| {
            for (touch.items[ai + 1 ..]) |b| {
                w[a * n + b] += 1;
                w[b * n + a] += 1;
            }
        }
    }

    // Block half-extents and bbox-centre offsets (world centre = origin + offset).
    const hw = try arena.alloc(f64, n);
    const hh = try arena.alloc(f64, n);
    const offx = try arena.alloc(f64, n);
    const offy = try arena.alloc(f64, n);
    var max_span: f64 = 1;
    for (macros, 0..) |m, i| {
        hw[i] = @max(m.width() / 2, 0.1);
        hh[i] = @max(m.height() / 2, 0.1);
        offx[i] = (m.bminx + m.bmaxx) / 2;
        offy[i] = (m.bminy + m.bmaxy) / 2;
        max_span = @max(max_span, @max(m.width(), m.height()));
    }

    // Deterministic initial spread on a square grid, generous spacing so blocks
    // begin non-overlapping and the springs pull connected ones together.
    const centers = try arena.alloc([2]f64, n);
    const cols: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(n)))))));
    const spacing = max_span + ROUGH_BLOCK_GAP_MM;
    for (0..n) |i| {
        const r: f64 = @floatFromInt(i / cols);
        const c: f64 = @floatFromInt(i % cols);
        centers[i] = .{ c * spacing, r * spacing };
    }

    const nf: f64 = @floatFromInt(n);
    const force = try arena.alloc([2]f64, n);
    var it: usize = 0;
    while (it < ROUGH_ITERS) : (it += 1) {
        @memset(force, [2]f64{ 0, 0 });
        var gx: f64 = 0;
        var gy: f64 = 0;
        for (centers) |c| {
            gx += c[0];
            gy += c[1];
        }
        gx /= nf;
        gy /= nf;
        for (0..n) |a| {
            force[a][0] += (gx - centers[a][0]) * ROUGH_K_CENTER;
            force[a][1] += (gy - centers[a][1]) * ROUGH_K_CENTER;
            for (a + 1..n) |b| {
                const dx = centers[b][0] - centers[a][0];
                const dy = centers[b][1] - centers[a][1];
                const ww = w[a * n + b];
                if (ww > 0) { // connectivity spring (linear → equilibrium at contact)
                    const fx = ROUGH_K_ATT * ww * dx;
                    const fy = ROUGH_K_ATT * ww * dy;
                    force[a][0] += fx;
                    force[a][1] += fy;
                    force[b][0] -= fx;
                    force[b][1] -= fy;
                }
                const ox = hw[a] + hw[b] + ROUGH_BLOCK_GAP_MM - @abs(dx);
                const oy = hh[a] + hh[b] + ROUGH_BLOCK_GAP_MM - @abs(dy);
                if (ox > 0 and oy > 0) { // overlapping: push along smaller-overlap axis
                    if (ox <= oy) {
                        const push = ROUGH_K_REP * ox * (if (dx >= 0) @as(f64, 1) else -1);
                        force[a][0] -= push;
                        force[b][0] += push;
                    } else {
                        const push = ROUGH_K_REP * oy * (if (dy >= 0) @as(f64, 1) else -1);
                        force[a][1] -= push;
                        force[b][1] += push;
                    }
                }
            }
        }
        for (0..n) |a| {
            centers[a][0] += @max(-ROUGH_MAX_STEP_MM, @min(ROUGH_MAX_STEP_MM, force[a][0] * ROUGH_STEP));
            centers[a][1] += @max(-ROUGH_MAX_STEP_MM, @min(ROUGH_MAX_STEP_MM, force[a][1] * ROUGH_STEP));
        }
    }

    const origins = try arena.alloc([2]f64, n);
    for (0..n) |i| {
        // Snap the block CENTRE to the coarse grid, then back out the origin so the
        // member offsets (grid multiples) keep every part on the base grid.
        const ccx = @round(centers[i][0] / ROUGH_ORIGIN_GRID_MM) * ROUGH_ORIGIN_GRID_MM;
        const ccy = @round(centers[i][1] / ROUGH_ORIGIN_GRID_MM) * ROUGH_ORIGIN_GRID_MM;
        origins[i] = .{ gridRound(ccx - offx[i]), gridRound(ccy - offy[i]) };
    }
    return origins;
}

// ── Physical board: outline + edge docking (`(board …)`) ────────────────────
// The interior placement (force / spec / floorplan) is solved first and left
// unchanged; the authored W×H outline is then centered on it, each edge list
// docks flush INSIDE its named board edge (slid along the edge toward the
// parts it connects to, then 1-D de-overlapped within the span the corners
// leave free), and `(corners …)` hardware pins at the four corners.

/// Clearance between neighbouring edge-docked parts along their shared edge,
/// and between an edge part and the corner hardware bounding its span (mm).
const BOARD_EDGE_GAP_MM: f64 = 1.0;

/// The four `(corners …)` slots in authored order.
const CornerSlot = enum { tl, tr, br, bl };

/// Default rotation for an edge-docked connector: the quarter turn that points
/// its pad centroid toward the board interior — pads inward, body toward (or
/// overhanging) the edge, the way an edge-launch SMA / USB-C / RJ45 mounts.
/// Parts whose pads are centred on the footprint (mounting standoffs) keep 0.
fn edgeInwardRot(p: Part, edge: Edge) f64 {
    if (p.pads.len == 0) return 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (p.pads) |pad| {
        cx += pad.x;
        cy += pad.y;
    }
    cx /= @as(f64, @floatFromInt(p.pads.len));
    cy /= @as(f64, @floatFromInt(p.pads.len));
    if (cx * cx + cy * cy < 0.01) return 0;
    // Board-interior direction for each edge (y grows DOWN: top edge = −y).
    const inx: f64 = switch (edge) {
        .left => 1,
        .right => -1,
        .top, .bottom => 0,
    };
    const iny: f64 = switch (edge) {
        .top => 1,
        .bottom => -1,
        .left, .right => 0,
    };
    var best_rot: f64 = 0;
    var best = -std.math.inf(f64);
    var r: f64 = 0;
    while (r < 360) : (r += 90) {
        const off = rotateLocal(cx, cy, r);
        const dot = off.x * inx + off.y * iny;
        if (dot > best + 1e-9) {
            best = dot;
            best_rot = r;
        }
    }
    return best_rot;
}

/// The attachment centroid of `pi`: mean centre of the other parts it shares a
/// non-ground net with (ground nets touch everything, pulling every connector
/// to the board centre). Falls back to ground-net partners, then null. The
/// docked connector slides along its edge toward this point.
fn attachCentroid(parts: []const Part, idx_of: *const std.StringHashMap(usize), nets: []const FlatNet, pi: usize) ?Pt {
    var sx: f64 = 0;
    var sy: f64 = 0;
    var n: f64 = 0;
    var gx: f64 = 0;
    var gy: f64 = 0;
    var gn: f64 = 0;
    for (nets) |net| {
        var touches = false;
        for (net.pins) |pin| {
            if (idx_of.get(pin.ref_des)) |qi| {
                if (qi == pi) {
                    touches = true;
                    break;
                }
            }
        }
        if (!touches) continue;
        const groundy = isGroundName(net.name);
        for (net.pins) |pin| {
            const qi = idx_of.get(pin.ref_des) orelse continue;
            if (qi == pi) continue;
            if (groundy) {
                gx += parts[qi].x;
                gy += parts[qi].y;
                gn += 1;
            } else {
                sx += parts[qi].x;
                sy += parts[qi].y;
                n += 1;
            }
        }
    }
    if (n > 0) return .{ .x = sx / n, .y = sy / n };
    if (gn > 0) return .{ .x = gx / gn, .y = gy / gn };
    return null;
}

/// One resolved edge-list entry: the part index + its authored rotation.
const SideRef = struct { pi: usize, rot: ?f64 };

/// Resolve the `(board …)` side + corner names against the flattened design.
/// Unresolved names are appended to the placement diag (the lint layer
/// surfaces them); a name in two lists keeps its first claim.
const BoardClaims = struct {
    claimed: []bool,
    side_parts: [4][]const SideRef,
    corner_parts: []const usize,
};

fn resolveBoardClaims(
    arena: std.mem.Allocator,
    spec: env.BoardSpec,
    instances: []const export_kicad.FlatInstance,
    nparts: usize,
    record_unresolved: bool,
) std.mem.Allocator.Error!BoardClaims {
    const claimed = try arena.alloc(bool, nparts);
    @memset(claimed, false);
    var unresolved: std.ArrayListUnmanaged([]const u8) = .empty;
    var side_lists: [4]std.ArrayListUnmanaged(SideRef) = .{ .empty, .empty, .empty, .empty };
    for (spec.sides) |s| {
        const ei: usize = @intFromEnum(edgeFromSide(s.side));
        for (s.items) |it| {
            if (resolvePart(instances, it.ref)) |pi| {
                if (!claimed[pi]) {
                    claimed[pi] = true;
                    try side_lists[ei].append(arena, .{ .pi = pi, .rot = it.rot });
                }
            } else try unresolved.append(arena, it.ref);
        }
    }
    var corner_list: std.ArrayListUnmanaged(usize) = .empty;
    for (spec.corners) |it| {
        if (resolvePart(instances, it.ref)) |pi| {
            if (!claimed[pi]) {
                claimed[pi] = true;
                try corner_list.append(arena, pi);
            }
        } else try unresolved.append(arena, it.ref);
    }
    if (record_unresolved and unresolved.items.len > 0) {
        var all: std.ArrayListUnmanaged([]const u8) = .empty;
        try all.appendSlice(arena, g_placement_diag.unresolved);
        try all.appendSlice(arena, unresolved.items);
        g_placement_diag.unresolved = try all.toOwnedSlice(arena);
    }
    return .{
        .claimed = claimed,
        .side_parts = .{
            try side_lists[0].toOwnedSlice(arena),
            try side_lists[1].toOwnedSlice(arena),
            try side_lists[2].toOwnedSlice(arena),
            try side_lists[3].toOwnedSlice(arena),
        },
        .corner_parts = try corner_list.toOwnedSlice(arena),
    };
}

/// Remove board-claimed refs from a placement-diag list — a claimed part is
/// placed by the board form now, whatever the spec pass thought of it.
fn scrubClaimed(
    arena: std.mem.Allocator,
    list: []const []const u8,
    idx_of: *const std.StringHashMap(usize),
    claimed: []const bool,
) std.mem.Allocator.Error![]const []const u8 {
    var still: std.ArrayListUnmanaged([]const u8) = .empty;
    for (list) |ref| {
        const pi = idx_of.get(ref) orelse {
            try still.append(arena, ref);
            continue;
        };
        if (!claimed[pi]) try still.append(arena, ref);
    }
    return still.toOwnedSlice(arena);
}

/// Realize a `(board …)` form on an already-solved interior placement. Mutates
/// only the claimed (edge/corner) parts and the staging band; returns the
/// outline rectangle for the renderers.
fn packBoard(
    arena: std.mem.Allocator,
    parts: []Part,
    instances: []const export_kicad.FlatInstance,
    idx_of: *const std.StringHashMap(usize),
    nets: []const FlatNet,
    spec: env.BoardSpec,
) std.mem.Allocator.Error!BoardRect {
    const bc = try resolveBoardClaims(arena, spec, instances, parts.len, true);

    // Interior bbox: every part that is neither board-claimed nor staged in
    // the spec band (keepout extents — same boxes the collision pass checks).
    var staged = std.StringHashMap(void).init(arena);
    for (g_placement_diag.unplaced) |ref| try staged.put(ref, {});
    var ix0 = std.math.inf(f64);
    var iy0 = std.math.inf(f64);
    var ix1 = -std.math.inf(f64);
    var iy1 = -std.math.inf(f64);
    for (parts, 0..) |p, i| {
        if (bc.claimed[i] or staged.contains(p.ref_des)) continue;
        const kb = keepBoxOf(p);
        ix0 = @min(ix0, p.x + kb.cxo - kb.hw);
        ix1 = @max(ix1, p.x + kb.cxo + kb.hw);
        iy0 = @min(iy0, p.y + kb.cyo - kb.hh);
        iy1 = @max(iy1, p.y + kb.cyo + kb.hh);
    }
    if (ix0 > ix1) {
        ix0 = 0;
        ix1 = 0;
        iy0 = 0;
        iy1 = 0;
    }
    // Each edge's docked parts occupy a lane reaching inward from the edge;
    // offset the rectangle so the interior centres in the region the lanes
    // leave FREE (centring on the full rectangle would slide the interior
    // under a deep connector like a magjack).
    var lane = [4]f64{ 0, 0, 0, 0 };
    for (bc.side_parts, 0..) |list, ei| {
        const edge: Edge = @enumFromInt(ei);
        for (list) |sr| {
            var tmp = parts[sr.pi];
            tmp.rot = if (sr.rot) |r| @mod(@round(r / 90.0) * 90.0, 360.0) else edgeInwardRot(tmp, edge);
            const kb = keepBoxOf(tmp);
            const depth = if (edge == .left or edge == .right) 2 * kb.hw else 2 * kb.hh;
            lane[ei] = @max(lane[ei], depth + BOARD_EDGE_GAP_MM);
        }
    }
    const rect = BoardRect{
        .minx = gridRound((ix0 + ix1) / 2 - spec.w / 2 - (lane[0] - lane[1]) / 2),
        .miny = gridRound((iy0 + iy1) / 2 - spec.h / 2 - (lane[2] - lane[3]) / 2),
        .w = spec.w,
        .h = spec.h,
    };
    const x0 = rect.minx;
    const x1 = rect.minx + rect.w;
    const y0 = rect.miny;
    const y1 = rect.miny + rect.h;

    // Corners first (TL, TR, BR, BL in authored order) — they bound the edge
    // spans. Track each one's world keepout so the edges dodge it.
    var corner_box = [4]?Rect{ null, null, null, null };
    for (bc.corner_parts, 0..) |pi, k| {
        if (k >= 4) break;
        const p = &parts[pi];
        p.rot = 0;
        const kb = keepBoxOf(p.*);
        switch (@as(CornerSlot, @enumFromInt(k))) {
            .tl => {
                p.x = gridRound(x0 + kb.hw - kb.cxo);
                p.y = gridRound(y0 + kb.hh - kb.cyo);
            },
            .tr => {
                p.x = gridRound(x1 - kb.hw - kb.cxo);
                p.y = gridRound(y0 + kb.hh - kb.cyo);
            },
            .br => {
                p.x = gridRound(x1 - kb.hw - kb.cxo);
                p.y = gridRound(y1 - kb.hh - kb.cyo);
            },
            .bl => {
                p.x = gridRound(x0 + kb.hw - kb.cxo);
                p.y = gridRound(y1 - kb.hh - kb.cyo);
            },
        }
        corner_box[k] = .{
            .x0 = p.x + kb.cxo - kb.hw,
            .y0 = p.y + kb.cyo - kb.hh,
            .x1 = p.x + kb.cxo + kb.hw,
            .y1 = p.y + kb.cyo + kb.hh,
        };
    }

    // Each edge: rotation (pads inward unless overridden) → cross-axis flush
    // inside the edge → desired slide position (attachment centroid) → 1-D
    // de-overlap inside the span the adjacent corners leave free.
    for (bc.side_parts, 0..) |list, ei| {
        if (list.len == 0) continue;
        const edge: Edge = @enumFromInt(ei);
        const vertical = (edge == .left or edge == .right);
        // Span along the edge, shrunk past any adjacent corner hardware.
        var span_min = if (vertical) y0 else x0;
        var span_max = if (vertical) y1 else x1;
        const corner_at: [2]?Rect = switch (edge) {
            .left => .{ corner_box[0], corner_box[3] }, // TL, BL
            .right => .{ corner_box[1], corner_box[2] }, // TR, BR
            .top => .{ corner_box[0], corner_box[1] }, // TL, TR
            .bottom => .{ corner_box[3], corner_box[2] }, // BL, BR
        };
        if (corner_at[0]) |cb| span_min = @max(span_min, (if (vertical) cb.y1 else cb.x1) + BOARD_EDGE_GAP_MM);
        if (corner_at[1]) |cb| span_max = @min(span_max, (if (vertical) cb.y0 else cb.x0) - BOARD_EDGE_GAP_MM);

        const Entry = struct { pi: usize, want: f64, half: f64 };
        var entries = try arena.alloc(Entry, list.len);
        for (list, 0..) |sr, i| {
            const p = &parts[sr.pi];
            p.rot = if (sr.rot) |r| @mod(@round(r / 90.0) * 90.0, 360.0) else edgeInwardRot(p.*, edge);
            const kb = keepBoxOf(p.*);
            switch (edge) {
                .left => p.x = x0 + kb.hw - kb.cxo,
                .right => p.x = x1 - kb.hw - kb.cxo,
                .top => p.y = y0 + kb.hh - kb.cyo,
                .bottom => p.y = y1 - kb.hh - kb.cyo,
            }
            const want = if (attachCentroid(parts, idx_of, nets, sr.pi)) |c|
                (if (vertical) c.y else c.x)
            else
                (span_min + span_max) / 2;
            entries[i] = .{
                .pi = sr.pi,
                .want = std.math.clamp(want, span_min, span_max),
                .half = if (vertical) kb.hh else kb.hw,
            };
        }
        std.mem.sort(Entry, entries, {}, struct {
            fn less(_: void, a: Entry, b: Entry) bool {
                return a.want < b.want;
            }
        }.less);
        // Standard 1-D legalize: forward sweep packs left-to-right at desired
        // positions, backward sweep pulls everything inside the span. A span
        // too small for its parts overflows past `span_min` — honest geometry
        // the overlap lint reports rather than a silent rescale.
        const centers = try arena.alloc(f64, entries.len);
        for (entries, 0..) |e, i| {
            const lo = if (i == 0)
                span_min + e.half
            else
                centers[i - 1] + entries[i - 1].half + e.half + BOARD_EDGE_GAP_MM;
            centers[i] = @max(e.want, lo);
        }
        var i = entries.len;
        var hi = span_max - entries[entries.len - 1].half;
        while (i > 0) {
            i -= 1;
            centers[i] = @min(centers[i], hi);
            if (i > 0) hi = centers[i] - entries[i].half - entries[i - 1].half - BOARD_EDGE_GAP_MM;
        }
        for (entries, 0..) |e, k| {
            const p = &parts[e.pi];
            const kb = keepBoxOf(p.*);
            if (vertical) {
                p.y = gridRound(centers[k] - kb.cyo);
            } else {
                p.x = gridRound(centers[k] - kb.cxo);
            }
        }
    }

    // Board-claimed parts are placed now — drop them from the spec staging
    // diag (a floorplan that doesn't list the connectors leaves them loose;
    // the board form is what places them).
    g_placement_diag.unplaced = try scrubClaimed(arena, g_placement_diag.unplaced, idx_of, bc.claimed);
    g_placement_diag.auto_filled = try scrubClaimed(arena, g_placement_diag.auto_filled, idx_of, bc.claimed);
    staged.clearRetainingCapacity();
    for (g_placement_diag.unplaced) |ref| try staged.put(ref, {});

    // The spec staging band was packed under the *interior*; a board outline
    // can reach further down. Keep the band clear of the rectangle.
    var band_top = std.math.inf(f64);
    var band_hits = false;
    for (parts) |p| {
        if (!staged.contains(p.ref_des)) continue;
        const kb = keepBoxOf(p);
        const top = p.y + kb.cyo - kb.hh;
        band_top = @min(band_top, top);
        if (top < y1 + GRID_MM) band_hits = true;
    }
    if (band_hits) {
        const dy = (y1 + STAGE_GAP_MM) - band_top;
        for (parts) |*p| {
            if (staged.contains(p.ref_des)) p.y += dy;
        }
    }
    return rect;
}

/// The outline rectangle for a layout loaded from cache (poses applied
/// verbatim — nothing re-docks): W×H centered on the board-claimed parts'
/// bbox when any resolve (they were docked flush to the edges when the cache
/// was written, so their bbox ≈ the original rectangle), else on the whole
/// board's bbox.
fn boardRectFromPoses(
    arena: std.mem.Allocator,
    parts: []const Part,
    instances: []const export_kicad.FlatInstance,
    spec: env.BoardSpec,
) std.mem.Allocator.Error!BoardRect {
    const bc = try resolveBoardClaims(arena, spec, instances, parts.len, false);
    var ix0 = std.math.inf(f64);
    var iy0 = std.math.inf(f64);
    var ix1 = -std.math.inf(f64);
    var iy1 = -std.math.inf(f64);
    var any_claimed = false;
    for (bc.claimed) |c| {
        if (c) any_claimed = true;
    }
    for (parts, 0..) |p, i| {
        if (any_claimed and !bc.claimed[i]) continue;
        const kb = keepBoxOf(p);
        ix0 = @min(ix0, p.x + kb.cxo - kb.hw);
        ix1 = @max(ix1, p.x + kb.cxo + kb.hw);
        iy0 = @min(iy0, p.y + kb.cyo - kb.hh);
        iy1 = @max(iy1, p.y + kb.cyo + kb.hh);
    }
    if (ix0 > ix1) {
        ix0 = 0;
        ix1 = 0;
        iy0 = 0;
        iy1 = 0;
    }
    return .{
        .minx = gridRound((ix0 + ix1) / 2 - spec.w / 2),
        .miny = gridRound((iy0 + iy1) / 2 - spec.h / 2),
        .w = spec.w,
        .h = spec.h,
    };
}

/// The design's plane-carrying net names per its `(stackup …)` form, in the
/// shape `Placement.plane_nets` documents (null = legacy implicit planes).
fn planeNetsOf(arena: std.mem.Allocator, block: *const DesignBlock) std.mem.Allocator.Error!?[]const []const u8 {
    if (!block.stackup.present) return null;
    const out = try arena.alloc([]const u8, block.stackup.planes.len);
    for (block.stackup.planes, 0..) |pl, i| out[i] = pl.net;
    return out;
}

/// Per-net routing geometry from the design's `(net-class …)` forms, aligned
/// with `nets` (see `Placement.net_rules`). Names match case-insensitively on
/// the full flattened net name or its leaf after the last `/`; the first class
/// naming a net wins. Empty when the design declares no classes.
fn netRulesOf(arena: std.mem.Allocator, block: *const DesignBlock, nets: []const FlatNet) std.mem.Allocator.Error![]const NetRule {
    if (block.net_classes.len == 0) return &.{};
    const out = try arena.alloc(NetRule, nets.len);
    for (nets, 0..) |net, i| {
        out[i] = .{};
        outer: for (block.net_classes) |nc| {
            for (nc.nets) |cn| {
                const hit = std.ascii.eqlIgnoreCase(cn, net.name) or
                    std.ascii.eqlIgnoreCase(cn, shortName(net.name));
                if (hit) {
                    out[i] = .{ .width = nc.width, .clearance = nc.clearance, .via_dia = nc.via_dia, .via_drill = nc.via_drill };
                    break :outer;
                }
            }
        }
    }
    return out;
}

/// Build a placement for `block`. When `cached` covers every part, its poses
/// are applied directly (no optimization — fast); otherwise the optimizer runs
/// and `Placement.generated` is set so the caller can persist a fresh cache.
/// In `.refine` mode an applied cached layout is given the local routed tuck
/// (`routedPolish`) instead of being left as-is; `generated` stays false so the
/// caller leaves the auto cache untouched. All output is in `arena`.
pub fn solve(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    cached: ?[]const RefPose,
    params: Params,
    mode: SeedMode,
) std.mem.Allocator.Error!Placement {
    // Don't leave the arena-backed threadlocals dangling once the outermost solve
    // returns and the caller frees the arena (nested solves manage them via
    // SolveState — see resetArenaGlobals).
    g_solve_depth += 1;
    defer {
        g_solve_depth -= 1;
        resetArenaGlobals();
    }
    var prep = try prepare(arena, block, project_dir, params);
    const parts = prep.parts;
    const nets = prep.nets;
    const built = prep.built;

    // Reserve a breakout corridor in front of every "unaccounted" pad (a net
    // touching only this part — a single-pin signal that leaves the board), so
    // the placer doesn't drop a neighbour over the escape route. This grows the
    // collision keepout only; the rendered courtyard is unchanged.
    const stubs = try buildEscapeStubs(arena, nets, parts, &prep.idx_of);
    applyKeepout(parts, stubs);

    // `(board (size W H) …)` with a real size declares a physical outline:
    // dock its edge/corner hardware after the interior solve, and surface the
    // rectangle to the renderers either way. Without `(size …)` the form is
    // inert (the describe lint reports it).
    const board_live = block.board.present and block.board.w > 0 and block.board.h > 0;
    var board_rect: ?BoardRect = null;

    const generated = !applyCached(parts, cached);
    if (generated) {
        try runPlacement(arena, parts, &prep, nets, built, params);
        // Stream the first arrangement to a watching live-regen browser (no-op
        // for a synchronous page solve, which never installs a sink). Pure
        // observation — `emitBest`/`surrogateObjective` only read `parts`, so
        // they can't shift output. The scalar is the smooth objective the viewer
        // shows (lower is better).
        emitBest(parts, surrogateObjective(parts, &prep.idx_of, nets, built.loops, params), .explore);
        // When courtyard overlap is enabled, the denser feasible region helps most
        // boards but can land a small/sparse one in a worse basin (its HPWL rises
        // even though overlap only *adds* freedom — a convergence artefact). So
        // also solve the strict regime and keep whichever routes better: overlap
        // can then never regress a board below strict. Only pays the 2× cost when
        // overlap is on (`routedObjectiveCost` is a valid comparison for any board
        // — it folds in HPWL + congestion and falls back to the surrogate loop
        // term when there are no loops or the board is too large to route).
        if (g_collide_shrink > 0 and parts.len >= 2) {
            const overlap_routed = routedObjectiveCost(arena, parts, &prep.idx_of, nets, built.loops, params);
            const overlap_poses = try capturePoses(arena, parts);
            const saved_shrink = g_collide_shrink;
            g_collide_shrink = 0; // strict regime
            try runPlacement(arena, parts, &prep, nets, built, params);
            const strict_routed = routedObjectiveCost(arena, parts, &prep.idx_of, nets, built.loops, params);
            g_collide_shrink = saved_shrink;
            if (overlap_routed <= strict_routed) restorePoses(parts, overlap_poses);
            // else keep the strict arrangement already in `parts`.
        }
        if (board_live) {
            board_rect = try packBoard(arena, parts, prep.instances, &prep.idx_of, nets, block.board);
            // The dock just landed the connectors; parts whose only anchors
            // are ON those connectors (CC pull-downs, LED resistors) couldn't
            // fill during the spec pass — give them a second pin-hug pass.
            if (g_placement_diag.unplaced.len > 0) {
                try autofillUnlisted(arena, parts, &prep.idx_of, nets, built.loops);
            }
        }
    } else if (mode == .refine and parts.len >= 2 and parts.len <= ROUTED_POLISH_MAX_PARTS and built.loops.len > 0) {
        // Seeded from an existing layout: keep its global arrangement, just run the
        // local routed tuck on it (the same monotonic, safety-netted pass the auto
        // solve finishes with), then the same priority-cap tuck. Lets a good hand
        // layout be improved without losing it.
        routedPolish(arena, parts, &prep.idx_of, nets, built.loops, params);
        tightenPriorityLoops(arena, parts, built.loops, nets, prep.priority);
    }

    // Headline + objective loop term: the smooth analytic fixed-pad surrogate
    // (`surrogateLoops`) — the same continuous metric the inner objective already
    // minimises. The real maze-routed trace is deliberately NOT scored here: re-
    // routing from scratch per pose makes the score a jagged, bistable function of
    // position (a 0.05 mm nudge can flip a leg routable↔unroutable and swing the
    // objective by tens of units). Routing is a separate explicit action that
    // draws real copper, not the placement score.
    const score = scoreLayout(parts, &prep.idx_of, nets, built.loops);
    const lsum = surrogateLoops(parts, built.loops);
    const bd = breakdownWith(parts, &prep.idx_of, nets, params, score, lsum);
    // Final refined arrangement → the live-regen watcher (see the explore emit
    // above). No-op without a sink; reads `parts` only. `bd.objective` is the
    // same lower-is-better scalar the explore frame used.
    emitBest(parts, bd.objective, .refine);
    var pl = try finalize(arena, parts, built.springs, built.loops, stubs, prep.instances, nets, prep.priority, score, bd, generated);
    pl.rules = .{ .plane_nets = try planeNetsOf(arena, block), .net = try netRulesOf(arena, block, nets) };
    if (board_live) {
        if (board_rect == null) board_rect = try boardRectFromPoses(arena, parts, prep.instances, block.board);
        pl.board_rect = board_rect;
        // The view frame must include the outline even where it reaches past
        // the parts (a sparse board on a big rectangle).
        const r = board_rect.?;
        pl.minx = @min(pl.minx, r.minx);
        pl.miny = @min(pl.miny, r.miny);
        pl.maxx = @max(pl.maxx, r.minx + r.w);
        pl.maxy = @max(pl.maxy, r.miny + r.h);
    }
    return pl;
}

/// Score an arbitrary set of part poses with the optimizer's *own* objective —
/// the single source of truth, so callers (the layout page's server-side score
/// button) needn't reimplement HPWL / loop / alignment in JS. Builds
/// the design exactly as `solve` does, applies `poses` verbatim (overlaps
/// allowed — this only measures, never moves), and returns the full breakdown.
/// Parts not named in `poses` stay at the origin, so `poses` should cover all.
pub fn scorePoses(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    poses: []const RefPose,
    params: Params,
) std.mem.Allocator.Error!Breakdown {
    // See solve — don't dangle into the freed arena. scorePoses is never nested.
    g_solve_depth += 1;
    defer {
        g_solve_depth -= 1;
        resetArenaGlobals();
    }
    var prep = try prepare(arena, block, project_dir, params);
    _ = applyCached(prep.parts, poses);
    // Score the loop term with the smooth analytic surrogate — never the maze
    // router — so the drag-to-score the page issues on every pointer move is a
    // continuous function of position (see `solve`).
    const score = scoreLayout(prep.parts, &prep.idx_of, prep.nets, prep.built.loops);
    const lsum = surrogateLoops(prep.parts, prep.built.loops);
    return breakdownWith(prep.parts, &prep.idx_of, prep.nets, params, score, lsum);
}

/// One hot loop's connection inductance (nH) — the quantity the objective's loop
/// term sums. Exposed so the PNG renderer can size and label each loop ribbon by
/// its contribution. Mirrors the surrogate the optimizer minimizes (fixed power
/// leg, no maze router), so the ribbon weights match what placement is fighting.
pub fn loopNh(parts: []const Part, lp: Loop) f64 {
    return loopMetric(parts, lp, surrogatePwrLeg(parts, lp)).nh;
}

/// Fill `out` (index-aligned with `p.parts`) with each part's share of the
/// objective, for the render "blame" heatmap. Every ratsnest link's length is
/// split evenly between its two endpoints, and each hot loop's value-weighted
/// inductance (× `loop_w`) is charged to its cap — the same mm + `loop_w`·nH
/// mixing the objective itself sums, so the hottest parts are the ones the
/// optimizer is straining against. Congestion is board-global and omitted.
/// Values are raw; the caller normalizes for the colour ramp. No-op on a length
/// mismatch.
pub fn perPartBlame(p: Placement, params: Params, out: []f64) void {
    if (out.len != p.parts.len) return;
    @memset(out, 0);
    for (p.links) |l| {
        const a = worldPt(p.parts[l.a], l.ax, l.ay);
        const b = worldPt(p.parts[l.b], l.bx, l.by);
        const d = std.math.hypot(a.x - b.x, a.y - b.y);
        out[l.a] += d / 2;
        out[l.b] += d / 2;
    }
    for (p.loops) |lp| {
        out[lp.cap] += params.loop_w * lp.weight * loopNh(p.parts, lp);
    }
}

/// The maze-routed objective for an existing set of `poses` — the routed metric
/// (HPWL + routed-loop nH + compactness + congestion), as opposed to the smooth
/// surrogate `scorePoses` reports. Computed
/// once for diagnostics/benchmarking; deliberately NOT a per-pose optimization
/// signal — re-routing per pose is jagged/bistable (see the note in `solve`), so
/// call this on a finished placement, never in a hot loop. Rebuilds the design
/// like `scorePoses` and applies the poses verbatim (`routedLoops` self-gates on
/// part count, so it is safe on any board).
pub fn routedScorePoses(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    poses: []const RefPose,
    params: Params,
) std.mem.Allocator.Error!f64 {
    var prep = try prepare(arena, block, project_dir, params);
    _ = applyCached(prep.parts, poses);
    return routedObjectiveCost(arena, prep.parts, &prep.idx_of, prep.nets, prep.built.loops, params);
}

/// The FULL-route score for an existing set of `poses` — the highest-fidelity
/// rung: the whole board is mazed (every net, not just loop legs) and judged on
/// real trace length + vias + post-route DRC + unrouted nets (see `FullRouted`).
/// The highest-fidelity routed metric (`fullRouteCost`); exposed so the bench can
/// compare engines / weight sweeps on measured copper instead of the RSMT
/// estimate. Expensive (a full route per call) — diagnostics only, never a
/// per-pose search signal. Null when the board can't be gridded.
pub fn fullRoutedScorePoses(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    poses: []const RefPose,
    params: Params,
) std.mem.Allocator.Error!?FullRouted {
    var prep = try prepare(arena, block, project_dir, params);
    _ = applyCached(prep.parts, poses);
    const lw = routedLoops(arena, prep.parts, &prep.idx_of, prep.nets, prep.built.loops).weighted_nh;
    const stubs = try buildEscapeStubs(arena, prep.nets, prep.parts, &prep.idx_of);
    return fullRouteCost(arena, prep.parts, prep.nets, prep.built.loops, stubs, prep.priority, params, .{}, lw);
}

/// Build a `Placement` at exactly `poses` (no optimization — overlaps allowed),
/// so a caller can route the user's *on-screen* layout verbatim instead of the
/// auto-generated one. Same design model as `scorePoses` (and it also builds the
/// escape stubs the router needs), but it returns the full placement with
/// `generated = false`. The score fields use the cheap fixed-pad surrogate — the
/// router re-measures real traces itself, so paying for `routedLoops` here would
/// just route the board twice. Parts not named in `poses` stay at the origin, so
/// `poses` should cover every part.
pub fn placeFromPoses(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    poses: []const RefPose,
    params: Params,
) std.mem.Allocator.Error!Placement {
    var prep = try prepare(arena, block, project_dir, params);
    const parts = prep.parts;
    const nets = prep.nets;
    const built = prep.built;
    const stubs = try buildEscapeStubs(arena, nets, parts, &prep.idx_of);
    // Apply the poses verbatim; unlike `solve`, never fall back to optimizing —
    // a slightly-overlapping hand-dragged layout must still route as drawn.
    _ = applyCached(parts, poses);
    const score = scoreLayout(parts, &prep.idx_of, nets, built.loops);
    const lsum = surrogateLoops(parts, built.loops);
    const bd = breakdownWith(parts, &prep.idx_of, nets, params, score, lsum);
    var pl = try finalize(arena, parts, built.springs, built.loops, stubs, prep.instances, nets, prep.priority, score, bd, false);
    pl.rules = .{ .plane_nets = try planeNetsOf(arena, block), .net = try netRulesOf(arena, block, nets) };
    // Saved/hand layouts of a `(board …)` design keep their outline overlay.
    if (block.board.present and block.board.w > 0 and block.board.h > 0) {
        const r = try boardRectFromPoses(arena, parts, prep.instances, block.board);
        pl.board_rect = r;
        pl.minx = @min(pl.minx, r.minx);
        pl.miny = @min(pl.miny, r.miny);
        pl.maxx = @max(pl.maxx, r.minx + r.w);
        pl.maxy = @max(pl.maxy, r.miny + r.h);
    }
    return pl;
}

/// Place every part on a plain uniform grid (no optimization) — the cheap
/// placeholder the layout page shows when a design has no cached or saved layout
/// yet, so *opening* the page doesn't pay for a full solve. Same design model as
/// `placeFromPoses` (escape stubs built, surrogate score so the score bar still
/// has numbers), but positions come from `arrangeGrid` and `generated` is false
/// (a raw grid is never persisted as the auto layout). The optimizer still runs
/// on demand — the Regenerate / Apply-tuning paths and the small per-sub-block
/// previews call `solve`.
pub fn gridPlace(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    params: Params,
) std.mem.Allocator.Error!Placement {
    var prep = try prepare(arena, block, project_dir, params);
    const parts = prep.parts;
    const nets = prep.nets;
    const built = prep.built;
    const stubs = try buildEscapeStubs(arena, nets, parts, &prep.idx_of);
    applyKeepout(parts, stubs);
    arrangeGrid(parts);
    const score = scoreLayout(parts, &prep.idx_of, nets, built.loops);
    const lsum = surrogateLoops(parts, built.loops);
    const bd = breakdownWith(parts, &prep.idx_of, nets, params, score, lsum);
    var pl = try finalize(arena, parts, built.springs, built.loops, stubs, prep.instances, nets, prep.priority, score, bd, false);
    pl.rules = .{ .plane_nets = try planeNetsOf(arena, block), .net = try netRulesOf(arena, block, nets) };
    return pl;
}

/// Lay parts out on a uniform grid, row-major in flatten order, filling a roughly
/// square aspect. The cell is sized to the largest part's keepout span (so no two
/// courtyards can overlap) plus a small gap, and each part is centred in its cell
/// on the `GRID_MM` grid at rotation 0. Deterministic and O(n) — the "just show
/// the parts" fallback, no springs or relaxation. Mutates `parts.x/y/rot`.
fn arrangeGrid(parts: []Part) void {
    if (parts.len == 0) return;
    // Uniform cell = the widest/tallest keepout across all parts (the keepout
    // centre can be offset by an escape stub, so account for both sides) + a gap.
    var cw: f64 = 0;
    var ch: f64 = 0;
    for (parts) |p| {
        cw = @max(cw, 2 * (keepHw(p) + @abs(keepCx(p) - p.x)));
        ch = @max(ch, 2 * (keepHh(p) + @abs(keepCy(p) - p.y)));
    }
    const GAP_MM: f64 = 2.0;
    cw = ceilToGrid(cw + GAP_MM);
    ch = ceilToGrid(ch + GAP_MM);
    const cols: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(parts.len)))))));
    for (parts, 0..) |*p, i| {
        const col: f64 = @floatFromInt(i % cols);
        const row: f64 = @floatFromInt(i / cols);
        p.rot = 0;
        p.x = @round((col * cw + cw / 2) / GRID_MM) * GRID_MM;
        p.y = @round((row * ch + ch / 2) / GRID_MM) * GRID_MM;
    }
}

/// The design model `solve` and `scorePoses` share: the flattened parts (with
/// footprint geometry + grid-rounded courtyards), the ref→index map, the merged
/// signal nets, and the springs/decoupling-loops — already classified
/// (per-loop value + input-loop weights). Everything the scoring
/// reads, minus the placed positions.
const Prepared = struct {
    parts: []Part,
    idx_of: std.StringHashMap(usize),
    instances: []const export_kicad.FlatInstance,
    nets: []const FlatNet,
    built: Built,
    /// Per-part priority rank (always 0 now — `(placement-order …)` was removed),
    /// kept because `tightenPriorityLoops` takes it (it no-ops on an all-zero slice).
    priority: []const u32,
    /// Resolved + lowered Phase-A constraints. Always inert now (the `(constraints …)`
    /// form was removed); `prepare` still publishes it to `g_lowered` for the solve.
    lowered: Lowered,
    /// The design block + project dir this model was prepared from, carried so the
    /// rough hierarchical seed (`runRough`) can iterate `block.sub_blocks` and
    /// nested-solve each one as its own board.
    block: *const DesignBlock,
    project_dir: []const u8,
};

/// Resolve a design-local net name (what a constraint author writes — "VIN",
/// "FB") to a flattened-net index. Flattening prefixes a sub-block's nets
/// ("pwr/VIN"), so match on the prefix-stripped `shortName` first, then the full
/// name. Null when no net matches.
fn resolveNet(nets: []const FlatNet, want: []const u8) ?usize {
    for (nets, 0..) |net, i| {
        if (std.mem.eql(u8, shortName(net.name), want) or std.mem.eql(u8, net.name, want)) return i;
    }
    return null;
}

/// Per-flattened-net declared current (A) — the data the power-budget table
/// already collects, resolved against the placement netlist so `congestPitch`
/// can size each rail's RUDY corridor. Three sources, max-merged per net:
///   • the design's own ports carrying `(current <typ> <max>)`;
///   • sub-block *output* ports with current (the budget's "sources"), mapped to
///     the top-level rail through the `(net …)` tie that connects them;
///   • the summed `(i-typ …)` consumer pins on each top-level net, so a rail
///     with no source declaration is still sized by its declared loads.
/// Names resolve via `resolveNet` (short or full); anything unresolved is
/// skipped — a missed net just keeps the signal pitch, never errors.
fn netCurrents(arena: std.mem.Allocator, block: *const DesignBlock, nets: []const FlatNet) std.mem.Allocator.Error![]f64 {
    const cur = try arena.alloc(f64, nets.len);
    @memset(cur, 0);
    for (block.ports) |port| {
        const amps = port.current_typ orelse port.current_max orelse continue;
        const want = if (port.net.len > 0) port.net else port.name;
        if (resolveNet(nets, want)) |ni| cur[ni] = @max(cur[ni], amps);
    }
    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |port| {
            if (!std.mem.eql(u8, port.direction, "out")) continue;
            const amps = port.current_typ orelse port.current_max orelse continue;
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ sb.name, port.name });
            for (block.net_ties) |nt| {
                const top = if (std.mem.eql(u8, nt.a, path)) nt.b else if (std.mem.eql(u8, nt.b, path)) nt.a else continue;
                if (resolveNet(nets, top)) |ni| cur[ni] = @max(cur[ni], amps);
            }
        }
    }
    for (block.nets) |net| {
        var sum: f64 = 0;
        for (net.pins) |pin| {
            if (pin.i_typ) |v| sum += v;
        }
        if (sum <= 0) continue;
        if (resolveNet(nets, net.name)) |ni| cur[ni] = @max(cur[ni], sum);
    }
    return cur;
}

/// The footprint-local pad of part `idx` that sits on net `net`, or a zero-size
/// pad at the part centre when it has no pin on that net (so a proximity pull
/// still has a sensible anchor — the part body).
fn padOnNet(part: Part, idx: usize, net: FlatNet, idx_of: *std.StringHashMap(usize)) PadRect {
    for (net.pins) |pr| {
        const i = idx_of.get(pr.ref_des) orelse continue;
        if (i != idx) continue;
        const pad = padLocal(part, pr.pin);
        return .{ .x = pad.x, .y = pad.y, .w = pad.w, .h = pad.h };
    }
    return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
}

/// Resolve + validate the design's Phase-A `(constraints …)` against the
/// flattened netlist, lowering each form into the geometry/weights `constraintCost`
/// consumes. Every ref/net is checked; anything that doesn't resolve is appended
/// to `diags` (a human-readable rejection) and skipped — never silently applied
/// to a wrong target (the doc's load-bearing safety property). When `diags` is
/// null, rejections are simply dropped (the hot `prepare` path). All output is in
/// `arena`. Returns an all-empty `Lowered` when no constraints were authored.
fn resolveConstraints(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    instances: []const export_kicad.FlatInstance,
    nets: []const FlatNet,
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    diags: ?*std.ArrayListUnmanaged([]const u8),
) std.mem.Allocator.Error!Lowered {
    const c = block.constraints;

    const reject = struct {
        fn add(a: std.mem.Allocator, d: ?*std.ArrayListUnmanaged([]const u8), comptime fmt: []const u8, args: anytype) void {
            const dd = d orelse return;
            const msg = std.fmt.allocPrint(a, fmt, args) catch return;
            // A dropped diagnostic only loses an authoring hint, never correctness
            // (the constraint is skipped regardless) — so OOM here just returns.
            dd.append(a, msg) catch return;
        }
    }.add;

    var net_weight = try arena.alloc(f64, nets.len);
    @memset(net_weight, 1.0);
    var input_rail = try arena.alloc(bool, nets.len);
    @memset(input_rail, false);
    var prox: std.ArrayListUnmanaged(ProxTerm) = .empty;
    var keepouts: std.ArrayListUnmanaged(KeepTerm) = .empty;
    var groups: std.ArrayListUnmanaged(GroupTerm) = .empty;

    // power-rail (role input) → mark the rail so the input-loop boost fires even
    // with an integrated inductor (no discrete L to reveal the switcher).
    for (c.power_rails) |pr| {
        const ni = resolveNet(nets, pr.net) orelse {
            reject(arena, diags, "power-rail '{s}': net '{s}' not in netlist", .{ pr.label, pr.net });
            continue;
        };
        if (pr.role == .input) input_rail[ni] = true;
    }

    // Phase-2a auto hot-loop boost: an INTEGRATED-module switcher (a regulated
    // converter with no discrete inductor — TPSM84338, TPS6299x …) hides its
    // switching loop inside the package, so `classify`'s discrete-inductor test
    // never fires the input-loop boost. When `module_policy` detects an input
    // rail + a feedback net (the regulated-converter tell) and there is no
    // discrete L, auto-mark the input rail — the same thing a hand-authored
    // `(power-rail … (role input))` does. (A discrete-L switcher is already
    // boosted by `classify`, so `autoInputRails` excludes it to avoid a double
    // boost.) The board always force-solves now, so this auto-policy always runs.
    const auto_input = autoInputRails(parts, nets, input_rail);

    // net-length (priority) → raise that net's wirelength weight.
    for (c.net_lengths) |nl| {
        const ni = resolveNet(nets, nl.net) orelse {
            reject(arena, diags, "net-length: net '{s}' not in netlist", .{nl.net});
            continue;
        };
        net_weight[ni] *= constraintWeight(nl.priority);
    }

    // deprioritize → scale down the wirelength weight of every net the part is on.
    for (c.deprioritize) |ref| {
        const pi = resolvePart(instances, ref) orelse {
            reject(arena, diags, "deprioritize: part '{s}' not found", .{ref});
            continue;
        };
        for (nets, 0..) |net, ni| {
            for (net.pins) |pp| {
                if ((idx_of.get(pp.ref_des) orelse continue) == pi) {
                    net_weight[ni] *= DEPRIORITIZE_SCALE;
                    break;
                }
            }
        }
    }

    // proximity → a pad-to-pad attraction term. The `pin` token is resolved as a
    // net name (in these designs the relevant pin's net is named after it, e.g.
    // U1's VIN pin sits on net VIN); failing that, as a literal hub pad number.
    for (c.proximity) |p| {
        const part_i = resolvePart(instances, p.ref) orelse {
            reject(arena, diags, "proximity: part '{s}' not found", .{p.ref});
            continue;
        };
        const hub_i = resolvePart(instances, p.hub) orelse {
            reject(arena, diags, "proximity {s}: hub '{s}' not found", .{ p.ref, p.hub });
            continue;
        };
        var part_pad: PadRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        var hub_pad: PadRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (resolveNet(nets, p.pin)) |ni| {
            // Validate both parts actually touch that net.
            hub_pad = padOnNet(parts[hub_i], hub_i, nets[ni], idx_of);
            part_pad = padOnNet(parts[part_i], part_i, nets[ni], idx_of);
            if (hub_pad.w == 0 and hub_pad.h == 0)
                reject(arena, diags, "proximity {s}: hub {s} has no pin on net '{s}'", .{ p.ref, p.hub, p.pin });
        } else {
            const hp = padLocal(parts[hub_i], p.pin);
            if (hp.w == 0 and hp.h == 0) {
                reject(arena, diags, "proximity {s}: '{s}' is neither a net nor a pad of {s}", .{ p.ref, p.pin, p.hub });
                continue;
            }
            hub_pad = .{ .x = hp.x, .y = hp.y, .w = hp.w, .h = hp.h };
        }
        try prox.append(arena, .{
            .part = part_i,
            .hub = hub_i,
            .part_pad = part_pad,
            .hub_pad = hub_pad,
            .w = PROX_W * constraintWeight(p.priority),
            .max_mm = p.max_mm,
        });
    }

    // keep-out (part X) (from Y) → a part-vs-part min courtyard gap. The net-form
    // keep-out (a net's routing region away from a region) is parsed + validated
    // but not yet lowered (its region geometry needs the router) — reported so an
    // author knows it is inert rather than silently honoured.
    for (c.keep_outs) |k| {
        const from_i = resolvePart(instances, k.from) orelse {
            reject(arena, diags, "keep-out: 'from' part '{s}' not found", .{k.from});
            continue;
        };
        if (k.part.len > 0) {
            const pi = resolvePart(instances, k.part) orelse {
                reject(arena, diags, "keep-out: part '{s}' not found", .{k.part});
                continue;
            };
            try keepouts.append(arena, .{ .a = pi, .b = from_i, .min_mm = k.min_mm });
        } else if (k.net.len > 0) {
            if (resolveNet(nets, k.net) == null)
                reject(arena, diags, "keep-out: net '{s}' not in netlist", .{k.net});
            reject(arena, diags, "keep-out (net '{s}'): net-region keep-out not yet lowered (inert)", .{k.net});
        }
    }

    // Phase-2b aggressor-avoidance keep-outs: push a feedback/compensation
    // passive away from a switching-node / clock / RF passive (the inductor,
    // snubber, crystal, RF match) so the sensitive high-impedance FB node
    // doesn't couple to the aggressor. Synthesized into the SAME part-vs-part
    // keep-out machinery a hand `(keep-out …)` lowers to — search-only, so the
    // reported objective stays comparable. Always runs (the board force-solves).
    try synthAggressorKeepouts(arena, parts, nets, idx_of, &keepouts);
    const has_keepouts = keepouts.items.len > 0;

    // Constraint-DSL (group …) clusters. Resolve each ref; skip unresolved
    // (reported) and groups with <2 resolved members (nothing to cohese).
    for (c.groups) |g| {
        const m = try resolveGroupMembers(arena, instances, g.refs, diags);
        if (m.len >= 2) try groups.append(arena, makeGroupTerm(arena, m, parts, nets, idx_of));
    }

    // The design's own functional (group "name" (refs)) declarations — the same
    // groups the schematic/BOM use — are ALSO honoured as placement cohesion, so
    // an output filter's caps sit as one block with no (constraints) form needed.
    // (Unresolved refs are skipped silently; these are not authored constraints.)
    for (block.groups) |vg| {
        const m = try resolveGroupMembers(arena, instances, vg.members, null);
        if (m.len >= 2) try groups.append(arena, makeGroupTerm(arena, m, parts, nets, idx_of));
    }

    const has_groups = groups.items.len > 0;
    return .{
        .prox = try prox.toOwnedSlice(arena),
        .keepouts = try keepouts.toOwnedSlice(arena),
        .net_weight = net_weight,
        .input_rail = input_rail,
        .groups = try groups.toOwnedSlice(arena),
        .active = c.present or has_groups or auto_input or has_keepouts,
    };
}

/// Phase-2a: mark every detected input-rail net as a hot rail (so
/// `constraintCost`'s input-loop boost fires) when the design is an
/// integrated-module switcher — it carries a feedback net (a regulated
/// converter) but no discrete inductor (a discrete-L switcher is already
/// boosted by `classify`, so marking here would double-boost). `input_rail` is
/// index-aligned with `nets`; entries already set by a `(power-rail …)` stay
/// set. Returns true when it marked at least one rail (so the caller can flip
/// `Lowered.active` on — else `constraintCost` would fast-exit and skip the boost).
fn autoInputRails(parts: []const Part, nets: []const FlatNet, input_rail: []bool) bool {
    for (parts) |p| {
        if (isInductor(p.ref_des)) return false; // discrete-L switcher → classify handles it
    }
    var has_feedback = false;
    for (nets) |n| {
        if (module_policy.classifyNetName(n.name) == .feedback) {
            has_feedback = true;
            break;
        }
    }
    if (!has_feedback) return false; // no FB divider → not a regulated converter
    var marked = false;
    for (nets, 0..) |n, ni| {
        if (module_policy.classifyNetName(n.name) == .input_rail) {
            input_rail[ni] = true;
            marked = true;
        }
    }
    return marked;
}

/// Phase-2b: append a part-vs-part keep-out between every feedback passive and
/// every switching-node / clock / RF passive (the aggressors), so the solve
/// keeps the sensitive FB node clear of them. Hubs are excluded on both sides —
/// the IC legitimately carries the FB and SW pins; the rule is about the FB
/// *divider* versus the SW *node copper / inductor*. Keep-outs are inert
/// (zero cost) once the gap is met, so emitting all pairs is cheap and only
/// acts where the force layout would otherwise crowd them.
fn synthAggressorKeepouts(
    arena: std.mem.Allocator,
    parts: []const Part,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
    out: *std.ArrayListUnmanaged(KeepTerm),
) std.mem.Allocator.Error!void {
    const flags = try arena.alloc(std.EnumSet(module_policy.NetClass), parts.len);
    defer arena.free(flags);
    for (flags) |*f| f.* = std.EnumSet(module_policy.NetClass).initEmpty();
    for (nets) |net| {
        const cls = module_policy.classifyNetName(net.name);
        for (net.pins) |pin| {
            if (idx_of.get(pin.ref_des)) |pi| flags[pi].insert(cls);
        }
    }
    for (parts, 0..) |fp, fi| {
        if (fp.kind != .passive or !flags[fi].contains(.feedback)) continue;
        for (parts, 0..) |ap, ai| {
            if (ai == fi or ap.kind != .passive) continue;
            const aggressor = flags[ai].contains(.switch_node) or flags[ai].contains(.clock) or flags[ai].contains(.rf);
            if (aggressor) try out.append(arena, .{ .a = fi, .b = ai, .min_mm = AGGRESSOR_KEEPOUT_MM });
        }
    }
}

/// True when part index `p` is one of a group's resolved members.
fn memberOf(members: []const usize, p: usize) bool {
    for (members) |m| {
        if (m == p) return true;
    }
    return false;
}

/// Per-loop force/cost multiplier for bank-loop relief (index-aligned with
/// `loops`): `1 − relief` for a cap that is in a `(group …)` with ≥2 members on
/// the *same* power rail (a cap bank), else `1.0`. Position-invariant (membership
/// + rail are fixed for the solve), so it is computed once in `prepare` and read
/// by both `accumulateLoops` (force) and `constraintCost` (objective) so the two
/// stay consistent. `relief ≤ 0` ⇒ all `1.0` (relief off).
fn bankLoopScale(arena: std.mem.Allocator, loops: []const Loop, lowered: Lowered, relief: f64) std.mem.Allocator.Error![]const f64 {
    const scale = try arena.alloc(f64, loops.len);
    @memset(scale, 1.0);
    if (relief <= 0 or !lowered.active) return scale;
    const r = std.math.clamp(relief, 0.0, 1.0);
    for (lowered.groups) |g| {
        for (loops, 0..) |lp, li| {
            if (!memberOf(g.members, lp.cap)) continue;
            var bank: usize = 0;
            for (loops) |lp2| {
                if (lp2.pwr_net == lp.pwr_net and memberOf(g.members, lp2.cap)) bank += 1;
            }
            if (bank >= 2) scale[li] = @min(scale[li], 1.0 - r);
        }
    }
    return scale;
}

/// Resolve a group's member refs to part indices (in the arena). Unresolved refs
/// are reported via `diags` when provided, else skipped.
fn resolveGroupMembers(
    arena: std.mem.Allocator,
    instances: []const export_kicad.FlatInstance,
    refs: []const []const u8,
    diags: ?*std.ArrayListUnmanaged([]const u8),
) std.mem.Allocator.Error![]usize {
    var members: std.ArrayListUnmanaged(usize) = .empty;
    for (refs) |ref| {
        if (resolvePart(instances, ref)) |pi|
            try members.append(arena, pi)
        else if (diags) |d| {
            const msg = std.fmt.allocPrint(arena, "group: part '{s}' not found", .{ref}) catch continue;
            d.append(arena, msg) catch continue; // diag is best-effort; OOM just drops the hint
        }
    }
    return members.toOwnedSlice(arena);
}

/// Build a `GroupTerm` for `members`: the member set plus the hub it orbits (the
/// largest hub part) and the unit direction, in hub-local frame, from the hub
/// centre toward the hub pads the group connects to — used to zone the cluster to
/// the correct side of the IC. `hub = -1` (no zoning) when no hub/shared pad.
///
/// The direction is computed over the group's **non-ground** hub pads only.
/// Ground pads are scattered all around an IC (and a switcher's exposed pad sits
/// dead-centre), so folding them in averages the side away — an input bank wired
/// to a left-edge VIN pad would zone *right* purely because more GND pads happen
/// to sit on the right. The signature rail (VIN, VOUT, SW, …) is what defines a
/// group's side, so ground is excluded.
fn makeGroupTerm(arena: std.mem.Allocator, members: []usize, parts: []const Part, nets: []const FlatNet, idx_of: *std.StringHashMap(usize)) GroupTerm {
    _ = arena;
    var hub: i32 = -1;
    var best_area: f64 = 0;
    for (parts, 0..) |p, i| {
        if (p.kind != .hub) continue;
        // The hub a group orbits must not be a member of the group itself.
        if (memberOf(members, i)) continue;
        const area = p.hw * p.hh;
        if (area > best_area) {
            best_area = area;
            hub = @intCast(i);
        }
    }
    if (hub < 0) return .{ .members = members };
    const h: usize = @intCast(hub);
    const hub_ref = parts[h].ref_des;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var n: usize = 0;
    for (nets) |net| {
        if (isGroundName(shortName(net.name))) continue; // ground defines no side
        var touches = false;
        for (net.pins) |pp| {
            const pi = idx_of.get(pp.ref_des) orelse continue;
            if (memberOf(members, pi)) touches = true;
        }
        if (!touches) continue;
        for (net.pins) |pp| {
            if (!std.mem.eql(u8, pp.ref_des, hub_ref)) continue;
            const pad = padLocal(parts[h], pp.pin);
            if (pad.w == 0 and pad.h == 0) continue;
            sx += pad.x;
            sy += pad.y;
            n += 1;
        }
    }
    if (n == 0) return .{ .members = members, .hub = hub };
    const mag = std.math.hypot(sx, sy);
    if (mag < 1e-6) return .{ .members = members, .hub = hub };
    return .{ .members = members, .hub = hub, .dirx = sx / mag, .diry = sy / mag };
}

/// Validate a design's Phase-A constraints against its flattened netlist without
/// running a solve — the deterministic, LLM-free validator the doc requires.
/// Returns the list of human-readable rejections (empty ⇒ everything resolves).
/// Builds the same design model `solve` does. All output in `arena`.
pub fn validateConstraints(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    params: Params,
) std.mem.Allocator.Error![]const []const u8 {
    var prep = try prepare(arena, block, project_dir, params);
    var diags: std.ArrayListUnmanaged([]const u8) = .empty;
    _ = try resolveConstraints(arena, block, prep.instances, prep.nets, prep.parts, &prep.idx_of, &diags);
    return diags.toOwnedSlice(arena);
}

/// Resolve a `(placement-order …)` name to a flattened part index. Matches the
/// name the author wrote — the stable `origin_key` (survives ref-des renumbering,
/// so "C_VIN" still resolves after it is auto-assigned "C188") or the final
/// `ref_des` — then a `parent/child` suffix so a bare "C1" finds sub-block
/// "pwr/C1". Null when no part matches. `instances` is index-aligned with `parts`.
fn resolvePart(instances: []const export_kicad.FlatInstance, ref: []const u8) ?usize {
    for (instances, 0..) |inst, i| {
        if (std.mem.eql(u8, inst.origin_key, ref) or std.mem.eql(u8, inst.ref_des, ref)) return i;
    }
    for (instances, 0..) |inst, i| {
        const rd = inst.ref_des;
        if (rd.len > ref.len and rd[rd.len - ref.len - 1] == '/' and std.mem.endsWith(u8, rd, ref)) return i;
    }
    return null;
}

/// The IC pad a `(decouple … per-pin …)` cap decouples, read from its structural
/// origin key `value@PAD#replica` (built in `builders.emitDecoupleItems`). Null
/// when the key has no `@PAD#` segment — a non-per-pin decouple (`value#replica`)
/// or any named part (whose origin key is the source name).
fn decouplePinFromOrigin(origin_key: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, origin_key, '@') orelse return null;
    const hash = std.mem.indexOfScalarPos(u8, origin_key, at + 1, '#') orelse return null;
    const pin = origin_key[at + 1 .. hash];
    return if (pin.len > 0) pin else null;
}

fn prepare(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    params: Params,
) std.mem.Allocator.Error!Prepared {
    // Flatten the hierarchy exactly as the KiCad sync does, so parts inside
    // `(sub-block …)`s (hierarchical ref-des like "pwr/U1") and their merged
    // nets are included — a buck design is one sub-block, so `block.instances`
    // alone would be empty.
    var inst_list: std.ArrayListUnmanaged(export_kicad.FlatInstance) = .empty;
    try netlist_mod.collectInstances(arena, block, "", &inst_list, block.refStyle());
    var net_list: std.ArrayListUnmanaged(FlatNet) = .empty;
    try export_kicad.flattenAndMergeNets(arena, block, &net_list);
    const instances = inst_list.items;
    const nets = net_list.items;

    // Pin-count hint per ref: how many net endpoints it has (sizes fallback
    // boxes and is a decent proxy for footprint complexity).
    var pin_counts = std.StringHashMap(usize).init(arena);
    for (nets) |net| {
        for (net.pins) |pr| {
            const gop = try pin_counts.getOrPut(pr.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }
    }

    // Per-part pin classification (real ground/supply pins vs config straps),
    // keyed by component so a part type loaded N times parses its lib files
    // once. Only hubs are classified — a passive's pads are always real, and an
    // IC's GND/rail nets are the ones that also carry straps.
    var roles = try arena.alloc(pin_roles.PartRoles, instances.len);
    var roles_cache = std.StringHashMap(pin_roles.PartRoles).init(arena);

    // Per-footprint geometry cache, keyed by footprint name, mirroring
    // `roles_cache`. A board with 100 cap-0402s used to file-read + parse
    // `C_0402.sexp` 100 times per prepare — and prepare runs per drag-score
    // event. A *real* footprint's Geom is a pure function of (name, margin) and
    // margin is constant across a prepare, so caching by name is byte-identical.
    // Fallback geoms (missing file) depend on the per-instance pin-count hint, so
    // they are never cached — `g.fallback` gates the store.
    var geom_cache = std.StringHashMap(geometry.Geom).init(arena);

    var parts = try arena.alloc(Part, instances.len);
    var idx_of = std.StringHashMap(usize).init(arena);
    for (instances, 0..) |inst, i| {
        const hint = pin_counts.get(inst.ref_des) orelse 2;
        const g = blk: {
            if (geom_cache.get(inst.footprint)) |cached| break :blk cached;
            const loaded = geometry.load(arena, project_dir, inst.footprint, hint, params.bbox_margin);
            // Fallback geoms depend on the per-instance pin hint — never cache them.
            if (!loaded.fallback) try geom_cache.put(inst.footprint, loaded);
            break :blk loaded;
        };
        const is_hub = isHub(inst.ref_des);
        if (is_hub) {
            const gop = try roles_cache.getOrPut(inst.component);
            if (!gop.found_existing) gop.value_ptr.* = pin_roles.load(arena, project_dir, inst.component);
            roles[i] = gop.value_ptr.*;
        } else roles[i] = .{};
        parts[i] = .{
            .ref_des = inst.ref_des,
            .kind = if (is_hub) .hub else .passive,
            // Round courtyard half-extents up to the grid so that — with grid-
            // snapped centres — every courtyard edge lands on a 0.2 mm line and
            // parts abut cleanly. Rounding *up* never shrinks below the real
            // footprint, so clearance is preserved.
            .hw = if (params.grid_courtyards) ceilToGrid(g.hw) else g.hw,
            .hh = if (params.grid_courtyards) ceilToGrid(g.hh) else g.hh,
            .ccx = g.ccx,
            .ccy = g.ccy,
            .pads = g.pads,
            .fallback = g.fallback,
            .value = instValue(inst),
            .silk_lines = g.silk_lines,
            .silk_circles = g.silk_circles,
        };
        try idx_of.put(inst.ref_des, i);
    }

    // Per-part priority rank (0 = unranked everywhere now — `(placement-order …)`
    // was removed) and the explicit hub pin a cap's decoupling loop should target.
    const priority = try arena.alloc(u32, instances.len);
    @memset(priority, 0);
    const explicit_pin = try arena.alloc([]const u8, instances.len);
    for (explicit_pin) |*e| e.* = "";
    // A (decouple … per-pin N …) cap carries the IC pad it decouples in its
    // structural origin key `value@PAD#replica`; pin its loop to that pad so the
    // bypass loop targets the pin it serves (and the part shows that target on
    // the layout). These caps are auto-named, so this is the only way to pin them.
    // `(decouples rail)` opt-out flags, parallel to `explicit_pin` — caps that
    // serve the whole rail and so are exempt from the per-pin-decoupling lint.
    const rail_optout = try arena.alloc(bool, instances.len);
    @memset(rail_optout, false);
    for (instances, 0..) |inst, pi| {
        if (decouplePinFromOrigin(inst.origin_key)) |pin| explicit_pin[pi] = pin;
        // A `(decouples "IC" PIN)` instance binding pins the loop to that pad —
        // more authoritative than the structural-key default.
        if (inst.decouple_pin.len > 0) explicit_pin[pi] = inst.decouple_pin;
        if (inst.decouple_rail) rail_optout[pi] = true;
    }

    const built = try buildSprings(arena, nets, parts, &idx_of, roles, explicit_pin, rail_optout);
    classify(parts, built.loops, nets, params.cap_w_max, params.input_loop_boost, priority);
    // Declared rail currents (ports' `(current …)`, pins' `(i-typ …)`) → the
    // per-net congestion corridor widths `congestPitch` reads.
    g_net_current = try netCurrents(arena, block, nets);
    // Resolve + lower any Phase-A `(constraints …)` and publish to the thread's
    // `g_lowered` so `constraintCost` (the search-only objective delta) sees it.
    // Inert when the design authored none. Rejections are dropped on this hot
    // path; `validateConstraints` surfaces them for authoring.
    const lowered = try resolveConstraints(arena, block, instances, nets, parts, &idx_of, null);
    g_lowered = lowered;
    // Relaxation cohesion- and zoning-force gains (position-space twins of the
    // scalar `group_w` / `group_zone_w` terms in `constraintCost`).
    g_group_force = if (lowered.active) @max(0.0, params.group_w) * GROUP_FORCE_PER_W else 0;
    g_zone_force = if (lowered.active) @max(0.0, params.group_zone_w) * ZONE_FORCE_PER_W else 0;
    // Per-loop force relief for ≥2-member same-rail banks (twin of the scalar
    // `group_loop_relief`). Precomputed once: bank membership is position-invariant.
    g_loop_force_scale = try bankLoopScale(arena, built.loops, lowered, params.group_loop_relief);
    // Publish the courtyard-overlap allowance for the thread's collision helpers.
    // Capped at `bbox_margin` per side so the collision box stays ≥ the real
    // footprint extent (courtyard = ceilToGrid(extent+margin) ⇒ courtyard−margin
    // ≥ extent): only clearance bands overlap, never copper. Gated to the
    // multi-start band (≤ MULTISTART_MAX_PARTS) — that's where dense decap loops
    // benefit and the strict/overlap retry's 2× cost is affordable; big boards
    // have area to spare and the retry would double an already-long solve.
    g_collide_shrink = if (instances.len <= MULTISTART_MAX_PARTS)
        std.math.clamp(params.courtyard_overlap / 2, 0, params.bbox_margin)
    else
        0;
    // Routing/copper room left between courtyards (0 = touch).
    g_route_gap = @max(0.0, params.route_gap);
    // Reset the per-solve diagnostics the PCB-layout JSON reads back. No authored
    // PCB-placement spec exists any more, so this is always inert.
    g_placement_diag = .{};
    return .{
        .parts = parts,
        .idx_of = idx_of,
        .instances = instances,
        .nets = nets,
        .built = built,
        .priority = priority,
        .lowered = lowered,
        .block = block,
        .project_dir = project_dir,
    };
}

/// Decompose the objective for already-placed parts, surfaced term-by-term for
/// the score export. `lsum` is supplied by the caller — the analytic fixed-pad
/// surrogate (`surrogateLoops`) on the score path, so the reported objective is
/// the same smooth metric the optimizer minimises — and the objective is rebuilt
/// from its inductance term, so the headline matches.
fn breakdownWith(parts: []const Part, idx_of: *std.StringHashMap(usize), nets: []const FlatNet, params: Params, score: Score, lsum: LoopSums) Breakdown {
    // `al` is the *active* compactness term (what the objective minimizes);
    // `footprint` is always the courtyard bbox area — the universal yardstick the
    // UI shows so the two modes are comparable on the same scale.
    const al = tidinessPenalty(parts);
    const cong = congestionPenalty(parts, idx_of, nets);
    return .{
        .hpwl = score.hpwl_mm,
        .loop_raw = score.loop_mm, // = lsum.raw_mm — kept so it matches the headline length
        .loop_weighted = lsum.weighted_mm,
        // The scored loop metric: connection inductance (nH), value-weighted. The
        // objective minimizes this — not the loop length (the length is display only).
        .loop_nh = lsum.raw_nh,
        .loop_nh_weighted = lsum.weighted_nh,
        .alignment = al,
        .footprint = compactnessArea(parts),
        .congestion = cong,
        .objective = score.hpwl_mm + params.loop_w * lsum.weighted_nh +
            effAlignW(params) * al + params.w_congest * cong,
    };
}

/// Real routed-trace loop sums (raw + value-weighted) via the maze router — used
/// **only by the routed finishing passes** (`routedObjectiveCost` →
/// `routedPolish`), never the reported score (which is the smooth
/// surrogate — re-routing per pose makes it jagged) and never the inner relax.
/// Builds one grid over the placement, then routes each loop's power leg as actual
/// copper (cap pad → its pinned hub pin) detouring foreign pads; the cap span +
/// ground return (`loopGroundSpan`) add the rest of the physical loop. Falls back
/// to the analytic surrogate when a leg is unroutable or the board is too large to
/// grid, so a value is always produced.
fn routedLoops(
    arena: std.mem.Allocator,
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
) LoopSums {
    if (loops.len == 0) return .{ .raw_mm = 0, .weighted_mm = 0, .raw_nh = 0, .weighted_nh = 0 };
    var lr = router.LoopRouter.init(arena, parts, nets, idx_of, .{}) catch return surrogateLoops(parts, loops);
    if (!lr.ready) return surrogateLoops(parts, loops);
    var s = LoopSums{ .raw_mm = 0, .weighted_mm = 0, .raw_nh = 0, .weighted_nh = 0 };
    for (loops) |lp| {
        const cap_c = worldPadCenter(parts[lp.cap], lp.cap_pwr.x, lp.cap_pwr.y);
        const hub_c = worldPadCenter(parts[lp.hub], lp.hub_pwr_pin.x, lp.hub_pwr_pin.y);
        const routed = lr.legLen(cap_c, hub_c, lp.pwr_net) catch null;
        const pwr = if (routed) |r| r else surrogatePwrLeg(parts, lp) + UNROUTABLE_PENALTY_MM;
        const m = loopMetric(parts, lp, pwr);
        s.raw_mm += m.mm;
        s.weighted_mm += lp.weight * m.mm;
        s.raw_nh += m.nh;
        s.weighted_nh += lp.weight * m.nh;
    }
    return s;
}

/// Weighted routed-loop length over a *subset* of `loops`: `match=true` sums only
/// the loops owned by cap index `cap`, `match=false` sums all the others. Same
/// routing as `routedLoops` (the grid is built from every part, so a leg still
/// detours around the whole board) — it just sums a slice. `routedPolish` re-routes
/// only the cap it is currently moving (`match=true`) each candidate, and adds the
/// others' length as a baseline measured once per part — cutting the routes per
/// candidate from "every loop" to "this cap's loop(s)". A moved cap obstructing a
/// foreign loop is a second-order effect, re-measured when the next part is polished.
fn routedSubsetWeighted(
    arena: std.mem.Allocator,
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    cap: usize,
    match: bool,
) f64 {
    var weighted: f64 = 0;
    var lr_opt: ?router.LoopRouter = router.LoopRouter.init(arena, parts, nets, idx_of, .{}) catch null;
    const ready = if (lr_opt) |lr| lr.ready else false;
    for (loops) |lp| {
        if ((lp.cap == cap) != match) continue;
        const pwr = if (ready) blk: {
            const cap_c = worldPadCenter(parts[lp.cap], lp.cap_pwr.x, lp.cap_pwr.y);
            const hub_c = worldPadCenter(parts[lp.hub], lp.hub_pwr_pin.x, lp.hub_pwr_pin.y);
            const routed = lr_opt.?.legLen(cap_c, hub_c, lp.pwr_net) catch null;
            break :blk if (routed) |r| r else surrogatePwrLeg(parts, lp) + UNROUTABLE_PENALTY_MM;
        } else surrogatePwrLeg(parts, lp);
        weighted += lp.weight * loopMetric(parts, lp, pwr).nh;
    }
    return weighted;
}

/// Apply a cached layout to `parts` when it covers every one (matched by
/// ref-des) *and* the result has no courtyard overlap. Returns true on a clean
/// hit (positions applied, optimizer skipped); false on a miss, a partial/
/// stale cache, or a cache that now overlaps (e.g. courtyard sizes changed) —
/// leaving `parts` for the optimizer to re-solve.
fn applyCached(parts: []Part, cached: ?[]const RefPose) bool {
    const poses = cached orelse return false;
    if (parts.len == 0) return false;
    var matched: usize = 0;
    for (parts) |*p| {
        for (poses) |rp| {
            if (std.mem.eql(u8, rp.ref, p.ref_des)) {
                p.x = rp.x;
                p.y = rp.y;
                p.rot = rp.rot;
                p.side = rp.side;
                p.locked = rp.locked;
                matched += 1;
                break;
            }
        }
    }
    return matched == parts.len and !anyOverlap(parts);
}

/// True if any two parts' keepout boxes overlap (rotation-aware).
fn anyOverlap(parts: []const Part) bool {
    for (parts) |*p| {
        if (overlapsAny(parts, p)) return true;
    }
    return false;
}

/// Robust overlap removal: the continuous force pass converges smoothly where
/// the grid-only nudger can oscillate on a tight pack (e.g. large escape-stub
/// keepouts), then snap + grid-legalize so the result is on-grid and clean.
fn legalizeFinal(parts: []Part) void {
    legalize(parts, FINAL_CLEAR);
    snapToGrid(parts);
    legalizeOnGrid(parts);
}

/// Half-window (grid cells) the priority-cap tuck scans — wider than the polish
/// window so a bypass cap can be pulled the full width of a small IC onto its
/// pin (±`TIGHTEN_CELLS`·`GRID_MM` ≈ ±2.8 mm).
const TIGHTEN_CELLS: i64 = 28;

/// Tuck every *declared-priority* decoupling cap onto its IC pin. For each loop
/// whose cap was ranked in a `(placement-order …)` (priority > 0), greedily
/// search the cap's (position × rotation) over a wide grid window for the spot
/// that minimizes *its own* hot loop (power leg + ground return), collision-
/// checked. Highest-priority caps tuck first, so when several share a rail the
/// most important one claims the pin and the rest stack behind it. The search
/// starts from the current pose as the incumbent, so a cap's loop can only get
/// shorter — never worse. Each accepted tuck is re-routed and reverted if it
/// would drop a net, so tightening can never reduce routability. No-op on big
/// boards / when nothing is ranked.
fn tightenPriorityLoops(arena: std.mem.Allocator, parts: []Part, loops: []const Loop, nets: []const FlatNet, priority: []const u32) void {
    if (parts.len < 2 or parts.len > POLISH_MAX_PARTS) return;
    if (loops.len > maxParts) return;
    // Nothing ranked ⇒ skip entirely (don't even pay for the baseline route).
    var any = false;
    for (loops) |lp| {
        if (lp.cap < priority.len and priority[lp.cap] > 0) any = true;
    }
    if (!any) return;
    // Process loops in descending cap priority (highest first).
    var order_buf: [maxParts]usize = undefined;
    const order = order_buf[0..loops.len];
    for (order, 0..) |*o, i| o.* = i;
    std.sort.pdq(usize, order, LoopPriCtx{ .loops = loops, .priority = priority }, loopPriDesc);
    var baseline = routedCount(arena, parts, nets);
    for (order) |li| {
        const lp = loops[li];
        if (lp.cap >= priority.len or priority[lp.cap] == 0) continue;
        const p = &parts[lp.cap];
        const sx = p.x;
        const sy = p.y;
        const sr = p.rot;
        tuckCap(parts, lp);
        if (p.x == sx and p.y == sy and p.rot == sr) continue; // no move found
        const rc = routedCount(arena, parts, nets);
        if (rc < baseline) {
            p.x = sx; // the tuck would cost a net — back it out
            p.y = sy;
            p.rot = sr;
        } else {
            baseline = rc;
        }
    }
}

/// How many multi-pad nets the in-tool router connects for the current part
/// poses — used to veto a tuck that would drop a net. Builds a throwaway
/// `Placement` (no links/loops/stubs needed) and routes it; 0 if it can't grid.
fn routedCount(arena: std.mem.Allocator, parts: []Part, nets: []const FlatNet) usize {
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (parts) |p| {
        minx = @min(minx, keepCx(p) - keepHw(p));
        miny = @min(miny, keepCy(p) - keepHh(p));
        maxx = @max(maxx, keepCx(p) + keepHw(p));
        maxy = @max(maxy, keepCy(p) + keepHh(p));
    }
    if (!std.math.isFinite(minx)) return 0;
    const pl = Placement{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = minx,
        .miny = miny,
        .maxx = maxx,
        .maxy = maxy,
        .generated = true,
    };
    const r = router.route(arena, pl, .{}) catch return 0;
    return r.routed;
}

const LoopPriCtx = struct { loops: []const Loop, priority: []const u32 };

/// Order loops by descending cap priority (stable by loop index on ties).
fn loopPriDesc(ctx: LoopPriCtx, a: usize, b: usize) bool {
    const pa: u32 = if (ctx.loops[a].cap < ctx.priority.len) ctx.priority[ctx.loops[a].cap] else 0;
    const pb: u32 = if (ctx.loops[b].cap < ctx.priority.len) ctx.priority[ctx.loops[b].cap] else 0;
    if (pa != pb) return pa > pb;
    return a < b;
}

/// Greedily move `lp`'s cap to the pose (over a wide grid window × the four
/// rotations) that minimizes its power-leg cost — constrained to be collision-
/// free *and* still docked against a neighbour, so the cap tightens onto its IC
/// pin without floating off into a routing channel.
fn tuckCap(parts: []Part, lp: Loop) void {
    const p = &parts[lp.cap];
    const ox = p.x;
    const oy = p.y;
    var best = loopLen(parts, lp);
    var bx = ox;
    var by = oy;
    var br = p.rot;
    // A pinned rotation is decided (spec / series pairing) — search position only.
    const pinned = [_]f64{p.rot};
    const rot_cands: []const f64 = if (p.rot_pin != .none) &pinned else &ROT_CAND;
    for (rot_cands) |r| {
        var dy: i64 = -TIGHTEN_CELLS;
        while (dy <= TIGHTEN_CELLS) : (dy += 1) {
            var dx: i64 = -TIGHTEN_CELLS;
            while (dx <= TIGHTEN_CELLS) : (dx += 1) {
                p.rot = r;
                p.x = ox + @as(f64, @floatFromInt(dx)) * GRID_MM;
                p.y = oy + @as(f64, @floatFromInt(dy)) * GRID_MM;
                if (overlapsAny(parts, p)) continue;
                if (!touchesOther(parts, p, lp.cap)) continue; // stay docked
                const c = loopLen(parts, lp);
                if (c < best - 1e-9) {
                    best = c;
                    bx = p.x;
                    by = p.y;
                    br = r;
                }
            }
        }
    }
    p.x = bx;
    p.y = by;
    p.rot = br;
}

/// True if part `p` (at its current pose) shares a courtyard edge with some part
/// other than itself — i.e. it's docked against the blob, not floating.
fn touchesOther(parts: []const Part, p: *const Part, self_idx: usize) bool {
    for (parts, 0..) |o, j| {
        if (j == self_idx) continue;
        if (courtyardEdge(p.*, o)) return true;
    }
    return false;
}

/// Weight the ground-return span gets in the tuck cost. On this 4-layer stack
/// the cap's ground return is a *via to the GND plane* (negligible copper), so
/// the real routed copper the author sees is the power leg — that dominates;
/// the small ground term only breaks ties toward a sane cap orientation.
const TUCK_GND_W: f64 = 0.15;

/// Tuck cost for one cap: its power leg (the real routed supply trace, cap power
/// pad → its pinned IC power pad) plus a light ground-span tiebreaker.
fn loopLen(parts: []const Part, lp: Loop) f64 {
    return surrogatePwrLeg(parts, lp) + TUCK_GND_W * loopGroundSpan(parts, lp);
}

/// True when two courtyards share an *edge* (not just a corner): a zero gap on
/// one axis with a positive projection overlap on the other. Rendered courtyard
/// (`effHw`/`effHh` about the centre).
fn courtyardEdge(a: Part, b: Part) bool {
    const gx = @abs(a.x - b.x) - (effHw(a) + effHw(b));
    const gy = @abs(a.y - b.y) - (effHh(a) + effHh(b));
    return (@abs(gx) <= COMPACT_EPS and gy < -COMPACT_EPS) or
        (@abs(gy) <= COMPACT_EPS and gx < -COMPACT_EPS);
}

/// A solved pose snapshot (used to retain the best multi-start arrangement).
const Pose = struct { x: f64, y: f64, rot: f64 };

/// One placement attempt from seed `s`: seed, relax, then alternately refine
/// rotations and re-relax, and finally legalize + snap so the result is
/// grid-aligned and overlap-free. Small boards ring-seed (so multi-start
/// explores side-arrangements); large boards grid-seed (overlap-free start).
fn runStart(
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    built: Built,
    s: usize,
    rounds: usize,
    params: Params,
) void {
    if (parts.len <= MULTISTART_MAX_PARTS) seedRing(parts, s) else seedGrid(parts);
    // Pin each series part (buck inductor across LX1/LX2, a feedback R) to the
    // rotation that faces each pad at its own hub pin — HPWL is blind to the
    // two-legged orientation, so this must be decided geometrically before the
    // rotation-searching passes below run. Runs after seeding (needs the hub's
    // seeded rotation) and pins `rot_pin = .series`, which the search passes then
    // honour ("search position only"). No-op for boards with no series pairs.
    applySeriesRotations(parts, built.series);
    relax(parts, built.springs, built.loops);
    // Coordinate descent: alternately pick each passive's best rotation and
    // re-relax positions, so a flipped cap's pad lands against its IC pin.
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        optimizeRotations(parts, idx_of, nets, built.loops, params);
        relax(parts, built.springs, built.loops);
    }
    legalize(parts, FINAL_CLEAR); // leave ≥ a grid cell so snapping can't re-overlap
    snapToGrid(parts);
    legalizeOnGrid(parts); // safety net: resolve any snap-induced overlap, on-grid
}

/// Final refinement on the *routed* objective: a greedy per-part position ×
/// rotation grid search (several sweeps) that scores every candidate with
/// `routedObjectiveCost` — the real maze-routed loop length, the same metric the
/// headline reports. A surrogate-driven tuck settles parts by a straight
/// edge-to-edge gap, which can leave a cap on a rotation/side the router then
/// routes long; this pass re-tucks each part to what actually routes short. Runs
/// once on the finished layout, small boards only (one layout, so the router cost
/// is bounded — one route per candidate cell). The window is deliberately small
/// (`ROUTED_POLISH_CELLS`): a local tuck/flip, not a re-place, so it never undoes
/// the global arrangement already chosen.
fn routedPolish(
    arena: std.mem.Allocator,
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    params: Params,
) void {
    if (parts.len < 2 or parts.len > ROUTED_POLISH_MAX_PARTS or loops.len == 0) return;
    // Only the decoupling caps (parts that own a loop) drive the routed term, so
    // those are the only parts worth the per-candidate route. Resistors/other
    // passives are left where the surrogate polish + compaction placed them.
    var in_loop = [_]bool{false} ** maxParts;
    for (loops) |lp| in_loop[lp.cap] = true;
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();

    // Snapshot the finished layout + its true routed objective. The greedy sweeps
    // below only accept improving moves, but the closing snap/legalize can nudge a
    // part off its chosen cell; the gate at the end reverts the whole pass if that
    // ever leaves the board worse than it started, so routedPolish is never harmful.
    var before: [maxParts]Pose = undefined;
    for (parts, 0..) |p, i| before[i] = .{ .x = p.x, .y = p.y, .rot = p.rot };
    _ = scratch.reset(.retain_capacity);
    const before_cost = routedObjectiveCost(scratch.allocator(), parts, idx_of, nets, loops, params);

    var sweep: usize = 0;
    while (sweep < ROUTED_POLISH_SWEEPS) : (sweep += 1) {
        var improved = false;
        for (parts, 0..) |*p, i| {
            if (p.kind == .hub or !in_loop[i]) continue;
            if (routedPolishPart(&scratch, parts, idx_of, nets, loops, i, params)) improved = true;
        }
        if (!improved) break;
    }
    snapToGrid(parts);
    legalizeOnGrid(parts);

    _ = scratch.reset(.retain_capacity);
    const after_cost = routedObjectiveCost(scratch.allocator(), parts, idx_of, nets, loops, params);
    if (after_cost > before_cost + 1e-6) {
        for (parts, 0..) |*p, i| {
            p.x = before[i].x;
            p.y = before[i].y;
            p.rot = before[i].rot;
        }
    }
}

/// The routed objective `routedPolishPart` minimises for one candidate: HPWL +
/// alignment over the live positions, plus the loop term split into the fixed
/// `others_w` baseline and the freshly-routed loops owned by cap `cap`.
/// `scratch` is reset before the route so the per-candidate router grid is freed.
fn routedPolishCost(
    scratch: *std.heap.ArenaAllocator,
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    params: Params,
    cap: usize,
    others_w: f64,
) f64 {
    _ = scratch.reset(.retain_capacity);
    const focus_w = routedSubsetWeighted(scratch.allocator(), parts, idx_of, nets, loops, cap, true);
    const cong = if (params.w_congest != 0) params.w_congest * congestionPenalty(parts, idx_of, nets) else 0;
    return wireScore(parts, idx_of, nets) + params.loop_w * (others_w + focus_w) +
        effAlignW(params) * tidinessPenalty(parts) + cong;
}

/// Per-part routed tuck: pick the (position, rotation) over a small grid window
/// that most lowers the routed objective, holding the others fixed. For speed it
/// re-routes only the loop(s) owned by the moved cap `i` per
/// candidate (`routedSubsetWeighted` with `match=true`) and adds the other loops'
/// length (`others_w`) as a baseline measured once — the others don't move, so
/// the only thing that changes cell-to-cell is this cap's own leg.
fn routedPolishPart(
    scratch: *std.heap.ArenaAllocator,
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    i: usize,
    params: Params,
) bool {
    const p = &parts[i];
    const ox = p.x;
    const oy = p.y;
    // The loops not owned by `i`, routed once at `i`'s current position — the fixed
    // part of the objective while `i` is tucked. (A moved `i` obstructing one of
    // these is second-order; it is re-measured when the next part is polished.)
    _ = scratch.reset(.retain_capacity);
    const others_w = routedSubsetWeighted(scratch.allocator(), parts, idx_of, nets, loops, i, false);
    var best_cost = routedPolishCost(scratch, parts, idx_of, nets, loops, params, i, others_w);
    var best_x = ox;
    var best_y = oy;
    var best_rot = p.rot;
    var improved = false;
    // A pinned rotation is decided (spec / series pairing) — search position only.
    const pinned = [_]f64{p.rot};
    const rot_cands: []const f64 = if (p.rot_pin != .none) &pinned else &ROT_CAND;
    for (rot_cands) |r| {
        var dy: i64 = -ROUTED_POLISH_CELLS;
        while (dy <= ROUTED_POLISH_CELLS) : (dy += 1) {
            var dx: i64 = -ROUTED_POLISH_CELLS;
            while (dx <= ROUTED_POLISH_CELLS) : (dx += 1) {
                p.rot = r;
                p.x = ox + @as(f64, @floatFromInt(dx)) * GRID_MM;
                p.y = oy + @as(f64, @floatFromInt(dy)) * GRID_MM;
                if (overlapsAny(parts, p)) continue;
                const c = routedPolishCost(scratch, parts, idx_of, nets, loops, params, i, others_w);
                if (c < best_cost - 1e-9) {
                    best_cost = c;
                    best_x = p.x;
                    best_y = p.y;
                    best_rot = r;
                    improved = true;
                }
            }
        }
    }
    p.x = best_x;
    p.y = best_y;
    p.rot = best_rot;
    return improved;
}

/// True if `p`'s courtyard overlaps any other part's (rotation-aware).
/// Parts on opposite board sides never collide.
fn overlapsAny(parts: []const Part, p: *const Part) bool {
    for (parts) |*o| {
        if (o == p) continue;
        if (o.side != p.side) continue;
        const ox = (keepHw(p.*) + keepHw(o.*)) - @abs(keepCx(p.*) - keepCx(o.*));
        const oy = (keepHh(p.*) + keepHh(o.*)) - @abs(keepCy(p.*) - keepCy(o.*));
        if (ox > 1e-9 and oy > 1e-9) return true;
    }
    return false;
}

/// Snap every part centre to the `GRID_MM` grid, so exported and displayed
/// positions are grid-aligned (the interactive page drags on the same grid).
fn snapToGrid(parts: []Part) void {
    for (parts) |*p| {
        p.x = @round(p.x / GRID_MM) * GRID_MM;
        p.y = @round(p.y / GRID_MM) * GRID_MM;
    }
}

/// Round a length up to the next `GRID_MM` multiple. The `1e-9` slack keeps a
/// length already on the grid from being bumped a whole step by float error —
/// it matters when the input is constructed to land exactly on a grid line
/// (e.g. the courtyard editor's offset mode stores `ceilToGrid(gap) - margin`,
/// so `stored + margin` reloads back onto the grid). The editor mirrors this
/// rule with its own `courtCeilGrid` so its preview matches what the placer draws.
fn ceilToGrid(v: f64) f64 {
    return @ceil(v / GRID_MM - 1e-9) * GRID_MM;
}

/// Extra clearance the final legalization leaves between courtyards, so the
/// subsequent grid snap (≤ half a cell per axis) cannot push them into
/// overlap.
const FINAL_CLEAR: f64 = GRID_MM;

// ── Rotation ─────────────────────────────────────────────────────────────

/// Candidate part rotations (degrees, CCW). 0/180 keep the pad axis
/// horizontal; 90/270 make it vertical — and 0 vs 180 swaps which pad is
/// pin-1, which is what lets a cap orient its power/ground pads to the IC.
const ROT_CAND = [_]f64{ 0, 90, 180, 270 };

/// Rotate a footprint-local offset by `rot` (CCW, matching the page's
/// `wpt()`). Only the four right-angle cases occur, so this is exact.
fn rotateLocal(lx: f64, ly: f64, rot: f64) Pt {
    return switch (@as(i64, @intFromFloat(@round(@mod(rot, 360))))) {
        90 => .{ .x = -ly, .y = lx },
        180 => .{ .x = -lx, .y = -ly },
        270 => .{ .x = ly, .y = -lx },
        else => .{ .x = lx, .y = ly },
    };
}

/// World position of a footprint-local point on `p`, honouring its rotation
/// and board side (a bottom part mirrors local x before rotating — see `Side`).
/// Rotation is one of {0,90,180,270}; the `rot == 0` top-side identity is by
/// far the commonest case (every hub, and unrotated passives) and the inner
/// loops call this millions of times, so it skips `rotateLocal`'s
/// `@mod`/`@round`/switch.
fn worldPt(p: Part, lx: f64, ly: f64) Pt {
    const mlx = if (p.side == .bottom) -lx else lx;
    if (p.rot == 0) return .{ .x = p.x + mlx, .y = p.y + ly };
    const r = rotateLocal(mlx, ly, p.rot);
    return .{ .x = p.x + r.x, .y = p.y + r.y };
}

/// World centre (mm) of a footprint-local point on `p`, honouring rotation.
/// Public so the router can place trace endpoints on pads.
pub fn worldPadCenter(p: Part, lx: f64, ly: f64) [2]f64 {
    const w = worldPt(p, lx, ly);
    return .{ w.x, w.y };
}

/// World-space axis-aligned rectangle of pad `pr` on part `p` (its size swaps
/// on a quarter turn; right-angle rotation keeps it axis-aligned). The `rot == 0`
/// identity is the hot case (hub pads — the loop-leg scan's inner term), so it
/// bypasses `worldPt`/`isQuarter` entirely.
fn worldRect(p: Part, pr: PadRect) Rect {
    if (p.rot == 0) {
        const mx = if (p.side == .bottom) -pr.x else pr.x;
        const hw0 = pr.w / 2;
        const hh0 = pr.h / 2;
        return .{ .x0 = p.x + mx - hw0, .y0 = p.y + pr.y - hh0, .x1 = p.x + mx + hw0, .y1 = p.y + pr.y + hh0 };
    }
    const c = worldPt(p, pr.x, pr.y);
    const hw = if (isQuarter(p.rot)) pr.h / 2 else pr.w / 2;
    const hh = if (isQuarter(p.rot)) pr.w / 2 else pr.h / 2;
    return .{ .x0 = c.x - hw, .y0 = c.y - hh, .x1 = c.x + hw, .y1 = c.y + hh };
}

/// On one axis, the nearest coordinates on intervals [a0,a1] and [b0,b1]: the
/// facing edges if disjoint, else their shared midpoint. Returns {on a, on b}.
fn nearestSpan(a0: f64, a1: f64, b0: f64, b1: f64) struct { a: f64, b: f64 } {
    if (a1 < b0) return .{ .a = a1, .b = b0 };
    if (b1 < a0) return .{ .a = a0, .b = b1 };
    const m = (@max(a0, b0) + @min(a1, b1)) / 2;
    return .{ .a = m, .b = m };
}

/// Representative nearest points on two rects: {point on a, point on b}.
/// The distance between them is the edge-to-edge gap (0 if they touch).
fn nearestPoints(a: Rect, b: Rect) struct { a: Pt, b: Pt } {
    const sx = nearestSpan(a.x0, a.x1, b.x0, b.x1);
    const sy = nearestSpan(a.y0, a.y1, b.y0, b.y1);
    return .{ .a = .{ .x = sx.a, .y = sy.a }, .b = .{ .x = sx.b, .y = sy.b } };
}

/// Edge-to-edge gap between two axis-aligned rects (0 if touching/overlapping).
fn rectGap(a: Rect, b: Rect) f64 {
    const gx = @max(0.0, @max(a.x0 - b.x1, b.x0 - a.x1));
    const gy = @max(0.0, @max(a.y0 - b.y1, b.y0 - a.y1));
    return std.math.hypot(gx, gy);
}

/// Nearest of `hub_pads` (footprint-local rects on `hub`) to cap rect `cr`
/// (already in world space): its world rect and the edge-to-edge gap. Used by
/// the relaxation force (cheap, obstacle-blind).
fn nearestHubPad(cr: Rect, hub: Part, hub_pads: []const PadRect) struct { rect: Rect, gap: f64 } {
    var best_gap: f64 = std.math.inf(f64);
    var best: Rect = cr;
    for (hub_pads) |pr| {
        const hr = worldRect(hub, pr);
        const g = rectGap(cr, hr);
        if (g < best_gap) {
            best_gap = g;
            best = hr;
        }
    }
    return .{ .rect = best, .gap = best_gap };
}

/// Top signal layer → GND plane (L1→L2) spacing in mm. The decoupling loop's
/// ground return drops from the cap's GND pad through a via to the plane, runs
/// laterally in the plane, and rises through a via at the IC's GND pad — so the
/// loop counts this twice (one via down at the cap, one up at the IC). Per the
/// 4-layer stackup the router assumes; tune to the real board's L1→L2 prepreg.
const LAYER_GAP_MM: f64 = 0.2;

/// Penalty (mm) added to a loop's power leg when the maze router can't connect
/// the cap to its pinned hub pin (a fully blocked or boxed-in placement). Keeps
/// an unroutable loop visibly worse than any routable one in the score.
const UNROUTABLE_PENALTY_MM: f64 = 10.0;

/// Per-rank loop-weight step from a `(placement-order …)`: a cap at priority
/// rank `r` (1 = last listed, K = first listed) gets weight ≥ `1 + r·STEP`, so a
/// declared order dominates the value-based weighting and pulls the first-listed
/// caps tightest. Unranked caps (rank 0) keep their value weight.
const PRIORITY_STEP: f64 = 0.5;

/// Order two pad numbers: numerically when both parse as integers (so "2" < "10"),
/// else lexicographically (BGA "A1"/"B2"). Picks the default pinned supply pad.
fn pinLess(a: []const u8, b: []const u8) bool {
    const ai: ?i64 = std.fmt.parseInt(i64, a, 10) catch null;
    const bi: ?i64 = std.fmt.parseInt(i64, b, 10) catch null;
    if (ai != null and bi != null) return ai.? < bi.?;
    return std.mem.lessThan(u8, a, b);
}

/// True when the part is rotated a quarter turn (its courtyard extents swap).
fn isQuarter(rot: f64) bool {
    const r = @mod(@round(rot), 360);
    return r == 90 or r == 270;
}

/// Rotation-aware courtyard half-extents (swap on a quarter turn).
fn effHw(p: Part) f64 {
    return if (isQuarter(p.rot)) p.hh else p.hw;
}
fn effHh(p: Part) f64 {
    return if (isQuarter(p.rot)) p.hw else p.hh;
}

/// World-space centre of the part's courtyard box: the pose plus the rotated
/// (and side-mirrored) courtyard offset — equal to the pose for the common
/// origin-centred box.
fn courtCx(p: Part) f64 {
    return if (p.ccx == 0 and p.ccy == 0) p.x else worldPt(p, p.ccx, p.ccy).x;
}
fn courtCy(p: Part) f64 {
    return if (p.ccx == 0 and p.ccy == 0) p.y else worldPt(p, p.ccx, p.ccy).y;
}

/// Collision-keepout box used by every overlap/repulsion test: the escape-stub
/// box when set (`khw≥0`), else the courtyard box about its own centre
/// (sentinel `khw<0` ⇒ identical to the pre-stub behaviour). The centre offset
/// rotates with the part; the half-extents swap on a quarter turn.
fn keepCx(p: Part) f64 {
    return if (p.keep.hw < 0) courtCx(p) else worldPt(p, p.keep.ox, p.keep.oy).x;
}
fn keepCy(p: Part) f64 {
    return if (p.keep.hw < 0) courtCy(p) else worldPt(p, p.keep.ox, p.keep.oy).y;
}
fn keepHw(p: Part) f64 {
    const base = if (p.keep.hw < 0) effHw(p) else (if (isQuarter(p.rot)) p.keep.hh else p.keep.hw);
    return @max(0.0, base - g_collide_shrink) + g_route_gap;
}
fn keepHh(p: Part) f64 {
    const base = if (p.keep.hw < 0) effHh(p) else (if (isQuarter(p.rot)) p.keep.hw else p.keep.hh);
    return @max(0.0, base - g_collide_shrink) + g_route_gap;
}

/// Build a breakout stub for every pad on an *unaccounted* net — one whose pins
/// all belong to a single part (a single-component net like RFIN/LNAOUT that
/// leaves the board). Ground and no-connect nets are excluded; multi-component
/// nets (VDD with decoupling, etc.) already steer the placement via springs.
fn buildEscapeStubs(
    arena: std.mem.Allocator,
    nets: []const FlatNet,
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
) std.mem.Allocator.Error![]const Stub {
    var list: std.ArrayListUnmanaged(Stub) = .empty;
    for (nets, 0..) |net, ni| {
        const sn = shortName(net.name);
        if (isGroundName(sn) or isNoConnect(sn)) continue;
        var only: ?usize = null;
        var single = true;
        for (net.pins) |pr| {
            const i = idx_of.get(pr.ref_des) orelse continue;
            if (only) |o| {
                if (o != i) {
                    single = false;
                    break;
                }
            } else only = i;
        }
        const pi = only orelse continue;
        if (!single) continue;
        for (net.pins) |pr| {
            const i = idx_of.get(pr.ref_des) orelse continue;
            if (i != pi) continue;
            const pad = padLocal(parts[i], pr.pin);
            const d = escapeDir(parts[i], pad.x, pad.y);
            try list.append(arena, .{
                .part = i,
                .ax = pad.x,
                .ay = pad.y,
                .bx = pad.x + d.x * ESCAPE_STUB_MM,
                .by = pad.y + d.y * ESCAPE_STUB_MM,
                .net = @intCast(ni),
            });
        }
    }
    return list.toOwnedSlice(arena);
}

/// Outward (away-from-centre) axis-aligned unit direction for a pad at local
/// (px,py): along whichever axis the pad sits closest to the courtyard edge.
fn escapeDir(p: Part, px: f64, py: f64) Pt {
    const rx = if (p.hw > 1e-9) @abs(px) / p.hw else 0;
    const ry = if (p.hh > 1e-9) @abs(py) / p.hh else 0;
    if (rx >= ry) return .{ .x = if (px < 0) -1 else 1, .y = 0 };
    return .{ .x = 0, .y = if (py < 0) -1 else 1 };
}

/// Grow each part's keepout box to the union of its courtyard and its escape
/// stubs' tips, so the repulsion/legalization keep neighbours out of the
/// reserved corridor. Parts with no stub keep the sentinel (`khw<0`).
fn applyKeepout(parts: []Part, stubs: []const Stub) void {
    for (parts, 0..) |*p, i| {
        var x0 = p.ccx - p.hw;
        var x1 = p.ccx + p.hw;
        var y0 = p.ccy - p.hh;
        var y1 = p.ccy + p.hh;
        var has = false;
        for (stubs) |st| {
            if (st.part != i) continue;
            has = true;
            x0 = @min(x0, st.bx);
            x1 = @max(x1, st.bx);
            y0 = @min(y0, st.by);
            y1 = @max(y1, st.by);
        }
        if (!has) continue;
        p.keep = .{ .ox = (x0 + x1) / 2, .oy = (y0 + y1) / 2, .hw = (x1 - x0) / 2, .hh = (y1 - y0) / 2 };
    }
}

/// True for a no-connect net name (its single pin needs no breakout).
fn isNoConnect(name: []const u8) bool {
    if (std.mem.eql(u8, name, "NC") or std.mem.eql(u8, name, "DNC")) return true;
    return std.mem.startsWith(u8, name, "unconnected") or std.mem.startsWith(u8, name, "no_connect");
}

/// Coordinate descent over rotation: for each part, set the 0/90/180/270°
/// that minimizes the global objective (HPWL + weighted loop). On a
/// single-hub module the hub stays at 0° — its rotation is a degenerate
/// global frame turn that changes no relative distance — but with two or
/// more hubs their *relative* orientation is real (which edges face each
/// other decides every inter-hub net), so multi-hub boards search hubs too.
/// Pinned rotations (spec `(rot …)` / series pairing) are decided, not
/// searched — same rule as every other rotation search.
fn optimizeRotations(
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    params: Params,
) void {
    var hub_count: usize = 0;
    for (parts) |p| {
        if (p.kind == .hub) hub_count += 1;
    }
    for (parts) |*p| {
        if (p.rot_pin != .none) continue;
        if (p.kind == .hub and hub_count < 2) continue;
        var best_rot = p.rot;
        var best_cost = objectiveCost(parts, idx_of, nets, loops, params);
        for (ROT_CAND) |r| {
            p.rot = r;
            const c = objectiveCost(parts, idx_of, nets, loops, params);
            if (c < best_cost - 1e-9) {
                best_cost = c;
                best_rot = r;
            }
        }
        p.rot = best_rot;
    }
}

/// Scalar objective the rotation/polish/multi-start search minimizes:
/// wirelength(RSMT) + `LOOP_W`·(value-weighted loop inductance) + `effAlignW`·
/// (alignment) + `W_CONGEST`·(routing congestion). The *displayed* score
/// (`scoreLayout`) stays plain wirelength + loop length — these extra rules only
/// steer placement, they don't change the headline numbers.
fn objectiveCost(
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    params: Params,
) f64 {
    const hpwl = wireScore(parts, idx_of, nets);
    // Congestion is a grid pass over every net — skip it entirely when disabled
    // (`w_congest == 0`) so a speed-conscious user reclaims it on sparse boards
    // where it contributes nothing anyway.
    const cong = if (params.w_congest != 0) params.w_congest * congestionPenalty(parts, idx_of, nets) else 0;
    return hpwl + params.loop_w * weightedLoop(parts, loops) +
        effAlignW(params) * tidinessPenalty(parts) + cong +
        constraintCost(parts, idx_of, nets, loops, params);
}

/// The Phase-A constraint contribution to the *search* objective — added to
/// `objectiveCost` so SA is steered by the authored intent, but deliberately
/// absent from `scoreLayout`/`scorePoses`/`routedObjectiveCost` (the reported &
/// compared metrics). That separation is the whole point: constraints change
/// where the optimizer looks, not how the result is judged, so a hand layout and
/// a constrained solve are scored on the identical unmodified physical objective.
/// Reads the thread's `g_lowered` (set by `prepare`); a no-op when none authored.
/// Five lowered terms:
///   • proximity — Σ w·(edge gap from part pad to hub pin pad)
///   • keep-out  — Σ KEEPOUT_W·max(0, min − courtyard gap)
///   • net weight — Σ (w−1)·net wirelength  (net-length raises, deprioritize lowers)
///   • input-loop boost — extra loop inductance weight on a declared input rail
///     (fires even with an integrated inductor, which the auto switcher test misses)
///   • group cohesion — Σ group_w·(member→centroid distance) per `(group …)`,
///     a per-member pull (force on every member, not just the bbox extremes) —
///     the scalar twin of the relaxation force in `accumulateGroupCohesion`
///   • group zoning — group_zone_w·(centroid → hub's connecting side)
///   • bank-loop relief — removes `group_loop_relief` of the per-cap loop pull for
///     caps in a ≥2-member same-rail bank (twin of `g_loop_force_scale`)
fn constraintCost(
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    params: Params,
) f64 {
    const L = g_lowered;
    // Fast exit when nothing is live (no constraints and no functional groups).
    if (!L.active) return 0;
    var c: f64 = 0;

    for (L.prox) |t| {
        const gap = rectGap(worldRect(parts[t.part], t.part_pad), worldRect(parts[t.hub], t.hub_pad));
        // Hinge: only penalise distance beyond the declared radius (so a part
        // already inside `max_mm` is left alone, not dragged further at the cost
        // of other nets). A radius of 0 means "no declared max" → plain pull.
        const over = if (t.max_mm > 0) @max(0.0, gap - t.max_mm) else gap;
        c += t.w * over;
    }
    for (L.keepouts) |k| {
        const g = partGap(parts[k.a], parts[k.b]);
        if (g < k.min_mm) c += KEEPOUT_W * (k.min_mm - g);
    }
    if (L.net_weight.len == nets.len) {
        var pts: [MAX_WIRE_PTS]Pt = undefined;
        for (nets, 0..) |net, ni| {
            const extra = L.net_weight[ni] - 1.0;
            if (extra == 0) continue;
            if (isGroundName(shortName(net.name))) continue;
            c += extra * netWire(parts, idx_of, net, &pts);
        }
    }
    if (L.input_rail.len == nets.len) {
        for (loops) |lp| {
            if (lp.pwr_net < 0) continue;
            const ni: usize = @intCast(lp.pwr_net);
            if (ni >= nets.len or !L.input_rail[ni]) continue;
            const nh = loopMetric(parts, lp, surrogatePwrLeg(parts, lp)).nh;
            c += (params.input_loop_boost - 1.0) * params.loop_w * lp.weight * nh;
        }
    }
    for (L.groups) |g| {
        const inv = 1.0 / @as(f64, @floatFromInt(g.members.len));
        // Centroid of the member centres.
        var cx: f64 = 0;
        var cy: f64 = 0;
        for (g.members) |m| {
            cx += parts[m].x;
            cy += parts[m].y;
        }
        cx *= inv;
        cy *= inv;
        // Cohesion: pull *every* member toward the cluster centroid (Σ of the
        // members' distances to their mean position — a moment-of-inertia term).
        // Unlike a bounding-box penalty, this exerts a restoring force on the
        // interior members too, not just the four extremes — so a loop pull that
        // scatters individual caps along a tall pad is opposed cap-by-cap.
        for (g.members) |m| {
            c += params.group_w * std.math.hypot(parts[m].x - cx, parts[m].y - cy);
        }
        // Zoning: pull the cluster's centroid to the side of the hub it wires to,
        // a fixed reach beyond the hub edge, so groups land on distinct sides.
        if (g.hub >= 0 and params.group_zone_w > 0) {
            const hub = parts[@intCast(g.hub)];
            const d = rotateLocal(g.dirx, g.diry, hub.rot);
            const reach = @abs(d.x) * hub.hw + @abs(d.y) * hub.hh + ZONE_GAP_MM;
            const tx = hub.x + d.x * reach;
            const ty = hub.y + d.y * reach;
            c += params.group_zone_w * std.math.hypot(cx - tx, cy - ty);
        }
    }
    // Bank-loop relief: caps in a ≥2-member same-rail bank don't each need to reach
    // the rail pad — removing a fraction of their per-cap loop pull lets cohesion
    // pack them into one block (see `Params.group_loop_relief`). This cancels
    // exactly the matching fraction `objectiveCost` charged via `weightedLoop`
    // (`1 − g_loop_force_scale`), so a bank cap's net loop contribution stays ≥0.
    if (g_loop_force_scale.len == loops.len) {
        for (loops, 0..) |lp, li| {
            const relief = 1.0 - g_loop_force_scale[li];
            if (relief <= 0) continue;
            const nh = loopMetric(parts, lp, surrogatePwrLeg(parts, lp)).nh;
            c -= relief * params.loop_w * lp.weight * nh;
        }
    }
    return c;
}

/// Edge-to-edge gap (mm) between two parts' rotation-aware courtyards — the
/// distance a `(keep-out (part …) (from …))` penalises below its `min`.
fn partGap(a: Part, b: Part) f64 {
    const ar = Rect{ .x0 = courtCx(a) - effHw(a), .y0 = courtCy(a) - effHh(a), .x1 = courtCx(a) + effHw(a), .y1 = courtCy(a) + effHh(a) };
    const br = Rect{ .x0 = courtCx(b) - effHw(b), .y0 = courtCy(b) - effHh(b), .x1 = courtCx(b) + effHw(b), .y1 = courtCy(b) + effHh(b) };
    return rectGap(ar, br);
}

/// The same objective as `objectiveCost`, but the loop term is the *real*
/// maze-routed trace length (`routedLoops`) instead of the fixed-pad surrogate.
/// The surrogate measures a straight edge-to-edge gap to the pinned hub pad; the
/// router has to detour around foreign pads, so the two diverge — a layout whose
/// cap sits a slightly-shorter gap away on one side can route longer than the
/// other side. The surrogate-driven relax/polish therefore can't see which
/// rotation/side actually routes short; `routedPolish` uses this to re-tuck on
/// the metric the headline reports. `scratch` is a resettable arena the caller
/// wipes between evaluations (the router allocates a fresh grid per call).
fn routedObjectiveCost(
    scratch: std.mem.Allocator,
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    params: Params,
) f64 {
    const hpwl = wireScore(parts, idx_of, nets);
    const loop_weighted = routedLoops(scratch, parts, idx_of, nets, loops).weighted_nh;
    const cong = if (params.w_congest != 0) params.w_congest * congestionPenalty(parts, idx_of, nets) else 0;
    return hpwl + params.loop_w * loop_weighted + effAlignW(params) * tidinessPenalty(parts) + cong;
}

/// One full-route verdict — what the estimate-based objectives can only proxy,
/// measured: real copper length, via count, post-route DRC violations, nets the
/// router couldn't complete, plus the routed loop term carried through. `cost`
/// blends them in mm-equivalents (see the `FULLROUTE_*` weights).
pub const FullRouted = struct {
    cost: f64,
    trace_mm: f64,
    vias: usize,
    drc: usize,
    unrouted: usize,
    loop_nh_weighted: f64,
};

/// Fully route the board as placed — the same maze router + clearance check the
/// layout page runs — and score the result. This is the last rung of the
/// fidelity ladder: the RSMT estimate inside `routedObjectiveCost` cannot see
/// detours, layer changes, or two nets fighting for one corridor; the real
/// route can. The congestion proxy is deliberately absent (vias / DRC /
/// unrouted / trace ARE the measured thing it predicts); compactness stays so
/// the arbiter still values the regularizer the search optimized. Null when
/// the router can't grid the board (caller falls back to the routed-loop
/// objective). All allocation in `scratch`; `loop_nh_weighted` is the already-
/// measured routed loop term (don't pay `routedLoops` twice).
fn fullRouteCost(
    scratch: std.mem.Allocator,
    parts: []Part,
    nets: []const FlatNet,
    loops: []const Loop,
    stubs: []const Stub,
    priority: []const u32,
    params: Params,
    rp: router.RouteParams,
    loop_nh_weighted: f64,
) std.mem.Allocator.Error!?FullRouted {
    if (parts.len == 0) return null;
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (parts) |p| {
        minx = @min(minx, courtCx(p) - effHw(p));
        miny = @min(miny, courtCy(p) - effHh(p));
        maxx = @max(maxx, courtCx(p) + effHw(p));
        maxy = @max(maxy, courtCy(p) + effHh(p));
    }
    // A minimal Placement — exactly the fields `router.route`/`drc.check` read
    // (parts, nets, stubs, priority, bounds). Links/instances are render-only.
    const pl = Placement{
        .parts = parts,
        .links = &.{},
        .loops = loops,
        .stubs = stubs,
        .instances = &.{},
        .nets = nets,
        .priority = priority,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = minx,
        .miny = miny,
        .maxx = maxx,
        .maxy = maxy,
        .generated = false,
    };
    const routed = try router.route(scratch, pl, rp);
    // A fully-empty result with nets present means the board couldn't be
    // gridded (too large / degenerate) — no information, let the caller fall
    // back. (A ground-only board legitimately returns vias and no tracks.)
    if (routed.total == 0 and routed.tracks.len == 0 and routed.vias.len == 0 and nets.len > 0) return null;
    const viol = try drc.check(scratch, pl, routed, rp.clearance);
    var trace: f64 = 0;
    for (routed.tracks) |t| trace += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    const unrouted = routed.total - routed.routed;
    const cost = trace +
        FULLROUTE_VIA_MM * @as(f64, @floatFromInt(routed.vias.len)) +
        FULLROUTE_DRC_MM * @as(f64, @floatFromInt(viol.len)) +
        FULLROUTE_UNROUTED_MM * @as(f64, @floatFromInt(unrouted)) +
        params.loop_w * loop_nh_weighted +
        effAlignW(params) * tidinessPenalty(parts);
    return .{
        .cost = cost,
        .trace_mm = trace,
        .vias = routed.vias.len,
        .drc = viol.len,
        .unrouted = unrouted,
        .loop_nh_weighted = loop_nh_weighted,
    };
}

/// The whole sub-module's footprint area (mm²): the area of the axis-aligned
/// bounding box over every part's rotation-aware courtyard (`effHw`/`effHh`).
/// Reported in `Breakdown.footprint` as the compactness yardstick (it is not
/// part of the scored objective — `tidinessPenalty` is the regularizer).
fn compactnessArea(parts: []const Part) f64 {
    if (parts.len == 0) return 0;
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (parts) |p| {
        minx = @min(minx, courtCx(p) - effHw(p));
        miny = @min(miny, courtCy(p) - effHh(p));
        maxx = @max(maxx, courtCx(p) + effHw(p));
        maxy = @max(maxy, courtCy(p) + effHh(p));
    }
    return (maxx - minx) * (maxy - miny);
}

/// Tidiness reward (as a penalty to minimize): for each part pair, the smaller of
/// their x/y offsets, clamped to `ALIGN_CLAMP_MM`. Driving it down lines parts up
/// into shared rows / columns; the clamp means only near-aligned pairs feel a pull,
/// so distant parts aren't dragged together. The long-shipped default regularizer —
/// cheap, and on large boards aligned rows route far shorter.
///
/// Normalized by pair count (× 2/(n−1) ⇒ n × the mean pairwise misalignment) so
/// the term grows ~linearly with part count, the same as HPWL — the raw O(n²)
/// sum made the alignment-vs-wirelength balance an accident of board size (one
/// part's alignment gradient scaled with n while its wirelength gradient
/// didn't). The weight scale moves to `W_ALIGN_TIDINESS` accordingly.
fn tidinessPenalty(parts: []const Part) f64 {
    if (parts.len < 2) return 0;
    var total: f64 = 0;
    for (parts, 0..) |a, i| {
        for (parts[i + 1 ..]) |b| {
            const off = @min(@abs(a.x - b.x), @abs(a.y - b.y));
            total += @min(off, ALIGN_CLAMP_MM);
        }
    }
    return total * 2.0 / @as(f64, @floatFromInt(parts.len - 1));
}

// Congestion grid: bin size targets ~3 mm so a real hotspot is visible on any
// board — a fixed 8×8 grid meant 12.5 mm bins on a 100 mm board (too coarse to
// see a pileup) and sub-mm bins on a tiny module (noise). Bin *count* per axis
// is derived from the extent and clamped: the floor keeps small modules at the
// long-shipped resolution, the cap bounds the per-eval cost (`objectiveCost` is
// hot — every polish candidate pays nets × covered-bins).
const CONGEST_BIN_MM: f64 = 3.0; // target bin edge (mm)
const CONGEST_BINS_MIN: usize = 8;
const CONGEST_BINS_MAX: usize = 32;
const CONGEST_PITCH_MM: f64 = 0.254; // one signal wire's footprint ≈ track_width + clearance
const CONGEST_CLEARANCE_MM: f64 = 0.127; // the clearance half of that pitch (router default rule)
// Routable wire-density per bin, summed over the two signal layers. 2.0 (the
// old value) is 100% copper utilization per layer — real maze/auto routability
// collapses well before that (~60–80% per layer; beyond it detours explode),
// so the penalty only fired in pathological pileups. 1.4 ≈ 70% × 2 layers.
const CONGEST_CAP: f64 = 1.4;

/// Bin count for one axis of the congestion grid: extent / target bin size,
/// clamped to `[CONGEST_BINS_MIN, CONGEST_BINS_MAX]`.
fn congestBins(extent: f64) usize {
    const n: usize = @intFromFloat(@ceil(@max(extent, 1.0) / CONGEST_BIN_MM));
    return std.math.clamp(n, CONGEST_BINS_MIN, CONGEST_BINS_MAX);
}

/// IPC-2221-approximate trace width (mm) for `amps` of continuous current —
/// external 1 oz copper, 10 °C rise: I = 0.048·ΔT^0.44·A^0.725 (A in mil²),
/// width = A / 1.378 mil. ~0.30 mm at 1 A, ~0.78 mm at 2 A, ~1.37 mm at 3 A.
/// 0 for no/unknown current, so the caller falls back to the signal pitch.
fn ipc2221WidthMm(amps: f64) f64 {
    if (amps <= 0) return 0;
    const k = 0.048 * std.math.pow(f64, 10.0, 0.44); // ΔT = 10 °C
    const area_mil2 = std.math.pow(f64, amps / k, 1.0 / 0.725);
    const width_mil = area_mil2 / 1.378; // 1 oz copper thickness
    return width_mil * 0.0254;
}

/// One net's congestion wire pitch (mm): the signal default, widened to the
/// IPC-2221 trace width (plus clearance) when the net carries a declared
/// current (`g_net_current`, resolved from `(current …)` ports and `(i-typ …)`
/// pins by `prepare`). A 3 A rail needs a ~1.4 mm corridor, not a 0.254 mm one
/// — sizing its RUDY footprint by the copper that must actually exist makes
/// congestion see power routing, not just signal count.
fn congestPitch(net_index: usize) f64 {
    if (net_index >= g_net_current.len) return CONGEST_PITCH_MM;
    const w = ipc2221WidthMm(g_net_current[net_index]);
    return @max(CONGEST_PITCH_MM, w + CONGEST_CLEARANCE_MM);
}

/// Routing-congestion penalty (RUDY: Rectangular Uniform wire DensitY). Lays a
/// coarse grid over the board and, for each signal net, spreads its estimated
/// wire area (HPWL × wire pitch) uniformly over its bounding box, accumulating a
/// dimensionless wire-density per bin. The penalty is the summed squared overflow
/// of each bin above the signal-layer budget `CONGEST_CAP` — zero on a sparse
/// board, growing where many nets pile into one region. This predicts routability
/// (whether the board routes clean), which pure wirelength does not — it must be
/// traded off against HPWL, not minimized in isolation (Spindler & Johannes;
/// UCLA mPL supply/demand). Ground nets are excluded (they drop to the plane);
/// a net with a declared current deposits a proportionally wider corridor
/// (`congestPitch`).
fn congestionPenalty(parts: []const Part, idx_of: *std.StringHashMap(usize), nets: []const FlatNet) f64 {
    if (parts.len == 0) return 0;
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (parts) |p| {
        minx = @min(minx, courtCx(p) - effHw(p));
        miny = @min(miny, courtCy(p) - effHh(p));
        maxx = @max(maxx, courtCx(p) + effHw(p));
        maxy = @max(maxy, courtCy(p) + effHh(p));
    }
    const nbx = congestBins(maxx - minx);
    const nby = congestBins(maxy - miny);
    const binw = (maxx - minx) / @as(f64, @floatFromInt(nbx));
    const binh = (maxy - miny) / @as(f64, @floatFromInt(nby));
    if (binw <= 1e-6 or binh <= 1e-6) return 0;
    const bin_area = binw * binh;

    var dens = [_]f64{0} ** (CONGEST_BINS_MAX * CONGEST_BINS_MAX);
    for (nets, 0..) |net, net_i| {
        if (isGroundName(shortName(net.name))) continue;
        var nminx: f64 = std.math.inf(f64);
        var nminy: f64 = std.math.inf(f64);
        var nmaxx: f64 = -std.math.inf(f64);
        var nmaxy: f64 = -std.math.inf(f64);
        var cnt: usize = 0;
        for (net.pins) |pr| {
            const i = idx_of.get(pr.ref_des) orelse continue;
            const pad = padLocal(parts[i], pr.pin);
            const w = worldPt(parts[i], pad.x, pad.y);
            nminx = @min(nminx, w.x);
            nminy = @min(nminy, w.y);
            nmaxx = @max(nmaxx, w.x);
            nmaxy = @max(nmaxy, w.y);
            cnt += 1;
        }
        if (cnt < 2) continue;
        const pitch = congestPitch(net_i);
        const nw = nmaxx - nminx;
        const nh = nmaxy - nminy;
        // Effective footprint for spreading: a trace has a finite width, so floor
        // each axis to one wire pitch. This keeps `na` non-degenerate AND lets a
        // perfectly horizontal/vertical net still deposit density over its corridor.
        const ex0 = nminx - @max(0.0, pitch - nw) / 2;
        const ex1 = nmaxx + @max(0.0, pitch - nw) / 2;
        const ey0 = nminy - @max(0.0, pitch - nh) / 2;
        const ey1 = nmaxy + @max(0.0, pitch - nh) / 2;
        const na = (ex1 - ex0) * (ey1 - ey0); // = max(nw,pitch)·max(nh,pitch)
        // RUDY per-net density: wire area (HPWL × pitch) over the bounding-box area.
        const dn = ((nw + nh) * pitch) / na;
        const bx0 = binIndex((ex0 - minx) / binw, nbx);
        const bx1 = binIndex((ex1 - minx) / binw, nbx);
        const by0 = binIndex((ey0 - miny) / binh, nby);
        const by1 = binIndex((ey1 - miny) / binh, nby);
        var by = by0;
        while (by <= by1) : (by += 1) {
            var bx = bx0;
            while (bx <= bx1) : (bx += 1) {
                // Fraction of this bin the net's effective footprint overlaps.
                const cx0 = minx + @as(f64, @floatFromInt(bx)) * binw;
                const cy0 = miny + @as(f64, @floatFromInt(by)) * binh;
                const ow = @max(0.0, @min(ex1, cx0 + binw) - @max(ex0, cx0));
                const oh = @max(0.0, @min(ey1, cy0 + binh) - @max(ey0, cy0));
                dens[by * nbx + bx] += dn * (ow * oh) / bin_area;
            }
        }
    }
    var pen: f64 = 0;
    for (dens[0 .. nbx * nby]) |d| {
        const over = d - CONGEST_CAP;
        if (over > 0) pen += over * over;
    }
    return pen;
}

/// Clamp a fractional bin coordinate to a valid `[0, bins-1]` index.
fn binIndex(f: f64, bins: usize) usize {
    if (f <= 0) return 0;
    const i: usize = @intFromFloat(@floor(f));
    return @min(i, bins - 1);
}

/// Hot-loop *inductance* (nH) with each cap's loop scaled by its value-priority
/// `weight` — so on a multi-cap rail the smaller cap is pulled closest. Uses the
/// continuous fixed-pad surrogate (no argmin flip) — the same metric the reported
/// score uses, so the objective the optimizer minimizes and the score the page
/// shows are one smooth function. (The routed finishing passes additionally probe
/// the real trace via `routedObjectiveCost`.) This is the loop term the objective
/// minimizes.
fn weightedLoop(parts: []const Part, loops: []const Loop) f64 {
    return surrogateLoops(parts, loops).weighted_nh;
}

/// One loop's surrogate power-leg cost: the straight-line edge-to-edge gap from
/// the cap's power pad to its pinned hub pin. A pure analytic distance with no
/// obstacle/detour penalty, so the loop term is a smooth, continuous function of
/// the cap's position (no chord cliffs as a leg slides past a foreign pad); the
/// obstacle-aware routed length is measured separately by the finishing passes.
/// The rest of the loop (the cap's body span + the ground return) is added by
/// `loopGroundSpan`.
fn surrogatePwrLeg(parts: []const Part, lp: Loop) f64 {
    return rectGap(worldRect(parts[lp.cap], lp.cap_pwr), worldRect(parts[lp.hub], lp.hub_pwr_pin));
}

/// The cap's own pad-to-pad span (its body), edge-to-edge (mm) — the current
/// path through the capacitor itself, part of the conducting loop.
fn capSpan(parts: []const Part, lp: Loop) f64 {
    const cap = parts[lp.cap];
    return rectGap(worldRect(cap, lp.cap_pwr), worldRect(cap, lp.cap_gnd));
}

/// The non-power half of the physical loop *length* (mm), modelled for a *solid
/// adjacent GND plane* (the board's L2): the cap's own pad-to-pad span (its body)
/// + the two `LAYER_GAP_MM` via transitions (cap GND pad → plane, plane → IC GND
/// pad). There is NO lateral ground-return term: on a plane the return current
/// images directly under the power trace (path of least inductance), so the loop
/// is set by the power-leg length, not by how far the cap's GND pad sits from the
/// IC GND *pin*. (For a board with a discrete routed return instead of a plane,
/// that lateral distance would matter — not this design; see the design's
/// `(kicad-pcb)` stackup, always plane-on-L2.) Kept as the display *length*; the
/// scored quantity is the loop *inductance* (`loopInductanceNh`).
fn loopGroundSpan(parts: []const Part, lp: Loop) f64 {
    return capSpan(parts, lp) + 2 * LAYER_GAP_MM;
}

// ── Loop inductance (the scored hot-loop metric) ─────────────────────────────
// The research verdict: a decoupling cap's connection *inductance* (nH) — not the
// loop *length* — is what limits its high-frequency current delivery (LearnEMC,
// "Estimating Connection Inductance"; SRF = 1/(2π√(LC))). So the objective scores
// inductance. Two pieces of validated physics shape the estimate:
//   • A trace over its adjacent return plane has a per-unit-length inductance
//     L' = (μ0/2π)·ln(2h/r_eq), h = the L1→L2 dielectric gap, r_eq ≈ w/4 the
//     flat-trace equivalent radius. This linear-in-length term is the LearnEMC
//     "long loop" (w>5h) regime.
//   • Below w≈5h the linear term alone would drive L→0 as the cap touches the
//     pin, but the connection inductance floors at the via/mounting inductance —
//     so we add the series inductance of the two short vias down to the L2 plane
//     (cap-GND→plane, IC-GND→plane). That floor IS the dominant short-regime
//     correction the pure-length model misses; a full rectangular-loop closed
//     form would refine the crossover but the geometry can't pin the absolute nH
//     anyway (the coefficient is logarithmic), so weights need empirical tuning.
const MU0_OVER_2PI_NH_PER_MM: f64 = 0.2; // μ0/2π = 2e-7 H/m = 0.2 nH/mm
const IND_TRACE_W_MM: f64 = 0.127; // ~track width; flat-trace equiv radius = w/4
const VIA_TO_PLANE_DIA_MM: f64 = 0.4; // via barrel Ø for the GND drop to L2
const N_LOOP_VIAS: f64 = 2.0; // cap-GND→plane + IC-GND→plane
/// Per-unit-length inductance of a signal trace over the adjacent return plane.
const LOOP_PUL_NH_PER_MM: f64 = MU0_OVER_2PI_NH_PER_MM * @log(2.0 * LAYER_GAP_MM / (IND_TRACE_W_MM / 4.0));
/// Series inductance (nH) of one short via down to the L2 plane: (μ0/2π)·h·(ln(4h/d)+1).
const VIA_IND_NH: f64 = MU0_OVER_2PI_NH_PER_MM * LAYER_GAP_MM * (@log(4.0 * LAYER_GAP_MM / VIA_TO_PLANE_DIA_MM) + 1.0);

/// Loop connection inductance (nH) from the conducting-path length (power leg +
/// cap body span, mm): the trace-over-plane term + the two via transitions' floor.
fn loopInductanceNh(conductor_len_mm: f64) f64 {
    return N_LOOP_VIAS * VIA_IND_NH + LOOP_PUL_NH_PER_MM * conductor_len_mm;
}

/// One loop's display *length* (mm) and scored *inductance* (nH) from a power-leg
/// length (`pwr_len`, mm) — the surrogate gap or the routed trace. The conducting
/// path is the power leg + the cap body span; the ground return images under it.
const LoopMetric = struct { mm: f64, nh: f64 };
fn loopMetric(parts: []const Part, lp: Loop, pwr_len: f64) LoopMetric {
    const span = capSpan(parts, lp);
    return .{ .mm = pwr_len + span + 2 * LAYER_GAP_MM, .nh = loopInductanceNh(pwr_len + span) };
}

/// Analytic loop sums (length + inductance, raw + value-weighted) from the
/// fixed-pad surrogate: the power leg to the pinned pin, plus the cap span and
/// via floor folded into `loopMetric`. Drives the inner-loop objective and is the
/// score path's fallback when routing a leg fails or the board is too large to grid.
fn surrogateLoops(parts: []const Part, loops: []const Loop) LoopSums {
    var s = LoopSums{ .raw_mm = 0, .weighted_mm = 0, .raw_nh = 0, .weighted_nh = 0 };
    for (loops) |lp| {
        const m = loopMetric(parts, lp, surrogatePwrLeg(parts, lp));
        s.raw_mm += m.mm;
        s.weighted_mm += lp.weight * m.mm;
        s.raw_nh += m.nh;
        s.weighted_nh += lp.weight * m.nh;
    }
    return s;
}

const Endpoint = struct { idx: usize, pin: []const u8, px: f64, py: f64, pw: f64, ph: f64, is_hub: bool };

/// Build the force list from the netlist:
///   • A net touching exactly one *hub component* (even across several of its
///     pins) hugs each passive to that hub. Power rails like VIN (pins 1+2) or
///     VOUT (10+11+12) qualify — we key on a single hub *component*, not pin.
///   • A passive that also has a ground pad is a *decoupling cap*: instead of
///     springs it records a `Loop` whose power and ground legs are measured
///     edge-to-edge to the nearest hub power / ground pad (see `Loop`). The
///     relaxation applies those legs as forces directly (`accumulateLoops`).
///   • A non-decoupling single-hub passive (a feedback resistor, say) gets a
///     centroid hug spring to the hub's pads on its net.
///   • Everything else gets a weak centre pull; ground nets are planes.
fn buildSprings(
    arena: std.mem.Allocator,
    nets: []const FlatNet,
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    roles: []const pin_roles.PartRoles,
    explicit_pin: []const []const u8,
    rail_optout: []const bool,
) std.mem.Allocator.Error!Built {
    const gnd = try groundPads(arena, nets, parts, idx_of, roles);
    var springs: std.ArrayListUnmanaged(Spring) = .empty;
    var loops: std.ArrayListUnmanaged(Loop) = .empty;
    var legs: std.ArrayListUnmanaged(SeriesCand) = .empty;

    for (nets, 0..) |net, net_i| {
        if (isGroundName(shortName(net.name))) continue;

        var eps: std.ArrayListUnmanaged(Endpoint) = .empty;
        var hub_idx: ?usize = null;
        var multi_hub = false;
        for (net.pins) |pr| {
            const i = idx_of.get(pr.ref_des) orelse continue;
            const pad = padLocal(parts[i], pr.pin);
            const is_hub = parts[i].kind == .hub;
            if (is_hub) {
                if (hub_idx) |h| {
                    if (h != i) multi_hub = true;
                } else hub_idx = i;
            }
            try eps.append(arena, .{ .idx = i, .pin = pr.pin, .px = pad.x, .py = pad.y, .pw = pad.w, .ph = pad.h, .is_hub = is_hub });
        }
        if (eps.items.len < 2) continue;

        const single_hub = hub_idx != null and !multi_hub;
        if (single_hub) {
            try hugToHub(arena, &springs, &loops, &legs, eps.items, hub_idx.?, gnd, roles, explicit_pin, rail_optout, @intCast(net_i), net.name);
        } else if (multi_hub) {
            // A rail shared by ≥2 ICs: honour each cap's explicit `(decouples …)`
            // pin binding with a real loop to the hub that owns the named pad,
            // instead of collapsing the whole rail into one weak cluster.
            try clusterMultiHub(arena, &springs, &loops, eps.items, gnd, roles, explicit_pin, rail_optout, @intCast(net_i), net.name);
        } else {
            try weakCluster(arena, &springs, eps.items, net.name);
        }
    }
    const series = try pairSeriesLegs(arena, legs.items, parts);
    return .{ .springs = try springs.toOwnedSlice(arena), .loops = try loops.toOwnedSlice(arena), .series = series };
}

/// One non-decoupling passive leg recorded by `hugToHub` — a candidate half of
/// a `SeriesPair`. `hub_pad` is the centroid of the hub's pads on the leg's net.
const SeriesCand = struct { part: usize, hub: usize, part_pad: PadRect, hub_pad: PadRect };

/// Pair up `hugToHub`'s candidate legs into `SeriesPair`s: a part qualifies
/// when it has exactly two pads, exactly two legs, both legs reach the *same*
/// hub, and the hub-side targets are distinct (two different pins — a part
/// strapped twice to one pin has no orientation to decide).
fn pairSeriesLegs(arena: std.mem.Allocator, cands: []const SeriesCand, parts: []const Part) std.mem.Allocator.Error![]SeriesPair {
    var out: std.ArrayListUnmanaged(SeriesPair) = .empty;
    for (cands, 0..) |c, i| {
        if (parts[c.part].pads.len != 2) continue;
        // Count this part's legs and find the one other than `i` (emit each
        // pair once, from its first leg).
        var n: usize = 0;
        var first_idx: usize = cands.len;
        var mate_idx: usize = cands.len;
        for (cands, 0..) |o, j| {
            if (o.part != c.part) continue;
            n += 1;
            if (first_idx == cands.len) first_idx = j;
            if (j != i and mate_idx == cands.len) mate_idx = j;
        }
        if (n != 2 or first_idx != i or mate_idx == cands.len) continue;
        const m = cands[mate_idx];
        if (m.hub != c.hub) continue;
        // Two distinct pads reaching two distinct hub targets, else there is
        // no orientation to decide.
        if (c.part_pad.x == m.part_pad.x and c.part_pad.y == m.part_pad.y) continue;
        if (c.hub_pad.x == m.hub_pad.x and c.hub_pad.y == m.hub_pad.y) continue;
        try out.append(arena, .{
            .part = c.part,
            .hub = c.hub,
            .a = .{ .part_pad = c.part_pad, .hub_pad = c.hub_pad },
            .b = .{ .part_pad = m.part_pad, .hub_pad = m.hub_pad },
        });
    }
    return out.toOwnedSlice(arena);
}

/// The quarter rotation that best aligns a series part's pad axis with its
/// matched hub pads' axis — so each pad faces *its own* pin instead of one pad
/// docking close while the other's leg detours around the part body. World-space
/// via the hub's current rotation; position-independent (depends only on the two
/// footprints), so it cannot flip as the part slides along its lane.
fn seriesPairRot(parts: []const Part, sp: SeriesPair) ?f64 {
    const pdx = sp.b.part_pad.x - sp.a.part_pad.x;
    const pdy = sp.b.part_pad.y - sp.a.part_pad.y;
    const ta = rotateLocal(sp.a.hub_pad.x, sp.a.hub_pad.y, parts[sp.hub].rot);
    const tb = rotateLocal(sp.b.hub_pad.x, sp.b.hub_pad.y, parts[sp.hub].rot);
    const tdx = tb.x - ta.x;
    const tdy = tb.y - ta.y;
    if (@abs(pdx) + @abs(pdy) < 1e-9 or @abs(tdx) + @abs(tdy) < 1e-9) return null;
    var best: f64 = 0;
    var best_dot = -std.math.inf(f64);
    for (ROT_CAND) |r| {
        const p = rotateLocal(pdx, pdy, r);
        const dot = p.x * tdx + p.y * tdy;
        if (dot > best_dot) {
            best_dot = dot;
            best = r;
        }
    }
    return best;
}

/// Set every series part to its pad-pairing rotation and pin it `.series`
/// (an `.authored` spec `(rot …)` wins and is left alone). Re-applies over an
/// existing `.series` pin — the pairing is deterministic, and the multi-start
/// rerank polishes several restored candidates through this path in turn. Run
/// after seeding, before the rotation-searching refinement passes — see
/// `SeriesPair` for why those searches must not own this decision. A rotation
/// that would collide at the part's current pose is applied anyway: the
/// legalize passes that follow every polish resolve position overlaps, but
/// only this pass knows the right orientation.
fn applySeriesRotations(parts: []Part, series: []const SeriesPair) void {
    for (series) |sp| {
        const p = &parts[sp.part];
        if (p.rot_pin == .authored or p.kind == .hub) continue;
        if (seriesPairRot(parts, sp)) |r| {
            p.rot = r;
            p.rot_pin = .series;
        }
    }
}

/// Set each loop's value-priority weight:
///   • loop.weight = boost the smaller of several caps sharing a power rail
///     toward the pin (rails identified by a shared `hub_pwr` slice); a lone
///     cap keeps weight 1, so single-cap rails are unaffected. A declared
///     `(placement-order …)` rank (`priority[cap]`, 0 = unranked) raises the
///     weight further — `@max` so the order can only *tighten*, never loosen.
///   • when an inductor marks the design a switching regulator, a loop on an
///     INPUT rail (VIN/PVIN/VBUS/…, see `isInputRailName`) is the high-dI/dt hot
///     loop and its weight is multiplied by `INPUT_LOOP_BOOST` — pulled tighter
///     than output/generic decoupling because it dominates EMI.
fn classify(parts: []Part, loops: []Loop, nets: []const FlatNet, cap_w_max: f64, input_loop_boost: f64, priority: []const u32) void {
    var switcher = false;
    for (parts) |p| {
        if (isInductor(p.ref_des)) {
            switcher = true;
            break;
        }
    }
    for (loops) |*lp| {
        var w_val: f64 = 1;
        const v = capValueFarads(parts[lp.cap].value);
        if (v > 0) {
            var vref = v;
            for (loops) |o| {
                if (o.hub_pwr.ptr == lp.hub_pwr.ptr) vref = @max(vref, capValueFarads(parts[o.cap].value));
            }
            w_val = std.math.clamp(@sqrt(vref / v), 1.0, cap_w_max);
        }
        var w = @max(w_val, priorityWeight(priority[lp.cap]));
        if (switcher and lp.pwr_net >= 0) {
            const ni: usize = @intCast(lp.pwr_net);
            if (ni < nets.len and isInputRailName(shortName(nets[ni].name))) w *= input_loop_boost;
        }
        lp.weight = w;
    }
}

/// True when `name` looks like a switching regulator's *input* rail — the
/// high-dI/dt side whose decoupling loop dominates EMI. Matches common input-rail
/// names (VIN/PVIN/VBUS/VBAT/VSYS/…) and any raw-voltage rail ≥7 V (e.g. `V_12V`,
/// `24V`), which on a buck is the input; lower raw rails (3V3, 5V) read as
/// outputs and are not boosted. Separators stripped, case-insensitive.
fn isInputRailName(name: []const u8) bool {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (name) |c| switch (c) {
        '_', '-', '/', '.', ' ', '#' => {},
        else => {
            if (n >= buf.len) break;
            buf[n] = std.ascii.toUpper(c);
            n += 1;
        },
    };
    const s = buf[0..n];
    const prefixes = [_][]const u8{ "VIN", "PVIN", "VBUS", "VBAT", "VSYS", "VDCIN", "HVIN" };
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    // Raw-voltage rail: an optional leading 'V' then an integer ≥ 7 V is an input.
    var t = s;
    if (t.len > 0 and t[0] == 'V') t = t[1..];
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i > 0) {
        const volts = std.fmt.parseInt(u32, t[0..i], 10) catch return false;
        return volts >= 7;
    }
    return false;
}

/// Loop-tightness weight from a `(placement-order …)` rank: rank 0 (unranked) is
/// neutral (1.0); a higher rank (earlier in the list) pulls the cap tighter.
fn priorityWeight(rank: u32) f64 {
    if (rank == 0) return 1.0;
    return 1.0 + PRIORITY_STEP * @as(f64, @floatFromInt(rank));
}

/// The pad in `pads` whose centre is nearest `to`'s centre (footprint-local) —
/// picks the hub ground pad a loop's return targets (the one closest to the
/// power pin). `pads` must be non-empty.
fn nearestPad(pads: []const PadRect, to: PadRect) PadRect {
    var best = pads[0];
    var best_d2 = std.math.inf(f64);
    for (pads) |p| {
        const d2 = (p.x - to.x) * (p.x - to.x) + (p.y - to.y) * (p.y - to.y);
        if (d2 < best_d2) {
            best_d2 = d2;
            best = p;
        }
    }
    return best;
}

/// The hub pad whose pin matches `want` (a cap's explicitly-named target pin),
/// as a footprint-local rect, or null when `want` is empty / not on this net.
fn findHubPin(eps: []const Endpoint, hub: usize, want: []const u8) ?PadRect {
    if (want.len == 0) return null;
    for (eps) |h| {
        if (h.idx == hub and std.mem.eql(u8, h.pin, want)) {
            return .{ .x = h.px, .y = h.py, .w = h.pw, .h = h.ph };
        }
    }
    return null;
}

/// For each passive on a single-hub net: a decoupling cap (it also has a
/// ground pad) records an edge-aware `Loop`; any other passive gets a centroid
/// hug spring to the hub's pads on this net.
fn hugToHub(
    arena: std.mem.Allocator,
    springs: *std.ArrayListUnmanaged(Spring),
    loops: *std.ArrayListUnmanaged(Loop),
    legs: *std.ArrayListUnmanaged(SeriesCand),
    eps: []const Endpoint,
    hub: usize,
    gnd: []const []const PadRect,
    roles: []const pin_roles.PartRoles,
    explicit_pin: []const []const u8,
    rail_optout: []const bool,
    net_i: i32,
    net_name: []const u8,
) std.mem.Allocator.Error!void {
    const tgt = (try hubTargets(arena, eps, hub, roles)) orelse return;

    for (eps) |e| {
        if (e.idx == hub or e.is_hub) continue;
        const decouple = gnd[e.idx].len > 0 and gnd[hub].len > 0;
        if (decouple) {
            try emitCapLoop(arena, loops, eps, e, hub, tgt, gnd, explicit_pin, rail_optout, net_i);
        } else {
            // Non-decoupling single-hub passive: hug the hub's pad centroid.
            try springs.append(arena, .{
                .a = e.idx,
                .b = hub,
                .ax = e.px,
                .ay = e.py,
                .bx = tgt.centroid.x,
                .by = tgt.centroid.y,
                .k = K_PROX,
                .kind = .proximity,
                .net = net_name,
            });
            // Record the leg — `pairSeriesLegs` turns a 2-pad part with two of
            // these (to the same hub) into a `SeriesPair`.
            try legs.append(arena, .{
                .part = e.idx,
                .hub = hub,
                .part_pad = .{ .x = e.px, .y = e.py, .w = e.pw, .h = e.ph },
                .hub_pad = .{ .x = tgt.centroid.x, .y = tgt.centroid.y, .w = 0, .h = 0 },
            });
        }
    }
}

/// A hub's target geometry on one (power) net, shared by the single-hub
/// (`hugToHub`) and multi-hub (`clusterMultiHub`) paths.
const HubTarget = struct {
    /// The hub's supply pads on the net (kept as a slice so `classify` can group
    /// caps that share a rail by pointer identity).
    hub_pwr_s: []const PadRect,
    /// Lowest-numbered real supply pad — the pinned loop target for a cap with no
    /// explicit pin. Fixing it removes the per-eval argmin flip.
    default_pin_rect: PadRect,
    /// Centroid of the chosen pads — the non-decoupling hug spring target.
    centroid: Pt,
};

/// The hub's pads on this (power) net. Config straps tied to the rail (a declared
/// `input`/`output`/`io` pin such as EN/UV or PGFB) are dropped so a bypass cap
/// hugs the real supply pins, not a control pin that merely shares the net; if
/// every hub pad is a strap we keep them all so a rail is never left targetless.
/// Returns null when the hub has no pad on this net.
fn hubTargets(
    arena: std.mem.Allocator,
    eps: []const Endpoint,
    hub: usize,
    roles: []const pin_roles.PartRoles,
) std.mem.Allocator.Error!?HubTarget {
    var hub_all: std.ArrayListUnmanaged(PadRect) = .empty;
    var hub_real: std.ArrayListUnmanaged(PadRect) = .empty;
    var def_rect: ?PadRect = null;
    var def_pin: []const u8 = "";
    for (eps) |e| {
        if (e.idx != hub) continue;
        const rect = PadRect{ .x = e.px, .y = e.py, .w = e.pw, .h = e.ph };
        try hub_all.append(arena, rect);
        if (roles[hub].classOf(e.pin) != .strap) {
            try hub_real.append(arena, rect);
            if (def_rect == null or pinLess(e.pin, def_pin)) {
                def_rect = rect;
                def_pin = e.pin;
            }
        }
    }
    if (hub_all.items.len == 0) return null;
    const hub_pwr_s = if (hub_real.items.len > 0) try hub_real.toOwnedSlice(arena) else try hub_all.toOwnedSlice(arena);
    var hx: f64 = 0;
    var hy: f64 = 0;
    for (hub_pwr_s) |p| {
        hx += p.x;
        hy += p.y;
    }
    const hn: f64 = @floatFromInt(hub_pwr_s.len);
    return .{
        .hub_pwr_s = hub_pwr_s,
        .default_pin_rect = def_rect orelse hub_pwr_s[0],
        .centroid = .{ .x = hx / hn, .y = hy / hn },
    };
}

/// Append one decoupling cap's hot loop against `hub`. The power leg is pinned to
/// the cap's named pad (`explicit_pin` — e.g. from `(decouples "IC" PIN)` or a
/// `(near <pin>)`) when that pad is on this net, else to `tgt.default_pin_rect`;
/// the ground return targets the hub GND pad nearest that power pin. Both targets
/// are fixed (no per-eval argmin), so loop cost stays continuous in the cap's
/// position. Caller guarantees both the cap and the hub have a ground pad.
fn emitCapLoop(
    arena: std.mem.Allocator,
    loops: *std.ArrayListUnmanaged(Loop),
    eps: []const Endpoint,
    e: Endpoint,
    hub: usize,
    tgt: HubTarget,
    gnd: []const []const PadRect,
    explicit_pin: []const []const u8,
    rail_optout: []const bool,
    net_i: i32,
) std.mem.Allocator.Error!void {
    const named_rect = findHubPin(eps, hub, explicit_pin[e.idx]);
    const pin_rect = named_rect orelse tgt.default_pin_rect;
    const gnd_rect = nearestPad(gnd[hub], pin_rect);
    try loops.append(arena, .{
        .cap = e.idx,
        .hub = hub,
        .cap_pwr = .{ .x = e.px, .y = e.py, .w = e.pw, .h = e.ph },
        .cap_gnd = gnd[e.idx][0],
        .hub_pwr = tgt.hub_pwr_s,
        .hub_pwr_pin = pin_rect,
        .hub_gnd = gnd[hub],
        .hub_gnd_pin = gnd_rect,
        .pwr_net = net_i,
        // Only an authored, on-this-net pin counts as explicit.
        .explicit_pin = if (named_rect != null) explicit_pin[e.idx] else "",
        .rail_optout = rail_optout[e.idx],
    });
}

/// The hub endpoint that owns pad `want` on this net. A physical pad belongs to
/// exactly one IC, so the named pin disambiguates which hub a `(decouples …)`
/// cap binds to on a rail shared by several ICs. Null if no hub matches.
fn hubOwningPin(eps: []const Endpoint, want: []const u8) ?usize {
    if (want.len == 0) return null;
    for (eps) |h| {
        if (h.is_hub and std.mem.eql(u8, h.pin, want)) return h.idx;
    }
    return null;
}

/// A net with ≥2 hub ICs (e.g. a supply rail landing on both an MCU and a QSPI
/// flash) has no single hub to hug, so its endpoints normally fall to the weak
/// centre-pull `weakCluster`. But a decoupling cap that *names* its pad via
/// `(decouples "IC" PIN)` (or a generator stub key) still wants a real loop to
/// that exact pin — silently demoting it to a weak cluster is the layout bug
/// this guards against. Peel each explicitly-bound decoupling cap into a `Loop`
/// against the hub that owns the named pad; everything else weak-clusters as
/// before, so unbound caps and true multi-hub signal nets are unchanged.
fn clusterMultiHub(
    arena: std.mem.Allocator,
    springs: *std.ArrayListUnmanaged(Spring),
    loops: *std.ArrayListUnmanaged(Loop),
    eps: []const Endpoint,
    gnd: []const []const PadRect,
    roles: []const pin_roles.PartRoles,
    explicit_pin: []const []const u8,
    rail_optout: []const bool,
    net_i: i32,
    net_name: []const u8,
) std.mem.Allocator.Error!void {
    var rest: std.ArrayListUnmanaged(Endpoint) = .empty;
    for (eps) |e| {
        const bound = !e.is_hub and gnd[e.idx].len > 0 and explicit_pin[e.idx].len > 0;
        if (bound) {
            if (hubOwningPin(eps, explicit_pin[e.idx])) |hub| {
                if (gnd[hub].len > 0) {
                    if (try hubTargets(arena, eps, hub, roles)) |tgt| {
                        try emitCapLoop(arena, loops, eps, e, hub, tgt, gnd, explicit_pin, rail_optout, net_i);
                        continue;
                    }
                }
            }
        }
        try rest.append(arena, e);
    }
    if (rest.items.len >= 2) try weakCluster(arena, springs, rest.items, net_name);
}

/// Weak centre-to-centre pull among a net's endpoints (no single hub to hug).
/// The *force* stays centre-to-centre (the historical, tuned behaviour for these
/// weak K_SIG springs), but each spring records its two endpoints' pad offsets so
/// the rendered ratsnest joins the real pads — e.g. on a multi-hub net like a
/// crystal wired to an MCU (both `U`-prefixed → both hubs) the airwire runs
/// pin-to-pin, not box-centre to box-centre.
fn weakCluster(
    arena: std.mem.Allocator,
    springs: *std.ArrayListUnmanaged(Spring),
    eps: []const Endpoint,
    net_name: []const u8,
) std.mem.Allocator.Error!void {
    const r = eps[0];
    for (eps[1..]) |e| {
        if (e.idx == r.idx) continue;
        try springs.append(arena, .{
            .a = e.idx,
            .b = r.idx,
            .ax = 0,
            .ay = 0,
            .bx = 0,
            .by = 0,
            .k = K_SIG,
            .kind = .signal,
            .net = net_name,
            .dax = e.px,
            .day = e.py,
            .dbx = r.px,
            .dby = r.py,
        });
    }
}

/// A ground-net pad plus its placement class, used to pick a hub's *real*
/// return pads over config straps that merely happen to be tied to GND.
const TaggedPad = struct { rect: PadRect, cls: pin_roles.PinClass };

/// Per-part list of its ground-return pads (footprint-local rects), empty if
/// none. Drives both the decoupling test (cap & hub both have ground pads) and
/// the edge-aware ground leg (the nearest of these is the return target).
///
/// A hub's pads on a GND net are filtered to the real returns: a strap declared
/// `input`/`output`/`io` is dropped, and when any genuinely groundy-named pad
/// exists the non-groundy ones (e.g. an `ILIM` strap tied to GND) are dropped
/// too — so the loop never closes on a config pin. Passive pads (a cap's own
/// ground pad) are always kept. The selection never empties a part that had any
/// GND pad, so the decoupling test and fallback behaviour are preserved.
fn groundPads(
    arena: std.mem.Allocator,
    nets: []const FlatNet,
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    roles: []const pin_roles.PartRoles,
) std.mem.Allocator.Error![]const []const PadRect {
    var lists = try arena.alloc(std.ArrayListUnmanaged(TaggedPad), parts.len);
    for (lists) |*l| l.* = .empty;
    for (nets) |net| {
        if (!isGroundName(shortName(net.name))) continue;
        for (net.pins) |pr| {
            const i = idx_of.get(pr.ref_des) orelse continue;
            const pad = padLocal(parts[i], pr.pin);
            // A passive's ground pad is always real; only a hub's GND net also
            // carries straps, so only hubs consult their pin roles.
            const cls = if (parts[i].kind == .hub) roles[i].classOf(pr.pin) else .ground;
            try lists[i].append(arena, .{ .rect = .{ .x = pad.x, .y = pad.y, .w = pad.w, .h = pad.h }, .cls = cls });
        }
    }
    var out = try arena.alloc([]const PadRect, parts.len);
    for (lists, 0..) |*l, i| out[i] = try selectGroundPads(arena, l.items);
    return out;
}

/// Pick a part's return pads from its tagged GND pads, in tiers: real grounds
/// first; failing that, anything not a strap; failing that (every pad was a
/// strap), all of them — so a part with GND pads is never left empty.
fn selectGroundPads(arena: std.mem.Allocator, tagged: []const TaggedPad) std.mem.Allocator.Error![]const PadRect {
    var out: std.ArrayListUnmanaged(PadRect) = .empty;
    for (tagged) |t| if (t.cls == .ground) try out.append(arena, t.rect);
    if (out.items.len > 0) return out.toOwnedSlice(arena);
    for (tagged) |t| if (t.cls != .strap) try out.append(arena, t.rect);
    if (out.items.len > 0) return out.toOwnedSlice(arena);
    for (tagged) |t| try out.append(arena, t.rect);
    return out.toOwnedSlice(arena);
}

/// Largest net (pin count) `wireScore` builds the explicit point set for; bigger
/// nets fall back to the cheap bounding-box HPWL (a power/ground-ish rail where
/// the looser estimate is fine). Bounds the per-net RMST work at O(n²) ≤ 64².
const MAX_WIRE_PTS: usize = 64;

/// Signal-net wirelength estimate (ground excluded) — the wirelength part of the
/// inner-loop objective (`objectiveCost`), split out so it's cheap to re-evaluate.
/// HPWL (bounding-box half-perimeter) is *exact* for 2- and 3-pin nets, so those
/// keep the fast path; for nets of degree ≥4 HPWL systematically under-estimates
/// the routed tree, so we use the rectilinear minimum spanning tree (`rmstLen`)
/// — a much closer proxy for routed multi-pin wirelength (Chow & Young; FLUTE).
/// The `Score.hpwl_mm` / `Breakdown.hpwl` fields keep their historical names but
/// now carry this RSMT estimate.
fn wireScore(parts: []const Part, idx_of: *std.StringHashMap(usize), nets: []const FlatNet) f64 {
    var total: f64 = 0;
    var pts: [MAX_WIRE_PTS]Pt = undefined;
    for (nets) |net| {
        if (isGroundName(shortName(net.name))) continue;
        total += netWire(parts, idx_of, net, &pts);
    }
    return total;
}

/// Wirelength estimate for one net (mm): bounding-box HPWL for ≤3 pins (exact
/// RSMT, fast path), rectilinear MST for larger. `pts` is a scratch buffer the
/// caller owns. Factored out of `wireScore` so the constraint layer can weight
/// an individual net's contribution (`net-length` / `deprioritize`) without
/// re-deriving it. Caller skips ground nets.
fn netWire(parts: []const Part, idx_of: *std.StringHashMap(usize), net: FlatNet, pts: *[MAX_WIRE_PTS]Pt) f64 {
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    var cnt: usize = 0;
    for (net.pins) |pr| {
        const i = idx_of.get(pr.ref_des) orelse continue;
        const pad = padLocal(parts[i], pr.pin);
        const w = worldPt(parts[i], pad.x, pad.y);
        if (cnt < MAX_WIRE_PTS) pts[cnt] = w;
        minx = @min(minx, w.x);
        miny = @min(miny, w.y);
        maxx = @max(maxx, w.x);
        maxy = @max(maxy, w.y);
        cnt += 1;
    }
    if (cnt < 2) return 0;
    // HPWL = RSMT for ≤3 pins (keep the fast path); RMST for the rest.
    if (cnt <= 3 or cnt > MAX_WIRE_PTS) return (maxx - minx) + (maxy - miny);
    return rmstLen(pts[0..cnt]);
}

/// Rectilinear minimum spanning tree length (Prim, Manhattan metric) over `pts`
/// — a tighter routed-wirelength estimate than the bounding-box HPWL, which
/// under-estimates nets of degree >3. RMST bounds the rectilinear Steiner
/// minimal tree from above (RSMT ≤ RMST ≤ 1.5·RSMT) where HPWL bounds it from
/// below (HPWL ≤ RSMT), so it is the better placement-steering proxy. `pts.len`
/// is in [2, MAX_WIRE_PTS]; full FLUTE LUTs would tighten this toward exact RSMT.
fn rmstLen(pts: []const Pt) f64 {
    const n = pts.len;
    var in_tree = [_]bool{false} ** MAX_WIRE_PTS;
    var best: [MAX_WIRE_PTS]f64 = undefined;
    in_tree[0] = true;
    for (1..n) |i| best[i] = manhattan(pts[0], pts[i]);
    var total: f64 = 0;
    var added: usize = 1;
    while (added < n) : (added += 1) {
        // Nearest not-yet-connected pin to the current tree.
        var bj: usize = 0;
        var bd: f64 = std.math.inf(f64);
        for (1..n) |j| {
            if (!in_tree[j] and best[j] < bd) {
                bd = best[j];
                bj = j;
            }
        }
        in_tree[bj] = true;
        total += bd;
        for (1..n) |k| {
            if (!in_tree[k]) best[k] = @min(best[k], manhattan(pts[bj], pts[k]));
        }
    }
    return total;
}

/// Manhattan (rectilinear) distance between two points (mm).
fn manhattan(a: Pt, b: Pt) f64 {
    return @abs(a.x - b.x) + @abs(a.y - b.y);
}

/// Signal-net wirelength estimate (`wireScore`) + the decoupling loops' length. The loop term here is
/// the fixed-pad *surrogate* (power leg to the pinned pin + cap span + ground
/// return) — the smooth metric the reported score uses verbatim (no routed
/// override; the maze router is reserved for the finishing passes, not scoring).
fn scoreLayout(
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
) Score {
    return .{
        .hpwl_mm = wireScore(parts, idx_of, nets),
        .loop_mm = surrogateLoops(parts, loops).raw_mm,
        .loop_caps = loops.len,
    };
}

/// Spring relaxation: springs + edge-aware decoupling-loop pulls + courtyard
/// repulsion, with a cooling step.
fn relax(parts: []Part, springs: []const Spring, loops: []const Loop) void {
    const n = parts.len;
    if (n == 0 or n > maxParts) return;
    // Rotation is fixed across the call, so the keepout boxes are too — compute
    // them once instead of re-deriving per pair per iteration.
    var boxes: [maxParts]KeepBox = undefined;
    fillKeepBoxes(parts, boxes[0..n]);
    var it: usize = 0;
    while (it < ITERS) : (it += 1) {
        const cool = 1.0 - @as(f64, @floatFromInt(it)) / @as(f64, @floatFromInt(ITERS));
        const step = 0.1 + 0.7 * cool;

        var ax: [maxParts]f64 = undefined;
        var ay: [maxParts]f64 = undefined;
        for (0..n) |i| {
            ax[i] = 0;
            ay[i] = 0;
        }

        for (springs) |s| {
            const aw = worldPt(parts[s.a], s.ax, s.ay);
            const bw = worldPt(parts[s.b], s.bx, s.by);
            const dx = bw.x - aw.x;
            const dy = bw.y - aw.y;
            ax[s.a] += s.k * dx;
            ay[s.a] += s.k * dy;
            ax[s.b] -= s.k * dx;
            ay[s.b] -= s.k * dy;
        }

        accumulateLoops(parts, loops, &ax, &ay);
        accumulateCompaction(parts, &ax, &ay);
        accumulateGroupCohesion(parts, &ax, &ay);
        _ = accumulateRepulsion(parts, boxes[0..n], &ax, &ay, 0);

        var maxdisp: f64 = 0;
        for (0..n) |i| {
            const mass = if (parts[i].kind == .hub) HUB_MASS else PASSIVE_MASS;
            const dx = clampDisp(step * ax[i] / mass);
            const dy = clampDisp(step * ay[i] / mass);
            parts[i].x += dx;
            parts[i].y += dy;
            maxdisp = @max(maxdisp, @max(@abs(dx), @abs(dy)));
        }
        // The relaxation is damped + cooled, so once the largest per-step move
        // falls well under the grid it has settled and further iterations only
        // jitter sub-grid — stop early. (Fixed 600 iters for a ~dozen parts is
        // mostly spent here, after equilibrium.) The cooling schedule still
        // keys on the full ITERS, so the early iterations are unchanged.
        if (maxdisp < RELAX_CONVERGE_MM) break;
    }
}

/// Pull each decoupling cap so its power and ground pads close on the nearest
/// hub power / ground pad (edge-to-edge). The force acts along the current
/// gap vector, so it vanishes once the pads touch — repulsion then sets the
/// final clearance. This replaces the old centroid power/ground springs.
fn accumulateLoops(parts: []const Part, loops: []const Loop, ax: []f64, ay: []f64) void {
    for (loops, 0..) |lp, li| {
        // Bank caps (a ≥2-member same-rail group) get their loop force relieved so
        // the relaxation stops yanking each onto the rail pad — cohesion packs them
        // (see `g_loop_force_scale`). 1.0 for a lone cap / when relief is off.
        const scale = if (li < g_loop_force_scale.len) g_loop_force_scale[li] else 1.0;
        if (scale <= 0) continue;
        // Both legs pull toward their *pinned* hub pads (matching the score), so a
        // cap settles with each pad facing its assigned pin — power pad to the
        // supply pin, ground pad to the nearby ground pin — not the nearest of each.
        const pwr_pin = [_]PadRect{lp.hub_pwr_pin};
        const gnd_pin = [_]PadRect{lp.hub_gnd_pin};
        accumulateLeg(parts, lp.cap, lp.cap_pwr, lp.hub, &pwr_pin, scale, ax, ay);
        accumulateLeg(parts, lp.cap, lp.cap_gnd, lp.hub, &gnd_pin, scale, ax, ay);
    }
}

/// Cohesion force: pull every `(group …)` member toward its group's centroid,
/// the position-space twin of the `constraintCost` cohesion term (which alone
/// can only *select*, not *create*, a tight block — see `g_group_force`). No-op
/// when no groups are live or the gain is zero.
fn accumulateGroupCohesion(parts: []const Part, ax: []f64, ay: []f64) void {
    if (g_group_force <= 0 or !g_lowered.active) return;
    for (g_lowered.groups) |g| {
        if (g.members.len < 2) continue;
        const inv = 1.0 / @as(f64, @floatFromInt(g.members.len));
        var cx: f64 = 0;
        var cy: f64 = 0;
        // The group's anchor is its largest hub member (the IC) — it stays put so
        // the cluster gathers around it, not the other way round. A *secondary* hub
        // (e.g. a power inductor in the switching cell) is NOT the anchor and IS
        // pulled in, so the inductor docks beside the IC instead of floating off.
        var anchor: usize = g.members[0];
        var anchor_area: f64 = -1;
        for (g.members) |m| {
            cx += parts[m].x;
            cy += parts[m].y;
            if (parts[m].kind == .hub and parts[m].hw * parts[m].hh > anchor_area) {
                anchor_area = parts[m].hw * parts[m].hh;
                anchor = m;
            }
        }
        cx *= inv;
        cy *= inv;
        // Zoning target: the point a fixed reach beyond the hub edge on the side
        // the group wires to (VIN caps left, VOUT caps right, …). Pulling every
        // member toward it migrates the whole cluster to that side; null ⇒ no zone.
        var zone: ?Pt = null;
        if (g_zone_force > 0 and g.hub >= 0) {
            const hub = parts[@intCast(g.hub)];
            const d = rotateLocal(g.dirx, g.diry, hub.rot);
            const reach = @abs(d.x) * hub.hw + @abs(d.y) * hub.hh + ZONE_GAP_MM;
            zone = .{ .x = hub.x + d.x * reach, .y = hub.y + d.y * reach };
        }
        for (g.members) |m| {
            if (anchor_area >= 0 and m == anchor) continue; // keep the IC anchored
            ax[m] += g_group_force * (cx - parts[m].x);
            ay[m] += g_group_force * (cy - parts[m].y);
            if (zone) |z| {
                ax[m] += g_zone_force * (z.x - parts[m].x);
                ay[m] += g_zone_force * (z.y - parts[m].y);
            }
        }
    }
}

/// One loop leg: pull `cap`'s pad toward the nearest of `hub`'s `hub_pads`,
/// along the edge-to-edge gap vector (no force once touching).
fn accumulateLeg(
    parts: []const Part,
    cap: usize,
    cap_pad: PadRect,
    hub: usize,
    hub_pads: []const PadRect,
    scale: f64,
    ax: []f64,
    ay: []f64,
) void {
    const cr = worldRect(parts[cap], cap_pad);
    const near = nearestHubPad(cr, parts[hub], hub_pads);
    if (near.gap < 1e-6) return; // touching → loop leg already minimal
    const np = nearestPoints(cr, near.rect);
    const dx = scale * K_DECOUPLE * (np.b.x - np.a.x);
    const dy = scale * K_DECOUPLE * (np.b.y - np.a.y);
    ax[cap] += dx;
    ay[cap] += dy;
    ax[hub] -= dx;
    ay[hub] -= dy;
}

/// Repulsion-only passes that fully resolve any courtyard overlap, leaving an
/// extra `clearance` mm gap between every pair.
fn legalize(parts: []Part, clearance: f64) void {
    const n = parts.len;
    if (n == 0 or n > maxParts) return;
    var boxes: [maxParts]KeepBox = undefined;
    fillKeepBoxes(parts, boxes[0..n]);
    var it: usize = 0;
    while (it < LEGALIZE_ITERS) : (it += 1) {
        var ax: [maxParts]f64 = undefined;
        var ay: [maxParts]f64 = undefined;
        for (0..n) |i| {
            ax[i] = 0;
            ay[i] = 0;
        }
        const moved = accumulateRepulsion(parts, boxes[0..n], &ax, &ay, clearance);
        if (!moved) break;
        for (0..n) |i| {
            parts[i].x += ax[i];
            parts[i].y += ay[i];
        }
    }
}

/// Grid-aligned safety net: after snapping, nudge overlapping parts apart by
/// whole grid cells (so they stay on-grid) until no two courtyards overlap.
/// Normally a no-op — `legalize(FINAL_CLEAR)` already left enough gap.
fn legalizeOnGrid(parts: []Part) void {
    const n = parts.len;
    if (n == 0) return;
    var it: usize = 0;
    while (it < LEGALIZE_ITERS) : (it += 1) {
        var any = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j: usize = i + 1;
            while (j < n) : (j += 1) {
                if (parts[i].side != parts[j].side) continue;
                const dx = keepCx(parts[i]) - keepCx(parts[j]);
                const dy = keepCy(parts[i]) - keepCy(parts[j]);
                const ox = (keepHw(parts[i]) + keepHw(parts[j])) - @abs(dx);
                const oy = (keepHh(parts[i]) + keepHh(parts[j])) - @abs(dy);
                if (ox <= 0 or oy <= 0) continue;
                any = true;
                // Move the higher-index part one cell away on the tight axis.
                if (ox < oy) {
                    parts[j].x -= signNudge(dx, i, j) * GRID_MM;
                } else {
                    parts[j].y -= signNudge(dy, i, j) * GRID_MM;
                }
            }
        }
        if (!any) break;
    }
}

/// Gentle pull of every part toward the cluster centroid. Counteracts the
/// outward drift that repulsion + pin-hugging produce, keeping the bounding
/// box (and thus HPWL) compact instead of fanning passives around the hub.
fn accumulateCompaction(parts: []const Part, ax: []f64, ay: []f64) void {
    const n = parts.len;
    if (n < 2) return;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (parts) |p| {
        cx += p.x;
        cy += p.y;
    }
    cx /= @floatFromInt(n);
    cy /= @floatFromInt(n);
    for (parts, 0..) |p, i| {
        ax[i] += K_COMPACT * (cx - p.x);
        ay[i] += K_COMPACT * (cy - p.y);
    }
}

/// A part's collision box reduced to position-independent terms, so the O(n²)
/// repulsion inner loop is pure arithmetic. `cxo`/`cyo` are the rotated keepout
/// centre offset (world centre = `part.x + cxo`); `hw`/`hh` the rotation-aware
/// half-extents. All four depend only on rotation + footprint, which are fixed
/// across a relax/legalize call — recomputing `keepCx`/`keepHw` (each a branch
/// + `isQuarter`'s `@mod`/`@round`) for every pair every iteration was the bulk
/// of the relaxation's cost. Mirrors `keepCx`/`keepCy`/`keepHw`/`keepHh` exactly.
const KeepBox = struct { cxo: f64, cyo: f64, hw: f64, hh: f64 };

fn keepBoxOf(p: Part) KeepBox {
    const q = isQuarter(p.rot);
    const s = g_collide_shrink; // courtyards may overlap their clearance margins
    const r = g_route_gap; // …or leave extra routing room between them
    if (p.keep.hw < 0) {
        const ccx = if (p.side == .bottom) -p.ccx else p.ccx;
        const coff = rotateLocal(ccx, p.ccy, p.rot);
        return .{ .cxo = coff.x, .cyo = coff.y, .hw = @max(0.0, (if (q) p.hh else p.hw) - s) + r, .hh = @max(0.0, (if (q) p.hw else p.hh) - s) + r };
    }
    const kox = if (p.side == .bottom) -p.keep.ox else p.keep.ox;
    const off = rotateLocal(kox, p.keep.oy, p.rot);
    const hw = @max(0.0, (if (q) p.keep.hh else p.keep.hw) - s) + r;
    const hh = @max(0.0, (if (q) p.keep.hw else p.keep.hh) - s) + r;
    return .{ .cxo = off.x, .cyo = off.y, .hw = hw, .hh = hh };
}

/// Fill `out[0..parts.len]` with each part's precomputed keepout box.
fn fillKeepBoxes(parts: []const Part, out: []KeepBox) void {
    for (parts, 0..) |p, i| out[i] = keepBoxOf(p);
}

/// Add separation forces for every overlapping courtyard pair (rotation-aware
/// extents, plus a `clearance` margin) along the axis of least penetration.
/// `boxes[i]` is `parts[i]`'s precomputed keepout (see `fillKeepBoxes`).
/// Returns true if any pair overlapped.
fn accumulateRepulsion(parts: []const Part, boxes: []const KeepBox, ax: []f64, ay: []f64, clearance: f64) bool {
    const n = parts.len;
    var any = false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const cxi = parts[i].x + boxes[i].cxo;
        const cyi = parts[i].y + boxes[i].cyo;
        var j: usize = i + 1;
        while (j < n) : (j += 1) {
            if (parts[i].side != parts[j].side) continue;
            const dx = cxi - (parts[j].x + boxes[j].cxo);
            const dy = cyi - (parts[j].y + boxes[j].cyo);
            const ox = (boxes[i].hw + boxes[j].hw + clearance) - @abs(dx);
            const oy = (boxes[i].hh + boxes[j].hh + clearance) - @abs(dy);
            if (ox <= 0 or oy <= 0) continue;
            any = true;
            // Push apart along the axis of least overlap; split evenly.
            if (ox < oy) {
                const push = ox / 2 + 1e-3;
                const s = signNudge(dx, i, j);
                ax[i] += s * push;
                ax[j] -= s * push;
            } else {
                const push = oy / 2 + 1e-3;
                const s = signNudge(dy, i, j);
                ay[i] += s * push;
                ay[j] -= s * push;
            }
        }
    }
    return any;
}

/// Deterministic separation direction; breaks exact ties by index parity.
fn signNudge(d: f64, i: usize, j: usize) f64 {
    if (d > 0) return 1;
    if (d < 0) return -1;
    return if ((i + j) % 2 == 0) 1 else -1;
}

fn clampDisp(v: f64) f64 {
    return std.math.clamp(v, -MAX_DISP_MM, MAX_DISP_MM);
}

/// Seed for one multi-start attempt: hubs anchor on a compact grid at the
/// centre; passives fan out on a ring around them, each at a low-discrepancy
/// angle that depends on both the passive's ordinal and the start index, so
/// different starts approach their pins from different sides.
fn seedRing(parts: []Part, start: usize) void {
    const n = parts.len;
    if (n == 0) return;
    var maxext: f64 = 0.5;
    for (parts) |p| maxext = @max(maxext, @max(p.hw, p.hh));
    const cell = 2 * maxext + SEED_GAP_MM;
    const radius = cell * 1.6;

    var hub_count: usize = 0;
    for (parts) |p| {
        if (p.kind == .hub) hub_count += 1;
    }
    const hub_cols = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(@max(hub_count, 1))))))));

    var placed_hubs: usize = 0;
    var pord: usize = 0;
    for (parts) |*p| {
        if (p.kind == .hub) {
            const col = placed_hubs % hub_cols;
            const row = placed_hubs / hub_cols;
            p.x = (@as(f64, @floatFromInt(col)) - @as(f64, @floatFromInt(hub_cols - 1)) / 2) * cell;
            p.y = @as(f64, @floatFromInt(row)) * cell;
            placed_hubs += 1;
        } else {
            const t = seedAngle(pord, start);
            p.x = radius * @cos(t);
            p.y = radius * @sin(t);
            pord += 1;
        }
    }
}

/// Seed every part on a roughly-square grid sized by the largest courtyard,
/// so the relaxation starts overlap-free. Used for large boards, where the
/// ring seed would pile every part onto one circle (a hugely overlapping
/// start the legalizer then has to untangle).
fn seedGrid(parts: []Part) void {
    const n = parts.len;
    if (n == 0) return;
    var cell: f64 = 1.0;
    for (parts) |p| cell = @max(cell, 2 * @max(p.hw, p.hh));
    cell += SEED_GAP_MM;
    const cols = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(@as(f64, @floatFromInt(n)))))));
    for (parts, 0..) |*p, i| {
        p.x = @as(f64, @floatFromInt(i % cols)) * cell;
        p.y = @as(f64, @floatFromInt(i / cols)) * cell;
    }
}

/// Low-discrepancy seed angle (radians) for passive ordinal `k` on start `s`.
/// The golden-ratio term spreads the passives within a start; the per-start
/// cross term decorrelates the arrangement across starts.
fn seedAngle(k: usize, s: usize) f64 {
    const phi = 0.6180339887498949;
    const phi2 = 0.7548776662466927;
    const kf: f64 = @floatFromInt(k + 1);
    const sf: f64 = @floatFromInt(s);
    return @mod(kf * phi + sf * kf * phi2, 1.0) * std.math.tau;
}

/// Center the layout on the origin and build the ratsnest + bounding box.
fn finalize(
    arena: std.mem.Allocator,
    parts: []Part,
    springs: []const Spring,
    loops: []const Loop,
    stubs: []const Stub,
    instances: []const export_kicad.FlatInstance,
    nets: []const FlatNet,
    priority: []const u32,
    score: Score,
    breakdown: Breakdown,
    generated: bool,
) std.mem.Allocator.Error!Placement {
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (parts) |p| {
        // Frame to the keepout box so escape stubs aren't clipped (it equals
        // the courtyard for parts with no stub).
        minx = @min(minx, keepCx(p) - keepHw(p));
        miny = @min(miny, keepCy(p) - keepHh(p));
        maxx = @max(maxx, keepCx(p) + keepHw(p));
        maxy = @max(maxy, keepCy(p) + keepHh(p));
    }
    if (parts.len == 0) {
        minx = 0;
        miny = 0;
        maxx = 0;
        maxy = 0;
    }

    var links = try arena.alloc(Link, springs.len);
    for (springs, 0..) |s, i| {
        // A `.signal` spring pulls part centres (its tuned force) but should be
        // *drawn* pad-to-pad — so the inter-hub ratsnest reads pin-to-pin. Its
        // draw offsets live in `dax/…`; every other spring already holds the pad
        // offsets in `ax/…`, so the force and draw endpoints coincide.
        const pads = s.kind == .signal;
        links[i] = .{
            .a = s.a,
            .b = s.b,
            .ax = if (pads) s.dax else s.ax,
            .ay = if (pads) s.day else s.ay,
            .bx = if (pads) s.dbx else s.bx,
            .by = if (pads) s.dby else s.by,
            .kind = s.kind,
            .net = s.net,
        };
    }

    return .{
        .parts = parts,
        .links = links,
        .loops = loops,
        .stubs = stubs,
        .instances = instances,
        .nets = nets,
        .priority = priority,
        .score = score,
        .breakdown = breakdown,
        .minx = minx,
        .miny = miny,
        .maxx = maxx,
        .maxy = maxy,
        .generated = generated,
    };
}

/// Upper bound on parts the stack-allocated force accumulators support.
/// Modules are tiny; whole boards stay well under this.
const maxParts: usize = 4096;

/// Pad position (origin-relative mm) for `pin` on `part`, or the part
/// centre (0,0) when the pad isn't in the footprint (e.g. fallback boxes).
fn padLocal(part: Part, pin: []const u8) geometry.Pad {
    for (part.pads) |p| {
        if (std.mem.eql(u8, p.number, pin)) return p;
    }
    return .{ .number = pin, .x = 0, .y = 0, .w = 0, .h = 0 };
}

/// True if the ref-des is an inductor (prefix `L`) — a switch-node / high-di/dt
/// part, used to detect a switching regulator for input-hot-loop weighting.
fn isInductor(ref: []const u8) bool {
    const s = shortName(ref);
    return s.len > 0 and (s[0] == 'L' or s[0] == 'l');
}

/// Resolve a flat instance's value string (the `value` field, else a `value`
/// property), used for value-ordered decoupling. Empty when unknown.
fn instValue(inst: export_kicad.FlatInstance) []const u8 {
    if (inst.value.len > 0) return inst.value;
    for (inst.properties) |prop| {
        if (std.mem.eql(u8, prop.key, "value") and prop.value.len > 0) return prop.value;
    }
    return "";
}

/// Parse a capacitance value string ("100nF", "4.7uF", "0.47uF") to farads,
/// or 0 when it has no recognised metric suffix.
fn capValueFarads(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
    if (i == 0) return 0;
    const num = std.fmt.parseFloat(f64, s[0..i]) catch return 0;
    if (i >= s.len) return 0;
    const mult: f64 = switch (s[i]) {
        'p', 'P' => 1e-12,
        'n', 'N' => 1e-9,
        'u', 'U' => 1e-6,
        'm' => 1e-3,
        else => return 0,
    };
    return num * mult;
}

/// A part is a hub unless its ref-des prefix is a passive (R/C/L/F/D),
/// mirroring the schematic hub/spoke split. Handles `sub/U1` ref-des.
fn isHub(ref: []const u8) bool {
    const s = shortName(ref);
    if (s.len == 0) return true;
    return switch (s[0]) {
        // Passives that hang off a hub, never anchor the layout. 'Y' is a crystal/
        // oscillator: a 2-pin part wired to an IC's XTAL pins with its own load
        // caps — treating it as a hub strands an extra anchor that pulls the cap
        // cluster away from the real IC (see bcuda-mcu-w55rp20).
        'R', 'C', 'L', 'F', 'D', 'Y' => false,
        else => true,
    };
}

/// True when `name` (already leaf-stripped) is a ground rail. Public so the
/// router (`router.zig`) shares the exact same predicate — the two used to keep
/// hand-copied lists and the router's drifted, routing numbered/split grounds as
/// signal copper.
pub fn isGroundName(name: []const u8) bool {
    // A ground rail is one of these tokens, optionally with a *numbered* suffix
    // (GND1, GND2, AGND2, VSS1, PGND_2 on a multi-ground part) — an exact-match list
    // missed numbered grounds, so on an isolated/split-ground part those nets read
    // as *signal*, corrupting loop detection, rail direction, and scoring. The
    // suffix must be (an optional single '_'/'-' then) all digits, so a real signal
    // like GND_SENSE / GNDSW stays a signal. Longer tokens first so e.g. GNDA isn't
    // shadowed by GND.
    const tokens = [_][]const u8{ "GNDA", "GNDD", "AGND", "PGND", "DGND", "VSSA", "GND", "VSS" };
    for (tokens) |t| {
        if (!std.mem.startsWith(u8, name, t)) continue;
        var rest = name[t.len..];
        if (rest.len == 0) return true;
        if (rest[0] == '_' or rest[0] == '-') rest = rest[1..];
        if (rest.len == 0) return false; // bare separator, no number
        for (rest) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }
    return false;
}

/// Last path segment of a `parent/child` ref-des or net name.
fn shortName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/optimizer - classifies hub vs passive ref-des, handling hierarchical paths
test "isHub classifies passives and hubs, including sub-block paths" {
    try testing.expect(isHub("U1"));
    try testing.expect(isHub("pwr/U1"));
    try testing.expect(!isHub("C1"));
    try testing.expect(!isHub("pwr/R2"));
    try testing.expect(!isHub("L7"));
    try testing.expect(!isHub("Y1")); // crystal — passive, hangs off the IC
}

// spec: placement/optimizer - excludes ground nets from spring forces
test "isGroundName matches common ground rails" {
    try testing.expect(isGroundName("GND"));
    try testing.expect(isGroundName(shortName("pwr/GND")));
    try testing.expect(!isGroundName("VIN"));
    try testing.expect(!isGroundName("3.3V"));
    // Numbered / suffixed grounds on multi-ground parts (isolated, split-rail).
    try testing.expect(isGroundName("GND1"));
    try testing.expect(isGroundName("GND2"));
    try testing.expect(isGroundName("AGND2"));
    try testing.expect(isGroundName("VSS1"));
    try testing.expect(isGroundName("PGND_2")); // separator + digits = numbered ground
    // A real signal that starts with a ground token but isn't a numbered ground.
    try testing.expect(!isGroundName("GND_SENSE"));
    try testing.expect(!isGroundName("GNDSW"));
    try testing.expect(!isGroundName("VINGND")); // doesn't start with a ground token
}

// spec: placement/optimizer - legalization separates two overlapping courtyards
test "legalize removes overlap between two parts" {
    var parts = [_]Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = true, .x = 0, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = true, .x = 0.5, .y = 0 },
    };
    legalize(&parts, 0);
    const dx = @abs(parts[0].x - parts[1].x);
    const dy = @abs(parts[0].y - parts[1].y);
    // No longer overlapping on at least one axis.
    try testing.expect(dx >= (parts[0].hw + parts[1].hw) - 1e-2 or dy >= (parts[0].hh + parts[1].hh) - 1e-2);
}

// spec: placement/optimizer - rotates footprint-local offsets in right-angle steps matching the page
test "rotateLocal applies exact right-angle turns" {
    const r90 = rotateLocal(1, 0, 90);
    try testing.expectApproxEqAbs(@as(f64, 0), r90.x, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), r90.y, 1e-12);
    const r180 = rotateLocal(1, 0, 180);
    try testing.expectApproxEqAbs(@as(f64, -1), r180.x, 1e-12);
    // A quarter turn swaps the courtyard extents.
    const p = Part{ .ref_des = "C1", .kind = .passive, .hw = 2, .hh = 1, .pads = &.{}, .fallback = true, .rot = 90 };
    try testing.expectEqual(@as(f64, 1), effHw(p));
    try testing.expectEqual(@as(f64, 2), effHh(p));
}

// spec: placement/optimizer - rotation refine picks the orientation that shortens the decoupling loop
test "optimizeRotations flips a cap to face both its pinned power and ground pins" {
    // Hub U1 at origin: supply pad left (-0.5,-1), ground pad right (0.5,-1). Cap
    // C1 below at (0,-2) with its pads CROSSED at rot 0 (power right, ground left).
    // A 180° turn uncrosses them so the power pad faces the supply pin AND the
    // ground pad faces the ground pin — minimizing the FULL loop (both legs + cap
    // span + the two GND vias), not just the power leg.
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.2, .hh = 0.8, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.8, .hh = 0.4, .pads = &.{}, .fallback = false, .x = 0, .y = -2 },
    };
    const hub_pwr = [_]PadRect{.{ .x = -0.5, .y = -1, .w = 0.4, .h = 0.4 }};
    const hub_gnd = [_]PadRect{.{ .x = 0.5, .y = -1, .w = 0.4, .h = 0.4 }};
    const loops = [_]Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0.5, .y = -0.5, .w = 0.4, .h = 0.4 },
        .cap_gnd = .{ .x = -0.5, .y = -0.5, .w = 0.4, .h = 0.4 },
        .hub_pwr = &hub_pwr,
        .hub_pwr_pin = .{ .x = -0.5, .y = -1, .w = 0.4, .h = 0.4 },
        .hub_gnd = &hub_gnd,
        .hub_gnd_pin = .{ .x = 0.5, .y = -1, .w = 0.4, .h = 0.4 },
    }};

    var idx = std.StringHashMap(usize).init(testing.allocator);
    defer idx.deinit();
    try idx.put("U1", 0);
    try idx.put("C1", 1);

    const before = scoreLayout(&parts, &idx, &.{}, &loops).loop_mm;
    optimizeRotations(&parts, &idx, &.{}, &loops, .{});
    const after = scoreLayout(&parts, &idx, &.{}, &loops).loop_mm;
    try testing.expectEqual(@as(f64, 180), parts[1].rot); // uncrossed — both pads face their pins
    try testing.expect(after < before - 0.3); // and it shortened the full loop
}

// spec: placement/optimizer - reserves a breakout corridor only for single-component nets
test "buildEscapeStubs reserves a corridor for unaccounted single-component nets" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // R1's pin 2 is on net RFIN, which touches only R1 (unaccounted → escape).
    // Net SIG touches R1 + U1 (two components → already steered, no stub).
    const pads_r = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.4, .h = 0.4 },
    };
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 1, .hh = 0.5, .pads = &pads_r, .fallback = false },
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false },
    };
    const rfin = [_]export_kicad.FlatPin{.{ .ref_des = "R1", .pin = "2" }};
    const sig = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "U1", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "RFIN", .pins = &rfin }, .{ .name = "SIG", .pins = &sig } };

    var idx = std.StringHashMap(usize).init(arena);
    try idx.put("R1", 0);
    try idx.put("U1", 1);

    const stubs = try buildEscapeStubs(arena, &nets, &parts, &idx);
    try testing.expectEqual(@as(usize, 1), stubs.len); // RFIN only
    try testing.expectEqual(@as(usize, 0), stubs[0].part); // on R1
    try testing.expectApproxEqAbs(@as(f64, 2.5), stubs[0].bx, 1e-9); // 0.5 + 2 mm, outward +x

    applyKeepout(&parts, stubs);
    try testing.expect(parts[0].keep.hw > parts[0].hw); // R1 keepout grew right
    try testing.expect(parts[1].keep.hw < 0); // U1 unchanged (sentinel)
}

// spec: placement/optimizer - an explicit (decouples …) binding still loops to its hub on a rail shared by >=2 ICs
test "buildSprings honours explicit decoupling bindings on a multi-hub rail" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // VDD lands on both U1 (MCU) and U2 (flash) → a multi-hub rail. C1 is bound
    // to U1 pad 5, C2 to U2 pad 8. Each must still form a real loop to its own
    // hub instead of the whole rail collapsing into one weak cluster (loops==0).
    const u1_pads = [_]geometry.Pad{
        .{ .number = "5", .x = -2, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "15", .x = -2, .y = 1, .w = 0.3, .h = 0.3 },
        .{ .number = "81", .x = -2, .y = -1, .w = 0.3, .h = 0.3 },
    };
    const u2_pads = [_]geometry.Pad{
        .{ .number = "8", .x = 2, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "4", .x = 2, .y = -1, .w = 0.3, .h = 0.3 },
    };
    const cap_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.4, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "2", .x = 0.4, .y = 0, .w = 0.3, .h = 0.3 },
    };
    const parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &u1_pads, .fallback = false },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &u2_pads, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.3, .pads = &cap_pads, .fallback = false },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.3, .pads = &cap_pads, .fallback = false },
    };
    const vdd = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "5" }, .{ .ref_des = "U1", .pin = "15" },
        .{ .ref_des = "U2", .pin = "8" }, .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
    };
    const gnd_net = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "81" }, .{ .ref_des = "U2", .pin = "4" },
        .{ .ref_des = "C1", .pin = "2" },  .{ .ref_des = "C2", .pin = "2" },
    };
    const nets = [_]FlatNet{
        .{ .name = "VDD", .pins = &vdd },
        .{ .name = "GND", .pins = &gnd_net },
    };
    var idx = std.StringHashMap(usize).init(arena);
    try idx.put("U1", 0);
    try idx.put("U2", 1);
    try idx.put("C1", 2);
    try idx.put("C2", 3);

    const roles = [_]pin_roles.PartRoles{ .{}, .{}, .{}, .{} };
    const explicit = [_][]const u8{ "", "", "5", "8" };
    const optout = [_]bool{ false, false, false, false };

    const built = try buildSprings(arena, &nets, &parts, &idx, &roles, &explicit, &optout);

    try testing.expectEqual(@as(usize, 2), built.loops.len);
    var saw_u1 = false;
    var saw_u2 = false;
    for (built.loops) |lp| {
        if (lp.cap == 2) { // C1 → U1 pad 5
            try testing.expectEqual(@as(usize, 0), lp.hub);
            try testing.expectEqualStrings("5", lp.explicit_pin);
            try testing.expectApproxEqAbs(@as(f64, -2), lp.hub_pwr_pin.x, 1e-9);
            saw_u1 = true;
        } else if (lp.cap == 3) { // C2 → U2 pad 8
            try testing.expectEqual(@as(usize, 1), lp.hub);
            try testing.expectEqualStrings("8", lp.explicit_pin);
            try testing.expectApproxEqAbs(@as(f64, 2), lp.hub_pwr_pin.x, 1e-9);
            saw_u2 = true;
        }
    }
    try testing.expect(saw_u1 and saw_u2);
}

// spec: placement/optimizer - loop legs measure edge-to-edge to the nearest hub pad
test "rectGap and nearestHubPad measure edge-to-edge to the closest pad" {
    // Two unit pads 1mm apart edge-to-edge on x.
    const a = Rect{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
    const b = Rect{ .x0 = 2, .y0 = 0, .x1 = 3, .y1 = 1 };
    try testing.expectApproxEqAbs(@as(f64, 1), rectGap(a, b), 1e-12);
    // Overlapping rects have zero gap.
    const c = Rect{ .x0 = 0.5, .y0 = 0.5, .x1 = 1.5, .y1 = 1.5 };
    try testing.expectEqual(@as(f64, 0), rectGap(a, c));
    // nearestHubPad picks the closer of two hub pads (edge-to-edge), so a big
    // far pad loses to a small near one.
    const hub = Part{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0 };
    const cap_rect = Rect{ .x0 = -0.1, .y0 = 2.0, .x1 = 0.1, .y1 = 2.2 };
    const pads = [_]PadRect{
        .{ .x = 0, .y = 1.5, .w = 0.2, .h = 0.2 }, // near: edge at y=1.6, gap 0.4
        .{ .x = 0, .y = -1, .w = 3.0, .h = 3.0 }, // big but far: edge at y=0.5
    };
    try testing.expectApproxEqAbs(@as(f64, 0.4), nearestHubPad(cap_rect, hub, &pads).gap, 1e-9);
}

// spec: placement/optimizer - ground-return selection keeps real grounds over straps, with a never-empty fallback
test "selectGroundPads prefers real grounds, then non-straps, then anything" {
    const g = PadRect{ .x = 0, .y = 0, .w = 0.3, .h = 0.3 };
    const ilim = PadRect{ .x = 1, .y = 0, .w = 0.3, .h = 0.3 };
    const strap = PadRect{ .x = 2, .y = 0, .w = 0.3, .h = 0.3 };

    // A real ground (pin 8/11) wins over an unannotated non-groundy pin (ILIM)
    // and an annotated strap — the loop closes on the GND_x pad, not the strap.
    {
        const tagged = [_]TaggedPad{
            .{ .rect = ilim, .cls = .other },
            .{ .rect = g, .cls = .ground },
            .{ .rect = strap, .cls = .strap },
        };
        const out = try selectGroundPads(testing.allocator, &tagged);
        defer testing.allocator.free(out);
        try testing.expectEqual(@as(usize, 1), out.len);
        try testing.expectApproxEqAbs(@as(f64, 0), out[0].x, 1e-12);
    }
    // No groundy name available: keep everything that isn't a strap.
    {
        const tagged = [_]TaggedPad{
            .{ .rect = ilim, .cls = .other },
            .{ .rect = strap, .cls = .strap },
        };
        const out = try selectGroundPads(testing.allocator, &tagged);
        defer testing.allocator.free(out);
        try testing.expectEqual(@as(usize, 1), out.len);
        try testing.expectApproxEqAbs(@as(f64, 1), out[0].x, 1e-12);
    }
    // Degenerate: every pad is a strap → fall back to all (never empty).
    {
        const tagged = [_]TaggedPad{.{ .rect = strap, .cls = .strap }};
        const out = try selectGroundPads(testing.allocator, &tagged);
        defer testing.allocator.free(out);
        try testing.expectEqual(@as(usize, 1), out.len);
    }
}

// spec: placement/optimizer - multi-pin wirelength uses the rectilinear MST, which equals span when collinear and exceeds HPWL otherwise
test "rmstLen is exact on collinear pins and tightens above HPWL for a 4-pin net" {
    // Collinear pins: the MST is just the span, which also equals HPWL.
    const line = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } };
    try testing.expectApproxEqAbs(@as(f64, 3.0), rmstLen(&line), 1e-12);

    // Unit square: MST is 3 edges of length 1 (= 3.0); HPWL is only 2.0, so the
    // RMST is the strictly larger — and more faithful — multi-pin estimate.
    const square = [_]Pt{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    const hpwl: f64 = 2.0; // (maxx-minx) + (maxy-miny)
    try testing.expectApproxEqAbs(@as(f64, 3.0), rmstLen(&square), 1e-12);
    try testing.expect(rmstLen(&square) > hpwl);
}

// spec: placement/optimizer - loop inductance floors at the via mounting inductance and rises with conductor length
test "loopInductanceNh floors at the via inductance and grows with length" {
    // A zero-length connection still has the two GND vias' series inductance — the
    // floor the pure-length model misses (so L never collapses to 0 as a cap nears
    // the pin). The floor is small but strictly positive.
    const floor = loopInductanceNh(0);
    try testing.expectApproxEqAbs(N_LOOP_VIAS * VIA_IND_NH, floor, 1e-12);
    try testing.expect(floor > 0);
    // Longer conductor ⇒ strictly more inductance, linear above the floor.
    try testing.expect(loopInductanceNh(2.0) > loopInductanceNh(0.5));
    try testing.expectApproxEqAbs(floor + LOOP_PUL_NH_PER_MM * 2.0, loopInductanceNh(2.0), 1e-9);
    // Per-unit-length inductance lands in the physically sane ~0.3–0.7 nH/mm band
    // for a trace over a 0.2 mm-adjacent plane.
    try testing.expect(LOOP_PUL_NH_PER_MM > 0.3 and LOOP_PUL_NH_PER_MM < 0.7);
}

/// Slide `parts[cap]` by `+dy` for `steps` steps, sampling the scored
/// (value-weighted) loop inductance each time. Returns the largest single-step
/// change and the start/end values — the continuity probe the smoothness test
/// asserts on (kept out of the test body so the test stays assertion-only).
fn loopStepProbe(parts: []Part, loops: []const Loop, cap: usize, dy: f64, steps: usize) struct { max_step: f64, start: f64, end: f64 } {
    var prev = surrogateLoops(parts, loops).weighted_nh;
    const start = prev;
    var max_step: f64 = 0;
    var k: usize = 0;
    while (k < steps) : (k += 1) {
        parts[cap].y += dy;
        const nh = surrogateLoops(parts, loops).weighted_nh;
        max_step = @max(max_step, @abs(nh - prev));
        prev = nh;
    }
    return .{ .max_step = max_step, .start = start, .end = prev };
}

// spec: placement/optimizer - the scored loop term is the smooth analytic surrogate, continuous in part position (no routing cliffs)
test "scored loop inductance is continuous as a cap slides toward its pin" {
    // Hub U1 power pad at (-0.5,-1); cap C1 starts 3 mm below and slides up toward
    // the pin in fine 0.05 mm steps. The scored loop term (`surrogateLoops`, which
    // `scoreLayout`/`scorePoses` now report verbatim) must change smoothly — far
    // below the multi-nH cliffs the maze-routed metric produced when a leg flipped
    // routable↔unroutable. This continuity is what keeps the drag-to-score and the
    // optimizer's objective a smooth function of position.
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.2, .hh = 0.8, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.8, .hh = 0.4, .pads = &.{}, .fallback = false, .x = 0, .y = -3 },
    };
    const hub_pwr = [_]PadRect{.{ .x = -0.5, .y = -1, .w = 0.4, .h = 0.4 }};
    const hub_gnd = [_]PadRect{.{ .x = 0.5, .y = -1, .w = 0.4, .h = 0.4 }};
    const loops = [_]Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = -0.5, .y = 0.5, .w = 0.4, .h = 0.4 },
        .cap_gnd = .{ .x = 0.5, .y = 0.5, .w = 0.4, .h = 0.4 },
        .hub_pwr = &hub_pwr,
        .hub_pwr_pin = .{ .x = -0.5, .y = -1, .w = 0.4, .h = 0.4 },
        .hub_gnd = &hub_gnd,
        .hub_gnd_pin = .{ .x = 0.5, .y = -1, .w = 0.4, .h = 0.4 },
    }};

    // 20 × 0.05 mm = 1 mm of travel, staying clear of the hub courtyard.
    const r = loopStepProbe(&parts, &loops, 1, 0.05, 20);
    // The surrogate is Lipschitz in distance: a 0.05 mm step moves the inductance
    // by ~LOOP_PUL_NH_PER_MM·0.05 ≈ 0.025 nH. Bound it well under 0.1 nH — a cliff
    // the routed metric would blow past by 1-2 orders of magnitude.
    try testing.expect(r.max_step < 0.1);
    // And sliding the cap closer to the pin strictly shortened the loop.
    try testing.expect(r.end < r.start);
}

// spec: placement/optimizer - input-rail names (and raw rails ≥7V) read as the switching hot loop; output/low rails do not
test "isInputRailName flags switching input rails, not outputs" {
    // Named input rails (separator/case-insensitive).
    try testing.expect(isInputRailName("VIN"));
    try testing.expect(isInputRailName("PVIN"));
    try testing.expect(isInputRailName("VBUS"));
    try testing.expect(isInputRailName("V_IN"));
    // Raw-voltage rails: ≥7 V is an input on a buck; lower rails are outputs.
    try testing.expect(isInputRailName("V_12V"));
    try testing.expect(isInputRailName("24V"));
    try testing.expect(!isInputRailName("V_3V3"));
    try testing.expect(!isInputRailName("V_5V"));
    // Outputs / switch node / ground are not the input hot loop.
    try testing.expect(!isInputRailName("VOUT"));
    try testing.expect(!isInputRailName("SW"));
    try testing.expect(!isInputRailName("GND"));
}

// spec: placement/optimizer - routing congestion is zero with no multi-pin nets and positive when nets pile into one region
test "congestionPenalty fires only on dense regions" {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    // Four parts at the corners of a ~0.5 mm board.
    var parts = [_]Part{
        .{ .ref_des = "A", .kind = .passive, .hw = 0.05, .hh = 0.05, .pads = &pad, .fallback = false, .x = 0.0, .y = 0.0 },
        .{ .ref_des = "B", .kind = .passive, .hw = 0.05, .hh = 0.05, .pads = &pad, .fallback = false, .x = 0.4, .y = 0.4 },
        .{ .ref_des = "C", .kind = .passive, .hw = 0.05, .hh = 0.05, .pads = &pad, .fallback = false, .x = 0.4, .y = 0.0 },
        .{ .ref_des = "D", .kind = .passive, .hw = 0.05, .hh = 0.05, .pads = &pad, .fallback = false, .x = 0.0, .y = 0.4 },
    };
    var idx_of = std.StringHashMap(usize).init(testing.allocator);
    defer idx_of.deinit();
    for (parts, 0..) |p, i| try idx_of.put(p.ref_des, i);

    // No multi-pin signal net → zero congestion.
    const lone = [_]export_kicad.FlatPin{.{ .ref_des = "A", .pin = "1" }};
    const empty_nets = [_]FlatNet{.{ .name = "NET1", .pins = &lone }};
    try testing.expectEqual(@as(f64, 0), congestionPenalty(&parts, &idx_of, &empty_nets));

    // Three nets each spanning the small board overlap in the centre → congested.
    const ab = [_]export_kicad.FlatPin{ .{ .ref_des = "A", .pin = "1" }, .{ .ref_des = "B", .pin = "1" } };
    const cd = [_]export_kicad.FlatPin{ .{ .ref_des = "C", .pin = "1" }, .{ .ref_des = "D", .pin = "1" } };
    const ad = [_]export_kicad.FlatPin{ .{ .ref_des = "A", .pin = "1" }, .{ .ref_des = "B", .pin = "1" } };
    const dense_nets = [_]FlatNet{
        .{ .name = "N1", .pins = &ab },
        .{ .name = "N2", .pins = &cd },
        .{ .name = "N3", .pins = &ad },
    };
    try testing.expect(congestionPenalty(&parts, &idx_of, &dense_nets) > 0);

    // binIndex clamps out-of-range fractions into [0, bins-1].
    try testing.expectEqual(@as(usize, 0), binIndex(-1.5, CONGEST_BINS_MIN));
    try testing.expectEqual(CONGEST_BINS_MIN - 1, binIndex(999, CONGEST_BINS_MIN));
    // Bin count tracks the board extent at ~CONGEST_BIN_MM per bin, clamped.
    try testing.expectEqual(CONGEST_BINS_MIN, congestBins(1.0)); // tiny module → floor
    try testing.expectEqual(@as(usize, 20), congestBins(60.0)); // 60 mm → 3 mm bins
    try testing.expectEqual(CONGEST_BINS_MAX, congestBins(500.0)); // huge board → cap
}

// spec: placement/optimizer - relieves the loop pull of caps in a same-rail bank
test "bankLoopScale relieves only caps in a >=2-member same-rail bank" {
    const z: PadRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    // Caps 1 & 2 share rail (net 0) and the group → a bank; cap 3 is alone on net 1.
    const loops = [_]Loop{
        .{ .cap = 1, .hub = 0, .cap_pwr = z, .cap_gnd = z, .hub_pwr = &.{}, .hub_gnd = &.{}, .pwr_net = 0 },
        .{ .cap = 2, .hub = 0, .cap_pwr = z, .cap_gnd = z, .hub_pwr = &.{}, .hub_gnd = &.{}, .pwr_net = 0 },
        .{ .cap = 3, .hub = 0, .cap_pwr = z, .cap_gnd = z, .hub_pwr = &.{}, .hub_gnd = &.{}, .pwr_net = 1 },
    };
    const members = [_]usize{ 1, 2, 3 };
    const groups = [_]GroupTerm{.{ .members = &members }};
    const lowered = Lowered{ .groups = &groups, .active = true };

    const scale = try bankLoopScale(testing.allocator, &loops, lowered, 0.5);
    defer testing.allocator.free(@constCast(scale));
    try testing.expectApproxEqAbs(@as(f64, 0.5), scale[0], 1e-9); // bank cap
    try testing.expectApproxEqAbs(@as(f64, 0.5), scale[1], 1e-9); // bank cap
    try testing.expectApproxEqAbs(@as(f64, 1.0), scale[2], 1e-9); // lone cap → no relief

    // relief = 0 ⇒ every entry stays 1.0 (the feature is off).
    const off = try bankLoopScale(testing.allocator, &loops, lowered, 0);
    defer testing.allocator.free(@constCast(off));
    for (off) |s| try testing.expectApproxEqAbs(@as(f64, 1.0), s, 1e-9);
}

// spec: placement/optimizer - pulls group members toward their centroid, anchoring the IC
test "accumulateGroupCohesion pulls members in and keeps the hub anchored" {
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 3, .hh = 2, .pads = &.{}, .fallback = true, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = true, .x = -10, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = true, .x = 10, .y = 0 },
    };
    const members = [_]usize{ 0, 1, 2 };
    const groups = [_]GroupTerm{.{ .members = &members }};

    g_lowered = .{ .groups = &groups, .active = true };
    g_group_force = 0.4;
    g_zone_force = 0;
    defer {
        g_lowered = .{};
        g_group_force = 0;
    }
    var ax = [_]f64{ 0, 0, 0 };
    var ay = [_]f64{ 0, 0, 0 };
    accumulateGroupCohesion(&parts, &ax, &ay);
    // Centroid is at x=0 (the IC). The left cap is pulled right (+), the right cap
    // left (−); the IC (largest hub = anchor) gets no force.
    try testing.expect(ax[1] > 0);
    try testing.expect(ax[2] < 0);
    try testing.expectApproxEqAbs(@as(f64, 0), ax[0], 1e-9);
}

// spec: placement/optimizer - zone-pack snaps a rail direction to an IC edge
test "snapEdge picks the dominant IC edge (y-down)" {
    try testing.expectEqual(Edge.left, snapEdge(.{ .x = -2, .y = 0.3 }).?);
    try testing.expectEqual(Edge.right, snapEdge(.{ .x = 2, .y = -0.3 }).?);
    try testing.expectEqual(Edge.top, snapEdge(.{ .x = 0.1, .y = -2 }).?);
    try testing.expectEqual(Edge.bottom, snapEdge(.{ .x = 0.1, .y = 2 }).?);
    try testing.expect(snapEdge(.{ .x = 0, .y = 0 }) == null);
}

// spec: placement/optimizer - zone-pack rotates a cap so its power pad faces the IC
test "faceRotation turns the power pad toward the IC" {
    const pwr = PadRect{ .x = 1, .y = 0, .w = 0.4, .h = 0.4 }; // power pad on +x
    try testing.expectEqual(@as(f64, 0), faceRotation(pwr, .left)); // IC to the right
    try testing.expectEqual(@as(f64, 180), faceRotation(pwr, .right)); // IC to the left
    try testing.expectEqual(@as(f64, 90), faceRotation(pwr, .top)); // IC below (+y)
    try testing.expectEqual(@as(f64, 270), faceRotation(pwr, .bottom)); // IC above (−y)
}

// spec: placement/optimizer - zone-pack lays a group into an aligned row/column
test "packOneBlock lays members into an aligned column for a side edge" {
    var astate = std.heap.ArenaAllocator.init(testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var parts = [_]Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &.{}, .fallback = true },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &.{}, .fallback = true },
        .{ .ref_des = "C3", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &.{}, .fallback = true },
    };
    const ordered = [_]usize{ 0, 1, 2 };
    const blk = try packOneBlock(arena, &ordered, &parts, .left, &.{}, 0.2, false);
    // A side (left) edge packs a vertical column: same x, strictly increasing y.
    try testing.expectApproxEqAbs(@as(f64, 0), blk.lx[0], 1e-9);
    try testing.expectApproxEqAbs(blk.lx[0], blk.lx[1], 1e-9);
    try testing.expectApproxEqAbs(blk.lx[1], blk.lx[2], 1e-9);
    try testing.expect(blk.ly[0] < blk.ly[1] and blk.ly[1] < blk.ly[2]);
    // Column half-height spans all three caps + the two gaps; half-width = one cap.
    try testing.expectApproxEqAbs(@as(f64, 0.6 * 3 + 0.2), blk.half_h, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), blk.half_w, 1e-9);
}

// spec: placement/optimizer - a series part's rotation aligns its pad axis with its matched hub pins
test "seriesPairRot aligns the pad axis with the matched hub pins" {
    // TPS631000-style switch cell: hub pins LX1/LX2 stacked on Y (the IC's left
    // edge), inductor pads on X at rot 0. The pairing must pick a quarter turn
    // (pads end up stacked on Y, each facing its own pin) — exactly the case
    // where summed Manhattan HPWL is rotation-invariant and cannot decide.
    const parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
        .{ .ref_des = "L1", .kind = .passive, .hw = 1.25, .hh = 1.05, .pads = &.{}, .fallback = false },
    };
    const sp = SeriesPair{
        .part = 1,
        .hub = 0,
        .a = .{ .part_pad = .{ .x = -0.73, .y = 0, .w = 0.55, .h = 1.6 }, .hub_pad = .{ .x = -1.0, .y = 0.25, .w = 0, .h = 0 } },
        .b = .{ .part_pad = .{ .x = 0.73, .y = 0, .w = 0.55, .h = 1.6 }, .hub_pad = .{ .x = -1.0, .y = -0.25, .w = 0, .h = 0 } },
    };
    const r = seriesPairRot(&parts, sp).?;
    // Convention-independent check: the rotated pad axis must be (anti)parallel
    // to the hub-pin axis (0,−0.5) — pointing the same way, no X component left.
    const d = rotateLocal(sp.b.part_pad.x - sp.a.part_pad.x, sp.b.part_pad.y - sp.a.part_pad.y, r);
    try testing.expect(@abs(d.x) < 1e-9);
    try testing.expect(d.y < 0);
    // And it is a quarter turn, not the HPWL-tied 0/180.
    try testing.expect(r == 90 or r == 270);
}

// spec: placement/optimizer - series detection pairs a 2-pad part with two single-hub legs to one hub
test "pairSeriesLegs pairs two legs of a 2-pad part to one hub" {
    var astate = std.heap.ArenaAllocator.init(testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    const two_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.73, .y = 0, .w = 0.55, .h = 1.6 },
        .{ .number = "2", .x = 0.73, .y = 0, .w = 0.55, .h = 1.6 },
    };
    const parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
        .{ .ref_des = "L1", .kind = .passive, .hw = 1.25, .hh = 1.05, .pads = &two_pads, .fallback = false },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.3, .pads = &two_pads, .fallback = false },
    };
    const cands = [_]SeriesCand{
        // L1: two legs to the same hub (U1) → one pair.
        .{ .part = 1, .hub = 0, .part_pad = .{ .x = -0.73, .y = 0, .w = 0.55, .h = 1.6 }, .hub_pad = .{ .x = -1, .y = 0.25, .w = 0, .h = 0 } },
        .{ .part = 1, .hub = 0, .part_pad = .{ .x = 0.73, .y = 0, .w = 0.55, .h = 1.6 }, .hub_pad = .{ .x = -1, .y = -0.25, .w = 0, .h = 0 } },
        // R1: two legs but to two different hubs → not a series pair.
        .{ .part = 3, .hub = 0, .part_pad = .{ .x = -0.73, .y = 0, .w = 0.5, .h = 0.5 }, .hub_pad = .{ .x = 1, .y = 0, .w = 0, .h = 0 } },
        .{ .part = 3, .hub = 2, .part_pad = .{ .x = 0.73, .y = 0, .w = 0.5, .h = 0.5 }, .hub_pad = .{ .x = -1, .y = 0, .w = 0, .h = 0 } },
    };
    const series = try pairSeriesLegs(arena, &cands, &parts);
    try testing.expectEqual(@as(usize, 1), series.len);
    try testing.expectEqual(@as(usize, 1), series[0].part);
    try testing.expectEqual(@as(usize, 0), series[0].hub);
}

// spec: placement/optimizer - series rotations are applied and pinned; authored spec rotations win
test "applySeriesRotations pins the pairing but never an authored rot" {
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
        .{ .ref_des = "L1", .kind = .passive, .hw = 1.25, .hh = 1.05, .pads = &.{}, .fallback = false },
    };
    const sp = SeriesPair{
        .part = 1,
        .hub = 0,
        .a = .{ .part_pad = .{ .x = -0.73, .y = 0, .w = 0.55, .h = 1.6 }, .hub_pad = .{ .x = -1.0, .y = 0.25, .w = 0, .h = 0 } },
        .b = .{ .part_pad = .{ .x = 0.73, .y = 0, .w = 0.55, .h = 1.6 }, .hub_pad = .{ .x = -1.0, .y = -0.25, .w = 0, .h = 0 } },
    };
    applySeriesRotations(&parts, &.{sp});
    try testing.expectEqual(RotPin.series, parts[1].rot_pin);
    const paired = parts[1].rot;
    try testing.expect(paired == 90 or paired == 270);
    // An authored rotation is never overridden by the pairing.
    parts[1].rot = 180;
    parts[1].rot_pin = .authored;
    applySeriesRotations(&parts, &.{sp});
    try testing.expectEqual(@as(f64, 180), parts[1].rot);
    try testing.expectEqual(RotPin.authored, parts[1].rot_pin);
}

// spec: placement/optimizer - auto-fill pulls staged (unplaced) parts out of the band beside their net
test "autofillUnlisted places a staged part beside its net" {
    var astate = std.heap.ArenaAllocator.init(testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var hub_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -2.5, .y = 0, .w = 0.8, .h = 0.8 },
        .{ .number = "2", .x = 2.5, .y = 0, .w = 0.8, .h = 0.8 },
    };
    var cap_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
    };
    // U1 at origin, C1 placed beside it; C9 is staged in the band below the board
    // (what a partial solve would leave behind — autofill pulls it out by hand here).
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 3, .hh = 3, .pads = &hub_pads, .fallback = true },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &cap_pads, .fallback = true, .x = -5, .y = 0 },
        .{ .ref_des = "C9", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &cap_pads, .fallback = true, .y = 10 }, // staged below
    };
    var idx_of = std.StringHashMap(usize).init(arena);
    try idx_of.put("U1", 0);
    try idx_of.put("C1", 1);
    try idx_of.put("C9", 2);
    const vin_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C9", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "VIN", .pins = &vin_pins }};
    var springs = [_]Spring{};
    var loops = [_]Loop{};
    const built = Built{ .springs = &springs, .loops = &loops };
    // Stage C9 as the autofill input: it's the one part in the unplaced band.
    g_placement_diag = .{ .unplaced = &.{"C9"} };
    defer g_placement_diag = .{};
    // Staged below the board before the fill…
    try testing.expect(parts[2].y > parts[0].y + parts[0].hh);
    try autofillUnlisted(arena, &parts, &idx_of, &nets, built.loops);
    // …auto-filled beside its net afterwards: off the band, reported as filled.
    try testing.expectEqual(@as(usize, 1), g_placement_diag.auto_filled.len);
    try testing.expectEqualStrings("C9", g_placement_diag.auto_filled[0]);
    try testing.expectEqual(@as(usize, 0), g_placement_diag.unplaced.len);
    try testing.expect(parts[2].y < parts[0].y + parts[0].hh + STAGE_GAP_MM);
    try testing.expect(!anyOverlap(&parts));
}

// spec: placement/optimizer - (board ...) edge default rotation turns connector pads toward the board interior
test "edgeInwardRot points pads inward per edge" {
    var pads = [_]geometry.Pad{.{ .number = "1", .x = 1.0, .y = 0, .w = 0.5, .h = 0.5 }};
    const p = Part{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 1, .pads = &pads, .fallback = true };
    try testing.expectApproxEqAbs(@as(f64, 0), edgeInwardRot(p, .left), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 180), edgeInwardRot(p, .right), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 90), edgeInwardRot(p, .top), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 270), edgeInwardRot(p, .bottom), 1e-9);
}

// spec: placement/optimizer - (board ...) docks edge parts flush inside the outline and pins corners
test "packBoard docks edges and corners on the outline" {
    var astate = std.heap.ArenaAllocator.init(testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var j_pads = [_]geometry.Pad{.{ .number = "1", .x = 1.0, .y = 0, .w = 0.8, .h = 0.8 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 3, .hh = 3, .pads = &.{}, .fallback = true },
        .{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 1.5, .pads = &j_pads, .fallback = true },
        .{ .ref_des = "MK1", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = true },
    };
    var idx_of = std.StringHashMap(usize).init(arena);
    try idx_of.put("U1", 0);
    try idx_of.put("J1", 1);
    try idx_of.put("MK1", 2);
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
        .{ .ref_des = "J1", .component = "", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
        .{ .ref_des = "MK1", .component = "", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
    };
    const net_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "J1", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &net_pins }};
    const left_items = [_]env.PlacementItem{.{ .ref = "J1" }};
    const sides = [_]env.PlacementSideSpec{.{ .side = .left, .items = &left_items }};
    const corners = [_]env.PlacementItem{ .{ .ref = "MK1" }, .{ .ref = "NOPE" } };
    const spec = env.BoardSpec{ .w = 20, .h = 20, .sides = &sides, .corners = &corners, .present = true };
    g_placement_diag = .{};
    defer g_placement_diag = .{};
    const rect = try packBoard(arena, &parts, &instances, &idx_of, &nets, spec);
    // The outline shifts left of the interior centre (U1 at the origin) so the
    // interior centres in the region the left edge's dock lane (2*hw(J1) +
    // gap = 5mm) leaves free: minx = -10 - 5/2, grid-rounded (lands exactly
    // on the 0.1 mm grid).
    try testing.expectApproxEqAbs(@as(f64, -12.5), rect.minx, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -10), rect.miny, 1e-9);
    // J1 flush inside the left edge (keepout hw 2 -> centre at minx+2), pads
    // inward (rot 0), slid opposite its attachment (U1 at y 0).
    try testing.expectApproxEqAbs(rect.minx + 2, parts[1].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), parts[1].y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), parts[1].rot, 1e-9);
    // MK1 pinned at the top-left corner, inset by its keepout extents.
    try testing.expectApproxEqAbs(rect.minx + 1, parts[2].x, 1e-9);
    try testing.expectApproxEqAbs(rect.miny + 1, parts[2].y, 1e-9);
    // The corner name that resolves to nothing is reported, not dropped.
    try testing.expectEqual(@as(usize, 1), g_placement_diag.unresolved.len);
    try testing.expectEqualStrings("NOPE", g_placement_diag.unresolved[0]);
}

// spec: placement/optimizer - (board ...) edge parts wanting the same spot de-overlap along the edge
test "packBoard de-overlaps edge parts along their edge" {
    var astate = std.heap.ArenaAllocator.init(testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 3, .hh = 3, .pads = &.{}, .fallback = true },
        .{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 1.5, .pads = &.{}, .fallback = true },
        .{ .ref_des = "J2", .kind = .hub, .hw = 2, .hh = 1.5, .pads = &.{}, .fallback = true },
    };
    var idx_of = std.StringHashMap(usize).init(arena);
    try idx_of.put("U1", 0);
    try idx_of.put("J1", 1);
    try idx_of.put("J2", 2);
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
        .{ .ref_des = "J1", .component = "", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
        .{ .ref_des = "J2", .component = "", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
    };
    // Both connectors attach to U1 (y 0) -> both want the same slide position.
    const p1 = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "J1", .pin = "1" } };
    const p2 = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "J2", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "A", .pins = &p1 }, .{ .name = "B", .pins = &p2 } };
    const left_items = [_]env.PlacementItem{ .{ .ref = "J1" }, .{ .ref = "J2" } };
    const sides = [_]env.PlacementSideSpec{.{ .side = .left, .items = &left_items }};
    const spec = env.BoardSpec{ .w = 20, .h = 20, .sides = &sides, .present = true };
    g_placement_diag = .{};
    defer g_placement_diag = .{};
    _ = try packBoard(arena, &parts, &instances, &idx_of, &nets, spec);
    // Same edge (same x), separated along it by at least their extents + gap.
    try testing.expectApproxEqAbs(parts[1].x, parts[2].x, 1e-9);
    try testing.expect(@abs(parts[1].y - parts[2].y) >= 1.5 + 1.5 + BOARD_EDGE_GAP_MM - 1e-9);
    try testing.expect(!anyOverlap(&parts));
}

// spec: placement/optimizer - finishMacro turns the whole macro in quarter steps about its centroid
test "finishMacro rotates members rigidly about the centroid" {
    const pads = [_]geometry.Pad{};
    const parts = [_]Part{
        .{ .ref_des = "A", .kind = .passive, .hw = 1, .hh = 0.5, .pads = &pads, .fallback = false },
        .{ .ref_des = "B", .kind = .passive, .hw = 1, .hh = 0.5, .pads = &pads, .fallback = false },
    };
    var members = [_]usize{ 0, 1 };
    var xs = [_]f64{ 0, 4 };
    var ys = [_]f64{ 0, 0 };
    var rots = [_]f64{ 0, 0 };
    const m = finishMacro(&members, &xs, &ys, &rots, &parts, 90);
    // The pair was horizontal; after a quarter turn it's vertical and each
    // member's extents swapped (rot 90), so the bbox is 1 wide per member.
    try testing.expectApproxEqAbs(@as(f64, 90), m.rots[0], 1e-9);
    try testing.expectApproxEqAbs(m.lx[0], m.lx[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4), @abs(m.ly[1] - m.ly[0]), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), m.bmaxx - m.bminx, 1e-9);
}

// spec: placement/optimizer - composed module macros push free parts away and stay rigid
test "legalizeComposed moves the free part, not the macro members" {
    const pads = [_]geometry.Pad{};
    var parts = [_]Part{
        // Two-member rigid macro at x = 0 and 4.
        .{ .ref_des = "m/U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "m/C1", .kind = .passive, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 4, .y = 0 },
        // Free part overlapping the second member.
        .{ .ref_des = "R1", .kind = .passive, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 6, .y = 0.5 },
    };
    const macro_of = [_]?usize{ 0, 0, null };
    legalizeComposed(&parts, &macro_of);
    // Macro members never moved relative to each other (or at all).
    try testing.expectApproxEqAbs(@as(f64, 0), parts[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4), parts[1].x, 1e-9);
    // The free part was pushed clear of both members.
    try testing.expect(!overlapsAny(&parts, &parts[2]));
}

// spec: placement/optimizer - composed macros overlapping each other move the later one as a unit
test "legalizeComposed shifts the later macro rigidly" {
    const pads = [_]geometry.Pad{};
    var parts = [_]Part{
        .{ .ref_des = "a/U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "b/U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 3, .y = 0.5 },
        .{ .ref_des = "b/C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 7, .y = 0.5 },
    };
    const macro_of = [_]?usize{ 0, 1, 1 };
    legalizeComposed(&parts, &macro_of);
    // Macro b moved as a unit: the b members' relative offset is preserved.
    try testing.expectApproxEqAbs(@as(f64, 4), parts[2].x - parts[1].x, 1e-9);
    try testing.expectApproxEqAbs(parts[2].y, parts[1].y, 1e-9);
    // And the overlap with macro a is gone.
    try testing.expect(!anyOverlap(&parts));
}

// spec: placement/optimizer - synthesizes an aggressor-avoidance keep-out for a feedback passive
test "synthAggressorKeepouts pairs a feedback passive with the switching inductor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false },
        .{ .ref_des = "L1", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false },
    };
    const sw = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "L1", .pin = "1" } };
    const fb = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "R1", .pin = "1" } };
    const nets = [_]FlatNet{
        .{ .name = "SW", .pins = &sw },
        .{ .name = "FB", .pins = &fb },
    };
    var idx_of = std.StringHashMap(usize).init(arena);
    for (parts, 0..) |p, i| try idx_of.put(p.ref_des, i);
    var keepouts: std.ArrayListUnmanaged(KeepTerm) = .empty;
    try synthAggressorKeepouts(arena, &parts, &nets, &idx_of, &keepouts);
    // Exactly one pair: R1 (on feedback net FB) kept clear of L1 (on the
    // switching node SW). The hub U1, on both nets, is excluded both ways.
    try testing.expectEqual(@as(usize, 1), keepouts.items.len);
    try testing.expectEqual(@as(usize, 2), keepouts.items[0].a); // R1 (victim)
    try testing.expectEqual(@as(usize, 1), keepouts.items[0].b); // L1 (aggressor)
}

// spec: placement/optimizer - rough seed keeps each module a rigid, non-interleaved block
test "arrangeMacros + legalize keep modules intact and disjoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pads = [_]geometry.Pad{};
    // Module a = {0,1}, module b = {2,3}, started INTERLEAVED along x (a at 0/12,
    // b at 6/18) so a flat solve would mix them — the rough seed must pull each
    // module into its own rigid, disjoint block.
    var parts = [_]Part{
        .{ .ref_des = "a/U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "a/C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 12, .y = 0 },
        .{ .ref_des = "b/U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 6, .y = 0 },
        .{ .ref_des = "b/C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 18, .y = 0 },
    };
    const am = [_]usize{ 0, 1 };
    const bm = [_]usize{ 2, 3 };
    // finishMacro grid-snaps each module's members to module-local offsets and
    // records the block bbox (rot_override null = keep authored rotations).
    const az = [_]f64{ 0, 0 };
    const macros = [_]Macro{
        finishMacro(
            try arena.dupe(usize, &am),
            try arena.dupe(f64, &[_]f64{ 0, 12 }),
            try arena.dupe(f64, &az),
            try arena.dupe(f64, &az),
            &parts,
            null,
        ),
        finishMacro(
            try arena.dupe(usize, &bm),
            try arena.dupe(f64, &[_]f64{ 6, 18 }),
            try arena.dupe(f64, &az),
            try arena.dupe(f64, &az),
            &parts,
            null,
        ),
    };
    const macro_of = [_]?usize{ 0, 0, 1, 1 };
    // One net joins the two modules, so the arranger has connectivity to act on.
    const link = [_]export_kicad.FlatPin{ .{ .ref_des = "a/C1", .pin = "1" }, .{ .ref_des = "b/U1", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "L", .pins = &link }};
    var idx_of = std.StringHashMap(usize).init(arena);
    try idx_of.put("a/U1", 0);
    try idx_of.put("a/C1", 1);
    try idx_of.put("b/U1", 2);
    try idx_of.put("b/C1", 3);

    const origins = try arrangeMacros(arena, &macros, &macro_of, &nets, &idx_of);
    stampMacros(&parts, &macros, origins);
    legalizeComposed(&parts, &macro_of);

    // Rigidity: each module's internal member offset survived the arrange + legalize
    // (a module moves only as a whole block). finishMacro snapped both to dx = 12.
    try testing.expectApproxEqAbs(@as(f64, 12), parts[1].x - parts[0].x, 1e-9);
    try testing.expectApproxEqAbs(parts[1].y, parts[0].y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 12), parts[3].x - parts[2].x, 1e-9);
    try testing.expectApproxEqAbs(parts[3].y, parts[2].y, 1e-9);
    // No part overlaps anywhere.
    try testing.expect(!anyOverlap(&parts));
    // The two modules occupy disjoint bounding boxes — they did not interleave.
    const ba = membersBox(&parts, &am);
    const bb = membersBox(&parts, &bm);
    const disjoint = ba[2] <= bb[0] or bb[2] <= ba[0] or ba[3] <= bb[1] or bb[3] <= ba[1];
    try testing.expect(disjoint);
}

// spec: placement/optimizer - (rough …) anchor/group tokens match by ref-des or origin name
test "roughNameMatch matches by ref-des or origin, exact or leaf" {
    try testing.expect(roughNameMatch("U1", "", "U1")); // exact ref
    try testing.expect(roughNameMatch("clk/U1", "", "U1")); // leaf of a prefixed ref
    try testing.expect(roughNameMatch("U17", "U1", "U1")); // origin survives renumber
    try testing.expect(roughNameMatch("a/C5", "C_VDD", "C_VDD")); // origin name
    try testing.expect(!roughNameMatch("U2", "", "U1")); // no match
    try testing.expect(!roughNameMatch("U1", "", "")); // empty token never matches
}

// spec: placement/optimizer - (rough …) priority is the fill order; lower tiers spill to outer lanes
test "dockSidesByTier fills inner lane by priority, spilling lower tiers outward" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pads = [_]geometry.Pad{};
    var parts = [_]Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false },
    };
    // Both docked on the LEFT (s=0) at the same edge coordinate; C1 is tier 0
    // (highest priority), C2 tier 1. The anchor is tiny so a lane holds only one
    // part — C1 claims the inner lane and C2 spills to the outer lane.
    var sides = [_]std.ArrayListUnmanaged(SidePart){ .empty, .empty, .empty, .empty };
    try sides[0].append(arena, .{ .i = 0, .tier = 0, .along = 0, .half_along = 0.5, .depth = 0.5 });
    try sides[0].append(arena, .{ .i = 1, .tier = 1, .along = 0, .half_along = 0.5, .depth = 0.5 });
    const hkb = KeepBox{ .cxo = 0, .cyo = 0, .hw = 0.3, .hh = 0.3 };
    dockSidesByTier(&parts, &sides, hkb);
    // Left side x is negative; the inner (tier-0) part sits closer to the IC, so
    // its x is greater (less negative) than the spilled tier-1 part's.
    try testing.expect(parts[0].x > parts[1].x);
    try testing.expect(parts[0].x < 0 and parts[1].x < 0);
}

// spec: placement/optimizer - segsCross flags interior airwire crossings, not shared endpoints
test "segsCross flags interior crossings and ignores shared endpoints" {
    // Diagonals of a unit square cross in the middle.
    try testing.expect(segsCross(.{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 1, 0 }));
    // Parallel segments never cross.
    try testing.expect(!segsCross(.{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 }));
    // Two airwires meeting at the same pad share an endpoint — not a crossing.
    try testing.expect(!segsCross(.{ 0, 0 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, -1 }));
    // Disjoint and far apart.
    try testing.expect(!segsCross(.{ 0, 0 }, .{ 1, 0 }, .{ 5, 5 }, .{ 6, 6 }));
}

// spec: placement/optimizer - refineSidesByPull moves a part to the IC side its real connections pull toward
test "refineSidesByPull re-sides a part toward its signal pad" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Hub U1 (index 0) with its only SIG pad on the RIGHT (x=+5); passive R1 hangs
    // off it. R1 is mis-seeded on the LEFT — refinement should pull it right.
    const hub_pads = [_]geometry.Pad{.{ .number = "1", .x = 5, .y = 0, .w = 1, .h = 1 }};
    const r_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &r_pads, .fallback = false },
    };
    const nets = [_]FlatNet{
        .{ .name = "SIG", .pins = &.{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } } },
    };
    var idx_of = std.StringHashMap(usize).init(arena);
    try idx_of.put("U1", 0);
    try idx_of.put("R1", 1);
    const tier_of = [_]usize{ 0, 0 };
    const cohere_side = [_]u8{ 255, 255 }; // neither part is group-cohered

    var sides = [_]std.ArrayListUnmanaged(SidePart){ .empty, .empty, .empty, .empty };
    try sides[0].append(arena, .{ .i = 1, .tier = 0, .along = 0, .half_along = 0.5, .depth = 0.5 });
    parts[1].x = -10; // its mis-seeded (left) position
    parts[1].y = 0;
    const hkb = KeepBox{ .cxo = 0, .cyo = 0, .hw = 2, .hh = 2 };

    try refineSidesByPull(arena, &parts, 0, &nets, &idx_of, &tier_of, &cohere_side, &sides, hkb);

    // Moved from the LEFT bucket (s=0) to the RIGHT (s=1), now at positive x.
    try testing.expectEqual(@as(usize, 0), sides[0].items.len);
    try testing.expectEqual(@as(usize, 1), sides[1].items.len);
    try testing.expect(parts[1].x > 0);
}

// spec: placement/optimizer - cohereGroups pins a subsystem with an anchored member to one side, leaves an anchorless bypass group spread
test "cohereGroups coheres an anchored group and leaves a pure-bypass group distributed" {
    var astate = std.heap.ArenaAllocator.init(testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();

    // PWR = L1 (anchored: sig_side top) + C1,C2 (bypass, no anchor) → cohere all
    // to top. BYP = C3,C4 (bypass only, no anchor) → must stay where they were.
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false },
        .{ .ref_des = "L1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false },
        .{ .ref_des = "C3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false },
        .{ .ref_des = "C4", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false },
    };
    const pwr_m = [_][]const u8{ "L1", "C1", "C2" };
    const byp_m = [_][]const u8{ "C3", "C4" };
    const groups = [_]env.Group{ .{ .name = "PWR", .members = &pwr_m }, .{ .name = "BYP", .members = &byp_m } };
    // Only L1 has a directional anchor (top = side 2); all caps are anchorless.
    const sig_side = [_]u8{ 255, 2, 255, 255, 255, 255 };
    const tier_of = [_]usize{ 0, 0, 0, 0, 0, 0 };
    const cohere_side = try arena.alloc(u8, parts.len);
    @memset(cohere_side, 255);

    // Seed each ringed part on a NON-top side so cohesion visibly moves the PWR
    // group: L1,C3→left(0); C1,C4→right(1); C2→bottom(3).
    var sides = [_]std.ArrayListUnmanaged(SidePart){ .empty, .empty, .empty, .empty };
    try sides[0].append(arena, .{ .i = 1, .tier = 0, .along = 0, .half_along = 0.5, .depth = 0.5 });
    try sides[1].append(arena, .{ .i = 2, .tier = 0, .along = 0, .half_along = 0.5, .depth = 0.5 });
    try sides[3].append(arena, .{ .i = 3, .tier = 0, .along = 0, .half_along = 0.5, .depth = 0.5 });
    try sides[0].append(arena, .{ .i = 4, .tier = 0, .along = 0, .half_along = 0.5, .depth = 0.5 });
    try sides[1].append(arena, .{ .i = 5, .tier = 0, .along = 0, .half_along = 0.5, .depth = 0.5 });

    try cohereGroups(arena, &parts, 0, &groups, &.{}, &tier_of, &sig_side, cohere_side, &sides);

    // PWR (L1,C1,C2) all cohered to top (side 2); BYP (C3,C4) untouched.
    try testing.expectEqual(@as(u8, 2), cohere_side[1]);
    try testing.expectEqual(@as(u8, 2), cohere_side[2]);
    try testing.expectEqual(@as(u8, 2), cohere_side[3]);
    try testing.expectEqual(@as(u8, 255), cohere_side[4]);
    try testing.expectEqual(@as(u8, 255), cohere_side[5]);
    try testing.expectEqual(@as(usize, 3), sides[2].items.len); // all PWR on top
    // BYP members stayed on their seeded sides (C3 left, C4 right).
    try testing.expectEqual(@as(usize, 1), sides[0].items.len);
    try testing.expectEqual(@as(usize, 1), sides[1].items.len);
}

// spec: placement/optimizer - servedPadLocal resolves a decoupling cap's bound hub pad on-net and rejects a cross-hub binding
test "servedPadLocal resolves a bound pad on-net and rejects cross-hub bindings" {
    var astate = std.heap.ArenaAllocator.init(testing.allocator);
    defer astate.deinit();
    const arena = astate.allocator();
    // U1 (idx 0) has pads 10@(3,0); U2 (idx 1) has an unrelated pad 8@(0,5).
    const u1_pads = [_]geometry.Pad{.{ .number = "10", .x = 3, .y = 0, .w = 0.3, .h = 0.3 }};
    const u2_pads = [_]geometry.Pad{.{ .number = "8", .x = 0, .y = 5, .w = 0.3, .h = 0.3 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 4, .hh = 4, .pads = &u1_pads, .fallback = false },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &u2_pads, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &.{}, .fallback = false },
    };
    // C1 sits on DVDD with U1 pad 10; it does NOT touch U2's pad 8.
    const nets = [_]FlatNet{
        .{ .name = "DVDD", .pins = &.{ .{ .ref_des = "U1", .pin = "10" }, .{ .ref_des = "C1", .pin = "1" } } },
    };
    var idx_of = std.StringHashMap(usize).init(arena);
    try idx_of.put("U1", 0);
    try idx_of.put("U2", 1);
    try idx_of.put("C1", 2);
    // Bound to U1 pad 10 on its own net → resolves to that pad's centre (3,0).
    const got = servedPadLocal(&parts, 0, 2, "10", &nets, &idx_of);
    try testing.expect(got != null);
    try testing.expectApproxEqAbs(@as(f64, 3), got.?[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), got.?[1], 1e-9);
    // A cross-hub token (U2's pad 8, off C1's net at U1) → null, never mis-docked.
    try testing.expect(servedPadLocal(&parts, 0, 2, "8", &nets, &idx_of) == null);
    // Empty token → null.
    try testing.expect(servedPadLocal(&parts, 0, 2, "", &nets, &idx_of) == null);
}

// spec: placement/optimizer - decouplePinFromOrigin reads the decoupled pad from a per-pin cap's structural key
test "decouplePinFromOrigin extracts the pad from value@pad#replica keys" {
    try testing.expectEqualStrings("3", decouplePinFromOrigin("100nF@3#0").?);
    try testing.expectEqualStrings("B4", decouplePinFromOrigin("10uF@B4#2").?); // BGA pad name
    try testing.expect(decouplePinFromOrigin("100nF#0") == null); // non-per-pin decouple
    try testing.expect(decouplePinFromOrigin("C_AVDD1") == null); // named part
    try testing.expect(decouplePinFromOrigin("10uF@#0") == null); // empty pad
}

// spec: placement/optimizer - orientPadsToIC flips a 2-pad part so its important pad faces the IC
test "orientPadsToIC turns the important pad toward the anchor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Cap C1 on the LEFT of the IC; pad "1" (power, net VDD→hub) at local +x,
    // pad "2" (GND) at local −x. Seeded rot 180 → the power pad points OUTWARD.
    const hub_pads = [_]geometry.Pad{.{ .number = "1", .x = -3, .y = 0, .w = 1, .h = 1 }};
    const c_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 1, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "2", .x = -1, .y = 0, .w = 0.4, .h = 0.4 },
    };
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.5, .pads = &c_pads, .fallback = false, .x = -10, .y = 0, .rot = 180 },
    };
    const nets = [_]FlatNet{
        .{ .name = "VDD", .pins = &.{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } } },
        .{ .name = "GND", .pins = &.{.{ .ref_des = "C1", .pin = "2" }} },
    };
    var idx_of = std.StringHashMap(usize).init(arena);
    try idx_of.put("U1", 0);
    try idx_of.put("C1", 1);
    orientPadsToIC(&parts, 0, &nets, &idx_of);
    // Flipped 180 → 0 so pad "1" (power, not GND) sits at world +x, toward the IC.
    try testing.expectEqual(@as(f64, 0), parts[1].rot);
    // A part already oriented right is left untouched.
    orientPadsToIC(&parts, 0, &nets, &idx_of);
    try testing.expectEqual(@as(f64, 0), parts[1].rot);
}

// spec: placement/optimizer - posSide buckets a point into the anchor quadrant it lies in
test "posSide picks the anchor side a point lies on" {
    try testing.expectEqual(@as(u8, 1), posSide(0, 0, 5, 1)); // right
    try testing.expectEqual(@as(u8, 0), posSide(0, 0, -5, 1)); // left
    try testing.expectEqual(@as(u8, 3), posSide(0, 0, 1, 5)); // bottom (+y)
    try testing.expectEqual(@as(u8, 2), posSide(0, 0, 1, -5)); // top (−y)
    try testing.expectEqual(@as(u8, 1), posSide(2, 0, 9, 2)); // relative to a non-origin anchor
}

// spec: placement/optimizer - the crossing polish never swaps a part onto its wrong anchor side
test "polishCrossings honours want_side, refusing a wrong-side swap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // X-crossing: net N1 wires R1(right) to R3(far left), N2 wires R2(left) to
    // R4(far right) — the two airwires cross at the origin. Swapping the same-size
    // R1↔R2 uncrosses them, but that parks R1 on the LEFT (its wrong side).
    const sp = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const mk = struct {
        fn p(ref: []const u8, x: f64, y: f64, h: f64, pads: []const geometry.Pad) Part {
            return .{ .ref_des = ref, .kind = .passive, .hw = h, .hh = h, .pads = pads, .fallback = false, .x = x, .y = y };
        }
    }.p;
    const init = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        mk("R1", 6, 3, 0.5, &sp), // right, swappable size
        mk("R2", -6, 3, 0.5, &sp), // left, swappable size
        mk("R3", -6, -3, 0.7, &sp), // target, different size (can't swap with R1/R2)
        mk("R4", 6, -3, 0.7, &sp),
    };
    const nets = [_]FlatNet{
        .{ .name = "N1", .pins = &.{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R3", .pin = "1" } } },
        .{ .name = "N2", .pins = &.{ .{ .ref_des = "R2", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } } },
    };
    var idx_of = std.StringHashMap(usize).init(arena);
    inline for (.{ "U1", "R1", "R2", "R3", "R4" }, 0..) |r, i| try idx_of.put(r, i);

    // Unconstrained polish (all 255) DOES swap R1↔R2 to kill the crossing.
    var free = init;
    const open = [_]u8{255} ** 5;
    try polishCrossings(arena, &free, 0, &nets, &idx_of, &open);
    try testing.expect(free[1].x < 0); // R1 moved to the left

    // Side-constrained polish refuses the swap — R1 stays on its right side.
    var pinned = init;
    const want = [_]u8{ 255, 1, 0, 255, 255 }; // R1→right, R2→left
    try polishCrossings(arena, &pinned, 0, &nets, &idx_of, &want);
    try testing.expect(pinned[1].x > 0); // R1 held on the right
    try testing.expect(pinned[2].x < 0); // R2 held on the left
}

// spec: placement/optimizer - the surrogate objective ranks a tighter layout below a spread one
test "surrogateObjective ranks a tighter layout below a spread one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The surrogate objective's ordering property: a cap hugging the hub must score
    // below the same cap flung far away (shorter airwire → lower objective).
    const hub_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1 }};
    const c_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &c_pads, .fallback = false, .x = 2, .y = 0 },
    };
    const nets = [_]FlatNet{
        .{ .name = "N", .pins = &.{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } } },
    };
    var idx_of = std.StringHashMap(usize).init(arena);
    try idx_of.put("U1", 0);
    try idx_of.put("C1", 1);
    const params = Params{ .w_align = 0 }; // kill alignment; objective ≈ wirelength
    const no_loops = [_]Loop{};
    const tight = surrogateObjective(&parts, &idx_of, &nets, &no_loops, params);
    parts[1].x = 40; // fling the cap far from the hub
    const spread = surrogateObjective(&parts, &idx_of, &nets, &no_loops, params);
    try testing.expect(tight < spread);
}

// spec: placement/optimizer - a bottom-side part mirrors footprint-local x in world transforms and never collides with top-side parts
test "bottom side mirrors worldPt and skips cross-side overlap" {
    var p = Part{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 10, .y = 5 };
    p.side = .bottom;
    // rot 0: local (+1, +0.5) mirrors to (−1, +0.5).
    const w = worldPt(p, 1.0, 0.5);
    try testing.expectEqual(@as(f64, 9.0), w.x);
    try testing.expectEqual(@as(f64, 5.5), w.y);
    // rot 90: mirrored local (−1, 0.5) rotates to (−0.5, −1).
    p.rot = 90;
    const w2 = worldPt(p, 1.0, 0.5);
    try testing.expectEqual(@as(f64, 9.5), w2.x);
    try testing.expectEqual(@as(f64, 4.0), w2.y);
    // Two parts stacked at the same spot: opposite sides never collide,
    // same side does.
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 0, .y = 0, .side = .bottom },
        .{ .ref_des = "U2", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
    };
    try testing.expect(!anyOverlap(&parts));
    parts[1].side = .bottom;
    try testing.expect(anyOverlap(&parts));
}

// spec: placement/optimizer - cached poses restore each part's board side and lock flag
test "applyCached applies side and locked" {
    var parts = [_]Part{.{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false }};
    const poses = [_]RefPose{.{ .ref = "C1", .x = 4, .y = 6, .rot = 180, .side = .bottom, .locked = true }};
    _ = applyCached(&parts, &poses);
    try testing.expectEqual(Side.bottom, parts[0].side);
    try testing.expect(parts[0].locked);
    try testing.expectEqual(@as(f64, 4), parts[0].x);
    try testing.expectEqual(@as(f64, 180), parts[0].rot);
}

// spec: placement/optimizer - anchor pick prefers net degree over courtyard area, area only breaks ties
test "pickAnchorHub picks the wired MCU over a big-courtyard button" {
    // U1 = small MCU on three nets; U4 = reset button with a 4x bigger
    // courtyard on one net (the w55rp20 mis-anchor shape).
    const parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false },
        .{ .ref_des = "U4", .kind = .hub, .hw = 4, .hh = 4, .pads = &.{}, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false },
    };
    const nets = [_]FlatNet{
        .{ .name = "VDD", .pins = &.{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } } },
        .{ .name = "GND", .pins = &.{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C1", .pin = "2" }, .{ .ref_des = "U4", .pin = "2" } } },
        .{ .name = "RUN", .pins = &.{ .{ .ref_des = "U1", .pin = "3" }, .{ .ref_des = "U4", .pin = "1" } } },
    };
    try testing.expectEqual(@as(?usize, 0), pickAnchorHub(&parts, &nets));
    // Degree tie (no nets at all) falls back to courtyard area: U4 wins.
    try testing.expectEqual(@as(?usize, 1), pickAnchorHub(&parts, &.{}));
    // No hub anywhere: null.
    try testing.expectEqual(@as(?usize, null), pickAnchorHub(parts[2..], &nets));
}
