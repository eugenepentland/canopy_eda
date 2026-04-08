const std = @import("std");
const env_mod = @import("eval/env.zig");
const layout_mod = @import("layout.zig");
const netlist_mod = @import("export_kicad_netlist.zig");
const export_kicad = @import("export_kicad.zig");
const FlatInstance = export_kicad.FlatInstance;
const parser_mod = @import("sexpr/parser.zig");

pub const Severity = enum { error_, warning };

pub const Violation = struct {
    kind: []const u8,
    message: []const u8,
    x: f64,
    y: f64,
    severity: Severity,
};

/// Run DRC on a design, returning all violations found.
pub fn runDrc(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    board_def: ?*const env_mod.Board,
    project_dir: []const u8,
    layout: *const layout_mod.Layout,
) ![]const Violation {
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
        placed.put(p.uuid, .{ .x = p.x, .y = p.y, .angle = p.angle, .side = p.side }) catch {};
    }

    // Parse footprint pads
    var fp_geom = std.StringHashMap([]const PadGeom).init(allocator);
    defer fp_geom.deinit();
    for (instances.items) |inst| {
        if (inst.footprint.len == 0) continue;
        if (fp_geom.contains(inst.footprint)) continue;
        const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
        defer allocator.free(fp_path);
        const source = std.fs.cwd().readFileAlloc(allocator, fp_path, 1024 * 1024) catch continue;
        const pads = parsePads(allocator, source) catch continue;
        fp_geom.put(inst.footprint, pads) catch {};
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
                .r = @max(pad.w, pad.h) / 2.0,
                .net = net_name,
                .layer = if (is_thru) "ALL" else fp_layer,
                .ref = inst.ref_des,
                .pin = pad.name,
            });
        }
    }

    // Check 1: Pad-to-pad clearance (different nets)
    for (0..pad_list.items.len) |i| {
        for (i + 1..pad_list.items.len) |j| {
            const a = pad_list.items[i];
            const b = pad_list.items[j];
            if (sameNet(a.net, b.net)) continue;
            if (!layersOverlap(a.layer, b.layer)) continue;
            const dx = a.x - b.x;
            const dy = a.y - b.y;
            const dist = @sqrt(dx * dx + dy * dy) - a.r - b.r;
            if (dist < rules.clearance) {
                try violations.append(allocator, .{
                    .kind = "clearance",
                    .message = try std.fmt.allocPrint(allocator, "Pad {s}.{s} to {s}.{s}: {d:.2}mm < {d:.2}mm clearance", .{ a.ref, a.pin, b.ref, b.pin, dist, rules.clearance }),
                    .x = (a.x + b.x) / 2.0,
                    .y = (a.y + b.y) / 2.0,
                    .severity = .error_,
                });
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
                const gap = d - pad.r - t.width / 2.0;
                if (gap < rules.clearance) {
                    try violations.append(allocator, .{
                        .kind = "clearance",
                        .message = try std.fmt.allocPrint(allocator, "Trace '{s}' to pad {s}.{s}: {d:.2}mm < {d:.2}mm", .{ baseNet(t.net), pad.ref, pad.pin, gap, rules.clearance }),
                        .x = pad.x,
                        .y = pad.y,
                        .severity = .error_,
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
            const min_gap = rules.clearance + ta.width / 2.0 + tb.width / 2.0;
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
                        const mx = (ta.points[ai][0] + tb.points[bi][0]) / 2.0;
                        const my = (ta.points[ai][1] + tb.points[bi][1]) / 2.0;
                        try violations.append(allocator, .{
                            .kind = "clearance",
                            .message = try std.fmt.allocPrint(allocator, "Trace '{s}' to trace '{s}': {d:.2}mm < {d:.2}mm", .{ baseNet(ta.net), baseNet(tb.net), d, min_gap }),
                            .x = mx,
                            .y = my,
                            .severity = .error_,
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
            const dist = @sqrt(dx * dx + dy * dy) - v.pad_size / 2.0 - pad.r;
            if (dist < rules.clearance) {
                try violations.append(allocator, .{
                    .kind = "clearance",
                    .message = try std.fmt.allocPrint(allocator, "Via '{s}' to pad {s}.{s}: {d:.2}mm < {d:.2}mm", .{ baseNet(v.net), pad.ref, pad.pin, dist, rules.clearance }),
                    .x = v.x,
                    .y = v.y,
                    .severity = .error_,
                });
            }
        }
        // Via to trace
        for (layout.traces) |t| {
            if (sameNet(v.net, t.net)) continue;
            for (0..t.points.len -| 1) |pi| {
                const d = distPtSeg(v.x, v.y, t.points[pi][0], t.points[pi][1], t.points[pi + 1][0], t.points[pi + 1][1]);
                const gap = d - v.pad_size / 2.0 - t.width / 2.0;
                if (gap < rules.clearance) {
                    try violations.append(allocator, .{
                        .kind = "clearance",
                        .message = try std.fmt.allocPrint(allocator, "Via '{s}' to trace '{s}': {d:.2}mm < {d:.2}mm", .{ baseNet(v.net), baseNet(t.net), gap, rules.clearance }),
                        .x = v.x,
                        .y = v.y,
                        .severity = .error_,
                    });
                    break;
                }
            }
        }
    }

    // Check 5: Minimum trace width
    for (layout.traces) |t| {
        if (t.width < rules.track_width - 0.001) {
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
        const annular = (v.pad_size - v.drill) / 2.0;
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
                                .severity = .error_,
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
                            .severity = .error_,
                        });
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

fn distSegSeg(ax1: f64, ay1: f64, ax2: f64, ay2: f64, bx1: f64, by1: f64, bx2: f64, by2: f64) f64 {
    return @min(@min(distPtSeg(ax1, ay1, bx1, by1, bx2, by2), distPtSeg(ax2, ay2, bx1, by1, bx2, by2)), @min(distPtSeg(bx1, by1, ax1, ay1, ax2, ay2), distPtSeg(bx2, by2, ax1, ay1, ax2, ay2)));
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
    const a = angle_deg * std.math.pi / 180.0;
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
        try pads.append(allocator, .{ .name = try allocator.dupe(u8, name), .pad_type = try allocator.dupe(u8, pad_type), .x = px, .y = py, .w = pw, .h = ph });
    }
    return try pads.toOwnedSlice(allocator);
}

fn nf(node: anytype) f64 {
    if (node.asNumber()) |n| return n;
    if (node.asAtom()) |s| return std.fmt.parseFloat(f64, s) catch 0;
    return 0;
}
