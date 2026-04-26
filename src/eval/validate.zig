const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const na = @import("net_analysis.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const DesignBlock = env_mod.DesignBlock;
const Node = ast.Node;
const Env = env_mod.Env;

/// Run post-build validations on a design block and its sub-blocks.
pub fn validateDesign(self: *Evaluator, block: *const DesignBlock) !void {
    try checkSinglePinNets(self, block);
    try checkVoltageMismatches(self, block);
    try checkMissingDecoupling(self, block);
}

/// Warn about nets that have only a single pin (dead-end connections).
/// Groups nets by base name (before first '.') so that "VDD" and "VDD.U3.W6"
/// are counted together. Sub-blocks are excluded since their internal nets
/// connect to the parent design via net_ties.
fn checkSinglePinNets(self: *Evaluator, block: *const DesignBlock) !void {
    // Count total pins per base net name
    var net_pin_counts: std.StringHashMapUnmanaged(u32) = .empty;
    // Track a representative single-pin net for the error message
    const PinInfo = struct { ref_des: []const u8, pin: []const u8 };
    var net_single_pin: std.StringHashMapUnmanaged(PinInfo) = .empty;

    // Build set of port net names — these connect externally and aren't dead-ends
    var port_nets: std.StringHashMapUnmanaged(void) = .empty;
    for (block.ports) |port| {
        try port_nets.put(self.allocator, port.net, {});
        try port_nets.put(self.allocator, port.name, {});
    }

    for (block.nets) |net| {
        const base = na.baseNetName(net.name);
        if (port_nets.contains(base)) continue; // Port nets connect externally
        const gop = net_pin_counts.getOrPut(self.allocator, base) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        gop.value_ptr.* += @intCast(net.pins.len);

        // Store single-pin info for the first occurrence
        if (net.pins.len == 1 and !net_single_pin.contains(base)) {
            try net_single_pin.put(self.allocator, base, .{
                .ref_des = net.pins[0].ref_des,
                .pin = net.pins[0].pin,
            });
        }
    }

    // Also count pins from sub-block port connections (via net_ties)
    for (block.net_ties) |nt| {
        // Each net_tie side that doesn't have '/' is a plain net in this block
        for ([_][]const u8{ nt.a, nt.b }) |side| {
            if (std.mem.indexOfScalar(u8, side, '/') == null) {
                const base = na.baseNetName(side);
                const gop = net_pin_counts.getOrPut(self.allocator, base) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* += 1;
            }
        }
    }

    var iter = net_pin_counts.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* == 1) {
            const base = entry.key_ptr.*;
            if (net_single_pin.get(base)) |info| {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "Dead-end net \"{s}\" — only connected to {s} pin {s}",
                    .{ base, info.ref_des, info.pin },
                ) catch continue;
                try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
            }
        }
    }
}

/// Warn when two sections declare the same net with different voltages.
fn checkVoltageMismatches(self: *Evaluator, block: *const DesignBlock) !void {
    // Collect voltage declarations per net name across sections
    const Entry = struct { section: []const u8, voltage: f64 };
    var net_voltages: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Entry)) = .empty;

    for (block.sections) |sec| {
        for (sec.ports) |p| {
            if (p.voltage) |v| {
                const gop = net_voltages.getOrPut(self.allocator, p.name) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(self.allocator, .{ .section = sec.name, .voltage = v });
            }
        }
        for (sec.sub_sections) |sub| {
            for (sub.ports) |p| {
                if (p.voltage) |v| {
                    const gop = net_voltages.getOrPut(self.allocator, p.name) catch continue;
                    if (!gop.found_existing) gop.value_ptr.* = .empty;
                    try gop.value_ptr.append(self.allocator, .{ .section = sub.name, .voltage = v });
                }
            }
        }
    }

    var iter = net_voltages.iterator();
    while (iter.next()) |entry| {
        const entries = entry.value_ptr.items;
        if (entries.len < 2) continue;
        const first_v = entries[0].voltage;
        for (entries[1..]) |e| {
            if (@abs(e.voltage - first_v) > 0.01) {
                const msg = std.fmt.allocPrint(
                    self.allocator,
                    "Voltage mismatch on net \"{s}\": {s} declares {d:.1}V but {s} declares {d:.1}V",
                    .{ entry.key_ptr.*, entries[0].section, first_v, e.section, e.voltage },
                ) catch continue;
                try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
                break;
            }
        }
    }
}

/// Warn about power nets connected to ICs but missing decoupling capacitors.
/// Shares its core analysis with the on-demand ERC pass in `src/erc.zig` —
/// see `eval/net_analysis.zig` for the actual walk (including the follow
/// into sub-block ports tied to top-level rails).
fn checkMissingDecoupling(self: *Evaluator, block: *const DesignBlock) !void {
    const missing = try na.findMissingDecouplingNets(self.allocator, block);
    defer self.allocator.free(missing);
    for (missing) |base| {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Power net \"{s}\" connects to IC but has no decoupling capacitor",
            .{base},
        ) catch continue;
        try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
    }
}

/// Track the first argument of a (net ...) form for combinability warnings.
pub fn trackNetFormSource(self: *Evaluator, form_children: []const Node, env: *Env, sources: *std.StringHashMapUnmanaged(u32)) void {
    if (form_children.len < 3) return;
    const src_val = self.evalNode(form_children[1], env) catch return;
    const src = src_val.asString() orelse return;
    const gop = sources.getOrPut(self.allocator, src) catch return;
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
    } else {
        gop.value_ptr.* += 1;
    }
}

/// Emit warnings for net forms that share a common first net and could be combined.
pub fn warnCombinableNets(self: *Evaluator, sources: *std.StringHashMapUnmanaged(u32)) !void {
    var iter = sources.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.* > 1) {
            const msg = std.fmt.allocPrint(
                self.allocator,
                "Net \"{s}\" has {d} separate (net) forms that could be combined",
                .{ entry.key_ptr.*, entry.value_ptr.* },
            ) catch continue;
            try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
        }
    }
}
