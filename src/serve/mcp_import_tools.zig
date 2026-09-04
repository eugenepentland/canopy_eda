//! KiCad board-importer CLI tool handlers, split out of `mcp_tools.zig` (which
//! stays the dispatcher). `parse_kicad_netlist` is the read-only preview — it
//! parses a `.kicad_pcb` off disk into a family-classified netlist without
//! writing anything; `import_kicad` runs the full importer (`import_kicad.zig`)
//! that materializes `lib/` + `src/` files, the CLI twin of the
//! `netlisp import-kicad` CLI. Board paths are read via `infra_fs`, the
//! whitelisted filesystem seam, so an absolute NAS path is the expected form
//! (same trust model as the `(kicad-pcb …)` sync path). Arg parsing + the JSON
//! string writer are reused from `mcp_tools` / `json_writer` verbatim.
const std = @import("std");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const import_kicad = @import("../import_kicad.zig");
const kicad_inspect = @import("../kicad_pcb/inspect.zig");
const kicad_experiment = @import("../kicad_pcb/experiment.zig");
const mcp_tools = @import("mcp_tools.zig");

const requireString = mcp_tools.requireString;
const optionalString = mcp_tools.optionalString;
const optionalBool = mcp_tools.optionalBool;
const missingArg = mcp_tools.missingArg;
const AllocatingWriter = @import("../allocating_writer.zig").AllocatingWriter;

const writeJsonString = json_writer.writeStringOom;

/// Board files can be large (a routed board is tens of MB); cap the read the
/// same as the importer's own `importBoard`.
const max_board_bytes = 64 * 1024 * 1024;
const board_suffix = ".kicad_pcb";
const key_board_path = "board_path";
const invalid_board_suffix = "board_path must end with .kicad_pcb";

/// True when `net` names a real connection — non-empty and not one of KiCad's
/// `unconnected-*` single-pad stubs (which mark a pad left floating).
fn isConnected(net: []const u8) bool {
    return net.len > 0 and !std.mem.startsWith(u8, net, import_kicad.unconnected_prefix);
}

/// Write `{ok:false,error:"<msg>"}` and return false — the shared failure shape.
fn errorJson(out: *std.ArrayList(u8), allocator: std.mem.Allocator, msg: []const u8) std.mem.Allocator.Error!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    try w.writeAll("{\"ok\":false,\"error\":");
    try writeJsonString(w, msg);
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
        return errorJson(out, allocator, invalid_board_suffix);

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

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    try w.print("{{\"ok\":true,\"part_count\":{d},\"net_count\":{d},\"components\":[", .{ parts.len, seen.count() });
    for (parts, 0..) |part, i| {
        if (i > 0) try w.writeAll(",");
        try writePart(w, part);
    }
    try w.writeAll("]}");
    return true;
}

/// `inspect_kicad_layout` (read-only): retain physical placement/copper/zones,
/// adjacent project rules, and routing metrics instead of reducing the board
/// to a netlist. `include_nets` adds per-net copper/via/pad totals.
pub fn toolInspectKicadLayout(
    allocator: std.mem.Allocator,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const board_path = requireString(args_val, key_board_path) orelse
        return missingArg(out, allocator, key_board_path);
    if (!std.mem.endsWith(u8, board_path, board_suffix))
        return errorJson(out, allocator, invalid_board_suffix);

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = kicad_inspect.load(arena, board_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorJson(out, allocator, @errorName(err)),
    };
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    kicad_inspect.writeJson(
        arena,
        w,
        report,
        if (optionalBool(args_val, "include_nets") orelse false) .nets else .summary,
    ) catch return error.OutOfMemory;
    return true;
}

/// `benchmark_kicad_routing` (read-only): without `candidate_path`, report the
/// virtual trace/via erasure that seeds an experiment. With a candidate, score
/// it against fixed reference geometry and the reference project's hard rules.
pub fn toolBenchmarkKicadRouting(
    allocator: std.mem.Allocator,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!bool {
    const reference_path = requireString(args_val, "reference_path") orelse
        return missingArg(out, allocator, "reference_path");
    if (!std.mem.endsWith(u8, reference_path, board_suffix))
        return errorJson(out, allocator, "reference_path must end with .kicad_pcb");
    const candidate_path = optionalString(args_val, "candidate_path");
    if (candidate_path) |path| if (!std.mem.endsWith(u8, path, board_suffix))
        return errorJson(out, allocator, "candidate_path must end with .kicad_pcb");

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const reference = kicad_inspect.load(arena, reference_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorJson(out, allocator, @errorName(err)),
    };
    const nets = jsonStringList(arena, args_val, "nets");
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    if (candidate_path == null) {
        const erased = try kicad_experiment.virtualErase(arena, reference.board, nets);
        try w.writeAll("{\"ok\":true,\"mode\":\"virtual-erasure\",\"reference_path\":");
        try writeJsonString(w, reference_path);
        try writeNameLists(w, erased.selected_nets, erased.unknown_nets);
        try w.writeAll(",\"removed\":");
        try writeCopperMetrics(w, erased.removed);
        try w.writeAll(",\"retained\":");
        try writeCopperMetrics(w, erased.retained);
        try w.print(",\"seed\":{{\"segments\":{d},\"arcs\":{d},\"vias\":{d},\"zones_retained\":{d}}}}}", .{
            erased.seed.segments.len,
            erased.seed.arcs.len,
            erased.seed.vias.len,
            erased.seed.zones.len,
        });
        return true;
    }

    const candidate = kicad_inspect.load(arena, candidate_path.?) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return errorJson(out, allocator, @errorName(err)),
    };
    const score = try kicad_experiment.scoreCandidate(
        arena,
        reference.board,
        candidate.board,
        reference.project,
        nets,
    );
    try w.writeAll("{\"ok\":true,\"mode\":\"score\",\"reference_path\":");
    try writeJsonString(w, reference_path);
    try w.writeAll(",\"candidate_path\":");
    try writeJsonString(w, candidate_path.?);
    try writeNameLists(w, score.selected_nets, score.unknown_nets);
    try w.writeAll(",\"missing_nets\":");
    try writeStringArray(w, score.missing_nets);
    try w.print(",\"eligible_nets\":{d},\"routed_nets\":{d},\"fixed_geometry_mismatches\":{d}," ++
        "\"rule_violations\":{d},\"reference_rule_violations\":{d},\"reference\":", .{
        score.eligible_nets,
        score.routed_nets,
        score.fixed_geometry_mismatches,
        score.rule_violations,
        score.reference_rule_violations,
    });
    try writeCopperMetrics(w, score.reference);
    try w.writeAll(",\"candidate\":");
    try writeCopperMetrics(w, score.candidate);
    try w.print(",\"reference_objective\":{d},\"objective\":{d}}}", .{
        score.reference_objective,
        score.objective,
    });
    return true;
}

fn jsonStringList(
    arena: std.mem.Allocator,
    args_val: ?std.json.Value,
    key: []const u8,
) []const []const u8 {
    const args = args_val orelse return &.{};
    if (args != .object) return &.{};
    const value = args.object.get(key) orelse return &.{};
    if (value != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (value.array.items) |item| {
        if (item == .string and item.string.len > 0) out.append(arena, item.string) catch return &.{};
    }
    return out.toOwnedSlice(arena) catch &.{};
}

fn writeNameLists(writer: anytype, selected: []const []const u8, unknown: []const []const u8) !void {
    try writer.writeAll(",\"selected_nets\":");
    try writeStringArray(writer, selected);
    try writer.writeAll(",\"unknown_nets\":");
    try writeStringArray(writer, unknown);
}

fn writeStringArray(writer: anytype, names: []const []const u8) !void {
    try writer.writeByte('[');
    for (names, 0..) |name, i| {
        if (i > 0) try writer.writeByte(',');
        try writeJsonString(writer, name);
    }
    try writer.writeByte(']');
}

fn writeCopperMetrics(writer: anytype, metrics: kicad_experiment.CopperMetrics) !void {
    try writer.print(
        "{{\"nets\":{d},\"segments\":{d},\"arcs\":{d},\"vias\":{d},\"length_mm\":{d}}}",
        .{ metrics.nets, metrics.segments, metrics.arcs, metrics.vias, metrics.length_mm },
    );
}

/// Emit one `{ref,value,lib,family,dnp,pads:[…]}` object. `family` is the
/// mapped passive family (e.g. "cap-0402") or null for a custom part; each
/// pad's `net` is normalized to "" when unconnected.
fn writePart(w: anytype, part: import_kicad.Part) std.mem.Allocator.Error!void {
    try w.writeAll("{\"ref\":");
    try writeJsonString(w, part.ref);
    try w.writeAll(",\"value\":");
    try writeJsonString(w, part.value);
    try w.writeAll(",\"lib\":");
    try writeJsonString(w, part.lib_id);
    try w.writeAll(",\"family\":");
    if (part.family) |fam| try writeJsonString(w, fam) else try w.writeAll("null");
    try w.print(",\"dnp\":{s},\"pads\":[", .{if (part.dnp) "true" else "false"});
    for (part.pads, 0..) |pad, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"pad\":");
        try writeJsonString(w, pad.number);
        try w.writeAll(",\"function\":");
        try writeJsonString(w, pad.func);
        try w.writeAll(",\"net\":");
        try writeJsonString(w, if (isConnected(pad.net)) pad.net else "");
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
        return errorJson(out, allocator, invalid_board_suffix);

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

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const w: AllocatingWriter = .{ .writer = &aw.writer };
    try w.print("{{\"ok\":true,\"parts\":{d},\"family_mapped\":{d},\"custom_parts\":{d}", .{
        summary.parts, summary.family_mapped, summary.custom_parts,
    });
    try w.print(",\"lib_written\":{d},\"lib_existing\":{d},\"nets\":{d},\"dropped_pins\":{d}", .{
        summary.lib_written, summary.lib_existing, summary.nets, summary.dropped_pins,
    });
    try w.writeAll(",\"design_path\":");
    try writeJsonString(w, summary.design_path);
    if (summary.folded_channels > 0) {
        try w.writeAll(",\"fold\":{\"module\":");
        try writeJsonString(w, summary.fold_module);
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
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/cap-0402.sexp", .data = "(component-family \"cap-0402\")" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "board.kicad_pcb", .data = test_board });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    return std.fmt.allocPrint(arena, "{s}/board.kicad_pcb", .{dir});
}

fn objectArgs(arena: std.mem.Allocator, pairs: []const [2][]const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .empty;
    for (pairs) |p| try obj.put(arena, p[0], .{ .string = p[1] });
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
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

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
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);

    // objectArgs only builds string values, so set dry_run as a real JSON bool.
    var obj: std.json.ObjectMap = .empty;
    try obj.put(arena, key_board_path, .{ .string = board_path });
    try obj.put(arena, "name", .{ .string = "smoketest" });
    try obj.put(arena, "dry_run", .{ .bool = true });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const ok = try toolImportKicad(testing.allocator, project_dir, .{ .object = obj }, &out);

    try testing.expect(ok);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"parts\":2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"family_mapped\":1") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"dry_run\":true") != null);
    // dry_run must not write the design file.
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.access(std.testing.io, "src/smoketest.sexp", .{}),
    );
}
