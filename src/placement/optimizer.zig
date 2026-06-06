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
const router = @import("router.zig");
const parser = @import("../sexpr/parser.zig");
const infra_fs = @import("../infra/fs.zig");

const DesignBlock = env.DesignBlock;
const FlatNet = export_kicad.FlatNet;

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
const ROT_ROUNDS: usize = 2; // rotation-refine ↔ relax coordinate-descent rounds
const LOOP_W: f64 = 6.0; // weight on the loop *inductance* term (nH; see
// `loopInductanceNh`). On a solid GND plane the loop is dominated by the power-leg
// (L1) trace — the return images directly under it (`loopGroundSpan` carries no
// lateral term) — so minimising the connection inductance minimises both the EMI
// loop area and the PDN bandwidth limit. The loop nH ≈ 0.5·(loop length mm) + a
// via floor, so 6.0 keeps this term's magnitude near the old length-based 3.0;
// PROVISIONAL — the research flags that PCB weights need empirical re-tuning.
const K_COMPACT: f64 = 0.10; // pull toward the cluster centroid (keeps HPWL tight)
const GROUP_FORCE_PER_W: f64 = 0.05; // relaxation cohesion-force gain per unit `group_w`
// (g_group_force = group_w·this); default group_w=2 ⇒ 0.10, ≈ K_COMPACT.
const ZONE_FORCE_PER_W: f64 = 0.04; // relaxation zoning-force gain per unit `group_zone_w`
const STARTS: usize = 48; // multi-start seeds; keep the lowest-scoring arrangement
const MULTISTART_MAX_PARTS: usize = 32; // above this, single start (bound O(n²·starts))
// The once-per-solve quality passes — rotation refine, the greedy `polish` local
// search, and the priority-cap tuck — are cheap (linear-ish, fixed-pad surrogate,
// run once on the winning arrangement, *not* per multi-start seed). They can cover
// boards well above MULTISTART_MAX_PARTS. Without this, a 33–64-part block (e.g. an
// MCU sub-block with ~30 decoupling caps) fell off the multi-start cliff to a bare
// grid-seed + one relax — i.e. looked unplaced. Keep the expensive multi-start
// gated at MULTISTART_MAX_PARTS; let the finishing passes run up to here.
const POLISH_MAX_PARTS: usize = 64;
const POLISH_SWEEPS: usize = 4; // greedy per-part tightening sweeps
const POLISH_CELLS: i64 = 6; // half-window (grid cells) the polish search scans
// Tighter polish window for the single-start band above MULTISTART_MAX_PARTS:
// each cell is a full-board objective eval, so the (2c+1)² cost dominates a
// large-board regen. ±3 cells (≈±0.6 mm) is a local tuck on an already-relaxed
// part — ~3.4× fewer evals than ±6 with nearly all the quality.
const POLISH_CELLS_LARGE: i64 = 3;
// Routed-aware finishing polish (small boards only): a final local search that
// scores each candidate (position × rotation) with the *real* maze-routed loop
// length instead of the fixed-pad surrogate, so a cap settles at the rotation/
// offset that shortens the actual trace — the surrogate-driven `polish` optimises
// a straight-gap proxy and can pick a different rotation/side than the router.
const ROUTED_POLISH_SWEEPS: usize = 2;
const ROUTED_POLISH_CELLS: i64 = 3; // ±0.6 mm window — local tuck/flip, not a re-place
// Routed polish routes once per candidate cell, so its cost grows with
// caps × window × loops. Keep it small so a mid-size module can't make an
// on-demand regenerate take tens of seconds. Small power modules — the case this
// helps most — sit comfortably under it.
const ROUTED_POLISH_MAX_PARTS: usize = 16;
// Top-K rerank (small boards, `rerankSolve`): the multi-start ranks arrangements
// by the fixed-pad surrogate, but the surrogate-best global arrangement isn't
// always the routed-best — and `routedPolish`'s small window can only tuck a cap,
// not move it to a different side of the IC. So keep the K lowest-surrogate
// candidates, finish each fully, and pick the one with the lowest *routed*
// objective. K is scaled down with part count to bound the per-candidate finish
// cost (each runs polish + compaction); `RERANK_BUDGET/parts` ≈ a fixed work cap.
const RERANK_K: usize = 12;
const RERANK_BUDGET: usize = 120;
// The rerank path can afford a much larger seed pool than the default `STARTS`:
// it only runs on ≤16-part boards (relax is cheap there) and — because the
// candidates are reranked on the *routed* metric — a wider, more diverse pool can
// only surface a better arrangement, never a worse one (unlike raising the global
// `STARTS`, which would re-feed the surrogate-only path on mid-size boards and
// just slow them down). So the higher count is scoped to here.
const RERANK_STARTS: usize = 128;
const CAP_W_MAX: f64 = 3.0; // max value-priority boost for the smallest cap on a rail
// Extra loop-tightness multiplier for a switching regulator's INPUT decoupling
// loop (Cin→high-side switch→GND). That loop carries the high-dI/dt current and
// dominates radiated EMI (E ∝ f²·area·I; Richtek AN045, TI SNVA638A), so its caps
// are pulled tighter than generic / output decoupling. Applied only when an
// inductor marks the design a switcher. PROVISIONAL — magnitude wants tuning.
const INPUT_LOOP_BOOST: f64 = 2.0;
// Weight on the placement-regularizer term (`compactnessTerm`, default `.tidiness`).
// 0.5 is the long-shipped tidiness weight: the row/column alignment reward keeps
// large boards compact (aligned parts route shorter — load-bearing on 200+ part
// designs) while staying a gentle nudge on small ones. The `.bbox` / `.protrusion`
// area modes are opt-in alternatives; a 12-design sweep showed THEY raise hot-loop
// inductance ~10-13% (up to +88% on a buck) by dragging caps off their IC power
// pins and do nothing for large-board row alignment — so they are not the default.
const ALIGN_CLAMP_MM: f64 = 1.5; // only finish near-alignments within this offset (no long pulls)
const W_ALIGN: f64 = 0.5;
// Weight on the routing-congestion penalty (`congestionPenalty`). HPWL/RSMT alone
// does not predict routability — local congestion must be traded off against it
// (Spindler & Johannes RUDY; UCLA mPL). The penalty is ~0 until a region's
// estimated wire density exceeds the signal-layer budget, so it only steers parts
// apart out of genuine hotspots. PROVISIONAL — the research notes the optimal
// congestion weight is IC-derived and must be swept on real PCBs.
const W_CONGEST: f64 = 2.0;
const GRID_COURTYARDS = true; // round courtyard half-extents to GRID_MM so edges land on-grid
const COMPACT_MIN_OVERLAP: f64 = GRID_MM; // min shared-edge length when docking a floating part
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

/// Which placement-regularizer `w_align` weights.
///   • `tidiness` (default) — the long-shipped pairwise row/column alignment reward
///     (`tidinessPenalty`): for each part pair, the smaller of their x/y offsets,
///     clamped to `ALIGN_CLAMP_MM`. Driving it down lines parts into shared rows /
///     columns, which keeps routing short — essential on large boards (a 301-part
///     design's wirelength ~doubled with it removed) and a gentle nudge on small ones.
///   • `bbox` — area of the whole-module courtyard bounding box (mm²). Only the
///     *outermost* parts feel it, so it does nothing for large-board row alignment.
///   • `protrusion` — Σ per-part squared reach from the cluster centroid to its
///     courtyard's far corner (mm²). Tucks caps' GND inward but fights the hot loop
///     (≈+10-13%, up to +88% on a buck), so it lost the small-board sweep.
/// `bbox`/`protrusion` are opt-in alternatives via the "Compact" dropdown / `?compact=`.
pub const CompactMode = enum { tidiness, bbox, protrusion };

/// Runtime-tunable weights (the consts above are the defaults). Passed to
/// `solve` so the UI can adjust placement without a rebuild. Only the steering
/// weights are exposed; the structural tunables (iters, starts) stay fixed.
pub const Params = struct {
    loop_w: f64 = LOOP_W,
    w_align: f64 = W_ALIGN,
    w_congest: f64 = W_CONGEST,
    cap_w_max: f64 = CAP_W_MAX,
    grid_courtyards: bool = GRID_COURTYARDS,
    compact_mode: CompactMode = .tidiness,
    /// Extra clearance (mm) added to every part's courtyard half-extents (on top
    /// of its F.CrtYd / pad bbox). The optimizer's density floor: two parts can
    /// never sit closer than the sum of their margins. Defaults to the geometry
    /// module's shipping value; exposed so a denser regime can be swept (a hand
    /// layout packed at courtyard-touching density needs a smaller margin to be
    /// reproducible — see the tpsm84338 constraint experiment).
    bbox_margin: f64 = geometry.BBOX_MARGIN_MM,
    /// How much (mm, total) two parts' *drawn* courtyards may overlap in the
    /// collision / legalization test. Default 0: courtyards may **touch** (their
    /// edges land on the shared 0.2 mm grid line — grid-rounded extents +
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
};

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
/// drags on the same grid so manual edits and auto-placement stay aligned.
pub const GRID_MM: f64 = 0.2;

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
    pads: []const geometry.Pad,
    fallback: bool,
    value: []const u8 = "",
    silk_lines: []const geometry.SilkLine = &.{},
    silk_circles: []const geometry.SilkCircle = &.{},
    x: f64 = 0,
    y: f64 = 0,
    rot: f64 = 0,
    /// Collision keepout box (footprint-local). Defaults to the sentinel
    /// (`hw<0`), meaning "use the symmetric courtyard" (`effHw`/`effHh` about
    /// the part centre) — so a part with no escape stub behaves exactly as
    /// before. Escape stubs grow this box outward (see `applyKeepout`).
    keep: Keepout = .{},
};

/// Footprint-local collision keepout: centre offset (`ox`,`oy`) + half-extents
/// (`hw`,`hh`). `hw<0` is the sentinel for "no override → use the courtyard".
const Keepout = struct { ox: f64 = 0, oy: f64 = 0, hw: f64 = -1, hh: f64 = -1 };

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
    alignment: f64, // active compactness term (mm²): bbox area or per-part protrusion per compact_mode (field name kept for wire-compat)
    footprint: f64 = 0, // courtyard bounding-box area (mm²) — always; the yardstick shown for comparing the two modes
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
};

/// A cached part pose (ref-des + centre + rotation) — the persisted form of an
/// auto-generated layout, so the optimizer needn't re-run on every page load.
pub const RefPose = struct { ref: []const u8, x: f64, y: f64, rot: f64 };

const Spring = struct {
    a: usize,
    b: usize,
    ax: f64,
    ay: f64,
    bx: f64,
    by: f64,
    k: f64,
    kind: RatKind,
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
};

/// `buildSprings` output: the force list plus the decoupling loops to score.
const Built = struct {
    springs: []Spring,
    loops: []Loop,
};

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

/// How `solve` treats an applied `cached` layout.
pub const SeedMode = enum {
    /// Apply `cached` verbatim when it covers every part (no optimization, fast);
    /// otherwise place from scratch. The normal load/regenerate path.
    place,
    /// Seed from `cached` and run only the local routed tuck (`routedPolish`) on
    /// it — improve an existing (e.g. hand) layout in place without re-placing.
    refine,
};

/// The from-scratch placement pipeline, factored out so `solve` can run it twice
/// (the strict vs courtyard-overlap retry). Global arrangement first — routed-
/// reranked multi-start where the board has loops and fits the multi-start band,
/// else optimize + symmetrize + compact — then the priority-cap tuck. Mutates
/// `parts` in place; honours the thread's `g_collide_shrink`.
fn runPlacement(
    arena: std.mem.Allocator,
    parts: []Part,
    prep: *Prepared,
    nets: []const FlatNet,
    built: Built,
    params: Params,
) std.mem.Allocator.Error!void {
    // Constructive zone-then-pack floorplan (opt-in): crisp VIN│IC│L│VOUT rows the
    // force model can't make. Returns false (falls through to the force pipeline)
    // for any shape it doesn't handle, so it never degrades a non-switcher board.
    if (params.zone_pack and try packZoned(arena, parts, prep, nets, built, params)) {
        tightenPriorityLoops(arena, parts, built.loops, nets, prep.priority);
        return;
    }
    if (parts.len >= 2 and parts.len <= MULTISTART_MAX_PARTS and built.loops.len > 0) {
        // Routed-reranked multi-start (closes the surrogate↔routed gap; widened
        // from ≤16 to the whole multi-start band so 17–32-part loop boards select
        // on routed too — adf5901 −13%, nestedarray −5%).
        try rerankSolve(arena, parts, &prep.idx_of, nets, built, params, prep.priority);
    } else {
        optimize(parts, &prep.idx_of, nets, built, params);
        // Mirror matched halves (symmetric amp input/output) when genuinely
        // symmetric; a no-op otherwise.
        try symmetrize(arena, parts, &prep.idx_of, nets, built, params);
        // Final pull-together: dock any part still held off by the snap gap so
        // every courtyard abuts a neighbour, highest placement-order priority first.
        compactToContact(parts, prep.priority);
    }
    // Tuck each declared-priority decoupling cap onto its IC pin (a wide per-cap
    // window the global objective/polish can't do); re-routed and reverted if it
    // would drop a net, so it never makes routing worse.
    tightenPriorityLoops(arena, parts, built.loops, nets, prep.priority);
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
const Edge = enum { left, right, top, bottom };

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
fn faceRotation(pwr: PadRect, edge: Edge) f64 {
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
fn packOneBlock(arena: std.mem.Allocator, ordered: []const usize, parts: []const Part, edge: Edge, loops: []const Loop, gap: f64) std.mem.Allocator.Error!PackBlock {
    // Map the criticality order onto centre-out positions: most critical member at
    // the block centre (nearest the rail pad), flanked outward by the rest.
    const seq = try centerOutOrder(arena, ordered);
    const n = seq.len;
    const rots = try arena.alloc(f64, n);
    const lx = try arena.alloc(f64, n);
    const ly = try arena.alloc(f64, n);
    const exts = try arena.alloc(Pt, n);
    const vertical = (edge == .left or edge == .right); // pack along Y
    for (seq, 0..) |m, i| {
        var rot: f64 = 0;
        if (loopForCap(loops, m)) |lp| rot = faceRotation(lp.cap_pwr, edge);
        rots[i] = rot;
        exts[i] = extByRot(parts[m], rot);
    }
    var total: f64 = 0;
    for (exts) |e| total += 2 * (if (vertical) e.y else e.x);
    total += @as(f64, @floatFromInt(n - 1)) * gap;
    var cursor = -total / 2;
    var cross_half: f64 = 0;
    for (0..n) |i| {
        const along = if (vertical) exts[i].y else exts[i].x;
        const center = cursor + along;
        if (vertical) {
            lx[i] = 0;
            ly[i] = center;
        } else {
            lx[i] = center;
            ly[i] = 0;
        }
        cursor += 2 * along + gap;
        cross_half = @max(cross_half, if (vertical) exts[i].x else exts[i].y);
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
    // off the busier edge).
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
        const edge = snapEdge(railDir(ordered, ic, parts, nets, &prep.idx_of)) orelse .bottom;
        var blk = try packOneBlock(arena, ordered, parts, edge, built.loops, gap);
        if (railPadCross(ordered, ic, edge, parts, nets, &prep.idx_of)) |t| {
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
        var blk = try packOneBlock(arena, single, parts, edge, built.loops, gap);
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

    const generated = !applyCached(parts, cached);
    if (generated) {
        try runPlacement(arena, parts, &prep, nets, built, params);
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
    // objective by tens of units — see `src/fuzz_layout.zig`). Routing is a
    // separate explicit action that draws real copper, not the placement score.
    const score = scoreLayout(parts, &prep.idx_of, nets, built.loops);
    const lsum = surrogateLoops(parts, built.loops);
    const bd = breakdownWith(parts, &prep.idx_of, nets, params, score, lsum);
    return finalize(arena, parts, built.springs, built.loops, stubs, prep.instances, nets, prep.priority, score, bd, generated);
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

/// The maze-routed objective for an existing set of `poses` — the same metric
/// `rerankSolve` selects its candidates on (HPWL + routed-loop nH + compactness +
/// congestion), as opposed to the smooth surrogate `scorePoses` reports. Computed
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
    return finalize(arena, parts, built.springs, built.loops, stubs, prep.instances, nets, prep.priority, score, bd, false);
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
    return finalize(arena, parts, built.springs, built.loops, stubs, prep.instances, nets, prep.priority, score, bd, false);
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
    /// Per-part placement-order rank (0 = unranked, higher = earlier in the
    /// declared order) — drives compaction docking order in `solve`.
    priority: []const u32,
    /// Resolved + lowered Phase-A constraints (see docs/constraints_dsl.md).
    /// `prepare` also publishes this to `g_lowered` for the solve.
    lowered: Lowered,
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
        .active = c.present or has_groups,
    };
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
    try netlist_mod.collectInstances(arena, block, "", &inst_list);
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

    var parts = try arena.alloc(Part, instances.len);
    var idx_of = std.StringHashMap(usize).init(arena);
    for (instances, 0..) |inst, i| {
        const hint = pin_counts.get(inst.ref_des) orelse 2;
        const g = geometry.load(arena, project_dir, inst.footprint, hint, params.bbox_margin);
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
            .pads = g.pads,
            .fallback = g.fallback,
            .value = instValue(inst),
            .silk_lines = g.silk_lines,
            .silk_circles = g.silk_circles,
        };
        try idx_of.put(inst.ref_des, i);
    }

    // Resolve declared `(placement-order …)` into per-part data: a priority rank
    // (0 = unranked; higher = earlier in the list) that tightens the loop weight
    // and orders compaction, plus the explicit hub pin a cap's loop should target.
    const priority = try arena.alloc(u32, instances.len);
    @memset(priority, 0);
    const explicit_pin = try arena.alloc([]const u8, instances.len);
    for (explicit_pin) |*e| e.* = "";
    for (block.placement_order) |po| {
        const k: u32 = @intCast(po.entries.len);
        for (po.entries, 0..) |ent, pos| {
            const pi = resolvePart(instances, ent.ref) orelse continue;
            priority[pi] = k - @as(u32, @intCast(pos)); // first listed = highest
            if (ent.pin.len > 0) explicit_pin[pi] = ent.pin;
        }
    }

    const built = try buildSprings(arena, nets, parts, &idx_of, roles, explicit_pin);
    classify(parts, built.loops, nets, params.cap_w_max, priority);
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
    return .{ .parts = parts, .idx_of = idx_of, .instances = instances, .nets = nets, .built = built, .priority = priority, .lowered = lowered };
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
    const al = compactnessTerm(parts, params.compact_mode);
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
            params.w_align * al + params.w_congest * cong,
    };
}

/// Real routed-trace loop sums (raw + value-weighted) via the maze router — used
/// **only by the routed finishing passes** (`routedObjectiveCost` →
/// `rerankSolve`/`routedPolish`), never the reported score (which is the smooth
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

/// True if any two parts' *courtyards* overlap (ignoring escape keepouts) — the
/// validity test for the symmetry pass, which trades the soft breakout
/// reservation for a clean mirror.
fn anyCourtOverlap(parts: []const Part) bool {
    for (parts, 0..) |a, i| {
        for (parts[i + 1 ..]) |b| {
            const ox = (effHw(a) + effHw(b)) - @abs(a.x - b.x);
            const oy = (effHh(a) + effHh(b)) - @abs(a.y - b.y);
            if (ox > 1e-9 and oy > 1e-9) return true;
        }
    }
    return false;
}

/// Small-board solve that picks the global arrangement on the *routed* metric.
/// The multi-start ranks arrangements by the fixed-pad surrogate, but the
/// surrogate-best isn't always the routed-best, and `routedPolish`'s ±0.6mm
/// window can only tuck a cap, not move it to the other side of the IC — so a
/// poor side-assignment survives. Here we keep the K lowest-surrogate relaxed
/// candidates, finish each one fully (polish → legalize → symmetrise → compact),
/// score the finished arrangement by the real routed objective, keep the best,
/// then run the local routed tuck on it. The surrogate-best is always among the
/// K, so the result is never worse than the single-arrangement path. K scales
/// down with part count to bound the per-candidate finish cost.
fn rerankSolve(
    arena: std.mem.Allocator,
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    built: Built,
    params: Params,
    priority: []const u32,
) std.mem.Allocator.Error!void {
    // rerankSolve runs on loop-bearing boards within the multi-start band
    // (≤ MULTISTART_MAX_PARTS), so the multi-start + rotation refine always apply.
    // The final routed tuck (`routedPolish`) self-gates to ≤ ROUTED_POLISH_MAX_PARTS;
    // above that the top-K routed rerank alone carries the routed selection.
    const starts: usize = RERANK_STARTS;
    const rounds: usize = ROT_ROUNDS;
    const k = std.math.clamp(RERANK_BUDGET / parts.len, 2, RERANK_K);

    // Keep the K lowest-surrogate relaxed arrangements (poses flattened K×n).
    var cand = try arena.alloc(Pose, k * parts.len);
    const cand_cost = try arena.alloc(f64, k);
    for (cand_cost) |*c| c.* = std.math.inf(f64);
    // Track the running best surrogate cost only to stream "explore" frames to a
    // live watcher on each improvement (the top-K bookkeeping below is unchanged).
    var best_surr: f64 = std.math.inf(f64);
    var s: usize = 0;
    while (s < starts) : (s += 1) {
        runStart(parts, idx_of, nets, built, s, rounds, params);
        const cost = objectiveCost(parts, idx_of, nets, built.loops, params);
        if (cost < best_surr) {
            best_surr = cost;
            emitBest(parts, cost, .explore);
        }
        var worst: usize = 0;
        for (cand_cost, 0..) |c, i| {
            if (c > cand_cost[worst]) worst = i;
        }
        if (cost < cand_cost[worst]) {
            cand_cost[worst] = cost;
            for (parts, 0..) |p, j| cand[worst * parts.len + j] = .{ .x = p.x, .y = p.y, .rot = p.rot };
        }
    }

    // Finish each kept candidate and keep the routed-best finished arrangement.
    var scratch = std.heap.ArenaAllocator.init(arena);
    defer scratch.deinit();
    const best = try arena.alloc(Pose, parts.len);
    var best_cost: f64 = std.math.inf(f64);
    var have = false;
    for (0..k) |c| {
        if (cand_cost[c] == std.math.inf(f64)) continue;
        for (parts, 0..) |*p, j| {
            p.x = cand[c * parts.len + j].x;
            p.y = cand[c * parts.len + j].y;
            p.rot = cand[c * parts.len + j].rot;
        }
        polish(parts, idx_of, nets, built.loops, params);
        legalizeFinal(parts);
        try symmetrize(arena, parts, idx_of, nets, built, params);
        compactToContact(parts, priority);
        _ = scratch.reset(.retain_capacity);
        const sc = routedObjectiveCost(scratch.allocator(), parts, idx_of, nets, built.loops, params);
        if (!have or sc < best_cost) {
            best_cost = sc;
            have = true;
            for (parts, 0..) |p, j| best[j] = .{ .x = p.x, .y = p.y, .rot = p.rot };
            // Stream this finished, routed-scored candidate (`parts` hold it now).
            emitBest(parts, sc, .refine);
        }
    }
    if (have) for (parts, 0..) |*p, j| {
        p.x = best[j].x;
        p.y = best[j].y;
        p.rot = best[j].rot;
    };

    // Local routed tuck on the chosen global arrangement.
    routedPolish(arena, parts, idx_of, nets, built.loops, params);
}

/// Run the placer: multi-start seeds → keep the lowest-scoring arrangement →
/// polish, then legalize. Small boards (modules) get the full treatment;
/// large whole-board layouts take a single grid-seeded relax with no rotation
/// (they blob together regardless — per-module grouping is future work).
fn optimize(parts: []Part, idx_of: *std.StringHashMap(usize), nets: []const FlatNet, built: Built, params: Params) void {
    if (parts.len == 0 or parts.len > maxParts) return;
    const small = parts.len <= MULTISTART_MAX_PARTS;
    const starts: usize = if (small) STARTS else 1;
    // Rotation refine is part of the cheap finishing work — keep it on for the
    // single-start band above MULTISTART_MAX_PARTS, where seed quality is lower
    // and a flipped cap matters more, not less.
    const rounds: usize = if (parts.len <= POLISH_MAX_PARTS) ROT_ROUNDS else 0;
    var best: [maxParts]Pose = undefined;
    var best_cost: f64 = std.math.inf(f64);
    var s: usize = 0;
    while (s < starts) : (s += 1) {
        runStart(parts, idx_of, nets, built, s, rounds, params);
        const cost = objectiveCost(parts, idx_of, nets, built.loops, params);
        if (cost < best_cost) {
            best_cost = cost;
            for (parts, 0..) |p, i| best[i] = .{ .x = p.x, .y = p.y, .rot = p.rot };
            // Stream this new best to a live watcher (`parts` hold it right now).
            emitBest(parts, cost, .explore);
        }
    }
    for (parts, 0..) |*p, i| {
        p.x = best[i].x;
        p.y = best[i].y;
        p.rot = best[i].rot;
    }
    // Polish only the winning arrangement (the local search is the costliest
    // step — running it per start would be 64× the work for no extra quality).
    polish(parts, idx_of, nets, built.loops, params);
    legalizeFinal(parts);
}

/// Robust overlap removal: the continuous force pass converges smoothly where
/// the grid-only nudger can oscillate on a tight pack (e.g. large escape-stub
/// keepouts), then snap + grid-legalize so the result is on-grid and clean.
fn legalizeFinal(parts: []Part) void {
    legalize(parts, FINAL_CLEAR);
    snapToGrid(parts);
    legalizeOnGrid(parts);
}

/// Final tightening: pull every part into one connected mass so each courtyard
/// abuts at least one neighbour — the layout is then provably as compact as it
/// packs. The optimizer/polish leave a snap-safety gap (`FINAL_CLEAR`) around
/// parts; this pass grows a single blob outward from the hubs (the anchors,
/// which never move): any passive already flush against the blob stays put, then
/// each remaining floating part is docked — cheapest move first — onto the blob,
/// keeping its perpendicular position where it can. Growing from one seed
/// (rather than docking to any nearest neighbour) is what keeps it from leaving
/// disconnected islands. Courtyards already bake in `BBOX_MARGIN_MM`, so abutting
/// them is DRC-clean; overlap is still tested against the (escape-stub-aware)
/// keepout, so a part with a reserved breakout corridor may not reach the blob —
/// best effort, never an overlap.
fn compactToContact(parts: []Part, priority: []const u32) void {
    const n = parts.len;
    if (n < 2 or n > maxParts) return;
    var settled_buf: [maxParts]bool = undefined;
    const settled = settled_buf[0..n];
    for (settled) |*s| s.* = false;

    // Seed the blob with the hubs (anchors). With no hub, seed the part nearest
    // the cluster centroid so the blob still grows from the middle.
    var has_anchor = false;
    for (parts, 0..) |p, i| {
        if (p.kind == .hub) {
            settled[i] = true;
            has_anchor = true;
        }
    }
    if (!has_anchor) settled[centralIndex(parts)] = true;
    growSettled(parts, settled);

    // Spatial hash over the (static-within-a-pass) part keepouts, so the
    // per-dock `overlapsAny` test is ~O(1) instead of O(n). Rebuilt after each
    // commit (the only point a part actually moves); bit-identical to the dense
    // scan because the query is a pure boolean OR (see CompactGrid). On the big
    // single-start boards this docking loop is the dominant cost.
    var grid: CompactGrid = undefined;
    grid.build(parts);

    // Attach the rest highest-priority first (so declared parts claim the space
    // nearest the hub before the rest fill in), each at its own cheapest dock —
    // so the mass stays connected and every move is as small as it can be. With
    // uniform priority this is exactly the prior cheapest-first packing.
    while (true) {
        var pick: ?usize = null;
        var pick_pt: Pt = undefined;
        var best_pri: u32 = 0;
        var best_d2: f64 = std.math.inf(f64);
        for (parts, 0..) |_, i| {
            if (settled[i]) continue;
            const d = bestDock(parts, i, settled, &grid) orelse continue;
            const take = pick == null or priority[i] > best_pri or
                (priority[i] == best_pri and d.d2 < best_d2 - 1e-12);
            if (take) {
                best_pri = priority[i];
                best_d2 = d.d2;
                pick = i;
                pick_pt = d.pt;
            }
        }
        const i = pick orelse break;
        parts[i].x = pick_pt.x;
        parts[i].y = pick_pt.y;
        settled[i] = true;
        growSettled(parts, settled);
        grid.build(parts); // the docked part moved → refresh the hash
    }
}

/// Half-window (grid cells) the priority-cap tuck scans — wider than the polish
/// window so a bypass cap can be pulled the full width of a small IC onto its
/// pin (±`TIGHTEN_CELLS`·`GRID_MM` ≈ ±2.8 mm).
const TIGHTEN_CELLS: i64 = 14;

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
    for (ROT_CAND) |r| {
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

/// Index of the part closest to the cluster centroid — the blob seed when a
/// design has no hub to anchor on.
fn centralIndex(parts: []const Part) usize {
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (parts) |p| {
        cx += p.x;
        cy += p.y;
    }
    const inv = 1.0 / @as(f64, @floatFromInt(parts.len));
    cx *= inv;
    cy *= inv;
    var best: usize = 0;
    var best_d2: f64 = std.math.inf(f64);
    for (parts, 0..) |p, i| {
        const d2 = (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy);
        if (d2 < best_d2) {
            best_d2 = d2;
            best = i;
        }
    }
    return best;
}

/// Transitively settle every part whose courtyard already abuts a settled one,
/// so parts the optimizer placed flush against the blob aren't needlessly moved.
fn growSettled(parts: []const Part, settled: []bool) void {
    var changed = true;
    while (changed) {
        changed = false;
        for (parts, 0..) |_, i| {
            if (settled[i]) continue;
            for (parts, 0..) |_, j| {
                if (i == j or !settled[j]) continue;
                if (courtyardEdge(parts[i], parts[j])) {
                    settled[i] = true;
                    changed = true;
                    break;
                }
            }
        }
    }
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

/// True when part `i`'s courtyard shares an edge with any other part's.
fn courtyardTouchesAny(parts: []const Part, i: usize) bool {
    for (parts, 0..) |_, j| {
        if (j != i and courtyardEdge(parts[i], parts[j])) return true;
    }
    return false;
}

/// A dock candidate: the grid-aligned centre and its squared displacement.
const Dock = struct { pt: Pt, d2: f64 };

/// Minimum-displacement grid-aligned centre that makes part `i`'s courtyard abut
/// a *settled* part, with its keepout overlapping nothing. Tries each side of
/// every settled part, preserving `i`'s perpendicular coordinate (clamped just
/// enough to keep a `COMPACT_MIN_OVERLAP` shared edge). Null when none is
/// reachable (e.g. every dock would overlap a third part).
fn bestDock(parts: []Part, i: usize, settled: []const bool, grid: ?*const CompactGrid) ?Dock {
    const ox = parts[i].x;
    const oy = parts[i].y;
    const phw = effHw(parts[i]);
    const phh = effHh(parts[i]);
    // The trial part's keepout box is position-independent (rot is fixed during
    // the dock), so compute it once for the grid-accelerated overlap test.
    const tbox = keepBoxOf(parts[i]);
    var best: ?Pt = null;
    var best_d2: f64 = std.math.inf(f64);
    for (parts, 0..) |o, j| {
        if (j == i or !settled[j]) continue;
        const sumw = phw + effHw(o);
        const sumh = phh + effHh(o);
        // Left / right of o: slide along x, keep y (clamped into the overlap band).
        const ylim = @max(0.0, sumh - COMPACT_MIN_OVERLAP);
        const cy = std.math.clamp(oy, o.y - ylim, o.y + ylim);
        considerDock(parts, i, o.x + sumw, cy, ox, oy, &best, &best_d2, grid, tbox);
        considerDock(parts, i, o.x - sumw, cy, ox, oy, &best, &best_d2, grid, tbox);
        // Above / below o: slide along y, keep x (clamped into the overlap band).
        const xlim = @max(0.0, sumw - COMPACT_MIN_OVERLAP);
        const cx = std.math.clamp(ox, o.x - xlim, o.x + xlim);
        considerDock(parts, i, cx, o.y + sumh, ox, oy, &best, &best_d2, grid, tbox);
        considerDock(parts, i, cx, o.y - sumh, ox, oy, &best, &best_d2, grid, tbox);
    }
    if (best) |pt| return .{ .pt = pt, .d2 = best_d2 };
    return null;
}

/// Evaluate one candidate dock centre for part `i`: snap to grid, reject if its
/// keepout overlaps anything, else keep it when it is the closest valid dock so
/// far. Restores `i`'s position before returning (the caller commits the winner).
/// With a `grid`, the overlap test is the O(1) spatial-hash query (bit-identical
/// to the dense `overlapsAny`); `tbox` is `parts[i]`'s precomputed keepout.
fn considerDock(parts: []Part, i: usize, cx: f64, cy: f64, ox: f64, oy: f64, best: *?Pt, best_d2: *f64, grid: ?*const CompactGrid, tbox: KeepBox) void {
    const sx = @round(cx / GRID_MM) * GRID_MM;
    const sy = @round(cy / GRID_MM) * GRID_MM;
    const bad = if (grid) |g|
        g.overlaps(i, tbox, sx + tbox.cxo, sy + tbox.cyo)
    else blk: {
        parts[i].x = sx;
        parts[i].y = sy;
        const b = overlapsAny(parts, &parts[i]);
        parts[i].x = ox;
        parts[i].y = oy;
        break :blk b;
    };
    if (bad) return;
    const d2 = (sx - ox) * (sx - ox) + (sy - oy) * (sy - oy);
    if (d2 < best_d2.* - 1e-12) {
        best_d2.* = d2;
        best.* = .{ .x = sx, .y = sy };
    }
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

/// Greedy local search: for each passive, jointly try every rotation and a
/// window of grid positions, keeping the non-overlapping (position, rotation)
/// that most lowers the objective. Position and rotation must be optimized
/// *together* — the relax-phase rotation can be stale for a part's final spot
/// (e.g. a cap rotated for a short power leg but a long ground one). Several
/// sweeps until no part improves.
fn polish(
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    params: Params,
) void {
    if (parts.len < 2 or parts.len > POLISH_MAX_PARTS) return;
    // Each candidate cell costs a full-board objective eval (no incremental
    // precompute yet), so the per-part window is (2·cells+1)² evals. On the
    // single-start band above MULTISTART_MAX_PARTS that quadratic times tens of
    // extra parts is what makes a regen drag, and the relax pass has already
    // brought every part within ~a grid cell of its spot — so a tighter local
    // tuck recovers nearly all the quality at a fraction of the evals.
    const cells: i64 = if (parts.len <= MULTISTART_MAX_PARTS) POLISH_CELLS else POLISH_CELLS_LARGE;
    var sweep: usize = 0;
    while (sweep < POLISH_SWEEPS) : (sweep += 1) {
        var improved = false;
        for (parts, 0..) |*p, i| {
            if (p.kind == .hub) continue;
            if (polishPart(parts, idx_of, nets, loops, i, cells, params)) improved = true;
        }
        if (!improved) break;
    }
}

/// Pick the best (position, rotation) for part `i` over a grid window × the
/// four rotations, holding the others fixed. Returns true if it improved.
fn polishPart(
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    i: usize,
    cells: i64,
    params: Params,
) bool {
    const p = &parts[i];
    const ox = p.x;
    const oy = p.y;
    var best_cost = objectiveCost(parts, idx_of, nets, loops, params);
    var best_x = ox;
    var best_y = oy;
    var best_rot = p.rot;
    var improved = false;
    for (ROT_CAND) |r| {
        var dy: i64 = -cells;
        while (dy <= cells) : (dy += 1) {
            var dx: i64 = -cells;
            while (dx <= cells) : (dx += 1) {
                p.rot = r;
                p.x = ox + @as(f64, @floatFromInt(dx)) * GRID_MM;
                p.y = oy + @as(f64, @floatFromInt(dy)) * GRID_MM;
                if (overlapsAny(parts, p)) continue;
                const c = objectiveCost(parts, idx_of, nets, loops, params);
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

/// Final refinement on the *routed* objective. Mirrors `polish` (greedy per-part
/// position × rotation grid search, several sweeps) but scores every candidate
/// with `routedObjectiveCost` — the real maze-routed loop length, the same metric
/// the headline reports. The surrogate-driven `polish` tucks parts by a straight
/// edge-to-edge gap, which can settle a cap on a rotation/side the router then
/// routes long; this pass re-tucks each part to what actually routes short. Runs
/// once on the finished layout, small boards only (one layout, so the router cost
/// is bounded — one route per candidate cell). The window is deliberately small
/// (`ROUTED_POLISH_CELLS`): a local tuck/flip, not a re-place, so it never undoes
/// the global arrangement the multi-start already chose.
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
        params.w_align * compactnessTerm(parts, params.compact_mode) + cong;
}

/// `polishPart` for the routed objective: pick the (position, rotation) over a
/// small grid window that most lowers the routed objective, holding the others
/// fixed. For speed it re-routes only the loop(s) owned by the moved cap `i` per
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
    for (ROT_CAND) |r| {
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

// ── Symmetry ───────────────────────────────────────────────────────────────

/// Accept a mirrored layout if its cost is within this factor of the free one.
/// Generous: mirroring spreads the halves (higher HPWL) but the user wants the
/// symmetry — the paired-fraction gate is what actually guards against firing
/// on a board that isn't really symmetric.
const SYM_TOL: f64 = 3.0;
/// At least this fraction of parts must pair up (so asymmetric boards skip it).
const SYM_MIN_PAIR_FRAC: f64 = 0.6;

/// Make a symmetric design's matched halves mirror each other. Pairs parts
/// whose net connections map onto each other under an IN↔OUT role swap (same
/// footprint/kind), finds the mirror axis from the paired geometry, reflects
/// one half onto the other (trying each side as the master), and keeps the
/// result only when enough parts paired *and* the cost stayed within `SYM_TOL`.
/// Otherwise the free layout is left untouched — so asymmetric boards are safe.
fn symmetrize(
    arena: std.mem.Allocator,
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    built: Built,
    params: Params,
) std.mem.Allocator.Error!void {
    if (parts.len < 4 or parts.len > MULTISTART_MAX_PARTS) return;
    const partner = try computeMirrorPairs(arena, parts, nets, idx_of);
    var npairs: usize = 0;
    for (partner, 0..) |pr, i| {
        if (pr) |j| {
            if (j > i) npairs += 1;
        }
    }
    if (npairs < 2) return;
    const frac = @as(f64, @floatFromInt(2 * npairs)) / @as(f64, @floatFromInt(parts.len));
    if (frac < SYM_MIN_PAIR_FRAC) return;

    var base: [maxParts]Pose = undefined;
    for (parts, 0..) |p, i| base[i] = .{ .x = p.x, .y = p.y, .rot = p.rot };
    const base_cost = objectiveCost(parts, idx_of, nets, built.loops, params);

    // Mirror axis: parts of a pair are separated along the axis-normal, so the
    // dominant separation picks horizontal vs vertical; the axis line is the
    // grid-snapped mean of the pair midpoints.
    var sumdx: f64 = 0;
    var sumdy: f64 = 0;
    var acc: f64 = 0;
    for (partner, 0..) |pr, i| {
        const j = pr orelse continue;
        if (j <= i) continue;
        sumdx += @abs(parts[i].x - parts[j].x);
        sumdy += @abs(parts[i].y - parts[j].y);
    }
    const horizontal = sumdy >= sumdx;
    for (partner, 0..) |pr, i| {
        const j = pr orelse continue;
        if (j <= i) continue;
        acc += if (horizontal) (parts[i].y + parts[j].y) / 2 else (parts[i].x + parts[j].x) / 2;
    }
    const axis = @round((acc / @as(f64, @floatFromInt(npairs))) / GRID_MM) * GRID_MM;

    var best: [maxParts]Pose = undefined;
    var best_cost = std.math.inf(f64);
    for ([_]bool{ false, true }) |master_high| {
        for (parts, 0..) |*p, i| {
            p.x = base[i].x;
            p.y = base[i].y;
            p.rot = base[i].rot;
        }
        // Center the hub(s) on the axis — a single-hub symmetric design mirrors
        // about its anchor, so an off-axis hub would collide with the reflected
        // half and block the symmetric pack.
        for (parts) |*p| {
            if (p.kind != .hub) continue;
            if (horizontal) p.y = axis else p.x = axis;
        }
        applyMirror(parts, partner, horizontal, axis, master_high);
        // Symmetry-preserving legalize: only masters move, partners stay exact
        // reflections — so a converged result is both overlap-free *and* a clean
        // single-axis mirror. Reject (and fall back) if it can't clear.
        legalizeHalf(parts, partner, horizontal, axis);
        if (anyCourtOverlap(parts)) continue; // never accept colliding courtyards
        const c = objectiveCost(parts, idx_of, nets, built.loops, params);
        if (c < best_cost) {
            best_cost = c;
            for (parts, 0..) |p, i| best[i] = .{ .x = p.x, .y = p.y, .rot = p.rot };
        }
    }

    const keep = std.math.isFinite(best_cost) and best_cost <= base_cost * SYM_TOL;
    const src = if (keep) &best else &base;
    for (parts, 0..) |*p, i| {
        p.x = src[i].x;
        p.y = src[i].y;
        p.rot = src[i].rot;
    }
}

/// Reflect one part of each pair across `axis` (the other becomes its mirror).
/// `master_high` selects which side is authoritative (we try both and keep the
/// cheaper). The non-master member is overwritten with the master's reflection.
fn applyMirror(parts: []Part, partner: []const ?usize, horizontal: bool, axis: f64, master_high: bool) void {
    for (partner, 0..) |pr, i| {
        const j = pr orelse continue;
        if (j <= i) continue;
        const ci = if (horizontal) parts[i].y else parts[i].x;
        const cj = if (horizontal) parts[j].y else parts[j].x;
        const i_high = ci > cj;
        const master: usize = if (i_high == master_high) i else j;
        const other: usize = if (master == i) j else i;
        const m = reflectPose(parts[master], horizontal, axis);
        parts[other].x = m.x;
        parts[other].y = m.y;
        parts[other].rot = m.rot;
    }
}

/// Reflect a pose across the mirror axis. A right-angle part keeps the same
/// footprint, so its orientation maps to the mirrored right-angle (exact for
/// the 2-pad passives that dominate symmetric pairs).
fn reflectPose(p: Part, horizontal: bool, axis: f64) Pose {
    if (horizontal) return .{ .x = p.x, .y = 2 * axis - p.y, .rot = @mod(360 - p.rot, 360) };
    return .{ .x = 2 * axis - p.x, .y = p.y, .rot = @mod(180 - p.rot, 360) };
}

/// Lower-index member of a part's mirror pair (its "master"), or the part
/// itself when unpaired. Only masters carry a degree of freedom.
fn masterOf(partner: []const ?usize, k: usize) usize {
    return if (partner[k]) |m| @min(k, m) else k;
}

/// Overlap removal that keeps the mirror exact: a nudge to part `k` is applied
/// to its *master*, and the partner is re-synced to the master's reflection —
/// so paired parts never drift onto different axes. Converges like the grid
/// legalizer (only masters are free); leaves residual only if the symmetric
/// arrangement genuinely can't fit (the caller then rejects this candidate).
fn legalizeHalf(parts: []Part, partner: []const ?usize, horizontal: bool, axis: f64) void {
    const n = parts.len;
    if (n == 0) return;
    var it: usize = 0;
    while (it < LEGALIZE_ITERS) : (it += 1) {
        var any = false;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var j: usize = i + 1;
            while (j < n) : (j += 1) {
                // Courtyard-only (not escape keepout): symmetry takes priority
                // over the soft breakout reservation, so the symmetric pack is
                // feasible. Escape traces still draw; they just aren't reserved.
                const dx = parts[i].x - parts[j].x;
                const dy = parts[i].y - parts[j].y;
                const ox = (effHw(parts[i]) + effHw(parts[j])) - @abs(dx);
                const oy = (effHh(parts[i]) + effHh(parts[j])) - @abs(dy);
                if (ox <= 0 or oy <= 0) continue;
                any = true;
                if (ox < oy) {
                    moveMaster(parts, partner, horizontal, axis, j, -signNudge(dx, i, j) * GRID_MM, 0);
                } else {
                    moveMaster(parts, partner, horizontal, axis, j, 0, -signNudge(dy, i, j) * GRID_MM);
                }
            }
        }
        if (!any) break;
    }
}

/// Move concrete part `k` by (dx,dy) through its master so the pair stays an
/// exact reflection: if `k` is the reflected partner, the master is moved by
/// the pre-image delta; then the partner is re-synced to the reflection.
fn moveMaster(parts: []Part, partner: []const ?usize, horizontal: bool, axis: f64, k: usize, dx: f64, dy: f64) void {
    const master = masterOf(partner, k);
    if (master == k) {
        parts[k].x += dx;
        parts[k].y += dy;
    } else if (horizontal) {
        parts[master].x += dx;
        parts[master].y -= dy;
    } else {
        parts[master].x -= dx;
        parts[master].y += dy;
    }
    if (partner[master]) |o| {
        const r = reflectPose(parts[master], horizontal, axis);
        parts[o].x = r.x;
        parts[o].y = r.y;
        parts[o].rot = r.rot;
    }
}

/// Pair each part with the one whose net set is its mirror image (IN↔OUT role
/// swap), same footprint + kind. Returns a per-part partner index (or null for
/// unpaired / central parts). The pairing is an involution.
fn computeMirrorPairs(
    arena: std.mem.Allocator,
    parts: []const Part,
    nets: []const FlatNet,
    idx_of: *std.StringHashMap(usize),
) std.mem.Allocator.Error![]?usize {
    var lists = try arena.alloc(std.ArrayListUnmanaged([]const u8), parts.len);
    for (lists) |*l| l.* = .empty;
    for (nets) |net| {
        for (net.pins) |pr| {
            const i = idx_of.get(pr.ref_des) orelse continue;
            try lists[i].append(arena, net.name);
        }
    }
    const nset = try arena.alloc([]const []const u8, parts.len);
    const mset = try arena.alloc([]const []const u8, parts.len);
    for (lists, 0..) |*l, i| {
        nset[i] = try sortedUnique(arena, l.items);
        mset[i] = try mirrorSet(arena, nset[i]);
    }

    const partner = try arena.alloc(?usize, parts.len);
    for (partner) |*p| p.* = null;
    for (0..parts.len) |i| {
        if (partner[i] != null or nset[i].len == 0) continue;
        if (eqSets(mset[i], nset[i])) continue; // central (self-symmetric)
        for (i + 1..parts.len) |j| {
            if (partner[j] != null) continue;
            if (parts[j].kind != parts[i].kind or parts[j].hw != parts[i].hw or parts[j].hh != parts[i].hh) continue;
            if (eqSets(mset[i], nset[j])) {
                partner[i] = j;
                partner[j] = i;
                break;
            }
        }
    }
    return partner;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Sort `names` and drop adjacent duplicates into a fresh slice.
fn sortedUnique(arena: std.mem.Allocator, names: [][]const u8) std.mem.Allocator.Error![]const []const u8 {
    std.mem.sort([]const u8, names, {}, lessStr);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    for (names, 0..) |nm, k| {
        if (k > 0 and std.mem.eql(u8, nm, names[k - 1])) continue;
        try out.append(arena, nm);
    }
    return out.toOwnedSlice(arena);
}

/// The IN↔OUT mirror image of a (sorted) net-name set, re-sorted. Central nets
/// (no IN/OUT token) map to themselves.
fn mirrorSet(arena: std.mem.Allocator, s: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, s.len);
    for (s, 0..) |nm, i| out[i] = (try mirrorNetName(arena, nm)) orelse nm;
    std.mem.sort([]const u8, out, {}, lessStr);
    return out;
}

/// Swap the IN/OUT direction token in a net name ("RF_IN"→"RF_OUT",
/// "INPUT_BIAS"→"OUTPUT_BIAS"), or null when it has neither (a central net).
fn mirrorNetName(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (std.mem.indexOf(u8, name, "OUT") != null) return try replaceAlloc(arena, name, "OUT", "IN");
    if (std.mem.indexOf(u8, name, "IN") != null) return try replaceAlloc(arena, name, "IN", "OUT");
    return null;
}

fn replaceAlloc(arena: std.mem.Allocator, input: []const u8, needle: []const u8, repl: []const u8) std.mem.Allocator.Error![]const u8 {
    const size = std.mem.replacementSize(u8, input, needle, repl);
    const buf = try arena.alloc(u8, size);
    _ = std.mem.replace(u8, input, needle, repl, buf);
    return buf;
}

/// Element-wise equality of two sorted name sets.
fn eqSets(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// True if `p`'s courtyard overlaps any other part's (rotation-aware).
fn overlapsAny(parts: []const Part, p: *const Part) bool {
    for (parts) |*o| {
        if (o == p) continue;
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

/// World position of a footprint-local point on `p`, honouring its rotation.
/// Rotation is one of {0,90,180,270}; the `rot == 0` identity is by far the
/// commonest case (every hub, and unrotated passives) and the inner loops call
/// this millions of times, so it skips `rotateLocal`'s `@mod`/`@round`/switch.
fn worldPt(p: Part, lx: f64, ly: f64) Pt {
    if (p.rot == 0) return .{ .x = p.x + lx, .y = p.y + ly };
    const r = rotateLocal(lx, ly, p.rot);
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
        const hw0 = pr.w / 2;
        const hh0 = pr.h / 2;
        return .{ .x0 = p.x + pr.x - hw0, .y0 = p.y + pr.y - hh0, .x1 = p.x + pr.x + hw0, .y1 = p.y + pr.y + hh0 };
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

/// Collision-keepout box used by every overlap/repulsion test: the escape-stub
/// box when set (`khw≥0`), else the symmetric courtyard about the part centre
/// (sentinel `khw<0` ⇒ identical to the pre-stub behaviour). The centre offset
/// rotates with the part; the half-extents swap on a quarter turn.
fn keepCx(p: Part) f64 {
    return if (p.keep.hw < 0) p.x else worldPt(p, p.keep.ox, p.keep.oy).x;
}
fn keepCy(p: Part) f64 {
    return if (p.keep.hw < 0) p.y else worldPt(p, p.keep.ox, p.keep.oy).y;
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
        var x0 = -p.hw;
        var x1 = p.hw;
        var y0 = -p.hh;
        var y1 = p.hh;
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

/// Coordinate descent over rotation: for each passive, set the 0/90/180/270°
/// that minimizes the global objective (HPWL + weighted loop). Hubs are left
/// at 0° — for a single-hub module their rotation is a degenerate global
/// frame turn that changes no relative distance.
fn optimizeRotations(
    parts: []Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    params: Params,
) void {
    for (parts) |*p| {
        if (p.kind == .hub) continue;
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
/// wirelength(RSMT) + `LOOP_W`·(value-weighted loop inductance) + `W_ALIGN`·
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
        params.w_align * compactnessTerm(parts, params.compact_mode) + cong +
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
            c += (INPUT_LOOP_BOOST - 1.0) * params.loop_w * lp.weight * nh;
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
    const ar = Rect{ .x0 = a.x - effHw(a), .y0 = a.y - effHh(a), .x1 = a.x + effHw(a), .y1 = a.y + effHh(a) };
    const br = Rect{ .x0 = b.x - effHw(b), .y0 = b.y - effHh(b), .x1 = b.x + effHw(b), .y1 = b.y + effHh(b) };
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
    return hpwl + params.loop_w * loop_weighted + params.w_align * compactnessTerm(parts, params.compact_mode) + cong;
}

/// The whole sub-module's footprint area (mm²): the area of the axis-aligned
/// bounding box over every part's rotation-aware courtyard (`effHw`/`effHh`).
/// Replaces the old pairwise tidiness reward — minimising the envelope pulls
/// parts in tight and, because a decoupling cap whose GND pad points *away*
/// from its IC pushes the bounding box outward, biases each cap toward the
/// orientation that keeps the whole circuit compact (GND tucked alongside the
/// chip rather than sticking out into empty space).
fn compactnessArea(parts: []const Part) f64 {
    if (parts.len == 0) return 0;
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (parts) |p| {
        minx = @min(minx, p.x - effHw(p));
        miny = @min(miny, p.y - effHh(p));
        maxx = @max(maxx, p.x + effHw(p));
        maxy = @max(maxy, p.y + effHh(p));
    }
    return (maxx - minx) * (maxy - miny);
}

/// Per-part protrusion (mm²): Σ over parts of the squared distance from the
/// cluster centroid to that part's courtyard corner *facing away* from the
/// centroid (`|Δx|+effHw`, `|Δy|+effHh`). Unlike the bounding box, *every* part
/// contributes a gradient, so each cap is pulled toward the centre **and**
/// rotated to present its short axis outward — a cap offset mostly in x prefers
/// its long axis vertical (tangential), which tucks the GND pad alongside the IC
/// instead of letting it jut into empty space. The whole-cluster spread the
/// box metric can't see at the interior.
fn compactnessProtrusion(parts: []const Part) f64 {
    if (parts.len == 0) return 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (parts) |p| {
        cx += p.x;
        cy += p.y;
    }
    const inv = 1.0 / @as(f64, @floatFromInt(parts.len));
    cx *= inv;
    cy *= inv;
    var total: f64 = 0;
    for (parts) |p| {
        const rx = @abs(p.x - cx) + effHw(p);
        const ry = @abs(p.y - cy) + effHh(p);
        total += rx * rx + ry * ry;
    }
    return total;
}

/// The active compactness term `w_align` weights, selected by `mode`. Both are
/// in mm² so the weight stays on a comparable scale across the two.
fn compactnessTerm(parts: []const Part, mode: CompactMode) f64 {
    return switch (mode) {
        .tidiness => tidinessPenalty(parts),
        .bbox => compactnessArea(parts),
        .protrusion => compactnessProtrusion(parts),
    };
}

/// Tidiness reward (as a penalty to minimize): for each part pair, the smaller of
/// their x/y offsets, clamped to `ALIGN_CLAMP_MM`. Driving it down lines parts up
/// into shared rows / columns; the clamp means only near-aligned pairs feel a pull,
/// so distant parts aren't dragged together. The long-shipped default regularizer —
/// cheap, and on large boards aligned rows route far shorter (the `.bbox`/
/// `.protrusion` area modes do not align, so they can't substitute here).
fn tidinessPenalty(parts: []const Part) f64 {
    var total: f64 = 0;
    for (parts, 0..) |a, i| {
        for (parts[i + 1 ..]) |b| {
            const off = @min(@abs(a.x - b.x), @abs(a.y - b.y));
            total += @min(off, ALIGN_CLAMP_MM);
        }
    }
    return total;
}

const CONGEST_BINS: usize = 8; // congestion grid resolution per axis
const CONGEST_PITCH_MM: f64 = 0.254; // one wire's footprint ≈ track_width + clearance
const CONGEST_CAP: f64 = 2.0; // routable wire-density per bin (top + bottom signal layers)

/// Routing-congestion penalty (RUDY: Rectangular Uniform wire DensitY). Lays a
/// coarse grid over the board and, for each signal net, spreads its estimated
/// wire area (HPWL × wire pitch) uniformly over its bounding box, accumulating a
/// dimensionless wire-density per bin. The penalty is the summed squared overflow
/// of each bin above the signal-layer budget `CONGEST_CAP` — zero on a sparse
/// board, growing where many nets pile into one region. This predicts routability
/// (whether the board routes clean), which pure wirelength does not — it must be
/// traded off against HPWL, not minimized in isolation (Spindler & Johannes;
/// UCLA mPL supply/demand). Ground nets are excluded (they drop to the plane).
fn congestionPenalty(parts: []const Part, idx_of: *std.StringHashMap(usize), nets: []const FlatNet) f64 {
    if (parts.len == 0) return 0;
    var minx: f64 = std.math.inf(f64);
    var miny: f64 = std.math.inf(f64);
    var maxx: f64 = -std.math.inf(f64);
    var maxy: f64 = -std.math.inf(f64);
    for (parts) |p| {
        minx = @min(minx, p.x - effHw(p));
        miny = @min(miny, p.y - effHh(p));
        maxx = @max(maxx, p.x + effHw(p));
        maxy = @max(maxy, p.y + effHh(p));
    }
    const binw = (maxx - minx) / @as(f64, CONGEST_BINS);
    const binh = (maxy - miny) / @as(f64, CONGEST_BINS);
    if (binw <= 1e-6 or binh <= 1e-6) return 0;
    const bin_area = binw * binh;

    var dens = [_]f64{0} ** (CONGEST_BINS * CONGEST_BINS);
    for (nets) |net| {
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
        const nw = nmaxx - nminx;
        const nh = nmaxy - nminy;
        // Effective footprint for spreading: a trace has a finite width, so floor
        // each axis to one wire pitch. This keeps `na` non-degenerate AND lets a
        // perfectly horizontal/vertical net still deposit density over its corridor.
        const ex0 = nminx - @max(0.0, CONGEST_PITCH_MM - nw) / 2;
        const ex1 = nmaxx + @max(0.0, CONGEST_PITCH_MM - nw) / 2;
        const ey0 = nminy - @max(0.0, CONGEST_PITCH_MM - nh) / 2;
        const ey1 = nmaxy + @max(0.0, CONGEST_PITCH_MM - nh) / 2;
        const na = (ex1 - ex0) * (ey1 - ey0); // = max(nw,pitch)·max(nh,pitch)
        // RUDY per-net density: wire area (HPWL × pitch) over the bounding-box area.
        const dn = ((nw + nh) * CONGEST_PITCH_MM) / na;
        const bx0 = binIndex((ex0 - minx) / binw);
        const bx1 = binIndex((ex1 - minx) / binw);
        const by0 = binIndex((ey0 - miny) / binh);
        const by1 = binIndex((ey1 - miny) / binh);
        var by = by0;
        while (by <= by1) : (by += 1) {
            var bx = bx0;
            while (bx <= bx1) : (bx += 1) {
                // Fraction of this bin the net's effective footprint overlaps.
                const cx0 = minx + @as(f64, @floatFromInt(bx)) * binw;
                const cy0 = miny + @as(f64, @floatFromInt(by)) * binh;
                const ow = @max(0.0, @min(ex1, cx0 + binw) - @max(ex0, cx0));
                const oh = @max(0.0, @min(ey1, cy0 + binh) - @max(ey0, cy0));
                dens[by * CONGEST_BINS + bx] += dn * (ow * oh) / bin_area;
            }
        }
    }
    var pen: f64 = 0;
    for (dens) |d| {
        const over = d - CONGEST_CAP;
        if (over > 0) pen += over * over;
    }
    return pen;
}

/// Clamp a fractional bin coordinate to a valid `[0, CONGEST_BINS-1]` index.
fn binIndex(f: f64) usize {
    if (f <= 0) return 0;
    const i: usize = @intFromFloat(@floor(f));
    return @min(i, CONGEST_BINS - 1);
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
) std.mem.Allocator.Error!Built {
    const gnd = try groundPads(arena, nets, parts, idx_of, roles);
    var springs: std.ArrayListUnmanaged(Spring) = .empty;
    var loops: std.ArrayListUnmanaged(Loop) = .empty;

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
            try hugToHub(arena, &springs, &loops, eps.items, hub_idx.?, gnd, roles, explicit_pin, @intCast(net_i));
        } else {
            try weakCluster(arena, &springs, eps.items);
        }
    }
    return .{ .springs = try springs.toOwnedSlice(arena), .loops = try loops.toOwnedSlice(arena) };
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
fn classify(parts: []Part, loops: []Loop, nets: []const FlatNet, cap_w_max: f64, priority: []const u32) void {
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
            if (ni < nets.len and isInputRailName(shortName(nets[ni].name))) w *= INPUT_LOOP_BOOST;
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
    eps: []const Endpoint,
    hub: usize,
    gnd: []const []const PadRect,
    roles: []const pin_roles.PartRoles,
    explicit_pin: []const []const u8,
    net_i: i32,
) std.mem.Allocator.Error!void {
    // The hub's pads on this (power) net seed the loop target / hug centroid.
    // Config straps tied to the rail (a declared `input`/`output`/`io` pin such
    // as EN/UV or PGFB) are dropped so the bypass cap hugs the real supply pins,
    // not a control pin that merely shares the net. If every hub pad is a strap
    // we keep them all, so a rail is never left without a target.
    var hub_all: std.ArrayListUnmanaged(PadRect) = .empty;
    var hub_real: std.ArrayListUnmanaged(PadRect) = .empty;
    // Lowest-numbered real supply pad — the default pinned target for a cap that
    // doesn't name an explicit pin (`(near <pin> …)`). Fixing it removes the
    // per-eval argmin flip that made the score jump on a small nudge.
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
    if (hub_all.items.len == 0) return;
    const hub_pwr_s = if (hub_real.items.len > 0) try hub_real.toOwnedSlice(arena) else try hub_all.toOwnedSlice(arena);
    // Centroid of the chosen pads — the non-decoupling spring target.
    var hx: f64 = 0;
    var hy: f64 = 0;
    for (hub_pwr_s) |p| {
        hx += p.x;
        hy += p.y;
    }
    const hn: f64 = @floatFromInt(hub_pwr_s.len);
    const ht = Pt{ .x = hx / hn, .y = hy / hn };
    // Default pinned target: the lowest-numbered real supply pad, or the first
    // hub pad when every pad was a strap (kept above so the rail isn't dropped).
    const default_pin_rect = def_rect orelse hub_pwr_s[0];

    for (eps) |e| {
        if (e.idx == hub or e.is_hub) continue;
        const decouple = gnd[e.idx].len > 0 and gnd[hub].len > 0;
        if (decouple) {
            // Pin the power leg to one hub pad — the cap's explicitly-named pin
            // (`(near <pin> …)`) if it's on this net, else the lowest-numbered
            // supply pad. Fixing the target removes the per-eval argmin flip.
            const pin_rect = findHubPin(eps, hub, explicit_pin[e.idx]) orelse default_pin_rect;
            // The ground return targets the hub GND pad nearest that power pin —
            // also fixed (no flip), so the loop is a coherent local pin pair.
            const gnd_rect = nearestPad(gnd[hub], pin_rect);
            try loops.append(arena, .{
                .cap = e.idx,
                .hub = hub,
                .cap_pwr = .{ .x = e.px, .y = e.py, .w = e.pw, .h = e.ph },
                .cap_gnd = gnd[e.idx][0],
                .hub_pwr = hub_pwr_s,
                .hub_pwr_pin = pin_rect,
                .hub_gnd = gnd[hub],
                .hub_gnd_pin = gnd_rect,
                .pwr_net = net_i,
            });
        } else {
            // Non-decoupling single-hub passive: hug the hub's pad centroid.
            try springs.append(arena, .{ .a = e.idx, .b = hub, .ax = e.px, .ay = e.py, .bx = ht.x, .by = ht.y, .k = K_PROX, .kind = .proximity });
        }
    }
}

/// Weak centre-to-centre pull among a net's endpoints (no single hub to hug).
fn weakCluster(
    arena: std.mem.Allocator,
    springs: *std.ArrayListUnmanaged(Spring),
    eps: []const Endpoint,
) std.mem.Allocator.Error!void {
    const r = eps[0];
    for (eps[1..]) |e| {
        if (e.idx == r.idx) continue;
        try springs.append(arena, .{ .a = e.idx, .b = r.idx, .ax = 0, .ay = 0, .bx = 0, .by = 0, .k = K_SIG, .kind = .signal });
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
    if (p.keep.hw < 0) return .{ .cxo = 0, .cyo = 0, .hw = @max(0.0, (if (q) p.hh else p.hw) - s) + r, .hh = @max(0.0, (if (q) p.hw else p.hh) - s) + r };
    const off = rotateLocal(p.keep.ox, p.keep.oy, p.rot);
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

/// Max hash buckets (must be a power of two and >= bucketCount(maxParts)).
const GRID_MAX_BUCKETS: usize = 8192;

/// Bucket count for `n` parts: next power of two of 2n, clamped to
/// [16, GRID_MAX_BUCKETS]. Keeps load factor < 1 while keeping the per-iter
/// clear cheap on small boards.
fn bucketCount(n: usize) u64 {
    var b: u64 = 16;
    const want = 2 * n;
    while (b < want and b < GRID_MAX_BUCKETS) b <<= 1;
    return b;
}

/// Hash a signed cell coordinate pair into a bucket index space. Mixing keeps
/// adjacent cells from clustering in the same bucket.
inline fn cellHash(cx: i64, cy: i64) u64 {
    const ux: u64 = @bitCast(cx);
    const uy: u64 = @bitCast(cy);
    var h: u64 = ux *% 0x9E3779B97F4A7C15;
    h ^= uy *% 0xC2B2AE3D27D4EB4F;
    h ^= h >> 29;
    h *%= 0xBF58476D1CE4E5B9;
    h ^= h >> 32;
    return h;
}

/// Uniform spatial hash over every part's collision keepout, used to make the
/// `overlapsAny` boolean query ~O(1) instead of O(n). `compactToContact` is the
/// dominant cost on large single-start boards (an O(n⁴)-ish blob-dock that calls
/// `overlapsAny` for every trial dock of every floating part); the parts are
/// static across one docking pass, so the grid is built once per pass and reused
/// for all queries in it.
///
/// `overlapsAny` returns "does *any* other courtyard overlap" — a pure boolean
/// OR, so it is order-independent: a grid that misses no truly-overlapping part
/// returns the identical boolean. (False positives are impossible — the exact
/// overlap test is still applied — and the cell size guarantees no false
/// negatives, so this is bit-for-bit equivalent to the dense scan.) Because the
/// answer is order-free we needn't sort or de-dup candidates: scanning a part
/// twice (via a hash collision) or in any order yields the same boolean.
const CompactGrid = struct {
    n: usize,
    box: [maxParts]KeepBox, // rotation-aware keepout (position-independent offsets)
    wcx: [maxParts]f64, // world keepout centre x (= part.x + box.cxo)
    wcy: [maxParts]f64,
    minx: f64,
    miny: f64,
    inv_cell: f64,
    mask: u64,
    bstart: [GRID_MAX_BUCKETS + 1]u32,
    items: [maxParts]u32,

    /// (Re)build from the current part positions. Cheap O(n) — call once per
    /// docking pass (positions are static within a pass).
    fn build(g: *CompactGrid, parts: []const Part) void {
        const n = parts.len;
        g.n = n;
        if (n == 0) return;
        var max_half: f64 = 0;
        var minx: f64 = std.math.floatMax(f64);
        var miny: f64 = std.math.floatMax(f64);
        var k: usize = 0;
        while (k < n) : (k += 1) {
            const b = keepBoxOf(parts[k]);
            g.box[k] = b;
            const cx = parts[k].x + b.cxo;
            const cy = parts[k].y + b.cyo;
            g.wcx[k] = cx;
            g.wcy[k] = cy;
            if (b.hw > max_half) max_half = b.hw;
            if (b.hh > max_half) max_half = b.hh;
            if (cx < minx) minx = cx;
            if (cy < miny) miny = cy;
        }
        // Overlap needs |Δcx| < hw_i+hw_j ≤ 2·max_half on each axis, so a cell
        // of 2·max_half puts any overlapping pair within one cell (3×3 cover).
        const cell = 2 * max_half + 1e-9;
        g.inv_cell = 1.0 / cell;
        g.minx = minx;
        g.miny = miny;

        const nbuckets = bucketCount(n);
        g.mask = nbuckets - 1;
        var b: usize = 0;
        while (b <= nbuckets) : (b += 1) g.bstart[b] = 0;
        // Histogram cells into bucket counts.
        var pbucket: [maxParts]u32 = undefined;
        k = 0;
        while (k < n) : (k += 1) {
            const key: u32 = @intCast(g.cellKey(g.wcx[k], g.wcy[k]));
            pbucket[k] = key;
            g.bstart[key + 1] += 1;
        }
        b = 0;
        while (b < nbuckets) : (b += 1) g.bstart[b + 1] += g.bstart[b];
        var cursor: [GRID_MAX_BUCKETS]u32 = undefined;
        b = 0;
        while (b < nbuckets) : (b += 1) cursor[b] = g.bstart[b];
        k = 0;
        while (k < n) : (k += 1) {
            const key = pbucket[k];
            g.items[cursor[key]] = @intCast(k);
            cursor[key] += 1;
        }
    }

    inline fn cellOf(g: *const CompactGrid, wx: f64, wy: f64) struct { cx: i64, cy: i64 } {
        return .{
            .cx = @intFromFloat(@floor((wx - g.minx) * g.inv_cell)),
            .cy = @intFromFloat(@floor((wy - g.miny) * g.inv_cell)),
        };
    }

    inline fn cellKey(g: *const CompactGrid, wx: f64, wy: f64) u64 {
        const c = g.cellOf(wx, wy);
        return cellHash(c.cx, c.cy) & g.mask;
    }

    /// True iff any part other than `self` overlaps a keepout box `tbox` centred
    /// at world `(twcx,twcy)`. Mirrors `overlapsAny`'s exact float test so the
    /// boolean matches bit-for-bit.
    fn overlaps(g: *const CompactGrid, self: usize, tbox: KeepBox, twcx: f64, twcy: f64) bool {
        const c = g.cellOf(twcx, twcy);
        var dgy: i64 = -1;
        while (dgy <= 1) : (dgy += 1) {
            var dgx: i64 = -1;
            while (dgx <= 1) : (dgx += 1) {
                const key: u32 = @intCast(cellHash(c.cx + dgx, c.cy + dgy) & g.mask);
                const slice = g.items[g.bstart[key]..g.bstart[key + 1]];
                for (slice) |o| {
                    if (o == self) continue;
                    const ox = (tbox.hw + g.box[o].hw) - @abs(twcx - g.wcx[o]);
                    const oy = (tbox.hh + g.box[o].hh) - @abs(twcy - g.wcy[o]);
                    if (ox > 1e-9 and oy > 1e-9) return true;
                }
            }
        }
        return false;
    }
};

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
        links[i] = .{
            .a = s.a,
            .b = s.b,
            .ax = s.ax,
            .ay = s.ay,
            .bx = s.bx,
            .by = s.by,
            .kind = s.kind,
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

fn isGroundName(name: []const u8) bool {
    const grounds = [_][]const u8{ "GND", "GNDA", "AGND", "PGND", "DGND", "GNDD", "VSS", "VSSA" };
    for (grounds) |g| {
        if (std.mem.eql(u8, name, g)) return true;
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

test "compactToContact docks floating parts so every courtyard abuts a neighbour" {
    // Hub U1 (anchor) with two caps each left a 0.2 mm snap-safety gap — C1 off
    // the right edge (2.0+0.4+0.2), C2 off the bottom. All extents are grid
    // multiples so docking lands exactly on the courtyard edge. Compaction must
    // close both gaps, leaving every part touching and nothing overlapping.
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2.0, .hh = 2.0, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &.{}, .fallback = false, .x = 2.6, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &.{}, .fallback = false, .x = 0, .y = 2.6 },
    };
    // Precondition: the passives start floating (0.2 mm gap to the hub).
    try testing.expect(!courtyardTouchesAny(&parts, 1));
    try testing.expect(!courtyardTouchesAny(&parts, 2));

    const prio = [_]u32{ 0, 0, 0 }; // unranked → cheapest-first docking
    compactToContact(&parts, &prio);

    for (0..parts.len) |i| try testing.expect(courtyardTouchesAny(&parts, i));
    try testing.expect(!anyOverlap(&parts));
    // The anchor hub did not move; the caps pulled in to its edges.
    try testing.expectEqual(@as(f64, 0), parts[0].x);
    try testing.expectEqual(@as(f64, 0), parts[0].y);
    try testing.expectApproxEqAbs(@as(f64, 2.4), parts[1].x, 1e-9); // 2.0 + 0.4, abutting
    try testing.expectApproxEqAbs(@as(f64, 2.4), parts[2].y, 1e-9);
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

// spec: placement/optimizer - pairs matched halves across an IN/OUT mirror
test "computeMirrorPairs pairs parts on mirrored IN/OUT nets" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    try testing.expectEqualStrings("RF_OUT", (try mirrorNetName(arena, "RF_IN")).?);
    try testing.expectEqualStrings("OUTPUT_BIAS", (try mirrorNetName(arena, "INPUT_BIAS")).?);
    try testing.expect((try mirrorNetName(arena, "GND")) == null);

    // C1 (RF_IN, RF_INPUT) mirrors C2 (RF_OUT, RF_OUTPUT); U1 is central.
    var parts = [_]Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.5, .pads = &.{}, .fallback = false },
        .{ .ref_des = "C2", .kind = .passive, .hw = 1, .hh = 0.5, .pads = &.{}, .fallback = false },
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false },
    };
    const n_rfin = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const n_rfout = [_]export_kicad.FlatPin{.{ .ref_des = "C2", .pin = "1" }};
    const n_in = [_]export_kicad.FlatPin{ .{ .ref_des = "C1", .pin = "2" }, .{ .ref_des = "U1", .pin = "1" } };
    const n_out = [_]export_kicad.FlatPin{ .{ .ref_des = "C2", .pin = "2" }, .{ .ref_des = "U1", .pin = "2" } };
    const nets = [_]FlatNet{
        .{ .name = "RF_IN", .pins = &n_rfin },
        .{ .name = "RF_OUT", .pins = &n_rfout },
        .{ .name = "RF_INPUT", .pins = &n_in },
        .{ .name = "RF_OUTPUT", .pins = &n_out },
    };
    var idx = std.StringHashMap(usize).init(arena);
    try idx.put("C1", 0);
    try idx.put("C2", 1);
    try idx.put("U1", 2);

    const partner = try computeMirrorPairs(arena, &parts, &nets, &idx);
    try testing.expectEqual(@as(?usize, 1), partner[0]); // C1 ↔ C2
    try testing.expectEqual(@as(?usize, 0), partner[1]);
    try testing.expectEqual(@as(?usize, null), partner[2]); // U1 central
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

    // binIndex clamps out-of-range fractions into [0, CONGEST_BINS-1].
    try testing.expectEqual(@as(usize, 0), binIndex(-1.5));
    try testing.expectEqual(CONGEST_BINS - 1, binIndex(999));
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
    const blk = try packOneBlock(arena, &ordered, &parts, .left, &.{}, 0.2);
    // A side (left) edge packs a vertical column: same x, strictly increasing y.
    try testing.expectApproxEqAbs(@as(f64, 0), blk.lx[0], 1e-9);
    try testing.expectApproxEqAbs(blk.lx[0], blk.lx[1], 1e-9);
    try testing.expectApproxEqAbs(blk.lx[1], blk.lx[2], 1e-9);
    try testing.expect(blk.ly[0] < blk.ly[1] and blk.ly[1] < blk.ly[2]);
    // Column half-height spans all three caps + the two gaps; half-width = one cap.
    try testing.expectApproxEqAbs(@as(f64, 0.6 * 3 + 0.2), blk.half_h, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), blk.half_w, 1e-9);
}
