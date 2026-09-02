//! Server-side PNG rendering of a solved PCB placement, so an AI agent (or any
//! HTTP client) can *see* the layout instead of parsing the coordinate JSON the
//! browser viewer consumes. Mirrors the browser renderer (BOARD_JS in
//! `serve/pcb_layout_page.zig`): same world→pixel projection, same element
//! colours, and the SAME PAINT ORDER — `board_passes` below is
//! `render_order.stages` with this renderer's pass bound to each stage, so the
//! image an agent reasons about is stacked exactly like the one the user sees.
//!
//! With `highlight_nets` / `highlight_refs` set, the render enters *focus mode*:
//! the named nets' pads + airwires and the named components glow in an accent
//! colour while everything else is dimmed back, so an agent inspecting one
//! subsystem sees it in the context of the whole board.

const std = @import("std");
const net_name = @import("net_name.zig");
const board_layers = @import("board_layers.zig");
const board_theme = @import("board_theme.zig");
const optimizer = @import("placement/optimizer.zig");
const geometry = @import("placement/geometry.zig");
const router = @import("placement/router.zig");
const pour = @import("placement/pour.zig");
const outline = @import("placement/outline.zig");
const implicit_plane = @import("placement/implicit_plane.zig");
const export_gerber = @import("export_gerber.zig");
const drc = @import("placement/drc.zig");
const raster = @import("raster.zig");
const png = @import("png.zig");
const numeric = @import("numeric.zig");
const export_fab = @import("export_fab.zig");
const env = @import("eval/env.zig");
const font = @import("font5x7.zig");
const silk_font = @import("silk_font.zig");
const subcircuit_silkscreen = @import("subcircuit_silkscreen.zig");
const testpoint_silkscreen = @import("testpoint_silkscreen.zig");
const mask_relief = @import("placement/mask_relief.zig");

/// Replace an RF path's compact editor handles with the conservative physical
/// chords/collars consumed by render-time geometry, and suppress any native
/// arc whose copper is already represented by those samples. The sampled proof
/// remains attached for exact pour geometry; re-lowering first removes every
/// proof-owned chord, so the returned view stays idempotent.
fn physicalRoute(arena: std.mem.Allocator, routed: router.RouteResult) std.mem.Allocator.Error!router.RouteResult {
    if (routed.rf_port_outcomes.len == 0) return routed;
    const copper = try export_gerber.physicalCopper(arena, .{
        .tracks = routed.tracks,
        .vias = routed.vias,
        .arcs = routed.arcs,
        .rf_paths = routed.rf_port_outcomes,
    });
    var physical = routed;
    physical.tracks = copper.tracks;
    physical.arcs = copper.arcs;
    // Retain the sampled proof alongside the private draw chords: pours need
    // its exact swept polygon. Re-lowering stays idempotent because
    // `path_copper.tracks` first removes every chord the proof owns.
    physical.rf_port_outcomes = routed.rf_port_outcomes;
    return physical;
}

fn physicalOptions(arena: std.mem.Allocator, input: Options) std.mem.Allocator.Error!Options {
    var opts = input;
    if (opts.routed) |r| opts.routed = try physicalRoute(arena, r);
    return opts;
}

/// The shown copper's mask relief for the sub-circuit silk pass — empty when
/// nothing is routed, so an unrouted preview pays nothing.
fn silkRelief(arena: std.mem.Allocator, p: optimizer.Placement, routed: ?router.RouteResult) std.mem.Allocator.Error!mask_relief.Relief {
    const r = routed orelse return .{};
    return mask_relief.computeRouted(arena, p, .{
        .tracks = r.tracks,
        .arcs = r.arcs,
        .rf_paths = r.rf_port_outcomes,
    }, r.vias);
}

const Rgb = raster.Rgb;

// ── Theme ──────────────────────────────────────────────────────────────────
// Every colour below is READ from `board_theme.zig`, never re-typed here: the
// PNG and the browser viewer paint one board, so a literal in this file is a
// second opinion about what the image should look like. Each name is the
// theme constant decoded to raster channels; the decode is comptime because
// the theme values are.

const bg = rgbOf(board_theme.background);
const court_col = rgbOf(board_theme.courtyard);
const silk_rgb = rgbOf(board_theme.silk_front);
const silk_bot = rgbOf(board_theme.silk_back);
const pad_col = rgbOf(board_theme.copper_top);
const pad_col_bot = rgbOf(board_theme.copper_bottom);
// A face's pads and its traces are the same copper, so they are one colour.
const track_top = pad_col;
const track_bot = pad_col_bot;
const pad_pth = rgbOf(board_theme.pad_pth);
const pad_npth = rgbOf(board_theme.pad_npth);
const aw_prox = rgbOf(board_theme.airwire_proximity);
const aw_gnd = rgbOf(board_theme.airwire_ground);
const aw_sig = rgbOf(board_theme.ratsnest); // drawn at ~35% alpha
const loop_ret = rgbOf(board_theme.loop_return);
const via_col = rgbOf(board_theme.via);
const via_hole = rgbOf(board_theme.via_hole);
const pad_hole = rgbOf(board_theme.drill_bore);
const drc_col = rgbOf(board_theme.drc);
const accent_rgb = rgbOf(board_theme.focus_accent);
const text_col = rgbOf(board_theme.text);
const text_dim = rgbOf(board_theme.text_dim);
const good_col = rgbOf(board_theme.improvement);
const grid_col = rgbOf(board_theme.grid_dot);
const edge_col = rgbOf(board_theme.edge_cuts);
const keepout_col = rgbOf(board_theme.keepout_region);
// Blame heatmap ramp: cheap (cool) → expensive (hot).
const blame_lo = rgbOf(board_theme.blame_low);
const blame_mid = rgbOf(board_theme.blame_mid);
const blame_hi = rgbOf(board_theme.blame_high);

/// A theme colour as raster channels. The theme owns the ONE hex parser, so
/// this is a plain re-shape — and it works on a runtime string too, which is
/// what lets `trackColor` read a layer-table row instead of a literal.
fn rgbOf(hex: []const u8) Rgb {
    const c = board_theme.channels(hex);
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

/// Trace colour for a routed track's signal layer: the colour the board's own
/// LAYER TABLE gives the physical copper that signal draws on. Reading the row
/// — rather than recomputing "outer face, else inner palette by depth" here —
/// is what keeps the PNG, the blob and the page legend on one palette; the
/// arithmetic lives in `board_layers.stackColor` alone. (KiCad semantics:
/// In2.Cu keeps its colour whether or not In1.Cu is a plane, which is why the
/// key is the stack position and never the signal index.)
pub fn trackColor(rules: optimizer.BoardRules, layer: u8) Rgb {
    const table = rules.layerTable();
    const stack = board_layers.StackIndex.of(rules.signalStackIndex(layer));
    if (table.rowAtStack(stack)) |row| return rgbOf(row.color());
    return rgbOf(board_layers.stackColor(stack, table.stackCount()));
}

/// Flattening tolerance for a routed arc, in FINAL pixels: the largest gap
/// allowed between the true curve and the polyline drawn for it.
const arc_flatten_px: f64 = 0.5;
/// Points one flattened arc may use. A half-pixel tolerance on a board-sized
/// radius stays far under this; the cap bounds the stack buffer.
const arc_max_points: usize = 256;

/// Blank board margin (mm) left on every side of the parts bounding box when a
/// board is framed for viewing. Owned here and reused by the served SVG page so
/// the PNG and the browser viewer frame one board identically — a cross-probe
/// that lands on different pixels in the two surfaces is a bug report.
pub const view_margin_mm: f64 = 2.0;
const min_w: u32 = 400;
const max_w: u32 = 2200;
const max_h: u32 = 2600;
const ss: u32 = 2; // supersample factor for anti-aliasing
const header_h_px: u32 = 46; // title + objective score line (+ focus/compare line)
const legend_h_px: u32 = 22;
const dim_a: f32 = 0.20; // alpha for de-emphasised elements in focus mode

/// Which name labels parts: the flattened ref-des (`C150`), the stable
/// module-local origin name a `(placement …)` spec is written in (`C_BOOT1`),
/// or both (`C150=C_BOOT1`). Parts without an origin name fall back to ref.
pub const NameMode = enum { ref, origin, both };

test "board PNG refdes labels use the globally unique leaf" {
    try std.testing.expectEqualStrings("C17", net_name.leaf("buck_3v3/C17"));
    try std.testing.expectEqualStrings("U2", net_name.leaf("U2"));
}

/// Staging status of a solved layout (from `optimizer.placementDiag()`): which
/// parts the force / `(board …)` edge-dock path left in the band below the board,
/// and which the pin-hug auto-fill pulled back out. Rendered as a header status +
/// red hatch so staged parts never silently pass for a finished layout.
pub const SpecStatus = struct {
    unplaced: []const []const u8,
    /// Parts the pin-hug auto-fill placed — usable positions (drawn with an amber
    /// outline, not the red hatch).
    auto_filled: []const []const u8 = &.{},
};

/// One poured face's precomputed fill, keyed by `side`. The contact sheet
/// computes each side's fill once (`pour.compute`) and threads the slice through
/// every tile's `Options`, so the fill — a pure function of placement + routed
/// copper, identical for the main view and every crop — is not recomputed per
/// tile. Private: only `renderSheet` populates it.
const PrecomputedPour = struct { side: optimizer.Side, fill: pour.Fill };

/// What one render pours its board with, nested because the two are only ever
/// set and read together: both exist so a picture rasters each surface of one
/// lattice ONCE instead of per paint.
pub const PourInputs = struct {
    /// Precomputed pour fills (one per poured side) shared across a contact
    /// sheet's main view + tiles, so `pour.compute` runs once per side per
    /// request instead of once per tile. Null ⇒ each face computes its own fill
    /// (the single-view path). Must be allocated to outlive every tile paint.
    precomputed: ?[]const PrecomputedPour = null,
    /// The board-edge margin field every fill of this board starts from
    /// (`pour.sharedEdgeField`), seeded once by the caller. One image pours the
    /// same lattice a couple of dozen times — both outer faces, every declared
    /// plane, and every hand-drawn zone — and each of those used to re-walk the
    /// outline to seed its own field. Measured on `barracuda`, a plain
    /// `/api/pcb-png` render ran 28 fills; on `barracuda-base`, 8 fills over a
    /// denser board. Null keeps the historical behaviour (each fill seeds its
    /// own), and a field built for a different board is rejected by
    /// `pour.EdgeField.fits` rather than read stale — so this changes latency
    /// only, never a pixel. The renderer never seeds one itself: the caller
    /// already pours this board for its DRC, so seeding it there shares one
    /// walk across both (see `serve/pcb_layout_page.renderDesignPng`).
    base_edge: ?pour.EdgeField = null,
};

/// Render options: output size, focus-mode highlight sets, optional routed
/// copper / DRC overlay, and the caption.
pub const Options = struct {
    /// Requested output width in px (clamped to [MIN_W, MAX_W]; height follows
    /// the board aspect, clamped to MAX_H).
    width: u32 = 1200,
    /// Net names to spotlight (case-insensitive; matched against the full net
    /// name, its tie-collapsed key, and its leaf name).
    highlight_nets: []const []const u8 = &.{},
    /// Ref-designators to spotlight (case-insensitive).
    highlight_refs: []const []const u8 = &.{},
    /// Routed copper to draw, when a route has been computed.
    routed: ?router.RouteResult = null,
    /// DRC violations to mark.
    violations: []const drc.Violation = &.{},
    /// Caption shown top-left (typically the design name).
    title: []const u8 = "",
    /// Optimizer weights — drive the objective score line and blame attribution.
    params: optimizer.Params = .{},
    /// Tint each courtyard by its share of the objective + show a worst-offenders
    /// panel ("what to fix first").
    blame: bool = false,
    /// Label each hot loop with its connection inductance (nH).
    loop_labels: bool = false,
    /// Draw labeled mm dimension leaders on each hot loop's power leg.
    dims: bool = false,
    /// Draw a 1/2/5 mm reference grid with axis ticks.
    grid: bool = false,
    /// A second placement to diff against: ghost outlines + movement arrows +
    /// a Δobjective in the score line.
    compare: ?optimizer.Placement = null,
    /// Part-name labelling: ref-des, spec origin name, or both.
    names: NameMode = .ref,
    /// Label these parts' pads with their net names (case-insensitive ref-des,
    /// sub-block leaf matched like `highlight_refs`; the token "hubs" labels
    /// every hub). How an agent checks "is the FB divider at the FB pad".
    pin_refs: []const []const u8 = &.{},
    /// `(placement …)` spec coverage — header status + red hatch on unplaced.
    spec: ?SpecStatus = null,
    /// Crop the viewport to a window around this part (matched like
    /// `highlight_refs`: ref-des, sub-block leaf, or origin name). The agent's
    /// zoom lens — combine with `pin_refs` for a readable pin-level closeup.
    crop: ?[]const u8 = null,
    /// Crop window radius in mm around the part centre (≤0 ⇒ default 6).
    crop_r: f64 = 6,
    /// Explicit world-space viewport override `[minx,miny,maxx,maxy]` (mm), set
    /// by the serve layer for the `cropnet=` net-bbox zoom lens (a net set's
    /// pads + copper + margin, computed via `cropNetBbox`). Wins over the
    /// whole-board bbox; `crop` (a single part) still wins over this when both
    /// are set.
    view_bbox: ?[4]f64 = null,
    /// Skip the header band and legend — used for contact-sheet tiles.
    bare: bool = false,
    /// Callout overlay: numbered markers + a panel listing the board's worst
    /// problems (hottest loops, longest airwire, staged parts, DRC count).
    critique: bool = false,
    /// Board-level silkscreen text labels (from the shown layout's sidecar).
    /// Drawn in a silk colour at their world anchor + nominal size, so the PNG
    /// and CLI screenshots show the same legend the Gerber emits.
    texts: []const font.BoardText = &.{},
    /// Saved/imported no-silkscreen polygons. Generated sub-circuit names and
    /// corner strokes are suppressed wherever their ink would enter one.
    silk_keepouts: []const subcircuit_silkscreen.Keepout = &.{},
    /// Hand-drawn user copper pours (filled netted outer zones) — drawn under
    /// the parts exactly like a declared pour (translucent fill + rim + "NET
    /// pour" label), so a screenshot shows the same copper the viewer does.
    user_zones: []const pour.UserZone = &.{},
    /// The shared pour inputs of this render (see `PourInputs`).
    pours: PourInputs = .{},
};

/// Render `p` to PNG bytes owned by `alloc`.
pub fn render(alloc: std.mem.Allocator, p: optimizer.Placement, opts: Options) png.Error![]u8 {
    var cv = try renderPhysicalCanvas(alloc, p, opts);
    defer cv.deinit();
    return cv.toPng(alloc);
}

/// Resolve solver RF profiles to their physical copper for one paint. The
/// returned canvas owns its pixels, so the temporary route slices can be freed
/// as soon as the synchronous render completes.
fn renderPhysicalCanvas(alloc: std.mem.Allocator, p: optimizer.Placement, input_opts: Options) png.Error!raster.Canvas {
    var copper_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer copper_arena_state.deinit();
    return renderCanvas(alloc, p, try physicalOptions(copper_arena_state.allocator(), input_opts));
}

/// Render `p` onto a fresh canvas (the body of `render`, reusable by the
/// contact sheet which composites several views into one image).
fn renderCanvas(alloc: std.mem.Allocator, p: optimizer.Placement, opts: Options) png.Error!raster.Canvas {
    // Viewport: the whole board, or a crop window centred on one part.
    var vminx = p.minx;
    var vminy = p.miny;
    var vmaxx = p.maxx;
    var vmaxy = p.maxy;
    if (opts.crop) |cref| {
        // `crop` (a single part window) wins over `view_bbox` (the cropnet lens)
        // when both are set.
        if (try findPartByName(alloc, p, cref)) |pi| {
            const r = if (opts.crop_r > 0) opts.crop_r else 6;
            vminx = p.parts[pi].x - r;
            vmaxx = p.parts[pi].x + r;
            vminy = p.parts[pi].y - r;
            vmaxy = p.parts[pi].y + r;
        }
    } else if (opts.view_bbox) |vb| {
        vminx = vb[0];
        vminy = vb[1];
        vmaxx = vb[2];
        vmaxy = vb[3];
    }
    const cw_mm = @max(vmaxx - vminx, 1.0) + 2 * view_margin_mm;
    const ch_mm = @max(vmaxy - vminy, 1.0) + 2 * view_margin_mm;

    var board_w = std.math.clamp(opts.width, min_w, max_w);
    var scale = @as(f64, @floatFromInt(board_w)) / cw_mm;
    var board_h_f = ch_mm * scale;
    if (board_h_f > max_h) {
        scale = @as(f64, @floatFromInt(max_h)) / ch_mm;
        board_h_f = @floatFromInt(max_h);
        // Guard the narrowing: a NaN/±inf or absurd coordinate leaking out of
        // the placement optimizer would make a bare `@intFromFloat` UB in the
        // runtime-safety-off ReleaseSmall prod build. Fall back to MIN_W, then
        // re-clamp to the valid canvas-width band.
        board_w = std.math.clamp(numeric.checkedInt(u32, @round(cw_mm * scale)) orelse min_w, min_w, max_w);
    }
    // Same guard; board_h is bounded above by MAX_H (board_h_f ≤ MAX_H here),
    // and a non-finite result collapses to a 1px-tall board rather than UB.
    const board_h: u32 = std.math.clamp(numeric.checkedInt(u32, @round(board_h_f)) orelse 1, 1, max_h);

    const focus = opts.highlight_nets.len > 0 or opts.highlight_refs.len > 0;
    const header_h: u32 = if (opts.bare) 0 else header_h_px;
    const legend_h: u32 = if (opts.bare) 0 else legend_h_px;
    const total_h = header_h + board_h + legend_h;
    var cv = try raster.Canvas.init(alloc, board_w, total_h, ss, bg);
    errdefer cv.deinit();

    // Highlight sets: full net names matching any token, and uppercased refs.
    var hot_nets = std.StringHashMapUnmanaged(void).empty;
    defer hot_nets.deinit(alloc);
    var hot_refs = std.StringHashMapUnmanaged(void).empty;
    defer hot_refs.deinit(alloc);
    try buildHighlightSets(alloc, p, opts, &hot_nets, &hot_refs);

    // Pad-label targets and spec-unplaced parts, both uppercased ref sets.
    var pin_set = std.StringHashMapUnmanaged(void).empty;
    defer pin_set.deinit(alloc);
    for (opts.pin_refs) |ref| try pin_set.put(alloc, try upper(alloc, ref), {});
    var unplaced_set = std.StringHashMapUnmanaged(void).empty;
    defer unplaced_set.deinit(alloc);
    var autofill_set = std.StringHashMapUnmanaged(void).empty;
    defer autofill_set.deinit(alloc);
    if (opts.spec) |sp| {
        for (sp.unplaced) |ref| try unplaced_set.put(alloc, try upper(alloc, ref), {});
        for (sp.auto_filled) |ref| try autofill_set.put(alloc, try upper(alloc, ref), {});
    }

    // ref|pad → full net name, so pads/airwires can resolve their net.
    var pad_net = std.StringHashMapUnmanaged([]const u8).empty;
    defer pad_net.deinit(alloc);
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pad_net.put(alloc, key, net.name);
        }
    }

    const caption = if (focus) try buildCaption(alloc, opts) else "";

    // Per-part blame (normalized to the hottest part) for the heatmap tint.
    var blame_norm: []const f64 = &.{};
    if (opts.blame) {
        const raw = try alloc.alloc(f64, p.parts.len);
        optimizer.perPartBlame(p, opts.params, raw);
        var mx: f64 = 0;
        for (raw) |v| mx = @max(mx, v);
        if (mx > 0) for (raw) |*v| {
            v.* /= mx;
        };
        blame_norm = raw;
    }

    // ref_des → index into the compare placement (for ghost/arrow lookup).
    var cmp_idx = std.StringHashMapUnmanaged(usize).empty;
    defer cmp_idx.deinit(alloc);
    if (opts.compare) |c| for (c.parts, 0..) |cp, i| try cmp_idx.put(alloc, cp.ref_des, i);

    // The generated sub-circuit silk avoids mask-relieved bare copper, so the
    // PNG's legs/names match what the Gerber silk actually draws.
    var relief_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer relief_arena_state.deinit();
    const sub_relief = try silkRelief(relief_arena_state.allocator(), p, opts.routed);
    const sub_silk = try subcircuit_silkscreen.collectWithBoardTexts(alloc, p, stagedRefs(opts), opts.silk_keepouts, sub_relief, opts.texts);
    defer subcircuit_silkscreen.deinitCollected(alloc, sub_silk);
    const testpoint_silk = try testpoint_silkscreen.collectWithKeepouts(alloc, p, stagedRefs(opts), opts.silk_keepouts, sub_silk, opts.texts);
    defer testpoint_silkscreen.deinitCollected(alloc, testpoint_silk);
    const pin_one_reserved = try alloc.alloc(font.BoardText, opts.texts.len + testpoint_silk.len);
    defer alloc.free(pin_one_reserved);
    @memcpy(pin_one_reserved[0..opts.texts.len], opts.texts);
    for (testpoint_silk, 0..) |label, i| pin_one_reserved[opts.texts.len + i] = label.text;
    const pin_one_silk = try subcircuit_silkscreen.collectPinOneMarkers(
        alloc,
        p,
        .{
            .excluded_refs = stagedRefs(opts),
            .keepouts = opts.silk_keepouts,
            .relief = sub_relief,
            .annotations = sub_silk,
            .reserved_texts = pin_one_reserved,
            .tracks = if (opts.routed) |r| r.tracks else &.{},
        },
    );
    defer subcircuit_silkscreen.deinitPinOneMarkers(alloc, pin_one_silk);
    var ctx = Ctx{
        .cv = &cv,
        .scale = scale,
        .minx = vminx,
        .miny = vminy,
        .yoff = @floatFromInt(header_h),
        .p = p,
        .focus = focus,
        .caption = caption,
        .hot_nets = &hot_nets,
        .hot_refs = &hot_refs,
        .pad_net = &pad_net,
        .opts = opts,
        .blame_norm = blame_norm,
        .cmp_idx = &cmp_idx,
        .pin_set = &pin_set,
        .unplaced_set = &unplaced_set,
        .autofill_set = &autofill_set,
        .sub_silk = sub_silk,
        .testpoint_silk = testpoint_silk,
        .pin_one_silk = pin_one_silk,
    };

    for (board_passes) |bp| {
        if (bp.run) |run| run(&ctx);
    }
    // Image chrome, not board copper: the caption band and the colour legend
    // frame the board rather than sitting on it, so they are outside the order.
    if (!opts.bare) {
        ctx.drawHeader();
        ctx.drawLegend(opts.routed != null);
    }

    return cv;
}

/// One canonical stage bound to this renderer's pass for it. `run` is null
/// where the PNG has no model for a stage — an explicit hole in the table, so
/// a gap is documented rather than silently missing from the sequence.
const Pass = struct { stage: []const u8, run: ?*const fn (*Ctx) void };

/// THE ORDER, as this renderer implements it: `render_order.stages` name for
/// name (a test below proves it), each bound to the pass that draws it.
///
/// Known residual, deliberately kept: part ref-des labels ride in `overlays`
/// here, where the viewer draws them with the part body. A still image has no
/// zoom and no hover, so its annotations stay legible on top; the viewer can
/// afford to bury a label under a trace because you can move the board.
const board_passes = [_]Pass{
    .{ .stage = "substrate", .run = Ctx.stageSubstrate },
    .{ .stage = "plane_fills", .run = Ctx.stagePlaneFills },
    .{ .stage = "keepouts", .run = Ctx.stageKeepouts },
    .{ .stage = "groups", .run = null }, // no sub-circuit boxes in the PNG
    .{ .stage = "ratsnest", .run = Ctx.stageRatsnest },
    .{ .stage = "clearance", .run = null }, // no clearance halos in the PNG
    .{ .stage = "copper", .run = Ctx.stageCopper },
    .{ .stage = "parts", .run = Ctx.stageParts },
    .{ .stage = "pad_labels", .run = Ctx.drawPinLabels },
    .{ .stage = "footprint_silk", .run = Ctx.drawFootprintSilk },
    .{ .stage = "board_silk", .run = Ctx.drawBoardSilkscreen },
    .{ .stage = "edge_cuts", .run = Ctx.drawBoardOutline },
    .{ .stage = "overlays", .run = Ctx.stageOverlays },
};

/// Staged refs do not belong to the finished sub-circuit footprint envelope.
fn stagedRefs(opts: Options) []const []const u8 {
    return if (opts.spec) |spec| spec.unplaced else &.{};
}

/// Resolve a crop target the way `highlight_refs` matches parts: uppercased
/// ref-des, sub-block leaf, or stable origin name. Null when nothing matches.
fn findPartByName(alloc: std.mem.Allocator, p: optimizer.Placement, name: []const u8) std.mem.Allocator.Error!?usize {
    const want = try upper(alloc, name);
    defer alloc.free(want);
    for (p.parts, 0..) |part, pi| {
        if (eqUpper(part.ref_des, want)) return pi;
        if (std.mem.lastIndexOfScalar(u8, part.ref_des, '/')) |i| {
            if (eqUpper(part.ref_des[i + 1 ..], want)) return pi;
        }
        if (pi < p.instances.len and eqUpper(p.instances[pi].origin_key, want)) return pi;
    }
    return null;
}

/// Default margin (mm) grown around the `cropnet=` net-bbox lens.
pub const cropnet_margin_mm: f64 = 1.5;

/// World-space bounding box `[minx,miny,maxx,maxy]` (mm) of the copper subsystem
/// named by `nets` — every pad on a matching net plus that net's routed copper
/// (tracks + vias, whether restored or freshly routed) — grown by `margin`.
/// Net names match the same way `highlight_nets` does (full name, tie-collapsed
/// key, or leaf, case-insensitive). Powers the `cropnet=` zoom lens: the serve
/// layer sets the result as `Options.view_bbox` after it has placement + copper.
/// Null when no matching pad or copper exists (viewport stays the whole board).
pub fn cropNetBbox(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    routed: ?router.RouteResult,
    nets: []const []const u8,
    margin: f64,
) std.mem.Allocator.Error!?[4]f64 {
    if (nets.len == 0) return null;
    var tokens = try alloc.alloc([]const u8, nets.len);
    defer {
        for (tokens) |t| alloc.free(t);
        alloc.free(tokens);
    }
    for (nets, 0..) |t, i| tokens[i] = try upper(alloc, t);

    // ref_des → part index, so a net's pins resolve to a pad world position.
    var pidx = std.StringHashMapUnmanaged(usize).empty;
    defer pidx.deinit(alloc);
    for (p.parts, 0..) |part, i| try pidx.put(alloc, part.ref_des, i);
    // Matched net indices (into p.nets) — the copper filter keys off these
    // (`Track.net`/`Via.net` carry the flattened-net index).
    var net_hit = std.AutoHashMapUnmanaged(i32, void).empty;
    defer net_hit.deinit(alloc);

    var minx: f64 = std.math.floatMax(f64);
    var miny: f64 = std.math.floatMax(f64);
    var maxx: f64 = -std.math.floatMax(f64);
    var maxy: f64 = -std.math.floatMax(f64);
    var any = false;

    for (p.nets, 0..) |net, ni| {
        var match = false;
        for (tokens) |tok| {
            if (eqUpper(net.name, tok) or eqUpper(netKey(net.name), tok) or eqUpper(shortName(net.name), tok)) {
                match = true;
                break;
            }
        }
        if (!match) continue;
        try net_hit.put(alloc, @intCast(ni), {});
        for (net.pins) |pin| {
            const pi = pidx.get(pin.ref_des) orelse continue;
            const part = p.parts[pi];
            for (part.pads) |pad| {
                if (!std.mem.eql(u8, pad.number, pin.pin)) continue;
                const wp = Ctx.world(part, pad.x, pad.y);
                const hx = @max(pad.w, pad.h) / 2;
                minx = @min(minx, wp[0] - hx);
                maxx = @max(maxx, wp[0] + hx);
                miny = @min(miny, wp[1] - hx);
                maxy = @max(maxy, wp[1] + hx);
                any = true;
            }
        }
    }
    if (routed) |r| {
        var copper_arena_state = std.heap.ArenaAllocator.init(alloc);
        defer copper_arena_state.deinit();
        const physical = try physicalRoute(copper_arena_state.allocator(), r);
        for (physical.tracks) |t| {
            if (!net_hit.contains(t.net)) continue;
            minx = @min(minx, @min(t.x1, t.x2));
            maxx = @max(maxx, @max(t.x1, t.x2));
            miny = @min(miny, @min(t.y1, t.y2));
            maxy = @max(maxy, @max(t.y1, t.y2));
            any = true;
        }
        for (r.vias) |v| {
            if (!net_hit.contains(v.net)) continue;
            const rr = v.dia / 2;
            minx = @min(minx, v.x - rr);
            maxx = @max(maxx, v.x + rr);
            miny = @min(miny, v.y - rr);
            maxy = @max(maxy, v.y + rr);
            any = true;
        }
    }
    if (!any) return null;
    return .{ minx - margin, miny - margin, maxx + margin, maxy + margin };
}

/// Hubs to tile in a contact sheet, biggest first (the parts whose pin
/// neighbourhoods an agent actually needs to inspect).
const sheet_max_tiles: usize = 6;
/// Closeup tiles per contact-sheet row.
const sheet_cols: u32 = 3;

/// Contact sheet: the whole board on top, then per-hub closeups with pad net
/// labels — one image answers both "what's the arrangement" and "what sits at
/// each IC's pins". Tile order is hub courtyard area, biggest first.
pub fn renderSheet(alloc: std.mem.Allocator, p: optimizer.Placement, opts: Options) png.Error![]u8 {
    // Compute each poured side's fill ONCE for the whole request; the main view
    // and every tile paint the same fill instead of recomputing `pour.compute`
    // per tile (up to 14× on a two-sided board). Its arena outlives all paints.
    var pour_arena = std.heap.ArenaAllocator.init(alloc);
    defer pour_arena.deinit();
    const pre = precomputePours(pour_arena.allocator(), p, opts.routed, opts.user_zones, opts.pours.base_edge);

    var main_opts = opts;
    main_opts.crop = null;
    main_opts.pours.precomputed = pre;
    var main_cv = try renderPhysicalCanvas(alloc, p, main_opts);
    defer main_cv.deinit();

    // Biggest hubs first.
    var hubs: std.ArrayList(usize) = .empty;
    defer hubs.deinit(alloc);
    for (p.parts, 0..) |part, pi| {
        if (part.kind != .hub) continue;
        try hubs.append(alloc, pi);
    }
    std.mem.sort(usize, hubs.items, p.parts, hubAreaDesc);
    const ntiles = @min(hubs.items.len, sheet_max_tiles);
    if (ntiles == 0) return main_cv.toPng(alloc);

    const ncols: u32 = @min(@as(u32, @intCast(ntiles)), sheet_cols);
    const tile_w = @max(main_cv.w / ncols, min_w);
    var tiles: std.ArrayList(raster.Canvas) = .empty;
    defer {
        for (tiles.items) |*t| t.deinit();
        tiles.deinit(alloc);
    }
    for (hubs.items[0..ntiles]) |pi| {
        const part = p.parts[pi];
        const pin_one = try alloc.alloc([]const u8, 1);
        pin_one[0] = part.ref_des;
        var tcv = try renderPhysicalCanvas(alloc, p, .{
            .width = tile_w,
            .bare = true,
            .crop = part.ref_des,
            .crop_r = @max(4.0, @max(part.hw, part.hh) + 3.0),
            .pin_refs = pin_one,
            .names = opts.names,
            .params = opts.params,
            .routed = opts.routed,
            .pours = .{ .precomputed = pre, .base_edge = opts.pours.base_edge },
        });
        // Tile caption: which hub this closeup is (ref + origin when distinct).
        var buf: [96]u8 = undefined;
        const origin = if (pi < p.instances.len and p.instances[pi].origin_key.len > 0)
            p.instances[pi].origin_key
        else
            part.ref_des;
        const cap = if (std.mem.eql(u8, origin, part.ref_des))
            part.ref_des
        else
            std.fmt.bufPrint(&buf, "{s}={s}", .{ part.ref_des, origin }) catch part.ref_des;
        tcv.text(4, 3, cap, 11, sheet_cap_col, 1.0, .start);
        try tiles.append(alloc, tcv);
    }

    // Row heights, then composite everything onto one master canvas.
    const nrows = (ntiles + ncols - 1) / ncols;
    var row_h = try alloc.alloc(u32, nrows);
    defer alloc.free(row_h);
    @memset(row_h, 0);
    for (tiles.items, 0..) |t, i| {
        const r = i / ncols;
        row_h[r] = @max(row_h[r], t.h);
    }
    var total_h = main_cv.h;
    for (row_h) |h| total_h += h + sheet_gap_px;
    var master = try raster.Canvas.init(alloc, main_cv.w, total_h, ss, bg);
    defer master.deinit();
    master.blit(&main_cv, 0, 0);
    var y = main_cv.h + sheet_gap_px;
    for (0..nrows) |r| {
        for (0..ncols) |c| {
            const i = r * ncols + c;
            if (i >= tiles.items.len) break;
            master.blit(&tiles.items[i], @as(u32, @intCast(c)) * tile_w, y);
        }
        y += row_h[r] + sheet_gap_px;
    }
    return master.toPng(alloc);
}

/// Compute each poured OUTER side's fill once for a sheet request (lookup is by
/// `side`; inner planes are not cached — a contact sheet's tiles are crops of
/// one board, and the inner fills are recomputed per tile). The fill is
/// a pure function of `p` + `routed` copper, so every view (main + crops) shares
/// it. Arena-owned by the caller (must outlive all tile paints); OOM on a side
/// drops that entry, so `pourFill` falls back to a per-face compute for it.
fn precomputePours(
    arena: std.mem.Allocator,
    p: optimizer.Placement,
    routed: ?router.RouteResult,
    zones: []const pour.UserZone,
    base_edge: ?pour.EdgeField,
) []const PrecomputedPour {
    var out: std.ArrayList(PrecomputedPour) = .empty;
    const copper: pour.Copper = if (routed) |rt| blk: {
        const physical = physicalRoute(arena, rt) catch return &.{};
        break :blk .{ .tracks = physical.tracks, .vias = physical.vias, .arcs = physical.arcs, .rf_paths = rt.rf_port_outcomes };
    } else .{};
    for ([_]optimizer.Side{ .bottom, .top }) |side| {
        const net = p.rules.pourNetOnSide(side) orelse continue;
        var spec = pour.outerSpec(net, side);
        // Ranked user pours on this face clear the declared background pour.
        spec.higher = pour.higherThanDeclared(arena, zones, if (side == .top) 0 else 1, spec.net) catch &.{};
        const fill = pour.computeShared(arena, p, copper, spec, base_edge) catch continue;
        out.append(arena, .{ .side = side, .fill = fill }) catch continue;
    }
    return out.toOwnedSlice(arena) catch &.{};
}

/// Gap (final px) between contact-sheet rows.
const sheet_gap_px: u32 = 4;
/// Tile-caption colour (matches the dim header text).
const sheet_cap_col = raster.Rgb.hex("8b949e");

fn hubAreaDesc(parts: []const optimizer.Part, a: usize, b: usize) bool {
    return parts[a].hw * parts[a].hh > parts[b].hw * parts[b].hh;
}

/// Populate `hot_nets` (full net names matching a `highlight_nets` token) and
/// `hot_refs` (uppercased `highlight_refs`).
fn buildHighlightSets(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    opts: Options,
    hot_nets: *std.StringHashMapUnmanaged(void),
    hot_refs: *std.StringHashMapUnmanaged(void),
) !void {
    for (opts.highlight_refs) |ref| try hot_refs.put(alloc, try upper(alloc, ref), {});
    if (opts.highlight_nets.len == 0) return;
    var tokens = try alloc.alloc([]const u8, opts.highlight_nets.len);
    for (opts.highlight_nets, 0..) |t, i| tokens[i] = try upper(alloc, t);
    for (p.nets) |net| {
        for (tokens) |tok| {
            if (eqUpper(net.name, tok) or eqUpper(netKey(net.name), tok) or eqUpper(shortName(net.name), tok)) {
                try hot_nets.put(alloc, net.name, {});
                break;
            }
        }
    }
}

/// Rendering context: projection + highlight state, with the per-element draw
/// passes as methods so the projection isn't threaded through every call.
const Ctx = struct {
    cv: *raster.Canvas,
    scale: f64,
    minx: f64,
    miny: f64,
    yoff: f32,
    p: optimizer.Placement,
    focus: bool,
    caption: []const u8,
    hot_nets: *std.StringHashMapUnmanaged(void),
    hot_refs: *std.StringHashMapUnmanaged(void),
    pad_net: *std.StringHashMapUnmanaged([]const u8),
    opts: Options,
    /// Per-part objective blame, normalized to [0,1]; empty when blame is off.
    blame_norm: []const f64,
    /// ref_des → index into `opts.compare.?.parts`; empty when no compare layout.
    cmp_idx: *std.StringHashMapUnmanaged(usize),
    /// Uppercased `pin_refs` (pad-net-label targets); empty when none requested.
    pin_set: *std.StringHashMapUnmanaged(void),
    /// Uppercased refs the `(placement …)` spec left unplaced (staging band).
    unplaced_set: *std.StringHashMapUnmanaged(void),
    /// Uppercased refs the pin-hug auto-fill placed (spec-unlisted, amber).
    autofill_set: *std.StringHashMapUnmanaged(void),
    /// Auto-generated corner/name silk for each flattened sub-circuit.
    sub_silk: []const subcircuit_silkscreen.Annotation,
    /// Uniform, collision-aware board-silk labels for physical test points.
    testpoint_silk: []const testpoint_silkscreen.Label,
    /// Uniform, collision-aware filled dots beside detected pin-one pads.
    pin_one_silk: []const subcircuit_silkscreen.PinOneMarker,

    fn xpx(self: *Ctx, mm: f64) f32 {
        return @floatCast((mm - self.minx + view_margin_mm) * self.scale);
    }
    fn ypx(self: *Ctx, mm: f64) f32 {
        return self.yoff + @as(f32, @floatCast((mm - self.miny + view_margin_mm) * self.scale));
    }
    fn len(self: *Ctx, mm: f64) f32 {
        return @floatCast(mm * self.scale);
    }

    /// World point of a footprint-local offset on `part` (matches BOARD_JS wpt).
    /// A bottom-side part mirrors local x before rotating (see optimizer.Side).
    fn world(part: optimizer.Part, lx: f64, ly: f64) [2]f64 {
        const mlx = if (part.side == .bottom) -lx else lx;
        const a = part.rot * std.math.pi / 180.0;
        const c = @cos(a);
        const s = @sin(a);
        return .{ part.x + mlx * c - ly * s, part.y + mlx * s + ly * c };
    }
    /// Pixel point of a footprint-local offset on `part`.
    fn lp(self: *Ctx, part: optimizer.Part, lx: f64, ly: f64) [2]f32 {
        const w = world(part, lx, ly);
        return .{ self.xpx(w[0]), self.ypx(w[1]) };
    }

    /// Rotate a pad-local offset before applying the footprint pose/mirror.
    fn padWorld(part: optimizer.Part, pad: geometry.Pad, dx: f64, dy: f64) [2]f64 {
        const a = pad.rot * std.math.pi / 180.0;
        const c = @cos(a);
        const s = @sin(a);
        return world(part, pad.x + dx * c - dy * s, pad.y + dx * s + dy * c);
    }
    fn padLp(self: *Ctx, part: optimizer.Part, pad: geometry.Pad, dx: f64, dy: f64) [2]f32 {
        const w = padWorld(part, pad, dx, dy);
        return .{ self.xpx(w[0]), self.ypx(w[1]) };
    }

    fn netOf(self: *Ctx, ref: []const u8, pad: []const u8) ?[]const u8 {
        // `pad_net` keys are `ref|pad` built with an unbounded allocPrint, so
        // this buffer must be wide enough to reconstruct any of them — a deep
        // sub-block ref path plus a pad number. Sized to match the `upperInSet`
        // fast path; a longer key would `bufPrint`-overflow → null (part shown
        // dim/unlabeled), never a wrong net.
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}|{s}", .{ ref, pad }) catch return null;
        return self.pad_net.get(key);
    }
    fn netHot(self: *Ctx, name: ?[]const u8) bool {
        const n = name orelse return false;
        return self.hot_nets.contains(n);
    }
    fn refHot(self: *Ctx, ref: []const u8) bool {
        if (upperInSet(self.hot_refs, ref)) return true;
        // Parts inside a sub-block carry a "sub/REF" ref_des; also match the bare
        // leaf so an agent can spotlight "U2" without knowing the prefix.
        if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| {
            if (upperInSet(self.hot_refs, ref[i + 1 ..])) return true;
        }
        return false;
    }
    /// True when `part`'s pads should carry net-name labels: its ref (or
    /// sub-block leaf) is in `pin_refs`, or the "hubs" token selected all hubs.
    fn pinLabeled(self: *Ctx, part: optimizer.Part, pi: usize) bool {
        if (self.pin_set.count() == 0) return false;
        if (part.kind == .hub and self.pin_set.contains("HUBS")) return true;
        if (upperInSet(self.pin_set, part.ref_des)) return true;
        if (std.mem.lastIndexOfScalar(u8, part.ref_des, '/')) |i| {
            if (upperInSet(self.pin_set, part.ref_des[i + 1 ..])) return true;
        }
        // Also answer to the stable origin name — `?pins=U1` should work even
        // after the design renumbered the part to U13 (spec vocabulary).
        if (pi < self.p.instances.len and self.p.instances[pi].origin_key.len > 0) {
            if (upperInSet(self.pin_set, self.p.instances[pi].origin_key)) return true;
        }
        return false;
    }
    fn isUnplaced(self: *Ctx, ref: []const u8) bool {
        if (self.unplaced_set.count() == 0) return false;
        return upperInSet(self.unplaced_set, ref);
    }
    fn isAutoFilled(self: *Ctx, ref: []const u8) bool {
        if (self.autofill_set.count() == 0) return false;
        return upperInSet(self.autofill_set, ref);
    }
    fn isTestPoint(self: *Ctx, index: usize) bool {
        return index < self.p.instances.len and env.isTestPoint(self.p.instances[index].component);
    }
    /// The label `names` mode picks for part `pi`: ref-des, the spec's stable
    /// origin name (fallback ref when a part has none), or `REF=ORIGIN`.
    fn partLabel(self: *Ctx, pi: usize, buf: []u8) []const u8 {
        const ref = self.p.parts[pi].ref_des;
        const display_ref = net_name.leaf(ref);
        if (self.opts.names == .ref) return display_ref;
        const origin = if (pi < self.p.instances.len) self.p.instances[pi].origin_key else "";
        if (origin.len == 0 or std.mem.eql(u8, origin, ref)) return display_ref;
        if (self.opts.names == .origin) return origin;
        return std.fmt.bufPrint(buf, "{s}={s}", .{ display_ref, origin }) catch display_ref;
    }
    /// A part is active (full-strength) when not in focus mode, or when its ref
    /// is spotlighted, or it has a pad on a spotlighted net.
    fn partActive(self: *Ctx, part: optimizer.Part) bool {
        if (!self.focus) return true;
        if (self.refHot(part.ref_des)) return true;
        for (part.pads) |pad| {
            if (self.netHot(self.netOf(part.ref_des, pad.number))) return true;
        }
        return false;
    }

    // ── Canonical stages ───────────────────────────────────────────────
    // One method per `board_passes` entry that needs more than a single
    // existing pass, so the table stays a plain stage→pass binding and every
    // option gate lives with the drawing it gates.

    /// `substrate` — the reference grid, when asked for.
    fn stageSubstrate(self: *Ctx) void {
        if (self.opts.grid) self.drawGrid();
    }

    /// `plane_fills` — every filled copper face, painted from the BOTTOM of the
    /// physical stack upward, so a layer is covered by exactly the layers that
    /// are physically nearer the viewer. One pass over the board's own layer
    /// table (`board_layers`), which is what makes an INNER plane and an inner
    /// user pour drawable at all: they used to be skipped, so a four-layer
    /// board's ground and rail planes — most of its copper — were invisible in
    /// the image an agent reasons about, and an inner pour was dropped rather
    /// than painted on the wrong face.
    /// Authored `(board … (keepout "NAME" …))` regions: a violet wash with the
    /// author's name across it. The derived perimeter band is deliberately NOT
    /// drawn here — it is a function of the outline the viewer already shows,
    /// while an authored region is a fact nothing else on the picture reveals.
    fn stageKeepouts(self: *Ctx) void {
        var arena_state = std.heap.ArenaAllocator.init(self.cv.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const regions = optimizer.boardKeepoutRegions(arena, self.p) catch return;
        for (regions) |region| self.drawKeepoutRegion(arena, region);
    }

    fn drawKeepoutRegion(self: *Ctx, arena: std.mem.Allocator, region: optimizer.BoardKeepoutRegion) void {
        const box = region.corners();
        const ring = self.projectRing(arena, &box) catch return;
        self.cv.fillPoly(ring, keepout_col, 0.16);
        self.cv.strokePath(ring, .closed, self.pw(1), keepout_col, 0.6);
        var buf: [96]u8 = undefined;
        const label = std.fmt.bufPrint(&buf, "{s} · {s}", .{ region.spec.name, @tagName(region.spec.side) }) catch region.spec.name;
        self.cv.text(
            self.xpx(region.rect.minx + region.rect.w / 2),
            self.ypx(region.rect.miny + region.rect.h / 2),
            label,
            self.pw(7),
            keepout_col,
            0.95,
            .middle,
        );
    }

    fn stagePlaneFills(self: *Ctx) void {
        var arena_state = std.heap.ArenaAllocator.init(self.cv.alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const table = self.p.rules.layerTable();
        const rows = table.rows();
        var labels: f32 = 0;
        var i = rows.len;
        while (i > 0) {
            i -= 1;
            self.fillLayer(arena, &rows[i], @intCast(rows.len), &labels);
        }
    }

    /// Every fill living on ONE physical copper layer: its declared pour (an
    /// outer face's `(pour …)` or an inner `(plane …)`), then the hand-drawn
    /// user pours that sit on it.
    fn fillLayer(self: *Ctx, arena: std.mem.Allocator, row: *const board_layers.Row, count: u8, labels: *f32) void {
        // The row's OWN colour — the same string `trackColor` resolves and the
        // blob ships — so a plane on In1 and a track on In1 can never read as
        // two different layers. `board_layers.stackColor` stays the one place
        // the position→colour arithmetic lives.
        const col = rgbOf(row.color());
        const alpha: f32 = if (row.stack.int() == 1) 0.10 else 0.12;
        if (row.isOuter(count)) {
            const side = if (row.stack.int() == 1) optimizer.Side.top else optimizer.Side.bottom;
            if (self.p.rules.pourNetOnSide(side)) |net| {
                self.fillPourFace(arena, side, net, col, alpha);
                self.labelLayerFill(net, "pour", row, labels);
            }
        } else if (row.kind == .plane) {
            const net = row.plane_net orelse "GND";
            // A DECLARED `(plane …)` is authored board content, so its copper is
            // painted: same spec the blob and the Gerber pour it from, with a
            // named plane carrying one net and the ground CLASS spelled by a
            // null net. The legacy IMPLICIT model's two inner planes are an
            // assumption rather than an authored layer — and, being unseeded
            // full-board copper, a wash of them would cover every board that
            // declares no stackup — so those are named in the label only. The
            // viewer draws the same distinction with its per-plane eye, which
            // defaults OFF for exactly this reason.
            if (self.p.rules.declaredStackup()) {
                const spec: pour.LayerSpec = if (row.plane_net) |named|
                    .{ .net = .{ .named = named }, .keep_unseeded = true }
                else
                    .{ .net = .ground, .keep_unseeded = true };
                if (pour.computeShared(arena, self.p, self.shownCopper(), spec, self.opts.pours.base_edge)) |fill| {
                    self.fillContours(arena, fill, col, alpha);
                } else |_| {}
                self.labelLayerFill(net, "plane", row, labels);
            } else {
                self.labelLayerFill(net, "plane (implicit)", row, labels);
            }
        }
        self.fillUserZonesOn(arena, row, col, alpha);
    }

    /// The copper this image draws, as the pour engine's carving input: the
    /// routed tracks/vias when the route overlay is on, nothing otherwise — an
    /// uncarved pour is consistent with a picture showing no routed copper.
    fn shownCopper(self: *Ctx) pour.Copper {
        const rt = self.opts.routed orelse return .{};
        return .{ .tracks = rt.tracks, .vias = rt.vias, .arcs = rt.arcs, .rf_paths = rt.rf_port_outcomes };
    }

    /// "NET <kind> - <layer>", stacked up from the board's bottom edge so every
    /// filled layer gets a legible line naming what its copper is.
    fn labelLayerFill(self: *Ctx, net: []const u8, kind: []const u8, row: *const board_layers.Row, labels: *f32) void {
        const r = export_fab.outlineRect(self.p);
        const col = rgbOf(row.color());
        var buf: [96]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{s} {s} - {s}", .{ net, kind, row.name() }) catch "";
        self.cv.text(
            self.xpx(r.minx) + self.pw(4),
            self.ypx(r.miny + r.h) - self.pw(12) - labels.* * self.pw(11),
            s,
            self.pw(8),
            col,
            0.95,
            .start,
        );
        labels.* += 1;
    }

    /// `parts` — the compare layout's ghost outlines under the live bodies.
    fn stageParts(self: *Ctx) void {
        if (self.opts.compare != null) self.drawCompareGhost();
        self.drawParts();
        if (self.opts.routed) |r| self.drawViaHoles(r);
    }

    /// `ratsnest` — airwires, decoupling loops, their optional dimension
    /// leaders, and the compare layout's movement arrows.
    fn stageRatsnest(self: *Ctx) void {
        self.drawAirwires();
        self.drawLoops();
        if (self.opts.dims) self.drawDims();
        if (self.opts.compare != null) self.drawCompareArrows();
    }

    /// `copper` — the routed tracks and vias, when a route is being shown.
    fn stageCopper(self: *Ctx) void {
        if (self.opts.routed) |r| self.drawRouted(r);
    }

    /// `overlays` — DRC markers, part labels, and the opt-in analysis panels.
    fn stageOverlays(self: *Ctx) void {
        self.drawViolations(self.opts.violations);
        self.drawLabels();
        if (self.opts.critique) self.drawCritique();
        if (self.opts.blame) self.drawBlamePanel();
    }

    /// Part bodies: courtyard, pad copper and drilled bores. BOTTOM-side parts
    /// paint first, so a far-side footprint can never cover a near-side one —
    /// the board is seen from the top. Placement order used to decide that,
    /// which meant a bottom-side cap drawn late erased the pads of the top-side
    /// hub it sits under.
    fn drawParts(self: *Ctx) void {
        for ([_]optimizer.Side{ .bottom, .top }) |side| self.drawPartsOnSide(side);
    }

    fn drawPartsOnSide(self: *Ctx, side: optimizer.Side) void {
        for (self.p.parts, 0..) |part, pi| {
            if (part.side != side) continue;
            const active = self.partActive(part);
            const base_a: f32 = if (active) 1.0 else dim_a;
            // Courtyard (rotated quad about the box centre — offset from the
            // part origin when the library rect is off-origin). KiCad-style:
            // a thin dim magenta outline, NO fill — the part reads from its
            // pads + silk, not a solid body box.
            const court = [_][2]f32{
                self.lp(part, part.ccx - part.hw, part.ccy - part.hh), self.lp(part, part.ccx + part.hw, part.ccy - part.hh),
                self.lp(part, part.ccx + part.hw, part.ccy + part.hh), self.lp(part, part.ccx - part.hw, part.ccy + part.hh),
            };
            // Blame heatmap still tints the fill green→red by objective share.
            if (self.opts.blame and pi < self.blame_norm.len) {
                self.cv.fillPoly(&court, blameColor(self.blame_norm[pi]), base_a);
            }
            self.cv.strokePath(&court, .closed, self.outlineW(active), court_col, base_a * 0.35);
            if (self.focus and active and (self.refHot(part.ref_des))) {
                self.cv.strokePath(&court, .closed, self.outlineW(true) + self.pw(1.5), accent_rgb, 0.9);
            }
            // A part the `(placement …)` spec left unplaced sits in a staging
            // band — cross it out so it never reads as a deliberate placement.
            if (self.isUnplaced(part.ref_des)) {
                self.cv.fillPoly(&court, drc_col, 0.12);
                self.cv.strokePath(&court, .closed, self.outlineW(true), drc_col, 0.9);
                self.cv.line(court[0][0], court[0][1], court[2][0], court[2][1], self.pw(1.0), drc_col, 0.8, .butt);
                self.cv.line(court[1][0], court[1][1], court[3][0], court[3][1], self.pw(1.0), drc_col, 0.8, .butt);
            } else if (self.isAutoFilled(part.ref_des)) {
                // Auto-filled: a usable position the spec doesn't pin — amber
                // outline so the agent can tell authored from solver-chosen.
                self.cv.strokePath(&court, .closed, self.outlineW(true), accent_rgb, 0.75);
            }
            // Footprint silk is NOT drawn here — it paints above the copper,
            // in `drawFootprintSilk`. See that pass for why.
            self.drawPads(part, active);
        }
    }

    /// Footprint silk (footprint-local, rotates with the part) — F.Silk white
    /// on top, B.Silk pink on bottom-side parts — stroked ABOVE the routed
    /// copper, as its own pass.
    ///
    /// Silkscreen ink is physically printed on the finished board, so a trace
    /// never runs over the polarity mark or the body outline of the part
    /// sitting on it. Drawing it inside `drawParts` put it under `drawRouted`,
    /// which erased a footprint's own artwork wherever a route crossed it, and
    /// disagreed with the viewer's WebGPU path (where every canvas adornment
    /// composites above the GPU surface's copper). All three renderers now
    /// paint one silk pass above copper.
    ///
    /// B.Silk paints before F.Silk: the board is seen from the top, so far-side
    /// ink belongs under near-side ink wherever two footprints overlap in X/Y.
    fn drawFootprintSilk(self: *Ctx) void {
        for ([_]optimizer.Side{ .bottom, .top }) |side| {
            for (self.p.parts) |part| {
                if (part.side != side) continue;
                const base_a: f32 = if (self.partActive(part)) 1.0 else dim_a;
                const silk_col = if (part.side == .bottom) silk_bot else silk_rgb;
                for (part.features.silk_lines) |sl| {
                    const a = self.lp(part, sl.x1, sl.y1);
                    const b = self.lp(part, sl.x2, sl.y2);
                    self.cv.line(a[0], a[1], b[0], b[1], self.pw(0.8), silk_col, base_a, .round);
                }
                for (part.features.silk_circles) |sc| {
                    if (subcircuit_silkscreen.isAuthoredPinOneIndicator(sc)) continue;
                    const c = self.lp(part, sc.cx, sc.cy);
                    self.cv.ring(c[0], c[1], @max(self.len(sc.r), self.pw(1)), self.pw(0.8), silk_col, base_a);
                }
            }
        }
    }

    fn drawPads(self: *Ctx, part: optimizer.Part, active: bool) void {
        for (part.pads) |pad| {
            const hot = self.focus and self.netHot(self.netOf(part.ref_des, pad.number));
            // Layer-coloured pads (KiCad): SMD pads in their face's copper
            // colour, plated through-hole pads gold on every layer, NPTH
            // mounting holes as a dim copper-free rim.
            const layer_col = if (pad.drill > 0)
                (if (pad.npth) pad_npth else pad_pth)
            else if (part.side == .bottom) pad_col_bot else pad_col;
            const col = if (hot) accent_rgb else layer_col;
            const a: f32 = if (hot or active) 1.0 else dim_a;
            if (pad.poly.len >= 3) {
                // KiCad custom pads carry full copper outlines (100-200+ pts);
                // a 64-slot stack scratch covers the common case, larger spill
                // to the heap so the polygon is never truncated mid-shape.
                var stack: [64][2]f32 = undefined;
                var pts: [][2]f32 = &stack;
                var heap = false;
                if (pad.poly.len > stack.len) {
                    if (self.cv.alloc.alloc([2]f32, pad.poly.len)) |b| {
                        pts = b;
                        heap = true;
                    } else |_| {}
                }
                defer if (heap) self.cv.alloc.free(pts);
                const n = @min(pad.poly.len, pts.len);
                for (pad.poly[0..n], 0..) |pp, i| pts[i] = self.lp(part, pp[0], pp[1]);
                self.cv.fillPoly(pts[0..n], col, a);
            } else if (std.mem.eql(u8, pad.shape, "circle")) {
                const c = self.lp(part, pad.x, pad.y);
                self.cv.disc(c[0], c[1], self.len(@min(pad.w, pad.h) / 2), col, a);
            } else if (std.mem.eql(u8, pad.shape, "oval")) {
                // A stadium (obround): a round-capped line along the major axis,
                // width = the minor axis — draws the true pill, not a sharp rect.
                if (pad.w >= pad.h) {
                    const e = (pad.w - pad.h) / 2;
                    const a1 = self.padLp(part, pad, -e, 0);
                    const b1 = self.padLp(part, pad, e, 0);
                    self.cv.line(a1[0], a1[1], b1[0], b1[1], self.len(pad.h), col, a, .round);
                } else {
                    const e = (pad.h - pad.w) / 2;
                    const a1 = self.padLp(part, pad, 0, -e);
                    const b1 = self.padLp(part, pad, 0, e);
                    self.cv.line(a1[0], a1[1], b1[0], b1[1], self.len(pad.w), col, a, .round);
                }
            } else {
                const hw = pad.w / 2;
                const hh = pad.h / 2;
                const quad = [_][2]f32{
                    self.padLp(part, pad, -hw, -hh), self.padLp(part, pad, hw, -hh),
                    self.padLp(part, pad, hw, hh),   self.padLp(part, pad, -hw, hh),
                };
                self.cv.fillPoly(&quad, col, a);
            }
            // Drilled bore: punch a board-coloured hole through thru/npth pads so
            // through-hole parts and mounting holes read as holes, not solid
            // copper — an oval drill punches a capsule slot, not a round hole.
            if (pad.drill > 0) {
                if (pad.isSlot()) {
                    const e1 = self.padLp(part, pad, pad.slot_half[0], pad.slot_half[1]);
                    const e2 = self.padLp(part, pad, -pad.slot_half[0], -pad.slot_half[1]);
                    self.cv.line(e1[0], e1[1], e2[0], e2[1], @max(self.len(pad.drill), self.pw(1.2)), pad_hole, a, .round);
                } else {
                    const c = self.lp(part, pad.x, pad.y);
                    const hr = @max(self.len(pad.drill / 2), self.pw(0.6));
                    self.cv.disc(c[0], c[1], hr, pad_hole, a);
                }
            }
        }
    }

    fn drawAirwires(self: *Ctx) void {
        for (self.p.links) |l| {
            // A declared plane/pour satisfies electrical connectivity, but a
            // proximity link is placement intent and must remain visible.
            if (l.kind != .proximity and l.net.len > 0 and self.p.rules.carriesPlane(l.net)) continue;
            const a_pt = self.lp(self.p.parts[l.a], l.ax, l.ay);
            const b_pt = self.lp(self.p.parts[l.b], l.bx, l.by);
            const col = awColor(l.kind);
            const base_w: f64 = if (l.kind == .signal) 0.7 else 1.3;
            // KiCad ratsnest: thin solid white at ~35% alpha; the loop/ground
            // kinds keep their accent colours but stay translucent too.
            var alpha: f32 = if (l.kind == .signal) 0.38 else 0.8;
            var col2 = col;
            var w = base_w;
            if (self.focus) {
                const net = self.netOf(self.p.parts[l.a].ref_des, self.nearestPad(l.a, l.ax, l.ay));
                if (self.netHot(net)) {
                    col2 = accent_rgb;
                    alpha = 1.0;
                    w = 1.6;
                } else {
                    alpha = dim_a * 0.6;
                }
            }
            self.cv.line(a_pt[0], a_pt[1], b_pt[0], b_pt[1], self.pw(w), col2, alpha, .butt);
        }
    }

    /// Pad number on part `pi` whose centre is nearest the footprint-local
    /// offset (lx,ly) — recovers an airwire endpoint's net (links carry only
    /// offsets, not the net name).
    fn nearestPad(self: *Ctx, pi: usize, lx: f64, ly: f64) []const u8 {
        const part = self.p.parts[pi];
        var best: []const u8 = "";
        var best_d: f64 = std.math.floatMax(f64);
        for (part.pads) |pad| {
            const dx = pad.x - lx;
            const dy = pad.y - ly;
            const d = dx * dx + dy * dy;
            if (d < best_d) {
                best_d = d;
                best = pad.number;
            }
        }
        return best;
    }

    fn drawLoops(self: *Ctx) void {
        for (self.p.loops) |L| {
            const cap = self.p.parts[L.cap];
            const hub = self.p.parts[L.hub];
            const cp = self.lp(cap, L.cap_pwr.x, L.cap_pwr.y);
            const cg = self.lp(cap, L.cap_gnd.x, L.cap_gnd.y);
            const pp = self.lp(hub, L.hub_pwr_pin.x, L.hub_pwr_pin.y);
            const gp = self.lp(hub, L.hub_gnd_pin.x, L.hub_gnd_pin.y);
            const dim = self.focus and !(self.partActive(cap) or self.partActive(hub));
            const a: f32 = if (dim) dim_a * 0.6 else 0.9;
            // Power-leg ribbon width grows with the loop's inductance share, so
            // the loops dominating the objective read as the fattest.
            const nh = optimizer.loopNh(self.p.parts, L);
            const w = std.math.clamp(1.0 + nh * 0.7, 1.0, 5.0);
            self.cv.line(cp[0], cp[1], pp[0], pp[1], self.pw(w), aw_prox, a, .butt);
            // L2 ground-return path cap_gnd → cap_pwr → hub_pwr → hub_gnd.
            const ret = [_][2]f32{ cg, cp, pp, gp };
            self.cv.strokePath(&ret, .open, self.pw(1.1), loop_ret, a * 0.85);
            if (self.opts.loop_labels) {
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d:.1}nH", .{nh}) catch "";
                self.cv.text((cp[0] + pp[0]) / 2, (cp[1] + pp[1]) / 2 - self.pw(6), s, self.pw(8), aw_prox, a, .middle);
            }
        }
    }

    /// Routed copper: straight tracks, then the true arcs, then via barrels.
    ///
    /// An arc's copper is present TWICE in a route result — as the arc itself
    /// and as the bounded chords the router keeps for connectivity/clearance —
    /// so the chords an arc owns are dropped here and the arc is stroked as a
    /// real curve. Drawing the chords instead (what this did before) showed an
    /// RF bend as a visible polygon with a lump at every chord join, which is
    /// not the copper the Gerber emits. `export_gerber.arcOwnsTrack` is that
    /// same suppression rule, so the picture and the fab output agree.
    fn drawRouted(self: *Ctx, r: router.RouteResult) void {
        for (r.tracks) |t| {
            if (export_gerber.arcOwnsTrack(r.arcs, t)) continue;
            const col = trackColor(self.p.rules, t.layer);
            self.cv.line(self.xpx(t.x1), self.ypx(t.y1), self.xpx(t.x2), self.ypx(t.y2), @max(self.len(t.width), self.pw(0.6)), col, 0.92, .round);
        }
        for (r.arcs) |a| self.drawArc(a);
        for (r.vias) |v| {
            const c = [_]f32{ self.xpx(v.x), self.ypx(v.y) };
            const rad = @max(self.len(v.dia / 2), self.pw(1.2));
            self.cv.disc(c[0], c[1], rad, via_col, 1.0);
        }
    }

    /// Punch via drills after pad copper. Pads intentionally win over routed
    /// copper, but their fill must not hide a real bore when a via sits inside
    /// a land (via-in-pad). A missing legacy drill keeps the old 45%-of-barrel
    /// visual fallback; saved vias with a drill use their manufactured size.
    fn drawViaHoles(self: *Ctx, r: router.RouteResult) void {
        for (r.vias) |v| {
            const c = [_]f32{ self.xpx(v.x), self.ypx(v.y) };
            const barrel = @max(self.len(v.dia / 2), self.pw(1.2));
            const bore = if (v.drill > 0) self.len(v.drill / 2) else barrel * 0.45;
            self.cv.disc(c[0], c[1], bore, via_hole, 1.0);
        }
    }

    /// Stroke one routed arc as a polyline fine enough that its facets are
    /// under half a pixel — the canvas has no arc primitive, so the curve is
    /// flattened at RENDER resolution rather than at the router's much coarser
    /// connectivity tolerance. A degenerate (collinear) arc falls back to its
    /// chord, which is what its geometry actually is.
    fn drawArc(self: *Ctx, a: router.Arc) void {
        const w = @max(self.len(a.width), self.pw(0.6));
        const col = trackColor(self.p.rules, a.layer);
        const circle = outline.arcCircle(.{ .p1 = a.p1, .pm = a.pm, .p2 = a.p2 }) orelse {
            self.cv.line(self.xpx(a.p1[0]), self.ypx(a.p1[1]), self.xpx(a.p2[0]), self.ypx(a.p2[1]), w, col, 0.92, .round);
            return;
        };
        // Sagitta ≤ arc_flatten_px at this zoom: r(1-cos(θ/2)) ≤ tol ⇒
        // θ ≤ 2·acos(1 - tol/r). Guarded for a radius smaller than the
        // tolerance (the whole arc is then one step) and clamped so a huge
        // radius still gets a few segments.
        const r_px = @max(self.len(circle.radius), 1e-6);
        const step = if (r_px <= arc_flatten_px)
            std.math.pi
        else
            @min(std.math.pi / 2.0, 2 * std.math.acos(1 - arc_flatten_px / r_px));
        const sweep = circle.sweep;
        const n = @max(2, @min(arc_max_points, 1 + @as(usize, @intFromFloat(@ceil(@abs(sweep) / step)))));
        var pts: [arc_max_points][2]f32 = undefined;
        for (0..n) |i| {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n - 1));
            const ang = circle.start_angle + sweep * t;
            pts[i] = .{
                self.xpx(circle.cx + circle.radius * @cos(ang)),
                self.ypx(circle.cy + circle.radius * @sin(ang)),
            };
        }
        self.cv.strokePath(pts[0..n], .open, w, col, 0.92);
    }

    fn drawViolations(self: *Ctx, violations: []const drc.Violation) void {
        for (violations) |v| {
            const c = [_]f32{ self.xpx(v.x), self.ypx(v.y) };
            self.cv.ring(c[0], c[1], self.pw(5), self.pw(1.6), drc_col, 1.0);
        }
    }

    /// Labeled mm dimension leaders on each hot loop's power leg, so distances
    /// are legible without pixel-counting.
    fn drawDims(self: *Ctx) void {
        for (self.p.loops) |L| {
            const cap = self.p.parts[L.cap];
            const hub = self.p.parts[L.hub];
            const cw = world(cap, L.cap_pwr.x, L.cap_pwr.y);
            const hwd = world(hub, L.hub_pwr_pin.x, L.hub_pwr_pin.y);
            const mm = std.math.hypot(cw[0] - hwd[0], cw[1] - hwd[1]);
            const a = [_]f32{ self.xpx(cw[0]), self.ypx(cw[1]) };
            const b = [_]f32{ self.xpx(hwd[0]), self.ypx(hwd[1]) };
            self.cv.line(a[0], a[1], b[0], b[1], self.pw(0.6), text_col, 0.75, .round);
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.2}mm", .{mm}) catch "";
            self.cv.text((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + self.pw(2), s, self.pw(8), text_col, 0.95, .middle);
        }
    }

    /// The board outline with its dimensions, under the parts — the physical
    /// board edge everything must stay inside. Non-rectangular boards (a
    /// drawn polygon / `(corner-radius R)`) stroke the exact polygon; the
    /// dimension label stays the bounding box.
    fn drawBoardOutline(self: *Ctx) void {
        const r = self.p.board_rect orelse return;
        const x0 = self.xpx(r.minx);
        const y0 = self.ypx(r.miny);
        if (self.p.board_poly) |poly| {
            if (poly.len >= 3) {
                // Rounded rects run 36 points, hand-drawn polygons a handful;
                // spill to the heap only for an unusually dense outline.
                var stack: [64][2]f32 = undefined;
                var pts: [][2]f32 = &stack;
                var heap = false;
                if (poly.len > stack.len) {
                    if (self.cv.alloc.alloc([2]f32, poly.len)) |b| {
                        pts = b;
                        heap = true;
                    } else |_| {}
                }
                defer if (heap) self.cv.alloc.free(pts);
                const n = @min(poly.len, pts.len);
                for (poly[0..n], 0..) |pp, i| pts[i] = .{ self.xpx(pp[0]), self.ypx(pp[1]) };
                self.cv.strokePath(pts[0..n], .closed, self.pw(1.4), edge_col, 0.9);
                self.labelBoardDims(r, x0, y0);
                return;
            }
        }
        const x1 = self.xpx(r.minx + r.w);
        const y1 = self.ypx(r.miny + r.h);
        const pts = [_][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 }, .{ x0, y0 } };
        self.cv.strokePath(&pts, .open, self.pw(1.4), edge_col, 0.9);
        self.labelBoardDims(r, x0, y0);
    }

    /// The outline's W×H dimension label at its bbox top-left corner.
    fn labelBoardDims(self: *Ctx, r: optimizer.BoardRect, x0: f32, y0: f32) void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.0}x{d:.0}mm", .{ r.w, r.h }) catch "";
        self.cv.text(x0 + self.pw(4), y0 + self.pw(3), s, self.pw(8), edge_col, 0.9, .start);
    }

    /// The hand-drawn user copper pours living on ONE physical copper layer:
    /// each filled netted zone's COMPUTED fill (carved by the copper this image
    /// draws), painted like a declared pour in that layer's colour with a
    /// "NET pour" label — so a screenshot shows the same user copper the
    /// interactive viewer does. The fill is computed identically to the blob /
    /// Gerber (`pour.zoneLayerSpec`), on an INNER layer as well as an outer
    /// face: a zone's `layer` is a routable signal index, and the board's own
    /// layer table says which physical position that is.
    fn fillUserZonesOn(self: *Ctx, arena: std.mem.Allocator, row: *const board_layers.Row, col: Rgb, alpha: f32) void {
        if (self.opts.user_zones.len == 0) return;
        const sig = row.signal orelse return; // a plane-claimed layer holds no zone
        for (self.opts.user_zones, 0..) |z, zi| {
            if (z.layer != sig.int()) continue;
            var spec = pour.zoneLayerSpec(z.net, pour.sideOfSignal(z.layer), z.layer, z.poly);
            spec.higher = pour.higherPolys(arena, self.opts.user_zones, zi) catch &.{};
            const fill = pour.computeShared(arena, self.p, self.shownCopper(), spec, self.opts.pours.base_edge) catch continue;
            self.fillContours(arena, fill, col, alpha);
            self.labelUserZone(fill, z.net, col);
        }
    }

    /// Every kept contour of one computed fill, antipad holes cut out even-odd.
    /// An OOM skips the paint (the pour label still marks the layer).
    fn fillContours(self: *Ctx, arena: std.mem.Allocator, fill: pour.Fill, col: Rgb, alpha: f32) void {
        for (fill.contours, 0..) |poly, ci| {
            if (poly.len < 3) continue;
            const rings = self.projectRings(arena, poly, fill.holes[ci]) catch return;
            self.cv.fillRings(rings, col, alpha);
        }
    }

    /// "NET pour" at each of a user zone's islands.
    fn labelUserZone(self: *Ctx, fill: pour.Fill, net: []const u8, col: Rgb) void {
        for (fill.contours) |poly| {
            if (poly.len < 3) continue;
            var buf: [96]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{s} pour", .{net}) catch "";
            self.cv.text(self.xpx(poly[0][0]) + self.pw(2), self.ypx(poly[0][1]) - self.pw(2), s, self.pw(7), col, 0.95, .start);
        }
    }

    /// Paint one poured face's computed fill: each kept contour with its
    /// antipad holes cut out even-odd. `arena` is per-request (compute's
    /// output is arena-owned, never individually freed); an OOM skips the
    /// paint — the pour label still marks the face.
    fn fillPourFace(
        self: *Ctx,
        arena: std.mem.Allocator,
        side: optimizer.Side,
        net: []const u8,
        col: Rgb,
        alpha: f32,
    ) void {
        const fill = self.pourFill(arena, side, net) orelse return;
        for (fill.contours, 0..) |poly, ci| {
            if (poly.len < 3) continue;
            const rings = self.projectRings(arena, poly, fill.holes[ci]) catch return;
            self.cv.fillRings(rings, col, alpha);
        }
    }

    /// The poured fill for `side`: the request-precomputed one (contact sheet,
    /// where the identical fill would otherwise be recomputed per tile) or a
    /// fresh `pour.compute` (single view). The compute path carves the same
    /// copper the image draws — routed tracks/vias when the overlay is on, none
    /// otherwise. Null on OOM, which skips the paint (the label still marks the
    /// face).
    fn pourFill(self: *Ctx, arena: std.mem.Allocator, side: optimizer.Side, net: []const u8) ?pour.Fill {
        if (self.opts.pours.precomputed) |pre| {
            for (pre) |pp| if (pp.side == side) return pp.fill;
        }
        const copper: pour.Copper = if (self.opts.routed) |rt| .{ .tracks = rt.tracks, .vias = rt.vias, .arcs = rt.arcs, .rf_paths = rt.rf_port_outcomes } else .{};
        var spec = pour.outerSpec(net, side);
        // Ranked user pours on this face clear the declared background pour.
        spec.higher = pour.higherThanDeclared(arena, self.opts.user_zones, if (side == .top) 0 else 1, spec.net) catch &.{};
        return pour.computeShared(arena, self.p, copper, spec, self.opts.pours.base_edge) catch null;
    }

    /// Project a pour contour + its holes from world mm to final-px rings
    /// (ring 0 = the outer) for the canvas's even-odd fill. Arena-owned.
    fn projectRings(
        self: *Ctx,
        arena: std.mem.Allocator,
        outer: []const [2]f64,
        holes: []const []const [2]f64,
    ) std.mem.Allocator.Error![]const []const [2]f32 {
        const rings = try arena.alloc([]const [2]f32, 1 + holes.len);
        rings[0] = try self.projectRing(arena, outer);
        for (holes, 0..) |h, i| rings[i + 1] = try self.projectRing(arena, h);
        return rings;
    }

    fn projectRing(self: *Ctx, arena: std.mem.Allocator, poly: []const [2]f64) std.mem.Allocator.Error![]const [2]f32 {
        const out = try arena.alloc([2]f32, poly.len);
        for (poly, 0..) |pt, i| out[i] = .{ self.xpx(pt[0]), self.ypx(pt[1]) };
        return out;
    }

    /// A faint 1/2/5 mm reference grid with axis tick labels, under everything.
    fn drawGrid(self: *Ctx) void {
        const step = gridStep(self.p.maxx - self.p.minx, self.p.maxy - self.p.miny);
        const top = self.yoff;
        const bot = @as(f32, @floatFromInt(self.cv.h - legend_h_px));
        const left = self.xpx(self.minx - view_margin_mm);
        const right = self.xpx(self.p.maxx + view_margin_mm);
        var gx = @ceil((self.minx - view_margin_mm) / step) * step;
        while (gx <= self.p.maxx + view_margin_mm + 1e-6) : (gx += step) {
            const px = self.xpx(gx);
            self.cv.line(px, top, px, bot, self.pw(0.4), grid_col, 0.5, .butt);
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.0}", .{gx}) catch "";
            self.cv.text(px, bot - self.pw(9), s, self.pw(7), text_dim, 0.7, .middle);
        }
        var gy = @ceil((self.miny - view_margin_mm) / step) * step;
        while (gy <= self.p.maxy + view_margin_mm + 1e-6) : (gy += step) {
            const py = self.ypx(gy);
            self.cv.line(left, py, right, py, self.pw(0.4), grid_col, 0.5, .butt);
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.0}", .{gy}) catch "";
            self.cv.text(left + self.pw(2), py - self.pw(3), s, self.pw(7), text_dim, 0.7, .start);
        }
    }

    /// Ghost outlines of the compare layout's part positions, under the live one.
    fn drawCompareGhost(self: *Ctx) void {
        const c = self.opts.compare orelse return;
        for (self.p.parts) |part| {
            const idx = self.cmp_idx.get(part.ref_des) orelse continue;
            const old = c.parts[idx];
            const court = [_][2]f32{
                self.lp(old, -old.hw, -old.hh), self.lp(old, old.hw, -old.hh),
                self.lp(old, old.hw, old.hh),   self.lp(old, -old.hw, old.hh),
            };
            self.cv.strokePath(&court, .closed, self.pw(0.8), text_dim, 0.45);
        }
    }

    /// Arrows from each part's compare position to its live position (movement).
    fn drawCompareArrows(self: *Ctx) void {
        const c = self.opts.compare orelse return;
        for (self.p.parts) |part| {
            const idx = self.cmp_idx.get(part.ref_des) orelse continue;
            const old = c.parts[idx];
            if (std.math.hypot(part.x - old.x, part.y - old.y) < 0.05) continue;
            const a = [_]f32{ self.xpx(old.x), self.ypx(old.y) };
            const b = [_]f32{ self.xpx(part.x), self.ypx(part.y) };
            self.cv.line(a[0], a[1], b[0], b[1], self.pw(1.0), accent_rgb, 0.85, .round);
            self.cv.disc(b[0], b[1], self.pw(2.0), accent_rgb, 0.9);
        }
    }

    /// Top-right panel listing the three highest-blame parts ("fix these first").
    /// Callout overlay: numbered markers on the board plus a panel listing the
    /// worst problems in fix-first order — the hottest loops, the longest
    /// airwire, anything staged, and the DRC count. The "what should I improve"
    /// answer drawn directly on the image an agent is already looking at.
    fn drawCritique(self: *Ctx) void {
        var lines_buf: [6][64]u8 = undefined;
        var lines: [6][]const u8 = undefined;
        var marks: [6]?[2]f32 = @splat(null);
        var n: usize = 0;

        // Top-3 hot loops by inductance.
        var li = [_]usize{ 0, 0, 0 };
        var lv = [_]f64{ -1, -1, -1 };
        for (self.p.loops, 0..) |loop, i| {
            const v = optimizer.loopNh(self.p.parts, loop);
            if (v > lv[0]) {
                lv[2] = lv[1];
                li[2] = li[1];
                lv[1] = lv[0];
                li[1] = li[0];
                lv[0] = v;
                li[0] = i;
            } else if (v > lv[1]) {
                lv[2] = lv[1];
                li[2] = li[1];
                lv[1] = v;
                li[1] = i;
            } else if (v > lv[2]) {
                lv[2] = v;
                li[2] = i;
            }
        }
        for (0..3) |k| {
            if (lv[k] < 0 or n >= lines.len) break;
            const loop = self.p.loops[li[k]];
            const cap = self.p.parts[loop.cap];
            lines[n] = std.fmt.bufPrint(&lines_buf[n], "{d}. loop {s}>{s} {d:.1}nH", .{
                n + 1,
                cap.ref_des,
                self.p.parts[loop.hub].ref_des,
                lv[k],
            }) catch "";
            marks[n] = .{ self.xpx(cap.x), self.ypx(cap.y) };
            n += 1;
        }

        // Longest signal airwire — the worst HPWL contributor.
        var best_len: f64 = -1;
        var best_mid: [2]f32 = .{ 0, 0 };
        var best_a: []const u8 = "";
        var best_b: []const u8 = "";
        for (self.p.links) |l| {
            const a = world(self.p.parts[l.a], l.ax, l.ay);
            const b = world(self.p.parts[l.b], l.bx, l.by);
            const d = std.math.hypot(b[0] - a[0], b[1] - a[1]);
            if (d > best_len) {
                best_len = d;
                best_mid = .{ self.xpx((a[0] + b[0]) / 2), self.ypx((a[1] + b[1]) / 2) };
                best_a = self.p.parts[l.a].ref_des;
                best_b = self.p.parts[l.b].ref_des;
            }
        }
        if (best_len > 0 and n < lines.len) {
            lines[n] = std.fmt.bufPrint(&lines_buf[n], "{d}. longest net {s}>{s} {d:.1}mm", .{ n + 1, best_a, best_b, best_len }) catch "";
            marks[n] = best_mid;
            n += 1;
        }
        if (self.unplaced_set.count() > 0 and n < lines.len) {
            lines[n] = std.fmt.bufPrint(&lines_buf[n], "{d}. {d} unplaced (staged)", .{ n + 1, self.unplaced_set.count() }) catch "";
            marks[n] = null;
            n += 1;
        }
        if (self.opts.violations.len > 0 and n < lines.len) {
            lines[n] = std.fmt.bufPrint(&lines_buf[n], "{d}. {d} drc violations", .{ n + 1, self.opts.violations.len }) catch "";
            marks[n] = null;
            n += 1;
        }
        if (n == 0) return;

        for (0..n) |k| {
            const m = marks[k] orelse continue;
            const r = self.pw(8);
            self.cv.disc(m[0], m[1], r, bg, 0.7);
            self.cv.ring(m[0], m[1], r, self.pw(1.5), accent_rgb, 0.95);
            var nb: [4]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{k + 1}) catch "";
            self.cv.text(m[0], m[1] - self.pw(4), s, self.pw(8), accent_rgb, 1.0, .middle);
        }
        // Panel on the right edge; drops below the blame panel when both are on.
        const x = @as(f32, @floatFromInt(self.cv.w)) - self.pw(215);
        var y = self.yoff + self.pw(6) + (if (self.opts.blame) self.pw(50) else @as(f32, 0));
        self.cv.text(x, y, "CRITIQUE (fix first)", self.pw(8), text_col, 0.95, .start);
        y += self.pw(12);
        for (0..n) |k| {
            self.cv.text(x, y, lines[k], self.pw(8), accent_rgb, 0.95, .start);
            y += self.pw(11);
        }
    }

    fn drawBlamePanel(self: *Ctx) void {
        if (self.blame_norm.len == 0) return;
        var idx = [_]usize{ 0, 0, 0 };
        var val = [_]f64{ -1, -1, -1 };
        for (self.blame_norm, 0..) |v, i| {
            if (v > val[0]) {
                val[2] = val[1];
                idx[2] = idx[1];
                val[1] = val[0];
                idx[1] = idx[0];
                val[0] = v;
                idx[0] = i;
            } else if (v > val[1]) {
                val[2] = val[1];
                idx[2] = idx[1];
                val[1] = v;
                idx[1] = i;
            } else if (v > val[2]) {
                val[2] = v;
                idx[2] = i;
            }
        }
        const x = @as(f32, @floatFromInt(self.cv.w)) - self.pw(130);
        var y = self.yoff + self.pw(6);
        self.cv.text(x, y, "WORST (blame)", self.pw(8), text_col, 0.95, .start);
        y += self.pw(12);
        for (0..3) |k| {
            if (val[k] < 0) break;
            var buf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}. {s}  {d:.0}%", .{ k + 1, net_name.leaf(self.p.parts[idx[k]].ref_des), val[k] * 100 }) catch "";
            self.cv.text(x, y, s, self.pw(8), blameColor(val[k]), 0.95, .start);
            y += self.pw(11);
        }
    }

    fn drawLabels(self: *Ctx) void {
        const h = self.pw(9);
        for (self.p.parts, 0..) |part, pi| {
            if (self.isTestPoint(pi)) continue; // generated board silk is the one authoritative TP label
            const active = self.partActive(part);
            if (self.focus and !active) continue;
            const court = optimizer.worldCourtyard(&part);
            const cx = self.xpx(court.minx + court.w / 2);
            const top = self.ypx(court.miny) - h - self.pw(2);
            const col = if (self.isUnplaced(part.ref_des))
                drc_col
            else if (self.focus and self.refHot(part.ref_des))
                accent_rgb
            else if (part.side == .bottom) silk_bot else silk_rgb;
            var buf: [96]u8 = undefined;
            self.cv.text(cx, top, self.partLabel(pi, &buf), h, col, 1.0, .middle);
        }
    }

    /// Board-level silkscreen text (the Text tool / sidecar `texts[]`) uses the
    /// same single-line glyph geometry as the Gerber writer, so the PNG shows
    /// the manufactured paths. Bottom-side text mirrors x and the whole string
    /// rotates about its anchor.
    fn drawOneBoardText(self: *Ctx, t: font.BoardText) void {
        const Pen = struct {
            ctx: *Ctx,
            cx: f64,
            cy: f64,
            gx0: f64,
            scale: f64,
            mirror: bool,
            ca: f64,
            sa: f64,
            col: Rgb,
            fn place(self2: @This(), lx_units: f64, ly_units: f64) [2]f32 {
                const lx0 = lx_units * self2.scale;
                const ly = ly_units * self2.scale;
                const lx = if (self2.mirror) -lx0 else lx0;
                const wx = self2.cx + lx * self2.ca - ly * self2.sa;
                const wy = self2.cy + lx * self2.sa + ly * self2.ca;
                return .{ self2.ctx.xpx(wx), self2.ctx.ypx(wy) };
            }
            fn emit(self2: @This(), stroke: silk_font.Stroke) error{}!void {
                const a = self2.place(self2.gx0 + stroke.x1, stroke.y1 - silk_font.cap_units / 2);
                const b = self2.place(self2.gx0 + stroke.x2, stroke.y2 - silk_font.cap_units / 2);
                // The shared aperture stays independent of cap height.
                const w = @max(self2.ctx.len(silk_font.stroke_width_mm), self2.ctx.pw(1.0));
                self2.ctx.cv.line(a[0], a[1], b[0], b[1], w, self2.col, 1.0, .round);
            }
        };
        if (t.text.len == 0) return;
        const size = if (t.size > 0) t.size else font.default_size_mm;
        const scale = size / silk_font.em_units;
        const a = @mod(t.rot, 360.0) * std.math.pi / 180.0;
        const ca = @cos(a);
        const sa = @sin(a);
        var gx0 = -silk_font.widthUnits(t.text) / 2;
        for (t.text) |ch| {
            const tcol = if (t.bottom) silk_bot else silk_rgb;
            const pen = Pen{ .ctx = self, .cx = t.x, .cy = t.y, .gx0 = gx0, .scale = scale, .mirror = t.bottom, .ca = ca, .sa = sa, .col = tcol };
            // The emit callback is infallible (error{}); the exhaustive
            // switch on the empty error set is a no-op, not a swallowed error.
            silk_font.glyphStrokes(ch, error{}, pen, Pen.emit) catch |err| switch (err) {};
            gx0 += silk_font.advanceUnits(ch);
        }
    }

    /// Generated F./B.Silkscreen artwork: sub-circuit L corners + labels,
    /// followed by editable user text on the same physical side layers as each
    /// footprint's authored silkscreen artwork.
    fn drawBoardSilkscreen(self: *Ctx) void {
        for (self.pin_one_silk) |marker| {
            const col = if (marker.side == .bottom) silk_bot else silk_rgb;
            self.cv.disc(
                self.xpx(marker.x),
                self.ypx(marker.y),
                self.len(subcircuit_silkscreen.pin_one_marker_diameter_mm / 2),
                col,
                1.0,
            );
        }
        for (self.sub_silk) |annotation| {
            const col = if (annotation.side == .bottom) silk_bot else silk_rgb;
            for (annotation.visibleSegments()) |segment| {
                self.cv.line(
                    self.xpx(segment.x1),
                    self.ypx(segment.y1),
                    self.xpx(segment.x2),
                    self.ypx(segment.y2),
                    @max(self.len(0.15), self.pw(1.0)),
                    col,
                    1.0,
                    .round,
                );
            }
            self.drawOneBoardText(annotation.label());
        }
        for (self.testpoint_silk) |label| self.drawOneBoardText(label.text);
        for (self.opts.texts) |t| self.drawOneBoardText(t);
    }

    /// Net-name labels on the pads of every `pin_refs`-selected part, dark on
    /// the pad copper — how an agent reads pin functions (FB/SW/VIN) off the
    /// image instead of guessing from pad geometry.
    fn drawPinLabels(self: *Ctx) void {
        if (self.pin_set.count() == 0) return;
        for (self.p.parts, 0..) |part, part_i| {
            if (!self.pinLabeled(part, part_i)) continue;
            for (part.pads, 0..) |pad, pad_i| {
                const net = self.netOf(part.ref_des, pad.number) orelse continue;
                const c = self.lp(part, pad.x, pad.y);
                // Cap the glyph height to the pad's smaller extent so labels on
                // fine-pitch pads shrink instead of blanketing the neighbourhood.
                const h = std.math.clamp(self.len(@min(pad.w, pad.h)) * 0.8, self.pw(4.0), self.pw(7.0));
                const s = shortName(net);
                // Stagger neighbouring labels vertically so adjacent same-row
                // pads (a QFN edge) don't run their names together.
                const stagger: f32 = if (pad_i % 2 == 0) -h * 0.7 else h * 0.7;
                // Dark backing chip so the label survives overflowing a small
                // pad onto the board (bright-on-dark everywhere).
                const ty = c[1] - h / 2 + stagger;
                const tw = raster.Canvas.textWidth(s, h);
                self.cv.fillRect(c[0] - tw / 2 - self.pw(1), ty - self.pw(1), tw + self.pw(2), h + self.pw(2), bg, 0.55);
                self.cv.text(c[0], ty, s, h, text_col, 1.0, .middle);
            }
        }
    }

    fn drawHeader(self: *Ctx) void {
        const pad = self.pw(6);
        if (self.opts.title.len > 0) {
            self.cv.text(pad, self.pw(3), self.opts.title, self.pw(13), text_col, 1.0, .start);
        }
        // Objective decomposition — every render is self-documenting.
        const b = self.p.breakdown;
        var buf: [200]u8 = undefined;
        const score = std.fmt.bufPrint(
            &buf,
            "obj {d:.1}  |  hpwl {d:.1}  loop {d:.1}nH  cmp {d:.0}mm2  cong {d:.1}",
            .{ b.objective, b.hpwl, b.loop_nh, b.alignment, b.congestion },
        ) catch "";
        self.cv.text(pad, self.pw(20), score, self.pw(9), text_dim, 1.0, .start);
        // Top-right: staging status, so a board that left parts in the band (or
        // auto-filled some) is impossible to mistake for a finished layout. Auto-
        // filled parts are usable but unpinned — amber, between red and green.
        if (self.opts.spec) |sp| {
            const xr = @as(f32, @floatFromInt(self.cv.w)) - pad;
            if (sp.unplaced.len > 0) {
                var buf3: [64]u8 = undefined;
                const s3 = std.fmt.bufPrint(&buf3, "{d} UNPLACED (staged)", .{sp.unplaced.len}) catch "";
                self.cv.text(xr, self.pw(3), s3, self.pw(10), drc_col, 1.0, .end);
                if (sp.auto_filled.len > 0) {
                    var buf4: [48]u8 = undefined;
                    const s4 = std.fmt.bufPrint(&buf4, "+ {d} AUTO-FILLED", .{sp.auto_filled.len}) catch "";
                    self.cv.text(xr, self.pw(15), s4, self.pw(9), accent_rgb, 1.0, .end);
                }
            } else if (sp.auto_filled.len > 0) {
                var buf3: [64]u8 = undefined;
                const s3 = std.fmt.bufPrint(&buf3, "{d} AUTO-FILLED", .{sp.auto_filled.len}) catch "";
                self.cv.text(xr, self.pw(3), s3, self.pw(10), accent_rgb, 1.0, .end);
            }
        }
        // Third line: compare Δ if diffing, else the focus caption.
        if (self.opts.compare) |c| {
            var buf2: [64]u8 = undefined;
            const d = b.objective - c.breakdown.objective;
            const sign = if (d >= 0) "+" else "-";
            const s2 = std.fmt.bufPrint(&buf2, "vs base: d_obj {s}{d:.1} ({s})", .{ sign, @abs(d), if (d <= 0) "better" else "worse" }) catch "";
            self.cv.text(pad, self.pw(32), s2, self.pw(9), if (d <= 0) good_col else drc_col, 1.0, .start);
        } else if (self.focus) {
            self.cv.text(pad, self.pw(32), self.caption, self.pw(8), accent_rgb, 1.0, .start);
        }
    }

    fn drawLegend(self: *Ctx, routed: bool) void {
        const y: f32 = @as(f32, @floatFromInt(self.cv.h - legend_h_px)) + self.pw(7);
        var x = self.pw(6);
        x = self.legendItem(x, y, aw_prox, "HOT LOOP");
        x = self.legendItem(x, y, aw_gnd, "GND");
        x = self.legendItem(x, y, aw_sig, "SIGNAL");
        if (routed) {
            x = self.legendItem(x, y, track_top, "F.CU");
            x = self.legendItem(x, y, track_bot, "B.CU");
            // Inner routable layers (a >2-signal stackup): one entry each,
            // named from the stackup so the legend matches the Gerber files.
            const n_sig = self.p.rules.signalLayerCount();
            var lname_buf: [16]u8 = undefined;
            var sig: u8 = 2;
            while (sig < n_sig) : (sig += 1) {
                const nm = self.p.rules.signalLayerName(sig, &lname_buf);
                x = self.legendItem(x, y, trackColor(self.p.rules, sig), nm);
            }
            x = self.legendItem(x, y, via_col, "VIA");
        }
        if (self.focus) x = self.legendItem(x, y, accent_rgb, "FOCUS");
        if (self.opts.spec) |sp| {
            if (sp.unplaced.len > 0) x = self.legendItem(x, y, drc_col, "UNPLACED");
            if (sp.auto_filled.len > 0) x = self.legendItem(x, y, accent_rgb, "AUTO-FILLED");
        }
    }

    fn legendItem(self: *Ctx, x: f32, y: f32, col: Rgb, label: []const u8) f32 {
        const sw = self.pw(8);
        self.cv.fillRect(x, y, sw, sw, col, 1.0);
        const tx = x + sw + self.pw(3);
        const h = self.pw(8);
        self.cv.text(tx, y, label, h, text_dim, 1.0, .start);
        return tx + raster.Canvas.textWidth(label, h) + self.pw(12);
    }

    /// A constant on-screen pixel size (independent of board zoom — stroke
    /// widths, label heights, marker radii), cast to f32 for the canvas. The
    /// canvas handles supersampling internally, so these are final-output px.
    fn pw(_: *Ctx, v: f64) f32 {
        return @floatCast(v);
    }
    fn outlineW(self: *Ctx, active: bool) f32 {
        return if (active) self.pw(1.3) else self.pw(1.0);
    }
};

/// Colour an airwire by its kind (mirrors BOARD_JS; an if-chain rather than a
/// switch so the RatKind switch isn't duplicated across modules).
fn awColor(kind: optimizer.RatKind) Rgb {
    if (kind == .proximity) return aw_prox;
    if (kind == .ground) return aw_gnd;
    return aw_sig;
}

/// One channel of a linear colour blend.
fn mixByte(a: u8, b: u8, t: f64) u8 {
    const af: f64 = @floatFromInt(a);
    const bf: f64 = @floatFromInt(b);
    return numeric.checkedInt(u8, @round(af + (bf - af) * t)) orelse 0;
}
/// Blend two colours; `t` clamped to [0,1].
fn lerpRgb(a: Rgb, b: Rgb, t: f64) Rgb {
    const tt = std.math.clamp(t, 0, 1);
    return .{ .r = mixByte(a.r, b.r, tt), .g = mixByte(a.g, b.g, tt), .b = mixByte(a.b, b.b, tt) };
}
/// Heatmap colour for a normalized blame value: cheap (cool) → expensive (hot).
fn blameColor(t: f64) Rgb {
    return if (t < 0.5) lerpRgb(blame_lo, blame_mid, t * 2) else lerpRgb(blame_mid, blame_hi, (t - 0.5) * 2);
}
/// Reference-grid spacing (mm): 1/2/5/10 so the line count stays legible.
fn gridStep(span_x: f64, span_y: f64) f64 {
    const span = @max(span_x, span_y);
    if (span <= 16) return 1;
    if (span <= 40) return 2;
    if (span <= 100) return 5;
    return 10;
}

/// Build the focus-mode caption ("FOCUS  NETS: …  REFS: …") in `alloc`.
fn buildCaption(alloc: std.mem.Allocator, opts: Options) std.mem.Allocator.Error![]const u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(alloc, "FOCUS  ");
    if (opts.highlight_nets.len > 0) {
        try b.appendSlice(alloc, "NETS: ");
        try joinInto(&b, alloc, opts.highlight_nets);
        if (opts.highlight_refs.len > 0) try b.appendSlice(alloc, "  ");
    }
    if (opts.highlight_refs.len > 0) {
        try b.appendSlice(alloc, "REFS: ");
        try joinInto(&b, alloc, opts.highlight_refs);
    }
    return b.toOwnedSlice(alloc);
}

fn joinInto(b: *std.ArrayList(u8), alloc: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error!void {
    for (items, 0..) |it, i| {
        if (i > 0) try b.appendSlice(alloc, ", ");
        try b.appendSlice(alloc, it);
    }
}

// ── Small net-name helpers (mirror serve/pcb_layout_page.zig) ───────────────
fn shortName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}
fn netKey(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |i| return name[0..i];
    return name;
}
/// True if the uppercased `s` is a member of `set` (whose keys are uppercased,
/// inserted via `upper` with no length cap). The stack buffer covers realistic
/// refs (incl. deep sub-block paths); a pathologically long `s` falls back to a
/// case-insensitive linear scan of the set so the lookup can never silently
/// miss a key the insertion side accepted — the two paths agree on membership.
fn upperInSet(set: *std.StringHashMapUnmanaged(void), s: []const u8) bool {
    var buf: [256]u8 = undefined;
    if (s.len <= buf.len) {
        for (s, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
        return set.contains(buf[0..s.len]);
    }
    var it = set.keyIterator();
    while (it.next()) |k| {
        if (eqUpper(s, k.*)) return true;
    }
    return false;
}

fn eqUpper(a: []const u8, b_upper: []const u8) bool {
    if (a.len != b_upper.len) return false;
    for (a, b_upper) |ca, cb| {
        if (std.ascii.toUpper(ca) != cb) return false;
    }
    return true;
}
fn upper(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    const out = try alloc.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
    return out;
}

test "render produces a PNG for a tiny placement" {
    const alloc = std.testing.allocator;
    var pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &pads, .fallback = false, .x = 9, .y = 5 },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 12,
        .maxy = 10,
        .generated = true,
    };
    const png_bytes = try render(alloc, p, .{ .width = 600, .title = "test" });
    defer alloc.free(png_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, png_bytes[0..4]);
}

test "PNG pad transform rotates QFN side pads independently of footprint" {
    const part = optimizer.Part{
        .ref_des = "U14",
        .kind = .hub,
        .hw = 2.65,
        .hh = 2.65,
        .pads = &.{},
        .fallback = false,
        .x = 144.16,
        .y = 108.962,
    };
    const pad = geometry.Pad{
        .number = "4",
        .x = -2,
        .y = 0.25,
        .w = 0.3,
        .h = 0.8,
        .rot = -90,
    };
    const end = Ctx.padWorld(part, pad, 0, pad.h / 2);
    try std.testing.expectApproxEqAbs(@as(f64, 142.56), end[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 109.212), end[1], 1e-9);
}

test "render with origin labels, pad net labels and spec status" {
    const export_kicad = @import("export_kicad.zig");
    // The renderer assumes an arena (production passes req.arena): the upper-
    // cased highlight/pin/unplaced keys are never individually freed.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "C150", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &pads, .fallback = false, .x = 9, .y = 5 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "U1" },
        .{ .ref_des = "C150", .component = "cap", .value = "100nF", .footprint = "", .properties = &.{}, .uuid = "", .origin_key = "C_BOOT1" },
    };
    const net_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C150", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "VIN", .pins = &net_pins }};
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &instances,
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 12,
        .maxy = 10,
        .generated = true,
    };
    const unplaced = [_][]const u8{"C150"};
    const pin_refs = [_][]const u8{"hubs"};
    const png_bytes = try render(alloc, p, .{
        .width = 600,
        .title = "test",
        .names = .both,
        .pin_refs = &pin_refs,
        .spec = .{ .unplaced = &unplaced },
    });
    defer alloc.free(png_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, png_bytes[0..4]);
}

// spec: Web Server - the board PNG fills inner planes from the same pour engine the fabrication outputs use
test "PNG paints an inner plane's copper and carves a foreign via's antipad in it" {
    const export_kicad = @import("export_kicad.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // A 20 mm four-layer board with a declared GND plane on In1.Cu (stack 2) —
    // an INNER layer, which the PNG used to draw nothing at all for.
    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &gnd_pad,
        .fallback = false,
        .x = 3,
        .y = 3,
    }};
    const gnd_pins = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 },
        .rules = .{ .plane_nets = &gnd_names, .copper_layers = 4, .planes = .{ .declared = &planes } },
    };
    const vias = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.6, .net = 1 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 };
    var cv = try renderPhysicalCanvas(alloc, p, .{ .width = 600, .routed = routed, .bare = true });
    defer cv.deinit();
    const px_mm: usize = 50; // 600 px / 24 mm × ss=2
    const row = (12 * px_mm) * cv.iw; // world y = 10
    // (a) deep inside the plane: In1.Cu's yellow tint (#C2C200) lifts red and
    // green well above the #001023 canvas, and leaves blue at the canvas value.
    const in_plane = (row + 19 * px_mm) * 3;
    try std.testing.expect(cv.buf[in_plane] > 0x10);
    try std.testing.expect(cv.buf[in_plane + 1] > 0x20);
    // (b) inside the foreign via's antipad: honestly carved bare board.
    const in_antipad = (row + 12 * px_mm + 22) * 3;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x10, 0x23 }, cv.buf[in_antipad .. in_antipad + 3]);
}

// spec: Web Server - the board PNG strokes a routed arc as a curve and drops the chords it owns
test "PNG draws a routed arc off its true curve, not its chords" {
    const alloc = std.testing.allocator;
    const p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
    };
    // A quarter turn of radius 6 about (10,10), from (16,10) to (10,4). Its
    // copper is ALSO present as the two coarse chords the router keeps.
    const leg: f64 = 6.0 / @sqrt(2.0);
    const mid = [2]f64{ 10 + leg, 10 - leg };
    const arcs = [_]router.Arc{.{ .p1 = .{ 16, 10 }, .pm = mid, .p2 = .{ 10, 4 }, .layer = 0, .width = 0.6, .net = 0 }};
    const chords = [_]router.Track{
        .{ .x1 = 16, .y1 = 10, .x2 = mid[0], .y2 = mid[1], .layer = 0, .width = 0.6, .net = 0 },
        .{ .x1 = mid[0], .y1 = mid[1], .x2 = 10, .y2 = 4, .layer = 0, .width = 0.6, .net = 0 },
    };
    const routed = router.RouteResult{ .tracks = &chords, .vias = &.{}, .arcs = &arcs, .routed = 1, .total = 1 };
    var cv = try renderPhysicalCanvas(alloc, p, .{ .width = 600, .routed = routed, .bare = true });
    defer cv.deinit();
    const px_mm: usize = 50;
    // 45° along the arc — ON the curve, and the point the two chords cut the
    // corner furthest from. Copper red (#C83434) is there now.
    const on_curve = (@as(usize, @intFromFloat(@round((mid[1] + 2) * @as(f64, px_mm)))) * cv.iw +
        @as(usize, @intFromFloat(@round((mid[0] + 2) * @as(f64, px_mm))))) * 3;
    try std.testing.expect(cv.buf[on_curve] > 0x80);
    // The chord midpoint between the arc's start and its own middle sample sits
    // INSIDE the circle; with the chords suppressed it is bare board there.
    const inside = (@as(usize, @intFromFloat(@round(13.0 * @as(f64, px_mm)))) * cv.iw +
        @as(usize, @intFromFloat(@round(13.0 * @as(f64, px_mm))))) * 3;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x10, 0x23 }, cv.buf[inside .. inside + 3]);
}

fn containsCopperRedPixel(rgb: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < rgb.len) : (i += 3) {
        if (rgb[i] > 0x80 and rgb[i + 1] < 0x80) return true;
    }
    return false;
}

// spec: Web Server - RF-only saved paths paint their sampled physical chords even when no ordinary track handle is present
test "PNG draws an RF-only physical path" {
    const alloc = std.testing.allocator;
    const p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
    };
    const RfOutcome = @typeInfo(@FieldType(router.RouteResult, "rf_port_outcomes")).pointer.child;
    const RfPhysical = @FieldType(RfOutcome, "physical");
    const RfSample = @typeInfo(@FieldType(RfPhysical, "samples")).pointer.child;
    const samples = [_]RfSample{
        .{ .at = .{ 2, 2 }, .s_mm = 0, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 8, 2 }, .s_mm = 6, .curvature = 0, .width_mm = 0.4 },
        .{ .at = .{ 8, 8 }, .s_mm = 12, .curvature = 0, .width_mm = 0.2 },
    };
    const paths = [_]RfOutcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .rf_port_outcomes = &paths, .routed = 1, .total = 1 };
    var route_arena_state = std.heap.ArenaAllocator.init(alloc);
    defer route_arena_state.deinit();
    const physical = try physicalRoute(route_arena_state.allocator(), routed);
    try std.testing.expectEqual(@as(usize, 2), physical.tracks.len);
    var cv = try renderPhysicalCanvas(alloc, p, .{ .width = 600, .routed = routed, .bare = true });
    defer cv.deinit();

    // An otherwise empty board has no copper-red pixels. The RF-only proof
    // therefore has to be lowered and painted for any such pixel to exist.
    try std.testing.expect(containsCopperRedPixel(cv.buf));
}

// spec: Web Server - the board PNG paints bottom-side parts under top-side parts
test "PNG paints a bottom-side part under the top-side part it overlaps" {
    const alloc = std.testing.allocator;
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 4, .h = 4 }};
    // The bottom part is declared FIRST, so array order alone would have let it
    // paint over the top-side one it sits directly beneath.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 2, .hh = 2, .pads = &pad, .fallback = false, .x = 10, .y = 10, .side = .bottom },
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pad, .fallback = false, .x = 10, .y = 10 },
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
    };
    var cv = try renderCanvas(alloc, p, .{ .width = 600, .bare = true });
    defer cv.deinit();
    const px_mm: usize = 50;
    const at = ((12 * px_mm) * cv.iw + 12 * px_mm) * 3;
    // F.Cu pad red (#C83434) wins over the B.Cu pad blue (#4D7FC4) underneath.
    try std.testing.expect(cv.buf[at] > 0x90);
    try std.testing.expect(cv.buf[at + 2] < 0x60);
}

// spec: Web Server - a via-in-pad keeps its drilled centre visible after component pads paint above routed copper
test "PNG re-punches a via bore through an overlapping SMD pad" {
    const alloc = std.testing.allocator;
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 4, .h = 4 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 2,
        .hh = 2,
        .pads = &pads,
        .fallback = false,
        .x = 10,
        .y = 10,
    }};
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
    };
    const vias = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.8, .drill = 0.3, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 1, .total = 1 };
    var cv = try renderCanvas(alloc, p, .{ .width = 600, .routed = routed, .bare = true });
    defer cv.deinit();

    // 25 final px/mm at width 600, doubled by the raster supersampling. The
    // 2 mm margin moves world (10,10) to internal pixel (600,600).
    const px_mm: usize = 50;
    const at = ((12 * px_mm) * cv.iw + 12 * px_mm) * 3;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x10, 0x23 }, cv.buf[at .. at + 3]);
}

// spec: Web Server - the PCB PNG paints declared outer pours as computed fill contours with antipad holes carved by the routed copper the image draws
test "PNG pour paints the computed fill and leaves a foreign via's antipad bare" {
    const export_kicad = @import("export_kicad.zig");
    // pour.compute treats its allocator as an arena and renderCanvas's pad-net
    // keys are request-scoped — mirror production's req.arena.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // A 20 mm board with a declared bottom GND pour (plane index 2 of a
    // 2-layer stack), seeded by C1's bottom-side GND pad.
    const gnd_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = &gnd_pad,
        .fallback = false,
        .x = 3,
        .y = 3,
        .side = .bottom,
    }};
    const gnd_pins = [_]export_kicad.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "VIN", .pins = &.{} },
    };
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 },
        .rules = .{ .plane_nets = &gnd_names, .copper_layers = 2, .planes = .{ .declared = &planes } },
    };
    // A FOREIGN VIN via dead centre, drawn by the route overlay — so the pour
    // must be carved with an antipad around exactly the copper the image shows.
    const vias = [_]router.Via{.{ .x = 10, .y = 10, .dia = 0.6, .net = 1 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 };
    var cv = try renderCanvas(alloc, p, .{ .width = 600, .routed = routed });
    defer cv.deinit();
    // Projection: 600 px / (20 + 2·margin) mm = 25 px/mm, ×ss → 50 internal
    // px per mm; the header band offsets y by header_h_px·ss.
    const px_mm: usize = 50;
    const hdr: usize = header_h_px * ss;
    const row = (hdr + 12 * px_mm) * cv.iw; // world y = 10
    // (a) world (17,10) — deep inside the pour, far from via/pad/labels: the
    // bottom-pour tint lifts blue well above the #001023 canvas.
    const in_pour = (row + 19 * px_mm) * 3;
    try std.testing.expect(cv.buf[in_pour + 2] > 0x30);
    // (b) world (10.45,10) — inside the via's antipad ring but outside the
    // drawn via copper: honestly carved bare board, exactly the canvas colour.
    const in_antipad = (row + 12 * px_mm + 22) * 3;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x10, 0x23 }, cv.buf[in_antipad .. in_antipad + 3]);
    // Without the route overlay the image draws no via — the pour is uncarved,
    // consistent with the picture, so the same point carries the tint.
    var cv2 = try renderCanvas(alloc, p, .{ .width = 600 });
    defer cv2.deinit();
    try std.testing.expect(cv2.buf[in_antipad + 2] > 0x30);
}

// spec: Web Server - the board PNG washes and names each authored board keepout region, leaving the rest of the board bare
test "PNG paints an authored board keepout region" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    // A 20 mm board whose right half is reserved.
    const specs = [_]env.BoardKeepoutSpec{.{
        .name = "plate",
        .rect = .{ .x = 10, .y = 0, .w = 10, .h = 20 },
        .side = .bottom,
    }};
    const p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 20 },
        .rules = .{ .board_keepouts = &specs },
    };
    var cv = try renderCanvas(alloc, p, .{ .width = 600 });
    defer cv.deinit();
    // Same projection as the pour test: 600 px / (20 + 2·margin) mm = 25 px/mm,
    // ×ss internal, with the header band offsetting y.
    const px_mm: usize = 50;
    const row = (header_h_px * ss + 5 * px_mm) * cv.iw; // world y = 3
    // World (16,3) — inside the reserved half. The violet wash lifts red off
    // the #001023 canvas, which has none.
    const inside = (row + 18 * px_mm) * 3;
    try std.testing.expect(cv.buf[inside] > 0x10);
    // World (4,3) — the free half stays exactly the canvas colour.
    const outside = (row + 6 * px_mm) * 3;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x10, 0x23 }, cv.buf[outside .. outside + 3]);

    // A board declaring no region paints neither wash nor rim.
    var bare = p;
    bare.rules = .{};
    var cv2 = try renderCanvas(alloc, bare, .{ .width = 600 });
    defer cv2.deinit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x10, 0x23 }, cv2.buf[inside .. inside + 3]);
}

// spec: Web Server - the board PNG paints the canonical stages in order
test "the PNG pass table is the canonical stage list, stage for stage" {
    const order = @import("render_order.zig");
    try std.testing.expectEqual(order.stages.len, board_passes.len);
    for (order.stages, board_passes) |want, got| {
        try std.testing.expectEqualStrings(want.name, got.stage);
        // The holes are deliberate and named: this renderer has no group-box
        // or clearance-halo model, and nothing else may be a hole. The keepout
        // stage is NOT one: it paints the authored `(board … (keepout …))`
        // regions (the derived perimeter band stays viewer-only, being a
        // function of the outline the image already draws).
        const hole = std.mem.eql(u8, got.stage, "groups") or
            std.mem.eql(u8, got.stage, "clearance");
        try std.testing.expectEqual(hole, got.run == null);
    }
}

// spec: Web Server - footprint silk paints above routed copper on the board PNG
test "PNG footprint silk survives a track routed straight across it" {
    const alloc = std.testing.allocator;
    // One part carrying a single horizontal silk line at world y = 10, and a
    // fat F.Cu track routed along exactly that line.
    const silk = [_]geometry.SilkLine{.{ .x1 = -4, .y1 = 0, .x2 = 4, .y2 = 0 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 4,
        .hh = 2,
        .pads = &.{},
        .fallback = false,
        .x = 10,
        .y = 10,
        .features = .{ .silk_lines = &silk },
    }};
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 20,
        .generated = false,
    };
    const tracks = [_]router.Track{.{ .x1 = 6, .y1 = 10, .x2 = 14, .y2 = 10, .layer = 0, .width = 1.0, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    var cv = try renderCanvas(alloc, p, .{ .width = 600, .routed = routed, .bare = true });
    defer cv.deinit();
    // Projection: 600 px / (20 + 2·margin) mm = 25 px/mm, ×ss → 50 internal px
    // per mm, with the margin shifting world 0 to 2 mm; `bare` drops the header
    // band, so world (10,10) — dead centre of both the track and the silk line
    // — lands at internal pixel (12·50, 12·50).
    const px_mm: usize = 50;
    const at = ((12 * px_mm) * cv.iw + 12 * px_mm) * 3;
    // Silk white (#F0F0F0), not the F.Cu trace red (#C83434): the ink is
    // printed on the finished board, so it covers the copper it crosses.
    try std.testing.expect(cv.buf[at] > 0xE0);
    try std.testing.expect(cv.buf[at + 1] > 0xE0);
    try std.testing.expect(cv.buf[at + 2] > 0xE0);
}

// spec: Web Server - the viewer strokes footprint silk as one pass above the copper pass, and under the assembly review's package bodies
test "viewer JS strokes footprint silk in its own pass after the copper pass" {
    const js = @embedFile("serve/assets/pcb_board.js");
    const order = @import("render_order.zig");
    // The stroke left paintParts entirely — it is one pass of its own, reached
    // from exactly one place: its entry in the shared stage table. Its position
    // (above copper, and under the review's package bodies) is that table's
    // business and is asserted in render_order.zig against the canonical list.
    try std.testing.expect(std.mem.indexOf(u8, js, "function paintFootprintSilk(") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "sp:1,f:function(c,k,s){paintFootprintSilk(c,k,s.mov,s.only);}}") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, js, "paintFootprintSilk(c,k,"));
    // …and the silk Path2D is stroked in exactly that one place, so paintParts
    // can no longer put it under the copper.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, js, "ctx.stroke(pp.silk)"));
    // Pads and package bodies sit above routed copper, while fabrication silk
    // remains above copper and below opaque package bodies in assembly review.
    const silk = order.stages[order.indexOf("footprint_silk").?];
    const copper = order.stages[order.indexOf("copper").?];
    const parts = order.stages[order.indexOf("parts").?];
    try std.testing.expect(order.indexOf("copper").? < order.indexOf("parts").?);
    try std.testing.expect(order.indexOf("copper").? < order.indexOf("footprint_silk").?);
    try std.testing.expect(copper.review < silk.review and silk.review < parts.review);
}

// spec: Web Server - cropnet= computes the viewport as a net set's pad + copper bbox plus a margin, case-insensitively and excluding other nets' copper
test "cropNetBbox tightens to a net's pads and copper, dropping foreign copper" {
    const export_kicad = @import("export_kicad.zig");
    const alloc = std.testing.allocator;
    // U1 hub: pad 1 = VTUNE (left), pad 2 = GND (right). C1 cap far right, on the
    // same two nets. Rot 0, top side, so world pad = pose + local offset.
    var hub_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1.8, .y = 0, .w = 0.6, .h = 0.6 },
        .{ .number = "2", .x = 1.8, .y = 0, .w = 0.6, .h = 0.6 },
    };
    var cap_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.5, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &cap_pads, .fallback = false, .x = 9, .y = 5 },
    };
    const vt_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const gnd_pins = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "2" }, .{ .ref_des = "C1", .pin = "2" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "VTUNE", .pins = &vt_pins }, // index 0
        .{ .name = "GND", .pins = &gnd_pins }, // index 1
    };
    const p = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 30,
        .maxy = 30,
        .generated = true,
    };
    // VTUNE copper links the two VTUNE pads; a GND track sits far away — it must
    // NOT stretch the lens.
    const tracks = [_]router.Track{
        .{ .x1 = 3.2, .y1 = 5, .x2 = 8.5, .y2 = 5, .layer = 0, .width = 0.15, .net = 0 },
        .{ .x1 = 20, .y1 = 20, .x2 = 21, .y2 = 21, .layer = 0, .width = 0.15, .net = 1 },
    };
    const vias = [_]router.Via{.{ .x = 8.5, .y = 5, .dia = 0.6, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 2 };

    // Lower-case token → case-insensitive match; margin 1.5.
    const bb = (try cropNetBbox(alloc, p, routed, &.{"vtune"}, cropnet_margin_mm)) orelse return error.TestNoBbox;
    // Min x = U1|1 pad left edge: world 3.2 − 0.3 half. Max x = the VTUNE via at
    // x=8.5, radius 0.3 (wider than C1|1's 0.25 pad half), so 8.8. Both + margin.
    try std.testing.expectApproxEqAbs(@as(f64, 3.2 - 0.3 - cropnet_margin_mm), bb[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 8.5 + 0.3 + cropnet_margin_mm), bb[2], 1e-6);
    // The far GND track (x up to 21) is excluded — the lens stays under 12 mm.
    try std.testing.expect(bb[2] < 12);
    try std.testing.expect(bb[1] > 3 and bb[3] < 7);
    // No matching net → null (viewport stays the whole board).
    try std.testing.expect((try cropNetBbox(alloc, p, routed, &.{"NOSUCH"}, cropnet_margin_mm)) == null);
}

/// Every object colour this renderer paints, paired with the theme constant it
/// must equal. The list is the standing proof that the PNG re-types nothing:
/// a literal reintroduced above would have to be added here to stay green, and
/// then it would fail against the theme value it shadowed.
const themed_colors = [_]struct { drawn: Rgb, theme: []const u8 }{
    .{ .drawn = bg, .theme = board_theme.background },
    .{ .drawn = grid_col, .theme = board_theme.grid_dot },
    .{ .drawn = court_col, .theme = board_theme.courtyard },
    .{ .drawn = pad_col, .theme = board_theme.copper_top },
    .{ .drawn = pad_col_bot, .theme = board_theme.copper_bottom },
    .{ .drawn = track_top, .theme = board_theme.copper_top },
    .{ .drawn = track_bot, .theme = board_theme.copper_bottom },
    .{ .drawn = pad_pth, .theme = board_theme.pad_pth },
    .{ .drawn = pad_npth, .theme = board_theme.pad_npth },
    .{ .drawn = pad_hole, .theme = board_theme.drill_bore },
    .{ .drawn = silk_rgb, .theme = board_theme.silk_front },
    .{ .drawn = silk_bot, .theme = board_theme.silk_back },
    .{ .drawn = edge_col, .theme = board_theme.edge_cuts },
    .{ .drawn = keepout_col, .theme = board_theme.keepout_region },
    .{ .drawn = via_col, .theme = board_theme.via },
    .{ .drawn = via_hole, .theme = board_theme.via_hole },
    .{ .drawn = aw_sig, .theme = board_theme.ratsnest },
    .{ .drawn = aw_prox, .theme = board_theme.airwire_proximity },
    .{ .drawn = aw_gnd, .theme = board_theme.airwire_ground },
    .{ .drawn = loop_ret, .theme = board_theme.loop_return },
    .{ .drawn = drc_col, .theme = board_theme.drc },
    .{ .drawn = accent_rgb, .theme = board_theme.focus_accent },
    .{ .drawn = text_col, .theme = board_theme.text },
    .{ .drawn = text_dim, .theme = board_theme.text_dim },
    .{ .drawn = good_col, .theme = board_theme.improvement },
    .{ .drawn = blame_lo, .theme = board_theme.blame_low },
    .{ .drawn = blame_mid, .theme = board_theme.blame_mid },
    .{ .drawn = blame_hi, .theme = board_theme.blame_high },
};

// spec: Web Server - the PCB PNG's object colours are the shared board theme's rather than re-typed literals, and a routed track takes its layer table row's colour
test "the PNG paints the shared theme and reads track colour from the layer table" {
    for (themed_colors) |c| {
        const want = board_theme.channels(c.theme);
        try std.testing.expectEqualSlices(
            u8,
            &[_]u8{ want.r, want.g, want.b },
            &[_]u8{ c.drawn.r, c.drawn.g, c.drawn.b },
        );
    }

    // A track's colour is its physical row's, not a local (stack-2)%len sum:
    // with a plane on In1.Cu, signal 2 lives on In2.Cu (stack 3), so it takes
    // the row's own colour and NOT the second inner-palette entry by signal.
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const rules = optimizer.BoardRules{ .plane_nets = &.{"GND"}, .copper_layers = 4, .planes = .{ .declared = &planes } };
    try expectTracksMatchTable(rules);
    const in2 = rules.layerTable().rowOfSignal(board_layers.SignalIndex.of(2)).?;
    try std.testing.expectEqualStrings("#C200C2", in2.color());
}

/// Every routable layer of `rules` paints exactly the colour its own
/// layer-table row carries.
fn expectTracksMatchTable(rules: optimizer.BoardRules) !void {
    const table = rules.layerTable();
    var sig: u8 = 0;
    while (sig < rules.signalLayerCount()) : (sig += 1) {
        const row = table.rowOfSignal(board_layers.SignalIndex.of(sig)).?;
        const want = board_theme.channels(row.color());
        const got = trackColor(rules, sig);
        try std.testing.expectEqualSlices(u8, &[_]u8{ want.r, want.g, want.b }, &[_]u8{ got.r, got.g, got.b });
    }
}
