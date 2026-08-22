//! JSON serialization for computed outer-layer copper pours.
//! Shared by the initial PCB blob and live in-browser refill requests.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const implicit_plane = @import("../placement/implicit_plane.zig");
const optimizer = @import("../placement/optimizer.zig");
const pour = @import("../placement/pour.zig");

/// Write the actual kept outer-pour contours for `placement` and live `copper`.
/// `zones` are the board's user copper pours: any of them ranked above this
/// declared pour (priority > 0, same face, different net) is cleared out of the
/// fill, so a declared `(pour bottom "GND")` recedes around a ranked rail zone
/// instead of shorting to it (`pour.higherThanDeclared`).
///
/// Each entry names its copper layer TWICE on purpose: `"layer"` is the
/// canonical key every blob geometry carries — the KiCad name off the shared
/// layer table, which the viewer resolves to a stack row and a routable index
/// — while `"side"` stays for the cheap top/bottom face tests the painter makes
/// per frame. The two can never disagree: both come from the same `side`.
pub fn writePours(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: pour.Copper,
    zones: []const pour.UserZone,
    base: ?pour.EdgeField,
) std.Io.Writer.Error!void {
    try w.writeByte('[');
    var first = true;
    const stack = placement.rules.layerStack();
    var name_buf: [board_layers.name_buf_len]u8 = undefined;
    // Both faces pour the same outline on the same lattice.
    var edge = LazyEdge{ .alloc = alloc, .placement = placement, .base = base };
    for ([_]optimizer.Side{ .top, .bottom }) |side| {
        const net = placement.rules.pourNetOnSide(side) orelse continue;
        const sig = if (side == .top) board_layers.SignalIndex.top else board_layers.SignalIndex.bottom;
        const layer_name = stack.signalName(sig, &name_buf);
        var spec = pour.outerSpec(net, side);
        spec.higher = pour.higherThanDeclared(alloc, zones, if (side == .top) 0 else 1, spec.net) catch &.{};
        const fill = pour.computeShared(alloc, placement, copper, spec, edge.get()) catch continue;
        for (fill.contours, 0..) |poly, ci| {
            if (poly.len < 3) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"layer\":\"{s}\",\"side\":\"{s}\",\"net\":", .{ layer_name, if (side == .top) "top" else "bottom" });
            try writeString(w, net);
            try writePolyAndHoles(w, poly, fill.holes[ci]);
            try w.writeByte('}');
        }
    }
    try w.writeByte(']');
}

/// Write the actual copper on every plane-only inner layer. Unlike `writePours`,
/// these entries are keyed by their 1-based physical stack index because they
/// have no routable signal-layer index. The same fill engine feeds fabrication,
/// connectivity, and this view, so foreign through vias appear as real antipad
/// holes rather than a cosmetic solid-colour sheet.
pub fn writePlaneFillsField(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: pour.Copper,
    omit: bool,
    base: ?pour.EdgeField,
) std.Io.Writer.Error!void {
    try w.writeAll(",\"plane_fills\":");
    if (omit) return w.writeAll("[]");
    try w.writeByte('[');
    var first = true;
    // Every plane-only inner layer fills the same outline on the same lattice.
    var edge = LazyEdge{ .alloc = alloc, .placement = placement, .base = base };
    if (!placement.rules.declaredStackup()) {
        const planes = implicit_plane.innerPlanes(placement.rules);
        for (planes, 0..) |plane, off| {
            const stack: u8 = @intCast(implicit_plane.ground_index + off);
            const spec: pour.LayerSpec = switch (plane) {
                .ground => .{ .net = .ground, .keep_unseeded = true },
                .rail => |net| .{ .net = .{ .named = net }, .keep_unseeded = true },
            };
            const label = switch (plane) {
                .ground => "GND",
                .rail => |net| net,
            };
            try writePlaneFill(w, alloc, placement, copper, .{ .stack = stack, .net = label, .spec = spec, .base = edge.get() }, &first);
        }
    } else {
        const bottom = if (placement.rules.copper_layers >= 2) placement.rules.copper_layers else 0;
        for (placement.rules.planes.declared) |plane| {
            if (plane.index == 1 or plane.index == bottom) continue;
            try writePlaneFill(w, alloc, placement, copper, .{
                .stack = plane.index,
                .net = plane.net,
                .spec = .{ .net = .{ .named = plane.net }, .keep_unseeded = true },
                .base = edge.get(),
            }, &first);
        }
    }
    try w.writeByte(']');
}

/// One plane-only inner layer to fill: its 1-based physical stack index, the
/// net label the entry carries, the fill spec, and the caller's shared
/// board-edge margin field (`pour.sharedEdgeField`) — carried here rather than
/// as a seventh parameter, since it is as much an input to this one fill as the
/// spec is.
/// A board-edge margin field seeded at most once, and only on the first fill
/// that actually wants it. Every writer here starts one and hands `get()` to
/// each `pour.computeShared`, so a board pours its outline once for all of its
/// fills — while a board with NOTHING to pour (no declared pour, no plane, no
/// zone) allocates no raster at all, and a caller that passes a non-arena
/// allocator is never handed one to free.
const LazyEdge = struct {
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    /// The caller's shared field when the whole render pours the same board
    /// (`pour.sharedEdgeField` seeded once at the top) — returned as-is so the
    /// outline walk is not repeated per writer.
    base: ?pour.EdgeField = null,
    field: ?pour.EdgeField = null,
    seeded: bool = false,

    fn get(self: *LazyEdge) ?pour.EdgeField {
        if (self.base) |b| return b;
        if (!self.seeded) {
            self.seeded = true;
            self.field = pour.sharedEdgeField(self.alloc, self.placement) catch null;
        }
        return self.field;
    }
};

const PlaneFillReq = struct { stack: u8, net: []const u8, spec: pour.LayerSpec, base: ?pour.EdgeField = null };

fn writePlaneFill(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: pour.Copper,
    req: PlaneFillReq,
    first: *bool,
) std.Io.Writer.Error!void {
    const fill = pour.computeShared(alloc, placement, copper, req.spec, req.base) catch return;
    var name_buf: [board_layers.name_buf_len]u8 = undefined;
    const stack = placement.rules.layerStack();
    const layer_name = stack.nameOfStack(board_layers.StackIndex.of(req.stack), &name_buf);
    for (fill.contours, 0..) |poly, ci| {
        if (poly.len < 3) continue;
        if (!first.*) try w.writeByte(',');
        first.* = false;
        try w.print("{{\"stack\":{d},\"layer\":", .{req.stack});
        try writeString(w, layer_name);
        try w.writeAll(",\"net\":");
        try writeString(w, req.net);
        try writePolyAndHoles(w, poly, fill.holes[ci]);
        try w.writeByte('}');
    }
}

/// One hand-drawn user pour to compute a carved fill for: its index into the
/// board blob's `"zones"` array (so the client can map a fill back to its
/// zone), the flattened net it carries, the KiCad copper-layer NAME it sits on
/// (emitted verbatim so the viewer keys painting/dimming off the physical
/// layer), the outer face (`null` = an inner layer), the signal-layer index
/// whose same-layer tracks the fill carves as foreign, and the drawn boundary
/// polygon. The serve layer filters to filled/netted/non-keepout zones on a
/// routable signal layer before building these.
pub const ZoneFillReq = struct {
    index: usize,
    net: []const u8,
    layer_name: []const u8,
    side: ?optimizer.Side,
    track_layer: u8,
    poly: []const [2]f64,
    /// Boundary polygons of the higher-priority overlapping pours this fill must
    /// clear (`pour.higherPolys`, built by the serve layer from each zone's
    /// priority) — threaded straight into `LayerSpec.higher`.
    higher: []const []const [2]f64 = &.{},
};

/// Write the carved fills for user-drawn copper pours as
/// `[{"zone":i,"layer":"F.Cu","side":"top","net":"…","poly":[…],"holes":[…]},…]`
/// — the same contour shape `writePours` emits, plus a `"zone"` index and the
/// zone's KiCad `"layer"` name. An OUTER zone also carries `"side":"top|bottom"`;
/// an INNER zone omits `"side"` entirely (its layer is named by `"layer"`, e.g.
/// `"In2.Cu"`). Each request's fill is computed identically to a declared pour
/// (`pour.zoneLayerSpec`), against the live `copper`, so blob and refill agree
/// with the Gerber. Emits `[]` when no zone yields a contour.
pub fn writeZoneFills(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: pour.Copper,
    zones: []const ZoneFillReq,
    base: ?pour.EdgeField,
) std.Io.Writer.Error!void {
    try w.writeByte('[');
    var first = true;
    // Every zone carves the same outline on the same lattice.
    var edge = LazyEdge{ .alloc = alloc, .placement = placement, .base = base };
    for (zones) |z| {
        var spec = pour.zoneLayerSpec(z.net, z.side, z.track_layer, z.poly);
        spec.higher = z.higher;
        const fill = pour.computeShared(alloc, placement, copper, spec, edge.get()) catch continue;
        for (fill.contours, 0..) |poly, ci| {
            if (poly.len < 3) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"zone\":{d},\"layer\":", .{z.index});
            try writeString(w, z.layer_name);
            if (z.side) |s| try w.print(",\"side\":\"{s}\"", .{if (s == .top) "top" else "bottom"});
            try w.writeAll(",\"net\":");
            try writeString(w, z.net);
            try writePolyAndHoles(w, poly, fill.holes[ci]);
            try w.writeByte('}');
        }
    }
    try w.writeByte(']');
}

/// Emit `,"poly":[[x,y],…]` for a contour then its `,"holes":[…]` — the shared
/// body of a declared-pour entry and a user-zone fill, so both write copper the
/// viewer paints even-odd (contour minus holes) identically.
fn writePolyAndHoles(w: *std.Io.Writer, poly: []const [2]f64, holes: []const []const [2]f64) std.Io.Writer.Error!void {
    try w.writeAll(",\"poly\":[");
    for (poly, 0..) |pt, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("[{d},{d}]", .{ pt[0], pt[1] });
    }
    try w.writeAll("]");
    try writeHoles(w, holes);
}

/// Emit a compact `,"holes":[[[x,y],…],…]` for a contour's interior antipad
/// loops — the key is OMITTED entirely when there are none (or all degenerate),
/// so a hole-free pour stays a minimal blob the viewer tolerates.
fn writeHoles(w: *std.Io.Writer, holes: []const []const [2]f64) std.Io.Writer.Error!void {
    var any = false;
    for (holes) |h| {
        if (h.len < 3) continue;
        if (!any) {
            try w.writeAll(",\"holes\":[");
            any = true;
        } else try w.writeByte(',');
        try w.writeByte('[');
        for (h, 0..) |pt, i| {
            if (i > 0) try w.writeByte(',');
            try w.print("[{d},{d}]", .{ pt[0], pt[1] });
        }
        try w.writeByte(']');
    }
    if (any) try w.writeByte(']');
}

fn writeString(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < value.len) : (i += 1) switch (value[i]) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        '<' => try w.writeAll("\\u003c"),
        0xE2 => if (i + 2 < value.len and value[i + 1] == 0x80 and (value[i + 2] == 0xA8 or value[i + 2] == 0xA9)) {
            try w.writeAll(if (value[i + 2] == 0xA8) "\\u2028" else "\\u2029");
            i += 2;
        } else try w.writeByte(value[i]),
        else => if (value[i] < 0x20) try w.print("\\u{x:0>4}", .{value[i]}) else try w.writeByte(value[i]),
    };
    try w.writeByte('"');
}

const geometry = @import("../placement/geometry.zig");
const router = @import("../placement/router.zig");
const export_kicad = @import("../export_kicad.zig");
const pcb_keepout_json = @import("pcb_keepout_json.zig");

test "pour JSON is empty when the board declares no outer pours" {
    const placement: optimizer.Placement = .{
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
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writePours(&aw.writer, std.testing.allocator, placement, .{}, &.{}, null);
    try std.testing.expectEqualStrings("[]", aw.written());
}

/// A bottom GND pour seeded by a corner pad, over a 20 mm square with a declared
/// bottom plane — the fixture both hole tests below share.
fn gndPourPlacement(parts: []optimizer.Part, nets: []const export_kicad.FlatNet, gnd_names: []const []const u8, planes: []const optimizer.PlaneAt) optimizer.Placement {
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
        .maxx = 20,
        .maxy = 20,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 },
        .rules = .{ .plane_nets = gnd_names, .copper_layers = 2, .planes = .{ .declared = planes } },
    };
}

// spec: Web Server - a pour with an interior foreign feature ships its antipad holes and the viewer fills them even-odd
test "writePours ships interior antipad holes and omits the key when none" {
    // compute() treats the passed allocator as an arena (its fills are never
    // individually freed), so the test must hand writePours a real arena.
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.2 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 3, .side = .bottom },
    };
    const gnd_pins = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = gndPourPlacement(&parts, &nets, &gnd_names, &planes);

    // A FOREIGN VIN via dead centre is fully enclosed by ground copper, so the
    // blob carries a well-formed nested `"holes":[[[…]]]` array.
    const vias = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.6, .net = 1 }};
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writePours(&aw.writer, arena, placement, .{ .vias = &vias }, &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"holes\":[[[") != null);

    // Drop the via: the solid pour has no interior loop, so the key is omitted.
    var aw2: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw2.deinit();
    try writePours(&aw2.writer, arena, placement, .{}, &.{}, null);
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"poly\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw2.written(), "\"holes\":") == null);

    // The viewer paints those holes even-odd (outer minus holes). The fill
    // runs through the cached pour Path2D, so the probe matches the
    // two-argument fill(path,"evenodd") spelling.
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, ",\"evenodd\")") != null);
}

// spec: Web Server - every copper geometry in the PCB blob names its layer with one key, a KiCad layer name on a fill and a name array on a keepout region
test "blob copper geometry carries one canonical layer key" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 3, .side = .bottom }};
    const gnd_pins = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &gnd_pins }};
    const gnd_names = [_][]const u8{"GND"};
    // A bottom-face declared pour on a four-layer board: B.Cu is stack 4.
    const planes = [_]optimizer.PlaneAt{.{ .index = 4, .net = "GND" }};
    var placement = gndPourPlacement(&parts, &nets, &gnd_names, &planes);
    placement.rules.copper_layers = 4;

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writePours(&aw.writer, arena, placement, .{}, &.{}, null);
    const pours = aw.written();
    // `layer` is the canonical key; `side` rides along for face tests only.
    try std.testing.expect(std.mem.indexOf(u8, pours, "{\"layer\":\"B.Cu\",\"side\":\"bottom\",\"net\":\"GND\"") != null);

    // A plane-only fill names BOTH its physical stack index and that row's name.
    var planes_out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer planes_out.deinit();
    try writePlaneFillsField(&planes_out.writer, arena, placement, .{}, false, null);
    try std.testing.expect(std.mem.indexOf(u8, planes_out.written(), "\"stack\":2,\"layer\":\"In1.Cu\"") == null);

    // A keepout region names every copper layer it spans — an ARRAY of layer
    // names, never the magic "all" string only this producer used to emit.
    var keepouts: std.Io.Writer.Allocating = .init(arena);
    var fenced = placement;
    fenced.rules.perimeter_fence = .{
        .via_dia = 0.4,
        .via_drill = 0.2,
        .spacing = 1,
        .edge_offset = 0.5,
        .keepout = .{ .clearance = 0.3, .blocks = .{ .tracks = true } },
    };
    try pcb_keepout_json.write(&keepouts.writer, arena, fenced);
    try std.testing.expect(std.mem.indexOf(u8, keepouts.written(), "\"layers\":[\"F.Cu\",\"In1.Cu\",\"In2.Cu\",\"B.Cu\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, keepouts.written(), "\"all\"") == null);

    // The viewer reads those keys through ONE lookup over the layer table.
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "function reviewAreaStack(q){") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "o.layers===\"all\"") == null);
}

// spec: Web Server - every physical copper layer is selectable and a plane-only view uses its computed fill
test "writePlaneFills ships an inner plane and its via antipad" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 3, .y = 3 }};
    const gnd_pins = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "RF_IN", .pins = &.{} },
    };
    const plane_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    var placement = gndPourPlacement(&parts, &nets, &plane_names, &planes);
    placement.rules.copper_layers = 4;
    const vias = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.4, .drill = 0.2, .net = 1 }};
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writePlaneFillsField(&aw.writer, arena, placement, .{ .vias = &vias }, false, null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"stack\":2,\"layer\":\"In1.Cu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"holes\":[[[") != null);
}
