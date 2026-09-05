//! The RF **crossing shadow** — a soft, all-layer routing cost that keeps foreign
//! copper from running ALONGSIDE a protected RF trace on another layer.
//!
//! `keepout.zig`'s halo is deliberately same-layer only: the board is the shield,
//! so a foreign net crossing UNDER an RF trace on the far copper is legal by
//! design. That is the right rule for a crossing and the wrong one for a
//! *parallel run*: a control track that dives to the bottom layer and then
//! follows the RF trace for 8 mm sits in the fence corridor for its whole length,
//! and every through-hole fence via site along that stretch is now unbuildable —
//! the shield the author asked for cannot be built where the trace needs it most.
//!
//! So the copper of every net whose class declares a `(fence …)`, carries a
//! `(max-freq …)` fence target, or declares a `(keepout MM)` casts a SHADOW on
//! **all** signal layers: its own footprint
//! dilated outward from the copper edge by the fence-corridor width — the outer
//! extent where a fence via barrel lands. Steps whose destination node is
//! shadowed pay `step_mult`; a via dropped on a node shadowed on ANY layer pays
//! `via_mult`, which is deliberately harder because a foreign barrel parked in
//! the corridor blocks that fence site permanently rather than in passing.
//!
//! Three properties make this the right shape:
//!
//!   * **Soft, never blocking.** A foreign net that genuinely must cross does
//!     cross; it just pays, so the search buys the SHORTEST crossing it can —
//!     which is the perpendicular one, ~one corridor width of shadowed nodes.
//!     A parallel run costs a multiple of that and dies on cost alone. Nothing
//!     here can make a net unroutable, so the shadow cannot cost completion the
//!     way a hard mask would. The one place that softness is not available is
//!     the direct/dogleg/octilinear SYNTHESIS, which emits a segment whole or
//!     not at all and so can only refuse (`State.runsAlong`) — which makes the
//!     angle it refuses at load-bearing, and mis-set it did cost completion.
//!   * **Owner-exempt.** The net casting the shadow routes through its own (its
//!     later legs must be able to follow the same corridor), and ground/plane
//!     copper is exempt for the same reason it is exempt from the halo — GND
//!     under an RF trace IS the shield (`keepout.exempt`).
//!   * **Cost only.** There is no DRC counterpart and no new violation kind: a
//!     parallel run underneath is a routing-quality problem, not a fab defect,
//!     and the fence generator already reports the sites it had to skip.
//!
//! Lifetime mirrors the keepout halo lane exactly (see `router.KeepState`): the
//! lanes are allocated ONLY on the whole-board route context, and every derived
//! context (windowed fine retry, gap pass, `router.visionMask`) drops them, so a
//! window rescue routes on the ordinary cost model. That is a deliberate gap, not
//! an oversight — a rescue is already the last thing standing between a net and
//! failure, and there is nothing to re-stamp a window-local lane from.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const disc_stamp = @import("disc_stamp.zig");
const pad_shape = @import("pad_shape.zig");
const numeric = @import("../numeric.zig");

/// Unclaimed sentinel, the same encoding the occupancy / reservation / keepout
/// lanes use (`router`'s private `empty_cell`) so one grid convention serves all.
const empty: i32 = -1;

/// Cost multiplier a step landing on a shadowed node pays. Sized against the
/// router's other soft weights (`via_cost_mult` 4.0, `escape_pen_mult` 4.0): it
/// must dominate the small detour that leaves a corridor — a few grid steps —
/// without being so large that a net which must cross routes three layers away
/// to avoid it.
pub const step_mult: f64 = 6.0;

/// Cost multiplier a LAYER CHANGE onto a shadowed node pays. Twice `step_mult`:
/// a transiting track leaves the corridor again, a via barrel never does, and a
/// barrel in the corridor kills the fence site it stands on for good.
pub const via_mult: f64 = 12.0;

/// Fabrication margin a DERIVED fence gap adds over the class clearance.
/// Mirrors `via_fence.offset_margin_mm` — see `corridorMm` for why the two
/// formulas are replicated here rather than imported.
const fence_margin_mm: f64 = 0.1;
/// Mirrors the wavelength defaults in `via_fence.zig`; kept local because this
/// router-side module cannot import the post-route fence generator.
const c_mm_per_s: f64 = 299792458000;
const assumed_er: f64 = 4.4;
const pitch_wavelength_divisor: f64 = 10;

/// The per-run shadow state the router carries. Inert by default: with no lanes
/// every query short-circuits on a length and the cost model is byte-identical to
/// a board that declares no RF class at all.
pub const State = struct {
    /// Per-net corridor width (mm), net-indexed. Empty ⇒ no net on this board
    /// declares a fence or a keepout — the early-out every path takes first.
    nets: []const f64 = &.{},
    /// Per-signal-layer shadow ownership: the net whose corridor claims this
    /// node, else `empty`. Owner ids rather than a bitset, so a net routes
    /// through its own shadow. Allocated only on the whole-board route context.
    layers: []const []i32 = &.{},
    /// The CURRENT net's own corridor width (mm), 0 when it declares none —
    /// what the emitters stamp as they lay copper.
    width: f64 = 0,

    /// Is node `n` on `layer` inside a FOREIGN net's shadow?
    pub fn at(self: State, layer: usize, n: usize, net: i32) bool {
        if (layer >= self.layers.len) return false;
        const lane = self.layers[layer];
        if (n >= lane.len) return false;
        return lane[n] != empty and lane[n] != net;
    }

    /// Is node `n` inside a foreign shadow on ANY signal layer — the question a
    /// through-via has to ask, since its barrel occupies them all.
    pub fn anyLayer(self: State, n: usize, net: i32) bool {
        for (0..self.layers.len) |layer| {
            if (self.at(layer, n, net)) return true;
        }
        return false;
    }

    /// The cost multiplier a move onto `(layer, n)` pays: 1.0 outside every
    /// foreign shadow, `step_mult` for a same-layer step into one, `via_mult`
    /// for a layer change onto a node shadowed anywhere. `exempt` (ground /
    /// plane copper) always pays 1.0.
    pub fn multiplier(self: State, layer: usize, n: usize, net: i32, via_move: bool, exempt: bool) f64 {
        if (self.layers.len == 0 or exempt) return 1.0;
        if (via_move) return if (self.anyLayer(n, net)) via_mult else 1.0;
        return if (self.at(layer, n, net)) step_mult else 1.0;
    }

    /// Drop every node this net's copper shadowed — the counterpart of ripping
    /// its copper up, so a removed trace leaves no phantom corridor behind.
    pub fn clearNet(self: State, net: i32) void {
        for (self.layers) |lane| {
            for (lane) |*c| {
                if (c.* == net) c.* = empty;
            }
        }
    }

    /// Claim every free node within `dist` of `(x, y)` on `layer` for `net`'s
    /// shadow. First writer owns the node: where two RF corridors overlap the
    /// second net reads the cell as foreign, which is the safe direction (it
    /// pays), and each net still routes freely through the part it owns.
    pub fn disc(self: State, grid: router.Grid, layer: usize, at_pt: [2]f64, dist: f64, net: i32) void {
        if (layer >= self.layers.len or !(dist > 0)) return;
        disc_stamp.claimFree(grid, self.layers[layer], at_pt, dist, net);
    }

    /// Stamp `net`'s corridor along the segment a→b on EVERY signal layer — the
    /// whole point of the rule is that the far side of the board is shadowed too.
    /// `half` is the copper's own half-extent (a track half-width or a via
    /// radius), so `half + width` measures the corridor from the copper EDGE.
    /// Sampled at half-grid steps, like every other halo writer.
    pub fn stampSeg(self: State, grid: router.Grid, a: [2]f64, b: [2]f64, half: f64, net: i32) void {
        if (self.layers.len == 0 or !(self.width > 0)) return;
        const dist = half + self.width;
        const steps = disc_stamp.segSteps(grid, a, b);
        for (0..self.layers.len) |layer| {
            for (0..steps + 1) |step| {
                const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
                self.disc(grid, layer, .{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) }, dist, net);
            }
        }
    }

    /// Stamp a via's corridor on every signal layer (its barrel is on all of
    /// them anyway).
    pub fn stampVia(self: State, grid: router.Grid, x: f64, y: f64, half: f64, net: i32) void {
        if (self.layers.len == 0 or !(self.width > 0)) return;
        for (0..self.layers.len) |layer| {
            self.disc(grid, layer, .{ x, y }, half + self.width, net);
        }
    }

    /// Does the segment `seg` RUN ALONG a foreign corridor rather than cross it?
    /// `half` is the segment's own half-width, so the band is measured edge to
    /// edge like every other shadow distance, and `exempt` (ground/plane copper)
    /// never runs along anything.
    ///
    /// Measured as the longest CONTIGUOUS span the segment spends inside one
    /// corridor's band, against that band's own thickness. A straight segment
    /// meeting a band of thickness `T` at angle θ spends exactly `T / sin θ`
    /// inside it, so the ratio run/T *is* `1 / sin θ` — a pure angle, free of the
    /// corridor width, the caster's track width and the probe's own. The segment
    /// is refused once that ratio passes `max_cross_ratio`, i.e. once it meets
    /// the corridor shallower than `min_cross_angle_deg`.
    ///
    /// Two properties this shape has and its predecessor did not:
    ///
    ///   * **The budget is the band actually traversed.** The old test budgeted
    ///     four times the CORRIDOR width, but the band a crossing must get
    ///     through is `2 · (corridor + caster half-width + probe half-width)`,
    ///     which is wider. On board-a's fenced RF class (0.627 corridor,
    ///     0.3124 caster, 0.2532 probe) that band is 1.82 mm against a 2.51 mm
    ///     budget — so a 45° crossing, at 2.57 mm, was REFUSED. That is the
    ///     router's own lattice angle, and the exact case the old comment worked
    ///     through and concluded was "well under the budget"; the arithmetic
    ///     there silently took the band to be `2 · corridor`.
    ///   * **Contiguity.** The old accumulator summed in-band length over the
    ///     WHOLE segment while the divisor stayed one corridor width, so three
    ///     square crossings of three unrelated corridors added up to a refusal
    ///     though each was individually as cheap as a crossing gets. The rule
    ///     always read "spent inside ONE"; now it measures that.
    ///
    /// Both bit the COUPLED DIFF-PAIR construction hardest, because its legs are
    /// long runs between bends where the escape/dogleg synthesis emits short
    /// stubs: on a board declaring a fence, a declared pair fell back to two
    /// independent routes the moment a leg met the RF chain off-square.
    ///
    /// This is the shadow's half of the DIRECT/dogleg/octilinear synthesis, which
    /// never touches the maze cost model: a straight shortcut is emitted whole or
    /// not at all, so the only way to price it is to refuse it and let the maze —
    /// which does read the cost — find the crossing instead. Refusing a crossing
    /// the maze would merely price is therefore not a conservative choice but a
    /// contradiction between the two halves of one engine, and it costs the
    /// board: the synthesis has no cheaper crossing to fall back to, only a
    /// worse route or none.
    ///
    /// Measured against the shadow-casting COPPER rather than the stamped node
    /// lane, because a directly synthesized segment is off-lattice: the nearest
    /// node to a track running half a grid step outside the raster reads clear
    /// while the copper itself is squarely inside the corridor. Tracks only — a
    /// via's own corridor is a disc a segment crosses in one step, never a run.
    pub fn runsAlong(self: State, tracks: []const router.Track, seg: [2][2]f64, half: f64, net: i32) bool {
        if (self.nets.len == 0) return false;
        const a = seg[0];
        const b = seg[1];
        const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
        if (!(len > 0)) return false;
        var caster: [run_max_casters]u32 = undefined;
        var n: usize = 0;
        for (tracks, 0..) |t, i| {
            if (n == caster.len) break;
            if (t.net == net or !(widthAt(self.nets, t.net) > 0)) continue;
            if (!nearSegment(a, b, t, widthAt(self.nets, t.net) + t.width / 2 + half)) continue;
            caster[n] = @intCast(i);
            n += 1;
        }
        if (n == 0) return false;
        const steps: usize = @max(1, numeric.toCount(@ceil(len / run_sample_mm)));
        const per_step = len / @as(f64, @floatFromInt(steps));
        // The CURRENT contiguous in-band span, and the widest band it lies in.
        // Both reset the moment the segment leaves every corridor, so what is
        // measured is one crossing (or one run), never a sum over several.
        var run: f64 = 0;
        var band: f64 = 0;
        for (0..steps + 1) |i| {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const px = a[0] + t * (b[0] - a[0]);
            const py = a[1] + t * (b[1] - a[1]);
            var here: f64 = 0;
            for (caster[0..n]) |ci| {
                const k = tracks[ci];
                // The in-shadow set is the stadium within `reach` of the caster's
                // centreline, so a square crossing of it is `2 · reach` of copper
                // — that, not the bare corridor, is the length a crossing is
                // judged against.
                const reach = widthAt(self.nets, k.net) + k.width / 2 + half;
                if (pad_shape.segPointDist(k.x1, k.y1, k.x2, k.y2, px, py) <= reach) {
                    here = @max(here, 2 * reach);
                }
            }
            if (!(here > 0)) {
                run = 0;
                band = 0;
                continue;
            }
            run += per_step;
            band = @max(band, here);
            if (run > max_cross_ratio * band) return true;
        }
        return false;
    }
};

/// The shallowest angle at which a directly synthesized segment still counts as
/// CROSSING a protected corridor rather than running along it (see
/// `State.runsAlong`). Below it the segment is bounced to the maze, which prices
/// the same geometry softly instead of refusing it.
///
/// 30° leaves the router's own 45° lattice a wide margin — a 45° crossing spends
/// 1.41 band-lengths inside, against the 2.0 this allows — while still catching
/// the case the shadow exists for: the 8 mm parallel run one layer down, which
/// at board-a's 1.82 mm band is 4.4 band-lengths and refused twice over.
const min_cross_angle_deg: f64 = 30.0;

/// `1 / sin(min_cross_angle_deg)` — the in-band length multiple that angle
/// admits, which is what the sampler can compare against directly. Written out
/// rather than computed because `@sin` is not available in a comptime float
/// initialiser; a test below pins the two together so they cannot drift.
const max_cross_ratio: f64 = 2.0;

/// Sampling pitch (mm) along a candidate segment, and the cap on how many
/// shadow-casting tracks one test measures against. Both bound the work: the
/// test rides `router.segClearsTracks`, which the escape/dogleg search calls
/// hundreds of times per net. The cap can only ever UNDER-detect (a segment
/// running along the 33rd nearby RF trace is let through), which is the safe
/// direction — the maze still prices it if it ends up there.
const run_sample_mm: f64 = 0.05;
const run_max_casters: usize = 32;

/// Cheap AABB reject: could any point of a→b lie within `band` of track `t`?
fn nearSegment(a: [2]f64, b: [2]f64, t: router.Track, band: f64) bool {
    const tx0 = @min(t.x1, t.x2) - band;
    const tx1 = @max(t.x1, t.x2) + band;
    const ty0 = @min(t.y1, t.y2) - band;
    const ty1 = @max(t.y1, t.y2) + band;
    return @min(a[0], b[0]) <= tx1 and @max(a[0], b[0]) >= tx0 and
        @min(a[1], b[1]) <= ty1 and @max(a[1], b[1]) >= ty0;
}

/// Does any net on this board cast a shadow — i.e. declare a `(fence …)` or a
/// `(keepout MM)`? False ⇒ every shadow path is skipped and the lanes are never
/// allocated.
pub fn anyDeclared(placement: optimizer.Placement) bool {
    for (placement.rules.net) |r| {
        if (r.rf.fence.declared or r.rf.max_freq_hz > 0 or r.rf.keepout_mm > 0) return true;
    }
    return false;
}

/// Net `net_i`'s shadow corridor width (mm), measured from its copper edge
/// outward; 0 = this net casts no shadow.
///
/// A **fence-target** class's corridor reaches the far edge of its fence row:
/// edge-to-edge gap plus the fence via's FULL diameter. A max-freq class is a
/// fence target even when it did not spell `(fence)`. When it also authors a
/// wider keepout halo, the wider of the two wins; a protected corridor may not
/// shrink merely because another protection rule is present.
///
/// A **keepout-only** class has no via row to protect, so its corridor is simply
/// the halo it declared — the shadow then extends that same distance onto the
/// other layers as a cost, where the halo itself does not reach.
///
/// The two fence formulas are replicated from `via_fence.resolvedGapMm` and
/// `via_fence.resolvedFenceVia` (its `offset_margin_mm` as `fence_margin_mm`)
/// rather than imported, because `via_fence` sits ABOVE the router — it imports
/// `router.zig` to read routed copper — and importing it back into a module the
/// router depends on would invert that layering. `via_fence` remains the source
/// of truth; a test in `keepout_route.zig` pins the two against each other so the
/// duplication cannot drift.
pub fn widthOf(placement: optimizer.Placement, net_i: usize) f64 {
    if (net_i >= placement.rules.net.len) return 0;
    const rule = placement.rules.net[net_i];
    const fenceable = rule.rf.fence.declared or rule.rf.max_freq_hz > 0;
    if (!fenceable) return rule.rf.keepout_mm;
    return @max(rule.rf.keepout_mm, corridorMm(rule, placement.rules.design));
}

/// The fence corridor width (mm) for a fenced class: resolved gap + fence via
/// diameter, plus one effective pitch for every additional concentric row.
/// See `widthOf` for the source-of-truth note.
fn corridorMm(rule: optimizer.NetRule, design: optimizer.DesignRules) f64 {
    const gap = if (rule.rf.fence.offset_mm > 0)
        rule.rf.fence.offset_mm
    else
        (if (rule.clearance > 0) rule.clearance else design.clearance) + fence_margin_mm;
    const dia = if (rule.rf.fence.via_dia > 0)
        rule.rf.fence.via_dia
    else if (rule.via_dia > 0) rule.via_dia else design.via_dia;
    const drill = if (rule.rf.fence.via_drill > 0)
        rule.rf.fence.via_drill
    else if (rule.via_drill > 0) rule.via_drill else design.via_drill;
    const asked_pitch = if (rule.rf.fence.pitch_mm > 0)
        rule.rf.fence.pitch_mm
    else if (rule.rf.max_freq_hz > 0)
        c_mm_per_s / (rule.rf.max_freq_hz * @sqrt(assumed_er)) / pitch_wavelength_divisor
    else
        0;
    const pitch = if (asked_pitch > 0)
        @max(asked_pitch, @max(dia + design.clearance, drill + design.hole_to_hole))
    else
        0;
    const extra_rows: f64 = @floatFromInt(@max(1, rule.rf.fence.rows.generated) - 1);
    return gap + dia + extra_rows * pitch;
}

/// The net-indexed corridor table `State.nets` carries, or empty when no net
/// declares a fence or a keepout.
pub fn widths(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]const f64 {
    if (!anyDeclared(placement)) return &.{};
    const out = try arena.alloc(f64, placement.nets.len);
    for (out, 0..) |*w, i| w.* = widthOf(placement, i);
    return out;
}

/// Net `net`'s corridor width from a `widths` table; 0 for the no-net (−1)
/// sentinel or an id past the table.
pub fn widthAt(table: []const f64, net: i32) f64 {
    if (net < 0) return 0;
    const i: usize = @intCast(net);
    return if (i < table.len) table[i] else 0;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A placement carrying just the net names + per-net rules these helpers read.
fn fixture(nets: []const optimizer.FlatNet, rules: []const optimizer.NetRule, design: optimizer.DesignRules) optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
        .rules = .{ .net = rules, .design = design },
    };
}

const three_nets = [_]optimizer.FlatNet{
    .{ .name = "RF_IN", .pins = &.{} },
    .{ .name = "SPI_SCK", .pins = &.{} },
    .{ .name = "GND", .pins = &.{} },
};

// spec: placement/router - an RF corridor reaches the far edge of the full fence-via diameter for declared and max-freq-derived fences, never shrinking below a wider authored halo
test "the shadow corridor width resolves per class from the fence, else the keepout" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const design = optimizer.DesignRules{ .clearance = 0.2, .via_dia = 0.4, .via_drill = 0.2 };
    const rules = [_]optimizer.NetRule{
        .{ .rf = .{ .fence = .{ .declared = true } } }, // derive everything
        .{ .rf = .{ .keepout_mm = 0.5 } }, // keepout only
        .{}, // plain
    };
    const p = fixture(&three_nets, &rules, design);
    try testing.expect(anyDeclared(p));
    // Derived fence: (clearance 0.2 + margin 0.1) gap + 0.4 via = 0.7 mm.
    try testing.expectApproxEqAbs(@as(f64, 0.7), widthOf(p, 0), 1e-12);
    // Keepout-only: the halo itself, carried onto the other layers as a cost.
    try testing.expectApproxEqAbs(@as(f64, 0.5), widthOf(p, 1), 1e-12);
    // A plain class casts nothing, and so does an out-of-range index.
    try testing.expectEqual(@as(f64, 0), widthOf(p, 2));
    try testing.expectEqual(@as(f64, 0), widthOf(p, 9));

    // An AUTHORED offset and fence via win over the derivation.
    const authored = [_]optimizer.NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .offset_mm = 0.25, .via_dia = 0.6 } } },
        .{},
        .{},
    };
    try testing.expectApproxEqAbs(@as(f64, 0.85), widthOf(fixture(&three_nets, &authored, design), 0), 1e-12);

    // Additional layers reserve their actual generated row pitch too.
    const layered = [_]optimizer.NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1.0, .rows = .{ .generated = 3 }, .offset_mm = 0.25, .via_dia = 0.6 } } },
        .{},
        .{},
    };
    try testing.expectApproxEqAbs(@as(f64, 2.85), widthOf(fixture(&three_nets, &layered, design), 0), 1e-12);

    // A max-freq class is the same derived fence target even without an
    // authored (fence), and a wider explicit halo can only expand it.
    const derived = [_]optimizer.NetRule{
        .{ .rf = .{ .max_freq_hz = 12e9 } },
        .{ .rf = .{ .max_freq_hz = 12e9, .keepout_mm = 0.9 } },
        .{},
    };
    const derived_placement = fixture(&three_nets, &derived, design);
    try testing.expectApproxEqAbs(@as(f64, 0.7), widthOf(derived_placement, 0), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.9), widthOf(derived_placement, 1), 1e-12);

    // A board declaring neither takes the early-out: no table, no lanes.
    const plain = [_]optimizer.NetRule{ .{ .width = 0.2 }, .{}, .{} };
    const none = fixture(&three_nets, &plain, design);
    try testing.expect(!anyDeclared(none));
    try testing.expectEqual(@as(usize, 0), (try widths(arena, none)).len);

    // The table is net-indexed and `widthAt` answers the no-net sentinel.
    const table = try widths(arena, p);
    try testing.expectEqual(@as(usize, 3), table.len);
    try testing.expectApproxEqAbs(@as(f64, 0.7), widthAt(table, 0), 1e-12);
    try testing.expectEqual(@as(f64, 0), widthAt(table, -1));
    try testing.expectEqual(@as(f64, 0), widthAt(table, 7));
}

/// A two-layer shadow state over a 20×20 node grid at 0.5 mm pitch.
fn laneState(arena: std.mem.Allocator, width: f64) std.mem.Allocator.Error!State {
    const layers = try arena.alloc([]i32, 2);
    for (layers) |*l| {
        l.* = try arena.alloc(i32, 20 * 20);
        @memset(l.*, empty);
    }
    return .{ .layers = layers, .width = width };
}

const lane_grid = router.Grid{ .ox = 0, .oy = 0, .g = 0.5, .nx = 20, .ny = 20 };

// spec: placement/router - a fenced net's copper shadows every signal layer, its owner and exempt ground pay nothing, and a via into the shadow costs more than a step
test "a stamped shadow spans both layers, exempts its owner, and prices a via above a step" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const st = try laneState(arena, 0.7);
    // An RF trace (net 0) along y = 5 on the TOP layer only.
    st.stampSeg(lane_grid, .{ 2, 5 }, .{ 8, 5 }, 0.1, 0);
    const on = lane_grid.node(lane_grid.nearest(5, 5)[0], lane_grid.nearest(5, 5)[1]);
    const off = lane_grid.node(lane_grid.nearest(5, 8)[0], lane_grid.nearest(5, 8)[1]);

    // The shadow is on BOTH layers, though the copper is on one — that is the
    // parallel-run-underneath case the rule exists for.
    try testing.expect(st.at(0, on, 1));
    try testing.expect(st.at(1, on, 1));
    // Well away from the trace nothing is shadowed on either layer.
    try testing.expect(!st.at(0, off, 1));
    try testing.expect(!st.at(1, off, 1));
    // The owner routes through its own corridor.
    try testing.expect(!st.at(0, on, 0));
    try testing.expect(!st.at(1, on, 0));

    // Costs: a foreign step pays `step_mult`, a foreign via `via_mult`, and
    // exempt (ground/plane) copper pays neither.
    try testing.expectEqual(step_mult, st.multiplier(1, on, 1, false, false));
    try testing.expectEqual(via_mult, st.multiplier(1, on, 1, true, false));
    try testing.expect(via_mult > step_mult);
    try testing.expectEqual(@as(f64, 1.0), st.multiplier(1, on, 1, false, true));
    try testing.expectEqual(@as(f64, 1.0), st.multiplier(1, on, 1, true, true));
    // Outside the corridor nothing is charged, and the owner is never charged.
    try testing.expectEqual(@as(f64, 1.0), st.multiplier(1, off, 1, false, false));
    try testing.expectEqual(@as(f64, 1.0), st.multiplier(1, on, 0, true, false));
    // An inert state (no lanes) charges nothing at all.
    const inert = State{};
    try testing.expectEqual(@as(f64, 1.0), inert.multiplier(0, on, 1, true, false));
    try testing.expect(!inert.at(0, on, 1));
    try testing.expect(!inert.anyLayer(on, 1));

    // Ripping the net's copper takes its corridor with it.
    st.clearNet(0);
    try testing.expect(!st.at(0, on, 1));
    try testing.expect(!st.at(1, on, 1));

    // A class with no corridor stamps nothing at all.
    const plain = try laneState(arena, 0);
    plain.stampSeg(lane_grid, .{ 2, 5 }, .{ 8, 5 }, 0.1, 0);
    plain.stampVia(lane_grid, 5, 5, 0.2, 0);
    try testing.expect(!plain.at(0, on, 1));
}

/// board-a's fenced RF class as `runsAlong` sees it: a 0.627 mm corridor
/// (0.127 clearance + 0.1 margin + 0.4 via) cast by a 0.3124 mm RF trace, probed
/// by the 0.2532 mm LVDS pair that has to cross it. These are the real numbers
/// the miscalibration was found on, so the tests below are the board's own case
/// rather than a synthetic one.
const bar_corridor: f64 = 0.127 + 0.1 + 0.4;
const bar_caster_w: f64 = 0.3124;
const bar_probe_half: f64 = 0.2532 / 2.0;
/// Half-thickness of the in-shadow stadium, and the band a square crossing
/// traverses — the quantity the admission ratio is measured against.
const bar_reach: f64 = bar_corridor + bar_caster_w / 2 + bar_probe_half;
const bar_band: f64 = 2 * bar_reach;

/// A shadow state whose net 0 casts `bar_corridor` and whose net 1 (the probe)
/// casts nothing. No lanes — `runsAlong` reads the casting COPPER, not the raster.
const bar_widths = [_]f64{ bar_corridor, 0 };

/// One horizontal RF trace of net 0 centred on `y`, long enough (x ∈ [-60, 60])
/// that every probe below meets its SIDE rather than running off an endpoint,
/// where `segPointDist` would measure to the cap and the geometry stops being
/// the clean band the tests reason about.
fn casterAt(y: f64) router.Track {
    return .{ .x1 = -60, .y1 = y, .x2 = 60, .y2 = y, .layer = 0, .width = bar_caster_w, .net = 0 };
}

/// Walk a segment through `runsAlong` as the probe net (1).
fn crosses(tracks: []const router.Track, a: [2]f64, b: [2]f64) bool {
    const st = State{ .nets = &bar_widths };
    return st.runsAlong(tracks, .{ a, b }, bar_probe_half, 1);
}

// spec: placement/router - a synthesized segment crossing an RF corridor is admitted by the angle it meets it at, so a 45 degree lattice crossing passes where a shallow approach and a parallel run do not
test "the crossing gate admits by angle, and the admitted angle is the documented one" {
    // The ratio and the angle are two spellings of one constant; a drift between
    // them would silently retune the gate, so they are pinned to each other.
    try testing.expectApproxEqAbs(
        @as(f64, 1.0) / @sin(min_cross_angle_deg * std.math.pi / 180.0),
        max_cross_ratio,
        1e-12,
    );

    const casters = [_]router.Track{casterAt(0)};
    // A square crossing spends one band inside — the cheapest crossing there is.
    try testing.expect(!crosses(&casters, .{ 0, -5 }, .{ 0, 5 }));
    // 45°, the router's OWN lattice angle: 1.41 bands. This is the case the old
    // budget refused (2.573 mm of travel against a 2.508 mm allowance), which is
    // what broke the coupled diff-pair construction on a fenced board.
    try testing.expect(!crosses(&casters, .{ -5, -5 }, .{ 5, 5 }));
    // Shallower than the declared minimum angle is a run, not a crossing: at 20°
    // the segment spends 2.9 bands in the corridor.
    const shallow = 5.0 / @tan(20.0 * std.math.pi / 180.0);
    try testing.expect(crosses(&casters, .{ -shallow, -5 }, .{ shallow, 5 }));
    // And the case the shadow exists for — 8 mm one layer down, alongside.
    try testing.expect(crosses(&casters, .{ -4, 0.3 }, .{ 4, 0.3 }));

    // Exactly at the documented angle the gate is on its boundary: a hair
    // steeper crosses, a hair shallower runs.
    const at = bar_band / 2 / @tan(min_cross_angle_deg * std.math.pi / 180.0);
    try testing.expect(!crosses(&casters, .{ -at * 0.9, -bar_band / 2 }, .{ at * 0.9, bar_band / 2 }));
    try testing.expect(crosses(&casters, .{ -at * 1.2, -bar_band / 2 }, .{ at * 1.2, bar_band / 2 }));

    // A board that declares no fence and no keepout has no table, so the whole
    // test short-circuits and every segment is admitted.
    const inert = State{};
    try testing.expect(!inert.runsAlong(&casters, .{ .{ -4, 0.3 }, .{ 4, 0.3 } }, bar_probe_half, 1));
    // The corridor's OWNER runs along its own freely — its later legs must.
    const own = State{ .nets = &bar_widths };
    try testing.expect(!own.runsAlong(&casters, .{ .{ -4, 0.3 }, .{ 4, 0.3 } }, bar_probe_half, 0));
}

// spec: placement/router - each crossing of an RF corridor is judged on its own contiguous span, so one segment crossing several unrelated corridors squarely is not refused for their sum
test "crossings of separate RF corridors are measured one at a time, not summed" {
    // Three parallel RF traces 6 mm apart, crossed dead square by one segment.
    // Every crossing is individually the cheapest shape there is, but their
    // lengths sum to 3 bands — which the old accumulator, summing over the whole
    // segment against a single corridor width, refused outright. The rule always
    // read "spent inside ONE"; this pins that it now measures that.
    const casters = [_]router.Track{ casterAt(0), casterAt(6), casterAt(12) };
    try testing.expect(!crosses(&casters, .{ 0, -3 }, .{ 0, 15 }));
    // …and the pass above is contiguity doing the work, not slack in the budget:
    // ONE unbroken span of that same summed length is refused outright.
    const one = [_]router.Track{casterAt(0)};
    const summed = 3 * bar_band / 2;
    try testing.expect(crosses(&one, .{ -summed, 0.3 }, .{ summed, 0.3 }));

    // Contiguity is not a blanket pardon either. Crossed at ~17° instead of
    // square, each of the three spans is on its own 6.3 mm long — past what one
    // crossing may spend — and the segment is refused at the first of them.
    try testing.expect(crosses(&casters, .{ -30, -3 }, .{ 30, 15 }));

    // Two casters close enough to overlap read as one wider corridor, and a
    // square crossing of the fused pair is still a crossing.
    const pair = [_]router.Track{ casterAt(0), casterAt(0.4) };
    try testing.expect(!crosses(&pair, .{ 0, -4 }, .{ 0, 4 }));
}

// spec: placement/router - a via reads the RF shadow on every signal layer while a step reads only its own, since a through barrel occupies them all
test "a via reads the shadow on every layer, a step only its own" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const st = try laneState(arena, 0.7);
    // Stamp only the BOTTOM lane, as if the shadow came from bottom-side copper
    // and the router is deciding a top-layer move.
    st.disc(lane_grid, 1, .{ 5, 5 }, 0.8, 0);
    const on = lane_grid.node(lane_grid.nearest(5, 5)[0], lane_grid.nearest(5, 5)[1]);

    // A top-layer STEP is free — the shadow is not on its layer…
    try testing.expect(!st.at(0, on, 1));
    try testing.expectEqual(@as(f64, 1.0), st.multiplier(0, on, 1, false, false));
    // …but a via at the same node is not, because the barrel reaches the layer
    // that IS shadowed.
    try testing.expect(st.anyLayer(on, 1));
    try testing.expectEqual(via_mult, st.multiplier(0, on, 1, true, false));
    // Its owner still passes on both counts.
    try testing.expect(!st.anyLayer(on, 0));
}
