const std = @import("std");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Section = env_mod.Section;
const parser_mod = @import("sexpr/parser.zig");

const export_kicad = @import("export_kicad.zig");
const FlatInstance = export_kicad.FlatInstance;
const FlatNet = export_kicad.FlatNet;
const FlatPin = export_kicad.FlatPin;
const Property = env_mod.Property;
const uuidFromId = export_kicad.uuidFromId;

const layout_mod = @import("layout.zig");
const netlist_mod = @import("export_kicad_netlist.zig");
const collectInstances = netlist_mod.collectInstances;
const collectNets = netlist_mod.collectNets;
const extractPadNames = netlist_mod.extractPadNames;
const extractFootprintName = netlist_mod.extractFootprintName;

const model_mod = @import("export_kicad_model.zig");
const buildKicadMod = model_mod.buildKicadMod;
const findModelFile = @import("export_kicad_footprint.zig").findModelFile;
const loadModelConfig = model_mod.loadModelConfig;

/// Placement state for a footprint read from an existing .kicad_pcb.
pub const PlacedFootprint = struct {
    x: f64,
    y: f64,
    angle: f64,
    layer: []const u8,
    flipped: bool,
};

/// Generate a .kicad_pcb file from a resolved design.
///
/// If `existing_pcb_path` is non-null and the file exists, footprint positions
/// are preserved for components whose canopy_uuid matches. New components are
/// placed in a section-based grid; removed components are dropped.
pub fn exportPcb(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    existing_pcb_path: ?[]const u8,
    board_def: ?*const env_mod.Board,
    layout_path: ?[]const u8,
) ![]const u8 {
    // Flatten hierarchy
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayListUnmanaged(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try collectNets(allocator, block, "", &nets);

    // Build pin→net lookup: "REF\x00PIN" → net_index (1-based, 0 = unconnected)
    var pin_net_map = std.StringHashMap(usize).init(allocator);
    defer pin_net_map.deinit();
    for (nets.items, 0..) |net, ni| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ pin.ref_des, pin.pin });
            try pin_net_map.put(key, ni + 1);
        }
    }

    // Build footprint name map and pad maps
    var fp_name_map = std.StringHashMap([]const u8).init(allocator);
    defer fp_name_map.deinit();
    var fp_kicad_mod_map = std.StringHashMap([]const u8).init(allocator);
    defer fp_kicad_mod_map.deinit();
    var fp_pad_map = std.StringHashMap([]const []const u8).init(allocator);
    defer fp_pad_map.deinit();
    var processed_fps = std.StringHashMap(void).init(allocator);
    defer processed_fps.deinit();

    var model_cfg = loadModelConfig(allocator, project_dir);
    defer model_cfg.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed_fps.contains(inst.footprint)) continue;
        try processed_fps.put(inst.footprint, {});

        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);

        const fp_source = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch {
            try fp_name_map.put(inst.footprint, inst.footprint);
            continue;
        };

        const kicad_name = extractFootprintName(allocator, fp_source) catch inst.footprint;
        try fp_name_map.put(inst.footprint, kicad_name);

        // Extract pad names for NC handling
        const pad_names = extractPadNames(allocator, fp_source) catch &.{};
        try fp_pad_map.put(inst.footprint, pad_names);

        // Build .kicad_mod content
        const mcfg = model_cfg.get(inst.footprint);
        const model_name = if (mcfg) |c| (c.model orelse findModelFile(allocator, project_dir, inst.footprint, inst.component)) else findModelFile(allocator, project_dir, inst.footprint, inst.component);

        const mod_output = buildKicadMod(allocator, project_dir, inst.footprint, fp_source, model_name, if (mcfg) |c| c.offset else null, if (mcfg) |c| c.rotation else null) catch continue;
        try fp_kicad_mod_map.put(inst.footprint, mod_output);
    }

    // Load placements: try .layout first, fall back to existing .kicad_pcb
    var placed = std.StringHashMap(PlacedFootprint).init(allocator);
    defer placed.deinit();
    var loaded_from_layout = false;
    var layout_traces: []const layout_mod.Trace = &.{};
    var layout_vias: []const layout_mod.Via = &.{};
    var layout_zone_fills: []const layout_mod.ZoneFill = &.{};
    if (layout_path) |lp| {
        if (layout_mod.loadLayout(allocator, lp)) |layout| {
            for (layout.placements) |p| {
                try placed.put(p.uuid, .{
                    .x = p.x,
                    .y = p.y,
                    .angle = p.angle,
                    .layer = if (p.side == .back) "B.Cu" else "F.Cu",
                    .flipped = p.side == .back,
                });
            }
            layout_traces = layout.traces;
            layout_vias = layout.vias;
            layout_zone_fills = layout.zone_fills;
            loaded_from_layout = true;
        } else |_| {}
    }
    if (!loaded_from_layout) {
        if (existing_pcb_path) |pcb_path| {
            const existing = std.fs.cwd().readFileAlloc(allocator, pcb_path, 100 * 1024 * 1024) catch null;
            if (existing) |pcb_content| {
                try parseExistingPlacements(allocator, pcb_content, &placed);
            }
        }
    }

    // Build section→ref_des mapping for grid placement
    var ref_section = std.StringHashMap(usize).init(allocator);
    defer ref_section.deinit();
    try buildSectionMap(allocator, block, &ref_section);

    // Generate .kicad_pcb output
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Board parameters (from board form or defaults)
    const thickness: f64 = if (board_def) |b| b.thickness else 1.6;
    const copper_layers: u8 = if (board_def) |b| b.copper_layers else 2;

    // Header
    try w.writeAll("(kicad_pcb\n");
    try w.writeAll("\t(version 20241229)\n");
    try w.writeAll("\t(generator \"canopy-eda\")\n");
    try w.writeAll("\t(generator_version \"1.0\")\n");
    try w.print("\t(general\n\t\t(thickness {d:.1})\n\t\t(legacy_teardrops no)\n\t)\n", .{thickness});
    try w.writeAll("\t(paper \"A4\")\n");

    try writeLayerDefs(w, copper_layers);
    try writeSetup(w, board_def);

    // Net declarations
    try w.writeAll("\t(net 0 \"\")\n");
    for (nets.items, 0..) |net, ni| {
        try w.print("\t(net {d} \"{s}\")\n", .{ ni + 1, net.name });
    }
    try w.writeAll("\n");

    // Footprints
    // Placement grid for new components
    var next_x: f64 = 20.0; // mm
    var next_y: f64 = 30.0;
    const comp_gap: f64 = 2.0;
    const max_row_width: f64 = 80.0;
    const row_start_y: f64 = 30.0;
    _ = row_start_y;

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;

        const mod_source = fp_kicad_mod_map.get(inst.footprint) orelse continue;

        // Determine position
        var pos_x: f64 = next_x;
        var pos_y: f64 = next_y;
        var angle: f64 = 0;
        var layer: []const u8 = "F.Cu";
        if (inst.uuid.len > 0) {
            if (placed.get(inst.uuid)) |p| {
                pos_x = p.x;
                pos_y = p.y;
                angle = p.angle;
                layer = p.layer;
            } else {
                // New component — advance grid
                next_x += comp_gap + 3.0; // estimate 3mm per component
                if (next_x > max_row_width) {
                    next_x = 20.0;
                    next_y += comp_gap + 3.0;
                }
            }
        }

        try writeFootprint(allocator, w, inst, mod_source, pos_x, pos_y, angle, layer, &pin_net_map, &nets, &fp_pad_map, design_name);
    }

    // Board outline on Edge.Cuts layer
    if (board_def) |b| {
        if (b.outline.len >= 3) {
            try writeOutline(w, b.outline);
        }
    }

    // Build net name → index map for traces/vias/zones
    var net_name_map = std.StringHashMap(usize).init(allocator);
    defer net_name_map.deinit();
    for (nets.items, 0..) |net, ni| {
        try net_name_map.put(net.name, ni + 1);
    }

    // Traces → (segment ...)
    for (layout_traces) |t| {
        const net_idx = net_name_map.get(t.net) orelse 0;
        if (t.points.len < 2) continue;
        for (0..t.points.len - 1) |pi| {
            try w.print("\t(segment (start {d:.4} {d:.4}) (end {d:.4} {d:.4}) (width {d:.4}) (layer \"{s}\") (net {d}))\n", .{
                t.points[pi][0],     t.points[pi][1],
                t.points[pi + 1][0], t.points[pi + 1][1],
                t.width,             t.layer,
                net_idx,
            });
        }
    }

    // Vias → (via ...)
    for (layout_vias) |v| {
        const net_idx = net_name_map.get(v.net) orelse 0;
        try w.print("\t(via (at {d:.4} {d:.4}) (size {d:.4}) (drill {d:.4}) (layers \"{s}\" \"{s}\") (net {d}))\n", .{
            v.x, v.y, v.pad_size, v.drill, v.layer_from, v.layer_to, net_idx,
        });
    }

    // Zone fills → (zone ...)
    for (layout_zone_fills) |z| {
        const net_idx = net_name_map.get(z.zone_name) orelse 0;
        try w.print("\t(zone (net {d}) (net_name \"{s}\") (layer \"{s}\") (fill yes)\n", .{ net_idx, z.zone_name, z.layer });
        for (z.polygons) |poly| {
            try w.writeAll("\t\t(filled_polygon (pts\n");
            for (poly) |pt| {
                try w.print("\t\t\t(xy {d:.4} {d:.4})\n", .{ pt[0], pt[1] });
            }
            try w.writeAll("\t\t))\n");
        }
        try w.writeAll("\t)\n");
    }

    // Close
    try w.writeAll("\t(embedded_fonts no)\n");
    try w.writeAll(")\n");

    return buf.toOwnedSlice(allocator);
}

/// Write a single footprint into the PCB output.
///
/// Takes the .kicad_mod source and injects position, net assignments, UUID,
/// and canopy tracking fields.
fn writeFootprint(
    allocator: std.mem.Allocator,
    w: anytype,
    inst: FlatInstance,
    mod_source: []const u8,
    pos_x: f64,
    pos_y: f64,
    angle: f64,
    layer: []const u8,
    pin_net_map: *const std.StringHashMap(usize),
    nets: *const std.ArrayListUnmanaged(FlatNet),
    fp_pad_map: *const std.StringHashMap([]const []const u8),
    design_name: []const u8,
) !void {
    _ = design_name;
    // Parse the .kicad_mod source to extract structure
    // We'll rewrite it with our modifications
    const nodes = parser_mod.parse(allocator, mod_source) catch return;

    if (nodes.len == 0) return;
    const root = nodes[0];
    if (!root.isForm("footprint")) return;
    const children = root.asList() orelse return;
    if (children.len < 2) return;

    // Get the footprint name
    const fp_name = children[1].asAtom() orelse children[1].asString() orelse return;

    // Generate footprint UUID
    const fp_uuid = if (inst.uuid.len > 0) inst.uuid else "00000000-0000-0000-0000-000000000000";

    try w.print("\t(footprint \"{s}\"\n", .{fp_name});
    try w.print("\t\t(layer \"{s}\")\n", .{layer});
    try w.print("\t\t(uuid \"{s}\")\n", .{fp_uuid});
    if (angle != 0) {
        try w.print("\t\t(at {d:.6} {d:.6} {d:.1})\n", .{ pos_x, pos_y, angle });
    } else {
        try w.print("\t\t(at {d:.6} {d:.6})\n", .{ pos_x, pos_y });
    }

    // Description from original
    for (children[2..]) |child| {
        if (child.isForm("descr")) {
            const cl = child.asList() orelse continue;
            if (cl.len >= 2) {
                const desc = cl[1].asString() orelse cl[1].asAtom() orelse continue;
                try w.print("\t\t(descr \"{s}\")\n", .{desc});
            }
            break;
        }
    }

    // Properties: Reference, Value, canopy_uuid
    try writeProperty(w, "Reference", inst.ref_des, "F.SilkS", false);
    try writeProperty(w, "Value", inst.value, "F.Fab", false);
    try writeProperty(w, "Datasheet", "", "F.Fab", true);
    try writeProperty(w, "Description", "", "F.Fab", true);
    if (inst.uuid.len > 0) {
        try writeProperty(w, "canopy_uuid", inst.uuid, "F.SilkS", true);
    }
    // MPN property
    for (inst.properties) |prop| {
        if (std.mem.eql(u8, prop.key, "mpn")) {
            try writeProperty(w, "MPN", prop.value, "F.Fab", true);
            break;
        }
    }

    // Copy non-property, non-pad elements from the original (silkscreen, courtyard, fab)
    for (children[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len == 0) continue;
        const tag = cl[0].asAtom() orelse continue;

        // Skip elements we handle ourselves
        if (std.mem.eql(u8, tag, "descr")) continue;
        if (std.mem.eql(u8, tag, "property")) continue;
        if (std.mem.eql(u8, tag, "pad")) continue;
        if (std.mem.eql(u8, tag, "model")) continue;
        if (std.mem.eql(u8, tag, "layer")) continue;
        if (std.mem.eql(u8, tag, "at")) continue;
        if (std.mem.eql(u8, tag, "uuid")) continue;
        if (std.mem.eql(u8, tag, "embedded_fonts")) continue;

        // Re-emit this element by printing from source
        // We need to reconstruct from the AST
        try w.writeAll("\t\t");
        try writeNode(w, child, 2);
        try w.writeAll("\n");
    }

    // Pads with net assignment
    for (children[2..]) |child| {
        if (!child.isForm("pad")) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 5) continue;

        const pad_name = cl[1].asAtom() orelse cl[1].asString() orelse continue;
        const pad_type = cl[2].asAtom() orelse continue; // smd, thru_hole, etc.
        const pad_shape = cl[3].asAtom() orelse continue; // roundrect, circle, etc.

        try w.print("\t\t(pad \"{s}\" {s} {s}\n", .{ pad_name, pad_type, pad_shape });

        // Copy pad sub-elements (at, size, layers, roundrect_rratio, etc.)
        for (cl[4..]) |sub| {
            const sl = sub.asList() orelse continue;
            if (sl.len == 0) continue;
            const stag = sl[0].asAtom() orelse continue;

            // Skip net/uuid — we add our own
            if (std.mem.eql(u8, stag, "net")) continue;
            if (std.mem.eql(u8, stag, "uuid")) continue;

            try w.writeAll("\t\t\t");
            try writeNode(w, sub, 3);
            try w.writeAll("\n");
        }

        // Add net assignment
        const net_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ inst.ref_des, pad_name });
        defer allocator.free(net_key);
        if (pin_net_map.get(net_key)) |net_idx| {
            if (net_idx > 0 and net_idx <= nets.items.len) {
                try w.print("\t\t\t(net {d} \"{s}\")\n", .{ net_idx, nets.items[net_idx - 1].name });
            }
        }

        // Pad UUID
        try w.print("\t\t\t(uuid \"{s}\")\n", .{try generateSubUuid(allocator, fp_uuid, pad_name)});
        try w.writeAll("\t\t)\n");
    }

    // Handle NC pads (pads in footprint not connected to any net)
    _ = fp_pad_map;

    // Model reference
    for (children[2..]) |child| {
        if (child.isForm("model")) {
            try w.writeAll("\t\t");
            try writeNode(w, child, 2);
            try w.writeAll("\n");
            break;
        }
    }

    try w.writeAll("\t\t(embedded_fonts no)\n");
    try w.writeAll("\t)\n");
}

/// Write a property element.
fn writeProperty(w: anytype, name: []const u8, value: []const u8, layer_name: []const u8, hidden: bool) !void {
    try w.print("\t\t(property \"{s}\" \"{s}\"\n", .{ name, value });
    try w.writeAll("\t\t\t(at 0 0 0)\n");
    try w.print("\t\t\t(layer \"{s}\")\n", .{layer_name});
    if (hidden) {
        try w.writeAll("\t\t\t(hide yes)\n");
    }
    try w.writeAll("\t\t\t(effects\n\t\t\t\t(font\n\t\t\t\t\t(size 1.27 1.27)\n\t\t\t\t\t(thickness 0.15)\n\t\t\t\t)\n\t\t\t)\n");
    try w.writeAll("\t\t)\n");
}

/// Recursively write an AST node as S-expression text.
fn writeNode(w: anytype, node: anytype, depth: u32) !void {
    switch (node.tag) {
        .atom => |a| try w.writeAll(a),
        .string => |s| try w.print("\"{s}\"", .{s}),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| {
            const int_val: i64 = @intFromFloat(f);
            if (@as(f64, @floatFromInt(int_val)) == f) {
                try w.print("{d}", .{int_val});
            } else {
                try w.print("{d:.6}", .{f});
            }
        },
        .unit_val => |u| {
            const int_val: i64 = @intFromFloat(u);
            if (@as(f64, @floatFromInt(int_val)) == u) {
                try w.print("{d}", .{int_val});
            } else {
                try w.print("{d:.6}", .{u});
            }
        },
        .list => |list| {
            try w.writeAll("(");
            for (list, 0..) |child, ci| {
                if (ci > 0) {
                    if (child.asList() != null) {
                        try w.writeAll("\n");
                        var d: u32 = 0;
                        while (d < depth + 1) : (d += 1) {
                            try w.writeAll("\t");
                        }
                    } else {
                        try w.writeAll(" ");
                    }
                }
                try writeNode(w, child, depth + 1);
            }
            try w.writeAll(")");
        },
    }
}

/// Generate a deterministic sub-UUID for pad elements within a footprint.
fn generateSubUuid(allocator: std.mem.Allocator, parent_uuid: []const u8, suffix: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("pad:");
    hasher.update(parent_uuid);
    hasher.update(":");
    hasher.update(suffix);
    const hash = hasher.finalResult();
    var bytes: [16]u8 = undefined;
    @memcpy(&bytes, hash[0..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        bytes[0],  bytes[1],  bytes[2],  bytes[3],
        bytes[4],  bytes[5],  bytes[6],  bytes[7],
        bytes[8],  bytes[9],  bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15],
    });
}

/// Write the standard 2-layer KiCad layer definitions.
fn writeLayerDefs(w: anytype, copper_layers: u8) !void {
    try w.writeAll("\t(layers\n");
    try w.writeAll("\t\t(0 \"F.Cu\" signal)\n");
    // Inner copper layers for 4+ layer boards
    if (copper_layers >= 4) {
        try w.writeAll("\t\t(4 \"In1.Cu\" signal)\n");
        try w.writeAll("\t\t(6 \"In2.Cu\" signal)\n");
    }
    if (copper_layers >= 6) {
        try w.writeAll("\t\t(8 \"In3.Cu\" signal)\n");
        try w.writeAll("\t\t(10 \"In4.Cu\" signal)\n");
    }
    try w.writeAll("\t\t(2 \"B.Cu\" signal)\n");
    try w.writeAll("\t\t(9 \"F.Adhes\" user \"F.Adhesive\")\n");
    try w.writeAll("\t\t(11 \"B.Adhes\" user \"B.Adhesive\")\n");
    try w.writeAll("\t\t(13 \"F.Paste\" user)\n");
    try w.writeAll("\t\t(15 \"B.Paste\" user)\n");
    try w.writeAll("\t\t(5 \"F.SilkS\" user \"F.Silkscreen\")\n");
    try w.writeAll("\t\t(7 \"B.SilkS\" user \"B.Silkscreen\")\n");
    try w.writeAll("\t\t(1 \"F.Mask\" user)\n");
    try w.writeAll("\t\t(3 \"B.Mask\" user)\n");
    try w.writeAll("\t\t(17 \"Dwgs.User\" user \"User.Drawings\")\n");
    try w.writeAll("\t\t(19 \"Cmts.User\" user \"User.Comments\")\n");
    try w.writeAll("\t\t(21 \"Eco1.User\" user \"User.Eco1\")\n");
    try w.writeAll("\t\t(23 \"Eco2.User\" user \"User.Eco2\")\n");
    try w.writeAll("\t\t(25 \"Edge.Cuts\" user)\n");
    try w.writeAll("\t\t(27 \"Margin\" user)\n");
    try w.writeAll("\t\t(31 \"F.CrtYd\" user \"F.Courtyard\")\n");
    try w.writeAll("\t\t(29 \"B.CrtYd\" user \"B.Courtyard\")\n");
    try w.writeAll("\t\t(35 \"F.Fab\" user)\n");
    try w.writeAll("\t\t(33 \"B.Fab\" user)\n");
    try w.writeAll("\t\t(39 \"User.1\" user)\n");
    try w.writeAll("\t\t(41 \"User.2\" user)\n");
    try w.writeAll("\t\t(43 \"User.3\" user)\n");
    try w.writeAll("\t\t(45 \"User.4\" user)\n");
    try w.writeAll("\t)\n");
}

/// Write the standard KiCad setup block.
fn writeSetup(w: anytype, board_def: ?*const env_mod.Board) !void {
    _ = board_def; // Rules will be used in future for DRC defaults
    try w.writeAll("\t(setup\n");
    try w.writeAll("\t\t(pad_to_mask_clearance 0)\n");
    try w.writeAll("\t\t(allow_soldermask_bridges_in_footprints no)\n");
    try w.writeAll("\t\t(tenting front back)\n");
    try w.writeAll("\t\t(pcbplotparams\n");
    try w.writeAll("\t\t\t(layerselection 0x00000000_00000000_55555555_5755f5ff)\n");
    try w.writeAll("\t\t\t(plot_on_all_layers_selection 0x00000000_00000000_00000000_00000000)\n");
    try w.writeAll("\t\t\t(disableapertmacros no)\n");
    try w.writeAll("\t\t\t(usegerberextensions no)\n");
    try w.writeAll("\t\t\t(usegerberattributes yes)\n");
    try w.writeAll("\t\t\t(usegerberadvancedattributes yes)\n");
    try w.writeAll("\t\t\t(creategerberjobfile yes)\n");
    try w.writeAll("\t\t\t(dashed_line_dash_ratio 12.000000)\n");
    try w.writeAll("\t\t\t(dashed_line_gap_ratio 3.000000)\n");
    try w.writeAll("\t\t\t(svgprecision 4)\n");
    try w.writeAll("\t\t\t(plotframeref no)\n");
    try w.writeAll("\t\t\t(mode 1)\n");
    try w.writeAll("\t\t\t(useauxorigin no)\n");
    try w.writeAll("\t\t\t(hpglpennumber 1)\n");
    try w.writeAll("\t\t\t(hpglpenspeed 20)\n");
    try w.writeAll("\t\t\t(hpglpendiameter 15.000000)\n");
    try w.writeAll("\t\t\t(pdf_front_fp_property_popups yes)\n");
    try w.writeAll("\t\t\t(pdf_back_fp_property_popups yes)\n");
    try w.writeAll("\t\t\t(pdf_metadata yes)\n");
    try w.writeAll("\t\t\t(pdf_single_document no)\n");
    try w.writeAll("\t\t\t(dxfpolygonmode yes)\n");
    try w.writeAll("\t\t\t(dxfimperialunits yes)\n");
    try w.writeAll("\t\t\t(dxfusepcbnewfont yes)\n");
    try w.writeAll("\t\t\t(psnegative no)\n");
    try w.writeAll("\t\t\t(psa4output no)\n");
    try w.writeAll("\t\t\t(plot_black_and_white yes)\n");
    try w.writeAll("\t\t\t(sketchpadsonfab no)\n");
    try w.writeAll("\t\t\t(plotpadnumbers no)\n");
    try w.writeAll("\t\t\t(hidednponfab no)\n");
    try w.writeAll("\t\t\t(sketchdnponfab yes)\n");
    try w.writeAll("\t\t\t(crossoutdnponfab yes)\n");
    try w.writeAll("\t\t\t(subtractmaskfromsilk no)\n");
    try w.writeAll("\t\t\t(outputformat 1)\n");
    try w.writeAll("\t\t\t(mirror no)\n");
    try w.writeAll("\t\t\t(drillshape 1)\n");
    try w.writeAll("\t\t\t(scaleselection 1)\n");
    try w.writeAll("\t\t\t(outputdirectory \"\")\n");
    try w.writeAll("\t\t)\n");
    try w.writeAll("\t)\n");
}

/// Write board outline as line segments on Edge.Cuts layer.
fn writeOutline(w: anytype, points: []const [2]f64) !void {
    for (points, 0..) |pt, i| {
        const next = points[(i + 1) % points.len];
        try w.print("\t(gr_line\n\t\t(start {d:.6} {d:.6})\n\t\t(end {d:.6} {d:.6})\n", .{ pt[0], pt[1], next[0], next[1] });
        try w.writeAll("\t\t(stroke\n\t\t\t(width 0.05)\n\t\t\t(type default)\n\t\t)\n");
        try w.writeAll("\t\t(layer \"Edge.Cuts\")\n\t)\n");
    }
}

/// Parse an existing .kicad_pcb file to extract footprint placements keyed by canopy_uuid.
pub fn parseExistingPlacements(
    allocator: std.mem.Allocator,
    pcb_content: []const u8,
    placed: *std.StringHashMap(PlacedFootprint),
) std.mem.Allocator.Error!void {
    // Simple line-based parser: find footprint blocks, extract canopy_uuid and (at x y angle)
    var i: usize = 0;
    while (i < pcb_content.len) {
        // Find next footprint block — match "(footprint " preceded by whitespace
        const fp_start = findFootprintStart(pcb_content, i) orelse break;

        // Find the end of this footprint block by tracking parens
        var depth: u32 = 0;
        var fp_end: usize = fp_start;
        for (pcb_content[fp_start..], 0..) |c, j| {
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth == 0) {
                    fp_end = fp_start + j + 1;
                    break;
                }
            }
        }

        const fp_block = pcb_content[fp_start..fp_end];

        // Extract canopy_uuid
        const uuid_str = extractFieldValue(fp_block, "canopy_uuid");
        if (uuid_str) |uuid| {
            // Extract position
            var x: f64 = 0;
            var y: f64 = 0;
            var ang: f64 = 0;
            var fp_layer: []const u8 = "F.Cu";

            if (extractAtPosition(fp_block)) |pos| {
                x = pos.x;
                y = pos.y;
                ang = pos.angle;
            }

            if (extractLayerName(fp_block)) |ln| {
                fp_layer = ln;
            }

            try placed.put(allocator.dupe(u8, uuid) catch continue, .{
                .x = x,
                .y = y,
                .angle = ang,
                .layer = fp_layer,
                .flipped = std.mem.eql(u8, fp_layer, "B.Cu"),
            });
        }

        i = fp_end;
    }
}

/// Find the start of a top-level "(footprint " form in PCB content.
fn findFootprintStart(content: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < content.len) {
        const idx = std.mem.indexOf(u8, content[pos..], "(footprint ") orelse return null;
        const abs = pos + idx;
        // Must be preceded by newline+whitespace (top-level footprint, not nested)
        if (abs > 0 and content[abs - 1] != '\n' and content[abs - 1] != '\t' and content[abs - 1] != ' ') {
            pos = abs + 1;
            continue;
        }
        return abs;
    }
    return null;
}

const AtPosition = struct { x: f64, y: f64, angle: f64 };

/// Extract (at X Y [angle]) from a footprint block.
/// Finds the first top-level (at ...) — skips those inside nested forms like (property ...).
fn extractAtPosition(block: []const u8) ?AtPosition {
    // Find "(at " that appears before any "(pad" or "(property" — i.e., the footprint-level one.
    // Strategy: scan for "(at " occurrences, pick the first one at shallow depth (depth <= 1).
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < block.len) : (i += 1) {
        if (block[i] == '(') {
            // Check if this is "(at " at depth 1 (inside the footprint form)
            if (depth == 1 and i + 4 < block.len and std.mem.eql(u8, block[i .. i + 4], "(at ")) {
                const start = i + 4;
                const end_paren = std.mem.indexOf(u8, block[start..], ")") orelse return null;
                const coords = block[start .. start + end_paren];
                return parseCoords(coords);
            }
            depth += 1;
        } else if (block[i] == ')') {
            if (depth > 0) depth -= 1;
        }
    }
    return null;
}

fn parseCoords(coords: []const u8) AtPosition {
    var x: f64 = 0;
    var y: f64 = 0;
    var ang: f64 = 0;

    var iter = std.mem.splitScalar(u8, coords, ' ');
    if (iter.next()) |xs| x = std.fmt.parseFloat(f64, xs) catch 0;
    if (iter.next()) |ys| y = std.fmt.parseFloat(f64, ys) catch 0;
    if (iter.next()) |as_| ang = std.fmt.parseFloat(f64, as_) catch 0;

    return .{ .x = x, .y = y, .angle = ang };
}

/// Extract the layer name from a footprint block (first (layer "...") at depth 1).
fn extractLayerName(block: []const u8) ?[]const u8 {
    var depth: u32 = 0;
    var i: usize = 0;
    while (i < block.len) : (i += 1) {
        if (block[i] == '(') {
            if (depth == 1 and i + 8 < block.len and std.mem.eql(u8, block[i .. i + 8], "(layer \"")) {
                const start = i + 8;
                const end_quote = std.mem.indexOf(u8, block[start..], "\"") orelse return null;
                return block[start .. start + end_quote];
            }
            depth += 1;
        } else if (block[i] == ')') {
            if (depth > 0) depth -= 1;
        }
    }
    return null;
}

/// Extract a property field value from a footprint block.
fn extractFieldValue(block: []const u8, field_name: []const u8) ?[]const u8 {
    // Look for: (property "field_name" "VALUE"
    var search_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "(property \"{s}\" \"", .{field_name}) catch return null;
    const pos = std.mem.indexOf(u8, block, needle) orelse return null;
    const start = pos + needle.len;
    const end = std.mem.indexOf(u8, block[start..], "\"") orelse return null;
    return block[start .. start + end];
}

/// Build a mapping from ref_des to section index for grid placement.
fn buildSectionMap(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    map: *std.StringHashMap(usize),
) std.mem.Allocator.Error!void {
    for (block.sections, 0..) |sec, si| {
        for (sec.instances) |inst| {
            try map.put(inst.ref_des, si);
        }
        for (sec.sub_sections) |sub| {
            for (sub.instances) |inst| {
                try map.put(inst.ref_des, si);
            }
        }
    }
    // Also recurse into sub-blocks
    for (block.sub_blocks) |sb| {
        try buildSectionMap(allocator, sb.block, map);
    }
}

// --- Tests ---

// spec: export_kicad_pcb - Generates a KiCad PCB file from a resolved design
test "pcb header generation" {
    const alloc = std.testing.allocator;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    const w = buf.writer(alloc);

    try w.writeAll("(kicad_pcb\n");
    try writeLayerDefs(w, 2);
    try writeSetup(w, null);
    try w.writeAll(")\n");

    const output = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, output, "(kicad_pcb") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"F.Cu\" signal") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"Edge.Cuts\" user") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pad_to_mask_clearance") != null);
}

// spec: export_kicad_pcb - Extracts footprint placements from existing PCB by canopy_uuid
test "placement extraction" {
    const alloc = std.testing.allocator;
    const pcb = "(kicad_pcb\n (footprint \"R_0402\"\n  (layer \"F.Cu\")\n  (at 10.5 20.3 90)\n  (property \"canopy_uuid\" \"test-uuid-1234\"\n   (at 0 0 0)\n   (layer \"F.SilkS\")\n   (hide yes)\n  )\n )\n)";

    var placed = std.StringHashMap(PlacedFootprint).init(alloc);
    defer {
        var it = placed.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
        }
        placed.deinit();
    }
    try parseExistingPlacements(alloc, pcb, &placed);

    try std.testing.expect(placed.count() == 1);
    const p = placed.get("test-uuid-1234").?;
    try std.testing.expectApproxEqAbs(p.x, 10.5, 0.01);
    try std.testing.expectApproxEqAbs(p.y, 20.3, 0.01);
    try std.testing.expectApproxEqAbs(p.angle, 90.0, 0.01);
}

// spec: export_kicad_pcb - Generates deterministic sub-UUIDs for pad elements
test "sub-uuid generation" {
    const alloc = std.testing.allocator;
    const uuid1 = try generateSubUuid(alloc, "parent-uuid", "1");
    defer alloc.free(uuid1);
    const uuid2 = try generateSubUuid(alloc, "parent-uuid", "2");
    defer alloc.free(uuid2);
    const uuid1b = try generateSubUuid(alloc, "parent-uuid", "1");
    defer alloc.free(uuid1b);

    // Same inputs → same output
    try std.testing.expectEqualStrings(uuid1, uuid1b);
    // Different pad → different UUID
    try std.testing.expect(!std.mem.eql(u8, uuid1, uuid2));
    // UUID format: 8-4-4-4-12
    try std.testing.expect(uuid1.len == 36);
    try std.testing.expect(uuid1[8] == '-');
}
