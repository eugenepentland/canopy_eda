//! CLI seam for `import-kicad-layout`: evaluate the design, read the KiCad
//! board READ-ONLY, run the pure importer (`import_layout.zig`), print one
//! JSON result to stdout, and — unless `--dry-run` — replace the design's
//! layout sidecar with the imported layout as its single starred entry. The
//! `.kicad_pcb` file is never written by this command.

const std = @import("std");
const exit = @import("../exit.zig");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const json_writer = @import("../json_writer.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const eval_modules = @import("../eval/modules.zig");
const export_kicad = @import("../export_kicad.zig");
const export_kicad_netlist = @import("../export_kicad_netlist.zig");
const optimizer = @import("../placement/optimizer.zig");
const snapshot = @import("snapshot.zig");
const import_layout = @import("import_layout.zig");
const import_layout_json = @import("import_layout_json.zig");
const pcb_layout_import = @import("../serve/pcb_layout_import.zig");

/// Board files above this size are rejected rather than swallowing memory.
const board_max_bytes: usize = 64 * 1024 * 1024;
const default_chord_tol_mm: f64 = (import_layout.Options{}).chord_tol_mm;
const usage =
    "Usage: netlisp import-kicad-layout [--project-dir <d>] <design> " ++
    "[--board <path>] [--dry-run] [--chord-tol-mm <mm>]\n";

/// Errors the command can propagate; everything user-facing goes through
/// `exit.fatal` instead.
pub const RunError = std.mem.Allocator.Error || std.Io.Writer.Error;

const Args = struct {
    project_dir: []const u8 = ".",
    design: []const u8,
    board: ?[]const u8 = null,
    dry_run: bool = false,
    chord_tol_mm: f64 = default_chord_tol_mm,
};

/// Everything `printResult` needs to emit the one JSON line.
const Outcome = struct {
    args: Args,
    board_path: []const u8,
    imported: import_layout.Imported,
    written: bool,
};

/// Run the `import-kicad-layout` command end to end (see module docs).
pub fn run(allocator: std.mem.Allocator, argv: []const []const u8) RunError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = parseArgs(argv);

    var eval = Evaluator.init(allocator, args.project_dir);
    defer eval.deinit();
    const block = designBlockOf(arena, &eval, args);
    const board_path = args.board orelse block.kicad_pcb_path orelse exit.fatal(
        "import-kicad-layout: {s} declares no (kicad-pcb …) form; pass --board <path>\n",
        .{args.design},
    );
    const source = infra_fs.cwd().readFileAlloc(arena, board_path, board_max_bytes) catch |err|
        exit.fatal("import-kicad-layout: cannot read {s}: {s}\n", .{ board_path, @errorName(err) });
    const board = snapshot.parse(arena, source) catch |err|
        exit.fatal("import-kicad-layout: parse error in {s}: {s}\n", .{ board_path, @errorName(err) });

    var instances: std.ArrayList(export_kicad.FlatInstance) = .empty;
    try export_kicad_netlist.collectInstances(arena, block, "", &instances);
    var nets: std.ArrayList(export_kicad.FlatNet) = .empty;
    try export_kicad.flattenAndMergeNets(arena, block, &nets);

    const imported = try import_layout.build(arena, .{
        .board = board,
        .instances = instances.items,
        .nets = nets.items,
        .rules = try boardRulesFor(arena, block),
    }, .{ .chord_tol_mm = args.chord_tol_mm });

    const written = !args.dry_run and
        pcb_layout_import.writeImportedStarredLayout(arena, args.project_dir, args.design, imported);
    try printResult(arena, .{
        .args = args,
        .board_path = board_path,
        .imported = imported,
        .written = written,
    });
}

/// Parse the argument vector, exiting with usage on anything malformed.
fn parseArgs(argv: []const []const u8) Args {
    var out = Args{ .design = "" };
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--project-dir")) {
            out.project_dir = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--board")) {
            out.board = takeValue(argv, &i, arg);
        } else if (std.mem.eql(u8, arg, "--chord-tol-mm")) {
            out.chord_tol_mm = parseTolerance(takeValue(argv, &i, arg));
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            out.dry_run = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            exit.fatal("import-kicad-layout: unknown option {s}\n", .{arg});
        } else if (out.design.len == 0) {
            out.design = arg;
        } else {
            exit.fatal("import-kicad-layout: unexpected argument {s}\n", .{arg});
        }
    }
    if (out.design.len == 0) exit.fatal(usage, .{});
    return out;
}

/// The value following a `--flag`, advancing the cursor past it.
fn takeValue(argv: []const []const u8, i: *usize, flag: []const u8) []const u8 {
    if (i.* + 1 >= argv.len) exit.fatal("import-kicad-layout: {s} requires a value\n", .{flag});
    i.* += 1;
    return argv[i.*];
}

/// A finite, positive chord tolerance in millimetres.
fn parseTolerance(source: []const u8) f64 {
    const value = std.fmt.parseFloat(f64, source) catch
        exit.fatal("import-kicad-layout: invalid chord tolerance {s}\n", .{source});
    if (!std.math.isFinite(value) or value <= 0) exit.fatal(
        "import-kicad-layout: chord tolerance must be finite and positive\n",
        .{},
    );
    return value;
}

/// Evaluate `<design>` exactly like `netlisp build`: a top-level design block
/// is used as-is; a bare `lib/modules` name is instantiated standalone via
/// its parameter defaults. Fatal (with the stashed diagnostic) on failure.
fn designBlockOf(arena: std.mem.Allocator, eval: *Evaluator, args: Args) *env_mod.DesignBlock {
    const source_path = paths.designSourcePath(arena, args.project_dir, args.design) catch |err|
        exit.fatal("import-kicad-layout: cannot resolve {s}: {s}\n", .{ args.design, @errorName(err) });
    const result = eval.evalFile(source_path) catch |err| fatalEval(eval, source_path, err);
    switch (result) {
        .design_block => |block| return block,
        else => {},
    }
    const standalone = eval_modules.instantiateStandalone(eval, args.design) catch |err|
        fatalEval(eval, source_path, err);
    return switch (standalone) {
        .design_block => |block| block,
        else => exit.fatal(
            "import-kicad-layout: {s} did not evaluate to a design\n",
            .{args.design},
        ),
    };
}

/// Print the stashed compiler-style diagnostic when one exists, then exit.
fn fatalEval(eval: *const Evaluator, source_path: []const u8, err: anyerror) noreturn {
    // A diagnostic raised inside an imported module names that module's file.
    if (eval.last_error) |diag| exit.fatal(
        "{s}:{d}:{d}: error: {s}\n",
        .{ if (diag.file.len > 0) diag.file else source_path, diag.span.line, diag.span.col, diag.message },
    );
    exit.fatal("import-kicad-layout: evaluate error: {s}\n", .{@errorName(err)});
}

/// The layer-map slice of the design's board rules — copper-layer count +
/// declared planes + plane nets, the exact fields `signalLayerCount` /
/// `signalLayerName` read (mirrors the optimizer's private `boardRulesOf`).
/// The implicit model's rail plane is deliberately absent: this caller only
/// ever names layers, and layer naming never asks what a plane carries.
fn boardRulesFor(
    arena: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
) std.mem.Allocator.Error!optimizer.BoardRules {
    if (!block.stackup.present) return .{};
    const planes = try arena.alloc(optimizer.PlaneAt, block.stackup.planes.len);
    const plane_nets = try arena.alloc([]const u8, block.stackup.planes.len);
    for (block.stackup.planes, planes, plane_nets) |declared, *plane, *net| {
        plane.* = .{ .index = declared.index, .net = declared.net };
        net.* = declared.net;
    }
    return .{
        .plane_nets = plane_nets,
        .copper_layers = block.stackup.layers,
        .planes = .{ .declared = planes },
    };
}

/// The literal JSON spelling of a bool value (twin of the json module's
/// private helper — kept local so neither needs a pub bool-taking fn).
fn jsonBool(value: bool) []const u8 {
    return if (value) "true" else "false";
}

/// Emit the one-line JSON result (header + report + written flag) to stdout.
fn printResult(arena: std.mem.Allocator, outcome: Outcome) RunError!void {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"ok\":true,\"design\":");
    try json_writer.writeString(w, outcome.args.design);
    try w.writeAll(",\"board_path\":");
    try json_writer.writeString(w, outcome.board_path);
    try w.print(",\"dry_run\":{s},\"chord_tol_mm\":{d}", .{
        jsonBool(outcome.args.dry_run),
        outcome.args.chord_tol_mm,
    });
    try w.writeAll(",\"report\":");
    try import_layout_json.writeReport(w, outcome.imported.report);
    try w.print(",\"written\":{s}}}", .{jsonBool(outcome.written)});

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(infra_fs.currentIo(), &stdout_buffer);
    try stdout_writer.interface.writeAll(out.written());
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

// ── Tests ───────────────────────────────────────────────────────────────────

// spec: kicad_pcb/import-layout - --dry-run parses as report-only and --chord-tol-mm overrides the tolerance
test "argument parsing reads dry-run and the chord tolerance override" {
    const got = parseArgs(&.{
        "--project-dir",      "projects/designs",
        "board-a",            "--board",
        "boards/b.kicad_pcb", "--dry-run",
        "--chord-tol-mm",     "0.1",
    });
    try std.testing.expect(got.dry_run);
    try std.testing.expectEqual(@as(f64, 0.1), got.chord_tol_mm);
    try std.testing.expectEqualStrings("board-a", got.design);
    try std.testing.expectEqualStrings("boards/b.kicad_pcb", got.board.?);
    try std.testing.expectEqualStrings("projects/designs", got.project_dir);
}
