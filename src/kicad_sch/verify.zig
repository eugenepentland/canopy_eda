//! Structural self-check for emitted `.kicad_sch` bytes.
//!
//! The exporter re-parses what it just wrote and proves the invariants that a
//! silent KiCad failure would otherwise hide. KiCad *accepts* a schematic whose
//! `lib_symbols` entry is missing, whose pad numbers repeat inside one symbol,
//! or whose endpoints are off-grid — it just exports a wrong netlist, or buries
//! the file in ERC noise. A root sheet that links a child file it never wrote
//! is the hierarchical version of the same trap. Every one of those is caught
//! here, before the bytes reach disk.
//!
//! Drawn wires add a second family of traps, so the scan re-derives the whole
//! drawing from the bytes rather than trusting what the router believed: every
//! wire must be axis-aligned and on the grid, no wire may touch a pin anywhere
//! but at its own endpoint (a pin in a wire's *interior* does not connect — it
//! reports `pin_not_connected` — so such a wire draws a connection the netlist
//! does not have), and a point where three or more wire ends meet must carry
//! its junction dot. Pin positions here come from the emitted `lib_symbols`
//! geometry and the placed symbols that reference it, independent of the
//! exporter's own bookkeeping.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser = @import("../sexpr/parser.zig");
const numeric = @import("../numeric.zig");
const textbox = @import("textbox.zig");

const Node = ast.Node;
const grid_hundredths: i64 = 127;
const power_ref_prefix = "#PWR";
/// Half the coordinate range `key` can pack, in hundredths of a millimetre —
/// far beyond the largest page KiCad will load.
const coord_offset: i64 = 1 << 20;

/// What the caller believes it emitted. Every field is compared against the
/// re-parsed document, so a drop anywhere between intent and bytes is fatal.
pub const Expect = struct {
    /// One instance UUID per placed symbol, in emission order (power symbols
    /// included).
    uuids: []const []const u8,
    /// One `netlisp:<name>` lib_id per placed symbol, in emission order.
    lib_ids: []const []const u8,
    /// The net name carried by each label-connected pin (a multiset — a net
    /// with three pins on this sheet appears three times).
    labels: []const []const u8,
    /// The net named by each placed `#PWR…` rail symbol (also a multiset).
    rail_values: []const []const u8,
    /// How many pads were left unconnected and must carry a no-connect flag.
    no_connects: usize,
    /// `Sheetfile` of each child sheet this document links to, in order.
    sheets: []const []const u8 = &.{},
    /// Every `(wire …)` segment the sheet draws: the per-pin stubs, the routed
    /// connections, and the one under each PWR_FLAG.
    wires: usize = 0,
};

/// Ways the emitted document can fail its own contract.
pub const VerifyError = error{
    NotSchematic,
    SymbolCountMismatch,
    SymbolUuidMismatch,
    UnknownLibId,
    DuplicatePad,
    LabelCountMismatch,
    MissingNetLabel,
    NoConnectCountMismatch,
    SheetLinkMismatch,
    OffGrid,
    WireCountMismatch,
    WireNotOrthogonal,
    WireThroughPin,
    LabelOnWireInterior,
    MissingJunction,
    StrayJunction,
} || std.mem.Allocator.Error || parser.ParseError;

/// A point in hundredths of a millimetre — the unit the emitter writes.
const Pt = struct { x: i64, y: i64 };

/// One emitted wire segment.
const Seg = struct { a: Pt, b: Pt };

/// One library pin: the entry and unit it belongs to, and its connection
/// endpoint in library coordinates (y-UP about the symbol origin).
const LibPin = struct { lib: []const u8, unit: u32, at: Pt };

/// One placed symbol: the library entry it draws, its unit, its origin on the
/// sheet, and its rotation.
const Placed = struct { lib: []const u8, unit: u32, at: Pt, angle: u32 };

/// The drawing as the re-parsed document actually spells it, from which the
/// wire invariants are re-derived.
const Geometry = struct {
    segs: std.ArrayList(Seg) = .empty,
    dots: std.ArrayList(Pt) = .empty,
    placed: std.ArrayList(Placed) = .empty,
    lib_pins: std.ArrayList(LibPin) = .empty,
    /// Where each global label attaches. KiCad joins a label to any wire whose
    /// geometry passes through its anchor, interior included, so a label caught
    /// mid-span silently merges two nets.
    label_pts: std.ArrayList(Pt) = .empty,
};

/// Counts and identities pulled back out of the emitted bytes.
const Found = struct {
    lib_names: std.StringHashMapUnmanaged(void) = .empty,
    uuids: std.ArrayList([]const u8) = .empty,
    lib_ids: std.ArrayList([]const u8) = .empty,
    labels: Multiset = .{},
    rail_values: Multiset = .{},
    sheets: std.ArrayList([]const u8) = .empty,
    no_connects: usize = 0,
    geom: Geometry = .{},
};

/// A counted set of strings, so a dropped or duplicated label is caught rather
/// than merely a missing name.
const Multiset = struct {
    counts: std.StringHashMapUnmanaged(u32) = .empty,
    total: usize = 0,

    fn add(self: *Multiset, arena: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!void {
        const gop = try self.counts.getOrPut(arena, key);
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        self.total += 1;
    }
};

/// Re-parse `bytes` and assert they say what the exporter meant to say.
/// Allocations come from `arena`; the caller keeps the bytes.
///
/// The returned report is the sheet's READABILITY, which is deliberately not
/// part of the contract above: overlapping text is a smell measured from
/// approximate extents (`kicad_sch/textbox.zig`), and a document KiCad reads
/// perfectly must never be refused over an estimate. The caller warns on it.
pub fn check(arena: std.mem.Allocator, bytes: []const u8, want: Expect) VerifyError!textbox.Report {
    const nodes = try parser.parse(arena, bytes);
    if (nodes.len == 0 or !nodes[0].isForm("kicad_sch")) return error.NotSchematic;
    const root = nodes[0].asList() orelse return error.NotSchematic;

    try gridScan(nodes[0]);

    var found = Found{};
    for (root[1..]) |child| try scanTop(arena, child, &found);

    if (found.uuids.items.len != want.uuids.len) return error.SymbolCountMismatch;
    if (found.lib_ids.items.len != want.lib_ids.len) return error.SymbolCountMismatch;
    for (found.uuids.items, want.uuids) |got, expected| {
        if (!std.mem.eql(u8, got, expected)) return error.SymbolUuidMismatch;
    }
    for (found.lib_ids.items, want.lib_ids) |got, expected| {
        if (!std.mem.eql(u8, got, expected)) return error.UnknownLibId;
        if (!found.lib_names.contains(got)) return error.UnknownLibId;
    }
    if (found.no_connects != want.no_connects) return error.NoConnectCountMismatch;
    try checkSheets(&found, want);
    try compare(arena, &found.labels, want.labels);
    try compare(arena, &found.rail_values, want.rail_values);
    try checkWires(arena, &found.geom, want);
    return textbox.scan(arena, nodes[0]);
}

/// The drawn wire, re-derived from the bytes: the segments say what they were
/// meant to say, none of them runs across a pin, and every three-way meeting
/// carries its dot.
fn checkWires(arena: std.mem.Allocator, g: *Geometry, want: Expect) VerifyError!void {
    if (g.segs.items.len != want.wires) return error.WireCountMismatch;
    try checkOrthogonal(g.segs.items);
    try checkPinTouch(g.segs.items, try pinPoints(arena, g));
    try checkLabelTouch(g.segs.items, g.label_pts.items);
    try checkJunctions(arena, g);
}

/// A diagonal or zero-length wire is not something KiCad's connectivity or a
/// reader can make sense of.
fn checkOrthogonal(segs: []const Seg) VerifyError!void {
    for (segs) |s| {
        if (s.a.x == s.b.x and s.a.y == s.b.y) return error.WireNotOrthogonal;
        if (s.a.x != s.b.x and s.a.y != s.b.y) return error.WireNotOrthogonal;
    }
}

/// A wire may coincide with a pin only at its own endpoint. Anywhere else the
/// pin stays unconnected in KiCad while the drawing claims otherwise — the one
/// way a drawn wire can silently disagree with the netlist.
fn checkPinTouch(segs: []const Seg, pins: []const Pt) VerifyError!void {
    for (segs) |s| {
        for (pins) |p| {
            if (!onSeg(p, s)) continue;
            if (endOf(s, p)) continue;
            return error.WireThroughPin;
        }
    }
}

/// A global label may sit on a wire only at that wire's own end. Anywhere in
/// the interior KiCad attaches the label to the wire anyway, which pulls the
/// label's net into whatever the wire carries — the failure mode a same-net
/// gang's run along a symbol edge would cause if it spanned a foreign pin's
/// stub tip, and the reason `gang.zig` refuses such a run.
fn checkLabelTouch(segs: []const Seg, labels: []const Pt) VerifyError!void {
    for (segs) |s| {
        for (labels) |p| {
            if (!onSeg(p, s)) continue;
            if (endOf(s, p)) continue;
            return error.LabelOnWireInterior;
        }
    }
}

/// Three or more wire ends at one point is a connection a reader can only see
/// if the dot is drawn; a dot on fewer than two ends draws one that is not
/// there.
fn checkJunctions(arena: std.mem.Allocator, g: *Geometry) VerifyError!void {
    var ends: std.AutoHashMapUnmanaged(i64, u32) = .empty;
    defer ends.deinit(arena);
    for (g.segs.items) |s| {
        try tally(arena, &ends, s.a);
        try tally(arena, &ends, s.b);
    }
    var dots: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer dots.deinit(arena);
    for (g.dots.items) |p| {
        if ((ends.get(ptKey(p)) orelse 0) < 2) return error.StrayJunction;
        try dots.put(arena, ptKey(p), {});
    }
    var it = ends.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* < 3) continue;
        if (!dots.contains(e.key_ptr.*)) return error.MissingJunction;
    }
}

fn tally(
    arena: std.mem.Allocator,
    ends: *std.AutoHashMapUnmanaged(i64, u32),
    p: Pt,
) std.mem.Allocator.Error!void {
    const gop = try ends.getOrPut(arena, ptKey(p));
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
}

/// A collision-free key for a sheet point, packed by shifting both coordinates
/// onto a non-negative range wider than any page KiCad will load.
fn ptKey(p: Pt) i64 {
    return (p.x + coord_offset) * (2 * coord_offset) + (p.y + coord_offset);
}

/// Every pin connection point on the sheet, built from the emitted library
/// geometry and the symbols that place it — never from what the exporter
/// thought it drew.
fn pinPoints(arena: std.mem.Allocator, g: *Geometry) std.mem.Allocator.Error![]const Pt {
    var out: std.ArrayList(Pt) = .empty;
    for (g.placed.items) |s| {
        for (g.lib_pins.items) |lp| {
            if (!std.mem.eql(u8, lp.lib, s.lib)) continue;
            if (lp.unit != s.unit and lp.unit != 0) continue;
            const r = rotate(lp.at, s.angle);
            // Library coordinates are y-UP about the origin; the sheet is y-DOWN.
            try out.append(arena, .{ .x = s.at.x + r.x, .y = s.at.y - r.y });
        }
    }
    return out.items;
}

/// A library point turned by a placed symbol's angle, counter-clockwise in the
/// library's own y-up frame.
fn rotate(p: Pt, angle: u32) Pt {
    return switch (@mod(angle, 360)) {
        90 => .{ .x = -p.y, .y = p.x },
        180 => .{ .x = -p.x, .y = -p.y },
        270 => .{ .x = p.y, .y = -p.x },
        else => p,
    };
}

/// True when `p` lies on the closed, axis-aligned segment `s`.
fn onSeg(p: Pt, s: Seg) bool {
    if (p.x < @min(s.a.x, s.b.x) or p.x > @max(s.a.x, s.b.x)) return false;
    return p.y >= @min(s.a.y, s.b.y) and p.y <= @max(s.a.y, s.b.y);
}

fn endOf(s: Seg, p: Pt) bool {
    if (s.a.x == p.x and s.a.y == p.y) return true;
    return s.b.x == p.x and s.b.y == p.y;
}

/// A root sheet that links a child file the exporter is not writing would open
/// in KiCad as a broken hierarchy, so the link list must match exactly.
fn checkSheets(found: *Found, want: Expect) VerifyError!void {
    if (found.sheets.items.len != want.sheets.len) return error.SheetLinkMismatch;
    for (found.sheets.items, want.sheets) |got, expected| {
        if (!std.mem.eql(u8, got, expected)) return error.SheetLinkMismatch;
    }
}

/// The found multiset must match the expected one exactly — a dropped label is
/// a silently disconnected pin in KiCad, and a dropped rail symbol a silently
/// renamed net.
fn compare(arena: std.mem.Allocator, found: *Multiset, want: []const []const u8) VerifyError!void {
    if (found.total != want.len) return error.LabelCountMismatch;
    var expected: Multiset = .{};
    defer expected.counts.deinit(arena);
    for (want) |l| try expected.add(arena, l);
    if (expected.counts.count() != found.counts.count()) return error.LabelCountMismatch;
    var it = expected.counts.iterator();
    while (it.next()) |e| {
        const got = found.counts.get(e.key_ptr.*) orelse return error.MissingNetLabel;
        if (got != e.value_ptr.*) return error.LabelCountMismatch;
    }
}

/// Classify one top-level child of the document.
fn scanTop(arena: std.mem.Allocator, node: Node, found: *Found) VerifyError!void {
    if (node.isForm("lib_symbols")) return scanLibSymbols(arena, node, found);
    if (node.isForm("no_connect")) {
        found.no_connects += 1;
        return;
    }
    if (node.isForm("global_label")) return scanLabel(arena, node, found);
    if (node.isForm("symbol")) return scanPlaced(arena, node, found);
    if (node.isForm("sheet")) return scanSheet(arena, node, found);
    if (node.isForm("wire")) return scanWire(arena, node, found);
    if (node.isForm("junction")) return scanJunction(arena, node, found);
}

fn scanWire(arena: std.mem.Allocator, node: Node, found: *Found) VerifyError!void {
    const cl = node.asList() orelse return;
    for (cl[1..]) |child| {
        if (!child.isForm("pts")) continue;
        const l = child.asList() orelse continue;
        if (l.len < 3) continue;
        const a = xyOf(l[1]) orelse continue;
        const b = xyOf(l[2]) orelse continue;
        try found.geom.segs.append(arena, .{ .a = a, .b = b });
    }
}

fn scanJunction(arena: std.mem.Allocator, node: Node, found: *Found) VerifyError!void {
    try found.geom.dots.append(arena, pointOf(node) orelse return);
}

/// A coordinate in hundredths of a millimetre. Null when the node is not a
/// number the emitter could have written.
fn coord(node: Node) ?i64 {
    const v = node.asNumber() orelse return null;
    return numeric.checkedInt(i64, @round(v * 100.0));
}

fn xyOf(node: Node) ?Pt {
    if (!node.isForm("xy")) return null;
    const l = node.asList() orelse return null;
    if (l.len < 3) return null;
    return .{ .x = coord(l[1]) orelse return null, .y = coord(l[2]) orelse return null };
}

/// The direct `(at X Y …)` child of a form, when it has one with a position.
fn atForm(node: Node) ?[]const Node {
    const cl = node.asList() orelse return null;
    for (cl[1..]) |child| {
        if (!child.isForm("at")) continue;
        const l = child.asList() orelse continue;
        if (l.len >= 3) return l;
    }
    return null;
}

fn pointOf(node: Node) ?Pt {
    const l = atForm(node) orelse return null;
    return .{ .x = coord(l[1]) orelse return null, .y = coord(l[2]) orelse return null };
}

fn angleOf(node: Node) u32 {
    const l = atForm(node) orelse return 0;
    if (l.len < 4) return 0;
    const deg = numeric.checkedInt(i64, @round(l[3].asNumber() orelse 0)) orelse return 0;
    return @intCast(@mod(deg, 360));
}

/// The `(unit N)` a placed symbol draws; 1 when it names none.
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

fn scanLabel(arena: std.mem.Allocator, node: Node, found: *Found) VerifyError!void {
    const cl = node.asList() orelse return;
    if (cl.len < 2) return;
    try found.labels.add(arena, cl[1].asText() orelse return);
    if (pointOf(node)) |at| try found.geom.label_pts.append(arena, at);
}

fn scanSheet(arena: std.mem.Allocator, node: Node, found: *Found) VerifyError!void {
    const file = property(node, "Sheetfile") orelse return;
    try found.sheets.append(arena, file);
}

/// The value of a named `(property "NAME" "VALUE" …)` on a symbol or sheet.
fn property(node: Node, name: []const u8) ?[]const u8 {
    const cl = node.asList() orelse return null;
    for (cl[1..]) |child| {
        if (!child.isForm("property")) continue;
        const l = child.asList() orelse continue;
        if (l.len < 3) continue;
        if (!std.mem.eql(u8, l[1].asText() orelse "", name)) continue;
        return l[2].asText();
    }
    return null;
}

/// Record every library symbol's name and prove its pad numbers are unique —
/// a repeated pad number splits that pad's net in KiCad's exported netlist
/// without any diagnostic.
fn scanLibSymbols(arena: std.mem.Allocator, node: Node, found: *Found) VerifyError!void {
    const cl = node.asList() orelse return;
    for (cl[1..]) |sym| {
        const sl = sym.asList() orelse continue;
        if (sl.len < 2 or !sym.isForm("symbol")) continue;
        const name = sl[1].asText() orelse continue;
        try found.lib_names.put(arena, name, {});
        var pads: std.StringHashMapUnmanaged(void) = .empty;
        defer pads.deinit(arena);
        try uniquePads(arena, sym, &pads);
        try scanLibUnits(arena, sl[2..], name, found);
    }
}

/// Record every pin of a library entry's unit sub-symbols, so a placed symbol
/// can be turned back into the sheet points a wire must not run across.
fn scanLibUnits(
    arena: std.mem.Allocator,
    children: []const Node,
    lib: []const u8,
    found: *Found,
) VerifyError!void {
    for (children) |sub| {
        if (!sub.isForm("symbol")) continue;
        const l = sub.asList() orelse continue;
        if (l.len < 2) continue;
        const unit = subUnit(l[1].asText() orelse "") orelse continue;
        for (l[2..]) |item| {
            if (!item.isForm("pin")) continue;
            const at = pointOf(item) orelse continue;
            try found.geom.lib_pins.append(arena, .{ .lib = lib, .unit = unit, .at = at });
        }
    }
}

/// Walk a library symbol's units collecting `(number "PAD")` entries, failing
/// on the first repeat.
fn uniquePads(arena: std.mem.Allocator, node: Node, pads: *std.StringHashMapUnmanaged(void)) VerifyError!void {
    const cl = node.asList() orelse return;
    for (cl) |child| {
        if (child.isForm("number")) {
            const l = child.asList() orelse continue;
            if (l.len < 2) continue;
            const pad = l[1].asText() orelse continue;
            if ((try pads.fetchPut(arena, pad, {})) != null) return error.DuplicatePad;
            continue;
        }
        if (child.asList() != null) try uniquePads(arena, child, pads);
    }
}

/// A placed symbol: `(symbol (lib_id "…") … (uuid "…") …)`. Library entries
/// spell their name as a bare string instead, and live inside `lib_symbols`. A
/// `#PWR`-referenced symbol is a power rail, and its Value is what names the net.
fn scanPlaced(arena: std.mem.Allocator, node: Node, found: *Found) VerifyError!void {
    const cl = node.asList() orelse return;
    var lib_id: ?[]const u8 = null;
    var uuid: ?[]const u8 = null;
    for (cl[1..]) |child| {
        const l = child.asList() orelse continue;
        if (l.len < 2) continue;
        if (child.isForm("lib_id")) lib_id = l[1].asText();
        if (child.isForm("uuid")) uuid = l[1].asText();
    }
    const id = lib_id orelse return;
    try found.lib_ids.append(arena, id);
    try found.uuids.append(arena, uuid orelse "");
    if (pointOf(node)) |at| {
        try found.geom.placed.append(arena, .{
            .lib = id,
            .unit = unitOf(node),
            .at = at,
            .angle = angleOf(node),
        });
    }
    const ref = property(node, "Reference") orelse return;
    if (!std.mem.startsWith(u8, ref, power_ref_prefix)) return;
    try found.rail_values.add(arena, property(node, "Value") orelse "");
}

/// Every *connection* coordinate in the document must sit on KiCad's 1.27 mm
/// connection grid: a pin endpoint, a wire end, a label anchor, a placed
/// symbol's origin. Off-grid endpoints are one ERC warning each and, on a
/// label-connected sheet, drown out real findings.
///
/// Drawing-only graphics are exempt, and that exemption is what lets a vendor
/// `.kicad_sym` body be re-emitted exactly. A vendor arc's control point or a
/// circle's centre is frequently off the connection grid; snapping it would
/// visibly distort the drawn part, and KiCad's grid rule never looks at a
/// graphic because a graphic connects to nothing. Text is deliberately NOT
/// exempt — its anchor is spelled `(at …)` like a real connection point, so the
/// exporter grid-snaps it and the scan keeps checking it.
fn gridScan(node: Node) VerifyError!void {
    if (isGraphicForm(node)) return;
    const cl = node.asList() orelse return;
    if (cl.len >= 3 and isPointForm(node)) {
        try onGrid(cl[1]);
        try onGrid(cl[2]);
    }
    for (cl) |child| try gridScan(child);
}

fn isPointForm(node: Node) bool {
    return node.isForm("at") or node.isForm("xy") or node.isForm("start") or node.isForm("end");
}

fn isGraphicForm(node: Node) bool {
    return node.isForm("rectangle") or node.isForm("polyline") or
        node.isForm("circle") or node.isForm("arc") or node.isForm("bezier");
}

fn onGrid(node: Node) VerifyError!void {
    const v = node.asNumber() orelse return;
    const scaled = v * 100.0;
    const hundredths = numeric.checkedInt(i64, @round(scaled)) orelse return error.OffGrid;
    const back: f64 = @floatFromInt(hundredths);
    if (@abs(scaled - back) > 0.01) return error.OffGrid;
    if (@rem(hundredths, grid_hundredths) != 0) return error.OffGrid;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const minimal_doc =
    \\(kicad_sch
    \\  (version 20260306)
    \\  (lib_symbols
    \\    (symbol "netlisp:BOX"
    \\      (symbol "BOX_1_1"
    \\        (pin passive line (at -15.24 1.27 0) (length 2.54)
    \\          (name "A" (effects)) (number "1" (effects)))
    \\        (pin passive line (at 15.24 1.27 180) (length 2.54)
    \\          (name "B" (effects)) (number "2" (effects))))))
    \\  (symbol (lib_id "netlisp:BOX") (at 63.5 38.1 0)
    \\    (uuid "aaaa"))
    \\  (global_label "NETA" (at 43.18 36.83 180))
    \\  (no_connect (at 78.74 36.83))
    \\)
;

const minimal_expect = Expect{
    .uuids = &.{"aaaa"},
    .lib_ids = &.{"netlisp:BOX"},
    .labels = &.{"NETA"},
    .rail_values = &.{},
    .no_connects = 1,
};

// spec: export_kicad_sch - The self-check accepts a well-formed sheet and rejects one whose symbol has been removed
test "kicad-sch: verify passes a good document and catches a dropped symbol" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    _ = try check(a, minimal_doc, minimal_expect);

    // Mutilate it: delete the placed symbol block.
    const cut_start = std.mem.indexOf(u8, minimal_doc, "  (symbol (lib_id").?;
    const cut_end = std.mem.indexOf(u8, minimal_doc, "  (global_label").?;
    const damaged = try std.mem.concat(a, u8, &.{ minimal_doc[0..cut_start], minimal_doc[cut_end..] });
    try testing.expectError(error.SymbolCountMismatch, check(a, damaged, minimal_expect));
}

// spec: export_kicad_sch - The self-check rejects a dropped net label, a stray no-connect, and an unknown lib_id
test "kicad-sch: verify catches label, no-connect, and lib_id damage" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const no_label = try std.mem.replaceOwned(u8, a, minimal_doc, "  (global_label \"NETA\" (at 43.18 36.83 180))\n", "");
    try testing.expectError(error.LabelCountMismatch, check(a, no_label, minimal_expect));

    const renamed = try std.mem.replaceOwned(u8, a, minimal_doc, "(global_label \"NETA\"", "(global_label \"NETB\"");
    try testing.expectError(error.MissingNetLabel, check(a, renamed, minimal_expect));

    const no_nc = try std.mem.replaceOwned(u8, a, minimal_doc, "  (no_connect (at 78.74 36.83))\n", "");
    try testing.expectError(error.NoConnectCountMismatch, check(a, no_nc, minimal_expect));

    const orphan = try std.mem.replaceOwned(u8, a, minimal_doc, "(symbol \"netlisp:BOX\"", "(symbol \"netlisp:OTHER\"");
    try testing.expectError(error.UnknownLibId, check(a, orphan, minimal_expect));
}

// spec: export_kicad_sch - The self-check rejects an off-grid coordinate and a repeated pad number
test "kicad-sch: verify catches off-grid coordinates and duplicate pads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const off = try std.mem.replaceOwned(u8, a, minimal_doc, "(at 63.5 38.1 0)", "(at 63.4 38.1 0)");
    try testing.expectError(error.OffGrid, check(a, off, minimal_expect));

    const dup = try std.mem.replaceOwned(u8, a, minimal_doc, "(number \"2\"", "(number \"1\"");
    try testing.expectError(error.DuplicatePad, check(a, dup, minimal_expect));
}

// spec: export_kicad_sch - The grid scan exempts a vendor body's drawing while still rejecting an off-grid connection point
test "kicad-sch: verify passes off-grid body art but not an off-grid pin" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A vendor arc/polyline routinely sits between grid points. It connects to
    // nothing, so it must not fail the document.
    const art = try std.mem.replaceOwned(u8, a, minimal_doc, "      (symbol \"BOX_1_1\"\n", "      (symbol \"BOX_1_1\"\n" ++
        "        (polyline (pts (xy -15.239 1.219) (xy -1.1 2.2))\n" ++
        "          (stroke (width 0.254) (type default)) (fill (type none)))\n" ++
        "        (arc (start 7.62 0) (mid 6.35 1.219) (end 5.08 0)\n" ++
        "          (stroke (width 0.254) (type default)) (fill (type none)))\n");
    _ = try check(a, art, minimal_expect);

    // The pin endpoint beside it is a connection point, and is still checked.
    const bad = try std.mem.replaceOwned(u8, a, minimal_doc, "(at -15.24 1.27 0)", "(at -15.239 1.27 0)");
    try testing.expectError(error.OffGrid, check(a, bad, minimal_expect));
}

const wired_doc =
    \\(kicad_sch
    \\  (version 20260306)
    \\  (lib_symbols
    \\    (symbol "netlisp:BOX"
    \\      (symbol "BOX_1_1"
    \\        (pin passive line (at -15.24 1.27 0) (length 2.54)
    \\          (name "A" (effects)) (number "1" (effects)))
    \\        (pin passive line (at 15.24 1.27 180) (length 2.54)
    \\          (name "B" (effects)) (number "2" (effects))))))
    \\  (symbol (lib_id "netlisp:BOX") (at 63.5 38.1 0) (unit 1)
    \\    (uuid "aaaa"))
    \\  (wire (pts (xy 48.26 36.83) (xy 43.18 36.83)))
    \\  (wire (pts (xy 43.18 36.83) (xy 43.18 27.94)))
    \\  (wire (pts (xy 43.18 36.83) (xy 43.18 46.99)))
    \\  (wire (pts (xy 78.74 36.83) (xy 83.82 36.83)))
    \\  (junction (at 43.18 36.83))
    \\  (global_label "NETA" (at 43.18 46.99 180))
    \\  (global_label "NETB" (at 83.82 36.83 0))
    \\)
;

const wired_expect = Expect{
    .uuids = &.{"aaaa"},
    .lib_ids = &.{"netlisp:BOX"},
    .labels = &.{ "NETA", "NETB" },
    .rail_values = &.{},
    .no_connects = 0,
    .wires = 4,
};

// spec: export_kicad_sch - The self-check rejects a wire drawn across a pin, a diagonal wire, and a lost segment
test "kicad-sch: verify catches a wire through a pin, a diagonal, and a missing segment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    _ = try check(a, wired_doc, wired_expect);

    // Pulling the wire's start back past pad 2 puts that pin in the segment's
    // interior, where KiCad does not connect it at all.
    const through = try std.mem.replaceOwned(u8, a, wired_doc, "(xy 78.74 36.83)", "(xy 73.66 36.83)");
    try testing.expectError(error.WireThroughPin, check(a, through, wired_expect));

    const diagonal = try std.mem.replaceOwned(u8, a, wired_doc, "(xy 43.18 27.94)", "(xy 40.64 27.94)");
    try testing.expectError(error.WireNotOrthogonal, check(a, diagonal, wired_expect));

    const dropped = try std.mem.replaceOwned(u8, a, wired_doc, "  (wire (pts (xy 43.18 36.83) (xy 43.18 46.99)))\n", "");
    try testing.expectError(error.WireCountMismatch, check(a, dropped, wired_expect));
}

// spec: export_kicad_sch - The self-check rejects a global label sitting inside a wire rather than at its end
test "kicad-sch: verify catches a label caught mid-wire" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Sliding NETB's label back along its own wire puts it in that wire's
    // interior. KiCad still attaches it there, which is how a run along a
    // symbol edge would silently swallow a neighbouring pin's net.
    const at_end = "(global_label \"NETB\" (at 83.82 36.83 0))";
    const mid_wire = "(global_label \"NETB\" (at 81.28 36.83 0))";
    const inside = try std.mem.replaceOwned(u8, a, wired_doc, at_end, mid_wire);
    try testing.expectError(error.LabelOnWireInterior, check(a, inside, wired_expect));
}

// spec: export_kicad_sch - The self-check demands a junction dot where three wire ends meet and rejects one that connects nothing
test "kicad-sch: verify matches junction dots to the points wire ends actually meet at" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const undotted = try std.mem.replaceOwned(u8, a, wired_doc, "  (junction (at 43.18 36.83))\n", "");
    try testing.expectError(error.MissingJunction, check(a, undotted, wired_expect));

    // Moved onto a lone wire end, the dot claims a connection that is not there.
    const stray = try std.mem.replaceOwned(u8, a, wired_doc, "(junction (at 43.18 36.83))", "(junction (at 43.18 27.94))");
    try testing.expectError(error.StrayJunction, check(a, stray, wired_expect));
}

const hier_doc =
    \\(kicad_sch
    \\  (version 20260306)
    \\  (lib_symbols
    \\    (symbol "netlisp:PWR_GND"
    \\      (symbol "PWR_GND_1_1"
    \\        (pin power_in line (at 0 0 270) (length 0)
    \\          (name "" (effects)) (number "1" (effects))))))
    \\  (symbol (lib_id "netlisp:PWR_GND") (at 63.5 38.1 0)
    \\    (uuid "pwr-1")
    \\    (property "Reference" "#PWR01" (at 63.5 31.75 0))
    \\    (property "Value" "GND" (at 63.5 44.45 0)))
    \\  (sheet (at 25.4 25.4 0) (size 63.5 25.4)
    \\    (uuid "sheet-1")
    \\    (property "Sheetname" "Core" (at 25.4 24.13 0))
    \\    (property "Sheetfile" "board-core.kicad_sch" (at 25.4 52.07 0)))
    \\)
;

const hier_expect = Expect{
    .uuids = &.{"pwr-1"},
    .lib_ids = &.{"netlisp:PWR_GND"},
    .labels = &.{},
    .rail_values = &.{"GND"},
    .no_connects = 0,
    .sheets = &.{"board-core.kicad_sch"},
};

// spec: export_kicad_sch - The self-check rejects a broken child-sheet link and a ground symbol naming the wrong rail
test "kicad-sch: verify matches child sheet files and rail symbol values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    _ = try check(a, hier_doc, hier_expect);

    const renamed_file = try std.mem.replaceOwned(u8, a, hier_doc, "board-core.kicad_sch", "board-other.kicad_sch");
    try testing.expectError(error.SheetLinkMismatch, check(a, renamed_file, hier_expect));

    const no_sheet = try std.mem.replaceOwned(u8, a, hier_doc, "(property \"Sheetfile\"", "(property \"Other\"");
    try testing.expectError(error.SheetLinkMismatch, check(a, no_sheet, hier_expect));

    const wrong_rail = try std.mem.replaceOwned(u8, a, hier_doc, "\"Value\" \"GND\"", "\"Value\" \"AGND\"");
    try testing.expectError(error.MissingNetLabel, check(a, wrong_rail, hier_expect));
}
