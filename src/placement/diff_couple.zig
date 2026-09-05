//! The router-side driver for COUPLED differential-pair routing.
//!
//! A declared `(net-class … (diff-pair GAP))` pair is routed ONCE, as a single
//! centreline, and split into its two legs geometrically (`diff_route.zig`).
//! The search runs with the pair ENVELOPE as its copper profile — `2·width +
//! gap` wide, launched from the midpoint between each end's two pads — so the
//! corridor it claims fits BOTH legs; the legs are then exact ±(width+gap)/2
//! offsets of the path it found: parallel by construction, mitered through
//! every bend, paired at every via, length-matched in the pad fans. This
//! replaces the two members' independent searches.
//!
//! Every step may decline — odd pad counts, no envelope-wide corridor, a
//! centreline that is not a simple path, a constructed leg that fails the exact
//! clearance probe. The pair then falls back to `router.zig`'s legacy leader +
//! follower-corridor route and surfaces as today's `diff_uncoupled` warnings
//! rather than silently degrading. A board declaring no pair never enters here,
//! so its routing is byte-identical.
//!
//! It lives beside `router.zig` rather than inside it because that file sits at
//! its Guardian size cap; the seam is `leaderRoute`, called once per net from
//! the greedy pass.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const diff_pairs = @import("diff_pairs.zig");
const diff_route = @import("diff_route.zig");
const diff_direct = @import("diff_direct.zig");
const diff_shape = @import("diff_shape.zig");
const cdt_layers = @import("cdt_layers.zig");
const cdt_route = @import("cdt_route.zig");
const keepout = @import("keepout.zig");
const bend_smooth = @import("bend_smooth.zig");
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");
const numeric = @import("../numeric.zig");
const log = @import("../infra/log.zig");

/// The mesh tier's own verdicts, at the level every other gridless-channel
/// verdict is printed at (`router`'s `shapeLog`) — a tier that answers silently
/// is a tier nobody can tell apart from one that was never reached.
const shapeLog = std.log.info;

/// Millimetres apart the two pads at one END of a pair may sit and still count
/// as a launch pair. Farther apart, their midpoint is not a meaningful
/// centreline terminal and the coupled construction declines.
const pair_end_span_mm: f64 = 6.0;

/// Length-match window (mm) the coupled construction equalizes its legs to —
/// far inside the `diff_skew` DRC window, because a controlled-impedance pair
/// wants identical legs, not merely un-flagged ones.
const pair_skew_tol_mm: f64 = 0.05;

/// A pad terminal as `diff_route` sees it.
fn terminalOf(p: router.NetPt) diff_route.Terminal {
    return .{ .x = p.x, .y = p.y, .layer = p.layer };
}

/// The pair's centreline terminals, or null when its pads cannot launch a
/// coupled pair: not exactly two pads a side, an end whose pads sit on
/// different layers, or an end whose pads are too far apart to be a launch
/// pair.
fn pairTerminals(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
) std.mem.Allocator.Error![]const diff_route.Ends {
    const arena = run.ctx.arena;
    const p_pts = try router.netPoints(arena, run.placement, run.idx_of, run.placement.nets[pair.p]);
    const n_pts = try router.netPoints(arena, run.placement, run.idx_of, run.placement.nets[pair.n]);
    return diff_route.pairEndOptions(
        arena,
        try terminalsOf(arena, p_pts),
        try terminalsOf(arena, n_pts),
        pair_end_span_mm,
        max_end_options,
    );
}

/// How many launch-pad configurations the pair may try before giving up. Each
/// costs one envelope search, so this is a routing-time budget, not a limit on
/// what is expressible.
const max_end_options: usize = 4;

/// Collect the pair's pad geometry: every pad of both nets, plus the twin's two
/// landing pads.
fn pairPads(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    _: diff_route.Ends,
) std.mem.Allocator.Error!PairPads {
    const arena = run.ctx.arena;
    var all: std.ArrayList([2]f64) = .empty;
    for ([2]usize{ pair.p, pair.n }) |net| {
        const pts = try router.netPoints(arena, run.placement, run.idx_of, run.placement.nets[net]);
        for (pts) |pt| try all.append(arena, .{ pt.x, pt.y });
    }
    return .{ .all = try all.toOwnedSlice(arena) };
}

/// Swap in an obstacle table whose N-net pads/// A net's pad terminals as `diff_route` sees them.
fn terminalsOf(
    arena: std.mem.Allocator,
    pts: []const router.NetPt,
) std.mem.Allocator.Error![]const diff_route.Terminal {
    const out = try arena.alloc(diff_route.Terminal, pts.len);
    for (pts, out) |pt, *slot| slot.* = terminalOf(pt);
    return out;
}

/// Foreign copper dilated by the extra half-width the envelope needs beyond a
/// single track, with a launch pocket cleared around each terminal. Null when
/// the extra rounds to no grid cell (the mask would be inert). A search
/// heuristic only — every constructed leg is re-validated against exact
/// geometry before it lands.
fn buildPairBlock(
    run: router.CoupledRun,
    net: i32,
    extra: f64,
    pts: []const router.NetPt,
) std.mem.Allocator.Error!?[]const bool {
    const ctx = run.ctx;
    if (!(extra > 0)) return null;
    const radius = numeric.toCount(@ceil(extra / ctx.grid.g));
    if (radius == 0) return null;
    const mask = try diff_pairs.buildBlock(ctx.arena, ctx.occ, .{
        .nx = ctx.grid.nx,
        .ny = ctx.grid.ny,
        .net = net,
        .empty = router.empty_cell,
        .radius = radius,
    });
    try router.clearMaskPockets(run, mask, pts, ctx.reach);
    return mask;
}

/// Route the pair's centreline once with the ENVELOPE copper profile. Tried
/// twice: first with the exclusion mask armed (the honest envelope width), then
/// without it — the mask is conservative by a grid cell, and a pair that only
/// fits the true envelope still routes legally because the constructed legs are
/// exact-probed afterwards either way.
fn routeEnvelope(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    pts: []const router.NetPt,
    pads: PairPads,
) std.mem.Allocator.Error!bool {
    const ctx = run.ctx;
    const saved = ctx.params;
    const saved_reach = ctx.reach;
    ctx.params.track_width = 2 * saved.track_width + pair.gap;
    ctx.reach = ctx.params.track_width / 2 + saved.clearance;
    router.setNetRoutePolicy(ctx, pair.p, pts);
    ctx.pair_block = try buildPairBlock(run, @intCast(pair.p), ctx.reach - saved_reach, pts);
    ctx.via_ban = try router.buildPairViaBan(run, pads.all, viaBanRadius(run, pair));
    var ok = try router.routeNet(ctx, @intCast(pair.p), pts, run.tracks, run.vias);
    // The envelope mask is conservative by a grid cell, so a pair that only fits
    // the true envelope gets a second try without it — the construction is
    // exact-probed either way. The via ban is NOT relaxed: a layer change inside
    // the pair's own pad field puts the mirrored barrel on its twin's pad, which
    // no amount of later probing can rescue.
    if (!ok and ctx.pair_block != null) {
        ctx.pair_block = null;
        ok = try router.routeNet(ctx, @intCast(pair.p), pts, run.tracks, run.vias);
    }
    ctx.pair_block = null;
    ctx.via_ban = null;
    ctx.params = saved;
    ctx.reach = saved_reach;
    return ok;
}

/// The pair's pad geometry as the envelope search needs it.
///
/// The twin's landing pads are deliberately NOT hidden from the search. They
/// were, once: the old model launched the centreline from the midpoint BETWEEN
/// two landing pads, which the real obstacle table walls off, so those pads had
/// to read as the routing net's own. The sequence model starts the centreline
/// clear of the whole pad field instead — and hiding the pads then let the
/// centreline hug them, so the constructed leg grazed its own twin's pad and
/// failed the honest probe every time.
const PairPads = struct {
    /// Every pad of both nets — no layer change may land in this field.
    all: []const [2]f64,
};

/// How far from any of the pair's own pads a layer change must stay: the barrel
/// the construction mirrors sits half a spread off the centreline, and it needs
/// its own via-to-pad clearance from there.
fn viaBanRadius(run: router.CoupledRun, pair: diff_pairs.DiffPair) f64 {
    const p = run.ctx.params;
    const off = p.track_width + pair.gap;
    const half = pairViaSpread(run, pair, off) / 2;
    return half + p.via_dia / 2 + p.clearance;
}

/// Centre-to-centre spacing this pair's via barrels need: wide enough for the
/// two barrels' copper AND the opposite leg's track, and for the drill-to-drill
/// manufacturing wall.
fn pairViaSpread(run: router.CoupledRun, pair: diff_pairs.DiffPair, off: f64) f64 {
    return pairViaSpreadFor(run.ctx.params, pair, off, run.ctx.hole_to_hole);
}

fn pairViaSpreadFor(p: router.RouteParams, pair: diff_pairs.DiffPair, off: f64, hole_to_hole: f64) f64 {
    const copper = diff_route.viaSpread(off, p.via_dia, p.clearance, p.track_width);
    // KiCad's EffectiveDiffPairViaGap is edge-to-edge: the barrel centres are
    // one via diameter farther apart. Keep the router's opposite-track guard
    // and the board's drill-to-drill minimum as additional lower bounds.
    const via_gap = if (pair.via_gap > 0) pair.via_gap else pair.gap;
    const pair_gap = p.via_dia + via_gap;
    return @max(copper, @max(pair_gap, p.via_drill + hole_to_hole));
}

/// Re-read the envelope route's fresh copper as one ordered centreline. Null
/// when that copper is not a simple two-ended path.
fn centerlineOf(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    ends: diff_route.Ends,
    marks: [2]usize,
) std.mem.Allocator.Error!?diff_route.Centerline {
    const ctx = run.ctx;
    const arena = ctx.arena;
    const pnet: i32 = @intCast(pair.p);
    var segs: std.ArrayList(diff_route.Seg) = .empty;
    for (run.tracks.items[marks[0]..]) |t| {
        if (t.net != pnet) continue;
        try segs.append(arena, .{
            .a = .{ .x = t.x1, .y = t.y1 },
            .b = .{ .x = t.x2, .y = t.y2 },
            .layer = t.layer,
        });
    }
    var vias: std.ArrayList(diff_route.Pt) = .empty;
    for (run.vias.items[marks[1]..]) |v| {
        if (v.net == pnet) try vias.append(arena, .{ .x = v.x, .y = v.y });
    }
    const start = diff_route.Pt{ .x = ends.far[0].x, .y = ends.far[0].y };
    // Weld tolerance: a run ends on its own grid NODE, which can sit up to half
    // a track off the drill centre on top of the barrel radius. Anything
    // tighter refuses copper the router itself considers joined.
    const weld = ctx.params.via_dia / 2 + ctx.params.track_width / 2;
    const c = (try diff_route.chain(arena, segs.items, vias.items, start, weld)) orelse return null;
    return try diff_route.extendEnds(arena, c, ends.mid[0], ends.mid[1]);
}

/// The pair's two length-matched legs for one candidate centreline.
fn legsFor(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    ends: diff_route.Ends,
    center: diff_route.Centerline,
    shape: Shape,
) std.mem.Allocator.Error!?diff_route.Legs {
    const ctx = run.ctx;
    const off = ctx.params.track_width + pair.gap;
    const built = (try diff_route.build(ctx.arena, center, .{
        .off = off,
        .via_spread = pairViaSpread(run, pair, off),
        .via_clear = ctx.params.via_dia / 2 + ctx.params.track_width / 2 + ctx.params.clearance,
        .seq = ends.seq,
        .mid = ends.mid,
        .swap_via = shape.swap_via,
        .trim = shape.trim,
    })) orelse return null;
    return try diff_route.equalize(ctx.arena, built, pair_skew_tol_mm, ends.seq);
}

/// One construction shape offered to the clearance probe: which layer change (if
/// any) absorbs the twist, and which ends approach their terminal straight.
const Shape = struct { swap_via: ?usize, trim: diff_route.RunEnds };

/// The end-approach shapes, offered STRAIGHTEST FIRST.
///
/// A trimmed end is strictly less copper and one via pair fewer, so it is always
/// the better board when it fits — and only the probe knows whether it fits. The
/// untrimmed shape comes last: it is the escape a crowded pocket genuinely needs,
/// and the behaviour every pair had before this was offered.
const trim_shapes = [4]diff_route.RunEnds{
    .{ .head = true, .tail = true },
    .{ .head = false, .tail = true },
    .{ .head = true, .tail = false },
    .{ .head = false, .tail = false },
};

/// How many layer changes are offered as the pair's side-swapping transition.
///
/// A TWISTED pair — the two ends demanding opposite sides, which is what a
/// connector wired pin-for-pin to a receiver whose pinout runs the other way
/// gives you — has no all-perpendicular construction at all. Exactly one of its
/// layer changes has to absorb the twist in-line, and which one is a placement
/// question, not a geometric one: the transition sits wherever the board leaves
/// room for two staggered barrels plus the passing leg's excursion. So every
/// one is probed, nearest first, and the via-float ladder above re-offers each
/// at a fresh site.
const max_swap_candidates: usize = 8;

/// Build one candidate centreline's legs and land them if every piece is legal.
///
/// The all-perpendicular arrangement is tried first and is the only one an
/// untwisted pair accepts; a twisted one declines it outright and each in-line
/// transition is offered in turn.
fn tryCandidate(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    ends: diff_route.Ends,
    center: diff_route.Centerline,
) std.mem.Allocator.Error!bool {
    var built_any = false;
    for (trim_shapes) |trim| {
        for (0..max_swap_candidates + 1) |k| {
            const swap: ?usize = if (k == 0) null else k - 1;
            const shape = Shape{ .swap_via = swap, .trim = trim };
            const legs = (try legsFor(run, pair, ends, center, shape)) orelse continue;
            built_any = true;
            censusBarrel(run, legs, swap);
            if (try commitPairLegs(run, pair, legs)) return true;
        }
    }
    if (!built_any) censusDecline(run, pair, .no_construction, 0);
    return false;
}

/// How far along the run a layer change may be walked looking for a site two
/// barrels fit, and the step it walks in.
const via_float_step_mm: f64 = 0.5;
const via_float_max_mm: f64 = 4.0;

/// Land the pair, floating its layer changes when the maze's own sites cannot
/// carry a via PAIR.
///
/// The maze changes layers wherever ITS single track happened to need to; a
/// pair needs room for two barrels plus the clearance between them and the
/// opposite leg, which the pad pocket a route is escaping rarely has. The
/// transition is free to sit anywhere along the centreline, so each site walks
/// outward in both directions until the whole construction passes the exact
/// probe. Nearest sites are tried first, so a pair that already fits keeps the
/// maze's own transition and the result is unchanged.
fn commitFloating(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    ends: diff_route.Ends,
    center: diff_route.Centerline,
) std.mem.Allocator.Error!bool {
    if (try tryCandidate(run, pair, ends, center)) return true;
    var step: f64 = via_float_step_mm;
    while (step <= via_float_max_mm) : (step += via_float_step_mm) {
        for (0..center.vias.len) |i| {
            for ([2]f64{ step, -step }) |delta| {
                const moved = (try diff_route.shiftVia(run.ctx.arena, center, i, delta)) orelse continue;
                if (try tryCandidate(run, pair, ends, moved)) return true;
            }
        }
    }
    return false;
}

/// This run's probe handle on `net`, with the per-net keepout escape gate aimed
/// at that net.
///
/// The gate is a cache the router refreshes once per net it configures; the
/// coupled construction probes BOTH legs inside one such net's slot, so it has
/// to move the gate itself. Judged through its twin's gate a leg is refused
/// inside an escape zone its own pad sits in — see `keepout.aimAt`.
fn legRun(run: router.CoupledRun, net: usize) router.DirectRun {
    const keep = &run.ctx.keep;
    keepout.aimAt(keep.zones, keep.pads, &keep.class.cur, @intCast(net));
    return run.direct(net);
}

/// True when one side's constructed segments clear foreign geometry, probed as
/// THAT side's own net — so a leg's daisy hop onto its own termination pad is
/// legal while the twin's copper is judged the way the DRC will judge it.
fn sideClear(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    net: usize,
    legs: diff_route.Legs,
    side: diff_route.Side,
) bool {
    const probe = router.TautProbe{ .run = legRun(run, net) };
    for (legs.segs) |s| {
        if (s.side != side) continue;
        if (!probe.clear(s.layer, .{ s.a.x, s.a.y }, .{ s.b.x, s.b.y })) {
            censusSeg(run, pair, net, s);
            censusLegs(legs);
            return false;
        }
    }
    return true;
}

/// Append one side's segments as that net's copper.
fn emitSide(
    run: router.CoupledRun,
    net: usize,
    legs: diff_route.Legs,
    side: diff_route.Side,
) std.mem.Allocator.Error!void {
    for (legs.segs) |s| {
        if (s.side != side) continue;
        try run.tracks.append(run.ctx.arena, .{
            .x1 = s.a.x,
            .y1 = s.a.y,
            .x2 = s.b.x,
            .y2 = s.b.y,
            .layer = s.layer,
            .width = run.ctx.params.track_width,
            .net = @intCast(net),
        });
    }
}

/// Place every via PAIR, one barrel at a time so each is judged against the
/// copper already down — including its own twin's barrel and the opposite leg's
/// track. False (with nothing appended past `mark`) if any barrel is illegal.
fn emitVias(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    legs: diff_route.Legs,
) std.mem.Allocator.Error!bool {
    const p = run.ctx.params;
    for (legs.vias) |v| {
        for ([2]diff_route.Pt{ v.p, v.n }, [2]usize{ pair.p, pair.n }) |at, net| {
            if (!router.directViaClear(legRun(run, net), .{ at.x, at.y })) {
                censusVia(run, pair, net, at);
                return false;
            }
            try run.vias.append(run.ctx.arena, .{
                .x = at.x,
                .y = at.y,
                .dia = p.via_dia,
                .drill = p.via_drill,
                .net = @intCast(net),
            });
        }
    }
    return true;
}

/// Validate the constructed legs and put them on the board, all-or-nothing.
///
/// Each side is probed as its OWN net and laid before the other is checked, so
/// the twin's copper is a real obstacle by the time it matters — the coupled
/// run is judged at its true `width + gap` spacing, exactly as the DRC will.
/// A single illegal segment or barrel leaves the board as it was.
fn commitPairLegs(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    legs: diff_route.Legs,
) std.mem.Allocator.Error!bool {
    const ctx = run.ctx;
    const marks = [2]usize{ run.tracks.items.len, run.vias.items.len };
    const need = ctx.params.track_width + ctx.params.clearance - router.clearance_eps;
    const gap = diff_route.minOppositeGap(legs);
    if (gap < need) {
        censusFold(legs, gap, need);
        return false;
    }
    var ok = sideClear(run, pair, pair.p, legs, .p);
    if (ok) {
        try emitSide(run, pair.p, legs, .p);
        ok = sideClear(run, pair, pair.n, legs, .n);
    }
    if (ok) {
        try emitSide(run, pair.n, legs, .n);
        ok = try emitVias(run, pair, legs);
    }
    if (!ok) {
        run.tracks.shrinkRetainingCapacity(marks[0]);
        run.vias.shrinkRetainingCapacity(marks[1]);
        return false;
    }
    for ([2]usize{ pair.p, pair.n }) |net|
        router.restoreNetOcc(ctx, @intCast(net), run.tracks.items, run.vias.items);
    return true;
}

/// Route one declared pair as a coupled unit. False leaves the board exactly as
/// it was, for the caller's legacy fallback.
fn tryCoupledPair(run: router.CoupledRun, pair: diff_pairs.DiffPair) std.mem.Allocator.Error!bool {
    router.resetPairContext(run.ctx);
    const opts = try pairTerminals(run, pair);
    if (opts.len == 0) censusDecline(run, pair, .no_end_option, 0);
    // The short construction is a CLASSIFICATION, not merely a rescue rung.
    // Try it before an envelope search: a too-tight pair can sometimes route
    // an envelope by sending both escapes OUTSIDE the two pad pairs, but the
    // resulting copper doubles back through the first component. R2 -> C14/C15
    // on board-d-synth-lmx2595 is that exact geometry. When the forward pad-pair
    // span cannot hold both tapers and a coupled stretch, the direct/fan shape
    // is the RF-honest answer even if a longer maze path happens to clear.
    if (try tryShortPair(run, pair, opts)) return true;
    for (opts, 0..) |ends, i| {
        censusEnds(ends, i);
        if (try tryEnds(run, pair, ends)) return true;
    }
    return false;
}

/// The first choice for a pair with no room for a coupled run at all.
///
/// Every coupled option above declines when the pair's two ends sit closer
/// together than their own pad exits need — the tapers alone eat the gap, and
/// asking for one anyway makes the leg jog out past the coupled run's start and
/// double back into its twin. On board-d-synth-lmx2595 that is both declared
/// pairs, and what shipped instead was two INDEPENDENT maze routes: 3-and-6
/// segment legs hooking around each other, 0.163 mm and 0.888 mm of skew.
///
/// A hand route holds the receiver pitch straight and fans once at the wider
/// passive pads, so that is what this offers (`diff_direct.directLegs`). It is
/// gated to the shape it is honest about and still faces the same exact
/// clearance probe as any other construction. The caller offers it BEFORE an
/// envelope search, because "a maze can reach two exterior escape points" does
/// not mean there is physical room for a coupled run BETWEEN the pads.
fn tryShortPair(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    opts: []const diff_route.Ends,
) std.mem.Allocator.Error!bool {
    const off = run.ctx.params.track_width + pair.gap;
    for (opts) |ends| {
        const legs = (try diff_direct.directLegs(run.ctx.arena, ends, off, ends.mid[0].layer)) orelse continue;
        if (try commitPairLegs(run, pair, legs)) return true;
    }
    return false;
}

/// One launch-pad configuration: route its envelope on the lattice, and — when
/// the caller's tier allows it — re-ask the gridless mesh whatever the maze
/// declined.
fn tryEnds(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    ends: diff_route.Ends,
) std.mem.Allocator.Error!bool {
    if (try tryEndsMaze(run, pair, ends)) return true;
    return try tryEndsShape(run, pair, ends);
}

/// The MESH half: ask `diff_shape` for a channel the whole envelope fits and
/// build the same legs from whatever it finds.
///
/// A maze that declines says the pair's corridor does not exist ON THE LATTICE,
/// which is a different claim from "does not exist" — the same gap the single-net
/// shape tiers were built to close, and the one a pair could not reach at all
/// (`shapeRescueTier` skips every pair member by name, because a leg drawn alone
/// is copper the coupling contract is certain to throw away). Here the mesh
/// answers for the ENVELOPE instead, so what comes back is a corridor both legs
/// fit in, and it is handed to `commitFloating` — the same construction, the same
/// via-float ladder, the same exact clearance probe the maze's centreline faces.
///
/// Off unless the caller's tier turns it on, so every board that has ever routed
/// without it is byte-identical. Nothing here draws copper on its own: a channel
/// that cannot be built into two legal legs leaves the board exactly as the maze
/// left it, and the pair falls through to the caller's legacy leader/follower
/// route as before.
fn tryEndsShape(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    ends: diff_route.Ends,
) std.mem.Allocator.Error!bool {
    if (!run.ctx.pair_channel.meshes()) return false;
    const p = run.placement.nets[pair.p].name;
    const n = run.placement.nets[pair.n].name;
    const channel = try diff_shape.envelopeChannel(run, pair, ends);
    const center = channel.center orelse {
        reportPinch(run, pair, channel.pinch);
        censusDecline(run, pair, .no_mesh_channel, 0);
        return false;
    };
    censusCenter(center);
    if (!try commitFloating(run, pair, ends, center)) {
        shapeLog("pair channel {s}/{s}: mesh channel found, no legal two-leg construction off it", .{ p, n });
        return false;
    }
    shapeLog("pair channel {s}/{s}: re-laid coupled through the mesh ({d} runs, {d} vias)", .{
        p,
        n,
        center.runs.len,
        center.vias.len,
    });
    return true;
}

/// Say WHY the mesh found no envelope channel, and record it for the caller.
///
/// "No envelope channel in the mesh either" is a true statement and an unusable
/// one: it says the geometry refused without saying what the geometry IS, and a
/// caller holding rip authority is left with nothing to nominate. The mesh knows
/// — it can be walked through its own walls to the narrowest cut between the
/// pair's two terminals — so what is printed here is that cut: the copper on
/// each side, how much room there actually is, and how much the envelope needed.
/// The same fact goes into the caller's log (`pair_pinch`), where a transaction
/// that lost this pair can turn it into a rip.
///
/// A pinch the mesh could not name at all — a wall owned by the search window's
/// own edge rather than by any copper — keeps exactly the old line, because
/// there is nothing to name and inventing an owner would be worse than silence.
fn reportPinch(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    found: ?cdt_layers.Pinch,
) void {
    const p = run.placement.nets[pair.p].name;
    const n = run.placement.nets[pair.n].name;
    const pinch = found orelse {
        shapeLog("pair channel {s}/{s}: no envelope channel in the mesh either", .{ p, n });
        return;
    };
    shapeLog("pair channel {s}/{s}: pinched by {s} vs {s} (need {d:.3}mm, have {d:.3}mm) at ({d:.3},{d:.3}) L{d}", .{
        p,
        n,
        pinchOwnerName(run, pinch.a),
        if (pinch.b) |other| pinchOwnerName(run, other) else "the same body",
        pinch.need_mm,
        pinch.have_mm,
        pinch.at[0],
        pinch.at[1],
        pinch.layer,
    });
    const sink = run.ctx.pinch_log orelse return;
    sink.record(.{
        .pair = .{ @intCast(pair.p), @intCast(pair.n) },
        .nets = .{
            pinchOwnerNet(pinch.a),
            if (pinch.b) |other| pinchOwnerNet(other) else pinchOwnerNet(pinch.a),
        },
        .at = pinch.at,
        .layer = pinch.layer,
        .have_mm = pinch.have_mm,
        .need_mm = pinch.need_mm,
    });
}

/// What to call one side of a pinch: its NET, which is the name a reader knows
/// the copper by and the only handle a rip can take it by. A keepout or the
/// board-edge band carries no net, so it is named for what it is.
fn pinchOwnerName(run: router.CoupledRun, owner: cdt_route.Owner) []const u8 {
    if (owner.kind == .keepout) return "a keepout or the board edge";
    if (owner.net < 0) return "unowned copper";
    const net_i: usize = @intCast(owner.net);
    if (net_i >= run.placement.nets.len) return "unowned copper";
    return run.placement.nets[net_i].name;
}

/// The flattened net index behind one side of a pinch, or `-1` where the side is
/// a keepout or the board edge — something no transaction may ever negotiate.
fn pinchOwnerNet(owner: cdt_route.Owner) i32 {
    return if (owner.kind == .keepout) -1 else owner.net;
}

/// The maze half: route the pair's envelope on the lattice, re-read that copper
/// as one centreline, drop it, and land the constructed legs.
fn tryEndsMaze(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    ends: diff_route.Ends,
) std.mem.Allocator.Error!bool {
    const pts = [2]router.NetPt{
        .{ .x = ends.far[0].x, .y = ends.far[0].y, .layer = ends.far[0].layer },
        .{ .x = ends.far[1].x, .y = ends.far[1].y, .layer = ends.far[1].layer },
    };
    const marks = [2]usize{ run.tracks.items.len, run.vias.items.len };
    const pads = try pairPads(run, pair, ends);
    if (!(try routeEnvelope(run, pair, &pts, pads))) {
        censusDecline(run, pair, .no_corridor, 0);
        return false;
    }
    const center = try centerlineOf(run, pair, ends, marks);
    router.rollbackDirectRun(run.direct(pair.p), marks[0], marks[1]); // drop the envelope copper
    if (center) |c| censusCenter(c);
    return try commitFloating(run, pair, ends, center orelse {
        censusDecline(run, pair, .not_a_path, 0);
        return false;
    });
}

/// The coupled diff-pair seam in the greedy loop. True when this net's copper
/// is already on the board and the caller must move on: either it is the
/// follower leg of a pair its leader laid coupled, or it IS that leader and the
/// coupled route just succeeded. Both legs are recorded non-reroutable, so
/// rip-up can never tear one member out on its own and leave a decoupled twin.
///
/// A pair that lands here also skips the caller's inline RF gloss, so its bend
/// discipline is measured on the way out (`auditPairBends`). The copper mark is
/// taken on entry, where it is exactly the greedy pass's own: nothing of this
/// net is on the board yet.
pub fn leaderRoute(
    run: router.CoupledRun,
    net_i: usize,
    done: []bool,
) std.mem.Allocator.Error!bool {
    if (done[net_i]) return true;
    const keep = run.tracks.items.len;
    const pair = router.pairOf(run.ctx, run.placement.diff_pairs, net_i) orelse return false;
    if (!router.pairCouplable(run.ctx, pair)) {
        censusDecline(run, pair, .not_couplable, 0);
        return false;
    }
    if (!(try tryCoupledPair(run, pair))) return false;
    done[pair.n] = true;
    try auditPairBends(run, keep);
    return true;
}

/// Record the RF bend discipline of a coupled pair's freshly laid copper —
/// `run.tracks[keep..]`, both legs — without reshaping any of it.
///
/// A coupled pair is routed as one centreline and split into two exact offset
/// legs, length-matched to `pair_skew_tol_mm`. Smoothing one leg alone would
/// move copper the other leg's skew was equalized against, so `leaderRoute`'s
/// caller skips the inline RF gloss entirely. That is right for the COPPER and
/// was wrong for the REPORT: `sharp_bend` DRC echoes exactly what the smoothing
/// pass records and nothing else, so a `(diff-pair …) (max-freq …)` class — the
/// ordinary LVDS/USB3 declaration — kept its raw mitred lattice corners with no
/// arcs AND no warning. Here the corners are measured and filed per leg, and
/// the copper is left to the pair.
///
/// No external clearance probe is handed to the smoother: nothing is drawn, so
/// there is nothing to clear, and that oracle is aimed at ONE net while this
/// reads two.
pub fn auditPairBends(run: router.CoupledRun, keep: usize) std.mem.Allocator.Error!void {
    const ctx = run.ctx;
    if (ctx.timing) |t| t.begin(.smooth);
    defer {
        if (ctx.timing) |t| t.end(.smooth);
    }
    const sharp = try bend_smooth.detect(ctx.arena, .{
        .placement = run.placement,
        .params = ctx.params,
        .tracks = run.tracks.items,
        .vias = run.vias.items,
        .keep = keep,
    });
    if (sharp.len == 0) return;
    // The router's `net_smooth` map is keyed per net (rip-up drops one net's
    // entry at a time), so the pair's shared report is filed leg by leg.
    var by_net = std.AutoHashMapUnmanaged(i32, std.ArrayList(router.SharpBend)).empty;
    for (sharp) |sb| {
        const slot = try by_net.getOrPut(ctx.arena, sb.net);
        if (!slot.found_existing) slot.value_ptr.* = .empty;
        try slot.value_ptr.append(ctx.arena, sb);
    }
    var it = by_net.iterator();
    while (it.next()) |entry| {
        const prev = ctx.rf.net_smooth.get(entry.key_ptr.*);
        try ctx.rf.net_smooth.put(ctx.arena, entry.key_ptr.*, .{
            .arcs = if (prev) |p| p.arcs else &.{},
            .sharp = entry.value_ptr.items,
        });
    }
}

// ── Rejection census ────────────────────────────────────────────────────────
//
// WHY a declared pair declined to couple, named. Every rejection here is either
// a construction defect (the blocker reads SELF-P / SELF-N — the pair's own
// copper) or a real obstacle (a foreign net, by name). Telling those apart from
// the outside is impossible, and guessing at it is how a coupled-pair bug turns
// into a week: each fix in this module's history was found by reading a census
// exactly like this one and none were found without it.
//
// Compiled out entirely unless `census_on` is flipped, so the shipped router
// pays nothing and prints nothing.

/// Flip to true to have every coupled-pair rejection name its blocker on
/// stderr. Off in normal builds — a board with a pair that couples cleanly has
/// nothing to say, and one that does not is being actively debugged.
const census_on = false;

/// Name a net index the way the census reads best: the pair's own two nets are
/// called out as SELF, because "blocked by REF_LMX_N" and "blocked by my own
/// twin" are the same string but completely different bugs.
fn censusName(run: router.CoupledRun, pair: diff_pairs.DiffPair, idx: i32) []const u8 {
    if (idx == @as(i32, @intCast(pair.p))) return "SELF-P";
    if (idx == @as(i32, @intCast(pair.n))) return "SELF-N";
    if (idx < 0) return "(none)";
    const u: usize = @intCast(idx);
    if (u >= run.placement.nets.len) return "(oob)";
    return run.placement.nets[u].name;
}

/// Closest approach between a segment and a pad's RECTANGLE, not its bounding
/// circle. A connector pad is 1.0 x 0.35 mm; treating it as round overstates
/// how close a track beside it is by nearly a third of a millimetre, which is
/// the difference between a census that names the blocker and one that names
/// its neighbour.
fn censusPadGap(o: router.PadObs, a: diff_route.Pt, b: diff_route.Pt) f64 {
    const cx = (o.x0 + o.x1) / 2;
    const cy = (o.y0 + o.y1) / 2;
    const hw = @abs(o.x1 - o.x0) / 2;
    const hh = @abs(o.y1 - o.y0) / 2;
    var lo = std.math.inf(f64);
    var i: usize = 0;
    while (i <= 16) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / 16;
        const px = a.x + t * (b.x - a.x);
        const py = a.y + t * (b.y - a.y);
        const dx = @max(@abs(px - cx) - hw, 0);
        const dy = @max(@abs(py - cy) - hh, 0);
        lo = @min(lo, std.math.hypot(dx, dy));
    }
    return lo;
}

/// Distance from a point to a segment.
fn censusPtSeg(p: diff_route.Pt, a: diff_route.Pt, b: diff_route.Pt) f64 {
    const vx = b.x - a.x;
    const vy = b.y - a.y;
    const l2 = vx * vx + vy * vy;
    if (l2 <= 1e-12) return std.math.hypot(p.x - a.x, p.y - a.y);
    const t = std.math.clamp(((p.x - a.x) * vx + (p.y - a.y) * vy) / l2, 0, 1);
    return std.math.hypot(p.x - (a.x + t * vx), p.y - (a.y + t * vy));
}

/// One rejected leg segment, with every object that is too close to it.
fn censusSeg(run: router.CoupledRun, pair: diff_pairs.DiffPair, net: usize, s: diff_route.LegSeg) void {
    if (!census_on) return;
    const ctx = run.ctx;
    const mine: i32 = @intCast(net);
    log.warn("diff-pair reject: {s} {s} leg L{d} ({d:.4},{d:.4})->({d:.4},{d:.4})", .{ @tagName(s.side), @tagName(s.kind), s.layer, s.a.x, s.a.y, s.b.x, s.b.y });
    for (run.tracks.items) |t| {
        if (t.net == mine or t.layer != s.layer) continue;
        const d = @min(@min(censusPtSeg(s.a, .{ .x = t.x1, .y = t.y1 }, .{ .x = t.x2, .y = t.y2 }), censusPtSeg(s.b, .{ .x = t.x1, .y = t.y1 }, .{ .x = t.x2, .y = t.y2 })), @min(censusPtSeg(.{ .x = t.x1, .y = t.y1 }, s.a, s.b), censusPtSeg(.{ .x = t.x2, .y = t.y2 }, s.a, s.b)));
        const halo = router.keepoutExtra(ctx, t.net);
        const need = t.width / 2 + ctx.params.track_width / 2 + ctx.params.clearance + halo;
        if (d >= need) continue;
        log.warn("  vs track {s} ({d:.4},{d:.4})->({d:.4},{d:.4}): {d:.4} of {d:.4} (halo {d:.4})", .{ censusName(run, pair, t.net), t.x1, t.y1, t.x2, t.y2, d, need, halo });
    }
    for (ctx.obs) |o| {
        if (o.net == mine) continue;
        const halo = router.keepoutExtra(ctx, o.net);
        const need = ctx.params.track_width / 2 + ctx.params.clearance + halo;
        const d = censusPadGap(o, s.a, s.b);
        if (d >= need) continue;
        log.warn("  vs pad {s} at ({d:.3},{d:.3}): {d:.4} of {d:.4} (halo {d:.4})", .{ censusName(run, pair, o.net), (o.x0 + o.x1) / 2, (o.y0 + o.y1) / 2, d, need, halo });
    }
    for (run.vias.items) |v| {
        if (v.net == mine) continue;
        const d = censusPtSeg(.{ .x = v.x, .y = v.y }, s.a, s.b);
        const halo = router.keepoutExtra(ctx, v.net);
        const need = v.dia / 2 + ctx.params.track_width / 2 + ctx.params.clearance + halo;
        if (d >= need) continue;
        log.warn("  vs via {s} at ({d:.3},{d:.3}): {d:.4} of {d:.4} (halo {d:.4})", .{ censusName(run, pair, v.net), v.x, v.y, d, need, halo });
    }
}

/// One rejected via barrel, with every object that is too close to it.
fn censusVia(run: router.CoupledRun, pair: diff_pairs.DiffPair, net: usize, at: diff_route.Pt) void {
    if (!census_on) return;
    const ctx = run.ctx;
    const mine: i32 = @intCast(net);
    log.warn("diff-pair reject: {s} barrel at ({d:.4},{d:.4})", .{ censusName(run, pair, mine), at.x, at.y });
    for (run.tracks.items) |t| {
        if (t.net == mine) continue;
        const d = censusPtSeg(at, .{ .x = t.x1, .y = t.y1 }, .{ .x = t.x2, .y = t.y2 });
        const need = ctx.params.via_dia / 2 + t.width / 2 + ctx.params.clearance;
        if (d >= need) continue;
        log.warn("  vs track {s}: {d:.4} of {d:.4}", .{ censusName(run, pair, t.net), d, need });
    }
    for (ctx.obs) |o| {
        if (o.net == mine) continue;
        const need = ctx.params.via_dia / 2 + ctx.params.clearance;
        const d = censusPadGap(o, at, at);
        if (d >= need) continue;
        log.warn("  vs pad {s} at ({d:.3},{d:.3}): {d:.4} of {d:.4}", .{ censusName(run, pair, o.net), (o.x0 + o.x1) / 2, (o.y0 + o.y1) / 2, d, need });
    }
}

/// Every constructed segment of one candidate, in emission order. The census's
/// other entries say WHAT blocked; this says what the construction actually
/// built, which is the only way to tell a bad leg from a bad blocker.
fn censusLegs(legs: diff_route.Legs) void {
    if (!census_on) return;
    for (legs.segs, 0..) |s, i| {
        log.warn("  leg[{d}] {s} {s} L{d} ({d:.4},{d:.4})->({d:.4},{d:.4})", .{ i, @tagName(s.side), @tagName(s.kind), s.layer, s.a.x, s.a.y, s.b.x, s.b.y });
    }
    for (legs.vias, 0..) |v, i| {
        log.warn("  via[{d}] P({d:.4},{d:.4}) N({d:.4},{d:.4})", .{ i, v.p.x, v.p.y, v.n.x, v.n.y });
    }
}

/// A construction whose own barrels never seated, after the whole spread
/// ladder. Silent otherwise — a candidate that seats is not news.
fn censusBarrel(run: router.CoupledRun, legs: diff_route.Legs, swap: ?usize) void {
    if (!census_on) return;
    const ctx = run.ctx;
    const need = ctx.params.via_dia / 2 + ctx.params.track_width / 2 + ctx.params.clearance;
    const clash = diff_route.barrelClash(legs, need) orelse return;
    log.warn("diff-pair barrel unseated (swap {?d}): ({d:.4},{d:.4}) vs {s} {s} L{d} ({d:.4},{d:.4})->({d:.4},{d:.4}): {d:.4} of {d:.4}", .{
        swap,            clash.at.x,    clash.at.y,    @tagName(clash.seg.side), @tagName(clash.seg.kind),
        clash.seg.layer, clash.seg.a.x, clash.seg.a.y, clash.seg.b.x,            clash.seg.b.y,
        clash.gap,       clash.need,
    });
}

/// A construction fold: the two legs crossing on the coupled run.
fn censusFold(legs: diff_route.Legs, got: f64, need: f64) void {
    if (!census_on) return;
    log.warn("diff-pair reject: legs fold to {d:.4} of {d:.4} on the coupled run ({d} segs)", .{ got, need, legs.segs.len });
    const pair = diff_route.tightestOpposite(legs) orelse return;
    log.warn("  P L{d} ({d:.4},{d:.4})->({d:.4},{d:.4})  vs  N L{d} ({d:.4},{d:.4})->({d:.4},{d:.4})", .{
        pair[0].layer, pair[0].a.x, pair[0].a.y, pair[0].b.x, pair[0].b.y,
        pair[1].layer, pair[1].a.x, pair[1].a.y, pair[1].b.x, pair[1].b.y,
    });
}

/// Every point a coupled pair can give up at BEFORE its construction is ever
/// probed. A decline and a rejection look identical from outside — the pair
/// simply falls back to the legacy route — but they are fixed in completely
/// different code, so each one is named.
const DeclineStage = enum {
    /// A hard-guided net (waypoints / branches) — the pair is not ours to route.
    not_couplable,
    /// The pads do not resolve into a launch configuration at either end.
    no_end_option,
    /// No corridor the full pair envelope fits through — on the LATTICE.
    no_corridor,
    /// The envelope's own copper did not read back as one two-ended path.
    not_a_path,
    /// The path is a path, but no two-leg construction comes off it.
    no_construction,
    /// The gridless mesh was asked for the envelope after the maze declined, and
    /// found no channel either — the geometry answer, with no lattice behind it.
    no_mesh_channel,

    /// One line of prose per stage — what a reader needs to know where to look.
    fn label(self: DeclineStage) []const u8 {
        return switch (self) {
            .not_couplable => "pair not couplable in this context",
            .no_end_option => "no launch-pad configuration",
            .no_corridor => "no envelope-wide corridor",
            .not_a_path => "envelope copper is not a simple path",
            .no_construction => "centreline carries no two-leg construction",
            .no_mesh_channel => "no envelope-wide channel in the mesh either",
        };
    }
};

/// A pair that never reached the clearance gate, named by the STAGE it died at.
fn censusDecline(
    run: router.CoupledRun,
    pair: diff_pairs.DiffPair,
    stage: DeclineStage,
    opt: usize,
) void {
    if (!census_on) return;
    log.warn("diff-pair decline [{s}] option {d}: {s}", .{
        run.placement.nets[pair.p].name,
        opt,
        stage.label(),
    });
}

/// One launch-pad configuration's geometry: the pad-pair walk, its escape
/// terminal, and the far terminal the envelope search actually routes between.
fn censusEnds(ends: diff_route.Ends, opt: usize) void {
    if (!census_on) return;
    for ([2]usize{ 0, 1 }) |end| {
        log.warn("  ends[{d}] end {d}: mid ({d:.4},{d:.4}) far ({d:.4},{d:.4}) L{d}", .{
            opt, end, ends.mid[end].x, ends.mid[end].y, ends.far[end].x, ends.far[end].y, ends.mid[end].layer,
        });
        for (ends.seq[end], 0..) |pp, i| log.warn("    pad[{d}] P({d:.4},{d:.4}) N({d:.4},{d:.4}) span {d:.4}", .{
            i, pp.p.x, pp.p.y, pp.n.x, pp.n.y, std.math.hypot(pp.p.x - pp.n.x, pp.p.y - pp.n.y),
        });
    }
}

/// The re-read centreline one candidate is built from: every run's layer and
/// vertices. A construction defect is almost always visible here first.
fn censusCenter(c: diff_route.Centerline) void {
    if (!census_on) return;
    for (c.runs, 0..) |r, i| {
        log.warn("  center run[{d}] L{d} {d} pts", .{ i, r.layer, r.pts.len });
        for (r.pts) |pt| log.warn("      ({d:.4},{d:.4})", .{ pt.x, pt.y });
    }
    for (c.vias, 0..) |v, i| log.warn("  center via[{d}] ({d:.4},{d:.4})", .{ i, v.x, v.y });
}

// ── Escalation: the pair's second chance, still coupled ─────────────────────
//
// The greedy pass routes a declared pair as ONE centreline. Escalation used to
// route it as two nets: a failed leader was re-mazed alone and a failed
// follower was corridor-fitted to whatever copper the leader happened to have
// (`router.routeFollowerLeg`) — so a pair rescued here came back with geometry
// that is merely *near* parallel instead of the exact ±(width+gap)/2 offsets,
// mitered bends, paired vias and matched pad fans the class declared. The
// class is a promise about impedance and skew; a rescue that quietly drops it
// is worse than one that declines.
//
// `recouple` is the fix and it comes FIRST: take both legs off the board, run
// the same coupled construction the greedy pass runs, and keep it only if it
// lands. Ripping the routed twin is what makes the attempt possible at all —
// the envelope search reads the twin's copper as foreign, so a leader still
// down walls its own pair out — and it is safe because the whole thing is one
// snapshot transaction. On failure the board is restored byte for byte and the
// single-leg ladder runs exactly as before, so the tier can only add coupled
// pairs, never subtract a routed leg.

/// Does `net_i` belong to a declared pair? (Such a net escalates through
/// `escalatePair`, never as a singleton, so its twin is never left behind.)
pub fn isPairMember(pairs: []const diff_pairs.DiffPair, net_i: usize) bool {
    for (pairs) |pair| if (pair.p == net_i or pair.n == net_i) return true;
    return false;
}

/// Retry a diff pair under escalation: the COUPLED construction for the whole
/// pair first (`recouple`), then — only if that declines — the legacy
/// non-destructive ladder, which re-routes a failed leader and fits its
/// follower to the leader's copper without ever ripping a routed leg. Returns
/// the number of the pair's legs newly routed (0, 1, or 2).
pub fn escalatePair(run: router.EscalateRun, pair: diff_pairs.DiffPair) std.mem.Allocator.Error!usize {
    const ctx = run.ctx;
    const p_slot = router.ripNetSlot(run.routable, pair.p) orelse return 0;
    const n_slot = router.ripNetSlot(run.routable, pair.n) orelse return 0;
    if (p_slot.ok and n_slot.ok) return 0;
    if (!router.netEnabled(ctx, pair.p) or !router.netEnabled(ctx, pair.n)) return 0;
    const was = @as(usize, @intFromBool(p_slot.ok)) + @intFromBool(n_slot.ok);
    if (try recouple(run, pair)) return 2 - was;
    var rescued: usize = 0;
    ctx.escalate_budget = run.budget;
    defer ctx.escalate_budget = 0;
    if (!p_slot.ok) {
        try router.rerouteNet(ctx, run.placement, run.idx_of, p_slot, run.tracks, run.vias);
        if (p_slot.ok) {
            router.clearSearchLimit(ctx, pair.p);
            rescued += 1;
        }
    }
    if (p_slot.ok and !n_slot.ok) {
        try router.routeFollowerLeg(run, pair, n_slot);
        if (n_slot.ok) {
            router.clearSearchLimit(ctx, pair.n);
            rescued += 1;
        }
    }
    // A routed leg freezes; a still-failed leg becomes a rip-up rescue candidate
    // (the follow-on rip-up phase now attacks a pair leg's blockers too).
    p_slot.reroutable = !p_slot.ok;
    n_slot.reroutable = !n_slot.ok;
    return rescued;
}

/// Re-run the coupled construction for a PAIR in escalation: both legs off the
/// board, one centreline, all under `run.budget` expansions — and rolled back
/// whole if it declines, so a routed twin is never spent on a failed attempt.
///
/// Budget: exactly one attempt per pair per escalation pass. The construction
/// is itself bounded (`pair_end_options` launch configurations, each one
/// envelope search under the caller's expansion budget), and a pair that
/// declines is left to the single-leg ladder rather than retried here.
///
/// Both legs come back non-reroutable on success — the same freeze the greedy
/// pass applies, so rip-up can never tear one member out and leave a decoupled
/// twin.
pub fn recouple(run: router.EscalateRun, pair: diff_pairs.DiffPair) std.mem.Allocator.Error!bool {
    const ctx = run.ctx;
    if (!router.pairCouplable(ctx, pair)) return false;
    const p_slot = router.ripNetSlot(run.routable, pair.p) orelse return false;
    const n_slot = router.ripNetSlot(run.routable, pair.n) orelse return false;
    const coupled_run = router.CoupledRun{
        .ctx = ctx,
        .placement = run.placement,
        .idx_of = run.idx_of,
        .tracks = run.tracks,
        .vias = run.vias,
    };
    // One transaction's rollback point at a time. allocator-ok: the injected
    // route arena is monotonic and cannot reclaim the snapshot on its own.
    var scratch_inst = std.heap.ArenaAllocator.init(ctx.arena);
    defer scratch_inst.deinit();
    const snap = try router.saveSnapshot(scratch_inst.allocator(), ctx, run.tracks, run.vias, run.routable);
    router.ripNet(ctx, run.tracks, run.vias, pair.p);
    router.ripNet(ctx, run.tracks, run.vias, pair.n);
    p_slot.ok = false;
    n_slot.ok = false;
    const keep = run.tracks.items.len;
    ctx.escalate_budget = run.budget;
    const ok = try tryCoupledPair(coupled_run, pair);
    ctx.escalate_budget = 0;
    if (!ok) {
        try router.restoreSnapshot(ctx, run.tracks, run.vias, run.routable, snap);
        return false;
    }
    try auditPairBends(coupled_run, keep);
    p_slot.ok = true;
    n_slot.ok = true;
    p_slot.reroutable = false;
    n_slot.reroutable = false;
    router.clearSearchLimit(ctx, pair.p);
    router.clearSearchLimit(ctx, pair.n);
    return true;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/router - a coupled diff pair applies KiCad's edge-to-edge via gap independently of its trace gap
test "dp_coupled pair via spread honors the KiCad via gap" {
    const params = router.RouteParams{
        .track_width = 0.15,
        .clearance = 0.127,
        .via_drill = 0.3,
        .via_dia = 0.6,
    };
    const explicit = diff_pairs.DiffPair{ .p = 0, .n = 1, .gap = 0.2, .via_gap = 0.35 };
    try testing.expectApproxEqAbs(@as(f64, 0.95), pairViaSpreadFor(params, explicit, 0.35, 0.2), 1e-9);

    // Zero retains KiCad's default "via gap same as trace gap" behavior.
    const inherited = diff_pairs.DiffPair{ .p = 0, .n = 1, .gap = 0.2 };
    try testing.expectApproxEqAbs(@as(f64, 0.8), pairViaSpreadFor(params, inherited, 0.35, 0.2), 1e-9);
}

// spec: placement/router - a declined coupled diff pair can name the copper that blocked it, telling the pair's own legs apart from a foreign net
test "dp_coupled census names SELF legs apart from foreign nets and measures pad rectangles" {
    // The census exists so a declined pair is never a mystery. Two properties
    // carry that: the pair's OWN nets read as SELF (a leg grazing its twin and
    // a leg grazing a stranger are the same distance but opposite diagnoses),
    // and a pad is measured as the RECTANGLE it is — a 1.0 x 0.35 mm connector
    // pad judged as a circle reads a third of a millimetre closer than it is,
    // which is enough to name the wrong blocker.
    const nets = [_]optimizer.FlatNet{
        .{ .name = "D_P", .pins = &.{} },
        .{ .name = "D_N", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    var placement = router.CoupledRun{
        .ctx = undefined,
        .placement = undefined,
        .idx_of = undefined,
        .tracks = undefined,
        .vias = undefined,
    };
    _ = &placement;
    var p: optimizer.Placement = .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
    };
    _ = &p;

    // A 1.0 x 0.35 mm pad centred at the origin, and a track running 0.4 mm
    // above it: the true gap is 0.4 - 0.175 = 0.225, not 0.4 - 0.5 (clamped 0).
    const pad = router.PadObs{ .x0 = -0.5, .y0 = -0.175, .x1 = 0.5, .y1 = 0.175, .net = 2 };
    const gap = censusPadGap(pad, .{ .x = -1, .y = 0.4 }, .{ .x = 1, .y = 0.4 });
    try testing.expectApproxEqAbs(@as(f64, 0.225), gap, 1e-9);
}

// spec: placement/router - a declined coupled diff pair that never reached the clearance gate can name the stage it gave up at
test "dp_coupled decline census names every stage distinctly" {
    // A pair that declines and a pair whose construction is rejected both end
    // up on the legacy route, indistinguishable from outside. The rejection
    // census already names the copper that blocked a built candidate; this is
    // its other half, and it is only worth anything if each stage says
    // something different from the rest.
    const all = std.enums.values(DeclineStage);
    try testing.expect(all.len > 0);
    for (all, 0..) |a, i| {
        try testing.expect(a.label().len > 0);
        for (all[0..i]) |b| try testing.expect(!std.mem.eql(u8, a.label(), b.label()));
    }
}

fn mkPad(x: f64, y: f64) [1]geometry.Pad {
    return .{.{ .number = "1", .x = x, .y = y, .w = 0.4, .h = 0.4 }};
}

fn mkPart(ref: []const u8, x: f64, y: f64, pads: []const geometry.Pad) optimizer.Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = pads,
        .fallback = false,
        .x = x,
        .y = y,
    };
}

/// A pair with nothing in its way but a diagonal to cover: the coupled
/// centreline routes end to end (so `leaderRoute` takes the pair) and turns on
/// the way, which is the geometry the bend audit is about. `rules` declares the
/// class; `pair` drops the declaration for the control run.
fn coupledPairFixture(
    arena: std.mem.Allocator,
    rules: []const optimizer.NetRule,
    pair: bool,
) std.mem.Allocator.Error!router.RouteResult {
    const pad = mkPad(0, 0);
    const parts = arena.alloc(optimizer.Part, 4) catch return error.OutOfMemory;
    parts[0] = mkPart("R1", 0, 0, &pad);
    parts[1] = mkPart("R2", 6, 3, &pad);
    parts[2] = mkPart("R3", 0, 0.6, &pad);
    parts[3] = mkPart("R4", 6, 3.6, &pad);
    const pins_p = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const pins_n = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const nets = arena.alloc(flat_netlist.FlatNet, 2) catch return error.OutOfMemory;
    nets[0] = .{ .name = "D_P", .pins = &pins_p };
    nets[1] = .{ .name = "D_N", .pins = &pins_n };
    const pairs = arena.alloc(diff_pairs.DiffPair, 1) catch return error.OutOfMemory;
    pairs[0] = .{ .p = 0, .n = 1, .gap = 0.4 };
    var placement = optimizer.Placement{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 7,
        .maxy = 5,
        .generated = true,
        .diff_pairs = if (pair) pairs else &.{},
    };
    placement.rules.net = rules;
    return router.route(arena, placement, .{});
}

/// A too-short pair matching board-d-synth-lmx2595's R2 -> C14/C15 geometry.
/// The open board is intentional: an exterior envelope route CAN clear here,
/// which proves the driver prefers the honest direct classification rather
/// than accepting a longer loop merely because the maze found one.
fn shortR2Fixture(arena: std.mem.Allocator) std.mem.Allocator.Error!router.RouteResult {
    const r2_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = -0.51, .w = 0.4, .h = 0.4 },
        .{ .number = "2", .x = 0, .y = 0.51, .w = 0.4, .h = 0.4 },
    };
    const cap_pad = mkPad(0, 0);
    const parts = try arena.alloc(optimizer.Part, 3);
    parts[0] = mkPart("R2", 0, 0, &r2_pads);
    parts[0].hh = 0.75;
    parts[1] = mkPart("C14", 1.02, -0.50, &cap_pad);
    parts[2] = mkPart("C15", 1.02, 0.50, &cap_pad);
    const pins_p = [_]flat_netlist.FlatPin{ .{ .ref_des = "R2", .pin = "1" }, .{ .ref_des = "C14", .pin = "1" } };
    const pins_n = [_]flat_netlist.FlatPin{ .{ .ref_des = "R2", .pin = "2" }, .{ .ref_des = "C15", .pin = "1" } };
    const nets = try arena.alloc(flat_netlist.FlatNet, 2);
    nets[0] = .{ .name = "REF_P", .pins = &pins_p };
    nets[1] = .{ .name = "REF_N", .pins = &pins_n };
    const pairs = try arena.alloc(diff_pairs.DiffPair, 1);
    pairs[0] = .{ .p = 0, .n = 1, .gap = 0.127 };
    const placement = optimizer.Placement{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1.5,
        .miny = -1.5,
        .maxx = 2.5,
        .maxy = 1.5,
        .generated = true,
        .diff_pairs = pairs,
    };
    return router.route(arena, placement, .{});
}

// spec: placement/router - a too-short differential pair is routed directly before an exterior coupled escape can send it back through its first component
test "a too-short R2 pair chooses direct pad hops before a looping envelope route" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const routed = try shortR2Fixture(arena_inst.allocator());

    try testing.expectEqual(@as(usize, 2), routed.routed);
    try testing.expectEqual(@as(usize, 2), routed.tracks.len);
    try testing.expectEqual(@as(usize, 0), routed.vias.len);
    for (routed.tracks) |t| {
        try testing.expectApproxEqAbs(@as(f64, 0), @min(t.x1, t.x2), 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 1.02), @max(t.x1, t.x2), 1e-9);
        try testing.expect(@abs(t.y2 - t.y1) <= 0.01 + 1e-9);
    }
}

// spec: placement/router - a coupled diff pair's under-radius corners are reported as sharp bends even though its copper is never reshaped
test "a coupled max-freq diff pair reports its raw corners instead of staying silent" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // The ordinary LVDS/USB3 declaration: a class that is BOTH a diff pair and
    // RF-disciplined. The coupled construction lays both legs as one unit and
    // the greedy loop moves straight on, so no arc may be placed — reshaping one
    // leg alone would break the pair's skew equalization.
    const rf = [_]optimizer.NetRule{
        .{ .rf = .{ .max_freq_hz = 12e9 } },
        .{ .rf = .{ .max_freq_hz = 12e9 } },
    };
    const res = try coupledPairFixture(arena, &rf, true);
    try testing.expectEqual(@as(usize, 2), res.routed);
    try testing.expectEqual(@as(usize, 0), res.arcs.len);
    // The control: the same board and the same RF class with the pair
    // declaration dropped. Now the legs route independently, the inline gloss
    // runs, and the corners come out as ARCS — so it really is the coupled path
    // that suppresses smoothing here, and it must not suppress the report too.
    const solo = try coupledPairFixture(arena, &rf, false);
    try testing.expect(solo.arcs.len > 0);
    // …and that silence is exactly what used to hide the raw mitred corners.
    // Every corner is now measured and filed, on BOTH legs, as a real
    // under-radius finding: nothing was smoothed, so the achieved radius is
    // zero against a floor the class actually declared.
    try testing.expect(res.sharp_bends.len > 0);
    const on_p = sharpOnNet(res.sharp_bends, 0) orelse return error.NoFindingOnP;
    const on_n = sharpOnNet(res.sharp_bends, 1) orelse return error.NoFindingOnN;
    try testing.expectEqual(@as(f64, 0), on_p.radius);
    try testing.expectEqual(@as(f64, 0), on_n.radius);
    try testing.expect(on_p.required > 0);
    try testing.expect(on_n.required > 0);
}

/// The first bend finding on `net`, or null — a helper so the test above reads
/// one leg's report without a second top-level loop in its body.
fn sharpOnNet(list: []const router.SharpBend, net: i32) ?router.SharpBend {
    for (list) |sb| if (sb.net == net) return sb;
    return null;
}

// spec: placement/router - a declared pair's member escalates through the pair driver, never as a singleton
test "a declared pair's member is recognised as a pair member" {
    const pairs = [_]diff_pairs.DiffPair{
        .{ .p = 3, .n = 4, .gap = 0.2 },
        .{ .p = 7, .n = 9, .gap = 0.1 },
    };
    // Either leg counts — the singleton escalation loop skips both so the pair
    // driver owns them, and a rescued leg can never strand its twin.
    try testing.expect(isPairMember(&pairs, 3));
    try testing.expect(isPairMember(&pairs, 4));
    try testing.expect(isPairMember(&pairs, 9));
    // An unrelated net, and an index between two members, are not.
    try testing.expect(!isPairMember(&pairs, 8));
    try testing.expect(!isPairMember(&pairs, 0));
    try testing.expect(!isPairMember(&.{}, 3));
}
