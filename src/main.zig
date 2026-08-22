//! CLI entry point: parses the subcommand from argv and dispatches to the
//! `commands.zig` handlers (build/check/export/import) or the local
//! convert/parse/token helpers, printing usage on an unknown command. Also
//! resolves the auth directory (CLI flag -> `EDA_AUTH_DIR` -> `<project>/auth`)
//! shared with the long-running `serve` flow.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const config = @import("config.zig");
const parser = @import("sexpr/parser.zig");
const printer = @import("sexpr/printer.zig");
const docgen = @import("docgen.zig");
const footprint_conv = @import("convert/footprint.zig");
const symbol_conv = @import("convert/symbol.zig");
const alt_functions = @import("convert/alt_functions.zig");
const serve_mod = @import("serve.zig");
const commands = @import("commands.zig");
const elmer_thermal_command = @import("elmer_thermal_command.zig");
const query = @import("query.zig");
const bench_route = @import("bench_route.zig");
const plugin_tokens = @import("serve/plugin_tokens.zig");
const build_id = @import("build_id.zig");

/// Process capabilities installed from `std.process.Init` for infrastructure
/// adapters imported throughout the application graph.
pub var process_io: std.Io = .failing;
pub var process_environ_map: ?*const std.process.Environ.Map = null;
/// Immutable identity installed from paired deployment metadata at startup.
pub var process_build_id: []const u8 = "unknown";

// ── Constants ─────────────────────────────────────────────────────
const default_serve_port: u16 = 7050;
const parse_port_radix: u8 = 10;
const filter_flag = "--filter";
const convert_error_fmt = "Convert error: {}\n";
const error_reading_fmt = "Error reading {s}: {}\n";
const alt_source_max_bytes: usize = 20 * 1024 * 1024;

/// Return the value of `--<flag>` if present anywhere in `args`, else null.
fn optionalArg(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

/// Return true if `--<flag>` appears anywhere in `args`.
fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

/// Read `EDA_AUTH_DIR` from the environment so multiple worktrees / project
/// checkouts can share one plugin-token store. Returns `null` when the
/// env var is unset; the caller falls back to the `<project_dir>/auth`
/// default. Caller owns any returned slice (allocator-owned dupe).
fn readAuthDirEnv(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    const value = environ.get("EDA_AUTH_DIR") orelse return null;
    return allocator.dupe(u8, value) catch null;
}

/// Resolve the auth directory from CLI args, env, or `<project_dir>/auth`.
/// Returns the same answer the long-running `serve` flow uses, so CLI helpers
/// (mint-plugin-token) operate on the same files the server writes.
fn resolveAuthDir(
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    args: []const []const u8,
) ![]const u8 {
    const project_dir = optionalArg(args, "--project-dir") orelse ".";
    if (optionalArg(args, "--auth-dir")) |d| return d;
    if (readAuthDirEnv(allocator, environ)) |d| return d;
    return std.fmt.allocPrint(allocator, "{s}/auth", .{project_dir});
}

/// CLI entry point: parses `argv[1]` as the subcommand name and dispatches
/// to the matching `cmd*` handler in `commands.zig` (or one of the local
/// `convert-*` / `parse` / `mint-plugin-token` helpers). Prints the usage
/// banner and exits 1 on unknown commands.
pub fn main(init: std.process.Init) !void {
    process_io = init.io;
    process_environ_map = init.environ_map;
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    process_build_id = build_id.load(init.io, arena, ".");
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try printUsage();
        std.process.exit(1);
    }

    const command = args[1];
    if (try dispatchKicadCommand(allocator, command, args[2..])) return;
    if (try dispatchQueryCommand(allocator, command, args[2..])) return;

    if (std.mem.eql(u8, command, "parse")) {
        if (args.len < 3) {
            std.debug.print("Usage: netlisp parse <file>\n", .{});
            std.process.exit(1);
        }
        try cmdParse(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "build")) {
        try commands.cmdBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "check")) {
        try commands.cmdCheck(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "convert-footprint")) {
        if (args.len < 3) {
            std.debug.print("Usage: netlisp convert-footprint <file.kicad_mod>\n", .{});
            std.process.exit(1);
        }
        try cmdConvertFootprint(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "convert-symbol")) {
        if (args.len < 3) {
            std.debug.print("Usage: netlisp convert-symbol <file.kicad_sym> [--filter <name>]\n", .{});
            std.process.exit(1);
        }
        try cmdConvertSymbol(allocator, args[2], optionalArg(args[3..], filter_flag));
    } else if (std.mem.eql(u8, command, "convert-package")) {
        if (args.len < 4) {
            std.debug.print("Usage: netlisp convert-package <file.kicad_sym> <file.kicad_mod> [--name <n>] [--filter <f>]\n", .{});
            std.process.exit(1);
        }
        const pkg_name = optionalArg(args[4..], "--name") orelse "package";
        const filter = optionalArg(args[4..], filter_flag);
        try cmdConvertPackage(allocator, args[2], args[3], pkg_name, filter);
    } else if (std.mem.eql(u8, command, "convert-pinout")) {
        if (args.len < 3) {
            std.debug.print("Usage: netlisp convert-pinout <file.kicad_sym> [--filter <name>]\n", .{});
            std.process.exit(1);
        }
        try cmdConvertPinout(allocator, args[2], optionalArg(args[3..], filter_flag));
    } else if (std.mem.eql(u8, command, "merge-alt-functions")) {
        if (args.len < 4) {
            std.debug.print("Usage: netlisp merge-alt-functions <pinout.sexp> <alts.csv|alts.xml> [--write]\n", .{});
            std.process.exit(1);
        }
        try cmdMergeAltFunctions(allocator, args[2], args[3], hasFlag(args[4..], "--write"));
    } else if (std.mem.eql(u8, command, "export-kicad")) {
        try commands.cmdExportKicad(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "export-kicad-sch")) {
        try commands.cmdExportKicadSch(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "export-pdf")) {
        try commands.cmdExportPdf(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "serve")) {
        try dispatchServe(init.io, allocator, args[2..], arena, init.environ_map);
    } else if (std.mem.eql(u8, command, "mint-plugin-token")) {
        const label = optionalArg(args[2..], "--label") orelse "plugin";
        const auth_dir = try resolveAuthDir(arena, init.environ_map, args[2..]);
        var pts: plugin_tokens.PluginTokenStore = .{};
        const raw = try pts.mint(allocator, auth_dir, label);
        defer allocator.free(raw);
        try writeStdout(raw);
        try writeStdout("\n");
        try writeStdout("Save this token — it will not be shown again.\n");
    } else if (std.mem.eql(u8, command, "gen-language-docs")) {
        const out_path = optionalArg(args[2..], "--output") orelse "docs/language-forms.md";
        const check_only = hasFlag(args[2..], "--check");
        try cmdGenLanguageDocs(allocator, out_path, check_only);
    } else if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-V")) {
        try cmdVersion();
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
        std.process.exit(1);
    }
}

/// Handle the related KiCad-source ingest/inspection commands outside the
/// already-large main dispatch chain.
fn dispatchKicadCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
) !bool {
    if (std.mem.eql(u8, command, "export-schematic-png")) {
        try commands.cmdExportSchematicPng(allocator, args);
        return true;
    }
    if (std.mem.eql(u8, command, "import-kicad")) {
        try commands.cmdImportKicad(allocator, args);
        return true;
    }
    if (std.mem.eql(u8, command, "import-kicad-layout")) {
        try commands.cmdImportKicadLayout(allocator, args);
        return true;
    }
    if (std.mem.eql(u8, command, "backfill-layouts")) {
        try commands.cmdBackfillLayouts(allocator, args);
        return true;
    }
    if (std.mem.eql(u8, command, "merge-layout")) {
        try commands.cmdMergeLayout(allocator, args);
        return true;
    }
    if (std.mem.eql(u8, command, "sync-kicad-sch")) {
        try commands.cmdSyncKicadSch(allocator, args);
        return true;
    }
    if (std.mem.eql(u8, command, "inspect-kicad")) {
        try commands.cmdInspectKicad(allocator, args);
        return true;
    }
    if (std.mem.eql(u8, command, "route-kicad-reference")) {
        try commands.cmdRouteKicadReference(allocator, args);
        return true;
    }
    return false;
}

/// Dispatch the read-only introspection family (`query.zig`) plus the routing
/// benchmark, returning true when `command` was one of them. Grouped out of
/// `main` for the same reason the KiCad family is: each is a one-line delegation
/// whose only variation is the handler name, and a flat chain of them buries the
/// dispatcher's real branches.
fn dispatchQueryCommand(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
) !bool {
    if (std.mem.eql(u8, command, "export-elmer-thermal")) {
        elmer_thermal_command.exportCommand(allocator, args);
        return true;
    }
    if (std.mem.eql(u8, command, "compare-elmer-thermal")) {
        elmer_thermal_command.compareCommand(allocator, args);
        return true;
    }
    if (std.mem.eql(u8, command, "bench-thermal")) {
        elmer_thermal_command.benchCommand(allocator, args);
        return true;
    }
    const Entry = struct {
        name: []const u8,
        run: *const fn (std.mem.Allocator, []const []const u8) query.QueryError!void,
    };
    const table = [_]Entry{
        .{ .name = "designs", .run = query.cmdDesigns },
        .{ .name = "instances", .run = query.cmdInstances },
        .{ .name = "net", .run = query.cmdNet },
        .{ .name = "free-pins", .run = query.cmdFreePins },
        .{ .name = "schematic", .run = query.cmdSchematic },
        .{ .name = "describe", .run = query.cmdDescribe },
        .{ .name = "library", .run = query.cmdLibrary },
        .{ .name = "reference", .run = query.cmdReference },
    };
    for (table) |e| {
        if (std.mem.eql(u8, command, e.name)) {
            try e.run(allocator, args);
            return true;
        }
    }
    if (std.mem.eql(u8, command, "bench-route")) {
        try bench_route.cmdBenchRoute(allocator, args);
        return true;
    }
    return false;
}

/// Regenerate (or, with `--check`, verify) the auto-generated language
/// reference. Walks every dispatch table aggregated by `src/docgen.zig`
/// and writes a Markdown reference to `out_path` (default
/// `docs/language-forms.md`). `zig build test` runs the `--check` mode,
/// so editing a registry without regenerating the file fails the build.
fn cmdGenLanguageDocs(allocator: std.mem.Allocator, out_path: []const u8, check_only: bool) !void {
    const rendered = try docgen.renderLanguageReference(allocator);
    defer allocator.free(rendered);

    if (check_only) {
        const committed = infra_fs.cwd().readFileAlloc(allocator, out_path, 1024 * 1024) catch |err| {
            std.debug.print("docs check FAILED: cannot read {s} ({any}) — run `zig build docs` to generate it\n", .{ out_path, err });
            std.process.exit(1);
        };
        defer allocator.free(committed);
        if (!std.mem.eql(u8, committed, rendered)) {
            std.debug.print("docs check FAILED: {s} is out of date with the dispatch tables — run `zig build docs` to regenerate\n", .{out_path});
            std.process.exit(1);
        }
        std.debug.print("docs check OK: {s} matches the dispatch tables\n", .{out_path});
        return;
    }

    const file = infra_fs.cwd().createFile(out_path, .{ .truncate = true }) catch |err| {
        std.debug.print("Error opening {s}: {}\n", .{ out_path, err });
        std.process.exit(1);
    };
    defer file.close();
    try file.writeAll(rendered);
    std.debug.print("Wrote {s} ({d} bytes)\n", .{ out_path, rendered.len });
}

/// Resolve and start the web/MCP server (`serve` command). Extracted from
/// `main`'s dispatch chain to keep that chain's cognitive complexity under the
/// Guardian cap.
fn dispatchServe(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, arena: std.mem.Allocator, environ: *const std.process.Environ.Map) !void {
    const project_dir = optionalArg(args, "--project-dir") orelse ".";
    const port: u16 = if (optionalArg(args, "--port")) |p|
        std.fmt.parseInt(u16, p, parse_port_radix) catch default_serve_port
    else
        default_serve_port;
    const auth_dir_override = optionalArg(args, "--auth-dir") orelse readAuthDirEnv(arena, environ);
    try serve_mod.serve(io, allocator, port, project_dir, auth_dir_override);
}

/// Print the runtime build id (the deployment-provided EDA commit from
/// `.git/netlisp-deploy-id`, or the current checkout's git HEAD short hash).
fn cmdVersion() !void {
    try writeStdout(process_build_id);
    try writeStdout("\n");
}

fn cmdParse(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = infra_fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(error_reading_fmt, .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    var diag: parser.ParseDiagnostic = .{};
    const nodes = parser.parseDiag(allocator, source, &diag) catch {
        // Compiler-style `file:line:col: error: message` — the same shape the
        // build/check paths and the server use for eval errors.
        std.debug.print("{s}:{d}:{d}: error: {s}\n", .{ path, diag.span.line, diag.span.col, diag.message });
        std.process.exit(1);
    };
    defer parser.freeNodes(allocator, nodes);

    const output = try printer.print(allocator, nodes);
    defer allocator.free(output);

    try writeStdout(output);
    try writeStdout("\n");
}

fn cmdConvertFootprint(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = infra_fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(error_reading_fmt, .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const output = footprint_conv.convertFootprint(allocator, source) catch |err| {
        std.debug.print(convert_error_fmt, .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    try writeStdout(output);
}

fn cmdConvertPackage(allocator: std.mem.Allocator, sym_path: []const u8, fp_path: []const u8, name: []const u8, filter: ?[]const u8) !void {
    const sym_source = infra_fs.cwd().readFileAlloc(allocator, sym_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(error_reading_fmt, .{ sym_path, err });
        std.process.exit(1);
    };
    defer allocator.free(sym_source);
    const fp_source = infra_fs.cwd().readFileAlloc(allocator, fp_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(error_reading_fmt, .{ fp_path, err });
        std.process.exit(1);
    };
    defer allocator.free(fp_source);

    const output = symbol_conv.generatePackage(allocator, sym_source, fp_source, name, filter) catch |err| {
        std.debug.print(convert_error_fmt, .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    try writeStdout(output);
}

fn cmdMergeAltFunctions(allocator: std.mem.Allocator, pinout_path: []const u8, src_path: []const u8, write_back: bool) !void {
    const pinout_src = infra_fs.cwd().readFileAlloc(allocator, pinout_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(error_reading_fmt, .{ pinout_path, err });
        std.process.exit(1);
    };
    defer allocator.free(pinout_src);
    const alt_src = infra_fs.cwd().readFileAlloc(allocator, src_path, alt_source_max_bytes) catch |err| {
        std.debug.print(error_reading_fmt, .{ src_path, err });
        std.process.exit(1);
    };
    defer allocator.free(alt_src);

    const entries = alt_functions.parseAltSource(allocator, alt_src) catch |err| {
        std.debug.print("Alt-function parse error: {}\n", .{err});
        std.process.exit(1);
    };
    const output = alt_functions.mergePinoutWithAlts(allocator, pinout_src, entries) catch |err| {
        std.debug.print("Merge error: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    if (write_back) {
        infra_fs.cwd().writeFile(.{ .sub_path = pinout_path, .data = output }) catch |err| {
            std.debug.print("Error writing {s}: {}\n", .{ pinout_path, err });
            std.process.exit(1);
        };
        std.debug.print("Merged {d} alt-function rows into {s}\n", .{ entries.len, pinout_path });
    } else {
        try writeStdout(output);
    }
}

fn cmdConvertPinout(allocator: std.mem.Allocator, path: []const u8, filter: ?[]const u8) !void {
    const source = infra_fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(error_reading_fmt, .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const output = symbol_conv.generatePinout(allocator, source, filter) catch |err| {
        std.debug.print(convert_error_fmt, .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    try writeStdout(output);
}

fn cmdConvertSymbol(allocator: std.mem.Allocator, path: []const u8, filter: ?[]const u8) !void {
    const source = infra_fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print(error_reading_fmt, .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const output = symbol_conv.convertSymbol(allocator, source, filter) catch |err| {
        std.debug.print(convert_error_fmt, .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    try writeStdout(output);
}

fn writeStdout(bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(infra_fs.currentIo(), bytes);
}

fn printUsage() !void {
    try writeStdout(
        \\netlisp — Electronic Design Automation CLI
        \\
        \\Usage:
        \\  netlisp parse <file>                   Parse and pretty-print an S-expression file
        \\  netlisp build [--project-dir <d>]       Evaluate and emit resolved design
        \\  netlisp check [--project-dir <d>] [--severity <s>] [--profile authoring|preflight] <name>  Run ERC + requirements
        \\  netlisp designs [--project-dir <d>]     List designs (name + title) as JSON
        \\  netlisp instances [--project-dir <d>] <name>  List a design's parts as JSON
        \\  netlisp net [--project-dir <d>] <name> <net>  Pins + passives on a net as JSON
        \\  netlisp free-pins [--project-dir <d>] <name> <ref> [--category <c>]  Unassigned pins on an IC
        \\  netlisp schematic [--project-dir <d>] <name>  Full scene-graph JSON (instances, nets, ports, ERC)
        \\  netlisp describe [--project-dir <d>] <component>  Component definition + datasheet requirements as JSON
        \\  netlisp library [--project-dir <d>] [query]  Fuzzy-search components/modules/parts/footprints
        \\  netlisp reference [section]             Print the DSL grammar reference (docs/language-forms.md)
        \\  netlisp serve [--project-dir <d>] [--port <n>]  Start web server (default port 7050)
        \\  netlisp mint-plugin-token [--project-dir <d>] [--label <l>]  Mint a bearer token for the KiCad plugin
        \\  netlisp import-kicad <board.kicad_pcb> [--project-dir <d>] [--name <n>] [--title <t>] [--dry-run]  Migrate a KiCad board into a netlisp design
        \\  netlisp import-kicad-layout [--project-dir <d>] <design> [--board <path>] [--dry-run] [--chord-tol-mm <mm>]  Import a routed board's placement/outline/copper as the design's starred layout (board read-only)
        \\  netlisp backfill-layouts [--project-dir <d>] [<block>…] [--dry-run] [--limit <n>]  Recover layouts that survive only in history/ or git and append them as named rows
        \\  netlisp merge-layout [--project-dir <d>] <design> --from <source.layouts.json> --layout <name> [--star] [--dry-run]  Upsert one named layout without text-merging sidecars
        \\  netlisp inspect-kicad <board.kicad_pcb> [--nets]  Inspect physical layout + project routing rules as JSON (read-only)
        \\  netlisp route-kicad-reference <board.kicad_pcb> [--net <name>]... [--reference-guides|--reference-corridor|--reference-path] [--reference-tolerance-mm <mm>] [--output-png <preview.png>]  Virtually erase + route a fixed layout
        \\  netlisp export-kicad --project-dir <d> --output-dir <out> [--with-schematic] <name>  Export KiCad netlist + footprints (--with-schematic adds the .kicad_sch hierarchy + project sidecars, so the directory opens as a complete KiCad project)
        \\  netlisp export-kicad-sch --project-dir <d> [--output <root>] [--output-dir <dir>] [--flat] [--no-vendor-symbols] <name>  Export a hierarchical KiCad schematic (root + one .kicad_sch per section/module, plus sym-lib-table / fp-lib-table / <name>.kicad_pro / netlisp.kicad_sym; parts with a lib/sources/*.kicad_sym are drawn from it)
        \\  netlisp sync-kicad-sch --project-dir <d> [--dry-run] [--force] <name>  Push that schematic INTO the KiCad project directory the design's (kicad-pcb "<path>") names — guarded (refuses a hand-drawn sheet or a locked project; replaced files roll into backups/)
        \\  netlisp export-pdf [--project-dir <d>] <name> [--output <file>] [--theme light|dark]  Export the design-review PDF (cover, per-section schematics, validation + power tables)
        \\  netlisp export-elmer-thermal [--project-dir <d>] [--output-dir <out>] [--layout <name>] [--ambient <C>] [--scenario <natural|airflow_1ms|airflow_2ms>] <name>  Export an Elmer FEM thermal case
        \\  netlisp compare-elmer-thermal [--project-dir <d>] [--output-dir <out>] [--layout <name>] [--ambient <C>] [--scenario <natural|airflow_1ms|airflow_2ms>] [--solver <path>] <name>  Run Elmer and write a side-by-side thermal comparison
        \\  netlisp bench-thermal [--project-dir <d>] [--layout <name>] [--reps <n>] <name>  Benchmark only the built-in four-scenario thermal field solve
        \\  netlisp export-schematic-png [--project-dir <d>] <name> [--sub <slug>|--ref <hub>] [--view sequential|functional] [--theme light|dark] [--width <px>] [--output <file>]  Export a schematic block PNG without a browser
        \\  netlisp convert-footprint <file>        Convert KiCad .kicad_mod to .sexp
        \\  netlisp convert-symbol <file> [--filter <name>]  Convert KiCad .kicad_sym to .sexp
        \\  netlisp convert-pinout <file> [--filter <name>]  Generate pinout from KiCad .kicad_sym
        \\  netlisp merge-alt-functions <pinout.sexp> <alts.csv|alts.xml> [--write]  Merge alt functions (CSV or ST open-pin-data XML)
        \\  netlisp gen-language-docs [--output <path>] [--check]  Regenerate (or verify with --check) docs/language-forms.md from the dispatch tables
        \\  netlisp version                          Print the runtime build id (the EDA commit, or the current checkout's HEAD)
        \\  netlisp help                            Show this help
        \\
    );
}

// Pull in all test declarations
test {
    _ = @import("sexpr/ast.zig");
    _ = @import("sexpr/tokenizer.zig");
    _ = @import("sexpr/parser.zig");
    _ = @import("sexpr/printer.zig");
    _ = @import("eval/env.zig");
    _ = @import("eval/check_grammar.zig");
    _ = @import("eval/instance.zig");
    _ = @import("eval/builders.zig");
    _ = @import("eval/forms.zig");
    _ = @import("eval/builtins.zig");
    _ = @import("eval/fmt.zig");
    _ = @import("docgen.zig");
    _ = @import("query.zig");
    _ = @import("eval/evaluator.zig");
    _ = @import("eval/board_role_cases.zig");
    _ = @import("eval/section_maturity.zig");
    _ = @import("eval/ids.zig");
    _ = @import("refdes_stability.zig");
    _ = @import("eval/pin_enrichment.zig");
    _ = @import("eval/rails.zig");
    _ = @import("eval/test_point.zig");
    _ = @import("eval/micro_forms.zig");
    _ = @import("eval/electrical.zig");
    _ = @import("diagram/diagram.zig");
    _ = @import("render_html.zig");
    _ = @import("render_svg/context.zig");
    _ = @import("render_svg/connection.zig");
    _ = @import("render_svg/draw.zig");
    _ = @import("render_svg/hub.zig");
    _ = @import("layout_status.zig");
    _ = @import("githash.zig");
    _ = @import("eval/power_budget.zig");
    _ = @import("eval/thermal.zig");
    _ = @import("eval/power_sequencing.zig");
    _ = @import("req_checks_cases.zig");
    _ = @import("component_classification.zig");
    _ = @import("module_metadata.zig");
    _ = @import("canonical_module_check.zig");
    _ = @import("decouple_key.zig");
    _ = @import("placement/cap_bind.zig");
    _ = @import("placement/near_bind.zig");
    _ = @import("erc.zig");
    _ = @import("review_md.zig");
    _ = @import("review_html.zig");
    _ = @import("review_thermal.zig");
    _ = @import("thermal_scenarios.zig");
    _ = @import("export_elmer_thermal.zig");
    _ = @import("render_thermal_png.zig");
    _ = @import("id_insert.zig");
    _ = @import("emit.zig");
    _ = @import("convert/footprint.zig");
    _ = @import("convert/symbol.zig");
    _ = @import("import_kicad.zig");
    _ = @import("import_fold.zig");
    _ = @import("import_fold_emit.zig");
    _ = @import("convert/alt_functions.zig");
    _ = @import("flat_netlist.zig");
    _ = @import("export_kicad.zig");
    _ = @import("export_kicad_footprint.zig");
    _ = @import("export_kicad_sch.zig");
    _ = @import("kicad_sch/shape.zig");
    _ = @import("kicad_sch/glyph.zig");
    _ = @import("kicad_sch/bank.zig");
    _ = @import("kicad_sch/gang.zig");
    _ = @import("kicad_sch/stagger.zig");
    _ = @import("kicad_sch/stub.zig");
    _ = @import("kicad_sch/vendor.zig");
    _ = @import("kicad_sym/reader.zig");
    _ = @import("kicad_sym/library.zig");
    _ = @import("kicad_sch/sheet.zig");
    _ = @import("kicad_sch/emit.zig");
    _ = @import("kicad_sch/project.zig");
    _ = @import("kicad_sch/verify.zig");
    _ = @import("kicad_sch/textbox.zig");
    _ = @import("kicad_sch_push.zig");
    _ = @import("serve.zig");
    // `serve.zig` only reaches these modules from inside route-registration
    // bodies, which the test binary never analyzes, so their tests would be
    // collected by nobody. Bridge them the same way the rest of this list does.
    _ = @import("serve/pages.zig");
    _ = @import("serve/edit.zig");
    _ = @import("serve/mcp_docs.zig");
    _ = @import("serve/assembly_debug.zig");
    _ = @import("serve/assembly_page_cache.zig");
    _ = @import("serve/rework_guide.zig");
    _ = @import("serve/modules.zig");
    _ = @import("serve/schematic_pdf.zig");
    _ = @import("serve/thermal_api.zig");
    _ = @import("serve/thermal_cache.zig");
    _ = @import("serve/urlcodec.zig");
    _ = @import("serve/schematic_png.zig");
    _ = @import("serve/kicad_sch_export.zig");
    _ = @import("serve/sync_kicad_sch.zig");
    _ = @import("serve/auth_store.zig");
    _ = @import("serve/ward_auth.zig");
    _ = @import("serve/sync.zig");
    _ = @import("serve/board_backup.zig");
    _ = @import("serve/component_search.zig");
    _ = @import("serve/digikey.zig");
    _ = @import("serve/rate_limiter.zig");
    _ = @import("serve/subprocess.zig");
    _ = @import("serve/autocommit.zig");
    _ = @import("serve/datasheet.zig");
    _ = @import("serve/library.zig");
    _ = @import("serve/library_3d.zig");
    _ = @import("serve/footprint_preview.zig");
    _ = @import("config.zig");
    _ = @import("kicad_pcb/writer.zig");
    _ = @import("kicad_pcb/board_state.zig");
    _ = @import("kicad_pcb/reader.zig");
    _ = @import("kicad_pcb/snapshot.zig");
    _ = @import("kicad_pcb/project_rules.zig");
    _ = @import("kicad_pcb/inspect.zig");
    _ = @import("kicad_pcb/net_aliases.zig");
    _ = @import("kicad_pcb/experiment.zig");
    _ = @import("kicad_pcb/router_adapter.zig");
    _ = @import("kicad_pcb/reference_guides.zig");
    _ = @import("kicad_pcb/route_command.zig");
    _ = @import("kicad_pcb/route_score.zig");
    _ = @import("kicad_pcb/import_layout.zig");
    _ = @import("kicad_pcb/import_layout_json.zig");
    _ = @import("kicad_pcb/import_layout_command.zig");
    _ = @import("serve/style_score.zig");
    _ = @import("serve/layout_match.zig");
    _ = @import("serve/layout_backfill.zig");
    _ = @import("serve/layout_backfill_command.zig");
    _ = @import("serve/layout_merge_command.zig");
    _ = @import("render_json.zig");
    _ = @import("json_writer.zig");
    _ = @import("checks.zig");
    _ = @import("escape.zig");
    _ = @import("numeric.zig");
    _ = @import("paths.zig");
    _ = @import("lib_limits.zig");
    _ = @import("board_layers.zig");
    _ = @import("board_theme.zig");
    _ = @import("render_order.zig");
    _ = @import("placement/geometry.zig");
    _ = @import("placement/pin_roles.zig");
    _ = @import("placement/implicit_plane.zig");
    _ = @import("placement/mask_relief.zig");
    _ = @import("placement/pad_shape.zig");
    _ = @import("placement/outline.zig");
    _ = @import("placement/pour.zig");
    _ = @import("placement/courtyard_close.zig");
    _ = @import("placement/optimizer.zig");
    _ = @import("placement/critical_paths.zig");
    _ = @import("placement/critical_rough.zig");
    _ = @import("placement/critical_route_score.zig");
    _ = @import("placement/rf_path_solver.zig");
    _ = @import("placement/rf_port_frames.zig");
    _ = @import("placement/rf_port_finish.zig");
    _ = @import("placement/rf_port_report.zig");
    _ = @import("placement/edge_rotation.zig");
    _ = @import("placement/pose_snapshot.zig");
    _ = @import("placement/pose_math.zig");
    _ = @import("placement/pad_exit.zig");
    _ = @import("placement/drc_compose.zig");
    _ = @import("placement/bypass_open.zig");
    _ = @import("placement/routed_copper.zig");
    _ = @import("placement/router.zig");
    _ = @import("placement/router_vision_regression.zig");
    _ = @import("placement/router_waypoint_regression.zig");
    _ = @import("placement/copper_support.zig");
    _ = @import("placement/copper_topology_route_regression.zig");
    _ = @import("placement/net_topology_route_regression.zig");
    _ = @import("placement/route_score.zig");
    _ = @import("placement/fine_window.zig");
    _ = @import("placement/fine_accept.zig");
    _ = @import("placement/island_accept.zig");
    _ = @import("placement/dive_elide.zig");
    _ = @import("placement/via_merge.zig");
    _ = @import("placement/joint_rescue.zig");
    _ = @import("placement/congestion.zig");
    _ = @import("placement/blocker_nomination.zig");
    _ = @import("placement/escalate_retry.zig");
    _ = @import("placement/cdt_route.zig");
    _ = @import("placement/cdt_layers.zig");
    _ = @import("placement/pair_pinch.zig");
    _ = @import("placement/pinch_probe.zig");
    _ = @import("placement/place_repair.zig");
    _ = @import("placement/bend_smooth.zig");
    _ = @import("placement/octilinear.zig");
    _ = @import("placement/net_topology.zig");
    _ = @import("placement/plane_stitch.zig");
    _ = @import("placement/plane_stitch_route_regression.zig");
    _ = @import("placement/maze_scratch.zig");
    _ = @import("placement/manhattan_route.zig");
    _ = @import("placement/straighten.zig");
    _ = @import("placement/pad_entry.zig");
    _ = @import("placement/land_transit.zig");
    _ = @import("placement/pad_escape.zig");
    _ = @import("placement/via_centre.zig");
    _ = @import("placement/diff_pairs.zig");
    _ = @import("placement/via_guide.zig");
    _ = @import("placement/via_fence.zig");
    _ = @import("placement/perimeter_fence.zig");
    _ = @import("serve/pcb_fence.zig");
    _ = @import("serve/pcb_rules_json.zig");
    _ = @import("placement/copper_length.zig");
    _ = @import("placement/diff_route.zig");
    _ = @import("placement/diff_couple.zig");
    _ = @import("placement/diff_direct.zig");
    _ = @import("placement/diff_shape.zig");
    _ = @import("placement/drc.zig");
    _ = @import("placement/drc_diffpair.zig");
    _ = @import("placement/match_group.zig");
    _ = @import("placement/drc_match.zig");
    _ = @import("placement/keepout.zig");
    _ = @import("placement/rf_shadow.zig");
    _ = @import("eval/stackup_presets.zig");
    _ = @import("placement/drc_keepout.zig");
    _ = @import("placement/drc_perimeter_keepout.zig");
    _ = @import("serve/pcb_keepout_json.zig");
    _ = @import("serve/pour_json.zig");
    _ = @import("serve/layout_layers.zig");
    _ = @import("placement/pad_grid.zig");
    _ = @import("placement/keepout_route.zig");
    _ = @import("placement/gap_close_route.zig");
    _ = @import("placement/net_open.zig");
    _ = @import("placement/module_policy.zig");
    _ = @import("placement/layout_lint.zig");
    _ = @import("placement/impedance.zig");
    _ = @import("placement/impedance_rules.zig");
    _ = @import("placement/via_antipad.zig");
    _ = @import("placement/trace_em.zig");
    _ = @import("placement/routability_lint.zig");
    _ = @import("placement/rough_routability.zig");
    _ = @import("placement/port_escape.zig");
    _ = @import("placement/progress.zig");
    _ = @import("placement/plan_resolve.zig");
    _ = @import("placement/route_policy.zig");
    _ = @import("placement/guide_branch.zig");
    _ = @import("placement/escape_assign.zig");
    _ = @import("placement/connector_pinout.zig");
    _ = @import("placement/topo_plan.zig");
    _ = @import("placement/topo_lower.zig");
    _ = @import("placement/route_session.zig");
    _ = @import("placement/route_diagnose.zig");
    _ = @import("placement/route_cleanup.zig");
    _ = @import("placement/gap_policy.zig");
    _ = @import("placement/vacate_policy.zig");
    _ = @import("placement/route_timeline.zig");
    _ = @import("placement/return_path.zig");
    _ = @import("placement/shove.zig");
    _ = @import("serve/pcb_layout_page.zig");
    _ = @import("serve/layout_sidecar_json.zig");
    _ = @import("serve/placement_outline.zig");
    _ = @import("serve/pcb_part_json.zig");
    _ = @import("serve/pcb_layout_import.zig");
    _ = @import("serve/route_plan.zig");
    _ = @import("serve/subcircuit_route.zig");
    _ = @import("serve/route_review.zig");
    _ = @import("serve/route_analyze_api.zig");
    _ = @import("serve/route_session_api.zig");
    _ = @import("serve/route_live.zig");
    _ = @import("serve/route_vision.zig");
    _ = @import("serve/static_assets.zig");
    _ = @import("serve/pcb_describe.zig");
    _ = @import("serve/pcb_progress.zig");
    _ = @import("serve/drc_json.zig");
    _ = @import("serve/layer_table_json.zig");
    _ = @import("serve/stuck_json.zig");
    _ = @import("serve/drc_rules.zig");
    _ = @import("serve/fab_filename.zig");
    _ = @import("serve/diag_format.zig");
    _ = @import("serve/edit_assist.zig");
    _ = @import("serve/design_rules_edit.zig");
    _ = @import("serve/upload.zig");
    _ = @import("serve/component_info.zig");
    _ = @import("serve/design_diff.zig");
    _ = @import("serve/mcp_tools.zig");
    _ = @import("serve/mcp_route_experiment.zig");
    _ = @import("serve/mcp_connector_pinout.zig");
    _ = @import("route_repair.zig");
    _ = @import("serve/mcp_route_order.zig");
    _ = @import("serve/mcp_close_gaps.zig");
    _ = @import("serve/mcp_routability.zig");
    _ = @import("serve/mcp_kicad_sch.zig");
    _ = @import("serve/mcp_placement_sensitivity.zig");
    _ = @import("serve/mcp_escape_assign.zig");
    _ = @import("serve/mcp_route_trials.zig");
    _ = @import("serve/mcp_read_opts.zig");
    _ = @import("serve/mcp_flatten.zig");
    _ = @import("serve/datasheet_attach.zig");
    _ = @import("serve/page_cache.zig");
    _ = @import("serve/gzip_cache.zig");
    _ = @import("serve/pcb_page_cache.zig");
    _ = @import("serve/progress_cache.zig");
    _ = @import("deflate.zig");
    _ = @import("png.zig");
    _ = @import("font5x7.zig");
    _ = @import("subcircuit_silkscreen.zig");
    _ = @import("testpoint_silkscreen.zig");
    _ = @import("raster.zig");
    _ = @import("render_pcb_png.zig");
    _ = @import("render_schematic_png.zig");
    _ = @import("export_fab.zig");
    _ = @import("export_gerber.zig");
    _ = @import("export_matlab_rf.zig");
    _ = @import("silk_font.zig");
    _ = @import("fab_preview.zig");
    _ = @import("fab_identity.zig");
    _ = @import("fab_readiness.zig");
    _ = @import("target_unblock.zig");
    _ = @import("placement/route_close.zig");
    _ = @import("placement/route_grid.zig");
    _ = @import("placement/route_determinism.zig");
    _ = @import("bench_route.zig");
    _ = @import("gerber_verify.zig");
    _ = @import("zipfile.zig");

    // Memory-leak audit regression tests (src/leak_tests/) — exercise
    // allocator-owning paths under std.testing.allocator's leak detector.
    _ = @import("leak_tests/eval_core.zig");
    _ = @import("leak_tests/sexpr.zig");
    _ = @import("leak_tests/render.zig");
    _ = @import("leak_tests/diagram.zig");
    _ = @import("leak_tests/review_bom.zig");
    _ = @import("leak_tests/placement.zig");
    _ = @import("leak_tests/import_export.zig");
    _ = @import("leak_tests/checks.zig");
    _ = @import("leak_tests/serve_stores.zig");
    _ = @import("leak_tests/serve_request.zig");
    _ = @import("leak_tests/serve_auth_request.zig");
    _ = @import("wasm_drc.zig");
    _ = @import("drc_session.zig");
    _ = @import("pdf.zig");
    _ = @import("svg2pdf.zig");
    _ = @import("export_pdf.zig");
}
