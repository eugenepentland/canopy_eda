//! Global topology planner — a per-wave, all-nets-at-once flow relaxation that
//! decides WHERE each net should run before the router draws any copper.
//!
//! The router routes nets ONE AT A TIME, so a board's global topology is an
//! accident of net order: whoever routes first takes the short path and the
//! rest detour around the copper it left. `escape_assign` fixes that for one
//! hub's escape corridor; this module is the whole-board version of the same
//! idea. Every net of a wave is relaxed SIMULTANEOUSLY on a coarse lattice, so
//! the corridors they settle into are the ones a set of mutually-aware nets
//! would pick — a net pushed out of a congested gap moves while it is still
//! free to move, not after the gap is already full of metal.
//!
//! The physics is Physarum conductance adaptation under congestion pricing:
//!
//!   1. Each net is one commodity — a unit injected at its first pad and
//!      extracted evenly across the others (star flow).
//!   2. Per frame, each net's potential field is relaxed with Gauss-Seidel on
//!      `∇·(De ∇p) = −b`, where the effective conductance
//!      `De = D / (1 + kappa·(cong + history_weight·hist))` prices the space
//!      other nets are already asking for.
//!   3. Flux `Q = De·∇p` feeds the Tero conductance update `D += rate·(|Q| − D)`
//!      — a corridor that carries flow gets wider, one that does not withers.
//!   4. `cong` is per-cell demand over free cross-section; `hist` accumulates
//!      `max(0, cong − 1)` as PathFinder's history term, so a cell that has been
//!      oversubscribed for many frames stays expensive even after this frame's
//!      demand drops. That is what stops two nets from trading one gap forever.
//!
//! The output is SOFT — `route_policy.GuideTrack` / `GuideVia`, the same
//! corridor hints `escape_assign` emits. A guide only multiplies the maze's
//! cost near it (`router.reference_corridor`); a corridor that turns out to be
//! unusable costs the net a detour, never the net. That is what makes the
//! coarse-lattice simplifications below safe: the planner can be wrong about
//! geometry without ever being wrong about legality.
//!
//! ## Guide contract (open question 1)
//!
//! `GuideTrack` is a single SEGMENT (`x1,y1 → x2,y2`) on one `layer`, keyed by
//! `net` (the flattened net index as `i32`). It is NOT a polyline, so a net's
//! backbone lowers to one `GuideTrack` PER SEGMENT — `router.setNetReferenceGuide`
//! rasterizes every track carrying that net into one shared corridor bitmask,
//! so the segments of a run are OR-ed together and their order is irrelevant.
//! `GuideTrack.width` is never read by the router (only the four coordinates,
//! `layer` and `net` are); it is set here to the net's track width for the
//! benefit of viewers. `GuideVia` is keyed the same way and only its `x`/`y`
//! are read — `dia`/`drill` are decorative. Both are stamped through
//! `markGuideCell`, which paints the 3×3 cell block around each sample, so a
//! guide is inherently a corridor rather than a centerline.
//!
//! ## Vias on a guided net (open question 2)
//!
//! YES — `reference_off_via_mult = 8.0` punishes vias on a net that has guide
//! TRACKS but zero guide VIAS, and the penalty is board-wide. In
//! `setNetReferenceGuide` a net arms `reference_guide_active` when it has
//! tracks OR vias, but `reference_via_mask` is allocated only when it has
//! VIAS. The relaxation step then prices every layer change as
//!
//!     if (reference_guide_active and from_layer != to_layer)
//!         eff *= if (on_reference_via) 0.1 else 8.0;
//!
//! and `on_reference_via` reads `false` for EVERY node when the mask is null.
//! So a tracks-only guide silently tells the maze "you may never change layer
//! without paying 8×" — a hard global constraint the planner never intended
//! from a coarse hint. This module therefore never emits a tracks-only guide
//! for a net that is allowed to via:
//!
//!   * backbone spans ≥2 layers → a `GuideVia` at every layer change (the via
//!     plan is real, and the 0.1× discount is exactly the wanted pull);
//!   * backbone is single-layer but ≥2 layers are ALLOWED → `GuideVia`s
//!     mirroring the corridor, so a via inside the planned corridor stays cheap
//!     and only a via that leaves the corridor pays. This keeps the on-guide /
//!     off-guide ratio identical for tracks and vias instead of the asymmetric
//!     "tracks hinted, vias forbidden" a tracks-only guide produces;
//!   * exactly one layer allowed → no vias, which is safe because
//!     `router.layerInMask` is a HARD gate (`relaxStep` returns before any via
//!     pricing), so no via step is ever evaluated and the 8× can never bite.
//!
//! ## What one wave costs
//!
//! Only the wave BEING PLANNED is a per-frame commodity. Waves already planned
//! are gone from the lattice — their backbones stamped out of `Board.free` — and
//! waves not planned yet enter as `Sim.bg`, a standing congestion field read off
//! once per wave after a short warm-up (`freezeBackground`). Planning stops
//! after the last wave allowed to emit, since nothing reads a later one's stamps
//! (`lastEmittingWave`).
//!
//! That is a correction, not a tuning choice. Relaxing every remaining net every
//! frame made the cost `Σ_waves (nets_left × frames × cells)`, so barracuda's 16
//! waves spent 87–98% of every frame on nets the wave could not emit and ONE
//! flagged wave cost exactly as much as sixteen — 561 s of wave time, against
//! 15 s for the same board now. The other half of that came from the lattice
//! itself: the edge loops recovered `(layer, y, x)` from a flat cell index on
//! every one of ~45 edge evaluations per cell, so `Board.nbrs` precomputes the
//! six neighbours once and the frame loop pays no integer division at all.
//!
//! ## Resolution is per wave, capacity is not (v2)
//!
//! v1 had ONE lattice at `max(2·g_route, 0.5)` — 0.93 mm on barracuda — and a
//! cell offered `pitch × (open area fraction)`. That conflated two different
//! quantities, and the measurement showed exactly what it cost: 16 of 93 nets
//! came back `no_path`, including three of the eight J1 control escapes, because
//! a 0.93 mm cell laid over fine-pitch pads is half copper and reads shut. The
//! planner was silent precisely where the board is hardest.
//!
//! The pitch is now a RESOLUTION knob and the reference channel a CAPACITY one:
//!
//!   * A cell offers the local APERTURE at its centre (`apertureAt`) — the
//!     narrower of the open runs through it along x and y — capped at the
//!     reference channel. That is a property of the geometry, not of the
//!     sampling, so halving the pitch resolves finer channels instead of
//!     halving what every cell can carry (which is what a naive per-wave pitch
//!     would have done: at 0.46 mm NO cell could hold a 0.6 mm net).
//!   * A wave is planned on the reference lattice; the nets it could not join
//!     are RETRIED on a finer one (`refinedPitch`, half the tightest pin pitch
//!     they terminate on, floored at 0.35 mm) with only those nets as
//!     commodities and the first pass's background field inherited. A wave whose
//!     nets all found corridors therefore costs exactly what it always did.
//!   * Consumed capacity is kept as WORLD geometry (`Stamp`) and replayed onto
//!     whatever lattice the next pass uses, so a refined wave still sees what
//!     earlier waves took.
//!
//! Measured on barracuda (16 waves, 93 nets, arm-2 all-waves flagged):
//! `no_path` 16 → 2, guides emitted 12 → 22, control-escape 3 no-path → 0 of 8,
//! planner wall 20.5 s → 27.1 s. Two of that census moved by resolution and the
//! rest by the two capacity corrections the finer lattice exposed — a stamp
//! consumes its own cross-section, not the guide corridor's much wider hint
//! radius, and only on the layers its backbone runs on.
//!
//! ## Deliberate simplifications (all safe because guides are soft)
//!
//!   * The confidence gate measures COMMITMENT (how much worse the best route
//!     that cannot use this corridor is), not "fraction of |Q| mass within
//!     corridor radius". See `confidenceOf` for the measurements: the mass
//!     ratio plateaus at 0.42 and cannot reach 0.6 at any frame budget under
//!     the plain Tero update, so the literal gate would refuse every net.
//!   * A cell must have room for a net's WHOLE cross-section to carry it
//!     (`cellUsable`), so a cell in a channel narrower than the trace is
//!     impassable rather than merely expensive; each net gets an escape halo one
//!     reference channel wide at its own pads so the rule cannot seal a net
//!     inside its own footprint.
//!   * Keepout is modelled as demand-width inflation (`width + 2·max(clearance,
//!     halo)`) rather than per-net zone admission. A net's halo is what other
//!     nets must leave it, which is exactly a cross-section cost; the router's
//!     own keepout gate stays authoritative for legality.
//!   * The board outline is taken from `board_rect`; a `board_poly` concavity
//!     is not carved out.
//!   * Cell occupancy is sub-sampled from pad BOUNDING BOXES, not pad polygons.
//!   * Memory is `O(commodities × layers × cells)` for the conductance state, so
//!     a refined pass carries only the nets it is retrying and is capped by
//!     `Params.refine.max_cell_commodities`.
//!
//! Pure: no disk, no globals, no clock, no RNG — one allocator in, deterministic
//! slices out. Symmetry between equal corridors is broken by a fixed per-net
//! epsilon bias on the initial conductance (`tie_break_eps`), never by noise, so
//! planning the same input twice is byte-identical.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const route_policy = @import("route_policy.zig");
const pad_shape = @import("pad_shape.zig");
const numeric = @import("../numeric.zig");

const Allocator = std.mem.Allocator;

/// Tuning for one planning run. The defaults are the v1 spec.
pub const Params = struct {
    /// Pins EVERY wave's lattice to this pitch (mm), suppressing per-wave
    /// refinement; null derives the reference channel `max(2·g_route, 0.5)` and
    /// lets a wave refine below it (see `refinedPitch`).
    pitch_mm: ?f64 = null,
    /// What one pass is allowed to spend, and the early-out that usually beats
    /// it. Every quantity here is a FRAME COUNT — no clock is ever read.
    budget: struct {
        frames: u32 = 200,
        gs_sweeps: u32 = 6,
        stability_checks: u32 = 3,
        /// Least per-net backbone overlap (Jaccard) that counts as "the topology
        /// held still" between two stability checks. 1.0 asks for the same cells.
        ///
        /// It is 1.0 because the measurement says a looser value would not be
        /// tolerating jitter, it would be calling two DIFFERENT corridors the
        /// same. On barracuda the early-out already fires on 13 of 16 waves; the
        /// three that spend the full budget are not wandering by a cell — their
        /// per-check overlap swings 0.08–1.00 (wave 4, eight nets) and 0.13–1.00
        /// (wave 1, two nets), i.e. the extraction keeps swapping whole
        /// corridors. No threshold short of "any two paths are the same" stops
        /// that, and one that did would freeze a net mid-swap.
        stability_overlap: f64 = 1.0,
    } = .{},
    /// How the relaxation behaves.
    flow: struct {
        /// Congestion price on effective conductance.
        kappa: f64 = 1.0,
        /// Tero conductance adaptation rate.
        rate: f64 = 0.15,
        /// Weight of the PathFinder history term beside live congestion.
        history_weight: f64 = 0.5,
        /// Demand weight of waves not yet planned.
        background_demand: f64 = 0.2,
        /// Frames of full-participation warm-up that produce the FROZEN
        /// background field (see `freezeBackground`). Small on purpose: it only
        /// has to say roughly where not-yet-planned work wants to go, and every
        /// frame of it is paid over every remaining net of the board.
        background_frames: u32 = 4,
        /// Base conductance of a via edge relative to an in-plane edge.
        via_conductance: f64 = 0.25,
    } = .{},
    /// How a settled topology becomes a guide.
    guide: struct {
        /// Corridor half-width as a multiple of the REFERENCE channel (not the
        /// wave's pitch): a corridor is a physical hint to the router, so
        /// resolving a wave more finely must not shrink the region it discounts.
        corridor_halfwidth_scale: f64 = 1.25,
        /// Least commitment (see `confidenceOf`) that still earns a guide.
        confidence_min: f64 = 0.6,
        /// Extraction price of a layer change, as a multiple of an in-plane
        /// edge — the planner's analogue of the router's `via_cost_mult`.
        ///
        /// Without it the extraction Dijkstra prices a vertical edge exactly
        /// like a lateral one (`pitch / (|Q| + eps)`), and the plain Tero update
        /// erases the `via_conductance` bias within a few frames by driving
        /// every conductance toward its own flux. A net whose flow spreads over
        /// two layers then flaps between them for free: measured on barracuda,
        /// `SPI_LMX_CSN` came out of a 102-cell backbone with FOURTEEN layer
        /// changes, and `V_3V3_LMX` with forty.
        via_cost_mult: f64 = 4,
    } = .{},
    /// How fine a wave's own lattice may become when the reference channel is
    /// too coarse to see the geometry its nets terminate on.
    refine: struct {
        /// Floor on any wave's pitch (mm). Below this the lattice stops buying
        /// resolution and starts buying cells: a net's cross-section is measured
        /// over the reference channel either way, so a pitch far under the pad
        /// gaps only re-measures the same aperture from more places.
        min_pitch_mm: f64 = 0.35,
        /// Fraction of a wave's tightest pin pitch its lattice resolves to.
        /// Half is the Nyquist reading of the rule that actually fails on a
        /// coarse lattice: a cell CENTRE has to be able to land inside the gap
        /// between two adjacent pads.
        pin_pitch_scale: f64 = 0.5,
        /// Fewest pads a part must carry for its pin pitch to count as escape
        /// geometry. A two-pad passive's own pads are the net's ENDS, not an
        /// aperture anything threads, and letting a 0402 set the pitch would
        /// refine every wave on the board.
        dense_part_pads: usize = 6,
        /// Ceiling on `cells × commodities` for one refined pass — the shape of
        /// the planner's whole per-wave state. A wave whose wanted pitch would
        /// exceed it is coarsened until it fits, so a resolution choice can
        /// never turn into gigabytes on a dense board.
        max_cell_commodities: f64 = 6.0e6,
    } = .{},
};

/// One net offered to the planner. `net` indexes `placement.nets`.
pub const NetInput = struct {
    net: usize,
    width: f64 = 0,
    clearance: f64 = 0,
    /// Signal-layer bitset; 0 = unrestricted (matches `route_policy.NetPolicy`).
    allowed_layers: u64 = 0,
    has_authored_guide: bool = false,
    is_diff_pair: bool = false,
    /// A copper plane or pour carries this net (`fab_readiness.netHasPlane`).
    /// It needs no corridor and consumes no channel: the plane is already
    /// everywhere. Planning one is pure cost — a rail on fifty pads is the most
    /// expensive commodity on the board and its answer is never used.
    is_plane_carried: bool = false,
};

/// True when this net consumes capacity but must never receive a guide: a
/// diff-pair member (its twin's coupling owns its shape) or a net whose author
/// already wrote the topology by hand.
fn demandOnly(n: NetInput) bool {
    return n.is_diff_pair or n.has_authored_guide;
}

/// One routing wave, planned as a unit. `emit` is false for a wave that is only
/// context — it is planned for the capacity its backbones consume, but its nets
/// may never receive a guide. Planning STOPS after the last emitting wave: a
/// wave later than that stamps capacity nothing reads and produces guides the
/// caller filters out, so relaxing it is pure cost (see `lastEmittingWave`).
pub const Wave = struct {
    nets: []const NetInput,
    emit: bool = true,
};

/// Why a net did or did not receive a guide.
pub const Reason = enum {
    emitted,
    /// Flow never concentrated: too little of the net's |Q| mass sits inside
    /// the corridor for the backbone to be worth asserting.
    low_confidence,
    /// No open corridor joins the net's terminals on its allowed layers.
    no_path,
    /// A diff-pair member or an authored-guide net (see `NetInput.demandOnly`).
    demand_only,
    /// Fewer than two distinct terminal cells — nothing to plan.
    no_terminals,
    /// A copper plane or pour carries this net, so it needs no corridor and is
    /// never relaxed (see `NetInput.is_plane_carried`).
    plane_carried,
};

/// Per-net outcome, always emitted (one per input net, in input order).
pub const NetDiag = struct {
    net: usize,
    wave: usize,
    emitted: bool,
    reason: Reason,
    /// Fraction of the net's total flux mass lying inside the corridor — the
    /// quantity the confidence gate tests.
    confidence: f64 = 0,
    /// Size of the extracted backbone; 0 when none was found.
    backbone_cells: usize = 0,
    /// Lattice pitch (mm) this net was actually planned on — the reference
    /// channel, or the finer pitch its wave refined to. Reading a `no_path` is
    /// otherwise guesswork: it says nothing about whether the lattice was too
    /// coarse to see the geometry or the geometry is genuinely sealed.
    pitch_mm: f64 = 0,
};

/// The planned topology: soft corridor guides plus one diagnosis per net.
pub const Plan = struct {
    tracks: []const route_policy.GuideTrack = &.{},
    vias: []const route_policy.GuideVia = &.{},
    diags: []const NetDiag = &.{},
    /// The reference channel (mm): the coarsest lattice pitch of the run, and
    /// the cross-section a wholly open cell offers at EVERY pitch. A wave that
    /// refined below it reports its own pitch on each of its `diags`.
    pitch_mm: f64 = 0,
};

/// Floor on the derived lattice pitch (mm) — a coarse planner gains nothing
/// from resolving finer than half a millimetre and pays cells for it.
const pitch_floor_mm: f64 = 0.5;
/// Mirrors `router.route_grid_margin_mm` so the planner spans the same board.
const grid_margin_mm: f64 = 1.0;
/// Mirrors the router's grid-pitch floor.
const route_pitch_floor_mm: f64 = 0.05;
/// Sub-samples each way from a cell centre when measuring the local aperture
/// (`apertureAt`). Five is not cosmetic: the measure gates passability, so its
/// quantisation is the resolution at which a narrow channel reads open or shut.
const aperture_steps: usize = 5;
/// Deterministic tie-break on initial conductance. Large enough to seed the
/// congestion feedback that separates two nets contending for equal corridors,
/// far too small to outweigh any real congestion term.
const tie_break_eps: f64 = 1e-3;
/// Frames between stability checks.
const stability_period: u32 = 10;
/// Guards the flux divisor in the extraction weight.
const flux_eps: f64 = 1e-9;
/// Douglas-Peucker tolerance as a fraction of the pitch.
const simplify_tol_scale: f64 = 0.5;

// ── Public entry ────────────────────────────────────────────────────────────

/// Plan every wave up to and including the last one allowed to emit. Wave `k`
/// sees waves `< k` as consumed capacity and waves `> k` as a frozen background
/// demand field, so it breaks ties in favour of leaving room for work that has
/// not been planned yet.
pub fn plan(
    allocator: Allocator,
    placement: *const optimizer.Placement,
    waves: []const Wave,
    params: Params,
) Allocator.Error!Plan {
    const last = lastEmittingWave(waves) orelse return .{};
    const slots = try buildSlots(allocator, waves);
    if (slots.len == 0) return .{};
    const chan = deriveChannel(placement, slots, params);
    var out = Output{};
    var run = Run{
        .slots = slots,
        .geom = try buildGeom(allocator, placement, slots, params.refine.dense_part_pads),
        .chan = chan,
        .layers = @max(1, @as(usize, placement.rules.signalLayerCount())),
        .params = params,
        .out = &out,
    };
    for (0..last + 1) |wi| try planWave(allocator, &run, wi);
    return .{
        .tracks = try out.tracks.toOwnedSlice(allocator),
        .vias = try out.vias.toOwnedSlice(allocator),
        .diags = try out.diags.toOwnedSlice(allocator),
        .pitch_mm = chan,
    };
}

/// Index of the last wave whose nets may receive guides, or null when none may.
/// Everything after it is planned for nobody: its capacity stamps are read only
/// by LATER waves and its guides are filtered out, so the relaxation frames it
/// would cost buy nothing. Measured on barracuda (16 waves, one flagged at index
/// 4): the eleven waves past it were 74% of the planner's wall clock.
fn lastEmittingWave(waves: []const Wave) ?usize {
    var last: ?usize = null;
    for (waves, 0..) |w, i| {
        if (w.emit) last = i;
    }
    return last;
}

const Output = struct {
    tracks: std.ArrayList(route_policy.GuideTrack) = .empty,
    vias: std.ArrayList(route_policy.GuideVia) = .empty,
    diags: std.ArrayList(NetDiag) = .empty,
};

/// Everything one whole planning run carries across its waves.
const Run = struct {
    slots: []const Slot,
    /// The pitch-independent board: pad obstacles, outline, terminal pads.
    geom: Geom,
    /// Reference channel width (mm) — the coarsest pitch of the run, and the
    /// cross-section a wholly open cell offers at ANY pitch.
    chan: f64,
    layers: usize,
    params: Params,
    out: *Output,
    /// One lattice per distinct pitch, built on demand and kept for the rest of
    /// the run. Pointers, so appending never moves a live `Board`.
    lattices: std.ArrayList(*Board) = .empty,
    /// Every planned backbone's WORLD footprint, in planning order. Capacity is
    /// replayed from these rather than carried in a lattice's cells, because the
    /// next wave may be planned on a lattice with different cells.
    stamps: std.ArrayList(Stamp) = .empty,
};

/// One planned backbone's claim on the board: the world points its cells sat on
/// and the cross-section it consumes there. The same geometry that lowers to
/// `GuideTrack`s, so a stamp and a guide can never describe different corridors.
const Stamp = struct { pts: []const StampPt, demand_mm: f64 };

/// One cell of a backbone, in world space and on ITS OWN layer. The layer is
/// load-bearing: v1 consumed every layer under a backbone, so one F.Cu escape
/// took the B.Cu capacity beneath it as well.
const StampPt = struct { x: f64, y: f64, layer: usize };

/// One net's place in the run: its input, its wave, and its cross-section cost.
const Slot = struct {
    in: NetInput,
    wave: usize,
    /// Cross-section this net consumes (mm): trace plus the space it owes
    /// its neighbours on each side.
    demand_mm: f64,
};

fn buildSlots(allocator: Allocator, waves: []const Wave) Allocator.Error![]Slot {
    var out: std.ArrayList(Slot) = .empty;
    for (waves, 0..) |w, wi| {
        for (w.nets) |n| {
            const gap = @max(n.clearance, 0);
            try out.append(allocator, .{
                .in = n,
                .wave = wi,
                .demand_mm = @max(n.width, route_pitch_floor_mm) + 2 * gap,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── Lattice ─────────────────────────────────────────────────────────────────

/// One wave's lattice: a grid per signal layer, plus the per-cell free
/// cross-section that capacity and congestion are measured against.
///
/// `p` is a RESOLUTION knob and `chan` a CAPACITY one, and keeping them apart is
/// what makes a per-wave pitch possible at all. The v1 lattice conflated them —
/// a cell offered `p × (open area fraction)`, so halving the pitch halved what
/// every cell could carry and sealed the board rather than resolving it. Here a
/// cell offers the local APERTURE (`apertureAt`) capped at the run's reference
/// channel, which is a property of the geometry rather than of the sampling: a
/// finer lattice measures the same channels from more places, and a cell centre
/// that lands inside a fine-pitch escape gap can finally see it.
const Board = struct {
    nx: usize,
    ny: usize,
    layers: usize,
    p: f64,
    /// The run's reference channel (mm) — see `Run.chan`.
    chan: f64,
    ox: f64,
    oy: f64,
    /// Usable cross-section per cell (mm). 0 = blocked. Waves consume it.
    free: []f64,
    /// `free` as carved, before any wave consumed anything. A lattice is reused
    /// by every wave that resolves to its pitch, so each pass restores this and
    /// replays `Run.stamps` rather than inheriting another wave's leftovers.
    free0: []const f64,
    /// This lattice's terminal cells per slot — a function of the pitch, so it
    /// is cached with the lattice rather than rebuilt per wave.
    terms: []const Terminals,
    /// Every cell's six lattice neighbours, `no_cell` at the boundary, indexed
    /// `[dir][0 = forward, 1 = backward]` — the order the edge loops must visit
    /// them in, since a Gauss-Seidel sum and a Dijkstra tie both depend on it.
    /// Built once for the whole run: the
    /// relaxation evaluates ~45 edges per cell per net per frame, and deriving
    /// (layer, y, x) back out of a flat index costs three integer divisions
    /// EVERY time — measured as the largest single term in the frame loop.
    nbrs: []const [3][2]u32,

    fn nodes(self: Board) usize {
        return self.nx * self.ny;
    }

    fn cells(self: Board) usize {
        return self.layers * self.nodes();
    }

    fn cell(self: Board, layer: usize, x: usize, y: usize) usize {
        return layer * self.nodes() + y * self.nx + x;
    }

    fn worldX(self: Board, x: usize) f64 {
        return self.ox + @as(f64, @floatFromInt(x)) * self.p;
    }

    fn worldY(self: Board, y: usize) f64 {
        return self.oy + @as(f64, @floatFromInt(y)) * self.p;
    }

    fn layerOf(self: Board, c: usize) usize {
        return c / self.nodes();
    }

    fn colOf(self: Board, c: usize) usize {
        return (c % self.nodes()) % self.nx;
    }

    fn rowOf(self: Board, c: usize) usize {
        return (c % self.nodes()) / self.nx;
    }

    fn nearest(self: Board, wx: f64, wy: f64) [2]usize {
        const fx = (wx - self.ox) / self.p;
        const fy = (wy - self.oy) / self.p;
        const cx = std.math.clamp(fx, 0, @as(f64, @floatFromInt(self.nx - 1)));
        const cy = std.math.clamp(fy, 0, @as(f64, @floatFromInt(self.ny - 1)));
        return .{ numeric.toCount(@round(cx)), numeric.toCount(@round(cy)) };
    }
};

/// The reference channel: the router's own pitch formula (`routeGridDims`),
/// reimplemented rather than called so this module keeps no `router.Ctx`
/// dependency — the widest participating class's track width plus the larger of
/// its clearance and the diff-pair gap, doubled and floored.
///
/// It is the CAPACITY unit for the whole run, not just wave zero's pitch: twice
/// the router's grid is exactly wide enough for the widest net's cross-section,
/// which is the property a refined wave has to keep. See `Board`.
fn deriveChannel(placement: *const optimizer.Placement, slots: []const Slot, params: Params) f64 {
    if (params.pitch_mm) |p| return @max(p, route_pitch_floor_mm);
    var width: f64 = 0.127;
    var gap: f64 = 0.127;
    for (slots) |s| {
        width = @max(width, s.in.width);
        gap = @max(gap, s.in.clearance);
        if (s.in.net < placement.rules.net.len) {
            const r = placement.rules.net[s.in.net];
            width = @max(width, r.width);
            gap = @max(gap, r.clearance);
            if (r.diff_gap > 0) gap = @max(gap, r.diff_gap);
        }
    }
    const g_route = @max(width + gap, route_pitch_floor_mm);
    return @max(2 * g_route, pitch_floor_mm);
}

/// The lattice for pitch `p`, built once and reused by every wave that resolves
/// to it, then restored to its pristine carve with `Run.stamps` replayed on top.
/// A pitch is matched EXACTLY (it is derived, never measured), so the run keeps
/// at most one lattice per distinct wave pitch.
fn latticeFor(allocator: Allocator, run: *Run, p: f64) Allocator.Error!*Board {
    const board = try findLattice(allocator, run, p);
    @memcpy(board.free, board.free0);
    const touched = try allocator.alloc(bool, board.cells());
    for (run.stamps.items) |st| applyStamp(board, st, touched);
    return board;
}

fn findLattice(allocator: Allocator, run: *Run, p: f64) Allocator.Error!*Board {
    for (run.lattices.items) |b| {
        if (b.p == p) return b;
    }
    const board = try allocator.create(Board);
    board.* = try buildBoard(allocator, run.*, p);
    try run.lattices.append(allocator, board);
    return board;
}

fn buildBoard(allocator: Allocator, run: Run, p: f64) Allocator.Error!Board {
    const g = run.geom;
    const span_x = g.maxx - g.minx + 2 * grid_margin_mm;
    const span_y = g.maxy - g.miny + 2 * grid_margin_mm;
    var board = Board{
        .nx = @max(2, numeric.toCount(@ceil(span_x / p) + 1)),
        .ny = @max(2, numeric.toCount(@ceil(span_y / p) + 1)),
        .layers = run.layers,
        .p = p,
        .chan = run.chan,
        .ox = g.minx - grid_margin_mm,
        .oy = g.miny - grid_margin_mm,
        .free = &.{},
        .free0 = &.{},
        .terms = &.{},
        .nbrs = &.{},
    };
    board.free = try allocator.alloc(f64, board.cells());
    board.nbrs = try buildNeighbors(allocator, board);
    board.free0 = try carveAperture(allocator, board, g);
    board.terms = try buildTerminals(allocator, board, run.slots, g);
    return board;
}

/// Sentinel for "no neighbour that way" in `Board.nbrs`. The lattice can never
/// hold this many cells (`MAX` cells would need terabytes of conductance state),
/// so it can never collide with a real index.
const no_cell: u32 = std.math.maxInt(u32);

fn buildNeighbors(allocator: Allocator, board: Board) Allocator.Error![]const [3][2]u32 {
    const out = try allocator.alloc([3][2]u32, board.cells());
    for (0..board.layers) |layer| {
        for (0..board.ny) |y| {
            for (0..board.nx) |x| out[board.cell(layer, x, y)] = neighborsAt(board, layer, x, y);
        }
    }
    return out;
}

fn neighborsAt(board: Board, layer: usize, x: usize, y: usize) [3][2]u32 {
    const n = board.nodes();
    const c = board.cell(layer, x, y);
    return .{
        .{ cellOrEdge(x + 1 < board.nx, c + 1, 0), cellOrEdge(x > 0, c, 1) },
        .{ cellOrEdge(y + 1 < board.ny, c + board.nx, 0), cellOrEdge(y > 0, c, board.nx) },
        .{ cellOrEdge(layer + 1 < board.layers, c + n, 0), cellOrEdge(layer > 0, c, n) },
    };
}

/// `base - back` as a cell index when `ok`, else the boundary sentinel.
fn cellOrEdge(ok: bool, base: usize, back: usize) u32 {
    if (!ok) return no_cell;
    return @intCast(base - back);
}

// ── Board geometry (pitch-independent) ──────────────────────────────────────

/// A pad reduced to what the lattice needs: its world box and which layers its
/// copper sits on.
const Obstacle = struct { x0: f64, y0: f64, x1: f64, y1: f64, layer: usize, thru: bool };

/// One pad a net terminates on, in WORLD space so it survives a pitch change.
const TermPad = struct {
    x: f64,
    y: f64,
    /// Copper layer the pad's own side sits on (0 top, 1 bottom).
    side: usize,
    thru: bool,
    /// Distance (mm) to the nearest other pad of the SAME part, when that part
    /// is dense enough to count as escape geometry — the pin pitch a wave reads
    /// its lattice resolution off. Infinite when the part is a passive.
    pin_pitch: f64,
};

/// Everything about the board that does not depend on the lattice pitch: the
/// pad obstacles (with a bucket index), the outline, and each slot's terminal
/// pads. Built once and shared by every wave's lattice.
const Geom = struct {
    obs: []const Obstacle,
    grid: ObsGrid,
    rect: ?optimizer.BoardRect,
    inset: f64,
    /// One list per slot, index-aligned with `Run.slots`.
    terms: []const []const TermPad,
    minx: f64,
    miny: f64,
    maxx: f64,
    maxy: f64,
};

fn buildGeom(
    allocator: Allocator,
    placement: *const optimizer.Placement,
    slots: []const Slot,
    dense_pads: usize,
) Allocator.Error!Geom {
    const obs = try collectObstacles(allocator, placement);
    var g = Geom{
        .obs = obs,
        .grid = try buildObsGrid(allocator, placement, obs),
        .rect = placement.board_rect,
        .inset = placement.rules.design.edgeClearance(),
        .terms = &.{},
        .minx = placement.minx,
        .miny = placement.miny,
        .maxx = placement.maxx,
        .maxy = placement.maxy,
    };
    g.terms = try buildTermPads(allocator, placement, slots, dense_pads);
    return g;
}

/// Mirrors `router.buildObstacles`: EVERY pad of every part is an obstacle,
/// on its part's side, or on every layer when through-hole.
fn collectObstacles(
    allocator: Allocator,
    placement: *const optimizer.Placement,
) Allocator.Error![]Obstacle {
    var out: std.ArrayList(Obstacle) = .empty;
    for (placement.parts) |part| {
        for (part.pads) |pad| {
            const sh = try pad_shape.worldShape(allocator, part, pad);
            try out.append(allocator, .{
                .x0 = sh.x0,
                .y0 = sh.y0,
                .x1 = sh.x1,
                .y1 = sh.y1,
                .layer = if (part.side == .bottom) 1 else 0,
                .thru = pad.thru,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

/// A uniform bucket index over the pad boxes, in CSR form. The aperture measure
/// takes ~21 point samples per cell and a refined lattice has tens of thousands
/// of cells, so testing every pad per sample (the v1 carve) is what a per-wave
/// lattice cannot afford — this turns it into a handful of boxes per sample.
const ObsGrid = struct {
    ox: f64,
    oy: f64,
    cell: f64,
    nx: usize,
    ny: usize,
    starts: []const u32,
    items: []const u32,

    /// The bucket holding a world point, or null when it lies outside the index
    /// (no pad can reach there, so nothing blocks it).
    fn bucketOf(self: ObsGrid, px: f64, py: f64) ?usize {
        const fx = @floor((px - self.ox) / self.cell);
        const fy = @floor((py - self.oy) / self.cell);
        if (fx < 0 or fy < 0) return null;
        const x = numeric.toCount(fx);
        const y = numeric.toCount(fy);
        if (x >= self.nx or y >= self.ny) return null;
        return y * self.nx + x;
    }
};

/// Bucket span an obstacle box covers, clamped to the index.
fn obsSpan(grid: ObsGrid, o: Obstacle) [4]usize {
    const lo_x = numeric.toCount(@max(0, @floor((o.x0 - grid.ox) / grid.cell)));
    const lo_y = numeric.toCount(@max(0, @floor((o.y0 - grid.oy) / grid.cell)));
    const hi_x = numeric.toCount(@max(0, @floor((o.x1 - grid.ox) / grid.cell)));
    const hi_y = numeric.toCount(@max(0, @floor((o.y1 - grid.oy) / grid.cell)));
    return .{
        @min(lo_x, grid.nx - 1),
        @min(lo_y, grid.ny - 1),
        @min(hi_x, grid.nx - 1),
        @min(hi_y, grid.ny - 1),
    };
}

/// Bucket edge (mm). Wide enough that a pad lands in a handful of buckets,
/// narrow enough that a bucket holds a handful of pads.
const obs_bucket_mm: f64 = 1.0;

fn buildObsGrid(
    allocator: Allocator,
    placement: *const optimizer.Placement,
    obs: []const Obstacle,
) Allocator.Error!ObsGrid {
    const span_x = placement.maxx - placement.minx + 2 * grid_margin_mm;
    const span_y = placement.maxy - placement.miny + 2 * grid_margin_mm;
    var grid = ObsGrid{
        .ox = placement.minx - grid_margin_mm,
        .oy = placement.miny - grid_margin_mm,
        .cell = obs_bucket_mm,
        .nx = @max(1, numeric.toCount(@ceil(span_x / obs_bucket_mm)) + 1),
        .ny = @max(1, numeric.toCount(@ceil(span_y / obs_bucket_mm)) + 1),
        .starts = &.{},
        .items = &.{},
    };
    const counts = try allocator.alloc(u32, grid.nx * grid.ny + 1);
    @memset(counts, 0);
    for (obs) |o| {
        const s = obsSpan(grid, o);
        for (s[1]..s[3] + 1) |y| {
            for (s[0]..s[2] + 1) |x| counts[y * grid.nx + x + 1] += 1;
        }
    }
    for (1..counts.len) |i| counts[i] += counts[i - 1];
    const items = try allocator.alloc(u32, counts[counts.len - 1]);
    const fill = try allocator.dupe(u32, counts[0 .. counts.len - 1]);
    for (obs, 0..) |o, oi| {
        const s = obsSpan(grid, o);
        for (s[1]..s[3] + 1) |y| {
            for (s[0]..s[2] + 1) |x| {
                const b = y * grid.nx + x;
                items[fill[b]] = @intCast(oi);
                fill[b] += 1;
            }
        }
    }
    grid.starts = counts;
    grid.items = items;
    return grid;
}

/// Carve every cell's usable cross-section: the local aperture at its centre,
/// capped at the reference channel.
fn carveAperture(allocator: Allocator, board: Board, g: Geom) Allocator.Error![]const f64 {
    const out = try allocator.alloc(f64, board.cells());
    for (0..board.layers) |layer| {
        for (0..board.ny) |y| {
            for (0..board.nx) |x| {
                out[board.cell(layer, x, y)] = apertureAt(board, g, layer, board.worldX(x), board.worldY(y));
            }
        }
    }
    return out;
}

/// The widest cross-section a trace could pass through this point, capped at the
/// reference channel: the SHORTER of the open runs through it along x and along
/// y, sampled over a window one channel wide.
///
/// The narrower run is the answer, not the wider one: a trace threading a long
/// thin channel is limited by the channel's width, not by how far it can travel
/// along it. Taking the maximum would call a 0.3 mm slot a corridor.
fn apertureAt(board: Board, g: Geom, layer: usize, cx: f64, cy: f64) f64 {
    if (!samplePointOpen(g, layer, cx, cy)) return 0;
    const step = board.chan / @as(f64, @floatFromInt(2 * aperture_steps));
    const run_x = openRun(g, layer, cx, cy, .{ 1, 0 }, step);
    const run_y = openRun(g, layer, cx, cy, .{ 0, 1 }, step);
    return @min(board.chan, @min(run_x, run_y));
}

/// Length (mm) of the open run through (cx, cy) along `dir`, reaching at most
/// half a channel each way. The centre sample is known open and counts as one
/// step of width.
fn openRun(g: Geom, layer: usize, cx: f64, cy: f64, dir: [2]f64, step: f64) f64 {
    var n: usize = 1;
    for ([2]f64{ 1, -1 }) |sign| {
        for (1..aperture_steps + 1) |i| {
            const d = sign * @as(f64, @floatFromInt(i)) * step;
            if (!samplePointOpen(g, layer, cx + dir[0] * d, cy + dir[1] * d)) break;
            n += 1;
        }
    }
    return @as(f64, @floatFromInt(n)) * step;
}

fn samplePointOpen(g: Geom, layer: usize, px: f64, py: f64) bool {
    if (g.rect) |r| {
        if (px < r.minx + g.inset or px > r.minx + r.w - g.inset) return false;
        if (py < r.miny + g.inset or py > r.miny + r.h - g.inset) return false;
    }
    const b = g.grid.bucketOf(px, py) orelse return true;
    for (g.grid.items[g.grid.starts[b]..g.grid.starts[b + 1]]) |oi| {
        const o = g.obs[oi];
        if (!o.thru and o.layer != layer) continue;
        if (px >= o.x0 and px <= o.x1 and py >= o.y0 and py <= o.y1) return false;
    }
    return true;
}

// ── Terminals ───────────────────────────────────────────────────────────────

/// One net's terminal cells on ONE lattice, deduplicated and in a fixed order.
/// Index 0 is the flow source; the rest are sinks. A finer lattice separates
/// pads a coarse one merged into a single cell, so this is derived per lattice
/// from the world pads in `Geom.terms`.
const Terminals = struct { cells: []const usize };

/// Every slot's terminal pads in world space, plus the pin pitch of the part
/// each sits on. Built once per run.
fn buildTermPads(
    allocator: Allocator,
    placement: *const optimizer.Placement,
    slots: []const Slot,
    dense_pads: usize,
) Allocator.Error![]const []const TermPad {
    var pad_at = std.StringHashMapUnmanaged([2]usize).empty;
    for (placement.parts, 0..) |part, pi| {
        for (part.pads, 0..) |pad, di| {
            const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ part.ref_des, pad.number });
            try pad_at.put(allocator, key, .{ pi, di });
        }
    }
    const boxes = try padBoxes(allocator, placement);
    const out = try allocator.alloc([]const TermPad, slots.len);
    for (slots, 0..) |s, i| {
        out[i] = try netTermPads(allocator, placement, .{ .slot = s, .pad_at = pad_at, .boxes = boxes, .dense_pads = dense_pads });
    }
    return out;
}

/// One part's pads as world boxes, so pin pitch and terminal centres are read
/// off the same geometry the obstacles were.
const PadBox = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

fn padBoxes(
    allocator: Allocator,
    placement: *const optimizer.Placement,
) Allocator.Error![]const []const PadBox {
    const out = try allocator.alloc([]const PadBox, placement.parts.len);
    for (placement.parts, 0..) |part, pi| {
        const row = try allocator.alloc(PadBox, part.pads.len);
        for (part.pads, 0..) |pad, di| {
            const sh = try pad_shape.worldShape(allocator, part, pad);
            row[di] = .{ .x0 = sh.x0, .y0 = sh.y0, .x1 = sh.x1, .y1 = sh.y1 };
        }
        out[pi] = row;
    }
    return out;
}

/// Everything one net's terminal-pad lookup reads, bundled so the call stays
/// inside Guardian's parameter cap.
const TermLookup = struct {
    slot: Slot,
    pad_at: std.StringHashMapUnmanaged([2]usize),
    boxes: []const []const PadBox,
    dense_pads: usize,
};

fn netTermPads(
    allocator: Allocator,
    placement: *const optimizer.Placement,
    look: TermLookup,
) Allocator.Error![]const TermPad {
    if (look.slot.in.net >= placement.nets.len) return &.{};
    var out: std.ArrayList(TermPad) = .empty;
    for (placement.nets[look.slot.in.net].pins) |pin| {
        const key = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ pin.ref_des, pin.pin });
        const at = look.pad_at.get(key) orelse continue;
        const part = placement.parts[at[0]];
        const box = look.boxes[at[0]][at[1]];
        try out.append(allocator, .{
            .x = (box.x0 + box.x1) / 2,
            .y = (box.y0 + box.y1) / 2,
            .side = if (part.side == .bottom) 1 else 0,
            .thru = part.pads[at[1]].thru,
            .pin_pitch = pinPitchAt(look.boxes[at[0]], at[1], look.dense_pads),
        });
    }
    return out.toOwnedSlice(allocator);
}

/// Distance to the nearest other pad of the same part, or infinity when the
/// part is not dense enough to count as escape geometry (see
/// `Params.refine.dense_part_pads` — a two-pad passive's own pads are the net's
/// ENDS, not an aperture anything has to thread).
fn pinPitchAt(pads: []const PadBox, di: usize, dense_pads: usize) f64 {
    if (pads.len < dense_pads) return std.math.inf(f64);
    const cx = (pads[di].x0 + pads[di].x1) / 2;
    const cy = (pads[di].y0 + pads[di].y1) / 2;
    var best = std.math.inf(f64);
    for (pads, 0..) |o, oi| {
        if (oi == di) continue;
        const d = std.math.hypot((o.x0 + o.x1) / 2 - cx, (o.y0 + o.y1) / 2 - cy);
        best = @min(best, d);
    }
    return best;
}

/// Map every slot's world terminal pads onto this lattice's cells.
fn buildTerminals(
    allocator: Allocator,
    board: Board,
    slots: []const Slot,
    g: Geom,
) Allocator.Error![]const Terminals {
    const out = try allocator.alloc(Terminals, slots.len);
    for (slots, 0..) |s, i| {
        const layer = lowestAllowedLayer(board, s.in.allowed_layers);
        var cells: std.ArrayList(usize) = .empty;
        for (g.terms[i]) |t| {
            const use = if (t.thru or !layerAllowed(s.in.allowed_layers, t.side))
                layer
            else
                @min(t.side, board.layers - 1);
            const at = board.nearest(t.x, t.y);
            try appendUnique(allocator, &cells, board.cell(use, at[0], at[1]));
        }
        out[i] = .{ .cells = try cells.toOwnedSlice(allocator) };
    }
    return out;
}

fn appendUnique(allocator: Allocator, list: *std.ArrayList(usize), v: usize) Allocator.Error!void {
    for (list.items) |x| {
        if (x == v) return;
    }
    try list.append(allocator, v);
}

fn containsUsize(hay: []const usize, v: usize) bool {
    for (hay) |x| {
        if (x == v) return true;
    }
    return false;
}

fn layerAllowed(mask: u64, layer: usize) bool {
    if (mask == 0) return true;
    if (layer >= 64) return false;
    return (mask & (@as(u64, 1) << @intCast(layer))) != 0;
}

fn lowestAllowedLayer(board: Board, mask: u64) usize {
    for (0..board.layers) |l| {
        if (layerAllowed(mask, l)) return l;
    }
    return 0;
}

fn allowedLayerCount(board: Board, mask: u64) usize {
    var n: usize = 0;
    for (0..board.layers) |l| {
        if (layerAllowed(mask, l)) n += 1;
    }
    return n;
}

// ── Relaxation ──────────────────────────────────────────────────────────────

/// Edge families. In-plane edges join a cell to its +x / +y neighbour; via
/// edges join a cell to the same node on the next layer up.
const Dir = enum(u2) { x, y, z };

/// Per-net conductance + potential state, plus the shared congestion fields.
const Sim = struct {
    board: *Board,
    slots: []const Slot,
    terms: []const Terminals,
    /// Indices into `slots` participating this pass, in fixed order.
    active: []const usize,
    /// Per-active-net demand weight (1.0 for a commodity of this pass,
    /// `background_demand` for a not-yet-planned wave's standing demand).
    weight: []const f64,
    /// Per-active-net: is this a COMMODITY of this pass (relaxed every frame and
    /// extracted at the end) rather than background? A refinement retry plans
    /// only the nets the coarse pass could not join, so "this wave's nets" is no
    /// longer the same question as "this pass's nets".
    current: []const bool,
    /// Slot index → index into `active`, or `no_slot`. Lets the per-net record
    /// walk slots in their own order while the hot loops stay dense.
    ai_of: []const usize,
    /// `[net][cell]` conductance per direction, and the potential field.
    d: [3][]f64,
    pot: []f64,
    /// Scratch flux for the net being processed.
    q: [3][]f64,
    /// Shared per-cell fields.
    cong: []f64,
    cong_next: []f64,
    hist: []f64,
    /// The not-yet-planned waves' congestion, frozen once per wave. Every frame
    /// starts from it instead of from zero (`advanceFrame`).
    bg: []f64,
    /// `[net][cell]`: may this net occupy this cell? Static for the whole wave
    /// (allowed layer, room for the net's whole cross-section, plus the escape
    /// halo around its own pads), so the hot loops read it instead of
    /// re-deriving the cell's layer and re-comparing its free width.
    usable: []bool,
    /// Per-net scratch, valid only while that net is being solved.
    b: []f64,
    fixed: []bool,
    /// The loaded net's terminal cells plus one cell of escape room. Shared,
    /// and meaningful only while that net is loaded (`loadNet` / `unloadNet`).
    open: []bool,
    /// Membership scratch, always left all-false by whoever borrows it.
    seen: []bool,

    fn stride(self: Sim) usize {
        return self.board.cells();
    }

    fn qAt(self: Sim, dir: Dir, c: usize) f64 {
        return self.q[@backingInt(dir)][c];
    }
};

/// The net currently being relaxed. Bundled so the hot helpers below stay
/// narrow enough to read (and inside Guardian's parameter cap).
const NetSolve = struct {
    sim: *const Sim,
    slot_i: usize,
    ai: usize,
    params: Params,
    /// Cells this search may not enter. Null during relaxation; set only by the
    /// alternative-corridor search that scores confidence.
    blocked: ?[]const bool = null,
};

/// Sentinel for "this slot is not a participant of this pass".
const no_slot: usize = std.math.maxInt(usize);

/// The participating set of one pass: `commodities` are relaxed and extracted;
/// every not-yet-planned wave's net rides along as background demand. A slot a
/// plane carries is in neither — the plane is already everywhere, so it needs no
/// corridor and blocks nobody's.
fn initSim(
    allocator: Allocator,
    board: *Board,
    run: Run,
    pass: Pass,
    commodities: []const usize,
) Allocator.Error!Sim {
    const params = run.params;
    var active: std.ArrayList(usize) = .empty;
    var weight: std.ArrayList(f64) = .empty;
    var current: std.ArrayList(bool) = .empty;
    const ai_of = try allocator.alloc(usize, run.slots.len);
    @memset(ai_of, no_slot);
    for (run.slots, 0..) |s, i| {
        const is_current = containsUsize(commodities, i);
        // A pass that INHERITS a background field needs no background
        // commodities: the field it was handed already says where they want to
        // go, and re-solving them on a refined lattice is the single most
        // expensive thing this module can do.
        if (!is_current and pass.carried != null) continue;
        if (!is_current and (s.wave <= pass.wave or s.in.is_plane_carried)) continue;
        ai_of[i] = active.items.len;
        try active.append(allocator, i);
        try weight.append(allocator, if (is_current) 1.0 else params.flow.background_demand);
        try current.append(allocator, is_current);
    }
    const cells = board.cells();
    const n = active.items.len;
    var d: [3][]f64 = .{ &.{}, &.{}, &.{} };
    var q: [3][]f64 = .{ &.{}, &.{}, &.{} };
    for (0..3) |k| {
        d[k] = try allocator.alloc(f64, n * cells);
        q[k] = try allocator.alloc(f64, cells);
    }
    var sim = Sim{
        .board = board,
        .slots = run.slots,
        .terms = board.terms,
        .active = try active.toOwnedSlice(allocator),
        .weight = try weight.toOwnedSlice(allocator),
        .current = try current.toOwnedSlice(allocator),
        .ai_of = ai_of,
        .d = d,
        .pot = try allocator.alloc(f64, n * cells),
        .q = q,
        .cong = try allocator.alloc(f64, cells),
        .cong_next = try allocator.alloc(f64, cells),
        .hist = try allocator.alloc(f64, cells),
        .bg = try allocator.alloc(f64, cells),
        .usable = try allocator.alloc(bool, n * cells),
        .b = try allocator.alloc(f64, cells),
        .fixed = try allocator.alloc(bool, cells),
        .open = try allocator.alloc(bool, cells),
        .seen = try allocator.alloc(bool, cells),
    };
    resetSim(&sim, params);
    buildUsable(&sim);
    return sim;
}

/// Fold the two static admission tests — allowed layer, and room for the net's
/// whole cross-section — into one array read per edge end, once per wave. The
/// third test (the loaded net's escape halo) stays dynamic in `Sim.open`.
fn buildUsable(sim: *Sim) void {
    const cells = sim.stride();
    for (sim.active, 0..) |slot_i, ai| {
        const row = sim.usable[ai * cells ..][0..cells];
        const slot = sim.slots[slot_i];
        for (0..cells) |c| {
            row[c] = layerAllowed(slot.in.allowed_layers, sim.board.layerOf(c)) and
                sim.board.free[c] >= slot.demand_mm;
        }
    }
}

/// Mark (or clear) one net's escape halo: every cell within one REFERENCE
/// CHANNEL of a terminal, on any layer the net is allowed. Without it the
/// capacity gate can seal a net inside its own pad, where the pad itself leaves
/// every nearby cell under-width.
///
/// The radius is a distance in millimetres, not a count of lattice steps: a
/// refined wave must get the same physical breathing room as a coarse one, or
/// halving its pitch would halve the escape room it is refining in order to see.
/// On the reference lattice the radius admits exactly the four in-plane
/// neighbours a step away, which is the v1 halo.
fn setHalo(sim: *Sim, slot_i: usize, on: bool) void {
    const board = sim.board.*;
    const mask = sim.slots[slot_i].in.allowed_layers;
    const r = board.chan;
    const reach = numeric.toCount(@ceil(r / board.p));
    for (sim.terms[slot_i].cells) |t| {
        const tx = board.colOf(t);
        const ty = board.rowOf(t);
        for (ty -| reach..@min(board.ny, ty + reach + 1)) |y| {
            for (tx -| reach..@min(board.nx, tx + reach + 1)) |x| {
                if (!withinRadius(board, tx, ty, x, y, r)) continue;
                for (0..board.layers) |l| {
                    if (layerAllowed(mask, l)) sim.open[board.cell(l, x, y)] = on;
                }
            }
        }
    }
}

fn withinRadius(board: Board, ax: usize, ay: usize, bx: usize, by: usize, r: f64) bool {
    const dx = board.worldX(bx) - board.worldX(ax);
    const dy = board.worldY(by) - board.worldY(ay);
    return dx * dx + dy * dy <= r * r;
}

/// Every wave relaxes from scratch: capacity and the participating set both
/// changed, so carrying the previous wave's conductance would bias the new
/// problem toward a topology that was solved against different constraints.
fn resetSim(sim: *Sim, params: Params) void {
    @memset(sim.pot, 0);
    @memset(sim.cong, 0);
    @memset(sim.cong_next, 0);
    @memset(sim.hist, 0);
    @memset(sim.bg, 0);
    @memset(sim.b, 0);
    @memset(sim.fixed, false);
    @memset(sim.open, false);
    @memset(sim.seen, false);
    const cells = sim.stride();
    for (sim.active, 0..) |_, ai| {
        for (0..cells) |c| {
            for (0..3) |k| {
                const base: f64 = if (k == @backingInt(Dir.z)) params.flow.via_conductance else 1.0;
                sim.d[k][ai * cells + c] = base * (1 + tie_break_eps * tiePhase(ai, k, c));
            }
        }
    }
}

/// Deterministic per-net spatial bias in [0,1). Two nets contending for two
/// equal corridors must not both sit in the middle forever; this seeds the
/// congestion feedback that separates them. Integer mixing, never an RNG.
fn tiePhase(slot_i: usize, dir: usize, c: usize) f64 {
    var h: u64 = @as(u64, slot_i +% 1) *% 0x9E3779B97F4A7C15;
    h ^= @as(u64, dir +% 1) *% 0xC2B2AE3D27D4EB4F;
    h ^= @as(u64, c) *% 0x165667B19E3779F9;
    h ^= h >> 29;
    return @as(f64, @floatFromInt(h % 1024)) / 1024.0;
}

/// The edge slot an edge is stored in: always the LOWER of its two cells.
fn edgeSlot(c: usize, other: usize) usize {
    return @min(c, other);
}

/// Effective conductance of one edge for the net currently being solved, given
/// the far end the caller's lattice walk already has. Zero whenever the edge is
/// unusable — blocked cell, disallowed layer, no room for the cross-section — so
/// a zero here is a hard "no flow", not merely expensive.
fn edgeDeAt(s: NetSolve, c: usize, other: usize, dir: Dir) f64 {
    const sim = s.sim;
    if (!cellUsable(s, c) or !cellUsable(s, other)) return 0;
    const d = sim.d[@backingInt(dir)][s.ai * sim.stride() + edgeSlot(c, other)];
    const load = (sim.cong[c] + sim.cong[other]) / 2;
    const hist = (sim.hist[c] + sim.hist[other]) / 2;
    return d / (1 + s.params.flow.kappa * (load + s.params.flow.history_weight * hist));
}

/// A cell carries this net's flow when it is inside the loaded net's escape
/// halo, or `buildUsable` admitted it — and the caller's alternative-corridor
/// search has not blocked it.
fn cellUsable(s: NetSolve, c: usize) bool {
    if (s.blocked) |mask| {
        if (mask[c]) return false;
    }
    if (s.sim.open[c]) return true;
    return s.sim.usable[s.ai * s.sim.stride() + c];
}

/// Load the per-net sparse right-hand side: +1 at terminal 0, −1/(n−1) at each
/// other terminal, with the LAST terminal pinned Dirichlet so the singular pure
/// -Neumann system has a unique solution. The pinned node absorbs exactly its
/// own 1/(n−1) share, so the star flow the spec asks for is unchanged.
fn loadNet(sim: *Sim, slot_i: usize) void {
    const t = sim.terms[slot_i].cells;
    setHalo(sim, slot_i, true);
    if (t.len < 2) return;
    const share = 1.0 / @as(f64, @floatFromInt(t.len - 1));
    sim.b[t[0]] = 1.0;
    for (t[1 .. t.len - 1]) |c| sim.b[c] = -share;
    sim.fixed[t[t.len - 1]] = true;
}

fn unloadNet(sim: *Sim, slot_i: usize) void {
    setHalo(sim, slot_i, false);
    for (sim.terms[slot_i].cells) |c| {
        sim.b[c] = 0;
        sim.fixed[c] = false;
    }
}

fn gaussSeidel(sim: *Sim, s: NetSolve) void {
    const cells = sim.stride();
    const pot = sim.pot[s.ai * cells ..][0..cells];
    for (0..s.params.budget.gs_sweeps) |_| {
        for (0..cells) |c| relaxCell(s, pot, c);
    }
}

fn relaxCell(s: NetSolve, pot: []f64, c: usize) void {
    if (s.sim.fixed[c]) {
        pot[c] = 0;
        return;
    }
    // An inadmissible cell has no live edge, so its potential never moves;
    // testing it once here saves six edge evaluations that would all return 0.
    if (!cellUsable(s, c)) return;
    var num = s.sim.b[c];
    var den: f64 = 0;
    for (s.sim.board.nbrs[c], 0..) |pair, di| {
        for (pair) |other| {
            if (other == no_cell) continue;
            const de = edgeDeAt(s, c, other, @fromBackingInt(@intCast(di)));
            if (de <= 0) continue;
            num += de * pot[other];
            den += de;
        }
    }
    if (den > 0) pot[c] = num / den;
}

/// `Q = De·∇p` on every forward edge, into the shared scratch.
fn computeFlux(sim: *Sim, s: NetSolve) void {
    const cells = sim.stride();
    const pot = sim.pot[s.ai * cells ..][0..cells];
    for (0..3) |k| @memset(sim.q[k], 0);
    for (0..cells) |c| {
        for (sim.board.nbrs[c], 0..) |pair, di| {
            const other = pair[0];
            if (other == no_cell) continue;
            const de = edgeDeAt(s, c, other, @fromBackingInt(@intCast(di)));
            if (de <= 0) continue;
            sim.q[di][c] = de * (pot[c] - pot[other]);
        }
    }
}

/// The Tero update: a corridor carrying flux thickens, one carrying none decays.
fn updateConductance(sim: *Sim, ai: usize, params: Params) void {
    const cells = sim.stride();
    for (0..3) |k| {
        const d = sim.d[k][ai * cells ..][0..cells];
        for (0..cells) |c| {
            d[c] += params.flow.rate * (@abs(sim.q[k][c]) - d[c]);
            if (d[c] < 0) d[c] = 0;
        }
    }
}

/// A cell's flux magnitude is half the sum over its incident edges, so a unit
/// of straight-through flow reads exactly 1.
fn cellFlux(sim: Sim, c: usize) f64 {
    var sum: f64 = 0;
    for (sim.board.nbrs[c], 0..) |pair, di| {
        const dir: Dir = @fromBackingInt(@intCast(di));
        sum += @abs(sim.qAt(dir, c));
        if (pair[1] != no_cell) sum += @abs(sim.qAt(dir, pair[1]));
    }
    return sum / 2;
}

/// Congestion is demand cross-section over free cross-section, so 1.0 means a
/// cell is exactly full and the history term starts charging above it.
fn accumulateCongestion(sim: *Sim, dst: []f64, slot_i: usize, weight: f64) void {
    const demand = sim.slots[slot_i].demand_mm;
    for (0..sim.stride()) |c| {
        const free = sim.board.free[c];
        if (free <= 0) continue;
        dst[c] += weight * cellFlux(sim.*, c) * demand / free;
    }
}

fn advanceFrame(sim: *Sim) void {
    for (0..sim.stride()) |c| {
        sim.hist[c] += @max(0, sim.cong_next[c] - 1);
    }
    std.mem.swap([]f64, &sim.cong, &sim.cong_next);
    // The next frame starts from the frozen background rather than from zero:
    // not-yet-planned waves are a standing demand, not a per-frame commodity.
    @memcpy(sim.cong_next, sim.bg);
}

/// One frame: every commodity of this pass relaxes against the PREVIOUS frame's
/// congestion (double-buffered), then history charges for oversubscription.
/// `everyone` relaxes the background nets too — the warm-up that produces the
/// frozen background field, and the only place a later wave's conductance moves.
fn runFrame(sim: *Sim, params: Params, everyone: bool) void {
    for (sim.active, 0..) |slot_i, ai| {
        if (!everyone and !sim.current[ai]) continue;
        solveNet(sim, slot_i, ai, params);
        accumulateCongestion(sim, sim.cong_next, slot_i, sim.weight[ai]);
        unloadNet(sim, slot_i);
    }
    advanceFrame(sim);
}

/// Relax one net's potential and adapt its conductance. Leaves the net LOADED
/// (its flux is in the shared scratch) so the caller can read it before
/// `unloadNet` clears the right-hand side.
fn solveNet(sim: *Sim, slot_i: usize, ai: usize, params: Params) void {
    const s = NetSolve{ .sim = sim, .slot_i = slot_i, .ai = ai, .params = params };
    loadNet(sim, slot_i);
    gaussSeidel(sim, s);
    computeFlux(sim, s);
    updateConductance(sim, ai, params);
}

/// Freeze the waves that have NOT been planned yet into a standing congestion
/// field, so the wave being planned relaxes alone against it.
///
/// A later wave is context, not a commodity: this wave has to see where that
/// work will want to go, but re-solving all of it every frame is what made
/// planning quadratic in wave count. Measured on barracuda (16 waves, 93 nets):
/// 87–98% of every frame went to nets the wave could not emit, and one flagged
/// wave cost exactly as much as sixteen. So the whole participating set relaxes
/// for a short warm-up, the later waves' demand is read off ONCE, and the main
/// loop never touches them again.
fn freezeBackground(sim: *Sim, params: Params) void {
    // The last wave (and any single-wave plan) has no later work to leave room
    // for, so there is nothing to warm up and the field stays zero.
    if (!hasBackground(sim.*)) return;
    for (0..params.flow.background_frames) |_| runFrame(sim, params, true);
    @memset(sim.bg, 0);
    for (sim.active, 0..) |slot_i, ai| {
        if (sim.current[ai]) continue;
        loadNet(sim, slot_i);
        computeFlux(sim, .{ .sim = sim, .slot_i = slot_i, .ai = ai, .params = params });
        accumulateCongestion(sim, sim.bg, slot_i, sim.weight[ai]);
        unloadNet(sim, slot_i);
    }
    @memcpy(sim.cong_next, sim.bg);
}

fn hasBackground(sim: Sim) bool {
    for (sim.current) |c| {
        if (!c) return true;
    }
    return false;
}

/// A frozen background field plus the lattice it was measured on, so a refined
/// retry can inherit it instead of paying for the whole warm-up again.
const Carried = struct { from: *const Board, bg: []const f64 };

/// Carry a coarser pass's frozen background onto this lattice, nearest cell. The
/// background is a standing field read off a short warm-up — a smoothed
/// statement of where not-yet-planned work wants to go — so resampling it says
/// exactly what re-deriving it would, for the cost of one pass over the cells.
fn resampleBackground(sim: *Sim, carried: Carried) void {
    const board = sim.board.*;
    const from = carried.from.*;
    for (0..board.layers) |l| {
        const src_layer = @min(l, from.layers - 1);
        for (0..board.ny) |y| {
            for (0..board.nx) |x| {
                const at = from.nearest(board.worldX(x), board.worldY(y));
                sim.bg[board.cell(l, x, y)] = carried.bg[from.cell(src_layer, at[0], at[1])];
            }
        }
    }
    @memcpy(sim.cong_next, sim.bg);
}

// ── Extraction ──────────────────────────────────────────────────────────────

/// A net's planned backbone: the highest-flux tree joining its terminals.
const Backbone = struct {
    /// One path per sink, each a list of cells from terminal 0 outward.
    branches: []const []const usize = &.{},
    cells: []const usize = &.{},
    /// Flux-weighted cost of the whole tree (see `treeCost`).
    cost: f64 = 0,
    ok: bool = false,
};

const HeapItem = struct { cell: usize, dist: f64 };

fn heapBefore(_: void, a: HeapItem, b: HeapItem) std.math.Order {
    if (a.dist < b.dist) return .lt;
    if (a.dist > b.dist) return .gt;
    // Index tie-break keeps two equal-cost frontiers in a fixed order.
    return std.math.order(a.cell, b.cell);
}

/// Dijkstra over `pitch / (|Q| + eps)` — the cheapest path is the one hugging
/// the corridor the relaxation actually pushed flow through.
const Search = struct { prev: []usize, dist: []f64 };

fn dijkstra(allocator: Allocator, s: NetSolve) Allocator.Error!Search {
    const cells = s.sim.stride();
    const dist = try allocator.alloc(f64, cells);
    const prev = try allocator.alloc(usize, cells);
    @memset(dist, std.math.inf(f64));
    @memset(prev, std.math.maxInt(usize));
    var heap = std.PriorityQueue(HeapItem, void, heapBefore).initContext({});
    defer heap.deinit(allocator);
    const src = s.sim.terms[s.slot_i].cells[0];
    dist[src] = 0;
    try heap.push(allocator, .{ .cell = src, .dist = 0 });
    while (heap.pop()) |item| {
        if (item.dist > dist[item.cell]) continue;
        try relaxNeighbors(allocator, s, item.cell, dist, prev, &heap);
    }
    return .{ .prev = prev, .dist = dist };
}

/// Total flux-weighted cost of joining every sink, or infinity when any sink is
/// unreachable.
fn treeCost(s: NetSolve, dist: []const f64) f64 {
    var sum: f64 = 0;
    for (s.sim.terms[s.slot_i].cells[1..]) |sink| {
        if (!std.math.isFinite(dist[sink])) return std.math.inf(f64);
        sum += dist[sink];
    }
    return sum;
}

fn relaxNeighbors(
    allocator: Allocator,
    s: NetSolve,
    c: usize,
    dist: []f64,
    prev: []usize,
    heap: *std.PriorityQueue(HeapItem, void, heapBefore),
) Allocator.Error!void {
    for (s.sim.board.nbrs[c], 0..) |pair, di| {
        for (pair) |other| {
            if (other == no_cell) continue;
            const dir: Dir = @fromBackingInt(@intCast(di));
            if (edgeDeAt(s, c, other, dir) <= 0) continue;
            const flux = @abs(s.sim.q[di][edgeSlot(c, other)]);
            // A layer change is priced explicitly, not left to the flux alone:
            // the Tero update drives every conductance toward its own flux, so
            // the `via_conductance` bias that made a vertical edge expensive at
            // frame zero is gone by the time the backbone is extracted.
            const step = if (dir == .z) s.params.guide.via_cost_mult else 1;
            const w = step * s.sim.board.p / (flux + flux_eps);
            if (dist[c] + w >= dist[other]) continue;
            dist[other] = dist[c] + w;
            prev[other] = c;
            try heap.push(allocator, .{ .cell = other, .dist = dist[other] });
        }
    }
}

fn tracePath(allocator: Allocator, prev: []const usize, src: usize, dst: usize) Allocator.Error!?[]usize {
    if (dst != src and prev[dst] == std.math.maxInt(usize)) return null;
    var rev: std.ArrayList(usize) = .empty;
    var at = dst;
    while (true) {
        try rev.append(allocator, at);
        if (at == src) break;
        at = prev[at];
    }
    const out = try rev.toOwnedSlice(allocator);
    std.mem.reverse(usize, out);
    return out;
}

fn extractBackbone(allocator: Allocator, sim: *Sim, slot_i: usize, ai: usize, params: Params) Allocator.Error!Backbone {
    const t = sim.terms[slot_i].cells;
    if (t.len < 2) return .{};
    const s = NetSolve{ .sim = sim, .slot_i = slot_i, .ai = ai, .params = params };
    loadNet(sim, slot_i);
    computeFlux(sim, s);
    const found = try dijkstra(allocator, s);
    var branches: std.ArrayList([]const usize) = .empty;
    var all: std.ArrayList(usize) = .empty;
    for (t[1..]) |sink| {
        const path = try tracePath(allocator, found.prev, t[0], sink) orelse {
            for (all.items) |c| sim.seen[c] = false;
            unloadNet(sim, slot_i);
            return .{};
        };
        try branches.append(allocator, path);
        // A star's branches share their trunk, so `all` is a set, not a
        // concatenation. Marking membership beats re-scanning it: a whole-board
        // net's tree reaches thousands of cells and the scan was quadratic.
        for (path) |c| {
            if (sim.seen[c]) continue;
            sim.seen[c] = true;
            try all.append(allocator, c);
        }
    }
    for (all.items) |c| sim.seen[c] = false;
    unloadNet(sim, slot_i);
    return .{
        .branches = try branches.toOwnedSlice(allocator),
        .cells = try all.toOwnedSlice(allocator),
        .cost = treeCost(s, found.dist),
        .ok = true,
    };
}

/// How committed the relaxation is to this backbone, as
/// `cost_alt / (cost_main + cost_alt)` over the flux-weighted metric, where
/// `cost_alt` is the best route that CANNOT use the planned corridor. Two
/// equally good corridors score 0.5; a corridor that is the only way scores
/// 1.0. `confidence_min` therefore reads directly as "the alternative must be
/// at least this much worse before I assert a topology".
///
/// This deliberately replaces the literal "fraction of |Q| mass within corridor
/// radius" of the v1 sketch. Measured on the two-gap fixture, that quantity
/// plateaus at 0.42 (r = 1.25·pitch) and reaches 0.6 only at r ≈ 2.4·pitch,
/// regardless of frame budget — because the PLAIN Tero update the spec mandates
/// (`D += rate·(|Q| − D)`, no Hill sharpening) settles at `D ∝ |Q|`, which
/// concentrates flow only weakly and always leaves a broad skirt. A mass-ratio
/// gate at the corridor width is therefore a measure of how narrow a Laplacian
/// filament is, not of whether the net chose a corridor, and 0.6 is unreachable
/// by construction. This ratio measures the thing the gate is FOR — did the flow
/// commit to one corridor — and is free of both lattice pitch and flux scale.
fn confidenceOf(allocator: Allocator, s: NetSolve, bone: Backbone, radius: f64) Allocator.Error!f64 {
    if (!bone.ok or !std.math.isFinite(bone.cost)) return 0;
    const mask = try corridorMask(allocator, s, bone, radius);
    var alt = s;
    alt.blocked = mask;
    const found = try dijkstra(allocator, alt);
    const cost_alt = treeCost(alt, found.dist);
    if (!std.math.isFinite(cost_alt)) return 1;
    if (bone.cost + cost_alt <= 0) return 0;
    return cost_alt / (bone.cost + cost_alt);
}

/// The planned corridor as a blocked mask, with breathing room kept around the
/// terminals — sealing a pad's own escape would make every net look unique.
fn corridorMask(
    allocator: Allocator,
    s: NetSolve,
    bone: Backbone,
    radius: f64,
) Allocator.Error![]const bool {
    const board = s.sim.board.*;
    const mask = try allocator.alloc(bool, s.sim.stride());
    @memset(mask, false);
    for (0..mask.len) |c| {
        if (!nearBackbone(board, bone, c, radius)) continue;
        if (nearTerminals(board, s.sim.terms[s.slot_i].cells, c, 2 * radius)) continue;
        mask[c] = true;
    }
    return mask;
}

fn nearTerminals(board: Board, terms: []const usize, c: usize, radius: f64) bool {
    const cx = board.worldX(board.colOf(c));
    const cy = board.worldY(board.rowOf(c));
    for (terms) |t| {
        const tx = board.worldX(board.colOf(t));
        const ty = board.worldY(board.rowOf(t));
        if (std.math.hypot(cx - tx, cy - ty) <= radius) return true;
    }
    return false;
}

fn nearBackbone(board: Board, bone: Backbone, c: usize, radius: f64) bool {
    const cx = board.worldX(board.colOf(c));
    const cy = board.worldY(board.rowOf(c));
    for (bone.cells) |b| {
        const bx = board.worldX(board.colOf(b));
        const by = board.worldY(board.rowOf(b));
        if (std.math.hypot(cx - bx, cy - by) <= radius) return true;
    }
    return false;
}

// ── Stability ───────────────────────────────────────────────────────────────

/// One extraction of the whole wave: each net's backbone cell set. Kept as sets
/// rather than folded to a hash so the check can measure HOW FAR a backbone
/// moved, not merely whether it moved — see `topologyOverlap`.
const Topology = struct { nets: []const []const usize };

fn extractTopology(
    allocator: Allocator,
    sim: *Sim,
    params: Params,
) Allocator.Error!Topology {
    var out: std.ArrayList([]const usize) = .empty;
    for (sim.active, 0..) |slot_i, ai| {
        if (!sim.current[ai]) continue;
        const bone = try extractBackbone(allocator, sim, slot_i, ai, params);
        try out.append(allocator, bone.cells);
    }
    return .{ .nets = try out.toOwnedSlice(allocator) };
}

/// The LEAST per-net Jaccard overlap between two extractions: 1.0 when every
/// net came out with exactly the same cells, and a net that came out empty both
/// times counts as unchanged. Taking the minimum (not the mean) keeps one net
/// still hunting for its corridor from being averaged away by a settled wave.
fn topologyOverlap(sim: *Sim, a: Topology, b: Topology) f64 {
    if (a.nets.len != b.nets.len) return 0;
    var worst: f64 = 1;
    for (a.nets, b.nets) |x, y| worst = @min(worst, jaccard(sim, x, y));
    return worst;
}

fn jaccard(sim: *Sim, a: []const usize, b: []const usize) f64 {
    if (a.len == 0 and b.len == 0) return 1;
    for (a) |c| sim.seen[c] = true;
    var inter: usize = 0;
    for (b) |c| {
        if (sim.seen[c]) inter += 1;
    }
    for (a) |c| sim.seen[c] = false;
    const uni = a.len + b.len - inter;
    if (uni == 0) return 1;
    return @as(f64, @floatFromInt(inter)) / @as(f64, @floatFromInt(uni));
}

/// Freeze the background, then relax THIS wave's nets against it under a fixed
/// frame budget, with an early-out once the extracted topology has held still
/// for `stability_checks` consecutive checks. No clock is ever read: the budget
/// and the check period are both frame counts.
fn relax(
    allocator: Allocator,
    sim: *Sim,
    params: Params,
    carried: ?Carried,
) Allocator.Error!void {
    if (carried) |c| resampleBackground(sim, c) else freezeBackground(sim, params);
    var last: ?Topology = null;
    var stable: u32 = 0;
    for (0..params.budget.frames) |f| {
        runFrame(sim, params, false);
        if ((f + 1) % stability_period != 0) continue;
        const now = try extractTopology(allocator, sim, params);
        const held = if (last) |l| topologyOverlap(sim, l, now) >= params.budget.stability_overlap else false;
        stable = if (held) stable + 1 else 0;
        last = now;
        if (stable >= params.budget.stability_checks) return;
    }
}

// ── Guide lowering ──────────────────────────────────────────────────────────

/// Split a cell path into maximal same-layer runs, simplify each, and lower it
/// to segments plus a via at every layer change.
fn emitBranch(
    allocator: Allocator,
    board: Board,
    slot: Slot,
    path: []const usize,
    out: *Output,
) Allocator.Error!void {
    var start: usize = 0;
    while (start < path.len) {
        var end = start;
        while (end + 1 < path.len and board.layerOf(path[end + 1]) == board.layerOf(path[start])) end += 1;
        try emitRun(allocator, board, slot, path[start .. end + 1], out);
        if (end + 1 < path.len) {
            try out.vias.append(allocator, .{
                .x = board.worldX(board.colOf(path[end])),
                .y = board.worldY(board.rowOf(path[end])),
                .net = @intCast(slot.in.net),
            });
        }
        start = end + 1;
    }
}

fn emitRun(
    allocator: Allocator,
    board: Board,
    slot: Slot,
    run: []const usize,
    out: *Output,
) Allocator.Error!void {
    if (run.len < 2) return;
    const pts = try simplifyRun(allocator, board, run);
    const layer: u8 = @intCast(board.layerOf(run[0]));
    for (0..pts.len - 1) |i| {
        try appendTrack(allocator, out, .{
            .x1 = pts[i][0],
            .y1 = pts[i][1],
            .x2 = pts[i + 1][0],
            .y2 = pts[i + 1][1],
            .layer = layer,
            .net = @intCast(slot.in.net),
            .width = slot.in.width,
        });
    }
}

/// A shared trunk is traced once per branch, so identical segments recur; the
/// corridor mask would OR them anyway, but deduping keeps the guide set (and
/// the determinism comparison) small.
fn appendTrack(
    allocator: Allocator,
    out: *Output,
    t: route_policy.GuideTrack,
) Allocator.Error!void {
    for (out.tracks.items) |e| {
        if (sameSegment(e, t)) return;
    }
    try out.tracks.append(allocator, t);
}

fn sameSegment(a: route_policy.GuideTrack, b: route_policy.GuideTrack) bool {
    if (a.net != b.net or a.layer != b.layer) return false;
    if (a.x1 != b.x1 or a.y1 != b.y1) return false;
    return a.x2 == b.x2 and a.y2 == b.y2;
}

/// Drop collinear points, then Douglas-Peucker at half the lattice pitch.
fn simplifyRun(allocator: Allocator, board: Board, run: []const usize) Allocator.Error![]const [2]f64 {
    const raw = try allocator.alloc([2]f64, run.len);
    for (run, 0..) |c, i| {
        raw[i] = .{ board.worldX(board.colOf(c)), board.worldY(board.rowOf(c)) };
    }
    const keep = try allocator.alloc(bool, raw.len);
    @memset(keep, false);
    keep[0] = true;
    keep[raw.len - 1] = true;
    try douglasPeucker(allocator, raw, keep, board.p * simplify_tol_scale);
    var out: std.ArrayList([2]f64) = .empty;
    for (raw, 0..) |pt, i| {
        if (keep[i]) try out.append(allocator, pt);
    }
    return out.toOwnedSlice(allocator);
}

const Span = struct { lo: usize, hi: usize };

/// Iterative (explicit stack) so a long backbone cannot recurse deeply.
fn douglasPeucker(allocator: Allocator, pts: []const [2]f64, keep: []bool, tol: f64) Allocator.Error!void {
    var stack: std.ArrayList(Span) = .empty;
    try stack.append(allocator, .{ .lo = 0, .hi = pts.len - 1 });
    while (stack.pop()) |s| {
        if (s.hi <= s.lo + 1) continue;
        const split = farthest(pts, s);
        if (split[1] <= tol) continue;
        const at = numeric.toCount(split[0]);
        keep[at] = true;
        try stack.append(allocator, .{ .lo = s.lo, .hi = at });
        try stack.append(allocator, .{ .lo = at, .hi = s.hi });
    }
}

fn farthest(pts: []const [2]f64, s: Span) [2]f64 {
    var best_i: usize = s.lo;
    var best_d: f64 = 0;
    for (s.lo + 1..s.hi) |i| {
        const d = pointSegDist(pts[i], pts[s.lo], pts[s.hi]);
        if (d > best_d) {
            best_d = d;
            best_i = i;
        }
    }
    return .{ @floatFromInt(best_i), best_d };
}

fn pointSegDist(p: [2]f64, a: [2]f64, b: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    if (len2 <= 0) return std.math.hypot(p[0] - a[0], p[1] - a[1]);
    const t = std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2, 0, 1);
    return std.math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}

/// See the header's open-question-2 note: a guided net that MAY via must never
/// be left with tracks and no vias, or `reference_off_via_mult` taxes every
/// layer change on it board-wide.
fn emitCorridorVias(
    allocator: Allocator,
    board: Board,
    slot: Slot,
    bone: Backbone,
    out: *Output,
) Allocator.Error!void {
    if (allowedLayerCount(board, slot.in.allowed_layers) < 2) return;
    // Sub-sampled at half a reference channel, which is exactly EVERY cell of a
    // reference-pitch backbone and a bounded handful of a refined one — the
    // router paints a 3×3 block of its own grid around each sample, so denser
    // samples add file size and nothing else.
    var last: ?[2]f64 = null;
    for (bone.cells) |c| {
        const pt = [2]f64{ board.worldX(board.colOf(c)), board.worldY(board.rowOf(c)) };
        if (last) |l| {
            if (std.math.hypot(pt[0] - l[0], pt[1] - l[1]) < board.chan / 2) continue;
        }
        last = pt;
        try out.vias.append(allocator, .{ .x = pt[0], .y = pt[1], .net = @intCast(slot.in.net) });
    }
}

// ── Per-wave driver ─────────────────────────────────────────────────────────

/// One planned backbone's world footprint, so the capacity it consumes can be
/// re-stamped onto a lattice with different cells.
fn stampOf(allocator: Allocator, board: Board, slot: Slot, bone: Backbone) Allocator.Error!Stamp {
    const pts = try allocator.alloc(StampPt, bone.cells.len);
    for (bone.cells, 0..) |c, i| {
        pts[i] = .{
            .x = board.worldX(board.colOf(c)),
            .y = board.worldY(board.rowOf(c)),
            .layer = board.layerOf(c),
        };
    }
    return .{ .pts = pts, .demand_mm = slot.demand_mm };
}

/// How wide a stamp actually consumes: the trace's own half cross-section, or
/// half a cell when the lattice is coarser than that.
///
/// NOT the guide corridor's half-width, which is what v1 used. A corridor is a
/// HINT to the router — deliberately wide so the discount is reachable — while a
/// stamp is a claim on real capacity, and charging 1.16 mm of channel for a
/// 0.38 mm trace closes an escape region after one net has crossed it. Half a
/// cell is the floor because a backbone's cells sit one pitch apart, so anything
/// less would leave gaps between the cells it visibly runs through.
fn stampRadius(board: Board, demand_mm: f64) f64 {
    return @max(demand_mm / 2, board.p / 2);
}

/// Consume a planned backbone's cross-section, so every later pass relaxes
/// against a board that already knows it is there. Rasterised from the stamp's
/// world points rather than scanned over every cell: a refined lattice has tens
/// of thousands of cells and a wave replays every stamp taken so far.
fn applyStamp(board: *Board, st: Stamp, touched: []bool) void {
    @memset(touched, false);
    const r = stampRadius(board.*, st.demand_mm);
    const reach = numeric.toCount(@ceil(r / board.p));
    for (st.pts) |pt| {
        const at = board.nearest(pt.x, pt.y);
        const layer = @min(pt.layer, board.layers - 1);
        for (at[1] -| reach..@min(board.ny, at[1] + reach + 1)) |y| {
            for (at[0] -| reach..@min(board.nx, at[0] + reach + 1)) |x| {
                const dx = board.worldX(x) - pt.x;
                const dy = board.worldY(y) - pt.y;
                if (dx * dx + dy * dy > r * r) continue;
                touched[board.cell(layer, x, y)] = true;
            }
        }
    }
    for (0..board.cells()) |c| {
        if (!touched[c] or board.free[c] <= 0) continue;
        board.free[c] = @max(0, board.free[c] - st.demand_mm);
    }
}

/// Plan one wave. Its nets are relaxed together on the reference lattice; any
/// net that lattice could not join is RETRIED on a finer one (see
/// `refinedPitch`) with only those nets as commodities — the pass that just ran
/// has already stamped everything it did place, so the retry is a small problem
/// on a big grid rather than the whole wave over again. That is what keeps the
/// refinement affordable: a wave whose nets all found corridors pays exactly
/// what it always did.
fn planWave(allocator: Allocator, run: *Run, wave: usize) Allocator.Error!void {
    const first = try planPass(allocator, run, .{ .wave = wave, .pitch = run.chan, .may_retry = true });
    if (first.stuck.len == 0) return;
    const fine = refinedPitch(run.*, first.stuck);
    if (fine >= run.chan) {
        for (first.stuck) |slot_i| try recordStuck(allocator, run, slot_i, run.chan);
        return;
    }
    _ = try planPass(allocator, run, .{
        .wave = wave,
        .pitch = fine,
        .only = first.stuck,
        .carried = first.background,
    });
}

/// One relaxation of a wave on one lattice.
const Pass = struct {
    wave: usize,
    pitch: f64,
    /// The slots to plan; null means every net of the wave.
    only: ?[]const usize = null,
    /// Hold a net that found no corridor back for a finer retry instead of
    /// diagnosing `no_path` now.
    may_retry: bool = false,
    /// Background field to inherit rather than warm up (see `Carried`).
    carried: ?Carried = null,
};

/// What a pass leaves behind: the nets it could not join, and the standing
/// background field it froze (so a retry need not freeze it again).
const PassResult = struct { stuck: []const usize, background: Carried };

fn planPass(allocator: Allocator, run: *Run, pass: Pass) Allocator.Error!PassResult {
    const board = try latticeFor(allocator, run, pass.pitch);
    const commodities = pass.only orelse try waveCommodities(allocator, run.*, pass.wave);
    var sim = try initSim(allocator, board, run.*, pass, commodities);
    try relax(allocator, &sim, run.params, pass.carried);
    const ctx = WaveCtx{
        .sim = &sim,
        .board = board,
        .radius = run.params.guide.corridor_halfwidth_scale * run.chan,
        .params = run.params,
        .run = run,
        .touched = try allocator.alloc(bool, board.cells()),
    };
    var stuck: std.ArrayList(usize) = .empty;
    for (commodities) |slot_i| {
        const ai = sim.ai_of[slot_i];
        const bone = try extractBackbone(allocator, &sim, slot_i, ai, run.params);
        if (pass.may_retry and !bone.ok and run.geom.terms[slot_i].len >= 2) {
            try stuck.append(allocator, slot_i);
            continue;
        }
        try recordNet(allocator, ctx, slot_i, ai, bone);
    }
    if (pass.only == null) try recordSkipped(allocator, run, pass.wave, pass.pitch);
    return .{
        .stuck = try stuck.toOwnedSlice(allocator),
        .background = .{ .from = board, .bg = sim.bg },
    };
}

/// The wave's nets that are relaxed at all: a plane carries the rest, so they
/// need no corridor and take no channel.
fn waveCommodities(allocator: Allocator, run: Run, wave: usize) Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    for (run.slots, 0..) |s, i| {
        if (s.wave == wave and !s.in.is_plane_carried) try out.append(allocator, i);
    }
    return out.toOwnedSlice(allocator);
}

/// Diagnose the nets a plane carries — recorded once per wave, alongside the
/// wave's own answers, so every input net still gets exactly one diagnosis.
fn recordSkipped(allocator: Allocator, run: *Run, wave: usize, pitch: f64) Allocator.Error!void {
    for (run.slots) |s| {
        if (s.wave != wave or !s.in.is_plane_carried) continue;
        try run.out.diags.append(allocator, .{
            .net = s.in.net,
            .wave = wave,
            .emitted = false,
            .reason = .plane_carried,
            .pitch_mm = pitch,
        });
    }
}

/// A net no lattice could join and no finer one was available for.
fn recordStuck(allocator: Allocator, run: *Run, slot_i: usize, pitch: f64) Allocator.Error!void {
    const s = run.slots[slot_i];
    try run.out.diags.append(allocator, .{
        .net = s.in.net,
        .wave = s.wave,
        .emitted = false,
        .reason = if (demandOnly(s.in)) .demand_only else .no_path,
        .pitch_mm = pitch,
    });
}

/// The finer lattice a wave retries its stuck nets on: half the tightest pin
/// pitch they terminate on, floored at `min_pitch_mm`, never coarser than the
/// reference channel, and coarsened again if the state it implies would break
/// the memory budget.
///
/// Half is the Nyquist reading of the rule that actually fails on the reference
/// lattice — a cell CENTRE has to be able to land inside the gap between two
/// adjacent pads. On barracuda the reference channel is 0.93 mm, and the eight
/// J1 control escapes are exactly the geometry that hides under it.
///
/// A stuck net whose pads are all on passives has no pin pitch to read, and
/// still drops to the floor rather than being refused a retry: it has already
/// been shown to be unplannable at the reference channel, and the retry now
/// costs one commodity on an inherited background field. The pin pitch's job is
/// to stop a wave refining FURTHER than its geometry warrants, not to decide
/// whether a failure is worth a second look.
fn refinedPitch(run: Run, stuck: []const usize) f64 {
    if (run.params.pitch_mm != null) return run.chan;
    var tight = std.math.inf(f64);
    for (stuck) |slot_i| {
        for (run.geom.terms[slot_i]) |t| tight = @min(tight, t.pin_pitch);
    }
    const wanted = if (std.math.isFinite(tight))
        tight * run.params.refine.pin_pitch_scale
    else
        run.params.refine.min_pitch_mm;
    const want = @max(wanted, run.params.refine.min_pitch_mm);
    return @max(want, budgetPitch(run, stuck.len));
}

/// Coarsest pitch the per-pass state budget allows. `cells × commodities` is the
/// shape of the conductance/potential arrays, and cell count grows as `1/p²`, so
/// the floor has a closed form and needs no search. Only the retried nets count:
/// a refined pass carries no background commodities, having inherited the field
/// they would have produced.
fn budgetPitch(run: Run, commodities: usize) f64 {
    const active = commodities;
    const span_x = run.geom.maxx - run.geom.minx + 2 * grid_margin_mm;
    const span_y = run.geom.maxy - run.geom.miny + 2 * grid_margin_mm;
    const area = span_x * span_y * @as(f64, @floatFromInt(run.layers));
    const allowed = run.params.refine.max_cell_commodities / @as(f64, @floatFromInt(@max(1, active)));
    if (allowed <= 0) return run.chan;
    return @sqrt(area / allowed);
}

/// What every per-net step of one pass needs, bundled so the steps stay narrow.
const WaveCtx = struct {
    sim: *Sim,
    board: *Board,
    radius: f64,
    params: Params,
    run: *Run,
    /// One cell-sized scratch mask, reused by every stamp of the pass rather
    /// than allocated per net.
    touched: []bool,
};

fn recordNet(
    allocator: Allocator,
    ctx: WaveCtx,
    slot_i: usize,
    ai: usize,
    bone: Backbone,
) Allocator.Error!void {
    const slot = ctx.sim.slots[slot_i];
    var diag = NetDiag{
        .net = slot.in.net,
        .wave = slot.wave,
        .emitted = false,
        .reason = .no_terminals,
        .backbone_cells = bone.cells.len,
        .pitch_mm = ctx.board.p,
    };
    if (bone.ok) {
        const s = NetSolve{ .sim = ctx.sim, .slot_i = slot_i, .ai = ai, .params = ctx.params };
        // The alternative-corridor search has to start from the same escape
        // halo the backbone search had. Without it the source pad's own cell is
        // under-width, no edge out of it is live, every alternative reads
        // UNREACHABLE, and the gate scores 1.0 for every net — which is exactly
        // the "make every net look unique" failure `corridorMask` keeps
        // terminal breathing room to avoid. Measured on barracuda: 4 of the 5
        // guides the control-escape wave emitted scored a flat 1.0.
        loadNet(ctx.sim, slot_i);
        diag.confidence = try confidenceOf(allocator, s, bone, ctx.radius);
        unloadNet(ctx.sim, slot_i);
        // Even a net that gets no guide still OCCUPIES its corridor. The stamp
        // is kept in WORLD space and replayed onto every later lattice, so a
        // wave that refines its pitch still sees what earlier waves took.
        const st = try stampOf(allocator, ctx.board.*, slot, bone);
        try ctx.run.stamps.append(allocator, st);
        applyStamp(ctx.board, st, ctx.touched);
        // Consuming capacity can put a cell below a net's cross-section, so the
        // admission table has to follow `free` down. The nets of THIS wave are
        // extracted one after another and each sees the previous ones' corridor
        // gone — which is what pushes the second of two contenders through the
        // other gap.
        buildUsable(ctx.sim);
    }
    diag.reason = classify(slot, bone, ctx.sim.terms[slot_i].cells.len, diag.confidence, ctx.params);
    diag.emitted = diag.reason == .emitted;
    if (diag.emitted) try emitGuides(allocator, ctx.board.*, slot, bone, ctx.run.out);
    try ctx.run.out.diags.append(allocator, diag);
}

fn classify(slot: Slot, bone: Backbone, terminals: usize, confidence: f64, params: Params) Reason {
    if (slot.in.is_plane_carried) return .plane_carried;
    if (demandOnly(slot.in)) return .demand_only;
    if (terminals < 2) return .no_terminals;
    if (!bone.ok) return .no_path;
    if (confidence < params.guide.confidence_min) return .low_confidence;
    return .emitted;
}

fn emitGuides(
    allocator: Allocator,
    board: Board,
    slot: Slot,
    bone: Backbone,
    out: *Output,
) Allocator.Error!void {
    const before = out.vias.items.len;
    for (bone.branches) |path| try emitBranch(allocator, board, slot, path, out);
    if (out.vias.items.len == before) try emitCorridorVias(allocator, board, slot, bone, out);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// One 1 mm block of the wall: a through-hole pad, so it is an obstacle on
/// EVERY layer and a net cannot simply via around it.
const wall_pad = [_]geometry.Pad{
    .{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 1.0, .thru = true },
};

fn wallPart(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &wall_pad,
        .fallback = false,
        .x = x,
        .y = y,
    };
}

const term_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};

fn termPart(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.3,
        .hh = 0.3,
        .pads = &term_pad,
        .fallback = false,
        .x = x,
        .y = y,
    };
}

/// A wall at x = 10 spanning y = 0..20 in 1 mm blocks, with the rows named in
/// `gaps` left out. Terminals sit either side at the given y positions.
fn wallFixture(
    allocator: Allocator,
    gaps: []const usize,
    lefts: []const f64,
    rights: []const f64,
) Allocator.Error![]optimizer.Part {
    var parts: std.ArrayList(optimizer.Part) = .empty;
    for (0..20) |row| {
        if (containsUsize(gaps, row)) continue;
        const name = try std.fmt.allocPrint(allocator, "W{d}", .{row});
        const y = @as(f64, @floatFromInt(row)) + 0.5;
        try parts.append(allocator, wallPart(name, 10, y));
    }
    for (lefts, 0..) |y, i| {
        const name = try std.fmt.allocPrint(allocator, "L{d}", .{i});
        try parts.append(allocator, termPart(name, 2, y));
    }
    for (rights, 0..) |y, i| {
        const name = try std.fmt.allocPrint(allocator, "R{d}", .{i});
        try parts.append(allocator, termPart(name, 18, y));
    }
    return parts.toOwnedSlice(allocator);
}

fn twoPinNet(
    allocator: Allocator,
    name: []const u8,
    a: []const u8,
    b: []const u8,
) Allocator.Error!flat_netlist.FlatNet {
    const pins = try allocator.alloc(flat_netlist.FlatPin, 2);
    pins[0] = .{ .ref_des = a, .pin = "1" };
    pins[1] = .{ .ref_des = b, .pin = "1" };
    return .{ .name = name, .pins = pins };
}

fn fixturePlacement(parts: []optimizer.Part, nets: []const flat_netlist.FlatNet) optimizer.Placement {
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
        .generated = true,
        // Without an outline the lattice's 1 mm apron reaches past the wall's
        // ends and every "sealed" fixture leaks around it.
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 },
    };
}

/// Fast test settings — the stability early-out normally fires well inside this.
const test_params = Params{ .budget = .{ .frames = 60, .stability_checks = 2 } };

/// The y a net's guide is at where it crosses the wall — i.e. which gap it
/// took. Interpolated, since simplification leaves long diagonal segments.
fn guideBand(p: Plan, net: i32) ?f64 {
    for (p.tracks) |t| {
        if (t.net != net) continue;
        if (@min(t.x1, t.x2) > 10 or @max(t.x1, t.x2) < 10) continue;
        if (t.x2 == t.x1) return (t.y1 + t.y2) / 2;
        return t.y1 + (10 - t.x1) / (t.x2 - t.x1) * (t.y2 - t.y1);
    }
    return null;
}

fn diagFor(p: Plan, net: usize) ?NetDiag {
    for (p.diags) |d| {
        if (d.net == net) return d;
    }
    return null;
}

fn countVias(p: Plan, net: i32) usize {
    var n: usize = 0;
    for (p.vias) |v| {
        if (v.net == net) n += 1;
    }
    return n;
}

fn maxLayer(p: Plan, net: i32) u8 {
    var m: u8 = 0;
    for (p.tracks) |t| {
        if (t.net == net) m = @max(m, t.layer);
    }
    return m;
}

// spec: Topology planner - two nets contending for two gaps are planned through different gaps
test "two contended nets take different gaps" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Both nets sit just above the row-5 gap, so both PREFER it and the row-14
    // gap is a long detour. The gap is one lattice cell wide and each net needs
    // 0.6 mm of a 0.8 mm cell, so it cannot hold both: only mutual congestion
    // can decide which net pays the detour.
    //
    // Both are pinned to ONE layer, because a backbone consumes capacity only on
    // the layer it runs on: with both layers open the honest answer to this
    // contention is for the second net to take the same gap on the other layer,
    // which is a different (and equally correct) separation from the one this
    // test is about.
    const parts = try wallFixture(arena, &.{ 5, 14 }, &.{ 7.0, 8.2 }, &.{ 7.0, 8.2 });
    const nets = [_]flat_netlist.FlatNet{
        try twoPinNet(arena, "A", "L0", "R0"),
        try twoPinNet(arena, "B", "L1", "R1"),
    };
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{
        .{ .net = 0, .width = 0.2, .clearance = 0.2, .allowed_layers = 0b1 },
        .{ .net = 1, .width = 0.2, .clearance = 0.2, .allowed_layers = 0b1 },
    } }};

    const p = try plan(arena, &placement, &wave, test_params);
    const a = guideBand(p, 0) orelse return error.NoGuideForA;
    const b = guideBand(p, 1) orelse return error.NoGuideForB;
    // Different gaps: the two bands must be on opposite sides of the wall's
    // midline, not merely a fraction of a millimetre apart.
    try testing.expect(@abs(a - b) > 5.0);
}

// spec: Topology planner - a lone net is planned through the shorter of two unequal detours
test "a lone net takes the shorter gap" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Gaps at rows 5 and 18; the terminals sit at y = 5.5, so the row-5 gap is
    // a straight shot and the row-18 gap is a long detour.
    const parts = try wallFixture(arena, &.{ 5, 6, 17, 18 }, &.{6.0}, &.{6.0});
    const nets = [_]flat_netlist.FlatNet{try twoPinNet(arena, "A", "L0", "R0")};
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{.{ .net = 0, .width = 0.2, .clearance = 0.2 }} }};

    const p = try plan(arena, &placement, &wave, test_params);
    const band = guideBand(p, 0) orelse return error.NoGuide;
    try testing.expect(band < 9.0);
}

// spec: Topology planner - a net whose terminals no open corridor joins is refused a guide and told why
test "a sealed net gets no guide and a no_path diagnosis" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A solid wall: no gap rows at all.
    const parts = try wallFixture(arena, &.{}, &.{10.0}, &.{10.0});
    const nets = [_]flat_netlist.FlatNet{try twoPinNet(arena, "A", "L0", "R0")};
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{.{ .net = 0, .width = 0.2, .clearance = 0.2 }} }};

    const p = try plan(arena, &placement, &wave, test_params);
    try testing.expectEqual(@as(usize, 0), p.tracks.len);
    const d = diagFor(p, 0) orelse return error.NoDiag;
    try testing.expect(!d.emitted);
    try testing.expectEqual(Reason.no_path, d.reason);
}

// spec: Topology planner - a net restricted to one layer is planned on that layer with no guide vias
test "a single-allowed-layer net stays on its layer and gets no vias" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try wallFixture(arena, &.{ 5, 6, 15, 16 }, &.{6.0}, &.{6.0});
    const nets = [_]flat_netlist.FlatNet{try twoPinNet(arena, "A", "L0", "R0")};
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{
        .{ .net = 0, .width = 0.2, .clearance = 0.2, .allowed_layers = 0b1 },
    } }};

    const p = try plan(arena, &placement, &wave, test_params);
    try testing.expect(p.tracks.len > 0);
    try testing.expectEqual(@as(u8, 0), maxLayer(p, 0));
    // Vias are illegal for this net anyway (router.layerInMask is a hard gate),
    // so emitting none cannot trigger `reference_off_via_mult`.
    try testing.expectEqual(@as(usize, 0), countVias(p, 0));
}

// spec: Topology planner - a guided net that may change layer never receives tracks without vias
test "a guided net allowed to via always carries guide vias" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try wallFixture(arena, &.{ 5, 6, 15, 16 }, &.{6.0}, &.{6.0});
    const nets = [_]flat_netlist.FlatNet{try twoPinNet(arena, "A", "L0", "R0")};
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{.{ .net = 0, .width = 0.2, .clearance = 0.2 }} }};

    const p = try plan(arena, &placement, &wave, test_params);
    try testing.expect(p.tracks.len > 0);
    try testing.expect(countVias(p, 0) > 0);
}

// spec: Topology planner - planning the same board twice yields structurally identical guides and diagnoses
test "planning the same input twice is identical" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try wallFixture(arena, &.{ 5, 14 }, &.{ 7.0, 8.2 }, &.{ 7.0, 8.2 });
    const nets = [_]flat_netlist.FlatNet{
        try twoPinNet(arena, "A", "L0", "R0"),
        try twoPinNet(arena, "B", "L1", "R1"),
    };
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{
        .{ .net = 0, .width = 0.2, .clearance = 0.2 },
        .{ .net = 1, .width = 0.2, .clearance = 0.2 },
    } }};

    const a = try plan(arena, &placement, &wave, test_params);
    const b = try plan(arena, &placement, &wave, test_params);
    try expectPlansIdentical(a, b);
}

/// All loops live here so the test body above stays linear.
fn expectPlansIdentical(a: Plan, b: Plan) !void {
    try testing.expectEqual(a.tracks.len, b.tracks.len);
    try testing.expectEqual(a.vias.len, b.vias.len);
    try testing.expectEqual(a.diags.len, b.diags.len);
    try testing.expectEqual(a.pitch_mm, b.pitch_mm);
    for (a.tracks, b.tracks) |x, y| {
        try testing.expectEqual(x.x1, y.x1);
        try testing.expectEqual(x.y1, y.y1);
        try testing.expectEqual(x.x2, y.x2);
        try testing.expectEqual(x.y2, y.y2);
        try testing.expectEqual(x.layer, y.layer);
        try testing.expectEqual(x.net, y.net);
    }
    for (a.vias, b.vias) |x, y| {
        try testing.expectEqual(x.x, y.x);
        try testing.expectEqual(x.y, y.y);
        try testing.expectEqual(x.net, y.net);
    }
    for (a.diags, b.diags) |x, y| {
        try testing.expectEqual(x.net, y.net);
        try testing.expectEqual(x.wave, y.wave);
        try testing.expectEqual(x.emitted, y.emitted);
        try testing.expectEqual(x.reason, y.reason);
        try testing.expectEqual(x.confidence, y.confidence);
        try testing.expectEqual(x.backbone_cells, y.backbone_cells);
    }
}

// spec: Topology planner - a later wave is planned around the corridor an earlier wave's backbone consumed
test "a wave-2 net avoids the wave-1 corridor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try wallFixture(arena, &.{ 5, 14 }, &.{ 7.0, 8.2 }, &.{ 7.0, 8.2 });
    const nets = [_]flat_netlist.FlatNet{
        try twoPinNet(arena, "A", "L0", "R0"),
        try twoPinNet(arena, "B", "L1", "R1"),
    };
    const placement = fixturePlacement(parts, &nets);
    // Same geometry as the contention test, but the nets are in SEPARATE waves,
    // so net B is steered by the capacity net A's backbone consumed rather than
    // by simultaneous congestion. One layer each, for the same reason.
    const waves = [_]Wave{
        .{ .nets = &.{.{ .net = 0, .width = 0.2, .clearance = 0.2, .allowed_layers = 0b1 }} },
        .{ .nets = &.{.{ .net = 1, .width = 0.2, .clearance = 0.2, .allowed_layers = 0b1 }} },
    };

    const p = try plan(arena, &placement, &waves, test_params);
    const a = guideBand(p, 0) orelse return error.NoGuideForA;
    const b = guideBand(p, 1) orelse return error.NoGuideForB;
    try testing.expect(@abs(a - b) > 5.0);
}

// spec: Topology planner - a diff-pair member or authored-guide net consumes capacity but is never given a guide
test "demand-only nets consume space without receiving guides" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try wallFixture(arena, &.{ 5, 6, 15, 16 }, &.{ 6.0, 6.5 }, &.{ 6.0, 6.5 });
    const nets = [_]flat_netlist.FlatNet{
        try twoPinNet(arena, "PAIR", "L0", "R0"),
        try twoPinNet(arena, "AUTHORED", "L1", "R1"),
    };
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{
        .{ .net = 0, .width = 0.2, .clearance = 0.2, .is_diff_pair = true },
        .{ .net = 1, .width = 0.2, .clearance = 0.2, .has_authored_guide = true },
    } }};

    const p = try plan(arena, &placement, &wave, test_params);
    try testing.expectEqual(@as(usize, 0), p.tracks.len);
    try testing.expectEqual(@as(usize, 0), p.vias.len);
    try testing.expectEqual(@as(usize, 2), p.diags.len);
    try expectAllDemandOnly(p);
}

fn expectAllDemandOnly(p: Plan) !void {
    for (p.diags) |d| {
        try testing.expect(!d.emitted);
        try testing.expectEqual(Reason.demand_only, d.reason);
        // They still routed: a demand-only net occupies its corridor so the
        // nets planned alongside it see the space it takes.
        try testing.expect(d.backbone_cells > 0);
    }
}

/// One SURFACE pad (top side, not through-hole), so it blocks layer 0 and
/// leaves layer 1 open — a wall a net can only cross by changing layer.
const top_wall_pad = [_]geometry.Pad{
    .{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 1.0, .thru = false },
};

fn topWallPart(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &top_wall_pad,
        .fallback = false,
        .x = x,
        .y = y,
    };
}

/// A top-layer-only wall at x = 10 spanning y = 0..20, with one terminal either
/// side. The only route is: down through a via, across on layer 1, back up.
fn layerWallFixture(allocator: Allocator) Allocator.Error![]optimizer.Part {
    var parts: std.ArrayList(optimizer.Part) = .empty;
    for (0..20) |row| {
        const name = try std.fmt.allocPrint(allocator, "W{d}", .{row});
        try parts.append(allocator, topWallPart(name, 10, @as(f64, @floatFromInt(row)) + 0.5));
    }
    try parts.append(allocator, termPart("L0", 2, 10));
    try parts.append(allocator, termPart("R0", 18, 10));
    return parts.toOwnedSlice(allocator);
}

// spec: Topology planner - a backbone that must change layer does so exactly once each way, never flapping between layers
test "a two-layer backbone changes layer twice, not fourteen times" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try layerWallFixture(arena);
    const nets = [_]flat_netlist.FlatNet{try twoPinNet(arena, "A", "L0", "R0")};
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{.{ .net = 0, .width = 0.2, .clearance = 0.2 }} }};

    const p = try plan(arena, &placement, &wave, test_params);
    // Both layers are used, so these are REAL layer changes rather than the
    // corridor-mirroring vias a single-layer backbone emits.
    try testing.expectEqual(@as(u8, 1), maxLayer(p, 0));
    // Down and back up. Without an explicit per-layer-change price in the
    // extraction, flow spread over both layers makes flapping free — measured on
    // barracuda as fourteen changes on one control net's 102-cell backbone.
    try testing.expectEqual(@as(usize, 2), countVias(p, 0));
}

/// Two blocking slabs at x = 10 leaving a horizontal channel `gap` mm tall,
/// centred on y = 10, with a terminal either side of the wall.
const slot_slab_pad = [_]geometry.Pad{
    .{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 10.0, .thru = true },
};

fn slotFixture(allocator: Allocator, gap: f64) Allocator.Error![]optimizer.Part {
    const slab = struct {
        fn make(ref: []const u8, y: f64) optimizer.Part {
            return .{
                .ref_des = ref,
                .kind = .passive,
                .hw = 0.5,
                .hh = 5.0,
                .pads = &slot_slab_pad,
                .fallback = false,
                .x = 10,
                .y = y,
            };
        }
    };
    var parts: std.ArrayList(optimizer.Part) = .empty;
    try parts.append(allocator, slab.make("WLO", 10 - gap / 2 - 5));
    try parts.append(allocator, slab.make("WHI", 10 + gap / 2 + 5));
    try parts.append(allocator, termPart("L0", 2, 10));
    try parts.append(allocator, termPart("R0", 18, 10));
    return parts.toOwnedSlice(allocator);
}

// spec: Topology planner - a channel narrower than a net's own cross-section is not a corridor, however finely the lattice resolves it
test "a sub-cross-section channel is refused at every resolution" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A 0.4 mm slot for a net whose trace plus both clearances is 0.6 mm. The
    // slot runs clear through the wall, so a measure that took the LONGER open
    // run through a cell (or the cell's open AREA) would call it a corridor.
    const parts = try slotFixture(arena, 0.4);
    const nets = [_]flat_netlist.FlatNet{try twoPinNet(arena, "A", "L0", "R0")};
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{.{ .net = 0, .width = 0.2, .clearance = 0.2 }} }};

    const p = try plan(arena, &placement, &wave, test_params);
    const d = diagFor(p, 0) orelse return error.NoDiag;
    try testing.expectEqual(Reason.no_path, d.reason);
    try testing.expectEqual(@as(usize, 0), p.tracks.len);
}

// spec: Topology planner - a channel at least a net's cross-section wide carries it
test "a channel as wide as the cross-section is a corridor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try slotFixture(arena, 1.2);
    const nets = [_]flat_netlist.FlatNet{try twoPinNet(arena, "A", "L0", "R0")};
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{.{ .net = 0, .width = 0.2, .clearance = 0.2 }} }};

    const p = try plan(arena, &placement, &wave, test_params);
    const band = guideBand(p, 0) orelse return error.NoGuide;
    try testing.expect(@abs(band - 10) < 1.5);
}

// spec: Topology planner - a net no reference-pitch corridor joins is replanned on a finer lattice, and every diagnosis names the pitch it was planned on
test "a stuck net is retried on a finer lattice" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try slotFixture(arena, 0.4);
    const nets = [_]flat_netlist.FlatNet{try twoPinNet(arena, "A", "L0", "R0")};
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{.{ .net = 0, .width = 0.2, .clearance = 0.2 }} }};

    const p = try plan(arena, &placement, &wave, test_params);
    const d = diagFor(p, 0) orelse return error.NoDiag;
    // The verdict is the same either way (the slot is genuinely too narrow),
    // but the pitch on the diagnosis proves the finer look actually happened.
    try testing.expect(d.pitch_mm < p.pitch_mm);
}

// spec: Topology planner - pinning the lattice pitch plans every wave on it and suppresses refinement
test "a pinned pitch suppresses the finer retry" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try slotFixture(arena, 0.4);
    const nets = [_]flat_netlist.FlatNet{try twoPinNet(arena, "A", "L0", "R0")};
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{.{ .net = 0, .width = 0.2, .clearance = 0.2 }} }};

    var pinned = test_params;
    pinned.pitch_mm = 0.8;
    const p = try plan(arena, &placement, &wave, pinned);
    const d = diagFor(p, 0) orelse return error.NoDiag;
    try testing.expectEqual(@as(f64, 0.8), p.pitch_mm);
    try testing.expectEqual(@as(f64, 0.8), d.pitch_mm);
}

// spec: Topology planner - a net a copper plane carries is never relaxed and is diagnosed as plane-carried
test "a plane-carried net is skipped rather than planned" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts = try wallFixture(arena, &.{ 5, 6, 15, 16 }, &.{ 6.0, 6.5 }, &.{ 6.0, 6.5 });
    const nets = [_]flat_netlist.FlatNet{
        try twoPinNet(arena, "GND", "L0", "R0"),
        try twoPinNet(arena, "SIG", "L1", "R1"),
    };
    const placement = fixturePlacement(parts, &nets);
    const wave = [_]Wave{.{ .nets = &.{
        .{ .net = 0, .width = 0.2, .clearance = 0.2, .is_plane_carried = true },
        .{ .net = 1, .width = 0.2, .clearance = 0.2 },
    } }};

    const p = try plan(arena, &placement, &wave, test_params);
    const gnd = diagFor(p, 0) orelse return error.NoDiag;
    try testing.expect(!gnd.emitted);
    try testing.expectEqual(Reason.plane_carried, gnd.reason);
    // Not merely refused a guide — never relaxed at all, so it has no backbone
    // and took no channel from the net planned beside it.
    try testing.expectEqual(@as(usize, 0), gnd.backbone_cells);
    try testing.expectEqual(@as(usize, 0), countVias(p, 0));
}
