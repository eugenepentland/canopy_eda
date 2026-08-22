//! Native schematic PNG export. The schematic SVG emitter remains the single
//! layout authority: this module renders the requested hub(s), translates the
//! renderer's closed SVG subset through `svg2pdf`, then paints that resolved
//! display list into the same dependency-free software canvas as PCB PNGs.
//! No browser, DOM, Chromium, or screenshot automation participates.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const render_html = @import("render_html.zig");
const ctx_mod = @import("render_svg/context.zig");
const svg2pdf = @import("svg2pdf.zig");
const raster = @import("raster.zig");
const font = @import("font5x7.zig");
const png = @import("png.zig");
const review = @import("review.zig");

/// Schematic pin ordering / connection-routing presentation.
pub const View = enum { sequential, functional };
/// Colour palette used by the SVG translator and raster background.
pub const Theme = enum { dark, light };

/// Native schematic image dimensions, presentation, palette, and focus.
pub const Options = struct {
    width: u32 = 1600,
    view: View = .functional,
    theme: Theme = .dark,
    /// Slugified `(sub-block "…")` name. Useful for the block card shown on
    /// the schematic page and normally resolves to one hub plus its passives.
    sub: ?[]const u8 = null,
    /// Exact (or unique path-leaf) hub ref-des. More precise than `sub`.
    ref: ?[]const u8 = null,
};

/// Every failure a native schematic image render can return.
pub const Error = render_html.RenderError || svg2pdf.Error || png.Error || error{
    TargetConflict,
    SubNotFound,
    RefNotFound,
    NoSchematicBlocks,
    TooManyBlocks,
};

const max_unfocused_hubs: usize = 8;
const max_height: f32 = 6000;
const margin: f32 = 24;
const gap: f32 = 24;
const group_title_h: f32 = 22;

/// Parse UI/API view names, defaulting to the actively edited Functional view.
pub fn parseView(raw: ?[]const u8) View {
    const value = raw orelse return .functional;
    return if (std.ascii.eqlIgnoreCase(value, "functional")) .functional else .sequential;
}

/// Parse dark/light (and print alias) palette names, defaulting to dark.
pub fn parseTheme(raw: ?[]const u8) Theme {
    const value = raw orelse return .dark;
    return if (std.ascii.eqlIgnoreCase(value, "light") or std.ascii.eqlIgnoreCase(value, "print")) .light else .dark;
}

/// Human-readable explanation for focus/size errors; unknown renderer failures
/// retain their Zig error name for diagnostics.
pub fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.TargetConflict => "choose either sub or ref, not both",
        error.SubNotFound => "schematic sub-block not found",
        error.RefNotFound => "schematic hub ref not found (use its full path when a leaf ref is ambiguous)",
        error.NoSchematicBlocks => "target contains no renderable schematic hub",
        error.TooManyBlocks => "design has more than eight schematic hubs; choose sub=<slug> or ref=<hub>",
        else => @errorName(err),
    };
}

/// Render a design/module block to PNG bytes owned by `allocator`. A focused
/// `sub` or `ref` produces the visual block used for post-edit review; a small
/// unfocused block becomes a contact sheet. Designs with more than eight hubs
/// require focus so the output remains inspectable rather than stamp-sized.
pub fn render(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    project_dir: []const u8,
    opts: Options,
) Error![]u8 {
    if (opts.sub != null and opts.ref != null) return error.TargetConflict;

    var ctx = try render_html.setupRenderCtx(allocator, block);
    ctx.project_dir = project_dir;

    const refs = try selectRefs(allocator, block, &ctx, opts);
    if (refs.len == 0) return error.NoSchematicBlocks;
    if (opts.sub == null and opts.ref == null and refs.len > max_unfocused_hubs) return error.TooManyBlocks;

    var pin_groups: std.ArrayList(env_mod.PinGroup) = .empty;
    try collectPinGroups(allocator, block, &pin_groups);

    var docs: std.ArrayList(svg2pdf.Document) = .empty;
    const html_view: render_html.SchematicView = switch (opts.view) {
        .sequential => .original,
        .functional => .functional,
    };
    const svg_theme: svg2pdf.Theme = switch (opts.theme) {
        .dark => .screen,
        .light => .print,
    };
    for (refs) |ref| {
        var markup: std.Io.Writer.Allocating = .init(allocator);
        defer markup.deinit();
        if (!try render_html.renderHubSvgForView(
            &ctx,
            &markup.writer,
            allocator,
            pin_groups.items,
            ref,
            html_view,
        )) continue;
        const translated = try svg2pdf.translateAll(allocator, markup.written(), .{ .theme = svg_theme }, null);
        for (translated) |doc| if (doc.ops.len > 0) try docs.append(allocator, doc);
    }
    if (docs.items.len == 0) return error.NoSchematicBlocks;

    const width = std.math.clamp(opts.width, 320, 4000);
    return paintDocuments(allocator, docs.items, width, opts.theme);
}

fn selectRefs(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    ctx: *const ctx_mod.RenderCtx,
    opts: Options,
) ![]const []const u8 {
    if (opts.ref) |query| {
        const found = uniqueHubRef(ctx.hub_order.items, query) orelse return error.RefNotFound;
        return allocator.dupe([]const u8, &.{found});
    }
    if (opts.sub) |slug| {
        for (block.sub_blocks) |sb| {
            const candidate = try review.slugify(allocator, sb.name);
            if (!std.ascii.eqlIgnoreCase(candidate, slug)) continue;
            var out: std.ArrayList([]const u8) = .empty;
            try collectBlockHubRefs(allocator, &sb.block.*, sb.name, ctx, &out);
            if (out.items.len == 0) return error.NoSchematicBlocks;
            return out.toOwnedSlice(allocator);
        }
        return error.SubNotFound;
    }
    return allocator.dupe([]const u8, ctx.hub_order.items);
}

fn uniqueHubRef(hubs: []const []const u8, query: []const u8) ?[]const u8 {
    var match: ?[]const u8 = null;
    for (hubs) |ref| {
        const exact = std.ascii.eqlIgnoreCase(ref, query);
        const leaf = if (std.mem.lastIndexOfScalar(u8, ref, '/')) |at|
            std.ascii.eqlIgnoreCase(ref[at + 1 ..], query)
        else
            false;
        if (!exact and !leaf) continue;
        if (exact) return ref;
        if (match != null) return null; // ambiguous leaf — require full ref
        match = ref;
    }
    return match;
}

fn collectBlockHubRefs(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    ctx: *const ctx_mod.RenderCtx,
    out: *std.ArrayList([]const u8),
) !void {
    for (block.instances) |inst| {
        const ref = if (prefix.len > 0 and !isStdRefDes(inst.ref_des))
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, inst.ref_des })
        else
            inst.ref_des;
        if (hubContains(ctx.hub_order.items, ref)) try appendUnique(allocator, out, ref);
    }
    for (block.sub_blocks) |sb| {
        const next = if (prefix.len > 0)
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, sb.name })
        else
            sb.name;
        try collectBlockHubRefs(allocator, sb.block, next, ctx, out);
    }
}

fn isStdRefDes(ref: []const u8) bool {
    if (ref.len < 2) return false;
    var i: usize = 0;
    while (i < ref.len and i < 2 and std.ascii.isUpper(ref[i])) : (i += 1) {}
    if (i == 0) return false;
    const digit_start = i;
    while (i < ref.len and std.ascii.isDigit(ref[i])) : (i += 1) {}
    return i == ref.len and i > digit_start;
}

fn hubContains(hubs: []const []const u8, ref: []const u8) bool {
    for (hubs) |hub| if (std.mem.eql(u8, hub, ref)) return true;
    return false;
}

fn appendUnique(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), ref: []const u8) !void {
    for (out.items) |old| if (std.mem.eql(u8, old, ref)) return;
    try out.append(allocator, ref);
}

fn collectPinGroups(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    out: *std.ArrayList(env_mod.PinGroup),
) !void {
    for (block.sections) |sec| {
        try out.appendSlice(allocator, sec.pin_groups);
        for (sec.sub_sections) |sub| try out.appendSlice(allocator, sub.pin_groups);
    }
    for (block.sub_blocks) |sb| try collectPinGroups(allocator, sb.block, out);
}

const Placement = struct { x: f32, y: f32, scale: f32 };

fn paintDocuments(
    allocator: std.mem.Allocator,
    docs: []const svg2pdf.Document,
    width: u32,
    theme: Theme,
) ![]u8 {
    const cols: usize = if (docs.len == 1) 1 else if (docs.len <= 4) 2 else 3;
    const rows = (docs.len + cols - 1) / cols;
    const wf: f32 = @floatFromInt(width);
    const cell_w = (wf - margin * 2 - gap * @as(f32, @floatFromInt(cols - 1))) / @as(f32, @floatFromInt(cols));
    var placements = try allocator.alloc(Placement, docs.len);
    defer allocator.free(placements);
    var row_heights = try allocator.alloc(f32, rows);
    defer allocator.free(row_heights);
    @memset(row_heights, 0);

    for (docs, 0..) |doc, i| {
        const title_h: f32 = if (doc.title.len > 0) group_title_h else 0;
        const scale = cell_w / @as(f32, @floatCast(doc.width));
        row_heights[i / cols] = @max(row_heights[i / cols], @as(f32, @floatCast(doc.height)) * scale + title_h);
        placements[i].scale = scale;
    }
    var content_h: f32 = 0;
    for (row_heights) |h| content_h += h;
    if (rows > 1) content_h += gap * @as(f32, @floatFromInt(rows - 1));
    var shrink: f32 = 1;
    if (content_h + margin * 2 > max_height) shrink = (max_height - margin * 2) / content_h;

    @memset(row_heights, 0);
    for (docs, 0..) |doc, i| {
        placements[i].scale *= shrink;
        const title_h: f32 = if (doc.title.len > 0) group_title_h else 0;
        row_heights[i / cols] = @max(row_heights[i / cols], @as(f32, @floatCast(doc.height)) * placements[i].scale + title_h);
    }
    var y = margin;
    for (0..rows) |row| {
        for (0..cols) |col| {
            const i = row * cols + col;
            if (i >= docs.len) break;
            const drawn_w = @as(f32, @floatCast(docs[i].width)) * placements[i].scale;
            const cell_x = margin + @as(f32, @floatFromInt(col)) * (cell_w + gap);
            placements[i].x = cell_x + (cell_w - drawn_w) / 2;
            placements[i].y = y + if (docs[i].title.len > 0) group_title_h else 0;
        }
        y += row_heights[row] + gap;
    }
    const height: u32 = @intFromFloat(@ceil(@min(max_height, y - gap + margin)));
    const area = @as(u64, width) * height;
    const ss: u32 = if (area <= 5_000_000) 2 else 1;
    const bg = switch (theme) {
        .dark => raster.Rgb.hex("#010409"),
        .light => raster.Rgb.hex("#ffffff"),
    };
    var canvas = try raster.Canvas.init(allocator, width, height, ss, bg);
    defer canvas.deinit();

    const title_color = switch (theme) {
        .dark => raster.Rgb.hex("#c9d1d9"),
        .light => raster.Rgb.hex("#222222"),
    };
    for (docs, 0..) |doc, i| {
        const p = placements[i];
        if (doc.title.len > 0) paintText(&canvas, doc.title, .{
            .x = p.x,
            .y = p.y - group_title_h,
            .height = 14,
            .color = title_color,
        });
        try paintDocument(allocator, &canvas, doc, p);
    }
    return canvas.toPng(allocator);
}

fn paintDocument(
    allocator: std.mem.Allocator,
    canvas: *raster.Canvas,
    doc: svg2pdf.Document,
    place: Placement,
) !void {
    for (doc.ops) |op| switch (op) {
        .line => |v| drawLine(canvas, doc, place, v.a, v.b, v.stroke),
        .polyline => |v| {
            const pts = try mapPoints(allocator, doc, place, v.points);
            defer allocator.free(pts);
            canvas.strokePath(pts, .open, strokeWidth(v.stroke, place.scale), color(v.stroke.color), 1);
        },
        .polygon => |v| {
            const pts = try mapPoints(allocator, doc, place, v.points);
            defer allocator.free(pts);
            if (v.fill) |fill| canvas.fillPoly(pts, color(fill), 1);
            if (v.stroke) |stroke| canvas.strokePath(pts, .closed, strokeWidth(stroke, place.scale), color(stroke.color), 1);
        },
        .rect => |v| {
            const x = mapX(doc, place, v.x);
            const y = mapY(doc, place, v.y);
            const w = @as(f32, @floatCast(v.w)) * place.scale;
            const h = @as(f32, @floatCast(v.h)) * place.scale;
            if (v.fill) |fill| canvas.fillRect(x, y, w, h, color(fill), 1);
            if (v.stroke) |stroke| {
                const pts = [_][2]f32{ .{ x, y }, .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } };
                canvas.strokePath(&pts, .closed, strokeWidth(stroke, place.scale), color(stroke.color), 1);
            }
        },
        .circle => |v| {
            const x = mapX(doc, place, v.c.x);
            const y = mapY(doc, place, v.c.y);
            const r = @as(f32, @floatCast(v.r)) * place.scale;
            if (v.fill) |fill| canvas.disc(x, y, r, color(fill), 1);
            if (v.stroke) |stroke| canvas.ring(x, y, r, strokeWidth(stroke, place.scale), color(stroke.color), 1);
        },
        .arc => |v| drawArc(canvas, doc, place, v),
        .text => |v| {
            const x = mapX(doc, place, v.at.x);
            const size = @as(f32, @floatCast(v.size)) * place.scale;
            const y = mapY(doc, place, v.at.y) - size * 0.82;
            const anchor: raster.Anchor = switch (v.anchor) {
                .start => .start,
                .middle => .middle,
                .end => .end,
            };
            paintText(canvas, v.s, .{
                .x = x,
                .y = y,
                .height = size,
                .color = color(v.fill),
                .anchor = anchor,
                .bold_offset = if (v.bold) @max(0.5, place.scale * 0.35) else 0,
            });
        },
    };
}

const TextPaint = struct {
    x: f32,
    y: f32,
    height: f32,
    color: raster.Rgb,
    anchor: raster.Anchor = .start,
    bold_offset: f32 = 0,
};

/// Case-preserving 5x7 text painter for schematic values (`pF`, `uF`, etc.).
/// PCB labels keep their historical uppercase `Canvas.text` behavior.
fn paintText(canvas: *raster.Canvas, text: []const u8, opts: TextPaint) void {
    // SVG's monospace fonts advance at roughly 0.6em. The bitmap glyph is a
    // 5-wide mark in a 6-wide cell, so use independent x/y pixel scales: a
    // square 5x7 pixel would advance at 0.86em and make labels collide even
    // though the browser layout is clean.
    const sy = opts.height / @as(f32, @floatFromInt(font.gh));
    const sx = opts.height / 10;
    const advance = @as(f32, @floatFromInt(font.gw + 1)) * sx;
    const total = if (text.len == 0) 0 else @as(f32, @floatFromInt(text.len)) * advance - sx;
    var x0 = opts.x;
    switch (opts.anchor) {
        .start => {},
        .middle => x0 -= total / 2,
        .end => x0 -= total,
    }
    for (text, 0..) |ch, ci| {
        const cols = font.cols(ch);
        const base_x = x0 + @as(f32, @floatFromInt(ci)) * advance;
        for (cols, 0..) |col, gx| {
            var gy: u32 = 0;
            while (gy < font.gh) : (gy += 1) {
                if (col & (@as(u8, 1) << @as(u3, @intCast(gy))) == 0) continue;
                const x = base_x + @as(f32, @floatFromInt(gx)) * sx;
                const y = opts.y + @as(f32, @floatFromInt(gy)) * sy;
                canvas.fillRect(x, y, sx, sy, opts.color, 1);
                if (opts.bold_offset > 0) canvas.fillRect(x + opts.bold_offset, y, sx, sy, opts.color, 1);
            }
        }
    }
}

fn color(v: svg2pdf.Rgb) raster.Rgb {
    return .{ .r = v.r, .g = v.g, .b = v.b };
}

fn strokeWidth(v: svg2pdf.Stroke, scale: f32) f32 {
    return @max(0.75, @as(f32, @floatCast(v.width)) * scale);
}

fn mapX(doc: svg2pdf.Document, p: Placement, x: f64) f32 {
    return p.x + @as(f32, @floatCast(x - doc.min_x)) * p.scale;
}

fn mapY(doc: svg2pdf.Document, p: Placement, y: f64) f32 {
    return p.y + @as(f32, @floatCast(y - doc.min_y)) * p.scale;
}

fn mapPoints(
    allocator: std.mem.Allocator,
    doc: svg2pdf.Document,
    p: Placement,
    points: []const svg2pdf.Pt,
) ![][2]f32 {
    const out = try allocator.alloc([2]f32, points.len);
    for (points, 0..) |v, i| out[i] = .{ mapX(doc, p, v.x), mapY(doc, p, v.y) };
    return out;
}

fn drawLine(canvas: *raster.Canvas, doc: svg2pdf.Document, p: Placement, a: svg2pdf.Pt, b: svg2pdf.Pt, stroke: svg2pdf.Stroke) void {
    canvas.line(mapX(doc, p, a.x), mapY(doc, p, a.y), mapX(doc, p, b.x), mapY(doc, p, b.y), strokeWidth(stroke, p.scale), color(stroke.color), 1, .butt);
}

/// Approximate the SVG emitter's one supported elliptical-arc form with a
/// short polyline. This is normally an inductor half-loop, so 20 segments are
/// well above the raster's visible resolution.
fn drawArc(canvas: *raster.Canvas, doc: svg2pdf.Document, p: Placement, arc: svg2pdf.Arc) void {
    const rx = @abs(arc.rx);
    const ry = @abs(arc.ry);
    if (rx == 0 or ry == 0) {
        drawLine(canvas, doc, p, arc.from, arc.to, arc.stroke);
        return;
    }
    const dx2 = (arc.from.x - arc.to.x) / 2;
    const dy2 = (arc.from.y - arc.to.y) / 2;
    var arx = rx;
    var ary = ry;
    const lambda = dx2 * dx2 / (arx * arx) + dy2 * dy2 / (ary * ary);
    if (lambda > 1) {
        const grow = @sqrt(lambda);
        arx *= grow;
        ary *= grow;
    }
    const den = arx * arx * dy2 * dy2 + ary * ary * dx2 * dx2;
    const num = @max(0, arx * arx * ary * ary - den);
    const sign: f64 = if (arc.sweep_cw) -1 else 1;
    const factor = if (den == 0) 0 else sign * @sqrt(num / den);
    const cxp = factor * arx * dy2 / ary;
    const cyp = factor * -ary * dx2 / arx;
    const cx = (arc.from.x + arc.to.x) / 2 + cxp;
    const cy = (arc.from.y + arc.to.y) / 2 + cyp;
    const start = std.math.atan2((arc.from.y - cy) / ary, (arc.from.x - cx) / arx);
    var stop = std.math.atan2((arc.to.y - cy) / ary, (arc.to.x - cx) / arx);
    if (arc.sweep_cw and stop < start) stop += 2 * std.math.pi;
    if (!arc.sweep_cw and stop > start) stop -= 2 * std.math.pi;
    const step = (stop - start) / 20;
    var points: [21][2]f32 = undefined;
    for (&points, 0..) |*pt, i| {
        const angle = start + step * @as(f64, @floatFromInt(i));
        pt.* = .{ mapX(doc, p, cx + arx * @cos(angle)), mapY(doc, p, cy + ary * @sin(angle)) };
    }
    canvas.strokePath(&points, .open, strokeWidth(arc.stroke, p.scale), color(arc.stroke.color), 1);
}

const fixture_instances = [_]env_mod.Instance{.{ .ref_des = "U1", .component = "ic", .value = "demo", .footprint = "", .symbol = "" }};
const fixture_pins = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "1" }};
const fixture_nets = [_]env_mod.Net{.{ .name = "OUT", .pins = &fixture_pins }};
const fixture_block: env_mod.DesignBlock = .{
    .name = "native png",
    .instances = &fixture_instances,
    .nets = &fixture_nets,
    .ports = &.{},
    .notes = &.{},
    .groups = &.{},
    .sub_blocks = &.{},
};

// spec: Web Server - Native schematic export paints the SVG display list into a valid PNG without a browser
test "native schematic render returns PNG bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var block = fixture_block;
    const bytes = try render(arena.allocator(), &block, "", .{ .width = 640 });
    try std.testing.expect(bytes.len > 100);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4e, 0x47 }, bytes[0..4]);
}

// spec: Web Server - Schematic image view parsing accepts the UI's Sequential and Functional names and defaults to Functional
test "schematic image view parser follows the UI names" {
    try std.testing.expectEqual(View.functional, parseView(null));
    try std.testing.expectEqual(View.functional, parseView("Functional"));
    try std.testing.expectEqual(View.sequential, parseView("sequential"));
    try std.testing.expectEqual(View.sequential, parseView("original"));
}
