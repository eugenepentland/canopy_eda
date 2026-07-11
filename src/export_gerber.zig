//! Gerber (RS-274X / X2) writer — the copper half of the netlisp-native
//! manufacturing package (`export_fab.zig` holds the drill + centroid half).
//! One call per output file: outer signal copper (pads + the saved layout's
//! routed tracks/vias), inner planes (solid pour with clearance antipads
//! around foreign holes), solder mask, paste, silkscreen (footprint art +
//! 5x7 ref-des strokes), and the board-profile Edge.Cuts.
//!
//! What the files say is exactly what the placement/routing model believes:
//! pads flash as their model shapes (rect/roundrect → R, circle → C, oval →
//! O, custom outlines as G36 regions via the same `pad_shape.worldShape` the
//! DRC measures), tracks are the persisted routed copper, and plane layers
//! follow the design's `(stackup …)` form — no form means the router's
//! legacy implicit 4-layer model, emitted as two inner ground planes.
//!
//! Everything is emitted through the shared `export_fab.Frame` (y-up, origin
//! at the board outline's bottom-left), so gerbers, Excellon drills, and the
//! centroid CSV stack exactly in CAM.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const geometry = @import("placement/geometry.zig");
const pad_shape = @import("placement/pad_shape.zig");
const pour = @import("placement/pour.zig");
const export_kicad = @import("export_kicad.zig");
const export_fab = @import("export_fab.zig");
const font = @import("font5x7.zig");

// Solder-mask margin and copper-pour isolation are no longer hard-coded here —
// they live in `optimizer.DesignRules` (`mask_margin` / `pour_clearance` /
// `copper_edge`), resolved from the design's `(design-rules …)` form with the
// old constants (0.05 / 0.3) as defaults, and read via `placement.rules.design`.

/// Silkscreen stroke width (mm) — footprint art and ref-des text alike.
const silk_w_mm: f64 = 0.15;
/// Ref-des text pixel pitch (mm); glyphs are 5x7 px, so cap height ~1 mm.
const text_px_mm: f64 = 0.15;
/// Board-profile line width (mm).
const edge_w_mm: f64 = 0.1;

/// Which net an inner/outer plane pour carries: a `(plane IDX "NET")` name,
/// or the legacy implicit model's "every ground-named net".
pub const PlaneNet = union(enum) { named: []const u8, ground };

/// A solid-pour copper layer: its 1-based stack index + the net it carries.
pub const PlaneLayer = struct { index: u8, net: PlaneNet };

/// An inner ROUTABLE copper layer: its 1-based stack index + the signal-layer
/// index (2..) the router's `Track.layer` uses for it.
pub const InnerSignal = struct { index: u8, sig: u8 };

/// Identity of one Gerber output file.
pub const Layer = union(enum) {
    /// Outer signal copper (pads, routed tracks, via lands).
    copper: optimizer.Side,
    /// Inner solid plane.
    plane: PlaneLayer,
    /// A plane-free inner copper layer the router treats as a signal layer —
    /// emits that layer's routed tracks, via lands, and through-pad barrels.
    inner_signal: InnerSignal,
    mask: optimizer.Side,
    paste: optimizer.Side,
    silk: optimizer.Side,
    edge,
};

/// One planned output file: which layer, the file-name suffix appended to
/// the design name (KiCad naming + Protel extensions, so every CAM package
/// auto-detects it), and the X2 `.FileFunction` attribute value.
pub const LayerFile = struct { layer: Layer, suffix: []const u8, function: []const u8 };

/// The routed copper a layout persisted — what the signal layers draw.
pub const Copper = struct {
    tracks: []const router.Track = &.{},
    vias: []const router.Via = &.{},
};

pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error;

/// Plan the full Gerber file set for `placement` from its `(stackup …)`
/// rules: no stackup form = the router's legacy implicit 4-layer model (two
/// inner ground planes), a declared stackup gets its declared planes (inner
/// signal layers it never names come out blank), and mask/paste/silk/edge
/// always ship. Slices are arena-allocated.
pub fn planLayers(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]const LayerFile {
    const rules = placement.rules;
    var out: std.ArrayList(LayerFile) = .empty;
    const implicit = rules.plane_nets == null;
    const n: u8 = if (implicit) 4 else @max(2, rules.copper_layers);

    try out.append(arena, .{ .layer = .{ .copper = .top }, .suffix = "F_Cu.gtl", .function = "Copper,L1,Top" });
    if (implicit) {
        try out.append(arena, .{ .layer = .{ .plane = .{ .index = 2, .net = .ground } }, .suffix = "In1_Cu.g2", .function = "Copper,L2,Inner" });
        try out.append(arena, .{ .layer = .{ .plane = .{ .index = 3, .net = .ground } }, .suffix = "In2_Cu.g3", .function = "Copper,L3,Inner" });
    } else {
        // Signal-layer indices for plane-free inners count up from 2 in stack
        // order — the same assignment `BoardRules.signalStackIndex` makes, so
        // a persisted `Track.layer` lands on exactly this file.
        var sig: u8 = 2;
        var i: u8 = 2;
        while (i < n) : (i += 1) {
            const suffix = try std.fmt.allocPrint(arena, "In{d}_Cu.g{d}", .{ i - 1, i });
            var layer: Layer = undefined;
            var function: []const u8 = undefined;
            if (declaredPlaneAt(rules, i)) |net| {
                layer = .{ .plane = .{ .index = i, .net = .{ .named = net } } };
                function = try std.fmt.allocPrint(arena, "Copper,L{d},Inner", .{i});
            } else {
                layer = .{ .inner_signal = .{ .index = i, .sig = sig } };
                // The X2-spec spelling for an inner copper layer is "Inr";
                // the plane files keep the writer's established "Inner" so
                // existing declared-plane packages don't churn.
                function = try std.fmt.allocPrint(arena, "Copper,L{d},Inr", .{i});
                sig += 1;
            }
            try out.append(arena, .{ .layer = layer, .suffix = suffix, .function = function });
        }
    }
    try out.append(arena, .{
        .layer = .{ .copper = .bottom },
        .suffix = "B_Cu.gbl",
        .function = try std.fmt.allocPrint(arena, "Copper,L{d},Bot", .{n}),
    });

    try out.append(arena, .{ .layer = .{ .mask = .top }, .suffix = "F_Mask.gts", .function = "Soldermask,Top" });
    try out.append(arena, .{ .layer = .{ .mask = .bottom }, .suffix = "B_Mask.gbs", .function = "Soldermask,Bot" });
    try out.append(arena, .{ .layer = .{ .paste = .top }, .suffix = "F_Paste.gtp", .function = "Paste,Top" });
    try out.append(arena, .{ .layer = .{ .paste = .bottom }, .suffix = "B_Paste.gbp", .function = "Paste,Bot" });
    try out.append(arena, .{ .layer = .{ .silk = .top }, .suffix = "F_Silkscreen.gto", .function = "Legend,Top" });
    try out.append(arena, .{ .layer = .{ .silk = .bottom }, .suffix = "B_Silkscreen.gbo", .function = "Legend,Bot" });
    try out.append(arena, .{ .layer = .edge, .suffix = "Edge_Cuts.gm1", .function = "Profile,NP" });
    return out.toOwnedSlice(arena);
}

/// Write the Gerber Job File (`.gbrjob`, JSON) that ties the package together:
/// `GeneralSpecs` (board size from the outline, copper-layer count from the
/// stackup) + `FilesAttributes` (each Gerber's archive path + its
/// `FileFunction`/`FilePolarity`, matching the `%TF.*` attributes the layers
/// carry). Many fabs' CAM reads this for automatic stackup/layer detection.
/// `files` is the same `planLayers` set; `name_prefix` is the design name the
/// archive entries are prefixed with (so `Path` matches the ZIP entry).
pub fn writeJobFile(
    w: *std.Io.Writer,
    placement: optimizer.Placement,
    files: []const LayerFile,
    name_prefix: []const u8,
) std.Io.Writer.Error!void {
    const r = export_fab.outlineRect(placement);
    const rules = placement.rules;
    const layer_count: u8 = if (rules.plane_nets == null) 4 else @max(2, rules.copper_layers);
    // Count copper files (the FileFunction begins with "Copper") for the
    // MaterialStackup-less GeneralSpecs summary.
    try w.writeAll("{\n  \"Header\": {\n");
    try w.writeAll("    \"GenerationSoftware\": { \"Vendor\": \"netlisp\", \"Application\": \"netlisp\", \"Version\": \"1\" }\n");
    try w.writeAll("  },\n  \"GeneralSpecs\": {\n");
    try w.writeAll("    \"ProjectId\": { \"Name\": ");
    try writeJsonStr(w, name_prefix);
    try w.writeAll(", \"GUID\": \"\", \"Revision\": \"\" },\n");
    try w.print("    \"Size\": {{ \"X\": {d:.3}, \"Y\": {d:.3} }},\n", .{ r.w, r.h });
    try w.print("    \"LayerNumber\": {d},\n", .{layer_count});
    // Finished board thickness from the design's `(stackup … (thickness MM))`;
    // an unset thickness keeps the byte-identical fab-standard 1.6 mm default.
    if (rules.board_thickness > 0) {
        try w.print("    \"BoardThickness\": {d}\n", .{rules.board_thickness});
    } else {
        try w.writeAll("    \"BoardThickness\": 1.6\n");
    }
    try w.writeAll("  },\n  \"FilesAttributes\": [\n");
    for (files, 0..) |f, i| {
        if (i > 0) try w.writeAll(",\n");
        const polarity = if (f.layer == .mask) "Negative" else "Positive";
        try w.writeAll("    { \"Path\": ");
        // Path = "<name>-<suffix>", the ZIP entry name.
        var buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}-{s}", .{ name_prefix, f.suffix }) catch f.suffix;
        try writeJsonStr(w, path);
        try w.writeAll(", \"FileFunction\": ");
        try writeJsonStr(w, f.function);
        try w.print(", \"FilePolarity\": \"{s}\" }}", .{polarity});
    }
    try w.writeAll("\n  ]\n}\n");
}

/// Minimal JSON string writer for the job file (quotes + backslash escaping).
fn writeJsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Write one complete Gerber file for `layer`. `copper` is the saved
/// layout's persisted routed copper (empty is fine — pads still flash);
/// `texts` are the saved layout's board-level silkscreen labels (only the
/// silk layers consume them); `frame` must be the same package frame every
/// sibling file uses.
pub fn writeLayer(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    texts: []const font.BoardText,
    frame: export_fab.Frame,
    layer: Layer,
    function: []const u8,
) Error!void {
    // Geometry is buffered first so the aperture dictionary it builds can be
    // written into the header ahead of it.
    var body: std.Io.Writer.Allocating = .init(arena);
    var aps = Apertures{};
    var g = Gx{ .w = &body.writer, .aps = &aps, .arena = arena, .frame = frame };

    switch (layer) {
        .copper => |side| try writeCopper(&g, placement, copper, side),
        .plane => |pl| try writePlane(&g, placement, copper, pl),
        .inner_signal => |is| try writeInnerCopper(&g, placement, copper, is.sig),
        .mask => |side| try writeMask(&g, placement, side),
        .paste => |side| try writePaste(&g, placement, side),
        .silk => |side| try writeSilk(&g, placement, side, texts),
        .edge => try writeEdge(&g, placement),
    }

    try w.print("%TF.GenerationSoftware,netlisp,netlisp,1*%\n%TF.FileFunction,{s}*%\n", .{function});
    try w.print("%TF.FilePolarity,{s}*%\n", .{if (layer == .mask) "Negative" else "Positive"});
    if (placement.board_rect == null)
        try w.writeAll("G04 no (board ...) outline authored; profile synthesized from the parts bounding box*\n");
    if (layer == .plane and layer.plane.net == .ground)
        try w.writeAll("G04 implicit stackup: this inner plane pours every ground-named net*\n");
    try w.writeAll("%FSLAX46Y46*%\n%MOMM*%\nG01*\n%LPD*%\n");
    for (aps.list.items, 10..) |ap, code| {
        switch (ap.kind) {
            .c => try w.print("%ADD{d}C,{d:.6}*%\n", .{ code, umToMm(ap.w) }),
            .r => try w.print("%ADD{d}R,{d:.6}X{d:.6}*%\n", .{ code, umToMm(ap.w), umToMm(ap.h) }),
            .o => try w.print("%ADD{d}O,{d:.6}X{d:.6}*%\n", .{ code, umToMm(ap.w), umToMm(ap.h) }),
        }
    }
    try w.writeAll(body.written());
    try w.writeAll("M02*\n");
}

// ── Layer content ───────────────────────────────────────────────────────────

/// Outer signal copper: an optional declared same-index pour (solid, with
/// clearance carved around foreign copper), then pad flashes, routed tracks
/// of this layer, and via lands.
fn writeCopper(g: *Gx, placement: optimizer.Placement, copper: Copper, side: optimizer.Side) Error!void {
    const li: u8 = if (side == .bottom) 1 else 0;
    const stack_idx: u8 = if (side == .top) 1 else bottomIndex(placement.rules);

    // A `(plane IDX "NET")` declared on this OUTER layer: pour the COMPUTED
    // fill (island-free kept components) as the dark base, carve clearance
    // around every foreign feature in clear polarity, then thermally relieve
    // the same-net through-hole pads — the dark copper below re-lands the real
    // features on the cleaned pour.
    if (declaredPlaneAt(placement.rules, stack_idx)) |pour_net| {
        const net: PlaneNet = .{ .named = pour_net };
        const pnet: pour.PlaneNet = .{ .named = pour_net };
        const pc = placement.rules.design.pour_clearance;
        const fill = try pour.compute(g.arena, placement, .{ .tracks = copper.tracks, .vias = copper.vias }, .{ .net = pnet, .side = side, .track_layer = li });
        for (fill.contours) |poly| try regionPoly(g, poly);
        try g.polarity(false);
        const nets = try padNets(g.arena, placement);
        for (placement.parts) |p| {
            for (p.pads) |pad| {
                if (isSmd(pad) and p.side != side) continue;
                if (planeCarries(net, netOfPad(nets, placement, p.ref_des, pad.number))) continue;
                try flashPadBox(g, p, pad, pc);
            }
        }
        for (copper.tracks) |t| {
            if (t.layer != li) continue;
            if (planeCarries(net, netName(placement, t.net))) continue;
            try g.use(.c, t.width + 2 * pc, 0);
            try g.line(t.x1, t.y1, t.x2, t.y2);
        }
        for (copper.vias) |v| {
            if (planeCarries(net, netName(placement, v.net))) continue;
            try g.use(.c, v.dia + 2 * pc, 0);
            try g.flash(v.x, v.y);
        }
        try g.polarity(true);
        try thermalReliefs(g, placement, nets, net);
    }

    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (pad.npth) continue;
            if (!pad.thru and p.side != side) continue;
            try flashPad(g, p, pad, 0);
        }
    }
    for (copper.tracks) |t| {
        if (t.layer != li) continue;
        try g.use(.c, t.width, 0);
        try g.line(t.x1, t.y1, t.x2, t.y2);
    }
    for (copper.vias) |v| {
        try g.use(.c, v.dia, 0);
        try g.flash(v.x, v.y);
    }
}

/// Inner SIGNAL copper: the routed tracks persisted on signal layer `sig`,
/// via lands (through vias reach every copper layer), and through-pad barrel
/// annuli (a PTH pad has copper on each layer — inner tracks may terminate
/// on it). SMD pads live only on their outer face and never appear here.
fn writeInnerCopper(g: *Gx, placement: optimizer.Placement, copper: Copper, sig: u8) Error!void {
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (!pad.thru or pad.npth) continue;
            try flashPad(g, p, pad, 0);
        }
    }
    for (copper.tracks) |t| {
        if (t.layer != sig) continue;
        try g.use(.c, t.width, 0);
        try g.line(t.x1, t.y1, t.x2, t.y2);
    }
    for (copper.vias) |v| {
        try g.use(.c, v.dia, 0);
        try g.flash(v.x, v.y);
    }
}

/// Inner plane: the COMPUTED fill (kept components only — orphan islands and a
/// plane split by a foreign trace are dropped, not shipped as believed copper)
/// as the dark base, clearance antipads punched over every foreign drilled hole
/// / via, then 4-spoke thermal reliefs on the same-net through-hole barrels (so
/// plane-tied THT pads are reworkable). Same-net vias stay solid.
fn writePlane(g: *Gx, placement: optimizer.Placement, copper: Copper, pl: PlaneLayer) Error!void {
    const pc = placement.rules.design.pour_clearance;
    const pnet: pour.PlaneNet = if (pl.net == .ground) .ground else .{ .named = pl.net.named };
    const fill = try pour.compute(g.arena, placement, .{ .tracks = copper.tracks, .vias = copper.vias }, .{ .net = pnet });
    for (fill.contours) |poly| try regionPoly(g, poly);
    try g.polarity(false);
    const nets = try padNets(g.arena, placement);
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (pad.drill <= 0) continue;
            const foreign = pad.npth or !planeCarries(pl.net, netOfPad(nets, placement, p.ref_des, pad.number));
            if (!foreign) continue;
            try g.use(.c, pad.drill + 2 * pc, 0);
            if (pad.isSlot()) {
                // An oval hole's antipad is the capsule swept by the cleared
                // tool: a round-cap stroke between the two arc centres.
                const e1 = optimizer.worldPadCenter(p, pad.x + pad.slot_half[0], pad.y + pad.slot_half[1]);
                const e2 = optimizer.worldPadCenter(p, pad.x - pad.slot_half[0], pad.y - pad.slot_half[1]);
                try g.line(e1[0], e1[1], e2[0], e2[1]);
            } else {
                const c = optimizer.worldPadCenter(p, pad.x, pad.y);
                try g.flash(c[0], c[1]);
            }
        }
    }
    for (copper.vias) |v| {
        if (planeCarries(pl.net, netName(placement, v.net))) continue;
        try g.use(.c, v.dia + 2 * pc, 0);
        try g.flash(v.x, v.y);
    }
    try g.polarity(true);
    try thermalReliefs(g, placement, nets, pl.net);
}

/// Spoke width (mm) bridging a plane-tied through-hole pad's thermal-relief gap
/// — `max(0.3, default track width)`, a fab-safe KiCad-ish default (not
/// author-tunable this round).
const thermal_spoke_mm: f64 = @max(0.3, (router.RouteParams{}).track_width);

/// Emit 4-spoke thermal reliefs for every same-net THROUGH-HOLE pad the plane
/// `net` carries: clear an isolation ring (gap = pour clearance) around each,
/// re-flash its land, and bridge the ring with an axis-aligned copper cross.
/// SMD same-net pads and vias are left solid (the KiCad default).
fn thermalReliefs(g: *Gx, pl: optimizer.Placement, nets: std.StringHashMapUnmanaged(usize), net: PlaneNet) Error!void {
    const gap = pl.rules.design.pour_clearance;
    for (pl.parts) |p| {
        for (p.pads) |pad| {
            if (pad.npth or !pad.thru or pad.drill <= 0) continue;
            if (!planeCarries(net, netOfPad(nets, pl, p.ref_des, pad.number))) continue;
            try thermalRelief(g, p, pad, gap);
        }
    }
}

/// One pad's thermal relief: a clear isolation ring (pad copper + `gap`), then
/// the dark land re-flash plus a horizontal and vertical spoke crossing it.
fn thermalRelief(g: *Gx, p: optimizer.Part, pad: geometry.Pad, gap: f64) Error!void {
    const sh = try pad_shape.worldShape(g.arena, p, pad);
    const cx = (sh.x0 + sh.x1) / 2;
    const cy = (sh.y0 + sh.y1) / 2;
    const rout = @max(sh.x1 - sh.x0, sh.y1 - sh.y0) / 2 + gap;
    try g.polarity(false);
    try g.use(.c, 2 * rout, 0);
    try g.flash(cx, cy);
    try g.polarity(true);
    try flashPad(g, p, pad, 0);
    const reach = rout + thermal_spoke_mm;
    try g.use(.c, thermal_spoke_mm, 0);
    try g.line(cx - reach, cy, cx + reach, cy);
    try g.line(cx, cy - reach, cx, cy + reach);
}

/// Solder mask (negative: a flash = an OPENING in the mask). SMD pads open
/// on their part's side; through-hole and NPTH pads open on both sides.
/// Vias are tented (no opening).
fn writeMask(g: *Gx, placement: optimizer.Placement, side: optimizer.Side) Error!void {
    const margin = placement.rules.design.mask_margin;
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (isSmd(pad) and p.side != side) continue;
            try flashPad(g, p, pad, margin);
        }
    }
}

/// Surface-mount pad: copper on its part's side only (vs. thru/NPTH, which
/// reach both faces).
fn isSmd(pad: geometry.Pad) bool {
    return !pad.thru and !pad.npth;
}

/// Paste stencil: SMD pads on this side only, at 1:1 (assemblers apply
/// their own shrink rules).
fn writePaste(g: *Gx, placement: optimizer.Placement, side: optimizer.Side) Error!void {
    for (placement.parts) |p| {
        if (p.side != side) continue;
        for (p.pads) |pad| {
            if (pad.thru or pad.npth) continue;
            try flashPad(g, p, pad, 0);
        }
    }
}

/// Silkscreen: each same-side part's footprint art (lines + circles) plus
/// its ref-des in 5x7 strokes above the courtyard, then any board-level user
/// text on this side. Bottom-side text mirrors so it reads correctly when the
/// board is flipped.
fn writeSilk(g: *Gx, placement: optimizer.Placement, side: optimizer.Side, texts: []const font.BoardText) Error!void {
    for (placement.parts) |p| {
        if (p.side != side) continue;
        try g.use(.c, silk_w_mm, 0);
        for (p.silk_lines) |l| {
            const a = optimizer.worldPadCenter(p, l.x1, l.y1);
            const b = optimizer.worldPadCenter(p, l.x2, l.y2);
            try g.line(a[0], a[1], b[0], b[1]);
        }
        for (p.silk_circles) |ci| {
            const c = optimizer.worldPadCenter(p, ci.cx, ci.cy);
            try strokeCircle(g, c[0], c[1], ci.r);
        }
        try drawRefDes(g, p);
    }
    // Board-level user silkscreen text (Text tool / sidecar `texts[]`).
    const bottom = side == .bottom;
    for (texts) |t| {
        if (t.bottom != bottom) continue;
        try drawBoardText(g, t);
    }
}

/// Board profile as a thin closed contour: the exact outline polygon when
/// the board is non-rectangular (viewer-drawn polygon / `(corner-radius R)`
/// rounded rect, straight segments), else the outline rectangle.
fn writeEdge(g: *Gx, placement: optimizer.Placement) Error!void {
    try g.use(.c, edge_w_mm, 0);
    if (placement.board_poly) |poly| {
        if (poly.len >= 3) {
            var prev = poly[poly.len - 1];
            for (poly) |v| {
                try g.line(prev[0], prev[1], v[0], v[1]);
                prev = v;
            }
            return;
        }
    }
    const r = export_fab.outlineRect(placement);
    try g.line(r.minx, r.miny, r.minx + r.w, r.miny);
    try g.line(r.minx + r.w, r.miny, r.minx + r.w, r.miny + r.h);
    try g.line(r.minx + r.w, r.miny + r.h, r.minx, r.miny + r.h);
    try g.line(r.minx, r.miny + r.h, r.minx, r.miny);
}

// ── Pads ────────────────────────────────────────────────────────────────────

/// Flash one pad at its world pose. Shapes map to their faithful fab feature:
/// a circle is a C aperture; an axis-aligned plain rect / oval is an R / O
/// aperture (w/h swapped on a quarter turn — the fast, byte-identical path); a
/// roundrect, or ANY pad at a non-quarter angle, is emitted as its true outline
/// via a G36 region (rounded corners / arbitrary rotation an aperture can't
/// represent); a custom (thermal/EP) outline flashes its real copper polygon.
/// `expand` grows every feature per side (mask/paste openings) — including the
/// custom polygon, offset outward by `expand` so its opening keeps the margin.
fn flashPad(g: *Gx, p: optimizer.Part, pad: geometry.Pad, expand: f64) Error!void {
    // 1. Custom polygon pad: its real outline, offset outward for a margin.
    if (pad.poly.len >= 3) {
        const shape = try pad_shape.worldShape(g.arena, p, pad);
        if (shape.poly.len >= 3) {
            const poly = if (expand > 0) try offsetPolygon(g.arena, shape.poly, expand) else shape.poly;
            return regionPoly(g, poly);
        }
    }
    const c = optimizer.worldPadCenter(p, pad.x, pad.y);
    // 2. Circle: rotation-invariant, always a C aperture.
    if (std.mem.eql(u8, pad.shape, "circle")) {
        const d = pad.w + 2 * expand;
        if (d <= 0) return;
        try g.use(.c, d, d);
        return g.flash(c[0], c[1]);
    }
    // 3. Rounded corners or an off-axis pose → the true outline as a region.
    const tot = p.rot + pad.rot;
    if (isRoundrect(pad) or !axisAligned(tot)) {
        const poly = try padRegion(g.arena, p, pad, expand);
        if (poly.len >= 3) return regionPoly(g, poly);
    }
    // 4. Axis-aligned rect / oval aperture (the fast, byte-identical path).
    const q = quarterRot(tot);
    const w = (if (q) pad.h else pad.w) + 2 * expand;
    const h = (if (q) pad.w else pad.h) + 2 * expand;
    if (w <= 0 or h <= 0) return;
    const kind: ApKind = if (std.mem.eql(u8, pad.shape, "oval")) .o else .r;
    try g.use(kind, w, h);
    try g.flash(c[0], c[1]);
}

/// A pad shape word test.
fn isRoundrect(pad: geometry.Pad) bool {
    return std.mem.eql(u8, pad.shape, "roundrect");
}
fn isOval(pad: geometry.Pad) bool {
    return std.mem.eql(u8, pad.shape, "oval");
}

/// The roundrect corner ratio to use: the pad's explicit value (capped at 0.5),
/// else the KiCad default so a bare `roundrect` still rounds.
fn roundrectRatio(pad: geometry.Pad) f64 {
    return if (pad.rratio > 0) @min(pad.rratio, 0.5) else geometry.default_rratio;
}

/// True when `rot` (deg) is a multiple of 90° — an axis-aligned pose an R/O
/// aperture can represent.
fn axisAligned(rot: f64) bool {
    return @abs(rot - @round(rot / 90) * 90) < 1e-6;
}

/// Corner-arc segments per rounded corner when a pad is polygonized.
const pad_arc_seg: usize = 6;

/// The world-space region outline of a rect / roundrect / oval pad at `p`'s
/// pose, grown `expand` per side (0 = copper 1:1). Rect ⇒ 4 corners; roundrect
/// ⇒ its corner arcs (default ratio when unset); oval ⇒ a stadium (corner
/// radius = half the minor axis). The pad's own `(pos … ROT)` rotates the local
/// outline before the part pose is applied, so any angle comes out exact.
fn padRegion(arena: std.mem.Allocator, p: optimizer.Part, pad: geometry.Pad, expand: f64) Error![]const [2]f64 {
    const hw = pad.w / 2 + expand;
    const hh = pad.h / 2 + expand;
    if (hw <= 0 or hh <= 0) return &.{};
    var r: f64 = 0;
    if (isRoundrect(pad)) {
        r = roundrectRatio(pad) * @min(pad.w, pad.h) + expand;
    } else if (isOval(pad)) {
        r = @min(pad.w, pad.h) / 2 + expand;
    }
    r = std.math.clamp(r, 0, @min(hw, hh));

    // Local offsets from the pad centre (before the pad's own rotation).
    var locals: std.ArrayList([2]f64) = .empty;
    if (r <= 1e-9) {
        try locals.append(arena, .{ hw, -hh });
        try locals.append(arena, .{ hw, hh });
        try locals.append(arena, .{ -hw, hh });
        try locals.append(arena, .{ -hw, -hh });
    } else {
        const HALF_PI = std.math.pi / 2.0;
        // Four corner arcs, ordered so the connecting straight edges are drawn
        // between successive arcs (top-right → bottom-right → bottom-left → top-left).
        const arcs = [4][3]f64{
            .{ hw - r, -(hh - r), -HALF_PI },
            .{ hw - r, hh - r, 0 },
            .{ -(hw - r), hh - r, HALF_PI },
            .{ -(hw - r), -(hh - r), std.math.pi },
        };
        for (arcs) |arc| {
            var i: usize = 0;
            while (i <= pad_arc_seg) : (i += 1) {
                const t = arc[2] + HALF_PI * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(pad_arc_seg));
                try locals.append(arena, .{ arc[0] + r * @cos(t), arc[1] + r * @sin(t) });
            }
        }
    }

    // Rotate each local offset by the pad's own angle, then apply the part pose.
    const a = pad.rot * std.math.pi / 180.0;
    const ca = @cos(a);
    const sa = @sin(a);
    const out = try arena.alloc([2]f64, locals.items.len);
    for (locals.items, 0..) |d, i| {
        const rx = d[0] * ca - d[1] * sa;
        const ry = d[0] * sa + d[1] * ca;
        out[i] = optimizer.worldPadCenter(p, pad.x + rx, pad.y + ry);
    }
    return out;
}

/// Offset the closed polygon `pts` outward by `d` mm (edge normals + mitered
/// joins) — the mask/paste margin for a custom pad. Winding comes from the
/// signed area so normals point outward regardless of orientation; a degenerate
/// (near-parallel) join falls back to one edge normal, and the miter length is
/// capped so a sharp corner can't spike.
fn offsetPolygon(arena: std.mem.Allocator, pts: []const [2]f64, d: f64) Error![]const [2]f64 {
    const n = pts.len;
    if (n < 3 or d == 0) return pts;
    var area2: f64 = 0;
    var j: usize = n - 1;
    for (pts, 0..) |v, i| {
        area2 += pts[j][0] * v[1] - v[0] * pts[j][1];
        j = i;
    }
    const ccw = area2 > 0;
    const out = try arena.alloc([2]f64, n);
    for (pts, 0..) |v, i| {
        const prev = pts[(i + n - 1) % n];
        const next = pts[(i + 1) % n];
        const n1 = edgeNormal(prev, v, ccw);
        const n2 = edgeNormal(v, next, ccw);
        var mx = n1[0] + n2[0];
        var my = n1[1] + n2[1];
        const ml = std.math.hypot(mx, my);
        if (ml < 1e-9) {
            out[i] = .{ v[0] + n1[0] * d, v[1] + n1[1] * d };
            continue;
        }
        mx /= ml;
        my /= ml;
        var cos_half = mx * n1[0] + my * n1[1];
        if (cos_half < 0.2) cos_half = 0.2; // cap the miter on a sharp corner
        const len = d / cos_half;
        out[i] = .{ v[0] + mx * len, v[1] + my * len };
    }
    return out;
}

/// Unit outward normal of edge a→b: the right-hand normal `(dy,-dx)/l` is
/// outward when the polygon's signed area is positive (`ccw`), else flipped.
fn edgeNormal(a: [2]f64, b: [2]f64, ccw: bool) [2]f64 {
    const ex = b[0] - a[0];
    const ey = b[1] - a[1];
    const l = std.math.hypot(ex, ey);
    if (l < 1e-12) return .{ 0, 0 };
    const nx = ey / l;
    const ny = -ex / l;
    return if (ccw) .{ nx, ny } else .{ -nx, -ny };
}

/// Flash a pad's bounding box grown by `grow` per side — the clear-polarity
/// halo an outer pour keeps around foreign pads (a box over-clears a custom
/// outline, which is the safe direction for isolation).
fn flashPadBox(g: *Gx, p: optimizer.Part, pad: geometry.Pad, grow: f64) Error!void {
    const shape = try pad_shape.worldShape(g.arena, p, pad);
    const w = (shape.x1 - shape.x0) + 2 * grow;
    const h = (shape.y1 - shape.y0) + 2 * grow;
    if (w <= 2 * grow or h <= 2 * grow) return;
    try g.use(.r, w, h);
    try g.flash((shape.x0 + shape.x1) / 2, (shape.y0 + shape.y1) / 2);
}

// ── Pours + net lookups ─────────────────────────────────────────────────────

/// The solid pour region: the board outline pulled back by the copper-to-edge
/// clearance (a `(design-rules (copper-edge …))` value, else the fab-safe pour
/// default) on every edge (skipped when degenerate).
fn pourRect(g: *Gx, placement: optimizer.Placement) Error!void {
    const r = export_fab.outlineRect(placement);
    const p = placement.rules.design.pourEdge();
    if (r.w <= 2 * p or r.h <= 2 * p) return;
    const pts = [_][2]f64{
        .{ r.minx + p, r.miny + p },
        .{ r.minx + r.w - p, r.miny + p },
        .{ r.minx + r.w - p, r.miny + r.h - p },
        .{ r.minx + p, r.miny + r.h - p },
    };
    try regionPoly(g, &pts);
}

/// (ref-des NUL pad-number) → flattened-net index, built from the netlist so
/// plane/pour layers can classify each pad's net. Arena-owned.
fn padNets(arena: std.mem.Allocator, placement: optimizer.Placement) !std.StringHashMapUnmanaged(usize) {
    var map = std.StringHashMapUnmanaged(usize).empty;
    for (placement.nets, 0..) |net, i| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ pin.ref_des, pin.pin });
            try map.put(arena, key, i);
        }
    }
    return map;
}

/// The net name a pad is on, or "" when unconnected.
fn netOfPad(n: std.StringHashMapUnmanaged(usize), p: optimizer.Placement, ref: []const u8, pad: []const u8) []const u8 {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}\x00{s}", .{ ref, pad }) catch return "";
    const i = n.get(key) orelse return "";
    return p.nets[i].name;
}

/// Flattened-net index → name ("" for the router's -1 / out-of-range).
fn netName(placement: optimizer.Placement, net: i32) []const u8 {
    if (net < 0) return "";
    const i: usize = @intCast(net);
    if (i >= placement.nets.len) return "";
    return placement.nets[i].name;
}

/// Does this plane carry `name`? Named planes match the full flattened name
/// or its leaf (the router's `netHasPlane` rule); the implicit model carries
/// every ground-named net. Unconnected ("") is never carried.
fn planeCarries(net: PlaneNet, name: []const u8) bool {
    if (name.len == 0) return false;
    return switch (net) {
        .ground => optimizer.isGroundName(leafName(name)),
        .named => |n| std.ascii.eqlIgnoreCase(n, name) or std.ascii.eqlIgnoreCase(n, leafName(name)),
    };
}

/// The net name's leaf after the last `/` (sub-block flatten prefix).
fn leafName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

/// The declared `(plane IDX "NET")` net at stack index `idx`, if any.
fn declaredPlaneAt(rules: optimizer.BoardRules, idx: u8) ?[]const u8 {
    for (rules.planes) |pl| {
        if (pl.index == idx) return pl.net;
    }
    return null;
}

/// The bottom copper's 1-based stack index (4 for the implicit model).
fn bottomIndex(rules: optimizer.BoardRules) u8 {
    if (rules.plane_nets == null) return 4;
    return @max(2, rules.copper_layers);
}

/// True for 90°/270° poses (pad w/h swap) — same rule as `pad_shape`.
fn quarterRot(rot: f64) bool {
    const q = @mod(@round(rot), 360);
    return q == 90 or q == 270;
}

// ── Silkscreen text ─────────────────────────────────────────────────────────

/// Stroke the ref-des in 5x7 pixels centred above the part's courtyard.
/// Bottom-side parts mirror horizontally (readable from the bottom view).
fn drawRefDes(g: *Gx, p: optimizer.Part) Error!void {
    if (p.ref_des.len == 0) return;
    const q = quarterRot(p.rot);
    const hh = if (q) p.hw else p.hh;
    const cc = optimizer.worldPadCenter(p, p.ccx, p.ccy);
    const ty = cc[1] - hh - (font.gh * text_px_mm) / 2 - 0.2;
    // Ref-des uppercases (its font predates lowercase) at the fixed 0.15 mm
    // pitch — kept byte-identical (see TextGeom defaults).
    try drawText(g, cc[0], ty, p.ref_des, .{ .mirror = p.side == .bottom, .upper = true });
}

/// How a silkscreen string is laid out: the per-pixel pitch (mm), whether x
/// mirrors about the anchor (bottom side), quarter-turn rotation, and whether
/// the source is uppercased first (ref-des only, for byte-identical legacy).
const TextGeom = struct {
    pitch: f64 = text_px_mm,
    mirror: bool = false,
    rot: f64 = 0,
    upper: bool = false,
};

/// Stroke a board-level user text at its world anchor, scaled to its cap
/// height and rotated to its quarter turn. Bottom-side mirrors like ref-des.
fn drawBoardText(g: *Gx, t: font.BoardText) Error!void {
    // Cap height → pixel pitch (glyph is GH pixels tall). Guard non-positive.
    const pitch = if (t.size > 0) t.size / @as(f64, @floatFromInt(font.gh)) else text_px_mm;
    try drawText(g, t.x, t.y, t.text, .{ .pitch = pitch, .mirror = t.bottom, .rot = t.rot });
}

/// Stroke `s` centred at (cx,cy) in placement coordinates: each glyph row's
/// runs of lit pixels become one horizontal segment (single pixels flash a
/// dot) — walked once per glyph via `font.glyphRuns` in the same row-then-
/// column order the old inline loop used, so ref-des output is byte-identical.
/// `geom.mirror` flips x about the centre (bottom-side readability);
/// `geom.rot` rotates the whole string about the anchor.
fn drawText(g: *Gx, cx: f64, cy: f64, s: []const u8, geom: TextGeom) Error!void {
    const P = geom.pitch;
    const adv = @as(f64, @floatFromInt(font.gw + 1)) * P;
    const total = @as(f64, @floatFromInt(s.len)) * adv - P;
    // Rotation of the local (lx,ly) frame about the anchor (0 = the fast path
    // where ca/sa are exactly 1/0, so unrotated text is byte-identical).
    const a = @mod(geom.rot, 360.0) * std.math.pi / 180.0;
    const ca = @cos(a);
    const sa = @sin(a);
    const Emit = struct {
        g: *Gx,
        cx: f64,
        cy: f64,
        gx0: f64,
        p: f64,
        mirror: bool,
        rotated: bool,
        ca: f64,
        sa: f64,
        // (lx,ly) local px → world mm: mirror x, then rotate about the anchor.
        fn place(self: @This(), lxpx: f64, ly: f64) [2]f64 {
            const lx = if (self.mirror) -lxpx else lxpx;
            if (!self.rotated) return .{ self.cx + lx, self.cy + ly };
            return .{ self.cx + lx * self.ca - ly * self.sa, self.cy + lx * self.sa + ly * self.ca };
        }
        fn emit(self: @This(), run: font.Run) Error!void {
            const ly = (@as(f64, @floatFromInt(run.r)) - 3.0) * self.p;
            const lx1 = self.gx0 + (@as(f64, @floatFromInt(run.c0)) + 0.5) * self.p;
            const lx2 = self.gx0 + (@as(f64, @floatFromInt(run.c1)) + 0.5) * self.p;
            const w1 = self.place(lx1, ly);
            if (run.c0 == run.c1) return self.g.flash(w1[0], w1[1]);
            const w2 = self.place(lx2, ly);
            try self.g.line(w1[0], w1[1], w2[0], w2[1]);
        }
    };
    const rotated = geom.rot != 0;
    try g.use(.c, silk_w_mm, 0);
    for (s, 0..) |ch0, k| {
        const ch = if (geom.upper) std.ascii.toUpper(ch0) else ch0;
        const gx0 = -total / 2 + @as(f64, @floatFromInt(k)) * adv;
        const em = Emit{ .g = g, .cx = cx, .cy = cy, .gx0 = gx0, .p = P, .mirror = geom.mirror, .rotated = rotated, .ca = ca, .sa = sa };
        try font.glyphRuns(ch, Error, em, Emit.emit);
    }
}

/// Stroke a circle as a 24-gon polyline (silk pin-1 markers etc.).
fn strokeCircle(g: *Gx, cx: f64, cy: f64, r: f64) Error!void {
    const N = 24;
    var px = cx + r;
    var py = cy;
    var i: usize = 1;
    while (i <= N) : (i += 1) {
        const a = 2 * std.math.pi * @as(f64, @floatFromInt(i)) / N;
        const nx = cx + r * @cos(a);
        const ny = cy + r * @sin(a);
        try g.line(px, py, nx, ny);
        px = nx;
        py = ny;
    }
}

// ── Gerber emission plumbing ────────────────────────────────────────────────

const ApKind = enum { c, r, o };

/// One standard aperture, dimensions in integer micro-mm-ish units (mm·1e6)
/// so dedup is exact.
const Ap = struct { kind: ApKind, w: i64, h: i64 };

/// The file's aperture dictionary: dedups (kind, w, h) → D-code (D10+).
const Apertures = struct {
    list: std.ArrayList(Ap) = .empty,

    fn code(self: *Apertures, arena: std.mem.Allocator, kind: ApKind, w: f64, h: f64) std.mem.Allocator.Error!u32 {
        const key = Ap{ .kind = kind, .w = mmToUm(w), .h = mmToUm(h) };
        for (self.list.items, 0..) |a, i| {
            if (a.kind == key.kind and a.w == key.w and a.h == key.h) return @intCast(10 + i);
        }
        try self.list.append(arena, key);
        return @intCast(10 + self.list.items.len - 1);
    }
};

/// Geometry emitter: applies the package frame (y-flip) and 4.6-mm scaling,
/// tracks the current aperture/polarity so the body stays minimal.
const Gx = struct {
    w: *std.Io.Writer,
    aps: *Apertures,
    arena: std.mem.Allocator,
    frame: export_fab.Frame,
    cur: u32 = 0,
    dark: bool = true,

    /// Select (defining if needed) the aperture for what's drawn next.
    fn use(g: *Gx, kind: ApKind, w: f64, h: f64) Error!void {
        const c = try g.aps.code(g.arena, kind, w, if (kind == .c) w else h);
        if (c != g.cur) {
            try g.w.print("D{d}*\n", .{c});
            g.cur = c;
        }
    }

    fn polarity(g: *Gx, dark: bool) Error!void {
        if (dark == g.dark) return;
        try g.w.writeAll(if (dark) "%LPD*%\n" else "%LPC*%\n");
        g.dark = dark;
    }

    /// Placement-space mm → framed 4.6 integer coordinates.
    fn xy(g: *Gx, x: f64, y: f64) [2]i64 {
        const p = g.frame.pt(x, y);
        return .{ mmToUm(p[0]), mmToUm(p[1]) };
    }

    fn flash(g: *Gx, x: f64, y: f64) Error!void {
        const c = g.xy(x, y);
        try g.w.print("X{d}Y{d}D03*\n", .{ c[0], c[1] });
    }

    fn line(g: *Gx, x1: f64, y1: f64, x2: f64, y2: f64) Error!void {
        const a = g.xy(x1, y1);
        const b = g.xy(x2, y2);
        try g.w.print("X{d}Y{d}D02*\nX{d}Y{d}D01*\n", .{ a[0], a[1], b[0], b[1] });
    }
};

/// Fill a closed polygon (placement-space points) as a G36/G37 region.
fn regionPoly(g: *Gx, pts: []const [2]f64) Error!void {
    if (pts.len < 3) return;
    try g.w.writeAll("G36*\n");
    const first = g.xy(pts[0][0], pts[0][1]);
    try g.w.print("X{d}Y{d}D02*\n", .{ first[0], first[1] });
    for (pts[1..]) |v| {
        const c = g.xy(v[0], v[1]);
        try g.w.print("X{d}Y{d}D01*\n", .{ c[0], c[1] });
    }
    const last = g.xy(pts[pts.len - 1][0], pts[pts.len - 1][1]);
    if (last[0] != first[0] or last[1] != first[1])
        try g.w.print("X{d}Y{d}D01*\n", .{ first[0], first[1] });
    try g.w.writeAll("G37*\n");
}

/// mm → integer 4.6-format units (1e-6 mm).
fn mmToUm(mm: f64) i64 {
    return @intFromFloat(@round(mm * 1e6));
}

/// Integer 4.6 units → mm (aperture-definition printing).
fn umToMm(u: i64) f64 {
    return @as(f64, @floatFromInt(u)) / 1e6;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testPlacement(parts: []optimizer.Part, nets: []const export_kicad.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
    };
}

// spec: export_gerber - plans the file set from the stackup (implicit 4-layer, declared planes, plain 2-layer)
test "planLayers sizes the copper set from the stackup rules" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // No stackup form: implicit 4-layer — two inner ground planes.
    var p = testPlacement(&.{}, &.{});
    const implicit = try planLayers(arena, p);
    try testing.expectEqual(@as(usize, 11), implicit.len);
    try testing.expectEqualStrings("In1_Cu.g2", implicit[1].suffix);
    try testing.expect(implicit[1].layer.plane.net == .ground);
    try testing.expectEqualStrings("Copper,L4,Bot", implicit[3].function);

    // (stackup 2): plane-less two-layer — no inner files at all.
    p.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };
    const two = try planLayers(arena, p);
    try testing.expectEqual(@as(usize, 9), two.len);
    try testing.expectEqualStrings("B_Cu.gbl", two[1].suffix);
    try testing.expectEqualStrings("Copper,L2,Bot", two[1].function);

    // Declared 4-layer with one plane: the named plane plus one ROUTABLE
    // inner signal layer (stack L3 = signal index 2, the router's third layer).
    const gnd = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    p.rules = .{ .plane_nets = &gnd, .copper_layers = 4, .planes = &planes };
    const four = try planLayers(arena, p);
    try testing.expectEqual(@as(usize, 11), four.len);
    try testing.expectEqualStrings("GND", four[1].layer.plane.net.named);
    try testing.expect(four[2].layer == .inner_signal);
    try testing.expectEqual(@as(u8, 3), four[2].layer.inner_signal.index);
    try testing.expectEqual(@as(u8, 2), four[2].layer.inner_signal.sig);
    try testing.expectEqualStrings("In2_Cu.g3", four[2].suffix);
    try testing.expectEqualStrings("Copper,L3,Inr", four[2].function);
}

// spec: export_gerber - an inner signal layer emits its routed tracks, via lands, and through-pad barrels; other layers' tracks stay off it
test "inner signal layer carries layer-2 copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.5 }, // SMD — must NOT appear
        .{ .number = "2", .x = 2, .y = 0, .w = 1.4, .h = 1.4, .shape = "circle", .thru = true, .drill = 0.9 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    const tracks = [_]router.Track{
        .{ .x1 = 3, .y1 = 5, .x2 = 7, .y2 = 5, .layer = 2, .width = 0.2, .net = 0 }, // inner — drawn
        .{ .x1 = 1, .y1 = 1, .x2 = 2, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 }, // top — absent
    };
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};

    var aw: std.Io.Writer.Allocating = .init(arena);
    const inner: Layer = .{ .inner_signal = .{ .index = 3, .sig = 2 } };
    try writeLayer(&aw.writer, arena, placement, .{ .tracks = &tracks, .vias = &vias }, &.{}, export_fab.frameFor(placement), inner, "Copper,L3,Inr");
    const out = aw.written();

    // The layer-2 track draws ((3,5)→(7,5), y-up (3,5)→(7,5)); the top track doesn't.
    try testing.expect(std.mem.indexOf(u8, out, "X3000000Y5000000D02*\nX7000000Y5000000D01*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X1000000Y9000000D02*") == null);
    // Via land flashes; the through pad's barrel flashes (world (12,5)); the
    // SMD pad (world (9,5)) has no copper on an inner layer.
    try testing.expect(std.mem.indexOf(u8, out, "X5000000Y5000000D03*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "C,1.400000*%") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X12000000Y5000000D03*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X9000000Y5000000D03*") == null);
    try testing.expect(std.mem.indexOf(u8, out, "R,1.000000X0.500000") == null);
}

// spec: export_gerber - outer copper flashes side-correct pads and draws routed tracks/vias in the y-up frame
test "writeLayer emits top copper with pads, tracks, and via lands" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1, .y = 0, .w = 1.0, .h = 0.5 },
        .{ .number = "2", .x = 1, .y = 0, .w = 1.4, .h = 1.4, .shape = "circle", .thru = true, .drill = 0.9 },
    };
    const bot_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
        .{ .ref_des = "C9", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &bot_pads, .fallback = false, .x = 4, .y = 4, .side = .bottom },
    };
    const placement = testPlacement(&parts, &.{});
    const tracks = [_]router.Track{
        .{ .x1 = 9, .y1 = 5, .x2 = 12, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1, .y1 = 1, .x2 = 2, .y2 = 1, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};

    var aw: std.Io.Writer.Allocating = .init(arena);
    const top_copper = Copper{ .tracks = &tracks, .vias = &vias };
    try writeLayer(&aw.writer, arena, placement, top_copper, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, "Copper,L1,Top");
    const out = aw.written();

    try testing.expect(std.mem.indexOf(u8, out, "%FSLAX46Y46*%") != null);
    try testing.expect(std.mem.indexOf(u8, out, "%ADD10R,1.000000X0.500000*%") != null); // SMD rect pad
    try testing.expect(std.mem.indexOf(u8, out, "C,1.400000*%") != null); // thru circle pad
    // Rect pad at (9,5) y-down → (9, 10-5=5) y-up, 4.6 format.
    try testing.expect(std.mem.indexOf(u8, out, "X9000000Y5000000D03*") != null);
    // The top-layer track drawn, the bottom-layer one absent.
    try testing.expect(std.mem.indexOf(u8, out, "X9000000Y5000000D02*\nX12000000Y5000000D01*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X1000000Y9000000D02*") == null);
    // Via land flashes; the bottom SMD pad does not appear on top copper.
    try testing.expect(std.mem.indexOf(u8, out, "X5000000Y5000000D03*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X4000000Y6000000D03*") == null);

    // Bottom copper: the bottom pad appears (x mirrors about the part origin
    // is footprint-local; a centred pad stays at the part centre).
    var bw: std.Io.Writer.Allocating = .init(arena);
    const bot_copper = Copper{ .tracks = &tracks, .vias = &vias };
    try writeLayer(&bw.writer, arena, placement, bot_copper, &.{}, export_fab.frameFor(placement), .{ .copper = .bottom }, "Copper,L4,Bot");
    const bot = bw.written();
    try testing.expect(std.mem.indexOf(u8, bot, "X4000000Y6000000D03*") != null);
    try testing.expect(std.mem.indexOf(u8, bot, "X1000000Y9000000D02*\nX2000000Y9000000D01*") != null);
}

// spec: export_gerber - mask openings expand pads and tent vias; paste covers only same-side SMD pads
test "mask expands pads and skips vias; paste skips through-hole" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.5 },
        .{ .number = "2", .x = 2, .y = 0, .w = 1.4, .h = 1.4, .thru = true, .drill = 0.9 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};

    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, .{ .vias = &vias }, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, "Soldermask,Top");
    const mask = mw.written();
    try testing.expect(std.mem.indexOf(u8, mask, "%TF.FilePolarity,Negative*%") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "R,1.100000X0.600000*%") != null); // 0.05/side expansion
    try testing.expect(std.mem.indexOf(u8, mask, "X5000000Y5000000D03*") == null); // via tented

    var pw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&pw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .paste = .top }, "Paste,Top");
    const paste = pw.written();
    try testing.expect(std.mem.indexOf(u8, paste, "R,1.000000X0.500000*%") != null); // SMD at 1:1
    try testing.expect(std.mem.indexOf(u8, paste, "1.400000") == null); // thru pad has no paste
}

// spec: export_gerber - the mask margin comes from (design-rules …), defaulting byte-identically to 0.05 mm
test "mask margin reads from the design rules" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };

    // No form ⇒ default 0.05/side ⇒ the same 1.100000X0.600000 opening the
    // legacy constant produced (the byte-identical regression).
    const base = testPlacement(&parts, &.{});
    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, base, .{}, &.{}, export_fab.frameFor(base), .{ .mask = .top }, "Soldermask,Top");
    try testing.expect(std.mem.indexOf(u8, mw.written(), "R,1.100000X0.600000*%") != null);

    // A (design-rules (mask-margin 0.1)) widens the opening to 0.1/side ⇒
    // 1.200000X0.700000.
    var wide = testPlacement(&parts, &.{});
    wide.rules = .{ .design = .{ .mask_margin = 0.1 } };
    var ww: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&ww.writer, arena, wide, .{}, &.{}, export_fab.frameFor(wide), .{ .mask = .top }, "Soldermask,Top");
    try testing.expect(std.mem.indexOf(u8, ww.written(), "R,1.200000X0.700000*%") != null);
}

// spec: export_gerber - an inner plane pours solid copper and antipads only foreign holes
test "plane layer clears foreign holes and connects same-net barrels" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1, .y = 0, .w = 1.4, .h = 1.4, .thru = true, .drill = 0.8 },
        .{ .number = "2", .x = 1, .y = 0, .w = 1.4, .h = 1.4, .thru = true, .drill = 0.8 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const gnd_pins = [_]export_kicad.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const sig_pins = [_]export_kicad.FlatPin{.{ .ref_des = "J1", .pin = "2" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &sig_pins },
    };
    const placement = testPlacement(&parts, &nets);
    const vias = [_]router.Via{
        .{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }, // GND via — connects
        .{ .x = 6, .y = 5, .dia = 0.4, .drill = 0.2, .net = 1 }, // VIN via — antipad
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    const inner: Layer = .{ .plane = .{ .index = 2, .net = .ground } };
    try writeLayer(&aw.writer, arena, placement, .{ .vias = &vias }, &.{}, export_fab.frameFor(placement), inner, "Copper,L2,Inner");
    const out = aw.written();

    try testing.expect(std.mem.indexOf(u8, out, "G36*") != null); // the computed pour region
    try testing.expect(std.mem.indexOf(u8, out, "%LPC*%") != null); // clear pass
    // Foreign pad hole (J1.2 at world (11,5)→(11,5) y-up) antipadded 0.8+0.6.
    try testing.expect(std.mem.indexOf(u8, out, "C,1.400000*%") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X11000000Y5000000D03*") != null);
    // Same-net GND THT barrel at (9,5) is THERMALLY RELIEVED (not solid): a
    // clear isolation ring (pad 1.4 + 0.3 gap ⇒ C,2.0) flashes at its centre,
    // and 0.3 mm spokes bridge the gap.
    try testing.expect(std.mem.indexOf(u8, out, "C,2.000000*%") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X9000000Y5000000D03*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "C,0.300000*%") != null); // spoke aperture
    // Foreign via antipadded; same-net GND via connects solid (no flash).
    try testing.expect(std.mem.indexOf(u8, out, "X6000000Y5000000D03*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X5000000Y5000000D03*") == null);
}

// spec: export_gerber - an outer-layer pour paints the copper file solid and isolates only foreign same-face features
test "outer pour fills bottom copper and antipads foreign features" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    const sig_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        // Bottom-side GND cap: its pad must stay SOLID in the pour (no antipad).
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .x = 4, .y = 4, .side = .bottom },
        // Bottom-side signal part: its pad gets a clear-polarity isolation box.
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.7, .hh = 0.5, .pads = &sig_pad, .fallback = false, .x = 10, .y = 5, .side = .bottom },
    };
    const gnd_pins = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const sig_pins = [_]export_kicad.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &sig_pins },
    };
    var placement = testPlacement(&parts, &nets);
    // (stackup 2 (pour bottom "GND")) — index 2 IS the bottom outer face.
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    placement.rules = .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = &planes };

    var bw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&bw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .bottom }, "Copper,L2,Bot");
    const bot = bw.written();
    // The solid pour region + a clear-polarity pass, then back to dark.
    try testing.expect(std.mem.indexOf(u8, bot, "G36*") != null);
    try testing.expect(std.mem.indexOf(u8, bot, "%LPC*%") != null);
    try testing.expect(std.mem.indexOf(u8, bot, "%LPD*%") != null);
    // Foreign pad antipad: bbox 1.0x0.5 grown 0.3/side ⇒ 1.6x1.1 rect flash.
    try testing.expect(std.mem.indexOf(u8, bot, "R,1.600000X1.100000*%") != null);
    // The pad flashes themselves (dark) exist for both parts; the GND pad's
    // 0.6 aperture never appears grown (0.6+0.6=1.2 would be its antipad).
    try testing.expect(std.mem.indexOf(u8, bot, "R,0.600000X0.600000*%") != null);
    try testing.expect(std.mem.indexOf(u8, bot, "R,1.200000X1.200000*%") == null);

    // The un-poured top face keeps plain pads-only copper: no pour region.
    var tw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&tw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, "Copper,L1,Top");
    try testing.expect(std.mem.indexOf(u8, tw.written(), "G36*") == null);
}

// spec: export_gerber - the .gbrjob job file lists board size, layer count, and each file's function
test "writeJobFile summarizes the package as valid JSON" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = testPlacement(&.{}, &.{});
    const files = try planLayers(arena, placement);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeJobFile(&aw.writer, placement, files, "demo");
    const out = aw.written();

    // Parses as JSON and carries the spec fields.
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, out, .{});
    const root = parsed.value.object;
    const specs = root.get("GeneralSpecs").?.object;
    try testing.expectEqual(@as(i64, 4), specs.get("LayerNumber").?.integer); // implicit 4-layer
    try testing.expectApproxEqAbs(@as(f64, 20), specs.get("Size").?.object.get("X").?.float, 1e-6);
    // The top-copper file entry carries the KiCad-style path + FileFunction.
    try testing.expect(std.mem.indexOf(u8, out, "demo-F_Cu.gtl") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"Copper,L1,Top\"") != null);
    // The mask file is Negative polarity.
    try testing.expect(std.mem.indexOf(u8, out, "\"FilePolarity\": \"Negative\"") != null);
}

// spec: export_gerber - the edge layer closes the board outline; silk strokes footprint art and ref-des text
test "edge closes the outline and silk carries the ref-des" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const silk = [_]geometry.SilkLine{.{ .x1 = -1, .y1 = -1, .x2 = 1, .y2 = -1 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .silk_lines = &silk, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});

    var ew: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&ew.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .edge, "Profile,NP");
    const edge = ew.written();
    try testing.expect(std.mem.indexOf(u8, edge, "C,0.100000*%") != null);
    // All four outline corners appear ((0,0)→(20,10) in the y-up frame).
    try testing.expect(std.mem.indexOf(u8, edge, "X0Y10000000D02*") != null);
    try testing.expect(std.mem.indexOf(u8, edge, "X20000000Y0D01*") != null);

    var sw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&sw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .silk = .top }, "Legend,Top");
    const silk_out = sw.written();
    try testing.expect(std.mem.indexOf(u8, silk_out, "C,0.150000*%") != null);
    // The footprint silk line at world y=4 → y-up 6.
    try testing.expect(std.mem.indexOf(u8, silk_out, "X9000000Y6000000D02*\nX11000000Y6000000D01*") != null);
    // Ref-des strokes exist (the "U1" glyphs flash many single pixels).
    try testing.expect(std.mem.count(u8, silk_out, "D03*") >= 10);
}

// spec: export_gerber - a non-rectangular board emits its exact outline polygon on the edge layer
test "edge layer traces the outline polygon when the board is non-rectangular" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // L-shaped 10×10 board with the (6..10, 4..10) corner notched out (y-down
    // world). The fab frame origin is the polygon BBOX's bottom-left, so the
    // notch vertices land at positive y-up coordinates.
    const l_poly = [_][2]f64{
        .{ 0, 0 }, .{ 10, 0 }, .{ 10, 4 }, .{ 6, 4 }, .{ 6, 10 }, .{ 0, 10 },
    };
    var placement = testPlacement(&.{}, &.{});
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 };
    placement.board_poly = &l_poly;

    var ew: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&ew.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .edge, "Profile,NP");
    const edge = ew.written();
    // The notch corner (6,4) → y-up (6,6) is drawn to from (10,4) → (10,6).
    try testing.expect(std.mem.indexOf(u8, edge, "X10000000Y6000000D02*\nX6000000Y6000000D01*") != null);
    // The notch wall (6,4)→(6,10) → y-up (6,6)→(6,0).
    try testing.expect(std.mem.indexOf(u8, edge, "X6000000Y6000000D02*\nX6000000Y0D01*") != null);
    // The path closes: last vertex (0,10) → first (0,0), y-up (0,0)→(0,10).
    try testing.expect(std.mem.indexOf(u8, edge, "X0Y0D02*\nX0Y10000000D01*") != null);
    // The plain bbox rectangle's notched corner (10,10 y-down → 10,0 y-up)
    // never appears as a draw target.
    try testing.expect(std.mem.indexOf(u8, edge, "X10000000Y0D01*") == null);
}

// spec: export_gerber - board-level silkscreen text strokes onto the silk layer at its world anchor, and only on its own side
test "silk layer strokes board-level text at its anchor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Empty ref-des so the only silk strokes are the board text (no ref-des
    // glyphs to muddy the flash counts).
    var parts = [_]optimizer.Part{
        .{ .ref_des = "", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    // A top-side "T" at world (10,5). "T" = a 5-wide top bar (one line run) plus
    // a 1-wide stem down the middle (six single-pixel dot flashes).
    const texts = [_]font.BoardText{
        .{ .x = 10, .y = 5, .size = 1.05, .text = "T", .bottom = false },
        .{ .x = 3, .y = 3, .size = 1.05, .text = "B", .bottom = true }, // wrong side
    };

    var tw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&tw.writer, arena, placement, .{}, &texts, export_fab.frameFor(placement), .{ .silk = .top }, "Legend,Top");
    const out = tw.written();
    // "T"'s top-bar run is a horizontal segment; its stem is exactly 6 dot
    // flashes. The bottom "B" is filtered out of the top layer, so the counts
    // are the glyph's alone.
    try testing.expect(std.mem.count(u8, out, "D01*") >= 1); // the top-bar stroke
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, out, "D03*")); // "T" stem dots only

    // The same "B" on the BOTTOM silk layer does render (and mirrors); the top
    // "T" is filtered off the bottom layer, so "B"'s own strokes are all that show.
    var bw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&bw.writer, arena, placement, .{}, &texts, export_fab.frameFor(placement), .{ .silk = .bottom }, "Legend,Bot");
    const bout = bw.written();
    try testing.expect(std.mem.count(u8, bout, "D01*") >= 1);
    // "B" flashes/strokes exist; "T"'s 6 stem dots are absent (wrong side).
    try testing.expect(std.mem.count(u8, bout, "D03*") + std.mem.count(u8, bout, "D01*") >= 3);
}

// spec: export_gerber - silkscreen text scales with its cap-height size (2x size gives 2x glyph extent)
test "board text extent scales with cap height" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Empty ref-des so the measured strokes are the board text alone (a fixed
    // ref-des would add size-independent x-extent and break the ratio).
    var parts = [_]optimizer.Part{
        .{ .ref_des = "", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});

    // Measure the x-span of the flashed "H" strokes at 1× vs 2× cap height. A
    // taller cap is a proportionally wider glyph, so the span doubles.
    const span = struct {
        fn measure(a2: std.mem.Allocator, pl: optimizer.Placement, size: f64) !f64 {
            const ts = [_]font.BoardText{.{ .x = 10, .y = 5, .size = size, .text = "H" }};
            var wbuf: std.Io.Writer.Allocating = .init(a2);
            try writeLayer(&wbuf.writer, a2, pl, .{}, &ts, export_fab.frameFor(pl), .{ .silk = .top }, "Legend,Top");
            const s = wbuf.written();
            var minx: f64 = 1e18;
            var maxx: f64 = -1e18;
            var it = std.mem.tokenizeScalar(u8, s, '\n');
            while (it.next()) |line| {
                if (line.len == 0 or line[0] != 'X') continue;
                const yi = std.mem.indexOfScalar(u8, line, 'Y') orelse continue;
                const xv = std.fmt.parseInt(i64, line[1..yi], 10) catch continue;
                const xf: f64 = @floatFromInt(xv);
                minx = @min(minx, xf);
                maxx = @max(maxx, xf);
            }
            return maxx - minx;
        }
    }.measure;

    const s1 = try span(arena, placement, 1.0);
    const s2 = try span(arena, placement, 2.0);
    try testing.expect(s1 > 0);
    // 2× cap height → 2× x-extent (within a small tolerance for the half-pixel
    // stroke offsets being scaled too).
    const ratio = s2 / s1;
    try testing.expect(ratio > 1.9 and ratio < 2.1);
}

/// Min/max integer X coordinate over a Gerber file's coordinate lines (4.6
/// units) — used to measure a region's width for the mask-offset test.
fn xExtent(s: []const u8) [2]i64 {
    var minx: i64 = std.math.maxInt(i64);
    var maxx: i64 = std.math.minInt(i64);
    var it = std.mem.tokenizeScalar(u8, s, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or line[0] != 'X') continue;
        const yi = std.mem.indexOfScalar(u8, line, 'Y') orelse continue;
        const xv = std.fmt.parseInt(i64, line[1..yi], 10) catch continue;
        minx = @min(minx, xv);
        maxx = @max(maxx, xv);
    }
    return .{ minx, maxx };
}

// spec: export_gerber - a roundrect pad emits its rounded outline as a G36 region while a plain rect stays an R aperture
test "roundrect pads emit as rounded regions, plain rects as apertures" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -2, .y = 0, .w = 1.0, .h = 0.6, .shape = "roundrect", .rratio = 0.25 },
        .{ .number = "2", .x = 2, .y = 0, .w = 1.0, .h = 0.6, .shape = "rect" },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 3, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&aw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, "Copper,L1,Top");
    const out = aw.written();
    // Exactly one region (the roundrect); the plain rect stays a 1.0×0.6 R aperture.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "G36*"));
    try testing.expect(std.mem.indexOf(u8, out, "R,1.000000X0.600000*%") != null);
}

// spec: export_gerber - a custom polygon pad's mask opening is offset outward from its copper by the mask margin
test "custom pad mask opening exceeds its copper outline" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A 2×2 custom pad given as a (poly …): copper flashes 1:1; the mask
    // opening grows by the 0.05 mm/side default margin.
    const poly = [_][2]f64{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 2, .h = 2, .shape = "custom", .poly = &poly },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});

    var cw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&cw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, "Copper,L1,Top");
    const cs = xExtent(cw.written());

    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, "Soldermask,Top");
    const ms = xExtent(mw.written());

    // The mask region is wider than the copper region by ~2× the 0.05 mm margin
    // (0.1 mm = 100000 in 4.6 units), never equal to it (the old bug).
    const grow = (ms[1] - ms[0]) - (cs[1] - cs[0]);
    try testing.expect(grow > 80000 and grow < 120000);
}

// spec: export_gerber - a pad at a non-quarter angle emits a rotated region instead of an axis-aligned aperture
test "a 45-degree pad emits a rotated region, not an R aperture" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.4, .shape = "rect", .rot = 45 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&aw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, "Copper,L1,Top");
    const out = aw.written();
    // A rotated rect can't be an axis-aligned aperture — it's a G36 region and
    // no R aperture is defined.
    try testing.expect(std.mem.indexOf(u8, out, "G36*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "R,") == null);
}

// spec: export_gerber - the .gbrjob board thickness comes from the stackup (thickness …), defaulting to 1.6 mm
test "writeJobFile reports the stackup board thickness" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // No thickness → the byte-identical fab-standard 1.6 mm default.
    var placement = testPlacement(&.{}, &.{});
    var files = try planLayers(arena, placement);
    var dw: std.Io.Writer.Allocating = .init(arena);
    try writeJobFile(&dw.writer, placement, files, "demo");
    try testing.expect(std.mem.indexOf(u8, dw.written(), "\"BoardThickness\": 1.6") != null);

    // A declared (stackup 2 (thickness 0.8)) flows to the job file.
    placement.rules = .{ .plane_nets = &.{}, .copper_layers = 2, .board_thickness = 0.8 };
    files = try planLayers(arena, placement);
    var tw: std.Io.Writer.Allocating = .init(arena);
    try writeJobFile(&tw.writer, placement, files, "demo");
    try testing.expect(std.mem.indexOf(u8, tw.written(), "\"BoardThickness\": 0.8") != null);
}

test "padRegion sweeps a roundrect top-right corner arc outward" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const pad = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 10, .h = 10, .shape = "roundrect", .rratio = 0.25 };
    const part = optimizer.Part{ .ref_des = "U1", .kind = .passive, .hw = 5, .hh = 5, .pads = &.{}, .fallback = false };
    const pts = try padRegion(arena_state.allocator(), part, pad, 0);
    // r = 0.25·10 = 2.5, so the inner-rect corner sits at (2.5, 2.5). The
    // top-right corner arc must bulge OUTWARD past it — some vertex with both
    // x>2.5 and y>2.5. A sign flip on the arc angle sweeps it the other way
    // (y<2.5), leaving no such vertex.
    try testing.expect(anyBeyond(pts, 2.5, 2.5));
}

/// True when some point of `pts` lies strictly past (mx, my) on both axes.
fn anyBeyond(pts: []const [2]f64, mx: f64, my: f64) bool {
    for (pts) |q| {
        if (q[0] > mx + 1e-6 and q[1] > my + 1e-6) return true;
    }
    return false;
}
