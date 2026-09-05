//! Simultaneous multi-net escape assignment — parallel lanes for a set of nets
//! that all leave the same hub through the same corridor.
//!
//! The router places nets ONE AT A TIME. Each net's maze is greedy over the
//! space left by its predecessors, so where several nets share one narrow
//! escape (board-a: eight SPI/control nets fanning west out of connector
//! `J1`) the early nets take the middle of the channel and the late ones are
//! starved — and no reordering fixes it, because whichever net routes first
//! takes the same lane. A hand router solves it in one move: assign the whole
//! contended set to PARALLEL LANES up front, in the order their endpoints
//! already imply, so nobody has to cross anybody.
//!
//! That is what this module computes, in four steps:
//!
//!   1. **Hub** — the part hosting a pad of the most nets in the set (the
//!      shared origin the escape leaves from), or a caller-named ref.
//!   2. **Corridor** — the direction the set's destinations lie in (a majority
//!      vote over each net's source→destination vector), then a CROSS-SECTION
//!      cut across that direction. The cut is scanned outward from the hub and
//!      the tightest one that still fits every net is chosen: that is the
//!      constriction the assignment has to schedule, and a cut chosen anywhere
//!      looser schedules nothing.
//!   3. **Lanes** — the free intervals along that cut (every other part's
//!      courtyard is an obstacle, the board outline bounds it), sliced at
//!      track-pitch. Each free interval is a **BAND**: a contiguous run of
//!      lanes with nothing in between. A band is thinned to a few more lanes
//!      than the nets scheduled into it, so the assignment spreads across the
//!      band instead of packing every net into one minimum-pitch strip.
//!   4. **Assignment** — each net's IDEAL crossing point (where its straight
//!      source→destination line meets the cut) mapped onto a lane by an exact
//!      O(nets·lanes) dynamic program over MONOTONE assignments: lane order
//!      follows ideal order, so the solution has no crossings by construction,
//!      and among crossing-free solutions it minimises total detour.
//!
//! **The assignment declines rather than exiles.** A corridor's free space is
//! routinely BIMODAL — board-a's eight-net J1 escape offers ten lanes in two
//! bands separated by a 5.9 mm dead gap — and a single monotone program over
//! the flat lane list honours its ordering ACROSS that void: it will drag a net
//! six millimetres into the far band rather than leave the schedule crossed.
//! That is not scheduling, it is a detour dictated to a net that never wanted
//! one, and measured on board-a it cost two nets for the one it bought. So
//! each band is solved as its own capacity-limited sub-corridor over the nets
//! whose ideals land nearest it (monotonicity is preserved WITHIN a band, where
//! it means something — two nets in different bands are separated by an
//! obstacle, so their order can never make them cross), and a net whose lane
//! would sit farther than `displacementCap` from its own ideal is REFUSED: it
//! gets no guide and routes exactly as it does with no form authored. Partial
//! assignment is therefore first-class — `Schedule.unassigned` names who was
//! declined and `Assignment.fit` says why, so a refusal surfaces as a plan
//! warning instead of as copper nobody asked for.
//!
//! The result lowers to SOFT guide tracks (`route_policy.GuideTrack`), never
//! hard waypoints. A guide only multiplies the maze's cost for staying near it
//! (`router.reference_corridor`), so a lane that turns out to be unusable costs
//! the net a detour — never the net. Hard waypoints would fail a two-terminal
//! net outright the moment its dogleg is blocked, which is exactly the
//! brittleness a joint assignment is supposed to remove.
//!
//! **`detect` finds contended fans without the form, and steers nothing.** It
//! turns the machinery above on EVERY hub of a board — for each side, the nets
//! that leave that way against the lanes the tightest cross-section there
//! offers — and reports the fans the corridor cannot seat. No
//! `(assign-escapes …)` is needed, no guide is produced, and no route changes:
//! it is a diagnosis, and `suggestDsl` renders it as the exact one-line wave a
//! human would author to act on it.
//!
//! Detection and steering are split deliberately, on a measurement. On
//! board-a, ANY steering of the eight J1 control escapes scores 81/91 against
//! the 82/91 control — a perfect assignment and a bare wave split with no forms
//! alike. That escape is a knife-edge, so an automatic assignment would spend a
//! routed net to buy a tidier picture. What the geometry can do unattended is
//! say WHERE the contention is; whether to steer it stays an authored decision.
//!
//! Pure: no disk, no globals, one arena in, deterministic slices out.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const route_policy = @import("route_policy.zig");
const plane_stitch = @import("plane_stitch.zig");
const numeric = @import("../numeric.zig");

const Allocator = std.mem.Allocator;

/// Cardinal direction the contended set leaves its hub in. Board axes are
/// y-DOWN (the placement convention), so `north` is −y and `south` is +y.
pub const Direction = enum {
    north,
    south,
    east,
    west,

    /// True when lanes are separated along **y** — i.e. the escape runs along
    /// x, so parallel lanes are horizontal lines at different y.
    pub fn lanesAlongY(self: Direction) bool {
        return self == .east or self == .west;
    }

    /// +1 when escaping toward growing coordinates on the escape axis, −1 the
    /// other way.
    pub fn outward(self: Direction) f64 {
        return if (self == .south or self == .east) 1 else -1;
    }
};

/// The chosen cross-section: where it cuts, how wide it is, the lane pitch, and
/// how far off its own ideal crossing this corridor is willing to move a net.
/// `cut` is on the ESCAPE axis, `lo`/`hi` on the LANE axis.
pub const Corridor = struct {
    dir: Direction = .west,
    cut: f64 = 0,
    lo: f64 = 0,
    hi: f64 = 0,
    pitch: f64 = 0,
    /// The displacement cap, in mm — see `displacementCap`. Zero on a corridor
    /// that was never scheduled (no lanes).
    cap: f64 = 0,
};

/// One candidate lane: its coordinate on the lane axis plus the world point
/// where it meets the cross-section. `band` is which contiguous free interval
/// of the cross-section the lane belongs to — lanes of one band have nothing
/// between them, lanes of different bands have an obstacle.
pub const Lane = struct {
    pos: f64,
    x: f64,
    y: f64,
    band: usize = 0,
};

/// Why a contended net ended up with no lane. Never a failure — a refused net
/// simply routes as it would with no `(assign-escapes …)` authored at all.
pub const Refusal = enum {
    /// The net has a lane.
    none,
    /// Its ideal crossing lies farther than the displacement cap from EVERY
    /// free band of the cross-section — the corridor's free space is simply not
    /// where this net wants to cross, and dragging it there would dictate a
    /// detour rather than schedule it among its peers.
    out_of_band,
    /// A lane was available in the net's own band, but keeping the schedule
    /// crossing-free would have pushed the net farther than the cap.
    displacement_over_cap,
    /// The net's band holds fewer lanes than the nets that want it, and this is
    /// one the monotone program had to drop.
    no_lane,
    /// The net never reached the assignment at all: it has no pad on the hub,
    /// no pad anywhere else, or names a pad the hub's footprint does not carry.
    /// Reported rather than dropped in silence, so a wave that names six nets
    /// and schedules four says so.
    off_hub,
};

/// The hub pad a contended net escapes from: the part, the pad number, and the
/// pad's world centre.
pub const Origin = struct {
    ref: []const u8 = "",
    pad: []const u8 = "",
    at: [2]f64 = .{ 0, 0 },
};

/// How well a net's lane matches what its own endpoints asked for: where it
/// wanted to cross, how far the assignment moved it, and — when that was too
/// far — why the assignment declined instead.
pub const Fit = struct {
    /// Where this net's straight source→destination line meets the cut.
    ideal: f64 = 0,
    /// How far off that crossing the corridor put it (mm): the assigned lane's
    /// distance for an assignment, the gap to the nearest band for an
    /// `out_of_band` refusal, the refused lane's distance for the other two.
    offset: f64 = 0,
    /// Why this net got no lane; `.none` exactly when `Assignment.lane != null`.
    refusal: Refusal = .none,
};

/// One net's place in the assignment. `lane` is null when the assignment
/// declined it; `fit.refusal` then says why.
pub const Assignment = struct {
    net: usize,
    lane: ?usize = null,
    from: Origin = .{},
    /// The lane point, valid only when `lane != null`.
    dst: [2]f64 = .{ 0, 0 },
    fit: Fit = .{},
};

/// The schedule laid over one corridor: the lanes it offered, one entry per
/// contended net, and the subset that got no lane (repeated out of
/// `assignments`, same order, so a caller that only wants the refusals needn't
/// filter).
pub const Schedule = struct {
    lanes: []const Lane = &.{},
    assignments: []const Assignment = &.{},
    unassigned: []const Assignment = &.{},
};

/// The computed assignment. `ok` is false when the set has no shared hub or no
/// usable corridor; `reason` then says which, and the schedule is empty.
/// A `true` plan may still be PARTIAL — see `Schedule.unassigned`.
pub const Plan = struct {
    ok: bool = false,
    reason: []const u8 = "",
    hub: []const u8 = "",
    layer: u8 = 0,
    corridor: Corridor = .{},
    schedule: Schedule = .{},
    /// Lanes the chosen cross-section offers BEFORE any band is thinned — the
    /// corridor's raw capacity. `Schedule.lanes` is the THINNED list (a roomy
    /// band is fanned down to the nets attached to it plus slack), so it is the
    /// wrong number to compare a net count against; this is the right one, and
    /// `detect` reports it as the lanes the fan contends for.
    offered: usize = 0,
};

/// What the caller wants assigned. `nets` are indices into `placement.nets`.
pub const Request = struct {
    nets: []const usize,
    /// Hub ref override; empty detects the shared part.
    hub: []const u8 = "",
    /// Signal layer for the emitted guides; null picks the hub's own side.
    layer: ?u8 = null,
};

/// How far past the cross-section each lane guide runs (mm) — long enough to be
/// a corridor the maze can follow OUT of the escape rather than a point it
/// merely touches, short enough that it never dictates where a net goes once it
/// is clear of the contended set. Lives HERE so the `(assign-escapes …)`
/// lowering and the `preview_escape_assignment` tool cannot describe different
/// guides for the same board: `Request` used to carry a `run_mm` that `plan`
/// never read, which made the two look independently configurable when neither
/// was.
pub const guide_run_mm: f64 = 4.0;

/// Smallest offset past the hub courtyard a cross-section may be cut at.
const cut_min_mm: f64 = 0.4;
/// Largest offset past the hub courtyard the constriction scan looks at.
const cut_max_mm: f64 = 8.0;
/// Step of the constriction scan.
const cut_step_mm: f64 = 0.4;
/// Extra lane-axis span beyond the source-pad extent, per contended net.
const span_pad_per_net: f64 = 1.0;
/// Fallback lane pitch when the board declares no track/clearance rules.
const fallback_pitch_mm: f64 = 0.25;
/// Spare lanes kept beyond the contended set, so the monotone program can still
/// shift a net past a badly-placed lane instead of being forced onto it.
const lane_slack: usize = 2;
/// How many LANE SPACINGS a net may be moved off its own ideal crossing before
/// the assignment declines it (see `displacementCap`). `lane_slack` is the
/// head-room the thinning hands the monotone program, so anything within a few
/// spacings of that is still scheduling the net among its peers; beyond it the
/// "guide" is dictating a detour, which is precisely what the soft-guide
/// contract promises never to do. Five was chosen as the smallest whole number
/// that leaves every fixture's legitimate spread intact while refusing
/// board-a's measured 4.1 mm / 6.2 mm cross-void drags.
const max_displacement_lanes: f64 = 5;

/// A closed interval on the lane axis.
const Interval = struct { lo: f64, hi: f64 };

/// Compute the joint escape assignment for `req.nets` over `placement`.
pub fn plan(arena: Allocator, placement: optimizer.Placement, req: Request) Allocator.Error!Plan {
    if (req.nets.len < 2) return .{ .reason = "fewer than two nets contend" };
    const hub_i = findHub(placement, req) orelse
        return .{ .reason = "no part hosts a pad of two or more of these nets" };
    var sources = try arena.alloc(Source, req.nets.len);
    var off_hub: std.ArrayList(usize) = .empty;
    var n: usize = 0;
    for (req.nets) |net_i| {
        if (try sourceOf(placement, hub_i, net_i)) |s| {
            sources[n] = s;
            n += 1;
        } else try off_hub.append(arena, net_i);
    }
    sources = sources[0..n];
    return finishPlan(arena, placement, hub_i, sources, off_hub.items, req.layer);
}

/// Finish a plan after its pose-dependent source points have been resolved.
/// Detection already owns an indexed view of those points, so sharing the
/// scheduling half avoids repeating its ref-des and pad-name searches for every
/// hub side while keeping authored `plan` requests on the same implementation.
fn finishPlan(
    arena: Allocator,
    placement: optimizer.Placement,
    hub_i: usize,
    sources: []Source,
    off_hub: []const usize,
    requested_layer: ?u8,
) Allocator.Error!Plan {
    if (sources.len < 2) return .{ .reason = "fewer than two nets reach the hub with a destination" };
    const hub = placement.parts[hub_i];
    const dir = escapeDirection(sources);
    const layer = requested_layer orelse defaultLayer(placement, hub);
    const cut = try chooseCut(arena, .{ .placement = placement, .hub = hub_i, .dir = dir, .sources = sources });
    if (cut.lanes.len == 0) return .{ .reason = "no free lane along the escape corridor", .hub = hub.ref_des };
    for (sources) |*s| s.ideal_pos = idealPos(s.*, cut.corridor);
    const sched = try schedule(arena, sources, cut);
    const assignments = try buildAssignments(arena, sources, sched, off_hub);
    var corridor = cut.corridor;
    corridor.cap = sched.cap;
    return .{
        .ok = true,
        .hub = hub.ref_des,
        .layer = layer,
        .corridor = corridor,
        .schedule = .{
            .lanes = sched.lanes,
            .assignments = assignments,
            .unassigned = try refusedOf(arena, assignments),
        },
        .offered = cut.lanes.len,
    };
}

/// Lower an assignment into the router's soft guide tracks: one segment per
/// assigned net, its LANE — starting at the cross-section and running `run_mm`
/// outward along the escape, so the net is biased to hold its own lane through
/// the constriction. Nets left unassigned contribute nothing.
///
/// Deliberately NOT a ramp from the hub pad to the lane point. A pad-to-lane
/// segment reads straight across the hub's OTHER pads (on board-a's J1 it
/// crosses the second pad column outright), and a guide there tells the maze it
/// is cheap to route over foreign copper — the guide is a cost bonus, not a
/// keepout, so nothing stops it. The lane alone carries all the scheduling
/// information; how each net reaches its lane is the maze's own business, and
/// it already knows where the pads are.
pub fn guideTracks(
    arena: Allocator,
    p: Plan,
    run_mm: f64,
) Allocator.Error![]const route_policy.GuideTrack {
    if (!p.ok) return &.{};
    var out: std.ArrayList(route_policy.GuideTrack) = .empty;
    for (p.schedule.assignments) |a| {
        const seg = laneRun(p, a, run_mm) orelse continue;
        try out.append(arena, .{
            .x1 = seg[0],
            .y1 = seg[1],
            .x2 = seg[2],
            .y2 = seg[3],
            .layer = p.layer,
            .net = @intCast(a.net),
        });
    }
    return out.toOwnedSlice(arena);
}

/// The HARD counterpart of `guideTracks`, for a wave that authored
/// `(assign-escapes … (reserve))`: the SAME lane segments, emitted as
/// reservations only their own net may cross (`placement/lane_reserve`).
///
/// One geometry, two lowerings, because a reservation that did not coincide
/// exactly with the guide would push a net toward one corridor while holding a
/// different one open for it. Each lane is `corridor.pitch` wide — the
/// assignment's own lane spacing, which is what makes neighbouring lanes claim
/// adjacent channels instead of each other's.
pub fn reservedLanes(
    arena: Allocator,
    p: Plan,
    run_mm: f64,
) Allocator.Error![]const route_policy.ReservedLane {
    if (!p.ok) return &.{};
    var out: std.ArrayList(route_policy.ReservedLane) = .empty;
    for (p.schedule.assignments) |a| {
        const seg = laneRun(p, a, run_mm) orelse continue;
        try out.append(arena, .{
            .x1 = seg[0],
            .y1 = seg[1],
            .x2 = seg[2],
            .y2 = seg[3],
            .layer = p.layer,
            .net = @intCast(a.net),
            .width = @max(0.0, p.corridor.pitch),
        });
    }
    return out.toOwnedSlice(arena);
}

/// One assigned net's lane as `{x1,y1,x2,y2}`: from the cross-section, running
/// `run_mm` outward along the escape. Null for a net the assignment declined,
/// and for a zero-length run — there is no corridor to express then.
fn laneRun(p: Plan, a: Assignment, run_mm: f64) ?[4]f64 {
    if (a.lane == null) return null;
    const step = p.corridor.dir.outward() * @max(0.0, run_mm);
    if (step == 0) return null;
    const along_y = p.corridor.dir.lanesAlongY();
    return .{
        a.dst[0],
        a.dst[1],
        if (along_y) a.dst[0] + step else a.dst[0],
        if (along_y) a.dst[1] else a.dst[1] + step,
    };
}

// ── Hub + per-net source/destination ────────────────────────────────────────

/// One contended net reduced to what the assignment needs: where it leaves the
/// hub and where it is headed.
const Source = struct {
    net: usize,
    ref: []const u8,
    pad: []const u8,
    at: [2]f64,
    target: [2]f64,
    /// Where this net's straight source→destination line crosses the chosen
    /// cross-section; filled once the corridor is known (see `plan`).
    ideal_pos: f64 = 0,
};

/// The part hosting a pad of the most nets in the set (ties → lowest index), or
/// the caller's named ref when it exists. Null when no part is shared by two.
fn findHub(placement: optimizer.Placement, req: Request) ?usize {
    if (req.hub.len > 0) {
        for (placement.parts, 0..) |part, i| {
            if (std.mem.eql(u8, part.ref_des, req.hub)) return i;
        }
        return null;
    }
    var best: ?usize = null;
    var best_count: usize = 1;
    for (placement.parts, 0..) |part, i| {
        var count: usize = 0;
        for (req.nets) |net_i| {
            if (net_i < placement.nets.len and netTouches(placement.nets[net_i], part.ref_des)) count += 1;
        }
        if (count > best_count) {
            best_count = count;
            best = i;
        }
    }
    return best;
}

fn netTouches(net: optimizer.FlatNet, ref: []const u8) bool {
    for (net.pins) |pin| {
        if (std.mem.eql(u8, pin.ref_des, ref)) return true;
    }
    return false;
}

/// Reduce net `net_i` to its hub pad plus the centroid of its pads elsewhere.
/// Null when the net has no pad on the hub, no pad off it, or names a pad the
/// hub's footprint does not carry.
fn sourceOf(placement: optimizer.Placement, hub_i: usize, net_i: usize) Allocator.Error!?Source {
    if (net_i >= placement.nets.len) return null;
    const net = placement.nets[net_i];
    const hub = placement.parts[hub_i];
    var src: ?Source = null;
    var sum: [2]f64 = .{ 0, 0 };
    var others: usize = 0;
    for (net.pins) |pin| {
        if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
            if (src == null) src = hubSource(hub, pin.pin, net_i);
            continue;
        }
        if (padCenter(placement, pin.ref_des, pin.pin)) |at| {
            sum[0] += at[0];
            sum[1] += at[1];
            others += 1;
        }
    }
    if (others == 0) return null;
    var out = src orelse return null;
    const denom: f64 = @floatFromInt(others);
    out.target = .{ sum[0] / denom, sum[1] / denom };
    return out;
}

fn hubSource(hub: optimizer.Part, pad_name: []const u8, net_i: usize) ?Source {
    for (hub.pads) |pad| {
        if (!std.mem.eql(u8, pad.number, pad_name)) continue;
        return .{
            .net = net_i,
            .ref = hub.ref_des,
            .pad = pad.number,
            .at = optimizer.worldPadCenter(&hub, pad.x, pad.y),
            .target = .{ 0, 0 },
        };
    }
    return null;
}

fn padCenter(placement: optimizer.Placement, ref: []const u8, pad_name: []const u8) ?[2]f64 {
    for (placement.parts) |part| {
        if (!std.mem.eql(u8, part.ref_des, ref)) continue;
        for (part.pads) |pad| {
            if (std.mem.eql(u8, pad.number, pad_name)) return optimizer.worldPadCenter(&part, pad.x, pad.y);
        }
    }
    return null;
}

/// Tie-break order for the direction vote, and the order `detect` walks a hub's
/// four sides in — fixed, so the same board always yields the same corridor and
/// the same fan list.
const dir_order = [_]Direction{ .west, .east, .north, .south };

/// The cardinal direction a source→destination vector points in, resolved on
/// its dominant axis. Shared by the assignment's own vote and by `detect`'s
/// per-net bucketing, so a net is always detected in the corridor the
/// assignment would then schedule it through.
fn dominantDir(dx: f64, dy: f64) Direction {
    if (@abs(dx) >= @abs(dy)) return if (dx < 0) .west else .east;
    return if (dy < 0) .north else .south;
}

/// Majority vote over each net's source→destination vector, resolved on the
/// dominant axis of each vector. Ties break in the fixed order west, east,
/// north, south so the same board always yields the same corridor.
fn escapeDirection(sources: []const Source) Direction {
    var votes: [4]usize = @splat(0);
    for (sources) |s| {
        votes[@backingInt(dominantDir(s.target[0] - s.at[0], s.target[1] - s.at[1]))] += 1;
    }
    var best = dir_order[0];
    var best_votes: usize = 0;
    for (dir_order) |d| {
        const v = votes[@backingInt(d)];
        if (v > best_votes) {
            best_votes = v;
            best = d;
        }
    }
    return best;
}

/// Signal layer for the guides: F.Cu (0) for a top-side hub, B.Cu (1) for a
/// bottom-side one — the face the escape physically leaves on.
fn defaultLayer(placement: optimizer.Placement, hub: optimizer.Part) u8 {
    if (hub.side != .bottom) return 0;
    return if (placement.rules.signalLayerCount() >= 2) 1 else 0;
}

// ── Corridor cross-section + lanes ──────────────────────────────────────────

/// Everything the cut scan reads; grouped so the scan helpers stay low-arity.
const CutInput = struct {
    placement: optimizer.Placement,
    hub: usize,
    dir: Direction,
    sources: []const Source,
};

const Cut = struct {
    corridor: Corridor = .{},
    lanes: []const Lane = &.{},
};

/// Scan cross-sections outward from the hub courtyard and keep the TIGHTEST one
/// that still offers a lane per net — the constriction the whole set has to be
/// scheduled through. When no cut fits everybody, keep the widest seen, so a
/// genuinely over-subscribed corridor still assigns as many nets as it can.
fn chooseCut(arena: Allocator, in: CutInput) Allocator.Error!Cut {
    const pitch = lanePitch(in.placement, in.sources);
    const span = laneSpan(in);
    const start = cutStart(in);
    // Direction and part poses stay fixed throughout the 20-position scan.
    // Reduce each foreign courtyard to cut/lane extents once instead of
    // rebuilding its rotated world rectangle at every candidate cut.
    const boxes = try cutBoxes(arena, in);
    const blocked = try arena.alloc(Interval, boxes.len);
    var best_corridor: Corridor = .{};
    var best_count: usize = 0;
    var offset: f64 = cut_min_mm;
    while (offset <= cut_max_mm) : (offset += cut_step_mm) {
        const at = start + in.dir.outward() * offset;
        const corridor = Corridor{ .dir = in.dir, .cut = at, .lo = span.lo, .hi = span.hi, .pitch = pitch };
        const count = laneCountAt(boxes, corridor, blocked);
        if (count == 0) continue;
        if (best_count == 0 or beats(count, best_count, in.sources.len)) {
            best_corridor = corridor;
            best_count = count;
        }
    }
    if (best_count == 0) return .{};
    return .{ .corridor = best_corridor, .lanes = try lanesAt(arena, boxes, best_corridor) };
}

/// One foreign courtyard in the coordinate system of a corridor scan.
const CutBox = struct { cut_lo: f64, cut_hi: f64, lane_lo: f64, lane_hi: f64 };

fn cutBoxes(arena: Allocator, in: CutInput) Allocator.Error![]const CutBox {
    const along_y = in.dir.lanesAlongY();
    const out = try arena.alloc(CutBox, in.placement.parts.len - 1);
    var n: usize = 0;
    for (in.placement.parts, 0..) |part, i| {
        if (i == in.hub) continue;
        const rect = optimizer.worldCourtyard(&part);
        const cut_lo = if (along_y) rect.minx else rect.miny;
        const lane_lo = if (along_y) rect.miny else rect.minx;
        out[n] = .{
            .cut_lo = cut_lo,
            .cut_hi = cut_lo + (if (along_y) rect.w else rect.h),
            .lane_lo = lane_lo,
            .lane_hi = lane_lo + (if (along_y) rect.h else rect.w),
        };
        n += 1;
    }
    return out[0..n];
}

/// Cut-scan preference: a cut that fits every net beats one that does not, and
/// among cuts that fit, the TIGHTER one wins (it is the constriction the set
/// must be scheduled through). Among cuts that do not fit, the roomier wins.
fn beats(candidate: usize, incumbent: usize, needed: usize) bool {
    const fits = candidate >= needed;
    if (fits != (incumbent >= needed)) return fits;
    return if (fits) candidate < incumbent else candidate > incumbent;
}

/// Lane pitch: the widest track any contended net's class demands plus the
/// board clearance, so lanes are spaced far enough for the fattest member.
fn lanePitch(placement: optimizer.Placement, sources: []const Source) f64 {
    const design = placement.rules.design;
    var width = design.track_width;
    var clearance = design.clearance;
    for (sources) |s| {
        if (s.net >= placement.rules.net.len) continue;
        const rule = placement.rules.net[s.net];
        width = @max(width, rule.width);
        clearance = @max(clearance, rule.clearance);
    }
    const pitch = width + clearance;
    return if (pitch > 0) pitch else fallback_pitch_mm;
}

/// The escape-axis coordinate the scan starts from: the hub courtyard's face on
/// the escape side.
fn cutStart(in: CutInput) f64 {
    const rect = optimizer.worldCourtyard(&in.placement.parts[in.hub]);
    return switch (in.dir) {
        .west => rect.minx,
        .east => rect.minx + rect.w,
        .north => rect.miny,
        .south => rect.miny + rect.h,
    };
}

/// The lane axis's board limits: the declared outline when the design has one,
/// else the placement's own bounding box.
///
/// A lane outside the board carries no copper, so offering one is offering a
/// lane that does not exist — and the placement bbox is NOT the board: a part
/// hanging over the edge (board-a's mounting hole and one buck inductor both
/// do) pushes it out past the outline, and the escape then schedules nets into
/// the strip beyond it. Measured on board-a 2026-08-05: J1's eight-net escape
/// offered a whole three-lane band at y 114.6–116.4 on a board whose outline
/// ends at y 114.4.
fn boardLimits(placement: optimizer.Placement, along_y: bool) Interval {
    const bbox: Interval = if (along_y)
        .{ .lo = placement.miny, .hi = placement.maxy }
    else
        .{ .lo = placement.minx, .hi = placement.maxx };
    const rect = placement.board_rect orelse return bbox;
    const lo = if (along_y) rect.miny else rect.minx;
    return .{ .lo = @max(bbox.lo, lo), .hi = @min(bbox.hi, lo + (if (along_y) rect.h else rect.w)) };
}

/// The cross-section's extent on the lane axis: the source pads' own span, one
/// lane-worth of head-room per contended net on each side, clipped to the board.
fn laneSpan(in: CutInput) Interval {
    const along_y = in.dir.lanesAlongY();
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (in.sources) |s| {
        const v = if (along_y) s.at[1] else s.at[0];
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    const room = span_pad_per_net * @as(f64, @floatFromInt(in.sources.len));
    const board = boardLimits(in.placement, along_y);
    return .{ .lo = @max(board.lo, lo - room), .hi = @min(board.hi, hi + room) };
}

/// The free intervals of `corridor`, sliced into lanes at its pitch. Every part
/// but the hub whose courtyard straddles the cut blocks its own lane-axis span,
/// widened by half a pitch on each side so a lane never grazes a courtyard.
fn lanesAt(arena: Allocator, boxes: []const CutBox, corridor: Corridor) Allocator.Error![]const Lane {
    var blocked: std.ArrayList(Interval) = .empty;
    const halo = corridor.pitch / 2;
    for (boxes) |box| {
        if (corridor.cut < box.cut_lo - halo or corridor.cut > box.cut_hi + halo) continue;
        try blocked.append(arena, .{ .lo = box.lane_lo - halo, .hi = box.lane_hi + halo });
    }
    const free = try freeIntervals(arena, blocked.items, .{ .lo = corridor.lo, .hi = corridor.hi });
    return sliceLanes(arena, free, corridor);
}

/// Count a candidate cut's lanes without allocating them. `chooseCut` needs
/// full lane coordinates only for the eventual winner; the other nineteen
/// candidates are compared solely by this count.
fn laneCountAt(boxes: []const CutBox, corridor: Corridor, blocked: []Interval) usize {
    const halo = corridor.pitch / 2;
    var n: usize = 0;
    for (boxes) |box| {
        if (corridor.cut < box.cut_lo - halo or corridor.cut > box.cut_hi + halo) continue;
        blocked[n] = .{ .lo = box.lane_lo - halo, .hi = box.lane_hi + halo };
        n += 1;
    }
    sortIntervals(blocked[0..n]);
    var count: usize = 0;
    var cursor = corridor.lo;
    for (blocked[0..n]) |b| {
        if (b.hi <= cursor) continue;
        if (b.lo > cursor) count += intervalLaneCount(cursor, @min(b.lo, corridor.hi), corridor.pitch);
        cursor = @max(cursor, b.hi);
        if (cursor >= corridor.hi) break;
    }
    if (cursor < corridor.hi) count += intervalLaneCount(cursor, corridor.hi, corridor.pitch);
    return count;
}

fn intervalLaneCount(lo: f64, hi: f64, pitch: f64) usize {
    const usable = hi - lo - pitch;
    if (usable < 0) return 0;
    return numeric.toCount(@floor(usable / pitch)) + 1;
}

/// The cut scan sorts only the handful of courtyards crossing one line. A
/// local insertion sort avoids paying the generic sort machinery thousands of
/// times in a Debug build, while retaining the same ascending-`lo` ordering.
fn sortIntervals(items: []Interval) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const item = items[i];
        var j = i;
        while (j > 0 and item.lo < items[j - 1].lo) : (j -= 1) {
            items[j] = items[j - 1];
        }
        items[j] = item;
    }
}

/// `span` minus the union of `blocked`, in ascending order.
fn freeIntervals(arena: Allocator, blocked: []Interval, span: Interval) Allocator.Error![]const Interval {
    sortIntervals(blocked);
    var out: std.ArrayList(Interval) = .empty;
    var cursor = span.lo;
    for (blocked) |b| {
        if (b.hi <= cursor) continue;
        if (b.lo > cursor) try out.append(arena, .{ .lo = cursor, .hi = @min(b.lo, span.hi) });
        cursor = @max(cursor, b.hi);
        if (cursor >= span.hi) break;
    }
    if (cursor < span.hi) try out.append(arena, .{ .lo = cursor, .hi = span.hi });
    return out.toOwnedSlice(arena);
}

/// Lay lanes at pitch inside each free interval, centred so the first and last
/// keep half a pitch off the obstacle they abut. Every lane carries the index of
/// the free interval it came from — its BAND — because that is the one fact the
/// flat, ascending lane list otherwise destroys: which neighbouring lanes have
/// clear space between them and which have an obstacle.
fn sliceLanes(arena: Allocator, free: []const Interval, corridor: Corridor) Allocator.Error![]const Lane {
    var out: std.ArrayList(Lane) = .empty;
    const along_y = corridor.dir.lanesAlongY();
    var band: usize = 0;
    for (free) |iv| {
        const usable = iv.hi - iv.lo - corridor.pitch;
        if (usable < 0) continue;
        const count = numeric.toCount(@floor(usable / corridor.pitch)) + 1;
        const used = @as(f64, @floatFromInt(count - 1)) * corridor.pitch;
        const start = (iv.lo + iv.hi - used) / 2;
        for (0..count) |k| {
            const pos = start + @as(f64, @floatFromInt(k)) * corridor.pitch;
            const x = if (along_y) corridor.cut else pos;
            const y = if (along_y) pos else corridor.cut;
            try out.append(arena, .{ .pos = pos, .x = x, .y = y, .band = band });
        }
        band += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Thin one band's `lanes` down to at most `want`, evenly across the list. A
/// band at minimum track pitch offers far more lanes than any contended set
/// needs, and a detour-minimising assignment over all of them packs every net
/// into a strip one pitch wide — the crossings are gone but the traces still run
/// shoulder to shoulder, which is not what a hand router draws and not what the
/// maze can hold. Thinning first makes the SAME assignment spread across the
/// whole free width. A band already at or below `want` lanes is returned
/// unchanged, so a genuinely tight escape keeps every lane it has. The first and
/// last lane are always kept, so a band's extent survives thinning.
fn spreadLanes(arena: Allocator, lanes: []const Lane, want: usize) Allocator.Error![]const Lane {
    if (want < 2 or lanes.len <= want) return lanes;
    const out = try arena.alloc(Lane, want);
    const span: f64 = @floatFromInt(lanes.len - 1);
    const steps: f64 = @floatFromInt(want - 1);
    for (out, 0..) |*lane, i| {
        const at = @round(span * @as(f64, @floatFromInt(i)) / steps);
        lane.* = lanes[numeric.toCount(at)];
    }
    return out;
}

// ── Joint assignment ────────────────────────────────────────────────────────

/// Where net `s`'s straight source→destination line meets the cross-section,
/// clamped into the corridor. A net whose destination is not actually past the
/// cut keeps its own source coordinate.
fn idealPos(s: Source, corridor: Corridor) f64 {
    const along_y = corridor.dir.lanesAlongY();
    const escape_from = if (along_y) s.at[0] else s.at[1];
    const escape_to = if (along_y) s.target[0] else s.target[1];
    const lane_from = if (along_y) s.at[1] else s.at[0];
    const lane_to = if (along_y) s.target[1] else s.target[0];
    const run = escape_to - escape_from;
    var pos = lane_from;
    if (@abs(run) > 1e-9) {
        const t = (corridor.cut - escape_from) / run;
        if (t > 0) pos = lane_from + @min(t, 1.0) * (lane_to - lane_from);
    }
    return std.math.clamp(pos, corridor.lo, corridor.hi);
}

/// One net's row in the dynamic program: its ideal crossing point and which
/// entry of the caller's `sources` it came from.
const Row = struct { ideal: f64, source: usize };

fn rowLess(_: void, a: Row, b: Row) bool {
    if (a.ideal != b.ideal) return a.ideal < b.ideal;
    return a.source < b.source;
}

/// A contiguous run of lanes — one free interval of the cross-section, with no
/// obstacle anywhere between its first and its last lane. `hi` is exclusive.
const Band = struct { lo: usize, hi: usize };

/// Group `lanes` into its bands. `sliceLanes` emits lanes free interval by free
/// interval and tags each with its interval, so a band is exactly a maximal run
/// sharing one tag — no geometry is re-derived here. `lanes` is never empty
/// (`plan` returns before this on an empty corridor).
fn bandsOf(arena: Allocator, lanes: []const Lane) Allocator.Error![]const Band {
    var out: std.ArrayList(Band) = .empty;
    var start: usize = 0;
    for (lanes, 0..) |lane, i| {
        if (i > 0 and lane.band != lanes[i - 1].band) {
            try out.append(arena, .{ .lo = start, .hi = i });
            start = i;
        }
    }
    try out.append(arena, .{ .lo = start, .hi = lanes.len });
    return out.toOwnedSlice(arena);
}

/// How far a net may be moved off its own ideal crossing, in mm.
///
/// The unit is the LANE SPACING this corridor actually offers, not the raw
/// track pitch: `spreadLanes` deliberately fans a roomy band out so the set does
/// not run shoulder to shoulder, and a cap in raw pitches would then refuse the
/// very spread it was asked to produce. So the spacing is the widest a band
/// could be thinned to (its width shared among the whole set plus slack),
/// floored at the pitch, and the cap is `max_displacement_lanes` of those.
///
/// Measured WITHIN bands only. The gap across a void is not a lane spacing —
/// it is the thing this cap exists to refuse.
fn displacementCap(lanes: []const Lane, bands: []const Band, pitch: f64, nets: usize) f64 {
    const slots: f64 = @floatFromInt(@max(1, nets + lane_slack - 1));
    var spacing = pitch;
    for (bands) |b| {
        const width = lanes[b.hi - 1].pos - lanes[b.lo].pos;
        spacing = @max(spacing, width / slots);
    }
    return spacing * max_displacement_lanes;
}

/// The band a net's ideal crossing is nearest, and how far OUTSIDE that band it
/// lies (0 when inside). Ties go to the lower band, so the pick is stable.
const BandPick = struct { band: usize = 0, gap: f64 = 0 };

fn nearestBand(lanes: []const Lane, bands: []const Band, ideal: f64) BandPick {
    var best: BandPick = .{ .gap = std.math.inf(f64) };
    for (bands, 0..) |b, i| {
        const lo = lanes[b.lo].pos;
        const hi = lanes[b.hi - 1].pos;
        const gap = if (ideal < lo) lo - ideal else if (ideal > hi) ideal - hi else 0;
        if (gap < best.gap) best = .{ .band = i, .gap = gap };
    }
    return best;
}

/// One net's scheduling outcome, before it is published as an `Assignment`.
const Slot = struct { lane: ?usize = null, refusal: Refusal = .none, offset: f64 = 0 };

/// The whole schedule: the lane list actually offered, the cap it was judged
/// against, and one slot per entry of the caller's `sources`.
const Scheduled = struct {
    cap: f64,
    lanes: []const Lane,
    slots: []const Slot,
};

/// Schedule the contended set over the chosen cross-section, band by band.
///
/// Each net is first attached to the band its own ideal crossing is nearest,
/// and refused outright when no band comes within the cap — that both spares it
/// a dictated detour AND frees the capacity it would have taken from a net that
/// genuinely belongs there. Every band is then thinned to a few more lanes than
/// the nets attached to it and solved on its own, so monotonicity is enforced
/// exactly where it means something: two nets in one band share clear space and
/// really would cross; two nets in different bands are separated by an
/// obstacle, and no ordering between them can make them cross.
fn schedule(arena: Allocator, sources: []const Source, cut: Cut) Allocator.Error!Scheduled {
    const raw = try bandsOf(arena, cut.lanes);
    const cap = displacementCap(cut.lanes, raw, cut.corridor.pitch, sources.len);
    const picks = try arena.alloc(BandPick, sources.len);
    const load = try arena.alloc(usize, raw.len);
    @memset(load, 0);
    for (sources, picks) |s, *p| {
        p.* = nearestBand(cut.lanes, raw, s.ideal_pos);
        if (p.gap <= cap) load[p.band] += 1;
    }
    const lanes = try thinBands(arena, cut.lanes, raw, load);
    const bands = try bandsOf(arena, lanes);
    return .{
        .cap = cap,
        .lanes = lanes,
        .slots = try solveBands(arena, .{
            .sources = sources,
            .picks = picks,
            .lanes = lanes,
            .bands = bands,
            .cap = cap,
        }),
    };
}

/// Thin each band to `load` + slack lanes of its own. Thinning per band rather
/// than over the flat list is what stops a band NO net wants from spending the
/// resolution a crowded band needs — on board-a's bimodal J1 escape three of
/// the ten offered lanes sat in a band whose nearest net was four millimetres
/// away. `spreadLanes` keeps a band's first and last lane, so a band's extent —
/// the thing net attachment was decided on — survives the thinning unchanged.
fn thinBands(
    arena: Allocator,
    lanes: []const Lane,
    bands: []const Band,
    load: []const usize,
) Allocator.Error![]const Lane {
    var out: std.ArrayList(Lane) = .empty;
    for (bands, load, 0..) |b, k, bi| {
        for (try spreadLanes(arena, lanes[b.lo..b.hi], k + lane_slack)) |lane| {
            var kept = lane;
            kept.band = bi;
            try out.append(arena, kept);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Everything `solveBands` reads, grouped so it stays low-arity.
const BandSolve = struct {
    sources: []const Source,
    picks: []const BandPick,
    lanes: []const Lane,
    bands: []const Band,
    cap: f64,
};

/// Run the monotone program once per band and check every result against the
/// cap. A net the program had to drop is `no_lane`; one it kept but had to push
/// past the cap is `displacement_over_cap`; one no band would take is
/// `out_of_band`. All three route exactly as they do with no form authored.
fn solveBands(arena: Allocator, in: BandSolve) Allocator.Error![]const Slot {
    const out = try arena.alloc(Slot, in.sources.len);
    for (out, in.picks) |*slot, p| slot.* = if (p.gap > in.cap)
        .{ .refusal = .out_of_band, .offset = p.gap }
    else
        .{ .refusal = .no_lane };
    var rows: std.ArrayList(Row) = .empty;
    for (in.bands, 0..) |b, bi| {
        rows.clearRetainingCapacity();
        for (in.sources, in.picks, 0..) |s, p, i| {
            if (p.gap > in.cap or p.band != bi) continue;
            try rows.append(arena, .{ .ideal = s.ideal_pos, .source = i });
        }
        if (rows.items.len == 0) continue;
        std.mem.sort(Row, rows.items, {}, rowLess);
        const lanes = in.lanes[b.lo..b.hi];
        for (try solveMonotone(arena, rows.items, lanes), rows.items) |pick, row| {
            const k = pick orelse continue;
            const off = @abs(lanes[k].pos - row.ideal);
            out[row.source] = if (off > in.cap)
                .{ .refusal = .displacement_over_cap, .offset = off }
            else
                .{ .lane = b.lo + k, .offset = off };
        }
    }
    return out;
}

/// The dynamic program itself: `cost[i][j]` = least total detour placing the
/// first `i` rows in the first `j` lanes. A row may go unplaced at a penalty
/// larger than any single detour, so an over-subscribed corridor drops the
/// rows that fit worst rather than failing outright.
fn solveMonotone(arena: Allocator, rows: []const Row, lanes: []const Lane) Allocator.Error![]const ?usize {
    const w = lanes.len + 1;
    const cost = try arena.alloc(f64, (rows.len + 1) * w);
    const from = try arena.alloc(u2, (rows.len + 1) * w);
    const skip = skipPenalty(rows, lanes);
    for (0..w) |j| {
        cost[j] = 0;
        from[j] = 0;
    }
    for (1..rows.len + 1) |i| {
        for (0..w) |j| {
            const here = i * w + j;
            var best = cost[(i - 1) * w + j] + skip;
            var pick: u2 = 2;
            if (j > 0) {
                const drop = cost[here - 1];
                if (drop < best) {
                    best = drop;
                    pick = 1;
                }
                const take = cost[(i - 1) * w + j - 1] + @abs(lanes[j - 1].pos - rows[i - 1].ideal);
                if (take < best) {
                    best = take;
                    pick = 0;
                }
            }
            cost[here] = best;
            from[here] = pick;
        }
    }
    return walkBack(arena, .{ .rows = rows.len, .width = w, .from = from });
}

/// Back-pointer walk of `solveMonotone`'s table into a lane per row.
const Trace = struct { rows: usize, width: usize, from: []const u2 };

fn walkBack(arena: Allocator, t: Trace) Allocator.Error![]const ?usize {
    const out = try arena.alloc(?usize, t.rows);
    @memset(out, null);
    var i = t.rows;
    var j = t.width - 1;
    while (i > 0) {
        switch (t.from[i * t.width + j]) {
            0 => {
                out[i - 1] = j - 1;
                i -= 1;
                j -= 1;
            },
            1 => j -= 1,
            else => i -= 1,
        }
    }
    return out;
}

/// Leaving a net unassigned must cost more than any detour a lane could impose,
/// so the program only ever drops a net when there is genuinely no lane left.
/// Measured against the ROWS' own ideals rather than the lane span, because a
/// band solved on its own can be one lane wide (span zero) while the detour to
/// that lane is millimetres — sizing the penalty off the span there would have
/// the program drop every row instead of placing the one that fits.
fn skipPenalty(rows: []const Row, lanes: []const Lane) f64 {
    var reach: f64 = 0;
    for (rows) |r| {
        for (lanes) |l| reach = @max(reach, @abs(l.pos - r.ideal));
    }
    return reach * @as(f64, @floatFromInt(rows.len + 1)) + 1;
}

fn buildAssignments(
    arena: Allocator,
    sources: []const Source,
    sched: Scheduled,
    off_hub: []const usize,
) Allocator.Error![]const Assignment {
    const out = try arena.alloc(Assignment, sources.len + off_hub.len);
    for (sources, sched.slots, out[0..sources.len]) |s, slot, *a| {
        a.* = .{
            .net = s.net,
            .lane = slot.lane,
            .from = .{ .ref = s.ref, .pad = s.pad, .at = s.at },
            .dst = if (slot.lane) |k| .{ sched.lanes[k].x, sched.lanes[k].y } else .{ 0, 0 },
            .fit = .{ .ideal = s.ideal_pos, .offset = slot.offset, .refusal = slot.refusal },
        };
    }
    // The nets that never reached the corridor, in the order the caller named
    // them, so `assignments` accounts for every net of the request.
    for (off_hub, out[sources.len..]) |net_i, *a| a.* = .{ .net = net_i, .fit = .{ .refusal = .off_hub } };
    return out;
}

/// The declined entries of `assignments`, in the same order — `Plan.unassigned`.
fn refusedOf(arena: Allocator, assignments: []const Assignment) Allocator.Error![]const Assignment {
    var out: std.ArrayList(Assignment) = .empty;
    for (assignments) |a| {
        if (a.lane == null) try out.append(arena, a);
    }
    return out.toOwnedSlice(arena);
}

/// How many distinct bands `lanes` spans. More than one means the corridor's
/// free space is split by an obstacle, which is the difference between "eight
/// nets, ten lanes, fine" and board-a's actual J1 escape.
fn bandCount(lanes: []const Lane) usize {
    if (lanes.len == 0) return 0;
    var n: usize = 1;
    for (lanes[1..], lanes[0 .. lanes.len - 1]) |b, a| {
        if (b.band != a.band) n += 1;
    }
    return n;
}

// ── Detection: contended escape fans, with no form authored ─────────────────

/// One hub side whose escape fan the corridor there cannot seat.
///
/// Purely a DIAGNOSIS. Nothing is steered by this, no guide is emitted, and the
/// fan routes exactly as it does with no `(assign-escapes …)` written — see the
/// module header for the measurement that keeps it that way.
pub const Contention = struct {
    /// The escaping part's ref-des.
    hub: []const u8,
    /// The copper face the assignment would draw the lanes on.
    layer: u8 = 0,
    /// The fan: every net with a pad on `hub` whose counterparts lie this way,
    /// ascending by net index.
    nets: []const usize,
    /// How many of the fan the joint assignment could give a lane of its own.
    seated: usize,
    /// Lanes the tightest cross-section offers — the capacity the fan contends
    /// for (`Plan.offered`).
    lanes: usize,
    /// Contiguous free bands that capacity is split across. More than one means
    /// the lanes are not one corridor: a net cannot reach a band on the far side
    /// of an obstacle without a detour the assignment refuses to dictate.
    bands: usize,
    /// The cross-section the shortfall was measured at — including `dir`, the
    /// side the fan leaves on, which is not repeated as a field of its own.
    corridor: Corridor,

    /// How many of the fan got no lane — the shortfall this finding is about.
    pub fn refused(self: Contention) usize {
        return self.nets.len - self.seated;
    }
};

/// Smallest fan worth analysing. Two nets leaving one side share a corridor
/// trivially and are not what "contention" means; three is the smallest set a
/// joint assignment can order differently from the router's own arrival order.
const detect_min_fan: usize = 3;

/// How many contended fans one detection reports, worst first. A board whose
/// parts are still piled in the staging band would otherwise flag every hub —
/// `unplaced` already says that once — and these findings share `lint[]` with
/// every other gate, so the report is capped rather than exhaustive.
///
/// Sized on the corpus (measured 2026-08-06, uncapped): rf-switch-8way and
/// adf5901 find 0, the four board-b boards and straps 2-4, black-canyon 6,
/// board-a 9, board-a-base 11, stm32n6 15, and the unplaced labstation 18.
/// Six covers every finished board's worst handful — board-a's `J1` west
/// escape, the one the audit named, comes fifth — and holds the two crowded
/// boards to the same kind of bounded report `pad-sealed` gets from its own cap.
const detect_max_findings: usize = 6;

/// What `detect` reads beyond the placement.
pub const DetectOptions = struct {
    /// Smallest fan analysed (see `detect_min_fan`).
    min_fan: usize = detect_min_fan,
    /// Cap on reported fans, worst first (see `detect_max_findings`).
    max: usize = detect_max_findings,
    /// Net-index mask of the nets an authored `(assign-escapes …)` wave already
    /// hands to the assignment. A fan every net of which is masked is NOT
    /// reported: the author already decided about that escape, and repeating it
    /// as a warning is the noise this gate must not add. Empty (the default)
    /// masks nothing.
    assigned: []const bool = &.{},
};

/// Find every contended escape fan on `placement`: for each hub part and each
/// of its four sides, the nets leaving that way against the lanes the tightest
/// cross-section offers them. A fan the joint assignment can seat in full is not
/// contended and is not reported.
///
/// Static and route-free — the same cut scan `plan` runs, over the same
/// placement — so it is cheap enough for a preflight path and its verdicts do
/// not move with the router's ordering, priorities or effort tier.
pub fn detect(
    arena: Allocator,
    placement: optimizer.Placement,
    opts: DetectOptions,
) Allocator.Error![]const Contention {
    const cache = try DetectCache.build(arena, placement);
    return detectCached(arena, placement, opts, cache);
}

/// Pose-independent net-to-pad topology for repeated detection over nearby
/// poses of one board. Rough repair runs the detector after every proposed
/// move; ref-des lookup, pad-name lookup, and plane classification do not move.
pub const DetectCache = struct {
    pins: []const []const ?PinLoc,
    plane: []const bool,
    /// Net indices incident to each part, deduplicated per part. Detection only
    /// reads rows for hub parts; keeping all rows index-aligned avoids a map in
    /// every repeated pose check.
    hub_nets: []const []const usize,

    /// Resolve net pins and plane membership once for repeated nearby poses.
    pub fn build(arena: Allocator, p: optimizer.Placement) Allocator.Error!DetectCache {
        var of_ref = std.StringHashMapUnmanaged(usize).empty;
        for (p.parts, 0..) |part, i| try of_ref.put(arena, part.ref_des, i);
        const rows = try arena.alloc([]const ?PinLoc, p.nets.len);
        const hub_lists = try arena.alloc(std.ArrayList(usize), p.parts.len);
        @memset(hub_lists, .empty);
        for (p.nets, rows, 0..) |net, *row, ni| {
            const cells = try arena.alloc(?PinLoc, net.pins.len);
            for (net.pins, cells) |pin, *cell| {
                cell.* = pinLocAt(p, of_ref.get(pin.ref_des), pin.pin);
            }
            for (cells, 0..) |maybe_loc, ci| {
                const loc = maybe_loc orelse continue;
                if (p.parts[loc.part].kind != .hub) continue;
                var duplicate = false;
                for (cells[0..ci]) |maybe_prev| {
                    const prev = maybe_prev orelse continue;
                    if (prev.part == loc.part) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate) try hub_lists[loc.part].append(arena, ni);
            }
            row.* = cells;
        }
        const hub_nets = try arena.alloc([]const usize, p.parts.len);
        for (hub_lists, hub_nets) |list, *nets| nets.* = list.items;
        return .{ .pins = rows, .plane = try planeNets(arena, p), .hub_nets = hub_nets };
    }
};

/// Detect with topology prepared by `DetectCache.build`; only world pad
/// coordinates and corridor geometry are recomputed for the current poses.
pub fn detectCached(
    arena: Allocator,
    placement: optimizer.Placement,
    opts: DetectOptions,
    cache: DetectCache,
) Allocator.Error![]const Contention {
    const idx = try PadIndex.buildCached(arena, placement, cache);
    var out: std.ArrayList(Contention) = .empty;
    for (placement.parts, 0..) |part, pi| {
        if (part.kind != .hub) continue;
        try detectHub(arena, .{
            .placement = placement,
            .idx = idx,
            .pins = cache.pins,
            .plane = cache.plane,
            .nets = cache.hub_nets[pi],
            .hub = pi,
            .opts = opts,
        }, &out);
    }
    std.mem.sort(Contention, out.items, {}, worstFirst);
    return out.items[0..@min(out.items.len, opts.max)];
}

/// Which nets a plane carries, per `plane_stitch.netHasPlane` — the predicate
/// the sealed-pad gate already exempts on, for the same reason: a plane-carried
/// net leaves a hub pad by dropping a via into the pour, not by taking a lane
/// through the escape, so it is not contending for one.
///
/// Excluding them is not tidiness, it is what makes the measurement mean
/// anything on a real connector. Board A's `J1` carries twenty-one ground
/// pads spread over all four edges: counting `GND` as a westward contender both
/// added a net that never wanted a lane AND stretched the cross-section across
/// the whole connector, so the side read as sixteen nets against nineteen
/// lanes — comfortable — when the six SPI/control nets actually fighting over
/// that corridor are the reason the escape is hard.
fn planeNets(arena: Allocator, placement: optimizer.Placement) Allocator.Error![]const bool {
    const out = try arena.alloc(bool, placement.nets.len);
    for (placement.nets, out) |net, *flag| flag.* = plane_stitch.netHasPlane(placement, net.name);
    return out;
}

/// The contended fan as a paste-ready `(pcb-plan (route …))` fragment: ONE wave
/// naming the fan's nets and opting them into the joint assignment, aimed at the
/// hub and layer the detection measured. This is what makes a detection-only
/// gate actionable — the geometry proposes the exact edit, and a human applies
/// it deliberately rather than the board steering itself onto a knife-edge.
pub fn suggestDsl(
    arena: Allocator,
    placement: optimizer.Placement,
    c: Contention,
) Allocator.Error![]const u8 {
    var nets: std.ArrayList(u8) = .empty;
    for (c.nets, 0..) |n, i| {
        if (i > 0) try nets.append(arena, ' ');
        const name = if (n < placement.nets.len) placement.nets[n].name else "";
        try nets.appendSlice(arena, try std.fmt.allocPrint(arena, "\"{s}\"", .{name}));
    }
    var layer_buf: [16]u8 = undefined;
    return std.fmt.allocPrint(
        arena,
        "(pcb-plan (route (wave \"escape-{s}-{s}\" (nets {s}) (assign-escapes \"{s}\" \"{s}\"))))",
        .{
            c.hub,
            @tagName(c.corridor.dir),
            nets.items,
            placement.rules.signalLayerName(c.layer, &layer_buf),
            c.hub,
        },
    );
}

/// Every net pin reduced to its world pad centre once. Detection asks the same
/// "where does this net go" question of every net at every hub, and resolving a
/// pad by (ref, pad) walks the whole part list — doing that per hub turned a
/// microsecond pass into a measurable one, so it is done once here.
const PadIndex = struct {
    /// `at[net][k]` is that net's pin `k`, or null when no placed part carries
    /// the pad.
    at: []const []const ?[2]f64,

    fn build(arena: Allocator, p: optimizer.Placement) Allocator.Error!PadIndex {
        const cache = try DetectCache.build(arena, p);
        return buildCached(arena, p, cache);
    }

    fn buildCached(arena: Allocator, p: optimizer.Placement, cache: DetectCache) Allocator.Error!PadIndex {
        const rows = try arena.alloc([]const ?[2]f64, p.nets.len);
        for (cache.pins, rows) |pins, *row| {
            const cells = try arena.alloc(?[2]f64, pins.len);
            for (pins, cells) |pin, *cell| {
                cell.* = if (pin) |loc|
                    optimizer.worldPadCenter(&p.parts[loc.part], loc.x, loc.y)
                else
                    null;
            }
            row.* = cells;
        }
        return .{ .at = rows };
    }
};

const PinLoc = struct { part: usize, x: f64, y: f64 };

fn pinLocAt(p: optimizer.Placement, part_i: ?usize, pad_name: []const u8) ?PinLoc {
    const pi = part_i orelse return null;
    for (p.parts[pi].pads) |pad| {
        if (std.mem.eql(u8, pad.number, pad_name)) return .{ .part = pi, .x = pad.x, .y = pad.y };
    }
    return null;
}

/// Part `part_i`'s pad `pad_name` in world space; null when the part is unknown
/// or its footprint carries no such pad.
fn padCenterAt(p: optimizer.Placement, part_i: ?usize, pad_name: []const u8) ?[2]f64 {
    const part = p.parts[part_i orelse return null];
    for (part.pads) |pad| {
        if (std.mem.eql(u8, pad.number, pad_name)) return optimizer.worldPadCenter(&part, pad.x, pad.y);
    }
    return null;
}

/// One hub's detection pass, grouped so the helpers stay low-arity.
const HubScan = struct {
    placement: optimizer.Placement,
    idx: PadIndex,
    /// The same index-aligned pin table as `idx`, retaining each pin's
    /// resolved part identity. Detection can therefore recognize a hub pin by
    /// integer index instead of repeating ref-des string comparisons in its
    /// net × hub hot loop.
    pins: []const []const ?PinLoc,
    /// Per net: is it plane-carried (see `planeNets`)? Never part of a fan.
    plane: []const bool,
    /// Only nets incident to `hub`; prepared once with the topology cache so
    /// every pose round avoids scanning every unrelated board net per hub.
    nets: []const usize,
    hub: usize,
    opts: DetectOptions,
};

/// Bucket every net leaving this hub by the side it leaves on, then measure each
/// side's fan against the corridor there.
fn detectHub(arena: Allocator, in: HubScan, out: *std.ArrayList(Contention)) Allocator.Error!void {
    var fans: [dir_order.len]std.ArrayList(usize) = @splat(.empty);
    for (in.nets) |ni| {
        if (in.plane[ni]) continue;
        const d = fanDir(in, ni) orelse continue;
        try fans[@backingInt(d)].append(arena, ni);
    }
    for (dir_order) |d| {
        const nets = fans[@backingInt(d)].items;
        if (nets.len < in.opts.min_fan or allAssigned(in.opts.assigned, nets)) continue;
        if (try contentionOf(arena, in, nets)) |c| try out.append(arena, c);
    }
}

/// Which way net `ni` leaves this hub: the dominant axis of the vector from its
/// hub pad to the centroid of its pads elsewhere — the same reduction
/// `sourceOf` performs for the assignment. Null when the net has no pad on the
/// hub, or no located pad anywhere else, so it never escapes from here.
fn fanDir(in: HubScan, ni: usize) ?Direction {
    var from: ?[2]f64 = null;
    var sum: [2]f64 = .{ 0, 0 };
    var others: usize = 0;
    for (in.pins[ni], in.idx.at[ni]) |loc, cell| {
        const at = cell orelse continue;
        if ((loc orelse continue).part == in.hub) {
            if (from == null) from = at;
            continue;
        }
        sum[0] += at[0];
        sum[1] += at[1];
        others += 1;
    }
    if (others == 0) return null;
    const src = from orelse return null;
    const n: f64 = @floatFromInt(others);
    return dominantDir(sum[0] / n - src[0], sum[1] / n - src[1]);
}

/// Schedule `nets` over this hub's corridor and keep the result only when the
/// corridor cannot seat the whole fan. A fan that fits is not a finding, and a
/// hub with no shared corridor at all (`plan` declined) is not one either.
fn contentionOf(arena: Allocator, in: HubScan, nets: []const usize) Allocator.Error!?Contention {
    const p = try planIndexed(arena, in, nets);
    if (!p.ok) return null;
    const seated = p.schedule.assignments.len - p.schedule.unassigned.len;
    if (seated >= nets.len) return null;
    return .{
        .hub = p.hub,
        .layer = p.layer,
        .nets = try arena.dupe(usize, nets),
        .seated = seated,
        .lanes = p.offered,
        .bands = bandCount(p.schedule.lanes),
        .corridor = p.corridor,
    };
}

/// Detection has already resolved every net pin to world space. Build the same
/// sources as `plan` directly from that table instead of walking all parts and
/// pads again for every candidate hub side.
fn planIndexed(arena: Allocator, in: HubScan, nets: []const usize) Allocator.Error!Plan {
    var sources = try arena.alloc(Source, nets.len);
    var off_hub: std.ArrayList(usize) = .empty;
    var n: usize = 0;
    for (nets) |net_i| {
        if (sourceOfIndexed(in, net_i)) |s| {
            sources[n] = s;
            n += 1;
        } else try off_hub.append(arena, net_i);
    }
    return finishPlan(arena, in.placement, in.hub, sources[0..n], off_hub.items, null);
}

fn sourceOfIndexed(in: HubScan, net_i: usize) ?Source {
    if (net_i >= in.placement.nets.len) return null;
    const net = in.placement.nets[net_i];
    const hub_ref = in.placement.parts[in.hub].ref_des;
    var src: ?Source = null;
    var sum: [2]f64 = .{ 0, 0 };
    var others: usize = 0;
    for (net.pins, in.pins[net_i], in.idx.at[net_i]) |pin, loc, cell| {
        const at = cell orelse continue;
        if ((loc orelse continue).part == in.hub) {
            if (src == null) src = .{ .net = net_i, .ref = hub_ref, .pad = pin.pin, .at = at, .target = .{ 0, 0 } };
            continue;
        }
        sum[0] += at[0];
        sum[1] += at[1];
        others += 1;
    }
    if (others == 0) return null;
    var out = src orelse return null;
    const denom: f64 = @floatFromInt(others);
    out.target = .{ sum[0] / denom, sum[1] / denom };
    return out;
}

/// True when an authored `(assign-escapes …)` wave already covers every net of
/// this fan. Every net, not merely one: a wave that takes half a hub's escape
/// leaves the other half contending, and that half is still worth saying.
fn allAssigned(mask: []const bool, nets: []const usize) bool {
    if (mask.len == 0) return false;
    for (nets) |n| {
        if (n >= mask.len or !mask[n]) return false;
    }
    return true;
}

/// Worst fan first — most nets left without a lane, then the largest fan, then
/// hub ref-des and side, so the report is total and deterministic.
fn worstFirst(_: void, a: Contention, b: Contention) bool {
    if (a.refused() != b.refused()) return a.refused() > b.refused();
    if (a.nets.len != b.nets.len) return a.nets.len > b.nets.len;
    const by_ref = std.mem.order(u8, a.hub, b.hub);
    if (by_ref != .eq) return by_ref == .lt;
    return @backingInt(a.corridor.dir) < @backingInt(b.corridor.dir);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// A synthetic four-net escape: connector `J1` on the east with four stacked
/// pads, four destination parts due west, and a 1 mm lane pitch so the lane
/// arithmetic reads by eye.
const FourNet = struct {
    parts: [6]optimizer.Part,
    pads: [4][1]geometry.Pad,
    hub_pads: [4]geometry.Pad,
    nets: [4]optimizer.FlatNet,
    pins: [4][2]flat_netlist.FlatPin,

    fn setupBoard(self: *FourNet, block: ?optimizer.Part) void {
        const ys = [_]f64{ -1.5, -0.5, 0.5, 1.5 };
        for (ys, 0..) |y, i| {
            self.hub_pads[i] = .{ .number = padName(i), .x = -0.5, .y = y, .w = 0.4, .h = 0.4 };
            self.pads[i] = .{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
        }
        self.parts[0] = .{
            .ref_des = "J1",
            .kind = .hub,
            .hw = 1,
            .hh = 4,
            .pads = &self.hub_pads,
            .fallback = false,
            .x = 10,
            .y = 0,
        };
        for (ys, 0..) |y, i| {
            self.parts[i + 1] = .{
                .ref_des = destName(i),
                .kind = .passive,
                .hw = 0.5,
                .hh = 0.5,
                .pads = &self.pads[i],
                .fallback = false,
                .x = -10,
                .y = y,
            };
            self.pins[i] = .{
                .{ .ref_des = "J1", .pin = padName(i) },
                .{ .ref_des = destName(i), .pin = "1" },
            };
            self.nets[i] = .{ .name = netName(i), .pins = &self.pins[i] };
        }
        if (block) |b| self.parts[5] = b;
    }

    fn placement(self: *const FourNet, parts: []optimizer.Part) optimizer.Placement {
        return .{
            .parts = parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &self.nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = -11,
            .miny = -5,
            .maxx = 11,
            .maxy = 5,
            .generated = true,
            .rules = .{ .design = .{ .track_width = 0.4, .clearance = 0.6 } },
        };
    }
};

fn padName(i: usize) []const u8 {
    return ([_][]const u8{ "1", "2", "3", "4" })[i];
}
fn destName(i: usize) []const u8 {
    return ([_][]const u8{ "R1", "R2", "R3", "R4" })[i];
}
fn netName(i: usize) []const u8 {
    return ([_][]const u8{ "A", "B", "C", "D" })[i];
}

const all_four = [_]usize{ 0, 1, 2, 3 };

// spec: placement/escape-assign - a contended net set resolves to one shared hub and the direction its destinations lie in
test "the shared hub and escape direction come from the contended set" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    f.setupBoard(null);
    const p = try plan(arena_i.allocator(), f.placement(f.parts[0..5]), .{ .nets = &all_four });
    try testing.expect(p.ok);
    try testing.expectEqualStrings("J1", p.hub);
    try testing.expectEqual(Direction.west, p.corridor.dir);
}

// spec: placement/escape-assign - a net set with no part in common assigns nothing and says so
test "a set with no shared hub reports why it assigned nothing" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    f.setupBoard(null);
    // Two nets that share no part: rewire each onto its own destination pair.
    var lone = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    var other = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R3", .pin = "1" },
        .{ .ref_des = "R4", .pin = "1" },
    };
    f.nets[0] = .{ .name = "A", .pins = &lone };
    f.nets[1] = .{ .name = "B", .pins = &other };
    const pair = [_]usize{ 0, 1 };
    const p = try plan(arena_i.allocator(), f.placement(f.parts[0..5]), .{ .nets = &pair });
    try testing.expect(!p.ok);
    try testing.expect(p.reason.len > 0);
    try testing.expectEqual(@as(usize, 0), p.schedule.assignments.len);
}

// spec: placement/escape-assign - lanes are the free intervals of the corridor cross-section at track pitch, with every foreign courtyard removed
test "an obstacle in the corridor removes its own lanes" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    const block_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    f.setupBoard(.{
        .ref_des = "BLK",
        .kind = .passive,
        .hw = 1,
        .hh = 1.5,
        .pads = &block_pad,
        .fallback = false,
        .x = 5,
        .y = 0,
    });
    const p = try plan(arena_i.allocator(), f.placement(f.parts[0..6]), .{ .nets = &all_four });
    try testing.expect(p.ok);
    // The obstacle spans y ∈ [-1.5, 1.5]; with a half-pitch halo it blocks
    // [-2, 2] of the 10 mm span, leaving 3 lanes each side instead of 10.
    try testing.expectEqual(@as(usize, 6), p.schedule.lanes.len); // 6 == 4 nets + slack, so none are thinned
    try testing.expect(p.corridor.cut >= 3.5 and p.corridor.cut <= 6.5);
    for (p.schedule.lanes) |lane| try testing.expect(lane.pos <= -2 or lane.pos >= 2);
}

// spec: placement/escape-assign - the tightest cross-section that still fits every contended net is the one scheduled
test "the scan picks the constriction over the roomier cuts around it" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    f.setupBoard(null);
    const open = try plan(arena_i.allocator(), f.placement(f.parts[0..5]), .{ .nets = &all_four });
    try testing.expectEqual(all_four.len + lane_slack, open.schedule.lanes.len);

    var g: FourNet = undefined;
    const block_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    g.setupBoard(.{
        .ref_des = "BLK",
        .kind = .passive,
        .hw = 1,
        .hh = 1.5,
        .pads = &block_pad,
        .fallback = false,
        .x = 5,
        .y = 0,
    });
    const tight = try plan(arena_i.allocator(), g.placement(g.parts[0..6]), .{ .nets = &all_four });
    // Cuts nearer the hub are wide open and are scanned FIRST; the constriction
    // at x ∈ [4, 6] still wins, because it is the tightest cut that fits four.
    try testing.expect(open.corridor.cut > 8);
    try testing.expect(tight.corridor.cut >= 3.5 and tight.corridor.cut <= 6.5);
    try testing.expect(tight.schedule.lanes.len >= all_four.len);
}

// spec: placement/escape-assign - every contended net gets its own lane, in the order its endpoints already imply, so no two assignments cross
test "the joint assignment is monotone and shares no lane" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    const block_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    f.setupBoard(.{
        .ref_des = "BLK",
        .kind = .passive,
        .hw = 1,
        .hh = 1.5,
        .pads = &block_pad,
        .fallback = false,
        .x = 5,
        .y = 0,
    });
    const p = try plan(arena_i.allocator(), f.placement(f.parts[0..6]), .{ .nets = &all_four });
    try testing.expectEqual(@as(usize, 4), p.schedule.assignments.len);
    var prev_ideal = -std.math.inf(f64);
    var prev_lane: ?usize = null;
    for (p.schedule.assignments) |a| {
        try testing.expect(a.lane != null);
        try testing.expect(a.fit.ideal >= prev_ideal);
        if (prev_lane) |k| try testing.expect(a.lane.? > k);
        prev_ideal = a.fit.ideal;
        prev_lane = a.lane;
    }
}

// spec: placement/escape-assign - a corridor with fewer lanes than nets leaves the worst-fitting nets unassigned instead of doubling one up
test "an over-subscribed corridor drops nets rather than sharing a lane" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    const block_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    // A wall spanning the WHOLE scan band, so no cross-section fits four nets.
    f.setupBoard(.{
        .ref_des = "WALL",
        .kind = .passive,
        .hw = 4,
        .hh = 3.5,
        .pads = &block_pad,
        .fallback = false,
        .x = 5,
        .y = 0,
    });
    const p = try plan(arena_i.allocator(), f.placement(f.parts[0..6]), .{ .nets = &all_four });
    try testing.expect(p.ok);
    try testing.expectEqual(@as(usize, 2), p.schedule.lanes.len);
    var placed: usize = 0;
    var seen = [_]bool{ false, false };
    for (p.schedule.assignments) |a| {
        const lane = a.lane orelse continue;
        placed += 1;
        try testing.expect(!seen[lane]);
        seen[lane] = true;
    }
    try testing.expectEqual(@as(usize, 2), placed);
}

// spec: placement/escape-assign - each assignment lowers to one soft per-net lane guide that starts clear of the hub's own pads
test "assignments lower to per-net guide tracks on the escape layer" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: FourNet = undefined;
    f.setupBoard(null);
    const p = try plan(arena, f.placement(f.parts[0..5]), .{ .nets = &all_four });
    const tracks = try guideTracks(arena, p, 1.0);
    // One segment per assigned net: its lane, and nothing crossing J1's pads.
    try testing.expectEqual(@as(usize, 4), tracks.len);
    for (&all_four) |net_i| {
        var lane: ?route_policy.GuideTrack = null;
        for (tracks) |t| {
            if (t.net == @as(i32, @intCast(net_i))) lane = t;
        }
        try testing.expect(lane != null);
        try testing.expectEqual(@as(u8, 0), lane.?.layer);
        try testing.expectApproxEqAbs(p.corridor.cut, lane.?.x1, 1e-9);
        try testing.expect(lane.?.x2 < lane.?.x1); // the lane heads west, out of J1
        try testing.expect(lane.?.x1 < 9); // …and starts clear of J1's courtyard
    }
}

// spec: placement/escape-assign - a roomy corridor is thinned to a few more lanes than the contended set, so the assignment spreads instead of packing at minimum pitch
test "a roomy corridor spreads the set instead of packing it" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    f.setupBoard(null);
    const p = try plan(arena_i.allocator(), f.placement(f.parts[0..5]), .{ .nets = &all_four });
    // The 10 mm span holds 10 lanes at the 1 mm pitch; four nets keep six.
    try testing.expectEqual(all_four.len + lane_slack, p.schedule.lanes.len);
    // Neighbouring lanes stay a whole pitch apart, spanning the free width…
    try testing.expect(p.schedule.lanes[p.schedule.lanes.len - 1].pos - p.schedule.lanes[0].pos >= 4.0);
    // …and the assignment still lands every net on a lane of its own.
    for (p.schedule.assignments) |a| try testing.expect(a.lane != null);
}

// spec: placement/escape-assign - an empty or single-net request assigns nothing
test "fewer than two contended nets is not an assignment problem" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    f.setupBoard(null);
    const one = [_]usize{0};
    const p = try plan(arena_i.allocator(), f.placement(f.parts[0..5]), .{ .nets = &one });
    try testing.expect(!p.ok);
    try testing.expectEqual(@as(usize, 0), (try guideTracks(arena_i.allocator(), p, 1.0)).len);
}

// spec: placement/escape-assign - assigning the same board twice yields the identical corridor, lanes and assignment
test "the assignment is deterministic" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: FourNet = undefined;
    const block_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    f.setupBoard(.{
        .ref_des = "BLK",
        .kind = .passive,
        .hw = 1,
        .hh = 1.5,
        .pads = &block_pad,
        .fallback = false,
        .x = 5,
        .y = 0,
    });
    const placement = f.placement(f.parts[0..6]);
    const first = try plan(arena, placement, .{ .nets = &all_four });
    const again = try plan(arena, placement, .{ .nets = &all_four });
    try testing.expectEqual(first.corridor.cut, again.corridor.cut);
    try testing.expectEqual(first.schedule.lanes.len, again.schedule.lanes.len);
    for (first.schedule.assignments, again.schedule.assignments) |a, b| {
        try testing.expectEqual(a.net, b.net);
        try testing.expectEqual(a.lane, b.lane);
    }
}

/// A synthetic BIMODAL escape: connector `J1` on the east, four nets whose
/// destinations line up in a tight cluster plus one far below them, and two
/// walls across the corridor that leave the cross-section with a NEAR band of
/// three lanes (fewer than the four nets that want it) and a FAR band 3 mm
/// across a void. Track pitch is 0.25 mm, so the arithmetic in the tests below
/// is exact: lanes at -0.25 / 0 / 0.25 near, 3.3375 … 5.0875 far.
const blank_pad: geometry.Pad = .{ .number = "", .x = 0, .y = 0, .w = 0, .h = 0 };
const blank_part: optimizer.Part = .{
    .ref_des = "",
    .kind = .passive,
    .hw = 0,
    .hh = 0,
    .pads = &.{},
    .fallback = false,
};
const blank_pin: flat_netlist.FlatPin = .{ .ref_des = "", .pin = "" };
const blank_net: optimizer.FlatNet = .{ .name = "", .pins = &.{} };

const Bimodal = struct {
    parts: [8]optimizer.Part = @splat(blank_part),
    hub_pads: [5]geometry.Pad = @splat(blank_pad),
    leg: [1]geometry.Pad = .{blank_pad},
    nets: [5]optimizer.FlatNet = @splat(blank_net),
    pins: [5][2]flat_netlist.FlatPin = @splat(.{ blank_pin, blank_pin }),

    /// Hub-pad (and destination) lane-axis positions. The last is the outlier
    /// whose ideal crossing lands far below every band.
    const ys = [_]f64{ -0.3, -0.1, 0.1, 0.3, -4.0 };

    fn setupBoard(self: *Bimodal, tail: f64) void {
        self.leg = .{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
        for (ys, 0..) |y, i| {
            const at = if (i + 1 == ys.len) tail else y;
            self.hub_pads[i] = .{ .number = padName5(i), .x = -0.5, .y = at, .w = 0.2, .h = 0.2 };
            self.parts[i + 1] = .{
                .ref_des = destName5(i),
                .kind = .passive,
                .hw = 0.5,
                .hh = 0.5,
                .pads = &self.leg,
                .fallback = false,
                .x = -10,
                .y = at,
            };
            self.pins[i] = .{
                .{ .ref_des = "J1", .pin = padName5(i) },
                .{ .ref_des = destName5(i), .pin = "1" },
            };
            self.nets[i] = .{ .name = netName5(i), .pins = &self.pins[i] };
        }
        self.parts[0] = .{
            .ref_des = "J1",
            .kind = .hub,
            .hw = 1,
            .hh = 5,
            .pads = &self.hub_pads,
            .fallback = false,
            .x = 10,
            .y = 0,
        };
        // Two walls across the whole cut scan: one below (y <= -0.5) and one
        // above with a 3 mm gap over it (0.5 <= y <= 3.0), so the free space is
        // a narrow near band plus a far band across a void.
        self.parts[6] = wall("LOW", -4.75, 4.25, &self.leg);
        self.parts[7] = wall("MID", 1.75, 1.25, &self.leg);
    }

    fn placement(self: *Bimodal) optimizer.Placement {
        return .{
            .parts = &self.parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &self.nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = -11,
            .miny = -10,
            .maxx = 11,
            .maxy = 10,
            .generated = true,
            .rules = .{ .design = .{ .track_width = 0.1, .clearance = 0.15 } },
        };
    }
};

fn wall(ref: []const u8, y: f64, hh: f64, pads: []const geometry.Pad) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 4, .hh = hh, .pads = pads, .fallback = false, .x = 5, .y = y };
}

fn padName5(i: usize) []const u8 {
    return ([_][]const u8{ "1", "2", "3", "4", "5" })[i];
}
fn destName5(i: usize) []const u8 {
    return ([_][]const u8{ "R1", "R2", "R3", "R4", "R5" })[i];
}
fn netName5(i: usize) []const u8 {
    return ([_][]const u8{ "A", "B", "C", "D", "E" })[i];
}

const all_five = [_]usize{ 0, 1, 2, 3, 4 };

/// Refusal reasons tallied over an unassigned list, plus how many of a full
/// assignment list actually got a lane.
const Tally = struct { assigned: usize = 0, out_of_band: usize = 0, no_lane: usize = 0 };

fn tally(assignments: []const Assignment) Tally {
    var t: Tally = .{};
    for (assignments) |a| {
        if (a.lane != null) t.assigned += 1;
        if (a.fit.refusal == .out_of_band) t.out_of_band += 1;
        if (a.fit.refusal == .no_lane) t.no_lane += 1;
    }
    return t;
}

// spec: placement/escape-assign - each contiguous free band of the cross-section is scheduled on its own, so no net is dragged across the void between bands
test "a bimodal corridor schedules each band on its own instead of across the void" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: Bimodal = .{};
    f.setupBoard(Bimodal.ys[4]);
    const p = try plan(arena_i.allocator(), f.placement(), .{ .nets = &all_five });
    try testing.expect(p.ok);
    // Two bands: the near one holds three lanes, the far one starts 3 mm up.
    try testing.expectEqual(@as(usize, 2), bandCount(p.schedule.lanes));
    // Four nets want the three-lane near band and one sits far below every
    // band, so exactly three are scheduled and both refusals are named.
    const t = tally(p.schedule.assignments);
    try testing.expectEqual(@as(usize, 3), t.assigned);
    try testing.expectEqual(@as(usize, 1), t.out_of_band);
    try testing.expectEqual(@as(usize, 1), t.no_lane);
    try testing.expectEqual(@as(usize, 2), p.schedule.unassigned.len);
    // Every assigned net stays in the NEAR band, within the corridor's cap of
    // its own ideal — nothing is exiled across the void to reach a free lane.
    for (p.schedule.assignments) |a| {
        const k = a.lane orelse continue;
        try testing.expectEqual(@as(usize, 0), p.schedule.lanes[k].band);
        try testing.expect(a.fit.offset <= p.corridor.cap);
        try testing.expectEqual(Refusal.none, a.fit.refusal);
    }
}

// spec: placement/escape-assign - the displacement cap is measured in the lane spacings one band offers, never across the gap between two bands
test "the displacement cap never counts the gap between bands as spacing" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    // Two bands of three lanes at 0.25 mm, six millimetres apart.
    const lanes = [_]Lane{
        .{ .pos = 0.00, .x = 0, .y = 0.00, .band = 0 },
        .{ .pos = 0.25, .x = 0, .y = 0.25, .band = 0 },
        .{ .pos = 0.50, .x = 0, .y = 0.50, .band = 0 },
        .{ .pos = 6.50, .x = 0, .y = 6.50, .band = 1 },
        .{ .pos = 6.75, .x = 0, .y = 6.75, .band = 1 },
        .{ .pos = 7.00, .x = 0, .y = 7.00, .band = 1 },
    };
    const bands = try bandsOf(arena_i.allocator(), &lanes);
    try testing.expectEqual(@as(usize, 2), bands.len);
    // Each band is 0.5 mm wide, so four nets plus slack could be spread at
    // 0.5/5 = 0.1 mm — under the 0.25 mm pitch, which therefore floors the
    // spacing and makes the cap five pitches.
    const cap = displacementCap(&lanes, bands, 0.25, 4);
    try testing.expectApproxEqAbs(@as(f64, 1.25), cap, 1e-9);
    // The 6 mm void between the two bands is nowhere in that number.
    try testing.expect(cap < lanes[3].pos - lanes[2].pos);
}

// spec: placement/escape-assign - a net whose ideal crossing is farther than the displacement cap from every band is refused rather than moved onto a lane it never wanted
test "the displacement cap admits a net just inside it and refuses one just outside" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pair = [_]usize{ 0, 4 };

    // One band of three lanes at -0.25 / 0 / 0.25 and a 0.25 mm spacing, so the
    // cap is exactly 5 x 0.25 = 1.25 mm off the band's nearest lane.
    var inside: Bimodal = .{};
    inside.setupBoard(-1.49);
    const near = try plan(arena, inside.placement(), .{ .nets = &pair });
    try testing.expect(near.ok);
    try testing.expectApproxEqAbs(@as(f64, 1.25), near.corridor.cap, 1e-9);
    for (near.schedule.assignments) |a| try testing.expect(a.fit.refusal != .out_of_band);
    try testing.expectEqual(@as(usize, 0), near.schedule.unassigned.len);

    var outside: Bimodal = .{};
    outside.setupBoard(-1.51);
    const far = try plan(arena, outside.placement(), .{ .nets = &pair });
    try testing.expect(far.ok);
    try testing.expectApproxEqAbs(@as(f64, 1.25), far.corridor.cap, 1e-9);
    try testing.expectEqual(@as(usize, 1), far.schedule.unassigned.len);
    try testing.expectEqual(Refusal.out_of_band, far.schedule.unassigned[0].fit.refusal);
    try testing.expect(far.schedule.unassigned[0].fit.offset > far.corridor.cap);
}

// spec: placement/escape-assign - a refused net contributes no guide track, so it routes exactly as it does with no assignment authored
test "refused nets emit no guide track" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: Bimodal = .{};
    f.setupBoard(Bimodal.ys[4]);
    const p = try plan(arena, f.placement(), .{ .nets = &all_five });
    const tracks = try guideTracks(arena, p, guide_run_mm);
    try testing.expectEqual(p.schedule.assignments.len - p.schedule.unassigned.len, tracks.len);
    for (p.schedule.unassigned) |a| {
        for (tracks) |t| try testing.expect(t.net != @as(i32, @intCast(a.net)));
    }
}

// spec: placement/escape-assign - a bimodal corridor's refusals and band assignments are identical on a second run
test "the band-aware assignment is deterministic" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: Bimodal = .{};
    f.setupBoard(Bimodal.ys[4]);
    const first = try plan(arena, f.placement(), .{ .nets = &all_five });
    const again = try plan(arena, f.placement(), .{ .nets = &all_five });
    try testing.expectEqual(first.corridor.cut, again.corridor.cut);
    try testing.expectEqual(first.corridor.cap, again.corridor.cap);
    try testing.expectEqual(first.schedule.lanes.len, again.schedule.lanes.len);
    try testing.expectEqual(first.schedule.unassigned.len, again.schedule.unassigned.len);
    for (first.schedule.assignments, again.schedule.assignments) |a, b| {
        try testing.expectEqual(a.net, b.net);
        try testing.expectEqual(a.lane, b.lane);
        try testing.expectEqual(a.fit.refusal, b.fit.refusal);
        try testing.expectEqual(a.fit.offset, b.fit.offset);
    }
}

// spec: placement/escape-assign - no lane is offered outside the design's declared board outline, where no copper can go
test "the declared board outline bounds the lanes, not the placement bounding box" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: FourNet = undefined;
    f.setupBoard(null);
    var p = f.placement(f.parts[0..5]);
    const bbox = try plan(arena, p, .{ .nets = &all_four });

    // Same board, now declaring an outline narrower than the parts' own extent
    // (a part hanging over the edge is exactly how board-a's escape came to
    // offer a band 2 mm past its own board edge).
    p.board_rect = .{ .minx = -11, .miny = -3, .w = 22, .h = 6 };
    const clipped = try plan(arena, p, .{ .nets = &all_four });
    try testing.expect(clipped.corridor.hi < bbox.corridor.hi);
    for (clipped.schedule.lanes) |lane| {
        try testing.expect(lane.pos >= -3 and lane.pos <= 3);
    }
}

// spec: placement/escape-assign - every hub side whose escape fan the corridor cannot seat is found with no assignment form authored
test "detection finds the contended fan on a bimodal escape" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: Bimodal = .{};
    f.setupBoard(Bimodal.ys[4]);
    const placement = f.placement();
    const cache = try DetectCache.build(arena, placement);
    // Each net appears exactly once for the hub it touches. Non-hub parts have
    // no detection row, so a pose round never revisits unrelated board nets.
    try testing.expectEqualSlices(usize, &all_five, cache.hub_nets[0]);
    for (cache.hub_nets[1..]) |nets| try testing.expectEqual(@as(usize, 0), nets.len);
    const found = try detectCached(arena, placement, .{}, cache);
    try testing.expectEqual(@as(usize, 1), found.len);
    const c = found[0];
    try testing.expectEqualStrings("J1", c.hub);
    try testing.expectEqual(Direction.west, c.corridor.dir);
    // All five nets leave west; the near band seats three and the far band is
    // across a void, so two are refused — the shortfall a flat lane count misses.
    try testing.expectEqual(@as(usize, 5), c.nets.len);
    try testing.expectEqual(@as(usize, 3), c.seated);
    try testing.expectEqual(@as(usize, 2), c.refused());
    try testing.expectEqual(@as(usize, 2), c.bands);
    try testing.expect(c.lanes >= c.seated);
}

// spec: placement/escape-assign - an escape fan the corridor seats in full is not reported as contended
test "detection stays silent on a corridor that seats its whole fan" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    f.setupBoard(null);
    const p = f.placement(f.parts[0..5]);
    // The same board the assignment lands every net on (see the spread test).
    const assigned = try plan(arena_i.allocator(), p, .{ .nets = &all_four });
    try testing.expectEqual(@as(usize, 0), assigned.schedule.unassigned.len);
    try testing.expectEqual(@as(usize, 0), (try detect(arena_i.allocator(), p, .{})).len);
}

// spec: placement/escape-assign - a fan every net of which an authored assignment already covers is not detected again
test "detection skips a fan an authored assignment already covers" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: Bimodal = .{};
    f.setupBoard(Bimodal.ys[4]);
    const covered: [5]bool = @splat(true);
    try testing.expectEqual(@as(usize, 0), (try detect(arena, f.placement(), .{ .assigned = &covered })).len);
    // …and a wave covering only PART of the fan leaves the rest worth saying.
    const partial = [_]bool{ true, true, false, false, false };
    try testing.expectEqual(@as(usize, 1), (try detect(arena, f.placement(), .{ .assigned = &partial })).len);
}

// spec: placement/escape-assign - a detected fan renders as a paste-ready assign-escapes wave naming its own nets, hub and layer
test "a detected fan renders as one pasteable assign-escapes wave" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: Bimodal = .{};
    f.setupBoard(Bimodal.ys[4]);
    const p = f.placement();
    const found = try detect(arena, p, .{});
    const dsl = try suggestDsl(arena, p, found[0]);
    try testing.expect(std.mem.indexOf(u8, dsl, "(wave \"escape-J1-west\"") != null);
    try testing.expect(std.mem.indexOf(u8, dsl, "(nets \"A\" \"B\" \"C\" \"D\" \"E\")") != null);
    try testing.expect(std.mem.indexOf(u8, dsl, "(assign-escapes \"F.Cu\" \"J1\")") != null);
}

// spec: placement/escape-assign - a plane-carried net is never part of an escape fan, because it rejoins through the pour instead of taking a lane
test "detection leaves a plane-carried net out of the fan" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: Bimodal = .{};
    f.setupBoard(Bimodal.ys[4]);
    const all = try detect(arena, f.placement(), .{});
    try testing.expectEqual(@as(usize, 5), all[0].nets.len);

    // Rename the outlier net to a ground: the board declares no `(stackup …)`,
    // so the router's implicit plane carries it and it stops contending for a
    // surface lane — the fan is four nets, and the one it dropped is gone from
    // the suggested wave as well.
    f.nets[4] = .{ .name = "GND", .pins = &f.pins[4] };
    const planed = try detect(arena, f.placement(), .{});
    try testing.expectEqual(@as(usize, 1), planed.len);
    try testing.expectEqual(@as(usize, 4), planed[0].nets.len);
    for (planed[0].nets) |n| try testing.expect(n != 4);
    try testing.expect(std.mem.indexOf(u8, try suggestDsl(arena, f.placement(), planed[0]), "\"GND\"") == null);
}

// spec: placement/escape-assign - detecting the same board twice yields the identical fans in the identical order
test "detection is deterministic" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    var f: Bimodal = .{};
    f.setupBoard(Bimodal.ys[4]);
    const first = try detect(arena, f.placement(), .{});
    const again = try detect(arena, f.placement(), .{});
    try testing.expectEqual(first.len, again.len);
    for (first, again) |a, b| {
        try testing.expectEqualStrings(a.hub, b.hub);
        try testing.expectEqual(a.corridor.dir, b.corridor.dir);
        try testing.expectEqual(a.seated, b.seated);
        try testing.expectEqual(a.lanes, b.lanes);
        try testing.expectEqualSlices(usize, a.nets, b.nets);
    }
}

// spec: placement/escape-assign - a net that reaches the corridor from no hub pad is reported as refused rather than dropped in silence
test "a net with no pad on the hub is reported rather than dropped" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    var f: FourNet = undefined;
    f.setupBoard(null);
    // Rewire the fourth net onto two destinations, so it never touches J1.
    var lone = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    f.nets[3] = .{ .name = "D", .pins = &lone };
    const p = try plan(arena_i.allocator(), f.placement(f.parts[0..5]), .{ .nets = &all_four });
    try testing.expect(p.ok);
    // Every net of the request is accounted for, and the one that never
    // reached the hub says so instead of vanishing from the report.
    try testing.expectEqual(all_four.len, p.schedule.assignments.len);
    try testing.expectEqual(@as(usize, 1), p.schedule.unassigned.len);
    try testing.expectEqual(Refusal.off_hub, p.schedule.unassigned[0].fit.refusal);
    try testing.expectEqual(@as(usize, 3), p.schedule.unassigned[0].net);
}
