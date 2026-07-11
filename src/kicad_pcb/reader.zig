//! Parse a `.kicad_pcb` file on disk and produce the same `BoardFp` shape
//! the Go IPC agent posts to `/api/sync-plan`. Replaces the IPC-derived
//! board state with a direct file read so the new file-based KiCad sync
//! can reuse `runSyncPlan` without going through a live KiCad session.
//!
//! KiCad's `.kicad_pcb` is the same S-expression dialect this project
//! already speaks, so parsing and traversal piggyback on `src/sexpr/`.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser = @import("../sexpr/parser.zig");
const sync = @import("../serve/sync.zig");
const fmt_const = @import("format.zig");
const numeric = @import("../numeric.zig");

const Node = ast.Node;

const PROP_REFERENCE = fmt_const.PROP_REFERENCE;
const PROP_VALUE = fmt_const.PROP_VALUE;
const PROP_CANOPY_UUID = fmt_const.PROP_CANOPY_UUID;

pub const ReadError = error{InvalidPcbRoot} || std.mem.Allocator.Error || parser.ParseError;

/// Parse `source` (the raw contents of a `.kicad_pcb` file) into a slice
/// of BoardFp records. All strings are owned by `arena`. Net IDs in pad
/// records are resolved against the file's top-level `(net N "name")`
/// table before being attached to each pad.
pub fn readBoard(arena: std.mem.Allocator, source: []const u8) ReadError![]const sync.BoardFp {
    const nodes = try parser.parse(arena, source);
    if (nodes.len == 0 or !nodes[0].isForm("kicad_pcb")) return error.InvalidPcbRoot;
    const children = nodes[0].asList() orelse return error.InvalidPcbRoot;

    var net_table = std.AutoHashMap(i64, []const u8).init(arena);
    var fps: std.ArrayListUnmanaged(sync.BoardFp) = .empty;

    // Pass 1: build the net-ID → name map. Pads in pass 2 reference it.
    for (children[1..]) |child| {
        if (!child.isForm("net")) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        const id_num = cl[1].asNumber() orelse continue;
        const name = cl[2].asString() orelse continue;
        try net_table.put(numeric.checkedInt(i64, id_num) orelse continue, name);
    }

    // Pass 2: build a BoardFp per footprint.
    for (children[1..]) |child| {
        if (!child.isForm("footprint")) continue;
        if (try readFootprint(arena, child, &net_table)) |fp| {
            try fps.append(arena, fp);
        }
    }

    return fps.items;
}

fn readFootprint(
    arena: std.mem.Allocator,
    node: Node,
    net_table: *const std.AutoHashMap(i64, []const u8),
) ReadError!?sync.BoardFp {
    const cl = node.asList() orelse return null;
    if (cl.len < 2) return null;
    // `(footprint "lib_id" …)` — lib_id is the next element.
    const lib_id = cl[1].asString() orelse return null;

    var fp: sync.BoardFp = .{
        .uuid = "",
        .kicad_uuid = "",
        .ref = "",
        .value = "",
        .footprint_name = lib_id,
        .fields = .empty,
        .pads = &[_]sync.PadAssign{},
        .locked = false,
    };

    var pads: std.ArrayListUnmanaged(sync.PadAssign) = .empty;

    for (cl[2..]) |sub| {
        if (sub.isForm("uuid")) {
            fp.kicad_uuid = formStringChild(sub) orelse "";
        } else if (sub.isForm("locked")) {
            // (locked yes) | (locked no). KiCad emits this as a sibling
            // of (at …) when the user padlocks a footprint in pcbnew.
            fp.locked = formAtomChildEquals(sub, "yes");
        } else if (sub.isForm("property")) {
            try readProperty(arena, sub, &fp);
        } else if (sub.isForm("pad")) {
            try readPad(arena, sub, net_table, &pads);
        } else if (sub.isForm("model")) {
            readModel(sub, &fp);
        }
    }

    fp.pads = pads.items;
    return fp;
}

/// Parse a footprint's `(model "<path>" (offset (xyz X Y Z)) (scale …)
/// (rotate (xyz RX RY RZ)))` into `has_model`/`model_offset`/`model_rotate`.
/// Missing offset/rotate sub-forms default to zero (KiCad omits a zero block).
/// Used by the diff to detect 3D-model orientation drift vs `model-config.json`.
fn readModel(node: Node, fp: *sync.BoardFp) void {
    const cl = node.asList() orelse return;
    if (cl.len < 2) return;
    fp.has_model = true;
    for (cl[2..]) |sub| {
        if (sub.isForm("offset")) {
            fp.model_offset = readXyz(sub);
        } else if (sub.isForm("rotate")) {
            fp.model_rotate = readXyz(sub);
        }
    }
}

/// Read the `(xyz X Y Z)` child of an `(offset …)` / `(rotate …)` form into a
/// `[3]f64`. Returns zeros when the form is malformed or the `xyz` is absent.
fn readXyz(node: Node) [3]f64 {
    const cl = node.asList() orelse return .{ 0, 0, 0 };
    for (cl[1..]) |sub| {
        const xl = sub.asList() orelse continue;
        if (xl.len < 4 or !sub.isForm("xyz")) continue;
        return .{
            xl[1].asNumber() orelse 0,
            xl[2].asNumber() orelse 0,
            xl[3].asNumber() orelse 0,
        };
    }
    return .{ 0, 0, 0 };
}

fn readProperty(arena: std.mem.Allocator, node: Node, fp: *sync.BoardFp) std.mem.Allocator.Error!void {
    const cl = node.asList() orelse return;
    if (cl.len < 3) return;
    const key = cl[1].asString() orelse return;
    const value = cl[2].asString() orelse return;
    if (std.mem.eql(u8, key, PROP_REFERENCE)) {
        fp.ref = value;
    } else if (std.mem.eql(u8, key, PROP_VALUE)) {
        fp.value = value;
    } else if (std.mem.eql(u8, key, PROP_CANOPY_UUID)) {
        fp.uuid = value;
    } else {
        try fp.fields.put(arena, key, value);
    }
}

fn readPad(
    arena: std.mem.Allocator,
    node: Node,
    net_table: *const std.AutoHashMap(i64, []const u8),
    pads: *std.ArrayListUnmanaged(sync.PadAssign),
) std.mem.Allocator.Error!void {
    const cl = node.asList() orelse return;
    if (cl.len < 2) return;
    // Slot 1 is the pad number/name. It may be quoted (`(pad "1" …)`), a bare
    // atom (`(pad A1 …)` from KiCad-5 sources), or a bare integer (`(pad 1 …)`
    // as KiCad re-saves numeric pads). padNumberText handles all three so a
    // bare-numbered pad isn't silently dropped and left unwireable.
    const num = fmt_const.padNumberText(arena, cl[1]) orelse return;
    var net_name: []const u8 = "";
    for (cl[2..]) |sub| {
        if (!sub.isForm("net")) continue;
        const nl = sub.asList() orelse continue;
        if (nl.len < 2) continue;
        // Standard KiCad format: `(net <id> "<name>")` — slot 1 is the
        // integer net-ID into the top-level table.
        // Legacy / Go-IPC-agent format: `(net "<name>")` — slot 1 is the
        // name directly, no top-level table. Older Canopy boards were
        // written this way; the file-based sync must read both so an
        // existing board isn't flagged "all pads disconnected" on the
        // first push. The writer always emits the canonical form.
        if (nl[1].asNumber()) |id_num| {
            if (net_table.get(numeric.checkedInt(i64, id_num) orelse continue)) |name| net_name = name;
        } else if (nl[1].asString()) |name| {
            net_name = name;
        }
        break;
    }
    try pads.append(arena, .{ .number = num, .net = net_name });
}

/// Return the first child of a single-string form like `(uuid "…")`.
fn formStringChild(node: Node) ?[]const u8 {
    const cl = node.asList() orelse return null;
    if (cl.len < 2) return null;
    return cl[1].asString();
}

/// True when a single-atom form like `(locked yes)` matches `expected`.
fn formAtomChildEquals(node: Node, expected: []const u8) bool {
    const cl = node.asList() orelse return false;
    if (cl.len < 2) return false;
    const atom = cl[1].asAtom() orelse return false;
    return std.mem.eql(u8, atom, expected);
}

// ── Tests ──────────────────────────────────────────────────────────────

const reader_fuzz_corpus = [_][]const u8{
    "",
    "(kicad_pcb)",
    "(kicad_pcb (net 0 \"\") (net 1 \"VDD\")\n" ++
        "  (footprint \"R\" (at 1 2) (property \"Reference\" \"R1\")\n" ++
        "    (pad \"1\" smd rect (at 0 0) (net 1 \"VDD\"))))",
    "(not_a_board 1 2 3)",
    "((((",
    "(kicad_pcb (footprint",
    &[_]u8{ 0x28, 0x00, 0xff, 0x29 },
};

/// One fuzz iteration for the `.kicad_pcb` reader: arbitrary bytes must never
/// crash — `readBoard` either returns a board slice or a `ReadError`. Every
/// allocation lands in an arena that is unconditionally reclaimed, so the outer
/// `testing.allocator` stays leak-free regardless of where parsing bails out.
fn fuzzReadBoard(allocator: std.mem.Allocator, input: []const u8) anyerror!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    _ = readBoard(arena.allocator(), input) catch return;
}

// spec: kicad_pcb/reader - Fuzzing readBoard with arbitrary bytes never crashes
test "fuzz: readBoard tolerates arbitrary bytes" {
    try std.testing.fuzz(std.testing.allocator, fuzzReadBoard, .{ .corpus = &reader_fuzz_corpus });
}

// spec: kicad_pcb/reader - parses footprint reference, value, kicad_uuid, and canopy_uuid from properties
test "readBoard extracts ref/value/uuids from a single footprint" {
    const a = std.testing.allocator;
    const src =
        \\(kicad_pcb
        \\  (net 0 "")
        \\  (net 1 "VDD")
        \\  (footprint "R_0402"
        \\    (uuid "abc-123")
        \\    (at 10 20)
        \\    (property "Reference" "R7")
        \\    (property "Value" "10k")
        \\    (property "canopy_uuid" "f5df675d-9ad6-42ea-bf19-bb298929c9c2")
        \\    (pad "1" smd roundrect
        \\      (at 0 0)
        \\      (net 1 "VDD"))))
    ;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const fps = try readBoard(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), fps.len);
    try std.testing.expectEqualStrings("R7", fps[0].ref);
    try std.testing.expectEqualStrings("10k", fps[0].value);
    try std.testing.expectEqualStrings("R_0402", fps[0].footprint_name);
    try std.testing.expectEqualStrings("abc-123", fps[0].kicad_uuid);
    try std.testing.expectEqualStrings("f5df675d-9ad6-42ea-bf19-bb298929c9c2", fps[0].uuid);
    try std.testing.expectEqual(@as(usize, 1), fps[0].pads.len);
    try std.testing.expectEqualStrings("1", fps[0].pads[0].number);
    try std.testing.expectEqualStrings("VDD", fps[0].pads[0].net);
    try std.testing.expectEqual(false, fps[0].locked);
}

// spec: kicad_pcb/reader - parses the (model …) offset/rotate so the diff can detect 3D-model drift
test "readBoard parses the footprint model offset + rotation" {
    const a = std.testing.allocator;
    const src =
        \\(kicad_pcb
        \\  (net 0 "")
        \\  (footprint "GSB"
        \\    (uuid "g-1")
        \\    (property "Reference" "J9")
        \\    (model "${KIPRJMOD}/models/gsb.step"
        \\      (offset (xyz -0 -6.85 -1.65))
        \\      (scale (xyz 1 1 1))
        \\      (rotate (xyz -90 -180 0))))
        \\  (footprint "R_0402"
        \\    (uuid "r-1")
        \\    (property "Reference" "R1")))
    ;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const fps = try readBoard(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), fps.len);
    // Footprint with a (model …): flags + parsed offset/rotate.
    try std.testing.expect(fps[0].has_model);
    try std.testing.expectApproxEqAbs(@as(f64, -6.85), fps[0].model_offset[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -1.65), fps[0].model_offset[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -90), fps[0].model_rotate[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, -180), fps[0].model_rotate[1], 1e-6);
    // Footprint without one: has_model stays false, vectors zero.
    try std.testing.expect(!fps[1].has_model);
    try std.testing.expectApproxEqAbs(@as(f64, 0), fps[1].model_rotate[0], 1e-6);
}

// spec: kicad_pcb/reader - reads a bare-integer pad number so the pad still enters the net diff
test "readBoard reads a bare-integer, netless pad" {
    const a = std.testing.allocator;
    // KiCad re-saves numeric pads with a bare integer (`(pad 1 …)`), and a
    // pad the design hasn't wired yet has no (net …) form. The reader must
    // still surface it (number "1", net "") so the diff can attach the net.
    const src =
        \\(kicad_pcb
        \\  (net 0 "")
        \\  (footprint "SW_B3U"
        \\    (uuid "sw-1")
        \\    (property "Reference" "SW1")
        \\    (pad 1 smd rect (at 1.7 0))
        \\    (pad 2 smd rect (at -1.7 0))))
    ;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const fps = try readBoard(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), fps[0].pads.len);
    try std.testing.expectEqualStrings("1", fps[0].pads[0].number);
    try std.testing.expectEqualStrings("", fps[0].pads[0].net);
    try std.testing.expectEqualStrings("2", fps[0].pads[1].number);
}

// spec: kicad_pcb/reader - skips a pad net id that is non-finite or out of integer range
test "readBoard skips a pad net id that overflows the integer range" {
    const a = std.testing.allocator;
    // A net id far outside i64 (a corrupt/hand-mangled board) must not reach a
    // bare @intFromFloat (UB out of range); numeric.checkedInt drops the id so
    // the net table and the pad lookup both skip it, leaving the pad netless.
    const src =
        \\(kicad_pcb
        \\  (net 1e30 "GND")
        \\  (footprint "R_0402"
        \\    (uuid "r-1")
        \\    (property "Reference" "R1")
        \\    (pad 1 smd rect (at 0 0) (net 1e30 "GND"))))
    ;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const fps = try readBoard(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), fps[0].pads.len);
    try std.testing.expectEqualStrings("", fps[0].pads[0].net);
}

// spec: kicad_pcb/reader - parses (locked yes) as locked footprint
test "readBoard surfaces footprint lock state" {
    const a = std.testing.allocator;
    const src =
        \\(kicad_pcb
        \\  (footprint "C_0402"
        \\    (uuid "u1")
        \\    (locked yes)
        \\    (property "Reference" "C9")))
    ;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    const fps = try readBoard(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), fps.len);
    try std.testing.expectEqual(true, fps[0].locked);
}

// spec: kicad_pcb/reader - reads every footprint in a real .kicad_pcb fixture
test "readBoard walks every footprint in lt3045.kicad_pcb" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    var file = std.fs.cwd().openFile("projects/designs/out/lt3045.kicad_pcb", .{}) catch return;
    defer file.close();
    const src = try file.readToEndAlloc(ar, 16 * 1024 * 1024);

    const fps = try readBoard(ar, src);
    // lt3045.kicad_pcb has ~10 footprints in its current state; the
    // exact number isn't fixed (the file is regenerated) so just assert
    // we got at least one and that every fp has a reference + kicad_uuid.
    try std.testing.expect(fps.len > 0);
    for (fps) |fp| {
        try std.testing.expect(fp.kicad_uuid.len > 0);
        try std.testing.expect(fp.ref.len > 0);
    }
}
