//! Gerber (RS-274X / X2) writer — the copper half of the netlisp-native
//! manufacturing package (`export_fab.zig` holds the drill + centroid half).
//! One call per output file: outer signal copper (pads + the saved layout's
//! routed tracks/vias), inner planes (solid pour with clearance antipads
//! around foreign holes), solder mask, paste, authored footprint art and
//! scalable vector silkscreen text, and the board-profile Edge.Cuts.
//!
//! What the files say is exactly what the placement/routing model believes:
//! pads flash as their model shapes (rect/roundrect → R, circle → C, oval →
//! O, custom outlines as exact authored G36 regions while DRC may simplify its
//! private collision copy), tracks are the persisted routed copper, and plane layers
//! follow the design's `(stackup …)` form — no form means the router's
//! legacy implicit 4-layer model, emitted through `implicit_plane` as an inner
//! ground plane plus, when the block has one, an inner supply-rail plane.
//!
//! Everything is emitted through the shared `export_fab.Frame` (y-up, origin
//! at the board outline's bottom-left), so gerbers, Excellon drills, and the
//! centroid CSV stack exactly in CAM.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const outline = @import("placement/outline.zig");
const router = @import("placement/router.zig");
const rf_port_report = @import("placement/rf_port_report.zig");
const path_copper = @import("placement/path_copper.zig");
const geometry = @import("placement/geometry.zig");
const pad_shape = @import("placement/pad_shape.zig");
const pour = @import("placement/pour.zig");
const routed_copper = @import("placement/routed_copper.zig");
const implicit_plane = @import("placement/implicit_plane.zig");
const perimeter_fence = @import("placement/perimeter_fence.zig");
const mask_relief = @import("placement/mask_relief.zig");
const land_transit = @import("placement/land_transit.zig");
const export_kicad = @import("export_kicad.zig");
const export_fab = @import("export_fab.zig");
const font = @import("font5x7.zig");
const silk_font = @import("silk_font.zig");
const subcircuit_silkscreen = @import("subcircuit_silkscreen.zig");
const testpoint_silkscreen = @import("testpoint_silkscreen.zig");
const numeric = @import("numeric.zig");
const board_layers = @import("board_layers.zig");
const env = @import("eval/env.zig");
// Solder-mask margin and copper-pour isolation are no longer hard-coded here —
// they live in `optimizer.DesignRules` (`mask_margin` / `pour_clearance` /
// `copper_edge`), resolved from the design's `(design-rules …)` form with the
// old constants (0.05 / 0.3) as defaults, and read via `placement.rules.design`.

/// Silkscreen stroke width (mm), independent of vector text cap height.
const silk_w_mm = silk_font.stroke_width_mm;
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

/// Index + face of a separately-authored fabrication backing. The full spec
/// stays on Placement; keeping only its stable index here makes Layer small.
pub const FabricationLayer = struct { index: usize, side: optimizer.Side };

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
    fabrication: FabricationLayer,
    edge,
};

/// One planned output file: which layer, the file-name suffix appended to
/// the design name (KiCad naming + Protel extensions, so every CAM package
/// auto-detects it), and the X2 `.FileFunction` attribute value.
pub const LayerFile = struct {
    layer: Layer,
    suffix: []const u8,
    function: []const u8,
    /// Vendor-named auxiliary files stay exactly `suffix` in the archive;
    /// ordinary board files keep the shared `<project>-<suffix>` rule.
    exact_name: bool = false,
};

/// The fab package's NON-layer member names. The per-layer suffixes are planned
/// into `LayerFile.suffix` off the `board_layers` table; these are the files the
/// archive carries beside them, so the whole package's naming resolves here
/// rather than at whichever handler happens to assemble the ZIP. A CAM tool
/// auto-detects a member by its extension, so a name invented at the call site
/// is how a package ships a file the fab then mis-reads or ignores.
pub const job_file_ext = ".gbrjob";
/// The Gerber Job File, whose `Path` fields must match the entry names above.
pub const job_file_suffix = "job" ++ job_file_ext;
/// Excellon drills, split by `export_fab.DrillClass`: plated through-holes…
pub const plated_drill_suffix = "PTH.drl";
/// …and the non-plated mounting holes, which the fab drills without copper.
pub const non_plated_drill_suffix = "NPTH.drl";

/// Contract-owned archive paths for the MATLAB R2022b four-layer simulation
/// handoff. They live beside the ordinary fab suffixes so CAM extensions have
/// one owner even though this package uses MATLAB's required layer basenames.
pub const matlab_rf_paths = struct {
    pub const l1 = "geometry/L1_top.gtl";
    pub const l2 = "geometry/L2_inner.gbr";
    pub const l3 = "geometry/L3_inner.gbr";
    pub const l4 = "geometry/L4_bottom.gbl";
    pub const plated = "geometry/plated_through.drl";
    pub const top_mask = "geometry/top_solder_mask.gts";
};

/// The routed copper a layout persisted. DECLARED in
/// `placement/routed_copper.zig`, a module beneath both this Gerber writer and
/// the `src/placement/*` layer that fills it in, and re-exported here so
/// callers in the export and serve layers keep their historical spelling.
pub const Copper = routed_copper.Copper;

pub const Error = std.Io.Writer.Error || std.mem.Allocator.Error;

/// Rebuild the router-shaped view `path_copper` consumes from the persisted
/// export bundle. The returned slices still belong to `copper`; only the
/// physical lowering below may allocate into the caller's arena.
fn routedCopper(copper: Copper) router.RouteResult {
    return .{
        .tracks = copper.tracks,
        .vias = copper.vias,
        .arcs = copper.arcs,
        .rf_port_outcomes = copper.rf_paths,
        .routed = 0,
        .total = 0,
    };
}

fn physicalTracks(arena: std.mem.Allocator, copper: Copper) std.mem.Allocator.Error![]const router.Track {
    return path_copper.tracks(arena, routedCopper(copper));
}

fn physicalArcs(arena: std.mem.Allocator, copper: Copper) std.mem.Allocator.Error![]const router.Arc {
    return path_copper.filterArcs(arena, copper.rf_paths, copper.arcs);
}

/// Normalize persisted/editor copper into the conservative physical view used
/// by geometry consumers outside the placement layer. The returned bundle is
/// idempotent: its RF paths are cleared after their sampled chords and collars
/// replace compact handles, and RF-owned native arcs are omitted.
pub fn physicalCopper(arena: std.mem.Allocator, copper: Copper) std.mem.Allocator.Error!Copper {
    if (copper.rf_paths.len == 0) return copper;
    var physical = copper;
    physical.tracks = try physicalTracks(arena, copper);
    physical.arcs = try physicalArcs(arena, copper);
    physical.rf_paths = &.{};
    return physical;
}

/// Plan the full Gerber file set for `placement` from its `(stackup …)`
/// rules: no stackup form = the router's legacy implicit 4-layer model (whose
/// two inner planes `implicit_plane` names — ground, then the dominant supply
/// rail or ground again), a declared stackup gets its declared planes (inner
/// signal layers it never names come out blank), and mask/paste/silk/edge
/// always ship. Slices are arena-allocated.
///
/// EVERY file — copper and technical alike — comes from the shared layer
/// table: which files exist, their emission order, their names and their X2
/// attributes. It is the same table the router, the pour fill and the
/// connectivity oracle read, so a Gerber package can never pour a different
/// net than the board was routed against, and the mask/paste/silk/profile
/// spellings can never drift from the ones the rest of the toolchain uses.
/// The implicit model's two inner planes arrive here as ordinary plane rows
/// (`implicit_plane` still owns which nets they carry).
pub fn planLayers(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error![]const LayerFile {
    var out: std.ArrayList(LayerFile) = .empty;
    const table = placement.rules.layerTable();
    const n = table.stackCount();
    for (table.fabRows()) |*row| {
        const layer = layerOf(row, n) orelse continue;
        try out.append(arena, .{
            .layer = layer,
            .suffix = try arena.dupe(u8, row.gerberSuffix()),
            .function = try arena.dupe(u8, row.gerberFunction()),
        });
    }
    for (placement.fabrication_layers, 0..) |spec, i| {
        try out.append(arena, .{
            .layer = .{ .fabrication = .{ .index = i, .side = if (spec.side == .bottom) .bottom else .top } },
            .suffix = try arena.dupe(u8, spec.name),
            .function = "Other,Drawing",
            .exact_name = true,
        });
    }
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
    // `LayerNumber` counts the COPPER FILES THIS PACKAGE ACTUALLY SHIPS, not a
    // second reading of the stackup rules: the two used to be independent
    // computations that a table change could silently desynchronize, and a job
    // file claiming a layer count the archive does not contain mis-stacks the
    // board in CAM.
    const layer_count = copperFileCount(files);
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
    if (rules.physical.board_thickness > 0) {
        try w.print("    \"BoardThickness\": {d}\n", .{rules.physical.board_thickness});
    } else {
        try w.writeAll("    \"BoardThickness\": 1.6\n");
    }
    try w.writeAll("  },\n  \"FilesAttributes\": [\n");
    for (files, 0..) |f, i| {
        if (i > 0) try w.writeAll(",\n");
        const polarity = polarityOf(f.layer);
        try w.writeAll("    { \"Path\": ");
        // Path = "<name>-<suffix>", the ZIP entry name.
        var buf: [256]u8 = undefined;
        const path = if (f.exact_name)
            f.suffix
        else
            std.fmt.bufPrint(&buf, "{s}-{s}", .{ name_prefix, f.suffix }) catch f.suffix;
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

/// The X2 file attributes one emitted layer carries beyond what its geometry
/// determines.
pub const Meta = struct {
    /// `%TF.FileFunction` — the planned file's own value (`LayerFile.function`).
    function: []const u8,
    /// `%TF.CreationDate`, ISO 8601 with a UTC offset (see `creationDate`).
    /// NULL OMITS THE ATTRIBUTE, and that is the default on purpose: this
    /// writer is deterministic, so a CLI export and a golden test reproduce
    /// byte for byte. Only a SERVED package stamps a clock — the same split
    /// `export_pdf`/`serve/schematic_pdf` use for `/CreationDate`.
    created: ?[]const u8 = null,
    /// A pre-solved silkscreen placement (`planSilk`) for the silk layers to
    /// draw from. NULL means "solve it yourself", which is right for a lone
    /// layer; a caller writing a whole package solves it ONCE and threads the
    /// same plan through every file — see `SilkPlan`.
    silk: ?*const SilkPlan = null,
    /// A pre-seeded board-edge margin field (`pour.sharedEdgeField`) for the
    /// poured layers to start from. NULL means "seed it per fill", which is
    /// right for a lone layer; a caller writing a whole package seeds it ONCE
    /// and threads the same field through every file, because it depends only
    /// on the board outline — never on the layer. See `pour.computeShared`.
    edge: ?pour.EdgeField = null,
};

/// The side-independent half of a board's silkscreen: mask relief, the
/// generated sub-circuit annotations, test-point labels and pin-one markers.
///
/// Solving it runs a label-vs-pad clearance sweep over the whole board, and
/// none of the result depends on which side is being written — so a package
/// writer that hands the SAME plan to F.SilkS and B.SilkS (and reads the
/// annotations itself, as `fab_identity` does for the fab-ID text) pays the
/// sweep once instead of once per consumer. On a dense board that sweep was
/// most of the cost of building the package.
pub const SilkPlan = struct {
    relief: mask_relief.Relief,
    annotations: []subcircuit_silkscreen.Annotation,
    testpoint_labels: []testpoint_silkscreen.Label,
    /// `texts` plus every test-point label — the silk boxes a pin-one marker
    /// must stay clear of.
    reserved_texts: []const font.BoardText,
    pin_one_markers: []subcircuit_silkscreen.PinOneMarker,
};

/// Solve the side-independent silkscreen for one board (see `SilkPlan`).
/// Arena-owned; `texts` are the layout's board-level silk labels.
pub fn planSilk(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    texts: []const font.BoardText,
) Error!SilkPlan {
    const tracks = try physicalTracks(arena, copper);
    // Generated annotations and test-point labels are placed first so the
    // pin-one search can reserve every board-level silk box around pad 1.
    const relief = try mask_relief.computeRouted(arena, placement, .{
        .tracks = copper.tracks,
        .arcs = copper.arcs,
        .rf_paths = copper.rf_paths,
    }, copper.vias);
    const annotations = try subcircuit_silkscreen.collectWithBoardTexts(arena, placement, &.{}, copper.silk_keepouts, relief, texts);
    const testpoint_labels = try testpoint_silkscreen.collectWithKeepouts(arena, placement, &.{}, copper.silk_keepouts, annotations, texts);
    const reserved_texts = try arena.alloc(font.BoardText, texts.len + testpoint_labels.len);
    @memcpy(reserved_texts[0..texts.len], texts);
    for (testpoint_labels, 0..) |label, i| reserved_texts[texts.len + i] = label.text;
    return .{
        .relief = relief,
        .annotations = annotations,
        .testpoint_labels = testpoint_labels,
        .reserved_texts = reserved_texts,
        .pin_one_markers = try subcircuit_silkscreen.collectPinOneMarkers(
            arena,
            placement,
            .{
                .keepouts = copper.silk_keepouts,
                .relief = relief,
                .annotations = annotations,
                .reserved_texts = reserved_texts,
                .tracks = tracks,
            },
        ),
    };
}

/// Format a unix-epoch second count as the `%TF.CreationDate` value: ISO 8601
/// with an explicit zone, which is what the X2 spec requires (`Z` is legal
/// ISO but the spec's own grammar and every CAM sample use a numeric offset).
/// UTC, so the stamp is unambiguous wherever the server runs.
pub fn creationDate(allocator: std.mem.Allocator, unix_s: i64) std.mem.Allocator.Error![]const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, unix_s)) };
    const day = es.getDaySeconds();
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00", .{
        @as(u32, yd.year),
        @backingInt(md.month),
        md.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

/// Write one complete Gerber file for `layer`. `copper` is the saved
/// layout's persisted routed copper (empty is fine — pads still flash);
/// `texts` are the saved layout's board-level silkscreen labels (only the
/// silk layers consume them); `frame` must be the same package frame every
/// sibling file uses; `meta` carries the file attributes (see `Meta`).
pub fn writeLayer(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    copper: Copper,
    texts: []const font.BoardText,
    frame: export_fab.Frame,
    layer: Layer,
    meta: Meta,
) Error!void {
    // Geometry is buffered first so the aperture dictionary it builds can be
    // written into the header ahead of it.
    var body: std.Io.Writer.Allocating = .init(arena);
    var aps = Apertures{};
    var g = Gx{ .w = &body.writer, .aps = &aps, .arena = arena, .frame = frame, .copper = kindOf(layer).isCopper(), .edge = meta.edge };

    switch (layer) {
        .copper => |side| try writeCopper(&g, placement, copper, side),
        .plane => |pl| try writePlane(&g, placement, copper, pl),
        .inner_signal => |is| try writeInnerCopper(&g, placement, copper, is.sig),
        .mask => |side| try writeMask(&g, placement, copper, side),
        .paste => |side| try writePaste(&g, placement, side),
        .silk => |side| try writeSilk(&g, placement, copper, side, texts, meta.silk),
        .fabrication => |fab| try writeFabrication(&g, placement, fab.index),
        .edge => try writeEdge(&g, placement),
    }

    try w.writeAll("%TF.GenerationSoftware,netlisp,netlisp,1*%\n");
    // Between the software and the function attributes, exactly where KiCad
    // writes it — and only when a caller supplied a clock read.
    if (meta.created) |stamp| try w.print("%TF.CreationDate,{s}*%\n", .{stamp});
    try w.print("%TF.FileFunction,{s}*%\n", .{meta.function});
    try w.print("%TF.FilePolarity,{s}*%\n", .{polarityOf(layer)});
    if (placement.board_rect == null)
        try w.writeAll("G04 no (board ...) outline authored; profile synthesized from the parts bounding box*\n");
    if (layer == .plane and !placement.rules.declaredStackup()) {
        // The implicit stack is an ASSUMPTION, not an authored fact, so say so
        // on the plane itself: a fab reading the package sees which net each
        // undeclared inner layer pours.
        if (layer.plane.net == .ground) {
            try w.writeAll("G04 implicit stackup: this inner plane pours every ground-named net*\n");
        } else {
            try w.print("G04 implicit stackup: this inner plane pours the supply rail {s}*\n", .{layer.plane.net.named});
        }
    }
    try w.writeAll("%FSLAX46Y46*%\n%MOMM*%\nG01*\n%LPD*%\n");
    for (aps.list.items, 10..) |ap, code| {
        // `%TA` sets the attribute for the definitions that follow and `%TD`
        // clears every attribute, so one classified aperture is wrapped in its
        // own pair — unambiguous whatever order the dictionary comes out in.
        if (ap.func.attr()) |a| try w.print("%TA.AperFunction,{s}*%\n", .{a});
        switch (ap.kind) {
            .c => try w.print("%ADD{d}C,{d:.6}*%\n", .{ code, umToMm(ap.w) }),
            .r => try w.print("%ADD{d}R,{d:.6}X{d:.6}*%\n", .{ code, umToMm(ap.w), umToMm(ap.h) }),
            .o => try w.print("%ADD{d}O,{d:.6}X{d:.6}*%\n", .{ code, umToMm(ap.w), umToMm(ap.h) }),
        }
        if (ap.func.attr() != null) try w.writeAll("%TD*%\n");
    }
    try w.writeAll(body.written());
    try w.writeAll("M02*\n");
}

// ── Layer content ───────────────────────────────────────────────────────────

/// Outer signal copper: an optional declared same-index pour (solid, with the
/// exact computed clearance holes shared by the editor), then pad flashes,
/// routed tracks of this layer, and via lands.
fn writeCopper(g: *Gx, placement: optimizer.Placement, copper: Copper, side: optimizer.Side) Error!void {
    const li: u8 = if (side == .bottom) 1 else 0;
    const stack_idx: u8 = if (side == .top) 1 else bottomIndex(placement.rules);
    const physical_arcs = try physicalArcs(g.arena, copper);

    // A `(plane IDX "NET")` declared on this OUTER layer: pour the COMPUTED
    // fill (island-free kept components) and its computed holes verbatim. The
    // old writer threw those holes away and rebuilt a second clearance pass
    // (including pad bounding boxes), which made the fabricated gap larger than
    // the editor's. Same-net through-hole lands remain solidly joined: outer
    // pours do not add a thermal-relief ring or spokes.
    if (declaredPlaneAt(placement.rules, stack_idx)) |pour_net| {
        const pnet: pour.PlaneNet = .{ .named = pour_net };
        // A ranked user pour on this face outranks the declared background pour,
        // so the declared copper recedes by the clearance around it (no short).
        var pspec: pour.LayerSpec = .{ .net = pnet, .side = side, .track_layer = li };
        pspec.higher = try pour.higherThanDeclared(g.arena, copper.zones, li, pnet);
        const fill = try pour.computeShared(g.arena, placement, .{ .tracks = copper.tracks, .vias = copper.vias, .rf_paths = copper.rf_paths }, pspec, g.edge);
        try writeComputedFill(g, fill);
    }

    // Hand-drawn user copper pours on this outer face (see `writeUserZone`).
    for (copper.zones, 0..) |z, zi| {
        if (z.layer != li) continue;
        try writeUserZone(g, placement, copper, side, zi);
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
        if (arcOwnsTrack(copper.arcs, t)) continue;
        if (rfOwnsTrack(copper.rf_paths, t)) continue;
        try g.useAs(.c, t.width, 0, .conductor);
        try g.line(t.x1, t.y1, t.x2, t.y2);
    }
    try writeRfRegions(g, copper.rf_paths, li);
    try writeLayerArcs(g, physical_arcs, li);
    for (copper.vias) |v| {
        try g.useAs(.c, v.dia, 0, .via_pad);
        try g.flash(v.x, v.y);
    }
}

/// Is this track one of the bounded chords an arc's copper is ALSO carried as?
/// The router keeps chords for connectivity and clearance while the arc itself
/// is the real geometry, so anything drawing true arcs — the Gerber writers
/// here, the board PNG — must drop exactly these tracks or it doubles the
/// copper. One rule, so fabrication and the picture of it agree.
pub fn arcOwnsTrack(arcs: []const router.Arc, track: router.Track) bool {
    for (arcs) |arc| {
        if (arc.layer != track.layer or arc.net != track.net or @abs(arc.width - track.width) > 0.0001) continue;
        if (outline.arcOwnsSegment(.{ .p1 = arc.p1, .pm = arc.pm, .p2 = arc.p2 }, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, 0.0001)) return true;
    }
    return false;
}

/// Emit each contiguous solver RF centreline as one G36 swept copper region.
/// The router keeps chords for connectivity/clearance, but fabrication no
/// longer receives dozens of overlapping short tracks or treats the taper as
/// a sequence of under-width traces.
fn writeRfRegions(g: *Gx, paths: []const rf_port_report.Outcome, layer: u8) Error!void {
    for (paths) |path| {
        if (!path.success or path.physical.gate_removed) continue;
        if (path.physical.layer != layer or path.physical.samples.len < 2) continue;
        try writeRfRun(g, path.physical.samples);
    }
}

fn rfOwnsTrack(paths: []const rf_port_report.Outcome, track: router.Track) bool {
    return path_copper.ownsTrack(paths, track);
}

fn writeRfRun(g: *Gx, samples: []const @import("placement/rf_path_solver.zig").Sample) Error!void {
    const polys = try path_copper.regions(g.arena, samples);
    for (polys) |poly| try regionPoly(g, poly);
}

fn writeLayerArcs(g: *Gx, arcs: []const router.Arc, layer: u8) Error!void {
    for (arcs) |arc| {
        if (arc.layer != layer) continue;
        try g.useAs(.c, arc.width, 0, .conductor);
        try g.arc(arc.p1, arc.pm, arc.p2);
    }
}

fn writePlaneClearanceArcs(g: *Gx, placement: optimizer.Placement, arcs: []const router.Arc, layer: u8, plane: PlaneNet, fallback: f64) Error!void {
    for (arcs) |arc| {
        if (arc.layer != layer or planeCarries(plane, netName(placement, arc.net))) continue;
        const gap = placement.rules.clearanceForNet(arc.net, fallback);
        try g.use(.c, arc.width + 2 * gap, 0);
        try g.arc(arc.p1, arc.pm, arc.p2);
    }
}

/// One hand-drawn user copper pour — `copper.zones[zi]` — on signal layer
/// `track_layer`: the same margin-field fill as a declared plane (computed
/// identically to the blob / PNG via `pour.zoneLayerSpec`), confined to the
/// drawn polygon and cleared back from any higher-priority overlapping pour on
/// this layer (`pour.higherPolys`, keyed on the global index `zi`). `side` is the
/// outer face (`null` for an inner layer — an inner pour carves only drilled
/// barrels/vias + same-layer inner tracks, never SMD pads). Emits the carved
/// fill as dark G36 regions and punches its interior antipad loops in clear
/// polarity. Own-net through-hole pads stay solidly joined without thermals.
fn writeUserZone(g: *Gx, placement: optimizer.Placement, copper: Copper, side: ?optimizer.Side, zi: usize) Error!void {
    const z = copper.zones[zi];
    var spec = pour.zoneLayerSpec(z.net, side, z.layer, z.poly);
    // Clear the fill back from any higher-priority overlapping pour on this layer.
    spec.higher = try pour.higherPolys(g.arena, copper.zones, zi);
    const fill = try pour.computeShared(g.arena, placement, .{ .tracks = copper.tracks, .vias = copper.vias, .rf_paths = copper.rf_paths }, spec, g.edge);
    if (fill.contours.len == 0) return;
    try writeComputedFill(g, fill);
}

/// Emit one pour engine result without reconstructing any obstacle geometry.
/// Every dark contour and every clear interior loop is therefore byte-derived
/// from the same polygons `pour_json` gives the interactive editor.
///
/// Polarity order matters when one kept component is an island inside another
/// component's hole: drawing every dark contour and then every clear hole
/// erases that island from the finished film. Largest contours are parents of
/// any nested components, so emit each contour followed by its own holes in
/// descending area order. A later nested contour then restores its copper
/// after the parent's clear pass, matching the fill's even-odd geometry.
fn writeComputedFill(g: *Gx, fill: pour.Fill) Error!void {
    const order = try g.arena.alloc(usize, fill.contours.len);
    for (order, 0..) |*idx, i| idx.* = i;
    std.mem.sort(usize, order, fill.contours, contourAreaDesc);

    for (order) |i| {
        try g.polarity(true);
        try regionPoly(g, fill.contours[i]);
        if (i >= fill.holes.len or fill.holes[i].len == 0) continue;
        try g.polarity(false);
        for (fill.holes[i]) |hole| try regionPoly(g, hole);
    }
    try g.polarity(true);
}

fn contourAreaDesc(contours: []const []const [2]f64, a: usize, b: usize) bool {
    const aa = @abs(outline.signedArea2(contours[a]));
    const ba = @abs(outline.signedArea2(contours[b]));
    return aa > ba or (aa == ba and a < b);
}

/// Inner SIGNAL copper: any hand-drawn user pours on this layer (see
/// `writeUserZone` — an inner zone has no outer face, so it carves only drilled
/// barrels/vias + same-layer inner tracks), then the routed tracks persisted on
/// signal layer `sig`, via lands (through vias reach every copper layer), and
/// through-pad barrel annuli (a PTH pad has copper on each layer — inner tracks
/// may terminate on it). SMD pads live only on their outer face and never
/// appear here.
fn writeInnerCopper(g: *Gx, placement: optimizer.Placement, copper: Copper, sig: u8) Error!void {
    const physical_arcs = try physicalArcs(g.arena, copper);
    // Poured base first, so the pad/track/via copper below re-lands on the
    // cleaned fill — the same ordering `writeCopper` uses for an outer face.
    for (copper.zones, 0..) |z, zi| {
        if (z.layer != sig) continue;
        try writeUserZone(g, placement, copper, null, zi);
    }
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (!pad.thru or pad.npth) continue;
            try flashPad(g, p, pad, 0);
        }
    }
    for (copper.tracks) |t| {
        if (t.layer != sig) continue;
        if (arcOwnsTrack(copper.arcs, t)) continue;
        if (rfOwnsTrack(copper.rf_paths, t)) continue;
        try g.useAs(.c, t.width, 0, .conductor);
        try g.line(t.x1, t.y1, t.x2, t.y2);
    }
    try writeRfRegions(g, copper.rf_paths, sig);
    try writeLayerArcs(g, physical_arcs, sig);
    for (copper.vias) |v| {
        try g.useAs(.c, v.dia, 0, .via_pad);
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
    const physical_tracks = try physicalTracks(g.arena, copper);
    const fill = try pour.computeShared(g.arena, placement, .{ .tracks = physical_tracks, .vias = copper.vias }, .{ .net = pnet }, g.edge);
    for (fill.contours) |poly| try regionPoly(g, poly);
    try g.polarity(false);
    const nets = try padNets(g.arena, placement);
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (pad.drill <= 0) continue;
            const pad_net = netOfPad(nets, placement, p.ref_des, pad.number);
            const foreign = pad.npth or !planeCarries(pl.net, pad_net);
            if (!foreign) continue;
            const gap = pourClearanceNamed(placement, pad_net, pc);
            try g.use(.c, pad.drill + 2 * gap, 0);
            if (pad.isSlot()) {
                // An oval hole's antipad is the capsule swept by the cleared
                // tool: a round-cap stroke between the two arc centres.
                const e1 = optimizer.worldPadCenter(&p, pad.x + pad.slot_half[0], pad.y + pad.slot_half[1]);
                const e2 = optimizer.worldPadCenter(&p, pad.x - pad.slot_half[0], pad.y - pad.slot_half[1]);
                try g.line(e1[0], e1[1], e2[0], e2[1]);
            } else {
                const c = optimizer.worldPadCenter(&p, pad.x, pad.y);
                try g.flash(c[0], c[1]);
            }
        }
    }
    for (copper.vias) |v| {
        if (planeCarries(pl.net, netName(placement, v.net))) continue;
        const gap = pour.viaPlaneClearance(placement, v, pnet, pc);
        try g.use(.c, v.dia + 2 * gap, 0);
        try g.flash(v.x, v.y);
    }
    try g.polarity(true);
    try thermalReliefs(g, placement, nets, pl.net);
}

fn pourClearanceNamed(placement: optimizer.Placement, name: []const u8, base: f64) f64 {
    for (placement.nets, 0..) |net, i| {
        if (std.ascii.eqlIgnoreCase(net.name, name)) {
            return placement.rules.clearanceForNet(@intCast(i), base);
        }
    }
    return base;
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
    try g.useAs(.c, thermal_spoke_mm, 0, .conductor);
    try g.line(cx - reach, cy, cx + reach, cy);
    try g.line(cx, cy - reach, cx, cy + reach);
}

/// Solder mask (negative: a flash = an OPENING in the mask). SMD pads open
/// on their part's side; an IC's exposed thermal paddle additionally opens an
/// exact 1:1 window on the opposite face; through-hole and NPTH pads open on
/// both sides. Any positive web below the resolved `mask-web` floor is removed
/// by joining the neighbouring apertures; it is not left as a DRC warning for
/// a fabricator to resolve differently.
/// Ordinary vias are tented. A RELIEVED net (`(mask-relief …)`, defaulting on
/// for a max-freq class, widened over a declared fence) opens the mask along
/// its routed copper first — the exposure-run polygons plus an antipad-sized
/// opening polygon where an exposed run reaches an RF transition via — that
/// `mask_relief.computeRouted` returns, which already merged runs across joints,
/// dropped stretches under its 1 mm floor, and clipped trace openings one mask
/// web before pads that terminate or cross the route. For a pad beside a wider
/// RF opening, a clear-polarity copy of that pad's aperture plus one web puts
/// back only a local pad-shaped mask island; the pad aperture is then reopened,
/// so the trace exposure remains continuous around it. A declared perimeter
/// fence adds openings centred on the exact finished edge; CAM clips the
/// outside half, leaving the authored `mask-width` band inward on both faces.
/// The stroke exists only on a face carrying a matching GND pour. Pads and
/// foreign routed copper split it, retaining finished mask over every non-GND
/// feature and the pour-clearance antipad around it.
fn writeMask(g: *Gx, placement: optimizer.Placement, copper: Copper, side: optimizer.Side) Error!void {
    const margin = placement.rules.design.mask.margin;
    const had_relief = try writeMaskRelief(g, placement, copper, side);
    var physical = copper;
    physical.tracks = try physicalTracks(g.arena, copper);
    physical.arcs = try physicalArcs(g.arena, copper);
    physical.rf_paths = &.{};
    if (had_relief) try writeMaskPadIslands(g, placement, physical, side);
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            if (isSmd(pad) and p.side != side) {
                if (!isExposedPaddle(p, pad)) continue;
                if (oppositeEpHasNonGroundPour(g, placement, physical, p, pad, side)) continue;
                // The remote opening is a board-to-heatsink contact window,
                // not a solderable land. Keep it exactly the EP's authored
                // outline: the normal registration margin belongs only to the
                // component-side mask aperture.
                try flashPad(g, p, pad, 0);
                continue;
            }
            // A pad's own `(mask-margin …)` REPLACES the board rule for it
            // (KiCad's per-pad `solder_mask_margin`) — a fiducial's target is
            // a bare 0.75 mm pad under a 2.25 mm opening, and flashing it at
            // the board's 0.05 mm ships a fiducial no vision system can read.
            try flashPad(g, p, pad, pad.maskMargin(margin));
        }
    }
    for (try mask_relief.collectMerges(g.arena, placement)) |merge| {
        const layer: u8 = if (side == .bottom) 1 else 0;
        if (merge.layer != layer) continue;
        try g.use(.c, merge.width, 0);
        try g.line(merge.x1, merge.y1, merge.x2, merge.y2);
    }
    const fence = placement.rules.perimeter_fence;
    if (fence.mask_width > 0) {
        const segments = try perimeter_fence.maskSegmentsForFaceWithVias(g.arena, placement, physical.tracks, physical.vias, side);
        if (segments.len > 0) {
            try g.use(.c, 2 * fence.mask_width, 0);
            for (segments) |segment| try g.line(segment.a[0], segment.a[1], segment.b[0], segment.b[1]);
        }
    }
    // The paddle flashes above can uncover ordinary routed copper on this
    // outer face. Put mask back over every non-ground trace/via after ALL
    // openings so this safety guard has final precedence.
    for (placement.parts) |p| {
        if (p.side == side) continue;
        for (p.pads) |pad| {
            if (!isExposedPaddle(p, pad)) continue;
            if (oppositeEpHasNonGroundPour(g, placement, physical, p, pad, side)) continue;
            try protectOppositeEpSignals(g, placement, physical, p, pad, side);
        }
    }
}

/// Put solder mask back locally where a routed RF opening overlaps a pad's
/// retaining web. This pass deliberately paints the exact pad shape plus its
/// aperture margin and one mask web, rather than clipping a full-width bar out
/// of the relief run. `writeMask` immediately re-flashes the ordinary pad
/// apertures afterward, leaving a pad-shaped island/ring while the exposed RF
/// trace continues on both sides.
fn writeMaskPadIslands(g: *Gx, placement: optimizer.Placement, copper: Copper, side: optimizer.Side) Error!void {
    const design = placement.rules.design;
    try g.polarity(false);
    for (placement.parts) |p| {
        for (p.pads) |pad| {
            var aperture_margin = pad.maskMargin(design.mask.margin);
            if (isSmd(pad) and p.side != side) {
                if (!isExposedPaddle(p, pad)) continue;
                if (oppositeEpHasNonGroundPour(g, placement, copper, p, pad, side)) continue;
                // The opposite-face EP aperture is exact-size, so its island
                // grows only by the required web.
                aperture_margin = 0;
            }
            try flashPad(g, p, pad, aperture_margin + design.mask.web);
        }
    }
    try g.polarity(true);
}

/// Dark relief openings over every relieved net's copper on this face. A
/// continuous exposure run is one closed, filleted region; construction
/// strokes are only a compatibility fallback. Returns whether anything opened,
/// so a board with no relieved net emits a byte-identical mask (no polarity
/// toggles, no dam pass).
fn writeMaskRelief(g: *Gx, placement: optimizer.Placement, copper: Copper, side: optimizer.Side) Error!bool {
    const li: u8 = if (side == .bottom) 1 else 0;
    const relief = try mask_relief.computeRouted(g.arena, placement, .{
        .tracks = copper.tracks,
        .arcs = copper.arcs,
        .rf_paths = copper.rf_paths,
    }, copper.vias);
    var any = false;
    var layer_has_outline = false;
    for (relief.openings) |opening| {
        if (opening.layer != li or opening.poly.len < 3) continue;
        try regionFilletedPoly(g, opening.poly, opening.arcs);
        layer_has_outline = true;
        any = true;
    }
    if (!layer_has_outline) {
        for (relief.strokes) |s| {
            if (s.layer != li) continue;
            if (s.terminal.trim_start or s.terminal.trim_end) {
                const poly = try mask_relief.openingPoly(g.arena, s);
                if (poly.len >= 3) try regionPoly(g, poly);
            } else {
                try g.use(.c, s.widths.opening, 0);
                try g.line(s.x1, s.y1, s.x2, s.y2);
            }
            any = true;
        }
        for (relief.joints) |j| {
            if (j.layer != li) continue;
            try g.use(.c, j.dia, 0);
            try g.flash(j.x, j.y);
            any = true;
        }
    }
    // Only the compatibility path needs the old cap-overlap repair. A native
    // opening has no per-chord caps to erase or repaint.
    if (!layer_has_outline) {
        var has_terminal = false;
        for (relief.strokes) |s| {
            if (s.layer != li) continue;
            for ([2]bool{ true, false }) |at_start| {
                const finish = try mask_relief.terminalFinish(g.arena, s, at_start) orelse continue;
                if (!has_terminal) try g.polarity(false);
                has_terminal = true;
                try regionPoly(g, &finish.clear);
            }
        }
        if (has_terminal) {
            try g.polarity(true);
            for (relief.strokes) |s| {
                if (s.layer != li) continue;
                for ([2]bool{ true, false }) |at_start| {
                    const finish = try mask_relief.terminalFinish(g.arena, s, at_start) orelse continue;
                    if (finish.patch.len >= 3) try regionPoly(g, finish.patch);
                }
            }
        }
    }
    return any;
}

/// Surface-mount pad: copper on its part's side only (vs. thru/NPTH, which
/// reach both faces).
fn isSmd(pad: geometry.Pad) bool {
    return !pad.thru and !pad.npth;
}

/// Geometry-level exposed-paddle detection shared with the router's land
/// discipline: a QFN/IC paddle is large in BOTH axes and belongs to a hub,
/// unlike a lead land or a large passive terminal. Keeping the same 1.5 mm
/// full-span threshold means the mask and thermal-via paths agree on what a
/// paddle is without requiring package-name heuristics.
fn isExposedPaddle(part: optimizer.Part, pad: geometry.Pad) bool {
    return part.kind == .hub and isSmd(pad) and
        pad.w / 2 >= land_transit.paddle_min_half_mm and
        pad.h / 2 >= land_transit.paddle_min_half_mm;
}

/// A non-ground poured face cannot safely become a heatsink contact window.
/// Decline the whole remote opening instead of trying to approximate a poured
/// contour in the solder-mask film. Ordinary routed primitives are guarded
/// locally by `protectOppositeEpSignals` below.
fn oppositeEpHasNonGroundPour(
    g: *Gx,
    placement: optimizer.Placement,
    copper: Copper,
    part: optimizer.Part,
    pad: geometry.Pad,
    side: optimizer.Side,
) bool {
    const li: u8 = if (side == .bottom) 1 else 0;
    const stack_idx: u8 = if (side == .top) 1 else bottomIndex(placement.rules);
    if (declaredPlaneAt(placement.rules, stack_idx)) |name| {
        if (!isGroundNetName(name)) return true;
    }
    const ep = pad_shape.worldShape(g.arena, part, pad) catch return true;
    const guard = @max(0, placement.rules.design.mask.margin);
    for (copper.zones) |zone| {
        if (zone.layer != li or isGroundNetName(zone.net) or zone.poly.len < 3) continue;
        const zone_shape = shapeOfPoly(zone.poly);
        if (pad_shape.shapeGap(ep, zone_shape, guard) <= guard) return true;
    }
    return false;
}

fn shapeOfPoly(poly: []const [2]f64) pad_shape.Shape {
    var x0 = std.math.inf(f64);
    var y0 = std.math.inf(f64);
    var x1 = -std.math.inf(f64);
    var y1 = -std.math.inf(f64);
    for (poly) |point| {
        x0 = @min(x0, point[0]);
        y0 = @min(y0, point[1]);
        x1 = @max(x1, point[0]);
        y1 = @max(y1, point[1]);
    }
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .poly = poly };
}

/// Subtract only the portions of non-ground outer-face tracks and vias which
/// can overlap one remote EP window. The mask margin grows the protected
/// copper so registration tolerance cannot leave a signal sliver exposed.
fn protectOppositeEpSignals(
    g: *Gx,
    placement: optimizer.Placement,
    copper: Copper,
    part: optimizer.Part,
    pad: geometry.Pad,
    side: optimizer.Side,
) Error!void {
    const ep = try pad_shape.worldShape(g.arena, part, pad);
    const li: u8 = if (side == .bottom) 1 else 0;
    const guard = @max(0, placement.rules.design.mask.margin);
    var clearing = false;
    for (copper.tracks) |track| {
        if (track.layer != li or isGroundNetName(netName(placement, track.net))) continue;
        const radius = track.width / 2 + guard;
        if (pad_shape.segmentDist(ep, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, radius) > radius) continue;
        const clipped = clipSegmentToBox(
            .{ track.x1, track.y1 },
            .{ track.x2, track.y2 },
            ep.x0 - radius,
            ep.y0 - radius,
            ep.x1 + radius,
            ep.y1 + radius,
        ) orelse continue;
        if (!clearing) {
            try g.polarity(false);
            clearing = true;
        }
        try g.use(.c, 2 * radius, 0);
        try g.line(clipped[0][0], clipped[0][1], clipped[1][0], clipped[1][1]);
    }
    for (copper.vias) |via| {
        if (isGroundNetName(netName(placement, via.net))) continue;
        const radius = via.dia / 2 + guard;
        if (pad_shape.pointDist(ep.x0, ep.y0, ep.x1, ep.y1, ep.poly, via.x, via.y, radius) > radius) continue;
        if (!clearing) {
            try g.polarity(false);
            clearing = true;
        }
        try g.use(.c, 2 * radius, 0);
        try g.flash(via.x, via.y);
    }
    if (clearing) try g.polarity(true);
}

fn isGroundNetName(name: []const u8) bool {
    return name.len > 0 and optimizer.isGroundName(leafName(name));
}

/// Liang-Barsky slab clip of a line segment to an axis-aligned box.
fn clipSegmentToBox(a: [2]f64, b: [2]f64, x0: f64, y0: f64, x1: f64, y1: f64) ?[2][2]f64 {
    var lo: f64 = 0;
    var hi: f64 = 1;
    if (!clipSegmentAxis(a[0], b[0] - a[0], x0, x1, &lo, &hi)) return null;
    if (!clipSegmentAxis(a[1], b[1] - a[1], y0, y1, &lo, &hi)) return null;
    return .{
        .{ a[0] + (b[0] - a[0]) * lo, a[1] + (b[1] - a[1]) * lo },
        .{ a[0] + (b[0] - a[0]) * hi, a[1] + (b[1] - a[1]) * hi },
    };
}

fn clipSegmentAxis(origin: f64, delta: f64, min: f64, max: f64, lo: *f64, hi: *f64) bool {
    if (@abs(delta) <= 1e-12) return origin >= min and origin <= max;
    const ta = (min - origin) / delta;
    const tb = (max - origin) / delta;
    lo.* = @max(lo.*, @min(ta, tb));
    hi.* = @min(hi.*, @max(ta, tb));
    return lo.* <= hi.*;
}

/// Paste stencil: SMD pads on this side only, at 1:1 (assemblers apply
/// their own shrink rules). A pad marked `no-paste` is skipped — a fiducial's
/// target, a hand-soldered pad or a probe point must NOT get an aperture, and
/// a stencil that pastes a fiducial hides it under solder.
fn writePaste(g: *Gx, placement: optimizer.Placement, side: optimizer.Side) Error!void {
    for (placement.parts) |p| {
        if (p.side != side) continue;
        for (p.pads) |pad| {
            if (pad.thru or pad.npth or pad.noPaste()) continue;
            try flashPad(g, p, pad, 0);
        }
    }
}

/// Silkscreen: each same-side part's authored footprint art (lines + circles),
/// generated sub-circuit corner/name artwork, then board-level user text.
/// Component ref-des is deliberately NOT synthesized here: if it is absent
/// from the PCB editor's silk artwork it must also be absent from fabrication.
/// Bottom-side text mirrors so it reads correctly when the board is flipped.
/// Generated legs and names also avoid the mask-relieved bare copper the
/// mask layer opens — silk ink on exposed RF copper is scrap.
fn writeSilk(
    g: *Gx,
    placement: optimizer.Placement,
    copper: Copper,
    side: optimizer.Side,
    texts: []const font.BoardText,
    prepared: ?*const SilkPlan,
) Error!void {
    // Both silk sides read the SAME plan — it is side-independent — so a
    // package writer solves it once and passes it in (see `SilkPlan`).
    const plan = if (prepared) |p| p.* else try planSilk(g.arena, placement, copper, texts);
    const annotations = plan.annotations;
    const testpoint_labels = plan.testpoint_labels;
    const pin_one_markers = plan.pin_one_markers;

    for (placement.parts) |p| {
        if (p.side != side) continue;
        try g.use(.c, silk_w_mm, 0);
        for (p.features.silk_lines) |l| {
            const a = optimizer.worldPadCenter(&p, l.x1, l.y1);
            const b = optimizer.worldPadCenter(&p, l.x2, l.y2);
            try g.line(a[0], a[1], b[0], b[1]);
        }
        for (p.features.silk_circles) |ci| {
            if (subcircuit_silkscreen.isAuthoredPinOneIndicator(ci)) continue;
            const c = optimizer.worldPadCenter(&p, ci.cx, ci.cy);
            try strokeCircle(g, c[0], c[1], ci.r);
        }
    }
    // A pin-one marker is a true filled dot, not a stroked ring. A circular
    // aperture flash preserves its exact 0.3 mm finished diameter.
    try g.use(.c, subcircuit_silkscreen.pin_one_marker_diameter_mm, 0);
    for (pin_one_markers) |marker| {
        if (marker.side != side) continue;
        try g.flash(marker.x, marker.y);
    }
    // Generated board annotation: safe corner legs around every flattened
    // top-level sub-circuit, plus its name inline on a collision-free edge. The
    // group's main IC chooses which physical silk layer owns all of its artwork.
    for (annotations) |annotation| {
        if (annotation.side != side) continue;
        try g.use(.c, silk_w_mm, 0);
        for (annotation.visibleSegments()) |segment| {
            try g.line(segment.x1, segment.y1, segment.x2, segment.y2);
        }
        try drawBoardText(g, annotation.label());
    }
    // A test point carries one authoritative label that the editor also shows.
    for (testpoint_labels) |label| {
        if (label.text.bottom != (side == .bottom)) continue;
        try drawBoardText(g, label.text);
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
    try g.useAs(.c, edge_w_mm, 0, .profile);
    if (placement.board_poly) |poly| {
        if (poly.len >= 3) {
            var prev = poly[poly.len - 1];
            for (poly) |v| {
                if (boardArcOwnsSegment(placement.board_arcs, prev, v)) {
                    prev = v;
                    continue;
                }
                try g.line(prev[0], prev[1], v[0], v[1]);
                prev = v;
            }
            for (placement.board_arcs) |arc| try g.arc(arc.p1, arc.pm, arc.p2);
            return;
        }
    }
    const r = export_fab.outlineRect(placement);
    try g.line(r.minx, r.miny, r.minx + r.w, r.miny);
    try g.line(r.minx + r.w, r.miny, r.minx + r.w, r.miny + r.h);
    try g.line(r.minx + r.w, r.miny + r.h, r.minx, r.miny + r.h);
    try g.line(r.minx, r.miny + r.h, r.minx, r.miny);
}

fn writeBoardRegion(g: *Gx, placement: optimizer.Placement) Error!void {
    if (placement.board_poly) |poly| {
        if (poly.len >= 3) return regionFilletedPoly(g, poly, placement.board_arcs);
    }
    const r = export_fab.outlineRect(placement);
    const points = [_][2]f64{
        .{ r.minx, r.miny },
        .{ r.minx + r.w, r.miny },
        .{ r.minx + r.w, r.miny + r.h },
        .{ r.minx, r.miny + r.h },
    };
    try regionPoly(g, &points);
}

fn fabricationRefSelected(refs: []const []const u8, ref: []const u8) bool {
    if (refs.len == 0) return true;
    for (refs) |wanted| {
        if (std.mem.eql(u8, wanted, ref) or std.mem.eql(u8, wanted, leafName(ref))) return true;
    }
    return false;
}

/// Positive backing regions followed by clear-polarity courtyard holes. The
/// footprint projection follows the selected face unless the design explicitly
/// requests all sides, so a top-only component does not unexpectedly punch a
/// bottom adhesive sheet.
fn writeFabrication(g: *Gx, placement: optimizer.Placement, index: usize) Error!void {
    if (index >= placement.fabrication_layers.len) return;
    const spec = placement.fabrication_layers[index];
    try g.w.print("G04 fabrication {s}; side={s}; material={s}; thickness={d:.6}mm*\n", .{
        spec.kind, @tagName(spec.side), spec.material, spec.thickness,
    });
    for (spec.regions) |region| switch (region) {
        .board => try writeBoardRegion(g, placement),
        .polygon => |points| try regionPoly(g, points),
    };

    const exclusion = spec.exclude_footprints;
    if (!exclusion.enabled) return;
    try g.polarity(false);
    const wanted_side: optimizer.Side = if (spec.side == .bottom) .bottom else .top;
    for (placement.parts) |*part| {
        if (!exclusion.all_sides and part.side != wanted_side) continue;
        if (!fabricationRefSelected(exclusion.refs, part.ref_des)) continue;
        const r = optimizer.worldCourtyard(part);
        const c = exclusion.clearance;
        const points = [_][2]f64{
            .{ r.minx - c, r.miny - c },
            .{ r.minx + r.w + c, r.miny - c },
            .{ r.minx + r.w + c, r.miny + r.h + c },
            .{ r.minx - c, r.miny + r.h + c },
        };
        try regionPoly(g, &points);
    }
    try g.polarity(true);
}

fn boardArcOwnsSegment(arcs: []const optimizer.BoardArc, a: [2]f64, b: [2]f64) bool {
    for (arcs) |arc| if (outline.arcOwnsSegment(arc, a, b, 0.0001)) return true;
    return false;
}

// ── Pads ────────────────────────────────────────────────────────────────────

/// Flash one pad at its world pose. Shapes map to their faithful fab feature:
/// a circle is a C aperture; an axis-aligned plain rect / oval is an R / O
/// aperture (w/h swapped on a quarter turn — the fast, byte-identical path); a
/// roundrect, or ANY pad at a non-quarter angle, is emitted as its true outline
/// via a G36 region (rounded corners / arbitrary rotation an aperture can't
/// represent); a custom (thermal/EP) outline flashes its real copper polygon.
/// `expand` grows every feature per side (mask/paste openings). A custom
/// polygon grows as its original filled region plus a round stroke along its
/// closed boundary. That is the polygon's geometric dilation by `expand`, and
/// unlike a synthesized offset ring it remains valid at concave corners.
/// An APERTURE flash on a copper layer carries the pad's `%TA.AperFunction`; a
/// G36 REGION carries none, because a region has no aperture — so a roundrect,
/// a rotated pad or a custom outline goes out unclassified, which is the same
/// gap KiCad's own region output has.
fn flashPad(g: *Gx, p: optimizer.Part, pad: geometry.Pad, expand: f64) Error!void {
    // 1. Custom polygon pad: its exact authored outline, dilated for a
    // positive margin. Placement deliberately simplifies a separate collision
    // copy; fabrication must retain every straight/arc vertex the editor draws.
    if (pad.poly.len >= 3) {
        const poly = try exactCustomPadPoly(g.arena, p, pad);
        if (poly.len >= 3) {
            try regionPoly(g, poly);
            if (expand > 0) try strokeClosedPoly(g, poly, 2 * expand);
            return;
        }
    }
    const c = optimizer.worldPadCenter(&p, pad.x, pad.y);
    // 2. Circle: rotation-invariant, always a C aperture.
    if (std.mem.eql(u8, pad.shape, "circle")) {
        const d = pad.w + 2 * expand;
        if (d <= 0) return;
        try g.useAs(.c, d, d, g.padFunc(pad));
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
    try g.useAs(kind, w, h, g.padFunc(pad));
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
    return if (pad.rratio() > 0) @min(pad.rratio(), 0.5) else geometry.default_rratio;
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
        out[i] = optimizer.worldPadCenter(&p, pad.x + rx, pad.y + ry);
    }
    return out;
}

/// Transform every authored custom-pad vertex through the part pose without
/// applying the collision-only Douglas–Peucker reduction in `pad_shape`.
fn exactCustomPadPoly(arena: std.mem.Allocator, part: optimizer.Part, pad: geometry.Pad) Error![]const [2]f64 {
    const out = try arena.alloc([2]f64, pad.poly.len);
    for (pad.poly, 0..) |point, i| out[i] = optimizer.worldPadCenter(&part, point[0], point[1]);
    return out;
}

/// Dilate a filled polygon with a circular Gerber aperture. The filled region
/// owns the interior; these round edge strokes add exactly `width / 2` outside
/// it and naturally union at convex, concave, and dense imported vertices.
fn strokeClosedPoly(g: *Gx, pts: []const [2]f64, width: f64) Error!void {
    if (pts.len < 3 or width <= 0) return;
    try g.use(.c, width, 0);
    const repeats_first = pts[0][0] == pts[pts.len - 1][0] and pts[0][1] == pts[pts.len - 1][1];
    const ring = if (repeats_first) pts[0 .. pts.len - 1] else pts;
    var prev = ring[ring.len - 1];
    for (ring) |point| {
        try g.line(prev[0], prev[1], point[0], point[1]);
        prev = point;
    }
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

/// One implicit inner plane as this writer's `PlaneNet`. A ground plane keeps
/// the `.ground` predicate (every ground-named net); a rail plane becomes an
/// ordinary `.named` plane, which is the same shape — and so the same
/// membership, antipad and thermal-relief handling — a declared `(plane …)` on
/// an inner layer already gets.
/// Which writer draws one row of the shared layer table, or null for a row
/// this exporter generates no file for (the reserved courtyard/fab/doc roles).
/// An OUTER copper face always emits its side's copper file — `writeCopper`
/// paints a `(pour …)` there itself — an inner plane pours solid, a plane-free
/// inner carries the router's signal-layer copper at the index tracks persist,
/// and each technical row maps onto its own writer.
fn layerOf(row: *const board_layers.Row, count: u8) ?Layer {
    return switch (row.kind) {
        .signal, .plane => copperLayerOf(row, count),
        .mask => .{ .mask = rowSide(row) },
        .paste => .{ .paste = rowSide(row) },
        .silk => .{ .silk = rowSide(row) },
        .edge => .edge,
        .courtyard, .fab, .doc => null,
    };
}

/// A technical row's board face as this writer's `Side`. A row with no face
/// (which no side-bearing kind reaches) reads as the top, defensively.
fn rowSide(row: *const board_layers.Row) optimizer.Side {
    return if (row.side == .back) .bottom else .top;
}

/// Which writer draws one COPPER row (see `layerOf`).
fn copperLayerOf(row: *const board_layers.Row, count: u8) Layer {
    const idx = row.stack.int();
    if (row.isOuter(count)) return .{ .copper = if (idx == 1) .top else .bottom };
    if (row.kind == .plane) return .{ .plane = .{ .index = idx, .net = rowPlaneNet(row) } };
    const sig = row.signal orelse board_layers.SignalIndex.top;
    return .{ .inner_signal = .{ .index = idx, .sig = sig.int() } };
}

/// The layer-table `Kind` one planned output file plays — the bridge from this
/// writer's `Layer` union back to the shared table's role vocabulary, so
/// role-derived facts (today the Gerber file polarity) are answered in exactly
/// one place for both the layer files and the job file.
fn kindOf(layer: Layer) board_layers.Kind {
    return switch (layer) {
        .copper, .inner_signal => .signal,
        .plane => .plane,
        .mask => .mask,
        .paste => .paste,
        .silk => .silk,
        .fabrication => .fab,
        .edge => .edge,
    };
}

/// The Gerber `%TF.FilePolarity` value for one planned file.
fn polarityOf(layer: Layer) []const u8 {
    return kindOf(layer).gerberPolarity();
}

/// How many of a planned file set are COPPER — the job file's `LayerNumber`.
fn copperFileCount(files: []const LayerFile) usize {
    var n: usize = 0;
    for (files) |f| {
        if (kindOf(f.layer).isCopper()) n += 1;
    }
    return n;
}

/// A plane row's pour target: the net it names, or the GROUND CLASS (every
/// ground-named net) when it names none — the implicit model's ground plane.
fn rowPlaneNet(row: *const board_layers.Row) PlaneNet {
    if (row.plane_net) |net| return .{ .named = net };
    return .ground;
}

/// The declared `(plane IDX "NET")` net at stack index `idx`, if any.
fn declaredPlaneAt(rules: optimizer.BoardRules, idx: u8) ?[]const u8 {
    for (rules.planes.declared) |pl| {
        if (pl.index == idx) return pl.net;
    }
    return null;
}

/// The bottom copper's 1-based stack index (4 for the implicit model).
fn bottomIndex(rules: optimizer.BoardRules) u8 {
    return rules.layerStack().stackCount();
}

/// True for 90°/270° poses (pad w/h swap) — same rule as `pad_shape`.
fn quarterRot(rot: f64) bool {
    const q = @mod(@round(rot), 360);
    return q == 90 or q == 270;
}

// ── Silkscreen text ─────────────────────────────────────────────────────────

/// How a silkscreen string is laid out: nominal size, bottom-side mirroring, and
/// quarter-turn rotation. The 0.15 mm Gerber aperture is independent of size.
const TextGeom = struct {
    size: f64 = font.default_size_mm,
    mirror: bool = false,
    rot: f64 = 0,
};

/// Stroke board-level user text at its world anchor, scaled to its nominal size
/// and rotated to its quarter turn. Bottom text mirrors for face readability.
fn drawBoardText(g: *Gx, t: font.BoardText) Error!void {
    const size = if (t.size > 0) t.size else font.default_size_mm;
    try drawText(g, t.x, t.y, t.text, .{ .size = size, .mirror = t.bottom, .rot = t.rot });
}

/// Stroke `s` centred at (cx,cy) in placement coordinates. Each glyph is a
/// normalized single-line move/draw path; Gerber retains diagonal and curved
/// chords at 1 µm precision rather than exposing a 5×7 bitmap grid.
/// `geom.mirror` flips x about the centre (bottom-side readability);
/// `geom.rot` rotates the whole string about the anchor.
fn drawText(g: *Gx, cx: f64, cy: f64, s: []const u8, geom: TextGeom) Error!void {
    if (s.len == 0) return;
    const scale = geom.size / silk_font.em_units;
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
        scale: f64,
        mirror: bool,
        rotated: bool,
        ca: f64,
        sa: f64,
        // Local font units → world mm: mirror x, then rotate about the anchor.
        fn place(self: @This(), lx_unscaled: f64, ly_unscaled: f64) [2]f64 {
            const lx0 = lx_unscaled * self.scale;
            const ly = ly_unscaled * self.scale;
            const lx = if (self.mirror) -lx0 else lx0;
            if (!self.rotated) return .{ self.cx + lx, self.cy + ly };
            return .{ self.cx + lx * self.ca - ly * self.sa, self.cy + lx * self.sa + ly * self.ca };
        }
        fn emit(self: @This(), stroke: silk_font.Stroke) Error!void {
            const w1 = self.place(self.gx0 + stroke.x1, stroke.y1 - silk_font.cap_units / 2);
            const w2 = self.place(self.gx0 + stroke.x2, stroke.y2 - silk_font.cap_units / 2);
            try self.g.line(w1[0], w1[1], w2[0], w2[1]);
        }
    };
    const rotated = geom.rot != 0;
    try g.use(.c, silk_w_mm, 0);
    var pen = -silk_font.widthUnits(s) / 2;
    for (s) |ch| {
        const em = Emit{ .g = g, .cx = cx, .cy = cy, .gx0 = pen, .scale = scale, .mirror = geom.mirror, .rotated = rotated, .ca = ca, .sa = sa };
        try silk_font.glyphStrokes(ch, Error, em, Emit.emit);
        pen += silk_font.advanceUnits(ch);
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

/// What an aperture PHYSICALLY DRAWS, as the X2 `%TA.AperFunction` attribute.
/// CAM reads these: a netlist extractor tells a pad from a track by them, an
/// e-test generator finds the probeable pads, and a fab's pad-shrink rules
/// apply to pads and not to conductors. `.none` carries no attribute at all,
/// which is right for everything that is not a copper feature — clearance
/// halos, antipads, mask and paste openings, silkscreen.
const ApFunc = enum {
    none,
    /// A surface-mount pad, copper-defined (as opposed to mask-defined).
    smd_pad,
    /// A plated through-hole pad a component lead sits in.
    component_pad,
    /// A via land.
    via_pad,
    /// A track, arc or thermal spoke.
    conductor,
    /// The board profile.
    profile,

    /// The attribute value, or null when this function carries no attribute.
    fn attr(self: ApFunc) ?[]const u8 {
        return switch (self) {
            .none => null,
            // `CuDef` = the pad's extent is defined by its copper, which is
            // how every pad in this model is drawn (the mask opening is
            // derived FROM the copper, never the other way round).
            .smd_pad => "SMDPad,CuDef",
            .component_pad => "ComponentPad",
            .via_pad => "ViaPad",
            .conductor => "Conductor",
            .profile => "Profile",
        };
    }
};

/// One standard aperture, dimensions in integer micro-mm-ish units (mm·1e6)
/// so dedup is exact, plus the X2 function it draws (part of its identity —
/// see `Apertures.code`).
const Ap = struct { kind: ApKind, w: i64, h: i64, func: ApFunc = .none };

/// The file's aperture dictionary: dedups (kind, w, h) → D-code (D10+).
const Apertures = struct {
    list: std.ArrayList(Ap) = .empty,

    fn code(self: *Apertures, arena: std.mem.Allocator, kind: ApKind, w: f64, h: f64, func: ApFunc) std.mem.Allocator.Error!u32 {
        // The FUNCTION is part of the key: a 0.4 mm track and a 0.4 mm via
        // land are not the same aperture to CAM even though they are the same
        // circle, and one D-code cannot carry two `%TA.AperFunction` values.
        const key = Ap{ .kind = kind, .w = mmToUm(w), .h = mmToUm(h), .func = func };
        for (self.list.items, 0..) |a, i| {
            if (a.kind == key.kind and a.w == key.w and a.h == key.h and a.func == key.func) return @intCast(10 + i);
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
    /// True while writing a COPPER layer. A pad flash means "a pad" only
    /// there; the same call on mask or paste draws an opening, which has no
    /// copper aperture function.
    copper: bool = false,
    /// `Meta.edge`: the shared board-edge margin field this file's poured
    /// layers seed from, or null to seed each fill on its own.
    edge: ?pour.EdgeField = null,

    /// Select (defining if needed) an UNCLASSIFIED aperture — clearance
    /// halos, antipads, thermal isolation rings, silkscreen strokes, mask and
    /// paste openings: everything that is not a copper feature CAM asks about.
    fn use(g: *Gx, kind: ApKind, w: f64, h: f64) Error!void {
        return g.useAs(kind, w, h, .none);
    }

    /// Select (defining if needed) an aperture carrying the X2 function
    /// `func` — what the next draw physically IS.
    fn useAs(g: *Gx, kind: ApKind, w: f64, h: f64, func: ApFunc) Error!void {
        const c = try g.aps.code(g.arena, kind, w, if (kind == .c) w else h, func);
        if (c != g.cur) {
            try g.w.print("D{d}*\n", .{c});
            g.cur = c;
        }
    }

    /// The X2 function of a PAD flash on this layer: what the pad is when the
    /// layer is copper, nothing when it is a mask/paste opening. An NPTH hole
    /// is unplated, so its ring is not a component pad.
    fn padFunc(g: *const Gx, pad: geometry.Pad) ApFunc {
        if (!g.copper or pad.npth) return .none;
        return if (pad.thru) .component_pad else .smd_pad;
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

    /// Native circular interpolation (single-quadrant/multi-quadrant G75) from
    /// the same exact three points persisted by the editor and KiCad writer.
    fn arc(g: *Gx, p1: [2]f64, pm: [2]f64, p2: [2]f64) Error!void {
        const circle = outline.arcCircle(.{ .p1 = p1, .pm = pm, .p2 = p2 }) orelse {
            try g.line(p1[0], p1[1], p2[0], p2[1]);
            return;
        };
        const a = g.xy(p1[0], p1[1]);
        const m = g.xy(pm[0], pm[1]);
        const b = g.xy(p2[0], p2[1]);
        const c = g.xy(circle.cx, circle.cy);
        const cross = @as(i128, m[0] - a[0]) * @as(i128, b[1] - m[1]) -
            @as(i128, m[1] - a[1]) * @as(i128, b[0] - m[0]);
        try g.w.writeAll("G75*\n");
        try g.w.print("X{d}Y{d}D02*\n{s}X{d}Y{d}I{d}J{d}D01*\nG01*\n", .{
            a[0], a[1], if (cross < 0) "G02" else "G03", b[0], b[1], c[0] - a[0], c[1] - a[1],
        });
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

/// Fill a closed filleted polygon while preserving its circular corners as
/// native G02/G03 region edges. `poly` contains fine fallback chords; when an
/// exact arc starts at the current point, those owned chords are skipped and
/// one circular interpolation reaches the arc's endpoint instead.
fn regionFilletedPoly(g: *Gx, poly: []const [2]f64, arcs: []const optimizer.BoardArc) Error!void {
    if (poly.len < 3) return;
    try g.w.writeAll("G36*\n");
    const first = g.xy(poly[0][0], poly[0][1]);
    try g.w.print("X{d}Y{d}D02*\n", .{ first[0], first[1] });
    var i: usize = 0;
    while (i + 1 < poly.len) {
        if (arcStartingAt(arcs, poly[i])) |arc| {
            var end_index = i + 1;
            while (end_index < poly.len and !sameOutlinePoint(poly[end_index], arc.p2)) : (end_index += 1) {}
            if (end_index < poly.len) {
                try regionArcTo(g, arc);
                i = end_index;
                continue;
            }
        }
        const point = g.xy(poly[i + 1][0], poly[i + 1][1]);
        try g.w.print("X{d}Y{d}D01*\n", .{ point[0], point[1] });
        i += 1;
    }
    const last = g.xy(poly[poly.len - 1][0], poly[poly.len - 1][1]);
    if (last[0] != first[0] or last[1] != first[1])
        try g.w.print("X{d}Y{d}D01*\n", .{ first[0], first[1] });
    try g.w.writeAll("G37*\n");
}

fn arcStartingAt(arcs: []const optimizer.BoardArc, point: [2]f64) ?optimizer.BoardArc {
    for (arcs) |arc| if (sameOutlinePoint(point, arc.p1)) return arc;
    return null;
}

fn sameOutlinePoint(a: [2]f64, b: [2]f64) bool {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]) <= 1e-7;
}

fn regionArcTo(g: *Gx, arc: optimizer.BoardArc) Error!void {
    const circle = outline.arcCircle(arc) orelse {
        const end = g.xy(arc.p2[0], arc.p2[1]);
        try g.w.print("X{d}Y{d}D01*\n", .{ end[0], end[1] });
        return;
    };
    const a = g.xy(arc.p1[0], arc.p1[1]);
    const m = g.xy(arc.pm[0], arc.pm[1]);
    const b = g.xy(arc.p2[0], arc.p2[1]);
    const c = g.xy(circle.cx, circle.cy);
    const cross = @as(i128, m[0] - a[0]) * @as(i128, b[1] - m[1]) -
        @as(i128, m[1] - a[1]) * @as(i128, b[0] - m[0]);
    try g.w.writeAll("G75*\n");
    try g.w.print("{s}X{d}Y{d}I{d}J{d}D01*\nG01*\n", .{
        if (cross < 0) "G02" else "G03", b[0], b[1], c[0] - a[0], c[1] - a[1],
    });
}

/// mm → integer 4.6-format units (1e-6 mm).
fn mmToUm(mm: f64) i64 {
    return numeric.checkedInt(i64, @round(mm * 1e6)) orelse 0;
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

// spec: export_gerber - a vendor-named backing Gerber follows the board face and clears only matching-side footprint courtyards
test "fabrication backing exports exact filename and side-aware footprint cutouts" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 5, .y = 5, .side = .bottom },
        .{ .ref_des = "U2", .kind = .hub, .hw = 1, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 15, .y = 5, .side = .top },
    };
    const regions = [_]env.FabricationRegion{.board};
    const specs = [_]env.FabricationLayerSpec{.{
        .name = "psb_tesa8854.gbr",
        .side = .bottom,
        .material = "tesa8854",
        .thickness = 0.1,
        .regions = &regions,
        .exclude_footprints = .{ .enabled = true, .clearance = 0.2 },
    }};
    var placement = testPlacement(&parts, &.{});
    placement.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };
    placement.fabrication_layers = &specs;

    const files = try planLayers(arena, placement);
    const file = files[files.len - 1];
    try testing.expect(file.layer == .fabrication);
    try testing.expect(file.layer.fabrication.side == .bottom);
    try testing.expect(file.exact_name);
    try testing.expectEqualStrings("psb_tesa8854.gbr", file.suffix);

    var out: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&out.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), file.layer, .{ .function = file.function });
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.written(), "G36*")); // board + bottom U1 only
    try testing.expect(std.mem.indexOf(u8, out.written(), "%LPC*%") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "material=tesa8854; thickness=0.100000mm") != null);

    var job: std.Io.Writer.Allocating = .init(arena);
    try writeJobFile(&job.writer, placement, files, "Cyclops-Flex");
    try testing.expect(std.mem.indexOf(u8, job.written(), "\"Path\": \"psb_tesa8854.gbr\"") != null);
    try testing.expect(std.mem.indexOf(u8, job.written(), "\"LayerNumber\": 2") != null);
}

// spec: export_gerber - a seeded pour island enclosed by another component's clearance hole is restored after the clear-polarity pass
test "nested pour islands survive Gerber polarity ordering" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const outer = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 20 }, .{ 0, 20 } };
    const moat = [_][2]f64{ .{ 5, 5 }, .{ 15, 5 }, .{ 15, 15 }, .{ 5, 15 } };
    const island = [_][2]f64{ .{ 7, 7 }, .{ 13, 7 }, .{ 13, 13 }, .{ 7, 13 } };
    // Deliberately put the child first: emission must derive topology from the
    // polygons, not rely on component-labelling order from the fill raster.
    const contours = [_][]const [2]f64{ &island, &outer };
    const no_holes = [_][]const [2]f64{};
    const outer_holes = [_][]const [2]f64{&moat};
    const holes = [_][]const []const [2]f64{ &no_holes, &outer_holes };
    const fill: pour.Fill = .{
        .frame = undefined,
        .labels = &.{},
        .n_comp = contours.len,
        .contours = &contours,
        .holes = &holes,
        .coarsened = false,
    };

    var body: std.Io.Writer.Allocating = .init(arena);
    var aps = Apertures{};
    var g = Gx{ .w = &body.writer, .aps = &aps, .arena = arena, .frame = .{} };
    try writeComputedFill(&g, fill);
    const out = body.written();

    const outer_pos = std.mem.indexOf(u8, out, "X0Y0D02*") orelse return error.OuterContourMissing;
    const clear_pos = std.mem.indexOf(u8, out, "%LPC*%") orelse return error.ClearPolarityMissing;
    const moat_pos = std.mem.indexOf(u8, out, "X5000000Y-5000000D02*") orelse return error.HoleContourMissing;
    const dark_rel = std.mem.indexOf(u8, out[clear_pos..], "%LPD*%") orelse return error.DarkPolarityMissing;
    const dark_pos = clear_pos + dark_rel;
    const island_pos = std.mem.indexOf(u8, out, "X7000000Y-7000000D02*") orelse return error.IslandContourMissing;
    try testing.expect(outer_pos < clear_pos);
    try testing.expect(clear_pos < moat_pos);
    try testing.expect(moat_pos < dark_pos);
    try testing.expect(dark_pos < island_pos);
}

// spec: export_gerber - a solver RF taper is emitted as one swept polygon rather than its centreline chord apertures
test "solver RF chords emit one swept copper region" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const tracks = [_]router.Track{
        .{ .x1 = 1, .y1 = 5, .x2 = 2, .y2 = 5, .layer = 0, .width = 0.15, .net = 0 },
        .{ .x1 = 2, .y1 = 5, .x2 = 4, .y2 = 5.5, .layer = 0, .width = 0.25, .net = 0 },
        // Same net and layer, but not part of the path: this branch must remain.
        .{ .x1 = 2, .y1 = 5, .x2 = 2, .y2 = 6, .layer = 0, .width = 0.4, .net = 0 },
    };
    const samples = [_]@import("placement/rf_path_solver.zig").Sample{
        .{ .at = .{ 1, 5 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 2, 5 }, .s_mm = 1, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 4, 5.5 }, .s_mm = 3.06155, .curvature = 0, .width_mm = 0.3 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const placement = testPlacement(&.{}, &.{});
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&aw.writer, arena, placement, .{ .tracks = &tracks, .rf_paths = &paths }, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    const out = aw.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "G36*"));
    try testing.expect(std.mem.indexOf(u8, out, "C,0.150000*%") == null);
    try testing.expect(std.mem.indexOf(u8, out, "C,0.250000*%") == null);
    try testing.expect(std.mem.indexOf(u8, out, "C,0.400000*%") != null);
}

// spec: export_gerber - a folded RF sweep emits overlapping simple dark regions instead of a self-crossing G36 region
test "a folded RF offset ring emits overlapping simple Gerber regions" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const samples = [_]@import("placement/rf_path_solver.zig").Sample{
        .{ .at = .{ 143.96, 105.45 }, .s_mm = 0, .curvature = 0, .width_mm = 0.56 },
        .{ .at = .{ 144.22, 105.45 }, .s_mm = 0.26, .curvature = 0, .width_mm = 0.56 },
        .{ .at = .{ 144.22, 105.5 }, .s_mm = 0.31, .curvature = 0, .width_mm = 0.56 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const placement = testPlacement(&.{}, &.{});
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&aw.writer, arena, placement, .{ .tracks = &.{}, .rf_paths = &paths }, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, aw.written(), "G36*"));
}

// spec: export_gerber - downstream geometry consumes an RF portal collar as physical copper even when no compact track handle was persisted
test "physical copper lowers an RF-only collar once" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const samples = [_]@import("placement/rf_path_solver.zig").Sample{
        .{ .at = .{ 2, 3 }, .s_mm = 0, .curvature = 0, .width_mm = 0.12 },
        .{ .at = .{ 2.4, 3.1 }, .s_mm = 0.412, .curvature = 0, .width_mm = 0.46 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 7,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 1 },
    }};

    const physical = try physicalCopper(arena, .{ .rf_paths = &paths });
    try testing.expectEqual(@as(usize, 1), physical.tracks.len);
    try testing.expectEqual(@as(i32, 7), physical.tracks[0].net);
    try testing.expectEqual(@as(u8, 1), physical.tracks[0].layer);
    try testing.expectEqual(samples[0].at[0], physical.tracks[0].x1);
    try testing.expectEqual(samples[0].at[1], physical.tracks[0].y1);
    try testing.expectEqual(samples[1].at[0], physical.tracks[0].x2);
    try testing.expectEqual(samples[1].at[1], physical.tracks[0].y2);
    try testing.expectEqual(@as(f64, 0.46), physical.tracks[0].width);
    try testing.expectEqual(@as(usize, 0), physical.rf_paths.len);

    const again = try physicalCopper(arena, physical);
    try testing.expectEqual(physical.tracks.ptr, again.tracks.ptr);
    try testing.expectEqual(physical.tracks.len, again.tracks.len);
}

// spec: export_gerber - every copper Gerber file takes its name and X2 file function from the shared layer table row
test "planLayers copper files come from the shared layer table" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 6 copper layers, planes on In1 (stack 2) and In4 (stack 5).
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 5, .net = "V_3V3" } };
    var p = testPlacement(&.{}, &.{});
    p.rules = .{ .plane_nets = &.{ "GND", "V_3V3" }, .copper_layers = 6, .planes = .{ .declared = &planes } };

    const files = try planLayers(arena, p);
    const table = p.rules.layerTable();
    try testing.expectEqual(@as(usize, 6), table.rows().len);
    for (table.rows(), files[0..table.rows().len]) |*row, file| {
        try testing.expectEqualStrings(row.gerberSuffix(), file.suffix);
        try testing.expectEqualStrings(row.gerberFunction(), file.function);
    }
    // The two declared planes pour; the two plane-free inners carry copper at
    // the routable indices tracks persist (signal 2 and 3).
    try testing.expectEqualStrings("GND", files[1].layer.plane.net.named);
    try testing.expectEqual(@as(u8, 2), files[2].layer.inner_signal.sig);
    try testing.expectEqual(@as(u8, 3), files[3].layer.inner_signal.sig);
    try testing.expectEqualStrings("V_3V3", files[4].layer.plane.net.named);
    try testing.expect(files[5].layer.copper == .bottom);
}

// spec: export_gerber - the mask, paste, silkscreen and profile files take their names and X2 file functions from the shared layer table's technical rows
test "planLayers technical files come from the shared layer table" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var p = testPlacement(&.{}, &.{});
    const gnd = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    p.rules = .{ .plane_nets = &gnd, .copper_layers = 4, .planes = .{ .declared = &planes } };

    // ONE walk of the table produces the whole plan: every fab row, copper and
    // technical alike, is one file with that row's own spellings.
    const files = try planLayers(arena, p);
    const table = p.rules.layerTable();
    try testing.expectEqual(table.fabRows().len, files.len);
    for (table.fabRows(), files) |*row, file| {
        try testing.expectEqualStrings(row.gerberSuffix(), file.suffix);
        try testing.expectEqualStrings(row.gerberFunction(), file.function);
        try testing.expectEqual(row.kind, kindOf(file.layer));
    }

    // …and concretely, the technical tail is the emission order a package has
    // always had, with each row's side carried onto its writer.
    const tech = files[table.stackCount()..];
    try testing.expect(tech[0].layer.mask == .top);
    try testing.expectEqualStrings("F_Mask.gts", tech[0].suffix);
    try testing.expect(tech[1].layer.mask == .bottom);
    try testing.expect(tech[2].layer.paste == .top);
    try testing.expect(tech[3].layer.paste == .bottom);
    try testing.expect(tech[4].layer.silk == .top);
    try testing.expectEqualStrings("F_Silkscreen.gto", tech[4].suffix);
    try testing.expectEqualStrings("Legend,Top", tech[4].function);
    try testing.expect(tech[5].layer.silk == .bottom);
    try testing.expect(tech[6].layer == .edge);
    try testing.expectEqualStrings("Edge_Cuts.gm1", tech[6].suffix);
    try testing.expectEqualStrings("Profile,NP", tech[6].function);
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
    p.rules = .{ .plane_nets = &gnd, .copper_layers = 4, .planes = .{ .declared = &planes } };
    const four = try planLayers(arena, p);
    try testing.expectEqual(@as(usize, 11), four.len);
    try testing.expectEqualStrings("GND", four[1].layer.plane.net.named);
    try testing.expect(four[2].layer == .inner_signal);
    try testing.expectEqual(@as(u8, 3), four[2].layer.inner_signal.index);
    try testing.expectEqual(@as(u8, 2), four[2].layer.inner_signal.sig);
    try testing.expectEqualStrings("In2_Cu.g3", four[2].suffix);
    try testing.expectEqualStrings("Copper,L3,Inr", four[2].function);
}

// spec: export_gerber - the implicit stackup's inner planes pour exactly the nets the router treats as plane-carried
test "the implicit stackup's Gerber planes agree with the router's plane model" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A board with no `(stackup …)`: ground, a wide rail, a narrow rail and a
    // signal. `boardRulesOf` would choose V_3V3 (5 pads); spelled out here so
    // the test states the assignment it is checking rather than deriving it.
    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &pins },
        .{ .name = "V_3V3", .pins = &pins },
        .{ .name = "V_5V0", .pins = pins[0..2] },
        .{ .name = "SPI_SCK", .pins = pins[0..2] },
    };
    var p = testPlacement(&.{}, &nets);
    p.rules.planes.implicit_rail = implicit_plane.dominantRail(&nets);
    try testing.expectEqualStrings("V_3V3", p.rules.planes.implicit_rail.?);

    // THE BAR: for every net, "the router stitches it to a plane" and "some
    // emitted plane file pours it" must be the same answer. A board where the
    // router assumes a plane the Gerbers do not pour is a shipped short.
    const files = try planLayers(arena, p);
    for (nets) |net| {
        var poured = false;
        for (files) |f| {
            if (f.layer != .plane) continue;
            if (planeCarries(f.layer.plane.net, net.name)) poured = true;
        }
        try testing.expectEqual(router.netHasPlane(p, net.name), poured);
    }
    // …and concretely: In1 pours ground, In2 pours the rail, the other rail and
    // the signal are ordinary copper the router has to draw.
    try testing.expect(files[1].layer.plane.net == .ground);
    try testing.expectEqualStrings("V_3V3", files[2].layer.plane.net.named);
    try testing.expect(!router.netHasPlane(p, "V_5V0"));
    try testing.expect(!router.netHasPlane(p, "SPI_SCK"));

    // With no qualifying rail the model is its legacy self: two ground planes,
    // and the rail-less board's every non-ground net stays real copper.
    var legacy = testPlacement(&.{}, nets[0..1]);
    legacy.rules.planes.implicit_rail = implicit_plane.dominantRail(nets[0..1]);
    try testing.expect(legacy.rules.planes.implicit_rail == null);
    const legacy_files = try planLayers(arena, legacy);
    try testing.expect(legacy_files[1].layer.plane.net == .ground);
    try testing.expect(legacy_files[2].layer.plane.net == .ground);
    try testing.expect(!router.netHasPlane(legacy, "V_3V3"));
}

// spec: placement/implicit-plane - a design that declares a `(stackup …)` plants no implicit rail and emits exactly its effective declared planes
test "a declared stackup ignores the implicit rail entirely" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &pins },
        .{ .name = "V_3V3", .pins = &pins },
    };
    var p = testPlacement(&.{}, &nets);
    const gnd = [_][]const u8{"GND"};
    const declared = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    // A stackup is authored, so `boardRulesOf` leaves `implicit_rail` null. Set
    // it anyway: nothing downstream may read it once planes are declared, and
    // that is the guarantee an existing board (barracuda) rests on.
    p.rules = .{
        .plane_nets = &gnd,
        .copper_layers = 4,
        .planes = .{ .declared = &declared, .implicit_rail = "V_3V3" },
    };
    try testing.expect(router.netHasPlane(p, "GND"));
    try testing.expect(!router.netHasPlane(p, "V_3V3"));

    // The emitted stack is the declared one: In1 pours GND, In2 stays a plain
    // routable inner signal layer — no rail plane appears anywhere.
    const files = try planLayers(arena, p);
    for (files) |f| {
        if (f.layer != .plane) continue;
        try testing.expect(!planeCarries(f.layer.plane.net, "V_3V3"));
    }
    try testing.expect(files[2].layer == .inner_signal);
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
    try writeLayer(&aw.writer, arena, placement, .{ .tracks = &tracks, .vias = &vias }, &.{}, export_fab.frameFor(placement), inner, .{ .function = "Copper,L3,Inr" });
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
    try writeLayer(&aw.writer, arena, placement, top_copper, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
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
    try writeLayer(&bw.writer, arena, placement, bot_copper, &.{}, export_fab.frameFor(placement), .{ .copper = .bottom }, .{ .function = "Copper,L4,Bot" });
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
    try writeLayer(&mw.writer, arena, placement, .{ .vias = &vias }, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const mask = mw.written();
    try testing.expect(std.mem.indexOf(u8, mask, "%TF.FilePolarity,Negative*%") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "R,1.100000X0.600000*%") != null); // 0.05/side expansion
    try testing.expect(std.mem.indexOf(u8, mask, "X5000000Y5000000D03*") == null); // via tented

    var pw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&pw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .paste = .top }, .{ .function = "Paste,Top" });
    const paste = pw.written();
    try testing.expect(std.mem.indexOf(u8, paste, "R,1.000000X0.500000*%") != null); // SMD at 1:1
    try testing.expect(std.mem.indexOf(u8, paste, "1.400000") == null); // thru pad has no paste
}

// spec: export_gerber - an IC exposed paddle opens the opposite-face solder mask at the exact EP outline, without the component-side mask margin
test "exposed paddle opens the opposite mask at one to one" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1.5, .y = 0, .w = 0.3, .h = 0.9 },
        .{ .number = "EP", .x = 0, .y = 0, .w = 1.95, .h = 1.95 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});

    var top_writer: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&top_writer.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const top = top_writer.written();
    try testing.expect(std.mem.indexOf(u8, top, "R,2.050000X2.050000*%") != null);
    try testing.expect(std.mem.indexOf(u8, top, "R,0.400000X1.000000*%") != null);

    var bottom_writer: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&bottom_writer.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .bottom }, .{ .function = "Soldermask,Bot" });
    const bottom = bottom_writer.written();
    try testing.expect(std.mem.indexOf(u8, bottom, "R,1.950000X1.950000*%") != null);
    try testing.expect(std.mem.indexOf(u8, bottom, "R,2.050000X2.050000*%") == null);
    try testing.expect(std.mem.indexOf(u8, bottom, "R,0.400000X1.000000*%") == null);
    try testing.expect(std.mem.indexOf(u8, bottom, "X10000000Y5000000D03*") != null);
}

// spec: export_gerber - non-ground outer-face traces and vias remain masked where they cross an opposite-face exposed-paddle window, and a non-ground pour suppresses that window
test "opposite paddle mask window protects non-ground tracks and vias" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "EP", .x = 0, .y = 0, .w = 2, .h = 2 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "SIG", .pins = &.{} },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 8, .y1 = 5, .x2 = 12, .y2 = 5, .layer = 1, .width = 0.2, .net = 1 },
        .{ .x1 = 8, .y1 = 5.5, .x2 = 12, .y2 = 5.5, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{
        .{ .x = 9.5, .y = 4.5, .dia = 0.4, .drill = 0.2, .net = 1 },
        .{ .x = 10.5, .y = 4.5, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    const placement = testPlacement(&parts, &nets);

    var out: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&out.writer, arena, placement, .{ .tracks = &tracks, .vias = &vias }, &.{}, export_fab.frameFor(placement), .{ .mask = .bottom }, .{ .function = "Soldermask,Bot" });
    const mask = out.written();

    try testing.expect(std.mem.indexOf(u8, mask, "R,2.000000X2.000000*%") != null); // exact EP opening
    try testing.expect(std.mem.indexOf(u8, mask, "%LPC*%") != null); // mask restored over SIG copper
    try testing.expect(std.mem.indexOf(u8, mask, "C,0.300000*%") != null); // 0.2 trace + 0.05/side guard
    try testing.expect(std.mem.indexOf(u8, mask, "X8850000Y5000000D02*\nX11150000Y5000000D01*") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "C,0.500000*%") != null); // 0.4 via + 0.05/side guard
    try testing.expect(std.mem.indexOf(u8, mask, "X9500000Y5500000D03*") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "X10500000Y5500000D03*") == null); // GND via remains exposed
    try testing.expect(std.mem.indexOf(u8, mask, "%LPD*%") != null);

    const zone_poly = [_][2]f64{ .{ 9, 4 }, .{ 11, 4 }, .{ 11, 6 }, .{ 9, 6 } };
    const zones = [_]pour.UserZone{.{ .net = "SIG", .layer = 1, .poly = &zone_poly }};
    var poured_writer: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&poured_writer.writer, arena, placement, .{ .zones = &zones }, &.{}, export_fab.frameFor(placement), .{ .mask = .bottom }, .{ .function = "Soldermask,Bot" });
    try testing.expect(std.mem.indexOf(u8, poured_writer.written(), "R,2.000000X2.000000*%") == null);
}

// spec: export_gerber - a pad's own (mask-margin …) sizes its mask opening instead of the board rule, and a no-paste pad gets no stencil aperture
test "a fiducial's pad overrides open the mask and skip the stencil" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // `lib/footprints/fiducial-0p75-2p25.sexp`: a 0.75 mm round target under a
    // 0.75 mm/side mask opening, taking no paste — beside an ordinary pad that
    // declares neither and must keep the board's 0.05 mm margin and its paste.
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.75, .h = 0.75, .shape = "circle", .overrides = .{ .mask_margin = 0.75, .no_paste = true } },
        .{ .number = "2", .x = 3, .y = 0, .w = 1.0, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "FID1", .kind = .passive, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});

    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const mask = mw.written();
    // 0.75 copper + 2×0.75 = 2.25 mm opening — the fiducial's whole point. The
    // board-rule opening (0.75 + 2×0.05 = 0.85) must NOT appear.
    try testing.expect(std.mem.indexOf(u8, mask, "C,2.250000*%") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "C,0.850000*%") == null);
    // The undeclared pad still opens at the board rule (1.0/0.5 + 2×0.05).
    try testing.expect(std.mem.indexOf(u8, mask, "R,1.100000X0.600000*%") != null);

    var pw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&pw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .paste = .top }, .{ .function = "Paste,Top" });
    const paste = pw.written();
    // No aperture and no flash for the no-paste pad; the ordinary pad pastes 1:1.
    try testing.expect(std.mem.indexOf(u8, paste, "0.750000") == null);
    try testing.expect(std.mem.indexOf(u8, paste, "X10000000Y5000000D03*") == null);
    try testing.expect(std.mem.indexOf(u8, paste, "R,1.000000X0.500000*%") != null);
    try testing.expect(std.mem.indexOf(u8, paste, "X13000000Y5000000D03*") != null);
}

// spec: placement/perimeter-fence - Gerber opens at most the authored-width solder-mask band around the exact board outline, clipped to matching outer-face GND pour copper
test "mask opens a perimeter-fence band" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &.{} }};
    var placement = testPlacement(&.{}, &nets);
    const planes = [_]optimizer.PlaneAt{ .{ .index = 1, .net = "GND" }, .{ .index = 2, .net = "GND" } };
    placement.rules.copper_layers = 2;
    placement.rules.plane_nets = &.{"GND"};
    placement.rules.planes.declared = &planes;
    placement.rules.perimeter_fence = .{
        .via_dia = 0.4,
        .via_drill = 0.2,
        .spacing = 1,
        .edge_offset = 0.5,
        .mask_width = 0.7,
    };
    const tracks = [_]router.Track{.{ .x1 = 10, .y1 = 0, .x2 = 10, .y2 = 2, .layer = 0, .width = 0.2, .net = 0 }};
    const vias = [_]router.Via{.{ .x = 12, .y = 0.5, .dia = 0.4, .drill = 0.2, .net = 0 }};
    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, .{ .tracks = &tracks, .vias = &vias }, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const mask = mw.written();
    try testing.expect(std.mem.indexOf(u8, mask, "C,1.400000*%") != null);
    // Same-net GND copper remains inside the exposed GND-pour band.
    try testing.expect(std.mem.indexOf(u8, mask, "X0Y10000000D02*\nX20000000Y10000000D01*") != null);
}

// spec: placement/perimeter-fence - component bodies and courtyards do not interrupt the exposed perimeter mask band
test "perimeter mask band ignores a pad-free component body" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var parts = [_]optimizer.Part{.{
        .ref_des = "J1",
        .kind = .hub,
        .x = 10,
        .y = 0.5,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
    }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &.{} }};
    var placement = testPlacement(&parts, &nets);
    const planes = [_]optimizer.PlaneAt{ .{ .index = 1, .net = "GND" }, .{ .index = 2, .net = "GND" } };
    placement.rules.copper_layers = 2;
    placement.rules.plane_nets = &.{"GND"};
    placement.rules.planes.declared = &planes;
    placement.rules.perimeter_fence = .{
        .via_dia = 0.4,
        .via_drill = 0.2,
        .spacing = 1,
        .edge_offset = 0.5,
        .mask_width = 0.7,
    };
    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const mask = mw.written();
    try testing.expect(std.mem.indexOf(u8, mask, "X0Y10000000D02*\nX20000000Y10000000D01*") != null);
    try testing.expect((try perimeter_fence.maskSegments(arena, placement)).len > 0);
}

// spec: placement/perimeter-fence - each face's perimeter opening retains mask over foreign pads, routed traces, vias, and the matching GND pour's clearance around them, without suppressing otherwise-valid fence sites
test "perimeter mask stays on non-ground copper while fence vias remain independent" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{
        .number = "1",
        .x = -5,
        .y = -4.5,
        .w = 1,
        .h = 0.4,
    }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "J1",
        .kind = .hub,
        .x = 10,
        .y = 5,
        .hw = 0,
        .hh = 0,
        .pads = &pads,
        .fallback = false,
    }};
    const nets = [_]export_kicad.FlatNet{ .{ .name = "GND", .pins = &.{} }, .{ .name = "SIG", .pins = &.{} } };
    var placement = testPlacement(&parts, &nets);
    const planes = [_]optimizer.PlaneAt{ .{ .index = 1, .net = "GND" }, .{ .index = 2, .net = "GND" } };
    placement.rules.copper_layers = 2;
    placement.rules.plane_nets = &.{"GND"};
    placement.rules.planes.declared = &planes;
    placement.rules.perimeter_fence = .{
        .via_dia = 0.4,
        .via_drill = 0.2,
        .spacing = 1,
        .edge_offset = 0.5,
        .mask_width = 0.7,
    };
    const tracks = [_]router.Track{.{
        .x1 = 14,
        .y1 = 0,
        .x2 = 14,
        .y2 = 2,
        .layer = 0,
        .width = 0.2,
        .net = 1,
    }};
    const vias = [_]router.Via{.{ .x = 17, .y = 0.5, .dia = 0.4, .drill = 0.2, .net = 1 }};

    var top_writer: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&top_writer.writer, arena, placement, .{ .tracks = &tracks, .vias = &vias }, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const top = top_writer.written();
    // The pad aperture ends at x=5.55 (0.5 mm copper radius + 0.05 mm mask
    // margin); its nearest perimeter-stroke cap ends at x=5.35, leaving the
    // local 0.2 mm web. The SIG trace carves x=13..15 and the SIG via carves
    // x=15.9..18.1, so neither foreign feature is uncovered by the GND band.
    try testing.expect(std.mem.indexOf(u8, top, "X0Y10000000D02*\nX3550000Y10000000D01*") != null);
    try testing.expect(std.mem.indexOf(u8, top, "X6450000Y10000000D02*\nX13000000Y10000000D01*") != null);
    try testing.expect(std.mem.indexOf(u8, top, "X15000000Y10000000D02*\nX15900000Y10000000D01*") != null);
    try testing.expect(std.mem.indexOf(u8, top, "X18100000Y10000000D02*\nX20000000Y10000000D01*") != null);

    var bottom_writer: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&bottom_writer.writer, arena, placement, .{ .tracks = &tracks, .vias = &vias }, &.{}, export_fab.frameFor(placement), .{ .mask = .bottom }, .{ .function = "Soldermask,Bot" });
    // The top-only pad/track do not affect the bottom. The through via does.
    try testing.expect(std.mem.indexOf(u8, bottom_writer.written(), "X0Y10000000D02*\nX15900000Y10000000D01*") != null);
    try testing.expect(std.mem.indexOf(u8, bottom_writer.written(), "X18100000Y10000000D02*\nX20000000Y10000000D01*") != null);
    try testing.expect(std.mem.indexOf(u8, bottom_writer.written(), "X0Y10000000D02*\nX20000000Y10000000D01*") == null);

    // Fence generation remains a copper/DRC concern, independent of mask gaps.
    const sites = try perimeter_fence.generate(arena, placement);
    try testing.expect(sites.len < 56);
    const shape = try pad_shape.worldShape(arena, parts[0], pads[0]);
    for (sites) |via| {
        const gap = pad_shape.pointDist(shape.x0, shape.y0, shape.x1, shape.y1, shape.poly, via.x, via.y, std.math.inf(f64)) - via.dia / 2;
        try testing.expect(gap >= 0.2 - 1e-9);
    }
}

// spec: placement/perimeter-fence - a face without a declared ground pour matching the fence net has no perimeter mask opening
test "perimeter mask is absent on a face without the matching ground pour" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &.{} }};
    var placement = testPlacement(&.{}, &nets);
    const planes = [_]optimizer.PlaneAt{.{ .index = 1, .net = "GND" }};
    placement.rules.copper_layers = 2;
    placement.rules.plane_nets = &.{"GND"};
    placement.rules.planes.declared = &planes;
    placement.rules.perimeter_fence = .{
        .via_dia = 0.4,
        .via_drill = 0.2,
        .spacing = 1,
        .edge_offset = 0.5,
        .mask_width = 0.7,
    };

    var top_writer: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&top_writer.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    try testing.expect(std.mem.indexOf(u8, top_writer.written(), "C,1.400000*%") != null);

    var bottom_writer: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&bottom_writer.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .bottom }, .{ .function = "Soldermask,Bot" });
    try testing.expect(std.mem.indexOf(u8, bottom_writer.written(), "C,1.400000*%") == null);
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
    try writeLayer(&mw.writer, arena, base, .{}, &.{}, export_fab.frameFor(base), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    try testing.expect(std.mem.indexOf(u8, mw.written(), "R,1.100000X0.600000*%") != null);

    // A (design-rules (mask-margin 0.1)) widens the opening to 0.1/side ⇒
    // 1.200000X0.700000.
    var wide = testPlacement(&parts, &.{});
    wide.rules = .{ .design = .{ .mask = .{ .margin = 0.1, .web = 0.2 } } };
    var ww: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&ww.writer, arena, wide, .{}, &.{}, export_fab.frameFor(wide), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    try testing.expect(std.mem.indexOf(u8, ww.written(), "R,1.200000X0.700000*%") != null);
}

// spec: export_gerber - pad openings separated by a positive web below mask-web are merged across that web instead of producing a mask-sliver DRC warning
test "mask output removes a sub-minimum web between pad openings" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 10.55, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    var out: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&out.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const mask = out.written();
    // Two 0.5 mm-tall openings leave 0.05 mm of mask between them. The extra
    // 0.5 mm round stroke crosses that complete web, merging the apertures.
    try testing.expect(std.mem.indexOf(u8, mask, "%ADD11C,0.500000*%") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, mask, "D01*"));

    parts[1].x = 10.6; // opening gap = 0.1 mm, exactly the retained-web floor.
    const legal = testPlacement(&parts, &.{});
    var legal_out: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&legal_out.writer, arena, legal, .{}, &.{}, export_fab.frameFor(legal), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, legal_out.written(), "D01*"));
}

/// Render one face's mask for the RF relief tests: `rules` are index-aligned
/// with `nets`, `copper` is the routed copper under test.
fn reliefMaskSide(
    arena: std.mem.Allocator,
    parts: []optimizer.Part,
    nets: []const export_kicad.FlatNet,
    rules: []const optimizer.NetRule,
    copper: Copper,
    side: optimizer.Side,
) ![]const u8 {
    var placement = testPlacement(parts, nets);
    placement.rules.net = rules;
    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, copper, &.{}, export_fab.frameFor(placement), .{ .mask = side }, .{ .function = if (side == .top) "Soldermask,Top" else "Soldermask,Bot" });
    return mw.written();
}

fn reliefMask(
    arena: std.mem.Allocator,
    parts: []optimizer.Part,
    nets: []const export_kicad.FlatNet,
    rules: []const optimizer.NetRule,
    copper: Copper,
) ![]const u8 {
    return reliefMaskSide(arena, parts, nets, rules, copper, .top);
}

// spec: export_gerber - a relieved max-freq net opens solder mask only with layer polygons, never via flashes
test "max-freq mask relief emits polygons and no via flashes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = [_]export_kicad.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "SIG", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } },
        .{},
    };
    const tracks = [_]router.Track{
        .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }, // relieved
        .{ .x1 = 2, .y1 = 8, .x2 = 8, .y2 = 8, .layer = 0, .width = 0.2, .net = 1 }, // stays tented
    };
    const vias = [_]router.Via{
        .{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }, // inside top relief
        .{ .x = 5, .y = 3, .dia = 0.4, .drill = 0.2, .net = 0 }, // same RF net, outside relief
    };
    const copper: Copper = .{ .tracks = &tracks, .vias = &vias };
    const mask = try reliefMask(arena, &.{}, &nets, &rules, copper);

    // The RF trace and its connected transition antipad are closed regions,
    // never via flashes. The trace boundary is 1.554 mm wide because the class
    // is a fence target; the distant RF via creates no third region.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, mask, "G36*"));
    try testing.expect(std.mem.indexOf(u8, mask, "X2000000Y4223000D02*") != null);
    // The unclassed track never opens (its y-up start (2,2) is absent).
    try testing.expect(std.mem.indexOf(u8, mask, "X2000000Y2000000D02*") == null);
    // Neither via creates a flash aperture: the first is exposed because the
    // connected transition generated an ordinary polygon; the second remains
    // tented because no relief polygon reaches it.
    try testing.expect(std.mem.indexOf(u8, mask, "C,0.500000*%") == null);
    try testing.expect(std.mem.indexOf(u8, mask, "X5000000Y5000000D03*") == null);
    try testing.expect(std.mem.indexOf(u8, mask, "X5000000Y7000000D03*") == null);
    // The same plated barrel remains tented on the opposite face.
    const bottom = try reliefMaskSide(arena, &.{}, &nets, &rules, copper, .bottom);
    try testing.expect(std.mem.indexOf(u8, bottom, "X5000000Y5000000D03*") == null);
}

// spec: export_gerber - a solver-authored pad taper remains mask-covered while the following uniform RF trace opens without sampled-width stair steps
test "solver RF pad taper stays masked in the fabrication layer" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = [_]export_kicad.FlatNet{.{ .name = "RF", .pins = &.{} }};
    const rules = [_]optimizer.NetRule{.{ .class = .{ .name = "rf" }, .rf = .{ .mask_relief_mm = 0.2 } }};
    const samples = [_]@import("placement/rf_path_solver.zig").Sample{
        .{ .at = .{ 2, 5 }, .s_mm = 0, .curvature = 0, .width_mm = 1.2 },
        .{ .at = .{ 5, 5 }, .s_mm = 3, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 8, 5 }, .s_mm = 6, .curvature = 0, .width_mm = 0.2 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const mask = try reliefMask(arena, &.{}, &nets, &rules, .{ .rf_paths = &paths });

    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, mask, "G36*"));
    try testing.expect(std.mem.indexOf(u8, mask, "X5000000") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "X2000000") == null);
}

// spec: export_gerber - mask relief restores a local pad-shaped web and then reopens the pad without interrupting the exposed trace
test "continuous mask relief restores a local pad island" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "RF", .pins = &.{} }};
    const rules = [_]optimizer.NetRule{.{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } }};
    const tracks = [_]router.Track{
        .{ .x1 = 2, .y1 = 5, .x2 = 10, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
    };
    const mask = try reliefMask(arena, &parts, &nets, &rules, .{ .tracks = &tracks });

    // The centreline dam still ends the relief at x=9.35. A clear-polarity
    // 1.3 x 0.8 mm copy then restores exactly the pad opening plus one 0.1 mm
    // web; dark polarity reopens the ordinary 1.1 x 0.6 mm pad aperture.
    try testing.expect(std.mem.indexOf(u8, mask, "G36*") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "X9350000Y") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "%LPC*%") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "R,1.300000X0.800000*%") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "%LPD*%") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "R,1.500000X1.000000*%") == null);
    try testing.expect(std.mem.indexOf(u8, mask, "R,1.100000X0.600000*%") != null); // pad opening
}

test "nearby pad island leaves the RF trace relief continuous" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "2", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C101", .kind = .passive, .hw = 0.25, .hh = 0.25, .pads = &pads, .fallback = false, .x = 5, .y = 5.6 },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "RF", .pins = &.{} }};
    const rules = [_]optimizer.NetRule{.{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .mask_relief_mm = 0.3 } }};
    const tracks = [_]router.Track{.{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const mask = try reliefMask(arena, &parts, &nets, &rules, .{ .tracks = &tracks });

    // The single region still runs from x=2 through x=8. Only the local
    // 0.8 mm pad-shaped protector is clear, followed by the 0.6 mm aperture.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, mask, "G36*"));
    try testing.expect(std.mem.indexOf(u8, mask, "X2000000Y4600000D02*") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "X8000000Y") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "%LPC*%") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "R,0.800000X0.800000*%") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "%LPD*%") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "R,0.600000X0.600000*%") != null);
}

// spec: export_gerber - mask-relief pad-dam terminations use the authored corner fillet in the fabrication layer
test "mask relief writes the authored terminal fillet" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "RF", .pins = &.{} }};
    const rules = [_]optimizer.NetRule{.{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9 } }};
    const tracks = [_]router.Track{.{ .x1 = 2, .y1 = 5, .x2 = 10, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    var placement = testPlacement(&parts, &nets);
    placement.rules.net = &rules;
    placement.rules.design.mask.relief_corner_radius = 0.2;
    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, .{ .tracks = &tracks }, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const mask = mw.written();

    // The centreline dam transition is x=9.35. Its 0.777 mm half
    // opening is pulled in by the authored 0.2 mm fillet at the vertical cap:
    // world y=5.577 becomes y-up 4.423 in the Gerber frame.
    try testing.expect(std.mem.indexOf(u8, mask, "G36*") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "G02") != null or std.mem.indexOf(u8, mask, "G03") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "X9350000Y4423000") != null);
}

// spec: export_gerber - fence vias never emit solder-mask apertures; the widened RF polygon alone exposes overlapping copper
test "fence vias rely only on the widened relief polygon" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = [_]export_kicad.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .fence = .{ .declared = true } } },
        .{},
    };
    const tracks = [_]router.Track{
        .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
    };
    // One GND via inside the fence row (0.5 mm off the centreline), one far away.
    const vias = [_]router.Via{
        .{ .x = 5, .y = 5.5, .dia = 0.4, .drill = 0.2, .net = 1 },
        .{ .x = 15, .y = 9, .dia = 0.4, .drill = 0.2, .net = 1 },
    };
    const mask = try reliefMask(arena, &.{}, &nets, &rules, .{ .tracks = &tracks, .vias = &vias });

    try testing.expect(std.mem.indexOf(u8, mask, "G36*") != null);
    // Neither the near nor distant via is flashed into the mask. The widened
    // top polygon geometrically covers the near one's copper.
    try testing.expect(std.mem.indexOf(u8, mask, "X5000000Y4500000D03*") == null);
    try testing.expect(std.mem.indexOf(u8, mask, "X15000000Y1000000D03*") == null);
    const bottom = try reliefMaskSide(arena, &.{}, &nets, &rules, .{ .tracks = &tracks, .vias = &vias }, .bottom);
    try testing.expect(std.mem.indexOf(u8, bottom, "X5000000Y4500000D03*") == null);
}

// spec: export_gerber - (mask-relief 0) keeps a max-freq net tented and an authored pullback opts in a class without max-freq
test "mask-relief zero tents and a positive pullback opts in" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const nets = [_]export_kicad.FlatNet{
        .{ .name = "RF", .pins = &.{} },
        .{ .name = "IF", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        // (max-freq 12G) (mask-relief 0): explicitly tented despite the default.
        .{ .class = .{ .name = "rf" }, .rf = .{ .max_freq_hz = 12e9, .mask_relief_mm = 0 } },
        // No (max-freq …), authored (mask-relief 0.1): opted in at 0.1/side.
        .{ .class = .{ .name = "if" }, .rf = .{ .mask_relief_mm = 0.1 } },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 8, .x2 = 8, .y2 = 8, .layer = 0, .width = 0.2, .net = 1 },
    };
    const mask = try reliefMask(arena, &.{}, &nets, &rules, .{ .tracks = &tracks });

    // The zeroed max-freq net stays tented — its y-up centreline never appears.
    try testing.expect(std.mem.indexOf(u8, mask, "X2000000Y5000000D02*") == null);
    // The opted-in net ships as one closed region, not a circular-aperture
    // stroke: its boundary straddles the y-up centreline (y=2) by half the
    // 0.2 + 2×0.1 opening, so the two long edges land at y=1.8 and y=2.2.
    try testing.expect(std.mem.indexOf(u8, mask, "G36*") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "C,0.400000*%") == null);
    try testing.expect(std.mem.indexOf(u8, mask, "X2000000Y1800000D02*\nX8000000Y1800000D01*") != null);
    try testing.expect(std.mem.indexOf(u8, mask, "X8000000Y2200000D01*\nX2000000Y2200000D01*") != null);

    // With no relieved net at all, the mask carries no clear-polarity pass —
    // the pre-relief output stays byte-identical.
    const plain_rules = [_]optimizer.NetRule{ .{}, .{} };
    const plain = try reliefMask(arena, &.{}, &nets, &plain_rules, .{ .tracks = &tracks });
    try testing.expect(std.mem.indexOf(u8, plain, "%LPC*%") == null);
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
    var placement = testPlacement(&parts, &nets);
    const rules = [_]optimizer.NetRule{
        .{},
        .{ .class = .{ .name = "rf-50" }, .clearance = 0.127, .rf = .{
            .impedance = .{ .ohms = 50 },
        } },
    };
    placement.rules.net = &rules;
    placement.rules.physical = .{ .board_thickness = 1.6, .stack = .{ .layers = 4, .board_mm = 1.6 } };
    const vias = [_]router.Via{
        .{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }, // GND via — connects
        .{ .x = 6, .y = 5, .dia = 0.4, .drill = 0.2, .net = 1 }, // VIN via — antipad
    };

    var aw: std.Io.Writer.Allocating = .init(arena);
    const inner: Layer = .{ .plane = .{ .index = 2, .net = .ground } };
    try writeLayer(&aw.writer, arena, placement, .{ .vias = &vias }, &.{}, export_fab.frameFor(placement), inner, .{ .function = "Copper,L2,Inr" });
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
    const expected_via_antipad = vias[1].dia + 2 * pour.viaPlaneClearance(placement, vias[1], .ground, placement.rules.design.pour_clearance);
    const aperture = try std.fmt.allocPrint(arena, "C,{d:.6}*%", .{expected_via_antipad});
    try testing.expect(std.mem.indexOf(u8, out, aperture) != null);
    try testing.expect(std.mem.indexOf(u8, out, "X6000000Y5000000D03*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X5000000Y5000000D03*") == null);
}

// spec: placement/implicit-plane - the implicit rail plane pours In2 and antipads the holes it does not carry
test "the implicit In2 plane pours the rail and clears foreign holes" {
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
    const rail_pins = [_]export_kicad.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const gnd_pins = [_]export_kicad.FlatPin{.{ .ref_des = "J1", .pin = "2" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "V_3V3", .pins = &rail_pins },
        .{ .name = "GND", .pins = &gnd_pins },
    };
    var placement = testPlacement(&parts, &nets);
    placement.rules.planes.implicit_rail = "V_3V3";
    // The rail's own stitch via is what SEEDS In2's fill, exactly as ground's
    // stitch vias seed In1 — an inner plane credits no SMD pad on its own.
    const vias = [_]router.Via{
        .{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }, // V_3V3 — connects
        .{ .x = 6, .y = 5, .dia = 0.4, .drill = 0.2, .net = 1 }, // GND — antipad
    };

    const files = try planLayers(arena, placement);
    var aw: std.Io.Writer.Allocating = .init(arena);
    const in2 = files[2]; // In1 = ground, In2 = the rail
    try writeLayer(&aw.writer, arena, placement, .{ .vias = &vias }, &.{}, export_fab.frameFor(placement), in2.layer, .{ .function = in2.function });
    const out = aw.written();

    try testing.expectEqualStrings("In2_Cu.g3", in2.suffix);
    try testing.expect(std.mem.indexOf(u8, out, "pours the supply rail V_3V3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "G36*") != null); // solid rail copper
    try testing.expect(std.mem.indexOf(u8, out, "%LPC*%") != null); // clear pass
    // The GND thru pad (J1.2, world (11,5)) is foreign here — antipadded at
    // drill 0.8 + 2×0.3 — and the GND via at (6,5) is cleared too.
    try testing.expect(std.mem.indexOf(u8, out, "C,1.400000*%") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X11000000Y5000000D03*") != null);
    try testing.expect(std.mem.indexOf(u8, out, "X6000000Y5000000D03*") != null);
    // The rail's OWN via stays solid — no antipad flash at its centre.
    try testing.expect(std.mem.indexOf(u8, out, "X5000000Y5000000D03*") == null);
}

// spec: export_gerber - outer and user pours emit the editor's computed contours and holes without rebuilding bounding-box antipads or adding thermal reliefs to own-net through-hole pads
test "outer pour fills bottom copper and antipads foreign features" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};
    const sig_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 0.5 }};
    const keep_poly = [_][2]f64{ .{ 0.8, -0.4 }, .{ 1.6, -0.4 }, .{ 1.6, 0.4 }, .{ 0.8, 0.4 } };
    const keepouts = [_]geometry.CopperPourKeepout{.{ .side = .front, .poly = &keep_poly }};
    var parts = [_]optimizer.Part{
        // Bottom-side GND cap: its pad must stay SOLID in the pour (no antipad).
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &gnd_pad, .fallback = false, .features = .{ .copper_pour_keepouts = &keepouts }, .x = 4, .y = 4, .side = .bottom },
        // Bottom-side signal part: its pad gets a clear-polarity isolation box.
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.7, .hh = 0.5, .pads = &sig_pad, .fallback = false, .x = 10, .y = 5, .side = .bottom },
    };
    const gnd_pins = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const sig_pins = [_]export_kicad.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &sig_pins },
        .{ .name = "RF", .pins = &.{} },
    };
    var placement = testPlacement(&parts, &nets);
    // (stackup 2 (pour bottom "GND")) — index 2 IS the bottom outer face.
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const rules = [_]optimizer.NetRule{
        .{},
        .{},
        .{ .class = .{ .name = "rf-cpwg-50" }, .clearance = 0.8 },
    };
    placement.rules = .{
        .plane_nets = &gnd_names,
        .copper_layers = 2,
        .planes = .{ .declared = &planes },
        .net = &rules,
    };
    const rf_track = [_]router.Track{.{
        .x1 = 7,
        .y1 = 12,
        .x2 = 13,
        .y2 = 12,
        .layer = 1,
        .width = 0.38,
        .net = 2,
    }};

    var bw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(
        &bw.writer,
        arena,
        placement,
        .{ .tracks = &rf_track },
        &.{},
        export_fab.frameFor(placement),
        .{ .copper = .bottom },
        .{ .function = "Copper,L2,Bot" },
    );
    const bot = bw.written();
    // The solid pour region + a clear-polarity pass, then back to dark.
    try testing.expect(std.mem.indexOf(u8, bot, "G36*") != null);
    try testing.expect(std.mem.indexOf(u8, bot, "%LPC*%") != null);
    try testing.expect(std.mem.indexOf(u8, bot, "%LPD*%") != null);
    // The dark pour and its two surviving computed interior loops are all G36
    // regions. Clearance is no longer reconstructed as Gerber apertures.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, bot, "G36*"));
    // In particular, the foreign pad must NOT regain the old 1.6 × 1.1 mm
    // bounding-box antipad; its clear loop is the pour engine's exact polygon.
    try testing.expect(std.mem.indexOf(u8, bot, "R,1.600000X1.100000*%") == null);
    // The pad flashes themselves (dark) exist for both parts; the GND pad's
    // 0.6 aperture never appears grown (0.6+0.6=1.2 would be its antipad).
    try testing.expect(std.mem.indexOf(u8, bot, "R,0.600000X0.600000*%") != null);
    try testing.expect(std.mem.indexOf(u8, bot, "R,1.200000X1.200000*%") == null);
    // The own-net through-hole pad is a solid pour connection: no 0.3 mm
    // thermal spokes and no 1.2 mm clear isolation ring are emitted.
    try testing.expect(std.mem.indexOf(u8, bot, "C,0.300000*%") == null);
    try testing.expect(std.mem.indexOf(u8, bot, "C,1.200000*%") == null);
    // The old analytic RF corridor aperture is gone too: its net-class gap was
    // already applied while tracing the shared computed fill boundary.
    try testing.expect(std.mem.indexOf(u8, bot, "C,1.980000*%") == null);

    // The un-poured top face keeps plain pads-only copper: no pour region.
    var tw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&tw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    try testing.expect(std.mem.indexOf(u8, tw.written(), "G36*") == null);
}

// spec: export_gerber - an outer-layer user copper pour emits its carved fill as a G36 region on that face
test "writeLayer emits a user copper pour as a top-face region" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A GND SMD pad on the top face, and a hand-drawn GND user pour rectangle
    // enclosing it. The pour must ship as a dark G36 region on F.Cu (top), and
    // NOT on B.Cu (it's a layer-0 zone).
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{.{ .name = "GND", .pins = &pins }};
    const placement = testPlacement(&parts, &nets);

    const poly = [_][2]f64{ .{ 7, 2 }, .{ 13, 2 }, .{ 13, 8 }, .{ 7, 8 } };
    const zones = [_]pour.UserZone{.{ .net = "GND", .layer = 0, .poly = &poly }};
    const copper = Copper{ .zones = &zones };

    var tw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&tw.writer, arena, placement, copper, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    try testing.expect(std.mem.indexOf(u8, tw.written(), "G36*") != null);

    // The same zone is layer 0, so the bottom face carries no region from it.
    var bw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&bw.writer, arena, placement, copper, &.{}, export_fab.frameFor(placement), .{ .copper = .bottom }, .{ .function = "Copper,L4,Bot" });
    try testing.expect(std.mem.indexOf(u8, bw.written(), "G36*") == null);
}

// spec: export_gerber - an inner-layer user copper pour emits its carved fill on that signal layer's Gerber, leaving a declared plane on another layer untouched
test "writeLayer emits an inner-layer user copper pour on In2.Cu, not the In1 plane" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The barracuda stackup: 4-layer, In1 (stack idx 2) = declared GND plane,
    // In2 (stack idx 3) = plane-free inner signal layer (signal index 2). A
    // hand-drawn V_3V3A rail pour on In2.Cu, seeded by a same-net THROUGH-HOLE
    // pad and carving a foreign GND via barrel that reaches the inner layer.
    const rail_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.9, .thru = true, .drill = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &rail_pad, .fallback = false, .x = 10, .y = 5 },
    };
    const rail_pins = [_]export_kicad.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "V_3V3A", .pins = &rail_pins },
        .{ .name = "GND", .pins = &.{} },
    };
    var placement = testPlacement(&parts, &nets);
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    placement.rules = .{ .plane_nets = &gnd_names, .copper_layers = 4, .planes = .{ .declared = &planes } };

    // A foreign GND via inside the drawn square — its barrel reaches In2.Cu.
    const vias = [_]router.Via{.{ .x = 13, .y = 5, .dia = 0.6, .drill = 0.3, .net = 1 }};
    const poly = [_][2]f64{ .{ 7, 2 }, .{ 15, 2 }, .{ 15, 8 }, .{ 7, 8 } };
    const zones = [_]pour.UserZone{.{ .net = "V_3V3A", .layer = 2, .poly = &poly }};
    const copper = Copper{ .vias = &vias, .zones = &zones };

    // In2.Cu is signal index 2 (stack index 3 on this 4-layer stackup).
    const inner: Layer = .{ .inner_signal = .{ .index = 3, .sig = 2 } };
    var iw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&iw.writer, arena, placement, copper, &.{}, export_fab.frameFor(placement), inner, .{ .function = "Copper,L3,Inr" });
    const inner_out = iw.written();
    // The pour ships as a dark G36 region on the inner signal layer.
    try testing.expect(std.mem.indexOf(u8, inner_out, "G36*") != null);
    // The carved foreign via barrel clears the pour.
    try testing.expect(std.mem.indexOf(u8, inner_out, "%LPC*%") != null);
    // User pours keep own-net through-hole pads solidly connected.
    try testing.expect(std.mem.indexOf(u8, inner_out, "C,0.300000*%") == null);

    // The In1 declared GND plane (stack index 2) is untouched by the In2 zone:
    // byte-identical whether or not the design carries the pour (the plane
    // writer ignores `copper.zones`).
    const in1: Layer = .{ .plane = .{ .index = 2, .net = .{ .named = "GND" } } };
    var pz: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&pz.writer, arena, placement, copper, &.{}, export_fab.frameFor(placement), in1, .{ .function = "Copper,L2,Inr" });
    var pnoz: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&pnoz.writer, arena, placement, .{ .vias = &vias }, &.{}, export_fab.frameFor(placement), in1, .{ .function = "Copper,L2,Inr" });
    try testing.expectEqualStrings(pnoz.written(), pz.written());
}

// spec: export_gerber - the fab package's job-file and Excellon drill members are named by the Gerber writer rather than by whatever assembles the archive
test "the package's non-layer member names resolve to the writer's constants" {
    // Exact spellings, because a CAM tool auto-detects a member by its
    // extension: these four strings are what the fab reads, and they are
    // pinned here so a rename cannot quietly change a shipped filename.
    try testing.expectEqualStrings(".gbrjob", job_file_ext);
    try testing.expectEqualStrings("job.gbrjob", job_file_suffix);
    try testing.expectEqualStrings("PTH.drl", plated_drill_suffix);
    try testing.expectEqualStrings("NPTH.drl", non_plated_drill_suffix);
    // The job file's own name is built from the extension, so the two cannot
    // drift apart — the toolbar tooltip splices the extension for the same
    // reason.
    try testing.expect(std.mem.endsWith(u8, job_file_suffix, job_file_ext));
    // Drill members are distinguished by plating class, never by extension.
    try testing.expect(std.mem.endsWith(u8, plated_drill_suffix, ".drl"));
    try testing.expect(std.mem.endsWith(u8, non_plated_drill_suffix, ".drl"));
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

// spec: export_gerber - the job file's LayerNumber counts the copper files the package actually ships, and every entry's polarity is the one its own Gerber carries
test "writeJobFile counts the copper files it was handed" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A six-layer declared stackup: LayerNumber must follow the PLAN, not a
    // second reading of the rules, so it moves with the file set.
    var p = testPlacement(&.{}, &.{});
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 5, .net = "V_3V3" } };
    p.rules = .{ .plane_nets = &.{ "GND", "V_3V3" }, .copper_layers = 6, .planes = .{ .declared = &planes } };
    const files = try planLayers(arena, p);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeJobFile(&aw.writer, p, files, "demo");
    const out = aw.written();

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, out, .{});
    const attrs = parsed.value.object.get("FilesAttributes").?.array;
    try testing.expectEqual(@as(usize, files.len), attrs.items.len);
    const copper: i64 = @intCast(copperFileCount(files));
    try testing.expectEqual(@as(i64, 6), copper);
    try testing.expectEqual(copper, parsed.value.object.get("GeneralSpecs").?.object.get("LayerNumber").?.integer);

    // Each entry's polarity is the one the layer file itself writes — both
    // read the SAME rule, so the two can never disagree.
    for (files, attrs.items) |f, entry| {
        var lw: std.Io.Writer.Allocating = .init(arena);
        try writeLayer(&lw.writer, arena, p, .{}, &.{}, export_fab.frameFor(p), f.layer, .{ .function = f.function });
        const want = try std.fmt.allocPrint(arena, "%TF.FilePolarity,{s}*%", .{entry.object.get("FilePolarity").?.string});
        try testing.expect(std.mem.indexOf(u8, lw.written(), want) != null);
    }
    // …and concretely: exactly the two mask files are negative.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\"FilePolarity\": \"Negative\""));
}

// spec: export_gerber - a layer omits %TF.CreationDate unless the caller supplies one, so the writer stays byte-reproducible and only a served package is stamped
test "creation date is an injected attribute, not a clock read" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = testPlacement(&.{}, &.{});
    const frame = export_fab.frameFor(placement);
    const layer: Layer = .{ .copper = .top };

    // No stamp (the CLI / golden-test path): the attribute is absent, and two
    // runs are byte-identical.
    var a: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&a.writer, arena, placement, .{}, &.{}, frame, layer, .{ .function = "Copper,L1,Top" });
    var b: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&b.writer, arena, placement, .{}, &.{}, frame, layer, .{ .function = "Copper,L1,Top" });
    try testing.expect(std.mem.indexOf(u8, a.written(), "%TF.CreationDate") == null);
    try testing.expectEqualStrings(a.written(), b.written());

    // Stamped (the served-package path): ISO 8601 with an explicit zone, right
    // after the generation software and before the file function.
    const stamp = try creationDate(arena, 1_700_000_000);
    try testing.expectEqualStrings("2023-11-14T22:13:20+00:00", stamp);
    const attr = "%TF.CreationDate,2023-11-14T22:13:20+00:00*%\n";
    var c: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&c.writer, arena, placement, .{}, &.{}, frame, layer, .{ .function = "Copper,L1,Top", .created = stamp });
    const out = c.written();
    const head = "%TF.GenerationSoftware,netlisp,netlisp,1*%\n";
    try testing.expect(std.mem.startsWith(u8, out, head ++ attr ++ "%TF.FileFunction,Copper,L1,Top*%\n"));
    // …and the stamp is the ONLY difference from the unstamped file.
    const spliced = try std.mem.concat(arena, u8, &.{ out[0..head.len], out[head.len + attr.len ..] });
    try testing.expectEqualStrings(a.written(), spliced);
}

// spec: export_gerber - copper apertures carry their X2 %TA.AperFunction (SMD pad, component pad, via land, conductor) and the profile is classified, while openings and clearances stay unclassified
test "apertures declare what they draw" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1, .y = 0, .w = 1.0, .h = 0.5 },
        .{ .number = "2", .x = 1, .y = 0, .w = 1.4, .h = 1.4, .shape = "circle", .thru = true, .drill = 0.9 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    const frame = export_fab.frameFor(placement);
    // A track and a via land of the SAME 0.4 mm circle: two functions, so two
    // apertures — one D-code cannot carry both.
    const tracks = [_]router.Track{.{ .x1 = 9, .y1 = 5, .x2 = 12, .y2 = 5, .layer = 0, .width = 0.4, .net = 0 }};
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};

    var cw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&cw.writer, arena, placement, .{ .tracks = &tracks, .vias = &vias }, &.{}, frame, .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    const cu = cw.written();
    try testing.expect(std.mem.indexOf(u8, cu, "%TA.AperFunction,SMDPad,CuDef*%\n%ADD10R,1.100000X0.600000*%") == null);
    try testing.expect(std.mem.indexOf(u8, cu, "%TA.AperFunction,SMDPad,CuDef*%\n%ADD10R,1.000000X0.500000*%\n%TD*%") != null);
    try testing.expect(std.mem.indexOf(u8, cu, "%TA.AperFunction,ComponentPad*%\n%ADD11C,1.400000*%\n%TD*%") != null);
    try testing.expect(std.mem.indexOf(u8, cu, "%TA.AperFunction,Conductor*%\n%ADD12C,0.400000*%\n%TD*%") != null);
    try testing.expect(std.mem.indexOf(u8, cu, "%TA.AperFunction,ViaPad*%\n%ADD13C,0.400000*%\n%TD*%") != null);

    // The board profile is classified too.
    var ew: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&ew.writer, arena, placement, .{}, &.{}, frame, .edge, .{ .function = "Profile,NP" });
    try testing.expect(std.mem.indexOf(u8, ew.written(), "%TA.AperFunction,Profile*%\n%ADD10C,0.100000*%\n%TD*%") != null);

    // A mask OPENING is not a pad and a silk stroke is not copper: neither
    // carries an aperture function at all.
    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, .{}, &.{}, frame, .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    try testing.expect(std.mem.indexOf(u8, mw.written(), "%TA.") == null);
    try testing.expect(std.mem.indexOf(u8, mw.written(), "R,1.100000X0.600000*%") != null);
    var sw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&sw.writer, arena, placement, .{}, &.{}, frame, .{ .silk = .top }, .{ .function = "Legend,Top" });
    try testing.expect(std.mem.indexOf(u8, sw.written(), "%TA.") == null);
}

// spec: export_gerber - the edge layer closes the board outline; silk exports authored footprint artwork without synthesizing component ref-des text
test "edge closes the outline and silk omits synthetic ref-des" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const silk = [_]geometry.SilkLine{.{ .x1 = -1, .y1 = -1, .x2 = 1, .y2 = -1 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .features = .{ .silk_lines = &silk }, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});

    var ew: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&ew.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .edge, .{ .function = "Profile,NP" });
    const edge = ew.written();
    try testing.expect(std.mem.indexOf(u8, edge, "C,0.100000*%") != null);
    // All four outline corners appear ((0,0)→(20,10) in the y-up frame).
    try testing.expect(std.mem.indexOf(u8, edge, "X0Y10000000D02*") != null);
    try testing.expect(std.mem.indexOf(u8, edge, "X20000000Y0D01*") != null);

    var sw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&sw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .silk = .top }, .{ .function = "Legend,Top" });
    const silk_out = sw.written();
    try testing.expect(std.mem.indexOf(u8, silk_out, "C,0.150000*%") != null);
    // The footprint silk line at world y=4 → y-up 6.
    try testing.expect(std.mem.indexOf(u8, silk_out, "X9000000Y6000000D02*\nX11000000Y6000000D01*") != null);
    // The part's "U1" ref-des is metadata, not authored footprint artwork:
    // the only draw is the one explicit silk line and no glyph flashes appear.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, silk_out, "D01*"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, silk_out, "D03*"));
}

// Regression: a Barracuda-style 0.26 mm footprint pin-one ring is suppressed
// only in board artwork and replaced by one exact 0.3 mm filled Gerber flash.
test "silk replaces a small footprint pin-one ring with a uniform dot" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1 }};
    const circles = [_]geometry.SilkCircle{.{ .cx = -1, .cy = 0, .r = 0.13 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 2,
        .hh = 2,
        .pads = &pads,
        .fallback = false,
        .features = .{ .silk_circles = &circles },
        .x = 10,
        .y = 5,
    }};
    const placement = testPlacement(&parts, &.{});
    var sw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&sw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .silk = .top }, .{ .function = "Legend,Top" });
    const out = sw.written();
    try testing.expect(std.mem.indexOf(u8, out, "C,0.300000*%") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "D03*"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "D01*"));
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
    try writeLayer(&ew.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .edge, .{ .function = "Profile,NP" });
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

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    // A top-side "T" at world (10,5) is exactly two continuous vector strokes:
    // one top bar and one stem.
    const texts = [_]font.BoardText{
        .{ .x = 10, .y = 5, .size = 1.05, .text = "T", .bottom = false },
        .{ .x = 3, .y = 3, .size = 1.05, .text = "B", .bottom = true }, // wrong side
    };

    var tw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&tw.writer, arena, placement, .{}, &texts, export_fab.frameFor(placement), .{ .silk = .top }, .{ .function = "Legend,Top" });
    const out = tw.written();
    // The bottom "B" and metadata-only "U1" are absent from this layer.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "D01*"));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "D03*"));

    // The same "B" on the BOTTOM silk layer does render (and mirrors); the top
    // "T" is filtered off the bottom layer, so "B"'s own strokes are all that show.
    var bw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&bw.writer, arena, placement, .{}, &texts, export_fab.frameFor(placement), .{ .silk = .bottom }, .{ .function = "Legend,Bot" });
    const bout = bw.written();
    try testing.expect(std.mem.count(u8, bout, "D01*") >= 8);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, bout, "D03*"));
}

// spec: export_gerber - both silk faces and the fabrication-ID search share one silkscreen solve, and a prepared plan writes byte-identical silk
test "a prepared silk plan writes the same silk as solving per file" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1, .y = 0, .w = 1.0, .h = 0.5 },
        .{ .number = "2", .x = 1, .y = 0, .w = 1.0, .h = 0.5 },
        .{ .number = "3", .x = 1, .y = 2, .w = 1.0, .h = 0.5 },
        .{ .number = "4", .x = -1, .y = 2, .w = 1.0, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    const texts = [_]font.BoardText{.{ .x = 3, .y = 8, .size = 1.05, .text = "REV A", .bottom = false }};
    const frame = export_fab.frameFor(placement);

    // The one solve a package writer does up front...
    const plan = try planSilk(arena, placement, .{}, &texts);
    // ...which must carry real geometry, or the comparison below proves nothing.
    try testing.expect(plan.pin_one_markers.len > 0);

    // ...prints byte-for-byte what each file would have solved for itself.
    for ([_]optimizer.Side{ .top, .bottom }) |side| {
        var alone: std.Io.Writer.Allocating = .init(arena);
        try writeLayer(&alone.writer, arena, placement, .{}, &texts, frame, .{ .silk = side }, .{ .function = "Legend" });
        var shared: std.Io.Writer.Allocating = .init(arena);
        try writeLayer(&shared.writer, arena, placement, .{}, &texts, frame, .{ .silk = side }, .{ .function = "Legend", .silk = &plan });
        try testing.expectEqualStrings(alone.written(), shared.written());
    }
}

// spec: export_gerber - fabricated silkscreen text uses scalable single-line vector glyphs with independent stroke thickness and one consistent cap height for capitals and digits
test "fabricated text uses vector paths without bitmap flashes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = testPlacement(&.{}, &.{});
    const texts = [_]font.BoardText{.{ .x = 10, .y = 5, .size = 1.0, .text = "A" }};

    var sw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&sw.writer, arena, placement, .{}, &texts, export_fab.frameFor(placement), .{ .silk = .top }, .{ .function = "Legend,Top" });
    const out = sw.written();
    // "A" includes diagonals and a crossbar, all drawn with the independent
    // 0.15 mm circular aperture. Raster text would have emitted D03 flashes.
    try testing.expect(std.mem.indexOf(u8, out, "C,0.150000*%") != null);
    try testing.expect(std.mem.count(u8, out, "D01*") >= 3);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "D03*"));
}

test "sub-circuit annotation is emitted only on the main IC silk side" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = [_]optimizer.Part{.{
        .ref_des = "buck/U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
        .x = 5,
        .y = 5,
        .side = .bottom,
    }};
    var placement = testPlacement(&parts, &.{});
    placement.board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 };

    var top: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&top.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .silk = .top }, .{ .function = "Legend,Top" });
    try testing.expect(std.mem.indexOf(u8, top.written(), "D01*") == null);

    var bottom: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&bottom.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .silk = .bottom }, .{ .function = "Legend,Bot" });
    // Eight L-arm strokes plus the vector name make this substantially more
    // than a footprint-only empty silk layer.
    try testing.expect(std.mem.count(u8, bottom.written(), "D01*") >= 8);
}

// spec: export_gerber - silkscreen text scales with its nominal size (2x size gives 2x glyph extent)
test "board text extent scales with nominal size" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});

    // Measure the x-span of the vector "H" strokes at 1× vs 2× nominal size.
    // A larger em produces a proportionally wider glyph, so the span doubles.
    const span = struct {
        fn measure(a2: std.mem.Allocator, pl: optimizer.Placement, size: f64) !f64 {
            const ts = [_]font.BoardText{.{ .x = 10, .y = 5, .size = size, .text = "H" }};
            var wbuf: std.Io.Writer.Allocating = .init(a2);
            try writeLayer(&wbuf.writer, a2, pl, .{}, &ts, export_fab.frameFor(pl), .{ .silk = .top }, .{ .function = "Legend,Top" });
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
    // 2× nominal size → 2× x-extent while the aperture width stays fixed.
    const ratio = s2 / s1;
    try testing.expect(ratio > 1.9 and ratio < 2.1);
}

// spec: export_gerber - a roundrect pad emits its rounded outline as a G36 region while a plain rect stays an R aperture
test "roundrect pads emit as rounded regions, plain rects as apertures" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -2, .y = 0, .w = 1.0, .h = 0.6, .shape = "roundrect", .overrides = .{ .rratio = 0.25 } },
        .{ .number = "2", .x = 2, .y = 0, .w = 1.0, .h = 0.6, .shape = "rect" },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 3, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&aw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    const out = aw.written();
    // Exactly one region (the roundrect); the plain rect stays a 1.0×0.6 R aperture.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "G36*"));
    try testing.expect(std.mem.indexOf(u8, out, "R,1.000000X0.600000*%") != null);
}

// spec: export_gerber - a custom polygon pad's mask opening dilates its original fill with a round boundary stroke by the mask margin, preserving concave notches without self-intersecting offset rings
test "custom pad mask opening dilates its copper outline" {
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
    try writeLayer(&cw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    const copper = cw.written();

    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const mask = mw.written();

    // Copper is one exact region. Mask keeps that same region and adds four
    // closed boundary legs with a 0.1 mm circular aperture: 0.05 mm growth on
    // every side, with round joins supplied by the Gerber stroke itself.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, copper, "G36*"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, mask, "G36*"));
    try testing.expect(std.mem.indexOf(u8, copper, "C,0.100000*%") == null);
    try testing.expect(std.mem.indexOf(u8, mask, "C,0.100000*%") != null);
    try testing.expectEqual(@as(usize, 5), std.mem.count(u8, mask, "D02*"));
    try testing.expectEqual(@as(usize, 8), std.mem.count(u8, mask, "D01*"));
}

// Regression fixture for TPSM84-style concave custom-pad outlines.
test "concave custom pad mask preserves its source region" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const poly = [_][2]f64{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 0 }, .{ 0, 0 }, .{ 0, 1 }, .{ -1, 1 } };
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 2, .h = 2, .shape = "custom", .poly = &poly },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    var cw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&cw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    var mw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&mw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .mask = .top }, .{ .function = "Soldermask,Top" });
    const copper = cw.written();
    const mask = mw.written();
    const copper_start = std.mem.indexOf(u8, copper, "G36*").?;
    const copper_end = std.mem.indexOfPos(u8, copper, copper_start, "G37*").?;
    const mask_start = std.mem.indexOf(u8, mask, "G36*").?;
    const mask_end = std.mem.indexOfPos(u8, mask, mask_start, "G37*").?;

    // The concave G36 contour is byte-identical to copper, so no generated
    // offset ring can cross its notch. Six round boundary legs own the margin.
    try testing.expectEqualStrings(copper[copper_start..copper_end], mask[mask_start..mask_end]);
    try testing.expect(std.mem.indexOf(u8, mask, "C,0.100000*%") != null);
    try testing.expectEqual(@as(usize, 7), std.mem.count(u8, mask, "D02*"));
    try testing.expectEqual(@as(usize, 12), std.mem.count(u8, mask, "D01*"));
}

// spec: export_gerber - custom polygon pad copper and mask preserve every authored outline vertex in Gerber while placement collision math may simplify a private copy
test "custom pad Gerber retains authored straight and rounded contour vertices" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Dense collinear points followed by a finely authored rounded transition:
    // collision math may collapse these, but the fabrication contour may not.
    const poly = [_][2]f64{
        .{ 0, 0 },     .{ 0.25, 0 },      .{ 0.5, 0 },       .{ 0.75, 0 },
        .{ 1, 0 },     .{ 1.038, 0.008 }, .{ 1.071, 0.029 }, .{ 1.092, 0.062 },
        .{ 1.1, 0.1 }, .{ 1.1, 1 },       .{ 0, 1 },         .{ 0, 0 },
    };
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0.5, .y = 0.5, .w = 1.1, .h = 1, .shape = "custom", .poly = &poly },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const collision = try pad_shape.worldShape(arena, parts[0], pads[0]);
    try testing.expect(collision.poly.len < poly.len);

    const placement = testPlacement(&parts, &.{});
    var cw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&cw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    const copper = cw.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, copper, "G36*"));
    try testing.expectEqual(poly.len - 1, std.mem.count(u8, copper, "D01*"));
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
    try writeLayer(&aw.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
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
    placement.rules = .{ .plane_nets = &.{}, .copper_layers = 2, .physical = .{ .board_thickness = 0.8 } };
    files = try planLayers(arena, placement);
    var tw: std.Io.Writer.Allocating = .init(arena);
    try writeJobFile(&tw.writer, placement, files, "demo");
    try testing.expect(std.mem.indexOf(u8, tw.written(), "\"BoardThickness\": 0.8") != null);
}

test "padRegion sweeps a roundrect top-right corner arc outward" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const pad = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 10, .h = 10, .shape = "roundrect", .overrides = .{ .rratio = 0.25 } };
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

// spec: export_gerber - copper and board-outline arcs use native G02/G03 interpolation instead of chord-only output
test "native arcs emit circular Gerber interpolation" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var placement = testPlacement(&.{}, &.{});
    const square = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 0, 10 } };
    const radii = [_]f64{ 2, 2, 2, 2 };
    const fillet = try outline.filletPath(arena, &square, &radii, 0.01);
    placement.board_poly = fillet.poly;
    placement.board_arcs = fillet.arcs;

    const copper_arc = router.Arc{ .p1 = .{ 2, 5 }, .pm = .{ 3, 4 }, .p2 = .{ 4, 5 }, .layer = 0, .width = 0.25, .net = -1 };
    var cw: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&cw.writer, arena, placement, .{ .arcs = &.{copper_arc} }, &.{}, export_fab.frameFor(placement), .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    try testing.expect(std.mem.indexOf(u8, cw.written(), "G75*") != null);
    try testing.expect(std.mem.indexOf(u8, cw.written(), "G02") != null or std.mem.indexOf(u8, cw.written(), "G03") != null);

    var ew: std.Io.Writer.Allocating = .init(arena);
    try writeLayer(&ew.writer, arena, placement, .{}, &.{}, export_fab.frameFor(placement), .edge, .{ .function = "Profile,NP" });
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, ew.written(), "G75*"));
}

// spec: export_gerber - every job-file Path is the exact archive entry name the package builds for that same file
test "job-file paths are the package's own entry names" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A design slug JLCPCB rejects: the package sanitizes it ONCE, into the
    // prefix, and the job file is handed that same prefix. So the paths it
    // writes and the entries the archive carries agree by construction — the
    // failure this guards is a job file pointing at `rf-switch-eval-F_Cu.gtl`
    // in an archive whose member is `board-F_Cu.gtl`.
    const placement = testPlacement(&.{}, &.{});
    const files = try planLayers(arena, placement);
    const pkg = try packageOf(arena, files, "board");

    var aw: std.Io.Writer.Allocating = .init(arena);
    try writeJobFile(&aw.writer, placement, files, pkg.prefix);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, aw.written(), .{});
    const attrs = parsed.value.object.get("FilesAttributes").?.array;

    try testing.expectEqual(pkg.entries.items.len, attrs.items.len);
    for (attrs.items, pkg.entries.items) |attr, entry| {
        try testing.expectEqualStrings(entry.name, attr.object.get("Path").?.string);
    }
}

/// A package holding one (empty) member per planned file, named exactly as the
/// server names them — the archive side of the job file's `Path` fields.
fn packageOf(arena: std.mem.Allocator, files: []const LayerFile, prefix: []const u8) !export_fab.Package {
    var pkg = export_fab.Package{ .arena = arena, .prefix = prefix };
    for (files) |f| if (f.exact_name) try pkg.addNamed(f.suffix, "") else try pkg.add(f.suffix, "");
    return pkg;
}
