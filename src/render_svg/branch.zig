//! Spoke-side SVG drawing: renders the branch tree hanging off a hub pin — the
//! recursive left/right junction fan-out, terminal symbols (GND/NC/net label),
//! and inline passive chains (series R/C/L drawn on the wire). Pure geometry
//! emission onto the render context's writer.

const std = @import("std");
const env_mod = @import("../eval/env.zig");
const ctx_mod = @import("context.zig");
const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const Branch = ctx_mod.Branch;

/// Closing tags for a passive-branch `<text>` label inside its `<g>` group.
const text_g_close = "</text>\n</g>\n";
const BranchBody = ctx_mod.BranchBody;
const draw = @import("draw.zig");
const hub_width = draw.hub_width;
const hub_x = draw.hub_x;
const pin_stub = draw.pin_stub;
const net_label_gap = draw.net_label_gap;
const passive_bw = draw.passive_bw;
const passive_bh = draw.passive_bh;
const branch_spacing = draw.branch_spacing;
const bus_gap = draw.bus_gap;
const isGroundNet = draw.isGroundNet;
const baseNetName = draw.baseNetName;
const shortRef = draw.shortRef;
const formatShort = draw.formatShort;
const drawWire = draw.drawWire;
const drawNetWire = draw.drawNetWire;
const drawSymbolShape = draw.drawSymbolShape;
const drawGndSymbol = draw.drawGndSymbol;
const drawBlockIcon = draw.drawBlockIcon;
const writeDebugPin = draw.writeDebugPin;
const RenderError = draw.RenderError;
const escape = @import("../escape.zig");

// ── Layout constants ──────────────────────────────────────────────
const half_divisor: f64 = 2.0;
const branch_bus_gap: f64 = 10.0;
const terminal_gap: f64 = 20.0;
const far_x_sentinel: f64 = 99999.0;
const terminal_inset: f64 = 15.0;
const label_baseline: f64 = 4.0;
const hub_title_y: f64 = 18.0;
const icon_off_y: f64 = 8.0;
const port_block_pad: f64 = 40.0;
const port_spacing: f64 = 40.0;
const port_label_pad: f64 = 8.0;
const rating_line_offset: f64 = 16.0;
const passive_label_pad: f64 = 6.0;
const passive_label_offset_y: f64 = 14.0;
const passive_hit_pad_h: f64 = 18.0;
const passive_value_offset: f64 = 4.0;

/// Functional direct-return branches can align one horizontal series resistor
/// with the outside lane, but that lane is only known after every hub row has
/// rendered. Hold just that resistor back; Sequential and all other branch
/// shapes continue through the ordinary immediate renderer.
fn deferredSeriesInst(
    self: *RenderCtx,
    branch: Branch,
    by: f64,
    index: usize,
    branch_count: usize,
    side: ctx_mod.Side,
) ?FlatInst {
    if (!self.render_scratch.functional_layout or !self.render_scratch.defer_branch_terminals) return null;
    if (branch.chain.len != 1 or !std.mem.eql(u8, branch.chain[0].symbol, "generic-res")) return null;
    const target_y = switch (side) {
        .left => self.render_scratch.functional_left_pin_y.get(baseNetName(branch.terminal)),
        .right => self.render_scratch.functional_right_pin_y.get(baseNetName(branch.terminal)),
    } orelse return null;
    if (target_y > by and index + 1 == branch_count) return branch.chain[0];
    if (target_y < by and index == 0) return branch.chain[0];
    return null;
}

/// A resistor bridging two external signal ports is a differential termination,
/// not another inline element. Hold it for the hub-level pass so Functional can
/// turn it vertically between the two port rows while leaving both port stubs
/// visible. The Sequential view deliberately keeps the topology walk unchanged.
fn deferredBoundaryTermination(
    self: *RenderCtx,
    junction_net: []const u8,
    branch: Branch,
) ?FlatInst {
    if (!self.render_scratch.functional_layout or !self.render_scratch.defer_branch_terminals) return null;
    if (!self.rendersWhenAlone(junction_net) or !self.rendersWhenAlone(branch.terminal)) return null;
    if (branch.chain.len != 1 or !std.mem.eql(u8, branch.chain[0].symbol, "generic-res")) return null;
    return branch.chain[0];
}

fn functionalPinY(self: *const RenderCtx, side: ctx_mod.Side, net: []const u8) ?f64 {
    return switch (side) {
        .left => self.render_scratch.functional_left_pin_y.get(baseNetName(net)),
        .right => self.render_scratch.functional_right_pin_y.get(baseNetName(net)),
    };
}

/// A passive-only island can join two hub pins through separate spokes. When
/// both rows are visible on one side, center the island's branch tree between
/// them and let the hub-level direct rail provide the junction connection.
fn sharedIslandCenterY(self: *RenderCtx, junction_net: []const u8, side: ctx_mod.Side) ?f64 {
    if (!self.render_scratch.functional_layout) return null;
    const pins = self.net_index.get(baseNetName(junction_net)) orelse return null;

    var first_y = far_x_sentinel;
    var last_y = -far_x_sentinel;
    for (pins.items) |island_pin| {
        if (!self.spoke_set.contains(island_pin.ref_des)) continue;
        const adj = self.adjacency.get(island_pin.ref_des) orelse continue;
        for (adj.items) |entry| switch (entry.endpoint) {
            .pin => |pin| {
                if (self.spoke_set.contains(pin.ref_des)) continue;
                const key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ pin.ref_des, pin.pin }) catch continue;
                const hub_net = self.pin_canonical_nets.get(key) orelse continue;
                const hub_y = functionalPinY(self, side, hub_net) orelse continue;
                first_y = @min(first_y, hub_y);
                last_y = @max(last_y, hub_y);
            },
            .net => {},
        };
    }
    if (first_y == far_x_sentinel or first_y == last_y) return null;
    return (first_y + last_y) / half_divisor;
}

test "functional boundary resistor waits for vertical differential layout" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = RenderCtx.init(allocator);
    ctx.render_scratch.functional_layout = true;
    ctx.render_scratch.defer_branch_terminals = true;
    try ctx.lone_pin_nets.put(allocator, "REF_P", .internal);
    try ctx.lone_pin_nets.put(allocator, "REF_N", .internal);

    const resistor: FlatInst = .{
        .ref_des = "R2",
        .component = "res-0402",
        .value = "100R",
        .symbol = "generic-res",
    };
    const branch: Branch = .{ .chain = &.{resistor}, .terminal = "REF_N" };
    try testing.expectEqualStrings("R2", deferredBoundaryTermination(&ctx, "REF_P", branch).?.ref_des);
    ctx.render_scratch.functional_layout = false;
    try testing.expect(deferredBoundaryTermination(&ctx, "REF_P", branch) == null);
}

/// Render the left-side branch tree off a hub pin: a vertical bus with
/// horizontal stubs feeding each passive chain, then per-chain terminals.
/// Used when one hub pin fans out to several spoke chains (e.g. a power
/// rail decoupled by multiple caps in series).
pub fn drawBranchTreeLeft(self: *RenderCtx, w: anytype, junction_x: f64, center_y: f64, branches: []const Branch, junction_net: []const u8) RenderError!void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const owns_port_row = junctionOwnsPortRow(self, junction_net, branches);
    const start_y = if (owns_port_row)
        center_y + branch_spacing
    else
        center_y - total_height / half_divisor;

    const bx = junction_x - bus_gap;
    try drawNetWire(w, junction_x, center_y, bx, center_y, junction_net);
    if (n > 1 or owns_port_row) {
        const end_y = start_y + total_height;
        try drawNetWire(w, bx, if (owns_port_row) center_y else start_y, bx, end_y, junction_net);
    }

    var bodies: std.ArrayList(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        const chain_start_x = bx - branch_bus_gap;
        try drawNetWire(w, bx, by, chain_start_x, by, junction_net);
        if (deferredBoundaryTermination(self, junction_net, branch) orelse
            deferredSeriesInst(self, branch, by, idx, n, .left)) |inst|
        {
            try bodies.append(self.allocator, .{
                .end_x = chain_start_x - passive_bw,
                .cy = by,
                .terminal = branch.terminal,
                .deferred_series = inst,
                .deferred_start_x = chain_start_x,
                .deferred_source_net = junction_net,
            });
        } else {
            const chain_end_x = try drawPassiveChainLeft(self, w, chain_start_x, by, branch.chain);
            try bodies.append(self.allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
        }
    }

    if (self.render_scratch.defer_branch_terminals) {
        try self.render_scratch.deferred_branch_terminals.appendSlice(self.allocator, bodies.items);
        return;
    }
    try renderBranchTerminalsLeft(self, w, bodies.items);
}

/// Mirror of `drawBranchTreeLeft` for the right side of a hub. Wires the
/// junction net out to a vertical bus, then walks each branch's passive
/// chain rightward to its terminal label or symbol.
pub fn drawBranchTreeRight(self: *RenderCtx, w: anytype, junction_x: f64, center_y: f64, branches: []const Branch, junction_net: []const u8) RenderError!void {
    const shared_center_y = sharedIslandCenterY(self, junction_net, .right);
    const tree_center_y = shared_center_y orelse center_y;
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const owns_port_row = shared_center_y == null and junctionOwnsPortRow(self, junction_net, branches);
    const start_y = if (owns_port_row)
        tree_center_y + branch_spacing
    else
        tree_center_y - total_height / half_divisor;

    const bx = junction_x + bus_gap;
    if (shared_center_y == null) try drawNetWire(w, junction_x, tree_center_y, bx, tree_center_y, junction_net);
    if (n > 1 or owns_port_row) {
        const end_y = start_y + total_height;
        try drawNetWire(w, bx, if (owns_port_row) tree_center_y else start_y, bx, end_y, junction_net);
    }

    var bodies: std.ArrayList(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        const chain_start_x = bx + branch_bus_gap;
        try drawNetWire(w, bx, by, chain_start_x, by, junction_net);
        if (deferredBoundaryTermination(self, junction_net, branch) orelse
            deferredSeriesInst(self, branch, by, idx, n, .right)) |inst|
        {
            try bodies.append(self.allocator, .{
                .end_x = chain_start_x + passive_bw,
                .cy = by,
                .terminal = branch.terminal,
                .deferred_series = inst,
                .deferred_start_x = chain_start_x,
                .deferred_source_net = junction_net,
            });
        } else {
            const chain_end_x = try drawPassiveChainRight(self, w, chain_start_x, by, branch.chain);
            try bodies.append(self.allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
        }
    }

    if (self.render_scratch.defer_branch_terminals) {
        try self.render_scratch.deferred_branch_terminals.appendSlice(self.allocator, bodies.items);
        return;
    }
    try renderBranchTerminalsRight(self, w, bodies.items);
}

/// A boundary signal with a local ground shunt needs two visible rows: one for
/// the off-sheet label and one for the shunt. Sharing the row paints the label
/// across the capacitor and makes the signal look grounded.
fn junctionOwnsPortRow(self: *const RenderCtx, junction_net: []const u8, branches: []const Branch) bool {
    if (!self.render_scratch.functional_layout or !self.rendersWhenAlone(baseNetName(junction_net))) return false;
    for (branches) |branch| {
        if (isGroundNet(baseNetName(branch.terminal))) return true;
    }
    return false;
}

fn branchTerminalXLeft(bodies: []const BranchBody) f64 {
    var term_x: f64 = 0;
    for (bodies) |body| {
        const candidate = body.end_x - terminal_gap;
        if (term_x == 0 or candidate < term_x) term_x = candidate;
    }
    return term_x;
}

fn branchTerminalXRight(bodies: []const BranchBody) f64 {
    var term_x: f64 = 0;
    for (bodies) |body| {
        const candidate = body.end_x + terminal_gap;
        if (term_x == 0 or candidate > term_x) term_x = candidate;
    }
    return term_x;
}

fn renderBranchTerminalsLeft(self: *RenderCtx, w: anytype, bodies: []const BranchBody) !void {
    if (bodies.len == 0) return;
    const term_x = branchTerminalXLeft(bodies);

    var i: usize = 0;
    while (i < bodies.len) {
        const term = bodies[i].terminal;
        var j = i + 1;
        while (j < bodies.len) : (j += 1) {
            if (!std.mem.eql(u8, bodies[j].terminal, term)) break;
        }
        const group = bodies[i..j];

        if (group.len == 1) {
            try drawNetWire(w, group[0].end_x, group[0].cy, term_x, group[0].cy, term);
            try drawTerminal(self, w, term_x, group[0].cy, term, "end");
        } else {
            var bx: f64 = far_x_sentinel;
            for (group) |b| bx = @min(bx, b.end_x - terminal_inset);
            for (group) |b| try drawNetWire(w, b.end_x, b.cy, bx, b.cy, term);
            try drawNetWire(w, bx, group[0].cy, bx, group[group.len - 1].cy, term);
            try drawNetWire(w, bx, group[group.len - 1].cy, term_x, group[group.len - 1].cy, term);
            try drawTerminal(self, w, term_x, group[group.len - 1].cy, term, "end");
        }

        i = j;
    }
}

fn renderBranchTerminalsRight(self: *RenderCtx, w: anytype, bodies: []const BranchBody) !void {
    if (bodies.len == 0) return;
    const term_x = branchTerminalXRight(bodies);

    var i: usize = 0;
    while (i < bodies.len) {
        const term = bodies[i].terminal;
        var j = i + 1;
        while (j < bodies.len) : (j += 1) {
            if (!std.mem.eql(u8, bodies[j].terminal, term)) break;
        }
        const group = bodies[i..j];

        if (group.len == 1) {
            try drawNetWire(w, group[0].end_x, group[0].cy, term_x, group[0].cy, term);
            try drawTerminal(self, w, term_x, group[0].cy, term, "start");
        } else {
            var bx: f64 = -far_x_sentinel;
            for (group) |b| bx = @max(bx, b.end_x + terminal_inset);
            for (group) |b| try drawNetWire(w, b.end_x, b.cy, bx, b.cy, term);
            try drawNetWire(w, bx, group[0].cy, bx, group[group.len - 1].cy, term);
            try drawNetWire(w, bx, group[group.len - 1].cy, term_x, group[group.len - 1].cy, term);
            try drawTerminal(self, w, term_x, group[group.len - 1].cy, term, "start");
        }

        i = j;
    }
}

/// Draw a terminal label or symbol (GND/NC/net label).
pub fn drawTerminal(self: *RenderCtx, w: anytype, end_x: f64, cy: f64, term: []const u8, anchor: []const u8) RenderError!void {
    const display = draw.baseNetName(term);
    if (isGroundNet(display)) {
        try w.writeAll("<g class=\"net\" data-net=\"");
        try escape.writeXml(w, display);
        try w.writeAll("\" style=\"cursor:pointer\">\n");
        try drawGndSymbol(w, end_x, cy);
        try w.writeAll("</g>\n");
    } else {
        const color: []const u8 = if (self.isBoundaryPort(term) or self.isBoundaryPort(display)) "#4a9eff" else "#e8c547";
        const label_x: f64 = if (std.mem.eql(u8, anchor, "end")) end_x - net_label_gap else end_x + net_label_gap;
        try w.writeAll("<g class=\"net\" data-net=\"");
        try escape.writeXml(w, display);
        try w.print(
            \\" style="cursor:pointer">
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="{s}" font-size="11" font-weight="bold" fill="{s}">
        , .{ label_x, cy + label_baseline, anchor, color });
        try escape.writeXml(w, display);
        try w.writeAll(text_g_close);
    }
    try writeDebugPin(w, end_x, cy);
}

// Regression: hub-level routing must include terminals nested inside passive branch trees.
test "branch tree terminals can be deferred for hub-level routing" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ctx = RenderCtx.init(allocator);
    ctx.render_scratch.defer_branch_terminals = true;

    const branches = [_]Branch{
        .{ .chain = &.{}, .terminal = "GND" },
        .{ .chain = &.{}, .terminal = "LMX_RFOUTBP" },
    };
    var got: std.Io.Writer.Allocating = .init(allocator);
    try drawBranchTreeRight(&ctx, &got.writer, 100.0, 80.0, &branches, "LO_BIAS_B");

    try testing.expectEqual(@as(usize, 2), ctx.render_scratch.deferred_branch_terminals.items.len);
    try testing.expectEqualStrings("LMX_RFOUTBP", ctx.render_scratch.deferred_branch_terminals.items[1].terminal);
    try testing.expect(std.mem.indexOf(u8, got.written(), ">LMX_RFOUTBP</text>") == null);
}

// ── Passive chain drawing ─────────────────────────────────────────────

/// Lay out a horizontal series chain of passive spokes leftward from
/// `start_x`, drawing wire segments between each pair and returning the
/// final x of the chain so the caller can attach a terminal symbol.
pub fn drawPassiveChainLeft(_: *RenderCtx, w: anytype, start_x: f64, cy: f64, spokes: []const FlatInst) RenderError!f64 {
    if (spokes.len == 0) return start_x;
    var x = start_x;
    for (spokes, 0..) |inst, i| {
        if (i > 0) {
            try drawWire(w, x, cy, x - terminal_gap, cy);
            x -= terminal_gap;
        }
        try drawPassiveLeft(w, inst, x, cy);
        x -= passive_bw;
    }
    return x;
}

/// Right-hand mirror of `drawPassiveChainLeft`. Walks the spoke list left
/// to right, drawing each passive box in series, and returns the final x
/// past the last passive's right edge.
pub fn drawPassiveChainRight(_: *RenderCtx, w: anytype, start_x: f64, cy: f64, spokes: []const FlatInst) RenderError!f64 {
    if (spokes.len == 0) return start_x;
    var x = start_x;
    for (spokes, 0..) |inst, i| {
        if (i > 0) {
            try drawWire(w, x, cy, x + terminal_gap, cy);
            x += terminal_gap;
        }
        try drawPassiveRight(w, inst, x, cy);
        x += passive_bw;
    }
    return x;
}

fn drawPassiveLeft(w: anytype, inst: FlatInst, x: f64, cy: f64) !void {
    const bx = x - passive_bw;
    const by = cy - passive_bh / half_divisor;
    const cx = bx + passive_bw / half_divisor;
    const pad: f64 = passive_label_pad;

    try w.writeAll("<g data-ref=\"");
    try escape.writeXml(w, shortRef(inst.ref_des));
    try w.print(
        \\" data-passive-count="{d}" class="component" style="cursor:pointer">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
        \\
    , .{
        1,
        bx - pad,
        by - passive_label_offset_y,
        passive_bw + pad * half_divisor,
        passive_bh + passive_hit_pad_h,
    });

    try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="{s}"{s}>
    , .{ cx, by - passive_value_offset, if (inst.flags.dnp) "#ff6b6b" else "#888", if (inst.flags.dnp) " font-weight=\"bold\"" else "" });
    try escape.writeXml(w, shortRef(inst.ref_des));
    try w.writeAll(" ");
    try escape.writeXml(w, formatShort(inst));
    if (inst.flags.dnp) try w.writeAll(" DNP");
    try w.writeAll(text_g_close);

    try writeDebugPin(w, bx, cy);
    try writeDebugPin(w, bx + passive_bw, cy);
}

fn drawPassiveRight(w: anytype, inst: FlatInst, x: f64, cy: f64) !void {
    const bx = x;
    const by = cy - passive_bh / half_divisor;
    const cx = bx + passive_bw / half_divisor;
    const pad: f64 = passive_label_pad;

    try w.writeAll("<g data-ref=\"");
    try escape.writeXml(w, shortRef(inst.ref_des));
    try w.print(
        \\" data-passive-count="{d}" class="component" style="cursor:pointer">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
        \\
    , .{
        1,
        bx - pad,
        by - passive_label_offset_y,
        passive_bw + pad * half_divisor,
        passive_bh + passive_hit_pad_h,
    });

    try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="{s}"{s}>
    , .{ cx, by - passive_value_offset, if (inst.flags.dnp) "#ff6b6b" else "#888", if (inst.flags.dnp) " font-weight=\"bold\"" else "" });
    try escape.writeXml(w, shortRef(inst.ref_des));
    try w.writeAll(" ");
    try escape.writeXml(w, formatShort(inst));
    if (inst.flags.dnp) try w.writeAll(" DNP");
    try w.writeAll(text_g_close);

    try writeDebugPin(w, bx, cy);
    try writeDebugPin(w, bx + passive_bw, cy);
}
