const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const ast = @import("sexpr/ast.zig");
const parser_mod = @import("sexpr/parser.zig");

/// Error set for footprint emission helpers — covers the parse step on the
/// project source and the allocator failures from string formatting, plus
/// the local `InvalidFormat` thrown when the input doesn't look like a
/// KiCad footprint sexp.
pub const FootprintError = std.mem.Allocator.Error || parser_mod.ParseError || error{InvalidFormat};

// ── Constants ─────────────────────────────────────────────────────
const PAD_MIN_CHILDREN: usize = 5;
const RECT_MIN_CHILDREN: usize = 5;
const POLY_MIN_POINTS: usize = 3;
const DEFAULT_ROUNDRECT_RRATIO: f64 = 0.25;
// Anchor-rect size for an emitted custom pad: kept small (and inside the
// polygon) so the anchor∪primitives union is just the polygon outline.
const CUSTOM_PAD_ANCHOR_MM: f64 = 0.25;
const KICAD_FILL_NONE = "    (fill none)\n";
// Shared `.kicad_mod` line fragments for graphic primitives (layer + stroke).
const KICAD_LAYER_FMT = "    (layer \"{s}\")\n";
const KICAD_STROKE_FMT = "    (stroke (width {d:.2}) (type default))\n";
// KiCad default stroke widths (mm) for the documentation layers.
const SILK_STROKE_MM: f64 = 0.12;
const FAB_STROKE_MM: f64 = 0.1;
const STEP_EXT_LEN: usize = 5;
// ZIP file format constants (PKZIP appnote.txt)
const ZIP_VERSION_NEEDED: u16 = 20;
const ZIP_VERSION_MADE_BY: u16 = 20;
const ZIP_EOCD_SIG_5: u8 = 5;
const ZIP_EOCD_SIG_6: u8 = 6;

// --- Source .kicad_mod passthrough ---

/// Find the original .kicad_mod source file for a footprint.
/// Scans lib/sources/ with case-insensitive matching and underscore/hyphen normalization.
pub fn findSourceKicadMod(allocator: std.mem.Allocator, project_dir: []const u8, footprint_name: []const u8) ?[]const u8 {
    const sources_path = std.fmt.allocPrint(allocator, "{s}/lib/sources", .{project_dir}) catch return null;
    defer allocator.free(sources_path);

    var dir = infra_fs.cwd().openDir(sources_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    // Normalize the footprint name for comparison: lowercase, hyphens→underscores
    const norm_fp = allocator.alloc(u8, footprint_name.len) catch return null;
    defer allocator.free(norm_fp);
    for (footprint_name, 0..) |c, i| {
        norm_fp[i] = if (c >= 'A' and c <= 'Z') c + 32 else if (c == '_') '-' else c;
    }

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".kicad_mod")) continue;

        // Normalize source filename (strip extension, lowercase, underscores→hyphens)
        const basename = entry.name[0 .. entry.name.len - 10]; // strip .kicad_mod
        const norm_src = allocator.alloc(u8, basename.len) catch continue;
        defer allocator.free(norm_src);
        for (basename, 0..) |c, i| {
            norm_src[i] = if (c >= 'A' and c <= 'Z') c + 32 else if (c == '_') '-' else c;
        }

        if (std.mem.eql(u8, norm_fp, norm_src)) {
            const full_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ sources_path, entry.name }) catch return null;
            return full_path;
        }
    }
    return null;
}

/// Use an original .kicad_mod file, injecting/replacing the 3D model reference.
pub fn useSourceKicadMod(
    allocator: std.mem.Allocator,
    source: []const u8,
    model_name: ?[]const u8,
    model_offset: ?[3]f64,
    model_rotation: ?[3]f64,
) FootprintError![]const u8 {
    // If no model, return the source as-is
    if (model_name == null) {
        return allocator.dupe(u8, source);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Find existing (model ...) block to replace, or insert before final ')'
    if (std.mem.indexOf(u8, source, "(model ")) |model_start| {
        // Find the end of the model block by tracking parens
        var depth: u32 = 0;
        var model_end: usize = model_start;
        for (source[model_start..], 0..) |c, i| {
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth == 0) {
                    model_end = model_start + i + 1;
                    break;
                }
            }
        }
        // Skip trailing whitespace/newline after model block
        while (model_end < source.len and (source[model_end] == '\n' or source[model_end] == '\r' or source[model_end] == ' ')) {
            model_end += 1;
        }
        // Write everything before the old model, then new model, then rest
        try w.writeAll(source[0..model_start]);
        try writeModelBlock(w, model_name.?, model_offset, model_rotation);
        try w.writeAll(source[model_end..]);
    } else {
        // No existing model — insert before the final ')'
        const last_paren = std.mem.lastIndexOf(u8, source, ")") orelse return error.InvalidFormat;
        try w.writeAll(source[0..last_paren]);
        try writeModelBlock(w, model_name.?, model_offset, model_rotation);
        try w.writeAll(")\n");
    }

    return buf.toOwnedSlice(allocator);
}

fn writeModelBlock(w: anytype, model_name: []const u8, model_offset: ?[3]f64, model_rotation: ?[3]f64) !void {
    const off = model_offset orelse [3]f64{ 0, 0, 0 };
    const rot = model_rotation orelse [3]f64{ 0, 0, 0 };
    try w.writeAll("  (model \"${KIPRJMOD}/models/");
    try w.writeAll(model_name);
    try w.writeAll("\"\n");
    try w.print("    (offset (xyz {d:.4} {d:.4} {d:.4}))\n", .{ -off[0], -off[1], -off[2] });
    try w.writeAll("    (scale (xyz 1 1 1))\n");
    // KiCad .kicad_mod stores the X rotation negated vs. the 3D viewer display.
    // Our config uses right-handed X rotation (matches the in-tool preview);
    // negate X here so KiCad shows the same orientation the user set.
    try w.print("    (rotate (xyz {d:.4} {d:.4} {d:.4}))\n", .{ -rot[0], rot[1], rot[2] });
    try w.writeAll("  )\n");
}

// --- Footprint .sexp -> .kicad_mod ---

/// Render a project `(footprint …)` source into a KiCad `.kicad_mod` file:
/// emits the version header, every pad, the courtyard, silkscreen + fab
/// geometry, and an optional `(model …)` reference to a STEP file under
/// `models/`.
pub fn exportFootprintMod(
    allocator: std.mem.Allocator,
    source: []const u8,
    model_name: ?[]const u8,
    model_offset: ?[3]f64,
    model_rotation: ?[3]f64,
) FootprintError![]const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];
    if (!root.isForm("footprint")) return error.InvalidFormat;
    const children = root.asList() orelse return error.InvalidFormat;
    if (children.len < 2) return error.InvalidFormat;

    const name = children[1].asAtom() orelse children[1].asString() orelse return error.InvalidFormat;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("(footprint \"");
    try w.writeAll(name);
    try w.writeAll("\"\n");
    try w.writeAll("  (version 20240108)\n");
    try w.writeAll("  (generator \"canopy-eda\")\n");
    try w.writeAll("  (layer \"F.Cu\")\n");

    // Description
    for (children[2..]) |child| {
        if (child.isForm("description")) {
            const cl = child.asList().?;
            if (cl.len >= 2) {
                const desc = cl[1].asAtom() orelse cl[1].asString() orelse "";
                try w.print("  (descr \"{s}\")\n", .{desc});
            }
        }
    }

    // Pads
    for (children[2..]) |child| {
        if (child.isForm("pad")) {
            try emitKicadPad(w, child);
        }
    }

    // Courtyard
    for (children[2..]) |child| {
        if (child.isForm("courtyard")) {
            try emitKicadCourtyard(w, child);
        }
    }

    // Silkscreen
    for (children[2..]) |child| {
        if (child.isForm("silkscreen")) {
            try emitKicadGeomBlock(w, child, "F.SilkS", SILK_STROKE_MM);
        }
    }

    // Fab (package body outline + pin-1 marker). Same shape grammar as
    // silkscreen; many footprints carry their outline only here, so it must
    // round-trip to F.Fab rather than being dropped.
    for (children[2..]) |child| {
        if (child.isForm("fab")) {
            try emitKicadGeomBlock(w, child, "F.Fab", FAB_STROKE_MM);
        }
    }

    // 3D model reference
    if (model_name) |mname| {
        try writeModelBlock(w, mname, model_offset, model_rotation);
    }

    try w.writeAll(")\n");
    return buf.toOwnedSlice(allocator);
}

fn emitKicadPad(w: anytype, node: ast.Node) !void {
    const children = node.asList() orelse return;
    if (children.len < PAD_MIN_CHILDREN) return;

    // (pad NAME TYPE SHAPE (pos X Y) (size W H))
    const pad_type_internal = children[2].asAtom() orelse return;
    const pad_shape_internal = children[3].asAtom() orelse return;

    // Reverse map types
    const kicad_type = reverseMapPadType(pad_type_internal);
    const kicad_shape = pad_shape_internal; // shapes are same names

    var x: f64 = 0;
    var y: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var drill_x: f64 = 0;
    var drill_y: f64 = 0;
    var has_drill = false;
    var is_oval_drill = false;
    var mask_margin: ?f64 = null;
    var no_paste = false;
    var poly_node: ?ast.Node = null;
    // rratio defaults match KiCad's library default; override via
    // `(roundrect_rratio R)` on the .sexp pad form. 0.5 turns a square
    // pad into a circle (used by mounting-spacer footprints).
    var rratio: f64 = DEFAULT_ROUNDRECT_RRATIO;

    for (children[4..]) |child| {
        if (child.isForm("roundrect_rratio")) {
            const cl = child.asList().?;
            if (cl.len >= 2) rratio = cl[1].asNumber() orelse DEFAULT_ROUNDRECT_RRATIO;
        }
        if (child.isForm("pos")) {
            const cl = child.asList().?;
            if (cl.len >= 3) {
                x = cl[1].asNumber() orelse 0;
                y = cl[2].asNumber() orelse 0;
            }
        }
        if (child.isForm("size")) {
            const cl = child.asList().?;
            if (cl.len >= 3) {
                sx = cl[1].asNumber() orelse 0;
                sy = cl[2].asNumber() orelse 0;
            }
        }
        if (child.isForm("mask-margin")) {
            const cl = child.asList().?;
            if (cl.len >= 2) mask_margin = cl[1].asNumber();
        }
        if (child.isForm("poly")) poly_node = child;
        if (child.asAtom()) |a| {
            if (std.mem.eql(u8, a, "no-paste")) no_paste = true;
        }
        if (child.isForm("drill")) {
            const cl = child.asList().?;
            has_drill = true;
            if (cl.len >= 2) {
                if (cl[1].asAtom()) |a| {
                    if (std.mem.eql(u8, a, "oval") and cl.len >= 4) {
                        is_oval_drill = true;
                        drill_x = cl[2].asNumber() orelse 0;
                        drill_y = cl[3].asNumber() orelse 0;
                    }
                } else {
                    drill_x = cl[1].asNumber() orelse 0;
                    drill_y = drill_x;
                }
            }
        }
    }

    // Resolve the pad name once (atom, string, or numeric).
    var name_buf: [64]u8 = undefined;
    const pad_name = padName(children[1], &name_buf) orelse return;

    // A `custom` pad carries its real copper outline in `(poly …)`; emit it as
    // a valid KiCad custom pad with `(primitives (gr_poly …))`. A `custom` pad
    // with no polygon would be invalid in KiCad, so fall back to `rect`.
    if (std.mem.eql(u8, pad_shape_internal, "custom")) {
        if (poly_node) |pn| {
            try emitKicadCustomPad(w, pad_name, kicad_type, x, y, sx, sy, pn, no_paste);
            return;
        }
    }
    const emit_shape = if (std.mem.eql(u8, kicad_shape, "custom")) "rect" else kicad_shape;
    try w.print("  (pad \"{s}\" {s} {s}\n", .{ pad_name, kicad_type, emit_shape });

    try w.print("    (at {d:.2} {d:.2})\n", .{ x, y });
    try w.print("    (size {d:.2} {d:.2})\n", .{ sx, sy });

    // Drill for through-hole pads
    if (std.mem.eql(u8, pad_type_internal, "thru") or std.mem.eql(u8, pad_type_internal, "npth")) {
        if (has_drill) {
            if (is_oval_drill) {
                try w.print("    (drill oval {d:.2} {d:.2})\n", .{ drill_x, drill_y });
            } else {
                try w.print("    (drill {d:.2})\n", .{drill_x});
            }
        } else {
            // Fallback: guess drill as min dimension
            const drill = @min(sx, sy);
            try w.print("    (drill {d:.2})\n", .{drill});
        }
    }

    // Layers
    if (std.mem.eql(u8, pad_type_internal, "smd")) {
        if (no_paste) {
            try w.writeAll("    (layers \"F.Cu\" \"F.Mask\")\n");
        } else {
            try w.writeAll("    (layers \"F.Cu\" \"F.Mask\" \"F.Paste\")\n");
        }
        if (std.mem.eql(u8, kicad_shape, "roundrect")) {
            try w.print("    (roundrect_rratio {d:.3})\n", .{rratio});
        }
    } else if (std.mem.eql(u8, pad_type_internal, "thru")) {
        try w.writeAll("    (layers \"*.Cu\" \"*.Mask\")\n");
    } else if (std.mem.eql(u8, pad_type_internal, "npth")) {
        try w.writeAll("    (layers \"*.Cu\" \"*.Mask\")\n");
    }

    if (mask_margin) |m| try w.print("    (solder_mask_margin {d:.3})\n", .{m});

    try w.writeAll("  )\n");
}

/// Resolve a pad-name node (atom / string / numeric) into a string, writing a
/// numeric name into `buf`. Returns null if the node is none of those.
fn padName(node: ast.Node, buf: []u8) ?[]const u8 {
    if (node.asAtom() orelse node.asString()) |s| return s;
    if (node.asNumber()) |num| {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i64, @intFromFloat(num))}) catch null;
    }
    return null;
}

/// Emit a KiCad custom pad. The `.sexp` stores the outline in `(poly …)` as
/// footprint-absolute points with `(pos …)` at the polygon's bbox center; KiCad
/// wants pad-local points, so each is rewritten relative to `(at x y)`. A small
/// anchor rect sits inside the polygon so the union is exactly the outline.
fn emitKicadCustomPad(
    w: anytype,
    pad_name: []const u8,
    kicad_type: []const u8,
    x: f64,
    y: f64,
    bw: f64,
    bh: f64,
    poly_node: ast.Node,
    no_paste: bool,
) !void {
    const anchor = @min(@min(bw, bh) * 0.5, CUSTOM_PAD_ANCHOR_MM);
    try w.print("  (pad \"{s}\" {s} custom\n", .{ pad_name, kicad_type });
    try w.print("    (at {d:.3} {d:.3})\n", .{ x, y });
    try w.print("    (size {d:.3} {d:.3})\n", .{ anchor, anchor });
    if (no_paste) {
        try w.writeAll("    (layers \"F.Cu\" \"F.Mask\")\n");
    } else {
        try w.writeAll("    (layers \"F.Cu\" \"F.Mask\" \"F.Paste\")\n");
    }
    try w.writeAll("    (options (clearance outline) (anchor rect))\n");
    try w.writeAll("    (primitives\n      (gr_poly\n        (pts\n");
    const pl = poly_node.asList() orelse return;
    for (pl[1..]) |pt| {
        const ptl = pt.asList() orelse continue;
        if (ptl.len < 2) continue;
        const ax = ptl[0].asNumber() orelse continue;
        const ay = ptl[1].asNumber() orelse continue;
        try w.print("          (xy {d:.3} {d:.3})\n", .{ ax - x, ay - y });
    }
    try w.writeAll("        )\n        (width 0)\n        (fill yes)\n      )\n    )\n");
    try w.writeAll("  )\n");
}

fn emitKicadCourtyard(w: anytype, node: ast.Node) !void {
    const children = node.asList() orelse return;
    // (courtyard (rect X1 Y1 X2 Y2)) and (courtyard (circle (CX CY) R))
    for (children[1..]) |child| {
        if (child.isForm("rect")) {
            const cl = child.asList() orelse continue;
            if (cl.len >= RECT_MIN_CHILDREN) {
                const x1 = cl[1].asNumber() orelse 0;
                const y1 = cl[2].asNumber() orelse 0;
                const x2 = cl[3].asNumber() orelse 0;
                const y2 = cl[4].asNumber() orelse 0;
                try w.print("  (fp_rect (start {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ x1, y1, x2, y2 });
                try w.writeAll("    (stroke (width 0.05) (type default))\n");
                try w.writeAll(KICAD_FILL_NONE);
                try w.writeAll("    (layer \"F.CrtYd\")\n");
                try w.writeAll("  )\n");
            }
        } else if (child.isForm("circle")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 3) continue;
            const center = cl[1].asList() orelse continue;
            if (center.len < 2) continue;
            const cx = center[0].asNumber() orelse continue;
            const cy = center[1].asNumber() orelse continue;
            const r = cl[2].asNumber() orelse continue;
            try w.print("  (fp_circle (center {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ cx, cy, cx + r, cy });
            try w.writeAll("    (stroke (width 0.05) (type default))\n");
            try w.writeAll(KICAD_FILL_NONE);
            try w.writeAll("    (layer \"F.CrtYd\")\n");
            try w.writeAll("  )\n");
        }
    }
}

/// Emit a `(line …)`/`(circle …)`/`(rect …)`/`(poly …)` geometry block onto
/// `layer` with the given stroke `width`. The `silkscreen` (F.SilkS) and `fab`
/// (F.Fab) blocks share the same shape grammar, so both route through here.
/// `(poly …)` covers filled pin-1 markers, which fine-pitch parts (LGA/QFN)
/// carry on F.SilkS — dropping them left those parts with no orientation mark.
fn emitKicadGeomBlock(w: anytype, node: ast.Node, layer: []const u8, width: f64) !void {
    const children = node.asList() orelse return;
    for (children[1..]) |child| {
        if (child.isForm("rect")) {
            const cl = child.asList() orelse continue;
            // (rect X1 Y1 X2 Y2)
            if (cl.len >= RECT_MIN_CHILDREN) {
                const x1 = cl[1].asNumber() orelse continue;
                const y1 = cl[2].asNumber() orelse continue;
                const x2 = cl[3].asNumber() orelse continue;
                const y2 = cl[4].asNumber() orelse continue;
                try w.print("  (fp_rect (start {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ x1, y1, x2, y2 });
                try w.print(KICAD_STROKE_FMT, .{width});
                try w.writeAll(KICAD_FILL_NONE);
                try w.print(KICAD_LAYER_FMT, .{layer});
                try w.writeAll("  )\n");
            }
        }
        if (child.isForm("poly")) {
            const cl = child.asList() orelse continue;
            // (poly (X Y) (X Y) …) — a filled outline (pin-1 marker, body shape)
            if (cl.len >= POLY_MIN_POINTS + 1) {
                try w.writeAll("  (fp_poly\n    (pts");
                for (cl[1..]) |pt| {
                    const p = pt.asList() orelse continue;
                    if (p.len < 2) continue;
                    const x = p[0].asNumber() orelse continue;
                    const y = p[1].asNumber() orelse continue;
                    try w.print(" (xy {d:.2} {d:.2})", .{ x, y });
                }
                try w.writeAll(")\n");
                try w.print(KICAD_STROKE_FMT, .{width});
                try w.writeAll("    (fill solid)\n");
                try w.print(KICAD_LAYER_FMT, .{layer});
                try w.writeAll("  )\n");
            }
        }
        if (child.isForm("line")) {
            const cl = child.asList() orelse continue;
            // (line (X1 Y1) (X2 Y2))
            if (cl.len >= 3) {
                const start = cl[1].asList() orelse continue;
                const end = cl[2].asList() orelse continue;
                if (start.len >= 2 and end.len >= 2) {
                    const sx = start[0].asNumber() orelse continue;
                    const sy = start[1].asNumber() orelse continue;
                    const ex = end[0].asNumber() orelse continue;
                    const ey = end[1].asNumber() orelse continue;
                    try w.print("  (fp_line (start {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ sx, sy, ex, ey });
                    try w.print(KICAD_STROKE_FMT, .{width});
                    try w.print(KICAD_LAYER_FMT, .{layer});
                    try w.writeAll("  )\n");
                }
            }
        }
        if (child.isForm("circle")) {
            const cl = child.asList() orelse continue;
            // (circle (CX CY) R)
            if (cl.len >= 3) {
                const center = cl[1].asList() orelse continue;
                if (center.len >= 2) {
                    const cx = center[0].asNumber() orelse continue;
                    const cy = center[1].asNumber() orelse continue;
                    const r = cl[2].asNumber() orelse continue;
                    // KiCad uses center + end point
                    try w.print("  (fp_circle (center {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ cx, cy, cx + r, cy });
                    try w.print(KICAD_STROKE_FMT, .{width});
                    try w.writeAll(KICAD_FILL_NONE);
                    try w.print(KICAD_LAYER_FMT, .{layer});
                    try w.writeAll("  )\n");
                }
            }
        }
    }
}

/// Inverse of `convert.footprint.mapPadType`: turn the project's compact
/// pad-type token (`smd`/`thru`/`npth`) back into the KiCad spelling
/// (`smd`/`thru_hole`/`np_thru_hole`) used in `.kicad_mod` output.
pub fn reverseMapPadType(internal: []const u8) []const u8 {
    if (std.mem.eql(u8, internal, "smd")) return "smd";
    if (std.mem.eql(u8, internal, "thru")) return "thru_hole";
    if (std.mem.eql(u8, internal, "npth")) return "np_thru_hole";
    return "smd";
}

// --- STEP model finder ---

/// Locate the STEP model that pairs with a footprint by trying
/// `<footprint>.step`, then `<component>.step`, then a partial-name scan
/// of `lib/models/`. Returns the model filename (caller frees) or null
/// when no candidate is found.
pub fn findModelFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    footprint_name: []const u8,
    component_name: []const u8,
) ?[]const u8 {
    // Try exact footprint name match
    const fp_step = std.fmt.allocPrint(allocator, "{s}.step", .{footprint_name}) catch return null;
    defer allocator.free(fp_step);
    {
        const check_path = std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, fp_step }) catch return null;
        defer allocator.free(check_path);
        if (infra_fs.cwd().access(check_path, .{})) |_| {
            return allocator.dupe(u8, fp_step) catch null;
        } else |_| {}
    }

    // Try component name match
    const comp_step = std.fmt.allocPrint(allocator, "{s}.step", .{component_name}) catch return null;
    defer allocator.free(comp_step);
    {
        const check_path = std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, comp_step }) catch return null;
        defer allocator.free(check_path);
        if (infra_fs.cwd().access(check_path, .{})) |_| {
            return allocator.dupe(u8, comp_step) catch null;
        } else |_| {}
    }

    // Scan models directory for partial match
    const models_path = std.fmt.allocPrint(allocator, "{s}/lib/models", .{project_dir}) catch return null;
    defer allocator.free(models_path);

    var dir = infra_fs.cwd().openDir(models_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".step")) continue;
        // Check if model filename contains the footprint or component name
        const basename = entry.name[0 .. entry.name.len - STEP_EXT_LEN]; // strip .step
        if (std.mem.indexOf(u8, footprint_name, basename) != null or
            std.mem.indexOf(u8, basename, footprint_name) != null or
            std.mem.indexOf(u8, component_name, basename) != null or
            std.mem.indexOf(u8, basename, component_name) != null)
        {
            return allocator.dupe(u8, entry.name) catch null;
        }
    }

    return null;
}

// --- ZIP builder ---

/// A single file inside a built-in-memory zip archive: the archive path
/// (e.g. `footprints.pretty/R_0402.kicad_mod`) and its raw contents. Used
/// by the KiCad and Gerber zip exporters as their unit of work.
pub const ZipEntry = struct {
    name: []const u8,
    data: []const u8,
};

/// Build a ZIP file in memory using store (no compression).
pub fn buildZip(allocator: std.mem.Allocator, entries: []const ZipEntry) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);

    // Track offsets for central directory
    var offsets = try allocator.alloc(u32, entries.len);
    defer allocator.free(offsets);

    // Write local file headers + data
    for (entries, 0..) |entry, i| {
        offsets[i] = @intCast(buf.items.len);
        // Local file header
        try buf.appendSlice(allocator, &[_]u8{ 'P', 'K', 3, 4 }); // signature
        try appendU16(&buf, allocator, ZIP_VERSION_NEEDED); // version needed
        try appendU16(&buf, allocator, 0); // flags
        try appendU16(&buf, allocator, 0); // compression: store
        try appendU16(&buf, allocator, 0); // mod time
        try appendU16(&buf, allocator, 0); // mod date
        try appendU32(&buf, allocator, crc32(entry.data)); // crc32
        try appendU32(&buf, allocator, @intCast(entry.data.len)); // compressed size
        try appendU32(&buf, allocator, @intCast(entry.data.len)); // uncompressed size
        try appendU16(&buf, allocator, @intCast(entry.name.len)); // filename len
        try appendU16(&buf, allocator, 0); // extra field len
        try buf.appendSlice(allocator, entry.name);
        try buf.appendSlice(allocator, entry.data);
    }

    // Central directory
    const cd_start: u32 = @intCast(buf.items.len);
    for (entries, 0..) |entry, i| {
        try buf.appendSlice(allocator, &[_]u8{ 'P', 'K', 1, 2 }); // signature
        try appendU16(&buf, allocator, ZIP_VERSION_MADE_BY); // version made by
        try appendU16(&buf, allocator, ZIP_VERSION_NEEDED); // version needed
        try appendU16(&buf, allocator, 0); // flags
        try appendU16(&buf, allocator, 0); // compression: store
        try appendU16(&buf, allocator, 0); // mod time
        try appendU16(&buf, allocator, 0); // mod date
        try appendU32(&buf, allocator, crc32(entry.data)); // crc32
        try appendU32(&buf, allocator, @intCast(entry.data.len)); // compressed size
        try appendU32(&buf, allocator, @intCast(entry.data.len)); // uncompressed size
        try appendU16(&buf, allocator, @intCast(entry.name.len)); // filename len
        try appendU16(&buf, allocator, 0); // extra field len
        try appendU16(&buf, allocator, 0); // comment len
        try appendU16(&buf, allocator, 0); // disk number start
        try appendU16(&buf, allocator, 0); // internal attrs
        try appendU32(&buf, allocator, 0); // external attrs
        try appendU32(&buf, allocator, offsets[i]); // local header offset
        try buf.appendSlice(allocator, entry.name);
    }
    const cd_size: u32 = @intCast(buf.items.len - cd_start);

    // End of central directory
    try buf.appendSlice(allocator, &[_]u8{ 'P', 'K', ZIP_EOCD_SIG_5, ZIP_EOCD_SIG_6 }); // signature
    try appendU16(&buf, allocator, 0); // disk number
    try appendU16(&buf, allocator, 0); // disk with CD
    try appendU16(&buf, allocator, @intCast(entries.len)); // entries on disk
    try appendU16(&buf, allocator, @intCast(entries.len)); // total entries
    try appendU32(&buf, allocator, cd_size); // CD size
    try appendU32(&buf, allocator, cd_start); // CD offset
    try appendU16(&buf, allocator, 0); // comment len

    return buf.toOwnedSlice(allocator);
}

fn appendU16(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u16) !void {
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u16, val)));
}

fn appendU32(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, val: u32) !void {
    try buf.appendSlice(allocator, &std.mem.toBytes(std.mem.nativeToLittle(u32, val)));
}

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc = crc ^ @as(u32, byte);
        for (0..8) |_| {
            const mask: u32 = if (crc & 1 != 0) 0xEDB88320 else 0;
            crc = (crc >> 1) ^ mask;
        }
    }
    return crc ^ 0xFFFFFFFF;
}

test "exportFootprintMod emits fab geometry on F.Fab and keeps silkscreen on F.SilkS" {
    // spec: export_kicad - Emits a footprint's (fab …) body outline as fp_line/fp_circle on the F.Fab layer
    const src =
        \\(footprint "T"
        \\  (pad 1 smd rect (pos 0 0) (size 1 1))
        \\  (silkscreen (line (-1 -1) (1 -1)))
        \\  (fab (line (-2 -2) (2 -2)) (circle (0 0) 0.5)))
    ;
    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    // The fab line + circle land on F.Fab (previously dropped entirely).
    try std.testing.expect(std.mem.indexOf(u8, out, "(layer \"F.Fab\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(fp_line (start -2.00 -2.00) (end 2.00 -2.00)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(fp_circle (center 0.00 0.00) (end 0.50 0.00)") != null);
    // Silkscreen still routes to F.SilkS — fab emission must not displace it.
    try std.testing.expect(std.mem.indexOf(u8, out, "(layer \"F.SilkS\")") != null);
}

test "exportFootprintMod emits silkscreen poly + rect (pin-1 markers must not be dropped)" {
    // spec: export_kicad - Emits silkscreen/fab (poly …) as a filled fp_poly and (rect …) as fp_rect on the target layer
    const src =
        \\(footprint "T"
        \\  (pad 1 smd rect (pos 0 0) (size 1 1))
        \\  (silkscreen
        \\    (poly (-3.40 1.81) (-3.40 2.19) (-3.15 2.19) (-3.15 1.81))
        \\    (rect -1 -1 1 1)))
    ;
    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    // The pin-1 marker poly becomes a filled fp_poly on F.SilkS.
    try std.testing.expect(std.mem.indexOf(u8, out, "(fp_poly") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(xy -3.40 1.81)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(fill solid)") != null);
    // The rect becomes an fp_rect.
    try std.testing.expect(std.mem.indexOf(u8, out, "(fp_rect (start -1.00 -1.00) (end 1.00 1.00)") != null);
}

test "exportFootprintMod emits a custom pad's polygon as KiCad (primitives (gr_poly …))" {
    // spec: export_kicad - Emits a custom pad's (poly …) outline as a valid KiCad custom pad with (primitives (gr_poly …)) in pad-local coords
    const src =
        \\(footprint "T"
        \\  (pad 1 smd custom (pos 1.000 1.000) (size 2.000 2.000)
        \\    (poly (0.000 0.000) (2.000 0.000) (2.000 2.000) (0.000 2.000))))
    ;
    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "smd custom") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(primitives") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(gr_poly") != null);
    // Footprint-absolute (0,0) is rewritten pad-local relative to (at 1 1) → (-1,-1).
    try std.testing.expect(std.mem.indexOf(u8, out, "(xy -1.000 -1.000)") != null);
    // The anchor stays small so anchor∪primitives is exactly the polygon.
    try std.testing.expect(std.mem.indexOf(u8, out, "(size 0.250 0.250)") != null);
}
