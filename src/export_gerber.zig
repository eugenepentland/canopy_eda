const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const layout_mod = @import("layout.zig");
const netlist_mod = @import("export_kicad_netlist.zig");
const collectInstances = netlist_mod.collectInstances;
const FlatInstance = @import("export_kicad.zig").FlatInstance;
const parser_mod = @import("sexpr/parser.zig");
const pcb_json = @import("render_pcb_json.zig");

/// A single Gerber output file.
pub const GerberFile = struct {
    name: []const u8,
    data: []const u8,
};

/// Aperture definition: round, rect, or oblong.
const Aperture = struct {
    kind: enum { circle, rect, oblong },
    w: f64,
    h: f64,
};

/// Generate all Gerber + Excellon files for a design.
/// Returns a list of GerberFile entries suitable for zipping.
pub fn exportGerber(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    board_def: ?*const env_mod.Board,
    layout_path: ?[]const u8,
) ![]const GerberFile {
    // Flatten hierarchy
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    try collectInstances(allocator, block, "", &instances);

    // Load layout
    var layout_traces: []const layout_mod.Trace = &.{};
    var layout_vias: []const layout_mod.Via = &.{};
    var layout_zone_fills: []const layout_mod.ZoneFill = &.{};
    var placements = std.StringHashMap(Placement).init(allocator);
    defer placements.deinit();

    if (layout_path) |lp| {
        if (layout_mod.loadLayout(allocator, lp)) |layout| {
            for (layout.placements) |p| {
                try placements.put(p.uuid, .{
                    .x = p.x,
                    .y = p.y,
                    .angle = p.angle,
                    .side = p.side,
                });
            }
            layout_traces = layout.traces;
            layout_vias = layout.vias;
            layout_zone_fills = layout.zone_fills;
        } else |_| {}
    }

    // Parse footprint geometry for each unique footprint
    var fp_geom = std.StringHashMap(FootprintGeom).init(allocator);
    defer fp_geom.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (fp_geom.contains(inst.footprint)) continue;
        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);
        const source = infra_fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
        const geom = parseGeometry(allocator, source) catch continue;
        try fp_geom.put(inst.footprint, geom);
    }

    var files: std.ArrayListUnmanaged(GerberFile) = .empty;

    // Generate copper layers
    const fcu = try generateCopperLayer(allocator, "F.Cu", instances.items, &placements, &fp_geom, layout_traces, layout_vias, layout_zone_fills, board_def, design_name);
    try files.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "{s}-F_Cu.gbr", .{design_name}), .data = fcu });

    const bcu = try generateCopperLayer(allocator, "B.Cu", instances.items, &placements, &fp_geom, layout_traces, layout_vias, layout_zone_fills, board_def, design_name);
    try files.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "{s}-B_Cu.gbr", .{design_name}), .data = bcu });

    // Solder mask (pads expanded by 0.05mm)
    const fmask = try generateMaskLayer(allocator, "F.Cu", instances.items, &placements, &fp_geom, layout_vias, design_name, "F.Mask");
    try files.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "{s}-F_Mask.gbr", .{design_name}), .data = fmask });

    const bmask = try generateMaskLayer(allocator, "B.Cu", instances.items, &placements, &fp_geom, layout_vias, design_name, "B.Mask");
    try files.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "{s}-B_Mask.gbr", .{design_name}), .data = bmask });

    // Silkscreen
    const fsilk = try generateSilkLayer(allocator, "F.Cu", instances.items, &placements, &fp_geom, design_name, "F.SilkS");
    try files.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "{s}-F_Silkscreen.gbr", .{design_name}), .data = fsilk });

    // Edge cuts (board outline)
    if (board_def) |bd| {
        if (bd.outline.len >= 3) {
            const edge = try generateEdgeCuts(allocator, bd.outline, design_name);
            try files.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "{s}-Edge_Cuts.gbr", .{design_name}), .data = edge });
        }
    }

    // Excellon drill file
    const drill = try generateDrill(allocator, instances.items, &placements, &fp_geom, layout_vias, design_name);
    try files.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "{s}.drl", .{design_name}), .data = drill });

    // Pick and place
    const pnp = try generatePnP(allocator, instances.items, &placements, design_name);
    try files.append(allocator, .{ .name = try std.fmt.allocPrint(allocator, "{s}-pnp.csv", .{design_name}), .data = pnp });

    return try files.toOwnedSlice(allocator);
}

// --- Internal types ---

const Placement = struct { x: f64, y: f64, angle: f64, side: layout_mod.Side };

const PadGeom = struct {
    name: []const u8,
    shape: []const u8, // circle, rect, roundrect, oval
    pad_type: []const u8, // smd, thru_hole
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    drill: f64,
};

const LineGeom = struct { x1: f64, y1: f64, x2: f64, y2: f64, width: f64, layer: []const u8 };

const FootprintGeom = struct {
    pads: []const PadGeom,
    silk_lines: []const LineGeom,
};

fn parseGeometry(allocator: std.mem.Allocator, source: []const u8) !FootprintGeom {
    const nodes = try parser_mod.parse(allocator, source);
    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];
    const children = root.asList() orelse return error.InvalidFormat;

    var pads: std.ArrayListUnmanaged(PadGeom) = .empty;
    var silk_lines: std.ArrayListUnmanaged(LineGeom) = .empty;

    for (children) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len == 0) continue;
        const tag = cl[0].asAtom() orelse continue;

        if (std.mem.eql(u8, tag, "pad")) {
            if (cl.len < 5) continue;
            const name = cl[1].asAtom() orelse cl[1].asString() orelse continue;
            const pad_type = cl[2].asAtom() orelse continue;
            const shape = cl[3].asAtom() orelse continue;
            var px: f64 = 0;
            var py: f64 = 0;
            var pw: f64 = 0;
            var ph: f64 = 0;
            var drill: f64 = 0;
            for (cl[4..]) |sub| {
                const sl = sub.asList() orelse continue;
                if (sl.len < 2) continue;
                const stag = sl[0].asAtom() orelse continue;
                if (std.mem.eql(u8, stag, "pos") and sl.len >= 3) {
                    px = nodeFloat(sl[1]);
                    py = nodeFloat(sl[2]);
                } else if (std.mem.eql(u8, stag, "size") and sl.len >= 3) {
                    pw = nodeFloat(sl[1]);
                    ph = nodeFloat(sl[2]);
                } else if (std.mem.eql(u8, stag, "drill")) {
                    drill = nodeFloat(sl[1]);
                }
            }
            try pads.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .shape = try allocator.dupe(u8, shape),
                .pad_type = try allocator.dupe(u8, pad_type),
                .x = px,
                .y = py,
                .w = pw,
                .h = ph,
                .drill = drill,
            });
        } else if (std.mem.eql(u8, tag, "line")) {
            // (line (pts x1 y1 x2 y2) (layer "F.SilkS") (width 0.12))
            var lx1: f64 = 0;
            var ly1: f64 = 0;
            var lx2: f64 = 0;
            var ly2: f64 = 0;
            var lw: f64 = 0.12;
            var layer: []const u8 = "F.SilkS";
            for (cl[1..]) |sub| {
                const sl = sub.asList() orelse continue;
                if (sl.len < 2) continue;
                const stag = sl[0].asAtom() orelse continue;
                if (std.mem.eql(u8, stag, "pts") and sl.len >= 5) {
                    lx1 = nodeFloat(sl[1]);
                    ly1 = nodeFloat(sl[2]);
                    lx2 = nodeFloat(sl[3]);
                    ly2 = nodeFloat(sl[4]);
                } else if (std.mem.eql(u8, stag, "layer")) {
                    layer = sl[1].asString() orelse sl[1].asAtom() orelse "F.SilkS";
                } else if (std.mem.eql(u8, stag, "width")) {
                    lw = nodeFloat(sl[1]);
                }
            }
            try silk_lines.append(allocator, .{ .x1 = lx1, .y1 = ly1, .x2 = lx2, .y2 = ly2, .width = lw, .layer = try allocator.dupe(u8, layer) });
        }
    }

    return .{
        .pads = try pads.toOwnedSlice(allocator),
        .silk_lines = try silk_lines.toOwnedSlice(allocator),
    };
}

fn nodeFloat(node: anytype) f64 {
    if (node.asNumber()) |n| return n;
    if (node.asAtom()) |s| return std.fmt.parseFloat(f64, s) catch 0;
    return 0;
}

// --- Gerber generation ---

fn gerberHeader(w: anytype, layer_name: []const u8, design_name: []const u8) !void {
    // RS-274X header
    try w.writeAll("G04 Generated by Canopy EDA*\n");
    try w.print("G04 Design: {s}*\n", .{design_name});
    try w.print("G04 Layer: {s}*\n", .{layer_name});
    try w.writeAll("%FSLAX46Y46*%\n"); // Format: leading zeros omitted, 4.6 decimal
    try w.writeAll("%MOMM*%\n"); // Units: mm
    try w.writeAll("%LPD*%\n"); // Layer polarity: dark
}

fn gerberFooter(w: anytype) !void {
    try w.writeAll("M02*\n");
}

fn fmtCoord(val: f64) i64 {
    // Convert mm to integer with 6 decimal places (nanometers)
    return @intFromFloat(@round(val * 1000000.0));
}

fn writeFlash(w: anytype, x: f64, y: f64) !void {
    try w.print("X{d}Y{d}D03*\n", .{ fmtCoord(x), fmtCoord(y) });
}

fn writeDraw(w: anytype, x1: f64, y1: f64, x2: f64, y2: f64) !void {
    try w.print("X{d}Y{d}D02*\n", .{ fmtCoord(x1), fmtCoord(y1) });
    try w.print("X{d}Y{d}D01*\n", .{ fmtCoord(x2), fmtCoord(y2) });
}

fn transformPad(px: f64, py: f64, angle_deg: f64, comp_x: f64, comp_y: f64) [2]f64 {
    const a = angle_deg * std.math.pi / 180.0;
    const cos_a = @cos(a);
    const sin_a = @sin(a);
    return .{
        comp_x + px * cos_a - py * sin_a,
        comp_y + px * sin_a + py * cos_a,
    };
}

fn generateCopperLayer(
    allocator: std.mem.Allocator,
    layer: []const u8,
    instances: []const FlatInstance,
    placed: *const std.StringHashMap(Placement),
    fp_geom: *const std.StringHashMap(FootprintGeom),
    traces: []const layout_mod.Trace,
    vias: []const layout_mod.Via,
    zone_fills: []const layout_mod.ZoneFill,
    board_def: ?*const env_mod.Board,
    design_name: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try gerberHeader(w, layer, design_name);

    // Collect unique apertures needed
    var apertures: std.ArrayListUnmanaged(Aperture) = .empty;
    defer apertures.deinit(allocator);

    // Aperture 10+ for pads, then trace widths, then via pads
    // We'll assign apertures as we go and track what we've seen
    var aperture_map = std.StringHashMap(u32).init(allocator);
    defer aperture_map.deinit();
    var next_aperture: u32 = 10;

    const is_front = std.mem.eql(u8, layer, "F.Cu");

    // Pre-scan: collect all pad shapes and trace widths to define apertures
    for (instances) |inst| {
        if (inst.footprint.len == 0) continue;
        const pl = placed.get(inst.uuid) orelse continue;
        const is_inst_front = pl.side == .front;
        const geom = fp_geom.get(inst.footprint) orelse continue;

        for (geom.pads) |pad| {
            const is_thru = std.mem.eql(u8, pad.pad_type, "thru_hole");
            if (!is_thru and is_inst_front != is_front) continue;

            const key = try std.fmt.allocPrint(allocator, "pad_{s}_{d:.4}_{d:.4}", .{ pad.shape, pad.w, pad.h });
            if (!aperture_map.contains(key)) {
                const kind: Aperture = if (std.mem.eql(u8, pad.shape, "circle"))
                    .{ .kind = .circle, .w = pad.w, .h = pad.w }
                else if (std.mem.eql(u8, pad.shape, "oval"))
                    .{ .kind = .oblong, .w = pad.w, .h = pad.h }
                else
                    .{ .kind = .rect, .w = pad.w, .h = pad.h };

                try aperture_map.put(key, next_aperture);
                try apertures.append(allocator, kind);
                next_aperture += 1;
            }
        }
    }

    // Trace width apertures
    for (traces) |t| {
        if (!std.mem.eql(u8, t.layer, layer)) continue;
        const key = try std.fmt.allocPrint(allocator, "trace_{d:.4}", .{t.width});
        if (!aperture_map.contains(key)) {
            try aperture_map.put(key, next_aperture);
            try apertures.append(allocator, .{ .kind = .circle, .w = t.width, .h = t.width });
            next_aperture += 1;
        }
    }

    // Via pad aperture
    for (vias) |v| {
        const key = try std.fmt.allocPrint(allocator, "via_{d:.4}", .{v.pad_size});
        if (!aperture_map.contains(key)) {
            try aperture_map.put(key, next_aperture);
            try apertures.append(allocator, .{ .kind = .circle, .w = v.pad_size, .h = v.pad_size });
            next_aperture += 1;
        }
    }

    // Write aperture definitions
    var ap_idx: u32 = 10;
    for (apertures.items) |ap| {
        switch (ap.kind) {
            .circle => try w.print("%ADD{d}C,{d:.4}*%\n", .{ ap_idx, ap.w }),
            .rect => try w.print("%ADD{d}R,{d:.4}X{d:.4}*%\n", .{ ap_idx, ap.w, ap.h }),
            .oblong => try w.print("%ADD{d}O,{d:.4}X{d:.4}*%\n", .{ ap_idx, ap.w, ap.h }),
        }
        ap_idx += 1;
    }

    // Flash pads
    for (instances) |inst| {
        if (inst.footprint.len == 0) continue;
        const pl = placed.get(inst.uuid) orelse continue;
        const is_inst_front = pl.side == .front;
        const geom = fp_geom.get(inst.footprint) orelse continue;

        for (geom.pads) |pad| {
            const is_thru = std.mem.eql(u8, pad.pad_type, "thru_hole");
            if (!is_thru and is_inst_front != is_front) continue;

            const key = try std.fmt.allocPrint(allocator, "pad_{s}_{d:.4}_{d:.4}", .{ pad.shape, pad.w, pad.h });
            defer allocator.free(key);
            const ap_id = aperture_map.get(key) orelse continue;
            try w.print("D{d}*\n", .{ap_id});

            const pos = transformPad(pad.x, pad.y, pl.angle, pl.x, pl.y);
            try writeFlash(w, pos[0], pos[1]);
        }
    }

    // Draw traces
    for (traces) |t| {
        if (!std.mem.eql(u8, t.layer, layer)) continue;
        if (t.points.len < 2) continue;
        const key = try std.fmt.allocPrint(allocator, "trace_{d:.4}", .{t.width});
        defer allocator.free(key);
        const ap_id = aperture_map.get(key) orelse continue;
        try w.print("D{d}*\n", .{ap_id});

        for (0..t.points.len - 1) |pi| {
            try writeDraw(w, t.points[pi][0], t.points[pi][1], t.points[pi + 1][0], t.points[pi + 1][1]);
        }
    }

    // Flash vias (appear on all copper layers)
    for (vias) |v| {
        const key = try std.fmt.allocPrint(allocator, "via_{d:.4}", .{v.pad_size});
        defer allocator.free(key);
        const ap_id = aperture_map.get(key) orelse continue;
        try w.print("D{d}*\n", .{ap_id});
        try writeFlash(w, v.x, v.y);
    }

    // Zone fills as regions
    for (zone_fills) |z| {
        if (!std.mem.eql(u8, z.layer, layer)) continue;
        for (z.polygons) |poly| {
            if (poly.len < 3) continue;
            try w.writeAll("G36*\n"); // Region begin
            try w.print("X{d}Y{d}D02*\n", .{ fmtCoord(poly[0][0]), fmtCoord(poly[0][1]) });
            for (poly[1..]) |pt| {
                try w.print("X{d}Y{d}D01*\n", .{ fmtCoord(pt[0]), fmtCoord(pt[1]) });
            }
            // Close polygon
            try w.print("X{d}Y{d}D01*\n", .{ fmtCoord(poly[0][0]), fmtCoord(poly[0][1]) });
            try w.writeAll("G37*\n"); // Region end
        }
    }

    _ = board_def;
    try gerberFooter(w);
    return buf.toOwnedSlice(allocator);
}

fn generateMaskLayer(
    allocator: std.mem.Allocator,
    copper_layer: []const u8,
    instances: []const FlatInstance,
    placed: *const std.StringHashMap(Placement),
    fp_geom: *const std.StringHashMap(FootprintGeom),
    vias: []const layout_mod.Via,
    design_name: []const u8,
    mask_layer_name: []const u8,
) ![]const u8 {
    const mask_expansion: f64 = 0.05; // mm

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try gerberHeader(w, mask_layer_name, design_name);

    const is_front = std.mem.eql(u8, copper_layer, "F.Cu");
    var next_ap: u32 = 10;

    // Pads with mask expansion
    for (instances) |inst| {
        if (inst.footprint.len == 0) continue;
        const pl = placed.get(inst.uuid) orelse continue;
        const is_inst_front = pl.side == .front;
        const geom = fp_geom.get(inst.footprint) orelse continue;

        for (geom.pads) |pad| {
            const is_thru = std.mem.eql(u8, pad.pad_type, "thru_hole");
            if (!is_thru and is_inst_front != is_front) continue;

            const ew = pad.w + mask_expansion * 2;
            const eh = pad.h + mask_expansion * 2;
            if (std.mem.eql(u8, pad.shape, "circle")) {
                try w.print("%ADD{d}C,{d:.4}*%\n", .{ next_ap, ew });
            } else if (std.mem.eql(u8, pad.shape, "oval")) {
                try w.print("%ADD{d}O,{d:.4}X{d:.4}*%\n", .{ next_ap, ew, eh });
            } else {
                try w.print("%ADD{d}R,{d:.4}X{d:.4}*%\n", .{ next_ap, ew, eh });
            }
            try w.print("D{d}*\n", .{next_ap});
            next_ap += 1;

            const pos = transformPad(pad.x, pad.y, pl.angle, pl.x, pl.y);
            try writeFlash(w, pos[0], pos[1]);
        }
    }

    // Via mask openings
    for (vias) |v| {
        const vs = v.pad_size + mask_expansion * 2;
        try w.print("%ADD{d}C,{d:.4}*%\n", .{ next_ap, vs });
        try w.print("D{d}*\n", .{next_ap});
        next_ap += 1;
        try writeFlash(w, v.x, v.y);
    }

    try gerberFooter(w);
    return buf.toOwnedSlice(allocator);
}

fn generateSilkLayer(
    allocator: std.mem.Allocator,
    copper_layer: []const u8,
    instances: []const FlatInstance,
    placed: *const std.StringHashMap(Placement),
    fp_geom: *const std.StringHashMap(FootprintGeom),
    design_name: []const u8,
    silk_layer_name: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try gerberHeader(w, silk_layer_name, design_name);

    const is_front = std.mem.eql(u8, copper_layer, "F.Cu");

    // Default silk aperture (0.12mm line)
    try w.writeAll("%ADD10C,0.1200*%\n");
    try w.writeAll("D10*\n");

    for (instances) |inst| {
        if (inst.footprint.len == 0) continue;
        const pl = placed.get(inst.uuid) orelse continue;
        const is_inst_front = pl.side == .front;
        if (is_inst_front != is_front) continue;
        const geom = fp_geom.get(inst.footprint) orelse continue;

        for (geom.silk_lines) |line| {
            // Check if silk line is on the right side
            const is_front_silk = std.mem.indexOf(u8, line.layer, "F.") != null;
            if (is_front_silk != is_front) continue;

            const p1 = transformPad(line.x1, line.y1, pl.angle, pl.x, pl.y);
            const p2 = transformPad(line.x2, line.y2, pl.angle, pl.x, pl.y);
            try writeDraw(w, p1[0], p1[1], p2[0], p2[1]);
        }
    }

    try gerberFooter(w);
    return buf.toOwnedSlice(allocator);
}

fn generateEdgeCuts(allocator: std.mem.Allocator, outline: []const [2]f64, design_name: []const u8) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    try gerberHeader(w, "Edge.Cuts", design_name);

    // 0.05mm line for board outline
    try w.writeAll("%ADD10C,0.0500*%\n");
    try w.writeAll("D10*\n");

    for (0..outline.len) |i| {
        const j = (i + 1) % outline.len;
        try writeDraw(w, outline[i][0], outline[i][1], outline[j][0], outline[j][1]);
    }

    try gerberFooter(w);
    return buf.toOwnedSlice(allocator);
}

fn generateDrill(
    allocator: std.mem.Allocator,
    instances: []const FlatInstance,
    placed: *const std.StringHashMap(Placement),
    fp_geom: *const std.StringHashMap(FootprintGeom),
    vias: []const layout_mod.Via,
    design_name: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    // Excellon header
    try w.writeAll("M48\n");
    try w.print("; Generated by Canopy EDA - {s}\n", .{design_name});
    try w.writeAll("FMAT,2\n");
    try w.writeAll("METRIC,TZ\n");

    // Collect unique drill sizes
    var drill_sizes: std.ArrayListUnmanaged(f64) = .empty;
    defer drill_sizes.deinit(allocator);

    // Via drills
    for (vias) |v| {
        var found = false;
        for (drill_sizes.items) |d| {
            if (@abs(d - v.drill) < 0.001) {
                found = true;
                break;
            }
        }
        if (!found) try drill_sizes.append(allocator, v.drill);
    }

    // Through-hole pad drills
    for (instances) |inst| {
        if (inst.footprint.len == 0) continue;
        if (!placed.contains(inst.uuid)) continue;
        const geom = fp_geom.get(inst.footprint) orelse continue;
        for (geom.pads) |pad| {
            if (pad.drill <= 0) continue;
            var found = false;
            for (drill_sizes.items) |d| {
                if (@abs(d - pad.drill) < 0.001) {
                    found = true;
                    break;
                }
            }
            if (!found) try drill_sizes.append(allocator, pad.drill);
        }
    }

    // Tool definitions
    for (drill_sizes.items, 0..) |d, ti| {
        try w.print("T{d:0>2}C{d:.3}\n", .{ ti + 1, d });
    }
    try w.writeAll("%\n");

    // Drill hits per tool
    for (drill_sizes.items, 0..) |drill_size, ti| {
        try w.print("T{d:0>2}\n", .{ti + 1});

        // Vias with this drill size
        for (vias) |v| {
            if (@abs(v.drill - drill_size) < 0.001) {
                try w.print("X{d:.4}Y{d:.4}\n", .{ v.x, v.y });
            }
        }

        // Through-hole pads with this drill size
        for (instances) |inst| {
            if (inst.footprint.len == 0) continue;
            const pl = placed.get(inst.uuid) orelse continue;
            const geom = fp_geom.get(inst.footprint) orelse continue;
            for (geom.pads) |pad| {
                if (@abs(pad.drill - drill_size) >= 0.001) continue;
                const pos = transformPad(pad.x, pad.y, pl.angle, pl.x, pl.y);
                try w.print("X{d:.4}Y{d:.4}\n", .{ pos[0], pos[1] });
            }
        }
    }

    try w.writeAll("M30\n");
    return buf.toOwnedSlice(allocator);
}

fn generatePnP(
    allocator: std.mem.Allocator,
    instances: []const FlatInstance,
    placed: *const std.StringHashMap(Placement),
    design_name: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);

    _ = design_name;
    try w.writeAll("Ref,Val,Package,PosX,PosY,Rot,Side\n");

    for (instances) |inst| {
        if (inst.footprint.len == 0) continue;
        const pl = placed.get(inst.uuid) orelse continue;
        const side_str = if (pl.side == .front) "top" else "bottom";
        try w.print("{s},{s},{s},{d:.4},{d:.4},{d:.1},{s}\n", .{
            inst.ref_des, inst.value, inst.footprint,
            pl.x,         pl.y,       pl.angle,
            side_str,
        });
    }

    return buf.toOwnedSlice(allocator);
}
