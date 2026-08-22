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
//! barracuda), joined back with a stub. That is the right answer for a chip
//! pad, which is smaller than the grid anyway, and the wrong one for a big pad:
//! a buck's exposed thermal pad is millimetres across, so a site a couple of
//! tenths off its centre is still deep inside its own copper — clear of the
//! neighbour that refused the centre, needing no stub, and invisible to a
//! search that only ever steps by the grid. Measured on barracuda's
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

const std = @import("std");
const pad_shape = @import("pad_shape.zig");

const thermal_barrel_samples: usize = 8;

/// Whether a regular thermal-via site's complete barrel stays inside the
/// exposed pad's real outline.
pub fn thermalBarrelFits(pad: pad_shape.Shape, point: [2]f64, via_dia: f64) bool {
    const r = via_dia / 2;
    if (pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, point[0], point[1], std.math.inf(f64)) > 0) return false;
    for (0..thermal_barrel_samples) |i| {
        const a = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(thermal_barrel_samples)) * std.math.tau;
        if (pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, point[0] + r * @cos(a), point[1] + r * @sin(a), std.math.inf(f64)) > 0) return false;
    }
    return true;
}
const numeric = @import("../numeric.zig");

/// In-pad scan step as a fraction of the via's copper DIAMETER. A quarter of a
/// 0.4 mm via is 0.1 mm — fine enough to find the legal band beside a crowding
/// neighbour (the barracuda thermal pad's is 0.275 mm off centre) without
/// turning a 1.7 mm pad into thousands of probes.
const step_frac: f64 = 0.25;
/// Floor on that step (mm), so a hairline via diameter cannot make the scan
/// unbounded.
const min_step_mm: f64 = 0.05;
/// Hard cap on how many rings the scan walks, whatever the pad measures, so a
/// huge pour-like land cannot turn one stitch into an unbounded probe. Sixteen
/// rings reach 1.6 mm from the anchor at the default step — past any pad this
/// exists for, and measured as the right value rather than guessed: cutting it
/// to six lost black-canyon five routed nets and straps three, while saving only
/// 2% of the corpus wall clock, because the cost is the ROUTE the moved vias
/// produce and not the probes themselves.
const max_ring: usize = 16;
/// Compass samples taken around the via barrel when testing that it stays
/// inside the pad's copper. Eight is enough to reject any site whose barrel
/// crosses a straight pad edge or a simplified outline's corner.
const barrel_samples: usize = 8;

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
    /// it cannot be anything else. Barracuda's `J1` is a 1.27 mm-pitch
    /// board-to-board connector whose B.Cu fingers are 1.0 x **0.35 mm**, and
    /// the board's via is 0.4 mm: no point of that pad can hold the barrel,
    /// because the pad is narrower than the barrel is wide. Its GND finger
    /// (pad 40) therefore reads as having no in-pad site, while every ring of
    /// the fan outside it is walled by the neighbours 0.635 mm away — so the
    /// pad ships as its own one-pad copper island, which is exactly what
    /// barracuda's last open GND gap was. The board the design is checked
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

    /// Is the whole via barrel centred at `p` inside this pad's copper?
    fn barrelInside(self: InPad, p: [2]f64) bool {
        if (!self.inCopper(p[0], p[1])) return false;
        for (0..barrel_samples) |i| {
            const a = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(barrel_samples)) * std.math.tau;
            if (!self.inCopper(p[0] + self.r * @cos(a), p[1] + self.r * @sin(a))) return false;
        }
        return true;
    }

    /// Is (x,y) on the pad's copper? `pad_shape.pointDist` is 0 exactly there —
    /// inside the box for a simple pad, inside the real outline for a custom
    /// one — and an infinite slack keeps the outline test from being skipped.
    fn inCopper(self: InPad, x: f64, y: f64) bool {
        const s = self.shape;
        return pad_shape.pointDist(s.x0, s.y0, s.x1, s.y1, s.poly, x, y, std.math.inf(f64)) <= 0;
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
    // barracuda's `J1` GND finger and the board's 0.4/0.2 via: 1.00 x 0.35 mm,
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
