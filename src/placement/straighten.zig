//! Post-route simplification pass — the maze router's "gloss" step.
//!
//! The router grid pitch is `track_width + clearance`, and pads sit off-grid,
//! so a short chip-to-chip hop leaves the maze as an entry stub, a grid
//! staircase, and an exit stub — a micro-zigzag where a straight line would do.
//! The router calls this as a POST-PASS (`passBoard`, after rip-up and the
//! escape/stitch post-passes) so a simplified off-grid segment can never be
//! crowded by a later grid route. Each routed net's polylines are simplified:
//!
//!   1. Direct-first — replace a whole same-layer subpath with the single
//!      endpoint-to-endpoint segment when it clears everything.
//!   2. Corner-cutting — otherwise sweep interior vertices, dropping any whose
//!      A—C shortcut clears, to a fixed point (bounded forward sweeps).
//!   3. Re-elbow — in lattice mode, rewrite each surviving staircase as the
//!      two-segment octilinear elbow spanning it (`reelbow`), longest span
//!      first. A field-directed board instead keeps the exact-clearance
//!      continuous shortcut selected by stages 1–2.
//!   4. Chamfer — cut each surviving RIGHT-ANGLE corner with the largest
//!      clearing 45° diagonal (`Chamferer`).
//!
//! The public `pass` and all lattice/hop seams remain octilinear-preserving
//! (`octilinear.isOctilinear` gates 1 and 2; `octilinear.elbows` constructs 3;
//! 4 cuts equal lengths off two perpendicular arms). The whole-board field
//! seam is deliberately continuous: its high-resolution free-space result may
//! use an arbitrary exact-clearance chord instead of preserving a quantized
//! H/V/45 detour. Pad terminal legs, via pins, escape reserves, connectivity,
//! and the exact clearance probe remain common hard constraints in both modes.
//! Stages 1–3 are SIMPLIFIERS — they reduce segment count; stage 4 spends up to
//! one vertex per corner to buy bend discipline back where a square turn must
//! survive.
//! The maze search itself emits octilinear paths (8-neighbour lattice, plus the
//! bend-count tie-break that settles equal-cost ties toward one long run), so
//! the board's discipline holds whether or not this pass finds anything to do —
//! which is what makes it safe on a tight board, where the shortcut probes are
//! exactly the ones that stop clearing.
//!
//! Clearance is judged by the caller's `probe.clear(layer, a, b)`, which in the
//! router is the same DRC-grade segment test the direct-synthesis rescue uses
//! (pads, vias, foreign tracks, zones/keepouts, board outline) — so a
//! straightened segment is at least as legal as the maze path it replaces, and
//! (probed against the finished board) the pass never adds a DRC violation.
//! Chain endpoints (pad / via / junction connections) never move, so
//! connectivity is preserved. Escape-ruled nets (every `(max-freq …)` net by
//! default) keep every corner-cut vertex inside a pad end's straight reserve,
//! and take the direct collapse only when the single segment still leaves each
//! pad outward (`PadExit` axes) — the segment then IS the escape line. After
//! straightening a `(max-freq …)` net the router re-runs the arc smoother on
//! the taut polyline (`rearcTautNet`). Diff-pair legs are skipped in v1
//! (straightening one leg alone would break the coupled pair).
//!
//! Chain extraction is reused from `bend_smooth` (junction-breaking + collinear
//! merge), composing simplifyChain -> straighten on each routed net.
//!
//! THREE seams reach the board, and the copper that misses one of them is
//! exactly the copper that keeps its staircases (see `passBoard` / `glossHop`):
//! the whole-board pass at finish, the SAME pass once more after the post-route
//! cleanup (which rewrites geometry the first run had already finished with),
//! and a per-hop gloss inside the gap-closing pass, which routes long after the
//! finish and would otherwise be the only path putting raw lattice copper onto
//! a nearly-done board.

const std = @import("std");
const bypass_intent = @import("bypass_intent.zig");
const router = @import("router.zig");
const bend_smooth = @import("bend_smooth.zig");
const octilinear = @import("octilinear.zig");
const optimizer = @import("optimizer.zig");
const diff_pairs = @import("diff_pairs.zig");
const geometry = @import("geometry.zig");
const route_cleanup = @import("route_cleanup.zig");
const flat_netlist = @import("../flat_netlist.zig");

const eps = 1e-9;
/// Corner-cutting fixpoint bound. Each forward sweep removes ≥1 vertex or
/// stops, and a routed chain has only a handful of corners, so a few sweeps
/// always reach the fixed point; the bound just caps a pathological input.
const max_sweeps: usize = 8;
/// Chain-end-to-pad-centre matching tolerance (mm) for `PadExit` lookup —
/// routed chains terminate exactly on pad centres (the router's gate stubs),
/// so this only absorbs float drift.
const exit_snap: f64 = 0.01;
/// Escape gate for the direct collapse: cos of the widest angle (45°) the
/// single straight segment may deviate from a pad's outward escape axis and
/// still count as "the segment IS the escape line".
const escape_align_min_dot: f64 = 0.70710678;
/// Pin-matching tolerance (mm) — as with `exit_snap`, only float drift.
const pin_snap: f64 = 0.01;
/// Smallest 45° corner cut worth emitting (mm). A shorter chamfer is invisible
/// at fab resolution and only spends two extra vertices — and on a real board
/// it costs more than nothing: barracuda's `V_22V` carried six sub-0.1 mm
/// chamfer legs, each one a micro-segment in the fab output and in every
/// "is this trace still a staircase" count, for a corner cut narrower than the
/// trace itself. One trace width (0.127 mm at the default class; 0.1 mm is a
/// hair under it, so a nominal-width trace's corner still cuts) is the floor
/// below which a chamfer stops being copper anyone can see.
const min_chamfer_mm: f64 = 0.1;
/// Widest deviation from a true right angle a chamfer will still cut, as the
/// sine of the corner-angle error — sin(5°). See `isRightAngle`: the cut's own
/// chord is separately required to be octilinear, which is what actually
/// bounds this.
const corner_tol_sin: f64 = 0.0871557;
/// How many times a blocked chamfer halves its cut before the corner is left
/// square. Four halvings reach 1/16 of the arm, well under `min_chamfer_mm`
/// for any corner worth cutting.
const max_chamfer_halvings: usize = 4;
/// Straight run (mm) a chamfer leaves at a PAD TERMINAL before its 45° cut may
/// start. The corner NEXT to a pad used to be refused outright, which on a real
/// board meant refusing nearly every corner there is: a decoupling hookup
/// leaves the maze as pad → axis escape → one perpendicular run → pad, three
/// points whose single corner is adjacent to BOTH ends, so the square corner a
/// reader sees on every short hookup was the one the chamfer could never reach
/// (measured on straps-synth-lmx2595: 13 of its 16 right angles sat within
/// 0.35 mm of a pad).
///
/// The reserve replaces that refusal with the rule a hand router follows — the
/// copper leaves its pad straight, then miters — and 0.15 mm is where the two
/// pressures meet. It is a hair over the 0.127 mm default track width, so the
/// neck at the pad is at least as wide as it is long; and it is small enough
/// that an ordinary escape still has a cuttable arm left (a 0402 pad's escape
/// runs 0.34 mm from its centre, a 0.5 mm-pitch QFN pad's 0.51 mm, leaving
/// 0.19 mm and 0.36 mm — both over `min_chamfer_mm`). A shorter arm than the
/// reserve keeps its right angle, which is what a micro-jog deserves.
///
/// The trade this buys is deliberate: a maximal cut may start INSIDE the pad's
/// own land, so the copper leaves through a side edge at 45° instead of square
/// out the end. That is copper drawn on the pad's own solid land — invisible in
/// fab — and every cut is still probed at DRC clearance, so a corner with no
/// room keeps its right angle rather than crowding a neighbour.
const terminal_keep_mm: f64 = 0.15;

/// Points the simplifier may not move copper away from: this net's via centres.
/// A via joins the net's copper on two layers at ONE point, so a stage that
/// drops or chamfers a vertex sitting on a via would leave the via — and every
/// bit of the net hanging off its other layer — stranded off the trace. Chain
/// endpoints never move, so this only matters for a via a same-layer run passes
/// THROUGH (a mid-run stitch); barracuda has seven.
const PinSet = struct {
    pts: []const [2]f64 = &.{},

    fn holds(self: PinSet, p: [2]f64) bool {
        for (self.pts) |q| {
            if (std.math.hypot(q[0] - p[0], q[1] - p[1]) <= pin_snap) return true;
        }
        return false;
    }

    /// Does any vertex strictly inside `pts[i..j]` sit on a via?
    fn inSpan(self: PinSet, pts: []const [2]f64, i: usize, j: usize) bool {
        var k = i + 1;
        while (k < j) : (k += 1) {
            if (self.holds(pts[k])) return true;
        }
        return false;
    }
};

/// A same-net pad terminal of the net being straightened: its world centre
/// plus the unit outward escape axis (part centre → pad centre; {0,0} when the
/// pad offers no direction). The escape gate consults these — a chain end
/// matching no exit is a via or junction, which carries no escape reserve.
pub const PadExit = struct { x: f64, y: f64, out: [2]f64 = .{ 0, 0 } };

/// The fixed points of the net being simplified: its pad terminals (which drive
/// the escape gate) and its via centres (which no stage may move copper off).
/// Both are empty for a net with neither an escape rule nor a via.
pub const Anchors = struct {
    exits: []const PadExit = &.{},
    vias: []const [2]f64 = &.{},
};

/// Simplify one routed net's copper. `net_tracks` is the net's routed segments
/// (the caller gathers them by net index); `probe` answers `clear(layer, a, b)`
/// for a candidate straight segment against the finished board; `anchors`
/// carries the net's fixed points (see `Anchors`). Returns the
/// net's replacement track list (arena-owned) when the polyline changed, or
/// null when nothing did — so the caller leaves the maze copper untouched for
/// every net that does not simplify. Diff-pair legs return null (skipped v1).
pub fn pass(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    net_i: usize,
    net_tracks: []const router.Track,
    anchors: Anchors,
    probe: anytype,
) std.mem.Allocator.Error!?[]const router.Track {
    return passMode(@TypeOf(probe), arena, placement, net_i, net_tracks, .{ .anchors = anchors }, probe);
}

const Mode = enum { octilinear, continuous };
const PassConfig = struct { anchors: Anchors = .{}, mode: Mode = .octilinear };

fn passMode(
    comptime Probe: type,
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    net_i: usize,
    net_tracks: []const router.Track,
    config: PassConfig,
    probe: Probe,
) std.mem.Allocator.Error!?[]const router.Track {
    if (isDiffPairLeg(placement, net_i)) return null;
    const escape_mm = if (net_i < placement.rules.net.len)
        placement.rules.net[net_i].rf.escape_mm
    else
        0;
    var s = Straightener(@TypeOf(probe)){
        .arena = arena,
        .probe = probe,
        .ni = @intCast(net_i),
        .gate = .{ .escape_mm = escape_mm, .exits = config.anchors.exits },
        .pins = .{ .pts = config.anchors.vias },
        .mode = config.mode,
    };
    return s.run(net_tracks);
}

fn isDiffPairLeg(placement: optimizer.Placement, net_i: usize) bool {
    for (placement.diff_pairs) |dp| {
        if (dp.p == net_i or dp.n == net_i) return true;
    }
    return false;
}

/// The escape-reserve gates for one net: its resolved straight-reserve
/// distance plus the net's pad exits. Plain data + pure predicates — the
/// probe-dependent straightening logic lives in `Straightener`.
const EscapeGate = struct {
    escape_mm: f64,
    exits: []const PadExit,

    /// Escape gate for the direct collapse: an escape-ruled chain may go
    /// fully straight only when the single segment still leaves each pad
    /// end along its outward escape axis (within 45°) — then the segment
    /// itself is the straight escape and the reserve holds by construction.
    /// With no exit list the gate refuses (outwardness can't be verified);
    /// the router always supplies exits for escape-ruled nets.
    fn directOk(self: EscapeGate, pts: []const [2]f64) bool {
        if (self.escape_mm <= 0) return true;
        if (self.exits.len == 0) return false;
        const a = pts[0];
        const b = pts[pts.len - 1];
        const d = dist(a, b);
        if (d < eps) return false;
        const dir = [2]f64{ (b[0] - a[0]) / d, (b[1] - a[1]) / d };
        return self.exitAligned(a, dir) and self.exitAligned(b, .{ -dir[0], -dir[1] });
    }

    /// True when leaving point `p` along `dir` stays inside the outward
    /// cone of the pad exit at `p` — or `p` matches no exit (a via or
    /// junction end) or its pad declares no outward axis.
    fn exitAligned(self: EscapeGate, p: [2]f64, dir: [2]f64) bool {
        const exit = self.exitAt(p) orelse return true;
        if (exit.out[0] == 0 and exit.out[1] == 0) return true;
        return dir[0] * exit.out[0] + dir[1] * exit.out[1] >= escape_align_min_dot;
    }

    fn exitAt(self: EscapeGate, p: [2]f64) ?PadExit {
        for (self.exits) |e| {
            if (std.math.hypot(e.x - p[0], e.y - p[1]) <= exit_snap) return e;
        }
        return null;
    }

    /// Is this chain end one of the pad terminals supplied by the board seam?
    /// With no exit list supplied the answer stays conservatively true only for
    /// RF callers that intentionally rely on an authored escape reserve.
    fn isPadEnd(self: EscapeGate, p: [2]f64) bool {
        if (self.exits.len == 0) return self.escape_mm > 0;
        return self.exitAt(p) != null;
    }

    /// Effective escape reserve for this chain (E4). On a short PAD-TO-PAD hop
    /// the full 1 mm reserve at BOTH ends covers the whole ≤2 mm trace, so its
    /// grid micro-jogs could never straighten. Clamp the reserve to a third of
    /// the hop's straight span there, leaving a middle third free while each pad
    /// still exits straight for span/3. Longer hops keep the full reserve
    /// (span/3 ≥ escape_mm); a hop with a non-pad end (via/junction) keeps it
    /// too — the clamp is for genuine 2-pad hops.
    fn effectiveEscape(self: EscapeGate, work: []const [2]f64, both_pads: bool) f64 {
        if (!both_pads) return self.escape_mm;
        const span = dist(work[0], work[work.len - 1]);
        return @min(self.escape_mm, span / 3.0);
    }

    /// True when removing vertex `i` would re-route copper inside a pad
    /// end's straight escape reserve. Dropping `i` replaces the legs
    /// `[i-1,i]` and `[i,i+1]` with `[i-1,i+1]`, so it disturbs the reserve
    /// whenever either neighbour lies within the effective reserve (measured
    /// along the polyline) of a pad end — which also pins the first/last
    /// interior vertex (a neighbour is the pad itself, distance 0), keeping
    /// each pad's outward exit stub intact.
    fn reserved(self: EscapeGate, work: []const [2]f64, i: usize, start_pad: bool, end_pad: bool) bool {
        if (self.escape_mm <= 0) return false;
        const eff = self.effectiveEscape(work, start_pad and end_pad);
        if (start_pad) {
            var to_prev: f64 = 0;
            for (1..i) |k| to_prev += dist(work[k - 1], work[k]);
            if (to_prev < eff) return true;
        }
        if (end_pad) {
            var to_next: f64 = 0;
            for (i + 1..work.len - 1) |k| to_next += dist(work[k], work[k + 1]);
            if (to_next < eff) return true;
        }
        return false;
    }
};

/// One net's straightening state, generic over the caller's clearance probe so
/// the probe rides as a concrete field (no `anytype` threaded through helpers).
fn Straightener(comptime Probe: type) type {
    return struct {
        const Self = @This();
        arena: std.mem.Allocator,
        probe: Probe,
        ni: i32,
        gate: EscapeGate,
        pins: PinSet = .{},
        mode: Mode = .octilinear,
        out: std.ArrayList(router.Track) = .empty,
        changed: bool = false,

        /// `simplifyChain`'s clearance seam: this net's probe pinned to one
        /// layer, so a jog collapse is judged by the same oracle every other
        /// stage of the pass uses.
        const ChainProbe = struct {
            probe: Probe,
            layer: u8,

            /// True when the straight run a→b on this net's layer clears every
            /// foreign pad, via, track, zone and the board outline.
            pub fn segClear(self: ChainProbe, a: [2]f64, b: [2]f64) bool {
                return self.probe.clear(self.layer, a, b);
            }
        };

        fn run(self: *Self, net_tracks: []const router.Track) std.mem.Allocator.Error!?[]const router.Track {
            // Defensive: keep any foreign segment verbatim (there are none in a
            // fresh single-net slice, but the caller replaces `net_tracks`).
            for (net_tracks) |t| {
                if (t.net != self.ni) try self.out.append(self.arena, t);
            }
            // Straighten per (net, layer): `extractChains` connects segments by
            // shared endpoint alone, so copper on either side of a via (a
            // different layer) must not share a graph.
            var layer: u8 = 0;
            const top = maxLayer(net_tracks, self.ni);
            while (true) : (layer += 1) {
                try self.straightenLayer(net_tracks, layer);
                if (layer >= top) break;
            }
            if (!self.changed) return null;
            return try self.out.toOwnedSlice(self.arena);
        }

        /// Extract this (net, layer)'s chains, pull each taut, and append the
        /// result to `out`, flipping `changed` when a chain loses a vertex.
        fn straightenLayer(self: *Self, net_tracks: []const router.Track, layer: u8) std.mem.Allocator.Error!void {
            var segs: std.ArrayList(router.Track) = .empty;
            for (net_tracks) |t| {
                if (t.net != self.ni or t.layer != layer) continue;
                if (segLen(t) < eps) continue; // drop degenerate steps
                try segs.append(self.arena, t);
            }
            if (segs.items.len == 0) return;
            const chains = try bend_smooth.extractChains(self.arena, segs.items);
            const chain_probe = ChainProbe{ .probe = self.probe, .layer = layer };
            for (chains) |raw| {
                const chain = try bend_smooth.simplifyChain(self.arena, raw, chain_probe);
                if (chain.pts.len < 2) continue;
                const width = if (chain.widths.len > 0) chain.widths[0] else segs.items[0].width;
                const taut = try self.straightenPts(chain.pts, layer);
                if (taut.len < chain.pts.len) self.changed = true;
                try emitPolyline(self.arena, &self.out, taut, layer, width, self.ni);
            }
        }

        /// May the whole chain collapse onto its two endpoints? Only when no
        /// via sits on a vertex the collapse would erase, the escape gate
        /// allows it, and the single segment is clear. Lattice mode also keeps
        /// the historical octilinear-heading constraint.
        fn collapsible(self: *Self, pts: []const [2]f64, layer: u8) bool {
            if (self.pins.inSpan(pts, 0, pts.len - 1)) return false;
            if (!self.gate.directOk(pts)) return false;
            const a = pts[0];
            const b = pts[pts.len - 1];
            if (self.mode == .octilinear and !octilinear.isOctilinear(a, b)) return false;
            const ends = [2]bool{ self.gate.isPadEnd(a), self.gate.isPadEnd(b) };
            if ((ends[0] or ends[1]) and !octilinear.isAxisAligned(a, b)) return false;
            return self.probe.clear(layer, a, b);
        }

        /// The taut vertex list for one chain: the two endpoints alone when the
        /// direct segment clears (and, on an escape-ruled net, the single
        /// segment still leaves each pad outward — "the segment IS the escape
        /// line"), else a corner-cut fixpoint that keeps every vertex whose
        /// shortcut is blocked and every vertex inside a pad end's straight
        /// escape reserve. Endpoints never move.
        fn straightenPts(self: *Self, pts: []const [2]f64, layer: u8) std.mem.Allocator.Error![][2]f64 {
            if (pts.len < 3) return self.arena.dupe([2]f64, pts);
            if (self.collapsible(pts, layer)) {
                const two = try self.arena.alloc([2]f64, 2);
                two[0] = pts[0];
                two[1] = pts[pts.len - 1];
                return two;
            }
            const ends = [2]bool{ self.gate.isPadEnd(pts[0]), self.gate.isPadEnd(pts[pts.len - 1]) };
            const work = try self.arena.dupe([2]f64, pts);
            var cc = CornerCutter(Probe){
                .probe = self.probe,
                .gate = self.gate,
                .pins = self.pins,
                .ends = ends,
                .mode = self.mode,
            };
            const cut = work[0..cc.run(work, layer)];
            if (self.mode == .continuous) return self.chamfer(cut, ends, layer);
            return self.reshape(cut, ends, layer);
        }

        /// The two shape stages, in order: re-elbow each surviving staircase,
        /// then chamfer whatever right angles are left. Both share this net's
        /// probe, escape gate and via pins; either one reporting a change makes
        /// the whole pass report one.
        fn reshape(self: *Self, work: [][2]f64, ends: [2]bool, layer: u8) std.mem.Allocator.Error![][2]f64 {
            var re = Reelbower(Probe){
                .arena = self.arena,
                .probe = self.probe,
                .gate = self.gate,
                .pins = self.pins,
                .ends = ends,
            };
            const elbowed = try re.run(work, layer);
            const out = try self.chamfer(elbowed, ends, layer);
            if (re.changed) self.changed = true;
            return out;
        }

        /// Preserve the existing corner discipline after either topology mode:
        /// a continuous pull skips re-elbowing, but a blocked square corner can
        /// still take the same exact-clearance 45-degree cut as lattice copper.
        fn chamfer(self: *Self, work: [][2]f64, ends: [2]bool, layer: u8) std.mem.Allocator.Error![][2]f64 {
            var ch = Chamferer(Probe){
                .arena = self.arena,
                .probe = self.probe,
                .gate = self.gate,
                .pins = self.pins,
                .ends = ends,
            };
            const out = try ch.run(work, layer);
            if (ch.changed) self.changed = true;
            return out;
        }
    };
}

/// The corner-cutting stage of `straightenPts`: repeated forward sweeps, each
/// dropping every interior vertex whose A—C shortcut clears, until a sweep is a
/// no-op. Its own generic type so each stage of the pass reads the same way.
fn CornerCutter(comptime Probe: type) type {
    return struct {
        const Self = @This();
        probe: Probe,
        gate: EscapeGate,
        pins: PinSet,
        /// Whether each chain end is a pad terminal (start, end).
        ends: [2]bool,
        mode: Mode = .octilinear,

        /// Compact `work` in place; returns the surviving prefix length.
        fn run(self: *Self, work: [][2]f64, layer: u8) usize {
            var len = work.len;
            var sweep: usize = 0;
            while (sweep < max_sweeps) : (sweep += 1) {
                var removed = false;
                var i: usize = 1;
                while (i + 1 < len) {
                    if (self.cuttable(work[0..len], i, layer)) {
                        std.mem.copyForwards([2]f64, work[i .. len - 1], work[i + 1 .. len]);
                        len -= 1;
                        removed = true;
                    } else {
                        i += 1;
                    }
                }
                if (!removed) break;
            }
            return len;
        }

        /// May interior vertex `i` be dropped? Only when nothing pins it (a via
        /// sits on it, or it is inside a pad end's straight escape reserve) and
        /// its A—C shortcut is clear. Lattice mode additionally requires an
        /// octilinear replacement; continuous field finish does not.
        fn cuttable(self: *Self, work: []const [2]f64, i: usize, layer: u8) bool {
            if (self.pins.holds(work[i])) return false;
            if ((self.ends[0] and i == 1) or (self.ends[1] and i + 2 == work.len)) return false;
            if (self.gate.reserved(work, i, self.ends[0], self.ends[1])) return false;
            if (self.mode == .octilinear and !octilinear.isOctilinear(work[i - 1], work[i + 1])) return false;
            return self.probe.clear(layer, work[i - 1], work[i + 1]);
        }
    };
}

/// The re-elbow stage of `straightenPts`, split into its own generic type so the
/// staircase rewrite's control flow does not inflate `Straightener`.
///
/// Corner-cutting alone cannot touch a staircase: every A—C shortcut across one
/// is off-axis, and the octilinear gate now refuses those — which is exactly the
/// copper the maze leaves where the turn cost could not buy a straight run (a
/// congested channel, a pad collar). Rewriting the whole run `i..j` as
/// `octilinear.elbows` keeps the discipline (both legs are on-axis by
/// construction) while collapsing dozens of grid steps into two segments.
fn Reelbower(comptime Probe: type) type {
    return struct {
        const Self = @This();
        arena: std.mem.Allocator,
        probe: Probe,
        gate: EscapeGate,
        pins: PinSet,
        /// Whether each chain end is a pad terminal (start, end).
        ends: [2]bool,
        changed: bool = false,

        /// Greedy longest-first: for each start `i` take the farthest `j` whose
        /// elbow clears, then resume the scan at `j`. Endpoints never move, and a
        /// span is skipped when any vertex it would remove sits inside a pad's
        /// escape reserve, so an RF net keeps its straight breakout.
        fn run(self: *Self, pts: [][2]f64, layer: u8) std.mem.Allocator.Error![][2]f64 {
            if (pts.len < 4) return pts;
            var out: std.ArrayList([2]f64) = .empty;
            try out.append(self.arena, pts[0]);
            var i: usize = 0;
            while (i + 1 < pts.len) {
                const hit = self.longestSpan(pts, i, layer);
                if (hit) |h| {
                    if (dist(pts[i], h.mid) > eps) try out.append(self.arena, h.mid);
                    try out.append(self.arena, pts[h.j]);
                    self.changed = true;
                    i = h.j;
                } else {
                    try out.append(self.arena, pts[i + 1]);
                    i += 1;
                }
            }
            return out.toOwnedSlice(self.arena);
        }

        const Span = struct { j: usize, mid: [2]f64 };

        /// The longest span from `i` that collapses to one clearing elbow. Spans
        /// of fewer than three segments are skipped — corner-cutting already
        /// reached those.
        fn longestSpan(self: *Self, pts: []const [2]f64, i: usize, layer: u8) ?Span {
            var j = pts.len - 1;
            while (j >= i + 3) : (j -= 1) {
                if (self.pins.inSpan(pts, i, j)) continue; // a via lives on this run
                if (self.spanReserved(pts, i, j)) continue;
                if (self.elbowFor(pts[i], pts[j], layer)) |mid| return .{ .j = j, .mid = mid };
            }
            return null;
        }

        /// The clearing octilinear elbow between `a` and `b`, or null when
        /// neither candidate fits. An already-octilinear pair reports its
        /// degenerate corner, so the caller emits one straight run.
        fn elbowFor(self: *Self, a: [2]f64, b: [2]f64, layer: u8) ?[2]f64 {
            for (octilinear.elbows(a, b)) |mid| {
                if (dist(a, mid) > eps and !self.probe.clear(layer, a, mid)) continue;
                if (dist(mid, b) > eps and !self.probe.clear(layer, mid, b)) continue;
                return mid;
            }
            return null;
        }

        /// Would collapsing the span `i..j` disturb a pad end's escape reserve?
        fn spanReserved(self: *Self, pts: []const [2]f64, i: usize, j: usize) bool {
            if ((self.ends[0] and i == 0) or (self.ends[1] and j + 1 == pts.len)) return true;
            var k = i + 1;
            while (k < j) : (k += 1) {
                if (self.gate.reserved(pts, k, self.ends[0], self.ends[1])) return true;
            }
            return false;
        }
    };
}

/// True when the arms `v→a` and `v→b` meet at (near enough) a right angle —
/// the corner shape an equal-length cut turns into a 45° diagonal. (Axis+axis
/// cuts to a diagonal; diagonal+diagonal cuts to an axis.)
///
/// The arms themselves are NOT required to be octilinear. A routed corner can
/// sit a degree or two off square when one arm is the join stub onto an
/// off-grid pad centre — barracuda's `I2C_SCL` turns at 92.3° between a
/// −0.90° run and a −88.61° one — and refusing those left square corners on
/// the board for a property that was already lost upstream. What actually has
/// to hold is that the CUT is octilinear, and `Chamferer.cutFor` tests exactly
/// that on the chord itself: the chord's heading depends only on the two arm
/// directions, not on the cut length, so one test settles the whole ladder.
/// That check is also what bounds this tolerance in practice — a corner much
/// further from square than `corner_tol_sin` yields a chord more than 1° off
/// 45° and is refused there anyway.
fn isRightAngle(a: [2]f64, v: [2]f64, b: [2]f64) bool {
    const la = dist(a, v);
    const lb = dist(v, b);
    if (la <= eps or lb <= eps) return false;
    const dot = ((a[0] - v[0]) * (b[0] - v[0]) + (a[1] - v[1]) * (b[1] - v[1])) / (la * lb);
    return @abs(dot) <= corner_tol_sin;
}

/// The point `c` mm from `v` along `v→t`.
fn along(v: [2]f64, t: [2]f64, c: f64) [2]f64 {
    const len = dist(v, t);
    if (len <= eps) return v;
    return .{ v[0] + (t[0] - v[0]) / len * c, v[1] + (t[1] - v[1]) / len * c };
}

/// The chamfer stage of `straightenPts`, and the last one to run.
///
/// A RIGHT-ANGLE corner is the one shape the earlier stages cannot touch. The
/// A—C shortcut across it is off-axis unless its two arms happen to be exactly
/// equal in length, so corner-cutting's octilinear gate refuses it; and the
/// re-elbow stage only rewrites spans of three segments or more, which a lone
/// corner is not. So every 90° turn the maze leaves survives untouched onto the
/// finished board — which is what a reviewer sees, and what a fabricator's
/// etchant pools in.
///
/// Cutting the corner with a 45° diagonal restores the bend discipline without
/// moving the route: the two runs keep their headings and positions, and only
/// the tip is replaced. The cut is MAXIMAL by default (`c = min(arm)`), which
/// for a one-grid-step jog between two long runs consumes the short arm
/// entirely and turns the whole Z into a single clean diagonal — the shape a
/// human draws. When the diagonal is blocked the cut halves until it fits, so a
/// corner in a tight channel still gets whatever 45° it has room for instead of
/// nothing. Each cut is probed at DRC clearance like every other stage, and it
/// only ever REMOVES copper from the corner tip, so it cannot break the net.
fn Chamferer(comptime Probe: type) type {
    return struct {
        const Self = @This();
        arena: std.mem.Allocator,
        probe: Probe,
        gate: EscapeGate,
        pins: PinSet,
        /// Whether each chain end is a pad terminal (start, end).
        ends: [2]bool,
        changed: bool = false,

        const Cut = struct { p1: [2]f64, p2: [2]f64, c: f64 };

        /// Walk the interior vertices once, replacing each right angle with its
        /// largest clearing cut. Endpoints never move.
        fn run(self: *Self, pts: [][2]f64, layer: u8) std.mem.Allocator.Error![][2]f64 {
            if (pts.len < 3) return pts;
            var out: std.ArrayList([2]f64) = .empty;
            try self.push(&out, pts[0]);
            // How much of the arm ARRIVING at the current vertex the previous
            // corner's cut already ate. Two adjacent maximal chamfers sharing a
            // short arm would otherwise overrun each other and cross.
            var eaten: f64 = 0;
            var i: usize = 1;
            while (i + 1 < pts.len) : (i += 1) {
                if (self.cutFor(pts, i, eaten, layer)) |cut| {
                    try self.push(&out, cut.p1);
                    try self.push(&out, cut.p2);
                    eaten = cut.c;
                    self.changed = true;
                } else {
                    try self.push(&out, pts[i]);
                    eaten = 0;
                }
            }
            try self.push(&out, pts[pts.len - 1]);
            return out.toOwnedSlice(self.arena);
        }

        /// Append `p` unless it repeats the last point — a maximal cut lands
        /// exactly on a neighbouring vertex, which the next step re-emits.
        fn push(self: *Self, out: *std.ArrayList([2]f64), p: [2]f64) std.mem.Allocator.Error!void {
            if (out.items.len > 0 and dist(out.items[out.items.len - 1], p) <= eps) return;
            try out.append(self.arena, p);
        }

        /// The largest clearing cut at vertex `i`, or null to leave it square.
        /// `eaten` is how much of the arriving arm the previous cut consumed.
        fn cutFor(self: *Self, pts: []const [2]f64, i: usize, eaten: f64, layer: u8) ?Cut {
            const a = pts[i - 1];
            const v = pts[i];
            const b = pts[i + 1];
            if (self.pins.holds(v)) return null; // a via sits on this corner
            if (self.gate.reserved(pts, i, self.ends[0], self.ends[1])) return null;
            if (!isRightAngle(a, v, b)) return null;
            var c = @min(dist(a, v) - eaten, dist(v, b));
            // A corner adjacent to a PAD terminal keeps `terminal_keep_mm` of
            // that arm straight, so the copper always leaves its pad on one
            // heading before the miter starts (see the constant).
            if (self.ends[0] and i == 1) c = @min(c, dist(a, v) - terminal_keep_mm);
            if (self.ends[1] and i + 2 == pts.len) c = @min(c, dist(v, b) - terminal_keep_mm);
            if (c <= 0) return null;
            // The chord's HEADING is the same for every cut length (it is fixed
            // by the two arm directions alone), so one octilinear test settles
            // the whole ladder — and it is the test that keeps the discipline:
            // a corner too far from square to yield a 45° chord is refused here
            // however clear it is (see `isRightAngle`).
            if (c > eps and !octilinear.isOctilinear(along(v, a, c), along(v, b, c))) return null;
            var tries: usize = 0;
            while (tries <= max_chamfer_halvings) : (tries += 1) {
                if (c < min_chamfer_mm) return null;
                const p1 = along(v, a, c);
                const p2 = along(v, b, c);
                if (self.probe.clear(layer, p1, p2)) return .{ .p1 = p1, .p2 = p2, .c = c };
                c /= 2;
            }
            return null;
        }
    };
}

fn emitPolyline(
    arena: std.mem.Allocator,
    out: *std.ArrayList(router.Track),
    pts: []const [2]f64,
    layer: u8,
    width: f64,
    net: i32,
) std.mem.Allocator.Error!void {
    for (1..pts.len) |k| {
        if (dist(pts[k - 1], pts[k]) < eps) continue;
        try out.append(arena, .{
            .x1 = pts[k - 1][0],
            .y1 = pts[k - 1][1],
            .x2 = pts[k][0],
            .y2 = pts[k][1],
            .layer = layer,
            .width = width,
            .net = net,
        });
    }
}

fn maxLayer(net_tracks: []const router.Track, ni: i32) u8 {
    var m: u8 = 0;
    for (net_tracks) |t| {
        if (t.net == ni and t.layer > m) m = t.layer;
    }
    return m;
}

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

fn segLen(t: router.Track) f64 {
    return std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
}

// ── Board seams: where the router hands whole boards and single hops in ─────

/// The live routing context a gloss probes against. `router.Ctx` is deliberately
/// unexported, so it is named here off the handle the router already publishes
/// rather than by widening the router's API (the `route_cleanup` precedent).
const Ctx = @FieldType(router.CleanupBoard, "ctx");

/// Post-route taut/straighten pass over a WHOLE finished board — pull each
/// routed signal net's copper straight (see the module header). A board routed
/// through continuous field space accepts exact-clearance off-axis chords;
/// lattice-directed boards retain the historical octilinear result. It runs after
/// rip-up and the escape/stitch post-passes, so nothing routes afterward: a
/// taut off-grid segment can never be crowded by a later grid route (the inline
/// straighten's grid-vs-off-grid clearance gap), and every replacement is
/// probed at DRC clearance against the complete copper — so the pass can only
/// hold trace count flat or reduce it, never add a DRC violation. A
/// `(max-freq …)` net straightens too (its chord fans collapse back to taut
/// legs) and then gets its arcs rebuilt on the simplified polyline
/// (`rearcTautNet`); its default 1 mm escape reserve gates both stages via the
/// net's pad exits. Diff-pair legs are skipped (inside `pass`).
pub fn passBoard(board: router.CleanupBoard) std.mem.Allocator.Error!void {
    const ctx = board.ctx;
    const placement = board.placement;
    const tracks = board.tracks;
    const vias = board.vias;
    const mode: Mode = if (ctx.field_space != null) .continuous else .octilinear;
    var idx_of = std.StringHashMapUnmanaged(usize).empty;
    for (placement.parts, 0..) |p, i| try idx_of.put(ctx.arena, p.ref_des, i);
    // The authored bypass bonds that are CLOSED as this pass begins. Straighten
    // is transactional about them: it tautens the rail like any other net and
    // then asks whether the bond still closes, rather than holding the leg's
    // chain rigid while the copper around it moves — see `bypass_intent`.
    const legs = try bypass_intent.build(ctx.arena, placement, router.Track, tracks.items);
    for (0..placement.nets.len) |net_i| {
        // A scoped route's unselected nets carry the caller's RETAINED copper
        // (`stampExistingCopper`), which must echo back unchanged — never
        // straightened into a different board than the caller submitted.
        if (!netSelected(ctx.selected_nets, net_i)) continue;
        const ni: i32 = @intCast(net_i);
        router.setNetParams(ctx, placement, net_i); // the probe reads this net's width/clearance
        // `route_cleanup.removeNetTracks` below SHIFTS the track list indexes
        // (middle removal), which would alias every subsequent probe's index
        // lookup — and the probe reads this net's params — so refresh the
        // index here, after both `setNetParams` and any removal.
        router.rebuildCopperIndex(ctx, tracks.items, vias.items);
        var mine: std.ArrayList(router.Track) = .empty;
        for (tracks.items) |t| if (t.net == ni) try mine.append(ctx.arena, t);
        if (mine.items.len == 0) continue;
        const exits = try padExits(ctx, placement, &idx_of, net_i);
        var pins: std.ArrayList([2]f64) = .empty;
        for (vias.items) |v| if (v.net == ni) try pins.append(ctx.arena, .{ v.x, v.y });
        const probe = router.TautProbe{ .run = .{ .ctx = ctx, .net = ni, .tracks = tracks, .vias = vias } };
        const anchors = Anchors{ .exits = exits, .vias = pins.items };
        const taut = (try passMode(router.TautProbe, ctx.arena, placement, net_i, mine.items, .{ .anchors = anchors, .mode = mode }, probe)) orelse continue;
        // Inline RF smoothing already chose the largest DRC-clear bend radius.
        // Keep that quality as part of this pass's transaction: a shorter
        // centreline is not an improvement when re-arcing it would tighten a
        // clean RF bend or turn it into an under-floor bend. This is exactly
        // the late "large U becomes a small U" failure — the maze/timeline
        // showed the desired copper, then finish-time gloss silently traded
        // radius for length.
        const before_smooth = ctx.rf.net_smooth.get(ni);
        const before_radius = if (before_smooth) |s| minimumBendRadius(s.arcs, s.sharp) else null;
        const before_sharp = if (before_smooth) |s| s.sharp.len else 0;
        route_cleanup.removeNetTracks(tracks, ni);
        const keep = tracks.items.len;
        try tracks.appendSlice(ctx.arena, taut);
        // The pack-down aliased every copper-index entry, and `rearcTautNet`
        // probes the board again for this net's arcs — restamp before it does
        // rather than let it judge chords against copper that moved slots.
        router.rebuildCopperIndex(ctx, tracks.items, vias.items);
        try rearcTautNet(ctx, placement, net_i, keep, tracks, vias);
        const after_smooth = ctx.rf.net_smooth.get(ni);
        const after_radius = if (after_smooth) |s| minimumBendRadius(s.arcs, s.sharp) else null;
        const after_sharp = if (after_smooth) |s| s.sharp.len else 0;
        // Two ways this rewrite is refused: it traded a clean RF bend radius
        // for length, or it pulled an authored cap-to-pin bypass leg off its
        // exact IC land. Either puts the net back exactly as it arrived.
        const opened_bond = !try legs.stillCloses(ctx.arena, placement, router.Track, tracks.items);
        if (opened_bond or bendQualityRegressed(before_radius, before_sharp, after_radius, after_sharp)) {
            route_cleanup.removeNetTracks(tracks, ni);
            try tracks.appendSlice(ctx.arena, mine.items);
            if (before_smooth) |s|
                try ctx.rf.net_smooth.put(ctx.arena, ni, s)
            else
                _ = ctx.rf.net_smooth.remove(ni);
            router.rebuildCopperIndex(ctx, tracks.items, vias.items);
        }
    }
}

/// The smallest true radius represented by one net's arc metadata. A straight
/// net has no radius to preserve (`null`), while a multi-bend RF run is judged
/// by its tightest bend.
fn minimumArcRadius(arcs: []const router.Arc) ?f64 {
    var out: ?f64 = null;
    for (arcs) |arc| {
        const ab = dist(arc.p1, arc.pm);
        const bc = dist(arc.pm, arc.p2);
        const ac = dist(arc.p1, arc.p2);
        const area2 = @abs(
            (arc.pm[0] - arc.p1[0]) * (arc.p2[1] - arc.p1[1]) -
                (arc.pm[1] - arc.p1[1]) * (arc.p2[0] - arc.p1[0]),
        );
        if (area2 <= eps) continue;
        const radius = ab * bc * ac / (2 * area2);
        if (!std.math.isFinite(radius) or radius <= 0) continue;
        out = if (out) |old| @min(old, radius) else radius;
    }
    return out;
}

/// Include unresolved sharp-bend estimates in the achieved-radius floor. This
/// matters when both versions miss the RF target: finish may still preserve the
/// visibly gentler pre-finish U instead of replacing it with an even tighter U.
fn minimumBendRadius(arcs: []const router.Arc, sharp: []const router.SharpBend) ?f64 {
    var out = minimumArcRadius(arcs);
    for (sharp) |bend| {
        if (!std.math.isFinite(bend.radius) or bend.radius < 0) continue;
        out = if (out) |old| @min(old, bend.radius) else bend.radius;
    }
    return out;
}

/// Whether finish-time re-arcing made an RF route worse. A straightened route
/// with no bends is always acceptable; otherwise gloss may hold or enlarge a
/// radius, never tighten it. The tolerance only absorbs three-point float
/// reconstruction noise.
fn bendQualityRegressed(
    before_radius: ?f64,
    before_sharp: usize,
    after_radius: ?f64,
    after_sharp: usize,
) bool {
    if (after_sharp > before_sharp) return true;
    const before = before_radius orelse return false;
    const after = after_radius orelse return false;
    return after + 1e-4 < before;
}

/// Is this net in the route's scope? An empty selection means "every net".
fn netSelected(selected: []const bool, net_i: usize) bool {
    return selected.len == 0 or (net_i < selected.len and selected[net_i]);
}

/// One finishing hop as `glossHop` needs it: the routing context and placement
/// it was routed against, which net it carries, the hop's own copper, and the
/// live board it landed on (`board.tracks` already has the ripped copper taken
/// out, so the gloss is judged against the metal that will actually be there).
pub const HopGloss = struct {
    ctx: Ctx,
    placement: optimizer.Placement,
    net: i32,
    hop: router.GapPath,
    board: router.GapBoard,
};

/// Gloss ONE finishing hop's copper, returning the hop with its polyline
/// simplified (or unchanged when nothing simplifies).
///
/// The maze walk-back is the LATTICE APPROXIMATION of the line it wants: a
/// shallow-angle span comes out as dozens of alternating one-cell steps, and a
/// whole-board route hands exactly that shape to `passBoard` at finish. A
/// finishing hop never reaches that pass — `router.closeGaps` runs long after
/// it — so without this seam the copper a nearly-finished board GAINS is the
/// only copper on it that keeps its staircases and square corners. (Measured on
/// barracuda: every staircase in the banked board came from this path; a fresh
/// whole-board route has none.)
///
/// The probe is the same `TautProbe` the whole-board pass uses, pointed at the
/// live board PLUS this hop, so same-net metal is free and every foreign pad,
/// via, track, zone and the outline are judged at DRC clearance. The hop's
/// endpoints never move, so the hop stays exactly as connected as it was
/// routed; the caller's accept gate then judges it as before.
pub fn glossHop(g: HopGloss) std.mem.Allocator.Error!?router.GapPath {
    if (g.hop.tracks.len < 2) return g.hop;
    const arena = g.ctx.arena;
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.appendSlice(arena, g.board.tracks);
    try tracks.appendSlice(arena, g.hop.tracks);
    var vias: std.ArrayList(router.Via) = .empty;
    try vias.appendSlice(arena, g.board.vias);
    try vias.appendSlice(arena, g.hop.vias);
    const probe = router.TautProbe{ .run = .{ .ctx = g.ctx, .net = g.net, .tracks = &tracks, .vias = &vias } };
    return .{
        .tracks = try glossHopTracks(arena, g.placement, g.net, g.hop.tracks, vias.items, probe),
        .vias = g.hop.vias,
        .ripped = g.hop.ripped,
        .ripped_nets = g.hop.ripped_nets,
    };
}

/// The hop's copper, simplified — or the hop's own copper verbatim when nothing
/// simplifies. Split out of `glossHop` so the geometry can be exercised against
/// a plain probe instead of a live routing context; `vias` is every via on the
/// board, of which this net's are pinned so no stage moves copper off one.
fn glossHopTracks(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    net: i32,
    hop_tracks: []const router.Track,
    vias: []const router.Via,
    probe: anytype,
) std.mem.Allocator.Error![]const router.Track {
    var pins: std.ArrayList([2]f64) = .empty;
    for (vias) |v| if (v.net == net) try pins.append(arena, .{ v.x, v.y });
    const taut = try pass(arena, placement, @intCast(net), hop_tracks, .{ .vias = pins.items }, probe);
    return taut orelse hop_tracks;
}

/// The net's pad terminals as `PadExit`s (world centre + outward escape axis).
/// Every net supplies them: authored escape distance controls the long reserve,
/// while ordinary nets use the same anchors to preserve their first H/V leg.
fn padExits(
    ctx: Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    net_i: usize,
) std.mem.Allocator.Error![]const PadExit {
    const pts = try router.netPoints(ctx.arena, placement, idx_of, placement.nets[net_i]);
    const exits = try ctx.arena.alloc(PadExit, pts.len);
    for (pts, exits) |pt, *e| e.* = .{ .x = pt.x, .y = pt.y, .out = pt.out };
    return exits;
}

/// Rebuild a just-straightened `(max-freq …)` net's arcs on its taut polyline:
/// re-run the bend smoother over `tracks[keep..]` (the net's fresh copper),
/// re-tessellate the arcs into chords, and refresh the net's `net_smooth`
/// metadata so the router gathers arcs consistent with the final copper.
/// A no-op for unconstrained nets.
fn rearcTautNet(
    ctx: Ctx,
    placement: optimizer.Placement,
    net_i: usize,
    keep: usize,
    tracks: *std.ArrayList(router.Track),
    vias: *std.ArrayList(router.Via),
) std.mem.Allocator.Error!void {
    const rule: ?optimizer.NetRule =
        if (net_i < placement.rules.net.len) placement.rules.net[net_i] else null;
    if (bend_smooth.minBendRadius(rule, ctx.base.track_width) <= 0) return;
    const ni: i32 = @intCast(net_i);
    // The arcs about to be drawn are judged through the router's own oracle —
    // which reads the exact-clearance copper index, and `removeNetTracks` above
    // shifted every index in it. Rebuild before probing anything.
    router.rebuildCopperIndex(ctx, tracks.items, vias.items);
    const taut = router.TautProbe{
        .run = .{ .ctx = ctx, .net = ni, .tracks = tracks, .vias = vias },
    };
    const res = try bend_smooth.apply(ctx.arena, .{
        .placement = placement,
        .params = ctx.params,
        .tracks = tracks.items,
        .vias = vias.items,
        .keep = keep,
        .ext = bend_smooth.ExtProbe.bind(router.TautProbe, &taut, ni),
    });
    if (!res.changed) return;
    tracks.shrinkRetainingCapacity(keep);
    try tracks.appendSlice(ctx.arena, res.tracks[keep..]);
    for (res.arcs) |arc| {
        const chords = try bend_smooth.tessellate(ctx.arena, arc, bend_smooth.emit_sagitta_mm);
        try tracks.appendSlice(ctx.arena, chords);
    }
    if (res.arcs.len == 0 and res.sharp.len == 0) {
        _ = ctx.rf.net_smooth.remove(ni);
    } else {
        try ctx.rf.net_smooth.put(ctx.arena, ni, .{ .arcs = res.arcs, .sharp = res.sharp });
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A probe that clears every candidate — exercises the direct-first path.
const AllClear = struct {
    fn clear(_: @This(), _: u8, _: [2]f64, _: [2]f64) bool {
        return true;
    }
};

/// A probe that vetoes any segment passing within `r` of the point (ox, oy),
/// sampled finely — a stand-in for foreign copper in the corner elbow.
const BlockNear = struct {
    ox: f64,
    oy: f64,
    r: f64,
    fn clear(self: @This(), _: u8, a: [2]f64, b: [2]f64) bool {
        const steps: usize = 40;
        for (0..steps + 1) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps));
            const x = a[0] + t * (b[0] - a[0]);
            const y = a[1] + t * (b[1] - a[1]);
            if (std.math.hypot(x - self.ox, y - self.oy) < self.r) return false;
        }
        return true;
    }
};

/// A probe that vetoes any segment passing within `r` of ANY listed point —
/// used to block a specific set of candidate shapes (e.g. both whole-span elbow
/// variants) while leaving a smaller local cut clear.
const BlockNearAny = struct {
    pts: []const [2]f64,
    r: f64,
    fn clear(self: @This(), _: u8, a: [2]f64, b: [2]f64) bool {
        const steps: usize = 40;
        for (0..steps + 1) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(steps));
            const x = a[0] + t * (b[0] - a[0]);
            const y = a[1] + t * (b[1] - a[1]);
            for (self.pts) |p| {
                if (std.math.hypot(x - p[0], y - p[1]) < self.r) return false;
            }
        }
        return true;
    }
};

fn fixture(diff: []const diff_pairs.DiffPair, rules: []const optimizer.NetRule) optimizer.Placement {
    var p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
    p.rules.net = rules;
    p.diff_pairs = diff;
    return p;
}

fn seg(x1: f64, y1: f64, x2: f64, y2: f64) router.Track {
    return .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .layer = 0, .width = 0.2, .net = 0 };
}

// spec: placement/straighten - the straighten pass collapses an unobstructed multi-segment hop to one direct segment
test "unobstructed hop collapses to a single direct segment" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // A two-leg zigzag between two pads at the same y — a straight line exists
    // (the IF1_MIX shape). Direct-first collapses it to one segment.
    const tracks = [_]router.Track{ seg(0, 0, 1, 0.3), seg(1, 0.3, 2, 0) };
    const res = (try pass(arena, placement, 0, &tracks, .{}, AllClear{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 1), res.len);
    try testing.expectApproxEqAbs(0.0, res[0].x1, 1e-9);
    try testing.expectApproxEqAbs(2.0, res[0].x2, 1e-9);
    try testing.expectApproxEqAbs(0.0, res[0].y2, 1e-9);
}

// spec: placement/straighten - the straighten pass corner-cuts a removable staircase vertex and keeps one whose shortcut is blocked
test "corner-cut removes a clear vertex and keeps a blocked one" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // One right-angle jog, as the maze emits it. The A—C shortcut across the
    // corner is the 45° diagonal (0,0)-(1,1) — octilinear, so the gate admits
    // it and the vertex's fate is decided purely by clearance. Two vertices
    // only, so the re-elbow stage (spans of 3+ segments) cannot interfere.
    const tracks = [_]router.Track{ seg(0, 0, 1, 0), seg(1, 0, 1, 1) };
    // Clear: the corner is cut and the hop becomes the single diagonal.
    const cut = (try pass(arena, placement, 0, &tracks, .{}, AllClear{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 1), cut.len);
    try testing.expectApproxEqAbs(1.0, cut[0].x2, 1e-9);
    try testing.expectApproxEqAbs(1.0, cut[0].y2, 1e-9);
    // Blocked mid-diagonal: the corner is NOT cut away — the copper still turns
    // at (1,0) rather than collapsing to the blocked through-diagonal. The
    // chamfer stage then trims the square tip with the largest cut that fits.
    const kept = (try pass(arena, placement, 0, &tracks, .{}, BlockNear{ .ox = 0.5, .oy = 0.5, .r = 0.2 })) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 3), kept.len);
    for (kept) |t| {
        try testing.expect(octilinear.isOctilinear(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }));
        // Nothing runs the blocked (0,0)-(1,1) through-line.
        try testing.expect(!(@abs(t.x1) < 1e-9 and @abs(t.y1) < 1e-9 and @abs(t.x2 - 1) < 1e-9));
    }
    try testing.expectApproxEqAbs(1.0, kept[kept.len - 1].x2, 1e-9);
    try testing.expectApproxEqAbs(1.0, kept[kept.len - 1].y2, 1e-9);
}

// spec: placement/straighten - the straighten pass refuses a shortcut that would leave the octilinear headings
test "an off-axis shortcut is refused even when it is completely clear" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // The same jog, but the far leg is twice as long, so the A—C shortcut
    // (0,0)-(2,1) sits at ~26.6°. Nothing blocks it — under the old taut rule
    // it would collapse to that one arbitrary-angle segment. The octilinear
    // gate refuses it, so what comes out is the chamfered corner (an axis run
    // then a 45° diagonal) and never the 26.6° line.
    const tracks = [_]router.Track{ seg(0, 0, 2, 0), seg(2, 0, 2, 1) };
    const res = (try pass(arena, placement, 0, &tracks, .{}, AllClear{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 2), res.len);
    for (res) |t| try testing.expect(octilinear.isOctilinear(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }));
    // Endpoints never move, so the off-axis span is spent on two legal headings.
    try testing.expectApproxEqAbs(0.0, res[0].x1, 1e-9);
    try testing.expectApproxEqAbs(0.0, res[0].y1, 1e-9);
    try testing.expectApproxEqAbs(2.0, res[1].x2, 1e-9);
    try testing.expectApproxEqAbs(1.0, res[1].y2, 1e-9);
}

// spec: placement/router - field-directed finish accepts exact-clearance continuous shortcuts instead of retaining octilinear quantization detours
test "continuous field gloss accepts a clear off-axis shortcut" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    const tracks = [_]router.Track{ seg(0, 0, 2, 0), seg(2, 0, 2, 1) };
    const res = (try passMode(AllClear, arena, placement, 0, &tracks, .{ .mode = .continuous }, .{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 1), res.len);
    try testing.expect(!octilinear.isOctilinear(.{ res[0].x1, res[0].y1 }, .{ res[0].x2, res[0].y2 }));
    try testing.expectApproxEqAbs(std.math.sqrt(5.0), segLen(res[0]), 1e-9);
}

// spec: placement/straighten - ordinary pad anchors keep their horizontal or vertical terminal legs through every simplification stage
test "plain pad terminal legs survive straighten" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    const tracks = [_]router.Track{
        seg(0, 0, 0.5, 0),
        seg(0.5, 0, 2.5, 2),
        seg(2.5, 2, 3, 2),
    };
    const exits = [_]PadExit{
        .{ .x = 0, .y = 0, .out = .{ 1, 0 } },
        .{ .x = 3, .y = 2, .out = .{ -1, 0 } },
    };
    const changed = try pass(arena, placement, 0, &tracks, .{ .exits = &exits }, AllClear{});
    const kept = changed orelse &tracks;
    try testing.expect(octilinear.isAxisAligned(.{ kept[0].x1, kept[0].y1 }, .{ kept[0].x2, kept[0].y2 }));
    const last = kept[kept.len - 1];
    try testing.expect(octilinear.isAxisAligned(.{ last.x1, last.y1 }, .{ last.x2, last.y2 }));
}

// spec: placement/straighten - the re-elbow stage rewrites a surviving staircase as a two-segment octilinear elbow
test "re-elbow collapses a grid staircase to two octilinear segments" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // A staircase climbing a 2:1 slope from (0,0) to (4,2) — exactly the copper
    // the maze leaves when a turn cost cannot buy a straight run. Its endpoints
    // are off-axis, so the direct collapse is refused, and every A—C shortcut
    // across it is off-axis too, so corner-cutting is powerless. Only the
    // re-elbow stage, spanning the whole run, can simplify this.
    const tracks = [_]router.Track{
        seg(0, 0, 2, 0), seg(2, 0, 2, 1),
        seg(2, 1, 4, 1), seg(4, 1, 4, 2),
    };
    const res = (try pass(arena, placement, 0, &tracks, .{}, AllClear{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 2), res.len);
    for (res) |t| try testing.expect(octilinear.isOctilinear(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }));
    // Endpoints are preserved — connectivity never moves.
    try testing.expectApproxEqAbs(0.0, res[0].x1, 1e-9);
    try testing.expectApproxEqAbs(0.0, res[0].y1, 1e-9);
    try testing.expectApproxEqAbs(4.0, res[1].x2, 1e-9);
    try testing.expectApproxEqAbs(2.0, res[1].y2, 1e-9);
}

// spec: placement/straighten - the straighten pass keeps an escape-ruled net's near-pad vertex inside the straight reserve
test "escape reserve keeps a near-pad vertex when the direct span is blocked" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const escape_rule = optimizer.NetRule{ .width = 0.2, .rf = .{ .escape_mm = 1.0 } };
    const placement = fixture(&.{}, &.{escape_rule});
    // The path leaves the pad straight up 1.5 mm (the escape reserve is 1.0 mm),
    // jogs right, up, then right to the far pad. The jog's shortcut
    // (0,1.5)-(1,2.5) is the 45° diagonal, so the octilinear gate admits it and
    // only the RESERVE decides: it pins the (0,1.5) exit stub and the far pad's
    // own last leg, so just the interior (1,1.5) jog vertex is cut — the pad
    // still exits straight up.
    const tracks = [_]router.Track{
        seg(0, 0, 0, 1.5),
        seg(0, 1.5, 1, 1.5),
        seg(1, 1.5, 1, 2.5),
        seg(1, 2.5, 3, 2.5),
    };
    const res = (try pass(arena, placement, 0, &tracks, .{}, AllClear{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 3), res.len);
    // The reserve keeps (0,1.5): the copper still leaves the pad straight up.
    try testing.expectApproxEqAbs(0.0, res[0].x1, 1e-9);
    try testing.expectApproxEqAbs(0.0, res[0].x2, 1e-9);
    try testing.expectApproxEqAbs(1.5, res[0].y2, 1e-9);
    // The interior (1,1.5) jog was straightened out.
    for (res) |t| try testing.expect(!(@abs(t.x1 - 1) < 1e-6 and @abs(t.y1 - 1.5) < 1e-6));
}

// spec: placement/straighten - an escape-ruled net goes fully straight only when the direct line leaves both pads outward
test "escape-aligned direct line collapses; a sideways one stays put" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const escape_rule = optimizer.NetRule{ .width = 0.2, .rf = .{ .escape_mm = 1.0 } };
    const placement = fixture(&.{}, &.{escape_rule});
    // The IF1_MIX shape: two facing pads, a shallow maze dip between them.
    const tracks = [_]router.Track{ seg(0, 0, 1, 0.3), seg(1, 0.3, 2, 0) };
    // Facing outward axes: the direct line IS each pad's straight escape, so
    // the whole hop collapses to one segment.
    const facing = [_]PadExit{
        .{ .x = 0, .y = 0, .out = .{ 1, 0 } },
        .{ .x = 2, .y = 0, .out = .{ -1, 0 } },
    };
    const res = (try pass(arena, placement, 0, &tracks, .{ .exits = &facing }, AllClear{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 1), res.len);
    try testing.expectApproxEqAbs(0.0, res[0].y1, 1e-9);
    try testing.expectApproxEqAbs(0.0, res[0].y2, 1e-9);
    // Perpendicular outward axes: the direct line would leave both pads
    // sideways, so the collapse is refused and the reserve pins every vertex
    // of this short chain — the copper stays exactly as routed (null).
    const sideways = [_]PadExit{
        .{ .x = 0, .y = 0, .out = .{ 0, 1 } },
        .{ .x = 2, .y = 0, .out = .{ 0, 1 } },
    };
    try testing.expect((try pass(arena, placement, 0, &tracks, .{ .exits = &sideways }, AllClear{})) == null);
}

// spec: placement/straighten - the straighten pass leaves a diff-pair leg untouched
test "a diff-pair leg is skipped" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pairs = [_]diff_pairs.DiffPair{.{ .p = 0, .n = 1, .gap = 0.2 }};
    const placement = fixture(&pairs, &.{ .{ .width = 0.2 }, .{ .width = 0.2 } });
    const tracks = [_]router.Track{ seg(0, 0, 1, 0.3), seg(1, 0.3, 2, 0) };
    // Net 0 is a diff-pair leg → skipped (null) even though it would straighten.
    try testing.expect((try pass(arena, placement, 0, &tracks, .{}, AllClear{})) == null);
}

// spec: placement/straighten - clamps the escape reserve to a third of a short hop so its middle jog straightens
test "escape reserve clamps to a third of a short hop so its middle jog straightens" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const escape_rule = optimizer.NetRule{ .width = 0.2, .rf = .{ .escape_mm = 1.0 } };
    const placement = fixture(&.{}, &.{escape_rule});
    // A 1.5 mm pad-to-pad hop (span 1.5) with a middle micro-jog at (0.75,0.15).
    // The full 1 mm reserve at both ends spans the whole hop and would pin every
    // vertex (returns null); clamped to span/3 (0.5 mm) the middle third is free,
    // so the apex straightens while each pad keeps a straight exit stub.
    const tracks = [_]router.Track{
        seg(0, 0, 0.55, 0),
        seg(0.55, 0, 0.75, 0.15),
        seg(0.75, 0.15, 0.95, 0),
        seg(0.95, 0, 1.5, 0),
    };
    const res = (try pass(arena, placement, 0, &tracks, .{}, AllClear{})) orelse
        return testing.expect(false);
    // The apex is gone: no surviving vertex sits at (0.75,0.15).
    for (res) |t| {
        try testing.expect(!(@abs(t.x1 - 0.75) < 1e-6 and @abs(t.y1 - 0.15) < 1e-6));
        try testing.expect(!(@abs(t.x2 - 0.75) < 1e-6 and @abs(t.y2 - 0.15) < 1e-6));
    }
    // Each pad still exits straight along the hop axis (near-pad vertices kept).
    try testing.expectApproxEqAbs(0.0, res[0].y1, 1e-9);
    try testing.expectApproxEqAbs(0.0, res[0].y2, 1e-9);
}

// spec: placement/straighten - the chamfer stage cuts a surviving right-angle corner with the largest clearing 45 degree diagonal
test "chamfer turns a one-step Z jog into a single 45 degree diagonal" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // V_1V8A's shape: a long run, a single grid-step jog, another long run.
    // Direct collapse is off-axis (dx 7.47, dy 0.44) and every A—C shortcut is
    // off-axis too, so stages 1–2 are powerless. The re-elbow stage CAN span
    // the whole run — but only by moving the bend to one end, and here both of
    // its two elbow corners are blocked (the congested-channel case that leaves
    // these corners square on a real board). Only the chamfer reaches it, and
    // the maximal cut eats the whole 0.44 jog, leaving one clean diagonal.
    const tracks = [_]router.Track{
        seg(0, 0, 4.394, 0),
        seg(4.394, 0, 4.394, 0.439),
        seg(4.394, 0.439, 7.470, 0.439),
    };
    const elbow_corners = [_][2]f64{ .{ 7.031, 0 }, .{ 0.439, 0.439 } };
    const blocked = BlockNearAny{ .pts = &elbow_corners, .r = 0.2 };
    const res = (try pass(arena, placement, 0, &tracks, .{}, blocked)) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 3), res.len);
    for (res) |t| {
        try testing.expect(octilinear.isOctilinear(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }));
        // The square corner at (4.394, 0) is gone — no segment starts there.
        try testing.expect(!(@abs(t.x1 - 4.394) < 1e-6 and @abs(t.y1) < 1e-6));
    }
    try testing.expectApproxEqAbs(@as(f64, 3.955), res[0].x2, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.0), res[0].y2, 1e-9);
    const jog = res[1];
    try testing.expectApproxEqAbs(@abs(jog.x2 - jog.x1), @abs(jog.y2 - jog.y1), 1e-9);
    // Endpoints never move.
    try testing.expectApproxEqAbs(@as(f64, 0.0), res[0].x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 7.470), res[res.len - 1].x2, 1e-6);
}

// spec: placement/straighten - the chamfer cuts the corner next to a pad terminal but keeps a straight run leaving that pad, and refuses an arm shorter than the reserve
test "a pad-adjacent corner is chamfered down to the terminal reserve" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // The shape of every short hookup: a pad, its 0.5 mm axis escape, one
    // perpendicular run, the next pad. Its ONE corner is adjacent to both ends,
    // which is exactly the corner the pass used to refuse outright.
    const tracks = [_]router.Track{ seg(0, 0, 0, -0.5), seg(0, -0.5, 2, -0.5) };
    const exits = [_]PadExit{
        .{ .x = 0, .y = 0, .out = .{ 0, -1 } },
        .{ .x = 2, .y = -0.5, .out = .{ 1, 0 } },
    };
    const res = (try pass(arena, placement, 0, &tracks, .{ .exits = &exits }, AllClear{})) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 3), res.len);
    // The copper still leaves the pad straight, for exactly the reserve…
    try testing.expectApproxEqAbs(@as(f64, 0.0), res[0].x2, 1e-9);
    try testing.expectApproxEqAbs(-terminal_keep_mm, res[0].y2, 1e-9);
    // …and the square corner at (0, -0.5) is now a 45° diagonal.
    try testing.expectApproxEqAbs(@abs(res[1].x2 - res[1].x1), @abs(res[1].y2 - res[1].y1), 1e-9);
    // Endpoints never move.
    try testing.expectApproxEqAbs(@as(f64, 0.0), res[0].y1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.0), res[res.len - 1].x2, 1e-9);
    // An escape shorter than the reserve has nothing left to cut, so that
    // corner keeps its right angle rather than starting the miter on the pad.
    const tight = [_]router.Track{ seg(0, 0, 0, -0.12), seg(0, -0.12, 2, -0.12) };
    try testing.expect((try pass(arena, placement, 0, &tight, .{ .exits = &exits }, AllClear{})) == null);
}

// spec: placement/straighten - the chamfer stage halves a blocked corner cut until it fits and leaves the corner square when none does
test "a blocked chamfer shrinks to fit and a fully blocked one stays square" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // A lone right angle with 2 mm arms. Maximal cut is the diagonal
    // (0,2)-(2,0); an obstacle at its midpoint (1,1) blocks that and the
    // halved cut, so the surviving chamfer is a smaller diagonal near (2,2).
    const tracks = [_]router.Track{ seg(0, 2, 2, 2), seg(2, 2, 2, 0) };
    const res = (try pass(arena, placement, 0, &tracks, .{}, BlockNear{ .ox = 1.35, .oy = 1.35, .r = 0.6 })) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 3), res.len);
    for (res) |t| try testing.expect(octilinear.isOctilinear(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }));
    // The cut had to shrink: it is strictly smaller than the 2 mm arms.
    const cut = 2.0 - res[0].x2;
    try testing.expect(cut > 0 and cut < 2.0);
    // An obstacle hugging the corner blocks every cut → the corner stays square.
    try testing.expect((try pass(arena, placement, 0, &tracks, .{}, BlockNear{ .ox = 2, .oy = 2, .r = 1.9 })) == null);
}

// spec: placement/straighten - no simplifier stage moves copper off a via the net's run passes through
test "a via pinned mid-run keeps its vertex through every stage" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // A right angle whose vertex carries a mid-run stitch via. Unpinned, the
    // chamfer would cut it away and strand the via's other-layer copper.
    const tracks = [_]router.Track{ seg(0, 1, 1, 1), seg(1, 1, 1, 0) };
    const pinned = [_][2]f64{.{ 1, 1 }};
    try testing.expect((try pass(arena, placement, 0, &tracks, .{ .vias = &pinned }, AllClear{})) == null);
    // Without the pin the same corner is cut, so the pin is what saved it.
    try testing.expect((try pass(arena, placement, 0, &tracks, .{}, AllClear{})) != null);
}

// spec: placement/straighten - the straighten pass returns null when a net has no removable corner so the router keeps its maze copper
test "an already-straight net returns null" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // One collinear run (already straight): no corner to remove → null, so the
    // caller keeps the maze copper and its occupancy untouched.
    const tracks = [_]router.Track{ seg(0, 0, 1, 0), seg(1, 0, 2, 0) };
    try testing.expect((try pass(arena, placement, 0, &tracks, .{}, AllClear{})) == null);
}

/// The shape a finishing hop actually comes back from the maze as: `steps`
/// alternating one-cell moves (an axis step then a diagonal step) climbing a
/// shallow slope, exactly like barracuda's `V_22V` bridge on B.Cu — 22 segments
/// of 0.127 mm and 0.180 mm covering a ~3.3 mm span at ~24°.
fn latticeStaircase(arena: std.mem.Allocator, cell: f64, steps: usize) std.mem.Allocator.Error![]router.Track {
    var out: std.ArrayList(router.Track) = .empty;
    var p = [2]f64{ 0, 0 };
    for (0..steps) |k| {
        const q: [2]f64 = if (k % 2 == 0)
            .{ p[0] + cell, p[1] }
        else
            .{ p[0] + cell, p[1] + cell };
        try out.append(arena, seg(p[0], p[1], q[0], q[1]));
        p = q;
    }
    return out.toOwnedSlice(arena);
}

// spec: placement/straighten - a finishing hop's lattice staircase is glossed to one 45 degree diagonal plus one axis run
test "a finishing hop's lattice staircase glosses to a diagonal plus an axis run" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.127 }});
    const stair = try latticeStaircase(arena, 0.127, 22);
    try testing.expectEqual(@as(usize, 22), stair.len);
    const out = try glossHopTracks(arena, placement, 0, stair, &.{}, AllClear{});
    // The octilinear ideal of a monotone staircase: ONE 45° diagonal and ONE
    // axis run — never the 22 micro-segments the maze walked back.
    try testing.expectEqual(@as(usize, 2), out.len);
    for (out) |t| try testing.expect(octilinear.isOctilinear(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }));
    // Endpoints are exactly the hop's own: a rewritten hop must weld where the
    // maze welded, or the net comes back open by a micro-gap.
    try testing.expectApproxEqAbs(stair[0].x1, out[0].x1, 1e-12);
    try testing.expectApproxEqAbs(stair[0].y1, out[0].y1, 1e-12);
    try testing.expectApproxEqAbs(stair[stair.len - 1].x2, out[out.len - 1].x2, 1e-12);
    try testing.expectApproxEqAbs(stair[stair.len - 1].y2, out[out.len - 1].y2, 1e-12);
    // …and exactly one of the two legs is a true 45° diagonal.
    try testing.expectEqual(@as(usize, 1), diagonalCount(out));
}

/// How many of `tracks` run at a true 45° (equal |dx| and |dy|, non-degenerate).
fn diagonalCount(tracks: []const router.Track) usize {
    var n: usize = 0;
    for (tracks) |t| {
        if (@abs(@abs(t.x2 - t.x1) - @abs(t.y2 - t.y1)) < 1e-9 and @abs(t.x2 - t.x1) > eps) n += 1;
    }
    return n;
}

// spec: placement/straighten - the hop gloss keeps a hop's endpoints exactly and hands back a hop with nothing to simplify verbatim
test "the hop gloss returns unsimplifiable hop copper verbatim" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.127 }});
    // One straight run has nothing to collapse: the hop's own copper comes back,
    // so the gap pass's accept gate judges exactly what the maze laid.
    const straight = [_]router.Track{ seg(0, 0, 1, 0), seg(1, 0, 2, 0) };
    const same = try glossHopTracks(arena, placement, 0, &straight, &.{}, AllClear{});
    try testing.expectEqualSlices(router.Track, &straight, same);
    // A staircase whose every shortcut is blocked also comes back reaching just
    // as far — the gloss may refuse, but it can never shorten the hop.
    const stair = try latticeStaircase(arena, 0.127, 8);
    const blocked = BlockNear{ .ox = 0.5, .oy = 0.25, .r = 5.0 };
    const kept = try glossHopTracks(arena, placement, 0, stair, &.{}, blocked);
    try testing.expectApproxEqAbs(stair[0].x1, kept[0].x1, 1e-12);
    try testing.expectApproxEqAbs(stair[stair.len - 1].x2, kept[kept.len - 1].x2, 1e-12);
    try testing.expectApproxEqAbs(stair[stair.len - 1].y2, kept[kept.len - 1].y2, 1e-12);
}

// spec: placement/straighten - the chamfer cuts a corner whose arms sit slightly off-axis, and refuses one whose cut would not be a 45 degree diagonal
test "chamfer cuts a near-square corner but refuses one whose chord is off 45" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.2 }});
    // I2C_SCL's real shape on barracuda: a −0.90° run meeting a −88.61° one, so
    // the corner is 92.3° and NEITHER arm is octilinear — the join stub onto an
    // off-grid pad centre tilted them. The chord of an equal cut is still 45°
    // within a third of a degree, so the corner is cut.
    const near = [_]router.Track{
        seg(0, 0, 1.3926, -0.0218),
        seg(1.3926, -0.0218, 1.4144, -0.9224),
    };
    const cut = (try pass(arena, placement, 0, &near, .{}, AllClear{})) orelse
        return testing.expect(false);
    for (cut) |t| {
        try testing.expect(!(@abs(t.x1 - 1.3926) < 1e-6 and @abs(t.y1 + 0.0218) < 1e-6));
        try testing.expect(!(@abs(t.x2 - 1.3926) < 1e-6 and @abs(t.y2 + 0.0218) < 1e-6));
    }
    // A corner 14° from square yields a chord 7° off 45°, so the chord test
    // refuses it: the discipline is enforced on the CUT, not on a tolerance
    // guess about the arms. Nothing here simplifies, so the pass reports none.
    const skew = [_]router.Track{ seg(0, 0, 1.4, -0.35), seg(1.4, -0.35, 1.4, -1.35) };
    try testing.expect((try pass(arena, placement, 0, &skew, .{}, AllClear{})) == null);
}

// spec: placement/straighten - the chamfer refuses a cut narrower than a trace width rather than spend two vertices on it
test "a sub-trace-width chamfer is refused instead of spending two vertices" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = fixture(&.{}, &.{.{ .width = 0.127 }});
    // A right angle with 0.06 mm arms — below `min_chamfer_mm`, so the maximal
    // cut is already under the floor. Cutting it would spend two vertices on a
    // 45° facet narrower than the trace drawn over it, invisible at fab
    // resolution; the corner is left square and the pass reports no change.
    const tiny = [_]router.Track{ seg(0, 0, 0.06, 0), seg(0.06, 0, 0.06, 0.06) };
    try testing.expect((try pass(arena, placement, 0, &tiny, .{}, AllClear{})) == null);
    // The same corner an order of magnitude larger clears the floor and cuts.
    const big = [_]router.Track{ seg(0, 0, 0.6, 0), seg(0.6, 0, 0.6, 0.6) };
    try testing.expect((try pass(arena, placement, 0, &big, .{}, AllClear{})) != null);
}

// spec: placement/straighten - finish-time RF gloss never trades a clean inline bend for a smaller-radius or under-floor bend
test "rf finish quality gate rejects a tighter re-arc" {
    const wide = [_]router.Arc{.{
        .p1 = .{ -1, 0 },
        .pm = .{ -0.7071067811865476, -0.7071067811865476 },
        .p2 = .{ 0, -1 },
        .layer = 0,
        .width = 0.3,
        .net = 0,
    }};
    const tight = [_]router.Arc{.{
        .p1 = .{ -0.5, 0 },
        .pm = .{ -0.3535533905932738, -0.3535533905932738 },
        .p2 = .{ 0, -0.5 },
        .layer = 0,
        .width = 0.3,
        .net = 0,
    }};
    const wide_radius = minimumArcRadius(&wide).?;
    const tight_radius = minimumArcRadius(&tight).?;
    try testing.expectApproxEqAbs(@as(f64, 1), wide_radius, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), tight_radius, 1e-9);
    try testing.expect(bendQualityRegressed(wide_radius, 0, tight_radius, 0));
    try testing.expect(bendQualityRegressed(wide_radius, 0, wide_radius, 1));
    try testing.expect(!bendQualityRegressed(wide_radius, 0, wide_radius, 0));
    // Even when both candidates remain under-floor, finishing must keep the
    // larger achieved radius instead of making the U visibly tighter.
    try testing.expect(bendQualityRegressed(0.75, 1, 0.25, 1));
    // Removing the bend entirely is a genuine straightening win, not a radius
    // regression, so the existing RF-staircase collapse remains legal.
    try testing.expect(!bendQualityRegressed(wide_radius, 0, null, 0));
}

// spec: placement/router - a max-freq net's routed staircase collapses straight at finish and its arcs rebuild on the taut path
test "rf staircase straightens at finish and drops its stale arcs" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{
            .ref_des = "R1",
            .kind = .passive,
            .hw = 0.3,
            .hh = 0.3,
            .pads = &pad,
            .fallback = false,
            .x = 0,
            .y = 0.19,
        },
        .{
            .ref_des = "R2",
            .kind = .passive,
            .hw = 0.3,
            .hh = 0.3,
            .pads = &pad,
            .fallback = false,
            .x = 4,
            .y = 0.19,
        },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "RF1", .pins = &pins }};
    // Both pads on one horizontal span but off any grid lane: the maze must
    // staircase (stub + run + stub), and inline smoothing may arc those
    // corners. The hop's endpoints ARE octilinear, so the finish-time pass is
    // free to collapse the whole thing to ONE direct segment, after which the
    // re-arc pass finds no corner left — stale arc metadata must go too.
    const rules = [_]optimizer.NetRule{.{ .class = .{ .name = "rf" }, .width = 0.3, .rf = .{ .max_freq_hz = 12e9 } }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1.5,
        .generated = true,
    };
    placement.rules.net = &rules;
    const r = try router.route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.routed);
    try testing.expectEqual(@as(usize, 1), r.tracks.len);
    try testing.expectEqual(@as(usize, 0), r.arcs.len);
    try testing.expectEqual(@as(usize, 0), r.sharp_bends.len);
}
