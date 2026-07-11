//! Pin-role classification for the placement optimizer.
//!
//! An IC pad that sits on a power or ground net is not necessarily a real
//! current-carrying pin for that rail: configuration straps are routinely tied
//! to GND or to the input rail (e.g. the LT3045's `ILIM` → GND default-current-
//! limit strap, or `EN/UV` and `PGFB` → IN). The decoupling-loop placer must
//! close its hot loop on the *real* supply/return pins, not on a strap that
//! merely happens to share the net — otherwise it measures (and pulls) the loop
//! to the geometrically nearest pad, which can be a config pin on the far side
//! of the package.
//!
//! Two signals separate real pins from straps, in priority order:
//!   1. A library `(electrical "FN" (type …))` decl on the component. A pin
//!      declared `input`/`output`/`io` is a control/strap pin and is demoted;
//!      `power-in`/`power-out` marks a real supply pin. Keyed by function name,
//!      so it survives pinout regeneration — this is the explicit annotation.
//!   2. The pinout function name. A groundy name (GND*, VSS*, AGND/…, or an
//!      exposed/thermal pad EP/PAD/TAB/…) marks a real ground return with no
//!      annotation needed.
//!
//! Both are read straight from the design's lib/ files, mirroring how
//! `geometry.load` reads footprints, so the optimizer stays self-contained.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser = @import("../sexpr/parser.zig");
const infra_fs = @import("../infra/fs.zig");
const electrical = @import("../eval/electrical.zig");
const env = @import("../eval/env.zig");
const numeric = @import("../numeric.zig");

const Node = ast.Node;
const max_bytes = 1024 * 256;

/// Placement-time role of one IC pad relative to the net it sits on.
pub const PinClass = enum {
    /// Real ground-return / exposed-pad pin.
    ground,
    /// Real supply pin (declared `power-in`/`power-out`).
    power,
    /// Configuration / control strap tied to a rail (EN, ILIM, PGFB, …).
    strap,
    /// Unclassified — treated as a normal pin (kept, never preferred).
    other,
};

/// Per-component pin classification: physical pad id → class. Built once per
/// component and shared by every instance of it.
pub const PartRoles = struct {
    map: std.StringHashMapUnmanaged(PinClass) = .empty,

    /// Class of physical pad `pin` (e.g. "5"); `.other` when the pin is unknown
    /// or no library data was found.
    pub fn classOf(self: PartRoles, pin: []const u8) PinClass {
        return self.map.get(pin) orelse .other;
    }
};

/// Load `component`'s pin classification from its `lib/components` +
/// `lib/pinouts` files under `project_dir`. A missing or malformed file yields
/// an empty map (every pin `.other`), so a part with no library data behaves
/// exactly as it did before pin roles existed. Allocated in `arena`.
pub fn load(arena: std.mem.Allocator, project_dir: []const u8, component: []const u8) PartRoles {
    if (component.len == 0) return .{};

    // fn-name → electrical type, plus the pinout file name, from the component.
    var elec: std.StringHashMapUnmanaged(env.ElectricalType) = .empty;
    var pinout_name: []const u8 = component;
    if (loadList(arena, project_dir, "components", component)) |children| {
        for (children) |child| {
            const cl = child.asList() orelse continue;
            if (cl.len < 2) continue;
            const head = cl[0].asAtom() orelse continue;
            if (std.mem.eql(u8, head, "pinout")) {
                if (cl[1].asText()) |p| pinout_name = p;
            } else if (std.mem.eql(u8, head, "electrical")) {
                const decl = electrical.parse(cl) orelse continue;
                const t = decl.electrical_type orelse continue;
                elec.put(arena, decl.pin, t) catch continue;
            }
        }
    }

    // physical pad id → primary function name, from the pinout file.
    const top = loadList(arena, project_dir, "pinouts", pinout_name) orelse return .{};
    if (top.len < 2 or !std.mem.eql(u8, top[0].asAtom() orelse "", "pinout")) return .{};

    var roles = PartRoles{};
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        if (!std.mem.eql(u8, cl[0].asAtom() orelse "", "pin")) continue;
        const pad_id = nodeText(arena, cl[1]) orelse continue;
        const fn_name = cl[2].asText() orelse continue;
        roles.map.put(arena, pad_id, classify(elec.get(fn_name), fn_name)) catch continue;
    }
    return roles;
}

/// Read `<project_dir>/lib/<dir>/<name>.sexp`, parse it, and return the first
/// top-level form's children. Null on any read/parse failure (caller degrades).
fn loadList(arena: std.mem.Allocator, project_dir: []const u8, dir: []const u8, name: []const u8) ?[]const Node {
    const path = std.fmt.allocPrint(arena, "{s}/lib/{s}/{s}.sexp", .{ project_dir, dir, name }) catch return null;
    const src = infra_fs.cwd().readFileAlloc(arena, path, max_bytes) catch return null;
    const nodes = parser.parse(arena, src) catch return null;
    if (nodes.len == 0) return null;
    return nodes[0].asList();
}

/// Stringify a pad-id node exactly as the evaluator does (`ids.pinId`): a bare
/// integer becomes its decimal text ("5"), an atom/string passes through. This
/// keeps the map keys aligned with the flattened net's `pin` ids.
fn nodeText(arena: std.mem.Allocator, n: Node) ?[]const u8 {
    if (n.asText()) |t| return t;
    if (n.asNumber()) |num| {
        const i = numeric.checkedInt(i64, num) orelse 0;
        return std.fmt.allocPrint(arena, "{d}", .{i}) catch null;
    }
    return null;
}

/// Map a pin's library electrical type (if declared) plus its function name to a
/// placement class. The electrical type wins; otherwise the name is inferred.
fn classify(elec_type: ?env.ElectricalType, fn_name: []const u8) PinClass {
    if (elec_type) |t| switch (t) {
        .input, .output, .io => return .strap,
        .power_in, .power_out => return .power,
        // passive / nc carry no placement signal — fall through to the name.
        .passive, .nc => {},
    };
    if (isGroundFn(fn_name)) return .ground;
    return .other;
}

/// True when `fn_name` (a pinout function name) denotes a real ground return or
/// exposed/thermal pad — not a strap that merely happens to be tied to GND.
/// Separators are stripped and the comparison is case-insensitive, so "GND_1",
/// "gnd", and "AGND" all match while "ILIM", "EN/UV", and "PGFB" do not.
pub fn isGroundFn(fn_name: []const u8) bool {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (fn_name) |c| switch (c) {
        '_', '-', '/', '.', ' ', '#' => {},
        else => {
            if (n >= buf.len) break;
            buf[n] = std.ascii.toUpper(c);
            n += 1;
        },
    };
    const s = buf[0..n];
    const prefixes = [_][]const u8{ "GND", "VSS", "AGND", "DGND", "PGND", "SGND" };
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    const exact = [_][]const u8{ "EP", "EPAD", "PAD", "TAB", "THERMAL", "EXP", "EXPOSED", "DAP", "RTN", "RETURN" };
    for (exact) |e| if (std.mem.eql(u8, s, e)) return true;
    return false;
}

/// True when `fn_name` (a pinout function name) denotes a real power-supply pin —
/// VCC/VDD/AVDD/VBAT/VIN/VREF/… — and not a ground or a signal. Normalisation
/// matches `isGroundFn` (separators stripped, case-insensitive). Ground names are
/// rejected first so "VSS"/"VSSA" never read as a supply via the "VS" exact form.
/// Used by the IC-power-presence ERC to decide whether a part is even expected to
/// have a supply pin — a passive RF filter/attenuator or a connector has none, so
/// "IC has no power connection" must not fire on it.
pub fn isSupplyFn(fn_name: []const u8) bool {
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    for (fn_name) |c| switch (c) {
        '_', '-', '/', '.', ' ', '#' => {},
        else => {
            if (n >= buf.len) break;
            buf[n] = std.ascii.toUpper(c);
            n += 1;
        },
    };
    const s = buf[0..n];
    if (isGroundFn(s)) return false;
    // A supply-*named* strap ("VDD_EN", "VIN_SEL0") is a config pin tied to the
    // rail, not a real supply pad: tokenize the raw name and reject it if any
    // token is a strap token. (Checked before the prefix match so "VDD_EN"
    // reads as a strap, not a supply. Done inline rather than via `isStrapFn`
    // to avoid mutual recursion — `isStrapFn` calls `isSupplyFn` first.)
    if (hasStrapToken(fn_name)) return false;
    const prefixes = [_][]const u8{
        "VCC",  "VDD", "AVDD", "DVDD", "PVDD", "VBAT",
        "VBUS", "VIN", "VOUT", "VEE",  "VPP",  "VREF",
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    const exact = [_][]const u8{ "V+", "VS" };
    for (exact) |e| if (std.mem.eql(u8, s, e)) return true;
    return false;
}

/// The component-file half of a part's library data: function-name → electrical
/// type (from `(electrical "FN" (type …))` decls) plus the pinout file name
/// (from `(pinout "name")`, defaulting to the component name). Shared by
/// `strapPads` and `padRequirements`, which then load the pinout and run their
/// own per-pad loop. (`load` keeps its own inline copy — it's on the placement
/// hot path and predates this helper.) Allocated in `arena`.
const ComponentElec = struct {
    elec: std.StringHashMapUnmanaged(env.ElectricalType),
    pinout_name: []const u8,
};

fn loadComponentElec(arena: std.mem.Allocator, project_dir: []const u8, component: []const u8) ComponentElec {
    var elec: std.StringHashMapUnmanaged(env.ElectricalType) = .empty;
    var pinout_name: []const u8 = component;
    if (loadList(arena, project_dir, "components", component)) |children| {
        for (children) |child| {
            const cl = child.asList() orelse continue;
            if (cl.len < 2) continue;
            const head = cl[0].asAtom() orelse continue;
            if (std.mem.eql(u8, head, "pinout")) {
                if (cl[1].asText()) |p| pinout_name = p;
            } else if (std.mem.eql(u8, head, "electrical")) {
                const decl = electrical.parse(cl) orelse continue;
                const t = decl.electrical_type orelse continue;
                elec.put(arena, decl.pin, t) catch continue;
            }
        }
    }
    return .{ .elec = elec, .pinout_name = pinout_name };
}

/// Pads of `component` that are configuration/control straps — enable, mode,
/// address, current-limit, boot, or reset pins a board sets by tying to a rail —
/// mapped pad-id → primary function name. Empty when the library has no data.
///
/// A pad is a strap when the library `(electrical "FN" (type input|output|io))`
/// says so (the same demotion `classify` uses) **or** its pinout function name
/// matches `isStrapFn`. The name heuristic matters because only a handful of
/// library parts carry `(electrical …)` annotations, so an annotation-only rule
/// would miss almost every real strap. Read by the `strap_tied_to_rail` ERC
/// check; the placer's `classify`/`load` path is deliberately left on the
/// electrical-type signal alone, so recognising more straps here never shifts a
/// PCB layout. Allocated in `arena`, mirroring `load`.
pub fn strapPads(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    component: []const u8,
) std.StringHashMapUnmanaged([]const u8) {
    var out: std.StringHashMapUnmanaged([]const u8) = .empty;
    if (component.len == 0) return out;

    const ce = loadComponentElec(arena, project_dir, component);
    const top = loadList(arena, project_dir, "pinouts", ce.pinout_name) orelse return out;
    if (top.len < 2 or !std.mem.eql(u8, top[0].asAtom() orelse "", "pinout")) return out;

    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        if (!std.mem.eql(u8, cl[0].asAtom() orelse "", "pin")) continue;
        const pad_id = nodeText(arena, cl[1]) orelse continue;
        const fn_name = cl[2].asText() orelse continue;
        // Connector / mechanical positional pins name their "function" after the
        // pad itself (apf6 mezzanine: pad "A01" → fn "A01_A01"; bare headers: pad
        // "5" → fn "5"). They carry no real function, so never a config strap.
        if (isPositionalPin(pad_id, fn_name)) continue;
        const strap = classify(ce.elec.get(fn_name), fn_name) == .strap or isStrapFn(fn_name);
        if (strap) {
            out.put(arena, pad_id, fn_name) catch continue;
        }
    }
    return out;
}

/// How much leaving a pad *unconnected* should worry the `no_connect` ERC check.
pub const NcRequirement = enum {
    /// Deferred to another check — supply/ground pads belong to the power-pin
    /// presence check, so a floating one is never double-reported here.
    skip,
    /// Fine to leave open: an unused output, a GPIO/IO, a passive pin, a
    /// datasheet no-connect/reserved pad, or any name we can't confidently
    /// classify. The check stays silent so it never flags every open pad.
    fine,
    /// Probably wants tying off — a config/enable/reset strap recognised only by
    /// name, which is commonly internally pulled. Reported as a *warning*.
    suspect,
    /// Should be driven — a pad the library explicitly declares an `input`.
    /// Reported as an *error*.
    required,
};

/// One pinout pad's no-connect classification: its function name plus how much
/// leaving it unconnected should worry ERC.
pub const PadReq = struct {
    fn_name: []const u8,
    req: NcRequirement,
};

/// Decide how much an *unconnected* pad named `fn_name` (with optional library
/// electrical `type`) should worry the no-connect ERC. ERC-only, exactly like
/// `strapPads` — the placer's `classify`/`load` path never consults it, so
/// recognising a requirement here can never shift a PCB layout.
///
/// Confidence drives severity. Supply/ground pads defer to the power-pin
/// presence check (`.skip`). A library-declared `input` is a high-confidence
/// "must be driven" (`.required` → error). A strap recognised only by *name*
/// (EN/MODE/BOOT/RST/ADDR/…) is a lower-confidence nudge (`.suspect` → warning),
/// since such pins are often internally pulled. Everything else — outputs,
/// GPIO/IO, passives, datasheet NC/reserved names, and any unrecognised name —
/// is `.fine`, so the check surfaces only the open pads worth a second look.
fn connectionRequirement(elec_type: ?env.ElectricalType, fn_name: []const u8) NcRequirement {
    if (isSupplyFn(fn_name) or isGroundFn(fn_name)) return .skip;
    if (elec_type) |t| return switch (t) {
        .input => .required,
        .power_in => .skip,
        .output, .power_out, .io, .passive, .nc => .fine,
    };
    if (isExplicitNcName(fn_name)) return .fine;
    if (isStrapFn(fn_name)) return .suspect;
    return .fine;
}

/// True when a pinout function name explicitly marks the pad a no-connect or
/// reserved/do-not-use pad — "NC", "N/C", "DNC", "DNU", "NO_CONNECT",
/// "RESERVED", "RSVD", "RSV", "RFU", and numbered forms "NC1"/"NC2"/…. Such a
/// pad is *meant* to float, so it's never flagged. Separators are stripped and
/// the match is case-insensitive (so "n/c" and "NC_1" both match).
fn isExplicitNcName(fn_name: []const u8) bool {
    var buf: [32]u8 = undefined;
    const s = normalizeIdent(fn_name, &buf);
    const exact = [_][]const u8{ "NC", "DNC", "DNU", "NOCONNECT", "RESERVED", "RSVD", "RSV", "RFU" };
    for (exact) |e| if (std.mem.eql(u8, s, e)) return true;
    // Numbered no-connects: "NC" followed by only digits ("NC1", "NC12").
    if (s.len > 2 and s[0] == 'N' and s[1] == 'C') {
        for (s[2..]) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    return false;
}

/// Every pinout pad of `component` that the no-connect ERC might flag — pad-id →
/// `{fn_name, requirement}` for pads whose `connectionRequirement` is `.suspect`
/// or `.required`. Pads that are fine to leave open (and supply/ground pads,
/// owned by the power check) are omitted, so the map holds only what ERC acts
/// on. Empty when the library has no readable data (safe degradation: nothing
/// flagged). Mirrors `strapPads`' component+pinout load; allocated in `arena`.
pub fn padRequirements(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    component: []const u8,
) std.StringHashMapUnmanaged(PadReq) {
    var out: std.StringHashMapUnmanaged(PadReq) = .empty;
    if (component.len == 0) return out;

    const ce = loadComponentElec(arena, project_dir, component);
    const top = loadList(arena, project_dir, "pinouts", ce.pinout_name) orelse return out;
    if (top.len < 2 or !std.mem.eql(u8, top[0].asAtom() orelse "", "pinout")) return out;

    // First pass: collect every function name so a level-translator / buffer
    // *channel* ("A<n>" with a "B<n>" twin) can be told apart from a device-
    // address strap ("A<n>" alone) — see isTranslatorChannel.
    var fn_set: std.StringHashMapUnmanaged(void) = .empty;
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3 or !std.mem.eql(u8, cl[0].asAtom() orelse "", "pin")) continue;
        if (cl[2].asText()) |fnm| fn_set.put(arena, fnm, {}) catch continue;
    }

    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        if (!std.mem.eql(u8, cl[0].asAtom() orelse "", "pin")) continue;
        const pad_id = nodeText(arena, cl[1]) orelse continue;
        const fn_name = cl[2].asText() orelse continue;
        const req = connectionRequirement(ce.elec.get(fn_name), fn_name);
        if (req == .suspect or req == .required) {
            // A buffer/level-translator channel (TXB0104 A1-A4/B1-B4, '245, …)
            // is a data I/O, not a config strap — an unused one floats freely.
            if (isTranslatorChannel(fn_name, &fn_set)) continue;
            out.put(arena, pad_id, .{ .fn_name = fn_name, .req = req }) catch continue;
        }
    }
    return out;
}

/// True when `fn_name` is a level-translator / buffer *channel* pin — an "A<n>"
/// or "B<n>" name whose complementary "B<n>"/"A<n>" twin is also in the part's
/// pinout (`fn_set`). Such a pad (TXB0104 A1-A4 / B1-B4, TXS0108, LSF0108, an
/// SN74…245 buffer) is a data I/O, so an unused one is as benign as a spare
/// GPIO and must not read as a device-address strap. Without the twin, an
/// "A<n>" stays a candidate address strap (an INA228 A0/A1, an I²C ADDR bit).
fn isTranslatorChannel(fn_name: []const u8, fn_set: *const std.StringHashMapUnmanaged(void)) bool {
    if (fn_name.len < 2 or fn_name.len > 16) return false;
    const twin: u8 = switch (fn_name[0]) {
        'A' => 'B',
        'B' => 'A',
        else => return false,
    };
    for (fn_name[1..]) |c| if (!std.ascii.isDigit(c)) return false;
    var buf: [16]u8 = undefined;
    buf[0] = twin;
    @memcpy(buf[1..fn_name.len], fn_name[1..]);
    return fn_set.contains(buf[0..fn_name.len]);
}

/// True when `fn_name` names a configuration/control strap. The name is split
/// into alphanumeric tokens (so "PRTPWR1/BC_EN1" → token "EN1" fires, and
/// "SCL/SMBCLK/CFG_SEL0" → "CFG"/"SEL0" fire) and each token is matched whole
/// and anchored — never as a substring — so a GPIO port name like "PA1"/"PD15"
/// is NOT a strap (it doesn't start the address/enable pattern) and "GREEN"
/// never matches "EN". Supply/ground names are rejected first. ERC-only.
fn isStrapFn(fn_name: []const u8) bool {
    if (isGroundFn(fn_name) or isSupplyFn(fn_name)) return false;
    return hasStrapToken(fn_name);
}

/// True when any whole alphanumeric token of `fn_name` is a config-strap token.
/// The raw name is split on separators (so "PRTPWR1/BC_EN1" → token "EN1" fires,
/// "SCL/SMBCLK/CFG_SEL0" → "CFG"/"SEL0" fire) and each token is upper-cased and
/// matched whole and anchored via `isStrapToken`. No supply/ground guard here —
/// callers apply their own (this is used both by `isStrapFn` after its guard and
/// by `isSupplyFn` to reject supply-named straps, where guarding would recurse).
fn hasStrapToken(fn_name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, fn_name, "_-/.# \t~{}()+");
    while (it.next()) |raw| {
        var buf: [32]u8 = undefined;
        if (raw.len == 0 or raw.len > buf.len) continue;
        for (raw, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        if (isStrapToken(buf[0..raw.len])) return true;
    }
    return false;
}

/// Whole-token strap test. `tok` is already upper-cased with separators stripped.
fn isStrapToken(tok: []const u8) bool {
    const exact = [_][]const u8{
        "ENABLE", "NEN",   "ENN",    "CE",     "NCE",    "CEN",  "OE",   "NOE",
        "OEN",    "WP",    "NWP",    "HOLD",   "NHOLD",  "MODE", "SHDN", "NSHDN",
        "STBY",   "NSTBY", "SLEEP",  "CFG",    "CONFIG", "ILIM", "NRST", "RST",
        "RSTN",   "RESET", "NRESET", "RESETN", "PSHOLD", "TEST",
    };
    for (exact) |e| if (std.mem.eql(u8, tok, e)) return true;
    // `<prefix><digits?>` variants — EN/EN1/EN4, BOOT/BOOT0, SEL/SEL0, ADDR/ADDR0.
    if (prefixThenDigits(tok, "EN")) return true;
    if (prefixThenDigits(tok, "BOOT")) return true;
    if (prefixThenDigits(tok, "SEL")) return true;
    if (prefixThenDigits(tok, "ADDR")) return true;
    // Device-address strap A0..A9 — anchored 'A' + exactly one digit. Two-digit
    // forms are intentionally excluded: zero-padded connector grids ("A01".."A20")
    // and parallel-bus address lines ("A14") aren't device-address config straps,
    // and the GPIO port name "PA1" (P-prefixed) never starts with 'A'.
    if (tok.len == 2 and tok[0] == 'A' and std.ascii.isDigit(tok[1])) return true;
    return false;
}

/// True when a pin's function name is just its own pad designator — the
/// signature of a connector / mechanical pin with no real function. Matches the
/// doubled connector form (apf6: pad "A01" → fn "A01_A01") always, and a plain
/// `fn == pad` only for grid-like pads (a letter then a digit, e.g. "A1"/"B12"),
/// so a part that legitimately names a real pad after its function (pad "EN" →
/// fn "EN") is NOT suppressed.
fn isPositionalPin(pad_id: []const u8, fn_name: []const u8) bool {
    var pbuf: [32]u8 = undefined;
    var fbuf: [64]u8 = undefined;
    const np = normalizeIdent(pad_id, &pbuf);
    const nf = normalizeIdent(fn_name, &fbuf);
    if (np.len == 0) return false;
    // Doubled: "A01A01" == "A01" ++ "A01".
    if (nf.len == 2 * np.len and std.mem.eql(u8, nf[0..np.len], np) and std.mem.eql(u8, nf[np.len..], np)) return true;
    // Plain fn == pad, but only when the pad is grid-like.
    if (std.mem.eql(u8, nf, np) and isGridLikePad(np)) return true;
    return false;
}

/// Upper-cases `s` into `buf` with separators removed; returns the written slice.
fn normalizeIdent(s: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    for (s) |c| switch (c) {
        '_', '-', '/', '.', ' ', '#', '~', '{', '}', '(', ')' => {},
        else => {
            if (n >= buf.len) break;
            buf[n] = std.ascii.toUpper(c);
            n += 1;
        },
    };
    return buf[0..n];
}

/// True when `s` looks like a connector grid pad: a leading letter followed
/// somewhere by a digit (e.g. "A1", "B12", "AA3") — never a function word.
fn isGridLikePad(s: []const u8) bool {
    if (s.len == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s) |c| if (std.ascii.isDigit(c)) return true;
    return false;
}

/// True when `tok` is exactly `prefix` optionally followed by digits ("EN",
/// "EN1"), and nothing else — anchored so "ENABLE"/"ENC" don't match via "EN".
fn prefixThenDigits(tok: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, tok, prefix)) return false;
    for (tok[prefix.len..]) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

test "isTranslatorChannel rejects names shorter than 2 or longer than 16 chars" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var fn_set: std.StringHashMapUnmanaged(void) = .empty;
    try fn_set.put(arena, "B1", {});
    // A well-formed "A<n>" whose "B<n>" twin is present IS a translator channel.
    try testing.expect(isTranslatorChannel("A1", &fn_set));
    // Length guard: too short (1) and too long (17) must return false, not true.
    try testing.expect(!isTranslatorChannel("A", &fn_set));
    try testing.expect(!isTranslatorChannel("A0000000000000000", &fn_set));
}

// spec: placement/pin_roles - groundy function names are recognised, straps are not
test "isGroundFn separates real grounds from config straps" {
    try testing.expect(isGroundFn("GND"));
    try testing.expect(isGroundFn("GND_1"));
    try testing.expect(isGroundFn("gnd"));
    try testing.expect(isGroundFn("AGND"));
    try testing.expect(isGroundFn("VSSA"));
    try testing.expect(isGroundFn("EP"));
    try testing.expect(isGroundFn("PAD"));
    // Straps tied to GND must NOT read as ground.
    try testing.expect(!isGroundFn("ILIM"));
    try testing.expect(!isGroundFn("EN/UV"));
    try testing.expect(!isGroundFn("PGFB"));
    try testing.expect(!isGroundFn("MODE"));
    try testing.expect(!isGroundFn("IN_1"));
}

// spec: placement/pin_roles - supply function names are recognised, grounds and signals are not
test "isSupplyFn separates real supplies from grounds and signals" {
    try testing.expect(isSupplyFn("VCC"));
    try testing.expect(isSupplyFn("VDD"));
    try testing.expect(isSupplyFn("VDD_1"));
    try testing.expect(isSupplyFn("AVDD"));
    try testing.expect(isSupplyFn("VBAT"));
    try testing.expect(isSupplyFn("VIN"));
    try testing.expect(isSupplyFn("VREF_A"));
    try testing.expect(isSupplyFn("V+"));
    // Grounds must NOT read as supply (the "VS" exact form is a prefix of VSS).
    try testing.expect(!isSupplyFn("VSS"));
    try testing.expect(!isSupplyFn("VSSA"));
    try testing.expect(!isSupplyFn("GND"));
    // Passive-part signal pins are not supplies.
    try testing.expect(!isSupplyFn("RF-IN"));
    try testing.expect(!isSupplyFn("RF_OUT"));
    try testing.expect(!isSupplyFn("INPUT"));
    try testing.expect(!isSupplyFn("OUTPUT"));
    // A supply-*named* strap (a config pin tied to the rail) is NOT a real
    // supply pad — the enable/select token wins over the VDD/VIN prefix.
    try testing.expect(!isSupplyFn("VDD_EN"));
    try testing.expect(!isSupplyFn("VIN_SEL0"));
    try testing.expect(!isSupplyFn("VCC_MODE"));
    // …and such a name still reads as a strap (the interaction that matters).
    try testing.expect(isStrapFn("VDD_EN"));
    try testing.expect(isStrapFn("VIN_SEL0"));
    // A plain supply name with a trailing letter (VREF bank "A") is still a supply.
    try testing.expect(isSupplyFn("VREF_A"));
    try testing.expect(isSupplyFn("VDD_1"));
}

// spec: placement/pin_roles - electrical type overrides the name heuristic; signal types demote to strap
test "classify prefers electrical type, falls back to ground name" {
    // A pin declared input/output/io is a strap regardless of its name.
    try testing.expectEqual(PinClass.strap, classify(.input, "GND_1"));
    try testing.expectEqual(PinClass.strap, classify(.io, "VDD"));
    // power-in/out mark real supply pins.
    try testing.expectEqual(PinClass.power, classify(.power_in, "IN_1"));
    // passive/nc carry no signal → name decides.
    try testing.expectEqual(PinClass.ground, classify(.passive, "GND_2"));
    try testing.expectEqual(PinClass.other, classify(.nc, "ILIM"));
    // No decl → name decides.
    try testing.expectEqual(PinClass.ground, classify(null, "AGND"));
    try testing.expectEqual(PinClass.other, classify(null, "ILIM"));
}

// spec: placement/pin_roles - config-strap function names are recognised, supplies grounds and GPIO are not
test "isStrapFn recognises config straps but not supplies, grounds, or GPIO" {
    // Enable / control / mode / boot / current-limit / reset straps.
    try testing.expect(isStrapFn("EN"));
    try testing.expect(isStrapFn("~{CE}"));
    try testing.expect(isStrapFn("MODE"));
    try testing.expect(isStrapFn("ILIM"));
    try testing.expect(isStrapFn("BOOT0"));
    try testing.expect(isStrapFn("~{SHDN}"));
    try testing.expect(isStrapFn("NRST"));
    try testing.expect(isStrapFn("RESET_N"));
    // Device-address straps (single digit), including multi-function names where
    // one token is a strap.
    try testing.expect(isStrapFn("A0"));
    try testing.expect(isStrapFn("A2"));
    try testing.expect(isStrapFn("PRTPWR1/BC_EN1"));
    try testing.expect(isStrapFn("SCL/SMBCLK/CFG_SEL0"));
    // Two-digit "A" names are connector grids / parallel-bus lines, not straps.
    try testing.expect(!isStrapFn("A01"));
    try testing.expect(!isStrapFn("A20"));
    try testing.expect(!isStrapFn("A14"));
    // Real supply / ground pins are never straps.
    try testing.expect(!isStrapFn("VDD"));
    try testing.expect(!isStrapFn("GND"));
    try testing.expect(!isStrapFn("VIN"));
    // GPIO port names must NOT read as straps (P-prefixed) — this is the noise
    // that would otherwise flag every unused MCU pin tied to a rail.
    try testing.expect(!isStrapFn("PA1"));
    try testing.expect(!isStrapFn("PD15"));
    try testing.expect(!isStrapFn("PB0"));
    // Words that merely start with a strap token are not straps.
    try testing.expect(!isStrapFn("ENC"));
    try testing.expect(!isStrapFn("ADC"));
    try testing.expect(!isStrapFn("GREEN"));
}

// spec: placement/pin_roles - strapPads maps strap pads to their function name via name or electrical type
test "strapPads collects strap pads by name and by electrical type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // CTRL is a plain signal name, but the library marks it input → strap by
    // type; EN/A0 are straps by name; VDD/GND/OUT are not straps.
    const comp = "(component reg (pinout \"reg\") (electrical \"CTRL\" (type input)))";
    const pinout =
        \\(pinout "reg"
        \\  (pin 1 "VDD") (pin 2 "EN") (pin 3 "A0") (pin 4 "GND") (pin 5 "OUT") (pin 6 "CTRL"))
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/pinouts");
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/reg.sexp", .data = comp });
    try tmp.dir.writeFile(.{ .sub_path = "lib/pinouts/reg.sexp", .data = pinout });
    const path = try tmp.dir.realpathAlloc(arena, ".");

    const straps = strapPads(arena, path, "reg");
    try testing.expectEqual(@as(usize, 3), straps.count()); // pads 2, 3, 6
    try testing.expectEqualStrings("EN", straps.get("2").?);
    try testing.expectEqualStrings("A0", straps.get("3").?);
    try testing.expectEqualStrings("CTRL", straps.get("6").?); // by electrical type
    try testing.expect(straps.get("1") == null); // VDD
    try testing.expect(straps.get("4") == null); // GND
    try testing.expect(straps.get("5") == null); // OUT
}

// spec: placement/pin_roles - strapPads skips connector positional pins named after their pad
test "strapPads ignores connector positional pins" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A mezzanine connector whose pins are named after their grid position: the
    // doubled "A01_A01" form and a plain "B2"-on-pad-"B2" must NOT read as straps,
    // while a genuine "EN" function on a numbered pad still does.
    const comp = "(component conn (pinout \"conn\"))";
    const pinout =
        \\(pinout "conn"
        \\  (pin A01 "A01_A01") (pin A02 "A02_A02") (pin B2 "B2") (pin 7 "EN"))
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/pinouts");
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/conn.sexp", .data = comp });
    try tmp.dir.writeFile(.{ .sub_path = "lib/pinouts/conn.sexp", .data = pinout });
    const path = try tmp.dir.realpathAlloc(arena, ".");

    const straps = strapPads(arena, path, "conn");
    try testing.expectEqual(@as(usize, 1), straps.count()); // only the real EN
    try testing.expectEqualStrings("EN", straps.get("7").?);
    try testing.expect(straps.get("A01") == null); // doubled positional
    try testing.expect(straps.get("B2") == null); // plain positional, grid-like
}

// spec: placement/pin_roles - connectionRequirement tiers an unconnected pad by confidence
test "connectionRequirement tiers floating pads by confidence" {
    // Supply/ground defer to the power-pin presence check.
    try testing.expectEqual(NcRequirement.skip, connectionRequirement(null, "VDD"));
    try testing.expectEqual(NcRequirement.skip, connectionRequirement(null, "GND"));
    try testing.expectEqual(NcRequirement.skip, connectionRequirement(.power_in, "IN"));
    // A library-declared input must be driven → error tier.
    try testing.expectEqual(NcRequirement.required, connectionRequirement(.input, "CTRL"));
    // A config/enable/reset strap recognised by name → warning tier.
    try testing.expectEqual(NcRequirement.suspect, connectionRequirement(null, "EN"));
    try testing.expectEqual(NcRequirement.suspect, connectionRequirement(null, "BOOT0"));
    try testing.expectEqual(NcRequirement.suspect, connectionRequirement(null, "NRST"));
    try testing.expectEqual(NcRequirement.suspect, connectionRequirement(null, "A0"));
    // Outputs, GPIO/IO, passives are fine to leave open.
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(.output, "DOUT"));
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(.io, "PA3"));
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(.passive, "FILT"));
    // Datasheet no-connect / reserved names are meant to float.
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(.nc, "NC"));
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(null, "NC"));
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(null, "N/C"));
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(null, "NC3"));
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(null, "RESERVED"));
    // A plain GPIO / unknown signal name is silent (noise control).
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(null, "PD15"));
    try testing.expectEqual(NcRequirement.fine, connectionRequirement(null, "SOMESIG"));
}

// spec: placement/pin_roles - padRequirements keeps only the flaggable pads of a part
test "padRequirements maps only the pads worth flagging" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // VDD/GND are skip; EN/A0 are suspect; CTRL is required (electrical input);
    // DOUT/NC are fine. A8/B8 are a level-translator channel pair, so the "A8"
    // pad is demoted to fine (not an address strap) — only 3 flaggable pads.
    const comp = "(component reg (pinout \"reg\") (electrical \"CTRL\" (type input)))";
    const pinout =
        \\(pinout "reg"
        \\  (pin 1 "VDD") (pin 2 "EN") (pin 3 "A0") (pin 4 "GND")
        \\  (pin 5 "DOUT") (pin 6 "CTRL") (pin 7 "NC")
        \\  (pin 8 "A8") (pin 9 "B8"))
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/pinouts");
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/reg.sexp", .data = comp });
    try tmp.dir.writeFile(.{ .sub_path = "lib/pinouts/reg.sexp", .data = pinout });
    const path = try tmp.dir.realpathAlloc(arena, ".");

    const reqs = padRequirements(arena, path, "reg");
    try testing.expectEqual(@as(usize, 3), reqs.count()); // pads 2, 3, 6
    try testing.expectEqual(NcRequirement.suspect, reqs.get("2").?.req); // EN
    try testing.expectEqual(NcRequirement.suspect, reqs.get("3").?.req); // A0
    try testing.expectEqual(NcRequirement.required, reqs.get("6").?.req); // CTRL (input)
    try testing.expectEqualStrings("CTRL", reqs.get("6").?.fn_name);
    try testing.expect(reqs.get("1") == null); // VDD (skip)
    try testing.expect(reqs.get("4") == null); // GND (skip)
    try testing.expect(reqs.get("5") == null); // DOUT (fine)
    try testing.expect(reqs.get("7") == null); // NC (fine)
    try testing.expect(reqs.get("8") == null); // A8 — translator channel (B8 twin), not an address strap
    try testing.expect(reqs.get("3").?.req == .suspect); // A0 — address strap (no B0 twin) stays
}
