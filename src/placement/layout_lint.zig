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
//!   • `bound-far`             — an authored `(near "REF" PIN)` leg ended up more
//!                                than 5 mm from the pad it named, so the
//!                                adjacency the author asked for did not survive
//!                                placement (`near-unresolved` is its twin: the
//!                                binding named something this board has not got).
//!   • `impedance_mismatch`     — a net class declares BOTH `(impedance OHMS)`
//!                                and `(width MM)`, and the authored width does
//!                                not hit the target on this `(stackup …)`.
//!
//! Deferred (need data this layer doesn't yet expose): plane-split crossings
//! (require a layer/zone model) and per-pin IC ground-via coverage (require the
//! routed copper, not just the placement).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const impedance = @import("impedance.zig");
const mp = @import("module_policy.zig");
const near_bind = @import("near_bind.zig");
const pose_math = @import("pose_math.zig");

const Allocator = std.mem.Allocator;
const Placement = optimizer.Placement;
const Part = optimizer.Part;
const NetClass = mp.NetClass;
const PartRole = mp.PartRole;

/// A flagged layout problem. `refs` lists the involved parts (cap, or
/// victim+aggressor) and is empty for a gate about a net class rather than a
/// part. `refs`, `msg` and the outer slice are heap-owned — free with
/// `freeFindings`. `rule` is a static string.
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
/// How far an authored `(near "REF" PIN)` leg may sit from the pad it named
/// before the declaration has stopped meaning anything. Tighter than the 6 mm
/// decap budget because `(near …)` is only ever written when the author has a
/// specific reason the two must touch — a series termination at its driver, a
/// matching element at its port — and at more than a board's-worth of trace the
/// element is no longer doing the job it was placed for.
const near_max_gap_mm: f64 = 5.0;
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
        for (out.items) |f| freeFinding(alloc, f);
        out.deinit(alloc);
    }
    try lintDecapDistance(alloc, p, policy, &out);
    try lintHotLoopTightest(alloc, p, policy, &out);
    try lintFeedbackAggressor(alloc, p, policy, &out);
    try lintDecoupleUnbound(alloc, p, policy, &out);
    try lintBoundFar(alloc, p, &out);
    try lintImpedanceMismatch(alloc, p, &out);
    return out.toOwnedSlice(alloc);
}

/// `bound-far` / `near-unresolved`: the two ways an authored `(near "REF" PIN)`
/// can end up not having done its job on the solved board.
///
/// The distance is measured to the DECLARED pad, never to the nearest candidate
/// pad the way `decap-far` measures a decoupling leg. A decoupling cap may
/// legitimately be served by whichever supply pad ended up closest; a `(near …)`
/// names one pad on purpose, so "some other pad of that part is close" is not
/// the question being asked.
fn lintBoundFar(alloc: Allocator, p: Placement, out: *std.ArrayList(Finding)) Allocator.Error!void {
    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const near = try near_bind.resolve(scratch.allocator(), p.instances, p.nets);

    var far: std.ArrayList([]const u8) = .empty;
    defer far.deinit(alloc);
    for (near.pairs) |np| {
        if (nearGapMm(p, np) > near_max_gap_mm) try far.append(alloc, p.parts[np.part].ref_des);
    }
    if (far.items.len > 0) {
        try emitStatic(
            alloc,
            out,
            "bound-far",
            .warn,
            try alloc.dupe([]const u8, far.items),
            "part declares (near \"REF\" PIN) but sits more than 5 mm from the pad it named — " ++
                "the adjacency the declaration asks for did not survive placement; drag it onto " ++
                "that pad, or drop the (near …) if the part no longer belongs there",
        );
    }

    // An authored binding that resolved to nothing is reported separately and by
    // CAUSE, because the fix differs per cause and because the part was placed
    // by the generic heuristics — the declaration silently did nothing at all.
    for (near.unresolved) |u| {
        const refs = try alloc.dupe([]const u8, &[_][]const u8{p.parts[u.part].ref_des});
        const msg = blk: {
            errdefer alloc.free(refs);
            break :blk try std.fmt.allocPrint(
                alloc,
                "(near \"{s}\" {s}) on {s} {s} — the part was placed by the ordinary heuristics, " ++
                    "so the declaration had no effect",
                .{
                    p.instances[u.part].bind.near.ref,
                    p.instances[u.part].bind.near.pin,
                    p.parts[u.part].ref_des,
                    u.why.text(),
                },
            );
        };
        try emit(alloc, out, "near-unresolved", .warn, refs, msg);
    }
}

/// World-space gap between a near pair's own pad and the exact pad it named.
fn nearGapMm(p: Placement, np: near_bind.NearPair) f64 {
    const own = optimizer.padLocal(&p.parts[np.part], np.own_pin);
    const tgt = optimizer.padLocal(&p.parts[np.target], np.target_pin);
    const a = world(p.parts[np.part], own.x, own.y);
    const b = world(p.parts[np.target], tgt.x, tgt.y);
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}

/// Free a slice returned by `lint` (each finding's `refs` and `msg`, then the
/// slice).
pub fn freeFindings(alloc: Allocator, findings: []Finding) void {
    for (findings) |f| freeFinding(alloc, f);
    alloc.free(findings);
}

fn freeFinding(alloc: Allocator, f: Finding) void {
    alloc.free(f.refs);
    alloc.free(f.msg);
}

/// Append a finding, taking ownership of `refs_owned` and `msg_owned`. On
/// failure both are released, so a caller's `errdefer` never has to know
/// whether the append got far enough to adopt them.
fn emit(
    alloc: Allocator,
    out: *std.ArrayList(Finding),
    rule: []const u8,
    severity: Severity,
    refs_owned: []const []const u8,
    msg_owned: []const u8,
) Allocator.Error!void {
    errdefer alloc.free(refs_owned);
    errdefer alloc.free(msg_owned);
    try out.append(alloc, .{ .rule = rule, .severity = severity, .refs = refs_owned, .msg = msg_owned });
}

/// `emit` for the gates whose message is a fixed sentence: the static text is
/// copied so every finding's `msg` is uniformly heap-owned.
fn emitStatic(
    alloc: Allocator,
    out: *std.ArrayList(Finding),
    rule: []const u8,
    severity: Severity,
    refs_owned: []const []const u8,
    msg: []const u8,
) Allocator.Error!void {
    // The errdefer is scoped to this block ONLY: past it `emit` owns `refs_owned`
    // and releases it itself on failure, so a function-wide errdefer here would
    // free it twice.
    const owned = blk: {
        errdefer alloc.free(refs_owned);
        break :blk try alloc.dupe(u8, msg);
    };
    try emit(alloc, out, rule, severity, refs_owned, owned);
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
    try emitStatic(
        alloc,
        out,
        "decap-far",
        .warn,
        try alloc.dupe([]const u8, refs.items),
        "decoupling cap power-leg exceeds ~6 mm to its supply pin; the long leg adds loop inductance that defeats the cap — move it onto the IC's pin",
    );
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
/// (placement resolution): a cap can *declare* a pin (`(decouples …)` set) yet
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
    // A warning: the hard "must declare a pin" requirement is the netlist-level
    // `decoupling_unbound` ERC error; this fires on placement non-resolution.
    try emitStatic(
        alloc,
        out,
        "decouple-unbound",
        .warn,
        try alloc.dupe([]const u8, refs.items),
        "HF decoupling cap on a multi-pin rail has no pin binding — its loop " ++
            "collapses onto one supply pad. Bind it with (decouples \"IC\" PIN) or a " ++
            "(decouple … per-pin) form, or mark (decouples rail) if it serves the whole rail",
    );
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
    try emitStatic(
        alloc,
        out,
        "hot-loop-not-tightest",
        .warn,
        try alloc.dupe([]const u8, refs.items),
        "the switcher input (hot) loop is looser than a less-critical decoupling loop on the same board; " ++
            "the highest-dI/dt loop should be the tightest — pull the input cap onto the IC's own " ++ "power-input and power-ground pins",
    );
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
        try emitStatic(
            alloc,
            out,
            "feedback-near-aggressor",
            .warn,
            try alloc.dupe([]const u8, &.{ fp.ref_des, p.parts[ai].ref_des }),
            "a feedback/compensation part sits within ~2 mm of a switching-node, clock, or RF part; " ++
                "keep the sensitive high-impedance FB node away from the aggressor to avoid coupling and instability",
        );
    }
}

/// `impedance_mismatch`: a net class declared `(impedance OHMS)` **and** an
/// explicit `(width MM)`, and that width does not produce the target impedance
/// on this board's `(stackup …)`.
///
/// The authored width always WINS — this gate never changes geometry, it only
/// reports the contradiction, with the numbers, so an author can see which of
/// the two they meant. A class that declared the target ALONE had its width
/// solved from it (`width_derived`) and so cannot mismatch; a board with no
/// stackup, or whose preferred signal layer has no reference plane, is silent
/// rather than guessing a buildup to judge against.
fn lintImpedanceMismatch(alloc: Allocator, p: Placement, out: *std.ArrayList(Finding)) Allocator.Error!void {
    const stack = p.rules.physical.stack;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(alloc);
    for (p.rules.net) |r| {
        if (!authoredWidthAgainstTarget(r)) continue;
        const layer = impedance.targetLayer(stack, r.rf.impedance.layer) orelse continue;
        const ref = impedance.reference(stack, layer) orelse continue;
        const differential = r.rf.impedance.diff_ohms > 0;
        const target = if (differential) r.rf.impedance.diff_ohms else r.rf.impedance.ohms;
        const pair_gap = @max(
            if (r.diff_gap > 0) r.diff_gap else @max(r.clearance, p.rules.design.clearance),
            @max(r.clearance, p.rules.design.clearance),
        );
        const coated = impedance.traceIsCoated(r.rf.mask_relief_mm, r.rf.max_freq_hz);
        const process = if (differential)
            impedance.analyzeDiffOnLayer(alloc, stack, layer, r.width, pair_gap, coated)
        else
            impedance.analyzeOnLayer(alloc, stack, layer, r.width, r.rf.impedance.ground_gap_mm, coated);
        const z = (process orelse continue).z0_ohms;
        const pct = @abs(z - target) / target * 100;
        if (pct <= impedance.mismatch_tolerance_pct) continue;
        if ((try seen.getOrPut(alloc, r.class.name)).found_existing) continue;
        var owned_gap_note: ?[]u8 = null;
        defer if (owned_gap_note) |note| alloc.free(note);
        const gap_note = if (differential) blk: {
            const note = try std.fmt.allocPrint(alloc, ", pair gap {d:.4} mm", .{pair_gap});
            owned_gap_note = note;
            break :blk note;
        } else if (r.rf.impedance.ground_gap_mm > 0) blk: {
            const note = try std.fmt.allocPrint(alloc, ", ground gap {d:.4} mm", .{r.rf.impedance.ground_gap_mm});
            owned_gap_note = note;
            break :blk note;
        } else "";
        const form_name = if (differential) "diff-impedance" else "impedance";
        const kind = if (differential) "coupled-stripline" else ref.kindNameWithGroundGap(r.rf.impedance.ground_gap_mm);
        const msg = try std.fmt.allocPrint(
            alloc,
            "net-class \"{s}\" declares ({s} {d:.1}) but its authored (width {d:.4}) computes to " ++
                "{d:.1} ohms on layer {d} ({s}, h {d:.4} mm, er {d:.2}{s}{s}) — {d:.1} % off target. " ++
                "The authored width wins; drop it to derive the width from the target, or retarget the impedance.",
            .{
                r.class.name, form_name, target,                                           r.width,
                z,            layer,     kind,                                             ref.heightMm(),
                ref.er(),     gap_note,  if (stack.assumed()) ", assumed buildup" else "", pct,
            },
        );
        try emit(alloc, out, "impedance_mismatch", .warn, try alloc.dupe([]const u8, &.{}), msg);
    }
}

/// True when this rule is the case `impedance_mismatch` judges: a class that
/// declared a target AND kept an authored width to check it against.
fn authoredWidthAgainstTarget(r: optimizer.NetRule) bool {
    if (r.rf.impedance.ohms <= 0 and r.rf.impedance.diff_ohms <= 0) return false;
    if (r.rf.impedance.width_derived) return false; // solved from the target — cannot miss it
    if (r.width <= 0) return false; // no width at all: nothing to check
    return r.class.name.len > 0;
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
    for (flags) |*f| f.* = std.EnumSet(NetClass).empty;
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

/// World position of a footprint-local point on `part` — the optimizer's OWN
/// transform, so a gate here measures the pose the solver placed. This was a
/// local rotate-only copy that dropped the bottom-side local-x mirror, so every
/// leg on a flipped part read `2·|local x|` off: the 6 mm `decap-far` and 5 mm
/// `bound-far` budgets were being judged against a point the part does not
/// occupy.
fn world(part: Part, lx: f64, ly: f64) [2]f64 {
    return optimizer.worldPadCenter(&part, lx, ly);
}

/// Axis-aligned world half-extents of `part`'s rotated courtyard — the shared
/// `pose_math` rule, which is exact at the right angles nearly every pose uses
/// (a sin/cos copy carries float dust there).
fn aabbHalf(part: Part) [2]f64 {
    return pose_math.aabbHalf(part.hw, part.hh, part.rot);
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
const flat_netlist = @import("../flat_netlist.zig");
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
    const vin = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "V3P3", .pins = &vin }};
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

// spec: placement/layout_lint - measures a bottom-side part through the optimizer's own mirrored pad transform, so a flipped decap is judged where the board draws it
test "lint measures a flipped part where the placer put it" {
    var hub_pads = [_]geometry.Pad{pad("1")};
    var cap_pads = [_]geometry.Pad{.{ .number = "1", .x = 3, .y = 0, .w = 0.5, .h = 0.5 }};
    // C1 sits on the BOTTOM, 4 mm right of the hub, with its power pad 3 mm out
    // along footprint-local +x. Bottom mirrors local x, so that pad lands at
    // 4 − 3 = 1 mm: a tight decoupling loop. Skip the mirror and it reads
    // 4 + 3 = 7 mm — `2·|local x|` = 6 mm of pure error, straight through the
    // 6 mm `decap-far` budget.
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &cap_pads, .fallback = false, .x = 4, .y = 0, .side = .bottom },
    };
    var hub_pwr = [_]optimizer.PadRect{.{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var hub_gnd = [_]optimizer.PadRect{.{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 }};
    var loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 3, .y = 0, .w = 0.5, .h = 0.5 },
        .cap_gnd = .{ .x = -3, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_pwr = &hub_pwr,
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_gnd = &hub_gnd,
        .hub_gnd_pin = .{ .x = 0, .y = 0.5, .w = 0.5, .h = 0.5 },
        .pwr_net = 0,
        .weight = 1,
    }};
    const vin = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "V3P3", .pins = &vin }};
    const p = mkPlacement(&parts, &loops, &nets);

    // The gate's own measurement is the placer's, to the bit.
    const cap_w = optimizer.worldPadCenter(&parts[1], loops[0].cap_pwr.x, loops[0].cap_pwr.y);
    const hub_w = optimizer.worldPadCenter(&parts[0], loops[0].hub_pwr_pin.x, loops[0].hub_pwr_pin.y);
    try testing.expectApproxEqAbs(std.math.hypot(cap_w[0] - hub_w[0], cap_w[1] - hub_w[1]), legMm(p, loops[0]), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), legMm(p, loops[0]), 1e-12);

    // So the 6 mm budget stays quiet, where the unmirrored 7 mm would have
    // reported a decap that is in fact 1 mm from its pin.
    var ncs = [_]NetClass{.power};
    var prs = [_]PartRole{ .anchor_ic, .decoupling_cap };
    const findings = try lint(testing.allocator, p, mp.ModulePolicy{ .net_class = &ncs, .part_role = &prs, .modules = &.{} });
    defer freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 0), findings.len);

    // Courtyard extents come from the shared pose rule, which is EXACT on the
    // right angles a placed part almost always sits at — a sin/cos copy leaves
    // ~1e-16 mm of dust in both terms.
    var turned = parts[0];
    turned.rot = 90;
    try testing.expectEqual([2]f64{ 2, 2 }, aabbHalf(turned));
    var oblong = parts[1];
    oblong.hw = 1.0;
    oblong.hh = 0.25;
    oblong.rot = 270;
    try testing.expectEqual([2]f64{ 0.25, 1.0 }, aabbHalf(oblong));
}

/// A one-hub / one-passive board wired on `SIG`, with the passive at `rx` mm and
/// the `(near "U1" 1 …)` binding `nb` on it. Everything `lintBoundFar` reads.
fn mkNearPlacement(parts: []optimizer.Part, instances: []const flat_netlist.FlatInstance) Placement {
    const S = struct {
        const sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
        const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &sig }};
    };
    var p = mkPlacement(parts, &.{}, &S.nets);
    p.instances = instances;
    return p;
}

/// One pad at the part origin, shared by both adjacency fixtures. File scope so
/// the `Part`s built from it own no pointer into a callee's frame.
const near_fixture_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};

fn nearParts(rx: f64) [2]optimizer.Part {
    return .{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &near_fixture_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &near_fixture_pads, .fallback = false, .x = rx, .y = 0 },
    };
}

fn nearInstances(target_ref: []const u8, target_pin: []const u8) [2]flat_netlist.FlatInstance {
    return .{
        .{ .ref_des = "U1", .component = "", .value = "", .footprint = "", .properties = &.{}, .uuid = "" },
        .{
            .ref_des = "R1",
            .component = "res-0402",
            .value = "1k",
            .footprint = "",
            .properties = &.{},
            .uuid = "",
            .bind = .{ .near = .{ .ref = target_ref, .pin = target_pin } },
        },
    };
}

const near_policy = mp.ModulePolicy{ .net_class = &.{}, .part_role = &.{}, .modules = &.{} };

// spec: placement/layout_lint - flags a near-bound passive sitting more than 5 mm from the exact pad it declared, and clears when it is adjacent
test "lint flags a near-bound part stranded away from the pad it named" {
    const insts = nearInstances("U1", "1");

    // 10 mm from the pad it declared: the adjacency did not survive placement.
    var far_parts = nearParts(10);
    const far = try lint(testing.allocator, mkNearPlacement(&far_parts, &insts), near_policy);
    defer freeFindings(testing.allocator, far);
    try testing.expectEqual(@as(usize, 1), far.len);
    try testing.expectEqualStrings("bound-far", far[0].rule);
    try testing.expectEqualStrings("R1", far[0].refs[0]);
    try testing.expectEqual(Severity.warn, far[0].severity);

    // 1 mm away: the declaration is being honoured, so the gate is silent.
    var near_parts = nearParts(1);
    const close = try lint(testing.allocator, mkNearPlacement(&near_parts, &insts), near_policy);
    defer freeFindings(testing.allocator, close);
    try testing.expectEqual(@as(usize, 0), close.len);
}

// spec: placement/layout_lint - reports a near binding that resolved to nothing, naming the cause, so a declaration that did nothing is never silent
test "lint reports a near binding that resolved to nothing" {
    // U9 is not on this board, so the binding placed nothing — and the part sits
    // at 1 mm, where a distance-only gate would have stayed quiet.
    const insts = nearInstances("U9", "1");
    var parts = nearParts(1);
    const findings = try lint(testing.allocator, mkNearPlacement(&parts, &insts), near_policy);
    defer freeFindings(testing.allocator, findings);
    try testing.expectEqual(@as(usize, 1), findings.len);
    try testing.expectEqualStrings("near-unresolved", findings[0].rule);
    try testing.expectEqualStrings("R1", findings[0].refs[0]);
    try testing.expect(std.mem.indexOf(u8, findings[0].msg, "not on this board") != null);
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
    const sw = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "L1", .pin = "1" } };
    const fb = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{
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
    const n1 = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &n1 }};
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

fn mkPlacement(parts: []optimizer.Part, loops: []const optimizer.Loop, nets: []const flat_netlist.FlatNet) Placement {
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

/// A placement carrying nothing but one net's resolved rule and Barracuda's
/// six-layer buildup — everything the impedance gate reads and nothing else.
fn mkImpedancePlacement(rules: []const optimizer.NetRule) Placement {
    const S = struct {
        var parts = [_]optimizer.Part{};
        const nets = [_]flat_netlist.FlatNet{.{ .name = "RF_IN", .pins = &.{} }};
        const planes = [_]u8{ 2, 5 };
        const dielectrics = [_]impedance.Dielectric{
            .{ .after_layer = 1, .thickness_mm = 0.2104, .er = 4.4 },
            .{ .after_layer = 2, .thickness_mm = 0.4, .er = 4.6 },
            .{ .after_layer = 3, .thickness_mm = 0.2028, .er = 4.4 },
            .{ .after_layer = 4, .thickness_mm = 0.4, .er = 4.6 },
            .{ .after_layer = 5, .thickness_mm = 0.2104, .er = 4.4 },
        };
        const foils = [_]impedance.Foil{
            .{ .index = 1, .thickness_mm = 0.035 },
            .{ .index = 2, .thickness_mm = 0.0152 },
            .{ .index = 3, .thickness_mm = 0.0152 },
            .{ .index = 4, .thickness_mm = 0.0152 },
            .{ .index = 5, .thickness_mm = 0.0152 },
            .{ .index = 6, .thickness_mm = 0.035 },
        };
    };
    var p = mkPlacement(&S.parts, &.{}, &S.nets);
    p.rules = .{
        .net = rules,
        .physical = .{ .stack = .{
            .layers = 6,
            .planes = &S.planes,
            .dielectrics = &S.dielectrics,
            .foils = &S.foils,
            .board_mm = 1.6,
        } },
    };
    return p;
}

/// The `impedance_mismatch` finding in `findings`, or null.
fn mismatchFinding(findings: []const Finding) ?Finding {
    for (findings) |f| {
        if (std.mem.eql(u8, f.rule, "impedance_mismatch")) return f;
    }
    return null;
}

// spec: placement/layout_lint - flags a net class whose authored width misses its declared (impedance …) target
test "lint flags an authored width that misses its impedance target" {
    // 0.20 mm on 0.2104 mm prepreg is ~70 Ω, not the declared 50 Ω.
    const rules = [_]optimizer.NetRule{.{
        .class = .{ .name = "rf" },
        .width = 0.20,
        .rf = .{ .impedance = .{ .ohms = 50 } },
    }};
    const p = mkImpedancePlacement(&rules);
    var policy = try mp.analyze(testing.allocator, p);
    defer policy.deinit(testing.allocator);
    const findings = try lint(testing.allocator, p, policy);
    defer freeFindings(testing.allocator, findings);

    const f = mismatchFinding(findings) orelse return error.TestExpectedFinding;
    try testing.expectEqual(Severity.warn, f.severity);
    try testing.expectEqual(@as(usize, 0), f.refs.len); // a class, not a part
    // The message carries the numbers an author needs to act: the class, the
    // target, the authored width, and what that width actually is.
    try testing.expect(std.mem.indexOf(u8, f.msg, "\"rf\"") != null);
    try testing.expect(std.mem.indexOf(u8, f.msg, "50.0") != null);
    try testing.expect(std.mem.indexOf(u8, f.msg, "0.2000") != null);
    try testing.expect(std.mem.indexOf(u8, f.msg, "microstrip") != null);
}

// spec: placement/layout_lint - differential impedance lint uses the selected layer and authored pair gap
test "lint checks a differential width on its selected stripline layer" {
    const wrong = [_]optimizer.NetRule{.{
        .class = .{ .name = "lvds" },
        .width = 0.2532,
        .clearance = 0.127,
        .diff_gap = 0.1524,
        .rf = .{ .impedance = .{ .diff_ohms = 100, .layer = 3 } },
    }};
    const p = mkImpedancePlacement(&wrong);
    var policy = try mp.analyze(testing.allocator, p);
    defer policy.deinit(testing.allocator);
    const findings = try lint(testing.allocator, p, policy);
    defer freeFindings(testing.allocator, findings);
    const f = mismatchFinding(findings) orelse return error.TestExpectedFinding;
    try testing.expect(std.mem.indexOf(u8, f.msg, "diff-impedance 100.0") != null);
    try testing.expect(std.mem.indexOf(u8, f.msg, "layer 3") != null);
    try testing.expect(std.mem.indexOf(u8, f.msg, "pair gap 0.1524") != null);
}

// spec: placement/layout_lint - a width matching its impedance target, or derived from it, raises no mismatch
test "the impedance gate is quiet when the width matches or was derived" {
    const stack = mkImpedancePlacement(&.{}).rules.physical.stack;
    const solved = impedance.resolvedWidthMm(stack, 50).?;

    // (a) The width the target itself solves to — authored, but correct.
    const matching = [_]optimizer.NetRule{.{
        .class = .{ .name = "rf" },
        .width = solved,
        .rf = .{ .impedance = .{ .ohms = 50 } },
    }};
    // (b) The same width, but DERIVED — the class authored no width at all.
    const derived = [_]optimizer.NetRule{.{
        .class = .{ .name = "rf" },
        .width = solved,
        .rf = .{ .impedance = .{ .ohms = 50, .width_derived = true } },
    }};
    // (c) Barracuda's authored CPWG geometry is within the 5% fab band.
    const grounded = [_]optimizer.NetRule{.{
        .class = .{ .name = "rf" },
        .width = 0.31,
        .rf = .{ .impedance = .{ .ohms = 50, .ground_gap_mm = 0.127 } },
    }};
    // (d) A width far off 50 Ω, but with no target declared to check it.
    const untargeted = [_]optimizer.NetRule{.{ .class = .{ .name = "rf" }, .width = 0.2 }};

    for ([_][]const optimizer.NetRule{ &matching, &derived, &grounded, &untargeted }) |rules| {
        const p = mkImpedancePlacement(rules);
        var policy = try mp.analyze(testing.allocator, p);
        defer policy.deinit(testing.allocator);
        const findings = try lint(testing.allocator, p, policy);
        defer freeFindings(testing.allocator, findings);
        try testing.expect(mismatchFinding(findings) == null);
    }
}

// spec: placement/layout_lint - a board with no stackup raises no impedance mismatch rather than guessing a buildup
test "the impedance gate is silent without a stackup" {
    var parts = [_]optimizer.Part{};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "RF_IN", .pins = &.{} }};
    const rules = [_]optimizer.NetRule{.{
        .class = .{ .name = "rf" },
        .width = 0.20,
        .rf = .{ .impedance = .{ .ohms = 50 } },
    }};
    var p = mkPlacement(&parts, &.{}, &nets);
    p.rules = .{ .net = &rules }; // no `stack` — the legacy implicit model
    var policy = try mp.analyze(testing.allocator, p);
    defer policy.deinit(testing.allocator);
    const findings = try lint(testing.allocator, p, policy);
    defer freeFindings(testing.allocator, findings);
    try testing.expect(mismatchFinding(findings) == null);
}
