//! The board's CANONICAL COLOUR THEME — the single place that knows what
//! colour anything on a PCB is drawn in.
//!
//! `board_layers.zig` already owned the COPPER palette (one colour per physical
//! stack position, KiCad pcbnew's defaults). Everything else a board surface
//! paints — the canvas, the grid, courtyards, pads, holes, silkscreen, the
//! board edge, vias, the ratsnest, DRC markers, the selection, the airwire
//! classes, and the `?review=1` fabricated-board preview — used to be
//! hand-copied hex literals in FOUR places at once: the browser viewer
//! (`assets/pcb_board.js`), the server-side PNG renderer (`render_pcb_png.zig`),
//! the replay client (`assets/pcb_replay.js`) and the page stylesheet
//! (`assets/pcb_layout.css`). A colour changed in one of them silently
//! disagreed with the other three, and the PNG an agent reads then no longer
//! showed the board the human is looking at.
//!
//! So the theme lives HERE, once, beside the layer table it extends:
//!
//!   * Named comptime constants are what Zig reads (`render_pcb_png.zig`).
//!   * `board_entries` is the same set as an ordered wire table: the page ships
//!     it as `PCB.theme` for the browser clients and defines it as `:root`
//!     CSS custom properties for the stylesheet. One array, so a new colour
//!     reaches all three consumers by being added in one place.
//!   * `review_entries` is the fabricated-board preview palette (`PH` in the
//!     viewer), shipped as `PCB.theme.review`.
//!
//! Dependency-light like its sibling: only `std` and `board_layers`, so the
//! renderers, the page and the exporters can all derive from it without a
//! cycle. Nothing here decides WHAT is drawn — only what colour it is.

const std = @import("std");
const board_layers = @import("board_layers.zig");
const testing = std.testing;

// ── Copper ───────────────────────────────────────────────────────────────
// Not re-typed: the copper palette IS the layer table's, so an SMD pad on
// F.Cu, an F.Cu trace and the F.Cu row of the blob's layer table can never be
// three different reds.

/// F.Cu — the top copper face (`board_layers.signal_layer_colors[0]`).
pub const copper_top = board_layers.signal_layer_colors[0];
/// B.Cu — the bottom copper face (`board_layers.signal_layer_colors[1]`).
pub const copper_bottom = board_layers.signal_layer_colors[1];
/// The inner-layer palette, cycling by physical depth.
pub const copper_inner = board_layers.inner_layer_colors;

// ── Board objects ────────────────────────────────────────────────────────

/// Canvas behind the board — KiCad pcbnew's dark navy.
pub const background = "#001023";
/// The reference grid's dots/lines.
pub const grid_dot = "#2a3a4a";
/// A footprint's courtyard outline (KiCad magenta), drawn as `courtyard_wash`.
pub const courtyard = "#D864FF";
/// The courtyard colour as the viewer strokes it — dimmed to 35%.
pub const courtyard_wash = rgba(courtyard, "0.35");
/// Plated through-hole annulus (KiCad PTH gold).
pub const pad_pth = "#d0a028";
/// Non-plated hole rim — no copper, so it reads as bare board.
pub const pad_npth = "#26323e";
/// The drilled bore punched through a thru/NPTH pad: the canvas showing
/// through, so it is the background by definition.
pub const drill_bore = background;
/// F.Silkscreen.
pub const silk_front = "#F0F0F0";
/// B.Silkscreen.
pub const silk_back = "#E8B2C8";
/// Edge.Cuts — the committed board outline.
pub const edge_cuts = "#D0D2CD";
/// Via annulus (KiCad muted olive-gold).
pub const via = "#B2B27A";
/// A via's barrel — the canvas through the hole, like `drill_bore`.
pub const via_hole = background;
/// Ratsnest airwire (KiCad white), drawn as `ratsnest_wash`.
pub const ratsnest = "#ffffff";
/// The ratsnest as the viewer strokes it — thin white at 35%.
pub const ratsnest_wash = rgba(ratsnest, "0.35");
/// DRC violation marker (KiCad red-orange).
pub const drc = "#f4432c";
/// Selected copper / multi-selected courtyards.
pub const selection = "#d2a8ff";
/// Focus-mode highlight (`?nets=` / `?refs=` spotlight in the PNG).
pub const focus_accent = "#f5c542";
/// Hot decoupling loop / proximity-hug airwire.
pub const airwire_proximity = "#ea580c";
/// Ground-return airwire.
pub const airwire_ground = "#22b8cf";
/// Any other connection class — no special routing meaning.
pub const airwire_other = "#9aa7b4";
/// The L2 ground-return overlay under a decoupling loop's power leg.
pub const loop_return = "#58a6ff";

// ── PNG overlay chrome ───────────────────────────────────────────────────
// Text and the blame heatmap exist only in the rendered IMAGE (the browser
// draws its labels with page CSS), so they are named constants and stay OFF
// the wire — the viewer has no use for them.

/// An authored `(board … (keepout …))` region's wash, rim and label. The same
/// violet the viewer hatches a fixed keepout with (`paintFixedKeepouts` in
/// `serve/assets/pcb_board.js`), so the still image and the page agree.
pub const keepout_region = "#a855f7";
/// Header/label text in the rendered PNG.
pub const text = "#c9d1d9";
/// Secondary PNG label text.
pub const text_dim = "#7d8590";
/// An improvement in a compare render (Δ ≤ 0).
pub const improvement = "#3fb950";
/// Blame heatmap, cheap end.
pub const blame_low = "#15302a";
/// Blame heatmap, middle.
pub const blame_mid = "#b8860b";
/// Blame heatmap, expensive end.
pub const blame_high = "#c0392b";

// ── Fabricated-board preview (`?review=1`) ───────────────────────────────
// Green FR-4 solder mask, muted copper visible below it, and bare ENIG-like
// copper inside the mask openings. A deliberately DIFFERENT palette from the
// editor's: it answers "what will this look like back from the fab", not
// "what is on which layer", so it overrides nothing above.

/// Canvas behind the fabricated board.
pub const review_background = "#101815";
/// Solder mask over copper.
pub const review_mask = "#086b43";
/// The board edge where the mask and substrate meet it.
pub const review_edge = "#786744";
/// Bare finished copper inside a solder-mask opening.
pub const review_opening = "#a1854e";
/// FR-4 laminate with no copper under the mask.
pub const review_substrate = "#544b36";
/// Exposed copper (pads, hand-drawn copper).
pub const review_copper = "#cfaf62";
/// Copper read THROUGH the solder mask.
pub const review_copper_under = "#c0aa62";
/// A tented via — mask over the annulus.
pub const review_via_mask = "#417b50";
/// Non-plated hole rim.
pub const review_npth = "#313c35";
/// A drilled bore: the canvas through the board.
pub const review_hole = review_background;
/// Silkscreen ink.
pub const review_silk = "#f4f3e9";
/// The pin-1 marker every assembly drawing carries.
pub const review_pin1 = "#ff3b30";

/// One themed colour on the wire: the key browser clients read it by and the
/// value itself (a `#RRGGBB` hex or an `rgba(…)` string). The stylesheet's
/// custom property is deliberately NOT a third field — `cssProp` derives it
/// from the key, so a row names its colour once instead of twice.
pub const Entry = struct {
    /// `PCB.theme.<key>` — also the viewer's `TH.<key>` / `PH.<key>` name.
    key: []const u8,
    /// The colour.
    value: []const u8,
};

/// The board palette as the page ships it — `PCB.theme` for the browser
/// clients, `:root{…}` custom properties for the stylesheet. Order is the
/// emitted order, so the blob and the style block stay diffable.
///
/// One quoted string per row is load-bearing beyond taste: guardian.toml's
/// `theme-keys` [[concept]] rule reads this table's `.key = "…"` lines as the
/// family every browser mirror must carry, and that extraction takes EVERY
/// literal on a matching line. A second string here — the CSS property this
/// table used to spell out — enrolled 23 names no JS client has any business
/// knowing, which is what `cssProp` exists to keep out.
pub const board_entries = [_]Entry{
    .{ .key = "bg", .value = background },
    .{ .key = "gridDot", .value = grid_dot },
    .{ .key = "court", .value = courtyard_wash },
    .{ .key = "courtLine", .value = courtyard },
    .{ .key = "padTop", .value = copper_top },
    .{ .key = "padBot", .value = copper_bottom },
    .{ .key = "pth", .value = pad_pth },
    .{ .key = "npth", .value = pad_npth },
    .{ .key = "hole", .value = drill_bore },
    .{ .key = "silk", .value = silk_front },
    .{ .key = "silkBot", .value = silk_back },
    .{ .key = "edge", .value = edge_cuts },
    .{ .key = "via", .value = via },
    .{ .key = "viaHole", .value = via_hole },
    .{ .key = "rats", .value = ratsnest_wash },
    .{ .key = "ratsLine", .value = ratsnest },
    .{ .key = "drc", .value = drc },
    .{ .key = "sel", .value = selection },
    .{ .key = "accent", .value = focus_accent },
    .{ .key = "awProx", .value = airwire_proximity },
    .{ .key = "awGnd", .value = airwire_ground },
    .{ .key = "awOther", .value = airwire_other },
    .{ .key = "loopRet", .value = loop_return },
};

/// The two board keys whose CSS spelling is NOT their own name in kebab-case.
/// The copper faces are `padTop`/`padBot` on the wire and `--pcb-cu-top` /
/// `--pcb-cu-bot` in the stylesheet — a published custom property an embed's
/// own CSS may already override, so the historical spelling stays and is
/// listed here rather than being renamed to tidy up the derivation.
const css_overrides = [_][2][]const u8{
    .{ "padTop", "--pcb-cu-top" },
    .{ "padBot", "--pcb-cu-bot" },
};

/// The `--pcb-…` custom property a BOARD key defines: the key in kebab-case
/// under the shared prefix (`gridDot` → `--pcb-grid-dot`), or its
/// `css_overrides` entry. Comptime, because a property name is a compile-time
/// fact about its key exactly like the colour beside it — and because the
/// derivation is what keeps the two spellings from drifting apart.
fn cssProp(comptime key: []const u8) []const u8 {
    // Bound to a container-level constant so the property has real static
    // storage: a value assembled purely at comptime cannot be handed back out
    // of a call the emitter makes at run time.
    const Prop = struct {
        const text: []const u8 = if (cssOverride(key)) |o| o else "--pcb-" ++ kebab(key);
    };
    return Prop.text;
}

/// This key's published property name, or null when it derives from the key.
fn cssOverride(comptime key: []const u8) ?[]const u8 {
    for (css_overrides) |o| {
        if (std.mem.eql(u8, o[0], key)) return o[1];
    }
    return null;
}

/// `gridDot` → `grid-dot`: an upper-case letter opens a new hyphenated word.
/// Accumulated by comptime concatenation (like `rgba` above) rather than into a
/// local buffer, so nothing here is the address of a stack slot.
fn kebab(comptime key: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (key) |c| {
            if (std.ascii.isUpper(c)) out = out ++ "-";
            out = out ++ std.fmt.comptimePrint("{c}", .{std.ascii.toLower(c)});
        }
        return out;
    }
}

/// The fabricated-board preview palette, shipped as `PCB.theme.review`. No CSS
/// custom properties: only the canvas paints this palette.
pub const review_entries = [_]Entry{
    .{ .key = "bg", .value = review_background },
    .{ .key = "mask", .value = review_mask },
    .{ .key = "edge", .value = review_edge },
    .{ .key = "opening", .value = review_opening },
    .{ .key = "substrate", .value = review_substrate },
    .{ .key = "copper", .value = review_copper },
    .{ .key = "copperUnder", .value = review_copper_under },
    .{ .key = "viaMask", .value = review_via_mask },
    .{ .key = "npth", .value = review_npth },
    .{ .key = "hole", .value = review_hole },
    .{ .key = "silk", .value = review_silk },
    .{ .key = "pin1", .value = review_pin1 },
};

/// Emit the board palette as the PCB blob's `"theme":{…},` member: every
/// object colour flat under its viewer key, plus the fabricated-board preview
/// under `review`. The browser clients derive their `TH` / `PH` palettes from
/// this, so a colour changed here reaches the canvas without a JS edit.
pub fn writeBlobJson(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll("\"theme\":{");
    try writeJsonPairs(w, &board_entries);
    try w.writeAll(",\"review\":{");
    try writeJsonPairs(w, &review_entries);
    try w.writeAll("}},");
}

/// One palette as comma-separated JSON string members (no braces).
fn writeJsonPairs(w: *std.Io.Writer, entries: []const Entry) std.Io.Writer.Error!void {
    for (entries, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("\"{s}\":\"{s}\"", .{ e.key, e.value });
    }
}

/// Emit the same palette as a `:root{…}` block of CSS custom properties, so a
/// stylesheet paints board objects from the ONE theme. Every `var(…)` site
/// keeps the literal as its fallback, so a page that omits this block still
/// renders the identical colour. Only the board palette gets properties — the
/// fabricated-board preview is painted by the canvas alone.
pub fn writeCssVars(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(":root{");
    inline for (board_entries) |e| {
        try w.print("{s}:{s};", .{ cssProp(e.key), e.value });
    }
    try w.writeAll("}");
}

/// One colour as 8-bit channels.
pub const Channels = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};

/// Read a `#RRGGBB` theme value (or a bare `RRGGBB`) as channels. The ONE hex
/// parser on the Zig side, so a comptime constant and a layer-table row's
/// runtime colour string are decoded identically. Anything malformed reads
/// black rather than erroring — a colour is never worth failing a render over.
pub fn channels(hex: []const u8) Channels {
    const h = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
    if (h.len != 6) return .{};
    return .{ .r = pair(h[0..2]), .g = pair(h[2..4]), .b = pair(h[4..6]) };
}

/// One hex byte from two nibble characters.
fn pair(digits: []const u8) u8 {
    return nibble(digits[0]) *| 16 +| nibble(digits[1]);
}

/// One hex digit's value; anything else is 0 (see `channels`).
fn nibble(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// A theme hex as a CSS `rgba(…)` string at `alpha`, so a wash is never a
/// second hand-typed spelling of the colour it dims.
fn rgba(comptime hex: []const u8, comptime alpha: []const u8) []const u8 {
    const c = channels(hex);
    return std.fmt.comptimePrint("rgba({d},{d},{d},{s})", .{ c.r, c.g, c.b, alpha });
}

// spec: placement/optimizer - the board theme's copper entries are the shared layer table's own face colours and every wire entry is a well-formed colour
test "the board theme is one well-formed table built on the layer table" {
    // Copper is NOT re-typed here: the pad/trace colours ARE the table's rows.
    const outer = (board_layers.Stack{}).table();
    try testing.expectEqualStrings(outer.rows()[0].color(), copper_top);
    try testing.expectEqualStrings(outer.rows()[3].color(), copper_bottom);
    // …and the inner palette is the one the table cycles by physical depth.
    try testing.expectEqualStrings(outer.rows()[1].color(), copper_inner[0]);
    try testing.expectEqualStrings(outer.rows()[2].color(), copper_inner[1]);
    try testing.expectEqualStrings(copper_top, valueOf("padTop").?);
    try testing.expectEqualStrings(copper_bottom, valueOf("padBot").?);

    // Every wire entry is a usable CSS colour under a key no sibling repeats…
    try expectPalette(&board_entries);
    try expectPalette(&review_entries);
    // …and every board key derives the `--pcb-` property the stylesheet names.
    try expectDerivedProps();
}

/// Each entry of one palette is a well-formed colour under a key no sibling
/// repeats.
fn expectPalette(entries: []const Entry) !void {
    for (entries, 0..) |e, i| {
        try expectColor(e.value);
        for (entries[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, e.key, other.key));
    }
}

/// Every board key names a `--pcb-` custom property, kebab-cased from the key
/// itself unless `css_overrides` keeps a published spelling alive.
fn expectDerivedProps() !void {
    inline for (board_entries) |e| {
        try testing.expect(std.mem.startsWith(u8, cssProp(e.key), "--pcb-"));
    }
    try testing.expectEqualStrings("--pcb-bg", cssProp("bg"));
    try testing.expectEqualStrings("--pcb-grid-dot", cssProp("gridDot"));
    try testing.expectEqualStrings("--pcb-aw-other", cssProp("awOther"));
    // The two the derivation does NOT produce, kept by name for the stylesheet.
    try testing.expectEqualStrings("--pcb-cu-top", cssProp("padTop"));
    try testing.expectEqualStrings("--pcb-cu-bot", cssProp("padBot"));
}

// spec: placement/optimizer - a theme wash is its own base colour at an alpha, decoded by the one hex parser
test "theme washes are the base colour and hex decoding is total" {
    try testing.expectEqualStrings("rgba(216,100,255,0.35)", courtyard_wash);
    try testing.expectEqualStrings("rgba(255,255,255,0.35)", ratsnest_wash);
    try testing.expectEqual(Channels{ .r = 0xC8, .g = 0x34, .b = 0x34 }, channels(copper_top));
    try testing.expectEqual(Channels{ .r = 0x4D, .g = 0x7F, .b = 0xC4 }, channels("4D7FC4"));
    // Malformed input reads black instead of trapping — see `channels`.
    try testing.expectEqual(Channels{}, channels(""));
    try testing.expectEqual(Channels{}, channels("#12345"));
    try testing.expectEqual(Channels{}, channels("#zzzzzz"));
}

// spec: placement/optimizer - the board theme emits once as a blob object and once as :root CSS custom properties, carrying the same values
test "the theme's two wire formats carry the same palette" {
    var blob: std.Io.Writer.Allocating = .init(testing.allocator);
    defer blob.deinit();
    try writeBlobJson(&blob.writer);
    try testing.expect(std.mem.startsWith(u8, blob.written(), "\"theme\":{\"bg\":\"#001023\","));
    try testing.expect(std.mem.endsWith(u8, blob.written(), "}},"));
    // The fab preview rides along under `review`, keyed as the viewer's PH.
    try testing.expect(std.mem.indexOf(u8, blob.written(), ",\"review\":{\"bg\":\"#101815\"") != null);
    try testing.expect(std.mem.indexOf(u8, blob.written(), "\"copperUnder\":\"#c0aa62\"") != null);

    var css: std.Io.Writer.Allocating = .init(testing.allocator);
    defer css.deinit();
    try writeCssVars(&css.writer);
    try testing.expect(std.mem.startsWith(u8, css.written(), ":root{--pcb-bg:#001023;"));
    try testing.expect(std.mem.endsWith(u8, css.written(), "}"));
    // …and only the board palette: no stylesheet paints the fab preview.
    try testing.expect(std.mem.indexOf(u8, css.written(), "#101815") == null);

    try expectBothWires(blob.written(), css.written());
}

/// Every board entry reaches BOTH wires — the blob object the browser clients
/// derive their palettes from, and the custom property a `var(…)` names.
fn expectBothWires(blob: []const u8, css: []const u8) !void {
    var buf: [96]u8 = undefined;
    inline for (board_entries) |e| {
        const member = try std.fmt.bufPrint(&buf, "\"{s}\":\"{s}\"", .{ e.key, e.value });
        try testing.expect(std.mem.indexOf(u8, blob, member) != null);
        const prop = try std.fmt.bufPrint(&buf, "{s}:{s};", .{ cssProp(e.key), e.value });
        try testing.expect(std.mem.indexOf(u8, css, prop) != null);
    }
}

/// The wire value of a board-palette key, or null when the theme has no such
/// colour.
fn valueOf(key: []const u8) ?[]const u8 {
    for (board_entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
    return null;
}

/// A theme value is a `#RRGGBB` hex or an `rgba(…)` string — the two spellings
/// every consumer (canvas, CSS, PNG) accepts.
fn expectColor(value: []const u8) !void {
    if (std.mem.startsWith(u8, value, "rgba(")) {
        try testing.expect(std.mem.endsWith(u8, value, ")"));
        return;
    }
    try testing.expectEqual(@as(usize, 7), value.len);
    try testing.expectEqual(@as(u8, '#'), value[0]);
    for (value[1..]) |c| try testing.expect(std.ascii.isHex(c));
}
