//! Per-pin bypass-stub nets, and how the exported schematic labels them.
//!
//! netlisp's `(decouple … per-pin …)` shorthand carves a private micro-net off
//! a rail for every bypassed pad — `builders.zig` spells it
//! `<base>.<REF>.<PAD>` and moves the IC's own pad onto it — so the placer can
//! measure each decoupling loop separately and the router can treat them as
//! distinct copper. On a **board** that split is the point. On a **schematic**
//! it is noise: a reader sees `V1P8.U14.B4` beside a cap and cannot tell it is
//! the 1.8 V rail, and neither can KiCad, which has no notion of the
//! convention. The exported sheet therefore labels such a net with its BASE
//! rail name, which merges it into the rail — a deliberate display merge, and
//! the one place the schematic says less than netlisp's own netlist.
//!
//! netlisp's netlist and file-based PCB sync stay the authority on the split
//! (nothing here touches them), and `scripts/verify_kicad_sch.sh` applies the
//! same collapse to the netlisp side of its diff so the oracle still proves
//! every other net exact.
//!
//! **Detection is structural, not a regex.** A name is only a stub when all
//! three of these hold, which is what keeps a design's genuinely dotted net
//! name (`3.3V_SENSE`, or a rail literally called `3.3V`) safe:
//!
//!   1. it splits as `<base>.<REF>.<PAD>` — two dots, none of the three parts
//!      empty;
//!   2. the net carries the pin `(REF, PAD)` itself, on a ref-des the export
//!      actually placed — that host pad is exactly what the generator moved
//!      onto the stub, and a coincidentally dotted name has no reason to have
//!      it (`REF` is matched against the leaf of the flattened ref, because the
//!      generator writes the module-local `U14` while the flattened pin reads
//!      `flash/U14`);
//!   3. `<base>` names a net that really exists in the same flattened view —
//!      the rail the stub claims to be part of is on the board.
//!
//! Rule 3 is the conservative one, and it costs a case: a rail whose *every*
//! pad is bypassed keeps no trunk at all (board-c's `V08CAP`), so its lone stub
//! stays spelled in full rather than being renamed. That is a rename nothing
//! would merge, so nothing is lost but tidiness; loosening it would mean
//! trusting rules 1 and 2 alone to tell a stub from an author's own name.

const std = @import("std");
const export_kicad = @import("../export_kicad.zig");
const net_name = @import("../net_name.zig");

const FlatNet = export_kicad.FlatNet;

/// A net name read as `<base>.<REF>.<PAD>`.
pub const Split = struct {
    base: []const u8,
    ref: []const u8,
    pad: []const u8,
};

/// Split a net name on its last two dots, or null when it does not have the
/// shape at all. This is rule 1 alone — a caller must still confirm rules 2
/// and 3 before treating the result as a stub.
pub fn split(name: []const u8) ?Split {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const prev = std.mem.lastIndexOfScalar(u8, name[0..dot], '.') orelse return null;
    const out = Split{
        .base = name[0..prev],
        .ref = name[prev + 1 .. dot],
        .pad = name[dot + 1 ..],
    };
    if (out.base.len == 0 or out.ref.len == 0 or out.pad.len == 0) return null;
    return out;
}

/// Fill `out` with `stub name -> base rail name` for every net of `nets` that
/// passes all three rules, and return how many there were. A net that is not a
/// stub gets no entry, so a caller reads a label as `out.get(net) orelse net`.
pub fn collapse(
    arena: std.mem.Allocator,
    nets: []const FlatNet,
    known: *const std.StringHashMapUnmanaged(u32),
    out: *std.StringHashMapUnmanaged([]const u8),
) std.mem.Allocator.Error!u32 {
    var names: std.StringHashMapUnmanaged(void) = .empty;
    defer names.deinit(arena);
    for (nets) |net| try names.put(arena, net.name, {});

    var found: u32 = 0;
    for (nets) |net| {
        const s = split(net.name) orelse continue;
        if (!names.contains(s.base)) continue;
        if (!hostsPad(net, s, known)) continue;
        try out.put(arena, net.name, s.base);
        found += 1;
    }
    return found;
}

/// Rule 2: the net carries its own claimed host pad, on a placed part.
fn hostsPad(net: FlatNet, s: Split, known: *const std.StringHashMapUnmanaged(u32)) bool {
    for (net.pins) |pin| {
        if (!std.mem.eql(u8, pin.pin, s.pad)) continue;
        if (!std.mem.eql(u8, leafOf(pin.ref_des), s.ref)) continue;
        if (!known.contains(pin.ref_des)) continue;
        return true;
    }
    return false;
}

/// The module-local part of a flattened ref-des: `flash/U14` -> `U14`, which is
/// the spelling the stub-net generator wrote before flattening prefixed it.
const leafOf = net_name.leaf;

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const FlatPin = export_kicad.FlatPin;

const rail_pins = [_]FlatPin{
    .{ .ref_des = "U10", .pin = "16" },
    .{ .ref_des = "L2", .pin = "1" },
};
const stub_pins = [_]FlatPin{
    .{ .ref_des = "flash/U14", .pin = "B4" },
    .{ .ref_des = "flash/C147", .pin = "1" },
};
const sense_pins = [_]FlatPin{
    .{ .ref_des = "U10", .pin = "3" },
    .{ .ref_des = "R9", .pin = "2" },
};
const impostor_pins = [_]FlatPin{
    // Dotted, and its base exists — but no pin of it is `U10`'s pad `7`, so
    // nothing generated it as a stub.
    .{ .ref_des = "R9", .pin = "1" },
};

const collapse_nets = [_]FlatNet{
    .{ .name = "V1P8", .pins = &rail_pins },
    .{ .name = "V1P8.U14.B4", .pins = &stub_pins },
    .{ .name = "3.3V_SENSE", .pins = &sense_pins },
    .{ .name = "V1P8.U10.7", .pins = &impostor_pins },
    // A stub shape whose base rail is not a net here at all.
    .{ .name = "V08CAP.U10.16", .pins = &rail_pins },
};

fn knownRefs(a: std.mem.Allocator) !std.StringHashMapUnmanaged(u32) {
    var known: std.StringHashMapUnmanaged(u32) = .empty;
    for ([_][]const u8{ "U10", "L2", "flash/U14", "flash/C147", "R9" }, 0..) |ref, i| {
        try known.put(a, ref, @intCast(i));
    }
    return known;
}

// spec: export_kicad_sch - A per-pin bypass-stub net is labelled with its base rail name, proven by its own host pad and an existing base net
test "kicad-sch: collapse renames a real bypass stub and refuses everything else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var known = try knownRefs(a);
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    const n = try collapse(a, &collapse_nets, &known, &map);

    try testing.expectEqual(@as(u32, 1), n);
    try testing.expectEqualStrings("V1P8", map.get("V1P8.U14.B4").?);
    // A one-dot name is not the shape at all — this is the case the whole
    // structural rule exists to protect.
    try testing.expect(map.get("3.3V_SENSE") == null);
    // Right shape, existing base, but the claimed host pad is not on it.
    try testing.expect(map.get("V1P8.U10.7") == null);
    // Right shape and a real host pad, but no such rail exists to merge onto.
    try testing.expect(map.get("V08CAP.U10.16") == null);
    // The rail itself is never rewritten.
    try testing.expect(map.get("V1P8") == null);
}

// spec: export_kicad_sch - A dotted net name only reads as a bypass stub when it carries a base, a reference, and a pad
test "kicad-sch: split reads the last two dots and rejects a name without both" {
    const s = split("buck/VIN.U12.VIN_1").?;
    try testing.expectEqualStrings("buck/VIN", s.base);
    try testing.expectEqualStrings("U12", s.ref);
    try testing.expectEqualStrings("VIN_1", s.pad);

    // A rail spelled with a decimal point keeps its own name in the base.
    const dotted = split("3.3V.U1.5").?;
    try testing.expectEqualStrings("3.3V", dotted.base);

    try testing.expect(split("3.3V_SENSE") == null);
    try testing.expect(split("VDD3V3") == null);
    try testing.expect(split("VDD..5") == null);
    try testing.expect(split(".U1.5") == null);
    try testing.expect(split("VDD.U1.") == null);
}
