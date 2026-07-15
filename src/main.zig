//! CLI entry point: parses the subcommand from argv and dispatches to the
//! `commands.zig` handlers (build/check/export/import) or the local
//! convert/parse/token helpers, printing usage on an unknown command. Also
//! resolves the auth directory (CLI flag -> `EDA_AUTH_DIR` -> `<project>/auth`)
//! shared with the long-running `serve` flow.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const parser = @import("sexpr/parser.zig");
const printer = @import("sexpr/printer.zig");
const docgen = @import("docgen.zig");
const footprint_conv = @import("convert/footprint.zig");
const symbol_conv = @import("convert/symbol.zig");
const alt_functions = @import("convert/alt_functions.zig");
const serve_mod = @import("serve.zig");
const commands = @import("commands.zig");
const query = @import("query.zig");
const plugin_tokens = @import("serve/plugin_tokens.zig");

// ── Constants ─────────────────────────────────────────────────────
const default_serve_port: u16 = 7050;
const parse_port_radix: u8 = 10;
const filter_flag = "--filter";
const convert_error_fmt = "Convert error: {}\n";
const error_reading_fmt = "Error reading {s}: {}\n";
const alt_source_max_bytes: usize = 20 * 1024 * 1024;

/// Return the value of `--<flag>` if present anywhere in `args`, else null.
fn optionalArg(args: [][:0]u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) return args[i + 1];
    }
    return null;
}

/// Return true if `--<flag>` appears anywhere in `args`.
fn hasFlag(args: [][:0]u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

/// Read `EDA_AUTH_DIR` from the environment so multiple worktrees / project
/// checkouts can share one plugin-token store. Returns `null` when the
/// env var is unset; the caller falls back to the `<project_dir>/auth`
/// default. Caller owns any returned slice (allocator-owned dupe).
fn readAuthDirEnv(allocator: std.mem.Allocator) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, "EDA_AUTH_DIR") catch null;
}

/// Resolve the auth directory from CLI args, env, or `<project_dir>/auth`.
/// Returns the same answer the long-running `serve` flow uses, so CLI helpers
/// (mint-plugin-token) operate on the same files the server writes.
fn resolveAuthDir(allocator: std.mem.Allocator, args: [][:0]u8) ![]const u8 {
    const project_dir = optionalArg(args, "--project-dir") orelse ".";
    if (optionalArg(args, "--auth-dir")) |d| return d;
    if (readAuthDirEnv(allocator)) |d| return d;
    return std.fmt.allocPrint(allocator, "{s}/auth", .{project_dir});
}

/// CLI entry point: parses `argv[1]` as the subcommand name and dispatches
/// to the matching `cmd*` handler in `commands.zig` (or one of the local
/// `convert-*` / `parse` / `mint-plugin-token` helpers). Prints the usage
/// banner and exits 1 on unknown commands.
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        std.process.exit(1);
    }

    const command = args[1];

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
    } else if (std.mem.eql(u8, command, "designs")) {
        try query.cmdDesigns(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "instances")) {
        try query.cmdInstances(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "net")) {
        try query.cmdNet(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "free-pins")) {
        try query.cmdFreePins(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "schematic")) {
        try query.cmdSchematic(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "describe")) {
        try query.cmdDescribe(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "library")) {
        try query.cmdLibrary(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "reference")) {
        try query.cmdReference(allocator, args[2..]);
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
    } else if (std.mem.eql(u8, command, "import-kicad")) {
        try commands.cmdImportKicad(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "export-kicad")) {
        try commands.cmdExportKicad(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "serve")) {
        const project_dir = optionalArg(args[2..], "--project-dir") orelse ".";
        const port: u16 = if (optionalArg(args[2..], "--port")) |p|
            std.fmt.parseInt(u16, p, parse_port_radix) catch default_serve_port
        else
            default_serve_port;
        const auth_dir_override = optionalArg(args[2..], "--auth-dir") orelse readAuthDirEnv(allocator);
        try serve_mod.serve(allocator, port, project_dir, auth_dir_override);
    } else if (std.mem.eql(u8, command, "mint-plugin-token")) {
        const label = optionalArg(args[2..], "--label") orelse "plugin";
        const auth_dir = try resolveAuthDir(allocator, args[2..]);
        var pts: plugin_tokens.PluginTokenStore = .{};
        const raw = try pts.mint(allocator, auth_dir, label);
        defer allocator.free(raw);
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(raw);
        try stdout.writeAll("\n");
        try stdout.writeAll("Save this token — it will not be shown again.\n");
    } else if (std.mem.eql(u8, command, "gen-language-docs")) {
        const out_path = optionalArg(args[2..], "--output") orelse "docs/language-forms.md";
        const check_only = hasFlag(args[2..], "--check");
        try cmdGenLanguageDocs(allocator, out_path, check_only);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
        std.process.exit(1);
    }
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

    const file = std.fs.File.stdout();
    try file.writeAll(output);
    try file.writeAll("\n");
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

    const file = std.fs.File.stdout();
    try file.writeAll(output);
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

    const file = std.fs.File.stdout();
    try file.writeAll(output);
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
        const file = std.fs.File.stdout();
        try file.writeAll(output);
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

    const file = std.fs.File.stdout();
    try file.writeAll(output);
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

    const file = std.fs.File.stdout();
    try file.writeAll(output);
}

fn printUsage() !void {
    const file = std.fs.File.stdout();
    try file.writeAll(
        \\netlisp — Electronic Design Automation CLI
        \\
        \\Usage:
        \\  netlisp parse <file>                   Parse and pretty-print an S-expression file
        \\  netlisp build [--project-dir <d>]       Evaluate and emit resolved design
        \\  netlisp check [--project-dir <d>] [--severity <s>] <name>  Run ERC on a design
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
        \\  netlisp export-kicad --project-dir <d> --output-dir <out> <name>  Export KiCad netlist + footprints
        \\  netlisp convert-footprint <file>        Convert KiCad .kicad_mod to .sexp
        \\  netlisp convert-symbol <file> [--filter <name>]  Convert KiCad .kicad_sym to .sexp
        \\  netlisp convert-pinout <file> [--filter <name>]  Generate pinout from KiCad .kicad_sym
        \\  netlisp merge-alt-functions <pinout.sexp> <alts.csv|alts.xml> [--write]  Merge alt functions (CSV or ST open-pin-data XML)
        \\  netlisp gen-language-docs [--output <path>] [--check]  Regenerate (or verify with --check) docs/language-forms.md from the dispatch tables
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
    _ = @import("eval/instance.zig");
    _ = @import("eval/builders.zig");
    _ = @import("eval/forms.zig");
    _ = @import("eval/builtins.zig");
    _ = @import("eval/fmt.zig");
    _ = @import("docgen.zig");
    _ = @import("query.zig");
    _ = @import("eval/evaluator.zig");
    _ = @import("eval/ids.zig");
    _ = @import("eval/pin_enrichment.zig");
    _ = @import("eval/rails.zig");
    _ = @import("eval/test_point.zig");
    _ = @import("eval/electrical.zig");
    _ = @import("diagram/diagram.zig");
    _ = @import("render_html.zig");
    _ = @import("layout_status.zig");
    _ = @import("eval/power_budget.zig");
    _ = @import("eval/power_sequencing.zig");
    _ = @import("erc.zig");
    _ = @import("review_md.zig");
    _ = @import("id_insert.zig");
    _ = @import("emit.zig");
    _ = @import("convert/footprint.zig");
    _ = @import("convert/symbol.zig");
    _ = @import("import_kicad.zig");
    _ = @import("import_fold.zig");
    _ = @import("import_fold_emit.zig");
    _ = @import("convert/alt_functions.zig");
    _ = @import("export_kicad.zig");
    _ = @import("export_kicad_footprint.zig");
    _ = @import("serve.zig");
    _ = @import("serve/modules.zig");
    _ = @import("serve/auth_store.zig");
    _ = @import("serve/ward_auth.zig");
    _ = @import("serve/sync.zig");
    _ = @import("serve/board_backup.zig");
    _ = @import("serve/component_search.zig");
    _ = @import("serve/digikey.zig");
    _ = @import("serve/rate_limiter.zig");
    _ = @import("serve/subprocess.zig");
    _ = @import("serve/datasheet.zig");
    _ = @import("serve/library.zig");
    _ = @import("serve/library_3d.zig");
    _ = @import("config.zig");
    _ = @import("kicad_pcb/writer.zig");
    _ = @import("kicad_pcb/reader.zig");
    _ = @import("render_json.zig");
    _ = @import("json_writer.zig");
    _ = @import("checks.zig");
    _ = @import("escape.zig");
    _ = @import("numeric.zig");
    _ = @import("paths.zig");
    _ = @import("placement/geometry.zig");
    _ = @import("placement/pin_roles.zig");
    _ = @import("placement/pad_shape.zig");
    _ = @import("placement/outline.zig");
    _ = @import("placement/pour.zig");
    _ = @import("placement/optimizer.zig");
    _ = @import("placement/router.zig");
    _ = @import("placement/drc.zig");
    _ = @import("placement/module_policy.zig");
    _ = @import("placement/layout_lint.zig");
    _ = @import("serve/pcb_layout_page.zig");
    _ = @import("serve/pcb_describe.zig");
    _ = @import("serve/drc_json.zig");
    _ = @import("serve/drc_rules.zig");
    _ = @import("serve/diag_format.zig");
    _ = @import("serve/edit_assist.zig");
    _ = @import("serve/upload.zig");
    _ = @import("serve/component_info.zig");
    _ = @import("serve/design_diff.zig");
    _ = @import("serve/datasheet_attach.zig");
    _ = @import("serve/page_cache.zig");
    _ = @import("deflate.zig");
    _ = @import("png.zig");
    _ = @import("font5x7.zig");
    _ = @import("raster.zig");
    _ = @import("render_pcb_png.zig");
    _ = @import("export_fab.zig");
    _ = @import("export_gerber.zig");
    _ = @import("fab_readiness.zig");
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
}
