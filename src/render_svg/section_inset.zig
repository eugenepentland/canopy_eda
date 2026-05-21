const std = @import("std");
const log = @import("../infra/log.zig");
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
const RenderError = draw.RenderError;

// ── Layout constants ──────────────────────────────────────────────
const HALF_DIVISOR: f64 = 2.0;
const HUB_VPAD: f64 = 40.0;
const SVG_TOP_MARGIN: f64 = 20.0;
const SVG_RIGHT_PAD: f64 = 320.0;
const SVG_BOTTOM_PAD: f64 = 20.0;
const HUB_TITLE_Y: f64 = 18.0;
const PIN_LABEL_PAD_X: f64 = 8.0;
const PIN_LABEL_PAD_Y: f64 = 4.0;
const PIN_NUMBER_INSET_LEFT: f64 = 38.0;
const PIN_NUMBER_INSET_RIGHT: f64 = 36.0;
const PIN_NUMBER_BASELINE: f64 = 1.0;

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
        log.warn("restoreInstMap put {s}: {s}", .{ s.ref, @errorName(e) });
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
) RenderError!void {
    if (groups.len == 0) return;

    var saved: std.ArrayListUnmanaged(Saved) = .empty;
    defer {
        restoreInstMap(ctx, saved.items);
        saved.deinit(ctx.allocator);
    }
    try applyMergeAnnotations(ctx, hub.ref_des, groups, &saved);

    const split = try hub_mod.splitGroupsByHeight(ctx, groups, hub.ref_des);
    const left_groups = split.left;
    const right_groups = split.right;
    const left_heights = split.left_heights;
    const right_heights = split.right_heights;

    var left_total: f64 = 0;
    for (left_heights) |h| left_total += h;
    var right_total: f64 = 0;
    for (right_heights) |h| right_total += h;
    const hub_height = @max(@max(left_total, right_total), HUB_VPAD) + HUB_VPAD;

    // Pad viewBox to include spoke trees on either side.
    const y_start: f64 = SVG_TOP_MARGIN;
    const svg_w: f64 = hub_x + hub_width + SVG_RIGHT_PAD;
    const svg_h: f64 = hub_height + y_start + SVG_BOTTOM_PAD;

    try w.print(
        \\<svg class="hub-inset" viewBox="0 0 {d:.0} {d:.0}" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg" data-ref="{s}">
        \\
    , .{ svg_w, svg_h, hub.ref_des });

    try w.print(
        \\<g data-ref="{s}" class="component">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}"
        \\  fill="#16213e" stroke="#4a9eff" stroke-width="2" rx="6"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle"
        \\  font-size="12" font-weight="bold" fill="#4a9eff">{s} {s}</text></g>
        \\
    , .{
        hub.ref_des,
        hub_x,
        y_start,
        hub_width,
        hub_height,
        hub_x + hub_width / HALF_DIVISOR,
        y_start + HUB_TITLE_Y,
        shortRef(hub.ref_des),
        displayValue(hub),
    });

    var py_left: f64 = y_start + HUB_VPAD;
    for (left_groups, 0..) |group, gi| {
        const h = left_heights[gi];
        const cy = py_left + h / HALF_DIVISOR;
        try renderPinStub(w, .left, hub_x, cy, group, hub.ref_des);
        try connection.renderGroupedConnections(ctx, w, hub.ref_des, group, hub_x - pin_stub, cy, .left);
        py_left += h;
    }

    var py_right: f64 = y_start + HUB_VPAD;
    for (right_groups, 0..) |group, gi| {
        const h = right_heights[gi];
        const cy = py_right + h / HALF_DIVISOR;
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
                stub_x,             py,                             px,
                py,                 px + PIN_LABEL_PAD_X,           py + PIN_LABEL_PAD_Y,
                group.display_name, stub_x + PIN_NUMBER_INSET_LEFT, py - PIN_NUMBER_BASELINE,
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
                px,                 py,                              stub_x,
                py,                 px - PIN_LABEL_PAD_X,            py + PIN_LABEL_PAD_Y,
                group.display_name, stub_x - PIN_NUMBER_INSET_RIGHT, py - PIN_NUMBER_BASELINE,
                pin_label,
            });
        },
    }
    try w.writeAll("</g>\n");
}
