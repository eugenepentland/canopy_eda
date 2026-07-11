//! A tiny software rasterizer for the PCB-layout PNG export. The board is
//! flat-shaded geometry — filled/stroked rectangles, polygons (rotated and
//! custom pads), thick line segments (airwires, traces), discs/rings (vias),
//! and bitmap text (labels) — so a small painter over an RGB buffer covers it
//! without a graphics dependency. Edges are anti-aliased by rendering into a
//! supersampled buffer and box-averaging down to the final size on `toPng`.

const std = @import("std");
const png = @import("png.zig");
const font = @import("font5x7.zig");
const numeric = @import("numeric.zig");

/// Round `f` to an `i64` pixel index clamped to `[lo, hi]`, guarding the
/// `@intFromFloat` in float space. A NaN/±inf coordinate (which `@intFromFloat`
/// would turn into UB in the runtime-safety-off ReleaseSmall prod build) or one
/// far outside the range collapses to `lo` — the primitive then spans an empty
/// pixel range and draws nothing, rather than crashing or corrupting memory.
fn pxIndex(f: f32, lo: i64, hi: i64) i64 {
    const v = numeric.checkedInt(i64, @floatCast(f)) orelse return lo;
    return std.math.clamp(v, lo, hi);
}

/// An 8-bit-per-channel RGB colour.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Parse a "#rrggbb" (or "rrggbb") literal at comptime — lets call sites
    /// keep the same hex colours the browser renderer uses.
    pub fn hex(comptime s: []const u8) Rgb {
        const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
        std.debug.assert(h.len == 6);
        return .{
            .r = nibble(h[0]) * 16 + nibble(h[1]),
            .g = nibble(h[2]) * 16 + nibble(h[3]),
            .b = nibble(h[4]) * 16 + nibble(h[5]),
        };
    }

    fn nibble(comptime c: u8) u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => 0,
        };
    }
};

/// Horizontal text alignment relative to the anchor point passed to `text`.
pub const Anchor = enum { start, middle, end };

/// Line-end style for `line`/`strokePath`.
pub const Caps = enum { butt, round };

/// Whether `strokePath` closes the loop back to the first vertex.
pub const PathMode = enum { open, closed };

/// An RGB raster surface. Public draw calls use *final* output pixel
/// coordinates; the buffer itself is `ss×` larger on each axis for
/// anti-aliasing, and `toPng` averages it back down.
pub const Canvas = struct {
    alloc: std.mem.Allocator,
    w: u32,
    h: u32,
    ss: u32,
    iw: usize,
    ih: usize,
    buf: []u8, // iw*ih*3, row-major RGB

    pub fn init(alloc: std.mem.Allocator, w: u32, h: u32, ss: u32, bg: Rgb) std.mem.Allocator.Error!Canvas {
        const iw: usize = @as(usize, w) * ss;
        const ih: usize = @as(usize, h) * ss;
        const buf = try alloc.alloc(u8, iw * ih * 3);
        var i: usize = 0;
        while (i < buf.len) : (i += 3) {
            buf[i] = bg.r;
            buf[i + 1] = bg.g;
            buf[i + 2] = bg.b;
        }
        return .{ .alloc = alloc, .w = w, .h = h, .ss = ss, .iw = iw, .ih = ih, .buf = buf };
    }

    pub fn deinit(self: *Canvas) void {
        self.alloc.free(self.buf);
    }

    /// Alpha-blend `c` over the internal pixel at (ix,iy). `a` is clamped to
    /// [0,1]; out-of-bounds is a no-op.
    fn blendPx(self: *Canvas, ix: i64, iy: i64, c: Rgb, a: f32) void {
        if (ix < 0 or iy < 0) return;
        const ux: usize = @intCast(ix);
        const uy: usize = @intCast(iy);
        if (ux >= self.iw or uy >= self.ih) return;
        const o: usize = (uy * self.iw + ux) * 3;
        const k = std.math.clamp(a, 0.0, 1.0);
        self.buf[o] = mix(self.buf[o], c.r, k);
        self.buf[o + 1] = mix(self.buf[o + 1], c.g, k);
        self.buf[o + 2] = mix(self.buf[o + 2], c.b, k);
    }

    fn mix(dst: u8, src: u8, a: f32) u8 {
        const d: f32 = @floatFromInt(dst);
        const s: f32 = @floatFromInt(src);
        return numeric.checkedInt(u8, @round(d * (1.0 - a) + s * a)) orelse 0;
    }

    /// Filled axis-aligned rectangle (final-pixel coords).
    pub fn fillRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, c: Rgb, a: f32) void {
        const s: f32 = @floatFromInt(self.ss);
        const iw: i64 = @intCast(self.iw);
        const ih: i64 = @intCast(self.ih);
        const ix0 = pxIndex(@round(x * s), 0, iw);
        const iy0 = pxIndex(@round(y * s), 0, ih);
        const ix1 = pxIndex(@round((x + w) * s), 0, iw);
        const iy1 = pxIndex(@round((y + h) * s), 0, ih);
        var iy = iy0;
        while (iy < iy1) : (iy += 1) {
            var ix = ix0;
            while (ix < ix1) : (ix += 1) self.blendPx(ix, iy, c, a);
        }
    }

    /// Filled polygon (final-pixel coords, even-odd rule). Handles arbitrary
    /// vertex counts: a 64-slot stack scratch covers simple pads/quads, and
    /// KiCad custom pads (rounded outlines, 100-200+ points) spill to the heap.
    pub fn fillPoly(self: *Canvas, pts: []const [2]f32, c: Rgb, a: f32) void {
        if (pts.len < 3) return;
        const s: f32 = @floatFromInt(self.ss);
        // `ip` holds the supersampled points; `xs` the per-scanline crossings
        // (at most one per edge ⇒ sized to the vertex count). Both fall back to
        // the stack buffers if the heap allocation fails — only the rare big
        // polygon would then truncate, never the common case.
        var ip_buf: [64][2]f32 = undefined;
        var xs_buf: [64]f32 = undefined;
        var ip: [][2]f32 = &ip_buf;
        var xs: []f32 = &xs_buf;
        var heap = false;
        if (pts.len > ip_buf.len) {
            if (self.alloc.alloc([2]f32, pts.len)) |b1| {
                if (self.alloc.alloc(f32, pts.len)) |b2| {
                    ip = b1;
                    xs = b2;
                    heap = true;
                } else |_| self.alloc.free(b1);
            } else |_| {}
        }
        defer if (heap) {
            self.alloc.free(ip);
            self.alloc.free(xs);
        };
        const n = @min(pts.len, ip.len);
        if (n < 3) return;
        var min_y: f32 = std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);
        for (pts[0..n], 0..) |p, i| {
            ip[i] = .{ p[0] * s, p[1] * s };
            min_y = @min(min_y, ip[i][1]);
            max_y = @max(max_y, ip[i][1]);
        }
        const iw: i64 = @intCast(self.iw);
        const ih: i64 = @intCast(self.ih);
        var iy: i64 = pxIndex(@floor(min_y), 0, ih);
        const iy_end: i64 = pxIndex(@ceil(max_y) + 1, 0, ih);
        while (iy < iy_end) : (iy += 1) {
            const yc: f32 = @as(f32, @floatFromInt(iy)) + 0.5;
            var m: usize = 0;
            var j: usize = 0;
            while (j < n) : (j += 1) {
                const k = (j + 1) % n;
                const y0 = ip[j][1];
                const y1 = ip[k][1];
                if ((y0 <= yc and y1 > yc) or (y1 <= yc and y0 > yc)) {
                    const t = (yc - y0) / (y1 - y0);
                    xs[m] = ip[j][0] + t * (ip[k][0] - ip[j][0]);
                    m += 1;
                }
            }
            std.mem.sort(f32, xs[0..m], {}, std.sort.asc(f32));
            var pair: usize = 0;
            while (pair + 1 < m) : (pair += 2) {
                var ix: i64 = pxIndex(@round(xs[pair]), 0, iw);
                const ix_end: i64 = pxIndex(@round(xs[pair + 1]), 0, iw);
                while (ix < ix_end) : (ix += 1) self.blendPx(ix, iy, c, a);
            }
        }
    }

    /// Thick line segment (final-pixel coords) as a filled quad; optional round
    /// caps so chained segments and trace ends read cleanly.
    pub fn line(self: *Canvas, x0: f32, y0: f32, x1: f32, y1: f32, width: f32, c: Rgb, a: f32, caps: Caps) void {
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len = @sqrt(dx * dx + dy * dy);
        const hw = width / 2;
        if (len < 1e-6) {
            self.disc(x0, y0, hw, c, a);
            return;
        }
        const nx = -dy / len * hw;
        const ny = dx / len * hw;
        const quad = [_][2]f32{
            .{ x0 + nx, y0 + ny }, .{ x1 + nx, y1 + ny },
            .{ x1 - nx, y1 - ny }, .{ x0 - nx, y0 - ny },
        };
        self.fillPoly(&quad, c, a);
        if (caps == .round) {
            self.disc(x0, y0, hw, c, a);
            self.disc(x1, y1, hw, c, a);
        }
    }

    /// Stroke a polyline (`.open`) or closed polygon outline (`.closed`) with
    /// thick round-capped segments.
    pub fn strokePath(self: *Canvas, pts: []const [2]f32, mode: PathMode, width: f32, c: Rgb, a: f32) void {
        if (pts.len < 2) return;
        var i: usize = 0;
        const last = if (mode == .closed) pts.len else pts.len - 1;
        while (i < last) : (i += 1) {
            const k = (i + 1) % pts.len;
            self.line(pts[i][0], pts[i][1], pts[k][0], pts[k][1], width, c, a, .round);
        }
    }

    /// Filled disc (final-pixel coords).
    pub fn disc(self: *Canvas, cx: f32, cy: f32, r: f32, c: Rgb, a: f32) void {
        self.discRing(cx, cy, 0, r, c, a);
    }

    /// Stroked circle of the given line `width` centred on radius `r`.
    pub fn ring(self: *Canvas, cx: f32, cy: f32, r: f32, width: f32, c: Rgb, a: f32) void {
        self.discRing(cx, cy, @max(0, r - width / 2), r + width / 2, c, a);
    }

    /// Fill the annulus inner_r..outer_r (inner_r=0 → solid disc).
    fn discRing(self: *Canvas, cx: f32, cy: f32, inner_r: f32, outer_r: f32, c: Rgb, a: f32) void {
        const s: f32 = @floatFromInt(self.ss);
        const cxi = cx * s;
        const cyi = cy * s;
        const ro = outer_r * s;
        const ri = inner_r * s;
        const ro2 = ro * ro;
        const ri2 = ri * ri;
        const iw: i64 = @intCast(self.iw);
        const ih: i64 = @intCast(self.ih);
        var iy: i64 = pxIndex(@floor(cyi - ro), 0, ih);
        const iy_end: i64 = pxIndex(@ceil(cyi + ro) + 1, 0, ih);
        while (iy < iy_end) : (iy += 1) {
            const dy = @as(f32, @floatFromInt(iy)) + 0.5 - cyi;
            var ix: i64 = pxIndex(@floor(cxi - ro), 0, iw);
            const ix_end: i64 = pxIndex(@ceil(cxi + ro) + 1, 0, iw);
            while (ix < ix_end) : (ix += 1) {
                const dx = @as(f32, @floatFromInt(ix)) + 0.5 - cxi;
                const d2 = dx * dx + dy * dy;
                if (d2 <= ro2 and d2 >= ri2) self.blendPx(ix, iy, c, a);
            }
        }
    }

    /// Draw `text` with cell height `h_px` (final px). `(x,y)` is the top of the
    /// text box; `anchor` positions it horizontally. Non-table chars are blank.
    pub fn text(self: *Canvas, x: f32, y: f32, s: []const u8, h_px: f32, c: Rgb, a: f32, anchor: Anchor) void {
        const scale = h_px / @as(f32, @floatFromInt(font.gh));
        const advance = @as(f32, @floatFromInt(font.gw + 1)) * scale;
        const total = if (s.len == 0) 0 else @as(f32, @floatFromInt(s.len)) * advance - scale;
        var x0 = x;
        switch (anchor) {
            .start => {},
            .middle => x0 -= total / 2,
            .end => x0 -= total,
        }
        for (s, 0..) |ch, ci| {
            const up = std.ascii.toUpper(ch);
            const cols = font.cols(up);
            const base_x = x0 + @as(f32, @floatFromInt(ci)) * advance;
            for (cols, 0..) |col, gx| {
                var gy: u32 = 0;
                while (gy < font.gh) : (gy += 1) {
                    if (col & (@as(u8, 1) << @as(u3, @intCast(gy))) != 0) {
                        self.fillRect(
                            base_x + @as(f32, @floatFromInt(gx)) * scale,
                            y + @as(f32, @floatFromInt(gy)) * scale,
                            scale,
                            scale,
                            c,
                            a,
                        );
                    }
                }
            }
        }
    }

    /// Copy `src`'s pixels into this canvas with its top-left at final-pixel
    /// (x,y) — the contact-sheet compositor. Both canvases must share the same
    /// supersample factor; out-of-bounds rows/columns are clipped.
    pub fn blit(self: *Canvas, src: *const Canvas, x: u32, y: u32) void {
        const ox = @as(usize, x) * self.ss;
        const oy = @as(usize, y) * self.ss;
        if (ox >= self.iw) return;
        const w = @min(src.iw, self.iw - ox);
        var row: usize = 0;
        while (row < src.ih) : (row += 1) {
            const dy = oy + row;
            if (dy >= self.ih) break;
            const so = row * src.iw * 3;
            const do = (dy * self.iw + ox) * 3;
            @memcpy(self.buf[do .. do + w * 3], src.buf[so .. so + w * 3]);
        }
    }

    /// Width in final px a `text` call of cell height `h_px` would occupy.
    pub fn textWidth(s: []const u8, h_px: f32) f32 {
        if (s.len == 0) return 0;
        const scale = h_px / @as(f32, @floatFromInt(font.gh));
        const advance = @as(f32, @floatFromInt(font.gw + 1)) * scale;
        return @as(f32, @floatFromInt(s.len)) * advance - scale;
    }

    /// Box-average the supersampled buffer down to `w×h` and PNG-encode it.
    pub fn toPng(self: *Canvas, alloc: std.mem.Allocator) png.Error![]u8 {
        if (self.ss == 1) return png.encodeRgb(alloc, self.w, self.h, self.buf);
        const out = try alloc.alloc(u8, @as(usize, self.w) * self.h * 3);
        defer alloc.free(out);
        const ss: usize = self.ss;
        const n: f32 = @floatFromInt(ss * ss);
        var oy: usize = 0;
        while (oy < self.h) : (oy += 1) {
            var ox: usize = 0;
            while (ox < self.w) : (ox += 1) {
                var sr: f32 = 0;
                var sg: f32 = 0;
                var sb: f32 = 0;
                var dy: usize = 0;
                while (dy < ss) : (dy += 1) {
                    const iy = oy * ss + dy;
                    var dx: usize = 0;
                    while (dx < ss) : (dx += 1) {
                        const o = (iy * self.iw + (ox * ss + dx)) * 3;
                        sr += @floatFromInt(self.buf[o]);
                        sg += @floatFromInt(self.buf[o + 1]);
                        sb += @floatFromInt(self.buf[o + 2]);
                    }
                }
                const oo = (oy * self.w + ox) * 3;
                out[oo] = numeric.checkedInt(u8, @round(sr / n)) orelse 0;
                out[oo + 1] = numeric.checkedInt(u8, @round(sg / n)) orelse 0;
                out[oo + 2] = numeric.checkedInt(u8, @round(sb / n)) orelse 0;
            }
        }
        return png.encodeRgb(alloc, self.w, self.h, out);
    }
};

test "fillPoly handles polygons past the 64-vertex stack scratch" {
    // A KiCad custom pad outline can carry 100-200+ vertices; a fixed 64-slot
    // buffer used to truncate it mid-shape, leaving the fill open. Approximate a
    // disc with 160 points and assert the centre actually fills.
    const alloc = std.testing.allocator;
    var cv = try Canvas.init(alloc, 40, 40, 1, Rgb.hex("#000000"));
    defer cv.deinit();
    const N = 160;
    var pts: [N][2]f32 = undefined;
    for (0..N) |i| {
        const t = @as(f32, @floatFromInt(i)) / N * 2.0 * std.math.pi;
        pts[i] = .{ 20 + 15 * @cos(t), 20 + 15 * @sin(t) };
    }
    cv.fillPoly(&pts, Rgb.hex("#b08d57"), 1.0);
    const o = (20 * cv.iw + 20) * 3; // centre pixel
    try std.testing.expect(cv.buf[o] == 0xb0 and cv.buf[o + 1] == 0x8d and cv.buf[o + 2] == 0x57);
}

test "canvas fills and downscales to a valid png" {
    const alloc = std.testing.allocator;
    var cv = try Canvas.init(alloc, 16, 16, 2, Rgb.hex("#0d1117"));
    defer cv.deinit();
    cv.fillRect(2, 2, 8, 8, Rgb.hex("#58a6ff"), 1.0);
    cv.disc(12, 12, 3, Rgb.hex("#ea580c"), 1.0);
    cv.line(0, 0, 16, 16, 2, Rgb.hex("#ffffff"), 0.8, .round);
    cv.text(8, 0, "U1", 6, Rgb.hex("#ffffff"), 1.0, .middle);
    const bytes = try cv.toPng(alloc);
    defer alloc.free(bytes);
    try std.testing.expect(bytes.len > 50);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 0x50, 0x4E, 0x47 }, bytes[0..4]);
}
