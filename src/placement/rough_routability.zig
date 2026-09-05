//! Routability awareness for the rough placement seed.
//!
//! The rough objective is wire length, loop inductance and compactness. None of
//! those asks whether the copper can be DRAWN, so the seed will happily pack a
//! ring flush enough to seal a pad's every escape, or lay a whole side's parts
//! in one column so the corridor behind them offers four lanes to six nets. The
//! router only reports "net X failed" after a full solve, and no ordering,
//! priority or effort tier fixes a wall.
//!
//! `placement/routability_lint.zig` already measures exactly that, in closed
//! form off the placement and the net classes — no router, no raster. This
//! module is the other half: it reads those findings DURING the rough solve and
//! repairs the ones a placement can answer.
//!
//!   * STACKED COURTYARDS — two parts on one spot. The seed does this (ten
//!     pairs on `w55rp20`), and it is the most extreme routability failure
//!     there is: the pads under the upper part have no exit in any direction,
//!     and the board is a courtyard-overlap DRC error. Separated first, because
//!     the sealed findings such a placement produces are one geometry restated
//!     many times and no per-pad push can answer them.
//!   * `pad-sealed` — a pad whose eight octilinear exits all sit inside foreign
//!     clearance. The finding names the near-miss blocker and the millimetres
//!     the move has to buy, so the repair is a push of that blocker directly
//!     away from the pad it seals.
//!   * `port-blocked` — a `(port …)` net that cannot LEAVE the block at all: no
//!     corridor from any of its pads to outside the courtyard bounding box, and
//!     nowhere reachable that a via of its class fits. This is the one failure
//!     nothing downstream reports — a port terminating on one pad has no
//!     airwire, no lane demand, and a one-pin net is not something the router
//!     routes — so a seed can fence `SPI_SCK` in completely and every other
//!     surface calls the board clean. Repaired like a sealed pad, but the push
//!     opens a whole lane rather than merely clearing the halo: the frontier's
//!     shortfall is a local number and backing a wall off by exactly that much
//!     leaves a corridor a track still cannot travel.
//!   * `escape-contended` — more nets leave a hub side than the tightest
//!     cross-section there has lanes for. The finding names the hub, the side
//!     and the cut, and the corridor is relieved two ways: STAGGER deals the
//!     parts crossing that cut into two depth ranks, so no cross-section is
//!     blocked by all of them; SPREAD keeps one rank and re-spaces them along
//!     the corridor so every neighbouring pair leaves free lane between them.
//!     A stagger is what the hand reference does — `straps-synth-lmx2595`'s
//!     starred layout spreads its east ring over three depths and offers 20
//!     lanes where the flush rough column offers 4 — but a net whose ideal
//!     crossing point is mid-corridor needs a lane THERE, which is the spread.
//!
//! `pad-corridor-tight` is deliberately NOT repaired: it compares two pads of
//! the SAME part, so it is a property of the footprint and the net class, and no
//! placement moves it. It is measured and reported, never acted on.
//!
//! Every move is bounded and conditional. A part may not be displaced past its
//! round's budget; a round is kept only when its own measure strictly improves
//! and nothing else it answers for gets worse, and is otherwise reverted whole.
//! A placement with no findings is therefore untouched byte for byte, which is
//! most of the corpus.
//!
//! Deterministic: findings arrive in the lint's own sorted order, blockers are
//! ordered along the corridor with ref-des as the tie-break, and nothing here
//! reads a clock or an RNG.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const routability_lint = @import("routability_lint.zig");

const Allocator = std.mem.Allocator;
const Placement = optimizer.Placement;
const Part = optimizer.Part;
const Finding = routability_lint.Finding;
const BoardRect = optimizer.BoardRect;

/// Counts of the static routability gates over one placement. `deficit` is the
/// headline: nets summed over every contended fan that the corridor there could
/// not seat. `corridor` is reported but never repaired (see the module note).
pub const Score = struct {
    sealed: usize = 0,
    corridor: usize = 0,
    contended: usize = 0,
    deficit: usize = 0,
    /// Port nets with no proven way out of the block (`port-blocked`).
    port_blocked: usize = 0,

    /// The part of the score a placement can move. Zero ⇒ nothing to repair.
    /// `port_blocked` counts here so every OTHER round is judged against it too:
    /// a stagger that seats two escaping nets by walling a port in is refused
    /// without any round needing to know what a port is.
    pub fn cost(self: Score) usize {
        return self.sealed + self.deficit + self.port_blocked;
    }
};

/// What one `repair` run did, for the caller to report. `ran` distinguishes "the
/// pass measured this placement and found nothing" from "no rough solve happened
/// on this request", which a zeroed struct otherwise conflates.
pub const Repair = struct {
    ran: bool = false,
    before: Score = .{},
    after: Score = .{},
    /// Parts whose pose the repair changed.
    moved: usize = 0,
    /// Overlapping courtyard pairs before the repair — the placement fault the
    /// sealed gate usually turns out to be reporting.
    stacked_before: usize = 0,
    stacked_after: usize = 0,
};

/// Largest total displacement one repair may give a part. Two ranks of an 0402
/// ring plus clearance is under a millimetre; past two the pass is no longer
/// repairing a placement, it is making a different one.
const max_shift_mm: f64 = 2.0;
/// Displacement budget for the overlap sweep. Larger than `max_shift_mm`
/// because un-stacking a part has to clear a whole courtyard, and a chain of
/// stacked parts clears more than one.
const overlap_shift_mm: f64 = 6.0;
/// Sweeps the overlap pass makes before giving up on a cascade.
const overlap_sweeps: usize = 24;
/// Contended fans repaired per run, worst first. The lint reports at most six;
/// a board whose fifth-worst escape still needs relief needs a different
/// placement, not more nudging.
const max_fans: usize = 4;
/// Free lane the spread variant opens between two neighbouring courtyards along
/// a corridor — two signal lanes at the usual 0.254 mm pitch, plus margin.
const lane_open_mm: f64 = 0.6;
/// Gap left between the two ranks a stagger creates, beyond the deeper rank's
/// own courtyard — enough that the inner rank's cut sees free space.
const stagger_gap_mm: f64 = 0.2;
/// Millimetres a sealed-pad push buys beyond the finding's own shortfall, so the
/// move clears the halo instead of landing exactly on it.
const seal_margin_mm: f64 = 0.1;
/// Multiple of the net's full cross-section (`width + 2 x clearance`) a
/// port-escape push opens beyond the frontier's own shortfall. A sealed pad only
/// needs its halo cleared, but a blocked PORT needs a lane it can travel down:
/// the shortfall the finding reports is measured at one frontier cell, and
/// backing a wall off by exactly that leaves a corridor the very next cell
/// closes again. One full cross-section is the least that can ever be a lane.
const port_lane_mult: f64 = 1.0;
/// Half-width of the escape-axis window a part must cross to count as blocking
/// a cut. The lane scan's own halo is pitch/2; 0.2 mm covers every pitch this
/// corpus resolves.
const cut_halo_mm: f64 = 0.2;
/// Fraction of the rough objective a SOFT escape round may spend, PER net it
/// seats. This is the whole trade the guard encodes, and it is one-sided on
/// purpose: a stacked or sealed pad is a defect the board cannot be built with,
/// but `escape-contended` is a WARNING by its own gate's account — such a fan
/// "routes today, just in whatever order the router happens to arrive in" — so
/// relief there is only worth having while it is cheap in wire length, loop
/// inductance and compactness.
///
/// 3 % sits in a measured gap, not a guessed one. Priced over the 36-module
/// corpus (2026-08-10) the accepted soft rounds cost, per net seated:
/// `straps-mixer` 0.6 %, `bcuda-synth-lmx2595` 1.2 %, `bcuda-lt3045-ldo` 2.8 %,
/// `straps-synth-lmx2595` 4.5 %, `bcuda-pll-adf4159` 5.3 %, `board-b-xband-lo`
/// 8.8 %. The first three also moved the layout TOWARD the hand reference (or
/// left it alone) — `bcuda-lt3045-ldo` gained 7.2 style and 14.3 area points —
/// while the last three all moved it away, costing 2.2, 1.7 and 6.0 style
/// points. The break is between 2.8 and 4.5, and this constant is the middle of
/// it.
const soft_objective_per_seat: f64 = 0.03;

/// Roll a preflight result up into per-gate counts. Public so a reporting
/// surface that already holds the findings needn't run the pass twice.
pub fn tally(findings: []const Finding) Score {
    var s: Score = .{};
    for (findings) |f| {
        if (std.mem.eql(u8, f.rule, "pad-sealed")) s.sealed += 1;
        if (std.mem.eql(u8, f.rule, "pad-corridor-tight")) s.corridor += 1;
        if (std.mem.eql(u8, f.rule, "port-blocked")) s.port_blocked += 1;
        const esc = f.escape orelse continue;
        s.contended += 1;
        s.deficit += esc.nets -| esc.seated;
    }
    return s;
}

/// What a soft round prices the placement by: the rough solve's own smooth
/// surrogate objective (`optimizer.surrogateObjective`) over the current poses.
/// Supplied by the optimizer, the only caller holding the net index, the loop
/// list and the solve's weights. `null` leaves the soft rounds unpriced — the
/// unit fixtures pass none, and the hard rounds never consult it.
pub const Cost = struct {
    idx_of: *std.StringHashMapUnmanaged(usize),
    loops: []const optimizer.Loop,
    params: optimizer.Params,
};

/// What the caller knows that the `Placement` does not.
pub const Opts = struct {
    /// How a soft round prices the placement; null leaves them unpriced.
    cost: ?Cost = null,
    /// Net-index mask of the block's own `(port …)` nets
    /// (`port_escape.portNets`). Empty leaves the port gate — and so the port
    /// round — silent, which is every caller that cannot tell a port from any
    /// other net.
    port_nets: []const bool = &.{},
};

/// Repair what the placement can answer, mutating `p.parts` in place. Returns
/// the before/after score; a placement the gates find nothing on is not touched.
pub fn repair(alloc: Allocator, p: Placement, opts: Opts) Allocator.Error!Repair {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var state = try State.build(arena.allocator(), p, opts);
    const before = state.score;
    const ovl_before = state.overlaps;
    if (before.cost() == 0) return .{
        .ran = true,
        .before = before,
        .after = before,
        .stacked_before = ovl_before,
        .stacked_after = ovl_before,
    };
    // Stacked parts first: a courtyard sitting on top of another seals every pad
    // under it, so the pad gate's findings are mostly one geometry restated many
    // times and no per-pad push can answer them.
    if (state.score.sealed > 0) _ = try state.round(.overlap);
    _ = try state.round(.sealed);
    // A port that cannot leave is a defect of the same order, and unlike a
    // contended fan nothing downstream will ever report it, so this round is
    // hard too — unconditional, never priced against the objective.
    _ = try state.round(.port);
    // Fans are independent corridors — a side one variant cannot help says
    // nothing about the next one, so this never stops early. Two relief shapes
    // per fan: deal the corridor into two depths, else open lane gaps along it.
    for (0..max_fans) |fan| {
        if (try state.round(.{ .stagger = fan })) continue;
        _ = try state.round(.{ .spread = fan });
    }
    return .{
        .ran = true,
        .before = before,
        .after = state.score,
        .moved = state.movedCount(),
        .stacked_before = ovl_before,
        .stacked_after = state.overlaps,
    };
}

/// What a repair round does. `.stagger` and `.spread` are the two relief shapes
/// for one contended escape, named by its rank in the lint's worst-first order.
const Round = union(enum) {
    overlap,
    sealed,
    port,
    stagger: usize,
    spread: usize,

    /// The measure this round answers for.
    fn gate(self: Round) enum { stacked, sealed, port, deficit } {
        return switch (self) {
            .overlap => .stacked,
            .sealed => .sealed,
            .port => .port,
            .stagger, .spread => .deficit,
        };
    }
};

/// One round's before/after, so the accept test reads as one statement.
/// `stacked` is overlapping COURTYARD pairs — the physical "parts sit on each
/// other" the DRC flags, not the routing-gap keepout boxes the solver relaxes
/// against, because that is the measure the overlap sweep moves.
const Step = struct {
    before: Score,
    after: Score,
    stacked_before: usize,
    stacked_after: usize,
    /// The rough objective either side of the move, 0 when the caller supplied
    /// no `Cost` (then a soft round is unpriced — see `withinObjectiveBudget`).
    obj_before: f64,
    obj_after: f64,

    /// Accept when the round's own measure strictly improved and nothing else it
    /// answers for got worse.
    ///
    /// Un-stacking is judged on the stack count ALONE, unlike every other round.
    /// Two parts on one spot are not a trade-off a routability score is entitled
    /// to price: the board cannot be built that way — it is a courtyard-overlap
    /// DRC error — and the pads under the upper part are sealed by definition.
    /// Requiring the preflight score to improve as well refused the separation
    /// on `w55rp20`, whose rough seed stacks ten pairs, and left every one of
    /// its 27 sealed pads in place.
    ///
    /// A SOFT round — the two escape reliefs — additionally has to pay for
    /// itself in the objective the solve is actually minimising, because a
    /// contended fan is a warning, not a defect (`soft_objective_per_seat`).
    /// The port round is not soft: a module whose port cannot leave is unusable
    /// as designed, and no wire-length saving buys that back.
    fn acceptedShape(self: Step, which: Round) bool {
        const gate = which.gate();
        if (gate == .stacked) return self.stacked_after < self.stacked_before;
        if (self.stacked_after > self.stacked_before) return false;
        if (self.after.cost() >= self.before.cost()) return false;
        if (gate == .sealed) return self.after.sealed < self.before.sealed;
        if (gate == .port) return self.after.port_blocked < self.before.port_blocked;
        if (self.after.deficit >= self.before.deficit) return false;
        return true;
    }

    fn accepted(self: Step, which: Round) bool {
        if (!self.acceptedShape(which)) return false;
        if (which.gate() != .deficit) return true;
        return withinObjectiveBudget(self.obj_before, self.obj_after, self.before.deficit - self.after.deficit);
    }
};

/// True when a soft escape round's objective cost is within what its seats buy.
/// A non-positive `before` means the caller priced nothing, and an unpriced
/// round is not refused — the guard reports "no opinion", never "no".
fn withinObjectiveBudget(before: f64, after: f64, seats: usize) bool {
    if (before <= 0) return true;
    const budget = 1 + soft_objective_per_seat * @as(f64, @floatFromInt(seats));
    return after <= before * budget;
}

/// The preflight options one repair run makes every measurement under, so the
/// baseline score and each round's re-measure can never disagree about which
/// gates are live.
fn lintOpts(opts: Opts) routability_lint.Options {
    return .{ .port_nets = opts.port_nets };
}

/// The rough objective at `p`'s current poses, or 0 when the caller priced
/// nothing.
fn priceOf(p: Placement, cost: ?Cost) f64 {
    const c = cost orelse return 0;
    return optimizer.surrogateObjective(p.parts, c.idx_of, p.nets, c.loops, c.params);
}

/// Pairs of parts whose courtyards overlap on the same board side.
/// `courtyards` is caller-owned scratch reused across repair rounds so this
/// O(n²) scan transforms each part once, not once per pair.
fn stackedPairs(p: Placement, courtyards: []BoardRect) usize {
    std.debug.assert(courtyards.len == p.parts.len);
    for (p.parts, courtyards) |part, *rect| rect.* = optimizer.worldCourtyard(&part);
    var n: usize = 0;
    for (p.parts, 0..) |a, i| {
        const ra = courtyards[i];
        for (p.parts[i + 1 ..], courtyards[i + 1 ..]) |b, rb| {
            if (a.side != b.side) continue;
            const px = (ra.w + rb.w) / 2 - @abs((rb.minx + rb.w / 2) - (ra.minx + ra.w / 2));
            const py = (ra.h + rb.h) / 2 - @abs((rb.miny + rb.h / 2) - (ra.miny + ra.h / 2));
            if (px > 0 and py > 0) n += 1;
        }
    }
    return n;
}

/// The repair's working state. `scratch` is `repair`'s arena — findings are
/// never freed individually because the arena reclaims the whole run at once,
/// and a round that is kept has to hold on to the findings it produced.
const State = struct {
    p: Placement,
    scratch: Allocator,
    score: Score,
    findings: []const Finding,
    lint_cache: routability_lint.Cache,
    overlaps: usize,
    courtyards: []BoardRect,
    /// What the caller knows that the placement does not — the soft rounds'
    /// price model and the port-net mask.
    opts: Opts,
    /// The objective at the current poses, so a round pays for one evaluation
    /// rather than two.
    objective: f64,
    /// Overlapping courtyard pairs at the current poses (see `Step`).
    /// Per-part displacement already spent, so `max_shift_mm` binds across
    /// rounds rather than per round.
    shifted: []f64,
    origin: []const [2]f64,

    fn build(scratch: Allocator, p: Placement, opts: Opts) Allocator.Error!State {
        const shifted = try scratch.alloc(f64, p.parts.len);
        @memset(shifted, 0);
        const origin = try scratch.alloc([2]f64, p.parts.len);
        for (p.parts, origin) |part, *o| o.* = .{ part.x, part.y };
        const lint_cache = try routability_lint.Cache.build(scratch, p);
        const findings = try routability_lint.preflightCached(scratch, scratch, p, lintOpts(opts), lint_cache);
        const courtyards = try scratch.alloc(BoardRect, p.parts.len);
        const overlaps = stackedPairs(p, courtyards);
        return .{
            .p = p,
            .scratch = scratch,
            .score = tally(findings),
            .findings = findings,
            .lint_cache = lint_cache,
            .overlaps = overlaps,
            .courtyards = courtyards,
            .opts = opts,
            .objective = priceOf(p, opts.cost),
            .shifted = shifted,
            .origin = origin,
        };
    }

    fn movedCount(self: State) usize {
        var n: usize = 0;
        for (self.p.parts, self.origin) |part, o| {
            if (part.x != o[0] or part.y != o[1]) n += 1;
        }
        return n;
    }

    /// Run one round: propose the moves its gate asks for, apply them, and keep
    /// them only if that gate strictly improved without new overlap. Returns
    /// true when the round changed the placement.
    fn round(self: *State, which: Round) Allocator.Error!bool {
        const saved = try self.snapshot();
        if (!try self.propose(which)) return false;
        // A soft move can seat at most every currently missing lane. If its
        // objective exceeds even that largest possible budget, no preflight
        // result can make it acceptable, so reject before rebuilding geometry.
        var priced_after: ?f64 = null;
        if (which.gate() == .deficit and self.objective > 0) {
            priced_after = priceOf(self.p, self.opts.cost);
            if (!withinObjectiveBudget(self.objective, priced_after.?, self.score.deficit)) {
                self.restore(saved);
                return false;
            }
        }
        const found = try routability_lint.preflightRepairCached(self.scratch, self.scratch, self.p, lintOpts(self.opts), self.lint_cache);
        var after = tally(found);
        // The omitted corridor gate is pose-invariant for this x/y-only repair.
        // Keep its baseline count in the public before/after score.
        after.corridor = self.score.corridor;
        const step = Step{
            .before = self.score,
            .after = after,
            .stacked_before = self.overlaps,
            .stacked_after = stackedPairs(self.p, self.courtyards),
            .obj_before = self.objective,
            .obj_after = self.objective,
        };
        // Do not price a hard move that failed its gate, nor a soft move whose
        // geometry bought no seat. Objective is only relevant after that test.
        if (!step.acceptedShape(which)) {
            self.restore(saved);
            return false;
        }
        var final_step = step;
        final_step.obj_after = priced_after orelse priceOf(self.p, self.opts.cost);
        if (!final_step.accepted(which)) {
            self.restore(saved);
            return false;
        }
        self.score = step.after;
        self.findings = found;
        self.overlaps = step.stacked_after;
        self.objective = final_step.obj_after;
        return true;
    }

    /// Apply the round's own moves to the placement. True when something moved.
    /// The overlap sweep mutates directly (it iterates to a fixpoint, which a
    /// single merged push cannot reach through a chain of stacked parts); the
    /// other rounds each propose one merged displacement per part.
    fn propose(self: *State, which: Round) Allocator.Error!bool {
        var moves = try Moves.build(self.scratch, self.p.parts.len);
        switch (which) {
            .overlap => return sweepOverlap(self.p, self.shifted),
            .sealed => try planSealed(self.*, &moves),
            .port => try planPort(self.*, &moves),
            .stagger => |rank| try planStagger(self.*, rank, &moves),
            .spread => |rank| try planSpread(self.*, rank, &moves),
        }
        if (!moves.any) return false;
        moves.apply(self.p.parts, self.shifted);
        return true;
    }

    fn snapshot(self: State) Allocator.Error![][2]f64 {
        const out = try self.scratch.alloc([2]f64, self.p.parts.len);
        for (self.p.parts, out) |part, *o| o.* = .{ part.x, part.y };
        return out;
    }

    fn restore(self: *State, poses: []const [2]f64) void {
        for (self.p.parts, poses) |*part, o| {
            part.x = o[0];
            part.y = o[1];
        }
    }
};

/// Per-part accumulated push, world mm. Merged rather than applied one at a time
/// so two findings naming the same blocker do not move it twice.
const Moves = struct {
    dx: []f64,
    dy: []f64,
    any: bool = false,

    fn build(scratch: Allocator, n: usize) Allocator.Error!Moves {
        const dx = try scratch.alloc(f64, n);
        const dy = try scratch.alloc(f64, n);
        @memset(dx, 0);
        @memset(dy, 0);
        return .{ .dx = dx, .dy = dy };
    }

    fn push(self: *Moves, i: usize, x: f64, y: f64) void {
        self.dx[i] += x;
        self.dy[i] += y;
        self.any = true;
    }

    /// Apply the merged pushes, snapped to the placement grid and clamped so no
    /// part exceeds `max_shift_mm` in total displacement.
    fn apply(self: Moves, parts: []Part, shifted: []f64) void {
        for (parts, 0..) |*part, i| {
            const len = std.math.hypot(self.dx[i], self.dy[i]);
            if (len <= 0) continue;
            const room = max_shift_mm - shifted[i];
            if (room <= 0) continue;
            const use = @min(len, room);
            part.x = snap(part.x + self.dx[i] / len * use);
            part.y = snap(part.y + self.dy[i] / len * use);
            shifted[i] += use;
        }
    }
};

fn snap(v: f64) f64 {
    return @round(v / optimizer.grid_mm) * optimizer.grid_mm;
}

/// Index of the part named `ref`, or null. Linear because a rough block is tens
/// of parts and each caller runs once per finding.
fn partIndex(p: Placement, ref: []const u8) ?usize {
    for (p.parts, 0..) |part, i| {
        if (std.mem.eql(u8, part.ref_des, ref)) return i;
    }
    return null;
}

/// Courtyard centre of `p` in world mm.
fn centreOf(p: Part) [2]f64 {
    const r = optimizer.worldCourtyard(&p);
    return .{ r.minx + r.w / 2, r.miny + r.h / 2 };
}

// ── overlap relief ───────────────────────────────────────────────────────────

/// Separate overlapping courtyards to a fixpoint, each side of a pair taking
/// half the penetration on its shallower axis. A part standing on another seals
/// all eight exits of every pad beneath it, so on a placement the sealed gate
/// has flagged, this is usually the geometry the findings are really describing
/// — and no per-pad push can answer it, because the blocker is not beside the
/// pad but on top of it.
///
/// Iterated rather than merged into one push because separating a stack pushes
/// its members onto their neighbours; the sweep count bounds that cascade, and
/// `overlap_shift_mm` bounds how far any one part can travel through it.
fn sweepOverlap(p: Placement, shifted: []f64) bool {
    var moved = false;
    var sweep: usize = 0;
    while (sweep < overlap_sweeps) : (sweep += 1) {
        var any = false;
        for (0..p.parts.len) |i| {
            for (i + 1..p.parts.len) |j| {
                if (separatePair(p.parts, shifted, i, j)) any = true;
            }
        }
        if (!any) break;
        moved = true;
    }
    return moved;
}

/// Push one overlapping pair apart on its shallower axis. Each side takes half,
/// unless it is locked or out of displacement budget, in which case the other
/// takes what it can. The direction for two parts at the SAME point is decided
/// by index parity — the tie-break the placement legalizers already use — so it
/// is stable across runs rather than dependent on floating-point noise.
fn separatePair(parts: []Part, shifted: []f64, i: usize, j: usize) bool {
    const ra = optimizer.worldCourtyard(&parts[i]);
    const rb = optimizer.worldCourtyard(&parts[j]);
    if (parts[i].side != parts[j].side) return false;
    const dx = (rb.minx + rb.w / 2) - (ra.minx + ra.w / 2);
    const dy = (rb.miny + rb.h / 2) - (ra.miny + ra.h / 2);
    const px = (ra.w + rb.w) / 2 - @abs(dx);
    const py = (ra.h + rb.h) / 2 - @abs(dy);
    if (px <= 0 or py <= 0) return false;
    const on_x = px <= py;
    const step = @max(optimizer.grid_mm, snap((@min(px, py) + stagger_gap_mm) / 2));
    const s = tieSign(if (on_x) dx else dy, i + j);
    const a = nudge(&parts[i], shifted, i, on_x, -s * step);
    const b = nudge(&parts[j], shifted, j, on_x, s * step);
    return a or b;
}

/// Move one part `d` mm along an axis, honouring its lock and its remaining
/// displacement budget. True when it actually moved.
fn nudge(part: *Part, shifted: []f64, i: usize, on_x: bool, d: f64) bool {
    if (part.locked or shifted[i] + @abs(d) > overlap_shift_mm) return false;
    if (on_x) part.x = snap(part.x + d) else part.y = snap(part.y + d);
    shifted[i] += @abs(d);
    return true;
}

/// Separation sign for a penetration axis: the sign of the centre offset, and
/// for two exactly-coincident parts the index-parity tie-break.
fn tieSign(d: f64, parity: usize) f64 {
    if (d > 0) return 1;
    if (d < 0) return -1;
    return if (parity % 2 == 0) 1 else -1;
}

// ── pad-sealed relief ────────────────────────────────────────────────────────

/// Push each sealed pad's near-miss blocker directly away from the part it
/// seals, by the millimetres the finding says that escape is short. The gate has
/// already named "the neighbour actually worth moving", so nothing is searched —
/// only the direction and the distance, both measured.
fn planSealed(state: State, moves: *Moves) Allocator.Error!void {
    for (state.findings) |f| {
        if (!std.mem.eql(u8, f.rule, "pad-sealed")) continue;
        const other = f.detail.b orelse continue;
        const victim = partIndex(state.p, f.detail.a.ref) orelse continue;
        const blocker = partIndex(state.p, other.ref) orelse continue;
        if (victim == blocker or state.p.parts[blocker].locked) continue;
        const want = f.detail.need_mm - f.detail.have_mm + seal_margin_mm;
        if (want <= 0) continue;
        const dir = awayFrom(state.p.parts[victim], state.p.parts[blocker]) orelse continue;
        moves.push(blocker, dir[0] * want, dir[1] * want);
    }
}

// ── port-blocked relief ──────────────────────────────────────────────────────

/// Back a blocked port's movable walls off the pad they fence, far enough to
/// leave a LANE rather than merely clear the halo: the finding's own shortfall
/// plus `port_lane_mult` cross-sections of the net's class. The gate has already
/// chosen and ordered the walls (`refs[1..]`, cheapest to open first), so
/// nothing is searched here.
///
/// EVERY named wall moves, not just the tightest one, because a fenced pad is
/// normally fenced by a PAIR — the two passives whose courtyards meet across the
/// lane the port wanted — and opening one side of a mouth leaves the other side
/// exactly where it was. The round is measured and reverted whole, so widening
/// the move costs nothing when it does not work.
fn planPort(state: State, moves: *Moves) Allocator.Error!void {
    for (state.findings) |f| {
        if (!std.mem.eql(u8, f.rule, "port-blocked") or f.refs.len < 2) continue;
        const victim = partIndex(state.p, f.detail.a.ref) orelse continue;
        const lane = f.detail.width_mm + 2 * f.detail.clearance_mm;
        const want = @max(f.detail.need_mm - f.detail.have_mm, 0) + port_lane_mult * lane;
        for (f.refs[1..]) |ref| {
            const blocker = partIndex(state.p, ref) orelse continue;
            if (victim == blocker or state.p.parts[blocker].locked) continue;
            const dir = awayFrom(state.p.parts[victim], state.p.parts[blocker]) orelse continue;
            moves.push(blocker, dir[0] * want, dir[1] * want);
        }
    }
}

/// Unit vector from `a`'s courtyard centre to `b`'s — the direction that opens
/// the gap between them. Null when the two centres coincide, which no push can
/// disambiguate.
fn awayFrom(a: Part, b: Part) ?[2]f64 {
    const ca = centreOf(a);
    const cb = centreOf(b);
    const dx = cb[0] - ca[0];
    const dy = cb[1] - ca[1];
    const len = std.math.hypot(dx, dy);
    if (len < 1e-9) return null;
    return .{ dx / len, dy / len };
}

// ── escape-contended relief ──────────────────────────────────────────────────

/// One contended fan's geometry, reduced to the axes a move is made on.
const Corridor = struct {
    hub: usize,
    /// True when the escape leaves along y (north/south) — then the lane axis
    /// is x. The lint reports the side by name; this is that name reduced to
    /// the one bit a move needs.
    along_y: bool,
    /// +1 when the fan leaves in the increasing direction of the escape axis.
    outward: f64,
    /// Escape-axis coordinate of the cut the lint measured.
    cut: f64,
    /// Half-width of the lane-axis window, centred on the hub.
    half_span: f64,
};

fn corridorOf(p: Placement, f: Finding) ?Corridor {
    const esc = f.escape orelse return null;
    if (f.refs.len == 0) return null;
    const hub = partIndex(p, f.refs[0]) orelse return null;
    const along_y = std.mem.eql(u8, esc.side, "north") or std.mem.eql(u8, esc.side, "south");
    const out = std.mem.eql(u8, esc.side, "south") or std.mem.eql(u8, esc.side, "east");
    return .{
        .hub = hub,
        .along_y = along_y,
        .outward = if (out) 1 else -1,
        .cut = esc.cut.at_mm,
        .half_span = @max(esc.cut.span_mm, 0) / 2,
    };
}

/// A part blocking the cut, keyed for a deterministic order along the corridor.
/// `depth` is its extent on the escape axis, `width` its extent along the lane
/// axis — the two the stagger and the spread respectively re-space by.
const Blocker = struct { part: usize, along: f64, ref: []const u8, depth: f64, width: f64 };

fn alongThenRef(_: void, a: Blocker, b: Blocker) bool {
    if (a.along != b.along) return a.along < b.along;
    return std.mem.order(u8, a.ref, b.ref) == .lt;
}

/// Stagger the `rank`-worst contended fan: the parts whose courtyards cross its
/// cut, ordered along the corridor, with every other one pushed a rank outward.
/// A cross-section blocked by half as many courtyards offers roughly twice the
/// free bands, and every part that moves is still docked on the same side of the
/// same hub.
fn planStagger(state: State, rank: usize, moves: *Moves) Allocator.Error!void {
    const f = nthEscape(state.findings, rank) orelse return;
    const cor = corridorOf(state.p, f) orelse return;
    var list: std.ArrayList(Blocker) = .empty;
    try collectBlockers(state, cor, &list);
    if (list.items.len < 2) return;
    std.mem.sort(Blocker, list.items, {}, alongThenRef);
    var depth: f64 = 0;
    for (list.items) |b| depth = @max(depth, b.depth);
    const shift = (depth + stagger_gap_mm) * cor.outward;
    var i: usize = 1;
    while (i < list.items.len) : (i += 2) {
        const b = list.items[i];
        moves.push(b.part, if (cor.along_y) 0 else shift, if (cor.along_y) shift else 0);
    }
}

/// The other relief shape for the `rank`-worst fan: keep the corridor one rank
/// deep, but re-space its parts along it so every neighbouring pair leaves
/// `lane_open_mm` of free lane between courtyards. A stagger gives the fan two
/// wide bands; this gives it many narrow ones, spread along the whole side —
/// which is what a net whose ideal crossing point is mid-corridor needs, since
/// the assignment refuses a lane too far from that ideal however many lanes
/// exist elsewhere.
fn planSpread(state: State, rank: usize, moves: *Moves) Allocator.Error!void {
    const f = nthEscape(state.findings, rank) orelse return;
    const cor = corridorOf(state.p, f) orelse return;
    var list: std.ArrayList(Blocker) = .empty;
    try collectBlockers(state, cor, &list);
    if (list.items.len < 2) return;
    std.mem.sort(Blocker, list.items, {}, alongThenRef);
    var pitch: f64 = 0;
    var centre: f64 = 0;
    for (list.items) |b| {
        pitch = @max(pitch, b.width + lane_open_mm);
        centre += b.along;
    }
    centre /= @floatFromInt(list.items.len);
    const first = centre - pitch * @as(f64, @floatFromInt(list.items.len - 1)) / 2;
    for (list.items, 0..) |b, k| {
        const want = first + pitch * @as(f64, @floatFromInt(k));
        const d = want - b.along;
        moves.push(b.part, if (cor.along_y) d else 0, if (cor.along_y) 0 else d);
    }
}

/// The `rank`-th `escape-contended` finding in the lint's own worst-first order.
fn nthEscape(findings: []const Finding, rank: usize) ?Finding {
    var seen: usize = 0;
    for (findings) |f| {
        if (f.escape == null) continue;
        if (seen == rank) return f;
        seen += 1;
    }
    return null;
}

/// The parts whose courtyard crosses `cor`'s cut inside its lane window — the
/// same obstacle set the lint's lane scan counted, minus the hub itself and
/// anything the editor locked.
fn collectBlockers(
    state: State,
    cor: Corridor,
    out: *std.ArrayList(Blocker),
) Allocator.Error!void {
    const hub = state.p.parts[cor.hub];
    const hub_rect = optimizer.worldCourtyard(&hub);
    const centre = if (cor.along_y) hub_rect.minx + hub_rect.w / 2 else hub_rect.miny + hub_rect.h / 2;
    for (state.p.parts, 0..) |part, i| {
        if (i == cor.hub or part.locked or part.side != hub.side) continue;
        const rect = optimizer.worldCourtyard(&part);
        const esc_lo = if (cor.along_y) rect.miny else rect.minx;
        const esc_hi = esc_lo + (if (cor.along_y) rect.h else rect.w);
        if (cor.cut < esc_lo - cut_halo_mm or cor.cut > esc_hi + cut_halo_mm) continue;
        const lane_lo = if (cor.along_y) rect.minx else rect.miny;
        const lane_hi = lane_lo + (if (cor.along_y) rect.w else rect.h);
        if (lane_hi < centre - cor.half_span or lane_lo > centre + cor.half_span) continue;
        try out.append(state.scratch, .{
            .part = i,
            .along = (lane_lo + lane_hi) / 2,
            .ref = part.ref_des,
            .depth = esc_hi - esc_lo,
            .width = lane_hi - lane_lo,
        });
    }
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

fn tPad(n: []const u8, x: f64, y: f64, w: f64, h: f64) geometry.Pad {
    return .{ .number = n, .x = x, .y = y, .w = w, .h = h };
}

/// Zero values so the stacked fixture's arrays need no `undefined` placeholder
/// before `build` fills them.
const blank_part: Part = .{ .ref_des = "", .kind = .passive, .hw = 0, .hh = 0, .pads = &.{}, .fallback = false };
const blank_net: flat_netlist.FlatNet = .{ .name = "", .pins = &.{} };

fn tPart(ref: []const u8, at: [2]f64, half: [2]f64, pads: []const geometry.Pad) Part {
    return .{
        .ref_des = ref,
        .kind = .hub,
        .hw = half[0],
        .hh = half[1],
        .pads = pads,
        .fallback = false,
        .x = at[0],
        .y = at[1],
    };
}

fn tPlacement(parts: []Part, nets: []const flat_netlist.FlatNet) Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .rules = .{ .design = .{ .track_width = 0.127, .clearance = 0.127 } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -20,
        .miny = -20,
        .maxx = 20,
        .maxy = 20,
        .generated = true,
    };
}

/// Two parts on the SAME spot: `V`'s lone pad sits inside the ring of `W`'s four
/// pads, so every one of its eight exits is inside foreign clearance and the
/// sealed gate fires. This is the `w55rp20` shape — the rough seed's own output
/// stacks ten pairs like it — reduced to two parts.
const StackedPair = struct {
    v_pad: [1]geometry.Pad = .{tPad("1", 0, 0, 0.3, 0.3)},
    w_pads: [4]geometry.Pad = .{
        tPad("1", -0.35, 0, 0.3, 1.0),
        tPad("2", 0.35, 0, 0.3, 1.0),
        tPad("3", 0, -0.375, 1.0, 0.25),
        tPad("4", 0, 0.375, 1.0, 0.25),
    },
    parts: [2]Part = @splat(blank_part),
    pins: [2]flat_netlist.FlatPin = .{
        .{ .ref_des = "V", .pin = "1" },
        .{ .ref_des = "FAR", .pin = "1" },
    },
    nets: [1]flat_netlist.FlatNet = .{blank_net},

    fn build(self: *StackedPair) Placement {
        self.parts = .{
            tPart("V", .{ 0, 0 }, .{ 1.5, 1.5 }, &self.v_pad),
            tPart("W", .{ 0, 0 }, .{ 1.5, 1.5 }, &self.w_pads),
        };
        self.nets = .{.{ .name = "SIG", .pins = &self.pins }};
        return tPlacement(&self.parts, &self.nets);
    }
};

// spec: placement/rough_routability - two parts stacked on one spot are separated
test "the repair pulls two stacked parts off each other" {
    var fx: StackedPair = .{};
    const p = fx.build();
    var courtyards: [2]BoardRect = undefined;
    try testing.expectEqual(@as(usize, 1), stackedPairs(p, &courtyards));
    const r = try repair(testing.allocator, p, .{});
    try testing.expect(r.ran);
    try testing.expectEqual(@as(usize, 1), r.stacked_before);
    try testing.expectEqual(@as(usize, 0), r.stacked_after);
    try testing.expectEqual(@as(usize, 0), stackedPairs(p, &courtyards));
    try testing.expect(r.before.sealed > 0);
}

// spec: placement/rough_routability - a part is never displaced past the repair's own budget
test "no part travels past the overlap budget" {
    var fx: StackedPair = .{};
    const p = fx.build();
    const r = try repair(testing.allocator, p, .{});
    try testing.expect(r.moved > 0);
    for (p.parts) |part| {
        try testing.expect(std.math.hypot(part.x, part.y) <= overlap_shift_mm);
    }
}

// spec: placement/rough_routability - repairing the same placement twice gives the same poses
test "the repair is deterministic on identical input" {
    var a: StackedPair = .{};
    var b: StackedPair = .{};
    const pa = a.build();
    const pb = b.build();
    _ = try repair(testing.allocator, pa, .{});
    _ = try repair(testing.allocator, pb, .{});
    for (pa.parts, pb.parts) |x, y| {
        try testing.expectEqual(x.x, y.x);
        try testing.expectEqual(x.y, y.y);
    }
}

// spec: placement/rough_routability - a placement whose gates find nothing is left untouched
test "a clean placement keeps every pose" {
    var pads = [_]geometry.Pad{tPad("1", 0, 0, 0.3, 0.3)};
    var far = [_]geometry.Pad{tPad("1", 0, 0, 0.3, 0.3)};
    var parts = [_]Part{
        tPart("V", .{ 0, 0 }, .{ 1.5, 1.5 }, &pads),
        tPart("FAR", .{ 12, 0 }, .{ 1.5, 1.5 }, &far),
    };
    var pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "V", .pin = "1" },
        .{ .ref_des = "FAR", .pin = "1" },
    };
    var nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const p = tPlacement(&parts, &nets);
    const r = try repair(testing.allocator, p, .{});
    try testing.expect(r.ran);
    try testing.expectEqual(@as(usize, 0), r.before.cost());
    try testing.expectEqual(@as(usize, 0), r.moved);
    try testing.expectEqual(@as(f64, 0), parts[0].x);
    try testing.expectEqual(@as(f64, 12), parts[1].x);
}

/// A port pad at the bottom of a slot cut into its OWN package — three walls are
/// `U1`'s neighbouring pads, so no move answers them — with the mouth crossed by
/// two movable bars `WL`/`WR` that meet in the middle. The port cannot leave and
/// the only fix is to back BOTH bars off, which is the shape a rough seed
/// actually produces: a port pad on a package edge with the ring's passives laid
/// flush across it.
const FencedPortMouth = struct {
    hub_pads: [4]geometry.Pad = .{
        tPad("1", 0, 0, 0.3, 0.3),
        tPad("2", -0.55, 0, 0.3, 1.4),
        tPad("3", 0.55, 0, 0.3, 1.4),
        tPad("4", 0, -0.55, 1.4, 0.3),
    },
    mouth_l: [1]geometry.Pad = .{tPad("1", 0, 0, 0.7, 0.3)},
    mouth_r: [1]geometry.Pad = .{tPad("1", 0, 0, 0.7, 0.3)},
    parts: [3]Part = @splat(blank_part),
    pins: [1]flat_netlist.FlatPin = .{.{ .ref_des = "U1", .pin = "1" }},
    wall_pins: [5]flat_netlist.FlatPin = .{
        .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "U1", .pin = "4" }, .{ .ref_des = "WL", .pin = "1" },
        .{ .ref_des = "WR", .pin = "1" },
    },
    nets: [2]flat_netlist.FlatNet = .{ blank_net, blank_net },
    /// The port net's own index, for the mask the gate is turned on with.
    const ports = [_]bool{ true, false };

    fn build(self: *FencedPortMouth) Placement {
        self.parts = .{
            tPart("U1", .{ 0, 0 }, .{ 0.7, 0.7 }, &self.hub_pads),
            tPart("WL", .{ -0.35, 0.55 }, .{ 0.35, 0.15 }, &self.mouth_l),
            tPart("WR", .{ 0.35, 0.55 }, .{ 0.35, 0.15 }, &self.mouth_r),
        };
        self.nets = .{
            .{ .name = "SPI_SCK", .pins = &self.pins },
            .{ .name = "V_1V8", .pins = &self.wall_pins },
        };
        return tPlacement(&self.parts, &self.nets);
    }
};

// spec: placement/rough_routability - a port net fenced out of its own block is repaired by backing its walls off, and the moved parts still do not overlap
test "the repair opens a blocked port's escape" {
    var fx: FencedPortMouth = .{};
    const p = fx.build();
    const r = try repair(testing.allocator, p, .{ .port_nets = &FencedPortMouth.ports });
    try testing.expect(r.ran);
    try testing.expectEqual(@as(usize, 1), r.before.port_blocked);
    try testing.expectEqual(@as(usize, 0), r.after.port_blocked);
    try testing.expect(r.moved >= 2);
    // The relief must not have bought the escape with a courtyard collision.
    var courtyards: [3]BoardRect = undefined;
    try testing.expectEqual(@as(usize, 0), stackedPairs(p, &courtyards));
    // The hub itself is never the thing that moves — it holds the port pad.
    try testing.expectEqual(@as(f64, 0), p.parts[0].x);
    try testing.expectEqual(@as(f64, 0), p.parts[0].y);
}

// spec: placement/rough_routability - the port round is skipped entirely when the caller names no port nets
test "a caller that names no ports gets no port repair" {
    var fx: FencedPortMouth = .{};
    const p = fx.build();
    const r = try repair(testing.allocator, p, .{});
    try testing.expectEqual(@as(usize, 0), r.before.port_blocked);
    // The same geometry, same poses: without the mask nothing here is a port.
    try testing.expectEqual(@as(f64, -0.35), p.parts[1].x);
    try testing.expectEqual(@as(f64, 0.35), p.parts[2].x);
}

// spec: placement/rough_routability - repairing a blocked port twice gives the same poses
test "the port repair is deterministic on identical input" {
    var a: FencedPortMouth = .{};
    var b: FencedPortMouth = .{};
    const pa = a.build();
    const pb = b.build();
    _ = try repair(testing.allocator, pa, .{ .port_nets = &FencedPortMouth.ports });
    _ = try repair(testing.allocator, pb, .{ .port_nets = &FencedPortMouth.ports });
    for (pa.parts, pb.parts) |x, y| {
        try testing.expectEqual(x.x, y.x);
        try testing.expectEqual(x.y, y.y);
    }
}

// spec: placement/rough_routability - the tally counts each gate the preflight reported
test "the tally counts sealed, tight corridors and contended fans" {
    const esc: routability_lint.Escape = .{
        .side = "west",
        .nets = 6,
        .lanes = 4,
        .seated = 2,
        .bands = 2,
        .cut = .{ .at_mm = -4, .span_mm = 14, .pitch_mm = 0.254 },
    };
    const findings = [_]Finding{
        .{ .rule = "pad-sealed", .severity = .warn, .refs = &.{}, .msg = "", .detail = .{ .a = .{ .ref = "R1" } } },
        .{ .rule = "pad-corridor-tight", .severity = .warn, .refs = &.{}, .msg = "", .detail = .{ .a = .{ .ref = "C1" } } },
        .{ .rule = "escape-contended", .severity = .warn, .refs = &.{}, .msg = "", .detail = .{ .a = .{ .ref = "U1" } }, .escape = esc },
        .{ .rule = "port-blocked", .severity = .warn, .refs = &.{}, .msg = "", .detail = .{ .a = .{ .ref = "U1" } } },
    };
    const s = tally(&findings);
    try testing.expectEqual(@as(usize, 1), s.sealed);
    try testing.expectEqual(@as(usize, 1), s.corridor);
    try testing.expectEqual(@as(usize, 1), s.contended);
    try testing.expectEqual(@as(usize, 4), s.deficit);
    try testing.expectEqual(@as(usize, 1), s.port_blocked);
    try testing.expectEqual(@as(usize, 6), s.cost());
}

// spec: placement/rough_routability - an escape relief may spend objective only in proportion to the nets it seats
test "a soft round's objective budget scales with the nets it seats" {
    // One seated net buys 3 %, two buy 6 % — `straps-synth-lmx2595`'s measured
    // round wanted 8.9 % for two seats and is refused; `bcuda-lt3045-ldo`'s
    // wanted 5.6 % for two and is kept.
    try testing.expect(withinObjectiveBudget(100, 102.9, 1));
    try testing.expect(!withinObjectiveBudget(100, 103.1, 1));
    try testing.expect(withinObjectiveBudget(100, 105.6, 2));
    try testing.expect(!withinObjectiveBudget(100, 108.9, 2));
    // A round that lowers the objective is free at any seat count.
    try testing.expect(withinObjectiveBudget(100, 90, 1));
}

// spec: placement/rough_routability - an unpriced escape relief is not refused for its objective
test "a caller that priced nothing gets no objective opinion" {
    try testing.expect(withinObjectiveBudget(0, 0, 1));
    try testing.expect(withinObjectiveBudget(0, 1e9, 4));
}
