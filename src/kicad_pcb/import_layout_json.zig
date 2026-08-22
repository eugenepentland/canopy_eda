//! Stable-order JSON rendering of an `import_layout.Report` — the machine
//! half of the `import-kicad-layout` CLI output (route_command's writeResult
//! is the house style). Field order never varies, so downstream tooling and
//! the fidelity gate can diff two runs textually.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const import_layout = @import("import_layout.zig");

/// JSON emission targets an allocator-backed writer (the `json_writer`
/// contract shared with route_command), so the only failure is allocation.
pub const WriteError = json_writer.WriteError;

/// Render the full import report as one JSON object with stable field order:
/// match → net_aliases → net_map → copper → zones → outline → per_net.
pub fn writeReport(w: anytype, report: import_layout.Report) WriteError!void {
    try w.writeAll("{\"match\":");
    try writeMatch(w, report.match);
    try w.writeAll(",\"net_aliases\":");
    try writeAliases(w, report.aliases);
    try w.writeAll(",\"net_map\":");
    try writeNetMap(w, report.net_map);
    try w.writeAll(",\"copper\":");
    try writeCopper(w, report.copper);
    try w.writeAll(",\"zones\":");
    try writeZones(w, report.zones);
    try w.print(
        ",\"outline\":{{\"points\":{d},\"fallback\":{s}}}",
        .{ report.outline.points, jsonBool(report.outline.fallback) },
    );
    try w.writeAll(",\"per_net\":");
    try writePerNet(w, report.per_net);
    try w.writeAll("}");
}

fn writeMatch(w: anytype, match: import_layout.MatchReport) WriteError!void {
    try w.print("{{\"by_uuid\":{d},\"by_ref\":{d},\"unmatched_board\":", .{
        match.by_uuid,
        match.by_ref,
    });
    try writeNames(w, match.unmatched_board);
    try w.writeAll(",\"unmatched_design\":");
    try writeNames(w, match.unmatched_design);
    try w.writeAll("}");
}

fn writeAliases(w: anytype, aliases: import_layout.AliasReport) WriteError!void {
    try w.print("{{\"safe_groups\":{d},\"ambiguous_groups\":{d},\"folded\":[", .{
        aliases.safe_groups,
        aliases.ambiguous_groups,
    });
    for (aliases.folds, 0..) |fold, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"canonical\":");
        try json_writer.writeString(w, fold.canonical);
        try w.writeAll(",\"aliases\":");
        try writeNames(w, fold.aliases);
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

fn writeNetMap(w: anytype, map: import_layout.NetMapReport) WriteError!void {
    try w.print("{{\"identical\":{d},\"renamed\":{d},\"renames\":[", .{
        map.identical,
        map.renamed,
    });
    for (map.renames, 0..) |rename, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"board\":");
        try json_writer.writeString(w, rename.board);
        try w.writeAll(",\"design\":");
        try json_writer.writeString(w, rename.design);
        try w.writeAll("}");
    }
    try w.writeAll("],\"ambiguous\":[");
    for (map.ambiguous, 0..) |amb, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"board\":");
        try json_writer.writeString(w, amb.board);
        try w.writeAll(",\"candidates\":");
        try writeNames(w, amb.candidates);
        try w.writeAll("}");
    }
    try w.writeAll("],\"unmatched\":");
    try writeNames(w, map.unmatched);
    try w.writeAll("}");
}

fn writeCopper(w: anytype, copper: import_layout.CopperReport) WriteError!void {
    try w.print("{{\"tracks\":{d},\"vias\":{d},\"non_through_vias\":{d},\"per_layer\":[", .{
        copper.tracks,
        copper.vias,
        copper.non_through_vias,
    });
    for (copper.per_layer, 0..) |layer, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"layer\":");
        try json_writer.writeString(w, layer.layer);
        try w.print(",\"tracks\":{d},\"mm\":{d:.6}}}", .{ layer.tracks, layer.mm });
    }
    try w.print("],\"arcs\":{{\"count\":{d},\"segments\":{d},\"max_chord_error_mm\":{d:.6}}}", .{
        copper.arcs.count,
        copper.arcs.segments,
        copper.arcs.max_chord_error_mm,
    });
    try w.writeAll(",\"dropped\":[");
    for (copper.dropped, 0..) |drop, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"layer\":");
        try json_writer.writeString(w, drop.layer);
        try w.writeAll(",\"net\":");
        try json_writer.writeString(w, drop.net);
        try w.print(",\"length_mm\":{d:.6}}}", .{drop.length_mm});
    }
    try w.writeAll("]}");
}

fn writeZones(w: anytype, zones: import_layout.ZoneReport) WriteError!void {
    try w.writeAll("{\"zones\":[");
    for (zones.zones, 0..) |zone, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try json_writer.writeString(w, zone.net);
        try w.writeAll(",\"layers\":");
        try writeNames(w, zone.layers);
        try w.print(",\"keepout\":{s}}}", .{jsonBool(zone.keepout)});
    }
    try w.writeAll("],\"pour_fed\":");
    try writeNames(w, zones.pour_fed);
    try w.writeAll("}");
}

fn writePerNet(w: anytype, per_net: []const import_layout.NetCopper) WriteError!void {
    try w.writeAll("[");
    for (per_net, 0..) |net, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"net\":");
        try json_writer.writeString(w, net.net);
        try w.print(",\"mm\":{d:.6},\"vias\":{d}}}", .{ net.mm, net.vias });
    }
    try w.writeAll("]");
}

/// The literal JSON spelling of a bool value.
fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn writeNames(w: anytype, names: []const []const u8) WriteError!void {
    try w.writeAll("[");
    for (names, 0..) |name, i| {
        if (i > 0) try w.writeAll(",");
        try json_writer.writeString(w, name);
    }
    try w.writeAll("]");
}

// ── Tests ───────────────────────────────────────────────────────────────────

const snapshot = @import("snapshot.zig");

/// Test shorthand: run the importer on a board with no design side and the
/// legacy 2-signal-layer rules.
fn buildBoard(arena: std.mem.Allocator, board: snapshot.Snapshot) import_layout.Error!import_layout.Imported {
    return import_layout.build(
        arena,
        .{ .board = board, .instances = &.{}, .nets = &.{}, .rules = .{} },
        .{},
    );
}

// spec: kicad_pcb/import-layout - every via imports as a through via and spans other than outer-to-outer are counted
test "vias import as through vias with odd spans counted" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{.{ .name = "SIG" }},
        .vias = &.{
            .{ .at = .{ .x = 1, .y = 2 }, .size = 0.4, .drill = 0.2, .layers = &.{ "F.Cu", "B.Cu" }, .net = "SIG" },
            .{ .at = .{ .x = 3, .y = 4 }, .size = 0.4, .drill = 0.2, .layers = &.{ "F.Cu", "In2.Cu" }, .net = "SIG" },
        },
    };
    const got = try buildBoard(arena, board);
    try std.testing.expectEqual(@as(usize, 2), got.vias.len);
    try std.testing.expectEqual(@as(usize, 1), got.report.copper.non_through_vias);
    try std.testing.expectEqual(@as(f64, 0.4), got.vias[1].dia);
    try std.testing.expectEqual(@as(f64, 0.2), got.vias[1].drill);
    try std.testing.expectEqualStrings("SIG", got.vias[0].net);
}

// spec: kicad_pcb/import-layout - zone boundaries/fills are imported with mapped net/layer geometry and keepouts stay nonconductive
test "zones preserve boundaries and fills while keepouts remain explicit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{.{ .name = "GND" }},
        .zones = &.{
            .{
                .net = "GND",
                .layers = &.{"In1.Cu"},
                .polygon = &.{ .{ .x = 0, .y = 0 }, .{ .x = 9, .y = 0 }, .{ .x = 9, .y = 9 } },
                .filled = &.{.{
                    .layer = "In1.Cu",
                    .polygon = &.{ .{ .x = 0.1, .y = 0.1 }, .{ .x = 8.9, .y = 0.1 }, .{ .x = 8.9, .y = 8.9 } },
                }},
            },
            .{
                .net = "",
                .layers = &.{"F.Cu"},
                .keepout = .{ .tracks_allowed = false },
                .polygon = &.{ .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 2 }, .{ .x = 3, .y = 3 } },
            },
        },
    };
    const got = try buildBoard(arena, board);
    try std.testing.expectEqual(@as(usize, 0), got.tracks.len);
    try std.testing.expectEqual(@as(usize, 3), got.zones.len);
    try std.testing.expectEqualStrings("GND", got.zones[0].net);
    try std.testing.expectEqualStrings("In1.Cu", got.zones[0].layer);
    try std.testing.expect(!got.zones[0].filled);
    try std.testing.expect(got.zones[1].filled);
    try std.testing.expectApproxEqAbs(@as(f64, 8.9), got.zones[1].poly[2][0], 1e-9);
    try std.testing.expect(got.zones[2].keepout);
    try std.testing.expectEqualStrings("", got.zones[2].net);
    try std.testing.expectEqual(@as(usize, 2), got.report.zones.zones.len);
    try std.testing.expectEqualStrings("GND", got.report.zones.zones[0].net);
    try std.testing.expectEqualStrings("In1.Cu", got.report.zones.zones[0].layers[0]);
    try std.testing.expect(!got.report.zones.zones[0].keepout);
    try std.testing.expect(got.report.zones.zones[1].keepout);
}

// spec: kicad_pcb/import-layout - a pour-fed rail with under five millimetres of imported track is reported
test "a rail served by a pour rather than tracks is flagged pour-fed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{ .{ .name = "V_12V" }, .{ .name = "SIG" } },
        .segments = &.{.{
            .start = .{ .x = 0, .y = 50 },
            .end = .{ .x = 30, .y = 50 },
            .width = 0.3,
            .layer = "F.Cu",
            .net = "SIG",
        }},
        .zones = &.{
            .{ .net = "V_12V", .layers = &.{"In2.Cu"} },
            .{ .net = "SIG", .layers = &.{"F.Cu"} },
        },
    };
    const got = try buildBoard(arena, board);
    try std.testing.expectEqual(@as(usize, 1), got.report.zones.pour_fed.len);
    try std.testing.expectEqualStrings("V_12V", got.report.zones.pour_fed[0]);
}

// spec: kicad_pcb/import-layout - per-net imported track length and via count are reported
test "per-net totals accumulate track millimetres and via counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const board = snapshot.Snapshot{
        .nets = &.{.{ .name = "SIG" }},
        .segments = &.{
            .{
                .start = .{ .x = 0, .y = 50 },
                .end = .{ .x = 3, .y = 54 },
                .width = 0.2,
                .layer = "F.Cu",
                .net = "SIG",
            },
            .{
                .start = .{ .x = 3, .y = 54 },
                .end = .{ .x = 3, .y = 56 },
                .width = 0.2,
                .layer = "B.Cu",
                .net = "SIG",
            },
        },
        .vias = &.{.{
            .at = .{ .x = 3, .y = 54 },
            .size = 0.4,
            .drill = 0.2,
            .layers = &.{ "F.Cu", "B.Cu" },
            .net = "SIG",
        }},
    };
    const got = try buildBoard(arena, board);
    try std.testing.expectEqual(@as(usize, 1), got.report.per_net.len);
    try std.testing.expectEqualStrings("SIG", got.report.per_net[0].net);
    try std.testing.expectApproxEqAbs(@as(f64, 7), got.report.per_net[0].mm, 1e-9);
    try std.testing.expectEqual(@as(usize, 1), got.report.per_net[0].vias);
    try std.testing.expectApproxEqAbs(@as(f64, 5), got.report.copper.per_layer[0].mm, 1e-9);
    try std.testing.expectEqualStrings("B.Cu", got.report.copper.per_layer[1].layer);
}

// spec: kicad_pcb/import-layout - an empty board yields no poses, no copper, and a flagged empty outline
test "an empty board imports nothing and flags the missing outline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const got = try buildBoard(arena, .{});
    try std.testing.expectEqual(@as(usize, 0), got.poses.len);
    try std.testing.expectEqual(@as(usize, 0), got.tracks.len);
    try std.testing.expectEqual(@as(usize, 0), got.vias.len);
    try std.testing.expectEqual(@as(usize, 0), got.outline.pts.len);
    try std.testing.expect(got.outline.fallback);
    try std.testing.expectEqual(@as(usize, 0), got.report.per_net.len);
}

// spec: kicad_pcb/import-layout - the report renders as one stable json object
test "the report JSON field order is stable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = import_layout.Report{
        .match = .{ .by_uuid = 2, .by_ref = 1, .unmatched_board = &.{"J9"} },
        .aliases = .{ .safe_groups = 1, .folds = &.{.{ .canonical = "RF1_A", .aliases = &.{"BPF_RF"} }} },
        .net_map = .{ .identical = 3, .renamed = 1, .renames = &.{.{ .board = "VCC_IN", .design = "VDD" }} },
        .copper = .{
            .tracks = 2,
            .vias = 1,
            .per_layer = &.{.{ .layer = "F.Cu", .tracks = 2, .mm = 5 }},
            .dropped = &.{.{ .layer = "In2.Cu", .net = "SIG", .length_mm = 1.5 }},
        },
        .zones = .{ .zones = &.{.{ .net = "GND", .layers = &.{"In1.Cu"} }}, .pour_fed = &.{"GND"} },
        .outline = .{ .points = 4 },
        .per_net = &.{.{ .net = "VDD", .mm = 5, .vias = 1 }},
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try writeReport(&out.writer, report);
    try std.testing.expectEqualStrings(
        "{\"match\":{\"by_uuid\":2,\"by_ref\":1,\"unmatched_board\":[\"J9\"],\"unmatched_design\":[]}," ++
            "\"net_aliases\":{\"safe_groups\":1,\"ambiguous_groups\":0," ++
            "\"folded\":[{\"canonical\":\"RF1_A\",\"aliases\":[\"BPF_RF\"]}]}," ++
            "\"net_map\":{\"identical\":3,\"renamed\":1," ++
            "\"renames\":[{\"board\":\"VCC_IN\",\"design\":\"VDD\"}],\"ambiguous\":[],\"unmatched\":[]}," ++
            "\"copper\":{\"tracks\":2,\"vias\":1,\"non_through_vias\":0," ++
            "\"per_layer\":[{\"layer\":\"F.Cu\",\"tracks\":2,\"mm\":5.000000}]," ++
            "\"arcs\":{\"count\":0,\"segments\":0,\"max_chord_error_mm\":0.000000}," ++
            "\"dropped\":[{\"layer\":\"In2.Cu\",\"net\":\"SIG\",\"length_mm\":1.500000}]}," ++
            "\"zones\":{\"zones\":[{\"net\":\"GND\",\"layers\":[\"In1.Cu\"],\"keepout\":false}]," ++
            "\"pour_fed\":[\"GND\"]}," ++
            "\"outline\":{\"points\":4,\"fallback\":false}," ++
            "\"per_net\":[{\"net\":\"VDD\",\"mm\":5.000000,\"vias\":1}]}",
        out.written(),
    );
}
