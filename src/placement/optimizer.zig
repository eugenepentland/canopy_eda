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
//! After a final grid-aware legalization, no two courtyards overlap. Large
//! whole-board layouts skip steps 1–3 (they blob together regardless) and take
//! a single grid-seeded relax. It is deterministic — seeds derive from the
//! start index, not an RNG — so a design always yields the same layout.
//! Coordinates are millimetres, y-down (KiCad convention).

const std = @import("std");
const env = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const netlist_mod = @import("../export_kicad_netlist.zig");
const geometry = @import("geometry.zig");
const pin_roles = @import("pin_roles.zig");

const DesignBlock = env.DesignBlock;
const FlatNet = export_kicad.FlatNet;

// ── Tunables ─────────────────────────────────────────────────────────────
const K_DECOUPLE: f64 = 0.95; // power/decoupling cap hug + ground-return (highest priority)
const K_PROX: f64 = 0.6; // single-hub signal passive hug (feedback divider, etc.)
const K_SIG: f64 = 0.12; // generic wirelength pull
const ITERS: usize = 600; // relaxation steps
const LEGALIZE_ITERS: usize = 2000; // overlap-removal-only steps
const MAX_DISP_MM: f64 = 0.6; // per-step displacement clamp
const HUB_MASS: f64 = 4.0; // hubs move less → act as anchors
const PASSIVE_MASS: f64 = 1.0;
const SEED_GAP_MM: f64 = 1.5; // extra gap between seed grid cells
const ROT_ROUNDS: usize = 4; // rotation-refine ↔ relax coordinate-descent rounds
const LOOP_W: f64 = 3.0; // weight on loop length in the objective
const K_COMPACT: f64 = 0.10; // pull toward the cluster centroid (keeps HPWL tight)
const STARTS: usize = 48; // multi-start seeds; keep the lowest-scoring arrangement
const MULTISTART_MAX_PARTS: usize = 32; // above this, single start (bound O(n²·starts))
const POLISH_SWEEPS: usize = 4; // greedy per-part tightening sweeps
const POLISH_CELLS: i64 = 12; // half-window (grid cells) the polish search scans
const W_ISOLATE: f64 = 1.5; // keep-away penalty: sensitive nets ✗ high-current/switch parts
const ISO_FALLOFF_MM: f64 = 4.0; // distance scale of the isolation penalty (falls to ~0 beyond)
const CAP_W_MAX: f64 = 3.0; // max value-priority boost for the smallest cap on a rail
const W_ALIGN: f64 = 0.5; // tidiness reward: nudge parts to share a row / column
const ALIGN_CLAMP_MM: f64 = 1.5; // only finish near-alignments within this offset (no long pulls)
const GRID_COURTYARDS = true; // round courtyard half-extents to GRID_MM so edges land on-grid

/// Runtime-tunable weights (the consts above are the defaults). Passed to
/// `solve` so the UI can adjust placement without a rebuild. Only the steering
/// weights are exposed; the structural tunables (iters, starts) stay fixed.
pub const Params = struct {
    loop_w: f64 = LOOP_W,
    w_isolate: f64 = W_ISOLATE,
    w_align: f64 = W_ALIGN,
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
/// (e.g. "100nF") used for value-ordered decoupling; `sensitive`/`aggressor`
/// flag the part for the keep-away rule (set during `solve`).
pub const Part = struct {
    ref_des: []const u8,
    kind: PartKind,
    hw: f64,
    hh: f64,
    pads: []const geometry.Pad,
    fallback: bool,
    value: []const u8 = "",
    sensitive: bool = false,
    aggressor: bool = false,
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
/// `hpwl_mm` is total half-perimeter wirelength over signal nets (lower =
/// shorter routing); `loop_mm` is the summed power+ground airwire length of
/// the `loop_caps` decoupling caps (lower = tighter hot loops).
pub const Score = struct {
    hpwl_mm: f64,
    loop_mm: f64,
    loop_caps: usize,
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
    score: Score,
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
    hub_pwr: []const PadRect,
    hub_gnd: []const PadRect,
    /// Value-priority weight (≥1): boosts the smaller of several caps sharing
    /// a rail toward the pin. 1 for a lone cap (no change). Set in `solve`.
    weight: f64 = 1,
};

/// `buildSprings` output: the force list plus the decoupling loops to score.
const Built = struct {
    springs: []Spring,
    loops: []Loop,
};

/// Build a placement for `block`. When `cached` covers every part, its poses
/// are applied directly (no optimization — fast); otherwise the optimizer runs
/// and `Placement.generated` is set so the caller can persist a fresh cache.
/// All output is allocated in `arena`.
pub fn solve(
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    cached: ?[]const RefPose,
    params: Params,
) std.mem.Allocator.Error!Placement {
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

    const built = try buildSprings(arena, nets, parts, &idx_of, roles);
    classify(parts, built.loops, params.cap_w_max);

    // Reserve a breakout corridor in front of every "unaccounted" pad (a net
    // touching only this part — a single-pin signal that leaves the board), so
    // the placer doesn't drop a neighbour over the escape route. This grows the
    // collision keepout only; the rendered courtyard is unchanged.
    const stubs = try buildEscapeStubs(arena, nets, parts, &idx_of);
    applyKeepout(parts, stubs);

    const generated = !applyCached(parts, cached);
    if (generated) {
        optimize(parts, &idx_of, nets, built, params);
        // Mirror matched halves (e.g. a symmetric amp's input/output sections)
        // when the design is genuinely symmetric; a no-op otherwise.
        try symmetrize(arena, parts, &idx_of, nets, built, params);
    }

    const score = scoreLayout(parts, &idx_of, nets, built.loops);
    return finalize(arena, parts, built.springs, built.loops, stubs, instances, nets, score, generated);
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

/// Run the placer: multi-start seeds → keep the lowest-scoring arrangement →
/// polish, then legalize. Small boards (modules) get the full treatment;
/// large whole-board layouts take a single grid-seeded relax with no rotation
/// (they blob together regardless — per-module grouping is future work).
fn optimize(parts: []Part, idx_of: *std.StringHashMap(usize), nets: []const FlatNet, built: Built, params: Params) void {
    const small = parts.len <= MULTISTART_MAX_PARTS;
    const starts: usize = if (small) STARTS else 1;
    const rounds: usize = if (small) ROT_ROUNDS else 0;
    if (parts.len == 0 or parts.len > maxParts) return;
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

/// Round a length up to the next `GRID_MM` multiple.
fn ceilToGrid(v: f64) f64 {
    return @ceil(v / GRID_MM) * GRID_MM;
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
fn worldPt(p: Part, lx: f64, ly: f64) Pt {
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
/// on a quarter turn; right-angle rotation keeps it axis-aligned).
fn worldRect(p: Part, pr: PadRect) Rect {
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

/// Does segment a→b pass through axis-aligned rect `r`? Liang–Barsky clip;
/// true only for a positive-length crossing of the interior (grazing an edge
/// doesn't count — callers also inset obstacles to be safe).
fn segIntersectsRect(a: Pt, b: Pt, r: Rect) bool {
    var t0: f64 = 0;
    var t1: f64 = 1;
    const p = [_]f64{ a.x - b.x, b.x - a.x, a.y - b.y, b.y - a.y };
    const q = [_]f64{ a.x - r.x0, r.x1 - a.x, a.y - r.y0, r.y1 - a.y };
    for (0..4) |i| {
        if (p[i] == 0) {
            if (q[i] < 0) return false;
        } else {
            const t = q[i] / p[i];
            if (p[i] < 0) {
                if (t > t1) return false;
                if (t > t0) t0 = t;
            } else {
                if (t < t0) return false;
                if (t < t1) t1 = t;
            }
        }
    }
    return t0 < t1;
}

fn rectsClose(a: Rect, b: Rect) bool {
    return @abs(a.x0 - b.x0) < 1e-6 and @abs(a.y0 - b.y0) < 1e-6 and
        @abs(a.x1 - b.x1) < 1e-6 and @abs(a.y1 - b.y1) < 1e-6;
}

/// True if a straight trace from `a` to `b` crosses any pad other than the
/// cap's own pads (`cap_idx`) and the `target` pad it connects to — i.e. the
/// leg isn't routable as drawn (it cuts through the IC's pins / the EP / a
/// neighbour). Obstacles are inset slightly so running along an edge is fine.
fn legBlocked(parts: []const Part, cap_idx: usize, a: Pt, b: Pt, target: Rect) bool {
    const eps = 0.02;
    for (parts, 0..) |part, pi| {
        if (pi == cap_idx) continue;
        for (part.pads) |pad| {
            const r0 = worldRect(part, .{ .x = pad.x, .y = pad.y, .w = pad.w, .h = pad.h });
            if (rectsClose(r0, target)) continue;
            const r = Rect{ .x0 = r0.x0 + eps, .y0 = r0.y0 + eps, .x1 = r0.x1 - eps, .y1 = r0.y1 - eps };
            if (r.x1 <= r.x0 or r.y1 <= r.y0) continue;
            if (segIntersectsRect(a, b, r)) return true;
        }
    }
    return false;
}

/// Nearest *routable* hub pad to cap rect `cr`: edge-to-edge gap plus a detour
/// penalty when the straight leg is blocked, so the optimizer prefers a pad it
/// can actually run a clean trace to (and the reported loop reflects reality).
fn nearestReachable(cr: Rect, parts: []const Part, cap_idx: usize, hub_idx: usize, hub_pads: []const PadRect) struct { rect: Rect, gap: f64 } {
    var best: f64 = std.math.inf(f64);
    var best_rect: Rect = cr;
    for (hub_pads) |pr| {
        const hr = worldRect(parts[hub_idx], pr);
        const np = nearestPoints(cr, hr);
        const pen: f64 = if (legBlocked(parts, cap_idx, np.a, np.b, hr)) BLOCK_PENALTY_MM else 0;
        const cost = rectGap(cr, hr) + pen;
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
/// HPWL + `LOOP_W`·(value-weighted hot-loop length) + `W_ISOLATE`·(keep-away
/// penalty). The *displayed* score (`scoreLayout`) stays plain HPWL + loop —
/// these extra rules only steer placement, they don't change the headline
/// numbers.
fn objectiveCost(
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
    params: Params,
) f64 {
    const hpwl = scoreLayout(parts, idx_of, nets, loops).hpwl_mm;
    return hpwl + params.loop_w * weightedLoop(parts, loops) +
        params.w_isolate * isolationPenalty(parts) + params.w_align * alignmentPenalty(parts);
}

/// Tidiness reward (as a penalty to minimize): for each part pair, the smaller
/// of their x/y offsets, clamped to `ALIGN_CLAMP_MM`. Driving it down lines
/// parts up into shared rows/columns; the clamp means only near-aligned pairs
/// feel a pull, so distant parts aren't dragged together.
fn alignmentPenalty(parts: []const Part) f64 {
    var total: f64 = 0;
    for (parts, 0..) |a, i| {
        for (parts[i + 1 ..]) |b| {
            const off = @min(@abs(a.x - b.x), @abs(a.y - b.y));
            total += @min(off, ALIGN_CLAMP_MM);
        }
    }
    return total;
}

/// Hot-loop length with each cap's leg sum scaled by its value-priority
/// `weight` — so on a multi-cap rail the smaller cap is pulled closest.
fn weightedLoop(parts: []const Part, loops: []const Loop) f64 {
    var total: f64 = 0;
    for (loops) |lp| {
        const cap = parts[lp.cap];
        const legs = nearestReachable(worldRect(cap, lp.cap_pwr), parts, lp.cap, lp.hub, lp.hub_pwr).gap +
            nearestReachable(worldRect(cap, lp.cap_gnd), parts, lp.cap, lp.hub, lp.hub_gnd).gap;
        total += lp.weight * legs;
    }
    return total;
}

/// Keep-away penalty: high when a sensitive part (feedback/reference net) sits
/// near a high-current/switch part (decoupling cap or inductor), decaying to
/// ~0 past `ISO_FALLOFF_MM`. Pushes the reference network clear of the noisy
/// nodes (e.g. a buck's feedback divider away from the switch node/inductor).
fn isolationPenalty(parts: []const Part) f64 {
    var total: f64 = 0;
    for (parts, 0..) |s, i| {
        if (!s.sensitive) continue;
        for (parts, 0..) |a, j| {
            if (i == j or !a.aggressor) continue;
            const d = std.math.hypot(s.x - a.x, s.y - a.y);
            total += 1.0 / (1.0 + d / ISO_FALLOFF_MM);
        }
    }
    return total;
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
) std.mem.Allocator.Error!Built {
    const gnd = try groundPads(arena, nets, parts, idx_of, roles);
    var springs: std.ArrayListUnmanaged(Spring) = .empty;
    var loops: std.ArrayListUnmanaged(Loop) = .empty;

    for (nets) |net| {
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
            try hugToHub(arena, &springs, &loops, eps.items, hub_idx.?, gnd, roles);
        } else {
            try weakCluster(arena, &springs, eps.items);
        }
    }
    return .{ .springs = try springs.toOwnedSlice(arena), .loops = try loops.toOwnedSlice(arena) };
}

/// Tag parts for the new rules, and set each loop's value-priority weight:
///   • aggressor = a decoupling cap or an inductor (high-current / switch
///     node) — the keep-away rule pushes sensitive parts away from these,
///   • sensitive = any other signal passive (feedback / reference network),
///   • loop.weight = boost the smaller of several caps sharing a power rail
///     toward the pin (rails identified by a shared `hub_pwr` slice); a lone
///     cap keeps weight 1, so single-cap rails are unaffected.
fn classify(parts: []Part, loops: []Loop, cap_w_max: f64) void {
    for (loops) |lp| parts[lp.cap].aggressor = true;
    for (parts) |*p| {
        if (isInductor(p.ref_des)) p.aggressor = true;
        if (p.kind == .passive and !p.aggressor) p.sensitive = true;
    }
    for (loops) |*lp| {
        const v = capValueFarads(parts[lp.cap].value);
        if (v <= 0) continue;
        var vref = v;
        for (loops) |o| {
            if (o.hub_pwr.ptr == lp.hub_pwr.ptr) vref = @max(vref, capValueFarads(parts[o.cap].value));
        }
        lp.weight = std.math.clamp(@sqrt(vref / v), 1.0, cap_w_max);
    }
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
) std.mem.Allocator.Error!void {
    // The hub's pads on this (power) net. Config straps tied to the rail (a
    // declared `input`/`output`/`io` pin such as EN/UV or PGFB) are dropped so
    // the bypass cap hugs the real supply pins, not a control pin that merely
    // shares the net. If every hub pad is a strap we keep them all, so a rail is
    // never left without a target.
    var hub_all: std.ArrayListUnmanaged(PadRect) = .empty;
    var hub_real: std.ArrayListUnmanaged(PadRect) = .empty;
    for (eps) |e| {
        if (e.idx != hub) continue;
        const rect = PadRect{ .x = e.px, .y = e.py, .w = e.pw, .h = e.ph };
        try hub_all.append(arena, rect);
        if (roles[hub].classOf(e.pin) != .strap) try hub_real.append(arena, rect);
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

    for (eps) |e| {
        if (e.idx == hub or e.is_hub) continue;
        const decouple = gnd[e.idx].len > 0 and gnd[hub].len > 0;
        if (decouple) {
            try loops.append(arena, .{
                .cap = e.idx,
                .hub = hub,
                .cap_pwr = .{ .x = e.px, .y = e.py, .w = e.pw, .h = e.ph },
                .cap_gnd = gnd[e.idx][0],
                .hub_pwr = hub_pwr_s,
                .hub_gnd = gnd[hub],
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

/// HPWL over signal nets + total power/ground airwire length of the
/// decoupling loops, measured on the settled placement.
fn scoreLayout(
    parts: []const Part,
    idx_of: *std.StringHashMap(usize),
    nets: []const FlatNet,
    loops: []const Loop,
) Score {
    var hpwl: f64 = 0;
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
            minx = @min(minx, w.x);
            miny = @min(miny, w.y);
            maxx = @max(maxx, w.x);
            maxy = @max(maxy, w.y);
            cnt += 1;
        }
        if (cnt >= 2) hpwl += (maxx - minx) + (maxy - miny);
    }

    var loop_mm: f64 = 0;
    for (loops) |lp| {
        const cap = parts[lp.cap];
        loop_mm += nearestReachable(worldRect(cap, lp.cap_pwr), parts, lp.cap, lp.hub, lp.hub_pwr).gap;
        loop_mm += nearestReachable(worldRect(cap, lp.cap_gnd), parts, lp.cap, lp.hub, lp.hub_gnd).gap;
    }
    return .{ .hpwl_mm = hpwl, .loop_mm = loop_mm, .loop_caps = loops.len };
}

/// Spring relaxation: springs + edge-aware decoupling-loop pulls + courtyard
/// repulsion, with a cooling step.
fn relax(parts: []Part, springs: []const Spring, loops: []const Loop) void {
    const n = parts.len;
    if (n == 0) return;
    var it: usize = 0;
    while (it < ITERS) : (it += 1) {
        const cool = 1.0 - @as(f64, @floatFromInt(it)) / @as(f64, @floatFromInt(ITERS));
        const step = 0.1 + 0.7 * cool;

        if (n > maxParts) return; // safety: bounded accumulators
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
        _ = accumulateRepulsion(parts, &ax, &ay, 0);

        for (0..n) |i| {
            const mass = if (parts[i].kind == .hub) HUB_MASS else PASSIVE_MASS;
            parts[i].x += clampDisp(step * ax[i] / mass);
            parts[i].y += clampDisp(step * ay[i] / mass);
        }
    }
}

/// Pull each decoupling cap so its power and ground pads close on the nearest
/// hub power / ground pad (edge-to-edge). The force acts along the current
/// gap vector, so it vanishes once the pads touch — repulsion then sets the
/// final clearance. This replaces the old centroid power/ground springs.
fn accumulateLoops(parts: []const Part, loops: []const Loop, ax: []f64, ay: []f64) void {
    for (loops) |lp| {
        accumulateLeg(parts, lp.cap, lp.cap_pwr, lp.hub, lp.hub_pwr, ax, ay);
        accumulateLeg(parts, lp.cap, lp.cap_gnd, lp.hub, lp.hub_gnd, ax, ay);
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
    var it: usize = 0;
    while (it < LEGALIZE_ITERS) : (it += 1) {
        var ax: [maxParts]f64 = undefined;
        var ay: [maxParts]f64 = undefined;
        for (0..n) |i| {
            ax[i] = 0;
            ay[i] = 0;
        }
        const moved = accumulateRepulsion(parts, &ax, &ay, clearance);
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

/// Add separation forces for every overlapping courtyard pair (rotation-aware
/// extents, plus a `clearance` margin) along the axis of least penetration.
/// Returns true if any pair overlapped.
fn accumulateRepulsion(parts: []const Part, ax: []f64, ay: []f64, clearance: f64) bool {
    const n = parts.len;
    var any = false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j: usize = i + 1;
        while (j < n) : (j += 1) {
            const dx = keepCx(parts[i]) - keepCx(parts[j]);
            const dy = keepCy(parts[i]) - keepCy(parts[j]);
            const ox = (keepHw(parts[i]) + keepHw(parts[j]) + clearance) - @abs(dx);
            const oy = (keepHh(parts[i]) + keepHh(parts[j]) + clearance) - @abs(dy);
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
    score: Score,
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
        .score = score,
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
/// part the keep-away rule treats as an aggressor.
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
test "optimizeRotations flips a cap to face its hub power and ground pads" {
    // Hub U1 at origin: power pad on the left (-0.5,-1), ground pad on the
    // right (0.5,-1). Cap C1 just below at (0,-1.6) with its power pad on the
    // right (+0.5) and ground on the left (-0.5) — *crossed* at rot 0. A 180°
    // turn uncrosses them so each cap pad sits directly under its hub pad,
    // collapsing the edge-to-edge legs (≈1.27 mm → ≈0.4 mm).
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.2, .hh = 0.8, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.8, .hh = 0.4, .pads = &.{}, .fallback = false, .x = 0, .y = -1.6 },
    };
    const hub_pwr = [_]PadRect{.{ .x = -0.5, .y = -1, .w = 0.4, .h = 0.4 }};
    const hub_gnd = [_]PadRect{.{ .x = 0.5, .y = -1, .w = 0.4, .h = 0.4 }};
    const loops = [_]Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0.5, .y = 0, .w = 0.4, .h = 0.4 },
        .cap_gnd = .{ .x = -0.5, .y = 0, .w = 0.4, .h = 0.4 },
        .hub_pwr = &hub_pwr,
        .hub_gnd = &hub_gnd,
    }};

    var idx = std.StringHashMap(usize).init(testing.allocator);
    defer idx.deinit();
    try idx.put("U1", 0);
    try idx.put("C1", 1);

    const before = scoreLayout(&parts, &idx, &.{}, &loops).loop_mm;
    optimizeRotations(&parts, &idx, &.{}, &loops, .{});
    const after = scoreLayout(&parts, &idx, &.{}, &loops).loop_mm;
    try testing.expectEqual(@as(f64, 180), parts[1].rot); // uncrossed orientation
    try testing.expect(after < before - 0.3); // and it shortened the loop
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
