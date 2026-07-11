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

/// Render the left-side branch tree off a hub pin: a vertical bus with
/// horizontal stubs feeding each passive chain, then per-chain terminals.
/// Used when one hub pin fans out to several spoke chains (e.g. a power
/// rail decoupled by multiple caps in series).
pub fn drawBranchTreeLeft(self: *RenderCtx, w: anytype, junction_x: f64, center_y: f64, branches: []const Branch, junction_net: []const u8) RenderError!void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const start_y = center_y - total_height / half_divisor;

    const bx = junction_x - bus_gap;
    try drawNetWire(w, junction_x, center_y, bx, center_y, junction_net);
    if (n > 1) {
        const end_y = start_y + total_height;
        try drawNetWire(w, bx, start_y, bx, end_y, junction_net);
    }

    var bodies: std.ArrayList(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try drawNetWire(w, bx, by, bx - branch_bus_gap, by, junction_net);
        const chain_end_x = try drawPassiveChainLeft(self, w, bx - branch_bus_gap, by, branch.chain);
        try bodies.append(self.allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    try renderBranchTerminalsLeft(self, w, bodies.items);
}

/// Mirror of `drawBranchTreeLeft` for the right side of a hub. Wires the
/// junction net out to a vertical bus, then walks each branch's passive
/// chain rightward to its terminal label or symbol.
pub fn drawBranchTreeRight(self: *RenderCtx, w: anytype, junction_x: f64, center_y: f64, branches: []const Branch, junction_net: []const u8) RenderError!void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const start_y = center_y - total_height / half_divisor;

    const bx = junction_x + bus_gap;
    try drawNetWire(w, junction_x, center_y, bx, center_y, junction_net);
    if (n > 1) {
        const end_y = start_y + total_height;
        try drawNetWire(w, bx, start_y, bx, end_y, junction_net);
    }

    var bodies: std.ArrayList(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try drawNetWire(w, bx, by, bx + branch_bus_gap, by, junction_net);
        const chain_end_x = try drawPassiveChainRight(self, w, bx + branch_bus_gap, by, branch.chain);
        try bodies.append(self.allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    try renderBranchTerminalsRight(self, w, bodies.items);
}

fn renderBranchTerminalsLeft(self: *RenderCtx, w: anytype, bodies: []const BranchBody) !void {
    if (bodies.len == 0) return;
    var term_x: f64 = 0;
    for (bodies) |b| {
        const tx = b.end_x - terminal_gap;
        if (term_x == 0 or tx < term_x) term_x = tx;
    }

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
    var term_x: f64 = 0;
    for (bodies) |b| {
        const tx = b.end_x + terminal_gap;
        if (term_x == 0 or tx > term_x) term_x = tx;
    }

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
        const color: []const u8 = if (self.port_nets.contains(term) or self.port_nets.contains(display)) "#4a9eff" else "#e8c547";
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
        \\" class="component" style="cursor:pointer">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
        \\
    , .{
        bx - pad,
        by - passive_label_offset_y,
        passive_bw + pad * half_divisor,
        passive_bh + passive_hit_pad_h,
    });

    try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="#888">
    , .{ cx, by - passive_value_offset });
    try escape.writeXml(w, shortRef(inst.ref_des));
    try w.writeAll(" ");
    try escape.writeXml(w, formatShort(inst));
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
        \\" class="component" style="cursor:pointer">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
        \\
    , .{
        bx - pad,
        by - passive_label_offset_y,
        passive_bw + pad * half_divisor,
        passive_bh + passive_hit_pad_h,
    });

    try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="#888">
    , .{ cx, by - passive_value_offset });
    try escape.writeXml(w, shortRef(inst.ref_des));
    try w.writeAll(" ");
    try escape.writeXml(w, formatShort(inst));
    try w.writeAll(text_g_close);

    try writeDebugPin(w, bx, cy);
    try writeDebugPin(w, bx + passive_bw, cy);
}
