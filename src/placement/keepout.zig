//! `(net-class … (keepout MM [(escape MM)]))` enforcement predicates, shared by
//! the DRC check (`drc_keepout.zig`) and the maze router (`router.zig`) so both
//! answer the same three questions the same way:
//!
//!   • Does this board declare a keepout at all? (`anyDeclared` — the early-out
//!     that keeps a board without one byte-identical and free.)
//!   • How wide is net N's halo, and how far around its own pads is that halo
//!     suspended? (`haloOf` / `escapeOf`.)
//!   • Is net N copper the halo never applies to? (`exempt`.)
//!
//! The semantics the two engines implement from these:
//!
//!   1. **Same layer only.** Foreign copper owes the halo on the layer that
//!      copper is on. A track crossing UNDER an RF trace on the other side of
//!      the board is legal by design — the board is the shield. A through via's
//!      barrel occupies every layer, so it still owes the halo.
//!   2. **Ground is never an aggressor.** A ground/plane-carried net is exempt:
//!      a GND stitching via or a coplanar ground pour beside an RF trace is the
//!      wanted fence, not an intrusion. This is why neither engine needs to know
//!      a via's fence provenance (`via_fence`'s `f` tag stays a reporting-only
//!      label) — being ground is the whole qualification.
//!   3. **A class never holds ITSELF off** (`sameClass`). The halo is declared
//!      on a `(net-class …)`, and that class's members are by definition one
//!      signal family — the chain through a filter, the two halves of a
//!      differential pair, an oscillator's two legs. They run adjacent because
//!      the circuit says so: barracuda's `OSCINP`/`OSCINM` must, and its
//!      0402 filter chain (`RF1_VCO`↔`RF1_DCBLK`, …) sits at 0.19–0.25 mm pad
//!      gaps, far inside any useful halo. Applied to them the halo starves the
//!      copper it exists to protect — measured 2026-08-03 on barracuda, a
//!      `(keepout 0.5)` on the `rf` class cost 8 of 86 routed nets, most of them
//!      rf-class members blocked by each OTHER, and DRC'd 65 warnings whose
//!      majority were same-class pairs. With the exemption the same declaration
//!      costs NOTHING: re-measured the same day on the same harness, barracuda's
//!      `rf` class at `(keepout 0.5)` closes to the baseline's own fixed point
//!      net for net with zero keepout warnings, and barracuda now declares it.
//!      Intra-class spacing is governed by the class's own `(clearance …)`, which
//!      this exemption never relaxes. Two DIFFERENT classes still hold each other
//!      off — the warnings that survive on that board are exactly those, a rail
//!      against an RF net and an LVDS pair against the oscillator legs — and an
//!      unclassed net matches nothing (a halo only ever comes from a class, so a
//!      guard always has one).
//!   4. **Escape exemption, NET-GATED.** Within `escapeOf` of one of the keepout
//!      net's own pad terminals the halo is suspended — but only for the nets the
//!      exemption exists for: a net with a pad of its OWN inside that same zone,
//!      i.e. the neighbour pin on the same IC that has to get out past the RF pad.
//!      A net merely passing through gets no passage. Ungated, the zones around
//!      two RF pads of one filter overlap into an open corridor straight between
//!      the pads, and a foreign trace threads it — the exemption cancelling the
//!      very halo it was carved out of. `Zones` is the router's precomputed form
//!      of the gate and `escapeAdmits` the DRC's direct one; both answer the same
//!      question. Exempt copper still owes ordinary clearance, which no part of
//!      this module relaxes.
//!   5. **Pads guard but never offend.** A keepout net's own component pads are
//!      protected copper, on their SMD face or every layer for a through pad.
//!      Foreign pads still never count as intrusions: placement owns their
//!      positions, and only foreign TRACKS and VIAS can offend a halo.
//!
//! Why the router gives the halo its OWN node mask (`router.KeepState.layers`)
//! rather than stamping it into the existing `resv` reservation grid: `resv`
//! blocks purely on net-id mismatch, and the same array carries the ordinary
//! clearance halo that ground must still respect. There is no way to waive one
//! and keep the other, so a ground net would be refused by exactly the fence it
//! was asked to build. A separate lane makes the exemption one boolean per
//! routing net (`exempt`) and costs nothing on a board that declares no keepout:
//! the mask is an empty slice and every test short-circuits on its length.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const net_name = @import("../net_name.zig");

/// Does any net on this board resolve to a `(keepout MM)`? False ⇒ every
/// keepout code path is skipped entirely, so a board that declares none pays
/// one slice walk and nothing else.
pub fn anyDeclared(placement: optimizer.Placement) bool {
    for (placement.rules.net) |r| {
        if (r.rf.keepout_mm > 0) return true;
    }
    return false;
}

/// Net `net_i`'s resolved same-layer halo (mm); 0 = no keepout declared, which
/// every caller treats as "this net is not a keepout net".
pub fn haloOf(placement: optimizer.Placement, net_i: usize) f64 {
    if (net_i >= placement.rules.net.len) return 0;
    return placement.rules.net[net_i].rf.keepout_mm;
}

/// The radius (mm) around net `net_i`'s OWN pad terminals within which its halo
/// is suspended. Always concrete: `(keepout … (escape MM))`'s inherit sentinel is
/// collapsed during resolution (see `optimizer.Rf.keepout_escape_mm`), so there
/// is nothing to derive here.
pub fn escapeOf(placement: optimizer.Placement, net_i: usize) f64 {
    if (net_i >= placement.rules.net.len) return 0;
    return placement.rules.net[net_i].rf.keepout_escape_mm;
}

/// Is net `net_i` copper a keepout halo never applies to — i.e. ground or
/// plane-carried copper?
pub fn exempt(placement: optimizer.Placement, net_i: usize) bool {
    if (net_i >= placement.nets.len) return false;
    return exemptName(placement.rules, placement.nets[net_i].name);
}

/// `exempt` over a raw net name — the union of the ground-name predicate and the
/// declared `(plane …)`/`(pour …)` net list. That union is deliberately wider
/// than `router.netHasPlane` alone: with no `(stackup …)` form `netHasPlane`
/// already IS the ground-name test, and with one, a ground net that the board
/// chose not to pour still must not be treated as an RF aggressor. Erring toward
/// exempt is the safe direction — it can only ever drop a finding for ground
/// copper, never invent one.
pub fn exemptName(rules: optimizer.BoardRules, name: []const u8) bool {
    if (optimizer.isGroundName(leaf(name))) return true;
    const planes = rules.plane_nets orelse return false;
    for (planes) |pn| {
        if (std.ascii.eqlIgnoreCase(pn, name) or std.ascii.eqlIgnoreCase(pn, leaf(name))) return true;
    }
    return false;
}

/// Per-net `(net-class …)` identity, interned to a dense id: **0 = no authored
/// class**, 1.. = one id per distinct class name (case-insensitively, matching
/// `diff_pairs`'s own class join). Empty when no net declares a keepout — the
/// same early-out `halos` takes, so a board without one pays nothing.
///
/// Interned rather than compared by name because the router asks this per grid
/// node; the loop is O(nets x distinct classes) once per route, and a board has a
/// handful of classes.
pub fn classIds(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]const u32 {
    if (!anyDeclared(placement)) return &.{};
    const out = try arena.alloc(u32, placement.nets.len);
    var names: std.ArrayList([]const u8) = .empty;
    for (out, 0..) |*id, i| {
        id.* = 0;
        if (i >= placement.rules.net.len) continue;
        const name = placement.rules.net[i].class.name;
        if (name.len == 0) continue;
        id.* = for (names.items, 0..) |seen, k| {
            if (std.ascii.eqlIgnoreCase(seen, name)) break @as(u32, @intCast(k + 1));
        } else id: {
            try names.append(arena, name);
            break :id @intCast(names.items.len);
        };
    }
    return out;
}

/// Net `net`'s class id from a `classIds` table; 0 (unclassed) for the no-net
/// (-1) sentinel, an id past the table, or an empty table.
fn classAt(table: []const u32, net: i32) u32 {
    if (net < 0) return 0;
    const i: usize = @intCast(net);
    return if (i < table.len) table[i] else 0;
}

/// Are nets `a` and `b` members of the SAME authored class — the pairing no
/// keepout halo applies to (rule 3)? False when either is unclassed, so an
/// absent/empty table (a board with no keepout, or a client blob that predates
/// the class field crossing the bridge) simply enforces the halo as before.
pub fn sameClass(table: []const u32, a: i32, b: i32) bool {
    const ca = classAt(table, a);
    return ca != 0 and ca == classAt(table, b);
}

/// The router's cached form of `sameClass`: which net is routing, against the
/// per-net class table. The enforcement points inside the maze see only the
/// OBSTACLE's net, so the other half of the pair is carried here and refreshed
/// once per net (`setNetParams`), exactly like the ground-exemption flag beside
/// it. Inert by default — no table and no current net waive nothing.
pub const ClassGate = struct {
    ids: []const u32 = &.{},
    cur: i32 = -1,

    /// Is the halo declared on `net` waived for the net currently routing,
    /// because the two are members of one class (rule 3)?
    pub fn waives(self: ClassGate, net: i32) bool {
        return sameClass(self.ids, net, self.cur);
    }
};

/// The net-indexed halo table the router carries (`router.KeepState.nets`), or
/// empty when no net declares a keepout — the early-out that keeps a board
/// without one routing byte-identically.
pub fn halos(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]const f64 {
    if (!anyDeclared(placement)) return &.{};
    const out = try arena.alloc(f64, placement.nets.len);
    for (out, 0..) |*h, i| h.* = haloOf(placement, i);
    return out;
}

/// Net `net`'s halo (mm) from a `halos` table; 0 for the no-net (-1) sentinel or
/// an id past the table.
pub fn haloAt(table: []const f64, net: i32) f64 {
    if (net < 0) return 0;
    const i: usize = @intCast(net);
    return if (i < table.len) table[i] else 0;
}

/// Extra edge-to-edge separation (mm) an obstacle on `obstacle_net` demands over
/// `clearance`, because that net declared a keepout. Zero when nothing is
/// declared, when the clearance is already the wider rule, or when the routing
/// net is exempt (ground/plane copper is the wanted fence, not an intruder).
pub fn extraOver(table: []const f64, obstacle_net: i32, clearance: f64, is_exempt: bool) f64 {
    if (is_exempt) return 0;
    return @max(0, haloAt(table, obstacle_net) - clearance);
}

/// Is node `node` of a halo `lane` claimed by a net whose halo `net` actually
/// OWES — another net's, and not a fellow member of `net`'s own class (`classes`,
/// a `classIds` table). `-1` is the unclaimed sentinel, matching the router's
/// `empty_cell` so one grid encoding serves the occupancy, reservation and
/// keepout lanes alike.
pub fn claimed(lane: []const i32, classes: []const u32, node: usize, net: i32) bool {
    if (node >= lane.len) return false;
    return lane[node] != -1 and lane[node] != net and !sameClass(classes, lane[node], net);
}

/// The largest halo any net declares, from a `halos` table — the conservative
/// bound the router sizes its copper/pad index reach with, so a halo-only
/// obstacle is still a candidate before the per-pair test applies the rule.
pub fn maxHalo(table: []const f64) f64 {
    var widest: f64 = 0;
    for (table) |halo| widest = @max(widest, halo);
    return widest;
}

/// A pad as the keepout rule reads it. Every pad contributes its net + world
/// centre to the escape gate. `guard` pads additionally carry their exact world
/// copper shape and face so DRC can protect a keepout net's own pad copper.
/// Gate-only fixtures leave `guard` false and need not provide the shape.
const PadGuard = struct {
    bounds: [4]f64,
    poly: []const [2]f64 = &.{},
    layer: u8 = 0,
    thru: bool = false,
};

/// Net + world centre for every escape terminal, with exact guarded copper
/// attached when this pad belongs to a real placed component.
pub const PadPt = struct {
    net: i32,
    x: f64,
    y: f64,
    guard: ?PadGuard = null,
};

/// One escape zone: the disc of radius `r` around pad `(x, y)` of keepout net
/// `net`, inside which that net's halo is suspended for the nets the zone admits.
pub const Zone = struct { net: i32, x: f64, y: f64, r: f64 };

/// The router's precomputed escape gate. The maze cannot afford `escapeAdmits`
/// per grid node per relax, so the zones are built once per route and the
/// "does the net being routed own a pad in this zone" answer is refreshed once
/// per net (`admitCurrent`) into `ok`, leaving the per-node test an array read.
///
/// `at` is net-indexed: `at[net]` is the `[lo, hi)` range of `all` belonging to
/// that net, so a halo stamper scans only its OWN net's zones. Empty everywhere
/// when no net declares a keepout with an escape radius.
pub const Zones = struct {
    all: []const Zone = &.{},
    at: []const [2]u32 = &.{},
    ok: []bool = &.{},

    /// Zones belonging to `net` (the ones its own halo stamp may open).
    pub fn of(self: Zones, net: i32) []const Zone {
        if (net < 0) return &.{};
        const i: usize = @intCast(net);
        if (i >= self.at.len) return &.{};
        return self.all[self.at[i][0]..self.at[i][1]];
    }

    /// Index into `all` (and `ok`) of `net`'s first zone — the base a stamper
    /// adds its local zone offset to when it encodes a gate.
    pub fn base(self: Zones, net: i32) u32 {
        if (net < 0) return 0;
        const i: usize = @intCast(net);
        return if (i < self.at.len) self.at[i][0] else 0;
    }

    /// Does zone `index` admit the net `admitCurrent` was last called for?
    pub fn admits(self: Zones, index: usize) bool {
        return index < self.ok.len and self.ok[index];
    }

    /// Does one of keepout net `net`'s own escape zones cover `(x, y)` AND admit
    /// the net `admitCurrent` was last called for? The maze's per-pad form of the
    /// gate; ordinary pad clearance is never relaxed by it.
    pub fn admitsAt(self: Zones, net: i32, x: f64, y: f64) bool {
        const first = self.base(net);
        for (self.of(net), 0..) |z, i| {
            if (std.math.hypot(x - z.x, y - z.y) <= z.r and self.admits(first + i)) return true;
        }
        return false;
    }
};

/// Gather every keepout net's escape zones from `pads`. A net with no halo, no
/// escape radius, or no pads contributes none, so `all` is empty on the boards
/// that declare nothing and the gate costs one allocation of two empty slices.
pub fn buildZones(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    pads: []const PadPt,
) std.mem.Allocator.Error!Zones {
    if (!anyDeclared(placement)) return .{};
    var all: std.ArrayList(Zone) = .empty;
    const at = try arena.alloc([2]u32, placement.nets.len);
    for (at, 0..) |*range, ni| {
        const lo: u32 = @intCast(all.items.len);
        const r = escapeOf(placement, ni);
        if (haloOf(placement, ni) > 0 and r > 0) {
            const id: i32 = @intCast(ni);
            for (pads) |p| {
                if (p.net == id) try all.append(arena, .{ .net = id, .x = p.x, .y = p.y, .r = r });
            }
        }
        range.* = .{ lo, @intCast(all.items.len) };
    }
    return .{ .all = all.items, .at = at, .ok = try arena.alloc(bool, all.items.len) };
}

/// Does an approach that comes within `gap` of `net`'s copper, at point `at`,
/// stand? `limits` is `{ ordinary clearance, ordinary + net's halo }`, both
/// already relaxed by the caller's float epsilon.
///
/// The ordinary clearance is absolute. The halo SURPLUS above it is waived when
/// `at` falls inside one of `net`'s own escape zones that admits the net now
/// routing (rule 4) — so an approach inside the zone is held to plain clearance
/// and one outside it to the full halo.
///
/// The maze has carried this carve-out since the halo was introduced (its mask
/// records a zone code per node) and so has `drc_keepout`, which drops a finding
/// whose approach point a zone admits. The router's direct / dogleg / taut
/// probes measure their own geometry and so have to ask here, or they refuse
/// copper the board's own DRC accepts: the neighbour pin escaping past an RF
/// pad, which is the one case the escape radius exists for. Measured on
/// barracuda — the REF_LMX LVDS pair's hop between its own two pad terminals
/// runs 0.64 mm from the RF-side track of the AC-coupling cap it lands on,
/// inside that cap's own escape zone, and the 0.78 mm halo refused it, so the
/// coupled construction never got a candidate out of its own pad field.
pub fn approachClears(zones: Zones, net: i32, gap: f64, at: [2]f64, limits: [2]f64) bool {
    if (gap < limits[0]) return false;
    return gap >= limits[1] or zones.admitsAt(net, at[0], at[1]);
}

/// The keepout half of ONE raster stamp: whose halo the maze is laying, and the
/// radius inside which that stamp is the ordinary clearance every net owes
/// rather than the halo. Inert by default — an infinite plain radius makes the
/// whole claim ordinary, so a stamp carrying no halo consults no zone.
pub const Band = struct {
    net: i32 = -1,
    plain: f64 = std.math.inf(f64),
};

/// Does an obstacle's stamp of squared outer radius `full_sq` claim the node at
/// `at`, squared distance `dsq` away? Inside `band.plain` the claim is the
/// ordinary clearance and always stands; between there and `full_sq` it is the
/// keepout SURPLUS, which stands down where one of `band.net`'s own escape zones
/// covers the node and admits the net now routing.
///
/// The raster twin of `approachClears`, and what makes a DERIVED router context
/// enforce the keepout the whole-board one does. The whole-board pass gives the
/// halo its own node mask with a per-node gate; a windowed retry or a gap hop
/// has no such mask (its lattice differs) and takes its keepout from the
/// obstacle stamp instead — so without this split, an escape the greedy pass
/// takes past an RF trace, which the DRC and the direct probes both accept, is
/// refused by every rescue. Squared distances throughout, and `inline` so the
/// zone/band structs never marshal: the raster evaluates this for millions of
/// nodes per board-wide re-stamp, and an out-of-line call there measured a
/// multiple of the whole finishing pass on a board declaring no keepout at all.
pub inline fn bandClaims(zones: Zones, band: Band, dsq: f64, full_sq: f64, at: [2]f64) bool {
    if (dsq > full_sq) return false;
    return dsq <= band.plain * band.plain or !zones.admitsAt(band.net, at[0], at[1]);
}

/// Re-aim the per-net escape gate at `net`, tracking whose it currently answers
/// for in `cur` — the caller's `ClassGate.cur`, which its own per-net setup
/// already leaves pointing at the net it configured, so a no-op costs one
/// comparison.
///
/// `admitCurrent` alone is enough for a router that configures once per net. A
/// COUPLED diff pair is the exception: it routes its envelope as the P net and
/// then probes each leg as its OWN net, so the gate has to move with it. Judged
/// through its twin's gate a leg is refused inside an escape zone its own pad
/// sits in — measured on barracuda, where the N leg's hop between its two pad
/// terminals is 0.64 mm from the RF pad of the cap it lands on while its twin's
/// nearest pad is 1.02 mm away, two hundredths outside the 1 mm escape radius.
pub fn aimAt(zones: Zones, pads: []const PadPt, cur: *i32, net: i32) void {
    if (zones.ok.len == 0 or cur.* == net) return;
    cur.* = net;
    admitCurrent(zones, pads, net);
}

/// Refresh `zones.ok` for the net about to route: a zone admits `net` only when
/// `net` owns a pad inside it. A zone's own keepout net is never marked — the
/// halo's owner passes through it regardless, so spending the flag on it would
/// only mask the gate.
pub fn admitCurrent(zones: Zones, pads: []const PadPt, net: i32) void {
    if (zones.ok.len == 0) return;
    @memset(zones.ok, false);
    if (net < 0) return;
    for (pads) |p| {
        if (p.net != net) continue;
        for (zones.all, zones.ok) |z, *ok| {
            if (z.net == net or ok.*) continue;
            if (std.math.hypot(p.x - z.x, p.y - z.y) <= z.r) ok.* = true;
        }
    }
}

/// The DRC's direct form of the gate: is `(x, y)` covered by an escape zone —
/// radius `radius` around one of `zone_pads`, a keepout net's own pad centres —
/// that admits copper on `net`, because `net` has a pad of its own in the same
/// zone? A zero/negative radius admits nothing.
pub fn escapeAdmits(
    pads: []const PadPt,
    zone_pads: []const [2]f64,
    radius: f64,
    x: f64,
    y: f64,
    net: i32,
) bool {
    if (!(radius > 0)) return false;
    for (zone_pads) |z| {
        if (std.math.hypot(x - z[0], y - z[1]) > radius) continue;
        for (pads) |p| {
            if (p.net != net) continue;
            if (std.math.hypot(p.x - z[0], p.y - z[1]) <= radius) return true;
        }
    }
    return false;
}

/// The net name's leaf after the last '/' (the sub-block flatten prefix), so a
/// module-local `buck/GND` reads as ground exactly like a board-level `GND`.
const leaf = net_name.leaf;

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A placement carrying just the net names + per-net rules these predicates read.
fn fixture(nets: []const optimizer.FlatNet, rules: []const optimizer.NetRule) optimizer.Placement {
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
        .rules = .{ .net = rules },
    };
}

// spec: placement/drc - a declared keepout halo and its escape radius resolve per net, and a board declaring none reports so
test "keepout declaration, halo and escape radius resolve per net" {
    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF_IN", .pins = &.{} },
        .{ .name = "SPI_SCK", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{ .rf = .{ .keepout_mm = 0.5, .keepout_escape_mm = 1.0 } },
        .{},
    };
    const p = fixture(&nets, &rules);
    try testing.expect(anyDeclared(p));
    try testing.expectEqual(@as(f64, 0.5), haloOf(p, 0));
    try testing.expectEqual(@as(f64, 1.0), escapeOf(p, 0));
    // The unclassed net declares nothing, and so does an out-of-range index.
    try testing.expectEqual(@as(f64, 0), haloOf(p, 1));
    try testing.expectEqual(@as(f64, 0), escapeOf(p, 1));
    try testing.expectEqual(@as(f64, 0), haloOf(p, 9));
    try testing.expectEqual(@as(f64, 0), escapeOf(p, 9));
    // A board with no keepout class at all takes the early-out.
    const plain = [_]optimizer.NetRule{ .{ .width = 0.2 }, .{} };
    try testing.expect(!anyDeclared(fixture(&nets, &plain)));
    try testing.expect(!anyDeclared(fixture(&nets, &.{})));
}

// spec: placement/drc - a ground-named or plane-carried net is exempt from every keepout halo
test "ground and declared plane nets are keepout-exempt, signal nets are not" {
    const nets = [_]optimizer.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "buck/AGND2", .pins = &.{} },
        .{ .name = "SPI_SCK", .pins = &.{} },
        .{ .name = "V_3V3", .pins = &.{} },
    };
    var p = fixture(&nets, &.{});
    // No stackup form: the ground-name predicate alone answers (numbered and
    // sub-block-prefixed grounds included), and a poured rail is not yet known.
    try testing.expect(exempt(p, 0));
    try testing.expect(exempt(p, 1));
    try testing.expect(!exempt(p, 2));
    try testing.expect(!exempt(p, 3));
    try testing.expect(!exempt(p, 9)); // out of range
    // A declared plane on the rail exempts it too — a poured V_3V3 beside an RF
    // trace is a reference plane, not an aggressor.
    const planes = [_][]const u8{"V_3V3"};
    p.rules = .{ .plane_nets = &planes };
    try testing.expect(exempt(p, 3));
    try testing.expect(!exempt(p, 2));
    try testing.expect(exempt(p, 0)); // ground stays exempt whatever the stackup pours
}

// spec: placement/drc - net-class identity interns per net so the keepout exemption pairs one class's own members case-insensitively and nobody else
test "sameClass pairs a class's own members and nobody else" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF1_VCO", .pins = &.{} },
        .{ .name = "RF1_DCBLK", .pins = &.{} },
        .{ .name = "REF_CLK", .pins = &.{} },
        .{ .name = "SPI_SCK", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .keepout_mm = 0.5 } },
        // Spelled differently on purpose: class identity joins case-insensitively,
        // the way `diff_pairs` already pairs two legs of one class.
        .{ .class = .{ .name = "RF" }, .rf = .{ .keepout_mm = 0.5 } },
        .{ .class = .{ .name = "clk" }, .rf = .{ .keepout_mm = 0.3 } },
        .{},
    };
    const ids = try classIds(arena, fixture(&nets, &rules));
    try testing.expectEqual(@as(usize, 4), ids.len);
    try testing.expectEqual(classAt(ids, 0), classAt(ids, 1)); // one class, two spellings
    try testing.expect(classAt(ids, 2) != classAt(ids, 0));
    try testing.expectEqual(@as(u32, 0), classAt(ids, 3)); // unclassed
    try testing.expectEqual(@as(u32, 0), classAt(ids, -1)); // the no-net sentinel
    try testing.expectEqual(@as(u32, 0), classAt(ids, 9)); // past the table

    // The filter-chain pairing the exemption exists for.
    try testing.expect(sameClass(ids, 0, 1));
    try testing.expect(sameClass(ids, 1, 0));
    // A DIFFERENT class still owes the halo, and an unclassed net matches nothing
    // — including another unclassed net.
    try testing.expect(!sameClass(ids, 0, 2));
    try testing.expect(!sameClass(ids, 0, 3));
    try testing.expect(!sameClass(ids, 3, 3));
    try testing.expect(!sameClass(ids, -1, 0));

    // A board declaring no keepout builds no table, and an empty table pairs
    // nobody — so every caller falls back to enforcing the halo.
    const plain = [_]optimizer.NetRule{ .{ .class = .{ .name = "rf" } }, .{ .class = .{ .name = "rf" } }, .{}, .{} };
    const none = try classIds(arena, fixture(&nets, &plain));
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expect(!sameClass(none, 0, 1));
}

// spec: placement/drc - the keepout escape exemption suspends the halo within its radius of the net's own pads, and only for a net with its own pad in that zone
test "escapeAdmits gates the pad neighbourhood on the intruder owning a pad there" {
    const zone_pads = [_][2]f64{ .{ 10, 10 }, .{ 20, 10 } };
    // Net 1 has a pad beside the RF pad at (10,10) — the neighbour-pin case the
    // exemption exists for — so it is admitted inside that zone.
    const pads = [_]PadPt{ .{ .net = 0, .x = 10, .y = 10 }, .{ .net = 1, .x = 10.6, .y = 10 } };
    try testing.expect(escapeAdmits(&pads, &zone_pads, 1.0, 10.5, 10, 1));
    try testing.expect(escapeAdmits(&pads, &zone_pads, 1.0, 10, 10.9, 1));
    // Net 2 has no pad anywhere near: the same cell gives it no passage.
    try testing.expect(!escapeAdmits(&pads, &zone_pads, 1.0, 10.5, 10, 2));
    // And net 1's own pad is in the (10,10) zone ONLY — the zone at (20,10) is
    // still closed to it, so the exemption stays local to the pad it belongs to.
    try testing.expect(!escapeAdmits(&pads, &zone_pads, 1.0, 20, 10.9, 1));
    // Outside every zone nothing is admitted...
    try testing.expect(!escapeAdmits(&pads, &zone_pads, 1.0, 15, 10, 1));
    // ...nor with an undeclared escape, even right on the pad, nor with no zones.
    try testing.expect(!escapeAdmits(&pads, &zone_pads, 0, 10, 10, 1));
    try testing.expect(!escapeAdmits(&pads, &.{}, 1.0, 10, 10, 1));
}

// spec: placement/router - the router's escape gate is built once per route and admits, per net, only the zones that net owns a pad inside
test "buildZones ranges per net and admitCurrent flags only the zones the net has a pad in" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF_IN", .pins = &.{} },
        .{ .name = "SPI_SCK", .pins = &.{} },
        .{ .name = "SPI_MOSI", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{ .rf = .{ .keepout_mm = 0.5, .keepout_escape_mm = 1.0 } },
        .{},
        .{},
    };
    // Two RF pads 3 mm apart, a SCK pad beside the first, a MOSI pad far away.
    const pads = [_]PadPt{
        .{ .net = 0, .x = 10, .y = 10 },
        .{ .net = 0, .x = 13, .y = 10 },
        .{ .net = 1, .x = 10.6, .y = 10 },
        .{ .net = 2, .x = 30, .y = 30 },
    };
    const zones = try buildZones(arena, fixture(&nets, &rules), &pads);
    // Only the keepout net has zones, one per pad of its own.
    try testing.expectEqual(@as(usize, 2), zones.all.len);
    try testing.expectEqual(@as(usize, 2), zones.of(0).len);
    try testing.expectEqual(@as(usize, 0), zones.of(1).len);
    try testing.expectEqual(@as(u32, 0), zones.base(0));

    // SCK owns a pad in the first zone and nothing in the second.
    admitCurrent(zones, &pads, 1);
    try testing.expect(zones.admits(0));
    try testing.expect(!zones.admits(1));
    // MOSI owns a pad in neither, so every zone stays shut to it.
    admitCurrent(zones, &pads, 2);
    try testing.expect(!zones.admits(0));
    try testing.expect(!zones.admits(1));
    // The keepout net's own zones are never flagged — its owner passes anyway.
    admitCurrent(zones, &pads, 0);
    try testing.expect(!zones.admits(0));
    // A board declaring no keepout builds no gate at all.
    const plain = [_]optimizer.NetRule{ .{}, .{}, .{} };
    try testing.expectEqual(@as(usize, 0), (try buildZones(arena, fixture(&nets, &plain), &pads)).all.len);
}

/// Two RF pads 6 mm apart with 1 mm escape zones, plus a neighbour pad for net 1
/// beside the first and one for net 2 beside the second — the "each pin escapes
/// past the RF pad ON ITS OWN PART" arrangement both new predicates are about.
fn gateFixture(arena: std.mem.Allocator) std.mem.Allocator.Error!struct { Zones, []const PadPt } {
    const nets = [_]optimizer.FlatNet{
        .{ .name = "RF_IN", .pins = &.{} },
        .{ .name = "LVDS_P", .pins = &.{} },
        .{ .name = "LVDS_N", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{ .rf = .{ .keepout_mm = 0.5, .keepout_escape_mm = 1.0 } },
        .{},
        .{},
    };
    const pads = try arena.dupe(PadPt, &[_]PadPt{
        .{ .net = 0, .x = 3, .y = 5 },
        .{ .net = 0, .x = 9, .y = 5 },
        .{ .net = 1, .x = 3.6, .y = 5 },
        .{ .net = 2, .x = 9.6, .y = 5 },
    });
    return .{ try buildZones(arena, fixture(&nets, &rules), pads), pads };
}

// spec: placement/router - a measured approach to a keepout net's copper is held to its ordinary clearance inside an escape zone that admits the routing net, and to the full halo everywhere else
test "approachClears waives only the halo surplus, and only inside an admitting escape zone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const zones, const pads = try gateFixture(arena_inst.allocator());
    // Ordinary clearance 0.29, halo 0.66 — the band between them is what an
    // escape zone may waive, and nothing else is.
    const limits = [2]f64{ 0.29, 0.66 };

    admitCurrent(zones, pads, 1);
    // Inside net 1's own zone (around the RF pad at 3,5) the halo surplus stands
    // down, so an approach that only meets the ordinary clearance is legal...
    try testing.expect(approachClears(zones, 0, 0.45, .{ 2.7, 5.2 }, limits));
    // ...while the ordinary clearance under it is never waived, zone or not.
    try testing.expect(!approachClears(zones, 0, 0.20, .{ 2.7, 5.2 }, limits));
    // Away from every zone the full halo is owed for the same gap.
    try testing.expect(!approachClears(zones, 0, 0.45, .{ 6.0, 5.2 }, limits));
    // A gap that meets the halo outright never consults the gate at all.
    try testing.expect(approachClears(zones, 0, 0.7, .{ 6.0, 5.2 }, limits));
    // Net 2 owns no pad in the first zone, so that opening is not its to use —
    // and net 1 owns none in the second, which is the other half of the gate.
    admitCurrent(zones, pads, 2);
    try testing.expect(!approachClears(zones, 0, 0.45, .{ 2.7, 5.2 }, limits));
    try testing.expect(approachClears(zones, 0, 0.45, .{ 8.7, 5.2 }, limits));
}

// spec: placement/router - an obstacle's raster stamp always claims the ordinary clearance under its keepout halo and claims the surplus above it only where no admitting escape zone covers the node
test "bandClaims splits an obstacle's stamp at the keepout boundary" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const zones, const pads = try gateFixture(arena_inst.allocator());
    // Ordinary clearance 0.4, halo 0.7 — squared, as the raster measures.
    const full_sq: f64 = 0.49;
    const band = Band{ .net = 0, .plain = 0.4 };

    admitCurrent(zones, pads, 1);
    // In the surplus band (0.55 mm out) inside net 1's own zone: not claimed…
    try testing.expect(!bandClaims(zones, band, 0.3025, full_sq, .{ 3, 5.55 }));
    // …the same offset away from every zone: claimed.
    try testing.expect(bandClaims(zones, band, 0.3025, full_sq, .{ 6, 5.55 }));
    // The ordinary clearance under the halo is claimed zone or not…
    try testing.expect(bandClaims(zones, band, 0.09, full_sq, .{ 3, 5.3 }));
    // …and past the halo nothing is claimed anywhere.
    try testing.expect(!bandClaims(zones, band, 0.64, full_sq, .{ 3, 5.8 }));
    // Net 2 owns no pad in that zone, so the opening is not its to use.
    admitCurrent(zones, pads, 2);
    try testing.expect(bandClaims(zones, band, 0.3025, full_sq, .{ 3, 5.55 }));
    // An inert band (every other stamper's) claims its whole disc and asks no zone.
    try testing.expect(bandClaims(zones, .{}, 0.3025, full_sq, .{ 3, 5.55 }));
}

// spec: placement/router - the keepout escape gate re-aims at another net mid-route, so a coupled diff pair judges each leg by the zones its OWN pads sit in and never its twin's
test "aimAt moves the escape gate between two nets and no-ops when it already answers for one" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const zones, const pads = try gateFixture(arena_inst.allocator());
    var cur: i32 = -1;

    // The P leg's gate opens the zone its own pad sits in, and only that one.
    aimAt(zones, pads, &cur, 1);
    try testing.expectEqual(@as(i32, 1), cur);
    try testing.expect(zones.admits(0));
    try testing.expect(!zones.admits(1));
    // Aiming at the N leg moves the gate with it — the whole point: judged
    // through its twin's gate a leg is refused inside its own escape zone.
    aimAt(zones, pads, &cur, 2);
    try testing.expectEqual(@as(i32, 2), cur);
    try testing.expect(!zones.admits(0));
    try testing.expect(zones.admits(1));
    // Re-aiming at the net it already answers for is a no-op, so the memo cannot
    // go stale behind a caller that asks per probe rather than per net.
    aimAt(zones, pads, &cur, 2);
    try testing.expect(zones.admits(1));
    // A board with no escape zones has no gate to move, and the memo stays put.
    var none: i32 = -1;
    aimAt(.{}, pads, &none, 1);
    try testing.expectEqual(@as(i32, -1), none);
}
