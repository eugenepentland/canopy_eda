const std = @import("std");
const env_mod = @import("../eval/env.zig");
const DesignBlock = env_mod.DesignBlock;
const PinRef = env_mod.PinRef;
const draw = @import("draw.zig");
const isHub = draw.isHub;
const isGroundNet = draw.isGroundNet;
const baseNetName = draw.baseNetName;
const shortNetName = draw.shortNetName;

const Allocator = std.mem.Allocator;

// ── Flat types ────────────────────────────────────────────────────────

pub const FlatInst = struct {
    ref_des: []const u8,
    component: []const u8,
    value: []const u8,
    symbol: []const u8,
    parts: []const env_mod.Part = &.{},
};

pub const FlatNet = struct {
    name: []const u8,
    pins: []const PinRef,
};

pub const Side = enum { left, right };

/// An endpoint in the adjacency list.
pub const Endpoint = union(enum) {
    net: []const u8,
    pin: struct { ref_des: []const u8, pin: []const u8 },
};

/// A connection entry: (pin_id, endpoint).
pub const AdjEntry = struct {
    pin: []const u8,
    endpoint: Endpoint,
};

/// Branch: chain of instances + terminal net name.
pub const Branch = struct {
    chain: []const FlatInst,
    terminal: []const u8,
};

pub const BranchBody = struct {
    end_x: f64,
    cy: f64,
    terminal: []const u8,
};

/// Pin group for hub rendering.
pub const PinGroup = struct {
    display_name: []const u8,
    pin_numbers: []const u8,
    conns: []const AdjEntry,
};

// ── Render Context ────────────────────────────────────────────────────

pub const RenderCtx = struct {
    allocator: Allocator,
    instances: std.ArrayListUnmanaged(FlatInst),
    nets: std.ArrayListUnmanaged(FlatNet),
    hub_order: std.ArrayListUnmanaged([]const u8),
    inst_map: std.StringHashMapUnmanaged(FlatInst),
    spoke_set: std.StringHashMapUnmanaged(void),
    pin_net: std.StringHashMapUnmanaged([]const u8),
    adjacency: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(AdjEntry)),
    net_index: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(PinRef)),
    significant_nets: std.StringHashMapUnmanaged(void),
    port_nets: std.StringHashMapUnmanaged(void),
    pin_canonical_nets: std.StringHashMapUnmanaged([]const u8),
    rendered_spokes: std.StringHashMapUnmanaged(void),
    section_map: std.StringHashMapUnmanaged(usize),

    pub fn init(allocator: Allocator) RenderCtx {
        return .{
            .allocator = allocator,
            .instances = .empty,
            .nets = .empty,
            .hub_order = .empty,
            .inst_map = .empty,
            .spoke_set = .empty,
            .pin_net = .empty,
            .adjacency = .empty,
            .net_index = .empty,
            .significant_nets = .empty,
            .port_nets = .empty,
            .pin_canonical_nets = .empty,
            .rendered_spokes = .empty,
            .section_map = .empty,
        };
    }

    // ── Data collection ───────────────────────────────────────────────

    pub fn collectFlat(self: *RenderCtx, block: *const DesignBlock, prefix: []const u8) !void {
        for (block.instances) |inst| {
            const rd = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, inst.ref_des })
            else
                inst.ref_des;
            const flat = FlatInst{
                .ref_des = rd,
                .component = inst.component,
                .value = inst.value,
                .symbol = inst.symbol,
                .parts = inst.parts,
            };
            try self.instances.append(self.allocator, flat);
            try self.inst_map.put(self.allocator, rd, flat);
        }
        for (block.nets) |net| {
            var pins: std.ArrayListUnmanaged(PinRef) = .empty;
            for (net.pins) |pin| {
                const rd = if (prefix.len > 0)
                    try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, pin.ref_des })
                else
                    pin.ref_des;
                try pins.append(self.allocator, .{ .ref_des = rd, .pin = pin.pin });
            }
            const net_name = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, net.name })
            else
                net.name;
            try self.nets.append(self.allocator, .{
                .name = net_name,
                .pins = try pins.toOwnedSlice(self.allocator),
            });
        }
        for (block.sub_blocks) |sb| {
            const np = if (prefix.len > 0)
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ prefix, sb.name })
            else
                sb.name;
            try self.collectFlat(sb.block, np);
        }
    }

    pub fn buildPinNetMap(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            for (net.pins) |pin| {
                const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pin.ref_des, pin.pin });
                try self.pin_net.put(self.allocator, key, net.name);
            }
        }
    }

    pub fn classify(self: *RenderCtx) !void {
        for (self.instances.items) |inst| {
            if (isHub(inst)) {
                try self.hub_order.append(self.allocator, inst.ref_des);
            } else {
                try self.spoke_set.put(self.allocator, inst.ref_des, {});
            }
        }
    }

    pub fn buildAdjacency(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            for (net.pins) |pin| {
                try self.adjAppend(pin.ref_des, .{
                    .pin = pin.pin,
                    .endpoint = .{ .net = bn },
                });
            }
        }
    }

    pub fn synthesizeSpokeConnections(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            if (isGroundNet(bn)) continue;

            const short = shortNetName(net.name);
            const hub_target: ?[]const u8 = blk: {
                const first_dot = std.mem.indexOfScalar(u8, short, '.') orelse break :blk null;
                const rest = short[first_dot + 1 ..];
                const second_dot = std.mem.indexOfScalar(u8, rest, '.') orelse break :blk null;
                break :blk rest[0..second_dot];
            };

            var hub_pins_buf: [64]PinRef = undefined;
            var hub_count: usize = 0;
            var spoke_pins_buf: [64]PinRef = undefined;
            var spoke_count: usize = 0;

            for (net.pins) |pin| {
                if (self.spoke_set.contains(pin.ref_des)) {
                    const is_ground_pin = self.isSpokeGroundPin(pin.ref_des, pin.pin);
                    if (!is_ground_pin) {
                        if (spoke_count < spoke_pins_buf.len) {
                            spoke_pins_buf[spoke_count] = pin;
                            spoke_count += 1;
                        }
                    }
                } else {
                    if (hub_count < hub_pins_buf.len) {
                        hub_pins_buf[hub_count] = pin;
                        hub_count += 1;
                    }
                }
            }

            if (hub_target != null and hub_count == 0) {
                for (self.nets.items) |other_net| {
                    if (std.mem.eql(u8, other_net.name, net.name)) continue;
                    if (!std.mem.eql(u8, baseNetName(other_net.name), bn)) continue;
                    for (other_net.pins) |pin| {
                        if (!self.spoke_set.contains(pin.ref_des) and
                            std.mem.eql(u8, pin.ref_des, hub_target.?))
                        {
                            if (hub_count < hub_pins_buf.len) {
                                hub_pins_buf[hub_count] = pin;
                                hub_count += 1;
                            }
                        }
                    }
                }
            }

            for (spoke_pins_buf[0..spoke_count]) |sp| {
                const spoke_section = self.section_map.get(sp.ref_des);
                for (hub_pins_buf[0..hub_count]) |hp| {
                    if (hub_target) |target| {
                        if (!std.mem.eql(u8, hp.ref_des, target)) continue;
                    }
                    if (spoke_section) |ss| {
                        const hub_section = self.section_map.get(hp.ref_des);
                        if (hub_section) |hs| {
                            if (ss != hs) continue;
                        }
                    }
                    try self.adjAppend(hp.ref_des, .{
                        .pin = hp.pin,
                        .endpoint = .{ .pin = .{ .ref_des = sp.ref_des, .pin = sp.pin } },
                    });
                    try self.adjAppend(sp.ref_des, .{
                        .pin = sp.pin,
                        .endpoint = .{ .pin = .{ .ref_des = hp.ref_des, .pin = hp.pin } },
                    });
                }
            }
        }
    }

    pub fn isSpokeGroundPin(self: *RenderCtx, ref_des: []const u8, pin_id: []const u8) bool {
        for (self.nets.items) |net| {
            for (net.pins) |p| {
                if (std.mem.eql(u8, p.ref_des, ref_des) and !std.mem.eql(u8, p.pin, pin_id)) {
                    if (isGroundNet(baseNetName(net.name))) return false;
                }
            }
        }
        for (self.nets.items) |net| {
            for (net.pins) |p| {
                if (std.mem.eql(u8, p.ref_des, ref_des) and std.mem.eql(u8, p.pin, pin_id)) {
                    if (isGroundNet(baseNetName(net.name))) return true;
                }
            }
        }
        return false;
    }

    pub fn buildNetIndex(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            for (net.pins) |pin| {
                var list = self.net_index.get(bn) orelse std.ArrayListUnmanaged(PinRef){};
                try list.append(self.allocator, pin);
                try self.net_index.put(self.allocator, bn, list);
            }
        }
    }

    pub fn buildSignificantNets(self: *RenderCtx, block: *const DesignBlock) !void {
        for (block.ports) |port| {
            try self.port_nets.put(self.allocator, baseNetName(port.net), {});
            try self.significant_nets.put(self.allocator, baseNetName(port.net), {});
        }
        for (block.sub_blocks) |sb| {
            for (sb.block.ports) |port| {
                const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sb.name, baseNetName(port.net) });
                try self.port_nets.put(self.allocator, full, {});
                try self.significant_nets.put(self.allocator, full, {});
            }
        }
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            if (isGroundNet(bn)) continue;
            var has_hub = false;
            for (net.pins) |pin| {
                if (!self.spoke_set.contains(pin.ref_des)) {
                    has_hub = true;
                    break;
                }
            }
            if (has_hub) {
                try self.significant_nets.put(self.allocator, bn, {});
            }
        }
        for ([_][]const u8{ "GND", "AGND", "DGND", "VSS" }) |g| {
            try self.significant_nets.put(self.allocator, g, {});
        }
    }

    pub fn buildPinCanonicalNets(self: *RenderCtx) !void {
        for (self.nets.items) |net| {
            const bn = baseNetName(net.name);
            for (net.pins) |pin| {
                if (!self.spoke_set.contains(pin.ref_des)) {
                    const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pin.ref_des, pin.pin });
                    try self.pin_canonical_nets.put(self.allocator, key, bn);
                }
            }
        }
    }

    pub fn validateNetConsistency(self: *RenderCtx) !void {
        var adj_it = self.adjacency.iterator();
        while (adj_it.next()) |kv| {
            const ref_des = kv.key_ptr.*;
            if (self.spoke_set.contains(ref_des)) continue;
            for (kv.value_ptr.items) |entry| {
                switch (entry.endpoint) {
                    .net => |endpoint_net| {
                        if (isGroundNet(endpoint_net)) continue;
                        const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ref_des, entry.pin });
                        const pin_net_name = self.pin_net.get(key) orelse continue;
                        const pin_bn = baseNetName(pin_net_name);
                        const ep_bn = baseNetName(endpoint_net);
                        if (!std.mem.eql(u8, pin_bn, ep_bn)) {
                            std.debug.print("NET VALIDATE: {s} pin {s}: pin_net=\"{s}\" but adjacency endpoint=\"{s}\"\n", .{ ref_des, entry.pin, pin_bn, ep_bn });
                        }
                    },
                    .pin => {},
                }
            }
        }

        var adj_it2 = self.adjacency.iterator();
        while (adj_it2.next()) |kv| {
            const ref_des = kv.key_ptr.*;
            if (!self.spoke_set.contains(ref_des)) continue;
            for (kv.value_ptr.items) |entry| {
                switch (entry.endpoint) {
                    .pin => |p| {
                        if (std.mem.order(u8, ref_des, p.ref_des) == .gt) continue;
                        const key_a = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ ref_des, entry.pin });
                        const key_b = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ p.ref_des, p.pin });
                        const net_a = self.pin_net.get(key_a) orelse continue;
                        const net_b = self.pin_net.get(key_b) orelse continue;
                        const bn_a = baseNetName(net_a);
                        const bn_b = baseNetName(net_b);
                        if (isGroundNet(bn_a) or isGroundNet(bn_b)) continue;
                        if (!std.mem.eql(u8, bn_a, bn_b)) {
                            std.debug.print("NET VALIDATE: spoke {s} pin {s} (net=\"{s}\") <-> {s} pin {s} (net=\"{s}\") — mismatch\n", .{ ref_des, entry.pin, bn_a, p.ref_des, p.pin, bn_b });
                        }
                    },
                    .net => {},
                }
            }
        }

        var pcn_it = self.pin_canonical_nets.iterator();
        while (pcn_it.next()) |kv| {
            const key = kv.key_ptr.*;
            const canonical = kv.value_ptr.*;
            const raw = self.pin_net.get(key) orelse continue;
            const canon_bn = baseNetName(canonical);
            const raw_bn = baseNetName(raw);
            if (isGroundNet(canon_bn) or isGroundNet(raw_bn)) continue;
            if (!std.mem.eql(u8, canon_bn, raw_bn)) {
                std.debug.print("NET VALIDATE: {s}: pin_net=\"{s}\" but canonical=\"{s}\"\n", .{ key, raw_bn, canon_bn });
            }
        }
    }

    pub fn adjAppend(self: *RenderCtx, ref_des: []const u8, entry: AdjEntry) !void {
        var list = self.adjacency.get(ref_des) orelse std.ArrayListUnmanaged(AdjEntry){};
        try list.append(self.allocator, entry);
        try self.adjacency.put(self.allocator, ref_des, list);
    }
};
