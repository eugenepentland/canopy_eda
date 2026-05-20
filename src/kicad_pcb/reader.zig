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
        try net_table.put(@intFromFloat(id_num), name);
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
        }
    }

    fp.pads = pads.items;
    return fp;
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
    // `(pad "1" smd …)` — numbered pads carry a string number first.
    // `(pad npth circle …)` — unnumbered NPTH mounting holes have an
    // atom (pad type) in slot 1 instead of a number. The Go agent's
    // sync-plan body skips those too (no PadAssign for them).
    const num = cl[1].asString() orelse return;
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
            if (net_table.get(@intFromFloat(id_num))) |name| net_name = name;
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
