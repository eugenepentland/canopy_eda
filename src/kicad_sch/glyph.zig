//! Stock-KiCad passive glyphs for the `.kicad_sch` exporter.
//!
//! A synthesised box is an honest drawing of an IC whose symbol netlisp does
//! not have, but it is the wrong drawing of a resistor: an engineer reads a
//! schematic by shape, and a page of identical boxes hides which part is the
//! decoupling cap and which is the series ferrite. This module supplies the
//! shapes KiCad's own `Device` library draws — the narrow IEC resistor body,
//! the capacitor's two plates, the inductor's four arcs, the diode triangle and
//! cathode bar, the ferrite bead's slashed parallelogram, the test-point
//! circle — so a netlisp-native passive reads like every other KiCad sheet.
//!
//! **The geometry is embedded, never read from `/usr/share/kicad`.** It was
//! transcribed from `Device.kicad_sym` (KiCad 10.0.1) and is reproduced here as
//! comptime constants: the export must be deterministic and must not depend on
//! a KiCad installation being present, or being the same version, on the
//! machine that runs it.
//!
//! Two deliberate departures from the stock symbols, both forced by the way the
//! rest of the exporter draws a sheet:
//!
//!   * **Horizontal, not vertical.** `Device:R`/`C`/`L`/`FerriteBead`/`Fuse`
//!     are drawn with their pins at the top and bottom; every placed symbol
//!     here sits at angle 0 with its net labels running left and right, so each
//!     body is transcribed through a quarter turn — library point `(x, y)`
//!     becomes `(-y, x)`. `Device:D`/`LED` are already horizontal and are
//!     copied as they stand.
//!   * **`Device:C`'s 2.794 mm pin length becomes 2.54 mm.** The exporter's
//!     unit is a hundredth of a millimetre and 2.794 is not a whole number of
//!     them; the drawn lead simply stops 0.508 mm short of the plate instead of
//!     0.254 mm short. Every *connection endpoint* is unchanged at 3.81 mm,
//!     which is the number that matters — it is a multiple of the 1.27 mm
//!     connection grid, so the ERC grid rule stays silent.
//!
//! Body art is in `kicad_sym` units (ten-thousandths of a millimetre, y-UP),
//! matching the vendor-passthrough path so `emit` writes both the same way.
//! Pin endpoints are in the exporter's hundredths.

const std = @import("std");
const kicad_sym = @import("../kicad_sym/reader.zig");
const shape = @import("shape.zig");

/// Ten-thousandths of a millimetre per hundredth — the two units this module
/// straddles (body art in the former, pin endpoints in the latter).
const u4mm: i32 = @divExact(kicad_sym.per_mm, 100);

/// Connection endpoint of every two-terminal glyph, in hundredths: 3.81 mm out
/// from the origin, exactly as the stock Device symbols place theirs (and a
/// multiple of the 1.27 mm connection grid).
const reach: i32 = 381;
/// A one-terminal glyph (the test point) is drawn compactly, so its pin sits
/// one grid step closer.
const probe_reach: i32 = 254;

/// Which stock glyph a component is drawn as. `box` is the synthesised
/// rectangle every other part keeps.
pub const Class = enum {
    box,
    resistor,
    capacitor,
    polarized_cap,
    inductor,
    ferrite_bead,
    diode,
    led,
    fuse,
    testpoint,
};

/// How one glyph's pins and body extents are laid out. `half_w`/`half_h` bound
/// the body for cell sizing, the Reference/Value text offsets, and the wiring
/// pass's obstacle box — so both are multiples of the connection grid (the text
/// anchors are `(at …)` forms the self-check grid-scans) and both stay *inside*
/// the pin endpoints, or a route could never leave the pin.
const Metrics = struct {
    /// Drawn lead length back toward the body, in hundredths.
    lead: i32,
    half_w: i32,
    half_h: i32,
};

/// Pick the glyph for one component. The library component name is the most
/// specific signal netlisp has, the declared `(symbol …)` the next, and the
/// ref-des prefix the last resort — an imported or ad-hoc part often has only
/// the last. Returns `box` for anything unrecognised, which is the old
/// behaviour exactly.
pub fn classify(component: []const u8, symbol: []const u8, ref: []const u8) Class {
    if (byComponent(component)) |c| return c;
    if (bySymbol(symbol)) |c| return c;
    return byRef(ref);
}

/// Component-name families, most specific first: `ferrite-0402` must not read
/// as an inductor even though both declare `(symbol generic-ind)`, and
/// `led-0402` must not read as a plain diode.
fn byComponent(name: []const u8) ?Class {
    if (name.len == 0) return null;
    if (family(name, "ferrite") or family(name, "bead")) return .ferrite_bead;
    if (family(name, "led")) return .led;
    if (family(name, "diode")) return .diode;
    if (family(name, "testpoint") or family(name, "test-point")) return .testpoint;
    if (family(name, "res")) return .resistor;
    if (family(name, "ind") or family(name, "coil") or family(name, "choke")) return .inductor;
    if (family(name, "fuse") or family(name, "polyfuse")) return .fuse;
    return capFamily(name);
}

/// Capacitor families. A polarized part (electrolytic, tantalum, an explicit
/// `cap-pol…`) draws the marked-plate variant; every other `cap…` draws the two
/// plain plates. No design in this project ships a polarized family today —
/// the branch exists so one names its glyph correctly the day it does.
fn capFamily(name: []const u8) ?Class {
    for (polarized_prefixes) |p| {
        if (hasPrefix(name, p)) return .polarized_cap;
    }
    if (family(name, "cap")) return .capacitor;
    return null;
}

/// Component-name prefixes that mean a polarized capacitor. `cp-` is KiCad's
/// own footprint spelling for one; the rest are how a netlisp family would
/// plausibly be named.
const polarized_prefixes = [_][]const u8{
    "cp-",
    "cap-pol",
    "cap-tant",
    "cap-elec",
    "tantalum",
    "electrolytic",
};

/// The `(symbol …)` a component family declares. `generic-ind` is shared by
/// inductors and ferrites, so it only ever reaches here for a component name
/// `byComponent` did not already classify.
fn bySymbol(name: []const u8) ?Class {
    if (std.mem.eql(u8, name, "generic-res")) return .resistor;
    if (std.mem.eql(u8, name, "generic-cap")) return .capacitor;
    if (std.mem.eql(u8, name, "generic-ind")) return .inductor;
    if (std.mem.eql(u8, name, "led")) return .led;
    return null;
}

/// True when `name` is `prefix` or `prefix` followed by a package/size
/// qualifier — so `res`, `res-0402` and `res0603` are resistors while
/// `resonator` and `reset-supervisor` are not.
fn family(name: []const u8, prefix: []const u8) bool {
    if (!hasPrefix(name, prefix)) return false;
    if (name.len == prefix.len) return true;
    const next = name[prefix.len];
    return next == '-' or next == '_' or std.ascii.isDigit(next);
}

/// Last resort: the ref-des class letter, read off the leaf of a sub-block
/// path. `FB` is a ferrite bead and `FID` a fiducial, so a bare `F` prefix only
/// means a fuse when nothing else follows the letter but digits.
fn byRef(ref: []const u8) Class {
    const leaf = if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| ref[i + 1 ..] else ref;
    if (leaf.len == 0) return .box;
    if (hasPrefix(leaf, "FB")) return .ferrite_bead;
    if (hasPrefix(leaf, "LED")) return .led;
    if (hasPrefix(leaf, "TP")) return .testpoint;
    if (hasPrefix(leaf, "FID")) return .box;
    return byRefLetter(leaf);
}

fn byRefLetter(leaf: []const u8) Class {
    if (!tailIsDigits(leaf[1..])) return .box;
    return switch (std.ascii.toUpper(leaf[0])) {
        'R' => .resistor,
        'C' => .capacitor,
        'L' => .inductor,
        'D' => .diode,
        'F' => .fuse,
        else => .box,
    };
}

/// True when everything after the class letter is a plain number — `R14` is a
/// resistor, `RN1` (a network) and `REG3` are not.
fn tailIsDigits(tail: []const u8) bool {
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn hasPrefix(name: []const u8, prefix: []const u8) bool {
    if (name.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix);
}

/// Build the drawn unit for one glyph class, or null when the class is `box` or
/// the part does not have the pad count the glyph draws (a three-pad part
/// called `res-array` is not a resistor symbol). The caller then synthesises
/// its box exactly as before.
pub fn unitFor(
    arena: std.mem.Allocator,
    class: Class,
    pads: []const shape.PadName,
) std.mem.Allocator.Error!?shape.Unit {
    if (class == .box) return null;
    if (class == .testpoint) {
        if (pads.len != 1) return null;
        return try probeUnit(arena, pads[0]);
    }
    if (pads.len != 2) return null;
    return try twoPinUnit(arena, class, pads);
}

/// The two-terminal body: pad on the left, pad on the right, the glyph between
/// them. A diode or LED is oriented by pin *function* — the cathode goes on the
/// left, under the bar, whichever pad carries it — because the two pinouts in
/// this project disagree about which pad that is.
fn twoPinUnit(
    arena: std.mem.Allocator,
    class: Class,
    pads: []const shape.PadName,
) std.mem.Allocator.Error!shape.Unit {
    const m = metricsOf(class);
    const flip = polarized(class) and cathodeIsSecond(pads);
    const left = if (flip) pads[1] else pads[0];
    const right = if (flip) pads[0] else pads[1];

    const pins = try arena.alloc(shape.Pin, 2);
    pins[0] = .{ .pad = left.pad, .name = left.name, .side = .left, .x = -reach, .y = 0, .len = m.lead };
    pins[1] = .{ .pad = right.pad, .name = right.name, .side = .right, .x = reach, .y = 0, .len = m.lead };
    return .{
        .number = 1,
        .title = "",
        .pins = pins,
        .half_w = m.half_w,
        .half_h = m.half_h,
        .graphics = bodyOf(class),
    };
}

/// The one-terminal test point: a probe circle on a short lead.
fn probeUnit(arena: std.mem.Allocator, pad: shape.PadName) std.mem.Allocator.Error!shape.Unit {
    const m = metricsOf(.testpoint);
    const pins = try arena.alloc(shape.Pin, 1);
    pins[0] = .{
        .pad = pad.pad,
        .name = pad.name,
        .side = .left,
        .x = -probe_reach,
        .y = 0,
        .len = m.lead,
    };
    return .{
        .number = 1,
        .title = "",
        .pins = pins,
        .half_w = m.half_w,
        .half_h = m.half_h,
        .graphics = bodyOf(.testpoint),
    };
}

fn polarized(class: Class) bool {
    return class == .diode or class == .led;
}

/// True when the SECOND pad is the cathode, so the pair must be swapped to put
/// the cathode under the bar. `lib/pinouts/led.sexp` numbers the anode first
/// while `diode-0402` numbers the cathode first, so the name decides.
fn cathodeIsSecond(pads: []const shape.PadName) bool {
    return isCathode(pads[1].name) and !isCathode(pads[0].name);
}

fn isCathode(name: []const u8) bool {
    if (name.len == 0) return false;
    if (hasPrefix(name, "K")) return true;
    return hasPrefix(name, "CATHODE");
}

fn metricsOf(class: Class) Metrics {
    return switch (class) {
        .box => .{ .lead = shape.pin_len, .half_w = 127, .half_h = 127 },
        .resistor, .fuse => .{ .lead = 127, .half_w = 254, .half_h = 127 },
        .capacitor => .{ .lead = 254, .half_w = 127, .half_h = 254 },
        .polarized_cap => .{ .lead = 254, .half_w = 254, .half_h = 254 },
        .inductor => .{ .lead = 127, .half_w = 254, .half_h = 127 },
        .ferrite_bead => .{ .lead = 254, .half_w = 254, .half_h = 381 },
        .diode => .{ .lead = 254, .half_w = 127, .half_h = 127 },
        .led => .{ .lead = 254, .half_w = 254, .half_h = 254 },
        .testpoint => .{ .lead = 254, .half_w = 127, .half_h = 127 },
    };
}

fn bodyOf(class: Class) []const kicad_sym.Graphic {
    return switch (class) {
        .box => &.{},
        .resistor => &resistor_body,
        .capacitor => &capacitor_body,
        .polarized_cap => &polarized_body,
        .inductor => &inductor_body,
        .ferrite_bead => &ferrite_body,
        .diode => &diode_body,
        .led => &led_body,
        .fuse => &fuse_body,
        .testpoint => &probe_body,
    };
}

// ── Embedded geometry ──────────────────────────────────────────────────
//
// Transcribed from KiCad 10.0.1's `Device.kicad_sym` / `Connector.kicad_sym`,
// quarter-turned where the stock symbol is vertical (see the module header).
// Units are ten-thousandths of a millimetre, y-UP.

const Pt = kicad_sym.Point;
const Graphic = kicad_sym.Graphic;

/// KiCad's default body-outline stroke, 0.254 mm. A zero width means "use the
/// document default", which is what the stock symbols write for their thinner
/// detail lines.
const outline: kicad_sym.Style = .{ .width = 2540, .fill = .none };
const hairline: kicad_sym.Style = .{ .width = 0, .fill = .none };
const filled: kicad_sym.Style = .{ .width = 0, .fill = .outline };
/// `Device:C`'s plates are drawn twice as heavy as an outline.
const plate: kicad_sym.Style = .{ .width = 5080, .fill = .none };

fn pt(x: i32, y: i32) Pt {
    return .{ .x = x, .y = y };
}

/// `Device:R` — the narrow IEC rectangle, on its side.
const resistor_body = [_]Graphic{
    .{ .kind = .rectangle, .pts = &.{ pt(-25400, 10160), pt(25400, -10160) }, .style = outline },
};

/// `Device:C` — two parallel plates.
const capacitor_body = [_]Graphic{
    .{ .kind = .polyline, .pts = &.{ pt(-7620, -20320), pt(-7620, 20320) }, .style = plate },
    .{ .kind = .polyline, .pts = &.{ pt(7620, -20320), pt(7620, 20320) }, .style = plate },
};

/// `Device:C_Polarized` — a hollow plate, a filled one, and the `+` mark.
const polarized_body = [_]Graphic{
    .{ .kind = .rectangle, .pts = &.{ pt(-5080, -22860), pt(-10160, 22860) }, .style = hairline },
    .{ .kind = .polyline, .pts = &.{ pt(-22860, -17780), pt(-22860, -7620) }, .style = hairline },
    .{ .kind = .polyline, .pts = &.{ pt(-27940, -12700), pt(-17780, -12700) }, .style = hairline },
    .{ .kind = .rectangle, .pts = &.{ pt(5080, 22860), pt(10160, -22860) }, .style = filled },
};

/// `Device:L` — four half-turn arcs in a row.
const inductor_body = [_]Graphic{
    .{ .kind = .arc, .pts = &.{ pt(-25400, 0), pt(-19050, 6323), pt(-12700, 0) }, .style = hairline },
    .{ .kind = .arc, .pts = &.{ pt(-12700, 0), pt(-6350, 6323), pt(0, 0) }, .style = hairline },
    .{ .kind = .arc, .pts = &.{ pt(0, 0), pt(6350, 6323), pt(12700, 0) }, .style = hairline },
    .{ .kind = .arc, .pts = &.{ pt(12700, 0), pt(19050, 6323), pt(25400, 0) }, .style = hairline },
};

/// `Device:FerriteBead` — the slashed parallelogram with its two lead nubs.
const ferrite_body = [_]Graphic{
    .{
        .kind = .polyline,
        .pts = &.{
            pt(-4064, -27686), pt(-22606, -17018), pt(3048, 27686),
            pt(21590, 16764),  pt(-4064, -27686),
        },
        .style = hairline,
    },
    .{ .kind = .polyline, .pts = &.{ pt(-12700, 0), pt(-12954, 0) }, .style = hairline },
    .{ .kind = .polyline, .pts = &.{ pt(12700, 0), pt(12192, 0) }, .style = hairline },
};

/// `Device:D` — cathode bar on the left, triangle pointing into it.
const diode_body = [_]Graphic{
    .{ .kind = .polyline, .pts = &.{ pt(-12700, 12700), pt(-12700, -12700) }, .style = outline },
    .{
        .kind = .polyline,
        .pts = &.{ pt(12700, 12700), pt(12700, -12700), pt(-12700, 0), pt(12700, 12700) },
        .style = outline,
    },
    .{ .kind = .polyline, .pts = &.{ pt(12700, 0), pt(-12700, 0) }, .style = hairline },
};

/// `Device:LED` — the diode plus the two emission arrows.
const led_body = [_]Graphic{
    .{
        .kind = .polyline,
        .pts = &.{
            pt(-30480, -7620),  pt(-45720, -22860), pt(-38100, -22860),
            pt(-45720, -22860), pt(-45720, -15240),
        },
        .style = hairline,
    },
    .{
        .kind = .polyline,
        .pts = &.{
            pt(-17780, -7620),  pt(-33020, -22860), pt(-25400, -22860),
            pt(-33020, -22860), pt(-33020, -15240),
        },
        .style = hairline,
    },
    .{ .kind = .polyline, .pts = &.{ pt(-12700, 0), pt(12700, 0) }, .style = hairline },
    .{ .kind = .polyline, .pts = &.{ pt(-12700, -12700), pt(-12700, 12700) }, .style = outline },
    .{
        .kind = .polyline,
        .pts = &.{ pt(12700, -12700), pt(12700, 12700), pt(-12700, 0), pt(12700, -12700) },
        .style = outline,
    },
};

/// `Device:Fuse` — a box with the element drawn through it.
const fuse_body = [_]Graphic{
    .{ .kind = .rectangle, .pts = &.{ pt(-25400, 7620), pt(25400, -7620) }, .style = outline },
    .{ .kind = .polyline, .pts = &.{ pt(-25400, 0), pt(25400, 0) }, .style = hairline },
};

/// `Connector:TestPoint` — the probe circle on the end of its lead.
const probe_body = [_]Graphic{
    .{ .kind = .circle, .pts = &.{pt(7620, 0)}, .radius = 7620, .style = hairline },
};

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: export_kicad_sch - Each passive ref class picks its own stock KiCad glyph, and an unrecognised part keeps the box
test "kicad-sch: classify picks a glyph per passive class and boxes everything else" {
    try testing.expectEqual(Class.resistor, classify("res-0402", "generic-res", "R1"));
    try testing.expectEqual(Class.capacitor, classify("cap-0402", "generic-cap", "C12"));
    try testing.expectEqual(Class.polarized_cap, classify("cap-tantalum", "generic-cap", "C3"));
    try testing.expectEqual(Class.inductor, classify("ind-0402", "generic-ind", "L2"));
    // A ferrite declares the inductor symbol, so only its component name tells
    // the bead from the coil.
    try testing.expectEqual(Class.ferrite_bead, classify("ferrite-0402", "generic-ind", "L7"));
    try testing.expectEqual(Class.diode, classify("diode-0402", "", "D1"));
    try testing.expectEqual(Class.led, classify("led-0603-1608metric", "led", "D4"));
    try testing.expectEqual(Class.testpoint, classify("testpoint", "", "TP3"));
    // Ref-des fallback for a component the name rules do not know.
    try testing.expectEqual(Class.capacitor, classify("mystery", "", "usb/C9"));
    try testing.expectEqual(Class.ferrite_bead, classify("mystery", "", "FB2"));
    // A fiducial and a hub keep the box.
    try testing.expectEqual(Class.box, classify("fiducial", "", "FID1"));
    try testing.expectEqual(Class.box, classify("stm32n657", "", "U9"));
    try testing.expectEqual(Class.box, classify("", "", "REG3"));
}

const two_pads = [_]shape.PadName{
    .{ .pad = "1", .name = "1" },
    .{ .pad = "2", .name = "2" },
};

// spec: export_kicad_sch - A glyph draws its stock body with both pins on the connection grid at the stock 3.81 mm reach
test "kicad-sch: a glyph unit keeps the stock pin endpoints and carries real body art" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const u = (try unitFor(a, .resistor, &two_pads)).?;
    try testing.expectEqual(@as(usize, 2), u.pins.len);
    try testing.expectEqual(@as(i32, -reach), u.pins[0].x);
    try testing.expectEqual(@as(i32, reach), u.pins[1].x);
    try testing.expectEqual(shape.Side.left, u.pins[0].side);
    try testing.expectEqual(shape.Side.right, u.pins[1].side);
    try testing.expectEqual(@as(usize, 1), u.graphics.len);
    // Every connection point and every text-anchor offset lands on the grid.
    for (u.pins) |p| {
        try testing.expectEqual(@as(i32, 0), @mod(p.x, shape.grid));
        try testing.expectEqual(@as(i32, 0), @mod(p.y, shape.grid));
    }
    try testing.expectEqual(@as(i32, 0), @mod(u.half_w, shape.grid));
    try testing.expectEqual(@as(i32, 0), @mod(u.half_h, shape.grid));
    // The body must stay inside the pins, or a route could not leave one.
    try testing.expect(u.half_w < reach);

    // A test point is the one-pin glyph; a box or a wrong pad count is not
    // drawn here at all.
    try testing.expect((try unitFor(a, .testpoint, &two_pads)) == null);
    try testing.expect((try unitFor(a, .box, &two_pads)) == null);
    try testing.expect((try unitFor(a, .resistor, two_pads[0..1])) == null);
}

// spec: export_kicad_sch - A diode glyph puts the cathode under its bar whichever pad the pinout numbers it
test "kicad-sch: a diode glyph orients itself by pin function, not pad order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const k_first = [_]shape.PadName{ .{ .pad = "1", .name = "K" }, .{ .pad = "2", .name = "A" } };
    const straight = (try unitFor(a, .diode, &k_first)).?;
    try testing.expectEqualStrings("1", straight.pins[0].pad);

    // lib/pinouts/led.sexp numbers the anode first — the cathode still has to
    // land on the left, under the bar.
    const a_first = [_]shape.PadName{ .{ .pad = "1", .name = "A" }, .{ .pad = "2", .name = "K" } };
    const flipped = (try unitFor(a, .led, &a_first)).?;
    try testing.expectEqualStrings("2", flipped.pins[0].pad);
    try testing.expectEqualStrings("1", flipped.pins[1].pad);

    // A capacitor is not polarized: its pads keep their order.
    const caps = (try unitFor(a, .capacitor, &a_first)).?;
    try testing.expectEqualStrings("1", caps.pins[0].pad);
}
