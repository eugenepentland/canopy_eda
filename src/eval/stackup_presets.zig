//! Fabricator stackup presets. These are physical construction templates only:
//! a board still authors its own `(plane …)` and `(pour …)` electrical roles.

const std = @import("std");
const env = @import("env.zig");

const Entry = struct {
    name: []const u8,
    layers: u8,
    thickness: f64,
};

const Ply = struct { material: []const u8, thickness: f64, er: f64 };
const Gap = struct {
    kind: env.StackupDielectricKind,
    label: []const u8,
    plies: [3]Ply = .{ empty_ply, empty_ply, empty_ply },
    len: u8,
};
const Definition = struct {
    entry: Entry,
    gaps: [5]Gap = .{ empty_gap, empty_gap, empty_gap, empty_gap, empty_gap },
    gap_count: u8,
};

const empty_ply = Ply{ .material = "", .thickness = 0, .er = 0 };
const empty_gap = Gap{ .kind = .prepreg, .label = "", .plies = .{ empty_ply, empty_ply, empty_ply }, .len = 0 };

fn prepreg(material: []const u8, thickness: f64, er: f64) Ply {
    return .{ .material = material, .thickness = thickness, .er = er };
}
fn corePly(thickness: f64) Ply {
    return .{ .material = "Core", .thickness = thickness, .er = 4.6 };
}
fn one(kind: env.StackupDielectricKind, label: []const u8, a: Ply) Gap {
    return .{ .kind = kind, .label = label, .plies = .{ a, empty_ply, empty_ply }, .len = 1 };
}
fn two(kind: env.StackupDielectricKind, label: []const u8, a: Ply, b: Ply) Gap {
    return .{ .kind = kind, .label = label, .plies = .{ a, b, empty_ply }, .len = 2 };
}
fn three(kind: env.StackupDielectricKind, label: []const u8, a: Ply, b: Ply, c: Ply) Gap {
    return .{ .kind = kind, .label = label, .plies = .{ a, b, c }, .len = 3 };
}
fn pp7628(thickness: f64) Ply {
    return prepreg("7628*1", thickness, 4.4);
}
fn pp3313(thickness: f64) Ply {
    return prepreg("3313*1", thickness, 4.1);
}
fn pp1080(thickness: f64) Ply {
    return prepreg("1080*1", thickness, 3.91);
}
fn pp2116(thickness: f64) Ply {
    return prepreg("2116*1", thickness, 4.16);
}
fn pp2313(thickness: f64) Ply {
    // The supplied table names 2313 but does not publish its Dk.
    return prepreg("2313*1", thickness, 4.4);
}
fn sym4(name: []const u8, face: Gap, middle: Gap) Definition {
    return .{
        .entry = .{ .name = name, .layers = 4, .thickness = 1.6 },
        .gaps = .{ face, middle, face, empty_gap, empty_gap },
        .gap_count = 3,
    };
}
fn sym6(name: []const u8, face: Gap, outer_core: Gap, middle: Gap) Definition {
    return .{
        .entry = .{ .name = name, .layers = 6, .thickness = 1.6 },
        .gaps = .{ face, outer_core, middle, outer_core, face },
        .gap_count = 5,
    };
}

const definitions = [_]Definition{
    sym4("JLC04161H-7628", one(.prepreg, "7628*1", pp7628(0.2104)), one(.core, "Core", corePly(1.065))),
    sym4("JLC04161H-3313", one(.prepreg, "3313*1", pp3313(0.0994)), one(.core, "Core", corePly(1.265))),
    sym4("JLC04161H-1080", one(.prepreg, "1080*1", pp1080(0.0764)), one(.core, "Core", corePly(1.265))),
    sym4("JLC04161H-7628A", two(.prepreg, "7628*1 + 1080*1", pp7628(0.218), pp1080(0.0764)), one(.core, "Core", corePly(0.865))),
    sym4("JLC04161H-3313A", two(.prepreg, "3313*1 + 3313*1", pp3313(0.107), pp3313(0.0994)), one(.core, "Core", corePly(1.065))),
    sym4("JLC04161H-1080A", two(.prepreg, "1080*1 + 1080*1", pp1080(0.084), pp1080(0.0764)), one(.core, "Core", corePly(1.065))),
    sym4("JLC04161H-7628B", three(.prepreg, "7628*1 + 7628*1 + 2116*1", pp7628(0.218), pp7628(0.218), pp2116(0.1164)), one(.core, "Core", corePly(0.4))),
    sym4("JLC04161H-2116A", three(.prepreg, "2116*1 + 7628*1 + 2116*1", pp2116(0.124), pp7628(0.218), pp2116(0.1164)), one(.core, "Core", corePly(0.6))),
    sym4("JLC04161H-2116B", two(.prepreg, "2116*1 + 7628*1", pp2116(0.124), pp7628(0.2104)), one(.core, "Core", corePly(0.865))),
    sym4("JLC04161H-2116C", two(.prepreg, "2116*1 + 1080*1", pp2116(0.124), pp1080(0.0764)), one(.core, "Core", corePly(1.065))),
    sym4("JLC04161H-7628G", three(.prepreg, "7628*1 + 7628*1 + 1080*1", pp7628(0.218), pp7628(0.218), pp1080(0.0764)), one(.core, "Core", corePly(0.5))),
    sym4("JLC04161H-2116", one(.prepreg, "2116*1", pp2116(0.1164)), one(.core, "Core", corePly(1.265))),
    sym4("JLC04161H-7628E", two(.prepreg, "7628*1 + 7628*1", pp7628(0.218), pp7628(0.2104)), one(.core, "Core", corePly(0.6))),
    sym4("JLC04161H-2116D", two(.prepreg, "2116*1 + 7628*1", pp2116(0.124), pp7628(0.2104)), one(.core, "Core", corePly(0.7))),
    sym4("JLC04161H-7628F", three(.prepreg, "7628*1 + 7628*1 + 7628*1", pp7628(0.218), pp7628(0.218), pp7628(0.2104)), one(.core, "Core", corePly(0.25))),
    sym4("JLC04161H-2116E", two(.prepreg, "2116*1 + 2116*1", pp2116(0.124), pp2116(0.1164)), one(.core, "Core", corePly(0.865))),
    sym4("JLC04161H-7628C", three(.prepreg, "7628*1 + 7628*1 + 7628*1", pp7628(0.218), pp7628(0.218), pp7628(0.2104)), one(.core, "Core", corePly(0.15))),
    sym6("JLC06161H-3313", one(.prepreg, "3313*1", pp3313(0.0994)), one(.core, "Core", corePly(0.55)), one(.prepreg, "2116*1", pp2116(0.1088))),
    sym6("JLC06161H-7628", one(.prepreg, "7628*1", pp7628(0.2104)), one(.core, "Core", corePly(0.4)), one(.prepreg, "7628*1", pp7628(0.2028))),
    sym6("JLC06161H-7628D", two(.prepreg, "7628*1 + 7628*1", pp7628(0.216), pp7628(0.2084)), one(.core, "Core", corePly(0.2)), one(.prepreg, "7628*1", pp7628(0.2008))),
    sym6("JLC06161H-1080", one(.prepreg, "1080*1", pp1080(0.0764)), one(.core, "Core", corePly(0.55)), one(.prepreg, "7628*1", pp7628(0.2104))),
    sym6("JLC06161H-2116A", one(.prepreg, "2116*1", pp2116(0.1164)), one(.core, "Core", corePly(0.13)), three(.core, "2116*1 + Core + 2116*1", pp2116(0.1164), corePly(0.7), pp2116(0.1164))),
    sym6("JLC06161H-1080A", one(.prepreg, "1080*1", pp1080(0.0764)), one(.core, "Core", corePly(0.6)), one(.prepreg, "3313*1", pp3313(0.0994))),
    sym6("JLC06161H-3313C", two(.prepreg, "3313*1 + 1080*1", pp3313(0.107), pp1080(0.0764)), one(.core, "Core", corePly(0.4)), two(.prepreg, "1080*1 + 1080*1", pp1080(0.0764), pp1080(0.0764))),
    sym6("JLC06161H-1080B", one(.prepreg, "1080*1", pp1080(0.0764)), one(.core, "Core", corePly(0.1)), three(.core, "7628*1 + Core + 7628*1", pp7628(0.2104), corePly(0.7), pp7628(0.2104))),
    sym6("JLC06161H-3313E", one(.prepreg, "3313*1", pp3313(0.0994)), one(.core, "Core", corePly(0.1)), three(.core, "7628*1 + Core + 7628*1", pp7628(0.2104), corePly(0.7), pp7628(0.2104))),
    sym6("JLC06161H-2116B", one(.prepreg, "2116*1", pp2116(0.1164)), one(.core, "Core", corePly(0.5)), two(.prepreg, "1080*1 + 1080*1", pp1080(0.0764), pp1080(0.0764))),
    sym6("JLC06161H-2116", two(.prepreg, "2116*1 + 2313*1", pp2116(0.127), pp2313(0.0964)), one(.core, "Core", corePly(0.3)), two(.prepreg, "7628*1 + 7628*1", pp7628(0.2084), pp7628(0.2084))),
    sym6("JLC06161H-7628B", two(.prepreg, "7628*1 + 1080*1", pp7628(0.218), pp1080(0.0764)), one(.core, "Core", corePly(0.35)), two(.prepreg, "1080*1 + 1080*1", pp1080(0.0764), pp1080(0.0764))),
    sym6("JLC06161H-3313D", two(.prepreg, "3313*1 + 1080*1", pp3313(0.107), pp1080(0.0764)), one(.core, "Core", corePly(0.25)), three(.prepreg, "7628*1 + 2116*1 + 7628*1", pp7628(0.2104), pp2116(0.124), pp7628(0.2104))),
    sym6("JLC06161H-7628A", three(.prepreg, "7628*1 + 7628*1 + 1080*1", pp7628(0.218), pp7628(0.218), pp1080(0.0764)), one(.core, "Core", corePly(0.1)), two(.prepreg, "2116*1 + 2116*1", pp2116(0.1164), pp2116(0.1164))),
};

fn dielectric(gap: Gap, after_layer: u8) env.StackupDielectric {
    var thickness: f64 = 0;
    var electrical_height: f64 = 0;
    for (gap.plies[0..gap.len]) |ply| {
        thickness += ply.thickness;
        electrical_height += ply.thickness / ply.er;
    }
    return .{
        .after_layer = after_layer,
        .kind = gap.kind,
        .material = gap.label,
        .thickness = thickness,
        .er = if (electrical_height > 0) thickness / electrical_height else 0,
    };
}

/// Expand a case-insensitive preset name into an owned physical stackup.
pub fn resolve(allocator: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?env.StackupSpec {
    for (definitions) |definition| {
        if (!std.ascii.eqlIgnoreCase(definition.entry.name, name)) continue;
        const copper = try allocator.alloc(env.StackupCopper, definition.entry.layers);
        errdefer allocator.free(copper);
        for (copper, 0..) |*layer, i| {
            const outer = i == 0 or i + 1 == copper.len;
            layer.* = .{ .index = @intCast(i + 1), .thickness = if (outer) 0.035 else 0.0152 };
        }
        const dielectrics = try allocator.alloc(env.StackupDielectric, definition.gap_count);
        for (dielectrics, 0..) |*gap, i| gap.* = dielectric(definition.gaps[i], @intCast(i + 1));
        return .{
            .layers = definition.entry.layers,
            .copper = copper,
            .dielectrics = dielectrics,
            .present = true,
            .thickness = definition.entry.thickness,
            .preset = definition.entry.name,
        };
    }
    return null;
}

/// Write the preset selection and complete catalog into PCB settings JSON.
pub fn writeCatalogJson(w: *std.Io.Writer, current: env.StackupSpec) std.Io.Writer.Error!void {
    try w.writeAll(",\"preset\":");
    if (current.preset.len > 0) try w.print("\"{s}\"", .{current.preset}) else try w.writeAll("null");
    try w.writeAll(",\"presets\":[");
    for (definitions, 0..) |definition, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"name\":\"{s}\",\"layers\":{d},\"thickness\":{d}}}", .{
            definition.entry.name,
            definition.entry.layers,
            definition.entry.thickness,
        });
    }
    try w.print("],\"layers\":{d},\"thickness\":{d},\"planes\":[", .{ current.layers, current.thickness });
}

test "JLC04161H-7628 resolves the supplied JLC construction" {
    const spec = (try resolve(std.testing.allocator, "jlc04161h-7628")).?;
    defer std.testing.allocator.free(spec.copper);
    defer std.testing.allocator.free(spec.dielectrics);
    try std.testing.expectEqual(@as(u8, 4), spec.layers);
    try std.testing.expectEqualStrings("JLC04161H-7628", spec.preset);
    try std.testing.expectApproxEqAbs(@as(f64, 0.2104), spec.dielectrics[0].thickness, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.4), spec.dielectrics[0].er, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.065), spec.dielectrics[1].thickness, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4.6), spec.dielectrics[1].er, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5862), spec.constructionThickness(), 1e-9);
}

test "catalog contains every supplied JLC controlled-impedance construction" {
    try std.testing.expectEqual(@as(usize, 31), definitions.len);
    for (definitions) |definition| {
        const spec = (try resolve(std.testing.allocator, definition.entry.name)).?;
        defer std.testing.allocator.free(spec.copper);
        defer std.testing.allocator.free(spec.dielectrics);
        try std.testing.expectEqual(definition.entry.layers, spec.layers);
        try std.testing.expectEqual(@as(usize, definition.entry.layers), spec.copper.len);
        try std.testing.expectEqual(@as(usize, definition.entry.layers - 1), spec.dielectrics.len);
    }
}
