//! System-of-boards block diagram: one node per board in a `SystemSpec`, with
//! every board-to-board `InterfaceContract` drawn as a labeled spine between the
//! two board columns. The sibling renderers in this directory diagram ONE
//! design's internal blocks; this one is a level up — the boards themselves are
//! the blocks and the connector contract is the wiring.
//!
//! A 40-contact contract drawn as 40 lines is unreadable, so contacts are
//! grouped into signal LANES by classifying each contact's canonical net name
//! (`classifySignal`). Each lane shows its class colour, its contact count and a
//! few representative net names; the ground lane collapses to a bare count
//! because returns touch every lane and listing them says nothing.
//!
//! Static and self-contained by construction: no script, no `id` that could
//! collide with another fragment on the same page, and every colour, font and
//! size is an explicit SVG presentation attribute — so the fragment renders
//! identically with or without `diagram.diagram_css` in the host document.
//! Rendering is a pure function of the spec: no clock, no RNG, and every
//! iteration order is either slice order or hash-map INSERTION order.

const std = @import("std");
const escape = @import("../escape.zig");
const rb = @import("../render_block_types.zig");
const na = @import("../eval/net_analysis.zig");
const rails = @import("../eval/rails.zig");
const system_review = @import("../system_review.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const BoardMember = system_review.BoardMember;
const InterfaceContract = system_review.InterfaceContract;
const SystemSpec = system_review.SystemSpec;

/// Signal class of one interface contact. Declaration order is also the lane
/// render order, so `ground` sits last: it is the collapsed return lane.
pub const Lane = enum { power, clock, comms, control, rf, ground };

const lane_count = @typeInfo(Lane).@"enum".field_names.len;

/// Tunable geometry, in SVG user units. The fragment scales to its container,
/// so these set proportion rather than final pixels.
pub const Options = struct {
    /// Width of one board node box.
    board_w: f64 = 300,
    /// Height of one board node box.
    board_h: f64 = 124,
    /// Width of the interface spine column between the two board columns.
    spine_w: f64 = 372,
    /// Height of one signal-lane row inside a spine.
    lane_h: f64 = 64,
    /// Horizontal gap between a board column and the spine.
    gutter: f64 = 56,
    /// Outer canvas margin.
    pad: f64 = 24,
};

/// Height of one interface's title block, above its first lane row.
const header_h: f64 = 42;
/// Vertical gap below one interface's last lane row.
const iface_gap: f64 = 20;
/// Vertical gap between two board boxes stacked in the same column.
const board_gap: f64 = 22;
/// Width and height of the contact-count pill sitting mid-lane.
const pill_w: f64 = 88;
const pill_h: f64 = 22;
/// Representative net names shown per lane before the overflow marker.
const max_samples: usize = 3;

const ink = "#c9d1d9";
const ink_muted = "#8b949e";
const ink_dim = "#6e7681";
const sheet = "#161b22";
const sheet_deep = "#0d1117";
const rule = "#30363d";
// Font stacks are written into quoted SVG attributes, so no family name here
// may carry a quote of its own.
const sans = "-apple-system,BlinkMacSystemFont,sans-serif";
const mono = "ui-monospace,SFMono-Regular,Menlo,monospace";

/// Per-board accent, cycled by board index so two boards never read alike.
const board_accents = [_][]const u8{ "#58a6ff", "#f0883e", "#a371f7", "#56d364" };

/// Render the whole system as one standalone inline SVG wrapped in a block
/// container — the static form a review document embeds. Writes nothing when
/// the spec declares no boards.
pub fn renderSystemSvg(
    allocator: Allocator,
    spec: *const SystemSpec,
    opts: Options,
    w: *Writer,
) (Allocator.Error || Writer.Error)!void {
    _ = try renderForm(allocator, spec, opts, w, .fragment);
}

/// Render the same drawing as a standalone SVG document — an `<svg>` root with
/// its own `xmlns`, intrinsic `width`/`height`, and a painted background — the
/// form an archive member has to take, since a bare fragment is not a file a
/// viewer can open. Returns false and writes nothing when the spec declares no
/// boards, which the archive reads as "omit the member", matching how the
/// per-board diagram evidence behaves.
pub fn renderSystemDocumentSvg(
    allocator: Allocator,
    spec: *const SystemSpec,
    opts: Options,
    w: *Writer,
) (Allocator.Error || Writer.Error)!bool {
    return renderForm(allocator, spec, opts, w, .document);
}

/// Which wrapper the same drawing gets: an HTML fragment for a review page, or
/// a self-standing SVG document for a file.
const Form = enum { fragment, document };

fn renderForm(
    allocator: Allocator,
    spec: *const SystemSpec,
    opts: Options,
    w: *Writer,
    form: Form,
) (Allocator.Error || Writer.Error)!bool {
    if (spec.boards.len == 0) return false;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tallies = try arena.alloc(InterfaceTally, spec.interfaces.len);
    for (spec.interfaces, tallies) |*contract, *tally| tally.* = try tallyInterface(arena, contract);
    const sides = try assignSides(arena, spec);

    const spine_h = spineHeight(opts, tallies);
    const content_h = @max(spine_h, columnHeight(opts, sides, true));
    const canvas_h = opts.pad * 2 + @max(content_h, columnHeight(opts, sides, false));
    const canvas_w = opts.pad * 2 + opts.board_w * 2 + opts.gutter * 2 + opts.spine_w;

    try writeOpen(w, spec, canvas_w, canvas_h, form);
    // A document has no host page behind it, so it paints its own ground; the
    // fragment's wrapper `<div>` already carries that colour.
    if (form == .document)
        try w.print("<rect width=\"100%\" height=\"100%\" fill=\"{s}\"/>", .{sheet_deep});
    try writeBoardColumns(w, spec, opts, sides, canvas_h);
    try writeSpine(w, spec, opts, tallies, canvas_h - opts.pad * 2 - spine_h);
    try w.writeAll("</svg>");
    if (form == .fragment) try w.writeAll("</div>");
    return true;
}

/// Classify one contact's canonical net name into a signal lane.
///
/// Order is load-bearing. Ground leads so a `VSS`-named return is a return and
/// not a rail, and control precedes RF so `LOCK_DET` is a control line rather
/// than an `LO…` one and `LNA_BYPASS` is the command it is rather than the
/// amplifier it names. `control` is the fallback, which is what makes the
/// function total: every contact lands in exactly one lane.
pub fn classifySignal(canonical: []const u8) Lane {
    if (isGround(canonical)) return .ground;
    if (isPower(canonical)) return .power;
    if (isClock(canonical)) return .clock;
    if (isComms(canonical)) return .comms;
    if (isControl(canonical)) return .control;
    if (isRf(canonical)) return .rf;
    return .control;
}

/// Lane accent colour, borrowed from the block-diagram category palette so a
/// system diagram and a board diagram in the same document agree on what a
/// power, clock, comms, control or analog line looks like.
pub fn laneColor(lane: Lane) []const u8 {
    return rb.categoryColor(switch (lane) {
        .power => .power,
        .clock => .clock,
        .comms => .comms,
        .control => .mcu,
        .rf => .analog,
        .ground => .protection,
    });
}

/// Heading shown above a lane row.
pub fn laneLabel(lane: Lane) []const u8 {
    return switch (lane) {
        .power => "POWER",
        .clock => "CLOCK / REF",
        .comms => "COMMS",
        .control => "CONTROL",
        .rf => "RF / ANALOG",
        .ground => "GROUND",
    };
}

// ── classification ─────────────────────────────────────────────────────

fn startsWithAny(name: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, name, p)) return true;
    }
    return false;
}

fn endsWithAny(name: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |s| {
        if (std.mem.endsWith(u8, name, s)) return true;
    }
    return false;
}

/// Ground and supply spellings come from the shared vocabularies in
/// `eval/net_analysis` and `eval/rails` rather than from a private table here:
/// a return that reads as ground to the placer and as a signal to this diagram
/// is exactly the divergence those tables exist to prevent.
fn isGround(name: []const u8) bool {
    for (na.ground_base_names) |g| {
        if (std.mem.eql(u8, name, g)) return true;
    }
    return startsWithAny(name, &na.ground_stem_prefixes) or
        endsWithAny(name, &.{ "_GND", "GND" });
}

fn isPower(name: []const u8) bool {
    return startsWithAny(name, &rails.diagram_supply_prefixes) or
        startsWithAny(name, &.{ "+", "VIN", "VOUT", "PWR_" }) or
        endsWithAny(name, &.{ "_RAIL", "_PWR" }) or
        startsVDigit(name);
}

/// `V5P0` / `V1P8_RF`: the structural rail form `diagram/classify` also accepts.
fn startsVDigit(name: []const u8) bool {
    return name.len >= 2 and name[0] == 'V' and std.ascii.isDigit(name[1]);
}

fn isClock(name: []const u8) bool {
    return startsWithAny(name, &.{ "REF", "CLK", "XTAL", "OSC", "MCLK", "SCLK", "PPS" }) or
        endsWithAny(name, &.{ "_CLK", "_REF", "_XTAL" });
}

fn isComms(name: []const u8) bool {
    return startsWithAny(name, &.{
        "SPI",  "I2C", "I2S", "USB", "UART", "CAN", "SDA",  "SCL",
        "SCK",  "CS",  "TX",  "RX",  "QSPI", "SWD", "JTAG", "MOSI",
        "MISO",
    }) or endsWithAny(name, &.{ "_MOSI", "_MISO", "_SCK", "_SDA", "_SCL", "_CS", "_CSN", "_TX", "_RX" });
}

fn isControl(name: []const u8) bool {
    return startsWithAny(name, &.{
        "EN_",    "GPIO", "LOCK", "RESET", "RST",  "NRST",
        "BYPASS", "IRQ",  "INT_", "ALERT", "SHDN", "MODE",
    }) or endsWithAny(name, &.{ "_EN", "_BYPASS", "_RESET", "_RST", "_LOCK", "_IRQ", "_DET" }) or
        std.mem.eql(u8, name, "EN");
}

fn isRf(name: []const u8) bool {
    return startsWithAny(name, &.{ "IF", "RF", "LO", "ANT", "CAL", "MIX", "VCO", "LNA", "PA_" }) or
        endsWithAny(name, &.{ "_RF", "_IF", "_ANT", "_LO" });
}

// ── tallying ───────────────────────────────────────────────────────────

/// One lane's share of an interface. `names` is an ARRAY hash map so the
/// representative names come back in first-contact order rather than in hash
/// order — the difference between a deterministic render and a flaky one.
const LaneTally = struct {
    contacts: usize = 0,
    names: std.array_hash_map.String(void) = .empty,
};

/// One interface's contacts split across the lanes, plus how many lanes ended
/// up non-empty (the spine's row count for this interface).
const InterfaceTally = struct {
    lanes: [lane_count]LaneTally,
    rows: usize,
};

fn tallyInterface(arena: Allocator, contract: *const InterfaceContract) Allocator.Error!InterfaceTally {
    var tally: InterfaceTally = .{ .lanes = @splat(.{}), .rows = 0 };
    for (contract.signals) |signal| {
        const slot = &tally.lanes[@backingInt(classifySignal(signal.canonical))];
        slot.contacts += 1;
        try slot.names.put(arena, signal.canonical, {});
    }
    for (tally.lanes) |slot| {
        if (slot.contacts > 0) tally.rows += 1;
    }
    return tally;
}

// ── layout ─────────────────────────────────────────────────────────────

/// Column side per board, indexed like `spec.boards`. True means the right
/// column. The first interface's two endpoints anchor the columns so the spine
/// is drawn the way the contract reads; the rest alternate into the shorter
/// column, which keeps a 1-board or N-board system from stacking on one side.
fn assignSides(arena: Allocator, spec: *const SystemSpec) Allocator.Error![]bool {
    const sides = try arena.alloc(bool, spec.boards.len);
    const placed = try arena.alloc(bool, spec.boards.len);
    @memset(sides, false);
    @memset(placed, false);
    var counts = [_]usize{ 0, 0 };
    if (spec.interfaces.len > 0) {
        const first = spec.interfaces[0];
        anchorSide(spec, first.left.board, false, sides, placed, &counts);
        anchorSide(spec, first.right.board, true, sides, placed, &counts);
    }
    for (sides, placed) |*side, done| {
        if (done) continue;
        side.* = counts[1] < counts[0];
        counts[@intFromBool(side.*)] += 1;
    }
    return sides;
}

fn anchorSide(
    spec: *const SystemSpec,
    name: []const u8,
    right: bool,
    sides: []bool,
    placed: []bool,
    counts: *[2]usize,
) void {
    const idx = findBoard(spec, name) orelse return;
    if (placed[idx]) return;
    sides[idx] = right;
    placed[idx] = true;
    counts[@intFromBool(right)] += 1;
}

fn findBoard(spec: *const SystemSpec, name: []const u8) ?usize {
    for (spec.boards, 0..) |b, i| {
        if (std.mem.eql(u8, b.name, name)) return i;
    }
    return null;
}

fn columnHeight(opts: Options, sides: []const bool, right: bool) f64 {
    var n: usize = 0;
    for (sides) |side| {
        if (side == right) n += 1;
    }
    if (n == 0) return 0;
    const rows: f64 = @floatFromInt(n);
    return rows * opts.board_h + (rows - 1) * board_gap;
}

fn spineHeight(opts: Options, tallies: []const InterfaceTally) f64 {
    var total: f64 = 0;
    for (tallies) |tally| {
        const rows: f64 = @floatFromInt(tally.rows);
        total += header_h + rows * opts.lane_h + iface_gap;
    }
    return if (total > 0) total - iface_gap else 0;
}

// ── rendering ──────────────────────────────────────────────────────────

fn writeOpen(w: *Writer, spec: *const SystemSpec, canvas_w: f64, canvas_h: f64, form: Form) Writer.Error!void {
    if (form == .fragment) {
        try w.print(
            "<div class=\"sob-wrap\" style=\"margin:12px 0 4px;padding:10px;background:{s};" ++
                "border:1px solid #21262d;border-radius:8px;\">" ++
                "<svg viewBox=\"0 0 {d:.0} {d:.0}\" role=\"img\" " ++
                "style=\"display:block;width:100%;max-width:{d:.0}px;height:auto;\" " ++
                "xmlns=\"http://www.w3.org/2000/svg\" aria-label=\"",
            .{ sheet_deep, canvas_w, canvas_h, canvas_w },
        );
    } else {
        try w.print(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {d:.0} {d:.0}\" " ++
                "width=\"{d:.0}\" height=\"{d:.0}\" role=\"img\" aria-label=\"",
            .{ canvas_w, canvas_h, canvas_w, canvas_h },
        );
    }
    try escape.writeXml(w, spec.title);
    try w.writeAll(" system block diagram\"><title>");
    try escape.writeXml(w, spec.title);
    try w.print(
        " system block diagram</title><desc>{d} board(s), {d} board-to-board interface(s).</desc>",
        .{ spec.boards.len, spec.interfaces.len },
    );
}

fn writeBoardColumns(
    w: *Writer,
    spec: *const SystemSpec,
    opts: Options,
    sides: []const bool,
    canvas_h: f64,
) Writer.Error!void {
    const right_x = opts.pad + opts.board_w + opts.gutter * 2 + opts.spine_w;
    var next = [_]f64{ 0, 0 };
    next[0] = columnTop(opts, sides, false, canvas_h);
    next[1] = columnTop(opts, sides, true, canvas_h);
    for (spec.boards, sides, 0..) |board, right, i| {
        const slot = @intFromBool(right);
        const x = if (right) right_x else opts.pad;
        try writeBoard(w, opts, board, board_accents[i % board_accents.len], .{ x, next[slot] });
        next[slot] += opts.board_h + board_gap;
    }
}

fn columnTop(opts: Options, sides: []const bool, right: bool, canvas_h: f64) f64 {
    return opts.pad + (canvas_h - opts.pad * 2 - columnHeight(opts, sides, right)) / 2;
}

fn writeBoard(
    w: *Writer,
    opts: Options,
    board: BoardMember,
    accent: []const u8,
    at: [2]f64,
) Writer.Error!void {
    const x = at[0];
    const y = at[1];
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"8\" fill=\"{s}\" stroke=\"{s}\"/>",
        .{ x, y, opts.board_w, opts.board_h, sheet, rule },
    );
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"4\" height=\"{d:.1}\" fill=\"{s}\"/>",
        .{ x, y + 8, opts.board_h - 16, accent },
    );
    try w.print(
        "<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"{s}\"/>",
        .{ x, y + 32, x + opts.board_w, y + 32, rule },
    );
    try writeText(w, .{ x + 16, y + 21 }, .{ mono, "700", "12" }, accent, board.role);
    try writeText(w, .{ x + 16, y + 57 }, .{ sans, "600", "17" }, ink, board.name);
    try writeText(w, .{ x + 16, y + 80 }, .{ mono, "500", "13" }, ink_muted, board.part_number);
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" font-family=\"{s}\" font-weight=\"500\" font-size=\"13\" fill=\"{s}\">rev ",
        .{ x + 16, y + 101, mono, ink_dim },
    );
    try escape.writeXml(w, board.revision);
    try w.writeAll(" \u{00b7} ");
    try escape.writeXml(w, board.layout);
    try w.writeAll("</text>");
}

/// One `<text>` run. `font` is `.{ family, weight, size }`; `at` is `.{ x, y }`.
fn writeText(
    w: *Writer,
    at: [2]f64,
    font: [3][]const u8,
    fill: []const u8,
    body: []const u8,
) Writer.Error!void {
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" font-family=\"{s}\" font-weight=\"{s}\" font-size=\"{s}\" fill=\"{s}\">",
        .{ at[0], at[1], font[0], font[1], font[2], fill },
    );
    try escape.writeXml(w, body);
    try w.writeAll("</text>");
}

/// Same as `writeText` but horizontally centred on `at[0]` — the spine writes
/// everything on its own centre line.
fn writeCentered(
    w: *Writer,
    at: [2]f64,
    font: [3][]const u8,
    fill: []const u8,
    body: []const u8,
) Writer.Error!void {
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" font-family=\"{s}\" font-weight=\"{s}\" " ++
            "font-size=\"{s}\" fill=\"{s}\">",
        .{ at[0], at[1], font[0], font[1], font[2], fill },
    );
    try escape.writeXml(w, body);
    try w.writeAll("</text>");
}

/// Horizontal anchors the spine draws against: the inner edge of each board
/// column and the spine's own centre line.
const Spine = struct { left_x: f64, right_x: f64, center_x: f64 };

fn writeSpine(
    w: *Writer,
    spec: *const SystemSpec,
    opts: Options,
    tallies: []const InterfaceTally,
    top_offset: f64,
) Writer.Error!void {
    const sp: Spine = .{
        .left_x = opts.pad + opts.board_w,
        .right_x = opts.pad + opts.board_w + opts.gutter * 2 + opts.spine_w,
        .center_x = opts.pad + opts.board_w + opts.gutter + opts.spine_w / 2,
    };
    var y = opts.pad + top_offset / 2;
    for (spec.interfaces, tallies) |contract, tally| {
        try writeInterfaceHeader(w, sp, contract, y);
        y += header_h;
        for (tally.lanes, 0..) |slot, i| {
            if (slot.contacts == 0) continue;
            try writeLane(w, sp, @fromBackingInt(@intCast(i)), slot, .{ y, opts.lane_h });
            y += opts.lane_h;
        }
        y += iface_gap;
    }
}

/// The interface's title block: its id, its declared contact count, and both
/// endpoints spelled `<board> <connector>` — the spine is drawn between the two
/// board COLUMNS, so with more than two boards this line is what says which
/// pair of boards the contract actually joins.
fn writeInterfaceHeader(w: *Writer, sp: Spine, contract: InterfaceContract, y: f64) Writer.Error!void {
    try writeCentered(w, .{ sp.center_x, y + 16 }, .{ mono, "700", "15" }, ink, contract.id);
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" font-family=\"{s}\" font-weight=\"500\" " ++
            "font-size=\"12\" fill=\"{s}\">{d} {s} \u{00b7} ",
        .{ sp.center_x, y + 33, mono, ink_muted, contract.contact_count, plural(contract.contact_count) },
    );
    try writeEndpoint(w, contract.left);
    try w.writeAll(" \u{2194} ");
    try writeEndpoint(w, contract.right);
    try w.writeAll("</text>");
}

fn writeEndpoint(w: *Writer, endpoint: system_review.InterfaceEndpoint) Writer.Error!void {
    try escape.writeXml(w, endpoint.board);
    try w.writeByte(' ');
    try escape.writeXml(w, endpoint.connector);
}

/// `contact` / `contacts` — a lane of one is common enough that the plural
/// reads as a bug.
fn plural(n: usize) []const u8 {
    return if (n == 1) "contact" else "contacts";
}

/// One lane row: heading, the two spine wires, the contact-count pill and the
/// representative net names. `row` is `.{ top_y, height }`.
fn writeLane(w: *Writer, sp: Spine, lane: Lane, slot: LaneTally, row: [2]f64) Writer.Error!void {
    const y = row[0];
    const color = laneColor(lane);
    try writeLaneHeading(w, sp, lane, slot, y);

    const wire_y = y + row[1] * 0.53;
    const pill_x = sp.center_x - pill_w / 2;
    const dash = if (lane == .ground) " stroke-dasharray=\"3 4\"" else "";
    const width: f64 = if (lane == .ground) 1.4 else 2;
    try writeWire(w, .{ sp.left_x, pill_x, wire_y }, color, width, dash);
    try writeWire(w, .{ pill_x + pill_w, sp.right_x, wire_y }, color, width, dash);

    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"3\" fill=\"{s}\" stroke=\"{s}\"/>",
        .{ pill_x, wire_y - pill_h / 2, pill_w, pill_h, sheet_deep, color },
    );
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" font-family=\"{s}\" font-weight=\"700\" " ++
            "font-size=\"12\" fill=\"{s}\">{d}\u{00d7}",
        .{ sp.center_x, wire_y + 4, mono, color, slot.contacts },
    );
    if (lane == .ground) try w.writeAll(" GND");
    try w.writeAll("</text>");

    // The ground lane is deliberately collapsed to that count: returns repeat
    // across every other lane, so naming them adds rows and no information.
    if (lane != .ground) try writeLaneSamples(w, sp, slot, y + row[1] - 10);
}

fn writeLaneHeading(w: *Writer, sp: Spine, lane: Lane, slot: LaneTally, y: f64) Writer.Error!void {
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" font-family=\"{s}\" font-weight=\"700\" " ++
            "font-size=\"12\" letter-spacing=\"0.06em\" fill=\"{s}\">{s} \u{00b7} {d} {s}</text>",
        .{ sp.center_x, y + 14, sans, laneColor(lane), laneLabel(lane), slot.contacts, plural(slot.contacts) },
    );
}

/// `seg` is `.{ x1, x2, y }`.
fn writeWire(w: *Writer, seg: [3]f64, color: []const u8, width: f64, dash: []const u8) Writer.Error!void {
    try w.print(
        "<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"{s}\" " ++
            "stroke-width=\"{d:.1}\" stroke-linecap=\"round\"{s}/>",
        .{ seg[0], seg[2], seg[1], seg[2], color, width, dash },
    );
}

fn writeLaneSamples(w: *Writer, sp: Spine, slot: LaneTally, y: f64) Writer.Error!void {
    const names = slot.names.keys();
    if (names.len == 0) return;
    const shown = @min(names.len, max_samples);
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" font-family=\"{s}\" font-weight=\"500\" " ++
            "font-size=\"11.5\" fill=\"{s}\">",
        .{ sp.center_x, y, mono, ink_muted },
    );
    for (names[0..shown], 0..) |name, i| {
        if (i > 0) try w.writeAll(" \u{00b7} ");
        try escape.writeXml(w, name);
    }
    if (names.len > shown) try w.print(" \u{00b7} +{d} more", .{names.len - shown});
    try w.writeAll("</text>");
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn contact(canonical: []const u8, pin: []const u8) system_review.InterfaceSignal {
    return .{
        .canonical = canonical,
        .left_pin = pin,
        .left_net = canonical,
        .right_pin = pin,
        .right_net = canonical,
    };
}

/// The two-board fixture: one 10-contact interface carrying at least one
/// contact of every lane, with the ground contacts repeated so collapsing is
/// observable.
const fixture_signals = [_]system_review.InterfaceSignal{
    contact("V_12V", "1"),
    contact("V_3V3_ID", "2"),
    contact("REF_LMX_P", "3"),
    contact("SPI_MOSI", "4"),
    contact("I2C_SDA", "5"),
    contact("EN_BUCK5V75", "6"),
    contact("LNA_BYPASS", "7"),
    contact("IF1_DSA", "8"),
    contact("GND", "9"),
    contact("GND", "10"),
    contact("GND", "11"),
};

const fixture_boards = [_]BoardMember{
    .{
        .name = "board-a",
        .role = "rf",
        .source = "src/boards/board-a.sexp",
        .part_number = "BOARD-A-RF",
        .revision = "B3",
        .layout = "Board A V2",
    },
    .{
        .name = "board-a-base",
        .role = "base",
        .source = "src/boards/board-a-base.sexp",
        .part_number = "BOARD-A-BASE",
        .revision = "B3",
    },
};

const fixture_interfaces = [_]InterfaceContract{.{
    .id = "j1-board-to-board",
    .left = .{ .board = "board-a", .connector = "J1" },
    .right = .{ .board = "board-a-base", .connector = "base-interface/J1" },
    .contact_count = fixture_signals.len,
    .signals = &fixture_signals,
}};

fn fixture() SystemSpec {
    return .{
        .schema = system_review.schema_v1,
        .name = "board-a",
        .title = "Board A OC-303-1-01",
        .part_number = "OC-303-1-01",
        .revision = "B3",
        .boards = &fixture_boards,
        .interfaces = &fixture_interfaces,
    };
}

fn render(allocator: Allocator, spec: *const SystemSpec) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try renderSystemSvg(allocator, spec, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

// spec: diagram/system_of_boards - Classifies an interface contact into a power, clock, comms, control, RF or ground lane by its canonical net name
test "classifySignal sorts real interface nets into lanes" {
    try testing.expectEqual(Lane.power, classifySignal("V_12V"));
    try testing.expectEqual(Lane.power, classifySignal("V_3V3_ID"));
    try testing.expectEqual(Lane.clock, classifySignal("REF_ADF"));
    try testing.expectEqual(Lane.clock, classifySignal("REF_LMX_N"));
    try testing.expectEqual(Lane.comms, classifySignal("SPI_DSA_CSN"));
    try testing.expectEqual(Lane.comms, classifySignal("I2C_SCL"));
    try testing.expectEqual(Lane.comms, classifySignal("TXDATA_ADF"));
    try testing.expectEqual(Lane.control, classifySignal("EN_BUCK5V75"));
    // LNA_BYPASS opens with an RF prefix and still reads as the command it is.
    try testing.expectEqual(Lane.control, classifySignal("LNA_BYPASS"));
    try testing.expectEqual(Lane.control, classifySignal("LOCK_DET"));
    try testing.expectEqual(Lane.rf, classifySignal("IF1_DSA"));
    try testing.expectEqual(Lane.ground, classifySignal("GND"));
    try testing.expectEqual(Lane.ground, classifySignal("GND_ISO"));
}

// spec: diagram/system_of_boards - An unrecognised canonical net name falls back to the control lane
test "classifySignal falls back to the control lane" {
    try testing.expectEqual(Lane.control, classifySignal("MYSTERY_PIN"));
    try testing.expectEqual(Lane.control, classifySignal(""));
}

// spec: diagram/system_of_boards - Renders one board node per member carrying its role, design name, part number and revision
test "renderSystemSvg frames a self-contained SVG naming every board" {
    const spec = fixture();
    const out = try render(testing.allocator, &spec);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.startsWith(u8, out, "<div class=\"sob-wrap\""));
    try testing.expect(std.mem.endsWith(u8, out, "</svg></div>"));
    try testing.expect(std.mem.indexOf(u8, out, "<svg viewBox=\"0 0 ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "xmlns=\"http://www.w3.org/2000/svg\"") != null);
    // Self-contained: no script, and no class the host page must supply CSS for.
    try testing.expect(std.mem.indexOf(u8, out, "<script") == null);
    try testing.expect(std.mem.indexOf(u8, out, "class=\"dg-") == null);

    for ([_][]const u8{
        "board-a",    "board-a-base", "rf",   "base",
        "BOARD-A-RF", "BOARD-A-BASE", "rev ", "B3",
        "Board A V2",
    }) |needle| {
        try testing.expect(std.mem.indexOf(u8, out, needle) != null);
    }
}

// spec: diagram/system_of_boards - Groups an interface's contacts into per-class lanes labeled with the class, its contact count and representative net names
test "renderSystemSvg groups interface contacts into labeled lanes" {
    const spec = fixture();
    const out = try render(testing.allocator, &spec);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "j1-board-to-board") != null);
    try testing.expect(std.mem.indexOf(u8, out, "11 contacts \u{00b7} board-a J1") != null);
    // Two power contacts, two comms, two control, one clock, one RF, three GND.
    try testing.expect(std.mem.indexOf(u8, out, "POWER \u{00b7} 2 contacts") != null);
    try testing.expect(std.mem.indexOf(u8, out, "COMMS \u{00b7} 2 contacts") != null);
    try testing.expect(std.mem.indexOf(u8, out, "CONTROL \u{00b7} 2 contacts") != null);
    try testing.expect(std.mem.indexOf(u8, out, "CLOCK / REF \u{00b7} 1 contact") != null);
    try testing.expect(std.mem.indexOf(u8, out, "RF / ANALOG \u{00b7} 1 contact") != null);
    // Representative names ride the lane they were classified into.
    try testing.expect(std.mem.indexOf(u8, out, "V_12V \u{00b7} V_3V3_ID") != null);
    try testing.expect(std.mem.indexOf(u8, out, "EN_BUCK5V75 \u{00b7} LNA_BYPASS") != null);
    // Lane accents come from the shared block-diagram category palette.
    try testing.expect(std.mem.indexOf(u8, out, rb.categoryColor(.power)) != null);
    try testing.expect(std.mem.indexOf(u8, out, rb.categoryColor(.analog)) != null);
}

// spec: diagram/system_of_boards - The ground lane collapses to a contact count instead of listing return nets
test "renderSystemSvg collapses the ground lane to a count" {
    const spec = fixture();
    const out = try render(testing.allocator, &spec);
    defer testing.allocator.free(out);

    try testing.expect(std.mem.indexOf(u8, out, "GROUND \u{00b7} 3 contacts") != null);
    try testing.expect(std.mem.indexOf(u8, out, "3\u{00d7} GND") != null);
    // The collapsed lane never emits a representative-name row.
    try testing.expect(std.mem.indexOf(u8, out, ">GND</text>") == null);
    try testing.expect(std.mem.indexOf(u8, out, "GND \u{00b7} GND") == null);
}

// spec: diagram/system_of_boards - The same system spec renders byte-identical SVG on every run
test "renderSystemSvg is deterministic" {
    const spec = fixture();
    const first = try render(testing.allocator, &spec);
    defer testing.allocator.free(first);
    const second = try render(testing.allocator, &spec);
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(first, second);
}

// spec: diagram/system_of_boards - A board-free system renders nothing while one-board and three-board systems still render
test "renderSystemSvg handles board counts other than two" {
    var spec = fixture();

    spec.boards = &.{};
    const none = try render(testing.allocator, &spec);
    defer testing.allocator.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);

    spec.boards = fixture_boards[0..1];
    const one = try render(testing.allocator, &spec);
    defer testing.allocator.free(one);
    try testing.expect(std.mem.indexOf(u8, one, "board-a") != null);
    try testing.expect(std.mem.endsWith(u8, one, "</svg></div>"));

    const three = fixture_boards ++ [_]BoardMember{.{
        .name = "board-a-fan",
        .role = "thermal",
        .source = "src/boards/board-a-fan.sexp",
        .part_number = "BOARD-A-FAN",
        .revision = "A1",
    }};
    spec.boards = &three;
    const wide = try render(testing.allocator, &spec);
    defer testing.allocator.free(wide);
    try testing.expect(std.mem.indexOf(u8, wide, "board-a-fan") != null);
    try testing.expect(std.mem.endsWith(u8, wide, "</svg></div>"));
}

// spec: diagram/system_of_boards - A system with no interface contracts renders its boards with an empty spine
test "renderSystemSvg renders boards for a system with no interfaces" {
    var spec = fixture();
    spec.interfaces = &.{};
    const out = try render(testing.allocator, &spec);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "board-a-base") != null);
    try testing.expect(std.mem.indexOf(u8, out, "j1-board-to-board") == null);
}

/// The same drawing as `render`, in the standalone-document form an archive
/// member takes.
fn renderDocument(allocator: Allocator, spec: *const SystemSpec) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    _ = try renderSystemDocumentSvg(allocator, spec, .{}, &aw.writer);
    return aw.toOwnedSlice();
}

// spec: diagram/system_of_boards - The document form is a standalone SVG root with its own namespace, intrinsic size and painted background, and draws the same body as the page fragment
test "renderSystemDocumentSvg emits a self-standing SVG document" {
    const spec = fixture();
    const document = try renderDocument(testing.allocator, &spec);
    defer testing.allocator.free(document);

    // A file, not a fragment: an `<svg>` root, no wrapper element, its own
    // namespace and intrinsic size, and a ground of its own to draw on.
    try testing.expect(std.mem.startsWith(u8, document, "<svg xmlns=\"http://www.w3.org/2000/svg\""));
    try testing.expect(std.mem.endsWith(u8, document, "</svg>"));
    try testing.expect(std.mem.indexOf(u8, document, "<div") == null);
    try testing.expect(std.mem.indexOf(u8, document, " width=\"") != null);
    try testing.expect(std.mem.indexOf(u8, document, "<rect width=\"100%\" height=\"100%\"") != null);
    // Same body as the page fragment: every board node still reads the same.
    try testing.expect(std.mem.indexOf(u8, document, "board-a-base") != null);
    try testing.expect(std.mem.indexOf(u8, document, "j1-board-to-board") != null);

    const again = try renderDocument(testing.allocator, &spec);
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(document, again);

    // A board-free system writes nothing at all, so the archive omits the
    // member rather than storing an empty file.
    var empty = fixture();
    empty.boards = &.{};
    const nothing = try renderDocument(testing.allocator, &empty);
    defer testing.allocator.free(nothing);
    try testing.expectEqual(@as(usize, 0), nothing.len);
}
