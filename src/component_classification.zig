//! Shared semantic component classification used by ERC, coverage and strict
//! preflight: is this placed part an active semiconductor, and therefore
//! subject to datasheet-review / requirement / IC-BOM policy?
//!
//! **A ref-des letter is the weakest evidence available.** It is authored
//! evidence only when someone chose it. The KiCad importer defaults every part
//! whose name it does not recognise to the IC class `U` (`ids.componentPrefix`
//! ends in "everything else is an IC"), so on a real board a barrel jack, six
//! SMA connectors, a board-to-board socket, three LEDs, two crystals, two tact
//! switches and a stack of M2 SMT spacers all arrive wearing `U`. Reading that
//! letter as "IC" makes the release gate demand a datasheet review from a
//! steel standoff.
//!
//! So the ref-des is consulted where it IS evidence — an authored `Q`/`IC`/
//! `PS`/`VR` class, or one of the passive / electromechanical classes — and
//! everything else is decided from the LIBRARY's own knowledge of the part:
//! what its `lib/components` entry says it is, and what the shape of its
//! `lib/pinouts` entry proves it is (`Instance.pinout_facts`).
//!
//! The structural half is what makes the descriptive half safe. "Attenuator",
//! "switch" and "LED" all appear in the descriptions of genuine ICs — a
//! digital step attenuator, an RF switch IC, an LED driver — so the vocabulary
//! below only reclassifies a part whose pinout declares **no supply pad at
//! all**. An integrated circuit has one; a connector, a crystal, a fixed
//! attenuator and a tactile switch do not. Where there is no pinout to read,
//! nothing is reclassified: absence of evidence is not evidence.

const std = @import("std");
const env = @import("eval/env.zig");
const ids = @import("eval/ids.zig");

/// True when `inst` is an active semiconductor that should carry a datasheet
/// review and requirements.
///
/// In order: an unambiguous authored active class wins; a passive /
/// electromechanical class is exempt; the part's own library entry may then
/// identify it as an inert (non-semiconductor) part regardless of the letter
/// it wears; the importer-default `U` may still be a description-identified
/// passive RF network; otherwise the component-family heuristic decides.
pub fn isActiveSemiconductor(inst: env.Instance) bool {
    const prefix = refDesClass(inst.ref_des);
    if (isUnambiguousActiveClass(prefix)) return true;
    if (isExemptClass(prefix)) return false;
    if (libraryIdentifiesInertPart(inst)) return false;
    if (std.mem.eql(u8, prefix, "U")) return !hasPassiveDescription(inst);
    const inferred = ids.componentPrefix(inst.component);
    return inferred == 'U' or inferred == 'Q';
}

fn isUnambiguousActiveClass(prefix: []const u8) bool {
    const active = [_][]const u8{ "IC", "PS", "VR", "Q" };
    for (active) |class| if (std.mem.eql(u8, prefix, class)) return true;
    return false;
}

/// Ref-des classes that are never an active semiconductor. `MK` is the
/// mounting-hardware class (M2/M3 SMT spacers, standoffs) — it sits beside the
/// older `MH`/`H`/`M` mounting spellings the library already used.
fn isExemptClass(prefix: []const u8) bool {
    const exempt = [_][]const u8{
        "R", "C",  "L", "F",  "FB", "FL", "D",  "J",  "P", "X",  "Y",
        "S", "SW", "K", "RL", "T",  "H",  "MH", "MK", "M", "TP", "FID",
    };
    for (exempt) |class| if (std.mem.eql(u8, prefix, class)) return true;
    return false;
}

/// True when the part's OWN library entry identifies it as something that is
/// not a semiconductor — whatever ref-des letter the importer gave it.
///
/// Both routes require the same structural corroboration: the pinout is known
/// and declares no supply pad. That single condition is what keeps the
/// vocabulary honest, because every counter-example is an IC and every IC has
/// a supply pad — the HMC1119 digital step attenuator ("Attenuators 7-bit"),
/// the PE42553 RF switch ("RF Switch ICs SPDT") and any LED driver all keep
/// their `VDD` and stay active.
///
/// Route 1 is the library description naming a part CLASS (`describesInertClass`).
/// Route 2 is a purely positional pinout — every pad named after its own
/// number — which means the part had no pin functions to record at all: a
/// connector, a socket, a mechanical spacer. Two-pad parts are excluded from
/// route 2 because a bare `1`/`2` pinout is the generic two-terminal shape
/// shared with real discretes (a TVS diode, for one), so it proves nothing.
fn libraryIdentifiesInertPart(inst: env.Instance) bool {
    const facts = inst.pinout_facts;
    if (!facts.known or facts.has_supply) return false;
    if (describesInertClass(inst)) return true;
    return facts.positional and facts.pin_count != 2;
}

/// True when the library `(description …)` names one of the inert part classes
/// below. Single words are matched as whole words (so "Coupled" is not
/// "coupler" and a part number fragment is never a match); multi-word spellings
/// are matched as case-insensitive substrings.
fn describesInertClass(inst: env.Instance) bool {
    for (inst.properties) |property| {
        if (!std.mem.eql(u8, property.key, "description")) continue;
        if (matchesInertVocabulary(property.value)) return true;
    }
    return false;
}

/// Head nouns for classes of part that contain no semiconductor junction:
/// mounting hardware, connectors, indicators, resonators, mechanical switches,
/// and fixed RF attenuators.
const inert_words = [_][]const u8{
    "spacer",      "spacers",    "standoff",  "standoffs",  "screw",       "screws",
    "washer",      "washers",    "connector", "connectors", "receptacle",  "receptacles",
    "jack",        "jacks",      "socket",    "sockets",    "header",      "headers",
    "plug",        "plugs",      "led",       "leds",       "crystal",     "crystals",
    "resonator",   "resonators", "tactile",   "pushbutton", "pushbuttons", "attenuator",
    "attenuators",
};

/// Multi-word spellings of the same classes, matched as substrings because
/// their meaning lives in the pair rather than in either word alone ("tact
/// switch" is electromechanical; "FET switch" is not).
const inert_phrases = [_][]const u8{
    "mounting hole",  "mounting hardware", "shield can",    "stand-off",
    "terminal block", "tact switch",       "push button",   "dip switch",
    "slide switch",   "toggle switch",     "rotary switch", "light emitting diode",
    "light-emitting",
};

fn matchesInertVocabulary(text: []const u8) bool {
    for (inert_phrases) |phrase| {
        if (std.ascii.findIgnoreCase(text, phrase) != null) return true;
    }
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n,.;:/\\()[]{}<>\"'|+*&_-");
    while (words.next()) |word| {
        for (inert_words) |term| {
            if (std.ascii.eqlIgnoreCase(word, term)) return true;
        }
    }
    return false;
}

/// The older, narrower RF-network vocabulary, kept ungated on purpose: these
/// head nouns are unambiguous for the `U` class (a "high pass filter", a
/// "balun", a "power splitter" is never an IC), and several of the parts they
/// cover are component-families with no pinout file at all, so demanding
/// structural corroboration would silently re-arm policy against them.
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

/// Build a placed-part fixture: `ref` wearing `component`, described by
/// `description`, with `facts` standing in for its `lib/pinouts` entry.
/// The description slice must outlive the returned instance.
fn fixtureInstance(
    ref: []const u8,
    component: []const u8,
    description: []const env.Property,
    facts: env.PinoutFacts,
) env.Instance {
    return .{
        .ref_des = ref,
        .component = component,
        .value = "",
        .footprint = "",
        .symbol = "",
        .properties = description,
        .pinout_facts = facts,
    };
}

/// A pinout whose every pad is named after its own number — what the importer
/// writes for a connector or a mechanical part.
fn positionalPinout(pins: u16) env.PinoutFacts {
    return .{ .known = true, .positional = true, .pin_count = pins };
}

// spec: component_classification - isActiveSemiconductor exempts the MK mounting-hardware ref-des class
test "MK mounting spacers are never active semiconductors" {
    const spacer = fixtureInstance("MK3", "9774020243r", &.{}, positionalPinout(1));
    try std.testing.expect(!isActiveSemiconductor(spacer));
    // The same part wearing the importer's default U ref-des must reach the
    // same answer, this time from its library entry rather than its letter.
    var imported = spacer;
    imported.ref_des = "U20";
    try std.testing.expect(!isActiveSemiconductor(imported));
}

// spec: component_classification - isActiveSemiconductor exempts a connector carrying an importer-default U ref-des
test "connectors with a U ref-des are identified by their positional pinout" {
    const sma = fixtureInstance("U12", "sma-j-p-h-st-em1", &.{}, positionalPinout(3));
    try std.testing.expect(!isActiveSemiconductor(sma));
    var socket = sma;
    socket.ref_des = "U19";
    socket.component = "erf6-20-03-5-l-dv-a-k-tr";
    socket.pinout_facts = positionalPinout(40);
    try std.testing.expect(!isActiveSemiconductor(socket));
    // A two-pad positional pinout is the generic two-terminal shape a real
    // discrete also wears, so it is not evidence and the part stays active.
    var tvs = sma;
    tvs.ref_des = "U33";
    tvs.component = "smbj15ca";
    tvs.pinout_facts = positionalPinout(2);
    try std.testing.expect(isActiveSemiconductor(tvs));
}

// spec: component_classification - isActiveSemiconductor exempts LEDs crystals and tactile switches wearing a U ref-des
test "LED crystal and tactile switch with U ref-des are not active semiconductors" {
    const led_desc = [_]env.Property{.{
        .key = "description",
        .value = "Lite-On LTST-S270KGKT, 571 nm Green LED, 1608 (0603) Side View SMD package",
    }};
    const led = fixtureInstance("U9", "ltst-s270kgkt", &led_desc, .{ .known = true, .pin_count = 2 });
    try std.testing.expect(!isActiveSemiconductor(led));

    const xtal_desc = [_]env.Property{.{
        .key = "description",
        .value = "12MHz +/-30ppm Crystal 20pF 80 Ohms 4-SMD, No Lead",
    }};
    const xtal = fixtureInstance("U24", "ecs-120-20-30b-tr", &xtal_desc, .{
        .known = true,
        .has_ground = true,
        .pin_count = 4,
    });
    try std.testing.expect(!isActiveSemiconductor(xtal));

    const sw_desc = [_]env.Property{.{
        .key = "description",
        .value = "Wurth WS-TATU 6x6mm right-angle THT tact switch, 8.35mm, black actuator, 160gf",
    }};
    const tact = fixtureInstance("U26", "sw-ws-tatu-431256083716", &sw_desc, .{
        .known = true,
        .has_ground = true,
        .pin_count = 4,
    });
    try std.testing.expect(!isActiveSemiconductor(tact));

    const atten_desc = [_]env.Property{.{
        .key = "description",
        .value = "YAT-6A+ 6 dB fixed RF attenuator used in a PLL feedback path",
    }};
    const atten = fixtureInstance("A1", "yat-6a-feedback", &atten_desc, .{
        .known = true,
        .has_ground = true,
        .pin_count = 7,
    });
    try std.testing.expect(!isActiveSemiconductor(atten));
}

// spec: component_classification - isActiveSemiconductor keeps a supply-pinned IC active when its description names an inert class
test "ICs whose descriptions name an inert class stay active via their supply pin" {
    const rf_switch_desc = [_]env.Property{.{
        .key = "description",
        .value = "RF Switch ICs SPDT, High Iso, High Power, Absorptive, 50 Ohm Instrumentation Switch",
    }};
    const rf_switch = fixtureInstance("U30", "pe42553b-z", &rf_switch_desc, .{
        .known = true,
        .has_supply = true,
        .has_ground = true,
        .pin_count = 17,
    });
    try std.testing.expect(isActiveSemiconductor(rf_switch));

    const dsa_desc = [_]env.Property{.{
        .key = "description",
        .value = "Attenuators 7-bit 0.1-6Ghz DATT",
    }};
    const dsa = fixtureInstance("U9", "hmc1119lp4metr", &dsa_desc, .{
        .known = true,
        .has_supply = true,
        .has_ground = true,
        .pin_count = 25,
    });
    try std.testing.expect(isActiveSemiconductor(dsa));

    const mcu_desc = [_]env.Property{.{
        .key = "description",
        .value = "Ethernet ICs 10/100Mbps Ethernet, easy to add Ethernet networking",
    }};
    const mcu = fixtureInstance("U23", "w55rp20-s2e", &mcu_desc, .{
        .known = true,
        .has_supply = true,
        .has_ground = true,
        .pin_count = 69,
    });
    try std.testing.expect(isActiveSemiconductor(mcu));
}

// spec: component_classification - isActiveSemiconductor reclassifies nothing when no pinout corroborates the description
test "an unreadable pinout is not read as absence of a supply pin" {
    const desc = [_]env.Property{.{
        .key = "description",
        .value = "Some part whose description mentions a jack",
    }};
    const unknown = fixtureInstance("U40", "mystery-part", &desc, .{});
    try std.testing.expect(isActiveSemiconductor(unknown));
    // The LDO keeps its supply pin and its policy either way.
    const ldo = fixtureInstance("U19", "lt3045edd#pbf", &.{}, .{
        .known = true,
        .has_ground = true,
        .pin_count = 11,
    });
    try std.testing.expect(isActiveSemiconductor(ldo));
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
