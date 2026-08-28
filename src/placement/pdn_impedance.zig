//! Fast post-route board-level PDN impedance screen.
//!
//! Each authored `(pdn "NET" …)` becomes one AC domain. Bound decoupling
//! loops on that *physical* net remain separate (ferrites are deliberately not
//! unioned as they are in the DC budget), and each capacitor is a series RLC
//! branch whose C/ESR/ESL comes from the selected BOM row. Mounting inductance
//! is added independently from the actual pad locations, shortest connected
//! routed or computed-pour power path, nearby ground-via locations, and stackup
//! reference-plane height. The branches plus a regulator/source RL model are solved as a
//! lumped one-port over a logarithmic sweep. This is a screening model: fast,
//! deterministic and actionable, but not a plane-cavity/package solver.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const impedance = @import("impedance.zig");
const pour = @import("pour.zig");
const flat_netlist = @import("../flat_netlist.zig");
const decouple_key = @import("../decouple_key.zig");
const net_names = @import("../net_name.zig");
const numeric = @import("../numeric.zig");

const two_pi = 2.0 * std.math.pi;
const mu0_nh_per_mm = 1.2566370614359172;
const default_points_per_decade: usize = 16;
const min_sweep_points: usize = 33;
const max_sweep_points: usize = 161;
const peak_prominence_db = 3.0;
const ineffective_db = 1.0;

fn capPathComplete(cap: Capacitor) bool {
    return !std.mem.eql(u8, cap.path_kind.power, "fallback") and
        (std.mem.eql(u8, cap.path_kind.ground, "computed-pour") or
            std.mem.eql(u8, cap.path_kind.ground, "computed-via-plane"));
}

/// One sampled complex-impedance result, stored as magnitude and phase.
pub const Point = struct {
    frequency_hz: f64,
    magnitude_ohm: f64,
    phase_deg: f64,
};

/// A prominent local maximum in the impedance sweep.
pub const Peak = struct {
    frequency_hz: f64,
    magnitude_ohm: f64,
    above_target: bool,
};

/// Extracted component and mounting model for one bound decoupling capacitor.
pub const Capacitor = struct {
    ref_des: []const u8,
    target_ref_des: []const u8,
    target_pin: []const u8,
    value: []const u8,
    model_source: []const u8,
    capacitance_f: f64,
    effective_factor: f64,
    esr_ohm: f64,
    intrinsic_esl_h: f64,
    mounting_inductance_h: f64,
    power_path_mm: f64,
    ground_path_mm: f64,
    /// Each leg reports the copper model that earned its mounting-inductance
    /// credit; neither a whole pour nor an assumed via becomes equipotential.
    path_kind: struct {
        power: []const u8,
        ground: []const u8,
    },
    model_estimated: bool,
    mounted_srf_hz: f64,
    removal_impact_db: f64 = 0,
    ideal_mount_improvement_db: f64 = 0,
    ineffective: bool = false,
};

/// Complete target, sweep, diagnostics, and model for one physical AC domain.
pub const Rail = struct {
    net: []const u8,
    ripple_v: f64,
    step_current_a: ?f64,
    step_assumed: bool,
    target_ohm: ?f64,
    source_resistance_ohm: f64,
    source_inductance_h: f64,
    source_assumed: bool,
    verdict_max_hz: f64,
    points: []const Point,
    peaks: []const Peak,
    capacitors: []Capacitor,
    worst_frequency_hz: f64,
    worst_magnitude_ohm: f64,
    passes: ?bool,
};

/// All explicitly authored AC-domain screens on a routed board.
pub const Analysis = struct { rails: []const Rail };

const Cx = struct { re: f64 = 0, im: f64 = 0 };

fn add(a: Cx, b: Cx) Cx {
    return .{ .re = a.re + b.re, .im = a.im + b.im };
}

fn admittance(r: f64, x: f64) Cx {
    const d = r * r + x * x;
    if (!(d > 0)) return .{ .re = 1.0e30 };
    return .{ .re = r / d, .im = -x / d };
}

fn impedanceOf(y: Cx) Cx {
    const d = y.re * y.re + y.im * y.im;
    if (!(d > 0)) return .{ .re = 1.0e30 };
    return .{ .re = y.re / d, .im = -y.im / d };
}

fn magnitude(z: Cx) f64 {
    return std.math.hypot(z.re, z.im);
}

fn property(inst: anytype, key: []const u8) ?[]const u8 {
    for (inst.properties) |p| if (std.ascii.eqlIgnoreCase(p.key, key)) return p.value;
    return null;
}

fn propertyNumber(inst: anytype, key: []const u8) ?f64 {
    const raw = property(inst, key) orelse return null;
    return std.fmt.parseFloat(f64, raw) catch null;
}

fn railVoltage(p: optimizer.Placement, net: []const u8) ?f64 {
    for (p.rules.physical.rail_specs) |rail| {
        if (intentMatches(net, rail.name)) return rail.nominal;
        for (rail.aliases) |alias| if (intentMatches(net, alias)) return rail.nominal;
    }
    return null;
}

/// Piecewise-linear `volts:factor` table used by characterized MLCC rows, for
/// example `0:1,3.3:0.56,5:0.38`. Refuse malformed/non-monotonic data rather
/// than silently applying a guessed derating. Endpoints clamp conservatively
/// to the nearest characterized voltage.
fn biasFactor(raw: []const u8, voltage: f64) ?f64 {
    var it = std.mem.splitScalar(u8, raw, ',');
    var previous_v: ?f64 = null;
    var previous_factor: f64 = 0;
    var interpolated: ?f64 = null;
    while (it.next()) |entry_raw| {
        const entry = std.mem.trim(u8, entry_raw, " \t");
        const colon = std.mem.indexOfScalar(u8, entry, ':') orelse return null;
        const v = std.fmt.parseFloat(f64, std.mem.trim(u8, entry[0..colon], " \t")) catch return null;
        const factor = std.fmt.parseFloat(f64, std.mem.trim(u8, entry[colon + 1 ..], " \t")) catch return null;
        if (!(v >= 0 and factor > 0 and factor <= 1.5)) return null;
        if (previous_v) |pv| {
            if (!(v > pv)) return null;
            if (interpolated == null and voltage <= v) {
                const t = std.math.clamp((voltage - pv) / (v - pv), 0, 1);
                interpolated = previous_factor + t * (factor - previous_factor);
            }
        } else if (voltage <= v) interpolated = factor;
        previous_v = v;
        previous_factor = factor;
    }
    return interpolated orelse if (previous_v != null) previous_factor else null;
}

fn effectiveCapacitance(inst: flat_netlist.FlatInstance, nominal: f64, voltage: ?f64) f64 {
    if (propertyNumber(inst, "pdn-c-effective-f")) |explicit| return explicit;
    var factor = propertyNumber(inst, "pdn-cap-factor") orelse 1.0;
    if (voltage) |v| if (property(inst, "pdn-dc-bias-curve")) |curve| {
        factor *= biasFactor(curve, v) orelse 1.0;
    };
    factor *= propertyNumber(inst, "pdn-tolerance-factor") orelse 1.0;
    factor *= propertyNumber(inst, "pdn-temperature-factor") orelse 1.0;
    return nominal * factor;
}

fn packageDefaultEsl(component: []const u8) f64 {
    if (std.mem.indexOf(u8, component, "0201") != null) return 0.20e-9;
    if (std.mem.indexOf(u8, component, "0402") != null) return 0.40e-9;
    if (std.mem.indexOf(u8, component, "0603") != null) return 0.65e-9;
    if (std.mem.indexOf(u8, component, "0805") != null) return 0.90e-9;
    return 1.20e-9;
}

fn defaultEsr(c: f64) f64 {
    if (!(c > 0)) return 0.1;
    return std.math.clamp(0.018 * @sqrt(100.0e-9 / c), 0.004, 0.20);
}

fn intentMatches(intent_net: []const u8, actual: []const u8) bool {
    return std.ascii.eqlIgnoreCase(intent_net, actual) or
        std.ascii.eqlIgnoreCase(intent_net, net_names.leaf(actual));
}

fn railForIntent(p: optimizer.Placement, net: []const u8) ?@import("../eval/power_budget.zig").Rail {
    for (p.rules.physical.rails) |rail| {
        if (intentMatches(net, rail.net)) return rail;
        for (rail.consumers) |consumer| if (intentMatches(net, consumer.net)) return rail;
    }
    return null;
}

fn inferredStep(p: optimizer.Placement, net: []const u8) ?f64 {
    const rail = railForIntent(p, net) orelse return null;
    if (rail.any_max_load and rail.any_typ_load and rail.load_max_a > rail.load_typ_a)
        return rail.load_max_a - rail.load_typ_a;
    if (rail.any_max_load and rail.load_max_a > 0) return rail.load_max_a;
    return null;
}

fn pointSegmentDistance(p: [2]f64, t: router.Track) f64 {
    const dx = t.x2 - t.x1;
    const dy = t.y2 - t.y1;
    const den = dx * dx + dy * dy;
    if (!(den > 0)) return std.math.hypot(p[0] - t.x1, p[1] - t.y1);
    const u = std.math.clamp(((p[0] - t.x1) * dx + (p[1] - t.y1) * dy) / den, 0, 1);
    return std.math.hypot(p[0] - (t.x1 + u * dx), p[1] - (t.y1 + u * dy));
}

fn samePoint(x1: f64, y1: f64, x2: f64, y2: f64) bool {
    return std.math.hypot(x1 - x2, y1 - y2) <= 1.0e-5;
}

const RoutePath = struct {
    length_mm: f64,
    width_mm: f64,
    /// Filled sheets integrate their finite local width directly. Explicit
    /// tracks leave this null and use the ordinary trace formula.
    inductance_nh: ?f64 = null,
    provenance: []const u8 = "computed-pour",
};

const PouredSurface = struct {
    net: []const u8,
    /// Routable signal layer for an outer/inner user pour; null for a
    /// dedicated inner plane.
    layer: ?u8,
    /// Physical 1-based copper stack position (zero only for legacy/ad-hoc
    /// surfaces whose position cannot be established).
    stack: u8,
    fill: pour.Fill,
};

const CopperPaths = struct {
    power: []?RoutePath,
    ground: []?RoutePath,
};

const PathRequest = struct {
    net: i32,
    start: [2]f64,
    finish: [2]f64,
    start_reach: f64,
    finish_reach: f64,
    board_mm: f64,
};

fn relaxPath(dist: []f64, widths: []f64, node: usize, candidate: f64, width: f64) void {
    if (candidate >= dist[node]) return;
    dist[node] = candidate;
    widths[node] = width;
}

fn considerPath(answer: *f64, answer_width: *f64, candidate: f64, width: f64) void {
    if (candidate >= answer.*) return;
    answer.* = candidate;
    answer_width.* = width;
}

/// Shortest connected copper-centreline path between two pads. Router output
/// normally terminates segments at junctions; exact endpoint contacts and
/// through-via coordinates are therefore enough for this local extraction.
fn routedPath(
    alloc: std.mem.Allocator,
    routed: router.RouteResult,
    request: PathRequest,
) std.mem.Allocator.Error!?RoutePath {
    const net = request.net;
    const start = request.start;
    const finish = request.finish;
    const start_reach = request.start_reach;
    const finish_reach = request.finish_reach;
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(alloc);
    for (routed.tracks, 0..) |t, i| if (t.net == net) try indices.append(alloc, i);
    if (indices.items.len == 0) return null;
    const n = indices.items.len * 2;
    const dist = try alloc.alloc(f64, n);
    defer alloc.free(dist);
    const used = try alloc.alloc(bool, n);
    defer alloc.free(used);
    const path_width = try alloc.alloc(f64, n);
    defer alloc.free(path_width);
    @memset(dist, std.math.inf(f64));
    @memset(used, false);
    @memset(path_width, 0);
    for (indices.items, 0..) |ri, i| {
        const t = routed.tracks[ri];
        if (pointSegmentDistance(start, t) <= start_reach + t.width / 2.0 + 1.0e-5) {
            dist[2 * i] = std.math.hypot(start[0] - t.x1, start[1] - t.y1);
            dist[2 * i + 1] = std.math.hypot(start[0] - t.x2, start[1] - t.y2);
            path_width[2 * i] = t.width;
            path_width[2 * i + 1] = t.width;
        }
    }
    var iteration: usize = 0;
    while (iteration < n) : (iteration += 1) {
        var best = std.math.inf(f64);
        var u: ?usize = null;
        for (dist, 0..) |d, i| if (!used[i] and d < best) {
            best = d;
            u = i;
        };
        const node = u orelse break;
        used[node] = true;
        const ti = node / 2;
        const t = routed.tracks[indices.items[ti]];
        const x = if (node % 2 == 0) t.x1 else t.x2;
        const y = if (node % 2 == 0) t.y1 else t.y2;
        const other = if (node % 2 == 0) node + 1 else node - 1;
        const across = best + std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        relaxPath(dist, path_width, other, across, if (path_width[node] > 0) @min(path_width[node], t.width) else t.width);
        for (indices.items, 0..) |rj, j| {
            const q = routed.tracks[rj];
            if (q.layer == t.layer) {
                if (samePoint(x, y, q.x1, q.y1)) relaxPath(dist, path_width, 2 * j, best, @min(path_width[node], q.width));
                if (samePoint(x, y, q.x2, q.y2)) relaxPath(dist, path_width, 2 * j + 1, best, @min(path_width[node], q.width));
            }
        }
        for (routed.vias) |via| {
            if (via.net != net or !samePoint(x, y, via.x, via.y)) continue;
            for (indices.items, 0..) |rj, j| {
                const q = routed.tracks[rj];
                const jumped = best + request.board_mm;
                if (samePoint(x, y, q.x1, q.y1)) relaxPath(dist, path_width, 2 * j, jumped, @min(path_width[node], q.width));
                if (samePoint(x, y, q.x2, q.y2)) relaxPath(dist, path_width, 2 * j + 1, jumped, @min(path_width[node], q.width));
            }
        }
    }
    var answer = std.math.inf(f64);
    var answer_width: f64 = 0;
    for (indices.items, 0..) |ri, i| {
        const t = routed.tracks[ri];
        if (pointSegmentDistance(finish, t) > finish_reach + t.width / 2.0 + 1.0e-5) continue;
        const first_answer = dist[2 * i] + std.math.hypot(finish[0] - t.x1, finish[1] - t.y1);
        considerPath(&answer, &answer_width, first_answer, @min(path_width[2 * i], t.width));
        const second_answer = dist[2 * i + 1] + std.math.hypot(finish[0] - t.x2, finish[1] - t.y2);
        considerPath(&answer, &answer_width, second_answer, @min(path_width[2 * i + 1], t.width));
    }
    if (!std.math.isFinite(answer)) return null;
    return .{ .length_mm = answer, .width_mm = if (answer_width > 0) answer_width else 0.2 };
}

fn routedSurfacePath(alloc: std.mem.Allocator, routed: router.RouteResult, layer: u8, request: PathRequest) std.mem.Allocator.Error!?RoutePath {
    var tracks: std.ArrayList(router.Track) = .empty;
    defer tracks.deinit(alloc);
    for (routed.tracks) |track| if (track.layer == layer) try tracks.append(alloc, track);
    var surface = routed;
    surface.tracks = tracks.items;
    surface.vias = &.{};
    return routedPath(alloc, surface, request);
}

fn transverseWidth(fill: pour.Fill, component: i32, at: [2]f64, normal: [2]f64) f64 {
    const step = fill.frame.pitch / 2.0;
    var width = step;
    for ([_]f64{ -1, 1 }) |sign| {
        var distance = step;
        while (distance <= 100.0) : (distance += step) {
            const sample = [2]f64{ at[0] + sign * normal[0] * distance, at[1] + sign * normal[1] * distance };
            if (fill.componentAt(sample[0], sample[1]) != component) break;
            width += step;
        }
    }
    return width;
}

/// A conservative sheet-inductance path through exact computed copper. Both
/// pad centres and every half-pitch sample of the direct corridor must remain
/// in one kept fill component. A hole, slot, island split, or coarsened raster
/// refuses credit instead of treating the whole component as equipotential.
/// Local transverse fill width is further capped by 45-degree spreading from
/// each pad contact, then harmonically integrated along the corridor.
fn fillPath(
    fill: pour.Fill,
    start: [2]f64,
    finish: [2]f64,
    start_width: f64,
    finish_width: f64,
    reference_height: f64,
) ?RoutePath {
    if (fill.coarsened or !(fill.frame.pitch > 0)) return null;
    const component = fill.componentAt(start[0], start[1]);
    if (component < 0 or fill.componentAt(finish[0], finish[1]) != component) return null;
    const length = std.math.hypot(finish[0] - start[0], finish[1] - start[1]);
    if (!(length > 0)) return .{ .length_mm = 0, .width_mm = @max(@min(start_width, finish_width), 0.05) };
    const tangent = [2]f64{ (finish[0] - start[0]) / length, (finish[1] - start[1]) / length };
    const normal = [2]f64{ -tangent[1], tangent[0] };
    const steps = @max(@as(usize, 1), numeric.toCount(@ceil(length / (fill.frame.pitch / 2.0))));
    const ds = length / @as(f64, @floatFromInt(steps));
    var squares: f64 = 0;
    for (0..steps + 1) |i| {
        const fraction = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const at = [2]f64{ start[0] + (finish[0] - start[0]) * fraction, start[1] + (finish[1] - start[1]) * fraction };
        if (fill.componentAt(at[0], at[1]) != component) return null;
        const from_start = length * fraction;
        const from_finish = length - from_start;
        const spreading_cap = @min(start_width + 2.0 * from_start, finish_width + 2.0 * from_finish);
        const local_width = @max(@min(transverseWidth(fill, component, at, normal), spreading_cap), 0.05);
        const weight: f64 = if (i == 0 or i == steps) 0.5 else 1.0;
        squares += weight * ds / local_width;
    }
    if (!(squares > 0)) return null;
    return .{
        .length_mm = length,
        .width_mm = length / squares,
        .inductance_nh = mu0_nh_per_mm * @max(reference_height, 0.02) * squares,
    };
}

fn fillCell(fill: pour.Fill, at: [2]f64) ?usize {
    const frame = fill.frame;
    if (!(frame.pitch > 0)) return null;
    const fi = @floor((at[0] - frame.minx) / frame.pitch);
    const fj = @floor((at[1] - frame.miny) / frame.pitch);
    if (fi < 0 or fj < 0) return null;
    const i = numeric.checkedInt(usize, fi) orelse return null;
    const j = numeric.checkedInt(usize, fj) orelse return null;
    if (i >= frame.nx or j >= frame.ny) return null;
    return j * frame.nx + i;
}

fn fillCellCenter(fill: pour.Fill, cell: usize) [2]f64 {
    const i = cell % fill.frame.nx;
    const j = cell / fill.frame.nx;
    return .{
        fill.frame.minx + (@as(f64, @floatFromInt(i)) + 0.5) * fill.frame.pitch,
        fill.frame.miny + (@as(f64, @floatFromInt(j)) + 0.5) * fill.frame.pitch,
    };
}

/// A conservative four-connected shortest path through one exact fill
/// component. The direct half-pitch corridor remains the fast path; this
/// fallback proves real copper that bends around an antipad or clearance slot
/// without treating the whole pour as equipotential. Four-connectivity is the
/// fill labeller's own connectivity and slightly overstates diagonal length.
const FillPathRequest = struct {
    start: [2]f64,
    finish: [2]f64,
    start_width: f64,
    finish_width: f64,
    reference_height: f64,
};

fn connectedFillPath(alloc: std.mem.Allocator, fill: pour.Fill, request: FillPathRequest) std.mem.Allocator.Error!?RoutePath {
    const start = request.start;
    const finish = request.finish;
    const start_width = request.start_width;
    const finish_width = request.finish_width;
    const reference_height = request.reference_height;
    if (fillPath(fill, start, finish, start_width, finish_width, reference_height)) |direct| return direct;
    if (fill.coarsened or fill.labels.len == 0) return null;
    const component = fill.componentAt(start[0], start[1]);
    if (component < 0 or fill.componentAt(finish[0], finish[1]) != component) return null;
    const start_cell = fillCell(fill, start) orelse return null;
    const finish_cell = fillCell(fill, finish) orelse return null;
    const n = fill.labels.len;
    const unseen: i32 = -2;
    const root: i32 = -1;
    const previous = try alloc.alloc(i32, n);
    defer alloc.free(previous);
    @memset(previous, unseen);
    const queue = try alloc.alloc(u32, n);
    defer alloc.free(queue);
    previous[start_cell] = root;
    queue[0] = @intCast(start_cell);
    var head: usize = 0;
    var tail: usize = 1;
    while (head < tail and previous[finish_cell] == unseen) : (head += 1) {
        const cell: usize = queue[head];
        const i = cell % fill.frame.nx;
        const j = cell / fill.frame.nx;
        const candidates = [_]?usize{
            if (i > 0) cell - 1 else null,
            if (i + 1 < fill.frame.nx) cell + 1 else null,
            if (j > 0) cell - fill.frame.nx else null,
            if (j + 1 < fill.frame.ny) cell + fill.frame.nx else null,
        };
        for (candidates) |maybe_next| {
            const next = maybe_next orelse continue;
            if (previous[next] != unseen or fill.labels[next] != component) continue;
            previous[next] = @intCast(cell);
            queue[tail] = @intCast(next);
            tail += 1;
        }
    }
    if (previous[finish_cell] == unseen) return null;

    var count: usize = 1;
    var cursor = finish_cell;
    while (cursor != start_cell) : (count += 1) cursor = @intCast(previous[cursor]);
    const cells = try alloc.alloc(usize, count);
    defer alloc.free(cells);
    cursor = finish_cell;
    var out_i = count;
    while (true) {
        out_i -= 1;
        cells[out_i] = cursor;
        if (cursor == start_cell) break;
        cursor = @intCast(previous[cursor]);
    }

    var total: f64 = 0;
    var prior = start;
    for (cells) |cell| {
        const at = fillCellCenter(fill, cell);
        total += std.math.hypot(at[0] - prior[0], at[1] - prior[1]);
        prior = at;
    }
    total += std.math.hypot(finish[0] - prior[0], finish[1] - prior[1]);
    if (!(total > 0)) return .{ .length_mm = 0, .width_mm = @max(@min(start_width, finish_width), 0.05) };

    var squares: f64 = 0;
    var travelled: f64 = 0;
    prior = start;
    var segment_index: usize = 0;
    while (segment_index <= cells.len) : (segment_index += 1) {
        const next = if (segment_index < cells.len) fillCellCenter(fill, cells[segment_index]) else finish;
        const dx = next[0] - prior[0];
        const dy = next[1] - prior[1];
        const ds = std.math.hypot(dx, dy);
        if (ds > 0) {
            const midpoint = [2]f64{ prior[0] + dx / 2.0, prior[1] + dy / 2.0 };
            if (fill.componentAt(midpoint[0], midpoint[1]) != component) return null;
            const normal = [2]f64{ -dy / ds, dx / ds };
            const mid_distance = travelled + ds / 2.0;
            const spreading_cap = @min(start_width + 2.0 * mid_distance, finish_width + 2.0 * (total - mid_distance));
            const local_width = @max(@min(transverseWidth(fill, component, midpoint, normal), spreading_cap), 0.05);
            squares += ds / local_width;
            travelled += ds;
        }
        prior = next;
    }
    if (!(squares > 0)) return null;
    return .{
        .length_mm = total,
        .width_mm = total / squares,
        .inductance_nh = mu0_nh_per_mm * @max(reference_height, 0.02) * squares,
    };
}

const PourPathRequest = struct {
    net_name: []const u8,
    layer: u8,
    start: [2]f64,
    finish: [2]f64,
    start_width: f64,
    finish_width: f64,
    reference_height: f64,
};

fn pouredPath(alloc: std.mem.Allocator, surfaces: []const PouredSurface, request: PourPathRequest) std.mem.Allocator.Error!?RoutePath {
    var best: ?RoutePath = null;
    for (surfaces) |surface| {
        if (surface.layer == null or surface.layer.? != request.layer or !intentMatches(surface.net, request.net_name)) continue;
        const path = (try connectedFillPath(alloc, surface.fill, .{
            .start = request.start,
            .finish = request.finish,
            .start_width = request.start_width,
            .finish_width = request.finish_width,
            .reference_height = request.reference_height,
        })) orelse continue;
        const cost = path.length_mm / @max(path.width_mm, 0.05);
        if (best == null or cost < best.?.length_mm / @max(best.?.width_mm, 0.05)) best = path;
    }
    return best;
}

fn betterPourPath(slot: *?RoutePath, candidate: RoutePath) void {
    const candidate_cost = candidate.length_mm / @max(candidate.width_mm, 0.05);
    if (slot.* == null or candidate_cost < slot.*.?.length_mm / @max(slot.*.?.width_mm, 0.05)) slot.* = candidate;
}

fn loopPourRequests(p: optimizer.Placement, lp: optimizer.Loop) ?struct { power: PourPathRequest, ground: PourPathRequest } {
    if (lp.cap >= p.parts.len or lp.hub >= p.parts.len or lp.pwr_net < 0 or @as(usize, @intCast(lp.pwr_net)) >= p.nets.len) return null;
    const cap_part = p.parts[lp.cap];
    const hub_part = p.parts[lp.hub];
    if (cap_part.side != hub_part.side) return null;
    const layer: u8 = if (cap_part.side == .top) 0 else 1;
    const h_ref = referenceHeight(p, cap_part.side);
    return .{
        .power = .{
            .net_name = p.nets[@intCast(lp.pwr_net)].name,
            .layer = layer,
            .start = optimizer.worldPadCenter(&cap_part, lp.cap_pwr.x, lp.cap_pwr.y),
            .finish = optimizer.worldPadCenter(&hub_part, lp.hub_pwr_pin.x, lp.hub_pwr_pin.y),
            .start_width = @max(@min(lp.cap_pwr.w, lp.cap_pwr.h), 0.1),
            .finish_width = @max(@min(lp.hub_pwr_pin.w, lp.hub_pwr_pin.h), 0.1),
            .reference_height = h_ref,
        },
        .ground = .{
            .net_name = "GND",
            .layer = layer,
            .start = optimizer.worldPadCenter(&cap_part, lp.cap_gnd.x, lp.cap_gnd.y),
            .finish = optimizer.worldPadCenter(&hub_part, lp.hub_gnd_pin.x, lp.hub_gnd_pin.y),
            .start_width = @max(@min(lp.cap_gnd.w, lp.cap_gnd.h), 0.1),
            .finish_width = @max(@min(lp.hub_gnd_pin.w, lp.hub_gnd_pin.h), 0.1),
            .reference_height = h_ref,
        },
    };
}

fn considerSurfacePath(alloc: std.mem.Allocator, slot: *?RoutePath, surface: PouredSurface, request: PourPathRequest) std.mem.Allocator.Error!void {
    if (surface.layer == null or surface.layer.? != request.layer or !intentMatches(surface.net, request.net_name)) return;
    const candidate = (try connectedFillPath(alloc, surface.fill, .{
        .start = request.start,
        .finish = request.finish,
        .start_width = request.start_width,
        .finish_width = request.finish_width,
        .reference_height = request.reference_height,
    })) orelse return;
    betterPourPath(slot, candidate);
}

fn padTouchesVia(part: optimizer.Part, pad: optimizer.PadRect, via: router.Via) bool {
    const center = optimizer.worldPadCenter(&part, pad.x, pad.y);
    const angle = -part.rot * std.math.pi / 180.0;
    const dx = via.x - center[0];
    const dy = via.y - center[1];
    const local_x = dx * @cos(angle) - dy * @sin(angle);
    const local_y = dx * @sin(angle) + dy * @cos(angle);
    const outside_x = @max(@abs(local_x) - pad.w / 2.0, 0);
    const outside_y = @max(@abs(local_y) - pad.h / 2.0, 0);
    return std.math.hypot(outside_x, outside_y) <= via.dia / 2.0 + 1.0e-5;
}

fn viaHasSurfaceCopper(routed: router.RouteResult, via: router.Via, layer: u8) bool {
    for (routed.tracks) |track| {
        if (track.net != via.net or track.layer != layer) continue;
        if (samePoint(track.x1, track.y1, via.x, via.y) or samePoint(track.x2, track.y2, via.x, via.y)) return true;
    }
    return false;
}

const PadViaRequest = struct {
    part: optimizer.Part,
    pad: optimizer.PadRect,
    via: router.Via,
    layer: u8,
};

fn padViaAccess(alloc: std.mem.Allocator, p: optimizer.Placement, routed: router.RouteResult, request: PadViaRequest) std.mem.Allocator.Error!?RoutePath {
    const part = request.part;
    const pad = request.pad;
    const via = request.via;
    const layer = request.layer;
    const center = optimizer.worldPadCenter(&part, pad.x, pad.y);
    if (padTouchesVia(part, pad, via)) return .{
        .length_mm = std.math.hypot(center[0] - via.x, center[1] - via.y),
        .width_mm = @max(@min(pad.w, pad.h), 0.05),
        .provenance = "track",
    };
    if (!viaHasSurfaceCopper(routed, via, layer)) return null;
    const board_mm = if (p.rules.physical.board_thickness > 0) p.rules.physical.board_thickness else if (p.rules.physical.stack.board_mm > 0) p.rules.physical.stack.board_mm else 1.6;
    var path = (try routedSurfacePath(alloc, routed, layer, .{
        .net = via.net,
        .start = center,
        .finish = .{ via.x, via.y },
        .start_reach = std.math.hypot(pad.w / 2.0, pad.h / 2.0),
        .finish_reach = via.dia / 2.0,
        .board_mm = board_mm,
    })) orelse return null;
    path.provenance = "track";
    return path;
}

fn stackSpanMm(stack: impedance.Stack, from: u8, to: u8) f64 {
    if (from == to) return 0;
    const lo = @min(from, to);
    const hi = @max(from, to);
    var length = stack.foilMm(lo) / 2.0 + stack.foilMm(hi) / 2.0;
    var layer = lo;
    while (layer < hi) : (layer += 1) {
        length += stack.gapMm(layer);
        if (layer + 1 < hi) length += stack.foilMm(layer + 1);
    }
    return length;
}

const ViaLeg = struct { via: router.Via, path: RoutePath };

const GroundLegRequest = struct {
    part: optimizer.Part,
    pad: optimizer.PadRect,
    layer: u8,
    plane_net: []const u8,
};

fn groundViaLegs(alloc: std.mem.Allocator, p: optimizer.Placement, routed: router.RouteResult, request: GroundLegRequest) std.mem.Allocator.Error![]const ViaLeg {
    var legs: std.ArrayList(ViaLeg) = .empty;
    for (routed.vias) |via| {
        if (via.net < 0 or @as(usize, @intCast(via.net)) >= p.nets.len) continue;
        const actual = p.nets[@intCast(via.net)].name;
        if (!optimizer.isGroundName(net_names.leaf(actual)) or !intentMatches(request.plane_net, actual)) continue;
        const access = (try padViaAccess(alloc, p, routed, .{
            .part = request.part,
            .pad = request.pad,
            .via = via,
            .layer = request.layer,
        })) orelse continue;
        try legs.append(alloc, .{ .via = via, .path = access });
    }
    return legs.toOwnedSlice(alloc);
}

/// One `computedPaths` call's memo of `groundViaLegs`.
///
/// The legs a ground land reaches are a pure function of the land, its signal
/// layer and the plane net — the poured surface's own raster never enters that
/// scan. `computedPaths` nevertheless asks the same question once per (inner
/// ground plane x decoupling loop x hub ground land), and every answer walks
/// each routed via and, for the vias the land does not overlap, builds a
/// per-layer track list and searches it. On barracuda that repetition WAS the
/// editor's deferred payload: 7.9 s of a 16 s response. Memoising per call
/// leaves one scan per distinct land.
const LegMemo = struct {
    /// Retained answers. `computedPaths` recycles its per-surface arena between
    /// surfaces, and these must outlive that reset.
    retain: std.mem.Allocator,
    /// Recycled after every miss: a miss builds a whole per-layer track list per
    /// candidate via, which must not accumulate across the call.
    work: *std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { key: Key, legs: []const ViaLeg };

    /// Everything `groundViaLegs` reads beyond the placement and the routing.
    /// The part is held as its placement index so the key stays comparable.
    const Key = struct {
        part: usize,
        pad: optimizer.PadRect,
        layer: u8,
        plane_net: []const u8,

        fn eql(a: Key, b: Key) bool {
            return a.part == b.part and a.layer == b.layer and
                a.pad.x == b.pad.x and a.pad.y == b.pad.y and
                a.pad.w == b.pad.w and a.pad.h == b.pad.h and
                std.mem.eql(u8, a.plane_net, b.plane_net);
        }
    };

    fn legs(
        self: *LegMemo,
        p: optimizer.Placement,
        routed: router.RouteResult,
        key: Key,
    ) std.mem.Allocator.Error![]const ViaLeg {
        for (self.entries.items) |entry| if (entry.key.eql(key)) return entry.legs;
        const fresh = try groundViaLegs(self.work.allocator(), p, routed, .{
            .part = p.parts[key.part],
            .pad = key.pad,
            .layer = key.layer,
            .plane_net = key.plane_net,
        });
        // ViaLeg is plain data (a Via plus a RoutePath whose only slice is a
        // static provenance literal), so one dupe carries the answer out of the
        // work arena intact.
        const owned = try self.retain.dupe(ViaLeg, fresh);
        _ = self.work.reset(.retain_capacity);
        try self.entries.append(self.retain, .{ .key = key, .legs = owned });
        return owned;
    }
};

/// Prove the actual return topology used by an SMD bypass loop: the capacitor
/// ground land and any actual ground land on the target IC must each reach a
/// same-net through via through authored surface copper (or direct land
/// overlap), and both barrels must land in the same exact clearance-carved
/// inner-plane component. The loop scorer's nearest ground land is a placement
/// objective, not an electrical restriction: an exposed paddle with via-in-pad
/// is a valid parallel return even when another edge pin is geometrically
/// nearer the supply pin. No nearest-via or equipotential-plane credit.
fn groundViaPlanePath(
    alloc: std.mem.Allocator,
    memo: *LegMemo,
    p: optimizer.Placement,
    routed: router.RouteResult,
    surface: PouredSurface,
    lp: optimizer.Loop,
) std.mem.Allocator.Error!?RoutePath {
    if (surface.layer != null or surface.stack == 0 or !optimizer.isGroundName(net_names.leaf(surface.net))) return null;
    if (lp.cap >= p.parts.len or lp.hub >= p.parts.len) return null;
    const cap_part = p.parts[lp.cap];
    const hub_part = p.parts[lp.hub];
    if (cap_part.side != hub_part.side) return null;
    const signal_layer: u8 = if (cap_part.side == .top) 0 else 1;
    const signal_stack: u8 = if (cap_part.side == .top) 1 else @max(@as(u8, 2), p.rules.physical.stack.layers);
    const h_ref = @max(stackSpanMm(p.rules.physical.stack, signal_stack, surface.stack), 0.02);
    const cap_legs = try memo.legs(p, routed, .{ .part = lp.cap, .pad = lp.cap_gnd, .layer = signal_layer, .plane_net = surface.net });
    var hub_legs: std.ArrayList(ViaLeg) = .empty;
    defer hub_legs.deinit(alloc);
    const hub_ground_pads = if (lp.hub_gnd.len > 0) lp.hub_gnd else &.{lp.hub_gnd_pin};
    for (hub_ground_pads) |hub_pad| {
        const pad_legs = try memo.legs(p, routed, .{ .part = lp.hub, .pad = hub_pad, .layer = signal_layer, .plane_net = surface.net });
        try hub_legs.appendSlice(alloc, pad_legs);
    }
    var best: ?RoutePath = null;
    for (cap_legs) |cap_leg| for (hub_legs.items) |hub_leg| {
        const cap_component = surface.fill.componentAt(cap_leg.via.x, cap_leg.via.y);
        if (cap_component < 0 or surface.fill.componentAt(hub_leg.via.x, hub_leg.via.y) != cap_component) continue;
        const plane = (try connectedFillPath(alloc, surface.fill, .{
            .start = .{ cap_leg.via.x, cap_leg.via.y },
            .finish = .{ hub_leg.via.x, hub_leg.via.y },
            .start_width = @max(cap_leg.via.dia, 0.1),
            .finish_width = @max(hub_leg.via.dia, 0.1),
            .reference_height = h_ref,
        })) orelse continue;
        const same_via = samePoint(cap_leg.via.x, cap_leg.via.y, hub_leg.via.x, hub_leg.via.y);
        var inductance = pathInductanceNh(cap_leg.path, h_ref) + pathInductanceNh(hub_leg.path, h_ref) + pathInductanceNh(plane, h_ref);
        if (!same_via) {
            inductance += viaInductanceNh(h_ref, if (cap_leg.via.drill > 0) cap_leg.via.drill else 0.2);
            inductance += viaInductanceNh(h_ref, if (hub_leg.via.drill > 0) hub_leg.via.drill else 0.2);
        }
        const candidate = RoutePath{
            .length_mm = cap_leg.path.length_mm + plane.length_mm + hub_leg.path.length_mm,
            .width_mm = @max(@min(@min(cap_leg.path.width_mm, plane.width_mm), hub_leg.path.width_mm), 0.05),
            .inductance_nh = inductance,
            .provenance = "computed-via-plane",
        };
        if (best == null or candidate.inductance_nh.? < best.?.inductance_nh.?) best = candidate;
    };
    return best;
}

fn computedPaths(
    alloc: std.mem.Allocator,
    scratch_alloc: std.mem.Allocator,
    p: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const pour.UserZone,
    base_edge: ?pour.EdgeField,
) std.mem.Allocator.Error!CopperPaths {
    const Meta = struct { net: []const u8, layer: ?u8, stack: u8, spec: pour.LayerSpec };
    var metas: std.ArrayList(Meta) = .empty;
    const copper: pour.Copper = .{
        .tracks = routed.tracks,
        .vias = routed.vias,
        .arcs = routed.arcs,
        .rf_paths = routed.rf_port_outcomes,
        .zones = zones,
    };
    for (p.nets) |net| {
        var relevant = optimizer.isGroundName(net_names.leaf(net.name));
        for (p.rules.physical.pdn_intents) |intent| if (intentMatches(intent.net, net.name)) {
            relevant = true;
            break;
        };
        if (!relevant) continue;
        const layers = try pour.carryingLayers(alloc, p.rules, net.name);
        for (layers) |layer| {
            var spec = layer;
            if (layer.track_layer) |signal_layer| spec.higher = try pour.higherThanDeclared(alloc, zones, signal_layer, spec.net);
            try metas.append(alloc, .{ .net = net.name, .layer = layer.track_layer, .stack = layer.stack, .spec = spec });
        }
    }
    for (zones, 0..) |zone, i| {
        var relevant = optimizer.isGroundName(net_names.leaf(zone.net));
        for (p.rules.physical.pdn_intents) |intent| if (intentMatches(intent.net, zone.net)) {
            relevant = true;
            break;
        };
        if (!relevant) continue;
        var spec = pour.zoneLayerSpec(zone.net, pour.sideOfSignal(zone.layer), zone.layer, zone.poly);
        spec.higher = try pour.higherPolys(alloc, zones, i);
        try metas.append(alloc, .{ .net = zone.net, .layer = zone.layer, .stack = p.rules.signalStackIndex(zone.layer), .spec = spec });
    }
    const power = try alloc.alloc(?RoutePath, p.loops.len);
    const ground = try alloc.alloc(?RoutePath, p.loops.len);
    @memset(power, null);
    @memset(ground, null);
    const shared = if (base_edge) |field| field else try pour.sharedEdgeField(alloc, p);

    // `computeFill` is arena-oriented and keeps several board-sized work
    // rasters beside its returned labels. The server allocator outlives its
    // cached pages, so retaining every relevant surface there made a Barracuda
    // page hold nearly a gigabyte. Extract compact per-loop facts
    // while one surface is live, then recycle all of that surface's scratch
    // before rasterizing the next one.
    var scratch_state = std.heap.ArenaAllocator.init(scratch_alloc);
    defer scratch_state.deinit();
    // The ground-return leg memo spans every surface (its answers do not depend
    // on which surface asked), so it owns two arenas of its own rather than
    // riding the per-surface one recycled below.
    var memo_retain = std.heap.ArenaAllocator.init(scratch_alloc);
    defer memo_retain.deinit();
    var memo_work = std.heap.ArenaAllocator.init(scratch_alloc);
    defer memo_work.deinit();
    var memo = LegMemo{ .retain = memo_retain.allocator(), .work = &memo_work };
    for (metas.items) |meta| {
        const surface = PouredSurface{
            .net = meta.net,
            .layer = meta.layer,
            .stack = meta.stack,
            .fill = try pour.computeMaskShared(scratch_state.allocator(), p, copper, meta.spec, shared),
        };
        for (p.loops, 0..) |lp, i| {
            const requests = loopPourRequests(p, lp) orelse continue;
            try considerSurfacePath(scratch_state.allocator(), &power[i], surface, requests.power);
            try considerSurfacePath(scratch_state.allocator(), &ground[i], surface, requests.ground);
            if (try groundViaPlanePath(scratch_state.allocator(), &memo, p, routed, surface, lp)) |candidate| {
                if (ground[i] == null or pathInductanceNh(candidate, requests.ground.reference_height) < pathInductanceNh(ground[i].?, requests.ground.reference_height)) ground[i] = candidate;
            }
        }
        _ = scratch_state.reset(.retain_capacity);
    }
    return .{ .power = power, .ground = ground };
}

fn nearestGroundVia(p: optimizer.Placement, routed: router.RouteResult, at: [2]f64) ?router.Via {
    var best: ?router.Via = null;
    var best_d = std.math.inf(f64);
    for (routed.vias) |via| {
        if (via.net < 0 or @as(usize, @intCast(via.net)) >= p.nets.len) continue;
        if (!optimizer.isGroundName(net_names.leaf(p.nets[@intCast(via.net)].name))) continue;
        const d = std.math.hypot(at[0] - via.x, at[1] - via.y);
        if (d < best_d) {
            best_d = d;
            best = via;
        }
    }
    return best;
}

fn referenceHeight(p: optimizer.Placement, side: optimizer.Side) f64 {
    const physical: u8 = if (side == .top) 1 else @max(@as(u8, 1), p.rules.physical.stack.layers);
    const ref = impedance.reference(p.rules.physical.stack, physical) orelse return 0.2;
    return ref.heightMm();
}

fn traceInductanceNh(length_mm: f64, width_mm: f64, height_mm: f64) f64 {
    if (!(length_mm > 0)) return 0;
    const width = @max(width_mm, 0.05);
    const h = @max(height_mm, 0.02);
    return mu0_nh_per_mm * h * length_mm / @max(width, h * 2.0);
}

fn pathInductanceNh(path: RoutePath, height_mm: f64) f64 {
    return path.inductance_nh orelse traceInductanceNh(path.length_mm, path.width_mm, height_mm);
}

fn viaInductanceNh(height_mm: f64, drill_mm: f64) f64 {
    const h = @max(height_mm, 0.02);
    const d = @max(drill_mm, 0.08);
    const arg = @max(1.0001, 4.0 * h / d);
    return 0.2 * h * (@log(arg) + 1.0);
}

const CapBuild = struct {
    power: ?RoutePath,
    ground: ?RoutePath,
    voltage: ?f64,
};

fn buildCap(alloc: std.mem.Allocator, p: optimizer.Placement, routed: router.RouteResult, model: CapBuild, lp: optimizer.Loop) std.mem.Allocator.Error!?Capacitor {
    if (lp.cap >= p.parts.len or lp.hub >= p.parts.len or lp.cap >= p.instances.len or lp.pwr_net < 0) return null;
    const cap_part = p.parts[lp.cap];
    const hub_part = p.parts[lp.hub];
    const inst = p.instances[lp.cap];
    const nominal = decouple_key.capFarads(cap_part.value);
    if (!(nominal > 0)) return null;
    const c_eff = effectiveCapacitance(inst, nominal, model.voltage);
    const esr = propertyNumber(inst, "pdn-esr-ohm") orelse defaultEsr(c_eff);
    const esl = propertyNumber(inst, "pdn-esl-h") orelse packageDefaultEsl(inst.component);
    const explicit_model = propertyNumber(inst, "pdn-esr-ohm") != null and propertyNumber(inst, "pdn-esl-h") != null;

    const cp = optimizer.worldPadCenter(&cap_part, lp.cap_pwr.x, lp.cap_pwr.y);
    const hp = optimizer.worldPadCenter(&hub_part, lp.hub_pwr_pin.x, lp.hub_pwr_pin.y);
    const cg = optimizer.worldPadCenter(&cap_part, lp.cap_gnd.x, lp.cap_gnd.y);
    const hg = optimizer.worldPadCenter(&hub_part, lp.hub_gnd_pin.x, lp.hub_gnd_pin.y);
    const cp_reach = std.math.hypot(lp.cap_pwr.w / 2.0, lp.cap_pwr.h / 2.0);
    const hp_reach = std.math.hypot(lp.hub_pwr_pin.w / 2.0, lp.hub_pwr_pin.h / 2.0);
    const board_mm = if (p.rules.physical.board_thickness > 0) p.rules.physical.board_thickness else if (p.rules.physical.stack.board_mm > 0) p.rules.physical.stack.board_mm else 1.6;
    const route_path = try routedPath(alloc, routed, .{
        .net = lp.pwr_net,
        .start = cp,
        .finish = hp,
        .start_reach = cp_reach,
        .finish_reach = hp_reach,
        .board_mm = board_mm,
    });
    const h_ref = referenceHeight(p, cap_part.side);
    const straight = std.math.hypot(cp[0] - hp[0], cp[1] - hp[1]);
    var power_kind: []const u8 = "fallback";
    const power_path = if (route_path) |trace| if (model.power) |sheet| blk: {
        if (pathInductanceNh(sheet, h_ref) < pathInductanceNh(trace, h_ref)) {
            power_kind = "computed-pour";
            break :blk sheet;
        }
        power_kind = "track";
        break :blk trace;
    } else blk: {
        power_kind = "track";
        break :blk trace;
    } else if (model.power) |sheet| blk: {
        power_kind = "computed-pour";
        break :blk sheet;
    } else null;
    const power_mm = if (power_path) |path| path.length_mm else straight;
    const power_width = if (power_path) |path| path.width_mm else @max(lp.cap_pwr.w, 0.1);
    var mount_nh = if (power_path) |path| pathInductanceNh(path, h_ref) else traceInductanceNh(power_mm, power_width, h_ref);

    var ground_kind: []const u8 = "fallback";
    var ground_mm: f64 = 0;
    if (model.ground) |path| {
        ground_kind = path.provenance;
        ground_mm = path.length_mm;
        mount_nh += pathInductanceNh(path, h_ref);
    } else {
        const cap_via = nearestGroundVia(p, routed, cg);
        const hub_via = nearestGroundVia(p, routed, hg);
        if (cap_via != null and hub_via != null) ground_kind = "estimated-via-return";
        if (cap_via) |v| {
            const d = std.math.hypot(cg[0] - v.x, cg[1] - v.y);
            ground_mm += d;
            mount_nh += traceInductanceNh(d, @max(lp.cap_gnd.w, 0.1), h_ref);
            mount_nh += viaInductanceNh(h_ref, if (v.drill > 0) v.drill else 0.2);
        } else {
            ground_mm += std.math.hypot(cg[0] - hg[0], cg[1] - hg[1]);
            mount_nh += viaInductanceNh(h_ref, 0.2);
        }
        if (hub_via) |v| {
            const d = std.math.hypot(hg[0] - v.x, hg[1] - v.y);
            ground_mm += d;
            mount_nh += traceInductanceNh(d, @max(lp.hub_gnd_pin.w, 0.1), h_ref);
            mount_nh += viaInductanceNh(h_ref, if (v.drill > 0) v.drill else 0.2);
            if (cap_via) |cv| {
                const spread = std.math.hypot(cv.x - v.x, cv.y - v.y);
                const spread_width = @max(0.5, spread / 2.0);
                mount_nh += traceInductanceNh(spread, spread_width, h_ref);
            }
        } else mount_nh += viaInductanceNh(h_ref, 0.2);
    }

    const mount_h = mount_nh * 1.0e-9;
    const srf = 1.0 / (two_pi * @sqrt(@max(1.0e-30, (esl + mount_h) * c_eff)));
    return .{
        .ref_des = cap_part.ref_des,
        .target_ref_des = hub_part.ref_des,
        .target_pin = lp.explicit_pin,
        .value = cap_part.value,
        .model_source = property(inst, "pdn-model-source") orelse if (explicit_model) "BOM model" else "package/value estimate",
        .capacitance_f = c_eff,
        .effective_factor = c_eff / nominal,
        .esr_ohm = esr,
        .intrinsic_esl_h = esl,
        .mounting_inductance_h = mount_h,
        .power_path_mm = power_mm,
        .ground_path_mm = ground_mm,
        .path_kind = .{ .power = power_kind, .ground = ground_kind },
        .model_estimated = !explicit_model,
        .mounted_srf_hz = srf,
    };
}

fn branchY(cap: Capacitor, frequency_hz: f64, ideal_mount: bool) Cx {
    const w = two_pi * frequency_hz;
    const l = cap.intrinsic_esl_h + if (ideal_mount) 0 else cap.mounting_inductance_h;
    return admittance(cap.esr_ohm, w * l - 1.0 / (w * cap.capacitance_f));
}

fn solveAt(rail: *const Rail, frequency_hz: f64, omit: ?usize, idealize: ?usize) Cx {
    const w = two_pi * frequency_hz;
    var y = admittance(rail.source_resistance_ohm, w * rail.source_inductance_h);
    for (rail.capacitors, 0..) |cap, i| {
        if (omit != null and omit.? == i) continue;
        y = add(y, branchY(cap, frequency_hz, idealize != null and idealize.? == i));
    }
    return impedanceOf(y);
}

fn sweepCount(f_min: f64, f_max: f64) usize {
    const decades = @log10(f_max / f_min);
    const raw = numeric.toCount(@ceil(decades * default_points_per_decade) + 1);
    return std.math.clamp(raw, min_sweep_points, max_sweep_points);
}

fn peakList(alloc: std.mem.Allocator, points: []const Point, target: ?f64) std.mem.Allocator.Error![]const Peak {
    var peaks: std.ArrayList(Peak) = .empty;
    if (points.len < 3) return peaks.items;
    for (points[1 .. points.len - 1], 1..) |point, i| {
        if (!(point.magnitude_ohm > points[i - 1].magnitude_ohm and point.magnitude_ohm >= points[i + 1].magnitude_ohm)) continue;
        var left = point.magnitude_ohm;
        var j = i;
        while (j > 0) : (j -= 1) left = @min(left, points[j - 1].magnitude_ohm);
        var right = point.magnitude_ohm;
        j = i + 1;
        while (j < points.len) : (j += 1) right = @min(right, points[j].magnitude_ohm);
        const shoulder = @max(left, right);
        const prominence = if (shoulder > 0) 20.0 * @log10(point.magnitude_ohm / shoulder) else 100.0;
        if (prominence < peak_prominence_db) continue;
        try peaks.append(alloc, .{
            .frequency_hz = point.frequency_hz,
            .magnitude_ohm = point.magnitude_ohm,
            .above_target = if (target) |z| point.magnitude_ohm > z else false,
        });
    }
    return peaks.items;
}

fn buildRail(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    routed: router.RouteResult,
    paths: CopperPaths,
    intent: @import("../eval/env.zig").PdnIntent,
) std.mem.Allocator.Error!Rail {
    var caps: std.ArrayList(Capacitor) = .empty;
    const nominal_voltage = railVoltage(p, intent.net);
    for (p.loops, 0..) |lp, i| {
        if (lp.pwr_net < 0 or @as(usize, @intCast(lp.pwr_net)) >= p.nets.len) continue;
        if (!intentMatches(intent.net, p.nets[@intCast(lp.pwr_net)].name)) continue;
        if (try buildCap(alloc, p, routed, .{ .power = paths.power[i], .ground = paths.ground[i], .voltage = nominal_voltage }, lp)) |cap| try caps.append(alloc, cap);
    }
    const explicit_step = intent.step_current_a;
    const step = explicit_step orelse inferredStep(p, intent.net);
    const target = if (step) |di| if (di > 0) intent.ripple_v / di else null else null;
    const source_assumed = intent.source_resistance_ohm == null or intent.source_inductance_h == null;
    var rail = Rail{
        .net = intent.net,
        .ripple_v = intent.ripple_v,
        .step_current_a = step,
        .step_assumed = explicit_step == null and step != null,
        .target_ohm = target,
        .source_resistance_ohm = intent.source_resistance_ohm orelse if (target) |z| z / 4.0 else 0.02,
        .source_inductance_h = intent.source_inductance_h orelse 1.0e-9,
        .source_assumed = source_assumed,
        .verdict_max_hz = if (intent.rise_time_s) |tr| @min(intent.f_max_hz, 0.35 / tr) else intent.f_max_hz,
        .points = &.{},
        .peaks = &.{},
        .capacitors = try caps.toOwnedSlice(alloc),
        .worst_frequency_hz = intent.f_min_hz,
        .worst_magnitude_ohm = 0,
        .passes = null,
    };
    const count = sweepCount(intent.f_min_hz, intent.f_max_hz);
    const points = try alloc.alloc(Point, count);
    const log_min = @log10(intent.f_min_hz);
    const log_span = @log10(intent.f_max_hz) - log_min;
    var worst_index: usize = 0;
    var verdict_worst: f64 = 0;
    for (points, 0..) |*point, i| {
        const fraction = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(count - 1));
        const f = std.math.pow(f64, 10.0, log_min + log_span * fraction);
        const z = solveAt(&rail, f, null, null);
        point.* = .{ .frequency_hz = f, .magnitude_ohm = magnitude(z), .phase_deg = std.math.atan2(z.im, z.re) * 180.0 / std.math.pi };
        if (f <= rail.verdict_max_hz and point.magnitude_ohm >= verdict_worst) {
            verdict_worst = point.magnitude_ohm;
            worst_index = i;
        }
    }
    rail.points = points;
    rail.worst_frequency_hz = points[worst_index].frequency_hz;
    rail.worst_magnitude_ohm = points[worst_index].magnitude_ohm;
    var path_complete = rail.capacitors.len > 0;
    for (rail.capacitors) |cap| {
        if (!capPathComplete(cap)) {
            path_complete = false;
            break;
        }
    }
    // Fallback branches remain in the diagnostic curve, but an assumed
    // straight trace or imaginary return via can never produce a green proof.
    if (target) |z| rail.passes = if (path_complete) verdict_worst <= z else null;
    rail.peaks = try peakList(alloc, points, target);
    const f_probe = rail.worst_frequency_hz;
    const with_mag = @max(1.0e-30, rail.worst_magnitude_ohm);
    for (rail.capacitors, 0..) |*cap, i| {
        cap.removal_impact_db = 20.0 * @log10(@max(1.0e-30, magnitude(solveAt(&rail, f_probe, i, null))) / with_mag);
        cap.ideal_mount_improvement_db = 20.0 * @log10(with_mag / @max(1.0e-30, magnitude(solveAt(&rail, f_probe, null, i))));
        cap.ineffective = cap.removal_impact_db < ineffective_db and cap.ideal_mount_improvement_db > ineffective_db;
    }
    return rail;
}

/// Extract and sweep every explicit PDN intent against the saved copper.
pub fn analyze(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    routed: router.RouteResult,
) std.mem.Allocator.Error!Analysis {
    return analyzeCopper(alloc, alloc, p, routed, &.{}, null);
}

/// Extract and sweep explicit PDN intents against routed copper plus the exact
/// clearance-carved saved user pours used for fabrication and connectivity.
pub fn analyzeCopper(
    alloc: std.mem.Allocator,
    scratch_alloc: std.mem.Allocator,
    p: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const pour.UserZone,
    base_edge: ?pour.EdgeField,
) std.mem.Allocator.Error!Analysis {
    const paths = try computedPaths(alloc, scratch_alloc, p, routed, zones, base_edge);
    var rails: std.ArrayList(Rail) = .empty;
    for (p.rules.physical.pdn_intents) |intent| try rails.append(alloc, try buildRail(alloc, p, routed, paths, intent));
    return .{ .rails = try rails.toOwnedSlice(alloc) };
}

fn writeSpiceIdent(w: *std.Io.Writer, raw: []const u8) std.Io.Writer.Error!void {
    for (raw) |c| try w.writeByte(if (std.ascii.isAlphanumeric(c) or c == '_') c else '_');
}

/// Emit the exact lumped network used by the screen as a portable SPICE
/// subcircuit. PORT is the observation/load node; an AC-grounded source RL and
/// every mounted capacitor RLC branch shunt it to GND.
pub fn writeSpice(w: *std.Io.Writer, rail: Rail) std.Io.Writer.Error!void {
    try w.writeAll("* Netlisp routed-board PDN screen; values are SI\n.subckt PDN_");
    try writeSpiceIdent(w, rail.net);
    try w.writeAll(" PORT GND\n");
    try w.print("R_SRC PORT N_SRC {e}\nL_SRC N_SRC GND {e}\n", .{ rail.source_resistance_ohm, rail.source_inductance_h });
    for (rail.capacitors, 0..) |cap, i| {
        try w.print("* C{d}: {s} {s}; mount={e}H intrinsic={e}H model={s}\n", .{ i + 1, cap.ref_des, cap.value, cap.mounting_inductance_h, cap.intrinsic_esl_h, cap.model_source });
        try w.print("R_C{d} PORT N_C{d} {e}\nL_C{d} N_C{d} N_CC{d} {e}\nC_C{d} N_CC{d} GND {e}\n", .{
            i + 1,                                           i + 1, cap.esr_ohm,
            i + 1,                                           i + 1, i + 1,
            cap.intrinsic_esl_h + cap.mounting_inductance_h, i + 1, i + 1,
            cap.capacitance_f,
        });
    }
    try w.writeAll(".ends PDN_");
    try writeSpiceIdent(w, rail.net);
    try w.writeByte('\n');
}

test "series RLC branch resonates at mounted SRF" {
    const cap = Capacitor{
        .ref_des = "C1",
        .target_ref_des = "U1",
        .target_pin = "1",
        .value = "100nF",
        .model_source = "fixture",
        .capacitance_f = 100e-9,
        .effective_factor = 1,
        .esr_ohm = 0.02,
        .intrinsic_esl_h = 0.4e-9,
        .mounting_inductance_h = 0.6e-9,
        .power_path_mm = 1,
        .ground_path_mm = 1,
        .path_kind = .{ .power = "track", .ground = "computed-pour" },
        .model_estimated = false,
        .mounted_srf_hz = 1.0 / (two_pi * @sqrt(100e-9 * 1e-9)),
    };
    const y = branchY(cap, cap.mounted_srf_hz, false);
    const z = impedanceOf(y);
    try std.testing.expectApproxEqAbs(@as(f64, 0.02), magnitude(z), 1e-9);
}

test "mounting inductance lowers capacitor self resonance" {
    const c = 100e-9;
    const bare = 1.0 / (two_pi * @sqrt(c * 0.4e-9));
    const mounted = 1.0 / (two_pi * @sqrt(c * (0.4e-9 + 3.0e-9)));
    try std.testing.expect(mounted < bare / 2.0);
}

test "PDN rail without extracted capacitors cannot green-pass" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const intents = [_]@import("../eval/env.zig").PdnIntent{.{ .net = "VDD", .ripple_v = 0.1, .step_current_a = 1 }};
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
        .maxx = 0,
        .maxy = 0,
        .generated = true,
        .rules = .{ .physical = .{ .pdn_intents = &intents } },
    };
    const analysis = try analyze(arena_state.allocator(), placement, .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 });
    try std.testing.expectEqual(@as(usize, 0), analysis.rails[0].capacitors.len);
    try std.testing.expect(analysis.rails[0].passes == null);
}

// spec: placement/pdn-impedance - a computed PDN pour path integrates finite transverse sheet width capped by terminal spreading, so a broad fill lowers mounting inductance while a narrow neck limits it
test "computed custom pour corridor lowers mounting inductance without becoming equipotential" {
    const broad_labels: [45]i32 = @splat(0);
    const broad = pour.Fill{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 9, .ny = 5 },
        .labels = &broad_labels,
        .n_comp = 1,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
    var narrow_labels: [45]i32 = @splat(-1);
    for (18..27) |i| narrow_labels[i] = 0;
    const narrow = pour.Fill{
        .frame = broad.frame,
        .labels = &narrow_labels,
        .n_comp = 1,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
    const surfaces = [_]PouredSurface{.{ .net = "VDD", .layer = 0, .stack = 1, .fill = broad }};
    const wide_path = (try pouredPath(std.testing.allocator, &surfaces, .{
        .net_name = "VDD",
        .layer = 0,
        .start = .{ 0.5, 2.5 },
        .finish = .{ 8.5, 2.5 },
        .start_width = 1,
        .finish_width = 1,
        .reference_height = 0.1,
    })).?;
    const neck_path = fillPath(narrow, .{ 0.5, 2.5 }, .{ 8.5, 2.5 }, 1, 1, 0.1).?;
    try std.testing.expect(wide_path.inductance_nh.? > 0);
    try std.testing.expect(wide_path.inductance_nh.? < neck_path.inductance_nh.?);
    try std.testing.expect(wide_path.width_mm > neck_path.width_mm);
}

// spec: placement/pdn-impedance - a hole, split island, or coarsened fill refuses PDN pour-path credit
test "computed pour refuses a hole split island and coarsened fill" {
    var hole_labels: [27]i32 = @splat(0);
    hole_labels[13] = -1;
    const hole = pour.Fill{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 9, .ny = 3 },
        .labels = &hole_labels,
        .n_comp = 1,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
    try std.testing.expect(fillPath(hole, .{ 0.5, 1.5 }, .{ 8.5, 1.5 }, 1, 1, 0.1) == null);

    var split_labels: [27]i32 = @splat(0);
    for (14..27) |i| split_labels[i] = 1;
    var split = hole;
    split.labels = &split_labels;
    split.n_comp = 2;
    try std.testing.expect(fillPath(split, .{ 0.5, 1.5 }, .{ 8.5, 1.5 }, 1, 1, 0.1) == null);

    var coarse = hole;
    const coarse_labels: [27]i32 = @splat(0);
    coarse.labels = &coarse_labels;
    coarse.coarsened = true;
    try std.testing.expect(fillPath(coarse, .{ 0.5, 1.5 }, .{ 8.5, 1.5 }, 1, 1, 0.1) == null);
}

// spec: placement/pdn-impedance - a same-component pour path may bend around a clearance hole, but still integrates finite path length and width instead of treating the component as equipotential
test "computed pour path finds conservative route around an antipad" {
    var labels: [45]i32 = @splat(0);
    labels[2 * 9 + 4] = -1;
    const fill = pour.Fill{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 9, .ny = 5 },
        .labels = &labels,
        .n_comp = 1,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
    try std.testing.expect(fillPath(fill, .{ 0.5, 2.5 }, .{ 8.5, 2.5 }, 1, 1, 0.1) == null);
    const around = (try connectedFillPath(std.testing.allocator, fill, .{
        .start = .{ 0.5, 2.5 },
        .finish = .{ 8.5, 2.5 },
        .start_width = 1,
        .finish_width = 1,
        .reference_height = 0.1,
    })).?;
    try std.testing.expect(around.length_mm > 8);
    try std.testing.expect(around.inductance_nh.? > 0);
}

// spec: placement/pdn-impedance - characterized capacitor DC-bias curves interpolate at the resolved rail voltage and combine with tolerance and temperature derating
test "characterized capacitor derating follows rail voltage" {
    const props = [_]@import("../eval/env.zig").Property{
        .{ .key = "pdn-dc-bias-curve", .value = "0:1,3.3:0.56,5:0.38" },
        .{ .key = "pdn-tolerance-factor", .value = "0.9" },
        .{ .key = "pdn-temperature-factor", .value = "0.85" },
    };
    const inst = flat_netlist.FlatInstance{ .ref_des = "C1", .component = "cap-0402", .value = "1uF", .footprint = "C_0402", .properties = &props, .uuid = "c1" };
    try std.testing.expectApproxEqAbs(@as(f64, 1e-6 * 0.56 * 0.9 * 0.85), effectiveCapacitance(inst, 1e-6, 3.3), 1e-18);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-6 * 0.38 * 0.9 * 0.85), effectiveCapacitance(inst, 1e-6, 5.0), 1e-18);
    try std.testing.expect(biasFactor("0:1,5:0.4,3.3:0.6", 3.3) == null);
}

// spec: placement/pdn-impedance - a capacitor and any actual load ground pad earn computed-via-plane proof only when authored surface copper reaches same-net vias in one exact inner-plane fill component
test "ground return proves pad via plane via topology" {
    const pad = optimizer.PadRect{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 };
    const unstitched_nearest = optimizer.PadRect{ .x = -1, .y = 0, .w = 0.3, .h = 0.3 };
    const hub_ground_pads = [_]optimizer.PadRect{ unstitched_nearest, pad };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 2, .y = 2 },
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 8, .y = 2 },
    };
    const ground_pins = [_]flat_netlist.FlatPin{};
    const nets = [_]optimizer.FlatNet{.{ .name = "GND", .pins = &ground_pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 4,
        .generated = true,
        .rules = .{ .physical = .{ .stack = .{
            .layers = 4,
            .planes = &.{2},
            .dielectrics = &.{
                .{ .after_layer = 1, .thickness_mm = 0.1, .er = 4.4 },
                .{ .after_layer = 2, .thickness_mm = 1.2, .er = 4.4 },
                .{ .after_layer = 3, .thickness_mm = 0.1, .er = 4.4 },
            },
        } } },
    };
    const vias = [_]router.Via{
        .{ .x = 2, .y = 2, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 8, .y = 2, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };
    const labels: [40]i32 = @splat(0);
    const surface = PouredSurface{
        .net = "GND",
        .layer = null,
        .stack = 2,
        .fill = .{
            .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 10, .ny = 4 },
            .labels = &labels,
            .n_comp = 1,
            .contours = &.{},
            .holes = &.{},
            .coarsened = false,
        },
    };
    const lp = optimizer.Loop{
        .cap = 0,
        .hub = 1,
        .cap_pwr = pad,
        .cap_gnd = pad,
        .hub_pwr = &.{pad},
        .hub_pwr_pin = pad,
        .hub_gnd = &hub_ground_pads,
        .hub_gnd_pin = unstitched_nearest,
        .pwr_net = 0,
        .explicit_pin = "1",
    };
    // Both calls share one memo, as `computedPaths` does: the second surface
    // differs only in its raster, and the legs it reuses must still be the legs
    // the first call proved — the memo answers a land, not a surface.
    var memo_retain = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memo_retain.deinit();
    var memo_work = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer memo_work.deinit();
    var memo = LegMemo{ .retain = memo_retain.allocator(), .work = &memo_work };

    const path = (try groundViaPlanePath(std.testing.allocator, &memo, placement, routed, surface, lp)).?;
    try std.testing.expectEqualStrings("computed-via-plane", path.provenance);
    try std.testing.expect(path.inductance_nh.? > 0);

    var split_labels = labels;
    for (0..4) |y| split_labels[y * 10 + 5] = -1;
    var split_surface = surface;
    split_surface.fill.labels = &split_labels;
    try std.testing.expect((try groundViaPlanePath(std.testing.allocator, &memo, placement, routed, split_surface, lp)) == null);
}

test "diagonal computed-pour neck retains finite transverse width" {
    var labels: [49]i32 = @splat(-1);
    for (0..7) |i| {
        labels[i * 7 + i] = 0;
        if (i + 1 < 7) labels[i * 7 + i + 1] = 0;
        if (i > 0) labels[i * 7 + i - 1] = 0;
    }
    const fill = pour.Fill{
        .frame = .{ .minx = 0, .miny = 0, .pitch = 1, .nx = 7, .ny = 7 },
        .labels = &labels,
        .n_comp = 1,
        .contours = &.{},
        .holes = &.{},
        .coarsened = false,
    };
    const path = fillPath(fill, .{ 0.5, 0.5 }, .{ 6.5, 6.5 }, 1, 1, 0.1).?;
    try std.testing.expect(path.width_mm > 0.5 and path.width_mm < 2.0);
    try std.testing.expect(path.inductance_nh.? > 0);
}

// spec: placement/pdn-impedance - a routed PDN path uses the selected route's bottleneck width, not unrelated copper on the same net
test "routed power path reports the selected path bottleneck width" {
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.1, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 20, .y1 = 20, .x2 = 40, .y2 = 20, .layer = 0, .width = 5, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    const path = (try routedPath(std.testing.allocator, routed, .{
        .net = 0,
        .start = .{ 0, 0 },
        .finish = .{ 2, 0 },
        .start_reach = 0.05,
        .finish_reach = 0.05,
        .board_mm = 1.6,
    })).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), path.width_mm, 1e-12);
}

// spec: placement/pdn-impedance - a saved custom-pour corridor reaches live PDN analysis and reports computed-pour provenance for each credited leg
// spec: placement/pdn-impedance - PDN pour extraction retains only compact per-capacitor path facts and recycles each board-sized fill before rasterizing the next surface
// spec: placement/pdn-impedance - a fallback or estimated-via-return PDN mounting path remains diagnostic and cannot produce a green target-impedance verdict
test "PDN capacitor to load custom pour is live analysis copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const geometry = @import("geometry.zig");
    const flat = @import("../flat_netlist.zig");
    const pwr_pad = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 };
    const gnd_pad = geometry.Pad{ .number = "2", .x = 0, .y = 1, .w = 0.4, .h = 0.4 };
    const pads = [_]geometry.Pad{ pwr_pad, gnd_pad };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .value = "100nF", .x = 2, .y = 5 },
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 8, .y = 5 },
    };
    const instances = [_]flat.FlatInstance{
        .{ .ref_des = "C1", .component = "capacitor-0402", .value = "100nF", .footprint = "C_0402", .properties = &.{}, .uuid = "c1" },
        .{ .ref_des = "U1", .component = "load", .value = "", .footprint = "U", .properties = &.{}, .uuid = "u1" },
    };
    const pwr_pins = [_]flat.FlatPin{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "U1", .pin = "1" } };
    const gnd_pins = [_]flat.FlatPin{ .{ .ref_des = "C1", .pin = "2" }, .{ .ref_des = "U1", .pin = "2" } };
    const nets = [_]optimizer.FlatNet{ .{ .name = "VDD", .pins = &pwr_pins }, .{ .name = "GND", .pins = &gnd_pins } };
    const pwr_rect = optimizer.PadRect{ .x = 0, .y = 0, .w = 0.4, .h = 0.4 };
    const gnd_rect = optimizer.PadRect{ .x = 0, .y = 1, .w = 0.4, .h = 0.4 };
    const hub_pwr = [_]optimizer.PadRect{pwr_rect};
    const hub_gnd = [_]optimizer.PadRect{gnd_rect};
    const loops = [_]optimizer.Loop{.{
        .cap = 0,
        .hub = 1,
        .cap_pwr = pwr_rect,
        .cap_gnd = gnd_rect,
        .hub_pwr = &hub_pwr,
        .hub_pwr_pin = pwr_rect,
        .hub_gnd = &hub_gnd,
        .hub_gnd_pin = gnd_rect,
        .pwr_net = 0,
        .explicit_pin = "1",
    }};
    const intents = [_]@import("../eval/env.zig").PdnIntent{.{ .net = "VDD", .ripple_v = 0.05, .step_current_a = 0.1 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &loops,
        .stubs = &.{},
        .instances = &instances,
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 1 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .rules = .{ .copper_layers = 2, .physical = .{ .stack = .{ .layers = 2 }, .pdn_intents = &intents } },
    };
    // Only the capacitor is stitched: without the authored surface GND pour,
    // no complete via/plane/via path reaches the load ground land.
    const ground_vias = [_]router.Via{.{ .x = 2, .y = 6, .dia = 0.4, .drill = 0.2, .net = 1 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &ground_vias, .routed = 0, .total = 1 };
    const zone_poly = [_][2]f64{ .{ 1, 4 }, .{ 9, 4 }, .{ 9, 5.4 }, .{ 1, 5.4 } };
    const ground_poly = [_][2]f64{ .{ 1, 5.6 }, .{ 9, 5.6 }, .{ 9, 6.4 }, .{ 1, 6.4 } };
    const zones = [_]pour.UserZone{
        .{ .net = "VDD", .layer = 0, .poly = &zone_poly },
        .{ .net = "GND", .layer = 0, .poly = &ground_poly },
    };
    const without = try analyze(alloc, placement, routed);
    const with = try analyzeCopper(alloc, std.testing.allocator, placement, routed, &zones, null);
    try std.testing.expectEqualStrings("fallback", without.rails[0].capacitors[0].path_kind.power);
    try std.testing.expectEqualStrings("estimated-via-return", without.rails[0].capacitors[0].path_kind.ground);
    try std.testing.expect(without.rails[0].passes == null);
    try std.testing.expectEqualStrings("computed-pour", with.rails[0].capacitors[0].path_kind.power);
    try std.testing.expectEqualStrings("computed-pour", with.rails[0].capacitors[0].path_kind.ground);
    try std.testing.expect(with.rails[0].capacitors[0].mounting_inductance_h > 0);
    try std.testing.expect(with.rails[0].passes != null);
    try std.testing.expect(with.rails[0].capacitors[0].mounting_inductance_h < without.rails[0].capacitors[0].mounting_inductance_h);

    const blocker_poly = [_][2]f64{ .{ 4.5, 3 }, .{ 5.5, 3 }, .{ 5.5, 7 }, .{ 4.5, 7 } };
    const clipped_zones = [_]pour.UserZone{
        .{ .net = "VDD", .layer = 0, .poly = &zone_poly },
        .{ .net = "OTHER", .layer = 0, .poly = &blocker_poly, .priority = 1 },
    };
    const clipped = try analyzeCopper(alloc, std.testing.allocator, placement, routed, &clipped_zones, null);
    try std.testing.expectEqualStrings("fallback", clipped.rails[0].capacitors[0].path_kind.power);
    try std.testing.expect(clipped.rails[0].passes == null);
}
