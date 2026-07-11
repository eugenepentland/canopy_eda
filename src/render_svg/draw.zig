const std = @import("std");
const ctx_mod = @import("context.zig");
const FlatInst = ctx_mod.FlatInst;
const Endpoint = ctx_mod.Endpoint;
const escape = @import("../escape.zig");

const Allocator = std.mem.Allocator;

/// Error set for SVG-emit helpers. Covers both writer shapes the schematic
/// page calls into: an `ArrayListUnmanaged.writer()` (only `OutOfMemory`)
/// and a `*std.Io.Writer` (adds `WriteFailed`).
pub const RenderError = std.mem.Allocator.Error || std.Io.Writer.Error;

// ── Layout Constants (re-exported for sub-modules) ────────────────────
pub const hub_width: f64 = 180.0;
pub const pin_stub: f64 = 40.0;
pub const spoke_len: f64 = 80.0;
pub const net_label_gap: f64 = 18.0;
pub const hub_x: f64 = 320.0;
pub const top_margin: f64 = 80.0;
pub const passive_bw: f64 = 40.0;
pub const passive_bh: f64 = 20.0;
pub const branch_spacing: f64 = 40.0;
pub const per_conn_spacing: f64 = 40.0;
pub const bus_gap: f64 = 15.0;

// ── Symbol drawing constants ──────────────────────────────────────
const HALF_DIVISOR: f64 = 2.0;
const PASSIVE_BODY_W: f64 = 24.0;
const PASSIVE_BODY_H: f64 = 10.0;
const CAP_PLATE_H: f64 = 12.0;
const CAP_PLATE_GAP: f64 = 6.0;
const IND_ARC_W: f64 = 6.0;
const DEFAULT_SYM_HALF_H: f64 = 8.0;
const GND_STUB_LEN: f64 = 6.0;
const GND_BAR1_HALF: f64 = 7.0;
const GND_BAR2_HALF: f64 = 4.5;
const GND_BAR2_OFF: f64 = 9.0;
const GND_BAR3_HALF: f64 = 2.0;
const GND_BAR3_OFF: f64 = 12.0;
const NC_HALF_SIZE: f64 = 5.0;
const AMP_BODY_SIZE: f64 = 28.0;
const AMP_HALF_RATIO: f64 = 0.6;
const ICON_LABEL_GAP: f64 = 14.0;
const LDO_W: f64 = 36.0;
const LDO_H: f64 = 24.0;
const LDO_PIN_LEN: f64 = 8.0;
const LDO_ARROW_HALF: f64 = 4.0;
const LDO_ARROW_FOOT: f64 = 3.0;
const TR_BODY_SIZE: f64 = 24.0;
const TR_OFF_X: f64 = 4.0;
const TR_GP_OFF: f64 = 4.0;
const TR_INSET: f64 = 3.0;
const TR_PIN_LEN: f64 = 8.0;
const LDO_INNER_LABEL_Y: f64 = 4.0;

/// Draw a wire (Manhattan routing: horizontal, or H-V-H polyline).
pub fn drawWire(w: anytype, x1: f64, y1: f64, x2: f64, y2: f64) RenderError!void {
    if (y1 == y2) {
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#4a9" stroke-width="1.5"/>
            \\
        , .{ x1, y1, x2, y2 });
    } else {
        const mid_x = (x1 + x2) / HALF_DIVISOR;
        try w.print(
            \\<polyline points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="#4a9" stroke-width="1.5"/>
            \\
        , .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2 });
    }
}

/// Draw a net wire with hit area and data-net attribute.
pub fn drawNetWire(w: anytype, x1: f64, y1: f64, x2: f64, y2: f64, net: []const u8) RenderError!void {
    try w.writeAll("<g class=\"net\" data-net=\"");
    try escape.writeXml(w, net);
    try w.writeAll("\" style=\"cursor:pointer\">");

    if (y1 == y2) {
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="transparent" stroke-width="12" class="hit-area"/>
        , .{ x1, y1, x2, y2 });
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#4a9" stroke-width="1.5"/>
        , .{ x1, y1, x2, y2 });
    } else {
        const mid_x = (x1 + x2) / HALF_DIVISOR;
        try w.print(
            \\<polyline points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}"
            \\ fill="none" stroke="transparent" stroke-width="12"
            \\ stroke-linejoin="round" class="hit-area"/>
        , .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2 });
        try w.print(
            \\<polyline points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="#4a9" stroke-width="1.5"/>
        , .{ x1, y1, mid_x, y1, mid_x, y2, x2, y2 });
    }

    try w.writeAll("</g>\n");
}

/// Draw the symbol shape inside a passive component box.
pub fn drawSymbolShape(w: anytype, bx: f64, bw: f64, cx: f64, cy: f64, inst: FlatInst) RenderError!void {
    const ref = shortRef(inst.ref_des);
    const is_ferrite = ref.len >= 2 and ref[0] == 'F' and ref[1] == 'B';

    if (is_ferrite) {
        const body_w: f64 = PASSIVE_BODY_W;
        const body_h: f64 = PASSIVE_BODY_H;
        const body_x = cx - body_w / HALF_DIVISOR;
        const body_y = cy - body_h / HALF_DIVISOR;
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
        const body_w: f64 = PASSIVE_BODY_W;
        const body_h: f64 = PASSIVE_BODY_H;
        const body_x = cx - body_w / HALF_DIVISOR;
        const body_y = cy - body_h / HALF_DIVISOR;
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
        const plate_h: f64 = CAP_PLATE_H;
        const gap_val: f64 = CAP_PLATE_GAP;
        const plate_l_x = cx - gap_val / HALF_DIVISOR;
        const plate_r_x = cx + gap_val / HALF_DIVISOR;
        const plate_top = cy - plate_h / HALF_DIVISOR;
        const plate_bot = cy + plate_h / HALF_DIVISOR;
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
        const arc_w: f64 = IND_ARC_W;
        const n_arcs: u32 = 3;
        const total_arc = arc_w * @as(f64, @floatFromInt(n_arcs));
        const start_x = cx - total_arc / HALF_DIVISOR;
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
            , .{ ax, cy, arc_w / HALF_DIVISOR, arc_w / HALF_DIVISOR, ax + arc_w, cy });
        }
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#8888cc" stroke-width="1.5"/>
            \\
        , .{ start_x + total_arc, cy, bx + bw, cy });
    } else {
        try w.print(
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="16" fill="#2a2a4a" stroke="#8888cc" stroke-width="1" rx="3"/>
            \\
        , .{ bx, cy - DEFAULT_SYM_HALF_H, bw });
    }
}

/// Draw the ground symbol: vertical stub + 3 decreasing horizontal lines.
pub fn drawGndSymbol(w: anytype, x: f64, y: f64) RenderError!void {
    try w.print(
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="#e8c547" stroke-width="1.5"/>
        \\
    , .{
        x,                 y,                x,                 y + GND_STUB_LEN,
        x - GND_BAR1_HALF, y + GND_STUB_LEN, x + GND_BAR1_HALF, y + GND_STUB_LEN,
        x - GND_BAR2_HALF, y + GND_BAR2_OFF, x + GND_BAR2_HALF, y + GND_BAR2_OFF,
        x - GND_BAR3_HALF, y + GND_BAR3_OFF, x + GND_BAR3_HALF, y + GND_BAR3_OFF,
    });
}

/// Draw the no-connect X symbol.
pub fn drawNcSymbol(w: anytype, x: f64, y: f64) RenderError!void {
    const size: f64 = NC_HALF_SIZE;
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
pub fn writeDebugPin(w: anytype, x: f64, y: f64) RenderError!void {
    try w.print(
        \\<circle class="debug-pin" cx="{d:.1}" cy="{d:.1}" r="3" fill="red" opacity="0.8" style="display:none"/>
        \\
    , .{ x, y });
}

/// Draw a block-level icon centered at (cx, cy) with given stroke color.
pub fn drawBlockIcon(w: anytype, icon_name: []const u8, cx: f64, cy: f64, color: []const u8) RenderError!void {
    if (std.mem.eql(u8, icon_name, "amplifier")) {
        const size: f64 = AMP_BODY_SIZE;
        const half_h = size * AMP_HALF_RATIO;
        const lx = cx - size / HALF_DIVISOR;
        const rx = cx + size / HALF_DIVISOR;
        const ty = cy - half_h;
        const by = cy + half_h;
        try w.print(
            \\<polygon points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="none" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="10" fill="{s}" opacity="0.5">Amplifier</text>
            \\
        , .{ lx, ty, lx, by, rx, cy, color, cx, by + ICON_LABEL_GAP, color });
    } else if (std.mem.eql(u8, icon_name, "ldo")) {
        const icon_w: f64 = LDO_W;
        const icon_h: f64 = LDO_H;
        const lx = cx - icon_w / HALF_DIVISOR;
        const ty = cy - icon_h / HALF_DIVISOR;
        const rx = lx + icon_w;
        try w.print(
            \\<rect x="{d:.1}" y="{d:.1}" width="{d:.1}" height="{d:.1}" fill="none" stroke="{s}" stroke-width="1.5" opacity="0.5" rx="2"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<polygon points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="{s}" opacity="0.5"/>
            \\
        , .{
            lx,                  ty,                  icon_w, icon_h, color,
            lx - LDO_PIN_LEN,    cy,                  lx,     cy,     color,
            lx - LDO_ARROW_HALF, cy - LDO_ARROW_FOOT, lx,     cy,     lx - LDO_ARROW_HALF,
            cy + LDO_ARROW_FOOT, color,
        });
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<polygon points="{d:.1},{d:.1} {d:.1},{d:.1} {d:.1},{d:.1}" fill="{s}" opacity="0.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="9" fill="{s}" opacity="0.5">LDO</text>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="10" fill="{s}" opacity="0.5">Linear Regulator</text>
            \\
        , .{
            rx,                  cy,                           rx + LDO_PIN_LEN, cy,                     color,
            rx + LDO_ARROW_HALF, cy - LDO_ARROW_FOOT,          rx + LDO_PIN_LEN, cy,                     rx + LDO_ARROW_HALF,
            cy + LDO_ARROW_FOOT, color,                        cx,               cy + LDO_INNER_LABEL_Y, color,
            cx,                  ty + icon_h + ICON_LABEL_GAP, color,
        });
    } else if (std.mem.eql(u8, icon_name, "transistor")) {
        const size: f64 = TR_BODY_SIZE;
        const half = size / HALF_DIVISOR;
        const ch_x = cx + TR_OFF_X;
        const ch_top = cy - half;
        const ch_bot = cy + half;
        const gp_x = ch_x - TR_GP_OFF;
        try w.print(
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="2" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<line x1="{d:.1}" y1="{d:.1}" x2="{d:.1}" y2="{d:.1}" stroke="{s}" stroke-width="1.5" opacity="0.5"/>
            \\<text x="{d:.1}" y="{d:.1}" text-anchor="middle" font-size="10" fill="{s}" opacity="0.5">Transistor</text>
            \\
        , .{
            ch_x,      ch_top,                  ch_x,              ch_bot,            color,
            cx - half, cy,                      gp_x,              cy,                color,
            gp_x,      ch_top + TR_INSET,       gp_x,              ch_bot - TR_INSET, color,
            ch_x,      ch_top,                  ch_x + TR_PIN_LEN, ch_top,            color,
            ch_x,      ch_bot,                  ch_x + TR_PIN_LEN, ch_bot,            color,
            cx,        ch_bot + ICON_LABEL_GAP, color,
        });
    }
}

// ── Classification helpers ────────────────────────────────────────────

/// Decide whether an instance renders as a hub (boxed IC/connector) or as
/// an inline passive spoke. Hubs are U/J/P/X/Q-prefix parts plus anything
/// that doesn't start with R/C/L/F/D — passives stay as bare symbols on
/// the wires they bridge.
pub fn isHub(inst: FlatInst) bool {
    return isHubRef(inst.ref_des);
}

/// The hub/spoke split keyed on a ref-des alone (the part of `isHub` that
/// doesn't need a full `FlatInst`). Passives — R/C/L/F/D — are spokes drawn
/// inline on the hub they wire into; everything else (U/J/P/X/Q and any other
/// prefix) is a hub box.
pub fn isHubRef(ref_des: []const u8) bool {
    const rd = shortRef(ref_des);
    if (rd.len == 0) return true;
    return switch (rd[0]) {
        'U', 'J', 'P', 'X', 'Q' => true,
        'R', 'C', 'L', 'F', 'D' => false,
        else => true,
    };
}

/// Recognise the canonical ground-rail names: GND, AGND, DGND, anything
/// starting with VSS. Drives whether the renderer draws a GND symbol
/// instead of a labeled net stub.
pub fn isGroundNet(name: []const u8) bool {
    return std.mem.eql(u8, name, "GND") or std.mem.eql(u8, name, "AGND") or
        std.mem.eql(u8, name, "DGND") or std.mem.startsWith(u8, name, "VSS");
}

/// Strip the "subblock/" path from a ref-des — turns "ldo/U1" into "U1"
/// so each hub box shows the local designator rather than the full
/// hierarchy path the evaluator stored.
pub fn shortRef(ref_des: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, ref_des, '/')) |idx| return ref_des[idx + 1 ..];
    return ref_des;
}

/// Strip a sub-block path prefix from a net name — turns "ldo/VOUT" into
/// "VOUT" so labels stay readable when sub-block contents are flattened
/// into the parent schematic.
pub fn shortNetName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |idx| return name[idx + 1 ..];
    return name;
}

/// Strip everything from the first `.` onward — turns "VDD.U1.IN" into
/// "VDD" so per-pin sub-nets generated by the decoupling pass collapse to
/// the rail name they belong to.
pub fn baseNetName(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, '.')) |idx| return name[0..idx];
    return name;
}

/// Pick the label shown next to an instance in the schematic — the user-set
/// value (e.g. "100nF") if any, otherwise the component family name. Keeps
/// passives readable even when the source omits a value.
pub fn displayValue(inst: FlatInst) []const u8 {
    if (inst.value.len > 0) return inst.value;
    return inst.component;
}

/// Short label used under each passive in the SVG schematic — the value
/// when set, otherwise the component family name. Mirrors `displayValue`
/// today but kept distinct so future tweaks can diverge.
pub fn formatShort(inst: FlatInst) []const u8 {
    if (inst.value.len > 0) return inst.value;
    return inst.component;
}

/// Tagged-union equality for `Endpoint` — identifies whether two adjacency
/// entries point at the same net or the same physical pin. Used by the
/// spoke-chain walker to detect "we came from this pin" in a consistent way.
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
    if (containsCI(name_lower, "lt3045") or containsCI(name_lower, "lt3042") or
        containsCI(name_lower, "lp5907") or containsCI(name_lower, "ams1117"))
        return "ldo";
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

// spec: render_svg - Net names are XML-escaped in the emitted SVG markup
test "drawNetWire escapes a quote/angle-bracket in the net name" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    // An import-kicad net name that tries to break out of the data-net attribute
    // and inject a <script> tag.
    try drawNetWire(w, 0, 0, 10, 0, "\"><script>alert(1)</script>");
    // The raw payload must not survive: no unescaped '<', '>' or '"' from the
    // net name can reach the inlined SVG markup.
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "data-net=\"&quot;&gt;&lt;script&gt;") != null);
}

test "drawWire emits a straight line for a horizontal (y1==y2) wire" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    // Equal endpoints on y ⇒ the horizontal branch: a single <line>, not the
    // H-V-H <polyline> the y1!=y2 branch draws. `==`→`!=` swaps the two branches.
    try drawWire(w, 0, 5, 10, 5);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<line ") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "<polyline") == null);
}
