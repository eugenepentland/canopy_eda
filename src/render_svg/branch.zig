const std = @import("std");
const env_mod = @import("../eval/env.zig");
const ctx_mod = @import("context.zig");
const RenderCtx = ctx_mod.RenderCtx;
const FlatInst = ctx_mod.FlatInst;
const Branch = ctx_mod.Branch;
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

// ── Layout constants ──────────────────────────────────────────────
const HALF_DIVISOR: f64 = 2.0;
const BRANCH_BUS_GAP: f64 = 10.0;
const TERMINAL_GAP: f64 = 20.0;
const FAR_X_SENTINEL: f64 = 99999.0;
const TERMINAL_INSET: f64 = 15.0;
const LABEL_BASELINE: f64 = 4.0;
const HUB_TITLE_Y: f64 = 18.0;
const ICON_OFF_Y: f64 = 8.0;
const PORT_BLOCK_PAD: f64 = 40.0;
const PORT_SPACING: f64 = 40.0;
const PORT_LABEL_PAD: f64 = 8.0;
const RATING_LINE_OFFSET: f64 = 16.0;
const PASSIVE_LABEL_PAD: f64 = 6.0;
const PASSIVE_LABEL_OFFSET_Y: f64 = 14.0;
const PASSIVE_HIT_PAD_H: f64 = 18.0;
const PASSIVE_VALUE_OFFSET: f64 = 4.0;

/// Render the left-side branch tree off a hub pin: a vertical bus with
/// horizontal stubs feeding each passive chain, then per-chain terminals.
/// Used when one hub pin fans out to several spoke chains (e.g. a power
/// rail decoupled by multiple caps in series).
pub fn drawBranchTreeLeft(self: *RenderCtx, w: anytype, junction_x: f64, center_y: f64, branches: []const Branch, junction_net: []const u8) RenderError!void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const start_y = center_y - total_height / HALF_DIVISOR;

    const bx = junction_x - bus_gap;
    try drawNetWire(w, junction_x, center_y, bx, center_y, junction_net);
    if (n > 1) {
        const end_y = start_y + total_height;
        try drawNetWire(w, bx, start_y, bx, end_y, junction_net);
    }

    var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try drawNetWire(w, bx, by, bx - BRANCH_BUS_GAP, by, junction_net);
        const chain_end_x = try drawPassiveChainLeft(self, w, bx - BRANCH_BUS_GAP, by, branch.chain);
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
    const start_y = center_y - total_height / HALF_DIVISOR;

    const bx = junction_x + bus_gap;
    try drawNetWire(w, junction_x, center_y, bx, center_y, junction_net);
    if (n > 1) {
        const end_y = start_y + total_height;
        try drawNetWire(w, bx, start_y, bx, end_y, junction_net);
    }

    var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try drawNetWire(w, bx, by, bx + BRANCH_BUS_GAP, by, junction_net);
        const chain_end_x = try drawPassiveChainRight(self, w, bx + BRANCH_BUS_GAP, by, branch.chain);
        try bodies.append(self.allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    try renderBranchTerminalsRight(self, w, bodies.items);
}

fn renderBranchTerminalsLeft(self: *RenderCtx, w: anytype, bodies: []const BranchBody) !void {
    if (bodies.len == 0) return;
    var term_x: f64 = 0;
    for (bodies) |b| {
        const tx = b.end_x - TERMINAL_GAP;
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
            var bx: f64 = FAR_X_SENTINEL;
            for (group) |b| bx = @min(bx, b.end_x - TERMINAL_INSET);
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
        const tx = b.end_x + TERMINAL_GAP;
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
            var bx: f64 = -FAR_X_SENTINEL;
            for (group) |b| bx = @max(bx, b.end_x + TERMINAL_INSET);
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
        try w.print(
            \\<g class="net" data-net="{s}" style="cursor:pointer">
            \\
        , .{display});
        try drawGndSymbol(w, end_x, cy);
        try w.writeAll("</g>\n");
    } else {
        const color: []const u8 = if (self.port_nets.contains(term) or self.port_nets.contains(display)) "#4a9eff" else "#e8c547";
        const label_x: f64 = if (std.mem.eql(u8, anchor, "end")) end_x - net_label_gap else end_x + net_label_gap;
        try w.print(
            \\<g class="net" data-net="{s}" style="cursor:pointer">
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="{s}" font-size="11" font-weight="bold" fill="{s}">{s}</text>
            \\</g>
            \\
        , .{ display, label_x, cy + LABEL_BASELINE, anchor, color, display });
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
            try drawWire(w, x, cy, x - TERMINAL_GAP, cy);
            x -= TERMINAL_GAP;
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
            try drawWire(w, x, cy, x + TERMINAL_GAP, cy);
            x += TERMINAL_GAP;
        }
        try drawPassiveRight(w, inst, x, cy);
        x += passive_bw;
    }
    return x;
}

fn drawPassiveLeft(w: anytype, inst: FlatInst, x: f64, cy: f64) !void {
    const bx = x - passive_bw;
    const by = cy - passive_bh / HALF_DIVISOR;
    const cx = bx + passive_bw / HALF_DIVISOR;
    const pad: f64 = PASSIVE_LABEL_PAD;

    try w.print(
        \\<g data-ref="{s}" class="component" style="cursor:pointer">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
        \\
    , .{
        shortRef(inst.ref_des),
        bx - pad,
        by - PASSIVE_LABEL_OFFSET_Y,
        passive_bw + pad * HALF_DIVISOR,
        passive_bh + PASSIVE_HIT_PAD_H,
    });

    try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="#888">{s} {s}</text>
        \\</g>
        \\
    , .{ cx, by - PASSIVE_VALUE_OFFSET, shortRef(inst.ref_des), formatShort(inst) });

    try writeDebugPin(w, bx, cy);
    try writeDebugPin(w, bx + passive_bw, cy);
}

fn drawPassiveRight(w: anytype, inst: FlatInst, x: f64, cy: f64) !void {
    const bx = x;
    const by = cy - passive_bh / HALF_DIVISOR;
    const cx = bx + passive_bw / HALF_DIVISOR;
    const pad: f64 = PASSIVE_LABEL_PAD;

    try w.print(
        \\<g data-ref="{s}" class="component" style="cursor:pointer">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
        \\
    , .{
        shortRef(inst.ref_des),
        bx - pad,
        by - PASSIVE_LABEL_OFFSET_Y,
        passive_bw + pad * HALF_DIVISOR,
        passive_bh + PASSIVE_HIT_PAD_H,
    });

    try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="#888">{s} {s}</text>
        \\</g>
        \\
    , .{ cx, by - PASSIVE_VALUE_OFFSET, shortRef(inst.ref_des), formatShort(inst) });

    try writeDebugPin(w, bx, cy);
    try writeDebugPin(w, bx + passive_bw, cy);
}
