//! The gap closer's caller-facing contract — the request/response types and the
//! rip-up ladder policy for `router.closeGaps`.
//!
//! `router.route` answers "route this board from scratch". `closeGaps` answers
//! the other question a nearly-finished board asks: "the persisted copper leaves
//! these same-net pads in different islands — put down the metal that joins
//! them, and disturb nothing else." Two shapes of request:
//!
//!   * a BRIDGE (`Gap.to` set) — maze a path between two pads, against the
//!     board's real copper; and
//!   * a STITCH (`Gap.to` null) — drop one plane/pour via beside a pad, which
//!     is how a plane-carried pad rejoins its net (a surface trace to its twin
//!     would be the wrong answer and usually impossible between QFN pads).
//!
//! Every hop is INDEPENDENT and reports its own copper, so the caller can
//! verify each against the connectivity oracle and keep only the ones that
//! actually merged islands (the router cannot see the pour engine's credit
//! rules, so a via that lands where a higher-priority pour clips it is the
//! caller's to reject). Failed hops leave no copper at all.
//!
//! Split out of `router.zig`: this is what a CALLER of the gap pass builds and
//! reads, with none of the maze machinery that services it. It names the
//! router's plain copper/terminal types, so it sits above `router.zig` (unlike
//! `route_policy.zig`, which is deliberately router-neutral and sits below).

const std = @import("std");
const router = @import("router.zig");
const route_policy = @import("route_policy.zig");

const Track = router.Track;
const Via = router.Via;
const NetPt = router.NetPt;

/// One island-joining request for `closeGaps`.
pub const Gap = struct {
    /// Flattened-net index (into `placement.nets`) the hop belongs to.
    net_i: usize,
    /// The pad the hop starts from.
    from: NetPt,
    /// The far pad to bridge to, or null to ask for a plane/pour STITCH via
    /// beside `from` — how a plane-carried pad rejoins its net.
    to: ?NetPt = null,
    /// A plane/pour stitch's pad-to-pad escape hatch. The stitch remains the
    /// first choice; only when no legal via/stub can be produced does the gap
    /// closer bridge to this terminal instead. Keeping the oracle's original
    /// endpoint matters for a surface pad beside a clipped or crowded pour:
    /// throwing it away turns a short, legal trace into a permanent open.
    stitch_fallback: ?NetPt = null,
};

/// The persisted copper a gap pass routes against: everything already on the
/// board, plus the retained pours (so a same-net pour is a terminal and a
/// foreign one is measured for clearance exactly as a fresh route would).
pub const GapBoard = struct {
    tracks: []const Track = &.{},
    vias: []const Via = &.{},
    zones: []const route_policy.ExistingZone = &.{},
    /// Corridors an authored `(assign-escapes … (reserve))` holds for their own
    /// nets. Not copper — nothing is drilled or plated there — but a hop has to
    /// route around them for the same reason the route did, or the pass that
    /// closes the last gaps is the one that undoes the plan. Empty for every
    /// caller today, so every hop stays byte-identical (`lane_reserve`).
    reserved_lanes: []const route_policy.ReservedLane = &.{},
};

/// The copper one hop needs. `ripped` names the `GapBoard.tracks` indices the
/// hop had to remove to get through — the caller must delete exactly those
/// (they are foreign copper, so the net they belonged to opens up and comes
/// back as a gap of its own on the caller's next pass).
pub const GapPath = struct {
    tracks: []const Track = &.{},
    vias: []const Via = &.{},
    ripped: []const usize = &.{},
    /// The nets whose copper `ripped` belonged to (empty when nothing was
    /// ripped), so the caller can repair each inside the same transaction and
    /// roll the whole thing back when a repair fails. More than one because a
    /// wide bridge is often walled by several trunks at once and clearing any
    /// ONE of them leaves the others still across the corridor — the hop then
    /// reports `blocked` against a channel no single rip could ever have
    /// opened (see `ripPathBlockers`).
    ripped_nets: []const i32 = &.{},
};

/// What became of one requested hop, reported the moment it finishes. A
/// finishing pass on a full board spends minutes inside `closeGaps`, so without
/// a per-hop report the caller cannot tell a slow board from a hung one, nor
/// which net ate the time. Timing is deliberately the caller's job — the event
/// arrives at the hop boundary, so consecutive clock reads in the sink measure
/// each hop without the router reaching for a wall clock.
pub const GapEvent = struct {
    /// Index into the `gaps` slice the caller passed.
    index: usize,
    /// True when the hop produced copper (the caller still judges whether to
    /// keep it — see the module header).
    landed: bool,
    /// Foreign tracks the hop had to rip to get through.
    ripped: usize,
    /// Why the hop ended the way it did.
    why: GapReason = .routed,
};

/// How a hop ended. The three failure shapes want completely different remedies,
/// and a bare "no path" hides which one applies: a SEALED pad is a placement /
/// escape problem no amount of routing effort fixes, while a blocked channel is
/// a congestion problem more rip-up or a different order can still solve.
pub const GapReason = enum {
    /// Copper was produced.
    routed,
    /// The start pad has no legal way onto the grid at all.
    sealed_from,
    /// The far pad has no legal way onto the grid at all.
    sealed_to,
    /// Both pads are reachable, but the maze drained its frontier without
    /// meeting the far pad: no legal path joins them on this board.
    blocked,
    /// The maze ran out of node-expansion budget before draining its frontier.
    /// A route may well exist — this says the search, not the board, gave up,
    /// which is a different remedy (coarser raster, or a shorter hop first).
    exhausted,
    /// A stitch found no via site near the pad (inside its own pour, when it
    /// owns one) that keeps clearance from copper and drills.
    no_via_site,
    /// The hop names a net index that is not in this placement's netlist, so
    /// the pass skipped it without attempting anything. A stale gap list or a
    /// caller-side indexing bug — never a verdict about the board. It exists so
    /// a SKIPPED hop reports its own state instead of inheriting the previous
    /// hop's diagnosis (which read `routed` on a hop that produced no copper).
    no_such_net,
};

/// Where a gap pass reports each hop as it finishes.
pub const GapSink = struct {
    ctx: ?*anyopaque,
    emit: *const fn (ctx: ?*anyopaque, ev: GapEvent) void,
};

/// A caller's veto on each landed hop, consulted BEFORE the batch takes the
/// copper onto its live board.
///
/// A gap pass routes every later hop of a round against the copper its earlier
/// hops laid — that is the point, so two hops never claim the same channel. But
/// the router does not own the decision of whether a hop *earns* its copper:
/// the caller does, through the connectivity oracle and the DRC gate. Without
/// this seam the two disagree. The pass absorbs a path the caller then rolls
/// back, and every remaining hop in the round is routed against copper that
/// never lands — reporting `blocked` against a phantom, which is how a long hop
/// that is perfectly routable on the board as it ends up gets refused.
///
/// `keep` returns false to drop the path, leaving the board (and the rip marks
/// the path asked for) exactly as the previous hop left it. The path is still
/// returned to the caller either way, so a vetoed hop stays distinguishable
/// from one that found no path at all.
pub const GapJudge = struct {
    ctx: ?*anyopaque,
    keep: *const fn (ctx: ?*anyopaque, index: usize, path: GapPath) bool,
};

/// A bounded world-mm rectangle one gap pass may search inside.
///
/// The gap raster is otherwise the WHOLE board re-gridded at `grid_divisor`, so
/// each finer rung costs the square of the divisor over the entire placement:
/// on board-a divisor 4 is ~433k cells per layer, and a divisor-8 rung built
/// that way ran for over 50 minutes without returning and had to be removed.
/// But a hop that fails on a lattice problem needs resolution only in its OWN
/// corridor — the copper twenty millimetres away is irrelevant to it. Bounding
/// the region makes the finer rung affordable: the same corridor at divisor 8
/// is a fraction of one board-wide divisor-4 grid, which is what turns "the
/// board demonstrably has a path our lattice cannot represent" into a hop we
/// can actually re-ask.
pub const GapWindow = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,

    /// The window enclosing a hop's terminals, grown by `margin` on each side.
    /// A stitch (no far terminal) is a square around its single pad.
    pub fn around(gap: Gap, margin: f64) GapWindow {
        const to = gap.to orelse gap.stitch_fallback orelse gap.from;
        return .{
            .x0 = @min(gap.from.x, to.x) - margin,
            .y0 = @min(gap.from.y, to.y) - margin,
            .x1 = @max(gap.from.x, to.x) + margin,
            .y1 = @max(gap.from.y, to.y) + margin,
        };
    }
};

/// The raster one gap pass searches on.
pub const Raster = struct {
    /// Divisor on the BASE grid pitch for this call's refined gap raster
    /// (default `gap_grid_divisor`). Raising it is for re-asking a hop that
    /// failed at the standard gap pitch on a lattice problem rather than a
    /// congestion problem: two minimum-width tracks legally 0.254 mm apart
    /// centre-to-centre cannot sit on adjacent lanes of a grid whose pitch is
    /// a hair under that, so a corridor that physically holds two routes holds
    /// only one *representable* one — the next lane out doubles the spacing
    /// and misses the corridor. The node and expansion ceilings scale with the
    /// divisor squared (`scaledGapCeiling`), so a finer call pays its own cost
    /// and a board whose divisor-2 raster fit its budget always fits the finer
    /// one's scaled budget too.
    divisor: f64 = gap_grid_divisor,
    /// Search only inside this world-mm rectangle (see `GapWindow`). Null — the
    /// default — rasters the whole board, which is what an ordinary round wants.
    /// A corridor is for re-asking ONE hop at a resolution the board-wide raster
    /// could never afford.
    window: ?GapWindow = null,
    /// Multiplier on the gap pass's node-expansion ceiling. The raster's node
    /// allocation is unchanged; this only lets an explicitly bounded endgame
    /// search drain more of the graph it already owns. One is the established
    /// behavior. Callers cap expensive uses by residual width and spend count.
    expansion_multiplier: usize = 1,
    /// The containing board transaction's absolute stop conditions. A gap
    /// maze can consume its full expansion budget before returning, so checking
    /// only between gaps does not enforce a wall-clock route deadline.
    stop: route_policy.Stop = .{},
};

/// Knobs a caller can turn on one gap pass.
pub const GapOptions = struct {
    /// Allow ripping foreign copper out of a sealed pad's escape and retrying.
    ripup: bool = true,
    /// Where on the rip-up ladder to start (0 = the narrowest rip, `rip_tiers-1`
    /// = clear the aggressor outright). A caller whose accept gate rejected a
    /// hop *only* because the rip's victim could not be repaired re-asks one
    /// rung higher: the rip was too SMALL, not too big — a partial rip leaves
    /// the victim as two stubs that must thread the channel the rescued net
    /// just took, while a wider one lets it re-route freely.
    rip_from: usize = 0,
    /// Which tiers this call may draw a hop with (see `ShapeTier`).
    shape: ShapeTier = .fallback,
    /// Optional per-hop progress report (see `GapSink`).
    sink: ?GapSink = null,
    /// Optional per-hop accept veto (see `GapJudge`). Absent = keep every path,
    /// which is the whole-board router's behaviour.
    judge: ?GapJudge = null,
    /// Optional filter on which nets a rip may take copper from (see
    /// `RipFilter`). Absent = any foreign net.
    rip_filter: ?RipFilter = null,
    /// Whether a hop may put its escape via on its own terminal pad (see
    /// `TerminalVia`). Default: no, on every pad.
    terminal_via: TerminalVia = .banned,
    /// The raster this call searches on: how fine, and how much of the board
    /// (see `Raster`).
    raster: Raster = .{},
};

/// Which of the two hop tiers a gap pass may draw with — the raster maze, the
/// gridless shape router, or both.
///
/// They are not interchangeable and the choice is never about effort. The maze
/// searches a lattice, so a channel narrower than its pitch, or one that only
/// opens by diving to another layer, is not a path it can REPRESENT however much
/// budget it is handed; the mesh has no lattice and answers in geometry. A caller
/// picks a tier when it already knows one of those answers.
pub const ShapeTier = enum {
    /// The maze alone. What a given `raster.divisor` can and cannot see is a
    /// property of the lattice, and measuring it needs the other tier out of the
    /// way.
    off,
    /// The maze, with the mesh behind it — the default, because the corridor the
    /// mesh finds is a real one the lattice merely cannot address, and a hop the
    /// maze can draw costs nothing to ask it first. (`closeOneGap` swaps the two
    /// for a long hop, where the maze is the treadmill; both still run.)
    fallback,
    /// The MESH alone: no maze, and no rip-up ladder behind it.
    ///
    /// For a caller that has already mazed this exact connection and needs the
    /// other tier's answer rather than a second lattice search. The per-target
    /// unblock transaction's victim restore is one — a scoped whole-board route
    /// has just failed to put a ripped net back, and the question left is whether
    /// a channel exists that no lattice can address.
    only,

    /// May this call draw with the gridless mesh at all?
    pub fn meshes(self: ShapeTier) bool {
        return self != .off;
    }
};

/// May a hop drop a via on its OWN terminal pad?
pub const TerminalVia = enum {
    /// No — the pad and its via-clearance halo are off limits at both ends.
    /// The default, and what every ordinary gap round uses.
    banned,
    /// Only inside a THROUGH-HOLE terminal; an SMD terminal is free.
    ///
    /// Measured on board-a's J1, a 0.635 mm-pitch bottom-side board-to-board
    /// row: the lane between two adjacent pads is 0.285 mm, narrower than a
    /// minimum track plus two clearances (0.381 mm), so nothing can leave such
    /// a pad sideways — the only exit is a via at the pad. Every net that IS
    /// routed off that row on the finished board uses one (`SPI_MISO` 0.225 mm
    /// past the pad edge, `LOCK_DET` 0.09 mm INSIDE it), and the whole-board
    /// router put them there. Under `banned`, `closeGaps` cannot escape that
    /// row at all: every hop starting on it comes back `blocked` — on the
    /// congested board and on one with the entire blocking corridor stripped
    /// out alike, which is why no amount of rip-up or re-ordering ever closed
    /// `SPI_LMX_CSN`. With this, the same hop routes.
    ///
    /// It is nonetheless OPT-IN, because it is not free: made the default for
    /// every hop of a whole `close_open_nets` pass it shifts which copper wins
    /// each contested channel from round 0 onward, and on board-a's pour
    /// priority-6 fixture that cost a net (87/90 → 86/90, `V_6VA` newly open)
    /// while the DRC gate held at 11/8. So the escape is offered to the passes
    /// that need it — a targeted re-route of one stuck net — and the ordinary
    /// rounds keep the copper they already earn.
    smd_ok,

    /// Is `pt` a terminal this policy bans a via inside?
    pub fn bans(self: TerminalVia, pt: NetPt) bool {
        return self == .banned or pt.thru;
    }
};

/// A caller's say in WHICH nets a rip may take copper from, consulted while the
/// aggressors are being nominated.
///
/// The caller's accept gate can already throw out a finished rip it dislikes,
/// but by then the sweeps are paid for — and worse, the rip-up ladder has spent
/// its whole candidate budget (`ripup_max_nets`) on nets it was never going to
/// be allowed to keep, so the aggressor it COULD have moved is never even
/// nominated. Filtering at nomination costs nothing and turns "reject three
/// candidates" into "try three usable ones".
pub const RipFilter = struct {
    ctx: ?*anyopaque,
    rippable: *const fn (ctx: ?*anyopaque, net: i32, routing: i32) bool,
};

/// Rungs on the rip-up ladder (see `GapOptions.rip_from`). One past the reach
/// ladder: the extra top rung is the WIDE rip (see `ripupHop`).
pub const rip_tiers: usize = ripup_reaches.len + 1;

/// How many nets one rip may take.
///
/// The multi-net rip is deliberately NOT part of a hop's first attempt. It is
/// an extra maze sweep on every hop that fails, and on a board where most
/// failing hops are failing for reasons no rip addresses that is pure cost —
/// measured on board-a, running the unions up front added ~50% to the pass's
/// wall clock and changed not one net. So the first attempt stays exactly as
/// cheap as it was, and the breadth only opens up once the caller has escalated
/// (`GapOptions.rip_from`), which it does only for a hop whose narrow rip was
/// rejected because its victim could not be repaired.
pub const RipBreadth = enum {
    /// Each candidate blocker alone. The first attempt.
    singles_only,
    /// Every candidate alone first (cheapest, least to repair), then all of
    /// them together.
    singles_then_union,
    /// Only all of them together. The singles have already been tried and the
    /// verdict came back "the rip was too small", so re-running them is pure
    /// cost.
    union_only,

    /// The breadth a hop starting at rung `rip_from` of the ladder may use.
    pub fn forTier(rip_from: usize) RipBreadth {
        if (rip_from >= ripup_reaches.len) return .union_only;
        return if (rip_from == 0) .singles_only else .singles_then_union;
    }
};

/// How far from either terminal pad foreign copper counts as "sealing the
/// escape" and becomes a rip-up candidate. Tried smallest-first: the common
/// case is a single segment lying across a fine-pitch pad's exit lane.
///
/// The last tier is deliberately the WHOLE aggressor net (`inf`), not a wider
/// annulus, and it is the one that actually closes the hard nets. A partial rip
/// leaves the victim as two stubs with a hole in the middle, so its repair has
/// to thread the exact channel the rescued net has just taken — usually
/// impossible. Clearing the aggressor outright lets the repair pick a different
/// route entirely, which is what "rip up and REORDER" means: the blocked net
/// routes first, the aggressor re-routes around the result.
pub const ripup_reaches = [_]f64{ 0.6, 1.2, 2.0, std.math.inf(f64) };

/// Divisor on the base grid pitch for a gap pass. A finishing pass routes a
/// handful of legs on a board that is otherwise FULL, so the two things a
/// coarse grid costs it are decisive: a channel narrower than one pitch is
/// invisible, and every stamped obstacle carries a `g·√2/2` diagonal-safety
/// margin (see `stampBoardCopper`) that widens with the pitch. Halving the
/// pitch halves that margin and doubles the channels the maze can see, for 4×
/// the nodes — a trade a whole-board run could not afford and this one can.
pub const gap_grid_divisor: f64 = 2;

// ── Last-K adaptive rungs ───────────────────────────────────────────────────
//
// Several finishing tiers carry rungs that are BUILT but switched off, always
// for the same reason: they cost far too much when many nets are still open,
// and their pay-off is concentrated in the endgame. Two live in the router's
// own fine-window classifier (`router.residualIsGridQuantized`) — an
// over-budget flood is refused outright, and a residual whose reachable region
// is bounded by RIPPABLE copper is refused as "congestion for rip-up to solve".
// Two more live in the post-route gap closer (`mcp_close_gaps`'s
// `max_repair_rip_depth` and its cap one rung below `rip_tiers`).
//
// Both refusals are correct in the middle of a route and stale at the end of
// it. "Leave it to rip-up" has no meaning once the rip ladder has run and
// failed, and "the flood was capped so we do not know" is a reason to spend
// more, not less, when there are three nets left rather than thirty. So the
// arming is made ADAPTIVE and the count is the control: below `LastK.nets`
// still-failed nets the expensive rungs come on; above it nothing changes and
// the tier is byte-identical to what it was.
//
// The policy is pure and lives here so every ladder — the router's fine rescue
// and the gap closer's rip tiers alike — arms on ONE rule instead of each
// growing its own threshold. (The closer's own two constants still spell its
// rungs; `LastKRungs.wide_rip` is the value it reads to adopt this rule.)
//
// ## What the rungs are worth, measured
//
// `bench-route`, ReleaseSafe, against `05e365c`, over the four corpus boards
// with real headroom, with the threshold lifted so every one of them armed:
//
//   * BOTH rungs: black-canyon 50 → 51, everything else unchanged, for
//     board-a +8.9 s (+72 %), black-canyon +4.6 s, xband +5.6 s, straps
//     +29.9 s (+98 %).
//   * `rippable_frontier` ALONE: **no** net anywhere, board-a +8.8 s,
//     black-canyon +3.0 s, straps +1.5 s. It is never armed for that reason.
//   * `capped_flood` ALONE: black-canyon's net, board-a −0.2 s (its residual
//     has no capped flood at all), straps +26.7 s, xband +5.5 s.
//   * `capped_flood` + `spenders = 4`: black-canyon's net kept at +1.0 s
//     (+8.3 %), board-a −0.1 s, xband +0.04 s, straps +5.7 s — the per-board
//     spend cap cuts the one board that pays by 4.7x while the win survives.
//
// So: one rung, gated on the residual's WIDTH and capped by how many of its
// nets may spend it. Neither bound alone is enough — the threshold lets a
// twenty-net residual through and the cap alone would arm on a board with a
// hundred.

/// How small a board's residual must get before the expensive rungs are armed,
/// and how much of the residual may then spend them.
pub const LastK = struct {
    /// Most still-failed nets a board may carry and still arm them. Above this
    /// the residual is a placement/escape problem and the extra sweeps are pure
    /// cost — which is exactly why the rungs were switched off in the first
    /// place.
    nets: usize = 24,
    /// Most nets on ONE board that may actually be DECIDED by a widened rung.
    /// The threshold alone bounds the wrong thing: a board of twenty residual
    /// nets that each pull a whole-board fine-grid retry is the expensive case,
    /// and it is expensive per NET, not per board. Measured on straps, where
    /// letting the whole residual through the capped-flood rung cost +26.7 s
    /// (+88 %) and closed nothing.
    spenders: usize = 4,
};

/// Which normally-refused rungs a finishing tier may arm. All false is the
/// historical behaviour, so a caller that never consults `lastKRungs` is
/// unchanged by construction.
pub const LastKRungs = struct {
    /// Fine-retry a residual whose reachability flood hit its cap (normally
    /// classified "unknown", hence refused).
    capped_flood: bool = false,
    /// Fine-retry a residual whose reachable region is bounded by rippable
    /// copper (normally refused as rip-up's problem). Measured worthless on
    /// this corpus and therefore never armed — see `lastKRungs`.
    rippable_frontier: bool = false,
    /// Let the gap closer's repair cascade rip in turn, and use its top
    /// `union_only` rip rung. Read by the post-route closer, which owns the two
    /// constants that spell those rungs today.
    wide_rip: bool = false,
};

/// The rungs to arm for a residual of `failed` still-open nets.
///
/// Zero failed nets arm nothing — there is no endgame to spend on — and so does
/// any residual wider than `lim.nets`.
///
/// `rippable_frontier` is deliberately NOT armed. Measured alone over the four
/// boards with real headroom (`bench-route`, ReleaseSafe, threshold lifted so
/// it armed on all of them) it closed **no** net and cost board-a +8.8 s
/// (+71 %) and black-canyon +3.0 s — the reachable region a rip could have
/// opened is not where these boards are stuck. `capped_flood` is the rung that
/// pays: it is the one that closes black-canyon's extra net, and on board-a
/// it costs nothing at all because board-a's residual has no capped flood.
pub fn lastKRungs(failed: usize, lim: LastK) LastKRungs {
    if (failed == 0 or failed > lim.nets) return .{};
    return .{ .capped_flood = true, .wide_rip = true };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/router - the expensive finishing rungs arm only once the residual is down to the last few nets, and a wider residual leaves every tier byte-identical
test "the last-K rungs arm only for a small residual" {
    // Nothing open: no endgame to spend on.
    try testing.expectEqual(LastKRungs{}, lastKRungs(0, .{}));
    // A wide residual is a placement/escape problem — every rung stays off, so
    // a board above the threshold routes exactly as it did before.
    try testing.expectEqual(LastKRungs{}, lastKRungs(5, .{ .nets = 4 }));
    try testing.expectEqual(LastKRungs{}, lastKRungs(147, .{ .nets = 4 }));
    // At or under it, the rungs that measured worth their cost come on — and
    // `rippable_frontier`, which measured worthless, stays off at every width.
    try testing.expectEqual(
        LastKRungs{ .capped_flood = true, .wide_rip = true },
        lastKRungs(4, .{ .nets = 4 }),
    );
    try testing.expectEqual(
        LastKRungs{ .capped_flood = true, .wide_rip = true },
        lastKRungs(1, .{ .nets = 4 }),
    );
    // The threshold is a policy value, not a constant baked into the ladder.
    try testing.expectEqual(LastKRungs{}, lastKRungs(3, .{ .nets = 2 }));
}

// spec: placement/router - the widened rungs carry a per-board spend cap, so a wide residual cannot each pay a whole fine-grid retry
test "the widened rungs carry a per-board spend cap" {
    // The threshold answers "may this board arm them"; the cap answers "how
    // much of its residual may actually be decided by one". Both are needed:
    // the cost is per NET, so a board just under the threshold with twenty
    // residual nets is the expensive case the threshold alone lets through.
    try testing.expect((LastK{}).spenders > 0);
    try testing.expect((LastK{}).spenders < (LastK{}).nets);
    try testing.expectEqual(@as(usize, 2), (LastK{ .spenders = 2 }).spenders);
}
