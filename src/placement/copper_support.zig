//! The ONE assembly of `copper_topology`'s support context.
//!
//! `copper_topology.analyzeRedundancy` answers "does deleting this section
//! change what the board connects" against a `BranchSupport`: which barrels are
//! live destinations, which trace endpoints stand in poured copper, and which
//! fabricated fill component each of those endpoints belongs to. Every one of
//! those is a CONNECTIVITY SOURCE, and a caller that omits one gets a different
//! answer from the same oracle.
//!
//! That is why this module exists rather than each caller building its own
//! record. `drc.checkCopperTopology` REPORTS the verdict and the router's
//! finish ACTS on it; while they assembled the context separately the finish
//! deleted a different set from the one DRC named, and copper the check called
//! dead survived every route. Both now call `assemble`, so the two cannot
//! disagree about what the board is connected by — only about the zones they
//! are handed, which is a data question each caller answers honestly (see
//! `Zone.component`).

const std = @import("std");
const copper_topology = @import("copper_topology.zig");
const optimizer = @import("optimizer.zig");
const outline = @import("outline.zig");
const pad_shape = @import("pad_shape.zig");
const plane_stitch = @import("plane_stitch.zig");
const net_name = @import("../net_name.zig");

/// One hand-authored or computed copper region credited by the topology
/// checks. Kept separate from `pour.UserZone` so the geometry checker stays
/// below the pour engine in the placement dependency graph.
pub const Zone = struct {
    net: []const u8,
    layer: u8,
    /// Physical 1-based copper position for a declared plane/pour fill. Zero
    /// for user zones. Return-path DRC uses this to inspect the exact reference
    /// plane rather than conflating two same-net planes.
    stack: u8 = 0,
    poly: []const [2]f64,
    holes: []const []const [2]f64 = &.{},
    priority: i64 = 0,
    /// Non-zero identity of one computed fill component. Equal ids conduct;
    /// separate components of the same net/layer deliberately do not. ZERO
    /// means "I have an outline but no fill raster": the reader then treats
    /// every same-net region on the layer as one conductor, which is the
    /// optimistic reading and the one a caller without a raster should avoid
    /// claiming — give each drawn outline its own id instead.
    component: u64 = 0,
    /// Inner-plane fill: touches barrels but never a signal-layer track.
    plane: bool = false,
};

/// Everything `analyzeRedundancy` needs, plus the per-via readings its caller
/// also reports on, so no consumer has to recompute (and mis-compute) them.
pub const Support = struct {
    branch: copper_topology.BranchSupport,
    /// Copper layers each barrel actually reaches — the `single_layer_via`
    /// number, and the test that put the barrel in `branch.live_vias`.
    via_uses: []const usize,
    /// Same-net poured layer mask at each barrel's coordinate.
    via_poured: []const u64,
    /// Same-net dedicated planes each barrel's drill crosses.
    via_planes: []const u8,
};

fn sameNet(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b) or
        std.ascii.eqlIgnoreCase(net_name.leaf(a), net_name.leaf(b));
}

fn zoneClipped(zones: []const Zone, zone_i: usize, x: f64, y: f64) bool {
    const zone = zones[zone_i];
    for (zones, 0..) |other, other_i| {
        if (other_i == zone_i or other.layer != zone.layer or other.priority <= zone.priority) continue;
        if (sameNet(other.net, zone.net)) continue;
        if (outline.contains(other.poly, x, y)) return true;
    }
    return false;
}

fn zoneContains(zone: Zone, x: f64, y: f64) bool {
    if (!outline.contains(zone.poly, x, y)) return false;
    for (zone.holes) |hole| if (outline.contains(hole, x, y)) return false;
    return true;
}

fn netNameOf(placement: optimizer.Placement, net: i32) ?[]const u8 {
    if (net < 0) return null;
    const ni: usize = @intCast(net);
    if (ni >= placement.nets.len) return null;
    return placement.nets[ni].name;
}

/// Same-net FILLED layers covering one point — the mask that tells a trace end
/// or a barrel it stands in copper. Dedicated planes are excluded: they are
/// inner geometry a signal-layer trace never meets (see `planeContacts`).
pub fn pourLayers(placement: optimizer.Placement, net: i32, zones: []const Zone, x: f64, y: f64) u64 {
    const name = netNameOf(placement, net) orelse return 0;
    var mask: u64 = 0;
    for (zones, 0..) |zone, zone_i| {
        if (zone.plane or zone.layer >= 64 or !sameNet(zone.net, name)) continue;
        if (!zoneContains(zone, x, y) or zoneClipped(zones, zone_i, x, y)) continue;
        mask |= @as(u64, 1) << @intCast(zone.layer);
    }
    return mask;
}

/// The fill component one trace endpoint stands in, on its own layer. A zone
/// that names no exact component falls back to one id per net+layer.
pub fn pourComponent(placement: optimizer.Placement, net: i32, layer: u8, zones: []const Zone, x: f64, y: f64) u64 {
    const name = netNameOf(placement, net) orelse return 0;
    for (zones, 0..) |zone, zone_i| {
        if (zone.plane or zone.layer != layer or !sameNet(zone.net, name)) continue;
        if (!zoneContains(zone, x, y) or zoneClipped(zones, zone_i, x, y)) continue;
        if (zone.component != 0) return zone.component;
        return (@as(u64, @intCast(net + 1)) << 8) | @as(u64, layer) + 1;
    }
    return 0;
}

/// Exact fabricated fill components touching one point. `layer == null` is a
/// through feature (all outer pours and inner planes); a concrete layer is an
/// SMD face and therefore never touches an inner plane.
pub fn componentsAt(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    net: i32,
    zones: []const Zone,
    at: [2]f64,
    layer: ?u8,
) std.mem.Allocator.Error![]const u64 {
    const name = netNameOf(placement, net) orelse return &.{};
    var ids: std.ArrayList(u64) = .empty;
    for (zones, 0..) |zone, zone_i| {
        if (zone.component == 0 or !sameNet(zone.net, name)) continue;
        if (layer) |signal_layer| {
            if (zone.plane or zone.layer != signal_layer) continue;
        }
        if (!zoneContains(zone, at[0], at[1]) or zoneClipped(zones, zone_i, at[0], at[1])) continue;
        var duplicate = false;
        for (ids.items) |old| if (old == zone.component) {
            duplicate = true;
            break;
        };
        if (!duplicate) try ids.append(arena, zone.component);
    }
    return ids.toOwnedSlice(arena);
}

/// Same-net dedicated planes a barrel at one point crosses. Exact plane
/// contours (with their antipad holes) win when the caller has them; a caller
/// with no plane geometry at all falls back to the stackup DECLARATION, which
/// is what keeps a plane drop's pad stub from reading as copper to nowhere.
pub fn planeContacts(placement: optimizer.Placement, net: i32, zones: []const Zone, x: f64, y: f64) u8 {
    const name = netNameOf(placement, net) orelse return 0;
    var count: u8 = 0;
    var has_plane_geometry = false;
    for (zones) |zone| {
        if (!zone.plane) continue;
        has_plane_geometry = true;
        if (!sameNet(zone.net, name) or !zoneContains(zone, x, y)) continue;
        count +|= 1;
    }
    if (count != 0 or has_plane_geometry) return count;
    return plane_stitch.declaredPlaneContacts(placement, name);
}

/// Build the one support record `copper_topology.analyzeRedundancy` reads.
///
/// The connectivity sources it folds in, in the order the walk consumes them:
///
///  1. `terminals` — every pad land (the caller's own list); a THROUGH land
///     reaches both outer faces and so counts on either.
///  2. `tracks` — same-net full-cross-section trace contact.
///  3. `live_vias` — barrels reaching two or more copper layers. A barrel
///     counts a layer for each same-net track that lands on it, each same-net
///     land covering its coordinate (through lands count both faces), each
///     poured layer over it (4), and each dedicated plane its drill crosses
///     (5). A one-layer barrel is junk together with whatever reaches it and
///     therefore supports nothing.
///  4. `pour_layers` — the filled same-net layers standing under each trace
///     ENDPOINT, which is how a trace that ends in a pour is carried by it.
///  5. `pour_components` — WHICH fill each of those endpoints is in, so two
///     separate islands of one net on one layer never form an alternate route.
pub fn assemble(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    terminals: []const copper_topology.Terminal,
    tracks: []const copper_topology.Track,
    vias: []const copper_topology.Via,
    zones: []const Zone,
) std.mem.Allocator.Error!Support {
    const via_uses = try arena.alloc(usize, vias.len);
    const via_poured = try arena.alloc(u64, vias.len);
    const via_planes = try arena.alloc(u8, vias.len);
    var live: std.ArrayList(copper_topology.Via) = .empty;
    for (vias, 0..) |via, via_i| {
        via_poured[via_i] = pourLayers(placement, via.net, zones, via.at[0], via.at[1]);
        via_planes[via_i] = planeContacts(placement, via.net, zones, via.at[0], via.at[1]);
        via_uses[via_i] = copper_topology.viaUseCount(
            terminals,
            tracks,
            via,
            via_poured[via_i],
            via_planes[via_i],
        );
        if (via_uses[via_i] >= 2) try live.append(arena, via);
    }
    const endpoint_pours = try arena.alloc([2]u64, tracks.len);
    const endpoint_components = try arena.alloc([2]u64, tracks.len);
    for (tracks, endpoint_pours, endpoint_components) |track, *poured, *components| {
        poured.* = .{
            pourLayers(placement, track.net, zones, track.a[0], track.a[1]),
            pourLayers(placement, track.net, zones, track.b[0], track.b[1]),
        };
        components.* = .{
            pourComponent(placement, track.net, track.layer, zones, track.a[0], track.a[1]),
            pourComponent(placement, track.net, track.layer, zones, track.b[0], track.b[1]),
        };
    }
    return .{
        .branch = .{
            .live_vias = live.items,
            .pour_layers = endpoint_pours,
            .pour_components = endpoint_components,
        },
        .via_uses = via_uses,
        .via_poured = via_poured,
        .via_planes = via_planes,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn onePlacement(nets: []const optimizer.FlatNet) optimizer.Placement {
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
        .maxy = 10,
        .generated = true,
    };
}

// spec: placement/copper-support - one assembly credits pads, tracks, poured trace ends, fill identity, and barrels made live by a pour or a declared plane
test "assemble credits a pour under a barrel and the endpoints standing in it" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]optimizer.FlatNet{.{ .name = "V_3V3A", .pins = &.{} }};
    const placement = onePlacement(&nets);
    const tracks = [_]copper_topology.Track{
        .{ .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]copper_topology.Via{.{ .at = .{ 1, 0 }, .dia = 0.4, .net = 0 }};

    // With no zone the barrel reaches one layer and supports nothing.
    const bare = try assemble(arena, placement, &.{}, &tracks, &vias, &.{});
    try testing.expectEqual(@as(usize, 1), bare.via_uses[0]);
    try testing.expectEqual(@as(usize, 0), bare.branch.live_vias.len);
    try testing.expectEqual(@as(u64, 0), bare.branch.pour_layers[0][1]);

    // An inner filled region of the same net makes it a real destination, and
    // an endpoint standing in a pour on its OWN layer is carried by it.
    const region = [_][2]f64{ .{ -1, -1 }, .{ 3, -1 }, .{ 3, 1 }, .{ -1, 1 } };
    const zones = [_]Zone{
        .{ .net = "V_3V3A", .layer = 2, .poly = &region, .component = 77 },
        .{ .net = "V_3V3A", .layer = 0, .poly = &region, .component = 88 },
    };
    const filled = try assemble(arena, placement, &.{}, &tracks, &vias, &zones);
    // Two DISTINCT copper layers: the routed face (which the layer-0 pour
    // shares with the track) and the inner fill the barrel drops into.
    try testing.expectEqual(@as(usize, 2), filled.via_uses[0]);
    try testing.expectEqual(@as(usize, 1), filled.branch.live_vias.len);
    try testing.expectEqual(@as(u64, 88), filled.branch.pour_components[0][0]);
    // The leaf spelling of a hierarchical net name resolves to the same fill.
    const hierarchical = [_]optimizer.FlatNet{.{ .name = "amp1/V_3V3A", .pins = &.{} }};
    const nested = try assemble(arena, onePlacement(&hierarchical), &.{}, &tracks, &vias, &zones);
    try testing.expectEqual(@as(u64, 88), nested.branch.pour_components[0][0]);
}

// spec: placement/copper-support - a barrel with no plane contour falls back to the stackup declaration, and exact plane contours override it
test "assemble reads declared planes only while no plane contour is supplied" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]optimizer.FlatNet{.{ .name = "GND", .pins = &.{} }};
    var placement = onePlacement(&nets);
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    placement.rules = .{ .plane_nets = &.{"GND"}, .copper_layers = 4, .planes = .{ .declared = &planes } };
    const tracks = [_]copper_topology.Track{
        .{ .a = .{ 0, 0 }, .b = .{ 0.6, 0 }, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]copper_topology.Via{.{ .at = .{ 0.6, 0 }, .dia = 0.4, .net = 0 }};
    // No contour: the declaration is the only evidence, and it keeps the
    // plane drop's own stub from reading as copper reaching nothing.
    const declared = try assemble(arena, placement, &.{}, &tracks, &vias, &.{});
    try testing.expectEqual(@as(u8, 1), declared.via_planes[0]);
    try testing.expectEqual(@as(usize, 1), declared.branch.live_vias.len);
    // An exact contour with the barrel in its antipad hole overrides it.
    const region = [_][2]f64{ .{ -1, -1 }, .{ 3, -1 }, .{ 3, 1 }, .{ -1, 1 } };
    const hole = [_][2]f64{ .{ 0.3, -0.3 }, .{ 0.9, -0.3 }, .{ 0.9, 0.3 }, .{ 0.3, 0.3 } };
    const holes = [_][]const [2]f64{&hole};
    const contour = [_]Zone{.{ .net = "GND", .layer = 2, .poly = &region, .holes = &holes, .plane = true, .component = 9 }};
    const exact = try assemble(arena, placement, &.{}, &tracks, &vias, &contour);
    try testing.expectEqual(@as(u8, 0), exact.via_planes[0]);
    try testing.expectEqual(@as(usize, 0), exact.branch.live_vias.len);
}
