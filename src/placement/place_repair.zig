//! Turn a placement pinch into a legal micro-move, or say why there isn't one.
//!
//! `pinch_probe` answers "which two bodies leave this channel no room, and how
//! much room is missing". That is a measurement; this is the decision that
//! follows it — WHICH of the two bodies may move, WHICH WAY, HOW FAR, and
//! whether the resulting pose is one the placement model still accepts.
//!
//! The whole module is deliberately timid, because a placement move is the most
//! expensive edit an engine can make: it invalidates every routed net that
//! touches the part and it changes a board a human may already have reviewed.
//! Three rules keep it that way.
//!
//! * **Only a movable passive moves.** A hub IC anchors its whole subsystem, an
//!   RF-fenced or `(near …)`-bound or `(decouples …)`-bound part was placed
//!   where it is ON PURPOSE, a diff-pair member IS the geometry under
//!   discussion, and a locked part is a human's explicit "do not touch". Each of
//!   those is refused BY NAME rather than skipped, so a pass that moves nothing
//!   still says what it looked at.
//! * **The move is the shortfall and no more.** The translation is the pinch's
//!   own `need − have` plus one margin, along the axis away from the body on the
//!   far side of the wall, snapped outward onto the pose grid. It never widens a
//!   channel "while we are here", and a shortfall past `max_move_mm` is refused
//!   rather than half-satisfied.
//! * **The trial pose is judged by the model that already exists.** Courtyard
//!   overlaps (`optimizer.overlapCount`), the board outline, and the layout lint
//!   (`layout_lint`) all get their say, and any of them worsening rejects the
//!   move. Nothing here invents a new placement rule.
//!
//! Whether a legal move actually HELPS is not a question this module answers.
//! It plans; the caller routes and keeps or discards on the count. Deterministic
//! throughout: no clock, no RNG, and every candidate walked in placement order.

const std = @import("std");
const layout_lint = @import("layout_lint.zig");
const module_policy = @import("module_policy.zig");
const near_bind = @import("near_bind.zig");
const optimizer = @import("optimizer.zig");
const pinch_probe = @import("pinch_probe.zig");
const pose_math = @import("pose_math.zig");
const router = @import("router.zig");
const keepout = @import("keepout.zig");
const net_name = @import("../net_name.zig");

/// Furthest a repair may translate one part. Past this the pinch is not a
/// near-miss any more — it is a different arrangement, and proposing one from a
/// single wall measurement would be a guess dressed as a computation.
pub const max_move_mm: f64 = 3.0;

/// Pose granularity a computed move snaps to, matching the 0.01 mm the board
/// sidecar and the KiCad sync round-trip poses at — so a move survives the trip
/// through both without drifting into a coordinate neither can spell.
pub const pose_grid_mm: f64 = 0.01;

/// Extra clearance a move buys on top of the measured shortfall, so the widened
/// channel is not exactly at its own limit (where a rounding difference between
/// the probe's mesh and the router's gate decides the board).
pub const move_margin_mm: f64 = 0.10;

/// Why a pinch produced no move. Every one of these is reported: a repair pass
/// that declines silently is indistinguishable from one that never ran.
pub const Why = enum {
    /// The wall is copper or a keepout, not a pad — nothing to move.
    not_a_part,
    /// A single body spans the wall: there is no gap between two things.
    one_sided_wall,
    /// Both sides of the wall are pads of the SAME part. A part is rigid, so
    /// translating it carries both pads and the gap between them is unchanged.
    same_part,
    /// A hub IC. It anchors the subsystem the passives are placed around.
    hub,
    /// Not an R/C/L/ferrite/diode two-terminal part.
    not_passive,
    /// The viewer's explicit lock.
    locked,
    /// On a net carrying an authored RF keepout halo or via fence.
    rf_fenced,
    /// Carries an authored `(near "REF" PIN)` adjacency.
    near_bound,
    /// A declared differential-pair member.
    pair_member,
    /// The shortfall is further than `max_move_mm`.
    too_far,
    /// The two bodies share a centre, so no widening direction exists.
    no_axis,
    /// The trial pose collides with another part's courtyard.
    overlaps,
    /// The trial pose leaves the declared board outline.
    off_board,
    /// The trial pose introduces a layout-lint finding the current one lacks.
    lint_regressed,

    /// One sentence a reader can act on: what stood in the way of moving this
    /// candidate, in the design's own vocabulary rather than the pass's.
    pub fn text(self: Why) []const u8 {
        return switch (self) {
            .not_a_part => "the wall is copper or a keepout, not a pad",
            .one_sided_wall => "one body spans the wall — no gap to widen",
            .same_part => "both sides of the wall are pads of one rigid part",
            .hub => "a hub IC anchors its subsystem",
            .not_passive => "not a movable two-terminal passive",
            .locked => "locked in the editor",
            .rf_fenced => "on an RF-fenced net",
            .near_bound => "carries an authored (near …) adjacency",
            .pair_member => "a declared diff-pair member",
            .too_far => "the shortfall is further than a micro-move",
            .no_axis => "the two bodies share a centre, so there is no widening direction",
            .overlaps => "the trial pose overlaps another courtyard",
            .off_board => "the trial pose leaves the board outline",
            .lint_regressed => "the trial pose adds a layout-lint finding",
        };
    }
};

/// One channel a repair pass is trying to open.
pub const Aim = struct {
    /// What a reader calls it — a net name, or "P/N" for a pair.
    label: []const u8,
    /// The net whose own pads are transparent to its own channel.
    net: i32,
    ends: pinch_probe.Ends,
    /// The copper profile the channel must hold.
    width: f64,
    clearance: f64,
    /// Copper the probe must see, if the caller has routed already. Empty asks
    /// the pure placement question (see `pinch_probe.Ask`).
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
};

/// One accepted translation.
pub const Move = struct {
    part: usize,
    ref: []const u8,
    from: [2]f64,
    to: [2]f64,
    /// The channel this move is opening.
    label: []const u8,
    have_mm: f64,
    need_mm: f64,

    /// How far the part travels.
    pub fn distMm(self: Move) f64 {
        return std.math.hypot(self.to[0] - self.from[0], self.to[1] - self.from[1]);
    }
};

/// One candidate the pass looked at and turned down.
pub const Refusal = struct {
    label: []const u8,
    /// The part, when there was one to name.
    ref: []const u8 = "",
    why: Why,
};

/// A pinch as the pass reports it, with both sides named.
pub const Finding = struct {
    label: []const u8,
    pinch: pinch_probe.Pinch,
    a_ref: []const u8 = "",
    b_ref: []const u8 = "",
};

/// What one repair pass computed, before anything is routed.
pub const Plan = struct {
    findings: []const Finding = &.{},
    moves: []const Move = &.{},
    refusals: []const Refusal = &.{},
};

/// How much a pass is allowed to do.
pub const Limits = struct {
    /// Most parts one invocation may move. Three is the campaign's own bound:
    /// enough for a pinch whose two sides both need to give, few enough that a
    /// discarded trial is one route away from being undone.
    max_moves: usize = 3,
};

/// Probe every aim, and for each pinch compute the one micro-move that opens it.
///
/// The placement is READ, never written — an accepted move is returned as a
/// pose the caller applies to its own copy. Validation runs against the moves
/// already accepted in this same plan, so two moves can never be individually
/// legal and jointly overlapping.
pub fn plan(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    aims: []const Aim,
    limits: Limits,
) std.mem.Allocator.Error!Plan {
    var findings: std.ArrayList(Finding) = .empty;
    var moves: std.ArrayList(Move) = .empty;
    var refusals: std.ArrayList(Refusal) = .empty;
    // Scratch for the probes and the validation trials. It is worth its own
    // arena because a probe triangulates a whole navmesh per aim and a
    // validation duplicates the pose slice per candidate — none of which the
    // caller ever sees. Only the three returned lists come from `alloc`, and
    // every string in them points at the placement's or the aim's own memory.
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const sa = scratch.allocator();
    // The poses every trial is judged against: the board as it stands, plus the
    // moves this plan has already accepted.
    const trial = try sa.dupe(optimizer.Part, placement.parts);
    var staged = placement;
    staged.parts = trial;
    const guard = try Guard.of(sa, placement);

    for (aims) |aim| {
        if (moves.items.len >= limits.max_moves) break;
        // One probe, one mesh, released before the next aim builds its own.
        // `Pinch` is scalars all the way down, so the value outlives the arena.
        var probe_arena = std.heap.ArenaAllocator.init(alloc);
        defer probe_arena.deinit();
        const pinch = (try pinch_probe.probe(probe_arena.allocator(), staged, .{
            .skip_net = aim.net,
            .ends = aim.ends,
            .width = aim.width,
            .clearance = aim.clearance,
            .tracks = aim.tracks,
            .vias = aim.vias,
        })) orelse continue;
        try findings.append(alloc, .{
            .label = aim.label,
            .pinch = pinch,
            .a_ref = refOf(staged, pinch.a.part),
            .b_ref = if (pinch.b) |other| refOf(staged, other.part) else "",
        });
        const other = pinch.b orelse {
            try refusals.append(alloc, .{ .label = aim.label, .why = .one_sided_wall });
            continue;
        };
        // Two pads of ONE part is not a movable wall. The mesh sees two distinct
        // obstacle polygons and reports them as two sides, but a footprint is
        // rigid: translating it carries both pads and leaves the gap between
        // them exactly as it was. Measured on barracuda — the `V_1V8A` channel
        // pinched between two pads of `adf4159/R58` produced a legal-looking
        // 0.13 mm move that could not possibly have opened it, and cost a whole
        // trial route to disprove.
        if (samePart(pinch.a, other)) {
            try refusals.append(alloc, .{
                .label = aim.label,
                .ref = refOf(staged, pinch.a.part),
                .why = .same_part,
            });
            continue;
        }
        // Try each side in turn: the far body may be immovable while the near
        // one is free, and either widening the same wall does the same job.
        const sides = [2][2]pinch_probe.Owner{ .{ pinch.a, other }, .{ other, pinch.a } };
        for (sides) |side| {
            const outcome = tryMove(staged, guard, aim, pinch, side[0], side[1]);
            switch (outcome) {
                .moved => |m| {
                    trial[m.part].x = m.to[0];
                    trial[m.part].y = m.to[1];
                    try moves.append(alloc, m);
                    break;
                },
                .refused => |r| try refusals.append(alloc, r),
            }
        }
    }
    return .{
        .findings = try findings.toOwnedSlice(alloc),
        .moves = try moves.toOwnedSlice(alloc),
        .refusals = try refusals.toOwnedSlice(alloc),
    };
}

/// A move, or the reason there wasn't one.
const Outcome = union(enum) { moved: Move, refused: Refusal };

/// Consider moving `mover` away from `anchor` far enough to open their wall.
fn tryMove(
    staged: optimizer.Placement,
    guard: Guard,
    aim: Aim,
    pinch: pinch_probe.Pinch,
    mover: pinch_probe.Owner,
    anchor: pinch_probe.Owner,
) Outcome {
    const pi = mover.part orelse
        return .{ .refused = .{ .label = aim.label, .why = .not_a_part } };
    const part = staged.parts[pi];
    if (immovable(staged, guard, pi)) |why|
        return .{ .refused = .{ .label = aim.label, .ref = part.ref_des, .why = why } };
    const to = switch (translation(part, pinch, mover, anchor)) {
        .to => |t| t,
        .refused => |why| return .{ .refused = .{ .label = aim.label, .ref = part.ref_des, .why = why } },
    };
    if (guard.rejects(staged, pi, to)) |why|
        return .{ .refused = .{ .label = aim.label, .ref = part.ref_des, .why = why } };
    return .{ .moved = .{
        .part = pi,
        .ref = part.ref_des,
        .from = .{ part.x, part.y },
        .to = to,
        .label = aim.label,
        .have_mm = pinch.have_mm,
        .need_mm = pinch.need_mm,
    } };
}

/// A destination pose, or why there is none. The two refusals are genuinely
/// different findings — "these two bodies give me no direction" and "the gap is
/// too wide to close by nudging" — and reporting either as the other would send
/// a reader looking at the wrong geometry.
const Translation = union(enum) {
    to: [2]f64,
    refused: Why,

    /// The destination, where there is one — for a reader asking only whether a
    /// move exists.
    fn pose(self: Translation) ?[2]f64 {
        return switch (self) {
            .to => |t| t,
            .refused => null,
        };
    }

    /// The reason there is none, where there is none.
    fn why(self: Translation) ?Why {
        return switch (self) {
            .to => null,
            .refused => |w| w,
        };
    }
};

/// Where `part` has to end up for its wall with `anchor` to hold the channel.
///
/// The axis is the one the wall is measured across: from the anchor body's
/// centre to the mover's, normalised. The distance is the measured shortfall
/// plus one margin, snapped OUTWARD onto the pose grid so the snap can only ever
/// give the channel more room than asked for, never less.
fn translation(
    part: optimizer.Part,
    pinch: pinch_probe.Pinch,
    mover: pinch_probe.Owner,
    anchor: pinch_probe.Owner,
) Translation {
    const dx = mover.center[0] - anchor.center[0];
    const dy = mover.center[1] - anchor.center[1];
    const len = std.math.hypot(dx, dy);
    if (len <= 0) return .{ .refused = .no_axis };
    const want = pinch.shortfallMm() + move_margin_mm;
    if (want > max_move_mm) return .{ .refused = .too_far };
    const step = snapOut(want);
    return .{ .to = .{ part.x + dx / len * step, part.y + dy / len * step } };
}

/// Round a distance UP to the pose grid — a repair may overshoot its own
/// margin, never undershoot the shortfall it measured.
fn snapOut(mm: f64) f64 {
    return @ceil(mm / pose_grid_mm) * pose_grid_mm;
}

/// Why this part may not be moved at all, or null when it may.
///
/// Every clause is a placement fact the design already states somewhere else:
/// the part kind, the ref-des prefix the whole codebase reads passives by, the
/// editor lock, the authored RF class, the authored `(near …)`, and the declared
/// pair membership. Nothing here is a new naming rule.
fn immovable(placement: optimizer.Placement, guard: Guard, pi: usize) ?Why {
    const part = placement.parts[pi];
    if (part.kind != .passive) return .hub;
    if (!movablePrefix(part.ref_des)) return .not_passive;
    if (part.locked) return .locked;
    if (guard.near_bound[pi]) return .near_bound;
    for (guard.padNets(placement, pi)) |net| {
        if (net < 0) continue;
        const ni: usize = @intCast(net);
        if (ni < guard.rf.len and guard.rf[ni]) return .rf_fenced;
        if (ni < guard.paired.len and guard.paired[ni]) return .pair_member;
    }
    return null;
}

/// Ref-des prefixes a repair may translate: the two-terminal passives whose
/// exact position is a routing convenience rather than a declared intent — a
/// resistor, a capacitor, an inductor, a ferrite, a diode.
///
/// `FID` is carved out of the `F` prefix on purpose. A fiducial is a MECHANICAL
/// datum the assembler's vision system registers the board by; it happens to
/// look like a one-pad passive and moving one would silently invalidate the
/// pick-and-place file.
fn movablePrefix(ref: []const u8) bool {
    const leaf = net_name.leaf(ref);
    if (leaf.len == 0) return false;
    if (std.ascii.startsWithIgnoreCase(leaf, "FID")) return false;
    return switch (std.ascii.toUpper(leaf[0])) {
        'R', 'C', 'L', 'F', 'D' => true,
        else => false,
    };
}

/// Are both sides of a wall pads of one placed part?
fn samePart(a: pinch_probe.Owner, b: pinch_probe.Owner) bool {
    const pa = a.part orelse return false;
    const pb = b.part orelse return false;
    return pa == pb;
}

fn refOf(placement: optimizer.Placement, part: ?usize) []const u8 {
    const pi = part orelse return "";
    return placement.parts[pi].ref_des;
}

/// Everything a validation needs that costs more to recompute than to carry:
/// the board's authored intent per net and per part, and the two baselines a
/// trial pose is compared against.
const Guard = struct {
    /// Per flattened net: does an authored class put an RF keepout on it?
    rf: []const bool,
    /// Per flattened net: is it a declared diff-pair member?
    paired: []const bool,
    /// Per part: does it carry an authored `(near …)` adjacency?
    near_bound: []const bool,
    /// Per part: the flattened nets its pads sit on, flattened into one slice.
    pad_nets: []const i32,
    pad_at: []const usize,
    /// Courtyard overlaps the board already has — a repair may not add one, and
    /// a board that already overlaps somewhere else is not this pass's problem.
    overlaps: usize,
    /// Layout-lint findings the board already has, by rule.
    lint: std.StringHashMapUnmanaged(usize),
    alloc: std.mem.Allocator,
    policy: module_policy.ModulePolicy,

    fn of(alloc: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error!Guard {
        const rf = try alloc.alloc(bool, placement.nets.len);
        for (rf, 0..) |*on, i| on.* = keepout.haloOf(placement, i) > 0;
        const paired = try alloc.alloc(bool, placement.nets.len);
        @memset(paired, false);
        for (placement.diff_pairs) |pair| {
            if (pair.p < paired.len) paired[pair.p] = true;
            if (pair.n < paired.len) paired[pair.n] = true;
        }
        const policy = try module_policy.analyze(alloc, placement);
        var g = Guard{
            .rf = rf,
            .paired = paired,
            .near_bound = try nearBound(alloc, placement),
            .pad_nets = &.{},
            .pad_at = &.{},
            .overlaps = optimizer.overlapCount(placement),
            .lint = .empty,
            .alloc = alloc,
            .policy = policy,
        };
        try g.indexPadNets(alloc, placement);
        try g.countLint(alloc, placement);
        return g;
    }

    /// Flatten each part's pad nets once, so the movability scan is a slice walk
    /// rather than a per-part netlist search.
    fn indexPadNets(self: *Guard, alloc: std.mem.Allocator, p: optimizer.Placement) std.mem.Allocator.Error!void {
        var of_ref: std.StringHashMapUnmanaged(usize) = .empty;
        for (p.parts, 0..) |part, i| try of_ref.put(alloc, part.ref_des, i);
        var per: []std.ArrayList(i32) = try alloc.alloc(std.ArrayList(i32), p.parts.len);
        for (per) |*list| list.* = .empty;
        for (p.nets, 0..) |net, ni| {
            for (net.pins) |pin| {
                const pi = of_ref.get(pin.ref_des) orelse continue;
                try per[pi].append(alloc, @intCast(ni));
            }
        }
        var flat: std.ArrayList(i32) = .empty;
        const at = try alloc.alloc(usize, p.parts.len + 1);
        for (per, 0..) |list, i| {
            at[i] = flat.items.len;
            try flat.appendSlice(alloc, list.items);
        }
        at[p.parts.len] = flat.items.len;
        self.pad_nets = try flat.toOwnedSlice(alloc);
        self.pad_at = at;
    }

    fn padNets(self: Guard, p: optimizer.Placement, pi: usize) []const i32 {
        _ = p;
        if (pi + 1 >= self.pad_at.len) return &.{};
        return self.pad_nets[self.pad_at[pi]..self.pad_at[pi + 1]];
    }

    fn countLint(self: *Guard, alloc: std.mem.Allocator, p: optimizer.Placement) std.mem.Allocator.Error!void {
        const findings = try layout_lint.lint(alloc, p, self.policy);
        defer layout_lint.freeFindings(alloc, findings);
        for (findings) |f| {
            if (f.severity == .info) continue;
            const gop = try self.lint.getOrPut(alloc, f.rule);
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    }

    /// Does moving part `pi` to `to` break something the board currently holds?
    fn rejects(self: Guard, staged: optimizer.Placement, pi: usize, to: [2]f64) ?Why {
        var trial = self.alloc.dupe(optimizer.Part, staged.parts) catch return .overlaps;
        defer self.alloc.free(trial);
        trial[pi].x = to[0];
        trial[pi].y = to[1];
        var probe_placement = staged;
        probe_placement.parts = trial;
        if (optimizer.overlapCount(probe_placement) > self.overlaps) return .overlaps;
        if (outsideBoard(probe_placement, trial[pi])) return .off_board;
        if (self.lintWorsens(probe_placement)) return .lint_regressed;
        return null;
    }

    /// True when the trial board carries an err/warn finding under some rule
    /// more often than the current one does. An allocation failure reads as a
    /// regression: refusing a move nobody could validate is the safe answer.
    fn lintWorsens(self: Guard, trial: optimizer.Placement) bool {
        const findings = layout_lint.lint(self.alloc, trial, self.policy) catch return true;
        defer layout_lint.freeFindings(self.alloc, findings);
        var seen: std.StringHashMapUnmanaged(usize) = .empty;
        defer seen.deinit(self.alloc);
        for (findings) |f| {
            if (f.severity == .info) continue;
            const gop = seen.getOrPut(self.alloc, f.rule) catch return true;
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
            if (gop.value_ptr.* > (self.lint.get(f.rule) orelse 0)) return true;
        }
        return false;
    }
};

/// Per part: does it declare an authored `(near "REF" PIN)`?
fn nearBound(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
) std.mem.Allocator.Error![]const bool {
    const out = try alloc.alloc(bool, placement.parts.len);
    @memset(out, false);
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const near = try near_bind.resolve(scratch.allocator(), placement.instances, placement.nets);
    // `NearPair.part` indexes the flattened INSTANCES; the poses are indexed by
    // part. Ref-des is the one name both slices agree on.
    for (near.pairs) |pair| {
        if (pair.part >= placement.instances.len) continue;
        const ref = placement.instances[pair.part].ref_des;
        for (placement.parts, 0..) |part, i| {
            if (std.mem.eql(u8, part.ref_des, ref)) out[i] = true;
        }
    }
    return out;
}

/// Does this part's courtyard leave the declared board outline? A board with no
/// authored `(board …)` rectangle declares no outline to leave.
fn outsideBoard(placement: optimizer.Placement, part: optimizer.Part) bool {
    const rect = placement.board_rect orelse return false;
    const ext = pose_math.aabbHalf(part.hw, part.hh, part.rot);
    const off = pose_math.rotate(part.ccx, part.ccy, part.rot);
    const cx = part.x + off[0];
    const cy = part.y + off[1];
    return cx - ext[0] < rect.minx or cy - ext[1] < rect.miny or
        cx + ext[0] > rect.minx + rect.w or cy + ext[1] > rect.miny + rect.h;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");

test {
    testing.refAllDecls(@This());
}

/// Slack for comparing a decimal pose grid in binary floating point — a
/// nanometre, far under anything a board cares about.
const snap_eps: f64 = 1e-9;

// spec: placement/place-repair - a computed translation is the measured shortfall plus one margin, along the axis away from the far body, snapped outward onto the pose grid
test "a translation opens exactly the wall it measured" {
    const part = optimizer.Part{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.3,
        .pads = &.{},
        .fallback = false,
        .x = 10,
        .y = 5,
    };
    // A wall 0.31 mm wide where 0.52 is needed: 0.21 short, plus the margin.
    const pinch = pinch_probe.Pinch{
        .a = .{ .kind = .pad, .part = 0, .center = .{ 10, 5 } },
        .b = .{ .kind = .pad, .part = 1, .center = .{ 10, 4 } },
        .at = .{ 10, 4.5 },
        .layer = 0,
        .have_mm = 0.31,
        .need_mm = 0.52,
    };
    const to = translation(part, pinch, pinch.a, pinch.b.?).pose() orelse
        return error.TestNoTranslation;
    // Straight up the +y axis (away from the body below), by shortfall+margin
    // rounded UP to the pose grid: never less than what was asked for, never
    // more than one grid step above it.
    try testing.expectApproxEqAbs(@as(f64, 10), to[0], 1e-9);
    const want = pinch.shortfallMm() + move_margin_mm;
    const step = to[1] - part.y;
    try testing.expect(step >= want);
    // One grid step at most, with a nanometre of slack for the binary
    // representation of a decimal grid — the claim is about millimetres.
    try testing.expect(step <= want + pose_grid_mm + snap_eps);

    // Concentric bodies have no axis to move along, and say so in those words.
    var concentric = pinch;
    concentric.b = .{ .kind = .pad, .part = 1, .center = .{ 10, 5 } };
    try testing.expectEqual(@as(?Why, .no_axis), translation(part, concentric, concentric.a, concentric.b.?).why());

    // A shortfall past a micro-move is refused rather than half-satisfied.
    var chasm = pinch;
    chasm.need_mm = 9.0;
    try testing.expectEqual(@as(?Why, .too_far), translation(part, chasm, chasm.a, chasm.b.?).why());
}

// spec: placement/place-repair - a snapped move rounds outward, so the pose grid can only ever give the channel more room than the shortfall asked for
test "the pose snap never eats the margin" {
    for ([_]f64{ 0.2999, 0.30, 0.3001, 1.0, 2.7183 }) |mm| {
        const snapped = snapOut(mm);
        try testing.expect(snapped >= mm);
        try testing.expect(snapped <= mm + pose_grid_mm + snap_eps);
    }
}

// spec: placement/place-repair - only an unlocked two-terminal passive may be translated; a hub, a lock and a foreign ref-des prefix are each refused by name
test "movability is decided by part kind, prefix and lock" {
    try testing.expect(movablePrefix("C12"));
    try testing.expect(movablePrefix("bypass/R4"));
    try testing.expect(movablePrefix("L1"));
    try testing.expect(movablePrefix("FB2"));
    try testing.expect(!movablePrefix("U7"));
    try testing.expect(!movablePrefix("J1"));
    try testing.expect(!movablePrefix("TP3"));
    // A fiducial is a mechanical datum, not a passive that happens to start F.
    try testing.expect(!movablePrefix("FID1"));
    try testing.expect(!movablePrefix(""));
    try testing.expect(movablePrefix("adc1/C9"));
}

// spec: placement/place-repair - every refusal carries a reason a reader can act on, and the reasons are distinct
test "each refusal reason reads as its own sentence" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    for (std.enums.values(Why)) |why| {
        const text = why.text();
        try testing.expect(text.len > 0);
        try testing.expect((try seen.getOrPut(testing.allocator, text)).found_existing == false);
    }
}

/// A one-pad passive at `(x, y)` whose pad carries `net`.
fn passiveAt(ref: []const u8, x: f64, y: f64, pads: []const geometry.Pad) optimizer.Part {
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

// spec: placement/place-repair - a wall whose two sides are pads of one rigid part is refused by name, because translating that part carries both pads and cannot widen the gap
test "a wall between two pads of one part is not a movable wall" {
    const left = pinch_probe.Owner{ .kind = .pad, .part = 3, .center = .{ 0, 0 } };
    const right = pinch_probe.Owner{ .kind = .pad, .part = 3, .center = .{ 1, 0 } };
    try testing.expect(samePart(left, right));
    // Two pads of DIFFERENT parts is the case a move exists for.
    try testing.expect(!samePart(left, .{ .kind = .pad, .part = 4, .center = .{ 1, 0 } }));
    // A side with no part at all (copper, a keepout) is never "the same part".
    try testing.expect(!samePart(left, .{ .kind = .track, .net = 2 }));
    try testing.expect(!samePart(.{ .kind = .track, .net = 2 }, left));
}

// spec: placement/place-repair - a part whose trial pose would leave the declared board outline is refused, and a board with no declared outline refuses nothing on that ground
test "a trial pose outside the declared outline is refused" {
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{passiveAt("C1", 5, 5, &pads)};
    var p = optimizer.Placement{
        .parts = &parts,
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
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    try testing.expect(!outsideBoard(p, parts[0]));
    var escaped = parts[0];
    escaped.x = 9.9;
    try testing.expect(outsideBoard(p, escaped));
    // With no declared outline there is nothing to leave.
    p.board_rect = null;
    try testing.expect(!outsideBoard(p, escaped));
}

// spec: placement/place-repair - a placement whose channel has room yields no finding, no move and no refusal, so the option changes nothing on a board that does not need it
test "a board with an open channel plans nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        passiveAt("R1", 0, -6, &pads),
        passiveAt("R2", 0, 6, &pads),
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -10,
        .miny = -10,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
    const aims = [_]Aim{.{
        .label = "SIG",
        .net = pinch_probe.skip_nothing,
        .ends = .{ .from = .{ -8, 0 }, .to = .{ 8, 0 } },
        .width = 0.15,
        .clearance = 0.15,
    }};
    const out = try plan(arena, p, &aims, .{});
    try testing.expectEqual(@as(usize, 0), out.findings.len);
    try testing.expectEqual(@as(usize, 0), out.moves.len);
    try testing.expectEqual(@as(usize, 0), out.refusals.len);
}

// spec: placement/place-repair - a pinch between two movable passives yields one bounded move that opens the channel, and re-probing the moved placement finds the channel open
test "one legal move opens a pinched channel" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Two long pads leaving a 0.1 mm slot, the only way across the board.
    const wide = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 8.0 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 4, .pads = &wide, .fallback = false, .x = 0, .y = -4.05 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 4, .pads = &wide, .fallback = false, .x = 0, .y = 4.05 },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -10,
        .miny = -10,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
    const aims = [_]Aim{.{
        .label = "SIG",
        .net = pinch_probe.skip_nothing,
        .ends = .{ .from = .{ -6, 0 }, .to = .{ 6, 0 } },
        .width = 0.2,
        .clearance = 0.2,
    }};
    const out = try plan(arena, p, &aims, .{});
    try testing.expectEqual(@as(usize, 1), out.findings.len);
    try testing.expectEqual(@as(usize, 1), out.moves.len);
    const m = out.moves[0];
    try testing.expect(m.distMm() > 0 and m.distMm() <= max_move_mm);
    // The move is the whole repair: re-probing the moved board finds a channel.
    var moved = try arena.dupe(optimizer.Part, &parts);
    moved[m.part].x = m.to[0];
    moved[m.part].y = m.to[1];
    var after = p;
    after.parts = moved;
    try testing.expect((try pinch_probe.probe(arena, after, .{
        .skip_net = pinch_probe.skip_nothing,
        .ends = .{ .from = .{ -6, 0 }, .to = .{ 6, 0 } },
        .width = 0.2,
        .clearance = 0.2,
    })) == null);
}
