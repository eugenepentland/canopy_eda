//! CLI seam for exporting and running Elmer board-thermal comparisons.

const std = @import("std");
const exit = @import("exit.zig");
const infra_fs = @import("infra/fs.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const thermal = @import("eval/thermal.zig");
const export_elmer = @import("export_elmer_thermal.zig");
const thermal_field = @import("placement/thermal_field.zig");
const thermal_scenarios = @import("thermal_scenarios.zig");
const clock = @import("infra/clock.zig");
const modules_mod = @import("serve/modules.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");

const export_usage =
    "Usage: netlisp export-elmer-thermal [--project-dir <d>] [--output-dir <out>] [--layout <name>] [--ambient <C>] [--scenario <natural|fan|airflow_1ms|airflow_2ms|heatsink|fan_heatsink>] [--heatsink-ref <ref>] [--heatsink-side <package_top|board_backside>] [--sink-width-mm <mm>] [--sink-length-mm <mm>] [--sink-base-mm <mm>] [--sink-fin-height-mm <mm>] [--sink-fin-count <n>] [--sink-theta-sa <C/W>] [--pad-thickness-mm <mm>] [--pad-k <W/mK>] <design>\n";
const compare_usage =
    "Usage: netlisp compare-elmer-thermal [--project-dir <d>] [--output-dir <out>] [--layout <name>] [--ambient <C>] [--scenario <natural|fan|airflow_1ms|airflow_2ms|heatsink|fan_heatsink>] [--heatsink-ref <ref>] [--heatsink-side <package_top|board_backside>] [--sink-width-mm <mm>] [--sink-length-mm <mm>] [--sink-base-mm <mm>] [--sink-fin-height-mm <mm>] [--sink-fin-count <n>] [--sink-theta-sa <C/W>] [--pad-thickness-mm <mm>] [--pad-k <W/mK>] [--solver <ElmerSolver>] <design>\n";
const bench_usage =
    "Usage: netlisp bench-thermal [--project-dir <d>] [--layout <name>] [--reps <n>] <design>\n";

const Args = struct {
    project_dir: []const u8 = ".",
    output_dir: []const u8 = "",
    layout: ?[]const u8 = null,
    solver: []const u8 = "ElmerSolver",
    ambient_c: f64 = 25.0,
    scenario: thermal_field.Scenario = .natural,
    heatsink: thermal_field.Heatsink = .{},
    heatsink_explicit: bool = false,
    design: []const u8 = "",
};

const Prepared = struct {
    input: export_elmer.Input,
    artifact: export_elmer.Artifact,
};

const BenchArgs = struct {
    project_dir: []const u8 = ".",
    layout: ?[]const u8 = null,
    reps: usize = 21,
    design: []const u8 = "",
};

/// Export a resolved design as a portable Elmer thermal case directory.
pub fn exportCommand(alloc: std.mem.Allocator, argv: []const []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    exportCommandInner(arena_state.allocator(), argv) catch |err| exit.fatal("Elmer thermal export failed: {s}\n", .{@errorName(err)});
}

fn exportCommandInner(alloc: std.mem.Allocator, argv: []const []const u8) anyerror!void {
    const args = parseArgs(argv, false);
    var eval = Evaluator.init(alloc, args.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer dropModule(alloc, module_res);
    const prepared = try prepare(alloc, args, &eval, &module_res);
    if (prepared.input.builtin.cooling.heatsink.interface != .none)
        exit.fatal("Elmer's board-only mesh cannot compare the shared heatsink plate or package θJC branches; use the built-in thermal result for this assembly\n", .{});
    const output_dir = try outputDir(alloc, args);
    try writeCase(alloc, output_dir, prepared.artifact);
    try printOut("Elmer thermal case: {s}\nRun: cd '{s}' && {s} case.sif\n", .{ output_dir, output_dir, args.solver });
}

/// Export, run Elmer, and write JSON plus Markdown comparison reports.
pub fn compareCommand(alloc: std.mem.Allocator, argv: []const []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    compareCommandInner(arena_state.allocator(), argv) catch |err| exit.fatal("Elmer thermal comparison failed: {s}\n", .{@errorName(err)});
}

/// Resolve one board once, then time only its four-scenario built-in field
/// solve. This deliberately excludes evaluation, placement-sidecar parsing and
/// copper rasterization so changes to the relaxation kernel are visible.
pub fn benchCommand(alloc: std.mem.Allocator, argv: []const []const u8) void {
    var command_arena = std.heap.ArenaAllocator.init(alloc);
    defer command_arena.deinit();
    benchCommandInner(command_arena.allocator(), argv) catch |err|
        exit.fatal("Thermal benchmark failed: {s}\n", .{@errorName(err)});
}

fn benchCommandInner(alloc: std.mem.Allocator, argv: []const []const u8) anyerror!void {
    const bench = parseBenchArgs(argv);
    const args = Args{
        .project_dir = bench.project_dir,
        .layout = bench.layout,
        .design = bench.design,
    };
    var eval = Evaluator.init(alloc, args.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer dropModule(alloc, module_res);
    const prepared = try prepare(alloc, args, &eval, &module_res);

    var solve_arena = std.heap.ArenaAllocator.init(alloc);
    defer solve_arena.deinit();
    const warm = try thermal_field.solveScenarios(solve_arena.allocator(), prepared.input.solver_inputs);
    const want_checksum = fieldChecksum(warm);
    const scalar_delta_c = try maxScalarDelta(solve_arena.allocator(), prepared.input.solver_inputs, warm);
    const shape = prepared.input.model.shape;
    _ = solve_arena.reset(.retain_capacity);

    const times = try alloc.alloc(u64, bench.reps);
    var rep: usize = 0;
    while (rep < bench.reps) : (rep += 1) {
        const started = clock.nanoTimestamp();
        const results = try thermal_field.solveScenarios(solve_arena.allocator(), prepared.input.solver_inputs);
        times[rep] = @intCast(clock.nanoTimestamp() - started);
        const got_checksum = fieldChecksum(results);
        if (got_checksum != want_checksum) return error.UnstableThermalResult;
        std.mem.doNotOptimizeAway(got_checksum);
        if (rep + 1 < bench.reps) _ = solve_arena.reset(.retain_capacity);
    }
    std.mem.sort(u64, times, {}, std.sort.asc(u64));
    try printOut(
        "BENCH_THERMAL {s} reps={d} cells={d}x{d} median_ms={d:.3} min_ms={d:.3} scalar_delta_c={d:.7} checksum={x:0>16}\n",
        .{
            bench.design,
            bench.reps,
            shape.cols,
            shape.rows,
            nsToMs(times[bench.reps / 2]),
            nsToMs(times[0]),
            scalar_delta_c,
            want_checksum,
        },
    );
}

fn maxScalarDelta(
    alloc: std.mem.Allocator,
    inputs: thermal_field.Inputs,
    packed_results: []const thermal_field.ScenarioResult,
) std.mem.Allocator.Error!f64 {
    var worst: f64 = 0;
    for (packed_results) |packed_result| {
        const scalar_result = try thermal_field.solveScenario(alloc, inputs, packed_result.scenario);
        for (packed_result.grid.rise_c, scalar_result.grid.rise_c) |packed_rise, scalar_rise| {
            worst = @max(worst, @abs(@as(f64, packed_rise) - scalar_rise));
        }
    }
    return worst;
}

fn parseBenchArgs(argv: []const []const u8) BenchArgs {
    var args = BenchArgs{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--project-dir") or std.mem.eql(u8, arg, "--layout") or std.mem.eql(u8, arg, "--reps")) {
            if (i + 1 >= argv.len) exit.fatal("Missing value after {s}\n{s}", .{ arg, bench_usage });
            const value = argv[i + 1];
            i += 1;
            if (std.mem.eql(u8, arg, "--project-dir")) {
                args.project_dir = value;
            } else if (std.mem.eql(u8, arg, "--layout")) {
                args.layout = value;
            } else {
                args.reps = std.fmt.parseInt(usize, value, 10) catch exit.fatal("Invalid repetition count '{s}'\n", .{value});
            }
        } else if (std.mem.startsWith(u8, arg, "--")) {
            exit.fatal("Unknown option {s}\n{s}", .{ arg, bench_usage });
        } else if (args.design.len == 0) {
            args.design = arg;
        } else {
            exit.fatal("Unexpected argument {s}\n{s}", .{ arg, bench_usage });
        }
    }
    if (args.design.len == 0 or args.reps == 0) exit.fatal("{s}", .{bench_usage});
    return args;
}

/// Stable correctness signature over rises rounded to 0.1 millikelvin. It is
/// strict enough to catch a changed field while tolerating harmless SIMD
/// reduction-order noise below the model's precision.
fn fieldChecksum(results: []const thermal_field.ScenarioResult) u64 {
    var hash = std.hash.Wyhash.init(0x7a1f_39d2_4c65_b8e0);
    for (results) |result| {
        hash.update(std.mem.asBytes(&result.scenario));
        hash.update(std.mem.asBytes(&result.grid.cols));
        hash.update(std.mem.asBytes(&result.grid.rows));
        for (result.grid.rise_c) |rise| {
            const quantized: i64 = @intFromFloat(@round(@as(f64, rise) * 10_000.0));
            hash.update(std.mem.asBytes(&quantized));
        }
    }
    return hash.final();
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn compareCommandInner(alloc: std.mem.Allocator, argv: []const []const u8) anyerror!void {
    const args = parseArgs(argv, true);
    var eval = Evaluator.init(alloc, args.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer dropModule(alloc, module_res);
    const prepared = try prepare(alloc, args, &eval, &module_res);
    const output_dir = try outputDir(alloc, args);
    try writeCase(alloc, output_dir, prepared.artifact);

    const run = std.process.run(alloc, infra_fs.currentIo(), .{
        .argv = &.{ args.solver, "case.sif" },
        .cwd = .{ .path = output_dir },
    }) catch |err| exit.fatal("Could not run Elmer solver '{s}': {s}\n", .{ args.solver, @errorName(err) });
    defer alloc.free(run.stdout);
    defer alloc.free(run.stderr);
    if (!run.term.success()) {
        try printOut("{s}{s}", .{ run.stdout, run.stderr });
        exit.fatal("ElmerSolver failed: {f}\n", .{run.term});
    }

    const result_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ output_dir, export_elmer.result_filename });
    const xml = infra_fs.cwd().readFileAlloc(alloc, result_path, 256 * 1024 * 1024) catch |err|
        exit.fatal("Elmer did not produce {s}: {s}\n", .{ result_path, @errorName(err) });
    const parsed = export_elmer.parseVtu(alloc, xml, prepared.input.model) catch |err|
        exit.fatal("Could not parse Elmer result {s}: {s}\n", .{ result_path, @errorName(err) });
    const comparison = try export_elmer.compare(alloc, prepared.input, parsed);
    const comparison_json = try export_elmer.comparisonJson(alloc, comparison);
    const comparison_md = try export_elmer.comparisonMarkdown(alloc, prepared.input, comparison);
    try writeAt(alloc, output_dir, "comparison.json", comparison_json);
    try writeAt(alloc, output_dir, "comparison.md", comparison_md);
    try std.Io.File.stdout().writeStreamingAll(infra_fs.currentIo(), comparison_md);
    try printOut("\nComparison files: {s}/comparison.md and comparison.json\n", .{output_dir});
}

fn parseArgs(argv: []const []const u8, compare_mode: bool) Args {
    var args = Args{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (takesValue(arg)) {
            if (i + 1 >= argv.len) exit.fatal("Missing value after {s}\n{s}", .{ arg, if (compare_mode) compare_usage else export_usage });
            const value = argv[i + 1];
            i += 1;
            applyValueOption(&args, arg, value, compare_mode);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            exit.fatal("Unknown option {s}\n{s}", .{ arg, if (compare_mode) compare_usage else export_usage });
        } else if (args.design.len == 0) {
            args.design = arg;
        } else {
            exit.fatal("Unexpected argument {s}\n{s}", .{ arg, if (compare_mode) compare_usage else export_usage });
        }
    }
    if (args.design.len == 0) exit.fatal("{s}", .{if (compare_mode) compare_usage else export_usage});
    if (!std.math.isFinite(args.ambient_c)) exit.fatal("Ambient temperature must be finite\n", .{});
    if (!validHeatsink(args.heatsink)) {
        exit.fatal("Heatsink dimensions/conductivity must be positive; base, fin height, theta-SA, and pad thickness may be zero\n", .{});
    }
    return args;
}

fn applyValueOption(args: *Args, arg: []const u8, value: []const u8, compare_mode: bool) void {
    if (isHeatsinkOption(arg)) args.heatsink_explicit = true;
    if (std.mem.eql(u8, arg, "--project-dir")) args.project_dir = value else if (std.mem.eql(u8, arg, "--output-dir")) args.output_dir = value else if (std.mem.eql(u8, arg, "--layout")) args.layout = value else if (std.mem.eql(u8, arg, "--solver")) args.solver = value else if (std.mem.eql(u8, arg, "--scenario")) {
        args.scenario = parseScenario(value, compare_mode);
    } else if (std.mem.eql(u8, arg, "--ambient")) {
        args.ambient_c = std.fmt.parseFloat(f64, value) catch exit.fatal("Invalid ambient temperature '{s}'\n", .{value});
    } else if (std.mem.eql(u8, arg, "--heatsink-ref")) {
        args.heatsink.ref_des = value;
    } else if (std.mem.eql(u8, arg, "--heatsink-side")) {
        args.heatsink.side = std.meta.stringToEnum(thermal_field.HeatsinkSide, value) orelse
            exit.fatal("Unknown heatsink side '{s}'; choose package_top or board_backside\n", .{value});
    } else if (std.mem.eql(u8, arg, "--sink-width-mm")) {
        args.heatsink.geometry.width_mm = parseFloatOption(arg, value);
    } else if (std.mem.eql(u8, arg, "--sink-length-mm")) {
        args.heatsink.geometry.length_mm = parseFloatOption(arg, value);
    } else if (std.mem.eql(u8, arg, "--sink-base-mm")) {
        args.heatsink.geometry.base_mm = parseFloatOption(arg, value);
    } else if (std.mem.eql(u8, arg, "--sink-fin-height-mm")) {
        args.heatsink.geometry.profile.finned.height_mm = parseFloatOption(arg, value);
    } else if (std.mem.eql(u8, arg, "--sink-fin-count")) {
        args.heatsink.geometry.profile.finned.count = std.fmt.parseInt(usize, value, 10) catch exit.fatal("Invalid value '{s}' after {s}\n", .{ value, arg });
    } else if (std.mem.eql(u8, arg, "--sink-theta-sa")) {
        args.heatsink.theta_sa_c_per_w = parseFloatOption(arg, value);
    } else if (std.mem.eql(u8, arg, "--pad-thickness-mm")) {
        args.heatsink.pad.thickness_mm = parseFloatOption(arg, value);
    } else if (std.mem.eql(u8, arg, "--pad-k")) {
        args.heatsink.pad.conductivity_w_mk = parseFloatOption(arg, value);
    }
}

fn isHeatsinkOption(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--heatsink-ref") or
        std.mem.eql(u8, arg, "--heatsink-side") or
        std.mem.startsWith(u8, arg, "--sink-") or
        std.mem.eql(u8, arg, "--pad-thickness-mm") or
        std.mem.eql(u8, arg, "--pad-k");
}

fn validHeatsink(hs: thermal_field.Heatsink) bool {
    if (!(hs.geometry.width_mm > 0) or !(hs.geometry.length_mm > 0)) return false;
    if (!(hs.geometry.base_mm >= 0)) return false;
    switch (hs.geometry.profile) {
        .finned => |fins| if (!(fins.height_mm >= 0) or fins.count == 0) return false,
        .stepped => |lower| if (!(lower.width_mm > 0 and lower.length_mm > 0 and lower.height_mm > 0)) return false,
    }
    if (!(hs.theta_sa_c_per_w >= 0)) return false;
    if (!(hs.pad.thickness_mm >= 0) or !(hs.pad.conductivity_w_mk > 0)) return false;
    return true;
}

fn parseFloatOption(name: []const u8, value: []const u8) f64 {
    const parsed = std.fmt.parseFloat(f64, value) catch exit.fatal("Invalid value '{s}' after {s}\n", .{ value, name });
    if (!std.math.isFinite(parsed)) exit.fatal("Value after {s} must be finite\n", .{name});
    return parsed;
}

fn takesValue(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--project-dir") or
        std.mem.eql(u8, arg, "--output-dir") or
        std.mem.eql(u8, arg, "--layout") or
        std.mem.eql(u8, arg, "--solver") or
        std.mem.eql(u8, arg, "--scenario") or
        std.mem.eql(u8, arg, "--ambient") or
        std.mem.eql(u8, arg, "--heatsink-ref") or
        std.mem.eql(u8, arg, "--heatsink-side") or
        std.mem.eql(u8, arg, "--sink-width-mm") or
        std.mem.eql(u8, arg, "--sink-length-mm") or
        std.mem.eql(u8, arg, "--sink-base-mm") or
        std.mem.eql(u8, arg, "--sink-fin-height-mm") or
        std.mem.eql(u8, arg, "--sink-fin-count") or
        std.mem.eql(u8, arg, "--sink-theta-sa") or
        std.mem.eql(u8, arg, "--pad-thickness-mm") or
        std.mem.eql(u8, arg, "--pad-k");
}

fn parseScenario(value: []const u8, compare_mode: bool) thermal_field.Scenario {
    const scenario = std.meta.stringToEnum(thermal_field.Scenario, value) orelse
        exit.fatal("Unknown thermal scenario '{s}'\n{s}", .{ value, if (compare_mode) compare_usage else export_usage });
    return scenario;
}

fn prepare(
    alloc: std.mem.Allocator,
    args: Args,
    eval: *Evaluator,
    module_res: *?modules_mod.ResolvedBlock,
) anyerror!Prepared {
    const solved = pcb_layout_page.solveForRequest(
        alloc,
        args.project_dir,
        args.design,
        .{ .layout = args.layout },
        eval,
        module_res,
    ) catch |err| exit.fatal("Could not resolve board layout for {s}: {s}\n", .{ args.design, @errorName(err) });
    if (solved.placement.parts.len == 0) exit.fatal("The resolved board has no placed parts\n", .{});
    const board_thermal = thermal.analyze(alloc, solved.block, args.ambient_c) catch |err|
        exit.fatal("Thermal analysis failed for {s}: {s}\n", .{ args.design, @errorName(err) });
    if (board_thermal.counts.with_power == 0) exit.fatal("No part declares thermal dissipation\n", .{});
    const copper = pcb_layout_page.thermalCopper(solved);
    var inputs = try thermal_scenarios.inputsFor(alloc, board_thermal, solved.placement, copper);
    inputs.cooling.heatsink = selectedHeatsink(args, pcb_layout_page.thermalHeatsink(solved, board_thermal));
    if (pcb_layout_page.thermalFan(solved)) |fan| inputs.cooling.fan = fan;
    const builtin = try thermal_field.solveScenario(alloc, inputs, args.scenario);
    if (!builtin.converged) exit.fatal("The built-in thermal solve did not converge; refusing a misleading comparison\n", .{});
    const model = try thermal_field.discretize(alloc, inputs, args.scenario);
    const input = export_elmer.Input{
        .design_name = args.design,
        .layout_name = args.layout orelse "",
        .ambient_c = args.ambient_c,
        .sheet = thermal_scenarios.sheetOf(solved.placement.rules),
        .model = model,
        .solver_inputs = inputs,
        .builtin = builtin,
    };
    return .{ .input = input, .artifact = try export_elmer.build(alloc, input) };
}

fn selectedHeatsink(args: Args, saved: ?thermal_field.Heatsink) thermal_field.Heatsink {
    return if (!args.heatsink_explicit) saved orelse args.heatsink else args.heatsink;
}

fn outputDir(alloc: std.mem.Allocator, args: Args) std.mem.Allocator.Error![]const u8 {
    if (args.output_dir.len != 0) return args.output_dir;
    return std.fmt.allocPrint(alloc, "{s}-elmer-thermal", .{args.design});
}

fn writeCase(alloc: std.mem.Allocator, output_dir: []const u8, artifact: export_elmer.Artifact) anyerror!void {
    const mesh_dir = try std.fmt.allocPrint(alloc, "{s}/mesh", .{output_dir});
    try infra_fs.cwd().makePath(mesh_dir);
    try writeAt(alloc, output_dir, "mesh/mesh.header", artifact.mesh_header);
    try writeAt(alloc, output_dir, "mesh/mesh.nodes", artifact.mesh_nodes);
    try writeAt(alloc, output_dir, "mesh/mesh.elements", artifact.mesh_elements);
    try writeAt(alloc, output_dir, "mesh/mesh.boundary", artifact.mesh_boundary);
    try writeAt(alloc, output_dir, "case.sif", artifact.sif);
    try writeAt(alloc, output_dir, "manifest.json", artifact.manifest);
    try writeAt(alloc, output_dir, "README.md", artifact.readme);
}

fn writeAt(alloc: std.mem.Allocator, dir: []const u8, name: []const u8, data: []const u8) anyerror!void {
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
    try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

fn printOut(comptime format: []const u8, args: anytype) std.Io.Writer.Error!void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(infra_fs.currentIo(), &buffer);
    try stdout.interface.print(format, args);
    try stdout.interface.flush();
}

fn dropModule(alloc: std.mem.Allocator, res: ?modules_mod.ResolvedBlock) void {
    const module = res orelse return;
    module.eval.deinit();
    alloc.destroy(module.eval);
}

// spec: export_elmer_thermal - the CLI defaults to 25 C ambient and natural still air, accepts either forced-air rung and a saved layout, and can export without running Elmer
test "Elmer export arguments default to still air and accept airflow and a saved layout" {
    const defaults = parseArgs(&.{"fixture"}, false);
    try std.testing.expectEqual(@as(f64, 25), defaults.ambient_c);
    try std.testing.expectEqualStrings("ElmerSolver", defaults.solver);
    try std.testing.expect(defaults.layout == null);
    try std.testing.expectEqual(thermal_field.Scenario.natural, defaults.scenario);

    const saved = parseArgs(&.{ "--layout", "saved-layout", "--scenario", "airflow_2ms", "fixture" }, false);
    try std.testing.expectEqualStrings("saved-layout", saved.layout.?);
    try std.testing.expectEqualStrings("fixture", saved.design);
    try std.testing.expectEqual(thermal_field.Scenario.airflow_2ms, saved.scenario);

    const sunk = parseArgs(&.{
        "--scenario",      "heatsink", "--heatsink-ref",   "U15", "--heatsink-side",    "package_top",
        "--sink-width-mm", "20",       "--sink-length-mm", "18",  "--pad-thickness-mm", "0.5",
        "--pad-k",         "6",        "fixture",
    }, true);
    try std.testing.expectEqual(thermal_field.Scenario.heatsink, sunk.scenario);
    try std.testing.expectEqualStrings("U15", sunk.heatsink.ref_des);
    try std.testing.expectEqual(thermal_field.HeatsinkSide.package_top, sunk.heatsink.side);
    try std.testing.expectEqual(@as(f64, 0.5), sunk.heatsink.pad.thickness_mm);
    try std.testing.expect(sunk.heatsink_explicit);

    const authored = thermal_field.Heatsink{ .ref_des = "U22", .material = .aluminum_6061 };
    try std.testing.expectEqualStrings("U22", selectedHeatsink(defaults, authored).ref_des);
    try std.testing.expectEqualStrings("U15", selectedHeatsink(sunk, authored).ref_des);
}

// spec: placement/thermal_field - the thermal kernel benchmark accepts a board, saved layout and positive repetition count while keeping project resolution outside its timed solve loop
test "thermal benchmark arguments name one resolved board and repetition count" {
    const args = parseBenchArgs(&.{ "--project-dir", "fixtures", "--layout", "Best2", "--reps", "7", "board-a" });
    try std.testing.expectEqualStrings("fixtures", args.project_dir);
    try std.testing.expectEqualStrings("Best2", args.layout.?);
    try std.testing.expectEqual(@as(usize, 7), args.reps);
    try std.testing.expectEqualStrings("board-a", args.design);
}
