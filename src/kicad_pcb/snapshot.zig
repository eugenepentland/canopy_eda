//! Normalized, read-only view of a KiCad PCB.  Unlike `reader.zig` (the board
//! sync seam), this module retains the physical facts a router/scorer needs:
//! fixed footprint poses and pads, authored copper, vias, zones/keepouts,
//! copper-layer metadata, and the Edge.Cuts outline.  The source AST is never
//! mutated and every returned slice is owned by the caller's arena.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser = @import("../sexpr/parser.zig");
const numeric = @import("../numeric.zig");
const board_layers = @import("../board_layers.zig");

const Node = ast.Node;

/// Parse failures from the shared S-expression parser or invalid board root.
pub const ParseError = error{InvalidPcbRoot} || std.mem.Allocator.Error || parser.ParseError;

/// A point in KiCad's board coordinate system, in millimetres.
pub const Point = struct {
    x: f64 = 0,
    y: f64 = 0,
};

/// A 2D board position and counter-clockwise rotation in degrees.
pub const Pose = struct {
    x: f64 = 0,
    y: f64 = 0,
    rotation_deg: f64 = 0,
};

/// One entry from the board's layer table.
pub const Layer = struct {
    id: i64 = -1,
    name: []const u8 = "",
    kind: []const u8 = "",
    user_name: []const u8 = "",
    copper: bool = false,
};

/// A distinct connected net encountered in the physical board.
pub const Net = struct {
    name: []const u8,
};

/// One footprint-local copper pad and its net assignment.
pub const Pad = struct {
    number: []const u8 = "",
    kind: []const u8 = "",
    shape: []const u8 = "",
    at: Pose = .{},
    size: Point = .{},
    drill: Point = .{},
    layers: []const []const u8 = &.{},
    net: []const u8 = "",
    roundrect_rratio: f64 = 0,
    /// Custom-pad primitive polygon in pad-local coordinates.  Empty for
    /// ordinary KiCad pad shapes.
    poly: []const Point = &.{},
};

/// The netlisp sync stamps read from a footprint's `(property "canopy_…" …)`
/// entries: `uuid` is the renumber-proof bridge back to a design instance's
/// exported UUID, `section` the authoring section label. Both are empty on
/// boards the netlisp KiCad sync has never touched.
pub const SyncStamps = struct {
    uuid: []const u8 = "",
    section: []const u8 = "",
};

/// A placed board footprint, including all physical pads.
pub const Footprint = struct {
    lib_id: []const u8 = "",
    uuid: []const u8 = "",
    reference: []const u8 = "",
    value: []const u8 = "",
    canopy: SyncStamps = .{},
    layer: []const u8 = "",
    at: Pose = .{},
    locked: bool = false,
    pads: []const Pad = &.{},
};

/// A straight routed copper segment.
pub const Segment = struct {
    start: Point = .{},
    end: Point = .{},
    width: f64 = 0,
    layer: []const u8 = "",
    net: []const u8 = "",
    uuid: []const u8 = "",
};

/// A circular routed copper arc represented by start/mid/end points.
pub const Arc = struct {
    start: Point = .{},
    mid: Point = .{},
    end: Point = .{},
    width: f64 = 0,
    layer: []const u8 = "",
    net: []const u8 = "",
    uuid: []const u8 = "",
};

/// A plated routing via and its layer span.
pub const Via = struct {
    at: Point = .{},
    size: f64 = 0,
    drill: f64 = 0,
    layers: []const []const u8 = &.{},
    net: []const u8 = "",
    uuid: []const u8 = "",
    kind: []const u8 = "through",
};

/// Per-item permissions attached to a KiCad keepout zone.
pub const Keepout = struct {
    tracks_allowed: bool = true,
    vias_allowed: bool = true,
    pads_allowed: bool = true,
    copper_pour_allowed: bool = true,
    footprints_allowed: bool = true,
};

/// One KiCad-computed filled polygon belonging to an authored zone. A zone
/// can have several disconnected fills (and, for multi-layer zones, fills on
/// several layers), so retain the layer on every polygon.
const ZoneFill = struct {
    layer: []const u8 = "",
    polygon: []const Point = &.{},
};

/// An authored copper zone or keepout, its boundary, and any filled polygons
/// KiCad persisted in the board file. `filled` is empty when the file carries
/// only the authored boundary (for example after zones were unfilled).
pub const Zone = struct {
    name: []const u8 = "",
    net: []const u8 = "",
    layers: []const []const u8 = &.{},
    uuid: []const u8 = "",
    priority: i64 = 0,
    clearance: f64 = 0,
    min_thickness: f64 = 0,
    keepout: ?Keepout = null,
    polygon: []const Point = &.{},
    filled: []const ZoneFill = &.{},
};

/// Supported Edge.Cuts primitive types.
pub const GraphicKind = enum { line, arc, rect, polygon };

/// Only board-graphics on Edge.Cuts are retained. `points` is start/end for a
/// line or rectangle, start/mid/end for an arc, and every vertex for a polygon.
pub const OutlineGraphic = struct {
    kind: GraphicKind,
    points: []const Point,
    width: f64 = 0,
    uuid: []const u8 = "",
};

/// Complete normalized physical model of one KiCad board.
pub const Snapshot = struct {
    version: i64 = 0,
    generator: []const u8 = "",
    generator_version: []const u8 = "",
    thickness_mm: f64 = 0,
    layers: []const Layer = &.{},
    nets: []const Net = &.{},
    footprints: []const Footprint = &.{},
    segments: []const Segment = &.{},
    arcs: []const Arc = &.{},
    vias: []const Via = &.{},
    zones: []const Zone = &.{},
    outline: []const OutlineGraphic = &.{},
};

/// Axis-aligned bounds with an explicit empty state.
pub const Bounds = struct {
    min: Point = .{},
    max: Point = .{},
    valid: bool = false,

    /// Horizontal extent, or zero when no point has been included.
    pub fn width(self: Bounds) f64 {
        return if (self.valid) self.max.x - self.min.x else 0;
    }

    /// Vertical extent, or zero when no point has been included.
    pub fn height(self: Bounds) f64 {
        return if (self.valid) self.max.y - self.min.y else 0;
    }

    fn include(self: *Bounds, p: Point) void {
        if (!self.valid) {
            self.min = p;
            self.max = p;
            self.valid = true;
            return;
        }
        self.min.x = @min(self.min.x, p.x);
        self.min.y = @min(self.min.y, p.y);
        self.max.x = @max(self.max.x, p.x);
        self.max.y = @max(self.max.y, p.y);
    }
};

/// Aggregate counts and routed length used by compact inspection reports.
pub const Summary = struct {
    footprints: usize = 0,
    top_footprints: usize = 0,
    bottom_footprints: usize = 0,
    pads: usize = 0,
    nets: usize = 0,
    segments: usize = 0,
    arcs: usize = 0,
    vias: usize = 0,
    zones: usize = 0,
    keepouts: usize = 0,
    outline_items: usize = 0,
    copper_length_mm: f64 = 0,
};

const Collector = struct {
    arena: std.mem.Allocator,
    net_names: std.ArrayList([]const u8) = .empty,
    net_index: std.StringHashMapUnmanaged(usize) = .empty,

    fn addNet(self: *Collector, name: []const u8) std.mem.Allocator.Error!void {
        if (name.len == 0 or self.net_index.contains(name)) return;
        const idx = self.net_names.items.len;
        try self.net_names.append(self.arena, name);
        try self.net_index.put(self.arena, name, idx);
    }

    fn freezeNets(self: *Collector) std.mem.Allocator.Error![]const Net {
        const out = try self.arena.alloc(Net, self.net_names.items.len);
        for (self.net_names.items, 0..) |name, i| out[i] = .{ .name = name };
        return out;
    }
};

/// Parse raw `.kicad_pcb` text into a normalized physical snapshot. Both
/// modern name-only `(net "GND")` references and legacy numeric net IDs are
/// accepted so old reference boards remain usable as training fixtures.
pub fn parse(arena: std.mem.Allocator, source: []const u8) ParseError!Snapshot {
    const nodes = try parser.parse(arena, source);
    if (nodes.len == 0 or !nodes[0].isForm("kicad_pcb")) return error.InvalidPcbRoot;
    const root = nodes[0].asList() orelse return error.InvalidPcbRoot;

    var legacy_nets = std.AutoHashMapUnmanaged(i64, []const u8).empty;
    for (root[1..]) |child| {
        if (!child.isForm("net")) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        const id = numeric.checkedInt(i64, cl[1].asNumber() orelse continue) orelse continue;
        const name = cl[2].asText() orelse continue;
        try legacy_nets.put(arena, id, name);
    }

    var result: Snapshot = .{};
    var layers: std.ArrayList(Layer) = .empty;
    var footprints: std.ArrayList(Footprint) = .empty;
    var segments: std.ArrayList(Segment) = .empty;
    var arcs: std.ArrayList(Arc) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    var zones: std.ArrayList(Zone) = .empty;
    var outline: std.ArrayList(OutlineGraphic) = .empty;
    var collector = Collector{ .arena = arena };

    for (root[1..]) |child| {
        if (child.isForm("version")) {
            result.version = formInt(child) orelse 0;
        } else if (child.isForm("generator")) {
            result.generator = formText(child) orelse "";
        } else if (child.isForm("generator_version")) {
            result.generator_version = formText(child) orelse "";
        } else if (child.isForm("general")) {
            result.thickness_mm = nestedNumber(child, "thickness") orelse 0;
        } else if (child.isForm("layers")) {
            try readLayers(arena, child, &layers);
        } else if (child.isForm("footprint")) {
            const fp = try readFootprint(arena, child, &legacy_nets, &collector);
            try footprints.append(arena, fp);
        } else if (child.isForm("segment")) {
            const item = readSegment(child, &legacy_nets);
            try collector.addNet(item.net);
            try segments.append(arena, item);
        } else if (child.isForm("arc")) {
            const item = readArc(child, &legacy_nets);
            try collector.addNet(item.net);
            try arcs.append(arena, item);
        } else if (child.isForm("via")) {
            const item = try readVia(arena, child, &legacy_nets);
            try collector.addNet(item.net);
            try vias.append(arena, item);
        } else if (child.isForm("zone")) {
            const item = try readZone(arena, child, &legacy_nets);
            try collector.addNet(item.net);
            try zones.append(arena, item);
        } else if (outlineKind(child)) |kind| {
            if (try readOutline(arena, child, kind)) |item| try outline.append(arena, item);
        }
    }

    result.layers = layers.items;
    result.nets = try collector.freezeNets();
    result.footprints = footprints.items;
    result.segments = segments.items;
    result.arcs = arcs.items;
    result.vias = vias.items;
    result.zones = zones.items;
    result.outline = outline.items;
    return result;
}

fn readLayers(arena: std.mem.Allocator, node: Node, out: *std.ArrayList(Layer)) std.mem.Allocator.Error!void {
    const cl = node.asList() orelse return;
    for (cl[1..]) |entry| {
        const el = entry.asList() orelse continue;
        if (el.len < 3) continue;
        const id = numeric.checkedInt(i64, el[0].asNumber() orelse continue) orelse continue;
        const name = el[1].asText() orelse continue;
        try out.append(arena, .{
            .id = id,
            .name = name,
            .kind = el[2].asText() orelse "",
            .user_name = if (el.len >= 4) el[3].asText() orelse "" else "",
            .copper = std.mem.endsWith(u8, name, ".Cu"),
        });
    }
}

fn readFootprint(
    arena: std.mem.Allocator,
    node: Node,
    legacy_nets: *const std.AutoHashMapUnmanaged(i64, []const u8),
    collector: *Collector,
) std.mem.Allocator.Error!Footprint {
    const cl = node.asList() orelse return .{};
    var fp: Footprint = .{ .lib_id = if (cl.len >= 2) cl[1].asText() orelse "" else "" };
    var pads: std.ArrayList(Pad) = .empty;
    for (cl[2..]) |sub| {
        if (sub.isForm("uuid")) {
            fp.uuid = formText(sub) orelse "";
        } else if (sub.isForm("layer")) {
            fp.layer = formText(sub) orelse "";
        } else if (sub.isForm("at")) {
            fp.at = readPose(sub);
        } else if (sub.isForm("locked")) {
            fp.locked = readAllowed(sub);
        } else if (sub.isForm("property")) {
            const pl = sub.asList() orelse continue;
            if (pl.len < 3) continue;
            const key = pl[1].asText() orelse continue;
            const value = pl[2].asText() orelse continue;
            if (std.mem.eql(u8, key, "Reference")) {
                fp.reference = value;
            } else if (std.mem.eql(u8, key, "Value")) {
                fp.value = value;
            } else if (std.mem.eql(u8, key, "canopy_section")) {
                fp.canopy.section = value;
            } else if (std.mem.eql(u8, key, "canopy_uuid")) {
                fp.canopy.uuid = value;
            }
        } else if (sub.isForm("pad")) {
            const pad = try readPad(arena, sub, legacy_nets);
            try collector.addNet(pad.net);
            try pads.append(arena, pad);
        }
    }
    fp.pads = pads.items;
    return fp;
}

fn readPad(
    arena: std.mem.Allocator,
    node: Node,
    legacy_nets: *const std.AutoHashMapUnmanaged(i64, []const u8),
) std.mem.Allocator.Error!Pad {
    const cl = node.asList() orelse return .{};
    var pad: Pad = .{};
    if (cl.len >= 2) pad.number = cl[1].tokenText(arena) orelse "";
    if (cl.len >= 3) pad.kind = cl[2].asText() orelse "";
    if (cl.len >= 4) pad.shape = cl[3].asText() orelse "";
    for (cl[4..]) |sub| {
        if (sub.isForm("at")) {
            pad.at = readPose(sub);
        } else if (sub.isForm("size")) {
            pad.size = readPoint(sub) orelse .{};
        } else if (sub.isForm("drill")) {
            pad.drill = readDrill(sub);
        } else if (sub.isForm("layers")) {
            pad.layers = try readTextTail(arena, sub);
        } else if (sub.isForm("net")) {
            pad.net = resolveNet(sub, legacy_nets);
        } else if (sub.isForm("roundrect_rratio")) {
            pad.roundrect_rratio = formNumber(sub) orelse 0;
        } else if (sub.isForm("primitives")) {
            pad.poly = try readCustomPadPoly(arena, sub);
        }
    }
    return pad;
}

fn readCustomPadPoly(
    arena: std.mem.Allocator,
    primitives: Node,
) std.mem.Allocator.Error![]const Point {
    const children = primitives.asList() orelse return &.{};
    for (children[1..]) |primitive| {
        if (!primitive.isForm("gr_poly")) continue;
        const graphic = primitive.asList() orelse continue;
        for (graphic[1..]) |child| {
            if (!child.isForm("pts")) continue;
            const points = child.asList() orelse continue;
            var out: std.ArrayList(Point) = .empty;
            for (points[1..]) |point| {
                if (!point.isForm("xy")) continue;
                if (readPoint(point)) |value| try out.append(arena, value);
            }
            if (out.items.len >= 3) return out.items;
        }
    }
    return &.{};
}

fn readSegment(node: Node, legacy_nets: *const std.AutoHashMapUnmanaged(i64, []const u8)) Segment {
    var item: Segment = .{};
    const cl = node.asList() orelse return item;
    for (cl[1..]) |sub| {
        readTrackCommon(sub, legacy_nets, &item.width, &item.layer, &item.net, &item.uuid);
        if (sub.isForm("start")) item.start = readPoint(sub) orelse .{};
        if (sub.isForm("end")) item.end = readPoint(sub) orelse .{};
    }
    return item;
}

fn readArc(node: Node, legacy_nets: *const std.AutoHashMapUnmanaged(i64, []const u8)) Arc {
    var item: Arc = .{};
    const cl = node.asList() orelse return item;
    for (cl[1..]) |sub| {
        readTrackCommon(sub, legacy_nets, &item.width, &item.layer, &item.net, &item.uuid);
        if (sub.isForm("start")) item.start = readPoint(sub) orelse .{};
        if (sub.isForm("mid")) item.mid = readPoint(sub) orelse .{};
        if (sub.isForm("end")) item.end = readPoint(sub) orelse .{};
    }
    return item;
}

fn readVia(
    arena: std.mem.Allocator,
    node: Node,
    legacy_nets: *const std.AutoHashMapUnmanaged(i64, []const u8),
) std.mem.Allocator.Error!Via {
    var item: Via = .{};
    const cl = node.asList() orelse return item;
    if (cl.len >= 2) {
        if (cl[1].asText()) |kind| item.kind = kind;
    }
    for (cl[1..]) |sub| {
        if (sub.isForm("at")) {
            item.at = readPoint(sub) orelse .{};
        } else if (sub.isForm("size")) {
            item.size = formNumber(sub) orelse 0;
        } else if (sub.isForm("drill")) {
            item.drill = firstNumericTail(sub) orelse 0;
        } else if (sub.isForm("layers")) {
            item.layers = try readTextTail(arena, sub);
        } else if (sub.isForm("net")) {
            item.net = resolveNet(sub, legacy_nets);
        } else if (sub.isForm("uuid")) {
            item.uuid = formText(sub) orelse "";
        }
    }
    return item;
}

fn readZone(
    arena: std.mem.Allocator,
    node: Node,
    legacy_nets: *const std.AutoHashMapUnmanaged(i64, []const u8),
) std.mem.Allocator.Error!Zone {
    var item: Zone = .{};
    var filled: std.ArrayList(ZoneFill) = .empty;
    const cl = node.asList() orelse return item;
    for (cl[1..]) |sub| {
        if (sub.isForm("net")) {
            item.net = resolveNet(sub, legacy_nets);
        } else if (sub.isForm("name")) {
            item.name = formText(sub) orelse "";
        } else if (sub.isForm("layer")) {
            item.layers = try oneText(arena, formText(sub) orelse "");
        } else if (sub.isForm("layers")) {
            item.layers = try readTextTail(arena, sub);
        } else if (sub.isForm("uuid")) {
            item.uuid = formText(sub) orelse "";
        } else if (sub.isForm("priority")) {
            item.priority = formInt(sub) orelse 0;
        } else if (sub.isForm("min_thickness")) {
            item.min_thickness = formNumber(sub) orelse 0;
        } else if (sub.isForm("connect_pads")) {
            item.clearance = nestedNumber(sub, "clearance") orelse 0;
        } else if (sub.isForm("keepout")) {
            item.keepout = readKeepout(sub);
        } else if (sub.isForm("polygon")) {
            item.polygon = try readPolygon(arena, sub);
        } else if (sub.isForm("filled_polygon")) {
            const poly = try readZoneFill(arena, sub);
            if (poly.polygon.len >= 3) try filled.append(arena, poly);
        }
    }
    item.filled = filled.items;
    return item;
}

/// Read `(filled_polygon (layer "F.Cu") … (pts …))`. Unknown KiCad fields
/// such as `(island)` are intentionally ignored; the physical polygon and its
/// layer are the stable data needed by review/debug views.
fn readZoneFill(arena: std.mem.Allocator, node: Node) std.mem.Allocator.Error!ZoneFill {
    var out: ZoneFill = .{};
    const cl = node.asList() orelse return out;
    for (cl[1..]) |sub| {
        if (sub.isForm("layer")) {
            out.layer = formText(sub) orelse "";
        } else if (sub.isForm("pts")) {
            out.polygon = try readPointList(arena, sub);
        }
    }
    return out;
}

fn readKeepout(node: Node) Keepout {
    var out: Keepout = .{};
    const cl = node.asList() orelse return out;
    for (cl[1..]) |sub| {
        const allowed = readAllowed(sub);
        if (sub.isForm("tracks")) {
            out.tracks_allowed = allowed;
        } else if (sub.isForm("vias")) {
            out.vias_allowed = allowed;
        } else if (sub.isForm("pads")) {
            out.pads_allowed = allowed;
        } else if (sub.isForm("copperpour")) {
            out.copper_pour_allowed = allowed;
        } else if (sub.isForm("footprints")) {
            out.footprints_allowed = allowed;
        }
    }
    return out;
}

fn readPolygon(arena: std.mem.Allocator, node: Node) std.mem.Allocator.Error![]const Point {
    const cl = node.asList() orelse return &.{};
    for (cl[1..]) |sub| {
        if (!sub.isForm("pts")) continue;
        return readPointList(arena, sub);
    }
    return &.{};
}

fn readPointList(arena: std.mem.Allocator, node: Node) std.mem.Allocator.Error![]const Point {
    var out: std.ArrayList(Point) = .empty;
    const cl = node.asList() orelse return out.items;
    for (cl[1..]) |xy| if (readPoint(xy)) |p| try out.append(arena, p);
    return out.items;
}

fn outlineKind(node: Node) ?GraphicKind {
    if (node.isForm("gr_line")) return .line;
    if (node.isForm("gr_arc")) return .arc;
    if (node.isForm("gr_rect")) return .rect;
    if (node.isForm("gr_poly")) return .polygon;
    return null;
}

fn readOutline(
    arena: std.mem.Allocator,
    node: Node,
    kind: GraphicKind,
) std.mem.Allocator.Error!?OutlineGraphic {
    const cl = node.asList() orelse return null;
    var layer: []const u8 = "";
    var uuid: []const u8 = "";
    var width: f64 = 0;
    var points: std.ArrayList(Point) = .empty;
    for (cl[1..]) |sub| {
        if (sub.isForm("layer")) {
            layer = formText(sub) orelse "";
        } else if (sub.isForm("uuid")) {
            uuid = formText(sub) orelse "";
        } else if (sub.isForm("stroke")) {
            width = nestedNumber(sub, "width") orelse 0;
        } else if (sub.isForm("start") or sub.isForm("mid") or sub.isForm("end")) {
            if (readPoint(sub)) |p| try points.append(arena, p);
        } else if (sub.isForm("pts")) {
            const pl = sub.asList() orelse continue;
            for (pl[1..]) |xy| if (readPoint(xy)) |p| try points.append(arena, p);
        }
    }
    if (!std.mem.eql(u8, layer, board_layers.edge_cuts)) return null;
    return .{ .kind = kind, .points = points.items, .width = width, .uuid = uuid };
}

fn readPose(node: Node) Pose {
    const cl = node.asList() orelse return .{};
    return .{
        .x = if (cl.len >= 2) cl[1].asNumber() orelse 0 else 0,
        .y = if (cl.len >= 3) cl[2].asNumber() orelse 0 else 0,
        .rotation_deg = if (cl.len >= 4) cl[3].asNumber() orelse 0 else 0,
    };
}

fn readTrackCommon(
    node: Node,
    legacy_nets: *const std.AutoHashMapUnmanaged(i64, []const u8),
    width: *f64,
    layer: *[]const u8,
    net: *[]const u8,
    uuid: *[]const u8,
) void {
    if (node.isForm("width")) width.* = formNumber(node) orelse 0;
    if (node.isForm("layer")) layer.* = formText(node) orelse "";
    if (node.isForm("net")) net.* = resolveNet(node, legacy_nets);
    if (node.isForm("uuid")) uuid.* = formText(node) orelse "";
}

fn readPoint(node: Node) ?Point {
    const cl = node.asList() orelse return null;
    if (cl.len < 3) return null;
    return .{ .x = cl[1].asNumber() orelse return null, .y = cl[2].asNumber() orelse return null };
}

fn readDrill(node: Node) Point {
    const cl = node.asList() orelse return .{};
    var values: [2]f64 = .{ 0, 0 };
    var count: usize = 0;
    for (cl[1..]) |n| if (n.asNumber()) |v| {
        if (count < values.len) values[count] = v;
        count += 1;
    };
    if (count == 1) values[1] = values[0];
    return .{ .x = values[0], .y = values[1] };
}

fn resolveNet(node: Node, legacy_nets: *const std.AutoHashMapUnmanaged(i64, []const u8)) []const u8 {
    const cl = node.asList() orelse return "";
    if (cl.len < 2) return "";
    if (cl[1].asText()) |name| return name;
    const id = numeric.checkedInt(i64, cl[1].asNumber() orelse return "") orelse return "";
    if (cl.len >= 3) {
        if (cl[2].asText()) |name| return name;
    }
    return legacy_nets.get(id) orelse "";
}

fn readTextTail(arena: std.mem.Allocator, node: Node) std.mem.Allocator.Error![]const []const u8 {
    const cl = node.asList() orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (cl[1..]) |n| if (n.asText()) |text| try out.append(arena, text);
    return out.items;
}

fn oneText(arena: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const []const u8 {
    if (value.len == 0) return &.{};
    const out = try arena.alloc([]const u8, 1);
    out[0] = value;
    return out;
}

fn readAllowed(node: Node) bool {
    const value = formText(node) orelse return true;
    return std.mem.eql(u8, value, "yes") or std.mem.eql(u8, value, "allowed") or std.mem.eql(u8, value, "true");
}

fn formText(node: Node) ?[]const u8 {
    const cl = node.asList() orelse return null;
    return if (cl.len >= 2) cl[1].asText() else null;
}

fn formNumber(node: Node) ?f64 {
    const cl = node.asList() orelse return null;
    return if (cl.len >= 2) cl[1].asNumber() else null;
}

fn formInt(node: Node) ?i64 {
    return numeric.checkedInt(i64, formNumber(node) orelse return null);
}

fn firstNumericTail(node: Node) ?f64 {
    const cl = node.asList() orelse return null;
    for (cl[1..]) |n| if (n.asNumber()) |v| return v;
    return null;
}

fn nestedNumber(node: Node, name: []const u8) ?f64 {
    const cl = node.asList() orelse return null;
    for (cl[1..]) |sub| if (sub.isForm(name)) return formNumber(sub);
    return null;
}

/// Axis-aligned bounds of every authored Edge.Cuts primitive.
pub fn outlineBounds(snapshot: Snapshot) Bounds {
    var bounds: Bounds = .{};
    for (snapshot.outline) |graphic| for (graphic.points) |p| bounds.include(p);
    return bounds;
}

/// Euclidean length of one straight track segment.
pub fn segmentLength(item: Segment) f64 {
    return std.math.hypot(item.end.x - item.start.x, item.end.y - item.start.y);
}

/// Length of the circular path from start to end that passes through mid.
pub fn arcLength(item: Arc) f64 {
    const ax = item.start.x;
    const ay = item.start.y;
    const bx = item.mid.x;
    const by = item.mid.y;
    const cx = item.end.x;
    const cy = item.end.y;
    const d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by));
    if (@abs(d) < 1e-12) return std.math.hypot(bx - ax, by - ay) + std.math.hypot(cx - bx, cy - by);
    const a2 = ax * ax + ay * ay;
    const b2 = bx * bx + by * by;
    const c2 = cx * cx + cy * cy;
    const ux = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d;
    const uy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d;
    const radius = std.math.hypot(ax - ux, ay - uy);
    const tau = 2 * std.math.pi;
    const start_a = std.math.atan2(ay - uy, ax - ux);
    const mid_a = std.math.atan2(by - uy, bx - ux);
    const end_a = std.math.atan2(cy - uy, cx - ux);
    const ccw_end = @mod(end_a - start_a + tau, tau);
    const ccw_mid = @mod(mid_a - start_a + tau, tau);
    const sweep = if (ccw_mid <= ccw_end + 1e-9) ccw_end else tau - ccw_end;
    return radius * sweep;
}

/// Aggregate physical item counts and total authored track length.
pub fn summarize(snapshot: Snapshot) Summary {
    var out: Summary = .{
        .footprints = snapshot.footprints.len,
        .nets = snapshot.nets.len,
        .segments = snapshot.segments.len,
        .arcs = snapshot.arcs.len,
        .vias = snapshot.vias.len,
        .zones = snapshot.zones.len,
        .outline_items = snapshot.outline.len,
    };
    for (snapshot.footprints) |fp| {
        out.pads += fp.pads.len;
        if (std.mem.eql(u8, fp.layer, board_layers.b_cu)) out.bottom_footprints += 1 else out.top_footprints += 1;
    }
    for (snapshot.segments) |item| out.copper_length_mm += segmentLength(item);
    for (snapshot.arcs) |item| out.copper_length_mm += arcLength(item);
    for (snapshot.zones) |zone| out.keepouts += @intFromBool(zone.keepout != null);
    return out;
}

test "normalized snapshot retains placement copper zones and outline" {
    // The golden board this test reads. It spells KiCad's layer names by hand
    // on purpose: an expectation derived from `board_layers` would only prove
    // the reader agrees with itself.
    const test_board =
        \\(kicad_pcb (version 20260206) (generator "pcbnew") (generator_version "10.0")
        \\  (general (thickness 1.2))
        \\  (layers (0 "F.Cu" signal) (2 "B.Cu" signal) (25 "Edge.Cuts" user))
        \\  (footprint "R_0402" (layer "F.Cu") (at 10 20 90)
        \\    (property "Reference" "R1") (property "Value" "10k")
        \\    (property "canopy_uuid" "11111111-2222-5333-8444-555555555555")
        \\    (pad "1" smd roundrect (at -0.5 0) (size 0.5 0.6) (roundrect_rratio 0.2)
        \\      (layers "F.Cu" "F.Mask") (net "SIG")))
        \\  (gr_line (start 0 0) (end 20 0) (stroke (width 0.05)) (layer "Edge.Cuts"))
        \\  (gr_line (start 20 0) (end 20 10) (stroke (width 0.05)) (layer "Edge.Cuts"))
        \\  (segment (start 1 2) (end 4 6) (width 0.2) (layer "F.Cu") (net "SIG"))
        \\  (via (at 4 6) (size 0.6) (drill 0.3) (layers "F.Cu" "B.Cu") (net "SIG"))
        \\  (zone (layers "F.Cu" "B.Cu") (keepout (tracks not_allowed) (vias allowed))
        \\    (polygon (pts (xy 2 2) (xy 3 2) (xy 3 3))))
        \\  (zone (net "SIG") (layer "F.Cu")
        \\    (polygon (pts (xy 4 2) (xy 8 2) (xy 8 6) (xy 4 6)))
        \\    (filled_polygon (layer "F.Cu") (island)
        \\      (pts (xy 4.1 2.1) (xy 7.9 2.1) (xy 7.9 5.9) (xy 4.1 5.9)))))
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const board = try parse(arena_state.allocator(), test_board);
    const summary = summarize(board);
    try std.testing.expectEqual(@as(i64, 20260206), board.version);
    try std.testing.expectEqual(@as(usize, 3), board.layers.len);
    try std.testing.expectEqual(@as(usize, 1), summary.footprints);
    try std.testing.expectEqual(@as(usize, 1), summary.nets);
    try std.testing.expectApproxEqAbs(@as(f64, 5), summary.copper_length_mm, 1e-9);
    try std.testing.expectEqualStrings("SIG", board.footprints[0].pads[0].net);
    try std.testing.expectEqualStrings(
        "11111111-2222-5333-8444-555555555555",
        board.footprints[0].canopy.uuid,
    );
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), board.footprints[0].pads[0].roundrect_rratio, 1e-9);
    try std.testing.expect(board.zones[0].keepout != null);
    try std.testing.expect(!board.zones[0].keepout.?.tracks_allowed);
    try std.testing.expectEqual(@as(usize, 1), board.zones[1].filled.len);
    try std.testing.expectEqualStrings("F.Cu", board.zones[1].filled[0].layer);
    try std.testing.expectEqual(@as(usize, 4), board.zones[1].filled[0].polygon.len);
    try std.testing.expectApproxEqAbs(@as(f64, 7.9), board.zones[1].filled[0].polygon[2].x, 1e-9);
    const bounds = outlineBounds(board);
    try std.testing.expectApproxEqAbs(@as(f64, 20), bounds.width(), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10), bounds.height(), 1e-9);
}

test "arc length follows the path through its midpoint" {
    const arc = Arc{ .start = .{ .x = 1, .y = 0 }, .mid = .{ .x = 0, .y = 1 }, .end = .{ .x = -1, .y = 0 } };
    try std.testing.expectApproxEqAbs(std.math.pi, arcLength(arc), 1e-9);
}

test "normalized snapshot retains custom pad primitive polygons" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const board = try parse(arena_state.allocator(),
        \\(kicad_pcb (footprint "U" (layer "B.Cu")
        \\  (pad 1 smd custom (at 1 2 90) (size 0.2 0.2) (layers "B.Cu")
        \\    (primitives (gr_poly (pts (xy -1 -2) (xy 3 -2) (xy 0 4)))))))
    );
    const poly = board.footprints[0].pads[0].poly;
    try std.testing.expectEqual(@as(usize, 3), poly.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3), poly[1].x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4), poly[2].y, 1e-9);
}
