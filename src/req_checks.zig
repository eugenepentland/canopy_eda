//! Executable counterparts to library `(requirement "..." (check ...))`
//! forms. Each primitive walks the live design to decide whether the rule
//! holds for a specific placement of the part, and returns a human-readable
//! pass/fail message the UI surfaces alongside the requirement text.
//!
//! Naming note: `checks.zig` is already taken for the ERC/DRC severity
//! types, so this file uses `req_checks` to avoid the collision.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const ids = @import("eval/ids.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Check = env_mod.Check;

pub const Status = enum { pass, fail, na };

pub const Result = struct {
    status: Status,
    message: []const u8 = "",
};

/// Run every `(check ...)` clause declared on every placed instance in the
/// design (and sub-blocks). Returns a map from ref_des → results, where
/// `results[i]` aligns to `inst.requirements[i]`. Requirements without a
/// check come back as `.na` so the UI can render a neutral marker.
pub fn runChecks(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
) !std.StringHashMapUnmanaged([]const Result) {
    var out: std.StringHashMapUnmanaged([]const Result) = .empty;
    try walkInstances(allocator, eval, block, &out);
    return out;
}

pub fn deinit(
    allocator: std.mem.Allocator,
    m: *std.StringHashMapUnmanaged([]const Result),
) void {
    var it = m.iterator();
    while (it.next()) |e| allocator.free(e.value_ptr.*);
    m.deinit(allocator);
}

fn walkInstances(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    out: *std.StringHashMapUnmanaged([]const Result),
) !void {
    for (block.instances) |inst| {
        if (inst.requirements.len == 0) continue;
        const results = try allocator.alloc(Result, inst.requirements.len);
        for (inst.requirements, 0..) |r, i| {
            if (r.check) |chk| {
                // Checks resolve against the instance's *containing* block —
                // sub-block nets are local to the sub-block, not the outer
                // design, so we thread the right block through.
                results[i] = evalCheck(allocator, eval, block, inst, chk);
            } else {
                results[i] = .{ .status = .na };
            }
        }
        try out.put(allocator, inst.ref_des, results);
    }
    for (block.sub_blocks) |sb| try walkInstances(allocator, eval, sb.block, out);
}

fn evalCheck(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    chk: Check,
) Result {
    return switch (chk) {
        .connected => |c| evalConnected(allocator, eval, block, inst, c.pin_a, c.pin_b),
        .decoupling => |c| evalDecoupling(allocator, eval, block, inst, c.pin_a, c.pin_b, c.min_uf),
        .pullup_range => |c| evalPullupRange(allocator, eval, block, inst, c.pin, c.target_net, c.min_ohms, c.max_ohms),
        .voltage_range => |c| evalVoltageRange(allocator, eval, block, inst, c.pin, c.min_v, c.max_v),
    };
}

// ── Primitives ────────────────────────────────────────────────────────────

fn evalConnected(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin_a: []const u8,
    pin_b: []const u8,
) Result {
    const net_a = netForPinFn(eval, block, inst, pin_a) orelse
        return fail(allocator, "pin '{s}' not found in pinout", .{pin_a});
    const net_b = netForPinFn(eval, block, inst, pin_b) orelse
        return fail(allocator, "pin '{s}' not found in pinout", .{pin_b});
    if (std.mem.eql(u8, net_a, net_b)) return passMsg(allocator, "'{s}' and '{s}' both on {s}", .{ pin_a, pin_b, net_a });
    return fail(allocator, "'{s}' on {s}, '{s}' on {s} — must be the same net", .{ pin_a, net_a, pin_b, net_b });
}

fn evalDecoupling(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin_a: []const u8,
    pin_b: []const u8,
    min_uf: f64,
) Result {
    const net_a = netForPinFn(eval, block, inst, pin_a) orelse
        return fail(allocator, "pin '{s}' not found in pinout", .{pin_a});
    const net_b = netForPinFn(eval, block, inst, pin_b) orelse
        return fail(allocator, "pin '{s}' not found in pinout", .{pin_b});
    if (std.mem.eql(u8, net_a, net_b)) {
        return fail(allocator, "pins '{s}' and '{s}' are on the same net ({s}) — nothing to decouple", .{ pin_a, pin_b, net_a });
    }

    var best_uf: f64 = 0;
    var best_ref: []const u8 = "";
    collectCapsBetween(block, net_a, net_b, &best_uf, &best_ref);
    if (best_uf == 0) {
        return fail(allocator, "no capacitor between {s} and {s}; need ≥{d:.3} µF", .{ net_a, net_b, min_uf });
    }
    if (best_uf + 1e-9 < min_uf) {
        return fail(allocator, "largest cap {s} = {d:.3} µF on {s}↔{s}; need ≥{d:.3} µF", .{ best_ref, best_uf, net_a, net_b, min_uf });
    }
    return passMsg(allocator, "{s} ({d:.3} µF) bridges {s}↔{s}", .{ best_ref, best_uf, net_a, net_b });
}

fn evalPullupRange(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin: []const u8,
    target_net: []const u8,
    min_ohms: f64,
    max_ohms: f64,
) Result {
    const pin_net = netForPinFn(eval, block, inst, pin) orelse
        return fail(allocator, "pin '{s}' not found in pinout", .{pin});

    var matched_ref: []const u8 = "";
    var matched_ohms: f64 = 0;
    var any_bridge = false;
    var matched_value: []const u8 = "";
    for (block.instances) |c| {
        if (c.ref_des.len == 0 or c.ref_des[0] != 'R') continue;
        if (!instancePinOnNet(block, c, pin_net)) continue;
        if (!instancePinOnNet(block, c, target_net)) continue;
        any_bridge = true;
        const ohms = parseOhms(c.value) orelse continue;
        if (ohms >= min_ohms and ohms <= max_ohms) {
            matched_ref = c.ref_des;
            matched_ohms = ohms;
            matched_value = c.value;
            break;
        }
    }
    if (matched_ref.len > 0) {
        return passMsg(allocator, "{s} = {s} ({d:.0} Ω) within [{d:.0}, {d:.0}] Ω", .{ matched_ref, matched_value, matched_ohms, min_ohms, max_ohms });
    }
    if (any_bridge) {
        return fail(allocator, "resistor(s) between {s} and {s} are outside [{d:.0}, {d:.0}] Ω", .{ pin_net, target_net, min_ohms, max_ohms });
    }
    return fail(allocator, "no resistor between {s} and {s}; need a value in [{d:.0}, {d:.0}] Ω", .{ pin_net, target_net, min_ohms, max_ohms });
}

fn evalVoltageRange(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin: []const u8,
    min_v: f64,
    max_v: f64,
) Result {
    const net = netForPinFn(eval, block, inst, pin) orelse
        return fail(allocator, "pin '{s}' could not be resolved to a net", .{pin});

    for (block.ports) |p| {
        if (!std.mem.eql(u8, p.net, net)) continue;
        if (p.nominal) |v| {
            if (v + 1e-9 < min_v or v > max_v + 1e-9) {
                return fail(allocator, "port {s} nominal = {d:.3} V, outside [{d:.3}, {d:.3}] V", .{ p.name, v, min_v, max_v });
            }
            return passMsg(allocator, "port {s} nominal = {d:.3} V ∈ [{d:.3}, {d:.3}] V", .{ p.name, v, min_v, max_v });
        }
        if (p.rated_min) |lo| if (p.rated_max) |hi| {
            if (lo + 1e-9 < min_v or hi > max_v + 1e-9) {
                return fail(allocator, "port {s} rated [{d:.3}, {d:.3}] V, outside envelope [{d:.3}, {d:.3}] V", .{ p.name, lo, hi, min_v, max_v });
            }
            return passMsg(allocator, "port {s} rated [{d:.3}, {d:.3}] V ⊆ [{d:.3}, {d:.3}] V", .{ p.name, lo, hi, min_v, max_v });
        };
        return fail(allocator, "port {s} on net {s} has no declared voltage — add (rated …) or a nominal", .{ p.name, net });
    }
    return fail(allocator, "no `(port …)` declared on net {s} — can't verify voltage", .{net});
}

// ── Helpers ──────────────────────────────────────────────────────────────

fn netForPinFn(
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin_fn: []const u8,
) ?[]const u8 {
    const pinout_key = if (inst.pinout.len > 0) inst.pinout else inst.symbol;
    if (pinout_key.len == 0) return null;
    const sym_pins = ids.getSymbolPins(eval, pinout_key) orelse return null;

    var it = sym_pins.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.value_ptr.*, pin_fn)) {
            if (netForPhysicalPin(block, inst.ref_des, e.key_ptr.*)) |n| return n;
        }
    }
    return null;
}

fn netForPhysicalPin(block: *const DesignBlock, ref_des: []const u8, pin_id: []const u8) ?[]const u8 {
    for (block.nets) |net| {
        for (net.pins) |pr| {
            if (std.mem.eql(u8, pr.ref_des, ref_des) and std.mem.eql(u8, pr.pin, pin_id)) {
                return net.name;
            }
        }
    }
    return null;
}

fn instancePinOnNet(block: *const DesignBlock, inst: Instance, net_name: []const u8) bool {
    for (block.nets) |net| {
        if (!netsAlias(net.name, net_name)) continue;
        for (net.pins) |pr| if (std.mem.eql(u8, pr.ref_des, inst.ref_des)) return true;
    }
    return false;
}

/// Two net names are the "same electrical net" if one equals the other or
/// one is a per-pin stub alias of the other. The evaluator emits stubs
/// named `NET.REFDES.PINFN` for each pin of a declared net, which keeps
/// the schematic renderer's per-pin labels clean but splits the logical
/// net into N+1 entries in `block.nets`. Treating those as equivalent
/// here means a decoupling cap stitched to `VBUS.U11.VDD_1` counts as
/// bridging `VBUS` for the purposes of a "cap between VDD and VSS" rule.
fn netsAlias(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    return std.mem.eql(u8, netBase(a), netBase(b));
}

fn netBase(name: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[0..idx];
}

fn collectCapsBetween(
    block: *const DesignBlock,
    net_a: []const u8,
    net_b: []const u8,
    best_uf: *f64,
    best_ref: *[]const u8,
) void {
    for (block.instances) |c| {
        if (c.ref_des.len == 0 or c.ref_des[0] != 'C') continue;
        if (!instancePinOnNet(block, c, net_a)) continue;
        if (!instancePinOnNet(block, c, net_b)) continue;
        const uf = parseMicroFarads(c.value) orelse continue;
        if (uf > best_uf.*) {
            best_uf.* = uf;
            best_ref.* = c.ref_des;
        }
    }
}

/// Parse "4.7uF" / "100nF" / "220pF" / "10µF" → µF. Returns null on
/// unrecognized input so an un-parsed value just counts as "not a qualifying
/// cap" rather than wedging the whole check.
pub fn parseMicroFarads(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    while (i < s.len and (isDigit(s[i]) or s[i] == '.')) : (i += 1) {}
    if (i == 0) return null;
    const num = std.fmt.parseFloat(f64, s[0..i]) catch return null;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len) return null;
    const scale = suffixToMicroFarads(s[i..]) orelse return null;
    return num * scale;
}

/// Parse "10k" / "220" / "4.7M" / "2k2" → Ω. "2k2" shorthand isn't
/// supported; accepts `<number><optional SI><optional Ω/ohm>`.
pub fn parseOhms(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    while (i < s.len and (isDigit(s[i]) or s[i] == '.')) : (i += 1) {}
    if (i == 0) return null;
    const num = std.fmt.parseFloat(f64, s[0..i]) catch return null;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len) return num;
    return num * suffixToOhms(s[i..]);
}

fn suffixToMicroFarads(s: []const u8) ?f64 {
    if (ieql(s, "pF") or ieql(s, "p")) return 1e-6;
    if (ieql(s, "nF") or ieql(s, "n")) return 1e-3;
    if (ieql(s, "uF") or ieql(s, "u") or std.mem.startsWith(u8, s, "µ")) return 1.0;
    if (ieql(s, "mF") or ieql(s, "m")) return 1e3;
    if (ieql(s, "F")) return 1e6;
    return null;
}

fn suffixToOhms(s: []const u8) f64 {
    if (ieql(s, "k") or ieql(s, "kΩ") or ieql(s, "kohm")) return 1e3;
    if (ieql(s, "M") or ieql(s, "MΩ")) return 1e6;
    if (ieql(s, "G") or ieql(s, "GΩ")) return 1e9;
    return 1.0;
}

fn ieql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn fail(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "";
    return .{ .status = .fail, .message = msg };
}

fn passMsg(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "";
    return .{ .status = .pass, .message = msg };
}

// spec: req_checks - parseMicroFarads handles SI-suffixed cap values
test "parseMicroFarads" {
    try std.testing.expectApproxEqAbs(@as(f64, 4.7), parseMicroFarads("4.7uF").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), parseMicroFarads("100nF").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0001), parseMicroFarads("100pF").?, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 10.0), parseMicroFarads("10µF").?, 1e-9);
    try std.testing.expect(parseMicroFarads("garbage") == null);
}

// spec: req_checks - parseOhms handles SI prefixes for resistor values
test "parseOhms" {
    try std.testing.expectApproxEqAbs(@as(f64, 10000), parseOhms("10k").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 2200), parseOhms("2.2k").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 470), parseOhms("470").?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1000000), parseOhms("1M").?, 1e-6);
}
