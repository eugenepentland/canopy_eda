//! Client-side WASM entry + JSON bridge for the post-route design-rule check.
//!
//! The browser holds the whole board state (parts, pads, routed copper, board
//! rules) in the `/pcb-layout` page blob, so a DRC needn't round-trip to the
//! server: this module compiles the *same* `placement/drc.zig` engine to
//! `wasm32-freestanding` and drives it from a self-contained JSON payload the
//! page builds from that blob. The only wasm-specific surface is the two C-ABI
//! exports (`wasm_alloc` / `drc_check`) guarded to wasm targets; the parse →
//! build → serialize core (`runDrcJson`) is a pure allocator-only function that
//! compiles and is unit-tested natively.
//!
//! Serialization reuses `serve/drc_json.zig`'s `writeViolation`, so a violation's
//! 4-hex id is byte-identical to every server surface (the viewer inspector, the
//! `/api/pcb-drc` endpoint, the page blob).

const std = @import("std");
const builtin = @import("builtin");

const env = @import("eval/env.zig");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const diff_pairs = @import("placement/diff_pairs.zig");
const geometry = @import("placement/geometry.zig");
const outline = @import("placement/outline.zig");
const drc = @import("placement/drc.zig");
const rf_port_report = @import("placement/rf_port_report.zig");
const rf_path_solver = @import("placement/rf_path_solver.zig");
const drc_json = @import("serve/drc_json.zig");
const export_kicad = @import("export_kicad.zig");
const board_layers = @import("board_layers.zig");
const numeric = @import("numeric.zig");

const FlatNet = export_kicad.FlatNet;
const FlatPin = export_kicad.FlatPin;

// The persistent-session probe half of the client DRC lives in its own module
// (drc_session.zig) — a separate file so each stays under the file-size cap.
// Importing it here also pulls its wasm exports (drc_load / drc_probe_*) into
// the SAME drc.wasm binary this module roots, which the `comptime` reference
// guarantees even if every named use below were removed.
//
// Their board parsers stay separate and privately duplicated on purpose: each
// bridge reads a payload the other does not, and a shared parser would couple
// them. The ONE thing single-sourced across the seam is `buildDesignRules` —
// both read the identical `rules` object from the identical page blob, so a
// second copy of that key list could only drift.
const drc_session = @import("drc_session.zig");
comptime {
    _ = drc_session;
}

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

// The `rules` object → `optimizer.DesignRules` is `drc_session.buildDesignRules`.
// This module carried a byte-identical copy of it until 2026-08-14. Both
// bridges parse the SAME `rules` object out of the SAME page blob, written by
// one server emitter, so a second reader of it could only ever drift from the
// first — silently, since nothing compares them. The rest of each bridge's
// board parser stays private and duplicated on purpose (see the header note
// above); the rules object is single-sourced because its KEY LIST is the part
// that drifts.

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

// ── Bridge core ──────────────────────────────────────────────────────────────

/// Parse the board-state JSON, build a minimal `Placement` + `RouteResult`, run
/// `drc.check`, and serialize the violations. Any malformed / non-object input
/// or marshal failure surfaces as `{"error":"…"}`; only OOM propagates. The
/// returned bytes are owned by `arena`.
fn runDrcJson(arena: std.mem.Allocator, input: []const u8) []const u8 {
    return buildAndSerialize(arena, input) catch |e| errorJson(arena, @errorName(e));
}

fn errorJson(arena: std.mem.Allocator, msg: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"oom\"}";
}

fn buildAndSerialize(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, input, .{});
    const obj = objOf(root) orelse return error.InputNotObject;

    var nettab: NetTable = .{};
    const parts = try buildParts(arena, obj.get("parts"), &nettab);
    const tracks = try buildTracks(arena, obj.get("tracks"), &nettab);
    const vias = try buildVias(arena, obj.get("vias"), &nettab);
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
    const design = drc_session.buildDesignRules(obj.get("rules"));
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

    const violations = try drc.check(arena, placement, routed, clearance);
    return serialize(arena, violations, .{ .nets = placement.nets, .parts = placement.parts });
}

/// `{"drc":[…violations…],"n":N}` — the same envelope `pcbDrcApi` writes, using
/// the shared `drc_json.writeViolation` so ids (and the named parties) match
/// every server surface.
fn serialize(arena: std.mem.Allocator, violations: []const drc.Violation, names: drc_json.Names) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"drc\":[");
    for (violations, 0..) |v, i| {
        if (i > 0) try w.writeAll(",");
        try drc_json.writeViolation(w, v, names);
    }
    try w.print("],\"n\":{d}}}", .{violations.len});
    return aw.written();
}

// ── WASM C-ABI exports ───────────────────────────────────────────────────────

/// Process-lifetime WASM state, namespaced in a struct so its statics are not
/// file-scope globals (a two-call output protocol keeps every export free of
/// pointer↔integer casts). `input` backs the caller-owned input buffer (reset
/// when a fresh buffer is requested); `work` backs the parse + response (reset
/// at each check so the PREVIOUS response stays valid until the next call, and
/// nothing accumulates); `output` remembers the last response slice for the
/// paired `drc_output_ptr`; `scratch` is the alloc-failure fallback so
/// `wasm_alloc` never fabricates a null pointer. Analyzed only on wasm targets
/// — the comptime-gated `@export`s below are the sole references, so
/// `wasm_allocator` never touches the native test build.
const Wasm = struct {
    var input = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    var work = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    var output: []const u8 = &.{};
    var scratch: [1]u8 = .{0};
};

/// Allocate `len` input bytes and return their offset. Frees the previous input
/// buffer first, so a client `wasm_alloc`s then `drc_check`s as a pair before
/// the next `wasm_alloc`.
fn wasmAlloc(len: u32) callconv(.c) [*]u8 {
    _ = Wasm.input.reset(.retain_capacity);
    const buf = Wasm.input.allocator().alloc(u8, len) catch return &Wasm.scratch;
    return buf.ptr;
}

/// Run the DRC over the UTF-8 JSON at `ptr[0..len]`; store the response and
/// return its byte length. The response bytes live in `work` and stay valid
/// until the next `drc_check`; read them at `drc_output_ptr()`.
fn drcCheck(ptr: [*]const u8, len: u32) callconv(.c) usize {
    _ = Wasm.work.reset(.retain_capacity);
    Wasm.output = runDrcJson(Wasm.work.allocator(), ptr[0..len]);
    return Wasm.output.len;
}

/// Offset of the last `drc_check` response (paired with its returned length).
fn drcOutputPtr() callconv(.c) [*]const u8 {
    return Wasm.output.ptr;
}

comptime {
    if (builtin.target.cpu.arch.isWasm()) {
        @export(&wasmAlloc, .{ .name = "wasm_alloc" });
        @export(&drcCheck, .{ .name = "drc_check" });
        @export(&drcOutputPtr, .{ .name = "drc_output_ptr" });
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A reference board's direct-`drc.check` result paired with the name tables
/// its violations resolve through — see `directReference`.
const Reference = struct { violations: []const drc.Violation, names: drc_json.Names };

/// The reference direct-construction of the synthetic board the bridge tests
/// feed as JSON: one passive `R1` with a single `SIG` pad at the origin, a
/// crossing `GND` via, plus a `GND`-classed override. Returns the violations
/// computed straight through `drc.check` (no JSON in the loop), so a bridge run
/// can be proved identical to it.
///
/// The name tables ride along: a violation now names the nets/pads it is
/// between, so the two sides are only comparable when both resolve those
/// indices through the same `nets`/`parts`.
fn directReference(arena: std.mem.Allocator) !Reference {
    const pads = try arena.dupe(geometry.Pad, &[_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }});
    const parts = try arena.alloc(optimizer.Part, 1);
    parts[0] = .{
        .ref_des = "R1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.5,
        .pads = pads,
        .fallback = false,
        .x = 0,
        .y = 0,
    };
    const pins = try arena.dupe(FlatPin, &[_]FlatPin{.{ .ref_des = "R1", .pin = "1" }});
    const nets = try arena.dupe(FlatNet, &[_]FlatNet{ .{ .name = "SIG", .pins = pins }, .{ .name = "GND", .pins = &.{} } });
    const netrules = [_]optimizer.NetRule{ .{}, .{ .clearance = 0.5 } };
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
        .rules = .{ .net = &netrules, .design = .{} },
    };
    const vias = [_]router.Via{.{ .x = 0.5, .y = 0, .dia = 0.6, .drill = 0.2, .net = 1 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &vias, .routed = 0, .total = 0 };
    return .{
        .violations = try drc.check(arena, placement, routed, 0.127),
        .names = .{ .nets = nets, .parts = parts },
    };
}

const synthetic_board_json =
    \\{"clearance":0.127,
    \\ "rules":{"min_drill":0.2,"min_annular":0.1,"hole_to_hole":0.25},
    \\ "netclasses":[{"net":"GND","clearance":0.5}],
    \\ "parts":[{"ref":"R1","kind":"passive","hw":0.5,"hh":0.5,"x":0,"y":0,"rot":0,"side":"top",
    \\           "pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"shape":"rect","net":"SIG"}]}],
    \\ "vias":[{"x":0.5,"y":0,"d":0.6,"drill":0.2,"net":"GND"}]}
;

// spec: Web Server - The WASM DRC bridge parses board-state JSON to the same violations as a direct drc.check run
test "bridge JSON equals a direct drc.check on the same board" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const ref = try directReference(arena);
    try testing.expect(ref.violations.len >= 1);

    const out = runDrcJson(arena, synthetic_board_json);

    // The bridge envelope carries every reference violation's id, kind word,
    // and total count — proving the parse→build→check path reproduces the
    // direct run (same violations, same shared-writer ids).
    const count_needle = try std.fmt.allocPrint(arena, "\"n\":{d}}}", .{ref.violations.len});
    try testing.expect(std.mem.indexOf(u8, out, count_needle) != null);
    try testing.expect(std.mem.startsWith(u8, out, "{\"drc\":["));

    // Serialize the reference through the SAME envelope the bridge uses, so the
    // two are directly comparable byte-for-byte (same violations, same ids).
    const direct_json = try serialize(arena, ref.violations, ref.names);
    try testing.expectEqualStrings(direct_json, out);
}

test "bridge accepts geometry-exact manual neck and RF land tapers" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const rf =
        \\{"clearance":0.127,"rules":{"min_width":0.127},
        \\ "netclasses":[{"net":"RF","class":"rf","width":0.4,"max_freq_hz":12000000000,"impedance_ohms":50}],
        \\ "parts":[{"ref":"U1","kind":"hub","hw":1,"hh":1,"x":0,"y":0,"side":"top",
        \\   "pads":[{"num":"1","x":0,"y":0,"w":0.6,"h":0.2,"net":"RF"}]}],
        \\ "tracks":[{"x1":0,"y1":0,"x2":0.3,"y2":0,"l":0,"w":0.2,"net":"RF"},
        \\             {"x1":0.3,"y1":0,"x2":0.38,"y2":0,"l":0,"w":0.234,"net":"RF"}]}
    ;
    const rf_bad =
        \\{"clearance":0.127,"rules":{"min_width":0.127},
        \\ "netclasses":[{"net":"RF","class":"rf","width":0.4,"max_freq_hz":12000000000,"impedance_ohms":50}],
        \\ "parts":[{"ref":"U1","kind":"hub","hw":1,"hh":1,"x":0,"y":0,"side":"top",
        \\   "pads":[{"num":"1","x":0,"y":0,"w":0.6,"h":0.2,"net":"RF"}]}],
        \\ "tracks":[{"x1":0.3,"y1":0,"x2":0.7,"y2":0,"l":0,"w":0.2,"net":"RF"}]}
    ;
    const neck =
        \\{"clearance":0.127,"rules":{"min_width":0.127},
        \\ "netclasses":[{"net":"VDD","width":0.3,"pad_neck_width":0.2,"pad_neck_max_length":0.75,"pad_neck_taper_length":0.35}],
        \\ "parts":[{"ref":"U1","kind":"hub","hw":1,"hh":1,"x":0,"y":0,"side":"top",
        \\   "pads":[{"num":"1","x":0,"y":0,"w":0.6,"h":0.25,"net":"VDD"}]}],
        \\ "tracks":[{"x1":0,"y1":0,"x2":0.5,"y2":0,"l":0,"w":0.2,"net":"VDD"}]}
    ;
    try testing.expect(std.mem.indexOf(u8, runDrcJson(arena, rf), "\"k\":\"track width\"") == null);
    try testing.expect(std.mem.indexOf(u8, runDrcJson(arena, rf_bad), "\"k\":\"track width\"") != null);
    try testing.expect(std.mem.indexOf(u8, runDrcJson(arena, neck), "\"k\":\"track width\"") == null);
}

// spec: Web Server - The WASM DRC bridge returns an error object on malformed input instead of trapping
test "bridge returns an error object on bad JSON" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const bad = runDrcJson(arena, "{not json");
    try testing.expect(std.mem.startsWith(u8, bad, "{\"error\":\""));

    const not_obj = runDrcJson(arena, "[1,2,3]");
    try testing.expect(std.mem.indexOf(u8, not_obj, "InputNotObject") != null);
}

/// The reference direct-construction of a diff-pair board the bridge test feeds
/// as JSON: a P leg straight along y=0 and an N leg diverging up to (10,8) — so
/// the pair reads as uncoupled (and skewed). Violations from a direct
/// `drc.check`, to prove the JSON `diffpairs` path reproduces them.
fn directReferenceDiff(arena: std.mem.Allocator) !Reference {
    const nets = try arena.dupe(FlatNet, &[_]FlatNet{ .{ .name = "D_P", .pins = &.{} }, .{ .name = "D_N", .pins = &.{} } });
    const pairs = [_]diff_pairs.DiffPair{.{ .p = 0, .n = 1, .gap = 0.2 }};
    const placement = optimizer.Placement{
        .parts = &.{},
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
        .diff_pairs = &pairs,
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 10, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 },
        .{ .x1 = 0, .y1 = 0.2, .x2 = 10, .y2 = 8, .layer = 0, .width = 0.127, .net = 1 },
    };
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 };
    return .{
        .violations = try drc.check(arena, placement, routed, 0.127),
        .names = .{ .nets = nets },
    };
}

const diff_pair_board_json =
    \\{"clearance":0.127,
    \\ "tracks":[{"x1":0,"y1":0,"x2":10,"y2":0,"l":0,"w":0.127,"net":"D_P"},
    \\           {"x1":0,"y1":0.2,"x2":10,"y2":8,"l":0,"w":0.127,"net":"D_N"}],
    \\ "diffpairs":[{"p":"D_P","n":"D_N","gap":0.2}]}
;

// spec: Web Server - The WASM DRC bridge resolves a diffpairs entry like a direct drc.check
test "bridge diffpairs entry equals a direct drc.check on the same pair" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const ref = try directReferenceDiff(arena);
    try testing.expect(ref.violations.len >= 1); // an uncoupled (and/or skew) warning
    const out = runDrcJson(arena, diff_pair_board_json);
    const direct_json = try serialize(arena, ref.violations, ref.names);
    try testing.expectEqualStrings(direct_json, out);
}

/// A four-layer DECLARED board whose In1 is a GND plane, carrying one GND via
/// fed by a single track. The via's second contact is that inner plane, so it
/// is a live barrel and `single_layer_via` must NOT fire — but only for a
/// checker that knows the board HAS an inner plane on stack 2.
const planed_via_board_json =
    \\{"clearance":0.2,
    \\ "planes":["GND"],
    \\ "layer_table":[{"i":1,"l":0,"kind":"signal","net":null},
    \\                {"i":2,"l":null,"kind":"plane","net":"GND"},
    \\                {"i":3,"l":2,"kind":"signal","net":null},
    \\                {"i":4,"l":1,"kind":"signal","net":null}],
    \\ "parts":[{"ref":"U1","x":0,"y":0,"kind":"hub","hw":1,"hh":1,
    \\           "pads":[{"num":"1","x":0,"y":0,"w":0.5,"h":0.5,"net":"GND"}]}],
    \\ "tracks":[{"x1":0,"y1":0,"x2":3,"y2":0,"l":0,"w":0.2,"net":"GND"}],
    \\ "vias":[{"x":3,"y":0,"d":0.6,"drill":0.3,"net":"GND"}]}
;

/// The same board with its `layer_table` stripped — what the bridge received
/// before the copper stack crossed it.
const planed_via_board_no_stack_json = blk: {
    var buf: [planed_via_board_json.len]u8 = undefined;
    const at = std.mem.indexOf(u8, planed_via_board_json, " \"layer_table\":").?;
    const end = std.mem.indexOf(u8, planed_via_board_json[at..], "\n \"parts\"").? + at;
    @memcpy(buf[0..at], planed_via_board_json[0..at]);
    const tail = planed_via_board_json[end..];
    @memcpy(buf[at .. at + tail.len], tail);
    const total = at + tail.len;
    const out = buf[0..total].*;
    break :blk out;
};

// spec: Web Server - The WASM DRC bridge is given the board's copper stack, so the client engine's layer arithmetic matches the server's on a declared stackup
test "the bridge adopts the marshalled copper stack" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The stack the marshal ships resolves to the board's real layer model:
    // four physical layers with one declared inner plane, so three routable.
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, planed_via_board_json, .{});
    const stack = try buildStack(arena, objOf(root).?.get("layer_table"));
    try testing.expectEqual(@as(u8, 4), stack.layers);
    try testing.expectEqual(@as(usize, 1), stack.planes.len);
    try testing.expectEqual(@as(u8, 2), stack.planes[0].index);
    const rules = optimizer.BoardRules{
        .plane_nets = &.{"GND"},
        .copper_layers = stack.layers,
        .planes = .{ .declared = stack.planes },
    };
    try testing.expectEqual(@as(u8, 3), rules.signalLayerCount());
    var buf: [board_layers.name_buf_len]u8 = undefined;
    try testing.expectEqualStrings("In2.Cu", rules.signalLayerName(2, &buf));

    // And it changes the VERDICT: the GND via's second contact is that inner
    // plane, so a stack-aware check passes it. Without the table the engine
    // saw a plane-less board and warned `single-layer via` on copper the
    // server calls fine — a permanent wasm/server reconcile.
    const with_stack = runDrcJson(arena, planed_via_board_json);
    try testing.expect(std.mem.indexOf(u8, with_stack, "single-layer via") == null);
    const without = runDrcJson(arena, &planed_via_board_no_stack_json);
    try testing.expect(std.mem.indexOf(u8, without, "single-layer via") != null);

    // The marshal is what puts the table on the wire.
    const marshal = @embedFile("serve/assets/drc_marshal.js");
    try testing.expect(std.mem.indexOf(u8, marshal, "out.layer_table = PCB.layer_table.map(") != null);
}

/// How a keepout finding spells its kind on the wire (`drc_json.kindStr`); the
/// per-design policy map keys on the enum name `keepout_violation` instead, like
/// every other check.
const keepout_kind_json = "\"k\":\"keepout\"";
const perimeter_keepout_kind_json = "\"k\":\"perimeter keepout\"";

/// An RF net with a 0.5 mm keepout, a signal neighbour 0.3 mm off it, a ground
/// track the same distance away, and the same neighbour crossing on B.Cu — the
/// four cases the client engine has to tell apart.
const keepout_board_json =
    \\{"clearance":0.127,
    \\ "planes":["GND"],
    \\ "tracks":[{"x1":0,"y1":0,"x2":10,"y2":0,"l":0,"w":0.127,"net":"RF_IN"},
    \\           {"x1":0,"y1":0.3,"x2":10,"y2":0.3,"l":0,"w":0.127,"net":"SPI_SCK"},
    \\           {"x1":0,"y1":-0.3,"x2":10,"y2":-0.3,"l":0,"w":0.127,"net":"GND"},
    \\           {"x1":0,"y1":0.3,"x2":10,"y2":0.3,"l":1,"w":0.127,"net":"SPI_MISO"}],
    \\ "netclasses":[{"net":"RF_IN","width":0.127,"keepout_mm":0.5,"keepout_escape_mm":0}]}
;

// spec: Web Server - The WASM DRC bridge carries a net class's keepout halo and the declared plane nets, so the client flags the same intrusions
test "bridge flags a keepout intrusion and honours the marshalled plane nets" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const out = runDrcJson(arena, keepout_board_json);
    // Exactly one keepout finding: the same-layer signal neighbour. The ground
    // track is exempt (its name AND the marshalled plane list say so) and the
    // B.Cu neighbour is on the far layer, which the rule leaves free.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, keepout_kind_json));
    try testing.expect(std.mem.indexOf(u8, out, "SPI_SCK") != null);
    // SPI_MISO may appear in the independent copper-stub audit because this
    // wire fixture deliberately has no pads; the exact keepout count above is
    // what proves the far-layer trace did not trip the RF halo.

    // Drop the class geometry and the same board reports nothing — proof the
    // finding came through the marshalled `keepout_mm`, not from somewhere else.
    const no_class = try std.mem.replaceOwned(
        u8,
        arena,
        keepout_board_json,
        "\"keepout_mm\":0.5",
        "\"keepout_mm\":0",
    );
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, runDrcJson(arena, no_class), keepout_kind_json));
}

const perimeter_keepout_board_json =
    \\{"clearance":0.127,
    \\ "board":{"x":0,"y":0,"w":10,"h":10},
    \\ "tracks":[{"x1":0.8,"y1":2,"x2":0.8,"y2":8,"l":0,"w":0.2,"net":"SIG"},
    \\           {"x1":9.2,"y1":2,"x2":9.2,"y2":8,"l":0,"w":0.2,"net":"GND"}],
    \\ "vias":[{"x":0.9,"y":4,"d":0.4,"drill":0.2,"net":"SIG"},
    \\          {"x":9.1,"y":4,"d":0.4,"drill":0.2,"net":"GND"}],
    \\ "keepouts":[{"kind":"perimeter","clearance":0.3,"edge_offset":0.5,
    \\   "via_dia":0.4,"via_drill":0.2,"blocks":["tracks","vias"],"allow_nets":["GND"]}]}
;

// spec: Web Server - The WASM DRC bridge carries typed generic perimeter keepouts and their allowed nets
test "bridge flags typed perimeter keepouts and admits their allowed nets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const out = runDrcJson(arena_state.allocator(), perimeter_keepout_board_json);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, perimeter_keepout_kind_json));
    try testing.expect(std.mem.indexOf(u8, out, "SIG") != null);
}

/// The filter-chain case on the wire: two nets 0.3 mm apart, both declaring the
/// same 0.5 mm halo, with `%CLASS%` naming the SECOND one's class — `"rf"` (the
/// same family, which owes no halo) or `"clk"` (foreign traffic, which does).
const keepout_class_board_json =
    \\{"clearance":0.127,
    \\ "tracks":[{"x1":0,"y1":0,"x2":10,"y2":0,"l":0,"w":0.127,"net":"RF1_VCO"},
    \\           {"x1":0,"y1":0.3,"x2":10,"y2":0.3,"l":0,"w":0.127,"net":"RF1_DCBLK"}],
    \\ "netclasses":[{"net":"RF1_VCO","class":"rf","width":0.127,"keepout_mm":0.5,"keepout_escape_mm":0},
    \\               {"net":"RF1_DCBLK","class":"%CLASS%","width":0.127,"keepout_mm":0.5,"keepout_escape_mm":0}]}
;

// spec: Web Server - The WASM DRC bridge carries each net's class identity, so the client waives the keepout halo between one class's own members exactly as the server does
test "bridge waives the keepout halo between two nets of one class" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // One class, two links of the same RF chain: nothing to report.
    const same = try std.mem.replaceOwned(u8, arena, keepout_class_board_json, "%CLASS%", "rf");
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, runDrcJson(arena, same), keepout_kind_json));

    // The identical copper with the neighbour in a DIFFERENT class breaks both
    // halos — proof the silence above came from the marshalled class name and not
    // from the check having gone missing.
    const apart = try std.mem.replaceOwned(u8, arena, keepout_class_board_json, "%CLASS%", "clk");
    const out = runDrcJson(arena, apart);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, keepout_kind_json));

    // A net whose class did not cross the bridge (an older page blob) reads as
    // unclassed, which enforces the halo rather than silently waiving it.
    const legacy = try std.mem.replaceOwned(u8, arena, keepout_class_board_json, "\"class\":\"%CLASS%\",", "");
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, runDrcJson(arena, legacy), keepout_kind_json));
}

/// The filter case on the wire: an RF pad at the origin with a 1 mm keepout
/// escape, and a neighbour stub 0.3 mm off the RF trace inside that escape zone.
/// `%PAD%` is the neighbour part's pad net — its own (admitted) or a third net
/// with no business there (refused).
const keepout_escape_board_json =
    \\{"clearance":0.127,
    \\ "parts":[{"ref":"J1","kind":"connector","hw":0.5,"hh":0.5,"x":0,"y":0,"rot":0,"side":"top",
    \\           "pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"shape":"rect","net":"RF_IN"}]},
    \\          {"ref":"R1","kind":"passive","hw":0.3,"hh":0.3,"x":0.5,"y":0.4,"rot":0,"side":"top",
    \\           "pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"shape":"rect","net":"%PAD%"}]}],
    \\ "tracks":[{"x1":0,"y1":0,"x2":10,"y2":0,"l":0,"w":0.127,"net":"RF_IN"},
    \\           {"x1":0,"y1":0.3,"x2":1,"y2":0.3,"l":0,"w":0.127,"net":"SPI_SCK"}],
    \\ "netclasses":[{"net":"RF_IN","width":0.127,"keepout_mm":0.5,"keepout_escape_mm":1.0}]}
;

// spec: Web Server - The WASM DRC bridge applies the same net-gated keepout escape as the server, excusing only a net with its own pad in the zone
test "bridge net-gates the keepout escape exemption" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The stub's own net owns the neighbouring pad — the breakout the exemption
    // is for — so the client engine excuses it, exactly as the server does.
    const admitted = try std.mem.replaceOwned(u8, arena, keepout_escape_board_json, "%PAD%", "SPI_SCK");
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, runDrcJson(arena, admitted), keepout_kind_json));

    // Give that pad to a third net and SPI_SCK is merely passing through the
    // zone: ungated it was silently excused, gated it is flagged.
    const passer = try std.mem.replaceOwned(u8, arena, keepout_escape_board_json, "%PAD%", "I2C_SDA");
    const out = runDrcJson(arena, passer);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, keepout_kind_json));
    try testing.expect(std.mem.indexOf(u8, out, "SPI_SCK") != null);
}

// spec: Web Server - The WASM DRC bridge treats every board-state field as optional, defaulting to a clean board
test "bridge defaults missing optional fields to an empty clean board" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A bare object (no parts/tracks/vias/rules) has no geometry to violate.
    const out = runDrcJson(arena, "{}");
    try testing.expectEqualStrings("{\"drc\":[],\"n\":0}", out);
}
