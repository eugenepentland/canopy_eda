//! The decoupling-binding model the placement passes read: which hub pad a
//! bypass capacitor was told to serve, and — crucially — which IC that pad
//! belongs to.
//!
//! The pad and the IC are one value because the pad ALONE is ambiguous. A
//! physical pad number belongs to exactly one part, but a rail shared by two
//! same-family ICs has two parts carrying a pad of that number, and resolving
//! the binding by matching the string picks whichever the net happens to list
//! first — silently tightening a cap against the wrong die. Keeping the pair
//! together makes that class of mistake unrepresentable.
//!
//! Split out of `optimizer.zig` so the rule lives somewhere small enough to
//! read, and deliberately holding only the ref-des STRINGS rather than the
//! solver's `Part` values, so this module depends on nothing in `placement/`
//! and the dependency runs one way.

const std = @import("std");
const flat_netlist = @import("../flat_netlist.zig");
const decouple_key = @import("../decouple_key.zig");

/// One cap's authored decoupling target. `ic` is the flattened ref-des a
/// `(decouples "IC" PIN)` names — empty for a `(decouple … per-pin …)` child
/// whose structural key spells only a pad, and for an unbound cap. `pad` is the
/// hub pad, empty when the cap names none.
pub const CapTarget = struct {
    ic: []const u8 = "",
    pad: []const u8 = "",
};

/// The decoupling target a flattened instance declares: an explicit
/// `(decouples "IC" PIN)` binding, else the pad a per-pin generator encoded in
/// its structural origin key (which names no IC).
pub fn targetOf(inst: flat_netlist.FlatInstance) CapTarget {
    if (inst.bind.decouple.pin.len > 0) return .{ .ic = inst.bind.decouple.ic, .pad = inst.bind.decouple.pin };
    if (decouple_key.pinFromOrigin(inst.origin_key)) |pad| return .{ .pad = pad };
    return .{};
}

/// Every part's authored binding, index-aligned: the ref-des of the part itself,
/// the hub pad it names, the hub IC it names, and the `(decouples rail)`
/// opt-outs. Bundled because all four travel together from the solve's
/// preparation down to the loop builder, and because pad and IC are only
/// meaningful read together — see the module comment.
pub const CapBinds = struct {
    /// Ref-des of every part, so a binding can be checked against the part it
    /// would attach to.
    ref_des: []const []const u8,
    pin: []const []const u8,
    ic: []const []const u8,
    optout: []const bool,

    /// True when `cap` explicitly names `hub` as the IC it decouples.
    pub fn namesHub(self: CapBinds, cap: usize, hub: usize) bool {
        return self.ic[cap].len > 0 and std.mem.eql(u8, self.ic[cap], self.ref_des[hub]);
    }

    /// The pad `cap`'s power leg should target on `hub`: its named pad when the
    /// cap names this very hub, or names no IC at all (a per-pin generator key,
    /// whose pad the caller has already matched against this net). "" when the
    /// cap names a DIFFERENT IC — an authored binding must never silently
    /// retarget, so the caller falls back to the hub's default supply pad and
    /// the cap reads as unbound to the `decouple-unbound` lint, which is the
    /// honest report rather than a quiet mis-bind.
    pub fn pinFor(self: CapBinds, cap: usize, hub: usize) []const u8 {
        if (self.ic[cap].len > 0 and !self.namesHub(cap, hub)) return "";
        return self.pin[cap];
    }
};

const testing = std.testing;

// spec: placement/optimizer - a decoupling binding naming another IC yields no pad for that hub while an unnamed one still does
test "pinFor honours the named IC and namesHub identifies it" {
    const refs = [_][]const u8{ "U1", "U2", "C1", "C2" };
    const pins = [_][]const u8{ "", "", "5", "5" };
    const ics = [_][]const u8{ "", "", "U2", "" };
    const optout = [_]bool{ false, false, false, false };
    const binds = CapBinds{ .ref_des = &refs, .pin = &pins, .ic = &ics, .optout = &optout };

    // C1 names U2: it offers its pad to U2 and nothing to U1, even though U1
    // may well carry a pad "5" of its own on the same rail.
    try testing.expect(binds.namesHub(2, 1));
    try testing.expect(!binds.namesHub(2, 0));
    try testing.expectEqualStrings("5", binds.pinFor(2, 1));
    try testing.expectEqualStrings("", binds.pinFor(2, 0));

    // C2 names no IC (a per-pin shorthand child), so its pad applies to whatever
    // hub the caller resolved — the historical behaviour, unchanged.
    try testing.expect(!binds.namesHub(3, 0));
    try testing.expectEqualStrings("5", binds.pinFor(3, 0));
    try testing.expectEqualStrings("5", binds.pinFor(3, 1));
}

// spec: placement/optimizer - an explicit decoupling binding outranks the per-pin structural key when reading a part's target
test "targetOf prefers the explicit binding over the origin key" {
    // Explicit `(decouples "U1" 24)` — both halves survive.
    const bound = flat_netlist.FlatInstance{
        .ref_des = "C1",
        .component = "cap-0402",
        .value = "100nF",
        .footprint = "",
        .properties = &.{},
        .uuid = "",
        .origin_key = "100nF@7#0",
        .bind = .{ .decouple = .{ .ic = "U1", .pin = "24" } },
    };
    try testing.expectEqualStrings("U1", targetOf(bound).ic);
    try testing.expectEqualStrings("24", targetOf(bound).pad);

    // A per-pin child with no explicit binding falls back to its structural key,
    // which names a pad but no IC.
    const shorthand = flat_netlist.FlatInstance{
        .ref_des = "C2",
        .component = "cap-0402",
        .value = "100nF",
        .footprint = "",
        .properties = &.{},
        .uuid = "",
        .origin_key = "100nF@7#0",
    };
    try testing.expectEqualStrings("", targetOf(shorthand).ic);
    try testing.expectEqualStrings("7", targetOf(shorthand).pad);

    // An ordinary named part declares nothing.
    const plain = flat_netlist.FlatInstance{
        .ref_des = "R1",
        .component = "res-0402",
        .value = "10k",
        .footprint = "",
        .properties = &.{},
        .uuid = "",
        .origin_key = "R1",
    };
    try testing.expectEqualStrings("", targetOf(plain).pad);
}
