//! Persistent-session WASM DRC for the viewer's mid-drag hand-route gate.
//!
//! The stateless `wasm_drc.zig` bridge re-parses the whole board per `drc_check`
//! (too slow for per-pointermove queries). This module loads a board ONCE
//! (`drc_load`) into a session — static features plus a spatial grid — so a probe
//! (`drc_probe_seg` / `drc_clip_seg` / `drc_probe_via`) is microseconds, and its
//! per-pair distance tests reproduce `placement/drc.zig`'s routing-class checks
//! byte-for-byte (same pub `pad_shape` / `outline` geometry the engine uses).
//! It is a SEPARATE file because `drc.zig` is at its file-size cap with its
//! helpers private, and the pub-api gate forbids a shared cross-file seam — so
//! the board parser is duplicated (mirroring `wasm_drc.zig`'s schema) and each
//! file stays self-contained and under the file-size cap. `wasm_drc.zig` and
//! `main.zig` `@import` this module (wasm exports emitted, native tests run).

const std = @import("std");
const builtin = @import("builtin");

const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const geometry = @import("placement/geometry.zig");
const outline = @import("placement/outline.zig");
const pad_shape = @import("placement/pad_shape.zig");
const drc = @import("placement/drc.zig");
const board_layers = @import("board_layers.zig");
const numeric = @import("numeric.zig");
const export_kicad = @import("export_kicad.zig");

const FlatNet = export_kicad.FlatNet;
const FlatPin = export_kicad.FlatPin;

// ── Board-state JSON parser ──────────────────────────────────────────────────
// Mirrors wasm_drc.zig's parser (same schema) — duplicated because the pub-api
// gate forbids a shared cross-file seam. Produces a Placement + RouteResult +
// base clearance, which the grids build from and the tests feed to `drc.check`.

fn clearanceVal(o: std.json.ObjectMap) ?std.json.Value {
    return o.get("clearance");
}
fn numOr(v: ?std.json.Value, dflt: f64) f64 {
    const val = v orelse return dflt;
    if (val == .integer) return @floatFromInt(val.integer);
    if (val == .float) return val.float;
    if (val == .number_string) return std.fmt.parseFloat(f64, val.number_string) catch dflt;
    return dflt;
}
fn jNum(v: ?std.json.Value) f64 {
    return numOr(v, 0);
}
fn jStr(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return if (val == .string) val.string else "";
}
fn jFlag(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return val == .bool and val.bool;
}
fn objOf(v: ?std.json.Value) ?std.json.ObjectMap {
    const val = v orelse return null;
    return if (val == .object) val.object else null;
}
fn arrOf(v: ?std.json.Value) ?std.json.Array {
    const val = v orelse return null;
    return if (val == .array) val.array else null;
}
/// A JSON `l` field → signal-layer index, clamped at the SHARED sidecar
/// ceiling so this parser, `wasm_drc.zig`'s and the sidecar's own all fold a
/// corrupt index onto the same layer.
fn layerOf(v: ?std.json.Value) u8 {
    const n = jNum(v);
    if (!(n >= 1)) return 0;
    if (n >= board_layers.max_sidecar_layer) return board_layers.max_sidecar_layer;
    return numeric.checkedInt(u8, @floor(n)) orelse 0;
}

/// Interns net names to dense indices (first-appearance order) + groups pads.
const NetTable = struct {
    names: std.ArrayList([]const u8) = .empty,
    index_of: std.StringHashMapUnmanaged(u32) = .empty,
    pins: std.ArrayList(std.ArrayList(FlatPin)) = .empty,

    fn intern(self: *NetTable, arena: std.mem.Allocator, name: []const u8) !u32 {
        if (self.index_of.get(name)) |i| return i;
        const i: u32 = @intCast(self.names.items.len);
        try self.names.append(arena, name);
        try self.pins.append(arena, .empty);
        try self.index_of.put(arena, name, i);
        return i;
    }

    fn addPin(self: *NetTable, arena: std.mem.Allocator, name: []const u8, ref: []const u8, pin: []const u8) !void {
        if (name.len == 0) return;
        const i = try self.intern(arena, name);
        try self.pins.items[i].append(arena, .{ .ref_des = ref, .pin = pin });
    }

    fn featureNet(self: *NetTable, arena: std.mem.Allocator, name: []const u8) !i32 {
        if (name.len == 0) return -1;
        return @intCast(try self.intern(arena, name));
    }

    fn flatNets(self: *NetTable, arena: std.mem.Allocator) ![]const FlatNet {
        const out = try arena.alloc(FlatNet, self.names.items.len);
        for (out, 0..) |*net, i| {
            net.* = .{ .name = self.names.items[i], .pins = try self.pins.items[i].toOwnedSlice(arena) };
        }
        return out;
    }
};

fn buildPoly(arena: std.mem.Allocator, v: ?std.json.Value) ![]const [2]f64 {
    const arr = arrOf(v) orelse return &.{};
    var list: std.ArrayList([2]f64) = .empty;
    for (arr.items) |it| {
        const pair = arrOf(it) orelse continue;
        if (pair.items.len < 2) continue;
        try list.append(arena, .{ jNum(pair.items[0]), jNum(pair.items[1]) });
    }
    return list.toOwnedSlice(arena);
}

/// A pad's oval-slot half-vector: `[a,b]`→`{a,b}`, a number→`{n,0}`, else `{0,0}`.
fn buildSlotHalf(v: ?std.json.Value) [2]f64 {
    if (arrOf(v)) |a| return .{
        if (a.items.len > 0) jNum(a.items[0]) else 0,
        if (a.items.len > 1) jNum(a.items[1]) else 0,
    };
    return .{ jNum(v), 0 };
}

/// One part's `pads` → `geometry.Pad[]`, binding each `ref|pin` to its net. Silk
/// / roundrect-ratio are dropped: probes ignore them and they cancel in the oracle.
fn buildPads(arena: std.mem.Allocator, v: ?std.json.Value, ref: []const u8, nettab: *NetTable) ![]const geometry.Pad {
    var list: std.ArrayList(geometry.Pad) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        const num = jStr(o.get("num"));
        try nettab.addPin(arena, jStr(o.get("net")), ref, num);
        try list.append(arena, .{
            .number = num,
            .x = jNum(o.get("x")),
            .y = jNum(o.get("y")),
            .w = jNum(o.get("w")),
            .h = jNum(o.get("h")),
            .poly = try buildPoly(arena, o.get("poly")),
            .thru = jFlag(o.get("thru")),
            .npth = jFlag(o.get("npth")),
            .drill = jNum(o.get("drill")),
            .slot_half = buildSlotHalf(o.get("slot_half")),
            .rot = jNum(o.get("rot")),
        });
    }
    return list.toOwnedSlice(arena);
}

/// The `parts` array → `optimizer.Part[]` (silk omitted — see `buildPads`).
fn buildParts(arena: std.mem.Allocator, v: ?std.json.Value, nettab: *NetTable) ![]optimizer.Part {
    var list: std.ArrayList(optimizer.Part) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        const ref = jStr(o.get("ref"));
        try list.append(arena, .{
            .ref_des = ref,
            .kind = if (std.mem.eql(u8, jStr(o.get("kind")), "hub")) .hub else .passive,
            .hw = jNum(o.get("hw")),
            .hh = jNum(o.get("hh")),
            .ccx = jNum(o.get("ccx")),
            .ccy = jNum(o.get("ccy")),
            .pads = try buildPads(arena, o.get("pads"), ref, nettab),
            .fallback = false,
            .x = jNum(o.get("x")),
            .y = jNum(o.get("y")),
            .rot = jNum(o.get("rot")),
            .side = if (std.mem.eql(u8, jStr(o.get("side")), "bottom")) .bottom else .top,
        });
    }
    return list.toOwnedSlice(arena);
}

fn buildTracks(arena: std.mem.Allocator, v: ?std.json.Value, nettab: *NetTable) ![]const router.Track {
    var list: std.ArrayList(router.Track) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        try list.append(arena, .{
            .x1 = jNum(o.get("x1")),
            .y1 = jNum(o.get("y1")),
            .x2 = jNum(o.get("x2")),
            .y2 = jNum(o.get("y2")),
            .layer = layerOf(o.get("l")),
            .width = jNum(o.get("w")),
            .net = try nettab.featureNet(arena, jStr(o.get("net"))),
        });
    }
    return list.toOwnedSlice(arena);
}

fn buildVias(arena: std.mem.Allocator, v: ?std.json.Value, nettab: *NetTable) ![]const router.Via {
    var list: std.ArrayList(router.Via) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        try list.append(arena, .{
            .x = jNum(o.get("x")),
            .y = jNum(o.get("y")),
            .dia = jNum(o.get("d")),
            .drill = jNum(o.get("drill")),
            .net = try nettab.featureNet(arena, jStr(o.get("net"))),
        });
    }
    return list.toOwnedSlice(arena);
}

/// The `rules` object → `optimizer.DesignRules` (absent keys keep defaults).
///
/// Shared with `wasm_drc.zig`, which roots this module into the same
/// `drc.wasm` binary and used to carry a byte-identical copy of this function.
/// Both bridges read the SAME blob written by one server emitter, so two
/// readers of it could only ever drift apart — and the pair is the whole
/// reason the design-rule wire keys want a single home. The rest of each
/// bridge's board parser stays deliberately private and duplicated (see this
/// module's header); it is only the rules object, whose key list is the thing
/// that drifts, that is single-sourced here.
///
/// `rules.clearance` is the design's own base clearance — `edgeClearance()`
/// falls back to it, and it can differ from the top-level `clearance` key
/// (which mirrors the blob's `clr` and may carry a `?clearance=` override).
///
/// Every key the blob carries that `DesignRules` owns is mapped, INCLUDING the
/// five `drc.check` does not consult today — `pour_clearance`,
/// `pour.clearance_outer`, `mask.relief_corner_radius`, `pour.min_width`,
/// `pour.corner_radius`. Their
/// only readers are the pour solver and the Gerber / mask-relief writers
/// (`placement/pour.zig`, `export_gerber.zig`, `placement/mask_relief.zig`),
/// none of which `drc.zig` imports; the checker's board-edge rule is
/// `edgeClearance()`, which falls back to `clearance` — not the pour's
/// `pourEdge()`, whose only callers are that same solver and writer. They are
/// mapped anyway because an unmapped key does not read as ABSENT: it reads as
/// the compile-time default, a DIFFERENT number (`pour_clearance` defaults to
/// 0.3), so the struct would quietly misstate a board authoring
/// `(design-rules (pour-clearance 0.15))` the moment anything consulted it.
/// Mapping the wire is this function's whole job; which fields a given check
/// happens to read is not — and cannot be, since one struct serves two bridges.
///
/// Nor is a key with no checker consumer dead weight on the wire. The same
/// object is read by `assets/pcb_board.js`, which paints mask relief with
/// `mask_relief_corner_radius`, and by `assets/pcb_settings.js`, whose rules
/// table shows every scalar here as the board's EFFECTIVE value beside the
/// authored one. It is not the checker's private input, so nothing in it
/// should be trimmed down to what the checker reads.
pub fn buildDesignRules(v: ?std.json.Value) optimizer.DesignRules {
    var r: optimizer.DesignRules = .{};
    const o = objOf(v) orelse return r;
    r.clearance = numOr(clearanceVal(o), r.clearance);
    r.min_drill = numOr(o.get("min_drill"), r.min_drill);
    r.min_annular = numOr(o.get("min_annular"), r.min_annular);
    r.hole_to_hole = numOr(o.get("hole_to_hole"), r.hole_to_hole);
    r.via_to_via = numOr(o.get("via_to_via"), r.via_to_via);
    r.mask.margin = numOr(o.get("mask_margin"), r.mask.margin);
    r.mask.web = numOr(o.get("mask_web"), r.mask.web);
    r.mask.relief_corner_radius = numOr(o.get("mask_relief_corner_radius"), r.mask.relief_corner_radius);
    r.min_width = numOr(o.get("min_width"), r.min_width);
    r.pour_clearance = numOr(o.get("pour_clearance"), r.pour_clearance);
    r.pour.clearance_outer = numOr(o.get("pour_clearance_outer"), r.pour.clearance_outer);
    r.pour.min_width = numOr(o.get("pour_min_width"), r.pour.min_width);
    r.pour.corner_radius = numOr(o.get("pour_corner_radius"), r.pour.corner_radius);
    r.pour.ground_via_max = numOr(o.get("ground_via_max"), r.pour.ground_via_max);
    r.edge.copper = numOr(o.get("copper_edge"), r.edge.copper);
    r.edge.component = numOr(o.get("component_edge"), r.edge.component);
    return r;
}

const NetClassOverride = struct { idx: u32, rule: optimizer.NetRule };
fn buildNetClassOverrides(arena: std.mem.Allocator, v: ?std.json.Value, nettab: *NetTable) ![]const NetClassOverride {
    var list: std.ArrayList(NetClassOverride) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        const name = jStr(o.get("net"));
        if (name.len == 0) continue;
        try list.append(arena, .{ .idx = try nettab.intern(arena, name), .rule = .{
            .width = jNum(o.get("width")),
            .clearance = jNum(clearanceVal(o)),
            .via_dia = jNum(o.get("via_dia")),
            .via_drill = jNum(o.get("via_drill")),
            .pad_neck = .{
                .width = jNum(o.get("pad_neck_width")),
                .max_length = jNum(o.get("pad_neck_max_length")),
                .taper_length = jNum(o.get("pad_neck_taper_length")),
            },
            .rf = .{
                .max_freq_hz = jNum(o.get("max_freq_hz")),
                .impedance = .{
                    .ohms = jNum(o.get("impedance_ohms")),
                    .diff_ohms = jNum(o.get("diff_impedance_ohms")),
                },
            },
        } });
    }
    return list.toOwnedSlice(arena);
}

/// The index-aligned `NetRule[]` (length `n`) from the collected overrides.
fn buildNetRules(arena: std.mem.Allocator, overrides: []const NetClassOverride, n: usize) ![]const optimizer.NetRule {
    if (overrides.len == 0) return &.{};
    const rules = try arena.alloc(optimizer.NetRule, n);
    for (rules) |*r| r.* = .{};
    for (overrides) |ov| if (ov.idx < n) {
        rules[ov.idx] = ov.rule;
    };
    return rules;
}

fn buildBoardRect(v: ?std.json.Value) ?optimizer.BoardRect {
    const o = objOf(v) orelse return null;
    const w = jNum(o.get("w"));
    const h = jNum(o.get("h"));
    if (!(w > 0) or !(h > 0)) return null;
    return .{ .minx = jNum(o.get("x")), .miny = jNum(o.get("y")), .w = w, .h = h };
}

const Board = struct { placement: optimizer.Placement, routed: router.RouteResult, clearance: f64 };

/// Parse board-state JSON into a `Board`. Strings are copied into `arena`
/// (`alloc_always`) so the session never references the input buffer, surviving
/// interleaved `wasm_alloc` / `drc_check` calls that reset the shared input arena.
fn parseBoard(arena: std.mem.Allocator, input: []const u8) !Board {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{ .allocate = .alloc_always });
    const obj = objOf(root) orelse return error.InputNotObject;

    var nettab: NetTable = .{};
    const parts = try buildParts(arena, obj.get("parts"), &nettab);
    const tracks = try buildTracks(arena, obj.get("tracks"), &nettab);
    const vias = try buildVias(arena, obj.get("vias"), &nettab);
    const overrides = try buildNetClassOverrides(arena, obj.get("netclasses"), &nettab);
    const nets = try nettab.flatNets(arena);
    const netrules = try buildNetRules(arena, overrides, nets.len);
    const design = buildDesignRules(obj.get("rules"));

    const board_poly = blk: {
        const pts = try buildPoly(arena, obj.get("board_poly"));
        break :blk if (pts.len >= 3) pts else null;
    };
    var board_rect = buildBoardRect(obj.get("board"));
    if (board_rect == null) {
        if (board_poly) |p| board_rect = outline.bboxRect(p);
    }

    const placement = optimizer.Placement{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
        .board_rect = board_rect,
        .board_poly = board_poly,
        .rules = .{ .net = netrules, .design = design },
    };
    const body_clearance = jNum(clearanceVal(obj));
    const clearance = if (body_clearance > 0) body_clearance else design.clearance;
    return .{
        .placement = placement,
        .routed = .{ .tracks = tracks, .vias = vias, .routed = 0, .total = 0 },
        .clearance = clearance,
    };
}

// ── Session model ────────────────────────────────────────────────────────────
const eps_p: f64 = 1e-6;

/// Two features may touch only if they share a real net (-1 "no net" needs clearance).
fn sameNet(a: i32, b: i32) bool {
    return a == b and a != -1;
}

/// A pad reduced to what a probe needs: world copper box + outline, net, signal
/// layer / thru, and drilled-hole centre + slot half-vector.
const PadLite = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64,
    net: i32,
    layer: u8,
    thru: bool,
    drill: f64,
    hx: f64,
    hy: f64,
    shx: f64,
    shy: f64,
};

/// A drilled hole (drilled pad or via): world centre + diameter + slot half-vector.
const Hole = struct { x: f64, y: f64, drill: f64, shx: f64 = 0, shy: f64 = 0 };

const PinNet = struct { pin: []const u8, net: i32 };

/// The net a pad lands on: the last matching pin in `list` (last-wins), or -1.
fn lookupNet(list: []const PinNet, pin: []const u8) i32 {
    var net: i32 = -1;
    for (list) |e| {
        if (std.mem.eql(u8, e.pin, pin)) net = e.net;
    }
    return net;
}

/// Rebuild the world pad list (net + layer + hole), mirroring drc.zig's private
/// `padBoxes` from the same pub geometry (engine-identical boxes).
fn buildPadLites(arena: std.mem.Allocator, placement: optimizer.Placement) ![]PadLite {
    var by_ref: std.StringHashMapUnmanaged(std.ArrayList(PinNet)) = .empty;
    for (placement.nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            const gop = try by_ref.getOrPut(arena, pin.ref_des);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(arena, .{ .pin = pin.pin, .net = @intCast(ni) });
        }
    }
    var list: std.ArrayList(PadLite) = .empty;
    for (placement.parts) |part| {
        const layer: u8 = if (part.side == .bottom) 1 else 0;
        const pins: []const PinNet = if (by_ref.get(part.ref_des)) |l| l.items else &.{};
        for (part.pads) |pad| {
            const sh = try pad_shape.worldShape(arena, part, pad);
            const c = optimizer.worldPadCenter(&part, pad.x, pad.y);
            var shx: f64 = 0;
            var shy: f64 = 0;
            if (pad.isSlot()) {
                const e1 = optimizer.worldPadCenter(&part, pad.x + pad.slot_half[0], pad.y + pad.slot_half[1]);
                shx = e1[0] - c[0];
                shy = e1[1] - c[1];
            }
            try list.append(arena, .{
                .x0 = sh.x0,
                .y0 = sh.y0,
                .x1 = sh.x1,
                .y1 = sh.y1,
                .poly = sh.poly,
                .net = lookupNet(pins, pad.number),
                .layer = layer,
                .thru = pad.thru,
                .drill = pad.drill,
                .hx = c[0],
                .hy = c[1],
                .shx = shx,
                .shy = shy,
            });
        }
    }
    return list.toOwnedSlice(arena);
}

// ── Session spatial grid ─────────────────────────────────────────────────────
// A uniform hash over feature AABBs (drc.zig's in-check cell maths) so a probe
// touches O(candidates); the session owns its grids for a load's lifetime.

fn cellKeyS(cx: i32, cy: i32) u64 {
    const ux: u64 = @intCast(@as(i64, cx) + 0x40000000);
    const uy: u64 = @intCast(@as(i64, cy) + 0x40000000);
    return (ux << 32) | uy;
}

fn floorCellS(scaled: f64) i32 {
    const f = @floor(scaled);
    if (!(f > -2.0e9)) return -0x40000000;
    if (!(f < 2.0e9)) return 0x40000000;
    return numeric.checkedInt(i32, f) orelse 0;
}

const SessGrid = struct {
    inv: f64 = 1,
    map: std.AutoHashMapUnmanaged(u64, std.ArrayList(u32)) = .empty,

    fn build(a: std.mem.Allocator, boxes: []const [4]f64, delta: f64) std.mem.Allocator.Error!SessGrid {
        var sum: f64 = 0;
        var maxext: f64 = 0;
        for (boxes) |b| {
            const e = @max(b[2] - b[0], b[3] - b[1]);
            sum += e;
            maxext = @max(maxext, e);
        }
        var cell = @max(@max(@max(sum / @max(1.0, @as(f64, @floatFromInt(boxes.len))), 2 * delta), 0.5), maxext / 64.0);
        if (!(std.math.isFinite(cell) and cell > 0)) cell = 1;
        var g = SessGrid{ .inv = 1.0 / cell };
        for (boxes, 0..) |b, i| {
            var cx = floorCellS(b[0] * g.inv);
            const cx1 = floorCellS(b[2] * g.inv);
            const cy1 = floorCellS(b[3] * g.inv);
            while (cx <= cx1) : (cx += 1) {
                var cy = floorCellS(b[1] * g.inv);
                while (cy <= cy1) : (cy += 1) {
                    const e = try g.map.getOrPut(a, cellKeyS(cx, cy));
                    if (!e.found_existing) e.value_ptr.* = .empty;
                    try e.value_ptr.append(a, @intCast(i));
                }
            }
        }
        return g;
    }
};

/// A loaded board: static features, grids, clearance rules, and the net-name
/// table (index = the probe `net` argument). `scratch` is the grid-query buffer.
const Session = struct {
    arena: std.mem.Allocator,
    pads: []const PadLite,
    tracks: []const router.Track,
    vias: []const router.Via,
    holes: []const Hole,
    pad_grid: SessGrid,
    track_grid: SessGrid,
    via_grid: SessGrid,
    hole_grid: SessGrid,
    rules: optimizer.BoardRules,
    base_clr: f64,
    clr_max: f64,
    edge_clr: f64,
    hole_to_hole: f64,
    min_annular: f64,
    min_drill: f64,
    board_rect: ?optimizer.BoardRect,
    board_poly: ?[]const [2]f64,
    net_names: []const []const u8,
    scratch: std.ArrayList(u32),
};

fn featBoxes(arena: std.mem.Allocator, comptime T: type, xs: []const T, comptime bf: fn (T) [4]f64) ![][4]f64 {
    const out = try arena.alloc([4]f64, xs.len);
    for (out, xs) |*b, x| b.* = bf(x);
    return out;
}
fn padLiteBox(p: PadLite) [4]f64 {
    return .{ p.x0, p.y0, p.x1, p.y1 };
}
fn trackFeatBox(t: router.Track) [4]f64 {
    const hw = t.width / 2;
    return .{ @min(t.x1, t.x2) - hw, @min(t.y1, t.y2) - hw, @max(t.x1, t.x2) + hw, @max(t.y1, t.y2) + hw };
}
fn viaFeatBox(v: router.Via) [4]f64 {
    const r = v.dia / 2;
    return .{ v.x - r, v.y - r, v.x + r, v.y + r };
}
fn holeFeatBox(h: Hole) [4]f64 {
    const r = h.drill / 2 + @max(@abs(h.shx), @abs(h.shy));
    return .{ h.x - r, h.y - r, h.x + r, h.y + r };
}

/// Parse `input` into a persistent session (grids over every static feature).
fn buildSessionCtx(arena: std.mem.Allocator, input: []const u8) !Session {
    return sessionFromBoard(arena, try parseBoard(arena, input));
}

fn sessionFromBoard(arena: std.mem.Allocator, board: Board) !Session {
    const placement = board.placement;
    const design = placement.rules.design;
    const pads = try buildPadLites(arena, placement);
    const tracks = board.routed.tracks;
    const vias = board.routed.vias;
    var clr_max = @max(board.clearance, design.via_to_via);
    for (placement.rules.net) |nr| clr_max = @max(clr_max, nr.clearance);

    var holes_l: std.ArrayList(Hole) = .empty;
    for (pads) |p| if (p.drill > 0) {
        try holes_l.append(arena, .{ .x = p.hx, .y = p.hy, .drill = p.drill, .shx = p.shx, .shy = p.shy });
    };
    for (vias) |v| if (v.drill > 0) try holes_l.append(arena, .{ .x = v.x, .y = v.y, .drill = v.drill });
    const holes = try holes_l.toOwnedSlice(arena);

    const names = try arena.alloc([]const u8, placement.nets.len);
    for (names, placement.nets) |*n, fnet| n.* = fnet.name;

    return .{
        .arena = arena,
        .pads = pads,
        .tracks = tracks,
        .vias = vias,
        .holes = holes,
        .pad_grid = try SessGrid.build(arena, try featBoxes(arena, PadLite, pads, padLiteBox), clr_max),
        .track_grid = try SessGrid.build(arena, try featBoxes(arena, router.Track, tracks, trackFeatBox), clr_max),
        .via_grid = try SessGrid.build(arena, try featBoxes(arena, router.Via, vias, viaFeatBox), clr_max),
        .hole_grid = try SessGrid.build(arena, try featBoxes(arena, Hole, holes, holeFeatBox), design.hole_to_hole),
        .rules = placement.rules,
        .base_clr = board.clearance,
        .clr_max = clr_max,
        .edge_clr = design.edgeClearance(),
        .hole_to_hole = design.hole_to_hole,
        .min_annular = design.min_annular,
        .min_drill = design.min_drill,
        .board_rect = placement.board_rect,
        .board_poly = placement.board_poly,
        .net_names = names,
        .scratch = .empty,
    };
}

/// `{"ok":true,"nets":[…]}` — the load response (index = the probe net arg).
fn sessionResponse(arena: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"ok\":true,\"nets\":[");
    for (names, 0..) |n, i| {
        if (i > 0) try w.writeAll(",");
        try writeJsonStr(w, n);
    }
    try w.writeAll("]}");
    return aw.written();
}

/// A JSON string literal, escaping only `"`/`\` (net names are identifiers).
fn writeJsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ── Probe geometry ───────────────────────────────────────────────────────────
// Engine-exact copies of drc.zig's private pair-distance helpers (points bundled
// as `[2]f64` for the param cap; pad/outline geometry stays shared).
fn segPointDist(a: [2]f64, b: [2]f64, p: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    if (len2 < eps_p) return std.math.hypot(p[0] - a[0], p[1] - a[1]);
    const t = std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2, 0, 1);
    return std.math.hypot(p[0] - (a[0] + t * dx), p[1] - (a[1] + t * dy));
}
fn segSegDist(a1: [2]f64, a2: [2]f64, b1: [2]f64, b2: [2]f64) f64 {
    const d1x = a2[0] - a1[0];
    const d1y = a2[1] - a1[1];
    const d2x = b2[0] - b1[0];
    const d2y = b2[1] - b1[1];
    const den = d1x * d2y - d1y * d2x;
    if (@abs(den) > 1e-12) {
        const t = ((b1[0] - a1[0]) * d2y - (b1[1] - a1[1]) * d2x) / den;
        const u = ((b1[0] - a1[0]) * d1y - (b1[1] - a1[1]) * d1x) / den;
        if (t >= 0 and t <= 1 and u >= 0 and u <= 1) return 0;
    }
    var d = segPointDist(a1, a2, b1);
    d = @min(d, segPointDist(a1, a2, b2));
    d = @min(d, segPointDist(b1, b2, a1));
    d = @min(d, segPointDist(b1, b2, a2));
    return d;
}

/// Track centreline `t1`→`t2` to pad `p`'s copper (0 inside; +inf when > `win`
/// off the pad bbox) — slab-clipped then sampled at 0.05 mm, like drc.zig.
fn segShapeDist(t1: [2]f64, t2: [2]f64, p: PadLite, win: f64) f64 {
    const dx = t2[0] - t1[0];
    const dy = t2[1] - t1[1];
    var f0: f64 = 0;
    var f1: f64 = 1;
    if (@abs(dx) > 1e-12) {
        const a = (p.x0 - win - t1[0]) / dx;
        const b = (p.x1 + win - t1[0]) / dx;
        f0 = @max(f0, @min(a, b));
        f1 = @min(f1, @max(a, b));
    } else if (t1[0] < p.x0 - win or t1[0] > p.x1 + win) return std.math.inf(f64);
    if (@abs(dy) > 1e-12) {
        const a = (p.y0 - win - t1[1]) / dy;
        const b = (p.y1 + win - t1[1]) / dy;
        f0 = @max(f0, @min(a, b));
        f1 = @min(f1, @max(a, b));
    } else if (t1[1] < p.y0 - win or t1[1] > p.y1 + win) return std.math.inf(f64);
    if (f0 > f1) return std.math.inf(f64);
    const len = std.math.hypot(dx, dy) * (f1 - f0);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / 0.05)));
    var best = std.math.inf(f64);
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const f = f0 + (f1 - f0) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const d = pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, t1[0] + f * dx, t1[1] + f * dy, best);
        if (d < best) best = d;
    }
    return best;
}

/// Signed inset of `p` from the outline (polygon else rect); positive = inside.
fn boardInset(br: optimizer.BoardRect, poly: ?[]const [2]f64, p: [2]f64) f64 {
    if (poly) |pl| {
        if (pl.len >= 3) return outline.signedInset(pl, p[0], p[1]);
    }
    const dl = p[0] - br.minx;
    const dr = br.minx + br.w - p[0];
    const dt = p[1] - br.miny;
    const db = br.miny + br.h - p[1];
    return @min(@min(dl, dr), @min(dt, db));
}

/// Candidate features (bundled to stay within the parameter cap): a track
/// segment (endpoints + layer / net / half-width) and a via (centre + radius /
/// drill / net).
const SegQ = struct { a: [2]f64, b: [2]f64, layer: u8, net: i32, hw: f64 };
const ViaQ = struct { c: [2]f64, vr: f64, drill: f64, net: i32 };

/// `q` with its far endpoint replaced (the clip search shrinks the segment).
fn segToEnd(q: SegQ, b: [2]f64) SegQ {
    return .{ .a = q.a, .b = b, .layer = q.layer, .net = q.net, .hw = q.hw };
}

// ── Probes ───────────────────────────────────────────────────────────────────
// Each reproduces one drc.zig routing-class check for a candidate against the
// grid-culled static features. Grid candidates near `box`±`delta`, into the
// reused scratch (bounded; duplicates harmless; OOM → empty, only under-reports).
fn candidates(s: *Session, grid: *const SessGrid, box: [4]f64, delta: f64) []const u32 {
    s.scratch.clearRetainingCapacity();
    var cx = floorCellS((box[0] - delta) * grid.inv);
    const cx1 = floorCellS((box[2] + delta) * grid.inv);
    const cy1 = floorCellS((box[3] + delta) * grid.inv);
    while (cx <= cx1) : (cx += 1) {
        var cy = floorCellS((box[1] - delta) * grid.inv);
        while (cy <= cy1) : (cy += 1) {
            if (grid.map.get(cellKeyS(cx, cy))) |b| s.scratch.appendSlice(s.arena, b.items) catch return &.{};
        }
    }
    return s.scratch.items;
}

fn segQBox(q: SegQ) [4]f64 {
    const lo = [2]f64{ @min(q.a[0], q.b[0]) - q.hw, @min(q.a[1], q.b[1]) - q.hw };
    const hi = [2]f64{ @max(q.a[0], q.b[0]) + q.hw, @max(q.a[1], q.b[1]) + q.hw };
    return .{ lo[0], lo[1], hi[0], hi[1] };
}

fn viaQBox(q: ViaQ) [4]f64 {
    return .{ q.c[0] - q.vr, q.c[1] - q.vr, q.c[0] + q.vr, q.c[1] + q.vr };
}

// track ↔ board edge (staging-band exemption).
fn segEdgeViol(s: *const Session, q: SegQ) bool {
    const br = s.board_rect orelse return false;
    var worst = @min(boardInset(br, s.board_poly, q.a), boardInset(br, s.board_poly, q.b));
    if (s.board_poly) |pl| {
        if (worst > -(q.hw + drc.staging_exempt_mm)) {
            if (outline.segCrossesEdge(pl, q.a[0], q.a[1], q.b[0], q.b[1])) |_| worst = 0;
        }
    }
    if (worst < -(q.hw + drc.staging_exempt_mm)) return false; // staging band
    return (worst - q.hw) < s.edge_clr - eps_p;
}

// track ↔ foreign pads (layer-aware, shape-exact).
fn segPadViol(s: *Session, q: SegQ) bool {
    for (candidates(s, &s.pad_grid, segQBox(q), s.clr_max)) |j| {
        const p = s.pads[j];
        if (sameNet(q.net, p.net) or (!p.thru and p.layer != q.layer)) continue;
        const eff = s.rules.clearanceBetween(q.net, p.net, s.base_clr);
        const need = q.hw + eff;
        if (@min(q.a[0], q.b[0]) > p.x1 + need or @max(q.a[0], q.b[0]) < p.x0 - need or
            @min(q.a[1], q.b[1]) > p.y1 + need or @max(q.a[1], q.b[1]) < p.y0 - need) continue;
        const gap = segShapeDist(q.a, q.b, p, need) - q.hw;
        if (gap < eff - eps_p) return true;
    }
    return false;
}

// track ↔ foreign tracks (same layer).
fn segTrackViol(s: *Session, q: SegQ) bool {
    for (candidates(s, &s.track_grid, segQBox(q), s.clr_max)) |j| {
        const t = s.tracks[j];
        if (t.layer != q.layer or sameNet(q.net, t.net)) continue;
        const eff = s.rules.clearanceBetween(q.net, t.net, s.base_clr);
        const gap = segSegDist(q.a, q.b, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }) - q.hw - t.width / 2;
        if (gap < eff - eps_p) return true;
    }
    return false;
}

// track ↔ foreign vias (a via is thru — every layer, like drc's via↔track).
fn segViaViol(s: *Session, q: SegQ) bool {
    for (candidates(s, &s.via_grid, segQBox(q), s.clr_max)) |j| {
        const v = s.vias[j];
        if (sameNet(q.net, v.net)) continue;
        const eff = s.rules.clearanceBetween(q.net, v.net, s.base_clr);
        const gap = segPointDist(q.a, q.b, .{ v.x, v.y }) - v.dia / 2 - q.hw;
        if (gap < eff - eps_p) return true;
    }
    return false;
}

/// Would adding the candidate track `q` create a routing-class violation?
fn probeSeg(s: *Session, q: SegQ) bool {
    return segEdgeViol(s, q) or segPadViol(s, q) or segTrackViol(s, q) or segViaViol(s, q);
}

// via's own annular ring / min-drill (position-independent).
fn viaSelfViol(s: *const Session, q: ViaQ) bool {
    if (q.drill <= 0) return false;
    if (q.vr - q.drill / 2 < s.min_annular - eps_p) return true; // ring = radius − drill/2
    return q.drill < s.min_drill - eps_p;
}

// via ↔ board edge (staging-band exemption).
fn viaEdgeViol(s: *const Session, q: ViaQ) bool {
    const br = s.board_rect orelse return false;
    const inset = boardInset(br, s.board_poly, q.c);
    if (inset < -(q.vr + drc.staging_exempt_mm)) return false;
    return (inset - q.vr) < s.edge_clr - eps_p;
}

// via ↔ foreign pads / tracks / vias (all layers — a via is thru).
fn viaPadViol(s: *Session, q: ViaQ) bool {
    for (candidates(s, &s.pad_grid, viaQBox(q), s.clr_max)) |j| {
        const p = s.pads[j];
        if (sameNet(q.net, p.net)) continue;
        const eff = s.rules.clearanceBetween(q.net, p.net, s.base_clr);
        const gap = pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, q.c[0], q.c[1], q.vr + eff) - q.vr;
        if (gap < eff - eps_p) return true;
    }
    return false;
}

fn viaTrackViol(s: *Session, q: ViaQ) bool {
    for (candidates(s, &s.track_grid, viaQBox(q), s.clr_max)) |j| {
        const t = s.tracks[j];
        if (sameNet(q.net, t.net)) continue;
        const eff = s.rules.clearanceBetween(q.net, t.net, s.base_clr);
        const gap = segPointDist(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }, q.c) - q.vr - t.width / 2;
        if (gap < eff - eps_p) return true;
    }
    return false;
}

/// The spacing a candidate via owes an existing via of its OWN net: the
/// board's `(design-rules (via-to-via MM))` when authored, else the net's own
/// resolved clearance — the same rule `drc.viaSpacingRule` applies, so the live
/// hand-draw guard refuses exactly the copper the checker would flag
/// `via_spacing` rather than letting it land and reporting it afterwards.
fn viaSpacingRule(s: *const Session, net: i32) f64 {
    const declared = s.rules.design.via_to_via;
    return if (declared > 0) declared else s.rules.clearanceForNet(net, s.base_clr);
}

fn viaViaViol(s: *Session, q: ViaQ) bool {
    for (candidates(s, &s.via_grid, viaQBox(q), s.clr_max)) |j| {
        const v = s.vias[j];
        const eff = if (sameNet(q.net, v.net))
            viaSpacingRule(s, q.net)
        else
            s.rules.clearanceBetween(q.net, v.net, s.base_clr);
        const gap = std.math.hypot(q.c[0] - v.x, q.c[1] - v.y) - q.vr - v.dia / 2;
        if (gap < eff - eps_p) return true;
    }
    return false;
}

// via hole ↔ existing holes (drilled pads + vias).
fn viaHoleViol(s: *Session, q: ViaQ) bool {
    if (q.drill <= 0) return false;
    for (candidates(s, &s.hole_grid, viaQBox(q), s.hole_to_hole)) |j| {
        const h = s.holes[j];
        if (std.math.hypot(q.c[0] - h.x, q.c[1] - h.y) < eps_p) continue; // coincident barrel
        const wall = segSegDist(q.c, q.c, .{ h.x - h.shx, h.y - h.shy }, .{ h.x + h.shx, h.y + h.shy });
        const gap = wall - q.drill / 2 - h.drill / 2;
        if (gap < s.hole_to_hole - eps_p) return true;
    }
    return false;
}

/// Would adding the candidate via `q` create a routing-class violation?
fn probeVia(s: *Session, q: ViaQ) bool {
    return viaSelfViol(s, q) or viaEdgeViol(s, q) or viaPadViol(s, q) or
        viaTrackViol(s, q) or viaViaViol(s, q) or viaHoleViol(s, q);
}

/// Largest t in [0,1] with the prefix (q.a)→lerp(t) probe-clean (1 = fully legal,
/// 0 = the start violates). Prefix-violation is monotone, so bisection converges
/// to within `clip_tol_mm` along the segment; the clean bound is returned.
const clip_tol_mm: f64 = 0.01;
fn clipSeg(s: *Session, q: SegQ) f64 {
    if (!probeSeg(s, q)) return 1;
    if (probeSeg(s, segToEnd(q, q.a))) return 0;
    const dx = q.b[0] - q.a[0];
    const dy = q.b[1] - q.a[1];
    const len = std.math.hypot(dx, dy);
    var lo: f64 = 0; // known clean
    var hi: f64 = 1; // known violating
    var iter: usize = 0;
    while (iter < 40 and (hi - lo) * len > clip_tol_mm) : (iter += 1) {
        const mid = (lo + hi) / 2;
        const end = [2]f64{ q.a[0] + mid * dx, q.a[1] + mid * dy };
        if (probeSeg(s, segToEnd(q, end))) hi = mid else lo = mid;
    }
    return lo;
}

// ── Probe result wrappers ────────────────────────────────────────────────────
// A `ctx == null` sentinel (2 / -1) tells the caller "no session, use the JS
// fallback"; extracted so the exports stay thin and the sentinel is testable.
fn clampLayer(layer: u32) u8 {
    const cap: u32 = board_layers.max_sidecar_layer;
    return if (layer > cap) board_layers.max_sidecar_layer else @intCast(layer);
}

/// 0 = clean, 1 = violates, 2 = no session.
fn probeSegResult(ctx: ?*Session, q: SegQ) u32 {
    const s = ctx orelse return 2;
    return if (probeSeg(s, q)) 1 else 0;
}

/// 0 = clean, 1 = violates, 2 = no session.
fn probeViaResult(ctx: ?*Session, q: ViaQ) u32 {
    const s = ctx orelse return 2;
    return if (probeVia(s, q)) 1 else 0;
}

/// t in [0,1], or -1 = no session.
fn clipSegResult(ctx: ?*Session, q: SegQ) f64 {
    const s = ctx orelse return -1;
    return clipSeg(s, q);
}

// ── WASM C-ABI exports ───────────────────────────────────────────────────────

/// Process-lifetime session statics. `arena` backs the session AND its
/// `drc_load` response; reset (with `ctx` cleared first) only on a new load, so
/// probes never allocate and the session survives interleaved `drc_check` calls
/// (disjoint arenas). `probe_layer`/`probe_width` carry the leg geometry.
/// Analyzed only on wasm targets (the exports below are the sole references).
const Wasm = struct {
    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    var ctx: ?Session = null;
    var output: []const u8 = &.{};
    var probe_layer: u8 = 0;
    var probe_width: f64 = 0.2;
};

fn errorJson(arena: std.mem.Allocator, msg: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"oom\"}";
}
fn sessionHandle() ?*Session {
    return if (Wasm.ctx) |*p| p else null;
}
/// A candidate segment from the export's scalar coords + the stored geometry.
fn scalarSeg(x1: f64, y1: f64, x2: f64, y2: f64, net: i32) SegQ {
    return .{ .a = .{ x1, y1 }, .b = .{ x2, y2 }, .layer = Wasm.probe_layer, .net = net, .hw = Wasm.probe_width / 2 };
}

/// Load board-state JSON (same schema as `drc_check`) into a session, replacing
/// any prior one; return the response length (`{"ok":true,"nets":[…]}`, or
/// `{"error":…}`), read at `drc_session_output_ptr`.
fn drcLoad(ptr: [*]const u8, len: u32) callconv(.c) usize {
    Wasm.ctx = null; // invalidate before the reset frees the old session
    _ = Wasm.arena.reset(.retain_capacity);
    const a = Wasm.arena.allocator();
    if (buildSessionCtx(a, ptr[0..len])) |built| {
        Wasm.ctx = built;
        Wasm.output = sessionResponse(a, built.net_names) catch errorJson(a, "oom");
    } else |e| {
        Wasm.output = errorJson(a, @errorName(e));
    }
    return Wasm.output.len;
}

/// Offset of the last `drc_load` response (paired with its returned length).
fn drcSessionOutputPtr() callconv(.c) [*]const u8 {
    return Wasm.output.ptr;
}

/// Set the segment-probe geometry (layer + track width) — stable across a leg,
/// so a separate call keeps `drc_probe_seg`/`drc_clip_seg` under the param cap.
fn drcProbeGeom(layer: u32, width: f64) callconv(.c) void {
    Wasm.probe_layer = clampLayer(layer);
    Wasm.probe_width = width;
}

/// The track (x1,y1)-(x2,y2) on `net` at the `drc_probe_geom` geometry: 1 =
/// would create a routing-class violation, 0 = clean, 2 = no session (fallback).
fn drcProbeSeg(x1: f64, y1: f64, x2: f64, y2: f64, net: i32) callconv(.c) u32 {
    return probeSegResult(sessionHandle(), scalarSeg(x1, y1, x2, y2, net));
}

/// Largest violation-free prefix fraction t∈[0,1] of the candidate track; -1 = no session.
fn drcClipSeg(x1: f64, y1: f64, x2: f64, y2: f64, net: i32) callconv(.c) f64 {
    return clipSegResult(sessionHandle(), scalarSeg(x1, y1, x2, y2, net));
}

/// A via at (x,y) of `dia`/`drill`/`net`: 1 = violation, 0 = clean, 2 = no session.
fn drcProbeVia(x: f64, y: f64, dia: f64, drill: f64, net: i32) callconv(.c) u32 {
    return probeViaResult(sessionHandle(), .{ .c = .{ x, y }, .vr = dia / 2, .drill = drill, .net = net });
}

comptime {
    if (builtin.target.cpu.arch.isWasm()) {
        @export(&drcLoad, .{ .name = "drc_load" });
        @export(&drcSessionOutputPtr, .{ .name = "drc_session_output_ptr" });
        @export(&drcProbeGeom, .{ .name = "drc_probe_geom" });
        @export(&drcProbeSeg, .{ .name = "drc_probe_seg" });
        @export(&drcClipSeg, .{ .name = "drc_clip_seg" });
        @export(&drcProbeVia, .{ .name = "drc_probe_via" });
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────
// Each probe's oracle is the live-routing subset of a full `drc.check`: adding
// one feature only ADDS those violations, so `n(after) > n(base)` is exactly
// "the candidate creates a new routing-class violation" — what the probe must
// reproduce. Final-state topology rules (stub / single-layer via) are excluded:
// a hand route is necessarily open while it is being drawn. The board has three
// nets (SIG / GND / VCC, VCC widened by a net-class), one base track, one via.

const testing = std.testing;

const board_head =
    \\{"clearance":0.2,
    \\ "rules":{"min_drill":0.2,"min_annular":0.1,"hole_to_hole":0.25},
    \\ "netclasses":[{"net":"VCC","clearance":0.5}],
    \\ "board":{"x":-2,"y":-2,"w":14,"h":14},
    \\ "parts":[
    \\  {"ref":"R1","kind":"passive","hw":0.5,"hh":0.5,"x":0,"y":0,"side":"top","pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"net":"SIG"}]},
    \\  {"ref":"R2","kind":"passive","hw":0.5,"hh":0.5,"x":3,"y":0,"side":"top","pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"net":"GND"}]},
    \\  {"ref":"R3","kind":"passive","hw":0.5,"hh":0.5,"x":0,"y":3,"side":"top","pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"net":"VCC"}]}],
    \\ "tracks":[{"x1":3,"y1":3,"x2":5,"y2":3,"l":0,"w":0.2,"net":"GND"}
;
const board_mid =
    \\],
    \\ "vias":[{"x":5,"y":5,"d":0.4,"drill":0.2,"net":"VCC"}
;
const board_tail = "]}";

// The test board with optional candidate track / via fragments spliced in.
fn testBoard(arena: std.mem.Allocator, cand_track: []const u8, cand_via: []const u8) ![]const u8 {
    return std.mem.concat(arena, u8, &.{ board_head, cand_track, board_mid, cand_via, board_tail });
}
// The full-check violation count for a board JSON — the probe oracle.
fn drcCount(arena: std.mem.Allocator, json: []const u8) !usize {
    const board = try parseBoard(arena, json);
    const v = try drc.check(arena, board.placement, board.routed, board.clearance);
    var count: usize = 0;
    for (v) |violation| {
        if (violation.kind == .copper_stub or violation.kind == .dangling_copper or
            violation.kind == .single_layer_via or violation.kind == .redundant_via) continue;
        count += 1;
    }
    return count;
}
fn testNetIdx(names: []const []const u8, name: []const u8) i32 {
    for (names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
    return -1;
}
// A 0.2 mm (hw 0.1), layer-0 candidate segment on `net`, and a candidate via.
fn tSeg(x1: f64, y1: f64, x2: f64, y2: f64, net: i32) SegQ {
    return .{ .a = .{ x1, y1 }, .b = .{ x2, y2 }, .layer = 0, .net = net, .hw = 0.1 };
}
fn tVia(x: f64, y: f64, dia: f64, drill: f64, net: i32) ViaQ {
    return .{ .c = .{ x, y }, .vr = dia / 2, .drill = drill, .net = net };
}
// True when a session load errors (keeps the conditional out of the test body).
fn isLoadError(arena: std.mem.Allocator, json: []const u8) bool {
    _ = buildSessionCtx(arena, json) catch return true;
    return false;
}

const SegCase = struct { x1: f64, y1: f64, x2: f64, y2: f64, net: []const u8 };
const ViaCase = struct { x: f64, y: f64, dia: f64, drill: f64, net: []const u8 };

// spec: Web Server - The WASM DRC session load returns the board's net table for probe indexing
test "session load lists the board nets in first-appearance order" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const sess = try buildSessionCtx(arena, try testBoard(arena, "", ""));
    const resp = try sessionResponse(arena, sess.net_names);
    try testing.expectEqualStrings("{\"ok\":true,\"nets\":[\"SIG\",\"GND\",\"VCC\"]}", resp);
    try testing.expectEqual(@as(i32, 0), testNetIdx(sess.net_names, "SIG"));
    try testing.expectEqual(@as(i32, 1), testNetIdx(sess.net_names, "GND"));
    try testing.expectEqual(@as(i32, 2), testNetIdx(sess.net_names, "VCC"));
}

// spec: Web Server - The WASM DRC session segment probe matches a full drc.check for new routing-class violations
test "session segment probe agrees with a full drc.check over board+candidate" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var sess = try buildSessionCtx(arena, try testBoard(arena, "", ""));
    const base_n = try drcCount(arena, try testBoard(arena, "", ""));
    const cases = [_]SegCase{
        .{ .x1 = 3, .y1 = -5, .x2 = 3, .y2 = -1, .net = "GND" }, // off-board start (board edge)
        .{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .net = "GND" }, // through the SIG pad
        .{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .net = "SIG" }, // same net over the pad
        .{ .x1 = -0.15, .y1 = 0.5, .x2 = 0.15, .y2 = 0.5, .net = "GND" }, // boundary-exact clean
        .{ .x1 = -0.15, .y1 = 0.495, .x2 = 0.15, .y2 = 0.495, .net = "GND" }, // just inside → violate
        .{ .x1 = -0.15, .y1 = -2.05, .x2 = 0.15, .y2 = -2.05, .net = "GND" }, // just off the edge
        .{ .x1 = -0.15, .y1 = -50, .x2 = 0.15, .y2 = -50, .net = "GND" }, // staged off-board
        .{ .x1 = -0.15, .y1 = 3.65, .x2 = 0.15, .y2 = 3.65, .net = "GND" }, // VCC net-class clearance
        .{ .x1 = 3, .y1 = 3, .x2 = 5, .y2 = 3, .net = "SIG" }, // over the base GND track
    };
    for (cases) |c| {
        const tf = ",{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d}," ++ "\"l\":0,\"w\":0.2,\"net\":\"{s}\"}}";
        const frag = try std.fmt.allocPrint(arena, tf, .{ c.x1, c.y1, c.x2, c.y2, c.net });
        const after_n = try drcCount(arena, try testBoard(arena, frag, ""));
        const expected: u32 = if (after_n > base_n) 1 else 0;
        const idx = testNetIdx(sess.net_names, c.net);
        try testing.expectEqual(expected, probeSegResult(&sess, tSeg(c.x1, c.y1, c.x2, c.y2, idx)));
    }
}

// spec: Web Server - The WASM DRC session via probe matches a full drc.check for new routing-class violations
test "session via probe agrees with a full drc.check over board+candidate" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var sess = try buildSessionCtx(arena, try testBoard(arena, "", ""));
    const base_n = try drcCount(arena, try testBoard(arena, "", ""));
    const cases = [_]ViaCase{
        .{ .x = 8, .y = 8, .dia = 0.4, .drill = 0.2, .net = "GND" }, // clean, far
        .{ .x = 0, .y = 0, .dia = 0.4, .drill = 0.2, .net = "GND" }, // on the SIG pad
        .{ .x = 0, .y = 0, .dia = 0.4, .drill = 0.2, .net = "SIG" }, // same net on the pad
        .{ .x = 8, .y = 8, .dia = 0.3, .drill = 0.25, .net = "GND" }, // thin annular ring
        .{ .x = 8, .y = 8, .dia = 0.4, .drill = 0.1, .net = "GND" }, // under min-drill
        .{ .x = 5.2, .y = 5, .dia = 0.4, .drill = 0.2, .net = "GND" }, // near the base VCC via
        .{ .x = 4, .y = 3, .dia = 0.4, .drill = 0.2, .net = "SIG" }, // on the base GND track
    };
    for (cases) |c| {
        const vf = ",{{\"x\":{d},\"y\":{d},\"d\":{d},\"drill\":{d},\"net\":\"{s}\"}}";
        const frag = try std.fmt.allocPrint(arena, vf, .{ c.x, c.y, c.dia, c.drill, c.net });
        const after_n = try drcCount(arena, try testBoard(arena, "", frag));
        const expected: u32 = if (after_n > base_n) 1 else 0;
        const idx = testNetIdx(sess.net_names, c.net);
        try testing.expectEqual(expected, probeViaResult(&sess, tVia(c.x, c.y, c.dia, c.drill, idx)));
    }
}

// spec: Web Server - The WASM DRC session via probe refuses a via crowding an existing same-net via, matching the checker's via-spacing rule
test "session via probe refuses a duplicate barrel on its own net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var sess = try buildSessionCtx(arena, try testBoard(arena, "", ""));
    const vcc = testNetIdx(sess.net_names, "VCC");
    // The board already carries a VCC via at (5,5). VCC's class asks 0.5 mm of
    // clearance, so its own barrels owe each other that much copper: a second
    // one 0.2 mm along is a duplicate drill and the live guard refuses it, the
    // same verdict the checker's `via_spacing` rule reaches.
    try testing.expectEqual(@as(u32, 1), probeViaResult(&sess, tVia(5.2, 5, 0.4, 0.2, vcc)));
    const base_n = try drcCount(arena, try testBoard(arena, "", ""));
    const dup = ",{\"x\":5.2,\"y\":5,\"d\":0.4,\"drill\":0.2,\"net\":\"VCC\"}";
    try testing.expect((try drcCount(arena, try testBoard(arena, "", dup))) > base_n);
    // One resting exactly ON the rule (0.4 mm of copper + 0.5 mm gap) is legal,
    // and so is a stitch-fence pitch — the guard polices duplicates, not reuse.
    try testing.expectEqual(@as(u32, 0), probeViaResult(&sess, tVia(5.9, 5, 0.4, 0.2, vcc)));
    try testing.expectEqual(@as(u32, 0), probeViaResult(&sess, tVia(6.5, 5, 0.4, 0.2, vcc)));
}

// spec: Web Server - The WASM DRC session segment clip returns the largest violation-free prefix fraction
test "session clip returns a clean prefix that violates just beyond it" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var sess = try buildSessionCtx(arena, try testBoard(arena, "", ""));
    const idx = testNetIdx(sess.net_names, "GND");
    // A GND track driving from (-1.5,0) — clear of the board edge — into R1's SIG
    // pad centre: the clean prefix ends at the pad clearance ring, between the ends.
    const t = clipSegResult(&sess, tSeg(-1.5, 0, 0, 0, idx));
    try testing.expect(t > 0 and t < 1);
    const tol_t = clip_tol_mm / 1.5; // segment length is 1.5 mm
    try testing.expectEqual(@as(u32, 0), probeSegResult(&sess, tSeg(-1.5, 0, -1.5 + t * 1.5, 0, idx)));
    const beyond = @min(1.0, t + 2 * tol_t);
    try testing.expectEqual(@as(u32, 1), probeSegResult(&sess, tSeg(-1.5, 0, -1.5 + beyond * 1.5, 0, idx)));
    // A clean candidate (well inside, far from copper) clips to the full length.
    try testing.expectEqual(@as(f64, 1), clipSegResult(&sess, tSeg(6, 6, 7, 7, idx)));
}

// spec: Web Server - Loading a new board replaces the WASM DRC session so probes answer against the current state
test "reloading the session replaces the board state" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const parts =
        \\ "parts":[
        \\  {"ref":"R1","kind":"passive","hw":0.5,"hh":0.5,"x":0,"y":0,"side":"top","pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"net":"SIG"}]},
        \\  {"ref":"R2","kind":"passive","hw":0.5,"hh":0.5,"x":3,"y":0,"side":"top","pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"net":"GND"}]}]
    ;
    const head = "{\"clearance\":0.2,\"board\":{\"x\":-3,\"y\":-3,\"w\":8,\"h\":8}," ++ parts;
    // Board A carries a GND track; a SIG candidate over it is a track↔track clash.
    const board_a = head ++ ",\"tracks\":[{\"x1\":-1,\"y1\":-1,\"x2\":1,\"y2\":-1,\"l\":0,\"w\":0.2,\"net\":\"GND\"}]}";
    const board_b = head ++ "}"; // same, no track → the candidate is now clean

    var sa = try buildSessionCtx(arena, board_a);
    const ia = testNetIdx(sa.net_names, "SIG");
    try testing.expectEqual(@as(u32, 1), probeSegResult(&sa, tSeg(-1, -1, 1, -1, ia)));
    var sb = try buildSessionCtx(arena, board_b);
    const ib = testNetIdx(sb.net_names, "SIG");
    try testing.expectEqual(@as(u32, 0), probeSegResult(&sb, tSeg(-1, -1, 1, -1, ib)));
}

test "session preserves pad transition fields from net-class JSON" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const board =
        \\{"netclasses":[{"net":"RF","width":0.4,"max_freq_hz":12000000000,"impedance_ohms":50,
        \\ "pad_neck_width":0.2,"pad_neck_max_length":0.75,"pad_neck_taper_length":0.35}],
        \\ "parts":[{"ref":"U1","kind":"hub","hw":1,"hh":1,"x":0,"y":0,"side":"top",
        \\ "pads":[{"num":"1","x":0,"y":0,"w":0.6,"h":0.2,"net":"RF"}]}]}
    ;
    const sess = try buildSessionCtx(arena, board);
    const idx: usize = @intCast(testNetIdx(sess.net_names, "RF"));
    const rule = sess.rules.net[idx];
    try testing.expectEqual(@as(f64, 0.2), rule.pad_neck.width);
    try testing.expectEqual(@as(f64, 0.75), rule.pad_neck.max_length);
    try testing.expectEqual(@as(f64, 0.35), rule.pad_neck.taper_length);
    try testing.expectEqual(@as(f64, 12e9), rule.rf.max_freq_hz);
    try testing.expectEqual(@as(f64, 50), rule.rf.impedance.ohms);
}

// spec: Web Server - Both client DRC bridges read the blob's design-rule object through one shared reader, so the stateless check and the session probe resolve identical board rules
test "the shared design-rule reader maps every design-rule key the blob carries" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Every key set to a distinct non-default value, so a field wired to the
    // wrong key cannot pass by coincidence. `wasm_drc.zig` calls THIS function,
    // so this pins both client bridges at once.
    const src =
        \\{"clearance":0.2,"min_drill":0.3,"min_annular":0.15,"hole_to_hole":0.35,
        \\ "via_to_via":0.45,"mask_margin":0.06,"mask_web":0.22,"min_width":0.12,
        \\ "pour_min_width":0.35,"pour_corner_radius":0.45,"ground_via_max":1.1,"copper_edge":0.55,
        \\ "component_edge":1.25,"pour_clearance":0.9,"pour_clearance_outer":0.95,"mask_relief_corner_radius":0.8}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, src, .{});
    defer parsed.deinit();
    const r = buildDesignRules(parsed.value);

    try testing.expectEqual(@as(f64, 0.2), r.clearance);
    try testing.expectEqual(@as(f64, 0.3), r.min_drill);
    try testing.expectEqual(@as(f64, 0.15), r.min_annular);
    try testing.expectEqual(@as(f64, 0.35), r.hole_to_hole);
    try testing.expectEqual(@as(f64, 0.45), r.via_to_via);
    try testing.expectEqual(@as(f64, 0.06), r.mask.margin);
    try testing.expectEqual(@as(f64, 0.22), r.mask.web);
    try testing.expectEqual(@as(f64, 0.12), r.min_width);
    try testing.expectEqual(@as(f64, 0.35), r.pour.min_width);
    try testing.expectEqual(@as(f64, 0.45), r.pour.corner_radius);
    try testing.expectEqual(@as(f64, 1.1), r.pour.ground_via_max);
    try testing.expectEqual(@as(f64, 0.55), r.edge.copper);
    try testing.expectEqual(@as(f64, 1.25), r.edge.component);

    // These two were the gap this test pinned when it was written: the server
    // emits them into the same object and neither reader read them back, so a
    // design authoring `(design-rules (pour-clearance 0.15))` left the client's
    // struct holding the compile-time 0.3. Closing it turned out NOT to be the
    // behaviour change the pin feared — no check on either bridge consults
    // either field (see `buildDesignRules`) — so it is a struct that stopped
    // misstating the board, not a client that started reporting differently.
    try testing.expectEqual(@as(f64, 0.9), r.pour_clearance);
    // The outer-face twin rides the same wire and the same argument: the server
    // resolves it (an authored `(pour-clearance …)` sets it, else it defaults
    // tighter than the inner gap), so a client that failed to read it back
    // would hold the compile-time 0.2 on a board that authored something else.
    try testing.expectEqual(@as(f64, 0.95), r.pour.clearance_outer);
    try testing.expectEqual(@as(f64, 0.8), r.mask.relief_corner_radius);
}

// spec: Web Server - A design-rule key absent from the page blob falls back to its built-in default, so a dropped key cannot read as zero
test "a design-rule key missing from the blob keeps its built-in default" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // With every key the emitter writes now mapped, the test above no longer
    // exercises the fallback at all — an unread key used to stand in for it.
    // `pour_clearance` is the one that makes this worth its own test: its
    // default is a NON-ZERO 0.3, so a fallback that resolved to the zero value
    // would hand the client a pour gap no fab can hold, and would do it
    // silently, on exactly the boards that authored no rule of their own.
    const bare = buildDesignRules(null);
    try testing.expectEqual(@as(f64, 0.3), bare.pour_clearance);
    try testing.expectEqual(@as(f64, 0.2), bare.pour.clearance_outer);
    try testing.expectEqual(@as(f64, 0), bare.mask.relief_corner_radius);

    // A present-but-partial object takes the same path per absent key, rather
    // than only the all-or-nothing one above.
    var partial = try std.json.parseFromSlice(std.json.Value, arena, "{\"clearance\":0.2}", .{});
    defer partial.deinit();
    const p = buildDesignRules(partial.value);
    try testing.expectEqual(@as(f64, 0.2), p.clearance);
    try testing.expectEqual(@as(f64, 0.3), p.pour_clearance);
    try testing.expectEqual(@as(f64, 0.2), p.pour.clearance_outer);
    try testing.expectEqual(@as(f64, 0), p.mask.relief_corner_radius);
}

// spec: Web Server - A WASM DRC probe with no loaded session returns the no-session sentinel
test "probes without a session return the no-session sentinel and bad loads error" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Null handle → sentinel (2 for probes, -1 for clip): the JS reads non-0/1
    // (and t<0) as "fall back to the JS gate".
    try testing.expectEqual(@as(u32, 2), probeSegResult(null, tSeg(0, 0, 1, 0, -1)));
    try testing.expectEqual(@as(u32, 2), probeViaResult(null, tVia(0, 0, 0.4, 0.2, -1)));
    try testing.expectEqual(@as(f64, -1), clipSegResult(null, tSeg(0, 0, 1, 0, -1)));

    // A malformed load errors (the wasm path then leaves ctx null → sentinel).
    try testing.expect(isLoadError(arena, "{not json"));
}
