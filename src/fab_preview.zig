//! CAM-preview serialization sourced from the exact Gerber/Excellon bytes.
//!
//! The assembly surface deliberately does not consume placement pads, browser
//! fonts, or independently rebuilt pours for fabricated artwork. Each planned
//! manufacturing layer is written through the production writers, parsed back,
//! and serialized as ordered polarity-aware operations. The browser therefore
//! paints the same quantized coordinates and apertures that are downloaded.

const std = @import("std");
const export_fab = @import("export_fab.zig");
const export_gerber = @import("export_gerber.zig");
const fab_identity = @import("fab_identity.zig");
const font = @import("font5x7.zig");
const gerber = @import("gerber_verify.zig");
const json = @import("json_writer.zig");
const optimizer = @import("placement/optimizer.zig");
const pour = @import("placement/pour.zig");
const router = @import("placement/router.zig");
const subcircuit_silkscreen = @import("subcircuit_silkscreen.zig");

const PackageFrame = struct { frame: export_fab.Frame, drill_suffixes: [2][]const u8 };

/// Generated-layer write, allocation, or read-back parse failure.
pub const Error = fab_identity.Error || gerber.ParseError;

/// One Assembly page's selected fabrication view and its display gate.
pub const Request = struct {
    enabled: bool,
    placement: optimizer.Placement,
    routed: ?router.RouteResult,
    zones: []const pour.UserZone,
    silk_keepouts: []const subcircuit_silkscreen.Keepout,
    texts: []const font.BoardText,
    /// Output coordinates plus the same drill member names used by the ZIP.
    package: PackageFrame,
};

/// Write the ordered CAM-preview JSON for one solved fabrication view.
pub fn writeJson(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    request: Request,
) Error!void {
    if (!request.enabled) return w.writeAll("null");
    const placement = request.placement;
    const frame = request.package.frame;
    const rr = request.routed orelse router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const copper = export_gerber.Copper{
        .tracks = rr.tracks,
        .arcs = rr.arcs,
        .rf_paths = rr.rf_port_outcomes,
        .vias = rr.vias,
        .zones = request.zones,
        .silk_keepouts = request.silk_keepouts,
    };
    const mark = try fab_identity.build(arena, placement, copper, request.texts, frame, null);
    const texts = try fab_identity.replaceAdoptedText(arena, request.texts, mark);
    const layers = try export_gerber.planLayers(arena, placement);
    var profile_ops: []const gerber.Op = &.{};
    try w.writeAll("{\"source\":\"generated-gerber\",\"layers\":[");
    var first = true;
    for (layers) |layer| {
        var bytes: std.Io.Writer.Allocating = .init(arena);
        try export_gerber.writeLayer(&bytes.writer, arena, placement, copper, texts, frame, layer.layer, .{ .function = layer.function });
        const parsed = try gerber.parse(arena, bytes.written());
        if (std.meta.activeTag(layer.layer) == .edge) profile_ops = parsed.ops;
        if (!first) try w.writeByte(',');
        first = false;
        try writeGerberLayer(w, layer, parsed, frame);
    }

    const copper_layers = placement.rules.layerStack().stackCount();
    for ([_]export_fab.DrillClass{ .plated, .non_plated }, 0..) |class, class_index| {
        var bytes: std.Io.Writer.Allocating = .init(arena);
        try export_fab.excellonDrill(&bytes.writer, arena, placement.parts, copper.vias, .{ .class = class, .copper_layers = copper_layers }, frame);
        const file = request.package.drill_suffixes[class_index];
        if (!first) try w.writeByte(',');
        first = false;
        try writeDrillLayer(w, arena, bytes.written(), class, file, frame);
    }
    try w.writeAll("],\"profile\":");
    try writeProfile(w, arena, profile_ops, frame);
    try w.writeAll(",\"fab_id\":");
    if (mark.printed) try json.writeString(w, &mark.short_hex) else try w.writeAll("null");
    try w.writeAll(",\"sha256\":");
    try json.writeString(w, &mark.digest_hex);
    try w.writeByte('}');
}

const ProfilePiece = struct {
    p1: [2]f64,
    p2: [2]f64,
    center: ?[2]f64 = null,
    cw: bool = false,
};

/// Write the outer finished-board contour reconstructed from the parsed
/// Profile Gerber's centerline operations. The production writer emits one
/// closed contour; connection by quantized endpoints restores its order after
/// the parser separates straight segments from the native-arc pass.
fn writeProfile(w: *std.Io.Writer, arena: std.mem.Allocator, ops: []const gerber.Op, frame: export_fab.Frame) !void {
    var pieces: std.ArrayList(ProfilePiece) = .empty;
    for (ops) |op| switch (op) {
        .segment => |line| try pieces.append(arena, .{
            .p1 = world(frame, line.x1, line.y1),
            .p2 = world(frame, line.x2, line.y2),
        }),
        .arc => |arc| try pieces.append(arena, .{
            .p1 = world(frame, arc.p1[0], arc.p1[1]),
            .p2 = world(frame, arc.p2[0], arc.p2[1]),
            .center = world(frame, arc.center[0], arc.center[1]),
            .cw = arc.cw,
        }),
        else => {},
    };
    if (pieces.items.len == 0) return w.writeAll("[]");
    const used = try arena.alloc(bool, pieces.items.len);
    @memset(used, false);
    var points: std.ArrayList([2]f64) = .empty;
    try points.append(arena, pieces.items[0].p1);
    try appendProfilePiece(&points, arena, pieces.items[0], false);
    used[0] = true;
    var current = pieces.items[0].p2;
    var remaining = pieces.items.len - 1;
    while (remaining > 0) : (remaining -= 1) {
        const next = connectedProfilePiece(pieces.items, used, current) orelse break;
        used[next.index] = true;
        try appendProfilePiece(&points, arena, pieces.items[next.index], next.reverse);
        current = if (next.reverse) pieces.items[next.index].p1 else pieces.items[next.index].p2;
    }
    try w.writeByte('[');
    for (points.items, 0..) |point, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("[{d},{d}]", .{ point[0], point[1] });
    }
    try w.writeByte(']');
}

const ProfileConnection = struct { index: usize, reverse: bool };

fn connectedProfilePiece(pieces: []const ProfilePiece, used: []const bool, point: [2]f64) ?ProfileConnection {
    for (pieces, used, 0..) |piece, done, i| {
        if (done) continue;
        if (profilePointEq(piece.p1, point)) return .{ .index = i, .reverse = false };
        if (profilePointEq(piece.p2, point)) return .{ .index = i, .reverse = true };
    }
    return null;
}

fn profilePointEq(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) <= gerber.eps_mm and @abs(a[1] - b[1]) <= gerber.eps_mm;
}

fn appendProfilePiece(points: *std.ArrayList([2]f64), arena: std.mem.Allocator, piece: ProfilePiece, reverse: bool) !void {
    const start = if (reverse) piece.p2 else piece.p1;
    const finish = if (reverse) piece.p1 else piece.p2;
    const center = piece.center orelse return points.append(arena, finish);
    const cw = if (reverse) !piece.cw else piece.cw;
    const radius = std.math.hypot(start[0] - center[0], start[1] - center[1]);
    const a0 = std.math.atan2(start[1] - center[1], start[0] - center[0]);
    var a1 = std.math.atan2(finish[1] - center[1], finish[0] - center[0]);
    if (cw) {
        while (a1 <= a0) a1 += 2 * std.math.pi;
    } else {
        while (a1 >= a0) a1 -= 2 * std.math.pi;
    }
    const steps = @max(@as(usize, 2), @as(usize, @intFromFloat(@ceil(@abs(a1 - a0) * radius / 0.02))));
    for (1..steps + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const a = a0 + (a1 - a0) * t;
        try points.append(arena, .{ center[0] + radius * @cos(a), center[1] + radius * @sin(a) });
    }
}

fn world(frame: export_fab.Frame, x: f64, y: f64) [2]f64 {
    return .{ x + frame.ox, frame.oy - y };
}

fn writeGerberLayer(w: *std.Io.Writer, layer: export_gerber.LayerFile, parsed: gerber.Parsed, frame: export_fab.Frame) !void {
    try w.writeByte('{');
    try writeLayerIdentity(w, layer);
    try w.writeAll(",\"negative\":");
    try w.writeAll(if (std.meta.activeTag(layer.layer) == .mask) "true" else "false");
    try w.writeAll(",\"ops\":[");
    for (parsed.ops, 0..) |op, i| {
        if (i > 0) try w.writeByte(',');
        try writeOp(w, op, frame);
    }
    try w.writeAll("]}");
}

fn writeLayerIdentity(w: *std.Io.Writer, file: export_gerber.LayerFile) !void {
    try w.writeAll("\"id\":");
    switch (file.layer) {
        .copper => |side| try w.print("\"copper-{s}\"", .{sideName(side)}),
        .plane => |plane| try w.print("\"copper-inner-{d}\"", .{plane.index}),
        .inner_signal => |inner| try w.print("\"copper-inner-{d}\"", .{inner.index}),
        .mask => |side| try w.print("\"mask-{s}\"", .{sideName(side)}),
        .paste => |side| try w.print("\"paste-{s}\"", .{sideName(side)}),
        .silk => |side| try w.print("\"silk-{s}\"", .{sideName(side)}),
        .fabrication => |fab| try w.print("\"fabrication-{s}-{d}\"", .{ sideName(fab.side), fab.index }),
        .edge => try w.writeAll("\"outline\""),
    }
    try w.writeAll(",\"kind\":");
    const kind = switch (file.layer) {
        .copper, .plane, .inner_signal => "copper",
        .mask => "mask",
        .paste => "paste",
        .silk => "silk",
        .fabrication => "fabrication",
        .edge => "outline",
    };
    try json.writeString(w, kind);
    try w.writeAll(",\"side\":");
    switch (file.layer) {
        .copper => |side| try json.writeString(w, sideName(side)),
        .mask => |side| try json.writeString(w, sideName(side)),
        .paste => |side| try json.writeString(w, sideName(side)),
        .silk => |side| try json.writeString(w, sideName(side)),
        .fabrication => |fab| try json.writeString(w, sideName(fab.side)),
        .plane, .inner_signal => try w.writeAll("\"inner\""),
        .edge => try w.writeAll("\"both\""),
    }
    try w.writeAll(",\"name\":");
    try json.writeString(w, file.function);
    try w.writeAll(",\"file\":");
    try json.writeString(w, file.suffix);
}

fn sideName(side: optimizer.Side) []const u8 {
    return if (side == .bottom) "bottom" else "top";
}

fn writeOp(w: *std.Io.Writer, op: gerber.Op, frame: export_fab.Frame) !void {
    switch (op) {
        .flash => |flash| {
            const p = world(frame, flash.x, flash.y);
            try w.print("[\"f\",{d},{d},{d},{d},{d},{s}]", .{
                p[0], p[1], @backingInt(flash.kind), flash.w, flash.h, if (flash.dark) "true" else "false",
            });
        },
        .segment => |segment| {
            const a = world(frame, segment.x1, segment.y1);
            const b = world(frame, segment.x2, segment.y2);
            try w.print("[\"l\",{d},{d},{d},{d},{d},{s}]", .{
                a[0], a[1], b[0], b[1], segment.w, if (segment.dark) "true" else "false",
            });
        },
        .arc => |arc| {
            const a = world(frame, arc.p1[0], arc.p1[1]);
            const b = world(frame, arc.p2[0], arc.p2[1]);
            const c = world(frame, arc.center[0], arc.center[1]);
            try w.print("[\"a\",{d},{d},{d},{d},{d},{d},{d},{s},{s}]", .{
                a[0],                            a[1],                              b[0], b[1], c[0], c[1], arc.w,
                if (arc.cw) "true" else "false", if (arc.dark) "true" else "false",
            });
        },
        .region => |region| {
            try w.print("[\"r\",{s},[", .{if (region.dark) "true" else "false"});
            for (region.points, 0..) |point, i| {
                if (i > 0) try w.writeByte(',');
                const p = world(frame, point[0], point[1]);
                try w.print("[{d},{d}]", .{ p[0], p[1] });
            }
            try w.writeAll("]] ");
        },
    }
}

const DrillTool = struct { number: u32, diameter: f64 };

fn writeDrillLayer(w: *std.Io.Writer, arena: std.mem.Allocator, bytes: []const u8, class: export_fab.DrillClass, file: []const u8, frame: export_fab.Frame) !void {
    try w.print("{{\"id\":\"drill-{s}\",\"kind\":\"drill\",\"side\":\"both\",\"name\":\"{s} drill\",\"file\":\"{s}\",\"negative\":false,\"ops\":[", .{
        if (class == .plated) "plated" else "non-plated",
        if (class == .plated) "Plated" else "Non-plated",
        file,
    });
    var tools: std.ArrayList(DrillTool) = .empty;
    var selected: f64 = 0;
    var first = true;
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        if (line.len < 2 or line[0] != 'T') continue;
        if (std.mem.indexOfScalar(u8, line, 'C')) |ci| {
            const number = std.fmt.parseInt(u32, line[1..ci], 10) catch continue;
            const diameter = std.fmt.parseFloat(f64, line[ci + 1 ..]) catch continue;
            try tools.append(arena, .{ .number = number, .diameter = diameter });
            continue;
        }
        const number = std.fmt.parseInt(u32, line[1..], 10) catch continue;
        for (tools.items) |tool| if (tool.number == number) {
            selected = tool.diameter;
            break;
        };
    }
    lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    selected = 0;
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        if (line[0] == 'T' and std.mem.indexOfScalar(u8, line, 'C') == null) {
            const number = std.fmt.parseInt(u32, line[1..], 10) catch continue;
            for (tools.items) |tool| if (tool.number == number) {
                selected = tool.diameter;
                break;
            };
            continue;
        }
        if (line[0] != 'X' or !(selected > 0)) continue;
        if (std.mem.indexOf(u8, line, "G85")) |gi| {
            const a = parseDrillPoint(line[0..gi]) orelse continue;
            const b = parseDrillPoint(line[gi + 3 ..]) orelse continue;
            if (!first) try w.writeByte(',');
            first = false;
            const wa = world(frame, a[0], a[1]);
            const wb = world(frame, b[0], b[1]);
            try w.print("[\"l\",{d},{d},{d},{d},{d},true]", .{ wa[0], wa[1], wb[0], wb[1], selected });
        } else {
            const point = parseDrillPoint(line) orelse continue;
            if (!first) try w.writeByte(',');
            first = false;
            const wp = world(frame, point[0], point[1]);
            try w.print("[\"f\",{d},{d},0,{d},{d},true]", .{ wp[0], wp[1], selected, selected });
        }
    }
    try w.writeAll("]}");
}

fn parseDrillPoint(s: []const u8) ?[2]f64 {
    if (s.len < 4 or s[0] != 'X') return null;
    const yi = std.mem.indexOfScalar(u8, s, 'Y') orelse return null;
    const x = std.fmt.parseFloat(f64, s[1..yi]) catch return null;
    const y = std.fmt.parseFloat(f64, s[yi + 1 ..]) catch return null;
    return .{ x, y };
}

// spec: export_gerber - the Assembly CAM payload is generated from every planned Gerber plus both Excellon drill files and carries their fabrication ID and full digest
test "CAM preview serializes quantized Gerber silk and Excellon drills" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pad = [_]@import("placement/geometry.zig").Pad{.{
        .number = "1",
        .x = 0,
        .y = 0,
        .w = 1.2,
        .h = 1.2,
        .thru = true,
        .drill = 0.7,
    }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "J1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &pad,
        .fallback = false,
        .x = 5,
        .y = 5,
    }};
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
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&out.writer, arena, .{
        .enabled = true,
        .placement = placement,
        .routed = null,
        .zones = &.{},
        .silk_keepouts = &.{},
        .texts = &.{},
        .package = .{ .frame = export_fab.frameFor(placement), .drill_suffixes = .{ "PTH", "NPTH" } },
    });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"source\":\"generated-gerber\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"silk-top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"id\":\"drill-plated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"profile\":[[") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"fab_id\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"sha256\":") != null);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.written(), .{});
}

test "CAM preview replaces an adopted fabrication identity instead of drawing its stale text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
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
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    const stale_a = [_]font.BoardText{.{
        .x = 3,
        .y = 2,
        .size = 1,
        .text = "ID STALE",
        .fabrication_id = true,
    }};
    const stale_b = [_]font.BoardText{.{
        .x = 3,
        .y = 2,
        .size = 1,
        .text = "ID OTHER",
        .fabrication_id = true,
    }};
    const package = PackageFrame{ .frame = export_fab.frameFor(placement), .drill_suffixes = .{ "PTH", "NPTH" } };
    var a: std.Io.Writer.Allocating = .init(arena);
    var b: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&a.writer, arena, .{
        .enabled = true,
        .placement = placement,
        .routed = null,
        .zones = &.{},
        .silk_keepouts = &.{},
        .texts = &stale_a,
        .package = package,
    });
    try writeJson(&b.writer, arena, .{
        .enabled = true,
        .placement = placement,
        .routed = null,
        .zones = &.{},
        .silk_keepouts = &.{},
        .texts = &stale_b,
        .package = package,
    });

    try std.testing.expectEqualStrings(a.written(), b.written());
}

// Regression: sub-circuit CAM previews keep the digest but contain no
// generated or stale adopted fabrication ID.
test "CAM preview omits fabrication ID silk for sub-circuits" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
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
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
    };
    placement.rules.physical.role = .subcircuit;
    const texts = [_]font.BoardText{
        .{ .x = 2, .y = 2, .text = "REV A" },
        .{ .x = 3, .y = 2, .text = "ID STALE", .fabrication_id = true },
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeJson(&out.writer, arena, .{
        .enabled = true,
        .placement = placement,
        .routed = null,
        .zones = &.{},
        .silk_keepouts = &.{},
        .texts = &texts,
        .package = .{ .frame = export_fab.frameFor(placement), .drill_suffixes = .{ "PTH", "NPTH" } },
    });

    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"fab_id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"sha256\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "ID STALE") == null);
}
