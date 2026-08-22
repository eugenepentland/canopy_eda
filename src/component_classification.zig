//! Shared semantic component classification used by ERC and strict preflight.
//! It combines the authored ref-des class with the component-family fallback
//! so `IC4` and `PS1` cannot evade active-part policy while connectors and
//! passives remain exempt.

const std = @import("std");
const env = @import("eval/env.zig");
const ids = @import("eval/ids.zig");

/// True when `inst` is an active semiconductor that should carry a datasheet
/// review and requirements. Unambiguous IC/power/transistor classes win;
/// importer-default `U` parts may still be description-identified passive RF
/// networks; known passive/electromechanical classes are exempt.
pub fn isActiveSemiconductor(inst: env.Instance) bool {
    const prefix = refDesClass(inst.ref_des);
    if (isUnambiguousActiveClass(prefix)) return true;
    if (isExemptClass(prefix)) return false;
    if (std.mem.eql(u8, prefix, "U")) return !hasPassiveDescription(inst);
    const inferred = ids.componentPrefix(inst.component);
    return inferred == 'U' or inferred == 'Q';
}

fn isUnambiguousActiveClass(prefix: []const u8) bool {
    const active = [_][]const u8{ "IC", "PS", "VR", "Q" };
    for (active) |class| if (std.mem.eql(u8, prefix, class)) return true;
    return false;
}

fn isExemptClass(prefix: []const u8) bool {
    const exempt = [_][]const u8{
        "R", "C",  "L", "F",  "FB", "FL", "D",  "J", "P",  "X",   "Y",
        "S", "SW", "K", "RL", "T",  "H",  "MH", "M", "TP", "FID",
    };
    for (exempt) |class| if (std.mem.eql(u8, prefix, class)) return true;
    return false;
}

fn hasPassiveDescription(inst: env.Instance) bool {
    for (inst.properties) |property| {
        if (!std.mem.eql(u8, property.key, "description")) continue;
        const passive_terms = [_][]const u8{
            "filter", "fltr",    "transformer", "equalizer", "equaliser",
            "balun",  "coupler", "splitter",    "fiducial",
        };
        for (passive_terms) |term| {
            if (std.ascii.findIgnoreCase(property.value, term) != null) return true;
        }
    }
    return false;
}

fn refDesClass(ref_des: []const u8) []const u8 {
    var end: usize = 0;
    while (end < ref_des.len and std.ascii.isAlphabetic(ref_des[end])) : (end += 1) {}
    return ref_des[0..end];
}

test "active classification recognizes multi-letter IC and power refs" {
    const fixture = env.Instance{
        .ref_des = "IC4",
        .component = "adp150aujz-3-3-r7",
        .value = "",
        .footprint = "",
        .symbol = "",
    };
    try std.testing.expect(isActiveSemiconductor(fixture));
    var ps = fixture;
    ps.ref_des = "PS1";
    try std.testing.expect(isActiveSemiconductor(ps));
}

test "active classification exempts connectors and infers unknown active refs" {
    const connector = env.Instance{
        .ref_des = "J1",
        .component = "unrecognized-connector-name",
        .value = "",
        .footprint = "",
        .symbol = "",
    };
    try std.testing.expect(!isActiveSemiconductor(connector));
    var passive = connector;
    passive.ref_des = "R12";
    passive.component = "res-0402";
    try std.testing.expect(!isActiveSemiconductor(passive));
    var custom_active = connector;
    custom_active.ref_des = "A1";
    custom_active.component = "adp150aujz-3-3-r7";
    try std.testing.expect(isActiveSemiconductor(custom_active));
}

test "U-class passive RF parts and fiducials are not active semiconductors" {
    const description = [_]env.Property{.{
        .key = "description",
        .value = "LTCC SMT High Pass Filter, 1.85 - 11 GHz",
    }};
    const filter = env.Instance{
        .ref_des = "U12",
        .component = "hfcg-1630+",
        .value = "",
        .footprint = "hfcg1630",
        .symbol = "",
        .properties = &description,
    };
    try std.testing.expect(!isActiveSemiconductor(filter));
    var fiducial = filter;
    fiducial.ref_des = "FID1";
    fiducial.component = "fiducial-0p75-2p25";
    fiducial.properties = &.{};
    try std.testing.expect(!isActiveSemiconductor(fiducial));
}
