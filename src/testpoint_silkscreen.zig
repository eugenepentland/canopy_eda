//! Collision-aware board-silkscreen labels for physical test points.
//!
//! Every physical `testpoint` instance gets the same 0.8 mm, horizontal label on
//! the footprint's side. The search starts directly above the test point, then
//! tries nearby above/below/left/right and diagonal slots in expanding rings.
//! Candidates reject same-face pads, saved keepouts, the exact board outline,
//! generated sub-circuit artwork, user text, and earlier test-point labels.

const std = @import("std");
const net_name = @import("net_name.zig");
const env = @import("eval/env.zig");
const font = @import("font5x7.zig");
const optimizer = @import("placement/optimizer.zig");
const outline = @import("placement/outline.zig");
const pad_shape = @import("placement/pad_shape.zig");
const perimeter_fence = @import("placement/perimeter_fence.zig");
const subcircuit_silkscreen = @import("subcircuit_silkscreen.zig");
const silk_font = @import("silk_font.zig");

// JLCPCB's documented high-precision character floor is 0.8 mm. The Gerber
// stroker remains 0.15 mm wide, above its 0.1 mm high-precision minimum and at
// the standard-process minimum.
const testpoint_cap_height_mm: f64 = 0.8;
const testpoint_label_size_mm: f64 = testpoint_cap_height_mm * silk_font.em_units / silk_font.cap_units;
const label_gap_mm: f64 = 0.2;
const label_clearance_mm: f64 = 0.2;
const silk_stroke_mm: f64 = 0.15;
const search_ring_mm = [_]f64{ 0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5, 5.0, 5.5, 6.0 };

const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
const PadObstacle = struct { shape: pad_shape.Shape, top: bool, bottom: bool };
const LabelContext = struct {
    placement: optimizer.Placement,
    pads: []const PadObstacle,
    keepouts: []const subcircuit_silkscreen.Keepout,
    annotations: []const subcircuit_silkscreen.Annotation,
    user_texts: []const font.BoardText,
};

/// One generated test-point label and the placement part it follows.
pub const Label = struct {
    part_index: usize,
    text: font.BoardText,
};

fn textWidth(text: []const u8) f64 {
    return silk_font.widthMm(text, testpoint_label_size_mm);
}

fn textBox(text: font.BoardText) Rect {
    const width = textWidth(text.text);
    return .{
        .x0 = text.x - width / 2,
        .y0 = text.y - testpoint_cap_height_mm / 2,
        .x1 = text.x + width / 2,
        .y1 = text.y + testpoint_cap_height_mm / 2,
    };
}

fn overlaps(a: Rect, b: Rect, clearance: f64) bool {
    return !(a.x1 + clearance <= b.x0 or b.x1 + clearance <= a.x0 or
        a.y1 + clearance <= b.y0 or b.y1 + clearance <= a.y0);
}

fn pointInRect(point: [2]f64, rect: Rect) bool {
    return point[0] >= rect.x0 and point[0] <= rect.x1 and point[1] >= rect.y0 and point[1] <= rect.y1;
}

fn boxInsideBoard(placement: optimizer.Placement, box: Rect) bool {
    const board = placement.board_rect orelse return true;
    const inset = @max(label_clearance_mm, perimeter_fence.keepoutLimit(placement) + label_clearance_mm);
    if (box.x0 < board.minx + inset or box.x1 > board.minx + board.w - inset or
        box.y0 < board.miny + inset or box.y1 > board.miny + board.h - inset) return false;
    const poly = placement.board_poly orelse return true;
    if (poly.len < 3) return true;
    const cx = (box.x0 + box.x1) / 2;
    const cy = (box.y0 + box.y1) / 2;
    const samples = [_][2]f64{
        .{ box.x0, box.y0 }, .{ cx, box.y0 }, .{ box.x1, box.y0 },
        .{ box.x0, cy },     .{ cx, cy },     .{ box.x1, cy },
        .{ box.x0, box.y1 }, .{ cx, box.y1 }, .{ box.x1, box.y1 },
    };
    for (samples) |point| if (outline.signedInset(poly, point[0], point[1]) < inset) return false;
    const corners = [_][2]f64{ .{ box.x0, box.y0 }, .{ box.x1, box.y0 }, .{ box.x1, box.y1 }, .{ box.x0, box.y1 } };
    for (corners, 0..) |a, i| {
        const b = corners[(i + 1) % corners.len];
        if (outline.segCrossesEdge(poly, a[0], a[1], b[0], b[1]) != null) return false;
    }
    return true;
}

fn boxHitsKeepout(box: Rect, keepout: subcircuit_silkscreen.Keepout) bool {
    const poly = keepout.polygon;
    if (poly.len < 3) return false;
    const grown = Rect{
        .x0 = box.x0 - label_clearance_mm,
        .y0 = box.y0 - label_clearance_mm,
        .x1 = box.x1 + label_clearance_mm,
        .y1 = box.y1 + label_clearance_mm,
    };
    const corners = [_][2]f64{ .{ grown.x0, grown.y0 }, .{ grown.x1, grown.y0 }, .{ grown.x1, grown.y1 }, .{ grown.x0, grown.y1 } };
    for (corners) |point| if (outline.contains(poly, point[0], point[1])) return true;
    for (poly) |point| if (pointInRect(point, grown)) return true;
    for (corners, 0..) |a, i| {
        const b = corners[(i + 1) % corners.len];
        if (outline.segCrossesEdge(poly, a[0], a[1], b[0], b[1]) != null) return true;
    }
    return false;
}

fn sameSide(side: optimizer.Side, text: font.BoardText) bool {
    return text.bottom == (side == .bottom);
}

fn segmentBox(segment: subcircuit_silkscreen.Segment) Rect {
    const radius = silk_stroke_mm / 2;
    return .{
        .x0 = @min(segment.x1, segment.x2) - radius,
        .y0 = @min(segment.y1, segment.y2) - radius,
        .x1 = @max(segment.x1, segment.x2) + radius,
        .y1 = @max(segment.y1, segment.y2) + radius,
    };
}

fn labelClear(
    ctx: LabelContext,
    placed: []const Label,
    side: optimizer.Side,
    box: Rect,
) bool {
    if (!boxInsideBoard(ctx.placement, box)) return false;
    for (ctx.keepouts) |keepout| if (boxHitsKeepout(box, keepout)) return false;
    const label_shape = pad_shape.Shape{ .x0 = box.x0, .y0 = box.y0, .x1 = box.x1, .y1 = box.y1 };
    for (ctx.pads) |pad| {
        const blocks = if (side == .top) pad.top else pad.bottom;
        if (blocks and pad_shape.shapeGap(label_shape, pad.shape, label_clearance_mm) + 1e-9 < label_clearance_mm) return false;
    }
    for (ctx.annotations) |annotation| {
        if (annotation.side != side) continue;
        if (annotation.label().text.len > 0 and overlaps(box, textBox(annotation.label()), label_clearance_mm)) return false;
        for (annotation.visibleSegments()) |segment| {
            if (overlaps(box, segmentBox(segment), label_clearance_mm)) return false;
        }
    }
    for (ctx.user_texts) |text| {
        if (text.text.len > 0 and sameSide(side, text) and overlaps(box, textBox(text), label_clearance_mm)) return false;
    }
    for (placed) |label| {
        if (sameSide(side, label.text) and overlaps(box, textBox(label.text), label_clearance_mm)) return false;
    }
    return true;
}

fn candidate(text: []const u8, side: optimizer.Side, x: f64, y: f64) font.BoardText {
    return .{ .x = x, .y = y, .bottom = side == .bottom, .size = testpoint_label_size_mm, .text = text, .rot = 0 };
}

fn placeLabel(
    ctx: LabelContext,
    placed: []const Label,
    part: optimizer.Part,
) ?font.BoardText {
    const court = optimizer.worldCourtyard(&part);
    const cx = court.minx + court.w / 2;
    const cy = court.miny + court.h / 2;
    const shown_ref = net_name.leaf(part.ref_des);
    const width = textWidth(shown_ref);
    for (search_ring_mm) |ring| {
        const top = court.miny - label_gap_mm - ring - testpoint_cap_height_mm / 2;
        const bottom = court.miny + court.h + label_gap_mm + ring + testpoint_cap_height_mm / 2;
        const left = court.minx - label_gap_mm - ring - width / 2;
        const right = court.minx + court.w + label_gap_mm + ring + width / 2;
        const diagonal = width / 2 + label_gap_mm + ring;
        const positions = [_][2]f64{
            .{ cx, top },    .{ cx - diagonal, top },    .{ cx + diagonal, top },
            .{ cx, bottom }, .{ cx - diagonal, bottom }, .{ cx + diagonal, bottom },
            .{ left, cy },   .{ right, cy },
        };
        for (positions) |position| {
            const text = candidate(shown_ref, part.side, position[0], position[1]);
            if (labelClear(ctx, placed, part.side, textBox(text))) return text;
        }
    }
    return null;
}

fn excluded(ref: []const u8, refs: []const []const u8) bool {
    for (refs) |candidate_ref| if (std.mem.eql(u8, ref, candidate_ref)) return true;
    return false;
}

fn isPhysicalTestPoint(placement: optimizer.Placement, index: usize) bool {
    return index < placement.instances.len and env.isTestPoint(placement.instances[index].component);
}

fn overridden(ref: []const u8, user_texts: []const font.BoardText) bool {
    for (user_texts) |text| {
        const owner = text.owner orelse continue;
        const testpoint = switch (owner) {
            .testpoint => |testpoint| testpoint,
            else => continue,
        };
        if (std.mem.eql(u8, testpoint, ref)) return true;
    }
    return false;
}

/// Place every live physical test-point label while reserving generated
/// sub-circuit annotations and editable board text already on the silk.
pub fn collectWithKeepouts(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    excluded_refs: []const []const u8,
    keepouts: []const subcircuit_silkscreen.Keepout,
    annotations: []const subcircuit_silkscreen.Annotation,
    user_texts: []const font.BoardText,
) std.mem.Allocator.Error![]Label {
    var shape_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer shape_arena_state.deinit();
    const shape_arena = shape_arena_state.allocator();
    var pads: std.ArrayList(PadObstacle) = .empty;
    defer pads.deinit(alloc);
    for (placement.parts) |part| {
        if (excluded(part.ref_des, excluded_refs)) continue;
        for (part.pads) |pad| {
            const both = pad.thru or pad.npth;
            try pads.append(alloc, .{
                .shape = try pad_shape.worldShape(shape_arena, part, pad),
                .top = both or part.side == .top,
                .bottom = both or part.side == .bottom,
            });
        }
    }

    var labels: std.ArrayList(Label) = .empty;
    defer labels.deinit(alloc);
    const ctx = LabelContext{
        .placement = placement,
        .pads = pads.items,
        .keepouts = keepouts,
        .annotations = annotations,
        .user_texts = user_texts,
    };
    for (placement.parts, 0..) |part, index| {
        if (!isPhysicalTestPoint(placement, index) or excluded(part.ref_des, excluded_refs)) continue;
        if (overridden(part.ref_des, user_texts)) continue;
        const text = placeLabel(ctx, labels.items, part) orelse continue;
        try labels.append(alloc, .{ .part_index = index, .text = text });
    }
    return labels.toOwnedSlice(alloc);
}

/// Release labels returned by `collectWithKeepouts`.
pub fn deinitCollected(alloc: std.mem.Allocator, labels: []Label) void {
    alloc.free(labels);
}

fn testPlacement(parts: []optimizer.Part, instances: []const @import("export_kicad.zig").FlatInstance) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = instances,
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 },
    };
}

fn flatInstance(ref: []const u8, component: []const u8) @import("export_kicad.zig").FlatInstance {
    return .{ .ref_des = ref, .component = component, .value = "", .footprint = "", .properties = &.{}, .uuid = "" };
}

// spec: export_gerber - physical test points get uniform horizontal 0.8 mm labels directly above their pad whenever that slot is clear
test "test-point labels prefer the clear slot directly above" {
    const pad = [_]@import("placement/geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true }};
    var parts = [_]optimizer.Part{.{ .ref_des = "TP_3V3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 10, .y = 10 }};
    const instances = [_]@import("export_kicad.zig").FlatInstance{flatInstance("TP_3V3", "testpoint")};
    const labels = try collectWithKeepouts(std.testing.allocator, testPlacement(&parts, &instances), &.{}, &.{}, &.{}, &.{});
    defer deinitCollected(std.testing.allocator, labels);
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectApproxEqAbs(@as(f64, 10), labels[0].text.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 8.9), labels[0].text.y, 1e-9);
    try std.testing.expectApproxEqAbs(testpoint_label_size_mm, labels[0].text.size, 1e-9);
    try std.testing.expectApproxEqAbs(testpoint_cap_height_mm, silk_font.heightMm(labels[0].text.size), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), labels[0].text.rot, 1e-9);
}

test "test-point silkscreen prints the leaf refdes" {
    const pad = [_]@import("placement/geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true }};
    var parts = [_]optimizer.Part{.{ .ref_des = "power/TP7", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 10, .y = 10 }};
    const instances = [_]@import("export_kicad.zig").FlatInstance{flatInstance("power/TP7", "testpoint")};
    const labels = try collectWithKeepouts(std.testing.allocator, testPlacement(&parts, &instances), &.{}, &.{}, &.{}, &.{});
    defer deinitCollected(std.testing.allocator, labels);
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expectEqualStrings("TP7", labels[0].text.text);
}

// spec: export_gerber - an editable board text tagged with a test-point identity replaces exactly that generated label
test "adopted test-point text suppresses its generated label" {
    const pad = [_]@import("placement/geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true }};
    var parts = [_]optimizer.Part{.{ .ref_des = "power/TP7", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 10, .y = 10 }};
    const instances = [_]@import("export_kicad.zig").FlatInstance{flatInstance("power/TP7", "testpoint")};
    const texts = [_]font.BoardText{.{ .x = 12, .y = 10, .size = testpoint_label_size_mm, .text = "TP7", .owner = .{ .testpoint = "power/TP7" } }};
    const labels = try collectWithKeepouts(std.testing.allocator, testPlacement(&parts, &instances), &.{}, &.{}, &.{}, &texts);
    defer deinitCollected(std.testing.allocator, labels);
    try std.testing.expectEqual(@as(usize, 0), labels.len);
}

// spec: export_gerber - a blocked test-point label searches nearby horizontal slots without crossing pads, keepouts, or Edge.Cuts
test "test-point labels move to the nearest available surrounding slot" {
    const tp_pad = [_]@import("placement/geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true }};
    const block_pad = [_]@import("placement/geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 5, .h = 1 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "TP1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &tp_pad, .fallback = false, .x = 10, .y = 10 },
        .{ .ref_des = "J1", .kind = .hub, .hw = 2.5, .hh = 0.5, .pads = &block_pad, .fallback = false, .x = 10, .y = 8.8 },
    };
    const instances = [_]@import("export_kicad.zig").FlatInstance{ flatInstance("TP1", "testpoint"), flatInstance("J1", "connector") };
    const labels = try collectWithKeepouts(std.testing.allocator, testPlacement(&parts, &instances), &.{}, &.{}, &.{}, &.{});
    defer deinitCollected(std.testing.allocator, labels);
    try std.testing.expectEqual(@as(usize, 1), labels.len);
    try std.testing.expect(labels[0].text.y > 10);
    try std.testing.expectApproxEqAbs(@as(f64, 0), labels[0].text.rot, 1e-9);
}

// spec: export_gerber - test-point labels reserve their chosen position so neighboring labels on the same face do not overlap
test "test-point labels avoid one another" {
    const pad = [_]@import("placement/geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "TP_A", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = 9, .y = 10 },
        .{ .ref_des = "TP_B", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = 11, .y = 10 },
    };
    const instances = [_]@import("export_kicad.zig").FlatInstance{ flatInstance("TP_A", "testpoint"), flatInstance("TP_B", "testpoint-smd") };
    const labels = try collectWithKeepouts(std.testing.allocator, testPlacement(&parts, &instances), &.{}, &.{}, &.{}, &.{});
    defer deinitCollected(std.testing.allocator, labels);
    try std.testing.expectEqual(@as(usize, 2), labels.len);
    try std.testing.expect(!overlaps(textBox(labels[0].text), textBox(labels[1].text), label_clearance_mm));
}

// spec: export_gerber - non-testpoint components do not receive generated test-point silkscreen labels
test "test-point collection ignores ordinary components" {
    var parts = [_]optimizer.Part{.{ .ref_des = "R1", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &.{}, .fallback = false, .x = 10, .y = 10 }};
    const instances = [_]@import("export_kicad.zig").FlatInstance{flatInstance("R1", "resistor")};
    const labels = try collectWithKeepouts(std.testing.allocator, testPlacement(&parts, &instances), &.{}, &.{}, &.{}, &.{});
    defer deinitCollected(std.testing.allocator, labels);
    try std.testing.expectEqual(@as(usize, 0), labels.len);
}

// spec: Web Server - the PCB viewer uses the same above-first, fixed-horizontal collision search for generated test-point labels
test "PCB viewer carries the test-point label placement contract" {
    const js = @embedFile("serve/assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "TP_SILK_SIZE=0.8") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "pos=[[cx,top]") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rot:0,size:TP_SILK_SIZE") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "subSilkClear({side:side}") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "testPointPart(p)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function testPointSilkAt(wx,wy)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function testPointSilkAdopt(tp)") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "testpoint:p.ref") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "testpointOverrides[p.ref]") != null);
}
