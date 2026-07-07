//! Assembly/fab text outputs generated straight from a solved placement:
//! the pick-and-place centroid CSV and the Excellon drill files — together
//! with `export_gerber.zig` (copper/mask/paste/silk/edge) the full
//! netlisp-native manufacturing package, so a fab can build the board and an
//! assembler can place it without KiCad in the loop.
//!
//! All outputs share one coordinate `Frame`: the placement model is
//! millimetres y-DOWN (KiCad editor convention), while Gerber and Excellon
//! are y-UP, so every emitted point is `(x - ox, oy - y)` — origin at the
//! board outline's bottom-left corner, positive coordinates, and the same
//! frame across copper, drill, and centroid so CAM layers stack exactly.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const export_kicad = @import("export_kicad.zig");

/// The shared fab-output coordinate frame: emitted = `(x - ox, oy - y)`.
/// Build one with `frameFor` and pass the SAME frame to every writer of a
/// package — a mixed-frame package mis-stacks in CAM.
pub const Frame = struct {
    ox: f64 = 0,
    oy: f64 = 0,

    /// Placement-space point → fab-output point (mm, y-up).
    pub fn pt(self: Frame, x: f64, y: f64) [2]f64 {
        return .{ x - self.ox, self.oy - y };
    }
};

/// Margin added around the parts' bounding box when a design declares no
/// board outline — the fallback rectangle `outlineRect` synthesizes.
pub const AUTO_OUTLINE_MARGIN_MM: f64 = 1.0;

/// Whether the centroid CSV keeps Do-Not-Populate parts. `.drop` (the default)
/// omits them — an assembler's pick-and-place machine should only see stuffed
/// parts; `.keep` (the `?dnp=keep` opt-in) lists them (a populated variant).
pub const DnpMode = enum { drop, keep };

/// The board outline every fab writer agrees on: the placement's authored /
/// drawn `board_rect` when present, else the parts' bounding box grown by
/// `AUTO_OUTLINE_MARGIN_MM` (so an outline-less design still exports a
/// closed, plausible board profile).
pub fn outlineRect(placement: optimizer.Placement) optimizer.BoardRect {
    if (placement.board_rect) |r| return r;
    return .{
        .minx = placement.minx - AUTO_OUTLINE_MARGIN_MM,
        .miny = placement.miny - AUTO_OUTLINE_MARGIN_MM,
        .w = (placement.maxx - placement.minx) + 2 * AUTO_OUTLINE_MARGIN_MM,
        .h = (placement.maxy - placement.miny) + 2 * AUTO_OUTLINE_MARGIN_MM,
    };
}

/// The package frame for `placement`: origin at the board outline's
/// bottom-left corner (y-down "bottom" = maxy), so fab outputs are y-up with
/// (0,0) at the board corner.
pub fn frameFor(placement: optimizer.Placement) Frame {
    const r = outlineRect(placement);
    return .{ .ox = r.minx, .oy = r.miny + r.h };
}

/// Write the pick-and-place centroid CSV (JLC-style columns): one row per
/// placed part — ref-des, value, footprint, centre (package-frame mm, y-up),
/// rotation (deg, CCW-positive — the KiCad pos-file convention, so the sense
/// matches what the gerbers show), and which board side it mounts on.
/// `instances` is index-aligned with `parts` (the `Placement` contract); a
/// missing instance leaves value/package empty.
///
/// Do-Not-Populate parts are DROPPED by default (`dnp = .drop`) — an
/// assembler's pick-and-place machine should only see the parts it stuffs. Pass
/// `dnp = .keep` (the `?dnp=keep` opt-in) to list them (a populated variant).
pub fn centroidCsv(
    w: *std.Io.Writer,
    parts: []const optimizer.Part,
    instances: []const export_kicad.FlatInstance,
    frame: Frame,
    dnp: DnpMode,
) std.Io.Writer.Error!void {
    try w.writeAll("Designator,Val,Package,Mid X,Mid Y,Rotation,Layer\n");
    for (parts, 0..) |p, i| {
        if (dnp == .drop and i < instances.len and instances[i].dnp) continue;
        try writeCsvField(w, p.ref_des);
        try w.writeByte(',');
        if (i < instances.len) try writeCsvField(w, instances[i].value);
        try w.writeByte(',');
        if (i < instances.len) try writeCsvField(w, instances[i].footprint);
        const c = frame.pt(p.x, p.y);
        // The placement angle is CW-positive in its y-down world; the pos-file
        // (and Gerber) world is y-up, where the same physical orientation
        // reads CCW-positive — emit the negated angle (KiCad does the same).
        try w.print(",{d:.3}mm,{d:.3}mm,{d:.0},{s}\n", .{
            c[0],
            c[1],
            @mod(360.0 - p.rot, 360.0),
            if (p.side == .bottom) "Bottom" else "Top",
        });
    }
}

/// One hole for the Excellon writer: position (mm) + tool diameter (mm). A
/// `slot` (oval drill) additionally carries its far arc-centre `(x2,y2)`; it
/// is routed with a `G85` canned slot between the two ends by a `d`-diameter
/// tool. Round holes leave `slot=false` and only use `(x,y)`.
const Hole = struct { x: f64, y: f64, d: f64, x2: f64 = 0, y2: f64 = 0, slot: bool = false };

/// Which drill file to emit — fabs take plated and non-plated holes as two
/// separate Excellon files.
pub const DrillClass = enum { plated, non_plated };

/// Write an Excellon (METRIC, decimal, trailing-zero) drill file.
/// `.plated` emits the PTH file: every plated through-hole pad of every
/// placed part plus every routed via. `.non_plated` emits the NPTH file
/// (mounting holes / non-plated pads only). Holes are grouped into one tool
/// per distinct diameter (0.01 mm resolution), smallest first. Coordinates
/// are in the shared package `frame` (y-up) so the holes stack on the
/// gerbers.
pub fn excellonDrill(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    parts: []const optimizer.Part,
    vias: []const router.Via,
    class: DrillClass,
    frame: Frame,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const plated = class == .plated;
    var holes: std.ArrayListUnmanaged(Hole) = .empty;
    for (parts) |p| {
        for (p.pads) |pad| {
            if (pad.drill <= 0) continue;
            const want = if (plated) (pad.thru and !pad.npth) else pad.npth;
            if (!want) continue;
            if (pad.isSlot()) {
                // The two slot-end arc centres, at the pad's world pose.
                const e1 = optimizer.worldPadCenter(p, pad.x + pad.slot_half[0], pad.y + pad.slot_half[1]);
                const e2 = optimizer.worldPadCenter(p, pad.x - pad.slot_half[0], pad.y - pad.slot_half[1]);
                const f1 = frame.pt(e1[0], e1[1]);
                const f2 = frame.pt(e2[0], e2[1]);
                try holes.append(alloc, .{ .x = f1[0], .y = f1[1], .x2 = f2[0], .y2 = f2[1], .d = pad.drill, .slot = true });
            } else {
                const c = optimizer.worldPadCenter(p, pad.x, pad.y);
                const f = frame.pt(c[0], c[1]);
                try holes.append(alloc, .{ .x = f[0], .y = f[1], .d = pad.drill });
            }
        }
    }
    if (plated) {
        for (vias) |v| {
            if (v.drill <= 0) continue;
            const f = frame.pt(v.x, v.y);
            try holes.append(alloc, .{ .x = f[0], .y = f[1], .d = v.drill });
        }
    }

    // Distinct diameters (0.01 mm buckets), ascending — one Excellon tool each.
    var dias: std.ArrayListUnmanaged(f64) = .empty;
    for (holes.items) |h| {
        var known = false;
        for (dias.items) |d| {
            if (@abs(d - h.d) < 0.005) {
                known = true;
                break;
            }
        }
        if (!known) try dias.append(alloc, h.d);
    }
    std.sort.pdq(f64, dias.items, {}, std.sort.asc(f64));

    try w.writeAll("M48\n");
    try w.print(";TYPE={s}\n", .{if (plated) @as([]const u8, "PLATED") else "NON_PLATED"});
    try w.writeAll("METRIC,TZ\n");
    for (dias.items, 1..) |d, ti| try w.print("T{d}C{d:.3}\n", .{ ti, d });
    try w.writeAll("%\n");
    for (dias.items, 1..) |d, ti| {
        try w.print("T{d}\n", .{ti});
        for (holes.items) |h| {
            if (@abs(h.d - d) >= 0.005) continue;
            if (h.slot) {
                // Excellon canned slot: route from one arc centre to the other.
                try w.print("X{d:.3}Y{d:.3}G85X{d:.3}Y{d:.3}\n", .{ h.x, h.y, h.x2, h.y2 });
            } else {
                try w.print("X{d:.3}Y{d:.3}\n", .{ h.x, h.y });
            }
        }
    }
    try w.writeAll("M30\n");
}

/// Escape one CSV field: quoted (with doubled quotes) only when it contains
/// a comma, quote, or newline — plain fields stay unquoted for readability.
fn writeCsvField(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const needs_quote = std.mem.indexOfAny(u8, s, ",\"\n") != null;
    if (!needs_quote) return w.writeAll(s);
    try w.writeByte('"');
    for (s) |ch| {
        if (ch == '"') try w.writeAll("\"\"") else try w.writeByte(ch);
    }
    try w.writeByte('"');
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("placement/geometry.zig");

// spec: export_fab - the centroid CSV lists each part's pose with its board side
test "centroidCsv emits one side-aware row per part" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 10, .y = 5, .rot = 90 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 1, .y = 2, .side = .bottom },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "mcu", .value = "STM32", .footprint = "LQFP-48", .uuid = "", .origin_key = "", .properties = &.{} },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "C_0402", .uuid = "", .origin_key = "", .properties = &.{} },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    // Frame with the board bottom at y=20: y flips (5→15, 2→18) and the
    // CW-positive placement angle comes out CCW-positive (90→270).
    try centroidCsv(&aw.writer, &parts, &instances, .{ .ox = 0, .oy = 20 }, .drop);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "U1,STM32,LQFP-48,10.000mm,15.000mm,270,Top") != null);
    try testing.expect(std.mem.indexOf(u8, out, "C1,100nF,C_0402,1.000mm,18.000mm,0,Bottom") != null);
}

// spec: export_fab - the centroid CSV drops DNP parts by default and keeps them under keep_dnp
test "centroidCsv excludes DNP parts unless keep_dnp is set" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &.{}, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "R_OPT", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 8, .y = 5 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "U1", .component = "mcu", .value = "STM32", .footprint = "LQFP-48", .uuid = "", .origin_key = "", .properties = &.{} },
        .{ .ref_des = "R_OPT", .component = "res", .value = "0R", .footprint = "R_0402", .uuid = "", .origin_key = "", .properties = &.{}, .dnp = true },
    };

    // Default (.drop): the DNP option resistor is dropped, the stuffed IC stays.
    var drop: std.Io.Writer.Allocating = .init(alloc);
    try centroidCsv(&drop.writer, &parts, &instances, .{ .ox = 0, .oy = 10 }, .drop);
    try testing.expect(std.mem.indexOf(u8, drop.written(), "U1,") != null);
    try testing.expect(std.mem.indexOf(u8, drop.written(), "R_OPT,") == null);

    // .keep: both rows present.
    var keep: std.Io.Writer.Allocating = .init(alloc);
    try centroidCsv(&keep.writer, &parts, &instances, .{ .ox = 0, .oy = 10 }, .keep);
    try testing.expect(std.mem.indexOf(u8, keep.written(), "U1,") != null);
    try testing.expect(std.mem.indexOf(u8, keep.written(), "R_OPT,") != null);
}

// spec: export_fab - fab writers share one y-up frame derived from the board outline
test "frameFor puts the origin at the outline's bottom-left corner" {
    var p = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 2,
        .miny = 3,
        .maxx = 12,
        .maxy = 8,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
    };
    const f = frameFor(p);
    try testing.expectApproxEqAbs(@as(f64, 0), f.ox, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), f.oy, 1e-9);
    // A point at the outline's top-left maps to (0, h) — y-up.
    const tl = f.pt(0, 0);
    try testing.expectApproxEqAbs(@as(f64, 0), tl[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), tl[1], 1e-9);

    // No outline: the parts' bbox + margin synthesizes one.
    p.board_rect = null;
    const auto = outlineRect(p);
    try testing.expectApproxEqAbs(@as(f64, 2 - AUTO_OUTLINE_MARGIN_MM), auto.minx, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10 + 2 * AUTO_OUTLINE_MARGIN_MM), auto.w, 1e-9);
}

// spec: export_fab - the Excellon writer splits plated pads + vias from non-plated holes and groups tools by diameter
test "excellonDrill separates PTH and NPTH files" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1.4, .h = 1.4, .thru = true, .drill = 0.92 },
        .{ .number = "MH1", .x = 3, .y = 0, .w = 0.75, .h = 0.75, .thru = true, .npth = true, .drill = 0.75 },
        .{ .number = "2", .x = 1, .y = 0, .w = 0.5, .h = 0.5 }, // SMD — no hole
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 10 },
    };
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};

    // Board bottom at y=20 → the part-origin pad (10,10) emits at (10,10).
    const frame = Frame{ .ox = 0, .oy = 20 };
    var pth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&pth.writer, alloc, &parts, &vias, .plated, frame);
    const pth_out = pth.written();
    try testing.expect(std.mem.indexOf(u8, pth_out, "T1C0.200") != null); // via tool (smallest first)
    try testing.expect(std.mem.indexOf(u8, pth_out, "C0.920") != null); // thru pad tool
    try testing.expect(std.mem.indexOf(u8, pth_out, "X10.000Y10.000") != null); // pad at part origin (y flipped)
    try testing.expect(std.mem.indexOf(u8, pth_out, "X5.000Y15.000") != null); // via, y flipped
    try testing.expect(std.mem.indexOf(u8, pth_out, "C0.750") == null); // NPTH kept out

    var npth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&npth.writer, alloc, &parts, &vias, .non_plated, frame);
    const npth_out = npth.written();
    try testing.expect(std.mem.indexOf(u8, npth_out, "T1C0.750") != null); // the mounting hole
    try testing.expect(std.mem.indexOf(u8, npth_out, "X13.000Y10.000") != null);
    try testing.expect(std.mem.indexOf(u8, npth_out, "C0.200") == null); // vias are plated-only
}

// spec: export_fab - an oval drill exports as a G85 slot at its minor-axis tool between the two arc centres, in both drill files
test "excellonDrill routes oval slots with a G85 record" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    // A plated slot 1.10 long × 0.40 wide, running along +x (slot_half.x =
    // (1.10-0.40)/2 = 0.35), plus an NPTH shield slot 1.10 long × 0.50 wide
    // running along +y. The tool is the MINOR axis; the slot runs between the
    // two arc centres (±slot_half about the pad centre).
    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1.4, .h = 0.6, .thru = true, .drill = 0.40, .slot_half = .{ 0.35, 0 } },
        .{ .number = "SH1", .x = 4, .y = 0, .w = 1.0, .h = 1.6, .thru = true, .npth = true, .drill = 0.50, .slot_half = .{ 0, 0.30 } },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 3, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 10 },
    };
    const frame = Frame{ .ox = 0, .oy = 20 }; // board bottom at y=20

    var pth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&pth.writer, alloc, &parts, &.{}, .plated, frame);
    const pth_out = pth.written();
    try testing.expect(std.mem.indexOf(u8, pth_out, "T1C0.400") != null); // tool = minor axis
    // Slot centred at world (10,10) → (10,10) y-up, ends at x = 10±0.35.
    try testing.expect(std.mem.indexOf(u8, pth_out, "X10.350Y10.000G85X9.650Y10.000") != null);
    try testing.expect(std.mem.indexOf(u8, pth_out, "C0.500") == null); // NPTH kept out

    var npth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&npth.writer, alloc, &parts, &.{}, .non_plated, frame);
    const npth_out = npth.written();
    try testing.expect(std.mem.indexOf(u8, npth_out, "T1C0.500") != null);
    // NPTH slot at world (14,10); its two ends (14,10±0.30) flip through the
    // y-up frame (20-y), so the first end lands at y=9.700, the second at 10.300.
    try testing.expect(std.mem.indexOf(u8, npth_out, "X14.000Y9.700G85X14.000Y10.300") != null);
}
