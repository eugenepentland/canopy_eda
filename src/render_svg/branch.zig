const std = @import("std");
const env_mod = @import("../eval/env.zig");
const Port = env_mod.Port;
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
const classifyComponent = draw.classifyComponent;

pub fn drawBranchTreeLeft(self: *RenderCtx, w: anytype, junction_x: f64, center_y: f64, branches: []const Branch, junction_net: []const u8) !void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const start_y = center_y - total_height / 2.0;

    const bx = junction_x - bus_gap;
    try drawNetWire(w, junction_x, center_y, bx, center_y, junction_net);
    if (n > 1) {
        const end_y = start_y + total_height;
        try drawNetWire(w, bx, start_y, bx, end_y, junction_net);
    }

    var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try drawNetWire(w, bx, by, bx - 10.0, by, junction_net);
        const chain_end_x = try drawPassiveChainLeft(self, w, bx - 10.0, by, branch.chain);
        try bodies.append(self.allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    try renderBranchTerminalsLeft(self, w, bodies.items);
}

pub fn drawBranchTreeRight(self: *RenderCtx, w: anytype, junction_x: f64, center_y: f64, branches: []const Branch, junction_net: []const u8) !void {
    const n = branches.len;
    const total_height = @as(f64, @floatFromInt(n -| 1)) * branch_spacing;
    const start_y = center_y - total_height / 2.0;

    const bx = junction_x + bus_gap;
    try drawNetWire(w, junction_x, center_y, bx, center_y, junction_net);
    if (n > 1) {
        const end_y = start_y + total_height;
        try drawNetWire(w, bx, start_y, bx, end_y, junction_net);
    }

    var bodies: std.ArrayListUnmanaged(BranchBody) = .empty;

    for (branches, 0..) |branch, idx| {
        const by = start_y + @as(f64, @floatFromInt(idx)) * branch_spacing;
        try drawNetWire(w, bx, by, bx + 10.0, by, junction_net);
        const chain_end_x = try drawPassiveChainRight(self, w, bx + 10.0, by, branch.chain);
        try bodies.append(self.allocator, .{ .end_x = chain_end_x, .cy = by, .terminal = branch.terminal });
    }

    try renderBranchTerminalsRight(self, w, bodies.items);
}

fn renderBranchTerminalsLeft(self: *RenderCtx, w: anytype, bodies: []const BranchBody) !void {
    if (bodies.len == 0) return;
    var term_x: f64 = 0;
    for (bodies) |b| {
        const tx = b.end_x - 20.0;
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
            var bx: f64 = 99999.0;
            for (group) |b| bx = @min(bx, b.end_x - 15.0);
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
        const tx = b.end_x + 20.0;
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
            var bx: f64 = -99999.0;
            for (group) |b| bx = @max(bx, b.end_x + 15.0);
            for (group) |b| try drawNetWire(w, b.end_x, b.cy, bx, b.cy, term);
            try drawNetWire(w, bx, group[0].cy, bx, group[group.len - 1].cy, term);
            try drawNetWire(w, bx, group[group.len - 1].cy, term_x, group[group.len - 1].cy, term);
            try drawTerminal(self, w, term_x, group[group.len - 1].cy, term, "start");
        }

        i = j;
    }
}

/// Draw a terminal label or symbol (GND/NC/net label).
pub fn drawTerminal(self: *RenderCtx, w: anytype, end_x: f64, cy: f64, term: []const u8, anchor: []const u8) !void {
    if (isGroundNet(term)) {
        try w.print(
            \\<g class="net" data-net="{s}" style="cursor:pointer">
            \\
        , .{term});
        try drawGndSymbol(w, end_x, cy);
        try w.writeAll("</g>\n");
    } else {
        const color: []const u8 = if (self.port_nets.contains(term)) "#4a9eff" else "#e8c547";
        const label_x: f64 = if (std.mem.eql(u8, anchor, "end")) end_x - net_label_gap else end_x + net_label_gap;
        try w.print(
            \\<g class="net" data-net="{s}" style="cursor:pointer">
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="{s}" font-size="11" font-weight="bold" fill="{s}">{s}</text>
            \\</g>
            \\
        , .{ term, label_x, cy + 4.0, anchor, color, term });
    }
    try writeDebugPin(w, end_x, cy);
}

// ── Hub icon ───────────────────────────────────────────────────────���──

pub fn drawHubIcon(self: *RenderCtx, w: anytype, hub: FlatInst, box_y: f64, hub_height: f64) !void {
    _ = self;
    const icon = classifyComponent(hub);
    if (icon) |icon_name| {
        const icon_cx = hub_x + hub_width / 2.0;
        const icon_cy = box_y + hub_height / 2.0 + 8.0;
        try drawBlockIcon(w, icon_name, icon_cx, icon_cy, "#4a9eff");
    }
}

/// Infer icon from a block's instances (find the first hub and classify it)
pub fn inferBlockIcon(self: *RenderCtx, block: *const env_mod.DesignBlock) ?[]const u8 {
    for (block.instances) |inst| {
        const fi = self.inst_map.get(inst.ref_des) orelse continue;
        if (classifyComponent(fi)) |icon| return icon;
    }
    for (block.sub_blocks) |sb| {
        for (sb.block.instances) |inst| {
            const key = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sb.name, inst.ref_des }) catch continue;
            const fi = self.inst_map.get(key) orelse continue;
            if (classifyComponent(fi)) |icon| return icon;
        }
    }
    return null;
}

// ── Port block rendering ──────────────────────────────────────────────

pub fn renderPortBlock(self: *RenderCtx, w: anytype, name: []const u8, ports: []const Port, y_start: f64, icon: ?[]const u8) !f64 {
    _ = self;
    var left_count: usize = 0;
    var right_count: usize = 0;
    for (ports) |port| {
        if (std.mem.eql(u8, port.direction, "out")) {
            right_count += 1;
        } else {
            left_count += 1;
        }
    }

    const port_spacing: f64 = 40.0;
    const box_pad: f64 = 40.0;
    const max_side = @max(@max(left_count, right_count), 1);
    const block_height = box_pad * 2.0 + @as(f64, @floatFromInt(max_side - 1)) * port_spacing;
    const box_y = y_start;

    try w.print(
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.0}" height="{d:.1}" fill="#1a2e1a" stroke="#4a9" stroke-width="2" rx="6" stroke-dasharray="8,4"/>
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="12" font-weight="bold" fill="#4a9">{s}</text>
        \\
    , .{
        hub_x,
        box_y,
        hub_width,
        block_height,
        hub_x + hub_width / 2.0,
        box_y + 18.0,
        name,
    });

    if (icon) |icon_name| {
        const icon_cx = hub_x + hub_width / 2.0;
        const icon_cy = box_y + block_height / 2.0 + 8.0;
        try drawBlockIcon(w, icon_name, icon_cx, icon_cy, "#4a9");
    }

    var left_idx: usize = 0;
    var right_idx: usize = 0;
    for (ports) |port| {
        const is_output = std.mem.eql(u8, port.direction, "out");
        if (is_output) {
            const py = box_y + box_pad + @as(f64, @floatFromInt(right_idx)) * port_spacing;
            const edge_x = hub_x + hub_width;
            const stub_x = edge_x + pin_stub;

            try drawNetWire(w, edge_x, py, stub_x, py, port.net);

            const dir_text: []const u8 = "\xe2\x86\x90 OUT";
            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="12" fill="#4a9">{s} {s}</text>
                \\
            , .{ edge_x - 8.0, py + 4.0, port.name, dir_text });

            try w.print(
                \\<g class="net" data-net="{s}" style="cursor:pointer">
                \\<text x="{d:.1}" y="{d:.1}" text-anchor="start" font-size="11" font-weight="bold" fill="#4a9eff">{s}</text>
                \\</g>
                \\
            , .{ port.net, stub_x + net_label_gap, py + 4.0, port.net });

            if (port.rated_min != null and port.rated_max != null) {
                try w.print(
                    \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="9" fill="#888">{d:.1}V - {d:.1}V</text>
                    \\
                , .{ edge_x - 8.0, py + 16.0, port.rated_min.?, port.rated_max.? });
            }

            right_idx += 1;
        } else {
            const py = box_y + box_pad + @as(f64, @floatFromInt(left_idx)) * port_spacing;
            const edge_x = hub_x;
            const stub_x = edge_x - pin_stub;

            try drawNetWire(w, stub_x, py, edge_x, py, port.net);

            const dir_text: []const u8 = if (std.mem.eql(u8, port.direction, "in"))
                "\xe2\x86\x92 "
            else
                "\xe2\x86\x94 ";

            try w.print(
                \\<text x="{d:.1}" y="{d:.1}" font-size="12" fill="#4a9">{s}{s}</text>
                \\
            , .{ edge_x + 8.0, py + 4.0, dir_text, port.name });

            if (isGroundNet(baseNetName(port.net))) {
                try w.print(
                    \\<g class="net" data-net="{s}" style="cursor:pointer">
                    \\
                , .{port.net});
                try drawGndSymbol(w, stub_x, py);
                try w.writeAll("</g>\n");
            } else {
                try w.print(
                    \\<g class="net" data-net="{s}" style="cursor:pointer">
                    \\<text x="{d:.1}" y="{d:.1}" text-anchor="end" font-size="11" font-weight="bold" fill="#4a9eff">{s}</text>
                    \\</g>
                    \\
                , .{ port.net, stub_x - net_label_gap, py + 4.0, port.net });
            }

            if (port.rated_min != null and port.rated_max != null) {
                try w.print(
                    \\<text x="{d:.1}" y="{d:.1}" font-size="9" fill="#888">{d:.1}V - {d:.1}V</text>
                    \\
                , .{ edge_x + 8.0, py + 16.0, port.rated_min.?, port.rated_max.? });
            }

            left_idx += 1;
        }
    }

    return block_height;
}

// ── Passive chain drawing ─────────────────────────────────────────────

pub fn drawPassiveChainLeft(_: *RenderCtx, w: anytype, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
    if (spokes.len == 0) return start_x;
    var x = start_x;
    for (spokes, 0..) |inst, i| {
        if (i > 0) {
            try drawWire(w, x, cy, x - 20.0, cy);
            x -= 20.0;
        }
        try drawPassiveLeft(w, inst, x, cy);
        x -= passive_bw;
    }
    return x;
}

pub fn drawPassiveChainRight(_: *RenderCtx, w: anytype, start_x: f64, cy: f64, spokes: []const FlatInst) !f64 {
    if (spokes.len == 0) return start_x;
    var x = start_x;
    for (spokes, 0..) |inst, i| {
        if (i > 0) {
            try drawWire(w, x, cy, x + 20.0, cy);
            x += 20.0;
        }
        try drawPassiveRight(w, inst, x, cy);
        x += passive_bw;
    }
    return x;
}

fn drawPassiveLeft(w: anytype, inst: FlatInst, x: f64, cy: f64) !void {
    const bx = x - passive_bw;
    const by = cy - passive_bh / 2.0;
    const cx = bx + passive_bw / 2.0;
    const pad: f64 = 6.0;

    try w.print(
        \\<g data-ref="{s}" class="component" style="cursor:pointer">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
        \\
    , .{
        shortRef(inst.ref_des),
        bx - pad,
        by - 14.0,
        passive_bw + pad * 2.0,
        passive_bh + 18.0,
    });

    try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="#888">{s} {s}</text>
        \\</g>
        \\
    , .{ cx, by - 4.0, shortRef(inst.ref_des), formatShort(inst) });

    try writeDebugPin(w, bx, cy);
    try writeDebugPin(w, bx + passive_bw, cy);
}

fn drawPassiveRight(w: anytype, inst: FlatInst, x: f64, cy: f64) !void {
    const bx = x;
    const by = cy - passive_bh / 2.0;
    const cx = bx + passive_bw / 2.0;
    const pad: f64 = 6.0;

    try w.print(
        \\<g data-ref="{s}" class="component" style="cursor:pointer">
        \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="transparent" class="hit-area"/>
        \\
    , .{
        shortRef(inst.ref_des),
        bx - pad,
        by - 14.0,
        passive_bw + pad * 2.0,
        passive_bh + 18.0,
    });

    try drawSymbolShape(w, bx, passive_bw, cx, cy, inst);

    try w.print(
        \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="#888">{s} {s}</text>
        \\</g>
        \\
    , .{ cx, by - 4.0, shortRef(inst.ref_des), formatShort(inst) });

    try writeDebugPin(w, bx, cy);
    try writeDebugPin(w, bx + passive_bw, cy);
}
