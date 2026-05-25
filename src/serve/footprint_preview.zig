const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const parser_mod = @import("../sexpr/parser.zig");
const export_kicad = @import("../export_kicad.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

// ── Constants ─────────────────────────────────────────────────────
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_INTERNAL_ERROR: u16 = 500;
const MAX_FOOTPRINT_BYTES: usize = 256 * 1024;
const SEXP_EXT_LEN: usize = ".sexp".len;
const FAR_AWAY: f64 = 999;
const SVG_BBOX_PAD: f64 = 0.5;

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// GET /api/footprint/:name — render a `lib/footprints/<name>.sexp`
/// as an inline SVG (pads, silkscreen lines and circles) for the library
/// page's footprint-preview panel and the schematic sidebar's component view.
pub fn footprintSvgApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const fp_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    defer ctx.allocator.free(fp_path);
    const content = infra_fs.cwd().readFileAlloc(ctx.allocator, fp_path, MAX_FOOTPRINT_BYTES) catch {
        res.status = HTTP_NOT_FOUND;
        res.body = "Footprint not found";
        return;
    };

    const nodes = parser_mod.parse(ctx.allocator, content) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Parse error";
        return;
    };
    if (nodes.len == 0) {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    }
    const top = nodes[0].asList() orelse {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };

    const Pad = struct { id: []const u8, x: f64, y: f64, w: f64, h: f64, shape: []const u8 };
    const Line = struct { x1: f64, y1: f64, x2: f64, y2: f64 };
    const Circle = struct { cx: f64, cy: f64, r: f64 };

    var pads: std.ArrayListUnmanaged(Pad) = .empty;
    var silk_lines: std.ArrayListUnmanaged(Line) = .empty;
    var silk_circles: std.ArrayListUnmanaged(Circle) = .empty;

    for (top[1..]) |child| {
        if (child.isForm("pad")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 4) continue;
            const pid: ?[]const u8 = cl[1].asAtom() orelse if (cl[1].asNumber()) |n|
                (std.fmt.allocPrint(ctx.allocator, "{d}", .{@as(i64, @intFromFloat(n))}) catch null)
            else
                null;
            if (pid == null) continue;
            const pid_val = pid.?;
            var px: f64 = 0;
            var py: f64 = 0;
            var pw: f64 = 0;
            var ph: f64 = 0;
            const shape: []const u8 = cl[3].asAtom() orelse "rect";
            for (cl[4..]) |sub| {
                if (sub.isForm("pos")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) {
                        px = sl[1].asNumber() orelse 0;
                        py = sl[2].asNumber() orelse 0;
                    }
                }
                if (sub.isForm("size")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) {
                        pw = sl[1].asNumber() orelse 0;
                        ph = sl[2].asNumber() orelse 0;
                    }
                }
            }
            try pads.append(ctx.allocator, .{ .id = pid_val, .x = px, .y = py, .w = pw, .h = ph, .shape = shape });
        }
        if (child.isForm("silkscreen")) {
            const cl = child.asList() orelse continue;
            for (cl[1..]) |sub| {
                if (sub.isForm("line")) {
                    const sl = sub.asList() orelse continue;
                    if (sl.len >= 3) {
                        const p1 = sl[1].asList() orelse continue;
                        const p2 = sl[2].asList() orelse continue;
                        if (p1.len >= 2 and p2.len >= 2) {
                            try silk_lines.append(ctx.allocator, .{
                                .x1 = p1[0].asNumber() orelse 0,
                                .y1 = p1[1].asNumber() orelse 0,
                                .x2 = p2[0].asNumber() orelse 0,
                                .y2 = p2[1].asNumber() orelse 0,
                            });
                        }
                    }
                }
                if (sub.isForm("circle")) {
                    const sl = sub.asList() orelse continue;
                    if (sl.len >= 3) {
                        const center = sl[1].asList() orelse continue;
                        const radius = sl[2].asNumber() orelse 0;
                        if (center.len >= 2) {
                            try silk_circles.append(ctx.allocator, .{
                                .cx = center[0].asNumber() orelse 0,
                                .cy = center[1].asNumber() orelse 0,
                                .r = radius,
                            });
                        }
                    }
                }
            }
        }
    }

    var min_x: f64 = FAR_AWAY;
    var min_y: f64 = FAR_AWAY;
    var max_x: f64 = -FAR_AWAY;
    var max_y: f64 = -FAR_AWAY;
    for (pads.items) |p| {
        const lx = p.x - p.w / 2;
        const ly = p.y - p.h / 2;
        const rx = p.x + p.w / 2;
        const ry = p.y + p.h / 2;
        if (lx < min_x) min_x = lx;
        if (ly < min_y) min_y = ly;
        if (rx > max_x) max_x = rx;
        if (ry > max_y) max_y = ry;
    }
    for (silk_lines.items) |l| {
        if (l.x1 < min_x) min_x = l.x1;
        if (l.y1 < min_y) min_y = l.y1;
        if (l.x2 < min_x) min_x = l.x2;
        if (l.y2 < min_y) min_y = l.y2;
        if (l.x1 > max_x) max_x = l.x1;
        if (l.y1 > max_y) max_y = l.y1;
        if (l.x2 > max_x) max_x = l.x2;
        if (l.y2 > max_y) max_y = l.y2;
    }
    if (pads.items.len == 0 and silk_lines.items.len == 0) {
        res.status = HTTP_NOT_FOUND;
        res.body = "Empty footprint";
        return;
    }

    min_x -= SVG_BBOX_PAD;
    min_y -= SVG_BBOX_PAD;
    max_x += SVG_BBOX_PAD;
    max_y += SVG_BBOX_PAD;
    const vw = max_x - min_x;
    const vh = max_y - min_y;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" " ++
            "viewBox=\"{d:.2} {d:.2} {d:.2} {d:.2}\" " ++
            "style=\"background:#161b22;border-radius:4px;\">",
        .{ min_x, min_y, vw, vh },
    );

    for (silk_lines.items) |l| {
        try w.print(
            "<line x1=\"{d:.3}\" y1=\"{d:.3}\" x2=\"{d:.3}\" y2=\"{d:.3}\" " ++
                "stroke=\"#555\" stroke-width=\"0.08\" stroke-linecap=\"round\"/>",
            .{ l.x1, l.y1, l.x2, l.y2 },
        );
    }
    for (silk_circles.items) |c| {
        try w.print("<circle cx=\"{d:.3}\" cy=\"{d:.3}\" r=\"{d:.3}\" fill=\"none\" stroke=\"#555\" stroke-width=\"0.08\"/>", .{ c.cx, c.cy, c.r });
    }

    for (pads.items) |p| {
        if (std.mem.eql(u8, p.shape, "circle")) {
            const r = @min(p.w, p.h) / 2;
            try w.print("<circle cx=\"{d:.3}\" cy=\"{d:.3}\" r=\"{d:.3}\" fill=\"#c4a000\"/>", .{ p.x, p.y, r });
        } else if (std.mem.eql(u8, p.shape, "oval")) {
            const rx = p.w / 2;
            const ry = p.h / 2;
            try w.print(
                "<rect x=\"{d:.3}\" y=\"{d:.3}\" width=\"{d:.3}\" height=\"{d:.3}\" " ++
                    "rx=\"{d:.3}\" fill=\"#c4a000\"/>",
                .{ p.x - rx, p.y - ry, p.w, p.h, @min(rx, ry) },
            );
        } else {
            try w.print(
                "<rect x=\"{d:.3}\" y=\"{d:.3}\" width=\"{d:.3}\" height=\"{d:.3}\" " ++
                    "rx=\"0.03\" fill=\"#c4a000\"/>",
                .{ p.x - p.w / 2, p.y - p.h / 2, p.w, p.h },
            );
        }
    }

    try w.writeAll("</svg>");

    res.body = buf.toOwnedSlice(ctx.allocator) catch "";
    res.content_type = .HTML;
}
