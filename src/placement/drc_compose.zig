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
const drc_return_path = @import("drc_return_path.zig");
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
};

/// Compose all DRC layers while retaining the net-open layer's reusable
/// connectivity report for a caller that also needs a routed tally.
pub fn checkDefaultRulesReport(alloc: std.mem.Allocator, in: CopperCheck) CheckReport {
    const filled = checkFilledReport(alloc, in);
    const geom = filled.violations;
    const silk = withBoardText(alloc, in.placement, geom, in.texts);
    const bypass = withBypassOpen(alloc, in.placement, in.routed, silk);
    return withNetOpenReport(alloc, in, bypass, filled.plane_fills);
}

/// Run only copper-topology findings against the fabricated fill components.
/// Persisted cleanup uses this to obtain the exact same jointly-safe removal
/// plan as full DRC without paying for unrelated geometry findings each round.
pub fn checkTopologyFilled(alloc: std.mem.Allocator, in: CopperCheck) []const drc.Violation {
    const filled = filledTopology(alloc, in) catch return &.{};
    return drc.checkTopology(alloc, in.placement, in.routed, filled.zones) catch &.{};
}

/// Append exact-target bypass connectivity warnings. This stays beside the
/// net-open layer, outside `drc.check`, so router candidates and client WASM do
/// not rebuild a surface graph for every tentative edit.
fn withBypassOpen(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    r: router.RouteResult,
    base: []const drc.Violation,
) []const drc.Violation {
    const warnings = bypass_open.check(alloc, placement, r.tracks) catch return base;
    if (warnings.len == 0) return base;
    var all: std.ArrayList(drc.Violation) = .empty;
    all.appendSlice(alloc, base) catch return base;
    all.appendSlice(alloc, warnings) catch return base;
    return all.items;
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
fn withBoardText(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    base: []const drc.Violation,
    texts: []const font.BoardText,
) []const drc.Violation {
    if (texts.len == 0) return base;
    var out: std.ArrayList(drc.Violation) = .empty;
    out.appendSlice(alloc, base) catch return base;
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
            }) catch return base;
        }
    }
    return out.items;
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
    return checkFilledReport(alloc, in).violations;
}

const FilledCheck = struct {
    violations: []const drc.Violation,
    plane_fills: []const pour.NetFills,
};

fn checkFilledReport(alloc: std.mem.Allocator, in: CopperCheck) FilledCheck {
    const filled = filledTopology(alloc, in) catch return .{
        .violations = drc.check(alloc, in.placement, in.routed, in.clearance) catch &.{},
        .plane_fills = &.{},
    };
    const base = drc.checkWithZones(alloc, in.placement, in.routed, in.clearance, filled.zones) catch &.{};
    var out: std.ArrayList(drc.Violation) = .empty;
    out.appendSlice(alloc, base) catch return .{ .violations = base, .plane_fills = filled.plane_fills };
    drc_return_path.check(alloc, &out, in.placement, in.routed, filled.zones) catch
        return .{ .violations = base, .plane_fills = filled.plane_fills };
    return .{ .violations = out.items, .plane_fills = filled.plane_fills };
}

/// Reduce every declared plane/pour and hand-authored zone to the exact kept
/// fill components the Gerber uses. The DRC topology graph receives one node
/// per component (and its holes), never one outline-wide conductor.
const FilledTopology = struct {
    zones: []const drc.TopologyZone,
    plane_fills: []const pour.NetFills,
};

fn filledTopology(alloc: std.mem.Allocator, in: CopperCheck) std.mem.Allocator.Error!FilledTopology {
    var out: std.ArrayList(drc.TopologyZone) = .empty;
    var plane_fills: std.ArrayList(pour.NetFills) = .empty;
    var component: u64 = 1;
    const physical_tracks = try path_copper.tracks(alloc, in.routed);
    const copper = pour.Copper{ .tracks = physical_tracks, .vias = in.routed.vias, .zones = in.zones };
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
    return .{
        .zones = try out.toOwnedSlice(alloc),
        .plane_fills = try plane_fills.toOwnedSlice(alloc),
    };
}

/// Append the net-open connectivity violations to the geometric ones. Fail-open:
/// on any allocation failure the geometric list rides through unchanged (a
/// partial DRC beats none).
fn withNetOpenReport(
    alloc: std.mem.Allocator,
    in: CopperCheck,
    geom: []const drc.Violation,
    plane_fills: []const pour.NetFills,
) CheckReport {
    const empty: net_open.Report = .{ .violations = &.{}, .connectivity = &.{} };
    const tracks = connectivityTracks(alloc, in.routed) catch return .{ .violations = geom, .net_report = empty };
    const report = net_open.checkWithConnectivity(alloc, in.placement, .{ .tracks = tracks, .vias = in.routed.vias, .zones = in.zones }, in.base_edge, plane_fills) catch
        return .{ .violations = geom, .net_report = empty };
    if (report.violations.len == 0) return .{ .violations = geom, .net_report = report };
    var all: std.ArrayList(drc.Violation) = .empty;
    all.appendSlice(alloc, geom) catch return .{ .violations = geom, .net_report = report };
    all.appendSlice(alloc, report.violations) catch return .{ .violations = geom, .net_report = report };
    return .{ .violations = all.items, .net_report = report };
}

/// A persisted RF path intentionally omits its solver chords: the compact
/// sample chain is the copper authority rendered and fabricated as one swept
/// polygon. Reconstruct those chords only for connectivity when no ordinary
/// track remains on that net. Geometry DRC keeps the polygon proof instead of
/// reclassifying its implementation samples as editable track segments.
fn connectivityTracks(alloc: std.mem.Allocator, r: router.RouteResult) std.mem.Allocator.Error![]const router.Track {
    return path_copper.tracks(alloc, r);
}
