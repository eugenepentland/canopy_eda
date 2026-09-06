//! Datasheet-driven IC package geometry shared by the browser and command line.
const std = @import("std");
const step = @import("pcb_step_export.zig");
const parser = @import("../sexpr/parser.zig");
const library = @import("library.zig");
const json_writer = @import("../json_writer.zig");

pub const Family = enum { qfn, dfn, soic, tssop, qfp };
pub const Body = struct { width: f64 = 4, length: f64 = 4, height: f64 = 0.9, standoff: f64 = 0.05 };
pub const Leads = struct { pitch: f64 = 0.5, width: f64 = 0.25, length: f64 = 0.4, thickness: f64 = 0.15, span_x: f64 = 4, span_y: f64 = 4 };
pub const Lands = struct {
    mode: enum { datasheet, allowances } = .datasheet,
    width: f64 = 0.3,
    length: f64 = 0.75,
    span_x: f64 = 3.9,
    span_y: f64 = 3.9,
    toe: f64 = 0,
    heel: f64 = 0,
    side: f64 = 0,
};
pub const Exposed = struct {
    enabled: bool = false,
    id: []const u8 = "25",
    width: f64 = 2.5,
    length: f64 = 2.5,
    land_width: f64 = 2.5,
    land_length: f64 = 2.5,
    paste_rows: u16 = 2,
    paste_columns: u16 = 2,
    paste_gap: f64 = 0.3,
    paste_margin: f64 = 0.15,
};
pub const Aperture = @import("../footprint_paste.zig").Aperture;
pub const Pad = struct {
    key: []const u8,
    id: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    type: []const u8 = "smd",
    shape: []const u8 = "rect",
    drill_x: f64 = 0,
    drill_y: f64 = 0,
    roundrect_ratio: ?f64 = null,
    mask_margin: ?f64 = null,
    no_paste: bool = false,
    poly: ?[]const [2]f64 = null,
    paste: ?[]const Aperture = null,
};
pub const Override = struct {
    key: []const u8,
    remove: bool = false,
    clear_fields: []const []const u8 = &.{},
    id: ?[]const u8 = null,
    x: ?f64 = null,
    y: ?f64 = null,
    w: ?f64 = null,
    h: ?f64 = null,
    type: ?[]const u8 = null,
    shape: ?[]const u8 = null,
    drill_x: ?f64 = null,
    drill_y: ?f64 = null,
    roundrect_ratio: ?f64 = null,
    mask_margin: ?f64 = null,
    no_paste: ?bool = null,
    poly: ?[]const [2]f64 = null,
    paste: ?[]const Aperture = null,
};
pub const Artwork = struct { courtyard: ?[]const u8 = null, silk: ?[]const u8 = null, fab: ?[]const u8 = null };
pub const Recipe = struct {
    schema: []const u8 = "netlisp-package-v1",
    revision: ?[]const u8 = null,
    footprint_hash: []const u8 = "",
    model_hash: []const u8 = "",
    name: []const u8 = "new-package",
    family: Family = .qfn,
    dimensions_verified: bool = false,
    datasheet: []const u8 = "",
    datasheet_page: u16 = 1,
    body: Body = .{},
    leads: Leads = .{},
    lands: Lands = .{},
    pins_x: u16 = 6,
    pins_y: u16 = 6,
    clockwise: bool = false,
    rotation: u16 = 0,
    exposed: Exposed = .{},
    courtyard: f64 = 0.25,
    overrides: []const Override = &.{},
    additions: []const Pad = &.{},
    artwork: Artwork = .{},
};
pub const Diagnostic = struct { field: []const u8, message: []const u8, severity: enum { @"error", warning } = .@"error" };
pub const Result = struct {
    recipe: Recipe,
    pads: []const Pad,
    footprint: []const u8,
    step: []const u8,
    svg: []const u8,
    diagnostics: []const Diagnostic,
};

/// Parse a bounded, versioned recipe; unknown fields are errors, never silently lost.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) (std.json.ParseError(std.json.Scanner) || error{ RecipeTooLarge, UnsupportedSchema })!Recipe {
    if (bytes.len > 256 * 1024) return error.RecipeTooLarge;
    const r = try std.json.parseFromSliceLeaky(Recipe, allocator, bytes, .{});
    if (!std.mem.eql(u8, r.schema, "netlisp-package-v1")) return error.UnsupportedSchema;
    return r;
}

/// Example dimensions are explicitly unverified until the author reviews them.
pub fn template(family: Family) Recipe {
    var r: Recipe = .{ .family = family };
    switch (family) {
        .qfn => {},
        .dfn => {
            r.pins_x = 0;
            r.pins_y = 3;
        },
        .soic, .tssop => {
            r.pins_x = 0;
            r.pins_y = 4;
            r.body = .{ .width = 3.9, .length = 4.9, .height = 1.75, .standoff = 0.15 };
            r.leads = .{ .pitch = 1.27, .width = 0.4, .length = 0.6, .thickness = 0.2, .span_x = 6, .span_y = 4.9 };
            r.lands = .{ .width = 0.6, .length = 1.5, .span_x = 5.4, .span_y = 4.9 };
            if (family == .tssop) {
                r.pins_y = 7;
                r.leads.pitch = 0.65;
                r.leads.width = 0.25;
                r.lands.width = 0.35;
                r.body.height = 1.2;
            }
        },
        .qfp => {
            r.body = .{ .width = 7, .length = 7, .height = 1.4, .standoff = 0.1 };
            r.pins_x = 12;
            r.pins_y = 12;
            r.leads.span_x = 9;
            r.leads.span_y = 9;
            r.leads.length = 0.6;
            r.lands.span_x = 8.4;
            r.lands.span_y = 8.4;
            r.lands.length = 1.5;
        },
    }
    return r;
}

fn diagnostic(a: std.mem.Allocator, list: *std.ArrayList(Diagnostic), field: []const u8, message: []const u8) !void {
    try list.append(a, .{ .field = field, .message = message });
}
fn positive(x: f64) bool {
    return std.math.isFinite(x) and x > 0 and x <= 1000;
}
fn nonnegative(x: f64) bool {
    return std.math.isFinite(x) and x >= 0 and x <= 1000;
}
fn leaded(r: Recipe) bool {
    return r.family == .soic or r.family == .tssop or r.family == .qfp;
}

/// Validate dimensions before any arithmetic, allocation, or file mutation.
pub fn validate(a: std.mem.Allocator, r: Recipe) std.mem.Allocator.Error![]const Diagnostic {
    var d: std.ArrayList(Diagnostic) = .empty;
    if (!library.isSafeLibName(r.name) or r.name.len > 100) try diagnostic(a, &d, "name", "Use a library basename of at most 100 characters");
    inline for (.{ "width", "length", "height" }) |field| {
        if (!positive(@field(r.body, field))) try diagnostic(a, &d, "body." ++ field, "Must be finite and between 0 and 1000 mm");
    }
    if (!nonnegative(r.body.standoff) or r.body.standoff >= r.body.height) try diagnostic(a, &d, "body.standoff", "Must be below overall package height");
    inline for (.{ "pitch", "width", "length", "thickness", "span_x", "span_y" }) |field| {
        if (!positive(@field(r.leads, field))) try diagnostic(a, &d, "leads." ++ field, "Must be finite and positive");
    }
    if (r.leads.width >= r.leads.pitch) try diagnostic(a, &d, "leads.width", "Terminal width must be smaller than pitch");
    if (r.leads.thickness >= r.body.height) try diagnostic(a, &d, "leads.thickness", "Terminal thickness must be smaller than package height");
    if (r.pins_y == 0 or r.pins_x > 128 or r.pins_y > 128) try diagnostic(a, &d, "pins_y", "Use 1–128 pins per populated side");
    if ((r.family == .qfn or r.family == .qfp) and r.pins_x == 0) try diagnostic(a, &d, "pins_x", "Four-sided packages require pins on each side");
    if ((r.family == .dfn or r.family == .soic or r.family == .tssop) and r.pins_x != 0) try diagnostic(a, &d, "pins_x", "Two-sided packages have zero pins on top and bottom");
    if (r.rotation >= 360 or r.rotation % 90 != 0) try diagnostic(a, &d, "rotation", "Use 0, 90, 180, or 270 degrees");
    if (!nonnegative(r.courtyard)) try diagnostic(a, &d, "courtyard", "Clearance must be finite and nonnegative");
    if (@as(f64, @floatFromInt(r.pins_y -| 1)) * r.leads.pitch + r.leads.width > r.body.length) try diagnostic(a, &d, "pins_y", "Terminal row exceeds body length");
    if (r.pins_x > 0 and @as(f64, @floatFromInt(r.pins_x -| 1)) * r.leads.pitch + r.leads.width > r.body.width) try diagnostic(a, &d, "pins_x", "Terminal row exceeds body width");
    if (leaded(r)) {
        if (r.leads.thickness > (r.body.height - r.body.standoff) / 2) try diagnostic(a, &d, "leads.thickness", "Lead insertion must fit within the body height");
        if (r.leads.span_x <= r.body.width + 2 * r.leads.length or (r.pins_x > 0 and r.leads.span_y <= r.body.length + 2 * r.leads.length)) try diagnostic(a, &d, "leads.span_x", "Lead span must leave room for the foot and sloping lead between foot and body");
    } else if (@abs(r.leads.span_x - r.body.width) > 0.001 or (r.pins_x > 0 and @abs(r.leads.span_y - r.body.length) > 0.001)) {
        try diagnostic(a, &d, "leads.span_x", "Leadless terminal outer span must match the body dimensions");
    }
    try validateLands(a, r, &d);
    if (r.overrides.len > 1024 or r.additions.len > 512) try diagnostic(a, &d, "overrides", "Too many manual edits");
    return d.toOwnedSlice(a);
}

fn validateLands(a: std.mem.Allocator, r: Recipe, d: *std.ArrayList(Diagnostic)) !void {
    if (r.lands.mode == .datasheet) {
        inline for (.{ "width", "length", "span_x", "span_y" }) |field| {
            if (!positive(@field(r.lands, field))) try diagnostic(a, d, "lands." ++ field, "Enter the recommended land dimensions; spans are opposing pad-center distances");
        }
    } else {
        inline for (.{ "toe", "heel", "side" }) |field| {
            if (!nonnegative(@field(r.lands, field))) try diagnostic(a, d, "lands." ++ field, "Enter an explicit nonnegative allowance");
        }
    }
    const ep = r.exposed;
    if (ep.enabled) {
        inline for (.{ "width", "length", "land_width", "land_length" }) |field| {
            if (!positive(@field(ep, field))) try diagnostic(a, d, "exposed." ++ field, "Exposed pad dimensions must be finite and positive");
        }
        if (ep.width >= r.body.width or ep.length >= r.body.length) try diagnostic(a, d, "exposed.width", "Physical exposed pad must fit within the package body");
        if (ep.paste_rows == 0 or ep.paste_columns == 0 or ep.paste_rows > 16 or ep.paste_columns > 16) try diagnostic(a, d, "exposed.paste_rows", "Use 1–16 rows and columns");
        if (!nonnegative(ep.paste_gap) or !nonnegative(ep.paste_margin)) try diagnostic(a, d, "exposed.paste_gap", "Paste gap and margin must be nonnegative");
        if (ep.land_width - 2 * ep.paste_margin - @as(f64, @floatFromInt(ep.paste_columns -| 1)) * ep.paste_gap <= 0 or ep.land_length - 2 * ep.paste_margin - @as(f64, @floatFromInt(ep.paste_rows -| 1)) * ep.paste_gap <= 0) try diagnostic(a, d, "exposed.paste_margin", "Paste windows must have positive area");
    }
}

fn rotate(p: [2]f64, angle: u16) [2]f64 {
    return switch (angle) {
        90 => .{ -p[1], p[0] },
        180 => .{ -p[0], -p[1] },
        270 => .{ p[1], -p[0] },
        else => p,
    };
}
fn rotatedPad(p: *Pad, angle: u16) void {
    const q = rotate(.{ p.x, p.y }, angle);
    p.x = q[0];
    p.y = q[1];
    if (angle == 90 or angle == 270) std.mem.swap(f64, &p.w, &p.h);
}
fn patch(p: *Pad, o: Override) void {
    for (o.clear_fields) |field| {
        inline for (.{ "roundrect_ratio", "mask_margin", "poly", "paste" }) |key| {
            if (std.mem.eql(u8, field, key)) @field(p, key) = null;
        }
    }
    inline for (.{ "id", "x", "y", "w", "h", "type", "shape", "drill_x", "drill_y", "roundrect_ratio", "mask_margin", "no_paste", "poly", "paste" }) |field| {
        if (@field(o, field)) |v| @field(p, field) = v;
    }
}

/// Generate the immutable baseline pad identities; overrides bind to side/ordinal, not array indices.
pub fn basePads(a: std.mem.Allocator, r: Recipe) std.mem.Allocator.Error![]Pad {
    var pads: std.ArrayList(Pad) = .empty;
    const counts = [4]u16{ r.pins_y, r.pins_x, r.pins_y, r.pins_x };
    const total = 2 * (@as(u32, r.pins_x) + r.pins_y);
    var number: u32 = 1;
    for (counts, 0..) |count, side| for (0..count) |i| {
        const along = (@as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(count - 1)) / 2) * r.leads.pitch;
        const horizontal = side == 0 or side == 2;
        const span = if (horizontal) r.leads.span_x else r.leads.span_y;
        const land_length = if (r.lands.mode == .datasheet) r.lands.length else r.leads.length + r.lands.toe + r.lands.heel;
        const land_width = if (r.lands.mode == .datasheet) r.lands.width else r.leads.width + 2 * r.lands.side;
        const center = if (r.lands.mode == .datasheet) (if (horizontal) r.lands.span_x else r.lands.span_y) / 2 else (span - r.leads.length + r.lands.toe - r.lands.heel) / 2;
        const xy: [2]f64 = switch (side) {
            0 => .{ -center, along },
            1 => .{ along, center },
            2 => .{ center, -along },
            else => .{ -along, -center },
        };
        var p: Pad = .{ .key = try std.fmt.allocPrint(a, "side-{d}-{d}", .{ side, i }), .id = try std.fmt.allocPrint(a, "{d}", .{if (r.clockwise and number > 1) total - number + 2 else number}), .x = xy[0], .y = xy[1], .w = if (horizontal) land_length else land_width, .h = if (horizontal) land_width else land_length };
        rotatedPad(&p, r.rotation);
        try pads.append(a, p);
        number += 1;
    };
    if (r.exposed.enabled) {
        const ep = r.exposed;
        var windows: std.ArrayList(Aperture) = .empty;
        const columns: f64 = @floatFromInt(ep.paste_columns);
        const rows: f64 = @floatFromInt(ep.paste_rows);
        const width = (ep.land_width - 2 * ep.paste_margin - (columns - 1) * ep.paste_gap) / columns;
        const length = (ep.land_length - 2 * ep.paste_margin - (rows - 1) * ep.paste_gap) / rows;
        for (0..ep.paste_rows) |y| for (0..ep.paste_columns) |x| {
            const pt = rotate(.{ (@as(f64, @floatFromInt(x)) - (columns - 1) / 2) * (width + ep.paste_gap), (@as(f64, @floatFromInt(y)) - (rows - 1) / 2) * (length + ep.paste_gap) }, r.rotation);
            try windows.append(a, .{ .x = pt[0], .y = pt[1], .w = if (r.rotation % 180 == 0) width else length, .h = if (r.rotation % 180 == 0) length else width });
        };
        var p: Pad = .{ .key = "exposed", .id = ep.id, .x = 0, .y = 0, .w = ep.land_width, .h = ep.land_length, .paste = try windows.toOwnedSlice(a) };
        rotatedPad(&p, r.rotation);
        try pads.append(a, p);
    }
    return pads.toOwnedSlice(a);
}

fn validPad(p: Pad) bool {
    const types = [_][]const u8{ "smd", "thru", "npth" };
    const shapes = [_][]const u8{ "rect", "roundrect", "oval", "circle", "custom" };
    var type_ok = false;
    for (types) |t| {
        if (std.mem.eql(u8, t, p.type)) type_ok = true;
    }
    var shape_ok = false;
    for (shapes) |t| {
        if (std.mem.eql(u8, t, p.shape)) shape_ok = true;
    }
    if (!type_ok or !shape_ok) return false;
    if (std.mem.eql(u8, p.shape, "custom") and p.poly == null) return false;
    if (p.id.len == 0 or p.id.len > 64) return false;
    if (!std.math.isFinite(p.x) or !std.math.isFinite(p.y)) return false;
    if (@abs(p.x) > 1000 or @abs(p.y) > 1000) return false;
    if (!positive(p.w) or !positive(p.h)) return false;
    if (!nonnegative(p.drill_x) or !nonnegative(p.drill_y)) return false;
    if (p.mask_margin) |v| if (!std.math.isFinite(v) or @abs(v) > 1000) return false;
    if (p.roundrect_ratio) |v| if (!std.math.isFinite(v) or v < 0 or v > 0.5) return false;
    if (p.poly) |poly| {
        if (poly.len < 3 or poly.len > 2048) return false;
        for (poly) |pt| for (pt) |v| {
            if (!std.math.isFinite(v) or @abs(v) > 1000) return false;
        };
    }
    if (p.paste) |windows| if (!@import("../footprint_paste.zig").valid(windows, p.w, p.h)) return false;
    return true;
}

/// Generate final pads and diagnostics, retaining explicit overrides and reporting lost targets.
pub fn finalPads(a: std.mem.Allocator, r: Recipe, d: *std.ArrayList(Diagnostic)) std.mem.Allocator.Error![]const Pad {
    const base = try basePads(a, r);
    var pads: std.ArrayList(Pad) = .empty;
    for (r.overrides, 0..) |o, i| {
        var found = false;
        for (base) |p| {
            if (std.mem.eql(u8, p.key, o.key)) found = true;
        }
        if (!found) try diagnostic(a, d, "overrides", try std.fmt.allocPrint(a, "Override target {s} no longer exists; remap or remove it", .{o.key}));
        for (r.overrides[0..i]) |prev| if (std.mem.eql(u8, prev.key, o.key)) {
            try diagnostic(a, d, "overrides", "Duplicate override target");
        };
    }
    for (base) |original| {
        var p = original;
        var removed = false;
        for (r.overrides) |o| if (std.mem.eql(u8, p.key, o.key)) {
            patch(&p, o);
            removed = o.remove;
        };
        if (!removed) try pads.append(a, p);
    }
    try pads.appendSlice(a, r.additions);
    for (pads.items, 0..) |p, i| {
        if (!validPad(p)) try diagnostic(a, d, "overrides", try std.fmt.allocPrint(a, "Invalid pad or paste geometry for {s}", .{p.key}));
        for (pads.items[0..i]) |q| {
            if (std.mem.eql(u8, p.key, q.key)) try diagnostic(a, d, "overrides", "Pad identities must be unique");
            if (std.mem.eql(u8, p.id, q.id)) try diagnostic(a, d, "numbering", "Pad numbers must be unique");
            if (@abs(p.x - q.x) < (p.w + q.w) / 2 - 1e-8 and @abs(p.y - q.y) < (p.h + q.h) / 2 - 1e-8) try diagnostic(a, d, "lands", "Copper lands overlap");
        }
        for (base) |q| if (std.mem.eql(u8, q.key, p.key) and (@abs(p.x - q.x) > r.leads.width or @abs(p.y - q.y) > r.leads.width)) {
            try d.append(a, .{ .field = "overrides", .message = try std.fmt.allocPrint(a, "Pad {s} moved relative to its physical terminal; inspect the 3D overlay", .{p.id}), .severity = .warning });
        };
    }
    return pads.toOwnedSlice(a);
}

/// True if generation diagnostics contain a blocking error.
pub fn hasErrors(d: []const Diagnostic) bool {
    for (d) |v| if (v.severity == .@"error") return true;
    return false;
}

fn rectProfile(a: std.mem.Allocator, width: f64, length: f64) ![]const [2]f64 {
    return a.dupe([2]f64, &.{ .{ -width / 2, -length / 2 }, .{ width / 2, -length / 2 }, .{ width / 2, length / 2 }, .{ -width / 2, length / 2 } });
}
fn transformSolid(s: *step.Extrusion, rotation: u16) void {
    // Footprint Y points south; STEP uses right-handed north/up axes.
    const angle: u16 = if (rotation == 0) 0 else 360 - rotation;
    const origin = rotate(.{ s.origin[0], s.origin[1] }, angle);
    s.origin[0] = origin[0];
    s.origin[1] = origin[1];
    const x = rotate(.{ s.x_axis[0], s.x_axis[1] }, angle);
    s.x_axis[0] = x[0];
    s.x_axis[1] = x[1];
    const z = rotate(.{ s.z_axis[0], s.z_axis[1] }, angle);
    s.z_axis[0] = z[0];
    s.z_axis[1] = z[1];
}
fn solids(a: std.mem.Allocator, r: Recipe) ![]const step.Extrusion {
    var list: std.ArrayList(step.Extrusion) = .empty;
    try list.append(a, .{ .name = "Body", .outline = try rectProfile(a, r.body.width, r.body.length), .thickness = r.body.height - r.body.standoff, .origin = .{ 0, 0, r.body.height }, .color = .{ 0.08, 0.08, 0.1 } });
    const counts = [4]u16{ r.pins_y, r.pins_x, r.pins_y, r.pins_x };
    var number: u32 = 1;
    for (counts, 0..) |count, side| for (0..count) |i| {
        const along = (@as(f64, @floatFromInt(i)) - @as(f64, @floatFromInt(count - 1)) / 2) * r.leads.pitch;
        const span = if (side % 2 == 0) r.leads.span_x else r.leads.span_y;
        const body_edge = (if (side % 2 == 0) r.body.width else r.body.length) / 2;
        var s: step.Extrusion = .{ .name = try std.fmt.allocPrint(a, "Terminal-{d}", .{if (r.clockwise and number > 1) 2 * (@as(u32, r.pins_x) + r.pins_y) - number + 2 else number}), .outline = &.{}, .thickness = r.leads.thickness, .color = .{ 0.72, 0.74, 0.77 } };
        if (leaded(r)) {
            const outer = span / 2;
            const inner = outer - r.leads.length;
            const z = r.body.standoff + (r.body.height - r.body.standoff) / 2;
            const t = r.leads.thickness;
            s.outline = try a.dupe([2]f64, &.{ .{ body_edge, z }, .{ inner, 0 }, .{ outer, 0 }, .{ outer, t }, .{ inner + t, t }, .{ body_edge, z + t } });
            s.thickness = r.leads.width;
            // Local profile X is radial, Y is up; extrusion spans the lead width.
            switch (side) {
                0 => {
                    s.origin = .{ 0, -along + r.leads.width / 2, 0 };
                    s.x_axis = .{ -1, 0, 0 };
                    s.z_axis = .{ 0, 1, 0 };
                },
                1 => {
                    s.origin = .{ along - r.leads.width / 2, 0, 0 };
                    s.x_axis = .{ 0, -1, 0 };
                    s.z_axis = .{ -1, 0, 0 };
                },
                2 => {
                    s.origin = .{ 0, along - r.leads.width / 2, 0 };
                    s.x_axis = .{ 1, 0, 0 };
                    s.z_axis = .{ 0, -1, 0 };
                },
                else => {
                    s.origin = .{ -along + r.leads.width / 2, 0, 0 };
                    s.x_axis = .{ 0, 1, 0 };
                    s.z_axis = .{ 1, 0, 0 };
                },
            }
        } else {
            const center = (span - r.leads.length) / 2;
            const xy: [2]f64 = switch (side) {
                0 => .{ -center, -along },
                1 => .{ along, -center },
                2 => .{ center, along },
                else => .{ -along, center },
            };
            s.outline = try rectProfile(a, if (side % 2 == 0) r.leads.length else r.leads.width, if (side % 2 == 0) r.leads.width else r.leads.length);
            s.origin = .{ xy[0], xy[1], r.leads.thickness };
        }
        try list.append(a, s);
        number += 1;
    };
    if (r.exposed.enabled) try list.append(a, .{ .name = "Exposed-pad", .outline = try rectProfile(a, r.exposed.width, r.exposed.length), .thickness = @max(r.body.standoff, 0.02), .origin = .{ 0, 0, @max(r.body.standoff, 0.02) }, .color = .{ 0.72, 0.74, 0.77 } });
    const mark = @min(r.body.width, r.body.length) * 0.07;
    try list.append(a, .{ .name = "Pin-1-mark", .outline = try rectProfile(a, mark, mark), .thickness = 0.002, .origin = .{ -r.body.width / 2 + 2 * mark, r.body.length / 2 - 2 * mark, r.body.height }, .color = .{ 0.8, 0.8, 0.8 } });
    for (list.items) |*s| transformSolid(s, r.rotation);
    return list.toOwnedSlice(a);
}

/// Emit a pad using the existing footprint grammar, including pad-relative stencil apertures.
pub fn writePad(w: *std.Io.Writer, p: Pad) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    try w.writeAll("  (pad ");
    try json_writer.writeString(w, p.id);
    try w.print(" {s} {s} (pos {d:.6} {d:.6}) (size {d:.6} {d:.6})", .{ p.type, p.shape, p.x, p.y, p.w, p.h });
    if (p.drill_x > 0) try w.print(" (drill {d:.6} {d:.6})", .{ p.drill_x, p.drill_y });
    if (p.roundrect_ratio) |v| try w.print(" (roundrect_rratio {d:.6})", .{v});
    if (p.mask_margin) |v| try w.print(" (mask-margin {d:.6})", .{v});
    if (p.no_paste) try w.writeAll(" no-paste");
    if (p.poly) |poly| {
        try w.writeAll(" (poly");
        for (poly) |pt| try w.print(" ({d:.6} {d:.6})", .{ pt[0], pt[1] });
        try w.writeByte(')');
    }
    if (p.paste) |windows| {
        try w.writeAll(" (paste");
        for (windows) |v| try w.print(" (rect {d:.6} {d:.6} {d:.6} {d:.6})", .{ v.x, v.y, v.w, v.h });
        try w.writeByte(')');
    }
    try w.writeAll(")\n");
}
fn artwork(w: *std.Io.Writer, a: std.mem.Allocator, source: []const u8, kind: []const u8) !void {
    const nodes = try parser.parse(a, source);
    if (nodes.len != 1 or !nodes[0].isForm(kind)) return error.InvalidArtwork;
    try w.writeAll(source);
    try w.writeByte('\n');
}
fn footprint(a: std.mem.Allocator, r: Recipe, pads: []const Pad) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("(footprint ");
    try json_writer.writeString(w, r.name);
    try w.writeAll("\n  (description \"Generated IC package; edit its package recipe\")\n");
    var bx = r.body.width / 2;
    var by = r.body.length / 2;
    if (r.rotation % 180 != 0) std.mem.swap(f64, &bx, &by);
    var cx = bx;
    var cy = by;
    for (pads) |p| {
        try writePad(w, p);
        cx = @max(cx, @abs(p.x) + p.w / 2);
        cy = @max(cy, @abs(p.y) + p.h / 2);
    }
    if (r.artwork.courtyard) |v| try artwork(w, a, v, "courtyard") else try w.print("  (courtyard (rect {d:.6} {d:.6} {d:.6} {d:.6}))\n", .{ -cx - r.courtyard, -cy - r.courtyard, cx + r.courtyard, cy + r.courtyard });
    if (r.artwork.fab) |v| try artwork(w, a, v, "fab") else try w.print("  (fab (rect {d:.6} {d:.6} {d:.6} {d:.6}))\n", .{ -bx, -by, bx, by });
    const marker = rotate(.{ -cx - 0.2, -cy - 0.2 }, r.rotation);
    if (r.artwork.silk) |v| try artwork(w, a, v, "silkscreen") else try w.print("  (silkscreen (circle ({d:.6} {d:.6}) 0.1))\n", .{ marker[0], marker[1] });
    try w.writeAll(")\n");
    return out.toOwnedSlice();
}
/// Generate canonical library files. The caller owns all allocations through its arena.
pub fn generate(a: std.mem.Allocator, r: Recipe) (step.ExportError || std.mem.Allocator.Error || std.Io.Writer.Error || parser.ParseError || std.json.ParseError(std.json.Scanner) || error{ InvalidArtwork, InvalidFootprint })!Result {
    var d: std.ArrayList(Diagnostic) = .empty;
    try d.appendSlice(a, try validate(a, r));
    if (hasErrors(d.items)) return .{ .recipe = r, .pads = &.{}, .footprint = "", .step = "", .svg = "", .diagnostics = try d.toOwnedSlice(a) };
    const pads = try finalPads(a, r, &d);
    if (hasErrors(d.items)) return .{ .recipe = r, .pads = pads, .footprint = "", .step = "", .svg = "", .diagnostics = try d.toOwnedSlice(a) };
    const source = try footprint(a, r, pads);
    return .{ .recipe = r, .pads = pads, .footprint = source, .step = try step.buildExtrusions(a, r.name, try solids(a, r)), .svg = try @import("package_svg.zig").render(a, source), .diagnostics = try d.toOwnedSlice(a) };
}

// spec: IC package builder - Shared templates generate dimensioned SMT footprints and analytic STEP solids with stable pad identities
test "IC package families dimensions and analytic solids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    inline for (std.meta.tags(Family)) |family| {
        const r = template(family);
        const result = try generate(a, r);
        try std.testing.expect(!hasErrors(result.diagnostics));
        try std.testing.expectEqual(@as(usize, 2) * (@as(usize, r.pins_x) + r.pins_y), result.pads.len);
        try std.testing.expect(std.mem.indexOf(u8, result.step, "MANIFOLD_SOLID_BREP") != null);
        try std.testing.expect(std.mem.indexOf(u8, result.step, "FACETED_BREP(") == null);
        try std.testing.expectEqualStrings("1", result.pads[0].id);
    }
    const result = try generate(a, template(.qfn));
    try std.testing.expectApproxEqAbs(@as(f64, -1.95), result.pads[0].x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1.25), result.pads[0].y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), result.pads[0].w, 1e-9);
}

// spec: IC package builder - Exposed pad stencil windows remain non-electrical geometry and manual fields survive regeneration without moving physical terminals
test "IC package exposed paste and override regeneration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = template(.qfn);
    r.exposed.enabled = true;
    r.overrides = &.{.{ .key = "side-0-0", .w = 0.8 }};
    const result = try generate(a, r);
    try std.testing.expect(!hasErrors(result.diagnostics));
    try std.testing.expectEqual(@as(usize, 25), result.pads.len);
    try std.testing.expectEqual(@as(usize, 4), result.pads[24].paste.?.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.95), result.pads[24].paste.?[0].w, 1e-9);
    r.lands.span_x = 4;
    const regenerated = try generate(a, r);
    try std.testing.expectApproxEqAbs(@as(f64, 0.8), regenerated.pads[0].w, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -2), regenerated.pads[0].x, 1e-9);
    try std.testing.expectEqualStrings(result.step, regenerated.step);
    r.overrides = &.{.{ .key = "side-0-99", .w = 0.8 }};
    try std.testing.expect(hasErrors((try generate(a, r)).diagnostics));
}

// spec: IC package builder - Rejects invalid inputs
test "IC package rejects invalid inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = template(.qfn);
    r.body.width = std.math.nan(f64);
    try std.testing.expect(hasErrors(try validate(a, r)));
    r = template(.qfn);
    r.pins_y = 65535;
    try std.testing.expect(hasErrors(try validate(a, r)));
    r = template(.qfn);
    r.lands.width = 1;
    try std.testing.expect(hasErrors((try generate(a, r)).diagnostics));
    r = template(.qfn);
    r.exposed.enabled = true;
    r.exposed.id = "1";
    try std.testing.expect(hasErrors((try generate(a, r)).diagnostics));
    try std.testing.expectError(error.UnknownField, parse(a, "{\"unknown\":1}"));
}

// spec: IC package builder - Rotated and rectangular packages retain numbering, seating height, and independent land sizing across CLI and GUI generation
test "IC package rectangular rotation and allowance sizing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = template(.qfn);
    r.body.length = 5;
    r.leads.span_y = 5;
    r.lands.span_y = 4.9;
    r.pins_y = 8;
    const original = try generate(a, r);
    try std.testing.expect(!hasErrors(original.diagnostics));
    r.rotation = 90;
    const rotated = try generate(a, r);
    try std.testing.expect(!hasErrors(rotated.diagnostics));
    try std.testing.expectEqual(original.pads[0].w, rotated.pads[0].h);
    try std.testing.expectEqual(-original.pads[0].y, rotated.pads[0].x);
    r = template(.dfn);
    r.lands.mode = .allowances;
    r.lands.toe = 0.2;
    r.lands.heel = 0.1;
    r.lands.side = 0.025;
    const derived = try generate(a, r);
    try std.testing.expect(!hasErrors(derived.diagnostics));
    try std.testing.expectApproxEqAbs(@as(f64, 0.7), derived.pads[0].w, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.3), derived.pads[0].h, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -1.85), derived.pads[0].x, 1e-9);
}

// spec: IC package builder - KiCad round trips preserve copper pad count and explicit exposed-pad stencil windows
test "IC package KiCad roundtrip keeps stencil apertures off copper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = template(.qfn);
    r.exposed.enabled = true;
    const result = try generate(a, r);
    const exported = try @import("../export_kicad_footprint.zig").exportFootprintMod(a, result.footprint, null, null, null);
    const imported = try @import("../convert/footprint.zig").convertFootprint(a, exported);
    const nodes = try parser.parse(a, imported);
    var copper: usize = 0;
    var windows: usize = 0;
    for (nodes[0].asList().?) |node| {
        if (!node.isForm("pad")) continue;
        copper += 1;
        if (try @import("../footprint_paste.zig").parse(a, node)) |v| windows += v.len;
    }
    try std.testing.expectEqual(@as(usize, 25), copper);
    try std.testing.expectEqual(@as(usize, 4), windows);
}

// spec: IC package builder - Rejects oversized schema and artwork
test "IC package rejects oversized schema and artwork" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const large = try a.alloc(u8, 256 * 1024 + 1);
    @memset(large, ' ');
    try std.testing.expectError(error.RecipeTooLarge, parse(a, large));
    try std.testing.expectError(error.UnsupportedSchema, parse(a, "{\"schema\":\"future\"}"));
    var r = template(.qfn);
    r.artwork.fab = "(pad 99 smd rect)";
    try std.testing.expectError(error.InvalidArtwork, generate(a, r));
}
