//! Per-track electrical width targets for the adaptive power finisher.
//!
//! `power_route_width.adaptiveTargetWidth` answers ONE width for a whole rail:
//! the IPC-2221 width of the entire declared rail current on the worst foil.
//! Growing every segment of the net to that width builds a test-point stub at
//! trunk width — on barracuda's `V_5VA` all 93 segments (123 mm of copper) were
//! sized for 0.42 A while the worst branch actually carried 0.275 A.
//!
//! `power_integrity` already solves the local current of every routed segment
//! by Kirchhoff over the trace/via graph. This module turns that per-track
//! answer into a per-track width target for `pad_neck.adaptPowerTracks`, and
//! keeps the two cases the solve cannot judge on the old whole-rail target:
//! a net whose topology did not solve (`envelope`), and a track the solve did
//! not cover at all (`null`).
//!
//! Widening changes resistance, so it changes how current divides between
//! parallel paths. The pass is therefore allowed to look at the board twice
//! (`solve_passes`): once at the routed floor width, once at the widths it
//! actually achieved, keeping only the larger target. It never iterates to a
//! fixed point — `margin` exists to absorb the residue, and DRC re-solves the
//! final geometry independently.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const power_integrity = @import("power_integrity.zig");
const power_route_width = @import("power_route_width.zig");
const router = @import("router.zig");

const eps: f64 = 1e-9;

/// Headroom over the solved local IPC-2221 width.
///
/// IPC-2221 makes width grow as roughly I^1.38, so 1.25x of width is about 18%
/// of current: enough to cover the redistribution a second solve would find
/// between parallel branches, plus ordinary etch tolerance, without reinstating
/// the whole-rail trunk on a lightly loaded leg. It is deliberately a ratio and
/// not a fixed offset — a 2 A trunk and a 20 mA stub do not need the same
/// absolute reserve.
pub const margin: f64 = 1.25;

/// How many times the board's currents are solved. Widening feeds back into the
/// current split, so the pass looks once at the routed floor width and once at
/// the widths it achieved, then stops: the second look only ever raises a
/// target, so the sequence is monotone and bounded, and `margin` covers what a
/// third look would move.
pub const solve_passes: usize = 2;

/// One track's solved local current requirement.
///
/// `envelope` marks a width the solve could not localize: `width_mm` is then
/// the whole-rail current on that track's own foil, and this pass must fall
/// back to the net-wide target rather than trust it as a branch measurement.
pub const LocalWidth = power_integrity.LocalWidth;

/// The three widths that bound one run's target.
pub const Limits = struct {
    /// Fabrication-legal centreline the router actually searched.
    floor: f64,
    /// Authored `power_branch_width` class minimum, 0 when unset.
    branch_floor: f64,
    /// Today's whole-rail target from `power_route_width.adaptiveTargetWidth`.
    net_target: f64,
};

/// Width one run should grow toward.
///
/// A solved local current sizes the run; an unsolved (`envelope`) or uncovered
/// (`null`) run keeps the whole-rail target, because those are exactly the
/// cases where a narrower answer would not be backed by a measurement. A run
/// carrying no current at all — a test-point stub, an unloaded connector leg —
/// stays at the fabrication floor and its class branch minimum.
///
/// `(power-branch-width MM)` is the opt-in, and `branch_floor` carries it. A
/// class that never declared one asked for its authored width on every segment
/// of the net, and gets it: a solved branch current is an argument for narrower
/// copper, not a licence to overrule the geometry the board author wrote down.
/// This is the same boundary the reporting DRC draws, so the copper this pass
/// lays and the copper DRC demands stay one rule.
///
/// The solved term is capped at `net_target` so this pass is never wider than
/// the behaviour it replaces; the class branch minimum is not capped, because
/// an authored floor outranks both.
pub fn targetFor(limits: Limits, local: ?LocalWidth) f64 {
    const bare = @max(limits.floor, limits.branch_floor);
    const whole_rail = @max(bare, limits.net_target);
    const solved = local orelse return whole_rail;
    if (solved.envelope) return whole_rail;
    if (!(solved.width_mm > 0)) return bare;
    return @max(bare, @min(limits.net_target, solved.width_mm * margin));
}

/// What one net contributes to the target of each of its tracks.
pub const NetLimits = struct {
    limits: Limits = .{ .floor = 0, .branch_floor = 0, .net_target = 0 },
    /// This net is an unpoured current-rated rail: the finisher owns its width
    /// and must still configure the route context for it, even when nothing on
    /// it can grow.
    candidate: bool = false,
    /// Something on this net can actually grow.
    active: bool = false,
};

/// Resolve every net's routing floor, class branch minimum, and whole-rail
/// target in one sweep.
///
/// This sweep must not touch the route context. Configuring it per net is what
/// `CleanupBoard.beginNet` is for, and reaching for it out of band here — even
/// through `setNetParams` alone, which reads like a pure query of the
/// parameters — clears per-net route policy (`ctx.rf.escape_pts`) that only the
/// normal route path repopulates. The floor is therefore resolved from the
/// placement instead, against the route request's own base width.
pub fn netLimits(board: router.CleanupBoard) std.mem.Allocator.Error![]const NetLimits {
    const placement = board.placement;
    const out = try board.arena().alloc(NetLimits, placement.nets.len);
    for (out, 0..) |*slot, net_i| {
        slot.* = .{};
        if (!board.enabled(net_i)) continue;
        const net_target = board.adaptivePowerWidth(net_i) orelse continue;
        const floor = power_route_width.adaptiveFloorWidth(placement, net_i, board.ctx.base.track_width);
        slot.* = .{
            .limits = .{
                .floor = floor,
                .branch_floor = if (net_i < placement.rules.net.len)
                    placement.rules.net[net_i].pad_neck.power_branch_width
                else
                    0,
                .net_target = net_target,
            },
            .candidate = true,
            .active = net_target > floor + eps,
        };
    }
    return out;
}

/// The limits one track is shaped under, or null when this pass does not own
/// its width: a signal net, a rail that cannot grow, or copper already wider
/// than the routed floor (authored geometry, or an earlier pass's output).
pub fn trackLimits(limits: []const NetLimits, track: router.Track) ?Limits {
    if (track.net < 0) return null;
    const net_i: usize = @intCast(track.net);
    if (net_i >= limits.len or !limits[net_i].active) return null;
    if (track.width > limits[net_i].limits.floor + router.clearance_eps) return null;
    return limits[net_i].limits;
}

/// True when some rail in scope can be grown at all — a net with a declared
/// current demand and a routed floor below its whole-rail target.
///
/// Every such rail is sized per segment by its own solved current; the
/// `(power-branch-width MM)` class value is only the floor a branch may neck
/// down to, never the switch. A board with no current-rated rail keeps the
/// exact path, allocations included, that it had before per-track targets
/// existed, because the Kirchhoff solve has nothing to judge there.
pub fn wantsBranchSizing(limits: []const NetLimits) bool {
    for (limits) |net| {
        if (net.active) return true;
    }
    return false;
}

/// Width target for every track on the board, 0 where this pass owns nothing.
/// Index-aligned with `board.tracks` as it stands on entry. Call only when
/// `wantsBranchSizing` is true.
///
/// This is where the two solves of `solve_passes` happen, before any copper is
/// reshaped. The second is skipped outright when the first left every active net
/// uniform: identical widths divide current exactly as the routed floor did, so
/// re-solving could not move.
pub fn boardTargets(
    board: router.CleanupBoard,
    limits: []const NetLimits,
) std.mem.Allocator.Error![]f64 {
    const arena = board.arena();
    const tracks = board.tracks.items;
    const targets = try arena.alloc(f64, tracks.len);
    @memset(targets, 0);
    const first = try solveLocalWidths(arena, board.placement, tracks, board.vias.items);
    var narrowed = false;
    for (tracks, targets, 0..) |track, *slot, index| {
        const lim = trackLimits(limits, track) orelse continue;
        slot.* = targetFor(lim, at(first, index));
        if (slot.* < lim.net_target - eps) narrowed = true;
    }
    if (!narrowed) return targets;

    // Copper this pass widens carries less resistance and therefore draws more
    // of a parallel split than it did at the floor. Re-solve against the widths
    // about to be applied and keep the larger target, `solve_passes` times in
    // total. Bounded there on purpose: routed power copper is a tree in every
    // case this pass can touch (a plane- or pour-carried rail keeps exact
    // geometry and never reaches here), and a tree divides current
    // independently of width, so a further look moves only the rare loop.
    // `margin` absorbs its residue, and DRC re-solves the finished geometry on
    // its own.
    const widened = try arena.alloc(router.Track, tracks.len);
    for (1..solve_passes) |_| {
        for (tracks, targets, widened) |track, target, *slot| {
            slot.* = track;
            if (target > 0) slot.width = @max(track.width, target);
        }
        const again = try solveLocalWidths(arena, board.placement, widened, board.vias.items);
        for (tracks, targets, 0..) |track, *slot, index| {
            if (!(slot.* > 0)) continue;
            const lim = trackLimits(limits, track) orelse continue;
            slot.* = @max(slot.*, targetFor(lim, at(again, index)));
        }
    }
    return targets;
}

fn at(local: []const ?LocalWidth, index: usize) ?LocalWidth {
    return if (index < local.len) local[index] else null;
}

/// Per-track solved local widths, index-aligned with `tracks`.
///
/// Null entries are tracks the current solve does not cover (signal nets, and
/// nets with no declared rail demand).
pub fn solveLocalWidths(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
) std.mem.Allocator.Error![]const ?LocalWidth {
    const routed = router.RouteResult{
        .tracks = tracks,
        .vias = vias,
        .routed = 0,
        .total = 0,
    };
    // The router holds no pour-fill memo, so this is the unmemoised spelling.
    const raw = try power_integrity.routedTrackRequiredWidthsMemo(alloc, placement, routed, null);
    return raw;
}

const testing = std.testing;

// spec: placement/power-routing - a routed power segment on a class that opted into branch sizing is widened for the current its own branch carries, not for the whole rail, while an unsolved branch, an uncovered segment, and every class that never opted in keep the whole-rail target
test "per-track power target follows the solved branch current" {
    const limits = Limits{ .floor = 0.127, .branch_floor = 0.2, .net_target = 0.42 };

    // A solved branch narrower than the rail: sized by its own current.
    try testing.expectApproxEqAbs(
        @as(f64, 0.3 * margin),
        targetFor(limits, .{ .width_mm = 0.3, .envelope = false }),
        1e-12,
    );
    // The solved term never exceeds the whole-rail target it replaces.
    try testing.expectApproxEqAbs(
        @as(f64, 0.42),
        targetFor(limits, .{ .width_mm = 0.4, .envelope = false }),
        1e-12,
    );
    // An unsolved net keeps today's whole-rail target.
    try testing.expectApproxEqAbs(
        @as(f64, 0.42),
        targetFor(limits, .{ .width_mm = 0.3, .envelope = true }),
        1e-12,
    );
    // So does a track the solve does not cover at all.
    try testing.expectApproxEqAbs(@as(f64, 0.42), targetFor(limits, null), 1e-12);
    // A zero-current stub stays at the fabrication floor and class minimum.
    try testing.expectApproxEqAbs(
        @as(f64, 0.2),
        targetFor(limits, .{ .width_mm = 0, .envelope = false }),
        1e-12,
    );
    // A stub whose class branch minimum is the fabrication floor lands there.
    try testing.expectApproxEqAbs(
        @as(f64, 0.127),
        targetFor(.{ .floor = 0.127, .branch_floor = 0.1, .net_target = 0.42 }, .{ .width_mm = 0, .envelope = false }),
        1e-12,
    );
    // An authored class minimum outranks a smaller solved requirement.
    try testing.expectApproxEqAbs(
        @as(f64, 0.2),
        targetFor(limits, .{ .width_mm = 0.05, .envelope = false }),
        1e-12,
    );
    // A class that never declared `(power-branch-width MM)` is sized by its
    // solved current all the same: the class value is only the floor a branch
    // may neck down to, so without one the fabrication floor is the bare width.
    const unopted = Limits{ .floor = 0.127, .branch_floor = 0, .net_target = 0.2532 };
    try testing.expectApproxEqAbs(
        @as(f64, 0.127),
        targetFor(unopted, .{ .width_mm = 0, .envelope = false }),
        1e-12,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 0.127),
        targetFor(unopted, .{ .width_mm = 0.05, .envelope = false }),
        1e-12,
    );
    try testing.expectApproxEqAbs(
        @as(f64, 0.2532),
        targetFor(unopted, .{ .width_mm = 0.30, .envelope = true }),
        1e-12,
    );
}
