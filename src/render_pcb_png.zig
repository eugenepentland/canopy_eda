//! Server-side PNG rendering of a solved PCB placement, so an AI agent (or any
//! HTTP client) can *see* the layout instead of parsing the coordinate JSON the
//! browser viewer consumes. Mirrors the browser renderer (BOARD_JS in
//! `serve/pcb_layout_page.zig`): same world→pixel projection, same element
//! colours, same draw order — courtyards/silk/pads, then airwires + decoupling
//! loops, then routed copper, then DRC markers and labels.
//!
//! With `highlight_nets` / `highlight_refs` set, the render enters *focus mode*:
//! the named nets' pads + airwires and the named components glow in an accent
//! colour while everything else is dimmed back, so an agent inspecting one
//! subsystem sees it in the context of the whole board.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const geometry = @import("placement/geometry.zig");
const router = @import("placement/router.zig");
const drc = @import("placement/drc.zig");
const raster = @import("raster.zig");
const png = @import("png.zig");
const numeric = @import("numeric.zig");
const export_fab = @import("export_fab.zig");
const font = @import("font5x7.zig");

const Rgb = raster.Rgb;

// ── Theme (matches BOARD_JS) ───────────────────────────────────────────────
const BG = Rgb.hex("#0d1117");
const COURT_FILL = Rgb.hex("#161b22");
const COURT_FILL_BOT = Rgb.hex("#122036"); // bottom-side part body (blue wash, KiCad-like)
const HUB_STROKE = Rgb.hex("#58a6ff");
const PASSIVE_STROKE = Rgb.hex("#8b949e");
const SILK = Rgb.hex("#8b949e");
const PAD_COL = Rgb.hex("#b08d57");
const PAD_COL_BOT = Rgb.hex("#5b8dd6"); // bottom-side pad copper (B.Cu blue)
const AW_PROX = Rgb.hex("#ea580c"); // hot decoupling loop / proximity hug
const AW_GND = Rgb.hex("#22b8cf"); // ground return airwire
const AW_SIG = Rgb.hex("#9aa7b4"); // generic signal airwire
const LOOP_RET = Rgb.hex("#58a6ff"); // L2 ground-return overlay
const TRACK_TOP = Rgb.hex("#ef4444"); // F.Cu trace
const TRACK_BOT = Rgb.hex("#3b82f6"); // B.Cu trace
const VIA_COL = Rgb.hex("#d8b048");
const VIA_HOLE = Rgb.hex("#0d1117");
const PAD_HOLE = Rgb.hex("#0d1117"); // drilled bore punched through a thru/npth pad
const DRC_COL = Rgb.hex("#f85149");
const ACCENT = Rgb.hex("#f5c542"); // focus highlight
const TEXT_COL = Rgb.hex("#c9d1d9");
const TEXT_DIM = Rgb.hex("#6e7681");
const GOOD_COL = Rgb.hex("#3fb950"); // improvement (compare Δ ≤ 0)
const GRID_COL = Rgb.hex("#30363d"); // reference grid lines
const EDGE_COL = Rgb.hex("#7ee787"); // (board …) outline rectangle
// Blame heatmap ramp: cheap (cool) → expensive (hot).
const BLAME_LO = Rgb.hex("#15302a");
const BLAME_MID = Rgb.hex("#b8860b");
const BLAME_HI = Rgb.hex("#c0392b");

const MARGIN_MM: f64 = 2.0;
const MIN_W: u32 = 400;
const MAX_W: u32 = 2200;
const MAX_H: u32 = 2600;
const SS: u32 = 2; // supersample factor for anti-aliasing
const HEADER_H: u32 = 46; // title + objective score line (+ focus/compare line)
const LEGEND_H: u32 = 22;
const DIM_A: f32 = 0.20; // alpha for de-emphasised elements in focus mode

/// Which name labels parts: the flattened ref-des (`C150`), the stable
/// module-local origin name a `(placement …)` spec is written in (`C_BOOT1`),
/// or both (`C150=C_BOOT1`). Parts without an origin name fall back to ref.
pub const NameMode = enum { ref, origin, both };

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
    /// Skip the header band and legend — used for contact-sheet tiles.
    bare: bool = false,
    /// Callout overlay: numbered markers + a panel listing the board's worst
    /// problems (hottest loops, longest airwire, staged parts, DRC count).
    critique: bool = false,
    /// Board-level silkscreen text labels (from the shown layout's sidecar).
    /// Drawn in a silk colour at their world anchor + cap height, so the PNG
    /// and MCP screenshots show the same legend the Gerber emits.
    texts: []const font.BoardText = &.{},
};

/// Render `p` to PNG bytes owned by `alloc`.
pub fn render(alloc: std.mem.Allocator, p: optimizer.Placement, opts: Options) png.Error![]u8 {
    var cv = try renderCanvas(alloc, p, opts);
    defer cv.deinit();
    return cv.toPng(alloc);
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
        if (try findPartByName(alloc, p, cref)) |pi| {
            const r = if (opts.crop_r > 0) opts.crop_r else 6;
            vminx = p.parts[pi].x - r;
            vmaxx = p.parts[pi].x + r;
            vminy = p.parts[pi].y - r;
            vmaxy = p.parts[pi].y + r;
        }
    }
    const cw_mm = @max(vmaxx - vminx, 1.0) + 2 * MARGIN_MM;
    const ch_mm = @max(vmaxy - vminy, 1.0) + 2 * MARGIN_MM;

    var board_w = std.math.clamp(opts.width, MIN_W, MAX_W);
    var scale = @as(f64, @floatFromInt(board_w)) / cw_mm;
    var board_h_f = ch_mm * scale;
    if (board_h_f > MAX_H) {
        scale = @as(f64, @floatFromInt(MAX_H)) / ch_mm;
        board_h_f = @floatFromInt(MAX_H);
        // Guard the narrowing: a NaN/±inf or absurd coordinate leaking out of
        // the placement optimizer would make a bare `@intFromFloat` UB in the
        // runtime-safety-off ReleaseSmall prod build. Fall back to MIN_W, then
        // re-clamp to the valid canvas-width band.
        board_w = std.math.clamp(numeric.checkedInt(u32, @round(cw_mm * scale)) orelse MIN_W, MIN_W, MAX_W);
    }
    // Same guard; board_h is bounded above by MAX_H (board_h_f ≤ MAX_H here),
    // and a non-finite result collapses to a 1px-tall board rather than UB.
    const board_h: u32 = std.math.clamp(numeric.checkedInt(u32, @round(board_h_f)) orelse 1, 1, MAX_H);

    const focus = opts.highlight_nets.len > 0 or opts.highlight_refs.len > 0;
    const header_h: u32 = if (opts.bare) 0 else HEADER_H;
    const legend_h: u32 = if (opts.bare) 0 else LEGEND_H;
    const total_h = header_h + board_h + legend_h;
    var cv = try raster.Canvas.init(alloc, board_w, total_h, SS, BG);
    errdefer cv.deinit();

    // Highlight sets: full net names matching any token, and uppercased refs.
    var hot_nets = std.StringHashMap(void).init(alloc);
    defer hot_nets.deinit();
    var hot_refs = std.StringHashMap(void).init(alloc);
    defer hot_refs.deinit();
    try buildHighlightSets(alloc, p, opts, &hot_nets, &hot_refs);

    // Pad-label targets and spec-unplaced parts, both uppercased ref sets.
    var pin_set = std.StringHashMap(void).init(alloc);
    defer pin_set.deinit();
    for (opts.pin_refs) |ref| try pin_set.put(try upper(alloc, ref), {});
    var unplaced_set = std.StringHashMap(void).init(alloc);
    defer unplaced_set.deinit();
    var autofill_set = std.StringHashMap(void).init(alloc);
    defer autofill_set.deinit();
    if (opts.spec) |sp| {
        for (sp.unplaced) |ref| try unplaced_set.put(try upper(alloc, ref), {});
        for (sp.auto_filled) |ref| try autofill_set.put(try upper(alloc, ref), {});
    }

    // ref|pad → full net name, so pads/airwires can resolve their net.
    var pad_net = std.StringHashMap([]const u8).init(alloc);
    defer pad_net.deinit();
    for (p.nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(alloc, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pad_net.put(key, net.name);
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
    var cmp_idx = std.StringHashMap(usize).init(alloc);
    defer cmp_idx.deinit();
    if (opts.compare) |c| for (c.parts, 0..) |cp, i| try cmp_idx.put(cp.ref_des, i);

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
    };

    if (opts.grid) ctx.drawGrid();
    ctx.drawBoardOutline();
    ctx.drawPours();
    if (opts.compare != null) ctx.drawCompareGhost();
    ctx.drawParts();
    ctx.drawBoardTexts();
    ctx.drawAirwires();
    ctx.drawLoops();
    if (opts.dims) ctx.drawDims();
    if (opts.compare != null) ctx.drawCompareArrows();
    if (opts.routed) |r| ctx.drawRouted(r);
    ctx.drawViolations(opts.violations);
    ctx.drawLabels();
    ctx.drawPinLabels();
    if (opts.critique) ctx.drawCritique();
    if (opts.blame) ctx.drawBlamePanel();
    if (!opts.bare) {
        ctx.drawHeader();
        ctx.drawLegend(opts.routed != null);
    }

    return cv;
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

/// Hubs to tile in a contact sheet, biggest first (the parts whose pin
/// neighbourhoods an agent actually needs to inspect).
const SHEET_MAX_TILES: usize = 6;
/// Closeup tiles per contact-sheet row.
const SHEET_COLS: u32 = 3;

/// Contact sheet: the whole board on top, then per-hub closeups with pad net
/// labels — one image answers both "what's the arrangement" and "what sits at
/// each IC's pins". Tile order is hub courtyard area, biggest first.
pub fn renderSheet(alloc: std.mem.Allocator, p: optimizer.Placement, opts: Options) png.Error![]u8 {
    var main_opts = opts;
    main_opts.crop = null;
    var main_cv = try renderCanvas(alloc, p, main_opts);
    defer main_cv.deinit();

    // Biggest hubs first.
    var hubs: std.ArrayListUnmanaged(usize) = .empty;
    defer hubs.deinit(alloc);
    for (p.parts, 0..) |part, pi| {
        if (part.kind != .hub) continue;
        try hubs.append(alloc, pi);
    }
    std.mem.sort(usize, hubs.items, p.parts, hubAreaDesc);
    const ntiles = @min(hubs.items.len, SHEET_MAX_TILES);
    if (ntiles == 0) return main_cv.toPng(alloc);

    const ncols: u32 = @min(@as(u32, @intCast(ntiles)), SHEET_COLS);
    const tile_w = @max(main_cv.w / ncols, MIN_W);
    var tiles: std.ArrayListUnmanaged(raster.Canvas) = .empty;
    defer {
        for (tiles.items) |*t| t.deinit();
        tiles.deinit(alloc);
    }
    for (hubs.items[0..ntiles]) |pi| {
        const part = p.parts[pi];
        const pin_one = try alloc.alloc([]const u8, 1);
        pin_one[0] = part.ref_des;
        var tcv = try renderCanvas(alloc, p, .{
            .width = tile_w,
            .bare = true,
            .crop = part.ref_des,
            .crop_r = @max(4.0, @max(part.hw, part.hh) + 3.0),
            .pin_refs = pin_one,
            .names = opts.names,
            .params = opts.params,
            .routed = opts.routed,
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
        tcv.text(4, 3, cap, 11, SHEET_CAP_COL, 1.0, .start);
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
    for (row_h) |h| total_h += h + SHEET_GAP_PX;
    var master = try raster.Canvas.init(alloc, main_cv.w, total_h, SS, BG);
    defer master.deinit();
    master.blit(&main_cv, 0, 0);
    var y = main_cv.h + SHEET_GAP_PX;
    for (0..nrows) |r| {
        for (0..ncols) |c| {
            const i = r * ncols + c;
            if (i >= tiles.items.len) break;
            master.blit(&tiles.items[i], @as(u32, @intCast(c)) * tile_w, y);
        }
        y += row_h[r] + SHEET_GAP_PX;
    }
    return master.toPng(alloc);
}

/// Gap (final px) between contact-sheet rows.
const SHEET_GAP_PX: u32 = 4;
/// Tile-caption colour (matches the dim header text).
const SHEET_CAP_COL = raster.Rgb.hex("8b949e");

fn hubAreaDesc(parts: []const optimizer.Part, a: usize, b: usize) bool {
    return parts[a].hw * parts[a].hh > parts[b].hw * parts[b].hh;
}

/// Populate `hot_nets` (full net names matching a `highlight_nets` token) and
/// `hot_refs` (uppercased `highlight_refs`).
fn buildHighlightSets(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    opts: Options,
    hot_nets: *std.StringHashMap(void),
    hot_refs: *std.StringHashMap(void),
) !void {
    for (opts.highlight_refs) |ref| try hot_refs.put(try upper(alloc, ref), {});
    if (opts.highlight_nets.len == 0) return;
    var tokens = try alloc.alloc([]const u8, opts.highlight_nets.len);
    for (opts.highlight_nets, 0..) |t, i| tokens[i] = try upper(alloc, t);
    for (p.nets) |net| {
        for (tokens) |tok| {
            if (eqUpper(net.name, tok) or eqUpper(netKey(net.name), tok) or eqUpper(shortName(net.name), tok)) {
                try hot_nets.put(net.name, {});
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
    hot_nets: *std.StringHashMap(void),
    hot_refs: *std.StringHashMap(void),
    pad_net: *std.StringHashMap([]const u8),
    opts: Options,
    /// Per-part objective blame, normalized to [0,1]; empty when blame is off.
    blame_norm: []const f64,
    /// ref_des → index into `opts.compare.?.parts`; empty when no compare layout.
    cmp_idx: *std.StringHashMap(usize),
    /// Uppercased `pin_refs` (pad-net-label targets); empty when none requested.
    pin_set: *std.StringHashMap(void),
    /// Uppercased refs the `(placement …)` spec left unplaced (staging band).
    unplaced_set: *std.StringHashMap(void),
    /// Uppercased refs the pin-hug auto-fill placed (spec-unlisted, amber).
    autofill_set: *std.StringHashMap(void),

    fn xpx(self: *Ctx, mm: f64) f32 {
        return @floatCast((mm - self.minx + MARGIN_MM) * self.scale);
    }
    fn ypx(self: *Ctx, mm: f64) f32 {
        return self.yoff + @as(f32, @floatCast((mm - self.miny + MARGIN_MM) * self.scale));
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
    /// The label `names` mode picks for part `pi`: ref-des, the spec's stable
    /// origin name (fallback ref when a part has none), or `REF=ORIGIN`.
    fn partLabel(self: *Ctx, pi: usize, buf: []u8) []const u8 {
        const ref = self.p.parts[pi].ref_des;
        if (self.opts.names == .ref) return ref;
        const origin = if (pi < self.p.instances.len) self.p.instances[pi].origin_key else "";
        if (origin.len == 0 or std.mem.eql(u8, origin, ref)) return ref;
        if (self.opts.names == .origin) return origin;
        return std.fmt.bufPrint(buf, "{s}={s}", .{ ref, origin }) catch ref;
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

    fn drawParts(self: *Ctx) void {
        for (self.p.parts, 0..) |part, pi| {
            const active = self.partActive(part);
            const base_a: f32 = if (active) 1.0 else DIM_A;
            const stroke = if (part.kind == .hub) HUB_STROKE else PASSIVE_STROKE;
            // Courtyard (rotated quad about the box centre — offset from the
            // part origin when the library rect is off-origin).
            const court = [_][2]f32{
                self.lp(part, part.ccx - part.hw, part.ccy - part.hh), self.lp(part, part.ccx + part.hw, part.ccy - part.hh),
                self.lp(part, part.ccx + part.hw, part.ccy + part.hh), self.lp(part, part.ccx - part.hw, part.ccy + part.hh),
            };
            // Blame heatmap tints the fill green→red by objective share; the cool
            // baseline COURT_FILL otherwise (blue wash for bottom-side parts).
            const fill = if (self.opts.blame and pi < self.blame_norm.len)
                blameColor(self.blame_norm[pi])
            else if (part.side == .bottom)
                COURT_FILL_BOT
            else
                COURT_FILL;
            self.cv.fillPoly(&court, fill, base_a);
            self.cv.strokePath(&court, .closed, self.outlineW(active), stroke, base_a);
            if (self.focus and active and (self.refHot(part.ref_des))) {
                self.cv.strokePath(&court, .closed, self.outlineW(true) + self.pw(1.5), ACCENT, 0.9);
            }
            // A part the `(placement …)` spec left unplaced sits in a staging
            // band — cross it out so it never reads as a deliberate placement.
            if (self.isUnplaced(part.ref_des)) {
                self.cv.fillPoly(&court, DRC_COL, 0.12);
                self.cv.strokePath(&court, .closed, self.outlineW(true), DRC_COL, 0.9);
                self.cv.line(court[0][0], court[0][1], court[2][0], court[2][1], self.pw(1.0), DRC_COL, 0.8, .butt);
                self.cv.line(court[1][0], court[1][1], court[3][0], court[3][1], self.pw(1.0), DRC_COL, 0.8, .butt);
            } else if (self.isAutoFilled(part.ref_des)) {
                // Auto-filled: a usable position the spec doesn't pin — amber
                // outline so the agent can tell authored from solver-chosen.
                self.cv.strokePath(&court, .closed, self.outlineW(true), ACCENT, 0.75);
            }
            // Silk (footprint-local, rotates with the part).
            for (part.silk_lines) |sl| {
                const a = self.lp(part, sl.x1, sl.y1);
                const b = self.lp(part, sl.x2, sl.y2);
                self.cv.line(a[0], a[1], b[0], b[1], self.pw(0.8), SILK, base_a, .round);
            }
            for (part.silk_circles) |sc| {
                const c = self.lp(part, sc.cx, sc.cy);
                self.cv.ring(c[0], c[1], @max(self.len(sc.r), self.pw(1)), self.pw(0.8), SILK, base_a);
            }
            self.drawPads(part, active);
        }
    }

    fn drawPads(self: *Ctx, part: optimizer.Part, active: bool) void {
        for (part.pads) |pad| {
            const hot = self.focus and self.netHot(self.netOf(part.ref_des, pad.number));
            const col = if (hot) ACCENT else if (part.side == .bottom) PAD_COL_BOT else PAD_COL;
            const a: f32 = if (hot or active) 1.0 else DIM_A;
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
            } else {
                const hw = pad.w / 2;
                const hh = pad.h / 2;
                const quad = [_][2]f32{
                    self.lp(part, pad.x - hw, pad.y - hh), self.lp(part, pad.x + hw, pad.y - hh),
                    self.lp(part, pad.x + hw, pad.y + hh), self.lp(part, pad.x - hw, pad.y + hh),
                };
                self.cv.fillPoly(&quad, col, a);
            }
            // Drilled bore: punch a board-coloured hole through thru/npth pads so
            // through-hole parts and mounting holes read as holes, not solid copper.
            if (pad.drill > 0) {
                const c = self.lp(part, pad.x, pad.y);
                const hr = @max(self.len(pad.drill / 2), self.pw(0.6));
                self.cv.disc(c[0], c[1], hr, PAD_HOLE, a);
            }
        }
    }

    fn drawAirwires(self: *Ctx) void {
        for (self.p.links) |l| {
            // A net a declared plane/pour carries is connected by the copper
            // sheet itself — drop its airwire, matching the page blob's filter
            // (the implicit model's grounds never spring links at all).
            if (l.net.len > 0 and self.p.rules.carriesPlane(l.net)) continue;
            const a_pt = self.lp(self.p.parts[l.a], l.ax, l.ay);
            const b_pt = self.lp(self.p.parts[l.b], l.bx, l.by);
            const col = awColor(l.kind);
            const base_w: f64 = if (l.kind == .signal) 0.7 else 1.3;
            var alpha: f32 = if (l.kind == .signal) 0.55 else 0.9;
            var col2 = col;
            var w = base_w;
            if (self.focus) {
                const net = self.netOf(self.p.parts[l.a].ref_des, self.nearestPad(l.a, l.ax, l.ay));
                if (self.netHot(net)) {
                    col2 = ACCENT;
                    alpha = 1.0;
                    w = 1.6;
                } else {
                    alpha = DIM_A * 0.6;
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
            const a: f32 = if (dim) DIM_A * 0.6 else 0.9;
            // Power-leg ribbon width grows with the loop's inductance share, so
            // the loops dominating the objective read as the fattest.
            const nh = optimizer.loopNh(self.p.parts, L);
            const w = std.math.clamp(1.0 + nh * 0.7, 1.0, 5.0);
            self.cv.line(cp[0], cp[1], pp[0], pp[1], self.pw(w), AW_PROX, a, .butt);
            // L2 ground-return path cap_gnd → cap_pwr → hub_pwr → hub_gnd.
            const ret = [_][2]f32{ cg, cp, pp, gp };
            self.cv.strokePath(&ret, .open, self.pw(1.1), LOOP_RET, a * 0.85);
            if (self.opts.loop_labels) {
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d:.1}nH", .{nh}) catch "";
                self.cv.text((cp[0] + pp[0]) / 2, (cp[1] + pp[1]) / 2 - self.pw(6), s, self.pw(8), AW_PROX, a, .middle);
            }
        }
    }

    fn drawRouted(self: *Ctx, r: router.RouteResult) void {
        for (r.tracks) |t| {
            const col = if (t.layer == 0) TRACK_TOP else TRACK_BOT;
            self.cv.line(self.xpx(t.x1), self.ypx(t.y1), self.xpx(t.x2), self.ypx(t.y2), @max(self.len(t.width), self.pw(0.6)), col, 0.92, .round);
        }
        for (r.vias) |v| {
            const c = [_]f32{ self.xpx(v.x), self.ypx(v.y) };
            const rad = @max(self.len(v.dia / 2), self.pw(1.2));
            self.cv.disc(c[0], c[1], rad, VIA_COL, 1.0);
            self.cv.disc(c[0], c[1], rad * 0.45, VIA_HOLE, 1.0);
        }
    }

    fn drawViolations(self: *Ctx, violations: []const drc.Violation) void {
        for (violations) |v| {
            const c = [_]f32{ self.xpx(v.x), self.ypx(v.y) };
            self.cv.ring(c[0], c[1], self.pw(5), self.pw(1.6), DRC_COL, 1.0);
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
            self.cv.line(a[0], a[1], b[0], b[1], self.pw(0.6), TEXT_COL, 0.75, .round);
            var buf: [24]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.2}mm", .{mm}) catch "";
            self.cv.text((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 + self.pw(2), s, self.pw(8), TEXT_COL, 0.95, .middle);
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
                self.cv.strokePath(pts[0..n], .closed, self.pw(1.4), EDGE_COL, 0.9);
                self.labelBoardDims(r, x0, y0);
                return;
            }
        }
        const x1 = self.xpx(r.minx + r.w);
        const y1 = self.ypx(r.miny + r.h);
        const pts = [_][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 }, .{ x0, y0 } };
        self.cv.strokePath(&pts, .open, self.pw(1.4), EDGE_COL, 0.9);
        self.labelBoardDims(r, x0, y0);
    }

    /// The outline's W×H dimension label at its bbox top-left corner.
    fn labelBoardDims(self: *Ctx, r: optimizer.BoardRect, x0: f32, y0: f32) void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.0}x{d:.0}mm", .{ r.w, r.h }) catch "";
        self.cv.text(x0 + self.pw(4), y0 + self.pw(3), s, self.pw(8), EDGE_COL, 0.9, .start);
    }

    /// Declared outer-layer copper pours, under the parts: a translucent
    /// wash across the pour region (the same rect the Gerber pours — board
    /// outline, or the parts-bbox fallback) plus a "NET pour · F.Cu/B.Cu"
    /// label in the layer's track colour, so a poured face reads as copper
    /// in the PNG an MCP agent inspects instead of being invisible.
    fn drawPours(self: *Ctx) void {
        var n: f32 = 0;
        for ([_]optimizer.Side{ .bottom, .top }) |side| {
            const net = self.p.rules.pourNetOnSide(side) orelse continue;
            const r = export_fab.outlineRect(self.p);
            const x0 = self.xpx(r.minx);
            const y0 = self.ypx(r.miny);
            const col = if (side == .top) TRACK_TOP else TRACK_BOT;
            self.cv.fillRect(x0, y0, self.len(r.w), self.len(r.h), col, if (side == .top) 0.10 else 0.12);
            var buf: [96]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{s} pour - {s}", .{ net, if (side == .top) "F.Cu" else "B.Cu" }) catch "";
            self.cv.text(x0 + self.pw(4), self.ypx(r.miny + r.h) - self.pw(12) - n * self.pw(11), s, self.pw(8), col, 0.95, .start);
            n += 1;
        }
    }

    /// A faint 1/2/5 mm reference grid with axis tick labels, under everything.
    fn drawGrid(self: *Ctx) void {
        const step = gridStep(self.p.maxx - self.p.minx, self.p.maxy - self.p.miny);
        const top = self.yoff;
        const bot = @as(f32, @floatFromInt(self.cv.h - LEGEND_H));
        const left = self.xpx(self.minx - MARGIN_MM);
        const right = self.xpx(self.p.maxx + MARGIN_MM);
        var gx = @ceil((self.minx - MARGIN_MM) / step) * step;
        while (gx <= self.p.maxx + MARGIN_MM + 1e-6) : (gx += step) {
            const px = self.xpx(gx);
            self.cv.line(px, top, px, bot, self.pw(0.4), GRID_COL, 0.5, .butt);
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.0}", .{gx}) catch "";
            self.cv.text(px, bot - self.pw(9), s, self.pw(7), TEXT_DIM, 0.7, .middle);
        }
        var gy = @ceil((self.miny - MARGIN_MM) / step) * step;
        while (gy <= self.p.maxy + MARGIN_MM + 1e-6) : (gy += step) {
            const py = self.ypx(gy);
            self.cv.line(left, py, right, py, self.pw(0.4), GRID_COL, 0.5, .butt);
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.0}", .{gy}) catch "";
            self.cv.text(left + self.pw(2), py - self.pw(3), s, self.pw(7), TEXT_DIM, 0.7, .start);
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
            self.cv.strokePath(&court, .closed, self.pw(0.8), TEXT_DIM, 0.45);
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
            self.cv.line(a[0], a[1], b[0], b[1], self.pw(1.0), ACCENT, 0.85, .round);
            self.cv.disc(b[0], b[1], self.pw(2.0), ACCENT, 0.9);
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
            self.cv.disc(m[0], m[1], r, BG, 0.7);
            self.cv.ring(m[0], m[1], r, self.pw(1.5), ACCENT, 0.95);
            var nb: [4]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "{d}", .{k + 1}) catch "";
            self.cv.text(m[0], m[1] - self.pw(4), s, self.pw(8), ACCENT, 1.0, .middle);
        }
        // Panel on the right edge; drops below the blame panel when both are on.
        const x = @as(f32, @floatFromInt(self.cv.w)) - self.pw(215);
        var y = self.yoff + self.pw(6) + (if (self.opts.blame) self.pw(50) else @as(f32, 0));
        self.cv.text(x, y, "CRITIQUE (fix first)", self.pw(8), TEXT_COL, 0.95, .start);
        y += self.pw(12);
        for (0..n) |k| {
            self.cv.text(x, y, lines[k], self.pw(8), ACCENT, 0.95, .start);
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
        self.cv.text(x, y, "WORST (blame)", self.pw(8), TEXT_COL, 0.95, .start);
        y += self.pw(12);
        for (0..3) |k| {
            if (val[k] < 0) break;
            var buf: [48]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}. {s}  {d:.0}%", .{ k + 1, self.p.parts[idx[k]].ref_des, val[k] * 100 }) catch "";
            self.cv.text(x, y, s, self.pw(8), blameColor(val[k]), 0.95, .start);
            y += self.pw(11);
        }
    }

    fn drawLabels(self: *Ctx) void {
        const h = self.pw(9);
        for (self.p.parts, 0..) |part, pi| {
            const active = self.partActive(part);
            if (self.focus and !active) continue;
            const eff_hh = if (isQuarter(part.rot)) part.hw else part.hh;
            const cx = self.xpx(part.x);
            const top = self.ypx(part.y) - self.len(eff_hh) - h - self.pw(2);
            const col = if (self.isUnplaced(part.ref_des))
                DRC_COL
            else if (self.focus and self.refHot(part.ref_des))
                ACCENT
            else if (part.kind == .hub) HUB_STROKE else PASSIVE_STROKE;
            var buf: [96]u8 = undefined;
            self.cv.text(cx, top, self.partLabel(pi, &buf), h, col, 1.0, .middle);
        }
    }

    /// Board-level silkscreen text (the Text tool / sidecar `texts[]`): each
    /// glyph row's lit-pixel runs become one stroked segment in mm-space, then
    /// project to px — the same 5x7 vector font the Gerber silk emits, so the
    /// PNG shows exactly what will be fabricated. Cap height scales the pixel
    /// pitch; bottom-side text mirrors x; the string rotates about its anchor.
    fn drawBoardTexts(self: *Ctx) void {
        const Pen = struct {
            ctx: *Ctx,
            cx: f64,
            cy: f64,
            gx0: f64,
            pitch: f64,
            mirror: bool,
            ca: f64,
            sa: f64,
            fn place(self2: @This(), lxpx: f64, ly: f64) [2]f32 {
                const lx = if (self2.mirror) -lxpx else lxpx;
                const wx = self2.cx + lx * self2.ca - ly * self2.sa;
                const wy = self2.cy + lx * self2.sa + ly * self2.ca;
                return .{ self2.ctx.xpx(wx), self2.ctx.ypx(wy) };
            }
            fn emit(self2: @This(), run: font.Run) error{}!void {
                const ly = (@as(f64, @floatFromInt(run.r)) - 3.0) * self2.pitch;
                const lx1 = self2.gx0 + (@as(f64, @floatFromInt(run.c0)) + 0.5) * self2.pitch;
                const lx2 = self2.gx0 + (@as(f64, @floatFromInt(run.c1)) + 0.5) * self2.pitch;
                const a = self2.place(lx1, ly);
                const b = self2.place(lx2, ly);
                // Stroke width = the ~0.15 mm silk width projected to px (min 1 px
                // so a zoomed-out label stays legible). A 1-px run draws as a dab.
                const w = @max(self2.ctx.len(0.15), self2.ctx.pw(1.0));
                self2.ctx.cv.line(a[0], a[1], b[0], b[1], w, SILK, 1.0, .round);
            }
        };
        for (self.opts.texts) |t| {
            if (t.text.len == 0) continue;
            const pitch = if (t.size > 0) t.size / @as(f64, @floatFromInt(font.GH)) else font.DEFAULT_SIZE_MM / @as(f64, @floatFromInt(font.GH));
            const adv = @as(f64, @floatFromInt(font.GW + 1)) * pitch;
            const total = @as(f64, @floatFromInt(t.text.len)) * adv - pitch;
            const a = @mod(t.rot, 360.0) * std.math.pi / 180.0;
            const ca = @cos(a);
            const sa = @sin(a);
            for (t.text, 0..) |ch, k| {
                const gx0 = -total / 2 + @as(f64, @floatFromInt(k)) * adv;
                const pen = Pen{ .ctx = self, .cx = t.x, .cy = t.y, .gx0 = gx0, .pitch = pitch, .mirror = t.bottom, .ca = ca, .sa = sa };
                // The emit callback is infallible (error{}); the exhaustive
                // switch on the empty error set is a no-op, not a swallowed error.
                font.glyphRuns(ch, error{}, pen, Pen.emit) catch |err| switch (err) {};
            }
        }
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
                self.cv.fillRect(c[0] - tw / 2 - self.pw(1), ty - self.pw(1), tw + self.pw(2), h + self.pw(2), BG, 0.55);
                self.cv.text(c[0], ty, s, h, TEXT_COL, 1.0, .middle);
            }
        }
    }

    fn drawHeader(self: *Ctx) void {
        const pad = self.pw(6);
        if (self.opts.title.len > 0) {
            self.cv.text(pad, self.pw(3), self.opts.title, self.pw(13), TEXT_COL, 1.0, .start);
        }
        // Objective decomposition — every render is self-documenting.
        const b = self.p.breakdown;
        var buf: [200]u8 = undefined;
        const score = std.fmt.bufPrint(
            &buf,
            "obj {d:.1}  |  hpwl {d:.1}  loop {d:.1}nH  cmp {d:.0}mm2  cong {d:.1}",
            .{ b.objective, b.hpwl, b.loop_nh, b.alignment, b.congestion },
        ) catch "";
        self.cv.text(pad, self.pw(20), score, self.pw(9), TEXT_DIM, 1.0, .start);
        // Top-right: staging status, so a board that left parts in the band (or
        // auto-filled some) is impossible to mistake for a finished layout. Auto-
        // filled parts are usable but unpinned — amber, between red and green.
        if (self.opts.spec) |sp| {
            const xr = @as(f32, @floatFromInt(self.cv.w)) - pad;
            if (sp.unplaced.len > 0) {
                var buf3: [64]u8 = undefined;
                const s3 = std.fmt.bufPrint(&buf3, "{d} UNPLACED (staged)", .{sp.unplaced.len}) catch "";
                self.cv.text(xr, self.pw(3), s3, self.pw(10), DRC_COL, 1.0, .end);
                if (sp.auto_filled.len > 0) {
                    var buf4: [48]u8 = undefined;
                    const s4 = std.fmt.bufPrint(&buf4, "+ {d} AUTO-FILLED", .{sp.auto_filled.len}) catch "";
                    self.cv.text(xr, self.pw(15), s4, self.pw(9), ACCENT, 1.0, .end);
                }
            } else if (sp.auto_filled.len > 0) {
                var buf3: [64]u8 = undefined;
                const s3 = std.fmt.bufPrint(&buf3, "{d} AUTO-FILLED", .{sp.auto_filled.len}) catch "";
                self.cv.text(xr, self.pw(3), s3, self.pw(10), ACCENT, 1.0, .end);
            }
        }
        // Third line: compare Δ if diffing, else the focus caption.
        if (self.opts.compare) |c| {
            var buf2: [64]u8 = undefined;
            const d = b.objective - c.breakdown.objective;
            const sign = if (d >= 0) "+" else "-";
            const s2 = std.fmt.bufPrint(&buf2, "vs base: d_obj {s}{d:.1} ({s})", .{ sign, @abs(d), if (d <= 0) "better" else "worse" }) catch "";
            self.cv.text(pad, self.pw(32), s2, self.pw(9), if (d <= 0) GOOD_COL else DRC_COL, 1.0, .start);
        } else if (self.focus) {
            self.cv.text(pad, self.pw(32), self.caption, self.pw(8), ACCENT, 1.0, .start);
        }
    }

    fn drawLegend(self: *Ctx, routed: bool) void {
        const y: f32 = @as(f32, @floatFromInt(self.cv.h - LEGEND_H)) + self.pw(7);
        var x = self.pw(6);
        x = self.legendItem(x, y, AW_PROX, "HOT LOOP");
        x = self.legendItem(x, y, AW_GND, "GND");
        x = self.legendItem(x, y, AW_SIG, "SIGNAL");
        if (routed) {
            x = self.legendItem(x, y, TRACK_TOP, "F.CU");
            x = self.legendItem(x, y, TRACK_BOT, "B.CU");
            x = self.legendItem(x, y, VIA_COL, "VIA");
        }
        if (self.focus) x = self.legendItem(x, y, ACCENT, "FOCUS");
        if (self.opts.spec) |sp| {
            if (sp.unplaced.len > 0) x = self.legendItem(x, y, DRC_COL, "UNPLACED");
            if (sp.auto_filled.len > 0) x = self.legendItem(x, y, ACCENT, "AUTO-FILLED");
        }
    }

    fn legendItem(self: *Ctx, x: f32, y: f32, col: Rgb, label: []const u8) f32 {
        const sw = self.pw(8);
        self.cv.fillRect(x, y, sw, sw, col, 1.0);
        const tx = x + sw + self.pw(3);
        const h = self.pw(8);
        self.cv.text(tx, y, label, h, TEXT_DIM, 1.0, .start);
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
    if (kind == .proximity) return AW_PROX;
    if (kind == .ground) return AW_GND;
    return AW_SIG;
}

/// One channel of a linear colour blend.
fn mixByte(a: u8, b: u8, t: f64) u8 {
    const af: f64 = @floatFromInt(a);
    const bf: f64 = @floatFromInt(b);
    return @intFromFloat(@round(af + (bf - af) * t));
}
/// Blend two colours; `t` clamped to [0,1].
fn lerpRgb(a: Rgb, b: Rgb, t: f64) Rgb {
    const tt = std.math.clamp(t, 0, 1);
    return .{ .r = mixByte(a.r, b.r, tt), .g = mixByte(a.g, b.g, tt), .b = mixByte(a.b, b.b, tt) };
}
/// Heatmap colour for a normalized blame value: cheap (cool) → expensive (hot).
fn blameColor(t: f64) Rgb {
    return if (t < 0.5) lerpRgb(BLAME_LO, BLAME_MID, t * 2) else lerpRgb(BLAME_MID, BLAME_HI, (t - 0.5) * 2);
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
    var b: std.ArrayListUnmanaged(u8) = .empty;
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

fn joinInto(b: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, items: []const []const u8) std.mem.Allocator.Error!void {
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
fn isQuarter(rot: f64) bool {
    const q = @mod(@mod(rot, 360.0) + 360.0, 360.0);
    return q == 90.0 or q == 270.0;
}
/// True if the uppercased `s` is a member of `set` (whose keys are uppercased,
/// inserted via `upper` with no length cap). The stack buffer covers realistic
/// refs (incl. deep sub-block paths); a pathologically long `s` falls back to a
/// case-insensitive linear scan of the set so the lookup can never silently
/// miss a key the insertion side accepted — the two paths agree on membership.
fn upperInSet(set: *std.StringHashMap(void), s: []const u8) bool {
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
