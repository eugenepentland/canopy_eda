//! Reader for KiCad symbol libraries (`.kicad_sym`).
//!
//! netlisp carries no schematic symbol geometry of its own, but a project's
//! `lib/sources/` keeps the original vendor `.kicad_sym` files its parts were
//! imported from. This module parses one of those libraries into a small,
//! neutral model — units, pins with their connection endpoints, and body
//! graphics — which the `.kicad_sch` exporter draws in place of a synthesised
//! box.
//!
//! Vendor files span several KiCad format epochs (this project's own sources
//! run 20211014 through 20231120), so the reader is deliberately liberal: it
//! looks only for the forms it understands, ignores everything else, and
//! returns an error rather than raising — the exporter then falls back to a
//! synthesised box for that part, so an unreadable library never fails an
//! export.
//!
//! Two library shapes are both handled: KiCad's own, where every drawn item
//! lives inside a `<NAME>_<unit>_<style>` sub-symbol, and the vendor
//! (SamacSys) style, where the items sit directly under `(symbol "NAME" …)`.
//! Direct items land in unit 0 — KiCad's "common to every unit" bucket.
//!
//! Lengths are integer ten-thousandths of a millimetre (`per_mm`). Vendor
//! geometry carries up to six decimal places, which neither the exporter's
//! hundredths-of-a-millimetre grid nor a float round-trip would reproduce
//! byte-stably.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser = @import("../sexpr/parser.zig");
const numeric = @import("../numeric.zig");

const Node = ast.Node;

/// Internal length unit: one ten-thousandth of a millimetre. Fine enough for
/// every coordinate a vendor library writes, and integral so re-emitted
/// geometry is byte-identical on every run.
pub const per_mm: i32 = 10000;

/// Coordinates are clamped to +/- 10 metres. No real symbol comes near it, and
/// the bound is what lets a consumer add, subtract, and centre these values in
/// `i32` without a range check at every step.
pub const max_coord: i32 = 100_000_000;

/// A point in library coordinates — y grows UP, origin at the symbol origin.
pub const Point = struct { x: i32 = 0, y: i32 = 0 };

/// How a closed graphic is filled. A vendor `color` fill reads as `outline`;
/// the exporter never carries a vendor colour through.
pub const Fill = enum { none, outline, background };

/// Stroke and fill of one graphic, bundled so `Graphic` stays inside the
/// public struct-size budget.
pub const Style = struct { width: i32 = 0, fill: Fill = .none };

/// Which drawn primitive a `Graphic` is. Anything else in the file (a bezier,
/// a text box, a property) is skipped rather than guessed at.
pub const Kind = enum { rectangle, polyline, circle, arc, text };

/// One drawn item of a symbol body.
pub const Graphic = struct {
    kind: Kind,
    /// `rectangle`: start, end. `polyline`: the vertices. `circle`: the
    /// centre. `arc`: start, mid, end. `text`: the anchor.
    pts: []const Point,
    /// Circle radius; zero for every other kind.
    radius: i32 = 0,
    /// Text rotation in degrees; zero for every other kind.
    angle: i32 = 0,
    /// Text body; empty for every other kind.
    text: []const u8 = "",
    style: Style = .{},
};

/// One symbol pin. `at` is the *connection endpoint* — the point a wire must
/// touch — and `angle` points from that endpoint back toward the body, so a
/// left-edge pin is 0 and a right-edge pin is 180.
pub const Pin = struct {
    /// Physical pad id, from `(number "…")`.
    pad: []const u8,
    /// Function name, from `(name "…")`; `~` means "no name" in KiCad 6.
    name: []const u8,
    at: Point = .{},
    angle: i32 = 0,
    /// Drawn length back toward the body; the connection point is `at`.
    length: i32 = 0,
    hidden: bool = false,
};

/// One KiCad unit's contents. Unit 0 is KiCad's "common to every unit"
/// bucket — its items belong to every real unit of the symbol.
pub const Unit = struct {
    number: u32,
    pins: []const Pin,
    graphics: []const Graphic,
};

/// A parsed library symbol. `units` is sorted by unit number, so unit 0 (when
/// present) comes first.
pub const Symbol = struct {
    name: []const u8,
    units: []const Unit,
};

/// Ways reading a library can fail. Every one of them means "no vendor body
/// for this part" to the caller, never a failed export.
pub const ReadError = std.mem.Allocator.Error || parser.ParseError || error{NotSymbolLib};

/// Parse a whole `.kicad_sym` file. Symbols come out in file order; a symbol
/// the reader can make nothing of is skipped rather than failing the library.
pub fn parseLibrary(arena: std.mem.Allocator, source: []const u8) ReadError![]const Symbol {
    const nodes = try parser.parse(arena, source);
    if (nodes.len == 0 or !nodes[0].isForm("kicad_symbol_lib")) return error.NotSymbolLib;
    const root = nodes[0].asList() orelse return error.NotSymbolLib;

    var out: std.ArrayList(Symbol) = .empty;
    for (root[1..]) |child| {
        if (!child.isForm("symbol")) continue;
        if (try readSymbol(arena, child)) |sym| try out.append(arena, sym);
    }
    return out.items;
}

/// The pins and graphics accumulating for one unit number.
const Acc = struct {
    pins: std.ArrayList(Pin) = .empty,
    graphics: std.ArrayList(Graphic) = .empty,
};

/// Unit contents keyed by unit number, in first-seen order.
const Units = std.array_hash_map.Auto(u32, Acc);

fn readSymbol(arena: std.mem.Allocator, node: Node) ReadError!?Symbol {
    const cl = node.asList() orelse return null;
    if (cl.len < 2) return null;
    const name = cl[1].asText() orelse return null;

    var units: Units = .empty;
    try collect(arena, cl[2..], 0, &units);
    if (units.count() == 0) return null;

    const out = try arena.alloc(Unit, units.count());
    for (units.keys(), units.values(), 0..) |number, acc, i| {
        out[i] = .{ .number = number, .pins = acc.pins.items, .graphics = acc.graphics.items };
    }
    std.mem.sort(Unit, out, {}, lessUnit);
    return .{ .name = name, .units = out };
}

fn lessUnit(_: void, x: Unit, y: Unit) bool {
    return x.number < y.number;
}

/// Walk one symbol's children, filing pins and graphics under `unit` and
/// recursing into `<NAME>_<unit>_<style>` sub-symbols.
fn collect(arena: std.mem.Allocator, children: []const Node, unit: u32, units: *Units) ReadError!void {
    for (children) |child| {
        if (child.isForm("symbol")) {
            try collectSub(arena, child, units);
        } else if (child.isForm("pin")) {
            const pin = readPin(arena, child) orelse continue;
            try (try accFor(arena, units, unit)).pins.append(arena, pin);
        } else if (try readGraphic(arena, child)) |g| {
            try (try accFor(arena, units, unit)).graphics.append(arena, g);
        }
    }
}

/// Recurse into one `<NAME>_<unit>_<style>` sub-symbol. Body style 2 and up is
/// KiCad's DeMorgan alternate, which a netlisp design never selects, so it is
/// dropped rather than drawn on top of the normal body.
fn collectSub(arena: std.mem.Allocator, node: Node, units: *Units) ReadError!void {
    const sub = node.asList() orelse return;
    if (sub.len < 2) return;
    const id = unitId(sub[1].asText() orelse return) orelse return;
    if (id.style > 1) return;
    try collect(arena, sub[2..], id.unit, units);
}

/// The accumulator for one unit number, created on first use.
fn accFor(arena: std.mem.Allocator, units: *Units, unit: u32) std.mem.Allocator.Error!*Acc {
    const gop = try units.getOrPut(arena, unit);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

/// Unit and body-style numbers off a `<NAME>_<unit>_<style>` sub-symbol name.
const UnitId = struct { unit: u32, style: u32 };

fn unitId(name: []const u8) ?UnitId {
    const cut = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const split = std.mem.lastIndexOfScalar(u8, name[0..cut], '_') orelse return null;
    return .{
        .unit = std.fmt.parseInt(u32, name[split + 1 .. cut], 10) catch return null,
        .style = std.fmt.parseInt(u32, name[cut + 1 ..], 10) catch return null,
    };
}

/// `(pin <type> <shape> (at x y a) (length L) [hide] (name "…") (number "…"))`.
/// The electrical type and shape are read past deliberately: the exporter
/// emits every pin as `passive`, because a typed `input` pin raises a
/// `pin_not_driven` ERC error on a label-connected sheet.
fn readPin(arena: std.mem.Allocator, node: Node) ?Pin {
    const cl = node.asList() orelse return null;
    var p = Pin{ .pad = "", .name = "" };
    for (cl[1..]) |child| {
        if (child.asAtom()) |a| {
            if (std.mem.eql(u8, a, "hide")) p.hidden = true;
        } else if (child.isForm("at")) {
            p.at = pointAt(child, 1) orelse p.at;
            p.angle = degrees(scalarAt(child, 3) orelse 0);
        } else if (child.isForm("length")) {
            p.length = unitAt(child, 1);
        } else if (child.isForm("hide")) {
            p.hidden = std.mem.eql(u8, textAt(child, 1) orelse "", "yes");
        } else if (child.isForm("name")) {
            p.name = textAt(child, 1) orelse "";
        } else if (child.isForm("number")) {
            p.pad = tokenAt(arena, child, 1) orelse "";
        }
    }
    return if (p.pad.len == 0) null else p;
}

/// One drawn item, or null when the form is not a graphic this reader models.
fn readGraphic(arena: std.mem.Allocator, node: Node) ReadError!?Graphic {
    if (node.isForm("rectangle")) return try corners(arena, node, &.{ "start", "end" }, .rectangle);
    if (node.isForm("arc")) return try corners(arena, node, &.{ "start", "mid", "end" }, .arc);
    if (node.isForm("polyline")) return try vertices(arena, node);
    if (node.isForm("circle")) return try disc(arena, node);
    if (node.isForm("text")) return try label(arena, node);
    return null;
}

/// A graphic defined by a fixed list of named points (`rectangle`, `arc`).
/// Missing any one of them means the form is malformed, so it is skipped.
fn corners(
    arena: std.mem.Allocator,
    node: Node,
    names: []const []const u8,
    kind: Kind,
) std.mem.Allocator.Error!?Graphic {
    const pts = try arena.alloc(Point, names.len);
    for (names, 0..) |name, i| {
        pts[i] = pointAt(findForm(node, name) orelse return null, 1) orelse return null;
    }
    return .{ .kind = kind, .pts = pts, .style = readStyle(node) };
}

fn vertices(arena: std.mem.Allocator, node: Node) std.mem.Allocator.Error!?Graphic {
    const cl = (findForm(node, "pts") orelse return null).asList() orelse return null;
    var out: std.ArrayList(Point) = .empty;
    for (cl[1..]) |child| {
        if (!child.isForm("xy")) continue;
        try out.append(arena, pointAt(child, 1) orelse continue);
    }
    if (out.items.len < 2) return null;
    return .{ .kind = .polyline, .pts = out.items, .style = readStyle(node) };
}

fn disc(arena: std.mem.Allocator, node: Node) std.mem.Allocator.Error!?Graphic {
    const centre = pointAt(findForm(node, "center") orelse return null, 1) orelse return null;
    const radius = unitAt(findForm(node, "radius") orelse return null, 1);
    if (radius <= 0) return null;
    const pts = try arena.dupe(Point, &.{centre});
    return .{ .kind = .circle, .pts = pts, .radius = radius, .style = readStyle(node) };
}

fn label(arena: std.mem.Allocator, node: Node) std.mem.Allocator.Error!?Graphic {
    const body = textAt(node, 1) orelse return null;
    if (body.len == 0) return null;
    const anchor = findForm(node, "at") orelse return null;
    const pts = try arena.dupe(Point, &.{pointAt(anchor, 1) orelse return null});
    return .{
        .kind = .text,
        .pts = pts,
        .angle = degrees(scalarAt(anchor, 3) orelse 0),
        .text = body,
    };
}

/// `(stroke (width W) …)` + `(fill (type none|outline|background|color))`.
fn readStyle(node: Node) Style {
    var st = Style{};
    if (findForm(node, "stroke")) |s| {
        if (findForm(s, "width")) |w| st.width = unitAt(w, 1);
    }
    if (findForm(node, "fill")) |f| {
        if (findForm(f, "type")) |t| st.fill = fillOf(textAt(t, 1) orelse "");
    }
    return st;
}

fn fillOf(name: []const u8) Fill {
    if (std.mem.eql(u8, name, "background")) return .background;
    if (std.mem.eql(u8, name, "outline")) return .outline;
    if (std.mem.eql(u8, name, "color")) return .outline;
    return .none;
}

/// The first child form of `node` named `name`.
fn findForm(node: Node, name: []const u8) ?Node {
    const cl = node.asList() orelse return null;
    for (cl[1..]) |child| {
        if (child.isForm(name)) return child;
    }
    return null;
}

fn textAt(node: Node, i: usize) ?[]const u8 {
    const cl = node.asList() orelse return null;
    if (cl.len <= i) return null;
    return cl[i].asText();
}

/// Like `textAt`, but also renders a bare integer — a pad written `(number 1)`
/// must resolve to the same "1" a quoted `(number "1")` does.
fn tokenAt(arena: std.mem.Allocator, node: Node, i: usize) ?[]const u8 {
    const cl = node.asList() orelse return null;
    if (cl.len <= i) return null;
    return cl[i].tokenText(arena);
}

fn scalarAt(node: Node, i: usize) ?f64 {
    const cl = node.asList() orelse return null;
    if (cl.len <= i) return null;
    return cl[i].asNumber();
}

/// A millimetre value at argument `i`, converted to internal units. An
/// unreadable or out-of-range number reads as zero rather than aborting the
/// symbol — a stroke width of zero is KiCad's own "use the default".
fn unitAt(node: Node, i: usize) i32 {
    return toUnit(scalarAt(node, i) orelse 0);
}

fn pointAt(node: Node, i: usize) ?Point {
    return .{
        .x = toUnit(scalarAt(node, i) orelse return null),
        .y = toUnit(scalarAt(node, i + 1) orelse return null),
    };
}

fn toUnit(mm: f64) i32 {
    const v = numeric.checkedInt(i32, @round(mm * @as(f64, @floatFromInt(per_mm)))) orelse 0;
    return std.math.clamp(v, -max_coord, max_coord);
}

fn degrees(v: f64) i32 {
    return numeric.checkedInt(i32, @round(v)) orelse 0;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const vendor_style = @embedFile("testdata/vendor-flat.kicad_sym");
const unit_style = @embedFile("testdata/vendor-units.kicad_sym");

// spec: export_kicad_sch - A vendor .kicad_sym written with its items directly under the symbol reads as one common unit carrying the pins and body
test "kicad-sym: reader parses a flat vendor symbol's pins and body graphics" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const syms = try parseLibrary(a, vendor_style);
    try testing.expectEqual(@as(usize, 1), syms.len);
    try testing.expectEqualStrings("ACME-3", syms[0].name);
    try testing.expectEqual(@as(usize, 1), syms[0].units.len);

    const u = syms[0].units[0];
    try testing.expectEqual(@as(u32, 0), u.number);
    try testing.expectEqual(@as(usize, 3), u.pins.len);
    try testing.expectEqualStrings("1", u.pins[0].pad);
    try testing.expectEqualStrings("G", u.pins[0].name);
    try testing.expectEqual(@as(i32, 0), u.pins[0].at.x);
    try testing.expectEqual(@as(i32, 0), u.pins[0].angle);
    // The right-hand pin faces back at the body: KiCad writes that as 180.
    try testing.expectEqual(@as(i32, 180), u.pins[2].angle);
    try testing.expectEqual(@as(i32, 50800), u.pins[2].length);
    // The body is one filled rectangle, offset from the symbol origin.
    try testing.expectEqual(@as(usize, 1), u.graphics.len);
    try testing.expectEqual(Kind.rectangle, u.graphics[0].kind);
    try testing.expectEqual(Fill.background, u.graphics[0].style.fill);
    try testing.expectEqual(@as(i32, 50800), u.graphics[0].pts[0].x);
}

// spec: export_kicad_sch - A vendor symbol's per-unit sub-symbols read as separate units and its off-grid, high-precision geometry survives
test "kicad-sym: reader splits sub-symbols into units and keeps sub-hundredth coordinates" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const syms = try parseLibrary(a, unit_style);
    try testing.expectEqual(@as(usize, 1), syms.len);
    // Unit 0 (the shared body) sorts before units 1 and 2; the DeMorgan
    // alternate body style is dropped rather than drawn over the normal one.
    try testing.expectEqual(@as(usize, 3), syms[0].units.len);
    try testing.expectEqual(@as(u32, 0), syms[0].units[0].number);
    try testing.expectEqual(@as(u32, 1), syms[0].units[1].number);
    try testing.expectEqual(@as(u32, 2), syms[0].units[2].number);
    try testing.expectEqual(@as(usize, 0), syms[0].units[0].pins.len);
    // The alternate body style contributes no pin of its own to unit 1.
    try testing.expectEqual(@as(usize, 1), syms[0].units[1].pins.len);
    try testing.expectEqualStrings("A1", syms[0].units[1].pins[0].pad);
    // 12.065 mm is a half-grid position: exact in ten-thousandths, lost in
    // the exporter's hundredths.
    try testing.expectEqual(@as(i32, 120650), syms[0].units[1].pins[0].at.y);
    // A hidden pin still reports its pad, so the exporter can still wire it.
    try testing.expect(syms[0].units[2].pins[0].hidden);
}

// spec: export_kicad_sch - The vendor symbol reader models polylines, circles, arcs, and text and drops graphics it cannot read
test "kicad-sym: reader models each body primitive and skips malformed ones" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const syms = try parseLibrary(a, unit_style);
    const g = syms[0].units[0].graphics;
    // polyline, circle, arc, text — the radius-less circle and the unknown
    // `bezier` form are both dropped.
    try testing.expectEqual(@as(usize, 4), g.len);
    try testing.expectEqual(Kind.polyline, g[0].kind);
    try testing.expectEqual(@as(usize, 3), g[0].pts.len);
    try testing.expectEqual(Kind.circle, g[1].kind);
    try testing.expectEqual(@as(i32, 1270), g[1].radius);
    try testing.expectEqual(Kind.arc, g[2].kind);
    try testing.expectEqual(@as(usize, 3), g[2].pts.len);
    try testing.expectEqual(Kind.text, g[3].kind);
    try testing.expectEqualStrings("GREEN", g[3].text);
}

// spec: export_kicad_sch - A file that is not a KiCad symbol library is rejected instead of half-read
test "kicad-sym: reader rejects a non-library root and tolerates an empty library" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectError(error.NotSymbolLib, parseLibrary(a, "(kicad_pcb (version 20240101))"));
    try testing.expectError(error.NotSymbolLib, parseLibrary(a, ""));
    const empty = try parseLibrary(a, "(kicad_symbol_lib (version 20211014))");
    try testing.expectEqual(@as(usize, 0), empty.len);
    // A symbol with nothing drawable in it is skipped, not returned empty.
    const bare = try parseLibrary(a, "(kicad_symbol_lib (symbol \"X\" (in_bom yes)))");
    try testing.expectEqual(@as(usize, 0), bare.len);
}

// spec: export_kicad_sch - A sub-symbol name yields its unit and body-style numbers only when it really carries them
test "kicad-sym: unitId reads the trailing unit and style numbers" {
    try testing.expectEqual(@as(u32, 1), unitId("ADAR2001ACCZ_1_1").?.unit);
    try testing.expectEqual(@as(u32, 1), unitId("ADAR2001ACCZ_1_1").?.style);
    try testing.expectEqual(@as(u32, 2), unitId("CM4102008_2_0").?.unit);
    try testing.expectEqual(@as(u32, 0), unitId("TPSM84338RCJR_0_0").?.unit);
    // A part number that merely contains underscores is not a sub-symbol.
    try testing.expect(unitId("DF40C-100DS-0.4V_51_") == null);
    try testing.expect(unitId("PLAIN") == null);
    try testing.expect(unitId("A_B") == null);
}

const reader_fuzz_corpus = [_][]const u8{
    "",
    "(kicad_symbol_lib)",
    "(kicad_symbol_lib (symbol \"A\" (pin passive line (at 0 0 0) (length 2.54)" ++
        " (name \"x\" (effects)) (number \"1\" (effects)))))",
    "(kicad_symbol_lib (symbol \"A\" (symbol \"A_1_1\" (rectangle (start 0 0) (end 1 1)))))",
    "(kicad_symbol_lib (symbol",
    "((((",
    &[_]u8{ 0x28, 0x00, 0xff, 0x29 },
};

/// One fuzz iteration for the vendor-symbol reader: arbitrary bytes must never
/// crash — `parseLibrary` either returns symbols or a `ReadError`. Every
/// allocation lands in an arena that is unconditionally reclaimed, so the outer
/// `testing.allocator` stays leak-free wherever parsing bails out.
fn fuzzParseLibrary(allocator: std.mem.Allocator, smith: *testing.Smith) anyerror!void {
    var generated: [64 * 1024]u8 = undefined;
    const input = smith.in orelse generated[0..smith.slice(&generated)];
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = parseLibrary(arena.allocator(), input) catch return;
}

// spec: export_kicad_sch - Fuzzing the vendor symbol reader with arbitrary bytes never crashes
test "fuzz: parseLibrary tolerates arbitrary bytes" {
    try testing.fuzz(testing.allocator, fuzzParseLibrary, .{ .corpus = &reader_fuzz_corpus });
}
