//! Composing a board's full DRC verdict: the geometric rules, plus the
//! board-text overlap warnings, plus the `net_open` connectivity layer.
//!
//! This is the seam every reporting surface measures a board through, and
//! deliberately NOT `drc.check`: geometry alone says nothing about whether the
//! routed copper actually joins each net's pads, so a board whose copper left a
//! net in two islands reads as clean without the connectivity layer. (The
//! router's candidate loop and the client WASM engine still call `drc.check`
//! directly — the per-net pour raster must not run in a hot path.)
//!
//! It was declared in `serve/drc_rules.zig` next to the `<name>.drc-rules.json`
//! severity sidecar, so `kicad_pcb/route_command.zig` — which scores an
//! uploaded board and wants no server at all — had to import `serve/`. Every
//! input here is a placement type and nothing touches the filesystem or HTTP,
//! so the composition belongs beneath both. `drc_rules.zig` keeps the sidecar
//! half and re-exports `CopperCheck` / `checkDefaultRules`; its
//! `checkFilteredZones` is now visibly this composition plus the override pass.

const std = @import("std");
const drc = @import("drc.zig");
const drc_pour = @import("drc_pour.zig");
const drc_return_path = @import("drc_return_path.zig");
const fill_cache = @import("fill_cache.zig");
const bypass_open = @import("bypass_open.zig");
const net_open = @import("net_open.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const pour = @import("pour.zig");
const path_copper = @import("path_copper.zig");
const font = @import("../font5x7.zig");
const silk_font = @import("../silk_font.zig");

/// The copper context one connectivity/geometry DRC pass measures: the
/// placement, the routed copper, the clearance rule, and any hand-drawn user
/// copper pours to credit toward connectivity.
pub const CopperCheck = struct {
    placement: optimizer.Placement,
    routed: router.RouteResult,
    clearance: f64,
    zones: []const pour.UserZone = &.{},
    /// The caller's shared board-edge margin field, when the whole render
    /// pours the same board and seeded it once (see `pour.sharedEdgeField`).
    /// Every fill below — the topology zones and the net-open connectivity —
    /// reads it, so the outline walk is not repeated per pass. Null seeds
    /// per call, exactly as before.
    base_edge: ?pour.EdgeField = null,
    /// Saved board-level silkscreen labels shown with this copper. Empty for
    /// route-only/internal checks that have no layout text context.
    texts: []const font.BoardText = &.{},
};

/// `checkFilteredZones` for copper that belongs to NO project design: an
/// uploaded `.kicad_pcb` on the route-review endpoint, or a board the
/// `route-kicad-reference` CLI is scoring. There is no `<name>.drc-rules.json`
/// to load for a foreign board, so the built-in severities stand — but the
/// `net_open` connectivity layer must still be there, or the report claims a
/// board whose copper leaves islands is DRC-clean. Identical to
/// `checkFilteredZones` against a design with no rule sidecar, minus the
/// pointless filesystem probe.
pub fn checkDefaultRules(alloc: std.mem.Allocator, in: CopperCheck) []const drc.Violation {
    return checkDefaultRulesReport(alloc, in).violations;
}

/// Full DRC result plus the connectivity statuses already built by the
/// net-open layer. Reporting endpoints that also show routed/total consume the
/// statuses instead of repeating the board's per-net plane rasters and unions.
pub const CheckReport = struct {
    violations: []const drc.Violation,
    net_report: net_open.Report,
    /// False when a fill/topology/connectivity stage failed and the ordinary
    /// interactive surface therefore received only a best-effort partial
    /// report.  Fab export consumes this bit and fails closed.
    complete: bool = true,
};

const ViolationStage = struct {
    violations: []const drc.Violation,
    complete: bool,
};

/// Compose all DRC layers while retaining the net-open layer's reusable
/// connectivity report for a caller that also needs a routed tally.
pub fn checkDefaultRulesReport(alloc: std.mem.Allocator, in: CopperCheck) CheckReport {
    // ONE borrow spans every layer below, because the connectivity layer reads
    // the same fill the topology rules judged. It is released on the way out —
    // every violation, status and string this returns is built from the
    // placement, never from the fill (see `fill_cache`'s header).
    var board = boardFills(alloc, in);
    defer board.release();
    const geom = filledViolationsReport(alloc, in, board);
    const silk = withBoardTextReport(alloc, in.placement, geom, in.texts);
    const bypass = withBypassOpenReport(alloc, in.placement, in.routed, silk);
    return withNetOpenReport(alloc, in, bypass, board);
}

/// Run only copper-topology findings against the fabricated fill components.
/// Persisted cleanup uses this to obtain the exact same jointly-safe removal
/// plan as full DRC without paying for unrelated geometry findings each round.
pub fn checkTopologyFilled(alloc: std.mem.Allocator, in: CopperCheck) []const drc.Violation {
    var board = boardFills(alloc, in);
    defer board.release();
    if (board.failed) return &.{};
    return drc.checkTopology(alloc, in.placement, in.routed, board.fills.zones) catch &.{};
}

/// Append exact-target bypass connectivity warnings. This stays beside the
/// net-open layer, outside `drc.check`, so router candidates and client WASM do
/// not rebuild a surface graph for every tentative edit.
fn withBypassOpenReport(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    r: router.RouteResult,
    base: ViolationStage,
) ViolationStage {
    const warnings = bypass_open.check(alloc, placement, r.tracks) catch return .{ .violations = base.violations, .complete = false };
    if (warnings.len == 0) return base;
    var all: std.ArrayList(drc.Violation) = .empty;
    all.appendSlice(alloc, base.violations) catch return .{ .violations = base.violations, .complete = false };
    all.appendSlice(alloc, warnings) catch return .{ .violations = base.violations, .complete = false };
    return .{ .violations = all.items, .complete = base.complete };
}

fn textBox(t: font.BoardText) [4]f64 {
    const width = silk_font.widthMm(t.text, t.size);
    const height = silk_font.heightMm(t.size);
    const radians = t.rot * std.math.pi / 180;
    const cs = @abs(@cos(radians));
    const sn = @abs(@sin(radians));
    const hw = (width * cs + height * sn) / 2;
    const hh = (width * sn + height * cs) / 2;
    return .{ t.x - hw, t.y - hh, t.x + hw, t.y + hh };
}

fn boxOverlap(a: [4]f64, b: optimizer.BoardRect) ?[2]f64 {
    const x0 = @max(a[0], b.minx);
    const y0 = @max(a[1], b.miny);
    const x1 = @min(a[2], b.minx + b.w);
    const y1 = @min(a[3], b.miny + b.h);
    if (!(x1 > x0 + 1e-9 and y1 > y0 + 1e-9)) return null;
    return .{ (x0 + x1) / 2, (y0 + y1) / 2 };
}

/// Add one warning for each board-level silk label whose printed bounding box
/// crosses a same-side component courtyard. Footprint-owned silk already has
/// the exact pad-opening check in `drc.zig`; this covers the layout Text tool.
fn withBoardTextReport(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    base: ViolationStage,
    texts: []const font.BoardText,
) ViolationStage {
    if (texts.len == 0) return base;
    var out: std.ArrayList(drc.Violation) = .empty;
    out.appendSlice(alloc, base.violations) catch return .{ .violations = base.violations, .complete = false };
    for (texts) |t| {
        if (t.text.len == 0 or !(t.size > 0)) continue;
        const tb = textBox(t);
        for (placement.parts, 0..) |part, i| {
            if (t.bottom != (part.side == .bottom)) continue;
            const hit = boxOverlap(tb, optimizer.worldCourtyard(&part)) orelse continue;
            out.append(alloc, .{
                .x = hit[0],
                .y = hit[1],
                .gap = 0,
                .clearance = 0,
                .kind = .silk_over_pad,
                .severity = drc.defaultSeverity(.silk_over_pad),
                .who = .{ .part_a = drc.partyIndex(i) },
            }) catch return .{ .violations = base.violations, .complete = false };
        }
    }
    return .{ .violations = out.items, .complete = base.complete };
}

/// The FULL geometry + copper-topology check against the fabricated fill — the
/// twin of `checkTopologyFilled`, for a caller that must judge copper the same
/// way the fill does AND still see every clearance rule.
///
/// `drc.check` is the same rules with NO fill, and the difference is not
/// cosmetic: the topology rules credit a same-net pour as copper, so a trace
/// that ends on its own rail's pour is a finished run here and an unattached
/// `copper_stub` — an ERROR — to the zone-blind spelling. A caller that pours a
/// rail and then judges its copper without the pour is contradicting itself.
pub fn checkFilled(alloc: std.mem.Allocator, in: CopperCheck) []const drc.Violation {
    var board = boardFills(alloc, in);
    defer board.release();
    return filledViolationsReport(alloc, in, board).violations;
}

/// The geometry rules plus the return-path rule, judged against `board`'s fill.
/// A board whose fill could not be built degrades to the ZONE-BLIND rules
/// rather than to an EMPTY fill: an empty fill is not "no pours", it is "every
/// pour vanished", and it would report every trace that terminates on its own
/// rail's copper as an unattached stub.
fn filledViolationsReport(alloc: std.mem.Allocator, in: CopperCheck, board: BoardFills) ViolationStage {
    if (board.failed) {
        const fallback = drc.check(alloc, in.placement, in.routed, in.clearance) catch &.{};
        return .{ .violations = fallback, .complete = false };
    }
    const zones = board.fills.zones;
    const prepared = drc.PreparedCopper{
        .topology_zones = zones,
        .plane_fills = board.fills.plane_fills,
        .zones = in.zones,
        .zone_fills = board.fills.zone_fills,
    };
    const base = drc.checkWithPreparedCopper(
        alloc,
        in.placement,
        in.routed,
        in.clearance,
        prepared,
    ) catch return .{ .violations = &.{}, .complete = false };
    var out: std.ArrayList(drc.Violation) = .empty;
    out.appendSlice(alloc, base) catch return .{ .violations = base, .complete = false };
    const pour_violations = drc_pour.check(alloc, in.placement, in.routed, prepared) catch return .{ .violations = base, .complete = false };
    out.appendSlice(alloc, pour_violations) catch return .{ .violations = base, .complete = false };
    drc_return_path.check(alloc, &out, in.placement, in.routed, zones) catch return .{ .violations = base, .complete = false };
    return .{ .violations = out.items, .complete = true };
}

/// This board's reduced fill for one DRC pass: either borrowed from the memo or
/// freshly poured into the caller's arena. `release` ends a borrow.
const BoardFills = struct {
    fills: fill_cache.Fills = .{},
    held: fill_cache.Held = .{},
    /// The fill could not be built at all (allocation failure). Distinguished
    /// from an empty fill, which is a legitimate answer for a board with no
    /// planes, pours or zones — see `filledViolations`.
    failed: bool = false,

    fn release(self: *BoardFills) void {
        self.held.release();
    }
};

/// The board's fill, memoised on the board's own bytes. A hit skips the whole
/// per-net raster; a miss pours exactly as before and retains a copy for the
/// next surface to ask about the same board (`fill_cache`).
fn boardFills(alloc: std.mem.Allocator, in: CopperCheck) BoardFills {
    const key = fill_cache.key(in.placement, in.routed, in.zones);
    var held = fill_cache.acquire(key);
    if (held.entry != null) return .{ .fills = held.fills(), .held = held };
    const fresh = filledTopology(alloc, in) catch return .{ .failed = true };
    fill_cache.put(key, fresh);
    return .{ .fills = fresh };
}

/// Reduce every declared plane/pour and hand-authored zone to the exact kept
/// fill components the Gerber uses. The DRC topology graph receives one node
/// per component (and its holes), never one outline-wide conductor.
///
/// This is the expensive half of the reporting seam — one raster per net per
/// carrying layer plus one per user zone — so `boardFills` memoises its result
/// and this runs only for a board no surface has poured yet.
fn filledTopology(alloc: std.mem.Allocator, in: CopperCheck) std.mem.Allocator.Error!fill_cache.Fills {
    var out: std.ArrayList(drc.TopologyZone) = .empty;
    var plane_fills: std.ArrayList(pour.NetFills) = .empty;
    var component: u64 = 1;
    // Keep the compact route plus its geometry proof intact here. Gerber
    // passes this exact spelling to `computeShared`: the pour engine suppresses
    // RF-owned handles/native arcs itself and carves the finished swept path.
    // Pre-lowering to max-width capsules would make reporting DRC retain a
    // different (over-cleared) fill from the one actually fabricated.
    const copper = pour.Copper{
        .tracks = in.routed.tracks,
        .vias = in.routed.vias,
        .arcs = in.routed.arcs,
        .rf_paths = in.routed.rf_port_outcomes,
        .zones = in.zones,
    };
    // Every plane, pour and zone below rasters the SAME board on the SAME
    // lattice, so the outline walk that seeds each cell's edge margin is done
    // once here and copied per fill. `base_edge` is the whole render's field
    // when the caller seeded it; otherwise we seed our own.
    const base = if (in.base_edge) |b| b else try pour.sharedEdgeField(alloc, in.placement);
    for (in.placement.nets) |net| {
        const layers = try pour.carryingLayers(alloc, in.placement.rules, net.name);
        if (layers.len == 0) continue;
        const prepared_layers = try alloc.alloc(pour.LayerSpec, layers.len);
        const fills = try alloc.alloc(pour.Fill, layers.len);
        for (layers, 0..) |layer, fill_i| {
            var spec = layer;
            if (spec.track_layer) |track_layer|
                spec.higher = try pour.higherThanDeclared(alloc, in.zones, track_layer, spec.net);
            const fill = try pour.computeShared(alloc, in.placement, copper, spec, base);
            prepared_layers[fill_i] = spec;
            fills[fill_i] = fill;
            for (fill.contours, 0..) |contour, contour_i| {
                try out.append(alloc, .{
                    .net = net.name,
                    .layer = spec.track_layer orelse 0,
                    .stack = spec.stack,
                    .poly = contour,
                    .holes = fill.holes[contour_i],
                    .component = component,
                    .plane = spec.track_layer == null,
                });
                component += 1;
            }
        }
        try plane_fills.append(alloc, .{ .net_name = net.name, .layers = prepared_layers, .fills = fills });
    }
    for (in.zones, 0..) |zone, zone_i| {
        var spec = pour.zoneLayerSpec(zone.net, pour.sideOfSignal(zone.layer), zone.layer, zone.poly);
        spec.higher = try pour.higherPolys(alloc, in.zones, zone_i);
        const fill = try pour.computeShared(alloc, in.placement, copper, spec, base);
        for (fill.contours, 0..) |contour, contour_i| {
            try out.append(alloc, .{
                .net = zone.net,
                .layer = zone.layer,
                .poly = contour,
                .holes = fill.holes[contour_i],
                .component = component,
            });
            component += 1;
        }
    }
    // The connectivity layer's own whole-board raster, taken here so the memo
    // retains BOTH halves of the seam's fill work under one board key. It reads
    // the same physical tracks and the same edge field this loop just used.
    const zone_fills = try net_open.zoneFills(
        alloc,
        in.placement,
        .{
            .tracks = in.routed.tracks,
            .vias = in.routed.vias,
            .arcs = in.routed.arcs,
            .rf_paths = in.routed.rf_port_outcomes,
            .zones = in.zones,
        },
        base,
    );
    return .{
        .zones = try out.toOwnedSlice(alloc),
        .plane_fills = try plane_fills.toOwnedSlice(alloc),
        .zone_fills = zone_fills,
    };
}

/// Append the net-open connectivity violations to the geometric ones. Fail-open:
/// on any allocation failure the geometric list rides through unchanged (a
/// partial DRC beats none).
fn withNetOpenReport(
    alloc: std.mem.Allocator,
    in: CopperCheck,
    geom: ViolationStage,
    board: BoardFills,
) CheckReport {
    const empty: net_open.Report = .{ .violations = &.{}, .connectivity = &.{} };
    const tracks = connectivityTracks(alloc, in.routed) catch return .{ .violations = geom.violations, .net_report = empty, .complete = false };
    const arcs = path_copper.filterArcs(alloc, in.routed.rf_port_outcomes, in.routed.arcs) catch
        return .{ .violations = geom.violations, .net_report = empty, .complete = false };
    const prepared: net_open.Prepared = .{
        .base = in.base_edge,
        .plane_fills = board.fills.plane_fills,
        // A board whose fill could not be built has no PREPARED zone rasters —
        // which is not the same fact as a board that rasters to none, so the
        // failed pass asks for its own rather than claiming there are no zones.
        .zone_fills = if (board.failed) null else board.fills.zone_fills,
    };
    const report = net_open.checkWithConnectivity(alloc, in.placement, .{ .tracks = tracks, .vias = in.routed.vias, .arcs = arcs, .zones = in.zones }, prepared) catch
        return .{ .violations = geom.violations, .net_report = empty, .complete = false };
    const connectivity_complete = !board.failed and report.connectivity.len == in.placement.nets.len;
    if (report.violations.len == 0) return .{ .violations = geom.violations, .net_report = report, .complete = geom.complete and connectivity_complete };
    var all: std.ArrayList(drc.Violation) = .empty;
    all.appendSlice(alloc, geom.violations) catch return .{ .violations = geom.violations, .net_report = report, .complete = false };
    all.appendSlice(alloc, report.violations) catch return .{ .violations = geom.violations, .net_report = report, .complete = false };
    return .{ .violations = all.items, .net_report = report, .complete = geom.complete and connectivity_complete };
}

/// A persisted RF path intentionally omits its solver chords: the compact
/// sample chain is the copper authority rendered and fabricated as one swept
/// polygon. Reconstruct those chords only for connectivity when no ordinary
/// track remains on that net. Geometry DRC keeps the polygon proof instead of
/// reclassifying its implementation samples as editable track segments.
fn connectivityTracks(alloc: std.mem.Allocator, r: router.RouteResult) std.mem.Allocator.Error![]const router.Track {
    return path_copper.tracks(alloc, r);
}

fn exactFillKeepsCopperLoweringRemoves(exact: pour.Fill, lowered: pour.Fill) bool {
    var y: f64 = 4.0;
    while (y <= 6.0) : (y += 0.05) {
        var x: f64 = 2.0;
        while (x <= 4.0) : (x += 0.05) {
            if (exact.componentAt(x, y) >= 0 and lowered.componentAt(x, y) < 0) return true;
        }
    }
    return false;
}

// ── Tests ─────────────────────────────────────────────────────────────────

// spec: placement/fill-cache - a second reporting DRC over an unchanged board reuses the retained fill instead of re-pouring it and returns the identical verdict
test "a memoised board fill returns the verdict the pour that built it returned" {
    const testing = std.testing;
    const geometry = @import("geometry.zig");
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    // Two GND pads under one hand-drawn GND pour: the pour is what joins them,
    // so a verdict taken against a wrong or missing fill would differ loudly.
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 1, .y = 1 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 4, .y = 1 },
    };
    const pins = [_]@import("../flat_netlist.zig").FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]optimizer.FlatNet{.{ .name = "GND", .pins = &pins }};
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
        .maxx = 5,
        .maxy = 2,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 5, .h = 2 },
    };
    const drawn = [_][2]f64{ .{ 0.2, 0.2 }, .{ 4.8, 0.2 }, .{ 4.8, 1.8 }, .{ 0.2, 1.8 } };
    const zones = [_]pour.UserZone{.{ .net = "GND", .layer = 0, .poly = &drawn }};
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1 };
    const in: CopperCheck = .{ .placement = placement, .routed = empty, .clearance = 0.127, .zones = &zones };

    const poured = checkDefaultRules(alloc, in);
    // The pour is load-bearing in this fixture: the identical board judged
    // WITHOUT it reads differently, so the comparison below cannot pass by
    // accident on a memo that handed back the wrong fill (or none).
    const unpoured = checkDefaultRules(alloc, .{ .placement = placement, .routed = empty, .clearance = 0.127 });
    try testing.expect(drc.countKind(unpoured, .net_open) != drc.countKind(poured, .net_open));

    // The board is retained now, so the pass below borrows its fill rather
    // than rastering the pour a second time.
    var held = fill_cache.acquire(fill_cache.key(placement, empty, &zones));
    defer held.release();
    try testing.expect(held.entry != null);

    const memoised = checkDefaultRules(alloc, in);
    try testing.expectEqual(poured.len, memoised.len);
    try testing.expectEqual(drc.errorCount(poured), drc.errorCount(memoised));
    try testing.expectEqual(drc.countKind(poured, .net_open), drc.countKind(memoised, .net_open));
    for (poured, memoised) |a, b| {
        try testing.expectEqual(a.kind, b.kind);
        try testing.expectEqual(a.severity, b.severity);
        try testing.expectEqual(a.x, b.x);
        try testing.expectEqual(a.y, b.y);
        try testing.expectEqual(a.gap, b.gap);
        try testing.expectEqualStrings(a.who.pad_a, b.who.pad_a);
        try testing.expectEqualStrings(a.who.pad_b, b.who.pad_b);
    }
    // A board that MOVED is a different board, and its fill is not that one.
    parts[1].x = 4.5;
    var moved = fill_cache.acquire(fill_cache.key(placement, empty, &zones));
    defer moved.release();
    try testing.expect(moved.entry == null);
}

// spec: placement/drc - reporting DRC retains the same exact variable-width RF carve that Gerber computes from the raw route proof
test "filled topology and Gerber proof carve the same RF taper" {
    const testing = std.testing;
    const rf_path_solver = @import("rf_path_solver.zig");
    const rf_port_report = @import("rf_port_report.zig");
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const nets = [_]optimizer.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "RF", .pins = &.{} },
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
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .rules = .{ .copper_layers = 2, .design = .{ .pour = .{ .clearance_outer = 0.2 } } },
    };
    const samples = [_]rf_path_solver.Sample{
        .{ .at = .{ 2, 5 }, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 8, 5 }, .s_mm = 6, .curvature = 0, .width_mm = 1.0 },
    };
    const outcomes = [_]rf_port_report.Outcome{.{
        .net = 1,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const handle = [_]router.Track{.{
        .x1 = 2,
        .y1 = 5,
        .x2 = 8,
        .y2 = 5,
        .layer = 0,
        .width = 0.2,
        .net = 1,
    }};
    const zone_poly = [_][2]f64{ .{ 0.2, 0.2 }, .{ 9.8, 0.2 }, .{ 9.8, 9.8 }, .{ 0.2, 9.8 } };
    const zones = [_]pour.UserZone{.{ .net = "GND", .layer = 0, .poly = &zone_poly }};
    const routed = router.RouteResult{
        .tracks = &handle,
        .vias = &.{},
        .rf_port_outcomes = &outcomes,
        .routed = 1,
        .total = 1,
    };
    const in: CopperCheck = .{ .placement = placement, .routed = routed, .clearance = 0.127, .zones = &zones };
    const retained = try filledTopology(alloc, in);
    try testing.expectEqual(@as(usize, 1), retained.zone_fills.len);

    const base = try pour.sharedEdgeField(alloc, placement);
    const spec = pour.zoneLayerSpec("GND", .top, 0, &zone_poly);
    const exact = try pour.computeShared(alloc, placement, .{
        .tracks = &handle,
        .rf_paths = &outcomes,
        .zones = &zones,
    }, spec, base);
    try testing.expectEqual(@as(usize, 1), exact.contours.len);
    try testing.expectEqual(@as(usize, 1), retained.zones.len);
    try testing.expectEqualSlices([2]f64, exact.contours[0], retained.zones[0].poly);
    try testing.expectEqual(@as(usize, 1), exact.holes[0].len);
    try testing.expectEqual(@as(usize, 1), retained.zones[0].holes.len);
    try testing.expectEqualSlices([2]f64, exact.holes[0][0], retained.zones[0].holes[0]);
    try testing.expectEqual(exact.integrity_ok, retained.zone_fills[0].integrity_ok);
    try testing.expectEqual(exact.n_comp, retained.zone_fills[0].n_comp);
    try testing.expectEqualSlices(i32, exact.labels, retained.zone_fills[0].labels);

    // Prove this fixture catches the old adapter: its max-endpoint-width
    // capsule removes copper near the narrow end that the tapered film keeps.
    const lowered_tracks = try path_copper.tracks(alloc, routed);
    const lowered = try pour.computeShared(alloc, placement, .{ .tracks = lowered_tracks, .zones = &zones }, spec, base);
    try testing.expect(exactFillKeepsCopperLoweringRemoves(exact, lowered));
}
