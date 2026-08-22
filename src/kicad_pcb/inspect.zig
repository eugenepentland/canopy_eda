//! File-backed inspection and metric reporting for normalized KiCad board
//! snapshots. This is the non-destructive seam used by the CLI and MCP tool:
//! it reads `.kicad_pcb` plus the adjacent `.kicad_pro`, then emits compact,
//! deterministic JSON suitable for an agent, scorer, or benchmark harness.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const snapshot_mod = @import("snapshot.zig");
const project_mod = @import("project_rules.zig");
const net_aliases = @import("net_aliases.zig");

const max_board_bytes = 64 * 1024 * 1024;
const max_project_bytes = 8 * 1024 * 1024;
const json_name = "{\"name\":";

/// Errors possible while loading a board and its optional adjacent project.
pub const LoadError = std.mem.Allocator.Error ||
    infra_fs.File.OpenError ||
    infra_fs.File.ReadError ||
    snapshot_mod.ParseError ||
    project_mod.ParseError ||
    error{ FileTooBig, StreamTooLong };

/// Controls whether the report carries only board aggregates or per-net rows.
pub const Detail = enum { summary, nets };

/// A board snapshot together with its adjacent project rules, when present.
pub const Report = struct {
    board_path: []const u8,
    project_path: ?[]const u8,
    board: snapshot_mod.Snapshot,
    project: ?project_mod.ProjectRules,
};

const NetMetric = struct {
    name: []const u8,
    pads: usize = 0,
    segments: usize = 0,
    arcs: usize = 0,
    vias: usize = 0,
    zones: usize = 0,
    length_mm: f64 = 0,
};

const LayerMetric = struct {
    name: []const u8,
    segments: usize = 0,
    arcs: usize = 0,
    zone_count: usize = 0,
    length_mm: f64 = 0,
};

/// Read a board and, if it exists, its same-stem `.kicad_pro`. Nothing is
/// written. A malformed present project is an error rather than silently
/// falling back to router defaults.
pub fn load(arena: std.mem.Allocator, board_path: []const u8) LoadError!Report {
    const board_source = try infra_fs.cwd().readFileAlloc(arena, board_path, max_board_bytes);
    const board = try snapshot_mod.parse(arena, board_source);
    const project_path = try siblingProjectPath(arena, board_path);
    const project_source = infra_fs.cwd().readFileAlloc(
        arena,
        project_path,
        max_project_bytes,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{
            .board_path = board_path,
            .project_path = null,
            .board = board,
            .project = null,
        },
        else => return err,
    };
    return .{
        .board_path = board_path,
        .project_path = project_path,
        .board = board,
        .project = try project_mod.parse(arena, project_source),
    };
}

fn siblingProjectPath(arena: std.mem.Allocator, board_path: []const u8) std.mem.Allocator.Error![]const u8 {
    const suffix = ".kicad_pcb";
    if (std.mem.endsWith(u8, board_path, suffix)) {
        return std.fmt.allocPrint(arena, "{s}.kicad_pro", .{board_path[0 .. board_path.len - suffix.len]});
    }
    return std.fmt.allocPrint(arena, "{s}.kicad_pro", .{board_path});
}

/// Emit the normalized report. `.nets` adds one compact metric row per net;
/// summary/layer/rule data is always present.
pub fn writeJson(
    arena: std.mem.Allocator,
    writer: anytype,
    report: Report,
    detail: Detail,
) !void {
    const summary = snapshot_mod.summarize(report.board);
    const bounds = snapshot_mod.outlineBounds(report.board);
    const layers = try layerMetrics(arena, report.board);
    const widths = try distinctWidths(arena, report.board);

    try writer.writeAll("{\"ok\":true,\"board_path\":");
    try json_writer.writeString(writer, report.board_path);
    try writer.writeAll(",\"project_path\":");
    if (report.project_path) |path| try json_writer.writeString(writer, path) else try writer.writeAll("null");
    try writer.print(
        ",\"format\":{{\"version\":{d},\"generator\":",
        .{report.board.version},
    );
    try json_writer.writeString(writer, report.board.generator);
    try writer.writeAll(",\"generator_version\":");
    try json_writer.writeString(writer, report.board.generator_version);
    try writer.print(",\"thickness_mm\":{d}}}", .{report.board.thickness_mm});
    try writeCounts(writer, summary);
    try writeOutline(writer, bounds, report.board.outline.len);
    try writeCopper(writer, summary.copper_length_mm, widths, layers);
    try writeZones(writer, report.board);
    try writeProject(writer, report.project);
    if (detail == .nets) {
        const nets = try netMetrics(arena, report.board);
        try writeNets(writer, nets);
        try writeAliases(writer, try net_aliases.analyze(arena, report.board));
    }
    try writer.writeByte('}');
}

fn writeCounts(writer: anytype, summary: snapshot_mod.Summary) !void {
    try writer.print(
        ",\"counts\":{{\"footprints\":{d},\"top_footprints\":{d}," ++
            "\"bottom_footprints\":{d},\"pads\":{d},\"nets\":{d}," ++
            "\"segments\":{d},\"arcs\":{d},\"vias\":{d},\"zones\":{d}," ++
            "\"keepouts\":{d},\"outline_items\":{d}}}",
        .{
            summary.footprints,
            summary.top_footprints,
            summary.bottom_footprints,
            summary.pads,
            summary.nets,
            summary.segments,
            summary.arcs,
            summary.vias,
            summary.zones,
            summary.keepouts,
            summary.outline_items,
        },
    );
}

fn writeOutline(writer: anytype, bounds: snapshot_mod.Bounds, items: usize) !void {
    try writer.print(
        ",\"outline\":{{\"valid\":{s},\"items\":{d},\"min_x\":{d}," ++
            "\"min_y\":{d},\"max_x\":{d},\"max_y\":{d}," ++
            "\"width_mm\":{d},\"height_mm\":{d}}}",
        .{
            if (bounds.valid) "true" else "false",
            items,
            bounds.min.x,
            bounds.min.y,
            bounds.max.x,
            bounds.max.y,
            bounds.width(),
            bounds.height(),
        },
    );
}

fn writeCopper(
    writer: anytype,
    total_length: f64,
    widths: []const f64,
    layers: []const LayerMetric,
) !void {
    try writer.print(",\"copper\":{{\"track_length_mm\":{d},\"widths_mm\":[", .{total_length});
    for (widths, 0..) |width, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.print("{d}", .{width});
    }
    try writer.writeAll("],\"layers\":[");
    for (layers, 0..) |layer, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll(json_name);
        try json_writer.writeString(writer, layer.name);
        try writer.print(
            ",\"segments\":{d},\"arcs\":{d},\"zones\":{d},\"length_mm\":{d}}}",
            .{ layer.segments, layer.arcs, layer.zone_count, layer.length_mm },
        );
    }
    try writer.writeAll("]}");
}

fn writeZones(writer: anytype, board: snapshot_mod.Snapshot) !void {
    try writer.writeAll(",\"zones\":[");
    for (board.zones, 0..) |zone, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll(json_name);
        try json_writer.writeString(writer, zone.name);
        try writer.writeAll(",\"net\":");
        try json_writer.writeString(writer, zone.net);
        try writer.print(",\"keepout\":{s},\"layers\":[", .{if (zone.keepout != null) "true" else "false"});
        for (zone.layers, 0..) |layer, li| {
            if (li > 0) try writer.writeByte(',');
            try json_writer.writeString(writer, layer);
        }
        try writer.print("],\"vertices\":{d}}}", .{zone.polygon.len});
    }
    try writer.writeByte(']');
}

fn writeProject(writer: anytype, maybe_project: ?project_mod.ProjectRules) !void {
    const project = maybe_project orelse {
        try writer.writeAll(",\"project_rules\":null");
        return;
    };
    try writer.print(
        ",\"project_rules\":{{\"minimums\":{{\"clearance\":{d}," ++
            "\"track_width\":{d},\"via_diameter\":{d},\"via_drill\":{d}," ++
            "\"copper_edge_clearance\":{d}}},\"drc_exclusions\":{d}," ++
            "\"net_classes\":[",
        .{
            project.design.min_clearance,
            project.design.min_track_width,
            project.design.min_via_diameter,
            project.design.min_via_drill,
            project.design.min_copper_edge_clearance,
            project.drc_exclusion_count,
        },
    );
    for (project.net_classes, 0..) |class, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll(json_name);
        try json_writer.writeString(writer, class.name);
        try writer.print(
            ",\"priority\":{d},\"clearance\":{d},\"width\":{d}," ++
                "\"via_diameter\":{d},\"via_drill\":{d}," ++
                "\"diff_pair_width\":{d},\"diff_pair_gap\":{d}}}",
            .{
                class.priority,
                class.clearance,
                class.track_width,
                class.via_diameter,
                class.via_drill,
                class.diff_pair_width,
                class.diff_pair_gap,
            },
        );
    }
    try writer.writeAll("],\"patterns\":[");
    for (project.patterns, 0..) |pattern, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"pattern\":");
        try json_writer.writeString(writer, pattern.pattern);
        try writer.writeAll(",\"net_class\":");
        try json_writer.writeString(writer, pattern.net_class);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
}

fn writeNets(writer: anytype, nets: []const NetMetric) !void {
    try writer.writeAll(",\"nets\":[");
    for (nets, 0..) |net, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll(json_name);
        try json_writer.writeString(writer, net.name);
        try writer.print(
            ",\"pads\":{d},\"segments\":{d},\"arcs\":{d}," ++
                "\"vias\":{d},\"zones\":{d},\"length_mm\":{d}}}",
            .{ net.pads, net.segments, net.arcs, net.vias, net.zones, net.length_mm },
        );
    }
    try writer.writeByte(']');
}

fn writeAliases(writer: anytype, aliases: net_aliases.Analysis) !void {
    try writer.print(
        ",\"net_aliases\":{{\"safe_groups\":{d},\"ambiguous_groups\":{d},\"groups\":[",
        .{ aliases.safe_groups, aliases.ambiguous_groups },
    );
    for (aliases.groups, 0..) |group, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeAll("{\"canonical\":");
        try json_writer.writeString(writer, group.canonical);
        try writer.print(",\"safe\":{s},\"contacts\":{d},\"members\":[", .{
            if (group.safe) "true" else "false",
            group.contacts,
        });
        for (group.members, 0..) |member, mi| {
            if (mi > 0) try writer.writeByte(',');
            try writer.writeAll(json_name);
            try json_writer.writeString(writer, member.name);
            try writer.print(",\"pads\":{d},\"copper_items\":{d}}}", .{
                member.pads,
                member.copper_items,
            });
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}");
}

fn netMetrics(arena: std.mem.Allocator, board: snapshot_mod.Snapshot) std.mem.Allocator.Error![]const NetMetric {
    const out = try arena.alloc(NetMetric, board.nets.len);
    var index = std.StringHashMapUnmanaged(usize).empty;
    for (board.nets, 0..) |net, i| {
        out[i] = .{ .name = net.name };
        try index.put(arena, net.name, i);
    }
    for (board.footprints) |fp| for (fp.pads) |pad| if (index.get(pad.net)) |i| {
        out[i].pads += 1;
    };
    for (board.segments) |segment| if (index.get(segment.net)) |i| {
        out[i].segments += 1;
        out[i].length_mm += snapshot_mod.segmentLength(segment);
    };
    for (board.arcs) |arc| if (index.get(arc.net)) |i| {
        out[i].arcs += 1;
        out[i].length_mm += snapshot_mod.arcLength(arc);
    };
    for (board.vias) |via| {
        if (index.get(via.net)) |i| out[i].vias += 1;
    }
    for (board.zones) |zone| {
        if (index.get(zone.net)) |i| out[i].zones += 1;
    }
    return out;
}

fn layerMetrics(arena: std.mem.Allocator, board: snapshot_mod.Snapshot) std.mem.Allocator.Error![]const LayerMetric {
    var out: std.ArrayList(LayerMetric) = .empty;
    var index = std.StringHashMapUnmanaged(usize).empty;
    for (board.layers) |layer| {
        if (!layer.copper) continue;
        try index.put(arena, layer.name, out.items.len);
        try out.append(arena, .{ .name = layer.name });
    }
    for (board.segments) |segment| if (index.get(segment.layer)) |i| {
        out.items[i].segments += 1;
        out.items[i].length_mm += snapshot_mod.segmentLength(segment);
    };
    for (board.arcs) |arc| if (index.get(arc.layer)) |i| {
        out.items[i].arcs += 1;
        out.items[i].length_mm += snapshot_mod.arcLength(arc);
    };
    for (board.zones) |zone| for (zone.layers) |layer| if (index.get(layer)) |i| {
        out.items[i].zone_count += 1;
    };
    return out.items;
}

fn distinctWidths(arena: std.mem.Allocator, board: snapshot_mod.Snapshot) std.mem.Allocator.Error![]const f64 {
    var widths: std.ArrayList(f64) = .empty;
    for (board.segments) |segment| try addWidth(arena, &widths, segment.width);
    for (board.arcs) |arc| try addWidth(arena, &widths, arc.width);
    std.mem.sort(f64, widths.items, {}, std.sort.asc(f64));
    return widths.items;
}

fn addWidth(
    arena: std.mem.Allocator,
    widths: *std.ArrayList(f64),
    width: f64,
) std.mem.Allocator.Error!void {
    for (widths.items) |known| if (@abs(known - width) < 1e-9) return;
    try widths.append(arena, width);
}

test "inspection JSON includes normalized counts rules and optional nets" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = try snapshot_mod.parse(arena,
        \\(kicad_pcb (version 1) (layers (0 "F.Cu" signal))
        \\ (footprint "R" (layer "F.Cu") (property "Reference" "R1")
        \\   (pad "1" smd rect (layers "F.Cu") (net "SIG")))
        \\ (segment (start 0 0) (end 3 4) (width 0.2) (layer "F.Cu") (net "SIG")))
    );
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJson(arena, &out.writer, .{
        .board_path = "board.kicad_pcb",
        .project_path = null,
        .board = board,
        .project = null,
    }, .nets);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"track_length_mm\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"name\":\"SIG\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"net_aliases\"") != null);
}
