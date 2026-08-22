//! Vendor symbol bodies for the `.kicad_sch` exporter.
//!
//! A part imported from a vendor library still has its original `.kicad_sym`
//! in the project's `lib/sources/`, so most ICs and connectors can be drawn as
//! the engineer knows them instead of as a synthesised box. This module is the
//! one seam between the two: `synth` answers the same question
//! `shape.synth` does — "what does this component look like?" — preferring a
//! vendor body and falling back to the box whenever it cannot.
//!
//! What it changes about a symbol, and what it deliberately does not:
//!
//!   * **Pins keep their pad numbers.** Connectivity is by pad, so a vendor pin
//!     is only useful if its `(number …)` matches the netlist. A pad the vendor
//!     symbol does not draw is collected into a trailing synthesised unit, so
//!     the exporter's every-pin-drawn invariant still holds.
//!   * **Pin endpoints are snapped to the 1.27 mm grid.** Vendor libraries are
//!     almost always on it; the handful that sit on the half grid would
//!     otherwise raise one `endpoint_off_grid` ERC warning per pin. Snapping
//!     never merges two pins: if it would, the whole symbol is rejected.
//!   * **Body graphics are kept exactly**, off-grid and all — they are drawing,
//!     never connection points, so the self-check's grid scan skips them.
//!   * **Every pin is emitted `passive`**, whatever the vendor typed it, and a
//!     hidden vendor pin is drawn visibly. Both are ERC decisions: a typed
//!     `input` raises `pin_not_driven` on a label-connected sheet, and a hidden
//!     pin with no visible stub is a connection a reader cannot see.
//!   * **A vendor symbol's units win over netlisp's `(part …)` groups.** The
//!     drawn body belongs to the vendor's own unit breakdown, and splitting it
//!     across a different one would put a body on a unit whose pins moved.

const std = @import("std");
const log = @import("../infra/log.zig");
const library = @import("../kicad_sym/library.zig");
const kicad_sym = @import("../kicad_sym/reader.zig");
const shape = @import("shape.zig");
const sheet = @import("sheet.zig");

/// Reader units (ten-thousandths of a millimetre) per exporter unit
/// (hundredths of a millimetre).
const per_hundredth: i32 = @divExact(kicad_sym.per_mm, 100);
/// KiCad's 1.27 mm connection grid, in reader units.
const grid_u: i32 = shape.grid * per_hundredth;
/// KiCad's "this pin has no name" spelling.
const no_name = "~";

/// The symbol for one component: its vendor body when the project has one and
/// it can be drawn safely, otherwise the synthesised box. `lib` is null when
/// vendor passthrough is switched off.
pub fn synth(
    arena: std.mem.Allocator,
    lib: ?*const library.Library,
    req: shape.Request,
) std.mem.Allocator.Error!shape.Shape {
    if (lib) |l| {
        if (resolve(l, req.names)) |sym| {
            if (try build(arena, sym, req)) |s| return s;
        }
    }
    return shape.synth(arena, req);
}

/// Component name first, then the declared symbol name, then the pinout key —
/// the same order the component itself resolves its library data in.
fn resolve(lib: *const library.Library, names: shape.Names) ?kicad_sym.Symbol {
    return lib.find(names.component) orelse
        lib.find(names.symbol) orelse
        lib.find(names.pinout);
}

/// Build a shape from a vendor symbol, or null when the symbol cannot be drawn
/// safely and the caller should synthesise a box instead.
fn build(
    arena: std.mem.Allocator,
    sym: kicad_sym.Symbol,
    req: shape.Request,
) std.mem.Allocator.Error!?shape.Shape {
    const merged = try mergeUnits(arena, sym);
    if (merged.len == 0 or countPins(merged) == 0) return null;
    if (try repeatedPad(arena, merged)) |pad| {
        // Phase 0 proved a pad number drawn twice silently splits that pad's
        // net in KiCad's exported netlist. A box is wrong-looking; this is
        // wrong.
        log.warn(
            "export-kicad-sch: vendor symbol '{s}' draws pad {s} twice — synthesising a box instead",
            .{ sym.name, pad },
        );
        return null;
    }

    var ctx = Ctx{ .arena = arena };
    try ctx.indexNames(req);
    var units: std.ArrayList(shape.Unit) = .empty;
    for (merged, 0..) |u, i| {
        const adapted = try adaptUnit(&ctx, u, @intCast(i + 1)) orelse {
            log.warn(
                "export-kicad-sch: vendor symbol '{s}' has pins that collide on the connection grid — synthesising a box instead",
                .{sym.name},
            );
            return null;
        };
        try units.append(arena, adapted);
    }
    try appendMissing(arena, &units, req, merged, sym.name);

    return .{
        .lib_name = try shape.libNameFor(arena, req),
        .units = units.items,
        .vendor = true,
    };
}

/// Pads the netlist needs that the vendor symbol never draws — a thermal pad
/// the vendor left off, or a pinout richer than the drawn symbol. They go into
/// one trailing synthesised unit rather than failing the export.
fn appendMissing(
    arena: std.mem.Allocator,
    units: *std.ArrayList(shape.Unit),
    req: shape.Request,
    drawn: []const kicad_sym.Unit,
    name: []const u8,
) std.mem.Allocator.Error!void {
    const extra = try missingPads(arena, req, drawn);
    if (extra.len == 0) return;
    log.warn(
        "export-kicad-sch: vendor symbol '{s}' does not draw {d} pad(s) the design uses — adding them as unit {d}",
        .{ name, extra.len, units.items.len + 1 },
    );
    try units.append(arena, try shape.boxUnit(arena, extra, @intCast(units.items.len + 1)));
}

/// Fold KiCad's unit 0 — "common to every unit" — into the real units, so each
/// returned unit is self-contained. Shared *graphics* go on every unit (that is
/// what unit 0 is for); shared *pins* go on the first only, because a pad drawn
/// on two units is exactly the duplicate that corrupts a netlist.
fn mergeUnits(
    arena: std.mem.Allocator,
    sym: kicad_sym.Symbol,
) std.mem.Allocator.Error![]const kicad_sym.Unit {
    var common: ?kicad_sym.Unit = null;
    var real: std.ArrayList(kicad_sym.Unit) = .empty;
    for (sym.units) |u| {
        if (u.number == 0) common = u else try real.append(arena, u);
    }
    const shared = common orelse return real.items;
    if (real.items.len == 0) return arena.dupe(kicad_sym.Unit, &.{shared});

    const out = try arena.alloc(kicad_sym.Unit, real.items.len);
    for (real.items, 0..) |u, i| {
        out[i] = .{
            .number = u.number,
            .pins = if (i == 0) try std.mem.concat(arena, kicad_sym.Pin, &.{ shared.pins, u.pins }) else u.pins,
            .graphics = try std.mem.concat(arena, kicad_sym.Graphic, &.{ shared.graphics, u.graphics }),
        };
    }
    return out;
}

fn countPins(units: []const kicad_sym.Unit) usize {
    var n: usize = 0;
    for (units) |u| n += u.pins.len;
    return n;
}

/// The first pad number two pins share, or null when every pad is unique.
fn repeatedPad(
    arena: std.mem.Allocator,
    units: []const kicad_sym.Unit,
) std.mem.Allocator.Error!?[]const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);
    for (units) |u| {
        for (u.pins) |p| {
            if ((try seen.fetchPut(arena, p.pad, {})) != null) return p.pad;
        }
    }
    return null;
}

fn missingPads(
    arena: std.mem.Allocator,
    req: shape.Request,
    units: []const kicad_sym.Unit,
) std.mem.Allocator.Error![]const shape.PadName {
    var drawn: std.StringHashMapUnmanaged(void) = .empty;
    defer drawn.deinit(arena);
    for (units) |u| {
        for (u.pins) |p| try drawn.put(arena, p.pad, {});
    }
    var out: std.ArrayList(shape.PadName) = .empty;
    for (try shape.requiredPads(arena, req)) |pn| {
        if (drawn.contains(pn.pad)) continue;
        try out.append(arena, pn);
    }
    return out.items;
}

/// Per-component state one unit adaptation needs beyond the unit itself.
const Ctx = struct {
    arena: std.mem.Allocator,
    /// pad -> pinout function name: the display name for a vendor pin the
    /// vendor left unnamed.
    fallback: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn indexNames(self: *Ctx, req: shape.Request) std.mem.Allocator.Error!void {
        for (try shape.requiredPads(self.arena, req)) |pn| {
            try self.fallback.put(self.arena, pn.pad, pn.name);
        }
    }

    fn nameOf(self: *const Ctx, pin: kicad_sym.Pin) []const u8 {
        if (pin.name.len > 0 and !std.mem.eql(u8, pin.name, no_name)) return pin.name;
        return self.fallback.get(pin.pad) orelse pin.pad;
    }
};

/// An axis-aligned extent in reader units.
const Box = struct {
    min: kicad_sym.Point,
    max: kicad_sym.Point,

    fn add(self: *Box, p: kicad_sym.Point, pad: i32) void {
        self.min = .{ .x = @min(self.min.x, p.x - pad), .y = @min(self.min.y, p.y - pad) };
        self.max = .{ .x = @max(self.max.x, p.x + pad), .y = @max(self.max.y, p.y + pad) };
    }
};

/// One vendor unit as a drawable shape unit: pins snapped onto the connection
/// grid, everything re-centred on the symbol origin, and a body to draw. Null
/// when two pins land on the same grid point, which would silently merge their
/// nets in KiCad.
fn adaptUnit(ctx: *Ctx, u: kicad_sym.Unit, number: u32) std.mem.Allocator.Error!?shape.Unit {
    const pins = try snapPins(ctx.arena, u.pins);
    const box = extents(pins, u.graphics) orelse return null;
    const shift = kicad_sym.Point{
        .x = -snapNearest(@divFloor(box.min.x + box.max.x, 2)),
        .y = -snapNearest(@divFloor(box.min.y + box.max.y, 2)),
    };
    const out = try ctx.arena.alloc(shape.Pin, pins.len);
    var seen: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer seen.deinit(ctx.arena);
    for (pins, 0..) |p, i| {
        const at = kicad_sym.Point{ .x = p.at.x + shift.x, .y = p.at.y + shift.y };
        if ((try seen.fetchPut(ctx.arena, pointKey(at), {})) != null) return null;
        const name = ctx.nameOf(p);
        out[i] = .{
            .pad = p.pad,
            .name = name,
            .side = sideOf(p.angle),
            // A connector whose pinout names every contact after its own contact
            // number would otherwise print that number twice per pin — once
            // outside the body and once in.
            .show_name = !shape.namesPad(.{ .pad = p.pad, .name = name }),
            .x = @divTrunc(at.x, per_hundredth),
            .y = @divTrunc(at.y, per_hundredth),
            .len = @divTrunc(p.length, per_hundredth),
        };
    }
    return .{
        .number = number,
        .title = "",
        .pins = out,
        .half_w = halfAbs(box.min.x + shift.x, box.max.x + shift.x),
        .half_h = halfAbs(box.min.y + shift.y, box.max.y + shift.y),
        .graphics = try body(ctx.arena, u.graphics, box, shift),
    };
}

/// The unit's drawn body, translated onto the re-centred origin. A vendor unit
/// with no graphics of its own (pins only) gets a rectangle inset from its pin
/// endpoints, so it reads as a body rather than a box drawn over its own pins.
fn body(
    arena: std.mem.Allocator,
    graphics: []const kicad_sym.Graphic,
    box: Box,
    shift: kicad_sym.Point,
) std.mem.Allocator.Error![]const kicad_sym.Graphic {
    if (graphics.len == 0) return arena.dupe(kicad_sym.Graphic, &.{try inset(arena, box, shift)});
    const out = try arena.alloc(kicad_sym.Graphic, graphics.len);
    for (graphics, 0..) |g, i| out[i] = try translate(arena, g, shift);
    return out;
}

fn inset(
    arena: std.mem.Allocator,
    box: Box,
    shift: kicad_sym.Point,
) std.mem.Allocator.Error!kicad_sym.Graphic {
    const dx = @min(grid_u, @divFloor(box.max.x - box.min.x, 4));
    const dy = @min(grid_u, @divFloor(box.max.y - box.min.y, 4));
    const pts = try arena.dupe(kicad_sym.Point, &.{
        .{ .x = box.min.x + dx + shift.x, .y = box.max.y - dy + shift.y },
        .{ .x = box.max.x - dx + shift.x, .y = box.min.y + dy + shift.y },
    });
    return .{ .kind = .rectangle, .pts = pts, .style = .{ .width = 254, .fill = .background } };
}

/// Move one graphic by `shift`. A text anchor is additionally grid-snapped:
/// it is the one graphic whose position the emitted file still spells as an
/// `(at …)`, which the self-check's grid scan does check.
fn translate(
    arena: std.mem.Allocator,
    g: kicad_sym.Graphic,
    shift: kicad_sym.Point,
) std.mem.Allocator.Error!kicad_sym.Graphic {
    const pts = try arena.alloc(kicad_sym.Point, g.pts.len);
    for (g.pts, 0..) |p, i| {
        const moved = kicad_sym.Point{ .x = p.x + shift.x, .y = p.y + shift.y };
        pts[i] = if (g.kind == .text)
            .{ .x = snapNearest(moved.x), .y = snapNearest(moved.y) }
        else
            moved;
    }
    var out = g;
    out.pts = pts;
    return out;
}

/// Pin endpoints moved onto the connection grid. Nothing else about a pin
/// moves — the drawn length still reaches the body it came from.
fn snapPins(
    arena: std.mem.Allocator,
    pins: []const kicad_sym.Pin,
) std.mem.Allocator.Error![]const kicad_sym.Pin {
    const out = try arena.alloc(kicad_sym.Pin, pins.len);
    for (pins, 0..) |p, i| {
        out[i] = p;
        out[i].at = .{ .x = snapNearest(p.at.x), .y = snapNearest(p.at.y) };
    }
    return out;
}

/// Bounding box over the unit's pin endpoints and body graphics, or null when
/// the unit has neither.
fn extents(pins: []const kicad_sym.Pin, graphics: []const kicad_sym.Graphic) ?Box {
    var box: ?Box = null;
    for (pins) |p| box = grow(box, p.at, 0);
    for (graphics) |g| {
        for (g.pts) |pt| box = grow(box, pt, g.radius);
    }
    return box;
}

fn grow(box: ?Box, p: kicad_sym.Point, pad: i32) Box {
    var out = box orelse Box{ .min = p, .max = p };
    out.add(p, pad);
    return out;
}

/// Half-extent of a re-centred edge, in hundredths of a millimetre, rounded up
/// onto the grid. Never below one pin pitch: a degenerate body would put the
/// reference and value text on top of the symbol.
fn halfAbs(lo: i32, hi: i32) i32 {
    const widest: i32 = @intCast(@max(@abs(lo), @abs(hi)));
    const hundredths = @divFloor(widest + per_hundredth - 1, per_hundredth);
    return sheet.snapUp(@max(hundredths, shape.pitch));
}

/// Round onto the connection grid, half away from zero at the midpoint, so a
/// whole edge of half-grid pins shifts by one step and keeps its spacing.
fn snapNearest(v: i32) i32 {
    return @divFloor(v + @divExact(grid_u, 2), grid_u) * grid_u;
}

/// A collision-free key for a snapped pin endpoint. Coordinates are bounded by
/// `kicad_sym.max_coord`, so shifting both onto that range and packing them in
/// base `span` is exact — two pins share a key only if they share a point.
fn pointKey(p: kicad_sym.Point) i64 {
    const max: i64 = kicad_sym.max_coord;
    const span = 2 * max + 1;
    return (@as(i64, p.x) + max) * span + (@as(i64, p.y) + max);
}

/// A vendor pin angle points from the connection endpoint back toward the
/// body, which is exactly the convention `emit.pinAngle` writes out — so this
/// is its inverse, with anything off the four axes snapped to the nearest.
fn sideOf(angle: i32) shape.Side {
    return switch (@mod(@divFloor(angle + 45, 90), 4)) {
        1 => .bottom,
        2 => .right,
        3 => .top,
        else => .left,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const flat_lib = @embedFile("../kicad_sym/testdata/vendor-flat.kicad_sym");
const unit_lib = @embedFile("../kicad_sym/testdata/vendor-units.kicad_sym");

/// A one-file vendor index built from `src`, without touching the filesystem.
fn indexOf(arena: std.mem.Allocator, src: []const u8, key: []const u8) !library.Library {
    var lib = library.Library{};
    const syms = try kicad_sym.parseLibrary(arena, src);
    try lib.by_name.put(arena, key, syms[0]);
    lib.files = 1;
    return lib;
}

// spec: export_kicad_sch - A component with a matching vendor symbol is drawn from its real body and pins instead of a synthesised box
test "kicad-sch: a vendor symbol supplies the body, pin sides, and pin names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lib = try indexOf(a, flat_lib, "acme-3");
    const s = try synth(a, &lib, .{ .names = .{ .component = "acme-3" }, .project_dir = "/nonexistent" });
    try testing.expect(s.vendor);
    try testing.expectEqualStrings("acme-3", s.lib_name);
    try testing.expectEqual(@as(usize, 1), s.units.len);

    const u = s.units[0];
    try testing.expectEqual(@as(usize, 3), u.pins.len);
    // Angle 0 means "the body is to my right", i.e. a left-edge pin.
    try testing.expectEqual(shape.Side.left, u.pins[0].side);
    try testing.expectEqual(shape.Side.right, u.pins[2].side);
    try testing.expectEqualStrings("D", u.pins[2].name);
    // The vendor's own 5.08 mm pin length survives, unlike a synthesised pin.
    try testing.expectEqual(@as(i32, 508), u.pins[2].len);
    // The vendor rectangle is carried through rather than replaced.
    try testing.expectEqual(@as(usize, 1), u.graphics.len);
    try testing.expectEqual(kicad_sym.Kind.rectangle, u.graphics[0].kind);
    // Re-centred on the origin: the pin row spans 0..33.02 mm in the vendor
    // file, so it comes out symmetric about x = 0.
    try testing.expectEqual(-u.pins[2].x, u.pins[0].x);
}

// spec: export_kicad_sch - Every symbol pin lands on the connection grid even when the vendor drew the part on a half-grid pitch
test "kicad-sch: vendor pin endpoints are snapped onto the 1.27 mm grid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lib = try indexOf(a, unit_lib, "acme-dual");
    const s = try synth(a, &lib, .{ .names = .{ .component = "acme-dual" }, .project_dir = "/nonexistent" });
    try testing.expect(s.vendor);
    for (s.units) |u| {
        try testing.expect(u.pins.len > 0 or u.graphics.len > 0);
    }
    // Both vendor units are kept, and the half-grid 12.065 mm pin has moved
    // onto the grid.
    try testing.expectEqual(@as(usize, 2), s.units.len);
    try testing.expectEqual(@as(i32, 0), @mod(s.units[0].pins[0].x, shape.grid));
    try testing.expectEqual(@as(i32, 0), @mod(s.units[0].pins[0].y, shape.grid));
    try testing.expectEqual(@as(i32, 0), @mod(s.units[0].half_w, shape.grid));
    // The shared unit-0 body is folded onto every real unit.
    try testing.expect(s.units[1].graphics.len >= 4);
}

// spec: export_kicad_sch - A pad the vendor symbol does not draw is added as a trailing unit rather than failing the export
test "kicad-sch: pads missing from a vendor symbol land in a catch-all unit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const lib = try indexOf(a, flat_lib, "acme-3");
    // The netlist uses a thermal pad the vendor symbol has no pin for.
    const used = [_][]const u8{ "2", "EP" };
    const s = try synth(a, &lib, .{
        .names = .{ .component = "acme-3" },
        .project_dir = "/nonexistent",
        .used = &used,
    });
    try testing.expectEqual(@as(usize, 2), s.units.len);
    try testing.expectEqual(@as(u32, 2), s.units[1].number);
    try testing.expectEqual(@as(usize, 1), s.units[1].pins.len);
    try testing.expectEqualStrings("EP", s.units[1].pins[0].pad);
    // The vendor unit is untouched, so no pad is drawn twice.
    try testing.expectEqual(@as(usize, 3), s.units[0].pins.len);
}

const duplicate_lib =
    \\(kicad_symbol_lib (version 20211014)
    \\  (symbol "DUP"
    \\    (pin passive line (at 0 0 0) (length 2.54)
    \\      (name "A" (effects)) (number "1" (effects)))
    \\    (pin passive line (at 0 -2.54 0) (length 2.54)
    \\      (name "B" (effects)) (number "1" (effects)))))
;

const collide_lib =
    \\(kicad_symbol_lib (version 20211014)
    \\  (symbol "TIGHT"
    \\    (pin passive line (at 0 0 0) (length 2.54)
    \\      (name "A" (effects)) (number "1" (effects)))
    \\    (pin passive line (at 0 0.3175 0) (length 2.54)
    \\      (name "B" (effects)) (number "2" (effects)))))
;

// spec: export_kicad_sch - A vendor symbol that repeats a pad number, or whose pins collide once snapped, falls back to a synthesised box
test "kicad-sch: an unsafe vendor symbol is rejected in favour of the box" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const pads = [_][]const u8{ "1", "2" };
    const dup = try indexOf(a, duplicate_lib, "dup");
    const boxed = try synth(a, &dup, .{
        .names = .{ .component = "dup" },
        .project_dir = "/nonexistent",
        .fp_pads = &pads,
    });
    try testing.expect(!boxed.vendor);
    try testing.expectEqual(@as(usize, 2), boxed.units[0].pins.len);

    const tight = try indexOf(a, collide_lib, "tight");
    const also_boxed = try synth(a, &tight, .{
        .names = .{ .component = "tight" },
        .project_dir = "/nonexistent",
        .fp_pads = &pads,
    });
    try testing.expect(!also_boxed.vendor);
    // Switching vendor passthrough off takes the same path for a good symbol.
    const off = try synth(a, null, .{ .names = .{ .component = "acme-3" }, .project_dir = "/nonexistent" });
    try testing.expect(!off.vendor);
}

// spec: export_kicad_sch - A vendor pin angle maps to the symbol edge its stub and label run from
test "kicad-sch: sideOf inverts the library pin angle onto an edge" {
    try testing.expectEqual(shape.Side.left, sideOf(0));
    try testing.expectEqual(shape.Side.bottom, sideOf(90));
    try testing.expectEqual(shape.Side.right, sideOf(180));
    try testing.expectEqual(shape.Side.top, sideOf(270));
    // Wrapped and negative spellings of the same four directions.
    try testing.expectEqual(shape.Side.left, sideOf(360));
    try testing.expectEqual(shape.Side.top, sideOf(-90));
    // Anything off the axes snaps to the nearest one.
    try testing.expectEqual(shape.Side.right, sideOf(170));
}

// spec: export_kicad_sch - Grid snapping moves a half-grid coordinate one whole step and leaves an on-grid one alone
test "kicad-sch: snapNearest keeps spacing across a half-grid pin row" {
    try testing.expectEqual(@as(i32, 0), snapNearest(0));
    try testing.expectEqual(@as(i32, grid_u), snapNearest(grid_u));
    try testing.expectEqual(@as(i32, -grid_u), snapNearest(-grid_u));
    // 12.065 and 10.795 mm are consecutive half-grid positions: both move up
    // one half step, so the 1.27 mm spacing between them survives.
    try testing.expectEqual(@as(i32, 127000), snapNearest(120650));
    try testing.expectEqual(@as(i32, 114300), snapNearest(107950));
}
