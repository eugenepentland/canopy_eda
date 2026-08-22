//! Serialiser for one `.kicad_sch` file — a root sheet or one of its children.
//!
//! Takes a fully resolved `Doc` — synthesised library symbols, placed parts at
//! grid coordinates, and the net name each pin carries — and writes the KiCad
//! 10 s-expression text. It makes no decisions: placement, pad sets, and net
//! spelling are settled by the caller, so the same `Doc` always renders the
//! same bytes.
//!
//! Connectivity is label-based. Every connected pin gets a short wire stub
//! ending in a `(global_label …)` carrying the flattened net name verbatim;
//! every unconnected pad gets a `(no_connect …)` so KiCad's ERC stays quiet.
//! Global labels only — a local label would be rewritten with a sheet-path
//! prefix and break the identity contract with the netlist exporter, and a
//! global label joins across hierarchical sheets with no prefix at all.
//!
//! Ground pins are the one exception: they carry a `power_in` rail symbol
//! instead of a label, which is what an engineer expects to see and what keeps
//! a busy sheet readable. A rail symbol names its net through its *Value*
//! property, and each rail needs one `power_out` driver (a PWR_FLAG) somewhere
//! in the hierarchy or KiCad's ERC reports `power_pin_not_driven`.

const std = @import("std");
const draw = @import("../render_svg/draw.zig");
const env_mod = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const kicad_sym = @import("../kicad_sym/reader.zig");
const plan_mod = @import("plan.zig");
const sheet_mod = @import("sheet.zig");
const shape_mod = @import("shape.zig");
const wire_mod = @import("wire.zig");

const Writer = std.Io.Writer;
const Shape = shape_mod.Shape;
const Side = shape_mod.Side;

/// KiCad 10.0.1's native schematic file epoch (see the Phase-0 format spike):
/// a file at this version loads without a migration pass, and a newer epoch is
/// rejected outright.
pub const file_version = "20260306";

/// Wire-stub length from a pin's connection point to its label (2.54 mm).
pub const stub_len: i32 = 254;

/// Library name of the PWR_FLAG driver symbol, and the reference prefix KiCad
/// uses to keep such helpers out of the netlist's component list.
pub const flag_lib_name = "PWR_FLAG";

/// How far past a power symbol's connection point its Reference and Value are
/// anchored, along the direction its body hangs in.
pub const text_reach: i32 = 635;

/// Sheet space one character of a net label takes, plus the gap KiCad leaves
/// between the connection point and the first glyph. Both are measured off its
/// own rendering at the 1.27 mm every label is drawn at: `VDDCORE` plots
/// 8.85 mm and its arrow head 1.43 mm.
const label_char_width: i32 = shape_mod.grid;
const label_lead: i32 = 143;
/// Longest label allowed to reserve space, so one deep hierarchical net name
/// cannot stretch a page.
const max_label_span: i32 = 5080;

/// True when a net is drawn as a power symbol instead of a net label. Uses the
/// renderer's own ground-rail predicate — no sixth power heuristic — applied to
/// the leaf of a sub-block path so a module's private ground counts too (its
/// symbol still carries the full, distinct net name).
pub fn isRailNet(name: []const u8) bool {
    return draw.isGroundNet(draw.shortNetName(name));
}

/// How far outward from a pin its net label (or ground symbol) reaches. The
/// sheet reserves this beside each edge, and a symbol's own Reference and Value
/// are anchored past it — so the two rules have to be the same one.
pub fn labelSpan(net: []const u8) i32 {
    if (net.len == 0) return 0;
    // A rail-carried pin needs the ground symbol's own reach instead: its body
    // hangs a stub beyond the pin and its Value is written past that, so
    // budgeting three characters of label put `GND` into the next cell.
    if (isRailNet(net)) return sheet_mod.snapUp(text_reach + label_char_width);
    const raw: i32 = @intCast(@min(net.len, @as(usize, @intCast(max_label_span / label_char_width))));
    return sheet_mod.snapUp(label_lead + raw * label_char_width);
}

/// Glyph height of the sheet's own title, above every band heading on it — the
/// page is named once, and larger, so the two never read as one repeated line.
pub const title_size: i32 = 381;

/// netlisp's property key for a manufacturer part number, and the KiCad field
/// name it is written under.
const mpn_key = "mpn";
const mpn_field = "MPN";

/// How far BELOW a symbol's Value its part number is anchored — one clear line
/// of air under it, which is where KiCad's own field stacking puts a third
/// field.
pub const mpn_drop: i32 = 2 * shape_mod.grid;

/// Longest part number allowed to reserve space, so one pathological MPN cannot
/// stretch a cell across the page.
const max_mpn_chars: usize = 40;

/// The part number a placed symbol DISPLAYS, or null when it shows none.
///
/// A hub is read for its part number — it is the one thing a reviewer cannot
/// infer from the drawing — so it goes on the sheet beside the reference and the
/// value. A PASSIVE is the other way round: `100nF` already is its identity, and
/// `GRM155R71C104KA88D` printed under all fifty bypass caps would be noise. The
/// split is the exporter's own hub/passive one (`kicad_sch/plan.zig`), the same
/// rule that decides which parts head a cluster — not a sixth ref-des heuristic.
pub fn shownMpn(id: Identity) ?[]const u8 {
    if (plan_mod.isPassiveRef(id.ref)) return null;
    for (id.properties) |prop| {
        if (!std.mem.eql(u8, prop.key, mpn_key)) continue;
        return if (prop.value.len == 0) null else prop.value;
    }
    return null;
}

/// Half the sheet space a displayed part number takes. It is centred on the
/// symbol's origin like the Reference and Value above it, so a cell has to hold
/// this much on BOTH sides or a long MPN runs into the next cell's text.
pub fn mpnHalfSpan(text: []const u8) i32 {
    const n: i32 = @intCast(@min(text.len, max_mpn_chars));
    return sheet_mod.snapUp(@divTrunc(n * label_char_width, 2));
}

/// How far right of a ganged part's body its Reference and Value are anchored.
/// A decoupling bank's column pitch is sized around this, so the two must agree
/// or a member's text runs into its neighbour.
pub const banked_text_dx: i32 = 254;

const font_effects = "(effects (font (size 1.27 1.27)))";
const hidden_font_effects = "(hide yes) (effects (font (size 1.27 1.27)))";
/// The size everything on these sheets is drawn at, in hundredths.
const font_size: i32 = 127;
/// Coarsest step a shrunk pin text is quantised to, and the floor it never goes
/// below — 0.5 mm still reads at KiCad's default zoom.
const size_step: i32 = 10;
const min_pin_text: i32 = 50;
const lib_prefix = "netlisp:";
const power_flags = "\t\t(exclude_from_sim no)\n\t\t(in_bom no)\n\t\t(on_board no)\n\t\t(dnp no)\n";

/// BOM-visible identity of one placed part. `footprint` is the KiCad library
/// spelling (`footprints:<name>`) the netlist exporter uses, already resolved.
pub const Identity = struct {
    ref: []const u8,
    value: []const u8,
    footprint: []const u8,
    properties: []const env_mod.Property,
    /// Stable instance UUID — the same one the netlist's `(tstamp …)` and the
    /// board's footprint carry, so schematic identity matches the board's.
    uuid: []const u8,
    dnp: bool = false,
};

/// One placed symbol unit: which shape and unit it draws, where its origin sits
/// (sheet coordinates, hundredths of a millimetre, y grows down), and the net
/// each of that unit's pins connects to (`""` = no connection -> a no-connect
/// flag). A multi-unit part contributes one `Part` per unit, all sharing the
/// reference but each with its own UUID.
///
/// `nets` is the net name as it will be WRITTEN, which for a per-pin
/// bypass-stub net is its base rail (see `kicad_sch/stub.zig`); the composer
/// keeps netlisp's own spelling for everything it reasons about.
pub const Part = struct {
    id: Identity,
    shape: u32,
    /// Index into `shapes[shape].units`.
    unit: u32,
    x: i32,
    y: i32,
    nets: []const []const u8,
    /// Rotation of a part ganged into a decoupling bank, which stands it on end
    /// between the bank's two rails. The bank draws both of its legs, so such a
    /// part carries no stub, no net label and no no-connect of its own. `null`
    /// for every ordinary part: upright, and label-connected pin by pin.
    banked: ?u32 = null,
};

/// A free-standing text label naming a placement group (a section or a
/// sub-block) above its band of symbols, or one decoupling bank above its rail.
pub const Caption = struct {
    text: []const u8,
    x: i32,
    y: i32,
    /// Glyph height in hundredths of a millimetre. A group heading is drawn at
    /// the default 2.54 mm; a bank's own caption is a subheading inside one, so
    /// it asks for less.
    size: i32 = 254,
};

/// A rectangle in sheet coordinates.
pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// One child sheet referenced from the root file.
pub const SheetRef = struct {
    name: []const u8,
    file: []const u8,
    uuid: []const u8,
    page: u32,
    at: Rect,
};

/// A power-rail library symbol. One entry per distinct rail name: the symbol's
/// Value property is what names the net, so the rails cannot share an entry.
pub const Rail = struct {
    lib_name: []const u8,
    net: []const u8,
};

/// A placed rail symbol standing in for a net label on one pin.
pub const RailPin = struct {
    /// Index into `Power.rails`.
    rail: u32,
    /// The `#PWR…` reference, unique across the whole hierarchy.
    ref: []const u8,
    uuid: []const u8,
    x: i32,
    y: i32,
    /// Rotation so the symbol's body points away from the pin it serves.
    angle: u32,
};

/// A `power_out` driver joined onto one rail. Without it KiCad's ERC reports
/// `power_pin_not_driven` for every `power_in` rail symbol on that net.
///
/// The flag's far end carries a **global label**, not a second rail symbol: a
/// power symbol does not count as a connection partner for the
/// `pin_not_connected` rule, so a flag facing one is reported as dangling even
/// while it drives the net. A label satisfies both rules at once.
pub const Flag = struct {
    /// Rail this flag drives; also the text of its global label.
    net: []const u8,
    ref: []const u8,
    uuid: []const u8,
    /// Sheet position of the label; the flag symbol sits one stub above it.
    x: i32,
    y: i32,
};

/// Everything power-symbol related on one sheet.
pub const Power = struct {
    rails: []const Rail = &.{},
    pins: []const RailPin = &.{},
    flags: []const Flag = &.{},
};

/// A global label that names a length of wire rather than a pin — the single
/// label a decoupling bank's rail carries in place of its members' per-pin
/// ones.
pub const FreeLabel = struct {
    net: []const u8,
    uuid: []const u8,
    x: i32,
    y: i32,
    /// Edge convention picking the label's angle and justification, exactly as
    /// a pin's own side does: `left` runs the text away to the left.
    side: Side,
};

/// The connections one sheet draws as real wire instead of a label pair.
///
/// A drawn run still carries exactly ONE global label — at its anchor's stub
/// end — because that label is what gives the run netlisp's own net name; drop
/// it and KiCad invents `Net-(U1-Pad3)` and the identity contract with the
/// netlist is gone. `no_label` names the stub ends of everything else on the
/// run, whose labels would only repeat it.
pub const Wiring = struct {
    paths: []const wire_mod.Path = &.{},
    /// Points where three or more wire ends meet and a dot must be drawn.
    junctions: []const wire_mod.Point = &.{},
    /// Stub ends a drawn wire makes the net label redundant at.
    no_label: []const wire_mod.Point = &.{},
    /// Labels that sit on drawn wire rather than on a pin's stub: one per
    /// decoupling bank, naming the rail its members are ganged onto.
    labels: []const FreeLabel = &.{},
};

/// Identity and page frame of one emitted file.
pub const Sheet = struct {
    design: []const u8,
    /// Drawn at the top of the sheet; the section or module this file holds.
    title: []const u8 = "",
    /// UUID of the ROOT file — the first segment of every instance path.
    root_uuid: []const u8,
    /// This file's own UUID. Equal to `root_uuid` on the root file.
    sheet_uuid: []const u8,
    /// Page extents in hundredths of a millimetre.
    page_w: i32,
    page_h: i32,
    /// Only the root carries `(sheet_instances …)` and the `(sheet …)` blocks.
    is_root: bool = true,
};

/// The complete sheet, ready to serialise.
pub const Doc = struct {
    sheet: Sheet,
    shapes: []const Shape,
    parts: []const Part,
    captions: []const Caption = &.{},
    power: Power = .{},
    wiring: Wiring = .{},
    children: []const SheetRef = &.{},
};

/// Errors the serialiser can raise: allocation of the output buffer plus the
/// writer's own failure mode.
pub const EmitError = std.mem.Allocator.Error || Writer.Error;

/// How a library entry spells its own `(symbol …)` name. Inside a sheet's
/// `(lib_symbols …)` block the name is the full lib_id (`netlisp:res-0402`),
/// which is what the placed symbols reference. Inside a standalone
/// `.kicad_sym` file it is bare (`res-0402`) — there the library's name comes
/// from the `sym-lib-table` row pointing at the file, and a colon in the
/// symbol name would make the lib_id unresolvable.
pub const Naming = enum { lib_id, bare };

/// KiCad 10.0.1's native symbol-library epoch — the version its own
/// `/usr/share/kicad/symbols/*.kicad_sym` carry.
pub const symbol_lib_version = "20251024";

/// Render the standalone `netlisp.kicad_sym` holding every symbol the exported
/// sheets place: the component shapes, one entry per ground rail, and the
/// PWR_FLAG driver (emitted unconditionally so the library does not change
/// shape with the design's rails). Same writers the sheets use, so a library
/// entry can never drift from the `(lib_symbols …)` copy KiCad compares it
/// against — a mismatch is exactly what `lib_symbol_issues` reports.
pub fn libraryFile(
    arena: std.mem.Allocator,
    shapes: []const Shape,
    rails: []const Rail,
) EmitError![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("(kicad_symbol_lib\n\t(version " ++ symbol_lib_version ++ ")\n");
    try w.writeAll("\t(generator \"netlisp\")\n\t(generator_version \"10.0\")\n");
    for (shapes) |s| try libSymbol(w, s, .bare);
    for (rails) |r| try railSymbol(w, r, .bare);
    try flagSymbol(w, .bare);
    try w.writeAll(")\n");
    return out.toOwnedSlice();
}

/// Render `doc` to `.kicad_sch` bytes. Scratch allocations (UUID strings,
/// escaped text) come from `arena`; the returned slice is owned by `arena` too.
pub fn render(arena: std.mem.Allocator, doc: Doc) EmitError![]u8 {
    var out: Writer.Allocating = .init(arena);
    const w = &out.writer;

    try header(w, doc);
    try w.writeAll("\t(lib_symbols\n");
    for (doc.shapes) |s| try libSymbol(w, s, .lib_id);
    for (doc.power.rails) |r| try railSymbol(w, r, .lib_id);
    if (doc.power.flags.len > 0) try flagSymbol(w, .lib_id);
    try w.writeAll("\t)\n");

    if (doc.sheet.title.len > 0) {
        try caption(arena, w, doc.sheet.design, .{
            .text = doc.sheet.title,
            .x = 1270,
            .y = 1016,
            .size = title_size,
        }, "title");
    }
    for (doc.captions, 0..) |c, i| {
        try caption(arena, w, doc.sheet.design, c, try std.fmt.allocPrint(arena, "{d}", .{i}));
    }
    for (doc.parts) |p| try placedSymbol(arena, w, doc, p);
    for (doc.parts) |p| try connections(arena, w, doc, p);
    for (doc.wiring.paths) |path| try routedWire(arena, w, doc.sheet.design, path);
    for (doc.wiring.labels) |fl| try globalLabel(w, fl.net, fl.uuid, fl.side, .{ fl.x, fl.y });
    for (doc.wiring.junctions) |pt| try junction(arena, w, doc.sheet.design, pt);
    for (doc.power.pins) |rp| try railInstance(arena, w, doc, rp);
    for (doc.power.flags) |f| try flagInstance(arena, w, doc, f);
    for (doc.children) |c| try childSheet(arena, w, doc, c);

    if (doc.sheet.is_root) {
        try w.writeAll("\t(sheet_instances\n\t\t(path \"/\"\n\t\t\t(page \"1\")\n\t\t)\n\t)\n");
    }
    try w.writeAll("\t(embedded_fonts no)\n)\n");
    return out.toOwnedSlice();
}

fn header(w: *Writer, doc: Doc) EmitError!void {
    try w.writeAll("(kicad_sch\n\t(version " ++ file_version ++ ")\n");
    try w.writeAll("\t(generator \"netlisp\")\n\t(generator_version \"10.0\")\n");
    try w.print("\t(uuid \"{s}\")\n", .{doc.sheet.sheet_uuid});
    try w.writeAll("\t(paper \"User\" ");
    try mm(w, doc.sheet.page_w);
    try w.writeByte(' ');
    try mm(w, doc.sheet.page_h);
    try w.writeAll(")\n");
}

/// Deterministic UUID for a non-instance element (wire, label, no-connect,
/// caption, the sheet itself). Hashing a stable element path means re-exporting
/// an unchanged design produces byte-identical output.
pub fn elementUuid(
    arena: std.mem.Allocator,
    design: []const u8,
    kind: []const u8,
    path: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const id = try std.fmt.allocPrint(arena, "sch:{s}:{s}:{s}", .{ design, kind, path });
    return export_kicad.uuidFromId(arena, id);
}

/// The hierarchical path a placed symbol's instance record lives under: the
/// root sheet's UUID, plus this sheet's own UUID when the file is a child.
fn instancePath(arena: std.mem.Allocator, s: Sheet) std.mem.Allocator.Error![]const u8 {
    if (s.is_root) return std.fmt.allocPrint(arena, "/{s}", .{s.root_uuid});
    return std.fmt.allocPrint(arena, "/{s}/{s}", .{ s.root_uuid, s.sheet_uuid });
}

/// Write a coordinate in millimetres. Values are integer hundredths, so the
/// printed decimal is exact — never a float artefact like `-15.239999999`.
fn mm(w: *Writer, v: i32) Writer.Error!void {
    if (v < 0) try w.writeByte('-');
    const a: u32 = @abs(v);
    const whole = a / 100;
    const frac = a % 100;
    if (frac == 0) {
        try w.print("{d}", .{whole});
    } else if (frac % 10 == 0) {
        try w.print("{d}.{d}", .{ whole, frac / 10 });
    } else {
        try w.print("{d}.{d:0>2}", .{ whole, frac });
    }
}

/// Reader units per emitted hundredth of a millimetre. A vendor symbol's
/// geometry is ten-thousandths; everything the exporter places is hundredths.
const per_hundredth: i32 = @divExact(kicad_sym.per_mm, 100);

/// Write a length in millimetres from ten-thousandths — the unit a vendor
/// symbol's own geometry is carried in, so its sub-hundredth coordinates print
/// exactly. Trailing zeros are trimmed: 25400 is `2.54`, 8466 is `0.8466`.
fn mm4(w: *Writer, v: i32) Writer.Error!void {
    if (v < 0) try w.writeByte('-');
    const a: u32 = @abs(v);
    const whole = a / @as(u32, @intCast(kicad_sym.per_mm));
    var frac = a % @as(u32, @intCast(kicad_sym.per_mm));
    if (frac == 0) return w.print("{d}", .{whole});
    var digits: usize = 4;
    while (frac % 10 == 0) : (digits -= 1) frac /= 10;
    switch (digits) {
        1 => try w.print("{d}.{d:0>1}", .{ whole, frac }),
        2 => try w.print("{d}.{d:0>2}", .{ whole, frac }),
        3 => try w.print("{d}.{d:0>3}", .{ whole, frac }),
        else => try w.print("{d}.{d:0>4}", .{ whole, frac }),
    }
}

/// Write `s` as a quoted KiCad string with `"` and `\` escaped.
fn str(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

/// `(at X Y ANGLE)` — KiCad rejects the two-value form on a placed symbol, so
/// the angle is always written.
fn at(w: *Writer, x: i32, y: i32, angle: u32) Writer.Error!void {
    try w.writeAll("(at ");
    try mm(w, x);
    try w.writeByte(' ');
    try mm(w, y);
    try w.print(" {d})", .{angle});
}

/// Open one library entry: `\t\t(symbol "<name>"` with the `netlisp:` lib
/// prefix in a sheet's `(lib_symbols …)` block and without it in a standalone
/// `.kicad_sym`. The caller continues on the same line.
fn entryName(w: *Writer, lib_name: []const u8, naming: Naming) Writer.Error!void {
    try w.writeAll("\t\t(symbol \"");
    if (naming == .lib_id) try w.writeAll(lib_prefix);
    try w.writeAll(lib_name);
    try w.writeByte('"');
}

/// The library entry for one synthesised shape: one `(rectangle …)` body plus
/// one `passive` pin per pad, per unit. Every pin is `passive` on purpose — a
/// typed `input` pin raises a `pin_not_driven` ERC error on a label-connected
/// schematic.
fn libSymbol(w: *Writer, s: Shape, naming: Naming) Writer.Error!void {
    try entryName(w, s.lib_name, naming);
    // A stock passive glyph hides its pin numbers and names, as KiCad's own
    // Device symbols do: "1"/"2" written on both ends of every resistor is
    // clutter, and the pad numbers are still in the file for the netlist.
    if (s.hide_pin_text) {
        try w.writeAll("\n\t\t\t(pin_numbers (hide yes))\n\t\t\t(pin_names (offset 0) (hide yes))\n");
    } else {
        try w.writeAll("\n\t\t\t(pin_names (offset 0.254))\n");
    }
    try w.writeAll("\t\t\t(exclude_from_sim no)\n\t\t\t(in_bom yes)\n\t\t\t(on_board yes)\n");
    try w.writeAll("\t\t\t(property \"Reference\" \"U\" (at 0 0 0) " ++ font_effects ++ ")\n");
    try w.writeAll("\t\t\t(property \"Value\" ");
    try str(w, s.lib_name);
    try w.writeAll(" (at 0 0 0) " ++ font_effects ++ ")\n");
    try w.writeAll("\t\t\t(property \"Footprint\" \"\" (at 0 0 0) " ++ hidden_font_effects ++ ")\n");
    try w.writeAll("\t\t\t(property \"Datasheet\" \"\" (at 0 0 0) " ++ hidden_font_effects ++ ")\n");
    for (s.units) |u| try libUnit(w, s.lib_name, u);
    try w.writeAll("\t\t\t(embedded_fonts no)\n\t\t)\n");
}

fn libUnit(w: *Writer, lib_name: []const u8, u: shape_mod.Unit) Writer.Error!void {
    try w.writeAll("\t\t\t(symbol \"");
    try w.writeAll(lib_name);
    try w.print("_{d}_1\"\n", .{u.number});
    if (u.graphics.len == 0) {
        try synthBody(w, u);
    } else {
        for (u.graphics) |g| try vendorBody(w, g);
    }
    for (u.pins, 0..) |p, i| try libPin(w, p, pinTextSize(u, i));
    try w.writeAll("\t\t\t)\n");
}

/// The size a pin's own name and number are drawn at: the standard 1.27 mm,
/// unless its edge packs its pins closer than that text fits. KiCad straddles a
/// pin's number across the pin and writes its name in from the body end, both on
/// the row the pin sits on — so on the 1.27 mm pitch a fine-pitch connector
/// draws its pins at, forty numbers at full size come out as one vertical smear.
/// Two thirds of the spacing leaves the fifth-of-a-size gap KiCad puts between
/// the pin and its number, plus as much again of air below it.
fn pinTextSize(u: shape_mod.Unit, i: usize) i32 {
    const gap = edgeSpacing(u, i) orelse return font_size;
    const fits = @divTrunc(@divTrunc(2 * gap, 3), size_step) * size_step;
    return @max(min_pin_text, @min(font_size, fits));
}

/// How close the nearest other pin on the same edge comes to pin `i`, measured
/// along that edge. Null when the pin has the edge to itself.
fn edgeSpacing(u: shape_mod.Unit, i: usize) ?i32 {
    var out: ?i32 = null;
    for (u.pins, 0..) |p, k| {
        if (k == i or p.side != u.pins[i].side) continue;
        const d: i32 = @intCast(@abs(alongEdge(p, p.side) - alongEdge(u.pins[i], p.side)));
        if (d == 0) continue;
        out = @min(out orelse d, d);
    }
    return out;
}

/// The coordinate that varies along an edge: a left or right edge runs in y, a
/// top or bottom edge in x.
fn alongEdge(p: shape_mod.Pin, side: Side) i32 {
    return switch (side) {
        .left, .right => p.y,
        .top, .bottom => p.x,
    };
}

/// The synthesised body: one rectangle around the origin.
fn synthBody(w: *Writer, u: shape_mod.Unit) Writer.Error!void {
    try w.writeAll("\t\t\t\t(rectangle (start ");
    try mm(w, -u.half_w);
    try w.writeByte(' ');
    try mm(w, u.half_h);
    try w.writeAll(") (end ");
    try mm(w, u.half_w);
    try w.writeByte(' ');
    try mm(w, -u.half_h);
    try w.writeAll(")\n\t\t\t\t\t(stroke (width 0.254) (type default)) (fill (type background)))\n");
}

fn libPin(w: *Writer, p: shape_mod.Pin, size: i32) Writer.Error!void {
    try w.writeAll("\t\t\t\t(pin passive line ");
    try at(w, p.x, p.y, pinAngle(p.side));
    try w.writeAll(" (length ");
    try mm(w, p.len);
    try w.writeAll(")\n\t\t\t\t\t(name ");
    try str(w, p.name);
    // A ganged pin's name is not drawn, and a ZERO FONT SIZE is the only
    // spelling KiCad 10.0.1 honours for that: `(hide yes)` inside a pin's name
    // effects parses and is then ignored by the renderer, and an empty name
    // drops the pad's `pinfunction` from KiCad's exported netlist. Measured on
    // kicad-cli 10.0.1; a load/save round trip leaves the zero size alone.
    try pinTextEffects(w, if (p.show_name) size else 0);
    try w.writeAll(")\n\t\t\t\t\t(number ");
    try str(w, p.pad);
    try pinTextEffects(w, size);
    try w.writeAll(")\n\t\t\t\t)\n");
}

fn pinTextEffects(w: *Writer, size: i32) Writer.Error!void {
    try w.writeAll(" (effects (font (size ");
    try mm(w, size);
    try w.writeByte(' ');
    try mm(w, size);
    try w.writeAll(")))");
}

/// One item of a vendor symbol's own drawn body, re-emitted from the parsed
/// model rather than spliced from the source file — the vendor's format epoch
/// is not necessarily the one this exporter writes.
fn vendorBody(w: *Writer, g: kicad_sym.Graphic) Writer.Error!void {
    switch (g.kind) {
        .rectangle => try namedPts(w, g, &.{ "rectangle", "start", "end" }),
        .arc => try namedPts(w, g, &.{ "arc", "start", "mid", "end" }),
        .polyline => try polyline(w, g),
        .circle => try circle(w, g),
        .text => try symbolText(w, g),
    }
}

/// `(<form> (<name> X Y) … (stroke …) (fill …))` — the shape of a rectangle
/// and an arc alike; `spec[0]` is the form, the rest name its points in order.
fn namedPts(w: *Writer, g: kicad_sym.Graphic, spec: []const []const u8) Writer.Error!void {
    try w.print("\t\t\t\t({s}", .{spec[0]});
    for (g.pts, spec[1..]) |p, name| {
        try w.print(" ({s} ", .{name});
        try mm4(w, p.x);
        try w.writeByte(' ');
        try mm4(w, p.y);
        try w.writeByte(')');
    }
    try styleOf(w, g.style);
}

fn polyline(w: *Writer, g: kicad_sym.Graphic) Writer.Error!void {
    try w.writeAll("\t\t\t\t(polyline (pts");
    for (g.pts) |p| {
        try w.writeAll(" (xy ");
        try mm4(w, p.x);
        try w.writeByte(' ');
        try mm4(w, p.y);
        try w.writeByte(')');
    }
    try w.writeByte(')');
    try styleOf(w, g.style);
}

fn circle(w: *Writer, g: kicad_sym.Graphic) Writer.Error!void {
    try w.writeAll("\t\t\t\t(circle (center ");
    try mm4(w, g.pts[0].x);
    try w.writeByte(' ');
    try mm4(w, g.pts[0].y);
    try w.writeAll(") (radius ");
    try mm4(w, g.radius);
    try w.writeByte(')');
    try styleOf(w, g.style);
}

fn symbolText(w: *Writer, g: kicad_sym.Graphic) Writer.Error!void {
    try w.writeAll("\t\t\t\t(text ");
    try str(w, g.text);
    try w.writeByte(' ');
    // The anchor is grid-snapped upstream, so hundredths lose nothing here —
    // and it stays inside the self-check's grid scan, unlike the rest of a
    // vendor body.
    try at(
        w,
        @divTrunc(g.pts[0].x, per_hundredth),
        @divTrunc(g.pts[0].y, per_hundredth),
        @intCast(@mod(g.angle, 360)),
    );
    try w.writeAll(" " ++ font_effects ++ ")\n");
}

fn styleOf(w: *Writer, s: kicad_sym.Style) Writer.Error!void {
    try w.writeAll("\n\t\t\t\t\t(stroke (width ");
    try mm4(w, s.width);
    try w.print(") (type default)) (fill (type {s})))\n", .{@tagName(s.fill)});
}

/// Library entry for one power rail. Two rails cannot share an entry: the
/// symbol's Value property is what names the net, and the pin must be
/// `power_in` or the symbol stops naming the net at all.
fn railSymbol(w: *Writer, r: Rail, naming: Naming) Writer.Error!void {
    try entryName(w, r.lib_name, naming);
    try w.writeAll("\n\t\t\t(power global)\n\t\t\t(pin_numbers (hide yes))\n");
    try w.writeAll("\t\t\t(pin_names (offset 0) (hide yes))\n");
    try w.writeAll("\t\t\t(exclude_from_sim no)\n\t\t\t(in_bom no)\n\t\t\t(on_board no)\n");
    try w.writeAll("\t\t\t(property \"Reference\" \"#PWR\" (at 0 -6.35 0) " ++ hidden_font_effects ++ ")\n");
    try w.writeAll("\t\t\t(property \"Value\" ");
    try str(w, r.net);
    try w.writeAll(" (at 0 -3.81 0) " ++ font_effects ++ ")\n");
    try w.writeAll("\t\t\t(property \"Footprint\" \"\" (at 0 0 0) " ++ hidden_font_effects ++ ")\n");
    try w.writeAll("\t\t\t(property \"Datasheet\" \"\" (at 0 0 0) " ++ hidden_font_effects ++ ")\n");
    try w.writeAll("\t\t\t(symbol \"");
    try w.writeAll(r.lib_name);
    try w.writeAll("_0_1\"\n\t\t\t\t(polyline (pts (xy 0 0) (xy 0 -1.27) (xy 1.27 -1.27)" ++
        " (xy 0 -2.54) (xy -1.27 -1.27) (xy 0 -1.27))\n" ++
        "\t\t\t\t\t(stroke (width 0) (type default)) (fill (type none)))\n\t\t\t)\n");
    try w.writeAll("\t\t\t(symbol \"");
    try w.writeAll(r.lib_name);
    try w.writeAll("_1_1\"\n\t\t\t\t(pin power_in line (at 0 0 270) (length 0)\n" ++
        "\t\t\t\t\t(name \"\" " ++ font_effects ++ ")\n" ++
        "\t\t\t\t\t(number \"1\" " ++ font_effects ++ ")\n\t\t\t\t)\n\t\t\t)\n");
    try w.writeAll("\t\t\t(embedded_fonts no)\n\t\t)\n");
}

/// Library entry for the PWR_FLAG driver. Its pin is `power_out`, which drives
/// the rail without naming it — the rail symbol beside it keeps the name.
fn flagSymbol(w: *Writer, naming: Naming) Writer.Error!void {
    try entryName(w, flag_lib_name, naming);
    try w.writeAll("\n\t\t\t(power global)\n\t\t\t(pin_numbers (hide yes))\n");
    try w.writeAll("\t\t\t(pin_names (offset 0) (hide yes))\n");
    try w.writeAll("\t\t\t(exclude_from_sim no)\n\t\t\t(in_bom no)\n\t\t\t(on_board no)\n");
    try w.writeAll("\t\t\t(property \"Reference\" \"#FLG\" (at 0 2.54 0) " ++ hidden_font_effects ++ ")\n");
    try w.writeAll("\t\t\t(property \"Value\" \"" ++ flag_lib_name ++ "\" (at 0 3.81 0) " ++ font_effects ++ ")\n");
    try w.writeAll("\t\t\t(property \"Footprint\" \"\" (at 0 0 0) " ++ hidden_font_effects ++ ")\n");
    try w.writeAll("\t\t\t(property \"Datasheet\" \"\" (at 0 0 0) " ++ hidden_font_effects ++ ")\n");
    try w.writeAll("\t\t\t(symbol \"" ++ flag_lib_name ++ "_0_1\"\n" ++
        "\t\t\t\t(polyline (pts (xy 0 0) (xy 0 1.27) (xy -1.27 2.54) (xy 0 3.81)" ++
        " (xy 1.27 2.54) (xy 0 1.27))\n" ++
        "\t\t\t\t\t(stroke (width 0) (type default)) (fill (type none)))\n\t\t\t)\n");
    try w.writeAll("\t\t\t(symbol \"" ++ flag_lib_name ++ "_1_1\"\n" ++
        "\t\t\t\t(pin power_out line (at 0 0 90) (length 0)\n" ++
        "\t\t\t\t\t(name \"pwr\" " ++ font_effects ++ ")\n" ++
        "\t\t\t\t\t(number \"1\" " ++ font_effects ++ ")\n\t\t\t\t)\n\t\t\t)\n");
    try w.writeAll("\t\t\t(embedded_fonts no)\n\t\t)\n");
}

/// Library-pin angle: it points from the connection endpoint back toward the
/// symbol body, so a left-edge pin is 0 and a right-edge pin is 180.
fn pinAngle(side: Side) u32 {
    return switch (side) {
        .left => 0,
        .right => 180,
        .top => 270,
        .bottom => 90,
    };
}

/// Sheet position of a pin: library coordinates are y-UP about the symbol
/// origin, the sheet is y-DOWN.
fn pinPoint(p: Part, pin: shape_mod.Pin) [2]i32 {
    return .{ p.x + pin.x, p.y - pin.y };
}

/// Where a pin's net label (or rail symbol) sits: `reach` outward from the pin.
/// That is one stub length for every pin on a symbol whose edges are roomy
/// enough, and a stub plus one column offset for a pin the label spreading
/// pushed into the far column (`stubReach`).
pub fn labelPoint(x: i32, y: i32, side: Side, reach: i32) [2]i32 {
    return switch (side) {
        .left => .{ x - reach, y },
        .right => .{ x + reach, y },
        .top => .{ x, y - reach },
        .bottom => .{ x, y + reach },
    };
}

/// How far pin `i` of `u` holds its label out from its own connection point.
pub fn stubReach(u: shape_mod.Unit, i: usize) i32 {
    return stub_len + shape_mod.stubExtra(u, i);
}

/// Global-label angle for a pin's edge, and the justification that mirrors it.
/// KiCad does not auto-flip label text: get this wrong and the net name is
/// drawn back across the symbol body.
fn labelAngle(side: Side) u32 {
    return switch (side) {
        .left => 180,
        .right => 0,
        .top => 90,
        .bottom => 270,
    };
}

fn labelJustify(side: Side) []const u8 {
    return switch (side) {
        .left, .bottom => "right",
        .right, .top => "left",
    };
}

/// Rotation of a rail symbol so its body hangs away from the pin it serves.
/// The library graphic points down; KiCad rotates counter-clockwise in the
/// library's y-up frame, so a right-hand stub needs a quarter turn.
pub fn railAngle(side: Side) u32 {
    return switch (side) {
        .bottom => 0,
        .right => 90,
        .top => 180,
        .left => 270,
    };
}

fn placedSymbol(arena: std.mem.Allocator, w: *Writer, doc: Doc, p: Part) EmitError!void {
    const s = doc.shapes[p.shape];
    const u = s.units[p.unit];
    try w.writeAll("\t(symbol (lib_id \"" ++ lib_prefix);
    try w.writeAll(s.lib_name);
    try w.writeAll("\") ");
    try at(w, p.x, p.y, p.banked orelse 0);
    try w.print(" (unit {d})\n\t\t(exclude_from_sim no)\n", .{u.number});
    // DNP keeps its pads on the board and in the netlist but leaves the BOM:
    // `(on_board no)` would delete the component from the netlist entirely.
    try w.print("\t\t(in_bom {s})\n\t\t(on_board yes)\n\t\t(dnp {s})\n", .{
        if (p.id.dnp) "no" else "yes",
        if (p.id.dnp) "yes" else "no",
    });
    try w.print("\t\t(uuid \"{s}\")\n", .{p.id.uuid});
    try namedProps(w, p, u);
    try hiddenProp(w, "Footprint", p.id.footprint, p.x, p.y);
    try extraProps(w, p, u);
    try instances(arena, w, doc.sheet, p.id.ref, u.number);
}

/// The Reference and Value a reader sees. An upright symbol carries them
/// centred above and below its body, as KiCad's own autoplacer does; a part
/// ganged into a decoupling bank stands on end between two rails with no room
/// either side of it, so both move to its right and read left-justified.
///
/// A ganged part's fields are written at **90 degrees** to come out horizontal.
/// KiCad does not draw a field at the angle stored on it: `GetDrawRotation`
/// swaps horizontal for vertical whenever the parent symbol is quarter-turned,
/// so a field left at 0 renders on its side, and both of a cap's fields then
/// run down the page through each other.
fn namedProps(w: *Writer, p: Part, u: shape_mod.Unit) Writer.Error!void {
    const ref_at = textAnchor(p, u, -1);
    const val_at = textAnchor(p, u, 1);
    const angle: u32 = if (p.banked == null) 0 else 90;
    const just = if (p.banked == null) "" else " (justify left)";
    try w.writeAll("\t\t(property \"Reference\" ");
    try str(w, p.id.ref);
    try w.writeByte(' ');
    try at(w, ref_at[0], ref_at[1], angle);
    try w.print(" (effects (font (size 1.27 1.27)){s}))\n", .{just});
    try w.writeAll("\t\t(property \"Value\" ");
    try str(w, p.id.value);
    try w.writeByte(' ');
    try at(w, val_at[0], val_at[1], angle);
    try w.print(" (effects (font (size 1.27 1.27)){s}))\n", .{just});
}

/// Where one of those two texts is anchored: `dir` is -1 for the Reference and
/// +1 for the Value, which puts them above/below an upright body and stacked to
/// the right of a ganged one.
///
/// Clear of the PINS, not just the body: KiCad straddles each pin's number
/// across the middle of its pin, so a reference two millimetres above the body
/// lands on the numbers of every pin leaving its top edge.
fn textAnchor(p: Part, u: shape_mod.Unit, dir: i32) [2]i32 {
    if (p.banked != null) return .{ p.x + banked_text_dx, p.y + dir * shape_mod.grid };
    return .{ p.x, p.y + dir * fieldReach(p, u) };
}

/// How far above (or below) its origin a symbol's Reference and Value sit:
/// clear of its own pins, of the numbers KiCad straddles across them, and of
/// the whole ring of net labels hanging off that edge. Anything nearer lands on
/// one of the three — a reference two millimetres above the body sits on the
/// pin numbers, and one just past the pins sits inside labels that run twenty
/// millimetres outward. This is the top of the cell the sheet packer reserved.
fn fieldReach(p: Part, u: shape_mod.Unit) i32 {
    var span: i32 = 0;
    for (u.pins, 0..) |pin, i| {
        if (pin.side == .left or pin.side == .right) continue;
        const net = if (i < p.nets.len) p.nets[i] else "";
        span = @max(span, shape_mod.stubExtra(u, i) + labelSpan(net));
    }
    return u.half_h + shape_mod.maxReach(u) + stub_len + span + shape_mod.pitch;
}

/// The `(instances …)` block binding a placed symbol to its reference and unit
/// under this file's hierarchical path.
fn instances(
    arena: std.mem.Allocator,
    w: *Writer,
    s: Sheet,
    ref: []const u8,
    unit: u32,
) EmitError!void {
    try w.writeAll("\t\t(instances\n\t\t\t(project ");
    try str(w, s.design);
    try w.writeAll("\n\t\t\t\t(path ");
    try str(w, try instancePath(arena, s));
    try w.writeAll("\n\t\t\t\t\t(reference ");
    try str(w, ref);
    try w.print(") (unit {d})\n\t\t\t\t)\n\t\t\t)\n\t\t)\n\t)\n", .{unit});
}

fn hiddenProp(w: *Writer, name: []const u8, value: []const u8, x: i32, y: i32) Writer.Error!void {
    try w.writeAll("\t\t(property ");
    try str(w, name);
    try w.writeByte(' ');
    try str(w, value);
    try w.writeByte(' ');
    try at(w, x, y, 0);
    try w.writeAll(" " ++ hidden_font_effects ++ ")\n");
}

/// The Datasheet field plus every other resolved property (MPN, Manufacturer,
/// …) as hidden custom fields, so a KiCad-generated BOM carries the same
/// identity netlisp's own netlist does — and, on a hub, the part number ONCE
/// MORE as a visible field under the Value. A field name may appear only once
/// per symbol, so the visible one replaces the hidden one rather than joining it.
fn extraProps(w: *Writer, p: Part, u: shape_mod.Unit) Writer.Error!void {
    var datasheet: []const u8 = "";
    for (p.id.properties) |prop| {
        if (std.mem.eql(u8, prop.key, "datasheet")) datasheet = prop.value;
    }
    try hiddenProp(w, "Datasheet", datasheet, p.x, p.y);
    const shown = shownMpn(p.id);
    for (p.id.properties) |prop| {
        const name = fieldName(prop.key) orelse continue;
        if (shown != null and std.mem.eql(u8, name, mpn_field)) continue;
        try hiddenProp(w, name, prop.value, p.x, p.y);
    }
    const mpn = shown orelse return;
    const at_pt = mpnAnchor(p, u);
    try w.writeAll("\t\t(property \"" ++ mpn_field ++ "\" ");
    try str(w, mpn);
    try w.writeByte(' ');
    try at(w, at_pt[0], at_pt[1], if (p.banked == null) 0 else 90);
    try w.writeAll(" " ++ font_effects ++ ")\n");
}

/// Where a displayed part number is anchored: one clear line under the Value,
/// which itself sits at the bottom of the cell the sheet packer reserved. The
/// cell is grown by the same `mpn_drop` when a part shows one, so the extra line
/// lands inside it rather than on whatever is packed underneath.
fn mpnAnchor(p: Part, u: shape_mod.Unit) [2]i32 {
    const value = textAnchor(p, u, 1);
    return .{ value[0], value[1] + mpn_drop };
}

/// KiCad field name for a netlisp property key; null for keys that already have
/// a dedicated field (emitting them twice would duplicate a field name).
fn fieldName(key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "mpn")) return "MPN";
    if (std.mem.eql(u8, key, "manufacturer")) return "Manufacturer";
    if (std.mem.eql(u8, key, "datasheet")) return null;
    if (std.mem.eql(u8, key, "footprint")) return null;
    if (std.mem.eql(u8, key, "value")) return null;
    if (key.len == 0) return null;
    return key;
}

/// Per-pin connectivity for one part: a stub plus a global label on every
/// labelled pin, a stub alone where a rail symbol or a drawn wire takes the
/// label's place, and a no-connect flag on every pad the netlist leaves open.
///
/// A part ganged into a decoupling bank has none of that: the bank's own rails
/// reach both of its legs and one label names them, so it is skipped whole —
/// which is also what keeps `pin.side`, meaningless once the part is turned on
/// end, from ever being asked for a stub direction.
fn connections(arena: std.mem.Allocator, w: *Writer, doc: Doc, p: Part) EmitError!void {
    if (p.banked != null) return;
    const u = doc.shapes[p.shape].units[p.unit];
    for (u.pins, 0..) |pin, i| {
        const net = if (i < p.nets.len) p.nets[i] else "";
        const pt = pinPoint(p, pin);
        if (net.len == 0) {
            try w.writeAll("\t(no_connect ");
            try at2(w, pt);
            try w.print(" (uuid \"{s}\"))\n", .{try pinUuid(arena, doc.sheet.design, "nc", p.id.ref, pin.pad)});
            continue;
        }
        const lp = labelPoint(pt[0], pt[1], pin.side, stubReach(u, i));
        try wire(arena, w, doc.sheet.design, pt, lp, try pinKey(arena, p.id.ref, pin.pad));
        // A rail-carried pin gets its symbol from `Power.pins`, and a pin the
        // wiring pass drew onto a run is named by that run's anchor label; the
        // stub above is all either needs here.
        if (isRailPin(doc.power.pins, lp)) continue;
        if (isWired(doc.wiring.no_label, lp)) continue;
        try globalLabel(w, net, try pinUuid(arena, doc.sheet.design, "label", p.id.ref, pin.pad), pin.side, lp);
    }
}

/// True when a rail symbol is already placed at `pt` — the pin is grounded
/// through a power symbol rather than a net label.
fn isRailPin(pins: []const RailPin, pt: [2]i32) bool {
    for (pins) |rp| {
        if (rp.x == pt[0] and rp.y == pt[1]) return true;
    }
    return false;
}

/// True when a drawn wire already carries this stub end onto a run whose anchor
/// names the net.
fn isWired(no_label: []const wire_mod.Point, pt: [2]i32) bool {
    for (no_label) |p| {
        if (p.x == pt[0] and p.y == pt[1]) return true;
    }
    return false;
}

/// One routed connection: an orthogonal polyline written as KiCad's two-point
/// wire segments, each uuid derived from the pin pair and the segment's index
/// so a re-export of the same connection reproduces the same bytes.
fn routedWire(
    arena: std.mem.Allocator,
    w: *Writer,
    design: []const u8,
    path: wire_mod.Path,
) EmitError!void {
    for (path.pts[0 .. path.pts.len - 1], path.pts[1..], 0..) |a, b, i| {
        const key = try std.fmt.allocPrint(arena, "{s}#{d}", .{ path.key, i });
        try wire(arena, w, design, .{ a.x, a.y }, .{ b.x, b.y }, key);
    }
}

/// A junction dot. KiCad joins three wire ends with or without one, but the dot
/// is what tells a reader the crossing they are looking at is a connection.
fn junction(
    arena: std.mem.Allocator,
    w: *Writer,
    design: []const u8,
    pt: wire_mod.Point,
) EmitError!void {
    const path = try std.fmt.allocPrint(arena, "{d},{d}", .{ pt.x, pt.y });
    try w.writeAll("\t(junction ");
    try at2(w, .{ pt.x, pt.y });
    try w.writeAll(" (diameter 0) (color 0 0 0 0)\n");
    try w.print("\t\t(uuid \"{s}\")\n\t)\n", .{try elementUuid(arena, design, "junc", path)});
}

fn wire(
    arena: std.mem.Allocator,
    w: *Writer,
    design: []const u8,
    from: [2]i32,
    to: [2]i32,
    key: []const u8,
) EmitError!void {
    try w.writeAll("\t(wire (pts ");
    try at2xy(w, from);
    try w.writeByte(' ');
    try at2xy(w, to);
    try w.print(")\n\t\t(stroke (width 0) (type default))\n\t\t(uuid \"{s}\")\n\t)\n", .{
        try elementUuid(arena, design, "wire", key),
    });
}

fn globalLabel(
    w: *Writer,
    net: []const u8,
    uuid: []const u8,
    side: Side,
    pt: [2]i32,
) EmitError!void {
    try w.writeAll("\t(global_label ");
    try str(w, net);
    try w.writeAll(" (shape bidirectional) ");
    try at(w, pt[0], pt[1], labelAngle(side));
    try w.writeAll("\n\t\t(fields_autoplaced yes)\n\t\t(effects (font (size 1.27 1.27)) (justify ");
    try w.writeAll(labelJustify(side));
    try w.print("))\n\t\t(uuid \"{s}\")\n\t)\n", .{uuid});
}

/// A placed rail symbol. Its `#PWR…` reference keeps it out of the netlist's
/// component list; its Value (carried by the library entry) names the net.
fn railInstance(arena: std.mem.Allocator, w: *Writer, doc: Doc, rp: RailPin) EmitError!void {
    const rail = doc.power.rails[rp.rail];
    try powerInstance(arena, w, doc.sheet, .{
        .lib_name = rail.lib_name,
        .value = rail.net,
        .ref = rp.ref,
        .uuid = rp.uuid,
        .x = rp.x,
        .y = rp.y,
        .angle = rp.angle,
    });
}

/// A PWR_FLAG driver, wired down to a global label naming the rail it drives.
fn flagInstance(arena: std.mem.Allocator, w: *Writer, doc: Doc, f: Flag) EmitError!void {
    try powerInstance(arena, w, doc.sheet, .{
        .lib_name = flag_lib_name,
        .value = flag_lib_name,
        .ref = f.ref,
        .uuid = f.uuid,
        .x = f.x,
        .y = f.y - stub_len,
        .angle = 0,
    });
    try wire(arena, w, doc.sheet.design, .{ f.x, f.y - stub_len }, .{ f.x, f.y }, f.ref);
    const uuid = try pinUuid(arena, doc.sheet.design, "label", f.ref, "");
    try globalLabel(w, f.net, uuid, .bottom, .{ f.x, f.y });
}

/// Everything one `#`-referenced power symbol needs on the page.
const PowerPlacement = struct {
    lib_name: []const u8,
    value: []const u8,
    ref: []const u8,
    uuid: []const u8,
    x: i32,
    y: i32,
    angle: u32,
};

fn powerInstance(arena: std.mem.Allocator, w: *Writer, s: Sheet, pp: PowerPlacement) EmitError!void {
    const dir = bodyDir(pp);
    try w.writeAll("\t(symbol (lib_id \"" ++ lib_prefix);
    try w.writeAll(pp.lib_name);
    try w.writeAll("\") ");
    try at(w, pp.x, pp.y, pp.angle);
    try w.writeAll(" (unit 1)\n");
    try w.writeAll(power_flags);
    try w.print("\t\t(uuid \"{s}\")\n", .{pp.uuid});
    // Stored at 90 on a quarter-turned symbol so it comes out HORIZONTAL:
    // KiCad's `GetDrawRotation` swaps a field's orientation whenever its parent
    // is quarter-turned, so a ground symbol on a left-hand pin used to print
    // `GND` running down the page across the two pins below it.
    const text_angle: u32 = if (pp.angle == 90 or pp.angle == 270) 90 else 0;
    try w.writeAll("\t\t(property \"Reference\" ");
    try str(w, pp.ref);
    try w.writeByte(' ');
    try at(w, pp.x - dir[0] * text_reach, pp.y - dir[1] * text_reach, text_angle);
    try w.writeAll(" " ++ hidden_font_effects ++ ")\n");
    try w.writeAll("\t\t(property \"Value\" ");
    try str(w, pp.value);
    try w.writeByte(' ');
    try at(w, pp.x + dir[0] * text_reach, pp.y + dir[1] * text_reach, text_angle);
    try w.writeAll(" " ++ font_effects ++ ")\n");
    try instances(arena, w, s, pp.ref, 1);
}

/// Which way a power symbol's body hangs off its connection point, ON THE
/// SHEET. A rail's graphic points down in library coordinates and a PWR_FLAG's
/// points up, and both turn with the placed angle — so the Value must follow, or
/// a left-facing ground symbol writes `GND` straight across the pin below it and
/// a flag writes `PWR_FLAG` over the label it drives.
fn bodyDir(pp: PowerPlacement) [2]i32 {
    const away: i32 = if (std.mem.eql(u8, pp.lib_name, flag_lib_name)) -1 else 1;
    return switch (pp.angle % 360) {
        90 => .{ away, 0 },
        180 => .{ 0, -away },
        270 => .{ -away, 0 },
        else => .{ 0, away },
    };
}

/// One `(sheet …)` block on the root: the box a reader double-clicks, plus the
/// `Sheetfile` property KiCad follows to the child document.
fn childSheet(arena: std.mem.Allocator, w: *Writer, doc: Doc, c: SheetRef) EmitError!void {
    // A sheet block's `(at …)` takes exactly TWO values — unlike a placed
    // symbol's, which needs three. KiCad refuses to load the file otherwise.
    try w.writeAll("\t(sheet ");
    try at2(w, .{ c.at.x, c.at.y });
    try w.writeAll(" (size ");
    try mm(w, c.at.w);
    try w.writeByte(' ');
    try mm(w, c.at.h);
    try w.writeAll(")\n\t\t(exclude_from_sim no)\n\t\t(in_bom yes)\n\t\t(on_board yes)\n\t\t(dnp no)\n");
    try w.writeAll("\t\t(fields_autoplaced yes)\n\t\t(stroke (width 0.1524) (type solid))\n");
    try w.writeAll("\t\t(fill (color 0 0 0 0))\n");
    try w.print("\t\t(uuid \"{s}\")\n", .{c.uuid});
    try w.writeAll("\t\t(property \"Sheetname\" ");
    try str(w, c.name);
    try w.writeByte(' ');
    try at(w, c.at.x, c.at.y - shape_mod.grid, 0);
    try w.writeAll(" (effects (font (size 1.27 1.27)) (justify left bottom)))\n");
    try w.writeAll("\t\t(property \"Sheetfile\" ");
    try str(w, c.file);
    try w.writeByte(' ');
    try at(w, c.at.x, c.at.y + c.at.h + shape_mod.grid, 0);
    try w.writeAll(" (effects (font (size 1.27 1.27)) (justify left top)))\n");
    try w.writeAll("\t\t(instances\n\t\t\t(project ");
    try str(w, doc.sheet.design);
    try w.writeAll("\n\t\t\t\t(path ");
    try str(w, try instancePath(arena, doc.sheet));
    try w.print("\n\t\t\t\t\t(page \"{d}\")\n\t\t\t\t)\n\t\t\t)\n\t\t)\n\t)\n", .{c.page});
}

fn pinKey(arena: std.mem.Allocator, ref: []const u8, pad: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}:{s}", .{ ref, pad });
}

fn pinUuid(
    arena: std.mem.Allocator,
    design: []const u8,
    kind: []const u8,
    ref: []const u8,
    pad: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return elementUuid(arena, design, kind, try pinKey(arena, ref, pad));
}

fn at2(w: *Writer, pt: [2]i32) Writer.Error!void {
    try w.writeAll("(at ");
    try mm(w, pt[0]);
    try w.writeByte(' ');
    try mm(w, pt[1]);
    try w.writeByte(')');
}

fn at2xy(w: *Writer, pt: [2]i32) Writer.Error!void {
    try w.writeAll("(xy ");
    try mm(w, pt[0]);
    try w.writeByte(' ');
    try mm(w, pt[1]);
    try w.writeByte(')');
}

fn caption(
    arena: std.mem.Allocator,
    w: *Writer,
    design: []const u8,
    c: Caption,
    path: []const u8,
) EmitError!void {
    try w.writeAll("\t(text ");
    try str(w, c.text);
    try w.writeAll("\n\t\t(exclude_from_sim no)\n\t\t");
    try at(w, c.x, c.y, 0);
    try w.writeAll("\n\t\t(effects (font (size ");
    try mm(w, c.size);
    try w.writeByte(' ');
    try mm(w, c.size);
    try w.writeAll(")) (justify left bottom))\n");
    try w.print("\t\t(uuid \"{s}\")\n\t)\n", .{try elementUuid(arena, design, "cap", path)});
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: export_kicad_sch - Coordinates print as exact decimals and quoted text escapes quotes and backslashes
test "kicad-sch: mm prints exact hundredths and str escapes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try mm(w, 6350);
    try w.writeByte(' ');
    try mm(w, -1524);
    try w.writeByte(' ');
    try mm(w, 6858);
    try w.writeByte(' ');
    try mm(w, 0);
    try w.writeByte(' ');
    try str(w, "a\"b\\c");
    try testing.expectEqualStrings("63.5 -15.24 68.58 0 \"a\\\"b\\\\c\"", out.written());
}

// spec: export_kicad_sch - A vendor body's sub-hundredth coordinates print exactly, with trailing zeros trimmed
test "kicad-sch: mm4 prints ten-thousandths of a millimetre exactly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    // 2.54 and 0.127 mm round-trip as they were written, a six-decimal vendor
    // coordinate keeps four, and a whole number stays whole.
    try mm4(w, 25400);
    try w.writeByte(' ');
    try mm4(w, -1270);
    try w.writeByte(' ');
    try mm4(w, 8467);
    try w.writeByte(' ');
    try mm4(w, 0);
    try w.writeByte(' ');
    try mm4(w, 1000000);
    try w.writeByte(' ');
    try mm4(w, 1524);
    try testing.expectEqualStrings("2.54 -0.127 0.8467 0 100 0.1524", out.written());
}

// spec: export_kicad_sch - A label's justification mirrors its angle so the net name never draws across the symbol
test "kicad-sch: label angle and justification mirror the pin side" {
    try testing.expectEqual(@as(u32, 180), labelAngle(.left));
    try testing.expectEqual(@as(u32, 0), labelAngle(.right));
    try testing.expectEqualStrings("right", labelJustify(.left));
    try testing.expectEqualStrings("left", labelJustify(.right));
    try testing.expectEqualStrings("left", labelJustify(.top));
    try testing.expectEqualStrings("right", labelJustify(.bottom));
    // The library pin angle points back at the body, the opposite convention.
    try testing.expectEqual(@as(u32, 0), pinAngle(.left));
    try testing.expectEqual(@as(u32, 180), pinAngle(.right));
    // A rail symbol's body hangs away from the pin, whichever edge it is on.
    try testing.expectEqual(@as(u32, 0), railAngle(.bottom));
    try testing.expectEqual(@as(u32, 90), railAngle(.right));
    try testing.expectEqual(@as(u32, 180), railAngle(.top));
    try testing.expectEqual(@as(u32, 270), railAngle(.left));
}

// spec: export_kicad_sch - A power symbol's Value follows the body it names, whichever way the symbol was turned
test "kicad-sch: a rail symbol's text hangs with its body and a flag's the other way" {
    const rail = PowerPlacement{
        .lib_name = "PWR_GND",
        .value = "GND",
        .ref = "#PWR01",
        .uuid = "u",
        .x = 0,
        .y = 0,
        .angle = 0,
    };
    // A ground under a bottom-edge pin writes its name below itself.
    try testing.expectEqual([2]i32{ 0, 1 }, bodyDir(rail));
    // Turned onto a left-hand pin the body points left, and the text with it —
    // otherwise `GND` is written straight across the pins below.
    var left = rail;
    left.angle = 270;
    try testing.expectEqual([2]i32{ -1, 0 }, bodyDir(left));
    var right = rail;
    right.angle = 90;
    try testing.expectEqual([2]i32{ 1, 0 }, bodyDir(right));
    // A PWR_FLAG's graphic points the OTHER way, so its own name goes up.
    var flag = rail;
    flag.lib_name = flag_lib_name;
    try testing.expectEqual([2]i32{ 0, -1 }, bodyDir(flag));
}

// spec: export_kicad_sch - A rail-carried pin reserves the ground symbol's whole reach, and a labelled one its text plus the label's own lead
test "kicad-sch: labelSpan budgets what KiCad actually draws" {
    // An unconnected pad draws nothing.
    try testing.expectEqual(@as(i32, 0), labelSpan(""));
    // A ground symbol reaches its Value text, well past three characters of
    // label — which is what the exporter used to budget for it.
    try testing.expect(labelSpan("GND") > 3 * shape_mod.grid);
    // A label is its own advance plus the arrow head before the first glyph.
    try testing.expect(labelSpan("VDDCORE") >= 7 * shape_mod.grid);
    try testing.expect(labelSpan("VDDCOREX") > labelSpan("VDDCORE"));
}

// spec: export_kicad_sch - A pin's own name and number are drawn at the size its edge's pin spacing leaves room for
test "kicad-sch: pin text shrinks on a fine-pitch edge and stays full size elsewhere" {
    const roomy = [_]shape_mod.Pin{
        .{ .pad = "1", .name = "A", .side = .left, .x = -1270, .y = 254 },
        .{ .pad = "2", .name = "B", .side = .left, .x = -1270, .y = 0 },
        // Alone on its own edge: nothing to clear, so nothing to shrink.
        .{ .pad = "3", .name = "C", .side = .right, .x = 1270, .y = 0 },
    };
    const wide = shape_mod.Unit{ .number = 1, .title = "", .pins = &roomy, .half_w = 1016, .half_h = 508 };
    try testing.expectEqual(@as(i32, 127), pinTextSize(wide, 0));
    try testing.expectEqual(@as(i32, 127), pinTextSize(wide, 2));
    try testing.expectEqual(@as(i32, 254), edgeSpacing(wide, 0).?);
    try testing.expect(edgeSpacing(wide, 2) == null);

    // A board-to-board connector's edge, one grid step per pin: full-size text
    // would print each number through the one below it.
    const tight = [_]shape_mod.Pin{
        .{ .pad = "1", .name = "A", .side = .left, .x = -1270, .y = 127 },
        .{ .pad = "2", .name = "B", .side = .left, .x = -1270, .y = 0 },
    };
    const dense = shape_mod.Unit{ .number = 1, .title = "", .pins = &tight, .half_w = 1016, .half_h = 508 };
    const size = pinTextSize(dense, 0);
    try testing.expect(size < 127);
    try testing.expect(size >= min_pin_text);
    // It is a whole number of hundredths, so the emitted decimal is exact, and
    // it leaves real air between one row of text and the next.
    try testing.expectEqual(@as(i32, 0), @mod(size, size_step));
    try testing.expect(size + @divTrunc(size, 5) < 127);
}

// spec: export_kicad_sch - A child sheet's symbols carry the root-then-sheet instance path while the root carries its own
test "kicad-sch: the instance path gains a sheet segment on a child file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = Sheet{
        .design = "d",
        .root_uuid = "R",
        .sheet_uuid = "R",
        .page_w = 1,
        .page_h = 1,
        .is_root = true,
    };
    try testing.expectEqualStrings("/R", try instancePath(a, root));

    var child = root;
    child.sheet_uuid = "S";
    child.is_root = false;
    try testing.expectEqualStrings("/R/S", try instancePath(a, child));
}
