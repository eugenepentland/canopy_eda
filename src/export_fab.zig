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
const env = @import("eval/env.zig");
const zipfile = @import("zipfile.zig");

/// The manufacturing package under construction: the archive members a fab
/// receives, each named `<prefix>-<suffix>`.
///
/// The naming rule lives HERE, once, because two things must agree about it
/// that are written far apart: the archive's own entry names, and the `Path`
/// fields `export_gerber.writeJobFile` writes into the job file to point at
/// them. A job file naming a member the archive does not contain is a package
/// CAM cannot load — so the prefix is chosen (and sanitized) in one place and
/// every member is named from it.
pub const Package = struct {
    arena: std.mem.Allocator,
    /// The basename every member shares — pass the SAME string to
    /// `writeJobFile`, whose `Path` fields must resolve to these entries.
    prefix: []const u8,
    entries: std.ArrayList(zipfile.Entry) = .empty,

    /// Append one fabrication file under the package's shared naming rule.
    pub fn add(self: *Package, suffix: []const u8, data: []const u8) std.mem.Allocator.Error!void {
        const entry_name = try std.fmt.allocPrint(self.arena, "{s}-{s}", .{ self.prefix, suffix });
        try self.entries.append(self.arena, .{ .name = entry_name, .data = data });
    }

    /// Append a vendor-contract file whose basename must not be decorated by
    /// the package prefix (for example JLCPCB `psb_*` / `pst_*` FPC backing
    /// artwork). The caller validates the basename at DSL parse time.
    pub fn addNamed(self: *Package, name: []const u8, data: []const u8) std.mem.Allocator.Error!void {
        try self.entries.append(self.arena, .{ .name = try self.arena.dupe(u8, name), .data = data });
    }
};

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
pub const auto_outline_margin_mm: f64 = 1.0;

/// Whether the centroid CSV keeps Do-Not-Populate parts. `.drop` (the default)
/// omits them — an assembler's pick-and-place machine should only see stuffed
/// parts; `.keep` (the `?dnp=keep` opt-in) lists them (a populated variant).
pub const DnpMode = enum { drop, keep };

/// Board-copy frames for panel-level assembly outputs. Frames are row-major;
/// `columns` gives each repeated designator its stable RnCn suffix.
pub const AssemblyPanel = struct {
    frames: []const Frame,
    columns: u8,
};

/// True when an evaluated instance belongs in both assembly outputs. Probe
/// pads and board-only mechanical artwork are never sourced or placed; DNP
/// rows are included only for an explicitly selected populated variant.
pub fn assemblyPopulated(instance: export_kicad.FlatInstance, dnp: DnpMode) bool {
    if (dnp == .drop and instance.dnp) return false;
    if (env.isTestPoint(instance.component)) return false;
    const mechanical_names = [_][]const u8{ "mounting-hole", "fiducial", "board-outline" };
    for (mechanical_names) |name| {
        if (std.mem.indexOf(u8, instance.component, name) != null) return false;
    }
    return true;
}

/// The board outline every fab writer agrees on: the placement's authored /
/// drawn `board_rect` when present, else the parts' bounding box grown by
/// `AUTO_OUTLINE_MARGIN_MM` (so an outline-less design still exports a
/// closed, plausible board profile).
pub fn outlineRect(placement: optimizer.Placement) optimizer.BoardRect {
    if (placement.board_rect) |r| return r;
    return .{
        .minx = placement.minx - auto_outline_margin_mm,
        .miny = placement.miny - auto_outline_margin_mm,
        .w = (placement.maxx - placement.minx) + 2 * auto_outline_margin_mm,
        .h = (placement.maxy - placement.miny) + 2 * auto_outline_margin_mm,
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
    try w.writeAll("Designator,Val,Package,Mid X (mm),Mid Y (mm),Rotation,Layer\n");
    try centroidRows(w, parts, instances, frame, dnp, null);
}

/// Write a panel-level centroid: every populated source part repeated in each
/// panel frame, with its designator suffixed `_RnCn` to remain unique and to
/// match the panel BOM's References field.
pub fn panelCentroidCsv(
    w: *std.Io.Writer,
    parts: []const optimizer.Part,
    instances: []const export_kicad.FlatInstance,
    panel: AssemblyPanel,
    dnp: DnpMode,
) std.Io.Writer.Error!void {
    try w.writeAll("Designator,Val,Package,Mid X (mm),Mid Y (mm),Rotation,Layer\n");
    for (panel.frames, 0..) |frame, board_index| {
        try centroidRows(w, parts, instances, frame, dnp, cellFor(board_index, panel.columns));
    }
}

const PanelCell = struct { row: usize, column: usize };

fn cellFor(board_index: usize, requested_columns: u8) PanelCell {
    const columns = @max(@as(usize, requested_columns), 1);
    return .{ .row = board_index / columns + 1, .column = board_index % columns + 1 };
}

fn centroidRows(
    w: *std.Io.Writer,
    parts: []const optimizer.Part,
    instances: []const export_kicad.FlatInstance,
    frame: Frame,
    dnp: DnpMode,
    cell: ?PanelCell,
) std.Io.Writer.Error!void {
    for (parts, 0..) |p, i| {
        if (i >= instances.len or !assemblyPopulated(instances[i], dnp)) continue;
        if (cell) |panel_cell|
            try writePanelReferenceField(w, p.ref_des, panel_cell)
        else
            try writeCsvField(w, p.ref_des);
        try w.writeByte(',');
        if (i < instances.len) try writeCsvField(w, instances[i].value);
        try w.writeByte(',');
        if (i < instances.len) try writeCsvField(w, instances[i].footprint);
        const c = frame.pt(p.x, p.y);
        // The placement angle is CW-positive in its y-down world; the pos-file
        // (and Gerber) world is y-up, where the same physical orientation
        // reads CCW-positive — emit the negated angle (KiCad does the same).
        //
        // The Layer column says "Top"/"Bottom" and NOT the layer table's
        // `F.Cu`/`B.Cu`: those are the words every assembler's pick-and-place
        // importer expects in a centroid file. They mean the same two faces
        // the table calls `Side.front` / `Side.back` (`board_layers.Side`).
        try w.print(",{d:.3},{d:.3},{d:.0},{s}\n", .{
            c[0],
            c[1],
            @mod(360.0 - p.rot, 360.0),
            if (p.side == .bottom) "Bottom" else "Top",
        });
    }
}

/// Write the revision-release BOM from the exact flattened instance array used
/// by the centroid. Sourceable parts sharing a normalized MPN occupy one row;
/// parts without an MPN use component/value/footprint as a conservative
/// fallback so unrelated unspecified parts do not collapse together.
pub fn assemblyBomCsv(
    w: *std.Io.Writer,
    instances: []const export_kicad.FlatInstance,
    dnp: DnpMode,
) std.Io.Writer.Error!void {
    return assemblyBomRows(w, instances, dnp, null);
}

/// Write the BOM for a fully assembled panel. Quantities are multiplied by
/// the board count and References use the same `_RnCn` identifiers as the
/// panel centroid.
pub fn panelAssemblyBomCsv(
    w: *std.Io.Writer,
    instances: []const export_kicad.FlatInstance,
    panel: AssemblyPanel,
    dnp: DnpMode,
) std.Io.Writer.Error!void {
    return assemblyBomRows(w, instances, dnp, panel);
}

fn assemblyBomRows(
    w: *std.Io.Writer,
    instances: []const export_kicad.FlatInstance,
    dnp: DnpMode,
    panel: ?AssemblyPanel,
) std.Io.Writer.Error!void {
    try w.writeAll("Qty,References,Component,Value,Footprint,MPN,Manufacturer,DNP\r\n");
    for (instances, 0..) |instance, instance_index| {
        if (!assemblyPopulated(instance, dnp)) continue;

        // The first populated instance for a group owns its row. Keeping that
        // order makes the output deterministic without allocating a second
        // copy of the BOM solely to sort or group it.
        var already_written = false;
        for (instances[0..instance_index]) |prior| {
            if (assemblyPopulated(prior, dnp) and sameBomGroup(prior, instance)) {
                already_written = true;
                break;
            }
        }
        if (already_written) continue;

        var quantity: usize = 0;
        var dnp_quantity: usize = 0;
        var manufacturer = bomProperty(instance, "manufacturer");
        for (instances) |candidate| {
            if (!assemblyPopulated(candidate, dnp) or !sameBomGroup(instance, candidate)) continue;
            quantity += 1;
            dnp_quantity += @intFromBool(candidate.dnp);
            if (manufacturer.len == 0) manufacturer = bomProperty(candidate, "manufacturer");
        }

        const board_count = if (panel) |array| array.frames.len else 1;
        try w.print("{d},\"", .{quantity * board_count});
        try writeBomReferences(w, instances, instance, dnp, panel);
        try w.writeAll("\",");
        try writeCsvField(w, instance.component);
        try w.writeByte(',');
        try writeCsvField(w, instance.value);
        try w.writeByte(',');
        try writeCsvField(w, instance.footprint);
        try w.writeByte(',');
        try writeCsvField(w, bomProperty(instance, "mpn"));
        try w.writeByte(',');
        try writeCsvField(w, manufacturer);
        const panel_dnp_quantity = dnp_quantity * board_count;
        const panel_quantity = quantity * board_count;
        const dnp_label = if (panel_dnp_quantity == 0)
            "no"
        else if (panel_dnp_quantity == panel_quantity)
            "yes"
        else
            "mixed";
        try w.print(",{s}\r\n", .{dnp_label});
    }
}

fn writeBomReferences(
    w: *std.Io.Writer,
    instances: []const export_kicad.FlatInstance,
    group: export_kicad.FlatInstance,
    dnp: DnpMode,
    panel: ?AssemblyPanel,
) std.Io.Writer.Error!void {
    const board_count = if (panel) |array| array.frames.len else 1;
    var first_ref = true;
    for (0..board_count) |board_index| {
        for (instances) |candidate| {
            if (!assemblyPopulated(candidate, dnp) or !sameBomGroup(group, candidate)) continue;
            if (!first_ref) try w.writeAll(", ");
            if (panel) |array|
                try writePanelReferenceRaw(w, candidate.ref_des, cellFor(board_index, array.columns))
            else
                try writeCsvEscaped(w, candidate.ref_des);
            first_ref = false;
        }
    }
}

fn writePanelReferenceField(w: *std.Io.Writer, ref_des: []const u8, cell: PanelCell) std.Io.Writer.Error!void {
    try w.writeByte('"');
    try writePanelReferenceRaw(w, ref_des, cell);
    try w.writeByte('"');
}

fn writePanelReferenceRaw(w: *std.Io.Writer, ref_des: []const u8, cell: PanelCell) std.Io.Writer.Error!void {
    try writeCsvEscaped(w, ref_des);
    try w.print("_R{d}C{d}", .{ cell.row, cell.column });
}

fn writeCsvEscaped(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    for (value) |ch| {
        if (ch == '"') try w.writeAll("\"\"") else try w.writeByte(ch);
    }
}

fn bomProperty(instance: export_kicad.FlatInstance, wanted: []const u8) []const u8 {
    for (instance.properties) |property| {
        if (std.ascii.eqlIgnoreCase(property.key, wanted)) {
            return std.mem.trim(u8, property.value, " \t\r\n");
        }
    }
    return "";
}

fn sameBomText(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(
        std.mem.trim(u8, a, " \t\r\n"),
        std.mem.trim(u8, b, " \t\r\n"),
    );
}

fn sameBomGroup(a: export_kicad.FlatInstance, b: export_kicad.FlatInstance) bool {
    const a_mpn = bomProperty(a, "mpn");
    const b_mpn = bomProperty(b, "mpn");
    if (a_mpn.len > 0 or b_mpn.len > 0) {
        return a_mpn.len > 0 and b_mpn.len > 0 and std.ascii.eqlIgnoreCase(a_mpn, b_mpn);
    }
    return sameBomText(a.component, b.component) and
        sameBomText(a.value, b.value) and
        sameBomText(a.footprint, b.footprint);
}

/// One hole for the Excellon writer: position (mm) + tool diameter (mm). A
/// `slot` (oval drill) additionally carries its far arc-centre `(x2,y2)`; it
/// is routed with a `G85` canned slot between the two ends by a `d`-diameter
/// tool. Round holes leave `slot=false` and only use `(x,y)`.
const Hole = struct { x: f64, y: f64, d: f64, x2: f64 = 0, y2: f64 = 0, slot: bool = false };

/// Which drill file to emit — fabs take plated and non-plated holes as two
/// separate Excellon files.
pub const DrillClass = enum { plated, non_plated };

/// One drill file's identity: which holes it carries, and the board they are
/// drilled through. Both are what the file's X2 `TF.FileFunction` states, so
/// they travel together rather than as two loose arguments.
pub const DrillFile = struct {
    class: DrillClass,
    /// The board's physical copper count, from the shared layer table — the
    /// span the header declares these holes reach through.
    copper_layers: u8,
};

/// An additional already-framed NPTH hit, used for panel mouse-bites.
pub const DrillHole = struct { x: f64, y: f64, diameter: f64 };

/// Repetition frames and panel-only holes for an Excellon panel export.
pub const DrillRepeat = struct {
    frames: []const Frame,
    extra_npth: []const DrillHole = &.{},
};

/// Half-width of an Excellon tool bucket: two diameters closer than this
/// share one tool (0.01 mm resolution).
const tool_bucket_mm: f64 = 0.005;

/// Index of the tool `d` belongs to — the NEAREST diameter inside the bucket
/// — or null when `d` needs a tool of its own. Both the tool-table build and
/// the hole emission go through this one answer, so a hole can never be
/// claimed by two tools (drilled twice) or by none.
///
/// Strict `<` on the running best means an exact tie goes to the lower index,
/// i.e. the smaller diameter once `dias` is sorted: deterministic, and
/// never dependent on the order holes were collected in.
fn toolFor(dias: []const f64, d: f64) ?usize {
    var best: ?usize = null;
    var best_err: f64 = tool_bucket_mm;
    for (dias, 0..) |t, i| {
        const err = @abs(t - d);
        if (err < best_err) {
            best = i;
            best_err = err;
        }
    }
    return best;
}

/// Write an Excellon (METRIC, decimal, trailing-zero) drill file.
/// `.plated` emits the PTH file: every plated through-hole pad of every
/// placed part plus every routed via. `.non_plated` emits the NPTH file
/// (mounting holes / non-plated pads only). Holes are grouped into one tool
/// per distinct diameter (0.01 mm resolution), smallest first. Coordinates
/// are in the shared package `frame` (y-up) so the holes stack on the
/// gerbers. `file` says which holes this is and how many copper layers they
/// drill through (see `DrillFile`).
pub fn excellonDrill(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    parts: []const optimizer.Part,
    vias: []const router.Via,
    file: DrillFile,
    frame: Frame,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    return excellonDrillRepeated(w, alloc, parts, vias, file, .{ .frames = &.{frame} });
}

/// Panel form of `excellonDrill`: repeat every board hit through each frame
/// and append panel-only NPTH hits (mouse-bites) in panel coordinates.
pub fn excellonDrillRepeated(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    parts: []const optimizer.Part,
    vias: []const router.Via,
    file: DrillFile,
    repeat: DrillRepeat,
) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    const plated = file.class == .plated;
    var holes: std.ArrayList(Hole) = .empty;
    for (repeat.frames) |frame| {
        for (parts) |p| {
            for (p.pads) |pad| {
                if (pad.drill <= 0) continue;
                const want = if (plated) (pad.thru and !pad.npth) else pad.npth;
                if (!want) continue;
                if (pad.isSlot()) {
                    // The two slot-end arc centres, at the pad's world pose.
                    const e1 = optimizer.worldPadCenter(&p, pad.x + pad.slot_half[0], pad.y + pad.slot_half[1]);
                    const e2 = optimizer.worldPadCenter(&p, pad.x - pad.slot_half[0], pad.y - pad.slot_half[1]);
                    const f1 = frame.pt(e1[0], e1[1]);
                    const f2 = frame.pt(e2[0], e2[1]);
                    try holes.append(alloc, .{ .x = f1[0], .y = f1[1], .x2 = f2[0], .y2 = f2[1], .d = pad.drill, .slot = true });
                } else {
                    const c = optimizer.worldPadCenter(&p, pad.x, pad.y);
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
    }
    if (!plated) for (repeat.extra_npth) |h|
        try holes.append(alloc, .{ .x = h.x, .y = h.y, .d = h.diameter });

    // Distinct diameters (0.01 mm buckets), ascending — one Excellon tool each.
    var dias: std.ArrayList(f64) = .empty;
    for (holes.items) |h| {
        if (toolFor(dias.items, h.d) == null) try dias.append(alloc, h.d);
    }
    std.sort.pdq(f64, dias.items, {}, std.sort.asc(f64));

    // Bind every hole to EXACTLY ONE tool up front. The bucket test is a
    // radius, not a partition: with diameters 0.400, 0.405, 0.402 the first
    // two are ≥0.005 apart so both become tools, and 0.402 is within 0.005 of
    // BOTH. Re-running the test once per tool at emit time therefore drilled
    // that hole twice at the same XY — a broken bit or, at best, a
    // duplicate-hit warning from the fab's CAM. `toolFor` picks the nearest
    // tool (ties to the smaller diameter), so the mapping is a function of
    // the diameter alone and independent of hole order.
    const owners = try alloc.alloc(usize, holes.items.len);
    for (holes.items, owners) |h, *o| o.* = toolFor(dias.items, h.d) orelse 0;

    try w.writeAll("M48\n");
    // The X2 file function, in the `; #@!` comment form Excellon carries it
    // (the format has no attribute syntax of its own, so the standard smuggles
    // it through a comment every CAM package recognises). It names the plating
    // AND the layer span the holes drill through, which is what tells a fab
    // these are through-holes of an n-layer board rather than blind/buried
    // ones. Without it a package's two `.drl` files are distinguished only by
    // their file names.
    try w.print("; #@! TF.FileFunction,{s},1,{d},{s}\n", .{
        if (plated) @as([]const u8, "Plated") else "NonPlated",
        @max(file.copper_layers, 1),
        if (plated) @as([]const u8, "PTH") else "NPTH",
    });
    try w.print(";TYPE={s}\n", .{if (plated) @as([]const u8, "PLATED") else "NON_PLATED"});
    try w.writeAll("METRIC,TZ\n");
    for (dias.items, 1..) |d, ti| try w.print("T{d}C{d:.3}\n", .{ ti, d });
    try w.writeAll("%\n");
    for (dias.items, 0..) |_, ti| {
        try w.print("T{d}\n", .{ti + 1});
        for (holes.items, owners) |h, owner| {
            if (owner != ti) continue;
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

// spec: export_fab - the centroid CSV labels coordinate units in its headers and lists each part's unitless-numeric pose with its board side
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
    try testing.expect(std.mem.startsWith(u8, out, "Designator,Val,Package,Mid X (mm),Mid Y (mm),Rotation,Layer\n"));
    try testing.expect(std.mem.indexOf(u8, out, "U1,STM32,LQFP-48,10.000,15.000,270,Top") != null);
    try testing.expect(std.mem.indexOf(u8, out, "C1,100nF,C_0402,1.000,18.000,0,Bottom") != null);
    try testing.expect(std.mem.indexOf(u8, out, "mm,") == null);
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

// spec: export_fab - the fabrication BOM groups normalized MPNs into quantity rows and uses component identity only when MPN is absent
test "assemblyBomCsv groups rows by normalized MPN" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const r1_properties = [_]env.Property{
        .{ .key = "mpn", .value = "RC0402-10K" },
    };
    const r2_properties = [_]env.Property{
        .{ .key = "MPN", .value = "  rc0402-10k  " },
        .{ .key = "Manufacturer", .value = "Yageo" },
    };
    const dnp_properties = [_]env.Property{
        .{ .key = "mpn", .value = "RC0402-10K" },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "R1", .component = "res", .value = "10k", .footprint = "0402", .uuid = "", .properties = &r1_properties },
        .{ .ref_des = "R2", .component = "res", .value = "12k", .footprint = "0402", .uuid = "", .properties = &r2_properties },
        .{ .ref_des = "C1", .component = "cap", .value = "100n", .footprint = "0402", .uuid = "", .properties = &.{} },
        .{ .ref_des = "C2", .component = "CAP", .value = "100N", .footprint = "0402", .uuid = "", .properties = &.{} },
        .{ .ref_des = "C3", .component = "cap", .value = "1u", .footprint = "0402", .uuid = "", .properties = &.{} },
        .{ .ref_des = "R_OPT", .component = "res", .value = "10k", .footprint = "0402", .uuid = "", .properties = &dnp_properties, .dnp = true },
    };

    var drop: std.Io.Writer.Allocating = .init(alloc);
    try assemblyBomCsv(&drop.writer, &instances, .drop);
    try testing.expectEqualStrings(
        "Qty,References,Component,Value,Footprint,MPN,Manufacturer,DNP\r\n" ++
            "2,\"R1, R2\",res,10k,0402,RC0402-10K,Yageo,no\r\n" ++
            "2,\"C1, C2\",cap,100n,0402,,,no\r\n" ++
            "1,\"C3\",cap,1u,0402,,,no\r\n",
        drop.written(),
    );

    // Keeping DNP parts still produces one MPN row and makes the mixed
    // population status explicit instead of silently inheriting R1's value.
    var keep: std.Io.Writer.Allocating = .init(alloc);
    try assemblyBomCsv(&keep.writer, &instances, .keep);
    try testing.expect(std.mem.indexOf(
        u8,
        keep.written(),
        "3,\"R1, R2, R_OPT\",res,10k,0402,RC0402-10K,Yageo,mixed\r\n",
    ) != null);
}

// spec: export_fab - panel assembly outputs repeat centroid coordinates in every board frame, multiply BOM quantities, and suffix matching references with their row and column
test "panel assembly BOM and centroid repeat matching row-column references" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 1, .y = 2 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .x = 3, .y = 4 },
    };
    const instances = [_]export_kicad.FlatInstance{
        .{ .ref_des = "R1", .component = "res", .value = "10k", .footprint = "0402", .uuid = "", .properties = &.{} },
        .{ .ref_des = "R2", .component = "res", .value = "10k", .footprint = "0402", .uuid = "", .properties = &.{} },
    };
    const frames = [_]Frame{
        .{ .ox = 0, .oy = 10 },
        .{ .ox = -22, .oy = 10 },
        .{ .ox = 0, .oy = 22 },
        .{ .ox = -22, .oy = 22 },
    };
    const panel = AssemblyPanel{ .frames = &frames, .columns = 2 };

    var centroid: std.Io.Writer.Allocating = .init(alloc);
    try panelCentroidCsv(&centroid.writer, &parts, &instances, panel, .drop);
    try testing.expectEqual(@as(usize, 9), std.mem.count(u8, centroid.written(), "\n"));
    try testing.expect(std.mem.indexOf(u8, centroid.written(), "\"R1_R1C1\",10k,0402,1.000,8.000,0,Top") != null);
    try testing.expect(std.mem.indexOf(u8, centroid.written(), "\"R2_R2C2\",10k,0402,25.000,18.000,0,Top") != null);

    var bom: std.Io.Writer.Allocating = .init(alloc);
    try panelAssemblyBomCsv(&bom.writer, &instances, panel, .drop);
    try testing.expectEqualStrings(
        "Qty,References,Component,Value,Footprint,MPN,Manufacturer,DNP\r\n" ++
            "8,\"R1_R1C1, R2_R1C1, R1_R1C2, R2_R1C2, R1_R2C1, R2_R2C1, R1_R2C2, R2_R2C2\",res,10k,0402,,,no\r\n",
        bom.written(),
    );
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
    try testing.expectApproxEqAbs(@as(f64, 2 - auto_outline_margin_mm), auto.minx, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10 + 2 * auto_outline_margin_mm), auto.w, 1e-9);
}

// spec: export_fab - panel Excellon repeats board drills in every panel frame and adds routed-tab mouse-bites only to NPTH
test "panel Excellon repeats board holes and adds NPTH mouse-bites" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true, .drill = 0.6 }};
    const parts = [_]optimizer.Part{.{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 2, .y = 3 }};
    const frames = [_]Frame{ .{ .ox = 0, .oy = 10 }, .{ .ox = -20, .oy = 10 } };

    var plated: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrillRepeated(&plated.writer, alloc, &parts, &.{}, .{ .class = .plated, .copper_layers = 2 }, .{ .frames = &frames });
    try testing.expect(std.mem.indexOf(u8, plated.written(), "X2.000Y7.000") != null);
    try testing.expect(std.mem.indexOf(u8, plated.written(), "X22.000Y7.000") != null);

    var non_plated: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrillRepeated(&non_plated.writer, alloc, &parts, &.{}, .{ .class = .non_plated, .copper_layers = 2 }, .{
        .frames = &frames,
        .extra_npth = &.{.{ .x = 5, .y = 6, .diameter = 0.5 }},
    });
    try testing.expect(std.mem.indexOf(u8, non_plated.written(), "T1C0.500") != null);
    try testing.expect(std.mem.indexOf(u8, non_plated.written(), "X5.000Y6.000") != null);
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
    try excellonDrill(&pth.writer, alloc, &parts, &vias, .{ .class = .plated, .copper_layers = 4 }, frame);
    const pth_out = pth.written();
    try testing.expect(std.mem.indexOf(u8, pth_out, "T1C0.200") != null); // via tool (smallest first)
    try testing.expect(std.mem.indexOf(u8, pth_out, "C0.920") != null); // thru pad tool
    try testing.expect(std.mem.indexOf(u8, pth_out, "X10.000Y10.000") != null); // pad at part origin (y flipped)
    try testing.expect(std.mem.indexOf(u8, pth_out, "X5.000Y15.000") != null); // via, y flipped
    try testing.expect(std.mem.indexOf(u8, pth_out, "C0.750") == null); // NPTH kept out

    var npth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&npth.writer, alloc, &parts, &vias, .{ .class = .non_plated, .copper_layers = 4 }, frame);
    const npth_out = npth.written();
    try testing.expect(std.mem.indexOf(u8, npth_out, "T1C0.750") != null); // the mounting hole
    try testing.expect(std.mem.indexOf(u8, npth_out, "X13.000Y10.000") != null);
    try testing.expect(std.mem.indexOf(u8, npth_out, "C0.200") == null); // vias are plated-only
}

// spec: export_fab - each Excellon file declares its X2 file function, naming its plating and the copper span it drills through
test "excellonDrill declares its file function and layer span" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1.4, .h = 1.4, .thru = true, .drill = 0.92 },
        .{ .number = "MH1", .x = 3, .y = 0, .w = 0.75, .h = 0.75, .thru = true, .npth = true, .drill = 0.75 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 10, .y = 10 },
    };
    const frame = Frame{ .ox = 0, .oy = 20 };

    // The attribute rides in Excellon's `; #@!` comment form (the format has
    // no attribute syntax), immediately after M48 and before the tool table.
    var pth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&pth.writer, alloc, &parts, &.{}, .{ .class = .plated, .copper_layers = 6 }, frame);
    try testing.expect(std.mem.startsWith(u8, pth.written(), "M48\n; #@! TF.FileFunction,Plated,1,6,PTH\n;TYPE=PLATED\n"));

    var npth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&npth.writer, alloc, &parts, &.{}, .{ .class = .non_plated, .copper_layers = 6 }, frame);
    try testing.expect(std.mem.startsWith(u8, npth.written(), "M48\n; #@! TF.FileFunction,NonPlated,1,6,NPTH\n;TYPE=NON_PLATED\n"));

    // The span follows the board: a plain two-layer stackup drills 1..2.
    var two: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&two.writer, alloc, &parts, &.{}, .{ .class = .plated, .copper_layers = 2 }, frame);
    try testing.expect(std.mem.indexOf(u8, two.written(), "TF.FileFunction,Plated,1,2,PTH") != null);
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
    try excellonDrill(&pth.writer, alloc, &parts, &.{}, .{ .class = .plated, .copper_layers = 4 }, frame);
    const pth_out = pth.written();
    try testing.expect(std.mem.indexOf(u8, pth_out, "T1C0.400") != null); // tool = minor axis
    // Slot centred at world (10,10) → (10,10) y-up, ends at x = 10±0.35.
    try testing.expect(std.mem.indexOf(u8, pth_out, "X10.350Y10.000G85X9.650Y10.000") != null);
    try testing.expect(std.mem.indexOf(u8, pth_out, "C0.500") == null); // NPTH kept out

    var npth: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&npth.writer, alloc, &parts, &.{}, .{ .class = .non_plated, .copper_layers = 4 }, frame);
    const npth_out = npth.written();
    try testing.expect(std.mem.indexOf(u8, npth_out, "T1C0.500") != null);
    // NPTH slot at world (14,10); its two ends (14,10±0.30) flip through the
    // y-up frame (20-y), so the first end lands at y=9.700, the second at 10.300.
    try testing.expect(std.mem.indexOf(u8, npth_out, "X14.000Y9.700G85X14.000Y10.300") != null);
}

// spec: export_fab - ordinary manufacturing-package members are named from the package's one shared prefix; vendor-contract auxiliary files may retain an exact safe basename, and the job file's Path fields resolve both forms exactly
test "a fab package prefixes ordinary members and preserves vendor names" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();

    var pkg = Package{ .arena = arena_i.allocator(), .prefix = "board" };
    try pkg.add("F_Cu.gtl", "copper");
    try pkg.add("PTH.drl", "holes");
    try pkg.addNamed("psb_tesa8854.gbr", "backing");

    try testing.expectEqual(@as(usize, 3), pkg.entries.items.len);
    try testing.expectEqualStrings("board-F_Cu.gtl", pkg.entries.items[0].name);
    try testing.expectEqualStrings("copper", pkg.entries.items[0].data);
    // The suffix is appended verbatim, so a member's name is exactly what the
    // job file's `Path` field spells for it — never a second transformation.
    try testing.expectEqualStrings("board-PTH.drl", pkg.entries.items[1].name);
    try testing.expectEqualStrings("psb_tesa8854.gbr", pkg.entries.items[2].name);
}

// spec: export_fab - every hole is drilled by exactly one Excellon tool, even when its diameter sits inside two tool buckets
test "excellonDrill drills each clustered-diameter hole exactly once" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    // 0.400 and 0.405 are 0.005 apart — just far enough that each claims its
    // own tool — and 0.402 falls inside BOTH buckets. Re-testing the bucket
    // once per tool at emit time drilled it twice at the same XY.
    const vias = [_]router.Via{
        .{ .x = 0, .y = 1, .dia = 0.6, .drill = 0.400, .net = 0 },
        .{ .x = 1, .y = 2, .dia = 0.6, .drill = 0.405, .net = 0 },
        .{ .x = 2, .y = 3, .dia = 0.6, .drill = 0.402, .net = 0 },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try excellonDrill(&aw.writer, alloc, &.{}, &vias, .{ .class = .plated, .copper_layers = 2 }, .{ .ox = 0, .oy = 10 });
    const out = aw.written();

    // Two tools, ascending …
    try testing.expect(std.mem.indexOf(u8, out, "T1C0.400") != null);
    try testing.expect(std.mem.indexOf(u8, out, "T2C0.405") != null);
    // … and exactly one drill record per hole — the ambiguous one included.
    try testing.expectEqual(@as(usize, vias.len), std.mem.count(u8, out, "\nX"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "X2.000Y7.000"));
}

// spec: export_fab - the Excellon tool lookup partitions diameters, giving each hole exactly one owning tool
test "toolFor partitions overlapping diameter buckets" {
    const dias = [_]f64{ 0.400, 0.405 };
    // The ambiguous diameter belongs to the NEARER tool, not to both.
    try testing.expectEqual(@as(?usize, 0), toolFor(&dias, 0.402));
    try testing.expectEqual(@as(?usize, 1), toolFor(&dias, 0.404));
    try testing.expectEqual(@as(?usize, 0), toolFor(&dias, 0.400));
    try testing.expectEqual(@as(?usize, 1), toolFor(&dias, 0.405));
    // Outside every bucket → the caller mints a new tool.
    try testing.expectEqual(@as(?usize, null), toolFor(&dias, 0.500));
    try testing.expectEqual(@as(?usize, null), toolFor(&.{}, 0.400));
}
