//! Footprint geometry for the placement optimizer. Loads a library
//! footprint (`lib/footprints/<name>.sexp`) and returns its courtyard
//! half-extents plus pad positions in millimetres, relative to the
//! footprint origin (KiCad convention: origin-centred, y-down).
//!
//! When the footprint file is missing or unparseable the loader returns a
//! synthesized box sized by the pin-count hint, so the optimizer can still
//! place the part (the buck IC `qfn9-3.3x4.5`, for one, has no library
//! footprint yet). Such results carry `fallback = true`.

const std = @import("std");
const parser = @import("../sexpr/parser.zig");
const ast = @import("../sexpr/ast.zig");
const infra_fs = @import("../infra/fs.zig");
const Node = ast.Node;

const MAX_FOOTPRINT_BYTES: usize = 1024 * 1024;
const PATH_FMT = "{s}/lib/footprints/{s}.sexp";
/// Extra clearance baked into a part's courtyard half-extents so the
/// optimizer leaves a little air between adjacent parts. Public so the
/// courtyard editor can invert it (effective extent ↔ written rect).
pub const BBOX_MARGIN_MM: f64 = 0.15;

/// One pad, positioned relative to the footprint origin (mm). `shape` and
/// `poly` are carried only for rendering (the PCB-layout page draws the real
/// outline via the shared footprint engine); placement/DRC/routing use the
/// `w`/`h` bounding box. `poly` is the footprint-absolute copper outline of a
/// custom pad (empty for simple pads).
pub const Pad = struct {
    number: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    shape: []const u8 = "rect",
    poly: []const [2]f64 = &.{},
    /// Through-hole (or NPTH) pad — its copper exists on every layer, so the
    /// router treats it as an obstacle (and a terminal) on both signal layers
    /// regardless of which side its part is placed on.
    thru: bool = false,
    /// Non-plated (mounting hole) — drilled but not plated; kept apart from
    /// plated holes because fabs take them as separate drill files.
    npth: bool = false,
    /// Drill diameter (mm; 0 = no hole). Oval drills record their larger axis.
    drill: f64 = 0,
};

/// A silkscreen line segment (footprint-local mm).
pub const SilkLine = struct { x1: f64, y1: f64, x2: f64, y2: f64 };

/// A silkscreen circle (footprint-local mm) — usually a pin-1 marker.
pub const SilkCircle = struct { cx: f64, cy: f64, r: f64 };

/// A footprint's physical extent: a box of `2*hw` by `2*hh` centred at
/// (`ccx`,`ccy`) in footprint-local coordinates — (0,0) unless the library
/// courtyard rect is off-origin (connectors whose pads hang off one side) —
/// plus its pads and silkscreen. `fallback` flags a synthesized (non-library)
/// box.
pub const Geom = struct {
    hw: f64,
    hh: f64,
    pads: []const Pad,
    fallback: bool,
    ccx: f64 = 0,
    ccy: f64 = 0,
    silk_lines: []const SilkLine = &.{},
    silk_circles: []const SilkCircle = &.{},
};

/// Load `<project_dir>/lib/footprints/<fp_name>.sexp`. Falls back to a
/// synthesized box (sized by `pin_count_hint`) on any failure.
pub fn load(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    fp_name: []const u8,
    pin_count_hint: usize,
    margin: f64,
) Geom {
    const path = std.fmt.allocPrint(arena, PATH_FMT, .{ project_dir, fp_name }) catch
        return fallbackGeom(pin_count_hint);
    const source = infra_fs.cwd().readFileAlloc(arena, path, MAX_FOOTPRINT_BYTES) catch
        return fallbackGeom(pin_count_hint);
    const nodes = parser.parse(arena, source) catch return fallbackGeom(pin_count_hint);
    if (nodes.len == 0 or !nodes[0].isForm("footprint")) return fallbackGeom(pin_count_hint);
    const children = nodes[0].asList() orelse return fallbackGeom(pin_count_hint);
    if (children.len < 2) return fallbackGeom(pin_count_hint);

    var pads: std.ArrayListUnmanaged(Pad) = .empty;
    var silk_lines: std.ArrayListUnmanaged(SilkLine) = .empty;
    var silk_circles: std.ArrayListUnmanaged(SilkCircle) = .empty;
    var court_hw: f64 = 0;
    var court_hh: f64 = 0;
    var have_court = false;

    var court_cx: f64 = 0;
    var court_cy: f64 = 0;
    for (children[2..]) |sub| {
        if (sub.isForm("pad")) {
            if (parsePad(arena, sub)) |p| pads.append(arena, p) catch return fallbackGeom(pin_count_hint);
        } else if (sub.isForm("courtyard")) {
            if (parseCourtyard(sub)) |ext| {
                court_hw = ext.hw;
                court_hh = ext.hh;
                court_cx = ext.cx;
                court_cy = ext.cy;
                have_court = true;
            }
        } else if (sub.isForm("silkscreen")) {
            parseSilkscreen(arena, sub, &silk_lines, &silk_circles);
        }
    }

    const pad_slice = pads.items;
    const ext_with_margin = blk: {
        if (have_court and court_hw > 0 and court_hh > 0)
            break :blk Ext{ .hw = court_hw, .hh = court_hh, .cx = court_cx, .cy = court_cy };
        break :blk padExtents(pad_slice) orelse return fallbackGeom(pin_count_hint);
    };
    return .{
        .hw = ext_with_margin.hw + margin,
        .hh = ext_with_margin.hh + margin,
        .pads = pad_slice,
        .fallback = false,
        .ccx = ext_with_margin.cx,
        .ccy = ext_with_margin.cy,
        .silk_lines = silk_lines.items,
        .silk_circles = silk_circles.items,
    };
}

/// Parse a `(silkscreen (line (x1 y1)(x2 y2)) (circle (cx cy) r) …)` block,
/// appending each line/circle. Best-effort: anything unrecognised is skipped.
fn parseSilkscreen(
    arena: std.mem.Allocator,
    node: Node,
    lines: *std.ArrayListUnmanaged(SilkLine),
    circles: *std.ArrayListUnmanaged(SilkCircle),
) void {
    const cl = node.asList() orelse return;
    if (cl.len < 2) return;
    for (cl[1..]) |c| {
        if (c.isForm("line")) {
            const l = parseSilkLine(c) orelse continue;
            lines.append(arena, l) catch return;
        } else if (c.isForm("circle")) {
            const ci = parseSilkCircle(c) orelse continue;
            circles.append(arena, ci) catch return;
        }
    }
}

/// `(x y)` → `[x, y]`, or null when not a 2-number point.
fn parsePoint(node: Node) ?[2]f64 {
    const cl = node.asList() orelse return null;
    if (cl.len < 2) return null;
    return .{ cl[0].asNumber() orelse return null, cl[1].asNumber() orelse return null };
}

/// `(line (x1 y1) (x2 y2))` → SilkLine.
fn parseSilkLine(node: Node) ?SilkLine {
    const cl = node.asList() orelse return null;
    if (cl.len < 3) return null;
    const a = parsePoint(cl[1]) orelse return null;
    const b = parsePoint(cl[2]) orelse return null;
    return .{ .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1] };
}

/// `(circle (cx cy) r)` → SilkCircle.
fn parseSilkCircle(node: Node) ?SilkCircle {
    const cl = node.asList() orelse return null;
    if (cl.len < 3) return null;
    const c = parsePoint(cl[1]) orelse return null;
    const r = cl[2].asNumber() orelse return null;
    return .{ .cx = c[0], .cy = c[1], .r = r };
}

/// `(pad <num> <type> <shape> (pos X Y [rot]) (size W H) …)` → Pad.
fn parsePad(arena: std.mem.Allocator, node: Node) ?Pad {
    const cl = node.asList() orelse return null;
    if (cl.len < 2) return null;
    const number = nodeText(arena, cl[1]);
    const ptype: []const u8 = if (cl.len >= 3) (cl[2].asAtom() orelse "smd") else "smd";
    const npth = std.mem.eql(u8, ptype, "npth");
    const thru = npth or std.mem.eql(u8, ptype, "thru");
    const shape: []const u8 = if (cl.len >= 4) (cl[3].asAtom() orelse "rect") else "rect";
    var x: f64 = 0;
    var y: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    var drill: f64 = 0;
    var poly: []const [2]f64 = &.{};
    for (cl[2..]) |c| {
        if (c.isForm("pos")) {
            const pl = c.asList() orelse continue;
            if (pl.len >= 2) x = pl[1].asNumber() orelse 0;
            if (pl.len >= 3) y = pl[2].asNumber() orelse 0;
        } else if (c.isForm("size")) {
            const sl = c.asList() orelse continue;
            if (sl.len >= 2) w = sl[1].asNumber() orelse 0;
            if (sl.len >= 3) h = sl[2].asNumber() orelse 0;
        } else if (c.isForm("poly")) {
            poly = parsePadPoly(arena, c) orelse poly;
        } else if (c.isForm("drill")) {
            // `(drill D)` or `(drill oval DX DY)` — record the larger axis.
            const dl = c.asList() orelse continue;
            for (dl[1..]) |dn| {
                if (dn.asNumber()) |d| drill = @max(drill, d);
            }
        }
    }
    return .{ .number = number, .x = x, .y = y, .w = w, .h = h, .shape = shape, .poly = poly, .thru = thru, .npth = npth, .drill = drill };
}

/// Parse a `(poly (x y) …)` form into footprint-absolute points, or null.
fn parsePadPoly(arena: std.mem.Allocator, node: Node) ?[]const [2]f64 {
    const cl = node.asList() orelse return null;
    if (cl.len < 4) return null; // need ≥3 points
    var pts: std.ArrayListUnmanaged([2]f64) = .empty;
    for (cl[1..]) |pn| {
        const pl = pn.asList() orelse continue;
        if (pl.len < 2) continue;
        const px = pl[0].asNumber() orelse continue;
        const py = pl[1].asNumber() orelse continue;
        pts.append(arena, .{ px, py }) catch return null;
    }
    if (pts.items.len < 3) return null;
    return pts.items;
}

const Ext = struct { hw: f64, hh: f64, cx: f64 = 0, cy: f64 = 0 };

/// `(courtyard (rect x1 y1 x2 y2))` or `(courtyard (circle (cx cy) r))`.
/// Returns the box's half-extents plus its centre offset from the footprint
/// origin — a courtyard need not be origin-centred (connectors whose pads
/// hang off one side), or null.
fn parseCourtyard(node: Node) ?Ext {
    const cl = node.asList() orelse return null;
    if (cl.len < 2) return null;
    const shape = cl[1];
    if (shape.isForm("rect")) return parseRectExt(shape);
    if (shape.isForm("circle")) return parseCircleExt(shape);
    return null;
}

/// `(rect x1 y1 x2 y2)` → the true box: half-extents + centre offset (no
/// max-abs symmetrizing — an off-origin rect keeps its position).
fn parseRectExt(shape: Node) ?Ext {
    const rl = shape.asList() orelse return null;
    if (rl.len < 5) return null;
    const x1 = rl[1].asNumber() orelse return null;
    const y1 = rl[2].asNumber() orelse return null;
    const x2 = rl[3].asNumber() orelse return null;
    const y2 = rl[4].asNumber() orelse return null;
    return .{
        .hw = @abs(x2 - x1) / 2,
        .hh = @abs(y2 - y1) / 2,
        .cx = (x1 + x2) / 2,
        .cy = (y1 + y2) / 2,
    };
}

/// `(circle (cx cy) r)` → half-extents (radius is the last numeric child)
/// centred on the circle's own centre when one is given.
fn parseCircleExt(shape: Node) ?Ext {
    const cc = shape.asList() orelse return null;
    if (cc.len < 2) return null;
    const r = cc[cc.len - 1].asNumber() orelse return null;
    const c = if (cc.len >= 3) (parsePoint(cc[1]) orelse [2]f64{ 0, 0 }) else [2]f64{ 0, 0 };
    return .{ .hw = @abs(r), .hh = @abs(r), .cx = c[0], .cy = c[1] };
}

/// Half-extents of the bounding box around every pad (including pad size).
fn padExtents(pads: []const Pad) ?Ext {
    if (pads.len == 0) return null;
    var hw: f64 = 0;
    var hh: f64 = 0;
    for (pads) |p| {
        hw = @max(hw, @abs(p.x) + p.w / 2);
        hh = @max(hh, @abs(p.y) + p.h / 2);
    }
    if (hw <= 0 and hh <= 0) return null;
    return .{ .hw = hw, .hh = hh };
}

/// A box sized by pin count when no real geometry is available.
fn fallbackGeom(pin_count_hint: usize) Geom {
    const pins: f64 = @floatFromInt(@max(pin_count_hint, 2));
    const half = @max(1.0, 0.5 * @sqrt(pins));
    return .{ .hw = half, .hh = half, .pads = &.{}, .fallback = true };
}

/// Literal text of a pad-number node: a quoted string / bare atom, or an
/// integer formatted as text (KiCad re-saves numeric pads as bare ints).
fn nodeText(arena: std.mem.Allocator, n: Node) []const u8 {
    if (n.asText()) |t| return t;
    if (n.asNumber()) |num| {
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(num))}) catch "";
    }
    return "";
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/geometry - parses pads and courtyard half-extents from a footprint sexp
test "load parses a 0402 footprint's pads and courtyard" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const src =
        \\(footprint "C_0402"
        \\  (pad 1 smd roundrect (pos -0.48 0.00) (size 0.56 0.62))
        \\  (pad 2 smd roundrect (pos 0.48 0.00) (size 0.56 0.62))
        \\  (courtyard (rect -0.91 -0.46 0.91 0.46)))
    ;
    const nodes = try parser.parse(arena, src);
    // Drive the same parsing paths load() uses, off an in-memory footprint.
    const children = nodes[0].asList().?;
    var pads: std.ArrayListUnmanaged(Pad) = .empty;
    var ext: ?Ext = null;
    for (children[2..]) |sub| {
        if (sub.isForm("pad")) {
            if (parsePad(arena, sub)) |p| try pads.append(arena, p);
        } else if (sub.isForm("courtyard")) {
            ext = parseCourtyard(sub);
        }
    }
    try testing.expectEqual(@as(usize, 2), pads.items.len);
    try testing.expectEqualStrings("1", pads.items[0].number);
    try testing.expectApproxEqAbs(@as(f64, -0.48), pads.items[0].x, 1e-9);
    try testing.expect(ext != null);
    try testing.expectApproxEqAbs(@as(f64, 0.91), ext.?.hw, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.46), ext.?.hh, 1e-9);
}

// spec: placement/geometry - synthesizes a fallback box sized by pin count when the footprint is missing
test "load falls back to a synthesized box for a missing footprint" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const g = load(arena, "/nonexistent-project-dir", "does-not-exist", 10, BBOX_MARGIN_MM);
    try testing.expect(g.fallback);
    try testing.expectEqual(@as(usize, 0), g.pads.len);
    try testing.expect(g.hw > 0 and g.hh > 0);
}

// spec: placement/geometry - parses silkscreen lines and circles from a footprint sexp
test "parseSilkscreen collects lines and circles" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const src =
        \\(silkscreen
        \\  (line (-0.26 -0.74) (0.26 -0.74))
        \\  (circle (-2.90 -2.50) 0.13))
    ;
    const nodes = try parser.parse(arena, src);
    var lines: std.ArrayListUnmanaged(SilkLine) = .empty;
    var circles: std.ArrayListUnmanaged(SilkCircle) = .empty;
    parseSilkscreen(arena, nodes[0], &lines, &circles);
    try testing.expectEqual(@as(usize, 1), lines.items.len);
    try testing.expectApproxEqAbs(@as(f64, -0.26), lines.items[0].x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.26), lines.items[0].x2, 1e-9);
    try testing.expectEqual(@as(usize, 1), circles.items.len);
    try testing.expectApproxEqAbs(@as(f64, 0.13), circles.items[0].r, 1e-9);
}
