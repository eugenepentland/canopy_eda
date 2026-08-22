//! Approximate text extents on an emitted sheet, and the pairs that collide.
//!
//! A schematic goes unreadable long before it goes wrong. Fifteen ground
//! symbols in a row print `GNDGNDGNDGND…`; a pin name drawn into a body its
//! opposite edge also draws into is text soup. Neither is a structural fault —
//! KiCad loads such a sheet and exports a perfect netlist from it — so the
//! exporter's self-check must not FAIL on one. What it can do is count them, and
//! a number that only goes down is what keeps a placement change honest.
//!
//! Every box here is an approximation and is documented as one:
//!
//!   * a character advances one font size, measured off KiCad 10.0.1's own
//!     rendering (`VDDCORE` at 1.27 mm plots 8.85 mm, i.e. 0.996 per character);
//!     `M` is 1.16 and `I` is 0.49, so a run of either is mis-measured;
//!   * a line is one font size tall, which ignores descenders;
//!   * a global label's text starts 1.125 sizes past its anchor, the arrow head
//!     KiCad draws between the connection point and the first glyph.
//!
//! So the count is a *smell*, never a verdict — which is exactly why it is a
//! warning channel and not an error.
//!
//! The geometry it does model exactly is orientation. KiCad draws every text in
//! one of two orientations — reading rightward, or reading upward — and places
//! the string relative to its anchor by justification, so a 180-degree label and
//! a right-justified one occupy the same box. Pin names run from the body end of
//! their pin inward by the symbol's name offset; pin numbers straddle the pin's
//! midpoint one notch to its reading-left. A field on a quarter-turned symbol is
//! drawn at the other orientation than it is stored at, which is why a
//! decoupling bank's members write theirs at 90 degrees to come out horizontal.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const numeric = @import("../numeric.zig");

const Node = ast.Node;

/// Overlap on BOTH axes must exceed this before a pair is reported, in
/// hundredths of a millimetre. Two boxes that merely touch — a caption resting
/// on the line below it — are not a collision, and the extents are estimates
/// anyway.
const tolerance: i64 = 10;

/// Gap between a global label's connection point and its first glyph, as
/// eighths of the font size (measured: 1.4288 mm at size 1.27).
const label_lead_num: i64 = 9;
const label_lead_den: i64 = 8;

/// Gap between a pin's own line and the pin-number text beside it, as fifths of
/// the font size (measured: 0.254 mm at size 1.27).
const number_gap_num: i64 = 1;
const number_gap_den: i64 = 5;

/// An axis-aligned box in hundredths of a millimetre, sheet coordinates.
pub const Box = struct { x0: i64, y0: i64, x1: i64, y1: i64 };

/// What a piece of drawn text is, so a report can say which surface collided.
pub const Kind = enum { caption, label, field, pin_name, pin_number };

/// One drawn text at its final place on the sheet.
pub const Item = struct {
    box: Box,
    kind: Kind,
    text: []const u8,
};

/// One collision, named by both parties and placed, so the log line is enough
/// to find it on the sheet.
pub const Pair = struct {
    a: []const u8,
    b: []const u8,
    kind_a: Kind,
    kind_b: Kind,
    /// Top-left of the overlap, in hundredths of a millimetre.
    x: i64 = 0,
    y: i64 = 0,
};

/// What one sheet's text looks like: how much of it there is, how many pairs of
/// it collide, and the first collision as an example.
pub const Report = struct {
    texts: usize = 0,
    overlaps: usize = 0,
    first: ?Pair = null,
};

/// Errors the scan can raise. It never rejects a document: an unreadable form is
/// simply text it does not measure.
pub const ScanError = std.mem.Allocator.Error;

/// Measure every text on an emitted sheet and count the overlapping pairs.
pub fn scan(arena: std.mem.Allocator, root: Node) ScanError!Report {
    var items: std.ArrayList(Item) = .empty;
    var libs: Libraries = .{};
    const cl = root.asList() orelse return .{};
    for (cl[1..]) |child| {
        if (child.isForm("lib_symbols")) try readLibSymbols(arena, child, &libs);
    }
    for (cl[1..]) |child| try readTop(arena, child, &libs, &items);
    return overlapsOf(items.items);
}

/// Reading direction of a text on the sheet. KiCad draws only these two
/// orientations; a text that reads the other way along an axis is the same box
/// with its justification flipped, which `place` does before building the box.
const Axis = enum { horizontal, vertical };

/// Where a string sits relative to its anchor, before orientation is applied.
/// `u` runs along the reading direction and `v` down across it.
const Span = struct { u0: i64, u1: i64, v0: i64, v1: i64 };

/// Everything needed to turn one string into a box.
const Placement = struct {
    x: i64,
    y: i64,
    /// Direction the text reads in, as a KiCad angle: 0 rightward, 90 up, 180
    /// leftward, 270 down.
    dir: u32,
    /// Advance of the whole string and the height of its line.
    w: i64,
    h: i64,
    /// Offset before the first glyph, along the reading direction.
    lead: i64 = 0,
    /// Which end of the string the anchor names.
    just: enum { start, middle, end } = .start,
    /// Where the anchor sits across the reading direction.
    cross: enum { center, above, below } = .center,
};

fn boxOf(p: Placement) Box {
    var span = Span{
        .u0 = switch (p.just) {
            .start => p.lead,
            .middle => -@divTrunc(p.w, 2),
            .end => -p.lead - p.w,
        },
        .u1 = 0,
        .v0 = switch (p.cross) {
            .center => -@divTrunc(p.h, 2),
            .above => -p.h - numberGap(p.h),
            .below => 0,
        },
        .v1 = 0,
    };
    span.u1 = span.u0 + p.w;
    span.v1 = span.v0 + p.h;
    // KiCad reads rightward or upward and never the other way, so a leftward or
    // downward string is the same box mirrored along its own axis.
    if (p.dir == 180 or p.dir == 270) {
        const start = span.u0;
        span.u0 = -span.u1;
        span.u1 = -start;
    }
    if (p.dir == 90 or p.dir == 270) {
        return .{ .x0 = p.x + span.v0, .y0 = p.y - span.u1, .x1 = p.x + span.v1, .y1 = p.y - span.u0 };
    }
    return .{ .x0 = p.x + span.u0, .y0 = p.y + span.v0, .x1 = p.x + span.u1, .y1 = p.y + span.v1 };
}

fn numberGap(h: i64) i64 {
    return @divTrunc(h * number_gap_num, number_gap_den);
}

fn labelLead(h: i64) i64 {
    return @divTrunc(h * label_lead_num, label_lead_den);
}

/// String advance: one font size per character. Counted in UTF-8 code points, so
/// a caption's em dash costs one character rather than three.
fn advance(text: []const u8, size: i64) i64 {
    var chars: i64 = 0;
    for (text) |c| {
        if ((c & 0xC0) != 0x80) chars += 1;
    }
    return chars * size;
}

/// The pairs of boxes that overlap. Sorted by left edge, so the sweep can stop
/// as soon as the next box starts past the current one's right edge.
fn overlapsOf(items: []Item) Report {
    std.mem.sort(Item, items, {}, leftOf);
    var out = Report{ .texts = items.len };
    for (items, 0..) |a, i| {
        for (items[i + 1 ..]) |b| {
            if (b.box.x0 >= a.box.x1 - tolerance) break;
            if (!hits(a.box, b.box)) continue;
            out.overlaps += 1;
            if (out.first == null) {
                out.first = .{
                    .a = a.text,
                    .b = b.text,
                    .kind_a = a.kind,
                    .kind_b = b.kind,
                    .x = @max(a.box.x0, b.box.x0),
                    .y = @max(a.box.y0, b.box.y0),
                };
            }
        }
    }
    return out;
}

fn leftOf(_: void, a: Item, b: Item) bool {
    if (a.box.x0 != b.box.x0) return a.box.x0 < b.box.x0;
    return a.box.y0 < b.box.y0;
}

fn hits(a: Box, b: Box) bool {
    if (@min(a.x1, b.x1) - @max(a.x0, b.x0) <= tolerance) return false;
    return @min(a.y1, b.y1) - @max(a.y0, b.y0) > tolerance;
}

// ── Reading the emitted document ───────────────────────────────────────

/// One library pin, in library coordinates (y-UP about the symbol origin).
const LibPin = struct {
    unit: u32,
    x: i64,
    y: i64,
    /// KiCad pin angle: the direction from the connection point toward the body.
    angle: u32,
    len: i64,
    name: []const u8,
    name_size: i64,
    number: []const u8,
    number_size: i64,
};

/// One library entry: whether it draws its pins' names and numbers at all, how
/// far inside the body a name starts, and the pins themselves.
const LibSymbol = struct {
    name: []const u8,
    show_names: bool = true,
    show_numbers: bool = true,
    name_offset: i64 = 0,
    pins: std.ArrayList(LibPin) = .empty,
};

const Libraries = struct {
    entries: std.ArrayList(LibSymbol) = .empty,

    fn find(self: *const Libraries, id: []const u8) ?*const LibSymbol {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.name, id)) return e;
        }
        return null;
    }
};

fn readLibSymbols(arena: std.mem.Allocator, node: Node, libs: *Libraries) ScanError!void {
    const cl = node.asList() orelse return;
    for (cl[1..]) |sym| {
        if (!sym.isForm("symbol")) continue;
        const sl = sym.asList() orelse continue;
        if (sl.len < 2) continue;
        var entry = LibSymbol{ .name = sl[1].asText() orelse continue };
        readPinPolicy(sym, &entry);
        for (sl[2..]) |sub| try readLibUnit(arena, sub, &entry);
        try libs.entries.append(arena, entry);
    }
}

/// `(pin_names (offset X) (hide yes))` / `(pin_numbers (hide yes))` — a stock
/// passive glyph switches both off, and a rail symbol switches names off.
fn readPinPolicy(sym: Node, entry: *LibSymbol) void {
    const cl = sym.asList() orelse return;
    for (cl[1..]) |child| {
        if (child.isForm("pin_numbers")) entry.show_numbers = !hidden(child);
        if (!child.isForm("pin_names")) continue;
        entry.show_names = !hidden(child);
        entry.name_offset = numberChild(child, "offset") orelse 0;
    }
}

fn readLibUnit(arena: std.mem.Allocator, sub: Node, entry: *LibSymbol) ScanError!void {
    if (!sub.isForm("symbol")) return;
    const l = sub.asList() orelse return;
    if (l.len < 2) return;
    const unit = subUnit(l[1].asText() orelse "") orelse return;
    for (l[2..]) |item| {
        if (!item.isForm("pin")) continue;
        try entry.pins.append(arena, readLibPin(item, unit) orelse continue);
    }
}

fn readLibPin(item: Node, unit: u32) ?LibPin {
    const at = atForm(item) orelse return null;
    const name = namedText(item, "name");
    const number = namedText(item, "number");
    return .{
        .unit = unit,
        .x = coord(at[1]) orelse return null,
        .y = coord(at[2]) orelse return null,
        .angle = angleAt(at),
        .len = numberChild(item, "length") orelse 0,
        .name = name.text,
        .name_size = name.size,
        .number = number.text,
        .number_size = number.size,
    };
}

/// A `(name "…" (effects …))` / `(number "…" (effects …))` pair: the string and
/// the size it is drawn at. A zero size is KiCad's own way of hiding one pin's
/// text while the library still carries the name — the spelling `(hide yes)`
/// inside a pin's effects is accepted by the parser and then ignored by the
/// renderer, which is why the exporter zeroes the size instead.
const NamedText = struct { text: []const u8 = "", size: i64 = 0 };

fn namedText(item: Node, form: []const u8) NamedText {
    const cl = item.asList() orelse return .{};
    for (cl[1..]) |child| {
        if (!child.isForm(form)) continue;
        const l = child.asList() orelse continue;
        if (l.len < 2) continue;
        return .{ .text = l[1].asText() orelse "", .size = fontSize(child) };
    }
    return .{};
}

/// Font height of a form's `(effects (font (size W H)))`, or zero when it has
/// none — which reads as "not drawn", the same as an explicit zero size.
fn fontSize(node: Node) i64 {
    const cl = node.asList() orelse return 0;
    for (cl[1..]) |child| {
        if (!child.isForm("effects")) continue;
        if (hidden(child)) return 0;
        const el = child.asList() orelse continue;
        for (el[1..]) |f| {
            if (!f.isForm("font")) continue;
            return numberChild(f, "size") orelse 0;
        }
    }
    return 0;
}

fn readTop(
    arena: std.mem.Allocator,
    node: Node,
    libs: *const Libraries,
    items: *std.ArrayList(Item),
) ScanError!void {
    if (node.isForm("text")) return appendCaption(arena, node, items);
    if (node.isForm("global_label")) return appendLabel(arena, node, items);
    if (node.isForm("symbol")) return appendSymbol(arena, node, libs, items);
}

fn appendCaption(arena: std.mem.Allocator, node: Node, items: *std.ArrayList(Item)) ScanError!void {
    const cl = node.asList() orelse return;
    if (cl.len < 2) return;
    const text = cl[1].asText() orelse return;
    const at = atForm(node) orelse return;
    const size = fontSize(node);
    if (size == 0) return;
    try items.append(arena, .{
        .kind = .caption,
        .text = text,
        .box = boxOf(.{
            .x = coord(at[1]) orelse return,
            .y = coord(at[2]) orelse return,
            .dir = angleAt(at),
            .w = advance(text, size),
            .h = size,
            .cross = .above,
        }),
    });
}

fn appendLabel(arena: std.mem.Allocator, node: Node, items: *std.ArrayList(Item)) ScanError!void {
    const cl = node.asList() orelse return;
    if (cl.len < 2) return;
    const text = cl[1].asText() orelse return;
    const at = atForm(node) orelse return;
    const size = fontSize(node);
    if (size == 0) return;
    try items.append(arena, .{
        .kind = .label,
        .text = text,
        .box = boxOf(.{
            .x = coord(at[1]) orelse return,
            .y = coord(at[2]) orelse return,
            .dir = angleAt(at),
            .w = advance(text, size),
            .h = size,
            .lead = labelLead(size),
        }),
    });
}

/// One placed symbol: its visible property fields, plus every pin text its
/// library entry draws, moved and turned onto the sheet.
fn appendSymbol(
    arena: std.mem.Allocator,
    node: Node,
    libs: *const Libraries,
    items: *std.ArrayList(Item),
) ScanError!void {
    const at = atForm(node) orelse return;
    const origin = Pose{
        .x = coord(at[1]) orelse return,
        .y = coord(at[2]) orelse return,
        .angle = angleAt(at),
    };
    try appendFields(arena, node, origin, items);
    const id = formText(node, "lib_id") orelse return;
    const entry = libs.find(id) orelse return;
    const unit = unitOf(node);
    for (entry.pins.items) |pin| {
        if (pin.unit != unit and pin.unit != 0) continue;
        try appendPinTexts(arena, entry, pin, origin, items);
    }
}

/// Where a placed symbol sits and how it is turned.
const Pose = struct { x: i64, y: i64, angle: u32 };

fn appendFields(
    arena: std.mem.Allocator,
    node: Node,
    origin: Pose,
    items: *std.ArrayList(Item),
) ScanError!void {
    const cl = node.asList() orelse return;
    for (cl[1..]) |child| {
        if (!child.isForm("property")) continue;
        if (hidden(child)) continue;
        const l = child.asList() orelse continue;
        if (l.len < 3) continue;
        const text = l[2].asText() orelse continue;
        if (text.len == 0) continue;
        const size = fontSize(child);
        if (size == 0) continue;
        const at = atForm(child) orelse continue;
        try items.append(arena, .{
            .kind = .field,
            .text = text,
            .box = boxOf(.{
                .x = coord(at[1]) orelse continue,
                .y = coord(at[2]) orelse continue,
                // KiCad swaps a field's orientation when its parent symbol is
                // quarter-turned, so a bank member's field is stored at 90 to
                // come out horizontal.
                .dir = drawnFieldAngle(angleAt(at), origin.angle),
                .w = advance(text, size),
                .h = size,
                .just = if (justifiedLeft(child)) .start else .middle,
            }),
        });
    }
}

/// The orientation a field is DRAWN at: its own angle, turned a further quarter
/// when the symbol carrying it is quarter-turned.
fn drawnFieldAngle(field: u32, parent: u32) u32 {
    if (parent == 90 or parent == 270) return (field + 270) % 360;
    return field;
}

fn appendPinTexts(
    arena: std.mem.Allocator,
    entry: *const LibSymbol,
    pin: LibPin,
    origin: Pose,
    items: *std.ArrayList(Item),
) ScanError!void {
    const at = onSheet(pin.x, pin.y, origin);
    const dir = (pin.angle + origin.angle) % 360;
    const body = along(at, dir, pin.len);
    if (entry.show_names and pin.name_size > 0 and pin.name.len > 0) {
        try items.append(arena, .{
            .kind = .pin_name,
            .text = pin.name,
            .box = boxOf(.{
                .x = body.x,
                .y = body.y,
                .dir = dir,
                .w = advance(pin.name, pin.name_size),
                .h = pin.name_size,
                .lead = entry.name_offset,
            }),
        });
    }
    if (!entry.show_numbers or pin.number_size == 0 or pin.number.len == 0) return;
    const mid = along(at, dir, @divTrunc(pin.len, 2));
    try items.append(arena, .{
        .kind = .pin_number,
        .text = pin.number,
        .box = boxOf(.{
            .x = mid.x,
            .y = mid.y,
            .dir = dir,
            .w = advance(pin.number, pin.number_size),
            .h = pin.number_size,
            .just = .middle,
            .cross = .above,
        }),
    });
}

/// A library point placed on the sheet: turned by the symbol's angle in the
/// library's y-UP frame, then dropped into the sheet's y-DOWN one.
fn onSheet(x: i64, y: i64, origin: Pose) Sheet2 {
    const r = turn(x, y, origin.angle);
    return .{ .x = origin.x + r[0], .y = origin.y - r[1] };
}

const Sheet2 = struct { x: i64, y: i64 };

fn turn(x: i64, y: i64, angle: u32) [2]i64 {
    return switch (angle % 360) {
        90 => .{ -y, x },
        180 => .{ -x, -y },
        270 => .{ y, -x },
        else => .{ x, y },
    };
}

/// A point `d` along a KiCad direction from `p`, in sheet coordinates. Library
/// angles are y-UP, so 90 degrees runs UP the page.
fn along(p: Sheet2, dir: u32, d: i64) Sheet2 {
    return switch (dir % 360) {
        90 => .{ .x = p.x, .y = p.y - d },
        180 => .{ .x = p.x - d, .y = p.y },
        270 => .{ .x = p.x, .y = p.y + d },
        else => .{ .x = p.x + d, .y = p.y },
    };
}

// ── Small s-expression readers ─────────────────────────────────────────

fn coord(node: Node) ?i64 {
    const v = node.asNumber() orelse return null;
    return numeric.checkedInt(i64, @round(v * 100.0));
}

fn atForm(node: Node) ?[]const Node {
    const cl = node.asList() orelse return null;
    for (cl[1..]) |child| {
        if (!child.isForm("at")) continue;
        const l = child.asList() orelse continue;
        if (l.len >= 3) return l;
    }
    return null;
}

fn angleAt(at: []const Node) u32 {
    if (at.len < 4) return 0;
    const deg = numeric.checkedInt(i64, @round(at[3].asNumber() orelse 0)) orelse return 0;
    return @intCast(@mod(deg, 360));
}

/// The first numeric argument of a named child form, in hundredths.
fn numberChild(node: Node, form: []const u8) ?i64 {
    const cl = node.asList() orelse return null;
    for (cl[1..]) |child| {
        if (!child.isForm(form)) continue;
        const l = child.asList() orelse continue;
        if (l.len < 2) continue;
        return coord(l[1]);
    }
    return null;
}

fn formText(node: Node, form: []const u8) ?[]const u8 {
    const cl = node.asList() orelse return null;
    for (cl[1..]) |child| {
        if (!child.isForm(form)) continue;
        const l = child.asList() orelse continue;
        if (l.len < 2) continue;
        return l[1].asText();
    }
    return null;
}

/// True when a form carries `(hide yes)` — on a property, or inside an effects
/// block.
fn hidden(node: Node) bool {
    const cl = node.asList() orelse return false;
    for (cl[1..]) |child| {
        if (!child.isForm("hide")) continue;
        const l = child.asList() orelse continue;
        if (l.len < 2) continue;
        return std.mem.eql(u8, l[1].asAtom() orelse "", "yes");
    }
    return false;
}

fn justifiedLeft(node: Node) bool {
    const cl = node.asList() orelse return false;
    for (cl[1..]) |child| {
        if (!child.isForm("effects")) continue;
        const el = child.asList() orelse continue;
        for (el[1..]) |j| {
            if (!j.isForm("justify")) continue;
            const jl = j.asList() orelse continue;
            for (jl[1..]) |word| {
                if (std.mem.eql(u8, word.asAtom() orelse "", "left")) return true;
            }
        }
    }
    return false;
}

fn unitOf(node: Node) u32 {
    const cl = node.asList() orelse return 1;
    for (cl[1..]) |child| {
        if (!child.isForm("unit")) continue;
        const l = child.asList() orelse continue;
        if (l.len < 2) continue;
        const n = numeric.checkedInt(i64, @round(l[1].asNumber() orelse 1)) orelse return 1;
        return @intCast(@max(n, 0));
    }
    return 1;
}

/// Unit number of a `<NAME>_<unit>_<style>` sub-symbol; null when the name does
/// not carry one.
fn subUnit(name: []const u8) ?u32 {
    const style = std.mem.lastIndexOfScalar(u8, name, '_') orelse return null;
    const unit = std.mem.lastIndexOfScalar(u8, name[0..style], '_') orelse return null;
    return std.fmt.parseInt(u32, name[unit + 1 .. style], 10) catch null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const parser = @import("../sexpr/parser.zig");

fn scanText(a: std.mem.Allocator, src: []const u8) !Report {
    const nodes = try parser.parse(a, src);
    return scan(a, nodes[0]);
}

// spec: export_kicad_sch - The text scan boxes a caption from its anchor and reports a clean sheet as having no overlaps
test "kicad-sch: text boxes follow justification and orientation" {
    // Reading rightward from the anchor, sitting above it.
    const right = boxOf(.{ .x = 0, .y = 0, .dir = 0, .w = 400, .h = 100, .cross = .below });
    try testing.expectEqual(@as(i64, 0), right.x0);
    try testing.expectEqual(@as(i64, 400), right.x1);
    try testing.expectEqual(@as(i64, 0), right.y0);
    try testing.expectEqual(@as(i64, 100), right.y1);

    // The same string reading leftward occupies the mirrored box.
    const left = boxOf(.{ .x = 0, .y = 0, .dir = 180, .w = 400, .h = 100, .cross = .below });
    try testing.expectEqual(@as(i64, -400), left.x0);
    try testing.expectEqual(@as(i64, 0), left.x1);

    // Upward: the advance runs along -y and the line height across x.
    const up = boxOf(.{ .x = 0, .y = 0, .dir = 90, .w = 400, .h = 100 });
    try testing.expectEqual(@as(i64, -400), up.y0);
    try testing.expectEqual(@as(i64, 0), up.y1);
    try testing.expectEqual(@as(i64, -50), up.x0);
    try testing.expectEqual(@as(i64, 50), up.x1);

    // Downward is that box mirrored, not a different shape.
    const down = boxOf(.{ .x = 0, .y = 0, .dir = 270, .w = 400, .h = 100 });
    try testing.expectEqual(@as(i64, 0), down.y0);
    try testing.expectEqual(@as(i64, 400), down.y1);
}

// spec: export_kicad_sch - The text scan reports a pair of overlapping labels and stays silent on a sheet whose texts clear each other
test "kicad-sch: the scan finds an overlapping label pair and clears a tidy sheet" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Two ground symbols one grid step apart print their values over each other.
    const clash =
        \\(kicad_sch
        \\  (lib_symbols)
        \\  (global_label "VDD3V3" (at 50 50 0) (effects (font (size 1.27 1.27)) (justify left)))
        \\  (global_label "VDD3V3" (at 50 50.5 0) (effects (font (size 1.27 1.27)) (justify left)))
        \\)
    ;
    const hit = try scanText(a, clash);
    try testing.expectEqual(@as(usize, 2), hit.texts);
    try testing.expectEqual(@as(usize, 1), hit.overlaps);
    try testing.expectEqualStrings("VDD3V3", hit.first.?.a);
    try testing.expectEqual(Kind.label, hit.first.?.kind_a);

    // The same pair a full line apart is exactly what a readable sheet looks
    // like, and must not be reported.
    const clear = try std.mem.replaceOwned(u8, a, clash, "(at 50 50.5 0)", "(at 50 55 0)");
    const ok = try scanText(a, clear);
    try testing.expectEqual(@as(usize, 2), ok.texts);
    try testing.expectEqual(@as(usize, 0), ok.overlaps);
    try testing.expect(ok.first == null);
}

// spec: export_kicad_sch - A pin whose name is drawn at zero size contributes no text to the overlap scan
test "kicad-sch: a zero-size pin name is not measured while its number still is" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const doc =
        \\(kicad_sch
        \\  (lib_symbols
        \\    (symbol "netlisp:BOX"
        \\      (pin_names (offset 0.254))
        \\      (symbol "BOX_1_1"
        \\        (pin passive line (at -15.24 0 0) (length 2.54)
        \\          (name "VSSAPM_U" (effects (font (size 1.27 1.27))))
        \\          (number "H14" (effects (font (size 1.27 1.27))))))))
        \\  (symbol (lib_id "netlisp:BOX") (at 63.5 38.1 0) (unit 1))
        \\)
    ;
    const shown = try scanText(a, doc);
    try testing.expectEqual(@as(usize, 2), shown.texts);

    // Zeroing the name's font is how the exporter hides a ganged pin's name;
    // the pad number beside it must still be measured.
    const drawn = "(name \"VSSAPM_U\" (effects (font (size 1.27 1.27))))";
    const muted = "(name \"VSSAPM_U\" (effects (font (size 0 0))))";
    const quiet = try std.mem.replaceOwned(u8, a, doc, drawn, muted);
    const after = try scanText(a, quiet);
    try testing.expectEqual(@as(usize, 1), after.texts);
    try testing.expectEqual(@as(usize, 0), after.overlaps);
}
