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
const STARTS: usize = 48; // multi-start seeds; keep the lowest-scoring arrangement
const MULTISTART_MAX_PARTS: usize = 32; // above this, single start (bound O(n²·starts))
// Real routed-trace loop scoring maze-routes every decoupling loop — accurate
// but superlinear in board size (a 223-part board takes minutes). Above this
// part count the *displayed* score keeps the continuous fixed-pad surrogate the
// optimizer already minimised, so large boards still load in well under a second.
const ROUTED_SCORE_MAX_PARTS: usize = 48;
const POLISH_SWEEPS: usize = 4; // greedy per-part tightening sweeps
const POLISH_CELLS: i64 = 6; // half-window (grid cells) the polish search scans
// Routed-aware finishing polish (small boards only): a final local search that
// scores each candidate (position × rotation) with the *real* maze-routed loop
// length instead of the fixed-pad surrogate, so a cap settles at the rotation/
// offset that shortens the actual trace — the surrogate-driven `polish` optimises
// a straight-gap proxy and can pick a different rotation/side than the router.
const ROUTED_POLISH_SWEEPS: usize = 2;
const ROUTED_POLISH_CELLS: i64 = 3; // ±0.6 mm window — local tuck/flip, not a re-place
// Routed polish routes once per candidate cell, so its cost grows with
// caps × window × loops. Cap it well below `ROUTED_SCORE_MAX_PARTS` (which only
// gates a single end-of-solve route) so a mid-size module can't make an
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
// Weight on the compactness term (`compactnessArea`): the sub-module's courtyard
// bounding-box area (mm²) — replaces the old pairwise tidiness reward. At ~1.0 the
// area term sits at ~40% of the loop term on the small power/RF sub-blocks, enough
// to flip boundary caps inward (GND tucked alongside the IC) and shrink the
// envelope ~10-16% for ≲1% loop cost, without overriding the electrical loop.
// PROVISIONAL — the area term grows quadratically with board size, so sweep it per
// design (the "Area" tuning input regenerates with a custom weight).
const W_ALIGN: f64 = 1.0;
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

/// Runtime-tunable weights (the consts above are the defaults). Passed to
/// `solve` so the UI can adjust placement without a rebuild. Only the steering
/// weights are exposed; the structural tunables (iters, starts) stay fixed.
pub const Params = struct {
    loop_w: f64 = LOOP_W,
    w_align: f64 = W_ALIGN,
    w_congest: f64 = W_CONGEST,
    cap_w_max: f64 = CAP_W_MAX,
    grid_courtyards: bool = GRID_COURTYARDS,
};

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
    alignment: f64, // sub-module courtyard bounding-box area (mm²) — the compactness term (field name kept for wire-compat)
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

/// How `solve` treats an applied `cached` layout.
pub const SeedMode = enum {
    /// Apply `cached` verbatim when it covers every part (no optimization, fast);
    /// otherwise place from scratch. The normal load/regenerate path.
    place,
    /// Seed from `cached` and run only the local routed tuck (`routedPolish`) on
    /// it — improve an existing (e.g. hand) layout in place without re-placing.
    refine,
};

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
        if (parts.len >= 2 and parts.len <= ROUTED_POLISH_MAX_PARTS and built.loops.len > 0) {
            // Small board with decoupling loops: pick the global arrangement on the
            // real routed metric (rerank the top-K multi-start candidates), then the
            // local routed tuck. This is what closes the surrogate↔routed gap that a
            // single surrogate-selected arrangement + local polish leaves on the table.
            try rerankSolve(arena, parts, &prep.idx_of, nets, built, params, prep.priority);
        } else {
            optimize(parts, &prep.idx_of, nets, built, params);
            // Mirror matched halves (e.g. a symmetric amp's input/output sections)
            // when the design is genuinely symmetric; a no-op otherwise.
            try symmetrize(arena, parts, &prep.idx_of, nets, built, params);
            // Final pull-together: dock any part still held off by the snap-safety
            // gap so every courtyard abuts at least one neighbour (provably tight),
            // highest placement-order priority docking first.
            compactToContact(parts, prep.priority);
        }
        // Then tuck each *declared-priority* decoupling cap onto its IC pin: a
        // per-cap wide-window search neither the global optimizer's balanced
        // objective nor the polish's small window can do — so an author-ranked
        // bypass cap actually hugs its power pin. Each tuck is re-routed and
        // reverted if it would drop a net, so it never makes routing worse;
        // self-no-ops when nothing is ranked or there are no loops.
        tightenPriorityLoops(arena, parts, built.loops, nets, prep.priority);
    } else if (mode == .refine and parts.len >= 2 and parts.len <= ROUTED_POLISH_MAX_PARTS and built.loops.len > 0) {
        // Seeded from an existing layout: keep its global arrangement, just run the
        // local routed tuck on it (the same monotonic, safety-netted pass the auto
        // solve finishes with), then the same priority-cap tuck. Lets a good hand
        // layout be improved without losing it.
        routedPolish(arena, parts, &prep.idx_of, nets, built.loops, params);
        tightenPriorityLoops(arena, parts, built.loops, nets, prep.priority);
    }

    // Headline score's loop length: the *real* routed-trace sum on interactive
    // boards, the fixed-pad surrogate above ROUTED_SCORE_MAX_PARTS (the router is
    // too slow on big boards to run on every load). `scoreLayout` already left
    // the surrogate in `score.loop_mm`; the router overrides it when affordable.
    var score = scoreLayout(parts, &prep.idx_of, nets, built.loops);
    const lsum = if (parts.len <= ROUTED_SCORE_MAX_PARTS) blk: {
        const routed = routedLoops(arena, parts, &prep.idx_of, nets, built.loops);
        score.loop_mm = routed.raw_mm;
        break :blk routed;
    } else surrogateLoops(parts, built.loops);
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
    var score = scoreLayout(prep.parts, &prep.idx_of, prep.nets, prep.built.loops);
    const lsum = if (prep.parts.len <= ROUTED_SCORE_MAX_PARTS) blk: {
        const routed = routedLoops(arena, prep.parts, &prep.idx_of, prep.nets, prep.built.loops);
        score.loop_mm = routed.raw_mm;
        break :blk routed;
    } else surrogateLoops(prep.parts, prep.built.loops);
    return breakdownWith(prep.parts, &prep.idx_of, prep.nets, params, score, lsum);
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
};

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
        const g = geometry.load(arena, project_dir, inst.footprint, hint);
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
    return .{ .parts = parts, .idx_of = idx_of, .instances = instances, .nets = nets, .built = built, .priority = priority };
}

/// Decompose the objective for already-placed parts, surfaced term-by-term for
/// the score export. `lsum` is supplied by the caller — the real routed-trace
/// sums on the score path, the surrogate above ROUTED_SCORE_MAX_PARTS — and the
/// objective is rebuilt from its inductance term, so the headline matches.
fn breakdownWith(parts: []const Part, idx_of: *std.StringHashMap(usize), nets: []const FlatNet, params: Params, score: Score, lsum: LoopSums) Breakdown {
    const al = compactnessArea(parts);
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
        .congestion = cong,
        .objective = score.hpwl_mm + params.loop_w * lsum.weighted_nh +
            params.w_align * al + params.w_congest * cong,
    };
}

/// Real routed-trace loop sums (raw + value-weighted) via the maze router — the
/// **score path only**, never the inner loop. Builds one grid over the placement,
/// then routes each loop's power leg as actual copper (cap pad → its pinned hub
/// pin) detouring foreign pads; the cap span + ground return (`loopGroundSpan`)
/// add the rest of the physical loop. Falls back to the analytic surrogate when a
/// leg is unroutable or the board is too large to grid, so a score is always produced.
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
    // rerankSolve only runs on small boards (≤ ROUTED_POLISH_MAX_PARTS ≤
    // MULTISTART_MAX_PARTS), so the multi-start + rotation refine always apply.
    const starts: usize = RERANK_STARTS;
    const rounds: usize = ROT_ROUNDS;
    const k = std.math.clamp(RERANK_BUDGET / parts.len, 2, RERANK_K);

    // Keep the K lowest-surrogate relaxed arrangements (poses flattened K×n).
    var cand = try arena.alloc(Pose, k * parts.len);
    const cand_cost = try arena.alloc(f64, k);
    for (cand_cost) |*c| c.* = std.math.inf(f64);
    var s: usize = 0;
    while (s < starts) : (s += 1) {
        runStart(parts, idx_of, nets, built, s, rounds, params);
        const cost = objectiveCost(parts, idx_of, nets, built.loops, params);
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
    const rounds: usize = if (small) ROT_ROUNDS else 0;
    var best: [maxParts]Pose = undefined;
    var best_cost: f64 = std.math.inf(f64);
    var s: usize = 0;
    while (s < starts) : (s += 1) {
        runStart(parts, idx_of, nets, built, s, rounds, params);
        const cost = objectiveCost(parts, idx_of, nets, built.loops, params);
        if (cost < best_cost) {
            best_cost = cost;
            for (parts, 0..) |p, i| best[i] = .{ .x = p.x, .y = p.y, .rot = p.rot };
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
            const d = bestDock(parts, i, settled) orelse continue;
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
    if (parts.len < 2 or parts.len > MULTISTART_MAX_PARTS) return;
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
fn bestDock(parts: []Part, i: usize, settled: []const bool) ?Dock {
    const ox = parts[i].x;
    const oy = parts[i].y;
    const phw = effHw(parts[i]);
    const phh = effHh(parts[i]);
    var best: ?Pt = null;
    var best_d2: f64 = std.math.inf(f64);
    for (parts, 0..) |o, j| {
        if (j == i or !settled[j]) continue;
        const sumw = phw + effHw(o);
        const sumh = phh + effHh(o);
        // Left / right of o: slide along x, keep y (clamped into the overlap band).
        const ylim = @max(0.0, sumh - COMPACT_MIN_OVERLAP);
        const cy = std.math.clamp(oy, o.y - ylim, o.y + ylim);
        considerDock(parts, i, o.x + sumw, cy, ox, oy, &best, &best_d2);
        considerDock(parts, i, o.x - sumw, cy, ox, oy, &best, &best_d2);
        // Above / below o: slide along y, keep x (clamped into the overlap band).
        const xlim = @max(0.0, sumw - COMPACT_MIN_OVERLAP);
        const cx = std.math.clamp(ox, o.x - xlim, o.x + xlim);
        considerDock(parts, i, cx, o.y + sumh, ox, oy, &best, &best_d2);
        considerDock(parts, i, cx, o.y - sumh, ox, oy, &best, &best_d2);
    }
    if (best) |pt| return .{ .pt = pt, .d2 = best_d2 };
    return null;
}

/// Evaluate one candidate dock centre for part `i`: snap to grid, reject if its
/// keepout overlaps anything, else keep it when it is the closest valid dock so
/// far. Restores `i`'s position before returning (the caller commits the winner).
fn considerDock(parts: []Part, i: usize, cx: f64, cy: f64, ox: f64, oy: f64, best: *?Pt, best_d2: *f64) void {
    const sx = @round(cx / GRID_MM) * GRID_MM;
    const sy = @round(cy / GRID_MM) * GRID_MM;
    parts[i].x = sx;
    parts[i].y = sy;
    const bad = overlapsAny(parts, &parts[i]);
    parts[i].x = ox;
    parts[i].y = oy;
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
    if (parts.len < 2 or parts.len > MULTISTART_MAX_PARTS) return;
    var sweep: usize = 0;
    while (sweep < POLISH_SWEEPS) : (sweep += 1) {
        var improved = false;
        for (parts, 0..) |*p, i| {
            if (p.kind == .hub) continue;
            if (polishPart(parts, idx_of, nets, loops, i, params)) improved = true;
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
        var dy: i64 = -POLISH_CELLS;
        while (dy <= POLISH_CELLS) : (dy += 1) {
            var dx: i64 = -POLISH_CELLS;
            while (dx <= POLISH_CELLS) : (dx += 1) {
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
        params.w_align * compactnessArea(parts) + cong;
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

/// Detour cost added to a loop leg whose straight trace is blocked by a pad —
/// a crude stand-in for "you'd have to route around (or via past) this". Kept
/// in sync with the page (emitted as `blockPen`).
pub const BLOCK_PENALTY_MM: f64 = 5.0;

/// Chord length (mm a loop leg cuts through an obstacle pad) at which the block
/// penalty reaches its full `BLOCK_PENALTY_MM`. Ramping the penalty over this —
/// rather than a hard in/out toggle — keeps the loop term *continuous* as a cap
/// slides past a pad. A binary toggle put `5 mm × loop_w × weight` (up to ~45)
/// cliffs into the objective over a single 0.2 mm step, which read as erratic
/// scoring and trapped the placer; the ramp turns each cliff into a slope.
const BLOCK_RAMP_MM: f64 = 1.0;

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

/// Length of segment a→b that lies inside axis-aligned rect `r` (0 if it misses
/// or only grazes an edge). Liang–Barsky clip: the clipped parameter span
/// `t1 − t0` times the segment length. Drives the *continuous* block penalty —
/// the deeper a loop leg cuts a pad, the worse, with no in/out cliff.
fn segRectChord(a: Pt, b: Pt, r: Rect) f64 {
    var t0: f64 = 0;
    var t1: f64 = 1;
    const p = [_]f64{ a.x - b.x, b.x - a.x, a.y - b.y, b.y - a.y };
    const q = [_]f64{ a.x - r.x0, r.x1 - a.x, a.y - r.y0, r.y1 - a.y };
    for (0..4) |i| {
        if (p[i] == 0) {
            if (q[i] < 0) return 0;
        } else {
            const t = q[i] / p[i];
            if (p[i] < 0) {
                if (t > t1) return 0;
                if (t > t0) t0 = t;
            } else {
                if (t < t0) return 0;
                if (t < t1) t1 = t;
            }
        }
    }
    if (t1 <= t0) return 0;
    return (t1 - t0) * std.math.hypot(b.x - a.x, b.y - a.y);
}

fn rectsClose(a: Rect, b: Rect) bool {
    return @abs(a.x0 - b.x0) < 1e-6 and @abs(a.y0 - b.y0) < 1e-6 and
        @abs(a.x1 - b.x1) < 1e-6 and @abs(a.y1 - b.y1) < 1e-6;
}

/// Deepest cut (mm) the straight trace a→b makes through any pad other than the
/// cap's own (`cap_idx`) or the `target` it connects to — 0 when the leg is
/// cleanly routable. Obstacles are inset slightly so running along an edge is
/// free. Drives the continuous block penalty in `nearestReachable`.
fn legPenetration(parts: []const Part, cap_idx: usize, a: Pt, b: Pt, target: Rect) f64 {
    const eps = 0.02;
    var worst: f64 = 0;
    for (parts, 0..) |part, pi| {
        if (pi == cap_idx) continue;
        for (part.pads) |pad| {
            const r0 = worldRect(part, .{ .x = pad.x, .y = pad.y, .w = pad.w, .h = pad.h });
            if (rectsClose(r0, target)) continue;
            const r = Rect{ .x0 = r0.x0 + eps, .y0 = r0.y0 + eps, .x1 = r0.x1 - eps, .y1 = r0.y1 - eps };
            if (r.x1 <= r.x0 or r.y1 <= r.y0) continue;
            worst = @max(worst, segRectChord(a, b, r));
        }
    }
    return worst;
}

/// Surrogate power-leg cost to a loop's *fixed* (pinned) hub pad `target`: the
/// edge-to-edge gap plus the continuous block-penetration ramp. Unlike
/// `nearestReachable` there is no argmin over hub pads — the target never flips —
/// so the cost is continuous in the cap's position (no pin-flip cliffs). This is
/// the inner-loop stand-in for the real routed trace the score path measures.
fn fixedReachable(cr: Rect, parts: []const Part, cap_idx: usize, target: Rect) f64 {
    const np = nearestPoints(cr, target);
    const chord = legPenetration(parts, cap_idx, np.a, np.b, target);
    const pen = BLOCK_PENALTY_MM * @min(chord / BLOCK_RAMP_MM, 1.0);
    return rectGap(cr, target) + pen;
}

/// Order two pad numbers: numerically when both parse as integers (so "2" < "10"),
/// else lexicographically (BGA "A1"/"B2"). Picks the default pinned supply pad.
fn pinLess(a: []const u8, b: []const u8) bool {
    const ai: ?i64 = std.fmt.parseInt(i64, a, 10) catch null;
    const bi: ?i64 = std.fmt.parseInt(i64, b, 10) catch null;
    if (ai != null and bi != null) return ai.? < bi.?;
    return std.mem.lessThan(u8, a, b);
}

/// Nearest *routable* hub pad to cap rect `cr`: edge-to-edge gap plus a detour
/// penalty when the straight leg is blocked, so the optimizer prefers a pad it
/// can actually run a clean trace to (and the reported loop reflects reality).
///
/// `legBlocked` (a scan over every other pad) is the optimizer's hottest leaf,
/// so two *exact* prunes skip it for pads that cannot win — the result (min
/// cost + its rect, first-in-order on ties) is unchanged:
///   • a pad whose bare gap already ≥ the best cost so far can't improve it,
///     since the detour penalty only adds (`cost = gap + pen ≥ gap`);
///   • a pad whose gap exceeds `gmin + BLOCK_PENALTY` can't beat the closest
///     pad even if that one is blocked, so it's never the minimum.
/// On a big IC (a dozen-plus ground pads per leg) this drops the per-leg
/// `legBlocked` count from O(pads) to ~1–2.
fn nearestReachable(cr: Rect, parts: []const Part, cap_idx: usize, hub_idx: usize, hub_pads: []const PadRect) struct { rect: Rect, gap: f64 } {
    var gmin: f64 = std.math.inf(f64);
    for (hub_pads) |pr| gmin = @min(gmin, rectGap(cr, worldRect(parts[hub_idx], pr)));
    const gcut = gmin + BLOCK_PENALTY_MM;

    var best: f64 = std.math.inf(f64);
    var best_rect: Rect = cr;
    for (hub_pads) |pr| {
        const hr = worldRect(parts[hub_idx], pr);
        const gap = rectGap(cr, hr);
        if (gap >= best or gap > gcut) continue; // can't beat the current/closest best
        const np = nearestPoints(cr, hr);
        // Continuous detour cost: ramps with how deeply the leg cuts an
        // obstacle pad, reaching full BLOCK_PENALTY_MM at BLOCK_RAMP_MM chord.
        const chord = legPenetration(parts, cap_idx, np.a, np.b, hr);
        const pen = BLOCK_PENALTY_MM * @min(chord / BLOCK_RAMP_MM, 1.0);
        const cost = gap + pen;
        if (cost < best) {
            best = cost;
            best_rect = hr;
        }
    }
    return .{ .rect = best_rect, .gap = best };
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
    if (p.keep.hw < 0) return effHw(p);
    return if (isQuarter(p.rot)) p.keep.hh else p.keep.hw;
}
fn keepHh(p: Part) f64 {
    if (p.keep.hw < 0) return effHh(p);
    return if (isQuarter(p.rot)) p.keep.hw else p.keep.hh;
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
        params.w_align * compactnessArea(parts) + cong;
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
    return hpwl + params.loop_w * loop_weighted + params.w_align * compactnessArea(parts) + cong;
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
/// continuous fixed-pad surrogate (no argmin flip); the score path replaces this
/// with the real routed-trace inductance (see `routedLoops`). This is the loop
/// term the objective minimizes.
fn weightedLoop(parts: []const Part, loops: []const Loop) f64 {
    return surrogateLoops(parts, loops).weighted_nh;
}

/// One loop's surrogate power-leg cost: the fixed-pad gap (+ block ramp) from the
/// cap's power pad to its pinned hub pin. The rest of the loop (the cap's body
/// span + the ground return) is added by `loopGroundSpan`.
fn surrogatePwrLeg(parts: []const Part, lp: Loop) f64 {
    const cap = parts[lp.cap];
    return fixedReachable(worldRect(cap, lp.cap_pwr), parts, lp.cap, worldRect(parts[lp.hub], lp.hub_pwr_pin));
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
        if (cnt < 2) continue;
        // HPWL = RSMT for ≤3 pins (keep the fast path); RMST for the rest.
        if (cnt <= 3 or cnt > MAX_WIRE_PTS) {
            total += (maxx - minx) + (maxy - miny);
        } else {
            total += rmstLen(pts[0..cnt]);
        }
    }
    return total;
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
/// return); the score path overrides `loop_mm` with the real routed power-leg
/// sum (`routedLoops`).
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
    for (loops) |lp| {
        // Both legs pull toward their *pinned* hub pads (matching the score), so a
        // cap settles with each pad facing its assigned pin — power pad to the
        // supply pin, ground pad to the nearby ground pin — not the nearest of each.
        const pwr_pin = [_]PadRect{lp.hub_pwr_pin};
        const gnd_pin = [_]PadRect{lp.hub_gnd_pin};
        accumulateLeg(parts, lp.cap, lp.cap_pwr, lp.hub, &pwr_pin, ax, ay);
        accumulateLeg(parts, lp.cap, lp.cap_gnd, lp.hub, &gnd_pin, ax, ay);
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
    ax: []f64,
    ay: []f64,
) void {
    const cr = worldRect(parts[cap], cap_pad);
    const near = nearestHubPad(cr, parts[hub], hub_pads);
    if (near.gap < 1e-6) return; // touching → loop leg already minimal
    const np = nearestPoints(cr, near.rect);
    const dx = K_DECOUPLE * (np.b.x - np.a.x);
    const dy = K_DECOUPLE * (np.b.y - np.a.y);
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
    if (p.keep.hw < 0) return .{ .cxo = 0, .cyo = 0, .hw = if (q) p.hh else p.hw, .hh = if (q) p.hw else p.hh };
    const off = rotateLocal(p.keep.ox, p.keep.oy, p.rot);
    return .{ .cxo = off.x, .cyo = off.y, .hw = if (q) p.keep.hh else p.keep.hw, .hh = if (q) p.keep.hw else p.keep.hh };
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

/// Pinout lookup key for `lib/pinouts/<key>.sexp`: the explicit `pinout`, else
/// the `symbol`, else the component name (mirrors the ERC's resolution order).
fn pinoutKey(inst: export_kicad.FlatInstance) []const u8 {
    if (inst.pinout.len > 0) return inst.pinout;
    if (inst.symbol.len > 0) return inst.symbol;
    return inst.component;
}

/// Space-delimited control / feedback / sense pin tokens. A pin whose function
/// contains one of these ties to a rail for configuration rather than carrying
/// bulk current, so a bypass cap should not hug it. Matched pad-bounded (each
/// token framed by spaces) so "IN" never matches inside "INT"/"INH".
const AUX_TOKENS =
    " EN UV UVLO PG PGOOD PGFB FB ILIM SET SS COMP SYNC MODE ADJ TRIM BYP " ++
    "BYPASS NC REF SENSE CTRL CTL INH DLY RT FREQ FSW SLEEP FAULT RESET NRST INT ";

/// True when `tok` (already uppercased) names a control/feedback/sense function.
fn isAuxToken(tok: []const u8) bool {
    var needle: [32]u8 = undefined;
    if (tok.len + 2 > needle.len) return false;
    needle[0] = ' ';
    @memcpy(needle[1 .. 1 + tok.len], tok);
    needle[1 + tok.len] = ' ';
    return std.mem.indexOf(u8, AUX_TOKENS, needle[0 .. tok.len + 2]) != null;
}

/// Classify a pin's primary function name as an auxiliary rail tie. Tokenises on
/// non-letters (so "EN/UV" → EN, UV and "IN_1" → IN), flagging the pin if any
/// token is a known control/feedback function or ends in "FB" (PGFB, VFB, IFB).
/// True supply pins (IN, VIN, VDD, VCC, OUT, OUTS, …) classify as non-aux.
fn isAuxRailPin(primary: []const u8) bool {
    var buf: [24]u8 = undefined;
    var i: usize = 0;
    while (i < primary.len) {
        var n: usize = 0;
        while (i < primary.len and std.ascii.isAlphabetic(primary[i])) : (i += 1) {
            if (n < buf.len) {
                buf[n] = std.ascii.toUpper(primary[i]);
                n += 1;
            }
        }
        if (n == 0) {
            i += 1;
            continue;
        }
        const tok = buf[0..n];
        if (isAuxToken(tok)) return true;
        if (n >= 2 and std.mem.eql(u8, tok[n - 2 .. n], "FB")) return true;
    }
    return false;
}

/// Load `lib/pinouts/<key>.sexp` and return the set of footprint pad numbers
/// whose pin function is an auxiliary rail tie (see `isAuxRailPin`). Empty when
/// the file is missing or unparseable, so a part with no pinout keeps the prior
/// all-pads loop behaviour.
fn loadAuxPads(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    key: []const u8,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(void) {
    var set: std.StringHashMapUnmanaged(void) = .empty;
    if (key.len == 0) return set;
    const path = std.fmt.allocPrint(arena, "{s}/lib/pinouts/{s}.sexp", .{ project_dir, key }) catch return set;
    const content = infra_fs.cwd().readFileAlloc(arena, path, 256 * 1024) catch return set;
    const nodes = parser.parse(arena, content) catch return set;
    if (nodes.len == 0) return set;
    const top = nodes[0].asList() orelse return set;
    if (top.len < 2) return set;
    const head = top[0].asAtom() orelse return set;
    if (!std.mem.eql(u8, head, "pinout")) return set;
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        const ch = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, ch, "pin")) continue;
        // Pin id may be a bare int (`(pin 1 …)` on a QFN/DFN) or an atom/string
        // (`(pin H4 …)` BGA, `(pin PN1 …)` logical); `tokenText` renders all to
        // the decimal string `geometry.Pad.number` uses.
        const pin_id = cl[1].tokenText(arena) orelse continue;
        const primary = cl[2].asText() orelse continue;
        if (isAuxRailPin(primary)) try set.put(arena, pin_id, {});
    }
    return set;
}

/// A part is a hub unless its ref-des prefix is a passive (R/C/L/F/D),
/// mirroring the schematic hub/spoke split. Handles `sub/U1` ref-des.
fn isHub(ref: []const u8) bool {
    const s = shortName(ref);
    if (s.len == 0) return true;
    return switch (s[0]) {
        'R', 'C', 'L', 'F', 'D' => false,
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
