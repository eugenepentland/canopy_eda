//! Read the routing-relevant portion of a KiCad `.kicad_pro` JSON file.  The
//! board carries geometry; the project carries global minimums, net classes,
//! class patterns, and DRC exclusions.  A routing benchmark needs both or it
//! will silently score candidates against the wrong constraints.

const std = @import("std");
const numeric = @import("../numeric.zig");
const design_settings = "design_settings";

/// Errors returned for malformed JSON, a non-object root, or allocation.
pub const ParseError = std.mem.Allocator.Error ||
    std.json.ParseError(std.json.Scanner) ||
    error{InvalidProject};

/// Global manufacturing and routing minimums from board.design_settings.rules.
pub const DesignRules = struct {
    min_clearance: f64 = 0,
    min_track_width: f64 = 0,
    min_via_diameter: f64 = 0,
    min_via_drill: f64 = 0,
    min_via_annular_width: f64 = 0,
    min_copper_edge_clearance: f64 = 0,
    min_hole_clearance: f64 = 0,
    min_hole_to_hole: f64 = 0,
};

/// One KiCad net class. Zero-valued geometry means that class inherits the
/// corresponding field from Default, matching KiCad's project representation.
pub const NetClass = struct {
    name: []const u8 = "",
    priority: i64 = 0,
    clearance: f64 = 0,
    track_width: f64 = 0,
    via_diameter: f64 = 0,
    via_drill: f64 = 0,
    diff_pair_width: f64 = 0,
    diff_pair_gap: f64 = 0,
    diff_pair_via_gap: f64 = 0,
};

/// A KiCad wildcard-pattern assignment such as `*RF* -> RF`.
pub const NetClassPattern = struct {
    pattern: []const u8,
    net_class: []const u8,
};

/// Routing rules normalized from a `.kicad_pro` file.
pub const ProjectRules = struct {
    design: DesignRules = .{},
    net_classes: []const NetClass = &.{},
    patterns: []const NetClassPattern = &.{},
    track_width_presets: []const f64 = &.{},
    drc_exclusion_count: usize = 0,
};

/// Parse a KiCad project JSON document. Unknown/new KiCad keys are ignored so
/// snapshots remain forward-compatible; malformed JSON is returned to caller.
pub fn parse(arena: std.mem.Allocator, source: []const u8) ParseError!ProjectRules {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, source, .{});
    if (root != .object) return error.InvalidProject;
    var result: ProjectRules = .{};

    if (path(root, &.{ "board", design_settings, "rules" })) |rules| {
        result.design = readDesignRules(rules);
    }
    if (path(root, &.{ "board", design_settings, "track_widths" })) |widths| {
        result.track_width_presets = try numberArray(arena, widths);
    }
    if (path(root, &.{ "board", design_settings, "drc_exclusions" })) |exclusions| {
        if (exclusions == .array) result.drc_exclusion_count = exclusions.array.items.len;
    }
    if (path(root, &.{ "net_settings", "classes" })) |classes| {
        result.net_classes = try readNetClasses(arena, classes);
    }
    if (path(root, &.{ "net_settings", "netclass_patterns" })) |patterns| {
        result.patterns = try readPatterns(arena, patterns);
    }
    return result;
}

fn readDesignRules(value: std.json.Value) DesignRules {
    if (value != .object) return .{};
    return .{
        .min_clearance = fieldNumber(value, "min_clearance"),
        .min_track_width = fieldNumber(value, "min_track_width"),
        .min_via_diameter = fieldNumber(value, "min_via_diameter"),
        .min_via_drill = fieldNumber(value, "min_through_hole_diameter"),
        .min_via_annular_width = fieldNumber(value, "min_via_annular_width"),
        .min_copper_edge_clearance = fieldNumber(value, "min_copper_edge_clearance"),
        .min_hole_clearance = fieldNumber(value, "min_hole_clearance"),
        .min_hole_to_hole = fieldNumber(value, "min_hole_to_hole"),
    };
}

fn readNetClasses(arena: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error![]const NetClass {
    if (value != .array) return &.{};
    var out: std.ArrayList(NetClass) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const name = fieldString(item, "name");
        if (name.len == 0) continue;
        try out.append(arena, .{
            .name = name,
            .priority = fieldInt(item, "priority"),
            .clearance = fieldNumber(item, "clearance"),
            .track_width = fieldNumber(item, "track_width"),
            .via_diameter = fieldNumber(item, "via_diameter"),
            .via_drill = fieldNumber(item, "via_drill"),
            .diff_pair_width = fieldNumber(item, "diff_pair_width"),
            .diff_pair_gap = fieldNumber(item, "diff_pair_gap"),
            .diff_pair_via_gap = fieldNumber(item, "diff_pair_via_gap"),
        });
    }
    return out.items;
}

fn readPatterns(arena: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error![]const NetClassPattern {
    if (value != .array) return &.{};
    var out: std.ArrayList(NetClassPattern) = .empty;
    for (value.array.items) |item| {
        if (item != .object) continue;
        const pattern = fieldString(item, "pattern");
        const net_class = fieldString(item, "netclass");
        if (pattern.len == 0 or net_class.len == 0) continue;
        try out.append(arena, .{ .pattern = pattern, .net_class = net_class });
    }
    return out.items;
}

fn numberArray(arena: std.mem.Allocator, value: std.json.Value) std.mem.Allocator.Error![]const f64 {
    if (value != .array) return &.{};
    var out: std.ArrayList(f64) = .empty;
    for (value.array.items) |item| if (jsonNumber(item)) |number| try out.append(arena, number);
    return out.items;
}

fn path(root: std.json.Value, keys: []const []const u8) ?std.json.Value {
    var cursor = root;
    for (keys) |key| {
        if (cursor != .object) return null;
        cursor = cursor.object.get(key) orelse return null;
    }
    return cursor;
}

fn fieldNumber(value: std.json.Value, key: []const u8) f64 {
    if (value != .object) return 0;
    return jsonNumber(value.object.get(key) orelse return 0) orelse 0;
}

fn fieldInt(value: std.json.Value, key: []const u8) i64 {
    if (value != .object) return 0;
    const item = value.object.get(key) orelse return 0;
    if (item == .integer) return item.integer;
    return numeric.checkedInt(i64, @trunc(jsonNumber(item) orelse return 0)) orelse 0;
}

fn fieldString(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    const item = value.object.get(key) orelse return "";
    return if (item == .string) item.string else "";
}

fn jsonNumber(value: std.json.Value) ?f64 {
    if (value == .integer) return @floatFromInt(value.integer);
    if (value == .float) return value.float;
    return null;
}

test "project rules retain global minima net classes and patterns" {
    const source =
        \\{
        \\  "board":{"design_settings":{
        \\    "rules":{"min_clearance":0.127,"min_track_width":0.1,"min_via_diameter":0.4,"min_through_hole_diameter":0.2},
        \\    "track_widths":[0,0.2],"drc_exclusions":[["one",""]] }},
        \\  "net_settings":{"classes":[
        \\    {"name":"Default","priority":2147483647,"track_width":0.127,"diff_pair_gap":0.1524},
        \\    {"name":"RF","priority":0,"track_width":0.3124}],
        \\    "netclass_patterns":[{"netclass":"RF","pattern":"*RF*"}]}}
    ;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try parse(arena_state.allocator(), source);
    try std.testing.expectApproxEqAbs(@as(f64, 0.127), got.design.min_clearance, 1e-9);
    try std.testing.expectEqual(@as(usize, 2), got.net_classes.len);
    try std.testing.expectEqualStrings("RF", got.net_classes[1].name);
    try std.testing.expectEqualStrings("*RF*", got.patterns[0].pattern);
    try std.testing.expectEqual(@as(usize, 1), got.drc_exclusion_count);
}

// spec: Web Server - Numeric input conversion rejects nonfinite and out-of-range values without trapping or losing integer precision
test "numeric project priority conversion preserves integers and rejects overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exact = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"priority\":9007199254740993}", .{});
    try std.testing.expectEqual(@as(i64, 9007199254740993), fieldInt(exact, "priority"));
    const huge = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"priority\":1e100}", .{});
    try std.testing.expectEqual(@as(i64, 0), fieldInt(huge, "priority"));
    const fractional = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"priority\":-1.9}", .{});
    try std.testing.expectEqual(@as(i64, -1), fieldInt(fractional, "priority"));
}
