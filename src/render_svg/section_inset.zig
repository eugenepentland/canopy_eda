const std = @import("std");
const env_mod = @import("../eval/env.zig");
const ctx_mod = @import("context.zig");
const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const AdjEntry = ctx_mod.AdjEntry;
const PinGroup = ctx_mod.PinGroup;
const connection = @import("connection.zig");
const hub_mod = @import("hub.zig");
const draw = @import("draw.zig");
const hub_width = draw.hub_width;
const hub_x = draw.hub_x;
const pin_stub = draw.pin_stub;
const shortRef = draw.shortRef;
const displayValue = draw.displayValue;

/// Two possibly-overlapping selections of a hub's pin-groups for the HTML
/// schematic view. `direct` feeds the master table; `spoke` feeds the SVG
/// inset. A pin-group can appear in both when it has both cross-device
/// significance (a port, or a connection to another hub) and local support
/// (a dedicated decouple cap, crystal, etc.).
pub const Partition = struct {
    direct: []const PinGroup,
    spoke: []const PinGroup,
};

/// Select a hub's pin-groups into two views:
///
/// * **Table (direct)** — pin-groups with *cross-device significance*:
///   any `.pin` endpoint to another hub, any `.pin` to a shared passive
///   (e.g., series resistor bridging two hubs), or any `.net` endpoint on a
///   declared section/block port.
/// * **SVG (spoke)** — pin-groups with local support worth visualizing:
///   any `.pin` endpoint to a passive dedicated to this hub, or any `.net`
///   endpoint on a ground net.
///
/// A pin-group may land in both — VDD on an MCU is a port *and* has
/// decoupling, so it earns a table row (to show which hub pins are VDD) and
/// an SVG stub (to show the cap). A pin-group matching neither rule
/// (rare — e.g., a bare net that's not a port and not cross-hub) falls back
/// to SVG so nothing disappears.
pub fn partitionGroups(
    allocator: std.mem.Allocator,
    ctx: *RenderCtx,
    hub_ref: []const u8,
    groups: []const PinGroup,
) !Partition {
    var direct: std.ArrayListUnmanaged(PinGroup) = .empty;
    var spoke: std.ArrayListUnmanaged(PinGroup) = .empty;
    for (groups) |g| {
        // Ground pins render in the SVG only — GND is universally shared and
        // would otherwise trip the cross-hub check, cluttering every table.
        if (groupIsGround(g)) {
            try spoke.append(allocator, g);
            continue;
        }
        const for_svg = hasDedicatedSpoke(ctx, g, hub_ref);
        const for_table = hasCrossDeviceSignificance(ctx, g, hub_ref, groups);
        if (for_table) try direct.append(allocator, g);
        if (for_svg) try spoke.append(allocator, g);
        // Fallback: pins with a real net connection but no local spoke and no
        // in-section peer (e.g. stm32 pins driving a sub-block at the parent
        // level) still belong in the table. Rendering them as bare SVG stubs
        // leaves an orphan pin with no wire.
        if (!for_table and !for_svg) try direct.append(allocator, g);
    }
    return .{
        .direct = try direct.toOwnedSlice(allocator),
        .spoke = try spoke.toOwnedSlice(allocator),
    };
}

fn hasDedicatedSpoke(ctx: *RenderCtx, g: PinGroup, hub_ref: []const u8) bool {
    for (g.conns) |c| switch (c.endpoint) {
        .pin => |p| {
            if (ctx.spoke_set.contains(p.ref_des) and isDedicatedSpoke(ctx, p.ref_des, hub_ref)) return true;
        },
        .net => {},
    };
    return false;
}

fn hasCrossDeviceSignificance(ctx: *RenderCtx, g: PinGroup, hub_ref: []const u8, all_groups: []const PinGroup) bool {
    _ = all_groups;
    for (g.conns) |c| switch (c.endpoint) {
        .pin => |p| {
            // Another hub directly, or a spoke passive that bridges to another hub.
            if (!ctx.spoke_set.contains(p.ref_des)) return true;
            if (!isDedicatedSpoke(ctx, p.ref_des, hub_ref)) return true;
        },
        .net => |n| {
            if (netIsCrossDevice(ctx, draw.baseNetName(n), hub_ref)) return true;
        },
    };
    // Fallback: the real net may only show up through `pin_canonical_nets`
    // (e.g., STM32 VDD pins whose adjacency lists only dedicated decouple
    // caps — no `.net` endpoint). Resolve each pin's canonical net and check
    // it the same way.
    var pin_it = std.mem.splitScalar(u8, g.pin_numbers, ',');
    while (pin_it.next()) |pin_id| {
        if (pin_id.len == 0) continue;
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}.{s}", .{ hub_ref, pin_id }) catch continue;
        if (ctx.pin_canonical_nets.get(key)) |net| {
            if (netIsCrossDevice(ctx, draw.baseNetName(net), hub_ref)) return true;
        }
    }
    return false;
}

/// A net is cross-device when it's a declared port OR when at least one other
/// hub in the design pins it too. The latter catches hub-to-hub buses wired
/// directly (no passive between them) — e.g. the XSPI signals shared by the
/// STM32 and the PSRAM.
fn netIsCrossDevice(ctx: *RenderCtx, base_net: []const u8, hub_ref: []const u8) bool {
    if (ctx.port_nets.contains(base_net)) return true;
    if (ctx.net_index.get(base_net)) |pin_list| {
        for (pin_list.items) |pr| {
            if (std.mem.eql(u8, pr.ref_des, hub_ref)) continue;
            if (ctx.spoke_set.contains(pr.ref_des)) continue;
            return true;
        }
    }
    return false;
}

fn groupIsGround(g: PinGroup) bool {
    for (g.conns) |c| switch (c.endpoint) {
        .net => |n| if (draw.isGroundNet(draw.baseNetName(n))) return true,
        .pin => {},
    };
    return false;
}

/// A spoke is dedicated to `hub_ref` when none of its adjacency `.pin`
/// endpoints target a different hub. Ground/terminal nets don't count — those
/// are just how a decoupling cap closes its loop.
fn isDedicatedSpoke(ctx: *RenderCtx, spoke_ref: []const u8, hub_ref: []const u8) bool {
    const adj = ctx.adjacency.get(spoke_ref) orelse return true;
    for (adj.items) |ae| switch (ae.endpoint) {
        .pin => |p| {
            if (!std.mem.eql(u8, p.ref_des, hub_ref)) return false;
        },
        .net => {},
    };
    return true;
}

/// A spoke instance whose `inst_map` entry was temporarily rewritten to add a
/// count prefix (e.g. value `"100nF"` → `"3× 100nF"`). Restored by
/// `restoreInstMap` after the SVG is written.
const Saved = struct { ref: []const u8, original: FlatInst };

/// Collapse runs of identical single-passive spokes before rendering.
///
/// For every `.pin` endpoint in a spoke group, build a merge key
/// `(terminal | value | symbol)` — any spoke whose chain is literally one
/// passive hanging off the hub pin and landing at the same terminal hashes to
/// the same key. Representative instances get their `value` rewritten to
/// `"Nx original"`; duplicates go into `rendered_spokes` so the SVG primitive
/// skips them. The canvas viewer did the same thing via `mergeIdenticalSpokes`
/// in `render_json.zig` — this is the same idea, just applied directly to the
/// shared `RenderCtx` state.
fn applyMergeAnnotations(
    ctx: *RenderCtx,
    hub_ref: []const u8,
    groups: []const PinGroup,
    saved: *std.ArrayListUnmanaged(Saved),
) !void {
    const allocator = ctx.allocator;

    for (groups) |g| {
        // For this group, bucket mergeable .pin endpoints by merge key.
        var buckets: std.StringHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .empty;
        defer {
            var it = buckets.iterator();
            while (it.next()) |kv| kv.value_ptr.deinit(allocator);
            buckets.deinit(allocator);
        }

        for (g.conns) |c| switch (c.endpoint) {
            .pin => |p| {
                if (!ctx.spoke_set.contains(p.ref_des)) continue;
                if (!isSinglePassiveToTerminal(ctx, p.ref_des, hub_ref, c.pin)) continue;
                const inst = ctx.inst_map.get(p.ref_des) orelse continue;
                const terminal = try connection.getConnTerminal(ctx, c.endpoint, hub_ref, c.pin);
                const val = if (inst.value.len > 0) inst.value else inst.component;
                const key = try std.fmt.allocPrint(allocator, "{s}|{s}|{s}", .{ terminal, val, inst.symbol });
                const gop = try buckets.getOrPut(allocator, key);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                try gop.value_ptr.append(allocator, p.ref_des);
            },
            .net => {},
        };

        var it = buckets.iterator();
        while (it.next()) |kv| {
            const refs = kv.value_ptr.items;
            if (refs.len < 2) continue;

            const rep_ref = refs[0];
            const original = ctx.inst_map.get(rep_ref) orelse continue;
            try saved.append(allocator, .{ .ref = rep_ref, .original = original });

            const base_val = if (original.value.len > 0) original.value else original.component;
            const new_value = try std.fmt.allocPrint(allocator, "{d}× {s}", .{ refs.len, base_val });

            var modified = original;
            modified.value = new_value;
            try ctx.inst_map.put(allocator, rep_ref, modified);

            // Every non-representative duplicate is already "drawn" as far as
            // the SVG pass is concerned — mark it rendered so any branch logic
            // that encounters it further down the chain skips it.
            for (refs[1..]) |dup| try ctx.rendered_spokes.put(allocator, dup, {});
        }
    }
}

fn restoreInstMap(ctx: *RenderCtx, saved: []const Saved) void {
    // Called from defer — can't propagate. OOM on restore would corrupt the
    // map, so log every failure rather than silently dropping the entry.
    for (saved) |s| ctx.inst_map.put(ctx.allocator, s.ref, s.original) catch |e| {
        std.debug.print("warning: restoreInstMap put {s}: {s}\n", .{ s.ref, @errorName(e) });
    };
}

/// A spoke counts as "single passive to terminal" when its chain from the
/// hub pin is just that one instance and it terminates at a real net — no
/// further hops. This is the shape that mergeable decoupling caps take.
fn isSinglePassiveToTerminal(
    ctx: *RenderCtx,
    spoke_ref: []const u8,
    hub_ref: []const u8,
    from_pin: []const u8,
) bool {
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    defer visited.deinit(ctx.allocator);
    visited.put(ctx.allocator, spoke_ref, {}) catch return false;
    const chain = connection.findSpokeChain(
        ctx,
        spoke_ref,
        .{ .pin = .{ .ref_des = hub_ref, .pin = from_pin } },
        &visited,
    ) catch return false;
    return chain.chain.len == 0 and chain.branches.len == 0;
}

/// Render a standalone `<svg>` showing `hub` with the supplied pin groups
/// drawn balanced left/right. Layout mirrors `hub.renderHub`. Returns without
/// writing anything if `groups` is empty. Identical-spoke runs (e.g. five
/// 100nF caps to the same VDD/GND terminal) are collapsed visually via
/// `applyMergeAnnotations` before drawing.
pub fn renderHubAllPins(
    ctx: *RenderCtx,
    w: anytype,
    hub: FlatInst,
    groups: []const PinGroup,
) !void {
    if (groups.len == 0) return;

    var saved: std.ArrayListUnmanaged(Saved) = .empty;
    defer {
        restoreInstMap(ctx, saved.items);
        saved.deinit(ctx.allocator);
    }
    try applyMergeAnnotations(ctx, hub.ref_des, groups, &saved);

    var left_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var right_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var left_pc: usize = 0;
    var right_pc: usize = 0;
    for (groups) |g| {
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, g.pin_numbers, ',');
        while (it.next()) |_| n += 1;
        if (left_pc <= right_pc) {
            try left_list.append(ctx.allocator, g);
            left_pc += n;
        } else {
            try right_list.append(ctx.allocator, g);
            right_pc += n;
        }
    }

    const left_groups = left_list.items;
    const right_groups = right_list.items;

    const left_heights = try hub_mod.groupHeights(ctx, left_groups, hub.ref_des);
    const right_heights = try hub_mod.groupHeights(ctx, right_groups, hub.ref_des);

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;
    const hub_height = @max(@max(left_total, right_total), 40.0) + 40.0;

    // Pad viewBox to include spoke trees on either side.
    const y_start: f64 = 20.0;
    const svg_w: f64 = hub_x + hub_width + 320.0;
    const svg_h: f64 = hub_height + y_start + 20.0;

    try w.print(
        \\<svg class="hub-inset" viewBox="0 0 {d:.0} {d:.0}" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg" data-ref="{s}">
        \\
    , .{ svg_w, svg_h, hub.ref_des });

    try w.print(
        \\<g data-ref="{s}" class="component"><rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" fill="#16213e" stroke="#4a9eff" stroke-width="2" rx="6"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="12" font-weight="bold" fill="#4a9eff">{s} {s}</text></g>
        \\
    , .{
        hub.ref_des,
        hub_x,
        y_start,
        hub_width,
        hub_height,
        hub_x + hub_width / 2.0,
        y_start + 18.0,
        shortRef(hub.ref_des),
        displayValue(hub),
    });

    var py_left: f64 = y_start + 40.0;
    for (left_groups, 0..) |group, gi| {
        const h = left_heights[gi];
        const cy = py_left + h / 2.0;
        try renderPinStub(w, .left, hub_x, cy, group, hub.ref_des);
        try connection.renderGroupedConnections(ctx, w, hub.ref_des, group, hub_x - pin_stub, cy, .left);
        py_left += h;
    }

    var py_right: f64 = y_start + 40.0;
    for (right_groups, 0..) |group, gi| {
        const h = right_heights[gi];
        const cy = py_right + h / 2.0;
        try renderPinStub(w, .right, hub_x + hub_width, cy, group, hub.ref_des);
        try connection.renderGroupedConnections(ctx, w, hub.ref_des, group, hub_x + hub_width + pin_stub, cy, .right);
        py_right += h;
    }

    try w.writeAll("</svg>");
}

fn renderPinStub(w: anytype, side: ctx_mod.Side, px: f64, py: f64, group: PinGroup, hub_ref: []const u8) !void {
    // Wrap the stub in a <g class="pin-stub"> with data-ref/data-pin so the
    // sidebar can scrollIntoView() to a specific pin and attach hover/click
    // behavior. Pin numbers stay comma-separated; the JS splits as needed.
    try w.print(
        \\<g class="pin-stub" data-ref="{s}" data-pin="{s}">
        \\
    , .{ hub_ref, group.pin_numbers });
    // Long GND/VSS chains can have 9+ pins; spelling them all out blows past
    // the hub's column width, so collapse ≥4 into "Nx pins" for display.
    // `data-pin` above still carries the full list for click routing.
    var pin_label_buf: [16]u8 = undefined;
    const pin_label = draw.compactPinNumbers(&pin_label_buf, group.pin_numbers);
    switch (side) {
        .left => {
            const stub_x = px - pin_stub;
            try w.print(
                \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#666" stroke-width="1.5"/>
                \\<text x="{d:.1}" y="{d:.1}" font-size="12" fill="#aaa">{s}</text>
                \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="10" fill="#666">{s}</text>
                \\
            , .{
                stub_x,             py,            px,
                py,                 px + 8.0,      py + 4.0,
                group.display_name, stub_x + 38.0, py - 1.0,
                pin_label,
            });
        },
        .right => {
            const stub_x = px + pin_stub;
            try w.print(
                \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#666" stroke-width="1.5"/>
                \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="12" fill="#aaa">{s}</text>
                \\<text x="{d:.1}" y="{d:.1}" font-size="10" fill="#666">{s}</text>
                \\
            , .{
                px,                 py,            stub_x,
                py,                 px - 8.0,      py + 4.0,
                group.display_name, stub_x - 36.0, py - 1.0,
                pin_label,
            });
        },
    }
    try w.writeAll("</g>\n");
}
