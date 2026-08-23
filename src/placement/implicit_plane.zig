//! The LEGACY IMPLICIT board model — what a block that authors no `(stackup …)`
//! form assumes about its inner copper — spelled once, so every consumer reads
//! the same assignment. The router, the connectivity oracle, the DRC, the pour
//! fill and the Gerber export all resolve the implicit stack through this file;
//! a board where the router assumes a plane the Gerbers do not pour would be a
//! shipped short, so the assignment may never be restated locally.
//!
//! The model is four copper layers, two of them inner planes:
//!
//!   * **In1.Cu** (copper stack index 2) — GROUND, always. Every ground-named
//!     net (`optimizer.isGroundName`) is carried, which is why a bypass cap's
//!     ground leg needs only a stitch via and never a trace.
//!   * **In2.Cu** (copper stack index 3) — the block's DOMINANT SUPPLY RAIL
//!     (`dominantRail`) when one qualifies, else ground again, which is what
//!     this model did before rails were planed at all. A block with no
//!     qualifying rail is therefore byte-identical to the legacy behaviour.
//!     WHICH rail wins is settled by a tie-break LADDER that is a strict total
//!     order over the qualifying nets — pad count, then role, then name — so
//!     the answer is a function of the netlist's CONTENT alone. Reordering two
//!     pin declarations in a `.sexp` may never move the plane from one rail to
//!     another: the loser is condemned to long surface routing, and that is not
//!     an electrical outcome any file's line order is allowed to decide.
//!
//! A planed rail behaves exactly as ground already does: the router plants a
//! stitch via at each of its pads instead of routing it, the oracle counts its
//! pads joined by the pour (so it leaves routed/total), port escape exempts it,
//! and In2's Gerber pours it with antipads around every foreign hole.
//!
//! The model says nothing about DIELECTRICS — see `impedance_rules.stackOf`,
//! which deliberately declines to invent heights for an undeclared stackup.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const flat_netlist = @import("../flat_netlist.zig");
const module_policy = @import("module_policy.zig");
const optimizer = @import("optimizer.zig");
const pin_roles = @import("pin_roles.zig");
const rails = @import("../eval/rails.zig");

const FlatNet = flat_netlist.FlatNet;

/// Total copper layers the implicit model assumes. The value itself lives in
/// `board_layers` (the shared layer table builds this same stack from it), so
/// "no stackup form ⇒ 4 copper layers" is spelled exactly once.
pub const copper_layers: u8 = board_layers.implicit_copper_layers;
/// 1-based copper stack index of the implicit GROUND plane (In1.Cu).
pub const ground_index: u8 = board_layers.implicit_ground_stack;
/// 1-based copper stack index of the implicit SUPPLY-RAIL plane (In2.Cu) —
/// the second ground plane when no rail qualifies.
pub const rail_index: u8 = board_layers.implicit_rail_stack;
/// Fewest pads a rail must land on to be worth a plane. A plane exists to JOIN
/// pads, so a rail reaching one pad has nothing to join — the same floor the
/// router's plane pass already applies when it skips a net with `pts.len < 2`.
const min_rail_pads: usize = 2;

/// What one implicit inner plane carries.
pub const InnerPlane = union(enum) {
    /// Every ground-named net (`optimizer.isGroundName` on the `/`-leaf).
    ground,
    /// Exactly this flattened supply-rail net (matched by the shared
    /// `.named`-plane rule: case-insensitive, full name or `/`-leaf).
    rail: []const u8,
};

/// The two inner planes of the implicit stack, ordered by copper stack index
/// (`ground_index` then `rail_index`). A block whose `Planes.implicit_rail` is
/// null gets two ground planes — the legacy model, unchanged.
pub fn innerPlanes(rules: optimizer.BoardRules) [2]InnerPlane {
    return .{ .ground, if (rules.planes.implicit_rail) |r| .{ .rail = r } else .ground };
}

/// Does the implicit RAIL plane carry `name`? Deliberately the SAME predicate a
/// declared `(plane IDX "NET")` uses (`pour`/`export_gerber`'s `planeCarries`
/// over a `.named` plane: case-insensitive, full flattened name or its `/`-leaf)
/// — the rail flows into those engines as an ordinary named plane, so any other
/// rule here would let the router and the Gerber disagree about which pads the
/// pour reaches. `dominantRail` only ever picks a rail whose leaf is unique, so
/// the leaf half of the match can never fold in a sibling's distinct net.
pub fn carriesRail(rules: optimizer.BoardRules, name: []const u8) bool {
    const r = rules.planes.implicit_rail orelse return false;
    if (name.len == 0) return false;
    return std.ascii.eqlIgnoreCase(r, name) or std.ascii.eqlIgnoreCase(r, leafName(name));
}

/// Does EITHER implicit plane carry `name`? The whole implicit half of
/// `router.netHasPlane` / `fab_readiness.netHasPlane`.
pub fn carries(rules: optimizer.BoardRules, name: []const u8) bool {
    return optimizer.isGroundName(leafName(name)) or carriesRail(rules, name);
}

/// The block's dominant supply rail: of the flattened nets that read as a
/// supply rail, the one that wins the tie-break LADDER below. Null when nothing
/// qualifies, which keeps the block on the legacy two-ground-plane model.
///
/// A net qualifies when all four hold:
///   * it is not ground (`optimizer.isGroundName`);
///   * its `/`-leaf reads as a supply by one of the project's two existing
///     rail predicates — `pin_roles.isSupplyFn` (the pinout-function rule:
///     VCC/VDD/AVDD/VIN/VBUS/…, straps rejected) or `rails.looksLikeRail`
///     (the net-name rule: `V`+digit or a `VDD`/`VBUS`/`V_`/… prefix). No new
///     naming rule is introduced here;
///   * it lands on at least `min_rail_pads` pads;
///   * its leaf is UNIQUE across the flattened nets (case-insensitively). The
///     plane predicate matches a leaf as well as a full name, so a rail whose
///     leaf is shared — two sibling sub-blocks each with a private `VCC` the
///     parent never tied — would silently short them together through the
///     pour. An ambiguous leaf simply disqualifies the rail.
///
/// Among the qualifiers `outranks` decides, and it is a strict TOTAL order, so
/// the winner depends only on which nets exist — never on the order the
/// flattener happened to emit them in. That matters because the rail that loses
/// this contest is the one left to long surface routing: an LDO whose `VIN` and
/// `VOUT` land on the same pad count must not hand the plane to whichever pin
/// was declared first in the `.sexp`.
pub fn dominantRail(nets: []const FlatNet) ?[]const u8 {
    var best: ?Candidate = null;
    for (nets) |net| {
        if (net.pins.len < min_rail_pads) continue;
        const leaf = leafName(net.name);
        if (!isRailName(leaf)) continue;
        if (!leafIsUnique(nets, leaf)) continue;
        const cand: Candidate = .{ .name = net.name, .pads = net.pins.len, .role = roleRank(leaf) };
        if (best == null or outranks(cand, best.?)) best = cand;
    }
    return if (best) |b| b.name else null;
}

/// One qualifying rail reduced to exactly the keys the ladder compares.
const Candidate = struct {
    name: []const u8,
    pads: usize,
    /// `roleRank`: 0 for an output/power-class rail, 1 for an input rail.
    role: u8,
};

/// The tie-break ladder: does `a` displace `b`? Every rung is a comparison of
/// values read off the netlist, and the last one is decisive, so this is a
/// strict total order and `dominantRail`'s scan order cannot reach the answer.
///
///   1. **More pads wins.** Unchanged, and still the point of the exercise: a
///      plane exists to JOIN pads, so the rail on the most of them buys the
///      most routing.
///   2. **An output rail beats an input rail.** A regulator's `VIN` arrives on
///      one short trunk from a connector and is the high-dI/dt side the placer
///      wants kept tight and local; its `VOUT` is what the rest of the board
///      draws from, spread across every load. Given equal pad counts the output
///      is the one a plane helps.
///   3. **Lower net name wins.** The rung that makes the order TOTAL. Only nets
///      with a UNIQUE leaf qualify, so no two candidates can carry the same
///      name and reach this rung still tied.
///
/// A pad BOUNDING BOX would be a better rung 3 than the name — the rail whose
/// pads spread furthest is the one that gains most from a plane. It is not
/// reachable here: the argument is `[]const FlatNet` and a `FlatPin` carries
/// only `ref_des`/`pin`, no coordinates. Nor could it be plumbed in, because
/// `optimizer.boardRulesOf` calls this while building the rules the placer
/// later runs on — there is no placed board to measure yet.
fn outranks(a: Candidate, b: Candidate) bool {
    if (a.pads != b.pads) return a.pads > b.pads;
    if (a.role != b.role) return a.role < b.role;
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Rung 2's key, low-is-better: an INPUT rail ranks below every other rail that
/// qualifies. The classification is `module_policy.classifyNetName`, this
/// project's existing name-based net classifier and the same one the ERC and
/// the placer already ask this question of (`input_rail` vs `power`) — as with
/// the qualification predicates above, no new naming rule is coined here.
fn roleRank(leaf: []const u8) u8 {
    return if (module_policy.classifyNetName(leaf) == .input_rail) 1 else 0;
}

/// Does this net-name leaf read as a supply rail (and not a ground)?
fn isRailName(leaf: []const u8) bool {
    if (optimizer.isGroundName(leaf)) return false;
    return pin_roles.isSupplyFn(leaf) or rails.looksLikeRail(leaf);
}

/// Is `leaf` the `/`-leaf of exactly ONE net in `nets` (case-insensitively)?
fn leafIsUnique(nets: []const FlatNet, leaf: []const u8) bool {
    var seen: usize = 0;
    for (nets) |n| {
        if (std.ascii.eqlIgnoreCase(leafName(n.name), leaf)) seen += 1;
        if (seen > 1) return false;
    }
    return true;
}

/// The net name's leaf after the last '/' (the sub-block flatten prefix).
fn leafName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn tNet(name: []const u8, pins: []const flat_netlist.FlatPin) FlatNet {
    return .{ .name = name, .pins = pins };
}

const three_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "U1", .pin = "1" },
    .{ .ref_des = "U1", .pin = "2" },
    .{ .ref_des = "C1", .pin = "1" },
};
const two_pins = three_pins[0..2];
const one_pin = three_pins[0..1];

// spec: placement/implicit-plane - the dominant supply rail is the rail-class net with the most pads
test "dominantRail picks the widest supply rail" {
    const nets = [_]FlatNet{
        tNet("GND", &three_pins),
        tNet("V_5V0", two_pins),
        tNet("V_3V3", &three_pins),
        tNet("LMX_CE", two_pins),
    };
    try testing.expectEqualStrings("V_3V3", dominantRail(&nets).?);
}

// spec: placement/implicit-plane - a tie on pad count resolves the same whatever order the nets arrive in
test "dominantRail answers a pad-count tie independently of net order" {
    // Same role, same pad count: the name rung decides, and it decides the same
    // way from either end. Reordering pin declarations in a `.sexp` reorders the
    // flattened nets, and that may not move the plane.
    const nets = [_]FlatNet{ tNet("VCC_A", two_pins), tNet("VCC_B", two_pins) };
    const flipped = [_]FlatNet{ tNet("VCC_B", two_pins), tNet("VCC_A", two_pins) };
    try testing.expectEqualStrings("VCC_A", dominantRail(&nets).?);
    try testing.expectEqualStrings("VCC_A", dominantRail(&flipped).?);

    // The fixture case that exposed the order dependence: an LDO whose VIN and
    // VOUT land on the same pad count. VOUT won only by being enumerated first;
    // now it wins by the role rung, from either order.
    const ldo = [_]FlatNet{ tNet("VOUT", &three_pins), tNet("VIN", &three_pins), tNet("GND", &three_pins) };
    const ldo_flipped = [_]FlatNet{ tNet("GND", &three_pins), tNet("VIN", &three_pins), tNet("VOUT", &three_pins) };
    try testing.expectEqualStrings("VOUT", dominantRail(&ldo).?);
    try testing.expectEqualStrings("VOUT", dominantRail(&ldo_flipped).?);
}

// spec: placement/implicit-plane - a pad-count tie hands the plane to an output rail over an input rail
test "dominantRail prefers an output rail to an input rail on a tie" {
    // VIN sorts BEFORE VOUT, so the name rung alone would elect the input rail:
    // only the role rung can produce this answer.
    const tied = [_]FlatNet{ tNet("VIN", two_pins), tNet("VOUT", two_pins) };
    try testing.expectEqualStrings("VOUT", dominantRail(&tied).?);

    // Role never overrules pad count — the primary criterion still leads, so an
    // input rail on more pads takes the plane.
    const wider_input = [_]FlatNet{ tNet("VOUT", two_pins), tNet("VIN", &three_pins) };
    try testing.expectEqualStrings("VIN", dominantRail(&wider_input).?);

    // Other input spellings rank the same way (`rails.input_rail_prefixes`).
    const bus = [_]FlatNet{ tNet("VBUS", two_pins), tNet("V_3V3", two_pins) };
    try testing.expectEqualStrings("V_3V3", dominantRail(&bus).?);

    // With no output rail in the running an input rail is still planed — the
    // rung demotes, it does not disqualify.
    const only_input = [_]FlatNet{ tNet("GND", &three_pins), tNet("VIN", two_pins) };
    try testing.expectEqualStrings("VIN", dominantRail(&only_input).?);
}

// spec: placement/implicit-plane - a block with no qualifying rail keeps both inner planes on ground
test "dominantRail declines grounds, signals, one-pad rails and ambiguous leaves" {
    // Grounds and ordinary signals never qualify, however many pads they carry.
    const grounds = [_]FlatNet{ tNet("GND", &three_pins), tNet("AGND", &three_pins), tNet("SPI_SCK", &three_pins) };
    try testing.expect(dominantRail(&grounds) == null);

    // A rail on a single pad has nothing for a plane to join.
    const lonely = [_]FlatNet{tNet("V_3V3", one_pin)};
    try testing.expect(dominantRail(&lonely) == null);

    // Two sibling sub-blocks with a private same-leaf rail: planing either would
    // short them through the pour, because the plane predicate matches leaves.
    const siblings = [_]FlatNet{ tNet("amp1/VCC", &three_pins), tNet("amp2/VCC", &three_pins) };
    try testing.expect(dominantRail(&siblings) == null);

    // The same rail with a unique leaf IS planed, prefix and all.
    const single = [_]FlatNet{ tNet("amp1/VCC", &three_pins), tNet("amp2/VDD", two_pins) };
    try testing.expectEqualStrings("amp1/VCC", dominantRail(&single).?);

    // Nothing at all: an empty net list is a no-rail block, not a crash.
    try testing.expect(dominantRail(&.{}) == null);
}

/// `BoardRules` for a no-stackup block that planed `rail` (null = none).
fn tRules(rail: ?[]const u8) optimizer.BoardRules {
    return .{ .planes = .{ .implicit_rail = rail } };
}

// spec: placement/implicit-plane - the rail plane carries its net by full name or leaf, and nothing else
test "carriesRail matches the declared-plane rule and carries folds in ground" {
    const railed = tRules("V_3V3");
    const bare = tRules(null);
    try testing.expect(carriesRail(railed, "V_3V3"));
    try testing.expect(carriesRail(railed, "v_3v3")); // case-insensitive
    try testing.expect(carriesRail(railed, "synth/V_3V3")); // leaf match
    try testing.expect(!carriesRail(railed, "V_5V0"));
    try testing.expect(!carriesRail(railed, ""));
    try testing.expect(!carriesRail(bare, "V_3V3")); // no rail chosen ⇒ nothing carried

    // `carries` is the implicit half of netHasPlane: ground OR the rail.
    try testing.expect(carries(bare, "GND"));
    try testing.expect(carries(railed, "GND"));
    try testing.expect(carries(railed, "V_3V3"));
    try testing.expect(!carries(bare, "V_3V3"));
    try testing.expect(!carries(railed, "SPI_SCK"));
}

// spec: placement/implicit-plane - In1 is always ground and In2 is the chosen rail when enabled, else ground
test "innerPlanes assigns In1 to ground and In2 to the rail" {
    const legacy = innerPlanes(tRules(null));
    try testing.expect(legacy[0] == .ground);
    try testing.expect(legacy[1] == .ground);

    const railed = innerPlanes(tRules("V_3V3"));
    try testing.expect(railed[0] == .ground);
    try testing.expectEqualStrings("V_3V3", railed[1].rail);

    // The stack indices the two planes occupy are fixed by the model.
    try testing.expectEqual(@as(u8, 2), ground_index);
    try testing.expectEqual(@as(u8, 3), rail_index);
    try testing.expectEqual(@as(u8, 4), copper_layers);
}

// spec: placement/implicit-plane - the u8 layer helpers on BoardRules answer exactly what the shared layer table does
test "BoardRules layer helpers agree with the shared layer table" {
    // A 6-layer board with planes on In1 (stack 2) and In4 (stack 5): the
    // routable set is F.Cu, B.Cu and the two plane-free inners.
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 5, .net = "V_3V3" } };
    const declared = optimizer.BoardRules{
        .plane_nets = &.{ "GND", "V_3V3" },
        .copper_layers = 6,
        .planes = .{ .declared = &planes },
    };
    try testing.expectEqual(@as(u8, 6), declared.layerTable().stackCount());
    try testing.expectEqual(@as(u8, 4), declared.signalLayerCount());
    try expectLayerHelpersMatchTable(declared);
    // The inverse agrees on both the hits and the plane-claimed misses.
    try testing.expectEqual(@as(?u8, 2), declared.signalIndexOfName("In2.Cu"));
    try testing.expectEqual(@as(?u8, null), declared.signalIndexOfName("In1.Cu"));
    try testing.expectEqual(@as(?u8, null), declared.signalIndexOfName("In4.Cu"));

    // An undeclared board reads as this module's implicit model everywhere:
    // four copper layers, two of them inner planes, two routable faces.
    const implicit = tRules("V_3V3");
    const table = implicit.layerTable();
    try testing.expectEqual(copper_layers, table.stackCount());
    try testing.expectEqual(@as(u8, 2), implicit.signalLayerCount());
    try testing.expectEqualStrings("V_3V3", table.rowAtStack(board_layers.StackIndex.of(rail_index)).?.plane_net.?);
    try expectLayerHelpersMatchTable(implicit);
}

/// Every routable index answers the same name and stack position through the
/// `u8` `BoardRules` helpers and through the typed layer-table row.
fn expectLayerHelpersMatchTable(rules: optimizer.BoardRules) !void {
    const table = rules.layerTable();
    var buf: [board_layers.name_buf_len]u8 = undefined;
    var sig: u8 = 0;
    while (sig < rules.signalLayerCount()) : (sig += 1) {
        const row = table.rowOfSignal(board_layers.SignalIndex.of(sig)).?;
        try testing.expectEqualStrings(row.name(), rules.signalLayerName(sig, &buf));
        try testing.expectEqual(row.stack.int(), rules.signalStackIndex(sig));
    }
}
