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

// ── Constants ─────────────────────────────────────────────────────
const CURRENT_TOLERANCE_F: f64 = 1e-9;
const VALUE_TOLERANCE_PF: f64 = 1e-12;
const DC_EQUIV_RESISTOR_OHMS: f64 = 10.0;
const PIN_NOT_FOUND_MSG = "pin '{s}' not found in pinout";

/// Outcome of evaluating one component requirement: `pass` / `fail` for
/// automated checks, `na` when no check primitive ran, and `verified` once
/// `applyVerifications` overlays a matching design-side `(verifies …)` form.
pub const Status = enum { pass, fail, na, verified };

/// One requirement-check outcome: a `Status`, a human `message` the review
/// UI displays under the requirement text, and an optional `Verification`
/// when a `(verifies …)` form has signed off the rule for this part.
pub const Result = struct {
    status: Status,
    message: []const u8 = "",
    /// When a `(verifies …)` form in the design targets the same
    /// `(ref_des, req_id)` as this check, the verification is attached here
    /// so the UI can show the rationale alongside the automated result.
    /// - For `na` results, `applyVerifications` flips `status` to `verified`
    ///   and stores the rationale here.
    /// - For `fail` results, `status` stays `fail` and the verification is
    ///   attached as a side-channel so the UI can render an "overridden"
    ///   badge with the rationale visible.
    /// - For `pass` results, this is left null even if a verification matches.
    verification: ?env_mod.Verification = null,
};

/// Post-process a results map by overlaying any matching `(verifies …)` forms
/// from the design block. Mutates the map in place. Should be called once
/// after `runChecks`.
///
/// `(verifies (req "REFDES" id) …)` resolves against any instance reachable
/// from the design (top-level instances and every nested sub-block), so a
/// design can sign off a requirement on a part inside a power-supply module
/// without the module file having to know it. The target may instead be a
/// stable instance id — `(verifies (req (id <hex>) id) …)` — which matches on
/// `Instance.id` so the sign-off survives ref-des renumbering and renames.
///
/// Resolution rules (see Verification doc-comment):
///   na + match → verified, rationale attached
///   fail + match → fail, rationale attached for the "overridden" UI badge
///   pass + match → unchanged (no point showing a sign-off for a passing check)
pub fn applyVerifications(
    map: *std.StringHashMapUnmanaged([]Result),
    block: *const DesignBlock,
    instances: []const Instance,
) void {
    _ = instances;
    for (block.verifications) |v| applyOneVerification(map, block, v);
}

fn applyOneVerification(
    map: *std.StringHashMapUnmanaged([]Result),
    block: *const DesignBlock,
    v: env_mod.Verification,
) void {
    // Try this block's own instances first, then recurse into sub-blocks.
    // A verifies form addresses its target either by stable instance id
    // (`(req (id …) …)`, renumber-proof) or by ref-des (`(req "U6" …)`).
    for (block.instances) |inst| {
        const matched = if (v.target_id.len > 0)
            std.mem.eql(u8, inst.id, v.target_id)
        else
            std.mem.eql(u8, inst.ref_des, v.ref_des);
        if (!matched) continue;
        var req_idx: ?usize = null;
        for (inst.requirements, 0..) |r, ri| {
            if (std.mem.eql(u8, r.id, v.req_id)) {
                req_idx = ri;
                break;
            }
        }
        const ri = req_idx orelse return;
        const results = map.get(inst.ref_des) orelse return;
        if (ri >= results.len) return;
        switch (results[ri].status) {
            .na => {
                results[ri].status = .verified;
                results[ri].verification = v;
            },
            .fail => {
                // Keep fail, attach rationale for the overridden-badge UI.
                results[ri].verification = v;
            },
            .pass, .verified => {},
        }
        return;
    }
    for (block.sub_blocks) |sb| applyOneVerification(map, sb.block, v);
}

/// Run every `(check ...)` clause declared on every placed instance in the
/// design (and sub-blocks). Returns a map from ref_des → results, where
/// `results[i]` aligns to `inst.requirements[i]`. Requirements without a
/// check come back as `.na` so the UI can render a neutral marker.
///
/// Result slices are mutable so callers can call `applyVerifications` to
/// overlay design-side `(verifies …)` sign-offs.
pub fn runChecks(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged([]Result) {
    var out: std.StringHashMapUnmanaged([]Result) = .empty;
    try walkInstances(allocator, eval, block, &out);
    return out;
}

/// Free the per-ref-des `Result` slices owned by a `runChecks` map and the
/// map's own backing storage. Call once after the review render is done
/// to release every requirement-check allocation in one pass.
pub fn deinit(
    allocator: std.mem.Allocator,
    m: *std.StringHashMapUnmanaged([]Result),
) void {
    var it = m.iterator();
    while (it.next()) |e| allocator.free(e.value_ptr.*);
    m.deinit(allocator);
}

fn walkInstances(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    out: *std.StringHashMapUnmanaged([]Result),
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
        .tied_to_net => |c| evalTiedToNet(allocator, eval, block, inst, c.pin, c.target_net),
        .not_connected => |c| evalNotConnected(allocator, eval, block, inst, c.pin),
        .pin_not_floating => |c| evalPinNotFloating(allocator, eval, block, inst, c.pin),
        .pins_on_same_net => |c| evalPinsOnSameNet(allocator, eval, block, inst, c.pins),
        .decoupling_per_pin => |c| evalDecouplingPerPin(allocator, eval, block, inst, c.return_pin, c.pins, c.min_uf, c.count),
        .series_element => |c| evalSeriesElement(allocator, eval, block, inst, c.kind, c.pin, c.target_net, c.min, c.max),
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
        return fail(allocator, PIN_NOT_FOUND_MSG, .{pin_a});
    const net_b = netForPinFn(eval, block, inst, pin_b) orelse
        return fail(allocator, PIN_NOT_FOUND_MSG, .{pin_b});
    // Use netsAlias so per-pin stubs (NET.REFDES.PIN) collapse to the base net.
    if (netsAlias(net_a, net_b)) return passMsg(allocator, "'{s}' and '{s}' both on {s}", .{ pin_a, pin_b, netBase(net_a) });
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
        return fail(allocator, PIN_NOT_FOUND_MSG, .{pin_a});
    const net_b = netForPinFn(eval, block, inst, pin_b) orelse
        return fail(allocator, PIN_NOT_FOUND_MSG, .{pin_b});
    if (std.mem.eql(u8, net_a, net_b)) {
        return fail(allocator, "pins '{s}' and '{s}' are on the same net ({s}) — nothing to decouple", .{ pin_a, pin_b, net_a });
    }

    var best_uf: f64 = 0;
    var best_ref: []const u8 = "";
    collectCapsBetween(block, net_a, net_b, &best_uf, &best_ref);
    if (best_uf == 0) {
        return fail(allocator, "no capacitor between {s} and {s}; need ≥{d:.3} µF", .{ net_a, net_b, min_uf });
    }
    if (best_uf + CURRENT_TOLERANCE_F < min_uf) {
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
        return fail(allocator, PIN_NOT_FOUND_MSG, .{pin});

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

/// Voltage info plumbed back from `findVoltageForNet`. `label` describes
/// where the voltage was sourced (e.g. `"section port V1P8"` or
/// `"V1P8 via FB1 ferrite"`).
const VoltageInfo = struct {
    label: []const u8,
    nominal: ?f64 = null,
    rated_min: ?f64 = null,
    rated_max: ?f64 = null,
};

/// Find a declared voltage for the named net, walking through top-level
/// ports → section ports → sub-block ports → DC-equivalent series
/// elements. Returns null when no voltage source is reachable. `visited`
/// caps cycles; `depth` caps recursion (4 hops is enough for any sane
/// power-distribution chain).
fn findVoltageForNet(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    net: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
    depth: u8,
) ?VoltageInfo {
    if (depth > 4) return null;
    const base = netBase(net);
    if (visited.contains(base)) return null;
    visited.put(allocator, base, {}) catch return null;

    // 1. Top-level ports.
    for (block.ports) |p| {
        if (!netsAlias(p.net, net)) continue;
        if (p.nominal != null or p.rated_min != null) {
            const lbl = std.fmt.allocPrint(allocator, "port {s}", .{p.name}) catch p.name;
            return .{ .label = lbl, .nominal = p.nominal, .rated_min = p.rated_min, .rated_max = p.rated_max };
        }
    }

    // 2. Section ports (and nested sub-section ports).
    for (block.sections) |sec| {
        for (sec.ports) |sp| {
            if (sp.voltage == null) continue;
            if (!std.mem.eql(u8, sp.name, base)) continue;
            const lbl = std.fmt.allocPrint(allocator, "section port {s}", .{sp.name}) catch sp.name;
            return .{ .label = lbl, .nominal = sp.voltage };
        }
        for (sec.sub_sections) |sub| {
            for (sub.ports) |sp| {
                if (sp.voltage == null) continue;
                if (!std.mem.eql(u8, sp.name, base)) continue;
                const lbl = std.fmt.allocPrint(allocator, "section port {s}", .{sp.name}) catch sp.name;
                return .{ .label = lbl, .nominal = sp.voltage };
            }
        }
    }

    // 3. Sub-block output ports, mapped through net-ties back to parent net.
    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |p| {
            const sb_qualified = std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, p.name }) catch continue;
            var matched = false;
            for (block.net_ties) |nt| {
                if (std.mem.eql(u8, nt.b, sb_qualified) and netsAlias(nt.a, net)) {
                    matched = true;
                    break;
                }
                if (std.mem.eql(u8, nt.a, sb_qualified) and netsAlias(nt.b, net)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) continue;
            if (p.nominal != null or p.rated_min != null) {
                const lbl = std.fmt.allocPrint(allocator, "sub-block {s} port {s}", .{ sb.name, p.name }) catch p.name;
                return .{ .label = lbl, .nominal = p.nominal, .rated_min = p.rated_min, .rated_max = p.rated_max };
            }
        }
    }

    // 4. Walk through DC-equivalent series elements (ferrite beads,
    // inductors, small-value resistors) to find an upstream port. Caps
    // and diodes are skipped — they aren't DC-transparent.
    for (block.instances) |c| {
        if (c.ref_des.len == 0) continue;
        const prefix = c.ref_des[0];
        if (prefix != 'R' and prefix != 'L' and prefix != 'F') continue;

        // Find this part's two distinct nets.
        var net_a: ?[]const u8 = null;
        var net_b: ?[]const u8 = null;
        for (block.nets) |n| {
            var has_pin = false;
            for (n.pins) |pr| {
                if (std.mem.eql(u8, pr.ref_des, c.ref_des)) {
                    has_pin = true;
                    break;
                }
            }
            if (!has_pin) continue;
            if (net_a == null) {
                net_a = n.name;
            } else if (net_b == null and !netsAlias(n.name, net_a.?)) {
                net_b = n.name;
            }
        }
        if (net_a == null or net_b == null) continue;

        const a_match = netsAlias(net_a.?, net);
        const b_match = netsAlias(net_b.?, net);
        if (!a_match and !b_match) continue;

        // DC-equivalence test. Ferrites and inductors are DC shorts;
        // resistors only count if the value is small (≤10Ω) since most
        // pull-up/down/series-damping resistors are kΩ-range and would
        // cause significant DC drop under load.
        const is_dc_equiv = switch (prefix) {
            'F', 'L' => true,
            'R' => blk: {
                const ohms = parseOhms(c.value) orelse break :blk false;
                break :blk ohms <= DC_EQUIV_RESISTOR_OHMS;
            },
            else => false,
        };
        if (!is_dc_equiv) continue;

        const other = if (a_match) net_b.? else net_a.?;
        if (findVoltageForNet(allocator, block, other, visited, depth + 1)) |vi| {
            const lbl = std.fmt.allocPrint(allocator, "{s} via {s}", .{ vi.label, c.ref_des }) catch vi.label;
            return .{ .label = lbl, .nominal = vi.nominal, .rated_min = vi.rated_min, .rated_max = vi.rated_max };
        }
    }

    return null;
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

    var visited: std.StringHashMapUnmanaged(void) = .empty;
    const vi = findVoltageForNet(allocator, block, net, &visited, 0) orelse
        return fail(allocator, "no `(port …)` declared on net {s} — can't verify voltage", .{net});

    if (vi.nominal) |v| {
        if (v + CURRENT_TOLERANCE_F < min_v or v > max_v + CURRENT_TOLERANCE_F) {
            return fail(allocator, "{s} nominal = {d:.3} V, outside [{d:.3}, {d:.3}] V", .{ vi.label, v, min_v, max_v });
        }
        return passMsg(allocator, "{s} = {d:.3} V ∈ [{d:.3}, {d:.3}] V", .{ vi.label, v, min_v, max_v });
    }
    if (vi.rated_min) |lo| if (vi.rated_max) |hi| {
        if (lo + CURRENT_TOLERANCE_F < min_v or hi > max_v + CURRENT_TOLERANCE_F) {
            return fail(allocator, "{s} rated [{d:.3}, {d:.3}] V, outside [{d:.3}, {d:.3}] V", .{ vi.label, lo, hi, min_v, max_v });
        }
        return passMsg(allocator, "{s} rated [{d:.3}, {d:.3}] V ⊆ [{d:.3}, {d:.3}] V", .{ vi.label, lo, hi, min_v, max_v });
    };
    return fail(allocator, "{s} has no declared voltage — add (rated …) or a nominal", .{vi.label});
}

fn evalTiedToNet(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin: []const u8,
    target_net: []const u8,
) Result {
    const net = netForPinFn(eval, block, inst, pin) orelse
        return fail(allocator, PIN_NOT_FOUND_MSG, .{pin});
    if (netsAlias(net, target_net)) {
        return passMsg(allocator, "pin '{s}' on {s} (matches {s})", .{ pin, net, target_net });
    }
    return fail(allocator, "pin '{s}' on {s}, expected {s}", .{ pin, net, target_net });
}

fn evalNotConnected(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin: []const u8,
) Result {
    // Look up the physical pin id for this function name.
    const pinout_key = if (inst.pinout.len > 0) inst.pinout else inst.symbol;
    if (pinout_key.len == 0) return fail(allocator, "instance has no pinout — can't resolve pin '{s}'", .{pin});
    const sym_pins = ids.getSymbolPins(eval, pinout_key) orelse
        return fail(allocator, "pinout '{s}' not loaded", .{pinout_key});

    var phys_pin: ?[]const u8 = null;
    var it = sym_pins.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.value_ptr.*, pin)) {
            phys_pin = e.key_ptr.*;
            break;
        }
    }
    const phys = phys_pin orelse
        return fail(allocator, "pin '{s}' not found in pinout '{s}'", .{ pin, pinout_key });

    // A "connected" pin is one that appears in any net with at least one OTHER pin.
    // Per-pin stub nets (NET.REFDES.PIN) with only this pin count as disconnected.
    for (block.nets) |net| {
        for (net.pins) |pr| {
            if (!std.mem.eql(u8, pr.ref_des, inst.ref_des)) continue;
            if (!std.mem.eql(u8, pr.pin, phys)) continue;
            // Found this physical pin on a net. If the net has co-pins, it's connected.
            if (net.pins.len > 1) {
                return fail(allocator, "pin '{s}' is connected to {s} (must be left floating per datasheet)", .{ pin, net.name });
            }
        }
    }
    return passMsg(allocator, "pin '{s}' is unconnected as required", .{pin});
}

fn evalPinNotFloating(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin: []const u8,
) Result {
    const pinout_key = if (inst.pinout.len > 0) inst.pinout else inst.symbol;
    if (pinout_key.len == 0) return fail(allocator, "instance has no pinout — can't resolve pin '{s}'", .{pin});
    const sym_pins = ids.getSymbolPins(eval, pinout_key) orelse
        return fail(allocator, "pinout '{s}' not loaded", .{pinout_key});

    var phys_pin: ?[]const u8 = null;
    var it = sym_pins.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.value_ptr.*, pin)) {
            phys_pin = e.key_ptr.*;
            break;
        }
    }
    const phys = phys_pin orelse
        return fail(allocator, "pin '{s}' not found in pinout '{s}'", .{ pin, pinout_key });

    for (block.nets) |net| {
        for (net.pins) |pr| {
            if (!std.mem.eql(u8, pr.ref_des, inst.ref_des)) continue;
            if (!std.mem.eql(u8, pr.pin, phys)) continue;
            if (net.pins.len > 1) {
                return passMsg(allocator, "pin '{s}' tied to {s}", .{ pin, net.name });
            }
            // Single-pin net: check whether the net is exposed as a block
            // port. Sub-block input ports (e.g. an LDO's EN) get only one
            // pin inside the sub-block, but the parent design wires them
            // externally via net-ties — this still counts as "not floating".
            for (block.ports) |p| {
                if (netsAlias(p.net, net.name) or std.mem.eql(u8, p.name, netBase(net.name))) {
                    return passMsg(allocator, "pin '{s}' on net {s} (exposed as block port {s})", .{ pin, net.name, p.name });
                }
            }
        }
    }
    return fail(allocator, "pin '{s}' is floating — must be tied to a defined level", .{pin});
}

fn evalPinsOnSameNet(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pins: []const []const u8,
) Result {
    if (pins.len < 2) return passMsg(allocator, "trivially satisfied (only {d} pin)", .{pins.len});
    const first = netForPinFn(eval, block, inst, pins[0]) orelse
        return fail(allocator, PIN_NOT_FOUND_MSG, .{pins[0]});
    for (pins[1..]) |pin_name| {
        const n = netForPinFn(eval, block, inst, pin_name) orelse
            return fail(allocator, PIN_NOT_FOUND_MSG, .{pin_name});
        if (!netsAlias(first, n)) {
            return fail(allocator, "pin '{s}' on {s}, '{s}' on {s} — must be the same net", .{ pins[0], first, pin_name, n });
        }
    }
    return passMsg(allocator, "all {d} pins on {s}", .{ pins.len, first });
}

fn evalDecouplingPerPin(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    return_pin: []const u8,
    pins: []const []const u8,
    min_uf: f64,
    count: u32,
) Result {
    const ret_net = netForPinFn(eval, block, inst, return_pin) orelse
        return fail(allocator, "return pin '{s}' not found in pinout", .{return_pin});

    var matched: u32 = 0;
    var first_unmatched: []const u8 = "";
    for (pins) |pin_name| {
        const pin_net = netForPinFn(eval, block, inst, pin_name) orelse {
            if (first_unmatched.len == 0) first_unmatched = pin_name;
            continue;
        };
        if (std.mem.eql(u8, pin_net, ret_net)) continue;

        var best_uf: f64 = 0;
        var best_ref: []const u8 = "";
        collectCapsBetween(block, pin_net, ret_net, &best_uf, &best_ref);
        if (best_uf + CURRENT_TOLERANCE_F >= min_uf) {
            matched += 1;
        } else if (first_unmatched.len == 0) {
            first_unmatched = pin_name;
        }
    }

    if (matched >= count) {
        return passMsg(allocator, "{d}/{d} pins have ≥{d:.3} µF cap to {s}", .{ matched, pins.len, min_uf, ret_net });
    }
    if (first_unmatched.len > 0) {
        return fail(
            allocator,
            "only {d}/{d} pins decoupled (need {d}); " ++
                "first missing: '{s}' (need ≥{d:.3} µF to {s})",
            .{ matched, pins.len, count, first_unmatched, min_uf, ret_net },
        );
    }
    return fail(allocator, "only {d}/{d} pins decoupled (need {d})", .{ matched, pins.len, count });
}

fn evalSeriesElement(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    kind: env_mod.SeriesKind,
    pin: []const u8,
    target_net: []const u8,
    min: f64,
    max: f64,
) Result {
    const pin_net = netForPinFn(eval, block, inst, pin) orelse
        return fail(allocator, PIN_NOT_FOUND_MSG, .{pin});

    const prefix: u8 = switch (kind) {
        .R => 'R',
        .L => 'L',
        .C => 'C',
    };
    const unit_label: []const u8 = switch (kind) {
        .R => "Ω",
        .L => "µH",
        .C => "µF",
    };

    var matched_ref: []const u8 = "";
    var matched_value: []const u8 = "";
    var matched_v: f64 = 0;
    var any_bridge = false;
    for (block.instances) |c| {
        if (c.ref_des.len == 0 or c.ref_des[0] != prefix) continue;
        if (!instancePinOnNet(block, c, pin_net)) continue;
        if (!instancePinOnNet(block, c, target_net)) continue;
        any_bridge = true;
        const v = parseValueFor(kind, c.value) orelse continue;
        if (v + VALUE_TOLERANCE_PF >= min and v <= max + VALUE_TOLERANCE_PF) {
            matched_ref = c.ref_des;
            matched_v = v;
            matched_value = c.value;
            break;
        }
    }
    if (matched_ref.len > 0) {
        return passMsg(
            allocator,
            "{s} = {s} ({d:.3} {s}) within [{d:.3}, {d:.3}] {s}",
            .{ matched_ref, matched_value, matched_v, unit_label, min, max, unit_label },
        );
    }
    if (any_bridge) {
        return fail(allocator, "{c}-element(s) between {s} and {s} are outside [{d:.3}, {d:.3}] {s}", .{ prefix, pin_net, target_net, min, max, unit_label });
    }
    return fail(allocator, "no {c} between {s} and {s}; need a value in [{d:.3}, {d:.3}] {s}", .{ prefix, pin_net, target_net, min, max, unit_label });
}

fn parseValueFor(kind: env_mod.SeriesKind, s: []const u8) ?f64 {
    return switch (kind) {
        .R => parseOhms(s),
        .L => parseMicroHenries(s),
        .C => parseMicroFarads(s),
    };
}

/// Parse "1uH" / "10uH" / "100nH" / "2.2µH" → µH. Same shape as `parseMicroFarads`.
pub fn parseMicroHenries(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    while (i < s.len and (isDigit(s[i]) or s[i] == '.')) : (i += 1) {}
    if (i == 0) return null;
    const num = std.fmt.parseFloat(f64, s[0..i]) catch return null;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len) return null;
    const scale = suffixToMicroHenries(s[i..]) orelse return null;
    return num * scale;
}

fn suffixToMicroHenries(s: []const u8) ?f64 {
    if (ieql(s, "pH") or ieql(s, "p")) return 1e-6;
    if (ieql(s, "nH") or ieql(s, "n")) return 1e-3;
    if (ieql(s, "uH") or ieql(s, "u") or std.mem.startsWith(u8, s, "µ")) return 1.0;
    if (ieql(s, "mH") or ieql(s, "m")) return 1e3;
    if (ieql(s, "H")) return 1e6;
    return null;
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

    // Primary: match against pin function name (e.g. "VDD", "VSSAON").
    var it = sym_pins.iterator();
    while (it.next()) |e| {
        if (std.ascii.eqlIgnoreCase(e.value_ptr.*, pin_fn)) {
            if (netForPhysicalPin(block, inst.ref_des, e.key_ptr.*)) |n| return n;
        }
    }
    // Fallback: physical pin id (e.g. "17", "A1"). Lets requirements name
    // a specific pin even when its pinout function is generic ("GND"/"VSS")
    // and the part has many such pins.
    if (netForPhysicalPin(block, inst.ref_des, pin_fn)) |n| return n;
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

// spec: req_checks - parseMicroHenries handles SI-suffixed inductor values
test "parseMicroHenries" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), parseMicroHenries("1uH").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2.2), parseMicroHenries("2.2µH").?, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), parseMicroHenries("100nH").?, 1e-9);
    try std.testing.expect(parseMicroHenries("garbage") == null);
}

// Build a one-instance design + a single-requirement results map for the
// verifies-matching tests below. The instance carries ref-des "U6" and stable
// id "b894897b"; its lone requirement has id "r1" and starts out `na`.
fn verifyFixture(
    a: std.mem.Allocator,
    verifs: []const env_mod.Verification,
) !struct { block: DesignBlock, results: []Result, map: std.StringHashMapUnmanaged([]Result) } {
    const reqs = try a.dupe(env_mod.Requirement, &.{.{ .text = "rule", .id = "r1" }});
    const insts = try a.dupe(Instance, &.{.{
        .ref_des = "U6",
        .component = "x",
        .value = "",
        .footprint = "",
        .symbol = "",
        .id = "b894897b",
        .requirements = reqs,
    }});
    const results = try a.dupe(Result, &.{.{ .status = .na }});
    var map: std.StringHashMapUnmanaged([]Result) = .empty;
    try map.put(a, "U6", results);
    return .{
        .block = .{
            .name = "t",
            .instances = insts,
            .nets = &.{},
            .ports = &.{},
            .notes = &.{},
            .groups = &.{},
            .sub_blocks = &.{},
            .verifications = verifs,
        },
        .results = results,
        .map = map,
    };
}

// spec: req_checks - applyVerifications matches a verifies form to an instance by stable id when target-id is set
test "applyVerifications matches by stable id" {
    const a = std.heap.page_allocator;
    // Target by id; the ref-des is deliberately left empty to prove the match
    // does not lean on it.
    var fx = try verifyFixture(a, &.{.{ .target_id = "b894897b", .req_id = "r1", .rationale = "checked" }});
    applyVerifications(&fx.map, &fx.block, fx.block.instances);
    try std.testing.expectEqual(Status.verified, fx.results[0].status);
    try std.testing.expect(fx.results[0].verification != null);

    // A non-matching id leaves the requirement untouched at `na`.
    var fx2 = try verifyFixture(a, &.{.{ .target_id = "deadbeef", .req_id = "r1", .rationale = "x" }});
    applyVerifications(&fx2.map, &fx2.block, fx2.block.instances);
    try std.testing.expectEqual(Status.na, fx2.results[0].status);
}

// spec: req_checks - applyVerifications matches a verifies form to an instance by ref-des when target-id is empty
test "applyVerifications matches by ref-des fallback" {
    const a = std.heap.page_allocator;
    var fx = try verifyFixture(a, &.{.{ .ref_des = "U6", .req_id = "r1", .rationale = "checked" }});
    applyVerifications(&fx.map, &fx.block, fx.block.instances);
    try std.testing.expectEqual(Status.verified, fx.results[0].status);
    try std.testing.expect(fx.results[0].verification != null);
}
