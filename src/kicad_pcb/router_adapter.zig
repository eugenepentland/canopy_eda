//! Adapt a normalized KiCad physical snapshot to the existing fixed-placement
//! maze router. Footprint poses are copied verbatim; no placement solve runs.
//! Project minima/classes become router rules, large single-net inner zones are
//! recognized as planes, and retained reference copper becomes route obstacles.

const std = @import("std");
const snapshot_mod = @import("snapshot.zig");
const project_mod = @import("project_rules.zig");
const optimizer = @import("../placement/optimizer.zig");
const geometry = @import("../placement/geometry.zig");
const board_layers = @import("../board_layers.zig");
const route_policy = @import("../placement/route_policy.zig");
const track_segment = @import("track_segment.zig");
const router = @import("../placement/router.zig");
const diff_pairs = @import("../placement/diff_pairs.zig");
const export_kicad = @import("../export_kicad.zig");

/// Fixed router input derived from one KiCad board plus optional project rules.
pub const Adapted = struct {
    placement: optimizer.Placement,
    params: router.RouteParams,
};

/// Build a fixed `Placement` from the physical board. Pad bounds stand in for
/// courtyards because routing only needs copper obstacles and terminal poses.
pub fn adapt(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
    project: ?project_mod.ProjectRules,
) std.mem.Allocator.Error!Adapted {
    const planes = try detectPlanes(arena, board);
    const plane_nets = try planeNetNames(arena, planes);
    const copper_layers = copperLayerCount(board);
    var rules = optimizer.BoardRules{
        .copper_layers = copper_layers,
        .planes = .{ .declared = planes },
        .plane_nets = plane_nets,
        .physical = .{ .board_thickness = board.thickness_mm },
        .design = designRules(project),
    };

    const parts = try arena.alloc(optimizer.Part, board.footprints.len);
    const instances = try arena.alloc(export_kicad.FlatInstance, board.footprints.len);
    for (board.footprints, 0..) |fp, i| {
        const bottom = std.mem.eql(u8, fp.layer, board_layers.b_cu);
        const pads = try convertPads(arena, fp.pads, fp.at.rotation_deg, bottom);
        const ext = padExtents(pads);
        const ref = if (fp.reference.len > 0) fp.reference else fp.uuid;
        parts[i] = .{
            .ref_des = ref,
            .kind = partKind(ref),
            .hw = ext[0],
            .hh = ext[1],
            .pads = pads,
            .fallback = false,
            .value = fp.value,
            .x = fp.at.x,
            .y = fp.at.y,
            // KiCad board coordinates have +Y down, so positive angles turn
            // opposite to the optimizer's Cartesian convention. Bottom local
            // X was pre-mirrored in convertPads to cancel worldPt's mirror.
            .rot = -fp.at.rotation_deg,
            .side = if (bottom) .bottom else .top,
            .locked = fp.locked,
        };
        instances[i] = .{
            .ref_des = ref,
            .component = fp.lib_id,
            .value = fp.value,
            .footprint = fp.lib_id,
            .properties = &.{},
            .uuid = fp.uuid,
        };
    }

    const nets = try convertNets(arena, board);
    const mutable_rules = try netRules(arena, board, project);
    try inferDiffPairRules(arena, nets, mutable_rules, project);
    rules.net = mutable_rules;
    const resolved_pairs = try diff_pairs.resolve(arena, nets, rules.net);
    const pairs = try arena.dupe(diff_pairs.DiffPair, resolved_pairs);
    applyDiffPairViaGaps(pairs, rules.net, project);
    const bounds = snapshot_mod.outlineBounds(board);
    const fallback = partBounds(parts);
    const minx = if (bounds.valid) bounds.min.x else fallback[0];
    const miny = if (bounds.valid) bounds.min.y else fallback[1];
    const maxx = if (bounds.valid) bounds.max.x else fallback[2];
    const maxy = if (bounds.valid) bounds.max.y else fallback[3];
    const rect: ?optimizer.BoardRect = if (bounds.valid) .{
        .minx = minx,
        .miny = miny,
        .w = maxx - minx,
        .h = maxy - miny,
    } else null;
    const placement = optimizer.Placement{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = instances,
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = minx,
        .miny = miny,
        .maxx = maxx,
        .maxy = maxy,
        .generated = false,
        .board_rect = rect,
        .rules = rules,
        .diff_pairs = pairs,
    };
    return .{ .placement = placement, .params = rules.design.routeParams() };
}

/// Build selected-net + retained-copper router options from a virtual-erasure
/// seed. `requested` empty selects every net and therefore retains no routes.
pub fn routeOptions(
    arena: std.mem.Allocator,
    adapted: Adapted,
    seed: snapshot_mod.Snapshot,
    requested: []const []const u8,
) std.mem.Allocator.Error!route_policy.Options {
    const selected = try arena.alloc(bool, adapted.placement.nets.len);
    @memset(selected, requested.len == 0);
    if (requested.len > 0) {
        for (requested) |want| for (adapted.placement.nets, 0..) |net, ni| {
            if (std.ascii.eqlIgnoreCase(net.name, want)) selected[ni] = true;
        };
    }
    var tracks: std.ArrayList(route_policy.ExistingTrack) = .empty;
    var vias: std.ArrayList(route_policy.ExistingVia) = .empty;
    var zones: std.ArrayList(route_policy.ExistingZone) = .empty;
    for (seed.segments) |item| {
        const layer = signalLayerIndex(adapted.placement.rules, item.layer) orelse continue;
        try tracks.append(arena, track_segment.from(route_policy.ExistingTrack, item.start, item.end, item.width, layer, netIndex(adapted.placement, item.net)));
    }
    for (seed.arcs) |item| {
        const layer = signalLayerIndex(adapted.placement.rules, item.layer) orelse continue;
        try tracks.append(arena, track_segment.from(route_policy.ExistingTrack, item.start, item.mid, item.width, layer, netIndex(adapted.placement, item.net)));
        try tracks.append(arena, track_segment.from(route_policy.ExistingTrack, item.mid, item.end, item.width, layer, netIndex(adapted.placement, item.net)));
    }
    for (seed.vias) |item| {
        try vias.append(arena, .{
            .x = item.at.x,
            .y = item.at.y,
            .dia = item.size,
            .drill = item.drill,
            .net = netIndex(adapted.placement, item.net),
        });
    }
    for (seed.zones) |item| {
        if (item.polygon.len < 3) continue;
        const polygon = try arena.alloc([2]f64, item.polygon.len);
        for (item.polygon, polygon) |point, *dst| dst.* = .{ point.x, point.y };
        const keepout = item.keepout;
        const copper = keepout == null and item.net.len > 0;
        const net = if (copper) netIndex(adapted.placement, item.net) else -2;
        if (copper and net < 0) continue;
        for (item.layers) |layer_name| {
            const layer = signalLayerIndex(adapted.placement.rules, layer_name) orelse continue;
            try zones.append(arena, .{
                .polygon = polygon,
                .layer = layer,
                .net = net,
                // KiCad repours copper zones around newly-routed foreign
                // copper. Only an explicit keepout is a fixed obstacle.
                .tracks_blocked = if (keepout) |rule| !rule.tracks_allowed else false,
                .vias_blocked = if (keepout) |rule| !rule.vias_allowed else false,
                .copper = copper,
            });
        }
    }
    return .{
        .selected_nets = selected,
        .existing_tracks = tracks.items,
        .existing_vias = vias.items,
        .existing_zones = zones.items,
    };
}

fn convertPads(
    arena: std.mem.Allocator,
    source: []const snapshot_mod.Pad,
    footprint_rotation: f64,
    bottom: bool,
) std.mem.Allocator.Error![]const geometry.Pad {
    const out = try arena.alloc(geometry.Pad, source.len);
    for (source, out) |pad, *dst| {
        const thru = std.mem.eql(u8, pad.kind, "thru_hole") or hasLayer(pad.layers, "*.Cu") or
            (hasLayer(pad.layers, board_layers.f_cu) and hasLayer(pad.layers, board_layers.b_cu));
        const npth = std.mem.eql(u8, pad.kind, "np_thru_hole");
        const drill = if (pad.drill.x > 0 and pad.drill.y > 0)
            @min(pad.drill.x, pad.drill.y)
        else
            @max(pad.drill.x, pad.drill.y);
        const poly = try convertPadPoly(
            arena,
            pad,
            footprint_rotation,
            bottom,
        );
        dst.* = .{
            .number = pad.number,
            // KiCad has already mirrored bottom-footprint local X in the
            // board file. Pre-mirror it so optimizer.worldPt's bottom-side
            // transform reconstructs the serialized pad centre exactly.
            .x = if (bottom) -pad.at.x else pad.at.x,
            .y = pad.at.y,
            .w = @max(pad.size.x, 0.05),
            .h = @max(pad.size.y, 0.05),
            .shape = pad.shape,
            .poly = poly,
            .thru = thru,
            .npth = npth,
            .drill = drill,
            .overrides = .{ .rratio = pad.roundrect_rratio },
            // KiCad stores a pad's board-facing angle. Convert it back to a
            // footprint-local Cartesian angle; the part pose supplies the
            // remaining rotation in `pad_shape.worldShape`.
            .rot = footprint_rotation - pad.at.rotation_deg,
        };
    }
    return out;
}

fn convertPadPoly(
    arena: std.mem.Allocator,
    pad: snapshot_mod.Pad,
    footprint_rotation: f64,
    bottom: bool,
) std.mem.Allocator.Error![]const [2]f64 {
    if (pad.poly.len < 3) return &.{};
    const out = try arena.alloc([2]f64, pad.poly.len);
    const angle = (footprint_rotation - pad.at.rotation_deg) * std.math.pi / 180;
    const ca = @cos(angle);
    const sa = @sin(angle);
    for (pad.poly, out) |point, *world_local| {
        const x = pad.at.x + point.x * ca - point.y * sa;
        const y = pad.at.y + point.x * sa + point.y * ca;
        world_local.* = .{ if (bottom) -x else x, y };
    }
    return out;
}

fn hasLayer(layers: []const []const u8, want: []const u8) bool {
    for (layers) |layer| if (std.mem.eql(u8, layer, want)) return true;
    return false;
}

fn padExtents(pads: []const geometry.Pad) [2]f64 {
    var hw: f64 = 0.5;
    var hh: f64 = 0.5;
    for (pads) |pad| {
        const radius = @max(pad.w, pad.h) / 2;
        hw = @max(hw, @abs(pad.x) + radius);
        hh = @max(hh, @abs(pad.y) + radius);
    }
    return .{ hw, hh };
}

fn partKind(ref: []const u8) optimizer.PartKind {
    if (ref.len == 0) return .passive;
    return switch (std.ascii.toUpper(ref[0])) {
        'U', 'I', 'J', 'P', 'X' => .hub,
        else => .passive,
    };
}

fn convertNets(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
) std.mem.Allocator.Error![]const export_kicad.FlatNet {
    const lists = try arena.alloc(std.ArrayList(export_kicad.FlatPin), board.nets.len);
    for (lists) |*list| list.* = .empty;
    for (board.footprints) |fp| {
        const ref = if (fp.reference.len > 0) fp.reference else fp.uuid;
        for (fp.pads) |pad| {
            const ni = snapshotNetIndex(board, pad.net) orelse continue;
            try lists[ni].append(arena, .{ .ref_des = ref, .pin = pad.number });
        }
    }
    const nets = try arena.alloc(export_kicad.FlatNet, board.nets.len);
    for (board.nets, lists, nets) |net, list, *dst| {
        dst.* = .{ .name = net.name, .pins = list.items };
    }
    return nets;
}

fn snapshotNetIndex(board: snapshot_mod.Snapshot, name: []const u8) ?usize {
    for (board.nets, 0..) |net, i| if (std.mem.eql(u8, net.name, name)) return i;
    return null;
}

fn netIndex(placement: optimizer.Placement, name: []const u8) i32 {
    for (placement.nets, 0..) |net, i| if (std.mem.eql(u8, net.name, name)) return @intCast(i);
    return -2;
}

fn copperLayerCount(board: snapshot_mod.Snapshot) u8 {
    var count: u8 = 0;
    for (board.layers) |layer| {
        if (layer.copper) count +|= 1;
    }
    return @max(count, 2);
}

fn detectPlanes(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
) std.mem.Allocator.Error![]const optimizer.PlaneAt {
    const bounds = snapshot_mod.outlineBounds(board);
    const board_area = bounds.width() * bounds.height();
    if (board_area <= 0) return &.{};
    var out: std.ArrayList(optimizer.PlaneAt) = .empty;
    var stack: u8 = 0;
    for (board.layers) |layer| {
        if (!layer.copper) continue;
        stack += 1;
        var net: ?[]const u8 = null;
        var ambiguous = false;
        for (board.zones) |zone| {
            if (zone.keepout != null or !hasLayer(zone.layers, layer.name)) continue;
            if (polygonArea(zone.polygon) < board_area * 0.5) continue;
            if (net == null) net = zone.net else if (!std.mem.eql(u8, net.?, zone.net)) ambiguous = true;
        }
        if (!ambiguous and net != null and net.?.len > 0) try out.append(arena, .{ .index = stack, .net = net.? });
    }
    return out.items;
}

test "adapter recognizes board-scale outer copper pours" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layers = [_]snapshot_mod.Layer{
        .{ .name = "F.Cu", .copper = true },
        .{ .name = "In1.Cu", .copper = true },
        .{ .name = "B.Cu", .copper = true },
    };
    const boundary = [_]snapshot_mod.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 10 },
    };
    const polygon = [_]snapshot_mod.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 10, .y = 0 },
        .{ .x = 10, .y = 10 },
        .{ .x = 0, .y = 10 },
    };
    const zones = [_]snapshot_mod.Zone{.{
        .net = "GND",
        .layers = &.{ "F.Cu", "B.Cu" },
        .polygon = &polygon,
    }};
    const outline = [_]snapshot_mod.OutlineGraphic{.{
        .kind = .rect,
        .points = &boundary,
    }};
    const planes = try detectPlanes(arena, .{
        .layers = &layers,
        .zones = &zones,
        .outline = &outline,
    });
    try std.testing.expectEqual(@as(usize, 2), planes.len);
    try std.testing.expectEqual(@as(u8, 1), planes[0].index);
    try std.testing.expectEqual(@as(u8, 3), planes[1].index);
    try std.testing.expectEqualStrings("GND", planes[0].net);
    try std.testing.expectEqualStrings("GND", planes[1].net);
}

fn polygonArea(points: []const snapshot_mod.Point) f64 {
    if (points.len < 3) return 0;
    var twice: f64 = 0;
    for (points, 0..) |p, i| {
        const q = points[(i + 1) % points.len];
        twice += p.x * q.y - q.x * p.y;
    }
    return @abs(twice) / 2;
}

fn planeNetNames(
    arena: std.mem.Allocator,
    planes: []const optimizer.PlaneAt,
) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (planes) |plane| {
        var seen = false;
        for (out.items) |name| if (std.mem.eql(u8, name, plane.net)) {
            seen = true;
            break;
        };
        if (!seen) try out.append(arena, plane.net);
    }
    return out.items;
}

fn designRules(project: ?project_mod.ProjectRules) optimizer.DesignRules {
    const p = project orelse return .{};
    const d = p.design;
    const default = findClass(p, "Default");
    var out: optimizer.DesignRules = .{};
    out.clearance = if (default) |c| nonzero(c.clearance, d.min_clearance) else nonzero(d.min_clearance, out.clearance);
    out.track_width = if (default) |c|
        nonzero(c.track_width, d.min_track_width)
    else
        nonzero(d.min_track_width, out.track_width);
    out.via_dia = if (default) |c|
        nonzero(c.via_diameter, d.min_via_diameter)
    else
        nonzero(d.min_via_diameter, out.via_dia);
    out.via_drill = if (default) |c| nonzero(c.via_drill, d.min_via_drill) else nonzero(d.min_via_drill, out.via_drill);
    out.min_width = nonzero(d.min_track_width, out.min_width);
    out.min_drill = nonzero(d.min_via_drill, out.min_drill);
    out.min_annular = nonzero(d.min_via_annular_width, out.min_annular);
    out.edge.copper = d.min_copper_edge_clearance;
    out.hole_to_hole = nonzero(d.min_hole_to_hole, out.hole_to_hole);
    return out;
}

fn nonzero(value: f64, fallback: f64) f64 {
    return if (value > 0) value else fallback;
}

fn netRules(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
    project: ?project_mod.ProjectRules,
) std.mem.Allocator.Error![]optimizer.NetRule {
    const out = try arena.alloc(optimizer.NetRule, board.nets.len);
    @memset(out, .{});
    const p = project orelse return out;
    for (board.nets, out) |net, *dst| {
        const class_name = classForNet(p, net.name);
        const class = findClass(p, class_name) orelse continue;
        dst.* = .{
            .class = .{ .name = class.name },
            .width = class.track_width,
            .clearance = class.clearance,
            .via_dia = class.via_diameter,
            .via_drill = class.via_drill,
        };
    }
    return out;
}

fn classForNet(project: project_mod.ProjectRules, name: []const u8) []const u8 {
    for (project.patterns) |pattern| if (wildcardMatch(pattern.pattern, name)) return pattern.net_class;
    return "Default";
}

fn findClass(project: project_mod.ProjectRules, name: []const u8) ?project_mod.NetClass {
    for (project.net_classes) |class| if (std.ascii.eqlIgnoreCase(class.name, name)) return class;
    return null;
}

fn wildcardMatch(pattern: []const u8, name: []const u8) bool {
    return wildcardInner(pattern, 0, name, 0);
}

fn wildcardInner(pattern: []const u8, pi: usize, name: []const u8, ni: usize) bool {
    if (pi == pattern.len) return ni == name.len;
    if (pattern[pi] == '*') {
        var next = ni;
        while (next <= name.len) : (next += 1) if (wildcardInner(pattern, pi + 1, name, next)) return true;
        return false;
    }
    if (ni == name.len) return false;
    if (pattern[pi] == '?' or std.ascii.toUpper(pattern[pi]) == std.ascii.toUpper(name[ni]))
        return wildcardInner(pattern, pi + 1, name, ni + 1);
    return false;
}

fn inferDiffPairRules(
    arena: std.mem.Allocator,
    nets: []const export_kicad.FlatNet,
    rules: []optimizer.NetRule,
    project: ?project_mod.ProjectRules,
) std.mem.Allocator.Error!void {
    for (nets, 0..) |net, pi| {
        const leaf = shortName(net.name);
        const named = (try diff_pairs.namedMate(arena, leaf)) orelse continue;
        if (named.polarity != .p) continue;
        const dm = try diff_pairs.dmMate(arena, leaf);
        for (nets, 0..) |other, ni| {
            const candidate = shortName(other.name);
            const kicad_match = std.ascii.eqlIgnoreCase(candidate, named.name);
            const dm_match = if (dm) |want| std.ascii.eqlIgnoreCase(candidate, want) else false;
            if (!kicad_match and !dm_match) continue;
            const class = if (project) |p| findClass(p, rules[pi].class.name) else null;
            const defaults = if (project) |p| findClass(p, "Default") else null;
            const min_gap = if (project) |p|
                nonzero(p.design.min_clearance, diff_pairs.default_gap_mm)
            else
                diff_pairs.default_gap_mm;
            const inherited_gap = if (class) |c|
                nonzero(c.diff_pair_gap, if (defaults) |d| d.diff_pair_gap else 0)
            else
                0;
            const gap = @max(nonzero(inherited_gap, min_gap), min_gap);
            const inherited_width = if (class) |c|
                nonzero(c.diff_pair_width, if (defaults) |d| d.diff_pair_width else 0)
            else
                0;
            const base_width = nonzero(rules[pi].width, if (defaults) |d| d.track_width else 0);
            const min_width = if (project) |p| nonzero(p.design.min_track_width, base_width) else base_width;
            const width = @max(nonzero(inherited_width, base_width), min_width);
            rules[pi].diff_gap = gap;
            rules[ni].diff_gap = gap;
            rules[pi].width = width;
            rules[ni].width = width;
            break;
        }
    }
}

/// Apply KiCad's separate edge-to-edge via gap after generic pair resolution.
/// Zero is retained when no project class is available, meaning trace gap.
fn applyDiffPairViaGaps(
    pairs: []diff_pairs.DiffPair,
    rules: []const optimizer.NetRule,
    project: ?project_mod.ProjectRules,
) void {
    const p = project orelse return;
    for (pairs) |*pair| {
        if (pair.p >= rules.len) continue;
        const class = findClass(p, rules[pair.p].class.name) orelse continue;
        const defaults = findClass(p, "Default");
        const board_defaults = optimizer.DesignRules{};
        const inherited = nonzero(class.diff_pair_via_gap, if (defaults) |d| d.diff_pair_via_gap else 0);
        const default_via_dia = if (defaults) |d|
            nonzero(d.via_diameter, board_defaults.via_dia)
        else
            board_defaults.via_dia;
        const default_via_drill = if (defaults) |d|
            nonzero(d.via_drill, board_defaults.via_drill)
        else
            board_defaults.via_drill;
        const via_dia = @max(
            nonzero(class.via_diameter, default_via_dia),
            p.design.min_via_diameter,
        );
        const via_drill = @max(
            nonzero(class.via_drill, default_via_drill),
            p.design.min_via_drill,
        );
        const annular = @max((via_dia - via_drill) / 2, 0);
        // Mirrors SIZES_SETTINGS::EffectiveDiffPairViaGap's copper-to-hole
        // term. The drill-to-drill term remains geometry-dependent and is
        // applied in diff_couple once the live RouteParams are known.
        const copper_to_hole = @max(p.design.min_hole_clearance - annular, 0);
        pair.via_gap = @max(nonzero(inherited, pair.gap), copper_to_hole);
    }
}

fn shortName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| return name[i + 1 ..];
    return name;
}

/// The routable index of a board layer NAME, through the shared layer model.
fn signalLayerIndex(rules: optimizer.BoardRules, name: []const u8) ?u8 {
    return rules.signalIndexOfName(name);
}

fn partBounds(parts: []const optimizer.Part) [4]f64 {
    if (parts.len == 0) return .{ 0, 0, 0, 0 };
    var minx = std.math.inf(f64);
    var miny = std.math.inf(f64);
    var maxx = -std.math.inf(f64);
    var maxy = -std.math.inf(f64);
    for (parts) |part| {
        minx = @min(minx, part.x - part.hw);
        miny = @min(miny, part.y - part.hh);
        maxx = @max(maxx, part.x + part.hw);
        maxy = @max(maxy, part.y + part.hh);
    }
    return .{ minx, miny, maxx, maxy };
}

test "adapter keeps fixed poses nets rules and retained copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layers = [_]snapshot_mod.Layer{
        .{ .name = "F.Cu", .copper = true },
        .{ .name = "B.Cu", .copper = true },
    };
    const pads = [_]snapshot_mod.Pad{.{
        .number = "1",
        .kind = "smd",
        .size = .{ .x = 0.5, .y = 0.5 },
        .layers = &.{"F.Cu"},
        .net = "SIG",
    }};
    const fps = [_]snapshot_mod.Footprint{.{
        .reference = "R1",
        .layer = "F.Cu",
        .at = .{ .x = 10, .y = 20, .rotation_deg = 90 },
        .pads = &pads,
    }};
    const nets = [_]snapshot_mod.Net{.{ .name = "SIG" }};
    const segments = [_]snapshot_mod.Segment{.{
        .start = .{ .x = 10, .y = 20 },
        .end = .{ .x = 11, .y = 20 },
        .width = 0.2,
        .layer = "F.Cu",
        .net = "SIG",
    }};
    const zone_poly = [_]snapshot_mod.Point{
        .{ .x = 9, .y = 19 },
        .{ .x = 12, .y = 19 },
        .{ .x = 12, .y = 21 },
        .{ .x = 9, .y = 21 },
    };
    const zones = [_]snapshot_mod.Zone{
        .{ .net = "SIG", .layers = &.{"F.Cu"}, .polygon = &zone_poly },
        .{
            .layers = &.{"B.Cu"},
            .keepout = .{ .tracks_allowed = false, .vias_allowed = true },
            .polygon = &zone_poly,
        },
    };
    const board = snapshot_mod.Snapshot{
        .layers = &layers,
        .footprints = &fps,
        .nets = &nets,
        .segments = &segments,
        .zones = &zones,
    };
    const got = try adapt(arena, board, null);
    try std.testing.expectEqual(@as(usize, 1), got.placement.parts.len);
    try std.testing.expectEqual(@as(f64, 10), got.placement.parts[0].x);
    try std.testing.expectEqual(@as(f64, -90), got.placement.parts[0].rot);
    try std.testing.expectEqualStrings("SIG", got.placement.nets[0].name);
    const options = try routeOptions(arena, got, board, &.{"OTHER"});
    try std.testing.expectEqual(@as(usize, 1), options.existing_tracks.len);
    try std.testing.expectEqual(@as(usize, 2), options.existing_zones.len);
    try std.testing.expect(options.existing_zones[0].copper);
    try std.testing.expect(!options.existing_zones[0].tracks_blocked);
    try std.testing.expect(!options.existing_zones[1].copper);
    try std.testing.expect(options.existing_zones[1].tracks_blocked);
    try std.testing.expect(!options.existing_zones[1].vias_blocked);
}

test "adapter reconstructs a rotated bottom KiCad pad centre" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layers = [_]snapshot_mod.Layer{
        .{ .name = "F.Cu", .copper = true },
        .{ .name = "B.Cu", .copper = true },
    };
    const pads = [_]snapshot_mod.Pad{.{
        .number = "4",
        .kind = "smd",
        .at = .{ .x = -1.5, .y = -0.5, .rotation_deg = 180 },
        .size = .{ .x = 0.3, .y = 0.8 },
        .layers = &.{"B.Cu"},
        .net = "PG",
    }};
    const footprints = [_]snapshot_mod.Footprint{.{
        .reference = "U1",
        .layer = "B.Cu",
        .at = .{ .x = 20, .y = 30, .rotation_deg = -90 },
        .pads = &pads,
    }};
    const nets = [_]snapshot_mod.Net{.{ .name = "PG" }};
    const got = try adapt(arena, .{
        .layers = &layers,
        .footprints = &footprints,
        .nets = &nets,
    }, null);
    const pad = got.placement.parts[0].pads[0];
    const world = optimizer.worldPadCenter(&got.placement.parts[0], pad.x, pad.y);
    try std.testing.expectApproxEqAbs(@as(f64, 20.5), world[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 28.5), world[1], 1e-9);
}

test "adapter applies KiCad differential width trace gap and via gap to both pair legs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layers = [_]snapshot_mod.Layer{
        .{ .name = "F.Cu", .copper = true },
        .{ .name = "B.Cu", .copper = true },
    };
    const nets = [_]snapshot_mod.Net{
        .{ .name = "D_P" },
        .{ .name = "D_N" },
    };
    const classes = [_]project_mod.NetClass{.{
        .name = "Default",
        .track_width = 0.127,
        .diff_pair_width = 0.2532,
        .diff_pair_gap = 0.1524,
        .diff_pair_via_gap = 0.2032,
    }};
    const got = try adapt(arena, .{
        .layers = &layers,
        .nets = &nets,
    }, .{ .net_classes = &classes });

    try std.testing.expectEqual(@as(usize, 1), got.placement.diff_pairs.len);
    for (got.placement.rules.net) |rule| {
        try std.testing.expectApproxEqAbs(@as(f64, 0.2532), rule.width, 1e-9);
        try std.testing.expectApproxEqAbs(@as(f64, 0.1524), rule.diff_gap, 1e-9);
    }
    try std.testing.expectApproxEqAbs(@as(f64, 0.2032), got.placement.diff_pairs[0].via_gap, 1e-9);
}

// spec: placement/router - KiCad pair names support P/N and +/- with trailing suffix digits, while pair rules inherit Default and respect board and physical-hole minima
test "adapter follows KiCad pair suffixes inheritance and minima" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const layers = [_]snapshot_mod.Layer{
        .{ .name = "F.Cu", .copper = true },
        .{ .name = "B.Cu", .copper = true },
    };
    const nets = [_]snapshot_mod.Net{
        .{ .name = "CLK+" },
        .{ .name = "CLK-" },
        .{ .name = "LANE_P_12" },
        .{ .name = "LANE_N_12" },
    };
    const classes = [_]project_mod.NetClass{
        .{
            .name = "Default",
            .track_width = 0.12,
            .diff_pair_width = 0.18,
            .diff_pair_gap = 0.08,
            .diff_pair_via_gap = 0.24,
            .via_diameter = 0.5,
            .via_drill = 0.3,
        },
        .{ .name = "Lane" },
    };
    const patterns = [_]project_mod.NetClassPattern{.{ .pattern = "LANE*", .net_class = "Lane" }};
    const got = try adapt(arena, .{ .layers = &layers, .nets = &nets }, .{
        .design = .{ .min_clearance = 0.1, .min_track_width = 0.15, .min_hole_clearance = 0.4 },
        .net_classes = &classes,
        .patterns = &patterns,
    });

    try std.testing.expectEqual(@as(usize, 2), got.placement.diff_pairs.len);
    try std.testing.expectEqual(@as(usize, 0), got.placement.diff_pairs[0].p);
    try std.testing.expectEqual(@as(usize, 1), got.placement.diff_pairs[0].n);
    try std.testing.expectEqual(@as(usize, 2), got.placement.diff_pairs[1].p);
    try std.testing.expectEqual(@as(usize, 3), got.placement.diff_pairs[1].n);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), got.placement.diff_pairs[1].gap, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), got.placement.diff_pairs[1].via_gap, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.18), got.placement.rules.net[2].width, 1e-9);
}
