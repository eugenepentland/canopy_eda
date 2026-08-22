//! Geometric shove primitive — nudge existing copper sideways so a lane opens.
//!
//! The router's conflict resolution can only RIP a net and retry it. It has no
//! way to move copper that is merely *in the way by a tenth of a millimetre*:
//! a net needs a 0.4 mm lane, the gap between two neighbours is 0.3 mm, and one
//! of those neighbours has 0.5 mm of empty board on its far side. A hand router
//! — and KiCad's PNS — pushes that neighbour over and threads the lane. This
//! module is the geometry half of that move.
//!
//! The whole engine is one primitive applied twice: **push a polyline out of the
//! capsule around another polyline**. The requested lane is a capsule (corridor
//! centreline + half-width); a track that was itself shoved is also a capsule
//! (its centreline + half its width). So the lane shove and the cascade shove
//! run the same code, and the cascade is just "the pushed track's own capsule
//! becomes the next round's zone".
//!
//! What a shove is allowed to do:
//!
//!   * **Anchors never move.** A polyline's first and last vertex sit on a pad
//!     or on a via by construction, so they are fixed. Only the interior is
//!     displaced, which is what keeps the net's connectivity intact — no
//!     endpoint is dragged off its pad and no segment is left dangling.
//!   * **Angles survive.** The displaced run is a rigid translation, so its own
//!     corners are unchanged. Each boundary between the fixed part and the
//!     displaced part gains ONE ramp vertex, placed by solving for the shortest
//!     ramp whose segment is still octilinear — a 45° jog where the geometry
//!     allows one, a perpendicular staple where it does not. An input polyline
//!     that was not octilinear to begin with is ramped by arc length instead
//!     and inherits no angle promise.
//!   * **Vias do not move** (v1). A lane blocked by a via is a refusal that
//!     names the via, not a silent partial result. Pads never move at all.
//!   * **Everything is verified.** After the moves are applied, every changed
//!     polyline is re-measured against every pad, via, foreign track, the board
//!     rectangle, and the lane itself. Anything still short is a refusal that
//!     names the binding object and how many millimetres were missing — the
//!     integrator's diagnosis, not a mystery failure.
//!
//! Default is ALL-OR-NOTHING: one refusal and `moved` comes back empty, so a
//! caller can apply the result without checking. `allow_partial` keeps the
//! chains that did succeed (a chain = one seed track plus everything it
//! cascaded into), and drops any chain that hit a refusal — never a half-applied
//! cascade.
//!
//! Pure: plain data in, deterministic slices out. No routing context, no RNG,
//! no clock, no disk; one allocator in, everything allocated from it. The same
//! `Scene` + `Request` always produce byte-identical geometry.

const std = @import("std");
const pad_shape = @import("pad_shape.zig");
const numeric = @import("../numeric.zig");

const Allocator = std.mem.Allocator;

/// Coordinate comparison floor (mm²-free): below this two positions are one.
const eps: f64 = 1e-9;
/// Arc-length step the intrusion scan walks a polyline at. Matches the 0.05 mm
/// sampling `pad_shape.segmentDist` and the DRC pass use, so what this module
/// calls "too close" is what the DRC verifier calls "too close".
const sample_mm: f64 = 0.05;
/// Hard cap on samples per polyline, so a pathological input stays bounded.
const max_samples: usize = 65_536;
/// Extra arc length the displaced run extends past the measured intrusion, so
/// the ramp starts from copper that was already clear.
const guard_mm: f64 = 0.05;
/// Relative tolerance for calling a direction octilinear.
const octi_tol: f64 = 1e-6;
/// Slack allowed when re-measuring a clearance that was solved for exactly.
const verify_tol: f64 = 1e-6;
/// Rebuild attempts allowed while converging the displacement onto the zone.
const push_refine_iters: usize = 6;
/// Largest displacement a single shove will attempt (mm). Past this the copper
/// is not being nudged, it is being re-routed — which is the caller's job.
const max_push_mm: f64 = 12.0;

/// The eight octilinear unit directions, spelled exactly so a snapped direction
/// stays bit-clean (a `@cos`/`@sin` round trip leaves 6e-17 where 0 belongs and
/// silently breaks every downstream octilinearity check).
const octi_dirs = [8][2]f64{
    .{ 1, 0 },
    .{ std.math.sqrt1_2, std.math.sqrt1_2 },
    .{ 0, 1 },
    .{ -std.math.sqrt1_2, std.math.sqrt1_2 },
    .{ -1, 0 },
    .{ -std.math.sqrt1_2, -std.math.sqrt1_2 },
    .{ 0, -1 },
    .{ std.math.sqrt1_2, -std.math.sqrt1_2 },
};

// ── Public input records ───────────────────────────────────────────────────

/// One routed run of copper: a centreline polyline on one layer, plus the net
/// and trace width that give it its clearance envelope. The first and last
/// point are ANCHORS (a pad or a via) and are never moved.
pub const Polyline = struct {
    pts: []const [2]f64,
    net: i32,
    layer: u8 = 0,
    width: f64,
};

/// An immovable pad. `box` is `{x0, y0, x1, y1}` in world mm; `poly` is the
/// exact copper outline for a non-rectangular pad (empty ⇒ the box is exact),
/// the same broad-phase/exact-phase split `pad_shape` uses. `ref` is carried
/// only so a refusal can name the pad a human will have to look at.
pub const Pad = struct {
    box: [4]f64,
    poly: []const [2]f64 = &.{},
    net: i32,
    layer: u8 = 0,
    thru: bool = false,
    ref: []const u8 = "",
};

/// An immovable via. Present on every copper layer, so it obstructs regardless
/// of `Request.layer`.
pub const Via = struct {
    x: f64,
    y: f64,
    dia: f64,
    net: i32,
    drill: f64 = 0,
};

/// One net's routing geometry: the trace width it is drawn at and the clearance
/// it demands from foreign copper. Between two nets the WIDER clearance rule
/// wins, which is the same arbitration the router and DRC apply.
pub const Rule = struct {
    net: i32,
    width: f64,
    clearance: f64,
};

/// The working set the shove reasons over. Everything except `copper` is
/// immovable. `board` is the usable rectangle `{x0, y0, x1, y1}` — the outline
/// ALREADY inset by whatever edge clearance applies — and a displaced
/// centreline must stay inside it by its own half width.
pub const Scene = struct {
    copper: []const Polyline,
    vias: []const Via = &.{},
    pads: []const Pad = &.{},
    rules: []const Rule = &.{},
    /// Width/clearance for a net with no `rules` entry (`net` is ignored).
    default_rule: Rule = .{ .net = 0, .width = 0.127, .clearance = 0.127 },
    board: [4]f64 = .{
        -std.math.inf(f64),
        -std.math.inf(f64),
        std.math.inf(f64),
        std.math.inf(f64),
    },
};

/// "Open a lane of this width along this corridor on this layer."
///
/// The corridor is a polyline centreline; the lane is every point within
/// `half_width` of it. A one-point corridor is a disc and a two-point corridor
/// is a capsule, so the simpler "displace everything foreign out of region R"
/// request is spelled as a degenerate corridor rather than a second entry point.
pub const Request = struct {
    corridor: []const [2]f64,
    half_width: f64,
    layer: u8 = 0,
    /// The net the lane is for. Its own copper, pads and vias are not obstacles
    /// to it and are never shoved. `-1` (the default) belongs to no net, so
    /// every object in the scene is foreign.
    net: i32 = -1,
    /// Induced levels allowed: 0 shoves only what the lane touches, 1 also
    /// shoves the neighbours those moves press against, and so on.
    max_cascade: usize = 1,
    /// Keep the chains that succeeded instead of the default all-or-nothing.
    allow_partial: bool = false,
};

// ── Public result records ──────────────────────────────────────────────────

/// What kind of object a refusal is about.
pub const ObjectKind = enum { none, pad, via, track, board_edge, lane };

/// The object that bound a refusal. `index` indexes `Scene.pads` / `Scene.vias`
/// / `Scene.copper` per `kind`; `ref` is the pad's label when there is one.
pub const Blocker = struct {
    kind: ObjectKind = .none,
    index: usize = 0,
    ref: []const u8 = "",
};

/// Why a shove could not be made.
pub const Reason = enum {
    /// A foreign via sits in the lane, and v1 never moves a via.
    via_in_lane,
    /// A foreign pad sits in the lane, and pads never move at all.
    pad_in_lane,
    /// The intrusion reaches an endpoint, which is anchored on a pad or via.
    anchor_in_lane,
    /// The track's intruding copper lies on BOTH sides of the corridor, so no
    /// single sideways nudge clears it — this one has to be ripped and rerouted.
    crosses_lane,
    /// The displacement the lane needs leaves the track short of some other
    /// object; `Blocker` names it and `missing_mm` says by how much.
    insufficient_slack,
    /// No angle-preserving ramp exists on the boundary segment.
    no_ramp,
    /// The displacement would push copper outside the board rectangle.
    off_board,
    /// Clearing this needed more induced levels than `Request.max_cascade`.
    cascade_too_deep,
};

/// One refused shove. `track` indexes `Scene.copper`, or is null when the
/// refusal is about the lane itself rather than about moving any one track.
pub const Refusal = struct {
    track: ?usize = null,
    reason: Reason,
    blocker: Blocker = .{},
    /// Millimetres of clearance still missing (0 when the reason is structural).
    missing_mm: f64 = 0,
    /// Cascade level the refusal arose at.
    level: usize = 0,
};

/// One displaced track: the FULL replacement polyline, keyed by its index in
/// `Scene.copper`. The caller swaps the whole run rather than patching points.
pub const Moved = struct {
    index: usize,
    pts: []const [2]f64,
    /// Perpendicular displacement applied to the run (mm).
    displacement_mm: f64,
    /// 0 when the lane itself pushed it; N when it was pushed by a track that
    /// was pushed at level N-1.
    level: usize = 0,
};

/// The outcome. `achieved` is true only when the lane came out clear AND
/// nothing was refused. `slack_used_mm` is the largest single displacement
/// applied — how deep into the board's spare room this cost.
pub const Result = struct {
    moved: []const Moved = &.{},
    refusals: []const Refusal = &.{},
    achieved: bool = false,
    slack_used_mm: f64 = 0,
    cascade_depth: usize = 0,
};

// ── Entry point ────────────────────────────────────────────────────────────

/// Open a lane of `req.half_width` along `req.corridor` by displacing the
/// foreign copper in the way. Deterministic: the same `scene`/`req` always
/// produce byte-identical output. Everything returned is allocated from
/// `arena` and borrows nothing mutable from `scene`.
pub fn shove(arena: Allocator, scene: Scene, req: Request) Allocator.Error!Result {
    var st = try State.over(arena, scene, req);
    try st.blockedByFixed();
    try st.runLevels();
    try st.verifyMoved();
    return st.finish();
}

// ── Engine ─────────────────────────────────────────────────────────────────

/// One copper index's live state: the polyline as it currently stands plus,
/// once displaced, the bookkeeping a `Moved` record is built from.
const Slot = struct {
    pts: []const [2]f64,
    moved: bool = false,
    level: usize = 0,
    disp: f64 = 0,
    dir: [2]f64 = .{ 0, 0 },
    /// The seed track whose shove this one descends from (itself, for a seed).
    chain: usize = 0,
};

/// A scheduled shove: displace `idx` out of the capsule `zone`/`half` belonging
/// to `other_net`, along `dir`.
const Pend = struct {
    idx: usize,
    chain: usize,
    zone: []const [2]f64,
    half: f64,
    other_net: i32,
    dir: [2]f64,
};

const State = struct {
    arena: Allocator,
    scene: Scene,
    req: Request,
    slot: []Slot,
    refusals: std.ArrayList(Refusal),
    depth: usize = 0,

    /// A fresh engine over `scene`, with every copper index parked at its
    /// input geometry.
    fn over(arena: Allocator, scene: Scene, req: Request) Allocator.Error!State {
        const slots = try arena.alloc(Slot, scene.copper.len);
        for (slots, scene.copper) |*s, line| s.* = .{ .pts = line.pts };
        return .{
            .arena = arena,
            .scene = scene,
            .req = req,
            .slot = slots,
            .refusals = .empty,
        };
    }

    fn refuse(st: *State, r: Refusal) Allocator.Error!void {
        try st.refusals.append(st.arena, r);
    }

    /// The rule a net routes under.
    fn ruleFor(st: State, net: i32) Rule {
        for (st.scene.rules) |r| {
            if (r.net == net) return r;
        }
        return st.scene.default_rule;
    }

    /// Clearance demanded between two nets: the wider of the two rules.
    fn clearance(st: State, a: i32, b: i32) f64 {
        return @max(st.ruleFor(a).clearance, st.ruleFor(b).clearance);
    }

    /// True when an object on `layer` can obstruct the request's layer.
    fn onLayer(st: State, layer: u8, thru: bool) bool {
        return thru or layer == st.req.layer;
    }

    /// Pads and vias inside the lane: immovable, so each is a refusal.
    fn blockedByFixed(st: *State) Allocator.Error!void {
        if (st.req.corridor.len == 0) return;
        for (st.scene.vias, 0..) |v, i| {
            if (v.net == st.req.net) continue;
            const need = st.req.half_width + v.dia / 2 + st.clearance(v.net, st.req.net);
            if (nearestOnPath(st.req.corridor, .{ v.x, v.y }).d >= need - verify_tol) continue;
            try st.refuse(.{ .reason = .via_in_lane, .blocker = .{ .kind = .via, .index = i } });
        }
        for (st.scene.pads, 0..) |p, i| {
            if (p.net == st.req.net or !st.onLayer(p.layer, p.thru)) continue;
            const need = st.req.half_width + st.clearance(p.net, st.req.net);
            if (padPathDist(p, st.req.corridor) >= need - verify_tol) continue;
            try st.refuse(.{
                .reason = .pad_in_lane,
                .blocker = .{ .kind = .pad, .index = i, .ref = p.ref },
            });
        }
    }

    /// Run the seed level and then each induced level, up to `max_cascade`.
    fn runLevels(st: *State) Allocator.Error!void {
        var pending = try st.seeds();
        var level: usize = 0;
        while (pending.len > 0) {
            if (level > st.req.max_cascade) return st.refuseDeep(pending, level);
            for (pending) |p| try st.shoveOne(p, level);
            if (level > st.depth) st.depth = level;
            pending = try st.induced(level);
            level += 1;
        }
    }

    fn refuseDeep(st: *State, pending: []const Pend, level: usize) Allocator.Error!void {
        for (pending) |p| {
            try st.refuse(.{
                .track = p.idx,
                .reason = .cascade_too_deep,
                .blocker = .{ .kind = .track, .index = p.idx },
                .level = level,
            });
        }
    }

    /// The tracks the lane itself touches, in ascending copper index.
    fn seeds(st: *State) Allocator.Error![]const Pend {
        var out: std.ArrayList(Pend) = .empty;
        if (st.req.corridor.len == 0) return out.toOwnedSlice(st.arena);
        for (st.scene.copper, 0..) |line, i| {
            if (line.net == st.req.net or !st.onLayer(line.layer, false)) continue;
            const need = st.laneNeed(line);
            if (pathPathDist(line.pts, st.req.corridor) >= need - verify_tol) continue;
            try out.append(st.arena, .{
                .idx = i,
                .chain = i,
                .zone = st.req.corridor,
                .half = st.req.half_width,
                .other_net = st.req.net,
                .dir = .{ 0, 0 },
            });
        }
        return out.toOwnedSlice(st.arena);
    }

    /// Centre-to-centre distance `line` must keep from the corridor axis.
    fn laneNeed(st: State, line: Polyline) f64 {
        return st.req.half_width + line.width / 2 + st.clearance(line.net, st.req.net);
    }

    /// Tracks the copper moved at `level` now presses against.
    fn induced(st: *State, level: usize) Allocator.Error![]const Pend {
        var out: std.ArrayList(Pend) = .empty;
        for (st.slot, 0..) |s, i| {
            if (!s.moved or s.level != level) continue;
            const src = st.scene.copper[i];
            for (st.scene.copper, 0..) |line, j| {
                if (j == i or line.net == src.net or st.slot[j].moved) continue;
                if (line.layer != src.layer) continue;
                const need = src.width / 2 + line.width / 2 + st.clearance(src.net, line.net);
                if (pathPathDist(s.pts, st.slot[j].pts) >= need - verify_tol) continue;
                try out.append(st.arena, .{
                    .idx = j,
                    .chain = s.chain,
                    .zone = s.pts,
                    .half = src.width / 2,
                    .other_net = src.net,
                    .dir = s.dir,
                });
            }
        }
        return out.toOwnedSlice(st.arena);
    }

    /// Displace one track out of one capsule, or record why it cannot be.
    fn shoveOne(st: *State, p: Pend, level: usize) Allocator.Error!void {
        const line = st.scene.copper[p.idx];
        const pts = st.slot[p.idx].pts;
        const need = p.half + line.width / 2 + st.clearance(line.net, p.other_net);
        const span = intrusionSpan(pts, p.zone, need) orelse return;
        const dir = st.escapeDir(pts, p, span) orelse
            return st.refuse(.{ .track = p.idx, .reason = .crosses_lane, .level = level });
        if (straddles(pts, p.zone, need, dir))
            return st.refuse(.{ .track = p.idx, .reason = .crosses_lane, .level = level });
        const built = try buildPushed(st.arena, pts, span, p.zone, .{ .need = need, .dir = dir });
        switch (built) {
            .refused => |reason| try st.refuse(.{ .track = p.idx, .reason = reason, .level = level }),
            .ok => |run| try st.commit(p, level, run),
        }
    }

    fn commit(st: *State, p: Pend, level: usize, run: Pushed) Allocator.Error!void {
        if (st.offBoard(p.idx, run.pts)) |edge| {
            return st.refuse(.{
                .track = p.idx,
                .reason = .off_board,
                .blocker = .{ .kind = .board_edge },
                .missing_mm = edge,
                .level = level,
            });
        }
        st.slot[p.idx] = .{
            .pts = run.pts,
            .moved = true,
            .level = level,
            .disp = run.disp,
            .dir = run.dir,
            .chain = p.chain,
        };
    }

    /// The direction to push in: outward from the corridor at the deepest
    /// intrusion, snapped to octilinear when the track itself is octilinear
    /// (a snapped direction is what makes an octilinear ramp possible at all).
    /// Null when the track's deepest point sits ON the axis, which no sideways
    /// nudge can resolve.
    fn escapeDir(st: State, pts: []const [2]f64, p: Pend, span: Span) ?[2]f64 {
        if (lenSq(p.dir) > eps) return p.dir;
        _ = st;
        const deep = pointAtArc(pts, span.deep);
        const e = sub(deep, nearestOnPath(p.zone, deep).at);
        if (lenSq(e) <= eps * eps) return null;
        const unit = scale(e, 1 / @sqrt(lenSq(e)));
        return if (pathIsOcti(pts)) snapOcti(unit) else unit;
    }

    /// How far outside the board rectangle a run's copper would sit, or null.
    fn offBoard(st: State, idx: usize, pts: []const [2]f64) ?f64 {
        const half = st.scene.copper[idx].width / 2;
        const b = st.scene.board;
        var worst: f64 = 0;
        for (pts) |q| {
            worst = @max(worst, b[0] + half - q[0]);
            worst = @max(worst, b[1] + half - q[1]);
            worst = @max(worst, q[0] - (b[2] - half));
            worst = @max(worst, q[1] - (b[3] - half));
        }
        return if (worst > verify_tol) worst else null;
    }

    /// Re-measure every displaced run against the whole scene. This is the
    /// gate: a shove that solved its own zone but broke something else is a
    /// refusal here, never a silently returned move.
    fn verifyMoved(st: *State) Allocator.Error!void {
        for (st.slot, 0..) |s, i| {
            if (!s.moved) continue;
            try st.verifyOne(i, s);
        }
    }

    fn verifyOne(st: *State, i: usize, s: Slot) Allocator.Error!void {
        const line = st.scene.copper[i];
        try st.verifyPads(i, s, line);
        try st.verifyVias(i, s, line);
        try st.verifyCopper(i, s, line);
        if (st.req.corridor.len == 0 or line.net == st.req.net) return;
        const need = st.laneNeed(line);
        const gap = pathPathDist(s.pts, st.req.corridor);
        if (gap >= need - verify_tol) return;
        try st.short(i, s.level, need - gap, .{ .kind = .lane });
    }

    fn verifyPads(st: *State, i: usize, s: Slot, line: Polyline) Allocator.Error!void {
        for (st.scene.pads, 0..) |p, k| {
            if (p.net == line.net or !st.onLayer(p.layer, p.thru)) continue;
            const need = line.width / 2 + st.clearance(p.net, line.net);
            const gap = padPathDist(p, s.pts);
            if (gap >= need - verify_tol) continue;
            try st.short(i, s.level, need - gap, .{ .kind = .pad, .index = k, .ref = p.ref });
        }
    }

    fn verifyVias(st: *State, i: usize, s: Slot, line: Polyline) Allocator.Error!void {
        for (st.scene.vias, 0..) |v, k| {
            if (v.net == line.net) continue;
            const need = line.width / 2 + v.dia / 2 + st.clearance(v.net, line.net);
            const gap = nearestPathPoint(s.pts, .{ v.x, v.y });
            if (gap >= need - verify_tol) continue;
            try st.short(i, s.level, need - gap, .{ .kind = .via, .index = k });
        }
    }

    fn verifyCopper(st: *State, i: usize, s: Slot, line: Polyline) Allocator.Error!void {
        for (st.scene.copper, 0..) |other, j| {
            if (j == i or other.net == line.net or other.layer != line.layer) continue;
            const need = line.width / 2 + other.width / 2 + st.clearance(other.net, line.net);
            const gap = pathPathDist(s.pts, st.slot[j].pts);
            if (gap >= need - verify_tol) continue;
            try st.short(i, s.level, need - gap, .{ .kind = .track, .index = j });
        }
    }

    fn short(st: *State, i: usize, level: usize, missing: f64, b: Blocker) Allocator.Error!void {
        try st.refuse(.{
            .track = i,
            .reason = .insufficient_slack,
            .blocker = b,
            .missing_mm = missing,
            .level = level,
        });
    }

    /// True when the lane still holds foreign copper after the moves.
    fn laneBlocked(st: State) bool {
        if (st.req.corridor.len == 0) return false;
        for (st.slot, st.scene.copper) |s, line| {
            if (line.net == st.req.net or !st.onLayer(line.layer, false)) continue;
            if (pathPathDist(s.pts, st.req.corridor) < st.laneNeed(line) - verify_tol) return true;
        }
        return false;
    }

    /// True when any refusal belongs to `chain` (so the whole chain is dropped
    /// in partial mode — a half-applied cascade is worse than no cascade).
    fn chainRefused(st: State, chain: usize) bool {
        for (st.refusals.items) |r| {
            const idx = r.track orelse return true;
            if (st.slot[idx].chain == chain) return true;
            if (idx == chain) return true;
        }
        return false;
    }

    /// Whether a displaced slot survives into the result: everything survives a
    /// clean run; on a run with refusals only partial mode keeps anything, and
    /// only the chains that were themselves never refused.
    fn kept(st: State, s: Slot, clean: bool) bool {
        if (!s.moved) return false;
        if (clean) return true;
        if (!st.req.allow_partial) return false;
        return !st.chainRefused(s.chain);
    }

    fn finish(st: *State) Allocator.Error!Result {
        const clean = st.refusals.items.len == 0;
        var moved: std.ArrayList(Moved) = .empty;
        var used: f64 = 0;
        for (st.slot, 0..) |s, i| {
            if (!st.kept(s, clean)) continue;
            used = @max(used, s.disp);
            try moved.append(st.arena, .{
                .index = i,
                .pts = s.pts,
                .displacement_mm = s.disp,
                .level = s.level,
            });
        }
        return .{
            .moved = try moved.toOwnedSlice(st.arena),
            .refusals = try st.refusals.toOwnedSlice(st.arena),
            .achieved = clean and !st.laneBlocked(),
            .slack_used_mm = used,
            .cascade_depth = st.depth,
        };
    }
};

// ── Displacement geometry ──────────────────────────────────────────────────

/// The arc-length stretch of a polyline that intrudes a zone, plus where it
/// intrudes deepest (the point whose escape direction is used).
const Span = struct { lo: f64, hi: f64, deep: f64 };

/// What a push is solving for: the centre-to-centre distance to reach and the
/// direction to reach it in.
const Push = struct { need: f64, dir: [2]f64 };

/// A successfully displaced run.
const Pushed = struct { pts: []const [2]f64, disp: f64, dir: [2]f64 };

const Built = union(enum) { ok: Pushed, refused: Reason };

/// The stretch of `pts` closer than `need` to `zone`, widened to its hull so
/// one contiguous run covers a path that weaves in and out. Null when nothing
/// intrudes.
fn intrusionSpan(pts: []const [2]f64, zone: []const [2]f64, need: f64) ?Span {
    const total = pathLen(pts);
    const steps = sampleCount(total);
    var lo: f64 = 0;
    var hi: f64 = 0;
    var deep: f64 = 0;
    var worst = std.math.inf(f64);
    var found = false;
    for (0..steps + 1) |i| {
        const s = total * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const d = nearestOnPath(zone, pointAtArc(pts, s)).d;
        if (d >= need) continue;
        if (!found) lo = s;
        hi = s;
        found = true;
        if (d >= worst) continue;
        worst = d;
        deep = s;
    }
    if (!found) return null;
    return .{ .lo = lo - sample_mm, .hi = hi + sample_mm, .deep = deep };
}

/// True when intruding copper lies on BOTH sides of the zone axis: a track
/// crossing the lane cannot be cleared by any single sideways displacement.
fn straddles(pts: []const [2]f64, zone: []const [2]f64, need: f64, dir: [2]f64) bool {
    const total = pathLen(pts);
    const steps = sampleCount(total);
    for (0..steps + 1) |i| {
        const s = total * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const q = pointAtArc(pts, s);
        const near = nearestOnPath(zone, q);
        if (near.d >= need) continue;
        if (dot(sub(q, near.at), dir) < -eps) return true;
    }
    return false;
}

/// Solve for the smallest displacement along `push.dir` that lifts every
/// intruding sample of `pts` to `push.need` from `zone`, then build the
/// replacement polyline and converge it (the built ramp geometry can sit
/// marginally closer than the sampled solve predicted).
fn buildPushed(
    arena: Allocator,
    pts: []const [2]f64,
    span: Span,
    zone: []const [2]f64,
    push: Push,
) Allocator.Error!Built {
    var t = requiredPush(pts, zone, push);
    const octi = pathIsOcti(pts);
    for (0..push_refine_iters) |_| {
        if (t > max_push_mm) return .{ .refused = .insufficient_slack };
        const out = try shiftRun(arena, pts, span, scale(push.dir, t), octi) orelse
            return .{ .refused = if (span.lo <= guard_mm) .anchor_in_lane else .no_ramp };
        const gap = pathPathDist(out, zone);
        if (gap >= push.need - verify_tol) {
            return .{ .ok = .{ .pts = out, .disp = t, .dir = push.dir } };
        }
        t += push.need - gap;
    }
    return .{ .refused = .insufficient_slack };
}

/// Largest displacement along `push.dir` any sample needs. For a sample at
/// distance `d` from the zone with offset `e` from its nearest axis point,
/// `|e + t·dir| = need` solves to the positive root below — exact where the
/// nearest feature is a segment interior, and refined by the caller otherwise.
fn requiredPush(pts: []const [2]f64, zone: []const [2]f64, push: Push) f64 {
    const total = pathLen(pts);
    const steps = sampleCount(total);
    var t: f64 = 0;
    for (0..steps + 1) |i| {
        const s = total * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const q = pointAtArc(pts, s);
        const near = nearestOnPath(zone, q);
        if (near.d >= push.need) continue;
        const e = sub(q, near.at);
        const b = dot(e, push.dir);
        const disc = b * b - lenSq(e) + push.need * push.need;
        if (disc < 0) continue;
        t = @max(t, -b + @sqrt(disc));
    }
    return t;
}

/// The replacement polyline: everything outside `[span.lo, span.hi]` untouched,
/// everything inside translated by `w`, and one ramp vertex on each boundary
/// segment. Null when the intrusion reaches an anchor (no fixed vertex is left
/// on one side to ramp from).
fn shiftRun(
    arena: Allocator,
    pts: []const [2]f64,
    span: Span,
    w: [2]f64,
    octi: bool,
) Allocator.Error!?[]const [2]f64 {
    if (pts.len < 2) return null;
    const total = pathLen(pts);
    const lo = span.lo - guard_mm;
    const hi = span.hi + guard_mm;
    if (!(lo > eps and hi < total - eps and lo < hi)) return null;
    const k_lo = segAtArc(pts, lo);
    const k_hi = segAtArc(pts, hi);
    const n_lo = pointAtArc(pts, lo);
    const n_hi = pointAtArc(pts, hi);
    var out: std.ArrayList([2]f64) = .empty;
    for (pts[0 .. k_lo + 1]) |q| try appendPt(arena, &out, q);
    try appendPt(arena, &out, rampVertex(pts[k_lo], n_lo, w, octi));
    try appendPt(arena, &out, add(n_lo, w));
    for (pts[k_lo + 1 .. k_hi + 1]) |q| try appendPt(arena, &out, add(q, w));
    try appendPt(arena, &out, add(n_hi, w));
    try appendPt(arena, &out, rampVertex(pts[k_hi + 1], n_hi, w, octi));
    for (pts[k_hi + 1 ..]) |q| try appendPt(arena, &out, q);
    if (out.items.len < 2) return null;
    const done: []const [2]f64 = try out.toOwnedSlice(arena);
    return done;
}

/// Append unless it repeats the previous point (the split points coincide with
/// a real vertex whenever the intrusion happens to start on one).
fn appendPt(arena: Allocator, out: *std.ArrayList([2]f64), q: [2]f64) Allocator.Error!void {
    if (out.items.len > 0 and lenSq(sub(out.items[out.items.len - 1], q)) <= eps * eps) return;
    try out.append(arena, q);
}

/// The ramp vertex on the boundary segment from the fixed vertex `f` to the
/// first displaced vertex's original position `n`. For octilinear copper this
/// is the point that makes the ramp segment itself octilinear — the shortest
/// such point, so the jog is a 45° corner wherever the geometry allows one and
/// a perpendicular staple (`u = 0`, whose ramp vector is `w`, already an
/// octilinear direction) where it does not. Non-octilinear copper ramps back by
/// the rise instead and inherits no angle promise.
fn rampVertex(f: [2]f64, n: [2]f64, w: [2]f64, octi: bool) [2]f64 {
    const v = sub(n, f);
    const len = @sqrt(lenSq(v));
    if (len < eps) return f;
    if (!octi) {
        const back = @min(@sqrt(lenSq(w)), len);
        return sub(n, scale(v, back / len));
    }
    return sub(n, scale(v, rampFraction(v, w) orelse 0));
}

/// The shortest fraction `u` of segment `v` for which `u·v + w` is octilinear
/// — i.e. has a zero component or two components of equal magnitude. Null when
/// no such fraction lies in `(0, 1]`.
fn rampFraction(v: [2]f64, w: [2]f64) ?f64 {
    var best: ?f64 = null;
    if (@abs(v[0]) > eps) keepMin(&best, -w[0] / v[0]);
    if (@abs(v[1]) > eps) keepMin(&best, -w[1] / v[1]);
    if (@abs(v[0] - v[1]) > eps) keepMin(&best, (w[1] - w[0]) / (v[0] - v[1]));
    if (@abs(v[0] + v[1]) > eps) keepMin(&best, -(w[0] + w[1]) / (v[0] + v[1]));
    return best;
}

fn keepMin(best: *?f64, u: f64) void {
    if (u <= eps or u > 1) return;
    if (best.* == null or u < best.*.?) best.* = u;
}

// ── Path primitives ────────────────────────────────────────────────────────

fn sub(a: [2]f64, b: [2]f64) [2]f64 {
    return .{ a[0] - b[0], a[1] - b[1] };
}

fn add(a: [2]f64, b: [2]f64) [2]f64 {
    return .{ a[0] + b[0], a[1] + b[1] };
}

fn scale(a: [2]f64, s: f64) [2]f64 {
    return .{ a[0] * s, a[1] * s };
}

fn dot(a: [2]f64, b: [2]f64) f64 {
    return a[0] * b[0] + a[1] * b[1];
}

fn lenSq(a: [2]f64) f64 {
    return a[0] * a[0] + a[1] * a[1];
}

/// Samples a polyline of length `total` is walked at, at `sample_mm` and
/// bounded by `max_samples`.
fn sampleCount(total: f64) usize {
    const want = numeric.toCount(@ceil(total / sample_mm));
    return std.math.clamp(want, 1, max_samples);
}

fn pathLen(pts: []const [2]f64) f64 {
    var total: f64 = 0;
    for (1..pts.len) |i| total += @sqrt(lenSq(sub(pts[i], pts[i - 1])));
    return total;
}

/// Index of the segment holding arc position `s` (clamped to the last).
fn segAtArc(pts: []const [2]f64, s: f64) usize {
    var acc: f64 = 0;
    for (1..pts.len) |i| {
        const l = @sqrt(lenSq(sub(pts[i], pts[i - 1])));
        if (s <= acc + l) return i - 1;
        acc += l;
    }
    return pts.len - 2;
}

/// The world point at arc position `s` along `pts` (clamped to the ends).
fn pointAtArc(pts: []const [2]f64, s: f64) [2]f64 {
    if (pts.len == 1 or s <= 0) return pts[0];
    var acc: f64 = 0;
    for (1..pts.len) |i| {
        const d = sub(pts[i], pts[i - 1]);
        const l = @sqrt(lenSq(d));
        if (l > eps and s <= acc + l) return add(pts[i - 1], scale(d, (s - acc) / l));
        acc += l;
    }
    return pts[pts.len - 1];
}

/// Nearest point on a polyline to `p`, and the distance to it.
const Near = struct { d: f64, at: [2]f64 };

fn nearestOnPath(path: []const [2]f64, p: [2]f64) Near {
    if (path.len == 0) return .{ .d = std.math.inf(f64), .at = p };
    if (path.len == 1) return .{ .d = @sqrt(lenSq(sub(p, path[0]))), .at = path[0] };
    var best = Near{ .d = std.math.inf(f64), .at = path[0] };
    for (1..path.len) |i| {
        const c = pad_shape.closestOnSeg(path[i - 1][0], path[i - 1][1], path[i][0], path[i][1], p[0], p[1]);
        if (c.d >= best.d) continue;
        best = .{ .d = c.d, .at = .{ c.x, c.y } };
    }
    return best;
}

fn nearestPathPoint(path: []const [2]f64, p: [2]f64) f64 {
    return nearestOnPath(path, p).d;
}

/// Shortest distance between two polylines (0 when they cross).
fn pathPathDist(a: []const [2]f64, b: []const [2]f64) f64 {
    if (a.len == 0 or b.len == 0) return std.math.inf(f64);
    if (a.len == 1) return nearestOnPath(b, a[0]).d;
    var best = std.math.inf(f64);
    for (1..a.len) |i| {
        if (b.len == 1) {
            best = @min(best, pad_shape.segPointDist(a[i - 1][0], a[i - 1][1], a[i][0], a[i][1], b[0][0], b[0][1]));
            continue;
        }
        for (1..b.len) |j| {
            best = @min(best, pad_shape.segSegDist(a[i - 1], a[i], b[j - 1], b[j]));
        }
    }
    return best;
}

/// Shortest distance from a pad's copper to a polyline.
fn padPathDist(p: Pad, path: []const [2]f64) f64 {
    const shape = pad_shape.Shape{
        .x0 = p.box[0],
        .y0 = p.box[1],
        .x1 = p.box[2],
        .y1 = p.box[3],
        .poly = p.poly,
    };
    if (path.len == 1) {
        return pad_shape.pointDist(shape.x0, shape.y0, shape.x1, shape.y1, shape.poly, path[0][0], path[0][1], std.math.inf(f64));
    }
    var best = std.math.inf(f64);
    for (1..path.len) |i| {
        best = @min(best, pad_shape.segmentDist(shape, path[i - 1], path[i], best));
    }
    return best;
}

/// True when a direction is axis-aligned or a true diagonal.
fn isOctiDir(v: [2]f64) bool {
    const ax = @abs(v[0]);
    const ay = @abs(v[1]);
    const m = @max(ax, ay);
    if (m < eps) return true;
    return ax < octi_tol * m or ay < octi_tol * m or @abs(ax - ay) < octi_tol * m;
}

fn pathIsOcti(pts: []const [2]f64) bool {
    for (1..pts.len) |i| {
        if (!isOctiDir(sub(pts[i], pts[i - 1]))) return false;
    }
    return true;
}

/// The octilinear unit direction closest to `v`, taken from the exact table so
/// the result carries no rounding dust.
fn snapOcti(v: [2]f64) [2]f64 {
    var best = octi_dirs[0];
    var score = -std.math.inf(f64);
    for (octi_dirs) |d| {
        const s = dot(v, d);
        if (s <= score) continue;
        score = s;
        best = d;
    }
    return best;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

/// Independent segment-to-segment distance for the test oracle, transcribed
/// from `src/placement/drc.zig`'s `segSegDist` so the assertions do not measure
/// with the same code the module measures with.
fn oracleSegSeg(a1: [2]f64, a2: [2]f64, b1: [2]f64, b2: [2]f64) f64 {
    const d1 = sub(a2, a1);
    const d2 = sub(b2, b1);
    const den = d1[0] * d2[1] - d1[1] * d2[0];
    if (@abs(den) > 1e-12) {
        const t = ((b1[0] - a1[0]) * d2[1] - (b1[1] - a1[1]) * d2[0]) / den;
        const u = ((b1[0] - a1[0]) * d1[1] - (b1[1] - a1[1]) * d1[0]) / den;
        if (t >= 0 and t <= 1 and u >= 0 and u <= 1) return 0;
    }
    var d = oraclePointSeg(a1, a2, b1);
    d = @min(d, oraclePointSeg(a1, a2, b2));
    d = @min(d, oraclePointSeg(b1, b2, a1));
    return @min(d, oraclePointSeg(b1, b2, a2));
}

fn oraclePointSeg(a: [2]f64, b: [2]f64, p: [2]f64) f64 {
    const d = sub(b, a);
    const l2 = lenSq(d);
    if (l2 < 1e-12) return @sqrt(lenSq(sub(p, a)));
    const t = std.math.clamp(dot(sub(p, a), d) / l2, 0, 1);
    return @sqrt(lenSq(sub(p, add(a, scale(d, t)))));
}

/// Oracle distance between two polylines, built from `oracleSegSeg` alone.
fn oracleDist(a: []const [2]f64, b: []const [2]f64) f64 {
    var best = std.math.inf(f64);
    for (1..a.len) |i| {
        for (1..b.len) |j| best = @min(best, oracleSegSeg(a[i - 1], a[i], b[j - 1], b[j]));
    }
    return best;
}

/// The scene every fixture starts from: one horizontal foreign track 0.3 mm
/// above a lane the router wants along y = 5.
const lane_pts = [_][2]f64{ .{ 2, 5 }, .{ 18, 5 } };
const track_a = [_][2]f64{ .{ 0, 5.3 }, .{ 20, 5.3 } };
const base_rules = [_]Rule{
    .{ .net = 1, .width = 0.2, .clearance = 0.15 },
    .{ .net = 2, .width = 0.2, .clearance = 0.15 },
    .{ .net = 3, .width = 0.2, .clearance = 0.15 },
    .{ .net = 4, .width = 0.2, .clearance = 0.15 },
};

fn baseRequest() Request {
    return .{ .corridor = &lane_pts, .half_width = 0.25, .layer = 0, .net = 1 };
}

fn oneTrackScene(copper: []const Polyline) Scene {
    return .{
        .copper = copper,
        .rules = &base_rules,
        .default_rule = .{ .net = 0, .width = 0.2, .clearance = 0.15 },
    };
}

// spec: Shove primitive - a foreign track with slack is displaced the least distance that opens the requested lane
test "a track with slack is displaced minimally and the lane opens" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const copper = [_]Polyline{.{ .pts = &track_a, .net = 2, .width = 0.2 }};
    const res = try shove(arena, oneTrackScene(&copper), baseRequest());

    try testing.expect(res.achieved);
    try testing.expectEqual(@as(usize, 0), res.refusals.len);
    try testing.expectEqual(@as(usize, 1), res.moved.len);
    try testing.expectEqual(@as(usize, 0), res.cascade_depth);
    // need = lane half 0.25 + track half 0.1 + clearance 0.15 = 0.5; the track
    // centreline sits 0.3 away, so 0.2 mm of push is both necessary and enough.
    try testing.expectApproxEqAbs(@as(f64, 0.2), res.moved[0].displacement_mm, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.2), res.slack_used_mm, 1e-6);
    // Oracle: re-measure the replacement run against the corridor independently.
    try testing.expect(oracleDist(res.moved[0].pts, &lane_pts) >= 0.5 - 1e-6);
    // The displaced middle really is 0.2 mm further out, not merely clipped.
    var deepest: f64 = 0;
    for (res.moved[0].pts) |q| deepest = @max(deepest, q[1]);
    try testing.expectApproxEqAbs(@as(f64, 5.5), deepest, 1e-9);
}

// spec: Shove primitive - a track pinned against an immovable pad refuses and names the pad plus the millimetres of clearance it lacked
test "a track pinned by a pad refuses naming the pad and the missing millimetres" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const copper = [_]Polyline{.{ .pts = &track_a, .net = 2, .width = 0.2 }};
    // A pad 0.05 mm past where the pushed centreline lands: the shove needs
    // 0.1 + 0.15 = 0.25 mm of gap and would leave 0.05, so 0.20 mm is missing.
    const pads = [_]Pad{.{ .box = .{ 8, 5.55, 12, 5.95 }, .net = 3, .ref = "U1" }};
    var scene = oneTrackScene(&copper);
    scene.pads = &pads;

    const res = try shove(arena, scene, baseRequest());
    try testing.expect(!res.achieved);
    // All-or-nothing: a refusal anywhere leaves nothing applied.
    try testing.expectEqual(@as(usize, 0), res.moved.len);
    try testing.expectEqual(@as(usize, 1), res.refusals.len);
    const r = res.refusals[0];
    try testing.expectEqual(Reason.insufficient_slack, r.reason);
    try testing.expectEqual(ObjectKind.pad, r.blocker.kind);
    try testing.expectEqualStrings("U1", r.blocker.ref);
    try testing.expectEqual(@as(?usize, 0), r.track);
    try testing.expectApproxEqAbs(@as(f64, 0.20), r.missing_mm, 1e-6);
}

// spec: Shove primitive - a shove that can only clear the lane by pushing its neighbour cascades one level and moves both runs
test "a shove cascades one level and moves both tracks" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const track_b = [_][2]f64{ .{ -2, 5.75 }, .{ 22, 5.75 } };
    const copper = [_]Polyline{
        .{ .pts = &track_a, .net = 2, .width = 0.2 },
        .{ .pts = &track_b, .net = 3, .width = 0.2 },
    };
    const res = try shove(arena, oneTrackScene(&copper), baseRequest());

    try testing.expect(res.achieved);
    try testing.expectEqual(@as(usize, 0), res.refusals.len);
    try testing.expectEqual(@as(usize, 2), res.moved.len);
    try testing.expectEqual(@as(usize, 1), res.cascade_depth);
    try testing.expectEqual(@as(usize, 0), res.moved[0].level);
    try testing.expectEqual(@as(usize, 1), res.moved[1].level);
    // A pushed to 5.5 leaves 0.25 to B, which needs 0.1+0.1+0.15 = 0.35.
    try testing.expectApproxEqAbs(@as(f64, 0.2), res.moved[0].displacement_mm, 1e-6);
    try testing.expectApproxEqAbs(@as(f64, 0.1), res.moved[1].displacement_mm, 1e-6);
    // Oracle: lane clear of A, and A clear of B, measured independently.
    try testing.expect(oracleDist(res.moved[0].pts, &lane_pts) >= 0.5 - 1e-6);
    try testing.expect(oracleDist(res.moved[0].pts, res.moved[1].pts) >= 0.35 - 1e-6);
}

// spec: Shove primitive - a cascade deeper than the requested limit refuses and leaves every run where it was
test "a cascade deeper than the limit refuses and moves nothing" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const track_b = [_][2]f64{ .{ -2, 5.75 }, .{ 22, 5.75 } };
    const track_c = [_][2]f64{ .{ -2, 6.15 }, .{ 22, 6.15 } };
    const copper = [_]Polyline{
        .{ .pts = &track_a, .net = 2, .width = 0.2 },
        .{ .pts = &track_b, .net = 3, .width = 0.2 },
        .{ .pts = &track_c, .net = 4, .width = 0.2 },
    };
    const scene = oneTrackScene(&copper);

    const res = try shove(arena, scene, baseRequest());
    try testing.expect(!res.achieved);
    try testing.expectEqual(@as(usize, 0), res.moved.len);
    try testing.expect(res.refusals.len >= 1);
    try testing.expectEqual(Reason.cascade_too_deep, res.refusals[0].reason);
    try testing.expectEqual(@as(?usize, 2), res.refusals[0].track);
    try testing.expectEqual(@as(usize, 2), res.refusals[0].level);

    // The same board with two levels allowed resolves instead of refusing.
    var deeper = baseRequest();
    deeper.max_cascade = 2;
    const ok = try shove(arena, scene, deeper);
    try testing.expect(ok.achieved);
    try testing.expectEqual(@as(usize, 3), ok.moved.len);
    try testing.expectEqual(@as(usize, 2), ok.cascade_depth);
}

// spec: Shove primitive - a via inside the requested lane refuses and names the via, because v1 never moves a via
test "a via in the lane refuses and names it" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const copper = [_]Polyline{.{ .pts = &track_a, .net = 2, .width = 0.2 }};
    // Sitting 0.15 below the corridor axis: deep inside the lane, but far
    // enough from where the track would be pushed that the via is the ONLY
    // thing refused — the lane simply cannot be opened here.
    const vias = [_]Via{.{ .x = 10, .y = 4.85, .dia = 0.6, .net = 3, .drill = 0.3 }};
    var scene = oneTrackScene(&copper);
    scene.vias = &vias;

    const res = try shove(arena, scene, baseRequest());
    try testing.expect(!res.achieved);
    try testing.expectEqual(@as(usize, 0), res.moved.len);
    try testing.expectEqual(@as(usize, 1), res.refusals.len);
    try testing.expectEqual(Reason.via_in_lane, res.refusals[0].reason);
    try testing.expectEqual(ObjectKind.via, res.refusals[0].blocker.kind);
    try testing.expectEqual(@as(usize, 0), res.refusals[0].blocker.index);
    try testing.expectEqual(@as(?usize, null), res.refusals[0].track);
}

// spec: Shove primitive - a shoved octilinear run stays octilinear and gains no corner sharper than a 45 degree jog
test "a shoved run keeps octilinear segments and gains no acute corner" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const copper = [_]Polyline{.{ .pts = &track_a, .net = 2, .width = 0.2 }};
    const res = try shove(arena, oneTrackScene(&copper), baseRequest());
    try testing.expectEqual(@as(usize, 1), res.moved.len);
    const out = res.moved[0].pts;
    // A straight run gains two ramp vertices and two displaced split points.
    try testing.expectEqual(@as(usize, 6), out.len);

    try expectOctiChain(out);
}

/// Oracle for the angle promise, kept out of the test body so the assertion
/// walk is one pass: every segment is axis-aligned or a true diagonal, and
/// every interior corner turns at most 45 degrees (so none comes out acute).
fn expectOctiChain(out: []const [2]f64) !void {
    for (1..out.len) |i| {
        const d = sub(out[i], out[i - 1]);
        const ax = @abs(d[0]);
        const ay = @abs(d[1]);
        const axis = ax < 1e-9 or ay < 1e-9;
        try testing.expect(axis or @abs(ax - ay) < 1e-9);
        if (i + 1 >= out.len) continue;
        const b = sub(out[i + 1], out[i]);
        const cosang = dot(d, b) / (@sqrt(lenSq(d)) * @sqrt(lenSq(b)));
        try testing.expect(cosang >= std.math.sqrt1_2 - 1e-9);
    }
}

// spec: Shove primitive - a run whose endpoint is anchored on a pad keeps that endpoint at exactly its original coordinates
test "anchored endpoints keep their exact coordinates" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Both ends land on real pads of the track's own net, inside the region.
    const pads = [_]Pad{
        .{ .box = .{ -0.3, 5.0, 0.3, 5.6 }, .net = 2, .ref = "J1" },
        .{ .box = .{ 19.7, 5.0, 20.3, 5.6 }, .net = 2, .ref = "J2" },
    };
    const copper = [_]Polyline{.{ .pts = &track_a, .net = 2, .width = 0.2 }};
    var scene = oneTrackScene(&copper);
    scene.pads = &pads;

    const res = try shove(arena, scene, baseRequest());
    try testing.expectEqual(@as(usize, 1), res.moved.len);
    const out = res.moved[0].pts;
    try testing.expectEqual(track_a[0][0], out[0][0]);
    try testing.expectEqual(track_a[0][1], out[0][1]);
    try testing.expectEqual(track_a[1][0], out[out.len - 1][0]);
    try testing.expectEqual(track_a[1][1], out[out.len - 1][1]);
}

// spec: Shove primitive - the same scene and request run twice produce byte-identical geometry
test "the shove is deterministic across runs" {
    var a1 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a1.deinit();
    var a2 = std.heap.ArenaAllocator.init(testing.allocator);
    defer a2.deinit();

    const track_b = [_][2]f64{ .{ -2, 5.75 }, .{ 22, 5.75 } };
    const copper = [_]Polyline{
        .{ .pts = &track_a, .net = 2, .width = 0.2 },
        .{ .pts = &track_b, .net = 3, .width = 0.2 },
    };
    const scene = oneTrackScene(&copper);
    const first = try shove(a1.allocator(), scene, baseRequest());
    const second = try shove(a2.allocator(), scene, baseRequest());

    try testing.expectEqual(first.moved.len, second.moved.len);
    try testing.expectEqual(first.cascade_depth, second.cascade_depth);
    try testing.expectEqual(first.slack_used_mm, second.slack_used_mm);
    for (first.moved, second.moved) |x, y| {
        try testing.expectEqual(x.index, y.index);
        try testing.expectEqual(x.displacement_mm, y.displacement_mm);
        try testing.expectEqualSlices([2]f64, x.pts, y.pts);
    }
}

// spec: Shove primitive - a displacement that would carry copper outside the board rectangle refuses instead
test "a displacement leaving the board outline refuses" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const copper = [_]Polyline{.{ .pts = &track_a, .net = 2, .width = 0.2 }};
    var scene = oneTrackScene(&copper);
    // Usable board stops at y = 5.45: the track fits where it is (5.3 + 0.1
    // half width = 5.4) but the 0.2 mm push would put its edge at 5.6.
    scene.board = .{ -1, 0, 21, 5.45 };

    const res = try shove(arena, scene, baseRequest());
    try testing.expect(!res.achieved);
    try testing.expectEqual(@as(usize, 0), res.moved.len);
    try testing.expectEqual(@as(usize, 1), res.refusals.len);
    try testing.expectEqual(Reason.off_board, res.refusals[0].reason);
    try testing.expectEqual(ObjectKind.board_edge, res.refusals[0].blocker.kind);
    try testing.expectApproxEqAbs(@as(f64, 0.15), res.refusals[0].missing_mm, 1e-6);
}

// spec: Shove primitive - a track whose intruding copper lies on both sides of the corridor refuses as a crossing rather than being nudged
test "a track crossing the lane refuses instead of being nudged" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const crossing = [_][2]f64{ .{ 10, 3 }, .{ 10, 7 } };
    const copper = [_]Polyline{.{ .pts = &crossing, .net = 2, .width = 0.2 }};
    const res = try shove(arena, oneTrackScene(&copper), baseRequest());

    try testing.expect(!res.achieved);
    try testing.expectEqual(@as(usize, 0), res.moved.len);
    try testing.expectEqual(@as(usize, 1), res.refusals.len);
    try testing.expectEqual(Reason.crosses_lane, res.refusals[0].reason);
}

// spec: Shove primitive - an empty corridor or an empty working set is a no-op that reports the lane already achieved
test "an empty request is an achieved no-op" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var empty = baseRequest();
    empty.corridor = &.{};
    const none = try shove(arena, oneTrackScene(&.{}), empty);
    try testing.expect(none.achieved);
    try testing.expectEqual(@as(usize, 0), none.moved.len);
    try testing.expectEqual(@as(usize, 0), none.refusals.len);

    // A populated scene with no corridor is equally a no-op.
    const copper = [_]Polyline{.{ .pts = &track_a, .net = 2, .width = 0.2 }};
    const quiet = try shove(arena, oneTrackScene(&copper), empty);
    try testing.expect(quiet.achieved);
    try testing.expectEqual(@as(usize, 0), quiet.moved.len);
}

// spec: Shove primitive - partial mode keeps the chains that succeeded and drops every chain that hit a refusal
test "partial mode keeps clean chains and drops refused ones" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two independent intruders: the second is pinned by a pad, the first is free.
    const track_b = [_][2]f64{ .{ 0, 4.7 }, .{ 20, 4.7 } };
    const copper = [_]Polyline{
        .{ .pts = &track_a, .net = 2, .width = 0.2 },
        .{ .pts = &track_b, .net = 3, .width = 0.2 },
    };
    const pads = [_]Pad{.{ .box = .{ 8, 4.05, 12, 4.45 }, .net = 4, .ref = "U9" }};
    var scene = oneTrackScene(&copper);
    scene.pads = &pads;

    var req = baseRequest();
    req.allow_partial = true;
    const res = try shove(arena, scene, req);
    try testing.expect(!res.achieved);
    try testing.expectEqual(@as(usize, 1), res.moved.len);
    try testing.expectEqual(@as(usize, 0), res.moved[0].index);
    try testing.expect(oracleDist(res.moved[0].pts, &lane_pts) >= 0.5 - 1e-6);

    // The default all-or-nothing mode drops it too.
    const strict = try shove(arena, scene, baseRequest());
    try testing.expectEqual(@as(usize, 0), strict.moved.len);
}

// spec: Shove primitive - the ramp fraction picks the shortest octilinear jog and falls back to a perpendicular staple when no jog exists
test "the ramp fraction picks the shortest octilinear jog" {
    // A horizontal run of length 1.55 pushed 0.2 in +y ramps at u = 0.2/1.55,
    // which puts the corner exactly 0.2 back — a 45 degree jog.
    const u = rampFraction(.{ 1.55, 0 }, .{ 0, 0.2 }).?;
    try testing.expectApproxEqAbs(@as(f64, 0.2 / 1.55), u, 1e-12);
    const corner = rampVertex(.{ 0, 5.3 }, .{ 1.55, 5.3 }, .{ 0, 0.2 }, true);
    try testing.expectApproxEqAbs(@as(f64, 1.35), corner[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.3), corner[1], 1e-9);

    // A 45 degree run pushed along its own perpendicular ramps horizontally.
    const diag = rampFraction(.{ 2, 2 }, .{ 0.3, -0.3 }).?;
    try testing.expectApproxEqAbs(@as(f64, 0.15), diag, 1e-12);

    // A push with a component ALONG the run has no forward jog; the staple
    // (u = 0) is used instead, whose ramp vector is the octilinear push itself.
    try testing.expectEqual(@as(?f64, null), rampFraction(.{ 2, 0 }, .{ 0.3, 0.3 }));
    const staple = rampVertex(.{ 0, 0 }, .{ 2, 0 }, .{ 0.3, 0.3 }, true);
    try testing.expectEqual(@as(f64, 2), staple[0]);
    try testing.expectEqual(@as(f64, 0), staple[1]);
}

// spec: Shove primitive - a direction is snapped to the exact octilinear table so a displaced run carries no rounding dust
test "octilinear snapping is exact and classification is scale free" {
    try testing.expectEqual([2]f64{ 0, 1 }, snapOcti(.{ 0.02, 0.99 }));
    try testing.expectEqual([2]f64{ -1, 0 }, snapOcti(.{ -3, 0.01 }));
    try testing.expectEqual([2]f64{ std.math.sqrt1_2, std.math.sqrt1_2 }, snapOcti(.{ 1, 1.02 }));
    try testing.expect(isOctiDir(.{ 0, 4 }));
    try testing.expect(isOctiDir(.{ -2.5, 2.5 }));
    try testing.expect(!isOctiDir(.{ 3, 1 }));
    try testing.expect(pathIsOcti(&track_a));
    const bent = [_][2]f64{ .{ 0, 0 }, .{ 3, 1 } };
    try testing.expect(!pathIsOcti(&bent));
}
