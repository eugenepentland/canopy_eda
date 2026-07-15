//! KiCad board-importer MCP tool handlers, split out of `mcp_tools.zig` (which
//! stays the dispatcher). `parse_kicad_netlist` is the read-only preview — it
//! parses a `.kicad_pcb` off disk into a family-classified netlist without
//! writing anything; `import_kicad` runs the full importer (`import_kicad.zig`)
//! that materializes `lib/` + `src/` files, the MCP twin of the
//! `netlisp import-kicad` CLI. Board paths are read via `infra_fs`, the
//! whitelisted filesystem seam, so an absolute NAS path is the expected form
//! (same trust model as the `(kicad-pcb …)` sync path). Arg parsing + the JSON
//! string writer are reused from `mcp_tools` / `json_writer` verbatim.
const std = @import("std");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const import_kicad = @import("../import_kicad.zig");
const mcp_tools = @import("mcp_tools.zig");

const requireString = mcp_tools.requireString;
const optionalString = mcp_tools.optionalString;
const optionalBool = mcp_tools.optionalBool;
const missingArg = mcp_tools.missingArg;

/// Board files can be large (a routed board is tens of MB); cap the read the
/// same as the importer's own `importBoard`.
const max_board_bytes = 64 * 1024 * 1024;
const board_suffix = ".kicad_pcb";
const key_board_path = "board_path";

/// True when `net` names a real connection — non-empty and not one of KiCad's
/// `unconnected-*` single-pad stubs (which mark a pad left floating).
fn isConnected(net: []const u8) bool {
    return net.len > 0 and !std.mem.startsWith(u8, net, import_kicad.unconnected_prefix);
}

/// Write `{ok:false,error:"<msg>"}` and return false — the shared failure shape.
fn errorJson(out: *std.ArrayList(u8), allocator: std.mem.Allocator, msg: []const u8) std.mem.Allocator.Error!bool {
    const w = out.writer(allocator);
    try w.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(w, msg);
    try w.writeAll("}");
    return false;
}

/// Map an importer error to a human-readable message for the `{ok:false}`
/// envelope. `OutOfMemory` is not handled here — it propagates to the caller.
fn importErrorMessage(err: import_kicad.ImportError) []const u8 {
    return switch (err) {
        error.FileNotFound => "board file not found",
        error.InvalidBoard => "not a valid KiCad board — no (kicad_pcb …) head or no footprints",
        error.WriteFailed => "failed to write imported library/design files",
        else => @errorName(err),
    };
}

/// `parse_kicad_netlist` (read-only): parse a `.kicad_pcb` off disk into a
/// family-classified netlist preview — the read half of the importer, nothing
/// is written. Returns `{ok:true, part_count, net_count, components:[…]}` where
/// `net_count` counts the distinct connected nets and each pad's `net` is `""`
/// for an unconnected/`unconnected-*` pad. On a bad path or unreadable/invalid
/// board returns `{ok:false, error}`.
pub fn toolParseKicadNetlist(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const board_path = requireString(args_val, key_board_path) orelse
        return missingArg(out, allocator, key_board_path);
    if (!std.mem.endsWith(u8, board_path, board_suffix))
        return errorJson(out, allocator, "board_path must end with .kicad_pcb");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = infra_fs.cwd().readFileAlloc(arena, board_path, max_board_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorJson(out, allocator, @errorName(err)),
    };
    const parts = import_kicad.parseNetlist(arena, project_dir, source) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorJson(out, allocator, importErrorMessage(err)),
    };

    var seen = std.StringHashMapUnmanaged(void).empty;
    for (parts) |part| {
        for (part.pads) |pad| {
            if (isConnected(pad.net)) try seen.put(arena, pad.net, {});
        }
    }

    const w = out.writer(allocator);
    try w.print("{{\"ok\":true,\"part_count\":{d},\"net_count\":{d},\"components\":[", .{ parts.len, seen.count() });
    for (parts, 0..) |part, i| {
        if (i > 0) try w.writeAll(",");
        try writePart(w, part);
    }
    try w.writeAll("]}");
    return true;
}

/// Emit one `{ref,value,lib,family,dnp,pads:[…]}` object. `family` is the
/// mapped passive family (e.g. "cap-0402") or null for a custom part; each
/// pad's `net` is normalized to "" when unconnected.
fn writePart(w: anytype, part: import_kicad.Part) std.mem.Allocator.Error!void {
    try w.writeAll("{\"ref\":");
    try json_writer.writeString(w, part.ref);
    try w.writeAll(",\"value\":");
    try json_writer.writeString(w, part.value);
    try w.writeAll(",\"lib\":");
    try json_writer.writeString(w, part.lib_id);
    try w.writeAll(",\"family\":");
    if (part.family) |fam| try json_writer.writeString(w, fam) else try w.writeAll("null");
    try w.print(",\"dnp\":{s},\"pads\":[", .{if (part.dnp) "true" else "false"});
    for (part.pads, 0..) |pad, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"pad\":");
        try json_writer.writeString(w, pad.number);
        try w.writeAll(",\"function\":");
        try json_writer.writeString(w, pad.func);
        try w.writeAll(",\"net\":");
        try json_writer.writeString(w, if (isConnected(pad.net)) pad.net else "");
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// `import_kicad` (mutation): run the full board importer, writing
/// `lib/{components,pinouts,footprints}` for unknown parts + `src/<name>.sexp`
/// (skipped when `dry_run`). `fold_prefix` implies `fold_channels`. Mirrors the
/// `netlisp import-kicad` CLI. Returns the `ImportSummary` counts as
/// `{ok:true, …, fold:{…}?, dry_run}`, or `{ok:false, error}` on failure.
pub fn toolImportKicad(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const board_path = requireString(args_val, key_board_path) orelse
        return missingArg(out, allocator, key_board_path);
    const name = requireString(args_val, "name") orelse return missingArg(out, allocator, "name");
    if (!std.mem.endsWith(u8, board_path, board_suffix))
        return errorJson(out, allocator, "board_path must end with .kicad_pcb");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fold_prefix = optionalString(args_val, "fold_prefix");
    const dry_run = optionalBool(args_val, "dry_run") orelse false;
    const summary = import_kicad.importBoard(arena, .{
        .board_path = board_path,
        .project_dir = project_dir,
        .name = name,
        .title = optionalString(args_val, "title") orelse boardStem(board_path),
        .dry_run = dry_run,
        .fold_channels = fold_prefix != null or (optionalBool(args_val, "fold_channels") orelse false),
        .fold_prefix = fold_prefix,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorJson(out, allocator, importErrorMessage(err)),
    };

    const w = out.writer(allocator);
    try w.print("{{\"ok\":true,\"parts\":{d},\"family_mapped\":{d},\"custom_parts\":{d}", .{
        summary.parts, summary.family_mapped, summary.custom_parts,
    });
    try w.print(",\"lib_written\":{d},\"lib_existing\":{d},\"nets\":{d},\"dropped_pins\":{d}", .{
        summary.lib_written, summary.lib_existing, summary.nets, summary.dropped_pins,
    });
    try w.writeAll(",\"design_path\":");
    try json_writer.writeString(w, summary.design_path);
    if (summary.folded_channels > 0) {
        try w.writeAll(",\"fold\":{\"module\":");
        try json_writer.writeString(w, summary.fold_module);
        try w.print(",\"channels\":{d},\"parts_each\":{d},\"skipped\":{d}}}", .{
            summary.folded_channels, summary.folded_parts_each, summary.fold_skipped,
        });
    }
    try w.print(",\"dry_run\":{s}}}", .{if (dry_run) "true" else "false"});
    return true;
}

/// The board file's basename without its extension — the default design title,
/// matching the CLI's `--title` fallback.
fn boardStem(board_path: []const u8) []const u8 {
    const base = std.fs.path.basename(board_path);
    return if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

const test_board =
    \\(kicad_pcb (version 20260206) (generator "pcbnew")
    \\  (footprint "Capacitor_SMD:C_0402_1005Metric"
    \\    (at 10 20 90)
    \\    (property "Reference" "C1" (at 0 0 0))
    \\    (property "Value" "100nF" (at 0 0 0))
    \\    (pad "1" smd roundrect (at -0.48 0 90) (size 0.56 0.62) (net "VDD") (pintype "passive"))
    \\    (pad "2" smd roundrect (at 0.48 0 90) (size 0.56 0.62) (net "GND") (pintype "passive")))
    \\  (footprint "SamacSys_Parts:QFN50P600X600X100-41N"
    \\    (at 30 40)
    \\    (property "Reference" "IC1" (at 0 0 0))
    \\    (property "Value" "LMX2595RHAR" (at 0 0 0))
    \\    (property "MPN" "LMX2595RHAR" (at 0 0 0))
    \\    (pad "1" smd roundrect (at -3 -2) (size 0.25 0.5) (net "VDD") (pinfunction "CE"))
    \\    (pad "3" smd roundrect (at -3 0) (size 0.25 0.5) (net "unconnected-(IC1-Pad3)") (pinfunction "NC"))))
;

/// Write `test_board` into a tmp dir with a `lib/components/cap-0402.sexp`
/// family file, returning the tmp dir (caller cleans up) and the board path.
fn writeTestBoard(tmp: *std.testing.TmpDir, arena: std.mem.Allocator) ![]const u8 {
    try tmp.dir.makePath("lib/components");
    try tmp.dir.writeFile(.{ .sub_path = "lib/components/cap-0402.sexp", .data = "(component-family \"cap-0402\")" });
    try tmp.dir.writeFile(.{ .sub_path = "board.kicad_pcb", .data = test_board });
    const dir = try tmp.dir.realpathAlloc(arena, ".");
    return std.fmt.allocPrint(arena, "{s}/board.kicad_pcb", .{dir});
}

fn objectArgs(arena: std.mem.Allocator, pairs: []const [2][]const u8) !std.json.Value {
    var obj = std.json.ObjectMap.init(arena);
    for (pairs) |p| try obj.put(p[0], .{ .string = p[1] });
    return .{ .object = obj };
}

test "parse_kicad_netlist returns components, pads, and connected net count" {
    // spec: serve/mcp_tools - parse_kicad_netlist returns components, pads, and a connected-net count
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const board_path = try writeTestBoard(&tmp, arena);
    const project_dir = try tmp.dir.realpathAlloc(arena, ".");

    const args = try objectArgs(arena, &.{.{ key_board_path, board_path }});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const ok = try toolParseKicadNetlist(testing.allocator, project_dir, args, &out);

    try testing.expect(ok);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"part_count\":2") != null);
    // VDD + GND are connected; the unconnected-* stub is not counted.
    try testing.expect(std.mem.indexOf(u8, out.items, "\"net_count\":2") != null);
    // The cap maps onto the existing family; the pinfunction survives.
    try testing.expect(std.mem.indexOf(u8, out.items, "\"family\":\"cap-0402\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"function\":\"CE\"") != null);
    // The unconnected pad's net is normalized to "".
    try testing.expect(std.mem.indexOf(u8, out.items, "\"function\":\"NC\",\"net\":\"\"") != null);
}

test "parse_kicad_netlist rejects a non-.kicad_pcb path" {
    // spec: serve/mcp_tools - parse_kicad_netlist rejects a board_path that does not end in .kicad_pcb
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try objectArgs(arena, &.{.{ key_board_path, "/tmp/board.kicad_sch" }});
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const ok = try toolParseKicadNetlist(testing.allocator, ".", args, &out);

    try testing.expect(!ok);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, ".kicad_pcb") != null);
}

test "import_kicad dry_run reports counts and writes nothing" {
    // spec: serve/mcp_tools - import_kicad with dry_run reports importer counts without writing files
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const board_path = try writeTestBoard(&tmp, arena);
    const project_dir = try tmp.dir.realpathAlloc(arena, ".");

    // objectArgs only builds string values, so set dry_run as a real JSON bool.
    var obj = std.json.ObjectMap.init(arena);
    try obj.put(key_board_path, .{ .string = board_path });
    try obj.put("name", .{ .string = "smoketest" });
    try obj.put("dry_run", .{ .bool = true });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const ok = try toolImportKicad(testing.allocator, project_dir, .{ .object = obj }, &out);

    try testing.expect(ok);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"parts\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"family_mapped\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"dry_run\":true") != null);
    // dry_run must not write the design file.
    try testing.expectError(error.FileNotFound, tmp.dir.access("src/smoketest.sexp", .{}));
}
