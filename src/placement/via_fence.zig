//! RF ground via fencing — the spec-resolution layer for a
//! `(net-class … (fence …))` declaration.
//!
//! A fenced class's routed traces get a flanking row of ground stitching vias
//! on each side, generated on demand once placement and routing have settled
//! (never by the autorouter mid-solve). Authors write only what they mean to
//! pin down: `(fence)` alone is legal, and every child of the form carries a
//! "derive me" sentinel through `env.ClassFence` and `optimizer.FenceRule`
//! untouched. A class that carries `(max-freq …)` but NO `(fence)` is fenced
//! the same way — the Fence action covers "the board's RF traces", and a
//! max-freq net is an RF trace every one of whose fence parameters can be
//! derived. This file answers those sentinels with concrete millimetres:
//!
//! * pitch — a tenth of the guided wavelength implied by the class's
//!   `(max-freq …)`, the standard stitching rule of thumb (λg/10 keeps the
//!   fence electrically continuous at the highest carried frequency),
//! * offset — the gap the fence keeps from the net's COPPER EDGE: the class
//!   clearance plus a small fabrication margin,
//! * via geometry — the class's fence via, else its signal via, else the
//!   board's `(design-rules (via …))`.
//!
//! The resolvers are pure functions of a resolved `NetRule` plus the board's
//! `DesignRules`. On top of them sits `generate`, the on-demand GENERATOR: it
//! gathers each fenced net's persisted copper into one union and marches the
//! resolved pitch around the GUIDE CONTOURS `via_guide` traces around it. It reads a solved
//! `optimizer.Placement` and the layout's copper and returns sites — no raster,
//! no serve layer, no router run — so the whole fence is unit-testable against
//! hand-built fixtures.
//!
//! **A fence wraps copper, not centrelines.** A row measured from the trace's
//! centreline marches straight through the pads the trace lands on — a 0402's
//! land and a QFN's RF pad are both wider than the trace between them — and a
//! trace shielded only along its flanks leaks out of its open ends besides. So
//! what is marched is the closed curve sitting a uniform distance outside the
//! net's whole copper union, the same shape a ground pour's edge takes as it
//! wraps the chain (`via_guide.trace`). The pitch is divided evenly into that one
//! perimeter (`round(L / pitch)` sites, actual spacing `L / n`), so the fence
//! closes with no seam gap and no bunching. In legal mode the same spacing is
//! tried at a few phase offsets around the closed curve and the phase retaining
//! the most legal sites wins; an arbitrary marching-squares start vertex must
//! not make a narrow but usable slot fall between two candidates.
//!
//! How hard a ring site is vetted is the caller's `Mode`:
//!
//!   * `.legal` (the default) — vet each site against the board, where the
//!     governing rule is **gaps are preferred over conflicts**: a candidate that
//!     fails a check is SKIPPED and counted, never forced, and no existing
//!     copper is ever moved or ripped up. A fence with a hole in it is a real
//!     fence; a fence that shorts a trace is scrap. A site landing on a pad of
//!     the STITCH net is not a conflict at all — via-in-pad on ground stitches
//!     that pad straight to the plane, which is exactly what a fence wants.
//!   * `.all` — place every site the ring produced, checking only intra-run
//!     coincidence. This is the raw generator output, for judging the ring
//!     geometry itself; DRC is reported by the serve layer but never acted on.
//!
//! **The prefilter is an exact mirror of `drc.zig`, not an approximation of it.**
//! Its contract is that the fence adds ZERO new error-severity violations while
//! keeping the MAXIMUM number of sites, and both halves of that are lost by
//! guessing: a threshold a rounding step tight drops manufacturable vias, and one
//! measured against the wrong rule lets a shorting via through. So every check in
//! `Pass.illegal` uses the same numbers its `drc.zig` twin does — the pairwise
//! `clearanceBetween` (not the fence net's own class clearance), the same `eps`
//! slack, the same same-net exemptions, the same real pad outline rather than its
//! bounding box, the same capsule geometry for a slot's bore, and the net-blind
//! `hole_to_hole` floor between drills. Footprint-attached via rule areas are an
//! additional authored constraint: their exact pose-transformed polygons reject
//! a candidate whenever any of its copper disc overlaps the forbidden region.
//!
//! Three departures are deliberate, and all three are STRICTER than the checker:
//! the DRC exempts copper staged >10 mm off-board and an exactly coincident pair
//! of drills, and it skips the edge rule outright on a board with no rectangle —
//! a fence via wants none of those, so it is refused there anyway. Nothing in the
//! prefilter is ever LOOSER than the DRC, which is what makes the serve layer's
//! ratchet a backstop rather than the actual filter.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const drc = @import("drc.zig");
const pad_shape = @import("pad_shape.zig");
const via_guide = @import("via_guide.zig");
const outline_mod = @import("outline.zig");
const via_antipad = @import("via_antipad.zig");
const numeric = @import("../numeric.zig");

const NetRule = optimizer.NetRule;
const DesignRules = optimizer.DesignRules;

/// The DRC's own threshold slack, borrowed rather than re-guessed: `drc.zig`
/// reports a rule broken only when the gap is `eps` BELOW it, so a candidate
/// sitting exactly on a rule is legal and the prefilter must keep it.
const eps = drc.eps;

/// The DRC's own same-net predicate: two features may touch only if they share a
/// REAL net. Index -1 ("no net" — a mechanical pad, an unclassed feature) owes
/// clearance to everything, itself included.
fn sameNet(a: i32, b: i32) bool {
    return a == b and a != -1;
}

/// Speed of light in millimetres per second — the board frame is millimetres
/// everywhere, so the wavelength math never leaves it.
pub const c_mm_per_s: f64 = 299792458000;

/// Assumed relative permittivity for the guided-wavelength derivation: plain
/// FR4 at 4.4. The stackup form records no dielectric constant yet, and a fence
/// pitch is a rule of thumb rather than a tuned length, so one FR4 assumption
/// beats demanding a number no design currently declares.
pub const assumed_er: f64 = 4.4;

/// Guided-wavelength fraction a derived fence pitch targets: λg/10, the usual
/// stitching-via spacing rule (a tenth of a wavelength is short enough that the
/// via row still behaves as a continuous ground wall).
pub const pitch_wavelength_divisor: f64 = 10;

/// Fabrication margin (mm) added to the clearance rule when deriving the fence
/// edge gap, so a generated fence clears the net's copper by more than exactly
/// the clearance rule and survives the usual etch/registration slop.
pub const offset_margin_mm: f64 = 0.1;

/// A resolved fence-via geometry in mm: copper diameter + drill diameter.
pub const FenceVia = struct { dia: f64, drill: f64 };

/// The effective copper clearance (mm) for `rule`: the class's `(clearance …)`
/// when it declares one, else the board default.
fn effectiveClearance(rule: NetRule, design: DesignRules) f64 {
    return if (rule.clearance > 0) rule.clearance else design.clearance;
}

/// The guided wavelength (mm) of `freq_hz` in the assumed FR4 dielectric.
/// Returns 0 for a non-positive frequency, so callers need no separate guard.
pub fn guidedWavelengthMm(freq_hz: f64) f64 {
    if (freq_hz <= 0) return 0;
    return c_mm_per_s / (freq_hz * @sqrt(assumed_er));
}

/// The fence via centre-to-centre spacing (mm) along `rule`'s traces: the
/// authored `(fence (pitch MM))` when present, else λg/10 from the class's
/// `(max-freq HZ)`. Returns 0 when the class declares NEITHER — the fence is
/// unresolvable and a generator must report that rather than invent a spacing.
pub fn resolvedPitchMm(rule: NetRule) f64 {
    if (rule.rf.fence.pitch_mm > 0) return rule.rf.fence.pitch_mm;
    return guidedWavelengthMm(rule.rf.max_freq_hz) / pitch_wavelength_divisor;
}

/// The fence via geometry for `rule`: the authored `(fence (via DIA DRILL))`,
/// else the class's own `(via …)` signal geometry, else the board's
/// `(design-rules (via …))`. Diameter and drill fall back independently, so a
/// half-authored `(via 0.45)` keeps the inherited drill.
pub fn resolvedFenceVia(rule: NetRule, design: DesignRules) FenceVia {
    const dia = if (rule.rf.fence.via_dia > 0)
        rule.rf.fence.via_dia
    else if (rule.via_dia > 0) rule.via_dia else design.via_dia;
    const drill = if (rule.rf.fence.via_drill > 0)
        rule.rf.fence.via_drill
    else if (rule.via_drill > 0) rule.via_drill else design.via_drill;
    return .{ .dia = dia, .drill = drill };
}

/// The gap (mm) a fence keeps between the fenced net's COPPER EDGE and the fence
/// via's own copper edge: the authored `(fence (offset MM))` when present, else
/// the tightest legal one — the class clearance + `offset_margin_mm`.
///
/// This is the FENCED class's own answer. A derived gap is raised again at plan
/// time to the pairwise clearance the stitch net and the fenced net owe each other
/// (see `planFor`), because the ground net's own class may ask for more than the RF
/// class does; an authored offset is not.
///
/// This is edge-to-edge on purpose. A number measured from the trace CENTRELINE
/// says nothing about the pads that trace lands on, and a pad is wider than the
/// trace: the same 0.2 mm that clears a 0.3 mm trace buries a via in a 0.6 mm
/// 0402 land. An edge gap holds everywhere along the net's copper at once.
pub fn resolvedGapMm(rule: NetRule, design: DesignRules) f64 {
    if (rule.rf.fence.offset_mm > 0) return rule.rf.fence.offset_mm;
    return effectiveClearance(rule, design) + offset_margin_mm;
}

/// The distance (mm) from the fenced net's copper edge to a fence via's CENTRE —
/// the level `via_guide` traces the guide contour at, i.e. the edge gap plus the
/// via's own radius. Built on `resolvedGapMm`, so it is likewise the fenced class's
/// own answer before `planFor` raises a derived gap to the pairwise rule.
pub fn guideDistMm(rule: NetRule, design: DesignRules) f64 {
    return resolvedGapMm(rule, design) + resolvedFenceVia(rule, design).dia / 2;
}

/// Extra reach (mm) the solder-mask untent test allows a stitch via beyond the
/// resolved fence row distance: the guide contour bulges outward around the
/// pads it wraps and a derived gap may be raised to a pairwise rule, so an
/// exact-distance match would leave legitimate fence vias tented.
pub const mask_untent_slack_mm: f64 = 0.3;

/// Reach (mm) within which a stitch via beside a fenced net's copper counts as
/// part of the fence row for solder-mask untenting; the caller adds the
/// trace's own half-width. Shared by the Gerber mask writer and the viewer
/// blob so the two untent the same vias.
pub fn maskUntentReachMm(rule: NetRule, design: DesignRules) f64 {
    return guideDistMm(rule, design) + mask_untent_slack_mm;
}

/// The centre-to-centre spacing (mm) two adjacent fence vias of geometry `via`
/// may not go below, whatever the class asked for. Two rules bind at once and
/// the tighter one loses:
///
///   * copper — the two rings must clear each other by the board clearance,
///     so `dia + clearance`;
///   * holes — the hole-to-hole DRC is **net-blind** (two GND drills crowd the
///     drill bit exactly as much as two signal drills), so `drill + hole_to_hole`.
///
/// A pitch under this floor cannot be built at any offset, so `generate` clamps
/// up to it and reports the clamp rather than emitting copper that DRCs.
pub fn minPitchMm(via: FenceVia, design: DesignRules) f64 {
    return @max(via.dia + design.clearance, via.drill + design.hole_to_hole);
}

/// Does `via` satisfy the two DRC rules that judge a via on its OWN geometry
/// rather than on its neighbours — the `min_annular` copper ring and the
/// `min_drill` bore? Mirrors `drc.checkDrillRules`, `eps` included.
///
/// Checked once per net rather than per site because the answer cannot vary
/// between sites: a class asking for a fence via the board's drill station will
/// not build makes EVERY site an identical error. Refusing the net with a reason
/// the author can act on beats placing a ring the ratchet then dismantles one via
/// at a time, and beats trusting a ratchet bounded at three rounds to catch a
/// violation on every via at once.
pub fn viaBuildable(via: FenceVia, design: DesignRules) bool {
    if (!(via.drill > 0)) return true; // no bore ⇒ no ring rule and no drill rule
    if ((via.dia - via.drill) / 2 < design.min_annular - eps) return false;
    return via.drill >= design.min_drill - eps;
}

// ── Generation ─────────────────────────────────────────────────────────────

/// How hard a candidate ring site is vetted before it lands. The generator draws
/// the SAME ring either way — the mode decides only what is allowed to veto a
/// site — so a `.legal` run is always a subset of an `.all` run.
pub const Mode = enum {
    /// Place every ring site, checking only intra-run coincidence. The raw ring
    /// geometry, for judging what the generator drew rather than what the board
    /// can accept.
    all,
    /// Vet each site against the board — the outline, pads, foreign tracks,
    /// existing vias — so the fence can never short anything. The default: a
    /// fence is copper on a nearly-finished board, and a run that hands back
    /// known-bad geometry is not a useful default whatever its ring looks like.
    legal,

    /// The mode named `s`, or null when `s` is neither spelling. The one parser
    /// both the HTTP endpoint and the CLI tool call, so an unknown mode is
    /// rejected identically on both.
    pub fn fromStr(s: []const u8) ?Mode {
        if (std.mem.eql(u8, s, "all")) return .all;
        if (std.mem.eql(u8, s, "legal")) return .legal;
        return null;
    }
};

/// Why a candidate fence site was dropped. Every rejection is counted under
/// exactly one of these, so a report says which constraint the board ran into
/// rather than only that vias are missing.
pub const SkipReason = enum {
    /// Outside the board outline, or inside its copper-edge clearance.
    outline,
    /// Too close to a pad's copper, or to a pad's drilled hole. A pad of the
    /// STITCH net never reports this on copper — see `Pass.padBlocks`.
    pad,
    /// Too close to a foreign-net track — including the fenced trace itself,
    /// which is what a tight corner pinches the guide contour against.
    track,
    /// Too close to a via that was already on the board before this run.
    via,
    /// Its copper disc overlaps a footprint-attached `(vias not_allowed)` rule
    /// area. The polygon follows the footprint's exact rotation and mirror.
    keepout,
    /// Coincident with a site this same run already accepted — two RF traces
    /// sharing a corridor, or two layers of one net wrapped separately, stitch it
    /// once instead of twice. The ONLY check that runs in every mode:
    /// it is generation correctness, not a board rule.
    dedup,
};

/// Per-reason skip tallies for one fenced net.
pub const Skips = struct {
    outline: usize = 0,
    pad: usize = 0,
    track: usize = 0,
    via: usize = 0,
    keepout: usize = 0,
    dedup: usize = 0,

    /// Total candidates dropped.
    pub fn total(self: Skips) usize {
        return self.outline + self.pad + self.track + self.via + self.keepout + self.dedup;
    }

    fn bump(self: *Skips, reason: SkipReason) void {
        switch (reason) {
            .outline => self.outline += 1,
            .pad => self.pad += 1,
            .track => self.track += 1,
            .via => self.via += 1,
            .keepout => self.keepout += 1,
            .dedup => self.dedup += 1,
        }
    }
};

/// One accepted fence via. `net` is the net it STITCHES (ground); `fenced` is
/// the RF net it flanks — the provenance the layout persists as its `f` tag, so
/// the fence invalidates and regenerates with the trace it belongs to.
pub const Site = struct {
    x: f64,
    y: f64,
    dia: f64,
    drill: f64,
    net: []const u8,
    fenced: []const u8,
};

/// What one net's march resolved to, and what it drew: the millimetres actually
/// used plus the guide those millimetres were marched around.
pub const March = struct {
    /// The pitch marched, i.e. `resolvedPitchMm` raised to `minPitchMm` if it
    /// sat below that floor.
    pitch_mm: f64 = 0,
    /// True when that raise happened — the class asked for a spacing the board
    /// rules cannot build.
    clamped: bool = false,
    /// The resolved copper-edge-to-via-copper-edge gap (`resolvedGapMm`).
    gap_mm: f64 = 0,
    /// The level the guide contour was traced at: `gap_mm` + the via's radius,
    /// i.e. copper edge to via CENTRE (`guideDistMm`).
    dist_mm: f64 = 0,
    /// Total guide-contour perimeter (mm) marched — summed over every contour on
    /// every layer. The denominator behind `sites`.
    guide_mm: f64 = 0,
    /// Guide sites the march produced, before any of them were vetted:
    /// `sites == NetReport.placed + NetReport.skipped.total()` always.
    sites: usize = 0,
};

/// What one fenced net's pass did. `err` non-empty means the net was not fenced
/// at all (unresolvable pitch, or no ground net to stitch to) — a clean,
/// per-net, user-facing report rather than a failed run.
pub const NetReport = struct {
    net: []const u8,
    stitch: []const u8 = "",
    placed: usize = 0,
    skipped: Skips = .{},
    /// Closed guide contours the net's copper union traced to, over every layer
    /// it has routed track on.
    contours: usize = 0,
    march: March = .{},
    err: []const u8 = "",
};

/// A whole generator run: the sites to add, one report per fenced net, and the
/// board's resolved default ground net ("" when none was found).
pub const Result = struct {
    sites: []const Site,
    nets: []const NetReport,
    ground: []const u8 = "",
};

/// A fence run's inputs: a solved placement plus the layout's persisted copper
/// with net indices already resolved against `placement.nets` (what
/// `restoreRoutes` produces). `only`, when non-empty, restricts the pass to
/// those net names.
pub const Input = struct {
    placement: optimizer.Placement,
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
    only: []const []const u8 = &.{},
    /// How hard each ring site is vetted. `.legal` — only sites the board's own
    /// rules accept — is the default; `.all` is the debug view of the raw ring.
    mode: Mode = .legal,
};

/// Error text for a class whose pitch cannot be resolved. Surfaced verbatim by
/// the CLI/HTTP layer, so it names the two ways to fix it.
pub const err_unresolvable_pitch: []const u8 =
    "fence pitch is unresolvable — the class declares neither (fence (pitch MM)) nor (max-freq HZ)";

/// Error text for a resolved fence via the board's own drill station would reject.
/// Names both rules, since either can be the one that bites.
pub const err_via_unbuildable: []const u8 =
    "fence via geometry breaks the board's drill rules — widen (fence (via DIA DRILL)) to clear (design-rules (min-annular …) (min-drill …))";

/// Error text for a board with nothing to stitch a fence to.
pub const err_no_ground: []const u8 =
    "no ground net to stitch to — declare (fence (net \"NAME\")) or a ground (plane …) in the (stackup …)";

/// Last path segment of a `parent/child` net name — the leaf a ground-name
/// predicate is applied to, so `pwr/GND` reads as ground.
fn leafName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// The board's default fence stitch net: the first DECLARED `(plane …)` whose
/// net is a ground rail, else the first ground-named net in the flattened
/// netlist. Returns its index into `placement.nets`, or null when the board has
/// no ground at all. Deliberately a local three-line lookup rather than a
/// router import — the router's own `firstGroundNet` additionally demands the
/// net carry a plane, which would refuse to fence a plane-less 2-layer board.
fn groundNetIndex(placement: optimizer.Placement) ?usize {
    for (placement.rules.planes.declared) |plane| {
        if (!optimizer.isGroundName(leafName(plane.net))) continue;
        for (placement.nets, 0..) |net, i| {
            if (std.mem.eql(u8, net.name, plane.net) or std.mem.eql(u8, leafName(net.name), leafName(plane.net))) return i;
        }
    }
    for (placement.nets, 0..) |net, i| {
        if (optimizer.isGroundName(leafName(net.name))) return i;
    }
    return null;
}

/// Is `rule`'s net a fence target? A net is fenced when its resolved class
/// DECLARES `(fence)` — the author's explicit ask — OR carries `(max-freq …)`,
/// which makes it an RF trace the fence can be derived for (pitch = λg/10) even
/// though no fence was written. That second arm is what lets the Fence action
/// cover a board's RF traces without demanding every RF class spell `(fence)`
/// out. An impedance-only class is NOT a fence target: with no frequency there
/// is no wavelength to derive a pitch from (the net would only report
/// `err_unresolvable_pitch`), and controlled-impedance clock/control nets are
/// not RF traces asking for a ground wall.
pub fn fenceable(rule: NetRule) bool {
    return rule.rf.fence.declared or rule.rf.max_freq_hz > 0;
}

/// True when ANY net on `placement` is a fence target: a declared `(fence)` or
/// a `(max-freq …)` RF trace. The cheap "is there anything to fence here" probe
/// every caller opens with — the serve layer uses it to refuse a fence run and
/// to decide the viewer's Fence button visibility.
pub fn anyFenceable(placement: optimizer.Placement) bool {
    for (placement.rules.net) |rule| {
        if (fenceable(rule)) return true;
    }
    return false;
}

/// Index of the net named `name` in the flattened netlist (exact match).
fn netIndex(placement: optimizer.Placement, name: []const u8) ?usize {
    for (placement.nets, 0..) |net, i| {
        if (std.mem.eql(u8, net.name, name)) return i;
    }
    return null;
}

/// One drilled feature's bore as the DRC's drill station sees it: the capsule swept
/// by a `drill`-diameter tool from `(x,y)-(shx,shy)` to `(x,y)+(shx,shy)`. A round
/// bore is the degenerate case with a zero half-vector, so one shape covers a via, a
/// round pad hole and an oval slot.
const Bore = struct {
    drill: f64,
    x: f64,
    y: f64,
    shx: f64 = 0,
    shy: f64 = 0,
};

/// A pad reduced to what a fence needs of it: its world copper shape, its net, and
/// its drilled bore as the CAPSULE the DRC's drill station measures — a segment
/// between a slot's two arc centres (`shx`/`shy` is the world half-vector to one of
/// them, zero for a round bore) swept by `drill`. Mirroring the capsule rather than
/// inflating an oval into a disc matters: a disc over-states a slot by its whole
/// half-length in every direction, which would veto sites the DRC clears.
///
/// It plays two parts — an obstacle a site must clear, and, when it belongs to the
/// fenced net, a piece of the copper union the guide contour wraps. Neither part
/// filters by side: a fence via is a THROUGH via, so its barrel meets every pad on
/// every layer.
const PadObs = struct {
    shape: pad_shape.Shape,
    net: i32,
    drill: f64,
    hx: f64,
    hy: f64,
    shx: f64 = 0,
    shy: f64 = 0,
};

/// Every pad on the board as a `PadObs`. A fence via is a THROUGH via, so its
/// barrel meets pads on every layer and none are filtered out by side.
fn padObstacles(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]PadObs {
    var pin_net = std.StringHashMapUnmanaged(i32).empty;
    for (placement.nets, 0..) |net, ni| for (net.pins) |pin| {
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
        try pin_net.put(arena, key, @intCast(ni));
    };
    var list: std.ArrayList(PadObs) = .empty;
    for (placement.parts) |part| for (part.pads) |pad| {
        const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ part.ref_des, pad.number });
        const c = optimizer.worldPadCenter(&part, pad.x, pad.y);
        var shx: f64 = 0;
        var shy: f64 = 0;
        if (pad.isSlot()) {
            const e = optimizer.worldPadCenter(&part, pad.x + pad.slot_half[0], pad.y + pad.slot_half[1]);
            shx = e[0] - c[0];
            shy = e[1] - c[1];
        }
        try list.append(arena, .{
            .shape = try pad_shape.worldShape(arena, part, pad),
            .net = pin_net.get(key) orelse -1,
            .drill = pad.drill,
            .hx = c[0],
            .hy = c[1],
            .shx = shx,
            .shy = shy,
        });
    };
    return list.toOwnedSlice(arena);
}

/// One footprint-attached through-via rule area in board coordinates. The
/// polygon is transformed once per generator run, preserving arbitrary part
/// rotation and bottom-side mirroring without reducing it to a bounding box.
const ViaKeepout = struct { poly: []const [2]f64 };

fn viaKeepouts(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]ViaKeepout {
    var list: std.ArrayList(ViaKeepout) = .empty;
    for (placement.parts) |part| {
        for (part.features.copper_pour_keepouts) |keepout| {
            if (!keepout.vias_not_allowed or keepout.poly.len < 3) continue;
            const world = try arena.alloc([2]f64, keepout.poly.len);
            for (keepout.poly, world) |local, *out| {
                out.* = optimizer.worldPadCenter(&part, local[0], local[1]);
            }
            try list.append(arena, .{ .poly = world });
        }
    }
    return list.toOwnedSlice(arena);
}

/// The arc length (mm) of a polyline.
fn chainLength(pts: []const [2]f64) f64 {
    var len: f64 = 0;
    for (pts[1..], 0..) |p, i| len += std.math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]);
    return len;
}

/// The point `s` mm along a polyline, clamped to its ends.
fn pointAt(pts: []const [2]f64, s: f64) [2]f64 {
    if (pts.len == 0) return .{ 0, 0 };
    var left = s;
    for (pts[1..], 0..) |p, i| {
        const a = pts[i];
        const seg = std.math.hypot(p[0] - a[0], p[1] - a[1]);
        if (left <= seg or i + 2 == pts.len) {
            if (seg <= 0) return a;
            const t = std.math.clamp(left / seg, 0, 1);
            return .{ a[0] + t * (p[0] - a[0]), a[1] + t * (p[1] - a[1]) };
        }
        left -= seg;
    }
    return pts[pts.len - 1];
}

/// Signed distance (mm) from (x,y) to the board outline, positive inside. The
/// exact polygon when the layout drew one, else the authored rectangle.
fn boardInset(placement: optimizer.Placement, x: f64, y: f64) ?f64 {
    if (placement.board_poly) |poly| {
        if (poly.len >= 3) return outline_mod.signedInset(poly, x, y);
    }
    const br = placement.board_rect orelse return null;
    return @min(
        @min(x - br.minx, br.minx + br.w - x),
        @min(y - br.miny, br.miny + br.h - y),
    );
}

/// One fence pass over one board: immutable obstacle sets plus the sites
/// accepted so far, which every later candidate is also judged against.
const Pass = struct {
    arena: std.mem.Allocator,
    in: Input,
    design: DesignRules,
    pads: []const PadObs,
    via_keepouts: []const ViaKeepout,
    sites: std.ArrayList(Site),
    /// World positions + geometry of the accepted sites, parallel to `sites`.
    accepted: std.ArrayList(router.Via),

    /// Copper clearance a fence via on net `stitch` owes net `other`: the PAIRWISE
    /// rule, the wider of the two classes' `(clearance …)` over the board default.
    /// The same `clearanceBetween` call `drc.ClearanceResolver.between` makes, on
    /// the same base — the fence net's own clearance alone would under-state every
    /// pair where the other net's class asks for more.
    ///
    /// Callers guard same-net pairs themselves with `sameNet` (as the DRC does)
    /// rather than reading a 0 back from here, so "owes nothing" and "owes the
    /// board default" can never be confused.
    fn clearanceTo(self: Pass, stitch: i32, other: i32) f64 {
        return self.in.placement.rules.clearanceBetween(stitch, other, self.design.clearance);
    }

    /// Exact foreign-copper gap around an existing single-ended RF via. A
    /// ground fence via is allowed inside the class's broad isolation halo,
    /// but never inside the physical plane antipad cut around the signal via.
    fn antipadGap(self: Pass, v: router.Via) f64 {
        if (v.net < 0) return 0;
        const ni: usize = @intCast(v.net);
        const rules = self.in.placement.rules;
        if (ni >= rules.net.len) return 0;
        const nr = rules.net[ni];
        if (nr.rf.impedance.diff_ohms > 0) return 0;
        const target = if (nr.rf.impedance.ohms > 0)
            nr.rf.impedance.ohms
        else if (nr.rf.max_freq_hz > 0)
            via_antipad.default_system_ohms
        else
            return 0;
        const minimum = rules.clearanceForNet(v.net, rules.design.clearance);
        const result = via_antipad.solve(rules.physical.stack, target, v.dia, v.drill, minimum) orelse return 0;
        return (result.antipad_dia_mm - v.dia) / 2.0;
    }

    /// Should a site at (x,y) be dropped? Null = keep it; otherwise the reason to
    /// count. `ring_from` is where the CURRENT ring's own sites start in
    /// `accepted`: coincidence dedup looks only below it, so the uniform march of
    /// one closed loop can never dedup against itself, however tight the ring.
    fn judge(self: Pass, x: f64, y: f64, plan: FencePlan, ring_from: usize) ?SkipReason {
        for (self.accepted.items[0..@min(ring_from, self.accepted.items.len)]) |v| {
            if (std.math.hypot(x - v.x, y - v.y) < plan.pitch / 2) return .dedup;
        }
        if (self.in.mode == .all) return null;
        return self.illegal(x, y, plan.via, plan.stitch_i);
    }

    /// The board's own veto on a `via` at (x,y), checked cheapest-and-most-
    /// decisive first: the outline, footprint rule areas, pads, tracks, then
    /// pre-existing vias and this run's own accepted geometry. `.legal` mode only.
    ///
    /// Each arm is its `drc.zig` twin's predicate written out as a keep/skip
    /// decision: `board_edge` here, `via_pad` + `hole_hole` in `padBlocks`,
    /// `via_track` here, `via_via` + `hole_hole` in `viaClash`. Same rule, same
    /// slack, same same-net exemption — see the module doc for why that exactness
    /// is the point and which three departures are deliberate.
    fn illegal(self: Pass, x: f64, y: f64, via: FenceVia, stitch: i32) ?SkipReason {
        const vr = via.dia / 2;
        // `board_edge`: the copper-edge rule, which is `copper_edge` when the board
        // declares one and the plain clearance otherwise. No staging exemption —
        // the DRC forgives copper parked far off-board, a fence via there is junk.
        if (boardInset(self.in.placement, x, y)) |inset| {
            if (inset - vr < self.design.edgeClearance() - eps) return .outline;
        }
        for (self.via_keepouts) |keepout| {
            // Positive means the centre is inside. A negative inset whose
            // magnitude is no larger than the via radius means its copper disc
            // still crosses the exact polygon boundary.
            if (outline_mod.signedInset(keepout.poly, x, y) >= -vr - eps) return .keepout;
        }
        for (self.pads) |pad| {
            if (self.padBlocks(x, y, via, stitch, pad)) return .pad;
        }
        // `via_track`. A track of the stitch net is exempt for the same reason a
        // pad of it is: ground copper meeting a ground barrel is one conductor,
        // which is what the fence is trying to build.
        for (self.in.tracks) |t| {
            if (sameNet(t.net, stitch)) continue;
            const eff = self.clearanceTo(stitch, t.net);
            const wall = pad_shape.segPointDist(t.x1, t.y1, t.x2, t.y2, x, y) - vr - t.width / 2;
            if (wall < eff - eps) return .track;
        }
        for (self.in.vias) |v| {
            if (self.viaClash(x, y, via, stitch, v) or self.crowdsStitch(x, y, via, stitch, v)) return .via;
        }
        for (self.accepted.items) |v| {
            if (self.viaClash(x, y, via, stitch, v)) return .dedup;
        }
        return null;
    }

    /// Does `pad` veto a fence via at (x,y)? `via_pad` + the drill station's
    /// `hole_hole`, exactly as `drc.checkViaPad` / `drc.checkDrillRules` judge them.
    ///
    /// A pad of the STITCH net does NOT veto on copper: a fence via landing on or
    /// inside a ground pad is VIA-IN-PAD ON GROUND, which stitches that pad
    /// straight to the plane — the tightest return path a fence can offer, and
    /// wanted rather than tolerated. Its DRILL still counts: hole-to-hole is
    /// net-blind, so drilling into a through-hole ground pad's barrel is refused
    /// on the same rule that refuses any two crowded holes.
    ///
    /// The `slack` handed to `pointDist` is load-bearing, not decoration: it is the
    /// threshold below which the exact outline is worth computing, so passing 0
    /// silently measures every roundrect and custom pad to its BOUNDING BOX. That
    /// box over-states a rounded land at each corner, which is precisely where a
    /// guide contour rounding a 0402 puts its sites.
    fn padBlocks(self: Pass, x: f64, y: f64, via: FenceVia, stitch: i32, pad: PadObs) bool {
        const vr = via.dia / 2;
        if (!sameNet(pad.net, stitch)) {
            const eff = self.clearanceTo(stitch, pad.net);
            const sh = pad.shape;
            const gap = pad_shape.pointDist(sh.x0, sh.y0, sh.x1, sh.y1, sh.poly, x, y, vr + eff) - vr;
            if (gap < eff - eps) return true;
        }
        return self.holeClash(x, y, via.drill, .{ .drill = pad.drill, .x = pad.hx, .y = pad.hy, .shx = pad.shx, .shy = pad.shy });
    }

    /// Does a fence via at (x,y) clash with existing via `v` — on copper
    /// (`via_via` across nets, `via_spacing` within one) or on the net-blind
    /// `hole_hole` rule?
    ///
    /// The SAME-net arm is the fence's own pitch discipline as well as a DRC
    /// echo: two ground barrels a fraction of a millimetre apart shield nothing
    /// the first one did not, and a site that close to the stitch net's
    /// existing copper is a duplicate drill, not a fence post. It is measured
    /// against `drc.viaSpacingRule`'s number so the prefilter cannot admit a
    /// site the board's own DRC would then flag.
    fn viaClash(self: Pass, x: f64, y: f64, via: FenceVia, stitch: i32, v: router.Via) bool {
        if (!sameNet(v.net, stitch)) {
            const eff = @max(self.clearanceTo(stitch, v.net), self.antipadGap(v));
            const gap = std.math.hypot(x - v.x, y - v.y) - via.dia / 2 - v.dia / 2;
            if (gap < eff - eps) return true;
        }
        return self.holeClash(x, y, via.drill, .{ .drill = v.drill, .x = v.x, .y = v.y });
    }

    /// Does a fence site at (x,y) crowd an EXISTING via of its own stitch net
    /// closer than `drc.viaSpacingRule` allows?
    ///
    /// Two ground barrels a fraction of a millimetre apart shield nothing the
    /// first one did not, and the board's own DRC now calls that pair
    /// `via_spacing` — so a prefilter that admitted it would plant copper the
    /// gate then refuses. Only BOARD vias are judged here: the fence's own
    /// posts are marched at `minPitchMm`, which already clamps the pitch up to
    /// this very floor, so re-testing them would only add float-edge churn to a
    /// spacing the generator has already guaranteed.
    fn crowdsStitch(self: Pass, x: f64, y: f64, via: FenceVia, stitch: i32, v: router.Via) bool {
        if (!sameNet(v.net, stitch)) return false;
        const declared = self.design.via_to_via;
        const eff = if (declared > 0) declared else self.clearanceTo(stitch, stitch);
        return std.math.hypot(x - v.x, y - v.y) - via.dia / 2 - v.dia / 2 < eff - eps;
    }

    /// The drill station's net-blind `hole_to_hole` rule between a fence via's bore
    /// of diameter `drill` at (x,y) and another drilled feature's `bore`:
    /// wall-to-wall distance between the two bore CAPSULES, as
    /// `drc.checkDrillRules` measures it. An undrilled feature — an SMD pad — has
    /// no bore to crowd.
    ///
    /// One deliberate departure: the DRC exempts an EXACTLY coincident pair, since
    /// a via dropped dead-centre on a thru pad is one hole in the drill file rather
    /// than two. The fence does not take that exemption — a second barrel down an
    /// existing bore adds no shielding and no stitch, so there is nothing to gain
    /// by allowing it.
    fn holeClash(self: Pass, x: f64, y: f64, drill: f64, bore: Bore) bool {
        if (!(drill > 0) or !(bore.drill > 0)) return false;
        const wall = pad_shape.segPointDist(bore.x - bore.shx, bore.y - bore.shy, bore.x + bore.shx, bore.y + bore.shy, x, y);
        return wall - drill / 2 - bore.drill / 2 < self.design.hole_to_hole - eps;
    }

    /// Accept a site, recording it so later rings dedupe against it.
    fn accept(self: *Pass, x: f64, y: f64, plan: FencePlan) std.mem.Allocator.Error!void {
        try self.sites.append(self.arena, .{
            .x = x,
            .y = y,
            .dia = plan.via.dia,
            .drill = plan.via.drill,
            .net = plan.stitch_name,
            .fenced = plan.fenced_name,
        });
        try self.accepted.append(self.arena, .{
            .x = x,
            .y = y,
            .dia = plan.via.dia,
            .net = plan.stitch_i,
            .drill = plan.via.drill,
        });
    }
};

/// Has `net_i` any routed track at all? A net with none is unrouted, and an
/// unrouted net is not fenced: a fence shields a path, and there is no path around
/// bare pads yet — a ring there would only wall off the routing still to come.
fn hasTracks(tracks: []const router.Track, net_i: i32) bool {
    for (tracks) |t| {
        if (t.net == net_i) return true;
    }
    return false;
}

/// The fenced net's whole copper, as the union `via_guide` wraps: every track
/// segment as a capsule, every pad the net lands on, and its own via barrels.
///
/// Every LAYER at once, deliberately. A fence via is a through barrel, so the
/// region it must stay out of is the net's copper on all of them: a top-routed
/// net whose pad sits on the bottom face (a board-to-board connector's land) would
/// otherwise be wrapped by a contour that knows nothing about that pad, and the
/// barrel would drill straight through it. Copper on layers that are far apart
/// stays far apart in the union too, so it simply traces as separate contours —
/// the merge happens exactly where the copper actually touches.
///
/// This is also the ONE place the fence decides what counts as the net's copper,
/// so trace and pad are held to the same gap by construction rather than by two
/// rules that have to agree.
fn netUnion(
    arena: std.mem.Allocator,
    in: Input,
    pads: []const PadObs,
    net_i: i32,
) std.mem.Allocator.Error!via_guide.Union {
    var caps: std.ArrayList(via_guide.Capsule) = .empty;
    for (in.tracks) |t| {
        if (t.net != net_i) continue;
        try caps.append(arena, .{ .x1 = t.x1, .y1 = t.y1, .x2 = t.x2, .y2 = t.y2, .half = t.width / 2 });
    }
    var discs: std.ArrayList(via_guide.Disc) = .empty;
    for (in.vias) |v| {
        if (v.net != net_i) continue;
        try discs.append(arena, .{ .x = v.x, .y = v.y, .r = v.dia / 2 });
    }
    var shapes: std.ArrayList(pad_shape.Shape) = .empty;
    for (pads) |pad| {
        if (pad.net != net_i) continue;
        try shapes.append(arena, pad.shape);
    }
    return .{
        .caps = try caps.toOwnedSlice(arena),
        .discs = try discs.toOwnedSlice(arena),
        .pads = try shapes.toOwnedSlice(arena),
    };
}

// ── The march ──────────────────────────────────────────────────────────────
//
// A fenced net's candidates come from the closed GUIDE CONTOURS `via_guide`
// traces around its copper union — one curve per connected blob of copper, at a
// uniform distance from every edge of it. The pitch is divided evenly into each
// perimeter, which is what makes the fence close: two independently marched
// flanks would leave a seam at each end, and a row measured from the centreline
// would cut through the net's own pads.

/// Through-vias also receive an explicit local guard ring. A via can be only a
/// small bulge on a long, wide trace, so the global contour's pitch march can
/// pass that bulge without leaving a complete return-via ring around the layer
/// transition. The local ring is still sent through `Pass.judge`, so trace exits,
/// plane antipads, pads, existing vias, and the board edge may remove individual
/// posts while every legal post that can surround the through-via is retained.
///
/// Fewest sites one closed contour is marched into, however short the copper and
/// however coarse the pitch. A pad-to-pad RF stub can be shorter than the pitch,
/// and a fence with one or two vias in it is not a fence — four is the least that
/// still surrounds the copper on every side.
const min_ring_sites: usize = 4;

/// Sites one closed contour of perimeter `len` is marched into: the pitch rounded
/// to the nearest WHOLE division of the perimeter, so the actual spacing
/// `len / n` closes the loop evenly instead of leaving a short seam or a doubled
/// site where the march wraps. Floored at `min_ring_sites`.
fn ringSites(len: f64, pitch: f64) usize {
    if (!(pitch > 0) or !(len > 0)) return min_ring_sites;
    return @max(min_ring_sites, numeric.toCount(@round(len / pitch)));
}

/// Phase samples for a legal contour march. Eight moves a nominal site in
/// eighth-pitch increments, fine enough to find a manufacturable via-sized slot
/// without turning obstacle vetting into an unbounded search. The zero phase is
/// always tried first and wins ties, preserving existing geometry unless a shift
/// places strictly more vias.
const contour_phase_trials: usize = 8;

/// Number of sites the fixed-spacing contour march can legally retain at
/// `phase`. This is a dry score: the pass is not mutated until the winning phase
/// is known, so every trial sees the identical board and earlier-ring sites.
fn contourPhaseScore(
    pass: Pass,
    closed: []const [2]f64,
    n: usize,
    spacing: f64,
    phase: f64,
    plan: FencePlan,
) usize {
    var kept: usize = 0;
    const ring_from = pass.accepted.items.len;
    for (0..n) |i| {
        const p = pointAt(closed, phase + @as(f64, @floatFromInt(i)) * spacing);
        if (pass.judge(p[0], p[1], plan, ring_from) == null) kept += 1;
    }
    return kept;
}

/// Pick the rotation of the uniform site lattice that retains the most legal
/// posts. Spacing and site count do not change: this only moves the seam around
/// the closed contour. Raw `.all` mode keeps phase zero because every phase is
/// equally legal and phase search would add no information.
fn bestContourPhase(
    pass: Pass,
    closed: []const [2]f64,
    n: usize,
    spacing: f64,
    plan: FencePlan,
) f64 {
    if (pass.in.mode == .all) return 0;
    var best_phase: f64 = 0;
    var best = contourPhaseScore(pass, closed, n, spacing, 0, plan);
    if (best == n) return 0;
    for (1..contour_phase_trials) |trial| {
        const phase = spacing * @as(f64, @floatFromInt(trial)) / contour_phase_trials;
        const kept = contourPhaseScore(pass, closed, n, spacing, phase, plan);
        if (kept > best) {
            best = kept;
            best_phase = phase;
        }
    }
    return best_phase;
}

/// March one closed guide contour and offer a site at every even division of its
/// perimeter. This is the whole candidate generator: one uniform spacing around
/// each contour, ends included.
fn marchContour(
    pass: *Pass,
    contour: via_guide.Contour,
    plan: FencePlan,
    rep: *NetReport,
) std.mem.Allocator.Error!void {
    if (contour.len < 2) return;
    // Repeating the first vertex turns the loop into an ordinary polyline, so the
    // closing chord is marched by the same arc-length walk as every other.
    const closed = try pass.arena.alloc([2]f64, contour.len + 1);
    @memcpy(closed[0..contour.len], contour);
    closed[contour.len] = contour[0];
    const len = chainLength(closed);
    if (!(len > 0)) return;
    rep.march.guide_mm += len;

    const n = ringSites(len, plan.pitch);
    const spacing = len / @as(f64, @floatFromInt(n));
    const ring_from = pass.accepted.items.len;
    const phase = bestContourPhase(pass.*, closed, n, spacing, plan);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = pointAt(closed, phase + @as(f64, @floatFromInt(i)) * spacing);
        rep.march.sites += 1;
        if (pass.judge(p[0], p[1], plan, ring_from)) |reason| {
            rep.skipped.bump(reason);
            continue;
        }
        try pass.accept(p[0], p[1], plan);
        rep.placed += 1;
    }
}

/// March a local return-via ring around one fenced signal through-via. The ring
/// radius is measured from the signal-via centre to the fence-via centre. A
/// single-ended controlled-impedance via may have a larger synthesized plane
/// antipad than the trace fence gap, so raise the local ring to that boundary
/// before `judge` checks the candidate; otherwise every post on the local ring
/// would be rejected and the through-via would remain unshielded.
fn marchVia(
    pass: *Pass,
    signal: router.Via,
    plan: FencePlan,
    rep: *NetReport,
) std.mem.Allocator.Error!void {
    const antipad_gap = pass.antipadGap(signal);
    const from_edge = @max(plan.dist, plan.via.dia / 2 + antipad_gap);
    const radius = signal.dia / 2 + from_edge;
    if (!(radius > 0) or !std.math.isFinite(radius)) return;

    const circumference = 2 * std.math.pi * radius;
    const n = ringSites(circumference, plan.pitch);
    const ring_from = pass.accepted.items.len;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(i)) /
            @as(f64, @floatFromInt(n));
        const x = signal.x + radius * @cos(angle);
        const y = signal.y + radius * @sin(angle);
        rep.march.sites += 1;
        if (pass.judge(x, y, plan, ring_from)) |reason| {
            rep.skipped.bump(reason);
            continue;
        }
        try pass.accept(x, y, plan);
        rep.placed += 1;
    }
    rep.march.guide_mm += circumference;
}

/// Everything one fenced net's march needs, resolved once. `dist` is the level
/// its guide contour is traced at — copper edge to via centre.
const FencePlan = struct {
    pitch: f64,
    dist: f64,
    via: FenceVia,
    stitch_i: i32,
    stitch_name: []const u8,
    fenced_name: []const u8,
};

/// Resolve the fenced net `fenced`'s plan, or the user-facing reason it has none.
fn planFor(
    placement: optimizer.Placement,
    rule: NetRule,
    fenced: usize,
    ground: ?usize,
    rep: *NetReport,
) ?FencePlan {
    const design = placement.rules.design;
    const stitch: usize = if (rule.rf.fence.net.len > 0)
        (netIndex(placement, rule.rf.fence.net) orelse {
            rep.err = err_no_ground;
            return null;
        })
    else
        (ground orelse {
            rep.err = err_no_ground;
            return null;
        });
    rep.stitch = placement.nets[stitch].name;
    const asked = resolvedPitchMm(rule);
    if (!(asked > 0)) {
        rep.err = err_unresolvable_pitch;
        return null;
    }
    const via = resolvedFenceVia(rule, design);
    if (!viaBuildable(via, design)) {
        rep.err = err_via_unbuildable;
        return null;
    }
    const floor = minPitchMm(via, design);
    // The gap is the class's resolved number raised to the PAIRWISE clearance the
    // stitch net and the fenced net actually owe each other. A derived gap reads the
    // fenced class alone, which under-states the rule whenever the GROUND net's own
    // class asks for more than the RF class does — and a guide traced inside the
    // legal distance yields a ring every site of which the prefilter then refuses
    // against the very trace it was meant to shield, counted as a "track" gap with
    // nothing to point at. An AUTHORED (fence (offset …)) still wins outright: the
    // author is stating a measured number, and the prefilter is what catches it if
    // the board disagrees.
    const asked_gap = resolvedGapMm(rule, design);
    const pairwise = placement.rules.clearanceBetween(@intCast(stitch), @intCast(fenced), design.clearance) + offset_margin_mm;
    const gap = if (rule.rf.fence.offset_mm > 0) asked_gap else @max(asked_gap, pairwise);
    rep.march = .{
        .pitch_mm = @max(asked, floor),
        .clamped = floor > asked,
        .gap_mm = gap,
        .dist_mm = gap + via.dia / 2,
    };
    return .{
        .pitch = rep.march.pitch_mm,
        .dist = rep.march.dist_mm,
        .via = via,
        .stitch_i = @intCast(stitch),
        .stitch_name = rep.stitch,
        .fenced_name = placement.nets[fenced].name,
    };
}

/// True when `name` is in `only`, or `only` is empty (no filter).
fn selected(only: []const []const u8, name: []const u8) bool {
    if (only.len == 0) return true;
    for (only) |o| if (std.mem.eql(u8, o, name)) return true;
    return false;
}

/// Fence one net: trace the guide contours around its copper union and march each
/// of them. Each contour is marched against the sites the earlier ones accepted, so
/// two blobs of the same net that pass close by stitch their shared corridor once.
fn fenceNet(pass: *Pass, net_i: i32, plan: FencePlan, rep: *NetReport) std.mem.Allocator.Error!void {
    if (!hasTracks(pass.in.tracks, net_i)) return;
    const copper = try netUnion(pass.arena, pass.in, pass.pads, net_i);
    if (copper.isEmpty()) return;

    // Transition rings go first. The later general contour deduplicates against
    // them, so a nearby trace-row post can never consume the limited sites that
    // actually surround the through-via. This makes the electrically critical
    // local return ring the stable geometry and lets the ordinary row yield at
    // their overlap.
    for (pass.in.vias) |signal| {
        if (signal.net != net_i) continue;
        try marchVia(pass, signal, plan, rep);
    }

    const guide = try via_guide.trace(pass.arena, copper, plan.dist);
    rep.contours += guide.contours.len;
    for (guide.contours) |contour| try marchContour(pass, contour, plan, rep);
}

/// Generate the ground via fence for every net whose resolved class declares a
/// fence OR carries a `(max-freq …)` — the end-of-design, on-demand pass over a
/// saved layout's persisted copper. The max-freq arm is the derived default: an
/// RF trace's pitch resolves as λg/10 exactly as a bare `(fence)`'s does, so the
/// two spellings cannot diverge on the same board.
///
/// Nets are walked in flatten order and each ring's sites are deduped against
/// everything accepted by the rings before it, so two RF traces sharing a
/// corridor stitch it once. Nothing is ever moved to make room: in `.legal` mode
/// a vetoed site is a counted gap.
pub fn generate(arena: std.mem.Allocator, in: Input) std.mem.Allocator.Error!Result {
    const placement = in.placement;
    const ground = groundNetIndex(placement);
    var pass = Pass{
        .arena = arena,
        .in = in,
        .design = placement.rules.design,
        .pads = try padObstacles(arena, placement),
        .via_keepouts = try viaKeepouts(arena, placement),
        .sites = .empty,
        .accepted = .empty,
    };
    var reports: std.ArrayList(NetReport) = .empty;
    for (placement.nets, 0..) |net, ni| {
        if (ni >= placement.rules.net.len) break;
        const rule = placement.rules.net[ni];
        if (!fenceable(rule)) continue;
        if (!selected(in.only, net.name)) continue;
        var rep = NetReport{ .net = net.name };
        if (planFor(placement, rule, ni, ground, &rep)) |plan| {
            try fenceNet(&pass, @intCast(ni), plan, &rep);
        }
        try reports.append(arena, rep);
    }
    return .{
        .sites = try pass.sites.toOwnedSlice(arena),
        .nets = try reports.toOwnedSlice(arena),
        .ground = if (ground) |g| placement.nets[g].name else "",
    };
}

// ── Tests ──────────────────────────────────────────────────────────────────

const flat_netlist = @import("../flat_netlist.zig");
const testing = std.testing;

/// A minimal solved placement for the generator tests: two RF pads at the ends
/// of a straight trace on net 0 ("RF"), a ground net 1 ("GND") with no pads, and
/// a 40x20 mm board so the outline never interferes unless a test asks it to.
fn fixture(parts: []optimizer.Part, nets: []const flat_netlist.FlatNet, rules: []const NetRule) optimizer.Placement {
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
        .maxx = 40,
        .maxy = 20,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 40, .h = 20 },
        .rules = .{ .net = rules },
    };
}

/// The standard two-net fixture: "RF" (fenced, 1 mm pitch, 0.6 mm edge gap) and
/// "GND". `parts` is caller-owned so a test can add pad obstacles.
fn rfFixture(parts: []optimizer.Part) optimizer.Placement {
    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6 } } },
        .{},
    };
    return fixture(parts, nets, rules);
}

// spec: placement/via-fence - legal fence sites reject full-disc overlap with an exactly rotated footprint via keepout
test "a rotated footprint via keepout rejects overlapping fence copper exactly" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const poly = [_][2]f64{
        .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 },
    };
    const keepouts = [_]@import("geometry.zig").CopperPourKeepout{.{
        .side = .front,
        .poly = &poly,
        .vias_not_allowed = true,
    }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "J1",
        .kind = .hub,
        .hw = 2,
        .hh = 2,
        .pads = &.{},
        .fallback = false,
        .features = .{ .copper_pour_keepouts = &keepouts },
        .x = 15,
        .y = 10,
        .rot = 45,
    }};
    const placement = rfFixture(&parts);
    var pass = Pass{
        .arena = arena,
        .in = .{ .placement = placement },
        .design = placement.rules.design,
        .pads = &.{},
        .via_keepouts = try viaKeepouts(arena, placement),
        .sites = .empty,
        .accepted = .empty,
    };
    const via = FenceVia{ .dia = 0.4, .drill = 0.2 };

    // These samples lie on the footprint's LOCAL +X axis. At 45 degrees that
    // axis is diagonal in board space: a local x=1.10 centre is outside the
    // polygon but its 0.20 mm copper radius still overlaps; x=1.21 clears it.
    const overlap = optimizer.worldPadCenter(&parts[0], 1.10, 0);
    const clear = optimizer.worldPadCenter(&parts[0], 1.21, 0);
    try testing.expectEqual(SkipReason.keepout, pass.illegal(overlap[0], overlap[1], via, 1).?);
    try testing.expect(pass.illegal(clear[0], clear[1], via, 1) == null);
}

/// A straight horizontal RF track from x0 to x1 at y, on net 0, top copper.
fn straight(x0: f64, x1: f64, y: f64) router.Track {
    return .{ .x1 = x0, .y1 = y, .x2 = x1, .y2 = y, .layer = 0, .width = 0.3, .net = 0 };
}

// spec: placement/via-fence - in legal mode the uniform contour lattice shifts in eighth-pitch steps when the contour's arbitrary first vertex misses usable sites, retaining the phase that places the most vias without changing pitch
test "a legal contour shifts its uniform lattice into usable slots" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{};
    const blockers = [_]router.Via{
        .{ .x = 10, .y = 10, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 12, .y = 10, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 14, .y = 10, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 14, .y = 12, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 14, .y = 14, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 12, .y = 14, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 10, .y = 14, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 10, .y = 12, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    var pass = try probePass(arena, rfFixture(&parts), &.{}, &blockers);
    const contour = [_][2]f64{ .{ 10, 10 }, .{ 14, 10 }, .{ 14, 14 }, .{ 10, 14 } };
    const plan = FencePlan{
        .pitch = 2,
        .dist = 0.8,
        .via = probe_via,
        .stitch_i = probe_stitch,
        .stitch_name = "GND",
        .fenced_name = "RF",
    };
    const closed = [_][2]f64{ .{ 10, 10 }, .{ 14, 10 }, .{ 14, 14 }, .{ 10, 14 }, .{ 10, 10 } };
    const n = ringSites(chainLength(&closed), plan.pitch);
    const spacing = chainLength(&closed) / @as(f64, @floatFromInt(n));
    try testing.expectEqual(@as(usize, 8), contour_phase_trials);

    // Phase zero lands all eight candidates on the blockers. Rotating the same
    // eight-site, 2 mm lattice puts every post between them; no extra site and no
    // clearance exemption is needed.
    try testing.expectEqual(@as(usize, 0), contourPhaseScore(pass, &closed, n, spacing, 0, plan));
    try testing.expect(bestContourPhase(pass, &closed, n, spacing, plan) > 0);
    var rep = NetReport{ .net = "RF" };
    try marchContour(&pass, &contour, plan, &rep);
    try testing.expectEqual(n, rep.march.sites);
    try testing.expectEqual(n, rep.placed);
    try testing.expectEqual(@as(usize, 0), rep.skipped.total());
}

/// Distance (mm) between the two closest accepted sites — the one number that
/// proves a whole run's rows never crowd each other. Infinite for <2 sites.
fn closestPair(sites: []const Site) f64 {
    var best = std.math.inf(f64);
    for (sites, 0..) |a, i| {
        for (sites[i + 1 ..]) |b| best = @min(best, std.math.hypot(a.x - b.x, a.y - b.y));
    }
    return best;
}

/// The {min, max} gap (mm) between `sites` and one straight track's COPPER — the
/// two numbers that say a whole fence sits at one distance from the copper edge,
/// flanks and wrapped ends alike, rather than at one distance from a centreline.
fn copperGapRange(sites: []const Site, t: router.Track) [2]f64 {
    var lo = std.math.inf(f64);
    var hi: f64 = 0;
    for (sites) |s| {
        const d = pad_shape.segPointDist(t.x1, t.y1, t.x2, t.y2, s.x, s.y) - t.width / 2;
        lo = @min(lo, d);
        hi = @max(hi, d);
    }
    return .{ lo, hi };
}

/// The smallest gap (mm) from any of `sites` to the world pad box
/// `x0,y0 .. x1,y1` — 0 when a site is inside that copper. The one number that says
/// whether a fence respected a foreign land, however many sites it placed.
fn padGapMin(sites: []const Site, box: [4]f64) f64 {
    var lo = std.math.inf(f64);
    for (sites) |s| lo = @min(lo, pad_shape.pointDist(box[0], box[1], box[2], box[3], &.{}, s.x, s.y, std.math.inf(f64)));
    return lo;
}

/// How many of `sites` land INSIDE the world pad box — the count that says a fence
/// took the via-in-pad a ground land offers it rather than merely tolerating it.
fn sitesInPad(sites: []const Site, box: [4]f64) usize {
    var n: usize = 0;
    for (sites) |s| {
        if (pad_shape.pointDist(box[0], box[1], box[2], box[3], &.{}, s.x, s.y, std.math.inf(f64)) <= 0) n += 1;
    }
    return n;
}

/// The {min, max} distance (mm) between CONSECUTIVE sites around one marched
/// contour, the wrap from last back to first included. On an evenly marched loop
/// both are the spacing (a chord across a tight curve reads a hair under it); a
/// SEAM — a missed wrap, a doubled site, a march that stopped one short — shows up
/// here as roughly double it, and shows up nowhere else in the counts.
fn wrapGapRange(sites: []const Site) [2]f64 {
    if (sites.len < 2) return .{ 0, 0 };
    var r = [2]f64{ std.math.inf(f64), 0 };
    for (sites, 0..) |a, i| {
        const b = sites[(i + 1) % sites.len];
        const d = std.math.hypot(a.x - b.x, a.y - b.y);
        r[0] = @min(r[0], d);
        r[1] = @max(r[1], d);
    }
    return r;
}

/// The {min, max} x of `sites` — how far along the trace's axis the fence reached,
/// which is how a test asks whether the wrapped ends are there at all.
fn xRange(sites: []const Site) [2]f64 {
    var r = [2]f64{ std.math.inf(f64), -std.math.inf(f64) };
    for (sites) |s| {
        r[0] = @min(r[0], s.x);
        r[1] = @max(r[1], s.x);
    }
    return r;
}

/// The {min, max} y of `sites` — which sides of a horizontal trace the fence
/// visited, and whether any site fell off the top edge of the fixture board.
fn yRange(sites: []const Site) [2]f64 {
    var r = [2]f64{ std.math.inf(f64), -std.math.inf(f64) };
    for (sites) |s| {
        r[0] = @min(r[0], s.y);
        r[1] = @max(r[1], s.y);
    }
    return r;
}

/// True when every site's provenance is `a`, or one of `a` and `b` when `b` is
/// non-empty — how a test asserts a whole run flanked exactly the fence targets.
fn fencedAmong(sites: []const Site, a: []const u8, b: []const u8) bool {
    for (sites) |s| {
        if (std.mem.eql(u8, s.fenced, a)) continue;
        if (b.len > 0 and std.mem.eql(u8, s.fenced, b)) continue;
        return false;
    }
    return true;
}

// spec: placement/via-fence - the generator marches the resolved pitch evenly around each guide contour of the net's copper, so the fence closes with no seam
test "a fenced trace is fenced by an evenly spaced closed guide" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{straight(10, 20, 10)};
    const res = try generate(arena, .{ .placement = rfFixture(&parts), .tracks = &tracks });

    try testing.expectEqual(@as(usize, 1), res.nets.len);
    const rep = res.nets[0];
    try testing.expectEqualStrings("RF", rep.net);
    try testing.expectEqualStrings("GND", rep.stitch);
    try testing.expectEqualStrings("", rep.err);
    // One connected blob of copper ⇒ one closed guide contour.
    try testing.expectEqual(@as(usize, 1), rep.contours);
    // The authored 0.6 mm is an EDGE gap, so the contour is traced 0.8 mm from
    // the copper — the gap plus the 0.4 mm via's own radius.
    try testing.expectApproxEqAbs(@as(f64, 0.6), rep.march.gap_mm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.8), rep.march.dist_mm, 1e-12);
    // Which around a 0.3 mm trace's 10 mm run is the racetrack at radius 0.95:
    // two straight flanks plus one full circle's worth of wrapped ends.
    const want = 20 + 2 * std.math.pi * 0.95;
    try testing.expectApproxEqAbs(want, rep.march.guide_mm, want * 0.01);
    // n = round(L / pitch) = 26 sites, spaced L / n — NOT the pitch itself, which
    // is what would leave a short seam where the march wraps.
    try testing.expectEqual(ringSites(rep.march.guide_mm, 1), rep.march.sites);
    try testing.expectEqual(@as(usize, 26), rep.march.sites);
    // All of which land: the default is the VETTED mode, and on a bare board in the
    // middle of the outline it has nothing to veto — every skip below is a board
    // rule this fixture does not break, not vetting being switched off.
    try testing.expectEqual(rep.march.sites, rep.placed);
    try testing.expectEqual(@as(usize, 0), rep.skipped.total());
    try testing.expectEqual(rep.placed, res.sites.len);
    try testing.expectEqualStrings("GND", res.sites[0].net);
    // The provenance tag names the FENCED net, not the stitched one — that is
    // what lets the fence invalidate with the trace it belongs to.
    try testing.expectEqualStrings("RF", res.sites[0].fenced);

    // Nowhere on the closed guide — the wrap included — do two neighbouring vias
    // sit further apart than the even spacing.
    const spacing = rep.march.guide_mm / @as(f64, @floatFromInt(rep.march.sites));
    const gaps = wrapGapRange(res.sites);
    try testing.expect(gaps[1] <= spacing * 1.01);
    try testing.expect(gaps[0] >= spacing * 0.9);
}

// spec: placement/via-fence - a (max-freq …) RF class is fenced even when it declares no (fence …), its pitch deriving as λg/10 exactly as a bare (fence)'s does
// spec: placement/via-fence - an impedance-only class is not a fence target: with no frequency there is no wavelength to derive a pitch from
// spec: placement/via-fence - the anyFenceable probe answers true for a max-freq RF class that declares no fence, so the Fence action and button cover such a board
// spec: placement/via-fence - anyFenceable answers false for a board whose classes carry neither a fence nor a max-freq
// spec: placement/via-fence - fenceable is the one predicate both the generate walk and the anyFenceable probe use, so "is there anything to fence" and "what gets fenced" can never diverge
test "a max-freq RF trace is fenced without a fence declaration" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The class carries ONLY a max-freq — the RF-facts spelling of "this is an RF
    // trace" — with no (fence) at all. The predicate that matters is the same one
    // the probe uses, so a board like this both shows the Fence action and fences.
    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const rules = &[_]NetRule{
        .{ .rf = .{ .max_freq_hz = 12e9 } },
        .{},
    };
    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{straight(10, 20, 10)};
    const placement = fixture(&parts, nets, rules);

    // The probe sees a fence target in the max-freq class alone — no (fence) on
    // the board — and an impedance-only class is deliberately NOT one.
    try testing.expect(anyFenceable(placement));
    try testing.expect(fenceable(rules[0]));
    try testing.expect(!fenceable(rules[1]));
    try testing.expect(!fenceable(.{ .rf = .{ .impedance = .{ .ohms = 50 } } }));
    try testing.expect(!fenceable(.{}));

    const res = try generate(arena, .{ .placement = placement, .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.nets.len);
    const rep = res.nets[0];
    try testing.expectEqualStrings("RF", rep.net);
    try testing.expectEqualStrings("GND", rep.stitch);
    try testing.expectEqualStrings("", rep.err);
    try testing.expect(res.sites.len > 0);
    for (res.sites) |site| try testing.expectEqualStrings("RF", site.fenced);
    // The derived pitch is λg/10 at 12 GHz in FR4 — c/(12 GHz·√εr)/10 — and the
    // gap is the class's clearance plus the fabrication margin, both numbers the
    // declared form would have resolved identically.
    try testing.expectApproxEqAbs(guidedWavelengthMm(12e9) / pitch_wavelength_divisor, rep.march.pitch_mm, 1e-9);
    try testing.expect(!rep.march.clamped);
    try testing.expectApproxEqAbs(resolvedGapMm(rules[0], .{}), rep.march.gap_mm, 1e-12);
    try testing.expectApproxEqAbs(resolvedGapMm(rules[0], .{}) + resolvedFenceVia(rules[0], .{}).dia / 2, rep.march.dist_mm, 1e-12);
}

// spec: placement/via-fence - the guide wraps past a fenced trace's endpoints, so the fence closes around its ends instead of leaving two open-ended rows
test "the fence wraps around the trace ends, not only along its sides" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{straight(10, 20, 10)};
    const res = try generate(arena, .{ .placement = rfFixture(&parts), .tracks = &tracks });

    // A level set has no ends, so it puts a via BEYOND each end of the trace —
    // the whole difference between a closed fence and two open-ended side rows.
    const xs = xRange(res.sites);
    try testing.expect(xs[1] > 20);
    try testing.expect(xs[0] < 10);
    // Both flanks are stitched too: the guide visits each side of the trace.
    const ys = yRange(res.sites);
    try testing.expect(ys[1] > 10);
    try testing.expect(ys[0] < 10);
    // …and every site, flank or wrapped end, sits the same distance from the
    // trace's COPPER — one constant-distance curve, not a pair of rows plus some
    // corner guesses.
    const d = copperGapRange(res.sites, tracks[0]);
    try testing.expectApproxEqAbs(@as(f64, 0.8), d[0], 0.02);
    try testing.expectApproxEqAbs(@as(f64, 0.8), d[1], 0.02);
}

// spec: placement/via-fence - a guide contour too short or too coarse for the pitch is still marched into a whole minimum ring, and copper with no length is wrapped in a circle
test "a sub-pitch contour still gets a whole minimum ring" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A perimeter under one pitch would round to one site, or none at all.
    try testing.expectEqual(min_ring_sites, ringSites(0.3, 5));
    try testing.expectEqual(min_ring_sites, ringSites(1.4, 1));
    // A degenerate perimeter or an unresolvable pitch takes the same floor rather
    // than dividing by zero.
    try testing.expectEqual(min_ring_sites, ringSites(0, 1));
    try testing.expectEqual(min_ring_sites, ringSites(10, 0));
    // Above the floor the pitch is what decides.
    try testing.expectEqual(@as(usize, 24), ringSites(23.767, 1));

    // Copper with no length is still copper: a collapsed segment's union is a
    // disc, so its guide is the full circle around it — a closed fence still.
    var pts = [_]optimizer.Part{};
    const dot = [_]router.Track{straight(5, 5, 5)};
    const ringed = try generate(arena, .{ .placement = rfFixture(&pts), .tracks = &dot });
    try testing.expectEqual(@as(usize, 1), ringed.nets[0].contours);
    try testing.expect(ringed.nets[0].placed >= min_ring_sites);
    for (ringed.sites) |site| {
        try testing.expectApproxEqAbs(@as(f64, 0.95), std.math.hypot(site.x - 5, site.y - 5), 0.02);
    }

    // End to end: a 0.4 mm stub at a 0.2 mm gap traces 4.26 mm of perimeter,
    // which against a 5 mm pitch rounds to nothing — so the floor is what lands.
    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 5, .offset_mm = 0.2 } } },
        .{},
    };
    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{straight(10, 10.4, 10)};
    const res = try generate(arena, .{ .placement = fixture(&parts, nets, rules), .tracks = &tracks });
    try testing.expectEqual(min_ring_sites, res.nets[0].march.sites);
    try testing.expectEqual(min_ring_sites, res.nets[0].placed);
}

// spec: placement/via-fence - a fenced net with pads but no routed track on any layer is left unfenced, because there is no routed path to shield yet
test "an unrouted fenced net is not fenced around its bare pads" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The RF net owns a real 1 mm pad but nothing has been routed to it.
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .fallback = false,
        .x = 15,
        .y = 10,
        .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1 }},
    }};
    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{.{ .ref_des = "U1", .pin = "1" }} },
        .{ .name = "GND", .pins = &.{} },
    };
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6 } } },
        .{},
    };
    const bare = try generate(arena, .{ .placement = fixture(&parts, nets, rules) });
    // Reported, resolved, and empty: a fence shields a routed path, and ringing a
    // pad that nothing reaches yet would just be copper in the way of routing it.
    try testing.expectEqual(@as(usize, 1), bare.nets.len);
    try testing.expectEqualStrings("", bare.nets[0].err);
    try testing.expectEqual(@as(usize, 0), bare.nets[0].contours);
    try testing.expectEqual(@as(usize, 0), bare.nets[0].march.sites);
    try testing.expectEqual(@as(usize, 0), bare.sites.len);

    // Route one segment INTO that pad and the pad joins the union: the fence now
    // wraps trace and pad together as one contour, standing off the pad's wider
    // copper by the same gap it keeps from the trace.
    const tracks = [_]router.Track{straight(11, 14.5, 10)};
    const routed = try generate(arena, .{ .placement = fixture(&parts, nets, rules), .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), routed.nets[0].contours);
    try testing.expect(routed.nets[0].placed > min_ring_sites);
    for (routed.sites) |site| {
        // Never inside the pad, and never nearer to its copper than the gap.
        try testing.expect(pad_shape.pointDist(14.5, 9.5, 15.5, 10.5, &.{}, site.x, site.y, 9) > 0.6);
    }
    // The fence bulges out around the pad rather than hugging the trace's own
    // 0.15 mm flank: the pad's copper ends at y = 10.5 and x = 15.5, and the fence
    // stands off BOTH of those edges.
    try testing.expect(yRange(routed.sites)[1] > 10.5);
    try testing.expect(xRange(routed.sites)[1] > 15.5);
}

// spec: placement/via-fence - a fence via is a through barrel, so the guide wraps the net's pads on every layer, a bottom-side land under a top-routed trace included
test "the guide wraps a bottom-side pad of a top-routed net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A board-to-board connector on the BOTTOM face, its land on the fenced net,
    // sitting right where a top-only guide would run.
    var parts = [_]optimizer.Part{.{
        .ref_des = "J1",
        .kind = .hub,
        .hw = 0.6,
        .hh = 0.3,
        .fallback = false,
        .x = 14.5,
        .y = 10,
        .side = .bottom,
        .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.4 }},
    }};
    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{.{ .ref_des = "J1", .pin = "1" }} },
        .{ .name = "GND", .pins = &.{} },
    };
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6 } } },
        .{},
    };
    // The trace runs on TOP copper only; the pad it feeds is on the bottom.
    const tracks = [_]router.Track{straight(10, 14, 10)};
    const res = try generate(arena, .{ .placement = fixture(&parts, nets, rules), .tracks = &tracks });
    try testing.expectEqual(@as(usize, 1), res.nets[0].contours);

    for (res.sites) |site| {
        // A through barrel exists on the bottom face too, so a site inside that
        // land would short the fenced net to ground — the copper it must clear is
        // the net's copper on EVERY layer, not just the routed one.
        const to_pad = pad_shape.pointDist(14, 9.8, 15, 10.2, &.{}, site.x, site.y, 9);
        try testing.expect(to_pad > 0.6);
    }
    // And the fence reaches around the far side of that land, 0.8 mm past it.
    try testing.expect(xRange(res.sites)[1] > 15.0);
}

// spec: placement/via-fence - every fenced through-via gets first claim on a local return-via ring, so general-contour dedup cannot consume the posts surrounding the transition
test "a fenced through-via gets a local guard ring" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{};
    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6 } } },
        .{},
    };
    const tracks = [_]router.Track{.{
        .x1 = 10,
        .y1 = 10,
        .x2 = 20,
        .y2 = 10,
        .layer = 0,
        .width = 1.2,
        .net = 0,
    }};
    const signal_via = [_]router.Via{.{ .x = 15, .y = 10, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const result = try generate(arena, .{
        .placement = fixture(&parts, nets, rules),
        .tracks = &tracks,
        .vias = &signal_via,
        .mode = .all,
    });

    // The trace's global contour is 1.4 mm from the via centre, close enough
    // that marching it first would deduplicate the north/south local posts. The
    // explicit local ring is at the requested 0.6 mm copper gap plus the 0.2 mm
    // fence-via radius, i.e. 1.0 mm from the signal-via centre.
    var local: usize = 0;
    for (result.sites) |site| {
        const distance = std.math.hypot(site.x - signal_via[0].x, site.y - signal_via[0].y);
        if (@abs(distance - 1.0) < 0.01) local += 1;
    }
    try testing.expect(local >= min_ring_sites);
}

// spec: placement/via-fence - the vetted legal mode is the default and drops the guide sites the board vetoes, while mode all places every one the geometry produced, both marching the same guide
test "mode all places the guide sites mode legal vetoes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    try testing.expectEqual(Mode.all, Mode.fromStr("all").?);
    try testing.expectEqual(Mode.legal, Mode.fromStr("legal").?);
    try testing.expect(Mode.fromStr("Legal") == null);
    try testing.expect(Mode.fromStr("") == null);

    // A trace hugging the top edge: the guide's upper flank falls off the board.
    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{straight(10, 20, 0.2)};
    const in = Input{ .placement = rfFixture(&parts), .tracks = &tracks };
    // Vetting is the DEFAULT: an unqualified run is the legal one, and `all` is the
    // debug view you have to ask for by name.
    try testing.expectEqual(Mode.legal, in.mode);
    const legal = try generate(arena, in);
    var all_in = in;
    all_in.mode = .all;
    const all = try generate(arena, all_in);

    // The SAME guide is marched either way — the mode decides only what may veto a
    // site, so a legal run is a strict subset of an all run.
    try testing.expectEqual(all.nets[0].march.sites, legal.nets[0].march.sites);
    try testing.expect(all.nets[0].placed > legal.nets[0].placed);
    try testing.expectEqual(all.nets[0].march.sites, all.nets[0].placed);
    try testing.expectEqual(@as(usize, 0), all.nets[0].skipped.total());
    // The board's veto is reported by reason, and it really is the outline: mode
    // all put vias off the top edge where mode legal refused to.
    try testing.expect(legal.nets[0].skipped.outline > 0);
    try testing.expect(yRange(all.sites)[0] < 0);
    try testing.expect(yRange(legal.sites)[0] > 0);
}

// spec: placement/via-fence - in legal mode a fence site landing on a pad of the stitch net is wanted via-in-pad, while a pad of any other net still skips it
test "via-in-pad on a ground pad is legal and a foreign pad still blocks" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // One 2 mm pad astride the guide, wide enough to swallow several sites on both
    // flanks. `P1` pad 1 is the pad; which NET owns it is the whole experiment.
    // It is on neither the fenced net nor its layer's union — it is an OBSTACLE,
    // which is what makes the stitch-net exemption the thing under test.
    var parts = [_]optimizer.Part{.{
        .ref_des = "P1",
        .kind = .passive,
        .hw = 1,
        .hh = 1,
        .fallback = false,
        .x = 15,
        .y = 10,
        .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 2, .h = 2 }},
    }};
    const tracks = [_]router.Track{straight(10, 20, 10)};
    const owner = [_]flat_netlist.FlatPin{.{ .ref_des = "P1", .pin = "1" }};
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6 } } },
        .{},
        .{},
    };

    // The pad belongs to the STITCH net: a fence via landing in it stitches that
    // ground pad straight to the plane, so nothing is skipped at all.
    const gnd_owned = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &owner },
        .{ .name = "V_5V", .pins = &.{} },
    };
    const on_gnd = try generate(arena, .{
        .placement = fixture(&parts, gnd_owned, rules),
        .tracks = &tracks,
        .mode = .legal,
    });
    try testing.expectEqualStrings("GND", on_gnd.nets[0].stitch);
    try testing.expectEqual(@as(usize, 0), on_gnd.nets[0].skipped.pad);
    try testing.expectEqual(on_gnd.nets[0].march.sites, on_gnd.nets[0].placed);

    // The identical pad on ANY other net is still a conflict, and the sites it
    // covers become counted gaps.
    const foreign_owned = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "V_5V", .pins = &owner },
    };
    const on_foreign = try generate(arena, .{
        .placement = fixture(&parts, foreign_owned, rules),
        .tracks = &tracks,
        .mode = .legal,
    });
    try testing.expect(on_foreign.nets[0].skipped.pad > 0);
    try testing.expect(on_foreign.nets[0].placed < on_gnd.nets[0].placed);
    // No surviving site sits inside the foreign pad's copper.
    for (on_foreign.sites) |s| {
        try testing.expect(!(@abs(s.x - 15) < 1 and @abs(s.y - 10) < 1));
    }
}

// spec: placement/via-fence - a fence pitch below the board's copper and hole-to-hole floor is clamped up to it and the clamp is reported
test "an unbuildably tight pitch clamps to the copper and hole-to-hole floor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const design = DesignRules{}; // via 0.4/0.2, clearance 0.127, hole-to-hole 0.25
    // Copper rule: 0.4 + 0.127 = 0.527. Hole rule: 0.2 + 0.25 = 0.45. Floor = 0.527.
    try testing.expectApproxEqAbs(@as(f64, 0.527), minPitchMm(.{ .dia = 0.4, .drill = 0.2 }, design), 1e-9);
    // A fat drill in a small ring makes the HOLE rule the binding one.
    try testing.expectApproxEqAbs(@as(f64, 0.65), minPitchMm(.{ .dia = 0.4, .drill = 0.4 }, design), 1e-9);

    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    // The class asks for 0.2 mm spacing — closer than two 0.4 mm rings can sit.
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 0.2, .offset_mm = 0.6 } } },
        .{},
    };
    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{straight(10, 20, 10)};
    const res = try generate(arena, .{ .placement = fixture(&parts, nets, rules), .tracks = &tracks });
    const rep = res.nets[0];
    try testing.expect(rep.march.clamped);
    try testing.expectApproxEqAbs(@as(f64, 0.527), rep.march.pitch_mm, 1e-9);
    // The FLOOR is what the guide is divided by, not the 0.2 mm that was asked
    // for: 49 sites around a 25.97 mm contour, so adjacent sites sit a whisker
    // over the floor rather than half of it.
    try testing.expectEqual(ringSites(rep.march.guide_mm, 0.527), rep.march.sites);
    try testing.expectEqual(@as(usize, 49), rep.march.sites);
    const spacing = rep.march.guide_mm / @as(f64, @floatFromInt(rep.march.sites));
    try testing.expect(spacing >= 0.527);
    try testing.expect(wrapGapRange(res.sites)[1] <= spacing * 1.01);
    // …and an honest pitch is not reported as clamped.
    var parts2 = [_]optimizer.Part{};
    const wide = try generate(arena, .{ .placement = rfFixture(&parts2), .tracks = &tracks });
    try testing.expect(!wide.nets[0].march.clamped);
}

// spec: placement/via-fence - two fenced traces sharing a corridor stitch it once, the second ring's coincident sites deduping against the first's in every mode
test "a shared corridor is fenced once, not twice" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF_A", .pins = &.{} },
        .{ .name = "RF_B", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const fenced = NetRule{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6 } } };
    const rules = &[_]NetRule{ fenced, fenced, .{} };
    var parts = [_]optimizer.Part{};
    // Two parallel runs 1.9 mm apart — twice the 0.95 mm the guide stands off a
    // 0.3 mm trace — so A's upper flank and B's lower flank are the SAME line and
    // the corridor between them is stitched once.
    const tracks = [_]router.Track{
        .{ .x1 = 10, .y1 = 10, .x2 = 20, .y2 = 10, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 10, .y1 = 11.9, .x2 = 20, .y2 = 11.9, .layer = 0, .width = 0.3, .net = 1 },
    };
    const res = try generate(arena, .{ .placement = fixture(&parts, nets, rules), .tracks = &tracks });
    try testing.expectEqual(@as(usize, 2), res.nets.len);
    // A fences itself completely; B finds its far flank and its wrapped ends free
    // and its near flank already stitched by A — deduped, not doubled. Dedup is the
    // one check that runs in EVERY mode: it is generation correctness rather than a
    // board rule, so `.all` reports the same 11 as this vetted default run.
    try testing.expectEqual(res.nets[0].march.sites, res.nets[0].placed);
    try testing.expectEqual(@as(usize, 26), res.nets[0].placed);
    try testing.expectEqual(@as(usize, 11), res.nets[1].skipped.dedup);
    try testing.expectEqual(@as(usize, 15), res.nets[1].placed);
    try testing.expectEqual(@as(usize, 0), res.nets[1].skipped.via);
    // Dedup is a COINCIDENCE rule at half the pitch, so nothing on the board ends
    // up closer than that to anything else — the shared corridor included.
    try testing.expect(closestPair(res.sites) >= 0.5 - 1e-9);
}

// spec: placement/via-fence - a fenced class with no resolvable pitch and a board with no ground net are reported per net, not crashed on
test "an unresolvable pitch and a groundless board are clean per-net errors" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{straight(10, 20, 10)};

    // A bare (fence) on a class with no (max-freq …): nothing to derive from.
    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const bare = &[_]NetRule{ .{ .rf = .{ .fence = .{ .declared = true } } }, .{} };
    const no_pitch = try generate(arena, .{ .placement = fixture(&parts, nets, bare), .tracks = &tracks });
    try testing.expectEqualStrings(err_unresolvable_pitch, no_pitch.nets[0].err);
    try testing.expectEqual(@as(usize, 0), no_pitch.sites.len);

    // A board whose only other net is a power rail has nothing to stitch to.
    const groundless = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "V_5V", .pins = &.{} },
    };
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6 } } },
        .{},
    };
    const no_gnd = try generate(arena, .{ .placement = fixture(&parts, groundless, rules), .tracks = &tracks });
    try testing.expectEqualStrings(err_no_ground, no_gnd.nets[0].err);
    try testing.expectEqual(@as(usize, 0), no_gnd.sites.len);
    try testing.expectEqualStrings("", no_gnd.ground);
}

// spec: placement/via-fence - the generator stitches every fence target — a declared (fence …) or a (max-freq …) RF trace — and only those a caller's net filter names; a plain net's copper is never marched
// spec: placement/via-fence - a max-freq RF class with no (fence …) is stitched with its derived pitch, so the Fence action covers the board's RF traces by default
test "fence targets are stitched, a filter narrows them, and a plain net is never marched" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF_A", .pins = &.{} },
        .{ .name = "SPI", .pins = &.{} },
        .{ .name = "PWR", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const fenced = NetRule{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6 } } };
    const rules = &[_]NetRule{ fenced, .{ .rf = .{ .max_freq_hz = 12e9 } }, .{}, .{} };
    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{
        straight(2, 8, 3),
        // A max-freq RF trace is a fence target too, even with no (fence) written.
        .{ .x1 = 2, .y1 = 8, .x2 = 8, .y2 = 8, .layer = 0, .width = 0.3, .net = 1 },
        // A plain net's copper is never marched, however long its track.
        .{ .x1 = 2, .y1 = 15, .x2 = 8, .y2 = 15, .layer = 0, .width = 0.3, .net = 2 },
    };
    const placement = fixture(&parts, nets, rules);
    const all = try generate(arena, .{ .placement = placement, .tracks = &tracks });
    // Two reports, in flatten order: the declared class and the max-freq class.
    // PWR is not a fence target, so it is neither marched nor reported.
    try testing.expectEqual(@as(usize, 2), all.nets.len);
    try testing.expectEqualStrings("RF_A", all.nets[0].net);
    try testing.expectEqualStrings("SPI", all.nets[1].net);
    // Every site the unfiltered run stitched flanks one of the two fence targets.
    try testing.expect(fencedAmong(all.sites, "RF_A", "SPI"));

    const only_spi = try generate(arena, .{ .placement = placement, .tracks = &tracks, .only = &.{"SPI"} });
    try testing.expectEqual(@as(usize, 1), only_spi.nets.len);
    try testing.expectEqualStrings("SPI", only_spi.nets[0].net);
    try testing.expect(fencedAmong(only_spi.sites, "SPI", ""));
}

// spec: placement/via-fence - in legal mode a fence site outside the board outline or inside its copper-edge clearance is skipped as an outline gap
test "the board outline clips the fence instead of hanging vias off the edge" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{};
    // A trace hugging the top edge: the flank at y = 1.15 is safely inside, while
    // the far flank (y = −0.75) and most of both wrapped ends are off-board.
    const tracks = [_]router.Track{straight(10, 20, 0.2)};
    const res = try generate(arena, .{ .placement = rfFixture(&parts), .tracks = &tracks, .mode = .legal });
    const rep = res.nets[0];
    try testing.expectEqual(@as(usize, 26), rep.march.sites);
    try testing.expectEqual(@as(usize, 13), rep.placed);
    try testing.expectEqual(@as(usize, 13), rep.skipped.outline);
    try testing.expectEqual(rep.march.sites, rep.placed + rep.skipped.total());
    // Every survivor clears the copper-to-edge rule, not merely the edge itself.
    const design = DesignRules{};
    for (res.sites) |s| try testing.expect(s.y > design.via_dia / 2 + design.edgeClearance());
}

// spec: placement/via-fence - a fence pitch derives a tenth of the guided wavelength from the class max-freq
test "fence pitch resolves from max-freq, and an authored pitch overrides it" {
    // barracuda's "rf" class: 12 GHz microstrip on FR4 ⇒ λg ≈ 11.91 mm ⇒ 1.191 mm
    // spacing, which matches the hand-fenced reference's ~1.18 mm median.
    const rf = NetRule{ .rf = .{ .max_freq_hz = 12e9, .fence = .{ .declared = true } } };
    try std.testing.expectApproxEqAbs(@as(f64, 1.191), resolvedPitchMm(rf), 0.001);
    // An authored (pitch …) is taken verbatim, max-freq or not.
    var authored = rf;
    authored.rf.fence.pitch_mm = 1.0;
    try std.testing.expectEqual(@as(f64, 1.0), resolvedPitchMm(authored));
}

// spec: placement/via-fence - a fence with neither pitch nor max-freq resolves to no spacing so the generator can report it unresolvable
test "fence pitch is zero when the class declares neither pitch nor max-freq" {
    const bare = NetRule{ .rf = .{ .fence = .{ .declared = true } } };
    try std.testing.expectEqual(@as(f64, 0), resolvedPitchMm(bare));
    // The wavelength helper is the guard: a non-positive frequency has none.
    try std.testing.expectEqual(@as(f64, 0), guidedWavelengthMm(0));
    try std.testing.expectEqual(@as(f64, 0), guidedWavelengthMm(-1));
}

// spec: placement/via-fence - a fence offset is the gap from the net's copper edge to the fence via's copper edge, derived from the class clearance and a fabrication margin
test "fence offset resolves an edge-to-edge gap, and an authored offset overrides it" {
    const design = DesignRules{}; // via 0.4/0.2, clearance 0.127, track 0.127
    // barracuda's "rf" class: its own 0.127 mm clearance + the 0.1 mm margin.
    const rf = NetRule{
        .width = 0.3124,
        .clearance = 0.127,
        .rf = .{ .max_freq_hz = 12e9, .fence = .{ .declared = true } },
    };
    try std.testing.expectApproxEqAbs(@as(f64, 0.227), resolvedGapMm(rf, design), 1e-9);
    // The guide is traced half a via further out, so the via's own COPPER lands
    // the gap from the net's copper.
    try std.testing.expectApproxEqAbs(@as(f64, 0.427), guideDistMm(rf, design), 1e-9);
    // Which beside the trace is exactly where the old centreline row sat —
    // 0.3124/2 + 0.427 — so redefining the number as an edge gap moved nothing
    // along a bare trace and everything around the pads it lands on.
    try std.testing.expectApproxEqAbs(
        @as(f64, 0.5832),
        rf.width / 2 + guideDistMm(rf, design),
        1e-9,
    );
    // The gap is width-BLIND: a fatter trace pushes its own copper edge out, and
    // the fence follows that edge rather than being resolved differently.
    var fat = rf;
    fat.width = 1.0;
    try std.testing.expectApproxEqAbs(resolvedGapMm(rf, design), resolvedGapMm(fat, design), 1e-12);
    // A class with no clearance of its own falls back to the board rule.
    const plain = NetRule{ .rf = .{ .fence = .{ .declared = true } } };
    try std.testing.expectApproxEqAbs(@as(f64, 0.227), resolvedGapMm(plain, design), 1e-9);
    // A looser class clearance loosens the fence with it.
    var loose = rf;
    loose.clearance = 0.2;
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), resolvedGapMm(loose, design), 1e-9);
    // An authored (offset …) wins outright, even when it is tighter than the
    // derived gap — the author is stating a measured number.
    var authored = rf;
    authored.rf.fence.offset_mm = 0.65;
    try std.testing.expectEqual(@as(f64, 0.65), resolvedGapMm(authored, design));
    // A wider fence via does NOT change the gap — it changes where the guide runs,
    // by exactly the extra radius, so the copper-to-copper gap is preserved.
    var big_via = authored;
    big_via.rf.fence.via_dia = 0.6;
    try std.testing.expectEqual(@as(f64, 0.65), resolvedGapMm(big_via, design));
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), guideDistMm(big_via, design), 1e-9);
}

// spec: placement/via-fence - a fence via falls back from the fence geometry to the class via to the board design rules
test "fence via geometry walks the fence-then-class-then-board fallback chain" {
    const design = DesignRules{};
    // Nothing authored anywhere ⇒ the board's (design-rules (via …)).
    const plain = NetRule{ .rf = .{ .fence = .{ .declared = true } } };
    try std.testing.expectEqual(FenceVia{ .dia = 0.4, .drill = 0.2 }, resolvedFenceVia(plain, design));
    // The class's own signal via outranks the board default.
    const class_via = NetRule{
        .via_dia = 0.45,
        .via_drill = 0.25,
        .rf = .{ .fence = .{ .declared = true } },
    };
    try std.testing.expectEqual(FenceVia{ .dia = 0.45, .drill = 0.25 }, resolvedFenceVia(class_via, design));
    // A (fence (via …)) outranks both — and each number falls back on its own,
    // so a fence declaring only a diameter keeps the class's drill.
    var fence_via = class_via;
    fence_via.rf.fence.via_dia = 0.3;
    try std.testing.expectEqual(FenceVia{ .dia = 0.3, .drill = 0.25 }, resolvedFenceVia(fence_via, design));
    fence_via.rf.fence.via_drill = 0.15;
    try std.testing.expectEqual(FenceVia{ .dia = 0.3, .drill = 0.15 }, resolvedFenceVia(fence_via, design));
}

/// A `Pass` over `placement` for the prefilter tests. `illegal` is probed at exact
/// coordinates rather than through `generate`, because the march offers sites only
/// at even divisions of a contour and none of them is guaranteed to land on the one
/// point where a rule is exactly satisfied — which is the point a threshold test has
/// to reach to prove the prefilter is not a micron stricter than the DRC.
fn probePass(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
) std.mem.Allocator.Error!Pass {
    return .{
        .arena = arena,
        .in = .{ .placement = placement, .tracks = tracks, .vias = vias, .mode = .legal },
        .design = placement.rules.design,
        .pads = try padObstacles(arena, placement),
        .via_keepouts = try viaKeepouts(arena, placement),
        .sites = .empty,
        .accepted = .empty,
    };
}

/// The board's own fence via and the GND net index of the prefilter fixtures.
const probe_via = FenceVia{ .dia = 0.4, .drill = 0.2 };
const probe_stitch: i32 = 1;

// spec: placement/via-fence - the legality prefilter judges a candidate on the DRC's own pairwise clearance and slack, so a site resting exactly on a rule is kept and one a micron inside it is skipped
// spec: placement/via-fence - a track of the stitch net is no more a conflict than a pad of it, while the net-blind hole-to-hole floor still applies to both
test "the prefilter's thresholds are the DRC's own, to the last micron" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const design = DesignRules{}; // clearance 0.127, via 0.4/0.2, hole-to-hole 0.25
    const vr = probe_via.dia / 2;
    var parts = [_]optimizer.Part{};

    // ── the board edge ────────────────────────────────────────────────────────
    // `board_edge` flags `inset − vr < edgeClearance`, so a via whose copper rests
    // EXACTLY on the rule is legal and must be kept.
    {
        var pass = try probePass(arena, rfFixture(&parts), &.{}, &.{});
        const edge = vr + design.edgeClearance();
        try testing.expect(pass.illegal(edge, 10, probe_via, probe_stitch) == null);
        try testing.expectEqual(SkipReason.outline, pass.illegal(edge - 1e-3, 10, probe_via, probe_stitch).?);
    }

    // ── a foreign track, and a track of the stitch net ────────────────────────
    {
        const foreign = [_]router.Track{straight(5, 15, 10)}; // net 0, the fenced RF net
        var pass = try probePass(arena, rfFixture(&parts), &foreign, &.{});
        const need = vr + 0.3 / 2.0 + design.clearance;
        try testing.expect(pass.illegal(10, 10 + need, probe_via, probe_stitch) == null);
        try testing.expectEqual(SkipReason.track, pass.illegal(10, 10 + need - 1e-3, probe_via, probe_stitch).?);

        // The SAME track on the stitch net is not an obstacle at all: ground copper
        // meeting a ground barrel is one conductor, which is what a fence builds. A
        // via dead on its centreline is legal.
        var gnd = foreign;
        gnd[0].net = probe_stitch;
        var gnd_pass = try probePass(arena, rfFixture(&parts), &gnd, &.{});
        try testing.expect(gnd_pass.illegal(10, 10, probe_via, probe_stitch) == null);
    }

    // ── an existing via, foreign and same-net ─────────────────────────────────
    {
        const gnd_via = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.6, .drill = 0.3, .net = probe_stitch }};
        var pass = try probePass(arena, rfFixture(&parts), &.{}, &gnd_via);
        // Same net ⇒ the FOREIGN copper rule is off, but two rules still bind: the
        // net-blind drill station (two ground bores crowd the bit exactly as much
        // as two signal bores) and the same-net via SPACING rule, which at these
        // diameters is the wider of the two. Both are checked at their own
        // exact thresholds — see the via-spacing test below.
        const bore = probe_via.drill / 2 + 0.3 / 2.0 + design.hole_to_hole;
        try testing.expectApproxEqAbs(@as(f64, 0.5), bore, 1e-12);
        const same_net = vr + 0.6 / 2.0 + design.clearance;
        try testing.expect(same_net > bore);
        try testing.expect(pass.illegal(10 + same_net, 10, probe_via, probe_stitch) == null);
        try testing.expectEqual(SkipReason.via, pass.illegal(10 + bore - 1e-3, 10, probe_via, probe_stitch).?);

        // The identical via on another net owes copper clearance too, which at these
        // diameters binds well outside the hole rule.
        var foreign = gnd_via;
        foreign[0].net = 0;
        var fpass = try probePass(arena, rfFixture(&parts), &.{}, &foreign);
        const copper = vr + 0.6 / 2.0 + design.clearance;
        try testing.expect(copper > bore);
        try testing.expectEqual(SkipReason.via, fpass.illegal(10 + bore, 10, probe_via, probe_stitch).?);
        try testing.expect(fpass.illegal(10 + copper, 10, probe_via, probe_stitch) == null);
    }
}

// spec: placement/via-fence - a fence site crowding an existing via of its own stitch net is refused as a duplicate drill rather than placed
test "a fence site on top of its own stitch net's via is a duplicate drill, not a post" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const design = DesignRules{}; // clearance 0.127, hole-to-hole 0.25
    var parts = [_]optimizer.Part{};
    // A routed GROUND via — the stitch net's own copper — with a wide bore, so
    // the drill rule is satisfied well before the copper rule is.
    const gnd_via = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.4, .drill = 0.2, .net = probe_stitch }};
    var pass = try probePass(arena, rfFixture(&parts), &.{}, &gnd_via);
    // A second ground barrel a fraction of a millimetre away shields nothing the
    // first one did not, and is exactly the `via_spacing` finding the board's own
    // DRC would raise — so the prefilter refuses it instead of planting it.
    const spacing = probe_via.dia / 2 + 0.4 / 2.0 + design.clearance;
    try testing.expectEqual(SkipReason.via, pass.illegal(10 + spacing - 1e-3, 10, probe_via, probe_stitch).?);
    // A site resting exactly ON the rule is kept, matching the DRC's slack …
    try testing.expect(pass.illegal(10 + spacing, 10, probe_via, probe_stitch) == null);
    // … and a real fence pitch (~1.2 mm) is never in question.
    try testing.expect(pass.illegal(11.2, 10, probe_via, probe_stitch) == null);
}

// spec: placement/via-fence - a ground fence via stays outside the signal via's synthesized plane antipad, including the 50-ohm default of a max-freq-only RF class
test "a fence site clears the exact controlled-impedance via antipad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{};
    const nets = &[_]flat_netlist.FlatNet{ .{ .name = "RF", .pins = &.{} }, .{ .name = "GND", .pins = &.{} } };
    const rules = &[_]NetRule{
        .{ .rf = .{ .impedance = .{ .ohms = 50 }, .fence = .{ .declared = true, .pitch_mm = 1 } } },
        .{},
    };
    var placement = fixture(&parts, nets, rules);
    placement.rules.physical.stack = .{ .layers = 4, .board_mm = 1.6 };
    const rf = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.4, .drill = 0.2, .net = 0 }};
    var pass = try probePass(arena, placement, &.{}, &rf);
    const anti = via_antipad.solve(placement.rules.physical.stack, 50, 0.4, 0.2, placement.rules.design.clearance).?;
    const centre = anti.antipad_dia_mm / 2 + probe_via.dia / 2;
    try testing.expectEqual(SkipReason.via, pass.illegal(10 + centre - 0.001, 10, probe_via, probe_stitch).?);
    try testing.expect(pass.illegal(10 + centre, 10, probe_via, probe_stitch) == null);

    // A max-freq-only class gets the same 50-ohm transition model used by the
    // plane pour and mask opening; omitting an explicit impedance may not let
    // the local fence ring enter the real antipad.
    const derived = [_]NetRule{
        .{ .rf = .{ .max_freq_hz = 12e9 } },
        .{},
    };
    placement.rules.net = &derived;
    var derived_pass = try probePass(arena, placement, &.{}, &rf);
    try testing.expectEqual(SkipReason.via, derived_pass.illegal(10 + centre - 0.001, 10, probe_via, probe_stitch).?);
    try testing.expect(derived_pass.illegal(10 + centre, 10, probe_via, probe_stitch) == null);
}

// spec: placement/via-fence - a foreign pad is measured on its real outline and its bore on the capsule the drill station measures, so neither a chamfered corner nor a slot's length vetoes a site the DRC would pass
test "a pad's outline and its slot's capsule decide, not their bounding boxes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const design = DesignRules{};
    const vr = probe_via.dia / 2;
    const owner = [_]flat_netlist.FlatPin{.{ .ref_des = "P1", .pin = "1" }};
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6 } } },
        .{},
        .{},
    };

    // ── a chamfered (polygon) land on a foreign net ───────────────────────────
    // A 1 mm octagon: its BOUNDING BOX still reaches each corner of the 1 mm
    // square, while its copper is cut back 0.3 mm diagonally. A site off that
    // corner clears the copper by 0.42 mm and the box by only 0.21 mm, so which
    // one is measured decides whether it lands.
    const octagon = [_][2]f64{
        .{ 0.5, 0.2 },   .{ 0.2, 0.5 },   .{ -0.2, 0.5 }, .{ -0.5, 0.2 },
        .{ -0.5, -0.2 }, .{ -0.2, -0.5 }, .{ 0.2, -0.5 }, .{ 0.5, -0.2 },
    };
    {
        var parts = [_]optimizer.Part{.{
            .ref_des = "P1",
            .kind = .passive,
            .hw = 0.5,
            .hh = 0.5,
            .fallback = false,
            .x = 15,
            .y = 10,
            .pads = &.{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .poly = &octagon }},
        }};
        const nets = &[_]flat_netlist.FlatNet{
            .{ .name = "RF", .pins = &.{} },
            .{ .name = "GND", .pins = &.{} },
            .{ .name = "V_5V", .pins = &owner },
        };
        var pass = try probePass(arena, fixture(&parts, nets, rules), &.{}, &.{});
        const clear = vr + design.clearance; // 0.327 mm from the copper to the centre
        // 0.15 mm off the box corner: 0.21 mm from the box, 0.42 mm from the copper.
        try testing.expect(pass.illegal(15.65, 10.65, probe_via, probe_stitch) == null);
        // 0.05 mm off it: 0.28 mm from the real copper, which IS inside the rule.
        try testing.expectEqual(SkipReason.pad, pass.illegal(15.55, 10.55, probe_via, probe_stitch).?);
        // …and the rule is the plain pairwise one, measured on the flat of the pad.
        try testing.expect(pass.illegal(15.5 + clear, 10, probe_via, probe_stitch) == null);
        try testing.expectEqual(SkipReason.pad, pass.illegal(15.5 + clear - 1e-3, 10, probe_via, probe_stitch).?);
    }

    // ── a GROUND mounting slot: exempt copper, net-blind bore ─────────────────
    // An M2 SMT spacer bonded to ground (barracuda has one): its copper is the
    // stitch net's, so only its 1.4 mm-long slotted BORE can veto — and the DRC
    // measures that bore as the capsule swept along the slot, not as a disc
    // swallowing its whole length, so beside the slot's flank the rule is the same
    // 0.55 mm it is beside a round bore.
    {
        var parts = [_]optimizer.Part{.{
            .ref_des = "P1",
            .kind = .passive,
            .hw = 0.5,
            .hh = 0.2,
            .fallback = false,
            .x = 15,
            .y = 10,
            .pads = &.{.{
                .number = "1",
                .x = 0,
                .y = 0,
                .w = 1.0,
                .h = 0.4,
                .thru = true,
                .drill = 0.4,
                .slot_half = .{ 0.5, 0 },
            }},
        }};
        const nets = &[_]flat_netlist.FlatNet{
            .{ .name = "RF", .pins = &.{} },
            .{ .name = "GND", .pins = &owner },
            .{ .name = "V_5V", .pins = &.{} },
        };
        var pass = try probePass(arena, fixture(&parts, nets, rules), &.{}, &.{});
        const wall = probe_via.drill / 2 + 0.4 / 2.0 + design.hole_to_hole;
        try testing.expectApproxEqAbs(@as(f64, 0.55), wall, 1e-12);
        try testing.expect(pass.illegal(15, 10 + wall, probe_via, probe_stitch) == null);
        try testing.expectEqual(SkipReason.pad, pass.illegal(15, 10 + wall - 1e-3, probe_via, probe_stitch).?);
        // Off the slot's END the same wall rule applies from the far arc centre, so
        // the veto reaches half the slot further out along its axis than across it.
        try testing.expect(pass.illegal(15.5 + wall, 10, probe_via, probe_stitch) == null);
        try testing.expectEqual(SkipReason.pad, pass.illegal(15.5 + wall - 1e-3, 10, probe_via, probe_stitch).?);
    }
}

// spec: placement/via-fence - a fence via geometry the board's own annular-ring or min-drill rule rejects is refused per net rather than placed and then culled
test "an unbuildable fence via is refused with a reason, not fenced with" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const design = DesignRules{}; // min-annular 0.1, min-drill 0.2
    // The board's own via sits exactly on the annular rule, so the default fences.
    try testing.expect(viaBuildable(.{ .dia = 0.4, .drill = 0.2 }, design));
    // A ring under the rule and a bore under it each fail on their own.
    try testing.expect(!viaBuildable(.{ .dia = 0.35, .drill = 0.2 }, design));
    try testing.expect(!viaBuildable(.{ .dia = 0.4, .drill = 0.15 }, design));
    // An undrilled via has neither a ring nor a bore to judge.
    try testing.expect(viaBuildable(.{ .dia = 0.4, .drill = 0 }, design));

    // End to end: the class asks for a 0.35/0.2 fence via, which every site would
    // report as the same annular-ring error. The net is reported unfenced with a
    // reason instead — a hundred identical violations for the ratchet to chew
    // through is not a filter, and its rounds are bounded anyway.
    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.6, .via_dia = 0.35, .via_drill = 0.2 } } },
        .{},
    };
    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{straight(10, 20, 10)};
    const res = try generate(arena, .{ .placement = fixture(&parts, nets, rules), .tracks = &tracks });
    try testing.expectEqualStrings(err_via_unbuildable, res.nets[0].err);
    try testing.expectEqual(@as(usize, 0), res.nets[0].march.sites);
    try testing.expectEqual(@as(usize, 0), res.sites.len);
}

// spec: placement/via-fence - the twin pad of a series part the fenced net lands on is foreign copper, so the guide's sites over it are skipped, while a ground twin takes the via-in-pad
test "a series part's twin pad blocks the fence, unless the twin is ground" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A real 0402: two 0.56 x 0.62 lands 0.4 mm apart. The fenced net lands on pad
    // 1, so the guide wraps pad 1's copper — and at any sane gap that contour runs
    // straight over pad 2. This is the dominant skip pattern on a routed RF board:
    // every series cap and every DC block on the chain has one.
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.91,
        .hh = 0.46,
        .fallback = false,
        .x = 15,
        .y = 10,
        .pads = &.{
            .{ .number = "1", .x = 0.48, .y = 0, .w = 0.56, .h = 0.62 },
            .{ .number = "2", .x = -0.48, .y = 0, .w = 0.56, .h = 0.62 },
        },
    }};
    const rf_pad = flat_netlist.FlatPin{ .ref_des = "C1", .pin = "1" };
    const twin = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "2" }};
    const rules = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.3 } } },
        .{},
        .{},
    };
    const tracks = [_]router.Track{straight(16, 20, 10)};

    // The twin on a FOREIGN net: a via there would short the RF chain to it, so
    // every site it covers is a counted gap and none survives inside its copper.
    const foreign = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{rf_pad} },
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "V_5V", .pins = &twin },
    };
    const design = DesignRules{};
    const twin_box = [4]f64{ 14.24, 9.69, 14.8, 10.31 }; // pad 2's world copper
    const blocked = try generate(arena, .{ .placement = fixture(&parts, foreign, rules), .tracks = &tracks });
    try testing.expect(blocked.nets[0].skipped.pad > 0);
    try testing.expect(padGapMin(blocked.sites, twin_box) >= probe_via.dia / 2 + design.clearance);

    // The identical twin on GROUND: the same sites are now wanted via-in-pad, so
    // nothing is skipped for a pad at all and at least one via lands INSIDE that
    // land, stitching it straight to the plane.
    const grounded = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{rf_pad} },
        .{ .name = "GND", .pins = &twin },
        .{ .name = "V_5V", .pins = &.{} },
    };
    const stitched = try generate(arena, .{ .placement = fixture(&parts, grounded, rules), .tracks = &tracks });
    try testing.expectEqual(@as(usize, 0), stitched.nets[0].skipped.pad);
    try testing.expect(stitched.nets[0].placed > blocked.nets[0].placed);
    try testing.expect(sitesInPad(stitched.sites, twin_box) > 0);
}

// spec: placement/via-fence - a derived fence gap is raised to the pairwise clearance the stitch net and the fenced net owe each other, while an authored offset still wins outright
test "the fence gap answers to both nets' classes, not the fenced one's alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // GND's own class asks for 0.4 mm — more than the RF class's 0.127 mm default.
    // The pairwise rule between them is therefore 0.4 mm, and a fence derived from
    // the RF class alone would stand off only 0.227 mm: legal against nothing, and
    // refused by the prefilter against the very trace it is meant to shield.
    const nets = &[_]flat_netlist.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const derived = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1 } } },
        .{ .clearance = 0.4 },
    };
    var parts = [_]optimizer.Part{};
    const tracks = [_]router.Track{straight(10, 20, 10)};
    const res = try generate(arena, .{ .placement = fixture(&parts, nets, derived), .tracks = &tracks });
    const rep = res.nets[0];
    // 0.4 mm + the fabrication margin, not 0.127 mm + it.
    try testing.expectApproxEqAbs(@as(f64, 0.5), rep.march.gap_mm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.7), rep.march.dist_mm, 1e-12);
    // Which is what makes the whole ring land: the guide now stands off far enough
    // that every site clears the pairwise rule it is actually judged by.
    try testing.expectEqual(rep.march.sites, rep.placed);
    try testing.expectEqual(@as(usize, 0), rep.skipped.track);

    // An AUTHORED offset of exactly the under-stated number is still taken verbatim
    // — the author is stating a measured gap — and the prefilter is what catches it:
    // every site is refused against the fenced trace, counted rather than shorted.
    const authored = &[_]NetRule{
        .{ .rf = .{ .fence = .{ .declared = true, .pitch_mm = 1, .offset_mm = 0.227 } } },
        .{ .clearance = 0.4 },
    };
    const tight = try generate(arena, .{ .placement = fixture(&parts, nets, authored), .tracks = &tracks });
    try testing.expectApproxEqAbs(@as(f64, 0.227), tight.nets[0].march.gap_mm, 1e-12);
    try testing.expectEqual(@as(usize, 0), tight.nets[0].placed);
    try testing.expectEqual(tight.nets[0].march.sites, tight.nets[0].skipped.track);
}
