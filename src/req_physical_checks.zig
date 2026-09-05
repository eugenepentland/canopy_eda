//! The three requirement-check primitives whose evidence is PHYSICAL rather
//! than topological — they ask what potential a net actually reaches, how far
//! apart two pads sit, and which rail comes up first. Split out of
//! `req_checks.zig` for the same reason `req_derived_checks.zig` is: the core
//! checker stays a readable list of netlist walks, and each new evidence
//! source (`eval/net_envelopes`, the saved layout, `eval/power_sequencing`)
//! arrives in one place.
//!
//! All three can end in a verdict the netlist cannot reach, which is why
//! `req_checks.Status` carries `unproven` and `layout_deferred`. Reporting
//! either as a pass would be the failure mode these primitives exist to close:
//! a datasheet rule that reads green because nothing was measured.

const std = @import("std");
const env = @import("eval/env.zig");
const na = @import("eval/net_analysis.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const req = @import("req_checks.zig");

const Evaluator = @import("eval/evaluator.zig").Evaluator;
const DesignBlock = env.DesignBlock;
const Instance = env.Instance;
const Check = env.Check;
const Result = req.Result;

const CapRatingCheck = @FieldType(Check, "cap_rating");
const MaxDistanceCheck = @FieldType(Check, "max_distance");
const SequenceCheck = @FieldType(Check, "sequence");

/// Volt-scale slack. Ratings and envelopes are both authored to three decimals
/// at most, so a comparison must not fail on float representation alone.
const volt_epsilon: f64 = 1e-9;

const pin_unresolved_msg = "pin '{s}' could not be resolved to a net";

/// A ran-but-undecided outcome: the rule applies and the design does not carry
/// the evidence that would settle it. Warned about, never passed. Lives here
/// rather than beside `req_checks.fail`/`passMsg` because these two primitives
/// are its only producers — the netlist walks in the core checker always reach
/// a verdict.
fn unproven(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "";
    return .{ .status = .unproven, .message = msg };
}

/// A geometry rule the netlist checker structurally cannot answer; the message
/// names the layout lint that carries the verdict.
fn layoutDeferred(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Result {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "";
    return .{ .status = .layout_deferred, .message = msg };
}

// ── (cap-rating …) ────────────────────────────────────────────────────────

/// A net's derived worst-case DC potential window, or the reason there is none.
const Envelope = struct { min: f64, max: f64 };

/// Every capacitor bridging the two pins' nets must be rated for the worst-case
/// DC potential the design proves across them.
///
/// The envelope comes from `block.net_envelopes` — the same table the release
/// rating checks read (`fab_readiness.railVoltage`) — so a requirement and the
/// fab gate can never disagree about what a net reaches. What this adds is the
/// datasheet's own multiplier: the fab gate knows a generic 25 % ceramic
/// margin, while `(min-ratio …)`/`(min-v …)` carry the number the part's own
/// data sheet asks for on the pin it asks for it on.
pub fn evalCapRating(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: CapRatingCheck,
) Result {
    const net_a = req.netForPinFn(eval, block, inst, check.pin_a) orelse
        return req.fail(allocator, pin_unresolved_msg, .{check.pin_a});
    const net_b = req.netForPinFn(eval, block, inst, check.pin_b) orelse
        return req.fail(allocator, pin_unresolved_msg, .{check.pin_b});
    if (req.netsAlias(net_a, net_b)) return req.fail(
        allocator,
        "pins '{s}' and '{s}' are on the same net ({s}) — no capacitor can bridge them",
        .{ check.pin_a, check.pin_b, req.netBase(net_a) },
    );

    const env_a = envelopeFor(block, net_a) orelse return unprovenEnvelope(allocator, net_a);
    const env_b = envelopeFor(block, net_b) orelse return unprovenEnvelope(allocator, net_b);
    // Worst case over two independent intervals: the widest difference either
    // polarity can reach, which is what a non-polarised ceramic must survive.
    const applied = @max(@abs(env_a.max - env_b.min), @abs(env_a.min - env_b.max));
    const required = @max(check.min_v, check.min_ratio * applied);

    return judgeBridgingCaps(allocator, block, .{
        .net_a = net_a,
        .net_b = net_b,
        .applied = applied,
        .required = required,
    });
}

/// The bound every bridging cap is measured against, plus the nets it bridges.
const RatingDemand = struct {
    net_a: []const u8,
    net_b: []const u8,
    applied: f64,
    required: f64,
};

/// Walk every capacitor bridging the two nets and reduce them to one verdict:
/// an underrated cap is an error, an unrated one leaves the rule unproven, and
/// only an all-rated, all-sufficient set passes.
fn judgeBridgingCaps(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    demand: RatingDemand,
) Result {
    var bridging: usize = 0;
    var unrated_ref: []const u8 = "";
    var worst_ref: []const u8 = "";
    var worst_v: f64 = 0;
    for (block.instances) |c| {
        if (c.ref_des.len == 0 or c.ref_des[0] != 'C') continue;
        if (!req.instancePinOnNet(block, c, demand.net_a)) continue;
        if (!req.instancePinOnNet(block, c, demand.net_b)) continue;
        bridging += 1;
        const rated = capVoltageRating(c) orelse {
            if (unrated_ref.len == 0) unrated_ref = c.ref_des;
            continue;
        };
        if (worst_ref.len == 0 or rated < worst_v) {
            worst_ref = c.ref_des;
            worst_v = rated;
        }
    }

    if (bridging == 0) return unproven(
        allocator,
        "no capacitor bridges {s} and {s}, so the rating rule proves nothing here",
        .{ demand.net_a, demand.net_b },
    );
    if (worst_ref.len > 0 and worst_v + volt_epsilon < demand.required) return req.fail(
        allocator,
        "{s} is rated {d:.3} V but {s}↔{s} needs ≥{d:.3} V ({d:.3} V worst-case applied)",
        .{ worst_ref, worst_v, demand.net_a, demand.net_b, demand.required, demand.applied },
    );
    if (unrated_ref.len > 0) return unproven(
        allocator,
        "{s} on {s}↔{s} declares no voltage rating, so the ≥{d:.3} V this pin needs " ++
            "({d:.3} V worst-case applied) is unproven — author one, e.g. (cap-0402 \"100nF\" x7r \"10%\" \"25V\")",
        .{ unrated_ref, demand.net_a, demand.net_b, demand.required, demand.applied },
    );
    return req.passMsg(
        allocator,
        "every cap on {s}↔{s} is rated ≥{d:.3} V (worst {s} at {d:.3} V) against {d:.3} V applied",
        .{ demand.net_a, demand.net_b, demand.required, worst_ref, worst_v, demand.applied },
    );
}

fn unprovenEnvelope(allocator: std.mem.Allocator, net: []const u8) Result {
    return unproven(
        allocator,
        "no derived DC envelope for net {s} — declare a (port …) voltage upstream " ++
            "or an explicit (net-envelope \"{s}\" (rated LO HI) \"why\")",
        .{ req.netBase(net), req.netBase(net) },
    );
}

/// The worst-case DC window on `net`, read from the block's derived envelope
/// table. Ground-class names are 0 V by definition — the same rule
/// `fab_readiness.railVoltage` applies before it consults the table, so a cap
/// to GND is not reported unproven for want of a declaration nobody writes.
fn envelopeFor(block: *const DesignBlock, net: []const u8) ?Envelope {
    const base = na.baseNetName(req.netBase(net));
    if (na.isRatingZeroVolts(base)) return .{ .min = 0, .max = 0 };
    for (block.net_envelopes) |e| {
        if (std.ascii.eqlIgnoreCase(base, e.net)) return .{ .min = e.min, .max = e.max };
    }
    return null;
}

/// A capacitor's authored voltage rating in volts, or null when it carries
/// none. The `voltage` PROPERTY is the source: it holds either the rating the
/// design authored — `(cap-0402 "1uF" (rating 25V))` and the bare `"25V"` both
/// land there via `eval/attrs.zig` — or the one a resolved parts row carries,
/// with the row winning because it is the physical part. `erc` reports the
/// case where the two disagree.
///
/// The attribute-text scan below survives only as the fallback for an
/// attribute nothing could classify (a `"25 V dc"`-style spelling): every
/// recognised one is already a property by the time this runs.
fn capVoltageRating(inst: Instance) ?f64 {
    for (inst.properties) |prop| {
        if (!std.ascii.eqlIgnoreCase(prop.key, "voltage")) continue;
        if (req.parseVolts(prop.value)) |v| return v;
    }
    for (inst.attrs) |attribute| {
        if (req.parseVolts(attribute)) |v| return v;
    }
    return null;
}

// ── (max-distance …) ──────────────────────────────────────────────────────

/// A placement rule, reported here and measured on the saved layout.
///
/// The netlist half is not nothing: a rule whose net carries no matching
/// passive at all can never be satisfied by any placement, and saying so at
/// `netlisp check` time is strictly better than waiting for a board. Every
/// other case is handed to the `req-distance-far` lint, and the message names
/// it so a reader knows where the verdict actually lives.
pub fn evalMaxDistance(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: MaxDistanceCheck,
) Result {
    const net = req.netForPinFn(eval, block, inst, check.pin) orelse
        return req.fail(allocator, pin_unresolved_msg, .{check.pin});

    var count: usize = 0;
    var first: []const u8 = "";
    for (block.instances) |c| {
        if (!matchesDistanceFilter(c, check)) continue;
        if (!req.instancePinOnNet(block, c, net)) continue;
        count += 1;
        if (first.len == 0) first = c.ref_des;
    }
    if (count == 0) return req.fail(
        allocator,
        "no {s} on net {s} to place within {d:.3} mm of pin '{s}' — no layout can satisfy this",
        .{ kindWord(check.kind), req.netBase(net), check.max_mm, check.pin },
    );
    return layoutDeferred(
        allocator,
        "layout rule: the nearest {s} on {s} ({d} candidate(s), e.g. {s}) must sit within " ++
            "{d:.3} mm of pin '{s}' — measured on the saved layout by the `req-distance-far` lint",
        .{ kindWord(check.kind), req.netBase(net), count, first, check.max_mm, check.pin },
    );
}

/// True when `c` is a passive of the rule's class whose value falls inside the
/// rule's window. Shared by the build-time verdict and `resolveDistanceRules`,
/// so the candidates a message names are exactly the ones the lint measures.
fn matchesDistanceFilter(c: Instance, check: MaxDistanceCheck) bool {
    // A ferrite (F) is an inductor for the purposes of "the element in series
    // with this pin", which is how every datasheet rule of this shape reads.
    const series: env.SeriesKind = switch (if (c.ref_des.len == 0) 0 else c.ref_des[0]) {
        'C' => .C,
        'R' => .R,
        'L', 'F' => .L,
        else => return false,
    };
    const wanted: ?env.SeriesKind = switch (check.kind) {
        .C => .C,
        .R => .R,
        .L => .L,
        .any => null,
    };
    if (wanted) |k| if (k != series) return false;
    if (check.min_value == null and check.max_value == null) return true;
    const value = req.parseValueFor(series, c.value) orelse return false;
    if (check.min_value) |lo| if (value < lo) return false;
    if (check.max_value) |hi| if (value > hi) return false;
    return true;
}

/// Human spelling of the class filter, for messages and for the lint's own
/// `what` text.
fn kindWord(kind: env.DistanceKind) []const u8 {
    return switch (kind) {
        .C => "capacitor",
        .R => "resistor",
        .L => "inductor/ferrite",
        .any => "passive",
    };
}

// ── (sequence …) ──────────────────────────────────────────────────────────

/// Judge "rail A must come up before rail B" against the enable-graph order
/// `eval/power_sequencing` derives.
///
/// Three outcomes, and the middle one is the point: a proven earlier order
/// passes, a proven later order is an error, and everything the enable graph
/// leaves undetermined — including two rails it puts at the same order, which
/// means neither gates the other — is unproven, with the message naming what
/// would settle it.
pub fn evalSequence(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    check: SequenceCheck,
) Result {
    const net_a = req.netForPinFn(eval, block, inst, check.pin_a) orelse
        return req.fail(allocator, pin_unresolved_msg, .{check.pin_a});
    const net_b = req.netForPinFn(eval, block, inst, check.pin_b) orelse
        return req.fail(allocator, pin_unresolved_msg, .{check.pin_b});
    const rail_a = req.netBase(net_a);
    const rail_b = req.netBase(net_b);
    if (std.mem.eql(u8, rail_a, rail_b)) return req.fail(
        allocator,
        "pins '{s}' and '{s}' are both on {s} — one rail cannot precede itself",
        .{ check.pin_a, check.pin_b, rail_a },
    );

    const rows = power_sequencing.analyze(allocator, block) catch
        return unproven(allocator, "power-sequencing analysis ran out of memory", .{});
    defer allocator.free(rows);

    const order_a = orderOf(rows, rail_a) orelse return unprovenOrder(allocator, rail_a, rail_b, rail_a);
    const order_b = orderOf(rows, rail_b) orelse return unprovenOrder(allocator, rail_a, rail_b, rail_b);
    if (order_a == order_b) return unproven(
        allocator,
        "{s} and {s} are both at power-up order {d} — the enable graph puts neither ahead " ++
            "of the other; tie one regulator's (enable …) to the other rail (or its PG) to prove it",
        .{ rail_a, rail_b, order_a },
    );
    if (order_a > order_b) return req.fail(
        allocator,
        "{s} comes up at order {d}, after {s} at order {d} — the datasheet requires the reverse{s}",
        .{ rail_a, order_a, rail_b, order_b, marginNote(check) },
    );
    return req.passMsg(
        allocator,
        "{s} (order {d}) comes up before {s} (order {d}){s}",
        .{ rail_a, order_a, rail_b, order_b, marginNote(check) },
    );
}

/// `margin-ms` is reported wherever the verdict is, and explicitly labelled as
/// unenforced: `SequenceRow` carries a topological order, not a ramp time, so
/// there is nothing in the model a millisecond could be compared against.
fn marginNote(check: SequenceCheck) []const u8 {
    return if (check.margin_ms > 0)
        " (the declared margin-ms is recorded only — the sequencing model carries no timing)"
    else
        "";
}

fn unprovenOrder(
    allocator: std.mem.Allocator,
    rail_a: []const u8,
    rail_b: []const u8,
    missing: []const u8,
) Result {
    return unproven(
        allocator,
        "the power-up order of {s} relative to {s} is undetermined: {s} is not sourced by a " ++
            "sub-block output port this design can order. Give its regulator a `(port … out " ++
            "(nominal …) (enable \"NET\"))`, or chain it off the upstream rail's PG, to prove it",
        .{ rail_a, rail_b, missing },
    );
}

fn orderOf(rows: []const power_sequencing.SequenceRow, rail: []const u8) ?u32 {
    for (rows) |row| {
        if (std.ascii.eqlIgnoreCase(row.rail, rail)) return row.order;
    }
    return null;
}

// ── Layout-rule resolution ────────────────────────────────────────────────

/// Resolve every `(check (max-distance …))` on every placed part into the
/// `DistanceRule` the placement layer measures — the exact pad, and the exact
/// set of passives that already satisfy the kind/value filter on that pad's
/// net.
///
/// This is a post-build pass for the same two reasons
/// `builders.resolveNearTargets` is: the pinout that gives a function name
/// meaning is only loadable from the evaluator, and the candidate ref-des are
/// only final after `ids.autoAssignSubBlockRefDes` has renumbered the tree. It
/// recurses so a module's own parts are resolved in the ref-des space the
/// parent gave them, and re-running over a sub-block simply replaces the
/// stale rules that block computed during its own evaluation — the replaced
/// slice is abandoned rather than freed, matching this evaluator's
/// allocate-and-never-free contract for design-lifetime data.
///
/// Resolving here rather than in the lint is deliberate: it keeps the
/// placement layer free of pinout loading and component-value parsing, the
/// same "resolve once, share the answer" contract `placement/near_bind.zig`
/// documents for `(near …)`.
pub fn resolveDistanceRules(eval: *Evaluator, block: *const DesignBlock) void {
    for (@as([]Instance, @constCast(block.instances))) |*inst| {
        if (inst.requirements.len == 0) continue;
        var rules: std.ArrayList(env.DistanceRule) = .empty;
        for (inst.requirements) |requirement| {
            const check = requirement.check orelse continue;
            const distance = switch (check) {
                .max_distance => |d| d,
                else => continue,
            };
            const rule = resolveOneRule(eval, block, inst.*, requirement.id, distance) orelse continue;
            rules.append(eval.allocator, rule) catch break;
        }
        inst.distance_rules = rules.toOwnedSlice(eval.allocator) catch &.{};
    }
    for (block.sub_blocks) |sb| resolveDistanceRules(eval, sb.block);
}

fn resolveOneRule(
    eval: *Evaluator,
    block: *const DesignBlock,
    inst: Instance,
    req_id: []const u8,
    check: MaxDistanceCheck,
) ?env.DistanceRule {
    const located = req.padAndNetForPin(eval, block, inst, check.pin) orelse return null;
    var candidates: std.ArrayList([]const u8) = .empty;
    for (block.instances) |c| {
        if (!matchesDistanceFilter(c, check)) continue;
        if (!req.instancePinOnNet(block, c, located.net)) continue;
        candidates.append(eval.allocator, c.ref_des) catch break;
    }
    return .{
        .req_id = req_id,
        .pad = located.pad,
        .candidates = candidates.toOwnedSlice(eval.allocator) catch &.{},
        .max_mm = check.max_mm,
        .what = filterText(eval.allocator, check),
    };
}

/// `capacitor` / `resistor in [1.000, 10.000] ohms` — the filter as a reader
/// sees it, built once so the ERC message and the lint message agree.
fn filterText(allocator: std.mem.Allocator, check: MaxDistanceCheck) []const u8 {
    const word = kindWord(check.kind);
    const unit = unitWord(check.kind);
    if (check.min_value) |lo| {
        if (check.max_value) |hi| return std.fmt.allocPrint(
            allocator,
            "{s} in [{d:.3}, {d:.3}] {s}",
            .{ word, lo, hi, unit },
        ) catch word;
        return std.fmt.allocPrint(allocator, "{s} ≥ {d:.3} {s}", .{ word, lo, unit }) catch word;
    }
    if (check.max_value) |hi| {
        return std.fmt.allocPrint(allocator, "{s} ≤ {d:.3} {s}", .{ word, hi, unit }) catch word;
    }
    return word;
}

/// Natural unit of the kind's value window. `any` has none — a mixed-class
/// rule is only ever written without value bounds, and `filterText` never
/// reaches this for it.
fn unitWord(kind: env.DistanceKind) []const u8 {
    return switch (kind) {
        .C => "µF",
        .R => "Ω",
        .L => "µH",
        .any => "(mixed units)",
    };
}
