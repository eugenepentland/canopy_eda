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

/// Render a single part of a multi-part instance as its own hub box.
pub fn renderHubPart(self: *RenderCtx, w: anytype, hub: FlatInst, part: env_mod.Part, y_start: f64) !f64 {
    var all_pins: std.ArrayListUnmanaged([]const u8) = .empty;
    defer all_pins.deinit(self.allocator);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(self.allocator);
    for (part.pins) |pp| {
        if (!seen.contains(pp.pin)) {
            try seen.put(self.allocator, pp.pin, {});
            try all_pins.append(self.allocator, pp.pin);
        }
    }
    std.mem.sortUnstable([]const u8, all_pins.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return pinOrder(a, b);
        }
    }.lt);

    const adj_entries = if (self.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};
    var pn_map = buildPinNameMap(self, &[_]env_mod.Part{part});
    defer pn_map.deinit(self.allocator);

    const all_groups = try groupHubPins(self, all_pins.items, adj_entries, &pn_map);
    var left_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var right_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var left_pin_count: usize = 0;
    var right_pin_count: usize = 0;

    for (all_groups) |group| {
        var n: usize = 0;
        var iter = std.mem.splitScalar(u8, group.pin_numbers, ',');
        while (iter.next()) |_| n += 1;
        if (left_pin_count <= right_pin_count) {
            try left_groups_list.append(self.allocator, group);
            left_pin_count += n;
        } else {
            try right_groups_list.append(self.allocator, group);
            right_pin_count += n;
        }
    }

    const left_groups = left_groups_list.toOwnedSlice(self.allocator) catch &[_]PinGroup{};
    const right_groups = right_groups_list.toOwnedSlice(self.allocator) catch &[_]PinGroup{};
    const left_heights = try groupHeights(self, left_groups, hub.ref_des);
    const right_heights = try groupHeights(self, right_groups, hub.ref_des);

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;
    const hub_height = @max(left_total, right_total) + 40.0;
    const box_y = y_start;

    const label = try std.fmt.allocPrint(self.allocator, "{s} {s}", .{ shortRef(hub.ref_des), displayValue(hub) });
    try w.print(
        \\<g class="hub-group" data-ref="{s}" transform="translate(0,0)">
        \\<g data-ref="{s}" data-part="{s}" class="component" style="cursor:pointer"><rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" fill="#16213e" stroke="#4a9eff" stroke-width="2" rx="6"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="12" font-weight="bold" fill="#4a9eff">{s}</text></g>
        \\
    , .{
        hub.ref_des, hub.ref_des,             part.name,
        hub_x,       box_y,                   hub_width,
        hub_height,  hub_x + hub_width / 2.0, box_y + 18.0,
        label,
    });

    var py_left = box_y + 40.0;
    for (left_groups, 0..) |group, gi| {
        const h = left_heights[gi];
        const cy = py_left + h / 2.0;
        try renderPinLeft(self, w, hub.ref_des, group, cy, h);
        py_left += h;
    }

    var py_right = box_y + 40.0;
    for (right_groups, 0..) |group, gi| {
        const h = right_heights[gi];
        const cy = py_right + h / 2.0;
        try renderPinRight(self, w, hub.ref_des, group, cy, h);
        py_right += h;
    }

    try w.writeAll("</g>\n");
    return hub_height;
}

/// Render an entire hub instance as one boxed schematic — gather every
/// pin connected to the hub, group consecutive same-net pins, split them
/// left vs right by pin count, then draw the box, icon, and per-pin
/// connection lanes. Returns the box height so the caller can stack the
/// next section beneath.
pub fn renderHub(self: *RenderCtx, w: anytype, hub: FlatInst, y_start: f64) !f64 {
    var pin_nets_map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    defer pin_nets_map.deinit(self.allocator);

    for (self.nets.items) |net| {
        for (net.pins) |pin| {
            if (std.mem.eql(u8, pin.ref_des, hub.ref_des)) {
                try pin_nets_map.put(self.allocator, pin.pin, baseNetName(net.name));
            }
        }
    }

    var all_pins = try self.allocator.alloc([]const u8, pin_nets_map.count());
    defer self.allocator.free(all_pins);
    for (pin_nets_map.keys(), 0..) |k, i| all_pins[i] = k;
    std.mem.sortUnstable([]const u8, all_pins, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return pinOrder(a, b);
        }
    }.lt);

    const adj_entries = if (self.adjacency.get(hub.ref_des)) |list| list.items else &[_]AdjEntry{};
    var pn_map = buildPinNameMap(self, hub.parts);
    defer pn_map.deinit(self.allocator);

    const all_groups = try groupHubPins(self, all_pins, adj_entries, &pn_map);
    var left_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var right_groups_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var left_pc: usize = 0;
    var right_pc: usize = 0;
    for (all_groups) |group| {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, group.pin_numbers, ',');
        while (it.next()) |_| n += 1;
        if (left_pc <= right_pc) {
            try left_groups_list.append(self.allocator, group);
            left_pc += n;
        } else {
            try right_groups_list.append(self.allocator, group);
            right_pc += n;
        }
    }
    const left_groups = left_groups_list.toOwnedSlice(self.allocator) catch &[_]PinGroup{};
    const right_groups = right_groups_list.toOwnedSlice(self.allocator) catch &[_]PinGroup{};

    const left_heights = try groupHeights(self, left_groups, hub.ref_des);
    const right_heights = try groupHeights(self, right_groups, hub.ref_des);

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;

    const hub_height = @max(left_total, right_total) + 40.0;
    const box_y = y_start;

    try w.print(
        \\<g data-ref="{s}" class="component" style="cursor:pointer"><rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" fill="#16213e" stroke="#4a9eff" stroke-width="2" rx="6"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="12" font-weight="bold" fill="#4a9eff">{s} {s}</text></g>
        \\
    , .{
        hub.ref_des,
        hub_x,
        box_y,
        hub_width,
        hub_height,
        hub_x + hub_width / 2.0,
        box_y + 18.0,
        shortRef(hub.ref_des),
        displayValue(hub),
    });

    try branch.drawHubIcon(self, w, hub, box_y, hub_height);

    var py_left = box_y + 40.0;
    for (left_groups, 0..) |group, gi| {
        const height = left_heights[gi];
        const pin_cy = py_left + height / 2.0;
        try renderPinLeft(self, w, hub.ref_des, group, pin_cy, height);
        py_left += height;
    }

    var py_right = box_y + 40.0;
    for (right_groups, 0..) |group, gi| {
        const height = right_heights[gi];
        const pin_cy = py_right + height / 2.0;
        try renderPinRight(self, w, hub.ref_des, group, pin_cy, height);
        py_right += height;
    }

    return hub_height;
}

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
pub fn groupHubPins(self: *RenderCtx, pins: []const []const u8, adj_entries: []const AdjEntry, pin_names: *const std.StringHashMapUnmanaged([]const u8)) ![]const PinGroup {
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

fn finishGroup(self: *RenderCtx, pins: *std.ArrayListUnmanaged([]const u8), conns: *std.ArrayListUnmanaged(AdjEntry), pin_names: *const std.StringHashMapUnmanaged([]const u8)) !PinGroup {
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

/// Calculate per-group heights based on connection count and branch estimates.
pub fn groupHeights(self: *RenderCtx, groups: []const PinGroup, hub_ref: []const u8) ![]f64 {
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

fn renderPinLeft(self: *RenderCtx, w: anytype, hub_ref: []const u8, group: PinGroup, py: f64, height: f64) !void {
    _ = height;
    const px = hub_x;
    const stub_x = px - pin_stub;

    var pin_label_buf: [16]u8 = undefined;
    const pin_label = draw.compactPinNumbers(&pin_label_buf, group.pin_numbers);

    try w.print(
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#666" stroke-width="1.5"/>
        \\<text x="{d:.1}" y="{d:.1}" font-size="12" fill="#aaa">{s}</text>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="10" fill="#666">{s}</text>
        \\
    , .{
        stub_x,   py,        px,                 py,
        px + 8.0, py + 4.0,  group.display_name, stub_x + 38.0,
        py - 1.0, pin_label,
    });

    try writeDebugPin(w, stub_x, py);
    try connection.renderGroupedConnections(self, w, hub_ref, group, stub_x, py, .left);
}

fn renderPinRight(self: *RenderCtx, w: anytype, hub_ref: []const u8, group: PinGroup, py: f64, height: f64) !void {
    _ = height;
    const px = hub_x + hub_width;
    const stub_x = px + pin_stub;

    var pin_label_buf: [16]u8 = undefined;
    const pin_label = draw.compactPinNumbers(&pin_label_buf, group.pin_numbers);

    try w.print(
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#666" stroke-width="1.5"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="12" fill="#aaa">{s}</text>
        \\<text x="{d:.1}" y="{d:.1}" font-size="10" fill="#666">{s}</text>
        \\
    , .{
        px,       py,        stub_x,             py,
        px - 8.0, py + 4.0,  group.display_name, stub_x - 36.0,
        py - 1.0, pin_label,
    });

    try writeDebugPin(w, stub_x, py);
    try connection.renderGroupedConnections(self, w, hub_ref, group, stub_x, py, .right);
}
