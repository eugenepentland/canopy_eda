//! KiCad footprint export: locates a part's source `.kicad_mod` (reusing it
//! verbatim when present) or emits one from the netlisp footprint, mapping
//! netlisp pad types back to KiCad's. Produces the footprint files of a KiCad
//! export alongside the netlist.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const ast = @import("sexpr/ast.zig");
const parser_mod = @import("sexpr/parser.zig");
const geometry = @import("placement/geometry.zig");
const numeric = @import("numeric.zig");
const board_layers = @import("board_layers.zig");
const kicad_format = @import("kicad_pcb/format.zig");
/// Error set for footprint emission helpers — covers the parse step on the
/// project source and the allocator failures from string formatting, plus
/// the local `InvalidFormat` thrown when the input doesn't look like a
/// KiCad footprint sexp.
pub const FootprintError = std.mem.Allocator.Error || std.Io.Writer.Error || parser_mod.ParseError || error{InvalidFormat};

// ── Constants ─────────────────────────────────────────────────────
const pad_min_children: usize = 5;
const rect_min_children: usize = 5;
const poly_min_points: usize = 3;
// Anchor-rect size for an emitted custom pad: kept small (and inside the
// polygon) so the anchor∪primitives union is just the polygon outline.
const custom_pad_anchor_mm: f64 = 0.25;
const kicad_fill_none = "    (fill none)\n";
// Shared `.kicad_mod` line fragments for graphic primitives (layer + stroke).
const kicad_layer_fmt = "    (layer \"{s}\")\n";

// The fixed `(layer …)` / `(layers …)` lines a generated `.kicad_mod` writes,
// spelled from the layer table so a footprint names the same faces the board
// model, the router and the Gerber plan do.
const footprint_layer_line = "  (layer \"" ++ board_layers.f_cu ++ "\")\n";
const smd_pad_layers = "    (layers \"" ++ board_layers.f_cu ++ "\" \"" ++ board_layers.f_mask ++ "\")\n";
const smd_pad_layers_pasted = "    (layers \"" ++ board_layers.f_cu ++ "\" \"" ++
    board_layers.f_mask ++ "\" \"" ++ board_layers.f_paste ++ "\")\n";
const courtyard_layer_line = "    (layer \"" ++ board_layers.f_crtyd ++ "\")\n";
const kicad_stroke_fmt = "    (stroke (width {d:.2}) (type default))\n";
// Stroke widths (mm) for the generated `.kicad_mod` graphic layers.
//
// F.SilkS is MANUFACTURED, so it takes the same 0.15 mm the Gerber writer
// plots (`export_gerber.silk_w_mm`): both stroke the very same parsed
// `(silkscreen …)` form of the very same netlisp footprint, so one outline
// drawn at two widths is one board described two ways. 0.15 mm is also the
// standard-process minimum silk line width — 0.12 mm is legal only on a
// high-precision process. F.Fab is a documentation layer that is never
// manufactured, so it keeps KiCad's 0.1 mm editor default.
const silk_stroke_mm: f64 = 0.15;
const fab_stroke_mm: f64 = 0.1;
const step_ext_len: usize = 5;

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

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const tmp = scratch.allocator();

    // Find existing (model ...) block to replace, or insert before final ')'
    if (std.mem.indexOf(u8, source, "(model ")) |model_start| {
        var model_end = formEndIndex(source, model_start) orelse return error.InvalidFormat;
        // Skip trailing whitespace/newline after model block
        while (model_end < source.len and (source[model_end] == '\n' or source[model_end] == '\r' or source[model_end] == ' ')) {
            model_end += 1;
        }
        // Write everything before the old model, then new model, then rest
        try w.writeAll(source[0..model_start]);
        try writeModelBlock(tmp, w, model_name.?, model_offset, model_rotation);
        try w.writeAll(source[model_end..]);
    } else {
        // No existing model — insert before the final ')'
        const last_paren = std.mem.lastIndexOf(u8, source, ")") orelse return error.InvalidFormat;
        try w.writeAll(source[0..last_paren]);
        try writeModelBlock(tmp, w, model_name.?, model_offset, model_rotation);
        try w.writeAll(")\n");
    }

    return buf.toOwnedSlice();
}

/// Byte offset one past the `)` that closes the form opening at `start`.
/// Quoted strings (and their `\` escapes) are skipped, so a parenthesis inside
/// a path — a vendor `.kicad_mod` whose model reads `models/Part(rev2).step` —
/// cannot end the form early and mis-splice the file. Null when `start` does
/// not open a form and when the form is unterminated, so a caller that guessed
/// its start wrong gets a refusal rather than a wrong splice.
///
/// The caller's own SEARCH for the form is still a plain substring scan, so a
/// `.kicad_mod` that spelled the literal text `(model ` inside a quoted string
/// would aim this at the wrong byte. No footprint does; the parenthesised
/// filename above is the case that actually occurs.
fn formEndIndex(source: []const u8, start: usize) ?usize {
    // Entering with the opening paren already counted keeps `depth` at 1 or
    // more for every `)` below, so the decrement cannot underflow.
    if (start >= source.len or source[start] != '(') return null;
    var depth: u32 = 1;
    var in_string = false;
    var i = start + 1;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_string) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') {
                in_string = false;
            }
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

fn writeModelBlock(arena: std.mem.Allocator, w: anytype, model_name: []const u8, model_offset: ?[3]f64, model_rotation: ?[3]f64) !void {
    const off = model_offset orelse [3]f64{ 0, 0, 0 };
    const rot = model_rotation orelse [3]f64{ 0, 0, 0 };
    // The model file name comes off a directory scan, not the tokenizer, so it
    // is a genuinely raw string — a `"` in a filename is legal on this platform
    // and would otherwise close the path token early.
    try w.writeAll("  (model \"${KIPRJMOD}/models/");
    try w.writeAll(try kicad_format.sexprEscape(arena, model_name));
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
///
/// `model_name` is escaped with `kicad_format.sexprEscape` because it comes off
/// a directory scan, not the tokenizer, and a `"` in a filename is legal here.
/// Everything read out of `source` is copied VERBATIM, and deliberately so: a
/// tokenizer slice is already in the grammar's escaped form, so escaping it
/// again doubles every sequence it holds. That is not hypothetical — the
/// project's own pin-header footprints describe themselves as `2.54mm pitch
/// (0.1\")`, which a second escape turns into `(0.1\\")` in KiCad.
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

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    // Scratch for the escaped 3D-model path (see the doc comment above); the
    // names read out of `source` are tokenizer slices and are copied verbatim.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const tmp = scratch.allocator();

    try w.writeAll("(footprint \"");
    try w.writeAll(name);
    try w.writeAll("\"\n");
    try w.writeAll("  (version 20240108)\n");
    try w.writeAll("  (generator \"netlisp\")\n");
    try w.writeAll(footprint_layer_line);

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
            try emitKicadPad(tmp, w, child);
        }
    }

    // Courtyard
    for (children[2..]) |child| {
        if (child.isForm("courtyard")) {
            try emitKicadCourtyard(w, child);
        }
    }

    // Footprint-attached, outer-layer copper-pour keepouts. These remain
    // pour-only in KiCad: pads/tracks/vias are allowed and buried planes are
    // not listed in the zone's layer set.
    for (children[2..]) |child| {
        if (child.isForm("copper-pour-keepout")) {
            try emitKicadCopperPourKeepout(w, child);
        }
    }

    // Silkscreen
    for (children[2..]) |child| {
        if (child.isForm("silkscreen")) {
            try emitKicadGeomBlock(w, child, board_layers.f_silks, silk_stroke_mm);
        }
    }

    // Fab (package body outline + pin-1 marker). Same shape grammar as
    // silkscreen; many footprints carry their outline only here, so it must
    // round-trip to F.Fab rather than being dropped.
    for (children[2..]) |child| {
        if (child.isForm("fab")) {
            try emitKicadGeomBlock(w, child, board_layers.f_fab, fab_stroke_mm);
        }
    }

    // 3D model reference
    if (model_name) |mname| {
        try writeModelBlock(tmp, w, mname, model_offset, model_rotation);
    }

    try w.writeAll(")\n");
    return buf.toOwnedSlice();
}

fn emitKicadCopperPourKeepout(w: anytype, node: ast.Node) !void {
    const children = node.asList() orelse return;
    if (children.len < 3) return;
    const layer = children[1].asAtom() orelse children[1].asString() orelse return;
    var poly: ?ast.Node = null;
    var vias_not_allowed = false;
    for (children[2..]) |child| {
        if (child.isForm("poly")) poly = child;
        if (child.isForm("vias")) {
            const rule = child.asList() orelse continue;
            if (rule.len >= 2) {
                const action = rule[1].asAtom() orelse rule[1].asString() orelse continue;
                vias_not_allowed = std.mem.eql(u8, action, "not_allowed");
            }
        }
    }
    const points = (poly orelse return).asList() orelse return;
    if (points.len < 4) return;

    try w.print(
        "  (zone\n" ++
            "    (layer \"{s}\")\n" ++
            "    (hatch full 0.508)\n" ++
            "    (connect_pads (clearance 0))\n" ++
            "    (min_thickness 0.254)\n" ++
            "    (keepout\n" ++
            "      (tracks allowed)\n" ++
            "      (vias {s})\n" ++
            "      (pads allowed)\n" ++
            "      (copperpour not_allowed)\n" ++
            "      (footprints allowed)\n" ++
            "    )\n" ++
            "    (polygon (pts\n",
        .{ layer, if (vias_not_allowed) "not_allowed" else "allowed" },
    );
    for (points[1..]) |point| {
        const xy = point.asList() orelse continue;
        if (xy.len < 2) continue;
        const x = xy[0].asNumber() orelse continue;
        const y = xy[1].asNumber() orelse continue;
        try w.print("      (xy {d:.4} {d:.4})\n", .{ x, y });
    }
    try w.writeAll("    ))\n  )\n");
}

fn emitKicadPad(allocator: std.mem.Allocator, w: anytype, node: ast.Node) !void {
    const children = node.asList() orelse return;
    if (children.len < pad_min_children) return;

    // (pad NAME TYPE SHAPE (pos X Y) (size W H))
    const pad_type_internal = children[2].asAtom() orelse return;
    const pad_shape_internal = children[3].asAtom() orelse return;

    // Reverse map types
    const kicad_type = reverseMapPadType(pad_type_internal);
    const kicad_shape = pad_shape_internal; // shapes are same names

    var x: f64 = 0;
    var y: f64 = 0;
    var rot: f64 = 0;
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
    var rratio: f64 = geometry.default_rratio;

    for (children[4..]) |child| {
        if (child.isForm("roundrect_rratio")) {
            const cl = child.asList().?;
            if (cl.len >= 2) rratio = cl[1].asNumber() orelse geometry.default_rratio;
        }
        if (child.isForm("pos")) {
            const p = readPadPos(child);
            x = p.x;
            y = p.y;
            rot = p.rot;
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
            try emitKicadCustomPad(allocator, w, pad_name, kicad_type, sx, sy, pn, no_paste);
            return;
        }
    }
    const emit_shape = if (std.mem.eql(u8, kicad_shape, "custom")) "rect" else kicad_shape;
    try w.print("  (pad \"{s}\" {s} {s}\n", .{ pad_name, kicad_type, emit_shape });

    try emitPadAt(w, x, y, rot);
    // `(size …)` stays the pad's own unrotated W×H — both frames measure a pad
    // in its local axes and turn it afterwards — so only the angle is mapped.
    // {d:.4} = KiCad's own metric precision; {d:.2} lost up to 5 µm per pass.
    try w.print("    (size {d:.4} {d:.4})\n", .{ sx, sy });

    // Drill for through-hole pads
    if (std.mem.eql(u8, pad_type_internal, "thru") or std.mem.eql(u8, pad_type_internal, "npth")) {
        if (has_drill) {
            if (is_oval_drill) {
                try w.print("    (drill oval {d:.4} {d:.4})\n", .{ drill_x, drill_y });
            } else {
                try w.print("    (drill {d:.4})\n", .{drill_x});
            }
        } else {
            // Fallback: no drill declared on a thru-hole/npth pad. Guessing the
            // hole as the pad's min dimension yields a pad-sized hole (zero
            // annular ring) — an unmanufacturable footprint. Warn loudly so the
            // omission is fixed at the source .sexp rather than shipped silently.
            const drill = @min(sx, sy);
            std.log.warn(
                "export-kicad: thru-hole pad \"{s}\" has no (drill …) — guessing {d:.4} mm (pad min dimension, zero annular ring); add an explicit drill to the footprint",
                .{ pad_name, drill },
            );
            try w.print("    (drill {d:.4})\n", .{drill});
        }
    }

    // Layers
    if (std.mem.eql(u8, pad_type_internal, "smd")) {
        if (no_paste) {
            try w.writeAll(smd_pad_layers);
        } else {
            try w.writeAll(smd_pad_layers_pasted);
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

/// A pad's placement as the `.sexp` states it: centre plus its own rotation
/// about that centre, in netlisp's frame.
const PadPos = struct { x: f64 = 0, y: f64 = 0, rot: f64 = 0 };

/// Read a pad's `(pos X Y [ROT])` form. The optional third token is the pad's
/// own rotation; `geometry.parsePad` reads it into `Pad.rot`, so dropping it
/// here shipped axis-aligned copper for a pad the router, the DRC and the
/// layout PNG were already treating as turned.
fn readPadPos(node: ast.Node) PadPos {
    const cl = node.asList() orelse return .{};
    if (cl.len < 3) return .{};
    return .{
        .x = cl[1].asNumber() orelse 0,
        .y = cl[2].asNumber() orelse 0,
        .rot = if (cl.len >= 4) (cl[3].asNumber() orelse 0) else 0,
    };
}

/// Write a pad's `(at X Y [ANGLE])` line. KiCad's third token is emitted only
/// when the pad is actually turned, so every unrotated pad keeps the bare
/// two-number form pcbnew writes (and existing exports stay byte-identical).
fn emitPadAt(w: anytype, x: f64, y: f64, rot: f64) !void {
    const angle = kicadPadAngle(rot);
    // {d:.4} = KiCad's own metric precision; {d:.2} lost up to 5 µm per pass.
    if (angle == 0) return w.print("    (at {d:.4} {d:.4})\n", .{ x, y });
    return w.print("    (at {d:.4} {d:.4} {d:.4})\n", .{ x, y, angle });
}

/// The KiCad `(at X Y ANGLE)` angle for a pad netlisp holds at `rot` degrees.
///
/// The two frames turn opposite ways over the same y-down coordinates. netlisp
/// rotates a pad with `pose_math.rotate` — `[[cos, −sin], [sin, cos]]` on the
/// raw numbers — which is what `placement/pad_shape.worldShape` measures a
/// rotated pad's copper by, and so what the router, the DRC, the pour and the
/// layout PNG all mean. KiCad's angles are counter-clockwise *as displayed*,
/// i.e. `[[cos, sin], [−sin, cos]]` on the same y-down numbers. So the exported
/// angle is the netlisp angle negated, normalised into [0, 360) the way pcbnew
/// spells it.
///
/// This is the identical relation the rest of the KiCad bridge already encodes
/// for a part pose and for a board pad: `serve/sync.zig`'s `netlispRotToKicad`
/// is `mod(360 − rot, 360)`, and `kicad_pcb/router_adapter.zig` recovers a
/// board pad's netlisp rotation as `footprint_rotation − pad.at.rotation_deg`.
/// Verified against KiCad 10's own library: in
/// `Valve.pretty/Valve_ECC-83-2.kicad_mod` the nine oval pads ring a centre at
/// (−3.45, −4.75) and each carries `at … −θ` for its own bearing θ, which lands
/// every oval tangential to the ring under KiCad's sense and at nine
/// inconsistent angles under the opposite one.
fn kicadPadAngle(rot: f64) f64 {
    return @mod(360.0 - rot, 360.0);
}

/// Resolve a pad-name node (atom / string / numeric) into a string, writing a
/// numeric name into `buf`. Returns null if the node is none of those.
fn padName(node: ast.Node, buf: []u8) ?[]const u8 {
    if (node.asAtom() orelse node.asString()) |s| return s;
    if (node.asNumber()) |num| {
        return std.fmt.bufPrint(buf, "{d}", .{numeric.checkedInt(i64, num) orelse 0}) catch null;
    }
    return null;
}

/// Emit a KiCad custom pad. The `.sexp` stores the outline in `(poly …)` as
/// footprint-absolute points with `(pos …)` at the polygon's bbox center; KiCad
/// wants pad-local points, so each is rewritten relative to `(at x y)`. A small
/// anchor rect sits inside the polygon so the union is exactly the outline.
///
/// The `at` here is deliberately left UNROTATED even when the pad's
/// `(pos X Y ROT)` carries an angle, because for a polygon pad that angle is
/// already spent. `convert/footprint.zig` bakes the source pad's rotation into
/// these absolute points when it imports the `.kicad_mod`, and
/// `placement/pad_shape.worldShape` takes its `pad.poly.len >= 3` branch first
/// and never applies `pad.rot` — so the outline, not the angle, is what every
/// netlisp consumer measures. KiCad rotates a custom pad's `(primitives …)`
/// with the pad (its stock `SolderJumper-3_P2.0mm_Open_TrianglePad1.0x1.5mm`
/// draws one triangle body and turns the far pad `at 2 0 180` to face it), so
/// emitting the angle as well would turn copper that is already turned. Simple
/// pads are the other case and do carry it — see `kicadPadAngle`.
fn emitKicadCustomPad(
    allocator: std.mem.Allocator,
    w: anytype,
    pad_name: []const u8,
    kicad_type: []const u8,
    bw: f64,
    bh: f64,
    poly_node: ast.Node,
    no_paste: bool,
) !void {
    const pl = poly_node.asList() orelse return;
    if (pl.len < 4) return;
    const points = try allocator.alloc([2]f64, pl.len - 1);
    var point_count: usize = 0;
    var x0 = std.math.inf(f64);
    var y0 = std.math.inf(f64);
    var x1 = -std.math.inf(f64);
    var y1 = -std.math.inf(f64);
    for (pl[1..]) |pt| {
        const ptl = pt.asList() orelse continue;
        if (ptl.len < 2) continue;
        const ax = ptl[0].asNumber() orelse continue;
        const ay = ptl[1].asNumber() orelse continue;
        points[point_count] = .{ ax, ay };
        point_count += 1;
        x0 = @min(x0, ax);
        y0 = @min(y0, ay);
        x1 = @max(x1, ax);
        y1 = @max(y1, ay);
    }
    if (point_count < 3) return;
    const anchor = customPadAnchorRect(
        points[0..point_count],
        .{ x0, y0, x1, y1 },
        @min(@min(bw, bh) * 0.5, custom_pad_anchor_mm),
    );
    try w.print("  (pad \"{s}\" {s} custom\n", .{ pad_name, kicad_type });
    try w.print("    (at {d:.3} {d:.3})\n", .{ anchor.center[0], anchor.center[1] });
    try w.print("    (size {d:.3} {d:.3})\n", .{ anchor.size, anchor.size });
    if (no_paste) {
        try w.writeAll(smd_pad_layers);
    } else {
        try w.writeAll(smd_pad_layers_pasted);
    }
    try w.writeAll("    (options (clearance outline) (anchor rect))\n");
    try w.writeAll("    (primitives\n      (gr_poly\n        (pts\n");
    for (pl[1..]) |pt| {
        const ptl = pt.asList() orelse continue;
        if (ptl.len < 2) continue;
        const ax = ptl[0].asNumber() orelse continue;
        const ay = ptl[1].asNumber() orelse continue;
        try w.print("          (xy {d:.3} {d:.3})\n", .{ ax - anchor.center[0], ay - anchor.center[1] });
    }
    try w.writeAll("        )\n        (width 0)\n        (fill yes)\n      )\n    )\n");
    try w.writeAll("  )\n");
}

fn customPadAnchorRect(
    poly: []const [2]f64,
    bounds: [4]f64,
    max_size: f64,
) struct { center: [2]f64, size: f64 } {
    const box_center = [2]f64{ (bounds[0] + bounds[2]) / 2, (bounds[1] + bounds[3]) / 2 };
    const center = if (pointInCustomPad(poly, box_center[0], box_center[1]))
        box_center
    else
        widestCustomPadSpan(poly, box_center[1]) orelse box_center;
    var size = @min(max_size, @min(bounds[2] - bounds[0], bounds[3] - bounds[1]) * 0.5);
    for (0..32) |_| {
        const half = size / 2;
        if (pointInCustomPad(poly, center[0] - half, center[1] - half) and
            pointInCustomPad(poly, center[0] + half, center[1] - half) and
            pointInCustomPad(poly, center[0] + half, center[1] + half) and
            pointInCustomPad(poly, center[0] - half, center[1] + half))
        {
            return .{ .center = center, .size = size };
        }
        size /= 2;
    }
    return .{ .center = center, .size = size };
}

fn widestCustomPadSpan(poly: []const [2]f64, y: f64) ?[2]f64 {
    var intersections: [512]f64 = undefined;
    var count: usize = 0;
    var previous = poly[poly.len - 1];
    for (poly) |point| {
        if ((previous[1] > y) != (point[1] > y)) {
            if (count == intersections.len) return null;
            intersections[count] = previous[0] + (y - previous[1]) /
                (point[1] - previous[1]) * (point[0] - previous[0]);
            count += 1;
        }
        previous = point;
    }
    if (count < 2) return null;
    std.mem.sort(f64, intersections[0..count], {}, std.sort.asc(f64));
    var best: ?[2]f64 = null;
    var i: usize = 0;
    while (i + 1 < count) : (i += 2) {
        const candidate = [2]f64{ intersections[i], intersections[i + 1] };
        if (best == null or candidate[1] - candidate[0] > best.?[1] - best.?[0]) best = candidate;
    }
    const span = best orelse return null;
    return .{ (span[0] + span[1]) / 2, y };
}

fn pointInCustomPad(poly: []const [2]f64, x: f64, y: f64) bool {
    var inside = false;
    var previous = poly[poly.len - 1];
    for (poly) |point| {
        if ((previous[1] > y) != (point[1] > y)) {
            const crossing = previous[0] + (y - previous[1]) /
                (point[1] - previous[1]) * (point[0] - previous[0]);
            if (x < crossing) inside = !inside;
        }
        previous = point;
    }
    return inside;
}

fn emitKicadCourtyard(w: anytype, node: ast.Node) !void {
    const children = node.asList() orelse return;
    // The placement page draws each part's courtyard as `geometry.load`'s
    // half-extents, which add `BBOX_MARGIN_MM` (a placement air-gap) on every
    // side. KiCad's F.CrtYd is meant to match that *displayed* courtyard, so we
    // inflate the raw rect/circle by the same margin here. The rect uses the
    // page's origin-centred max-abs convention (`parseRectExt`) so the emitted
    // box is identical to what the tool renders.
    const M = geometry.bbox_margin_mm;
    // (courtyard (rect X1 Y1 X2 Y2)) and (courtyard (circle (CX CY) R))
    for (children[1..]) |child| {
        if (child.isForm("rect")) {
            const cl = child.asList() orelse continue;
            if (cl.len >= rect_min_children) {
                const x1 = cl[1].asNumber() orelse 0;
                const y1 = cl[2].asNumber() orelse 0;
                const x2 = cl[3].asNumber() orelse 0;
                const y2 = cl[4].asNumber() orelse 0;
                const hw = @max(@abs(x1), @abs(x2)) + M;
                const hh = @max(@abs(y1), @abs(y2)) + M;
                try w.print("  (fp_rect (start {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ -hw, -hh, hw, hh });
                try w.writeAll("    (stroke (width 0.05) (type default))\n");
                try w.writeAll(kicad_fill_none);
                try w.writeAll(courtyard_layer_line);
                try w.writeAll("  )\n");
            }
        } else if (child.isForm("circle")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 3) continue;
            const center = cl[1].asList() orelse continue;
            if (center.len < 2) continue;
            const cx = center[0].asNumber() orelse continue;
            const cy = center[1].asNumber() orelse continue;
            const r = (cl[2].asNumber() orelse continue) + M;
            try w.print("  (fp_circle (center {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ cx, cy, cx + r, cy });
            try w.writeAll("    (stroke (width 0.05) (type default))\n");
            try w.writeAll(kicad_fill_none);
            try w.writeAll(courtyard_layer_line);
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
            if (cl.len >= rect_min_children) {
                const x1 = cl[1].asNumber() orelse continue;
                const y1 = cl[2].asNumber() orelse continue;
                const x2 = cl[3].asNumber() orelse continue;
                const y2 = cl[4].asNumber() orelse continue;
                try w.print("  (fp_rect (start {d:.2} {d:.2}) (end {d:.2} {d:.2})\n", .{ x1, y1, x2, y2 });
                try w.print(kicad_stroke_fmt, .{width});
                try w.writeAll(kicad_fill_none);
                try w.print(kicad_layer_fmt, .{layer});
                try w.writeAll("  )\n");
            }
        }
        if (child.isForm("poly")) {
            const cl = child.asList() orelse continue;
            // (poly (X Y) (X Y) …) — a filled outline (pin-1 marker, body shape)
            if (cl.len >= poly_min_points + 1) {
                try w.writeAll("  (fp_poly\n    (pts");
                for (cl[1..]) |pt| {
                    const p = pt.asList() orelse continue;
                    if (p.len < 2) continue;
                    const x = p[0].asNumber() orelse continue;
                    const y = p[1].asNumber() orelse continue;
                    try w.print(" (xy {d:.2} {d:.2})", .{ x, y });
                }
                try w.writeAll(")\n");
                try w.print(kicad_stroke_fmt, .{width});
                try w.writeAll("    (fill solid)\n");
                try w.print(kicad_layer_fmt, .{layer});
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
                    try w.print(kicad_stroke_fmt, .{width});
                    try w.print(kicad_layer_fmt, .{layer});
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
                    try w.print(kicad_stroke_fmt, .{width});
                    try w.writeAll(kicad_fill_none);
                    try w.print(kicad_layer_fmt, .{layer});
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
        const basename = entry.name[0 .. entry.name.len - step_ext_len]; // strip .step
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

/// The angle token of the `n`-th `(at …)` line in an emitted `.kicad_mod`, or
/// null when that pad emitted the bare two-number form. Only pads emit an
/// `(at …)` line, so `n` indexes pads in source order. Test support for the
/// differential guard below.
fn nthPadAtAngle(mod: []const u8, n: usize) ?f64 {
    var lines = std.mem.splitScalar(u8, mod, '\n');
    var seen: usize = 0;
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "(at ") or !std.mem.endsWith(u8, t, ")")) continue;
        if (seen != n) {
            seen += 1;
            continue;
        }
        var f = std.mem.tokenizeScalar(u8, t[4 .. t.len - 1], ' ');
        _ = f.next() orelse return null;
        _ = f.next() orelse return null;
        return std.fmt.parseFloat(f64, f.next() orelse return null) catch null;
    }
    return null;
}

// spec: export_kicad - Emits a pad's (pos X Y ROT) rotation as KiCad's (at X Y ANGLE) third argument, negated into KiCad's counter-clockwise frame
test "exportFootprintMod emits the pad rotation geometry.zig reads, mapped into KiCad's frame" {
    // Two readers, one grammar: `geometry.parsePad` takes `(pos X Y ROT)` into
    // `Pad.rot` (which is what the router, DRC and layout PNG measure rotated
    // copper by) and this exporter takes the same token into the `.kicad_mod`.
    // They silently disagreed — the exporter read only X and Y — so a pad
    // netlisp treated as turned reached the board as axis-aligned copper.
    const src =
        \\(footprint "rot-fixture"
        \\  (pad 1 smd rect (pos 1.0 2.0 45) (size 1.2 0.6))
        \\  (pad 2 smd rect (pos -1.0 2.0) (size 1.2 0.6))
        \\  (pad 3 smd roundrect (pos 0.0 -2.0 -30) (size 1.2 0.6)))
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    try tmp.dir.createDirPath(std.testing.io, "lib/footprints");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/footprints/rot-fixture.sexp", .data = src });

    const geom = geometry.load(arena.allocator(), project_dir, "rot-fixture", 0, 0);
    try std.testing.expect(!geom.fallback);
    try std.testing.expectEqual(@as(usize, 3), geom.pads.len);

    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);

    for (geom.pads, 0..) |pad, i| {
        const want = kicadPadAngle(pad.rot);
        const got = nthPadAtAngle(out, i);
        if (want == 0) {
            // An unrotated pad keeps the bare two-number `at` pcbnew writes.
            try std.testing.expectEqual(@as(?f64, null), got);
        } else {
            try std.testing.expectApproxEqAbs(want, got orelse return error.MissingPadAngle, 1e-4);
        }
    }
    // Concretely: netlisp +45° is KiCad 315°, netlisp −30° is KiCad 30°.
    try std.testing.expect(std.mem.indexOf(u8, out, "(at 1.0000 2.0000 315.0000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(at -1.0000 2.0000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(at 0.0000 -2.0000 30.0000)") != null);
    // Size stays the pad's own unrotated W×H in both frames.
    try std.testing.expect(std.mem.indexOf(u8, out, "(size 1.2000 0.6000)") != null);
}

// spec: export_kicad - Leaves a custom pad's exported (at …) unrotated because its (poly …) outline already carries the rotation
test "exportFootprintMod leaves a rotated custom pad's (at …) unrotated" {
    const src =
        \\(footprint "rot-custom"
        \\  (pad 1 smd custom (pos 1.000 1.000 30) (size 2.000 2.000)
        \\    (poly (0.000 0.000) (2.000 0.000) (2.000 2.000) (0.000 2.000))))
    ;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena.allocator());
    try tmp.dir.createDirPath(std.testing.io, "lib/footprints");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/footprints/rot-custom.sexp", .data = src });

    // The geometry reader still records the angle …
    const geom = geometry.load(arena.allocator(), project_dir, "rot-custom", 0, 0);
    try std.testing.expectEqual(@as(usize, 1), geom.pads.len);
    try std.testing.expectApproxEqAbs(@as(f64, 30), geom.pads[0].rot, 1e-9);
    // … but the outline it also carries is what every consumer measures:
    // `pad_shape.worldShape` takes its poly branch and never applies `rot`.
    try std.testing.expect(geom.pads[0].poly.len >= 3);

    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    // So the primitives, already turned, must not be turned a second time.
    try std.testing.expectEqual(@as(?f64, null), nthPadAtAngle(out, 0));
    try std.testing.expect(std.mem.indexOf(u8, out, "(at 1.000 1.000)") != null);
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

test "exportFootprintMod names the body and SMD pad layers with KiCad's own spellings" {
    // spec: export_kicad - Names the exported footprint's own layer and each SMD pad's copper/mask/paste layers with KiCad's spellings, with paste dropped on a no-paste pad
    const src =
        \\(footprint "T"
        \\  (pad 1 smd rect (pos 0 0) (size 1 1))
        \\  (pad 2 smd rect (pos 2 0) (size 1 1) no-paste))
    ;
    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    // The footprint's own layer, and a pasted pad's full copper/mask/paste set.
    try std.testing.expect(std.mem.indexOf(u8, out, "  (layer \"F.Cu\")\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(layers \"F.Cu\" \"F.Mask\" \"F.Paste\")") != null);
    // A no-paste pad keeps copper + mask and drops the stencil aperture.
    try std.testing.expect(std.mem.indexOf(u8, out, "(layers \"F.Cu\" \"F.Mask\")\n") != null);
}

test "exportFootprintMod strokes F.SilkS at the fabricated width and F.Fab at the documentation width" {
    // spec: export_kicad - Strokes an exported footprint's F.SilkS art at the 0.15 mm the Gerber writer plots, and keeps the never-manufactured F.Fab at KiCad's 0.1 mm documentation default
    const src =
        \\(footprint "T"
        \\  (pad 1 smd rect (pos 0 0) (size 1 1))
        \\  (silkscreen (line (-1 -1) (1 -1)))
        \\  (fab (line (-2 -2) (2 -2))))
    ;
    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    // Silk is MANUFACTURED: the .kicad_mod handoff must plot the same 0.15 mm
    // stroke export_gerber.zig pours for the very same (silkscreen …) form.
    try std.testing.expect(std.mem.indexOf(u8, out, "(fp_line (start -1.00 -1.00) (end 1.00 -1.00)\n" ++
        "    (stroke (width 0.15) (type default))\n" ++
        "    (layer \"F.SilkS\")") != null);
    // F.Fab is documentation only, so it keeps KiCad's thinner editor default.
    try std.testing.expect(std.mem.indexOf(u8, out, "(fp_line (start -2.00 -2.00) (end 2.00 -2.00)\n" ++
        "    (stroke (width 0.10) (type default))\n" ++
        "    (layer \"F.Fab\")") != null);
}

test "exportFootprintMod inflates the F.CrtYd courtyard by the placement margin" {
    // spec: export_kicad - Inflates the emitted F.CrtYd courtyard by BBOX_MARGIN_MM so KiCad matches the placement page's drawn courtyard
    const src =
        \\(footprint "T"
        \\  (pad 1 smd rect (pos 0 0) (size 1 1))
        \\  (courtyard (rect -0.85 -0.45 0.85 0.45)))
    ;
    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    // Raw rect is ±0.85/±0.45; +0.15/side → ±1.00/±0.60 on F.CrtYd.
    try std.testing.expect(std.mem.indexOf(u8, out, "(fp_rect (start -1.00 -0.60) (end 1.00 0.60)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(layer \"F.CrtYd\")") != null);
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

test "exportFootprintMod puts a concave custom pad anchor on copper" {
    const src =
        \\(footprint "concave"
        \\  (pad 3 smd custom (pos 1.500 1.500) (size 3.000 3.000)
        \\    (poly (0.000 2.000) (2.000 2.000) (2.000 0.000) (3.000 0.000)
        \\          (3.000 3.000) (0.000 3.000))))
    ;
    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    // The bbox centre (1.5,1.5) is the L-shaped pad's empty notch.  The KiCad
    // anchor is moved onto its right-hand copper prong while every primitive
    // remains at the same footprint-absolute coordinate after rebasing.
    try std.testing.expect(std.mem.indexOf(u8, out, "(at 2.500 1.500)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(xy -2.500 0.500)") != null);
}

test "exportFootprintMod emits a copper-pour-only footprint keepout" {
    const src =
        \\(footprint "T"
        \\  (pad 1 smd rect (pos 0 0) (size 1 1))
        \\  (copper-pour-keepout F.Cu
        \\    (poly (-1 -1) (1 -1) (1 1) (-1 1))))
    ;
    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(layer \"F.Cu\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(copperpour not_allowed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(vias allowed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(xy -1.0000 -1.0000)") != null);
}

// spec: export_kicad - Escapes a 3D-model filename in the emitted .kicad_mod so a quote or backslash in the file name cannot break the (model …) path
test "exportFootprintMod escapes a hostile 3D-model filename" {
    const src =
        \\(footprint "T"
        \\  (pad 1 smd rect (pos 0 0) (size 1 1)))
    ;
    // A model file name is read off a directory scan, not the tokenizer: both
    // of these bytes are legal in a filename here and neither can be trusted.
    const model = "Part \"A\"\\rev.step";
    const out = try exportFootprintMod(std.testing.allocator, src, model, null, null);
    defer std.testing.allocator.free(out);

    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "(model \"${KIPRJMOD}/models/Part \\\"A\\\"\\\\rev.step\"",
    ) != null);
    // Unescaped, the raw `"` closes the path token and the rest of the file is
    // read as garbage — so a successful parse is the real assertion.
    const nodes = try parser_mod.parse(std.testing.allocator, out);
    defer parser_mod.freeNodes(std.testing.allocator, nodes);
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
}

// spec: export_kicad - Replaces a source .kicad_mod's (model …) block by scanning parens outside quoted strings, so a parenthesis in the model path cannot mis-splice the file
test "useSourceKicadMod replaces a (model …) block whose path holds a parenthesis" {
    // A vendor `.kicad_mod` whose STEP path carries a revision in brackets. The
    // old depth walk counted that `(` as structure and cut the block short,
    // leaving the tail of the old model spliced into the output.
    const src =
        \\(footprint "Vendor"
        \\  (pad "1" smd rect (at 0 0) (size 1 1) (layers "F.Cu"))
        \\  (model "${KIPRJMOD}/3d/Part(rev2).step"
        \\    (offset (xyz 9 9 9))
        \\    (scale (xyz 1 1 1))
        \\    (rotate (xyz 7 7 7))
        \\  )
        \\)
    ;
    const out = try useSourceKicadMod(std.testing.allocator, src, "new.step", null, null);
    defer std.testing.allocator.free(out);

    // The whole old block is gone — path, and the offset/rotate that trailed it.
    try std.testing.expect(std.mem.indexOf(u8, out, "Part(rev2).step") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(xyz 9 9 9)") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(xyz 7 7 7)") == null);
    // … replaced by exactly one new model reference, in a file that re-parses.
    try std.testing.expect(std.mem.indexOf(u8, out, "(model \"${KIPRJMOD}/models/new.step\"") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "(model "));
    const nodes = try parser_mod.parse(std.testing.allocator, out);
    defer parser_mod.freeNodes(std.testing.allocator, nodes);
    try std.testing.expectEqual(@as(usize, 1), nodes.len);

    // A model block that never closes is refused, not half-replaced: the old
    // walk fell out of its loop with the end still at the start and wrote the
    // new block in front of the entire unterminated old one.
    const truncated =
        \\(footprint "V"
        \\  (model "x.step"
        \\    (offset (xyz 0 0 0))
    ;
    try std.testing.expectError(
        error.InvalidFormat,
        useSourceKicadMod(std.testing.allocator, truncated, "new.step", null, null),
    );
}

test "exportFootprintMod emits a footprint keepout that also blocks vias" {
    const src =
        \\(footprint "T"
        \\  (pad 1 smd rect (pos 0 0) (size 1 1))
        \\  (copper-pour-keepout F.Cu
        \\    (vias not_allowed)
        \\    (poly (-1 -1) (1 -1) (1 1) (-1 1))))
    ;
    const out = try exportFootprintMod(std.testing.allocator, src, null, null, null);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(copperpour not_allowed)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(vias not_allowed)") != null);
}
