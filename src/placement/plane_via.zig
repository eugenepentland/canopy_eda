//! Where a plane-stitching via may land on the pad it serves.
//!
//! A plane-carried net (`(stackup … (plane IDX "NET"))`) reaches its plane
//! through one via per ordinary stranded pad, or a bounded array in an exposed
//! thermal land — pass 1 of the router drops them, and the post-route gate
//! stitches whatever islands are left. Both searches want the
//! same thing: the nearest site to the pad that a via can legally occupy.
//!
//! Both used to look for it in the same place — OUTSIDE the pad. The site they
//! try first is the pad's anchor snapped to the ROUTING grid, and every
//! candidate after that is a whole grid pitch further out (~0.44 mm on
//! board-a), joined back with a stub. That is the right answer for a chip
//! pad, which is smaller than the grid anyway, and the wrong one for a big pad:
//! a buck's exposed thermal pad is millimetres across, so a site a couple of
//! tenths off its centre is still deep inside its own copper — clear of the
//! neighbour that refused the centre, needing no stub, and invisible to a
//! search that only ever steps by the grid. Measured on board-a's
//! `buck_6v/U22.3` (1.32 × 1.72 mm): the anchor sits 0.063 mm from the `FB` pad
//! and needs 0.327, while a site 0.275 mm below it clears everything — inside
//! the same pad.
//!
//! `InPad` is that search: a deterministic ring walk over a lattice pinned to
//! the pad's anchor, yielding only sites whose via BARREL stays entirely within
//! the pad's own copper. It answers WHERE a via may sit as far as the pad is
//! concerned; the caller still applies its own clearance predicates (foreign
//! pads, placed vias, drilled holes, routed copper), so a site this yields is a
//! candidate, never a verdict. No RNG and no clock: the same pad, anchor and
//! via diameter always produce the same sequence, so a board routed twice gets
//! byte-identical copper.
//!
//! The other half of the same question is CONTAINMENT itself, and it is this
//! module's because the answer must be one answer. A via sited on a pad has to
//! keep its finished annulus on that pad's copper: a ring hanging over the land
//! edge is unsupported copper across the mask opening and a solder-wicking path
//! out of the joint, and nothing else on the board can catch it — every copper
//! clearance probe skips the routing net's own pads, which is exactly what a
//! land the via is drilled into is. So `barrelFits` is the single predicate,
//! `inLandBarrelFits` is the form a caller uses when it does not yet know
//! whether the site is on a land at all (`landAt` answers that), and the ring
//! walk, the thermal array and the router's pad-centre sites all measure the
//! same geometry. Measured on `board-a-lt3045-ldo`: the router's first candidate
//! is the pad anchor snapped to the routing grid, and on U1's 0.80 x 0.30 mm
//! DFN ground land that put a 0.4 mm barrel dead on the land with the ring
//! ~0.05 mm past the 0.30 mm edge on each side — legal by every clearance rule
//! and a defect on the board.

const std = @import("std");
const pad_shape = @import("pad_shape.zig");
const numeric = @import("../numeric.zig");

/// Preferred centre pitch for automatic exposed-pad thermal arrays. This is
/// deliberately wider than the manufacturing minimum: tighter arrays remove
/// useful spreading copper and quickly hit diminishing thermal returns. A
/// small land may tighten below this only to fit a useful 3 x 3 field.
pub const thermal_via_pitch_mm: f64 = 0.9;
/// Bound one axis of an automatic field. A 4 x 4 array gives a large
/// 4.6-mm-class RF/power paddle sixteen regular barrels without walling the
/// package's own perimeter escapes; tighter packing showed no routing margin.
pub const max_thermal_axis_vias: usize = 4;

/// One axis of an automatic array: how many sites, and the centre pitch
/// between them.
pub const ThermalAxis = struct {
    count: usize,
    pitch: f64,
};

/// Choose one centred array axis. Use the preferred pitch when it naturally
/// gives at least three sites; otherwise tighten only when the DRC minimum can
/// support a 3-site row. This makes Board A's 1.95-mm HMC451 paddle a 3-site
/// axis while its 2.5-mm and 4.6-mm paddles remain at about 0.9-mm pitch.
pub fn thermalAxis(span: f64, via_dia: f64, min_pitch: f64) ThermalAxis {
    if (span < via_dia or min_pitch <= 0) return .{ .count = 0, .pitch = 0 };
    const usable = span - via_dia;
    const preferred_pitch = @max(thermal_via_pitch_mm, min_pitch);
    const preferred_count = numeric.toCount(@floor(usable / preferred_pitch)) + 1;
    const legal_count = numeric.toCount(@floor(usable / min_pitch)) + 1;
    var count = @min(preferred_count, max_thermal_axis_vias);
    if (count < 3 and legal_count >= 3) count = 3;
    count = @min(count, max_thermal_axis_vias);
    if (count < 2) return .{ .count = count, .pitch = 0 };
    return .{
        .count = count,
        .pitch = @min(preferred_pitch, usable / @as(f64, @floatFromInt(count - 1))),
    };
}

/// A centred regular field of thermal-via sites over one exposed land. Each
/// exact site is still judged by `barrelFits`: a rejected custom-pad cell is
/// skipped, never replaced by the nearest off-pattern point.
pub const ThermalArray = struct {
    pad: pad_shape.Shape,
    centre: [2]f64,
    cols: usize,
    rows: usize,
    pitch_x: f64,
    pitch_y: f64,

    /// How many sites the field holds.
    pub fn count(self: ThermalArray) usize {
        return self.cols *| self.rows;
    }

    /// The exact world centre of one field cell.
    pub fn point(self: ThermalArray, col: usize, row: usize) [2]f64 {
        const cx = (@as(f64, @floatFromInt(self.cols)) - 1) / 2;
        const cy = (@as(f64, @floatFromInt(self.rows)) - 1) / 2;
        return .{
            self.centre[0] + (@as(f64, @floatFromInt(col)) - cx) * self.pitch_x,
            self.centre[1] + (@as(f64, @floatFromInt(row)) - cy) * self.pitch_y,
        };
    }
};

/// Whether a via of `via_dia` standing at `point` keeps its whole FINISHED
/// BARREL — the copper annulus, not merely the drilled hole — inside `pad`'s
/// real outline. This is the one containment predicate: the thermal array
/// judges each of its regular cells with it, `InPad.init`'s strict ring walk
/// yields only sites that pass it, and the router gates every via-in-pad site
/// on it so an annular ring never hangs off the land it is drilled into.
pub fn barrelFits(pad: pad_shape.Shape, point: [2]f64, via_dia: f64) bool {
    return circleFits(pad, point, via_dia / 2);
}

/// Whether a circle of radius `r` about `point` stays on `pad`'s copper: the
/// centre plus `barrel_samples` compass points around the rim, each measured
/// against the real outline.
fn circleFits(pad: pad_shape.Shape, point: [2]f64, r: f64) bool {
    if (!onCopper(pad, point[0], point[1])) return false;
    for (0..barrel_samples) |i| {
        const a = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(barrel_samples)) * std.math.tau;
        if (!onCopper(pad, point[0] + r * @cos(a), point[1] + r * @sin(a))) return false;
    }
    return true;
}

/// Is (x,y) on `pad`'s copper? `pad_shape.pointDist` is 0 exactly there —
/// inside the box for a simple pad, inside the real outline for a custom one —
/// and an infinite slack keeps the outline test from being skipped.
fn onCopper(pad: pad_shape.Shape, x: f64, y: f64) bool {
    return pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, x, y, std.math.inf(f64)) <= fit_eps;
}

/// The net's own pad copper under `p` on `layer` — the first same-net land (in
/// the caller's own obstacle order, so the answer is deterministic) whose shape
/// contains the point, or null when `p` sits on no land of its own net. `obs` is
/// any slice of records carrying `x0`/`y0`/`x1`/`y1`/`poly`/`net`/`thru`/`layer`
/// — the router's pad-obstacle list, passed structurally so this module stays
/// out of an import cycle with it.
pub fn landAt(obs: anytype, p: [2]f64, net: i32, layer: u8) ?pad_shape.Shape {
    for (obs) |q| {
        if (q.net != net or (!q.thru and q.layer != layer)) continue;
        if (pad_shape.pointDist(q.x0, q.y0, q.x1, q.y1, q.poly, p[0], p[1], std.math.inf(f64)) > 0) continue;
        return .{ .x0 = q.x0, .y0 = q.y0, .x1 = q.x1, .y1 = q.y1, .poly = q.poly };
    }
    return null;
}

/// May a via of `via_dia` stand at `point` AS A VIA-IN-PAD, given the land its
/// centre sits on (`landAt`, null when it sits on none)? A site ON one of its
/// net's own lands is a via IN that land and has to contain its barrel there; a
/// site on no such land is a via BESIDE the pad it serves, reached by the
/// caller's stub, and this says nothing about it (the clearance predicates do).
///
/// The distinction is the whole rule. A barrel drilled into a land must keep its
/// annular ring on that land's copper — a ring hanging over the edge is
/// unsupported copper across the mask opening and a solder-wicking path, and no
/// clearance check can see it, because the land is the routing net's own and
/// every copper probe skips its own net. A barrel standing NEXT to a land, ring
/// clear of it or merely tangent, is the ordinary laddered drop the plane pass
/// has always made: refusing those would refuse nearly every stitch on a board.
pub fn inLandBarrelFits(land: ?pad_shape.Shape, point: [2]f64, via_dia: f64) bool {
    const pad = land orelse return true;
    return barrelFits(pad, point, via_dia);
}

/// In-pad scan step as a fraction of the via's copper DIAMETER. A quarter of a
/// 0.4 mm via is 0.1 mm — fine enough to find the legal band beside a crowding
/// neighbour (the board-a thermal pad's is 0.275 mm off centre) without
/// turning a 1.7 mm pad into thousands of probes.
const step_frac: f64 = 0.25;
/// Floor on that step (mm), so a hairline via diameter cannot make the scan
/// unbounded.
const min_step_mm: f64 = 0.05;
/// Hard cap on how many rings the scan walks, whatever the pad measures, so a
/// huge pour-like land cannot turn one stitch into an unbounded probe. Sixteen
/// rings reach 1.6 mm from the anchor at the default step — past any pad this
/// exists for, and measured as the right value rather than guessed: cutting it
/// to six lost board-e five routed nets and board-d three, while saving only
/// 2% of the corpus wall clock, because the cost is the ROUTE the moved vias
/// produce and not the probes themselves.
const max_ring: usize = 16;
/// Compass samples taken around the via barrel when testing that it stays
/// inside the pad's copper. Eight is enough to reject any site whose barrel
/// crosses a straight pad edge or a simplified outline's corner.
const barrel_samples: usize = 8;
/// Slack (mm) a barrel is allowed when it is measured against a pad EDGE.
///
/// The edge is the hard boundary: copper past it is off the land, which is the
/// annular/solderability defect containment exists to refuse. So this is one
/// nanometre — the same float-noise scale as the router's `clearance_eps` —
/// bought for exactly one case: a barrel whose rim lands ON the edge (a 0.4 mm
/// via in a land 0.4 mm across, where the centre and the rim need not round the
/// same way) must read as contained rather than losing its site to arithmetic.
/// It is not an overhang allowance and cannot be spent as one: a real overhang
/// is tens of microns, and the measured DFN case this gate was written for hangs
/// over by ~50 µm — 50000 times this — so every one of them is still refused.
const fit_eps: f64 = 1e-6;

/// Deterministic scan of the via sites inside one pad's own copper, walked in
/// rings out from the pad's anchor so the nearest legal site wins.
///
/// Iteration order is fixed: the anchor itself, then each square ring at
/// `step` mm — top row left-to-right, bottom row left-to-right, left column,
/// right column. Every yielded point has its whole via barrel inside the pad's
/// copper (`pad_shape.pointDist == 0` at the centre and at `barrel_samples`
/// points around the rim), so a caller may treat containment as given and test
/// only its own clearance rules.
pub const InPad = struct {
    shape: pad_shape.Shape,
    anchor: [2]f64,
    /// Radius (mm) of the circle that has to fit inside the pad — the via's
    /// copper barrel for `init`, its drilled hole for `overDrill`.
    r: f64,
    step: f64,
    /// Rings beyond which no lattice point can still be inside the pad.
    rings: usize,
    ring: usize = 0,
    k: usize = 0,

    /// A scan of `shape` around `anchor` for a via of `via_dia` mm. A pad too
    /// small to hold the barrel at all yields nothing (`rings == 0` and the
    /// anchor itself fails containment), which is the honest answer for an
    /// 0402 land or a fine-pitch connector finger.
    pub fn init(shape: pad_shape.Shape, anchor: [2]f64, via_dia: f64) InPad {
        return sized(shape, anchor, via_dia, via_dia);
    }

    /// The same scan with containment measured on the DRILL: the HOLE stays
    /// inside the pad's copper and only the annular RING may hang over its edge.
    ///
    /// For the pad this exists for, the strict scan above is not merely empty —
    /// it cannot be anything else. Board A's `J1` is a 1.27 mm-pitch
    /// board-to-board connector whose B.Cu fingers are 1.0 x **0.35 mm**, and
    /// the board's via is 0.4 mm: no point of that pad can hold the barrel,
    /// because the pad is narrower than the barrel is wide. Its GND finger
    /// (pad 40) therefore reads as having no in-pad site, while every ring of
    /// the fan outside it is walled by the neighbours 0.635 mm away — so the
    /// pad ships as its own one-pad copper island, which is exactly what
    /// board-a's last open GND gap was. The board the design is checked
    /// against solves it the way a hand layout does: one via at the finger's own
    /// centre, ring overhanging, hole in the pad.
    ///
    /// That is a real relaxation and it is bounded by something physical rather
    /// than by a tolerance. The DRILL inside the pad is what makes this a via IN
    /// the pad and not a via BESIDE it — the hole is surrounded by the pad's own
    /// copper, so the barrel is landed however the ring is trimmed — and the
    /// overhanging ring is copper on the pad's own net, so the only thing it can
    /// offend is a FOREIGN object, every class of which the caller already
    /// measures (`groundViaPointClear`'s pads, vias, drills, tracks and outline).
    /// A pad too small to hold even the hole still yields nothing.
    ///
    /// The step is the strict scan's, taken from the via's COPPER, so a caller
    /// that runs both walks the same lattice in the same order and the relaxed
    /// pass can only ever add sites to the strict one's sequence.
    pub fn overDrill(shape: pad_shape.Shape, anchor: [2]f64, via_dia: f64, via_drill: f64) InPad {
        const hole = if (via_drill > 0) @min(via_drill, via_dia) else via_dia;
        return sized(shape, anchor, via_dia, hole);
    }

    /// The shared constructor: `step` and `rings` come from the via's copper
    /// (the lattice is the same either way), `contained` is what must fit.
    fn sized(shape: pad_shape.Shape, anchor: [2]f64, via_dia: f64, contained: f64) InPad {
        const step = @max(min_step_mm, via_dia * step_frac);
        const reach = @max(shape.x1 - shape.x0, shape.y1 - shape.y0) / 2;
        return .{
            .shape = shape,
            .anchor = anchor,
            .r = contained / 2,
            .step = step,
            .rings = @min(max_ring, numeric.toCount(@ceil(reach / step))),
        };
    }

    /// The next site whose barrel fits inside the pad, or null when the scan is
    /// exhausted.
    pub fn next(self: *InPad) ?[2]f64 {
        while (self.ring <= self.rings) {
            const perimeter: usize = if (self.ring == 0) 1 else 8 * self.ring;
            if (self.k >= perimeter) {
                self.ring += 1;
                self.k = 0;
                continue;
            }
            const cell = ringCell(self.ring, self.k);
            self.k += 1;
            const p = [2]f64{
                self.anchor[0] + @as(f64, @floatFromInt(cell[0])) * self.step,
                self.anchor[1] + @as(f64, @floatFromInt(cell[1])) * self.step,
            };
            if (self.barrelInside(p)) return p;
        }
        return null;
    }

    /// Is the circle this scan contains (barrel for `init`, hole for
    /// `overDrill`) inside the pad's copper when centred at `p`? One shared
    /// `circleFits`, so the scan and the router's via-in-pad gate cannot drift
    /// apart on what "inside the pad" means.
    fn barrelInside(self: InPad, p: [2]f64) bool {
        return circleFits(self.shape, p, self.r);
    }
};

/// Lattice cell `k` of square ring `d` around the origin, in a fixed order:
/// ring 0 is the origin; ring d walks its top row (j = −d) left to right, then
/// its bottom row (j = +d), then the left and right columns between them.
fn ringCell(d: usize, k: usize) [2]i64 {
    const n: i64 = @intCast(d);
    if (d == 0) return .{ 0, 0 };
    const span: usize = 2 * d + 1;
    if (k < span) return .{ @as(i64, @intCast(k)) - n, -n };
    if (k < 2 * span) return .{ @as(i64, @intCast(k - span)) - n, n };
    const inner: usize = 2 * d - 1;
    if (k < 2 * span + inner) return .{ -n, @as(i64, @intCast(k - 2 * span)) - n + 1 };
    return .{ n, @as(i64, @intCast(k - 2 * span - inner)) - n + 1 };
}

/// Outward fan direction for a via at pad centre `c`: a unit vector pointing
/// AWAY from nearby foreign pads, so a via that has to leave the pad escapes
/// into open copper. Falls back to +y when nothing is close. `obs` is any slice
/// of records carrying `x0`/`y0`/`x1`/`y1`/`net` — the router's pad-obstacle
/// list, passed structurally so this module stays out of an import cycle with
/// it.
pub fn fanDir(obs: anytype, c: [2]f64, net: i32) [2]f64 {
    var vx: f64 = 0;
    var vy: f64 = 0;
    for (obs) |p| {
        if (p.net == net) continue;
        const cx = (p.x0 + p.x1) / 2;
        const cy = (p.y0 + p.y1) / 2;
        const dx = c[0] - cx;
        const dy = c[1] - cy;
        const d2 = dx * dx + dy * dy;
        if (d2 < 1e-9 or d2 > 16.0) continue; // ignore pads > 4 mm away
        vx += dx / d2;
        vy += dy / d2;
    }
    const m = std.math.hypot(vx, vy);
    if (m < 1e-9) return .{ 0, 1 };
    return .{ vx / m, vy / m };
}

/// Angle offset sequence sweeping out from 0: 0, +30°, −30°, +60°, −60°, …
/// — so an outward fan tries the directions nearest its heading first.
pub fn swivel(k: usize) f64 {
    const step = std.math.pi / 6.0;
    const mag: f64 = @floatFromInt((k + 1) / 2);
    const sign: f64 = if (k % 2 == 1) 1 else -1;
    return sign * mag * step;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// A 3 × 3 mm thermal land whose declared origin sits 1.1 mm off centre, ringed
/// by foreign copper 0.15 mm outside its edge, plus a second ground pad in open
/// space so the net is routable. Every number is chosen to isolate the in-pad
/// search:
///   * the via (0.8 mm) needs 0.6 mm to foreign copper, so the land's origin —
///     0.55 mm from the ring — is via-ILLEGAL, while its body is not;
///   * the stub (0.2 mm wide) needs only 0.3 mm, so a short trace INSIDE the
///     land is legal and the origin is not fatally crowded;
///   * a 3.8 mm net class puts the routing lattice at 4.0 mm, wider than the
///     land itself, so the outward fan's first ring already clears the pad —
///     and every site it can reach needs a stub across the ring, which is
///     illegal. Without the in-pad search this pad has no via at all.
const thermal_pad_fixture = struct {
    const land = [_][2]f64{ .{ -1.5, -1.5 }, .{ 1.5, -1.5 }, .{ 1.5, 1.5 }, .{ -1.5, 1.5 } };
    var hub_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 1.1, .y = 0, .w = 3, .h = 3, .poly = &land },
        .{ .number = "2", .x = 1.925, .y = 0, .w = 0.55, .h = 4.4 },
        .{ .number = "3", .x = -1.925, .y = 0, .w = 0.55, .h = 4.4 },
        .{ .number = "4", .x = 0, .y = -1.925, .w = 4.4, .h = 0.55 },
        .{ .number = "5", .x = 0, .y = 1.925, .w = 4.4, .h = 0.55 },
    };
    // Deliberately large enough for an array, but on a passive: geometry alone
    // must not turn an arbitrary land/testpoint into an automatic drill field.
    var far_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 3, .h = 3 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2.5, .hh = 2.5, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 1.7, .hh = 1.7, .pads = &far_pads, .fallback = false, .x = 10, .y = 0 },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "R1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &gnd_pins }};
    const rules = [_]optimizer.NetRule{ .{}, .{ .width = 3.8 } };
};

fn thermalPadPlacement() optimizer.Placement {
    return .{
        .parts = &thermal_pad_fixture.parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &thermal_pad_fixture.nets,
        // Index 1 has no net — `maxRouteParams` reads the rule table itself, so
        // this widens the LATTICE without adding copper the fixture must dodge.
        .rules = .{ .net = &thermal_pad_fixture.rules },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        // Grid origin is (minx - 1, miny - 1), so a 4.0 mm lattice runs
        // …, -2, 2, … in BOTH axes: no lattice node lands inside the land's
        // via-legal interior (|x|, |y| <= 1.05 mm). That is what makes this
        // fixture discriminating — the outward fan snaps every candidate to
        // that lattice, so without the in-pad search the land gets no via.
        .minx = -13,
        .miny = -5,
        .maxx = 13,
        .maxy = 5,
        .generated = true,
    };
}

/// The route params the thermal-pad fixture is dimensioned against.
const thermal_params = router.RouteParams{
    .track_width = 0.2,
    .clearance = 0.2,
    .via_dia = 0.8,
    .via_drill = 0.4,
};

/// The fixture's thermal land, as `plane_via` sees it.
const thermal_land = pad_shape.Shape{ .x0 = -1.5, .y0 = -1.5, .x1 = 1.5, .y1 = 1.5 };

// spec: placement/plane-via - a thermal pad whose anchor is via-illegal is still stitched, from a site inside its own copper
test "plane pass stitches a thermal pad from inside its own copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const vias = try router.groundVias(arena, thermalPadPlacement(), thermal_params);
    // The ordinary ground pad is served once, and the thermal land receives a
    // complete centred 3 x 3 field despite its deliberately off-centre anchor.
    try testing.expectEqual(@as(usize, 10), vias.len);
    // …whose members sit inside the land, barrel and all, rather than at the
    // anchor the ring refused or in the surrounding routing channels.
    var inside: usize = 0;
    for (vias) |v| {
        if (v.x - v.dia / 2 < thermal_land.x0 or v.x + v.dia / 2 > thermal_land.x1) continue;
        if (v.y - v.dia / 2 < thermal_land.y0 or v.y + v.dia / 2 > thermal_land.y1) continue;
        inside += 1;
        try testing.expect(@abs(v.x - 1.1) > 1e-9 or @abs(v.y) > 1e-9);
    }
    try testing.expectEqual(@as(usize, 9), inside);
    try testing.expectEqual(vias.len - 1, inside);
}

// spec: placement/plane-via - an exposed-pad thermal array keeps its centred regular field, which containment sizes but never displaces
test "the thermal array keeps its exact centred field" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // The land is 3 x 3 mm and the via 0.8 mm, and two same-net barrels need
    // `via_dia + clearance` = 1.0 mm between centres — wider than the 0.9 mm
    // preferred pitch, so the field is a centred 3 x 3 at exactly 1.0 mm. Every
    // member is a cell of that regular pattern about the land's TRUE centre
    // (0, 0) — never the declared 1.1 mm anchor, and never a nearest-legal point
    // nudged off the lattice by the containment test that judges each cell.
    const axis = thermalAxis(3.0, thermal_params.via_dia, thermal_params.via_dia + thermal_params.clearance);
    try testing.expectEqual(@as(usize, 3), axis.count);
    try testing.expectApproxEqAbs(@as(f64, 1.0), axis.pitch, 1e-12);
    const array = ThermalArray{
        .pad = thermal_land,
        .centre = .{ 0, 0 },
        .cols = axis.count,
        .rows = axis.count,
        .pitch_x = axis.pitch,
        .pitch_y = axis.pitch,
    };
    const vias = try router.groundVias(arena, thermalPadPlacement(), thermal_params);
    for (0..array.cols) |col| {
        for (0..array.rows) |row| {
            const want = array.point(col, row);
            try testing.expect(barrelFits(thermal_land, want, thermal_params.via_dia));
            var found = false;
            for (vias) |v| {
                if (@abs(v.x - want[0]) < 1e-9 and @abs(v.y - want[1]) < 1e-9) found = true;
            }
            try testing.expect(found);
        }
    }
}

// spec: placement/plane-via - the plane-via pass is deterministic: the same board replays the identical via positions
test "plane pass replays identical via positions" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const a = try router.groundVias(arena, thermalPadPlacement(), thermal_params);
    const b = try router.groundVias(arena, thermalPadPlacement(), thermal_params);
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| {
        try testing.expectEqual(x.x, y.x);
        try testing.expectEqual(x.y, y.y);
        try testing.expectEqual(x.net, y.net);
    }
}

// spec: placement/plane-via - the in-pad scan yields the pad's own anchor first when the barrel fits there
test "in-pad scan starts at the pad anchor" {
    const shape = pad_shape.Shape{ .x0 = -0.66, .y0 = -0.86, .x1 = 0.66, .y1 = 0.86 };
    var scan = InPad.init(shape, .{ 0, 0 }, 0.4);
    const first = scan.next().?;
    try testing.expectApproxEqAbs(@as(f64, 0), first[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), first[1], 1e-9);
}

// spec: placement/plane-via - the in-pad scan never yields a site whose via barrel leaves the pad's copper
test "in-pad scan keeps the whole barrel inside the pad" {
    const shape = pad_shape.Shape{ .x0 = -0.66, .y0 = -0.86, .x1 = 0.66, .y1 = 0.86 };
    var scan = InPad.init(shape, .{ 0, 0 }, 0.4);
    var n: usize = 0;
    while (scan.next()) |p| {
        n += 1;
        try testing.expect(p[0] - 0.2 >= shape.x0 - 1e-9);
        try testing.expect(p[0] + 0.2 <= shape.x1 + 1e-9);
        try testing.expect(p[1] - 0.2 >= shape.y0 - 1e-9);
        try testing.expect(p[1] + 0.2 <= shape.y1 + 1e-9);
    }
    try testing.expect(n > 1);
}

// spec: placement/plane-via - a pad too small to hold the via barrel offers the in-pad scan no site at all
test "in-pad scan yields nothing on a pad narrower than the via" {
    // A 1.00 × 0.35 mm connector finger cannot hold a 0.4 mm barrel.
    const shape = pad_shape.Shape{ .x0 = -0.5, .y0 = -0.175, .x1 = 0.5, .y1 = 0.175 };
    var scan = InPad.init(shape, .{ 0, 0 }, 0.4);
    try testing.expect(scan.next() == null);
}

// spec: placement/plane-via - a via-in-pad site may hang its annular ring over the pad edge while its drilled hole stays on the pad's own copper, so a finger narrower than the barrel still offers one
test "the drill-contained scan lands a via on a finger narrower than its barrel" {
    // board-a's `J1` GND finger and the board's 0.4/0.2 via: 1.00 x 0.35 mm,
    // so the pad is narrower than the barrel and the strict scan has nothing.
    const finger = pad_shape.Shape{ .x0 = 184.475, .y0 = 110.295, .x1 = 185.475, .y1 = 110.645 };
    const anchor = [2]f64{ 184.975, 110.47 };
    var strict = InPad.init(finger, anchor, 0.4);
    try testing.expect(strict.next() == null);
    // The hole fits, so the finger's own centre is a site — which is the via
    // the routed reference board carries on that pad.
    var over = InPad.overDrill(finger, anchor, 0.4, 0.2);
    const first = over.next().?;
    try testing.expectApproxEqAbs(anchor[0], first[0], 1e-9);
    try testing.expectApproxEqAbs(anchor[1], first[1], 1e-9);
    // Every site keeps the HOLE on the pad, and the ring is what hangs over.
    var scan = InPad.overDrill(finger, anchor, 0.4, 0.2);
    var n: usize = 0;
    var overhangs = false;
    while (scan.next()) |p| {
        n += 1;
        try testing.expect(p[1] - 0.1 >= finger.y0 - 1e-9);
        try testing.expect(p[1] + 0.1 <= finger.y1 + 1e-9);
        if (p[1] - 0.2 < finger.y0 - 1e-9 or p[1] + 0.2 > finger.y1 + 1e-9) overhangs = true;
    }
    try testing.expect(n > 1);
    try testing.expect(overhangs);
    // One lattice, walked in one order: on a pad that CAN hold the barrel the
    // relaxed scan yields the strict scan's own sites, in the strict scan's own
    // order, plus the rim sites it adds — so a caller running both can only
    // ever gain sites, never trade one for another.
    const land = pad_shape.Shape{ .x0 = -0.66, .y0 = -0.86, .x1 = 0.66, .y1 = 0.86 };
    try testing.expect((strictSitesInOrder(land, 0.4, 0.2) orelse 0) > 1);
}

/// How many of the STRICT scan's sites the relaxed scan yields on `land`, in
/// the strict scan's own order — null when it skipped one, which is what
/// "superset, same order" fails as.
fn strictSitesInOrder(land: pad_shape.Shape, via_dia: f64, via_drill: f64) ?usize {
    var tight = InPad.init(land, .{ 0, 0 }, via_dia);
    var loose = InPad.overDrill(land, .{ 0, 0 }, via_dia, via_drill);
    var matched: usize = 0;
    while (tight.next()) |want| {
        while (loose.next()) |got| {
            if (got[0] == want[0] and got[1] == want[1]) break;
        } else return null;
        matched += 1;
    }
    return matched;
}

// spec: placement/plane-via - a pad too small to hold even the drilled hole offers no in-pad site, and a via with no usable drill is held to its barrel
test "a pad narrower than the drill offers no in-pad site at all" {
    const sliver = pad_shape.Shape{ .x0 = -0.4, .y0 = -0.07, .x1 = 0.4, .y1 = 0.07 };
    var strict = InPad.init(sliver, .{ 0, 0 }, 0.4);
    var relaxed = InPad.overDrill(sliver, .{ 0, 0 }, 0.4, 0.2);
    try testing.expect(strict.next() == null);
    try testing.expect(relaxed.next() == null);
    // The relaxation is never looser than the caller's own geometry says. A via
    // whose drill is undeclared, and one whose drill is malformed wider than
    // its barrel, are both held to the barrel rule — so the 0.35 mm finger that
    // the drill rule rescues stays refused for either of them.
    const finger = pad_shape.Shape{ .x0 = -0.5, .y0 = -0.175, .x1 = 0.5, .y1 = 0.175 };
    var undrilled = InPad.overDrill(finger, .{ 0, 0 }, 0.4, 0);
    var fat = InPad.overDrill(finger, .{ 0, 0 }, 0.4, 9.0);
    try testing.expect(undrilled.next() == null);
    try testing.expect(fat.next() == null);
}

// spec: placement/plane-via - the in-pad scan is deterministic: the same pad, anchor and via size replay the identical sequence
test "in-pad scan replays the identical site sequence" {
    const shape = pad_shape.Shape{ .x0 = 180.0, .y0 = 91.5, .x1 = 181.4, .y1 = 93.3 };
    const anchor = [2]f64{ 180.7, 92.4 };
    var a = InPad.init(shape, anchor, 0.4);
    var b = InPad.init(shape, anchor, 0.4);
    var n: usize = 0;
    while (a.next()) |pa| {
        const pb = b.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(pa[0], pb[0]);
        try testing.expectEqual(pa[1], pb[1]);
        n += 1;
    }
    try testing.expect(b.next() == null);
    try testing.expect(n > 8);
}

/// `board-a-lt3045-ldo` U1's GND_1 land, as the router measures it: 0.80 x 0.30
/// mm, and the board's via is 0.4 mm — so no point of it can hold the barrel.
const dfn_land = pad_shape.Shape{ .x0 = 1.1, .y0 = -0.15, .x1 = 1.9, .y1 = 0.15 };
/// An 0603 ground land off the same board: 0.90 x 0.95 mm, which holds the same
/// barrel comfortably.
const land_0603 = pad_shape.Shape{ .x0 = -0.45, .y0 = -0.475, .x1 = 0.45, .y1 = 0.475 };

// spec: placement/plane-via - a via-in-pad site must land its whole annular ring on the pad, so a land too small to hold the barrel is refused at its own centre
test "barrel containment refuses a land too small for the via" {
    // The land is 0.30 mm across and the barrel 0.40, so its own centre — and
    // the grid-snapped site the router actually took there — both overhang.
    try testing.expect(!barrelFits(dfn_land, .{ 1.5, 0 }, 0.4));
    try testing.expect(!barrelFits(dfn_land, .{ 1.578, 0.016 }, 0.4));
    // Nothing about the LONG axis rescues it: slide along the 0.80 mm dimension
    // and the 0.30 mm one still refuses.
    try testing.expect(!barrelFits(dfn_land, .{ 1.3, 0 }, 0.4));
    try testing.expect(!barrelFits(dfn_land, .{ 1.7, 0 }, 0.4));
    // The 0603 land holds it at its centre, and refuses it once the barrel is
    // pushed off the edge.
    try testing.expect(barrelFits(land_0603, .{ 0, 0 }, 0.4));
    try testing.expect(!barrelFits(land_0603, .{ 0.3, 0 }, 0.4));
    // A smaller via fits the DFN land, so the rule is about the pair and not
    // about the pad alone.
    try testing.expect(barrelFits(dfn_land, .{ 1.5, 0 }, 0.25));
}

// spec: placement/plane-via - the pad edge is the containment boundary: a barrel exactly as wide as its land is contained, and a micron of real overhang is not
test "barrel containment holds the pad edge as the boundary" {
    // A 0.4 mm barrel in a land 0.4 mm square: the rim lands ON all four edges,
    // and the tolerance exists so arithmetic noise cannot take that site away.
    const exact = pad_shape.Shape{ .x0 = 100.0, .y0 = 50.0, .x1 = 100.4, .y1 = 50.4 };
    try testing.expect(barrelFits(exact, .{ 100.2, 50.2 }, 0.4));
    // One micron off centre is a thousand times the tolerance, and refused.
    try testing.expect(!barrelFits(exact, .{ 100.201, 50.2 }, 0.4));
    try testing.expect(!barrelFits(exact, .{ 100.2, 50.199 }, 0.4));
    // The tolerance itself is not an overhang allowance anyone can spend: half
    // of it still reads as contained, and it is 50000 times smaller than the
    // ~50 µm defect this gate was written for.
    try testing.expect(barrelFits(exact, .{ 100.2 + fit_eps / 2, 50.2 }, 0.4));
    try testing.expect(fit_eps * 50000 <= 0.05 + 1e-12);
}

// spec: placement/plane-via - a via standing on no land of its own net is not a via-in-pad and is not held to containment
test "containment judges only a site standing on its own land" {
    // No land under the site: a via BESIDE the pad, joined by the caller's stub,
    // and containment has nothing to say about it.
    try testing.expect(inLandBarrelFits(null, .{ 1.5, 0 }, 0.4));
    // A land under the site: a via IN it, and the ring has to land.
    try testing.expect(!inLandBarrelFits(dfn_land, .{ 1.5, 0 }, 0.4));
    try testing.expect(inLandBarrelFits(land_0603, .{ 0, 0 }, 0.4));
}

// spec: placement/plane-via - the land under a via site is the routing net's own pad on that layer, and a foreign or other-layer pad is not one
test "landAt finds only the routing net's own pad on the via's layer" {
    const Obs = struct { x0: f64, y0: f64, x1: f64, y1: f64, poly: []const [2]f64 = &.{}, net: i32, thru: bool = false, layer: u8 = 0 };
    const obs = [_]Obs{
        .{ .x0 = 1.1, .y0 = -0.15, .x1 = 1.9, .y1 = 0.15, .net = 2 },
        .{ .x0 = 3.0, .y0 = -0.5, .x1 = 4.0, .y1 = 0.5, .net = 7 },
        .{ .x0 = 5.0, .y0 = -0.5, .x1 = 6.0, .y1 = 0.5, .net = 2, .layer = 1 },
        .{ .x0 = 7.0, .y0 = -0.5, .x1 = 8.0, .y1 = 0.5, .net = 2, .thru = true, .layer = 1 },
    };
    const own = landAt(&obs, .{ 1.5, 0 }, 2, 0) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(dfn_land.x0, own.x0);
    try testing.expectEqual(dfn_land.y1, own.y1);
    // A FOREIGN pad is not a land this via is in — clearance governs it instead.
    try testing.expect(landAt(&obs, .{ 3.5, 0 }, 2, 0) == null);
    // Nor is the net's own pad on another signal layer …
    try testing.expect(landAt(&obs, .{ 5.5, 0 }, 2, 0) == null);
    // … unless it is a through-hole land, which is copper on every layer.
    try testing.expect(landAt(&obs, .{ 7.5, 0 }, 2, 0) != null);
    // Off every pad is the ordinary case: a via in open copper.
    try testing.expect(landAt(&obs, .{ 2.5, 0 }, 2, 0) == null);
}

/// Three ground lands on one grid-aligned row, sized so the plane pass has to
/// take a different tier on each. The routing lattice is `track + clearance` =
/// 0.4 mm with its origin at `(minx - 1, miny - 1)` = (-4, -2), so every land
/// centre below is exactly ON a lattice node: the pad-centre candidate lands on
/// the land itself, which is what makes containment — and not the snap — the
/// only thing that can move a via here.
///   * `U1.1` is `board-a-lt3045-ldo`'s DFN land, 0.80 x 0.30: too shallow to hold
///     the 0.4 mm barrel anywhere, so the in-pad walk is empty and only the
///     outward fan is left.
///   * `R1.1` is an 0603 land, 0.90 x 0.95: it holds the barrel at its centre.
///   * `R2.1` is a 0.30 x 0.30 test land, smaller than the barrel in BOTH axes:
///     no in-pad site at all, and every ring-1 fan site beside it is clear.
///   * `R3.1` is a 0.30 x 1.60 tab — narrow like the DFN land but LONG along the
///     axis the fan opens on. With no foreign copper near it `fanDir` falls back
///     to +y, so the fan's first sites are a grid pitch UP the tab and still deep
///     inside its own copper: the one case where an ungated fan would simply move
///     the overhanging ring one ring out instead of off the land.
const land_fixture = struct {
    var dfn_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.3 }};
    var wide_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.95 }};
    var tiny_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    var tab_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 1.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.3, .pads = &dfn_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &wide_pads, .fallback = false, .x = 2, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &tiny_pads, .fallback = false, .x = 4, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.2, .hh = 0.9, .pads = &tab_pads, .fallback = false, .x = -2, .y = 0 },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
        .{ .ref_des = "R3", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &gnd_pins }};
    const centres = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 4, 0 }, .{ -2, 0 } };
    const lands = [_]pad_shape.Shape{
        .{ .x0 = -0.4, .y0 = -0.15, .x1 = 0.4, .y1 = 0.15 },
        .{ .x0 = 1.55, .y0 = -0.475, .x1 = 2.45, .y1 = 0.475 },
        .{ .x0 = 3.85, .y0 = -0.15, .x1 = 4.15, .y1 = 0.15 },
        .{ .x0 = -2.15, .y0 = -0.8, .x1 = -1.85, .y1 = 0.8 },
    };
};

/// The lattice the `land_fixture` numbers are chosen against: 0.2 mm track and
/// 0.2 mm clearance put the routing grid at 0.4 mm, and the 0.4/0.2 via is the
/// board via `board-a-lt3045-ldo` carries.
const land_params = router.RouteParams{
    .track_width = 0.2,
    .clearance = 0.2,
    .via_dia = 0.4,
    .via_drill = 0.2,
};

fn landPlacement() optimizer.Placement {
    return .{
        .parts = &land_fixture.parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &land_fixture.nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = true,
    };
}

/// One land's plane return: where the barrel stands, and how far it had to
/// stand off the land centre to get there.
const Return = struct { at: [2]f64, mm: f64 };

/// The via serving `centre`: the nearest one on the plane net, with how far it
/// had to stand off. Null when the pad lost its plane return entirely.
fn nearestVia(vias: []const router.Via, centre: [2]f64) ?Return {
    var best: ?Return = null;
    for (vias) |v| {
        const mm = std.math.hypot(v.x - centre[0], v.y - centre[1]);
        if (best != null and mm >= best.?.mm) continue;
        best = .{ .at = .{ v.x, v.y }, .mm = mm };
    }
    return best;
}

/// How many of the fixture's lands came out with a plane return of their OWN —
/// a barrel near enough to be that land's drop rather than a neighbour's. One
/// grid pitch's diagonal is the bound: the pad centre, anything inside the land,
/// and the outward fan's first ring all fall inside it, and the next land is
/// 2 mm away.
fn landsServed(vias: []const router.Via) usize {
    var n: usize = 0;
    for (land_fixture.centres) |centre| {
        const near = nearestVia(vias, centre) orelse continue;
        if (near.mm <= 0.4 * std.math.sqrt2 + 1e-9) n += 1;
    }
    return n;
}

/// Does every placed barrel that STANDS on one of the fixture's lands keep its
/// ring on that land? A barrel standing on no land is the ordinary laddered
/// drop beside a pad and is not a via-in-pad, so it is not judged here.
fn everyRingLanded(vias: []const router.Via) bool {
    for (vias) |v| {
        for (land_fixture.lands) |land| {
            if (!onCopper(land, v.x, v.y)) continue;
            if (!barrelFits(land, .{ v.x, v.y }, v.dia)) return false;
        }
    }
    return true;
}

// spec: placement/plane-via - a plane return is never sited where its annular ring would hang off the land it stands on
// spec: placement/plane-via - a land too small to contain the barrel keeps its plane return, taken from the outward fan beside it
test "the plane pass lands every via-in-pad ring on its own pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = try router.route(arena, landPlacement(), land_params);
    // Every land still has its plane return: nothing is dropped for being
    // awkward, which is the failure mode a containment rule could introduce.
    try testing.expectEqual(land_fixture.centres.len, landsServed(routed.vias));
    // And no placed barrel stands on a land of its own net with its ring hanging
    // over the edge — the defect this gate exists for. A via sitting on NO land
    // is the ordinary laddered drop and is not judged here.
    try testing.expect(everyRingLanded(routed.vias));
    // The 0.80 x 0.30 DFN land cannot contain the barrel anywhere, so its return
    // is NOT at the land centre the ungated pad-centre candidate used to take …
    const dfn = nearestVia(routed.vias, land_fixture.centres[0]).?;
    try testing.expect(dfn.mm > 1e-9);
    try testing.expect(!onCopper(land_fixture.lands[0], dfn.at[0], dfn.at[1]));
    // … and it does not run away either: the fan's first ring is one grid pitch
    // out, so the return stays within a pitch's diagonal of the land it serves.
    try testing.expect(dfn.mm <= 0.4 * std.math.sqrt2 + 1e-9);
    // The 0603 land holds the barrel, so its return is IN the land, at its exact
    // centre — the tier below the refused snap is the in-pad walk, which opens
    // on the anchor itself.
    const wide = nearestVia(routed.vias, land_fixture.centres[1]).?;
    try testing.expectApproxEqAbs(@as(f64, 0), wide.mm, 1e-9);
    // The 0.30 mm square land has no in-pad site in either axis; the fan beside
    // it still finds one.
    const tiny = nearestVia(routed.vias, land_fixture.centres[2]).?;
    try testing.expect(tiny.mm > 1e-9);
    try testing.expect(!onCopper(land_fixture.lands[2], tiny.at[0], tiny.at[1]));
    // The 0.30 x 1.60 tab is the case the fan itself has to be gated for: with no
    // foreign copper near it the fan opens along +y, straight UP the tab, so its
    // first sites are a grid pitch away and STILL on the tab's own copper — where
    // the ring overhangs exactly as it did at the centre. The return therefore
    // has to leave the tab sideways, which costs it the pitch's diagonal.
    const tab = nearestVia(routed.vias, land_fixture.centres[3]).?;
    try testing.expect(!onCopper(land_fixture.lands[3], tab.at[0], tab.at[1]));
    try testing.expect(@abs(tab.at[0] - land_fixture.centres[3][0]) > 1e-9);
    try testing.expect(tab.mm <= 0.4 * std.math.sqrt2 + 1e-9);
}

/// One authored bypass bond on a plane-carried rail: `C1`'s rail land is the
/// cluster's cap land, so the plane pass sites the shared barrel ON it rather
/// than at the grid-snapped anchor. `C1` sits at x = 3.0 while the lattice
/// (origin -2, pitch 0.4) has nodes at 2.8 and 3.2 — so a via at exactly 3.0 can
/// only have come from the exact-centre rule, never from the snap.
const bond_fixture = struct {
    var hub_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var cap_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.95 }};
    var shallow_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.3 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &cap_pads, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const planes = [_][]const u8{"VDD"};
    const loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.9, .h = 0.95 },
        .cap_gnd = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .hub_pwr = &.{},
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_gnd = &.{},
        .pwr_net = 0,
        .explicit_pin = "1",
    }};
};

fn bondPlacement() optimizer.Placement {
    return .{
        .parts = &bond_fixture.parts,
        .links = &.{},
        .loops = &bond_fixture.loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = &bond_fixture.nets,
        .rules = .{ .plane_nets = &bond_fixture.planes },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 4,
        .maxy = 1,
        .generated = true,
    };
}

// spec: placement/plane-via - a bonded bypass cap keeps its barrel at the exact land centre when the land contains it, and degrades to the nearest contained site when it does not
test "a bonded cap land keeps its centred barrel only while the land contains it" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const cap_land = pad_shape.Shape{ .x0 = 2.55, .y0 = -0.475, .x1 = 3.45, .y1 = 0.475 };
    const centred = try router.route(arena, bondPlacement(), land_params);
    // The 0603 cap land holds the barrel, so the loop-inductance rule stands:
    // the barrel is at the land's EXACT centre, off the routing lattice.
    const at = nearestVia(centred.vias, .{ 3, 0 }) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f64, 0), at.mm, 1e-9);
    try testing.expect(barrelFits(cap_land, at.at, land_params.via_dia));

    // Shrink that same land to the 0.80 x 0.30 DFN shape and the centre can no
    // longer hold the ring. The rule yields rather than shipping an unlanded
    // annulus — and it degrades gracefully: the barrel steps off the land, not
    // across the board.
    var shallow = bondPlacement();
    var shallow_parts = bond_fixture.parts;
    shallow_parts[1].pads = &bond_fixture.shallow_pads;
    shallow.parts = &shallow_parts;
    const moved = try router.route(arena, shallow, land_params);
    const off = nearestVia(moved.vias, .{ 3, 0 }) orelse return error.TestUnexpectedResult;
    try testing.expect(off.mm > 1e-9);
    try testing.expect(off.mm <= 0.4 * std.math.sqrt2 + 1e-9);
    const shallow_land = pad_shape.Shape{ .x0 = 2.6, .y0 = -0.15, .x1 = 3.4, .y1 = 0.15 };
    try testing.expect(!onCopper(shallow_land, off.at[0], off.at[1]));
}

// spec: placement/plane-via - the in-pad ring walk visits every lattice cell of a ring exactly once
test "ring cells cover each ring exactly once" {
    for (1..4) |d| {
        var seen: std.AutoHashMapUnmanaged([2]i64, void) = .empty;
        defer seen.deinit(testing.allocator);
        for (0..8 * d) |k| {
            const cell = ringCell(d, k);
            const chebyshev: u64 = @max(@abs(cell[0]), @abs(cell[1]));
            try testing.expectEqual(@as(u64, d), chebyshev);
            try testing.expect(!seen.contains(cell));
            try seen.put(testing.allocator, cell, {});
        }
        try testing.expectEqual(@as(u32, @intCast(8 * d)), seen.count());
    }
}
