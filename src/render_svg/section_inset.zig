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

/// A hub pin-group partitioned for the HTML schematic view.
/// Direct groups feed the HTML pin-table; spoke groups feed the SVG inset.
pub const Partition = struct {
    direct: []const PinGroup,
    spoke: []const PinGroup,
};

/// Partition a hub's pin-groups into direct-table and spoke-SVG buckets.
///
/// A spoke is *dedicated* to this hub when it only connects back to this hub
/// (plus ground/terminal nets) — a decoupling cap is the canonical example. A
/// spoke is *shared* when it also connects to another hub — a series resistor
/// between two ICs is shared infrastructure, and should render as a plain net
/// row on both sides, since the resistor will appear in whichever section
/// declared it.
///
/// Rule: a group is a spoke-group only if it has at least one dedicated spoke.
/// Otherwise (no `.pin` endpoints, or all `.pin` endpoints are shared) it is
/// direct. This keeps the SVG inset reserved for "passives that belong to
/// this hub" and avoids double-drawing shared resistors across sections.
pub fn partitionGroups(
    allocator: std.mem.Allocator,
    ctx: *RenderCtx,
    hub_ref: []const u8,
    groups: []const PinGroup,
) !Partition {
    var direct: std.ArrayListUnmanaged(PinGroup) = .empty;
    var spoke: std.ArrayListUnmanaged(PinGroup) = .empty;
    for (groups) |g| {
        var has_dedicated = false;
        for (g.conns) |c| switch (c.endpoint) {
            .pin => |p| {
                if (isDedicatedSpoke(ctx, p.ref_des, hub_ref)) {
                    has_dedicated = true;
                    break;
                }
            },
            .net => {},
        };
        if (has_dedicated) try spoke.append(allocator, g) else try direct.append(allocator, g);
    }
    return .{
        .direct = try direct.toOwnedSlice(allocator),
        .spoke = try spoke.toOwnedSlice(allocator),
    };
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
    for (saved) |s| ctx.inst_map.put(ctx.allocator, s.ref, s.original) catch {};
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

/// Render a standalone `<svg>` showing `hub` with only its spoke groups drawn.
/// Layout mirrors `hub.renderHub` but scoped to the supplied group list.
/// Returns without writing anything if `spoke_groups` is empty.
pub fn renderHubInset(
    ctx: *RenderCtx,
    w: anytype,
    hub: FlatInst,
    spoke_groups: []const PinGroup,
) !void {
    if (spoke_groups.len == 0) return;

    var saved: std.ArrayListUnmanaged(Saved) = .empty;
    defer {
        restoreInstMap(ctx, saved.items);
        saved.deinit(ctx.allocator);
    }
    try applyMergeAnnotations(ctx, hub.ref_des, spoke_groups, &saved);

    var left_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var right_list: std.ArrayListUnmanaged(PinGroup) = .empty;
    var left_pc: usize = 0;
    var right_pc: usize = 0;
    for (spoke_groups) |g| {
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
        try renderPinStub(w, .left, hub_x, cy, group);
        try connection.renderGroupedConnections(ctx, w, hub.ref_des, group, hub_x - pin_stub, cy, .left);
        py_left += h;
    }

    var py_right: f64 = y_start + 40.0;
    for (right_groups, 0..) |group, gi| {
        const h = right_heights[gi];
        const cy = py_right + h / 2.0;
        try renderPinStub(w, .right, hub_x + hub_width, cy, group);
        try connection.renderGroupedConnections(ctx, w, hub.ref_des, group, hub_x + hub_width + pin_stub, cy, .right);
        py_right += h;
    }

    try w.writeAll("</svg>");
}

fn renderPinStub(w: anytype, side: ctx_mod.Side, px: f64, py: f64, group: PinGroup) !void {
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
                group.pin_numbers,
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
                group.pin_numbers,
            });
        },
    }
}
