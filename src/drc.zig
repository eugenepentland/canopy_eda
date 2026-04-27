const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const env_mod = @import("eval/env.zig");
const layout_mod = @import("layout.zig");
const netlist_mod = @import("export_kicad_netlist.zig");
const export_kicad = @import("export_kicad.zig");
const FlatInstance = export_kicad.FlatInstance;
const parser_mod = @import("sexpr/parser.zig");
const checks = @import("checks.zig");
const json_writer = @import("json_writer.zig");

pub const Severity = checks.Severity;

// ── Numeric constants ──────────────────────────────────────────────
const HALF_DIVISOR: f64 = 2.0;
const GRID_HASH_PRIME: i64 = 100003;
const TRACE_WIDTH_EPSILON: f64 = 0.001;
const SEG_LEN_EPSILON: f64 = 0.0001;
const DEG_TO_RAD_BASE: f64 = 180.0;
const PAD_NODE_MIN_CHILDREN: usize = 5;

// ── Repeated string literals ───────────────────────────────────────
const KIND_CLEARANCE: []const u8 = "clearance";

/// A single design-rule-check finding on the PCB layout: the rule kind
/// (e.g. `clearance`, `min_width`, `keepout`, `unconnected`), a human
/// message, the board-coordinate location to highlight, and a severity
/// the UI uses to colour the marker.
pub const Violation = struct {
    kind: []const u8,
    message: []const u8,
    x: f64,
    y: f64,
    severity: Severity,
};

/// Serialize DRC violations to JSON. Output format:
/// `{"violations":[{"kind":...,"message":...,"x":...,"y":...,"severity":...}],"count":N}`
pub fn writeViolationsJson(allocator: std.mem.Allocator, violations: []const Violation) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("{\"violations\":[");
    for (violations, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"kind\":");
        try json_writer.writeString(w, v.kind);
        try w.writeAll(",\"message\":");
        try json_writer.writeString(w, v.message);
        try w.print(",\"x\":{d:.4},\"y\":{d:.4},\"severity\":\"{s}\"", .{ v.x, v.y, @tagName(v.severity) });
        try w.writeAll("}");
    }
    try w.print("],\"count\":{d}}}", .{violations.len});
    return buf.items;
}

/// Run DRC on a design, returning all violations found.
pub fn runDrc(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    board_def: ?*const env_mod.Board,
    project_dir: []const u8,
    layout: *const layout_mod.Layout,
) std.mem.Allocator.Error![]const Violation {
    var violations: std.ArrayListUnmanaged(Violation) = .empty;

    const rules = if (layout.rules) |r| r else if (board_def) |bd| layout_mod.Rules{
        .clearance = bd.rules.clearance,
        .track_width = bd.rules.track_width,
        .via_drill = bd.rules.via_drill,
        .via_size = bd.rules.via_size,
    } else layout_mod.Rules{};

    // Collect obstacles
    var instances: std.ArrayListUnmanaged(FlatInstance) = .empty;
    defer instances.deinit(allocator);
    try netlist_mod.collectInstances(allocator, block, "", &instances);

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

    // Build placement map
    var placed = std.StringHashMap(PlacementInfo).init(allocator);
    defer placed.deinit();
    for (layout.placements) |p| {
        try placed.put(p.uuid, .{ .x = p.x, .y = p.y, .angle = p.angle, .side = p.side });
    }

    // Parse footprint pads
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

    // Build list of pad positions with net/layer info
    const PadPos = struct { x: f64, y: f64, r: f64, net: []const u8, layer: []const u8, ref: []const u8, pin: []const u8 };
    var pad_list: std.ArrayListUnmanaged(PadPos) = .empty;
    defer pad_list.deinit(allocator);

    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        const pl = placed.get(inst.uuid) orelse continue;
        const pads = fp_geom.get(inst.footprint) orelse continue;
        const fp_layer: []const u8 = if (pl.side == .front) "F.Cu" else "B.Cu";

        for (pads) |pad| {
            const pos = transformPad(pad.x, pad.y, pl.angle, pl.x, pl.y);
            const key = try std.fmt.allocPrint(allocator, "{s}\x00{s}", .{ inst.ref_des, pad.name });
            const net_name = pin_net.get(key) orelse "";
            const is_thru = std.mem.eql(u8, pad.pad_type, "thru_hole");
            try pad_list.append(allocator, .{
                .x = pos[0],
                .y = pos[1],
                .r = @max(pad.w, pad.h) / HALF_DIVISOR,
                .net = net_name,
                .layer = if (is_thru) "ALL" else fp_layer,
                .ref = inst.ref_des,
                .pin = pad.name,
            });
        }
    }

    // Check 1: Pad-to-pad clearance (different nets) — grid-accelerated
    // Build spatial grid with cell size = 2x max clearance radius
    const max_pad_r: f64 = blk: {
        var mr: f64 = 0;
        for (pad_list.items) |p| mr = @max(mr, p.r);
        break :blk mr;
    };
    const grid_cell: f64 = @max(HALF_DIVISOR, (rules.clearance + max_pad_r * 2) * HALF_DIVISOR);
    {
        // Hash pads into grid cells
        var grid = std.AutoHashMap(i64, std.ArrayListUnmanaged(usize)).init(allocator);
        defer {
            var git = grid.iterator();
            while (git.next()) |entry| entry.value_ptr.deinit(allocator);
            grid.deinit();
        }
        for (pad_list.items, 0..) |p, i| {
            const cx: i64 = @intFromFloat(@floor(p.x / grid_cell));
            const cy: i64 = @intFromFloat(@floor(p.y / grid_cell));
            const key: i64 = cx *% GRID_HASH_PRIME +% cy;
            const gop = try grid.getOrPut(key);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, i);
        }
        // Check each pad against neighbors in adjacent cells
        for (pad_list.items, 0..) |a, ai| {
            const acx: i64 = @intFromFloat(@floor(a.x / grid_cell));
            const acy: i64 = @intFromFloat(@floor(a.y / grid_cell));
            var dcx: i64 = -1;
            while (dcx <= 1) : (dcx += 1) {
                var dcy: i64 = -1;
                while (dcy <= 1) : (dcy += 1) {
                    const nkey: i64 = (acx + dcx) *% GRID_HASH_PRIME +% (acy + dcy);
                    const cell = grid.get(nkey) orelse continue;
                    for (cell.items) |bi| {
                        if (bi <= ai) continue; // avoid duplicate pairs
                        const b = pad_list.items[bi];
                        if (sameNet(a.net, b.net)) continue;
                        if (!layersOverlap(a.layer, b.layer)) continue;
                        const dx = a.x - b.x;
                        const dy = a.y - b.y;
                        const dist = @sqrt(dx * dx + dy * dy) - a.r - b.r;
                        if (dist < rules.clearance) {
                            try violations.append(allocator, .{
                                .kind = KIND_CLEARANCE,
                                .message = try std.fmt.allocPrint(
                                    allocator,
                                    "Pad {s}.{s} to {s}.{s}: {d:.2}mm < {d:.2}mm clearance",
                                    .{ a.ref, a.pin, b.ref, b.pin, dist, rules.clearance },
                                ),
                                .x = (a.x + b.x) / HALF_DIVISOR,
                                .y = (a.y + b.y) / HALF_DIVISOR,
                                .severity = .@"error",
                            });
                        }
                    }
                }
            }
        }
    }

    // Check 2: Trace-to-pad clearance (different nets)
    for (layout.traces) |t| {
        for (0..t.points.len -| 1) |pi| {
            for (pad_list.items) |pad| {
                if (sameNet(t.net, pad.net)) continue;
                if (!std.mem.eql(u8, pad.layer, "ALL") and !std.mem.eql(u8, pad.layer, t.layer)) continue;
                const d = distPtSeg(pad.x, pad.y, t.points[pi][0], t.points[pi][1], t.points[pi + 1][0], t.points[pi + 1][1]);
                const gap = d - pad.r - t.width / HALF_DIVISOR;
                if (gap < rules.clearance) {
                    try violations.append(allocator, .{
                        .kind = KIND_CLEARANCE,
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "Trace '{s}' to pad {s}.{s}: {d:.2}mm < {d:.2}mm",
                            .{ baseNet(t.net), pad.ref, pad.pin, gap, rules.clearance },
                        ),
                        .x = pad.x,
                        .y = pad.y,
                        .severity = .@"error",
                    });
                    break; // One violation per pad per trace
                }
            }
        }
    }

    // Check 3: Trace-to-trace clearance (different nets, same layer)
    for (0..layout.traces.len) |ti| {
        for (ti + 1..layout.traces.len) |tj| {
            const ta = layout.traces[ti];
            const tb = layout.traces[tj];
            if (sameNet(ta.net, tb.net)) continue;
            if (!std.mem.eql(u8, ta.layer, tb.layer)) continue;
            const min_gap = rules.clearance + ta.width / HALF_DIVISOR + tb.width / HALF_DIVISOR;
            // Check all segment pairs
            var found_violation = false;
            for (0..ta.points.len -| 1) |ai| {
                if (found_violation) break;
                for (0..tb.points.len -| 1) |bi| {
                    const d = distSegSeg(
                        ta.points[ai][0],
                        ta.points[ai][1],
                        ta.points[ai + 1][0],
                        ta.points[ai + 1][1],
                        tb.points[bi][0],
                        tb.points[bi][1],
                        tb.points[bi + 1][0],
                        tb.points[bi + 1][1],
                    );
                    if (d < min_gap) {
                        const mx = (ta.points[ai][0] + tb.points[bi][0]) / HALF_DIVISOR;
                        const my = (ta.points[ai][1] + tb.points[bi][1]) / HALF_DIVISOR;
                        try violations.append(allocator, .{
                            .kind = KIND_CLEARANCE,
                            .message = try std.fmt.allocPrint(
                                allocator,
                                "Trace '{s}' to trace '{s}': {d:.2}mm < {d:.2}mm",
                                .{ baseNet(ta.net), baseNet(tb.net), d, min_gap },
                            ),
                            .x = mx,
                            .y = my,
                            .severity = .@"error",
                        });
                        found_violation = true;
                        break;
                    }
                }
            }
        }
    }

    // Check 4: Via clearance
    for (0..layout.vias.len) |vi| {
        const v = layout.vias[vi];
        // Via to pad
        for (pad_list.items) |pad| {
            if (sameNet(v.net, pad.net)) continue;
            const dx = v.x - pad.x;
            const dy = v.y - pad.y;
            const dist = @sqrt(dx * dx + dy * dy) - v.pad_size / HALF_DIVISOR - pad.r;
            if (dist < rules.clearance) {
                try violations.append(allocator, .{
                    .kind = KIND_CLEARANCE,
                    .message = try std.fmt.allocPrint(
                        allocator,
                        "Via '{s}' to pad {s}.{s}: {d:.2}mm < {d:.2}mm",
                        .{ baseNet(v.net), pad.ref, pad.pin, dist, rules.clearance },
                    ),
                    .x = v.x,
                    .y = v.y,
                    .severity = .@"error",
                });
            }
        }
        // Via to trace
        for (layout.traces) |t| {
            if (sameNet(v.net, t.net)) continue;
            for (0..t.points.len -| 1) |pi| {
                const d = distPtSeg(v.x, v.y, t.points[pi][0], t.points[pi][1], t.points[pi + 1][0], t.points[pi + 1][1]);
                const gap = d - v.pad_size / HALF_DIVISOR - t.width / HALF_DIVISOR;
                if (gap < rules.clearance) {
                    try violations.append(allocator, .{
                        .kind = KIND_CLEARANCE,
                        .message = try std.fmt.allocPrint(
                            allocator,
                            "Via '{s}' to trace '{s}': {d:.2}mm < {d:.2}mm",
                            .{ baseNet(v.net), baseNet(t.net), gap, rules.clearance },
                        ),
                        .x = v.x,
                        .y = v.y,
                        .severity = .@"error",
                    });
                    break;
                }
            }
        }
    }

    // Check 5: Minimum trace width
    for (layout.traces) |t| {
        if (t.width < rules.track_width - TRACE_WIDTH_EPSILON) {
            if (t.points.len >= 2) {
                try violations.append(allocator, .{
                    .kind = "min_width",
                    .message = try std.fmt.allocPrint(allocator, "Trace '{s}' width {d:.2}mm < min {d:.2}mm", .{ baseNet(t.net), t.width, rules.track_width }),
                    .x = t.points[0][0],
                    .y = t.points[0][1],
                    .severity = .warning,
                });
            }
        }
    }

    // Check 6: Minimum annular ring (via pad_size - drill should be >= 0.15mm total, 0.075mm per side)
    const min_annular = 0.075; // mm per side
    for (layout.vias) |v| {
        const annular = (v.pad_size - v.drill) / HALF_DIVISOR;
        if (annular < min_annular) {
            try violations.append(allocator, .{
                .kind = "annular_ring",
                .message = try std.fmt.allocPrint(allocator, "Via annular ring {d:.3}mm < min {d:.3}mm", .{ annular, min_annular }),
                .x = v.x,
                .y = v.y,
                .severity = .warning,
            });
        }
    }

    // Check 7: Keepout violations
    if (board_def) |bd| {
        for (bd.keepouts) |ko| {
            // Check traces in keepout
            if (ko.no_tracks) {
                for (layout.traces) |t| {
                    for (t.points) |pt| {
                        if (pointInPolygon(pt[0], pt[1], ko.outline)) {
                            try violations.append(allocator, .{
                                .kind = "keepout",
                                .message = try std.fmt.allocPrint(allocator, "Trace '{s}' in keepout '{s}'", .{ baseNet(t.net), ko.name }),
                                .x = pt[0],
                                .y = pt[1],
                                .severity = .@"error",
                            });
                            break;
                        }
                    }
                }
            }
            // Check vias in keepout
            if (ko.no_vias) {
                for (layout.vias) |v| {
                    if (pointInPolygon(v.x, v.y, ko.outline)) {
                        try violations.append(allocator, .{
                            .kind = "keepout",
                            .message = try std.fmt.allocPrint(allocator, "Via '{s}' in keepout '{s}'", .{ baseNet(v.net), ko.name }),
                            .x = v.x,
                            .y = v.y,
                            .severity = .@"error",
                        });
                    }
                }
            }
        }
    }

    // Check 8: Unconnected nets — pads on same net not connected by traces/vias
    {
        // Build adjacency: two pads are connected if a trace/via chain links them.
        // Use union-find on pad indices.
        const n_pads = pad_list.items.len;
        if (n_pads > 0) {
            var parent = try allocator.alloc(usize, n_pads);
            defer allocator.free(parent);
            for (0..n_pads) |i| parent[i] = i;

            // Find root with path compression
            const find = struct {
                fn f(p: []usize, x: usize) usize {
                    var cur = x;
                    while (p[cur] != cur) {
                        p[cur] = p[p[cur]];
                        cur = p[cur];
                    }
                    return cur;
                }
            }.f;

            // Union two pads
            const merge = struct {
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

            _ = find;

            // Proximity threshold: pad is "connected" to a trace endpoint if within this distance
            const connect_dist: f64 = 0.15; // mm

            // Connect pads that touch the same trace endpoint or via
            for (layout.traces) |t| {
                if (t.points.len < 2) continue;
                // Find pads near trace start and end points
                var start_pads: std.ArrayListUnmanaged(usize) = .empty;
                defer start_pads.deinit(allocator);
                var end_pads: std.ArrayListUnmanaged(usize) = .empty;
                defer end_pads.deinit(allocator);

                for (pad_list.items, 0..) |pad, pi| {
                    if (!sameNet(pad.net, t.net)) continue;
                    // Check start
                    const ds = @sqrt(std.math.pow(f64, pad.x - t.points[0][0], 2) + std.math.pow(f64, pad.y - t.points[0][1], 2));
                    if (ds <= pad.r + connect_dist) {
                        try start_pads.append(allocator, pi);
                    }
                    // Check end
                    const last = t.points.len - 1;
                    const de = @sqrt(std.math.pow(f64, pad.x - t.points[last][0], 2) + std.math.pow(f64, pad.y - t.points[last][1], 2));
                    if (de <= pad.r + connect_dist) {
                        try end_pads.append(allocator, pi);
                    }
                }

                // Merge all start pads together
                if (start_pads.items.len > 1)
                    for (start_pads.items[1..]) |pi| merge(parent, start_pads.items[0], pi);
                // Merge all end pads together
                if (end_pads.items.len > 1)
                    for (end_pads.items[1..]) |pi| merge(parent, end_pads.items[0], pi);
                // Merge start and end groups (trace connects them)
                if (start_pads.items.len > 0 and end_pads.items.len > 0) {
                    merge(parent, start_pads.items[0], end_pads.items[0]);
                }
            }

            // Vias connect pads near them on any layer
            for (layout.vias) |v| {
                var via_pads: std.ArrayListUnmanaged(usize) = .empty;
                defer via_pads.deinit(allocator);
                for (pad_list.items, 0..) |pad, pi| {
                    if (!sameNet(pad.net, v.net)) continue;
                    const dv = @sqrt(std.math.pow(f64, pad.x - v.x, 2) + std.math.pow(f64, pad.y - v.y, 2));
                    if (dv <= pad.r + v.pad_size / HALF_DIVISOR + connect_dist) {
                        try via_pads.append(allocator, pi);
                    }
                }
                if (via_pads.items.len > 1)
                    for (via_pads.items[1..]) |pi| merge(parent, via_pads.items[0], pi);
            }

            // Also connect traces to each other where endpoints meet
            for (layout.traces, 0..) |ta, ti| {
                if (ta.points.len < 2) continue;
                for (layout.traces[ti + 1 ..]) |tb| {
                    if (tb.points.len < 2) continue;
                    if (!sameNet(ta.net, tb.net)) continue;
                    // Check if any endpoints are close
                    const ta_ends = [_][2]f64{ ta.points[0], ta.points[ta.points.len - 1] };
                    const tb_ends = [_][2]f64{ tb.points[0], tb.points[tb.points.len - 1] };
                    var traces_connected = false;
                    for (ta_ends) |ea| {
                        for (tb_ends) |eb| {
                            const dt = @sqrt(std.math.pow(f64, ea[0] - eb[0], 2) + std.math.pow(f64, ea[1] - eb[1], 2));
                            if (dt < connect_dist) traces_connected = true;
                        }
                    }
                    if (traces_connected) {
                        // Find any pad connected to each trace and merge
                        var pad_a: ?usize = null;
                        var pad_b: ?usize = null;
                        for (pad_list.items, 0..) |pad, pi| {
                            if (!sameNet(pad.net, ta.net)) continue;
                            for (ta_ends) |ep| {
                                const d = @sqrt(std.math.pow(f64, pad.x - ep[0], 2) + std.math.pow(f64, pad.y - ep[1], 2));
                                if (d <= pad.r + connect_dist) {
                                    pad_a = pi;
                                    break;
                                }
                            }
                            for (tb_ends) |ep| {
                                const d = @sqrt(std.math.pow(f64, pad.x - ep[0], 2) + std.math.pow(f64, pad.y - ep[1], 2));
                                if (d <= pad.r + connect_dist) {
                                    pad_b = pi;
                                    break;
                                }
                            }
                        }
                        if (pad_a != null and pad_b != null) merge(parent, pad_a.?, pad_b.?);
                    }
                }
            }

            // Now check each net: all pads should be in the same connected component
            // Group pads by base net name
            var net_pads = std.StringHashMap(std.ArrayListUnmanaged(usize)).init(allocator);
            defer {
                var it = net_pads.iterator();
                while (it.next()) |entry| entry.value_ptr.deinit(allocator);
                net_pads.deinit();
            }
            for (pad_list.items, 0..) |pad, pi| {
                if (pad.net.len == 0) continue;
                const bn = baseNet(pad.net);
                if (std.mem.eql(u8, bn, "GND")) continue; // Skip GND — too many pads
                const gop = try net_pads.getOrPut(bn);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(allocator, pi);
            }

            var net_iter = net_pads.iterator();
            while (net_iter.next()) |entry| {
                const net_name = entry.key_ptr.*;
                const pads_on_net = entry.value_ptr.items;
                if (pads_on_net.len < 2) continue;

                // Find root of first pad
                const root0 = struct {
                    fn f(p: []usize, x: usize) usize {
                        var cur = x;
                        while (p[cur] != cur) {
                            p[cur] = p[p[cur]];
                            cur = p[cur];
                        }
                        return cur;
                    }
                }.f(parent, pads_on_net[0]);

                // Check all others
                for (pads_on_net[1..]) |pi| {
                    const root_i = struct {
                        fn f(p: []usize, x: usize) usize {
                            var cur = x;
                            while (p[cur] != cur) {
                                p[cur] = p[p[cur]];
                                cur = p[cur];
                            }
                            return cur;
                        }
                    }.f(parent, pi);
                    if (root_i != root0) {
                        const pad = pad_list.items[pi];
                        try violations.append(allocator, .{
                            .kind = "unconnected",
                            .message = try std.fmt.allocPrint(allocator, "Pad {s}.{s} on net '{s}' is unconnected", .{ pad.ref, pad.pin, net_name }),
                            .x = pad.x,
                            .y = pad.y,
                            .severity = .@"error",
                        });
                        break; // One violation per net is enough
                    }
                }
            }
        }
    }

    return try violations.toOwnedSlice(allocator);
}

// --- Helpers ---

fn sameNet(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    return std.mem.eql(u8, baseNet(a), baseNet(b));
}

fn baseNet(name: []const u8) []const u8 {
    if (std.mem.indexOf(u8, name, ".")) |dot| return name[0..dot];
    return name;
}

fn layersOverlap(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, "ALL") or std.mem.eql(u8, b, "ALL")) return true;
    return std.mem.eql(u8, a, b);
}

fn distPtSeg(px: f64, py: f64, x1: f64, y1: f64, x2: f64, y2: f64) f64 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const len2 = dx * dx + dy * dy;
    if (len2 < SEG_LEN_EPSILON) {
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

fn distSegSeg(ax1: f64, ay1: f64, ax2: f64, ay2: f64, bx1: f64, by1: f64, bx2: f64, by2: f64) f64 {
    return @min(
        @min(
            distPtSeg(ax1, ay1, bx1, by1, bx2, by2),
            distPtSeg(ax2, ay2, bx1, by1, bx2, by2),
        ),
        @min(
            distPtSeg(bx1, by1, ax1, ay1, ax2, ay2),
            distPtSeg(bx2, by2, ax1, ay1, ax2, ay2),
        ),
    );
}

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

fn transformPad(px: f64, py: f64, angle_deg: f64, comp_x: f64, comp_y: f64) [2]f64 {
    const a = angle_deg * std.math.pi / DEG_TO_RAD_BASE;
    return .{
        comp_x + px * @cos(a) - py * @sin(a),
        comp_y + px * @sin(a) + py * @cos(a),
    };
}

const PadGeom = struct { name: []const u8, pad_type: []const u8, x: f64, y: f64, w: f64, h: f64 };
const PlacementInfo = struct { x: f64, y: f64, angle: f64, side: layout_mod.Side };

fn parsePads(allocator: std.mem.Allocator, source: []const u8) ![]const PadGeom {
    const nodes = try parser_mod.parse(allocator, source);
    if (nodes.len == 0) return error.InvalidFormat;
    const children = nodes[0].asList() orelse return error.InvalidFormat;
    var pads: std.ArrayListUnmanaged(PadGeom) = .empty;
    for (children) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < PAD_NODE_MIN_CHILDREN) continue;
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
        try pads.append(allocator, .{ .name = try allocator.dupe(u8, name), .pad_type = try allocator.dupe(u8, pad_type), .x = px, .y = py, .w = pw, .h = ph });
    }
    return try pads.toOwnedSlice(allocator);
}

fn nf(node: anytype) f64 {
    if (node.asNumber()) |n| return n;
    if (node.asAtom()) |s| return std.fmt.parseFloat(f64, s) catch 0;
    return 0;
}
