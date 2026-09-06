//! Renders the full-detail hub box with every pin and passive labeled (the
//! section-inset "all pins" view). Sits above `hub.zig`/`connection.zig` for
//! the zoomed-in schematic view.

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
const default_side_pad = draw.hub_x;
const pin_stub = draw.pin_stub;
const per_conn_spacing = draw.per_conn_spacing;
const baseNetName = draw.baseNetName;
const isGroundNet = draw.isGroundNet;
const shortRef = draw.shortRef;
const displayValue = draw.displayValue;
const RenderError = draw.RenderError;
const escape = @import("../escape.zig");

// ── Layout constants ──────────────────────────────────────────────
const half_divisor: f64 = 2.0;
const hub_vpad: f64 = 40.0;
const svg_top_margin: f64 = 20.0;
const svg_bottom_pad: f64 = 20.0;
const hub_title_y: f64 = 18.0;
const pin_label_pad_x: f64 = 8.0;
const pin_label_pad_y: f64 = 4.0;
const pin_number_inset_left: f64 = 38.0;
const pin_number_inset_right: f64 = 36.0;
const pin_number_baseline: f64 = 1.0;
const functional_group_gap: f64 = 16.0;
const functional_direct_lane_pad: f64 = 32.0;
const estimated_net_char_width: f64 = 7.0;
const horizontal_safety_pad: f64 = 16.0;
const default_terminal_reach: f64 = 158.0;
const non_spoke_terminal_reach: f64 = 178.0;
const passive_chain_base_reach: f64 = 78.0;
const branched_chain_base_reach: f64 = 83.0;
const passive_chain_pitch: f64 = 60.0;

/// Two groups on one functional signal are one island and take no gap — the
/// hub view's own rule, called rather than restated so the zoomed-in view can
/// never gap a board differently from the page it zooms into.
const groupsSharePassiveIsland = hub_mod.groupsSharePassiveAnchor;

fn gapAfterGroup(ctx: *const RenderCtx, groups: []const PinGroup, index: usize, default_gap: f64) f64 {
    if (default_gap == 0 or index + 1 >= groups.len) return 0;
    return if (groupsSharePassiveIsland(ctx, groups[index], groups[index + 1])) 0 else default_gap;
}

fn terminalLabelWidth(terminal: []const u8) f64 {
    if (isGroundNet(terminal)) return 18.0;
    return @as(f64, @floatFromInt(baseNetName(terminal).len)) * estimated_net_char_width;
}

fn maxBranchLength(branches: []const ctx_mod.Branch) usize {
    var longest: usize = 0;
    for (branches) |item| longest = @max(longest, item.chain.len);
    return longest;
}

/// Conservative horizontal reach from a hub edge through one connection to
/// the outside edge of its terminal text. This mirrors the fixed passive and
/// wire pitches in `branch.zig`; it lets a long three-part oscillator chain
/// enlarge the viewBox before any SVG primitives are emitted.
fn connectionOutset(ctx: *RenderCtx, hub_ref: []const u8, conn: AdjEntry) !f64 {
    const terminal = try connection.getConnTerminal(ctx, conn.endpoint, hub_ref, conn.pin);
    const label_width = terminalLabelWidth(terminal);
    const endpoint = switch (conn.endpoint) {
        .net => return default_terminal_reach + label_width,
        .pin => |pin| pin,
    };
    if (!ctx.spoke_set.contains(endpoint.ref_des)) return non_spoke_terminal_reach + label_width;

    var visited: std.StringHashMapUnmanaged(void) = .empty;
    defer visited.deinit(ctx.allocator);
    try visited.put(ctx.allocator, endpoint.ref_des, {});
    const chain = try connection.findSpokeChain(
        ctx,
        endpoint.ref_des,
        .{ .pin = .{ .ref_des = hub_ref, .pin = conn.pin } },
        &visited,
    );
    const main_count = 1 + chain.chain.len;
    var reach = @max(
        default_terminal_reach,
        passive_chain_base_reach + @as(f64, @floatFromInt(main_count)) * passive_chain_pitch,
    ) + label_width;
    const branch_count = maxBranchLength(chain.branches);
    if (branch_count > 0) {
        const total_count = main_count + branch_count;
        reach = @max(
            reach,
            branched_chain_base_reach + @as(f64, @floatFromInt(total_count)) * passive_chain_pitch + label_width,
        );
    }
    return reach;
}

fn requiredSidePad(ctx: *RenderCtx, hub_ref: []const u8, groups: []const PinGroup) !f64 {
    var required = default_side_pad;
    for (groups) |group| {
        for (group.conns) |conn| {
            required = @max(required, try connectionOutset(ctx, hub_ref, conn) + horizontal_safety_pad);
        }
    }
    return required;
}

/// Render a standalone `<svg>` showing `hub` with the supplied pin groups
/// drawn balanced left/right. Layout mirrors the main schematic's grouped hub
/// box (`render_html.renderHubSvg`), sharing `hub.splitGroupsByHeight` for the
/// column split. Returns without writing anything if `groups` is empty.
/// Parallel passives remain separate branches, including identical decoupling
/// capacitors tied between the same supply and ground rails.
pub fn renderHubAllPins(
    ctx: *RenderCtx,
    w: anytype,
    hub: FlatInst,
    groups: []const PinGroup,
    functional: bool,
) RenderError!void {
    if (groups.len == 0) return;

    const previous_functional_layout = ctx.render_scratch.functional_layout;
    ctx.render_scratch.functional_layout = functional;
    ctx.render_scratch.functional_left_pin_y.clearRetainingCapacity();
    ctx.render_scratch.functional_right_pin_y.clearRetainingCapacity();
    ctx.render_scratch.functional_inline_nets.clearRetainingCapacity();
    ctx.render_scratch.rendered_row_spans.clearRetainingCapacity();
    defer {
        ctx.render_scratch.functional_layout = previous_functional_layout;
        ctx.render_scratch.functional_left_pin_y.clearRetainingCapacity();
        ctx.render_scratch.functional_right_pin_y.clearRetainingCapacity();
        ctx.render_scratch.functional_inline_nets.clearRetainingCapacity();
        ctx.render_scratch.rendered_row_spans.clearRetainingCapacity();
    }

    const split = try hub_mod.splitGroupsByHeight(ctx, groups, hub.ref_des);
    const left_groups = split.left;
    const right_groups = split.right;
    const left_heights = split.left_heights;
    const right_heights = split.right_heights;
    const group_gap = if (functional) functional_group_gap else 0.0;

    var left_total: f64 = 0;
    for (left_heights, 0..) |h, i| left_total += h + gapAfterGroup(ctx, left_groups, i, group_gap);
    var right_total: f64 = 0;
    for (right_heights, 0..) |h, i| right_total += h + gapAfterGroup(ctx, right_groups, i, group_gap);
    const hub_height = @max(@max(left_total, right_total), hub_vpad) + hub_vpad;

    // Size each side independently from its longest passive chain and terminal
    // label. Long LMX2595 oscillator networks therefore stay inside the SVG
    // instead of losing the first character at x=0.
    const direct_lane_pad = if (functional) functional_direct_lane_pad else 0.0;
    const left_pad = try requiredSidePad(ctx, hub.ref_des, left_groups) + direct_lane_pad;
    const right_pad = try requiredSidePad(ctx, hub.ref_des, right_groups) + direct_lane_pad;
    const layout_hub_x = left_pad;
    const y_start: f64 = svg_top_margin;
    const svg_w: f64 = left_pad + hub_width + right_pad;
    const svg_h: f64 = hub_height + y_start + svg_bottom_pad;

    if (functional) {
        try rememberFunctionalPinRows(ctx, .{
            .hub_ref = hub.ref_des,
            .groups = left_groups,
            .heights = left_heights,
            .side = .left,
            .start_y = y_start + hub_vpad,
            .group_gap = group_gap,
            .stub_x = layout_hub_x - pin_stub,
        });
        try rememberFunctionalPinRows(ctx, .{
            .hub_ref = hub.ref_des,
            .groups = right_groups,
            .heights = right_heights,
            .side = .right,
            .start_y = y_start + hub_vpad,
            .group_gap = group_gap,
            .stub_x = layout_hub_x + hub_width + pin_stub,
        });
    }

    try w.print(
        \\<svg class="hub-inset" viewBox="0 0 {d:.0} {d:.0}" preserveAspectRatio="xMidYMid meet" xmlns="http://www.w3.org/2000/svg" data-ref="
    , .{ svg_w, svg_h });
    try escape.writeXml(w, hub.ref_des);
    try w.writeAll("\">\n");

    try w.writeAll("<g data-ref=\"");
    try escape.writeXml(w, hub.ref_des);
    try w.print(
        \\" class="component">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}"
        \\  fill="#16213e" stroke="#4a9eff" stroke-width="2" rx="6"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle"
        \\  font-size="12" font-weight="bold" fill="#4a9eff">
    , .{
        layout_hub_x,
        y_start,
        hub_width,
        hub_height,
        layout_hub_x + hub_width / half_divisor,
        y_start + hub_title_y,
    });
    try escape.writeXml(w, shortRef(hub.ref_des));
    try w.writeAll(" ");
    try escape.writeXml(w, displayValue(hub));
    try w.writeAll("</text></g>\n");

    var deferred_terminals: connection.DeferredTerminals = .{};

    var py_left: f64 = y_start + hub_vpad;
    for (left_groups, 0..) |group, gi| {
        const h = left_heights[gi];
        const cy = py_left + h / half_divisor;
        try renderPinStub(w, .left, layout_hub_x, cy, group, hub.ref_des);
        try connection.renderGroupedConnectionsDeferred(ctx, w, .{
            .hub_ref = hub.ref_des,
            .group = group,
            .stub_x = layout_hub_x - pin_stub,
            .py = cy,
            .side = .left,
        }, &deferred_terminals);
        py_left += h + gapAfterGroup(ctx, left_groups, gi, group_gap);
    }

    var py_right: f64 = y_start + hub_vpad;
    for (right_groups, 0..) |group, gi| {
        const h = right_heights[gi];
        const cy = py_right + h / half_divisor;
        try renderPinStub(w, .right, layout_hub_x + hub_width, cy, group, hub.ref_des);
        try connection.renderGroupedConnectionsDeferred(ctx, w, .{
            .hub_ref = hub.ref_des,
            .group = group,
            .stub_x = layout_hub_x + hub_width + pin_stub,
            .py = cy,
            .side = .right,
        }, &deferred_terminals);
        py_right += h + gapAfterGroup(ctx, right_groups, gi, group_gap);
    }

    try connection.renderDeferredTerminals(ctx, w, &deferred_terminals, functional);

    try w.writeAll("</svg>");
}

const FunctionalRowLayout = struct {
    hub_ref: []const u8,
    groups: []const PinGroup,
    heights: []const f64,
    side: ctx_mod.Side,
    start_y: f64,
    group_gap: f64,
    /// The side's pin-stub column (`renderPinStub`'s `stub_x`).
    stub_x: f64,
};

/// Record each group's row and stub span (the same spread `renderPinStub`
/// draws) so a series part on a neighbouring group can turn toward it and
/// close on its nearest pin stub.
fn rememberFunctionalPinRows(ctx: *RenderCtx, layout: FunctionalRowLayout) !void {
    var py = layout.start_y;
    for (layout.groups, 0..) |group, i| {
        const cy = py + layout.heights[i] / half_divisor;
        if (group.conns.len > 0) {
            const key = try std.fmt.allocPrint(ctx.allocator, "{s}.{s}", .{ layout.hub_ref, group.conns[0].pin });
            if (ctx.pin_canonical_nets.get(key)) |net| {
                const rows = switch (layout.side) {
                    .left => &ctx.render_scratch.functional_left_pin_y,
                    .right => &ctx.render_scratch.functional_right_pin_y,
                };
                const stubs = @as(f64, @floatFromInt(@max(group.stub_labels.len, 1) - 1));
                const half_span = stubs / half_divisor * per_conn_spacing;
                // `groupHeights`: base 40 plus one `per_conn_spacing` per extra row.
                const row_half_span = @max(layout.heights[i] - hub_vpad, 0) / half_divisor;
                try rows.put(ctx.allocator, baseNetName(net), .{
                    .cy = cy,
                    .first_stub_y = cy - half_span,
                    .last_stub_y = cy + half_span,
                    .stub_x = layout.stub_x,
                    .first_row_y = cy - row_half_span,
                    .last_row_y = cy + row_half_span,
                    .produces_rail = hub_mod.groupProducesRail(group),
                });
            }
        }
        py += layout.heights[i] + gapAfterGroup(ctx, layout.groups, i, layout.group_gap);
    }
}

/// Draw a hub pin group's stubs. Each pin renders as its own labeled stub —
/// the label is the component's pin function name (`IN_1`, `GND_2`, …) and a
/// small pin-number tag, mirroring the original single-stub layout. The stubs
/// are stacked across the group's vertical band `h` (centred on `py`) and tied
/// together with a vertical bus so it's obvious which pins share the net.
/// The net itself is labelled out at the wire's terminal by
/// `renderGroupedConnections`.
fn renderPinStub(w: anytype, side: ctx_mod.Side, px: f64, py: f64, group: PinGroup, hub_ref: []const u8) !void {
    const labels = group.stub_labels;
    const pin_lists = group.stub_pins;
    if (labels.len == 0) return;

    const displayed = labels.len;

    const stub_x = switch (side) {
        .left => px - pin_stub,
        .right => px + pin_stub,
    };
    // Spread the stubs across the band, one `per_conn_spacing` apart, centred
    // on `py`. The group height (set by groupHeights) is sized to hold them.
    const gap: f64 = per_conn_spacing;
    const first_y = py - @as(f64, @floatFromInt(displayed - 1)) / half_divisor * gap;

    for (labels, 0..) |label, i| {
        const pins = pin_lists[i];
        const y = first_y + @as(f64, @floatFromInt(i)) * gap;
        try renderOneStub(w, side, px, stub_x, y, label, pins, pins, hub_ref);
    }

    // Vertical bus tying every stub on this group to the same node, so it's
    // visible exactly which pins are connected together before the wire heads
    // out to the net.
    if (displayed > 1) {
        const last_y = first_y + @as(f64, @floatFromInt(displayed - 1)) * gap;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#6e7681" stroke-width="1.5"/>
            \\
        , .{ stub_x, first_y, stub_x, last_y });
    }
}

/// One pin stub: the short edge line, the function-name label inside the box,
/// and a small pin-number tag on the stub. `data_pin` is what the sidebar
/// matches on.
fn renderOneStub(
    w: anytype,
    side: ctx_mod.Side,
    px: f64,
    stub_x: f64,
    y: f64,
    label: []const u8,
    num_text: []const u8,
    data_pin: []const u8,
    hub_ref: []const u8,
) !void {
    try w.writeAll("<g class=\"pin-stub\" data-ref=\"");
    try escape.writeXml(w, hub_ref);
    try w.writeAll("\" data-pin=\"");
    try escape.writeXml(w, data_pin);
    try w.writeAll("\">\n");
    switch (side) {
        .left => {
            try w.print(
                \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#666" stroke-width="1.5"/>
                \\<text x="{d:.1}" y="{d:.1}" font-size="12" fill="#aaa">
            , .{
                stub_x, y,                    px,
                y,      px + pin_label_pad_x, y + pin_label_pad_y,
            });
            try escape.writeXml(w, label);
            try w.print(
                \\</text>
                \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="10" fill="#666">
            , .{ stub_x + pin_number_inset_left, y - pin_number_baseline });
            try escape.writeXml(w, num_text);
            try w.writeAll("</text>\n");
        },
        .right => {
            try w.print(
                \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#666" stroke-width="1.5"/>
                \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="12" fill="#aaa">
            , .{
                px, y,                    stub_x,
                y,  px - pin_label_pad_x, y + pin_label_pad_y,
            });
            try escape.writeXml(w, label);
            try w.print(
                \\</text>
                \\<text x="{d:.1}" y="{d:.1}" font-size="10" fill="#666">
            , .{ stub_x - pin_number_inset_right, y - pin_number_baseline });
            try escape.writeXml(w, num_text);
            try w.writeAll("</text>\n");
        },
    }
    try w.writeAll("</g>\n");
}

test "long passive chain expands side padding beyond the fixed minimum" {
    const testing = std.testing;
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "ic", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "C1", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res", .value = "100R", .footprint = "", .symbol = "" },
        .{ .ref_des = "C2", .component = "cap", .value = "100nF", .footprint = "", .symbol = "" },
    };
    const input = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const link_a = [_]env_mod.PinRef{ .{ .ref_des = "C1", .pin = "2" }, .{ .ref_des = "R1", .pin = "1" } };
    const link_b = [_]env_mod.PinRef{ .{ .ref_des = "R1", .pin = "2" }, .{ .ref_des = "C2", .pin = "1" } };
    const terminal = [_]env_mod.PinRef{.{ .ref_des = "C2", .pin = "2" }};
    const nets = [_]env_mod.Net{
        .{ .name = "OSCINP", .pins = &input },
        .{ .name = "LINK_A", .pins = &link_a },
        .{ .name = "LINK_B", .pins = &link_b },
        .{ .name = "LMX_OSCIN_N", .pins = &terminal },
    };
    const block: env_mod.DesignBlock = .{
        .name = "long-chain-padding",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var ctx = RenderCtx.init(arena.allocator());
    try ctx.setup(&block);
    const group = [_]PinGroup{.{
        .display_name = "OSCINP",
        .pin_numbers = "1",
        .stub_labels = &.{"OSCINP"},
        .conns = ctx.adjacency.get("U1").?.items,
    }};

    const pad = try requiredSidePad(&ctx, "U1", &group);
    try testing.expect(pad > default_side_pad);
}

// spec: render_svg - Pull-ups between neighbouring pin groups turn vertical on the bus column and run straight into the destination group's bus
test "functional pull-ups to a neighbouring group turn onto its pin stubs" {
    const testing = std.testing;
    // A sub-block's attenuator: C16 pulled up to the module-local filtered
    // rail VDD_F, the parallel bus pulled up to the same rail, a bypass cap,
    // and a bead to the board's shared V_3V3 (which U2 also sits on).
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "dat-31a-sp+", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "U2", .component = "ldo", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "U3", .component = "mcu", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "R2", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "C1", .component = "cap-0402", .value = "100nF", .footprint = "", .symbol = "generic-cap" },
        .{ .ref_des = "L1", .component = "ferrite-0402", .value = "600R", .footprint = "", .symbol = "generic-ind" },
    };
    const c16 = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "2" } };
    const vdd_f = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "6" },
        .{ .ref_des = "U1", .pin = "9" },
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "2" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "L1", .pin = "2" },
    };
    const par = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "15" },
        .{ .ref_des = "U1", .pin = "16" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    const gnd = [_]env_mod.PinRef{.{ .ref_des = "C1", .pin = "2" }};
    // Two other hubs on V_3V3: a rail with one hub pin would make that hub
    // the bead's owner and pull it off this schematic.
    const v3v3 = [_]env_mod.PinRef{
        .{ .ref_des = "L1", .pin = "1" },
        .{ .ref_des = "U2", .pin = "1" },
        .{ .ref_des = "U3", .pin = "1" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "dsa/PAR_C16", .pins = &c16 },
        .{ .name = "dsa/VDD_F", .pins = &vdd_f },
        .{ .name = "dsa/PAR_CTRL", .pins = &par },
        .{ .name = "GND", .pins = &gnd },
        .{ .name = "V_3V3", .pins = &v3v3 },
    };
    const block: env_mod.DesignBlock = .{
        .name = "neighbour-pull-ups",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = RenderCtx.init(a);
    try ctx.setup(&block);
    var pin_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    const pins = [_][]const u8{ "1", "6", "9", "15", "16" };
    const groups = try hub_mod.groupHubPinsFunctional(&ctx, &pins, ctx.adjacency.get("U1").?.items, &pin_names);
    try testing.expectEqual(@as(usize, 3), groups.len);

    var got: std.Io.Writer.Allocating = .init(a);
    try renderHubAllPins(&ctx, &got.writer, ctx.inst_map.get("U1").?, groups, true);
    const svg = got.written();

    // Pin 1 (y=80) is its own group: a short step from its stub end (312)
    // onto the bus column (302), R1 down that column, and a straight lane on
    // into the top of VDD's connection bus (its first row, y=156).
    try testing.expect(std.mem.indexOf(u8, svg, "x1=\"312.0\" y1=\"80.0\" x2=\"302.0\" y2=\"80.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "transform=\"rotate(90 302.0 100.0)\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "points=\"302.0,120.0 302.0,120.0 302.0,156.0 302.0,156.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "x1=\"302.0\" y1=\"156.0\" x2=\"302.0\" y2=\"236.0\"") != null);
    // The rail's rows: bypass, bead to the shared V_3V3 (labelled), and the
    // pull-up to the parallel bus LAST, nearest the bus's group below. R2
    // continues the bus straight down; the parallel-bus group drew no row of
    // its own, so the lane meets its first pin stub with the same short step.
    try testing.expect(std.mem.indexOf(u8, svg, "x1=\"302.0\" y1=\"236.0\" x2=\"312.0\" y2=\"236.0\"") == null);
    try testing.expect(std.mem.indexOf(u8, svg, "transform=\"rotate(90 302.0 256.0)\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "points=\"302.0,276.0 302.0,276.0 302.0,312.0 302.0,312.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "x1=\"302.0\" y1=\"312.0\" x2=\"312.0\" y2=\"312.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "x1=\"312.0\" y1=\"312.0\" x2=\"352.0\"") != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, svg, ">V_3V3</text>"));
    // Neither hub-private net earns a label, and nothing runs on the outside
    // lane (x=188) that used to cut through the V_3V3 label.
    try testing.expect(std.mem.indexOf(u8, svg, ">dsa/VDD_F</text>") == null);
    try testing.expect(std.mem.indexOf(u8, svg, ">dsa/PAR_CTRL</text>") == null);
    try testing.expect(std.mem.indexOf(u8, svg, "188.0,") == null);
}

// spec: render_svg - A return to a shared rail turns onto the pin group where this hub produces that rail
test "functional pull-ups to the hub's own output rail turn onto its pin stubs" {
    const testing = std.testing;
    // An LDO's power-good pull-up. V_5V is a SHARED rail — U2 sits on it too,
    // so it keeps a label — but pins 2/3 are this hub's OUTS/OUT, where the
    // rail is MADE, so the pull-up draws into the output node instead of
    // spending an outside lane. IN and GND balance the column split so PG and
    // the output group stay on one side, as they do on a real LDO.
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "lt3045edd#pbf", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "U2", .component = "mcu", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res-0402", .value = "100k", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "C1", .component = "cap-0402", .value = "10uF", .footprint = "", .symbol = "generic-cap" },
        .{ .ref_des = "C2", .component = "cap-0402", .value = "10uF", .footprint = "", .symbol = "generic-cap" },
    };
    const pg = [_]env_mod.PinRef{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const v_5v = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "R1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "U2", .pin = "1" },
    };
    const v_in = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "4" },
        .{ .ref_des = "C2", .pin = "1" },
        .{ .ref_des = "U2", .pin = "2" },
    };
    const gnd = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "5" },
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "PG_5V", .pins = &pg },
        .{ .name = "V_5V", .pins = &v_5v },
        .{ .name = "V_IN", .pins = &v_in },
        .{ .name = "GND", .pins = &gnd },
    };
    const block: env_mod.DesignBlock = .{
        .name = "own-rail-pull-up",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = RenderCtx.init(a);
    try ctx.setup(&block);
    var pin_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    try pin_names.put(a, "1", "PG");
    try pin_names.put(a, "2", "OUTS");
    try pin_names.put(a, "3", "OUT");
    try pin_names.put(a, "4", "IN");
    try pin_names.put(a, "5", "GND");
    const pins = [_][]const u8{ "1", "2", "3", "4", "5" };
    const groups = try hub_mod.groupHubPinsFunctional(&ctx, &pins, ctx.adjacency.get("U1").?.items, &pin_names);
    try testing.expectEqual(@as(usize, 4), groups.len);

    var got: std.Io.Writer.Allocating = .init(a);
    try renderHubAllPins(&ctx, &got.writer, ctx.inst_map.get("U1").?, groups, true);
    const svg = got.written();

    // PG (y=80) is the row above the OUTS/OUT group, so R1 stands on the
    // pin-stub column (x=312) and the lane runs from its far end straight down
    // to OUTS, the output group's first stub at y=136.
    // PG steps onto the bus column, R1 runs down it, and the lane continues
    // straight into the top of the OUT group's bus: its own V_5V row, which
    // is what names the rail — with a wire out to the label, not bare text.
    try testing.expect(std.mem.indexOf(u8, svg, "x1=\"312.0\" y1=\"80.0\" x2=\"302.0\" y2=\"80.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "transform=\"rotate(90 302.0 100.0)\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "points=\"302.0,120.0 302.0,120.0 302.0,136.0 302.0,136.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "x1=\"302.0\" y1=\"136.0\" x2=\"212.0\" y2=\"136.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "x=\"194.0\" y=\"140.0\" text-anchor=\"end\"") != null);
    // The rail is shared with U2, so it is named — once, beside the turned
    // part — and nothing runs on the outside lane at term_x - 24 any more.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, svg, ">V_5V</text>"));
    try testing.expect(std.mem.indexOf(u8, svg, "points=\"188.0,") == null);
}

// spec: render_svg - A feedback divider's upper leg turns onto the regulator's own output stub instead of an outside lane
test "functional feedback dividers turn their upper leg onto the output stubs" {
    const testing = std.testing;
    // A buck's feedback divider: R1 down to ground, R2 up to the buck's OWN
    // VOUT rail, which the rest of the board shares. EN, IN and GND balance
    // the column split, as they do on a real buck module.
    const instances = [_]env_mod.Instance{
        .{ .ref_des = "U1", .component = "tpsm84338rcjr", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "U2", .component = "mcu", .value = "", .footprint = "", .symbol = "" },
        .{ .ref_des = "R1", .component = "res-0402", .value = "10k", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "R2", .component = "res-0402", .value = "84.5k", .footprint = "", .symbol = "generic-res" },
        .{ .ref_des = "C1", .component = "cap-0402", .value = "22uF", .footprint = "", .symbol = "generic-cap" },
        .{ .ref_des = "C2", .component = "cap-0402", .value = "10uF", .footprint = "", .symbol = "generic-cap" },
    };
    const fb = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    const v_out = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "R2", .pin = "2" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "U2", .pin = "1" },
    };
    const v_in = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "C2", .pin = "1" },
        .{ .ref_des = "U2", .pin = "2" },
    };
    const gnd = [_]env_mod.PinRef{
        .{ .ref_des = "U1", .pin = "4" },
        .{ .ref_des = "R1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" },
    };
    const nets = [_]env_mod.Net{
        .{ .name = "BUCK_FB", .pins = &fb },
        .{ .name = "V_OUT", .pins = &v_out },
        .{ .name = "V_IN", .pins = &v_in },
        .{ .name = "GND", .pins = &gnd },
    };
    const block: env_mod.DesignBlock = .{
        .name = "feedback-divider",
        .instances = &instances,
        .nets = &nets,
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx = RenderCtx.init(a);
    try ctx.setup(&block);
    var pin_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    try pin_names.put(a, "1", "FB");
    try pin_names.put(a, "2", "VOUT");
    try pin_names.put(a, "3", "VIN");
    try pin_names.put(a, "4", "GND");
    const pins = [_][]const u8{ "1", "2", "3", "4" };
    const groups = try hub_mod.groupHubPinsFunctional(&ctx, &pins, ctx.adjacency.get("U1").?.items, &pin_names);
    try testing.expectEqual(@as(usize, 4), groups.len);

    var got: std.Io.Writer.Allocating = .init(a);
    try renderHubAllPins(&ctx, &got.writer, ctx.inst_map.get("U1").?, groups, true);
    const svg = got.written();

    // The FB group's rows are R1 to ground (y=80) then R2 to V_OUT (y=120):
    // a return heading below sits on the bottom edge, so R2 is the one that
    // turns, onto the column at x=312, and its lane lands on VOUT's stub.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, svg, "transform=\"rotate(90"));
    // R2 continues the FB bus straight down the bus column into the top of
    // the VOUT group's bus — its own labelled V_OUT row, wired out to the text.
    try testing.expect(std.mem.indexOf(u8, svg, "transform=\"rotate(90 302.0 140.0)\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "points=\"302.0,160.0 302.0,160.0 302.0,176.0 302.0,176.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "x1=\"302.0\" y1=\"176.0\" x2=\"212.0\" y2=\"176.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "x=\"194.0\" y=\"180.0\" text-anchor=\"end\"") != null);
    // One name for the shared rail, and no outside feedback-loop lane.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, svg, ">V_OUT</text>"));
    try testing.expect(std.mem.indexOf(u8, svg, "points=\"188.0,") == null);
}
