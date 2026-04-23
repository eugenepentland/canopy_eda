const std = @import("std");
const ctx_mod = @import("context.zig");
const FlatInst = ctx_mod.FlatInst;
const Endpoint = ctx_mod.Endpoint;

const Allocator = std.mem.Allocator;

// ── Layout Constants (re-exported for sub-modules) ────────────────────
pub const hub_width: f64 = 180.0;
pub const pin_stub: f64 = 40.0;
pub const spoke_len: f64 = 80.0;
pub const net_label_gap: f64 = 18.0;
pub const hub_x: f64 = 320.0;
pub const top_margin: f64 = 80.0;
pub const passive_bw: f64 = 40.0;
pub const passive_bh: f64 = 20.0;
pub const passive_hit_w: f64 = 52.0;
pub const passive_hit_h: f64 = 38.0;
pub const branch_spacing: f64 = 40.0;
pub const per_conn_spacing: f64 = 40.0;
pub const bus_gap: f64 = 15.0;

/// Draw a wire (Manhattan routing: horizontal, or H-V-H polyline).
pub fn drawWire(w: anytype, x1: f64, y1: f64, x2: f64, y2: f64) !void {
    if (y1 == y2) {
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#4a9" stroke-width="1.5"/>
            \\
        , .{ x1, y1, x2, y2 });
    } else {
        const mid_x = (x1 + x2) / 2.0;
        try w.print(
            \\<polyline points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="#4a9" stroke-width="1.5"/>
            \\
        , .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2 });
    }
}

/// Draw a net wire with hit area and data-net attribute.
pub fn drawNetWire(w: anytype, x1: f64, y1: f64, x2: f64, y2: f64, net: []const u8) !void {
    try w.print(
        \\<g class="net" data-net="{s}" style="cursor:pointer">
    , .{net});

    if (y1 == y2) {
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="transparent" stroke-width="12" class="hit-area"/>
        , .{ x1, y1, x2, y2 });
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#4a9" stroke-width="1.5"/>
        , .{ x1, y1, x2, y2 });
    } else {
        const mid_x = (x1 + x2) / 2.0;
        try w.print(
            \\<polyline points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="transparent" stroke-width="12" stroke-linejoin="round" class="hit-area"/>
        , .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2 });
        try w.print(
            \\<polyline points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="#4a9" stroke-width="1.5"/>
        , .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2 });
    }

    try w.writeAll("</g>\n");
}

/// Draw the symbol shape inside a passive component box.
pub fn drawSymbolShape(w: anytype, bx: f64, bw: f64, cx: f64, cy: f64, inst: FlatInst) !void {
    const ref = shortRef(inst.ref_des);
    const is_ferrite = ref.len >= 2 and ref[0] == 'F' and ref[1] == 'B';

    if (is_ferrite) {
        const body_w: f64 = 24.0;
        const body_h: f64 = 10.0;
        const body_x = cx - body_w / 2.0;
        const body_y = cy - body_h / 2.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="#3a3a5a" stroke="#8888cc" stroke-width="1.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{
            bx,              cy,     body_x,  cy,
            body_x,          body_y, body_w,  body_h,
            body_x + body_w, cy,     bx + bw, cy,
        });
    } else if (std.mem.eql(u8, inst.symbol, "generic-res")) {
        const body_w: f64 = 24.0;
        const body_h: f64 = 10.0;
        const body_x = cx - body_w / 2.0;
        const body_y = cy - body_h / 2.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="none" stroke="#8888cc" stroke-width="1.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{
            bx,              cy,     body_x,  cy,
            body_x,          body_y, body_w,  body_h,
            body_x + body_w, cy,     bx + bw, cy,
        });
    } else if (std.mem.eql(u8, inst.symbol, "generic-cap")) {
        const plate_h: f64 = 12.0;
        const gap_val: f64 = 6.0;
        const plate_l_x = cx - gap_val / 2.0;
        const plate_r_x = cx + gap_val / 2.0;
        const plate_top = cy - plate_h / 2.0;
        const plate_bot = cy + plate_h / 2.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="2"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="2"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{
            bx,        cy,        plate_l_x, cy,
            plate_l_x, plate_top, plate_l_x, plate_bot,
            plate_r_x, plate_top, plate_r_x, plate_bot,
            plate_r_x, cy,        bx + bw,   cy,
        });
    } else if (std.mem.eql(u8, inst.symbol, "generic-ind")) {
        const arc_w: f64 = 6.0;
        const n_arcs: u32 = 3;
        const total_arc = arc_w * @as(f64, @floatFromInt(n_arcs));
        const start_x = cx - total_arc / 2.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{ bx, cy, start_x, cy });
        var ai: u32 = 0;
        while (ai < n_arcs) : (ai += 1) {
            const ax = start_x + @as(f64, @floatFromInt(ai)) * arc_w;
            try w.print(
                \\<path d="M {d:.1} {d:.1} A {d:.1} {d:.1} 0 0 1 {d:.1} {d:.1}" fill="none" stroke="#8888cc" stroke-width="1.5"/>
                \\
            , .{ ax, cy, arc_w / 2.0, arc_w / 2.0, ax + arc_w, cy });
        }
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{ start_x + total_arc, cy, bx + bw, cy });
    } else {
        try w.print(
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="16" fill="#2a2a4a" stroke="#8888cc" stroke-width="1" rx="3"/>
            \\
        , .{ bx, cy - 8.0, bw });
    }
}

/// Draw the ground symbol: vertical stub + 3 decreasing horizontal lines.
pub fn drawGndSymbol(w: anytype, x: f64, y: f64) !void {
    try w.print(
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\
    , .{
        x,       y,        x,       y + 6.0,
        x - 7.0, y + 6.0,  x + 7.0, y + 6.0,
        x - 4.5, y + 9.0,  x + 4.5, y + 9.0,
        x - 2.0, y + 12.0, x + 2.0, y + 12.0,
    });
}

/// Draw the no-connect X symbol.
pub fn drawNcSymbol(w: anytype, x: f64, y: f64) !void {
    const size: f64 = 5.0;
    try w.print(
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#555" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#555" stroke-width="1.5"/>
        \\
    , .{
        x - size, y - size, x + size, y + size,
        x + size, y - size, x - size, y + size,
    });
}

/// Draw debug pin dot (hidden by default).
pub fn writeDebugPin(w: anytype, x: f64, y: f64) !void {
    try w.print(
        \\<circle class="debug-pin" cx="{d:.1}" cy="{d:.1}" r="3" fill="red" opacity="0.8" style="display:none"/>
        \\
    , .{ x, y });
}

/// Draw a block-level icon centered at (cx, cy) with given stroke color.
pub fn drawBlockIcon(w: anytype, icon_name: []const u8, cx: f64, cy: f64, color: []const u8) !void {
    if (std.mem.eql(u8, icon_name, "amplifier")) {
        const size: f64 = 28.0;
        const half_h = size * 0.6;
        const lx = cx - size / 2.0;
        const rx = cx + size / 2.0;
        const ty = cy - half_h;
        const by = cy + half_h;
        try w.print(
            \\<polygon points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="10" fill="{s}" opacity="0.5">Amplifier</text>
            \\
        , .{ lx, ty, lx, by, rx, cy, color, cx, by + 14.0, color });
    } else if (std.mem.eql(u8, icon_name, "ldo")) {
        const icon_w: f64 = 36.0;
        const icon_h: f64 = 24.0;
        const lx = cx - icon_w / 2.0;
        const ty = cy - icon_h / 2.0;
        const rx = lx + icon_w;
        try w.print(
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="none" stroke="{s}" stroke-width="1.5" opacity="0.5" rx="2"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<polygon points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="{s}" opacity="0.5"/>
            \\
        , .{
            lx,       ty,       icon_w, icon_h, color,
            lx - 8.0, cy,       lx,     cy,     color,
            lx - 4.0, cy - 3.0, lx,     cy,     lx - 4.0,
            cy + 3.0, color,
        });
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<polygon points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="{s}" opacity="0.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="{s}" opacity="0.5">LDO</text>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="10" fill="{s}" opacity="0.5">Linear Regulator</text>
            \\
        , .{
            rx,       cy,                 rx + 8.0, cy,       color,
            rx + 4.0, cy - 3.0,           rx + 8.0, cy,       rx + 4.0,
            cy + 3.0, color,              cx,       cy + 4.0, color,
            cx,       ty + icon_h + 14.0, color,
        });
    } else if (std.mem.eql(u8, icon_name, "transistor")) {
        const size: f64 = 24.0;
        const half = size / 2.0;
        const ch_x = cx + 4.0;
        const ch_top = cy - half;
        const ch_bot = cy + half;
        const gp_x = ch_x - 4.0;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="2" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="10" fill="{s}" opacity="0.5">Transistor</text>
            \\
        , .{
            ch_x,      ch_top,        ch_x,       ch_bot,       color,
            cx - half, cy,            gp_x,       cy,           color,
            gp_x,      ch_top + 3.0,  gp_x,       ch_bot - 3.0, color,
            ch_x,      ch_top,        ch_x + 8.0, ch_top,       color,
            ch_x,      ch_bot,        ch_x + 8.0, ch_bot,       color,
            cx,        ch_bot + 14.0, color,
        });
    }
}

// ── Classification helpers ────────────────────────────────────────────

pub fn isHub(inst: FlatInst) bool {
    const rd = shortRef(inst.ref_des);
    if (rd.len == 0) return true;
    return switch (rd[0]) {
        'U', 'J', 'P', 'X', 'Q' => true,
        'R', 'C', 'L', 'F', 'D' => false,
        else => true,
    };
}

pub fn isGroundNet(name: []const u8) bool {
    return std.mem.eql(u8, name, "GND") or std.mem.eql(u8, name, "AGND") or
        std.mem.eql(u8, name, "DGND") or std.mem.startsWith(u8, name, "VSS");
}

pub fn shortRef(ref_des: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, ref_des, '/')) |idx| return ref_des[idx + 1 ..];
    return ref_des;
}

pub fn shortNetName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| return name[idx + 1 ..];
    return name;
}

pub fn baseNetName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |idx| return name[0..idx];
    return name;
}

pub fn displayValue(inst: FlatInst) []const u8 {
    if (inst.value.len > 0) return inst.value;
    return inst.component;
}

pub fn formatShort(inst: FlatInst) []const u8 {
    if (inst.value.len > 0) return inst.value;
    return inst.component;
}

pub fn endpointEql(a: Endpoint, b: Endpoint) bool {
    switch (a) {
        .net => |an| {
            switch (b) {
                .net => |bn| return std.mem.eql(u8, an, bn),
                .pin => return false,
            }
        },
        .pin => |ap| {
            switch (b) {
                .pin => |bp| return std.mem.eql(u8, ap.ref_des, bp.ref_des) and std.mem.eql(u8, ap.pin, bp.pin),
                .net => return false,
            }
        },
    }
}

/// Classify a component into an icon category based on its symbol, component name, and ref_des.
pub fn classifyComponent(inst: FlatInst) ?[]const u8 {
    const name_lower = inst.component;
    if (containsCI(name_lower, "pma") or containsCI(name_lower, "lna") or containsCI(name_lower, "mmic")) return "amplifier";
    if (containsCI(name_lower, "tpsm") or containsCI(name_lower, "tps5") or containsCI(name_lower, "lm267")) return "buck";
    if (containsCI(name_lower, "lt3045") or containsCI(name_lower, "lt3042") or containsCI(name_lower, "lp5907") or containsCI(name_lower, "ams1117")) return "ldo";
    const ref = shortRef(inst.ref_des);
    if (ref.len > 0 and ref[0] == 'Q') return "transistor";
    if (ref.len > 0 and ref[0] == 'D') return "led";
    return null;
}

/// Case-insensitive substring search.
pub fn containsCI(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |nc, j| {
            const hc = haystack[i + j];
            const a = if (hc >= 'A' and hc <= 'Z') hc + 32 else hc;
            const b = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
            if (a != b) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/// Compare pin IDs for sorting: try numeric, fall back to string.
pub fn pinOrder(a: []const u8, b: []const u8) bool {
    const a_num = std.fmt.parseInt(i64, a, 10) catch null;
    const b_num = std.fmt.parseInt(i64, b, 10) catch null;
    if (a_num != null and b_num != null) return a_num.? < b_num.?;
    if (a_num != null) return true;
    if (b_num != null) return false;
    return std.mem.order(u8, a, b) == .lt;
}

/// Escape HTML entities in text content.
pub fn escapeHtml(allocator: Allocator, s: []const u8) ![]const u8 {
    var needs_escape = false;
    for (s) |c| {
        if (c == '&' or c == '<' or c == '>' or c == '"') {
            needs_escape = true;
            break;
        }
    }
    if (!needs_escape) return s;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            else => try buf.append(allocator, c),
        }
    }
    return buf.toOwnedSlice(allocator);
}
