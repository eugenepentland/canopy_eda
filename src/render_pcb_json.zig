const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const env_mod = @import("eval/env.zig");
const json_writer = @import("json_writer.zig");
const DesignBlock = env_mod.DesignBlock;
const Board = env_mod.Board;
const parser_mod = @import("sexpr/parser.zig");

const export_kicad = @import("export_kicad.zig");
const FlatInstance = export_kicad.FlatInstance;
const FlatNet = export_kicad.FlatNet;
const netlist_mod = @import("export_kicad_netlist.zig");
const collectInstances = netlist_mod.collectInstances;
const collectNets = netlist_mod.collectNets;

const pcb_mod = @import("export_kicad_pcb.zig");
const layout_mod = @import("layout.zig");

/// Error set for the PCB JSON emitter — uses an `ArrayListUnmanaged(u8)` writer
/// so the only failure mode is `OutOfMemory`.
pub const RenderError = std.mem.Allocator.Error;

// ── Layout constants ──────────────────────────────────────────────
const HALF_DIVISOR: f64 = 2.0;
const DEFAULT_COURTYARD_MM: f64 = 2.0;
const COURTYARD_PAD_MM: f64 = 1.0;
const SECTION_GRID_3X3_MAX: usize = 9;
const SECTION_OFFSET_MM: f64 = 20.0;
const SECTION_TOP_MM: f64 = 10.0;
const SECTION_AREA_PAD: f64 = 1.5;
const SECTION_MIN_DIM_MM: f64 = 15.0;
const SECTION_GRID_GAP_MM: f64 = 10.0;
const SECTION_INSET_MM: f64 = 2.0;
const SECTION_ROW_GAP_MM: f64 = 1.0;
const PAD_NODE_MIN_CHILDREN: usize = 5;
const COURTYARD_RECT_MIN_CHILDREN: usize = 5;

// ── Repeated string literals ──────────────────────────────────────
const POINT_JSON_FMT: []const u8 = "[{d:.3},{d:.3}]";

/// Render a PCB design as JSON for the Pixi.js viewer.
///
/// The JSON contains all the data needed to render footprints, pads, nets,
/// ratsnest lines, and board outline. Coordinates are in mm.
pub fn renderPcbJson(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    design_name: []const u8,
    board_def: ?*const Board,
    existing_pcb_path: ?[]const u8,
    layout_path: ?[]const u8,
) RenderError![]const u8 {
    // Flatten hierarchy
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    var nets: std.ArrayListUnmanaged(FlatNet) = .empty;
    defer nets.deinit(allocator);

    try collectInstances(allocator, block, "", &instances);
    try collectNets(allocator, block, "", &nets);

    // Build pin→net lookup
    var pin_net_map = std.StringHashMap(usize).init(allocator);
    defer pin_net_map.deinit();
    for (nets.items, 0..) |net, ni| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ pin.ref_des, pin.pin });
            try pin_net_map.put(key, ni);
        }
    }

    // Build canonical net group map: nets sharing a base name get the same group ID.
    // "VDD", "VDD.U3.F7", "VDD.U8.VDD_1" all → same group.
    // Sub-block nets like "buck/VIN" → group of the parent net they're tied to.
    var net_group = try allocator.alloc(usize, nets.items.len);
    for (0..nets.items.len) |i| net_group[i] = i; // initial: each net is its own group
    // Union-find helpers
    const uf_find = struct {
        fn f(p: []usize, x: usize) usize {
            var cur = x;
            while (p[cur] != cur) {
                p[cur] = p[p[cur]];
                cur = p[cur];
            }
            return cur;
        }
    }.f;
    const uf_union = struct {
        fn f(p: []usize, a: usize, b: usize) void {
            const ra = @This().root(p, a);
            const rb = @This().root(p, b);
            if (ra != rb) p[ra] = rb;
        }
        fn root(p: []usize, x: usize) usize {
            var cur = x;
            while (p[cur] != cur) {
                p[cur] = p[p[cur]];
                cur = p[cur];
            }
            return cur;
        }
    }.f;
    // Merge nets with same base name (strip dot suffix)
    {
        var base_to_idx = std.StringHashMap(usize).init(allocator);
        defer base_to_idx.deinit();
        for (nets.items, 0..) |net, ni| {
            const base = if (std.mem.indexOfScalar(u8, net.name, '.')) |dot| net.name[0..dot] else net.name;
            if (base_to_idx.get(base)) |existing| {
                uf_union(net_group, ni, existing);
            } else {
                try base_to_idx.put(base, ni);
            }
        }
    }
    // Also merge nets connected by net_ties (sub-block port wiring)
    for (block.net_ties) |nt| {
        // Find net indices for both sides
        var idx_a: ?usize = null;
        var idx_b: ?usize = null;
        for (nets.items, 0..) |net, ni| {
            if (std.mem.eql(u8, net.name, nt.a)) idx_a = ni;
            if (std.mem.eql(u8, net.name, nt.b)) idx_b = ni;
        }
        // Also try base name matching for hierarchical nets
        if (idx_a == null or idx_b == null) {
            const base_a = if (std.mem.indexOfScalar(u8, nt.a, '.')) |d| nt.a[0..d] else nt.a;
            const base_b = if (std.mem.indexOfScalar(u8, nt.b, '.')) |d| nt.b[0..d] else nt.b;
            for (nets.items, 0..) |net, ni| {
                const net_base = if (std.mem.indexOfScalar(u8, net.name, '.')) |d| net.name[0..d] else net.name;
                if (idx_a == null and std.mem.eql(u8, net_base, base_a)) idx_a = ni;
                if (idx_b == null and std.mem.eql(u8, net_base, base_b)) idx_b = ni;
            }
        }
        if (idx_a != null and idx_b != null) {
            uf_union(net_group, idx_a.?, idx_b.?);
        }
    }
    // Flatten groups to canonical IDs
    for (0..nets.items.len) |i| {
        net_group[i] = uf_find(net_group, i);
    }
    // Build net_name → group_id lookup for traces/vias
    var net_name_to_group = std.StringHashMap(usize).init(allocator);
    defer net_name_to_group.deinit();
    for (nets.items, 0..) |net, ni| {
        try net_name_to_group.put(net.name, net_group[ni]);
        // Also register base name
        const base = if (std.mem.indexOfScalar(u8, net.name, '.')) |dot| net.name[0..dot] else net.name;
        if (!net_name_to_group.contains(base)) {
            try net_name_to_group.put(base, net_group[ni]);
        }
    }

    // Load placements: try .layout first, fall back to .kicad_pcb
    var placed = std.StringHashMap(pcb_mod.PlacedFootprint).init(allocator);
    defer placed.deinit();
    var loaded_from_layout = false;
    var layout_traces: []const layout_mod.Trace = &.{};
    var layout_vias: []const layout_mod.Via = &.{};
    var layout_zone_fills: []const layout_mod.ZoneFill = &.{};
    var layout_rules: ?layout_mod.Rules = null;
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
            layout_rules = layout.rules;
            loaded_from_layout = true;
        } else |_| {}
    }
    if (!loaded_from_layout) {
        if (existing_pcb_path) |pcb_path| {
            const existing = infra_fs.cwd().readFileAlloc(allocator, pcb_path, 100 * 1024 * 1024) catch null;
            if (existing) |pcb_content| {
                try pcb_mod.parseExistingPlacements(allocator, pcb_content, &placed);
            }
        }
    }

    // Parse footprint geometry (cached by footprint name)
    var fp_geo_cache = std.StringHashMap(FootprintGeometry).init(allocator);
    defer fp_geo_cache.deinit();
    var processed = std.StringHashMap(void).init(allocator);
    defer processed.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (processed.contains(inst.footprint)) continue;
        try processed.put(inst.footprint, {});

        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);
        const fp_source = infra_fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
        const geo = parseFootprintGeometry(allocator, fp_source) catch continue;
        try fp_geo_cache.put(inst.footprint, geo);
    }

    // Build JSON output
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("{");

    // Design name
    try w.print("\"name\":\"{s}\",", .{design_name});

    // Board outline
    try w.writeAll("\"board\":{");
    if (board_def) |b| {
        try w.print("\"thickness\":{d:.1},\"copper_layers\":{d},\"outline\":[", .{ b.thickness, b.copper_layers });
        for (b.outline, 0..) |pt, i| {
            if (i > 0) try w.writeAll(",");
            try w.print(POINT_JSON_FMT, .{ pt[0], pt[1] });
        }
        try w.writeAll("]");
    } else {
        try w.writeAll("\"thickness\":1.6,\"copper_layers\":2,\"outline\":[]");
    }
    try w.writeAll("},");

    // Nets
    try w.writeAll("\"nets\":[");
    for (nets.items, 0..) |net, ni| {
        if (ni > 0) try w.writeAll(",");
        try w.print("{{\"id\":{d},\"name\":\"{s}\"}}", .{ ni, net.name });
    }
    try w.writeAll("],");

    // Auto-place unplaced components into section boxes
    // Build ref_des→section_index map
    var ref_to_section = std.StringHashMap(usize).init(allocator);
    defer ref_to_section.deinit();
    var section_names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer section_names.deinit(allocator);

    for (block.sections, 0..) |sec, si| {
        try section_names.append(allocator, sec.name);
        for (sec.instances) |inst| {
            try ref_to_section.put(inst.ref_des, si);
        }
    }
    for (block.sub_blocks, 0..) |sb, sbi| {
        const idx = block.sections.len + sbi;
        try section_names.append(allocator, sb.block.name);
        for (sb.block.instances) |inst| {
            const full_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, inst.ref_des });
            try ref_to_section.put(full_ref, idx);
        }
        for (sb.block.sections) |sec| {
            for (sec.instances) |inst| {
                const full_ref = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, inst.ref_des });
                try ref_to_section.put(full_ref, idx);
            }
        }
    }

    const num_sections = section_names.items.len;

    // Compute section sizes from ALL components (for box sizing and reset button)
    const SectionInfo = struct { count: usize, total_area: f64, unplaced: usize };
    var sec_info = try allocator.alloc(SectionInfo, num_sections + 1); // +1 for "unsectioned"
    for (sec_info) |*s| s.* = .{ .count = 0, .total_area = 0, .unplaced = 0 };

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        const geo = fp_geo_cache.get(inst.footprint) orelse continue;
        const sec_idx = ref_to_section.get(inst.ref_des) orelse num_sections;
        var cw: f64 = DEFAULT_COURTYARD_MM;
        var ch: f64 = DEFAULT_COURTYARD_MM;
        if (geo.courtyard) |c| {
            cw = c.x2 - c.x1 + COURTYARD_PAD_MM;
            ch = c.y2 - c.y1 + COURTYARD_PAD_MM;
        }
        sec_info[sec_idx].count += 1;
        sec_info[sec_idx].total_area += cw * ch;
        if (inst.uuid.len == 0 or !placed.contains(inst.uuid)) {
            sec_info[sec_idx].unplaced += 1;
        }
    }

    // Compute section box sizes (square-ish based on area, with padding)
    const grid_cols: usize = blk: {
        var active: usize = 0;
        for (sec_info) |s| {
            if (s.count > 0) active += 1;
        }
        if (active <= 1) break :blk 1;
        if (active <= 4) break :blk 2;
        if (active <= SECTION_GRID_3X3_MAX) break :blk 3;
        break :blk 4;
    };

    // Board outline bounds for placing sections outside
    var board_max_x: f64 = 0;
    var board_max_y: f64 = 0;
    if (board_def) |b| {
        for (b.outline) |pt| {
            if (pt[0] > board_max_x) board_max_x = pt[0];
            if (pt[1] > board_max_y) board_max_y = pt[1];
        }
    }
    const section_start_x: f64 = board_max_x + SECTION_OFFSET_MM;
    const section_start_y: f64 = SECTION_TOP_MM;

    // Compute section box dimensions and positions in a grid
    const BoxInfo = struct { x: f64, y: f64, w: f64, h: f64 };
    var sec_boxes = try allocator.alloc(BoxInfo, num_sections + 1);
    var grid_row: usize = 0;
    var grid_col: usize = 0;
    var row_height: f64 = 0;
    var cur_x: f64 = section_start_x;
    var cur_y: f64 = section_start_y;

    for (sec_info, 0..) |s, si| {
        if (s.count == 0) {
            sec_boxes[si] = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            continue;
        }
        // Box size: sqrt of total area * 1.5 for padding
        const side = @sqrt(s.total_area) * SECTION_AREA_PAD;
        const box_w = @max(side, SECTION_MIN_DIM_MM);
        const box_h = @max(side, SECTION_MIN_DIM_MM);

        sec_boxes[si] = .{ .x = cur_x, .y = cur_y, .w = box_w, .h = box_h };
        if (box_h > row_height) row_height = box_h;

        grid_col += 1;
        cur_x += box_w + SECTION_GRID_GAP_MM;
        if (grid_col >= grid_cols) {
            grid_col = 0;
            grid_row += 1;
            cur_x = section_start_x;
            cur_y += row_height + SECTION_GRID_GAP_MM;
            row_height = 0;
        }
    }

    // Place unplaced components into their section boxes (row packing)
    var sec_cursor_x = try allocator.alloc(f64, num_sections + 1);
    var sec_cursor_y = try allocator.alloc(f64, num_sections + 1);
    var sec_row_h = try allocator.alloc(f64, num_sections + 1);
    for (0..num_sections + 1) |i| {
        sec_cursor_x[i] = sec_boxes[i].x + SECTION_INSET_MM;
        sec_cursor_y[i] = sec_boxes[i].y + SECTION_INSET_MM;
        sec_row_h[i] = 0;
    }

    // Pre-compute auto positions for unplaced components
    var auto_placed = std.StringHashMap(pcb_mod.PlacedFootprint).init(allocator);
    defer auto_placed.deinit();

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (inst.uuid.len > 0 and placed.contains(inst.uuid)) continue;
        const geo = fp_geo_cache.get(inst.footprint) orelse continue;
        const sec_idx = ref_to_section.get(inst.ref_des) orelse num_sections;
        const box = sec_boxes[sec_idx];
        if (box.w == 0) continue;

        var cw: f64 = DEFAULT_COURTYARD_MM;
        var ch: f64 = DEFAULT_COURTYARD_MM;
        if (geo.courtyard) |c| {
            cw = c.x2 - c.x1 + COURTYARD_PAD_MM;
            ch = c.y2 - c.y1 + COURTYARD_PAD_MM;
        }

        // Wrap to next row if needed
        if (sec_cursor_x[sec_idx] + cw > box.x + box.w) {
            sec_cursor_x[sec_idx] = box.x + SECTION_INSET_MM;
            sec_cursor_y[sec_idx] += sec_row_h[sec_idx] + SECTION_ROW_GAP_MM;
            sec_row_h[sec_idx] = 0;
        }

        const px = sec_cursor_x[sec_idx] + cw / HALF_DIVISOR;
        const py = sec_cursor_y[sec_idx] + ch / HALF_DIVISOR;
        try auto_placed.put(inst.uuid, .{ .x = px, .y = py, .angle = 0, .layer = "F.Cu", .flipped = false });

        sec_cursor_x[sec_idx] += cw;
        if (ch > sec_row_h[sec_idx]) sec_row_h[sec_idx] = ch;
    }

    // Footprints with geometry, position, and pad-net assignments
    try w.writeAll("\"footprints\":[");
    var first_fp = true;
    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        const geo = fp_geo_cache.get(inst.footprint) orelse continue;

        if (!first_fp) try w.writeAll(",");
        first_fp = false;

        // Position from layout/pcb, then auto-placement, then origin
        var pos_x: f64 = 0;
        var pos_y: f64 = 0;
        var angle: f64 = 0;
        var layer: []const u8 = "F.Cu";
        if (inst.uuid.len > 0) {
            if (placed.get(inst.uuid)) |p| {
                pos_x = p.x;
                pos_y = p.y;
                angle = p.angle;
                layer = p.layer;
            } else if (auto_placed.get(inst.uuid)) |p| {
                pos_x = p.x;
                pos_y = p.y;
            }
        }

        try w.writeAll("{");
        try w.print("\"ref\":\"{s}\",\"component\":\"{s}\",\"value\":\"{s}\",\"footprint\":\"{s}\"", .{ inst.ref_des, inst.component, inst.value, inst.footprint });
        try w.print(",\"uuid\":\"{s}\"", .{inst.uuid});
        try w.print(",\"x\":{d:.3},\"y\":{d:.3},\"angle\":{d:.1},\"layer\":\"{s}\"", .{ pos_x, pos_y, angle, layer });

        // Pads
        try w.writeAll(",\"pads\":[");
        for (geo.pads, 0..) |pad, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("{");
            try writeJsonString(w, "name", pad.name);
            try w.print(",\"type\":\"{s}\",\"shape\":\"{s}\"", .{ pad.pad_type, pad.shape });
            try w.print(",\"x\":{d:.3},\"y\":{d:.3},\"w\":{d:.3},\"h\":{d:.3}", .{ pad.x, pad.y, pad.w, pad.h });

            // Net assignment
            const net_key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ inst.ref_des, pad.name });
            defer allocator.free(net_key);
            if (pin_net_map.get(net_key)) |net_idx| {
                try w.print(",\"net_id\":{d},\"net_name\":\"{s}\",\"ng\":{d}", .{ net_idx, nets.items[net_idx].name, net_group[net_idx] });
            }
            // Omit net fields for unconnected pads — client treats missing as unconnected
            try w.writeAll("}");
        }
        try w.writeAll("]");

        // Courtyard
        if (geo.courtyard) |c| {
            try w.print(",\"courtyard\":{{\"x1\":{d:.3},\"y1\":{d:.3},\"x2\":{d:.3},\"y2\":{d:.3}}}", .{ c.x1, c.y1, c.x2, c.y2 });
        }
        // Omit courtyard key when null — client checks for field existence

        // Silkscreen lines
        try w.writeAll(",\"silk_lines\":[");
        for (geo.silk_lines, 0..) |line, li| {
            if (li > 0) try w.writeAll(",");
            try w.print("[{d:.3},{d:.3},{d:.3},{d:.3}]", .{ line.x1, line.y1, line.x2, line.y2 });
        }
        try w.writeAll("]");

        try w.writeAll("}");
    }
    try w.writeAll("],");

    // Ratsnest: for each net, list the pads and their absolute positions
    try w.writeAll("\"ratsnest\":[");
    var first_net = true;
    for (nets.items, 0..) |net, ni| {
        if (net.pins.len < 2) continue;
        if (!first_net) try w.writeAll(",");
        first_net = false;
        try w.print("{{\"id\":{d},\"name\":\"{s}\",\"ng\":{d},\"pins\":[", .{ ni, net.name, net_group[ni] });
        for (net.pins, 0..) |pin, pni| {
            if (pni > 0) try w.writeAll(",");
            try w.print("[\"{s}\",\"{s}\"]", .{ pin.ref_des, pin.pin });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("],");

    // Sections: map section names to component ref_des lists + box geometry
    try w.writeAll("\"sections\":[");
    var first_sec = true;
    var sec_json_idx: usize = 0;
    for (block.sections) |sec| {
        if (!first_sec) try w.writeAll(",");
        first_sec = false;
        const box = sec_boxes[sec_json_idx];
        try w.print("{{\"name\":\"{s}\",\"box\":{{\"x\":{d:.2},\"y\":{d:.2},\"w\":{d:.2},\"h\":{d:.2}}},\"refs\":[", .{ sec.name, box.x, box.y, box.w, box.h });
        for (sec.instances, 0..) |inst, ii| {
            if (ii > 0) try w.writeAll(",");
            try w.print("\"{s}\"", .{inst.ref_des});
        }
        try w.writeAll("]}");
        sec_json_idx += 1;
    }
    for (block.sub_blocks) |sb| {
        if (!first_sec) try w.writeAll(",");
        first_sec = false;
        const box = sec_boxes[sec_json_idx];
        try w.print("{{\"name\":\"{s}\",\"box\":{{\"x\":{d:.2},\"y\":{d:.2},\"w\":{d:.2},\"h\":{d:.2}}},\"refs\":[", .{ sb.block.name, box.x, box.y, box.w, box.h });
        for (sb.block.instances, 0..) |inst, ii| {
            if (ii > 0) try w.writeAll(",");
            try w.print("\"{s}/{s}\"", .{ sb.name, inst.ref_des });
        }
        for (sb.block.sections) |sec| {
            for (sec.instances) |inst| {
                try w.writeAll(",");
                try w.print("\"{s}/{s}\"", .{ sb.name, inst.ref_des });
            }
        }
        try w.writeAll("]}");
        sec_json_idx += 1;
    }
    try w.writeAll("]");

    // Traces
    try w.writeAll(",\"traces\":[");
    for (layout_traces, 0..) |t, ti| {
        if (ti > 0) try w.writeAll(",");
        const t_ng: i64 = if (net_name_to_group.get(t.net)) |g| @intCast(g) else -1;
        try w.print("{{\"net\":\"{s}\",\"ng\":{d},\"layer\":\"{s}\",\"width\":{d:.3},\"points\":[", .{ t.net, t_ng, t.layer, t.width });
        for (t.points, 0..) |pt, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.print(POINT_JSON_FMT, .{ pt[0], pt[1] });
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    // Vias
    try w.writeAll(",\"vias\":[");
    for (layout_vias, 0..) |v, vi| {
        if (vi > 0) try w.writeAll(",");
        const v_ng: i64 = if (net_name_to_group.get(v.net)) |g| @intCast(g) else -1;
        try w.print("{{\"x\":{d:.3},\"y\":{d:.3},\"net\":\"{s}\",\"ng\":{d},\"drill\":{d:.3},\"pad_size\":{d:.3},\"from\":\"{s}\",\"to\":\"{s}\"}}", .{
            v.x, v.y, v.net, v_ng, v.drill, v.pad_size, v.layer_from, v.layer_to,
        });
    }
    try w.writeAll("]");

    // Zone fills
    try w.writeAll(",\"zone_fills\":[");
    for (layout_zone_fills, 0..) |z, zi| {
        if (zi > 0) try w.writeAll(",");
        try w.print("{{\"net\":\"{s}\",\"layer\":\"{s}\",\"polygons\":[", .{ z.zone_name, z.layer });
        for (z.polygons, 0..) |poly, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("[");
            for (poly, 0..) |pt, pti| {
                if (pti > 0) try w.writeAll(",");
                try w.print(POINT_JSON_FMT, .{ pt[0], pt[1] });
            }
            try w.writeAll("]");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]");

    // Board rules — layout overrides board defaults
    if (layout_rules) |lr| {
        try w.print(",\"rules\":{{\"clearance\":{d:.3},\"track_width\":{d:.3},\"via_drill\":{d:.3},\"via_size\":{d:.3}}}", .{
            lr.clearance, lr.track_width, lr.via_drill, lr.via_size,
        });
    } else if (board_def) |bd| {
        try w.print(",\"rules\":{{\"clearance\":{d:.3},\"track_width\":{d:.3},\"via_drill\":{d:.3},\"via_size\":{d:.3}}}", .{
            bd.rules.clearance, bd.rules.track_width, bd.rules.via_drill, bd.rules.via_size,
        });
    }
    if (board_def) |bd| {
        // Net classes
        try w.writeAll(",\"net_classes\":[");
        for (bd.net_classes, 0..) |nc, nci| {
            if (nci > 0) try w.writeAll(",");
            try w.print("{{\"name\":\"{s}\"", .{nc.name});
            if (nc.track_width) |tw| try w.print(",\"track_width\":{d:.3}", .{tw});
            if (nc.clearance) |cl| try w.print(",\"clearance\":{d:.3}", .{cl});
            if (nc.via_drill) |vd| try w.print(",\"via_drill\":{d:.3}", .{vd});
            if (nc.via_size) |vs| try w.print(",\"via_size\":{d:.3}", .{vs});
            try w.writeAll(",\"nets\":[");
            for (nc.nets, 0..) |net_name, ni| {
                if (ni > 0) try w.writeAll(",");
                try w.print("\"{s}\"", .{net_name});
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]");

        // Zone definitions
        try w.writeAll(",\"zones\":[");
        for (bd.zones, 0..) |zd, zdi| {
            if (zdi > 0) try w.writeAll(",");
            try w.print("{{\"net\":\"{s}\",\"layer\":\"{s}\",\"thermal_gap\":{d:.3},\"thermal_width\":{d:.3}}}", .{
                zd.name, zd.layer, zd.thermal_gap, zd.thermal_width,
            });
        }
        try w.writeAll("]");

        // Keepouts
        try w.writeAll(",\"keepouts\":[");
        for (bd.keepouts, 0..) |ko, koi| {
            if (koi > 0) try w.writeAll(",");
            try w.print("{{\"name\":\"{s}\",\"no_tracks\":{},\"no_vias\":{},\"no_pours\":{},\"outline\":[", .{
                ko.name, ko.no_tracks, ko.no_vias, ko.no_pours,
            });
            for (ko.outline, 0..) |pt, pti| {
                if (pti > 0) try w.writeAll(",");
                try w.print(POINT_JSON_FMT, .{ pt[0], pt[1] });
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]");
    }

    try w.writeAll("}");

    return buf.toOwnedSlice(allocator);
}

const writeJsonString = json_writer.writeField;

// --- Footprint Geometry Parsing ---

const PadInfo = struct {
    name: []const u8,
    pad_type: []const u8, // smd, thru_hole
    shape: []const u8, // roundrect, circle, rect, oval
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

const Line = struct { x1: f64, y1: f64, x2: f64, y2: f64 };
const Rect = struct { x1: f64, y1: f64, x2: f64, y2: f64 };

const FootprintGeometry = struct {
    pads: []const PadInfo,
    courtyard: ?Rect,
    silk_lines: []const Line,
};

fn parseFootprintGeometry(allocator: std.mem.Allocator, source: []const u8) !FootprintGeometry {
    const nodes = try parser_mod.parse(allocator, source);
    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];
    if (!root.isForm("footprint")) return error.InvalidFormat;
    const children = root.asList() orelse return error.InvalidFormat;

    var pads: std.ArrayListUnmanaged(PadInfo) = .empty;
    var silk_lines: std.ArrayListUnmanaged(Line) = .empty;
    var courtyard: ?Rect = null;

    for (children[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len == 0) continue;
        const tag = cl[0].asAtom() orelse continue;

        if (std.mem.eql(u8, tag, "pad")) {
            if (cl.len < PAD_NODE_MIN_CHILDREN) continue;
            const name = cl[1].asAtom() orelse cl[1].asString() orelse if (cl[1].asNumber()) |n| try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(n))}) else continue;
            const pad_type = cl[2].asAtom() orelse continue;
            const shape = cl[3].asAtom() orelse continue;

            var px: f64 = 0;
            var py: f64 = 0;
            var pw: f64 = 0;
            var ph: f64 = 0;

            for (cl[4..]) |sub| {
                const sl = sub.asList() orelse continue;
                if (sl.len < 3) continue;
                const stag = sl[0].asAtom() orelse continue;
                if (std.mem.eql(u8, stag, "pos")) {
                    px = nodeToFloat(sl[1]);
                    py = nodeToFloat(sl[2]);
                } else if (std.mem.eql(u8, stag, "size")) {
                    pw = nodeToFloat(sl[1]);
                    ph = nodeToFloat(sl[2]);
                }
            }

            try pads.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .pad_type = try allocator.dupe(u8, pad_type),
                .shape = try allocator.dupe(u8, shape),
                .x = px,
                .y = py,
                .w = pw,
                .h = ph,
            });
        } else if (std.mem.eql(u8, tag, "courtyard")) {
            // (courtyard (rect x1 y1 x2 y2))
            for (cl[1..]) |sub| {
                const sl = sub.asList() orelse continue;
                if (sl.len < COURTYARD_RECT_MIN_CHILDREN) continue;
                const stag = sl[0].asAtom() orelse continue;
                if (std.mem.eql(u8, stag, "rect")) {
                    courtyard = .{
                        .x1 = nodeToFloat(sl[1]),
                        .y1 = nodeToFloat(sl[2]),
                        .x2 = nodeToFloat(sl[3]),
                        .y2 = nodeToFloat(sl[4]),
                    };
                }
            }
        } else if (std.mem.eql(u8, tag, "silkscreen")) {
            for (cl[1..]) |sub| {
                const sl = sub.asList() orelse continue;
                if (sl.len < 3) continue;
                const stag = sl[0].asAtom() orelse continue;
                if (std.mem.eql(u8, stag, "line")) {
                    // (line (x1 y1) (x2 y2))
                    const p1 = sl[1].asList() orelse continue;
                    const p2 = sl[2].asList() orelse continue;
                    if (p1.len < 2 or p2.len < 2) continue;
                    try silk_lines.append(allocator, .{
                        .x1 = nodeToFloat(p1[0]),
                        .y1 = nodeToFloat(p1[1]),
                        .x2 = nodeToFloat(p2[0]),
                        .y2 = nodeToFloat(p2[1]),
                    });
                }
            }
        }
    }

    return .{
        .pads = pads.toOwnedSlice(allocator) catch &.{},
        .courtyard = courtyard,
        .silk_lines = silk_lines.toOwnedSlice(allocator) catch &.{},
    };
}

fn nodeToFloat(node: anytype) f64 {
    if (node.asNumber()) |n| return n;
    if (node.asAtom()) |s| return std.fmt.parseFloat(f64, s) catch 0;
    return 0;
}

// --- Tests ---

// spec: render_pcb_json - Parses footprint geometry from sexp source
test "footprint geometry parsing" {
    const alloc = std.testing.allocator;
    const source =
        \\(footprint "R_0402"
        \\  (description "Resistor 0402")
        \\  (pad 1 smd roundrect (pos -0.51 0.00) (size 0.54 0.64))
        \\  (pad 2 smd roundrect (pos 0.51 0.00) (size 0.54 0.64))
        \\  (courtyard (rect -0.93 -0.47 0.93 0.47))
        \\  (silkscreen
        \\    (line (-0.15 -0.38) (0.15 -0.38))
        \\  )
        \\)
    ;

    const geo = try parseFootprintGeometry(alloc, source);
    defer {
        for (geo.pads) |p| {
            alloc.free(p.name);
            alloc.free(p.pad_type);
            alloc.free(p.shape);
        }
        alloc.free(geo.pads);
        alloc.free(geo.silk_lines);
    }

    try std.testing.expectEqual(@as(usize, 2), geo.pads.len);
    try std.testing.expectEqualStrings("1", geo.pads[0].name);
    try std.testing.expectApproxEqAbs(-0.51, geo.pads[0].x, 0.01);
    try std.testing.expectApproxEqAbs(0.54, geo.pads[0].w, 0.01);
    try std.testing.expect(geo.courtyard != null);
    try std.testing.expectApproxEqAbs(-0.93, geo.courtyard.?.x1, 0.01);
    try std.testing.expectEqual(@as(usize, 1), geo.silk_lines.len);
}
