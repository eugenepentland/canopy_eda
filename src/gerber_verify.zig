//! Gerber CAM self-verification (audit item 0.2a). A minimal RS-274X reader —
//! just enough to parse OUR OWN `export_gerber.zig` output — reads a written
//! copper layer back and diffs every flashed pad and drawn track against the
//! placement model it came from. This locks the frame / polarity / aperture /
//! coordinate-format conventions against silent regressions forever: change any
//! of them and the read-back test fails, not a fab three weeks later.
//!
//! Scope of the reader (exactly what our writer emits): `%FSLAX46Y46*%` (4.6
//! integer.fraction coordinates), `%MOMM*%`, aperture defs `%ADDnnK,w[Xh]*%`
//! for K ∈ {C,R,O}, aperture selects `Dnn*` (nn ≥ 10), `X…Y…D03*` flashes,
//! `X…Y…D02*`/`D01*` moves+draws, `G36*/G37*` regions, native `G02`/`G03`
//! arcs, and `%LPD*%`/`%LPC*%` polarity. The ordered operation stream is also
//! the source for the in-app CAM preview, so that surface paints the bytes the
//! fab receives instead of independently reconstructing their geometry.
//!
//! Coordinates come back through the shared `export_fab.Frame`: a parsed
//! integer (x,y) is `(x/1e6, y/1e6)` mm in the y-up output frame, and the
//! expectations are given in placement space, so the verifier maps each
//! expectation with `frame.pt(...)` before comparing.

const std = @import("std");
const export_fab = @import("export_fab.zig");

/// Aperture shape, mirroring `export_gerber`'s `ApKind`.
pub const ApKind = enum { c, r, o };

/// One parsed aperture definition (dimensions in mm; height = width for C).
pub const Aperture = struct { code: u32, kind: ApKind, w: f64, h: f64 };

/// One flash (a D03) at a coordinate, with the aperture that was current.
pub const Flash = struct { x: f64, y: f64, kind: ApKind, w: f64, h: f64, dark: bool };

/// One drawn segment (a D02 move then a D01 draw), OUTSIDE a region, with the
/// aperture width that was current.
pub const Segment = struct { x1: f64, y1: f64, x2: f64, y2: f64, w: f64, dark: bool };

/// One native circular interpolation, in output-frame coordinates. `cw` is
/// Gerber G02 (false is G03); the aperture is circular in every arc our writer
/// emits, so its diameter is represented by `w` like a linear segment.
pub const Arc = struct { p1: [2]f64, p2: [2]f64, center: [2]f64, w: f64, cw: bool, dark: bool };

/// One filled G36/G37 contour. Points include the D02 start and every D01
/// vertex, including the writer's explicit closing point when needed.
pub const Region = struct { points: []const [2]f64, dark: bool };

/// Ordered draw operations. Polarity composition is order-sensitive (mask
/// terminal repairs clear an opening and then repaint its rounded patch), so a
/// preview cannot safely regroup flashes, strokes, and regions by shape.
pub const Op = union(enum) {
    flash: Flash,
    segment: Segment,
    arc: Arc,
    region: Region,
};

/// The parsed contents of one copper Gerber file (mm, y-up frame).
pub const Parsed = struct {
    apertures: []const Aperture,
    flashes: []const Flash,
    segments: []const Segment,
    arcs: []const Arc,
    regions: []const Region,
    /// Every flash/stroke/region in byte order, retaining polarity.
    ops: []const Op,
};

pub const ParseError = error{ MalformedCoord, MalformedAperture, MissingFormat, Overflow } || std.mem.Allocator.Error;

/// Parse one RS-274X copper file. Fails only on genuinely malformed input from
/// our own writer (a coordinate that doesn't fit the 4.6 format, an aperture
/// def we can't read) — those are the regressions this is meant to catch.
pub fn parse(arena: std.mem.Allocator, bytes: []const u8) ParseError!Parsed {
    var apertures: std.ArrayList(Aperture) = .empty;
    var flashes: std.ArrayList(Flash) = .empty;
    var segments: std.ArrayList(Segment) = .empty;
    var arcs: std.ArrayList(Arc) = .empty;
    var regions: std.ArrayList(Region) = .empty;
    var ops: std.ArrayList(Op) = .empty;
    var region_points: std.ArrayList([2]f64) = .empty;

    var saw_format = false;
    var dark = true;
    var in_region = false;
    var region_dark = true;
    var cur_ap: ?Aperture = null;
    var cx: f64 = 0;
    var cy: f64 = 0;

    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0) continue;

        // Extended commands are wrapped in %…*%.
        if (line[0] == '%') {
            const inner = std.mem.trim(u8, line, "%*");
            if (std.mem.startsWith(u8, inner, "FSLAX")) {
                // We only support 4.6; assert the format we always emit.
                if (std.mem.indexOf(u8, inner, "46Y46") == null) return error.MissingFormat;
                saw_format = true;
            } else if (std.mem.startsWith(u8, inner, "ADD")) {
                try apertures.append(arena, try parseAperture(inner));
            } else if (std.mem.eql(u8, inner, "LPD")) {
                dark = true;
            } else if (std.mem.eql(u8, inner, "LPC")) {
                dark = false;
            }
            continue;
        }

        // G-codes: region on/off plus native circular interpolation. Region
        // contours are finalized only at G37 so they occupy one ordered op.
        if (std.mem.eql(u8, line, "G36*")) {
            in_region = true;
            region_dark = dark;
            region_points.clearRetainingCapacity();
            continue;
        }
        if (std.mem.eql(u8, line, "G37*")) {
            in_region = false;
            if (region_points.items.len >= 3) {
                const region = Region{ .points = try region_points.toOwnedSlice(arena), .dark = region_dark };
                try regions.append(arena, region);
                try ops.append(arena, .{ .region = region });
            } else {
                region_points.clearRetainingCapacity();
            }
            continue;
        }
        const arc_cw = std.mem.startsWith(u8, line, "G02");
        const arc_ccw = std.mem.startsWith(u8, line, "G03");
        if (std.mem.startsWith(u8, line, "G")) {
            if (!arc_cw and !arc_ccw) continue; // G01*, G75*
        }
        if (std.mem.eql(u8, line, "M02*")) break;

        // Aperture select: Dnn* with nn >= 10 (a bare Dnn with no coords).
        if (line[0] == 'D' and std.mem.endsWith(u8, line, "*") and
            std.mem.indexOfScalar(u8, line, 'X') == null)
        {
            const code = std.fmt.parseInt(u32, line[1 .. line.len - 1], 10) catch continue;
            cur_ap = apertureByCode(apertures.items, code);
            continue;
        }

        // A coordinate op: X…Y…D0n*.
        if (!saw_format) return error.MissingFormat;
        const op = try parseCoordLine(line, cx, cy);
        switch (op.d) {
            2 => {
                cx = op.x;
                cy = op.y;
                if (in_region) try region_points.append(arena, .{ cx, cy });
            },
            1 => {
                if (in_region) {
                    if (arc_cw or arc_ccw) {
                        try appendRegionArc(&region_points, arena, .{ cx, cy }, .{ op.x, op.y }, .{ op.i, op.j }, arc_cw);
                    } else {
                        try region_points.append(arena, .{ op.x, op.y });
                    }
                } else if (arc_cw or arc_ccw) {
                    const arc = Arc{
                        .p1 = .{ cx, cy },
                        .p2 = .{ op.x, op.y },
                        .center = .{ cx + op.i, cy + op.j },
                        .w = if (cur_ap) |a| a.w else 0,
                        .cw = arc_cw,
                        .dark = dark,
                    };
                    try arcs.append(arena, arc);
                    try ops.append(arena, .{ .arc = arc });
                } else {
                    const segment = Segment{
                        .x1 = cx,
                        .y1 = cy,
                        .x2 = op.x,
                        .y2 = op.y,
                        .w = if (cur_ap) |a| a.w else 0,
                        .dark = dark,
                    };
                    try segments.append(arena, segment);
                    try ops.append(arena, .{ .segment = segment });
                }
                cx = op.x;
                cy = op.y;
            },
            3 => {
                if (cur_ap) |a| {
                    const flash = Flash{ .x = op.x, .y = op.y, .kind = a.kind, .w = a.w, .h = a.h, .dark = dark };
                    try flashes.append(arena, flash);
                    try ops.append(arena, .{ .flash = flash });
                }
                cx = op.x;
                cy = op.y;
            },
            else => {},
        }
    }

    return .{
        .apertures = try apertures.toOwnedSlice(arena),
        .flashes = try flashes.toOwnedSlice(arena),
        .segments = try segments.toOwnedSlice(arena),
        .arcs = try arcs.toOwnedSlice(arena),
        .regions = try regions.toOwnedSlice(arena),
        .ops = try ops.toOwnedSlice(arena),
    };
}

/// Flatten one native interpolation while it is part of a G36/G37 contour.
/// `Region` is intentionally a polygon because the preview composes it with a
/// normal canvas fill; retaining only the interpolation's endpoint would turn
/// every rounded Gerber boundary into its chord.
fn appendRegionArc(
    points: *std.ArrayList([2]f64),
    arena: std.mem.Allocator,
    start: [2]f64,
    finish: [2]f64,
    center_offset: [2]f64,
    cw: bool,
) std.mem.Allocator.Error!void {
    const center = [2]f64{ start[0] + center_offset[0], start[1] + center_offset[1] };
    const radius = std.math.hypot(start[0] - center[0], start[1] - center[1]);
    if (!(radius > 0) or !std.math.isFinite(radius)) return points.append(arena, finish);

    const a0 = std.math.atan2(start[1] - center[1], start[0] - center[0]);
    var a1 = std.math.atan2(finish[1] - center[1], finish[0] - center[0]);
    if (cw) {
        while (a1 >= a0) a1 -= std.math.tau;
    } else {
        while (a1 <= a0) a1 += std.math.tau;
    }
    // Bound the CHORD SAGITTA, not merely its length. A fixed 0.02 mm edge is
    // visibly non-tangent where a small fillet meets its following straight
    // edge: the final chord cuts inside the circle and leaves a thin triangular
    // sliver in the generated-Gerber CAM preview. 50 nm is comfortably below
    // a screen pixel even at inspection zoom while keeping ordinary fillets
    // compact. Retain the old length ceiling as a second bound for very large
    // radii. The cap also keeps malformed third-party input from manufacturing
    // an unbounded polygon, though our own writer stays far below it.
    const max_sagitta_mm = 0.00005;
    const max_edge_mm = 0.02;
    const sagitta_step = if (radius <= max_sagitta_mm)
        std.math.pi
    else
        2 * std.math.acos(std.math.clamp(1 - max_sagitta_mm / radius, -1, 1));
    const length_step = max_edge_mm / radius;
    const max_step = @max(@min(sagitta_step, length_step), std.math.floatEps(f64));
    const raw_steps = @ceil(@abs(a1 - a0) / max_step);
    const steps = @max(@as(usize, 2), @as(usize, @intFromFloat(@min(raw_steps, 4096.0))));
    for (1..steps + 1) |i| {
        if (i == steps) {
            try points.append(arena, finish);
            continue;
        }
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const angle = a0 + (a1 - a0) * t;
        try points.append(arena, .{ center[0] + radius * @cos(angle), center[1] + radius * @sin(angle) });
    }
}

/// `%ADDnnK,w[Xh]*%` → an `Aperture`. `inner` is the text between `%…*%`.
fn parseAperture(inner: []const u8) ParseError!Aperture {
    // inner = "ADD10C,0.400000" | "ADD11R,1.000000X0.500000"
    var rest = inner["ADD".len..];
    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
    if (i == 0 or i >= rest.len) return error.MalformedAperture;
    const code = std.fmt.parseInt(u32, rest[0..i], 10) catch return error.MalformedAperture;
    const kind: ApKind = switch (rest[i]) {
        'C' => .c,
        'R' => .r,
        'O' => .o,
        else => return error.MalformedAperture,
    };
    rest = rest[i + 1 ..];
    if (rest.len == 0 or rest[0] != ',') return error.MalformedAperture;
    rest = rest[1..];
    if (std.mem.indexOfScalar(u8, rest, 'X')) |xi| {
        const w = std.fmt.parseFloat(f64, rest[0..xi]) catch return error.MalformedAperture;
        const h = std.fmt.parseFloat(f64, rest[xi + 1 ..]) catch return error.MalformedAperture;
        return .{ .code = code, .kind = kind, .w = w, .h = h };
    }
    const w = std.fmt.parseFloat(f64, rest) catch return error.MalformedAperture;
    return .{ .code = code, .kind = kind, .w = w, .h = w };
}

const CoordOp = struct { x: f64, y: f64, i: f64 = 0, j: f64 = 0, d: u8 };

/// Parse `X<int>Y<int>D0n*` (either coord may be omitted → keep the previous).
/// Integers are 4.6 fixed-point (÷1e6 → mm).
fn parseCoordLine(line: []const u8, prev_x: f64, prev_y: f64) ParseError!CoordOp {
    var x = prev_x;
    var y = prev_y;
    var i_off: f64 = 0;
    var j_off: f64 = 0;
    var d: u8 = 0;
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '*') break;
        switch (c) {
            'X', 'Y', 'I', 'J', 'D' => {
                i += 1;
                const start = i;
                if (i < line.len and (line[i] == '-' or line[i] == '+')) i += 1;
                while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
                if (i == start) return error.MalformedCoord;
                const num = line[start..i];
                if (c == 'D') {
                    d = std.fmt.parseInt(u8, num, 10) catch return error.MalformedCoord;
                } else {
                    const v = @as(f64, @floatFromInt(std.fmt.parseInt(i64, num, 10) catch return error.MalformedCoord)) / 1e6;
                    switch (c) {
                        'X' => x = v,
                        'Y' => y = v,
                        'I' => i_off = v,
                        'J' => j_off = v,
                        else => {},
                    }
                }
            },
            else => i += 1,
        }
    }
    return .{ .x = x, .y = y, .i = i_off, .j = j_off, .d = d };
}

fn apertureByCode(aps: []const Aperture, code: u32) ?Aperture {
    for (aps) |a| if (a.code == code) return a;
    return null;
}

// ── Read-back verification ──────────────────────────────────────────────────

/// An expected pad flash, in PLACEMENT coordinates (the verifier applies the
/// frame). `w`/`h` are the flashed aperture size — after the ±90° swap the
/// writer applies, so give them post-rotation.
pub const ExpectFlash = struct { x: f64, y: f64, kind: ApKind, w: f64, h: f64 };

/// An expected track segment, in PLACEMENT coordinates, at width `w`.
pub const ExpectSegment = struct { x1: f64, y1: f64, x2: f64, y2: f64, w: f64 };

/// One thing that didn't match, for the report.
pub const Miss = struct { what: []const u8, detail: []const u8 };

/// The outcome of a read-back: what was checked and what (if anything) was
/// missing. `ok` ⇒ every expected feature was found at the right place.
pub const Report = struct {
    checked_flashes: usize,
    checked_segments: usize,
    misses: []const Miss,

    /// True when every expected flash and segment was found — the read-back
    /// matched the placement model exactly.
    pub fn ok(self: Report) bool {
        return self.misses.len == 0;
    }
};

/// Coordinate tolerance (mm): our 4.6 format rounds to 1e-6 mm, so 1e-4 is
/// three orders of margin while still catching a real frame/scale bug.
pub const eps_mm: f64 = 1e-4;

/// Read `gerber_bytes` (one copper layer our writer produced) back and confirm
/// every `flashes` and `segments` expectation appears at its frame-mapped
/// coordinate with the right aperture size. Returns a `Report`; `ok()` gates
/// the conventions test.
pub fn verifyCopperLayer(
    arena: std.mem.Allocator,
    gerber_bytes: []const u8,
    frame: export_fab.Frame,
    flashes: []const ExpectFlash,
    segments: []const ExpectSegment,
) ParseError!Report {
    const parsed = try parse(arena, gerber_bytes);
    var misses: std.ArrayList(Miss) = .empty;

    for (flashes) |ef| {
        const p = frame.pt(ef.x, ef.y);
        var found = false;
        for (parsed.flashes) |gf| {
            if (flashMatches(gf, ef, p)) {
                found = true;
                break;
            }
        }
        if (!found) try misses.append(arena, .{
            .what = "flash",
            .detail = try std.fmt.allocPrint(arena, "expected {s} {d:.3}x{d:.3} at ({d:.3},{d:.3})", .{ @tagName(ef.kind), ef.w, ef.h, p[0], p[1] }),
        });
    }

    for (segments) |es| {
        const a = frame.pt(es.x1, es.y1);
        const b = frame.pt(es.x2, es.y2);
        var found = false;
        for (parsed.segments) |gs| {
            if (segMatches(gs, es, a, b)) {
                found = true;
                break;
            }
        }
        if (!found) try misses.append(arena, .{
            .what = "segment",
            .detail = try std.fmt.allocPrint(arena, "expected w{d:.3} ({d:.3},{d:.3})→({d:.3},{d:.3})", .{ es.w, a[0], a[1], b[0], b[1] }),
        });
    }

    return .{
        .checked_flashes = flashes.len,
        .checked_segments = segments.len,
        .misses = try misses.toOwnedSlice(arena),
    };
}

fn approx(a: f64, b: f64) bool {
    return @abs(a - b) <= eps_mm;
}

/// Does parsed flash `gf` satisfy expectation `ef` at frame-mapped point `p`?
fn flashMatches(gf: Flash, ef: ExpectFlash, p: [2]f64) bool {
    if (gf.kind != ef.kind) return false;
    if (!approx(gf.x, p[0]) or !approx(gf.y, p[1])) return false;
    return approx(gf.w, ef.w) and approx(gf.h, ef.h);
}

/// Does parsed segment `gs` satisfy expectation `es` between frame-mapped
/// endpoints `a`,`b` (either orientation, same width)?
fn segMatches(gs: Segment, es: ExpectSegment, a: [2]f64, b: [2]f64) bool {
    if (!approx(gs.w, es.w)) return false;
    const p1 = [2]f64{ gs.x1, gs.y1 };
    const p2 = [2]f64{ gs.x2, gs.y2 };
    const fwd = ptEq(p1, a) and ptEq(p2, b);
    const rev = ptEq(p1, b) and ptEq(p2, a);
    return fwd or rev;
}

/// Two frame-mapped points equal within the coordinate tolerance.
fn ptEq(a: [2]f64, b: [2]f64) bool {
    return approx(a[0], b[0]) and approx(a[1], b[1]);
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const geometry = @import("placement/geometry.zig");
const export_gerber = @import("export_gerber.zig");
const export_kicad = @import("export_kicad.zig");

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

// spec: gerber_verify - the reader parses our own aperture/flash/segment/region output
// spec: export_gerber - Gerber read-back preserves ordered polarity operations, filled contours, and native arcs for the Assembly CAM preview
test "parse reads apertures, flashes, segments, and regions" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // ADD10 = a rect pad (flashed), ADD11 = a 0.2-wide round track aperture
    // (drawn) — exactly the two aperture shapes our copper writer emits.
    const g =
        "%FSLAX46Y46*%\n%MOMM*%\nG01*\n%LPD*%\n" ++
        "%ADD10R,1.000000X0.500000*%\n%ADD11C,0.200000*%\n" ++
        "D10*\nX5000000Y5000000D03*\n" ++
        "D11*\nX1000000Y2000000D02*\nX3000000Y2000000D01*\n" ++
        "X3000000Y3000000D02*\nG02X5000000Y3000000I1000000J0D01*\nG01*\n" ++
        "G36*\nX0Y0D02*\nX1000000Y0D01*\nG03X2000000Y1000000I0J1000000D01*\nG01*\nX0Y0D01*\nG37*\n" ++
        "M02*\n";
    const p = try parse(arena, g);
    try testing.expectEqual(@as(usize, 2), p.apertures.len);
    try testing.expectEqual(@as(usize, 1), p.flashes.len);
    try testing.expectEqual(ApKind.r, p.flashes[0].kind);
    try testing.expectApproxEqAbs(@as(f64, 5), p.flashes[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), p.flashes[0].w, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), p.flashes[0].h, 1e-9);
    // One track segment outside the region (0.2-wide); the region's contour
    // draws are NOT segments.
    try testing.expectEqual(@as(usize, 1), p.segments.len);
    try testing.expectApproxEqAbs(@as(f64, 0.2), p.segments[0].w, 1e-9);
    try testing.expectEqual(@as(usize, 1), p.arcs.len);
    try testing.expect(p.arcs[0].cw);
    try testing.expectApproxEqAbs(@as(f64, 4), p.arcs[0].center[0], 1e-9);
    try testing.expectEqual(@as(usize, 1), p.regions.len);
    try testing.expect(p.regions[0].points.len > 3);
    var saw_curved_region_point = false;
    for (p.regions[0].points) |point| {
        if (point[0] > 1.5 and point[1] < 0.5) saw_curved_region_point = true;
    }
    try testing.expect(saw_curved_region_point);
    try testing.expectEqual(@as(usize, 4), p.ops.len);
}

// spec: export_gerber - generated-Gerber CAM region fillets meet straight edges without a visible chord sliver
test "region arc read-back bounds the fillet chord sliver" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    // A 0.05 mm quarter-circle fillet is the hostile case for the old fixed
    // 0.02 mm chord length: only four edges represented the curve and the last
    // one met the following straight with about 1 um of visible sagitta.
    const g =
        "%FSLAX46Y46*%\n%MOMM*%\nG01*\n%LPD*%\n" ++
        "G36*\nX0Y50000D02*\nG02X50000Y0I0J-50000D01*\nG01*\n" ++
        "X100000Y0D01*\nX0Y50000D01*\nG37*\nM02*\n";
    const parsed = try parse(arena, g);
    try testing.expectEqual(@as(usize, 1), parsed.regions.len);
    const points = parsed.regions[0].points;
    try testing.expect(points.len > 12);

    // Every flattened chord of the circular portion stays within 50 nm of
    // the native curve at its midpoint. In particular this covers the final
    // arc chord immediately before the tangent straight section.
    const center = [2]f64{ 0, 0 };
    const radius: f64 = 0.05;
    var previous = points[0];
    for (points[1..]) |point| {
        if (point[0] > radius + 1e-12 or point[1] < -1e-12) break;
        const mid = [2]f64{ (previous[0] + point[0]) / 2, (previous[1] + point[1]) / 2 };
        const sagitta = radius - std.math.hypot(mid[0] - center[0], mid[1] - center[1]);
        try testing.expect(sagitta <= 0.00005 + 1e-12);
        previous = point;
    }
}

// spec: gerber_verify - a written copper layer reads back matching the placement model
test "round-trip: writeLayer then verifyCopperLayer matches every pad and track" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1, .y = 0, .w = 1.0, .h = 0.5 },
        .{ .number = "2", .x = 1, .y = 0, .w = 1.4, .h = 1.4, .shape = "circle", .thru = true, .drill = 0.9 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    const tracks = [_]router.Track{
        .{ .x1 = 9, .y1 = 5, .x2 = 12, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
    };
    const frame = export_fab.frameFor(placement);

    var aw: std.Io.Writer.Allocating = .init(arena);
    try export_gerber.writeLayer(&aw.writer, arena, placement, .{ .tracks = &tracks }, &.{}, frame, .{ .copper = .top }, .{ .function = "Copper,L1,Top" });

    // Pad 1 is a rect at world (9,5) — 1.0x0.5. Pad 2 a circle at (11,5), 1.4.
    // The track is a 0.2-wide segment from (9,5) to (12,5).
    const ef = [_]ExpectFlash{
        .{ .x = 9, .y = 5, .kind = .r, .w = 1.0, .h = 0.5 },
        .{ .x = 11, .y = 5, .kind = .c, .w = 1.4, .h = 1.4 },
    };
    const es = [_]ExpectSegment{
        .{ .x1 = 9, .y1 = 5, .x2 = 12, .y2 = 5, .w = 0.2 },
    };
    const report = try verifyCopperLayer(arena, aw.written(), frame, &ef, &es);
    try testing.expect(report.ok());
    try testing.expectEqual(@as(usize, 2), report.checked_flashes);
    try testing.expectEqual(@as(usize, 1), report.checked_segments);
}

// spec: gerber_verify - a pad flashed at the wrong coordinate is reported as a miss
test "verify reports a mislocated pad" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.0, .h = 1.0 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 5 },
    };
    const placement = testPlacement(&parts, &.{});
    const frame = export_fab.frameFor(placement);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try export_gerber.writeLayer(&aw.writer, arena, placement, .{}, &.{}, frame, .{ .copper = .top }, .{ .function = "Copper,L1,Top" });

    // Expect the pad at the WRONG place (off by 5 mm) → a miss.
    const ef = [_]ExpectFlash{.{ .x = 15, .y = 5, .kind = .r, .w = 1.0, .h = 1.0 }};
    const report = try verifyCopperLayer(arena, aw.written(), frame, &ef, &.{});
    try testing.expect(!report.ok());
    try testing.expectEqual(@as(usize, 1), report.misses.len);
    try testing.expectEqualStrings("flash", report.misses[0].what);
}

// spec: gerber_verify - top and bottom copper both read back correctly (frame/side conventions)
test "round-trip covers both board sides" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    const top_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8 }};
    const bot_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &top_pads, .fallback = false, .x = 6, .y = 4 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &bot_pads, .fallback = false, .x = 14, .y = 6, .side = .bottom },
    };
    const placement = testPlacement(&parts, &.{});
    const frame = export_fab.frameFor(placement);

    var tw: std.Io.Writer.Allocating = .init(arena);
    try export_gerber.writeLayer(&tw.writer, arena, placement, .{}, &.{}, frame, .{ .copper = .top }, .{ .function = "Copper,L1,Top" });
    const top_flash = [_]ExpectFlash{.{ .x = 6, .y = 4, .kind = .r, .w = 0.8, .h = 0.8 }};
    try testing.expect((try verifyCopperLayer(arena, tw.written(), frame, &top_flash, &.{})).ok());

    var bw: std.Io.Writer.Allocating = .init(arena);
    try export_gerber.writeLayer(&bw.writer, arena, placement, .{}, &.{}, frame, .{ .copper = .bottom }, .{ .function = "Copper,L4,Bot" });
    const bot_flash = [_]ExpectFlash{.{ .x = 14, .y = 6, .kind = .r, .w = 0.6, .h = 0.6 }};
    try testing.expect((try verifyCopperLayer(arena, bw.written(), frame, &bot_flash, &.{})).ok());
}

test "parseCoordLine reports MalformedCoord for a coord letter at end of line" {
    // "X" ends exactly at the line boundary: the sign-peek guard `i < line.len`
    // stops the read, so the missing digits surface as MalformedCoord. Relaxing
    // it to `i <= line.len` reads one past the end (a panic), so this must be a
    // clean error, not a crash.
    try testing.expectError(error.MalformedCoord, parseCoordLine("X", 0, 0));
    try testing.expectError(error.MalformedCoord, parseCoordLine("Y", 1.5, 2.5));
}
