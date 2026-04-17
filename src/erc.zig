const std = @import("std");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const Instance = env_mod.Instance;
const Net = env_mod.Net;

pub const Severity = enum { @"error", warning, info };

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
};

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
pub fn runErc(allocator: std.mem.Allocator, block: *const DesignBlock) ![]const Violation {
    var violations: std.ArrayListUnmanaged(Violation) = .empty;

    checkDuplicateRefDes(allocator, block, &violations);
    checkFloatingNets(allocator, block, &violations);
    checkUnconnectedPorts(allocator, block, &violations);
    checkMissingValues(allocator, block, &violations);
    checkMissingFootprints(allocator, block, &violations);
    checkMissingDecoupling(allocator, block, &violations);
    checkVoltageMismatches(allocator, block, &violations);
    checkUnconnectedPowerPins(allocator, block, &violations);
    checkConceptSections(allocator, block, &violations);

    return violations.items;
}

/// Check for duplicate reference designators across the full flattened design.
fn checkDuplicateRefDes(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
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
            violations.append(allocator, .{
                .kind = .duplicate_refdes,
                .severity = .@"error",
                .message = msg,
                .ref_des = entry.key_ptr.*,
            }) catch {};
        }
    }
}

/// Check for nets with only a single connection (floating/dead-end).
fn checkFloatingNets(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
    // Build port net set (these connect externally, not dead-ends)
    var port_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.ports) |port| {
        port_nets.put(allocator, port.net, {}) catch {};
        port_nets.put(allocator, port.name, {}) catch {};
    }

    // Also collect optional section ports — their nets are allowed to float
    var optional_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.sections) |sec| {
        collectOptionalPortNets(allocator, &optional_nets, sec);
    }
    // Optional top-level ports
    for (block.ports) |port| {
        if (port.optional) optional_nets.put(allocator, baseNetName(port.net), {}) catch {};
    }

    // Also exclude nets that participate in net_ties (sub-block connections)
    var tied_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.net_ties) |nt| {
        const base_a = baseNetName(nt.a);
        const base_b = baseNetName(nt.b);
        tied_nets.put(allocator, base_a, {}) catch {};
        tied_nets.put(allocator, base_b, {}) catch {};
    }

    // Count pins per base net name
    var net_pin_counts: std.StringHashMapUnmanaged(u32) = .empty;
    for (block.nets) |net| {
        const base = baseNetName(net.name);
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
            violations.append(allocator, .{
                .kind = .floating_net,
                .severity = .warning,
                .message = msg,
                .net = entry.key_ptr.*,
            }) catch {};
        }
    }
}

/// Check that required ports on sub-blocks are connected, and that
/// the parent design's own required ports have connections.
fn checkUnconnectedPorts(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
    // Build set of connected sub-block port paths from net_ties
    // Net ties look like: (net "VDD" "buck/VOUT" "ldo/VIN")
    // which creates net_ties: {a:"VDD", b:"buck/VOUT"}, {a:"VDD", b:"ldo/VIN"}
    var connected_paths: std.StringHashMapUnmanaged(void) = .empty;
    for (block.net_ties) |nt| {
        connected_paths.put(allocator, nt.a, {}) catch {};
        connected_paths.put(allocator, nt.b, {}) catch {};
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
                violations.append(allocator, .{
                    .kind = .unconnected_pin,
                    .severity = .@"error",
                    .message = msg,
                    .net = port.net,
                }) catch {};
            }
        }
    }

    // Check the parent block's own required ports — they should have at least
    // one internal connection (via nets or net_ties)
    var connected_port_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.nets) |net| {
        const base = baseNetName(net.name);
        if (net.pins.len > 0) connected_port_nets.put(allocator, base, {}) catch {};
    }
    // Net ties also count as connections for parent ports
    for (block.net_ties) |nt| {
        connected_port_nets.put(allocator, baseNetName(nt.a), {}) catch {};
        connected_port_nets.put(allocator, baseNetName(nt.b), {}) catch {};
    }

    for (block.ports) |port| {
        const base = baseNetName(port.net);
        if (!connected_port_nets.contains(base)) {
            if (port.optional) continue;
            const msg = std.fmt.allocPrint(
                allocator,
                "Required port \"{s}\" has no internal connections",
                .{port.name},
            ) catch continue;
            violations.append(allocator, .{
                .kind = .unconnected_pin,
                .severity = .@"error",
                .message = msg,
                .net = port.net,
            }) catch {};
        }
    }
}

/// Check for instances missing a value (passives need values).
fn checkMissingValues(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
    const all_instances = collectBlockInstances(allocator, block);
    for (all_instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        // Passives (R, C, L) need values
        const prefix = inst.ref_des[0];
        if ((prefix == 'R' or prefix == 'C' or prefix == 'L') and inst.value.len == 0) {
            const msg = std.fmt.allocPrint(allocator, "{s}: Missing value for {s}", .{ inst.ref_des, inst.component }) catch continue;
            violations.append(allocator, .{
                .kind = .missing_value,
                .severity = .@"error",
                .message = msg,
                .ref_des = inst.ref_des,
            }) catch {};
        }
    }
}

/// Check for instances missing a footprint.
fn checkMissingFootprints(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
    const all_instances = collectBlockInstances(allocator, block);
    for (all_instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        if (inst.footprint.len == 0) {
            const msg = std.fmt.allocPrint(allocator, "{s}: Missing footprint", .{inst.ref_des}) catch continue;
            violations.append(allocator, .{
                .kind = .missing_footprint,
                .severity = .warning,
                .message = msg,
                .ref_des = inst.ref_des,
            }) catch {};
        }
    }
}

/// Check power nets connected to ICs but missing decoupling caps.
fn checkMissingDecoupling(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
    // Collect power nets from implemented section port declarations (skip concept sections)
    var power_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.sections) |sec| {
        if (sec.status == .concept) continue;
        for (sec.ports) |p| {
            if (p.signal_type == .power and p.direction == .in) {
                power_nets.put(allocator, p.name, {}) catch {};
            }
        }
    }

    for (block.nets) |net| {
        const base = baseNetName(net.name);
        if (!power_nets.contains(base)) continue;

        var has_ic = false;
        var has_cap = false;
        for (net.pins) |pin| {
            if (pin.ref_des.len == 0) continue;
            const prefix = pin.ref_des[0];
            if (prefix == 'U') has_ic = true;
            if (prefix == 'C') has_cap = true;
        }
        if (has_ic and !has_cap) {
            const msg = std.fmt.allocPrint(allocator, "Power net \"{s}\" connects to IC but has no decoupling cap", .{base}) catch continue;
            violations.append(allocator, .{
                .kind = .missing_decoupling,
                .severity = .warning,
                .message = msg,
                .net = base,
            }) catch {};
        }
    }
}

/// Check voltage mismatches across section port declarations.
fn checkVoltageMismatches(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
    var net_voltages: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(VoltageEntry)) = .empty;

    for (block.sections) |sec| {
        collectSectionVoltages(allocator, &net_voltages, sec);
    }

    var iter = net_voltages.iterator();
    while (iter.next()) |entry| {
        const entries = entry.value_ptr.items;
        if (entries.len < 2) continue;
        const first_v = entries[0].voltage;
        for (entries[1..]) |e| {
            if (@abs(e.voltage - first_v) > 0.01) {
                const msg = std.fmt.allocPrint(
                    allocator,
                    "Voltage mismatch on \"{s}\": {s} declares {d:.1}V vs {s} declares {d:.1}V",
                    .{ entry.key_ptr.*, entries[0].section, first_v, e.section, e.voltage },
                ) catch continue;
                violations.append(allocator, .{
                    .kind = .voltage_mismatch,
                    .severity = .@"error",
                    .message = msg,
                    .net = entry.key_ptr.*,
                }) catch {};
                break;
            }
        }
    }
}

const VoltageEntry = struct { section: []const u8, voltage: f64 };

fn collectSectionVoltages(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(std.ArrayListUnmanaged(VoltageEntry)), sec: env_mod.Section) void {
    for (sec.ports) |p| {
        if (p.voltage) |v| {
            const gop = map.getOrPut(allocator, p.name) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            gop.value_ptr.append(allocator, .{ .section = sec.name, .voltage = v }) catch {};
        }
    }
    for (sec.sub_sections) |sub| {
        collectSectionVoltages(allocator, map, sub);
    }
}

/// Check ICs missing power/ground connections.
/// Checks both this block's nets and recursively checks sub-block nets for their own instances.
fn checkUnconnectedPowerPins(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
    checkBlockPowerPins(allocator, block, violations);
    // Also check sub-blocks with their own net namespace
    for (block.sub_blocks) |sb| {
        checkBlockPowerPins(allocator, sb.block, violations);
    }
}

fn checkBlockPowerPins(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
    var has_gnd: std.StringHashMapUnmanaged(void) = .empty;
    var has_vdd: std.StringHashMapUnmanaged(void) = .empty;

    for (block.nets) |net| {
        const base = baseNetName(net.name);
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
            if (is_gnd) has_gnd.put(allocator, pin.ref_des, {}) catch {};
            if (is_vdd) has_vdd.put(allocator, pin.ref_des, {}) catch {};
        }
    }

    for (block.instances) |inst| {
        if (inst.ref_des.len == 0) continue;
        const prefix = inst.ref_des[0];
        // Only check ICs (U prefix)
        if (prefix != 'U') continue;
        // Skip passive components that got U prefix (LEDs, inductors, filters, crystals)
        if (isPassiveComponent(inst.component)) continue;

        if (!has_gnd.contains(inst.ref_des)) {
            const msg = std.fmt.allocPrint(allocator, "{s}: IC has no ground connection", .{inst.ref_des}) catch continue;
            violations.append(allocator, .{
                .kind = .unconnected_pin,
                .severity = .@"error",
                .message = msg,
                .ref_des = inst.ref_des,
            }) catch {};
        }
        if (!has_vdd.contains(inst.ref_des)) {
            const msg = std.fmt.allocPrint(allocator, "{s}: IC has no power connection", .{inst.ref_des}) catch continue;
            violations.append(allocator, .{
                .kind = .unconnected_pin,
                .severity = .warning,
                .message = msg,
                .ref_des = inst.ref_des,
            }) catch {};
        }
    }
}

/// Report concept sections that still need implementation.
fn checkConceptSections(allocator: std.mem.Allocator, block: *const DesignBlock, violations: *std.ArrayListUnmanaged(Violation)) void {
    for (block.sections) |sec| {
        if (sec.status == .concept) {
            const msg = std.fmt.allocPrint(allocator, "Section \"{s}\" is still a concept — no implementation yet", .{sec.name}) catch continue;
            violations.append(allocator, .{
                .kind = .concept_remaining,
                .severity = .info,
                .message = msg,
            }) catch {};
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
        "fuse", "ntc",   "ptc",     "varistor",
    };
    for (passive_prefixes) |pfx| {
        if (component.len >= pfx.len and std.ascii.eqlIgnoreCase(component[0..pfx.len], pfx)) return true;
    }
    return false;
}

fn collectOptionalPortNets(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(void), sec: env_mod.Section) void {
    for (sec.ports) |p| {
        if (p.optional) map.put(allocator, p.name, {}) catch {};
    }
    for (sec.sub_sections) |sub| collectOptionalPortNets(allocator, map, sub);
}

fn baseNetName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |idx| return name[0..idx];
    return name;
}

/// Serialize violations to JSON.
pub fn writeViolationsJson(allocator: std.mem.Allocator, violations: []const Violation) ![]const u8 {
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

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
