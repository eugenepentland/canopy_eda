//! Synthesised KiCad library symbols for the `.kicad_sch` exporter.
//!
//! netlisp carries no schematic symbol geometry — a component is a pinout
//! (physical pad -> function name) plus a footprint. This module turns that
//! into a drawable box symbol: a rectangle body with one pin per physical pad,
//! pin number = pad, pin name = pinout function name.
//!
//! Two rules the rest of the exporter depends on:
//!   * Every coordinate is an integer number of hundredths of a millimetre and
//!     a multiple of `grid` (1.27 mm). KiCad's ERC reports every off-grid
//!     endpoint, so grid-exactness is a correctness property, not a nicety.
//!   * Pad ids are unique inside one symbol. A repeated pad number silently
//!     splits the net in KiCad's exported netlist, so the union that builds the
//!     pad list de-duplicates and the emitted file is re-checked afterwards.
//!
//! Supply pins go on top, ground pins on the bottom, everything else splits
//! left/right — classified by `placement/pin_roles`, the same supply/ground
//! heuristic the placement optimizer uses.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser = @import("../sexpr/parser.zig");
const glyph = @import("glyph.zig");
const infra_fs = @import("../infra/fs.zig");
const kicad_sym = @import("../kicad_sym/reader.zig");
const pin_roles = @import("../placement/pin_roles.zig");
const lib_limits = @import("../lib_limits.zig");

/// KiCad's schematic connection grid, in hundredths of a millimetre (1.27 mm).
/// Every emitted coordinate is a multiple of this.
pub const grid: i32 = 127;
/// Pin-to-pin spacing along a symbol edge (2.54 mm = 2 grid units).
pub const pitch: i32 = 254;
/// Drawn length of a library pin (2.54 mm). The connection point is the pin's
/// `(at …)`, so this only affects how far the stub is drawn.
pub const pin_len: i32 = 254;

const min_half_w: i32 = 1270;
const min_half_h: i32 = 508;
const compact_half_w: i32 = 635;
const compact_half_h: i32 = 254;

/// Sheet space one character of a drawn pin name takes. KiCad's stroke font
/// advances about one font size per character at the 1.27 mm every pin name is
/// drawn at (measured: `VDDCORE` plots 8.85 mm).
const name_char_w: i32 = grid;

/// Longest name allowed to widen a body, so one pathological function name
/// cannot inflate a whole symbol.
const max_name_chars: usize = 16;

/// Longest pad id allowed to lengthen a pin, for the same reason.
const max_pad_chars: usize = 8;

/// Which edge of the symbol body a pin leaves from. Fixes both the drawn pin
/// angle and the direction its wire stub and net label run.
pub const Side = enum { left, right, top, bottom };

/// One pin of a synthesised symbol, in library coordinates (y-UP, origin at the
/// symbol centre). `x`/`y` are the pin's *connection endpoint* — the point a
/// wire must touch.
pub const Pin = struct {
    /// Physical pad id, emitted as the KiCad pin `(number …)`.
    pad: []const u8,
    /// Pinout function name, emitted as the pin `(name …)`; falls back to `pad`.
    name: []const u8,
    side: Side,
    x: i32,
    y: i32,
    /// Drawn length back toward the body. Only affects the drawing — the
    /// connection point is `(x, y)` whatever the length — but a vendor body
    /// sits further from its pins than a synthesised box does, so a vendor pin
    /// keeps its own.
    len: i32 = pin_len,
    /// Whether the pin's function name is DRAWN. A pin ganged with its
    /// same-net neighbours is named by the gang's one label, so repeating the
    /// function name on each of fifteen ground pads is the text soup that made
    /// a dense body unreadable. The name stays in the file (and so in KiCad's
    /// exported `pinfunction`) — only its font size is zeroed, which is the one
    /// spelling KiCad 10.0.1 actually honours for hiding a single pin's name.
    show_name: bool = true,
};

/// One KiCad unit of a symbol — a `(part …)` grouping drawn as its own body,
/// placeable independently of its siblings. A component with no `(part …)`
/// declaration has exactly one unit holding every pad.
pub const Unit = struct {
    /// KiCad unit number, 1-based and contiguous across the shape.
    number: u32,
    /// The `(part "…")` title, or "" for a single/catch-all unit.
    title: []const u8,
    pins: []const Pin,
    /// Body half-width and half-height in hundredths of a millimetre.
    half_w: i32,
    half_h: i32,
    /// A vendor symbol's own drawn body, in `kicad_sym` units. Empty means the
    /// synthesised rectangle `half_w`/`half_h` describe.
    graphics: []const kicad_sym.Graphic = &.{},
    /// Extra stub length per pin, parallel to `pins`, filled by
    /// `kicad_sch/stagger.zig` when an edge's pins sit closer together than the
    /// text beside them. Empty — the usual case — means every pin's label sits
    /// one plain stub out. Read it through `stubExtra`, which tolerates that.
    stubs: []const i32 = &.{},
};

/// A synthesised box symbol: one or more units, each a body plus its pins. One
/// shape is shared by every instance of the same component and part breakdown.
pub const Shape = struct {
    /// Library-symbol name, without the `netlisp:` library prefix.
    lib_name: []const u8,
    /// Always at least one entry.
    units: []const Unit,
    /// True when the body came from the part's original vendor `.kicad_sym`
    /// rather than being synthesised. Reported, not acted on.
    vendor: bool = false,
    /// True for a stock passive glyph, whose pin numbers and names are hidden
    /// exactly as KiCad's own `Device` symbols hide theirs — a resistor
    /// labelled "1"/"2" on both ends is clutter, not information.
    hide_pin_text: bool = false,
};

/// One `(part …)` grouping: the pads it claims, in declaration order.
pub const PartSpec = struct {
    title: []const u8,
    pads: []const []const u8,
};

/// The three names one component answers to. All three are tried, in this
/// order, when looking for the part's original vendor `.kicad_sym`; `pinout`
/// additionally selects the `lib/pinouts/` file that names the pads.
pub const Names = struct {
    component: []const u8 = "",
    /// Declared `(symbol …)` name, when the component names one.
    symbol: []const u8 = "",
    /// Declared pinout key; empty falls back to the component's own
    /// `(pinout …)` declaration and then to the component name.
    pinout: []const u8 = "",
};

/// Everything `synth` needs about one component to draw it. `fp_pads` and
/// `used` widen the pad set beyond the pinout so a pad that exists only on the
/// footprint, or only on a net, still gets a pin (and therefore a netlist node).
pub const Request = struct {
    names: Names,
    project_dir: []const u8,
    /// Pad ids read off the component's footprint, in footprint order.
    fp_pads: []const []const u8 = &.{},
    /// Pad ids referenced by the flattened netlist, in net order.
    used: []const []const u8 = &.{},
    /// `(part …)` groupings; each becomes one KiCad unit. Pads no part claims
    /// form a trailing catch-all unit, so every pad is still drawn exactly once.
    parts: []const PartSpec = &.{},
    /// Which stock KiCad passive glyph to draw. `box` is the synthesised
    /// rectangle; anything else draws the real `Device`-library body when the
    /// part has that glyph's pad count, and otherwise falls back to a small
    /// two-pin box — which is what a two-pad part used to get unconditionally.
    glyph: glyph.Class = .box,
    /// Pad id -> the net that pad carries, taken from the FIRST instance using
    /// this symbol. Pads sharing a net are drawn side by side on their edge so
    /// the sheet can gang them under one label, and their function names are
    /// dropped. Absent (or absent for a pad) simply means the pinout's own
    /// order, which is what every earlier phase drew.
    nets: ?*const std.StringHashMapUnmanaged([]const u8) = null,
};

/// Pad id paired with its pinout function name.
pub const PadName = struct { pad: []const u8, name: []const u8 };

/// One unit's pads before geometry: the `(part …)` title plus the pads it owns.
const UnitPads = struct { title: []const u8, pads: []const PadName };

/// Build the symbol for one component. Never fails on missing library files: an
/// unreadable pinout just means the pads carry their own ids as names, which
/// still yields a correct (if unlabelled) symbol.
pub fn synth(arena: std.mem.Allocator, req: Request) std.mem.Allocator.Error!Shape {
    const pads = try requiredPads(arena, req);
    if (try glyph.unitFor(arena, req.glyph, pads)) |drawn| {
        const one = try arena.alloc(Unit, 1);
        one[0] = drawn;
        return .{ .lib_name = try libNameFor(arena, req), .units = one, .hide_pin_text = true };
    }

    const compact = req.glyph != .box and pads.len <= 2;
    const groups = try splitUnits(arena, pads, req.parts);

    const units = try arena.alloc(Unit, groups.len);
    for (groups, 0..) |g, i| {
        units[i] = try buildUnit(arena, g, @intCast(i + 1), .{ .compact = compact, .nets = req.nets });
    }

    return .{
        .lib_name = try libNameFor(arena, req),
        .units = units,
    };
}

/// The `lib_symbols` name a component's symbol is filed under, whether it is
/// drawn from a vendor body or synthesised — so swapping one for the other
/// never renames the entry.
pub fn libNameFor(arena: std.mem.Allocator, req: Request) std.mem.Allocator.Error![]const u8 {
    return sanitizeLibName(arena, req.names.component);
}

/// How far pin `i`'s label sits BEYOND the plain stub every other pin gets,
/// when its edge was spread into columns (`kicad_sch/stagger.zig`). Zero for a
/// unit that was never spread, which is every symbol on the usual pin pitch.
pub fn stubExtra(u: Unit, i: usize) i32 {
    return if (i < u.stubs.len) u.stubs[i] else 0;
}

/// True when a pin's function name says nothing its pad number does not. KiCad
/// draws the number outside the body and the name inside it, so such a pin is
/// the same string printed twice — and on a fine-pitch connector, whose pinout
/// names every contact after its own contact number, twice is a smear.
pub fn namesPad(p: PadName) bool {
    return std.mem.eql(u8, p.name, p.pad);
}

/// How far the furthest pin endpoint of a unit sits outside its body — the
/// space a sheet must leave beside it before the stub and the net label start.
/// A vendor body, or a part whose pad ids lengthened its pins, reaches further
/// than the default pin length.
pub fn maxReach(u: Unit) i32 {
    var out: i32 = pin_len;
    for (u.pins) |p| {
        const from_body: i32 = switch (p.side) {
            .left, .right => @as(i32, @intCast(@abs(p.x))) - u.half_w,
            .top, .bottom => @as(i32, @intCast(@abs(p.y))) - u.half_h,
        };
        out = @max(out, from_body);
    }
    return out;
}

/// One box unit holding exactly `pads` — the fallback body for pads a vendor
/// symbol does not draw, so the every-pad-drawn invariant survives a symbol
/// whose pin list is narrower than the netlist's.
pub fn boxUnit(
    arena: std.mem.Allocator,
    pads: []const PadName,
    number: u32,
) std.mem.Allocator.Error!Unit {
    return buildUnit(arena, .{ .title = "", .pads = pads }, number, .{});
}

/// Partition the pad list into units. With no `(part …)` declarations that is
/// one unit holding everything; otherwise each part becomes a unit in
/// declaration order and the pads nothing claimed form a trailing catch-all, so
/// the every-pad-drawn invariant survives a partial breakdown. Empty units are
/// dropped so KiCad's unit numbers stay contiguous.
fn splitUnits(
    arena: std.mem.Allocator,
    pads: []const PadName,
    parts: []const PartSpec,
) std.mem.Allocator.Error![]const UnitPads {
    if (parts.len == 0) return oneUnit(arena, pads);

    var owner: std.StringHashMapUnmanaged(usize) = .empty;
    defer owner.deinit(arena);
    for (parts, 0..) |part, pi| {
        for (part.pads) |pad| {
            const gop = try owner.getOrPut(arena, pad);
            if (!gop.found_existing) gop.value_ptr.* = pi;
        }
    }

    const buckets = try arena.alloc(std.ArrayList(PadName), parts.len + 1);
    for (buckets) |*b| b.* = .empty;
    for (pads) |p| try buckets[owner.get(p.pad) orelse parts.len].append(arena, p);

    var out: std.ArrayList(UnitPads) = .empty;
    for (buckets, 0..) |b, i| {
        if (b.items.len == 0) continue;
        const title = if (i < parts.len) parts[i].title else "";
        try out.append(arena, .{ .title = title, .pads = b.items });
    }
    if (out.items.len == 0) return oneUnit(arena, pads);
    return out.items;
}

/// The whole pad set as a single untitled unit, on the arena — a slice of a
/// stack temporary would dangle the moment `splitUnits` returned.
fn oneUnit(arena: std.mem.Allocator, pads: []const PadName) std.mem.Allocator.Error![]const UnitPads {
    const out = try arena.alloc(UnitPads, 1);
    out[0] = .{ .title = "", .pads = pads };
    return out;
}

/// How one unit is drawn: as the small two-terminal box a passive falls back
/// to, and against which pad-to-net map (if any) its edges are ordered.
const Style = struct {
    compact: bool = false,
    nets: ?*const std.StringHashMapUnmanaged([]const u8) = null,
};

/// Where each pad sits along its own edge, and whether its function name is
/// drawn there.
const Edges = struct {
    /// Position of each pad within its own edge, 0 outward.
    slot: []usize,
    /// False for a pad drawn as part of a same-net gang, which the gang's one
    /// label names.
    show_name: []bool,
};

/// Lay out one unit: assign each pad an edge, order the pads along it so
/// same-net pads sit together, size the body around the busiest edge AND around
/// the names it must hold, and place the pins.
fn buildUnit(
    arena: std.mem.Allocator,
    group: UnitPads,
    number: u32,
    style: Style,
) std.mem.Allocator.Error!Unit {
    const pads = group.pads;
    var sides = try arena.alloc(Side, pads.len);
    var n: [4]usize = .{ 0, 0, 0, 0 };
    try assignSides(arena, pads, style.compact, &sides, &n);
    const edges = try orderEdges(arena, pads, sides, n, style.nets);
    const names = nameSpans(pads, sides, edges.show_name);

    const half_w = if (style.compact) compact_half_w else @max(
        axisHalf(@max(n[idx(.top)], n[idx(.bottom)]), min_half_w),
        facing(names[idx(.left)], names[idx(.right)]),
    );
    const half_h = if (style.compact) compact_half_h else @max(
        axisHalf(@max(n[idx(.left)], n[idx(.right)]), min_half_h),
        facing(names[idx(.top)], names[idx(.bottom)]),
    );

    const plen = pinLenFor(pads);
    const pins = try arena.alloc(Pin, pads.len);
    for (pads, 0..) |p, i| {
        const side = sides[i];
        const along = axisPos(n[idx(side)], edges.slot[i]);
        pins[i] = .{
            .pad = p.pad,
            .name = p.name,
            .side = side,
            .show_name = edges.show_name[i],
            .len = plen,
            .x = switch (side) {
                .left => -(half_w + plen),
                .right => half_w + plen,
                .top, .bottom => -along,
            },
            .y = switch (side) {
                .top => half_h + plen,
                .bottom => -(half_h + plen),
                .left, .right => along,
            },
        };
    }
    return .{ .number = number, .title = group.title, .pins = pins, .half_w = half_w, .half_h = half_h };
}

/// Drawn pin length for one unit. KiCad straddles a pin's NUMBER across the
/// middle of its pin, so a pad id wider than the pin spills past the body edge
/// and lands on the function name written just inside it — which is what made a
/// BGA's `C17` sit on top of its own `PB14`. Give the pin room for its number.
fn pinLenFor(pads: []const PadName) i32 {
    var widest: usize = 0;
    for (pads) |p| widest = @max(widest, p.pad.len);
    const chars: i32 = @intCast(@min(widest, max_pad_chars));
    return @max(pin_len, snapUpGrid(chars * name_char_w));
}

/// Order each edge so pads on one net are adjacent, and mark the ones a gang
/// will name. Adjacency is not cosmetic: a gang is one wire running along the
/// edge through its members' stub tips, and a foreign pin's stub tip caught
/// between two of them would be joined to the gang by its label.
fn orderEdges(
    arena: std.mem.Allocator,
    pads: []const PadName,
    sides: []const Side,
    n: [4]usize,
    nets: ?*const std.StringHashMapUnmanaged([]const u8),
) std.mem.Allocator.Error!Edges {
    const out = Edges{
        .slot = try arena.alloc(usize, pads.len),
        .show_name = try arena.alloc(bool, pads.len),
    };
    for (pads, out.show_name) |p, *show| show.* = !namesPad(p);
    var seen: [4]usize = .{ 0, 0, 0, 0 };
    for (pads, 0..) |_, i| {
        out.slot[i] = seen[idx(sides[i])];
        seen[idx(sides[i])] += 1;
    }
    const map = nets orelse return out;
    for (0..4) |si| {
        if (n[si] < 2) continue;
        try gangEdge(arena, pads, sides, @fromBackingInt(@intCast(si)), map, out);
    }
    return out;
}

/// Re-slot one edge: its pads in first-appearance order of the nets they carry,
/// so every net's pads land in one run. A pad with no net keeps a run of its
/// own, and so keeps its place relative to the runs around it.
fn gangEdge(
    arena: std.mem.Allocator,
    pads: []const PadName,
    sides: []const Side,
    side: Side,
    map: *const std.StringHashMapUnmanaged([]const u8),
    out: Edges,
) std.mem.Allocator.Error!void {
    var runs: std.ArrayList(std.ArrayList(usize)) = .empty;
    var of_net: std.StringHashMapUnmanaged(usize) = .empty;
    defer of_net.deinit(arena);
    for (pads, 0..) |p, i| {
        if (sides[i] != side) continue;
        const net = map.get(p.pad) orelse "";
        var run = runs.items.len;
        if (net.len > 0) {
            const gop = try of_net.getOrPut(arena, net);
            if (!gop.found_existing) gop.value_ptr.* = run;
            run = gop.value_ptr.*;
        }
        if (run == runs.items.len) try runs.append(arena, .empty);
        try runs.items[run].append(arena, i);
    }
    var slot: usize = 0;
    for (runs.items) |run| {
        for (run.items) |i| {
            out.slot[i] = slot;
            out.show_name[i] = out.show_name[i] and run.items.len < 2;
            slot += 1;
        }
    }
}

/// Longest drawn function name on each edge, in sheet units. A name runs from
/// the body edge inward along its pin, so this is how deep into the body that
/// edge's text reaches.
fn nameSpans(pads: []const PadName, sides: []const Side, show: []const bool) [4]i32 {
    var out: [4]i32 = .{ 0, 0, 0, 0 };
    for (pads, 0..) |p, i| {
        if (!show[i]) continue;
        const si = idx(sides[i]);
        out[si] = @max(out[si], @as(i32, @intCast(@min(p.name.len, max_name_chars))) * name_char_w);
    }
    return out;
}

/// Half-extent an axis needs so the names running in from its two edges cannot
/// meet in the middle: the two reaches plus a pin pitch of air, on the grid.
fn facing(a: i32, b: i32) i32 {
    if (a == 0 and b == 0) return 0;
    return snapUpGrid(@divTrunc(a + b, 2) + pitch);
}

fn snapUpGrid(v: i32) i32 {
    const r = @mod(v, grid);
    return if (r == 0) v else v + (grid - r);
}

fn idx(s: Side) usize {
    return @backingInt(s);
}

/// Place pads on edges: supplies top, grounds bottom, the rest split evenly
/// left/right in pad order. A compact two-pin part is simply left/right.
fn assignSides(
    arena: std.mem.Allocator,
    pads: []const PadName,
    compact: bool,
    sides: *[]Side,
    n: *[4]usize,
) std.mem.Allocator.Error!void {
    var signals: std.ArrayList(usize) = .empty;
    defer signals.deinit(arena);
    for (pads, 0..) |p, i| {
        if (compact) {
            sides.*[i] = if (i == 0) .left else .right;
        } else if (pin_roles.isSupplyFn(p.name)) {
            sides.*[i] = .top;
        } else if (pin_roles.isGroundFn(p.name)) {
            sides.*[i] = .bottom;
        } else {
            sides.*[i] = .left; // provisional; split below
            try signals.append(arena, i);
            continue;
        }
        n[idx(sides.*[i])] += 1;
    }
    const left_count = (signals.items.len + 1) / 2;
    for (signals.items, 0..) |pi, k| {
        sides.*[pi] = if (k < left_count) .left else .right;
        n[idx(sides.*[pi])] += 1;
    }
}

/// Half-extent of a body edge carrying `k` pins: far enough that the outermost
/// pin still sits `pitch` inside the corner. Always a multiple of `grid`.
fn axisHalf(k: usize, minimum: i32) i32 {
    if (k == 0) return minimum;
    const span: i32 = @intCast((k - 1) * @as(usize, @intCast(grid)));
    return @max(minimum, span + pitch);
}

/// Offset of pin `i` of `k` along its edge, centred on the symbol origin.
/// `(k-1)*grid` is the first offset and every step is `pitch`, so every result
/// is a multiple of `grid`.
fn axisPos(k: usize, i: usize) i32 {
    const start: i32 = @intCast((k - 1) * @as(usize, @intCast(grid)));
    const step: i32 = @intCast(i * @as(usize, @intCast(pitch)));
    return start - step;
}

/// Ordered, de-duplicated pad list for a component: the pinout first (it is the
/// only source of function names), then footprint pads it omits, then any pad
/// the netlist references that neither knows about.
pub fn requiredPads(arena: std.mem.Allocator, req: Request) std.mem.Allocator.Error![]const PadName {
    var out: std.ArrayList(PadName) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(arena);

    for (try loadPinout(arena, req)) |pn| {
        if ((try seen.fetchPut(arena, pn.pad, {})) != null) continue;
        try out.append(arena, pn);
    }
    for (req.fp_pads) |pad| {
        if (pad.len == 0) continue;
        if ((try seen.fetchPut(arena, pad, {})) != null) continue;
        try out.append(arena, .{ .pad = pad, .name = pad });
    }
    for (req.used) |pad| {
        if (pad.len == 0) continue;
        if ((try seen.fetchPut(arena, pad, {})) != null) continue;
        try out.append(arena, .{ .pad = pad, .name = pad });
    }
    return out.items;
}

/// Read `lib/pinouts/<key>.sexp` as an ordered pad -> function-name list,
/// trying the declared key, then the component's own `(pinout …)` declaration,
/// then the component name. Empty when nothing resolves.
fn loadPinout(arena: std.mem.Allocator, req: Request) std.mem.Allocator.Error![]const PadName {
    if (req.names.pinout.len > 0) {
        const pins = try readPinout(arena, req.project_dir, req.names.pinout);
        if (pins.len > 0) return pins;
    }
    if (declaredPinout(arena, req.project_dir, req.names.component)) |key| {
        const pins = try readPinout(arena, req.project_dir, key);
        if (pins.len > 0) return pins;
    }
    if (req.names.component.len > 0) return readPinout(arena, req.project_dir, req.names.component);
    return &.{};
}

/// The `(pinout "x")` key declared by `lib/components/<component>.sexp`.
fn declaredPinout(arena: std.mem.Allocator, project_dir: []const u8, component: []const u8) ?[]const u8 {
    if (component.len == 0) return null;
    const children = loadForm(arena, project_dir, "components", component) orelse return null;
    for (children) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        if (!std.mem.eql(u8, cl[0].asAtom() orelse "", "pinout")) continue;
        if (cl[1].asText()) |p| return p;
    }
    return null;
}

fn readPinout(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    key: []const u8,
) std.mem.Allocator.Error![]const PadName {
    const top = loadForm(arena, project_dir, "pinouts", key) orelse return &.{};
    if (top.len < 2 or !std.mem.eql(u8, top[0].asAtom() orelse "", "pinout")) return &.{};
    var out: std.ArrayList(PadName) = .empty;
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        if (!std.mem.eql(u8, cl[0].asAtom() orelse "", "pin")) continue;
        const pad = cl[1].tokenText(arena) orelse continue;
        const fn_name = cl[2].asText() orelse pad;
        try out.append(arena, .{ .pad = pad, .name = fn_name });
    }
    return out.items;
}

/// Parse `<project_dir>/lib/<dir>/<name>.sexp` and return the first top-level
/// form's children. Null on any read or parse failure — a component with no
/// library data degrades to a pads-only symbol.
fn loadForm(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    dir: []const u8,
    name: []const u8,
) ?[]const ast.Node {
    if (name.len == 0) return null;
    const path = std.fmt.allocPrint(arena, "{s}/lib/{s}/{s}.sexp", .{ project_dir, dir, name }) catch return null;
    const src = infra_fs.cwd().readFileAlloc(arena, path, lib_limits.max_lib_file_bytes) catch return null;
    const nodes = parser.parse(arena, src) catch return null;
    if (nodes.len == 0) return null;
    return nodes[0].asList();
}

/// A library-symbol name KiCad can carry in a `lib_id`: `:` and `/` separate
/// library from part and path segments, so anything outside a conservative
/// identifier set becomes `_`. Never empty.
pub fn sanitizeLibName(arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (name.len == 0) return "UNNAMED";
    var ok = true;
    for (name) |c| {
        if (!isLibNameChar(c)) ok = false;
    }
    if (ok) return name;
    const out = try arena.alloc(u8, name.len);
    for (name, 0..) |c, i| out[i] = if (isLibNameChar(c)) c else '_';
    return out;
}

fn isLibNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '+';
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: export_kicad_sch - Synthesised symbol pins land on the 1.27 mm grid with supplies on top and grounds on the bottom
test "kicad-sch: synth places supply pins up, ground pins down, signals left and right" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/pinouts/reg.sexp",
        .data =
        \\(pinout "reg"
        \\  (pin 1 "VDD") (pin 2 "GND") (pin 3 "SDA") (pin 4 "SCL") (pin 5 "INT"))
        ,
    });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);

    const shape = try synth(a, .{ .names = .{ .component = "reg", .pinout = "reg" }, .project_dir = dir });
    try testing.expectEqual(@as(usize, 1), shape.units.len);
    const unit = shape.units[0];
    try testing.expectEqual(@as(usize, 5), unit.pins.len);
    try testing.expectEqual(Side.top, unit.pins[0].side);
    try testing.expectEqual(Side.bottom, unit.pins[1].side);
    // Three signals split 2 left / 1 right.
    try testing.expectEqual(Side.left, unit.pins[2].side);
    try testing.expectEqual(Side.left, unit.pins[3].side);
    try testing.expectEqual(Side.right, unit.pins[4].side);
    for (unit.pins) |p| {
        try testing.expectEqual(@as(i32, 0), @mod(p.x, grid));
        try testing.expectEqual(@as(i32, 0), @mod(p.y, grid));
    }
    try testing.expectEqual(@as(i32, 0), @mod(unit.half_w, grid));
    try testing.expectEqual(@as(i32, 0), @mod(unit.half_h, grid));
}

// spec: export_kicad_sch - Each (part …) grouping becomes one KiCad unit and unclaimed pads form a trailing catch-all unit
test "kicad-sch: synth splits pads into units and keeps every pad drawn once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const fp_pads = [_][]const u8{ "1", "2", "3", "4", "5" };
    const power = [_][]const u8{ "1", "2" };
    const io = [_][]const u8{"4"};
    const parts = [_]PartSpec{
        .{ .title = "Power", .pads = &power },
        .{ .title = "IO", .pads = &io },
    };
    const shape = try synth(a, .{
        .names = .{ .component = "dual" },
        .project_dir = "/nonexistent",
        .fp_pads = &fp_pads,
        .parts = &parts,
    });
    // Two declared parts plus the catch-all holding pads 3 and 5.
    try testing.expectEqual(@as(usize, 3), shape.units.len);
    try testing.expectEqual(@as(u32, 1), shape.units[0].number);
    try testing.expectEqualStrings("Power", shape.units[0].title);
    try testing.expectEqualStrings("IO", shape.units[1].title);
    try testing.expectEqualStrings("", shape.units[2].title);
    try testing.expectEqual(@as(usize, 2), shape.units[0].pins.len);
    try testing.expectEqual(@as(usize, 1), shape.units[1].pins.len);
    try testing.expectEqual(@as(usize, 2), shape.units[2].pins.len);

    // Pad numbers are global to the symbol: each appears in exactly one unit.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    var total: usize = 0;
    for (shape.units) |u| {
        for (u.pins) |p| {
            try testing.expect((try seen.fetchPut(a, p.pad, {})) == null);
            total += 1;
        }
    }
    try testing.expectEqual(@as(usize, 5), total);
}

// spec: export_kicad_sch - A part declaration that claims every pad leaves no catch-all unit behind
test "kicad-sch: synth drops empty units so unit numbers stay contiguous" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const fp_pads = [_][]const u8{ "1", "2" };
    const all = [_][]const u8{ "1", "2" };
    const unknown = [_][]const u8{"99"};
    const parts = [_]PartSpec{
        // Claims a pad the component does not have — the unit would be empty.
        .{ .title = "Ghost", .pads = &unknown },
        .{ .title = "Real", .pads = &all },
    };
    const shape = try synth(a, .{
        .names = .{ .component = "solo" },
        .project_dir = "/nonexistent",
        .fp_pads = &fp_pads,
        .parts = &parts,
    });
    try testing.expectEqual(@as(usize, 1), shape.units.len);
    try testing.expectEqual(@as(u32, 1), shape.units[0].number);
    try testing.expectEqualStrings("Real", shape.units[0].title);
}

// spec: export_kicad_sch - A symbol's pad set is the pinout widened by footprint pads and net-referenced pads, de-duplicated
test "kicad-sch: synth unions pinout, footprint, and net-referenced pads without repeats" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const fp_pads = [_][]const u8{ "1", "2", "EP" };
    const used = [_][]const u8{ "2", "9" };
    const shape = try synth(a, .{
        .names = .{ .component = "unknown-part" },
        .project_dir = "/nonexistent",
        .fp_pads = &fp_pads,
        .used = &used,
    });
    const pins = shape.units[0].pins;
    try testing.expectEqual(@as(usize, 4), pins.len);
    try testing.expectEqualStrings("1", pins[0].pad);
    try testing.expectEqualStrings("EP", pins[2].pad);
    try testing.expectEqualStrings("9", pins[3].pad);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    for (pins) |p| try testing.expect((try seen.fetchPut(a, p.pad, {})) == null);
}

// spec: export_kicad_sch - A two-pin passive draws its stock glyph while a wider part of the same class falls back to a box
test "kicad-sch: synth draws the glyph for two pads and falls back to a box beyond that" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const two = [_][]const u8{ "1", "2" };
    const small = try synth(a, .{
        .names = .{ .component = "cap-0402" },
        .project_dir = "/nonexistent",
        .fp_pads = &two,
        .glyph = .capacitor,
    });
    // The real Device:C body, and its pin text hidden the way stock passives
    // hide theirs.
    try testing.expect(small.units[0].graphics.len > 0);
    try testing.expect(small.hide_pin_text);
    try testing.expectEqual(Side.left, small.units[0].pins[0].side);
    try testing.expectEqual(Side.right, small.units[0].pins[1].side);

    // Three pads is not a capacitor symbol whatever the ref-des says, so the
    // box comes back — and at full size, not the two-pin compact one.
    const three = [_][]const u8{ "1", "2", "3" };
    const big = try synth(a, .{
        .names = .{ .component = "trio" },
        .project_dir = "/nonexistent",
        .fp_pads = &three,
        .glyph = .capacitor,
    });
    try testing.expectEqual(@as(usize, 0), big.units[0].graphics.len);
    try testing.expect(!big.hide_pin_text);
    try testing.expect(big.units[0].half_w > compact_half_w);
}

// spec: export_kicad_sch - Same-net pads are drawn side by side on their edge and drop their function names, so the edge can be ganged under one label
test "kicad-sch: synth orders an edge by net and mutes the names it gangs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/pinouts/hub.sexp",
        .data =
        \\(pinout "hub"
        \\  (pin 1 "VSS_1") (pin 2 "VSS_2") (pin 3 "VSSA") (pin 4 "VSS_3") (pin 5 "PA0"))
        ,
    });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);

    // Pads 1, 2 and 4 share GND; pad 3 is a ground pad on a rail of its own.
    var nets: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer nets.deinit(a);
    try nets.put(a, "1", "GND");
    try nets.put(a, "2", "GND");
    try nets.put(a, "3", "VSSA_REF");
    try nets.put(a, "4", "GND");
    try nets.put(a, "5", "SIG");

    const shape = try synth(a, .{
        .names = .{ .component = "hub", .pinout = "hub" },
        .project_dir = dir,
        .nets = &nets,
    });
    const pins = shape.units[0].pins;
    // All four grounds land on the bottom edge; the three on GND now sit side
    // by side, so pad 4 is next to pad 2 and pad 3 is pushed past them.
    try testing.expectEqual(@as(i32, 0), pins[0].y - pins[1].y);
    const gnd_run = [_]usize{ 0, 1, 3 };
    for (gnd_run) |i| {
        try testing.expect(!pins[i].show_name);
        try testing.expectEqual(Side.bottom, pins[i].side);
    }
    // The lone rail keeps its name, and so does the signal pin.
    try testing.expect(pins[2].show_name);
    try testing.expect(pins[4].show_name);
    // Adjacency is what a gang needs: the three GND pads occupy consecutive
    // slots along the edge, with the odd one out beyond them.
    const step = @abs(pins[0].x - pins[1].x);
    try testing.expectEqual(step, @abs(pins[1].x - pins[3].x));
    try testing.expect(@abs(pins[3].x - pins[2].x) == step);

    // Without a net map nothing is reordered and every name is drawn.
    const plain = try synth(a, .{ .names = .{ .component = "hub", .pinout = "hub" }, .project_dir = dir });
    try testing.expect(allNamed(plain.units[0]));
}

fn allNamed(u: Unit) bool {
    for (u.pins) |p| {
        if (!p.show_name) return false;
    }
    return true;
}

// spec: export_kicad_sch - A pin whose function name only repeats its own pad number draws the number alone
test "kicad-sch: a pin named after its own pad does not draw the name as well" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    // A connector pinout, which names every contact after its own contact
    // number — except one that carries a real function.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/pinouts/conn.sexp",
        .data =
        \\(pinout "conn"
        \\  (pin 1 "1") (pin 2 "2") (pin 3 "SHIELD"))
        ,
    });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);

    const shape = try synth(a, .{ .names = .{ .component = "conn", .pinout = "conn" }, .project_dir = dir });
    const pins = shape.units[0].pins;
    try testing.expect(!pins[0].show_name);
    try testing.expect(!pins[1].show_name);
    try testing.expect(pins[2].show_name);
    // The name is still in the shape — only its drawing is dropped, so KiCad's
    // exported `pinfunction` is unchanged.
    try testing.expectEqualStrings("1", pins[0].name);
    try testing.expect(namesPad(.{ .pad = "A7", .name = "A7" }));
    try testing.expect(!namesPad(.{ .pad = "7", .name = "VDD" }));
}

// spec: export_kicad_sch - A pin is drawn long enough to hold its own pad number, which KiCad straddles across it
test "kicad-sch: a wide pad id lengthens its pin so the number clears the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const short = [_][]const u8{ "1", "2", "3" };
    const small = try synth(a, .{ .names = .{ .component = "s" }, .project_dir = "/nonexistent", .fp_pads = &short });
    try testing.expectEqual(pin_len, small.units[0].pins[0].len);

    // A BGA's three-character pad needs three grid steps of pin under it.
    const bga = [_][]const u8{ "A11", "H14", "P3" };
    const big = try synth(a, .{ .names = .{ .component = "b" }, .project_dir = "/nonexistent", .fp_pads = &bga });
    try testing.expectEqual(@as(i32, 3 * grid), big.units[0].pins[0].len);
    // And the reported reach follows the pins, which is what sizes the cell.
    try testing.expectEqual(@as(i32, 3 * grid), maxReach(big.units[0]));
    try testing.expectEqual(pin_len, maxReach(small.units[0]));
}

// spec: export_kicad_sch - A component name that is not a legal KiCad lib_id token is sanitized
test "kicad-sch: sanitizeLibName replaces separator characters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("res-0402", try sanitizeLibName(a, "res-0402"));
    try testing.expectEqualStrings("a_b_c", try sanitizeLibName(a, "a:b/c"));
    try testing.expectEqualStrings("UNNAMED", try sanitizeLibName(a, ""));
}
