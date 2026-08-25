//! Persisted custom copper-zone schema and its per-layer routing/fill adapters.
//! Keeping this seam out of the already-large PCB page also gives every
//! sidecar, refill, route, and fabrication consumer one layer-expansion rule.

const std = @import("std");
const optimizer = @import("../placement/optimizer.zig");
const outline = @import("../placement/outline.zig");
const pour = @import("../placement/pour.zig");
const route_policy = @import("../placement/route_policy.zig");
const shape_sketch = @import("../shape_sketch.zig");
const pour_json = @import("pour_json.zig");

/// Persisted custom/KiCad copper-zone geometry. Declared stackup planes are
/// never represented here. `g` owns a zone stamped from a reusable subcircuit.
pub const SavedZone = struct {
    net: []const u8 = "",
    /// Primary/legacy copper layer. New multi-layer zones also carry `layers`
    /// and keep this equal to `layers[0]`, so older readers still see a valid
    /// single-layer pour instead of dropping the zone entirely.
    layer: []const u8 = "",
    /// Every routable copper layer this one authored boundary is applied to.
    /// Empty means the legacy `layer` field is authoritative.
    layers: []const []const u8 = &.{},
    poly: []const [2]f64 = &.{},
    flags: packed struct { filled: bool = false, keepout: bool = false } = .{},
    g: []const u8 = "",
    sketch: ?shape_sketch.Sketch = null,
    priority: i64 = 0,
};

/// Resolve a saved zone's native multi-layer list while keeping every legacy
/// single-`layer` record allocation-free. The caller owns the one-element
/// scratch array for the duration of the returned slice.
pub fn layers(zone: *const SavedZone, legacy: *[1][]const u8) []const []const u8 {
    if (zone.layers.len > 0) return zone.layers;
    if (zone.layer.len == 0) return &.{};
    legacy[0] = zone.layer;
    return legacy[0..];
}

/// Return the first selected layer, or the legacy single layer when present.
pub fn primaryLayer(zone: *const SavedZone) []const u8 {
    return if (zone.layers.len > 0) zone.layers[0] else zone.layer;
}

fn pourLayer(rules: optimizer.BoardRules, zone: SavedZone, layer_name: []const u8) ?u8 {
    if (!zone.flags.filled or zone.flags.keepout or zone.net.len == 0) return null;
    const layer = rules.signalIndexOfName(layer_name) orelse return null;
    if (!outline.valid(zone.poly)) return null;
    return layer;
}

/// Expand authored zones to the per-layer copper records consumed by
/// connectivity and fabrication. Legacy single-layer records expand once.
pub fn userZones(alloc: std.mem.Allocator, rules: optimizer.BoardRules, zones: []const SavedZone) []const pour.UserZone {
    var out: std.ArrayList(pour.UserZone) = .empty;
    for (zones) |zone| {
        var legacy: [1][]const u8 = undefined;
        for (layers(&zone, &legacy)) |layer_name| {
            const layer = pourLayer(rules, zone, layer_name) orelse continue;
            out.append(alloc, .{ .net = zone.net, .layer = layer, .poly = zone.poly, .priority = zone.priority }) catch return out.items;
        }
    }
    return out.items;
}

/// Build one carved-fill request per selected layer while retaining the raw
/// authored zone index used by the browser to associate fills and boundaries.
pub fn fillRequests(alloc: std.mem.Allocator, rules: optimizer.BoardRules, zones: []const SavedZone) []const pour_json.ZoneFillReq {
    const expanded = userZones(alloc, rules, zones);
    var out: std.ArrayList(pour_json.ZoneFillReq) = .empty;
    var expanded_index: usize = 0;
    for (zones, 0..) |zone, zone_index| {
        var legacy: [1][]const u8 = undefined;
        for (layers(&zone, &legacy)) |layer_name| {
            const layer = pourLayer(rules, zone, layer_name) orelse continue;
            out.append(alloc, .{
                .index = zone_index,
                .net = zone.net,
                .layer_name = layer_name,
                .side = pour.sideOfSignal(layer),
                .track_layer = layer,
                .poly = zone.poly,
                .higher = pour.higherPolys(alloc, expanded, expanded_index) catch &.{},
            }) catch return out.items;
            expanded_index += 1;
        }
    }
    return out.items;
}

fn netIndex(placement: optimizer.Placement, name: []const u8) ?i32 {
    for (placement.nets, 0..) |net, index| if (std.mem.eql(u8, net.name, name)) return @intCast(index);
    return null;
}

/// Expand pours to same-net router source copper and keepouts to hard
/// obstacles on every selected routable layer.
pub fn existingZones(alloc: std.mem.Allocator, placement: optimizer.Placement, zones: []const SavedZone) []const route_policy.ExistingZone {
    var out: std.ArrayList(route_policy.ExistingZone) = .empty;
    for (zones) |zone| {
        var legacy: [1][]const u8 = undefined;
        const layer_names = layers(&zone, &legacy);
        if (zone.flags.keepout) {
            if (zone.poly.len < 3) continue;
            for (layer_names) |layer_name| {
                const layer = placement.rules.signalIndexOfName(layer_name) orelse continue;
                out.append(alloc, .{ .polygon = zone.poly, .layer = layer, .net = -2, .tracks_blocked = true, .vias_blocked = true, .copper = false }) catch return out.items;
            }
            continue;
        }
        const ni = netIndex(placement, zone.net) orelse continue;
        for (layer_names) |layer_name| {
            const layer = pourLayer(placement.rules, zone, layer_name) orelse continue;
            out.append(alloc, .{ .polygon = zone.poly, .layer = layer, .net = ni, .copper = true, .priority = zone.priority }) catch return out.items;
        }
    }
    return out.items;
}
