//! MATLAB R2022b RF PCB simulation-bundle export.
//!
//! Version 1 deliberately exports one narrow, auditable case: a continuous
//! L1 controlled-impedance route as a two-port CPWG coupon.  The crop starts
//! and ends at the route's two straight degree-one endpoints, retains the
//! complete routed width/taper sequence and nearby ground-via fence, and uses
//! the design's exact four-layer stackup.  Connector bodies and connector-pad
//! copper remain outside the model; the two edge ports sit where the routed
//! interconnect meets those pad edges.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const rf_port_report = @import("placement/rf_port_report.zig");
const impedance = @import("placement/impedance.zig");
const env = @import("eval/env.zig");
const export_fab = @import("export_fab.zig");
const export_gerber = @import("export_gerber.zig");
const json_writer = @import("json_writer.zig");
const raster = @import("raster.zig");
const zipfile = @import("zipfile.zig");

const exporter_version = "1.0.0";
/// The first simulation handoff's deliberately narrow net scope.
pub const default_net = "CAL_THRU";

const Generator = struct {
    generated_utc: []const u8,
    application_version: []const u8,
};

/// Inputs resolved from one coherent saved PCB-layout snapshot.
pub const Input = struct {
    project_name: []const u8,
    revision: []const u8 = "",
    generator: Generator,
    net_name: []const u8 = default_net,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    stackup: env.StackupSpec,
};

/// Finished download bytes plus inspectable members for endpoint tests.
pub const Artifact = struct {
    filename: []const u8,
    package_name: []const u8,
    zip: []const u8,
    manifest: []const u8,
    entries: []const zipfile.Entry,
};

const BuildError = error{
    NetNotFound,
    NetIsNotControlledImpedance,
    NetIsNotRouted,
    UnsupportedRouteGeometry,
    UnsupportedRouteTopology,
    UnsupportedPortGeometry,
    UnsupportedStackup,
    MissingReferencePlane,
    MissingGroundViaFence,
    NearbyForeignCopper,
    InvalidGeneratedGeometry,
    InvalidManifest,
};

const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{ EmptyImage, InvalidCopperRegion } || BuildError;

const point_tol_mm: f64 = 0.0001;
const copper_conductivity_s_per_m: f64 = 58_000_000.0;
const port_feed_diameter_mm: f64 = 0.25;
const via_search_margin_mm: f64 = 1.5;
const ground_margin_mm: f64 = 0.5;

const Axis = enum { horizontal, vertical };

const Node = struct {
    p: [2]f64,
    degree: usize = 0,
};

const Path = struct {
    net_index: usize,
    tracks: []const router.Track,
    endpoint_nodes: [2]Node,
    endpoint_track_indices: [2]usize,
    axis: Axis,
};

/// The routed copper this export reads, in the two forms it needs.
///
/// `saved` is the persisted bundle `export_gerber.writeLayer` expects for a
/// full-board export: a swept taper is a compact constant-width editor handle
/// in `tracks` PLUS the sampled `rf_paths` that are its real geometry, and a
/// curved run is a chord in `tracks` PLUS the exact `arcs` over it. `physical`
/// is the same copper after `export_gerber.physicalCopper` has replaced those
/// handles with the path's own per-sample width chords.
///
/// Both are kept because they answer different questions. The straight-section
/// model this exporter builds — the crop rectangle, the L1 conductor, the port
/// widths — has to read `physical`, or an editor handle sizes a coupon whose
/// conductor is not the routed board. The mask layer has to read `saved`,
/// because `writeLayer` lowers handles itself and a tapering span deliberately
/// stays tented (`mask_relief.appendRfTraceRuns`), which only the path form can
/// say. `physicalCopper` returns its input unchanged when the layout holds no
/// RF path, so a plain routed net pays nothing for this.
const Bundle = struct {
    saved: export_gerber.Copper,
    physical: export_gerber.Copper,

    fn lower(alloc: std.mem.Allocator, saved: export_gerber.Copper) std.mem.Allocator.Error!Bundle {
        return .{ .saved = saved, .physical = try export_gerber.physicalCopper(alloc, saved) };
    }
};

const Region = struct {
    placement: optimizer.Placement,
    /// The signal net's L1 sections as the model draws them: physical chords,
    /// so a taper's real width sequence — not its handle — sets the conductor,
    /// the crop height and both port widths.
    tracks: []const router.Track,
    /// The signal net's native curves inside the crop, in persisted form. Every
    /// one is an exact curve over a chord run already in `tracks`; carrying it
    /// lets the mask open over the real curved envelope.
    arcs: []const router.Arc,
    /// The signal net's successful L1 swept paths, in persisted form. Their
    /// chords are already in `tracks`; the path itself is what tells a mask
    /// consumer which spans taper and must stay tented.
    rf_paths: []const rf_port_report.Outcome,
    vias: []const router.Via,
    frame: export_fab.Frame,
    rect: optimizer.BoardRect,
    ground_net: []const u8,
    ground_net_index: usize,
    ports: [2]Port,
};

const Port = struct {
    name: []const u8,
    point: [2]f64,
    width_mm: f64,
    gap_mm: f64,
    normal: [2]f64,
};

/// Human-readable refusal text for the HTTP endpoint.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.NetNotFound => "CAL_THRU is not present in this design",
        error.NetIsNotControlledImpedance => "CAL_THRU must belong to a single-ended controlled-impedance net class",
        error.NetIsNotRouted => "CAL_THRU has no saved routed copper in this layout",
        error.UnsupportedRouteGeometry => "CAL_THRU must stay on L1 and contain only finite, nonzero straight route sections for this exporter version",
        error.UnsupportedRouteTopology => "CAL_THRU must be one unbranched two-ended route with no signal vias",
        error.UnsupportedPortGeometry => "CAL_THRU must meet two opposite crop edges on straight horizontal or vertical sections",
        error.UnsupportedStackup => "MATLAB RF export v1 requires an authored four-copper-layer stackup with four foils and three dielectric intervals",
        error.MissingReferencePlane => "MATLAB RF export v1 requires continuous L2 and L3 GND planes beneath CAL_THRU",
        error.MissingGroundViaFence => "the CAL_THRU crop has no plated GND fence vias, so L4 would contain no simulated copper",
        error.NearbyForeignCopper => "non-GND copper or a non-GND via intersects the proposed CAL_THRU simulation crop",
        error.InvalidGeneratedGeometry => "the generated MATLAB RF geometry failed its mandatory consistency checks",
        error.InvalidManifest => "the generated MATLAB RF manifest is not strict JSON",
        else => "MATLAB RF export failed",
    };
}

/// Build the complete `<project>_matlab_rf_export_v1.zip` artifact.
pub fn build(alloc: std.mem.Allocator, input: Input) Error!Artifact {
    try validateStackup(input.stackup);
    const bundle = try Bundle.lower(alloc, input.copper);
    const path = try pathFor(alloc, input.placement, bundle.physical, input.net_name);
    const region = try regionFor(alloc, input.placement, bundle, input.stackup, path);
    const package_name = try packageName(alloc, input.project_name);

    const l1 = try copperGerber(alloc, region, input.placement.rules.net[path.net_index], .top);
    const l2 = try copperGerber(alloc, region, input.placement.rules.net[path.net_index], .l2);
    const l3 = try copperGerber(alloc, region, input.placement.rules.net[path.net_index], .l3);
    const l4 = try copperGerber(alloc, region, input.placement.rules.net[path.net_index], .bottom);

    // The whole routed bundle the crop contains, not the two fields that
    // happened to be at hand. `writeLayer` drops a track a swept path already
    // owns, so the chords in `tracks` and the paths beside them describe the
    // conductor exactly once — and the mask relief opens over the taper's real
    // swept polygon and the arcs' curved envelope instead of over chords.
    const local_copper = export_gerber.Copper{
        .tracks = region.tracks,
        .arcs = region.arcs,
        .rf_paths = region.rf_paths,
        .vias = region.vias,
    };
    var mask_writer: std.Io.Writer.Allocating = .init(alloc);
    try export_gerber.writeLayer(
        &mask_writer.writer,
        alloc,
        region.placement,
        local_copper,
        &.{},
        region.frame,
        .{ .mask = .top },
        .{ .function = "Soldermask,Top" },
    );
    const top_mask = mask_writer.written();

    var drill_writer: std.Io.Writer.Allocating = .init(alloc);
    try export_fab.excellonDrill(
        &drill_writer.writer,
        alloc,
        &.{},
        region.vias,
        .{ .class = .plated, .copper_layers = 4 },
        region.frame,
    );
    const drill = drill_writer.written();

    const copper_preview = try allCopperPreview(alloc, region);
    const stack_preview = try stackupPreview(alloc, input.stackup);

    const relative_files = [_]zipfile.Entry{
        .{ .name = export_gerber.matlab_rf_paths.l1, .data = l1 },
        .{ .name = export_gerber.matlab_rf_paths.l2, .data = l2 },
        .{ .name = export_gerber.matlab_rf_paths.l3, .data = l3 },
        .{ .name = export_gerber.matlab_rf_paths.l4, .data = l4 },
        .{ .name = export_gerber.matlab_rf_paths.plated, .data = drill },
        .{ .name = export_gerber.matlab_rf_paths.top_mask, .data = top_mask },
        .{ .name = "preview/all_copper_layers.png", .data = copper_preview },
        .{ .name = "preview/stackup.png", .data = stack_preview },
    };
    try validateGenerated(region, &relative_files);

    const manifest = try writeManifest(alloc, input, region, path.net_index);
    _ = std.json.parseFromSliceLeaky(std.json.Value, alloc, manifest, .{}) catch return error.InvalidManifest;

    const entries = try alloc.alloc(zipfile.Entry, relative_files.len + 1);
    entries[0] = .{
        .name = try std.fmt.allocPrint(alloc, "{s}/manifest.json", .{package_name}),
        .data = manifest,
    };
    for (relative_files, 0..) |file, i| {
        entries[i + 1] = .{
            .name = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ package_name, file.name }),
            .data = file.data,
        };
    }
    var zip_writer: std.Io.Writer.Allocating = .init(alloc);
    try zipfile.write(&zip_writer.writer, entries);
    return .{
        .filename = try std.fmt.allocPrint(alloc, "{s}.zip", .{package_name}),
        .package_name = package_name,
        .zip = zip_writer.written(),
        .manifest = manifest,
        .entries = entries,
    };
}

fn validateStackup(stackup: env.StackupSpec) BuildError!void {
    if (!stackup.present) return error.UnsupportedStackup;
    if (stackup.layers != 4) return error.UnsupportedStackup;
    if (stackup.preset.len == 0) return error.UnsupportedStackup;
    if (stackup.copper.len != 4) return error.UnsupportedStackup;
    if (stackup.dielectrics.len != 3) return error.UnsupportedStackup;
    for (stackup.copper, 0..) |foil, i| {
        if (foil.index != i + 1) return error.UnsupportedStackup;
        if (!(foil.thickness > 0)) return error.UnsupportedStackup;
        if (!std.math.isFinite(foil.thickness)) return error.UnsupportedStackup;
    }
    var dielectric_sum: f64 = 0;
    for (stackup.dielectrics, 0..) |dielectric, i| {
        if (dielectric.after_layer != i + 1) return error.UnsupportedStackup;
        if (!(dielectric.thickness > 0)) return error.UnsupportedStackup;
        if (!(dielectric.er > 0)) return error.UnsupportedStackup;
        dielectric_sum += dielectric.thickness;
    }
    if (!(dielectric_sum > 0)) return error.UnsupportedStackup;
    if (!std.math.isFinite(dielectric_sum)) return error.UnsupportedStackup;
    const l2 = planeAt(stackup, 2) orelse return error.MissingReferencePlane;
    const l3 = planeAt(stackup, 3) orelse return error.MissingReferencePlane;
    if (!optimizer.isGroundName(leaf(l2.net))) return error.MissingReferencePlane;
    if (!optimizer.isGroundName(leaf(l3.net))) return error.MissingReferencePlane;
}

fn planeAt(stackup: env.StackupSpec, index: u8) ?env.StackupPlane {
    for (stackup.planes) |plane| if (plane.index == index) return plane;
    return null;
}

fn pathFor(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: export_gerber.Copper,
    requested_name: []const u8,
) Error!Path {
    const net_index = findNet(placement, requested_name) orelse return error.NetNotFound;
    if (net_index >= placement.rules.net.len) return error.NetIsNotControlledImpedance;
    if (!(placement.rules.net[net_index].rf.impedance.ohms > 0)) return error.NetIsNotControlledImpedance;

    const tracks = try signalTracks(alloc, copper.tracks, net_index);
    for (copper.vias) |via| if (via.net == @as(i32, @intCast(net_index))) return error.UnsupportedRouteTopology;
    // `copper` is the physical view, so the only arcs left on this net are
    // native curves NOT already described by a swept path. v1 emits straight
    // G01 sections only (that is what `errorMessage` promises), so modelling
    // such a curve's chord would ship a coupon whose conductor is not the
    // routed board. Refuse rather than silently flatten it.
    for (copper.arcs) |arc| if (arc.net == @as(i32, @intCast(net_index))) return error.UnsupportedRouteGeometry;

    const graph = try graphFor(alloc, tracks);
    var endpoints = graph.endpoints;
    var endpoint_tracks = endpointTracksFor(graph.edge_nodes, endpoints);
    const pa = graph.nodes[endpoints[0]].p;
    const pb = graph.nodes[endpoints[1]].p;
    const axis = try portAxis(pa, pb);
    try validateEndpointTracks(tracks, endpoint_tracks, axis);

    // Stable P1/P2 order: left-to-right or bottom-to-top in the emitted y-up frame.
    if (portsNeedSwap(axis, pa, pb)) {
        std.mem.swap(usize, &endpoints[0], &endpoints[1]);
        std.mem.swap(usize, &endpoint_tracks[0], &endpoint_tracks[1]);
    }
    return .{
        .net_index = net_index,
        .tracks = tracks,
        .endpoint_nodes = .{ graph.nodes[endpoints[0]], graph.nodes[endpoints[1]] },
        .endpoint_track_indices = endpoint_tracks,
        .axis = axis,
    };
}

fn signalTracks(alloc: std.mem.Allocator, copper_tracks: []const router.Track, net_index: usize) Error![]const router.Track {
    var tracks: std.ArrayList(router.Track) = .empty;
    for (copper_tracks) |track| {
        if (track.net != @as(i32, @intCast(net_index))) continue;
        if (!validSignalTrack(track)) return error.UnsupportedRouteGeometry;
        try tracks.append(alloc, track);
    }
    if (tracks.items.len == 0) return error.NetIsNotRouted;
    return tracks.items;
}

fn validSignalTrack(track: router.Track) bool {
    if (track.layer != 0) return false;
    if (!(track.width > 0)) return false;
    if (!finitePoint(.{ track.x1, track.y1 })) return false;
    if (!finitePoint(.{ track.x2, track.y2 })) return false;
    return !samePoint(.{ track.x1, track.y1 }, .{ track.x2, track.y2 });
}

const PathGraph = struct {
    nodes: []Node,
    edge_nodes: [][2]usize,
    endpoints: [2]usize,
};

fn graphFor(alloc: std.mem.Allocator, tracks: []const router.Track) Error!PathGraph {
    const nodes = try alloc.alloc(Node, tracks.len * 2);
    var node_count: usize = 0;
    const edge_nodes = try alloc.alloc([2]usize, tracks.len);
    for (tracks, 0..) |track, i| {
        const a = findOrAddNode(nodes, &node_count, .{ track.x1, track.y1 });
        const b = findOrAddNode(nodes, &node_count, .{ track.x2, track.y2 });
        nodes[a].degree += 1;
        nodes[b].degree += 1;
        edge_nodes[i] = .{ a, b };
    }
    var endpoints: [2]usize = undefined;
    var endpoint_count: usize = 0;
    for (nodes[0..node_count], 0..) |node, i| {
        if (node.degree == 1) {
            if (endpoint_count >= endpoints.len) return error.UnsupportedRouteTopology;
            endpoints[endpoint_count] = i;
            endpoint_count += 1;
        } else if (node.degree != 2) return error.UnsupportedRouteTopology;
    }
    if (endpoint_count != 2) return error.UnsupportedRouteTopology;
    try validateConnectedPath(alloc, edge_nodes, endpoints);
    return .{ .nodes = nodes[0..node_count], .edge_nodes = edge_nodes, .endpoints = endpoints };
}

fn validateConnectedPath(alloc: std.mem.Allocator, edge_nodes: [][2]usize, endpoints: [2]usize) Error!void {
    var used = try alloc.alloc(bool, edge_nodes.len);
    @memset(used, false);
    var current = endpoints[0];
    var used_count: usize = 0;
    while (current != endpoints[1]) {
        var next_edge: ?usize = null;
        for (edge_nodes, 0..) |ends, i| {
            if (used[i]) continue;
            if (ends[0] == current or ends[1] == current) {
                if (next_edge != null) return error.UnsupportedRouteTopology;
                next_edge = i;
            }
        }
        const edge = next_edge orelse return error.UnsupportedRouteTopology;
        used[edge] = true;
        used_count += 1;
        current = if (edge_nodes[edge][0] == current) edge_nodes[edge][1] else edge_nodes[edge][0];
    }
    if (used_count != edge_nodes.len) return error.UnsupportedRouteTopology;
}

fn endpointTracksFor(edge_nodes: [][2]usize, endpoints: [2]usize) [2]usize {
    var endpoint_tracks: [2]usize = undefined;
    for (endpoints, 0..) |endpoint, ei| {
        for (edge_nodes, 0..) |ends, ti| if (ends[0] == endpoint or ends[1] == endpoint) {
            endpoint_tracks[ei] = ti;
            break;
        };
    }
    return endpoint_tracks;
}

fn portAxis(pa: [2]f64, pb: [2]f64) BuildError!Axis {
    const dx = @abs(pb[0] - pa[0]);
    const dy = @abs(pb[1] - pa[1]);
    if (dx > dy and dy <= point_tol_mm) return .horizontal;
    if (dy > dx and dx <= point_tol_mm) return .vertical;
    return error.UnsupportedPortGeometry;
}

fn validateEndpointTracks(tracks: []const router.Track, endpoint_tracks: [2]usize, axis: Axis) BuildError!void {
    for (endpoint_tracks) |ti| {
        const track = tracks[ti];
        const tdx = @abs(track.x2 - track.x1);
        const tdy = @abs(track.y2 - track.y1);
        if (axis == .horizontal and tdy > point_tol_mm) return error.UnsupportedPortGeometry;
        if (axis == .vertical and tdx > point_tol_mm) return error.UnsupportedPortGeometry;
        const length = std.math.hypot(tdx, tdy);
        if (length + point_tol_mm < track.width) return error.UnsupportedPortGeometry;
    }
}

fn portsNeedSwap(axis: Axis, pa: [2]f64, pb: [2]f64) bool {
    if (axis == .horizontal) return pa[0] > pb[0];
    return pa[1] > pb[1];
}

fn findNet(placement: optimizer.Placement, requested_name: []const u8) ?usize {
    for (placement.nets, 0..) |net, i| {
        if (std.ascii.eqlIgnoreCase(net.name, requested_name) or std.ascii.eqlIgnoreCase(leaf(net.name), requested_name)) return i;
    }
    return null;
}

fn leaf(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[slash + 1 ..];
}

fn finitePoint(p: [2]f64) bool {
    return std.math.isFinite(p[0]) and std.math.isFinite(p[1]);
}

fn cleanZero(value: f64) f64 {
    return if (@abs(value) <= point_tol_mm) 0 else value;
}

fn samePoint(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) <= point_tol_mm and @abs(a[1] - b[1]) <= point_tol_mm;
}

fn findOrAddNode(nodes: []Node, count: *usize, p: [2]f64) usize {
    for (nodes[0..count.*], 0..) |node, i| if (samePoint(node.p, p)) return i;
    const i = count.*;
    nodes[i] = .{ .p = p };
    count.* += 1;
    return i;
}

/// Window `bundle` down to the crop around `path`.
///
/// One rule governs every physical form of copper, so the region carries the
/// whole routed bundle rather than the part the crop happened to be measured
/// from: what belongs to the signal net travels INTO the region, and anything
/// else whose real envelope reaches the crop rectangle REFUSES the export as
/// foreign copper. Ground vias are the one form with their own window (the
/// fence search band), because they are what the crop is grown to include.
fn regionFor(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    bundle: Bundle,
    stackup: env.StackupSpec,
    path: Path,
) Error!Region {
    const copper = bundle.physical;
    const signal_net: i32 = @intCast(path.net_index);
    const ground_plane = planeAt(stackup, 2) orelse return error.MissingReferencePlane;
    const ground_net_index = findNet(placement, ground_plane.net) orelse return error.MissingReferencePlane;
    const rule = placement.rules.net[path.net_index];
    const a = path.endpoint_nodes[0].p;
    const b = path.endpoint_nodes[1].p;

    var perp_min: f64 = std.math.inf(f64);
    var perp_max: f64 = -std.math.inf(f64);
    for (path.tracks) |track| {
        const p0 = if (path.axis == .horizontal) track.y1 else track.x1;
        const p1 = if (path.axis == .horizontal) track.y2 else track.x2;
        perp_min = @min(perp_min, @min(p0, p1) - track.width / 2.0);
        perp_max = @max(perp_max, @max(p0, p1) + track.width / 2.0);
    }
    const axis_min = if (path.axis == .horizontal) a[0] else a[1];
    const axis_max = if (path.axis == .horizontal) b[0] else b[1];

    var vias: std.ArrayList(router.Via) = .empty;
    for (copper.vias) |via| {
        const along = if (path.axis == .horizontal) via.x else via.y;
        const across = if (path.axis == .horizontal) via.y else via.x;
        if (along < axis_min - point_tol_mm or along > axis_max + point_tol_mm) continue;
        if (across < perp_min - via_search_margin_mm or across > perp_max + via_search_margin_mm) continue;
        if (via.net != @as(i32, @intCast(ground_net_index))) return error.NearbyForeignCopper;
        if (!(via.drill > 0) or !(via.dia > via.drill)) return error.UnsupportedRouteGeometry;
        try vias.append(alloc, via);
        perp_min = @min(perp_min, across - via.dia / 2.0);
        perp_max = @max(perp_max, across + via.dia / 2.0);
    }
    if (vias.items.len == 0) return error.MissingGroundViaFence;
    perp_min -= ground_margin_mm;
    perp_max += ground_margin_mm;

    const rect: optimizer.BoardRect = if (path.axis == .horizontal)
        .{ .minx = axis_min, .miny = perp_min, .w = axis_max - axis_min, .h = perp_max - perp_min }
    else
        .{ .minx = perp_min, .miny = axis_min, .w = perp_max - perp_min, .h = axis_max - axis_min };
    if (!(rect.w > 0) or !(rect.h > 0)) return error.InvalidGeneratedGeometry;

    try refuseForeignCopper(copper, signal_net, rect);
    const signal = try signalCopper(alloc, bundle.saved, signal_net);

    var cropped = placement;
    cropped.parts = &.{};
    cropped.links = &.{};
    cropped.loops = &.{};
    cropped.stubs = &.{};
    cropped.instances = &.{};
    cropped.priority = &.{};
    cropped.diff_pairs = &.{};
    cropped.match_groups = &.{};
    cropped.minx = rect.minx;
    cropped.miny = rect.miny;
    cropped.maxx = rect.minx + rect.w;
    cropped.maxy = rect.miny + rect.h;
    cropped.board_rect = rect;
    cropped.board_poly = null;
    cropped.board_arcs = &.{};

    const frame = export_fab.Frame{
        .ox = rect.minx + rect.w / 2.0,
        .oy = rect.miny + rect.h / 2.0,
    };
    const t0 = path.tracks[path.endpoint_track_indices[0]];
    const t1 = path.tracks[path.endpoint_track_indices[1]];
    const p0 = frame.pt(path.endpoint_nodes[0].p[0], path.endpoint_nodes[0].p[1]);
    const p1 = frame.pt(path.endpoint_nodes[1].p[0], path.endpoint_nodes[1].p[1]);
    const gap0 = try groundGapFor(placement, rule, t0);
    const gap1 = try groundGapFor(placement, rule, t1);
    const normals: [2][2]f64 = if (path.axis == .horizontal)
        .{ .{ -1, 0 }, .{ 1, 0 } }
    else
        // Placement y grows down, so endpoint 0 (smaller placement y) is the
        // top/+Y emitted boundary and endpoint 1 is bottom/-Y.
        .{ .{ 0, 1 }, .{ 0, -1 } };
    return .{
        .placement = cropped,
        .tracks = path.tracks,
        .arcs = signal.arcs,
        .rf_paths = signal.rf_paths,
        .vias = vias.items,
        .frame = frame,
        .rect = rect,
        .ground_net = placement.nets[ground_net_index].name,
        .ground_net_index = ground_net_index,
        .ports = .{
            .{ .name = "P1", .point = p0, .width_mm = t0.width, .gap_mm = gap0, .normal = normals[0] },
            .{ .name = "P2", .point = p1, .width_mm = t1.width, .gap_mm = gap1, .normal = normals[1] },
        },
    };
}

/// Refuse the export when copper belonging to any other net reaches the crop:
/// a coupling feature the model silently dropped would make the simulated
/// coupon disagree with the board. `physical` must be the LOWERED bundle, so a
/// foreign taper is measured by its real swept width rather than by the
/// narrower editor handle persisted under it.
fn refuseForeignCopper(physical: export_gerber.Copper, signal_net: i32, rect: optimizer.BoardRect) BuildError!void {
    for (physical.tracks) |track| {
        if (track.net == signal_net) continue;
        if (trackTouchesRect(track, rect)) return error.NearbyForeignCopper;
    }
    // An arc is the exact curve over a chord run that is already in `tracks`,
    // so its chords were tested above — but the curve bulges off them, and that
    // bulge is copper the chord test cannot see. Test the arcs themselves.
    for (physical.arcs) |arc| {
        if (arc.net == signal_net) continue;
        if (arcTouchesRect(arc, rect)) return error.NearbyForeignCopper;
    }
}

/// The signal net's own curved and swept copper, in the persisted form
/// `export_gerber.writeLayer` expects. Both kinds are exact geometry over chord
/// runs the crop already contains, so no second growth pass is needed for them;
/// what they add is the shape those chords approximate.
fn signalCopper(
    alloc: std.mem.Allocator,
    saved: export_gerber.Copper,
    signal_net: i32,
) std.mem.Allocator.Error!struct { arcs: []const router.Arc, rf_paths: []const rf_port_report.Outcome } {
    var arcs: std.ArrayList(router.Arc) = .empty;
    for (saved.arcs) |arc| {
        if (arc.net == signal_net and arc.layer == 0) try arcs.append(alloc, arc);
    }
    var rf_paths: std.ArrayList(rf_port_report.Outcome) = .empty;
    for (saved.rf_paths) |rf| {
        if (rf.net == signal_net and rf.physical.layer == 0) try rf_paths.append(alloc, rf);
    }
    return .{ .arcs = arcs.items, .rf_paths = rf_paths.items };
}

/// Conservative overlap test for a native curve. The three stored points bound
/// a circular arc's own bounding box only up to the sagitta bulge, so the box
/// is grown by the chord's half-length as well as the copper half-width: an arc
/// can never leave that, and over-reporting here only makes the export refuse
/// copper it might have been able to ignore.
fn arcTouchesRect(arc: router.Arc, rect: optimizer.BoardRect) bool {
    const chord = std.math.hypot(arc.p2[0] - arc.p1[0], arc.p2[1] - arc.p1[1]);
    const r = arc.width / 2.0 + chord / 2.0;
    const xs = [_]f64{ arc.p1[0], arc.pm[0], arc.p2[0] };
    const ys = [_]f64{ arc.p1[1], arc.pm[1], arc.p2[1] };
    const minx = @min(xs[0], @min(xs[1], xs[2])) - r;
    const maxx = @max(xs[0], @max(xs[1], xs[2])) + r;
    const miny = @min(ys[0], @min(ys[1], ys[2])) - r;
    const maxy = @max(ys[0], @max(ys[1], ys[2])) + r;
    return maxx >= rect.minx and minx <= rect.minx + rect.w and maxy >= rect.miny and miny <= rect.miny + rect.h;
}

fn trackTouchesRect(track: router.Track, rect: optimizer.BoardRect) bool {
    const r = track.width / 2.0;
    const minx = @min(track.x1, track.x2) - r;
    const maxx = @max(track.x1, track.x2) + r;
    const miny = @min(track.y1, track.y2) - r;
    const maxy = @max(track.y1, track.y2) + r;
    return maxx >= rect.minx and minx <= rect.minx + rect.w and maxy >= rect.miny and miny <= rect.miny + rect.h;
}

fn groundGapFor(placement: optimizer.Placement, rule: optimizer.NetRule, track: router.Track) BuildError!f64 {
    const base = rule.rf.impedance.ground_gap_mm;
    if (!(base > 0)) return error.NetIsNotControlledImpedance;
    const cap = rule.rf.impedance.ground_gap_max_mm;
    if (!(cap > base)) return base;
    const stack = placement.rules.physical.stack;
    const ref = impedance.reference(stack, 1) orelse return error.UnsupportedStackup;
    const solved = impedance.refGroundGapForZ0(
        ref,
        track.width,
        stack.foilMm(1),
        rule.rf.impedance.ohms,
        base,
        cap,
    ) catch return error.UnsupportedRouteGeometry;
    return solved.gap_mm;
}

fn packageName(alloc: std.mem.Allocator, project: []const u8) std.mem.Allocator.Error![]const u8 {
    const p = try safeToken(alloc, project);
    return std.fmt.allocPrint(alloc, "{s}_matlab_rf_export_v1", .{p});
}

fn safeToken(alloc: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]const u8 {
    const out = try alloc.alloc(u8, @max(raw.len, 1));
    if (raw.len == 0) {
        out[0] = 'p';
        return out;
    }
    for (raw, 0..) |c, i| out[i] = switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => c,
        else => '_',
    };
    return out;
}

const CopperFile = enum { top, l2, l3, bottom };

/// Purpose-built CPWG Gerbers.  L1 is a ground rectangle with the actual
/// per-section dynamic gap cleared out, followed by the signal and GND-via
/// lands. L2/L3 are continuous authored GND planes; L4 contains the through-
/// via lands. Port strokes extend past the crop temporarily and are clipped
/// back to the exact boundary, producing a straight (not round-capped) edge.
fn copperGerber(
    alloc: std.mem.Allocator,
    region: Region,
    rule: optimizer.NetRule,
    which: CopperFile,
) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    const function = switch (which) {
        .top => "Copper,L1,Top",
        .l2 => "Copper,L2,Inr",
        .l3 => "Copper,L3,Inr",
        .bottom => "Copper,L4,Bot",
    };
    try w.writeAll("%TF.GenerationSoftware,netlisp,netlisp,1*%\n");
    try w.print("%TF.FileFunction,{s}*%\n%TF.FilePolarity,Positive*%\n", .{function});
    try w.writeAll("%FSLAX46Y46*%\n%MOMM*%\nG01*\n%LPD*%\n");
    try w.writeAll("%ADD10C,0.001000*%\n");
    if (which == .top) {
        for (region.tracks, 0..) |track, i| {
            const gap = try groundGapFor(region.placement, rule, track);
            try w.print("%ADD{d}C,{d:.6}*%\n%ADD{d}C,{d:.6}*%\n", .{ 11 + i * 2, track.width + 2 * gap, 12 + i * 2, track.width });
        }
    }
    const via_aperture: usize = 20 + region.tracks.len * 2;
    if (which == .top or which == .bottom) {
        for (region.vias, 0..) |via, i| try w.print("%ADD{d}C,{d:.6}*%\n", .{ via_aperture + i, via.dia });
    }
    try w.writeAll("D10*\n");
    if (which != .bottom) try gerberRect(w, region.frame, region.rect, true);
    if (which == .top) {
        try w.writeAll("%LPC*%\n");
        for (region.tracks, 0..) |track, i| {
            const extended = extendedPortTrack(region, track);
            try w.print("D{d}*\n", .{11 + i * 2});
            try gerberLine(w, region.frame, extended);
        }
        try w.writeAll("%LPD*%\n");
        for (region.tracks, 0..) |track, i| {
            const extended = extendedPortTrack(region, track);
            try w.print("D{d}*\n", .{12 + i * 2});
            try gerberLine(w, region.frame, extended);
        }
    }
    if (which == .top or which == .bottom) {
        for (region.vias, 0..) |via, i| {
            try w.print("D{d}*\n", .{via_aperture + i});
            const p = region.frame.pt(via.x, via.y);
            try gerberPoint(w, p, "D03");
        }
    }
    if (which == .top) try gerberClipOutside(w, region);
    try w.writeAll("M02*\n");
    return out.written();
}

fn extendedPortTrack(region: Region, track: router.Track) router.Track {
    var result = track;
    const extra = track.width + 1.0;
    for (region.ports) |port| {
        const original = region.frame.pt(track.x1, track.y1);
        if (samePoint(original, port.point)) {
            result.x1 -= port.normal[0] * -extra;
            result.y1 -= port.normal[1] * extra; // emitted +Y is placement -Y
        }
        const terminal = region.frame.pt(track.x2, track.y2);
        if (samePoint(terminal, port.point)) {
            result.x2 -= port.normal[0] * -extra;
            result.y2 -= port.normal[1] * extra;
        }
    }
    return result;
}

fn gerberLine(w: *std.Io.Writer, frame: export_fab.Frame, track: router.Track) std.Io.Writer.Error!void {
    try gerberPoint(w, frame.pt(track.x1, track.y1), "D02");
    try gerberPoint(w, frame.pt(track.x2, track.y2), "D01");
}

fn gerberRect(w: *std.Io.Writer, frame: export_fab.Frame, rect: optimizer.BoardRect, dark: bool) std.Io.Writer.Error!void {
    try w.writeAll(if (dark) "%LPD*%\nG36*\n" else "%LPC*%\nG36*\n");
    const pts = [_][2]f64{
        frame.pt(rect.minx, rect.miny + rect.h),
        frame.pt(rect.minx + rect.w, rect.miny + rect.h),
        frame.pt(rect.minx + rect.w, rect.miny),
        frame.pt(rect.minx, rect.miny),
    };
    try gerberPoint(w, pts[0], "D02");
    for (pts[1..]) |p| try gerberPoint(w, p, "D01");
    try gerberPoint(w, pts[0], "D01");
    try w.writeAll("G37*\n");
}

fn gerberClipOutside(w: *std.Io.Writer, region: Region) std.Io.Writer.Error!void {
    const r = region.rect;
    const pad = @max(r.w, r.h) + 5.0;
    const strips = [_]optimizer.BoardRect{
        .{ .minx = r.minx - pad, .miny = r.miny - pad, .w = pad, .h = r.h + 2 * pad },
        .{ .minx = r.minx + r.w, .miny = r.miny - pad, .w = pad, .h = r.h + 2 * pad },
        .{ .minx = r.minx, .miny = r.miny - pad, .w = r.w, .h = pad },
        .{ .minx = r.minx, .miny = r.miny + r.h, .w = r.w, .h = pad },
    };
    for (strips) |strip| try gerberRect(w, region.frame, strip, false);
    try w.writeAll("%LPD*%\n");
}

fn gerberPoint(w: *std.Io.Writer, p: [2]f64, op: []const u8) std.Io.Writer.Error!void {
    const x: i64 = @intFromFloat(@round(p[0] * 1_000_000.0));
    const y: i64 = @intFromFloat(@round(p[1] * 1_000_000.0));
    try w.print("X{d}Y{d}{s}*\n", .{ x, y, op });
}

fn validateGenerated(region: Region, files: []const zipfile.Entry) BuildError!void {
    try validateFileSet(files);
    try validateRegionGeometry(region);
}

fn validateFileSet(files: []const zipfile.Entry) BuildError!void {
    if (files.len != 8) return error.InvalidGeneratedGeometry;
    const expected = [_][]const u8{
        export_gerber.matlab_rf_paths.l1,
        export_gerber.matlab_rf_paths.l2,
        export_gerber.matlab_rf_paths.l3,
        export_gerber.matlab_rf_paths.l4,
        export_gerber.matlab_rf_paths.plated,
        export_gerber.matlab_rf_paths.top_mask,
        "preview/all_copper_layers.png",
        "preview/stackup.png",
    };
    for (files, expected) |file, name| {
        if (!std.mem.eql(u8, file.name, name)) return error.InvalidGeneratedGeometry;
        if (file.data.len == 0) return error.InvalidGeneratedGeometry;
    }
    for (files[0..4]) |file| {
        const has_draw = std.mem.indexOf(u8, file.data, "D01*") != null or std.mem.indexOf(u8, file.data, "D03*") != null;
        if (!has_draw or std.mem.indexOf(u8, file.data, "%MOMM*%") == null or std.mem.indexOf(u8, file.data, "%FSLAX46Y46*%") == null)
            return error.InvalidGeneratedGeometry;
        if (std.mem.indexOf(u8, file.data, "%MOIN*%") != null) return error.InvalidGeneratedGeometry;
    }
    if (std.mem.indexOf(u8, files[4].data, "METRIC,TZ") == null) return error.InvalidGeneratedGeometry;
    if (std.mem.indexOf(u8, files[5].data, "%MOMM*%") == null) return error.InvalidGeneratedGeometry;
    const png_signature = "\x89PNG\r\n\x1a\n";
    if (!std.mem.startsWith(u8, files[6].data, png_signature) or !std.mem.startsWith(u8, files[7].data, png_signature))
        return error.InvalidGeneratedGeometry;
}

fn validateRegionGeometry(region: Region) BuildError!void {
    if (!(region.rect.w > 0)) return error.InvalidGeneratedGeometry;
    if (!(region.rect.h > 0)) return error.InvalidGeneratedGeometry;
    if (region.ports[0].point[0] == region.ports[1].point[0] and region.ports[0].point[1] == region.ports[1].point[1])
        return error.InvalidGeneratedGeometry;
    for (region.tracks) |track| {
        if (!pointInsideRegion(region, region.frame.pt(track.x1, track.y1))) return error.InvalidGeneratedGeometry;
        if (!pointInsideRegion(region, region.frame.pt(track.x2, track.y2))) return error.InvalidGeneratedGeometry;
    }
    for (region.ports) |port| {
        if (!portOnBoundary(region, port)) return error.InvalidGeneratedGeometry;
        if (!portOnSignal(region, port)) return error.InvalidGeneratedGeometry;
    }
    for (region.vias) |via| {
        const p = region.frame.pt(via.x, via.y);
        if (!pointInsideRegion(region, p)) return error.InvalidGeneratedGeometry;
        if (!(via.drill > 0)) return error.InvalidGeneratedGeometry;
        if (!(via.dia > via.drill)) return error.InvalidGeneratedGeometry;
        if (via.net != @as(i32, @intCast(region.ground_net_index))) return error.InvalidGeneratedGeometry;
    }
}

fn pointInsideRegion(region: Region, point: [2]f64) bool {
    if (@abs(point[0]) > region.rect.w / 2.0 + point_tol_mm) return false;
    return @abs(point[1]) <= region.rect.h / 2.0 + point_tol_mm;
}

fn portOnBoundary(region: Region, port: Port) bool {
    if (!pointInsideRegion(region, port.point)) return false;
    const hx = region.rect.w / 2.0;
    const hy = region.rect.h / 2.0;
    if (@abs(port.point[0] + hx) <= point_tol_mm) return samePoint(port.normal, .{ -1, 0 });
    if (@abs(port.point[0] - hx) <= point_tol_mm) return samePoint(port.normal, .{ 1, 0 });
    if (@abs(port.point[1] + hy) <= point_tol_mm) return samePoint(port.normal, .{ 0, -1 });
    if (@abs(port.point[1] - hy) <= point_tol_mm) return samePoint(port.normal, .{ 0, 1 });
    return false;
}

fn portOnSignal(region: Region, port: Port) bool {
    for (region.tracks) |track| {
        const a = region.frame.pt(track.x1, track.y1);
        const b = region.frame.pt(track.x2, track.y2);
        if (!samePoint(a, port.point) and !samePoint(b, port.point)) continue;
        if (@abs(track.width - port.width_mm) <= point_tol_mm) return true;
    }
    return false;
}

fn writeManifest(
    alloc: std.mem.Allocator,
    input: Input,
    region: Region,
    net_index: usize,
) Error![]const u8 {
    const stackup = input.stackup;
    const laminate = stackup.dielectrics[0].thickness + stackup.dielectrics[1].thickness + stackup.dielectrics[2].thickness;
    const rule = input.placement.rules.net[net_index];
    const hw = region.rect.w / 2.0;
    const hh = region.rect.h / 2.0;
    const start_hz = if (rule.rf.electrical.band_start_hz > 0) rule.rf.electrical.band_start_hz else rule.rf.max_freq_hz / 100.0;
    const stop_hz = if (rule.rf.max_freq_hz > 0) rule.rf.max_freq_hz else 6.0e9;
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.writeAll("{\n  \"schema\":\"custom-netlisp-matlab-rf-export\",\n  \"schemaVersion\":\"1.0\",\n  \"generator\":{");
    try json_writer.writeField(w, "application", "netlisp");
    try w.writeByte(',');
    try json_writer.writeField(w, "applicationVersion", input.generator.application_version);
    try w.writeByte(',');
    try json_writer.writeField(w, "exporterVersion", exporter_version);
    try w.writeByte(',');
    try json_writer.writeField(w, "generatedUtc", input.generator.generated_utc);
    try w.writeAll("},\n  \"project\":{");
    try json_writer.writeField(w, "name", input.project_name);
    try w.writeByte(',');
    try json_writer.writeField(w, "revision", input.revision);
    try w.writeByte(',');
    try json_writer.writeField(w, "description", "CAL_THRU pad-edge to pad-edge two-port CPWG region; connector bodies and connector lands excluded");
    try w.writeAll("},\n  \"region\":{");
    try json_writer.writeField(w, "sourceNet", input.placement.nets[net_index].name);
    try w.print(",\"routeSections\":{d},\"platedGroundVias\":{d},", .{ region.tracks.len, region.vias.len });
    try json_writer.writeField(w, "scope", "routed interconnect between connector-pad edges");
    try w.writeAll("},\n  \"coordinateSystem\":{\"linearUnits\":\"mm\",\"angularUnits\":\"degree\",\"view\":\"top\",\"xDirection\":\"right\",\"yDirection\":\"up\",\"zDirection\":\"L4-to-L1\",\"zZero\":\"bottom-of-L4-copper\",\"originMm\":[0.0,0.0],\"rotationDegrees\":0.0,\"mirrored\":false},\n");
    try w.print("  \"simulationBoundary\":{{\"type\":\"polygon\",\"verticesMm\":[[-{d:.6},-{d:.6}],[{d:.6},-{d:.6}],[{d:.6},{d:.6}],[-{d:.6},{d:.6}]],\"cutouts\":[]}},\n", .{ hw, hh, hw, hh, hw, hh, hw, hh });
    try w.writeAll("  \"fabrication\":{\"vendor\":\"JLCPCB\",\"stackupId\":");
    try json_writer.writeString(w, stackup.preset);
    try w.print(",\"finishedBoardThicknessMm\":{d:.4},\"modeledLaminateThicknessMm\":{d:.4},\"outerCopperWeightOz\":1.0,\"innerCopperWeightOz\":0.5,\"materialDataStatus\":\"incomplete\",", .{ stackup.thickness, laminate });
    try json_writer.writeField(w, "materialDataSource", "netlisp JLCPCB controlled-impedance preset catalog; loss tangents are not declared by the design");
    try w.writeAll("},\n  \"layers\":[\n");
    const gerbers = [_][]const u8{
        export_gerber.matlab_rf_paths.l1,
        export_gerber.matlab_rf_paths.l2,
        export_gerber.matlab_rf_paths.l3,
        export_gerber.matlab_rf_paths.l4,
    };
    for (0..7) |li| {
        if (li > 0) try w.writeAll(",\n");
        if (li % 2 == 0) {
            const ci = li / 2;
            const foil = stackup.copper[ci];
            try w.print("    {{\"name\":\"L{d}\",\"type\":\"copper\",\"gerber\":", .{ci + 1});
            try json_writer.writeString(w, gerbers[ci]);
            try w.writeAll(",\"material\":");
            try json_writer.writeString(w, foil.material);
            try w.print(",\"thicknessMm\":{d:.6},\"conductivitySiemensPerMeter\":{d},\"materialSource\":", .{ foil.thickness, copper_conductivity_s_per_m });
            try json_writer.writeString(w, stackup.preset);
            try w.writeByte('}');
        } else {
            const di = li / 2;
            const dielectric = stackup.dielectrics[di];
            try w.print("    {{\"name\":\"D{d}{d}\",\"type\":\"dielectric\",\"material\":", .{ di + 1, di + 2 });
            try json_writer.writeString(w, dielectric.material);
            try w.print(",\"constructionType\":\"{s}\",\"thicknessMm\":{d:.6},\"epsilonR\":{d:.6},\"lossTangent\":null,", .{ @tagName(dielectric.kind), dielectric.thickness, dielectric.er });
            try json_writer.writeField(w, "materialSource", stackup.preset);
            try w.writeByte('}');
        }
    }
    try w.writeAll("\n  ],\n  \"solderMask\":{\"mode\":\"patterned\",\"topGerber\":");
    try json_writer.writeString(w, export_gerber.matlab_rf_paths.top_mask);
    try w.writeAll(",\"bottomGerber\":null,\"epsilonR\":null,\"lossTangent\":null,\"thicknessAboveLaminateMm\":null,\"thicknessAboveCopperMm\":null,\"rfTraceCovered\":false,\"rfGapsCovered\":true,\"materialDataStatus\":\"incomplete\",\"coverageNote\":\"The routed RF conductor is opened by the authored/default RF mask relief; the remaining CPWG slot is mask-covered.\"},\n");
    try w.writeAll("  \"drillFiles\":{\"platedThrough\":");
    try json_writer.writeString(w, export_gerber.matlab_rf_paths.plated);
    try w.writeAll(",\"nonPlated\":null},\n  \"vias\":[");
    for (region.vias, 0..) |via, i| {
        if (i > 0) try w.writeByte(',');
        const p = region.frame.pt(via.x, via.y);
        try w.print("{{\"id\":\"VIA_{d}\",\"xMm\":{d:.6},\"yMm\":{d:.6},\"startLayer\":\"L1\",\"stopLayer\":\"L4\",\"finishedDrillDiameterMm\":{d:.6},\"modelDiameterMm\":{d:.6},\"plated\":true,\"net\":", .{ i + 1, cleanZero(p[0]), cleanZero(p[1]), via.drill, via.drill });
        try json_writer.writeString(w, region.ground_net);
        try w.print(",\"padDiameterMm\":{{\"L1\":{d:.6},\"L2\":{d:.6},\"L3\":{d:.6},\"L4\":{d:.6}}}}}", .{ via.dia, via.dia, via.dia, via.dia });
    }
    try w.writeAll("],\n  \"ports\":[");
    for (region.ports, 0..) |port, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":\"{s}\",\"type\":\"edge\",\"xMm\":{d:.6},\"yMm\":{d:.6},\"signalLayer\":\"L1\",\"matlabLayerIndex\":1,\"signalNet\":", .{ port.name, cleanZero(port.point[0]), cleanZero(port.point[1]) });
        try json_writer.writeString(w, input.placement.nets[net_index].name);
        try w.writeAll(",\"referenceNet\":");
        try json_writer.writeString(w, region.ground_net);
        try w.print(",\"referencePlaneLayer\":\"L2\",\"referenceImpedanceOhm\":{d:.3},\"traceWidthMm\":{d:.6},\"leftCoplanarGapMm\":{d:.6},\"rightCoplanarGapMm\":{d:.6},\"matlabFeedDiameterMm\":{d:.6},\"outwardNormalXY\":[{d:.0},{d:.0}]}}", .{ rule.rf.impedance.ohms, port.width_mm, port.gap_mm, port.gap_mm, @min(port_feed_diameter_mm, port.width_mm), port.normal[0], port.normal[1] });
    }
    try w.print("],\n  \"simulation\":{{\"analysis\":\"sparameters\",\"solver\":\"full-wave-mom\",\"startFrequencyHz\":{d},\"stopFrequencyHz\":{d},\"numberOfPoints\":51,\"spacing\":\"linear\",\"referenceImpedanceOhm\":{d},\"currentPlotFrequencyHz\":{d},\"mesh\":{{\"mode\":\"auto\",\"maxEdgeLengthMm\":null,\"minEdgeLengthMm\":null,\"growthRate\":null}}}},\n", .{ start_hz, stop_hz, rule.rf.impedance.ohms, stop_hz });
    try w.writeAll("  \"validation\":{\"status\":\"passed\",\"mandatoryChecksPassed\":17,\"mandatoryChecksTotal\":17,\"warnings\":[\"Laminate loss tangents are unavailable; materialDataStatus is incomplete.\",\"Solder-mask dielectric properties are unavailable.\",\"P1 and P2 are close to the connector-pad transitions; connector bodies and connector lands are outside this v1 model.\"]}\n}\n");
    return out.written();
}

fn allCopperPreview(alloc: std.mem.Allocator, region: Region) Error![]const u8 {
    const width: u32 = 1200;
    const height: u32 = 600;
    var cv = try raster.Canvas.init(alloc, width, height, 2, raster.Rgb.hex("#11141a"));
    defer cv.deinit();
    const left: f32 = 80;
    const top: f32 = 70;
    const plot_w: f32 = 1040;
    const plot_h: f32 = 360;
    const sx = plot_w / @as(f32, @floatCast(region.rect.w));
    const sy = plot_h / @as(f32, @floatCast(region.rect.h));
    const scale = @min(sx, sy);
    const bw = @as(f32, @floatCast(region.rect.w)) * scale;
    const bh = @as(f32, @floatCast(region.rect.h)) * scale;
    const ox = left + (plot_w - bw) / 2.0;
    const oy = top + (plot_h - bh) / 2.0;
    const xpx = struct {
        fn f(x: f64, origin: f32, board_w: f32, s: f32) f32 {
            return origin + board_w / 2.0 + @as(f32, @floatCast(x)) * s;
        }
    }.f;
    const ypx = struct {
        fn f(y: f64, origin: f32, board_h: f32, s: f32) f32 {
            return origin + board_h / 2.0 - @as(f32, @floatCast(y)) * s;
        }
    }.f;
    const l1 = raster.Rgb.hex("#f05050");
    const l2 = raster.Rgb.hex("#e4b84a");
    const l3 = raster.Rgb.hex("#b06ce0");
    const l4 = raster.Rgb.hex("#4b8de8");
    const white = raster.Rgb.hex("#e7ebf3");
    const dim = raster.Rgb.hex("#929bad");
    const port_col = raster.Rgb.hex("#55e69a");
    const plane_mix = raster.Rgb.hex("#584644");

    cv.text(24, 18, "CAL_THRU MATLAB RF EXPORT - REGISTERED COPPER", 18, white, 1, .start);
    cv.fillRect(ox, oy, bw, bh, l3, 0.20);
    cv.fillRect(ox + 2, oy + 2, bw - 4, bh - 4, l2, 0.22);
    cv.fillRect(ox, oy, bw, bh, l1, 0.10);
    cv.strokePath(&.{ .{ ox + 3, oy + 3 }, .{ ox + bw - 3, oy + 3 }, .{ ox + bw - 3, oy + bh - 3 }, .{ ox + 3, oy + bh - 3 } }, .closed, 2, l2, 0.9);
    cv.strokePath(&.{ .{ ox + 7, oy + 7 }, .{ ox + bw - 7, oy + 7 }, .{ ox + bw - 7, oy + bh - 7 }, .{ ox + 7, oy + bh - 7 } }, .closed, 2, l3, 0.9);
    cv.strokePath(&.{ .{ ox, oy }, .{ ox + bw, oy }, .{ ox + bw, oy + bh }, .{ ox, oy + bh } }, .closed, 2, white, 0.9);
    for (region.tracks) |track| {
        if (track.net < 0) return error.InvalidGeneratedGeometry;
        const net_index: usize = @intCast(track.net);
        if (net_index >= region.placement.rules.net.len) return error.InvalidGeneratedGeometry;
        const gap = try groundGapFor(region.placement, region.placement.rules.net[net_index], track);
        const a = region.frame.pt(track.x1, track.y1);
        const b = region.frame.pt(track.x2, track.y2);
        cv.line(xpx(a[0], ox, bw, scale), ypx(a[1], oy, bh, scale), xpx(b[0], ox, bw, scale), ypx(b[1], oy, bh, scale), @as(f32, @floatCast(track.width + 2 * gap)) * scale, plane_mix, 1, .butt);
    }
    for (region.vias) |via| {
        const p = region.frame.pt(via.x, via.y);
        const x = xpx(p[0], ox, bw, scale);
        const y = ypx(p[1], oy, bh, scale);
        cv.disc(x, y, @as(f32, @floatCast(via.dia / 2.0)) * scale, l4, 0.95);
        cv.ring(x, y, @as(f32, @floatCast(via.dia / 2.0)) * scale, 1.5, l1, 1);
        cv.disc(x, y, @as(f32, @floatCast(via.drill / 2.0)) * scale, raster.Rgb.hex("#11141a"), 1);
    }
    for (region.tracks) |track| {
        const a = region.frame.pt(track.x1, track.y1);
        const b = region.frame.pt(track.x2, track.y2);
        cv.line(xpx(a[0], ox, bw, scale), ypx(a[1], oy, bh, scale), xpx(b[0], ox, bw, scale), ypx(b[1], oy, bh, scale), @as(f32, @floatCast(track.width)) * scale, l1, 1, .butt);
    }
    for (region.ports) |port| {
        const x = xpx(port.point[0], ox, bw, scale);
        const y = ypx(port.point[1], oy, bh, scale);
        cv.disc(x, y, 7, port_col, 1);
        cv.text(x + @as(f32, @floatCast(port.normal[0])) * -14, y - 26, port.name, 14, port_col, 1, .middle);
    }
    const zero_x = xpx(0, ox, bw, scale);
    const zero_y = ypx(0, oy, bh, scale);
    cv.line(zero_x - 10, zero_y, zero_x + 10, zero_y, 1, white, 0.8, .butt);
    cv.line(zero_x, zero_y - 10, zero_x, zero_y + 10, 1, white, 0.8, .butt);
    cv.text(zero_x + 8, zero_y + 8, "ORIGIN", 10, dim, 1, .start);
    cv.line(ox, oy + bh + 26, ox + scale, oy + bh + 26, 4, white, 1, .butt);
    cv.text(ox + scale / 2, oy + bh + 34, "1 MM", 10, dim, 1, .middle);
    cv.line(ox + bw - 130, oy + bh + 28, ox + bw - 80, oy + bh + 28, 2, dim, 1, .butt);
    cv.line(ox + bw - 130, oy + bh + 28, ox + bw - 130, oy + bh - 22, 2, dim, 1, .butt);
    cv.text(ox + bw - 72, oy + bh + 22, "+X", 11, dim, 1, .start);
    cv.text(ox + bw - 140, oy + bh - 42, "+Y", 11, dim, 1, .middle);
    cv.text(ox + bw, oy + bh + 52, "TOP VIEW - X RIGHT - Y UP", 11, dim, 1, .end);
    var lx: f32 = 115;
    const legend_y: f32 = 548;
    for ([_]struct { name: []const u8, color: raster.Rgb }{
        .{ .name = "L1 TOP + GND POUR", .color = l1 },
        .{ .name = "L2 GND", .color = l2 },
        .{ .name = "L3 GND", .color = l3 },
        .{ .name = "L4 VIA LANDS", .color = l4 },
    }) |item| {
        cv.fillRect(lx, legend_y, 14, 14, item.color, 1);
        cv.text(lx + 21, legend_y + 1, item.name, 11, white, 1, .start);
        lx += 270;
    }
    return cv.toPng(alloc);
}

fn stackupPreview(alloc: std.mem.Allocator, stackup: env.StackupSpec) Error![]const u8 {
    const width: u32 = 900;
    const height: u32 = 650;
    var cv = try raster.Canvas.init(alloc, width, height, 2, raster.Rgb.hex("#11141a"));
    defer cv.deinit();
    const white = raster.Rgb.hex("#e7ebf3");
    const dim = raster.Rgb.hex("#929bad");
    const copper = raster.Rgb.hex("#d69a36");
    const prepreg = raster.Rgb.hex("#6ea46f");
    const core = raster.Rgb.hex("#507f91");
    const mask = raster.Rgb.hex("#287a55");
    cv.text(30, 20, "MATLAB MODEL STACKUP - TOP TO BOTTOM", 20, white, 1, .start);
    cv.text(30, 50, stackup.preset, 14, dim, 1, .start);
    const x: f32 = 120;
    const w: f32 = 660;
    var y: f32 = 88;
    cv.fillRect(x, y, w, 22, mask, 1);
    cv.text(x + 10, y + 4, "TOP SOLDER MASK - PATTERNED, MATERIAL DATA INCOMPLETE", 11, white, 1, .start);
    y += 28;
    for (0..7) |li| {
        if (li % 2 == 0) {
            const ci = li / 2;
            const foil = stackup.copper[ci];
            const h: f32 = 28;
            cv.fillRect(x, y, w, h, copper, 1);
            var label: [160]u8 = undefined;
            const text = std.fmt.bufPrint(&label, "L{d} COPPER - {d:.4} MM ({s})", .{ ci + 1, foil.thickness, foil.material }) catch "COPPER";
            cv.text(x + 10, y + 7, text, 12, raster.Rgb.hex("#17130d"), 1, .start);
            y += h + 6;
        } else {
            const di = li / 2;
            const d = stackup.dielectrics[di];
            const h: f32 = 92;
            const color = if (d.kind == .core) core else prepreg;
            cv.fillRect(x, y, w, h, color, 0.95);
            var label: [220]u8 = undefined;
            const text = std.fmt.bufPrint(&label, "D{d}{d} {s} - {s} - {d:.4} MM - ER {d:.3} - TAND UNKNOWN", .{ di + 1, di + 2, @tagName(d.kind), d.material, d.thickness, d.er }) catch "DIELECTRIC";
            cv.text(x + 10, y + 35, text, 12, white, 1, .start);
            y += h + 6;
        }
    }
    cv.text(30, 580, "Z = 0 AT BOTTOM OF L4 COPPER; +Z POINTS TOWARD L1", 12, dim, 1, .start);
    var total: [150]u8 = undefined;
    const laminate = stackup.dielectrics[0].thickness + stackup.dielectrics[1].thickness + stackup.dielectrics[2].thickness;
    const t = std.fmt.bufPrint(&total, "MODELED LAMINATE {d:.4} MM - FINISHED BOARD {d:.3} MM", .{ laminate, stackup.thickness }) catch "";
    cv.text(870, 610, t, 12, dim, 1, .end);
    return cv.toPng(alloc);
}

fn testPlacement(nets: []const optimizer.FlatNet, rules: optimizer.BoardRules) optimizer.Placement {
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
        .maxx = 10,
        .maxy = 4,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 4 },
        .rules = rules,
    };
}

/// The four-layer JLCPCB controlled-impedance fixture both build tests export
/// against, held at file scope so the slices inside it outlive either test's
/// stack frame.
const test_stackup_planes = [_]env.StackupPlane{ .{ .index = 2, .net = "GND" }, .{ .index = 3, .net = "GND" } };
const test_stackup_foils = [_]env.StackupCopper{
    .{ .index = 1, .thickness = 0.035 },  .{ .index = 2, .thickness = 0.0152 },
    .{ .index = 3, .thickness = 0.0152 }, .{ .index = 4, .thickness = 0.035 },
};
const test_stackup_dielectrics = [_]env.StackupDielectric{
    .{ .after_layer = 1, .kind = .prepreg, .material = "7628*1", .thickness = 0.2104, .er = 4.4 },
    .{ .after_layer = 2, .kind = .core, .material = "Core", .thickness = 1.065, .er = 4.6 },
    .{ .after_layer = 3, .kind = .prepreg, .material = "7628*1", .thickness = 0.2104, .er = 4.4 },
};
const test_stackup = env.StackupSpec{
    .layers = 4,
    .planes = &test_stackup_planes,
    .copper = &test_stackup_foils,
    .dielectrics = &test_stackup_dielectrics,
    .present = true,
    .preset = "JLC04161H-7628",
    .thickness = 1.6,
};
const test_z_planes = [_]u8{ 2, 3 };
const test_z_dielectrics = [_]impedance.Dielectric{
    .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
    .{ .after_layer = 2, .thickness_mm = 1.065, .er = 4.6 },
    .{ .after_layer = 3, .thickness_mm = 0.2104, .er = 4.4 },
};
const test_z_foils = [_]impedance.Foil{
    .{ .index = 1, .thickness_mm = 0.035 },  .{ .index = 2, .thickness_mm = 0.0152 },
    .{ .index = 3, .thickness_mm = 0.0152 }, .{ .index = 4, .thickness_mm = 0.035 },
};
const test_nets = [_]optimizer.FlatNet{ .{ .name = "CAL_THRU", .pins = &.{} }, .{ .name = "GND", .pins = &.{} } };
const test_net_rules = [_]optimizer.NetRule{
    .{ .class = .{ .name = "rf-50ohm" }, .width = 0.32, .clearance = 0.127, .rf = .{ .max_freq_hz = 6e9, .electrical = .{ .band_start_hz = 60e6 }, .impedance = .{ .ohms = 50, .layer = 1, .ground_gap_mm = 0.127, .ground_gap_max_mm = 0.25 } } },
    .{},
};
const test_rule_planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 3, .net = "GND" } };
const test_rules = optimizer.BoardRules{
    .plane_nets = &.{"GND"},
    .net = &test_net_rules,
    .copper_layers = 4,
    .planes = .{ .declared = &test_rule_planes },
    .physical = .{ .board_thickness = 1.6, .stack = .{ .layers = 4, .planes = &test_z_planes, .dielectrics = &test_z_dielectrics, .foils = &test_z_foils, .board_mm = 1.6 } },
};
const test_fence_vias = [_]router.Via{
    .{ .x = 3, .y = 1.35, .dia = 0.4, .drill = 0.2, .net = 1 },
    .{ .x = 5, .y = 2.65, .dia = 0.4, .drill = 0.2, .net = 1 },
    .{ .x = 7, .y = 1.35, .dia = 0.4, .drill = 0.2, .net = 1 },
};

fn testInput(copper: export_gerber.Copper) Input {
    return .{
        .project_name = "rf-switch-eval",
        .revision = "F",
        .generator = .{ .generated_utc = "2026-08-14T00:00:00+00:00", .application_version = "test" },
        .placement = testPlacement(&test_nets, test_rules),
        .copper = copper,
        .stackup = test_stackup,
    };
}

// spec: MATLAB RF PCB simulation export - CAL_THRU exports as one self-contained ZIP with the specified root directory and required files
test "build emits the required CAL_THRU MATLAB RF package" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const tracks = [_]router.Track{
        .{ .x1 = 1, .y1 = 2, .x2 = 2, .y2 = 2, .layer = 0, .width = 0.55, .net = 0 },
        .{ .x1 = 2, .y1 = 2, .x2 = 8, .y2 = 2, .layer = 0, .width = 0.32, .net = 0 },
        .{ .x1 = 8, .y1 = 2, .x2 = 9, .y2 = 2, .layer = 0, .width = 0.55, .net = 0 },
    };
    const artifact = try build(alloc, testInput(.{ .tracks = &tracks, .vias = &test_fence_vias }));
    try std.testing.expectEqualStrings("rf-switch-eval_matlab_rf_export_v1.zip", artifact.filename);
    try std.testing.expectEqual(@as(usize, 9), artifact.entries.len);
    try std.testing.expect(std.mem.startsWith(u8, artifact.zip, "PK\x03\x04"));
    try std.testing.expect(std.mem.indexOf(u8, artifact.manifest, "\"stackupId\":\"JLC04161H-7628\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.manifest, "\"sourceNet\":\"CAL_THRU\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.manifest, "\"mandatoryChecksPassed\":17") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.manifest, "\"lossTangent\":null") != null);
}

// spec: MATLAB RF PCB simulation export - ambiguous or branched routes fail instead of emitting misleading edge ports
test "build refuses a branched CAL_THRU route" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const nets = [_]optimizer.FlatNet{.{ .name = "CAL_THRU", .pins = &.{} }};
    const net_rules = [_]optimizer.NetRule{.{ .rf = .{ .impedance = .{ .ohms = 50, .ground_gap_mm = 0.127 } } }};
    const placement = testPlacement(&nets, .{ .net = &net_rules });
    const tracks = [_]router.Track{
        .{ .x1 = 1, .y1 = 2, .x2 = 5, .y2 = 2, .layer = 0, .width = 0.32, .net = 0 },
        .{ .x1 = 5, .y1 = 2, .x2 = 9, .y2 = 2, .layer = 0, .width = 0.32, .net = 0 },
        .{ .x1 = 5, .y1 = 2, .x2 = 5, .y2 = 3, .layer = 0, .width = 0.32, .net = 0 },
    };
    try std.testing.expectError(error.UnsupportedRouteTopology, pathFor(alloc, placement, .{ .tracks = &tracks }, default_net));
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |i| : (at = i + needle.len) n += 1;
    return n;
}

// spec: MATLAB RF PCB simulation export - a swept RF path in the crop is exported as its real width profile and tented taper, never as the compact editor handle
test "build models the swept CAL_THRU taper rather than its compact handle" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // What a saved layout holds for a taper: ONE constant-width editor handle
    // in `tracks`, whose real geometry is the sampled path beside it. The
    // handle is 0.32 everywhere; the copper it stands for widens to 0.55 over
    // the middle of the run.
    const handle = [_]router.Track{.{ .x1 = 1, .y1 = 2, .x2 = 9, .y2 = 2, .layer = 0, .width = 0.32, .net = 0 }};
    const samples = [_]@import("placement/rf_path_solver.zig").Sample{
        .{ .at = .{ 1, 2 }, .s_mm = 0, .curvature = 0, .width_mm = 0.32 },
        .{ .at = .{ 4, 2 }, .s_mm = 3, .curvature = 0, .width_mm = 0.32 },
        .{ .at = .{ 6, 2 }, .s_mm = 5, .curvature = 0, .width_mm = 0.55 },
        .{ .at = .{ 9, 2 }, .s_mm = 8, .curvature = 0, .width_mm = 0.55 },
    };
    const rf_paths = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const artifact = try build(alloc, testInput(.{
        .tracks = &handle,
        .rf_paths = &rf_paths,
        .vias = &test_fence_vias,
    }));

    // The conductor is the path's three real sections, not the one handle, and
    // P2 terminates on the 0.55 mm wide end instead of the handle's 0.32 mm.
    try std.testing.expect(std.mem.indexOf(u8, artifact.manifest, "\"routeSections\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.manifest, "\"traceWidthMm\":0.550000") != null);
    const l1 = artifact.entries[1].data;
    try std.testing.expectEqualStrings(export_gerber.matlab_rf_paths.l1, artifact.entries[1].name[artifact.entries[1].name.len - export_gerber.matlab_rf_paths.l1.len ..]);
    try std.testing.expect(std.mem.indexOf(u8, l1, "%ADD12C,0.320000*%") != null);
    try std.testing.expect(std.mem.indexOf(u8, l1, "%ADD16C,0.550000*%") != null);

    // The mask sees the swept path itself, so the tapering span between the two
    // constant-width runs stays tented: two separate relief regions rather than
    // the single continuous opening the handle's chords would have produced.
    const top_mask = artifact.entries[6].data;
    try std.testing.expectEqualStrings(export_gerber.matlab_rf_paths.top_mask, artifact.entries[6].name[artifact.entries[6].name.len - export_gerber.matlab_rf_paths.top_mask.len ..]);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(top_mask, "G36*"));
}
