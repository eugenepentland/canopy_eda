//! Grouped decoupling banks for the `.kicad_sch` exporter.
//!
//! Bypass capacitors are most of a board's passives, and giving each one its
//! own pair of net labels — or, since the wiring pass, its own point-to-point
//! run to the pad it serves — scatters a rail's decoupling across the whole
//! cell grid and crosses those runs over one another. A sheet drawn by hand
//! does the opposite: every cap on one rail is ganged in parallel between a
//! single horizontal rail wire and a single ground wire, under one net label.
//! Planning that arrangement is this module's whole job.
//!
//! Two halves, both pure:
//!
//!   * **Membership** — which caps gang together. A candidate is a
//!     two-terminal capacitor with one leg on a ground-class net and the other
//!     on a rail, either because it declares a `(decouples …)` target or
//!     because the net reads like a supply by the project's existing
//!     classifiers. Caps sharing a cluster, a rail and a ground form one bank;
//!     a group of one is left alone, because a lone cap's label pair is
//!     already as compact as a drawing gets, and a cap whose geometry is not
//!     the plain two-terminal glyph is left alone too — it falls back to
//!     labels rather than to a wire nobody can follow.
//!   * **Geometry** — where the ganged parts, the two rails, the terminating
//!     label and the ground symbol go, given the bank's own corner on the
//!     sheet. Everything lands on the 1.27 mm connection grid, because an
//!     off-grid endpoint is an ERC warning each.
//!
//! The rails are deliberately drawn as one two-point wire per span, broken at
//! every tap: KiCad joins wires end to end, and a wire ending on another
//! wire's *interior* does not connect at all (it reports
//! `unconnected_wire_endpoint`). Broken spans make each tap a real end, which
//! is also what puts three ends — and so a junction dot — at every interior
//! column.

const std = @import("std");
const decouple_key = @import("../decouple_key.zig");
const draw = @import("../render_svg/draw.zig");
const rails = @import("../eval/rails.zig");
const pin_roles = @import("../placement/pin_roles.zig");
const emit = @import("emit.zig");
const sheet_mod = @import("sheet.zig");
const shape_mod = @import("shape.zig");
const wire = @import("wire.zig");
const net_name = @import("../net_name.zig");

const grid = shape_mod.grid;

/// Fewest caps that make a bank. One cap ganged onto its own private rail is
/// just a longer way to draw the label pair it already had, so a lone
/// candidate keeps today's drawing.
pub const min_members: usize = 2;

/// Vertical clearance between a member's leg endpoint and the rail it taps.
const rail_gap: i32 = 254;

/// How far both rails run to the left of the first member, ending at the net
/// label above and the ground symbol below.
const lead: i32 = 762;

/// Narrowest column pitch, before a long ref-des or value widens it.
const min_pitch: i32 = 762;

/// Sheet space one character of ref-des or value text needs. KiCad's stroke
/// font advances about one grid step per character at the 1.27 mm size every
/// property is written in, measured off a rendered bank.
const char_w: i32 = grid;

/// Clearance kept between the end of a member's text and the next member's
/// body: a turned cap reaches `half_h` sideways, plus a grid step of air.
const body_clear: i32 = 381;

/// Longest text run allowed to widen a column, so one pathological ref-des
/// cannot stretch a bank across the page.
const max_text_chars: usize = 24;

/// Room above the power rail for the bank's caption, and below the ground rail
/// for the ground symbol's body.
const top_pad: i32 = 762;
const bottom_pad: i32 = 762;

/// One capacitor offered to the grouper, already resolved against its sheet.
pub const Candidate = struct {
    /// Index of the placeable inside its cluster's run.
    item: u32,
    ref: []const u8,
    value: []const u8,
    /// Label text of the leg on the rail, and of the leg on ground.
    power: []const u8,
    gnd: []const u8,
    /// Which pin of the two-terminal unit carries the rail; the other is the
    /// ground leg.
    power_pin: u32,
    /// How far both pins reach from the symbol origin.
    reach: i32,
};

/// One member of a planned bank, in draw order.
pub const Member = struct { item: u32, power_pin: u32 };

/// One planned bank: the caps ganged between one rail and one ground.
pub const Bank = struct {
    power: []const u8,
    gnd: []const u8,
    /// Ref-des of the leading member — unique on the sheet, so it is what the
    /// bank's wire and label uuids are derived from.
    key: []const u8,
    members: []const Member,
    reach: i32,
    /// Column spacing, widened from `min_pitch` to hold the widest member's
    /// ref-des and value text.
    pitch: i32,
};

/// Where one planned bank's parts and wires land, once its cell has a place on
/// the sheet. `x`/`y` is the centre of the first (leftmost) member.
pub const Frame = struct {
    x: i32,
    y: i32,
    reach: i32,
    pitch: i32,

    /// Centre of the `k`-th member's symbol.
    pub fn memberX(self: Frame, k: usize) i32 {
        return self.x + @as(i32, @intCast(k)) * self.pitch;
    }

    /// The rail wire the members' upper legs tap.
    pub fn powerY(self: Frame) i32 {
        return self.y - self.reach - rail_gap;
    }

    /// The ground wire the members' lower legs tap.
    pub fn gndY(self: Frame) i32 {
        return self.y + self.reach + rail_gap;
    }

    /// Left end of both rails: the net label terminates the upper one there and
    /// the ground symbol the lower one.
    pub fn endX(self: Frame) i32 {
        return self.x - lead;
    }

    /// Sheet y of a member's upper (rail) leg endpoint.
    pub fn powerPinY(self: Frame) i32 {
        return self.y - self.reach;
    }

    /// Sheet y of a member's lower (ground) leg endpoint.
    pub fn gndPinY(self: Frame) i32 {
        return self.y + self.reach;
    }
};

/// True when a net name reads like a power rail caps may be ganged onto. Both
/// halves are the project's own classifiers — the placement optimizer's
/// supply-pin heuristic and the rails pass's "does this read like a supply
/// rail" test — so no new naming rule is invented here. A rail whose name
/// matches neither (a bare voltage literal like `3V3`) still banks when its
/// caps declare a `(decouples …)` target, which is the stronger signal anyway.
pub fn isSupplyNet(name: []const u8) bool {
    const short = draw.shortNetName(name);
    if (pin_roles.isSupplyFn(short)) return true;
    return rails.looksLikeRail(short);
}

/// Rotation that stands a member on end with its rail leg up and its ground
/// leg down. KiCad turns a placed symbol counter-clockwise in the library's
/// y-UP frame while the sheet is y-DOWN, so a quarter turn sends the pin at
/// positive library x to the TOP of the sheet.
pub fn angleFor(power_pin_x: i32) u32 {
    return if (power_pin_x > 0) 90 else 270;
}

/// The two-terminal reach of a unit that can be ganged: both pins on the
/// symbol's own centre line, mirrored about the origin. Null for anything
/// else — a three-pin part, a vendor body whose pins sit anywhere else — which
/// is what makes an odd cap fall back to its labels instead of to a drawing
/// that would not line up.
pub fn reachOf(u: shape_mod.Unit) ?i32 {
    if (u.pins.len != 2) return null;
    if (u.pins[0].y != 0 or u.pins[1].y != 0) return null;
    if (u.pins[0].x != -u.pins[1].x) return null;
    const r = @abs(u.pins[0].x);
    return if (r == 0) null else @intCast(r);
}

/// Group candidates into banks, one per (rail, ground) pair, dropping any pair
/// with too few members. Order is first-appearance of each pair, and members
/// are sorted smallest capacitance first — so the bulk reservoirs, always the
/// largest, end the row exactly as a hand-drawn bank puts them.
pub fn group(
    arena: std.mem.Allocator,
    cands: []const Candidate,
) std.mem.Allocator.Error![]const Bank {
    var by_pair: std.array_hash_map.String(std.ArrayList(u32)) = .empty;
    defer by_pair.deinit(arena);
    for (cands, 0..) |c, i| {
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ c.power, c.gnd });
        const gop = try by_pair.getOrPut(arena, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(arena, @intCast(i));
    }

    var out: std.ArrayList(Bank) = .empty;
    for (by_pair.values()) |*run| {
        if (run.items.len < min_members) continue;
        std.mem.sort(u32, run.items, cands, lessCandidate);
        try out.append(arena, try oneBank(arena, cands, run.items));
    }
    return out.items;
}

fn oneBank(
    arena: std.mem.Allocator,
    cands: []const Candidate,
    run: []const u32,
) std.mem.Allocator.Error!Bank {
    const members = try arena.alloc(Member, run.len);
    for (run, members) |i, *m| {
        m.* = .{ .item = cands[i].item, .power_pin = cands[i].power_pin };
    }
    return .{
        .power = cands[run[0]].power,
        .gnd = cands[run[0]].gnd,
        .key = cands[run[0]].ref,
        .members = members,
        .reach = cands[run[0]].reach,
        .pitch = pitchFor(cands, run),
    };
}

/// Column spacing wide enough for the widest member's own text, since a ganged
/// part's Reference and Value read to its right and would otherwise run into
/// its neighbour's body.
fn pitchFor(cands: []const Candidate, run: []const u32) i32 {
    var widest: usize = 0;
    for (run) |i| {
        widest = @max(widest, @max(cands[i].ref.len, cands[i].value.len));
    }
    const chars: i32 = @intCast(@min(widest, max_text_chars));
    return sheet_mod.snapUp(@max(min_pitch, emit.banked_text_dx + chars * char_w + body_clear));
}

fn lessCandidate(cands: []const Candidate, x: u32, y: u32) bool {
    const fx = farads(cands[x].value);
    const fy = farads(cands[y].value);
    if (fx != fy) return fx < fy;
    return std.mem.order(u8, cands[x].ref, cands[y].ref) == .lt;
}

/// Parse a capacitance string to farads; 0 when it is unrecognised, which simply
/// sorts such a member to the head of the row. Shared with the ERC pass and the
/// module-policy role detector via `decouple_key`, which imports nothing but
/// `std` — so the exporter still pulls in neither of them to read a value string.
const farads = decouple_key.capFarads;

/// The cell a bank occupies inside its cluster's packing: the rails' lead and
/// the label terminating them on the left, one column per member, and room
/// above for the caption and below for the ground symbol's body. `label_w` is
/// the sheet space the caller reserves for the rail's own net label, which
/// runs leftward from the rails' end.
pub fn cellFor(b: Bank, label_w: i32) sheet_mod.Cell {
    const ox = label_w + lead;
    const oy = top_pad + rail_gap + b.reach;
    return .{
        .w = ox + @as(i32, @intCast(b.members.len)) * b.pitch,
        .h = oy + b.reach + rail_gap + bottom_pad,
        .ox = ox,
        .oy = oy,
    };
}

/// Where the bank's caption sits: one grid step above the power rail, aligned
/// with the label that terminates it.
pub fn captionAt(f: Frame) wire.Point {
    return .{ .x = f.endX(), .y = f.powerY() - grid };
}

/// One rail's polyline at `y`: its terminating end, then one point per member
/// column. Consecutive points become separate two-point wires, so every tap is
/// a real wire END rather than a touch on another wire's interior.
pub fn railPts(
    arena: std.mem.Allocator,
    f: Frame,
    n: usize,
    y: i32,
) std.mem.Allocator.Error![]const wire.Point {
    const pts = try arena.alloc(wire.Point, n + 1);
    pts[0] = .{ .x = f.endX(), .y = y };
    for (pts[1..], 0..) |*p, k| p.* = .{ .x = f.memberX(k), .y = y };
    return pts;
}

/// The `Decoupling — <IC> · <RAIL>` caption above a bank, or just the rail when
/// the cluster it sits in has no hub to name. Both are written as their LEAF
/// names: the band heading above already names the sub-block, so repeating it
/// twice more inside the caption only made a heading long enough to run across
/// the bank beside it.
pub fn caption(
    arena: std.mem.Allocator,
    ic: []const u8,
    power: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const rail = draw.shortNetName(power);
    if (ic.len == 0) return std.fmt.allocPrint(arena, "Decoupling — {s}", .{rail});
    return std.fmt.allocPrint(arena, "Decoupling — {s} · {s}", .{ leaf(ic), rail });
}

/// The part of a sub-block-qualified reference after its last slash.
const leaf = net_name.leaf;

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn cand(item: u32, ref: []const u8, value: []const u8, power: []const u8) Candidate {
    return .{
        .item = item,
        .ref = ref,
        .value = value,
        .power = power,
        .gnd = "GND",
        .power_pin = 0,
        .reach = 381,
    };
}

// spec: export_kicad_sch - Decoupling caps sharing a rail and a ground gang into one bank, and a pair with too few members does not
test "kicad-sch: bank grouping keys on the rail and ground pair" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cands = [_]Candidate{
        cand(0, "C1", "100nF", "VDD3V3"),
        cand(1, "C2", "100nF", "VDD3V3"),
        cand(2, "C3", "100nF", "VDDA"),
        cand(3, "C4", "100nF", "VDD3V3"),
    };
    const banks = try group(a, &cands);
    // VDD3V3 gangs its three; VDDA has one cap and keeps its labels.
    try testing.expectEqual(@as(usize, 1), banks.len);
    try testing.expectEqualStrings("VDD3V3", banks[0].power);
    try testing.expectEqualStrings("GND", banks[0].gnd);
    try testing.expectEqual(@as(usize, 3), banks[0].members.len);
    try testing.expectEqual(@as(u32, 0), banks[0].members[0].item);
    try testing.expectEqual(@as(u32, 3), banks[0].members[2].item);
    // Nothing at all is still an answer, not a crash.
    try testing.expectEqual(@as(usize, 0), (try group(a, &.{})).len);
}

// spec: export_kicad_sch - A bank draws its caps smallest capacitance first, so bulk reservoirs end the row, with ties broken on ref-des
test "kicad-sch: bank members sort by value then reference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cands = [_]Candidate{
        cand(0, "C9", "10uF", "VDD"),
        cand(1, "C2", "100nF", "VDD"),
        cand(2, "C1", "100nF", "VDD"),
        cand(3, "C7", "1uF", "VDD"),
    };
    const banks = try group(a, &cands);
    try testing.expectEqual(@as(usize, 1), banks.len);
    // C1 and C2 tie on 100 nF and break on the ref; then 1 µF; the bulk last.
    const want = [_]u32{ 2, 1, 3, 0 };
    for (banks[0].members, want) |m, expected| try testing.expectEqual(expected, m.item);
    // The widest text ("100nF") sets a pitch wide enough to hold it.
    try testing.expect(banks[0].pitch >= emit.banked_text_dx + 5 * char_w);
    try testing.expectEqual(@as(i32, 0), @rem(banks[0].pitch, grid));
}

// spec: export_kicad_sch - A bank's rails, taps and terminating ends land on the connection grid around its members
test "kicad-sch: the bank frame places rails clear of every member pin" {
    const f = Frame{ .x = 10160, .y = 5080, .reach = 381, .pitch = 1270 };
    try testing.expectEqual(@as(i32, 10160), f.memberX(0));
    try testing.expectEqual(@as(i32, 11430), f.memberX(1));
    // Both rails clear the pins they serve, and the label/ground end sits left.
    try testing.expect(f.powerY() < f.powerPinY());
    try testing.expect(f.gndY() > f.gndPinY());
    try testing.expect(f.endX() < f.x);
    inline for (.{ f.powerY(), f.gndY(), f.endX(), f.memberX(3), f.powerPinY() }) |v| {
        try testing.expectEqual(@as(i32, 0), @rem(v, grid));
    }
}

// spec: export_kicad_sch - A bank rail is drawn as one span per tap so every member joins it end to end
test "kicad-sch: railPts breaks the rail at each member column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = Frame{ .x = 10160, .y = 5080, .reach = 381, .pitch = 1270 };
    const pts = try railPts(a, f, 3, f.powerY());
    try testing.expectEqual(@as(usize, 4), pts.len);
    try testing.expectEqual(f.endX(), pts[0].x);
    try testing.expectEqual(f.memberX(0), pts[1].x);
    try testing.expectEqual(f.memberX(2), pts[3].x);
    for (pts) |p| try testing.expectEqual(f.powerY(), p.y);
}

// spec: export_kicad_sch - A bank cell budgets its label, its lead and one column per member
test "kicad-sch: cellFor budgets the whole bank and keeps its origin inside" {
    const b = Bank{
        .power = "VDD3V3",
        .gnd = "GND",
        .key = "C1",
        .members = &.{ .{ .item = 0, .power_pin = 0 }, .{ .item = 1, .power_pin = 0 } },
        .reach = 381,
        .pitch = 1270,
    };
    const cell = cellFor(b, 600);
    try testing.expect(cell.ox >= 600);
    try testing.expect(cell.w >= cell.ox + 2 * b.pitch);
    try testing.expect(cell.oy > b.reach);
    try testing.expect(cell.h > cell.oy + b.reach);
}

// spec: export_kicad_sch - A rail-class net name is recognised by the project's own supply classifiers, and a signal net is not
test "kicad-sch: isSupplyNet accepts real rails and refuses signals" {
    try testing.expect(isSupplyNet("VDD3V3"));
    try testing.expect(isSupplyNet("VCC"));
    try testing.expect(isSupplyNet("V1P8"));
    try testing.expect(isSupplyNet("V_5VA"));
    // A module-private rail is judged on the leaf of its sub-block path.
    try testing.expect(isSupplyNet("buck/VOUT"));
    try testing.expect(!isSupplyNet("SPI_SCK"));
    try testing.expect(!isSupplyNet("GND"));
    try testing.expect(!isSupplyNet(""));
}

// spec: export_kicad_sch - A ganged cap is turned so its rail leg is up and its ground leg down, and a part that is not a plain two-terminal glyph is never ganged
test "kicad-sch: angleFor stands a cap up and reachOf refuses an odd body" {
    // KiCad turns counter-clockwise in the library's y-up frame: the pin at
    // +x goes to the top of the (y-down) sheet at 90 degrees.
    try testing.expectEqual(@as(u32, 90), angleFor(381));
    try testing.expectEqual(@as(u32, 270), angleFor(-381));

    const flat = [_]shape_mod.Pin{
        .{ .pad = "1", .name = "A", .side = .left, .x = -381, .y = 0 },
        .{ .pad = "2", .name = "B", .side = .right, .x = 381, .y = 0 },
    };
    try testing.expectEqual(@as(?i32, 381), reachOf(unitOf(&flat)));

    const offset = [_]shape_mod.Pin{
        .{ .pad = "1", .name = "A", .side = .left, .x = -381, .y = 127 },
        .{ .pad = "2", .name = "B", .side = .right, .x = 381, .y = 0 },
    };
    try testing.expectEqual(@as(?i32, null), reachOf(unitOf(&offset)));

    const lopsided = [_]shape_mod.Pin{
        .{ .pad = "1", .name = "A", .side = .left, .x = -254, .y = 0 },
        .{ .pad = "2", .name = "B", .side = .right, .x = 381, .y = 0 },
    };
    try testing.expectEqual(@as(?i32, null), reachOf(unitOf(&lopsided)));
    try testing.expectEqual(@as(?i32, null), reachOf(unitOf(flat[0..1])));
}

fn unitOf(pins: []const shape_mod.Pin) shape_mod.Unit {
    return .{ .number = 1, .title = "", .pins = pins, .half_w = 127, .half_h = 254 };
}

// spec: export_kicad_sch - A bank's caption names the IC it serves and the rail it gangs, and drops the IC when its cluster has none
test "kicad-sch: the bank caption names its IC and rail" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings("Decoupling — U1 · VDD3V3", try caption(a, "U1", "VDD3V3"));
    try testing.expectEqualStrings("Decoupling — VDD3V3", try caption(a, "", "VDD3V3"));
    // Inside a module the band heading already names the sub-block, so the
    // caption drops the path from both the IC and the rail.
    try testing.expectEqualStrings("Decoupling — U18 · VIN_F", try caption(a, "buck/U18", "buck/VIN_F"));
}
