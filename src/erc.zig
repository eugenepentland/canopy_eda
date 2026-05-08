const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const env_mod = @import("eval/env.zig");
const na = @import("eval/net_analysis.zig");
const power_budget = @import("eval/power_budget.zig");
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
    if (project_dir.len > 0) try checkPinFunctions(allocator, block, project_dir, &violations);

    return violations.items;
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
            std.mem.endsWith(u8, base, "GND") or std.mem.endsWith(u8, base, "VSS");
        const is_vdd = std.mem.startsWith(u8, base, "VDD") or std.mem.startsWith(u8, base, "VCC") or
            std.mem.startsWith(u8, base, "VBAT") or std.mem.startsWith(u8, base, "V3P3") or
            std.mem.startsWith(u8, base, "V1P") or std.mem.startsWith(u8, base, "V2P") or
            std.mem.startsWith(u8, base, "VBUS") or std.mem.startsWith(u8, base, "VIN") or
            std.mem.startsWith(u8, base, "VOUT") or std.mem.startsWith(u8, base, "AVDD") or
            std.mem.startsWith(u8, base, "DVDD") or std.mem.startsWith(u8, base, "V+") or
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
        "led",  "ind",   "ferrite", "xfl",      "abm",
        "fc-",  "diode", "ecmf",    "esd",      "tvs",
        "fuse", "ntc",   "ptc",     "varistor", "sw-",
    };
    for (passive_prefixes) |pfx| {
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

const PinoutEntry = struct {
    /// Primary function name (always valid).
    primary: []const u8,
    /// Additional valid function names for this physical pin.
    alts: []const []const u8,
};

/// Load a pinout file and return pin_id -> {primary, alts}. Returns null if the file is missing
/// or malformed. Allocator is used both for the parse tree (kept until end of ERC) and the map.
fn loadPinoutMap(allocator: std.mem.Allocator, path: []const u8) ?std.StringHashMapUnmanaged(PinoutEntry) {
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
        map.put(allocator, pin_id, .{
            .primary = primary,
            .alts = alts.toOwnedSlice(allocator) catch &.{},
        }) catch continue;
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

            // Rule 2: pin has alts but no (as ...). Skip pure-power pads (no alts).
            if (pin.asserted_fns.len == 0) {
                if (entry.alts.len == 0) continue;
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
    const alloc = std.testing.allocator;
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
    const alloc = std.testing.allocator;
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
    const alloc = std.testing.allocator;
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
    const alloc = std.testing.allocator;
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
    const alloc = std.testing.allocator;
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
    const alloc = std.testing.allocator;
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

// spec: erc - Rejects asserted function that is not in the pinout
test "pin function unsupported across slice" {
    const alloc = std.testing.allocator;
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
