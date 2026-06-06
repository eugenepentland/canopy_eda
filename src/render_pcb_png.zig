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

const Rgb = raster.Rgb;

// ── Theme (matches BOARD_JS) ───────────────────────────────────────────────
const BG = Rgb.hex("#0d1117");
const COURT_FILL = Rgb.hex("#161b22");
const HUB_STROKE = Rgb.hex("#58a6ff");
const PASSIVE_STROKE = Rgb.hex("#8b949e");
const SILK = Rgb.hex("#8b949e");
const PAD_COL = Rgb.hex("#b08d57");
const AW_PROX = Rgb.hex("#ea580c"); // hot decoupling loop / proximity hug
const AW_GND = Rgb.hex("#22b8cf"); // ground return airwire
const AW_SIG = Rgb.hex("#9aa7b4"); // generic signal airwire
const LOOP_RET = Rgb.hex("#58a6ff"); // L2 ground-return overlay
const TRACK_TOP = Rgb.hex("#ef4444"); // F.Cu trace
const TRACK_BOT = Rgb.hex("#3b82f6"); // B.Cu trace
const VIA_COL = Rgb.hex("#d8b048");
const VIA_HOLE = Rgb.hex("#0d1117");
const DRC_COL = Rgb.hex("#f85149");
const ACCENT = Rgb.hex("#f5c542"); // focus highlight
const TEXT_COL = Rgb.hex("#c9d1d9");
const TEXT_DIM = Rgb.hex("#6e7681");

const MARGIN_MM: f64 = 2.0;
const MIN_W: u32 = 400;
const MAX_W: u32 = 2200;
const MAX_H: u32 = 2600;
const SS: u32 = 2; // supersample factor for anti-aliasing
const HEADER_H: u32 = 30;
const LEGEND_H: u32 = 22;
const DIM_A: f32 = 0.20; // alpha for de-emphasised elements in focus mode

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
};

/// Render `p` to PNG bytes owned by `alloc`.
pub fn render(alloc: std.mem.Allocator, p: optimizer.Placement, opts: Options) png.Error![]u8 {
    const cw_mm = @max(p.maxx - p.minx, 1.0) + 2 * MARGIN_MM;
    const ch_mm = @max(p.maxy - p.miny, 1.0) + 2 * MARGIN_MM;

    var board_w = std.math.clamp(opts.width, MIN_W, MAX_W);
    var scale = @as(f64, @floatFromInt(board_w)) / cw_mm;
    var board_h_f = ch_mm * scale;
    if (board_h_f > MAX_H) {
        scale = @as(f64, @floatFromInt(MAX_H)) / ch_mm;
        board_h_f = @floatFromInt(MAX_H);
        board_w = @intFromFloat(@round(cw_mm * scale));
    }
    const board_h: u32 = @intFromFloat(@round(board_h_f));

    const focus = opts.highlight_nets.len > 0 or opts.highlight_refs.len > 0;
    const total_h = HEADER_H + board_h + LEGEND_H;
    var cv = try raster.Canvas.init(alloc, board_w, total_h, SS, BG);
    defer cv.deinit();

    // Highlight sets: full net names matching any token, and uppercased refs.
    var hot_nets = std.StringHashMap(void).init(alloc);
    defer hot_nets.deinit();
    var hot_refs = std.StringHashMap(void).init(alloc);
    defer hot_refs.deinit();
    try buildHighlightSets(alloc, p, opts, &hot_nets, &hot_refs);

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

    var ctx = Ctx{
        .cv = &cv,
        .scale = scale,
        .minx = p.minx,
        .miny = p.miny,
        .yoff = @floatFromInt(HEADER_H),
        .p = p,
        .focus = focus,
        .caption = caption,
        .hot_nets = &hot_nets,
        .hot_refs = &hot_refs,
        .pad_net = &pad_net,
    };

    ctx.drawParts();
    ctx.drawAirwires();
    ctx.drawLoops();
    if (opts.routed) |r| ctx.drawRouted(r);
    ctx.drawViolations(opts.violations);
    ctx.drawLabels();
    ctx.drawHeader(opts);
    ctx.drawLegend(opts.routed != null);

    return cv.toPng(alloc);
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
    fn world(part: optimizer.Part, lx: f64, ly: f64) [2]f64 {
        const a = part.rot * std.math.pi / 180.0;
        const c = @cos(a);
        const s = @sin(a);
        return .{ part.x + lx * c - ly * s, part.y + lx * s + ly * c };
    }
    /// Pixel point of a footprint-local offset on `part`.
    fn lp(self: *Ctx, part: optimizer.Part, lx: f64, ly: f64) [2]f32 {
        const w = world(part, lx, ly);
        return .{ self.xpx(w[0]), self.ypx(w[1]) };
    }

    fn netOf(self: *Ctx, ref: []const u8, pad: []const u8) ?[]const u8 {
        var buf: [128]u8 = undefined;
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
        for (self.p.parts) |part| {
            const active = self.partActive(part);
            const base_a: f32 = if (active) 1.0 else DIM_A;
            const stroke = if (part.kind == .hub) HUB_STROKE else PASSIVE_STROKE;
            // Courtyard (rotated quad about the part origin).
            const court = [_][2]f32{
                self.lp(part, -part.hw, -part.hh), self.lp(part, part.hw, -part.hh),
                self.lp(part, part.hw, part.hh),   self.lp(part, -part.hw, part.hh),
            };
            self.cv.fillPoly(&court, COURT_FILL, base_a);
            self.cv.strokePath(&court, .closed, self.outlineW(active), stroke, base_a);
            if (self.focus and active and (self.refHot(part.ref_des))) {
                self.cv.strokePath(&court, .closed, self.outlineW(true) + self.pw(1.5), ACCENT, 0.9);
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
            const col = if (hot) ACCENT else PAD_COL;
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
        }
    }

    fn drawAirwires(self: *Ctx) void {
        for (self.p.links) |l| {
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
            // Hot power leg cap→hub.
            self.cv.line(cp[0], cp[1], pp[0], pp[1], self.pw(1.3), AW_PROX, a, .butt);
            // L2 ground-return path cap_gnd → cap_pwr → hub_pwr → hub_gnd.
            const ret = [_][2]f32{ cg, cp, pp, gp };
            self.cv.strokePath(&ret, .open, self.pw(1.1), LOOP_RET, a * 0.85);
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

    fn drawLabels(self: *Ctx) void {
        const h = self.pw(9);
        for (self.p.parts) |part| {
            const active = self.partActive(part);
            if (self.focus and !active) continue;
            const eff_hh = if (isQuarter(part.rot)) part.hw else part.hh;
            const cx = self.xpx(part.x);
            const top = self.ypx(part.y) - self.len(eff_hh) - h - self.pw(2);
            const col = if (self.focus and self.refHot(part.ref_des)) ACCENT else if (part.kind == .hub) HUB_STROKE else PASSIVE_STROKE;
            self.cv.text(cx, top, part.ref_des, h, col, 1.0, .middle);
        }
    }

    fn drawHeader(self: *Ctx, opts: Options) void {
        const pad = self.pw(6);
        if (opts.title.len > 0) {
            self.cv.text(pad, self.pw(5), opts.title, self.pw(13), TEXT_COL, 1.0, .start);
        }
        if (self.focus) self.cv.text(pad, self.pw(18), self.caption, self.pw(9), ACCENT, 1.0, .start);
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
/// True if the uppercased `s` is a member of `set` (whose keys are uppercased).
fn upperInSet(set: *std.StringHashMap(void), s: []const u8) bool {
    if (s.len > 64) return false;
    var buf: [64]u8 = undefined;
    for (s, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
    return set.contains(buf[0..s.len]);
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
