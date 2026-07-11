const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const env_mod = @import("eval/env.zig");
const na = @import("eval/net_analysis.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const parser_mod = @import("sexpr/parser.zig");
const json_writer = @import("json_writer.zig");
const numeric = @import("numeric.zig");
const checks = @import("checks.zig");
const module_policy = @import("placement/module_policy.zig");
const pin_roles = @import("placement/pin_roles.zig");
const collect = @import("diagram/collect.zig");
const lod = @import("diagram/lod.zig");
const membership = @import("diagram/membership.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;

pub const Severity = checks.Severity;

// ── Constants ─────────────────────────────────────────────────────
const VOLTAGE_MISMATCH_TOLERANCE_V: f64 = 0.01;
const PERCENT_MULTIPLIER: f64 = 100.0;
/// Below this many diagram blocks the grouping rule doesn't apply — a tiny
/// power/module design (a buck + its passives) reads fine without `(group …)`
/// regions, so only real boards get flagged. Mirrors the "≥5 blocks" scope.
const GROUP_COVERAGE_MIN_BLOCKS: u32 = 5;
/// How many ungrouped block names to spell out in the violation before
/// summarising the rest as "+N more".
const GROUP_COVERAGE_NAME_LIMIT: usize = 6;

/// Tag identifying which electrical-rule check produced a `Violation`. The
/// review UI groups findings by this kind so users can scan all
/// power-budget warnings or all floating nets in one cluster.
pub const ViolationKind = enum {
    duplicate_refdes,
    floating_net,
    unconnected_pin,
    no_connect,
    missing_value,
    missing_footprint,
    voltage_mismatch,
    missing_decoupling,
    decoupling_unbound,
    strap_tied_to_rail,
    power_no_cap,
    concept_remaining,
    pin_multi_net,
    pin_function_unsupported,
    pin_function_required,
    power_budget,
    test_point_missing,
    source_unused,
    rail_voltage_unresolved,
    sequence_cycle,
    voltage_domain_incompatible,
    missing_requirements,
    layout_class_inferred,
    components_not_grouped,
    verification_orphaned,
};

/// One electrical-rule-check finding. `kind` selects the rule, `severity`
/// drives the UI colouring (error/warning/info), and `ref_des`/`net` carry
/// the offending entity so the schematic viewer can jump straight to it.
pub const Violation = struct {
    kind: ViolationKind,
    severity: Severity,
    message: []const u8,
    /// Component ref_des involved (empty if N/A).
    ref_des: []const u8 = "",
    /// Net name involved (empty if N/A).
    net: []const u8 = "",
};

/// Run all ERC checks on a design block and return violations.
/// `project_dir` is used to locate pinout files for the pin-function check; pass
/// an empty slice to skip that check when the project layout isn't available.
pub fn runErc(allocator: std.mem.Allocator, block: *const DesignBlock, project_dir: []const u8) std.mem.Allocator.Error![]const Violation {
    var violations: std.ArrayList(Violation) = .empty;

    try checkDuplicateRefDes(allocator, block, &violations);
    try checkPinMultiNet(allocator, block, &violations);
    try checkFloatingNets(allocator, block, &violations);
    try checkUnconnectedPorts(allocator, block, &violations);
    try checkMissingValues(allocator, block, &violations);
    try checkMissingFootprints(allocator, block, &violations);
    try checkMissingDecoupling(allocator, block, &violations);
    if (project_dir.len > 0) try checkDecouplingBinding(allocator, block, project_dir, &violations);
    if (project_dir.len > 0) try checkStrapTies(allocator, block, project_dir, &violations);
    if (project_dir.len > 0) try checkNoConnects(allocator, block, project_dir, &violations);
    try checkVoltageMismatches(allocator, block, &violations);
    try checkUnconnectedPowerPins(allocator, block, project_dir, &violations);
    try checkConceptSections(allocator, block, &violations);
    try checkPowerBudget(allocator, block, &violations);
    try checkTestPointCoverage(allocator, block, &violations);
    try checkPowerTreeIntegrity(allocator, block, &violations);
    try checkSequencingCycles(allocator, block, &violations);
    try checkVoltageDomainCompat(allocator, block, &violations);
    try checkMissingRequirements(allocator, block, &violations);
    try checkLayoutClasses(allocator, block, &violations);
    try checkComponentGrouping(allocator, block, &violations);
    try checkOrphanedVerifications(allocator, block, &violations);
    if (project_dir.len > 0) try checkPinFunctions(allocator, block, project_dir, &violations);

    return violations.items;
}

/// Flag active ICs whose library component declares no `(requirement …)` rules.
/// Component requirements are the design's record that a part was reviewed
/// against its datasheet, so an undocumented functional IC is the most common
/// review gap — a `warning` the schematic page and review doc surface so the
/// author can fill it in. Scope is the hub class the schematic renders as boxes
/// (ICs, connectors, transistors — `isActiveIcRefDes`); passive spokes
/// (R/C/L/F/D), `(ignore-requirements)` support parts, test points, and
/// passive-class components (ESD arrays, EMI filters) are exempt. Recurses
/// sub-blocks so a module's ICs are judged too, and deduplicates by component
/// so a part used N times warns once.
fn checkMissingRequirements(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);
    try collectMissingRequirements(allocator, block, &seen, violations);
}

fn collectMissingRequirements(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    seen: *std.StringHashMapUnmanaged(void),
    violations: *std.ArrayList(Violation),
) std.mem.Allocator.Error!void {
    for (block.instances) |inst| {
        if (!isActiveIcRefDes(inst.ref_des)) continue;
        if (inst.component.len == 0) continue;
        if (inst.requirements_ignored) continue;
        if (isPassiveComponent(inst.component)) continue;
        if (env_mod.isTestPoint(inst.component)) continue;
        if (inst.requirements.len > 0) continue;
        const gop = try seen.getOrPut(allocator, inst.component);
        if (gop.found_existing) continue;
        const msg = std.fmt.allocPrint(
            allocator,
            "IC \"{s}\" ({s}) declares no component requirements — add (requirement …) " ++
                "rules to lib/components/{s}.sexp so the part is documented against its datasheet",
            .{ inst.ref_des, inst.component, inst.component },
        ) catch continue;
        try violations.append(allocator, .{
            .kind = .missing_requirements,
            .severity = .warning,
            .message = msg,
            .ref_des = inst.ref_des,
        });
    }
    for (block.sub_blocks) |sb| try collectMissingRequirements(allocator, sb.block, seen, violations);
}

/// The requirements-warning scope: ICs (`U`) and discrete transistors (`Q`).
/// Connectors (`J`/`P`/`X`), passives (`R`/`C`/`L`/`F`/`D`), and other
/// electromechanical / mechanical parts (switches, encoders, crystals, relays,
/// …) carry no datasheet requirement rules, so they are exempt — only active
/// semiconductors are nagged to declare requirements.
fn isActiveIcRefDes(ref_des: []const u8) bool {
    if (ref_des.len == 0) return false;
    return switch (ref_des[0]) {
        'U', 'Q' => true,
        else => false,
    };
}

/// Surface the heuristic net-criticality classification the PCB placer will use,
/// so the author can SEE a wrong guess instead of discovering it as a bad board.
/// Each net whose *name* reads as a layout-critical class (input rail, switch
/// node, clock, RF, feedback, analog — `module_policy.isInterestingClass`) gets
/// one `info` row naming the class and the `(module-policy (net-class …))`
/// override. Name-only (`classifyNetName`), so it runs on the netlist with no
/// placement solve; the placement-aware view (incl. per-hub ModuleClass) stays
/// on `/api/pcb-describe`. Ground/power/plain-signal nets are intentionally
/// silent — they are the bulk and add no signal.
fn checkLayoutClasses(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    for (block.nets) |net| {
        // Skip the auto-generated `<rail>.<ic>.<pad>` bypass-stub sub-nets — they
        // are an internal per-pad detail of a rail that is itself surfaced, and
        // their munged names trip the name heuristics (e.g. "V08CAP" → input_rail).
        if (std.mem.indexOfScalar(u8, net.name, '.') != null) continue;
        const cls = module_policy.classifyNetName(net.name);
        if (!module_policy.isInterestingClass(cls)) continue;
        const msg = std.fmt.allocPrint(
            allocator,
            "Net \"{s}\" reads as {s} for PCB layout (drives loop weighting / routing order) — " ++
                "if that's wrong, pin it with (module-policy (net-class \"{s}\" <class>))",
            .{ net.name, @tagName(cls), net.name },
        ) catch return;
        try violations.append(allocator, .{
            .kind = .layout_class_inferred,
            .severity = .info,
            .message = msg,
            .net = net.name,
        });
    }
}

/// Flag a design whose functional blocks aren't split into `(group …)` cohesion
/// clusters (the barracuda-base idiom). Builds the same diagram graph the
/// schematic Block-overview view uses — so "ungrouped" means exactly what that
/// view's "Other" bucket shows — and warns once a real board (≥ the block
/// floor) leaves any block out of every cluster. Tiny power/module designs stay
/// exempt: grouping a buck + its handful of passives adds no legibility.
///
/// Severity is `warning`, not `error`: grouping is purely organizational (it
/// only shapes the block-overview render), so it must not fail `build`/`check`
/// or redden the home-page health chip the way an electrical fault does.
fn checkComponentGrouping(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    const attachments = membership.computeSubBlockAttachments(allocator, block) catch return;
    defer allocator.free(attachments);
    // project_dir "" — this check only needs group coverage, not the starred-layout
    // maturity lookup, so skip the sidecar reads.
    var graph = collect.collectGraph(allocator, block, attachments, "") catch return;
    defer graph.deinit(allocator);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cov = lod.groupCoverage(arena, &graph) catch return;
    if (cov.total < GROUP_COVERAGE_MIN_BLOCKS or cov.ungrouped.len == 0) return;

    // Spell out the first few offenders, then summarise the tail.
    const shown = @min(cov.ungrouped.len, GROUP_COVERAGE_NAME_LIMIT);
    var names: std.ArrayList(u8) = .empty;
    for (cov.ungrouped[0..shown], 0..) |label, i| {
        if (i > 0) names.appendSlice(arena, ", ") catch return;
        names.appendSlice(arena, label) catch return;
    }
    const tail = if (cov.ungrouped.len > shown)
        std.fmt.allocPrint(arena, ", +{d} more", .{cov.ungrouped.len - shown}) catch ""
    else
        "";
    const msg = std.fmt.allocPrint(
        allocator,
        "{d} of {d} blocks are outside any (group …) cluster: {s}{s} — split components into " ++
            "(group …) regions (like barracuda-base) for a scannable block view",
        .{ cov.ungrouped.len, cov.total, names.items, tail },
    ) catch return;
    try violations.append(allocator, .{
        .kind = .components_not_grouped,
        .severity = .warning,
        .message = msg,
    });
}

/// Flag any `(verifies …)` sign-off that resolves to no live requirement — a
/// dangling human sign-off. `req_checks.applyVerifications` silently drops one
/// whose target ref-des/id matches no instance, or whose `req_id` matches no
/// requirement on that instance, so a ref-des renumber (MEMORY: "ref-des drift
/// orphans the whole `<design>.checks.sexp`") flips VERIFIED requirements back
/// to PENDING with zero indication. This surfaces each unmatched sign-off as a
/// `warning` (not an error — it never masks a real defect; a passing/failing
/// requirement is judged by its own `(check …)`) so the drift is visible in the
/// review doc and the home-page health chip.
///
/// Mirrors `req_checks.applyOneVerification`'s resolution exactly (by stable id
/// when `target_id` is set, else by ref-des; then the `req_id` must match a
/// requirement on that instance), recursing sub-blocks the same way, so a
/// verification counts as matched iff `applyVerifications` would have applied it.
fn checkOrphanedVerifications(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    for (block.verifications) |v| {
        if (verificationResolves(block, v)) continue;
        const target = if (v.target_id.len > 0) v.target_id else v.ref_des;
        const msg = std.fmt.allocPrint(
            allocator,
            "Dangling (verifies …) sign-off: no live requirement \"{s}\" on \"{s}\" — " ++
                "a ref-des renumber or a removed requirement orphaned it, so the sign-off " ++
                "no longer marks anything VERIFIED. Re-target it (by (id …) to survive renumbers) or remove it",
            .{ v.req_id, target },
        ) catch continue;
        try violations.append(allocator, .{
            .kind = .verification_orphaned,
            .severity = .warning,
            .message = msg,
            .ref_des = v.ref_des,
        });
    }
}

/// True iff verification `v` resolves to a live `(ref_des_or_id, req_id)` pair
/// somewhere in `block` or its sub-blocks — the exact predicate
/// `req_checks.applyOneVerification` uses to decide whether to apply it.
fn verificationResolves(block: *const DesignBlock, v: env_mod.Verification) bool {
    for (block.instances) |inst| {
        const matched = if (v.target_id.len > 0)
            std.mem.eql(u8, inst.id, v.target_id)
        else
            std.mem.eql(u8, inst.ref_des, v.ref_des);
        if (!matched) continue;
        for (inst.requirements) |r| {
            if (std.mem.eql(u8, r.id, v.req_id)) return true;
        }
        // Instance matched but this req_id is stale — keep scanning other
        // instances (a ref-des can repeat across module instantiations).
    }
    for (block.sub_blocks) |sb| {
        if (verificationResolves(sb.block, v)) return true;
    }
    return false;
}

/// For each net, gather pins whose component library declared electrical
/// levels and compare driver outputs against receiver thresholds. Flags
/// nets where the worst driver high (lowest v_oh_typ across drivers)
/// can't meet the worst receiver high threshold (highest v_ih_min across
/// receivers). Pins without electrical metadata are silently skipped so
/// the check starts low-noise and grows useful as the library is
/// annotated.
fn checkVoltageDomainCompat(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    try checkBlockVoltageDomainCompat(allocator, block, violations);
    // Recurse sub-blocks so a module's driver→receiver levels are judged in
    // its own net namespace (its pins/ports, not the parent's).
    for (block.sub_blocks) |sb| try checkVoltageDomainCompat(allocator, sb.block, violations);
}

fn checkBlockVoltageDomainCompat(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    // Build ref_des → electrical lookup so we can resolve a pin's
    // declarations in O(1) inside the net-walk below. Skips instances
    // without electrical data — most of the library, for now.
    var ref_to_elec: std.StringHashMapUnmanaged([]const env_mod.ElectricalDecl) = .empty;
    defer ref_to_elec.deinit(allocator);
    for (block.instances) |inst| {
        if (inst.electrical.len == 0) continue;
        try ref_to_elec.put(allocator, inst.ref_des, inst.electrical);
    }

    // Build net → list-of-port-electrical-decls so each net's compatibility
    // check folds in boundary-port declarations alongside component pins.
    // Section ports use port.name as the net identifier; top-level ports
    // carry an explicit `net` field. Both feed the same map.
    var net_to_port_elec: std.StringHashMapUnmanaged(std.ArrayList(env_mod.ElectricalDecl)) = .empty;
    defer {
        var it = net_to_port_elec.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        net_to_port_elec.deinit(allocator);
    }

    for (block.ports) |p| {
        const e = p.electrical orelse continue;
        if (e.electrical_type == null) continue;
        const base = na.baseNetName(p.net);
        const gop = try net_to_port_elec.getOrPut(allocator, base);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, e);
    }
    for (block.sections) |sec| {
        for (sec.ports) |sp| {
            const e = sp.electrical orelse continue;
            if (e.electrical_type == null) continue;
            const base = na.baseNetName(sp.name);
            const gop = try net_to_port_elec.getOrPut(allocator, base);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, e);
        }
    }

    if (ref_to_elec.count() == 0 and net_to_port_elec.count() == 0) return;

    for (block.nets) |net| {
        // Skip GND / power-only nets — the driver/receiver distinction
        // doesn't apply.
        const base = na.baseNetName(net.name);
        if (std.mem.eql(u8, base, "GND")) continue;

        var worst_driver_high: ?f64 = null;
        var worst_receiver_high_threshold: ?f64 = null;

        for (net.pins) |pin| {
            const elec = ref_to_elec.get(pin.ref_des) orelse continue;
            const decl = findPinDecl(elec, pin.pin) orelse continue;
            applyDecl(decl, &worst_driver_high, &worst_receiver_high_threshold);
        }

        if (net_to_port_elec.get(base)) |port_decls| {
            for (port_decls.items) |decl| {
                applyDecl(decl, &worst_driver_high, &worst_receiver_high_threshold);
            }
        }

        if (worst_driver_high) |drv| {
            if (worst_receiver_high_threshold) |rcv| {
                if (drv < rcv) {
                    const msg = std.fmt.allocPrint(
                        allocator,
                        "Net \"{s}\": driver high level {d:.2}V is below receiver high threshold {d:.2}V — a level shifter is required",
                        .{ base, drv, rcv },
                    ) catch continue;
                    try violations.append(allocator, .{
                        .kind = .voltage_domain_incompatible,
                        .severity = .@"error",
                        .message = msg,
                        .net = base,
                    });
                }
            }
        }
    }
}

/// Fold one electrical declaration into the running worst-driver / worst-
/// receiver tallies for a net. Pins and ports share this logic so port-level
/// boundary contracts (e.g. "this mezz pin is 3.3 V CMOS") participate in the
/// same driver-meets-threshold compare as component pins.
fn applyDecl(decl: env_mod.ElectricalDecl, worst_driver_high: *?f64, worst_receiver_high_threshold: *?f64) void {
    const t = decl.electrical_type orelse return;
    const is_driver = t == .output or t == .io or t == .power_out;
    const is_receiver = t == .input or t == .io or t == .power_in;

    if (is_driver) {
        if (decl.v_oh_typ) |v| {
            if (worst_driver_high.* == null or v < worst_driver_high.*.?) {
                worst_driver_high.* = v;
            }
        }
    }
    if (is_receiver) {
        if (decl.v_ih_min) |v| {
            if (worst_receiver_high_threshold.* == null or v > worst_receiver_high_threshold.*.?) {
                worst_receiver_high_threshold.* = v;
            }
        }
    }
}

/// Linear scan to find an `ElectricalDecl` whose `pin` field matches the
/// given pin id. Pin counts on most parts are O(<200), so the linear
/// scan is fine; if a hot path ever needs faster lookup, build a temp
/// hashmap in `checkVoltageDomainCompat`.
fn findPinDecl(decls: []const env_mod.ElectricalDecl, pin_id: []const u8) ?env_mod.ElectricalDecl {
    for (decls) |d| {
        if (std.mem.eql(u8, d.pin, pin_id)) return d;
    }
    return null;
}

/// Detect cycles in the per-rail enable-net dependency graph emitted by
/// `power_sequencing.analyze`. The existing assignOrder uses a fixed-point
/// iteration with an 8-pass cap, so cycles silently produce stale ordering
/// instead of failing — this check fills that gap by chasing each rail's
/// dependency chain and reporting any rail that participates in a cycle.
fn checkSequencingCycles(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    const rows = try power_sequencing.analyze(allocator, block);
    defer allocator.free(rows);

    // Build rail → depends_on lookup. Rails with no dependency contribute
    // nothing to a cycle and can be skipped during chain traversal.
    var deps: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer deps.deinit(allocator);
    for (rows) |r| {
        if (r.depends_on.len == 0) continue;
        try deps.put(allocator, r.rail, r.depends_on);
    }

    var reported: std.StringHashMapUnmanaged(void) = .empty;
    defer reported.deinit(allocator);

    for (rows) |r| {
        if (r.depends_on.len == 0) continue;
        if (reported.contains(r.rail)) continue;

        var visited: std.StringHashMapUnmanaged(void) = .empty;
        defer visited.deinit(allocator);

        var cur = r.rail;
        try visited.put(allocator, cur, {});
        while (deps.get(cur)) |next| {
            if (visited.contains(next)) {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Power-sequencing cycle reaches rail \"{s}\" — review (enable …) declarations on regulators feeding back into this loop",
                    .{r.rail},
                ) catch break;
                try violations.append(allocator, .{
                    .kind = .sequence_cycle,
                    .severity = .@"error",
                    .message = msg,
                    .net = r.rail,
                });
                try reported.put(allocator, r.rail, {});
                break;
            }
            try visited.put(allocator, next, {});
            cur = next;
        }
    }
}

/// Walk the derived `block.rails` graph and report rails whose declarations
/// are incomplete or inconsistent. Phase 2B covers two checks — the other
/// two listed in the plan (orphan_rail and regulator_loop) require
/// extensions to `eval/rails.build` (consumer-only rail emission and
/// cascaded upstream-rail tracking) that land alongside Phase 2C.
fn checkPowerTreeIntegrity(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    for (block.rails) |rail| {
        // source_unused: rail has a declared regulator but no downstream
        // pins on its net or any ferrite-bridged alias.
        if (rail.source_ref_des.len > 0) {
            const has_consumer = railHasConsumer(block, rail);
            if (!has_consumer) {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Rail \"{s}\" sourced by {s} has no downstream pin connections — verify the regulator output is actually wired up",
                    .{ rail.name, rail.source_ref_des },
                ) catch continue;
                try violations.append(allocator, .{
                    .kind = .source_unused,
                    .severity = .warning,
                    .message = msg,
                    .net = rail.name,
                });
            }
        }

        // rail_voltage_unresolved: nothing in the fallback cascade declared
        // a nominal voltage. Information-level — analyses that need
        // voltage (power-budget back-compute, voltage-domain ERC) will
        // skip the rail, so reviewers should know about it.
        if (rail.nominal == null) {
            const msg = std.fmt.allocPrint(
                allocator,
                "Rail \"{s}\" has no declared nominal voltage — add (nominal V) on the source port or a section power port",
                .{rail.name},
            ) catch continue;
            try violations.append(allocator, .{
                .kind = .rail_voltage_unresolved,
                .severity = .info,
                .message = msg,
                .net = rail.name,
            });
        }
    }
}

/// True iff the rail reaches at least one downstream consumer. A consumer is
/// either (a) a direct component pin on the rail's net (or a ferrite-bridged
/// alias), or (b) a sub-block input port the rail is wired into — e.g. a rail
/// that only feeds an LDO's VIN inside another sub-block. Empty rail names are
/// treated as absent (no consumer possible).
fn railHasConsumer(block: *const DesignBlock, rail: env_mod.PowerRail) bool {
    // (a) Direct component pins on the rail's net or a ferrite alias.
    for (block.nets) |net| {
        if (net.pins.len == 0) continue;
        const base = na.baseNetName(net.name);
        if (railNameMatches(rail, base)) return true;
    }
    // (b) Sub-block port consumers. A `(net "<rail>" "<sub>/<port>")` form is
    // stored as a NetTie linking the rail name to the sub-block port path; such
    // a net carries no direct PinRef, so the loop above misses it. A tie to a
    // port path *other than the rail's own source port* means the rail is wired
    // into a downstream sub-block (the regulator output is genuinely used).
    for (block.net_ties) |nt| {
        const port_path = if (railNameMatches(rail, na.baseNetName(nt.a)))
            nt.b
        else if (railNameMatches(rail, na.baseNetName(nt.b)))
            nt.a
        else
            continue;
        // Only a sub-block port path (contains '/') counts here; plain-net ties
        // are already covered by the direct-pin loop above.
        if (std.mem.indexOfScalar(u8, port_path, '/') == null) continue;
        // Skip the rail's own source port — that is the producer, not a load.
        if (rail.source_path.len > 0 and std.mem.eql(u8, port_path, rail.source_path)) continue;
        return true;
    }
    return false;
}

/// True iff `base` equals the rail's canonical name or any ferrite-bridged alias.
fn railNameMatches(rail: env_mod.PowerRail, base: []const u8) bool {
    if (std.mem.eql(u8, base, rail.name)) return true;
    for (rail.aliases) |alias| {
        if (std.mem.eql(u8, base, alias)) return true;
    }
    return false;
}

/// Flag any `PowerRail` in `block.rails` that has no test point on its net
/// (or any of its ferrite-bridged aliases). Considers both first-class
/// `(test-point …)` declarations and legacy `(instance "TPx" testpoint …)`
/// instances so the migration window between the two sources is seamless.
///
/// Severity is `warning` — a missing rail test point isn't an electrical
/// fault, but it makes bring-up harder, so reviewers should see it on the
/// review page.
fn checkTestPointCoverage(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    // Collect the set of nets that have a test point on them, from both
    // sources (first-class form + legacy testpoint-component instances).
    var tp_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer tp_nets.deinit(allocator);

    for (block.test_points) |tp| {
        try tp_nets.put(allocator, tp.net, {});
    }
    for (block.instances) |inst| {
        // `env_mod.isTestPoint` also matches `testpoint-*` variants (e.g. an SMD
        // test point), so a rail probed only by a `testpoint-smd` isn't falsely
        // reported "has no test point" while the review table simultaneously
        // lists it (that table is isTestPoint-based too).
        if (!env_mod.isTestPoint(inst.component)) continue;
        for (block.nets) |net| {
            for (net.pins) |pin| {
                if (!std.mem.eql(u8, pin.ref_des, inst.ref_des)) continue;
                if (!std.mem.eql(u8, pin.pin, "1")) continue;
                try tp_nets.put(allocator, net.name, {});
            }
        }
    }

    for (block.rails) |rail| {
        if (tp_nets.contains(rail.name)) continue;
        var covered_via_alias = false;
        for (rail.aliases) |alias| {
            if (tp_nets.contains(alias)) {
                covered_via_alias = true;
                break;
            }
        }
        if (covered_via_alias) continue;

        const msg = std.fmt.allocPrint(
            allocator,
            "Power rail \"{s}\" has no test point — add (test-point \"TPx\" \"{s}\") to ease bring-up",
            .{ rail.name, rail.name },
        ) catch continue;
        try violations.append(allocator, .{
            .kind = .test_point_missing,
            .severity = .warning,
            .message = msg,
            .net = rail.name,
        });
    }
}

/// Check for duplicate reference designators across the full flattened design.
/// Recurses sub-blocks (via `collectAllInstances`) so a module-local ref-des
/// that collides with a top-level part — or with a part in another instantiation
/// of the same module — is caught, matching the flattened-design contract the
/// KiCad netlist export flattens to.
fn checkDuplicateRefDes(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;
    defer counts.deinit(allocator);

    const all = try collectAllInstances(allocator, block);
    defer allocator.free(all);
    for (all) |inst| {
        if (inst.ref_des.len == 0) continue;
        const gop = counts.getOrPut(allocator, inst.ref_des) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += 1;
    }

    var iter = counts.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* > 1) {
            const msg = std.fmt.allocPrint(allocator, "Duplicate ref_des \"{s}\" ({d} instances)", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            try violations.append(allocator, .{
                .kind = .duplicate_refdes,
                .severity = .@"error",
                .message = msg,
                .ref_des = entry.key_ptr.*,
            });
        }
    }
}

/// Check for a single component pin attached to two or more distinct nets.
/// Runs per block (recursing sub-blocks) so a module's pins are judged in
/// their own net namespace — a pin repeated across a parent net and a module
/// net after flattening isn't a genuine multi-net short.
fn checkPinMultiNet(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    try checkBlockPinMultiNet(allocator, block, violations);
    for (block.sub_blocks) |sb| try checkPinMultiNet(allocator, sb.block, violations);
}

fn checkBlockPinMultiNet(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    var pin_to_net: std.StringHashMapUnmanaged([]const u8) = .empty;
    var reported: std.StringHashMapUnmanaged(void) = .empty;

    for (block.nets) |net| {
        const base = na.baseNetName(net.name);
        for (net.pins) |p| {
            if (p.ref_des.len == 0) continue;
            const key = std.fmt.allocPrint(allocator, "{s}.{s}", .{ p.ref_des, p.pin }) catch continue;
            const gop = pin_to_net.getOrPut(allocator, key) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = base;
                continue;
            }
            if (std.mem.eql(u8, gop.value_ptr.*, base)) continue;
            if (reported.contains(key)) continue;
            try reported.put(allocator, key, {});
            const msg = std.fmt.allocPrint(
                allocator,
                "{s} pin {s} connected to multiple nets: \"{s}\" and \"{s}\"",
                .{ p.ref_des, p.pin, gop.value_ptr.*, base },
            ) catch continue;
            try violations.append(allocator, .{
                .kind = .pin_multi_net,
                .severity = .@"error",
                .message = msg,
                .ref_des = p.ref_des,
                .net = base,
            });
        }
    }
}

/// Check for nets with only a single connection (floating/dead-end).
fn checkFloatingNets(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    // Build port net set (these connect externally, not dead-ends)
    var port_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.ports) |port| {
        try port_nets.put(allocator, port.net, {});
        try port_nets.put(allocator, port.name, {});
    }

    // Also collect optional section ports — their nets are allowed to float
    var optional_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.sections) |sec| {
        try collectOptionalPortNets(allocator, &optional_nets, sec);
    }
    // Optional top-level ports
    for (block.ports) |port| {
        if (port.optional) try optional_nets.put(allocator, na.baseNetName(port.net), {});
    }

    // Also exclude nets that participate in net_ties (sub-block connections)
    var tied_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.net_ties) |nt| {
        const base_a = na.baseNetName(nt.a);
        const base_b = na.baseNetName(nt.b);
        try tied_nets.put(allocator, base_a, {});
        try tied_nets.put(allocator, base_b, {});
    }

    // Count pins per base net name
    var net_pin_counts: std.StringHashMapUnmanaged(u32) = .empty;
    for (block.nets) |net| {
        const base = na.baseNetName(net.name);
        if (port_nets.contains(base)) continue;
        if (tied_nets.contains(base)) continue;
        const gop = net_pin_counts.getOrPut(allocator, base) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += @intCast(net.pins.len);
    }

    var iter = net_pin_counts.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* == 1) {
            // Skip nets declared as optional ports
            if (optional_nets.contains(entry.key_ptr.*)) continue;
            const msg = std.fmt.allocPrint(allocator, "Floating net \"{s}\" — only one connection", .{entry.key_ptr.*}) catch continue;
            try violations.append(allocator, .{
                .kind = .floating_net,
                .severity = .warning,
                .message = msg,
                .net = entry.key_ptr.*,
            });
        }
    }
}

/// Check that required ports on sub-blocks are connected, and that
/// the parent design's own required ports have connections. Runs per block
/// (recursing sub-blocks) so a nested module's required port left unwired
/// inside a level-1 module is caught, not just the top block's direct
/// sub-block ports.
fn checkUnconnectedPorts(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    try checkBlockUnconnectedPorts(allocator, block, violations);
    for (block.sub_blocks) |sb| try checkUnconnectedPorts(allocator, sb.block, violations);
}

fn checkBlockUnconnectedPorts(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    // Build set of connected sub-block port paths from net_ties
    // Net ties look like: (net "VDD" "buck/VOUT" "ldo/VIN")
    // which creates net_ties: {a:"VDD", b:"buck/VOUT"}, {a:"VDD", b:"ldo/VIN"}
    var connected_paths: std.StringHashMapUnmanaged(void) = .empty;
    for (block.net_ties) |nt| {
        try connected_paths.put(allocator, nt.a, {});
        try connected_paths.put(allocator, nt.b, {});
    }

    // Check each sub-block's ports
    for (block.sub_blocks) |sb| {
        for (sb.block.ports) |port| {
            // Build the path as "sub_block_name/port_name"
            const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ sb.name, port.name }) catch continue;

            if (!connected_paths.contains(path)) {
                if (port.optional) {
                    // Optional port not connected — no violation
                    continue;
                }
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Required port \"{s}\" on sub-block \"{s}\" is not connected",
                    .{ port.name, sb.name },
                ) catch continue;
                try violations.append(allocator, .{
                    .kind = .unconnected_pin,
                    .severity = .@"error",
                    .message = msg,
                    .net = port.net,
                });
            }
        }
    }

    // Check the parent block's own required ports — they should have at least
    // one internal connection (via nets or net_ties)
    var connected_port_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.nets) |net| {
        const base = na.baseNetName(net.name);
        if (net.pins.len > 0) try connected_port_nets.put(allocator, base, {});
    }
    // Net ties also count as connections for parent ports
    for (block.net_ties) |nt| {
        try connected_port_nets.put(allocator, na.baseNetName(nt.a), {});
        try connected_port_nets.put(allocator, na.baseNetName(nt.b), {});
    }

    for (block.ports) |port| {
        const base = na.baseNetName(port.net);
        if (!connected_port_nets.contains(base)) {
            if (port.optional) continue;
            const msg = std.fmt.allocPrint(
                allocator,
                "Required port \"{s}\" has no internal connections",
                .{port.name},
            ) catch continue;
            try violations.append(allocator, .{
                .kind = .unconnected_pin,
                .severity = .@"error",
                .message = msg,
                .net = port.net,
            });
        }
    }
}

/// Check for instances missing a value (passives need values). Recurses
/// sub-blocks so a module-internal value-less passive is flagged too.
fn checkMissingValues(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    const all_instances = try collectAllInstances(allocator, block);
    defer allocator.free(all_instances);
    for (all_instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        // Passives (R, C, L) need values — unless the instance is a fixed
        // component already identified by MPN (e.g. a PS1608GT2-R50-T1
        // chip inductor imported from KiCad under its original "R" ref):
        // a part-number part has no free value left to declare.
        const prefix = na.refDesLocalPrefix(inst.ref_des);
        if ((prefix == 'R' or prefix == 'C' or prefix == 'L') and inst.value.len == 0) {
            if (hasNonEmptyProperty(inst, "mpn")) continue;
            const msg = std.fmt.allocPrint(allocator, "{s}: Missing value for {s}", .{ inst.ref_des, inst.component }) catch continue;
            try violations.append(allocator, .{
                .kind = .missing_value,
                .severity = .@"error",
                .message = msg,
                .ref_des = inst.ref_des,
            });
        }
    }
}

/// True when the instance carries a component property `key` with a
/// non-empty value (properties flow in from the lib component file).
fn hasNonEmptyProperty(inst: Instance, key: []const u8) bool {
    for (inst.properties) |prop| {
        if (std.mem.eql(u8, prop.key, key) and prop.value.len > 0) return true;
    }
    return false;
}

/// Check for instances missing a footprint. Recurses sub-blocks so a
/// module-internal footprint-less part is flagged too.
fn checkMissingFootprints(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    const all_instances = try collectAllInstances(allocator, block);
    defer allocator.free(all_instances);
    for (all_instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        if (inst.footprint.len == 0) {
            const msg = std.fmt.allocPrint(allocator, "{s}: Missing footprint", .{inst.ref_des}) catch continue;
            try violations.append(allocator, .{
                .kind = .missing_footprint,
                .severity = .warning,
                .message = msg,
                .ref_des = inst.ref_des,
            });
        }
    }
}

/// Check power nets connected to ICs but missing decoupling caps. Shares
/// its analysis with the eval-time validator — see `eval/net_analysis.zig`.
fn checkMissingDecoupling(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    const missing = try na.findMissingDecouplingNets(allocator, block);
    defer allocator.free(missing);
    for (missing) |base| {
        const msg = std.fmt.allocPrint(allocator, "Power net \"{s}\" connects to IC but has no decoupling cap", .{base}) catch continue;
        try violations.append(allocator, .{
            .kind = .missing_decoupling,
            .severity = .warning,
            .message = msg,
            .net = base,
        });
    }
}

/// Bulk-reservoir threshold: caps ≥ 4.7 µF serve the whole rail, not one pin, so
/// they're exempt from the per-pin binding requirement. Mirrors
/// `module_policy.BULK_FARADS` (kept local to avoid an eval→placement pub-API
/// dependency; both are stable physical constants).
const DECOUPLE_BULK_FARADS: f64 = 4.7e-6;

/// Require every HF decoupling cap on a *multi-supply-pad* rail to declare which
/// IC pin it serves — the netlist-level twin of the `decouple-unbound` layout
/// lint (`src/placement/layout_lint.zig`), as an ERC **error** so the requirement
/// gates `build`/`check`, the home-page health chips, the review doc, and the
/// `run_checks` MCP tool.
///
/// A cap is flagged when it is an unbound HF bypass cap (prefix `C`, < 4.7 µF,
/// with a ground leg + a single non-ground "power-leg" net) whose power-leg rail
/// lands on ≥ 2 of some hub IC's *supply* pads (config straps tied to the rail —
/// EN/PG/ILIM/… — are excluded via `pin_roles`, exactly as the placer's
/// `hubTargets` does). With ≥ 2 candidate pads the binding is ambiguous, so the
/// author must add `(decouples "IC" PIN)` / a `(decouple … per-pin)` form, or
/// `(decouples rail)` if the cap genuinely serves the whole rail.
///
/// Runs **per block** and recurses sub-blocks: the cap and the IC it decouples
/// live in the same module namespace, so a module's bypass cap is judged against
/// *its own* IC's pad count — not against an unrelated IC that merely shares a
/// board rail once the hierarchy is flattened (which would spuriously flag every
/// module cap on a shared `VDD`). This is also why violation strings can safely
/// point into the block (no flatten arena to outlive).
///
/// Exemptions (no error): bulk reservoirs (≥ 4.7 µF), single-supply-pad rails
/// (the target is unambiguous), caps already bound via `(decouples …)` /
/// `decouple_pin`, caps with a per-pin shorthand pad in their `origin_key`, and
/// `(decouples rail)` opt-outs. Needs `project_dir` to read `lib/pinouts` +
/// `lib/components` for the strap classification; skipped when the project
/// layout is unavailable (caller guards `project_dir.len > 0`).
fn checkDecouplingBinding(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var roles_cache = std.StringHashMapUnmanaged(pin_roles.PartRoles).empty;
    try checkBlockDecouplingBinding(allocator, arena, block, project_dir, &roles_cache, violations);
}

fn checkBlockDecouplingBinding(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    roles_cache: *std.StringHashMapUnmanaged(pin_roles.PartRoles),
    violations: *std.ArrayList(Violation),
) !void {
    for (block.instances) |cap| {
        if (na.refDesLocalPrefix(cap.ref_des) != 'C') continue; // capacitors only
        // Already bound? (decouples "IC" PIN) → decouple_pin; (decouples rail) →
        // rail opt-out; a (decouple … per-pin) cap carries its pad in origin_key.
        if (cap.decouple_pin.len > 0 or cap.decouple_rail) continue;
        if (decouplePinFromOrigin(cap.origin_key) != null) continue;
        // Bulk reservoirs serve the whole rail by nature → exempt.
        if (capFarads(cap.value) >= DECOUPLE_BULK_FARADS) continue;

        // Resolve the cap's legs: exactly one ground net + one non-ground
        // "power-leg" net. Anything else (no ground leg, two distinct power
        // legs, both pins shorted) is not a standard bypass cap → skip.
        var has_gnd = false;
        var pwr_net: ?[]const u8 = null;
        var multi_pwr = false;
        for (block.nets) |net| {
            var on_net = false;
            for (net.pins) |pn| {
                if (std.mem.eql(u8, pn.ref_des, cap.ref_des)) {
                    on_net = true;
                    break;
                }
            }
            if (!on_net) continue;
            if (pin_roles.isGroundFn(na.baseNetName(net.name))) {
                has_gnd = true;
            } else if (pwr_net) |p| {
                if (!std.mem.eql(u8, p, net.name)) multi_pwr = true;
            } else {
                pwr_net = net.name;
            }
        }
        if (multi_pwr or !has_gnd) continue;
        const rail = pwr_net orelse continue;

        if (!railLandsOnMultipleSupplyPads(block, arena, project_dir, roles_cache, rail, cap.ref_des))
            continue;

        const msg = std.fmt.allocPrint(
            allocator,
            "Decoupling cap \"{s}\" on rail \"{s}\" must declare which IC pin it serves — " ++
                "the rail lands on ≥2 supply pads, so the binding is ambiguous. Add " ++
                "(decouples \"IC\" PIN) or a (decouple … per-pin) form, or (decouples rail) " ++
                "if it serves the whole rail",
            .{ cap.ref_des, na.baseNetName(rail) },
        ) catch continue;
        try violations.append(allocator, .{
            .kind = .decoupling_unbound,
            .severity = .@"error",
            .message = msg,
            .ref_des = cap.ref_des,
            .net = na.baseNetName(rail),
        });
    }

    // A cap and the IC it decouples live in the same block namespace, so recurse
    // into each sub-block (module instantiation) and check it on its own terms.
    for (block.sub_blocks) |sb| {
        try checkBlockDecouplingBinding(allocator, arena, sb.block, project_dir, roles_cache, violations);
    }
}

/// True when `rail` lands on ≥2 *supply* pads of some hub on `block` — i.e. the
/// per-pin binding of a cap on that rail is ambiguous. Mirrors the placer's
/// `hubTargets`: a hub's supply pads on the net are its pads there minus config
/// straps (`pin_roles` `.strap`), keeping all if every pad is a strap so a rail
/// is never left targetless. A 2-pin passive can hold at most one pad on a given
/// net, so this naturally selects ICs/connectors. `cap_ref` (the cap under test)
/// is skipped.
fn railLandsOnMultipleSupplyPads(
    block: *const DesignBlock,
    arena: std.mem.Allocator,
    project_dir: []const u8,
    roles_cache: *std.StringHashMapUnmanaged(pin_roles.PartRoles),
    rail: []const u8,
    cap_ref: []const u8,
) bool {
    for (block.nets) |net| {
        if (!std.mem.eql(u8, net.name, rail)) continue;
        // Group this rail's pads by ref-des.
        var by_ref = std.StringHashMapUnmanaged(std.ArrayList([]const u8)).empty;
        for (net.pins) |pn| {
            if (pn.ref_des.len == 0 or std.mem.eql(u8, pn.ref_des, cap_ref)) continue;
            const gop = by_ref.getOrPut(arena, pn.ref_des) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.append(arena, pn.pin) catch continue;
        }
        var it = by_ref.iterator();
        while (it.next()) |entry| {
            const pads = entry.value_ptr.items;
            if (pads.len < 2) continue; // a single pad is never ambiguous
            const roles = rolesFor(arena, project_dir, roles_cache, componentOf(block, entry.key_ptr.*));
            var non_strap: usize = 0;
            for (pads) |pad| {
                if (roles.classOf(pad) != .strap) non_strap += 1;
            }
            // hubTargets keeps every pad when they're all straps, else only the
            // non-strap ones — so the supply count is one or the other.
            const supply = if (non_strap > 0) non_strap else pads.len;
            if (supply >= 2) return true;
        }
        return false;
    }
    return false;
}

/// Component name for `ref_des` among `block`'s own instances ("" if not found).
fn componentOf(block: *const DesignBlock, ref_des: []const u8) []const u8 {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) return inst.component;
    }
    return "";
}

/// Cached `pin_roles.load` keyed by component name.
fn rolesFor(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    cache: *std.StringHashMapUnmanaged(pin_roles.PartRoles),
    component: []const u8,
) pin_roles.PartRoles {
    if (component.len == 0) return .{};
    const gop = cache.getOrPut(arena, component) catch return .{};
    if (!gop.found_existing) gop.value_ptr.* = pin_roles.load(arena, project_dir, component);
    return gop.value_ptr.*;
}

/// The per-pin pad encoded in a `(decouple … per-pin)` child's structural
/// `origin_key` (`value@PAD#index`); null when there is none. Copy of
/// `optimizer.decouplePinFromOrigin` (kept local to avoid pulling the optimizer
/// into the ERC pass).
fn decouplePinFromOrigin(origin_key: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, origin_key, '@') orelse return null;
    const hash = std.mem.indexOfScalarPos(u8, origin_key, at + 1, '#') orelse return null;
    const pin = origin_key[at + 1 .. hash];
    return if (pin.len > 0) pin else null;
}

/// Parse a capacitance string ("100nF", "4.7uF", "10µF") to farads; 0 if
/// unrecognised. Copy of `module_policy.capValueFarads` (kept local to avoid an
/// eval→placement pub-API dependency). Accepts the UTF-8 micro sign `µ`
/// (0xC2 0xB5) as a `u`-equivalent so a hand-typed/imported "10µF" bulk cap
/// keeps its `decoupling_unbound` bulk-reservoir exemption instead of reading
/// 0 F (an HF cap) and producing a build-failing false positive.
fn capFarads(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
    if (i == 0) return 0;
    const num = std.fmt.parseFloat(f64, s[0..i]) catch return 0;
    if (i >= s.len) return 0;
    // UTF-8 `µ` (U+00B5, bytes 0xC2 0xB5) — the micro sign — reads as `u`.
    if (s[i] == 0xC2 and i + 1 < s.len and s[i + 1] == 0xB5) return num * 1e-6;
    const mult: f64 = switch (s[i]) {
        'p', 'P' => 1e-12,
        'n', 'N' => 1e-9,
        'u', 'U' => 1e-6,
        'm' => 1e-3,
        else => return 0,
    };
    return num * mult;
}

// ── config-strap direct-tie requirement ──────────────────────────────

/// Verdict for whether a per-pin sign-off (a `(strap-ok …)` direct-tie blessing
/// or a `(nc-ok …)` no-connect blessing) covers a pad: `.blessed` (matching pad
/// with a non-empty reason), `.empty_reason` (matching pad but blank reason —
/// still flagged, more specifically), or `.none` (no blessing at all).
const BlessingVerdict = enum { blessed, empty_reason, none };

/// Flag any configuration / enable / reset strap pin tied **directly** to a
/// power or ground rail net, unless the author blessed the tie with a
/// `(strap-ok PIN "reason")`. The good default is a pull-up/pull-down: a strap
/// pulled through a resistor lands on its own private net (e.g. "EN_PU"), never
/// on the rail, so it is silently fine — only a strap pad sitting on the rail
/// *itself* is flagged. The deliberate direct tie (an I²C address bit, a default
/// current-limit, a MODE select) is legitimate, but easy to wire backwards and
/// impossible to rework once fabbed, so it must carry an explicit "I checked
/// this" reason.
///
/// Mirrors `checkDecouplingBinding`: runs **per block** and recurses sub-blocks,
/// so a strap is judged against the rail names in *its own* module namespace (a
/// module's EN→VIN tie is judged on "VIN", not on whatever the parent wires VIN
/// to). Needs `project_dir` for `lib/pinouts` + `lib/components` strap
/// classification; the caller guards `project_dir.len > 0`.
fn checkStrapTies(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var straps_cache = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)).empty;
    try checkBlockStrapTies(allocator, arena, block, project_dir, &straps_cache, violations);
}

fn checkBlockStrapTies(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    straps_cache: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),
    violations: *std.ArrayList(Violation),
) !void {
    // Named rails (+ ferrite aliases) of THIS block, so a strap tied to a named
    // rail like "3V3"/"VSYS" is caught alongside the VDD/GND name heuristics.
    var rail_set: std.StringHashMapUnmanaged(void) = .empty;
    for (block.rails) |r| {
        try rail_set.put(arena, r.name, {});
        for (r.aliases) |a| try rail_set.put(arena, a, {});
    }

    for (block.nets) |net| {
        // Skip auto-generated `<rail>.<ic>.<pad>` bypass-stub sub-nets — a strap
        // is always declared on a canonical rail name, never the dotted stub.
        if (std.mem.indexOfScalar(u8, net.name, '.') != null) continue;
        const base = na.baseNetName(net.name);
        if (!isRailNet(base, &rail_set)) continue;

        for (net.pins) |pin| {
            if (pin.ref_des.len == 0) continue;
            const comp = componentOf(block, pin.ref_des);
            if (comp.len == 0) continue; // sub-block pin — handled in recursion
            const straps = strapsFor(arena, project_dir, straps_cache, comp);
            const fn_name = straps.get(pin.pin) orelse continue; // not a strap pad
            const inst = instanceOf(block, pin.ref_des) orelse continue;
            const msg = switch (strapBlessing(inst, pin.pin)) {
                .blessed => continue,
                .none => std.fmt.allocPrint(
                    allocator,
                    "Config strap \"{s}\" (pin {s}) on {s} is tied directly to rail \"{s}\" — " ++
                        "drive it through a pull-up/pull-down resistor, or bless the direct tie " ++
                        "with (strap-ok {s} \"why it's safe\") once you've checked it",
                    .{ fn_name, pin.pin, pin.ref_des, base, pin.pin },
                ) catch continue,
                .empty_reason => std.fmt.allocPrint(
                    allocator,
                    "(strap-ok {s}) on {s} needs a reason — explain why strap \"{s}\" may tie " ++
                        "straight to \"{s}\": (strap-ok {s} \"…\")",
                    .{ pin.pin, pin.ref_des, fn_name, base, pin.pin },
                ) catch continue,
            };
            try violations.append(allocator, .{
                .kind = .strap_tied_to_rail,
                .severity = .@"error",
                .message = msg,
                .ref_des = pin.ref_des,
                .net = base,
            });
        }
    }

    for (block.sub_blocks) |sb| {
        try checkBlockStrapTies(allocator, arena, sb.block, project_dir, straps_cache, violations);
    }
}

/// True when net base name `base` denotes a power or ground rail — a strap on it
/// is a direct tie. Combines the supply/ground name heuristics with this block's
/// declared rail names and a voltage-literal fallback ("3V3", "1V8", "+5V").
fn isRailNet(base: []const u8, rail_set: *const std.StringHashMapUnmanaged(void)) bool {
    if (pin_roles.isGroundFn(base) or pin_roles.isSupplyFn(base)) return true;
    if (rail_set.contains(base)) return true;
    return looksLikeRailLiteral(base);
}

/// True when `base` looks like a voltage-literal rail name: an optional +/- sign,
/// then only digits, '.', and 'V', with at least one digit and one 'V' ("3V3",
/// "1V8", "5V", "+5V", "3.3V"). Catches rails whose names aren't VDD/GND-shaped
/// and aren't in the derived rail graph.
fn looksLikeRailLiteral(base: []const u8) bool {
    var s = base;
    if (s.len > 0 and (s[0] == '+' or s[0] == '-')) s = s[1..];
    if (s.len < 2 or !std.ascii.isDigit(s[0])) return false; // must start with a digit
    var has_digit = false;
    var has_v = false;
    for (s) |c| {
        if (std.ascii.isDigit(c)) {
            has_digit = true;
        } else if (c == 'V' or c == 'v') {
            has_v = true;
        } else if (c != '.') {
            return false;
        }
    }
    return has_digit and has_v;
}

/// Instance with `ref_des` among `block`'s own instances (null if not found).
fn instanceOf(block: *const DesignBlock, ref_des: []const u8) ?Instance {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) return inst;
    }
    return null;
}

/// Whether instance `inst`'s direct tie of pad `pin` to a rail is signed off via
/// a `(strap-ok …)` form: `.blessed` (a matching pad with a non-empty reason),
/// `.empty_reason` (a matching pad whose reason is blank — still an error, but a
/// more specific one), or `.none` (no blessing at all).
fn strapBlessing(inst: Instance, pin: []const u8) BlessingVerdict {
    var saw_empty = false;
    for (inst.strap_oks) |s| {
        if (!std.mem.eql(u8, s.pin, pin)) continue;
        if (s.reason.len > 0) return .blessed;
        saw_empty = true;
    }
    return if (saw_empty) .empty_reason else .none;
}

/// Cached `pin_roles.strapPads` keyed by component name (pad-id → fn-name).
fn strapsFor(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    cache: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged([]const u8)),
    component: []const u8,
) std.StringHashMapUnmanaged([]const u8) {
    const gop = cache.getOrPut(arena, component) catch return .{};
    if (!gop.found_existing) gop.value_ptr.* = pin_roles.strapPads(arena, project_dir, component);
    return gop.value_ptr.*;
}

// ── no-connect requirement ───────────────────────────────────────────

/// Flag pads left as no-connects that the part's pinout says want a connection.
/// For every real IC instance (recursing sub-blocks), a pinout pad carrying no
/// net connection is judged by `pin_roles.connectionRequirement`: a
/// library-declared input left floating is an **error**, a config/enable/reset
/// strap left floating is a **warning**, and everything else (outputs, GPIO/IO,
/// passives, datasheet NC, unknown names) is silently fine — so the check
/// surfaces the open pads worth a second look instead of flagging every one. A
/// pad signed off with `(nc-ok PIN "reason")` is accepted.
///
/// Mirrors `checkStrapTies`: runs **per block** and recurses sub-blocks, so a
/// pad is judged in its own module namespace. Needs `project_dir` for
/// `lib/pinouts` + `lib/components`; the caller guards `project_dir.len > 0`.
/// Supply/ground pads are deferred to `checkUnconnectedPowerPins`, so a floating
/// rail pin is never double-reported here.
fn checkNoConnects(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var reqs_cache = std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(pin_roles.PadReq)).empty;
    try checkBlockNoConnects(allocator, arena, block, project_dir, &reqs_cache, violations);
}

fn checkBlockNoConnects(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    reqs_cache: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(pin_roles.PadReq)),
    violations: *std.ArrayList(Violation),
) !void {
    // Pads carrying any net connection, per ref_des in THIS block's namespace.
    var connected: std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(void)) = .empty;
    for (block.nets) |net| {
        for (net.pins) |pin| {
            if (pin.ref_des.len == 0) continue;
            const gop = try connected.getOrPut(arena, pin.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.*.put(arena, pin.pin, {});
        }
    }

    for (block.instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        // Only real ICs — same gating as the power-pin presence check.
        if (na.refDesLocalPrefix(inst.ref_des) != 'U') continue;
        if (env_mod.isTestPoint(inst.component)) continue;
        if (isPassiveComponent(inst.component)) continue;
        if (isGroundlessIc(inst.component)) continue;

        const reqs = reqsFor(arena, project_dir, reqs_cache, inst.component);
        if (reqs.count() == 0) continue; // no pinout data, or nothing flaggable
        const conn = connected.get(inst.ref_des);

        var it = reqs.iterator();
        while (it.next()) |e| {
            const pad = e.key_ptr.*;
            const info = e.value_ptr.*;
            if (conn) |c| if (c.contains(pad)) continue; // pad is wired — fine
            const severity: Severity = if (info.req == .required) .@"error" else .warning;
            const msg = switch (ncBlessing(inst, pad)) {
                .blessed => continue,
                .none => noConnectMsg(allocator, inst.ref_des, pad, info) orelse continue,
                .empty_reason => std.fmt.allocPrint(
                    allocator,
                    "(nc-ok {s}) on {s} needs a reason — explain why pin \"{s}\" may be left " ++
                        "unconnected: (nc-ok {s} \"…\")",
                    .{ pad, inst.ref_des, info.fn_name, pad },
                ) catch continue,
            };
            try violations.append(allocator, .{
                .kind = .no_connect,
                .severity = severity,
                .message = msg,
                .ref_des = inst.ref_des,
            });
        }
    }

    for (block.sub_blocks) |sb| {
        try checkBlockNoConnects(allocator, arena, sb.block, project_dir, reqs_cache, violations);
    }
}

/// The "this pad is an un-blessed no-connect" message, phrased per requirement
/// tier. Null only on an allocation failure (caller drops the finding).
fn noConnectMsg(allocator: std.mem.Allocator, ref_des: []const u8, pad: []const u8, info: pin_roles.PadReq) ?[]const u8 {
    return switch (info.req) {
        .required => std.fmt.allocPrint(
            allocator,
            "{s}: pin {s} (\"{s}\") is a declared input left unconnected — drive it, or " ++
                "sign off the no-connect with (nc-ok {s} \"why it's safe\")",
            .{ ref_des, pad, info.fn_name, pad },
        ) catch null,
        .suspect => std.fmt.allocPrint(
            allocator,
            "{s}: config strap \"{s}\" (pin {s}) is left unconnected (floating) — tie it off, or " ++
                "sign off the no-connect with (nc-ok {s} \"why it's safe\")",
            .{ ref_des, info.fn_name, pad, pad },
        ) catch null,
        .skip, .fine => null,
    };
}

/// Whether instance `inst` signs off leaving pad `pin` unconnected via a
/// `(nc-ok …)` form. Same three-state shape as `strapBlessing`.
fn ncBlessing(inst: Instance, pin: []const u8) BlessingVerdict {
    var saw_empty = false;
    for (inst.nc_oks) |n| {
        if (!std.mem.eql(u8, n.pin, pin)) continue;
        if (n.reason.len > 0) return .blessed;
        saw_empty = true;
    }
    return if (saw_empty) .empty_reason else .none;
}

/// Cached `pin_roles.padRequirements` keyed by component name (pad-id → PadReq).
fn reqsFor(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    cache: *std.StringHashMapUnmanaged(std.StringHashMapUnmanaged(pin_roles.PadReq)),
    component: []const u8,
) std.StringHashMapUnmanaged(pin_roles.PadReq) {
    const gop = cache.getOrPut(arena, component) catch return .{};
    if (!gop.found_existing) gop.value_ptr.* = pin_roles.padRequirements(arena, project_dir, component);
    return gop.value_ptr.*;
}

// ── config-strap direct-tie tests ────────────────────────────────────

// spec: erc - a config strap tied directly to a rail is an error unless pulled through a resistor or blessed
test "config strap tied directly to a rail requires a pull resistor or a blessing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // ic1: pin1 VDD (supply), pin2 EN (strap), pin3 GND, pin4 A0 (address strap).
    const ic1_comp = "(component ic1 (pinout \"ic1\"))";
    const ic1_pinout =
        \\(pinout "ic1"
        \\  (pin 1 "VDD") (pin 2 "EN") (pin 3 "GND") (pin 4 "A0"))
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/pinouts");
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/ic1.sexp", .data = ic1_comp });
    try tmp.dir.writeFile(.{ .sub_path = "lib/pinouts/ic1.sexp", .data = ic1_pinout });
    const path = try tmp.dir.realpathAlloc(alloc, ".");

    const insts = try alloc.alloc(Instance, 3);
    insts[0] = dcInst("U1", "ic1", ""); // EN→VDD unblessed (FLAG); A0→GND blessed (ok)
    insts[0].strap_oks = &.{.{ .pin = "4", .reason = "I2C address bit0 = 0" }};
    insts[1] = dcInst("U2", "ic1", ""); // EN on a private net via a pull resistor (ok)
    insts[2] = dcInst("R1", "res-0402", "10k");

    var vdd: std.ArrayList(env_mod.PinRef) = .empty;
    try vdd.append(alloc, .{ .ref_des = "U1", .pin = "1" }); // real supply pin
    try vdd.append(alloc, .{ .ref_des = "U1", .pin = "2" }); // EN strap tied straight to VDD
    try vdd.append(alloc, .{ .ref_des = "R1", .pin = "2" }); // pull resistor top
    var gnd: std.ArrayList(env_mod.PinRef) = .empty;
    try gnd.append(alloc, .{ .ref_des = "U1", .pin = "3" }); // real ground pin
    try gnd.append(alloc, .{ .ref_des = "U1", .pin = "4" }); // A0 strap, blessed
    var en2: std.ArrayList(env_mod.PinRef) = .empty;
    try en2.append(alloc, .{ .ref_des = "U2", .pin = "2" }); // EN on its own net
    try en2.append(alloc, .{ .ref_des = "R1", .pin = "1" });

    const nets = try alloc.alloc(env_mod.Net, 3);
    nets[0] = .{ .name = "VDD", .pins = vdd.items };
    nets[1] = .{ .name = "GND", .pins = gnd.items };
    nets[2] = .{ .name = "U2_EN", .pins = en2.items };

    const block: DesignBlock = .{
        .name = "t",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_ties = &.{},
    };

    var violations: std.ArrayList(Violation) = .empty;
    try checkStrapTies(alloc, &block, path, &violations);

    try std.testing.expectEqual(@as(usize, 1), countKind(violations.items, .strap_tied_to_rail));
    for (violations.items) |v| {
        if (v.kind != .strap_tied_to_rail) continue;
        try std.testing.expectEqual(Severity.@"error", v.severity);
        try std.testing.expectEqualStrings("U1", v.ref_des); // the EN→VDD tie
        try std.testing.expectEqualStrings("VDD", v.net);
    }
}

// spec: erc - strapBlessing distinguishes a reasoned blessing from a blank one and none
test "strapBlessing reads reasoned, blank, and absent blessings" {
    const blessed: Instance = .{
        .ref_des = "U1",
        .component = "ic1",
        .value = "",
        .footprint = "",
        .symbol = "",
        .strap_oks = &.{.{ .pin = "2", .reason = "default mode" }},
    };
    try std.testing.expectEqual(BlessingVerdict.blessed, strapBlessing(blessed, "2"));
    try std.testing.expectEqual(BlessingVerdict.none, strapBlessing(blessed, "3"));

    const blank: Instance = .{
        .ref_des = "U1",
        .component = "ic1",
        .value = "",
        .footprint = "",
        .symbol = "",
        .strap_oks = &.{.{ .pin = "2", .reason = "" }},
    };
    try std.testing.expectEqual(BlessingVerdict.empty_reason, strapBlessing(blank, "2"));
}

// ── no-connect requirement tests ─────────────────────────────────────

// spec: erc - an unconnected pad the pinout wants connected is flagged by tier unless blessed
test "no-connect check tiers floating pads and honours (nc-ok …)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // mcu: 1 VDD, 2 GND (skip); 3 EN (strap→warning); 4 CTRL (input→error);
    // 5 DOUT (fine); 6 NRST (strap→warning); 7 PA0 (gpio→fine).
    const comp = "(component mcu (pinout \"mcu\") (electrical \"CTRL\" (type input)))";
    const pinout =
        \\(pinout "mcu"
        \\  (pin 1 "VDD") (pin 2 "GND") (pin 3 "EN") (pin 4 "CTRL")
        \\  (pin 5 "DOUT") (pin 6 "NRST") (pin 7 "PA0"))
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/pinouts");
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/mcu.sexp", .data = comp });
    try tmp.dir.writeFile(.{ .sub_path = "lib/pinouts/mcu.sexp", .data = pinout });
    const path = try tmp.dir.realpathAlloc(alloc, ".");

    const insts = try alloc.alloc(Instance, 1);
    insts[0] = dcInst("U1", "mcu", "");
    // NRST(6) signed off → suppressed; EN(3) + CTRL(4) left unblessed.
    insts[0].nc_oks = &.{.{ .pin = "6", .reason = "internal pull-up per datasheet" }};

    // Wire only VDD(1), GND(2), DOUT(5). Pads 3,4,6,7 carry no connection.
    var vdd: std.ArrayList(env_mod.PinRef) = .empty;
    try vdd.append(alloc, .{ .ref_des = "U1", .pin = "1" });
    var gnd: std.ArrayList(env_mod.PinRef) = .empty;
    try gnd.append(alloc, .{ .ref_des = "U1", .pin = "2" });
    var sig: std.ArrayList(env_mod.PinRef) = .empty;
    try sig.append(alloc, .{ .ref_des = "U1", .pin = "5" });

    const nets = try alloc.alloc(env_mod.Net, 3);
    nets[0] = .{ .name = "VDD", .pins = vdd.items };
    nets[1] = .{ .name = "GND", .pins = gnd.items };
    nets[2] = .{ .name = "SIGOUT", .pins = sig.items };

    const block: DesignBlock = .{
        .name = "t",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_ties = &.{},
    };

    var violations: std.ArrayList(Violation) = .empty;
    try checkNoConnects(alloc, &block, path, &violations);

    // EN(3) → warning, CTRL(4) → error. NRST(6) blessed, PA0(7)/DOUT(5) fine.
    try std.testing.expectEqual(@as(usize, 2), countKind(violations.items, .no_connect));
    var errors: usize = 0;
    var warnings: usize = 0;
    for (violations.items) |v| {
        if (v.kind != .no_connect) continue;
        try std.testing.expectEqualStrings("U1", v.ref_des);
        if (v.severity == .@"error") errors += 1;
        if (v.severity == .warning) warnings += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), errors); // CTRL — declared input
    try std.testing.expectEqual(@as(usize, 1), warnings); // EN — config strap
}

// ── decoupling-binding requirement tests ─────────────────────────────

const TEST_CAP = "cap-0402";

fn dcInst(ref: []const u8, comp: []const u8, value: []const u8) Instance {
    return .{ .ref_des = ref, .component = comp, .value = value, .footprint = "", .symbol = "" };
}

fn countKind(violations: []const Violation, kind: ViolationKind) usize {
    var n: usize = 0;
    for (violations) |v| if (v.kind == kind) {
        n += 1;
    };
    return n;
}

// U1 is a hub with two pads (1,2) on VDD and one ground pad (3) on GND, plus one
// decoupling cap per binding state, all on VDD/GND. No pinout file exists for the
// dummy project dir the test uses, so pin_roles is empty (every pad `.other`,
// i.e. non-strap) ⇒ VDD lands on two supply pads and the binding is ambiguous.
fn makeDecoupleTestBlock(alloc: std.mem.Allocator) !DesignBlock {
    const insts = try alloc.alloc(Instance, 6);
    insts[0] = dcInst("U1", "somechip", "");
    insts[1] = dcInst("C1", TEST_CAP, "100nF"); // unbound → FLAG
    insts[2] = dcInst("C2", TEST_CAP, "100nF"); // bound via (decouples "U1" 1)
    insts[2].decouple_pin = "1";
    insts[3] = dcInst("C3", TEST_CAP, "10uF"); // bulk reservoir → exempt
    insts[4] = dcInst("C4", TEST_CAP, "100nF"); // (decouples rail) → exempt
    insts[4].decouple_rail = true;
    insts[5] = dcInst("C5", TEST_CAP, "100nF"); // per-pin shorthand pad in origin_key → exempt
    insts[5].origin_key = "100nF@2#0";

    const caps = [_][]const u8{ "C1", "C2", "C3", "C4", "C5" };
    var vdd: std.ArrayList(env_mod.PinRef) = .empty;
    var gnd: std.ArrayList(env_mod.PinRef) = .empty;
    try vdd.append(alloc, .{ .ref_des = "U1", .pin = "1" });
    try vdd.append(alloc, .{ .ref_des = "U1", .pin = "2" });
    try gnd.append(alloc, .{ .ref_des = "U1", .pin = "3" });
    for (caps) |c| {
        try vdd.append(alloc, .{ .ref_des = c, .pin = "1" });
        try gnd.append(alloc, .{ .ref_des = c, .pin = "2" });
    }
    const nets = try alloc.alloc(env_mod.Net, 2);
    nets[0] = .{ .name = "VDD", .pins = vdd.items };
    nets[1] = .{ .name = "GND", .pins = gnd.items };

    return .{
        .name = "t",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_ties = &.{},
    };
}

// spec: erc - an unbound HF decoupling cap on a multi-supply-pad rail is an error, with bound/bulk/rail-optout/per-pin caps exempt
test "decoupling cap on a multi-supply-pad rail requires a pin binding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const block = try makeDecoupleTestBlock(alloc);
    var violations: std.ArrayList(Violation) = .empty;
    try checkDecouplingBinding(alloc, &block, "/nonexistent-eda-test-dir", &violations);

    try std.testing.expectEqual(@as(usize, 1), countKind(violations.items, .decoupling_unbound));
    for (violations.items) |v| {
        if (v.kind != .decoupling_unbound) continue;
        try std.testing.expectEqual(Severity.@"error", v.severity);
        try std.testing.expectEqualStrings("C1", v.ref_des);
        try std.testing.expectEqualStrings("VDD", v.net);
    }
}

// spec: erc - config straps tied to the rail are excluded from the supply-pad count, like the placer's hubTargets
test "decoupling-binding excludes config straps from the supply-pad count" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // EN is a control strap tied to VIN; IN/VCC/VCC2 are real supply pins.
    const reg1_comp = "(component reg1 (pinout \"reg1\") (electrical \"EN\" (type input)))";
    const reg1_pinout =
        \\(pinout "reg1"
        \\  (pin 1 "IN") (pin 2 "EN") (pin 3 "GND") (pin 4 "VCC") (pin 5 "VCC2"))
    ;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/pinouts");
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/reg1.sexp", .data = reg1_comp });
    try tmp.dir.writeFile(.{ .sub_path = "lib/pinouts/reg1.sexp", .data = reg1_pinout });
    const path = try tmp.dir.realpathAlloc(alloc, ".");

    const insts = try alloc.alloc(Instance, 3);
    insts[0] = dcInst("U1", "reg1", "");
    insts[1] = dcInst("C1", TEST_CAP, "100nF"); // on VIN: pad 2 is a strap ⇒ 1 supply pad ⇒ exempt
    insts[2] = dcInst("C2", TEST_CAP, "100nF"); // on VCC: pads 4,5 real ⇒ 2 supply pads ⇒ FLAG

    var vin: std.ArrayList(env_mod.PinRef) = .empty;
    try vin.append(alloc, .{ .ref_des = "U1", .pin = "1" }); // IN
    try vin.append(alloc, .{ .ref_des = "U1", .pin = "2" }); // EN (strap)
    try vin.append(alloc, .{ .ref_des = "C1", .pin = "1" });
    var vcc: std.ArrayList(env_mod.PinRef) = .empty;
    try vcc.append(alloc, .{ .ref_des = "U1", .pin = "4" }); // VCC
    try vcc.append(alloc, .{ .ref_des = "U1", .pin = "5" }); // VCC2
    try vcc.append(alloc, .{ .ref_des = "C2", .pin = "1" });
    var gnd: std.ArrayList(env_mod.PinRef) = .empty;
    try gnd.append(alloc, .{ .ref_des = "U1", .pin = "3" });
    try gnd.append(alloc, .{ .ref_des = "C1", .pin = "2" });
    try gnd.append(alloc, .{ .ref_des = "C2", .pin = "2" });

    const nets = try alloc.alloc(env_mod.Net, 3);
    nets[0] = .{ .name = "VIN", .pins = vin.items };
    nets[1] = .{ .name = "VCC", .pins = vcc.items };
    nets[2] = .{ .name = "GND", .pins = gnd.items };

    const block: DesignBlock = .{
        .name = "t",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_ties = &.{},
    };

    var violations: std.ArrayList(Violation) = .empty;
    try checkDecouplingBinding(alloc, &block, path, &violations);

    try std.testing.expectEqual(@as(usize, 1), countKind(violations.items, .decoupling_unbound));
    for (violations.items) |v| {
        if (v.kind != .decoupling_unbound) continue;
        try std.testing.expectEqualStrings("C2", v.ref_des); // C1 exempt (strap), C2 flagged
    }
}

/// Check voltage mismatches across section port declarations.
fn checkVoltageMismatches(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    var net_voltages: std.StringHashMapUnmanaged(std.ArrayList(VoltageEntry)) = .empty;

    for (block.sections) |sec| {
        try collectSectionVoltages(allocator, &net_voltages, sec);
    }

    var iter = net_voltages.iterator();
    while (iter.next()) |entry| {
        const entries = entry.value_ptr.items;
        if (entries.len < 2) continue;
        // Compare the extremes across ALL declarations, not each against
        // entries[0]: three decls 3.30 / 3.291 / 3.309 V each sit within
        // tolerance of the first yet span 0.018 V, so an entries[0]-only compare
        // misses it (and which pair reported depended on iteration order). The
        // widest spread is the true mismatch and is order-independent.
        var min_e = entries[0];
        var max_e = entries[0];
        for (entries[1..]) |e| {
            if (e.voltage < min_e.voltage) min_e = e;
            if (e.voltage > max_e.voltage) max_e = e;
        }
        if (max_e.voltage - min_e.voltage > VOLTAGE_MISMATCH_TOLERANCE_V) {
            const msg = std.fmt.allocPrint(
                allocator,
                "Voltage mismatch on \"{s}\": {s} declares {d:.1}V vs {s} declares {d:.1}V",
                .{ entry.key_ptr.*, min_e.section, min_e.voltage, max_e.section, max_e.voltage },
            ) catch continue;
            try violations.append(allocator, .{
                .kind = .voltage_mismatch,
                .severity = .@"error",
                .message = msg,
                .net = entry.key_ptr.*,
            });
        }
    }
}

const VoltageEntry = struct { section: []const u8, voltage: f64 };

fn collectSectionVoltages(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(std.ArrayList(VoltageEntry)),
    sec: env_mod.Section,
) !void {
    for (sec.ports) |p| {
        if (p.voltage) |v| {
            const gop = map.getOrPut(allocator, p.name) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(allocator, .{ .section = sec.name, .voltage = v });
        }
    }
    for (sec.sub_sections) |sub| {
        try collectSectionVoltages(allocator, map, sub);
    }
}

/// Check ICs missing power/ground connections.
/// Checks both this block's nets and recursively checks sub-block nets for their own instances.
/// `project_dir` locates `lib/pinouts` so the check can tell a real IC (which has a
/// supply/ground pin to connect) from a passive RF part or connector that carries a
/// `U` ref-des but no power pins at all; pass "" to skip that refinement (every U
/// part is then expected to have both, the original strict behaviour).
fn checkUnconnectedPowerPins(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    try checkBlockPowerPins(allocator, block, project_dir, violations);
    // Recurse into every sub-block with its own net namespace — a
    // module-inside-a-module IC with no ground is otherwise missed.
    for (block.sub_blocks) |sb| {
        try checkUnconnectedPowerPins(allocator, sb.block, project_dir, violations);
    }
}

/// Whether a part's pinout declares a real supply pin and/or a real ground pin.
const PartPowerPins = struct { has_supply: bool, has_ground: bool };

/// Decide whether `inst`'s component is even expected to have a supply pin and a
/// ground pin, by reading its `lib/pinouts` function names. A passive RF
/// filter/attenuator (RF-IN/RF-OUT/GND only) or an SMA connector (signal pins
/// only) reports neither, so the no-power/no-ground checks skip it. When the
/// pinout can't be inspected (no `project_dir`, no lookup key, missing/parse-fail
/// file) both default to true, preserving the original strict behaviour. Results
/// are cached per pinout-lookup key.
fn partPowerPins(
    allocator: std.mem.Allocator,
    cache: *std.StringHashMapUnmanaged(PartPowerPins),
    project_dir: []const u8,
    inst: Instance,
) PartPowerPins {
    const fallback = PartPowerPins{ .has_supply = true, .has_ground = true };
    if (project_dir.len == 0) return fallback;
    // Mirror checkPinFunctions' lookup precedence: pinout, then symbol, then component.
    const lookup = if (inst.pinout.len > 0) inst.pinout else if (inst.symbol.len > 0) inst.symbol else inst.component;
    if (lookup.len == 0) return fallback;

    const gop = cache.getOrPut(allocator, lookup) catch return fallback;
    if (gop.found_existing) return gop.value_ptr.*;

    const result = loadPinoutFunctionFlags(allocator, project_dir, lookup) orelse fallback;
    gop.value_ptr.* = result;
    return result;
}

/// Read `<project_dir>/lib/pinouts/<lookup>.sexp` and report whether any pin's
/// function name reads as a supply / as a ground. Only the function name (the
/// third element of each `(pin <id> "<fn>" …)`) is inspected — the pad id is
/// ignored, so the bare-integer form `(pin 1 "VCC")` works the same as the
/// alphanumeric `(pin A1 "VDD")` form (unlike `loadPinoutMap`, which keys on the
/// pad id and drops integer pads). Null on any read/parse failure so the caller
/// falls back to the strict "expect both" default.
fn loadPinoutFunctionFlags(allocator: std.mem.Allocator, project_dir: []const u8, lookup: []const u8) ?PartPowerPins {
    const path = std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ project_dir, lookup }) catch return null;
    const content = infra_fs.cwd().readFileAlloc(allocator, path, 1024 * 256) catch return null;
    const nodes = parser_mod.parse(allocator, content) catch return null;
    if (nodes.len == 0) return null;
    const top = nodes[0].asList() orelse return null;
    if (top.len < 2 or !std.mem.eql(u8, top[0].asAtom() orelse "", "pinout")) return null;

    var flags = PartPowerPins{ .has_supply = false, .has_ground = false };
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        if (!std.mem.eql(u8, cl[0].asAtom() orelse "", "pin")) continue;
        const fn_name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
        if (pin_roles.isSupplyFn(fn_name)) flags.has_supply = true;
        if (pin_roles.isGroundFn(fn_name)) flags.has_ground = true;
    }
    return flags;
}

/// True for the `V<int>P<frac>` board-rail naming convention — `V5P0`,
/// `V1P8`, `V3P3`, `V0P9`, `V12P0` — where `P` stands in for the decimal
/// point. Mirrors `rails.looksLikeRail`'s "V + digit" intent but is scoped to
/// the explicit point-rail form so a V-initial signal name (VSYNC) can't
/// match. Used by the IC-power-presence check so a rail like the 5V `V5P0`
/// isn't mistaken for a non-power net.
fn isVoltagePointRail(base: []const u8) bool {
    if (base.len < 4 or base[0] != 'V') return false; // shortest is "V0P9"
    var i: usize = 1;
    const int_start = i;
    while (i < base.len and base[i] >= '0' and base[i] <= '9') : (i += 1) {}
    if (i == int_start or i >= base.len or base[i] != 'P') return false;
    i += 1; // consume the 'P'
    return i < base.len and base[i] >= '0' and base[i] <= '9';
}

/// True for `V_…` underscore board-rail names — the digit-first form
/// (`V_3V3D`, `V_12V`) and the domain-tagged form (`V_RF_3P3`, `V_RX_2P5`,
/// `V_NEG_3P3`). Requires the `V_` prefix plus at least one digit somewhere
/// after it (the voltage), so a non-rail signal like `V_SENSE` is not matched.
fn isUnderscoreRail(base: []const u8) bool {
    if (base.len < 4 or base[0] != 'V' or base[1] != '_') return false;
    for (base[2..]) |c| {
        if (c >= '0' and c <= '9') return true;
    }
    return false;
}

/// KiCad-style signed voltage rail: '+'/'-' followed by a digit, with a
/// 'V' somewhere after ("+5V", "-5.0V", "+3V3", "+12V", "+5_0V").
fn isSignedVoltRail(base: []const u8) bool {
    if (base.len < 3 or (base[0] != '+' and base[0] != '-')) return false;
    if (base[1] < '0' or base[1] > '9') return false;
    return std.mem.indexOfScalar(u8, base[2..], 'V') != null;
}

fn checkBlockPowerPins(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    var has_gnd: std.StringHashMapUnmanaged(void) = .empty;
    var has_vdd: std.StringHashMapUnmanaged(void) = .empty;
    // pinout-lookup key → whether the part has a supply / ground pin at all.
    var part_pins: std.StringHashMapUnmanaged(PartPowerPins) = .empty;

    for (block.nets) |net| {
        const base = na.baseNetName(net.name);
        const is_gnd = std.mem.eql(u8, base, "GND") or std.mem.eql(u8, base, "VSS") or
            std.mem.eql(u8, base, "AGND") or std.mem.eql(u8, base, "DGND") or
            std.mem.eql(u8, base, "PGND") or std.mem.eql(u8, base, "EP") or
            std.mem.startsWith(u8, base, "GND") or
            std.mem.endsWith(u8, base, "GND") or std.mem.endsWith(u8, base, "VSS") or
            pin_roles.isGroundFn(base);
        // A net classified as ground is never also a supply — reject it first so
        // "VSS"/"VSSA" don't read as power (the old inline `startsWith("VS")`
        // heuristic marked VSS/VSYNC/VSW/VSENSE as power; delegate to
        // `pin_roles.isSupplyFn` for the exact `VS`/`VSYS` form instead).
        const is_vdd = !is_gnd and (std.mem.startsWith(u8, base, "VDD") or std.mem.startsWith(u8, base, "VCC") or
            std.mem.startsWith(u8, base, "VBAT") or
            // Local post-filter supply nodes that *end* in a supply token — a
            // chip's VDD/VCC pin fed from a board rail through a ferrite/LC
            // filter sits on a renamed node like `SW_VDD` (PE42553 cal switch:
            // V_3V3D → FB_VDD → SW_VDD) or `ANA_VCC`. Mirrors the `endsWith
            // GND/VSS` rule the ground classifier already applies.
            std.mem.endsWith(u8, base, "VDD") or std.mem.endsWith(u8, base, "VCC") or
            // `V<int>P<frac>` board-rail convention (V1P8, V3P3, V5P0, V0P9,
            // V12P0 …) — `P` is the decimal point. Generalises the old
            // V1P/V2P/V3P3 special-cases, which missed higher rails like the
            // 5V `V5P0` feeding the NeoPixel level shifter.
            isVoltagePointRail(base) or
            std.mem.startsWith(u8, base, "VBUS") or std.mem.startsWith(u8, base, "VIN") or
            std.mem.startsWith(u8, base, "VOUT") or std.mem.startsWith(u8, base, "AVDD") or
            std.mem.startsWith(u8, base, "DVDD") or std.mem.startsWith(u8, base, "V+") or
            // VREF: auto-direction level translators (LSF0108, TXS0108, …) have no
            // VDD/VCC pin — they are supplied through their VREF_A / VREF_B rails.
            std.mem.startsWith(u8, base, "VREF") or
            // System rail `VSYS` (+ derivatives) is a real supply — kept
            // explicitly because `isSupplyFn` doesn't list it.
            std.mem.startsWith(u8, base, "VSYS") or
            // Real supply names (VS, VBUS, VIN, …) by `pin_roles.isSupplyFn`,
            // which rejects ground first so VSS/VSSA never read as a supply —
            // replacing the old `startsWith("VS")` that swallowed
            // VSS/VSYNC/VSW/VSENSE as power.
            pin_roles.isSupplyFn(base) or
            // `V_…` underscore board rails — both the digit-first form
            // (V_3V3D, V_12V, V_5V0) and the domain-tagged form
            // (V_RF_3P3, V_RX_2P5, V_NEG_3P3) RF/analog boards use. Without
            // this an IC powered only from such a rail is falsely flagged
            // "no power connection".
            isUnderscoreRail(base) or
            // KiCad-convention signed rails (+5V, +3V3, -5.0V, +12V — and
            // the dot-free +5_0V form imported modules use). Boards migrated
            // via import-kicad keep these names verbatim.
            isSignedVoltRail(base));

        for (net.pins) |pin| {
            if (pin.ref_des.len == 0) continue;
            if (is_gnd) try has_gnd.put(allocator, pin.ref_des, {});
            if (is_vdd) try has_vdd.put(allocator, pin.ref_des, {});
        }
    }

    for (block.instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        const prefix = na.refDesLocalPrefix(inst.ref_des);
        // Only check ICs (U prefix)
        if (prefix != 'U') continue;
        // Skip test points — single-pad probe pads, never an IC (also get a "TP"
        // ref-des, so this is belt-and-suspenders against a stray 'U').
        if (env_mod.isTestPoint(inst.component)) continue;
        // Skip passive components that got U prefix (LEDs, inductors, filters, crystals)
        if (isPassiveComponent(inst.component)) continue;
        // Skip ICs that intentionally have no ground reference pin (float with
        // their input rail) — flagging them for "no ground" is a false positive.
        if (isGroundlessIc(inst.component)) continue;
        // Passive RF parts (filters, attenuators) and connectors carry a `U`
        // ref-des but their pinout has no supply/ground pin at all — only expect
        // a power/ground connection on a part that actually has such a pin.
        const pins = partPowerPins(allocator, &part_pins, project_dir, inst);

        if (pins.has_ground and !has_gnd.contains(inst.ref_des)) {
            const msg = std.fmt.allocPrint(allocator, "{s}: IC has no ground connection", .{inst.ref_des}) catch continue;
            try violations.append(allocator, .{
                .kind = .unconnected_pin,
                .severity = .@"error",
                .message = msg,
                .ref_des = inst.ref_des,
            });
        }
        if (pins.has_supply and !has_vdd.contains(inst.ref_des)) {
            const msg = std.fmt.allocPrint(allocator, "{s}: IC has no power connection", .{inst.ref_des}) catch continue;
            try violations.append(allocator, .{
                .kind = .unconnected_pin,
                .severity = .warning,
                .message = msg,
                .ref_des = inst.ref_des,
            });
        }
    }
}

/// Emit power-budget violations by translating the rail analysis from
/// eval/power_budget.zig into ERC violations. Ferrite beads are treated as
/// electrically transparent (DC conductor) so downstream rails roll up to
/// the upstream regulator's budget. Surfaces four outcomes per rail:
///   - error:   max load exceeds the regulator's rated max
///   - warning: typ load exceeds 80 % of the regulator's typ capacity
///   - info:    rail has load but no declared source capacity
///   - info:    rail has declared source but no consumer annotations
fn checkPowerBudget(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    const rails = try power_budget.analyze(allocator, block);
    for (rails) |rail| {
        switch (rail.status) {
            .ok => {},
            .no_consumers => {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Rail \"{s}\" sourced by {s} has no annotated consumers — add (i-typ …)/(i-max …) on pin forms to populate the budget",
                    .{ rail.net, rail.source_label },
                ) catch continue;
                try violations.append(allocator, .{
                    .kind = .power_budget,
                    .severity = .info,
                    .message = msg,
                    .net = rail.net,
                });
            },
            .over => {
                const smax = rail.source_max_a orelse continue;
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Rail \"{s}\" max load {d:.3}A exceeds {s} rated max {d:.3}A",
                    .{ rail.net, rail.load_max_a, rail.source_label, smax },
                ) catch continue;
                try violations.append(allocator, .{
                    .kind = .power_budget,
                    .severity = .@"error",
                    .message = msg,
                    .net = rail.net,
                });
            },
            .tight => {
                const styp = rail.source_typ_a orelse continue;
                // A declared-zero source typ (`(current 0 …)`) still reads
                // `.tight` upstream, so guard the divide: `100*load/0` is +inf
                // and `@intFromFloat(inf)` is UB in ReleaseSmall. Emit the row
                // without a percent rather than crash the whole ERC pass.
                const pct: ?u32 = if (styp > 0)
                    numeric.checkedInt(u32, PERCENT_MULTIPLIER * rail.load_typ_a / styp)
                else
                    null;
                const msg = if (pct) |p| std.fmt.allocPrint(
                    allocator,
                    "Rail \"{s}\" typ load {d:.3}A is {d}% of {s} typ {d:.3}A — tight margin",
                    .{ rail.net, rail.load_typ_a, p, rail.source_label, styp },
                ) catch continue else std.fmt.allocPrint(
                    allocator,
                    "Rail \"{s}\" typ load {d:.3}A against {s} typ {d:.3}A — tight margin",
                    .{ rail.net, rail.load_typ_a, rail.source_label, styp },
                ) catch continue;
                try violations.append(allocator, .{
                    .kind = .power_budget,
                    .severity = .warning,
                    .message = msg,
                    .net = rail.net,
                });
            },
            .no_source => {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Rail \"{s}\" has {d:.3}A typ load but no regulator declares (current …) on its output",
                    .{ rail.net, rail.load_typ_a },
                ) catch continue;
                try violations.append(allocator, .{
                    .kind = .power_budget,
                    .severity = .info,
                    .message = msg,
                    .net = rail.net,
                });
            },
        }
    }
}

/// Report concept sections that still need implementation.
fn checkConceptSections(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayList(Violation),
) !void {
    for (block.sections) |sec| {
        if (sec.status == .concept) {
            const msg = std.fmt.allocPrint(allocator, "Section \"{s}\" is still a concept — no implementation yet", .{sec.name}) catch continue;
            try violations.append(allocator, .{
                .kind = .concept_remaining,
                .severity = .info,
                .message = msg,
            });
        }
    }
}

/// Check if a component name indicates a passive (LED, inductor, filter, crystal, etc.)
/// that shouldn't be flagged for missing power/ground connections.
fn isPassiveComponent(component: []const u8) bool {
    // LED, inductor, ferrite, crystal, diode, EMC filter, connector, switch, fuse
    const passive_prefixes = [_][]const u8{
        "led",     "ind",   "ferrite", "xfl",      "abm",
        "fc-",     "diode", "ecmf",    "esd",      "tvs",
        "fuse",    "ntc",   "ptc",     "varistor", "sw-",
        "crystal", "xtal",
    };
    for (passive_prefixes) |pfx| {
        if (component.len >= pfx.len and std.ascii.eqlIgnoreCase(component[0..pfx.len], pfx)) return true;
    }
    return false;
}

/// ICs that intentionally have no ground reference pin — they float with their
/// input rail (e.g. the LM74610 ideal-diode controller has no GND terminal),
/// so the "IC has no ground connection" check does not apply to them.
fn isGroundlessIc(component: []const u8) bool {
    const groundless_prefixes = [_][]const u8{
        "lm74610",
    };
    for (groundless_prefixes) |pfx| {
        if (component.len >= pfx.len and std.ascii.eqlIgnoreCase(component[0..pfx.len], pfx)) return true;
    }
    return false;
}

fn collectOptionalPortNets(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(void),
    sec: env_mod.Section,
) !void {
    for (sec.ports) |p| {
        if (p.optional) try map.put(allocator, p.name, {});
    }
    for (sec.sub_sections) |sub| try collectOptionalPortNets(allocator, map, sub);
}

/// One row of a parsed pinout file: the canonical name of a physical
/// pin plus every alternative peripheral function it can drive. Returned
/// from `loadPinoutMap` and consumed by `checkPinFunctions` here and by
/// `eval/pin_enrichment.enrichPinFunctions` to auto-fill single-alt
/// assertions before validation runs.
pub const PinoutEntry = struct {
    /// Primary function name (always valid).
    primary: []const u8,
    /// Additional valid function names for this physical pin.
    alts: []const []const u8,
};

/// Load a pinout file and return pin_id -> {primary, alts}. Returns null if the file is missing
/// or malformed. Allocator is used both for the parse tree (kept until end of ERC) and the map.
pub fn loadPinoutMap(allocator: std.mem.Allocator, path: []const u8) ?std.StringHashMapUnmanaged(PinoutEntry) {
    const content = infra_fs.cwd().readFileAlloc(allocator, path, 1024 * 256) catch return null;
    const nodes = parser_mod.parse(allocator, content) catch return null;
    if (nodes.len == 0) return null;
    const top = nodes[0].asList() orelse return null;
    if (top.len < 2) return null;
    const head = top[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, head, "pinout")) return null;

    var map: std.StringHashMapUnmanaged(PinoutEntry) = .empty;
    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        const ch = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, ch, "pin")) continue;
        const pin_id = atomOrString(cl[1]) orelse continue;
        const primary = cl[2].asString() orelse (cl[2].asAtom() orelse continue);

        var alts: std.ArrayList([]const u8) = .empty;
        for (cl[3..]) |alt_node| {
            const al = alt_node.asList() orelse continue;
            if (al.len < 2) continue;
            const hd = al[0].asAtom() orelse continue;
            if (!std.mem.eql(u8, hd, "alt")) continue;
            const alt_name = al[1].asString() orelse (al[1].asAtom() orelse continue);
            alts.append(allocator, alt_name) catch continue;
        }
        const entry = PinoutEntry{
            .primary = primary,
            .alts = alts.toOwnedSlice(allocator) catch &.{},
        };
        // Dual-key: BGA position ("P16") AND logical name ("PN1") both
        // resolve to the same entry. The design file mixes both styles
        // (`(pin H4 …)` uses BGA; `(pin PN1 …)` uses logical), and
        // before this dual indexing the logical-name lookups missed the
        // map entirely and `checkPinFunctions` silently skipped them.
        map.put(allocator, pin_id, entry) catch continue;
        if (!std.mem.eql(u8, pin_id, primary)) {
            map.put(allocator, primary, entry) catch continue;
        }
    }
    return map;
}

fn atomOrString(node: @import("sexpr/ast.zig").Node) ?[]const u8 {
    if (node.asAtom()) |a| return a;
    if (node.asString()) |s| return s;
    return null;
}

/// Validate `(as "FN")` assertions against the pinout file:
///   1. Every asserted function must match the pin's primary function or one of its
///      declared alternates.
///   2. When the pin has any `(alt ...)` entries, the design MUST name at least one
///      function via `(as ...)` — silence there means the user hasn't committed to
///      which role the pin plays, and the error blocks the build.
///
/// Pins without alts (pure power/analog pads) don't need an assertion.
fn checkPinFunctions(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    violations: *std.ArrayList(Violation),
) !void {
    // Cache loaded pinouts by symbol so repeated lookups don't reparse — shared
    // across every block in the recursion.
    var pinout_cache: std.StringHashMapUnmanaged(?std.StringHashMapUnmanaged(PinoutEntry)) = .empty;
    try checkBlockPinFunctions(allocator, block, project_dir, &pinout_cache, violations);
}

/// Runs per block (recursing sub-blocks): the `(as …)` assertions and the
/// mandatory multi-alt `pin_function_required` rule apply to every module's
/// pins in its own net namespace, not just the top-level block's nets.
fn checkBlockPinFunctions(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    project_dir: []const u8,
    pinout_cache: *std.StringHashMapUnmanaged(?std.StringHashMapUnmanaged(PinoutEntry)),
    violations: *std.ArrayList(Violation),
) std.mem.Allocator.Error!void {
    // Build ref_des -> pinout_lookup map for THIS block's own instances so we
    // know which pinout file to load per pin. Prefer `inst.pinout`, fall back to
    // `inst.symbol`, then `inst.component`.
    var ref_to_lookup: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (block.instances) |inst| {
        const lookup = if (inst.pinout.len > 0) inst.pinout else if (inst.symbol.len > 0) inst.symbol else inst.component;
        if (lookup.len == 0) continue;
        try ref_to_lookup.put(allocator, inst.ref_des, lookup);
    }

    // Track (ref_des|pin_id) pairs we've already emitted "required" errors for so
    // multiple net occurrences of the same physical pin don't produce duplicates.
    var required_seen: std.StringHashMapUnmanaged(void) = .empty;

    for (block.nets) |net| {
        for (net.pins) |pin| {
            const symbol = ref_to_lookup.get(pin.ref_des) orelse continue;

            const gop = pinout_cache.getOrPut(allocator, symbol) catch continue;
            if (!gop.found_existing) {
                const path = std.fmt.allocPrint(allocator, "{s}/lib/pinouts/{s}.sexp", .{ project_dir, symbol }) catch {
                    gop.value_ptr.* = null;
                    continue;
                };
                gop.value_ptr.* = loadPinoutMap(allocator, path);
            }
            const pinout_map = gop.value_ptr.* orelse continue;

            const entry = pinout_map.get(pin.pin) orelse continue;

            // Rule 2: pin has 2+ alts but no (as ...). Skip pure-power
            // pads (no alts) AND single-alt pins (which the build-time
            // enrichment pass auto-resolves to their one option) — only
            // genuinely ambiguous pins demand an explicit `as`.
            if (pin.asserted_fns.len == 0) {
                if (entry.alts.len < 2) continue;
                const seen_key = std.fmt.allocPrint(allocator, "{s}|{s}", .{ pin.ref_des, pin.pin }) catch continue;
                if (required_seen.contains(seen_key)) continue;
                try required_seen.put(allocator, seen_key, {});
                const msg = formatRequiredMsg(allocator, pin.ref_des, pin.pin, na.baseNetName(net.name), entry) orelse continue;
                try violations.append(allocator, .{
                    .kind = .pin_function_required,
                    .severity = .@"error",
                    .message = msg,
                    .ref_des = pin.ref_des,
                    .net = na.baseNetName(net.name),
                });
                continue;
            }

            // Rule 1: every asserted function must resolve.
            for (pin.asserted_fns) |asserted| {
                if (std.mem.eql(u8, asserted, entry.primary)) continue;
                var matched = false;
                for (entry.alts) |alt| {
                    if (std.mem.eql(u8, asserted, alt)) {
                        matched = true;
                        break;
                    }
                }
                if (matched) continue;

                const msg = formatFunctionMsg(allocator, pin.ref_des, pin.pin, asserted, na.baseNetName(net.name), entry) orelse continue;
                try violations.append(allocator, .{
                    .kind = .pin_function_unsupported,
                    .severity = .@"error",
                    .message = msg,
                    .ref_des = pin.ref_des,
                    .net = na.baseNetName(net.name),
                });
            }
        }
    }

    for (block.sub_blocks) |sb| {
        try checkBlockPinFunctions(allocator, sb.block, project_dir, pinout_cache, violations);
    }
}

fn formatFunctionMsg(
    allocator: std.mem.Allocator,
    ref_des: []const u8,
    pin_id: []const u8,
    asserted: []const u8,
    net: []const u8,
    entry: PinoutEntry,
) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    w.print(
        "{s} pin {s} (net \"{s}\") does not support function \"{s}\". Allowed: {s}",
        .{ ref_des, pin_id, net, asserted, entry.primary },
    ) catch return null;
    for (entry.alts) |alt| {
        w.print(", {s}", .{alt}) catch return null;
    }
    w.writeByte('.') catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

fn formatRequiredMsg(allocator: std.mem.Allocator, ref_des: []const u8, pin_id: []const u8, net: []const u8, entry: PinoutEntry) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    w.print(
        "{s} pin {s} (net \"{s}\") has alternate functions but no `(as \"FN\")` was specified. Pick one of: {s}",
        .{ ref_des, pin_id, net, entry.primary },
    ) catch return null;
    for (entry.alts) |alt| {
        w.print(", {s}", .{alt}) catch return null;
    }
    w.writeByte('.') catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// Flatten this block and all nested sub-blocks into one instance slice. The
/// returned slice is owned by `allocator` — callers must free it (via
/// `toOwnedSlice` it is shrunk to exact length, so a plain `allocator.free`
/// is size-correct).
fn collectAllInstances(allocator: std.mem.Allocator, block: *const DesignBlock) ![]const Instance {
    var list: std.ArrayList(Instance) = .empty;
    errdefer list.deinit(allocator);
    try appendInstances(allocator, &list, block);
    return list.toOwnedSlice(allocator);
}

fn appendInstances(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Instance),
    block: *const DesignBlock,
) !void {
    for (block.instances) |inst| try list.append(allocator, inst);
    for (block.sub_blocks) |sb| try appendInstances(allocator, list, sb.block);
}

/// Serialize violations to JSON.
pub fn writeViolationsJson(allocator: std.mem.Allocator, violations: []const Violation) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll("[");
    for (violations, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"kind\":\"");
        try w.writeAll(@tagName(v.kind));
        try w.writeAll("\",\"severity\":\"");
        try w.writeAll(@tagName(v.severity));
        try w.writeAll("\",\"message\":\"");
        try writeJsonEscaped(w, v.message);
        try w.writeAll("\"");
        if (v.ref_des.len > 0) {
            try w.writeAll(",\"ref\":\"");
            try writeJsonEscaped(w, v.ref_des);
            try w.writeAll("\"");
        }
        if (v.net.len > 0) {
            try w.writeAll(",\"net\":\"");
            try writeJsonEscaped(w, v.net);
            try w.writeAll("\"");
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
    return buf.items;
}

const writeJsonEscaped = json_writer.writeEscaped;

// ── Tests ──────────────────────────────────────────────────────────────

fn makeBudgetBlock(
    alloc: std.mem.Allocator,
    rail: []const u8,
    src_label: []const u8,
    src_typ: ?f64,
    src_max: ?f64,
    loads: []const struct { ref: []const u8, typ: ?f64, max: ?f64 },
) !DesignBlock {
    // Sub-block with an "out" port carrying the declared capacity.
    const sub_ports = try alloc.alloc(env_mod.Port, 1);
    sub_ports[0] = .{
        .name = "VOUT",
        .net = "VOUT",
        .direction = "out",
        .current_typ = src_typ,
        .current_max = src_max,
    };
    const sub = try alloc.create(DesignBlock);
    sub.* = .{
        .name = "buck",
        .instances = &.{},
        .nets = &.{},
        .ports = sub_ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sub_blocks = try alloc.alloc(env_mod.SubBlock, 1);
    sub_blocks[0] = .{ .name = src_label, .block = sub };

    // Top-level net with the load pin refs.
    const pins = try alloc.alloc(env_mod.PinRef, loads.len);
    for (loads, 0..) |l, i| {
        pins[i] = .{ .ref_des = l.ref, .pin = "1", .i_typ = l.typ, .i_max = l.max };
    }
    const nets = try alloc.alloc(env_mod.Net, 1);
    nets[0] = .{ .name = rail, .pins = pins };

    // Tie "{src_label}/VOUT" into the top-level rail.
    const tie_b = try std.fmt.allocPrint(alloc, "{s}/VOUT", .{src_label});
    const ties = try alloc.alloc(env_mod.NetTie, 1);
    ties[0] = .{ .a = rail, .b = tie_b };

    return .{
        .name = "test",
        .instances = &.{},
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = sub_blocks,
        .net_ties = ties,
    };
}

// spec: erc - Emits power_budget error when load max exceeds source max
test "power budget over-max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block = try makeBudgetBlock(alloc, "VDD", "buck", 2.0, 2.0, &.{
        .{ .ref = "U1", .typ = 1.0, .max = 1.5 },
        .{ .ref = "U2", .typ = 1.0, .max = 1.5 },
    });
    var violations: std.ArrayList(Violation) = .empty;
    try checkPowerBudget(alloc, &block, &violations);
    var hit_error = false;
    for (violations.items) |v| {
        if (v.kind == .power_budget and v.severity == .@"error") hit_error = true;
    }
    try std.testing.expect(hit_error);
}

// spec: erc - Emits power_budget warning when typ load is above 80 percent of source typ
test "power budget tight margin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block = try makeBudgetBlock(alloc, "VDD", "buck", 2.0, 2.5, &.{
        .{ .ref = "U1", .typ = 1.7, .max = 2.0 },
    });
    var violations: std.ArrayList(Violation) = .empty;
    try checkPowerBudget(alloc, &block, &violations);
    var hit_warning = false;
    var hit_error = false;
    for (violations.items) |v| {
        if (v.kind != .power_budget) continue;
        if (v.severity == .warning) hit_warning = true;
        if (v.severity == .@"error") hit_error = true;
    }
    try std.testing.expect(hit_warning);
    try std.testing.expect(!hit_error);
}

// spec: erc - Emits no power_budget violation when load is well below source capacity
test "power budget within budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block = try makeBudgetBlock(alloc, "VDD", "buck", 2.0, 2.5, &.{
        .{ .ref = "U1", .typ = 0.4, .max = 0.6 },
    });
    var violations: std.ArrayList(Violation) = .empty;
    try checkPowerBudget(alloc, &block, &violations);
    for (violations.items) |v| {
        try std.testing.expect(v.kind != .power_budget);
    }
}

// Test fixture: single-instance block where U1 uses pin "A1" of a fake "testchip"
// pinout. `asserted_fns` is plumbed through to the PinRef so we can exercise the
// assertion rules without setting up a full eval pipeline.
fn makePinFunctionBlock(
    alloc: std.mem.Allocator,
    pin_id: []const u8,
    asserted_fns: []const []const u8,
) !DesignBlock {
    const insts = try alloc.alloc(Instance, 1);
    insts[0] = .{
        .ref_des = "U1",
        .component = "testchip",
        .value = "",
        .footprint = "",
        .symbol = "",
        .pinout = "testchip",
        .properties = &.{},
        .attrs = &.{},
        .source_offset = 0,
        .id = "00000001",
    };
    const pins = try alloc.alloc(env_mod.PinRef, 1);
    pins[0] = .{ .ref_des = "U1", .pin = pin_id, .asserted_fns = asserted_fns };
    const nets = try alloc.alloc(env_mod.Net, 1);
    nets[0] = .{ .name = "SIG", .pins = pins };
    return .{
        .name = "test",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_ties = &.{},
    };
}

const pinout_fixture =
    \\(pinout "testchip"
    \\  (pin A1 "PA1"
    \\    (alt "SPI1_MOSI" io)
    \\    (alt "TIM1_CH1" io))
    \\  (pin B1 "VDD")
    \\  (pin C1 "PC1"
    \\    (alt "USART2_TX" io))
    \\)
;

// Create a temp directory with lib/pinouts/testchip.sexp so checkPinFunctions
// can resolve the fixture. Returns a TmpDir (caller must cleanup) and its path.
fn makePinoutTmp(alloc: std.mem.Allocator) !struct { tmp: std.testing.TmpDir, path: []const u8 } {
    var tmp = std.testing.tmpDir(.{});
    try tmp.dir.makePath("lib/pinouts");
    try tmp.dir.writeFile(.{ .sub_path = "lib/pinouts/testchip.sexp", .data = pinout_fixture });
    const path = try tmp.dir.realpathAlloc(alloc, ".");
    return .{ .tmp = tmp, .path = path };
}

// spec: erc - Requires pin function assertion when pinout defines alternates
test "pin function required when alts exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fx = try makePinoutTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    const block = try makePinFunctionBlock(alloc, "A1", &.{});
    var violations: std.ArrayList(Violation) = .empty;
    try checkPinFunctions(alloc, &block, fx.path, &violations);

    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .pin_function_required and v.severity == .@"error") hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Allows pins without alternates to omit (as ...)
test "pin function not required when no alts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fx = try makePinoutTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    // B1 in the fixture is a power pin with no alts — no assertion needed.
    const block = try makePinFunctionBlock(alloc, "B1", &.{});
    var violations: std.ArrayList(Violation) = .empty;
    try checkPinFunctions(alloc, &block, fx.path, &violations);

    for (violations.items) |v| {
        try std.testing.expect(v.kind != .pin_function_required);
    }
}

// spec: erc - Accepts multiple asserted functions on a single pin
test "pin function multi assertion validated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fx = try makePinoutTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    // Both functions exist in the pinout — no violation.
    const block = try makePinFunctionBlock(alloc, "A1", &.{ "SPI1_MOSI", "TIM1_CH1" });
    var violations: std.ArrayList(Violation) = .empty;
    try checkPinFunctions(alloc, &block, fx.path, &violations);

    for (violations.items) |v| {
        try std.testing.expect(v.kind != .pin_function_unsupported);
        try std.testing.expect(v.kind != .pin_function_required);
    }
}

// spec: erc - Resolves pin lookup by logical name when source uses logical pin id
test "pin function lookup resolves by logical name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fx = try makePinoutTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    // "PA1" is the logical name for BGA-position "A1". Before the
    // dual-key fix, looking up "PA1" missed the map entirely and the
    // check silently passed — so the assertion is that the check now
    // *fires* (PA1 has 2 alts, no `as`) instead of no-oping.
    const block = try makePinFunctionBlock(alloc, "PA1", &.{});
    var violations: std.ArrayList(Violation) = .empty;
    try checkPinFunctions(alloc, &block, fx.path, &violations);

    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .pin_function_required) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Skips pin function required check for single alt pins
test "pin function not required when single alt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fx = try makePinoutTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    // C1 has exactly one alt (USART2_TX). With the >= 2 threshold the
    // pin doesn't need an explicit `as` — the auto-fill pass will pick
    // the unique alt for downstream consumers.
    const block = try makePinFunctionBlock(alloc, "C1", &.{});
    var violations: std.ArrayList(Violation) = .empty;
    try checkPinFunctions(alloc, &block, fx.path, &violations);

    for (violations.items) |v| {
        try std.testing.expect(v.kind != .pin_function_required);
    }
}

// spec: erc - Rejects asserted function that is not in the pinout
test "pin function unsupported across slice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var fx = try makePinoutTmp(alloc);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);

    // TIM1_CH1 is valid, but UART9_TX is not on this pin — errors on the second.
    const block = try makePinFunctionBlock(alloc, "A1", &.{ "TIM1_CH1", "UART9_TX" });
    var violations: std.ArrayList(Violation) = .empty;
    try checkPinFunctions(alloc, &block, fx.path, &violations);

    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .pin_function_unsupported and std.mem.indexOf(u8, v.message, "UART9_TX") != null) hit = true;
    }
    try std.testing.expect(hit);
}

// Build a minimal DesignBlock carrying a single PowerRail and optional
// test-point sources for exercising the coverage check.
fn makeRailBlock(
    alloc: std.mem.Allocator,
    rail_name: []const u8,
    aliases: []const []const u8,
    tps: []const env_mod.TestPoint,
    legacy_tp_nets: []const []const u8,
) !DesignBlock {
    const rails = try alloc.alloc(env_mod.PowerRail, 1);
    rails[0] = .{
        .name = rail_name,
        .aliases = aliases,
        .source_ref_des = "buck",
        .source_port = "VOUT",
    };
    // Legacy test points show up as instances + nets connecting them.
    const insts = try alloc.alloc(env_mod.Instance, legacy_tp_nets.len);
    const nets = try alloc.alloc(env_mod.Net, legacy_tp_nets.len);
    for (legacy_tp_nets, 0..) |net_name, i| {
        const ref = try std.fmt.allocPrint(alloc, "TP{d}", .{i + 1});
        insts[i] = .{
            .ref_des = ref,
            .component = "testpoint",
            .value = "",
            .footprint = "",
            .symbol = "",
        };
        const pins = try alloc.alloc(env_mod.PinRef, 1);
        pins[0] = .{ .ref_des = ref, .pin = "1" };
        nets[i] = .{ .name = net_name, .pins = pins };
    }
    return .{
        .name = "test",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .rails = rails,
        .test_points = tps,
    };
}

// spec: erc - Flags a power rail with no test point on its net or any alias
test "test point missing on rail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block = try makeRailBlock(alloc, "VDD_3V3", &.{}, &.{}, &.{});
    var violations: std.ArrayList(Violation) = .empty;
    try checkTestPointCoverage(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .test_point_missing and std.mem.eql(u8, v.net, "VDD_3V3")) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Recognises test points declared via the test-point form
test "test point coverage from first-class form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const tps = [_]env_mod.TestPoint{.{ .ref_des = "TP1", .net = "VDD_3V3" }};
    const block = try makeRailBlock(alloc, "VDD_3V3", &.{}, &tps, &.{});
    var violations: std.ArrayList(Violation) = .empty;
    try checkTestPointCoverage(alloc, &block, &violations);
    for (violations.items) |v| try std.testing.expect(v.kind != .test_point_missing);
}

// spec: erc - Recognises legacy testpoint component instances as test points
test "test point coverage from legacy testpoint instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const legacy = [_][]const u8{"VDD_3V3"};
    const block = try makeRailBlock(alloc, "VDD_3V3", &.{}, &.{}, &legacy);
    var violations: std.ArrayList(Violation) = .empty;
    try checkTestPointCoverage(alloc, &block, &violations);
    for (violations.items) |v| try std.testing.expect(v.kind != .test_point_missing);
}

// spec: erc - Emits no test point violation when every rail has a test point
test "test point coverage via ferrite-bridged alias" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const aliases = [_][]const u8{"VDDA18USB"};
    const tps = [_]env_mod.TestPoint{.{ .ref_des = "TP1", .net = "VDDA18USB" }};
    const block = try makeRailBlock(alloc, "V1P8", &aliases, &tps, &.{});
    var violations: std.ArrayList(Violation) = .empty;
    try checkTestPointCoverage(alloc, &block, &violations);
    for (violations.items) |v| try std.testing.expect(v.kind != .test_point_missing);
}

// Build a DesignBlock with a single sourced rail and a configurable set of
// consumer pins + nominal voltage, for the power-tree integrity checks.
fn makeIntegrityBlock(
    alloc: std.mem.Allocator,
    rail_name: []const u8,
    source_ref: []const u8,
    nominal: ?f64,
    consumer_nets: []const []const u8,
) !DesignBlock {
    const rails = try alloc.alloc(env_mod.PowerRail, 1);
    rails[0] = .{
        .name = rail_name,
        .source_ref_des = source_ref,
        .source_port = "VOUT",
        .nominal = nominal,
    };
    const nets = try alloc.alloc(env_mod.Net, consumer_nets.len);
    for (consumer_nets, 0..) |n, i| {
        const pins = try alloc.alloc(env_mod.PinRef, 1);
        pins[0] = .{ .ref_des = "U1", .pin = "1" };
        nets[i] = .{ .name = n, .pins = pins };
    }
    return .{
        .name = "integrity-fixture",
        .instances = &.{},
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .rails = rails,
    };
}

// spec: erc - Flags a power rail with a declared source but no consumer pins
test "power tree integrity flags source_unused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block = try makeIntegrityBlock(alloc, "VDD_3V3", "buck", 3.3, &.{});
    var violations: std.ArrayList(Violation) = .empty;
    try checkPowerTreeIntegrity(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .source_unused and std.mem.eql(u8, v.net, "VDD_3V3")) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Flags a power rail whose nominal voltage cannot be resolved
test "power tree integrity flags rail_voltage_unresolved" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block = try makeIntegrityBlock(alloc, "VDD_3V3", "buck", null, &.{"VDD_3V3"});
    var violations: std.ArrayList(Violation) = .empty;
    try checkPowerTreeIntegrity(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .rail_voltage_unresolved and std.mem.eql(u8, v.net, "VDD_3V3")) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Emits no integrity violation on a fully-resolved rail with consumers
test "power tree integrity clean rail emits nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block = try makeIntegrityBlock(alloc, "VDD_3V3", "buck", 3.3, &.{"VDD_3V3"});
    var violations: std.ArrayList(Violation) = .empty;
    try checkPowerTreeIntegrity(alloc, &block, &violations);
    for (violations.items) |v| {
        try std.testing.expect(v.kind != .source_unused);
        try std.testing.expect(v.kind != .rail_voltage_unresolved);
    }
}

// Build a rail whose only consumers are sub-block ports reached through
// net-ties (no direct component pin on the top-level rail net) — mirrors a
// regulator feeding another sub-block's input port (e.g. iso-DCDC → LDO VIN).
fn makeTiedRailBlock(
    alloc: std.mem.Allocator,
    rail_name: []const u8,
    source_path: []const u8,
    ties: []const env_mod.NetTie,
) !DesignBlock {
    const rails = try alloc.alloc(env_mod.PowerRail, 1);
    rails[0] = .{
        .name = rail_name,
        .source_ref_des = "iso_dmm",
        .source_port = "VOUT_ISO",
        .source_path = source_path,
        .nominal = 5.0,
    };
    return .{
        .name = "tied-rail-fixture",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_ties = ties,
        .rails = rails,
    };
}

// spec: erc - Treats a sub-block input port wired via net-tie as a rail consumer
test "power tree integrity counts sub-block port consumer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Source tie + a genuine downstream consumer tie (dmm_ldo/VIN).
    const ties = [_]env_mod.NetTie{
        .{ .a = "VDD5_ISO", .b = "iso_dmm/VOUT_ISO" },
        .{ .a = "VDD5_ISO", .b = "dmm_ldo/VIN" },
    };
    const block = try makeTiedRailBlock(alloc, "VDD5_ISO", "iso_dmm/VOUT_ISO", &ties);
    var violations: std.ArrayList(Violation) = .empty;
    try checkPowerTreeIntegrity(alloc, &block, &violations);
    for (violations.items) |v| try std.testing.expect(v.kind != .source_unused);
}

// spec: erc - Flags a rail whose only net-tie is its own source port (no consumer)
test "power tree integrity flags rail tied only to its own source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // Only the source tie — the regulator output genuinely goes nowhere.
    const ties = [_]env_mod.NetTie{
        .{ .a = "VDD5_ISO", .b = "iso_dmm/VOUT_ISO" },
    };
    const block = try makeTiedRailBlock(alloc, "VDD5_ISO", "iso_dmm/VOUT_ISO", &ties);
    var violations: std.ArrayList(Violation) = .empty;
    try checkPowerTreeIntegrity(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .source_unused and std.mem.eql(u8, v.net, "VDD5_ISO")) hit = true;
    }
    try std.testing.expect(hit);
}

// Build a block with a single IC instance and a caller-chosen power-pin net,
// for the IC-power-presence heuristic (checkUnconnectedPowerPins).
fn makePowerPinBlock(
    alloc: std.mem.Allocator,
    component: []const u8,
    power_net: []const u8,
) !DesignBlock {
    const insts = try alloc.alloc(Instance, 1);
    insts[0] = .{ .ref_des = "U1", .component = component, .value = "", .footprint = "", .symbol = "" };
    const nets = try alloc.alloc(Net, 2);
    const gnd_pins = try alloc.alloc(env_mod.PinRef, 1);
    gnd_pins[0] = .{ .ref_des = "U1", .pin = "1" };
    const pwr_pins = try alloc.alloc(env_mod.PinRef, 1);
    pwr_pins[0] = .{ .ref_des = "U1", .pin = "2" };
    nets[0] = .{ .name = "GND", .pins = gnd_pins };
    nets[1] = .{ .name = power_net, .pins = pwr_pins };
    return .{
        .name = "power-pin-fixture",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

// spec: erc - Recognises a VREF-supplied level translator as powered (no false positive)
test "power pins VREF-supplied translator is not flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // LSF0108 has no VDD/VCC pin — it is supplied through VREF_A/VREF_B.
    const block = try makePowerPinBlock(alloc, "lsf0108rksr", "VREF_A");
    var violations: std.ArrayList(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, "", &violations);
    for (violations.items) |v| {
        try std.testing.expect(!std.mem.eql(u8, v.message, "U1: IC has no power connection"));
    }
}

// spec: erc - Still flags an IC with a ground pin but no recognised power net
test "power pins missing supply still flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // "SIGNAL" is not a power-net name → the IC has ground but no power.
    const block = try makePowerPinBlock(alloc, "someic", "SIGNAL");
    var violations: std.ArrayList(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, "", &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .unconnected_pin and std.mem.eql(u8, v.ref_des, "U1") and
            std.mem.indexOf(u8, v.message, "no power connection") != null) hit = true;
    }
    try std.testing.expect(hit);
}

// Build a temp project dir with a single lib/pinouts/<name>.sexp fixture so the
// power-pin check can read a part's function names. Caller cleans up + frees path.
fn makePowerPinoutTmp(alloc: std.mem.Allocator, name: []const u8, body: []const u8) !struct { tmp: std.testing.TmpDir, path: []const u8 } {
    var tmp = std.testing.tmpDir(.{});
    try tmp.dir.makePath("lib/pinouts");
    const sub = try std.fmt.allocPrint(alloc, "lib/pinouts/{s}.sexp", .{name});
    try tmp.dir.writeFile(.{ .sub_path = sub, .data = body });
    const path = try tmp.dir.realpathAlloc(alloc, ".");
    return .{ .tmp = tmp, .path = path };
}

// spec: erc - A passive RF part (no supply pin in its pinout) is not flagged for missing power
test "power pins passive RF part with no supply pin is not flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A 2-port attenuator/filter: RF-IN / RF-OUT / GND only — no supply pin, so
    // "IC has no power connection" must not fire even with a U ref-des.
    const pinout =
        \\(pinout "rfpad"
        \\  (pin 1 "GND_1")
        \\  (pin 2 "RF-IN")
        \\  (pin 3 "GND_2")
        \\  (pin 4 "RF-OUT")
        \\)
    ;
    var fx = try makePowerPinoutTmp(alloc, "rfpad", pinout);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);
    // The fixture wires a GND net + a non-power "RF_SIGNAL" net. Were rfpad
    // treated as an IC the missing supply would fire; has_supply gating (its
    // pinout has no supply pin) must suppress the "no power connection" warning.
    const block = try makePowerPinBlock(alloc, "rfpad", "RF_SIGNAL");
    var violations: std.ArrayList(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, fx.path, &violations);
    for (violations.items) |v| {
        try std.testing.expect(std.mem.indexOf(u8, v.message, "no power connection") == null);
        try std.testing.expect(std.mem.indexOf(u8, v.message, "no ground connection") == null);
    }
}

// spec: erc - A real IC with a VCC pin in its pinout but no power net is still flagged
test "power pins real IC with supply pin still flagged when unpowered" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // An EEPROM-shaped part: VCC + VSS in the pinout. Connected only to a signal
    // net, so the missing supply must still be reported (no regression).
    const pinout =
        \\(pinout "eeprom"
        \\  (pin 1 "SCL")
        \\  (pin 2 "VSS")
        \\  (pin 3 "SDA")
        \\  (pin 4 "VCC")
        \\)
    ;
    var fx = try makePowerPinoutTmp(alloc, "eeprom", pinout);
    defer fx.tmp.cleanup();
    defer alloc.free(fx.path);
    const block = try makePowerPinBlock(alloc, "eeprom", "SIGNAL");
    var violations: std.ArrayList(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, fx.path, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (std.mem.eql(u8, v.message, "U1: IC has no power connection")) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Recognises a post-filter local supply node ending in VDD/VCC as power
test "power pins SW_VDD local supply node is recognised as power" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // The PE42553 cal switch is powered through V_3V3D → FB_VDD → SW_VDD; its
    // VDD pad sits on the renamed local node "SW_VDD", which must read as power.
    const block = try makePowerPinBlock(alloc, "someic", "SW_VDD");
    var violations: std.ArrayList(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, "", &violations);
    for (violations.items) |v| {
        try std.testing.expect(!std.mem.eql(u8, v.message, "U1: IC has no power connection"));
    }
}

// spec: erc - Recognises a V<int>P<frac> rail such as the 5V V5P0 as power
test "power pins V5P0 rail is recognised as power" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // The NeoPixel level shifter's VCC sits on the 5V board rail "V5P0".
    // The old V1P/V2P/V3P3 list missed it and falsely flagged "no power".
    const block = try makePowerPinBlock(alloc, "someic", "V5P0");
    var violations: std.ArrayList(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, "", &violations);
    for (violations.items) |v| {
        try std.testing.expect(!std.mem.eql(u8, v.message, "U1: IC has no power connection"));
    }
}

// spec: erc - Test points are exempt from the IC-ground/power check
test "test point is not flagged for missing ground/power" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A `testpoint` part connecting only a signal net. Even if it somehow
    // carried a U ref-des, it must not trip "IC has no ground/power" — it is a
    // single-pad probe pad, not an IC. (Normally it gets a "TP" ref-des.)
    const insts = try alloc.alloc(Instance, 1);
    insts[0] = .{ .ref_des = "U7", .component = "testpoint", .value = "", .footprint = "", .symbol = "" };
    const sig_pins = try alloc.alloc(env_mod.PinRef, 1);
    sig_pins[0] = .{ .ref_des = "U7", .pin = "1" };
    const nets = try alloc.alloc(Net, 1);
    nets[0] = .{ .name = "STATUS0", .pins = sig_pins };
    const block: DesignBlock = .{
        .name = "tp-fixture",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, "", &violations);
    for (violations.items) |v| {
        try std.testing.expect(std.mem.indexOf(u8, v.message, "no ground connection") == null);
        try std.testing.expect(std.mem.indexOf(u8, v.message, "no power connection") == null);
    }
}

// Build a single-net DesignBlock with two pins whose ElectricalDecls are
// configured by the caller, for voltage-domain compatibility tests.
fn makeDomainBlock(
    alloc: std.mem.Allocator,
    net_name: []const u8,
    driver_oh_typ: f64,
    receiver_ih_min: f64,
) !DesignBlock {
    const drv_elec = try alloc.alloc(env_mod.ElectricalDecl, 1);
    drv_elec[0] = .{
        .pin = "1",
        .electrical_type = .output,
        .v_oh_typ = driver_oh_typ,
    };
    const rcv_elec = try alloc.alloc(env_mod.ElectricalDecl, 1);
    rcv_elec[0] = .{
        .pin = "1",
        .electrical_type = .input,
        .v_ih_min = receiver_ih_min,
    };
    const insts = try alloc.alloc(env_mod.Instance, 2);
    insts[0] = .{
        .ref_des = "U1",
        .component = "drv",
        .value = "",
        .footprint = "",
        .symbol = "",
        .electrical = drv_elec,
    };
    insts[1] = .{
        .ref_des = "U2",
        .component = "rcv",
        .value = "",
        .footprint = "",
        .symbol = "",
        .electrical = rcv_elec,
    };
    const pins = try alloc.alloc(env_mod.PinRef, 2);
    pins[0] = .{ .ref_des = "U1", .pin = "1" };
    pins[1] = .{ .ref_des = "U2", .pin = "1" };
    const nets = try alloc.alloc(env_mod.Net, 1);
    nets[0] = .{ .name = net_name, .pins = pins };
    return .{
        .name = "domain-fixture",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
}

// spec: erc - Flags a net where the worst driver high level is below the worst receiver high threshold
test "voltage-domain incompatibility flagged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 1V8 CMOS driver (v_oh_typ 1.7V) into 3V3 CMOS receiver (v_ih_min 2.31V).
    const block = try makeDomainBlock(alloc, "SIG", 1.7, 2.31);
    var violations: std.ArrayList(Violation) = .empty;
    try checkVoltageDomainCompat(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .voltage_domain_incompatible and std.mem.eql(u8, v.net, "SIG")) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Emits no voltage-domain violation when driver and receiver levels are compatible
test "voltage-domain compatible levels pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 3V3 CMOS driver (v_oh_typ 3.1V) into 1V8 CMOS receiver (v_ih_min 1.17V).
    const block = try makeDomainBlock(alloc, "SIG", 3.1, 1.17);
    var violations: std.ArrayList(Violation) = .empty;
    try checkVoltageDomainCompat(alloc, &block, &violations);
    for (violations.items) |v| {
        try std.testing.expect(v.kind != .voltage_domain_incompatible);
    }
}

// spec: erc - Treats a section port with electrical metadata as a virtual driver and receiver on its net
test "section port electrical decl flags incompatible receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A bare receiver pin on net "SIG" with v_ih_min=2.31 V (3.3 V CMOS).
    // No component driver — the driver is a section port that declares
    // v_oh_typ=1.7 V (1.8 V CMOS). Check that the port acts as the virtual
    // driver and the pair gets flagged.
    const rcv_elec = try alloc.alloc(env_mod.ElectricalDecl, 1);
    rcv_elec[0] = .{ .pin = "1", .electrical_type = .input, .v_ih_min = 2.31 };
    const insts = try alloc.alloc(env_mod.Instance, 1);
    insts[0] = .{
        .ref_des = "U1",
        .component = "rcv",
        .value = "",
        .footprint = "",
        .symbol = "",
        .electrical = rcv_elec,
    };
    const pins = try alloc.alloc(env_mod.PinRef, 1);
    pins[0] = .{ .ref_des = "U1", .pin = "1" };
    const nets = try alloc.alloc(env_mod.Net, 1);
    nets[0] = .{ .name = "SIG", .pins = pins };

    const sec_ports = try alloc.alloc(env_mod.SectionPort, 1);
    sec_ports[0] = .{
        .name = "SIG",
        .direction = .out,
        .electrical = .{ .pin = "SIG", .electrical_type = .output, .v_oh_typ = 1.7 },
    };
    const secs = try alloc.alloc(env_mod.Section, 1);
    secs[0] = .{ .name = "Mezz", .ports = sec_ports };

    const block: DesignBlock = .{
        .name = "port-fixture",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .sections = secs,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var violations: std.ArrayList(Violation) = .empty;
    try checkVoltageDomainCompat(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .voltage_domain_incompatible and std.mem.eql(u8, v.net, "SIG")) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Treats a top-level design port with electrical metadata as a virtual driver and receiver on its net
test "top-level port electrical decl flags incompatible receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Mirror of the section-port test, but the boundary contract lives on
    // a top-level `(port …)` instead of a section port. Net resolves via
    // the port's explicit `net` field.
    const rcv_elec = try alloc.alloc(env_mod.ElectricalDecl, 1);
    rcv_elec[0] = .{ .pin = "1", .electrical_type = .input, .v_ih_min = 2.31 };
    const insts = try alloc.alloc(env_mod.Instance, 1);
    insts[0] = .{
        .ref_des = "U1",
        .component = "rcv",
        .value = "",
        .footprint = "",
        .symbol = "",
        .electrical = rcv_elec,
    };
    const pins = try alloc.alloc(env_mod.PinRef, 1);
    pins[0] = .{ .ref_des = "U1", .pin = "1" };
    const nets = try alloc.alloc(env_mod.Net, 1);
    nets[0] = .{ .name = "BUS", .pins = pins };

    const top_ports = try alloc.alloc(env_mod.Port, 1);
    top_ports[0] = .{
        .name = "BUS_OUT",
        .net = "BUS",
        .direction = "out",
        .electrical = .{ .pin = "BUS_OUT", .electrical_type = .output, .v_oh_typ = 1.7 },
    };

    const block: DesignBlock = .{
        .name = "top-port-fixture",
        .instances = insts,
        .nets = nets,
        .ports = top_ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var violations: std.ArrayList(Violation) = .empty;
    try checkVoltageDomainCompat(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .voltage_domain_incompatible and std.mem.eql(u8, v.net, "BUS")) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Flags a sequencing cycle by emitting sequence_cycle per affected rail
test "sequencing cycle detected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build two sub-blocks whose enables form a cycle: A.enable = "VB",
    // B.enable = "VA". Both rails are power outputs with declared nominal.
    const a_ports = try alloc.alloc(env_mod.Port, 1);
    a_ports[0] = .{
        .name = "VOUT",
        .net = "VOUT",
        .direction = "out",
        .nominal = 3.3,
        .enable_net = "VB",
    };
    const a_block = try alloc.create(DesignBlock);
    a_block.* = .{
        .name = "a",
        .instances = &.{},
        .nets = &.{},
        .ports = a_ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const b_ports = try alloc.alloc(env_mod.Port, 1);
    b_ports[0] = .{
        .name = "VOUT",
        .net = "VOUT",
        .direction = "out",
        .nominal = 1.8,
        .enable_net = "VA",
    };
    const b_block = try alloc.create(DesignBlock);
    b_block.* = .{
        .name = "b",
        .instances = &.{},
        .nets = &.{},
        .ports = b_ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = try alloc.alloc(env_mod.SubBlock, 2);
    sbs[0] = .{ .name = "a", .block = a_block };
    sbs[1] = .{ .name = "b", .block = b_block };
    const ties = try alloc.alloc(env_mod.NetTie, 2);
    ties[0] = .{ .a = "a/VOUT", .b = "VA" };
    ties[1] = .{ .a = "b/VOUT", .b = "VB" };
    const block: DesignBlock = .{
        .name = "cycle-fixture",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = sbs,
        .net_ties = ties,
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkSequencingCycles(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .sequence_cycle) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Exempts connectors, ignore-requirements support parts, and passive-class components from the requirements warning
test "missing requirements exempts connectors, support parts, and passive-class components" {
    const instances = [_]Instance{
        // Connector — exempt purely by ref-des prefix (J), no opt-out needed.
        .{
            .ref_des = "J1",
            .component = "usb4510-03-1-a-gct",
            .value = "",
            .footprint = "",
            .symbol = "",
            .requirements = &.{},
        },
        // A board-to-board connector that lands on the IC `U` prefix but
        // declares (ignore-requirements).
        .{
            .ref_des = "U9",
            .component = "204928-0601",
            .value = "",
            .footprint = "2049280601",
            .symbol = "",
            .requirements_ignored = true,
            .requirements = &.{},
        },
        // ESD array — hub prefix but passive-class component.
        .{
            .ref_des = "U10",
            .component = "ecmf04-4hsm10",
            .value = "",
            .footprint = "",
            .symbol = "",
            .requirements = &.{},
        },
        // Crystal — passive-class component (abm prefix).
        .{
            .ref_des = "Y1",
            .component = "abm8",
            .value = "",
            .footprint = "",
            .symbol = "",
            .requirements = &.{},
        },
    };
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkMissingRequirements(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

// spec: erc - Recognizes KiCad-style signed rails (+5V, -5.0V, +3V3, +5_0V) as power nets
test "signed voltage rails count as power" {
    try std.testing.expect(isSignedVoltRail("+5V"));
    try std.testing.expect(isSignedVoltRail("-5.0V"));
    try std.testing.expect(isSignedVoltRail("+3V3"));
    try std.testing.expect(isSignedVoltRail("+12V"));
    try std.testing.expect(isSignedVoltRail("+5_0V"));
    try std.testing.expect(!isSignedVoltRail("+EDGE"));
    try std.testing.expect(!isSignedVoltRail("MOSI"));
    try std.testing.expect(!isSignedVoltRail("-X5V"));
}

// spec: erc - Recognizes V_ underscore rails (V_3V3D, V_RF_3P3) as power nets
test "underscore voltage rails count as power" {
    // Both the leading 'V' and the '_' are required; a `!=`→`==` flip on either
    // bound rejects these valid rails (or accepts the invalid X_/VX cases).
    try std.testing.expect(isUnderscoreRail("V_3V3D"));
    try std.testing.expect(isUnderscoreRail("V_RF_3P3"));
    try std.testing.expect(!isUnderscoreRail("V_SENSE")); // no digit ⇒ not a rail
    try std.testing.expect(!isUnderscoreRail("X_3V3")); // wrong first char
    try std.testing.expect(!isUnderscoreRail("VX3V3")); // no underscore
}

// spec: erc - Accepts an MPN-identified fixed component as a valued passive (no missing_value)
test "passive ref on an MPN-identified fixed component is not missing a value" {
    const instances = [_]Instance{
        // KiCad-imported chip inductor: "R" ref, no free value, identified
        // entirely by the component's MPN property.
        .{
            .ref_des = "R1",
            .component = "ps1608gt2-r50-t1",
            .value = "",
            .footprint = "ps1608gt2r50t1",
            .symbol = "",
            .properties = &.{.{ .key = "mpn", .value = "PS1608GT2-R50-T1" }},
        },
        // Genuinely value-less passive — must still be flagged.
        .{
            .ref_des = "R2",
            .component = "res-0402",
            .value = "",
            .footprint = "",
            .symbol = "",
        },
    };
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkMissingValues(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expectEqualStrings("R2", violations.items[0].ref_des);
}

// spec: erc - Warns when an active IC's library component declares no requirements
test "missing requirements warns for an undocumented IC" {
    const instances = [_]Instance{.{
        .ref_des = "U9",
        .component = "pcal6416ahf,128",
        .value = "",
        .footprint = "hwqfn-24",
        .symbol = "",
        .requirements = &.{},
    }};
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkMissingRequirements(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
    try std.testing.expectEqual(ViolationKind.missing_requirements, violations.items[0].kind);
    try std.testing.expectEqual(Severity.warning, violations.items[0].severity);
    try std.testing.expectEqualStrings("U9", violations.items[0].ref_des);
}

// spec: erc - Does not warn for an IC that declares at least one requirement, nor for passives
test "missing requirements skips documented ICs and passives" {
    const reqs = [_]env_mod.Requirement{.{ .text = "VDD 3V3", .id = "abc12345" }};
    const instances = [_]Instance{
        .{ .ref_des = "U1", .component = "stm32n657l0h3q", .value = "", .footprint = "bga-223", .symbol = "", .requirements = &reqs },
        .{ .ref_des = "R1", .component = "res-0402", .value = "10k", .footprint = "0402", .symbol = "", .requirements = &.{} },
        .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "0402", .symbol = "", .requirements = &.{} },
    };
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkMissingRequirements(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

// spec: erc - Recurses sub-blocks and warns once per undocumented component
test "missing requirements recurses sub-blocks and dedups by component" {
    const sub_instances = [_]Instance{
        .{ .ref_des = "U1", .component = "txb0104rutr", .value = "", .footprint = "qfn-12", .symbol = "", .requirements = &.{} },
        .{ .ref_des = "U2", .component = "txb0104rutr", .value = "", .footprint = "qfn-12", .symbol = "", .requirements = &.{} },
    };
    var sub_block: DesignBlock = .{
        .name = "ls",
        .instances = &sub_instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "ls", .block = &sub_block }};
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkMissingRequirements(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), violations.items.len);
}

// spec: erc - surfaces layout-critical net classes as info rows, staying silent on ground/power/plain-signal nets
test "layout class surfacing flags only the interesting nets" {
    const p1 = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "1" }};
    const p2 = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "2" }};
    const p3 = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "3" }};
    const p4 = [_]env_mod.PinRef{.{ .ref_des = "U1", .pin = "4" }};
    const nets = [_]env_mod.Net{
        .{ .name = "VIN", .pins = &p1 }, // input_rail → surfaced
        .{ .name = "SW1", .pins = &p2 }, // switch_node → surfaced
        .{ .name = "GND", .pins = &p3 }, // ground → silent
        .{ .name = "GPIO5", .pins = &p4 }, // signal → silent
    };
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &.{},
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkLayoutClasses(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), violations.items.len);
    for (violations.items) |v| {
        try std.testing.expectEqual(ViolationKind.layout_class_inferred, v.kind);
        try std.testing.expectEqual(Severity.info, v.severity);
    }
}

// spec: erc - Flags a board with at least five blocks that leaves some outside every group cluster
test "grouping check flags an ungrouped multi-block design" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const sections = [_]env_mod.Section{
        .{ .name = "Block A" },
        .{ .name = "Block B" },
        .{ .name = "Block C" },
        .{ .name = "Block D" },
        .{ .name = "Block E" },
    };
    const block = env_mod.DesignBlock{
        .name = "ungrouped-demo",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &sections,
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkComponentGrouping(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        // Organizational, not electrical → warning, so it never fails a build.
        if (v.kind == .components_not_grouped and v.severity == .warning) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Skips the grouping rule for a design below the block-count floor
test "grouping check ignores a small design" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const sections = [_]env_mod.Section{
        .{ .name = "Block A" },
        .{ .name = "Block B" },
        .{ .name = "Block C" },
    };
    const block = env_mod.DesignBlock{
        .name = "small-demo",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .sections = &sections,
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkComponentGrouping(alloc, &block, &violations);
    for (violations.items) |v| {
        try std.testing.expect(v.kind != .components_not_grouped);
    }
}

// spec: erc - Duplicate ref-des inside a sub-block collides with a top-level part (flattened scope)
test "duplicate ref-des across a sub-block boundary is flagged" {
    const sub_insts = [_]Instance{dcInst("U1", "modchip", "")};
    var sub_block: DesignBlock = .{
        .name = "mod",
        .instances = &sub_insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "mod", .block = &sub_block }};
    const top_insts = [_]Instance{dcInst("U1", "topchip", "")}; // same ref-des as the module's U1
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &top_insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkDuplicateRefDes(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), countKind(violations.items, .duplicate_refdes));
    for (violations.items) |v| {
        if (v.kind != .duplicate_refdes) continue;
        try std.testing.expectEqualStrings("U1", v.ref_des);
    }
}

// spec: erc - A value-less passive inside a sub-block is flagged (recursion)
test "missing value inside a sub-block is flagged" {
    const sub_insts = [_]Instance{dcInst("R1", "res-0402", "")}; // no value, no MPN
    var sub_block: DesignBlock = .{
        .name = "mod",
        .instances = &sub_insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "mod", .block = &sub_block }};
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkMissingValues(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), countKind(violations.items, .missing_value));
    try std.testing.expectEqualStrings("R1", violations.items[0].ref_des);
}

// spec: erc - capFarads accepts the UTF-8 micro sign so a "10µF" bulk cap keeps its decoupling exemption
test "capFarads parses the micro sign and exempts a bulk cap" {
    // 0.00001 F = 10 µF — well above the 4.7 µF bulk-reservoir threshold.
    try std.testing.expectApproxEqAbs(@as(f64, 1e-5), capFarads("10µF"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 4.7e-6), capFarads("4.7µF"), 1e-12);
    try std.testing.expect(capFarads("10µF") >= DECOUPLE_BULK_FARADS);
    // ASCII forms still parse (no regression).
    try std.testing.expectApproxEqAbs(@as(f64, 1e-5), capFarads("10uF"), 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1e-7), capFarads("100nF"), 1e-15);
}

// spec: erc - a "10µF" bulk cap on a multi-supply-pad rail is exempt from decoupling_unbound
test "decoupling-binding exempts a micro-sign bulk reservoir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const insts = try alloc.alloc(Instance, 2);
    insts[0] = dcInst("U1", "somechip", "");
    insts[1] = dcInst("C1", TEST_CAP, "10µF"); // bulk reservoir via the micro sign → exempt

    var vdd: std.ArrayList(env_mod.PinRef) = .empty;
    var gnd: std.ArrayList(env_mod.PinRef) = .empty;
    try vdd.append(alloc, .{ .ref_des = "U1", .pin = "1" });
    try vdd.append(alloc, .{ .ref_des = "U1", .pin = "2" });
    try gnd.append(alloc, .{ .ref_des = "U1", .pin = "3" });
    try vdd.append(alloc, .{ .ref_des = "C1", .pin = "1" });
    try gnd.append(alloc, .{ .ref_des = "C1", .pin = "2" });
    const nets = try alloc.alloc(env_mod.Net, 2);
    nets[0] = .{ .name = "VDD", .pins = vdd.items };
    nets[1] = .{ .name = "GND", .pins = gnd.items };

    const block: DesignBlock = .{
        .name = "t",
        .instances = insts,
        .nets = nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .net_ties = &.{},
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkDecouplingBinding(alloc, &block, "/nonexistent-eda-test-dir", &violations);
    try std.testing.expectEqual(@as(usize, 0), countKind(violations.items, .decoupling_unbound));
}

// spec: erc - a VSS-only IC is not counted as powered (the VS-prefix false positive)
test "power pins VSS net does not count as a power connection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // U1 connects to GND (pin1) and VSS (pin2). VSS is ground, not power — the old
    // startsWith("VS") heuristic wrongly counted it as a supply, silencing the
    // "IC has no power connection" warning.
    const block = try makePowerPinBlock(alloc, "someic", "VSS");
    var violations: std.ArrayList(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, "", &violations);
    var hit = false;
    for (violations.items) |v| {
        if (std.mem.eql(u8, v.message, "U1: IC has no power connection")) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - a VSYS rail still counts as a power connection (no VS regression)
test "power pins VSYS rail still counts as power" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const block = try makePowerPinBlock(alloc, "someic", "VSYS");
    var violations: std.ArrayList(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, "", &violations);
    for (violations.items) |v| {
        try std.testing.expect(!std.mem.eql(u8, v.message, "U1: IC has no power connection"));
    }
}

// spec: erc - a dangling (verifies …) sign-off whose target no longer exists is surfaced as a warning
test "orphaned verification is flagged" {
    const reqs = [_]env_mod.Requirement{.{ .text = "rule", .id = "r1" }};
    const insts = [_]Instance{.{
        .ref_des = "U6",
        .component = "x",
        .value = "",
        .footprint = "",
        .symbol = "",
        .id = "b894897b",
        .requirements = &reqs,
    }};
    // One verification resolves (U6/r1); one is orphaned (U9 doesn't exist).
    const verifs = [_]env_mod.Verification{
        .{ .ref_des = "U6", .req_id = "r1", .rationale = "ok" },
        .{ .ref_des = "U9", .req_id = "r1", .rationale = "dangling" },
    };
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .verifications = &verifs,
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkOrphanedVerifications(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), countKind(violations.items, .verification_orphaned));
    for (violations.items) |v| {
        if (v.kind != .verification_orphaned) continue;
        try std.testing.expectEqual(Severity.warning, v.severity);
        try std.testing.expectEqualStrings("U9", v.ref_des);
    }
}

// spec: erc - a stale req_id on an existing target still counts as an orphaned verification
test "orphaned verification flags a stale req id on a live instance" {
    const reqs = [_]env_mod.Requirement{.{ .text = "rule", .id = "r1" }};
    const insts = [_]Instance{.{
        .ref_des = "U6",
        .component = "x",
        .value = "",
        .footprint = "",
        .symbol = "",
        .id = "b894897b",
        .requirements = &reqs,
    }};
    // Target instance exists but the requirement id "rSTALE" does not.
    const verifs = [_]env_mod.Verification{.{ .ref_des = "U6", .req_id = "rSTALE", .rationale = "drifted" }};
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &insts,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .verifications = &verifs,
    };
    var violations: std.ArrayList(Violation) = .empty;
    try checkOrphanedVerifications(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), countKind(violations.items, .verification_orphaned));
}
