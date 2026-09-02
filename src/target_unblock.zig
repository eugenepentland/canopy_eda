//! Per-target unblock — the policy half of the residual tier that rips ONE open
//! net's diagnosed blockers, routes that net through the corridor they vacate,
//! and puts them back inside a single all-or-nothing transaction.
//!
//! Two other shapes were measured on barracuda's 102/109 residual first, and
//! neither moved the board:
//!
//!   * **A whole-field joint rescue inside the timed route** — it re-routes an
//!     unbounded victim set, and the residual tail is tens of seconds, so the
//!     first victim spent all of it and the run ended with the copper it started
//!     with. Time, not policy, was the binding constraint.
//!   * **One AGGREGATE cluster** over three open seeds and their six shared
//!     blockers — cheap, safe, and worth exactly nothing: the seeds' corridors
//!     are not ONE corridor (`LOCK_DET` crosses the board 55 mm, `EN_BUCK6V`
//!     16 mm into a different pocket), so freeing their union frees nobody's,
//!     and the transaction's all-or-nothing gate then has six restores to prove
//!     instead of two.
//!
//! What was never tried is the small, explicit, PER-TARGET transaction: one open
//! net, its own diagnosed blockers, its own bounded slice of what is left of the
//! route budget. That is what this module bounds — and the bounds are the whole
//! contribution, because the rip/re-route machinery already exists
//! (`blocker_nomination`, `vacate_policy.select`, `fine_accept.Gate`).
//!
//! Only POLICY lives here: which open nets qualify, in what order they are
//! attempted, how much of the remaining budget each may spend, and what a
//! transaction must prove about connectivity to be kept. The driver
//! (`serve/route_plan.zig`'s residual area) owns the copper, because ripping and
//! re-routing is a route-lowering operation composed out of that seam's own
//! strip / freeze / gate / merge helpers.
//!
//! It sits at the ROOT rather than under `src/placement/` for one structural
//! reason: guardian's `serve-placement-internals` layering rule forbids the
//! serve layer from compiling against the solver's internals, and the check's
//! own fix note names the remedy — "move the shared type into a module both
//! layers may import". That is what this is (`src/fab_readiness.zig` is the same
//! shape), and it is why `Gate` below WRAPS `placement/fine_accept.zig` rather
//! than the lowering seam reaching into it.
//!
//! Deterministic by construction: no RNG, no hash-map iteration order reaches a
//! decision, and the one clock reading is passed IN, so a test names the instant
//! rather than racing it.

const std = @import("std");
const clock = @import("infra/clock.zig");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const drc = @import("placement/drc.zig");
const drc_diffpair = @import("placement/drc_diffpair.zig");
const route_policy = @import("placement/route_policy.zig");
const fine_accept = @import("placement/fine_accept.zig");
const rf_port_report = @import("placement/rf_port_report.zig");
const vacate_policy = @import("placement/vacate_policy.zig");
const blocker_nomination = @import("placement/blocker_nomination.zig");
const numeric = @import("numeric.zig");

/// How the length of the corridor one transaction has to open sizes the
/// transaction: how wide a band counts as "in the way", and how much copper the
/// rip may take.
///
/// It is a scale, not a switch. This tier's cheap targets ask for 1-6 mm
/// endpoint pockets and its hardest ones for 42-55 mm cross-board joins, and a
/// single flat bound cannot be right for both: sized for the pocket it leaves a
/// long corridor's middle exactly as congested as it found it — so the scoped
/// re-route the rip paid for correctly reports no channel, and the whole
/// transaction is wasted on the targets that most needed it — while sized for
/// the corridor it would let a 1 mm join rip half a board.
pub const Corridor = struct {
    /// How close (mm) foreign copper must come to the target's island-joining
    /// hop to count as standing in its way, before any length scaling. The
    /// radius both existing corridor sweeps measured on this board — a track's
    /// own width plus a clearance either side, with room for the small bow a
    /// route takes around one obstacle instead of running dead straight.
    mm: f64 = 2.0,
    /// Extra half-width (mm) per mm of corridor, and its ceiling.
    ///
    /// A hop's real route is not its straight line. Over a couple of millimetres
    /// the difference is the bow allowance already inside `mm`; over a
    /// cross-board join the route that would finally close it weaves
    /// millimetres off that line, and copper a 2 mm band never saw is exactly
    /// the copper standing in it. Bounded, and bounded tightly: the point of a
    /// corridor is that it is NOT the whole board, and every millimetre of band
    /// nominates more nets for the same three or six blocker slots, so a loose
    /// band spends them on copper that was never in the way.
    bow_frac: f64 = 0.03,
    bow_max_mm: f64 = 2.0,
    /// Elements one transaction may rip PER mm of corridor, over
    /// `Limits.blockers.max_total_elements`, and the absolute ceiling on the
    /// sum.
    ///
    /// 2.0/mm is measured rather than chosen: barracuda carries 539 tracks over
    /// a 60 x 25 mm board, so a 4 mm-wide band the length of a 55 mm corridor
    /// covers about 1.4 elements per millimetre of it. The rate is that density
    /// with a little headroom, and `max_elements` is the hard stop that keeps a
    /// pathological corridor from proposing to rip the board. None of it widens
    /// what MAY be ripped: `vacate_policy` judges every nominated net exactly as
    /// before, and each one still has to come back inside the same
    /// all-or-nothing gate.
    elements_per_mm: f64 = 2.0,
    max_elements: usize = 256,
};

/// The tier's bounds. Every one exists to keep a transaction small enough that
/// its all-or-nothing gate can plausibly be met, and the whole pass short enough
/// to fit the tail of a route budget the main loop has already mostly spent.
pub const Limits = struct {
    /// Most open NETS one pass takes as targets. A board with a dozen open nets
    /// is not one this tier finishes; it is one whose placement or plan is
    /// wrong, and attempting them all would only spread the tail thinner.
    ///
    /// NETS, not transactions, and the difference cost this tier three of five
    /// targets on barracuda. `order` used to cap the FLATTENED list, so a rail
    /// in eight islands — whose per-gap targets are the shortest hops on the
    /// board — filled three of four slots with its own sub-targets and evicted
    /// every two-terminal net behind it. Measured at ReleaseSafe: `V_3V3A` and
    /// `SPI_SCK` were attempted while `LOCK_DET`, `TXDATA_ADF` and
    /// `SPI_LMX_CSN` were never reached, with roughly 190 s of route budget
    /// left unspent. That is exactly the monopoly `max_gap_transactions` was
    /// written to prevent, one level up from where it was being enforced.
    ///
    /// Six, because the same measurement bounds the cost: the whole phase spent
    /// **5.8 s** on both targets and all four of their transactions. And it is
    /// not the real governor — `sliceDeadline` is, and it stops the pass the
    /// moment a share falls under its floor. This cap only has to be wide
    /// enough not to silently drop a board's open set on the floor.
    max_targets: usize = 6,
    /// What one transaction may take off the board, in `vacate_policy`'s own
    /// vocabulary — most nets ripped, most elements ripped, and the size above
    /// which an unpoured net stops counting as a cheap stub. Held as that
    /// selector's own struct rather than restated field by field, because these
    /// bounds ARE the selector's and a second spelling of them is a second
    /// thing to keep in step. Only the DEFAULTS are this tier's: each ripped
    /// net has to come back inside the SAME gate or the whole transaction rolls
    /// back, so its widths sit below the post-route tier's.
    blockers: vacate_policy.Limits = .{
        .max_nets = 3,
        .stub_max_elements = 12,
        .max_total_elements = 48,
    },
    /// How the LENGTH of the corridor a transaction is clearing sizes that
    /// transaction (see `Corridor`).
    corridor: Corridor = .{},
    /// How many of ONE many-islanded net's gaps this phase PLANS to attack.
    /// Each is its own transaction with its own slice, so this is what stops a
    /// rail in eight islands filling a pass's list with its own pockets before
    /// any other open net is named.
    ///
    /// A plan, not a lifetime cap: a net whose transaction is ACCEPTED has
    /// proved a merge closes on this board and re-enters for its next gap on
    /// the spot, rather than waiting for its next planned slot. The bound there
    /// is the board's own — an accepted transaction is a CREDITED island merge,
    /// so the gaps run out.
    max_gap_transactions: usize = 3,
    /// Most oracle evaluations one pass's shared accept gate will pay for.
    ///
    /// `fine_accept`'s own default is eight, sized for a declared net's handful
    /// of rescue attempts; this pass is a different shape. Every candidate that
    /// reaches the commit rule costs one, and a re-entering rail costs one per
    /// island it merges — barracuda's `GND` arrives in eight islands and
    /// `V_3V3A` in eight more. Past the budget an attempt is REFUSED rather
    /// than admitted unmeasured, which would end a merge ladder mid-rail on a
    /// board that still had the time for it. Forty-eight is `island_accept`'s
    /// number for the same reason: one evaluation per island a transactional
    /// pass may join.
    max_evaluations: usize = 48,
    /// What this tier may NEGOTIATE rather than accept (see `Negotiable`).
    negotiate: Negotiable = .{},
    /// How the pass divides the wall time it is given (see `sliceDeadline`).
    slice: struct {
        /// Longest slice one transaction may hold. A single 55 mm cross-board
        /// corridor must not be able to spend a tail that three cheaper targets
        /// could have used.
        max_ns: i128 = 10 * clock.ns_per_s,
        /// Shortest slice worth starting a transaction with. Below this the
        /// route call would expire mid-maze and the candidate be dropped
        /// unmeasured, which costs the tail and buys nothing.
        min_ns: i128 = 3 * clock.ns_per_s,
        /// The end of the budget this pass never spends. Its transactions are
        /// the EXPENSIVE, speculative kind — rip, re-route, weigh, usually roll
        /// back — while the additive close behind them (the oracle's own island
        /// stitching, run through the route gate) is cheap and strictly gated,
        /// and only helps if something is left for it. This reserve is what
        /// stops a phase of rip-ups spending a board's last second on a
        /// transaction that is then thrown away.
        reserve_ns: i128 = 6 * clock.ns_per_s,
        /// Wall time `max_ns` grows by per ELEMENT of rip authority the
        /// corridor arithmetic hands one transaction over its base copper
        /// budget (see `corridorSlice`).
        ///
        /// Zero — no growth — by default, so the narrow tier and every
        /// clock-free board keep the flat cap they were measured on, and only
        /// a tier that declares a rate is scaled.
        ns_per_element: i128 = 0,
        /// The hard stop on the grown cap. A corridor may not buy unbounded
        /// wall time however long it is; `Corridor.max_elements` already stops
        /// the rip growing, and this stops the clock growing with it.
        ceiling_ns: i128 = 90 * clock.ns_per_s,
    } = .{},
};

/// The constraints a transaction may negotiate rather than accept — each
/// a place where the ordinary answer is a POLICY refusal and the physical answer
/// is "movable, under something that reproduces what the refusal was
/// protecting".
///
/// All three default OFF, and each is switched on by the one tier whose
/// affordability the caller has already measured. That is not laziness about
/// granularity: each costs real work beyond an ordinary rip (a second coupled
/// construction, a per-element corridor measurement), each is only worth
/// spending once the ordinary transaction has already refused, and a run with no
/// deadline must reach none of them, so every bench and test board stays
/// byte-identical.
///
/// `pairs` is the WIDE tier's alone: re-laying a declared pair is a second
/// coupled construction, and only a tier the board has measured spare wall time
/// for should attempt one. `plane_corridor` is the wide tier's too, and ALSO the
/// timed breadth probe's — a corridor lift is a SMALLER rip than the whole-net
/// charge it replaces, so the tier that most needs it is the one on the tightest
/// clock (see `route_plan.unblockBreadthLimits`), and the whole-rip authority
/// stays with the depth ladder behind it. `outranking` is the DEEPENING round's
/// own, switched on separately and for a different reason: deepening is reached
/// by narrow transactions too (both measured barracuda cases are narrow
/// rollbacks whose wide retry the board never affords), so waiting for the wide
/// tier would never reach the case it exists for.
///
/// A FOURTH was tried and measured dead: drawing the per-gap join inside
/// `route_close`'s last-chance detour corridor instead of the gate's straight
/// slot. It changed nothing on barracuda, and the arithmetic says why — that
/// corridor is `max(3 mm, half the span)`, and these hops are short (`V_3V3A`
/// 1.0 mm, `SPI_SCK` 6.4 mm), so the "wide" window is the same 3 mm window or
/// within a tenth of it. The `join_no_path` verdict on those targets is real
/// geometry, not a search bound.
pub const Negotiable = struct {
    /// Nominate a declared `(diff-pair …)` and re-lay it with the coupled
    /// constructor (see `pairFacts`).
    pairs: bool = false,
    /// Lift a plane- or pour-carried net CORRIDOR-ONLY, leaving the rest of its
    /// copper exactly where it is (see `liftFacts`).
    plane_corridor: bool = false,
    /// Nominate a net whose `(net-class … (priority …))` outranks the seed's,
    /// lifting it CORRIDOR-ONLY (see `rankFacts`).
    outranking: bool = false,
};

/// The blocker-selection bounds this tier hands `vacate_policy.select`.
///
/// THAT selector, and its restore-cheapness ranking, because it is the one
/// measured on this board: the post-route vacate tier took barracuda 85 → 91
/// picking a corridor's cheapest occupants, and its pour exemption is what let
/// the winning transaction displace a poured rail whose restore the pour
/// underwrites. `joint_rescue`'s proximity-first ranking answers a different
/// question (a victim inside a live route, with no oracle island detail to aim
/// at); here the corridor radius has already decided who is in the way, and what
/// is left to rank is which of them comes back most cheaply.
pub fn blockerLimits(lim: Limits) vacate_policy.Limits {
    return corridorLimits(lim, 0);
}

/// The same bounds, sized for the CORRIDOR this transaction is actually
/// clearing: `corridor_mm` is the total straight length of the hops it has to
/// open (see `Limits.elements_per_corridor_mm`).
///
/// Only the element budget moves. `max_nets` is untouched — it bounds how many
/// separate nets one all-or-nothing restore has to reproduce, which is a
/// property of the transaction's risk and not of the corridor's length — and so
/// is `stub_max_elements`, which is a statement about what a stub IS.
pub fn corridorLimits(lim: Limits, corridor_mm: f64) vacate_policy.Limits {
    var out = lim.blockers;
    if (!(corridor_mm > 0)) return out;
    const extra = corridor_mm * lim.corridor.elements_per_mm;
    const scaled = out.max_total_elements +| numeric.toCount(@floor(extra));
    out.max_total_elements = @min(@max(scaled, out.max_total_elements), lim.corridor.max_elements);
    return out;
}

/// The same bounds again, with the transaction's SLICE CAP sized for the
/// corridor too: `corridorLimits` grows the copper one transaction may rip, and
/// this grows the wall time it gets to put that copper back.
///
/// The two have to move together or the bigger transaction is strictly worse
/// than the smaller one. Measured on barracuda: with the rip scaled by corridor
/// length and the cap left flat, `SPI_LMX_CSN` (42.5 mm) and `LOCK_DET`
/// (55.3 mm) both re-entered the wide tier with two hundred elements of rip
/// authority and the same 45 s, and both verdicts came back "the scoped
/// re-route ran out of its slice" — the transaction was formed, the corridor
/// was freed, and the clock stopped it mid-re-route, so the board learned
/// nothing about whether the join exists.
///
/// The growth is charged per ELEMENT rather than per millimetre so it inherits
/// `Corridor.max_elements`: past saturation a longer corridor buys no more rip
/// authority, and it must buy no more time either. `slice.ceiling_ns` is the
/// second, absolute stop.
///
/// MONOTONE by construction — the cap only ever grows here. A ceiling below a
/// tier's own base cap is a mis-declaration, not an instruction to hand out
/// shorter slices than the tier was measured on.
pub fn corridorSlice(lim: Limits, corridor_mm: f64) Limits {
    const base = lim.blockers.max_total_elements;
    const scaled = corridorLimits(lim, corridor_mm).max_total_elements;
    return grownSlice(lim, if (scaled > base) scaled - base else 0);
}

/// The same bounds again, sized for the RESTORE this transaction actually has to
/// prove: `elements` is the copper its picked blockers carry, all of which has to
/// come back inside the one all-or-nothing gate.
///
/// `corridorSlice` prices the rip authority a corridor BOUGHT; this prices the
/// copper a transaction then went and took. They are the same arithmetic at the
/// same rate — a tier declares one `ns_per_element` and both readings charge it —
/// because they are the same claim: the clock and the copper have to move
/// together or the bigger transaction is strictly worse than the smaller one.
///
/// Measured on barracuda (Debug, v91). `GND`'s per-gap ladder rips 7 elements,
/// then 10, then 12, and the flat cap gave all three the same 10 s. The first two
/// re-routed in 10.4 s and were ACCEPTED; the third needed 13.0 s, was cut off at
/// 8.6 s of it, and reported `slice_expired` — a verdict about the clock, on a
/// transaction whose real answer (measured by handing it 36 s) is that the freed
/// corridor still carries no legal hop. A ladder that abandons its net on a
/// refusal cannot afford verdicts that are about the budget rather than the
/// board.
pub fn restoreSlice(lim: Limits, elements: usize) Limits {
    return grownSlice(lim, elements);
}

/// The one growth rule both readings share: `extra` elements of work at the
/// tier's declared rate, on top of the flat cap it was measured with.
///
/// MONOTONE by construction — the cap only ever grows here. A ceiling below a
/// tier's own base cap is a mis-declaration, not an instruction to hand out
/// shorter slices than the tier was measured on. A tier that declares NO rate is
/// returned untouched, which is what keeps every clock-free board and every
/// caller on the defaults byte-identical.
fn grownSlice(lim: Limits, extra: usize) Limits {
    var out = lim;
    if (lim.slice.ns_per_element == 0 or extra == 0) return out;
    const grown = lim.slice.max_ns + @as(i128, @intCast(extra)) * lim.slice.ns_per_element;
    out.slice.max_ns = @max(lim.slice.max_ns, @min(grown, lim.slice.ceiling_ns));
    return out;
}

/// The wall time a caller must hold back so THIS tier can run its biggest
/// target: one corridor-sized slice (`corridorSlice`) plus the additive close's
/// own reserve, bounded by `cap_ns`.
///
/// It is the tier's sizing read backwards. `sliceDeadline` answers "how long may
/// this transaction take, given what is left"; a phase ahead of it needs the
/// same arithmetic answered forwards — "how much must be left for the biggest
/// transaction to happen at all" — or its own convergence quietly decides that
/// the answer is nothing. The reserve is deliberately ONE target's slice rather
/// than every target's: the share and the floor inside `sliceDeadline` already
/// divide the tail among the targets that remain, and a reserve sized for their
/// sum would take the whole route.
pub fn phaseReserve(lim: Limits, corridor_mm: f64, cap_ns: i128) i128 {
    const grown = corridorSlice(lim, corridor_mm).slice;
    return @min(cap_ns, grown.max_ns + lim.slice.reserve_ns);
}

/// How wide (mm, either side of the straight hop) the corridor sweep counts
/// copper as being in the way, for a corridor of total length `corridor_mm`.
///
/// One reader for the NOMINATION and for the corridor lift, exactly as
/// `unblockHops` is one reader for the lines they are both measured against: a
/// band that nominated a net for copper the lift then declined to remove would
/// charge a transaction for a corridor it never opened.
pub fn corridorRadius(lim: Limits, corridor_mm: f64) f64 {
    if (!(corridor_mm > 0)) return lim.corridor.mm;
    return lim.corridor.mm + @min(corridor_mm * lim.corridor.bow_frac, lim.corridor.bow_max_mm);
}

/// Total straight length (mm) of the hops one transaction is clearing — the
/// corridor its budget and its band are sized against.
pub fn corridorLength(hops: []const blocker_nomination.Hop) f64 {
    var sum: f64 = 0;
    for (hops) |h| sum += std.math.hypot(h.bx - h.ax, h.by - h.ay);
    return sum;
}

/// This tier's one adjustment to how `vacate_policy.judge` reads a nominated
/// net: ground copper a PLANE OR POUR carries is displaceable here.
///
/// `vacate_policy` refuses ground outright, and for the post-route vacate tier
/// that is right — nothing there underwrites the reference copper coming back.
/// Two things differ inside this transaction. The surface hookups and stitch
/// vias it would remove are not what makes such a net connected (the plane is),
/// which is the same argument that already lets the policy displace a POURED
/// rail; and the transaction re-measures ground pad by pad before it commits —
/// `transactionClosed` names ground among the nets that must be off the oracle's
/// open list, and the accept gate re-weighs the whole board, so a stitch that
/// does not come back rolls the entire transaction away. Ground with no plane or
/// pour behind it stays refused, because then its tracks ARE its connectivity.
///
/// It matters because ground stitch metal is what rings the hardest residual
/// nets: a corridor walled by ground surface copper has no other lever, and
/// "unrippable" was a policy answer rather than a physical one. Every other
/// protection — diff pair, `(max-freq …)` RF, via-fenced — is untouched, and the
/// transaction's copper budget still applies, so a heavily stitched ground is
/// refused for its size rather than admitted as a huge restore.
pub fn blockerFacts(base: vacate_policy.NetFacts) vacate_policy.NetFacts {
    var f = base;
    if (f.protected.ground and f.pour_carried) f.protected.ground = false;
    return f;
}

/// What the driver resolved about a nominated net's declared differential pair.
/// Assembled from the placement's `diff_pairs` and the live board, so this
/// module stays free of both.
pub const PairBinding = struct {
    /// The twin leg. A transaction that rips one leg alone cannot re-lay it
    /// coupled — the envelope search reads the leg still on the board as
    /// foreign copper and walls its own pair out (`diff_couple.recouple`'s
    /// lesson) — so the twin is ripped, re-routed and judged with it.
    twin: usize,
    /// Generated tracks + vias of BOTH legs. The transaction's copper budget
    /// governs a pair by what its restore has to re-lay, and that is two legs;
    /// charging only the nominated one would let a pair in under a cap sized
    /// for half of it.
    elements: usize,
};

/// This tier's SECOND departure from `vacate_policy`'s default reading: a
/// declared differential pair is displaceable when the transaction commits to
/// re-laying it as a coupled pair.
///
/// `vacate_policy` refuses a pair outright and says why — "its geometry is a
/// coupled pair placed deliberately; a re-route would not reproduce it". That
/// is exactly right for a tier whose restore is an ordinary maze walk, and it
/// is what makes a pair the copper that seals a corridor nothing else can open:
/// on barracuda the `REF_LMX_P/N` In2 stripline lies across the band three
/// stuck control nets have to cross, and no rippable neighbour moves it.
///
/// What differs here is that the pair's contract is SPACING AND SKEW, not an
/// absolute position — an In2 stripline between two ground planes may sit a
/// millimetre further up the board and be the same transmission line — and the
/// router already owns the construction that reproduces that contract
/// (`diff_couple`: one centreline routed at the pair envelope, split into exact
/// ±(width+gap)/2 legs, mitred through every bend, paired at every via,
/// length-matched in the pad fans). The transaction re-routes both legs through
/// it under the pair's own authored class and wave, and the caller re-proves
/// the result per pair (`pairHeld`) on top of the whole-board gate every other
/// transaction passes. A pair that declines to couple, or comes back looser
/// than it was, rolls the entire transaction back.
///
/// `lim.negotiate.pairs` is the switch, and `pair` is the driver's assertion
/// that it really will rip both legs. Neither alone is enough: without the
/// binding there is no twin to rip, and without the flag this is the ordinary
/// narrow transaction, which cannot afford the construction.
pub fn pairFacts(
    base: vacate_policy.NetFacts,
    lim: Limits,
    pair: ?PairBinding,
) vacate_policy.NetFacts {
    var f = blockerFacts(base);
    if (f.protected.diff_pair == .none or !lim.negotiate.pairs) return f;
    const bind = pair orelse return f;
    f.protected.diff_pair = .recouplable;
    f.elements = bind.elements;
    return f;
}

/// This tier's THIRD departure: a plane- or pour-carried net is ripped
/// CORRIDOR-ONLY, and charged for the corridor rather than for the net.
///
/// `blockerFacts` above already lets an unblock transaction displace ground a
/// plane carries. On a real board that permission alone changes nothing, and
/// barracuda says exactly why: `GND` is whole, plane-carried and lying across
/// every sealed corridor — and it carries hundreds of elements, so the copper
/// budget refuses it `over_budget`, and would be right to. Re-laying a board's
/// entire stitch field inside one transaction's slice is not a rip, it is a
/// second route.
///
/// What is actually in the way is the handful of barrels and hookups crossing
/// the channel, and for a net a PLANE or POUR carries those are not its
/// connectivity — the plane is. That is the same argument that makes such a net
/// nominable at all (`vacate_policy.Kind.pour_carried`: strip its tracks and it
/// stays whole), and it applies just as exactly to a SUBSET of its tracks. So
/// the transaction lifts what stands in the corridor, freezes the rest
/// byte-for-byte, and lets the router re-stitch the pads it disturbed —
/// site flexibility being the whole point of a stitch via.
///
/// `corridor_elements` is the driver's count of what it will actually lift,
/// measured with the SAME corridor rule the nomination used
/// (`blocker_nomination.trackGap` / `viaGap`), so the copper this charges for
/// and the copper the rip removes are the same copper. Null, or a tier with
/// the switch off, leaves the whole-net charge in place.
///
/// Nothing else about the judgement moves: the net still has to be whole,
/// still has to be pour-carried to get here, and the transaction still proves
/// pad-by-pad connectivity over the whole board before it commits — which is
/// what catches a lift that took a pad's only path to the plane.
pub fn liftFacts(
    base: vacate_policy.NetFacts,
    lim: Limits,
    corridor_elements: ?usize,
) vacate_policy.NetFacts {
    var f = base;
    if (!lim.negotiate.plane_corridor or !f.pour_carried) return f;
    const n = corridor_elements orelse return f;
    if (n == 0 or n >= f.elements) return f;
    f.elements = n;
    return f;
}

/// This tier's FOURTH departure: a net whose class `(priority …)` outranks the
/// seed's may be lifted CORRIDOR-ONLY rather than refused outright.
///
/// `vacate_policy`'s rank guard is a heuristic about routing ORDER — "do not
/// take a channel from a net that was promised it first" — and it predates every
/// piece of restore discipline a transaction now carries. It is not an
/// electrical-integrity rule: those are `ground`, `diff_pair`, `rf_max_freq` and
/// `fenced`, they refuse ahead of it, and NONE of them moves here. Measured on
/// barracuda (ReleaseSafe, v97): `LOCK_DET`'s corridor, after every negotiable
/// blocker in it had been ripped and put back, was still held by `V_24V_CLEAN`
/// — excluded on rank alone, on a board where nothing else was left to try.
///
/// So the guard yields, on the same terms `liftFacts` gives a poured rail and
/// under the narrowest rip this tier owns:
///
///   * only what crosses the corridor is taken, measured by the driver with the
///     rip's own predicate, so the charge and the strip are the same copper and
///     the restore is the smallest one that can free the channel;
///   * the lifted net is re-routed inside the transaction and must come back
///     CONNECTED (`transactionClosed` names it), or the whole thing rolls back;
///   * if it comes back at a price the board will not pay, the driver's re-home
///     and alternate-nomination ladder answers that exactly as it does for any
///     other victim.
///
/// `corridor_elements` is null, zero, or the switch is off ⇒ nothing changes and
/// the net is refused `outranks_seed` exactly as before. A net with no copper in
/// the corridor is not in the way, so there is nothing to negotiate about it.
pub fn rankFacts(
    base: vacate_policy.NetFacts,
    lim: Limits,
    corridor_elements: ?usize,
) vacate_policy.NetFacts {
    var f = base;
    if (!lim.negotiate.outranking) return f;
    const n = corridor_elements orelse return f;
    if (n == 0) return f;
    f.rank.negotiable = true;
    f.elements = @min(n, f.elements);
    return f;
}

/// What one declared pair's copper is, measured on one board — the evidence a
/// pair negotiation is judged on.
pub const PairHealth = struct {
    /// How many of the pair's two legs carry any copper. Both DRC pair rules go
    /// quiet when a leg has none, so a half-laid pair would otherwise read as a
    /// clean one.
    legs_with_copper: usize = 0,
    /// `diff_uncoupled` findings for this pair: a stretch of one leg with no
    /// twin copper inside the coupling window.
    uncoupled: usize = 0,
    /// Total routed length difference between the two legs, in mm. Measured
    /// directly rather than read off the `diff_skew` finding, because that rule
    /// only speaks past `max(4·pitch, 1 mm)` while the coupled constructor
    /// equalizes to 0.05 mm — a legacy fallback could hand back 0.9 mm of skew
    /// and no finding at all.
    skew_mm: f64 = 0,
};

/// How much worse a re-laid pair's skew may be than the pair it replaced.
///
/// The coupled constructor's own length-match window (`diff_couple`'s
/// `pair_skew_tol_mm`). A pair rebuilt by that construction lands inside it by
/// definition, so the slack admits grid quantisation and nothing else; a
/// fallback that routed the two legs independently misses it by an order of
/// magnitude, which is the case this gate exists to catch.
pub const pair_skew_slack_mm: f64 = 0.05;

/// Did the pair come back to contract?
///
/// NO WORSE THAN IT WAS, on all three counts: both legs carry copper, the
/// coupling window is not violated any more often than before, and the legs are
/// no more skewed than before plus the constructor's own equalisation window.
/// A `before` reference rather than an absolute threshold, because the pair on
/// the incoming board is the design's own accepted answer — this tier may move
/// a pair, never degrade one.
pub fn pairHeld(before: PairHealth, after: PairHealth) bool {
    if (after.legs_with_copper != 2) return false;
    if (after.uncoupled > before.uncoupled) return false;
    return after.skew_mm <= before.skew_mm + pair_skew_slack_mm;
}

/// Measure every declared pair on one board, in `placement.diff_pairs` order.
///
/// `violations` is the caller's own DRC pass — the same one it ratchets error
/// counts against — so a candidate is weighed exactly once and the pair verdict
/// and the fabrication verdict are read off one board. The coupling half comes
/// from `drc_diffpair`'s own `diff_uncoupled` rule (each finding names its pair
/// in `who`), and the skew half from that module's own length measure rather
/// than from its `diff_skew` FINDING, which stays silent inside a millimetre.
///
/// It lives here rather than in the lowering seam for the layering reason this
/// whole module exists (see the header): the serve layer may not compile
/// against the solver's internals, and the pair measure needs two of them.
pub fn pairHealthAll(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    board: Board,
    violations: []const drc.Violation,
) std.mem.Allocator.Error![]const PairHealth {
    const out = try arena.alloc(PairHealth, placement.diff_pairs.len);
    const copper = drc_diffpair.Copper{ .tracks = board.tracks, .vias = board.vias };
    for (placement.diff_pairs, out) |pair, *slot| {
        const p: i32 = @intCast(pair.p);
        const n: i32 = @intCast(pair.n);
        const len_p = try drc_diffpair.effectiveNetLength(arena, copper, p);
        const len_n = try drc_diffpair.effectiveNetLength(arena, copper, n);
        slot.* = .{
            .legs_with_copper = @as(usize, @intFromBool(len_p > 0)) + @intFromBool(len_n > 0),
            .uncoupled = uncoupledFindings(violations, p, n),
            .skew_mm = @abs(len_p - len_n),
        };
    }
    return out;
}

/// How many `diff_uncoupled` findings name this pair.
fn uncoupledFindings(violations: []const drc.Violation, p: i32, n: i32) usize {
    var count: usize = 0;
    for (violations) |v| {
        if (v.kind != .diff_uncoupled) continue;
        if (v.who.net_a == p and v.who.net_b == n) count += 1;
    }
    return count;
}

/// One board's copper, either side of a transaction — all four kinds the
/// connectivity oracle reads (`fine_accept.Board`, which this forwards to).
/// A transaction here is weighed on FINISHED route results, so both curved
/// kinds exist and a caller that drops them hands the gate a board whose arcs
/// carve no pour and whose RF tapers never reach their pads.
pub const Board = struct {
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
    arcs: []const router.Arc = &.{},
    rf_paths: []const rf_port_report.Outcome = &.{},
};

/// The connectivity authority a transaction commits under, wrapped so the route
/// lowering seam can hold one without compiling against the solver's internals
/// (see this module's header note on the `serve-placement-internals` rule).
///
/// The judgement is entirely `fine_accept`'s and this adds no rule of its own:
/// strictly more nets connected and not one connected net lost, measured by the
/// fabrication oracle over the WHOLE board — the nets a transaction never named
/// included, because a rerouted trace can cut a pour and open a net nobody
/// touched. Its bounded evaluation budget also bounds this pass's oracle cost:
/// past it an attempt is refused rather than admitted unmeasured.
pub const Gate = struct {
    inner: fine_accept.Gate,

    /// Open a gate over `placement` and the route's retained copper `zones` (a
    /// rail poured rather than traced is joined by its zone and by nothing
    /// else, so the pours are part of the connectivity it measures). `home`
    /// owns the per-net buffers and backs the oracle's own scratch.
    pub fn init(
        home: std.mem.Allocator,
        placement: optimizer.Placement,
        zones: []const route_policy.ExistingZone,
    ) std.mem.Allocator.Error!Gate {
        return .{ .inner = try fine_accept.Gate.init(home, placement, zones) };
    }

    /// Release the measurement scratch. The verdicts a caller already read
    /// remain valid; the gate itself is done.
    pub fn deinit(self: *Gate) void {
        self.inner.deinit();
    }

    /// Let this gate weigh up to `evaluations` candidates (see
    /// `Limits.max_evaluations`). Raises only: `fine_accept`'s own default is
    /// the floor, so a caller that asks for less keeps what it had.
    pub fn allowEvaluations(self: *Gate, evaluations: usize) void {
        self.inner.budget = @max(self.inner.budget, evaluations);
    }

    /// Is `after` a strictly better board than `before`?
    pub fn accepts(self: *Gate, before: Board, after: Board) std.mem.Allocator.Error!bool {
        return self.inner.acceptsReplacement(innerBoard(before), innerBoard(after));
    }

    /// Did `after` join two of `net_i`'s copper islands without costing the
    /// board a net it already connected?
    ///
    /// The verdict a PER-GAP transaction commits under. Its target net stays
    /// open — closing one gap of eight leaves seven — so the whole-board
    /// "strictly more nets connected" rule `accepts` asks would refuse every
    /// such transaction on principle. This asks the fabrication oracle the
    /// question the transaction was actually formed to answer, over the same
    /// whole board and with the same bystander protection.
    pub fn acceptsIslandMerge(
        self: *Gate,
        net_i: usize,
        before: Board,
        after: Board,
    ) std.mem.Allocator.Error!bool {
        return self.inner.acceptsIslandMerge(net_i, innerBoard(before), innerBoard(after));
    }
};

/// This module's board in the solver's own spelling. One conversion, so the two
/// verdicts above cannot start disagreeing about which copper kinds travel.
fn innerBoard(b: Board) fine_accept.Board {
    return .{ .tracks = b.tracks, .vias = b.vias, .arcs = b.arcs, .rf_paths = b.rf_paths };
}

/// The connectivity oracle's shape of one still-open net, reduced to what the
/// eligibility rule reads. Counts rather than a `fab_readiness.OpenNet`, because
/// the rule is about shape and the caller already holds the detail.
pub const OpenShape = struct {
    /// Isolated copper groups the oracle finds behind the net's airwire.
    islands: usize = 0,
    /// The net's pads on the board.
    pads: usize = 0,
    /// Island-joining hops the oracle would need to close it.
    gaps: usize = 0,
    /// Length of the hop that closes it, in mm.
    gap_mm: f64 = 0,
};

/// What one transaction is formed to do.
pub const Kind = enum {
    /// Free the corridor and re-route the WHOLE net. The net's entire problem
    /// is one hop, so rewriting it is both the cheapest fix and an unambiguous
    /// success test.
    whole_net,
    /// Free the corridor of ONE island-joining hop and draw just that join,
    /// leaving the rest of the net's copper where it is. A many-islanded rail
    /// is not one problem but several, and its own copper is part of what jams
    /// each pocket — rewriting it wholesale neither frees it nor proves
    /// anything (that is exactly what `targetOf` refuses).
    one_gap,
};

/// One open net this pass may attempt, and the two facts that order it.
pub const Target = struct {
    net_i: usize,
    /// Length of the ONE island-joining hop this transaction would draw.
    gap_mm: f64,
    kind: Kind = .whole_net,
    /// How many island-joining hops its NET still has — how far this target's
    /// net is from closed, not how far this hop is across. One by default,
    /// because that is the shape `targetOf` claims and the only count a target
    /// with a single hop can have.
    gaps: usize = 1,
};

/// Is this open net a target, and if so at what gap?
///
/// TWO-TERMINAL AND WHOLLY OPEN, which is one rule wearing three checks: two
/// pads, each its own island, one hop between them. Such a net's entire problem
/// is that single hop, so freeing a corridor can plausibly close it and the
/// transaction's success test is unambiguous. A multi-island rail is the
/// opposite case on both counts — barracuda's `V_3V3A` is 27 pads in 8 islands
/// needing 7 hops, and its own scattered copper is part of what jams the pocket,
/// so ripping three neighbours neither frees it nor proves anything.
pub fn targetOf(net_i: usize, shape: OpenShape) ?Target {
    if (shape.pads != 2 or shape.islands != 2 or shape.gaps != 1) return null;
    return .{ .net_i = net_i, .gap_mm = shape.gap_mm, .kind = .whole_net, .gaps = shape.gaps };
}

/// The PER-GAP targets of an open net the whole-net rule does not claim: its
/// `gap_mm` hops, smallest first, capped at `lim.max_gap_transactions`.
///
/// This is the other half of `targetOf`'s rule rather than a loosening of it. A
/// rail in eight islands is eight problems, and the reason the whole-net shape
/// refuses it — its own scattered copper jams the pockets, so rewriting it
/// proves nothing — is also the reason each GAP is a sound transaction on its
/// own: free the copper standing in one 1 mm channel, draw that one join, leave
/// everything else exactly where it is, and the island count either fell or it
/// did not. Barracuda's `V_3V3A` is the case (eight islands, gaps 0.99-10.19 mm,
/// every additive close refused for want of a channel).
///
/// The two rules PARTITION the open nets, which is why the exclusion here is
/// spelled as "whatever `targetOf` claims" rather than as an island count of its
/// own. An island count left a hole exactly where barracuda's last ground gap
/// sits: `GND` finishes as TWO islands over 247 pads with one 1.27 mm hop
/// between them, so the whole-net rule refuses it (247 pads is not a
/// two-terminal net to rewrite) and an `islands > 2` rule refused it too — the
/// net with the shortest, most closable gap on the board was the one net no
/// transaction could be formed for. Two islands is not what made a whole-net
/// rewrite meaningless; MANY PADS is, and that is the same reason a per-gap
/// transaction suits it: it draws one join in a freed channel and leaves the
/// other 246 pads' copper exactly where it is.
///
/// Ordering is the same greedy rule the whole-net targets use: the shortest hop
/// is both likelier to close and quicker to prove. The cap is what keeps one
/// rail from spending a tail every other target shares — a net that closes a
/// gap re-enters the caller's list with a smaller board to work on, which is
/// how it gets more than `max_gap_transactions` attempts across a route rather
/// than all of them at once.
pub fn gapTargets(
    alloc: std.mem.Allocator,
    net_i: usize,
    shape: OpenShape,
    gap_mm: []const f64,
    lim: Limits,
) std.mem.Allocator.Error![]const Target {
    if (shape.islands <= 1 or gap_mm.len == 0) return &.{};
    if (targetOf(net_i, shape) != null) return &.{};
    const sorted = try alloc.dupe(f64, gap_mm);
    std.mem.sort(f64, sorted, {}, std.sort.asc(f64));
    const keep = @min(sorted.len, lim.max_gap_transactions);
    const out = try alloc.alloc(Target, keep);
    // Every target of one net carries that net's WHOLE gap count, not the capped
    // number of them this pass plans to attack: `gaps` is how far the net is from
    // closed, which is what `order` weighs, and the cap is a budget decision that
    // must not make a rail look nearer closing than it is.
    for (sorted[0..keep], out) |mm, *slot| slot.* = .{
        .net_i = net_i,
        .gap_mm = mm,
        .kind = .one_gap,
        .gaps = gap_mm.len,
    };
    return out;
}

/// Closest to CLOSED first: the net with the fewest island gaps left leads, its
/// shortest hop breaks that tie, and the net index breaks the last one.
///
/// The gap count leads because the budget buys CLOSED NETS, not merges. A net
/// with one gap left closes outright on one accept; a net with seven is seven
/// accepts from closing, and the six after the first buy an island count no fab
/// output reads. It is the same principle `route_close`'s whole-net prefix is
/// built on — spend the tail where one success is a finished net.
///
/// Measured on barracuda (Debug, v91): `GND` finishes as ONE 1.27 mm hop between
/// two islands — one accept from a closed net, and the closest win on the board —
/// while `V_3V3A` is eight islands whose shortest pocket is 0.99 mm. Flat
/// cheapest-hop-first put the rail's pocket first on 0.03 mm, and the phase's
/// tail ran out before `GND` was ever attempted.
///
/// Within one gap count the hop LENGTH still leads, for the reason it always
/// did: the targets share one tail, a short hop is likelier to close and quicker
/// to prove, and a long one attempted first can eat the budget of every target
/// behind it and still fail.
pub fn closestToClosedFirst(_: void, a: Target, b: Target) bool {
    if (a.gaps != b.gaps) return a.gaps < b.gaps;
    if (a.gap_mm != b.gap_mm) return a.gap_mm < b.gap_mm;
    return a.net_i < b.net_i;
}

/// The attempt order: closest to closed first, ROUND-ROBIN across nets, capped
/// at `lim.max_targets` distinct nets. Copies rather than sorting in place, so
/// the caller's oracle-ordered list stays as the oracle reported it.
///
/// `closestToClosedFirst` is still the rule WITHIN a round, for the reason it
/// always was: the targets share one tail, and the accept that finishes a net is
/// worth more of it than the accept that merely merges two of a rail's eight
/// islands.
///
/// The rounds are what stop that rule eating itself. A many-islanded rail
/// contributes one target per gap, and those gaps are the shortest hops on the
/// board — so a flat cheapest-first order puts three of one rail's pockets
/// ahead of every other open net, and a cap then discards the rest of the board
/// unattempted. Measured on barracuda: `V_3V3A`'s three sub-targets plus
/// `SPI_SCK`'s first filled a four-slot cap and `LOCK_DET`, `TXDATA_ADF` and
/// `SPI_LMX_CSN` were never attempted at all. Round-robin says instead: every
/// net gets its first attempt before any net gets its second, which is what
/// `Limits.max_gap_transactions` already promised one level down.
pub fn order(
    alloc: std.mem.Allocator,
    targets: []const Target,
    lim: Limits,
) std.mem.Allocator.Error![]const Target {
    const sorted = try alloc.dupe(Target, targets);
    std.mem.sort(Target, sorted, {}, closestToClosedFirst);
    // Each target's rank among its OWN net's targets, in that cheapest-first
    // order — its round.
    const round = try alloc.alloc(usize, sorted.len);
    for (sorted, round, 0..) |t, *slot, i| {
        var seen: usize = 0;
        for (sorted[0..i]) |earlier| {
            if (earlier.net_i == t.net_i) seen += 1;
        }
        slot.* = seen;
    }
    var out: std.ArrayList(Target) = .empty;
    var admitted: std.ArrayList(usize) = .empty;
    defer admitted.deinit(alloc);
    var r: usize = 0;
    while (out.items.len < sorted.len) : (r += 1) {
        const before = out.items.len;
        for (sorted, round) |t, rank| {
            if (rank != r) continue;
            if (!netAdmitted(admitted.items, t.net_i)) {
                if (admitted.items.len >= lim.max_targets) continue;
                try admitted.append(alloc, t.net_i);
            }
            try out.append(alloc, t);
        }
        // A round that admitted nothing means every remaining target belongs to
        // a net the cap turned away; nothing later can change that.
        if (out.items.len == before) break;
    }
    return out.toOwnedSlice(alloc);
}

/// Has this net already taken one of the pass's target slots?
fn netAdmitted(admitted: []const usize, net_i: usize) bool {
    for (admitted) |n| if (n == net_i) return true;
    return false;
}

/// The absolute deadline the next transaction runs under, or null when the pass
/// should stop.
///
/// An EQUAL SHARE of what is left BEFORE the reserve, floored at
/// `slice.min_ns` and capped at `slice.max_ns`. The share is what stops one
/// target starving the rest; the floor is what stops a slice too short to route
/// anything being handed out at all (the pass ends instead); the cap is what
/// keeps a lone target from spending a whole tail; and `slice.reserve_ns` is what
/// the pass hands on to the cheap additive close behind it. An unbudgeted run
/// (`board_deadline == 0`) still gets the cap — this tier is speculative work
/// and is bounded whether or not the caller bounded it.
///
/// The cap is whatever `lim` carries, which a caller may have sized for this
/// transaction's own corridor first (`corridorSlice`). That never loosens the
/// two bounds above it: the EQUAL SHARE and the remainder still stand between a
/// grown cap and the clock, so a long-corridor target takes a longer slice only
/// out of time no other target and no reserve had a claim on.
pub fn sliceDeadline(now: i128, board_deadline: i128, targets_left: usize, lim: Limits) ?i128 {
    if (targets_left == 0) return null;
    if (board_deadline == 0) return now + lim.slice.max_ns;
    const remaining = board_deadline - lim.slice.reserve_ns - now;
    if (remaining < lim.slice.min_ns) return null;
    const share = @divTrunc(remaining, @as(i128, @intCast(targets_left)));
    const slice = @min(lim.slice.max_ns, @max(lim.slice.min_ns, share));
    return now + @min(slice, remaining);
}

/// The deadline a FORMED transaction runs under, priced against the copper it
/// actually has to put back.
///
/// `sliceDeadline` divides the remainder into equal shares, and that is the right
/// answer while every transaction is the same size. It stops being one the moment
/// a rip is charged per element: `restoreSlice` raises what a big restore MAY
/// take, and the equal share then refuses to hand it over. Measured on barracuda
/// (ReleaseSafe, v92): `SPI_LMX_CSN` and `LOCK_DET` each ripped a 66-element
/// pour-carried rail plus two stubs — about 25 s of re-route at the tier's own
/// declared rate — out of a 89 s phase tail split six ways, so each was quoted
/// ~14 s and both verdicted `slice_expired`. The clock said no to work the tier
/// had already decided was worth doing.
///
/// So a transaction may claim what its own restore is PRICED at when that beats
/// its share, bounded three times over: never past the cap `restoreSlice` grew
/// (which `slice.ceiling_ns` already stops), never past the remainder, and never
/// into the `slice.min_ns` floor each target behind it is still owed — which is
/// the sense in which the phase reserve still covers every admitted target. It is
/// MONOTONE against `sliceDeadline`: the claim is a floor raised toward the cap,
/// never a shorter slice than the equal share would have given.
///
/// A clock-free board (`board_deadline == 0`) and a tier that declares no rate
/// are handed straight to `sliceDeadline`, so every bench and test route keeps
/// the flat cap it was measured on.
pub fn restoreDeadline(
    now: i128,
    board_deadline: i128,
    targets_left: usize,
    lim: Limits,
    elements: usize,
) ?i128 {
    const grown = restoreSlice(lim, elements);
    if (board_deadline == 0 or elements == 0 or lim.slice.ns_per_element == 0)
        return sliceDeadline(now, board_deadline, targets_left, grown);
    if (targets_left == 0) return null;
    const remaining = board_deadline - grown.slice.reserve_ns - now;
    if (remaining < grown.slice.min_ns) return null;
    const share = @max(grown.slice.min_ns, @divTrunc(remaining, @as(i128, @intCast(targets_left))));
    const priced = @as(i128, @intCast(elements)) * lim.slice.ns_per_element;
    // What is left once every target behind this one keeps its floor.
    const owed = @as(i128, @intCast(targets_left - 1)) * grown.slice.min_ns;
    const headroom = @max(grown.slice.min_ns, remaining - owed);
    const slice = @min(grown.slice.max_ns, @max(share, @min(priced, headroom)));
    return now + @min(slice, remaining);
}

/// Did this transaction do what it was formed to do — is every net it NAMED
/// (its target, and every blocker it ripped to free that target's corridor)
/// connected on the candidate board?
///
/// `open` is the connectivity oracle's own open-net list for that board
/// (`RouteResult.failed`, which the route gate fills from
/// `fab_readiness.routableTally`), so this asks the same authority
/// `fine_accept.Gate` asks and cannot answer against a different board.
///
/// It is the tier's OWN half of the accept rule and is never sufficient alone:
/// the gate supplies the other half — strictly more nets joined, and not one
/// net the board already connected left open — over the WHOLE board, including
/// every net this transaction never named. Asking both is what separates "the
/// target closed" from "the target closed and the board paid for it somewhere
/// else".
pub fn transactionClosed(open: []const []const u8, named: []const []const u8) bool {
    for (named) |name| {
        for (open) |still_open| {
            if (std.mem.eql(u8, name, still_open)) return false;
        }
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

// spec: placement/target-unblock - a many-islanded open net yields one transaction per gap, smallest first, capped per net
test "a many-islanded net is attacked one gap at a time" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lim = Limits{};
    const shape = OpenShape{ .islands = 8, .pads = 27, .gaps = 7, .gap_mm = 10.19 };
    const gaps = [_]f64{ 7.36, 5.6, 10.19, 0.99, 3.48, 2.02, 1.44 };
    const targets = try gapTargets(arena, 28, shape, &gaps, lim);
    // Capped per net, smallest first, and every one asks for a gap rather than
    // a rewrite of the whole rail.
    try testing.expectEqual(lim.max_gap_transactions, targets.len);
    try testing.expectApproxEqAbs(@as(f64, 0.99), targets[0].gap_mm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1.44), targets[1].gap_mm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 2.02), targets[2].gap_mm, 1e-12);
    for (targets) |t| {
        try testing.expectEqual(@as(usize, 28), t.net_i);
        try testing.expectEqual(Kind.one_gap, t.kind);
        // Each target carries the rail's WHOLE gap count, not the three of them
        // this pass plans to attack: the cap is a budget decision and must not
        // make an eight-island rail look one accept from closed.
        try testing.expectEqual(gaps.len, t.gaps);
    }

    // The two-island shape stays with `targetOf`: one rule owns each net.
    const two = OpenShape{ .islands = 2, .pads = 2, .gaps = 1, .gap_mm = 16.5 };
    try testing.expectEqual(@as(usize, 0), (try gapTargets(arena, 4, two, &.{16.5}, lim)).len);
    try testing.expectEqual(Kind.whole_net, targetOf(4, two).?.kind);
    // A net the oracle names no hop for has nothing to attack.
    try testing.expectEqual(@as(usize, 0), (try gapTargets(arena, 28, shape, &.{}, lim)).len);
}

// spec: placement/target-unblock - every open net the whole-net rule does not claim yields per-gap transactions instead, so a two-island net of many pads is a target rather than a hole between the two rules
test "a two-island net of many pads is a per-gap target" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lim = Limits{};
    // barracuda's finished `GND`: one 1.27 mm hop between two islands over 247
    // pads. `targetOf` refuses it (247 pads is no two-terminal rewrite) and an
    // island count of its own used to refuse it here as well, which left the
    // shortest gap on the board with no tier able to form a transaction at all.
    const ground = OpenShape{ .islands = 2, .pads = 247, .gaps = 1, .gap_mm = 1.27 };
    try testing.expect(targetOf(18, ground) == null);
    const targets = try gapTargets(arena, 18, ground, &.{1.27}, lim);
    try testing.expectEqual(@as(usize, 1), targets.len);
    try testing.expectEqual(Kind.one_gap, targets[0].kind);
    try testing.expectEqual(@as(usize, 18), targets[0].net_i);
    try testing.expectApproxEqAbs(@as(f64, 1.27), targets[0].gap_mm, 1e-12);
    // And it is ONE gap from closed, which is what puts it ahead of every rail
    // pocket on the board (see `closestToClosedFirst`).
    try testing.expectEqual(@as(usize, 1), targets[0].gaps);

    // The rules still PARTITION: the two-terminal shape stays whole-net and
    // yields nothing here, whatever its gap.
    const two = OpenShape{ .islands = 2, .pads = 2, .gaps = 1, .gap_mm = 1.27 };
    try testing.expectEqual(Kind.whole_net, targetOf(4, two).?.kind);
    try testing.expectEqual(@as(usize, 0), (try gapTargets(arena, 4, two, &.{1.27}, lim)).len);
    // A net already in one island has no hop to free, however many pads it has.
    const whole = OpenShape{ .islands = 1, .pads = 247, .gaps = 0 };
    try testing.expectEqual(@as(usize, 0), (try gapTargets(arena, 18, whole, &.{}, lim)).len);
    try testing.expect(targetOf(18, whole) == null);
}

// spec: placement/target-unblock - only a wholly open two-terminal net, two pads in two islands one hop apart, becomes an unblock target
test "an unblock target is a two-terminal net with one island-joining hop" {
    const two = targetOf(4, .{ .islands = 2, .pads = 2, .gaps = 1, .gap_mm = 16.5 }).?;
    try testing.expectEqual(@as(usize, 4), two.net_i);
    try testing.expectApproxEqAbs(@as(f64, 16.5), two.gap_mm, 1e-12);
    // A multi-island rail: many hops, and its own scattered copper is part of
    // the jam — barracuda's V_3V3A shape.
    try testing.expect(targetOf(5, .{ .islands = 8, .pads = 27, .gaps = 7, .gap_mm = 1.0 }) == null);
    // Two pads already sharing an island (a hairline the oracle still calls
    // open) has no hop to free.
    try testing.expect(targetOf(6, .{ .islands = 1, .pads = 2, .gaps = 0 }) == null);
    // Three pads in two islands is not two-terminal, whatever its hop count.
    try testing.expect(targetOf(7, .{ .islands = 2, .pads = 3, .gaps = 1, .gap_mm = 2.0 }) == null);
}

// spec: placement/target-unblock - among targets whose nets are equally far from closed, unblock attempts the smallest island gap first, tie-broken on net index, and caps the pass
test "targets are ordered cheapest gap first and capped" {
    const found = [_]Target{
        .{ .net_i = 3, .gap_mm = 55.272 },
        .{ .net_i = 9, .gap_mm = 16.503 },
        .{ .net_i = 5, .gap_mm = 42.541 },
        .{ .net_i = 1, .gap_mm = 42.541 },
        .{ .net_i = 7, .gap_mm = 49.611 },
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const attempted = try order(arena_state.allocator(), &found, .{ .max_targets = 4 });
    try testing.expectEqual(@as(usize, 4), attempted.len); // max_targets nets
    try testing.expectEqual(@as(usize, 9), attempted[0].net_i);
    try testing.expectEqual(@as(usize, 1), attempted[1].net_i); // index breaks the tie
    try testing.expectEqual(@as(usize, 5), attempted[2].net_i);
    try testing.expectEqual(@as(usize, 7), attempted[3].net_i);
    // The caller's own list is untouched, so the oracle order it reported and
    // the attempt order this returns stay separate facts.
    try testing.expectEqual(@as(usize, 3), found[0].net_i);
}

// spec: placement/target-unblock - one many-islanded net's per-gap targets may not crowd another open net out of the pass; every net gets its first attempt before any net gets its second, and the cap counts nets
test "the attempt order is round-robin across nets, not cheapest-hop-first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // barracuda's exact residual: one rail in eight islands contributing the
    // three SHORTEST hops on the board, one four-island clock net, and three
    // two-terminal control nets whose single hops are the longest of all.
    const found = [_]Target{
        .{ .net_i = 28, .gap_mm = 0.99, .kind = .one_gap, .gaps = 7 },
        .{ .net_i = 28, .gap_mm = 2.02, .kind = .one_gap, .gaps = 7 },
        .{ .net_i = 28, .gap_mm = 3.48, .kind = .one_gap, .gaps = 7 },
        .{ .net_i = 12, .gap_mm = 6.42, .kind = .one_gap, .gaps = 3 },
        .{ .net_i = 12, .gap_mm = 14.30, .kind = .one_gap, .gaps = 3 },
        .{ .net_i = 5, .gap_mm = 42.541 },
        .{ .net_i = 7, .gap_mm = 49.611 },
        .{ .net_i = 3, .gap_mm = 55.272 },
    };
    // Round one is one target per net, closest-to-closed first — all five open
    // nets are attempted before the rail gets a second pocket. The three
    // two-terminal nets lead on ONE gap each, however long their hops, because
    // one accept finishes them; only then round two and round three.
    try expectNetOrder(&.{ 5, 7, 3, 12, 28, 12, 28, 28 }, try order(arena, &found, .{}));
    // Under the OLD flat cap the rail took three of four slots and the three
    // control nets were never attempted. The cap now counts NETS: a narrow pass
    // keeps the three nets nearest closing, each still holding its own later
    // rounds (which is what the per-net gap cap already bounds), and turns the
    // rest away entirely rather than half-attempting them.
    try expectNetOrder(&.{ 5, 7, 3 }, try order(arena, &found, .{ .max_targets = 3 }));
}

// spec: placement/target-unblock - an unblock target whose net has fewer island gaps left is attempted before one with more, whatever their hop lengths, because the fewer-gap net is the one an accept finishes
test "a net one gap from closed outranks a shorter hop on a many-gap rail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // barracuda's v91 residual, exactly: `GND` finishes as ONE 1.27 mm hop
    // between two islands — one accept from a closed net — and `V_3V3A` is eight
    // islands whose shortest pocket is 0.99 mm. Flat cheapest-hop-first put the
    // rail's pocket first on 0.03 mm and the tail ran out before `GND` was ever
    // attempted, so the board's closest win was never tried.
    const found = [_]Target{
        .{ .net_i = 28, .gap_mm = 0.99, .kind = .one_gap, .gaps = 7 },
        .{ .net_i = 18, .gap_mm = 1.27, .kind = .one_gap, .gaps = 1 },
    };
    try expectNetOrder(&.{ 18, 28 }, try order(arena, &found, .{}));

    // The gap count leads whatever the lengths: a 55 mm hop that finishes its
    // net still outranks a millimetre-long merge on a rail six accepts from
    // closed.
    const lopsided = [_]Target{
        .{ .net_i = 28, .gap_mm = 0.99, .kind = .one_gap, .gaps = 7 },
        .{ .net_i = 11, .gap_mm = 55.27 },
    };
    try expectNetOrder(&.{ 11, 28 }, try order(arena, &lopsided, .{}));

    // Within ONE gap count the shortest hop still leads, and the net index still
    // breaks an exact tie — the rule this one sits on top of, not in place of.
    const level = [_]Target{
        .{ .net_i = 9, .gap_mm = 42.541 },
        .{ .net_i = 1, .gap_mm = 42.541 },
        .{ .net_i = 4, .gap_mm = 1.27 },
    };
    try expectNetOrder(&.{ 4, 1, 9 }, try order(arena, &level, .{}));
}

/// The attempted nets, in order — the whole of what a round-robin ordering
/// promises, so a test states it once instead of indexing its way through.
fn expectNetOrder(want: []const usize, attempted: []const Target) !void {
    try testing.expectEqual(want.len, attempted.len);
    for (want, attempted) |w, got| try testing.expectEqual(w, got.net_i);
}

// spec: placement/target-unblock - each unblock transaction gets an equal share of the route budget's remainder, floored and capped, and none is started once too little of it is left
test "the slice is an equal share of the remainder, floored and capped" {
    const lim = Limits{};
    // Four targets, 46 s left: the last 6 s are the reserve, so 10 s each —
    // which is also the cap.
    const wide = sliceDeadline(0, 46 * clock.ns_per_s, 4, lim).?;
    try testing.expectEqual(@as(i128, 10 * clock.ns_per_s), wide);
    // The cap holds when the share would be larger — one target may not take a
    // whole 60 s tail.
    try testing.expectEqual(
        @as(i128, 10 * clock.ns_per_s),
        sliceDeadline(0, 60 * clock.ns_per_s, 1, lim).?,
    );
    // Four targets, 8 s of spendable budget: the 2 s share is below the floor,
    // so the first transaction gets 3 s and the tail runs out under the ones
    // behind it — deliberately, since a 2 s slice cannot route a corridor.
    try testing.expectEqual(
        @as(i128, 3 * clock.ns_per_s),
        sliceDeadline(0, 14 * clock.ns_per_s, 4, lim).?,
    );
    // Under the floor, and past the deadline: the pass stops rather than
    // starting a transaction it must then drop unmeasured.
    try testing.expect(sliceDeadline(0, 8 * clock.ns_per_s, 4, lim) == null);
    try testing.expect(sliceDeadline(11 * clock.ns_per_s, 10 * clock.ns_per_s, 1, lim) == null);
    try testing.expect(sliceDeadline(0, 40 * clock.ns_per_s, 0, lim) == null);
    // An unbudgeted route still bounds this speculative tier.
    try testing.expectEqual(@as(i128, 5 + 10 * clock.ns_per_s), sliceDeadline(5, 0, 3, lim).?);
}

// spec: placement/target-unblock - the unblock pass never spends the end of the route budget, so the additive connectivity close behind it still has a slice
test "the pass reserves the end of the budget for the close behind it" {
    const lim = Limits{};
    // 12 s left, one target: it may spend 6 and must leave 6.
    try testing.expectEqual(@as(i128, 6 * clock.ns_per_s), sliceDeadline(0, 12 * clock.ns_per_s, 1, lim).?);
    // Inside the reserve nothing is started at all, however many targets remain.
    try testing.expect(sliceDeadline(0, 6 * clock.ns_per_s, 1, lim) == null);
    try testing.expect(sliceDeadline(0, 7 * clock.ns_per_s, 4, lim) == null);
    // A caller that wants the whole budget says so, and then the floor alone
    // decides — the reserve is policy, not a hidden constant.
    const greedy = Limits{ .slice = .{ .reserve_ns = 0 } };
    try testing.expectEqual(
        @as(i128, 6 * clock.ns_per_s),
        sliceDeadline(0, 6 * clock.ns_per_s, 1, greedy).?,
    );
}

// spec: placement/target-unblock - a transaction is closed only when the oracle connects its target and reconnects every net it ripped
test "a closed transaction connects the target and every ripped blocker" {
    const open = [_][]const u8{ "LOCK_DET", "V_3V3A" };
    // The target and both ripped blockers are off the oracle's open list.
    try testing.expect(transactionClosed(&open, &.{ "EN_BUCK6V", "SPI_MOSI", "I2C_SCL" }));
    // The target closed but a ripped blocker did not come back.
    try testing.expect(!transactionClosed(&open, &.{ "EN_BUCK6V", "V_3V3A" }));
    // Every blocker is back and the target is still open — the trade this tier
    // exists to refuse, and the one a whole-board count alone would allow.
    try testing.expect(!transactionClosed(&open, &.{ "LOCK_DET", "SPI_MOSI" }));
    // A board with nothing open closes any transaction; a transaction naming
    // nothing is vacuously closed and is never formed (see `unblockOne`).
    try testing.expect(transactionClosed(&.{}, &.{"LOCK_DET"}));
    try testing.expect(transactionClosed(&open, &.{}));
}

// spec: placement/target-unblock - the pass's shared accept gate is sized for a ladder of island merges rather than for a handful of rescue attempts, and its budget may only be raised
test "the pass's accept gate weighs a whole merge ladder" {
    // `fine_accept`'s default is the wrong shape for this pass: one many-islanded
    // rail spends an evaluation per island it merges, and past the budget an
    // attempt is refused rather than admitted unmeasured.
    const lim = Limits{};
    try testing.expect(lim.max_evaluations > fine_accept.max_evaluations);
    // Enough for the planned targets AND the re-entry ladders they earn: six
    // nets, each of which may arrive in as many islands as barracuda's `GND`.
    try testing.expect(lim.max_evaluations >= lim.max_targets * 8);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    var gate = try Gate.init(arena_state.allocator(), placement, &.{});
    defer gate.deinit();
    const base = gate.inner.budget;
    gate.allowEvaluations(lim.max_evaluations);
    try testing.expectEqual(lim.max_evaluations, gate.inner.budget);
    // Raises only — a caller asking for less keeps what the gate already had.
    gate.allowEvaluations(base);
    try testing.expectEqual(lim.max_evaluations, gate.inner.budget);
}

// spec: placement/target-unblock - ground copper a plane or pour carries is displaceable by an unblock transaction, while ground with nothing behind it stays refused
test "plane-carried ground is displaceable and bare ground is not" {
    const lim = blockerLimits(.{});
    const seed = vacate_policy.Seed{ .net_i = 1 };
    const carried = blockerFacts(.{
        .net_i = 3,
        .protected = .{ .ground = true },
        .pour_carried = true,
        .whole = true,
        .elements = 4,
    });
    try testing.expect(!carried.protected.ground);
    try testing.expectEqual(vacate_policy.Kind.pour_carried, vacate_policy.judge(carried, seed, lim).accept);
    // No plane or pour behind it: its tracks are its connectivity, so it stays
    // the one class no cheapness argument may touch.
    const bare = blockerFacts(.{
        .net_i = 3,
        .protected = .{ .ground = true },
        .whole = true,
        .elements = 4,
    });
    try testing.expect(bare.protected.ground);
    try testing.expectEqual(vacate_policy.Refusal.ground, vacate_policy.judge(bare, seed, lim).refuse);
    // Every other protection is untouched, pour or no pour.
    const rf = blockerFacts(.{
        .net_i = 3,
        .protected = .{ .rf = true },
        .pour_carried = true,
        .whole = true,
        .elements = 4,
    });
    try testing.expectEqual(vacate_policy.Refusal.rf_max_freq, vacate_policy.judge(rf, seed, lim).refuse);
    const fenced = blockerFacts(.{
        .net_i = 3,
        .protected = .{ .ground = true, .fenced = true },
        .pour_carried = true,
        .whole = true,
        .elements = 4,
    });
    try testing.expectEqual(vacate_policy.Refusal.fenced, vacate_policy.judge(fenced, seed, lim).refuse);
}

// spec: placement/target-unblock - a declared differential pair is displaceable only under a tier that turns pair recoupling on and names the twin it will rip with it
test "a pair is nominated only with the recouple switch and a twin binding" {
    const seed = vacate_policy.Seed{ .net_i = 1, .priority = 2 };
    // barracuda's REF_LMX_P shape: a `lvds-ref` (priority 5) leg carrying 11
    // elements, its twin another 9, sealing a `control` (priority 2) corridor.
    const base = vacate_policy.NetFacts{
        .net_i = 4,
        .protected = .{ .diff_pair = .protected },
        .whole = true,
        .rank = .{ .priority = 5 },
        .elements = 11,
    };
    const bind = PairBinding{ .twin = 5, .elements = 20 };
    const wide = Limits{ .negotiate = .{ .pairs = true } };

    // The narrow tier refuses it exactly as it always has, binding or no binding.
    const narrow_facts = pairFacts(base, .{}, bind);
    try testing.expectEqual(vacate_policy.PairGuard.protected, narrow_facts.protected.diff_pair);
    try testing.expectEqual(
        vacate_policy.Refusal.diff_pair,
        vacate_policy.judge(narrow_facts, seed, blockerLimits(.{})).refuse,
    );
    // So does the wide tier when the driver could not resolve a twin to rip.
    const unbound = pairFacts(base, wide, null);
    try testing.expectEqual(vacate_policy.PairGuard.protected, unbound.protected.diff_pair);
    try testing.expectEqual(
        vacate_policy.Refusal.diff_pair,
        vacate_policy.judge(unbound, seed, blockerLimits(wide)).refuse,
    );
    // A net that is not a pair member at all gains nothing from either.
    var solo = base;
    solo.protected.diff_pair = .none;
    solo.elements = 4;
    try testing.expectEqual(@as(usize, 4), pairFacts(solo, wide, bind).elements);
    try testing.expectEqual(vacate_policy.PairGuard.none, pairFacts(solo, wide, bind).protected.diff_pair);
    // With both, the pair is nominated — and charged for BOTH legs' copper, so
    // the transaction's budget governs the restore it actually has to re-lay.
    const claimed = pairFacts(base, wide, bind);
    try testing.expectEqual(vacate_policy.PairGuard.recouplable, claimed.protected.diff_pair);
    try testing.expectEqual(@as(usize, 20), claimed.elements);
    try testing.expectEqual(
        vacate_policy.Kind.pair_recouple,
        vacate_policy.judge(claimed, seed, blockerLimits(wide)).accept,
    );
    // The ground adjustment still applies alongside it, and neither invents a
    // fact for a net that has neither.
    var plane_ground = base;
    plane_ground.protected = .{ .ground = true };
    plane_ground.pour_carried = true;
    try testing.expect(!pairFacts(plane_ground, wide, null).protected.ground);
}

// spec: placement/target-unblock - a plane- or pour-carried blocker is charged for the corridor copper a lifting tier will actually remove, so a heavily stitched ground is negotiable instead of refused for its size
test "a lifted plane net is charged for its corridor, not for the whole net" {
    const seed = vacate_policy.Seed{ .net_i = 1 };
    const wide = Limits{ .negotiate = .{ .plane_corridor = true } };
    // barracuda's `GND`: whole, plane-carried, and 300 elements of stitch field
    // — of which 5 lie in the channel the target has to cross.
    const ground = blockerFacts(.{
        .net_i = 3,
        .protected = .{ .ground = true },
        .pour_carried = true,
        .whole = true,
        .elements = 300,
    });
    // Refused for its SIZE by every tier that would have to re-lay all of it.
    const whole = try vacate_policy.select(
        testing.allocator,
        &.{ground},
        seed,
        blockerLimits(.{}),
    );
    defer testing.allocator.free(whole.picked);
    defer testing.allocator.free(whole.refused);
    try testing.expectEqual(@as(usize, 0), whole.picked.len);
    try testing.expectEqual(vacate_policy.Refusal.over_budget, whole.refused[0].why);

    // Charged for the corridor, it fits — and it is still the same pour-carried
    // nomination, judged by the same rule.
    const lifted = liftFacts(ground, wide, 5);
    try testing.expectEqual(@as(usize, 5), lifted.elements);
    try testing.expectEqual(vacate_policy.Kind.pour_carried, vacate_policy.judge(lifted, seed, blockerLimits(wide)).accept);

    // The discount is confined to what it is argued for. A tier with the switch
    // off, a net no plane or pour carries, a driver that measured nothing, and
    // a corridor holding the whole net all keep the whole-net charge.
    try testing.expectEqual(@as(usize, 300), liftFacts(ground, .{}, 5).elements);
    try testing.expectEqual(@as(usize, 300), liftFacts(ground, wide, null).elements);
    try testing.expectEqual(@as(usize, 300), liftFacts(ground, wide, 0).elements);
    try testing.expectEqual(@as(usize, 300), liftFacts(ground, wide, 300).elements);
    var bare = ground;
    bare.pour_carried = false;
    try testing.expectEqual(@as(usize, 300), liftFacts(bare, wide, 5).elements);
}

/// Judge `rail` under `lim` with the driver's corridor measurement, and expect
/// the rank guard to have held it out — the refusal every tier but the
/// declaring one keeps.
fn expectRankRefused(rail: vacate_policy.NetFacts, lim: Limits, corridor: ?usize) !void {
    const facts = rankFacts(rail, lim, corridor);
    try testing.expect(!facts.rank.negotiable);
    try testing.expectEqual(
        vacate_policy.Refusal.outranks_seed,
        vacate_policy.judge(facts, .{ .net_i = 1, .priority = 0 }, blockerLimits(lim)).refuse,
    );
}

// spec: placement/target-unblock - a blocker held out on authored rank alone is negotiable to a tier that declares it, charged for the corridor copper it will lift, while a tier without the switch, or a blocker with no copper in the corridor, keeps today's refusal
test "an outranking blocker is negotiable only to a tier that declares it" {
    const seed = vacate_policy.Seed{ .net_i = 1, .priority = 0 };
    // barracuda's `V_24V_CLEAN` shape: whole, unpoured, outranking the stuck
    // control net whose corridor it seals, and far past the stub cap.
    const rail = vacate_policy.NetFacts{
        .net_i = 4,
        .whole = true,
        .rank = .{ .priority = 4 },
        .elements = 60,
    };
    const deep = Limits{ .negotiate = .{ .outranking = true } };

    // Every tier without the switch refuses it on rank, whatever the driver
    // measured — including the wide tier, which negotiates the other two classes.
    const wide = Limits{ .negotiate = .{ .pairs = true, .plane_corridor = true } };
    try expectRankRefused(rail, .{}, 6);
    try expectRankRefused(rail, wide, 6);
    try testing.expectEqual(@as(usize, 60), rankFacts(rail, wide, 6).elements);

    // Under the deepening round's switch it is nominated, and charged for the
    // corridor copper the lift will actually take rather than for the net.
    const negotiated = rankFacts(rail, deep, 6);
    try testing.expect(negotiated.rank.negotiable);
    try testing.expectEqual(@as(usize, 6), negotiated.elements);
    try testing.expectEqual(
        vacate_policy.Kind.rank_lifted,
        vacate_policy.judge(negotiated, seed, blockerLimits(deep)).accept,
    );

    // A driver that measured nothing, or measured no copper in the corridor,
    // has named no lift — so there is nothing to negotiate and the refusal stands.
    try expectRankRefused(rail, deep, null);
    try expectRankRefused(rail, deep, 0);
    // A corridor holding the whole net is charged for the whole net, never more.
    try testing.expectEqual(@as(usize, 60), rankFacts(rail, deep, 900).elements);

    // The switch stands down the RANK guard alone: an RF net, a fenced trace and
    // a still-open net in the same corridor are refused exactly as before.
    var rf = rail;
    rf.protected.rf = true;
    try testing.expectEqual(
        vacate_policy.Refusal.rf_max_freq,
        vacate_policy.judge(rankFacts(rf, deep, 6), seed, blockerLimits(deep)).refuse,
    );
    var fenced = rail;
    fenced.protected.fenced = true;
    try testing.expectEqual(
        vacate_policy.Refusal.fenced,
        vacate_policy.judge(rankFacts(fenced, deep, 6), seed, blockerLimits(deep)).refuse,
    );
    var open = rail;
    open.whole = false;
    try testing.expectEqual(
        vacate_policy.Refusal.not_whole,
        vacate_policy.judge(rankFacts(open, deep, 6), seed, blockerLimits(deep)).refuse,
    );
}

// spec: placement/target-unblock - a transaction's rip budget and corridor band are sized by the length of the corridor it is clearing, so a cross-board join is not held to the bounds an endpoint pocket was sized for, and both stay bounded
test "a transaction's budget and band grow with its corridor, and stop" {
    const lim = Limits{};
    // An endpoint pocket keeps exactly the flat bounds it was sized for, and
    // `blockerLimits` is that same zero-corridor reading, so every existing
    // caller is unchanged.
    try testing.expectEqual(lim.blockers.max_total_elements, corridorLimits(lim, 0).max_total_elements);
    try testing.expectEqual(blockerLimits(lim).max_total_elements, corridorLimits(lim, 0).max_total_elements);
    try testing.expectApproxEqAbs(lim.corridor.mm, corridorRadius(lim, 0), 1e-12);
    // A 55 mm cross-board join — the shape of this tier's hardest targets —
    // gets a budget proportional to the copper such a corridor holds.
    const wide = corridorLimits(lim, 55);
    try testing.expectEqual(@as(usize, 48 + 110), wide.max_total_elements);
    try testing.expectApproxEqAbs(@as(f64, 2.0 + 55 * 0.03), corridorRadius(lim, 55), 1e-12);
    // Only the element budget moves: how many separate nets one all-or-nothing
    // restore must reproduce is a property of the risk, not of the length.
    try testing.expectEqual(lim.blockers.max_nets, wide.max_nets);
    try testing.expectEqual(lim.blockers.stub_max_elements, wide.stub_max_elements);
    // Both bounds stop. A pathological corridor may not propose to rip the
    // board, and the band may not grow until it nominates every net on it.
    try testing.expectEqual(lim.corridor.max_elements, corridorLimits(lim, 10_000).max_total_elements);
    try testing.expectApproxEqAbs(lim.corridor.mm + lim.corridor.bow_max_mm, corridorRadius(lim, 10_000), 1e-12);
    // The corridor is the total straight length of the hops being opened, so a
    // multi-island target is sized by all of them rather than by whichever the
    // sweep happened to read first.
    const hops = [_]blocker_nomination.Hop{
        .{ .ax = 0, .ay = 0, .bx = 3, .by = 4 }, // 5 mm
        .{ .ax = 0, .ay = 0, .bx = 6, .by = 8 }, // 10 mm
    };
    try testing.expectApproxEqAbs(@as(f64, 15), corridorLength(&hops), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), corridorLength(&.{}), 1e-12);
}

// spec: placement/target-unblock - a transaction's slice cap grows with the rip authority its corridor bought it, saturating where that authority does and stopping at its own ceiling, while the pass's equal share still bounds what is handed out
test "the slice cap follows the corridor's own rip budget" {
    // The wide tier's shape: a 128-element base budget, 45 s for it, and this
    // cap's own implied rate (45 s / 128) carried on to every extra element.
    const wide = Limits{
        .blockers = .{ .max_nets = 6, .max_total_elements = 128 },
        .slice = .{
            .max_ns = 45 * clock.ns_per_s,
            .ns_per_element = 350 * clock.ns_per_ms,
            .ceiling_ns = 90 * clock.ns_per_s,
        },
    };
    // An endpoint pocket bought no extra rip, so it buys no extra clock.
    try testing.expectEqual(wide.slice.max_ns, corridorSlice(wide, 0).slice.max_ns);
    // barracuda's `LOCK_DET`: a 55.27 mm corridor is charged 110 elements over
    // the base budget, and takes 110 elements' worth of clock with them.
    try testing.expectEqual(@as(usize, 128 + 110), corridorLimits(wide, 55.27).max_total_elements);
    const lock_det = corridorSlice(wide, 55.27);
    try testing.expectEqual(
        @as(i128, 45 * clock.ns_per_s + 110 * 350 * clock.ns_per_ms),
        lock_det.slice.max_ns,
    );
    // Nothing else about the tier moves — this sizes the clock and only the
    // clock, exactly as `corridorLimits` sizes the copper and only the copper.
    try testing.expectEqual(wide.blockers.max_nets, lock_det.blockers.max_nets);
    try testing.expectEqual(wide.blockers.max_total_elements, lock_det.blockers.max_total_elements);
    try testing.expectEqual(wide.slice.min_ns, lock_det.slice.min_ns);
    try testing.expectEqual(wide.slice.reserve_ns, lock_det.slice.reserve_ns);
    // The growth SATURATES where the rip does: past `Corridor.max_elements` a
    // longer corridor buys no more copper, so it must buy no more time.
    const saturated: i128 = 45 * clock.ns_per_s + (256 - 128) * 350 * clock.ns_per_ms;
    try testing.expectEqual(saturated, corridorSlice(wide, 10_000).slice.max_ns);
    try testing.expectEqual(saturated, corridorSlice(wide, 64).slice.max_ns);
    // ... and the ceiling is the second, absolute stop, for a tier whose rate
    // and corridor bounds would otherwise run past it.
    var capped = wide;
    capped.slice.ceiling_ns = 60 * clock.ns_per_s;
    try testing.expectEqual(@as(i128, 60 * clock.ns_per_s), corridorSlice(capped, 55.27).slice.max_ns);
    // A ceiling under the tier's own base cap is a mis-declaration and never
    // hands out a slice SHORTER than the flat one the tier was measured on.
    capped.slice.ceiling_ns = 1;
    try testing.expectEqual(wide.slice.max_ns, corridorSlice(capped, 55.27).slice.max_ns);
    // A tier that declares no rate is untouched at any corridor length: the
    // narrow transaction and every clock-free board keep the flat cap.
    const narrow = Limits{};
    try testing.expectEqual(@as(i128, 0), narrow.slice.ns_per_element);
    try testing.expectEqual(narrow.slice.max_ns, corridorSlice(narrow, 55.27).slice.max_ns);
    // And a grown cap is not a licence to overspend: the equal share and the
    // remainder still stand between it and the clock, so three targets sharing
    // 66 s of spendable budget get 22 s each and not 83.5.
    const budget = 66 * clock.ns_per_s + lock_det.slice.reserve_ns;
    try testing.expectEqual(
        @as(i128, 22 * clock.ns_per_s),
        sliceDeadline(0, budget, 3, lock_det).?,
    );
    // The LAST target inherits what the others left, up to the grown cap.
    try testing.expectEqual(
        @as(i128, 66 * clock.ns_per_s),
        sliceDeadline(0, budget, 1, lock_det).?,
    );
    try testing.expectEqual(
        @as(i128, 45 * clock.ns_per_s),
        sliceDeadline(0, budget, 1, wide).?,
    );
}

// spec: placement/target-unblock - a transaction's slice cap also grows with the copper its own restore has to re-lay, charged at the same per-element rate under the same ceiling, and a tier that declares no rate keeps its flat cap
test "the slice cap follows the restore the transaction actually took on" {
    // The narrow tier's shape: a flat 10 s cap for forming at all, and the one
    // rate — the wide tier's own 45 s / 128 elements read back off itself —
    // charged for the copper this transaction has to put back.
    const narrow = Limits{ .slice = .{ .ns_per_element = 350 * clock.ns_per_ms } };
    // barracuda's `GND` ladder, rung by rung: 7 elements, then 10, then the
    // 12-element restore the flat cap cut off mid-re-route.
    try testing.expectEqual(
        @as(i128, 10 * clock.ns_per_s + 7 * 350 * clock.ns_per_ms),
        restoreSlice(narrow, 7).slice.max_ns,
    );
    try testing.expectEqual(
        @as(i128, 10 * clock.ns_per_s + 12 * 350 * clock.ns_per_ms),
        restoreSlice(narrow, 12).slice.max_ns,
    );
    // A transaction that took nothing earns nothing, and nothing else about the
    // tier moves: this sizes the clock and only the clock.
    try testing.expectEqual(narrow.slice.max_ns, restoreSlice(narrow, 0).slice.max_ns);
    const rung = restoreSlice(narrow, 12);
    try testing.expectEqual(narrow.blockers.max_total_elements, rung.blockers.max_total_elements);
    try testing.expectEqual(narrow.slice.min_ns, rung.slice.min_ns);
    try testing.expectEqual(narrow.slice.reserve_ns, rung.slice.reserve_ns);
    // The ceiling is the absolute stop here exactly as it is for the corridor
    // reading — a rip at the tier's own element cap may not buy unbounded clock.
    var capped = narrow;
    capped.slice.ceiling_ns = 12 * clock.ns_per_s;
    try testing.expectEqual(@as(i128, 12 * clock.ns_per_s), restoreSlice(capped, 48).slice.max_ns);
    // A tier that declares NO rate keeps its flat cap for any restore, which is
    // what leaves every clock-free board and every caller on the defaults
    // byte-identical.
    try testing.expectEqual(Limits{}, restoreSlice(.{}, 48));
    // And a grown cap is not a licence to overspend: the equal share still
    // stands between it and the clock.
    const budget = 30 * clock.ns_per_s + narrow.slice.reserve_ns;
    try testing.expectEqual(
        @as(i128, 10 * clock.ns_per_s),
        sliceDeadline(0, budget, 3, rung).?,
    );
    try testing.expectEqual(
        @as(i128, 10 * clock.ns_per_s + 12 * 350 * clock.ns_per_ms),
        sliceDeadline(0, budget, 1, rung).?,
    );
}

// spec: placement/target-unblock - a formed transaction may claim what its own restore is priced at when that beats its equal share of the remainder, never past the grown cap and never into the floor every target behind it is still owed, and a clock-free board or a rateless tier keeps the equal-share answer
test "a formed transaction claims the clock its own restore is priced at" {
    const wide = Limits{
        .blockers = .{ .max_nets = 6, .max_total_elements = 128 },
        .slice = .{
            .max_ns = 45 * clock.ns_per_s,
            .ns_per_element = 350 * clock.ns_per_ms,
            .ceiling_ns = 90 * clock.ns_per_s,
        },
    };
    // barracuda's v92 tail: 89 s reserved, six targets, and `SPI_LMX_CSN` ripping
    // a 66-element pour-carried rail plus two stubs — 71 elements, ~24.85 s of
    // re-route at the tier's own rate.
    const tail: i128 = 89 * clock.ns_per_s;
    const budget = tail + wide.slice.reserve_ns;
    const priced: i128 = 71 * 350 * clock.ns_per_ms;
    // The equal share is what quoted it ~14 s and produced `slice_expired`.
    const share = @divTrunc(tail, 6);
    try testing.expectEqual(share, sliceDeadline(0, budget, 6, restoreSlice(wide, 71)).?);
    try testing.expect(share < priced);
    // Priced instead, the transaction gets the clock its own copper costs.
    try testing.expectEqual(priced, restoreDeadline(0, budget, 6, wide, 71).?);

    // MONOTONE: a restore cheaper than the share never shortens the slice, and a
    // lone target still takes the whole grown cap rather than its own price.
    try testing.expectEqual(share, restoreDeadline(0, budget, 6, wide, 2).?);
    try testing.expectEqual(
        sliceDeadline(0, budget, 1, restoreSlice(wide, 71)).?,
        restoreDeadline(0, budget, 1, wide, 71).?,
    );

    // The claim never eats the floor the targets behind it are owed: five more
    // targets at `min_ns` each is 15 s of a 20 s remainder, so the priced 24.85 s
    // is cut to the 5 s that is genuinely spare.
    const thin = 20 * clock.ns_per_s + wide.slice.reserve_ns;
    try testing.expectEqual(
        @as(i128, 5 * clock.ns_per_s),
        restoreDeadline(0, thin, 6, wide, 71).?,
    );
    // …and never below the floor itself, nor past the remainder.
    try testing.expect(restoreDeadline(0, thin, 6, wide, 71).? >= wide.slice.min_ns);
    try testing.expect(restoreDeadline(0, budget, 6, wide, 10_000).? <= budget);
    // The grown cap is still the stop: 10_000 elements is priced far past it.
    try testing.expectEqual(
        restoreSlice(wide, 10_000).slice.max_ns,
        restoreDeadline(0, 10 * budget, 1, wide, 10_000).?,
    );
    // A pass with nothing left, and one with nothing to spend it on, still end.
    try testing.expect(restoreDeadline(0, wide.slice.reserve_ns + 1, 6, wide, 71) == null);
    try testing.expect(restoreDeadline(0, budget, 0, wide, 71) == null);

    // A clock-free board and a tier that declares no rate are the equal-share
    // answer verbatim, which is what keeps every bench and test route unchanged.
    try testing.expectEqual(
        sliceDeadline(0, 0, 6, restoreSlice(wide, 71)).?,
        restoreDeadline(0, 0, 6, wide, 71).?,
    );
    const narrow = Limits{};
    try testing.expectEqual(
        sliceDeadline(0, budget, 6, narrow).?,
        restoreDeadline(0, budget, 6, narrow, 71).?,
    );
}

// spec: placement/target-unblock - the tail an earlier phase must hold back is this tier's own corridor slice for the widest target plus the additive close's reserve, held under the caller's ceiling
test "the tail an earlier phase reserves is this tier's own slice for its widest target" {
    const wide = Limits{
        .blockers = .{ .max_nets = 6, .max_total_elements = 128 },
        .slice = .{
            .max_ns = 45 * clock.ns_per_s,
            .ns_per_element = 350 * clock.ns_per_ms,
            .ceiling_ns = 90 * clock.ns_per_s,
        },
    };
    const cap: i128 = 100 * clock.ns_per_s;
    // barracuda's widest residual corridor, `LOCK_DET` at 55.27 mm: the grown
    // slice its own rip authority buys, plus the additive close's reserve.
    const lock_det = corridorSlice(wide, 55.27).slice.max_ns;
    try testing.expectEqual(lock_det + wide.slice.reserve_ns, phaseReserve(wide, 55.27, cap));
    // A short corridor reserves the flat slice and no more: the tail follows the
    // work the tier will actually be asked to do.
    try testing.expectEqual(wide.slice.max_ns + wide.slice.reserve_ns, phaseReserve(wide, 0, cap));
    try testing.expect(phaseReserve(wide, 1.27, cap) < phaseReserve(wide, 55.27, cap));
    // The tail saturates where the rip authority does, so an arbitrarily long
    // corridor asks for a bounded tail even before the caller's ceiling: the
    // tier's own `slice.ceiling_ns` plus the close's reserve.
    const saturated = corridorSlice(wide, 10_000).slice.max_ns + wide.slice.reserve_ns;
    try testing.expectEqual(saturated, phaseReserve(wide, 10_000, cap));
    try testing.expect(saturated < cap);
    // And the caller's ceiling is the last word, so no tier's arithmetic can
    // turn a tail into the route.
    try testing.expectEqual(@as(i128, 5), phaseReserve(wide, 55.27, 5));
}

// spec: placement/target-unblock - a re-laid differential pair is kept only when both legs carry copper, its coupling window is no worse and its skew is within the constructor's equalisation window of what it was
test "a pair negotiation is held to the pair it replaced" {
    const before = PairHealth{ .legs_with_copper = 2, .uncoupled = 0, .skew_mm = 0.02 };
    // Re-laid coupled: both legs down, still inside the coupling window, skew
    // inside the constructor's own equalisation slack.
    try testing.expect(pairHeld(before, .{ .legs_with_copper = 2, .skew_mm = 0.04 }));
    try testing.expect(pairHeld(before, .{ .legs_with_copper = 2, .skew_mm = 0.07 })); // exactly the slack
    // The legacy fallback: two independently mazed legs. No `diff_skew` finding
    // (the rule's window is a whole millimetre) and the gate refuses it anyway,
    // which is the reason skew is measured rather than read off the DRC.
    try testing.expect(!pairHeld(before, .{ .legs_with_copper = 2, .skew_mm = 0.9 }));
    // A pair that came apart, and a pair only half re-laid.
    try testing.expect(!pairHeld(before, .{ .legs_with_copper = 2, .uncoupled = 1, .skew_mm = 0.02 }));
    try testing.expect(!pairHeld(before, .{ .legs_with_copper = 1, .skew_mm = 0.0 }));
    try testing.expect(!pairHeld(before, .{ .legs_with_copper = 0 }));
    // A board whose pair was ALREADY loose is not made a reason to tighten it:
    // this tier may move a pair, and the rule it is held to is the pair it
    // found, not an absolute the design never met.
    const loose = PairHealth{ .legs_with_copper = 2, .uncoupled = 1, .skew_mm = 1.4 };
    try testing.expect(pairHeld(loose, .{ .legs_with_copper = 2, .uncoupled = 1, .skew_mm = 1.4 }));
    try testing.expect(!pairHeld(loose, .{ .legs_with_copper = 2, .uncoupled = 2, .skew_mm = 1.4 }));
}

// spec: placement/target-unblock - one unblock transaction rips at most three blockers and bounds the copper its restore must re-lay
test "the blocker limits cap the transaction's width and copper" {
    const lim = blockerLimits(.{});
    try testing.expectEqual(@as(usize, 3), lim.max_nets);
    try testing.expectEqual(@as(usize, 48), lim.max_total_elements);
    try testing.expectEqual(@as(usize, 12), lim.stub_max_elements);
    // A caller's narrower bounds carry through unchanged.
    const tight = blockerLimits(.{ .blockers = .{ .max_nets = 1, .max_total_elements = 8 } });
    try testing.expectEqual(@as(usize, 1), tight.max_nets);
    try testing.expectEqual(@as(usize, 8), tight.max_total_elements);
    // A 40-element rail is too much copper to re-lay inside one gate unless a
    // pour underwrites its restore — `vacate_policy.judge`'s rule, and the
    // reason this cap is separate from the transaction's total.
    const fat = vacate_policy.judge(
        .{ .net_i = 2, .whole = true, .elements = 40 },
        .{ .net_i = 1 },
        lim,
    );
    try testing.expectEqual(vacate_policy.Refusal.not_cheap, fat.refuse);
    const poured = vacate_policy.judge(
        .{ .net_i = 2, .whole = true, .elements = 40, .pour_carried = true },
        .{ .net_i = 1 },
        lim,
    );
    try testing.expectEqual(vacate_policy.Kind.pour_carried, poured.accept);
}
