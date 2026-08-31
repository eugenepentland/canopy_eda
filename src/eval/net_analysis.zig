//! Shared net-analysis helpers used by both the eval-time validator
//! (`src/eval/validate.zig`) and the on-demand ERC pass (`src/erc.zig`).
//! Keeps the two checkers in lockstep — if one is fixed, both are fixed.

const std = @import("std");
const env_mod = @import("env.zig");
const DesignBlock = env_mod.DesignBlock;

// ── Ground-net name vocabulary ───────────────────────────────────────────
// Every ground-name spelling this project recognises lives HERE. Nine other
// modules used to keep a private token list of their own — the plane stitcher,
// the pin-role reader, the block-diagram classifier, the schematic renderer
// (twice), the ERC, the PCB page and the board viewer's JS — and a net that is
// ground to the router and signal to the ERC is a stitch via that never gets
// planted.
//
// This module is the home rather than `placement/optimizer.zig` for one
// structural reason: the optimizer sits near the top of the placement graph, so
// `pin_roles` — which the optimizer itself imports — cannot import it back, and
// neither can the eval-layer checkers. `net_analysis` is a leaf every one of
// those modules already can, and does, reach. The project's ground PREDICATE,
// `isGroundName`, lives here for the same reason and is re-exported as
// `optimizer.isGroundName`, which stays the spelling every consumer calls: the
// tokens and the rule that reads them must not be separable, or a module below
// the optimizer re-derives the rule (as `critical_rough` did, matching only
// GND/GROUND/VSS and routing every split ground as signal).
//
// The tables are the private lists TRANSCRIBED, not merged: they genuinely
// disagree today (only `ground_fn_prefixes` lists `SGND`; only
// `schematic_ground_names` omits `PGND`; `ground_tokens` demands an all-digit
// suffix where the prefix tables accept anything), and every one of those
// disagreements is a live behaviour some surface depends on. Naming them side
// by side is what makes the next one visible. Merging two is a design decision
// — make it here, in one edit, with a test.

/// `AGND` — the analog 0 V reference of a split-ground part or board.
pub const analog_ground = "AGND";

/// `DGND` — the digital 0 V reference (the twin of `analog_ground`).
pub const digital_ground = "DGND";

/// `PGND` — the power-stage return of a converter or driver, kept separate from
/// the quiet grounds so its high-dI/dt loop can be judged on its own.
pub const power_ground = "PGND";

/// `SGND` — a signal/sense ground, star-tied to the others at one point.
const signal_ground = "SGND";

/// `GNDA` / `GNDD` — the suffix spelling of the analog/digital split, used by
/// the parts whose datasheets name them that way round.
const analog_ground_suffixed = "GNDA";
const digital_ground_suffixed = "GNDD";

/// The canonical ground TOKEN list — `placement/optimizer.isGroundName`'s own,
/// which accepts each token bare or with an all-digit suffix (`GND1`, `AGND2`,
/// `PGND_2`) and nothing else, so a real signal like `GND_SENSE` stays a
/// signal. Ordered longest-first so `GNDA` is not shadowed by `GND`; the PCB
/// page's exact-match copy shares it. The one list the plane stitcher, the
/// pour, the DRC and the fab outputs all judge a board by.
pub const ground_tokens = [_][]const u8{
    analog_ground_suffixed, digital_ground_suffixed, analog_ground, power_ground,
    digital_ground,         "VSSA",                  "GND",         "VSS",
};

/// True when `name` — already stripped to its `/`-leaf by the caller — is a
/// ground rail. Re-exported as `placement/optimizer.isGroundName`, the spelling
/// every consumer calls; it is defined here so a module the optimizer imports
/// can reach it without an import cycle.
///
/// A ground rail is one of `ground_tokens`, optionally with a *numbered* suffix
/// (GND1, GND2, AGND2, VSS1, PGND_2 on a multi-ground part) — an exact-match
/// list missed numbered grounds, so on an isolated/split-ground part those nets
/// read as *signal*, corrupting loop detection, rail direction, and scoring. The
/// suffix must be (an optional single '_'/'-' then) all digits, so a real signal
/// like GND_SENSE / GNDSW stays a signal. `ground_tokens` is ordered longest
/// first so e.g. GNDA is not shadowed by GND.
pub fn isGroundName(name: []const u8) bool {
    for (ground_tokens) |t| {
        if (!std.mem.startsWith(u8, name, t)) continue;
        var rest = name[t.len..];
        if (rest.len == 0) return true;
        if (rest[0] == '_' or rest[0] == '-') rest = rest[1..];
        if (rest.len == 0) return false; // bare separator, no number
        for (rest) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
        return true;
    }
    return false;
}

/// `CHASSIS_GND` — the chassis/shield reference: a connector's metal shell, a
/// shield can, an enclosure stud. Deliberately ABSENT from `ground_tokens`,
/// and that absence is the point. `ground_tokens` is what the plane stitcher,
/// the pour and the DRC judge a board by, and on a design like `barracuda-base`
/// the chassis node is an ISOLATION BARRIER — the RJ45's metal shell reaches
/// system ground only through a 1 nF / 2 kV capacitor and a 1 M bleeder. Listing
/// it as a ground token would pour it into the ground plane and stitch the
/// barrier shut.
pub const chassis_ground = "CHASSIS_GND";

/// True when `name` is a 0 V reference *for voltage-RATING purposes*: every
/// ground in `ground_tokens`, plus the chassis node.
///
/// Separate from `isGroundName` because the two questions have different right
/// answers for exactly one name. "Does copper pour onto this net?" must say no
/// for `CHASSIS_GND` (see above). "What DC potential does a part bridging this
/// net see?" must say 0 V: the barrier components are specified against the
/// system ground they bridge to, and with no potential on either side the
/// release gate could not prove their ratings at all — `C_chassis`/`R_chassis`
/// on `barracuda-base` were unprovable for that reason alone. The kilovolt
/// rating on that capacitor is a surge/HiPot spec; this gate models the DC
/// operating point, where both sides are 0 V.
pub fn isRatingZeroVolts(name: []const u8) bool {
    if (isGroundName(name)) return true;
    if (!std.mem.startsWith(u8, name, chassis_ground)) return false;
    var rest = name[chassis_ground.len..];
    if (rest.len == 0) return true;
    if (rest[0] == '_' or rest[0] == '-') rest = rest[1..];
    if (rest.len == 0) return false;
    for (rest) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Pinout FUNCTION-name prefixes that denote a ground return. Read by
/// `placement/pin_roles.isGroundFn`, which normalises separators/case first
/// and then also accepts a short list of exposed-pad names. Uniquely lists
/// `SGND`, and being a bare prefix set it accepts `GND_SENSE` where
/// `ground_tokens` does not.
pub const ground_fn_prefixes = [_][]const u8{
    "GND", "VSS", analog_ground, digital_ground, power_ground, signal_ground,
};

/// The exact ground base-net names the block-diagram classifier matches
/// (`diagram/classify`), which pairs them with `ground_stem_prefixes`.
pub const ground_base_names = [_][]const u8{ "GND", analog_ground, digital_ground, power_ground };

/// Named/derived grounds keep their stem as a prefix: an isolated barrier
/// ground (`GND_ISO`), a digital/analog split (`GND_A`). `VSS`/`VSSA` is the
/// 0 V reference in CMOS naming (not a rail), so it belongs here — otherwise a
/// VSS-named design gets the spurious dense power-edge fan the ground class
/// exists to suppress.
pub const ground_stem_prefixes = [_][]const u8{
    "GND_",              analog_ground ++ "_", digital_ground ++ "_",
    power_ground ++ "_", "VSS",
};

/// The ground names the SCHEMATIC draws a GND symbol for rather than a labelled
/// net stub (`render_svg/draw.isGroundNet`, plus the always-significant net
/// seeds in `render_svg/context`). Deliberately omits `PGND`: a power-stage
/// return is drawn as its own labelled node so the reader can see it is not
/// the quiet ground.
pub const schematic_ground_names = [_][]const u8{ "GND", analog_ground, digital_ground };

/// Strip a `.subnet` suffix so `VDD.U3.W6` collapses to `VDD`. The `.`
/// separator is used by the eval builder to carve per-pin/per-port split
/// nets off a base rail; for most analyses we want the base name.
pub fn baseNetName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |idx| return name[0..idx];
    return name;
}

/// Return the leading character of a ref-des with any `sub-block/` namespace
/// prefix stripped (`ldo/C136` → 'C'). Sub-block parts get namespaced after
/// ref-des renaming, so a naive `ref_des[0]` would see `l`/`a`/etc. instead
/// of the local component class.
pub fn refDesLocalPrefix(ref_des: []const u8) u8 {
    if (ref_des.len == 0) return 0;
    if (std.mem.lastIndexOfScalar(u8, ref_des, '/')) |i| {
        if (i + 1 < ref_des.len) return ref_des[i + 1];
        return 0;
    }
    return ref_des[0];
}

/// Walk a sub-block path like `ldo/VOUT` or `adc1/VLOGIC` into the block
/// tree and return true if the leaf net has a capacitor bridged to ground.
/// Used to detect decoupling that lives inside a sub-block whose port is
/// tied to a top-level power rail via a `(net ...)` form.
pub fn subBlockNetHasCap(block: *const DesignBlock, net_path: []const u8) bool {
    if (std.mem.indexOfScalar(u8, net_path, '/')) |slash| {
        const head = net_path[0..slash];
        const rest = net_path[slash + 1 ..];
        for (block.sub_blocks) |sb| {
            if (std.mem.eql(u8, sb.name, head)) return subBlockNetHasCap(sb.block, rest);
        }
        return false;
    }
    for (block.nets) |n| {
        if (!std.mem.eql(u8, n.name, net_path)) continue;
        for (n.pins) |pin| {
            if (pin.ref_des.len == 0) continue;
            if (refDesLocalPrefix(pin.ref_des) == 'C' and
                capBridgesBaseToGround(block, pin.ref_des, baseNetName(n.name))) return true;
        }
        return false;
    }
    return false;
}

/// Return the base names of every power-net on `block` that has at least
/// one IC pin connected but no decoupling cap — including caps reached via
/// a `(net "RAIL" "sub/PORT" ...)` tie into a sub-block.
///
/// Caller owns the returned slice (allocated with `allocator`); the net
/// name slices inside reference strings owned by `block`.
pub fn findMissingDecouplingNets(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error![]const []const u8 {
    var power_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer power_nets.deinit(allocator);
    for (block.ports) |port| {
        if (!std.mem.eql(u8, port.direction, "in")) continue;
        // An explicit non-power kind is authoritative (`Port.isDeclaredNonPower`,
        // shared with the power budget). A rated enable/control input can
        // therefore declare its voltage envelope without becoming a supply rail
        // that incorrectly demands a bypass capacitor.
        if (port.isDeclaredNonPower()) continue;
        if (std.ascii.eqlIgnoreCase(port.kind, "power") or port.isPowerSource()) {
            try power_nets.put(allocator, baseNetName(port.net), {});
        }
    }
    for (block.sections) |sec| {
        try collectSectionPowerInputs(allocator, &power_nets, sec);
    }

    // Aggregate IC- and cap-presence per *base* rail name, folding the trunk
    // net together with its per-pin bypass-stub nets (`<rail>.<ic>.<pad>`).
    // A `(decouple … per-pin PAD)` form hangs each local cap on such a stub and
    // pulls the bypassed pad off the trunk; `buildNets` then renames the stub to
    // share the canonical rail prefix when the pad's power-domain name merges
    // into a board rail (e.g. VDDSMPS/VDDIO2 → V1P8). So a rail whose pads are
    // all locally bypassed carries its caps only on the stubs, never the trunk —
    // a per-net check would falsely flag the trunk as undecoupled (the stm32n6
    // V1P8 1.8 V rail). Collapsing trunk + stubs to one base-name verdict fixes
    // that without weakening the check for genuinely bare rails.
    var rails_with_ic: std.StringHashMapUnmanaged(void) = .empty;
    defer rails_with_ic.deinit(allocator);
    var rails_with_cap: std.StringHashMapUnmanaged(void) = .empty;
    defer rails_with_cap.deinit(allocator);
    for (block.nets) |net| {
        const base = baseNetName(net.name);
        if (!power_nets.contains(base)) continue;
        for (net.pins) |pin| {
            if (pin.ref_des.len == 0) continue;
            switch (refDesLocalPrefix(pin.ref_des)) {
                'U' => try rails_with_ic.put(allocator, base, {}),
                'C' => if (capBridgesBaseToGround(block, pin.ref_des, base))
                    try rails_with_cap.put(allocator, base, {}),
                else => {},
            }
        }
    }

    // Emit each undecoupled base rail once, walking `block.nets` for a stable
    // order rather than the (unordered) hash map.
    var missing: std.ArrayList([]const u8) = .empty;
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    defer emitted.deinit(allocator);
    for (block.nets) |net| {
        const base = baseNetName(net.name);
        if (!rails_with_ic.contains(base)) continue;
        if (rails_with_cap.contains(base)) continue;
        if (emitted.contains(base)) continue;
        // Decoupling may instead live inside a sub-block whose power port is
        // tied to this rail via a `(net "RAIL" "sub/PORT" …)` form.
        if (tiedSubBlockHasCap(block, base)) continue;
        try emitted.put(allocator, base, {});
        try missing.append(allocator, base);
    }
    return missing.toOwnedSlice(allocator);
}

fn collectSectionPowerInputs(
    allocator: std.mem.Allocator,
    power_nets: *std.StringHashMapUnmanaged(void),
    section: env_mod.Section,
) std.mem.Allocator.Error!void {
    // Concept sections haven't been implemented yet — skip so we don't demand
    // bypassing on rails that aren't wired to anything.
    if (section.status == .concept) return;
    for (section.ports) |port| {
        if (port.signal_type == .power and port.direction == .in) {
            try power_nets.put(allocator, baseNetName(port.name), {});
        }
    }
    for (section.sub_sections) |sub| {
        try collectSectionPowerInputs(allocator, power_nets, sub);
    }
}

/// A capacitor qualifies as decoupling only when it touches this rail and a
/// recognised ground-return net. Merely placing any C-prefix pin on a supply
/// rail no longer suppresses the missing-decoupling warning.
fn capBridgesBaseToGround(block: *const DesignBlock, cap_ref: []const u8, rail_base: []const u8) bool {
    var has_rail = false;
    var has_ground = false;
    for (block.nets) |net| {
        var touches = false;
        for (net.pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, cap_ref)) {
                touches = true;
                break;
            }
        }
        if (!touches) continue;
        const base = baseNetName(net.name);
        if (std.mem.eql(u8, base, rail_base)) has_rail = true;
        if (isGroundBase(base)) has_ground = true;
    }
    return has_rail and has_ground;
}

/// The eval-layer ground test. Alone among this project's ground predicates it
/// is case-INSENSITIVE, because it reads names straight off a design file where
/// an author may have typed `gnd`; the placement and schematic predicates all
/// judge already-normalised net names.
fn isGroundBase(name: []const u8) bool {
    for (ground_base_names) |g| if (std.ascii.eqlIgnoreCase(name, g)) return true;
    if (std.ascii.eqlIgnoreCase(name, "VSS")) return true;
    return std.ascii.startsWithIgnoreCase(name, "GND_") or
        std.ascii.startsWithIgnoreCase(name, "VSS_");
}

/// True when `base` is tied — via a `(net …)` form / net-tie — to a sub-block
/// power port whose internal leaf net carries a decoupling cap. Lets a board
/// rail count a peripheral module's own bypassing (e.g. `flash/VDDIO` on V1P8).
fn tiedSubBlockHasCap(block: *const DesignBlock, base: []const u8) bool {
    for (block.net_ties) |tie| {
        const other: ?[]const u8 = if (std.mem.eql(u8, tie.a, base))
            tie.b
        else if (std.mem.eql(u8, tie.b, base))
            tie.a
        else
            null;
        if (other) |o| {
            if (std.mem.indexOfScalar(u8, o, '/') != null and subBlockNetHasCap(block, o)) {
                return true;
            }
        }
    }
    return false;
}

// ── Ferrite-bridge union-find ────────────────────────────────────────────
// Shared by rails.zig and power_budget.zig (previously copy-pasted in both).

/// Find the canonical root of `name` in a net union-find map.
pub fn findRoot(parent: *std.StringHashMapUnmanaged([]const u8), name: []const u8) []const u8 {
    var cur = name;
    while (parent.get(cur)) |p| {
        if (std.mem.eql(u8, p, cur)) return cur;
        cur = p;
    }
    return cur;
}

/// Union the classes containing `a` and `b`. Internal to `buildFerriteBridges`.
fn unionNets(
    allocator: std.mem.Allocator,
    parent: *std.StringHashMapUnmanaged([]const u8),
    a: []const u8,
    b: []const u8,
) std.mem.Allocator.Error!void {
    const ra = findRoot(parent, a);
    const rb = findRoot(parent, b);
    if (std.mem.eql(u8, ra, rb)) return;
    try parent.put(allocator, rb, ra);
}

/// Build a union-find over base-net names bridged by ferrite beads (a ferrite
/// is a DC conductor, so loads on its downstream net attribute to the upstream
/// rail). Caller owns the returned map (`deinit`).
///
/// The legacy pin-`1`↔pin-`2` bridge is preserved exactly (including the
/// partial bridge it produced on multi-channel ferrite arrays). When a ferrite
/// has no `1`/`2` pads (letter-named pads, `A`/`B`, …) it now falls back to
/// bridging its two nets *by membership* — but only when it touches exactly two
/// distinct base-nets, so a genuine array (≥3 nets) is never mis-bridged. This
/// is purely additive: any ferrite that bridged before still bridges identically.
pub fn buildFerriteBridges(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged([]const u8) {
    var net_parent: std.StringHashMapUnmanaged([]const u8) = .empty;
    errdefer net_parent.deinit(allocator);
    for (block.instances) |inst| {
        if (!std.mem.startsWith(u8, inst.component, "ferrite")) continue;
        var net_a: ?[]const u8 = null; // pad "1"
        var net_b: ?[]const u8 = null; // pad "2"
        var d0: ?[]const u8 = null; // first distinct base-net touched
        var d1: ?[]const u8 = null; // second distinct base-net touched
        var multi = false; // touches ≥3 distinct base-nets
        for (block.nets) |net| {
            const base = baseNetName(net.name);
            var touches = false;
            for (net.pins) |p| {
                if (!std.mem.eql(u8, p.ref_des, inst.ref_des)) continue;
                touches = true;
                if (std.mem.eql(u8, p.pin, "1")) net_a = base;
                if (std.mem.eql(u8, p.pin, "2")) net_b = base;
            }
            if (!touches) continue;
            if (d0 == null) {
                d0 = base;
            } else if (!std.mem.eql(u8, d0.?, base)) {
                if (d1 == null) {
                    d1 = base;
                } else if (!std.mem.eql(u8, d1.?, base)) {
                    multi = true;
                }
            }
        }
        if (net_a != null and net_b != null) {
            try unionNets(allocator, &net_parent, net_a.?, net_b.?);
        } else if (!multi) {
            if (d0) |a| if (d1) |b| try unionNets(allocator, &net_parent, a, b);
        }
    }
    return net_parent;
}

// The vocabulary tables' independent witness. Each expectation is the literal
// list the consuming module held before it started importing the table,
// transcribed by hand — so a table edited here without its consumer in mind
// fails HERE, naming the classifier whose answer just changed, instead of
// silently making a net ground to the plane stitcher and signal to the ERC.
// Deriving the expectation from the table itself would make the test circular.
test "the ground-net vocabulary tables keep the spellings their consumers had" {
    const S = []const []const u8;
    try std.testing.expectEqualDeep(
        @as(S, &.{ "GNDA", "GNDD", "AGND", "PGND", "DGND", "VSSA", "GND", "VSS" }),
        @as(S, &ground_tokens),
    );
    try std.testing.expectEqualDeep(
        @as(S, &.{ "GND", "VSS", "AGND", "DGND", "PGND", "SGND" }),
        @as(S, &ground_fn_prefixes),
    );
    try std.testing.expectEqualDeep(
        @as(S, &.{ "GND", "AGND", "DGND", "PGND" }),
        @as(S, &ground_base_names),
    );
    try std.testing.expectEqualDeep(
        @as(S, &.{ "GND_", "AGND_", "DGND_", "PGND_", "VSS" }),
        @as(S, &ground_stem_prefixes),
    );
    try std.testing.expectEqualDeep(
        @as(S, &.{ "GND", "AGND", "DGND" }),
        @as(S, &schematic_ground_names),
    );
    try std.testing.expectEqualStrings("AGND", analog_ground);
    try std.testing.expectEqualStrings("DGND", digital_ground);
    try std.testing.expectEqualStrings("PGND", power_ground);
}

// spec: net_analysis - chassis ground counts as 0 V for rating but is not a ground token the pour may fill
test "isRatingZeroVolts adds only the chassis node to the ground tokens" {
    try std.testing.expect(isRatingZeroVolts("CHASSIS_GND"));
    try std.testing.expect(isRatingZeroVolts("CHASSIS_GND2"));
    try std.testing.expect(isRatingZeroVolts("GND"));
    try std.testing.expect(isRatingZeroVolts("AGND3"));
    // A named chassis derivative is a distinct node, not a numbered twin.
    try std.testing.expect(!isRatingZeroVolts("CHASSIS_GND_ISO"));
    try std.testing.expect(!isRatingZeroVolts("V_12V"));
    // The barrier must stay open to the pour, the plane stitcher and the DRC:
    // whatever this predicate says, `isGroundName` still says no.
    try std.testing.expect(!isGroundName(chassis_ground));
    for (ground_tokens) |t| try std.testing.expect(!std.mem.eql(u8, t, chassis_ground));
}

// `isGroundBase` is case-insensitive where every other ground predicate here is
// not; this pins that difference rather than leaving it to be "fixed" by
// someone unifying the tables.
test "isGroundBase accepts the base names in any case and only those" {
    try std.testing.expect(isGroundBase("GND"));
    try std.testing.expect(isGroundBase("gnd"));
    try std.testing.expect(isGroundBase("AGND"));
    try std.testing.expect(isGroundBase("dgnd"));
    try std.testing.expect(isGroundBase("PGND"));
    try std.testing.expect(isGroundBase("VSS"));
    try std.testing.expect(isGroundBase("GND_ISO"));
    try std.testing.expect(isGroundBase("vss_a"));
    // Not ground: the suffix spellings this table deliberately omits, a signal
    // that merely starts with a ground stem, and a rail.
    try std.testing.expect(!isGroundBase("GNDA"));
    try std.testing.expect(!isGroundBase("GNDSW"));
    try std.testing.expect(!isGroundBase("VDD"));
}

// spec: net_analysis - a top-level input power port creates decoupling demand
test "top-level input power ports require decoupling" {
    const allocator = std.testing.allocator;
    const instances = [_]env_mod.Instance{.{
        .ref_des = "U1",
        .component = "ic",
        .value = "ic",
        .footprint = "x",
        .symbol = "ic",
    }};
    const nets = [_]env_mod.Net{.{ .name = "VDD", .pins = &.{.{ .ref_des = "U1", .pin = "1" }} }};
    const ports = [_]env_mod.Port{.{ .name = "VIN", .net = "VDD", .direction = "in", .kind = "power" }};
    const block: DesignBlock = .{
        .name = "top power port",
        .instances = &instances,
        .nets = &nets,
        .ports = &ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const missing = try findMissingDecouplingNets(allocator, &block);
    defer allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 1), missing.len);
    try std.testing.expectEqualStrings("VDD", missing[0]);
}

// spec: net_analysis - a capacitor only qualifies when it bridges the supply to ground
test "supply capacitor without a ground leg is not decoupling" {
    const allocator = std.testing.allocator;
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "ic", .footprint = "x", .symbol = "ic" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "x", .symbol = "cap" },
    };
    const ports = [_]env_mod.Port{.{ .name = "VIN", .net = "VDD", .direction = "in", .kind = "power" }};
    const wrong_nets = [_]env_mod.Net{
        .{ .name = "VDD", .pins = &.{
            .{ .ref_des = "U1", .pin = "1" },
            .{ .ref_des = "C1", .pin = "1" },
        } },
        .{ .name = "SENSE", .pins = &.{.{ .ref_des = "C1", .pin = "2" }} },
    };
    var block = DesignBlock{
        .name = "wrong return",
        .instances = &instances,
        .nets = &wrong_nets,
        .ports = &ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const missing = try findMissingDecouplingNets(allocator, &block);
    defer allocator.free(missing);
    try std.testing.expectEqual(@as(usize, 1), missing.len);

    const valid_nets = [_]env_mod.Net{
        .{ .name = "VDD", .pins = &.{
            .{ .ref_des = "U1", .pin = "1" },
            .{ .ref_des = "C1", .pin = "1" },
        } },
        .{ .name = "GND", .pins = &.{.{ .ref_des = "C1", .pin = "2" }} },
    };
    block.nets = &valid_nets;
    const satisfied = try findMissingDecouplingNets(allocator, &block);
    defer allocator.free(satisfied);
    try std.testing.expectEqual(@as(usize, 0), satisfied.len);
}
