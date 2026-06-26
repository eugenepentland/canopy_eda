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

const Node = ast.Node;
const MAX_BYTES = 1024 * 256;

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
    const src = infra_fs.cwd().readFileAlloc(arena, path, MAX_BYTES) catch return null;
    const nodes = parser.parse(arena, src) catch return null;
    if (nodes.len == 0) return null;
    return nodes[0].asList();
}

/// Stringify a pad-id node exactly as the evaluator does (`ids.pinId`): a bare
/// integer becomes its decimal text ("5"), an atom/string passes through. This
/// keeps the map keys aligned with the flattened net's `pin` ids.
fn nodeText(arena: std.mem.Allocator, n: Node) ?[]const u8 {
    if (n.asText()) |t| return t;
    if (n.asNumber()) |num| return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(num))}) catch null;
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
    const prefixes = [_][]const u8{
        "VCC",  "VDD", "AVDD", "DVDD", "PVDD", "VBAT",
        "VBUS", "VIN", "VOUT", "VEE",  "VPP",  "VREF",
    };
    for (prefixes) |p| if (std.mem.startsWith(u8, s, p)) return true;
    const exact = [_][]const u8{ "V+", "VS" };
    for (exact) |e| if (std.mem.eql(u8, s, e)) return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

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
