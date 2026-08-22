//! Pour-derived, high-resolution route-space path director.
//!
//! This module does not schedule nets, choose layers, place vias, rip copper,
//! or accept a route. It answers one narrower question for the existing
//! router: on a fixed layer, where may this trace centreline flow? The answer
//! comes from the pour engine's signed-margin raster and exact obstacle stamps.
//! A margin-aware A* walk chooses a corridor; line-of-sight string pulling then
//! removes raster stair steps and returns off-grid world coordinates. The
//! router remains the authority: it exact-clearance-checks every returned chord
//! before committing it and falls back to its lattice maze on any refusal.

const std = @import("std");
const numeric = @import("../numeric.zig");
const optimizer = @import("optimizer.zig");
const pour = @import("pour.zig");
const route_policy = @import("route_policy.zig");
const route_space_cache = @import("route_space_cache.zig");
const router = @import("router.zig");

const Point = [2]f64;

/// Default route-space sampling pitch. It matches the historical Route Lab
/// field and is 8.8x finer than Barracuda's widest-class 0.4394 mm lattice.
const default_pitch_mm: f64 = 0.05;
/// Same safety ceiling as a pour field. One attempt owns scratch memory and
/// releases it before the next leg, so this bounds peak rather than cumulative
/// memory.
const default_max_cells: usize = 3_000_000;

/// Geometry and resource limits for one fixed-layer path query.
const Params = struct {
    net: i32,
    layer: u8,
    track_width: f64,
    clearance: f64,
    pitch: f64 = default_pitch_mm,
    max_cells: usize = default_max_cells,
};

/// Immutable board/copper world and endpoints for one path query.
const Input = struct {
    placement: optimizer.Placement,
    copper: CopperWorld,
    start: Point,
    goal: Point,
    params: Params,
};

/// Existing physical obstacles rasterized into one signed-margin field.
const CopperWorld = struct {
    pads: []const router.PadObs,
    tracks: []const router.Track,
    vias: []const router.Via,
    zones: []const route_policy.ExistingZone = &.{},
};

/// One path query's observable outcome. `path == null` is a normal decline;
/// the caller falls through to the unchanged lattice path.
const Result = struct {
    path: ?[]const Point = null,
    requested_pitch: f64,
    pitch: f64,
    cells: usize = 0,
    expansions: usize = 0,
    coarsened: bool = false,
    terminals_free: bool = false,
    static_cache_hit: bool = false,
    query_cache_hit: bool = false,
    live_cache_hit: bool = false,
};

const Frame = struct {
    minx: f64,
    miny: f64,
    pitch: f64,
    nx: usize,
    ny: usize,

    fn center(self: Frame, cell: usize) Point {
        return .{
            self.minx + (@as(f64, @floatFromInt(cell % self.nx)) + 0.5) * self.pitch,
            self.miny + (@as(f64, @floatFromInt(cell / self.nx)) + 0.5) * self.pitch,
        };
    }

    fn cellAt(self: Frame, p: Point) ?usize {
        if (self.pitch <= 0) return null;
        if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return null;
        const rx = @floor((p[0] - self.minx) / self.pitch);
        const ry = @floor((p[1] - self.miny) / self.pitch);
        if (rx < 0 or ry < 0) return null;
        const x = numeric.checkedInt(usize, rx) orelse return null;
        const y = numeric.checkedInt(usize, ry) orelse return null;
        if (x >= self.nx or y >= self.ny) return null;
        return y * self.nx + x;
    }
};

const Field = struct {
    frame: Frame,
    margin: []const f32,
    guard: f64,

    fn free(self: Field, cell: usize) bool {
        return cell < self.margin.len and @as(f64, self.margin[cell]) > self.guard;
    }
};

const no_parent = std.math.maxInt(u32);
const no_direction: u8 = 8;
const cost_epsilon: f64 = 1e-10;
const clearance_weight: f64 = 4.0;
const bend_weight: f64 = 0.35;

const QueueItem = struct { score: f64, cost: f64, cell: u32 };

fn queueOrder(_: void, a: QueueItem, b: QueueItem) std.math.Order {
    const by_score = std.math.order(a.score, b.score);
    if (by_score != .eq) return by_score;
    const by_cost = std.math.order(a.cost, b.cost);
    if (by_cost != .eq) return by_cost;
    return std.math.order(a.cell, b.cell);
}

const SearchResult = struct { cells: ?[]const u32, expansions: usize };

/// Direct every leg of the router's ordinary terminal tree, then ask its
/// existing exact oracle to pull the field guide taut and accept the complete
/// candidate before committing any copper. Generic host arguments keep routing
/// policy and mutable grid state in `router.zig`; this module owns only
/// free-space discovery.
pub fn tryTerminalTree(
    result_arena: std.mem.Allocator,
    ctx: anytype,
    net: i32,
    pts: []const router.NetPt,
    tracks: *std.ArrayList(router.Track),
    vias: *std.ArrayList(router.Via),
    comptime DirectPath: type,
    comptime clear_segment: fn (DirectPath, Point, Point) bool,
    comptime stamp_occ: fn (@TypeOf(ctx), Point, Point, i32, u8) void,
    comptime stamp_rf: fn (@TypeOf(ctx), Point, Point, i32, u8) void,
) std.mem.Allocator.Error!bool {
    const field_space = ctx.field_space orelse return false;
    const scratch_allocator = field_space.provider.fieldAllocator().?;
    if (pts.len < 2 or pts.len > 12) return false;
    if (escapeActive(ctx)) return false;
    if (ctx.corridor != null or ctx.reference_corridor != null) return false;
    const placement = field_space.placement;
    const layer = pts[0].layer;
    if (!layerAllowed(ctx.allowed_layers, layer)) return false;
    for (pts[1..]) |pt| if (pt.layer != layer) return false;

    const legs = try mstLegs(result_arena, pts);
    if (legs.len == 0) return false;
    var paths: std.ArrayList([]const Point) = .empty;
    for (legs) |leg| {
        var scratch_state = std.heap.ArenaAllocator.init(scratch_allocator);
        defer scratch_state.deinit();
        if (ctx.timing) |timing| {
            timing.begin(.field);
            timing.counters.field_attempts +|= 1;
        }
        const result = findPath(scratch_state.allocator(), field_space.provider.fieldCache(), .{
            .placement = placement,
            .copper = .{ .pads = ctx.obs, .tracks = tracks.items, .vias = vias.items, .zones = ctx.zones },
            .start = .{ pts[leg[0]].x, pts[leg[0]].y },
            .goal = .{ pts[leg[1]].x, pts[leg[1]].y },
            .params = .{
                .net = net,
                .layer = layer,
                .track_width = ctx.params.track_width,
                .clearance = ctx.params.clearance,
            },
        }) catch |err| {
            if (ctx.timing) |timing| timing.end(.field);
            return err;
        };
        if (ctx.timing) |timing| {
            timing.end(.field);
            timing.counters.field_expansions +|= result.expansions;
            timing.counters.field_terminal_pairs +|= @intFromBool(result.terminals_free);
            timing.counters.field_coarsened +|= @intFromBool(result.coarsened);
            timing.counters.field_static_cache_hits +|= @intFromBool(result.static_cache_hit);
            timing.counters.field_query_cache_hits +|= @intFromBool(result.query_cache_hit);
            timing.counters.field_live_cache_hits +|= @intFromBool(result.live_cache_hit);
        }
        const path = result.path orelse return false;
        if (path.len < 2) return false;
        try paths.append(result_arena, try result_arena.dupe(Point, path));
    }

    const exact = DirectPath{ .ctx = ctx, .net = net, .layer = layer, .tracks = tracks.items, .vias = vias.items };
    var taut_paths: std.ArrayList([]const Point) = .empty;
    for (paths.items) |path| {
        const taut = try exactPull(result_arena, DirectPath, exact, path, clear_segment) orelse return false;
        try taut_paths.append(result_arena, taut);
    }
    for (taut_paths.items) |path| {
        for (path[0 .. path.len - 1], path[1..]) |a, b| {
            if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < 1e-9) continue;
            try tracks.append(result_arena, .{
                .x1 = a[0],
                .y1 = a[1],
                .x2 = b[0],
                .y2 = b[1],
                .layer = layer,
                .width = ctx.params.track_width,
                .net = net,
            });
            stamp_occ(ctx, a, b, net, layer);
            stamp_rf(ctx, a, b, net, layer);
        }
    }
    if (ctx.timing) |timing| timing.counters.field_successes +|= legs.len;
    return true;
}

/// Pull a raster-derived polyline taut with the router's exact world-space
/// clearance oracle. The field still chooses the corridor; this pass only
/// removes waypoints whose longer replacement chord is physically legal.
fn exactPull(
    arena: std.mem.Allocator,
    comptime DirectPath: type,
    exact: DirectPath,
    points: []const Point,
    comptime clear_segment: fn (DirectPath, Point, Point) bool,
) std.mem.Allocator.Error!?[]const Point {
    if (points.len < 2) return null;
    var out: std.ArrayList(Point) = .empty;
    try out.append(arena, points[0]);
    var anchor: usize = 0;
    while (anchor + 1 < points.len) {
        var next = points.len - 1;
        while (next > anchor and !clear_segment(exact, points[anchor], points[next])) : (next -= 1) {}
        if (next == anchor) return null;
        try appendDistinct(arena, &out, points[next]);
        anchor = next;
    }
    return @as(?[]const Point, try out.toOwnedSlice(arena));
}

fn escapeActive(ctx: anytype) bool {
    if (ctx.rf.escape_mm <= 0) return false;
    for (ctx.rf.escape_pts) |pt| if (pt.out[0] != 0 or pt.out[1] != 0) return true;
    return false;
}

fn layerAllowed(mask: u64, layer: u8) bool {
    if (mask == 0) return true;
    if (layer >= 64) return false;
    return (mask & (@as(u64, 1) << @intCast(layer))) != 0;
}

fn mstLegs(arena: std.mem.Allocator, pts: []const router.NetPt) std.mem.Allocator.Error![]const [2]usize {
    const comp = try arena.alloc(usize, pts.len);
    for (comp, 0..) |*component, i| component.* = i;
    var legs: std.ArrayList([2]usize) = .empty;
    var joined: usize = 1;
    while (joined < pts.len) : (joined += 1) {
        var best = std.math.inf(f64);
        var choice: ?[2]usize = null;
        for (0..pts.len) |i| {
            for (i + 1..pts.len) |j| {
                if (comp[i] == comp[j]) continue;
                const dx = pts[i].x - pts[j].x;
                const dy = pts[i].y - pts[j].y;
                const distance = dx * dx + dy * dy;
                if (distance < best) {
                    best = distance;
                    choice = .{ i, j };
                }
            }
        }
        const leg = choice orelse break;
        try legs.append(arena, leg);
        const from = comp[leg[1]];
        const to = comp[leg[0]];
        for (comp) |*component| {
            if (component.* == from) component.* = to;
        }
    }
    return legs.toOwnedSlice(arena);
}

/// Compute a whole-board fixed-layer path. Returned points live in `arena` or
/// the longer-lived cache; large field/search arrays live in `arena`, so
/// callers should pass short-lived scratch and copy each path they accept.
fn findPath(arena: std.mem.Allocator, cache: ?*route_space_cache.Cache, in: Input) std.mem.Allocator.Error!Result {
    const requested = if (std.math.isFinite(in.params.pitch) and in.params.pitch > 0)
        in.params.pitch
    else
        default_pitch_mm;
    var pitch = requested;
    const bounds = boundsRect(in.placement);
    var nx = gridCount(bounds.w, pitch);
    var ny = gridCount(bounds.h, pitch);
    var coarsened = false;
    while (!withinLimit(nx, ny, in.params.max_cells)) {
        pitch *= 1.5;
        nx = gridCount(bounds.w, pitch);
        ny = gridCount(bounds.h, pitch);
        coarsened = true;
    }
    const count = nx * ny;
    const frame = Frame{ .minx = bounds.minx, .miny = bounds.miny, .pitch = pitch, .nx = nx, .ny = ny };
    var out = Result{
        .requested_pitch = requested,
        .pitch = pitch,
        .cells = count,
        .coarsened = coarsened,
    };
    if (count == 0 or count > std.math.maxInt(u32)) return out;

    const radius = in.params.track_width / 2;
    const edge = @max(in.params.clearance, in.placement.rules.design.edgeClearance());
    const key = staticKey(in, bounds, frame, radius, edge);
    const live_key = liveKey(key, in);
    const query_key = queryKey(live_key, in);
    if (cache) |field_cache| {
        if (field_cache.getQuery(query_key)) |saved| return .{
            .path = saved.path,
            .requested_pitch = saved.requested_pitch,
            .pitch = saved.pitch,
            .cells = saved.cells,
            .coarsened = saved.coarsened,
            .terminals_free = saved.terminals_free,
            .query_cache_hit = true,
        };
    }

    const margin = try arena.alloc(f32, count);
    const guard = pitch / @sqrt(2.0);
    const grid = pour.Grid{
        .minx = bounds.minx,
        .miny = bounds.miny,
        .pitch = pitch,
        .nx = nx,
        .ny = ny,
        .labels = &.{},
        .margin = margin,
        .iso = guard,
    };
    if (cache) |field_cache| out.live_cache_hit = field_cache.getLive(live_key, margin);
    if (!out.live_cache_hit) {
        if (cache) |static_cache| {
            if (static_cache.get(key)) |base| {
                if (base.len == margin.len) {
                    @memcpy(margin, base);
                    out.static_cache_hit = true;
                }
            }
        }
    }
    if (!out.live_cache_hit and !out.static_cache_hit) {
        pour.initMargin(grid, in.placement, bounds, radius + edge);
        stampStaticObstacles(grid, in, radius);
        if (cache) |static_cache| _ = static_cache.put(key, margin) catch false;
    }
    if (!out.live_cache_hit) {
        stampLiveObstacles(grid, in, radius);
        if (cache) |field_cache| field_cache.putLive(live_key, margin) catch |err| {
            std.debug.assert(err == error.OutOfMemory);
        };
    }

    const field = Field{
        .frame = frame,
        .margin = margin,
        .guard = guard,
    };
    const start = field.frame.cellAt(in.start) orelse return out;
    const goal = field.frame.cellAt(in.goal) orelse return out;
    if (!field.free(start) or !field.free(goal)) return out;
    out.terminals_free = true;

    const searched = try search(arena, field, start, goal);
    out.expansions = searched.expansions;
    const cells = searched.cells orelse return out;
    const turns = try compact(arena, field, cells, in.start, in.goal);
    const pulled = try stringPull(arena, field, turns);
    if (pulled.len >= 2) out.path = pulled;
    if (cache) |field_cache| field_cache.putQuery(query_key, .{
        .path = out.path,
        .requested_pitch = out.requested_pitch,
        .pitch = out.pitch,
        .cells = out.cells,
        .coarsened = out.coarsened,
        .terminals_free = out.terminals_free,
    }) catch return out;
    return out;
}

fn boundsRect(placement: optimizer.Placement) optimizer.BoardRect {
    return placement.board_rect orelse .{
        .minx = placement.minx - 1,
        .miny = placement.miny - 1,
        .w = placement.maxx - placement.minx + 2,
        .h = placement.maxy - placement.miny + 2,
    };
}

fn gridCount(extent: f64, pitch: f64) usize {
    if (extent <= 0 or pitch <= 0 or !std.math.isFinite(extent)) return 0;
    return numeric.toCount(@ceil(extent / pitch));
}

fn withinLimit(nx: usize, ny: usize, cap: usize) bool {
    return cap > 0 and (ny == 0 or nx <= cap / ny);
}

fn stampStaticObstacles(g: pour.Grid, in: Input, radius: f64) void {
    for (in.copper.pads) |pad| {
        if (pad.net == in.params.net) continue;
        if (!pad.thru and pad.layer != in.params.layer) continue;
        const gap = in.placement.rules.clearanceBetween(in.params.net, pad.net, in.params.clearance);
        pour.stampPadShape(g, .{ .x0 = pad.x0, .y0 = pad.y0, .x1 = pad.x1, .y1 = pad.y1, .poly = pad.poly }, radius + gap);
    }
    for (in.copper.zones) |zone| {
        if (zone.layer != in.params.layer or !zone.tracks_blocked) continue;
        if (zone.copper and zone.net == in.params.net) continue;
        const gap = in.placement.rules.clearanceBetween(in.params.net, zone.net, in.params.clearance);
        pour.stampPolygon(g, zone.polygon, radius + gap);
    }
}

fn stampLiveObstacles(g: pour.Grid, in: Input, radius: f64) void {
    for (in.copper.tracks) |track| {
        if (track.net == in.params.net or track.layer != in.params.layer) continue;
        const gap = in.placement.rules.clearanceBetween(in.params.net, track.net, in.params.clearance);
        pour.stampSeg(g, track.x1, track.y1, track.x2, track.y2, track.width / 2 + radius + gap);
    }
    for (in.copper.vias) |via| {
        if (via.net == in.params.net) continue;
        const gap = in.placement.rules.clearanceBetween(in.params.net, via.net, in.params.clearance);
        pour.stampDisc(g, via.x, via.y, via.dia / 2 + radius + gap);
    }
}

fn staticKey(
    in: Input,
    bounds: optimizer.BoardRect,
    frame: Frame,
    radius: f64,
    edge: f64,
) route_space_cache.Key {
    var lo = std.hash.Wyhash.init(0x243f6a8885a308d3);
    var hi = std.hash.Wyhash.init(0x13198a2e03707344);
    hashF64(&lo, &hi, bounds.minx);
    hashF64(&lo, &hi, bounds.miny);
    hashF64(&lo, &hi, bounds.w);
    hashF64(&lo, &hi, bounds.h);
    hashF64(&lo, &hi, frame.pitch);
    hashU64(&lo, &hi, frame.nx);
    hashU64(&lo, &hi, frame.ny);
    hashF64(&lo, &hi, radius);
    hashF64(&lo, &hi, edge);
    hashI32(&lo, &hi, in.params.net);
    hashU64(&lo, &hi, in.params.layer);
    if (in.placement.board_poly) |poly| {
        hashU64(&lo, &hi, 1);
        hashPoints(&lo, &hi, poly);
    } else hashU64(&lo, &hi, 0);

    for (in.copper.pads) |pad| {
        if (pad.net == in.params.net) continue;
        if (!pad.thru and pad.layer != in.params.layer) continue;
        hashU64(&lo, &hi, 1);
        hashI32(&lo, &hi, pad.net);
        hashF64(&lo, &hi, pad.x0);
        hashF64(&lo, &hi, pad.y0);
        hashF64(&lo, &hi, pad.x1);
        hashF64(&lo, &hi, pad.y1);
        hashPoints(&lo, &hi, pad.poly);
        hashF64(&lo, &hi, in.placement.rules.clearanceBetween(in.params.net, pad.net, in.params.clearance));
    }
    hashU64(&lo, &hi, 2);
    for (in.copper.zones) |zone| {
        if (zone.layer != in.params.layer or !zone.tracks_blocked) continue;
        if (zone.copper and zone.net == in.params.net) continue;
        hashI32(&lo, &hi, zone.net);
        hashU64(&lo, &hi, @intFromBool(zone.copper));
        hashPoints(&lo, &hi, zone.polygon);
        hashF64(&lo, &hi, in.placement.rules.clearanceBetween(in.params.net, zone.net, in.params.clearance));
    }
    return .{ .lo = lo.final(), .hi = hi.final() };
}

fn liveKey(base: route_space_cache.Key, in: Input) route_space_cache.Key {
    var lo = std.hash.Wyhash.init(base.lo);
    var hi = std.hash.Wyhash.init(base.hi);
    for (in.copper.tracks) |track| {
        if (track.net == in.params.net or track.layer != in.params.layer) continue;
        hashU64(&lo, &hi, 3);
        hashI32(&lo, &hi, track.net);
        hashF64(&lo, &hi, track.x1);
        hashF64(&lo, &hi, track.y1);
        hashF64(&lo, &hi, track.x2);
        hashF64(&lo, &hi, track.y2);
        hashF64(&lo, &hi, track.width);
        hashF64(&lo, &hi, in.placement.rules.clearanceBetween(in.params.net, track.net, in.params.clearance));
    }
    hashU64(&lo, &hi, 4);
    for (in.copper.vias) |via| {
        if (via.net == in.params.net) continue;
        hashI32(&lo, &hi, via.net);
        hashF64(&lo, &hi, via.x);
        hashF64(&lo, &hi, via.y);
        hashF64(&lo, &hi, via.dia);
        hashF64(&lo, &hi, in.placement.rules.clearanceBetween(in.params.net, via.net, in.params.clearance));
    }
    return .{ .lo = lo.final(), .hi = hi.final() };
}

fn queryKey(base: route_space_cache.Key, in: Input) route_space_cache.Key {
    var lo = std.hash.Wyhash.init(base.lo);
    var hi = std.hash.Wyhash.init(base.hi);
    hashF64(&lo, &hi, in.start[0]);
    hashF64(&lo, &hi, in.start[1]);
    hashF64(&lo, &hi, in.goal[0]);
    hashF64(&lo, &hi, in.goal[1]);
    return .{ .lo = lo.final(), .hi = hi.final() };
}

fn hashPoints(lo: *std.hash.Wyhash, hi: *std.hash.Wyhash, points: []const Point) void {
    hashU64(lo, hi, points.len);
    for (points) |point| {
        hashF64(lo, hi, point[0]);
        hashF64(lo, hi, point[1]);
    }
}

fn hashU64(lo: *std.hash.Wyhash, hi: *std.hash.Wyhash, value: u64) void {
    lo.update(std.mem.asBytes(&value));
    hi.update(std.mem.asBytes(&value));
}

fn hashF64(lo: *std.hash.Wyhash, hi: *std.hash.Wyhash, value: f64) void {
    lo.update(std.mem.asBytes(&value));
    hi.update(std.mem.asBytes(&value));
}

fn hashI32(lo: *std.hash.Wyhash, hi: *std.hash.Wyhash, value: i32) void {
    lo.update(std.mem.asBytes(&value));
    hi.update(std.mem.asBytes(&value));
}

fn search(arena: std.mem.Allocator, field: Field, start: usize, goal: usize) std.mem.Allocator.Error!SearchResult {
    if (start == goal) return .{ .cells = try arena.dupe(u32, &.{@intCast(start)}), .expansions = 0 };
    const dist = try arena.alloc(f64, field.margin.len);
    const parent = try arena.alloc(u32, field.margin.len);
    const incoming = try arena.alloc(u8, field.margin.len);
    @memset(dist, std.math.inf(f64));
    @memset(parent, no_parent);
    @memset(incoming, no_direction);
    dist[start] = 0;
    parent[start] = @intCast(start);
    var queue = std.PriorityQueue(QueueItem, void, queueOrder).initContext({});
    defer queue.deinit(arena);
    try queue.push(arena, .{ .score = heuristic(field, start, goal), .cost = 0, .cell = @intCast(start) });
    var expansions: usize = 0;
    const dx = [_]i8{ -1, 1, 0, 0, -1, 1, 1, -1 };
    const dy = [_]i8{ 0, 0, -1, 1, -1, -1, 1, 1 };
    while (queue.pop()) |item| {
        const cell: usize = @intCast(item.cell);
        if (item.cost > dist[cell] + cost_epsilon) continue;
        if (cell == goal) return .{ .cells = try recover(arena, parent, start, goal), .expansions = expansions };
        if (expansions >= field.margin.len) break;
        expansions += 1;
        const x = cell % field.frame.nx;
        const y = cell / field.frame.nx;
        for (dx, dy, 0..) |sx, sy, direction_i| {
            const next = neighbor(field.frame, x, y, sx, sy) orelse continue;
            if (!field.free(next)) continue;
            const diagonal = sx != 0 and sy != 0;
            if (diagonal) {
                const side_x = neighbor(field.frame, x, y, sx, 0) orelse continue;
                const side_y = neighbor(field.frame, x, y, 0, sy) orelse continue;
                if (!field.free(side_x) or !field.free(side_y)) continue;
            }
            const step = field.frame.pitch * (if (diagonal) @as(f64, @sqrt(2.0)) else 1.0);
            const slack = @max(@as(f64, field.margin[next]) - field.guard, 0);
            const clearance_cost = step * clearance_weight * field.frame.pitch / (slack + field.frame.pitch);
            const bend_cost = if (incoming[cell] != no_direction and incoming[cell] != direction_i)
                field.frame.pitch * bend_weight
            else
                0;
            const candidate = dist[cell] + step + clearance_cost + bend_cost;
            if (candidate + cost_epsilon >= dist[next]) continue;
            dist[next] = candidate;
            parent[next] = @intCast(cell);
            incoming[next] = @intCast(direction_i);
            try queue.push(arena, .{ .score = candidate + heuristic(field, next, goal), .cost = candidate, .cell = @intCast(next) });
        }
    }
    return .{ .cells = null, .expansions = expansions };
}

fn neighbor(frame: Frame, x: usize, y: usize, dx: i8, dy: i8) ?usize {
    const nx = @as(i64, @intCast(x)) + dx;
    const ny = @as(i64, @intCast(y)) + dy;
    if (nx < 0 or ny < 0 or nx >= @as(i64, @intCast(frame.nx)) or ny >= @as(i64, @intCast(frame.ny))) return null;
    return @as(usize, @intCast(ny)) * frame.nx + @as(usize, @intCast(nx));
}

fn heuristic(field: Field, cell: usize, goal: usize) f64 {
    const a = field.frame.center(cell);
    const b = field.frame.center(goal);
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

fn recover(arena: std.mem.Allocator, parent: []const u32, start: usize, goal: usize) std.mem.Allocator.Error![]const u32 {
    var count: usize = 1;
    var cursor = goal;
    while (cursor != start) : (count += 1) {
        if (parent[cursor] == no_parent or count > parent.len) return arena.dupe(u32, &.{});
        cursor = @intCast(parent[cursor]);
    }
    const cells = try arena.alloc(u32, count);
    cursor = goal;
    var out = cells.len;
    while (true) {
        out -= 1;
        cells[out] = @intCast(cursor);
        if (cursor == start) break;
        cursor = @intCast(parent[cursor]);
    }
    return cells;
}

fn compact(arena: std.mem.Allocator, field: Field, cells: []const u32, start: Point, goal: Point) std.mem.Allocator.Error![]const Point {
    var points: std.ArrayList(Point) = .empty;
    try appendDistinct(arena, &points, start);
    if (cells.len >= 3) {
        var previous = direction(field.frame.nx, cells[0], cells[1]);
        for (1..cells.len - 1) |i| {
            const next = direction(field.frame.nx, cells[i], cells[i + 1]);
            if (next == previous) continue;
            try appendDistinct(arena, &points, field.frame.center(cells[i]));
            previous = next;
        }
    }
    try appendDistinct(arena, &points, goal);
    return points.toOwnedSlice(arena);
}

fn direction(nx: usize, from: u32, to: u32) u8 {
    const ax: i64 = @intCast(@as(usize, @intCast(from)) % nx);
    const ay: i64 = @intCast(@as(usize, @intCast(from)) / nx);
    const bx: i64 = @intCast(@as(usize, @intCast(to)) % nx);
    const by: i64 = @intCast(@as(usize, @intCast(to)) / nx);
    const xs: u8 = if (bx < ax) 0 else if (bx > ax) 2 else 1;
    const ys: u8 = if (by < ay) 0 else if (by > ay) 2 else 1;
    return ys * 3 + xs;
}

fn stringPull(arena: std.mem.Allocator, field: Field, points: []const Point) std.mem.Allocator.Error![]const Point {
    if (points.len <= 2) return arena.dupe(Point, points);
    var out: std.ArrayList(Point) = .empty;
    try out.append(arena, points[0]);
    var anchor: usize = 0;
    while (anchor + 1 < points.len) {
        var next = points.len - 1;
        while (next > anchor + 1 and !segmentLegal(field, points[anchor], points[next])) : (next -= 1) {}
        try appendDistinct(arena, &out, points[next]);
        anchor = next;
    }
    return out.toOwnedSlice(arena);
}

fn segmentLegal(field: Field, a: Point, b: Point) bool {
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (field.frame.pitch * 0.25))));
    for (0..steps + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const p = Point{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) };
        const cell = field.frame.cellAt(p) orelse return false;
        if (!field.free(cell)) return false;
    }
    return true;
}

fn appendDistinct(arena: std.mem.Allocator, points: *std.ArrayList(Point), p: Point) std.mem.Allocator.Error!void {
    if (points.items.len > 0) {
        const q = points.items[points.items.len - 1];
        if (std.math.hypot(p[0] - q[0], p[1] - q[1]) <= 1e-9) return;
    }
    try points.append(arena, p);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const flat_netlist = @import("../flat_netlist.zig");

const PullProbe = struct { max_chord_mm: f64 };

fn pullProbeClear(probe: PullProbe, a: Point, b: Point) bool {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]) <= probe.max_chord_mm;
}

const test_nets = [_]flat_netlist.FlatNet{
    .{ .name = "SIG", .pins = &.{} },
    .{ .name = "WALL", .pins = &.{} },
};

// spec: placement/router - the field's exact oracle removes conservative raster waypoints while preserving required corridor turns
test "exact route-space pull keeps only the farthest clear waypoint" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const points = [_]Point{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 0 }, .{ 3, 0 } };
    const pulled = (try exactPull(arena_i.allocator(), PullProbe, .{ .max_chord_mm = 2.1 }, &points, pullProbeClear)).?;
    try testing.expectEqualSlices(Point, &.{ .{ 0, 0 }, .{ 2, 0 }, .{ 3, 0 } }, pulled);
}

fn fixture() optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &test_nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .generated = false,
    };
}

// spec: placement/router - a pour-derived field string-pulls an open corridor to one direct off-grid segment
test "open field returns one direct chord" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const result = try findPath(arena_i.allocator(), null, .{
        .placement = fixture(),
        .copper = .{ .pads = &.{}, .tracks = &.{}, .vias = &.{} },
        .start = .{ 1, 5 },
        .goal = .{ 9, 5 },
        .params = .{ .net = 0, .layer = 0, .track_width = 0.2, .clearance = 0.2 },
    });
    try testing.expect(result.path != null);
    try testing.expectEqual(@as(usize, 2), result.path.?.len);
}

// The cache is an optimization only: all three reuse levels preserve paths.
test "field cache preserves paths across static live and query hits" {
    var cache = route_space_cache.Cache.init(testing.allocator);
    defer cache.deinit();
    const input = Input{
        .placement = fixture(),
        .copper = .{ .pads = &.{}, .tracks = &.{}, .vias = &.{} },
        .start = .{ 1, 5 },
        .goal = .{ 9, 5 },
        .params = .{ .net = 0, .layer = 0, .track_width = 0.2, .clearance = 0.2 },
    };
    var first_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer first_arena.deinit();
    const first = try findPath(first_arena.allocator(), &cache, input);
    try testing.expect(!first.static_cache_hit);

    var static_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer static_arena.deinit();
    var nearby = input;
    nearby.goal = .{ 8, 5 };
    const second = try findPath(static_arena.allocator(), &cache, nearby);
    try testing.expect(second.live_cache_hit);

    var query_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer query_arena.deinit();
    const repeated = try findPath(query_arena.allocator(), &cache, input);
    try testing.expect(repeated.query_cache_hit);
    try testing.expectEqualSlices(Point, first.path.?, repeated.path.?);

    var static_hit_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer static_hit_arena.deinit();
    const distant = [_]router.Track{.{ .x1 = 2, .y1 = 8, .x2 = 3, .y2 = 8, .layer = 0, .width = 0.1, .net = 1 }};
    var changed_live = nearby;
    changed_live.copper.tracks = &distant;
    const static_hit = try findPath(static_hit_arena.allocator(), &cache, changed_live);
    try testing.expect(static_hit.static_cache_hit);
}

// spec: placement/router - a sub-base-grid opening remains visible at the fixed 0.05 mm field pitch
test "high resolution field sees a narrow wall opening" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const walls = [_]router.Track{
        .{ .x1 = 5, .y1 = 0, .x2 = 5, .y2 = 4.65, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 5, .y1 = 5.35, .x2 = 5, .y2 = 10, .layer = 0, .width = 0.2, .net = 1 },
    };
    const result = try findPath(arena_i.allocator(), null, .{
        .placement = fixture(),
        .copper = .{ .pads = &.{}, .tracks = &walls, .vias = &.{} },
        .start = .{ 1, 5 },
        .goal = .{ 9, 5 },
        .params = .{ .net = 0, .layer = 0, .track_width = 0.1, .clearance = 0.1 },
    });
    try testing.expect(result.path != null);
    try testing.expect(!result.coarsened);
}
