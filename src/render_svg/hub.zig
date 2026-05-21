const std = @import("std");
const env_mod = @import("../eval/env.zig");
const ctx_mod = @import("context.zig");
const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const AdjEntry = ctx_mod.AdjEntry;
const PinGroup = ctx_mod.PinGroup;
const draw = @import("draw.zig");
const hub_width = draw.hub_width;
const hub_x = draw.hub_x;
const pin_stub = draw.pin_stub;
const per_conn_spacing = draw.per_conn_spacing;
const isGroundNet = draw.isGroundNet;
const baseNetName = draw.baseNetName;
const shortRef = draw.shortRef;
const displayValue = draw.displayValue;
const pinOrder = draw.pinOrder;
const writeDebugPin = draw.writeDebugPin;
const connection = @import("connection.zig");
const branch = @import("branch.zig");
const RenderError = draw.RenderError;

// ── Layout constants ──────────────────────────────────────────────
const HALF_DIVISOR: f64 = 2.0;
const HUB_VPAD: f64 = 40.0;
const HUB_TITLE_Y: f64 = 18.0;
const PIN_LABEL_PAD_X: f64 = 8.0;
const PIN_LABEL_PAD_Y: f64 = 4.0;
const PIN_NUMBER_INSET_LEFT: f64 = 38.0;
const PIN_NUMBER_INSET_RIGHT: f64 = 36.0;
const PIN_NUMBER_BASELINE: f64 = 1.0;

/// Build a pin_id -> pin_name map from PartPin data.
pub fn buildPinNameMap(self: *RenderCtx, parts: []const env_mod.Part) std.StringHashMapUnmanaged([]const u8) {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (parts) |part| {
        for (part.pins) |pp| {
            if (pp.pin_name.len > 0) {
                map.put(self.allocator, pp.pin, pp.pin_name) catch return map;
            }
        }
    }
    return map;
}

/// Group hub pins: consecutive pins sharing the same net get merged.
pub fn groupHubPins(
    self: *RenderCtx,
    pins: []const []const u8,
    adj_entries: []const AdjEntry,
    pin_names: *const std.StringHashMapUnmanaged([]const u8),
) RenderError![]const PinGroup {
    if (pins.len == 0) return &[_]PinGroup{};

    const PinInfo = struct { pin: []const u8, net: []const u8 };
    var pin_infos: std.ArrayListUnmanaged(PinInfo) = .empty;
    for (pins) |pin_id| {
        var pin_net: []const u8 = "";
        for (adj_entries) |ae| {
            if (std.mem.eql(u8, ae.pin, pin_id)) {
                switch (ae.endpoint) {
                    .net => |n| {
                        pin_net = n;
                        break;
                    },
                    .pin => {},
                }
            }
        }
        try pin_infos.append(self.allocator, .{ .pin = pin_id, .net = pin_net });
    }

    std.mem.sortUnstable(PinInfo, pin_infos.items, {}, struct {
        fn lt(_: void, a: PinInfo, b: PinInfo) bool {
            const cmp = std.mem.order(u8, a.net, b.net);
            if (cmp == .eq) return pinOrder(a.pin, b.pin);
            return cmp == .lt;
        }
    }.lt);

    var groups: std.ArrayListUnmanaged(PinGroup) = .empty;
    var current_pins: std.ArrayListUnmanaged([]const u8) = .empty;
    var current_net: ?[]const u8 = null;
    var current_conns: std.ArrayListUnmanaged(AdjEntry) = .empty;

    for (pin_infos.items) |pi| {
        const pin_id = pi.pin;
        var pin_conns: std.ArrayListUnmanaged(AdjEntry) = .empty;
        for (adj_entries) |ae| {
            if (std.mem.eql(u8, ae.pin, pin_id)) {
                try pin_conns.append(self.allocator, ae);
            }
        }

        const should_merge = blk: {
            if (current_pins.items.len == 0) break :blk false;
            if (pi.net.len > 0) {
                if (current_net) |cn| {
                    if (std.mem.eql(u8, pi.net, cn)) break :blk true;
                }
            }
            break :blk false;
        };

        if (should_merge) {
            try current_pins.append(self.allocator, pin_id);
            for (pin_conns.items) |c| {
                try current_conns.append(self.allocator, c);
            }
        } else {
            if (current_pins.items.len > 0) {
                try groups.append(self.allocator, try finishGroup(self, &current_pins, &current_conns, pin_names));
            }
            current_pins = .empty;
            current_conns = .empty;
            try current_pins.append(self.allocator, pin_id);
            current_net = if (pi.net.len > 0) pi.net else null;
            for (pin_conns.items) |c| {
                try current_conns.append(self.allocator, c);
            }
        }
    }

    if (current_pins.items.len > 0) {
        try groups.append(self.allocator, try finishGroup(self, &current_pins, &current_conns, pin_names));
    }

    return groups.toOwnedSlice(self.allocator);
}

fn finishGroup(
    self: *RenderCtx,
    pins: *std.ArrayListUnmanaged([]const u8),
    conns: *std.ArrayListUnmanaged(AdjEntry),
    pin_names: *const std.StringHashMapUnmanaged([]const u8),
) !PinGroup {
    var display_name: []const u8 = "~";

    if (pins.items.len > 0) {
        if (pin_names.get(pins.items[0])) |func_name| {
            display_name = func_name;
        }
    }

    if (std.mem.eql(u8, display_name, "~")) {
        for (conns.items) |ae| {
            switch (ae.endpoint) {
                .net => |n| {
                    if (!isGroundNet(n)) {
                        display_name = n;
                        break;
                    } else {
                        display_name = n;
                    }
                },
                .pin => {},
            }
        }
    }

    if (std.mem.eql(u8, display_name, "~")) {
        if (pins.items.len == 1) {
            display_name = pins.items[0];
        }
    }

    var num_buf: std.ArrayListUnmanaged(u8) = .empty;
    for (pins.items, 0..) |pn, i| {
        if (i > 0) try num_buf.append(self.allocator, ',');
        try num_buf.appendSlice(self.allocator, pn);
    }

    const deduped = try dedupConns(self, conns.items);

    return PinGroup{
        .display_name = display_name,
        .pin_numbers = try num_buf.toOwnedSlice(self.allocator),
        .conns = deduped,
    };
}

/// Deduplicate connections.
fn dedupConns(self: *RenderCtx, conns: []const AdjEntry) ![]const AdjEntry {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var result: std.ArrayListUnmanaged(AdjEntry) = .empty;
    for (conns) |ae| {
        const key = switch (ae.endpoint) {
            .net => |n| try std.fmt.allocPrint(self.allocator, "net:{s}", .{n}),
            .pin => |p| try std.fmt.allocPrint(self.allocator, "pin:{s}.{s}", .{ p.ref_des, p.pin }),
        };
        if (!seen.contains(key)) {
            try seen.put(self.allocator, key, {});
            try result.append(self.allocator, ae);
        }
    }
    return result.toOwnedSlice(self.allocator);
}

/// Result of splitting hub pin groups into left/right columns.
pub const SplitGroups = struct {
    left: []const PinGroup,
    right: []const PinGroup,
    left_heights: []f64,
    right_heights: []f64,
};

/// Split hub pin groups into left/right columns, balancing by visual
/// height (per-group branch slots from `groupHeights`) instead of raw
/// pin count. Walks groups in order — preserving the alphabetical-by-net
/// order from `groupHubPins` — and assigns each to whichever column has
/// less accumulated height. Pin-count balancing was misleading: a single
/// merged GND group with N pins renders as one short row, while N
/// single-pin signal groups stack into N tall rows, so equal pin counts
/// could leave one side a full chip-height taller than the other (most
/// visible on parts like AD7380-4 where signals/inputs cluster on one
/// physical side of the IC).
pub fn splitGroupsByHeight(
    self: *RenderCtx,
    all_groups: []const PinGroup,
    hub_ref: []const u8,
) RenderError!SplitGroups {
    const all_heights = try groupHeights(self, all_groups, hub_ref);
    defer self.allocator.free(all_heights);

    var left: std.ArrayListUnmanaged(PinGroup) = .empty;
    var right: std.ArrayListUnmanaged(PinGroup) = .empty;
    var left_h: std.ArrayListUnmanaged(f64) = .empty;
    var right_h: std.ArrayListUnmanaged(f64) = .empty;
    var left_total: f64 = 0;
    var right_total: f64 = 0;

    for (all_groups, all_heights) |group, h| {
        if (left_total <= right_total) {
            try left.append(self.allocator, group);
            try left_h.append(self.allocator, h);
            left_total += h;
        } else {
            try right.append(self.allocator, group);
            try right_h.append(self.allocator, h);
            right_total += h;
        }
    }

    return .{
        .left = try left.toOwnedSlice(self.allocator),
        .right = try right.toOwnedSlice(self.allocator),
        .left_heights = try left_h.toOwnedSlice(self.allocator),
        .right_heights = try right_h.toOwnedSlice(self.allocator),
    };
}

/// Calculate per-group heights based on connection count and branch estimates.
pub fn groupHeights(self: *RenderCtx, groups: []const PinGroup, hub_ref: []const u8) RenderError![]f64 {
    var heights = try self.allocator.alloc(f64, groups.len);
    for (groups, 0..) |group, i| {
        var total_slots: i32 = 0;
        for (group.conns) |conn| {
            switch (conn.endpoint) {
                .pin => |p| {
                    if (self.spoke_set.contains(p.ref_des)) {
                        total_slots += @intCast(estimateBranchCount(self, p.ref_des, hub_ref));
                    } else {
                        total_slots += 1;
                    }
                },
                .net => {
                    const bn = baseNetName(conn.endpoint.net);
                    if (self.significant_nets.contains(bn)) {
                        total_slots += 1;
                    }
                },
            }
        }
        const base: f64 = 40.0;
        heights[i] = base + @as(f64, @floatFromInt(@max(total_slots, 1) - 1)) * per_conn_spacing;
    }
    return heights;
}

/// Estimate how many vertical slots a spoke connection needs.
pub fn estimateBranchCount(self: *RenderCtx, spoke_rd: []const u8, hub_ref: []const u8) u32 {
    const adj_list = self.adjacency.get(spoke_rd) orelse return 1;
    var hub_pin: ?[]const u8 = null;
    for (adj_list.items) |ae| {
        switch (ae.endpoint) {
            .pin => |p| {
                if (std.mem.eql(u8, p.ref_des, hub_ref)) {
                    hub_pin = ae.pin;
                    break;
                }
            },
            .net => {},
        }
    }

    for (adj_list.items) |ae| {
        if (hub_pin != null and std.mem.eql(u8, ae.pin, hub_pin.?)) continue;
        switch (ae.endpoint) {
            .net => |net| {
                if (isGroundNet(baseNetName(net))) return 1;
                const net_pins = self.net_index.get(baseNetName(net)) orelse continue;
                var has_hub = false;
                for (net_pins.items) |np| {
                    if (!self.spoke_set.contains(np.ref_des) and !std.mem.eql(u8, np.ref_des, spoke_rd)) {
                        has_hub = true;
                        break;
                    }
                }
                if (has_hub) return 1;

                var other_spokes: u32 = 0;
                for (net_pins.items) |np| {
                    if (std.mem.eql(u8, np.ref_des, spoke_rd)) continue;
                    if (self.spoke_set.contains(np.ref_des)) {
                        other_spokes += 1;
                    }
                }
                if (other_spokes <= 1) return 1;
                return other_spokes;
            },
            .pin => {},
        }
    }
    return 1;
}
