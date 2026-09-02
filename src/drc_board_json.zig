//! The board-state JSON the browser hands the client DRC, parsed ONCE.
//!
//! Both client bridges read the SAME payload out of the SAME `/pcb-layout` page
//! blob, written by one server emitter: `wasm_drc.zig` re-parses it per
//! `drc_check` (the stateless post-route check) and `drc_session.zig` parses it
//! per `drc_load` (the persistent mid-drag probe session). They used to carry
//! two hand-written parsers, and the session's header said the copy was
//! deliberate — `placement/drc.zig` is at its file-size cap with its helpers
//! private, so a shared seam looked impossible.
//!
//! It was not: a shared parser is its own module, and the pub-api snapshot that
//! the copy's rationale named as forbidding one is a reviewed accept, not a
//! prohibition. The copy cost exactly what a copy costs. Between 2026-07 and
//! 2026-08 the stateless parser gained `class` (net-class identity),
//! `power_branch_width`, `keepout_mm` and `keepout_escape_mm` on the net rule,
//! pad `shape`/`rratio`, and footprint silkscreen; the session's copy gained
//! none of them, so the mid-drag hand-route gate ran with no RF keepout rule
//! and no class identity while the post-route check on the same board applied
//! both. Nothing in the compiler could see it — no shared type, no shared call.
//!
//! One parser now, carrying every field the blob defines. A reader that both
//! bridges share cannot drift from itself; a key added here reaches both.
//!
//! Every string is a slice into the caller's `input` unless `Options.copy_strings`
//! asks otherwise — the session needs owned copies because it outlives the buffer
//! its JSON arrived in, while the stateless check finishes inside one call.

const std = @import("std");

const env = @import("eval/env.zig");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const diff_pairs = @import("placement/diff_pairs.zig");
const geometry = @import("placement/geometry.zig");
const outline = @import("placement/outline.zig");
const drc = @import("placement/drc.zig");
const rf_port_report = @import("placement/rf_port_report.zig");
const rf_path_solver = @import("placement/rf_path_solver.zig");
const export_kicad = @import("export_kicad.zig");
const board_layers = @import("board_layers.zig");
const numeric = @import("numeric.zig");

const FlatNet = export_kicad.FlatNet;
const FlatPin = export_kicad.FlatPin;

/// The `clearance` member of an object — the key recurs at every level of the
/// input (top-level board default, `rules`, each net-class entry), so the
/// lookup lives here to keep the spelling single-sourced.
fn clearanceVal(o: std.json.ObjectMap) ?std.json.Value {
    return o.get("clearance");
}

// ── JSON scalar readers (default-tolerant) ───────────────────────────────────
//
// Tag tests use `val == .tag` (not a `switch`) throughout: these one-armed
// dispatches would otherwise be byte-identical to the JSON readers in every
// other module, and the point is a self-contained default-tolerant reader, not
// a shared abstraction.

/// A JSON value as f64; `dflt` when absent or non-numeric. Covers the integer,
/// float, and (rare, out-of-range/arbitrary-precision) number_string encodings.
fn numOr(v: ?std.json.Value, dflt: f64) f64 {
    const val = v orelse return dflt;
    if (val == .integer) return @floatFromInt(val.integer);
    if (val == .float) return val.float;
    if (val == .number_string) return std.fmt.parseFloat(f64, val.number_string) catch dflt;
    return dflt;
}

/// A JSON number as f64, 0 when absent/non-numeric.
fn jNum(v: ?std.json.Value) f64 {
    return numOr(v, 0);
}

/// A JSON string, "" when absent/non-string.
fn jStr(v: ?std.json.Value) []const u8 {
    const val = v orelse return "";
    return if (val == .string) val.string else "";
}

/// A JSON string, or NULL when absent/non-string/empty — for a field whose
/// absence is a distinct answer (`implicit_rail`: "this block planed no rail").
fn jStrOpt(v: ?std.json.Value) ?[]const u8 {
    const s = jStr(v);
    return if (s.len > 0) s else null;
}

/// A JSON bool, false when absent/non-bool.
fn jFlag(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return val == .bool and val.bool;
}

/// The value as an object map, or null when absent/other-typed.
fn objOf(v: ?std.json.Value) ?std.json.ObjectMap {
    const val = v orelse return null;
    return if (val == .object) val.object else null;
}

/// The value as an array, or null when absent/other-typed.
fn arrOf(v: ?std.json.Value) ?std.json.Array {
    const val = v orelse return null;
    return if (val == .array) val.array else null;
}

/// A JSON `l` field → signal-layer index (0 top, 1 bottom, 2.. inner), clamped
/// at the SHARED sidecar ceiling; absent/<1 ⇒ 0, mirroring the sidecar's
/// `layerIndexFromJson` byte for byte (same constant, so client and server can
/// never clamp a corrupt index to different layers).
fn layerOf(v: ?std.json.Value) u8 {
    const n = jNum(v);
    if (!(n >= 1)) return 0;
    if (n >= board_layers.max_sidecar_layer) return board_layers.max_sidecar_layer;
    return numeric.checkedInt(u8, @floor(n)) orelse 0;
}

/// The board's copper stack from the marshalled `layer_table` (one row per
/// PHYSICAL layer, top→bottom). Returns the total copper count and the DECLARED
/// plane entries, so the client engine's layer arithmetic — `signalLayerCount`,
/// `signalLayerName`, `signalIndexOfName` — matches the server's instead of
/// silently assuming the legacy implicit four-layer board on every design.
/// Absent table ⇒ `{0, &.{}}`, which IS the implicit model, so an older blob
/// checks exactly as it did before.
fn buildStack(arena: std.mem.Allocator, v: ?std.json.Value) !struct { layers: u8, planes: []const optimizer.PlaneAt } {
    const arr = arrOf(v) orelse return .{ .layers = 0, .planes = &.{} };
    var planes: std.ArrayList(optimizer.PlaneAt) = .empty;
    for (arr.items) |item| {
        const o = objOf(item) orelse continue;
        if (!std.mem.eql(u8, jStr(o.get("kind")), "plane")) continue;
        const index = numeric.checkedInt(u8, @floor(jNum(o.get("i")))) orelse continue;
        try planes.append(arena, .{ .index = index, .net = jStr(o.get("net")) });
    }
    return .{
        .layers = std.math.cast(u8, arr.items.len) orelse 0,
        .planes = try planes.toOwnedSlice(arena),
    };
}

// ── Net-name table ───────────────────────────────────────────────────────────

/// Interns net-name strings to dense indices in first-appearance order and
/// groups the pads (`ref|pin`) that land on each, so the built `FlatNet[]`
/// satisfies exactly the `refdes|pin`→index lookup `drc.padBoxes` performs.
/// Track/via net strings resolve to the same indices, keeping `sameNet`
/// comparisons across pads and copper internally consistent.
const NetTable = struct {
    names: std.ArrayList([]const u8) = .empty,
    index_of: std.StringHashMapUnmanaged(u32) = .empty,
    pins: std.ArrayList(std.ArrayList(FlatPin)) = .empty,

    /// Index of `name`, appending a fresh (empty-pin) net when first seen.
    fn intern(self: *NetTable, arena: std.mem.Allocator, name: []const u8) !u32 {
        if (self.index_of.get(name)) |i| return i;
        const i: u32 = @intCast(self.names.items.len);
        try self.names.append(arena, name);
        try self.pins.append(arena, .empty);
        try self.index_of.put(arena, name, i);
        return i;
    }

    /// Bind pad `ref|pin` to `name`'s net (a no-op for the empty/no-net string).
    fn addPin(self: *NetTable, arena: std.mem.Allocator, name: []const u8, ref: []const u8, pin: []const u8) !void {
        if (name.len == 0) return;
        const i = try self.intern(arena, name);
        try self.pins.items[i].append(arena, .{ .ref_des = ref, .pin = pin });
    }

    /// Net index for a copper feature; -1 (drc's "no net" sentinel) for "".
    fn featureNet(self: *NetTable, arena: std.mem.Allocator, name: []const u8) !i32 {
        if (name.len == 0) return -1;
        return @intCast(try self.intern(arena, name));
    }

    /// Materialize the interned nets as `FlatNet[]` (index-aligned with the
    /// dense indices handed out above).
    fn flatNets(self: *NetTable, arena: std.mem.Allocator) ![]const FlatNet {
        const out = try arena.alloc(FlatNet, self.names.items.len);
        for (out, 0..) |*net, i| {
            net.* = .{ .name = self.names.items[i], .pins = try self.pins.items[i].toOwnedSlice(arena) };
        }
        return out;
    }
};

// ── Geometry builders ────────────────────────────────────────────────────────

/// A `[[x,y],…]` JSON array → an owned point list (short/other-typed entries
/// skipped). Shared by pad outlines and the board polygon.
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

/// A `[[[x,y],...],...]` JSON array to owned hole contours. Degenerate holes
/// are harmless here: `copper_support.zoneContains` applies the same polygon
/// predicate as it does to an outer contour, and an empty/short one contains
/// no point.
fn buildHoles(arena: std.mem.Allocator, v: ?std.json.Value) ![]const []const [2]f64 {
    const arr = arrOf(v) orelse return &.{};
    var list: std.ArrayList([]const [2]f64) = .empty;
    for (arr.items) |it| try list.append(arena, try buildPoly(arena, it));
    return list.toOwnedSlice(arena);
}

/// Fabricated/user copper regions marshalled by `drc_marshal.js`. Each contour
/// carries a non-zero component id so the topology graph keeps disconnected
/// islands distinct. Dedicated plane contours additionally carry `plane=true`:
/// a barrel reaches them, while a same-layer signal trace does not.
fn buildTopologyZones(arena: std.mem.Allocator, v: ?std.json.Value, nettab: *NetTable) ![]const drc.TopologyZone {
    const arr = arrOf(v) orelse return &.{};
    var list: std.ArrayList(drc.TopologyZone) = .empty;
    for (arr.items, 0..) |it, i| {
        const o = objOf(it) orelse continue;
        const net = jStr(o.get("net"));
        const poly = try buildPoly(arena, o.get("poly"));
        if (net.len == 0 or poly.len < 3) continue;
        _ = try nettab.intern(arena, net);
        try list.append(arena, .{
            .net = net,
            .layer = layerOf(o.get("l")),
            .stack = numeric.checkedInt(u8, @floor(jNum(o.get("stack")))) orelse 0,
            .poly = poly,
            .holes = try buildHoles(arena, o.get("holes")),
            .priority = numeric.checkedInt(i64, @floor(jNum(o.get("priority")))) orelse 0,
            // JSON rows are zero-based, while zero means "unknown component"
            // to the topology engine.
            .component = @as(u64, @intCast(i)) + 1,
            .plane = jFlag(o.get("plane")),
        });
    }
    return list.toOwnedSlice(arena);
}

/// A pad's oval-slot half-vector: a `[a,b]` array → `{a,b}`, a bare number →
/// `{n,0}`, absent → `{0,0}` (round bore). Tolerant of the exact spelling the
/// blob writer settles on.
fn buildSlotHalf(v: ?std.json.Value) [2]f64 {
    if (arrOf(v)) |a| return .{
        if (a.items.len > 0) jNum(a.items[0]) else 0,
        if (a.items.len > 1) jNum(a.items[1]) else 0,
    };
    return .{ jNum(v), 0 };
}

/// A part's `silk` object → footprint silk lines (`l`: 4-tuples) + circles
/// (`c`: 3-tuples), matching the blob's `{"l":[[x1,y1,x2,y2],…],"c":[[cx,cy,r],…]}`.
const Silk = struct { lines: []const geometry.SilkLine, circles: []const geometry.SilkCircle };
fn buildSilk(arena: std.mem.Allocator, v: ?std.json.Value) !Silk {
    var lines: std.ArrayList(geometry.SilkLine) = .empty;
    var circles: std.ArrayList(geometry.SilkCircle) = .empty;
    if (objOf(v)) |o| {
        if (arrOf(o.get("l"))) |la| for (la.items) |it| {
            const q = arrOf(it) orelse continue;
            if (q.items.len < 4) continue;
            try lines.append(arena, .{
                .x1 = jNum(q.items[0]),
                .y1 = jNum(q.items[1]),
                .x2 = jNum(q.items[2]),
                .y2 = jNum(q.items[3]),
            });
        };
        if (arrOf(o.get("c"))) |ca| for (ca.items) |it| {
            const q = arrOf(it) orelse continue;
            if (q.items.len < 3) continue;
            try circles.append(arena, .{ .cx = jNum(q.items[0]), .cy = jNum(q.items[1]), .r = jNum(q.items[2]) });
        };
    }
    return .{ .lines = try lines.toOwnedSlice(arena), .circles = try circles.toOwnedSlice(arena) };
}

/// One part's `pads` array → `geometry.Pad[]`, registering each pad's `ref|pin`
/// onto its net so the DRC's pad→net lookup resolves.
fn buildPads(arena: std.mem.Allocator, v: ?std.json.Value, ref: []const u8, nettab: *NetTable) ![]const geometry.Pad {
    var list: std.ArrayList(geometry.Pad) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        const num = jStr(o.get("num"));
        try nettab.addPin(arena, jStr(o.get("net")), ref, num);
        const shape = jStr(o.get("shape"));
        try list.append(arena, .{
            .number = num,
            .x = jNum(o.get("x")),
            .y = jNum(o.get("y")),
            .w = jNum(o.get("w")),
            .h = jNum(o.get("h")),
            .shape = if (shape.len == 0) "rect" else shape,
            .poly = try buildPoly(arena, o.get("poly")),
            .thru = jFlag(o.get("thru")),
            .npth = jFlag(o.get("npth")),
            .drill = jNum(o.get("drill")),
            .slot_half = buildSlotHalf(o.get("slot_half")),
            .rot = jNum(o.get("rot")),
            .overrides = .{ .rratio = jNum(o.get("rratio")) },
        });
    }
    return list.toOwnedSlice(arena);
}

/// The `parts` array → `optimizer.Part[]` (mutable, as `Placement.parts` wants).
fn buildParts(arena: std.mem.Allocator, v: ?std.json.Value, nettab: *NetTable) ![]optimizer.Part {
    var list: std.ArrayList(optimizer.Part) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        const ref = jStr(o.get("ref"));
        const silk = try buildSilk(arena, o.get("silk"));
        try list.append(arena, .{
            .ref_des = ref,
            .kind = if (std.mem.eql(u8, jStr(o.get("kind")), "hub")) .hub else .passive,
            .hw = jNum(o.get("hw")),
            .hh = jNum(o.get("hh")),
            .ccx = jNum(o.get("ccx")),
            .ccy = jNum(o.get("ccy")),
            .pads = try buildPads(arena, o.get("pads"), ref, nettab),
            .fallback = false,
            .features = .{ .silk_lines = silk.lines, .silk_circles = silk.circles },
            .x = jNum(o.get("x")),
            .y = jNum(o.get("y")),
            .rot = jNum(o.get("rot")),
            .side = if (std.mem.eql(u8, jStr(o.get("side")), "bottom")) .bottom else .top,
        });
    }
    return list.toOwnedSlice(arena);
}

/// The `tracks` array → `router.Track[]`, each net string resolved through the
/// shared name table.
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

/// The `rf_paths` array → solved RF port outcomes, one per marshalled centreline
/// (samples arrive as `[x, y, width]` triples and the arc length is accumulated
/// here). Runs shorter than two samples describe no path and are skipped.
fn buildRfPaths(arena: std.mem.Allocator, v: ?std.json.Value, nettab: *NetTable) ![]const rf_port_report.Outcome {
    var list: std.ArrayList(rf_port_report.Outcome) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        var samples: std.ArrayList(rf_path_solver.Sample) = .empty;
        const raw = arrOf(o.get("samples")) orelse continue;
        var previous: ?[2]f64 = null;
        var s_mm: f64 = 0;
        for (raw.items) |sample| {
            const q = arrOf(sample) orelse continue;
            if (q.items.len < 3) continue;
            const at = [2]f64{ jNum(q.items[0]), jNum(q.items[1]) };
            if (previous) |before| s_mm += std.math.hypot(at[0] - before[0], at[1] - before[1]);
            try samples.append(arena, .{ .at = at, .s_mm = s_mm, .curvature = 0, .width_mm = jNum(q.items[2]) });
            previous = at;
        }
        if (samples.items.len < 2) continue;
        try list.append(arena, .{
            .net = try nettab.featureNet(arena, jStr(o.get("net"))),
            .chosen = 0,
            .feasible = true,
            .success = true,
            .metrics = .{},
            .trials = &.{},
            .physical = .{ .sample_count = samples.items.len, .samples = try samples.toOwnedSlice(arena), .layer = layerOf(o.get("l")) },
        });
    }
    return list.toOwnedSlice(arena);
}

/// The `vias` array → `router.Via[]`.
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

// ── Rules builders ───────────────────────────────────────────────────────────

/// The `rules` object → `optimizer.DesignRules` (absent keys keep defaults).
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
fn buildDesignRules(v: ?std.json.Value) optimizer.DesignRules {
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

/// One `(net-class …)` override keyed by its resolved net index.
const NetClassOverride = struct { idx: u32, rule: optimizer.NetRule };

/// The `netclasses` array → per-net overrides; interns each named net so its
/// index exists in the table even when no copper carries it.
fn buildNetClassOverrides(arena: std.mem.Allocator, v: ?std.json.Value, nettab: *NetTable) ![]const NetClassOverride {
    var list: std.ArrayList(NetClassOverride) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        const name = jStr(o.get("net"));
        if (name.len == 0) continue;
        try list.append(arena, .{
            .idx = try nettab.intern(arena, name),
            .rule = .{
                // Class identity, so the client applies the same same-class
                // keepout exemption the server does: a class's own members are
                // one signal family and owe each other no halo. Absent (an older
                // page blob) reads as unclassed, which enforces the halo as
                // before rather than silently waiving it.
                .class = .{ .name = jStr(o.get("class")) },
                .width = jNum(o.get("width")),
                .clearance = jNum(clearanceVal(o)),
                .via_dia = jNum(o.get("via_dia")),
                .via_drill = jNum(o.get("via_drill")),
                .pad_neck = .{
                    .width = jNum(o.get("pad_neck_width")),
                    .max_length = jNum(o.get("pad_neck_max_length")),
                    .taper_length = jNum(o.get("pad_neck_taper_length")),
                    .power_branch_width = jNum(o.get("power_branch_width")),
                },
                // The resolved RF same-layer keepout halo + its pad-escape
                // exemption. Both must cross the bridge or the client silently
                // under-reports `keepout_violation` forever — the server would flag
                // an intrusion the browser's per-edit check never sees.
                .rf = .{
                    .max_freq_hz = jNum(o.get("max_freq_hz")),
                    .keepout_mm = jNum(o.get("keepout_mm")),
                    .keepout_escape_mm = jNum(o.get("keepout_escape_mm")),
                    .impedance = .{
                        .ohms = jNum(o.get("impedance_ohms")),
                        .diff_ohms = jNum(o.get("diff_impedance_ohms")),
                    },
                },
            },
        });
    }
    return list.toOwnedSlice(arena);
}

/// The index-aligned `NetRule[]` (length `n`, the final net count) from the
/// collected overrides — empty when none, so the DRC's net-class path is a
/// byte-identical no-op for boards that declare no classes.
fn buildNetRules(arena: std.mem.Allocator, overrides: []const NetClassOverride, n: usize) ![]const optimizer.NetRule {
    if (overrides.len == 0) return &.{};
    const rules = try arena.alloc(optimizer.NetRule, n);
    for (rules) |*r| r.* = .{};
    for (overrides) |ov| if (ov.idx < n) {
        rules[ov.idx] = ov.rule;
    };
    return rules;
}

/// The `diffpairs` array → `DiffPair[]`, interning each net name so its index
/// exists in the table (matching the pair indices to the copper's interned
/// nets). Net names arrive dot-collapsed from `drc_marshal.js`, exactly like
/// track/via nets, so a pair binds to the same interned net as its copper.
fn buildDiffPairs(arena: std.mem.Allocator, v: ?std.json.Value, nettab: *NetTable) ![]const diff_pairs.DiffPair {
    var list: std.ArrayList(diff_pairs.DiffPair) = .empty;
    const arr = arrOf(v) orelse return &.{};
    for (arr.items) |it| {
        const o = objOf(it) orelse continue;
        const p_name = jStr(o.get("p"));
        const n_name = jStr(o.get("n"));
        if (p_name.len == 0 or n_name.len == 0) continue;
        const pi = try nettab.intern(arena, p_name);
        const ni = try nettab.intern(arena, n_name);
        try list.append(arena, .{ .p = pi, .n = ni, .gap = jNum(o.get("gap")) });
    }
    return list.toOwnedSlice(arena);
}

/// A JSON string array → `[]const []const u8`, or NULL when the key is absent.
/// Null vs. empty is load-bearing for `planes`: `BoardRules.plane_nets == null`
/// means "no `(stackup …)` form", under which every ground-named net counts as
/// plane-carried — exactly what the RF keepout's exemption predicate reads. An
/// empty array means "a stackup that pours nothing".
fn buildStrings(arena: std.mem.Allocator, v: ?std.json.Value) !?[]const []const u8 {
    const arr = arrOf(v) orelse return null;
    var list: std.ArrayList([]const u8) = .empty;
    for (arr.items) |it| {
        const s = jStr(it);
        if (s.len > 0) try list.append(arena, s);
    }
    return try list.toOwnedSlice(arena);
}

/// The `board` object → a `BoardRect`, or null when absent/degenerate.
fn buildBoardRect(v: ?std.json.Value) ?optimizer.BoardRect {
    const o = objOf(v) orelse return null;
    const w = jNum(o.get("w"));
    const h = jNum(o.get("h"));
    if (!(w > 0) or !(h > 0)) return null;
    return .{ .minx = jNum(o.get("x")), .miny = jNum(o.get("y")), .w = w, .h = h };
}

fn stringListHas(v: ?std.json.Value, wanted: []const u8) bool {
    const arr = arrOf(v) orelse return false;
    for (arr.items) |item| if (std.mem.eql(u8, jStr(item), wanted)) return true;
    return false;
}

/// The first fixed perimeter entry in the generic `keepouts` array → the same
/// board rule the server DRC reads. Older blobs carry no array and stay inert.
fn buildPerimeterFence(arena: std.mem.Allocator, v: ?std.json.Value) !env.PerimeterFenceSpec {
    const arr = arrOf(v) orelse return .{};
    for (arr.items) |item| {
        const o = objOf(item) orelse continue;
        if (!std.mem.eql(u8, jStr(o.get("kind")), "perimeter")) continue;
        return .{
            .via_dia = jNum(o.get("via_dia")),
            .via_drill = jNum(o.get("via_drill")),
            .spacing = 1,
            .edge_offset = jNum(o.get("edge_offset")),
            .keepout = .{
                .clearance = jNum(clearanceVal(o)),
                .blocks = .{
                    .components = stringListHas(o.get("blocks"), "components"),
                    .tracks = stringListHas(o.get("blocks"), "tracks"),
                    .vias = stringListHas(o.get("blocks"), "vias"),
                },
                .allow_nets = (try buildStrings(arena, o.get("allow_nets"))) orelse &.{},
            },
        };
    }
    return .{};
}

// ── The parsed board ─────────────────────────────────────────────────────────

/// How a caller wants the payload read.
pub const Options = struct {
    /// Copy every parsed string into the arena instead of slicing `input`.
    /// The session needs this: it survives interleaved `wasm_alloc` /
    /// `drc_check` calls that reset the shared input arena, so a board holding
    /// slices into that buffer would read freed bytes on the next probe. The
    /// stateless check finishes inside one call and pays nothing for it.
    copy_strings: bool = false,
};

/// The board one marshalled payload describes: the placement the client engine
/// checks, its copper, its poured topology, and the clearance rule that check
/// runs at.
pub const Board = struct {
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const drc.TopologyZone,
    clearance: f64,
};

/// Everything a parse can fail with: the JSON reader's own errors (a malformed
/// payload), an allocation failure, and `InputNotObject` for a payload that
/// parses but is not an object. Both bridges turn any of them into the
/// `{"error":"…"}` response the page reads.
pub const Error = std.json.ParseError(std.json.Scanner) || error{InputNotObject};

/// Parse a marshalled board-state payload into the placement + copper the
/// client DRC runs over. Split out of the bridges so a test can assert on the
/// placement itself rather than only on the violations it produces, and so both
/// bridges read one schema.
pub fn parse(arena: std.mem.Allocator, input: []const u8, opts: Options) Error!Board {
    const allocate: std.json.AllocWhen = if (opts.copy_strings) .alloc_always else .alloc_if_needed;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{ .allocate = allocate });
    const obj = objOf(root) orelse return error.InputNotObject;

    var nettab: NetTable = .{};
    const parts = try buildParts(arena, obj.get("parts"), &nettab);
    const tracks = try buildTracks(arena, obj.get("tracks"), &nettab);
    const vias = try buildVias(arena, obj.get("vias"), &nettab);
    const zones = try buildTopologyZones(arena, obj.get("zones"), &nettab);
    const rf_paths = try buildRfPaths(arena, obj.get("rf_paths"), &nettab);
    const overrides = try buildNetClassOverrides(arena, obj.get("netclasses"), &nettab);
    const dpairs = try buildDiffPairs(arena, obj.get("diffpairs"), &nettab);
    const planes = try buildStrings(arena, obj.get("planes"));
    // The physical stack behind those net names. Only a board that DECLARED a
    // stackup adopts it: with `planes` absent the legacy implicit model is in
    // force and `copper_layers` must stay 0, exactly as before.
    const stack = try buildStack(arena, obj.get("layer_table"));
    // The implicit model's chosen supply rail (see `implicit_plane`). Read only
    // when `planes` is absent — the server marshals it under exactly that
    // condition — so the client's plane-carried verdict matches the server's
    // instead of diverging into a permanent wasm/server reconcile.
    const implicit_rail = jStrOpt(obj.get("implicit_rail"));

    // All interning done — the net set (and its indices) is now final.
    const nets = try nettab.flatNets(arena);
    const netrules = try buildNetRules(arena, overrides, nets.len);
    const design = buildDesignRules(obj.get("rules"));
    const perimeter = try buildPerimeterFence(arena, obj.get("keepouts"));

    const board_poly = blk: {
        const pts = try buildPoly(arena, obj.get("board_poly"));
        break :blk if (pts.len >= 3) pts else null;
    };
    // A polygon with no explicit rect still needs a board_rect (the edge check
    // returns early without one); fall back to the polygon's bounding box.
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
        .rules = .{
            .perimeter_fence = perimeter,
            .net = netrules,
            .design = design,
            .plane_nets = planes,
            .copper_layers = if (planes == null) 0 else stack.layers,
            .planes = .{
                .declared = if (planes == null) &.{} else stack.planes,
                .implicit_rail = if (planes == null) implicit_rail else null,
            },
        },
        .diff_pairs = dpairs,
    };
    const routed = router.RouteResult{ .tracks = tracks, .vias = vias, .rf_port_outcomes = rf_paths, .routed = 0, .total = 0 };

    // Clearance precedence mirrors pcbDrcApi: the body's `clearance` wins when
    // positive, else the design's resolved base rule.
    const body_clearance = jNum(clearanceVal(obj));
    const clearance = if (body_clearance > 0) body_clearance else design.clearance;

    return .{ .placement = placement, .routed = routed, .zones = zones, .clearance = clearance };
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Web Server - Both client DRC bridges read the blob's design-rule object through one shared reader, so the stateless check and the session probe resolve identical board rules
test "the shared design-rule reader maps every design-rule key the blob carries" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Every key set to a distinct non-default value, so a field wired to the
    // wrong key cannot pass by coincidence. Both client bridges parse through
    // THIS module, so this pins them at once.
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

// spec: Web Server - One shared parser reads the client DRC board payload, so the stateless check and the session probe see identical parts, pads and net rules
test "one parse serves both client bridges with every field the blob carries" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The four net-rule fields the session's hand-copied parser never gained,
    // plus the pad shape and silkscreen it dropped. Reading them back proves
    // the seam both bridges now share carries the whole schema.
    const src =
        \\{"clearance":0.2,
        \\ "netclasses":[{"net":"RF","class":"rf-cpwg-50","width":0.4,"keepout_mm":0.5,
        \\   "keepout_escape_mm":0.9,"power_branch_width":0.8,"max_freq_hz":12000000000}],
        \\ "parts":[{"ref":"U1","kind":"hub","hw":1,"hh":1,"x":0,"y":0,"side":"top",
        \\   "silk":{"l":[[0,0,1,0]],"c":[[0,0,0.5]]},
        \\   "pads":[{"num":"1","x":0,"y":0,"w":0.6,"h":0.2,"net":"RF","shape":"roundrect","rratio":0.25}]}]}
    ;
    const board = try parse(arena, src, .{});
    const rule = board.placement.rules.net[0];
    try testing.expectEqualStrings("rf-cpwg-50", rule.class.name);
    try testing.expectEqual(@as(f64, 0.5), rule.rf.keepout_mm);
    try testing.expectEqual(@as(f64, 0.9), rule.rf.keepout_escape_mm);
    try testing.expectEqual(@as(f64, 0.8), rule.pad_neck.power_branch_width);

    const part = board.placement.parts[0];
    try testing.expectEqualStrings("roundrect", part.pads[0].shape);
    try testing.expectEqual(@as(f64, 0.25), part.pads[0].overrides.rratio);
    try testing.expectEqual(@as(usize, 1), part.features.silk_lines.len);
    try testing.expectEqual(@as(usize, 1), part.features.silk_circles.len);
}

// spec: Web Server - The session parse copies every string out of the payload buffer so a loaded board survives the buffer being reused
test "copy_strings leaves the parsed board holding none of the input buffer" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const src = try arena.dupe(u8,
        \\{"parts":[{"ref":"R1","kind":"passive","hw":0.5,"hh":0.5,"x":0,"y":0,"side":"top",
        \\ "pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"net":"SIG"}]}]}
    );
    const board = try parse(arena, src, .{ .copy_strings = true });
    // Scribble over the payload the way a following `wasm_alloc` would.
    @memset(src, '#');
    try testing.expectEqualStrings("SIG", board.placement.nets[0].name);
    try testing.expectEqualStrings("R1", board.placement.parts[0].ref_des);
}
