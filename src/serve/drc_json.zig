//! DRC violation JSON — the single serialization every DRC-carrying endpoint
//! shares (/api/pcb-drc, /api/pcb-route, the embedded page blob, and
//! /api/pcb-describe's drc_list), so a violation's short traceable `id` can
//! never drift between surfaces: a user quoting "#a3f2" from the viewer's
//! inspector resolves to the same record everywhere.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const drc = @import("../placement/drc.zig");
const optimizer = @import("../placement/optimizer.zig");

/// The human-readable kind word for a violation, shared by the JSON writer
/// and the viewer's tooltips/panel rows (and the DRC-rules settings table).
pub fn kindStr(k: drc.Kind) []const u8 {
    return switch (k) {
        .via_pad => "via↔pad",
        .via_via => "via↔via",
        .via_spacing => "via spacing",
        .via_track => "via↔track",
        .track_track => "track↔track",
        .track_pad => "track↔pad",
        .pad_pad => "pad↔pad",
        .annular => "annular ring",
        .pad_annular => "pad annular ring",
        .board_edge => "board edge",
        .component_edge => "component edge",
        .courtyard => "courtyard overlap",
        .hole_hole => "hole↔hole",
        .min_drill => "min drill",
        .track_width => "track width",
        .power_width => "power width",
        .via_current => "via current",
        .via_current_envelope => "via current envelope",
        .pour_invalid => "invalid copper pour",
        .pour_overlap => "pour overlap",
        .copper_stub => "copper stub",
        .implicit_junction => "implicit trace junction",
        .hairline_gap => "hairline gap",
        .dangling_copper => "dangling copper",
        .single_layer_via => "single-layer via",
        .redundant_via => "redundant via",
        .land_transit => "copper on own land",
        .ground_via_distance => "ground via too far",
        .reference_plane_gap => "reference plane gap",
        .reference_transition => "reference transition",
        .loop_area => "return loop area",
        .bypass_open => "bypass open",
        .silk_over_pad => "silkscreen overlap",
        .diff_uncoupled => "diff uncoupled",
        .diff_skew => "diff skew",
        .length_mismatch => "length mismatch",
        .sharp_bend => "sharp RF bend",
        .keepout_violation => "keepout",
        .perimeter_keepout => "perimeter keepout",
        .board_keepout => "board keepout",
        .net_open => "net open",
    };
}

/// One section of the `/pcb-layout` settings drawer's DRC-policy table: the
/// heading, the line under it, and the kinds it lists in the order it lists
/// them. `kinds` is `drc.Kind`, not text, so a renamed kind is a rename here
/// and cannot silently fall out of the drawer.
pub const DrawerGroup = struct {
    title: []const u8,
    blurb: []const u8,
    kinds: []const drc.Kind,
};

/// How the DRC-policy drawer sections the checks, in display order. This table
/// used to live in `assets/pcb_settings.js` as six hand-written arrays of kind
/// id STRINGS — so renaming a kind in Zig dropped it out of its section while
/// the check kept firing, and adding one left it ungrouped. Grouping is decided
/// here and shipped to the client, and `comptime` below proves the table is
/// total, which is the part a text list could never do.
pub const drawer_groups = [_]DrawerGroup{
    .{
        .title = "Copper clearance",
        .blurb = "Edge-to-edge spacing between copper features that belong to different nets.",
        .kinds = &.{ .track_track, .track_pad, .pad_pad, .via_track, .via_pad, .via_via, .pour_overlap },
    },
    .{
        .title = "Drill & annular ring",
        .blurb = "Plated-hole geometry the fabricator has to be able to hit reliably.",
        .kinds = &.{ .annular, .pad_annular, .hole_hole, .min_drill, .via_spacing },
    },
    .{
        .title = "Fabrication limits",
        .blurb = "Board-level minimums, the routed outline, and assembly hygiene.",
        .kinds = &.{ .track_width, .pour_invalid, .board_edge, .component_edge, .courtyard, .silk_over_pad },
    },
    .{
        .title = "Electrical quality",
        .blurb = "Power capacity, controlled-impedance, and RF routing discipline.",
        .kinds = &.{ .power_width, .via_current, .via_current_envelope, .diff_uncoupled, .diff_skew, .length_mismatch, .sharp_bend, .ground_via_distance, .reference_plane_gap, .reference_transition, .loop_area, .bypass_open },
    },
    .{
        .title = "Keepouts",
        .blurb = "Authored regions that reserve space from selected board features.",
        .kinds = &.{ .keepout_violation, .perimeter_keepout, .board_keepout },
    },
    .{
        .title = "Connectivity",
        .blurb = "Every trace must terminate on useful same-net copper, every via must join layers, and every net must form one connected piece.",
        .kinds = &.{ .copper_stub, .implicit_junction, .hairline_gap, .dangling_copper, .single_layer_via, .redundant_via, .land_transit, .net_open },
    },
};

/// How many `drawer_groups` entries list `kind` — exactly 1 for every kind,
/// proven at comptime just below and re-stated by this module's test.
fn drawerGroupHits(kind: drc.Kind) usize {
    var found: usize = 0;
    for (drawer_groups) |group| {
        for (group.kinds) |member| {
            if (member == kind) found += 1;
        }
    }
    return found;
}

// Every `drc.Kind` sits in exactly one drawer group. A 28th kind therefore
// fails the BUILD until someone decides where it belongs, which is the whole
// point of moving the grouping off a JS string list: the old copy could only
// be wrong at runtime, and only in the drawer, where nobody was looking.
comptime {
    const kind_count = @typeInfo(drc.Kind).@"enum".field_names.len;
    var group_hits: [kind_count]u8 = @splat(0);
    for (drawer_groups) |group| {
        for (group.kinds) |kind| group_hits[@backingInt(kind)] += 1;
    }
    for (
        @typeInfo(drc.Kind).@"enum".field_names,
        @typeInfo(drc.Kind).@"enum".field_values,
    ) |fname, fval| {
        const kind: drc.Kind = @fromBackingInt(@intCast(fval));
        if (group_hits[@backingInt(kind)] != 1) @compileError(
            "DRC kind '" ++ fname ++ "' must appear in exactly one drc_json.drawer_groups entry — " ++
                "the settings drawer sections the policy table from it",
        );
    }
}

/// Emit the drawer's section table as JSON: `[{"title":…,"blurb":…,"kinds":[…]}]`.
/// The client renders one section per entry and reads each kind out of the
/// `drc_kinds` table by id, so it never spells a kind itself.
pub fn writeDrawerGroupsJson(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (drawer_groups, 0..) |group, gi| {
        if (gi > 0) try w.writeByte(',');
        try w.print("{{\"title\":\"{s}\",\"blurb\":\"{s}\",\"kinds\":[", .{ group.title, group.blurb });
        for (group.kinds, 0..) |kind, ki| {
            if (ki > 0) try w.writeByte(',');
            try w.print("\"{s}\"", .{@tagName(kind)});
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');
}

/// The severity word, matching `drc.Violation.severity` — surfaced so the
/// viewer chip can split error / warning counts.
fn sevStr(sev: drc.Severity) []const u8 {
    return switch (sev) {
        .err => "err",
        .warn => "warn",
    };
}

/// A violation coordinate quantized for hashing: rounded at `scale`, then
/// biased positive so the u64 conversion never sees a negative value (board
/// coordinates are tens of mm — nowhere near the 4e9 bias).
fn quant(val: f64, scale: f64) u64 {
    // A checker may use infinity to mean "no matching feature exists" (for
    // example, a diff-pair leg with no partner copper on the same layer).
    // Invalid geometry still needs a stable UI locator, and must never reach
    // @intFromFloat.
    if (!std.math.isFinite(val)) return 0;
    return @intFromFloat(@round(val * scale) + 4_000_000_000);
}

/// Deterministic short id for a DRC violation: FNV-1a over the kind word, the
/// COPPER LAYER (255 = "no single layer"), the marker position quantized to
/// 0.01 mm, and the broken rule (0.001 mm), folded to 16 bits → 4 hex chars.
/// Stable across re-checks of the same board state — the same defect keeps the
/// same id run to run. The layer is in the hash because without it two defects
/// of one kind at one x/y on DIFFERENT layers — an inner and an outer track
/// crossing the same pad column, say — collided onto one id, and the id is what
/// the viewer's inspector, the DRC pane's ‹ › steps and a user quoting "#a3f2"
/// all locate by. Ids are ephemeral UI locators, never persisted, so widening
/// the hash costs nothing.
fn violationId(v: drc.Violation) u16 {
    var h: u32 = 0x811c9dc5;
    for (kindStr(v.kind)) |c| {
        h = (h ^ c) *% 0x01000193;
    }
    h = (h ^ layerByte(v)) *% 0x01000193;
    const q = [3]u64{ quant(v.x, 100), quant(v.y, 100), quant(v.clearance, 1000) };
    for (q) |val| {
        var u: u64 = val;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            h = (h ^ @as(u8, @truncate(u))) *% 0x01000193;
            u >>= 8;
        }
    }
    return @truncate(h ^ (h >> 16));
}

/// A violation's layer as one hash byte: its routable index, or 255 for a
/// finding with no single layer (a courtyard clash, a hole rule, a through
/// barrel). 255 is safe as the sentinel — `board_layers.max_signal_layers` is
/// 64, so no real routable index can reach it.
fn layerByte(v: drc.Violation) u8 {
    const layer = v.layer orelse return 255;
    return layer.int();
}

/// The tables that turn a violation's `who` indices into names. Defaulted to
/// empty so a caller with no placement in hand still emits valid JSON (the
/// `a`/`b` party objects simply don't appear).
pub const Names = struct {
    nets: []const optimizer.FlatNet = &.{},
    parts: []const optimizer.Part = &.{},
};

/// One party of a violation, resolved to names: the net it belongs to and the
/// pad (`ref` + `pad`) it sits on, each empty when that side has none.
const Party = struct {
    net: []const u8 = "",
    ref: []const u8 = "",
    pad: []const u8 = "",

    fn known(self: Party) bool {
        return self.net.len > 0 or self.ref.len > 0;
    }
};

/// Resolve one side of `who` through `names`; out-of-range indices resolve to
/// blanks (a stale index must degrade to "unnamed", never to a wrong name).
fn party(names: Names, net: i32, part: i32, pad: []const u8) Party {
    var out = Party{ .pad = pad };
    if (net >= 0 and @as(usize, @intCast(net)) < names.nets.len) out.net = names.nets[@intCast(net)].name;
    if (part >= 0 and @as(usize, @intCast(part)) < names.parts.len) out.ref = names.parts[@intCast(part)].ref_des;
    if (out.ref.len == 0) out.pad = ""; // a pad number without its part names nothing
    return out;
}

/// `,"a":{…}` — one party object, omitted entirely when nothing is known about
/// that side (so a violation with no identity stays byte-identical to before).
fn writeParty(w: *std.Io.Writer, key: []const u8, p: Party) std.Io.Writer.Error!void {
    if (!p.known()) return;
    try w.print(",\"{s}\":{{", .{key});
    const fields = [_][2][]const u8{ .{ "net", p.net }, .{ "ref", p.ref }, .{ "pad", p.pad } };
    var written: usize = 0;
    for (fields) |f| {
        if (f[1].len == 0) continue;
        if (written > 0) try w.writeAll(",");
        written += 1;
        try w.print("\"{s}\":", .{f[0]});
        try writeJsonStr(w, f[1]);
    }
    try w.writeAll("}");
}

/// Minimal JSON string escaping — net names and ref-des come from user source,
/// so a quote or backslash in one must not break the payload.
fn writeJsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("\"");
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (ch < 0x20) try w.print("\\u{x:0>4}", .{ch}) else try w.writeByte(ch),
    };
    try w.writeAll("\"");
}

/// JSON has no NaN or infinity literals. Preserve the absence of a finite
/// measurement as `null`; every DRC consumer already renders null as `?`.
fn writeFiniteNumber(w: *std.Io.Writer, value: f64) std.Io.Writer.Error!void {
    if (std.math.isFinite(value)) return w.print("{d}", .{value});
    return w.writeAll("null");
}

/// One violation as a JSON object, `id` first, then `"l"` (the routable copper
/// layer, OMITTED when the finding has no single layer), an optional four-value
/// open-net `bridge`, then the `a`/`b` parties (nets / pads that clashed)
/// whenever the checker could name them.
pub fn writeViolation(w: *std.Io.Writer, v: drc.Violation, names: Names) std.Io.Writer.Error!void {
    try w.print("{{\"id\":\"{x:0>4}\",\"x\":", .{violationId(v)});
    try writeFiniteNumber(w, v.x);
    try w.writeAll(",\"y\":");
    try writeFiniteNumber(w, v.y);
    try w.writeAll(",\"gap\":");
    try writeFiniteNumber(w, v.gap);
    try w.writeAll(",\"clr\":");
    try writeFiniteNumber(w, v.clearance);
    try w.print(",\"k\":\"{s}\",\"sev\":\"{s}\"", .{ kindStr(v.kind), sevStr(v.severity) });
    if (v.layer) |layer| try w.print(",\"l\":{d}", .{layer.int()});
    if (v.who.bridge) |b| {
        try w.writeAll(",\"bridge\":[");
        for (b, 0..) |value, i| {
            if (i > 0) try w.writeByte(',');
            try writeFiniteNumber(w, value);
        }
        try w.writeByte(']');
    }
    try writeParty(w, "a", party(names, v.who.net_a, v.who.part_a, v.who.pad_a));
    try writeParty(w, "b", party(names, v.who.net_b, v.who.part_b, v.who.pad_b));
    try w.writeAll("}");
}

// Regression for barracuda: a diff-pair split across copper layers has no
// finite same-layer separation, which used to emit bare `inf` into `const
// PCB=...` and abort every board script that followed it.
test "non-finite DRC measurements serialize as valid JSON nulls" {
    const v = drc.Violation{
        .x = 188.6,
        .y = 104.625,
        .gap = std.math.inf(f64),
        .clearance = 0.622,
        .kind = .diff_uncoupled,
        .severity = .warn,
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeViolation(&aw.writer, v, .{});

    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "inf") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, aw.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("gap").? == .null);
}

// spec: Web Server - A DRC violation carries a stable 4-hex id emitted by the shared JSON writer
test "violation id is deterministic, position-sensitive, and 4 hex chars in the JSON" {
    const v = drc.Violation{ .x = 2.05, .y = -3.7, .gap = 0, .clearance = 0.25, .kind = .hole_hole };
    const same = drc.Violation{ .x = 2.05, .y = -3.7, .gap = 0, .clearance = 0.25, .kind = .hole_hole };
    try std.testing.expectEqual(violationId(v), violationId(same));
    const moved = drc.Violation{ .x = 2.06, .y = -3.7, .gap = 0, .clearance = 0.25, .kind = .hole_hole };
    try std.testing.expect(violationId(v) != violationId(moved));
    const other = drc.Violation{ .x = 2.05, .y = -3.7, .gap = 0, .clearance = 0.25, .kind = .via_via };
    try std.testing.expect(violationId(v) != violationId(other));
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeViolation(&aw.writer, v, .{});
    const out = aw.written();
    try std.testing.expect(std.mem.startsWith(u8, out, "{\"id\":\""));
    try std.testing.expectEqual(@as(u8, '"'), out[11]); // exactly 4 hex chars
    try std.testing.expect(std.mem.indexOf(u8, out, "\"k\":\"hole↔hole\"") != null);
}

// Regression guard for the shared wire representation of the checker probes.
test "net-open bridge probes serialize only when present" {
    const open = drc.Violation{
        .x = 5,
        .y = 0,
        .gap = 0.4,
        .clearance = 0,
        .kind = .net_open,
        .who = .{ .bridge = .{ 4.7, 0, 5.3, 0 } },
    };
    var with_bridge: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer with_bridge.deinit();
    try writeViolation(&with_bridge.writer, open, .{});
    try std.testing.expect(std.mem.indexOf(u8, with_bridge.written(), "\"bridge\":[4.7,0,5.3,0]") != null);

    var ordinary: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer ordinary.deinit();
    try writeViolation(&ordinary.writer, .{ .x = 1, .y = 2, .gap = 0, .clearance = 0.2, .kind = .hole_hole }, .{});
    try std.testing.expect(std.mem.indexOf(u8, ordinary.written(), "\"bridge\"") == null);
}

// spec: Web Server - A per-layer DRC violation carries its copper layer on the wire and in its id, so two defects at one point on different layers stay distinct
test "a violation's copper layer is emitted and folded into its id" {
    const base = drc.Violation{ .x = 4, .y = 5, .gap = 0.05, .clearance = 0.2, .kind = .track_track };
    const on_top = drc.Violation{ .x = 4, .y = 5, .gap = 0.05, .clearance = 0.2, .kind = .track_track, .layer = .top };
    const on_inner = drc.Violation{ .x = 4, .y = 5, .gap = 0.05, .clearance = 0.2, .kind = .track_track, .layer = board_layers.SignalIndex.of(2) };

    // Same defect, same layer ⇒ same id; the SAME point on another layer is a
    // different defect and gets a different locator (it used to collide).
    try std.testing.expectEqual(violationId(on_top), violationId(on_top));
    try std.testing.expect(violationId(on_top) != violationId(on_inner));
    // "No single layer" is its own value, distinct from layer 0.
    try std.testing.expect(violationId(base) != violationId(on_top));

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeViolation(&aw.writer, on_inner, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"sev\":\"err\",\"l\":2") != null);

    // A layerless finding omits the key entirely, so its JSON is unchanged.
    var bare: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bare.deinit();
    try writeViolation(&bare.writer, .{ .x = 1, .y = 2, .gap = 0, .clearance = 0.25, .kind = .courtyard }, .{});
    try std.testing.expect(std.mem.indexOf(u8, bare.written(), "\"l\":") == null);

    // The viewer prints the layer NAME when the key is there.
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "pRow(\"Layer\",layerName(o.l))") != null);
}

// spec: Web Server - The shared DRC JSON writer emits each violation's named parties and omits the sides the checker could not name
test "the violation JSON names the nets and pads a violation is between" {
    const nets = [_]optimizer.FlatNet{ .{ .name = "GND", .pins = &.{} }, .{ .name = "VDD3V3", .pins = &.{} } };
    const parts = [_]optimizer.Part{
        .{ .ref_des = "U7", .kind = .hub, .hw = 1, .hh = 1, .pads = &.{}, .fallback = false },
    };
    const names = Names{ .nets = &nets, .parts = &parts };

    // A track↔pad clash: net-only on the A side, net + part + pad on the B side.
    const v = drc.Violation{
        .x = 1,
        .y = 2,
        .gap = 0.08,
        .clearance = 0.15,
        .kind = .track_pad,
        .who = .{ .net_a = 0, .net_b = 1, .part_b = 0, .pad_b = "12" },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeViolation(&aw.writer, v, names);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "\"a\":{\"net\":\"GND\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"b\":{\"net\":\"VDD3V3\",\"ref\":\"U7\",\"pad\":\"12\"}") != null);

    // A violation the checker could not name emits NO party objects at all, so
    // an un-named producer's JSON is unchanged.
    var bare: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bare.deinit();
    try writeViolation(&bare.writer, .{ .x = 1, .y = 2, .gap = 0, .clearance = 0.25, .kind = .hole_hole }, names);
    try std.testing.expect(std.mem.indexOf(u8, bare.written(), "\"a\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, bare.written(), "\"b\":") == null);

    // An index with no table behind it resolves to blank, never to a wrong name.
    var stale: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stale.deinit();
    try writeViolation(&stale.writer, v, .{});
    try std.testing.expect(std.mem.indexOf(u8, stale.written(), "\"a\":") == null);
}

// spec: Web Server - The DRC policy drawer sections its checks from one server-shipped grouping table that covers every violation kind exactly once
test "the drawer grouping table covers every DRC kind once and ships it as JSON" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeDrawerGroupsJson(&aw.writer);
    const out = aw.written();

    // Totality, the property the JS copy could not hold: every kind sits in
    // exactly one group, no group names a kind twice, and every kind reaches
    // the client by its enum id. The comptime block above already fails the
    // BUILD on a miss — this states the same claim where a reader will look.
    inline for (
        @typeInfo(drc.Kind).@"enum".field_names,
        @typeInfo(drc.Kind).@"enum".field_values,
    ) |fname, fval| {
        try std.testing.expectEqual(@as(usize, 1), drawerGroupHits(@fromBackingInt(@intCast(fval))));
        try std.testing.expect(std.mem.indexOf(u8, out, "\"" ++ fname ++ "\"") != null);
    }

    try std.testing.expect(std.mem.startsWith(u8, out, "[{\"title\":\"Copper clearance\","));
    try std.testing.expect(std.mem.endsWith(u8, out, "]}]"));
    try std.testing.expectEqual(drawer_groups.len, std.mem.count(u8, out, "\"blurb\":"));
}
