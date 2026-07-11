//! Layout verification gates — Phase 1 of the module-placement ruleset. A
//! read-only audit of a *solved* `Placement` against the loop-area /
//! parasitic-inductance discipline the ruleset prescribes. Nothing here moves a
//! part; each gate emits a `Finding` an agent (or a human) should resolve
//! before trusting the board.
//!
//! Unlike `erc.zig`, which only sees the netlist, these gates need geometry —
//! they read part positions and the decoupling loops the optimizer found, plus
//! the criticality classes detected by `module_policy.zig`. They live in the
//! placement layer (downstream of the solve) and are surfaced through
//! `pcb_describe`'s `lint[]` array, alongside the existing spec-coverage and
//! long-loop checks.
//!
//! Gates implemented here:
//!   • `decap-far`              — a decoupling cap whose power-leg to its supply
//!                                pin exceeds the ~6 mm budget (Microchip's hard
//!                                limit; long leg = wasted loop inductance).
//!   • `hot-loop-not-tightest`  — the switcher input (hot) loop is looser than a
//!                                less-critical decoupling loop; the highest
//!                                dI/dt loop should be the tightest on the board.
//!   • `feedback-near-aggressor`— a feedback/compensation part sits within
//!                                keep-out of a switching-node, clock, or RF
//!                                part — the classic FB-coupling instability.
//!
//! Deferred (need data this layer doesn't yet expose): plane-split crossings
//! (require a layer/zone model) and per-pin IC ground-via coverage (require the
//! routed copper, not just the placement).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const mp = @import("module_policy.zig");

const Allocator = std.mem.Allocator;
const Placement = optimizer.Placement;
const Part = optimizer.Part;
const NetClass = mp.NetClass;
const PartRole = mp.PartRole;

/// A flagged layout problem. `refs` lists the involved parts (cap, or
/// victim+aggressor). `refs` and the outer slice are heap-owned — free with
/// `freeFindings`. `rule`/`msg` are static strings.
pub const Finding = struct {
    rule: []const u8,
    severity: Severity,
    refs: []const []const u8,
    msg: []const u8,
};

/// Finding severity: `err` blocks trust in the layout, `warn` flags a smell
/// worth fixing, `info` is advisory.
pub const Severity = enum { err, warn, info };

/// Microchip's hard limit: keep the pin→decap trace under ~6 mm or the leg
/// inductance defeats the cap.
const decap_max_leg_mm: f64 = 6.0;
/// A feedback node within this courtyard gap of a switching/clock/RF aggressor
/// is at coupling risk.
const fb_aggressor_gap_mm: f64 = 2.0;
/// A hot loop only counts as "not tightest" when it's this much looser than the
/// best non-hot loop — a margin so near-ties don't churn the lint.
const hot_loop_margin: f64 = 1.3;

/// Run every gate over the solved placement. Returns a heap slice of findings
/// (possibly empty) the caller frees with `freeFindings`.
pub fn lint(alloc: Allocator, p: Placement, policy: mp.ModulePolicy) Allocator.Error![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    errdefer {
        for (out.items) |f| alloc.free(f.refs);
        out.deinit(alloc);
    }
    try lintDecapDistance(alloc, p, policy, &out);
    try lintHotLoopTightest(alloc, p, policy, &out);
    try lintFeedbackAggressor(alloc, p, policy, &out);
    try lintDecoupleUnbound(alloc, p, policy, &out);
    return out.toOwnedSlice(alloc);
}

/// Free a slice returned by `lint` (each finding's `refs`, then the slice).
pub fn freeFindings(alloc: Allocator, findings: []Finding) void {
    for (findings) |f| alloc.free(f.refs);
    alloc.free(findings);
}

/// `decap-far`: any high-frequency decoupling loop whose power-leg exceeds the
/// 6 mm budget. Bulk caps (rail-entry reservoirs) are exempt — the ruleset
/// allows them ~2 cm; only the HF bypass cap must hug the pin.
fn lintDecapDistance(alloc: Allocator, p: Placement, policy: mp.ModulePolicy, out: *std.ArrayList(Finding)) Allocator.Error!void {
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(alloc);
    for (p.loops) |L| {
        if (L.cap < policy.part_role.len and policy.part_role[L.cap] == .bulk_cap) continue;
        if (legMm(p, L) > decap_max_leg_mm) try refs.append(alloc, p.parts[L.cap].ref_des);
    }
    if (refs.items.len == 0) return;
    const refs_owned = try alloc.dupe([]const u8, refs.items);
    errdefer alloc.free(refs_owned);
    try out.append(alloc, .{
        .rule = "decap-far",
        .severity = .warn,
        .refs = refs_owned,
        .msg = "decoupling cap power-leg exceeds ~6 mm to its supply pin; the long leg adds loop inductance that defeats the cap — move it onto the IC's pin",
    });
}

/// `decouple-unbound`: a high-frequency decoupling cap on a rail that lands on
/// ≥2 of the hub's *supply* pads (straps like EN/PG already excluded from that
/// count) whose per-pin binding did not resolve — its loop + ratsnest collapse
/// onto one (lowest-numbered) pad instead of the intended pin. The author should
/// bind it with `(decouples "IC" PIN)` (or a `(decouple … per-pin)` form), or, if
/// it genuinely serves the whole rail, mark `(decouples rail)`.
/// Exemptions: bulk reservoirs (rail-level by nature) and single-supply-pad
/// rails (the target is unambiguous — e.g. a buck VIN, never the enable strap).
///
/// This is a **warning**, not an error, because it fires on `explicit_pin`
/// (placement resolution): a cap can *declare* a pin (`decouple_pin` set) yet
/// still land here when the solver pairs it to a different hub on a shared plane,
/// which is a placement-quality smell, not a missing declaration. The hard
/// "every decoupling cap must declare a pin" requirement is the netlist-level
/// `decoupling_unbound` ERC check (`src/erc.zig`, error), which gates
/// `build`/`check` and the design health chips.
fn lintDecoupleUnbound(alloc: Allocator, p: Placement, policy: mp.ModulePolicy, out: *std.ArrayList(Finding)) Allocator.Error!void {
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(alloc);
    for (p.loops) |L| {
        if (L.explicit_pin.len > 0) continue; // already bound (decouples / near / per-pin)
        if (L.rail_optout) continue; // explicit (decouples rail) opt-out
        if (L.cap < policy.part_role.len and policy.part_role[L.cap] == .bulk_cap) continue; // bulk exempt
        if (L.hub_pwr.len < 2) continue; // one supply pad ⇒ binding is unambiguous
        try refs.append(alloc, p.parts[L.cap].ref_des);
    }
    if (refs.items.len == 0) return;
    const refs_owned = try alloc.dupe([]const u8, refs.items);
    errdefer alloc.free(refs_owned);
    try out.append(alloc, .{
        .rule = "decouple-unbound",
        // A warning: the hard "must declare a pin" requirement is the netlist-level
        // `decoupling_unbound` ERC error; this fires on placement non-resolution.
        .severity = .warn,
        .refs = refs_owned,
        .msg = "HF decoupling cap on a multi-pin rail has no pin binding — its loop " ++
            "collapses onto one supply pad. Bind it with (decouples \"IC\" PIN) or a " ++
            "(decouple … per-pin) form, or mark (decouples rail) if it serves the whole rail",
    });
}

/// `hot-loop-not-tightest`: a switcher input (hot) loop looser than the best
/// non-hot decoupling loop on the same board.
fn lintHotLoopTightest(alloc: Allocator, p: Placement, policy: mp.ModulePolicy, out: *std.ArrayList(Finding)) Allocator.Error!void {
    var min_nonhot: f64 = std.math.floatMax(f64);
    var any_nonhot = false;
    for (p.loops) |L| {
        if (isHotLoop(policy, L)) continue;
        const nh = optimizer.loopNh(p.parts, L);
        if (nh < min_nonhot) {
            min_nonhot = nh;
            any_nonhot = true;
        }
    }
    if (!any_nonhot) return;
    var refs: std.ArrayList([]const u8) = .empty;
    defer refs.deinit(alloc);
    for (p.loops) |L| {
        if (!isHotLoop(policy, L)) continue;
        if (optimizer.loopNh(p.parts, L) > min_nonhot * hot_loop_margin) try refs.append(alloc, p.parts[L.cap].ref_des);
    }
    if (refs.items.len == 0) return;
    const refs_owned = try alloc.dupe([]const u8, refs.items);
    errdefer alloc.free(refs_owned);
    try out.append(alloc, .{
        .rule = "hot-loop-not-tightest",
        .severity = .warn,
        .refs = refs_owned,
        .msg = "the switcher input (hot) loop is looser than a less-critical decoupling loop on the same board; " ++
            "the highest-dI/dt loop should be the tightest — pull the input cap onto the IC's PVIN/PGND pins",
    });
}

/// `feedback-near-aggressor`: a feedback part within keep-out of a switching,
/// clock, or RF passive. Hubs are excluded as aggressors — the IC legitimately
/// carries both the FB and SW pins; the rule is about the FB *divider/trace*
/// versus the SW *node copper / inductor*.
fn lintFeedbackAggressor(alloc: Allocator, p: Placement, policy: mp.ModulePolicy, out: *std.ArrayList(Finding)) Allocator.Error!void {
    const flags = try partClassFlags(alloc, p, policy);
    defer alloc.free(flags);
    for (p.parts, 0..) |fp, fi| {
        if (fp.kind != .passive or !flags[fi].contains(.feedback)) continue;
        var best: ?usize = null;
        var best_gap: f64 = std.math.floatMax(f64);
        for (p.parts, 0..) |ap, ai| {
            if (ai == fi or ap.kind != .passive or !isAggressor(flags[ai])) continue;
            const g = rectGap(fp, ap);
            if (g < best_gap) {
                best_gap = g;
                best = ai;
            }
        }
        const ai = best orelse continue;
        if (best_gap >= fb_aggressor_gap_mm) continue;
        const pair = try alloc.dupe([]const u8, &.{ fp.ref_des, p.parts[ai].ref_des });
        errdefer alloc.free(pair);
        try out.append(alloc, .{
            .rule = "feedback-near-aggressor",
            .severity = .warn,
            .refs = pair,
            .msg = "a feedback/compensation part sits within ~2 mm of a switching-node, clock, or RF part; " ++
                "keep the sensitive high-impedance FB node away from the aggressor to avoid coupling and instability",
        });
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────

fn isHotLoop(policy: mp.ModulePolicy, L: optimizer.Loop) bool {
    if (L.pwr_net < 0) return false;
    const ni: usize = @intCast(L.pwr_net);
    return ni < policy.net_class.len and policy.net_class[ni] == .input_rail;
}

fn isAggressor(fl: std.EnumSet(NetClass)) bool {
    return fl.contains(.switch_node) or fl.contains(.clock) or fl.contains(.rf);
}

/// Build a per-part set of the net classes touching its pads (the linter's twin
/// of the role pass in `module_policy.analyze`).
fn partClassFlags(alloc: Allocator, p: Placement, policy: mp.ModulePolicy) Allocator.Error![]std.EnumSet(NetClass) {
    const flags = try alloc.alloc(std.EnumSet(NetClass), p.parts.len);
    errdefer alloc.free(flags);
    for (flags) |*f| f.* = std.EnumSet(NetClass).initEmpty();
    var idx = std.StringHashMapUnmanaged(usize).empty;
    defer idx.deinit(alloc);
    for (p.parts, 0..) |part, i| try idx.put(alloc, part.ref_des, i);
    for (p.nets, 0..) |net, ni| {
        if (ni >= policy.net_class.len) break;
        for (net.pins) |pin| {
            if (idx.get(pin.ref_des)) |pi| flags[pi].insert(policy.net_class[ni]);
        }
    }
    return flags;
}

/// Power-leg length (mm): cap power pad → the *nearest* of the hub's supply
/// pads on this rail, world-rotated. The optimizer's loop pins to one pad for
/// scoring continuity, but a decap forms its real loop through whichever VDD
/// pad it sits next to — so a "is this decap tight to a supply pin" gate must
/// take the closest pad, or every decap on a big multi-VDD IC reads as far.
/// Falls back to the pinned pad when the rail's pad list is empty (fixtures).
fn legMm(p: Placement, L: optimizer.Loop) f64 {
    const hub = p.parts[L.hub];
    const c = world(p.parts[L.cap], L.cap_pwr.x, L.cap_pwr.y);
    const pin = world(hub, L.hub_pwr_pin.x, L.hub_pwr_pin.y);
    var best = std.math.hypot(c[0] - pin[0], c[1] - pin[1]);
    for (L.hub_pwr) |pwr_pad| {
        const h = world(hub, pwr_pad.x, pwr_pad.y);
        best = @min(best, std.math.hypot(c[0] - h[0], c[1] - h[1]));
    }
    return best;
}

fn world(part: Part, lx: f64, ly: f64) [2]f64 {
    const a = part.rot * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);
    return .{ part.x + lx * c - ly * s, part.y + lx * s + ly * c };
}

fn aabbHalf(part: Part) [2]f64 {
    const a = part.rot * std.math.pi / 180.0;
    const c = @abs(@cos(a));
    const s = @abs(@sin(a));
    return .{ part.hw * c + part.hh * s, part.hw * s + part.hh * c };
}

/// Clearance between two parts' world AABBs (mm); 0 = touching/overlapping.
fn rectGap(a: Part, b: Part) f64 {
    const ah = aabbHalf(a);
    const bh = aabbHalf(b);
    const gx = @max(0.0, @abs(b.x - a.x) - (ah[0] + bh[0]));
    const gy = @max(0.0, @abs(b.y - a.y) - (ah[1] + bh[1]));
    return std.math.hypot(gx, gy);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const export_kicad = @import("../export_kicad.zig");
const geometry = @import("geometry.zig");

fn pad(n: []const u8) geometry.Pad {
    return .{ .number = n, .x = 0, .y = 0, .w = 0.5, .h = 0.5 };
}

// spec: placement/layout_lint - flags a decoupling cap whose power-leg exceeds the 6 mm budget
test "lint flags a decap whose leg is too long" {
    var hub_pads = [_]geometry.Pad{pad("1")};
    var cap_pads = [_]geometry.Pad{pad("1")};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &cap_pads, .fallback = false, .x = 10, .y = 0 },
    };
    var hub_pwr = [_]optimizer.PadRect{.{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var hub_gnd = [_]optimizer.PadRect{.{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 }};
    var loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .cap_gnd = .{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 },
        .hub_pwr = &hub_pwr,
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_gnd = &hub_gnd,
        .hub_gnd_pin = .{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 },
        .pwr_net = 0,
        .weight = 1,
    }};
    const vin = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "V3P3", .pins = &vin }};
    const p = mkPlacement(&parts, &loops, &nets);

    var ncs = [_]NetClass{.power};
    var prs = [_]PartRole{ .anchor_ic, .decoupling_cap };
    const policy = mp.ModulePolicy{ .net_class = &ncs, .part_role = &prs, .modules = &.{} };

    const findings = try lint(testing.allocator, p, policy);
    defer freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("decap-far", findings[0].rule);
    try testing.expectEqualStrings("C1", findings[0].refs[0]);
}

// spec: placement/layout_lint - flags a feedback part placed within keep-out of a switching-node aggressor
test "lint flags a feedback part next to the inductor" {
    var hub_pads = [_]geometry.Pad{pad("1")};
    var l_pads = [_]geometry.Pad{pad("1")};
    var r_pads = [_]geometry.Pad{pad("1")};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "L1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &l_pads, .fallback = false, .x = 2, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &r_pads, .fallback = false, .x = 3, .y = 0 },
    };
    const sw = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "L1", .pin = "1" } };
    const fb = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{
        .{ .name = "SW", .pins = &sw },
        .{ .name = "FB", .pins = &fb },
    };
    const p = mkPlacement(&parts, &.{}, &nets);

    var ncs = [_]NetClass{ .switch_node, .feedback };
    var prs = [_]PartRole{ .anchor_ic, .other, .feedback_divider };
    const policy = mp.ModulePolicy{ .net_class = &ncs, .part_role = &prs, .modules = &.{} };

    const findings = try lint(testing.allocator, p, policy);
    defer freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("feedback-near-aggressor", findings[0].rule);
    try testing.expectEqualStrings("R1", findings[0].refs[0]);
    try testing.expectEqualStrings("L1", findings[0].refs[1]);
}

// spec: placement/layout_lint - flags an HF decoupling cap on a multi-supply-pad rail with no pin binding, exempting (decouples rail) opt-outs
test "lint flags an unbound decoupling cap on a multi-pin rail" {
    var hub_pads = [_]geometry.Pad{ pad("1"), pad("2") };
    var c1_pads = [_]geometry.Pad{pad("1")};
    var c2_pads = [_]geometry.Pad{pad("1")};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &c1_pads, .fallback = false, .x = 1, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &c2_pads, .fallback = false, .x = 1, .y = 1 },
    };
    // Two supply pads on the rail ⇒ the binding is ambiguous and must be declared.
    var hub_pwr = [_]optimizer.PadRect{ .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 }, .{ .x = 0.5, .y = 0, .w = 0.5, .h = 0.5 } };
    var hub_gnd = [_]optimizer.PadRect{.{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 }};
    const mkLoop = struct {
        fn f(cap: usize, hp: []optimizer.PadRect, hg: []optimizer.PadRect, optout: bool) optimizer.Loop {
            return .{
                .cap = cap,
                .hub = 0,
                .cap_pwr = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
                .cap_gnd = .{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 },
                .hub_pwr = hp,
                .hub_pwr_pin = hp[0],
                .hub_gnd = hg,
                .hub_gnd_pin = hg[0],
                .pwr_net = 0,
                .weight = 1,
                .rail_optout = optout,
            };
        }
    }.f;
    var loops = [_]optimizer.Loop{
        mkLoop(1, &hub_pwr, &hub_gnd, false), // C1 unbound → flagged
        mkLoop(2, &hub_pwr, &hub_gnd, true), // C2 (decouples rail) → exempt
    };
    const n1 = [_]export_kicad.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]export_kicad.FlatNet{.{ .name = "VDD", .pins = &n1 }};
    const p = mkPlacement(&parts, &loops, &nets);

    var ncs = [_]NetClass{.power};
    var prs = [_]PartRole{ .anchor_ic, .decoupling_cap, .decoupling_cap };
    const policy = mp.ModulePolicy{ .net_class = &ncs, .part_role = &prs, .modules = &.{} };

    // A warning naming only C1 (C2 opted out via (decouples rail)).
    const findings = try lint(testing.allocator, p, policy);
    defer freeFindings(testing.allocator, findings);
    var found = false;
    for (findings) |fdg| {
        if (!std.mem.eql(u8, fdg.rule, "decouple-unbound")) continue;
        found = true;
        try testing.expectEqual(@as(usize, 1), fdg.refs.len); // only C1; C2 opted out
        try testing.expectEqualStrings("C1", fdg.refs[0]);
        try testing.expectEqual(Severity.warn, fdg.severity);
    }
    try testing.expect(found);
}

fn mkPlacement(parts: []optimizer.Part, loops: []const optimizer.Loop, nets: []const export_kicad.FlatNet) Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 12,
        .maxy = 2,
        .generated = true,
    };
}
