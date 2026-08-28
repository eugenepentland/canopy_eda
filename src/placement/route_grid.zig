//! How big the routing lattice is, and how finely it is rastered.
//!
//! The maze can only put a track centerline on a grid node, so the lattice
//! pitch is the one number that decides which physical corridors the router is
//! even able to express. Everything that sizes it lives here: the whole-board
//! pitch, the node budget that caps it, the scoped-selection fine promotion,
//! and the widest/narrowest class scan the pitch is derived from.
//!
//! Extracted from `router.zig` (which is at Guardian's code-line ceiling) so
//! the pitch policy is one small readable unit instead of five helpers spread
//! across a 13k-line file. `router.zig` aliases the names it used to own, so
//! its call sites are unchanged.
//!
//! ## Why the pitch is a policy at all
//!
//! Historically one pitch served the whole board and it was sized to the
//! WIDEST net class (`maxRouteParams`), so two adjacent occupied grid lines
//! satisfy clearance even between the fattest pair of classes. That is safe,
//! but it is also the reason a 0.127 mm control net on barracuda rasters at
//! the 0.3124 mm RF class's 0.4394 mm pitch — 1.73x coarser than it needs,
//! on a board where most nets are control nets.
//!
//! The pitch does NOT carry the clearance guarantee on its own: `setNetParams`
//! already gives every net its own exact width/clearance for obstacle halos,
//! copper stamping and the DRC probes (`router.setNetParams` sets `ctx.params`
//! and `ctx.reach` per net, and `stampBoardCopper` haloes at that reach). So a
//! FINER pitch is strictly more expressive and never less legal — it only
//! costs nodes. That is what makes `Mode.narrowest` a legitimate option rather
//! than a correctness gamble, and it is the audit's own alternative phrasing:
//! "base the lattice on the narrowest class and inflate wide nets' halos".
//!
//! What a finer pitch DOES cost, besides memory: the per-leg expansion budget
//! is a COUNT, so the same budget reaches a smaller physical radius on a finer
//! lattice. Halving the pitch quarters the area one budget can sweep. A finer
//! board raster is therefore not a free routability win, and `Mode.narrowest`
//! ships off by default until a board measures better with it.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const numeric = @import("../numeric.zig");

/// The routing raster: origin (`ox`,`oy`), pitch `g`, and cell counts. Node
/// index `iy*nx+ix` addresses the occupancy grids. Exposed for the interactive
/// session's frontier flood.
pub const Grid = struct {
    ox: f64,
    oy: f64,
    g: f64,
    nx: usize,
    ny: usize,

    /// Flat node index of cell (ix, iy).
    pub fn node(self: Grid, ix: usize, iy: usize) usize {
        return iy * self.nx + ix;
    }
    /// World x (mm) of column `ix`.
    pub fn worldX(self: Grid, ix: usize) f64 {
        return self.ox + @as(f64, @floatFromInt(ix)) * self.g;
    }
    /// World y (mm) of row `iy`.
    pub fn worldY(self: Grid, iy: usize) f64 {
        return self.oy + @as(f64, @floatFromInt(iy)) * self.g;
    }
    /// Nearest grid node to a world point, clamped to the grid.
    pub fn nearest(self: Grid, x: f64, y: f64) [2]usize {
        const fx = std.math.clamp(@round((x - self.ox) / self.g), 0, @as(f64, @floatFromInt(self.nx - 1)));
        const fy = std.math.clamp(@round((y - self.oy) / self.g), 0, @as(f64, @floatFromInt(self.ny - 1)));
        return .{ numeric.toCount(fx), numeric.toCount(fy) };
    }
    /// World coords of the nearest grid node — snapping a via onto the grid so
    /// the `copperHalo` exclusion (exact only for on-grid centres) holds.
    pub fn snap(self: Grid, x: f64, y: f64) [2]f64 {
        const nd = self.nearest(x, y);
        return .{ self.worldX(nd[0]), self.worldY(nd[1]) };
    }
};

/// Largest grid (nodes per SIGNAL LAYER) the normal router will attempt — keeps
/// a huge board from allocating an enormous grid; modules stay far under this.
/// Total node count scales with the stackup's signal-layer count (the cap is
/// per layer), and a bail is reported via `RouteResult.grid_overflow`.
pub const max_nodes: usize = 200_000;

/// Raster apron (mm) added on every side of the placement bounding box, so a
/// track may detour just outside the parts before coming back in.
pub const apron_mm: f64 = 1.0;

/// Floor on any lattice pitch (mm). Below this a board-spanning grid stops
/// being a search and becomes a memory allocation.
const min_pitch_mm: f64 = 0.05;

/// A selection this size or smaller is a targeted experiment rather than a
/// board route, and gets the automatic fine-grid promotion (see
/// `effectiveGridScale`) plus the larger per-leg expansion budget.
pub const fine_selection_max_nets: usize = 2;
pub const max_targeted_expansions: usize = 50_000;
pub const max_batch_expansions: usize = 10_000;
pub const max_pair_corridor_expansions: usize = 2_000;

/// Which class's geometry sizes the whole-board lattice pitch.
///
/// This is a routability/cost trade, not a correctness one — per-net halos are
/// exact under both (see the module header).
pub const Mode = enum {
    /// The historical lattice: pitch from the WIDEST class on the board, so
    /// two adjacent occupied grid lines clear even the fattest pair. Every
    /// narrower class rasters coarser than it needs.
    widest,
    /// Pitch from the NARROWEST net's own width + clearance, so no class is
    /// rastered coarser than it needs. Capped by the node budget, and never
    /// coarser than `widest` would have been.
    narrowest,
};

/// How many nets a selection mask enables. An EMPTY mask means "every net",
/// which is the whole-board route, and reports 0 — callers read 0 as "not a
/// scoped selection", so the distinction is load-bearing.
pub fn selectedCount(selected_nets: []const bool) usize {
    var count: usize = 0;
    for (selected_nets) |selected| if (selected) {
        count += 1;
    };
    return count;
}

/// The widest geometry any net on this board can use — grid pitch and the
/// pad-index prefilter are sized to this so two adjacent occupied grid lines
/// satisfy clearance even between the widest pair of classes. Boards with no
/// `(net-class …)` forms return `base` unchanged (identical legacy grid).
pub fn maxRouteParams(
    placement: optimizer.Placement,
    base: router.RouteParams,
    selected_nets: []const bool,
) router.RouteParams {
    var p = base;
    for (placement.rules.net, 0..) |r, i| {
        if (selected_nets.len > 0 and (i >= selected_nets.len or !selected_nets[i])) continue;
        if (r.width > p.track_width) p.track_width = r.width;
        if (r.clearance > p.clearance) p.clearance = r.clearance;
        if (r.via_dia > p.via_dia) p.via_dia = r.via_dia;
    }
    return p;
}

fn adaptiveSearchWidth(
    placement: optimizer.Placement,
    base: router.RouteParams,
    net_i: usize,
    authored: f64,
) f64 {
    if (net_i >= placement.nets.len) return authored;
    const name = placement.nets[net_i].name;
    if (placement.rules.powerWidthForNet(name) == null or router.netHasPlane(placement, name)) return authored;
    if (net_i < placement.rules.net.len) {
        const rule = placement.rules.net[net_i];
        if (rule.rf.impedance.ohms > 0 or rule.rf.impedance.diff_ohms > 0) return authored;
    }
    for (placement.diff_pairs) |pair| if (pair.p == net_i or pair.n == net_i) return authored;
    return @max(placement.rules.design.min_width, @min(authored, base.track_width));
}

fn maxSearchParams(
    placement: optimizer.Placement,
    base: router.RouteParams,
    selected_nets: []const bool,
) router.RouteParams {
    var p = base;
    for (placement.rules.net, 0..) |rule, i| {
        if (selected_nets.len > 0 and (i >= selected_nets.len or !selected_nets[i])) continue;
        const authored = if (rule.width > 0) rule.width else base.track_width;
        p.track_width = @max(p.track_width, adaptiveSearchWidth(placement, base, i, authored));
        if (rule.clearance > p.clearance) p.clearance = rule.clearance;
        if (rule.via_dia > p.via_dia) p.via_dia = rule.via_dia;
    }
    return p;
}

/// The finest lattice pitch any ENABLED net on this board actually needs — the
/// minimum over each net's own effective `width + clearance`.
///
/// A net with no `(net-class …)` geometry contributes the board defaults, so a
/// board with no classes at all returns exactly `base.track_width +
/// base.clearance` — the same number `maxRouteParams` yields there. That
/// equality is what makes `Mode.narrowest` a provable no-op on a single-pitch
/// board: the two modes compute the same pitch, so the same lattice, so the
/// same copper.
pub fn narrowestPitch(
    placement: optimizer.Placement,
    base: router.RouteParams,
    selected_nets: []const bool,
) f64 {
    var best = base.track_width + base.clearance;
    for (placement.rules.net, 0..) |r, i| {
        if (selected_nets.len > 0 and (i >= selected_nets.len or !selected_nets[i])) continue;
        const authored = if (r.width > 0) r.width else base.track_width;
        const w = adaptiveSearchWidth(placement, base, i, authored);
        const c = if (r.clearance > 0) r.clearance else base.clearance;
        if (w + c < best) best = w + c;
    }
    return best;
}

/// The routing lattice one resolution scale yields: pitch from the selection's
/// widest class, node counts spanning the placement plus the raster apron.
/// Factored out of `buildRouteCtx` so `fittedGridScale` can size candidate
/// scales with the identical math (the two MUST stay in lockstep).
pub const GridDims = struct { g: f64, nx: usize, ny: usize };

/// Node counts a pitch yields over the given spans. The one place the
/// `ceil(span/g) + 1` sizing is written, so every budget check and the real
/// allocation agree by construction.
fn dimsAt(g: f64, span_x: f64, span_y: f64) GridDims {
    return .{
        .g = g,
        .nx = numeric.toCount(@ceil(span_x / g) + 1),
        .ny = numeric.toCount(@ceil(span_y / g) + 1),
    };
}

/// True when a pitch's lattice fits the per-signal-layer node budget.
fn fitsBudget(g: f64, span_x: f64, span_y: f64) bool {
    const d = dimsAt(g, span_x, span_y);
    return d.nx * d.ny <= max_nodes;
}

/// Bisection steps used to find the finest affordable pitch. Fixed (not a
/// tolerance loop) so the answer is a pure function of the inputs and two
/// identical runs bisect identically — the router's determinism contract.
const pitch_bisect_steps: usize = 40;

/// The finest pitch in `[want, coarse]` whose lattice still fits `max_nodes`.
///
/// Node count is monotone non-increasing in pitch, so the predicate "fits" is
/// monotone and a fixed-step bisection lands on the boundary deterministically.
/// Returns `coarse` when even `want` is unnecessary (`want >= coarse`) or when
/// nothing finer than `coarse` fits — a board that cannot afford a finer raster
/// keeps exactly the lattice it has today rather than overflowing.
fn finestAffordable(want: f64, coarse: f64, span_x: f64, span_y: f64) f64 {
    if (want >= coarse) return coarse;
    if (fitsBudget(want, span_x, span_y)) return want;
    if (!fitsBudget(coarse, span_x, span_y)) return coarse;
    var lo = want; // known not to fit
    var hi = coarse; // known to fit
    var step: usize = 0;
    while (step < pitch_bisect_steps) : (step += 1) {
        const mid = (lo + hi) / 2;
        if (fitsBudget(mid, span_x, span_y)) hi = mid else lo = mid;
    }
    return hi;
}

/// The pitch a whole-board route searches at, before the node budget is
/// applied: the widest class's track width plus the larger of its clearance
/// and the selection's diff-pair gap.
fn widestPitch(
    placement: optimizer.Placement,
    params: router.RouteParams,
    selected_nets: []const bool,
    resolution_scale: f64,
) f64 {
    const maxp = maxSearchParams(placement, params, selected_nets);
    // A one-net experiment has no second fresh route that can occupy an
    // adjacent grid line. Search it at the base pitch while preserving maxp's
    // true width/clearance in obstacle halos and edge inset. This removes the
    // coarse-grid lottery for wide RF traces without weakening DRC spacing.
    const gridp = if (selectedCount(selected_nets) == 1) params else maxp;
    const grid_gap = @max(gridp.clearance, selectedDiffPairGap(placement, selected_nets));
    return @max((gridp.track_width + grid_gap) * resolution_scale, min_pitch_mm);
}

/// The lattice `buildRouteCtx` will allocate, under the board's own
/// `rules.lattice` mode.
///
/// `Mode.widest` is the historical path, unchanged. `Mode.narrowest` asks for
/// the finest pitch the board's own classes need and then takes the finest
/// AFFORDABLE one, so it can only ever equal or refine the `widest` lattice —
/// never coarsen it, and never overflow a board that routes today.
pub fn routeGridDims(
    placement: optimizer.Placement,
    params: router.RouteParams,
    selected_nets: []const bool,
    resolution_scale: f64,
) GridDims {
    const mode = placement.rules.lattice;
    const coarse = widestPitch(placement, params, selected_nets, resolution_scale);
    const span_x = placement.maxx - placement.minx + 2 * apron_mm;
    const span_y = placement.maxy - placement.miny + 2 * apron_mm;
    const g = switch (mode) {
        .widest => coarse,
        .narrowest => finestAffordable(
            @max(narrowestPitch(placement, params, selected_nets) * resolution_scale, min_pitch_mm),
            coarse,
            span_x,
            span_y,
        ),
    };
    return dimsAt(g, span_x, span_y);
}

/// The automatic fine-grid promotion a SCOPED selection gets: a 1-net reroute
/// searches at half pitch and a 2-net one at quarter pitch, because a targeted
/// experiment can afford the nodes and usually exists precisely because the
/// board pitch could not express the path. A whole-board or >2-net route stays
/// at 1.0. An explicit `requested` scale always wins.
pub fn effectiveGridScale(selected_nets: []const bool, requested: f64) f64 {
    const count = selectedCount(selected_nets);
    if (count == 0 or count > fine_selection_max_nets) return 1;
    if (requested > 0) return std.math.clamp(requested, 0.1, 1.0);
    return if (count == 2) 0.25 else 0.5;
}

/// The resolution scale a run actually searches at: `effectiveGridScale`'s
/// fine-selection promotion, dropped back to the base pitch when the promoted
/// lattice would overflow `max_nodes`. Without the fallback a 1–2-net scoped
/// route on a large board auto-promoted onto an over-budget grid,
/// `buildRouteCtx` overflowed, and the run degenerated to routing NOTHING —
/// on a board whose whole-board grid routes fine. The fallback goes straight
/// to the base pitch, not to the next finer rung that fits: search cost is
/// nodes × expansion budget, and on barracuda the half-pitch rung that still
/// fits takes ~140 s where the base grid routes the same two nets in under a
/// second — the windowed fine rescues supply sub-pitch resolution for
/// residual failures at bounded cost. An EXPLICIT `requested` scale is
/// honoured as asked (its overflow surfaces via `grid_overflow`, and
/// `routeWithCapture`'s fine retry relies on that to stay cheap); only the
/// automatic promotion is gated.
pub fn fittedGridScale(
    placement: optimizer.Placement,
    params: router.RouteParams,
    selected_nets: []const bool,
    requested: f64,
) f64 {
    const scale = effectiveGridScale(selected_nets, requested);
    if (requested > 0 or scale >= 1) return scale;
    const dims = routeGridDims(placement, params, selected_nets, scale);
    return if (dims.nx * dims.ny > max_nodes) 1 else scale;
}

/// The declared gap of the diff pair a 2-net selection isolates, or 0 when the
/// selection is not exactly one pair. The lattice must be able to hold both
/// legs of a pair at their coupled gap, which can exceed the class clearance.
pub fn selectedDiffPairGap(placement: optimizer.Placement, selected_nets: []const bool) f64 {
    if (selectedCount(selected_nets) != 2) return 0;
    for (placement.diff_pairs) |pair| {
        if (pair.p >= selected_nets.len or pair.n >= selected_nets.len) continue;
        if (selected_nets[pair.p] and selected_nets[pair.n]) return pair.gap;
    }
    return 0;
}

/// One maze leg's A* priority term: the straight-line distance from a node to
/// the goal REGION's bounding box, discounted by `scale`.
///
/// A box rather than a point because a leg's goals are a pad's whole gateway fan
/// (`router.padGateways`), not one node — an estimate aimed at any single member
/// would over-state the distance to the others and stop being admissible. Inside
/// the box it is zero, which is also what lets the search stop the moment the
/// best `dist + escape stub` it holds can no longer be beaten: every goal sits
/// in the box, so a goal's priority IS its cost paid.
///
/// `scale` must be the SMALLEST multiplier any step of the leg can be discounted
/// by, or the estimate can exceed the true remaining cost and the path found
/// stops being the cheapest one.
pub const Heuristic = struct {
    active: bool = false,
    scale: f64 = 1,
    min_x: f64 = 0,
    min_y: f64 = 0,
    max_x: f64 = 0,
    max_y: f64 = 0,

    /// The estimate for `node`, or 0 for a leg with no goals to aim at.
    pub fn estimate(self: Heuristic, grid: Grid, node: usize) f64 {
        if (!self.active) return 0;
        const x = grid.worldX(node % grid.nx);
        const y = grid.worldY(node / grid.nx);
        const dx = @max(@max(self.min_x - x, x - self.max_x), 0);
        const dy = @max(@max(self.min_y - y, y - self.max_y), 0);
        return std.math.hypot(dx, dy) * self.scale;
    }
};

/// Build the `Heuristic` bounding `goals` (full `layer*nodes + node` keys).
pub fn heuristic(grid: Grid, goals: []const usize, nodes: usize, scale: f64) Heuristic {
    if (goals.len == 0) return .{};
    var out = Heuristic{
        .active = true,
        .scale = scale,
        .min_x = std.math.inf(f64),
        .min_y = std.math.inf(f64),
        .max_x = -std.math.inf(f64),
        .max_y = -std.math.inf(f64),
    };
    for (goals) |goal| {
        const target = goal % nodes;
        const x = grid.worldX(target % grid.nx);
        const y = grid.worldY(target / grid.nx);
        out.min_x = @min(out.min_x, x);
        out.min_y = @min(out.min_y, y);
        out.max_x = @max(out.max_x, x);
        out.max_y = @max(out.max_y, y);
    }
    return out;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A placement spanning `w` x `h` mm with `net_rules`, rastered under `mode` —
/// enough for the pitch math, which reads only the bounding box, the per-net
/// rules and the lattice mode.
fn pitchFixture(
    w: f64,
    h: f64,
    net_rules: []const optimizer.NetRule,
    mode: Mode,
) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = w,
        .maxy = h,
        .generated = true,
        .rules = .{ .net = net_rules, .lattice = mode },
    };
}

/// Both modes' lattices for one board shape + class set, so a test can compare
/// them without repeating the fixture.
const BothModes = struct { widest: GridDims, narrowest: GridDims };

fn bothModes(w: f64, h: f64, net_rules: []const optimizer.NetRule) BothModes {
    return .{
        .widest = routeGridDims(pitchFixture(w, h, net_rules, .widest), .{}, &.{}, 1),
        .narrowest = routeGridDims(pitchFixture(w, h, net_rules, .narrowest), .{}, &.{}, 1),
    };
}

/// The RF/control spread that motivates the whole mode: barracuda's 0.3124 mm
/// RF class (pitch 0.4394) beside the 0.127 mm board default (pitch 0.254).
const mixed_class_rules = [_]optimizer.NetRule{
    .{ .width = 0.3124, .clearance = 0.127 },
    .{},
};

/// A class far finer than any board-spanning lattice can afford, for the
/// node-budget fallback.
const unaffordable_rules = [_]optimizer.NetRule{
    .{ .width = 0.025, .clearance = 0.025 },
    .{},
};

// spec: placement/class-pitch - a board whose nets all resolve to one pitch rasters identically under either lattice mode
test "a single-pitch board yields the identical lattice under both modes" {
    const both = bothModes(40, 30, &.{});
    try testing.expectEqual(both.widest.g, both.narrowest.g);
    try testing.expectEqual(both.widest.nx, both.narrowest.nx);
    try testing.expectEqual(both.widest.ny, both.narrowest.ny);
}

// spec: placement/class-pitch - the narrowest mode rasters a mixed-class board at the finest class's own pitch, not the widest
test "a mixed-class board rasters finer under the narrowest mode" {
    const both = bothModes(40, 30, &mixed_class_rules);
    try testing.expectApproxEqAbs(@as(f64, 0.4394), both.widest.g, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.254), both.narrowest.g, 1e-9);
    try testing.expect(both.narrowest.nx > both.widest.nx);
    try testing.expect(both.narrowest.ny > both.widest.ny);
}

// spec: placement/class-pitch - a wide current-rated power class keeps the ordinary centreline lattice because its electrical width is added after routing
test "adaptive power class keeps the ordinary search lattice" {
    const rules = [_]optimizer.NetRule{.{ .width = 0.8, .clearance = 0.127 }};
    const nets = [_]optimizer.FlatNet{.{ .name = "VDD", .pins = &.{} }};
    const rails = [_]@import("../eval/power_budget.zig").Rail{.{
        .net = "VDD",
        .load_max_a = 1.2,
        .any_max_load = true,
        .status = .no_source,
    }};
    var placement = pitchFixture(40, 30, &rules, .widest);
    placement.nets = &nets;
    placement.rules.physical = .{ .stack = .{ .layers = 2 }, .rails = &rails };
    try testing.expectApproxEqAbs(@as(f64, 0.254), routeGridDims(placement, .{}, &.{}, 1).g, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.8), maxRouteParams(placement, .{}, &.{}).track_width, 1e-9);
}

// spec: placement/class-pitch - the narrowest lattice is never coarser than the widest-class lattice it replaces
test "the narrowest mode never coarsens the lattice" {
    // A class WIDER than the default cannot pull the pitch up; a class NARROWER
    // than the default pulls it down. Either way it never exceeds `widest`.
    const narrow = [_]optimizer.NetRule{.{ .width = 0.05, .clearance = 0.05 }};
    const both = bothModes(40, 30, &narrow);
    try testing.expect(both.narrowest.g <= both.widest.g);
    try testing.expectApproxEqAbs(@as(f64, 0.1), both.narrowest.g, 1e-9);
    const wide = bothModes(40, 30, &mixed_class_rules);
    try testing.expect(wide.narrowest.g <= wide.widest.g);
}

// spec: placement/class-pitch - a finer class pitch that would overflow the node budget falls back to the finest lattice that fits, never to an overflow
test "an unaffordable fine pitch falls back to a lattice that fits" {
    // 100 x 100 mm fits at the 0.254 mm default pitch (~162 k nodes) but not at
    // the 0.05 mm class pitch (~4.2 M). The fallback lands between the two:
    // finer than today's lattice, and inside the budget.
    const both = bothModes(100, 100, &unaffordable_rules);
    try testing.expect(both.widest.nx * both.widest.ny <= max_nodes);
    try testing.expect(both.narrowest.nx * both.narrowest.ny <= max_nodes);
    try testing.expect(both.narrowest.g > 0.05);
    try testing.expect(both.narrowest.g < both.widest.g);
}

// spec: placement/class-pitch - a board that cannot afford even its widest-class lattice keeps that lattice rather than being refined into a deeper overflow
test "an already-overflowing board is not refined further" {
    const both = bothModes(4000, 4000, &.{});
    try testing.expect(both.widest.nx * both.widest.ny > max_nodes);
    try testing.expectEqual(both.widest.g, both.narrowest.g);
}

// spec: placement/class-pitch - the finest-affordable pitch search is deterministic across identical calls
test "the affordable-pitch search is deterministic" {
    const a = bothModes(100, 100, &unaffordable_rules);
    const b = bothModes(100, 100, &unaffordable_rules);
    try testing.expectEqual(a.narrowest.g, b.narrowest.g);
    try testing.expectEqual(a.narrowest.nx, b.narrowest.nx);
    try testing.expectEqual(a.narrowest.ny, b.narrowest.ny);
}

// spec: placement/class-pitch - the narrowest pitch of a board with no net classes is the board default geometry
test "a class-free board's narrowest pitch is the board default" {
    const placement = pitchFixture(10, 10, &.{}, .narrowest);
    try testing.expectApproxEqAbs(@as(f64, 0.254), narrowestPitch(placement, .{}, &.{}), 1e-9);
}

// spec: placement/class-pitch - a net class narrower than the board default lowers the board's narrowest pitch
test "a narrow class lowers the narrowest pitch" {
    const rules = [_]optimizer.NetRule{.{ .width = 0.08, .clearance = 0.08 }};
    const placement = pitchFixture(10, 10, &rules, .narrowest);
    try testing.expectApproxEqAbs(@as(f64, 0.16), narrowestPitch(placement, .{}, &.{}), 1e-9);
}

// spec: placement/class-pitch - a selection mask confines the narrowest-pitch scan to the enabled nets
test "the narrowest pitch scan honours the selection mask" {
    const rules = [_]optimizer.NetRule{
        .{ .width = 0.08, .clearance = 0.08 },
        .{ .width = 0.3, .clearance = 0.2 },
    };
    const placement = pitchFixture(10, 10, &rules, .narrowest);
    const only_wide = [_]bool{ false, true };
    try testing.expectApproxEqAbs(
        @as(f64, 0.254),
        narrowestPitch(placement, .{}, &only_wide),
        1e-9,
    );
}

// ── End-to-end lattice fixtures ─────────────────────────────────────────────
//
// The unit tests above prove the PITCH decision. These two prove what the
// pitch is for: that a single-pitch board's copper is untouched by the mode,
// and that a mixed-class board's fine net can reach a corridor its coarse
// lattice cannot put a centerline in.

const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");

/// Compare two full route outputs copper-for-copper. All loops live HERE so a
/// test body stays linear (Guardian's `test-no-conditional` rule).
fn expectCopperIdentical(a: router.RouteResult, b: router.RouteResult) !void {
    try testing.expectEqual(a.routed, b.routed);
    try testing.expectEqual(a.total, b.total);
    try testing.expectEqual(a.tracks.len, b.tracks.len);
    try testing.expectEqual(a.vias.len, b.vias.len);
    for (a.tracks, b.tracks) |x, y| {
        try testing.expectApproxEqAbs(x.x1, y.x1, 1e-9);
        try testing.expectApproxEqAbs(x.y1, y.y1, 1e-9);
        try testing.expectApproxEqAbs(x.x2, y.x2, 1e-9);
        try testing.expectApproxEqAbs(x.y2, y.y2, 1e-9);
        try testing.expectEqual(x.layer, y.layer);
        try testing.expectApproxEqAbs(x.width, y.width, 1e-9);
        try testing.expectEqual(x.net, y.net);
    }
    for (a.vias, b.vias) |x, y| {
        try testing.expectApproxEqAbs(x.x, y.x, 1e-9);
        try testing.expectApproxEqAbs(x.y, y.y, 1e-9);
        try testing.expectApproxEqAbs(x.dia, y.dia, 1e-9);
        try testing.expectEqual(x.net, y.net);
    }
}

const one_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};

fn bottomAt(ref: []const u8, x: f64, y: f64) optimizer.Part {
    var p = passiveAt(ref, x, y);
    p.side = .bottom;
    return p;
}

fn passiveAt(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &one_pad,
        .fallback = false,
        .x = x,
        .y = y,
    };
}

// spec: placement/class-pitch - a board with no net classes lays byte-identical copper under either lattice mode
test "a class-free board routes byte-identically under both lattice modes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Same shape as the determinism fixture: a same-layer hop, a cross-face
    // pair that must take vias, and a 4-terminal tree — so "identical" covers
    // the maze, the direct synthesis and the finisher, not one easy net.
    var parts = [_]optimizer.Part{
        passiveAt("R1", 0, 0),
        passiveAt("R2", 4, 1.5),
        bottomAt("R3", 3, 0),
        bottomAt("R4", 7, 0),
        passiveAt("R5", 1, 3.5),
        passiveAt("R6", 5.5, 3.9),
        bottomAt("R7", 2.5, 5.5),
        passiveAt("R8", 8, 5.0),
    };
    const pins_sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const pins_x = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const pins_tree = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R5", .pin = "1" },
        .{ .ref_des = "R6", .pin = "1" },
        .{ .ref_des = "R7", .pin = "1" },
        .{ .ref_des = "R8", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SIG", .pins = &pins_sig },
        .{ .name = "X", .pins = &pins_x },
        .{ .name = "TREE", .pins = &pins_tree },
    };
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
        .maxx = 9,
        .maxy = 6,
        .generated = true,
    };
    const wide = try router.route(arena, placement, .{});
    placement.rules.lattice = .narrowest;
    const narrow = try router.route(arena, placement, .{});
    try expectCopperIdentical(wide, narrow);
    // Non-vacuity: the fixture really routes and really takes vias, so
    // "identical" is a claim about copper rather than about two empty results.
    try testing.expect(wide.routed >= 1);
    try testing.expect(wide.vias.len >= 1);
    try testing.expect(wide.tracks.len > 5);
}

/// A through-plated wall at x = 3 with ONE 0.22 mm slot centred on y = 1.4167 —
/// the midpoint between two adjacent coarse-lattice rows (1.1970 and 1.6364 at
/// the 0.4394 mm RF pitch, origin y = -1). The slot admits a 0.05 mm net
/// (which needs 0.075 mm of clearance either side, so its centreline band is
/// y in [1.3817, 1.4517]) and no coarse row lands in that band, while the
/// 0.1 mm narrow-class lattice puts a row at exactly y = 1.4.
const wall_pads = [_]geometry.Pad{
    .{ .number = "1", .x = 0, .y = -1.2, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "2", .x = 0, .y = -0.8, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "3", .x = 0, .y = -0.4, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "4", .x = 0, .y = 0.0, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "5", .x = 0, .y = 0.4, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "6", .x = 0, .y = 0.8, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "7", .x = 0, .y = 1.1067, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "8", .x = 0, .y = 1.7267, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "9", .x = 0, .y = 2.1, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "10", .x = 0, .y = 2.5, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "11", .x = 0, .y = 2.9, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "12", .x = 0, .y = 3.3, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "13", .x = 0, .y = 3.7, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "14", .x = 0, .y = 4.1, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "15", .x = 0, .y = 4.5, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "16", .x = 0, .y = 4.9, .w = 0.4, .h = 0.4, .thru = true },
    .{ .number = "17", .x = 0, .y = 5.3, .w = 0.4, .h = 0.4, .thru = true },
};

/// The slotted-wall board: a wide RF class sets the coarse pitch, and the
/// 0.05 mm `SIG` net must cross the wall through the slot. `SIG`'s terminals
/// sit level with each other ABOVE the slot, so no straight line or single
/// dogleg reaches it — the maze has to descend to the slot row, which is the
/// row only the fine lattice has.
const slotted_wall_rules = [_]optimizer.NetRule{
    .{ .width = 0.3124, .clearance = 0.127 },
    .{ .width = 0.05, .clearance = 0.05 },
};

fn slottedWallPlacement(mode: Mode, parts: []optimizer.Part, nets: []const flat_netlist.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 6,
        .maxy = 4,
        .generated = true,
        .rules = .{ .net = &slotted_wall_rules, .lattice = mode },
    };
}

// spec: placement/class-pitch - a fine-class net whose only corridor is narrower than the widest class's pitch routes on the narrowest lattice and fails on the widest
test "a fine net crosses a slot the coarse lattice cannot represent" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "W1", .kind = .passive, .hw = 0.3, .hh = 3.5, .pads = &wall_pads, .fallback = false, .x = 3, .y = 0 },
        passiveAt("R1", 1.2, 3.5),
        passiveAt("R2", 4.8, 3.5),
        passiveAt("R3", 0.5, 0.5),
        passiveAt("R4", 1.5, 0.5),
    };
    const pins_rf = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const pins_sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &pins_rf },
        .{ .name = "SIG", .pins = &pins_sig },
    };

    // `one_shot` isolates the PRIMARY maze: no rip-up, no escalation and no
    // fine-window rescue, so what this measures is which corridors the board's
    // own lattice can express — the exact thing the mode changes.
    const coarse = try router.routeWithOptions(
        arena,
        slottedWallPlacement(.widest, &parts, &nets),
        .{},
        .{ .effort = .one_shot },
    );
    const fine = try router.routeWithOptions(
        arena,
        slottedWallPlacement(.narrowest, &parts, &nets),
        .{},
        .{ .effort = .one_shot },
    );
    // Both boards route the RF pair (it never crosses the wall); only the fine
    // lattice also closes SIG through the slot.
    try testing.expectEqual(@as(usize, 2), coarse.total);
    try testing.expectEqual(@as(usize, 2), fine.total);
    try testing.expectEqual(@as(usize, 1), coarse.routed);
    try testing.expectEqual(@as(usize, 2), fine.routed);
}

// spec: placement/class-pitch - routing a board twice on the narrowest lattice is byte-identical
test "the narrowest lattice routes deterministically" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "W1", .kind = .passive, .hw = 0.3, .hh = 3.5, .pads = &wall_pads, .fallback = false, .x = 3, .y = 0 },
        passiveAt("R1", 1.2, 3.5),
        passiveAt("R2", 4.8, 3.5),
        passiveAt("R3", 0.5, 0.5),
        passiveAt("R4", 1.5, 0.5),
    };
    const pins_rf = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const pins_sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &pins_rf },
        .{ .name = "SIG", .pins = &pins_sig },
    };
    // The refined lattice's pitch comes from a bisection, so "same board twice"
    // has to hold through that search as well as through the maze.
    const placement = slottedWallPlacement(.narrowest, &parts, &nets);
    const run1 = try router.route(arena, placement, .{});
    const run2 = try router.route(arena, placement, .{});
    try expectCopperIdentical(run1, run2);
    try testing.expectEqual(@as(usize, 2), run1.routed);
    try testing.expect(run1.tracks.len > 5);
}
