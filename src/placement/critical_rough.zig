//! Design-level rough placement for ordered RF launch paths.
//!
//! The ordinary flat rougher sees one net at a time and rings every connector
//! around one global anchor. This module instead consumes the exact-pad motifs
//! recovered by critical_paths.zig, builds one rigid switch/series/launch
//! island per local RF owner, and places those islands before support parts.
//! It is intentionally optimizer-independent: the public entry points are
//! generic over the optimizer's part record, avoiding an import cycle and
//! keeping the already-large optimizer implementation below its size gate.

const std = @import("std");
const env = @import("../eval/env.zig");
const net_analysis = @import("../eval/net_analysis.zig");
const numeric = @import("../numeric.zig");
const geometry = @import("geometry.zig");
const net_rules = @import("net_rules.zig");
const critical_paths = @import("critical_paths.zig");
const route_score = @import("critical_route_score.zig");
const rf_path_solver = @import("rf_path_solver.zig");

/// Extracted critical topology retained by the placement preparation model.
pub const Result = critical_paths.Result;

/// Geometry controls inherited from the active optimizer solve.
pub const Options = struct {
    grid_mm: f64 = 0.1,
    clearance_mm: f64 = 0.1,
    island_gap_mm: f64 = 2.0,
    collide_shrink_mm: f64 = 0,
    route_gap_mm: f64 = 0,
    containment: ?Containment = null,
};

/// Translation-independent authored-board capacity. Parts claimed by a board
/// edge or corner are ignored because the board packer docks them after rough
/// placement; every other part must fit inside the component-edge inset.
pub const Containment = struct {
    width_mm: f64,
    height_mm: f64,
    edge_clearance_mm: f64 = 0,
    ignored: []const bool = &.{},
};

/// Lexicographic critical-path quality used to arbitrate this seed against the
/// existing design rougher.
pub const Rank = route_score.Rank;

const Point = struct { x: f64, y: f64 };
const Box = struct { cxo: f64, cyo: f64, hw: f64, hh: f64 };
const Target = struct { edge: u2, along: f64 };

const Terminal = struct {
    path: usize,
    part: usize,
    along: f64,
    half_along: f64,
};

const SupportTarget = struct {
    hub: usize,
    hub_x: f64,
    hub_y: f64,
    own_pad: []const u8,
    hub_pad_count: usize,
    net_pin_count: usize,
};

/// Resolve authored RF rules and recover exact ordered paths from optimizer
/// parts without importing optimizer.zig.
pub fn extract(
    arena: std.mem.Allocator,
    block: *const env.DesignBlock,
    parts: anytype,
    nets: []const critical_paths.FlatNet,
) std.mem.Allocator.Error!Result {
    const rules = try net_rules.resolvedNetRules(arena, block, nets);
    const projected = try arena.alloc(critical_paths.Part, parts.len);
    for (parts, 0..) |part, i| projected[i] = .{
        .ref_des = part.ref_des,
        .pad_count = part.pads.len,
        // Optimizer hubs include connectors. Critical-only incidence is the
        // reliable distinction between a one-port launch and a multi-port IC.
        .role = .auto,
    };
    return critical_paths.extract(arena, projected, nets, rules) catch |err| switch (err) {
        error.DuplicatePart => .{ .roles = &.{}, .paths = &.{}, .islands = &.{}, .diagnostics = .{} },
        else => |e| return e,
    };
}

fn gridRound(v: f64, opts: Options) f64 {
    return @round(v / opts.grid_mm) * opts.grid_mm;
}

fn rotate(x: f64, y: f64, rot: f64) Point {
    const normalized = @mod(rot, 360);
    return switch (numeric.checkedInt(i64, @round(normalized)) orelse 0) {
        90 => .{ .x = -y, .y = x },
        180 => .{ .x = -x, .y = -y },
        270 => .{ .x = y, .y = -x },
        0, 360 => .{ .x = x, .y = y },
        else => blk: {
            const radians = normalized * std.math.pi / 180;
            break :blk .{
                .x = x * @cos(radians) - y * @sin(radians),
                .y = x * @sin(radians) + y * @cos(radians),
            };
        },
    };
}

fn bottom(comptime Part: type, part: Part) bool {
    return @backingInt(part.side) != 0;
}

fn localAt(comptime Part: type, part: Part, pad: geometry.Pad, rot: f64) Point {
    return rotate(if (bottom(Part, part)) -pad.x else pad.x, pad.y, rot);
}

fn worldAt(comptime Part: type, part: Part, pad: geometry.Pad) Point {
    const q = localAt(Part, part, pad, part.rot);
    return .{ .x = part.x + q.x, .y = part.y + q.y };
}

fn padOf(comptime Part: type, part: Part, pin: []const u8) geometry.Pad {
    for (part.pads) |pad| if (std.mem.eql(u8, pad.number, pin)) return pad;
    return .{ .number = pin, .x = 0, .y = 0, .w = 0, .h = 0 };
}

fn boxOf(comptime Part: type, part: Part, opts: Options) Box {
    const shrink = opts.collide_shrink_mm;
    const gap = opts.route_gap_mm;
    const radians = part.rot * std.math.pi / 180;
    const ca = @abs(@cos(radians));
    const sa = @abs(@sin(radians));
    if (part.keep.hw < 0) {
        const ccx = if (bottom(Part, part)) -part.ccx else part.ccx;
        const off = rotate(ccx, part.ccy, part.rot);
        const hw = @max(0.0, part.hw - shrink);
        const hh = @max(0.0, part.hh - shrink);
        return .{
            .cxo = off.x,
            .cyo = off.y,
            .hw = ca * hw + sa * hh + gap,
            .hh = sa * hw + ca * hh + gap,
        };
    }
    const ox = if (bottom(Part, part)) -part.keep.ox else part.keep.ox;
    const off = rotate(ox, part.keep.oy, part.rot);
    const hw = @max(0.0, part.keep.hw - shrink);
    const hh = @max(0.0, part.keep.hh - shrink);
    return .{
        .cxo = off.x,
        .cyo = off.y,
        .hw = ca * hw + sa * hh + gap,
        .hh = sa * hw + ca * hh + gap,
    };
}

fn targetFromPad(box: Box, px: f64, py: f64) Target {
    const nx = px / @max(box.hw, 0.001);
    const ny = py / @max(box.hh, 0.001);
    const vertical = @abs(nx) >= @abs(ny);
    const edge: u2 = if (vertical) (if (px < 0) 0 else 1) else (if (py < 0) 2 else 3);
    return .{ .edge = edge, .along = if (vertical) py else px };
}

fn outward(edge: u2) Point {
    return switch (edge) {
        0 => .{ .x = -1, .y = 0 },
        1 => .{ .x = 1, .y = 0 },
        2 => .{ .x = 0, .y = -1 },
        else => .{ .x = 0, .y = 1 },
    };
}

fn inward(edge: u2) Point {
    const q = outward(edge);
    return .{ .x = -q.x, .y = -q.y };
}

fn boundary(comptime Part: type, part: Part, edge: u2, opts: Options) f64 {
    const box = boxOf(Part, part, opts);
    return switch (edge) {
        0 => part.x + box.cxo - box.hw,
        1 => part.x + box.cxo + box.hw,
        2 => part.y + box.cyo - box.hh,
        else => part.y + box.cyo + box.hh,
    };
}

fn placeOutside(comptime Part: type, part: *Part, edge: u2, preceding: f64, opts: Options) void {
    const box = boxOf(Part, part.*, opts);
    const gap = opts.clearance_mm;
    switch (edge) {
        0 => part.x = gridRound(preceding - gap - box.cxo - box.hw, opts),
        1 => part.x = gridRound(preceding + gap - box.cxo + box.hw, opts),
        2 => part.y = gridRound(preceding - gap - box.cyo - box.hh, opts),
        else => part.y = gridRound(preceding + gap - box.cyo + box.hh, opts),
    }
}

fn alignPad(comptime Part: type, part: *Part, pad: geometry.Pad, edge: u2, want: f64, opts: Options) void {
    const q = localAt(Part, part.*, pad, part.rot);
    if (edge < 2) {
        part.y = gridRound(want - q.y, opts);
    } else {
        part.x = gridRound(want - q.x, opts);
    }
}

fn axisRotation(dx: f64, dy: f64, tx: f64, ty: f64) ?f64 {
    if (@abs(dx) + @abs(dy) < 1e-9 or @abs(tx) + @abs(ty) < 1e-9) return null;
    var best: f64 = 0;
    var best_dot = -std.math.inf(f64);
    for ([_]f64{ 0, 90, 180, 270 }) |rot| {
        const q = rotate(dx, dy, rot);
        const dot = q.x * tx + q.y * ty;
        if (dot > best_dot) {
            best_dot = dot;
            best = rot;
        }
    }
    return best;
}

fn overlap(comptime Part: type, a: Part, b: Part, opts: Options) bool {
    if (@backingInt(a.side) != @backingInt(b.side)) return false;
    const aa = boxOf(Part, a, opts);
    const bb = boxOf(Part, b, opts);
    return @abs((a.x + aa.cxo) - (b.x + bb.cxo)) < aa.hw + bb.hw - 0.01 and
        @abs((a.y + aa.cyo) - (b.y + bb.cyo)) < aa.hh + bb.hh - 0.01;
}

fn pack1d(
    arena: std.mem.Allocator,
    desired: []const f64,
    half: []const f64,
    gap: f64,
) std.mem.Allocator.Error![]f64 {
    const n = desired.len;
    const position = try arena.alloc(f64, n);
    if (n == 0) return position;
    const offset = try arena.alloc(f64, n);
    offset[0] = 0;
    for (1..n) |i| offset[i] = offset[i - 1] + half[i - 1] + gap + half[i];
    const value = try arena.alloc(f64, n);
    const count = try arena.alloc(f64, n);
    var pools: usize = 0;
    for (0..n) |i| {
        value[pools] = desired[i] - offset[i];
        count[pools] = 1;
        pools += 1;
        while (pools > 1 and value[pools - 1] < value[pools - 2]) {
            const weight = count[pools - 2] + count[pools - 1];
            value[pools - 2] = (value[pools - 2] * count[pools - 2] +
                value[pools - 1] * count[pools - 1]) / weight;
            count[pools - 2] = weight;
            pools -= 1;
        }
    }
    var item: usize = 0;
    for (0..pools) |pool| {
        var k: f64 = 0;
        while (k < count[pool]) : (k += 1) {
            position[item] = value[pool] + offset[item];
            item += 1;
        }
    }
    return position;
}

fn padWorld(comptime Part: type, parts: []const Part, ref: critical_paths.PadRef) Point {
    return worldAt(Part, parts[ref.part], padOf(Part, parts[ref.part], ref.pad));
}

fn unitPoint(v: Point) ?Point {
    const length = std.math.hypot(v.x, v.y);
    if (length <= 1e-9) return null;
    return .{ .x = v.x / length, .y = v.y / length };
}

fn dotPoint(a: Point, b: Point) f64 {
    return a.x * b.x + a.y * b.y;
}

/// Unsigned world-space long axis of the physical land. Pad rotation is part
/// of the frame; ignoring it is exactly what made the 45-degree SMPM/QFN
/// launches look routeable to the old centre-to-centre heuristic.
fn padLongAxis(comptime Part: type, part: Part, pad: geometry.Pad) Point {
    const local = if (pad.w >= pad.h) rotate(1, 0, pad.rot) else rotate(0, 1, pad.rot);
    return rotate(if (bottom(Part, part)) -local.x else local.x, local.y, part.rot);
}

fn signedAxis(axis: Point, propagation: Point) Point {
    return if (dotPoint(axis, propagation) >= 0) axis else .{ .x = -axis.x, .y = -axis.y };
}

fn portFrames(
    comptime Part: type,
    parts: []const Part,
    from: critical_paths.PadRef,
    to: critical_paths.PadRef,
) ?struct { start: rf_path_solver.PortFrame, end: rf_path_solver.PortFrame } {
    const a = padWorld(Part, parts, from);
    const b = padWorld(Part, parts, to);
    const propagation = unitPoint(.{ .x = b.x - a.x, .y = b.y - a.y }) orelse return null;
    const a_pad = padOf(Part, parts[from.part], from.pad);
    const b_pad = padOf(Part, parts[to.part], to.pad);
    const a_axis = signedAxis(padLongAxis(Part, parts[from.part], a_pad), propagation);
    const b_axis = signedAxis(padLongAxis(Part, parts[to.part], b_pad), propagation);
    return .{
        .start = .{ .at = .{ a.x, a.y }, .tangent = .{ a_axis.x, a_axis.y } },
        .end = .{ .at = .{ b.x, b.y }, .tangent = .{ b_axis.x, b_axis.y } },
    };
}

fn rfFrameViolations(comptime Part: type, parts: []const Part, result: Result) usize {
    var violations: usize = 0;
    for (result.paths) |path| {
        for (path.links) |link| {
            if (link.net >= result.rules.len) continue;
            const rule = result.rules[link.net];
            if (!(rule.width > 0) or !(rule.rf.impedance.ohms > 0)) continue;
            const frames = portFrames(Part, parts, link.from, link.to) orelse {
                violations += 1;
                continue;
            };
            const fit = rf_path_solver.frameFit(
                frames.start,
                frames.end,
                rule.width,
                if (rule.rf.min_bend_ratio > 0) rule.rf.min_bend_ratio else 3,
                @max(rule.width, rule.rf.escape_mm),
            );
            violations += @intFromBool(!fit.feasible);
        }
    }
    return violations;
}

fn endpoint(comptime Part: type, parts: []const Part, ref: critical_paths.PadRef) route_score.Endpoint {
    const at = padWorld(Part, parts, ref);
    const part = parts[ref.part];
    return .{
        .at = .{ at.x, at.y },
        .out = .{ at.x - part.x, at.y - part.y },
    };
}

fn finitePathGeometry(comptime Part: type, parts: []const Part, result: Result) bool {
    for (result.paths) |path| {
        for (path.links) |link| {
            const metrics = route_score.estimate(endpoint(Part, parts, link.from), endpoint(Part, parts, link.to));
            if (!std.math.isFinite(metrics.length_mm) or !std.math.isFinite(metrics.facing_penalty)) return false;
        }
    }
    return true;
}

fn exceedsContainment(comptime Part: type, parts: []const Part, containment: Containment, opts: Options) bool {
    var geometry_opts = opts;
    // Collision relaxation is a solve aid, not physical board capacity. Use
    // the authored keep/courtyard geometry for this hard feasibility check.
    geometry_opts.collide_shrink_mm = 0;
    geometry_opts.route_gap_mm = 0;

    var min_x = std.math.inf(f64);
    var min_y = std.math.inf(f64);
    var max_x = -std.math.inf(f64);
    var max_y = -std.math.inf(f64);
    var any = false;
    for (parts, 0..) |part, index| {
        if (index < containment.ignored.len and containment.ignored[index]) continue;
        const box = boxOf(Part, part, geometry_opts);
        min_x = @min(min_x, part.x + box.cxo - box.hw);
        min_y = @min(min_y, part.y + box.cyo - box.hh);
        max_x = @max(max_x, part.x + box.cxo + box.hw);
        max_y = @max(max_y, part.y + box.cyo + box.hh);
        any = true;
    }
    if (!any) return false;

    const inset = @max(0, containment.edge_clearance_mm);
    const usable_width = containment.width_mm - 2 * inset;
    const usable_height = containment.height_mm - 2 * inset;
    return usable_width < 0 or usable_height < 0 or
        max_x - min_x > usable_width + 1e-9 or
        max_y - min_y > usable_height + 1e-9;
}

/// Measure exact-pad bend, facing, axis, and length quality for a placement.
/// `fallback_cost` is consulted only after every RF-specific key ties.
pub fn rank(comptime Part: type, parts: []const Part, result: Result, fallback_cost: f64, opts: Options) Rank {
    var out: Rank = .{ .fallback_cost = fallback_cost };
    out.hard_violations = @intFromBool(anyOverlap(Part, parts, opts));
    if (opts.containment) |containment| {
        out.hard_violations += @intFromBool(exceedsContainment(Part, parts, containment, opts));
    }
    out.hard_violations += rfFrameViolations(Part, parts, result);
    for (result.paths) |path| {
        var path_metrics: route_score.Metrics = .{};
        for (path.links) |link| {
            const link_metrics = route_score.estimate(endpoint(Part, parts, link.from), endpoint(Part, parts, link.to));
            path_metrics.bends += link_metrics.bends;
            path_metrics.length_mm += link_metrics.length_mm;
            path_metrics.facing_penalty += link_metrics.facing_penalty;
            path_metrics.axis_penalty += link_metrics.axis_penalty;
        }
        out.addPath(path_metrics);
    }
    return out;
}

/// True when the candidate improves the RF-first lexicographic ordering.
pub fn better(candidate: Rank, incumbent: Rank) bool {
    return route_score.better(candidate, incumbent);
}

fn capture(comptime Part: type, arena: std.mem.Allocator, parts: []const Part) std.mem.Allocator.Error![]Part {
    return arena.dupe(Part, parts);
}

fn restore(comptime Part: type, parts: []Part, poses: []const Part) void {
    for (parts, poses) |*part, pose| {
        part.x = pose.x;
        part.y = pose.y;
        part.rot = pose.rot;
        part.rot_pin = pose.rot_pin;
    }
}

/// Generate the exact-pad candidate and a caller-supplied legacy candidate,
/// finish each through the same caller-supplied orientation/repair pipeline,
/// then keep the lexicographically better RF geometry. The callbacks keep this
/// module independent of optimizer internals; importantly, snapshots are taken
/// only after `finishFn`, so a seed cannot win on geometry that repair changes.
pub fn arbitrate(
    comptime Part: type,
    comptime Context: type,
    comptime legacyFn: fn (Context, std.mem.Allocator, []Part) std.mem.Allocator.Error!bool,
    comptime finishFn: fn (Context, std.mem.Allocator, []Part) std.mem.Allocator.Error!void,
    comptime costFn: fn (Context, std.mem.Allocator, []Part) std.mem.Allocator.Error!f64,
    arena: std.mem.Allocator,
    parts: []Part,
    result: Result,
    nets: []const critical_paths.FlatNet,
    opts: Options,
    context: Context,
) std.mem.Allocator.Error!bool {
    if (result.paths.len == 0) return false;
    for (parts) |part| if (part.locked) return false;

    const original = try capture(Part, arena, parts);
    var candidate_rank: ?Rank = null;
    var candidate_poses: ?@TypeOf(original) = null;
    if (try place(arena, parts, result, nets, opts)) {
        try finishFn(context, arena, parts);
        candidate_rank = rank(Part, parts, result, try costFn(context, arena, parts), opts);
        candidate_poses = try capture(Part, arena, parts);
    }
    restore(Part, parts, original);

    const legacy_ok = try legacyFn(context, arena, parts);
    const legacy_rank = if (legacy_ok) blk: {
        try finishFn(context, arena, parts);
        break :blk rank(Part, parts, result, try costFn(context, arena, parts), opts);
    } else null;
    if (candidate_poses != null and (legacy_rank == null or better(candidate_rank.?, legacy_rank.?))) {
        restore(Part, parts, candidate_poses.?);
        return true;
    }
    if (legacy_ok) return true;
    restore(Part, parts, original);
    return false;
}

fn spokeCollides(
    comptime Part: type,
    parts: []const Part,
    path: critical_paths.Path,
    hub: usize,
    placed: []const usize,
    opts: Options,
) bool {
    if (overlap(Part, parts[path.terminal], parts[hub], opts)) return true;
    var launch_opts = opts;
    // Leave a copper corridor between neighbouring RF launches, not merely
    // enough room for their courtyard bodies.  The extra 0.3 mm is one
    // 0.20 mm controlled-impedance trace plus the board's 0.10 mm RF gap;
    // without it an adjacent SMPM signal land can seal the first bend of the
    // next spoke even though the two connector bodies are legal.
    launch_opts.route_gap_mm = @max(launch_opts.route_gap_mm, 0.9);
    for (placed) |other| if (overlap(Part, parts[path.terminal], parts[other], launch_opts)) return true;
    for (path.series) |step| if (overlap(Part, parts[path.terminal], parts[step.part], opts)) return true;
    for (path.series) |step| {
        if (overlap(Part, parts[step.part], parts[hub], opts)) return true;
        for (placed) |other| if (overlap(Part, parts[step.part], parts[other], opts)) return true;
    }
    return false;
}

fn moveSpokeOutward(comptime Part: type, parts: []Part, path: critical_paths.Path, ray: Point, opts: Options) void {
    const increment = @max(opts.grid_mm, 0.01);
    for (path.series) |series| {
        parts[series.part].x += ray.x * increment;
        parts[series.part].y += ray.y * increment;
    }
    parts[path.terminal].x += ray.x * increment;
    parts[path.terminal].y += ray.y * increment;
}

fn axisRotation45(dx: f64, dy: f64, target: Point) ?f64 {
    if (@abs(dx) + @abs(dy) < 1e-9) return null;
    var best: f64 = 0;
    var best_dot = -std.math.inf(f64);
    for ([_]f64{ 0, 45, 90, 135, 180, 225, 270, 315 }) |rot| {
        const q = rotate(dx, dy, rot);
        const score = q.x * target.x + q.y * target.y;
        if (score > best_dot) {
            best_dot = score;
            best = rot;
        }
    }
    return best;
}

fn terminalRotation(comptime Part: type, part: Part, signal: geometry.Pad, ray: Point) f64 {
    var best = part.rot;
    var best_axis_error = std.math.inf(f64);
    var best_pad_projection = std.math.inf(f64);
    for ([_]f64{ 0, 45, 90, 135, 180, 225, 270, 315 }) |rot| {
        var trial = part;
        trial.rot = rot;
        const axis = padLongAxis(Part, trial, signal);
        const axis_error = 1 - @abs(dotPoint(axis, ray));
        const local = localAt(Part, trial, signal, rot);
        const pad_projection = dotPoint(local, ray);
        if (axis_error < best_axis_error - 1e-9 or
            (@abs(axis_error - best_axis_error) <= 1e-9 and pad_projection < best_pad_projection))
        {
            best_axis_error = axis_error;
            best_pad_projection = pad_projection;
            best = rot;
        }
    }
    return best;
}

fn pathRay(comptime Part: type, parts: []const Part, path: critical_paths.Path, opts: Options) Point {
    const hub = parts[path.hub];
    const pad = padOf(Part, hub, path.hubPad().pad);
    const at = worldAt(Part, hub, pad);
    var radial = unitPoint(.{ .x = at.x - hub.x, .y = at.y - hub.y });
    if (radial == null) {
        const target = targetFromPad(boxOf(Part, hub, opts), at.x - hub.x, at.y - hub.y);
        radial = outward(target.edge);
    }
    return signedAxis(padLongAxis(Part, hub, pad), radial.?);
}

fn projectedBoundary(comptime Part: type, part: Part, ray: Point, opts: Options) f64 {
    const box = boxOf(Part, part, opts);
    const centre = Point{ .x = part.x + box.cxo, .y = part.y + box.cyo };
    const extent = @abs(ray.x) * box.hw + @abs(ray.y) * box.hh;
    return dotPoint(centre, ray) + extent;
}

fn placePadBeyond(
    comptime Part: type,
    part: *Part,
    pad: geometry.Pad,
    line_origin: Point,
    ray: Point,
    preceding: f64,
    opts: Options,
) void {
    const local = localAt(Part, part.*, pad, part.rot);
    const box = boxOf(Part, part.*, opts);
    const extent = @abs(ray.x) * box.hw + @abs(ray.y) * box.hh;
    const base_centre = Point{
        .x = line_origin.x - local.x + box.cxo,
        .y = line_origin.y - local.y + box.cyo,
    };
    const along = preceding + opts.clearance_mm - dotPoint(base_centre, ray) + extent;
    // Critical geometry is allowed off the cosmetic placement grid. Snapping
    // the two coordinates independently can move a one-millimetre spoke far
    // enough off a 45-degree port axis to violate the two-degree entry limit.
    part.x = line_origin.x + ray.x * along - local.x;
    part.y = line_origin.y + ray.y * along - local.y;
}

fn rotatePoint(v: Point, degrees: f64) Point {
    return rotate(v.x, v.y, degrees);
}

fn pathRule(result: Result, path: critical_paths.Path) net_rules.NetRule {
    if (path.links.len == 0) return .{};
    const net = path.links[path.links.len - 1].net;
    return if (net < result.rules.len) result.rules[net] else .{};
}

fn parallelPathCount(comptime Part: type, parts: []const Part, result: Result, island: critical_paths.Island, path: critical_paths.Path, opts: Options) usize {
    const ray = pathRay(Part, parts, path, opts);
    var count: usize = 0;
    for (island.paths) |other_index| {
        const other = pathRay(Part, parts, result.paths[other_index], opts);
        if (dotPoint(ray, other) > 0.999) count += 1;
    }
    return count;
}

fn preferredFanSign(comptime Part: type, parts: []const Part, path: critical_paths.Path, ray: Point) f64 {
    const hub = parts[path.hub];
    const at = padWorld(Part, parts, path.hubPad());
    const perpendicular = Point{ .x = -ray.y, .y = ray.x };
    const lane = dotPoint(.{ .x = at.x - hub.x, .y = at.y - hub.y }, perpendicular);
    return if (lane < 0) -1 else 1;
}

const TerminalJob = struct {
    result: Result,
    island: critical_paths.Island,
    path: critical_paths.Path,
    ray: Point,
    placed: []const usize,
    opts: Options,
};

/// Place a launch at the end of a feasible one-bend port-frame route. Parallel
/// switch pads fan in opposite 45-degree directions, avoiding the old choice
/// between overlapping SMPMs and a very long longitudinal stagger.
fn placeTerminalRouted(
    comptime Part: type,
    parts: []Part,
    job: TerminalJob,
) bool {
    const result = job.result;
    const island = job.island;
    const path = job.path;
    const ray = job.ray;
    const placed = job.placed;
    const opts = job.opts;
    const terminal_ref = path.terminalPad();
    const terminal = &parts[terminal_ref.part];
    const signal = padOf(Part, terminal.*, terminal_ref.pad);
    const start_ref = path.links[path.links.len - 1].from;
    const start = padWorld(Part, parts, start_ref);
    const rule = pathRule(result, path);
    const width = if (rule.width > 0) rule.width else 0.2;
    const ratio = if (rule.rf.min_bend_ratio > 0) rule.rf.min_bend_ratio else 3;
    const entry = @max(width, rule.rf.escape_mm);
    const base = entry + ratio * width;
    const fan = parallelPathCount(Part, parts, result, island, path, opts) > 1;
    const sign = preferredFanSign(Part, parts, path, ray);
    const offsets = if (fan)
        [5]f64{ sign * 45, 0, -sign * 45, sign * 90, -sign * 90 }
    else
        [5]f64{ 0, sign * 45, -sign * 45, sign * 90, -sign * 90 };
    const scales = [_]f64{ 1, 1.25, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10, 12 };
    const original = terminal.*;
    var best: ?Part = null;
    var best_score = std.math.inf(f64);
    for (offsets) |offset| {
        const heading = rotatePoint(ray, offset);
        // A straight run has no curvature trim at all; charging it one full
        // bend radius on both ends needlessly pushed bottom launches outside
        // the outline. Bent candidates still reserve entry + R before scoring.
        const run_base = if (@abs(offset) <= 1e-9) entry / 2 else base;
        terminal.rot = terminalRotation(Part, terminal.*, signal, heading);
        const local = localAt(Part, terminal.*, signal, terminal.rot);
        for (scales) |scale| {
            const run = run_base * scale;
            const end = Point{
                .x = start.x + ray.x * run + heading.x * run,
                .y = start.y + ray.y * run + heading.y * run,
            };
            terminal.x = end.x - local.x;
            terminal.y = end.y - local.y;
            const frames = portFrames(Part, parts, start_ref, terminal_ref) orelse continue;
            const fit = rf_path_solver.frameFit(frames.start, frames.end, width, ratio, entry);
            if (!fit.feasible) continue;
            if (spokeCollides(Part, parts, path, island.hub, placed, opts)) continue;
            // Search the whole deterministic family. The former first-fit
            // policy could accept a 12 mm preferred fan even when a 3 mm
            // straight or opposite fan was clear, making the island taller
            // than the board. A tiny straight penalty only breaks near-ties
            // between parallel siblings; actual copper length dominates.
            const score = fit.length_mm + @as(f64, if (fan and offset == 0) 0.05 else 0);
            if (score < best_score - 1e-9) {
                best_score = score;
                best = terminal.*;
            }
        }
    }
    if (best) |pose| {
        terminal.* = pose;
        return true;
    }
    terminal.* = original;
    return false;
}

fn placeIsland(
    comptime Part: type,
    arena: std.mem.Allocator,
    parts: []Part,
    result: Result,
    island: critical_paths.Island,
    opts: Options,
) std.mem.Allocator.Error!void {
    const hub = &parts[island.hub];
    hub.x = 0;
    hub.y = 0;
    hub.rot = 0;
    var placed: std.ArrayList(usize) = .empty;
    for (island.paths) |path_index| {
        const path = result.paths[path_index];
        const hub_pad = padOf(Part, hub.*, path.hubPad().pad);
        const hub_point = worldAt(Part, hub.*, hub_pad);
        const ray = pathRay(Part, parts, path, opts);
        var preceding = projectedBoundary(Part, hub.*, ray, opts);

        for (path.series) |step| {
            const part = &parts[step.part];
            const input = padOf(Part, part.*, step.in_pad);
            const output = padOf(Part, part.*, step.out_pad);
            const dx = if (bottom(Part, part.*)) -(output.x - input.x) else output.x - input.x;
            part.rot = axisRotation45(dx, output.y - input.y, ray) orelse part.rot;
            part.rot_pin = .series;
            placePadBeyond(Part, part, input, hub_point, ray, preceding, opts);
            preceding = projectedBoundary(Part, part.*, ray, opts);
        }

        const terminal_ref = path.terminalPad();
        const terminal = &parts[terminal_ref.part];
        const signal = padOf(Part, terminal.*, terminal_ref.pad);
        if (!placeTerminalRouted(Part, parts, .{
            .result = result,
            .island = island,
            .path = path,
            .ray = ray,
            .placed = placed.items,
            .opts = opts,
        })) {
            terminal.rot = terminalRotation(Part, terminal.*, signal, ray);
            placePadBeyond(Part, terminal, signal, hub_point, ray, preceding, opts);
        }

        // Parallel or adjacent launch bodies can still clash even when their
        // pad rays are individually perfect. Stagger the entire later spoke
        // outward on its own ray; this preserves every port-frame tangent and
        // turns a former dogleg into extra straight copper only.
        var attempt: usize = 0;
        while (attempt < 128) : (attempt += 1) {
            if (!spokeCollides(Part, parts, path, island.hub, placed.items, opts)) break;
            moveSpokeOutward(Part, parts, path, ray, opts);
        }
        for (path.series) |step| try placed.append(arena, step.part);
        try placed.append(arena, path.terminal);
    }
}

fn membersBox(comptime Part: type, parts: []const Part, members: []const usize, opts: Options) [4]f64 {
    var out = [4]f64{ std.math.inf(f64), std.math.inf(f64), -std.math.inf(f64), -std.math.inf(f64) };
    for (members) |index| {
        const part = parts[index];
        const box = boxOf(Part, part, opts);
        out[0] = @min(out[0], part.x + box.cxo - box.hw);
        out[1] = @min(out[1], part.y + box.cyo - box.hh);
        out[2] = @max(out[2], part.x + box.cxo + box.hw);
        out[3] = @max(out[3], part.y + box.cyo + box.hh);
    }
    return out;
}

fn translateMembers(comptime Part: type, parts: []Part, members: []const usize, dx: f64, dy: f64, opts: Options) void {
    _ = opts;
    for (members) |index| {
        parts[index].x += dx;
        parts[index].y += dy;
    }
}

fn anyOverlap(comptime Part: type, parts: []const Part, opts: Options) bool {
    for (parts, 0..) |a, i| {
        for (parts[i + 1 ..]) |b| if (overlap(Part, a, b, opts)) return true;
    }
    return false;
}

/// A net's leaf spelling: the segment after the last `/`, matching
/// `router.shortName` / `optimizer.shortName`. Hierarchy is spelled with `/`
/// alone — this also split on `.`, which is the per-pin bypass-stub separator
/// (`net_analysis.baseNetName`'s), so the stub `VDD.U1.3` reduced to the leaf
/// `3` instead of naming a rail. Nothing else in the project reads a net name
/// that way.
fn leafNetName(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name[i + 1 ..] else name;
}

/// True when a net is a ground return, judged by the project's one ground
/// predicate. This kept a private GND/GROUND/VSS exact-match list, which is the
/// very drift `optimizer.isGroundName` was made shared to end: on a split-ground
/// board every AGND/DGND/PGND/GNDA/VSSA net — and every numbered ground — read
/// as an ordinary signal here, so the support-target scan offered them as rough
/// placement targets.
fn isGroundNet(name: []const u8) bool {
    return net_analysis.isGroundName(leafNetName(name));
}

fn betterSupportTarget(candidate: SupportTarget, incumbent: SupportTarget) bool {
    if (candidate.hub_pad_count != incumbent.hub_pad_count) {
        return candidate.hub_pad_count < incumbent.hub_pad_count;
    }
    if (candidate.net_pin_count != incumbent.net_pin_count) {
        return candidate.net_pin_count < incumbent.net_pin_count;
    }
    return candidate.hub < incumbent.hub;
}

fn supportTarget(
    comptime Part: type,
    parts: []const Part,
    part_index: usize,
    result: Result,
    nets: []const critical_paths.FlatNet,
) ?SupportTarget {
    var best: ?SupportTarget = null;
    for (result.islands) |island| {
        const hub = parts[island.hub];
        for (nets) |net| {
            if (isGroundNet(net.name)) continue;
            var own_pad: ?[]const u8 = null;
            var hub_x: f64 = 0;
            var hub_y: f64 = 0;
            var hub_pads: usize = 0;
            for (net.pins) |pin| {
                if (std.mem.eql(u8, pin.ref_des, parts[part_index].ref_des) and own_pad == null) {
                    own_pad = pin.pin;
                }
                if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
                    const pad = padOf(Part, hub, pin.pin);
                    hub_x += pad.x;
                    hub_y += pad.y;
                    hub_pads += 1;
                }
            }
            if (own_pad == null or hub_pads == 0) continue;
            const candidate = SupportTarget{
                .hub = island.hub,
                .hub_x = hub_x / @as(f64, @floatFromInt(hub_pads)),
                .hub_y = hub_y / @as(f64, @floatFromInt(hub_pads)),
                .own_pad = own_pad.?,
                .hub_pad_count = hub_pads,
                .net_pin_count = net.pins.len,
            };
            if (best == null or betterSupportTarget(candidate, best.?)) best = candidate;
        }
    }
    return best;
}

fn collidesWithPlaced(
    comptime Part: type,
    parts: []const Part,
    placed: []const bool,
    part_index: usize,
    opts: Options,
) bool {
    for (parts, placed, 0..) |other, active, other_index| {
        if (active and other_index != part_index and overlap(Part, parts[part_index], other, opts)) return true;
    }
    return false;
}

fn dockSupport(
    comptime Part: type,
    parts: []Part,
    part_index: usize,
    target: SupportTarget,
    placed: []const bool,
    opts: Options,
) void {
    const hub = parts[target.hub];
    const hub_local = localAt(Part, hub, .{
        .number = "",
        .x = target.hub_x,
        .y = target.hub_y,
        .w = 0,
        .h = 0,
    }, hub.rot);
    const edge = targetFromPad(boxOf(Part, hub, opts), hub_local.x, hub_local.y).edge;
    const ray = inward(edge);
    const part = &parts[part_index];
    part.rot = 0;
    const own = padOf(Part, part.*, target.own_pad);
    const own_x = if (bottom(Part, part.*)) -own.x else own.x;
    part.rot = axisRotation(own_x, own.y, ray.x, ray.y) orelse 0;
    placeOutside(Part, part, edge, boundary(Part, hub, edge, opts), opts);
    const want = if (edge < 2) hub.y + hub_local.y else hub.x + hub_local.x;
    alignPad(Part, part, own, edge, want, opts);

    var attempt: usize = 0;
    while (attempt < 256 and collidesWithPlaced(Part, parts, placed, part_index, opts)) : (attempt += 1) {
        const away = outward(edge);
        part.x = gridRound(part.x + away.x * opts.grid_mm, opts);
        part.y = gridRound(part.y + away.y * opts.grid_mm, opts);
    }
}

/// Place every recovered RF island as a rigid exact-pad motif, dock directly
/// connected support passives at their local owner pad, then row-pack remaining
/// parts. Returns false without changing poses when no unambiguous critical
/// topology exists.
pub fn place(
    arena: std.mem.Allocator,
    parts: anytype,
    result: Result,
    nets: []const critical_paths.FlatNet,
    opts: Options,
) std.mem.Allocator.Error!bool {
    const Part = std.meta.Child(@TypeOf(parts));
    if (result.paths.len == 0 or result.islands.len == 0) return false;
    for (parts) |part| if (part.locked) return false;

    const member = try arena.alloc(bool, parts.len);
    @memset(member, false);
    var cursor_x: f64 = 0;
    var row_bottom: f64 = 0;
    for (result.islands) |island| {
        try placeIsland(Part, arena, parts, result, island, opts);
        const local = membersBox(Part, parts, island.members, opts);
        const dx = cursor_x - local[0];
        const dy = -local[1];
        translateMembers(Part, parts, island.members, dx, dy, opts);
        const moved = membersBox(Part, parts, island.members, opts);
        cursor_x = moved[2] + opts.island_gap_mm;
        row_bottom = @max(row_bottom, moved[3]);
        for (island.members) |index| member[index] = true;
    }

    // Attach local support passives after the RF geometry is frozen. A bypass
    // part follows the least-diffuse non-ground net it shares with a local hub,
    // which naturally selects its authored supply pad instead of the plane.
    // Any collision moves the support outward; RF members never move for it.
    const placed = member;
    for (parts, 0..) |part, index| {
        if (placed[index] or part.kind != .passive) continue;
        const target = supportTarget(Part, parts, index, result, nets) orelse continue;
        dockSupport(Part, parts, index, target, placed, opts);
        placed[index] = true;
    }

    // Edge/corner claims run afterwards. Everything not owned by an RF island
    // stays in a separate row so it cannot lengthen a critical launch.
    var occupied_bottom = row_bottom;
    for (parts, placed) |part, active| {
        if (!active) continue;
        const box = boxOf(Part, part, opts);
        occupied_bottom = @max(occupied_bottom, part.y + box.cyo + box.hh);
    }
    var support_x: f64 = 0;
    const support_top = occupied_bottom + opts.island_gap_mm;
    for (parts, 0..) |*part, index| {
        if (placed[index]) continue;
        part.rot = 0;
        const box = boxOf(Part, part.*, opts);
        part.x = gridRound(support_x + box.hw - box.cxo, opts);
        part.y = gridRound(support_top + box.hh - box.cyo, opts);
        support_x += 2 * box.hw + opts.clearance_mm;
        placed[index] = true;
    }
    // This is a seed, not the finished placement. Let the caller's identical
    // routability/legalization pipeline repair any residual body collision,
    // then rank that finished pose. Rejecting here prevented a nearly-correct
    // RF candidate from ever reaching the same finish pass as legacy.
    return finitePathGeometry(Part, parts, result);
}

/// Re-derive ordered two-pad polarity after any later repair or board docking
/// moved a path endpoint.
pub fn orientSeries(comptime Part: type, parts: []Part, result: Result) void {
    for (result.paths) |path| {
        for (path.series) |step| {
            const part = &parts[step.part];
            if (part.locked or part.rot_pin == .authored or part.pads.len != 2) continue;
            var before: ?critical_paths.PadRef = null;
            for (path.links) |link| {
                if (link.to.part == step.part and std.mem.eql(u8, link.to.pad, step.in_pad)) before = link.from;
            }
            const source_ref = before orelse continue;
            const source = padWorld(Part, parts, source_ref);
            const input = padOf(Part, part.*, step.in_pad);
            const output = padOf(Part, part.*, step.out_pad);
            const input_world = worldAt(Part, part.*, input);
            const propagation = unitPoint(.{ .x = input_world.x - source.x, .y = input_world.y - source.y }) orelse continue;
            const source_axis = signedAxis(
                padLongAxis(Part, parts[source_ref.part], padOf(Part, parts[source_ref.part], source_ref.pad)),
                propagation,
            );
            const dx = if (bottom(Part, part.*)) -(output.x - input.x) else output.x - input.x;
            part.rot = axisRotation45(dx, output.y - input.y, source_axis) orelse part.rot;
            part.rot_pin = .series;
        }
    }
}

const TestSide = enum { top, bottom };
const TestRotPin = enum { none, series, authored };
const TestKind = enum { hub, passive };
const TestKeepout = struct {
    ox: f64 = 0,
    oy: f64 = 0,
    hw: f64 = -1,
    hh: f64 = -1,
};

/// Minimal structural twin of the optimizer part fields consumed by the
/// generic rougher. Keeping it local makes this module's tests exercise the
/// cycle-free public seam instead of importing `optimizer.zig` back into it.
const TestPart = struct {
    ref_des: []const u8,
    pads: []const geometry.Pad,
    kind: TestKind,
    hw: f64,
    hh: f64,
    ccx: f64 = 0,
    ccy: f64 = 0,
    keep: TestKeepout = .{},
    side: TestSide = .top,
    x: f64 = 0,
    y: f64 = 0,
    rot: f64 = 0,
    rot_pin: TestRotPin = .none,
    locked: bool = false,
};

fn testPad(number: []const u8, x: f64, y: f64) geometry.Pad {
    return .{ .number = number, .x = x, .y = y, .w = 0.2, .h = 0.2 };
}

fn testDistance(a: Point, b: Point) f64 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}

fn expectSignalFacesHub(parts: []const TestPart, hub: usize, terminal: critical_paths.PadRef) !void {
    const launch = parts[terminal.part];
    const signal = worldAt(TestPart, launch, padOf(TestPart, launch, terminal.pad));
    const pad_vector = Point{ .x = signal.x - launch.x, .y = signal.y - launch.y };
    const toward_hub = Point{ .x = parts[hub].x - launch.x, .y = parts[hub].y - launch.y };
    try std.testing.expect(pad_vector.x * toward_hub.x + pad_vector.y * toward_hub.y > 0);
}

// spec: placement/optimizer - the design-level critical rough judges ground with the project's one predicate, so a split or numbered ground is never mistaken for signal
test "critical rough classifies ground by the shared predicate, leafing on '/' alone" {
    // The private GND/GROUND/VSS exact-match list this replaces read every one
    // of these as an ordinary signal, so `supportTarget` offered a split-ground
    // board's returns as rough placement targets.
    const cases = [_]struct { name: []const u8, ground: bool }{
        .{ .name = "GND", .ground = true },        .{ .name = "GND1", .ground = true },
        .{ .name = "AGND", .ground = true },       .{ .name = "DGND", .ground = true },
        .{ .name = "PGND", .ground = true },       .{ .name = "PGND_2", .ground = true },
        .{ .name = "GNDA", .ground = true },       .{ .name = "GNDD", .ground = true },
        .{ .name = "VSS", .ground = true },        .{ .name = "VSSA", .ground = true },
        .{ .name = "amp1/AGND", .ground = true },  .{ .name = "V_3V3", .ground = false },
        .{ .name = "GND_SENSE", .ground = false }, .{ .name = "GNDSW", .ground = false },
        .{ .name = "RF_IN", .ground = false },
    };
    for (cases) |c| try std.testing.expectEqual(c.ground, isGroundNet(c.name));
    // Hierarchy is `/` alone. Splitting on `.` as well reduced the per-pin
    // bypass stub `VDD.U1.3` to the leaf `3`, which named no rail at all.
    try std.testing.expectEqualStrings("VDD.U1.3", leafNetName("amp1/VDD.U1.3"));
    try std.testing.expect(!isGroundNet("amp1/VDD.U1.3"));
}

test "critical rough places two RF islands with ordered pads and inward launches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Island one has two close east-facing U1 -> C -> J series paths, forcing
    // lane packing. Island two is a west-facing direct U2 -> J2 path. The
    // launch signal pads are offset from the footprint origins like the vertical
    // SMPM footprint, which lets the rougher choose inward-facing rotation.
    const u1_pads = [_]geometry.Pad{ testPad("RF", 1.2, -0.3), testPad("RF2", 1.2, 0.3) };
    const cap_pads = [_]geometry.Pad{ testPad("1", -0.35, 0), testPad("2", 0.35, 0) };
    const j1_pads = [_]geometry.Pad{testPad("1", -0.7, 0)};
    const u2_pads = [_]geometry.Pad{testPad("RF", -1.2, -0.2)};
    const j2_pads = [_]geometry.Pad{testPad("1", 0.7, 0)};
    const support_pads = [_]geometry.Pad{testPad("1", 0, 0)};
    var parts = [_]TestPart{
        .{ .ref_des = "U1", .pads = &u1_pads, .kind = .hub, .hw = 1.5, .hh = 1.5 },
        .{ .ref_des = "C1", .pads = &cap_pads, .kind = .passive, .hw = 0.5, .hh = 0.25 },
        .{ .ref_des = "J1", .pads = &j1_pads, .kind = .hub, .hw = 1.0, .hh = 1.0 },
        .{ .ref_des = "U2", .pads = &u2_pads, .kind = .hub, .hw = 1.5, .hh = 1.5 },
        .{ .ref_des = "J2", .pads = &j2_pads, .kind = .hub, .hw = 1.0, .hh = 1.0 },
        .{ .ref_des = "C_CTL", .pads = &support_pads, .kind = .passive, .hw = 0.8, .hh = 0.5 },
        .{ .ref_des = "C2", .pads = &cap_pads, .kind = .passive, .hw = 0.5, .hh = 0.25 },
        .{ .ref_des = "J3", .pads = &j1_pads, .kind = .hub, .hw = 1.0, .hh = 1.0 },
    };

    const series_links = [_]critical_paths.Link{
        .{ .net = 0, .from = .{ .part = 0, .pad = "RF" }, .to = .{ .part = 1, .pad = "1" } },
        .{ .net = 1, .from = .{ .part = 1, .pad = "2" }, .to = .{ .part = 2, .pad = "1" } },
    };
    const series_steps = [_]critical_paths.SeriesStep{.{ .part = 1, .in_pad = "1", .out_pad = "2" }};
    const second_series_links = [_]critical_paths.Link{
        .{ .net = 2, .from = .{ .part = 0, .pad = "RF2" }, .to = .{ .part = 6, .pad = "1" } },
        .{ .net = 3, .from = .{ .part = 6, .pad = "2" }, .to = .{ .part = 7, .pad = "1" } },
    };
    const second_series_steps = [_]critical_paths.SeriesStep{.{ .part = 6, .in_pad = "1", .out_pad = "2" }};
    const direct_links = [_]critical_paths.Link{
        .{ .net = 4, .from = .{ .part = 3, .pad = "RF" }, .to = .{ .part = 4, .pad = "1" } },
    };
    const paths = [_]critical_paths.Path{
        .{ .hub = 0, .terminal = 2, .links = &series_links, .series = &series_steps, .importance = .{} },
        .{ .hub = 0, .terminal = 7, .links = &second_series_links, .series = &second_series_steps, .importance = .{} },
        .{ .hub = 3, .terminal = 4, .links = &direct_links, .series = &.{}, .importance = .{} },
    };
    const island_one_paths = [_]usize{ 0, 1 };
    const island_two_paths = [_]usize{2};
    const island_one_members = [_]usize{ 0, 1, 2, 6, 7 };
    const island_two_members = [_]usize{ 3, 4 };
    const islands = [_]critical_paths.Island{
        .{ .hub = 0, .paths = &island_one_paths, .members = &island_one_members },
        .{ .hub = 3, .paths = &island_two_paths, .members = &island_two_members },
    };
    const roles = [_]critical_paths.ResolvedRole{ .anchor, .series, .terminal, .anchor, .terminal, .other, .series, .terminal };
    const result = Result{ .roles = &roles, .paths = &paths, .islands = &islands, .diagnostics = .{} };
    const opts = Options{ .clearance_mm = 0.2, .island_gap_mm = 2.0 };
    const initial = parts;

    const part_slice: []TestPart = parts[0..];
    try std.testing.expect(try place(arena, part_slice, result, &.{}, opts));

    const hub_pad = padWorld(TestPart, &parts, paths[0].hubPad());
    const cap_input = worldAt(TestPart, parts[1], padOf(TestPart, parts[1], "1"));
    const cap_output = worldAt(TestPart, parts[1], padOf(TestPart, parts[1], "2"));
    const launch_pad = padWorld(TestPart, &parts, paths[0].terminalPad());
    try std.testing.expectEqual(TestRotPin.series, parts[1].rot_pin);
    try std.testing.expect(testDistance(hub_pad, cap_input) < testDistance(hub_pad, cap_output));
    try std.testing.expect(testDistance(launch_pad, cap_output) < testDistance(launch_pad, cap_input));
    const launch_fit = rf_path_solver.frameFit(
        portFrames(TestPart, &parts, series_links[1].from, series_links[1].to).?.start,
        portFrames(TestPart, &parts, series_links[1].from, series_links[1].to).?.end,
        0.2,
        3,
        0.2,
    );
    try std.testing.expect(launch_fit.feasible);

    const cap2_input = worldAt(TestPart, parts[6], padOf(TestPart, parts[6], "1"));
    const cap2_output = worldAt(TestPart, parts[6], padOf(TestPart, parts[6], "2"));
    try std.testing.expectEqual(TestRotPin.series, parts[6].rot_pin);
    try std.testing.expectApproxEqAbs(cap2_input.y, cap2_output.y, opts.grid_mm + 1e-9);
    const launch2_frames = portFrames(TestPart, &parts, second_series_links[1].from, second_series_links[1].to).?;
    try std.testing.expect(rf_path_solver.frameFit(launch2_frames.start, launch2_frames.end, 0.2, 3, 0.2).feasible);

    try expectSignalFacesHub(&parts, paths[0].hub, paths[0].terminalPad());
    try expectSignalFacesHub(&parts, paths[1].hub, paths[1].terminalPad());
    try expectSignalFacesHub(&parts, paths[2].hub, paths[2].terminalPad());

    // Islands are packed left-to-right with the requested gap; unrelated
    // support is below the entire RF row. The final pairwise check covers
    // internal island members as well as every cross-island/support pair.
    const first_box = membersBox(TestPart, &parts, &island_one_members, opts);
    const second_box = membersBox(TestPart, &parts, &island_two_members, opts);
    const support_box = membersBox(TestPart, &parts, &.{5}, opts);
    try std.testing.expect(first_box[2] + opts.island_gap_mm <= second_box[0] + 1e-9);
    try std.testing.expect(@max(first_box[3], second_box[3]) + opts.island_gap_mm <= support_box[1] + 1e-9);
    try std.testing.expect(!anyOverlap(TestPart, &parts, opts));

    var finish_count: usize = 0;
    const Legacy = struct {
        result: Result,
        finish_count: *usize,

        fn legacy(_: @This(), _: std.mem.Allocator, candidate: []TestPart) std.mem.Allocator.Error!bool {
            for (candidate, 0..) |*part, i| {
                part.x = @floatFromInt(i * 10);
                part.y = 0;
                part.rot = if (i == 1) 90 else 0;
                part.rot_pin = .none;
            }
            return true;
        }

        fn finish(self: @This(), _: std.mem.Allocator, candidate: []TestPart) std.mem.Allocator.Error!void {
            self.finish_count.* += 1;
            // Deliberately damage only the compact critical seed. Arbitration
            // must score this finished geometry, not the attractive pre-finish
            // seed, and therefore retain the finished legacy arrangement.
            if (candidate[1].x < 5) {
                candidate[2].x = candidate[0].x;
                candidate[2].y = candidate[0].y;
            }
            orientSeries(TestPart, candidate, self.result);
        }

        fn cost(_: @This(), _: std.mem.Allocator, _: []TestPart) std.mem.Allocator.Error!f64 {
            return 0;
        }
    };
    var arbitrated = initial;
    try std.testing.expect(try arbitrate(TestPart, Legacy, Legacy.legacy, Legacy.finish, Legacy.cost, arena, &arbitrated, result, &.{}, opts, .{ .result = result, .finish_count = &finish_count }));
    try std.testing.expectEqual(@as(usize, 2), finish_count);
    try std.testing.expectApproxEqAbs(@as(f64, 10), arbitrated[1].x, 1e-9);
    const arb_hub = padWorld(TestPart, &arbitrated, paths[0].hubPad());
    const arb_input = worldAt(TestPart, arbitrated[1], padOf(TestPart, arbitrated[1], "1"));
    const arb_output = worldAt(TestPart, arbitrated[1], padOf(TestPart, arbitrated[1], "2"));
    try std.testing.expect(testDistance(arb_hub, arb_input) < testDistance(arb_hub, arb_output));
    try std.testing.expectEqual(TestRotPin.series, arbitrated[1].rot_pin);
}

test "critical rank enforces authored board capacity for interior parts" {
    const pads = [_]geometry.Pad{testPad("1", 0, 0)};
    const parts = [_]TestPart{
        .{ .ref_des = "U1", .pads = &pads, .kind = .hub, .hw = 2, .hh = 1 },
        .{ .ref_des = "J1", .pads = &pads, .kind = .hub, .hw = 1, .hh = 1, .x = 100 },
    };
    const result = Result{ .roles = &.{}, .paths = &.{}, .islands = &.{}, .diagnostics = .{} };
    const claimed = [_]bool{ false, true };

    const fits = rank(TestPart, &parts, result, 0, .{
        // Collision shrink must not make a physically oversized board fit.
        .collide_shrink_mm = 10,
        .containment = .{
            .width_mm = 6,
            .height_mm = 4,
            .edge_clearance_mm = 1,
            .ignored = &claimed,
        },
    });
    try std.testing.expectEqual(@as(usize, 0), fits.hard_violations);

    const too_narrow = rank(TestPart, &parts, result, 0, .{
        .collide_shrink_mm = 10,
        .containment = .{
            .width_mm = 5.9,
            .height_mm = 4,
            .edge_clearance_mm = 1,
            .ignored = &claimed,
        },
    });
    try std.testing.expectEqual(@as(usize, 1), too_narrow.hard_violations);

    const includes_claimed = rank(TestPart, &parts, result, 0, .{
        .containment = .{
            .width_mm = 6,
            .height_mm = 4,
            .edge_clearance_mm = 1,
        },
    });
    try std.testing.expectEqual(@as(usize, 1), includes_claimed.hard_violations);
}
