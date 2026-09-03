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
//! The payload itself is read by `drc_board_json.zig`, the ONE parser both
//! client bridges share; this module is the stateless check's envelope around
//! it (parse → `drc.checkWithZones` → serialize) and nothing more.
//!
//! Serialization reuses `serve/drc_json.zig`'s `writeViolation`, so a violation's
//! 4-hex id is byte-identical to every server surface (the viewer inspector, the
//! `/api/pcb-drc` endpoint, the page blob).

const std = @import("std");
const builtin = @import("builtin");

const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const diff_pairs = @import("placement/diff_pairs.zig");
const geometry = @import("placement/geometry.zig");
const drc = @import("placement/drc.zig");
const drc_json = @import("serve/drc_json.zig");
const drc_board_json = @import("drc_board_json.zig");
const board_layers = @import("board_layers.zig");
const export_kicad = @import("export_kicad.zig");

const FlatNet = export_kicad.FlatNet;
const FlatPin = export_kicad.FlatPin;

// The persistent-session probe half of the client DRC lives in its own module
// (drc_session.zig) — a separate file so each stays under the file-size cap.
// Importing it here also pulls its wasm exports (drc_load / drc_probe_*) into
// the SAME drc.wasm binary this module roots, which the `comptime` reference
// guarantees even if every named use below were removed.
//
// Both bridges read the SAME payload through ONE parser, `drc_board_json.zig`.
// They used to carry two hand-written copies of it — the session's header said
// so — and the copies drifted: four net-rule fields, pad shape and silkscreen
// reached the stateless check and never the session. A shared reader cannot
// drift from itself.
const drc_session = @import("drc_session.zig");
comptime {
    _ = drc_session;
}

// ── Bridge core ──────────────────────────────────────────────────────────────

/// Parse the board-state JSON, build a minimal placement, route and poured
/// topology, run `drc.checkWithZones`, and serialize the violations. Any
/// malformed/non-object input or marshal failure surfaces as `{"error":"…"}`;
/// only OOM propagates. The returned bytes are owned by `arena`.
fn runDrcJson(arena: std.mem.Allocator, input: []const u8) []const u8 {
    return buildAndSerialize(arena, input) catch |e| errorJson(arena, @errorName(e));
}

fn errorJson(arena: std.mem.Allocator, msg: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{{\"error\":\"{s}\"}}", .{msg}) catch "{\"error\":\"oom\"}";
}

fn buildAndSerialize(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    const board = try drc_board_json.parse(arena, input, .{});
    const violations = try drc.checkWithZones(arena, board.placement, board.routed, board.clearance, board.zones);
    return serialize(arena, violations, .{ .nets = board.placement.nets, .parts = board.placement.parts });
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
    const rules = (try drc_board_json.parse(arena, planed_via_board_json, .{})).placement.rules;
    try testing.expectEqual(@as(u8, 4), rules.copper_layers);
    try testing.expectEqual(@as(usize, 1), rules.planes.declared.len);
    try testing.expectEqual(@as(u8, 2), rules.planes.declared[0].index);
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

/// Barracuda's 3.3 V rails are not dedicated stackup planes: they are poured
/// on routable In3.Cu. The fast client check therefore needs the fabricated
/// fill contours as well as the physical layer table.
const power_zone_via_board_json =
    \\{"clearance":0.2,
    \\ "planes":["GND"],
    \\ "layer_table":[{"i":1,"l":0,"kind":"signal","net":null},
    \\                {"i":2,"l":null,"kind":"plane","net":"GND"},
    \\                {"i":3,"l":2,"kind":"signal","net":null},
    \\                {"i":4,"l":3,"kind":"signal","net":null},
    \\                {"i":5,"l":null,"kind":"plane","net":"GND"},
    \\                {"i":6,"l":1,"kind":"signal","net":null}],
    \\ "tracks":[{"x1":0,"y1":0,"x2":3,"y2":0,"l":0,"w":0.2,"net":"V_3V3A"}],
    \\ "vias":[{"x":3,"y":0,"d":0.6,"drill":0.3,"net":"V_3V3A"}],
    \\ "zones":[{"net":"V_3V3A","l":3,"poly":[[2,-1],[4,-1],[4,1],[2,1]]}]}
;

const power_zone_via_hole_board_json =
    \\{"clearance":0.2,
    \\ "tracks":[{"x1":0,"y1":0,"x2":3,"y2":0,"l":0,"w":0.2,"net":"V_3V3A"}],
    \\ "vias":[{"x":3,"y":0,"d":0.6,"drill":0.3,"net":"V_3V3A"}],
    \\ "zones":[{"net":"V_3V3A","l":3,"poly":[[2,-1],[4,-1],[4,1],[2,1]],
    \\            "holes":[[[2.5,-0.5],[3.5,-0.5],[3.5,0.5],[2.5,0.5]]]}]}
;

// spec: Web Server - The WASM DRC credits an exact same-net fill on a routable internal power layer as a via contact, while an antipad hole remains disconnected
test "the bridge credits an internal power fill at a via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const board = try drc_board_json.parse(arena, power_zone_via_board_json, .{});
    try testing.expectEqual(@as(usize, 1), board.zones.len);
    try testing.expectEqual(@as(u8, 3), board.zones[0].layer);
    try testing.expectEqual(@as(u64, 1), board.zones[0].component);
    try testing.expect(std.mem.indexOf(u8, runDrcJson(arena, power_zone_via_board_json), "single-layer via") == null);
    try testing.expect(std.mem.indexOf(u8, runDrcJson(arena, power_zone_via_hole_board_json), "single-layer via") != null);

    const marshal = @embedFile("serve/assets/drc_marshal.js");
    try testing.expect(std.mem.indexOf(u8, marshal, "PCB.zone_fills") != null);
    try testing.expect(std.mem.indexOf(u8, marshal, "PCB.plane_fills") != null);
    try testing.expect(std.mem.indexOf(u8, marshal, "PCB.poursStale") != null);
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

/// A DECLARED four-layer board whose In2 is a V_3V3D plane, with that rail's
/// net class opting into current-aware branch sizing (`power_branch_width`) —
/// the exact shape that makes the SERVER's geometry pass raster every plane and
/// pour (barracuda-base). Everything the marshal can say about power is here;
/// what is missing is the one thing it never sends, the rail's current demand.
const power_branch_board_json =
    \\{"clearance":0.127,
    \\ "rules":{"min_width":0.1,"min_drill":0.2,"min_annular":0.1,"hole_to_hole":0.25},
    \\ "planes":["V_3V3D"],
    \\ "layer_table":[{"i":1,"l":0,"kind":"signal","net":null},
    \\                {"i":2,"l":null,"kind":"plane","net":"V_3V3D"},
    \\                {"i":3,"l":1,"kind":"signal","net":null},
    \\                {"i":4,"l":2,"kind":"signal","net":null}],
    \\ "netclasses":[{"net":"V_3V3D","width":0.3048,"power_branch_width":0.1524}],
    \\ "board":{"x":-2,"y":-2,"w":20,"h":20},
    \\ "parts":[{"ref":"U1","kind":"ic","hw":1,"hh":1,"x":0,"y":0,"rot":0,"side":"top",
    \\           "pads":[{"num":"1","x":0,"y":0,"w":0.4,"h":0.4,"shape":"rect","net":"V_3V3D"}]}],
    \\ "tracks":[{"x1":0,"y1":0,"x2":4,"y2":0,"l":0,"w":0.1524,"net":"V_3V3D"},
    \\           {"x1":4,"y1":0,"x2":8,"y2":0,"l":1,"w":0.1524,"net":"V_3V3D"}],
    \\ "vias":[{"x":4,"y":0,"d":0.4,"drill":0.2,"net":"V_3V3D"}]}
;

// spec: Web Server - The WASM DRC bridge marshals no rail current, so the client engine never rasters the board's planes for a power-branch width verdict
test "the bridge builds a rail-less placement, so no plane raster is reachable" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const power_integrity = @import("placement/power_integrity.zig");

    const board = try drc_board_json.parse(arena, power_branch_board_json, .{});

    // THE INVARIANT. `power_integrity.routedTrackRequiredWidthsMemo` sets
    // `needs_surfaces` only for a net with a declared current demand, and the
    // marshal (`drc_marshal.js buildDrcInput`) has no key for one — it sends
    // geometry, rules, net classes and the layer table, never `(i-typ …)`.
    // With rails empty that predicate is false on every board, so `buildSurfaces`
    // — 7.5 s of barracuda-base's 8.2 s server geometry pass — is unreachable
    // from the client engine, whose worker budget is ~50 ms per edit. Marshalling
    // rail currents to the client would silently reinstate that raster in the
    // worker; land the wasm-side skip FIRST if this assertion ever has to move.
    try testing.expectEqual(@as(usize, 0), board.placement.rules.physical.rails.len);

    // The consequence, stated where the cost lives: every entry null means the
    // solve produced nothing and no surface was ever poured for it.
    const widths = try power_integrity.routedTrackRequiredWidths(arena, board.placement, board.routed);
    try testing.expectEqual(board.routed.tracks.len, widths.len);
    for (widths) |w| try testing.expectEqual(@as(?f64, null), w);

    // …and the board still checks: this track sits at the class's branch floor,
    // under its 0.3048 mm class width, so the width rule the client DOES run
    // reports it. Only the current/fill-derived verdict is absent, and the
    // viewer defers exactly that one (`pcb_board.js drcGateDefersPowerWidth`).
    const out = runDrcJson(arena, power_branch_board_json);
    try testing.expect(std.mem.indexOf(u8, out, "\"track width\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"power width\"") == null);

    // The BARREL verdict is deferred on exactly the same grounds: with no rail
    // marshalled there is no current to judge this via's plated area against,
    // so `drc_power_via` has nothing to say here and the server reconcile owns
    // the answer. Its kinds belong in the client's deferred set for that
    // reason, not because the client engine is missing a rule.
    const requirements = try power_integrity.routedViaRequirements(arena, board.placement, board.routed);
    try testing.expectEqual(@as(usize, 1), board.routed.vias.len);
    try testing.expectEqual(board.routed.vias.len, requirements.len);
    try testing.expectEqual(@as(?power_integrity.ViaCurrent, null), requirements[0]);
    try testing.expect(std.mem.indexOf(u8, out, "\"via current\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "\"via current envelope\"") == null);
}
