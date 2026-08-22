//! Infer physical net aliases from copper that lands on a differently named
//! pad.  This handles imported/synchronized boards where pad net names were
//! updated but the already-routed copper retained an older name.  The analysis
//! is deliberately geometric: names are never compared heuristically.

const std = @import("std");
const snapshot_mod = @import("snapshot.zig");

const contact_slop_mm: f64 = 0.005;

/// Per-name evidence inside a physically connected alias component.
pub const Member = struct {
    name: []const u8,
    pads: usize,
    copper_items: usize,
};

/// Names joined by mismatched copper-to-pad physical contacts.
pub const Group = struct {
    canonical: []const u8,
    members: []const Member,
    contacts: usize,
    /// Safe means the contact component contains exactly one pad-bearing net.
    /// Only safe groups may be folded automatically.
    safe: bool,
};

/// Complete alias report plus the conservative safe-name resolution table.
pub const Analysis = struct {
    groups: []const Group,
    canonical_by_net: []const []const u8,
    safe_groups: usize,
    ambiguous_groups: usize,

    /// Resolve one source name through safe alias groups; unknown and
    /// ambiguous names are returned unchanged.
    pub fn canonicalName(self: Analysis, board: snapshot_mod.Snapshot, name: []const u8) []const u8 {
        for (board.nets, 0..) |net, i| {
            if (std.ascii.eqlIgnoreCase(net.name, name)) return self.canonical_by_net[i];
        }
        return name;
    }
};

const PhysicalPad = struct {
    net: usize,
    center: snapshot_mod.Point,
    width: f64,
    height: f64,
    rotation_deg: f64,
    shape: []const u8,
    roundrect_rratio: f64,
    poly: []const snapshot_mod.Point,
    layers: []const []const u8,
};

const Contact = struct { copper: usize, pad: usize };

const CopperPoint = struct {
    net: usize,
    point: snapshot_mod.Point,
    layer: []const u8,
    radius: f64,
};

/// Find connected components formed by a track/arc endpoint or via overlapping
/// a pad carrying a different net name.  Every returned group is auditable;
/// only a component with one pad-bearing name is marked safe for auto-folding.
pub fn analyze(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
) std.mem.Allocator.Error!Analysis {
    const count = board.nets.len;
    const parent = try arena.alloc(usize, count);
    const pad_counts = try arena.alloc(usize, count);
    const copper_counts = try arena.alloc(usize, count);
    for (parent, 0..) |*item, i| item.* = i;
    @memset(pad_counts, 0);
    @memset(copper_counts, 0);

    var index = std.StringHashMapUnmanaged(usize).empty;
    for (board.nets, 0..) |net, i| try index.put(arena, net.name, i);
    const pads = try physicalPads(arena, board, index, pad_counts);
    countCopper(board, index, copper_counts);

    var contacts: std.ArrayList(Contact) = .empty;
    for (board.segments) |segment| if (index.get(segment.net)) |copper| {
        try connectPoint(arena, &contacts, parent, pads, .{
            .net = copper,
            .point = segment.start,
            .layer = segment.layer,
            .radius = segment.width / 2,
        });
        try connectPoint(arena, &contacts, parent, pads, .{
            .net = copper,
            .point = segment.end,
            .layer = segment.layer,
            .radius = segment.width / 2,
        });
    };
    for (board.arcs) |arc| if (index.get(arc.net)) |copper| {
        try connectPoint(arena, &contacts, parent, pads, .{
            .net = copper,
            .point = arc.start,
            .layer = arc.layer,
            .radius = arc.width / 2,
        });
        try connectPoint(arena, &contacts, parent, pads, .{
            .net = copper,
            .point = arc.end,
            .layer = arc.layer,
            .radius = arc.width / 2,
        });
    };
    for (board.vias) |via| if (index.get(via.net)) |copper| {
        try connectVia(arena, &contacts, parent, pads, copper, via);
    };

    // Collapse roots before grouping so every member has a stable component.
    for (parent, 0..) |_, i| parent[i] = find(parent, i);
    var member_lists = try arena.alloc(std.ArrayList(Member), count);
    for (member_lists) |*list| list.* = .empty;
    for (board.nets, 0..) |net, i| try member_lists[parent[i]].append(arena, .{
        .name = net.name,
        .pads = pad_counts[i],
        .copper_items = copper_counts[i],
    });

    var groups: std.ArrayList(Group) = .empty;
    var canonical_by_net = try arena.alloc([]const u8, count);
    for (board.nets, canonical_by_net) |net, *canonical| canonical.* = net.name;
    var safe_groups: usize = 0;
    var ambiguous_groups: usize = 0;
    for (member_lists, 0..) |list, root| {
        if (list.items.len < 2) continue;
        var pad_bearing: usize = 0;
        var canonical = list.items[0].name;
        var most_pads: usize = 0;
        for (list.items) |member| if (member.pads > 0) {
            pad_bearing += 1;
            if (member.pads > most_pads) {
                most_pads = member.pads;
                canonical = member.name;
            }
        };
        const safe = pad_bearing == 1;
        if (safe) {
            safe_groups += 1;
            for (parent, 0..) |member_root, i| if (member_root == root) {
                canonical_by_net[i] = canonical;
            };
        } else {
            ambiguous_groups += 1;
        }
        var contact_count: usize = 0;
        for (contacts.items) |contact| if (parent[contact.copper] == root) {
            contact_count += 1;
        };
        try groups.append(arena, .{
            .canonical = canonical,
            .members = list.items,
            .contacts = contact_count,
            .safe = safe,
        });
    }
    return .{
        .groups = groups.items,
        .canonical_by_net = canonical_by_net,
        .safe_groups = safe_groups,
        .ambiguous_groups = ambiguous_groups,
    };
}

/// Return a routing-only snapshot whose safe alias components share their
/// single pad-bearing name.  All geometry and source strings are preserved;
/// only net tables and per-item net references are copied and normalized.
pub fn canonicalize(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
    analysis: Analysis,
) std.mem.Allocator.Error!snapshot_mod.Snapshot {
    var result = board;
    var nets: std.ArrayList(snapshot_mod.Net) = .empty;
    var seen = std.StringHashMapUnmanaged(void).empty;
    for (board.nets, 0..) |_, i| {
        const name = analysis.canonical_by_net[i];
        if (seen.contains(name)) continue;
        try seen.put(arena, name, {});
        try nets.append(arena, .{ .name = name });
    }
    result.nets = nets.items;

    const footprints = try arena.alloc(snapshot_mod.Footprint, board.footprints.len);
    for (board.footprints, footprints) |source, *footprint| {
        footprint.* = source;
        const pads = try arena.alloc(snapshot_mod.Pad, source.pads.len);
        for (source.pads, pads) |pad_source, *pad| {
            pad.* = pad_source;
            pad.net = analysis.canonicalName(board, pad_source.net);
        }
        footprint.pads = pads;
    }
    result.footprints = footprints;

    const segments = try arena.alloc(snapshot_mod.Segment, board.segments.len);
    for (board.segments, segments) |source, *item| {
        item.* = source;
        item.net = analysis.canonicalName(board, source.net);
    }
    result.segments = segments;
    const arcs = try arena.alloc(snapshot_mod.Arc, board.arcs.len);
    for (board.arcs, arcs) |source, *item| {
        item.* = source;
        item.net = analysis.canonicalName(board, source.net);
    }
    result.arcs = arcs;
    const vias = try arena.alloc(snapshot_mod.Via, board.vias.len);
    for (board.vias, vias) |source, *item| {
        item.* = source;
        item.net = analysis.canonicalName(board, source.net);
    }
    result.vias = vias;
    const zones = try arena.alloc(snapshot_mod.Zone, board.zones.len);
    for (board.zones, zones) |source, *item| {
        item.* = source;
        item.net = analysis.canonicalName(board, source.net);
    }
    result.zones = zones;
    return result;
}

fn physicalPads(
    arena: std.mem.Allocator,
    board: snapshot_mod.Snapshot,
    index: std.StringHashMapUnmanaged(usize),
    counts: []usize,
) std.mem.Allocator.Error![]const PhysicalPad {
    var out: std.ArrayList(PhysicalPad) = .empty;
    for (board.footprints) |fp| for (fp.pads) |pad| {
        const net = index.get(pad.net) orelse continue;
        counts[net] += 1;
        const angle = -fp.at.rotation_deg * std.math.pi / 180;
        const ca = @cos(angle);
        const sa = @sin(angle);
        try out.append(arena, .{
            .net = net,
            .center = .{
                .x = fp.at.x + pad.at.x * ca - pad.at.y * sa,
                .y = fp.at.y + pad.at.x * sa + pad.at.y * ca,
            },
            .width = pad.size.x,
            .height = pad.size.y,
            // KiCad serializes the pad's board-facing angle.  The adapter's
            // part+pad transform reduces to this same negated world angle.
            .rotation_deg = -pad.at.rotation_deg,
            .shape = pad.shape,
            .roundrect_rratio = pad.roundrect_rratio,
            .poly = pad.poly,
            .layers = pad.layers,
        });
    };
    return out.items;
}

fn countCopper(
    board: snapshot_mod.Snapshot,
    index: std.StringHashMapUnmanaged(usize),
    counts: []usize,
) void {
    for (board.segments) |item| if (index.get(item.net)) |i| {
        counts[i] += 1;
    };
    for (board.arcs) |item| if (index.get(item.net)) |i| {
        counts[i] += 1;
    };
    for (board.vias) |item| if (index.get(item.net)) |i| {
        counts[i] += 1;
    };
    for (board.zones) |item| if (index.get(item.net)) |i| {
        counts[i] += 1;
    };
}

fn connectPoint(
    arena: std.mem.Allocator,
    contacts: *std.ArrayList(Contact),
    parent: []usize,
    pads: []const PhysicalPad,
    point: CopperPoint,
) std.mem.Allocator.Error!void {
    for (pads) |pad| {
        if (pad.net == point.net or !onLayer(pad.layers, point.layer)) continue;
        if (!overlapsPad(pad, point.point, point.radius + contact_slop_mm)) continue;
        unite(parent, point.net, pad.net);
        try contacts.append(arena, .{ .copper = point.net, .pad = pad.net });
    }
}

fn connectVia(
    arena: std.mem.Allocator,
    contacts: *std.ArrayList(Contact),
    parent: []usize,
    pads: []const PhysicalPad,
    copper: usize,
    via: snapshot_mod.Via,
) std.mem.Allocator.Error!void {
    for (pads) |pad| {
        if (pad.net == copper or !layersOverlap(pad.layers, via.layers)) continue;
        if (!overlapsPad(pad, via.at, via.size / 2 + contact_slop_mm)) continue;
        unite(parent, copper, pad.net);
        try contacts.append(arena, .{ .copper = copper, .pad = pad.net });
    }
}

fn onLayer(layers: []const []const u8, want: []const u8) bool {
    for (layers) |layer| {
        if (std.mem.eql(u8, layer, "*.Cu") or std.mem.eql(u8, layer, want)) return true;
    }
    return false;
}

fn layersOverlap(a: []const []const u8, b: []const []const u8) bool {
    for (a) |layer| {
        if (std.mem.eql(u8, layer, "*.Cu")) return true;
        for (b) |other| if (std.mem.eql(u8, other, "*.Cu") or std.mem.eql(u8, layer, other)) return true;
    }
    return false;
}

fn overlapsPad(pad: PhysicalPad, point: snapshot_mod.Point, slack: f64) bool {
    const angle = -pad.rotation_deg * std.math.pi / 180;
    const ca = @cos(angle);
    const sa = @sin(angle);
    const dx = point.x - pad.center.x;
    const dy = point.y - pad.center.y;
    const local_x = dx * ca - dy * sa;
    const local_y = dx * sa + dy * ca;
    if (std.mem.eql(u8, pad.shape, "custom") and pad.poly.len >= 3) {
        return pointInPolygon(pad.poly, local_x, local_y) or
            pointPolygonEdgeDistance(pad.poly, local_x, local_y) <= slack;
    }
    const x = @abs(local_x);
    const y = @abs(local_y);
    const hw = pad.width / 2;
    const hh = pad.height / 2;
    if (std.mem.eql(u8, pad.shape, "circle") or std.mem.eql(u8, pad.shape, "oval")) {
        const rx = hw + slack;
        const ry = hh + slack;
        if (rx <= 0 or ry <= 0) return false;
        return x * x / (rx * rx) + y * y / (ry * ry) <= 1;
    }
    if (std.mem.eql(u8, pad.shape, "roundrect")) {
        const radius = @min(@max(pad.roundrect_rratio, 0) * @min(pad.width, pad.height), @min(hw, hh));
        const qx = @max(x - (hw - radius), 0);
        const qy = @max(y - (hh - radius), 0);
        return qx * qx + qy * qy <= (radius + slack) * (radius + slack);
    }
    return x <= hw + slack and y <= hh + slack;
}

fn pointInPolygon(poly: []const snapshot_mod.Point, x: f64, y: f64) bool {
    var inside = false;
    var previous = poly[poly.len - 1];
    for (poly) |point| {
        if ((point.y > y) != (previous.y > y)) {
            const crossing_x = point.x +
                (y - point.y) * (previous.x - point.x) / (previous.y - point.y);
            if (x < crossing_x) inside = !inside;
        }
        previous = point;
    }
    return inside;
}

fn pointPolygonEdgeDistance(poly: []const snapshot_mod.Point, x: f64, y: f64) f64 {
    var distance = std.math.inf(f64);
    var previous = poly[poly.len - 1];
    for (poly) |point| {
        const dx = point.x - previous.x;
        const dy = point.y - previous.y;
        const length_sq = dx * dx + dy * dy;
        const t = if (length_sq > 0)
            std.math.clamp(((x - previous.x) * dx + (y - previous.y) * dy) / length_sq, 0, 1)
        else
            0;
        distance = @min(distance, std.math.hypot(
            x - (previous.x + t * dx),
            y - (previous.y + t * dy),
        ));
        previous = point;
    }
    return distance;
}

fn find(parent: []usize, start: usize) usize {
    var item = start;
    while (parent[item] != item) item = parent[item];
    var cursor = start;
    while (parent[cursor] != cursor) {
        const next = parent[cursor];
        parent[cursor] = item;
        cursor = next;
    }
    return item;
}

fn unite(parent: []usize, a: usize, b: usize) void {
    const ra = find(parent, a);
    const rb = find(parent, b);
    if (ra != rb) parent[rb] = ra;
}

test "single pad-bearing contact group is a safe physical alias" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot_mod.Snapshot{
        .nets = &.{ .{ .name = "COPPER" }, .{ .name = "LOGICAL" } },
        .footprints = &.{.{
            .at = .{ .x = 10, .y = 20, .rotation_deg = 90 },
            .pads = &.{.{
                .at = .{ .x = 2, .y = 0 },
                .size = .{ .x = 1, .y = 1 },
                .shape = "circle",
                .layers = &.{"F.Cu"},
                .net = "LOGICAL",
            }},
        }},
        .segments = &.{.{
            .start = .{ .x = 10, .y = 18 },
            .end = .{ .x = 8, .y = 18 },
            .width = 0.2,
            .layer = "F.Cu",
            .net = "COPPER",
        }},
    };
    const result = try analyze(arena, board);
    try std.testing.expectEqual(@as(usize, 1), result.safe_groups);
    try std.testing.expectEqual(@as(usize, 0), result.ambiguous_groups);
    try std.testing.expectEqualStrings("LOGICAL", result.canonicalName(board, "COPPER"));
    const canonical = try canonicalize(arena, board, result);
    try std.testing.expectEqual(@as(usize, 1), canonical.nets.len);
    try std.testing.expectEqualStrings("LOGICAL", canonical.segments[0].net);
    try std.testing.expectEqualStrings("LOGICAL", canonical.footprints[0].pads[0].net);
}

test "one copper name joining two pad names is reported but not folded" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot_mod.Snapshot{
        .nets = &.{ .{ .name = "COPPER" }, .{ .name = "A" }, .{ .name = "B" } },
        .footprints = &.{
            .{ .at = .{ .x = 0, .y = 0 }, .pads = &.{.{
                .size = .{ .x = 1, .y = 1 },
                .shape = "rect",
                .layers = &.{"F.Cu"},
                .net = "A",
            }} },
            .{ .at = .{ .x = 5, .y = 0 }, .pads = &.{.{
                .size = .{ .x = 1, .y = 1 },
                .shape = "rect",
                .layers = &.{"F.Cu"},
                .net = "B",
            }} },
        },
        .segments = &.{.{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 5, .y = 0 },
            .width = 0.2,
            .layer = "F.Cu",
            .net = "COPPER",
        }},
    };
    const result = try analyze(arena, board);
    try std.testing.expectEqual(@as(usize, 0), result.safe_groups);
    try std.testing.expectEqual(@as(usize, 1), result.ambiguous_groups);
    try std.testing.expectEqualStrings("COPPER", result.canonicalName(board, "COPPER"));
}

test "custom pad aliases use the filled polygon rather than its bounds" {
    const triangle = [_]snapshot_mod.Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 2, .y = 0 },
        .{ .x = 0, .y = 2 },
    };
    const pad = PhysicalPad{
        .net = 0,
        .center = .{},
        .width = 4,
        .height = 4,
        .rotation_deg = 0,
        .shape = "custom",
        .roundrect_rratio = 0,
        .poly = &triangle,
        .layers = &.{"F.Cu"},
    };
    try std.testing.expect(overlapsPad(pad, .{ .x = 0.2, .y = 0.2 }, 0.01));
    try std.testing.expect(!overlapsPad(pad, .{ .x = 1.8, .y = 1.8 }, 0.01));
}
