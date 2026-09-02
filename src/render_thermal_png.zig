//! The heat-zone image: one solved cooling scenario painted over the board it
//! was solved on, served as `GET /api/pcb-png/:name?thermal=1` and returned by
//! the `get_pcb_layout_image` CLI tool with `thermal:true`.
//!
//! `/api/thermal/:name` already answers the same question in numbers, and the
//! numbers are the authority. What they cannot do is show WHERE the heat is: a
//! reader wants to see that the hot corner is the one with the buck in it, that
//! the MCU is sitting in its plume, and that the far side of the board is doing
//! no work. That is a picture, and this module draws it.
//!
//! Everything on it is the same solve the facts endpoint reports — the caller
//! hands over a solved `ScenarioResult` plus the absolute-°C `Row`
//! `thermal_scenarios.zig` derived from it, so the image cannot describe a
//! different board, a different scenario, or a different ambient than the JSON.
//! Nothing here re-solves anything.
//!
//! Four things carry the field, so no single one of them has to be trusted
//! alone:
//!
//!   * the colour ramp (deep blue → cyan → yellow → red);
//!   * isotherm lines at fixed fractions of the absolute temperature scale,
//!     which read in greyscale and under any colour blindness;
//!   * each powered part's junction temperature printed on it in degrees; and
//!   * the legend bar, captioned with the absolute temperatures its two ends
//!     stand for at the ambient the caller asked about.
//!
//! Text is drawn through `raster`'s 5×7 ASCII font, which has no degree sign —
//! so a temperature reads `60C`, not `60 °C`.

const std = @import("std");
const board_theme = @import("board_theme.zig");
const net_name = @import("net_name.zig");
const optimizer = @import("placement/optimizer.zig");
const outline = @import("placement/outline.zig");
const png = @import("png.zig");
const raster = @import("raster.zig");
const render_pcb_png = @import("render_pcb_png.zig");
const thermal_field = @import("placement/thermal_field.zig");
const thermal_scenarios = @import("thermal_scenarios.zig");

const Rgb = raster.Rgb;

/// A theme colour as raster channels (the theme owns the one hex parser).
fn rgbOf(hex: []const u8) Rgb {
    const c = board_theme.channels(hex);
    return .{ .r = c.r, .g = c.g, .b = c.b };
}

const bg = rgbOf(board_theme.background);
const text_col = rgbOf(board_theme.text);
const text_dim = rgbOf(board_theme.text_dim);
const outline_col = rgbOf(board_theme.edge_cuts);
const part_col = rgbOf(board_theme.silk_front);
const marker_col = rgbOf(board_theme.silk_front);
const warn_col = rgbOf(board_theme.drc);

/// Blank margin (mm) around the drawn board — the layout PNG's own constant, so
/// a reader flipping between the two images sees the same board framed the same
/// way rather than two nearly-identical crops.
const view_margin_mm = render_pcb_png.view_margin_mm;
const min_w: u32 = 400;
const max_w: u32 = 2200;
const max_h: u32 = 2600;
/// Supersample factor, as in the layout renderer.
const ss: u32 = 2;
const header_h_px: u32 = 46;
/// Height of the colour-scale band under the board (px). Deliberately taller
/// than the layout PNG's swatch legend: this one carries a gradient bar with a
/// number printed at each end.
const scale_band_px: u32 = 34;
/// Side of the square block the field is painted in, in final pixels. One
/// bilinear sample per block: 2 px is visually continuous at every width this
/// renderer emits and costs a quarter of a per-pixel walk.
const field_block_px: f32 = 2;
/// Cell height of a part label in final pixels.
const label_h: f32 = 9;
/// Absolute endpoints used by every thermal image. Temperatures outside the
/// range clamp to its nearest colour.
const scale_min_c: f64 = 25;
const scale_max_c: f64 = 125;
/// Fractions of the fixed scale an isotherm is drawn at — the hue-free channel
/// that keeps the field's shape readable in greyscale.
const isotherms = [_]f64{ 0.2, 0.4, 0.6, 0.8 };

/// One stop of the heat ramp.
const Stop = struct { t: f64, c: Rgb };

/// The heat ramp, cold to hot.
///
/// Luminance climbs monotonically from the deep-blue floor through cyan to
/// yellow — which is what makes the cold two thirds readable in greyscale and
/// under red-green colour blindness — and the hot end then turns red. That last
/// step is a deliberate, bounded exception: a strictly luminance-monotone ramp
/// cannot end in a saturated red at all (it would have to end in pale pink),
/// and "red is hottest" is the convention every reader of a thermal image
/// already has. The isotherms, the per-part temperatures and the numeric legend
/// are what carry the hot end for a reader who cannot use the hue.
const ramp = [_]Stop{
    .{ .t = 0.00, .c = Rgb.hex("071438") },
    .{ .t = 0.28, .c = Rgb.hex("1a5fc8") },
    .{ .t = 0.52, .c = Rgb.hex("2fc4d6") },
    .{ .t = 0.76, .c = Rgb.hex("f2dc5a") },
    .{ .t = 1.00, .c = Rgb.hex("e8402a") },
};

/// The heat ramp at `t` ∈ [0,1], linear between stops.
pub fn rampColor(t: f64) Rgb {
    const clamped = std.math.clamp(if (std.math.isFinite(t)) t else 0, 0.0, 1.0);
    var i: usize = 1;
    while (i < ramp.len and clamped > ramp[i].t) i += 1;
    const lo = ramp[i - 1];
    const hi = ramp[@min(i, ramp.len - 1)];
    const span = hi.t - lo.t;
    const k = if (span > 0) (clamped - lo.t) / span else 0;
    return .{
        .r = mixByte(lo.c.r, hi.c.r, k),
        .g = mixByte(lo.c.g, hi.c.g, k),
        .b = mixByte(lo.c.b, hi.c.b, k),
    };
}

fn mixByte(a: u8, b: u8, t: f64) u8 {
    const af: f64 = @floatFromInt(a);
    const bf: f64 = @floatFromInt(b);
    return @intFromFloat(std.math.clamp(@round(af + (bf - af) * t), 0, 255));
}

/// Everything the image draws, resolved by the caller so the picture and the
/// facts JSON can never be about different boards. It is `thermal_scenarios`'
/// own pair rather than a second shape of the same data: a renderer with its
/// own view type is a renderer that can be handed one scenario's field under
/// another's numbers.
pub const View = thermal_scenarios.Painted;

/// Framing and captioning.
pub const Options = struct {
    /// Requested output width in px (clamped); height follows the board.
    width: u32 = 1200,
    /// Caption shown top-left (typically the design name).
    title: []const u8 = "",
    /// Ambient the absolute temperatures were computed at (°C).
    ambient_c: f64 = 25,
    /// True when the rectangle solved over is the parts' bounding box rather
    /// than an authored `(board …)` outline. Said on the image, because a board
    /// bigger than its parts spreads more heat and the two answers differ.
    inferred_outline: bool = false,
};

/// Render `view` over `p` to PNG bytes owned by `alloc`.
pub fn render(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    view: View,
    opts: Options,
) png.Error![]u8 {
    var cv = try renderCanvas(alloc, p, view, opts);
    defer cv.deinit();
    return cv.toPng(alloc);
}

/// The body of `render`, on a canvas the tests can read pixels off.
fn renderCanvas(
    alloc: std.mem.Allocator,
    p: optimizer.Placement,
    view: View,
    opts: Options,
) png.Error!raster.Canvas {
    const box = viewBox(p, view.result.grid);
    const cw_mm = @max(box[2] - box[0], 1.0) + 2 * view_margin_mm;
    const ch_mm = @max(box[3] - box[1], 1.0) + 2 * view_margin_mm;

    const board_w = std.math.clamp(opts.width, min_w, max_w);
    var scale = @as(f64, @floatFromInt(board_w)) / cw_mm;
    var board_h_f = ch_mm * scale;
    if (board_h_f > max_h) {
        scale = @as(f64, @floatFromInt(max_h)) / ch_mm;
        board_h_f = @floatFromInt(max_h);
    }
    const board_h: u32 = std.math.clamp(@as(u32, @intFromFloat(@round(@min(board_h_f, @as(f64, max_h))))), 1, max_h);

    var cv = try raster.Canvas.init(alloc, board_w, header_h_px + board_h + scale_band_px, ss, bg);
    errdefer cv.deinit();

    var ctx = Ctx{
        .cv = &cv,
        .scale = scale,
        .minx = box[0],
        .miny = box[1],
        .yoff = @floatFromInt(header_h_px),
        .p = p,
        .view = view,
        .opts = opts,
        .span = riseSpan(view.result.grid),
    };
    ctx.drawField();
    ctx.drawIsotherms();
    ctx.drawBoardOutline();
    ctx.drawCourtyards();
    ctx.drawLabels();
    ctx.drawHotspot();
    try ctx.drawHeader(alloc);
    ctx.drawLegend();
    return cv;
}

/// World viewport `[minx,miny,maxx,maxy]`: the solved grid's rectangle unioned
/// with the placed parts' bounding box, so a part sitting off the board edge is
/// still visible rather than cropped out of its own thermal picture.
fn viewBox(p: optimizer.Placement, grid: thermal_field.FieldGrid) [4]f64 {
    const cols: f64 = @floatFromInt(grid.cols);
    const rows: f64 = @floatFromInt(grid.rows);
    return .{
        @min(p.minx, grid.origin_x_mm),
        @min(p.miny, grid.origin_y_mm),
        @max(p.maxx, grid.origin_x_mm + cols * grid.cell_mm),
        @max(p.maxy, grid.origin_y_mm + rows * grid.cell_mm),
    };
}

/// The `[min, max]` rise in a solved field (°C). A field that is flat — a board
/// dissipating nothing — reports a zero span, and every cell then paints the
/// ramp's cold end rather than dividing by nothing.
fn riseSpan(grid: thermal_field.FieldGrid) [2]f64 {
    var lo: f32 = std.math.floatMax(f32);
    var hi: f32 = -std.math.floatMax(f32);
    var any = false;
    for (grid.rise_c, 0..) |v, i| {
        if (grid.active.len != 0 and grid.active[i] == 0) continue;
        any = true;
        lo = @min(lo, v);
        hi = @max(hi, v);
    }
    if (!any) return .{ 0, 0 };
    return .{ lo, hi };
}

const Ctx = struct {
    cv: *raster.Canvas,
    scale: f64,
    minx: f64,
    miny: f64,
    yoff: f32,
    p: optimizer.Placement,
    view: View,
    opts: Options,
    /// `[min, max]` rise in the field (°C), retained only to recognize a flat
    /// field that should not receive a hotspot marker.
    span: [2]f64,

    fn xpx(self: *Ctx, mm: f64) f32 {
        return @floatCast((mm - self.minx + view_margin_mm) * self.scale);
    }
    fn ypx(self: *Ctx, mm: f64) f32 {
        return self.yoff + @as(f32, @floatCast((mm - self.miny + view_margin_mm) * self.scale));
    }
    fn len(self: *Ctx, mm: f64) f32 {
        return @floatCast(mm * self.scale);
    }

    /// Where a rise sits on the fixed absolute ramp: 25 °C at 0 and 125 °C at
    /// 1. Values beyond either end clamp, so colours compare across scenarios.
    fn norm(self: *Ctx, rise: f64) f64 {
        const temp_c = self.opts.ambient_c + rise;
        return std.math.clamp((temp_c - scale_min_c) / (scale_max_c - scale_min_c), 0.0, 1.0);
    }

    /// Bilinear sample of the rise field at a world point, over the cell
    /// CENTRES — so the gradient is smooth instead of the solver's blocks.
    /// Outside the grid the edge value extends, which is what a caller painting
    /// the rim of the board sees.
    fn sample(self: *Ctx, x_mm: f64, y_mm: f64) f64 {
        const g = self.view.result.grid;
        if (g.cols == 0 or g.rows == 0) return 0;
        const fx = (x_mm - g.origin_x_mm) / g.cell_mm - 0.5;
        const fy = (y_mm - g.origin_y_mm) / g.cell_mm - 0.5;
        const cx = axisWeights(fx, g.cols);
        const cy = axisWeights(fy, g.rows);
        const points = [_]struct { c: usize, r: usize, weight: f64 }{
            .{ .c = cx.lo, .r = cy.lo, .weight = (1 - cx.t) * (1 - cy.t) },
            .{ .c = cx.hi, .r = cy.lo, .weight = cx.t * (1 - cy.t) },
            .{ .c = cx.lo, .r = cy.hi, .weight = (1 - cx.t) * cy.t },
            .{ .c = cx.hi, .r = cy.hi, .weight = cx.t * cy.t },
        };
        var weighted: f64 = 0;
        var total: f64 = 0;
        for (points) |point| {
            if (!g.isActive(point.c, point.r)) continue;
            weighted += point.weight * g.at(point.c, point.r);
            total += point.weight;
        }
        return if (total > 0) weighted / total else 0;
    }

    /// The heat field, painted in small square blocks over the solved
    /// rectangle. Only the grid's own rectangle is painted: the margin around
    /// it is board-less air and stays canvas.
    fn drawField(self: *Ctx) void {
        const g = self.view.result.grid;
        if (g.cols == 0 or g.rows == 0) return;
        const x0 = self.xpx(g.origin_x_mm);
        const y0 = self.ypx(g.origin_y_mm);
        const x1 = self.xpx(g.origin_x_mm + @as(f64, @floatFromInt(g.cols)) * g.cell_mm);
        const y1 = self.ypx(g.origin_y_mm + @as(f64, @floatFromInt(g.rows)) * g.cell_mm);
        var y = y0;
        while (y < y1) : (y += field_block_px) {
            var x = x0;
            while (x < x1) : (x += field_block_px) {
                const wx = self.minx - view_margin_mm + @as(f64, x + field_block_px / 2) / self.scale;
                const wy = self.miny - view_margin_mm + @as(f64, y - self.yoff + field_block_px / 2) / self.scale;
                if (self.p.board_poly) |poly| {
                    if (!outline.contains(poly, wx, wy)) continue;
                }
                const col = rampColor(self.norm(self.sample(wx, wy)));
                self.cv.fillRect(x, y, field_block_px, field_block_px, col, 1.0);
            }
        }
    }

    /// Isotherms at fixed fractions of the absolute 25–125 °C scale, drawn on
    /// the cell boundaries a threshold falls across. Deterministic and
    /// interpolation-free — the point is a hue-free contour, not a smooth curve.
    fn drawIsotherms(self: *Ctx) void {
        const g = self.view.result.grid;
        if (!(self.span[1] - self.span[0] > 0)) return;
        // Wide enough to read against the ramp it is drawn over, and it grows
        // with the image so a 2200 px render is not hairlines.
        const width: f32 = @max(@as(f32, @floatFromInt(self.cv.w)) / 500.0, 1.5);
        var r: usize = 0;
        while (r < g.rows) : (r += 1) {
            var c: usize = 0;
            while (c < g.cols) : (c += 1) {
                if (!g.isActive(c, r)) continue;
                const here = self.norm(g.at(c, r));
                if (c + 1 < g.cols and g.isActive(c + 1, r) and self.crosses(here, self.norm(g.at(c + 1, r)))) {
                    const x = self.xpx(g.origin_x_mm + @as(f64, @floatFromInt(c + 1)) * g.cell_mm);
                    self.cv.line(x, self.cellY(r), x, self.cellY(r + 1), width, bg, 0.6, .butt);
                }
                if (r + 1 < g.rows and g.isActive(c, r + 1) and self.crosses(here, self.norm(g.at(c, r + 1)))) {
                    const y = self.ypx(g.origin_y_mm + @as(f64, @floatFromInt(r + 1)) * g.cell_mm);
                    self.cv.line(self.cellX(c), y, self.cellX(c + 1), y, width, bg, 0.6, .butt);
                }
            }
        }
    }

    fn cellX(self: *Ctx, c: usize) f32 {
        const g = self.view.result.grid;
        return self.xpx(g.origin_x_mm + @as(f64, @floatFromInt(c)) * g.cell_mm);
    }
    fn cellY(self: *Ctx, r: usize) f32 {
        const g = self.view.result.grid;
        return self.ypx(g.origin_y_mm + @as(f64, @floatFromInt(r)) * g.cell_mm);
    }

    /// Does an isotherm threshold lie between two neighbouring cells?
    fn crosses(_: *Ctx, a: f64, b: f64) bool {
        for (isotherms) |level| {
            if ((a < level and b >= level) or (b < level and a >= level)) return true;
        }
        return false;
    }

    /// The authored board edge, when the design declared one.
    fn drawBoardOutline(self: *Ctx) void {
        if (self.p.board_poly) |poly| {
            if (poly.len < 3) return;
            var previous = poly[poly.len - 1];
            for (poly) |p| {
                self.cv.line(self.xpx(previous[0]), self.ypx(previous[1]), self.xpx(p[0]), self.ypx(p[1]), 1.5, outline_col, 0.9, .butt);
                previous = p;
            }
            return;
        }
        const r = self.p.board_rect orelse return;
        const x0 = self.xpx(r.minx);
        const y0 = self.ypx(r.miny);
        const x1 = self.xpx(r.minx + r.w);
        const y1 = self.ypx(r.miny + r.h);
        const pts = [_][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        self.cv.strokePath(&pts, .closed, 1.5, outline_col, 0.9);
    }

    /// Every part's courtyard box, drawn for all of them — an outline is one
    /// stroke and never collides into an unreadable smear the way text does.
    fn drawCourtyards(self: *Ctx) void {
        for (self.p.parts) |part| {
            const b = self.courtBox(part);
            const pts = [_][2]f32{ .{ b[0], b[1] }, .{ b[2], b[1] }, .{ b[2], b[3] }, .{ b[0], b[3] } };
            self.cv.strokePath(&pts, .closed, 1.2, part_col, 0.85);
        }
    }

    /// Part labels, placed in two passes because a dense board has nowhere near
    /// room for all of them and the ones that matter are not the numerous ones.
    ///
    /// Parts the screen could say something about go FIRST and are always
    /// drawn: their temperature is the whole reason this image exists. Every
    /// other part follows, and keeps its ref-des only when the text fits inside
    /// the part's own drawn box — the same "does the label fit the thing it
    /// names" rule `render_pcb_png.drawPinLabels` applies to pad labels — and
    /// only when it lands clear of every label already placed. Without that,
    /// measured on barracuda at 1000 px, five neighbouring 0402 refs printed on
    /// top of each other as `C140.39.38.3756` and a passive's ref merged into
    /// its neighbour's temperature as `U14 175C ESC182`.
    ///
    /// The placed-box list is the same idea `kicad_sch/textbox.zig` uses to
    /// COUNT colliding text on an emitted sheet; here it is used to prevent the
    /// collision instead of reporting it, because a raster has no second pass.
    fn drawLabels(self: *Ctx) void {
        var placed: std.ArrayList([4]f32) = .empty;
        defer placed.deinit(self.cv.alloc);
        self.placeLabels(&placed, true);
        self.placeLabels(&placed, false);
    }

    /// One placement pass. `powered` selects the parts it considers: true takes
    /// the ones with a temperature to report, false the rest.
    fn placeLabels(self: *Ctx, placed: *std.ArrayList([4]f32), powered: bool) void {
        for (self.p.parts, 0..) |part, pi| {
            if (self.reported(pi) != powered) continue;
            const court = self.courtBox(part);
            var buf: [96]u8 = undefined;
            const label = self.partLabel(pi, &buf);
            const tw = raster.Canvas.textWidth(label, label_h);
            // An unpowered part's ref is worth ink only where the part itself is
            // big enough to carry it; a 0402 at board scale is a few pixels wide
            // and its four-character ref is not.
            if (!powered and tw > court[2] - court[0]) continue;
            const slot = labelSlot(court, tw, placed.items, powered) orelse continue;
            self.drawLabel(slot, label);
            // Out of memory for the placed-box list degrades the LAYOUT (later
            // labels stop seeing this one) and not the image, so the drawing
            // carries on rather than failing a render over a bookkeeping slot.
            placed.append(self.cv.alloc, slot) catch return;
        }
    }

    /// A label on its dark backing chip, so it survives the bright end of the
    /// ramp as well as the dark one.
    fn drawLabel(self: *Ctx, box: [4]f32, s: []const u8) void {
        self.cv.fillRect(box[0], box[1], box[2] - box[0], box[3] - box[1], bg, 0.55);
        self.cv.text((box[0] + box[2]) / 2, box[1] + 1, s, label_h, text_col, 1.0, .middle);
    }

    /// The world-space courtyard of `part` in pixels, as `[x0,y0,x1,y1]`.
    fn courtBox(self: *Ctx, part: optimizer.Part) [4]f32 {
        const court = optimizer.worldCourtyard(&part);
        return .{
            self.xpx(court.minx),
            self.ypx(court.miny),
            self.xpx(court.minx + court.w),
            self.ypx(court.miny + court.h),
        };
    }

    /// Did the thermal screen report anything about this part?
    fn reported(self: *Ctx, pi: usize) bool {
        return pi < self.view.part_rows.len and self.view.part_rows[pi] != null;
    }

    /// `REF` for a part the screen said nothing about, `REF 60C` for one whose
    /// junction it computed, and `REF 60C ?` when that junction went through the
    /// estimated θJB convention rather than a declared figure.
    fn partLabel(self: *Ctx, pi: usize, buf: []u8) []const u8 {
        const ref = net_name.leaf(self.p.parts[pi].ref_des);
        if (pi >= self.view.part_rows.len) return ref;
        const row = self.view.part_rows[pi] orelse return ref;
        const tj = row.tj_c orelse return std.fmt.bufPrint(buf, "{s} {d:.0}C brd", .{ ref, row.board_c }) catch ref;
        const mark: []const u8 = if (row.jb_estimated) " est" else "";
        return std.fmt.bufPrint(buf, "{s} {d:.0}C{s}", .{ ref, tj, mark }) catch ref;
    }

    /// The board's hottest point, marked with an × and its temperature.
    fn drawHotspot(self: *Ctx) void {
        if (!(self.span[1] > self.span[0])) return; // a flat field has no hot spot
        const hs = self.view.row.hotspot;
        const x = self.xpx(hs.x_mm);
        const y = self.ypx(hs.y_mm);
        const r: f32 = @max(self.len(1.2), 5);
        self.cv.line(x - r, y - r, x + r, y + r, 2.0, marker_col, 1.0, .round);
        self.cv.line(x - r, y + r, x + r, y - r, 2.0, marker_col, 1.0, .round);
        var buf: [48]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "HOT {d:.0}C", .{hs.c}) catch return;
        const tw = raster.Canvas.textWidth(s, 9);
        self.cv.fillRect(x - tw / 2 - 1, y + r + 2, tw + 2, 11, bg, 0.6);
        self.cv.text(x, y + r + 3, s, 9, marker_col, 1.0, .middle);
    }

    /// Title, then the caption naming the scenario, the ambient the numbers are
    /// read at, and the ambient ceiling this scenario buys.
    fn drawHeader(self: *Ctx, alloc: std.mem.Allocator) std.mem.Allocator.Error!void {
        const pad: f32 = 6;
        if (self.opts.title.len > 0) {
            self.cv.text(pad, 3, self.opts.title, 13, text_col, 1.0, .start);
        }
        const scenario = try thermal_scenarios.scenarioLabel(
            alloc,
            self.view.row.scenario,
            self.view.row.heatsink,
        );
        var buf: [200]u8 = undefined;
        const caption = std.fmt.bufPrint(&buf, "{s} - ambient {d:.0}C - max ambient {s}", .{
            scenario,
            self.opts.ambient_c,
            try ceilingText(alloc, self.view.row.max_ambient),
        }) catch "";
        self.cv.text(pad, 20, caption, 9, text_dim, 1.0, .start);

        var note_buf: [160]u8 = undefined;
        const note = try self.headerNote(&note_buf);
        if (note.len > 0) self.cv.text(pad, 32, note, 9, warn_col, 1.0, .start);
    }

    /// The line under the caption: what this picture is NOT to be read as —
    /// an inferred outline, an unconverged solve, or parts the screen could not
    /// place. Empty when the image has nothing to qualify.
    fn headerNote(self: *Ctx, buf: []u8) std.mem.Allocator.Error![]const u8 {
        const skipped = self.view.row.skipped.len;
        if (!self.opts.inferred_outline and self.view.row.converged and skipped == 0) return "";
        var w = std.Io.Writer.fixed(buf);
        var sep: []const u8 = "";
        if (self.opts.inferred_outline) {
            w.print("no (board ...) outline - solved over the parts bounding box", .{}) catch return buf[0..w.end];
            sep = " - ";
        }
        if (!self.view.row.converged) {
            w.print("{s}solve did not converge", .{sep}) catch return buf[0..w.end];
            sep = " - ";
        }
        if (skipped > 0) {
            w.print("{s}{d} powered part(s) unplaced and not in the field", .{ sep, skipped }) catch return buf[0..w.end];
        }
        return buf[0..w.end];
    }

    /// The colour bar, captioned with its invariant absolute endpoints.
    fn drawLegend(self: *Ctx) void {
        const y: f32 = @as(f32, @floatFromInt(self.cv.h - scale_band_px)) + 8;
        const pad: f32 = 6;
        const bar_h: f32 = 10;
        const bar_w: f32 = @max(@as(f32, @floatFromInt(self.cv.w)) * 0.45, 120);
        var i: f32 = 0;
        while (i < bar_w) : (i += 1) {
            self.cv.fillRect(pad + i, y, 1, bar_h, rampColor(@as(f64, i) / @as(f64, bar_w - 1)), 1.0);
        }
        var lo_buf: [32]u8 = undefined;
        var hi_buf: [32]u8 = undefined;
        const lo = std.fmt.bufPrint(&lo_buf, "{d:.0}C", .{scale_min_c}) catch "";
        const hi = std.fmt.bufPrint(&hi_buf, "{d:.0}C", .{scale_max_c}) catch "";
        self.cv.text(pad, y + bar_h + 3, lo, 9, text_dim, 1.0, .start);
        self.cv.text(pad + bar_w, y + bar_h + 3, hi, 9, text_dim, 1.0, .end);
        self.cv.text(pad + bar_w + 12, y + 1, "BOARD COPPER, COLD TO HOT", 9, text_dim, 1.0, .start);
    }
};

/// The pixel box a label of width `tw` occupies when centred on `cx` with its
/// top at `top`, grown by the one-pixel backing chip it is drawn on — so two
/// labels that merely touch already count as colliding.
fn labelBox(cx: f32, top: f32, tw: f32) [4]f32 {
    return .{ cx - tw / 2 - 1, top - 1, cx + tw / 2 + 1, top + label_h + 1 };
}

/// Where a label of width `tw` goes for a part occupying `court`: above the
/// part, else — for a REPORTED part, which must be drawn — below it, and as a
/// last resort above anyway, because a temperature this image exists to show is
/// worth one collision. Null tells an unreported part to give up.
fn labelSlot(court: [4]f32, tw: f32, placed: []const [4]f32, powered: bool) ?[4]f32 {
    const cx = (court[0] + court[2]) / 2;
    const above = labelBox(cx, court[1] - label_h - 3, tw);
    if (!overlapsAny(placed, above)) return above;
    if (!powered) return null;
    const below = labelBox(cx, court[3] + 3, tw);
    return if (overlapsAny(placed, below)) above else below;
}

/// Does `box` overlap any box already placed? Linear over a list that holds at
/// most one entry per part, which on the densest board here is a few hundred.
fn overlapsAny(placed: []const [4]f32, box: [4]f32) bool {
    for (placed) |b| {
        if (box[0] < b[2] and b[0] < box[2] and box[1] < b[3] and b[1] < box[3]) return true;
    }
    return false;
}

/// The two cell indices and the weight between them for one axis of a bilinear
/// sample. Out-of-range coordinates clamp onto the edge cell, which is what
/// makes the sample well-defined right up to the rim of the board.
const AxisWeights = struct { lo: usize, hi: usize, t: f64 };

fn axisWeights(f: f64, count: usize) AxisWeights {
    if (count == 0) return .{ .lo = 0, .hi = 0, .t = 0 };
    if (!std.math.isFinite(f) or f <= 0) return .{ .lo = 0, .hi = 0, .t = 0 };
    const last: f64 = @floatFromInt(count - 1);
    if (f >= last) return .{ .lo = count - 1, .hi = count - 1, .t = 0 };
    const lo: usize = @intFromFloat(@floor(f));
    return .{ .lo = lo, .hi = @min(lo + 1, count - 1), .t = f - @floor(f) };
}

/// The scenario's ambient ceiling as a caption fragment: the figure and the
/// part that sets it, or a word saying nothing sets one.
fn ceilingText(
    alloc: std.mem.Allocator,
    limit: thermal_scenarios.Limit,
) std.mem.Allocator.Error![]const u8 {
    const c = limit.c orelse return "unknown";
    if (limit.ref.len == 0) return std.fmt.allocPrint(alloc, "{d:.0}C", .{c});
    return std.fmt.allocPrint(alloc, "{d:.0}C ({s})", .{ c, net_name.leaf(limit.ref) });
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const thermal = @import("eval/thermal.zig");

/// A 40 × 40 mm board with one hot part near a corner and a cool one opposite.
fn testPlacement(parts: []optimizer.Part) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 40,
        .maxy = 40,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 40, .h = 40 },
    };
}

fn testParts() [2]optimizer.Part {
    return .{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 10, .y = 10 },
        .{ .ref_des = "buck/U2", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 30, .y = 30 },
    };
}

fn testScreen() thermal.BoardThermal {
    return .{
        .ambient_c = 25,
        .parts = &.{
            .{
                .ref_des = "U1",
                .component = "reg",
                .power = .{ .watts = 2.0, .source = .explicit },
                .theta = .{ .ja = 60, .jb = 10 },
                .limits = .{ .tj_max = 125, .operating_max_c = 85 },
            },
            .{
                .ref_des = "buck/U2",
                .component = "mcu",
                .power = .{ .watts = 0.1, .source = .explicit },
                .theta = .{ .ja = 40 },
                .limits = .{ .tj_max = 125 },
            },
        },
    };
}

/// Solve `scenario` over the fixture and build the render view for it.
fn testView(
    arena: std.mem.Allocator,
    p: optimizer.Placement,
    scenario: thermal_field.Scenario,
    ambient_c: f64,
) !View {
    const bt = testScreen();
    const result = try thermal_field.solveScenario(arena, try thermal_scenarios.inputsFor(arena, bt, p, .{}), scenario);
    const ladder = try thermal_scenarios.ladderAt(arena, &.{result}, ambient_c);
    return .{
        .result = result,
        .row = ladder.rows[0],
        .part_rows = try thermal_scenarios.rowsByPart(arena, p, ladder.rows[0].parts),
    };
}

// spec: render_thermal_png - the heat-zone image is a valid PNG whose pixels differ between two cooling scenarios of the same board
test "the heat-zone image encodes as a PNG and changes with the scenario" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = testParts();
    const p = testPlacement(&parts);
    const still = try render(arena, p, try testView(arena, p, .natural, 25), .{ .width = 600, .title = "heater" });
    const blown = try render(arena, p, try testView(arena, p, .airflow_2ms, 25), .{ .width = 600, .title = "heater" });

    try testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, still[0..4]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, blown[0..4]);
    // Two m/s of air is a colder board, and a picture that did not change would
    // mean the scenario never reached the renderer.
    try testing.expect(!std.mem.eql(u8, still, blown));
}

// spec: render_thermal_png - an authored non-rectangular outline clips the heat wash and is stroked as its exact polygon instead of the rectangular bounding box
test "the heat-zone image leaves rounded-off corner area unpainted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = testParts();
    var p = testPlacement(&parts);
    const cut = [_][2]f64{ .{ 5, 0 }, .{ 35, 0 }, .{ 40, 5 }, .{ 40, 35 }, .{ 35, 40 }, .{ 5, 40 }, .{ 0, 35 }, .{ 0, 5 } };
    p.board_poly = &cut;
    const view = try testView(arena, p, .natural, 25);
    var cv = try renderCanvas(arena, p, view, .{ .width = 600 });
    defer cv.deinit();

    const box = viewBox(p, view.result.grid);
    const scale = 600.0 / (@max(box[2] - box[0], 1.0) + 2 * view_margin_mm);
    const px: usize = @intFromFloat((1 - box[0] + view_margin_mm) * scale * ss);
    const py: usize = @intFromFloat((@as(f64, @floatFromInt(header_h_px)) + (1 - box[1] + view_margin_mm) * scale) * ss);
    const i = (py * cv.iw + px) * 3;
    try testing.expectEqual(bg.r, cv.buf[i]);
    try testing.expectEqual(bg.g, cv.buf[i + 1]);
    try testing.expectEqual(bg.b, cv.buf[i + 2]);
}

// spec: render_thermal_png - the field is painted against one absolute 25 °C to 125 °C scale, clamping temperatures outside it so the same colour means the same heat across boards and cooling scenarios
test "the painted field uses a fixed absolute temperature scale" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = testParts();
    const p = testPlacement(&parts);
    const view = try testView(arena, p, .natural, 25);
    var cv = try renderCanvas(arena, p, view, .{ .width = 600 });
    defer cv.deinit();

    var ctx = Ctx{
        .cv = &cv,
        .scale = 0,
        .minx = 0,
        .miny = 0,
        .yoff = 0,
        .p = p,
        .view = view,
        .opts = .{},
        .span = riseSpan(view.result.grid),
    };
    // U1 burns twenty times what U2 does, so the copper under it is hotter and
    // the hotspot lands on its corner of the board rather than in the middle.
    try testing.expect(ctx.sample(10, 10) > ctx.sample(30, 30));
    try testing.expect(view.row.hotspot.x_mm < 20);
    try testing.expect(view.row.hotspot.y_mm < 20);
    // Absolute temperatures, not this field's extrema, own the ramp. These are
    // rises above the 25 °C ambient in ctx.opts.
    try testing.expectApproxEqAbs(@as(f64, 0), ctx.norm(0), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), ctx.norm(50), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), ctx.norm(100), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), ctx.norm(-50), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), ctx.norm(200), 1e-12);
}

// spec: render_thermal_png - absolute temperatures on the image follow the requested ambient, shifting one for one with it
test "the image reads its temperatures at the requested ambient" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = testParts();
    const p = testPlacement(&parts);
    const cold = try testView(arena, p, .natural, 25);
    const warm = try testView(arena, p, .natural, 70);

    // The FIELD is the same solve — rises are ambient-free — while every
    // absolute figure the image prints moves by the 45 °C difference.
    try testing.expectEqualSlices(f32, cold.result.grid.rise_c, warm.result.grid.rise_c);
    try testing.expectApproxEqAbs(cold.row.hotspot.c + 45, warm.row.hotspot.c, 1e-9);
    try testing.expectApproxEqAbs(cold.row.board_max_c + 45, warm.row.board_max_c, 1e-9);
    try testing.expectApproxEqAbs(cold.part_rows[0].?.tj_c.? + 45, warm.part_rows[0].?.tj_c.?, 1e-9);
    // A ceiling is already an ambient and does not move with the reading.
    try testing.expectEqual(cold.row.max_ambient.c.?, warm.row.max_ambient.c.?);

    // Both still render, and the pictures differ only in their printed numbers.
    const bytes = try render(arena, p, warm, .{ .width = 500, .ambient_c = 70 });
    try testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, bytes[0..4]);
}

// spec: render_thermal_png - the ramp runs cold to hot through one blue, cyan and yellow band each, ends on red, and clamps outside the unit interval
test "the heat ramp is ordered and clamped" {
    // The named stops come back exactly, and everything between is a blend of
    // its two neighbours rather than a jump.
    try testing.expectEqual(ramp[0].c, rampColor(0));
    try testing.expectEqual(ramp[ramp.len - 1].c, rampColor(1));
    const mid = rampColor(0.52);
    try testing.expectEqual(ramp[2].c, mid);

    // Blue at the cold end, red at the hot end — the reading every thermal
    // image is expected to have.
    try testing.expect(rampColor(0).b > rampColor(0).r);
    try testing.expect(rampColor(1).r > rampColor(1).b);
    // Luminance climbs across the cold two thirds, the part that has to survive
    // a greyscale or colour-blind reading.
    try testing.expect(luma(rampColor(0)) < luma(rampColor(0.28)));
    try testing.expect(luma(rampColor(0.28)) < luma(rampColor(0.52)));
    try testing.expect(luma(rampColor(0.52)) < luma(rampColor(0.76)));

    // Out-of-range and non-finite inputs clamp instead of indexing off the end.
    try testing.expectEqual(ramp[0].c, rampColor(-5));
    try testing.expectEqual(ramp[ramp.len - 1].c, rampColor(9));
    try testing.expectEqual(ramp[0].c, rampColor(std.math.nan(f64)));
}

fn luma(c: Rgb) f64 {
    return 0.2126 * @as(f64, @floatFromInt(c.r)) +
        0.7152 * @as(f64, @floatFromInt(c.g)) +
        0.0722 * @as(f64, @floatFromInt(c.b));
}

// spec: render_thermal_png - a reported part always keeps its label while an unreported one keeps its ref only when the text fits its own box and lands clear of every label already placed
test "labels give way to the temperatures they would otherwise garble" {
    // A label placed clear of everything is taken as offered.
    const first = labelSlot(.{ 100, 100, 140, 120 }, 30, &.{}, false).?;
    try testing.expect(first[1] < 100); // above the part
    try testing.expect(!overlapsAny(&.{}, first));

    // An UNREPORTED part whose label would land on one already drawn gives up
    // rather than printing through it — the fix for barracuda's
    // "C140.39.38.3756", five neighbouring 0402 refs stacked on one another.
    try testing.expect(labelSlot(.{ 100, 100, 140, 120 }, 30, &.{first}, false) == null);

    // A REPORTED part must be drawn, so it takes the slot below the part
    // instead; its temperature is the reason the image exists.
    const below = labelSlot(.{ 100, 100, 140, 120 }, 30, &.{first}, true).?;
    try testing.expect(below[1] > 120);
    try testing.expect(!overlapsAny(&.{first}, below));
    // …and with BOTH slots taken it still draws, accepting one collision rather
    // than dropping a temperature.
    try testing.expect(labelSlot(.{ 100, 100, 140, 120 }, 30, &.{ first, below }, true) != null);

    // Overlap is measured on the drawn boxes, including the backing chip, so
    // two labels that merely touch already count as colliding.
    const box = labelBox(120, 100, 30);
    try testing.expect(overlapsAny(&.{box}, labelBox(120, 100 + label_h, 30)));
    try testing.expect(!overlapsAny(&.{box}, labelBox(120, 100 + label_h + 4, 30)));
    try testing.expect(!overlapsAny(&.{box}, labelBox(200, 100, 30)));
}

/// The two reported hubs of `testScreen`, plus twelve 0402-sized passives
/// packed a millimetre apart down one edge — the shape that garbled on
/// barracuda, where five neighbouring refs printed as one string.
fn crowdedParts() [14]optimizer.Part {
    var parts: [14]optimizer.Part = undefined;
    const hubs = testParts();
    parts[0] = hubs[0];
    parts[1] = hubs[1];
    for (parts[2..], 0..) |*part, i| {
        const fi: f64 = @floatFromInt(i);
        part.* = .{
            .ref_des = "C10",
            .kind = .passive,
            .hw = 0.5,
            .hh = 0.25,
            .pads = &.{},
            .fallback = false,
            .x = 8 + fi,
            .y = 20,
        };
    }
    return parts;
}

// spec: render_thermal_png - the heat-zone image labels every part the screen reported on and drops the refs of small unreported parts, so a dense board's temperatures stay readable
test "a dense board keeps its temperatures and drops the passive clutter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = crowdedParts();
    const p = testPlacement(&parts);
    const view = try testView(arena, p, .natural, 25);
    var cv = try renderCanvas(arena, p, view, .{ .width = 700 });
    defer cv.deinit();

    var ctx = Ctx{
        .cv = &cv,
        .scale = 700.0 / 44.0,
        .minx = 0,
        .miny = 0,
        .yoff = @floatFromInt(header_h_px),
        .p = p,
        .view = view,
        .opts = .{},
        .span = riseSpan(view.result.grid),
    };
    var placed: std.ArrayList([4]f32) = .empty;
    defer placed.deinit(arena);
    ctx.placeLabels(&placed, true);
    // Both reported parts are labelled, whatever else is around them.
    try testing.expectEqual(@as(usize, 2), placed.items.len);
    const reported = placed.items.len;

    ctx.placeLabels(&placed, false);
    // …and the twelve packed passives contribute far fewer, because a 1 mm part
    // cannot carry a three-character ref at this scale.
    try testing.expect(placed.items.len - reported < 12);
    // Nothing that was drawn overlaps anything drawn before it.
    for (placed.items, 0..) |box, i| try testing.expect(!overlapsAny(placed.items[0..i], box));
}

// spec: render_thermal_png - a board that dissipates nothing still renders, painting a flat field with no hotspot marker
test "a board dissipating nothing renders a flat field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parts = testParts();
    const p = testPlacement(&parts);
    const bt = thermal.BoardThermal{ .ambient_c = 25, .parts = &.{} };
    const result = try thermal_field.solveScenario(arena, try thermal_scenarios.inputsFor(arena, bt, p, .{}), .natural);
    const ladder = try thermal_scenarios.ladderAt(arena, &.{result}, 25);
    const view = View{ .result = result, .row = ladder.rows[0] };

    const bytes = try render(arena, p, view, .{ .width = 500, .title = "cold" });
    try testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, bytes[0..4]);
    // Nothing is hot, so the ramp collapses onto its cold end rather than
    // dividing by a zero span.
    const span = riseSpan(result.grid);
    try testing.expectEqual(@as(f64, 0), span[0]);
    try testing.expectEqual(@as(f64, 0), span[1]);
}
