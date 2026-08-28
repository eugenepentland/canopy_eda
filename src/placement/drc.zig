//! Post-route design-rule check. Flags every pair of copper features on
//! *different* nets closer than the clearance rule (via↔pad, via↔via, via↔track,
//! track↔track, track↔pad, pad↔pad across parts), plus the drill/edge/courtyard/
//! mask/silk/width and differential-pair rules. Track↔copper is geometric
//! (off-maze stubs, hand-drawn/stamped copper aren't grid-spaced) and layer-aware
//! (SMD pad clashes only on its own side, a through pad on every layer). Gaps are
//! edge-to-edge mm (0 ⇒ touching, − ⇒ overlapping); pairwise loops are grid-culled.

const std = @import("std");
const bend_smooth = @import("bend_smooth.zig");
const copper_support = @import("copper_support.zig");
const copper_topology = @import("copper_topology.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const drc_diffpair = @import("drc_diffpair.zig");
const drc_keepout = @import("drc_keepout.zig");
const drc_perimeter_keepout = @import("drc_perimeter_keepout.zig");
const drc_match = @import("drc_match.zig");
const geometry = @import("geometry.zig");
const keepout = @import("keepout.zig");
const land_transit = @import("land_transit.zig");
const net_identity = @import("net_identity.zig");
const pad_shape = @import("pad_shape.zig");
const pad_neck = @import("pad_neck.zig");
const plane_stitch = @import("plane_stitch.zig");
const power_integrity = @import("power_integrity.zig");
const pour = @import("pour.zig");
const path_copper = @import("path_copper.zig");
const pose_math = @import("pose_math.zig");
const outline = @import("outline.zig");
const RfSample = @import("rf_path_solver.zig").Sample;
const via_antipad = @import("via_antipad.zig");
const board_layers = @import("../board_layers.zig");
const flat_netlist = @import("../flat_netlist.zig");
const numeric = @import("../numeric.zig");

const FlatNet = flat_netlist.FlatNet;

/// What two features clash (the page marker label). `annular`/`pad_annular` =
/// via / plated-thru-pad ring under the fab minimum; `board_edge` = copper (a
/// track, a via, or a component land) near the outline; `component_edge` = a
/// component courtyard/body proxy inside the assembly edge margin; `courtyard`/
/// `hole_hole`/`min_drill`/`track_width`/
/// `silk_over_pad` as named; `diff_uncoupled`/`diff_skew` = differential-pair
/// coupling / length-match warnings (see `drc_diffpair.zig`).
pub const Kind = enum {
    via_pad,
    via_via,
    /// Two vias of the SAME net crowded together — a redundant drill planted
    /// beside copper that already reaches both layers. `via_via` skips a
    /// same-net pair (electrically they are one node), so before this rule the
    /// only thing left covering them was the net-blind `hole_hole` drill wall,
    /// which a board declaring a tight `(design-rules (hole-to-hole …))` lets
    /// through at a copper gap of microns. See `viaSpacingRule`.
    via_spacing,
    via_track,
    track_track,
    track_pad,
    pad_pad,
    annular,
    pad_annular,
    board_edge,
    component_edge,
    courtyard,
    hole_hole,
    min_drill,
    track_width,
    /// Routed power copper is below its IPC/current target at the worst
    /// clearance-constrained neck. Fabrication geometry remains legal.
    power_width,
    /// A final plane/pour component cannot be represented as one unambiguous
    /// solid: an outer or hole is degenerate/self-intersecting, a hole crosses
    /// or escapes its outer, or sibling holes touch/overlap.
    pour_invalid,
    /// Different-net final pour solids overlap or touch on the same physical
    /// copper layer. Same-net pours intentionally remain free to merge.
    pour_overlap,
    /// A routed trace endpoint that lands on no same-net pad, via, pour, or
    /// other trace. This is disconnected artifact copper and therefore an
    /// error, even when the net's real terminals are connected elsewhere.
    copper_stub,
    /// Same-net trace capsules physically touch, but the two stored
    /// centrelines have no explicit endpoint-on-centreline junction. The board
    /// will conduct as drawn, yet the router must not use a width-dependent
    /// graze as its proof of connectivity. Generated routes canonicalize these
    /// joins; saved/imported copper receives one warning per implicit contact.
    implicit_junction,
    /// Same-net copper separated by more than the 1 µm contact tolerance
    /// but no more than 20 µm. It remains electrically open and fabrication
    /// must not decide whether it happens to conduct.
    hairline_gap,
    /// A stored trace section whose deletion preserves the connectivity of all
    /// pads, useful vias, and pours. One finding is emitted per section. The
    /// copper is electrically redundant, so this is a warning; a saved board
    /// carrying one wants a re-route or a hand delete.
    dangling_copper,
    /// A through-via whose barrel reaches fewer than two copper layers. It is
    /// electrically redundant but fabrication-safe, so this is a warning.
    single_layer_via,
    /// A through-via that may reach several copper layers but is not an
    /// articulation of the same-net copper graph. Deleting the jointly planned
    /// subset leaves every pad, trace, and remaining via component connected
    /// exactly as before. Ground is excluded; unnamed legacy fill contacts are
    /// conservatively retained.
    redundant_via,
    /// SAME-net copper lying on a pad's land without being aimed at its centre
    /// — a run that laps a flank or turns beside the land rather than
    /// terminating on it. Electrically nothing (a track anywhere on a land is
    /// the same node, which is why every clearance rule stays silent), but the
    /// copper that laps a land continues into the corridor between it and its
    /// neighbour, which on a fine-pitch part is a fifth of a millimetre wide.
    /// A warning: the board still builds. See `land_transit.zig`.
    land_transit,
    /// An SMD ground pad whose nearest same-net through via is farther away
    /// than the authored `(ground-via-max MM)` budget. This is a return-path
    /// inductance warning, not a fabrication defect.
    ground_via_distance,
    /// Fast-net copper passes over a void in its exact fabricated reference
    /// plane fill (split, slot, antipad wall, or missing plane island).
    reference_plane_gap,
    /// A signal via changes physical reference planes without the required
    /// nearby reference-net stitching via or cross-reference capacitor.
    reference_transition,
    /// Estimated trace/reference loop area exceeds the net class's authored
    /// `(return-path (max-loop-area …))` budget.
    loop_area,
    /// A decoupling capacitor's rail land has no continuous same-face copper
    /// path to the exact IC supply land its placement loop targets. A remote
    /// rail pour or two independent plane drops may make the NET connected,
    /// but they do not make the local high-frequency bypass connection.
    bypass_open,
    silk_over_pad,
    diff_uncoupled,
    diff_skew,
    /// A `(net-class … (match-group "NAME" (tolerance MM)))` group whose routed
    /// members differ in effective length by more than the declared spread — an
    /// electrical PREFERENCE (a timing budget), so a WARNING like the diff-pair
    /// rules it generalizes, never a fab-blocking error. See `drc_match.zig`.
    length_mismatch,
    sharp_bend,
    /// Foreign copper inside a net's declared `(net-class … (keepout MM))`
    /// same-layer halo — an RF isolation preference, so a WARNING (see
    /// `drc_keepout.zig`), never a fab-blocking error unless escalated per
    /// design from the DRC policy drawer.
    keepout_violation,
    /// A component, track, or via inside the fixed exclusion band authored by
    /// `(board … (perimeter-fence … (keepout …)))`. Unlike an RF isolation
    /// preference, this is board-construction geometry and is fab-blocking.
    perimeter_keepout,
    /// A net whose drawn copper does not all connect — two islands that never
    /// join (fab-fatal, invisible to clearance). Produced by `net_open.zig`,
    /// layered on at the serve seam (`drc_rules.checkFiltered`), not in
    /// `check` — the router/WASM hot paths never pay its per-net pour raster.
    net_open,
};

/// Severity: `err` blocks the fab gate; `warn` is informational only. Every
/// `Violation` defaults to `err`; the assembly-hygiene + diff-pair checks `warn`.
pub const Severity = enum { err, warn };

/// One hand-authored copper region credited by the topology checks (see
/// `copper_support.Zone`). Re-exported under the historical name so every
/// caller keeps spelling it `drc.TopologyZone`; the type and every reading
/// taken from it live in `copper_support`, which is also what the router's
/// finish consumes, so check and cleanup cannot disagree about the board.
pub const TopologyZone = copper_support.Zone;

/// The ONE canonical kind → built-in severity table. Every producer stamps its
/// violations from here (`drc.zig`'s own hygiene + bend rules, `drc_diffpair`,
/// `drc_keepout`, `net_open`) and the serve layer's DRC-policy drawer renders
/// the same answer through `drc_rules.defaultSeverity`, so the emitted severity
/// and the advertised default cannot disagree.
///
/// It exists because they DID disagree: the table was written as a copy of the
/// `severity = .warn` sites in this file, then `diff_uncoupled` / `diff_skew`
/// moved out to `drc_diffpair.zig` and the copy was never updated — the checker
/// emitted warnings while the policy drawer advertised (and, for anything
/// reading the table rather than the violation, treated) them as fab errors.
///
/// Warnings are the findings a board can still be fabricated with: assembly
/// hygiene (courtyard / silk over pad), RF preferences (keepout
/// halo, sharp bend), and differential-pair coupling / skew. Everything else is
/// a fab error and blocks the gate.
pub fn defaultSeverity(k: Kind) Severity {
    return switch (k) {
        // Assembly hygiene — the board builds; a human decides whether to care.
        .component_edge, .courtyard, .silk_over_pad, .single_layer_via, .redundant_via => .warn,
        // Copper lying wholly on its own net's land: junk a reader should not
        // have to explain, but it can neither short nor open a net.
        .dangling_copper, .implicit_junction => .warn,
        // Same-net copper lapping a land it does not terminate on: a
        // solder-bridge risk a reader should see, not a fab rule — it can
        // neither short (it is the pad's own net) nor open anything.
        .land_transit => .warn,
        // A legal board can still have a long ground return. The authored
        // distance is an SI budget, so report it without blocking fabrication.
        .ground_via_distance, .reference_plane_gap, .reference_transition, .loop_area, .power_width => .warn,
        // The board can still fabricate, but the authored bypass relationship
        // is electrically ineffective at high frequency until its local
        // surface leg reaches the intended IC land.
        .bypass_open => .warn,
        // RF bend discipline: a corner the smoothing pass could not round to its
        // required radius is a signal-integrity preference, not a fab rule.
        .sharp_bend => .warn,
        // An RF keepout intrusion is likewise a preference: the board still
        // builds. Error severity is what `drc.errorCount` gates — add_tracks,
        // close_open_nets and the fence ratchet all refuse to write above zero —
        // so this MUST stay a warning or advisory findings would block hand
        // routing. Per-design escalation lives in the viewer's DRC policy drawer.
        .keepout_violation => .warn,
        .perimeter_keepout => .err,
        // Differential-pair coupling / length match (see `drc_diffpair.zig`):
        // both require BOTH legs routed, both are tolerance-window judgements,
        // and neither stops a fab house — deliberately non-blocking.
        .diff_uncoupled, .diff_skew => .warn,
        // A `(match-group …)` spread over budget is the same shape of judgement
        // across N nets instead of two: the board builds and the copper is
        // legal, a timing margin is what is at risk. Warning severity is also
        // load-bearing — `drc.errorCount` gates add_tracks / close_open_nets /
        // the fence ratchet, so an over-budget bus must not lock hand routing
        // out of the very edits that would fix it. Escalate per design from the
        // viewer's DRC policy drawer.
        .length_mismatch => .warn,
        else => .err,
    };
}

/// The fab-blocking subset of a violation list: every `err`-severity violation
/// EXCEPT `net_open`. The ONE spelling of "how many errors does this copper
/// have" — the hand-routing rollback gate, the fab-readiness gate, and the
/// `route_score` DRC term all count through here so they cannot drift apart.
///
/// Warnings are excluded because a sharp-bend / diff-skew warning is not a
/// reason to roll back hand copper, and counting them rejects good routes.
///
/// `net_open` is excluded because it is CONNECTIVITY, not geometry, and every
/// surface that reports it already reports connectivity as `routed` / `total` /
/// `open`. Counting it here as well charges the same defect twice. Two measured
/// consequences:
///
///   • The hand-route rollback gate rejected the FIRST step of every run: an
///     escape stub that leaves a sealed pad and lands on fresh copper raises the
///     open-net count by one until the run is finished, so a geometrically
///     perfect, DRC-silent polyline was undone and the draw/measure/adjust loop
///     could never start. Measured on barracuda: the LMX2595 escape stub added
///     zero clearance findings and was rolled back anyway.
///   • `route_score` inverted its own objective. Completion is meant to
///     dominate (`route_score.zig`: 1000·completion vs 50·drc_errors), but one
///     open net on a 90-net board costs 11.1 through completion and 50+ through
///     a doubled-up DRC term — so a ranking search preferred candidates that
///     routed FEWER nets.
pub fn errorCount(violations: []const Violation) usize {
    var n: usize = 0;
    for (violations) |v| {
        if (v.severity == .err and v.kind != .net_open) n += 1;
    }
    return n;
}

/// WHO a violation is between — the identity a bare "track↔pad, gap 0.08 mm"
/// otherwise leaves the reader to reverse-engineer from coordinates. `net_a` /
/// `net_b` index `placement.nets`, `part_a` / `part_b` index `placement.parts`,
/// `track_a` identifies the indexed stored copper member when topology cleanup
/// needs to consume the finding: a route section normally, or a barrel for the
/// two via-artifact kinds. `pad_a` / `pad_b` are those parts' pad numbers
/// (borrowed from the footprint, so this stays allocation-free on the router's
/// hot path).
///
/// A missing party is `-1` / `""`: a courtyard clash has parts but no net, a
/// `board_edge` has one net and no second party, and a `net_open` names ONE net
/// (its own) with the pads of the two islands it failed to join. Reporting only
/// These identities never change a verdict.
pub const Parties = struct {
    net_a: i32 = -1,
    net_b: i32 = -1,
    part_a: i32 = -1,
    part_b: i32 = -1,
    track_a: i32 = -1,
    pad_a: []const u8 = "",
    pad_b: []const u8 = "",
    /// Reporting-only nearest probe points for an open net: ax, ay, bx, by.
    /// The connectivity checker supplies these so a viewer can draw the
    /// specific missing join without re-running copper geometry in JavaScript.
    bridge: ?[4]f64 = null,
};

/// A part index as a `Parties` field (out-of-range → "unknown" rather than a
/// panic; the reporting path must never take the board down).
pub fn partyIndex(i: usize) i32 {
    return std.math.cast(i32, i) orelse -1;
}

// Drill-station rule defaults (min-annular 0.1, min-drill 0.2, hole-to-hole 0.25)
// live on `optimizer.DesignRules` (`placement.rules.design`); the router's default
// via sits on the annular floor, so only a thinner net-class via trips annular.

/// One violation, located at the offending gap's midpoint. `severity` defaults
/// to `err`; the assembly-hygiene checks set `warn`.
pub const Violation = struct {
    x: f64,
    y: f64,
    gap: f64, // actual edge-to-edge distance (mm); < clearance
    clearance: f64, // the rule that was broken (mm)
    kind: Kind,
    severity: Severity = .err,
    /// The nets / parts / pads that clashed — see `Parties`. Defaulted, so a
    /// producer that cannot name its parties still emits a valid violation.
    who: Parties = .{},
    /// The COPPER LAYER this violation is on, as a routable signal index. Set
    /// by the rules that judge one layer at a time — two tracks crossing, a
    /// track over a foreign land, two same-face SMD pads, a track's width, a
    /// stub or dangling fragment. NULL when the finding has no single layer:
    /// a courtyard clash, a drill/hole rule, a through-barrel pair, a board
    /// edge. Reporting only — no check reads it back, so it can never change a
    /// verdict — but it is folded into the violation's `id`, so two defects at
    /// one x/y on different layers no longer collide.
    layer: ?board_layers.SignalIndex = null,
};

/// A raw `router.Track.layer` / `PadBox.layer` as the violation field.
fn layerOf(layer: u8) ?board_layers.SignalIndex {
    return board_layers.SignalIndex.of(layer);
}

/// A pad as world bbox + copper outline (`poly`; empty ⇒ box is exact), net,
/// part index (same-part pads never paired), signal layer (0 top / 1 bottom;
/// `thru` reaches every layer), and drilled-hole `drill` / centre `hx,hy`.
const PadBox = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64 = &.{},
    net: i32,
    part: usize,
    /// The footprint pad number, carried so a violation can name the exact pad
    /// (`U3` pad `12`) instead of only the part it belongs to.
    num: []const u8 = "",
    layer: u8 = 0,
    thru: bool = false,
    npth: bool = false, // non-plated (mounting hole) — no ring, exempt from pad-annular
    drill_oval: bool = false, // `drill` is only the larger axis → pad-annular skips it
    drill: f64 = 0,
    hx: f64 = 0,
    hy: f64 = 0,
    // World half-vector to a slot's arc centres (`{0,0}` round); ends (hx,hy) ± (shx,shy).
    shx: f64 = 0,
    shy: f64 = 0,
};

/// A drilled hole (pad hole or via) as world centre + diameter + slot half-vector
/// (`{0,0}` round), so min-drill and hole-to-hole treat both alike. `net`/`part`/
/// `num` carry the owner's identity so a hole↔hole finding can name both drills.
const Hole = struct {
    x: f64,
    y: f64,
    drill: f64,
    shx: f64 = 0,
    shy: f64 = 0,
    net: i32 = -1,
    part: i32 = -1,
    num: []const u8 = "",
};

/// Floating-point slack on every threshold here: a rule is reported broken only
/// when the measured gap sits `eps` BELOW it, so copper resting exactly on a rule
/// is legal. Public because a pass that PRE-FILTERS its own candidates against
/// these checks (`via_fence`'s legality prefilter) has to use the identical
/// slack — a filter that is stricter by even a rounding step drops geometry this
/// checker would have passed.
pub const eps: f64 = 1e-6;

/// Effective copper clearance for a pair: MAX of the board default and each net's
/// `(net-class (clearance …))` override. Empty `rules.net` ⇒ every pair is `base`.
const ClearanceResolver = struct {
    base: f64,
    rules: optimizer.BoardRules,

    fn between(self: ClearanceResolver, a: i32, b: i32) f64 {
        return self.rules.clearanceBetween(a, b, self.base);
    }
};

/// Extra edge gap a controlled-impedance signal via's synthesized plane
/// antipad requires. This is a via-to-foreign-copper rule too: another via's
/// annulus may not occupy copper the plane must remove around the transition.
fn viaAntipadGap(rules: optimizer.BoardRules, via: router.Via) f64 {
    if (via.net < 0) return 0;
    const ni: usize = @intCast(via.net);
    if (ni >= rules.net.len) return 0;
    const nr = rules.net[ni];
    if (nr.rf.impedance.ohms <= 0 or nr.rf.impedance.diff_ohms > 0) return 0;
    const minimum = rules.clearanceForNet(via.net, rules.design.clearance);
    const result = via_antipad.solve(rules.physical.stack, nr.rf.impedance.ohms, via.dia, via.drill, minimum) orelse return 0;
    return (result.antipad_dia_mm - via.dia) / 2.0;
}

/// Largest copper min-dim (mm) a plated thru pad may have and still count as a
/// VIA-scale feature (via-in-pad / thermal / castellated) exempt from the
/// component-lead `pad_annular` check.
const via_pad_max_mm: f64 = 0.65;

/// Run the check (arena-allocated output). `clearance` is the board-default
/// copper rule (mm), edge to edge; per-net `(net-class …)` overrides come from
/// `placement.rules.net` and board rules from `placement.rules.design`. With no
/// classes and an absent form the output is byte-identical to before.
pub fn check(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    clearance: f64,
) std.mem.Allocator.Error![]Violation {
    return checkImpl(arena, placement, routed, clearance, &.{}, .{});
}

/// `check` with a per-fill memo for the ONE rule in it that pours copper.
///
/// Geometry DRC looks like a pure clearance sweep and mostly is, but the
/// power-width rule needs to know whether a declared rail's local branch is fed
/// by a plane, and `routedTrackRequiredWidths` answers that by rastering every
/// declared plane and pour of the board from scratch — 7.5 s of barracuda-base's
/// 8.2 s geometry pass, paid by every caller that never passes prepared copper.
/// A server-side caller measuring a SAVED board passes a memo here and pays it
/// once; the findings are identical either way, because a memoised fill is a
/// memoised fill.
///
/// Deliberately a separate entry point rather than a default: `drc.zig` is
/// compiled into the client's wasm DRC engine, which has no store to consult,
/// and the router's candidate loop mutates the copper the surfaces depend on
/// between every call and would only ever miss.
pub fn checkMemoised(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    clearance: f64,
    memo: ?pour.FillMemo,
) std.mem.Allocator.Error![]Violation {
    return checkImpl(arena, placement, routed, clearance, &.{}, .{ .fills = memo });
}

/// `check` with hand-authored copper zones credited as real same-net copper
/// for stub and via-use topology. Geometry/clearance checks remain identical.
pub fn checkWithZones(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    clearance: f64,
    zones: []const TopologyZone,
) std.mem.Allocator.Error![]Violation {
    return checkImpl(arena, placement, routed, clearance, zones, .{});
}

/// `checkWithZones` plus the exact prepared fills already owned by the
/// reporting DRC seam. Local-current power-width checks consume these fills so
/// a hand-authored copper zone is as authoritative as a declared plane.
pub fn checkWithPreparedCopper(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    clearance: f64,
    prepared: PreparedCopper,
) std.mem.Allocator.Error![]Violation {
    return checkImpl(arena, placement, routed, clearance, prepared.topology_zones, .{ .copper = prepared });
}

/// Exact fabricated copper rasters shared by reporting DRC's topology,
/// connectivity, and local-current width checks.
pub const PreparedCopper = struct {
    topology_zones: []const TopologyZone,
    plane_fills: []const pour.NetFills,
    zones: []const pour.UserZone,
    zone_fills: []const pour.Fill,
};

/// Run only the final-state copper topology rules. This is the authoritative
/// oracle used by post-router additive gates before copper is persisted.
pub fn checkTopology(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const TopologyZone,
) std.mem.Allocator.Error![]Violation {
    var out: Viol = .empty;
    const pads = try padBoxes(arena, placement);
    const tracks = try path_copper.tracks(arena, routed);
    try checkCopperTopology(arena, &out, placement, pads, .{ .routed = routed, .tracks = tracks, .zones = zones });
    return out.toOwnedSlice(arena);
}

/// Incremental "would adding this via create a fab error" oracle for additive
/// via passes (the perimeter stitch fence). The old gate re-ran the FULL check
/// once per candidate site — on a large routed board that is seconds of DRC per
/// site and made every `/pcb-layout` page load quadratic in fence length.
///
/// This builds the pairwise world ONCE (pad boxes + the same culling grids the
/// full check builds) and answers each candidate by running exactly the
/// error-severity rules a new via can trip: via↔pad, via↔track (the full
/// check's own functions, given a one-via slice), via↔via / via-spacing and
/// hole↔hole (the shared pair cores `viaPairViolation` / `holePairViolation`),
/// the via's own annular / min-drill (`checkDrillRules` with no pads), and
/// board-edge. Every remaining stage of the full check either cannot change
/// when one via is added (track/pad pairs, courtyards, widths) or emits only
/// warnings / `net_open` (topology, keepouts, bends, diff pairs, match groups),
/// which `errorCount` — the number the old gate compared — ignores by
/// definition. So `addsError` is exactly "would `errorCount` rise".
pub const ViaAdditionGate = struct {
    placement: optimizer.Placement,
    world: PairWorld,
    /// Every via already on the board plus each accepted candidate — the set a
    /// new candidate is paired against.
    others: std.ArrayList(router.Via) = .empty,
    /// Drilled features (pad holes + via holes), grown as candidates land.
    holes: std.ArrayList(Hole) = .empty,
    clr: ClearanceResolver,
    clr_max: f64,
    via_to_via: f64,

    /// The fixed copper the candidates are judged against: pad boxes and the
    /// full check's own culling grids over the (unchanging) tracks and pads.
    const PairWorld = struct {
        pads: []PadBox,
        pad_grid: Grid,
        track_grid: Grid,
        tracks: []const router.Track,
        identity: net_identity.Identity,
    };

    /// The grid inflation the full check would use for this copper. `probe` is
    /// a representative candidate via (net / geometry), folded in so a
    /// controlled-impedance stitch net's antipad halo can never out-reach the
    /// culling cells.
    fn gridInflation(placement: optimizer.Placement, vias: []const router.Via, clearance: f64, probe: router.Via) f64 {
        var clr_max = @max(clearance, placement.rules.design.via_to_via);
        for (placement.rules.net) |nr| clr_max = @max(clr_max, nr.clearance);
        for (vias) |via| clr_max = @max(clr_max, viaAntipadGap(placement.rules, via));
        return @max(clr_max, viaAntipadGap(placement.rules, probe));
    }

    /// Build the fixed world once; every `addsError` after this is via-scoped.
    pub fn build(
        arena: std.mem.Allocator,
        placement: optimizer.Placement,
        routed: router.RouteResult,
        clearance: f64,
        probe: router.Via,
    ) std.mem.Allocator.Error!ViaAdditionGate {
        const pads = try padBoxes(arena, placement);
        const clr_max = gridInflation(placement, routed.vias, clearance, probe);
        var gate = ViaAdditionGate{
            .placement = placement,
            .world = .{
                .pads = pads,
                .pad_grid = try Grid.build(arena, PadBox, pads, padBox, clr_max),
                .track_grid = try Grid.build(arena, router.Track, routed.tracks, trackBox, clr_max),
                .tracks = routed.tracks,
                .identity = try net_identity.Identity.init(arena, placement),
            },
            .clr = .{ .base = clearance, .rules = placement.rules },
            .clr_max = clr_max,
            .via_to_via = placement.rules.design.via_to_via,
        };
        try gate.others.appendSlice(arena, routed.vias);
        try gate.holes.appendSlice(arena, try allHoles(arena, pads, routed.vias));
        return gate;
    }

    /// True when adding `v` to the current copper would add at least one
    /// error-severity violation (`net_open` excluded, matching `errorCount`).
    pub fn addsError(self: *ViaAdditionGate, arena: std.mem.Allocator, v: router.Via) std.mem.Allocator.Error!bool {
        var out: Viol = .empty;
        const c = Ctx{ .arena = arena, .out = &out, .clr = self.clr, .clr_max = self.clr_max, .via_to_via = self.via_to_via, .identity = self.world.identity };
        const one = [_]router.Via{v};
        try checkViaPad(c, &one, self.world.pads, &self.world.pad_grid);
        try checkViaTrack(c, &one, self.world.tracks, &self.world.track_grid);
        for (self.others.items) |other| {
            if (viaPairViolation(c, v, other)) |viol| try out.append(arena, viol);
        }
        // Annular + min-drill for the candidate alone (no pads ⇒ no pad rules,
        // and its own single hole cannot pair with itself).
        try checkDrillRules(arena, &out, &.{}, &one, self.placement.rules.design);
        if (v.drill > 0) {
            const hole = Hole{ .x = v.x, .y = v.y, .drill = v.drill, .net = v.net };
            for (self.holes.items) |other| {
                if (holePairViolation(self.placement.rules.design, hole, other)) |viol| try out.append(arena, viol);
            }
        }
        try checkBoardEdge(arena, &out, self.placement, &.{}, &one, self.placement.rules.design.edgeClearance());
        for (out.items) |viol| {
            if (viol.severity == .err and viol.kind != .net_open) return true;
        }
        return false;
    }

    /// Commit an accepted candidate: later candidates are judged against it.
    pub fn accept(self: *ViaAdditionGate, arena: std.mem.Allocator, v: router.Via) std.mem.Allocator.Error!void {
        try self.others.append(arena, v);
        if (v.drill > 0) try self.holes.append(arena, .{ .x = v.x, .y = v.y, .drill = v.drill, .net = v.net });
    }
};

/// Reusable DRC-grade obstacle view for asking whether one same-layer track
/// could be added to finished copper without creating a fabrication error.
/// The route-shape benchmark uses it to distinguish necessary bends from
/// bends whose two arms can be replaced by a clear chord.
pub const TrackAdditionGate = struct {
    placement: optimizer.Placement,
    pads: []const PadBox,
    tracks: []const router.Track,
    vias: []const router.Via,
    clr: ClearanceResolver,
    identity: net_identity.Identity,

    /// Build the immutable pad/copper world once for all bend probes.
    pub fn build(
        arena: std.mem.Allocator,
        placement: optimizer.Placement,
        routed: router.RouteResult,
        clearance: f64,
    ) std.mem.Allocator.Error!TrackAdditionGate {
        return .{
            .placement = placement,
            .pads = try padBoxes(arena, placement),
            .tracks = routed.tracks,
            .vias = routed.vias,
            .clr = .{ .base = clearance, .rules = placement.rules },
            .identity = try net_identity.Identity.init(arena, placement),
        };
    }

    /// True when `candidate` clears foreign pads, tracks, vias, and the board
    /// edge under the same pairwise spacing rules as the full DRC.
    pub fn clear(self: TrackAdditionGate, candidate: router.Track) bool {
        for (self.pads) |pad| {
            if (self.identity.same(candidate.net, pad.net)) continue;
            if (!pad.thru and pad.layer != candidate.layer) continue;
            const required = self.clr.between(candidate.net, pad.net);
            const window = candidate.width / 2 + required;
            if (segShapeDist(candidate, pad, window) - candidate.width / 2 < required - eps) return false;
        }
        for (self.tracks) |track| {
            if (self.identity.same(candidate.net, track.net) or candidate.layer != track.layer) continue;
            const required = self.clr.between(candidate.net, track.net);
            const gap = segSegDist(candidate.x1, candidate.y1, candidate.x2, candidate.y2, track.x1, track.y1, track.x2, track.y2) -
                candidate.width / 2 - track.width / 2;
            if (gap < required - eps) return false;
        }
        for (self.vias) |via| {
            if (self.identity.same(candidate.net, via.net)) continue;
            const required = self.clr.between(candidate.net, via.net);
            const gap = segPointDist(candidate.x1, candidate.y1, candidate.x2, candidate.y2, via.x, via.y) -
                candidate.width / 2 - via.dia / 2;
            if (gap < required - eps) return false;
        }
        return trackClearsBoardEdge(self.placement, candidate);
    }
};

fn trackClearsBoardEdge(placement: optimizer.Placement, track: router.Track) bool {
    const board = placement.board_rect orelse return true;
    const half = track.width / 2;
    const endpoints = [_][2]f64{ .{ track.x1, track.y1 }, .{ track.x2, track.y2 } };
    var worst = std.math.inf(f64);
    for (endpoints) |point| worst = @min(worst, boardInset(board, placement.board_poly, point[0], point[1]));
    if (placement.board_poly) |poly| {
        if (worst > -(half + staging_exempt_mm) and outline.segCrossesEdge(poly, track.x1, track.y1, track.x2, track.y2) != null) worst = 0;
    }
    if (worst < -(half + staging_exempt_mm)) return true;
    return worst - half >= placement.rules.design.edgeClearance() - eps;
}

/// How the power-width rule inside `checkImpl` gets at the board's poured
/// copper: either the caller already holds the exact fills (the reporting seam,
/// which poured them for topology and connectivity), or it holds a memo the
/// rule can pour THROUGH, or neither and it pours from scratch. Exactly one of
/// the two is ever set; both null is the historical behaviour.
const PowerCopper = struct {
    copper: ?PreparedCopper = null,
    fills: ?pour.FillMemo = null,
};

fn checkImpl(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    clearance: f64,
    topology_zones: []const TopologyZone,
    power: PowerCopper,
) std.mem.Allocator.Error![]Violation {
    var out: std.ArrayList(Violation) = .empty;
    const pads = try padBoxes(arena, placement);
    const vias = routed.vias;
    // Swept paths are the physical width authority. Saved editor handles stay
    // compact; every capsule-based rule sees private profile chords instead.
    const tracks = try path_copper.tracks(arena, routed);
    var ordinary_tracks: usize = 0;
    for (routed.tracks) |track| {
        if (!path_copper.ownsTrack(routed.rf_port_outcomes, track)) ordinary_tracks += 1;
    }
    const rules = placement.rules.design;
    const clr = ClearanceResolver{ .base = clearance, .rules = placement.rules };
    // Widest clearance any pair can demand — the grid inflation, so no violating
    // pair is dropped.
    var clr_max = @max(clearance, rules.via_to_via);
    for (placement.rules.net) |nr| clr_max = @max(clr_max, nr.clearance);
    for (vias) |via| clr_max = @max(clr_max, viaAntipadGap(placement.rules, via));

    // Grids built once and shared. The pad grid is also queried by silk, so its
    // cell is sized to cover the mask-opening margin used there.
    var pad_grid = try Grid.build(arena, PadBox, pads, padBox, @max(clr_max, rules.mask.margin));
    var via_grid = try Grid.build(arena, router.Via, vias, viaBox, clr_max);
    var track_grid = try Grid.build(arena, router.Track, tracks, trackBox, clr_max);

    const identity = try net_identity.Identity.init(arena, placement);
    const c = Ctx{ .arena = arena, .out = &out, .clr = clr, .clr_max = clr_max, .via_to_via = rules.via_to_via, .identity = identity };
    try checkViaPad(c, vias, pads, &pad_grid);
    try checkViaVia(c, vias, &via_grid);
    try checkViaTrack(c, vias, tracks, &track_grid);
    try checkTrackTrack(c, tracks, &track_grid);
    // A variable-width path fabricates as butt-ended swept regions, not the
    // round-ended max-width capsules used by the remaining centreline rules.
    // Check ordinary tracks through the legacy capsule seam and paths against
    // their exact polygons. In particular, a wide/short launch pad must not
    // grow a synthetic radius behind its centre and crowd the adjacent land.
    try checkTrackPad(c, tracks[0..ordinary_tracks], pads, &pad_grid);
    try checkRfPathPad(c, routed, pads);
    // Drill / edge / courtyard / silk / width rules live in helpers.
    try checkDrillRules(arena, &out, pads, vias, rules);
    try checkBoardEdge(arena, &out, placement, tracks, vias, rules.edgeClearance());
    try checkPadEdge(arena, &out, placement, pads, rules.edgeClearance());
    try checkComponentEdge(arena, &out, placement, rules.edge.component);
    try checkCourtyards(arena, &out, placement);
    try checkSilkOverPad(arena, &out, placement, pads, &pad_grid, rules.mask.margin);
    var current_routed = routed;
    current_routed.tracks = tracks;
    const local_power_widths = if (power.copper) |prepared|
        try power_integrity.routedTrackRequiredWidthsPrepared(
            arena,
            placement,
            current_routed,
            prepared.plane_fills,
            prepared.zones,
            prepared.zone_fills,
        )
    else
        try power_integrity.routedTrackRequiredWidthsMemo(arena, placement, current_routed, power.fills);
    try checkTrackWidth(arena, &out, .{
        .placement = placement,
        .routed = routed,
        .tracks = tracks,
        .min_width = rules.min_width,
        .local_power_widths = local_power_widths,
    });
    // Topology still needs the private chords as physical support (a curved or
    // flared path may touch something its compact handle does not), but finding
    // identity must remain in the persisted track domain.  The topology checker
    // therefore keeps private chords in its graph while refusing to emit them
    // as independently editable/removable route sections.
    try checkCopperTopology(arena, &out, placement, pads, .{ .routed = routed, .tracks = tracks, .zones = topology_zones });
    // Own-land transit is a physical-copper rule, so retain the lowered width
    // profile.  Its checker coalesces chords only when they belong to the same
    // swept path and land, instead of presenting tessellation density as
    // warning severity or hiding distinct editable sections.
    try checkLandTransit(c, placement, routed, tracks, pads, &pad_grid);
    try checkGroundPadVias(c, placement, pads, vias, &via_grid, rules.pour.ground_via_max);
    try checkPadPad(c, pads, &pad_grid);
    try drc_diffpair.check(arena, &out, placement, .{ .tracks = tracks, .vias = vias }, clearance);
    // `(match-group …)` length matching — the same shape of tolerance judgement
    // across N nets. `placement.match_groups` is empty for every design that
    // declares none, so this costs nothing and adds nothing there.
    try drc_match.check(arena, &out, placement, .{ .tracks = tracks, .vias = vias });
    // RF same-layer keepout halos. Its own spatial reject is a per-keepout-net
    // bbox, NOT the shared grids above: a halo is typically wider than
    // `clr_max`, and inflating those grids to cover it would coarsen every
    // clearance query on the board for a rule only a handful of RF nets ask
    // for. `keepout.anyDeclared` makes it free for every other design.
    try drc_keepout.check(arena, &out, placement, tracks, vias, try keepoutPads(arena, placement, pads));
    try drc_perimeter_keepout.check(arena, &out, placement, tracks, vias);
    // RF bend discipline: preserve the router's richer findings (including
    // achieved radius on an under-floor arc), then audit the ACTUAL copper as
    // well. Saved layouts persist arcs as track chords and do not persist the
    // RouteResult metadata; post-route cleanup can also introduce a corner
    // after inline smoothing. Without this second source, either path could
    // leave a hard RF corner visible in the editor with no sharp_bend marker.
    for (routed.sharp_bends) |sb| {
        try appendSharpViolation(arena, &out, sb);
    }
    const measured = try bend_smooth.detect(arena, .{
        .placement = placement,
        .params = placement.rules.design.routeParams(),
        .tracks = tracks,
        .vias = vias,
    });
    for (measured) |sb| {
        // A port-frame route is emitted as short chords, but its recorded
        // solver result proves the underlying Euler chain is G2 continuous,
        // tangent-correct, and above the authored radius floor. Re-running a
        // vertex detector on that tessellation would flag the intentional
        // chord joins as hard bends. Saved/imported copper carries no outcome
        // and still receives the conservative geometric audit below.
        if (successfulPortFrameBend(routed, sb)) continue;
        if (sharpBendRecorded(routed.sharp_bends, sb)) continue;
        try appendSharpViolation(arena, &out, sb);
    }
    return out.toOwnedSlice(arena);
}

/// True only for an INTERNAL tessellation vertex of a successful swept path.
/// Path endpoints remain auditable because an adjoining stored section may
/// make a real hard corner there; unrelated corners on the same net must never
/// inherit another path's proof of G2 continuity.
fn successfulPortFrameBend(routed: router.RouteResult, bend: router.SharpBend) bool {
    for (routed.rf_port_outcomes) |outcome| {
        if (outcome.net != bend.net or outcome.physical.layer != bend.layer or !outcome.success) continue;
        if (outcome.physical.gate_removed) continue;
        const samples = outcome.physical.samples;
        if (samples.len < 3) continue;
        for (samples[1 .. samples.len - 1]) |sample| {
            if (std.math.hypot(sample.at[0] - bend.x, sample.at[1] - bend.y) <= 1e-4) return true;
        }
    }
    return false;
}

fn topologyTerminals(arena: std.mem.Allocator, pads: []const PadBox, identity: net_identity.Identity) std.mem.Allocator.Error![]const copper_topology.Terminal {
    const out = try arena.alloc(copper_topology.Terminal, pads.len);
    for (pads, out) |pad, *terminal| terminal.* = .{
        .shape = .{ .x0 = pad.x0, .y0 = pad.y0, .x1 = pad.x1, .y1 = pad.y1, .poly = pad.poly },
        .net = identity.canonical(pad.net),
        .layer = pad.layer,
        .thru = pad.thru,
    };
    return out;
}

fn topologyTracks(arena: std.mem.Allocator, tracks: []const router.Track, identity: net_identity.Identity) std.mem.Allocator.Error![]const copper_topology.Track {
    const out = try arena.alloc(copper_topology.Track, tracks.len);
    for (tracks, out) |track, *topology| topology.* = .{
        .a = .{ track.x1, track.y1 },
        .b = .{ track.x2, track.y2 },
        .layer = track.layer,
        .width = track.width,
        .net = identity.canonical(track.net),
    };
    return out;
}

/// Map the physical topology view back to persisted editor sections.  The
/// lowering contract emits every non-path stored section first, in saved order,
/// then private swept-path chords.  Null therefore means "real copper support,
/// but not an independently editable or reportable track".
fn topologyTrackIdentities(
    arena: std.mem.Allocator,
    routed: router.RouteResult,
    physical_tracks: []const router.Track,
) std.mem.Allocator.Error![]const ?usize {
    const identities = try arena.alloc(?usize, physical_tracks.len);
    @memset(identities, null);
    var physical_i: usize = 0;
    for (routed.tracks, 0..) |track, stored_i| {
        if (path_copper.ownsTrack(routed.rf_port_outcomes, track)) continue;
        if (physical_i == identities.len) break;
        identities[physical_i] = stored_i;
        physical_i += 1;
    }
    return identities;
}

fn topologyVias(arena: std.mem.Allocator, vias: []const router.Via, identity: net_identity.Identity) std.mem.Allocator.Error![]const copper_topology.Via {
    const out = try arena.alloc(copper_topology.Via, vias.len);
    for (vias, out) |via, *topology| topology.* = .{ .at = .{ via.x, via.y }, .dia = via.dia, .net = identity.canonical(via.net) };
    return out;
}

/// Copper that is electrically legal but topologically useless: loose trace
/// leaves are errors; vias reaching at most one copper layer are warnings.
const TopologyRoute = struct {
    routed: router.RouteResult,
    tracks: []const router.Track,
    zones: []const TopologyZone,
};

fn checkCopperTopology(
    arena: std.mem.Allocator,
    out: *Viol,
    placement: optimizer.Placement,
    pads: []const PadBox,
    route: TopologyRoute,
) std.mem.Allocator.Error!void {
    const routed = route.routed;
    const tracks = route.tracks;
    const zones = route.zones;
    const vias = routed.vias;
    const identity = try net_identity.Identity.init(arena, placement);
    const track_identities = try topologyTrackIdentities(arena, routed, tracks);
    const terminals = try topologyTerminals(arena, pads, identity);
    const topology_tracks = try topologyTracks(arena, tracks, identity);
    const topology_vias = try topologyVias(arena, vias, identity);
    const implicit = try copper_topology.implicitJoins(arena, topology_tracks);
    for (implicit) |join| {
        const stored_i = track_identities[join.a] orelse track_identities[join.b] orelse continue;
        const track = routed.tracks[stored_i];
        try out.append(arena, .{
            .x = join.at[0],
            .y = join.at[1],
            .gap = 0,
            .clearance = 0,
            .kind = .implicit_junction,
            .severity = defaultSeverity(.implicit_junction),
            .who = .{ .net_a = track.net, .track_a = partyIndex(stored_i) },
            .layer = layerOf(track.layer),
        });
    }
    // Every connectivity source the redundancy walk reads — live barrels,
    // poured trace ends, and which fill each of them is in — comes from the
    // ONE assembly the router's finish also calls (`copper_support.assemble`).
    // Only a LIVE barrel is a connectivity destination: a pad's escape to a
    // real plane via is that via's copper, while a stub to a via with no
    // second layer is junk together with it.
    const support = try copper_support.assemble(arena, placement, terminals, topology_tracks, topology_vias, zones);
    const via_use_counts = support.via_uses;
    const endpoint_pours = support.branch.pour_layers;
    const endpoint_components = support.branch.pour_components;
    const via_candidates = try arena.alloc(bool, vias.len);
    const via_ground_poured = try arena.alloc(bool, vias.len);
    const via_components = try arena.alloc([]const u64, vias.len);
    for (vias, 0..) |via, via_i| {
        const canonical_net = identity.canonical(via.net);
        const valid_net = canonical_net >= 0 and @as(usize, @intCast(canonical_net)) < placement.nets.len;
        const net_name = if (valid_net) placement.nets[@intCast(canonical_net)].name else "";
        const ground = valid_net and optimizer.isGroundName(router.shortName(net_name));
        const poured = if (ground) plane_stitch.netPourLayers(placement, net_name) else .{ false, false };
        via_ground_poured[via_i] = poured[0] or poured[1];
        via_components[via_i] = try copper_support.componentsAt(arena, placement, canonical_net, zones, .{ via.x, via.y }, null);
        const unobserved_fill = (support.via_poured[via_i] != 0 or support.via_planes[via_i] != 0) and
            via_components[via_i].len == 0;
        via_candidates[via_i] = valid_net and !ground and !unobserved_fill;
    }
    const terminal_components = try arena.alloc([]const u64, terminals.len);
    for (terminals, terminal_components) |terminal, *components| {
        const at = pad_shape.copperAnchor(terminal.shape);
        components.* = try copper_support.componentsAt(
            arena,
            placement,
            terminal.net,
            zones,
            at,
            if (terminal.thru) null else terminal.layer,
        );
    }
    const via_redundancy = try copper_topology.analyzeViaRedundancy(
        arena,
        terminals,
        topology_tracks,
        topology_vias,
        .{
            .candidates = via_candidates,
            .terminal_components = terminal_components,
            .track_components = endpoint_components,
            .via_components = via_components,
        },
    );
    const redundancy = try copper_topology.analyzeRedundancy(arena, terminals, topology_tracks, support.branch);
    // One batch call so the endpoint sweep buckets the board's copper once
    // instead of re-walking every land, trace, and barrel per section.
    const loose_ends = try copper_topology.looseEnds(arena, terminals, topology_tracks, topology_vias, endpoint_pours);
    const redundant = redundancy.individual;
    const removal = redundancy.removal;
    for (tracks, 0..) |track, track_i| {
        // A successful swept path is one semantic copper object.  Its private
        // chords remain in the graph so the exact flared/curved copper supports
        // adjoining pads, tracks, vias, and pours, but none is independently
        // reportable or removable merely because neighbouring samples overlap.
        const stored_i = track_identities[track_i] orelse continue;
        const loose = loose_ends[track_i];
        // The user's unit is the stored route section: one warning for every
        // section whose deletion preserves all support connectivity.
        if (redundant[track_i]) {
            try out.append(arena, .{
                .x = track.x1,
                .y = track.y1,
                .gap = 0,
                .clearance = 0,
                .kind = .dangling_copper,
                .severity = defaultSeverity(.dangling_copper),
                .who = .{
                    .net_a = track.net,
                    // Only jointly safe plan members are offered to automatic
                    // cleanup; every independently redundant section is still
                    // reported to the user.
                    .track_a = if (removal[track_i]) partyIndex(stored_i) else -1,
                },
                .layer = layerOf(track.layer),
            });
            continue;
        }
        const loose_at = loose orelse continue;
        try out.append(arena, .{
            .x = loose_at[0],
            .y = loose_at[1],
            .gap = 0,
            .clearance = 0,
            .kind = .copper_stub,
            .severity = defaultSeverity(.copper_stub),
            .who = .{ .net_a = track.net, .track_a = partyIndex(stored_i) },
            .layer = layerOf(track.layer),
        });
    }
    for (vias, 0..) |via, via_i| {
        const use_count = via_use_counts[via_i];
        // A same-net outer ground pour makes a GND barrel intentional stitching
        // copper rather than a disposable layer transition. Fill-blind callers
        // (the WASM checker and route gates) cannot prove its exact contour, so
        // use the authored stackup declaration; exact filled DRC still judges
        // every other topology rule against the computed pour components.
        if (use_count < 2 and !via_ground_poured[via_i]) {
            try out.append(arena, .{
                .x = via.x,
                .y = via.y,
                .gap = @floatFromInt(use_count),
                .clearance = 2,
                .kind = .single_layer_via,
                .severity = defaultSeverity(.single_layer_via),
                // Only a connectivity-proven member of the jointly safe plan
                // carries an index the automatic cleanup is allowed to consume.
                .who = .{ .net_a = via.net, .track_a = if (via_redundancy.removal[via_i]) partyIndex(via_i) else -1 },
            });
        } else if (via_redundancy.removal[via_i]) {
            try out.append(arena, .{
                .x = via.x,
                .y = via.y,
                .gap = 0,
                .clearance = 0,
                .kind = .redundant_via,
                .severity = defaultSeverity(.redundant_via),
                .who = .{ .net_a = via.net, .track_a = partyIndex(via_i) },
            });
        }
    }
}

fn appendSharpViolation(arena: std.mem.Allocator, out: *Viol, sb: router.SharpBend) std.mem.Allocator.Error!void {
    try out.append(arena, .{
        .x = sb.x,
        .y = sb.y,
        .gap = sb.radius,
        .clearance = sb.required,
        .kind = .sharp_bend,
        .severity = defaultSeverity(.sharp_bend),
        .who = .{ .net_a = sb.net },
        .layer = layerOf(sb.layer),
    });
}

/// True when the router already reported this same physical corner. The
/// copper audit deliberately supplements, rather than replaces, its metadata:
/// an under-floor arc's router marker carries a useful non-zero radius while
/// the chord audit can only identify genuinely hard vertices.
fn sharpBendRecorded(recorded: []const router.SharpBend, measured: router.SharpBend) bool {
    for (recorded) |sb| {
        if (sb.net != measured.net or sb.layer != measured.layer) continue;
        if (std.math.hypot(sb.x - measured.x, sb.y - measured.y) <= 1e-4) return true;
    }
    return false;
}

/// Project the already-joined pad list into the exact pad geometry and escape
/// terminals `drc_keepout` needs. Empty when no net declares a keepout, so a
/// board without one pays no allocation.
fn keepoutPads(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    pads: []const PadBox,
) std.mem.Allocator.Error![]const keepout.PadPt {
    if (!keepout.anyDeclared(placement)) return &.{};
    const out = try arena.alloc(keepout.PadPt, pads.len);
    for (pads, out) |p, *o| o.* = .{
        .net = p.net,
        .x = (p.x0 + p.x1) / 2,
        .y = (p.y0 + p.y1) / 2,
        .guard = if (!p.npth and p.net >= 0) .{
            .bounds = .{ p.x0, p.y0, p.x1, p.y1 },
            .poly = p.poly,
            .layer = p.layer,
            .thru = p.thru,
        } else null,
    };
    return out;
}

// ── Pairwise copper-clearance checks (grid-culled) ───────────────────────────
// Each queries its inner grid for candidates near the outer feature, then runs
// the SAME exact test the pre-cull nested loop ran, appending in the same order.

/// The `Parties` of a copper-vs-copper clash: both nets, no pad identity.
fn netParties(a: i32, b: i32) Parties {
    return .{ .net_a = a, .net_b = b };
}

/// The `Parties` of a copper-vs-pad clash: `net` on the A side, the pad's net,
/// part, and pad number on the B side.
fn padParties(net: i32, p: PadBox) Parties {
    return .{ .net_a = net, .net_b = p.net, .part_b = partyIndex(p.part), .pad_b = p.num };
}

/// The `Parties` of a pad-vs-pad clearance clash.
fn padPairParties(a: PadBox, b: PadBox) Parties {
    return .{
        .net_a = a.net,
        .part_a = partyIndex(a.part),
        .pad_a = a.num,
        .net_b = b.net,
        .part_b = partyIndex(b.part),
        .pad_b = b.num,
    };
}

/// The `Parties` of a single-pad finding (pad annular ring, min drill).
fn onePadParties(p: PadBox) Parties {
    return .{ .net_a = p.net, .part_a = partyIndex(p.part), .pad_a = p.num };
}

/// Shared inputs threaded through the copper checks.
const Ctx = struct {
    arena: std.mem.Allocator,
    out: *Viol,
    clr: ClearanceResolver,
    clr_max: f64,
    /// The board's `(design-rules (via-to-via MM))`, or 0 for "resolved
    /// clearance" (see `viaSpacingRule`).
    via_to_via: f64 = 0,
    identity: net_identity.Identity = .{},

    fn sameNet(self: Ctx, a: i32, b: i32) bool {
        return self.identity.same(a, b);
    }
};

/// The spacing rule two vias of the SAME net are held to. An authored
/// `(design-rules (via-to-via MM))` wins; otherwise the pair's resolved copper
/// clearance stands in, which is the number a foreign pair would owe each
/// other. That default is deliberate: a redundant via planted on top of an
/// existing one sits micrometres away and flags, while a stitch fence's ~1 mm
/// pitch — real, intentional, redundant-by-design copper — is nowhere near it.
fn viaSpacingRule(c: Ctx, net: i32) f64 {
    return if (c.via_to_via > 0) c.via_to_via else c.clr.between(net, net);
}

/// via ↔ pad: a via crowding a foreign pad's copper clearance.
fn checkViaPad(c: Ctx, vias: []const router.Via, pads: []const PadBox, pad_grid: *Grid) Err {
    for (vias) |v| {
        const vr = v.dia / 2;
        for (try pad_grid.near(c.arena, viaBox(v), c.clr_max)) |j| {
            const p = pads[j];
            if (c.sameNet(v.net, p.net)) continue;
            const eff = c.clr.between(v.net, p.net);
            const gap = pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, v.x, v.y, vr + eff) - vr;
            if (gap < eff - eps) {
                const face: ?board_layers.SignalIndex = if (p.thru) null else layerOf(p.layer);
                try c.out.append(c.arena, .{ .x = v.x, .y = v.y, .gap = gap, .clearance = eff, .kind = .via_pad, .who = padParties(v.net, p), .layer = face });
            }
        }
    }
}

/// One unordered via pair's clearance verdict — the single rule body shared by
/// the full sweep (`checkViaVia`) and the additive gate (`ViaAdditionGate`),
/// so the two can never disagree.
fn viaPairViolation(c: Ctx, a: router.Via, b: router.Via) ?Violation {
    const same = c.sameNet(a.net, b.net);
    const eff = if (same) viaSpacingRule(c, a.net) else @max(
        c.clr.between(a.net, b.net),
        @max(viaAntipadGap(c.clr.rules, a), viaAntipadGap(c.clr.rules, b)),
    );
    const gap = std.math.hypot(a.x - b.x, a.y - b.y) - a.dia / 2 - b.dia / 2;
    if (gap >= eff - eps) return null;
    return .{
        .x = (a.x + b.x) / 2,
        .y = (a.y + b.y) / 2,
        .gap = gap,
        .clearance = eff,
        .kind = if (same) .via_spacing else .via_via,
        .who = netParties(a.net, b.net),
    };
}

/// via ↔ via. A FOREIGN pair owes the resolved copper clearance (`via_via`); a
/// SAME-net pair owes the via-spacing rule instead (`via_spacing`) — see
/// `viaSpacingRule` for why the two are separate kinds and separate numbers.
fn checkViaVia(c: Ctx, vias: []const router.Via, via_grid: *Grid) Err {
    for (vias, 0..) |a, i| {
        for (try via_grid.near(c.arena, viaBox(a), c.clr_max)) |ju| {
            if (ju <= i) continue; // emit each unordered pair once, at the lower index
            if (viaPairViolation(c, a, vias[ju])) |v| try c.out.append(c.arena, v);
        }
    }
}

/// via ↔ track.
fn checkViaTrack(c: Ctx, vias: []const router.Via, tracks: []const router.Track, track_grid: *Grid) Err {
    for (vias) |v| {
        const vr = v.dia / 2;
        for (try track_grid.near(c.arena, viaBox(v), c.clr_max)) |j| {
            const t = tracks[j];
            if (c.sameNet(v.net, t.net)) continue;
            const eff = c.clr.between(v.net, t.net);
            const gap = segPointDist(t.x1, t.y1, t.x2, t.y2, v.x, v.y) - vr - t.width / 2;
            if (gap < eff - eps) {
                try c.out.append(c.arena, .{ .x = v.x, .y = v.y, .gap = gap, .clearance = eff, .kind = .via_track, .who = netParties(v.net, t.net), .layer = layerOf(t.layer) });
            }
        }
    }
}

/// track ↔ track (same layer, different nets): polices off-maze copper (stubs,
/// hand-drawn, stamped copper).
fn checkTrackTrack(c: Ctx, tracks: []const router.Track, track_grid: *Grid) Err {
    for (tracks, 0..) |a, i| {
        for (try track_grid.near(c.arena, trackBox(a), c.clr_max)) |ju| {
            if (ju <= i) continue;
            const b = tracks[ju];
            if (a.layer != b.layer or c.sameNet(a.net, b.net)) continue;
            const eff = c.clr.between(a.net, b.net);
            const gap = segSegDist(a.x1, a.y1, a.x2, a.y2, b.x1, b.y1, b.x2, b.y2) - a.width / 2 - b.width / 2;
            if (gap < eff - eps) {
                const mx = (a.x1 + a.x2 + b.x1 + b.x2) / 4;
                const my = (a.y1 + a.y2 + b.y1 + b.y2) / 4;
                try c.out.append(c.arena, .{ .x = mx, .y = my, .gap = gap, .clearance = eff, .kind = .track_track, .who = netParties(a.net, b.net), .layer = layerOf(a.layer) });
            }
        }
    }
}

/// track ↔ pad (layer-aware): catches a breakout stub / hand-drawn track drawn
/// across a foreign pad. Sampled along the track against the pad's real outline.
/// SAME-net copper lapping a land it does not connect to (`land_transit.zig`).
///
/// The twin of `checkTrackPad` on the other side of the net test: that rule
/// governs how close a track may come to a FOREIGN land, this one what a track
/// may do on its OWN. Between them every pad's neighbourhood is covered, which
/// it was not before — a same-net track could ride a QFN land's flank down the
/// 0.2 mm corridor to the next pin and no rule had an opinion.
///
/// Only SMD lands are judged: a through-hole barrel is the connection on every
/// layer, so copper across its annulus is not a lap (the same call `pad_entry`
/// and `pad_escape` make). Large lands are out of scope too — see
/// `land_transit.paddle_min_half_mm`.
fn checkLandTransit(
    c: Ctx,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    tracks: []const router.Track,
    pads: []const PadBox,
    pad_grid: *Grid,
) Err {
    const PathLandFinding = struct {
        path: usize,
        pad: usize,
        violation: Violation,
    };
    var path_findings: std.ArrayList(PathLandFinding) = .empty;
    for (tracks) |t| {
        // Ground lands intentionally collect broad surface bonds, stitching
        // fans, and pour tie-ins. Treating those shapes like a signal escape
        // turns useful return copper into own-land noise. Use the shared
        // ground-name predicate so split grounds (AGND/DGND/PGND/VSS, etc.)
        // receive the same exemption as a literal GND net.
        if (t.net >= 0 and @as(usize, @intCast(t.net)) < placement.nets.len and
            optimizer.isGroundName(router.shortName(placement.nets[@intCast(t.net)].name))) continue;
        var path_owner: ?usize = null;
        for (routed.rf_port_outcomes, 0..) |_, path_i| {
            if (!path_copper.ownsTrack(routed.rf_port_outcomes[path_i .. path_i + 1], t)) continue;
            path_owner = path_i;
            break;
        }
        const half = t.width / 2;
        for (try pad_grid.near(c.arena, trackBox(t), c.clr_max)) |j| {
            const p = pads[j];
            if (!c.sameNet(t.net, p.net) or p.thru or p.layer != t.layer) continue;
            const land = land_transit.Land{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .poly = p.poly };
            const f = land_transit.segmentOffence(land, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, half) orelse continue;
            const finding = Violation{
                .x = f.at[0],
                .y = f.at[1],
                .gap = f.overlap_mm,
                .clearance = f.miss_mm,
                .kind = .land_transit,
                .severity = defaultSeverity(.land_transit),
                .who = padParties(t.net, p),
                .layer = layerOf(t.layer),
            };
            const path_i = path_owner orelse {
                try c.out.append(c.arena, finding);
                continue;
            };
            var grouped = false;
            for (path_findings.items) |*prior| {
                if (prior.path != path_i or prior.pad != j) continue;
                if (finding.clearance > prior.violation.clearance + eps or
                    (@abs(finding.clearance - prior.violation.clearance) <= eps and finding.gap > prior.violation.gap))
                {
                    prior.violation = finding;
                }
                grouped = true;
                break;
            }
            if (!grouped) try path_findings.append(c.arena, .{ .path = path_i, .pad = j, .violation = finding });
        }
    }
    for (path_findings.items) |finding| try c.out.append(c.arena, finding.violation);
}

/// Enforce the optional maximum ground-return drop distance. The pad and via
/// must share the exact flattened net index: an AGND via cannot satisfy a GND
/// pad merely because both names are ground-like. Through-hole pads already
/// reach every copper layer and therefore need no separate barrel.
///
/// Two passes, and the split is what keeps this exact while it stops scanning
/// every via for every ground pad. The grid answers the only question the
/// VERDICT needs — "is any same-net via inside the rule?" — because a via at or
/// under `max_distance` from the pad centre necessarily sits in a queried cell.
/// The reported `gap` is the true nearest distance, so a pad that fails the
/// first pass (rare: it is a violation) still gets the exhaustive scan, which
/// also means a grid that somehow missed a close via is caught here anyway.
fn checkGroundPadVias(
    c: Ctx,
    placement: optimizer.Placement,
    pads: []const PadBox,
    vias: []const router.Via,
    via_grid: *Grid,
    max_distance: f64,
) Err {
    if (!(max_distance > 0)) return;
    for (pads) |pad| {
        if (pad.thru or pad.net < 0) continue;
        if (pad.part < placement.pin_roles.len) {
            const class = placement.pin_roles[pad.part].classOf(pad.num);
            if (class == .optional_nc or class == .strap) continue;
        }
        const net_i: usize = @intCast(pad.net);
        if (net_i >= placement.nets.len) continue;
        const name = placement.nets[net_i].name;
        if (!optimizer.isGroundName(router.shortName(name)) or !router.netHasPlane(placement, name)) continue;
        var served = false;
        for (try via_grid.near(c.arena, pointBox(pad.hx, pad.hy), max_distance + eps)) |j| {
            const via = vias[j];
            if (via.net != pad.net) continue;
            if (std.math.hypot(via.x - pad.hx, via.y - pad.hy) <= max_distance + eps) {
                served = true;
                break;
            }
        }
        if (served) continue;
        var nearest = std.math.inf(f64);
        for (vias) |via| {
            if (via.net != pad.net) continue;
            nearest = @min(nearest, std.math.hypot(via.x - pad.hx, via.y - pad.hy));
        }
        if (nearest <= max_distance + eps) continue;
        try c.out.append(c.arena, .{
            .x = pad.hx,
            .y = pad.hy,
            .gap = if (std.math.isFinite(nearest)) nearest else max_distance + 1,
            .clearance = max_distance,
            .kind = .ground_via_distance,
            .severity = defaultSeverity(.ground_via_distance),
            .who = onePadParties(pad),
            .layer = layerOf(pad.layer),
        });
    }
}

fn checkTrackPad(c: Ctx, tracks: []const router.Track, pads: []const PadBox, pad_grid: *Grid) Err {
    for (tracks) |t| {
        for (try pad_grid.near(c.arena, trackBox(t), c.clr_max)) |j| {
            const p = pads[j];
            if (c.sameNet(t.net, p.net)) continue;
            if (!p.thru and p.layer != t.layer) continue;
            const eff = c.clr.between(t.net, p.net);
            const need = t.width / 2 + eff;
            if (@min(t.x1, t.x2) > p.x1 + need or @max(t.x1, t.x2) < p.x0 - need or
                @min(t.y1, t.y2) > p.y1 + need or @max(t.y1, t.y2) < p.y0 - need) continue;
            const gap = segShapeDist(t, p, need) - t.width / 2;
            if (gap < eff - eps) {
                const mx = std.math.clamp((p.x0 + p.x1) / 2, @min(t.x1, t.x2), @max(t.x1, t.x2));
                const my = std.math.clamp((p.y0 + p.y1) / 2, @min(t.y1, t.y2), @max(t.y1, t.y2));
                try c.out.append(c.arena, .{ .x = mx, .y = my, .gap = gap, .clearance = eff, .kind = .track_pad, .who = padParties(t.net, p), .layer = layerOf(t.layer) });
            }
        }
    }
}

fn regionShape(poly: []const [2]f64) pad_shape.Shape {
    var x0 = std.math.inf(f64);
    var y0 = std.math.inf(f64);
    var x1 = -std.math.inf(f64);
    var y1 = -std.math.inf(f64);
    for (poly) |point| {
        x0 = @min(x0, point[0]);
        y0 = @min(y0, point[1]);
        x1 = @max(x1, point[0]);
        y1 = @max(y1, point[1]);
    }
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .poly = poly };
}

/// Track-to-pad clearance for swept variable-width copper. `path_copper.tracks`
/// deliberately emits max-endpoint capsules for rules that only understand a
/// scalar width. Those capsules have round ends, while the rendered/fabricated
/// taper regions are butt-ended. Measuring the regions here prevents the cap at
/// a 0.55 x 0.25 mm launch from extending 0.15 mm behind the real pad.
fn checkRfPathPad(c: Ctx, routed: router.RouteResult, pads: []const PadBox) Err {
    for (routed.rf_port_outcomes) |path| {
        if (!path.success or path.physical.gate_removed) continue;
        const regions = try path_copper.regions(c.arena, path.physical.samples);
        if (regions.len == 0) continue;
        for (pads) |pad| {
            if (c.sameNet(path.net, pad.net)) continue;
            if (!pad.thru and pad.layer != path.physical.layer) continue;
            const eff = c.clr.between(path.net, pad.net);
            const pad_s = pad_shape.Shape{ .x0 = pad.x0, .y0 = pad.y0, .x1 = pad.x1, .y1 = pad.y1, .poly = pad.poly };
            var best = std.math.inf(f64);
            var best_shape: ?pad_shape.Shape = null;
            for (regions) |region| {
                if (region.len < 3) continue;
                const shape = regionShape(region);
                const gap = pad_shape.shapeGap(shape, pad_s, eff);
                if (gap < best) {
                    best = gap;
                    best_shape = shape;
                }
            }
            if (best >= eff - eps) continue;
            const shape = best_shape orelse continue;
            const mx = std.math.clamp((pad.x0 + pad.x1) / 2, shape.x0, shape.x1);
            const my = std.math.clamp((pad.y0 + pad.y1) / 2, shape.y0, shape.y1);
            try c.out.append(c.arena, .{
                .x = mx,
                .y = my,
                .gap = best,
                .clearance = eff,
                .kind = .track_pad,
                .who = padParties(path.net, pad),
                .layer = layerOf(path.physical.layer),
            });
        }
    }
}

/// pad ↔ pad (different parts, layer-aware): SMD pads clash only sharing a face,
/// a thru barrel clashes on every layer (opposite-face SMD pads may overlap).
fn checkPadPad(c: Ctx, pads: []const PadBox, pad_grid: *Grid) Err {
    for (pads, 0..) |a, i| {
        for (try pad_grid.near(c.arena, padBox(a), c.clr_max)) |ju| {
            if (ju <= i) continue;
            const b = pads[ju];
            if (a.part == b.part or c.sameNet(a.net, b.net)) continue;
            const share_face = a.thru or b.thru or a.layer == b.layer;
            if (!share_face) continue;
            const eff = c.clr.between(a.net, b.net);
            const gap = pad_shape.shapeGap(
                .{ .x0 = a.x0, .y0 = a.y0, .x1 = a.x1, .y1 = a.y1, .poly = a.poly },
                .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1, .poly = b.poly },
                eff,
            );
            if (gap < eff - eps) {
                const mx = (std.math.clamp((a.x0 + a.x1) / 2, b.x0, b.x1) + std.math.clamp((b.x0 + b.x1) / 2, a.x0, a.x1)) / 2;
                const my = (std.math.clamp((a.y0 + a.y1) / 2, b.y0, b.y1) + std.math.clamp((b.y0 + b.y1) / 2, a.y0, a.y1)) / 2;
                const face: ?board_layers.SignalIndex = if (a.thru or b.thru) null else layerOf(a.layer);
                try c.out.append(c.arena, .{ .x = mx, .y = my, .gap = gap, .clearance = eff, .kind = .pad_pad, .who = padPairParties(a, b), .layer = face });
            }
        }
    }
}

const Viol = std.ArrayList(Violation);
const Err = std.mem.Allocator.Error!void;
const GridErr = std.mem.Allocator.Error!Grid;

/// Drill-station rules over every drilled feature (vias + drilled pads): via
/// annular ring, pad annular ring, min-drill, and hole-to-hole. drill=0 features
/// are skipped, so an all-SMD board flags nothing.
fn checkDrillRules(
    arena: std.mem.Allocator,
    out: *Viol,
    pads: []const PadBox,
    vias: []const router.Via,
    rules: optimizer.DesignRules,
) std.mem.Allocator.Error!void {
    // annular ring: copper ring around a via drill must meet the fab minimum.
    for (vias) |v| {
        if (v.drill <= 0) continue;
        const ring = (v.dia - v.drill) / 2;
        if (ring < rules.min_annular - eps) {
            try out.append(arena, .{ .x = v.x, .y = v.y, .gap = ring, .clearance = rules.min_annular, .kind = .annular, .who = .{ .net_a = v.net } });
        }
    }
    // pad annular ring: a PLATED thru pad's ring = (min copper dim − drill)/2.
    // Exempt: NPTH, OVAL slots (axis-dependent), and VIA-SCALE pads (a stitch/
    // thermal/castellated pad, ≤ via_pad_max_mm, governed by the via rule).
    for (pads) |p| {
        if (p.drill <= 0 or p.drill_oval) continue;
        if (!p.thru or p.npth) continue; // SMD / non-plated → no plated ring
        const min_dim = @min(p.x1 - p.x0, p.y1 - p.y0);
        if (min_dim <= via_pad_max_mm) continue; // via-scale stitch/thermal/castellated
        const ring = (min_dim - p.drill) / 2;
        if (ring < rules.min_annular - eps) {
            try out.append(arena, .{ .x = p.hx, .y = p.hy, .gap = ring, .clearance = rules.min_annular, .kind = .pad_annular, .who = onePadParties(p) });
        }
    }
    // min drill: no via/pad hole below the minimum drill diameter.
    for (vias) |v| {
        if (v.drill > 0 and v.drill < rules.min_drill - eps) {
            try out.append(arena, .{ .x = v.x, .y = v.y, .gap = v.drill, .clearance = rules.min_drill, .kind = .min_drill, .who = .{ .net_a = v.net } });
        }
    }
    for (pads) |p| {
        if (p.drill > 0 and p.drill < rules.min_drill - eps) {
            try out.append(arena, .{ .x = p.hx, .y = p.hy, .gap = p.drill, .clearance = rules.min_drill, .kind = .min_drill, .who = onePadParties(p) });
        }
    }
    // hole ↔ hole: walls closer than the rule risk breakout. Grid-culled — a
    // via-fenced board carries hundreds of barrels, and all-pairs over them was
    // the drill station's whole cost. `holeBox` already contains the barrel and
    // any slot sweep, so a violating pair's boxes are within `hole_to_hole` of
    // each other and therefore always share a queried cell.
    const holes = try allHoles(arena, pads, vias);
    var hole_grid = try Grid.build(arena, Hole, holes, holeBox, rules.hole_to_hole);
    for (holes, 0..) |a, i| {
        for (try hole_grid.near(arena, holeBox(a), rules.hole_to_hole)) |ju| {
            if (ju <= i) continue; // emit each unordered pair once, at the lower index
            if (holePairViolation(rules, a, holes[ju])) |v| try out.append(arena, v);
        }
    }
}

/// One unordered hole pair's wall-gap verdict — the single rule body shared by
/// `checkDrillRules` and the additive gate (`ViaAdditionGate`). Wall gap is the
/// capsule (segment ± radius) distance (oval slots measured end-to-end); a
/// coincident via on a thru barrel is skipped.
fn holePairViolation(rules: optimizer.DesignRules, a: Hole, b: Hole) ?Violation {
    if (std.math.hypot(a.x - b.x, a.y - b.y) < eps) return null;
    const wall = segSegDist(a.x - a.shx, a.y - a.shy, a.x + a.shx, a.y + a.shy, b.x - b.shx, b.y - b.shy, b.x + b.shx, b.y + b.shy);
    const gap = wall - a.drill / 2 - b.drill / 2;
    if (gap >= rules.hole_to_hole - eps) return null;
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2, .gap = gap, .clearance = rules.hole_to_hole, .kind = .hole_hole, .who = .{
        .net_a = a.net,
        .part_a = a.part,
        .pad_a = a.num,
        .net_b = b.net,
        .part_b = b.part,
        .pad_b = b.num,
    } };
}

/// copper ↔ board edge: routed copper must stay `edge` inside the outline (exact
/// polygon when non-rectangular, else the rect); staged copper (> staging_exempt_mm
/// out) is skipped.
fn checkBoardEdge(
    arena: std.mem.Allocator,
    out: *Viol,
    placement: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
    edge: f64,
) std.mem.Allocator.Error!void {
    const br = placement.board_rect orelse return;
    const poly = placement.board_poly;
    for (vias) |v| {
        const vr = v.dia / 2;
        const inset = boardInset(br, poly, v.x, v.y);
        if (inset < -(vr + staging_exempt_mm)) continue; // staging band
        const gap = inset - vr;
        if (gap < edge - eps) {
            try out.append(arena, .{ .x = v.x, .y = v.y, .gap = gap, .clearance = edge, .kind = .board_edge, .who = .{ .net_a = v.net } });
        }
    }
    for (tracks) |t| {
        const hw = t.width / 2;
        // Rectangle inset is minimised at an endpoint; a concave polygon can also
        // cut the middle of a straight track, so that crossing is checked too.
        const ends = [_][2]f64{ .{ t.x1, t.y1 }, .{ t.x2, t.y2 } };
        var worst: f64 = std.math.inf(f64);
        var wx: f64 = t.x1;
        var wy: f64 = t.y1;
        for (ends) |e| {
            const inset = boardInset(br, poly, e[0], e[1]);
            if (inset < worst) {
                worst = inset;
                wx = e[0];
                wy = e[1];
            }
        }
        if (poly) |pl| {
            if (worst > -(hw + staging_exempt_mm)) {
                if (outline.segCrossesEdge(pl, t.x1, t.y1, t.x2, t.y2)) |hit| {
                    worst = 0;
                    wx = hit[0];
                    wy = hit[1];
                }
            }
        }
        if (worst < -(hw + staging_exempt_mm)) continue; // staging band
        const gap = worst - hw;
        if (gap < edge - eps) {
            try out.append(arena, .{ .x = wx, .y = wy, .gap = gap, .clearance = edge, .kind = .board_edge, .who = .{ .net_a = t.net } });
        }
    }
}

/// pad ↔ board edge: a component land is copper too, so a pad overhanging the
/// cut line — or crowding it closer than the copper-edge rule — is the same
/// fab defect as a track that does, and was the one feature class this check
/// never looked at. Measured at the pad's own copper extremes (its polygon
/// outline when it has one, else its box corners), so no radius is subtracted;
/// exact against an axis-aligned edge for round pads too, and conservative by
/// at most a corner's worth against an oblique outline edge.
///
/// The off-board exemption is the pad's own: a pad whose copper lies WHOLLY
/// outside the board RECTANGLE is parked in the staging band and skipped. That
/// is deliberately a wider exemption than the `staging_exempt_mm` distance band
/// the track/via loops use — the solver stages loose parts only `stage_gap_mm`
/// (5 mm) past the board edge, comfortably INSIDE that band, so a distance test
/// alone would flag every staged part's pads on every board that has one. A
/// part sitting entirely off the board is already `fab_readiness`'s
/// `part-off-board` error and the layout lint's `outside-outline` warning; this
/// rule is about copper on the board and copper straddling its cut. A pad
/// inside the rectangle but in a concave notch is NOT exempt — the polygon
/// inset still measures it, exactly as it does a via there.
///
/// Non-plated mounting holes carry no ring, so there is no copper to measure.
fn checkPadEdge(
    arena: std.mem.Allocator,
    out: *Viol,
    placement: optimizer.Placement,
    pads: []const PadBox,
    edge: f64,
) std.mem.Allocator.Error!void {
    const br = placement.board_rect orelse return;
    const poly = placement.board_poly;
    for (pads) |p| {
        if (p.npth) continue;
        const corners = [4][2]f64{ .{ p.x0, p.y0 }, .{ p.x1, p.y0 }, .{ p.x1, p.y1 }, .{ p.x0, p.y1 } };
        const verts: []const [2]f64 = if (p.poly.len >= 3) p.poly else corners[0..];
        var worst: f64 = std.math.inf(f64);
        var wx: f64 = p.x0;
        var wy: f64 = p.y0;
        var on_board = false;
        for (verts) |v| {
            if (edgeInset(br, v[0], v[1]) > 0) on_board = true;
            const inset = boardInset(br, poly, v[0], v[1]);
            if (inset < worst) {
                worst = inset;
                wx = v[0];
                wy = v[1];
            }
        }
        if (!on_board) continue; // staged off-board — see the note above
        if (worst < edge - eps) {
            try out.append(arena, .{ .x = wx, .y = wy, .gap = worst, .clearance = edge, .kind = .board_edge, .who = .{
                .net_a = p.net,
                .part_a = partyIndex(p.part),
                .pad_a = p.num,
            } });
        }
    }
}

/// component courtyard ↔ board edge: the rotation-aware courtyard must stay
/// inside the resolved component-edge margin. The built-in fabrication minimum
/// is 0.2 mm; `(design-rules (component-edge MM))` can state a wider assembly-
/// process requirement. A wholly off-board courtyard is staged work, already
/// handled by fab-readiness, and NPTH-only mounting hardware has no assembled
/// component body to police.
fn checkComponentEdge(
    arena: std.mem.Allocator,
    out: *Viol,
    placement: optimizer.Placement,
    edge: f64,
) std.mem.Allocator.Error!void {
    if (!(edge > 0)) return;
    const br = placement.board_rect orelse return;
    const poly = placement.board_poly;
    const bx1 = br.minx + br.w;
    const by1 = br.miny + br.h;
    for (placement.parts, 0..) |part, i| {
        var npth_only = part.pads.len > 0;
        for (part.pads) |pad| {
            if (!pad.npth) {
                npth_only = false;
                break;
            }
        }
        if (npth_only) continue;

        // The box is the cull — it contains the courtyard at every pose — and
        // the courtyard's own corners are the measurement. A box corner off a
        // quarter turn is a point the part does not occupy (it needs maximum +x
        // and minimum −y at once), so measuring it both over-reports the
        // crowding and marks the finding somewhere the reader sees no copper.
        const c = optimizer.worldCourtyard(&part);
        if (c.minx + c.w < br.minx or c.minx > bx1 or
            c.miny + c.h < br.miny or c.miny > by1) continue;
        const corners = pad_shape.worldCourtyardCorners(part);
        var worst = std.math.inf(f64);
        var at = corners[0];
        for (corners) |corner| {
            const inset = boardInset(br, poly, corner[0], corner[1]);
            if (inset < worst) {
                worst = inset;
                at = corner;
            }
        }
        if (worst < edge - eps) {
            try out.append(arena, .{
                .x = at[0],
                .y = at[1],
                .gap = worst,
                .clearance = edge,
                .kind = .component_edge,
                .severity = defaultSeverity(.component_edge),
                .who = .{ .part_a = partyIndex(i) },
            });
        }
    }
}

/// courtyard ↔ courtyard: two same-side parts whose keep-out courtyards
/// interpenetrate can't both be assembled (opposite sides never clash). Strict
/// overlap is the violation (negative gap = depth); touching exactly is legal.
/// Grid-culled on the courtyard boxes: an overlapping pair's boxes overlap, so
/// the two always share a queried cell and no clash can be missed.
///
/// The boxes cull; the parts' REAL rotated rectangles decide. A courtyard off a
/// quarter turn boxes up to √2 wider per axis, so two parts that clear each
/// other on the diagonal — the pose a connector fanned out at 45° is in — read
/// as clashing when only their boxes do, and a genuine clash is reported deeper
/// than it is (rf-switch-eval's SMPM pairs: 1.037 mm boxed against 0.733 mm of
/// real interpenetration).
fn checkCourtyards(arena: std.mem.Allocator, out: *Viol, placement: optimizer.Placement) std.mem.Allocator.Error!void {
    var grid = try Grid.build(arena, optimizer.Part, placement.parts, courtyardBox, 0);
    for (placement.parts, 0..) |a, i| {
        const ca = optimizer.worldCourtyard(&a);
        if (ca.w <= 0 or ca.h <= 0) continue;
        for (try grid.near(arena, courtyardBox(a), 0)) |bu| {
            const bi: usize = bu;
            if (bi <= i) continue; // emit each unordered pair once, at the lower index
            const b = placement.parts[bi];
            if (a.side != b.side) continue;
            const cb = optimizer.worldCourtyard(&b);
            if (cb.w <= 0 or cb.h <= 0) continue;
            if (rectOverlap(ca, cb).depth <= eps) continue;
            const ov = pose_math.obbPenetration(
                pad_shape.worldCourtyardCorners(a),
                pad_shape.worldCourtyardCorners(b),
            ) orelse continue;
            if (ov.depth > eps) {
                // Assembly concern → warn; `gap` = −depth (no clearance rule).
                // Parties are the two PARTS (a courtyard belongs to no net).
                try out.append(arena, .{ .x = ov.x, .y = ov.y, .gap = -ov.depth, .clearance = 0, .kind = .courtyard, .severity = defaultSeverity(.courtyard), .who = .{ .part_a = partyIndex(i), .part_b = partyIndex(bi) } });
            }
        }
    }
}

/// silk over pad: a footprint's silk lines/circles crossing another part's pad
/// mask opening (pad box grown by `mask_margin`) keeps solder from wetting. Own
/// pads are exempt (footprint geometry); at most ONE finding per owner part so a
/// dense layout doesn't drown the report. Only authored footprint art exists
/// in this pass. A warning, never a blocker.
fn checkSilkOverPad(
    arena: std.mem.Allocator,
    out: *Viol,
    placement: optimizer.Placement,
    pads: []const PadBox,
    pad_grid: *Grid,
    mask_margin: f64,
) Err {
    if (pads.len == 0) return;
    for (placement.parts, 0..) |part, pi| {
        if (part.features.silk_lines.len == 0 and part.features.silk_circles.len == 0) continue;
        const box = silkWorldBox(part) orelse continue;
        const s_layer: u8 = if (part.side == .bottom) 1 else 0;
        // Openings the silk could cross sit within `margin` of its bbox — the
        // grid delta. The grid answers in cell-scan order, so the kept openings
        // are put back into pad order: this check reports at most one finding
        // per part, and WHICH pad it names must not depend on cell geometry.
        var openings: std.ArrayList(Opening) = .empty;
        for (try pad_grid.near(arena, box, mask_margin)) |j| {
            if (pads[j].part == pi) continue; // own footprint's silk-vs-pad = geometry
            if (padOpening(pads[j], s_layer, mask_margin)) |ob| try openings.append(arena, .{ .box = ob, .pad = j });
        }
        std.mem.sort(Opening, openings.items, {}, openingBefore);
        if (silkOverPadHit(part, openings.items)) |hit| {
            // Parties: A = the part whose silk offends, B = the pad it covers.
            const victim = pads[hit.pad];
            try out.append(arena, .{ .x = hit.x, .y = hit.y, .gap = 0, .clearance = 0, .kind = .silk_over_pad, .severity = defaultSeverity(.silk_over_pad), .who = .{
                .part_a = partyIndex(pi),
                .net_b = victim.net,
                .part_b = partyIndex(victim.part),
                .pad_b = victim.num,
            } });
        }
    }
}

/// World bounding box of a part's footprint silk (lines + circle discs), or null
/// when it has none — the probe box for the silk-over-pad grid query.
fn silkWorldBox(part: optimizer.Part) ?[4]f64 {
    var x0: f64 = std.math.inf(f64);
    var y0: f64 = std.math.inf(f64);
    var x1: f64 = -std.math.inf(f64);
    var y1: f64 = -std.math.inf(f64);
    for (part.features.silk_lines) |l| {
        const a = optimizer.worldPadCenter(&part, l.x1, l.y1);
        const b = optimizer.worldPadCenter(&part, l.x2, l.y2);
        x0 = @min(x0, @min(a[0], b[0]));
        y0 = @min(y0, @min(a[1], b[1]));
        x1 = @max(x1, @max(a[0], b[0]));
        y1 = @max(y1, @max(a[1], b[1]));
    }
    for (part.features.silk_circles) |ci| {
        const c = optimizer.worldPadCenter(&part, ci.cx, ci.cy);
        x0 = @min(x0, c[0] - ci.r);
        y0 = @min(y0, c[1] - ci.r);
        x1 = @max(x1, c[0] + ci.r);
        y1 = @max(y1, c[1] + ci.r);
    }
    if (x1 < x0) return null;
    return .{ x0, y0, x1, y1 };
}

/// The first foreign opening `part`'s authored footprint silk crosses, or null.
fn silkOverPadHit(part: optimizer.Part, openings: []const Opening) ?SilkHit {
    for (openings) |o| {
        for (part.features.silk_lines) |l| {
            const a = optimizer.worldPadCenter(&part, l.x1, l.y1);
            const b = optimizer.worldPadCenter(&part, l.x2, l.y2);
            if (segRectHit(a[0], a[1], b[0], b[1], o.box)) |hit| return .{ .x = hit[0], .y = hit[1], .pad = o.pad };
        }
        for (part.features.silk_circles) |ci| {
            const c = optimizer.worldPadCenter(&part, ci.cx, ci.cy);
            if (circleRectHit(c[0], c[1], ci.r, o.box)) return .{ .x = c[0], .y = c[1], .pad = o.pad };
        }
    }
    return null;
}

/// A candidate mask opening for the silk check: its world box + the `pads`
/// index it came from (so a hit can name the pad the silk covers).
const Opening = struct { box: [4]f64, pad: usize };

/// Pad order over mask openings — the stable identity of a one-per-part finding.
fn openingBefore(_: void, a: Opening, b: Opening) bool {
    return a.pad < b.pad;
}

/// Where silk crosses an opening, and which `pads` entry it was.
const SilkHit = struct { x: f64, y: f64, pad: usize };

/// track width: each track must be at least its net-class `(width …)`, else the
/// board `min_width`. A thinner track is an error; width-less tracks are skipped.
const TrackWidthInput = struct {
    placement: optimizer.Placement,
    routed: router.RouteResult,
    tracks: []const router.Track,
    min_width: f64,
    /// Index-aligned IPC-2221 widths from a solved power-copper graph.
    /// Null entries retain the conservative whole-net class rule.
    local_power_widths: []const ?f64 = &.{},
};

fn adaptivePowerNet(placement: optimizer.Placement, net_i: usize) bool {
    if (net_i >= placement.nets.len) return false;
    const name = placement.nets[net_i].name;
    if (placement.rules.powerWidthForNet(name) == null or router.netHasPlane(placement, name)) return false;
    if (net_i < placement.rules.net.len) {
        const rule = placement.rules.net[net_i];
        if (rule.rf.impedance.ohms > 0 or rule.rf.impedance.diff_ohms > 0) return false;
    }
    for (placement.diff_pairs) |pair| if (pair.p == net_i or pair.n == net_i) return false;
    return true;
}

const WidthShortfall = struct {
    track_index: usize,
    actual: f64,
    required: f64,
};

fn checkTrackWidth(arena: std.mem.Allocator, out: *Viol, in: TrackWidthInput) std.mem.Allocator.Error!void {
    const nrules = in.placement.rules.net;
    const power_shortfalls = try arena.alloc(?WidthShortfall, in.placement.nets.len);
    @memset(power_shortfalls, null);
    for (in.tracks, 0..) |t, track_index| {
        if (t.width <= eps) continue; // no recorded width — not a real defect
        var want = in.min_width;
        var adaptive_power = false;
        if (t.net >= 0) {
            const ni: usize = @intCast(t.net);
            if (ni < nrules.len and nrules[ni].width > 0) want = nrules[ni].width;
            if (ni < in.placement.nets.len and adaptivePowerNet(in.placement, ni)) {
                adaptive_power = true;
                want = @max(want, in.placement.rules.powerWidthForNet(in.placement.nets[ni].name) orelse 0);
            }
        }
        const local_power_width = if (track_index < in.local_power_widths.len) in.local_power_widths[track_index] else null;
        if (local_power_width) |local| {
            const branch_floor = if (t.net >= 0 and @as(usize, @intCast(t.net)) < nrules.len)
                nrules[@intCast(t.net)].pad_neck.power_branch_width
            else
                0;
            want = @max(in.min_width, @max(branch_floor, local));
        }
        const under_width = t.width < want - eps;
        // Fabrication width remains a hard rule. Electrical power capacity is
        // intentionally advisory: the router has already widened this route as
        // far as exact clearance allows, and one warning at the worst neck is
        // more useful than rejecting a connected board or flooding every 50 um
        // taper slice with the same finding.
        if (t.width < in.min_width - eps) {
            try out.append(arena, .{
                .x = (t.x1 + t.x2) / 2,
                .y = (t.y1 + t.y2) / 2,
                .gap = t.width,
                .clearance = in.min_width,
                .kind = .track_width,
                .who = .{ .net_a = t.net, .track_a = partyIndex(track_index) },
                .layer = layerOf(t.layer),
            });
            continue;
        }
        if (adaptive_power and under_width) {
            const ni: usize = @intCast(t.net);
            const prior = power_shortfalls[ni];
            if (prior == null or t.width / want < prior.?.actual / prior.?.required)
                power_shortfalls[ni] = .{ .track_index = track_index, .actual = t.width, .required = want };
            continue;
        }
        // A solved local-current width is already the electrical exception to
        // the whole-net class. Do not then let a geometric pad-neck exception
        // shrink below that proven current requirement.
        if (local_power_width != null) {
            if (under_width) try out.append(arena, .{
                .x = (t.x1 + t.x2) / 2,
                .y = (t.y1 + t.y2) / 2,
                .gap = t.width,
                .clearance = want,
                .kind = .track_width,
                .who = .{ .net_a = t.net, .track_a = partyIndex(track_index) },
                .layer = layerOf(t.layer),
            });
            continue;
        }
        const neck_ok = if (under_width)
            try pad_neck.allowsTrack(arena, in.placement, t, want, in.min_width)
        else
            false;
        const taper_ok = portFramePadTaper(in.routed, t, want);
        if (!under_width) continue;
        if (neck_ok or taper_ok) continue;
        try out.append(arena, .{ .x = (t.x1 + t.x2) / 2, .y = (t.y1 + t.y2) / 2, .gap = t.width, .clearance = want, .kind = .track_width, .who = .{ .net_a = t.net, .track_a = partyIndex(track_index) }, .layer = layerOf(t.layer) });
    }
    for (power_shortfalls) |maybe_shortfall| {
        const shortfall = maybe_shortfall orelse continue;
        const t = in.tracks[shortfall.track_index];
        try out.append(arena, .{
            .x = (t.x1 + t.x2) / 2,
            .y = (t.y1 + t.y2) / 2,
            .gap = shortfall.actual,
            .clearance = shortfall.required,
            .kind = .power_width,
            .severity = defaultSeverity(.power_width),
            .who = .{ .net_a = t.net, .track_a = partyIndex(shortfall.track_index) },
            .layer = layerOf(t.layer),
        });
    }
}

/// The controlled-width rule applies to the transmission-line body, not to
/// the one-width linear taper that joins it to a narrower land. Only a solver-
/// proven port-frame route earns this exemption, and only for an exact emitted
/// chord in that route's variable-width centreline. Imported or hand-drawn
/// thin copper therefore remains a fabrication error.
fn portFramePadTaper(routed: router.RouteResult, track: router.Track, nominal_width: f64) bool {
    if (track.width >= nominal_width - eps) return false;
    for (routed.rf_port_outcomes) |outcome| {
        if (outcome.net != track.net or outcome.physical.layer != track.layer) continue;
        if (!outcome.success or outcome.physical.gate_removed) continue;
        const samples = outcome.physical.samples;
        var cursor: usize = 0;
        var before = nextCleanRfSample(samples, &cursor) orelse continue;
        while (nextCleanRfSample(samples, &cursor)) |sample| {
            // path_copper.tracks uses the wider endpoint so every private
            // capsule conservatively covers the linear swept profile.
            const width = @max(before.width_mm, sample.width_mm);
            if (@abs(track.width - width) <= eps and sameChord(track, before.at, sample.at)) return true;
            before = sample;
        }
    }
    return false;
}

/// Iterate the same normalized sample stream as path_copper: consecutive
/// points within 1e-9 mm collapse onto the first coordinate and keep the widest
/// width. In particular, an all-coincident stream produces no chord.
fn nextCleanRfSample(samples: []const RfSample, cursor: *usize) ?RfSample {
    if (cursor.* >= samples.len) return null;
    var clean = samples[cursor.*];
    cursor.* += 1;
    while (cursor.* < samples.len) {
        const sample = samples[cursor.*];
        if (!(std.math.hypot(sample.at[0] - clean.at[0], sample.at[1] - clean.at[1]) <= 1e-9)) break;
        clean.width_mm = @max(clean.width_mm, sample.width_mm);
        cursor.* += 1;
    }
    return clean;
}

fn sameChord(track: router.Track, a: [2]f64, b: [2]f64) bool {
    return (samePoint(.{ track.x1, track.y1 }, a) and samePoint(.{ track.x2, track.y2 }, b)) or
        (samePoint(.{ track.x1, track.y1 }, b) and samePoint(.{ track.x2, track.y2 }, a));
}

fn samePoint(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) <= eps and @abs(a[1] - b[1]) <= eps;
}

/// The mask opening (pad box grown by `margin`) of a pad on side `s_layer`, or
/// null when it doesn't open there (SMD → its side only; thru/NPTH → both).
fn padOpening(p: PadBox, s_layer: u8, margin: f64) ?[4]f64 {
    if (!(p.thru or p.layer == s_layer)) return null;
    return .{ p.x0 - margin, p.y0 - margin, p.x1 + margin, p.y1 + margin };
}

/// If segment (ax,ay)-(bx,by) penetrates AABB `box`, an interior point; else
/// null (Liang–Barsky clip; a mere edge-graze doesn't count).
fn segRectHit(ax: f64, ay: f64, bx: f64, by: f64, box: [4]f64) ?[2]f64 {
    const dx = bx - ax;
    const dy = by - ay;
    var t0: f64 = 0;
    var t1: f64 = 1;
    const p = [_]f64{ -dx, dx, -dy, dy };
    const qv = [_]f64{ ax - box[0], box[2] - ax, ay - box[1], box[3] - ay };
    for (p, qv) |pi, qi| {
        if (@abs(pi) < 1e-12) {
            if (qi < 0) return null; // parallel and outside this slab
        } else {
            const r = qi / pi;
            if (pi < 0) {
                if (r > t1) return null;
                if (r > t0) t0 = r;
            } else {
                if (r < t0) return null;
                if (r < t1) t1 = r;
            }
        }
    }
    if (t1 < t0) return null;
    const tm = (t0 + t1) / 2;
    const mx = ax + tm * dx;
    const my = ay + tm * dy;
    if (mx > box[0] + eps and mx < box[2] - eps and my > box[1] + eps and my < box[3] - eps) return .{ mx, my };
    return null;
}

/// True when a stroked circle (r at cx,cy) crosses AABB `box`: the nearest box
/// point is inside the disc AND the farthest corner is outside it (the ring
/// passes through, vs. the pad sitting wholly inside an encircling marker).
fn circleRectHit(cx: f64, cy: f64, r: f64, box: [4]f64) bool {
    const nx = std.math.clamp(cx, box[0], box[2]);
    const ny = std.math.clamp(cy, box[1], box[3]);
    if (std.math.hypot(cx - nx, cy - ny) >= r - eps) return false;
    const fx = if (cx - box[0] > box[2] - cx) box[0] else box[2];
    const fy = if (cy - box[1] > box[3] - cy) box[1] else box[3];
    return std.math.hypot(cx - fx, cy - fy) > r + eps;
}

/// Overlap of two AABBs → the centre of the shared region, or null when they
/// don't properly overlap (touching edges don't count).
fn boxOverlap(a: [4]f64, b: [4]f64) ?[2]f64 {
    const ox0 = @max(a[0], b[0]);
    const oy0 = @max(a[1], b[1]);
    const ox1 = @min(a[2], b[2]);
    const oy1 = @min(a[3], b[3]);
    if (ox1 <= ox0 + eps or oy1 <= oy0 + eps) return null;
    return .{ (ox0 + ox1) / 2, (oy0 + oy1) / 2 };
}

// ── Spatial hash ─────────────────────────────────────────────────────────────
// Culls the pairwise checks from O(n²) to ~O(n). A box CONTAINS its feature, so a
// query (probe box inflated by the check's MAX separation) that drops a pair
// proves it beyond the rule; survivors run the identical exact test, so the
// result is unchanged (candidates come back deduped + sorted → nested-loop order).

/// Packed signed cell coordinate → key, biased non-negative in i64 so the pack
/// is a widening cast (dodges the i32 overflow at the clamp bound), not a bitcast.
fn cellKey(cx: i32, cy: i32) u64 {
    const ux: u64 = @intCast(@as(i64, cx) + 0x40000000);
    const uy: u64 = @intCast(@as(i64, cy) + 0x40000000);
    return (ux << 32) | uy;
}

/// A scaled coordinate → cell index, saturating far off-board so the narrow is
/// always defined and two distant features still share a boundary cell.
fn floorCell(scaled: f64) i32 {
    const f = @floor(scaled);
    if (!(f > -2.0e9)) return -0x40000000;
    if (!(f < 2.0e9)) return 0x40000000;
    return numeric.checkedInt(i32, f) orelse 0;
}

/// Uniform spatial hash over feature AABBs (built from `items` via `boxOf`) with
/// a reused candidate scratch. Each cell holds the indices whose box overlaps it.
const Grid = struct {
    inv: f64 = 1,
    map: std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty,
    cand: std.ArrayList(u32) = .empty,
    /// Per-feature "already collected by this query" stamp. One epoch bump per
    /// query makes the dedupe a compare-and-store instead of a sort.
    seen: []u32 = &.{},
    epoch: u32 = 0,

    /// Cell size ~ the typical span raised to `delta`, floored at 0.5 mm, never
    /// letting the largest box span over 64² cells (bounds degenerate input).
    fn build(a: std.mem.Allocator, comptime T: type, xs: []const T, comptime bf: fn (T) [4]f64, delta: f64) GridErr {
        var sum: f64 = 0;
        var maxext: f64 = 0;
        for (xs) |it| {
            const e = @max(bf(it)[2] - bf(it)[0], bf(it)[3] - bf(it)[1]);
            sum += e;
            maxext = @max(maxext, e);
        }
        var cell = @max(@max(@max(sum / @max(1.0, @as(f64, @floatFromInt(xs.len))), 2 * delta), 0.5), maxext / 64.0);
        if (!(std.math.isFinite(cell) and cell > 0)) cell = 1;
        var g = Grid{ .inv = 1.0 / cell, .seen = try a.alloc(u32, xs.len) };
        @memset(g.seen, 0);
        for (xs, 0..) |it, i| {
            const b = bf(it);
            var cx = floorCell(b[0] * g.inv);
            const cx1 = floorCell(b[2] * g.inv);
            const cy1 = floorCell(b[3] * g.inv);
            while (cx <= cx1) : (cx += 1) {
                var cy = floorCell(b[1] * g.inv);
                while (cy <= cy1) : (cy += 1) {
                    const e = try g.map.getOrPut(a, cellKey(cx, cy));
                    if (!e.found_existing) e.value_ptr.* = .empty;
                    try e.value_ptr.append(a, @intCast(i));
                }
            }
        }
        return g;
    }

    /// Deduped candidate indices whose cells meet `box`±`delta`, in cell-scan
    /// order (deterministic: the bbox loop is fixed and each cell's list is in
    /// build order — no hash map is ever iterated).
    ///
    /// Dedupe is the part callers DEPEND on: a box spanning several cells lists
    /// its neighbour once per shared cell, and a duplicate candidate would emit
    /// a duplicate violation. Order is not depended on for a verdict — every
    /// caller either judges each candidate independently or takes an unordered
    /// pair at the lower index — except `checkSilkOverPad`, which sorts the
    /// openings it keeps so its one-per-part pick stays the lowest pad index.
    fn near(self: *Grid, arena: std.mem.Allocator, box: [4]f64, delta: f64) std.mem.Allocator.Error![]const u32 {
        self.cand.clearRetainingCapacity();
        // Wrap would make a stale stamp read as "already seen" and silently
        // drop a candidate, so retire the stamps rather than reusing an epoch.
        if (self.epoch == std.math.maxInt(u32)) {
            @memset(self.seen, 0);
            self.epoch = 0;
        }
        self.epoch += 1;
        var cx = floorCell((box[0] - delta) * self.inv);
        const cx1 = floorCell((box[2] + delta) * self.inv);
        const cy1 = floorCell((box[3] + delta) * self.inv);
        while (cx <= cx1) : (cx += 1) {
            var cy = floorCell((box[1] - delta) * self.inv);
            while (cy <= cy1) : (cy += 1) {
                const b = self.map.get(cellKey(cx, cy)) orelse continue;
                for (b.items) |v| {
                    if (self.seen[v] == self.epoch) continue;
                    self.seen[v] = self.epoch;
                    try self.cand.append(arena, v);
                }
            }
        }
        return self.cand.items;
    }
};

/// Feature AABBs: via bounding square, track segment-bbox + half-width, pad box.
fn viaBox(v: router.Via) [4]f64 {
    const r = v.dia / 2;
    return .{ v.x - r, v.y - r, v.x + r, v.y + r };
}
fn trackBox(t: router.Track) [4]f64 {
    const hw = t.width / 2;
    return .{ @min(t.x1, t.x2) - hw, @min(t.y1, t.y2) - hw, @max(t.x1, t.x2) + hw, @max(t.y1, t.y2) + hw };
}
fn padBox(p: PadBox) [4]f64 {
    return .{ p.x0, p.y0, p.x1, p.y1 };
}
/// A drilled hole's barrel box, widened by the slot sweep so an oval reaches
/// both arc centres.
fn holeBox(h: Hole) [4]f64 {
    const r = h.drill / 2 + @max(@abs(h.shx), @abs(h.shy));
    return .{ h.x - r, h.y - r, h.x + r, h.y + r };
}
/// A part's world courtyard as a grid box (degenerate when it has none — such a
/// part is skipped by the check that queries this).
fn courtyardBox(p: optimizer.Part) [4]f64 {
    const c = optimizer.worldCourtyard(&p);
    return .{ c.minx, c.miny, c.minx + c.w, c.miny + c.h };
}
/// A bare point as a grid probe box.
fn pointBox(x: f64, y: f64) [4]f64 {
    return .{ x, y, x, y };
}

/// One (pin-name → net-index) entry in a ref-des's pin list.
const PinNet = struct { pin: []const u8, net: i32 };

/// The net a pad lands on: the last matching pin in `list` (last-wins, mirroring
/// the old map's overwrite), or -1 (no net).
fn lookupNet(list: []const PinNet, pin: []const u8) i32 {
    var net: i32 = -1;
    for (list) |e| {
        if (std.mem.eql(u8, e.pin, pin)) net = e.net;
    }
    return net;
}

/// The world pad-rect list (rotation-aware) with net + part index. The pad→net
/// join keys on the ref-des slice directly (per-ref pin list) — ZERO formatted
/// allocations per check call.
fn padBoxes(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]PadBox {
    var by_ref: std.StringHashMapUnmanaged(std.ArrayList(PinNet)) = .empty;
    for (placement.nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            const gop = try by_ref.getOrPut(arena, pin.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, .{ .pin = pin.pin, .net = @intCast(ni) });
        }
    }
    var list: std.ArrayList(PadBox) = .empty;
    for (placement.parts, 0..) |part, pi| {
        const layer: u8 = if (part.side == .bottom) 1 else 0;
        const pins: []const PinNet = if (by_ref.get(part.ref_des)) |l| l.items else &.{};
        for (part.pads) |pad| {
            const sh = try pad_shape.worldShape(arena, part, pad);
            const net = lookupNet(pins, pad.number);
            const c = optimizer.worldPadCenter(&part, pad.x, pad.y);
            // World half-vector to a slot's arc centres (0 for a round bore).
            var shx: f64 = 0;
            var shy: f64 = 0;
            if (pad.isSlot()) {
                const e1 = optimizer.worldPadCenter(&part, pad.x + pad.slot_half[0], pad.y + pad.slot_half[1]);
                shx = e1[0] - c[0];
                shy = e1[1] - c[1];
            }
            try list.append(arena, .{
                .x0 = sh.x0,
                .y0 = sh.y0,
                .x1 = sh.x1,
                .y1 = sh.y1,
                .poly = sh.poly,
                .net = net,
                .part = pi,
                .num = pad.number,
                .layer = layer,
                .thru = pad.thru,
                .npth = pad.npth,
                .drill_oval = pad.isSlot(),
                .drill = pad.drill,
                .hx = c[0],
                .hy = c[1],
                .shx = shx,
                .shy = shy,
            });
        }
    }
    return list.toOwnedSlice(arena);
}

/// Every drilled hole (pads + vias with drill>0) unified into one arena list.
fn allHoles(arena: std.mem.Allocator, pads: []const PadBox, vias: []const router.Via) std.mem.Allocator.Error![]Hole {
    var list: std.ArrayList(Hole) = .empty;
    for (pads) |p| {
        if (p.drill <= 0) continue;
        try list.append(arena, .{ .x = p.hx, .y = p.hy, .drill = p.drill, .shx = p.shx, .shy = p.shy, .net = p.net, .part = partyIndex(p.part), .num = p.num });
    }
    for (vias) |v| {
        if (v.drill <= 0) continue;
        try list.append(arena, .{ .x = v.x, .y = v.y, .drill = v.drill, .net = v.net });
    }
    return list.toOwnedSlice(arena);
}

/// Overlap of two rects: penetration depth (min axis overlap; ≤0 ⇒ disjoint or
/// touching) and the shared-region centre. Used by the courtyard check.
fn rectOverlap(a: optimizer.BoardRect, b: optimizer.BoardRect) struct { depth: f64, x: f64, y: f64 } {
    const ax1 = a.minx + a.w;
    const ay1 = a.miny + a.h;
    const bx1 = b.minx + b.w;
    const by1 = b.miny + b.h;
    const ox = @min(ax1, bx1) - @max(a.minx, b.minx);
    const oy = @min(ay1, by1) - @max(a.miny, b.miny);
    if (ox <= 0 or oy <= 0) return .{ .depth = 0, .x = 0, .y = 0 };
    const cx = (@max(a.minx, b.minx) + @min(ax1, bx1)) / 2;
    const cy = (@max(a.miny, b.miny) + @min(ay1, by1)) / 2;
    return .{ .depth = @min(ox, oy), .x = cx, .y = cy };
}

/// How far outside the outline a feature may sit before the board-edge check
/// treats it as staged (off-board) rather than flagging it — copper just past
/// the edge is an error, copper centimetres away is a workflow state.
pub const staging_exempt_mm: f64 = 10.0;

/// Signed distance from (x,y) to the nearest rectangle edge (positive inside).
fn edgeInset(br: optimizer.BoardRect, x: f64, y: f64) f64 {
    const dl = x - br.minx;
    const dr = br.minx + br.w - x;
    const dt = y - br.miny;
    const db = br.miny + br.h - y;
    return @min(@min(dl, dr), @min(dt, db));
}

/// Signed inset of (x,y) from the outline (exact polygon when non-rectangular,
/// else the rect). Positive = inside.
fn boardInset(br: optimizer.BoardRect, poly: ?[]const [2]f64, x: f64, y: f64) f64 {
    if (poly) |p| {
        if (p.len >= 3) return outline.signedInset(p, x, y);
    }
    return edgeInset(br, x, y);
}

/// Shortest distance from point (px,py) to segment (ax,ay)-(bx,by).
fn segPointDist(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < eps) return std.math.hypot(px - ax, py - ay);
    const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    return std.math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

/// Shortest distance from a track's centreline to a pad's copper (0 inside the
/// pad), or +inf when the whole segment stays > `win` from the pad bbox. The
/// span is slab-clipped to the pad's `win`-inflated bbox, then sampled at 0.05 mm
/// against the pad's real outline — exact enough for a pass/fail and polygon-safe.
fn segShapeDist(t: router.Track, p: PadBox, win: f64) f64 {
    return pad_shape.segmentDist(
        .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .poly = p.poly },
        .{ t.x1, t.y1 },
        .{ t.x2, t.y2 },
        win,
    );
}

/// Shortest distance between two segments (0 when they properly cross).
pub fn segSegDist(ax1: f64, ay1: f64, ax2: f64, ay2: f64, bx1: f64, by1: f64, bx2: f64, by2: f64) f64 {
    const d1x = ax2 - ax1;
    const d1y = ay2 - ay1;
    const d2x = bx2 - bx1;
    const d2y = by2 - by1;
    const den = d1x * d2y - d1y * d2x;
    if (@abs(den) > 1e-12) {
        const t = ((bx1 - ax1) * d2y - (by1 - ay1) * d2x) / den;
        const u = ((bx1 - ax1) * d1y - (by1 - ay1) * d1x) / den;
        if (t >= 0 and t <= 1 and u >= 0 and u <= 1) return 0;
    }
    var d = segPointDist(ax1, ay1, ax2, ay2, bx1, by1);
    d = @min(d, segPointDist(ax1, ay1, ax2, ay2, bx2, by2));
    d = @min(d, segPointDist(bx1, by1, bx2, by2, ax1, ay1));
    d = @min(d, segPointDist(bx1, by1, bx2, by2, ax2, ay2));
    return d;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/drc - flags a via that crowds a foreign pad's clearance
test "check flags a via overlapping a foreign pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // One part with a single pad on net SIG at the origin; a via on net GND
    // sits 0.3 mm away — via edge (dia 0.6 ⇒ r 0.3) lands right on the pad edge,
    // far inside a 0.127 mm clearance.
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    const vias = [_]router.Via{.{ .x = 0.5, .y = 0, .dia = 0.6, .net = 99 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };

    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .via_pad));
    try testing.expect(firstOfKind(v, .via_pad).?.gap < 0.127);
}

// spec: placement/drc - passes a via that shares the pad's net
test "check ignores a via on the same net as the pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    // net index 0 == the SIG pad's net ⇒ same net, allowed to sit on the pad.
    const vias = [_]router.Via{.{ .x = 0.2, .y = 0, .dia = 0.6, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };

    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 0), countKind(v, .via_pad));
}

// spec: placement/drc - flags a via whose annular ring is under the fab minimum
test "check flags a thin annular ring" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    // dia 0.4 / drill 0.3 ⇒ 0.05 mm ring, far under the 0.13 mm floor; the
    // second via has a healthy ring and a legacy via records no drill at all.
    const vias = [_]router.Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .drill = 0.3, .net = 0 },
        .{ .x = 5, .y = 0, .dia = 0.6, .drill = 0.3, .net = 0 },
        .{ .x = 9, .y = 0, .dia = 0.4, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .annular));
}

// spec: placement/drc - flags copper crowding the board outline and skips the off-board staging band
test "check flags copper at the board edge, not staged copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
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
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    // Track ends 0.05 mm from the left edge (violation); a via sits 20 mm
    // outside the outline — the staging band — and must be skipped.
    const tracks = [_]router.Track{
        .{ .x1 = 0.05, .y1 = 5, .x2 = 3, .y2 = 5, .layer = 0, .width = 0.127, .net = 0 },
    };
    const vias = [_]router.Via{.{ .x = -20, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 };
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .board_edge));
}

// spec: placement/drc - checks the board edge against a non-rectangular outline polygon, catching copper in a notch
test "check measures the exact outline polygon on an L-shaped board" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // 10×10 board with the corner at (6..10, 4..10) notched out (y-down).
    const l_poly = [_][2]f64{
        .{ 0, 0 }, .{ 10, 0 }, .{ 10, 4 }, .{ 6, 4 }, .{ 6, 10 }, .{ 0, 10 },
    };
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
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .board_poly = &l_poly,
    };
    // Via at (8,8): INSIDE the bbox rectangle but in the notch — off the real
    // board, only 2 mm out, so it must be flagged (not staging-exempt). A via
    // at (3,5) sits ≥ clearance inside every polygon edge — clean. A via 20 mm
    // below the board is parked in the staging band — skipped. The track cuts
    // across the notch wall (both endpoints comfortably inside): flagged.
    const vias = [_]router.Via{
        .{ .x = 8, .y = 8, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 3, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 3, .y = 30, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 2, .y1 = 8, .x2 = 9, .y2 = 8, .layer = 0, .width = 0.127, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 };
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 2), countKind(v, .board_edge));
    // The notch via is reported at its own position, the track at the wall.
    var edge_index: usize = 0;
    for (v) |viol| {
        if (viol.kind != .board_edge) continue;
        const expected_x: f64 = if (edge_index == 0) 8 else 6;
        try testing.expectApproxEqAbs(expected_x, viol.x, 1e-9);
        edge_index += 1;
    }
}

// spec: placement/drc - the polygon board-edge inset is measured against the copper-edge design rule
test "check measures the polygon inset against the copper-edge rule" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Same L-shaped board as above (corner (6..10, 4..10) notched out, y-down).
    const l_poly = [_][2]f64{
        .{ 0, 0 }, .{ 10, 0 }, .{ 10, 4 }, .{ 6, 4 }, .{ 6, 10 }, .{ 0, 10 },
    };
    var placement = optimizer.Placement{
        .parts = &.{},
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
        .board_poly = &l_poly,
    };
    // Via at (5.2, 8): 0.8 mm from the notch wall (x=6) ⇒ gap 0.6 after the
    // 0.2 mm via radius. Clean under the default 0.127 mm rule; a
    // (design-rules (copper-edge 0.75)) must flag it — and the reported
    // clearance must BE the rule value. The plain bbox rectangle would put
    // this via 2 mm inside (nearest bbox edge y=10), so a flag proves the
    // POLYGON inset was measured against the copper-edge rule.
    const vias = [_]router.Via{.{ .x = 5.2, .y = 8, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };

    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, routed, 0.127), .board_edge));

    placement.rules = .{ .design = .{ .edge = .{ .copper = 0.75, .component = 2.5 } } };
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .board_edge));
    try testing.expectEqual(@as(f64, 0.75), v[0].clearance);
    try testing.expectApproxEqAbs(@as(f64, 0.6), v[0].gap, 1e-9);
}

// spec: placement/drc - a routed module with a crowded ground pad has no clearance violations
test "route then check is clean when a ground pad abuts a foreign pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // A hub whose small GND pad (1) sits at 0.4 mm pitch hard against a foreign
    // VCC pad (2): a via dropped at the GND pad centre (0.4 mm ⌀ ⇒ 0.2 mm
    // radius) would crowd the VCC pad. The router must fan the via clear so the
    // fully routed module passes its own clearance DRC.
    const u_pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "2", .x = 0.4, .y = 0, .w = 0.3, .h = 0.3 },
    };
    const c_pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "2", .x = 0.4, .y = 0, .w = 0.3, .h = 0.3 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.6, .hh = 0.6, .pads = &u_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.6, .hh = 0.6, .pads = &c_pads, .fallback = false, .x = 4, .y = 0 },
    };
    const gnd = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "2" } };
    const vcc = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "GND", .pins = &gnd }, .{ .name = "VCC", .pins = &vcc } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = true,
    };

    const routed = try router.route(arena, placement, .{});
    // Both GND pads are still served by a via (connectivity preserved)…
    try testing.expect(routed.vias.len >= 2);
    // …and the routed module has zero clearance violations. The fan is judged
    // on ERRORS: at 0.4 mm pitch the escape to the fanned via can only leave
    // its land off the centre, which the same-net `land_transit` rule reports
    // as a warning — that is the shape this fixture is built out of, not
    // something the fan did wrong.
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 0), errorCount(v));
    try testing.expectEqual(@as(usize, 0), countKind(v, .track_pad));
    try testing.expectEqual(@as(usize, 0), countKind(v, .via_pad));
}

// spec: placement/drc - flags same-layer track crossings and sub-clearance pairs between nets
test "check flags track-to-track crossings but not exact-pitch neighbours" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{};
    const placement = optimizer.Placement{
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
    };
    const w = 0.127;
    const clearance = 0.127;

    // An X crossing between two nets on the top layer — the escape-stub short
    // this check exists to expose. Gap comes out negative (overlap).
    const crossing = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 2, .layer = 0, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = 2, .x2 = 2, .y2 = 0, .layer = 0, .width = w, .net = 1 },
    };
    const crossed = router.RouteResult{ .tracks = &crossing, .vias = &.{}, .routed = 2, .total = 2 };
    const v1 = try check(arena, placement, crossed, clearance);
    try testing.expectEqual(@as(usize, 1), countKind(v1, .track_track));
    try testing.expect(firstOfKind(v1, .track_track).?.gap < 0);

    // The same two tracks on DIFFERENT layers never interact.
    const stacked = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 2, .layer = 0, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = 2, .x2 = 2, .y2 = 0, .layer = 1, .width = w, .net = 1 },
    };
    const layered = router.RouteResult{ .tracks = &stacked, .vias = &.{}, .routed = 2, .total = 2 };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, layered, clearance), .track_track));

    // Two parallel tracks at exactly grid pitch (width + clearance centre to
    // centre) are the router's legal adjacency — must NOT flag.
    const pitch = w + clearance;
    const parallel = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = pitch, .x2 = 5, .y2 = pitch, .layer = 0, .width = w, .net = 1 },
    };
    const legal = router.RouteResult{ .tracks = &parallel, .vias = &.{}, .routed = 2, .total = 2 };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, legal, clearance), .track_track));

    // Nudge one inside the clearance rule → sub-clearance pair flags.
    const close = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = pitch * 0.7, .x2 = 5, .y2 = pitch * 0.7, .layer = 0, .width = w, .net = 1 },
    };
    const tight = router.RouteResult{ .tracks = &close, .vias = &.{}, .routed = 2, .total = 2 };
    const v2 = try check(arena, placement, tight, clearance);
    try testing.expectEqual(@as(usize, 1), countKind(v2, .track_track));
}

// spec: placement/drc - flags a track crossing a foreign pad on its layer; other-layer SMD pads don't clash
test "check flags track-to-pad clashes layer-aware" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // One top-side part with an SMD pad on net PAD (index 0) at the origin,
    // plus a through-hole pad on the same part further out.
    const pads = [_]@import("geometry.zig").Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 3, .y = 0, .w = 0.6, .h = 0.6, .thru = true },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const p1 = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const p2 = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "2" }};
    const nets = [_]FlatNet{ .{ .name = "PAD", .pins = &p1 }, .{ .name = "SIG", .pins = &.{} }, .{ .name = "THRU", .pins = &p2 } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -5,
        .maxx = 5,
        .maxy = 5,
        .generated = true,
    };

    // A SIG track slicing across the SMD pad on the pad's own layer → flagged.
    const across = [_]router.Track{.{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.127, .net = 1 }};
    const top = router.RouteResult{ .tracks = &across, .vias = &.{}, .routed = 1, .total = 1 };
    const v1 = try check(arena, placement, top, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v1, .track_pad));
    try testing.expect(firstOfKind(v1, .track_pad).?.gap < 0);

    // The same track on the BOTTOM layer passes under the top SMD pad — legal.
    const under = [_]router.Track{.{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 1, .width = 0.127, .net = 1 }};
    const bot = router.RouteResult{ .tracks = &under, .vias = &.{}, .routed = 1, .total = 1 };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, bot, 0.127), .track_pad));

    // A through-hole pad clashes on EVERY layer — the bottom track under it flags.
    const under_thru = [_]router.Track{.{ .x1 = 2, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 1, .width = 0.127, .net = 1 }};
    const bt = router.RouteResult{ .tracks = &under_thru, .vias = &.{}, .routed = 1, .total = 1 };
    const v2 = try check(arena, placement, bt, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v2, .track_pad));

    // A track on the pad's OWN net may touch it — never flagged.
    const own = [_]router.Track{.{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 }};
    const ok = router.RouteResult{ .tracks = &own, .vias = &.{}, .routed = 1, .total = 1 };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, ok, 0.127), .track_pad));
}

// spec: placement/drc - a wide RF taper is checked as its exact butt-ended sweep, so a short launch land does not acquire a round cap behind its centre and falsely crowd the adjacent pad
test "exact RF taper does not grow a capsule behind a short launch pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Barracuda F4 pads 1/2 in the launch direction: the RF land is 0.55 mm
    // across but only 0.25 mm long, followed 0.25 mm behind by a GND land.
    // A 0.55 mm round-ended probe reaches 0.275 mm behind the RF pad centre and
    // reports a false 0.100 mm gap. The fabricated taper has a butt end at the
    // centre, so its real gap to pad 2 is 0.375 mm.
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.25, .h = 0.55 },
        .{ .number = "2", .x = -0.5, .y = 0, .w = 0.25, .h = 0.55 },
    };
    var parts = [_]optimizer.Part{.{
        .ref_des = "F4",
        .kind = .passive,
        .hw = 0.8,
        .hh = 0.9,
        .pads = &pads,
        .fallback = false,
        .x = 0,
        .y = 0,
    }};
    const rf_pin = [_]flat_netlist.FlatPin{.{ .ref_des = "F4", .pin = "1" }};
    const gnd_pin = [_]flat_netlist.FlatPin{.{ .ref_des = "F4", .pin = "2" }};
    const nets = [_]FlatNet{
        .{ .name = "LO1_DRIVE", .pins = &rf_pin },
        .{ .name = "GND", .pins = &gnd_pin },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    const samples = [_]RfSample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.55 },
        .{ .at = .{ 0.125, 0 }, .s_mm = 0.125, .curvature = 0, .width_mm = 0.55 },
        .{ .at = .{ 0.353, 0 }, .s_mm = 0.353, .curvature = 0, .width_mm = 0.19 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.19 },
    };
    const outcomes = [_]@import("rf_port_report.zig").Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const handle = [_]router.Track{.{
        .x1 = 0,
        .y1 = 0,
        .x2 = 1,
        .y2 = 0,
        .layer = 0,
        .width = 0.19,
        .net = 0,
    }};
    const exact = router.RouteResult{ .tracks = &handle, .vias = &.{}, .rf_port_outcomes = &outcomes, .routed = 1, .total = 1 };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, exact, 0.127), .track_pad));

    // Pin the old failure mode: the same first chord treated as a scalar-width
    // capsule really does report the synthetic 0.100 mm gap.
    const capsule = [_]router.Track{.{
        .x1 = 0,
        .y1 = 0,
        .x2 = 0.125,
        .y2 = 0,
        .layer = 0,
        .width = 0.55,
        .net = 0,
    }};
    const legacy = router.RouteResult{ .tracks = &capsule, .vias = &.{}, .routed = 1, .total = 1 };
    const old_findings = try check(arena, placement, legacy, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(old_findings, .track_pad));
    try testing.expectApproxEqAbs(@as(f64, 0.1), firstOfKind(old_findings, .track_pad).?.gap, 1e-9);
}

// spec: placement/drc - parent-rail copper may touch a structurally proven generated per-pin bypass pad, while dotted lookalike nets remain foreign
test "parent rail copper shares clearance identity only with proven bypass stubs" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    const hub_pads = [_]G.Pad{.{ .number = "5", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const cap_pads = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "core/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "core/C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &cap_pads, .fallback = false, .x = 4, .y = 0 },
    };
    const stub_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "core/U1", .pin = "5" },
        .{ .ref_des = "core/C1", .pin = "1" },
    };
    const nets = [_]FlatNet{
        .{ .name = "core/VDD", .pins = &.{} },
        .{ .name = "core/VDD.U1.5", .pins = &stub_pins },
        .{ .name = "SENSOR.DATA.1", .pins = &.{} },
    };
    const loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .cap_gnd = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .hub_pwr = &.{},
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
        .hub_gnd = &.{},
        .pwr_net = 1,
        .explicit_pin = "5",
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1,
        .generated = false,
    };

    const parent = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 }};
    const parent_route = router.RouteResult{ .tracks = &parent, .vias = &.{}, .routed = 1, .total = 1 };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, parent_route, 0.127), .track_pad));

    const dotted = [_]router.Track{.{ .x1 = 3, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.127, .net = 2 }};
    const dotted_route = router.RouteResult{ .tracks = &dotted, .vias = &.{}, .routed = 1, .total = 1 };
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, placement, dotted_route, 0.127), .track_pad));
}

// spec: placement/drc - A copper-clearance DRC violation names both nets it is between, and a pad party names its part and pad number
test "check names the nets and the pad behind a track-to-pad clash" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // U7 pad "12" on VDD3V3, with a GND track drawn straight across it.
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "12", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U7", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U7", .pin = "12" }};
    const nets = [_]FlatNet{ .{ .name = "VDD3V3", .pins = &pins }, .{ .name = "GND", .pins = &.{} } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -5,
        .maxx = 5,
        .maxy = 5,
        .generated = true,
    };
    const across = [_]router.Track{.{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.127, .net = 1 }};
    const routed = router.RouteResult{ .tracks = &across, .vias = &.{}, .routed = 1, .total = 1 };

    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .track_pad));
    const hit = firstOfKind(v, .track_pad).?;
    // A = the track's net; B = the pad, named down to its part + pad number.
    try testing.expectEqual(@as(i32, 1), hit.who.net_a); // GND
    try testing.expectEqual(@as(i32, 0), hit.who.net_b); // VDD3V3
    try testing.expectEqual(@as(i32, 0), hit.who.part_b); // parts[0] = U7
    try testing.expectEqualStrings("12", hit.who.pad_b);
    // The track side has no pad — a party it cannot name stays blank.
    try testing.expectEqual(@as(i32, -1), hit.who.part_a);
    try testing.expectEqualStrings("", hit.who.pad_a);
}

// spec: placement/drc - inner signal layers get the same same-layer checks; through pads clash on every inner layer
test "check is layer-generalized across inner signal layers" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{};
    const placement = optimizer.Placement{
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
    };
    const w = 0.127;

    // Two INNER tracks (layer 2) crossing between nets — flagged like any
    // same-layer crossing.
    const inner_cross = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 2, .layer = 2, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = 2, .x2 = 2, .y2 = 0, .layer = 2, .width = w, .net = 1 },
    };
    const crossed = router.RouteResult{ .tracks = &inner_cross, .vias = &.{}, .routed = 2, .total = 2 };
    const v1 = try check(arena, placement, crossed, w);
    try testing.expectEqual(@as(usize, 1), countKind(v1, .track_track));

    // The same geometry split across two DIFFERENT inner layers never clashes.
    const inner_stacked = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 2, .layer = 2, .width = w, .net = 0 },
        .{ .x1 = 0, .y1 = 2, .x2 = 2, .y2 = 0, .layer = 3, .width = w, .net = 1 },
    };
    const layered = router.RouteResult{ .tracks = &inner_stacked, .vias = &.{}, .routed = 2, .total = 2 };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, layered, w), .track_track));

    // A through-hole pad's barrel clashes with an inner-layer track too.
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};
    var thru_parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 5, .y = 5 },
    };
    const jp = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const tnets = [_]FlatNet{ .{ .name = "THRU", .pins = &jp }, .{ .name = "SIG", .pins = &.{} } };
    var thru_pl = placement;
    thru_pl.parts = &thru_parts;
    thru_pl.nets = &tnets;
    const under = [_]router.Track{.{ .x1 = 4, .y1 = 5, .x2 = 6, .y2 = 5, .layer = 2, .width = w, .net = 1 }};
    const bt = router.RouteResult{ .tracks = &under, .vias = &.{}, .routed = 1, .total = 1 };
    const v2 = try check(arena, thru_pl, bt, w);
    try testing.expectEqual(@as(usize, 1), countKind(v2, .track_pad));
}

// spec: placement/drc - SMD pads on opposite board faces may overlap in 2D; sharing a face or a through barrel still clashes
test "check pad-to-pad is layer-aware across board faces" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const smd = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const thru = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};

    // Same spot, opposite faces, both SMD: no copper shares a layer — clean.
    // (The parts sit far enough apart in courtyard terms? No — same spot, but
    // courtyards on opposite sides never clash either.)
    var mirror = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &smd, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &smd, .fallback = false, .x = 0, .y = 0, .side = .bottom },
    };
    try testing.expectEqual(@as(usize, 0), (try check(arena, partsOnly(&mirror), routed, 0.127)).len);

    // Same face: flags as before.
    var same_face = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &smd, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &smd, .fallback = false, .x = 0.3, .y = 3, .side = .bottom },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &smd, .fallback = false, .x = 0.3, .y = 3.2, .side = .bottom },
    };
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, partsOnly(&same_face), routed, 0.127), .pad_pad));

    // A through pad reaches every layer, so it clashes with a bottom SMD pad.
    var thru_pair = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &thru, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &smd, .fallback = false, .x = 0.3, .y = 0, .side = .bottom },
    };
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, partsOnly(&thru_pair), routed, 0.127), .pad_pad));
}

/// A bare `Placement` around `parts` with default rules — the common shell for
/// the courtyard/drill tests, which need no nets or routed copper.
fn partsOnly(parts: []optimizer.Part) optimizer.Placement {
    return .{
        .parts = parts,
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
}

/// Count the violations of one kind — the drill/courtyard tests share layouts
/// that could in principle trip more than the check under test. Public so
/// other modules' tests (e.g. the router's escape-stub test) can isolate the
/// copper-clearance kinds from an unrelated courtyard finding.
pub fn countKind(v: []const Violation, k: Kind) usize {
    var n: usize = 0;
    for (v) |x| {
        if (x.kind == k) n += 1;
    }
    return n;
}

/// The first violation of kind `k`, or null — lets a test assert a field on a
/// specific finding without an `if` in the test body.
fn firstOfKind(v: []const Violation, k: Kind) ?Violation {
    for (v) |x| {
        if (x.kind == k) return x;
    }
    return null;
}

// spec: placement/drc - flags two placed parts whose courtyards overlap, but not disjoint or opposite-side ones
test "check flags overlapping courtyards only on the same side" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    // Two 2×2 mm courtyards centred 1 mm apart interpenetrate by 1 mm.
    var overlap = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 1, .y = 0 },
    };
    const v1 = try check(arena, partsOnly(&overlap), routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v1, .courtyard));
    // The one courtyard violation records the interpenetration as a negative
    // gap (the check only appends when depth > 0, so gap < 0 by construction).
    try testing.expect(firstOfKind(v1, .courtyard).?.gap < 0);

    // Exact edge contact is legal: the courtyards share x=1 but have no
    // positive-area interpenetration.
    overlap[1].x = 2;
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&overlap), routed, 0.127), .courtyard));

    // Slide U2 to 2.5 mm — the 2×2 boxes now sit 0.5 mm apart (edge-to-edge),
    // so they don't overlap and nothing flags.
    var apart = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 2.5, .y = 0 },
    };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&apart), routed, 0.127), .courtyard));

    // Same interpenetrating pair but on OPPOSITE board sides never clashes —
    // their courtyards live on different faces.
    var two_sided = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 0, .y = 0, .side = .top },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 1, .y = 0, .side = .bottom },
    };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&two_sided), routed, 0.127), .courtyard));
}

// spec: placement/drc - the courtyard clash measures both parts' rotated keep-out rectangles, so parts clear on the diagonal do not read as overlapping
test "check judges a courtyard clash on the rotated rectangles, not their boxes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    // Two 4 × 1 mm courtyards lying end to end along the 45-degree diagonal —
    // the pose a fanned-out connector row sits in. Their centres are 4.5 mm
    // apart, so 0.5 mm of clear board separates them.
    const half = @sqrt(0.5);
    var pair = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 0, .y = 0, .rot = 45 },
        .{ .ref_des = "J2", .kind = .hub, .hw = 2, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 4.5 * half, .y = 4.5 * half, .rot = 45 },
    };
    // Their BOXES do overlap — 3.536 mm square each, centres 3.182 mm apart —
    // so the old box rule called this a clash.
    try testing.expect(rectOverlap(
        optimizer.worldCourtyard(&pair[0]),
        optimizer.worldCourtyard(&pair[1]),
    ).depth > 0.35);
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&pair), routed, 0.127), .courtyard));

    // Slide the second in to 3 mm and they interpenetrate by a real 1 mm, which
    // is the depth reported — the box rule would have said 1.414 mm.
    pair[1].x = 3 * half;
    pair[1].y = 3 * half;
    const v = try check(arena, partsOnly(&pair), routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .courtyard));
    const hit = firstOfKind(v, .courtyard).?;
    try testing.expectApproxEqAbs(@as(f64, -1), hit.gap, 1e-9);
    // The marker lands in the shared region, not between the two centres.
    try testing.expectApproxEqAbs(1.5 * half, hit.x, 1e-9);
    try testing.expectApproxEqAbs(1.5 * half, hit.y, 1e-9);
}

// spec: placement/drc - the component-edge check measures the courtyard's own corners, so a chamfer clears a rotated part its bounding box would flag
test "component-edge clearance reads the rotated courtyard's own corners" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    // A 10 mm board with its bottom-left corner chamfered off along x + y = 3,
    // and one 4 × 1 mm part turned 45° at the centre — its long axis PARALLEL
    // to the cut, which is exactly how a part is oriented to clear a chamfer.
    const poly = [_][2]f64{ .{ 3, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 3 } };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .rot = 45 },
    };
    var placement = partsOnly(&parts);
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 };
    placement.board_poly = &poly;
    placement.rules.design.edge.component = 2.5;

    // Its box's inner corner is a point the part does not occupy, and it sits
    // 2.45 mm off the chamfer — inside the authored 2.5 mm body margin.
    const box = optimizer.worldCourtyard(&parts[0]);
    try testing.expect(boardInset(placement.board_rect.?, placement.board_poly, box.minx, box.miny) < 2.5);
    // Every corner the part HAS clears it, so nothing is flagged.
    for (pad_shape.worldCourtyardCorners(parts[0])) |corner| {
        try testing.expect(boardInset(placement.board_rect.?, placement.board_poly, corner[0], corner[1]) > 2.5);
    }
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, routed, 0.127), .component_edge));

    // Pushed into the chamfer, the finding returns and is marked at a corner
    // the part really has.
    parts[0].x = 4;
    parts[0].y = 4;
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .component_edge));
    const hit = firstOfKind(v, .component_edge).?;
    try testing.expectApproxEqAbs(@as(f64, 0), cornerGap(parts[0], hit.x, hit.y), 1e-9);
}

/// Distance from (x, y) to the nearest corner the part actually has.
fn cornerGap(part: optimizer.Part, x: f64, y: f64) f64 {
    var nearest = std.math.inf(f64);
    for (pad_shape.worldCourtyardCorners(part)) |corner| {
        nearest = @min(nearest, std.math.hypot(x - corner[0], y - corner[1]));
    }
    return nearest;
}

/// A deterministic scatter generator for the scale tests — a plain LCG, so the
/// same board is judged on every machine and every run.
fn scatter(state: *u64, span: u64) f64 {
    state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
    return @as(f64, @floatFromInt((state.* >> 33) % span)) / 100.0;
}

/// Barrels dense enough that one box spans several grid cells and many pairs
/// share more than one — the case a sort-free dedupe would double-report and a
/// badly sized grid would drop.
fn scatterVias(vias: []router.Via, state: *u64) void {
    for (vias, 0..) |*v, i| {
        v.* = .{ .x = scatter(state, 1200), .y = scatter(state, 1200), .dia = 0.6, .drill = 0.3, .net = @intCast(i % 4) };
    }
}

/// The all-pairs hole↔hole answer the grid-culled sweep must reproduce exactly.
fn bruteHolePairs(vias: []const router.Via, rules: optimizer.DesignRules) usize {
    var n: usize = 0;
    for (vias, 0..) |a, i| {
        for (vias[i + 1 ..]) |b| {
            const ha = Hole{ .x = a.x, .y = a.y, .drill = a.drill, .net = a.net };
            const hb = Hole{ .x = b.x, .y = b.y, .drill = b.drill, .net = b.net };
            if (holePairViolation(rules, ha, hb) != null) n += 1;
        }
    }
    return n;
}

/// Overlapping courtyards on both faces, scattered the same deterministic way.
fn scatterParts(parts: []optimizer.Part, state: *u64) void {
    for (parts, 0..) |*p, i| {
        p.* = .{
            .ref_des = "U1",
            .kind = .hub,
            .hw = 0.6,
            .hh = 0.6,
            .pads = &.{},
            .fallback = false,
            .x = scatter(state, 800),
            .y = scatter(state, 800),
            .side = if (i % 3 == 0) .bottom else .top,
        };
    }
}

/// The all-pairs courtyard answer the grid-culled sweep must reproduce exactly.
fn bruteCourtyardPairs(parts: []const optimizer.Part) usize {
    var n: usize = 0;
    for (parts, 0..) |a, i| {
        const ca = optimizer.worldCourtyard(&a);
        if (ca.w <= 0 or ca.h <= 0) continue;
        for (parts[i + 1 ..]) |b| {
            if (a.side != b.side) continue;
            const cb = optimizer.worldCourtyard(&b);
            if (cb.w <= 0 or cb.h <= 0) continue;
            if (rectOverlap(ca, cb).depth <= eps) continue;
            const ov = pose_math.obbPenetration(
                pad_shape.worldCourtyardCorners(a),
                pad_shape.worldCourtyardCorners(b),
            ) orelse continue;
            if (ov.depth > eps) n += 1;
        }
    }
    return n;
}

// spec: placement/drc - the grid-culled hole-to-hole and courtyard sweeps report exactly the brute all-pairs findings
test "grid-culled drill and courtyard sweeps agree with brute force at scale" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var seed: u64 = 0x9E3779B97F4A7C15;

    var vias: [240]router.Via = undefined;
    scatterVias(&vias, &seed);
    const brute = bruteHolePairs(&vias, .{});
    try testing.expect(brute > 0);
    var no_parts = [_]optimizer.Part{};
    const drilled = try check(arena, partsOnly(&no_parts), .{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 }, 0.127);
    try testing.expectEqual(brute, countKind(drilled, .hole_hole));

    // The same question for courtyards: boxes that overlap always share a cell,
    // and the rotated-rectangle verdict is unchanged by the culling.
    var parts: [80]optimizer.Part = undefined;
    scatterParts(&parts, &seed);
    const court_brute = bruteCourtyardPairs(&parts);
    try testing.expect(court_brute > 0);
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    try testing.expectEqual(court_brute, countKind(try check(arena, partsOnly(&parts), routed, 0.127), .courtyard));
}

// spec: placement/drc - flags two drilled holes whose walls sit closer than the hole-to-hole rule
test "check flags hole-to-hole clearance and passes well-spaced holes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // Two through-hole pads (0.4 mm drill ⇒ 0.2 mm radius each) whose centres
    // are 0.5 mm apart ⇒ 0.1 mm wall-to-wall, under the 0.25 mm default rule.
    const pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const v = try check(arena, partsOnly(&parts), routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .hole_hole));

    // Space them 1 mm apart ⇒ 0.6 mm wall-to-wall, clear of the rule.
    const far = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
        .{ .number = "2", .x = 1.0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
    };
    var far_parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1.5, .hh = 1, .pads = &far, .fallback = false, .x = 0, .y = 0 },
    };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&far_parts), routed, 0.127), .hole_hole));
}

// spec: placement/drc - flags a drilled hole below the minimum drill diameter (pads and vias); SMD pads exempt
test "check flags sub-minimum drills" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // One SMD pad (no drill — exempt), one drilled pad at 0.15 mm (under the
    // 0.2 mm default), well away from each other so hole-to-hole stays clean.
    const pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "2", .x = 5, .y = 0, .w = 0.5, .h = 0.5, .thru = true, .drill = 0.15 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 3, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    // A via drilled at 0.1 mm (under) and one at 0.3 mm (over); legacy via has
    // no drill and is exempt.
    const vias = [_]router.Via{
        .{ .x = 0, .y = 5, .dia = 0.4, .drill = 0.1, .net = 0 },
        .{ .x = 5, .y = 5, .dia = 0.6, .drill = 0.3, .net = 0 },
        .{ .x = 9, .y = 5, .dia = 0.4, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };
    const v = try check(arena, partsOnly(&parts), routed, 0.127);
    // The 0.15 mm pad + the 0.1 mm via = 2 min-drill violations; the SMD pad,
    // the 0.3 mm via, and the drill-less via are all exempt.
    try testing.expectEqual(@as(usize, 2), countKind(v, .min_drill));
}

// spec: placement/drc - board-level design rules resolve to the documented toolchain defaults when no form is authored
test "check default rules equal the documented defaults" {
    // The no-form `DesignRules{}` must reproduce every documented built-in
    // fabrication floor, including the 0.1 mm minimum solder-mask web.
    const d = optimizer.DesignRules{};
    try testing.expectEqual(@as(f64, 0.1), d.min_annular);
    try testing.expectEqual(@as(f64, 0.2), d.min_drill);
    try testing.expectEqual(@as(f64, 0.25), d.hole_to_hole);
    try testing.expectEqual(@as(f64, 0.1), d.mask.web);
    try testing.expectEqual(@as(f64, 0.1), d.min_width);
    try testing.expectEqual(@as(f64, 0.05), d.mask.margin);
    try testing.expectEqual(@as(f64, 0.3), d.pour_clearance);
    // copper_edge unset ⇒ the DRC edge clearance falls back to the plain
    // copper clearance (the old board_edge behaviour) and the Gerber pour
    // pullback falls back to the fab-safe 0.3 mm.
    try testing.expectEqual(@as(f64, 0.127), d.edgeClearance());
    try testing.expectEqual(@as(f64, 0.3), d.pourEdge());
}

// spec: placement/drc - a (design-rules …) value overrides the matching default in the DRC
test "check honours a design-rules override" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // Two drilled pads 0.5 mm apart ⇒ 0.1 mm wall-to-wall. At the 0.25 mm
    // default this flags; loosening the design's hole-to-hole rule to 0.05 mm
    // makes the same layout legal.
    const pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.4 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    var loose = partsOnly(&parts);
    loose.rules = .{ .design = .{ .hole_to_hole = 0.05 } };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, loose, routed, 0.127), .hole_hole));

    // The default (no override) still flags it.
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, partsOnly(&parts), routed, 0.127), .hole_hole));
}

// spec: placement/drc - a wider board clearance flags copper the default rule allowed
test "check honours the design's base copper clearance rule" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two parallel same-layer tracks on different nets, 0.2 mm edge-to-edge apart
    // (centres 0.327 mm, width 0.127). At the 0.127 mm default they clear; a
    // (design-rules (clearance 0.3)) — which reaches the DRC as the base rule —
    // must flag them because 0.2 mm < 0.3 mm, and report the 0.3 mm rule.
    var parts = [_]optimizer.Part{};
    const placement = partsOnly(&parts);
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 0, .y1 = 0.327, .x2 = 5, .y2 = 0.327, .layer = 0, .width = 0.127, .net = 1 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 };

    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, routed, 0.127), .track_track));
    const v = try check(arena, placement, routed, 0.3);
    try testing.expectEqual(@as(usize, 1), countKind(v, .track_track));
    try testing.expectEqual(@as(f64, 0.3), firstOfKind(v, .track_track).?.clearance);
}

// spec: placement/drc - a net-class clearance override is enforced against that net's neighbours server-side
test "check enforces a per-net class clearance from placement.rules.net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Same two tracks 0.2 mm apart on nets 0 and 1, but the board base stays at
    // the 0.127 mm default (so the pair is legal by the board rule). A per-net
    // (net-class (clearance 0.3)) on net 1 — carried on placement.rules.net — must
    // flag the pair against net 1's wider rule: proof the authoritative server DRC
    // reads per-net clearances, not just the browser preview. The reported
    // clearance is the resolved 0.3 mm (max of the two nets and the base).
    var parts = [_]optimizer.Part{};
    var placement = partsOnly(&parts);
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 0, .y1 = 0.327, .x2 = 5, .y2 = 0.327, .layer = 0, .width = 0.127, .net = 1 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 };

    // No class ⇒ legal at the 0.127 mm base (unruled nets keep the board default).
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, routed, 0.127), .track_track));

    // Net 1 asks for 0.3 mm clearance; the base is unchanged at 0.127 mm.
    const net_rules = [_]optimizer.NetRule{ .{}, .{ .clearance = 0.3 } };
    placement.rules.net = &net_rules;
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .track_track));
    try testing.expectEqual(@as(f64, 0.3), firstOfKind(v, .track_track).?.clearance);
}

// spec: placement/drc - RF bend findings are reconstructed from submitted or saved copper, not only transient router metadata
// spec: placement/drc - a successful swept RF path suppresses only its internal tessellation vertices, not unrelated same-net corners
test "check finds the saved LO1_DRIVE hard junction when RouteResult bend metadata is absent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]FlatNet{.{ .name = "LO1_DRIVE", .pins = &.{} }};
    const net_rules = [_]optimizer.NetRule{.{
        .width = 0.3124,
        .rf = .{ .max_freq_hz = 12e9 },
    }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .rules = .{ .net = &net_rules },
    };
    // The first three persisted segments from Barracuda's rf-rounding-v1
    // LO1_DRIVE run. The first junction turns about 82 degrees with no tangent
    // arc; the following short chord begins the visible rounded section.
    const tracks = [_]router.Track{
        .{
            .x1 = 156.0,
            .y1 = 105.35,
            .x2 = 157.05575853087134,
            .y2 = 105.19867467474472,
            .layer = 0,
            .width = 0.3124,
            .net = 0,
        },
        .{
            .x1 = 157.05575853087134,
            .y1 = 105.19867467474472,
            .x2 = 157.05575853087134,
            .y2 = 104.39269467045713,
            .layer = 0,
            .width = 0.3124,
            .net = 0,
        },
        .{
            .x1 = 157.05575853087134,
            .y1 = 104.39269467045713,
            .x2 = 157.0874347519041,
            .y2 = 104.15208988424887,
            .layer = 0,
            .width = 0.3124,
            .net = 0,
        },
    };
    const raw = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    const found = try check(arena, placement, raw, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(found, .sharp_bend));
    const finding = firstOfKind(found, .sharp_bend) orelse return error.ExpectedSharpBend;
    try testing.expectApproxEqAbs(157.05575853087134, finding.x, 1e-9);
    try testing.expectApproxEqAbs(105.19867467474472, finding.y, 1e-9);
    try testing.expectApproxEqAbs(0.9372, finding.clearance, 1e-12);
    try testing.expectEqual(@as(?board_layers.SignalIndex, .top), finding.layer);

    // A fresh router result can still carry the same finding. The actual-copper
    // audit supplements that metadata without duplicating its DRC marker.
    const metadata = [_]router.SharpBend{.{
        .x = 157.05575853087134,
        .y = 105.19867467474472,
        .layer = 0,
        .net = 0,
        .radius = 0,
        .required = 0.9372,
    }};
    var fresh = raw;
    fresh.sharp_bends = &metadata;
    const deduped = try check(arena, placement, fresh, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(deduped, .sharp_bend));

    // A successful port-frame outcome describes the smooth curve underlying
    // its chord tessellation, so the same geometric vertex is not a warning.
    const smooth_samples = [_]@import("rf_path_solver.zig").Sample{
        .{ .at = .{ tracks[0].x1, tracks[0].y1 }, .s_mm = 0, .curvature = 0, .width_mm = tracks[0].width },
        .{ .at = .{ tracks[0].x2, tracks[0].y2 }, .s_mm = 1, .curvature = 0, .width_mm = tracks[0].width },
        .{ .at = .{ tracks[1].x2, tracks[1].y2 }, .s_mm = 2, .curvature = 0, .width_mm = tracks[1].width },
        .{ .at = .{ tracks[2].x2, tracks[2].y2 }, .s_mm = 3, .curvature = 0, .width_mm = tracks[2].width },
    };
    const outcomes = [_]@import("rf_port_report.zig").Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = smooth_samples.len, .samples = &smooth_samples },
    }};
    var synthesized = raw;
    synthesized.rf_port_outcomes = &outcomes;
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, synthesized, 0.127), .sharp_bend));

    // The same net may have an unrelated hard corner outside that swept path.
    // Its geometry receives no path-wide exemption.
    const mixed_tracks = [_]router.Track{
        tracks[0],
        tracks[1],
        tracks[2],
        .{ .x1 = 10, .y1 = 0, .x2 = 11, .y2 = 0, .layer = 0, .width = 0.3124, .net = 0 },
        .{ .x1 = 11, .y1 = 0, .x2 = 11, .y2 = 1, .layer = 0, .width = 0.3124, .net = 0 },
    };
    synthesized.tracks = &mixed_tracks;
    const precise = try check(arena, placement, synthesized, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(precise, .sharp_bend));
    try testing.expectApproxEqAbs(@as(f64, 11), firstOfKind(precise, .sharp_bend).?.x, 1e-9);
}

// spec: placement/drc - an oval slot's hole-to-hole clearance is measured end-to-end (capsule), not at its centre
test "check measures an oval slot as a capsule for hole-to-hole" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A thru slot: tool 0.4, running along x with arc centres at ±0.5. A round
    // via sits 1.0 mm from the slot CENTRE but only 0.5 mm from its near end —
    // the capsule (end-to-end) gap is what the hole-to-hole check must use.
    const pads = [_]@import("geometry.zig").Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1.4, .h = 0.6, .thru = true, .drill = 0.4, .slot_half = .{ 0.5, 0 } },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "SLOT", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    // Wall gap = 0.5 (to near end) − 0.2 (slot r) − 0.2 (via r) = 0.1 < the
    // 0.25 hole-to-hole rule → flags; the 1.0 mm centre distance would clear it.
    const vias = [_]router.Via{.{ .x = 1.0, .y = 0, .dia = 0.4, .drill = 0.4, .net = 9 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .hole_hole));
    try testing.expectApproxEqAbs(@as(f64, 0.1), firstOfKind(v, .hole_hole).?.gap, 1e-9);
}

// spec: placement/drc - flags silkscreen that crosses a foreign pad's mask opening, as a warning
test "check flags silkscreen over a foreign pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    // U1 draws a silk line that runs across R1's pad (a 0.6×0.6 pad at x=2).
    // Own-footprint silk is exempt, so only the cross-part crossing counts.
    const r_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const over = [_]G.SilkLine{.{ .x1 = 1.5, .y1 = 0, .x2 = 2.5, .y2 = 0 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 0, .y = 0, .features = .{ .silk_lines = &over } },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &r_pad, .fallback = false, .x = 2, .y = 0 },
    };
    const v = try check(arena, partsOnly(&parts), routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .silk_over_pad));
    try testing.expectEqual(Severity.warn, firstOfKind(v, .silk_over_pad).?.severity);

    // Move the silk line 5 mm up, clear of the pad ⇒ no finding.
    const clear = [_]G.SilkLine{.{ .x1 = 1.5, .y1 = 5, .x2 = 2.5, .y2 = 5 }};
    var ok_parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 0, .y = 0, .features = .{ .silk_lines = &clear } },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &r_pad, .fallback = false, .x = 2, .y = 0 },
    };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&ok_parts), routed, 0.127), .silk_over_pad));
}

// spec: placement/drc - silk-over-pad checks authored footprint silk rather than inventing reference-designator artwork
test "check ignores a bare part with ref-des but no authored silk" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    // U1 carries metadata but no footprint silk. Nearby foreign pads cannot
    // create a finding because neither DRC nor fabrication invents a label.
    const ring = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = -1.0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 0, .y = 1.0, .w = 0.6, .h = 0.6 },
        .{ .number = "3", .x = 1.3, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "4", .x = -1.3, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var bp = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.3, .hh = 0.3, .pads = &.{}, .fallback = false },
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.2, .hh = 0.2, .pads = &ring, .fallback = false },
    };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, partsOnly(&bp), routed, 0.127), .silk_over_pad));
}
// spec: placement/drc - flags a plated through-hole pad whose annular ring is under the minimum; NPTH pads exempt
test "check flags a thin pad annular ring" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    // Pad 1: a COMPONENT through-hole lead, 0.9 mm copper over a 0.8 mm drill ⇒
    // 0.05 mm ring (< 0.1 floor) ⇒ flags. Pad 2: 1.4 mm over 0.5 mm ⇒ 0.45 mm
    // ring (healthy). Pad 3: NPTH mounting hole ⇒ exempt. Pad 4: a via-scale
    // stitch (0.5 mm ≤ 0.65 mm) with an even thinner ring ⇒ exempt (not a
    // component lead). Pad 5: an oval slot ⇒ exempt (axis-dependent annular).
    // Spaced 5 mm apart so no hole-to-hole.
    const pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.9, .thru = true, .drill = 0.8 },
        .{ .number = "2", .x = 5, .y = 0, .w = 1.4, .h = 1.4, .thru = true, .drill = 0.5 },
        .{ .number = "3", .x = 10, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .npth = true, .drill = 0.5 },
        .{ .number = "4", .x = 15, .y = 0, .w = 0.5, .h = 0.5, .thru = true, .drill = 0.45 },
        .{ .number = "5", .x = 20, .y = 0, .w = 1.0, .h = 1.6, .thru = true, .drill = 1.0, .slot_half = .{ 0, 0.25 } },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 12, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const v = try check(arena, partsOnly(&parts), routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .pad_annular));
    // It's a fab error (blocks the gate).
    try testing.expectEqual(Severity.err, firstOfKind(v, .pad_annular).?.severity);
}

// spec: placement/drc - flags a track narrower than its net-class width, else the board minimum, as an error
test "check flags sub-width tracks against class and board rules" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Net 0 carries a (net-class (width 0.3)) rule; net -1 (unruled) falls back
    // to the 0.1 mm board min-width default.
    const net_rules = [_]optimizer.NetRule{.{ .width = 0.3 }};
    const nets = [_]FlatNet{.{ .name = "PWR", .pins = &.{} }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -5,
        .maxx = 5,
        .maxy = 5,
        .generated = true,
        .rules = .{ .net = &net_rules },
    };
    // A: net 0 at 0.2 mm < its 0.3 mm class ⇒ flag. B: net 0 at 0.35 ⇒ clean.
    // C: unruled at 0.08 mm < the 0.1 mm min-width ⇒ flag. D: unruled at 0.12
    // ⇒ clean. A width-less (0) synthetic track is skipped.
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 1, .x2 = 1, .y2 = 1, .layer = 0, .width = 0.35, .net = 0 },
        .{ .x1 = 0, .y1 = 2, .x2 = 1, .y2 = 2, .layer = 0, .width = 0.08, .net = -1 },
        .{ .x1 = 0, .y1 = 3, .x2 = 1, .y2 = 3, .layer = 0, .width = 0.12, .net = -1 },
        .{ .x1 = 0, .y1 = 4, .x2 = 1, .y2 = 4, .layer = 0, .width = 0, .net = -1 },
    };
    const rr = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 0, .total = 0 };
    const v = try check(arena, placement, rr, 0.127);
    try testing.expectEqual(@as(usize, 2), countKind(v, .track_width));
    try testing.expectEqual(Severity.err, firstOfKind(v, .track_width).?.severity);

    // Widen everything past both rules ⇒ no width violations.
    const wide = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.4, .net = 0 },
        .{ .x1 = 0, .y1 = 2, .x2 = 1, .y2 = 2, .layer = 0, .width = 0.15, .net = -1 },
    };
    const wr = router.RouteResult{ .tracks = &wide, .vias = &.{}, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, wr, 0.127), .track_width));
}

// spec: placement/drc - a solved local-current requirement replaces the whole-net class width for that power track, but never permits copper below its own IPC-2221 requirement
test "track width accepts a solved narrow power branch but enforces its local requirement" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const net_rules = [_]optimizer.NetRule{.{ .width = 0.3048, .pad_neck = .{ .power_branch_width = 0.1524 } }};
    const nets = [_]FlatNet{.{ .name = "V3P3", .pins = &.{} }};
    var placement = partsOnly(&.{});
    placement.nets = &nets;
    placement.rules.net = &net_rules;
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.30, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = 1, .layer = 0, .width = 0.1524, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = -1, .layer = 0, .width = 0.13, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    const local = [_]?f64{ 0.2727, 0.10, 0.10 };
    var violations: std.ArrayList(Violation) = .empty;
    try checkTrackWidth(arena, &violations, .{
        .placement = placement,
        .routed = routed,
        .tracks = &tracks,
        .min_width = 0.127,
        .local_power_widths = &local,
    });
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectApproxEqAbs(@as(f64, 0.13), violations.items[0].gap, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.1524), violations.items[0].clearance, 1e-12);
}

// spec: placement/power-routing - an adaptive rail reports one warning at its worst electrical shortfall while the fabrication minimum remains a hard error
test "adaptive power width shortfall is one non-blocking worst-neck finding" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]FlatNet{.{ .name = "VDD", .pins = &.{} }};
    const net_rules = [_]optimizer.NetRule{.{ .width = 0.8 }};
    const foils = [_]@import("impedance.zig").Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.035 },
    };
    const rails = [_]@import("../eval/power_budget.zig").Rail{.{
        .net = "VDD",
        .load_max_a = 1.2,
        .any_max_load = true,
        .status = .no_source,
    }};
    var placement = partsOnly(&.{});
    placement.nets = &nets;
    placement.rules = .{
        .net = &net_rules,
        .plane_nets = &.{},
        .copper_layers = 2,
        .physical = .{ .stack = .{ .layers = 2, .foils = &foils }, .rails = &rails },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.4, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    var violations: std.ArrayList(Violation) = .empty;
    try checkTrackWidth(arena, &violations, .{
        .placement = placement,
        .routed = routed,
        .tracks = &tracks,
        .min_width = 0.127,
    });
    try testing.expectEqual(@as(usize, 1), violations.items.len);
    try testing.expectEqual(Kind.power_width, violations.items[0].kind);
    try testing.expectEqual(Severity.warn, violations.items[0].severity);
    try testing.expectApproxEqAbs(@as(f64, 0.2), violations.items[0].gap, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.8), violations.items[0].clearance, 1e-12);
}

// spec: placement/drc - reporting DRC reuses its exact cached plane, pour, and user-zone fills when solving local power-track current
test "reporting DRC accepts its prepared fabricated copper fills" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    var parts: [0]optimizer.Part = .{};
    const placement = partsOnly(&parts);
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const violations = try checkWithPreparedCopper(arena_inst.allocator(), placement, routed, 0.127, .{
        .topology_zones = &.{},
        .plane_fills = &.{},
        .zones = &.{},
        .zone_fills = &.{},
    });
    try testing.expectEqual(@as(usize, 0), violations.len);
}

// spec: placement/rf-port-frame-routing - a solver-proven one-width pad taper may narrow below the controlled line width, but thin copper away from the land still fails DRC
test "track width allows only the proven port-frame pad taper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const land = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.1 }};
    var parts = [_]optimizer.Part{.{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &land, .fallback = false, .x = 0, .y = 0 }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "RF", .pins = &pins }};
    const net_rules = [_]optimizer.NetRule{.{ .width = 0.2 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -5,
        .maxx = 5,
        .maxy = 5,
        .generated = true,
        .rules = .{ .net = &net_rules },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.15, .y2 = 0, .layer = 0, .width = 0.15, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.15, .net = 0 },
    };
    const samples = [_]RfSample{
        // The widest value occurs before a narrower duplicate. Normalization
        // must retain this first coordinate and carry 0.15 onto the real chord.
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.15 },
        .{ .at = .{ 0.5e-9, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 0.15, 0 }, .s_mm = 0.15, .curvature = 0, .width_mm = 0.1 },
    };
    var clean_cursor: usize = 0;
    const clean_first = nextCleanRfSample(&samples, &clean_cursor).?;
    try testing.expectEqual(@as(f64, 0), clean_first.at[0]);
    try testing.expectEqual(@as(f64, 0.15), clean_first.width_mm);
    try testing.expectEqual(@as(f64, 0.15), nextCleanRfSample(&samples, &clean_cursor).?.at[0]);
    try testing.expect(nextCleanRfSample(&samples, &clean_cursor) == null);
    const outcomes = [_]@import("rf_port_report.zig").Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples },
    }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 0, .total = 1, .rf_port_outcomes = &outcomes };
    const violations = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(violations, .track_width));
    try testing.expectApproxEqAbs(@as(f64, 1.5), firstOfKind(violations, .track_width).?.x, 1e-12);

    const coincident_samples = [_]RfSample{
        .{ .at = .{ 3, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.15 },
        .{ .at = .{ 3 + 0.5e-9, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
    };
    const coincident_outcomes = [_]@import("rf_port_report.zig").Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = coincident_samples.len, .samples = &coincident_samples },
    }};
    const coincident_track = router.Track{ .x1 = 3, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.15, .net = 0 };
    const coincident_routed = router.RouteResult{ .tracks = &.{coincident_track}, .vias = &.{}, .routed = 0, .total = 1, .rf_port_outcomes = &coincident_outcomes };
    try testing.expect(!portFramePadTaper(coincident_routed, coincident_track, 0.2));
}

// spec: placement/drc - existing copper violations are error-severity; only the hygiene checks are warnings
test "check severity: copper checks are errors, courtyard is a warning" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A via crowding a foreign pad (an error) plus two overlapping courtyards
    // (a warning) in one placement.
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false, .x = 1, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};

    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    const vias = [_]router.Via{.{ .x = 0.5, .y = 0, .dia = 0.6, .drill = 0.3, .net = 99 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };
    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(Severity.err, firstOfKind(v, .via_pad).?.severity);
    try testing.expectEqual(Severity.warn, firstOfKind(v, .courtyard).?.severity);
}

test "checkDrillRules measures oval-slot walls from the true ± endpoints" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Two oval slots: a from (−0.5,−2)→(0.5,2), b from (2,1)→(4,3), each a
    // 0.4 mm bore. Their capsule walls sit ~1.2977 mm apart; a loose 5 mm rule
    // reports the gap. Any sign flip on a slot endpoint moves an end and shifts
    // the reported gap, so pinning it exactly kills every `±shx/±shy` mutant.
    const pads = [_]PadBox{
        .{
            .x0 = -1,
            .y0 = -3,
            .x1 = 1,
            .y1 = 3,
            .net = -1,
            .part = 0,
            .drill = 0.4,
            .hx = 0,
            .hy = 0,
            .shx = 0.5,
            .shy = 2.0,
        },
        .{
            .x0 = 1,
            .y0 = 0,
            .x1 = 5,
            .y1 = 4,
            .net = -1,
            .part = 1,
            .drill = 0.4,
            .hx = 3,
            .hy = 2,
            .shx = 1.0,
            .shy = 1.0,
        },
    };
    var out: Viol = .empty;
    try checkDrillRules(arena, &out, &pads, &.{}, optimizer.DesignRules{ .hole_to_hole = 5.0 });
    try testing.expectEqual(@as(usize, 1), countKind(out.items, .hole_hole));
    try testing.expectApproxEqAbs(@as(f64, 1.2977493752543308), firstOfKind(out.items, .hole_hole).?.gap, 1e-6);
}

test "boxOverlap treats a sub-epsilon overlap on either axis as no overlap" {
    // x-overlap exactly EPS wide (y fully overlapping): touching within EPS ⇒ null.
    try testing.expect(boxOverlap(.{ 0, 0, 1e-6, 1 }, .{ 0, 0, 2, 1 }) == null);
    // y-overlap exactly EPS wide (x fully overlapping): likewise null.
    try testing.expect(boxOverlap(.{ 0, 0, 1, 1e-6 }, .{ 0, 0, 1, 2 }) == null);
    // A proper overlap returns the shared-region centre.
    const c = boxOverlap(.{ 0, 0, 2, 2 }, .{ 1, 1, 3, 3 }).?;
    try testing.expectApproxEqAbs(@as(f64, 1.5), c[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5), c[1], 1e-9);
}

test "grid cull: pad-to-pad flags exactly the sub-clearance cross-cell pairs" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // Four single-pad parts on a 0.45 mm lattice: 0.4 mm boxes leave 0.05 mm
    // orthogonal / 0.07 mm diagonal gaps (< the 0.127 mm rule) and STRADDLE the
    // ~0.5 mm grid cells, so the cull must reach neighbouring + diagonal cells.
    // Hand count of the 6 pairs: AB AD BC BD flag (4); AC and CD clear (0.5 mm).
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "A", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "B", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 0.45, .y = 0 },
        .{ .ref_des = "C", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 0.9, .y = 0 },
        .{ .ref_des = "D", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 0, .y = 0.45 },
    };
    const na = [_]flat_netlist.FlatPin{.{ .ref_des = "A", .pin = "1" }};
    const nb = [_]flat_netlist.FlatPin{.{ .ref_des = "B", .pin = "1" }};
    const nc = [_]flat_netlist.FlatPin{.{ .ref_des = "C", .pin = "1" }};
    const nd = [_]flat_netlist.FlatPin{.{ .ref_des = "D", .pin = "1" }};
    const nets = [_]FlatNet{
        .{ .name = "A", .pins = &na }, .{ .name = "B", .pins = &nb },
        .{ .name = "C", .pins = &nc }, .{ .name = "D", .pins = &nd },
    };
    var pl = partsOnly(&parts);
    pl.nets = &nets;
    const rr = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 4), countKind(try check(arena, pl, rr, 0.127), .pad_pad));
}

test "grid cull: a giant pad spanning many cells still clashes a via at its far edge" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // A 20 mm pad (net BIG) spans dozens of grid cells; a via (net V) sits 0.05 mm
    // off its far edge (gap 0.05 < clearance). The pad is inserted into every cell
    // it overlaps, so the via's query — in a cell far from the pad centre — still
    // surfaces it. A 2 mm control pad (net M) far away must NOT be flagged.
    const bigpad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 20.0, .h = 0.4 }};
    const mpad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 2.0, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "BIG", .kind = .hub, .hw = 10, .hh = 0.2, .pads = &bigpad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "M", .kind = .passive, .hw = 1, .hh = 0.2, .pads = &mpad, .fallback = false, .x = 50, .y = 50 },
    };
    const nbig = [_]flat_netlist.FlatPin{.{ .ref_des = "BIG", .pin = "1" }};
    const nets = [_]FlatNet{ .{ .name = "BIG", .pins = &nbig }, .{ .name = "M", .pins = &.{} } };
    var pl = partsOnly(&parts);
    pl.nets = &nets;
    // Pad box spans x −10..10; via edge (r 0.3) at 10.05 ⇒ gap 0.05.
    const vias = [_]router.Via{.{ .x = 10.35, .y = 0, .dia = 0.6, .net = 9 }};
    const rr = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, pl, rr, 0.127), .via_pad));
}

test "grid cull: via-to-via honours the exact clearance boundary and coincident vias" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // dia 0.4 ⇒ r 0.2, edge gap = centre distance − 0.4. #0–#1 sit at EXACTLY the
    // clearance (gap 0.127, not < clr−eps ⇒ clean); #2–#3 a hair closer ⇒ flag;
    // #4–#5 are coincident (same cell, gap −0.4 ⇒ flag). Rows are 5 mm apart.
    const vias = [_]router.Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .net = 0 },
        .{ .x = 0.527, .y = 0, .dia = 0.4, .net = 1 },
        .{ .x = 0, .y = 5, .dia = 0.4, .net = 2 },
        .{ .x = 0.526, .y = 5, .dia = 0.4, .net = 3 },
        .{ .x = 0, .y = 10, .dia = 0.4, .net = 4 },
        .{ .x = 0, .y = 10, .dia = 0.4, .net = 5 },
    };
    var parts = [_]optimizer.Part{};
    const pl = partsOnly(&parts);
    const rr = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 2), countKind(try check(arena, pl, rr, 0.127), .via_via));
}

// spec: placement/drc - a foreign via must clear the synthesized RF via antipad, not only ordinary copper clearance
test "via-to-via clearance includes the controlled-impedance antipad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{};
    const rules = [_]optimizer.NetRule{ .{ .rf = .{ .impedance = .{ .ohms = 50 } } }, .{} };
    var pl = partsOnly(&parts);
    pl.rules.net = &rules;
    pl.rules.physical.stack = .{ .layers = 4, .board_mm = 1.6 };
    const rf = router.Via{ .x = 0, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 };
    const anti = via_antipad.solve(pl.rules.physical.stack, 50, rf.dia, rf.drill, pl.rules.design.clearance).?;
    const centre = anti.antipad_dia_mm / 2 + 0.2;

    const crowded = [_]router.Via{ rf, .{ .x = centre - 0.001, .y = 0, .dia = 0.4, .drill = 0.2, .net = 1 } };
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, pl, .{ .tracks = &.{}, .vias = &crowded, .routed = 0, .total = 0 }, 0.127), .via_via));
    const exact = [_]router.Via{ rf, .{ .x = centre, .y = 0, .dia = 0.4, .drill = 0.2, .net = 1 } };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, pl, .{ .tracks = &.{}, .vias = &exact, .routed = 0, .total = 0 }, 0.127), .via_via));
}

// spec: placement/drc - flags a component land crowding the board edge, exempts a staged off-board part, and reports nothing without an outline
test "check flags a pad at the board edge and skips a staged part's pads" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    // One 0.6 mm land per part on a 10×10 mm board: U1 sits mid-board, U2's
    // land hangs 0.25 mm past the left cut line, U3 is parked 20 mm below the
    // board in the staging band.
    const one_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &one_pad, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &one_pad, .fallback = false, .x = 0.05, .y = 2 },
        .{ .ref_des = "U3", .kind = .hub, .hw = 1, .hh = 1, .pads = &one_pad, .fallback = false, .x = 5, .y = 25 },
    };
    var placement = partsOnly(&parts);
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 };

    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .board_edge));
    const hit = firstOfKind(v, .board_edge).?;
    try testing.expectEqual(@as(i32, 1), hit.who.part_a); // U2
    try testing.expectEqualStrings("1", hit.who.pad_a);
    try testing.expectApproxEqAbs(@as(f64, -0.25), hit.gap, 1e-9);
    try testing.expectEqual(@as(f64, 0.127), hit.clearance);

    // A design with NO outline has no cut line to measure against — the same
    // silence the track/via halves of this rule keep.
    placement.board_rect = null;
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, routed, 0.127), .board_edge));
}

// spec: placement/drc - component courtyards default to a 0.2 mm edge margin, honor an authored override, and exempt NPTH-only/staged parts
test "check enforces component-to-edge clearance" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const npth = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true, .npth = true, .drill = 1 }};
    var parts = [_]optimizer.Part{
        // Courtyard's left edge is exactly 0.2 mm from the cut: legal.
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 0.7, .y = 5 },
        // Right edge gap = 0.1 mm: one component-edge warning.
        .{ .ref_des = "U2", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 9.4, .y = 5 },
        // Mounting-hole courtyard touches the cut, but NPTH-only hardware has
        // no assembled body and is intentionally exempt.
        .{ .ref_des = "H1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &npth, .fallback = false, .x = 0.5, .y = 5 },
        // Wholly off-board solver staging is reported by fab-readiness, not
        // repeated as a component-edge finding.
        .{ .ref_des = "U3", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 20, .y = 20 },
    };
    var placement = partsOnly(&parts);
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 };

    const defaults = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(defaults, .component_edge));
    const hit = firstOfKind(defaults, .component_edge).?;
    try testing.expectEqual(@as(i32, 1), hit.who.part_a);
    try testing.expectEqual(@as(f64, 0.2), hit.clearance);
    try testing.expectEqual(Severity.warn, hit.severity);

    // A board-specific assembly process can state a wider rule.
    placement.rules.design.edge.component = 0.3;
    try testing.expectEqual(@as(usize, 2), countKind(try check(arena, placement, routed, 0.127), .component_edge));
}

// spec: placement/drc - component-edge clearance follows the exact rounded outline rather than its rectangular bounding box
test "component edge measures rounded outline" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &.{}, .fallback = false, .x = 1.6, .y = 1.6 },
    };
    var placement = partsOnly(&parts);
    const br = optimizer.BoardRect{ .minx = 0, .miny = 0, .w = 10, .h = 10 };
    placement.board_rect = br;
    placement.board_poly = try outline.roundedRectPoly(arena, br, 2);
    placement.rules.design.edge.component = 1.5;

    const hits = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(hits, .component_edge));
    try testing.expect(firstOfKind(hits, .component_edge).?.gap < 1.5);
}

// spec: placement/drc - a pad inside the board rectangle but in a concave notch is measured against the outline polygon
test "check flags a pad sitting in an outline notch" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    // 10×10 board with the corner at (6..10, 4..10) notched out (y-down). The
    // staging exemption is "wholly outside the RECTANGLE", so a part dropped in
    // the notch — inside the bbox, off the real board — is still measured.
    const l_poly = [_][2]f64{
        .{ 0, 0 }, .{ 10, 0 }, .{ 10, 4 }, .{ 6, 4 }, .{ 6, 10 }, .{ 0, 10 },
    };
    const one_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &one_pad, .fallback = false, .x = 3, .y = 5 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 1, .pads = &one_pad, .fallback = false, .x = 8, .y = 8 },
    };
    var placement = partsOnly(&parts);
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 };
    placement.board_poly = &l_poly;

    const v = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .board_edge));
    try testing.expectEqual(@as(i32, 1), firstOfKind(v, .board_edge).?.who.part_a); // U2
}

// spec: placement/drc - warns once when same-net trace capsules touch across separate explicit centreline components
test "check reports a robust crossing without an explicit centreline junction" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &.{} }};
    var placement = partsOnly(&.{});
    placement.nets = &nets;
    const tracks = [_]router.Track{
        .{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = -1, .x2 = 0, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
    };
    const found = try check(arena, placement, .{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 }, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(found, .implicit_junction));
    const join = firstOfKind(found, .implicit_junction).?;
    try testing.expectEqual(Severity.warn, join.severity);
    try testing.expectEqual(@as(i32, 0), join.who.net_a);
    try testing.expectEqual(@as(?board_layers.SignalIndex, .top), join.layer);
}

// spec: placement/drc - warns once per stored trace section whose deletion preserves all pad, live-via, and pour connectivity
test "check warns for a deletable dangling branch but not its pad-to-pad trunk" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    var placement = partsOnly(&parts);
    placement.nets = &nets;
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = 1.5, .layer = 0, .width = 0.2, .net = 0 },
    };
    const found = try check(arena, placement, .{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 }, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(found, .dangling_copper));
    try testing.expectEqual(Severity.warn, firstOfKind(found, .dangling_copper).?.severity);
    try testing.expectEqual(@as(usize, 0), countKind(found, .copper_stub));
}

// spec: placement/drc - swept RF paths remain one semantic topology object even when their overlapping physical profile is tessellated into many chords
test "check does not report successful RF path chords as removable copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 2, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "RF", .pins = &pins }};
    var placement = partsOnly(&parts);
    placement.nets = &nets;

    // Each compact editor section is shorter than the wide copper around it.
    // Judged independently, deleting any one chord appears harmless because
    // its neighbours' capsules still overlap.  The successful path outcome is
    // the authored object, though, and its sample sections are not individual
    // cleanup candidates or loose stubs.
    const tracks = [_]router.Track{
        .{ .x1 = 0.00, .y1 = 0, .x2 = 0.25, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 0.25, .y1 = 0, .x2 = 0.50, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 0.50, .y1 = 0, .x2 = 0.75, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 0.75, .y1 = 0, .x2 = 1.00, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 1.00, .y1 = 0, .x2 = 1.25, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 1.25, .y1 = 0, .x2 = 1.50, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 1.50, .y1 = 0, .x2 = 1.75, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        .{ .x1 = 1.75, .y1 = 0, .x2 = 2.00, .y2 = 0, .layer = 0, .width = 0.5, .net = 0 },
        // A real stored branch follows all eight path-owned sections.  It must
        // retain saved index 8 after those sections are replaced by private
        // chords in the physical topology view.
        .{ .x1 = 1.00, .y1 = 0, .x2 = 1.00, .y2 = 1.5, .layer = 0, .width = 0.2, .net = 0 },
    };
    const samples = [_]RfSample{
        .{ .at = .{ 0.00, 0 }, .s_mm = 0.00, .curvature = 0, .width_mm = 0.5 },
        .{ .at = .{ 0.25, 0 }, .s_mm = 0.25, .curvature = 0, .width_mm = 0.5 },
        .{ .at = .{ 0.50, 0 }, .s_mm = 0.50, .curvature = 0, .width_mm = 0.5 },
        .{ .at = .{ 0.75, 0 }, .s_mm = 0.75, .curvature = 0, .width_mm = 0.5 },
        .{ .at = .{ 1.00, 0 }, .s_mm = 1.00, .curvature = 0, .width_mm = 0.5 },
        .{ .at = .{ 1.25, 0 }, .s_mm = 1.25, .curvature = 0, .width_mm = 0.5 },
        .{ .at = .{ 1.50, 0 }, .s_mm = 1.50, .curvature = 0, .width_mm = 0.5 },
        .{ .at = .{ 1.75, 0 }, .s_mm = 1.75, .curvature = 0, .width_mm = 0.5 },
        .{ .at = .{ 2.00, 0 }, .s_mm = 2.00, .curvature = 0, .width_mm = 0.5 },
    };
    const outcomes = [_]@import("rf_port_report.zig").Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const found = try check(arena, placement, .{
        .tracks = &tracks,
        .vias = &.{},
        .routed = 1,
        .total = 1,
        .rf_port_outcomes = &outcomes,
    }, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(found, .dangling_copper));
    try testing.expectEqual(@as(i32, 8), firstOfKind(found, .dangling_copper).?.who.track_a);
    try testing.expectEqual(@as(usize, 0), countKind(found, .copper_stub));
}

test "check warns for both sections of a self-supporting backtrack" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 5, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    var placement = partsOnly(&parts);
    placement.nets = &nets;
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 1, .x2 = 2.15, .y2 = 0.05, .layer = 0, .width = 0.2, .net = 0 },
    };
    const found = try check(arena, placement, .{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 }, 0.127);
    try testing.expectEqual(@as(usize, 2), countKind(found, .dangling_copper));
    try testing.expectEqual(Severity.warn, firstOfKind(found, .dangling_copper).?.severity);
    try testing.expectEqual(@as(usize, 0), countKind(found, .copper_stub));
}

// spec: placement/drc - flags a routed trace endpoint that reaches no same-net copper as a copper-stub error when its section still carries support connectivity
test "check keeps an essential loose section as a copper-stub error" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 1, .y = 2 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    var placement = partsOnly(&parts);
    placement.nets = &nets;
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 1, .y2 = 2, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{.{ .x = 1, .y = 0, .dia = 0.4, .net = 0 }};
    const found = try check(arena, placement, .{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 }, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(found, .copper_stub));
    try testing.expectEqual(Severity.err, firstOfKind(found, .copper_stub).?.severity);
}

// spec: placement/drc - warns when a signal net's own copper laps one of its pads instead of being aimed at the pad centre, while ground nets are exempt
// spec: placement/drc - reports one own-land warning per swept RF path and physical land rather than one per tessellation chord
test "check warns on signal copper riding a land's flank, not a clean escape or ground bond" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    // A 0.5 mm-pitch QFN lead land, long axis vertical, at the origin.
    const pad = [_]G.Pad{.{ .number = "18", .x = 0, .y = 0, .w = 0.3, .h = 0.9 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "18" }};
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    var placement = partsOnly(&parts);
    placement.nets = &nets;
    // The board owner's pin 18: the escape leaves at 45 degrees, stops on the
    // land's own edge, and turns north ALONG it — so the vertical leg's metal
    // sits in the corridor to the next pin, and its line misses the pad centre
    // by the land's half width.
    const riding = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0.15, .y2 = 0.15, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 0.15, .y1 = 0.15, .x2 = 0.15, .y2 = 1.14, .layer = 0, .width = 0.127, .net = 0 },
    };
    const found = try check(arena, placement, .{ .tracks = &riding, .vias = &.{}, .routed = 1, .total = 1 }, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(found, .land_transit));
    const v = firstOfKind(found, .land_transit).?;
    try testing.expectEqual(Severity.warn, v.severity);
    try testing.expectApproxEqAbs(@as(f64, 0.15), v.clearance, 1e-9); // how far the line misses the centre
    // Tessellating the same dirty run more finely does not multiply what is one
    // land-level routing condition into one warning per implementation chord.
    const sampled_riding = [_]router.Track{
        riding[0],
        .{ .x1 = 0.15, .y1 = 0.15, .x2 = 0.15, .y2 = 0.60, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 0.15, .y1 = 0.60, .x2 = 0.15, .y2 = 1.14, .layer = 0, .width = 0.127, .net = 0 },
    };
    const riding_samples = [_]RfSample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.127 },
        .{ .at = .{ 0.15, 0.15 }, .s_mm = 0.212, .curvature = 0, .width_mm = 0.127 },
        .{ .at = .{ 0.15, 0.60 }, .s_mm = 0.662, .curvature = 0, .width_mm = 0.127 },
        .{ .at = .{ 0.15, 1.14 }, .s_mm = 1.202, .curvature = 0, .width_mm = 0.127 },
    };
    const riding_outcomes = [_]@import("rf_port_report.zig").Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = riding_samples.len, .samples = &riding_samples, .layer = 0 },
    }};
    const sampled_route = router.RouteResult{
        .tracks = &sampled_riding,
        .vias = &.{},
        .routed = 1,
        .total = 1,
        .rf_port_outcomes = &riding_outcomes,
    };
    try testing.expectEqual(
        @as(usize, 1),
        countKind(try check(arena, placement, sampled_route, 0.127), .land_transit),
    );
    // The disciplined shape — north until clear of the land, THEN the 45 — is
    // the same connection, the same length, and no finding.
    const clean = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0.99, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 0, .y1 = 0.99, .x2 = 0.15, .y2 = 1.14, .layer = 0, .width = 0.127, .net = 0 },
    };
    try testing.expectEqual(
        @as(usize, 0),
        countKind(try check(arena, placement, .{ .tracks = &clean, .vias = &.{}, .routed = 1, .total = 1 }, 0.127), .land_transit),
    );
    // The same flank geometry is intentional on a ground return: surface
    // bonding and stitching copper may spread across its own lands.
    const ground_nets = [_]FlatNet{.{ .name = "GND", .pins = &pins }};
    placement.nets = &ground_nets;
    try testing.expectEqual(
        @as(usize, 0),
        countKind(try check(arena, placement, .{ .tracks = &riding, .vias = &.{}, .routed = 1, .total = 1 }, 0.127), .land_transit),
    );
}

// spec: placement/drc - an authored ground-via maximum warns on an SMD ground pad until a same-net plane via falls within the budget
test "ground pad via distance is a warning and accepts the exact limit" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "2", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.3,
        .hh = 0.3,
        .pads = &pad,
        .fallback = false,
    }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "2" }};
    const nets = [_]FlatNet{.{ .name = "GND", .pins = &pins }};
    var placement = partsOnly(&parts);
    placement.nets = &nets;
    placement.rules.design.pour.ground_via_max = 1.0;
    const missing = try check(arena, placement, .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 }, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(missing, .ground_via_distance));
    try testing.expectEqual(Severity.warn, firstOfKind(missing, .ground_via_distance).?.severity);
    const via = [_]router.Via{.{ .x = 1, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const served = try check(arena, placement, .{ .tracks = &.{}, .vias = &via, .routed = 0, .total = 0 }, 0.127);
    try testing.expectEqual(@as(usize, 0), countKind(served, .ground_via_distance));
}

// spec: placement/drc - an optional NC or input-strap land assigned to ground is excluded from the ground-via maximum because its same-package real ground return owns the required plane connection
test "ground via maximum does not require a barrel at a package tie-off land" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const PR = @import("pin_roles.zig");
    const pad = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 1, .y = 0, .w = 0.5, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 0.3,
        .hh = 0.3,
        .pads = &pad,
        .fallback = false,
    }};
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "2" },
    };
    const nets = [_]FlatNet{.{ .name = "GND", .pins = &pins }};
    var role = PR.PartRoles{};
    try role.map.put(arena, "1", .optional_nc);
    try role.map.put(arena, "2", .strap);
    var roles = [_]PR.PartRoles{role};
    var placement = partsOnly(&parts);
    placement.nets = &nets;
    placement.pin_roles = &roles;
    placement.rules.design.pour.ground_via_max = 1.0;
    const found = try check(arena, placement, .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 }, 0.127);
    try testing.expectEqual(@as(usize, 0), countKind(found, .ground_via_distance));
}

// spec: placement/drc - warns on a through-via that reaches fewer than two copper layers
test "check warns on a one-layer via and clears it when bottom copper arrives" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &.{} }};
    var parts = [_]optimizer.Part{};
    var placement = partsOnly(&parts);
    placement.nets = &nets;
    const via = [_]router.Via{.{ .x = 0, .y = 0, .dia = 0.4, .net = 0 }};
    const top = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const one = try check(arena, placement, .{ .tracks = &top, .vias = &via, .routed = 1, .total = 1 }, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(one, .single_layer_via));
    try testing.expectEqual(Severity.warn, firstOfKind(one, .single_layer_via).?.severity);
    const both = [_]router.Track{
        top[0],
        .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 2, .layer = 1, .width = 0.2, .net = 0 },
    };
    try testing.expectEqual(
        @as(usize, 0),
        countKind(try check(arena, placement, .{ .tracks = &both, .vias = &via, .routed = 1, .total = 1 }, 0.127), .single_layer_via),
    );
}

// spec: placement/copper-topology - a ground via backed by its net's authored outer-face pour is not reported as a single-layer routing artifact
test "check exempts only ground vias backed by their own declared pour" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{};
    var placement = partsOnly(&parts);
    const via = [_]router.Via{.{ .x = 0, .y = 0, .dia = 0.4, .net = 0 }};
    const top = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &top, .vias = &via, .routed = 1, .total = 1 };

    const ground_nets = [_]FlatNet{.{ .name = "GND", .pins = &.{} }};
    placement.nets = &ground_nets;
    placement.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, placement, routed, 0.127), .single_layer_via));

    const gnd_pour = [_]optimizer.PlaneAt{.{ .index = 1, .net = "GND" }};
    placement.rules = .{ .plane_nets = &.{"GND"}, .copper_layers = 2, .planes = .{ .declared = &gnd_pour } };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, placement, routed, 0.127), .single_layer_via));

    const signal_nets = [_]FlatNet{.{ .name = "SIG", .pins = &.{} }};
    const signal_pour = [_]optimizer.PlaneAt{.{ .index = 1, .net = "SIG" }};
    placement.nets = &signal_nets;
    placement.rules = .{ .plane_nets = &.{"SIG"}, .copper_layers = 2, .planes = .{ .declared = &signal_pour } };
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, placement, routed, 0.127), .single_layer_via));

    placement.nets = &ground_nets;
    placement.rules = .{ .plane_nets = &.{"SIG"}, .copper_layers = 2, .planes = .{ .declared = &signal_pour } };
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, placement, routed, 0.127), .single_layer_via));
}

// spec: placement/drc - a jointly safe subset of multi-layer non-ground vias is reported for cleanup while every ground via is protected
test "check plans redundant signal vias but never ground vias" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{
        .{ .x = 0.5, .y = 0, .dia = 0.4, .net = 0 },
        .{ .x = 1.5, .y = 0, .dia = 0.4, .net = 0 },
    };
    var parts = [_]optimizer.Part{};
    var placement = partsOnly(&parts);
    const signal_nets = [_]FlatNet{.{ .name = "SIG", .pins = &.{} }};
    placement.nets = &signal_nets;
    const signal = try check(arena, placement, .{ .tracks = &tracks, .vias = &vias, .routed = 0, .total = 0 }, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(signal, .redundant_via));
    try testing.expect(firstOfKind(signal, .redundant_via).?.who.track_a >= 0);

    const ground_nets = [_]FlatNet{.{ .name = "GND", .pins = &.{} }};
    placement.nets = &ground_nets;
    const ground = try check(arena, placement, .{ .tracks = &tracks, .vias = &vias, .routed = 0, .total = 0 }, 0.127);
    try testing.expectEqual(@as(usize, 0), countKind(ground, .redundant_via));
}

// spec: placement/drc - credits same-net user zones when classifying trace ends and via layer use, including priority clipping
test "checkWithZones credits same-net filled copper and honours priority clipping" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &.{} }};
    var parts = [_]optimizer.Part{};
    var placement = partsOnly(&parts);
    placement.nets = &nets;
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const vias = [_]router.Via{.{ .x = 1, .y = 0, .dia = 0.4, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 };
    const bare = try check(arena, placement, routed, 0.127);
    try testing.expectEqual(@as(usize, 0), countKind(bare, .copper_stub));
    try testing.expectEqual(@as(usize, 1), countKind(bare, .dangling_copper));
    try testing.expectEqual(@as(usize, 1), countKind(bare, .single_layer_via));
    const topology_tracks = try topologyTracks(arena, &tracks, .{});
    const topology_vias = try topologyVias(arena, &vias, .{});
    try testing.expect(copper_topology.looseEnd(&.{}, topology_tracks, topology_vias, 0, .{ 0, 0 }) != null);

    const region = [_][2]f64{ .{ -1, -1 }, .{ 3, -1 }, .{ 3, 1 }, .{ -1, 1 } };
    const zones = [_]TopologyZone{
        .{ .net = "SIG", .layer = 0, .poly = &region },
        .{ .net = "SIG", .layer = 1, .poly = &region },
    };
    const filled = try checkWithZones(arena, placement, routed, 0.127, &zones);
    try testing.expectEqual(@as(usize, 0), countKind(filled, .copper_stub));
    try testing.expectEqual(@as(usize, 0), countKind(filled, .dangling_copper));
    try testing.expectEqual(@as(usize, 0), countKind(filled, .single_layer_via));
    try testing.expect(copper_topology.looseEnd(&.{}, topology_tracks, topology_vias, 0, .{ 1, 1 }) == null);

    const clipped = [_]TopologyZone{
        zones[0],
        zones[1],
        .{ .net = "OTHER", .layer = 1, .poly = &region, .priority = 1 },
    };
    try testing.expectEqual(
        @as(usize, 1),
        countKind(try checkWithZones(arena, placement, routed, 0.127, &clipped), .single_layer_via),
    );
}

// ── Severity-table parity ───────────────────────────────────────────────────
//
// `defaultSeverity` is the ONE table; every producer stamps from it and the
// serve layer's DRC-policy drawer renders it. The pair below keeps that claim
// honest against the CHECKERS rather than against another copy of the table:
// the first proves each emitted violation carries its kind's default, the
// second proves no warning kind escapes fixture coverage. The bug they exist to
// catch is a real one — `diff_uncoupled` / `diff_skew` moved from `drc.zig` into
// `drc_diffpair.zig` and the drawer's mirror table kept calling them fab errors
// while the checker emitted warnings.

/// One flag per `Kind`, in enum order.
const KindSet = [@typeInfo(Kind).@"enum".field_names.len]bool;

/// Every violation a set of deliberately-bad boards produces. Between them they
/// trip every kind whose canonical default is a WARNING: assembly hygiene
/// (component edge, courtyard, silk over pad), the RF rules
/// (keepout halo, sharp bend), both differential-pair rules, the match-group
/// length mismatch, the single-layer via, and copper drawn dead on its own land.
/// Error kinds come along for the ride and are checked the same way.
fn severityFixtures(arena: std.mem.Allocator) ![7][]const Violation {
    return .{
        try hygieneBoard(arena),
        try rfBoard(arena),
        try diffPairBoard(arena),
        try matchGroupBoard(arena),
        try topologyBoard(arena),
        try deadCopperBoard(arena),
        try groundViaDistanceBoard(arena),
    };
}

/// One plane-carried SMD GND pad with no nearby via, proving the optional
/// return-distance rule participates in the canonical warning table.
fn groundViaDistanceBoard(arena: std.mem.Allocator) ![]const Violation {
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.3,
        .hh = 0.3,
        .pads = &pad,
        .fallback = false,
    }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "GND", .pins = &pins }};
    var placement = partsOnly(&parts);
    placement.nets = &nets;
    placement.rules.design.pour.ground_via_max = 1.0;
    return check(arena, placement, .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 }, 0.127);
}

/// One pad and a hook of copper drawn on it: out of the land by less than the
/// trace's own half width and back, joining nothing. Both of its ends are
/// attached (to that land), so this is the `dangling_copper` shape rather than a
/// `copper_stub` one.
fn deadCopperBoard(arena: std.mem.Allocator) ![]const Violation {
    const G = @import("geometry.zig");
    const pads = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.2, .h = 1.2 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.7, .hh = 0.7, .pads = &pads, .fallback = false, .x = 5, .y = 5 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const tracks = [_]router.Track{
        .{ .x1 = 5.3, .y1 = 5.4, .x2 = 5.62, .y2 = 5.4, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5.62, .y1 = 5.4, .x2 = 5.4, .y2 = 5.5, .layer = 0, .width = 0.2, .net = 0 },
    };
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
        .maxy = 10,
        .generated = true,
    };
    return check(arena, placement, .{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 }, 0.127);
}

fn topologyBoard(arena: std.mem.Allocator) ![]const Violation {
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &.{} }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        // A robust X crossing exercises the implicit-junction warning without
        // relying on the cap-only graze that connectivity now rejects.
        .{ .x1 = 1, .y1 = -1, .x2 = 1, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
        // A parallel bottom run reached by two vias exercises the general
        // redundant-via warning; either barrel can carry the layer jump, but
        // the jointly safe plan names only one of them.
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{
        // Keep both barrels clear of the stored section endpoints: endpoint
        // support is an independent invariant and would intentionally retain
        // a barrel that alone terminates an otherwise loose trace end.
        .{ .x = 0.5, .y = 0, .dia = 0.4, .net = 0 },
        .{ .x = 1.5, .y = 0, .dia = 0.4, .net = 0 },
        // The isolated barrel still covers the narrower single-layer warning.
        .{ .x = 4, .y = 0, .dia = 0.4, .net = 0 },
    };
    return check(arena, placement, .{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 }, 0.127);
}

/// Two parts close enough to overlap courtyards, one of them drawing silk
/// across the other's pad.
fn hygieneBoard(arena: std.mem.Allocator) ![]const Violation {
    const G = @import("geometry.zig");
    const a_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const b_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const silk = [_]G.SilkLine{.{ .x1 = 0.4, .y1 = 0, .x2 = 0.8, .y2 = 0 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &a_pad, .fallback = false, .x = 0, .y = 0, .features = .{ .silk_lines = &silk } },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &b_pad, .fallback = false, .x = 0.6, .y = 0 },
    };
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    var placement = partsOnly(&parts);
    placement.board_rect = .{ .minx = -1, .miny = -2, .w = 10, .h = 10 };
    placement.rules.design.edge.component = 2.5;
    return check(arena, placement, routed, 0.127);
}

/// An RF net declaring a keepout halo with a foreign trace inside it, plus a
/// corner the bend-smoothing pass could not bring up to its required radius.
fn rfBoard(arena: std.mem.Allocator) ![]const Violation {
    const rules = [_]optimizer.NetRule{
        .{ .rf = .{ .keepout_mm = 0.5, .keepout_escape_mm = 0 } },
        .{},
    };
    const nets = [_]FlatNet{ .{ .name = "RF_IN", .pins = &.{} }, .{ .name = "SPI_SCK", .pins = &.{} } };
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 30,
        .maxy = 30,
        .generated = true,
        .rules = .{ .net = &rules },
    };
    // 0.4 mm centre-to-centre between two 0.2 mm traces ⇒ 0.2 mm edge-to-edge:
    // inside the 0.5 mm halo, but clear of the 0.127 mm spacing rule, so the
    // keepout warning is not confounded by a clearance error.
    const tracks = [_]router.Track{
        .{ .x1 = 5, .y1 = 10, .x2 = 15, .y2 = 10, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5, .y1 = 10.4, .x2 = 15, .y2 = 10.4, .layer = 0, .width = 0.2, .net = 1 },
    };
    const bends = [_]router.SharpBend{.{ .x = 15, .y = 10, .layer = 0, .net = 0, .radius = 0.1, .required = 0.6 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .sharp_bends = &bends, .routed = 2, .total = 2 };
    return check(arena, placement, routed, 0.127);
}

/// A declared differential pair whose legs run apart AND end up different
/// lengths — the two diff-pair rules together.
fn diffPairBoard(arena: std.mem.Allocator) ![]const Violation {
    const pairs = [_]@import("diff_pairs.zig").DiffPair{.{ .p = 0, .n = 1, .gap = 0.2 }};
    const nets = [_]FlatNet{ .{ .name = "D_P", .pins = &.{} }, .{ .name = "D_N", .pins = &.{} } };
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = true,
        .diff_pairs = &pairs,
    };
    // P runs 10 mm straight; N leaves at a steep angle, so it is both far from
    // P over most of the run (uncoupled) and much longer than it (skew).
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 0, .y1 = 0.2, .x2 = 10, .y2 = 15, .layer = 0, .width = 0.127, .net = 1 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 };
    return check(arena, placement, routed, 0.127);
}

/// A declared `(match-group …)` whose three routed members come out at 10, 14
/// and 12 mm against a 0.5 mm budget — a `length_mismatch`. The legs are 5 mm
/// apart so no clearance rule fires alongside it.
fn matchGroupBoard(arena: std.mem.Allocator) ![]const Violation {
    const groups = [_]@import("match_group.zig").Group{
        .{ .name = "addr", .tolerance_mm = 0.5, .members = &.{ 0, 1, 2 } },
    };
    const nets = [_]FlatNet{
        .{ .name = "A0", .pins = &.{} },
        .{ .name = "A1", .pins = &.{} },
        .{ .name = "A2", .pins = &.{} },
    };
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = true,
        .match_groups = &groups,
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 0, .y1 = 5, .x2 = 14, .y2 = 5, .layer = 0, .width = 0.127, .net = 1 },
        .{ .x1 = 0, .y1 = 10, .x2 = 12, .y2 = 10, .layer = 0, .width = 0.127, .net = 2 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 3, .total = 3 };
    return check(arena, placement, routed, 0.127);
}

/// Assert every violation the fixtures emit carries its kind's canonical default
/// severity, and report which kinds were observed at all.
fn observedKindSeverities(arena: std.mem.Allocator) !KindSet {
    var seen: KindSet = @splat(false);
    for (try severityFixtures(arena)) |list| {
        for (list) |v| {
            try testing.expectEqual(defaultSeverity(v.kind), v.severity);
            seen[@backingInt(v.kind)] = true;
        }
    }
    return seen;
}

/// The first kind `defaultSeverity` calls a WARNING that no fixture emitted —
/// the coverage ratchet. A new warning rule (or one that silently stopped
/// firing) surfaces here instead of leaving the table unproven.
fn firstUncoveredWarningKind(seen: KindSet) ?Kind {
    for (0..seen.len) |i| {
        const k: Kind = @fromBackingInt(@intCast(i));
        // These checks are composed at the final reporting seam because their
        // exact fill/surface graphs are intentionally too expensive for the
        // router/WASM hot path. Their owning modules prove the emitted default
        // severity alongside their dedicated geometry fixtures.
        if (k == .bypass_open or k == .reference_plane_gap or
            k == .reference_transition or k == .loop_area) continue;
        if (defaultSeverity(k) == .warn and !seen[i]) return k;
    }
    return null;
}

// spec: placement/drc - every check stamps its kind's canonical default severity, and each warning kind is proved by a fixture
test "the severity table is what the checkers emit, for every warning kind" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const seen = try observedKindSeverities(arena_inst.allocator());
    try testing.expect(seen[@backingInt(Kind.redundant_via)]);
    // The aggregated `power_width` producer is exercised directly above; it
    // cannot share these whole-board fixtures without replacing its solved
    // current graph with the conservative net-class fallback.
    try testing.expectEqual(@as(?Kind, Kind.power_width), firstUncoveredWarningKind(seen));
}

// spec: placement/drc - the fab-blocking error count drops warnings and an open net, which is already the completion term
test "errorCount counts fab-blocking geometry only" {
    const vios = [_]Violation{
        .{ .x = 0, .y = 0, .gap = 0.01, .clearance = 0.127, .kind = .track_pad },
        .{ .x = 1, .y = 1, .gap = 0, .clearance = 0, .kind = .sharp_bend, .severity = .warn },
        .{ .x = 2, .y = 2, .gap = 0.02, .clearance = 0.127, .kind = .track_track },
        // Connectivity, not geometry — every surface that reports it also
        // reports routed/total/open, so counting it here charges it twice.
        .{ .x = 3, .y = 3, .gap = 0.3, .clearance = 0, .kind = .net_open },
    };
    try testing.expectEqual(@as(usize, 2), errorCount(&vios));
    try testing.expectEqual(@as(usize, 0), errorCount(vios[1..2]));
    try testing.expectEqual(@as(usize, 0), errorCount(vios[3..4]));
    try testing.expectEqual(@as(usize, 0), errorCount(&.{}));
}

// spec: placement/drc - flags two vias of the SAME net crowded closer than the via-to-via rule, which the foreign-net clearance rule exempts
test "same-net vias crowding each other flag via_spacing, not via_via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // barracuda's measured duplicate: two 0.4 mm barrels of ONE net 0.402 mm
    // apart — a copper gap of 0.002 mm. It clears the board's declared 0.2 mm
    // hole-to-hole (drills 0.2 ⇒ wall 0.202), and `via_via` exempts a same-net
    // pair outright, so before `via_spacing` nothing on the board saw it.
    const vias = [_]router.Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 0.402, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
        // A legitimate stitch-fence pitch on the same net, 1.2 mm along: clean.
        .{ .x = 1.602, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    var parts = [_]optimizer.Part{};
    var pl = partsOnly(&parts);
    pl.rules = .{ .design = .{ .hole_to_hole = 0.2 } };
    const rr = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 };
    const v = try check(arena, pl, rr, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(v, .via_spacing));
    try testing.expectEqual(@as(usize, 0), countKind(v, .via_via));
    try testing.expectEqual(@as(usize, 0), countKind(v, .hole_hole));
    // The finding names the net on both sides and measures the real copper gap.
    const hit = firstOfKind(v, .via_spacing).?;
    try testing.expectApproxEqAbs(@as(f64, 0.002), hit.gap, 1e-9);
    try testing.expectEqual(@as(i32, 0), hit.who.net_a);
    try testing.expectEqual(@as(i32, 0), hit.who.net_b);
    try testing.expectEqual(Severity.err, hit.severity);
}

// spec: placement/drc - the same-net via spacing rule defaults to the pair's resolved clearance, and an authored (design-rules (via-to-via ...)) overrides it
test "the via-spacing rule falls back to clearance and an authored value overrides it" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 0.6 mm of copper between two same-net barrels: clean at the 0.127 mm
    // board clearance the rule falls back to …
    const vias = [_]router.Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .net = 0 },
        .{ .x = 1.0, .y = 0, .dia = 0.4, .net = 0 },
    };
    var parts = [_]optimizer.Part{};
    var pl = partsOnly(&parts);
    const rr = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 0), countKind(try check(arena, pl, rr, 0.127), .via_spacing));
    // … and flagged once the design says same-net barrels owe each other 1 mm.
    pl.rules = .{ .design = .{ .via_to_via = 1.0 } };
    const strict = try check(arena, pl, rr, 0.127);
    try testing.expectEqual(@as(usize, 1), countKind(strict, .via_spacing));
    try testing.expectApproxEqAbs(@as(f64, 1.0), firstOfKind(strict, .via_spacing).?.clearance, 1e-12);
    // A net-class clearance raises the fallback for its own net, too.
    pl.rules = .{ .design = .{}, .net = &[_]optimizer.NetRule{.{ .clearance = 0.8 }} };
    try testing.expectEqual(@as(usize, 1), countKind(try check(arena, pl, rr, 0.127), .via_spacing));
}
