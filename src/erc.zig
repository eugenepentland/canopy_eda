const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const env_mod = @import("eval/env.zig");
const na = @import("eval/net_analysis.zig");
const power_budget = @import("eval/power_budget.zig");
const power_sequencing = @import("eval/power_sequencing.zig");
const parser_mod = @import("sexpr/parser.zig");
const json_writer = @import("json_writer.zig");
const checks = @import("checks.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;

pub const Severity = checks.Severity;

// ── Constants ─────────────────────────────────────────────────────
const VOLTAGE_MISMATCH_TOLERANCE_V: f64 = 0.01;
const PERCENT_MULTIPLIER: f64 = 100.0;

/// Tag identifying which electrical-rule check produced a `Violation`. The
/// review UI groups findings by this kind so users can scan all
/// power-budget warnings or all floating nets in one cluster.
pub const ViolationKind = enum {
    duplicate_refdes,
    floating_net,
    unconnected_pin,
    missing_value,
    missing_footprint,
    multiple_drivers,
    voltage_mismatch,
    missing_decoupling,
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
    main_ic_in_design,
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;

    try checkDuplicateRefDes(allocator, block, &violations);
    try checkPinMultiNet(allocator, block, &violations);
    try checkFloatingNets(allocator, block, &violations);
    try checkUnconnectedPorts(allocator, block, &violations);
    try checkMissingValues(allocator, block, &violations);
    try checkMissingFootprints(allocator, block, &violations);
    try checkMissingDecoupling(allocator, block, &violations);
    try checkVoltageMismatches(allocator, block, &violations);
    try checkUnconnectedPowerPins(allocator, block, &violations);
    try checkConceptSections(allocator, block, &violations);
    try checkPowerBudget(allocator, block, &violations);
    try checkTestPointCoverage(allocator, block, &violations);
    try checkPowerTreeIntegrity(allocator, block, &violations);
    try checkSequencingCycles(allocator, block, &violations);
    try checkVoltageDomainCompat(allocator, block, &violations);
    try checkMainIcsInDesign(allocator, block, &violations);
    if (project_dir.len > 0) try checkPinFunctions(allocator, block, project_dir, &violations);

    return violations.items;
}

/// Flag "main ICs" instantiated directly in the top-level design instead of
/// being sealed inside a `(defmodule …)` and brought in via `(sub-block …)`.
/// The design file should read as a wiring harness between modules: each
/// functional IC's pin-level implementation belongs in `lib/modules/` so it
/// can be reviewed, reused, and revised on its own. A "main IC" here is an
/// instance whose ref-des prefix is `U` (the IC prefix from `ids.componentPrefix`)
/// that is neither an `(ignore-requirements)` support part — debug headers,
/// mounting hardware, and board-to-board connectors that fall through to the
/// `U` prefix all set this — nor a passive-class part (ESD arrays, EMI
/// filters). `block.instances` already excludes sub-block contents, so
/// iterating it inspects only what the design file instantiates directly.
fn checkMainIcsInDesign(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    for (collectBlockInstances(allocator, block)) |inst| {
        if (inst.ref_des.len == 0) continue;
        if (na.refDesLocalPrefix(inst.ref_des) != 'U') continue;
        if (inst.requirements_ignored) continue;
        if (isPassiveComponent(inst.component)) continue;
        const msg = std.fmt.allocPrint(
            allocator,
            "Main IC \"{s}\" ({s}) is instantiated directly in the design — " ++
                "seal it in a (defmodule …) under lib/modules/ and bring it in via (sub-block …)",
            .{ inst.ref_des, inst.component },
        ) catch continue;
        try violations.append(allocator, .{
            .kind = .main_ic_in_design,
            .severity = .@"error",
            .message = msg,
            .ref_des = inst.ref_des,
        });
    }
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
    violations: *std.ArrayListUnmanaged(Violation),
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
    var net_to_port_elec: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(env_mod.ElectricalDecl)) = .empty;
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
    violations: *std.ArrayListUnmanaged(Violation),
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
/// `upstream_rail` population) that land alongside Phase 2C.
fn checkPowerTreeIntegrity(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
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
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    // Collect the set of nets that have a test point on them, from both
    // sources (first-class form + legacy testpoint-component instances).
    var tp_nets: std.StringHashMapUnmanaged(void) = .empty;
    defer tp_nets.deinit(allocator);

    for (block.test_points) |tp| {
        try tp_nets.put(allocator, tp.net, {});
    }
    for (block.instances) |inst| {
        if (!std.mem.eql(u8, inst.component, "testpoint")) continue;
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
fn checkDuplicateRefDes(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    var counts: std.StringHashMapUnmanaged(u32) = .empty;

    const all = collectBlockInstances(allocator, block);
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
fn checkPinMultiNet(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
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
    violations: *std.ArrayListUnmanaged(Violation),
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
/// the parent design's own required ports have connections.
fn checkUnconnectedPorts(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
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

/// Check for instances missing a value (passives need values).
fn checkMissingValues(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    const all_instances = collectBlockInstances(allocator, block);
    for (all_instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        // Passives (R, C, L) need values
        const prefix = na.refDesLocalPrefix(inst.ref_des);
        if ((prefix == 'R' or prefix == 'C' or prefix == 'L') and inst.value.len == 0) {
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

/// Check for instances missing a footprint.
fn checkMissingFootprints(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    const all_instances = collectBlockInstances(allocator, block);
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
    violations: *std.ArrayListUnmanaged(Violation),
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

/// Check voltage mismatches across section port declarations.
fn checkVoltageMismatches(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    var net_voltages: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(VoltageEntry)) = .empty;

    for (block.sections) |sec| {
        try collectSectionVoltages(allocator, &net_voltages, sec);
    }

    var iter = net_voltages.iterator();
    while (iter.next()) |entry| {
        const entries = entry.value_ptr.items;
        if (entries.len < 2) continue;
        const first_v = entries[0].voltage;
        for (entries[1..]) |e| {
            if (@abs(e.voltage - first_v) > VOLTAGE_MISMATCH_TOLERANCE_V) {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Voltage mismatch on \"{s}\": {s} declares {d:.1}V vs {s} declares {d:.1}V",
                    .{ entry.key_ptr.*, entries[0].section, first_v, e.section, e.voltage },
                ) catch continue;
                try violations.append(allocator, .{
                    .kind = .voltage_mismatch,
                    .severity = .@"error",
                    .message = msg,
                    .net = entry.key_ptr.*,
                });
                break;
            }
        }
    }
}

const VoltageEntry = struct { section: []const u8, voltage: f64 };

fn collectSectionVoltages(
    allocator: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(VoltageEntry)),
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
fn checkUnconnectedPowerPins(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    try checkBlockPowerPins(allocator, block, violations);
    // Also check sub-blocks with their own net namespace
    for (block.sub_blocks) |sb| {
        try checkBlockPowerPins(allocator, sb.block, violations);
    }
}

fn checkBlockPowerPins(
    allocator: std.mem.Allocator,
    block: *const DesignBlock,
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    var has_gnd: std.StringHashMapUnmanaged(void) = .empty;
    var has_vdd: std.StringHashMapUnmanaged(void) = .empty;

    for (block.nets) |net| {
        const base = na.baseNetName(net.name);
        const is_gnd = std.mem.eql(u8, base, "GND") or std.mem.eql(u8, base, "VSS") or
            std.mem.eql(u8, base, "AGND") or std.mem.eql(u8, base, "DGND") or
            std.mem.eql(u8, base, "PGND") or std.mem.eql(u8, base, "EP") or
            std.mem.startsWith(u8, base, "GND") or
            std.mem.endsWith(u8, base, "GND") or std.mem.endsWith(u8, base, "VSS");
        const is_vdd = std.mem.startsWith(u8, base, "VDD") or std.mem.startsWith(u8, base, "VCC") or
            std.mem.startsWith(u8, base, "VBAT") or std.mem.startsWith(u8, base, "V3P3") or
            std.mem.startsWith(u8, base, "V1P") or std.mem.startsWith(u8, base, "V2P") or
            std.mem.startsWith(u8, base, "VBUS") or std.mem.startsWith(u8, base, "VIN") or
            std.mem.startsWith(u8, base, "VOUT") or std.mem.startsWith(u8, base, "AVDD") or
            std.mem.startsWith(u8, base, "DVDD") or std.mem.startsWith(u8, base, "V+") or
            // VREF: auto-direction level translators (LSF0108, TXS0108, …) have no
            // VDD/VCC pin — they are supplied through their VREF_A / VREF_B rails.
            std.mem.startsWith(u8, base, "VREF") or
            std.mem.startsWith(u8, base, "VS");

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
        // Skip passive components that got U prefix (LEDs, inductors, filters, crystals)
        if (isPassiveComponent(inst.component)) continue;
        // Skip ICs that intentionally have no ground reference pin (float with
        // their input rail) — flagging them for "no ground" is a false positive.
        if (isGroundlessIc(inst.component)) continue;

        if (!has_gnd.contains(inst.ref_des)) {
            const msg = std.fmt.allocPrint(allocator, "{s}: IC has no ground connection", .{inst.ref_des}) catch continue;
            try violations.append(allocator, .{
                .kind = .unconnected_pin,
                .severity = .@"error",
                .message = msg,
                .ref_des = inst.ref_des,
            });
        }
        if (!has_vdd.contains(inst.ref_des)) {
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
    violations: *std.ArrayListUnmanaged(Violation),
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
                const pct: u32 = @intFromFloat(PERCENT_MULTIPLIER * rail.load_typ_a / styp);
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Rail \"{s}\" typ load {d:.3}A is {d}% of {s} typ {d:.3}A — tight margin",
                    .{ rail.net, rail.load_typ_a, pct, rail.source_label, styp },
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
    violations: *std.ArrayListUnmanaged(Violation),
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

/// Collect instances from this block only (not sub-blocks).
/// Note: block.instances already includes section instances (they're added to both
/// the parent instances list and the section.instances list during evaluation).
fn collectBlockInstances(_: std.mem.Allocator, block: *const DesignBlock) []const Instance {
    return block.instances;
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

        var alts: std.ArrayListUnmanaged([]const u8) = .empty;
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
    violations: *std.ArrayListUnmanaged(Violation),
) !void {
    // Build ref_des -> pinout_lookup map so we know which pinout file to load per pin.
    // Prefer `inst.pinout`, fall back to `inst.symbol`, then `inst.component`.
    var ref_to_lookup: std.StringHashMapUnmanaged([]const u8) = .empty;
    const all = try collectAllInstances(allocator, block);
    for (all) |inst| {
        const lookup = if (inst.pinout.len > 0) inst.pinout else if (inst.symbol.len > 0) inst.symbol else inst.component;
        if (lookup.len == 0) continue;
        try ref_to_lookup.put(allocator, inst.ref_des, lookup);
    }

    // Cache loaded pinouts by symbol so repeated lookups don't reparse.
    var pinout_cache: std.StringHashMapUnmanaged(?std.StringHashMapUnmanaged(PinoutEntry)) = .empty;

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
}

fn formatFunctionMsg(
    allocator: std.mem.Allocator,
    ref_des: []const u8,
    pin_id: []const u8,
    asserted: []const u8,
    net: []const u8,
    entry: PinoutEntry,
) ?[]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
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

fn collectAllInstances(allocator: std.mem.Allocator, block: *const DesignBlock) ![]const Instance {
    var list: std.ArrayListUnmanaged(Instance) = .empty;
    try appendInstances(allocator, &list, block);
    return list.items;
}

fn appendInstances(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Instance),
    block: *const DesignBlock,
) !void {
    for (block.instances) |inst| try list.append(allocator, inst);
    for (block.sub_blocks) |sb| try appendInstances(allocator, list, sb.block);
}

/// Serialize violations to JSON.
pub fn writeViolationsJson(allocator: std.mem.Allocator, violations: []const Violation) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, &violations);
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
    try checkUnconnectedPowerPins(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .unconnected_pin and std.mem.eql(u8, v.ref_des, "U1") and
            std.mem.indexOf(u8, v.message, "no power connection") != null) hit = true;
    }
    try std.testing.expect(hit);
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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

    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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

    var violations: std.ArrayListUnmanaged(Violation) = .empty;
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
    try checkSequencingCycles(alloc, &block, &violations);
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .sequence_cycle) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Flags a main IC instantiated directly in the design instead of via a sub-block
test "main IC instantiated directly in design is flagged" {
    const instances = [_]Instance{.{
        .ref_des = "U8",
        .component = "stm32n657l0h3q",
        .value = "",
        .footprint = "bga-223",
        .symbol = "",
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
    try checkMainIcsInDesign(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    var hit = false;
    for (violations.items) |v| {
        if (v.kind == .main_ic_in_design and std.mem.eql(u8, v.ref_des, "U8")) hit = true;
    }
    try std.testing.expect(hit);
}

// spec: erc - Allows ignore-requirements support parts and passives to be instantiated directly in the design
test "support parts and passives instantiated directly in design are allowed" {
    const instances = [_]Instance{
        // Board-to-board connector that falls through to the `U` prefix but
        // declares (ignore-requirements).
        .{
            .ref_des = "U9",
            .component = "204928-0601",
            .value = "",
            .footprint = "2049280601",
            .symbol = "",
            .requirements_ignored = true,
        },
        // ESD array — `U` prefix but passive-class.
        .{
            .ref_des = "U10",
            .component = "ecmf04-4hsm10",
            .value = "",
            .footprint = "",
            .symbol = "",
        },
        // Crystal — non-`U` prefix.
        .{
            .ref_des = "Y1",
            .component = "abm8",
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
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
    try checkMainIcsInDesign(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}

// spec: erc - Does not flag main ICs that are wrapped in sub-blocks
test "main IC wrapped in a sub-block is not flagged" {
    const sub_instances = [_]Instance{.{
        .ref_des = "U1",
        .component = "stm32n657l0h3q",
        .value = "",
        .footprint = "bga-223",
        .symbol = "",
    }};
    var sub_block: DesignBlock = .{
        .name = "stm32-core",
        .instances = &sub_instances,
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const sbs = [_]env_mod.SubBlock{.{ .name = "core", .block = &sub_block }};
    const block: DesignBlock = .{
        .name = "demo",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &sbs,
    };
    var violations: std.ArrayListUnmanaged(Violation) = .empty;
    try checkMainIcsInDesign(std.testing.allocator, &block, &violations);
    defer {
        for (violations.items) |v| std.testing.allocator.free(v.message);
        violations.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
}
