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
const derived_checks = @import("req_derived_checks.zig");
const physical_checks = @import("req_physical_checks.zig");
const na = @import("eval/net_analysis.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// Pico per micro. Capacitance parses to µF and inductance to µH, so a `p`
/// suffix (1e-12 F / 1e-12 H) is this many of the base unit.
const pico_per_micro: f64 = 1e-6;
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Check = env_mod.Check;
const DecouplingCheck = @FieldType(Check, "decoupling");

// ── Constants ─────────────────────────────────────────────────────
const current_tolerance_f: f64 = 1e-9;
const value_tolerance_pf: f64 = 1e-12;
/// Series resistors at or below this value are treated as DC-transparent by
/// the pin-voltage walk (`findVoltageForNet`). The cutoff separates supply
/// FEED resistors — vendor application circuits routinely specify 10–25 Ω
/// here (e.g. Mini-Circuits M3SWA2-63DRC+ Figure 1 uses 11.5 Ω) — from
/// pull-up/pull-down/damping resistors, which start around 100 Ω and run to
/// kΩ. At the mA-scale supply currents these feeds carry, the unmodeled drop
/// stays in the tens-of-mV class; the walk reports the upstream port's window
/// unchanged either way, so 25 Ω admits the vendor-specified feeds without
/// letting genuinely droppy elements masquerade as rails.
const dc_equiv_resistor_ohms: f64 = 25.0;
const pin_not_found_msg = "pin '{s}' not found in pinout";
const pin_net_unresolved_msg = "pin '{s}' could not be resolved to a net";

/// Outcome of evaluating one component requirement.
///
/// `pass` / `fail` are the two verdicts an automated check can reach on the
/// netlist alone; `na` means no check primitive ran (reviewer judgement), and
/// `verified` is set once `applyVerifications` overlays a matching design-side
/// `(verifies …)` form.
///
/// Two further outcomes exist because a check can be RUN and still not reach a
/// verdict, and collapsing either onto `na` or `pass` would lie:
///
///   * `unproven` — the rule applies here, but the evidence the design carries
///     cannot decide it (a capacitor with no voltage-rating attribute, a net
///     with no derivable envelope, a power-up order the enable graph leaves
///     undetermined). A warning in every profile: it is never a pass, and it is
///     not the reviewer-judgement hole `na` describes.
///   * `layout_deferred` — the rule is about geometry, so the netlist-level
///     checker structurally cannot answer it; the real measurement is a
///     layout lint over the saved placement. Informational here, and the
///     message says which lint carries the verdict.
pub const Status = enum { pass, fail, na, verified, unproven, layout_deferred };

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
    for (block.sub_blocks) |sub_block| {
        applyVerifications(map, sub_block.block, sub_block.block.instances);
    }
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
            // An `unproven`/`layout_deferred` check reached no verdict, so a
            // reviewer sign-off closes it exactly as it closes an `na`.
            .na, .unproven, .layout_deferred => {
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
    errdefer deinit(allocator, &out);
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
    while (it.next()) |e| {
        for (e.value_ptr.*) |result| if (result.message.len > 0) allocator.free(result.message);
        allocator.free(e.value_ptr.*);
    }
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
        var initialized: usize = 0;
        var inserted = false;
        errdefer if (!inserted) {
            for (results[0..initialized]) |result| if (result.message.len > 0) allocator.free(result.message);
            allocator.free(results);
        };
        for (inst.requirements, 0..) |r, i| {
            if (r.check) |chk| {
                // Checks resolve against the instance's *containing* block —
                // sub-block nets are local to the sub-block, not the outer
                // design, so we thread the right block through.
                results[i] = evalCheck(allocator, eval, block, inst, chk);
            } else {
                results[i] = .{ .status = .na };
            }
            initialized = i + 1;
        }
        try out.put(allocator, inst.ref_des, results);
        inserted = true;
    }
    for (block.sub_blocks) |sb| try walkInstances(allocator, eval, sb.block, out);
}

/// Evaluate one `(check …)` primitive against `inst` as placed in `block` —
/// the containing-block contract every check is judged under. Exported so
/// `req_design_rules.zig` can run the identical primitive set for a
/// design-owned `(requirement … (on "REF") (check …))` rule: the two rule
/// sources must not be able to reach different verdicts from the same clause.
/// The returned `message` is owned by `allocator`.
pub fn evalCheck(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    chk: Check,
) Result {
    return switch (chk) {
        .connected => |c| evalConnected(allocator, eval, block, inst, c.pin_a, c.pin_b),
        .decoupling => |c| evalDecoupling(allocator, eval, block, inst, c),
        .pullup_range => |c| evalPullupRange(allocator, eval, block, inst, c.pin, c.target_net, c.min_ohms, c.max_ohms),
        .voltage_range => |c| if (c.not_above_pin.len > 0)
            evalVoltageNotAbove(allocator, eval, block, inst, .{
                .pin_a = c.pin,
                .pin_b = c.not_above_pin,
                .margin_v = c.margin_v,
            })
        else
            evalVoltageRange(allocator, eval, block, inst, c.pin, c.min_v, c.max_v),
        .tied_to_net => |c| evalTiedToNet(allocator, eval, block, inst, c.pin, c.target_net),
        .not_connected => |c| evalNotConnected(allocator, eval, block, inst, c.pin),
        .pin_not_floating => |c| evalPinNotFloating(allocator, eval, block, inst, c.pin),
        .pins_on_same_net => |c| evalPinsOnSameNet(allocator, eval, block, inst, c.pins),
        .decoupling_per_pin => |c| evalDecouplingPerPin(allocator, eval, block, inst, c.return_pin, c.pins, c.min_uf, c.count),
        .series_element => |c| evalSeriesElement(allocator, eval, block, inst, c.kind, c.pin, c.target_net, c.min, c.max),
        .feedback_divider => |c| fromDerived(
            derived_checks.evaluate(allocator, eval, block, inst, .{
                .feedback_divider = c,
            }),
        ),
        .set_resistor_output => |c| fromDerived(
            derived_checks.evaluate(allocator, eval, block, inst, .{
                .set_resistor_output = c,
            }),
        ),
        .cap_rating => |c| physical_checks.evalCapRating(allocator, eval, block, inst, c),
        .max_distance => |c| physical_checks.evalMaxDistance(allocator, eval, block, inst, c),
        .sequence => |c| physical_checks.evalSequence(allocator, eval, block, inst, c),
    };
}

fn fromDerived(result: derived_checks.Result) Result {
    return .{
        .status = if (result.passed) .pass else .fail,
        .message = result.message,
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
        return fail(allocator, pin_not_found_msg, .{pin_a});
    const net_b = netForPinFn(eval, block, inst, pin_b) orelse
        return fail(allocator, pin_not_found_msg, .{pin_b});
    // Use netsAlias so per-pin stubs (NET.REFDES.PIN) collapse to the base net.
    if (netsAlias(net_a, net_b)) return passMsg(allocator, "'{s}' and '{s}' both on {s}", .{ pin_a, pin_b, netBase(net_a) });
    return fail(allocator, "'{s}' on {s}, '{s}' on {s} — must be the same net", .{ pin_a, net_a, pin_b, net_b });
}

fn evalDecoupling(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: DecouplingCheck,
) Result {
    const net_a = netForPinFn(eval, block, inst, check.pin_a) orelse
        return fail(allocator, pin_not_found_msg, .{check.pin_a});
    const net_b = netForPinFn(eval, block, inst, check.pin_b) orelse
        return fail(allocator, pin_not_found_msg, .{check.pin_b});
    if (std.mem.eql(u8, net_a, net_b)) {
        return fail(
            allocator,
            "pins '{s}' and '{s}' are on the same net ({s}) — nothing to decouple",
            .{ check.pin_a, check.pin_b, net_a },
        );
    }

    var found: CapRangeResult = .{};
    collectCapsBetweenRange(block, .{
        .net_a = net_a,
        .net_b = net_b,
        .min_uf = check.min_uf,
        .max_uf = check.max_uf,
    }, &found);
    if (found.best_uf == 0) {
        return fail(
            allocator,
            "no capacitor between {s} and {s}; need ≥{d:.3} µF",
            .{ net_a, net_b, check.min_uf },
        );
    }
    if (found.matched_ref.len > 0) {
        return passMsg(
            allocator,
            "{s} ({d:.3} µF) bridges {s}↔{s}",
            .{ found.matched_ref, found.matched_uf, net_a, net_b },
        );
    }
    if (found.best_uf + current_tolerance_f < check.min_uf) {
        return fail(
            allocator,
            "largest cap {s} = {d:.3} µF on {s}↔{s}; need ≥{d:.3} µF",
            .{ found.best_ref, found.best_uf, net_a, net_b, check.min_uf },
        );
    }
    return fail(
        allocator,
        "capacitor(s) on {s}↔{s} are outside [{d:.3}, {d:.3}] µF; largest is {s} = {d:.3} µF",
        .{ net_a, net_b, check.min_uf, check.max_uf.?, found.best_ref, found.best_uf },
    );
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
        return fail(allocator, pin_not_found_msg, .{pin});

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
        // resistors only count up to the supply-feed cutoff (see
        // `dc_equiv_resistor_ohms`) — pull-up/down/damping resistors are
        // 100 Ω-to-kΩ and would cause significant DC drop under load.
        const is_dc_equiv = switch (prefix) {
            'F', 'L' => true,
            'R' => blk: {
                const ohms = parseOhms(c.value) orelse break :blk false;
                break :blk resistorIsDcEquivalent(ohms);
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
        return fail(allocator, pin_net_unresolved_msg, .{pin});

    var visited: std.StringHashMapUnmanaged(void) = .empty;
    const vi = findVoltageForNet(allocator, block, net, &visited, 0) orelse
        return fail(allocator, "no `(port …)` declared on net {s} — can't verify voltage", .{net});

    if (vi.nominal) |v| {
        if (v + current_tolerance_f < min_v or v > max_v + current_tolerance_f) {
            return fail(allocator, "{s} nominal = {d:.3} V, outside [{d:.3}, {d:.3}] V", .{ vi.label, v, min_v, max_v });
        }
        return passMsg(allocator, "{s} = {d:.3} V ∈ [{d:.3}, {d:.3}] V", .{ vi.label, v, min_v, max_v });
    }
    if (vi.rated_min) |lo| if (vi.rated_max) |hi| {
        if (lo + current_tolerance_f < min_v or hi > max_v + current_tolerance_f) {
            return fail(allocator, "{s} rated [{d:.3}, {d:.3}] V, outside [{d:.3}, {d:.3}] V", .{ vi.label, lo, hi, min_v, max_v });
        }
        return passMsg(allocator, "{s} rated [{d:.3}, {d:.3}] V ⊆ [{d:.3}, {d:.3}] V", .{ vi.label, lo, hi, min_v, max_v });
    };
    return fail(allocator, "{s} has no declared voltage — add (rated …) or a nominal", .{vi.label});
}

const VoltageNotAboveCheck = struct {
    pin_a: []const u8,
    pin_b: []const u8,
    margin_v: f64,
};

fn evalVoltageNotAbove(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: VoltageNotAboveCheck,
) Result {
    const net_a = netForPinFn(eval, block, inst, check.pin_a) orelse
        return fail(allocator, pin_net_unresolved_msg, .{check.pin_a});
    const net_b = netForPinFn(eval, block, inst, check.pin_b) orelse
        return fail(allocator, pin_net_unresolved_msg, .{check.pin_b});

    var visited_a: std.StringHashMapUnmanaged(void) = .empty;
    const a = findVoltageForNet(allocator, block, net_a, &visited_a, 0) orelse
        return fail(allocator, "no `(port …)` voltage declared on {s} — can't compare '{s}'", .{ net_a, check.pin_a });
    var visited_b: std.StringHashMapUnmanaged(void) = .empty;
    const b = findVoltageForNet(allocator, block, net_b, &visited_b, 0) orelse
        return fail(allocator, "no `(port …)` voltage declared on {s} — can't compare '{s}'", .{ net_b, check.pin_b });

    const a_max = a.rated_max orelse a.nominal orelse
        return fail(allocator, "{s} has no declared maximum/nominal voltage", .{a.label});
    const b_min = b.rated_min orelse b.nominal orelse
        return fail(allocator, "{s} has no declared minimum/nominal voltage", .{b.label});
    if (a_max <= b_min + check.margin_v + current_tolerance_f) {
        return passMsg(
            allocator,
            "{s} max {d:.3} V <= {s} min {d:.3} V + {d:.3} V",
            .{ a.label, a_max, b.label, b_min, check.margin_v },
        );
    }
    return fail(
        allocator,
        "{s} max {d:.3} V exceeds {s} min {d:.3} V + {d:.3} V",
        .{ a.label, a_max, b.label, b_min, check.margin_v },
    );
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
        return fail(allocator, pin_not_found_msg, .{pin});
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
    const phys = physicalPin(sym_pins, pin) orelse
        return fail(allocator, "pin '{s}' not found in pinout '{s}'", .{ pin, pinout_key });

    // A "connected" pin is one that appears in any net with at least one OTHER
    // pin, OR whose (single-pin) net is exposed as a block port and therefore
    // wired externally by the parent design. Per-pin stub nets (NET.REFDES.PIN)
    // with only this pin and no port exposure count as disconnected. This is the
    // symmetric twin of `evalPinNotFloating`, which credits block ports the same
    // way — otherwise a "must float" pin the parent ties via a port passes here.
    for (block.nets) |net| {
        for (net.pins) |pr| {
            if (!std.mem.eql(u8, pr.ref_des, inst.ref_des)) continue;
            if (!std.mem.eql(u8, pr.pin, phys)) continue;
            // Found this physical pin on a net. If the net has co-pins, it's connected.
            if (net.pins.len > 1) {
                return fail(allocator, "pin '{s}' is connected to {s} (must be left floating per datasheet)", .{ pin, net.name });
            }
            // Single-pin net exposed as a block port → the parent wires it
            // externally via a net-tie, so it is NOT floating.
            for (block.ports) |p| {
                if (netsAlias(p.net, net.name) or std.mem.eql(u8, p.name, netBase(net.name))) {
                    return fail(allocator, "pin '{s}' on net {s} is exposed as block port {s} (wired externally; must be left floating per datasheet)", .{ pin, net.name, p.name });
                }
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
    const phys = physicalPin(sym_pins, pin) orelse
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

fn physicalPin(pins: *const std.StringHashMapUnmanaged([]const u8), pin: []const u8) ?[]const u8 {
    if (pins.contains(pin)) return pin;
    var iterator = pins.iterator();
    while (iterator.next()) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.value_ptr.*, pin)) return entry.key_ptr.*;
    }
    return null;
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
        return fail(allocator, pin_not_found_msg, .{pins[0]});
    for (pins[1..]) |pin_name| {
        const n = netForPinFn(eval, block, inst, pin_name) orelse
            return fail(allocator, pin_not_found_msg, .{pin_name});
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

    // One physical capacitor can satisfy only one member of a per-pin rule.
    // Without this consumed-ref set, a single cap on a shared VDD trunk was
    // counted once for every listed pad, defeating "one cap per pin".
    var used_caps: std.ArrayList([]const u8) = .empty;
    defer used_caps.deinit(allocator);
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
        collectUnusedCapsBetween(block, pin_net, ret_net, used_caps.items, &best_uf, &best_ref);
        if (best_uf + current_tolerance_f >= min_uf) {
            used_caps.append(allocator, best_ref) catch
                return fail(allocator, "could not track distinct decoupling capacitors", .{});
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
        return fail(allocator, pin_not_found_msg, .{pin});

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
        if (v + value_tolerance_pf >= min and v <= max + value_tolerance_pf) {
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

/// A component value string read in the natural unit of its class:
/// ohms for R, microhenries for L, microfarads for C.
pub fn parseValueFor(kind: env_mod.SeriesKind, s: []const u8) ?f64 {
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
    if (ieql(s, "pH") or ieql(s, "p")) return pico_per_micro;
    if (ieql(s, "nH") or ieql(s, "n")) return 1e-3;
    if (ieql(s, "uH") or ieql(s, "u") or std.mem.startsWith(u8, s, "µ")) return 1.0;
    if (ieql(s, "mH") or ieql(s, "m")) return 1e3;
    if (ieql(s, "H")) return 1e6;
    return null;
}

// ── Helpers ──────────────────────────────────────────────────────────────

/// Where a requirement's pin token landed: the physical pad it names and the
/// net that pad sits on.
pub const PinLocation = struct { pad: []const u8, net: []const u8 };

/// The net a pinout FUNCTION name (or a bare pad id) resolves to on `inst`.
/// Public so `req_physical_checks` resolves pins exactly as the core
/// primitives do — a second pin walk would eventually disagree about which
/// pad a datasheet function names.
pub fn netForPinFn(
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin_fn: []const u8,
) ?[]const u8 {
    const found = padAndNetForPin(eval, block, inst, pin_fn) orelse return null;
    return found.net;
}

/// The pad-and-net view of the same walk `netForPinFn` performs. The layout
/// rules need the PAD (a distance is measured from copper, not from a net),
/// and resolving it twice by two routes is exactly how a pin binding and the
/// gate that judges it drift apart.
pub fn padAndNetForPin(
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    pin_fn: []const u8,
) ?PinLocation {
    const pinout_key = if (inst.pinout.len > 0) inst.pinout else inst.symbol;
    if (pinout_key.len > 0) {
        if (ids.getSymbolPins(eval, pinout_key)) |sym_pins| {
            // Primary: match against pin function name (e.g. "VDD", "VSSAON").
            var it = sym_pins.iterator();
            while (it.next()) |e| {
                if (!std.ascii.eqlIgnoreCase(e.value_ptr.*, pin_fn)) continue;
                if (netForPhysicalPin(block, inst.ref_des, e.key_ptr.*)) |n|
                    return .{ .pad = e.key_ptr.*, .net = n };
            }
        }
    }
    // Fallback: physical pin id (e.g. "17", "A1"). Lets requirements name
    // a specific pin even when its pinout function is generic ("GND"/"VSS")
    // and the part has many such pins.
    if (netForPhysicalPin(block, inst.ref_des, pin_fn)) |n| return .{ .pad = pin_fn, .net = n };
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

/// True when any pad of `inst` sits on a net aliasing `net_name`.
pub fn instancePinOnNet(block: *const DesignBlock, inst: Instance, net_name: []const u8) bool {
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
pub fn netsAlias(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    return std.mem.eql(u8, netBase(a), netBase(b));
}

/// The logical net behind a per-pin stub alias (`VBUS.U11.VDD_1` -> `VBUS`).
pub const netBase = na.baseNetName;

fn collectUnusedCapsBetween(
    block: *const DesignBlock,
    net_a: []const u8,
    net_b: []const u8,
    used_refs: []const []const u8,
    best_uf: *f64,
    best_ref: *[]const u8,
) void {
    for (block.instances) |c| {
        if (c.ref_des.len == 0 or c.ref_des[0] != 'C') continue;
        if (containsString(used_refs, c.ref_des)) continue;
        if (!instancePinOnNet(block, c, net_a)) continue;
        if (!instancePinOnNet(block, c, net_b)) continue;
        const uf = parseMicroFarads(c.value) orelse continue;
        if (uf > best_uf.*) {
            best_uf.* = uf;
            best_ref.* = c.ref_des;
        }
    }
}

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

const CapRangeQuery = struct {
    net_a: []const u8,
    net_b: []const u8,
    min_uf: f64,
    max_uf: ?f64,
};

const CapRangeResult = struct {
    best_uf: f64 = 0,
    best_ref: []const u8 = "",
    matched_uf: f64 = 0,
    matched_ref: []const u8 = "",
};

fn collectCapsBetweenRange(
    block: *const DesignBlock,
    query: CapRangeQuery,
    result: *CapRangeResult,
) void {
    for (block.instances) |c| {
        if (c.ref_des.len == 0 or c.ref_des[0] != 'C') continue;
        if (!instancePinOnNet(block, c, query.net_a)) continue;
        if (!instancePinOnNet(block, c, query.net_b)) continue;
        const uf = parseMicroFarads(c.value) orelse continue;
        if (uf > result.best_uf) {
            result.best_uf = uf;
            result.best_ref = c.ref_des;
        }
        const within_max = if (query.max_uf) |hi|
            uf <= hi + value_tolerance_pf
        else
            true;
        if (uf + value_tolerance_pf >= query.min_uf and
            within_max and uf > result.matched_uf)
        {
            result.matched_uf = uf;
            result.matched_ref = c.ref_des;
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

/// Parse "10k" / "220" / "4.7M" / "10m" / "4R7" / "0R05" → Ω. Accepts
/// `<number><optional SI/R-notation>`. `R`-notation (`4R7` = 4.7 Ω, where `R`
/// stands in for the decimal point) and a milliohm `m` suffix (`10m` = 0.01 Ω)
/// are both supported so a current-sense shunt isn't misread 1000× high. An
/// unrecognized suffix yields `null` (the value just doesn't qualify) rather
/// than being silently taken as ohms ×1.0.
/// Whether a series resistor of this value is DC-transparent for the
/// pin-voltage walk. Public so tests can pin the supply-feed cutoff.
pub fn resistorIsDcEquivalent(ohms: f64) bool {
    return ohms <= dc_equiv_resistor_ohms;
}

/// Parse a resistor value string ("11.5R", "4.7k", "10m", "1M") to ohms,
/// honoring SI prefixes and R-notation. Null when the string is not a value.
pub fn parseOhms(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    // R-notation: `4R7`/`0R05`/`4R` — split on the first 'R'/'r' and treat it as
    // the decimal point. Only when no '.' is present, so "4.7" stays numeric.
    // Not a net name: the decimal point of a resistor VALUE string.
    if (std.mem.indexOfScalar(u8, s, '.') == null) {
        if (std.mem.indexOfAny(u8, s, "Rr")) |r| {
            const int_part = s[0..r];
            const frac_part = s[r + 1 ..];
            // Whole thing must be digits either side of the R.
            if (allDigits(int_part) and allDigits(frac_part) and (int_part.len > 0 or frac_part.len > 0)) {
                var buf: [32]u8 = undefined;
                const joined = std.fmt.bufPrint(&buf, "{s}.{s}", .{
                    if (int_part.len > 0) int_part else "0",
                    if (frac_part.len > 0) frac_part else "0",
                }) catch return null;
                return std.fmt.parseFloat(f64, joined) catch null;
            }
        }
    }
    var i: usize = 0;
    while (i < s.len and (isDigit(s[i]) or s[i] == '.')) : (i += 1) {}
    if (i == 0) return null;
    const num = std.fmt.parseFloat(f64, s[0..i]) catch return null;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) : (i += 1) {}
    if (i >= s.len) return num;
    const scale = suffixToOhms(s[i..]) orelse return null;
    return num * scale;
}

fn allDigits(s: []const u8) bool {
    for (s) |c| if (!isDigit(c)) return false;
    return true;
}

fn suffixToMicroFarads(s: []const u8) ?f64 {
    if (ieql(s, "pF") or ieql(s, "p")) return pico_per_micro;
    if (ieql(s, "nF") or ieql(s, "n")) return 1e-3;
    if (ieql(s, "uF") or ieql(s, "u") or std.mem.startsWith(u8, s, "µ")) return 1.0;
    if (ieql(s, "mF") or ieql(s, "m")) return 1e3;
    if (ieql(s, "F")) return 1e6;
    return null;
}

/// Scale factor for an ohms suffix, or `null` when the suffix is unrecognized
/// so `parseOhms` can reject the value rather than silently taking garbage as
/// ohms. `m` is milliohms (not mega — that is `M`), so a `10m` shunt reads
/// 0.01 Ω, not 10 Ω. A bare `Ω`/`ohm`/`R`/`r` suffix (or an empty suffix) is
/// ×1.0.
fn suffixToOhms(s: []const u8) ?f64 {
    if (s.len == 0) return 1.0;
    if (ieql(s, "R") or ieql(s, "Ω") or ieql(s, "ohm") or ieql(s, "ohms")) return 1.0;
    // `m` (milli) vs `M` (mega) MUST be case-sensitive — case-insensitive
    // matching collapsed both onto whichever was tested first, so `1M` read as
    // 1 mΩ instead of 1 MΩ. `k`/`G` have no such collision.
    if (std.mem.eql(u8, s, "m") or std.mem.eql(u8, s, "mΩ") or std.mem.eql(u8, s, "mohm")) return 1e-3;
    if (std.mem.eql(u8, s, "M") or std.mem.eql(u8, s, "MΩ") or std.mem.eql(u8, s, "Mohm")) return 1e6;
    if (ieql(s, "k") or ieql(s, "kΩ") or ieql(s, "kohm")) return 1e3;
    if (ieql(s, "G") or ieql(s, "GΩ")) return 1e9;
    return null;
}

fn ieql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Allocator-owned failure message. Public so `req_physical_checks` builds its
/// verdicts with the same three constructors the core primitives use.
pub fn fail(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "";
    return .{ .status = .fail, .message = msg };
}

/// Allocator-owned pass message. Public alongside `fail`.
pub fn passMsg(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "";
    return .{ .status = .pass, .message = msg };
}

/// Parse a capacitor / resistor voltage-rating string ("16V", "6.3 V", "250mV",
/// "1kV") to volts. Deliberately stricter than the fab gate's `parseRating`,
/// which accepts any unit because its caller already knows the key it looked
/// up: here the string comes from an unlabelled attribute list where "63mW"
/// and "1A" sit beside the voltage, so a missing or foreign unit must be a
/// rejection rather than a bare number taken as volts.
pub fn parseVolts(s: []const u8) ?f64 {
    const text = std.mem.trim(u8, s, " \t");
    if (text.len == 0) return null;
    var i: usize = 0;
    while (i < text.len and (isDigit(text[i]) or text[i] == '.')) : (i += 1) {}
    if (i == 0) return null;
    const num = std.fmt.parseFloat(f64, text[0..i]) catch return null;
    const suffix = std.mem.trim(u8, text[i..], " \t");
    const scale = suffixToVolts(suffix) orelse return null;
    const volts = num * scale;
    return if (std.math.isFinite(volts) and volts > 0) volts else null;
}

fn suffixToVolts(s: []const u8) ?f64 {
    if (ieql(s, "V")) return 1.0;
    if (ieql(s, "mV")) return 1e-3;
    if (ieql(s, "kV")) return 1e3;
    return null;
}
