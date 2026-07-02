//! Assembly/fab text outputs generated straight from a solved placement:
//! the pick-and-place centroid CSV and the Excellon drill files. These are
//! the netlisp-native halves of the manufacturing package (BOM already
//! exists; Gerber copper is a later phase) — enough for a fab to drill the
//! board and an assembler to place it without KiCad in the loop.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const export_kicad = @import("export_kicad.zig");

/// Write the pick-and-place centroid CSV (JLC-style columns): one row per
/// placed part — ref-des, value, footprint, centre (mm), rotation (deg), and
/// which board side it mounts on. `instances` is index-aligned with `parts`
/// (the `Placement` contract); a missing instance leaves value/package empty.
pub fn centroidCsv(
    w: *std.Io.Writer,
    parts: []const optimizer.Part,
    instances: []const export_kicad.FlatInstance,
) std.Io.Writer.Error!void {
    try w.writeAll("Designator,Val,Package,Mid X,Mid Y,Rotation,Layer\n");
    for (parts, 0..) |p, i| {
        try writeCsvField(w, p.ref_des);
        try w.writeByte(',');
        if (i < instances.len) try writeCsvField(w, instances[i].value);
        try w.writeByte(',');
        if (i < instances.len) try writeCsvField(w, instances[i].footprint);
        try w.print(",{d:.3}mm,{d:.3}mm,{d:.0},{s}\n", .{
            p.x,
            p.y,
            p.rot,
            if (p.side == .bottom) "Bottom" else "Top",
        });
    }
}

/// One hole for the Excellon writer: position (mm) + drill diameter (mm).
const Hole = struct { x: f64, y: f64, d: f64 };

/// Which drill file to emit — fabs take plated and non-plated holes as two
/// separate Excellon files.
pub const DrillClass = enum { plated, non_plated };

/// Write an Excellon (METRIC, decimal, trailing-zero) drill file.
/// `.plated` emits the PTH file: every plated through-hole pad of every
/// placed part plus every routed via. `.non_plated` emits the NPTH file
/// (mounting holes / non-plated pads only). Holes are grouped into one tool
/// per distinct diameter (0.01 mm resolution), smallest first.
pub fn excellonDrill(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    parts: []const optimizer.Part,
    vias: []const router.Via,
    class: DrillClass,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const plated = class == .plated;
    var holes: std.ArrayListUnmanaged(Hole) = .empty;
    for (parts) |p| {
        for (p.pads) |pad| {
            if (pad.drill <= 0) continue;
            const want = if (plated) (pad.thru and !pad.npth) else pad.npth;
            if (!want) continue;
            const c = optimizer.worldPadCenter(p, pad.x, pad.y);
            try holes.append(alloc, .{ .x = c[0], .y = c[1], .d = pad.drill });
        }
    }
    if (plated) {
        for (vias) |v| {
            if (v.drill <= 0) continue;
            try holes.append(alloc, .{ .x = v.x, .y = v.y, .d = v.drill });
        }
    }

    // Distinct diameters (0.01 mm buckets), ascending — one Excellon tool each.
    var dias: std.ArrayListUnmanaged(f64) = .empty;
    for (holes.items) |h| {
        var known = false;
        for (dias.items) |d| {
            if (@abs(d - h.d) < 0.005) {
                known = true;
                break;
            }
        }
        if (!known) try dias.append(alloc, h.d);
    }
    std.sort.pdq(f64, dias.items, {}, std.sort.asc(f64));

    try w.writeAll("M48\n");
    try w.print(";TYPE={s}\n", .{if (plated) @as([]const u8, "PLATED") else "NON_PLATED"});
    try w.writeAll("METRIC,TZ\n");
    for (dias.items, 1..) |d, ti| try w.print("T{d}C{d:.3}\n", .{ ti, d });
    try w.writeAll("%\n");
    for (dias.items, 1..) |d, ti| {
        try w.print("T{d}\n", .{ti});
        for (holes.items) |h| {
            if (@abs(h.d - d) >= 0.005) continue;
            try w.print("X{d:.3}Y{d:.3}\n", .{ h.x, h.y });
        }
    }
    try w.writeAll("M30\n");
}

/// Escape one CSV field: quoted (with doubled quotes) only when it contains
/// a comma, quote, or newline — plain fields stay unquoted for readability.
fn writeCsvField(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const needs_quote = std.mem.indexOfAny(u8, s, ",\"\n") != null;
    if (!needs_quote) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"') try w.writeAll("\"\"") else try w.writeByte(ch);
    }
    try w.writeByte('"');
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("placement/geometry.zig");

// spec: export_fab - the centroid CSV lists each part's pose with its board side
test "centroidCsv emits one side-aware row per part" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 10, .y = 5, .rot = 90 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 1, .y = 2, .side = .bottom },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "mcu", .value = "STM32", .footprint = "LQFP-48", .uuid = "", .origin_key = "", .properties = &.{} },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "C_0402", .uuid = "", .origin_key = "", .properties = &.{} },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try centroidCsv(&aw.writer, &parts, &instances);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "U1,STM32,LQFP-48,10.000mm,5.000mm,90,Top") != null);
    try testing.expect(std.mem.indexOf(u8, out, "C1,100nF,C_0402,1.000mm,2.000mm,0,Bottom") != null);
}

// spec: export_fab - the Excellon writer splits plated pads + vias from non-plated holes and groups tools by diameter
test "excellonDrill separates PTH and NPTH files" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1.4, .h = 1.4, .thru = true, .drill = 0.92 },
        .{ .number = "MH1", .x = 3, .y = 0, .w = 0.75, .h = 0.75, .thru = true, .npth = true, .drill = 0.75 },
        .{ .number = "2", .x = 1, .y = 0, .w = 0.5, .h = 0.5 }, // SMD — no hole
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 10 },
    };
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};

    var pth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&pth.writer, alloc, &parts, &vias, .plated);
    const pth_out = pth.written();
    try testing.expect(std.mem.indexOf(u8, pth_out, "T1C0.200") != null); // via tool (smallest first)
    try testing.expect(std.mem.indexOf(u8, pth_out, "C0.920") != null); // thru pad tool
    try testing.expect(std.mem.indexOf(u8, pth_out, "X10.000Y10.000") != null); // pad at part origin
    try testing.expect(std.mem.indexOf(u8, pth_out, "C0.750") == null); // NPTH kept out

    var npth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&npth.writer, alloc, &parts, &vias, .non_plated);
    const npth_out = npth.written();
    try testing.expect(std.mem.indexOf(u8, npth_out, "T1C0.750") != null); // the mounting hole
    try testing.expect(std.mem.indexOf(u8, npth_out, "X13.000Y10.000") != null);
    try testing.expect(std.mem.indexOf(u8, npth_out, "C0.200") == null); // vias are plated-only
}
