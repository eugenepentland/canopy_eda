const std = @import("std");
const env_mod = @import("../eval/env.zig");
const PinRef = env_mod.PinRef;
const ctx_mod = @import("context.zig");
const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const AdjEntry = ctx_mod.AdjEntry;
const Endpoint = ctx_mod.Endpoint;
const Side = ctx_mod.Side;
const BranchBody = ctx_mod.BranchBody;
const PinGroup = ctx_mod.PinGroup;
const draw = @import("draw.zig");
const spoke_len = draw.spoke_len;
const per_conn_spacing = draw.per_conn_spacing;
const isGroundNet = draw.isGroundNet;
const baseNetName = draw.baseNetName;
const endpointEql = draw.endpointEql;
const drawNetWire = draw.drawNetWire;
const drawNcSymbol = draw.drawNcSymbol;
const hub_mod = @import("hub.zig");
const estimateBranchCount = hub_mod.estimateBranchCount;
const branch_mod = @import("branch.zig");
const RenderError = draw.RenderError;

/// Render every connection out of one merged hub-pin group. Classifies each
/// connection as net-label or pin-link (spoke-chain), filters out
/// insignificant nets, then routes the surviving ones onto a per-pin local
/// bus and lays the chains/terminals out vertically without overlapping the
/// neighbouring pins.
pub fn renderGroupedConnections(self: *RenderCtx, w: anytype, hub_ref: []const u8, group: PinGroup, stub_x: f64, py: f64, side: Side) RenderError!void {
    if (group.conns.len == 0) {
        const nc_x = switch (side) {
            .left => stub_x - 10.0,
            .right => stub_x + 10.0,
        };
        try drawNcSymbol(w, nc_x, py);
        return;
    }

    var first_pin_id: []const u8 = "";
    for (group.conns) |c| {
        first_pin_id = c.pin;
        break;
    }
    const canon_key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ hub_ref, first_pin_id });
    const pin_net_name = self.pin_canonical_nets.get(canon_key) orelse "";

    const Classified = struct { conn: AdjEntry, terminal: []const u8 };
    var classified: std.ArrayListUnmanaged(Classified) = .empty;

    for (group.conns) |conn| {
        switch (conn.endpoint) {
            .net => |net| {
                const term = baseNetName(net);
                if (!self.significant_nets.contains(term)) continue;
                if (std.mem.eql(u8, term, baseNetName(pin_net_name))) {
                    var should_show = false;
                    if (self.port_nets.contains(term)) should_show = true;
                    if (!should_show) {
                        if (self.net_index.get(term)) |nps| {
                            const my_section = self.section_map.get(hub_ref);
                            for (nps.items) |np| {
                                if (self.rendered_spokes.contains(np.ref_des)) {
                                    should_show = true;
                                    break;
                                }
                                if (!self.spoke_set.contains(np.ref_des) and !std.mem.eql(u8, np.ref_des, hub_ref)) {
                                    should_show = true;
                                    break;
                                }
                                // Spoke in a different section: net crosses section boundaries,
                                // so the label belongs on this side of the crossing too.
                                if (self.spoke_set.contains(np.ref_des)) {
                                    const other_section = self.section_map.get(np.ref_des);
                                    if (my_section != null and other_section != null and my_section.? != other_section.?) {
                                        should_show = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    if (!should_show) continue;
                }
                try classified.append(self.allocator, .{ .conn = conn, .terminal = term });
            },
            .pin => |p| {
                if (self.rendered_spokes.contains(p.ref_des)) continue;
                const term = try getConnTerminal(self, conn.endpoint, hub_ref, conn.pin);
                try classified.append(self.allocator, .{ .conn = conn, .terminal = term });
            },
        }
    }

    if (classified.items.len == 0) return;

    std.mem.sortUnstable(Classified, classified.items, {}, struct {
        fn lt(_: void, a: Classified, b: Classified) bool {
            return std.mem.lessThan(u8, a.terminal, b.terminal);
        }
    }.lt);

    var slot_counts = try self.allocator.alloc(u32, classified.items.len);
    var total_slots: u32 = 0;
    for (classified.items, 0..) |entry, i| {
        const slots: u32 = switch (entry.conn.endpoint) {
            .pin => |p| blk: {
                if (self.spoke_set.contains(p.ref_des)) {
                    break :blk estimateBranchCount(self, p.ref_des, hub_ref);
                }
                break :blk 1;
            },
            .net => 1,
        };
        slot_counts[i] = slots;
        total_slots += slots;
    }
    const total_height = @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;
    _ = total_height;

    var results: std.ArrayListUnmanaged(BranchBody) = .empty;

    const multi = classified.items.len > 1;
    const bus_offset: f64 = 10.0;
    const bus_x: f64 = switch (side) {
        .left => stub_x - bus_offset,
        .right => stub_x + bus_offset,
    };

    var consumed_slots: u32 = 0;
    var min_cy: f64 = py;
    var max_cy: f64 = py;
    const total_h2 = @as(f64, @floatFromInt(@max(total_slots, 1) -| 1)) * per_conn_spacing;

    for (classified.items, 0..) |entry, i| {
        const slots = slot_counts[i];
        const slot_center = @as(f64, @floatFromInt(consumed_slots)) + @as(f64, @floatFromInt(slots -| 1)) / 2.0;
        const cy = py + slot_center * per_conn_spacing - total_h2 / 2.0;
        consumed_slots += slots;
        if (cy < min_cy) min_cy = cy;
        if (cy > max_cy) max_cy = cy;

        const internal_net: []const u8 = switch (entry.conn.endpoint) {
            .net => entry.terminal,
            .pin => pin_net_name,
        };

        const conn_stub_x = if (multi) bus_x else stub_x;
        const conn_stub_y = if (multi) cy else py;

        const end_x = try renderConnBody(self, w, entry.conn.endpoint, hub_ref, entry.conn.pin, conn_stub_x, conn_stub_y, cy, side, internal_net);

        try results.append(self.allocator, .{ .end_x = end_x, .cy = cy, .terminal = entry.terminal });
    }

    if (multi) {
        try drawNetWire(w, stub_x, py, bus_x, py, pin_net_name);
        if (min_cy != max_cy) {
            try w.print(
                \\<g class="net" data-net="{s}" style="cursor:pointer">
                \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="transparent" stroke-width="12" class="hit-area"/>
                \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#4a9" stroke-width="1.5"/>
                \\</g>
                \\
            , .{ pin_net_name, bus_x, min_cy, bus_x, max_cy, bus_x, min_cy, bus_x, max_cy });
        }
    }

    var default_term_x: f64 = switch (side) {
        .left => stub_x - spoke_len - 20.0,
        .right => stub_x + spoke_len + 20.0,
    };
    for (results.items) |r| {
        switch (side) {
            .left => {
                default_term_x = @min(default_term_x, r.end_x - 20.0);
            },
            .right => {
                default_term_x = @max(default_term_x, r.end_x + 20.0);
            },
        }
    }
    const term_x = default_term_x;

    try renderTerminalGroups(self, w, results.items, term_x, side);
}

/// Render terminal labels/symbols, grouping by terminal name.
pub fn renderTerminalGroups(self: *RenderCtx, w: anytype, results: []const BranchBody, term_x: f64, side: Side) RenderError!void {
    if (results.len == 0) return;

    const anchor: []const u8 = switch (side) {
        .left => "end",
        .right => "start",
    };

    var i: usize = 0;
    while (i < results.len) {
        const term = results[i].terminal;
        var j = i + 1;
        while (j < results.len) : (j += 1) {
            if (!std.mem.eql(u8, results[j].terminal, term)) break;
        }
        const group_slice = results[i..j];

        if (!self.significant_nets.contains(term)) {
            i = j;
            continue;
        }

        if (group_slice.len == 1) {
            const r = group_slice[0];
            try drawNetWire(w, r.end_x, r.cy, term_x, r.cy, term);
            try branch_mod.drawTerminal(self, w, term_x, r.cy, term, anchor);
        } else {
            const nearest_x = blk: {
                var nx: f64 = switch (side) {
                    .left => 99999.0,
                    .right => -99999.0,
                };
                for (group_slice) |r| {
                    switch (side) {
                        .left => {
                            nx = @min(nx, r.end_x);
                        },
                        .right => {
                            nx = @max(nx, r.end_x);
                        },
                    }
                }
                break :blk nx;
            };
            const grp_bus_x = switch (side) {
                .left => nearest_x - 20.0,
                .right => nearest_x + 20.0,
            };

            const first_cy = group_slice[0].cy;
            const last_cy = group_slice[group_slice.len - 1].cy;

            for (group_slice) |r| {
                try drawNetWire(w, r.end_x, r.cy, grp_bus_x, r.cy, term);
            }

            try drawNetWire(w, grp_bus_x, first_cy, grp_bus_x, last_cy, term);
            try drawNetWire(w, grp_bus_x, last_cy, term_x, last_cy, term);
            try branch_mod.drawTerminal(self, w, term_x, last_cy, term, anchor);
        }

        i = j;
    }
}

/// Get the terminal net name for a connection endpoint.
pub fn getConnTerminal(self: *RenderCtx, endpoint: Endpoint, hub_ref: []const u8, from_pin: []const u8) RenderError![]const u8 {
    switch (endpoint) {
        .net => |net| return net,
        .pin => |p| {
            if (self.spoke_set.contains(p.ref_des)) {
                var visited: std.StringHashMapUnmanaged(void) = .empty;
                try visited.put(self.allocator, p.ref_des, {});
                const result = try findSpokeChain(self, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);
                return result.terminal;
            } else {
                if (self.adjacency.get(p.ref_des)) |adj_list| {
                    for (adj_list.items) |ae| {
                        if (std.mem.eql(u8, ae.pin, p.pin)) {
                            switch (ae.endpoint) {
                                .net => |n| return n,
                                .pin => {},
                            }
                        }
                    }
                }
                return try std.fmt.allocPrint(self.allocator, "{s}_pin{s}", .{ p.ref_des, p.pin });
            }
        },
    }
}

/// Find spoke chain result.
pub const ChainResult = struct {
    chain: []const FlatInst,
    terminal: []const u8,
    branches: []const ctx_mod.Branch,
};

/// Follow a chain of passives from a spoke, detecting branches at junctions.
pub fn findSpokeChain(self: *RenderCtx, ref_des: []const u8, came_from: Endpoint, visited: *std.StringHashMapUnmanaged(void)) error{OutOfMemory}!ChainResult {
    const adj_list = self.adjacency.get(ref_des) orelse return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };

    var from_pins: std.ArrayListUnmanaged([]const u8) = .empty;
    for (adj_list.items) |ae| {
        if (endpointEql(ae.endpoint, came_from)) {
            try from_pins.append(self.allocator, ae.pin);
        }
    }

    var other_conns: std.ArrayListUnmanaged(AdjEntry) = .empty;
    for (adj_list.items) |ae| {
        var is_from_pin = false;
        for (from_pins.items) |fp| {
            if (std.mem.eql(u8, ae.pin, fp)) {
                is_from_pin = true;
                break;
            }
        }
        if (!is_from_pin) {
            try other_conns.append(self.allocator, ae);
        }
    }

    return tryChainConns(self, other_conns.items, ref_des, visited);
}

fn tryChainConns(self: *RenderCtx, conns: []const AdjEntry, current_ref: []const u8, visited: *std.StringHashMapUnmanaged(void)) error{OutOfMemory}!ChainResult {
    if (conns.len == 0) return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };

    const ae = conns[0];
    switch (ae.endpoint) {
        .net => |net| {
            if (isGroundNet(net)) return .{ .chain = &.{}, .terminal = net, .branches = &.{} };

            const net_pins = self.net_index.get(net) orelse return .{ .chain = &.{}, .terminal = net, .branches = &.{} };

            var has_hub = false;
            for (net_pins.items) |np| {
                if (!std.mem.eql(u8, np.ref_des, current_ref) and !self.spoke_set.contains(np.ref_des)) {
                    has_hub = true;
                    break;
                }
            }
            if (has_hub) return .{ .chain = &.{}, .terminal = net, .branches = &.{} };

            var other_spokes: std.ArrayListUnmanaged(PinRef) = .empty;
            for (net_pins.items) |np| {
                if (!std.mem.eql(u8, np.ref_des, current_ref) and
                    self.spoke_set.contains(np.ref_des) and
                    !visited.contains(np.ref_des))
                {
                    try other_spokes.append(self.allocator, np);
                }
            }

            if (other_spokes.items.len == 0) {
                return .{ .chain = &.{}, .terminal = net, .branches = &.{} };
            } else if (other_spokes.items.len == 1) {
                const next_ref = other_spokes.items[0].ref_des;
                const next_inst = self.inst_map.get(next_ref) orelse return .{ .chain = &.{}, .terminal = net, .branches = &.{} };
                try visited.put(self.allocator, next_ref, {});
                const rest = try findSpokeChain(self, next_ref, .{ .net = net }, visited);
                var chain: std.ArrayListUnmanaged(FlatInst) = .empty;
                try chain.append(self.allocator, next_inst);
                for (rest.chain) |c| try chain.append(self.allocator, c);
                return .{
                    .chain = try chain.toOwnedSlice(self.allocator),
                    .terminal = rest.terminal,
                    .branches = rest.branches,
                };
            } else {
                var branches: std.ArrayListUnmanaged(ctx_mod.Branch) = .empty;
                for (other_spokes.items) |sp| {
                    if (visited.contains(sp.ref_des)) continue;
                    const sib_inst = self.inst_map.get(sp.ref_des) orelse continue;
                    try visited.put(self.allocator, sp.ref_des, {});
                    const sub = try findSpokeChain(self, sp.ref_des, .{ .net = net }, visited);
                    var chain: std.ArrayListUnmanaged(FlatInst) = .empty;
                    try chain.append(self.allocator, sib_inst);
                    for (sub.chain) |c| try chain.append(self.allocator, c);
                    try branches.append(self.allocator, .{
                        .chain = try chain.toOwnedSlice(self.allocator),
                        .terminal = sub.terminal,
                    });
                }
                return .{
                    .chain = &.{},
                    .terminal = net,
                    .branches = try branches.toOwnedSlice(self.allocator),
                };
            }
        },
        .pin => |p| {
            if (self.spoke_set.contains(p.ref_des)) {
                if (visited.contains(p.ref_des)) {
                    if (conns.len > 1) {
                        return tryChainConns(self, conns[1..], current_ref, visited);
                    }
                    return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };
                }
                const next_inst = self.inst_map.get(p.ref_des) orelse return .{ .chain = &.{}, .terminal = "?", .branches = &.{} };
                try visited.put(self.allocator, p.ref_des, {});
                const rest = try findSpokeChain(self, p.ref_des, .{ .pin = .{ .ref_des = current_ref, .pin = ae.pin } }, visited);
                var chain: std.ArrayListUnmanaged(FlatInst) = .empty;
                try chain.append(self.allocator, next_inst);
                for (rest.chain) |c| try chain.append(self.allocator, c);
                return .{
                    .chain = try chain.toOwnedSlice(self.allocator),
                    .terminal = rest.terminal,
                    .branches = rest.branches,
                };
            } else {
                if (self.adjacency.get(p.ref_des)) |adj_list| {
                    for (adj_list.items) |adj_ae| {
                        if (std.mem.eql(u8, adj_ae.pin, p.pin)) {
                            switch (adj_ae.endpoint) {
                                .net => |n| return .{ .chain = &.{}, .terminal = n, .branches = &.{} },
                                .pin => {},
                            }
                        }
                    }
                }
                return .{ .chain = &.{}, .terminal = try std.fmt.allocPrint(self.allocator, "{s}_pin{s}", .{ p.ref_des, p.pin }), .branches = &.{} };
            }
        },
    }
}

/// Render the body of a connection. Returns end_x position.
pub fn renderConnBody(self: *RenderCtx, w: anytype, endpoint: Endpoint, hub_ref: []const u8, from_pin: []const u8, stub_x: f64, stub_y: f64, cy: f64, side: Side, net_name: []const u8) RenderError!f64 {
    switch (endpoint) {
        .net => {
            const end_x: f64 = switch (side) {
                .left => stub_x - 20.0,
                .right => stub_x + 20.0,
            };
            try drawNetWire(w, stub_x, stub_y, end_x, cy, net_name);
            return end_x;
        },
        .pin => |p| {
            if (self.spoke_set.contains(p.ref_des)) {
                if (self.rendered_spokes.contains(p.ref_des)) {
                    return stub_x;
                }

                const inst = self.inst_map.get(p.ref_des) orelse return stub_x;
                try self.rendered_spokes.put(self.allocator, p.ref_des, {});

                var visited: std.StringHashMapUnmanaged(void) = .empty;
                try visited.put(self.allocator, p.ref_des, {});
                const chain_result = try findSpokeChain(self, p.ref_des, .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } }, &visited);

                for (chain_result.chain) |c| {
                    try self.rendered_spokes.put(self.allocator, c.ref_des, {});
                }

                var all_spokes: std.ArrayListUnmanaged(FlatInst) = .empty;
                try all_spokes.append(self.allocator, inst);
                for (chain_result.chain) |c| try all_spokes.append(self.allocator, c);

                switch (side) {
                    .left => {
                        try drawNetWire(w, stub_x, stub_y, stub_x - 20.0, cy, net_name);
                        const chain_end_x = try branch_mod.drawPassiveChainLeft(self, w, stub_x - 20.0, cy, all_spokes.items);
                        if (chain_result.branches.len > 0) {
                            try branch_mod.drawBranchTreeLeft(self, w, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                        }
                        return chain_end_x;
                    },
                    .right => {
                        try drawNetWire(w, stub_x, stub_y, stub_x + 20.0, cy, net_name);
                        const chain_end_x = try branch_mod.drawPassiveChainRight(self, w, stub_x + 20.0, cy, all_spokes.items);
                        if (chain_result.branches.len > 0) {
                            try branch_mod.drawBranchTreeRight(self, w, chain_end_x, cy, chain_result.branches, chain_result.terminal);
                        }
                        return chain_end_x;
                    },
                }
            } else {
                const end_x: f64 = switch (side) {
                    .left => stub_x - spoke_len - 20.0,
                    .right => stub_x + spoke_len + 20.0,
                };
                try drawNetWire(w, stub_x, stub_y, end_x, cy, net_name);
                return end_x;
            }
        },
    }
}
