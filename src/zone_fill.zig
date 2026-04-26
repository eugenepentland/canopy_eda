const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const env_mod = @import("eval/env.zig");
const layout_mod = @import("layout.zig");
const netlist_mod = @import("export_kicad_netlist.zig");
const export_kicad = @import("export_kicad.zig");
const FlatInstance = export_kicad.FlatInstance;
const parser_mod = @import("sexpr/parser.zig");

/// Result of a zone fill computation.
pub const ZoneFillResult = struct {
    zone_name: []const u8,
    layer: []const u8,
    polygons: []const []const [2]f64,
};

/// Obstacle for zone fill: a circle at (x,y) with radius r, on a specific net.
/// `layer` is the copper layer the obstacle lives on ("F.Cu", "B.Cu"), or "*" for
/// thru-hole pads and vias which affect every copper layer.
const Obstacle = struct {
    x: f64,
    y: f64,
    r: f64,
    net: []const u8,
    is_thru: bool,
    layer: []const u8,
};

/// Trace segment obstacle.
const TraceSeg = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    hw: f64, // half width
    net: []const u8,
    layer: []const u8,
};

/// Compute zone fills for all zone definitions in a board.
pub fn computeZoneFills(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    board_def: *const env_mod.Board,
    project_dir: []const u8,
    layout: *const layout_mod.Layout,
) ![]const ZoneFillResult {
    var results: std.ArrayListUnmanaged(ZoneFillResult) = .empty;

    // Collect obstacles from component pads
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    try netlist_mod.collectInstances(allocator, block, "", &instances);

    // Build placement map
    var placed = std.StringHashMap(PlacementInfo).init(allocator);
    defer placed.deinit();
    for (layout.placements) |p| {
        try placed.put(p.uuid, .{
            .x = p.x,
            .y = p.y,
            .angle = p.angle,
            .side = p.side,
        });
    }

    // Parse footprint geometry
    var fp_geom = std.StringHashMap([]const PadGeom).init(allocator);
    defer fp_geom.deinit();
    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (fp_geom.contains(inst.footprint)) continue;
        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);
        const source = infra_fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
        const pads = parsePads(allocator, source) catch continue;
        try fp_geom.put(inst.footprint, pads);
    }

    // Collect net names for pin→net lookup
    var nets: std.ArrayListUnmanaged(export_kicad.FlatNet) = .empty;
    defer nets.deinit(allocator);
    try netlist_mod.collectNets(allocator, block, "", &nets);

    var pin_net = std.StringHashMap([]const u8).init(allocator);
    defer pin_net.deinit();
    for (nets.items) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ pin.ref_des, pin.pin });
            try pin_net.put(key, net.name);
        }
    }

    // Build global obstacle list
    var obstacles: std.ArrayListUnmanaged(Obstacle) = .empty;
    defer obstacles.deinit(allocator);
    var trace_segs: std.ArrayListUnmanaged(TraceSeg) = .empty;
    defer trace_segs.deinit(allocator);

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        const pl = placed.get(inst.uuid) orelse continue;
        const pads = fp_geom.get(inst.footprint) orelse continue;

        for (pads) |pad| {
            const pos = transformPad(pad.x, pad.y, pl.angle, pl.x, pl.y);
            const is_thru = std.mem.eql(u8, pad.pad_type, "thru_hole");
            // Look up net for this pad
            const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ inst.ref_des, pad.name });
            const net_name = pin_net.get(key) orelse "";
            const pad_layer: []const u8 = if (is_thru)
                "*"
            else switch (pl.side) {
                .front => "F.Cu",
                .back => "B.Cu",
            };
            try obstacles.append(allocator, .{
                .x = pos[0],
                .y = pos[1],
                .r = @max(pad.w, pad.h) / 2.0,
                .net = net_name,
                .is_thru = is_thru,
                .layer = pad_layer,
            });
        }
    }

    // Via obstacles
    for (layout.vias) |v| {
        try obstacles.append(allocator, .{
            .x = v.x,
            .y = v.y,
            .r = v.pad_size / 2.0,
            .net = v.net,
            .is_thru = true,
            .layer = "*",
        });
    }

    // Trace segments
    for (layout.traces) |t| {
        for (0..t.points.len -| 1) |pi| {
            try trace_segs.append(allocator, .{
                .x1 = t.points[pi][0],
                .y1 = t.points[pi][1],
                .x2 = t.points[pi + 1][0],
                .y2 = t.points[pi + 1][1],
                .hw = t.width / 2.0,
                .net = t.net,
                .layer = t.layer,
            });
        }
    }

    // Process each zone definition
    for (board_def.zones) |zone_def| {
        const boundary = if (board_def.outline.len >= 3) board_def.outline else continue;
        const fill_result = try fillZone(
            allocator,
            zone_def,
            boundary,
            obstacles.items,
            trace_segs.items,
            board_def.rules.clearance,
        );
        try results.append(allocator, fill_result);
    }

    return try results.toOwnedSlice(allocator);
}

// --- Grid-based zone fill ---

const GRID_SIZE: f64 = 0.1; // mm per cell

fn fillZone(
    allocator: std.mem.Allocator,
    zone_def: env_mod.ZoneDef,
    boundary: []const [2]f64,
    obstacles: []const Obstacle,
    trace_segs: []const TraceSeg,
    clearance: f64,
) !ZoneFillResult {
    // Compute bounding box
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    for (boundary) |pt| {
        min_x = @min(min_x, pt[0]);
        min_y = @min(min_y, pt[1]);
        max_x = @max(max_x, pt[0]);
        max_y = @max(max_y, pt[1]);
    }

    // Add margin
    min_x -= 1.0;
    min_y -= 1.0;
    max_x += 1.0;
    max_y += 1.0;

    const cols: usize = @intFromFloat(@ceil((max_x - min_x) / GRID_SIZE));
    const rows: usize = @intFromFloat(@ceil((max_y - min_y) / GRID_SIZE));

    if (cols == 0 or rows == 0 or cols > 10000 or rows > 10000) {
        return .{ .zone_name = zone_def.name, .layer = zone_def.layer, .polygons = &.{} };
    }

    // Allocate grid
    var grid = try allocator.alloc(bool, cols * rows);
    defer allocator.free(grid);
    @memset(grid, false);

    // Step 1: Mark cells inside the boundary polygon
    for (0..rows) |r| {
        for (0..cols) |c| {
            const x = min_x + (@as(f64, @floatFromInt(c)) + 0.5) * GRID_SIZE;
            const y = min_y + (@as(f64, @floatFromInt(r)) + 0.5) * GRID_SIZE;
            if (pointInPolygon(x, y, boundary)) {
                grid[r * cols + c] = true;
            }
        }
    }

    // Step 2: Clear cells near obstacles on different nets
    for (obstacles) |obs| {
        // Skip same-net obstacles (they get thermal relief instead)
        if (baseNetEql(obs.net, zone_def.name)) continue;
        // Skip SMD pads on a different copper layer than this zone. "*" marks
        // thru-hole pads and vias which affect every layer.
        if (!std.mem.eql(u8, obs.layer, "*") and !std.mem.eql(u8, obs.layer, zone_def.layer)) continue;
        const clear_r = obs.r + clearance;
        clearCircle(grid, cols, rows, min_x, min_y, obs.x, obs.y, clear_r);
    }

    // Step 3: Clear cells near trace segments on different nets
    for (trace_segs) |seg| {
        if (baseNetEql(seg.net, zone_def.name)) continue;
        if (!std.mem.eql(u8, seg.layer, zone_def.layer)) continue;
        const clear_hw = seg.hw + clearance;
        clearLineSegment(grid, cols, rows, min_x, min_y, seg.x1, seg.y1, seg.x2, seg.y2, clear_hw);
    }

    // Step 4: Clear same-net pad centers (thermal relief — keep spokes)
    for (obstacles) |obs| {
        if (!baseNetEql(obs.net, zone_def.name)) continue;
        if (!std.mem.eql(u8, obs.layer, "*") and !std.mem.eql(u8, obs.layer, zone_def.layer)) continue;
        // Clear the pad area but leave thermal spokes
        clearThermalRelief(grid, cols, rows, min_x, min_y, obs.x, obs.y, obs.r, zone_def.thermal_gap, zone_def.thermal_width);
    }

    // Step 5: Extract contour polygons from grid
    const polygons = try extractPolygons(allocator, grid, cols, rows, min_x, min_y);

    return .{
        .zone_name = zone_def.name,
        .layer = zone_def.layer,
        .polygons = polygons,
    };
}

// --- Geometry helpers ---

fn pointInPolygon(x: f64, y: f64, polygon: []const [2]f64) bool {
    var inside = false;
    var j: usize = polygon.len - 1;
    for (0..polygon.len) |i| {
        const xi = polygon[i][0];
        const yi = polygon[i][1];
        const xj = polygon[j][0];
        const yj = polygon[j][1];
        if (((yi > y) != (yj > y)) and (x < (xj - xi) * (y - yi) / (yj - yi) + xi)) {
            inside = !inside;
        }
        j = i;
    }
    return inside;
}

fn clearCircle(grid: []bool, cols: usize, rows: usize, min_x: f64, min_y: f64, cx: f64, cy: f64, radius: f64) void {
    const r_cells: usize = @as(usize, @intFromFloat(@ceil(radius / GRID_SIZE))) + 1;
    const cc: usize = @intFromFloat(@max(0, @floor((cx - min_x) / GRID_SIZE)));
    const cr: usize = @intFromFloat(@max(0, @floor((cy - min_y) / GRID_SIZE)));
    const r2 = radius * radius;

    const start_r = if (cr >= r_cells) cr - r_cells else 0;
    const end_r = @min(cr + r_cells + 1, rows);
    const start_c = if (cc >= r_cells) cc - r_cells else 0;
    const end_c = @min(cc + r_cells + 1, cols);

    for (start_r..end_r) |r| {
        for (start_c..end_c) |c| {
            const gx = min_x + (@as(f64, @floatFromInt(c)) + 0.5) * GRID_SIZE;
            const gy = min_y + (@as(f64, @floatFromInt(r)) + 0.5) * GRID_SIZE;
            const dx = gx - cx;
            const dy = gy - cy;
            if (dx * dx + dy * dy <= r2) {
                grid[r * cols + c] = false;
            }
        }
    }
}

fn distPointToSegment(px: f64, py: f64, x1: f64, y1: f64, x2: f64, y2: f64) f64 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len2 = dx * dx + dy * dy;
    if (len2 < 0.0001) {
        const ddx = px - x1;
        const ddy = py - y1;
        return @sqrt(ddx * ddx + ddy * ddy);
    }
    var t = ((px - x1) * dx + (py - y1) * dy) / len2;
    t = @max(0, @min(1, t));
    const cx = x1 + t * dx;
    const cy = y1 + t * dy;
    const ex = px - cx;
    const ey = py - cy;
    return @sqrt(ex * ex + ey * ey);
}

fn clearLineSegment(grid: []bool, cols: usize, rows: usize, min_x: f64, min_y: f64, x1: f64, y1: f64, x2: f64, y2: f64, half_width: f64) void {
    // Bounding box of the segment + clearance
    const sx_min = @min(x1, x2) - half_width;
    const sx_max = @max(x1, x2) + half_width;
    const sy_min = @min(y1, y2) - half_width;
    const sy_max = @max(y1, y2) + half_width;

    const start_c: usize = @intFromFloat(@max(0, @floor((sx_min - min_x) / GRID_SIZE)));
    const end_c: usize = @min(@as(usize, @intFromFloat(@ceil((sx_max - min_x) / GRID_SIZE))) + 1, cols);
    const start_r: usize = @intFromFloat(@max(0, @floor((sy_min - min_y) / GRID_SIZE)));
    const end_r: usize = @min(@as(usize, @intFromFloat(@ceil((sy_max - min_y) / GRID_SIZE))) + 1, rows);

    for (start_r..end_r) |r| {
        for (start_c..end_c) |c| {
            const gx = min_x + (@as(f64, @floatFromInt(c)) + 0.5) * GRID_SIZE;
            const gy = min_y + (@as(f64, @floatFromInt(r)) + 0.5) * GRID_SIZE;
            const d = distPointToSegment(gx, gy, x1, y1, x2, y2);
            if (d <= half_width) {
                grid[r * cols + c] = false;
            }
        }
    }
}

fn clearThermalRelief(grid: []bool, cols: usize, rows: usize, min_x: f64, min_y: f64, cx: f64, cy: f64, pad_r: f64, gap: f64, spoke_width: f64) void {
    // Clear a ring around the pad, but leave 4 spokes (N/S/E/W)
    const outer_r = pad_r + gap;
    const half_spoke = spoke_width / 2.0;
    const r_cells: usize = @as(usize, @intFromFloat(@ceil(outer_r / GRID_SIZE))) + 1;
    const cc: usize = @intFromFloat(@max(0, @floor((cx - min_x) / GRID_SIZE)));
    const cr: usize = @intFromFloat(@max(0, @floor((cy - min_y) / GRID_SIZE)));

    const start_r = if (cr >= r_cells) cr - r_cells else 0;
    const end_r = @min(cr + r_cells + 1, rows);
    const start_c = if (cc >= r_cells) cc - r_cells else 0;
    const end_c = @min(cc + r_cells + 1, cols);

    for (start_r..end_r) |r| {
        for (start_c..end_c) |c| {
            const gx = min_x + (@as(f64, @floatFromInt(c)) + 0.5) * GRID_SIZE;
            const gy = min_y + (@as(f64, @floatFromInt(r)) + 0.5) * GRID_SIZE;
            const dx = gx - cx;
            const dy = gy - cy;
            const dist = @sqrt(dx * dx + dy * dy);

            // Only affect the ring between pad edge and outer clearance
            if (dist > pad_r and dist <= outer_r) {
                // Check if this is a spoke (N/S/E/W corridor)
                const in_h_spoke = @abs(dy) <= half_spoke;
                const in_v_spoke = @abs(dx) <= half_spoke;
                if (!in_h_spoke and !in_v_spoke) {
                    grid[r * cols + c] = false;
                }
            }
            // Clear inside the pad itself
            if (dist <= pad_r) {
                grid[r * cols + c] = false;
            }
        }
    }
}

fn baseNetEql(a: []const u8, b: []const u8) bool {
    const a_base = baseNet(a);
    const b_base = baseNet(b);
    return std.mem.eql(u8, a_base, b_base);
}

fn baseNet(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, ".")) |dot| return name[0..dot];
    return name;
}

// --- Polygon extraction from grid (simplified contour tracing) ---

fn extractPolygons(allocator: std.mem.Allocator, grid: []const bool, cols: usize, rows: usize, min_x: f64, min_y: f64) ![]const []const [2]f64 {
    // Simplified: find the outer boundary by scanning left-to-right per row,
    // collecting contour points. This produces a single polygon for the zone fill.
    // For complex shapes with holes, a more sophisticated algorithm would be needed.

    var polygons: std.ArrayListUnmanaged([]const [2]f64) = .empty;

    // Simple approach: output a simplified polygon by sampling the grid boundary
    // Walk the boundary of filled regions
    var visited = try allocator.alloc(bool, cols * rows);
    defer allocator.free(visited);
    @memset(visited, false);

    // Find connected components and trace their boundaries
    for (0..rows) |r| {
        for (0..cols) |c| {
            if (!grid[r * cols + c] or visited[r * cols + c]) continue;

            // Flood fill to mark component and collect boundary points
            var boundary_pts: std.ArrayListUnmanaged([2]f64) = .empty;
            var stack: std.ArrayListUnmanaged([2]usize) = .empty;
            defer stack.deinit(allocator);

            try stack.append(allocator, .{ c, r });
            while (stack.items.len > 0) {
                const cell = stack.pop() orelse break;
                const cx = cell[0];
                const cy = cell[1];
                if (visited[cy * cols + cx]) continue;
                if (!grid[cy * cols + cx]) continue;
                visited[cy * cols + cx] = true;

                // Check if this is a boundary cell (adjacent to empty or edge)
                const is_boundary = (cx == 0 or !grid[cy * cols + cx - 1]) or
                    (cx + 1 >= cols or !grid[cy * cols + cx + 1]) or
                    (cy == 0 or !grid[(cy - 1) * cols + cx]) or
                    (cy + 1 >= rows or !grid[(cy + 1) * cols + cx]);

                if (is_boundary) {
                    const px = min_x + (@as(f64, @floatFromInt(cx)) + 0.5) * GRID_SIZE;
                    const py = min_y + (@as(f64, @floatFromInt(cy)) + 0.5) * GRID_SIZE;
                    try boundary_pts.append(allocator, .{ px, py });
                }

                // Push neighbors
                if (cx > 0 and !visited[cy * cols + cx - 1] and grid[cy * cols + cx - 1])
                    try stack.append(allocator, .{ cx - 1, cy });
                if (cx + 1 < cols and !visited[cy * cols + cx + 1] and grid[cy * cols + cx + 1])
                    try stack.append(allocator, .{ cx + 1, cy });
                if (cy > 0 and !visited[(cy - 1) * cols + cx] and grid[(cy - 1) * cols + cx])
                    try stack.append(allocator, .{ cx, cy - 1 });
                if (cy + 1 < rows and !visited[(cy + 1) * cols + cx] and grid[(cy + 1) * cols + cx])
                    try stack.append(allocator, .{ cx, cy + 1 });
            }

            if (boundary_pts.items.len >= 3) {
                // Simplify: order points by angle from centroid for a convex hull approximation
                const simplified = try simplifyBoundary(allocator, boundary_pts.items);
                if (simplified.len >= 3) {
                    try polygons.append(allocator, simplified);
                }
            }
        }
    }

    return try polygons.toOwnedSlice(allocator);
}

fn simplifyBoundary(allocator: std.mem.Allocator, points: [][2]f64) ![]const [2]f64 {
    if (points.len < 3) return &.{};

    // Compute centroid
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (points) |pt| {
        cx += pt[0];
        cy += pt[1];
    }
    cx /= @as(f64, @floatFromInt(points.len));
    cy /= @as(f64, @floatFromInt(points.len));

    // Sort by angle from centroid
    const AnglePoint = struct { angle: f64, x: f64, y: f64 };
    var ap: std.ArrayListUnmanaged(AnglePoint) = .empty;
    defer ap.deinit(allocator);

    for (points) |pt| {
        const angle = std.math.atan2(pt[1] - cy, pt[0] - cx);
        try ap.append(allocator, .{ .angle = angle, .x = pt[0], .y = pt[1] });
    }

    // Sort by angle
    std.mem.sort(AnglePoint, ap.items, {}, struct {
        fn lessThan(_: void, a: AnglePoint, b: AnglePoint) bool {
            return a.angle < b.angle;
        }
    }.lessThan);

    // Subsample to reduce point count (max ~100 points per polygon)
    const step = if (ap.items.len > 200) ap.items.len / 100 else 1;
    var result: std.ArrayListUnmanaged([2]f64) = .empty;
    var i: usize = 0;
    while (i < ap.items.len) : (i += step) {
        try result.append(allocator, .{ ap.items[i].x, ap.items[i].y });
    }

    return try result.toOwnedSlice(allocator);
}

// --- Pad geometry ---

const PadGeom = struct {
    name: []const u8,
    pad_type: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

const PlacementInfo = struct { x: f64, y: f64, angle: f64, side: layout_mod.Side };

fn transformPad(px: f64, py: f64, angle_deg: f64, comp_x: f64, comp_y: f64) [2]f64 {
    const a = angle_deg * std.math.pi / 180.0;
    const cos_a = @cos(a);
    const sin_a = @sin(a);
    return .{
        comp_x + px * cos_a - py * sin_a,
        comp_y + px * sin_a + py * cos_a,
    };
}

fn parsePads(allocator: std.mem.Allocator, source: []const u8) ![]const PadGeom {
    const nodes = try parser_mod.parse(allocator, source);
    if (nodes.len == 0) return error.InvalidFormat;
    const children = nodes[0].asList() orelse return error.InvalidFormat;

    var pads: std.ArrayListUnmanaged(PadGeom) = .empty;
    for (children) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 5) continue;
        const tag = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, tag, "pad")) continue;

        const name = cl[1].asAtom() orelse cl[1].asString() orelse continue;
        const pad_type = cl[2].asAtom() orelse continue;
        var px: f64 = 0;
        var py: f64 = 0;
        var pw: f64 = 0;
        var ph: f64 = 0;
        for (cl[4..]) |sub| {
            const sl = sub.asList() orelse continue;
            if (sl.len < 2) continue;
            const stag = sl[0].asAtom() orelse continue;
            if (std.mem.eql(u8, stag, "pos") and sl.len >= 3) {
                px = nf(sl[1]);
                py = nf(sl[2]);
            } else if (std.mem.eql(u8, stag, "size") and sl.len >= 3) {
                pw = nf(sl[1]);
                ph = nf(sl[2]);
            }
        }
        try pads.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .pad_type = try allocator.dupe(u8, pad_type),
            .x = px,
            .y = py,
            .w = pw,
            .h = ph,
        });
    }
    return try pads.toOwnedSlice(allocator);
}

fn nf(node: anytype) f64 {
    if (node.asNumber()) |n| return n;
    if (node.asAtom()) |s| return std.fmt.parseFloat(f64, s) catch 0;
    return 0;
}
