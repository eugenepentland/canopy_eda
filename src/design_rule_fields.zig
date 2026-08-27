//! Canonical wire-key spellings for editable scalar PCB design rules.

/// One JSON wire key and its corresponding NetLisp form-head spelling.
pub const Rule = struct {
    key: []const u8,
    head: []const u8,
};

pub const pour_clearance = "pour_clearance";
pub const pour_min_width = "pour_min_width";
pub const pour_corner_radius = "pour_corner_radius";
pub const mask_relief_corner_radius = "mask_relief_corner_radius";
pub const mask_web = "mask_web";

pub const release = .{
    .web = mask_web,
    .relief_radius = mask_relief_corner_radius,
    .pour = pour_clearance,
    .pour_width = pour_min_width,
    .pour_radius = pour_corner_radius,
};

pub const scalar = [_]Rule{
    .{ .key = "clearance", .head = "clearance" },
    .{ .key = "track_width", .head = "track-width" },
    .{ .key = "min_width", .head = "min-width" },
    .{ .key = "min_drill", .head = "min-drill" },
    .{ .key = "min_annular", .head = "min-annular" },
    .{ .key = "hole_to_hole", .head = "hole-to-hole" },
    .{ .key = "via_to_via", .head = "via-to-via" },
    .{ .key = "via_plating", .head = "via-plating" },
    .{ .key = "copper_edge", .head = "copper-edge" },
    .{ .key = "component_edge", .head = "component-edge" },
    .{ .key = pour_clearance, .head = "pour-clearance" },
    .{ .key = pour_min_width, .head = "pour-min-width" },
    .{ .key = pour_corner_radius, .head = "pour-corner-radius" },
    .{ .key = "ground_via_max", .head = "ground-via-max" },
    .{ .key = "mask_margin", .head = "mask-margin" },
    .{ .key = mask_relief_corner_radius, .head = "mask-relief-corner-radius" },
    .{ .key = mask_web, .head = "mask-web" },
};
