//! CLI subcommand implementations dispatched from `main.zig`: `check` (runs ERC,
//! non-zero exit on any error-severity violation), `build` (+`--push`),
//! `export-kicad`, `import-kicad`, and the convert commands. These own the
//! program's visible stdout output — the point of running `netlisp <cmd>` —
//! distinct from diagnostics, which go through `infra/log.zig`.

const std = @import("std");
const exit = @import("exit.zig");
const infra_fs = @import("infra/fs.zig");
const paths = @import("paths.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const EvalError = @import("eval/evaluator.zig").EvalError;
const emit = @import("emit.zig");
const export_kicad = @import("export_kicad.zig");
const export_kicad_sch = @import("export_kicad_sch.zig");
const kicad_sch_push = @import("kicad_sch_push.zig");
const bom = @import("bom.zig");
const id_insert = @import("id_insert.zig");
const erc_mod = @import("erc.zig");
const env_mod = @import("eval/env.zig");
const eval_modules = @import("eval/modules.zig");
const import_kicad = @import("import_kicad.zig");
const kicad_inspect = @import("kicad_pcb/inspect.zig");
const kicad_route_command = @import("kicad_pcb/route_command.zig");
const kicad_import_layout_command = @import("kicad_pcb/import_layout_command.zig");
const layout_backfill_command = @import("serve/layout_backfill_command.zig");
const layout_merge_command = @import("serve/layout_merge_command.zig");
const json_writer = @import("json_writer.zig");
const preflight = @import("preflight.zig");
const build_id = @import("build_id.zig");
const export_pdf = @import("export_pdf.zig");
const render_schematic_png = @import("render_schematic_png.zig");
const pdf_mod = @import("pdf.zig");
const review_mod = @import("review.zig");
const req_checks = @import("req_checks.zig");
const notes = @import("serve/notes.zig");
const thermal_api = @import("serve/thermal_api.zig");

const InspectCommandError = std.mem.Allocator.Error || std.Io.Writer.Error;

// ── Constants ─────────────────────────────────────────────────────
const project_dir_flag = "--project-dir";
const output_dir_flag = "--output-dir";
const out_of_memory_msg = "Out of memory\n";
const build_error_fmt = "Build error: {}\n";
const diag_error_fmt = "{s}:{d}:{d}: error: {s}\n";
const build_failed_assertion_msg = "Build failed: assertion violations\n";
const cannot_write_fmt = "Cannot write {s}: {}\n";
const pass_fmt = "PASS: {s}\n";
const warn_fmt = "WARN: {s}\n";
const fail_fmt = "FAIL: {s}\n";
const identity_resolution_error_fmt = "Identity resolution error: {}\n";
const wrote_bytes_fmt = "Wrote {s} ({d} bytes)\n";
const check_usage =
    "Usage: netlisp check [--project-dir <d>] [--severity error|warning|info] " ++
    "[--profile authoring|preflight] <design-name>\n";
const export_pdf_usage =
    "Usage: netlisp export-pdf [--project-dir <d>] <design-name> " ++
    "[--output <file.pdf>] [--theme light|dark]\n";
const export_schematic_png_usage =
    "Usage: netlisp export-schematic-png [--project-dir <d>] <design-name> " ++
    "[--sub <slug>|--ref <hub>] [--view sequential|functional] " ++
    "[--theme light|dark] [--width <px>] [--output <file.png>]\n";
const export_sch_usage =
    "Usage: netlisp export-kicad-sch [--project-dir <d>] <design-name> " ++
    "[--output <root.kicad_sch>] [--output-dir <dir>] [--flat] [--no-vendor-symbols]\n" ++
    "Child sheets are written beside the root under the names it links to, along\n" ++
    "with the project sidecars (sym-lib-table, fp-lib-table, <design>.kicad_pro,\n" ++
    "netlisp.kicad_sym); an existing sidecar is kept, never overwritten.\n";
const sync_sch_usage =
    "Usage: netlisp sync-kicad-sch [--project-dir <d>] <design-name> [--dry-run] [--force]\n" ++
    "Writes the schematic INTO the KiCad project directory the design's\n" ++
    "(kicad-pcb \"<path>\") names, under that project's own name. An existing sheet\n" ++
    "is replaced only when it is a previous netlisp push or an empty eeschema stub;\n" ++
    "anything else refuses the whole push unless --force. A KiCad lock on the\n" ++
    "project refuses even with --force. Replaced files roll into backups/.\n";
const export_kicad_usage =
    "Usage: netlisp export-kicad --project-dir <d> --output-dir <out> [--with-schematic] <design-name>\n" ++
    "--with-schematic also writes the .kicad_sch hierarchy + project sidecars, so\n" ++
    "the output directory opens in KiCad as a complete project.\n";

/// Error set for the CLI command handlers in this file. Wide on purpose:
/// each `cmd*` orchestrates the evaluator (`EvalError`), file IO, network
/// pushes, and writers, so we union the relevant std error sets up front
/// rather than computing a per-command set.
pub const CommandError = std.mem.Allocator.Error ||
    EvalError ||
    infra_fs.File.OpenError ||
    infra_fs.File.ReadError ||
    infra_fs.File.WriteError ||
    infra_fs.Dir.MakeError ||
    infra_fs.Dir.RenameError ||
    error{
        FileTooBig,
        StreamTooLong,
        EndOfStream,
        InvalidName,
        InvalidArgument,
        WriteFailed,
        Canceled,
        BrokenPipe,
        NotOpenForWriting,
        ConnectionRefused,
        ConnectionResetByPeer,
        ConnectionTimedOut,
        NetworkUnreachable,
        AddressFamilyNotSupported,
        ProtocolFamilyNotAvailable,
        AddressNotAvailable,
        SocketTypeNotSupported,
        ProtocolNotSupported,
        SystemResources,
        Unexpected,
        TemporaryNameServerFailure,
        NameServerFailure,
        UnknownHostName,
        HostLacksNetworkAddresses,
        ServiceUnavailable,
    };

/// Fallback for the `build`/`check`/`export-kicad` commands when `name`
/// resolves to a `lib/modules/<name>.sexp` module rather than a top-level
/// `src/<name>.sexp` design: instantiate the module standalone via its
/// parameter defaults (zero args, defaults-first) and return its design
/// block. `eval` must already have run the module file (so the defmodule is
/// registered). Prints a diagnostic and exits non-zero if the name isn't a
/// resolvable module or needs required args it has no defaults for. Lets a
/// bare module name (e.g. `adp7118-ldo`) build the same as a design name.
fn moduleBlock(eval: *Evaluator, name: []const u8) *env_mod.DesignBlock {
    const result = eval_modules.instantiateStandalone(eval, name) catch |err| {
        if (eval.last_error) |diag| {
            std.debug.print(diag_error_fmt, .{ name, diag.span.line, diag.span.col, diag.message });
        }
        exit.fatal("error: {s} is neither a design nor a buildable module ({s})\n", .{ name, @errorName(err) });
    };
    return switch (result) {
        .design_block => |b| b,
        else => {
            exit.fatal("error: {s} did not evaluate to a design\n", .{name});
        },
    };
}

const CheckArgs = struct {
    project_dir: []const u8 = ".",
    design: []const u8,
    severity: ?[]const u8 = null,
    profile: preflight.Profile = .authoring,
};

fn parseCheckArgs(args: []const []const u8) CheckArgs {
    var parsed: CheckArgs = .{ .design = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            parsed.project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--severity") and i + 1 < args.len) {
            parsed.severity = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--profile") and i + 1 < args.len) {
            parsed.profile = preflight.parseProfile(args[i + 1]) orelse {
                exit.fatal(
                    "Invalid check profile '{s}' (expected authoring or preflight)\n",
                    .{args[i + 1]},
                );
            };
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            parsed.design = args[i];
        }
    }
    if (parsed.design.len == 0) exit.fatal(check_usage, .{});
    return parsed;
}

fn evalCheckBlock(eval: *Evaluator, board_path: []const u8, design: []const u8) *env_mod.DesignBlock {
    const result = eval.evalFile(board_path) catch |err| {
        if (eval.last_error) |diag| {
            std.debug.print(diag_error_fmt, .{ board_path, diag.span.line, diag.span.col, diag.message });
        }
        exit.fatal("Evaluate error: {}\n", .{err});
    };
    return switch (result) {
        .design_block => |block| block,
        else => moduleBlock(eval, design),
    };
}

const CheckCounts = struct {
    shown: usize = 0,
    errors: usize = 0,

    fn record(self: *CheckCounts, is_error: bool, visible: bool) void {
        if (is_error) self.errors += 1;
        if (visible) self.shown += 1;
    }

    fn include(self: *CheckCounts, other: CheckCounts) void {
        self.shown += other.shown;
        self.errors += other.errors;
    }
};

fn severityMatches(actual: []const u8, filter: ?[]const u8) bool {
    const expected = filter orelse return true;
    return std.mem.eql(u8, actual, expected);
}

fn writeCheckErc(w: anytype, violations: []const erc_mod.Violation, filter: ?[]const u8) !CheckCounts {
    var counts: CheckCounts = .{};
    for (violations) |violation| {
        const severity = @tagName(violation.severity);
        const visible = severityMatches(severity, filter);
        counts.record(violation.severity == .@"error", visible);
        if (!visible) continue;
        try w.print("{s:<9} {s:<26} ", .{ severity, @tagName(violation.kind) });
        if (violation.ref_des.len > 0) try w.print("{s} ", .{violation.ref_des});
        if (violation.net.len > 0) try w.print("[{s}] ", .{violation.net});
        try w.print("— {s}\n", .{violation.message});
    }
    return counts;
}

fn writeCheckAssertions(w: anytype, eval: *const Evaluator, filter: ?[]const u8) !CheckCounts {
    var counts: CheckCounts = .{};
    for (eval.assertions.items) |assertion| {
        if (assertion.passed) continue;
        const severity: []const u8 = if (assertion.is_warning) "warning" else "error";
        const visible = severityMatches(severity, filter);
        counts.record(!assertion.is_warning, visible);
        if (!visible) continue;
        try w.print("{s:<9} {s:<26} — {s}\n", .{ severity, "assertion", assertion.message });
    }
    return counts;
}

fn writeCheckFindings(
    w: anytype,
    findings: []const preflight.Finding,
    filter: ?[]const u8,
) !CheckCounts {
    var counts: CheckCounts = .{};
    for (findings) |finding| {
        const severity = @tagName(finding.severity);
        const hidden_info = filter == null and finding.severity == .info;
        const visible = !hidden_info and severityMatches(severity, filter);
        counts.record(finding.severity == .@"error", visible);
        if (!visible) continue;
        try w.print("{s:<9} {s:<26} {s} ", .{ severity, @tagName(finding.kind), finding.ref_des });
        if (finding.requirement.id.len > 0) try w.print("[{s}] ", .{finding.requirement.id});
        try w.print("— {s}", .{finding.message});
        if (finding.requirement.text.len > 0) try w.print(" ({s})", .{finding.requirement.text});
        try w.writeAll("\n");
    }
    return counts;
}

/// `netlisp check <name>` — run unified validation and print findings.
pub fn cmdCheck(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    const parsed = parseCheckArgs(args);

    const board_path = try paths.designSourcePath(allocator, parsed.project_dir, parsed.design);
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, parsed.project_dir);
    defer eval.deinit();
    const block = evalCheckBlock(&eval, board_path, parsed.design);

    // ERC/preflight diagnostics must name the same parts as `build`, the
    // introspection commands, and the PCB. Loading the prior BOM is read-only;
    // it restores allocator-owned ref-des by stable ID before checks run.
    const bom_path = try paths.designSiblingPath(allocator, parsed.project_dir, parsed.design, ".bom");
    defer allocator.free(bom_path);
    bom.applyExisting(allocator, block, bom_path, parsed.project_dir) catch |err| {
        std.debug.print("warning: existing BOM identity merge skipped: {s}\n", .{@errorName(err)});
    };

    const violations = try erc_mod.runErc(allocator, block, parsed.project_dir);
    var w_buf: std.Io.Writer.Allocating = .init(allocator);
    defer w_buf.deinit();
    const w = &w_buf.writer;
    var counts = try writeCheckErc(w, violations, parsed.severity);
    counts.include(try writeCheckAssertions(w, &eval, parsed.severity));
    const report = try preflight.run(allocator, &eval, block, parsed.project_dir, parsed.profile);
    defer report.deinit(allocator);
    counts.include(try writeCheckFindings(w, report.findings, parsed.severity));
    try w.print("\n{d} violation(s)\n", .{counts.shown});
    try std.Io.File.stdout().writeStreamingAll(infra_fs.currentIo(), w_buf.written());

    if (counts.errors > 0) exit.failure();
}

/// Parsed argument vector for `netlisp build`. Kept as a pure struct so the
/// (process-exiting) `cmdBuild` handler can delegate its parsing to a testable
/// helper. `design` is the resolved design name (positional, or the value that
/// followed a `--push <name>`); `want_push` records whether `--push` was passed
/// at all (a bare positional name does *not* imply a push).
const BuildArgs = struct {
    project_dir: []const u8 = ".",
    output_dir: ?[]const u8 = null,
    server_url: []const u8 = "http://localhost:7050",
    design: ?[]const u8 = null,
    want_push: bool = false,
};

/// Parse `netlisp build` arguments. `--push` may be a bare flag (push the
/// positional design) or take an explicit `--push <name>`; either way it is the
/// *only* thing that requests a network push — a lone positional design name is
/// built to stdout / `--output-dir` without touching a server.
fn parseBuildArgs(args: []const []const u8) BuildArgs {
    var out: BuildArgs = .{};
    var positional_name: ?[]const u8 = null;
    var push_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            out.project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--push")) {
            out.want_push = true;
            // `--push <name>` gives the design explicitly; a bare `--push`
            // pushes whatever positional name is supplied.
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                push_name = args[i + 1];
                i += 1;
            }
        } else if (std.mem.eql(u8, args[i], output_dir_flag) and i + 1 < args.len) {
            out.output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--server") and i + 1 < args.len) {
            out.server_url = args[i + 1];
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            positional_name = args[i];
        }
    }
    out.design = push_name orelse positional_name;
    return out;
}

/// CLI entry point for `netlisp build`. Evaluates `<design>.sexp`, runs assertions,
/// resolves identities into the `.bom`, and either prints the resolved design
/// to stdout, writes it to `--output-dir`, or (only with `--push`) pushes it to a
/// running server so the browser viewer updates live.
/// `netlisp build [--project-dir <d>] [--output-dir <out>] [--push] <design>` —
/// evaluate a design, persist any newly generated `(id …)`/`(ids …)` tokens
/// back into source, and optionally push the rebuilt scene to a running server.
pub fn cmdBuild(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    const parsed = parseBuildArgs(args);
    const project_dir = parsed.project_dir;
    const output_dir = parsed.output_dir;
    const server_url = parsed.server_url;
    const want_push = parsed.want_push;

    const design = parsed.design orelse {
        exit.fatal("Usage: netlisp build [--project-dir <d>] [--output-dir <out>] [--push] <design-name>\n", .{});
    };

    const board_path = paths.designSourcePath(allocator, project_dir, design) catch {
        exit.fatal(out_of_memory_msg, .{});
    };
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch |err| {
        // Render the stashed diagnostic (span + message + module call
        // chain) when one exists — the bare error code is the fallback.
        if (eval.last_error) |diag| {
            std.debug.print(diag_error_fmt, .{ board_path, diag.span.line, diag.span.col, diag.message });
        }
        exit.fatal(build_error_fmt, .{err});
    };

    // Resolve the design block. A top-level `(design-block …)` is used as-is;
    // a `lib/modules/<name>.sexp` file (where `evalFile` returned .nil after
    // running the `(defmodule …)`) is instantiated standalone via its
    // parameter defaults. `instantiateStandalone` runs `callModule`, which
    // records this module's assertions and pending ids into `eval`, so the
    // id-insertion / refdes-sidecar / warning / assertion handling below sees
    // them just as it would for a design.
    const block = switch (result) {
        .design_block => |b| b,
        else => moduleBlock(&eval, design),
    };

    // The shared persist wrapper, not a re-inlined copy of it: one place decides
    // when a minted id is written back and how a failure degrades, so the CLI
    // and every server write path cannot drift apart on the identity contract.
    _ = id_insert.persistMintedIds(allocator, board_path, &eval);

    // Lint warnings (unknown sub-forms / enum words the evaluator skipped).
    // Spans from module files point into those files but are reported
    // against the board path — the message names the offending form either way.
    for (eval.warnings.items) |w| {
        std.debug.print("{s}:{d}:{d}: warning: {s}\n", .{ board_path, w.span.line, w.span.col, w.message });
    }

    var has_failure = false;
    for (eval.assertions.items) |assertion| {
        if (assertion.passed) {
            std.debug.print(pass_fmt, .{assertion.message});
        } else if (assertion.is_warning) {
            std.debug.print(warn_fmt, .{assertion.message});
        } else {
            std.debug.print(fail_fmt, .{assertion.message});
            has_failure = true;
        }
    }

    if (has_failure) {
        exit.fatal(build_failed_assertion_msg, .{});
    }

    {
        {
            const ids_path = paths.designSiblingPath(allocator, project_dir, design, ".bom") catch {
                exit.fatal(out_of_memory_msg, .{});
            };
            defer allocator.free(ids_path);
            bom.resolveIdentities(allocator, block, ids_path, project_dir) catch |err| {
                exit.fatal(identity_resolution_error_fmt, .{err});
            };

            const output = emit.emitResolved(allocator, block) catch {
                exit.fatal("Emit error\n", .{});
            };
            defer allocator.free(output);

            if (output_dir) |dir| {
                const out_path = std.fmt.allocPrint(allocator, "{s}/{s}.sexp", .{ dir, design }) catch {
                    exit.fatal(out_of_memory_msg, .{});
                };
                defer allocator.free(out_path);
                const f = infra_fs.cwd().createFile(out_path, .{}) catch {
                    exit.fatal("Failed to write {s}\n", .{out_path});
                };
                defer f.close();
                f.writeAll(output) catch {
                    exit.fatal("Write error\n", .{});
                };
                std.debug.print("Wrote {s}\n", .{out_path});
            }

            // A push is requested only by `--push`; a bare positional design
            // name builds without touching a server. A failed push after a
            // successful `--output-dir` write is reported but does not
            // discard the file that was already written — the write is the
            // durable artifact, the push is a live-view convenience.
            if (want_push) {
                const url = std.fmt.allocPrint(allocator, "{s}/api/push/{s}", .{ server_url, design }) catch {
                    exit.fatal(out_of_memory_msg, .{});
                };
                defer allocator.free(url);
                pushToServer(allocator, url, output) catch {
                    std.debug.print("Push failed\n", .{});
                    // If we already wrote the file, the run's primary artifact
                    // succeeded; still signal the push failure via exit code
                    // but only exit here when there was no other output path.
                    if (output_dir == null) exit.failure();
                };
                std.debug.print("Pushed to {s}\n", .{url});
            }

            if (!want_push and output_dir == null) {
                const file = std.Io.File.stdout();
                try file.writeStreamingAll(infra_fs.currentIo(), output);
                try file.writeStreamingAll(infra_fs.currentIo(), "\n");
            }
        }
    }
}

/// CLI entry point for `netlisp export-kicad`. Builds the design, resolves the
/// BOM, and writes a KiCad-compatible netlist plus per-footprint
/// `.kicad_mod` files (and any associated STEP models) into `--output-dir`.
pub fn cmdExportKicad(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    var project_dir: []const u8 = ".";
    var output_dir: ?[]const u8 = null;
    var design_name: ?[]const u8 = null;
    var bundle: export_kicad.BundleOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], output_dir_flag) and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--with-schematic")) {
            bundle.schematic = true;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            design_name = args[i];
        }
    }

    const name = design_name orelse {
        exit.fatal(export_kicad_usage, .{});
    };
    const out = output_dir orelse {
        exit.fatal(export_kicad_usage, .{});
    };

    const board_path = paths.designSourcePath(allocator, project_dir, name) catch {
        exit.fatal(out_of_memory_msg, .{});
    };
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch |err| {
        // Render the stashed diagnostic (span + message + module call
        // chain) when one exists — the bare error code is the fallback.
        if (eval.last_error) |diag| {
            std.debug.print(diag_error_fmt, .{ board_path, diag.span.line, diag.span.col, diag.message });
        }
        exit.fatal(build_error_fmt, .{err});
    };

    // A top-level design is used as-is; a bare `lib/modules/<name>.sexp`
    // module (where `evalFile` returned .nil) is instantiated standalone via
    // its parameter defaults. Resolved before the assertion sweep so a
    // module's design math (recorded during `callModule`) surfaces here.
    const block = switch (result) {
        .design_block => |b| b,
        else => moduleBlock(&eval, name),
    };
    // Pin the minted ids before the netlist below stamps `uuidFromId(id)` into
    // every component's `tstamp`. `resolveIdentities` writes the `.bom` with
    // the id it used, so an unpinned id makes that sidecar name a token no
    // source carries — and the next export lands a different uuid on the same
    // part. See `persistIdsForExport`.
    persistIdsForExport(allocator, board_path, &eval);

    var has_failure = false;
    for (eval.assertions.items) |assertion| {
        if (assertion.passed) {
            std.debug.print(pass_fmt, .{assertion.message});
        } else if (assertion.is_warning) {
            std.debug.print(warn_fmt, .{assertion.message});
        } else {
            std.debug.print(fail_fmt, .{assertion.message});
            has_failure = true;
        }
    }

    if (has_failure) {
        exit.fatal(build_failed_assertion_msg, .{});
    }

    {
        {
            const ids_path = paths.designSiblingPath(allocator, project_dir, name, ".bom") catch {
                exit.fatal(out_of_memory_msg, .{});
            };
            defer allocator.free(ids_path);
            bom.resolveIdentities(allocator, block, ids_path, project_dir) catch |err| {
                exit.fatal(identity_resolution_error_fmt, .{err});
            };

            export_kicad.exportKicad(allocator, block, project_dir, out, name, bundle) catch |err| {
                exit.fatal("Export error: {}\n", .{err});
            };
            std.debug.print("KiCad export complete: {s}/\n", .{out});
        }
    }
}

/// Parsed `export-kicad-sch` invocation. The export is multi-file, so the
/// output selector names the ROOT sheet; children are written beside it under
/// the names the root's `Sheetfile` properties point at.
const ExportSchArgs = struct {
    project_dir: []const u8 = ".",
    design: []const u8 = "",
    output: ?[]const u8 = null,
    output_dir: ?[]const u8 = null,
    flat: bool = false,
    /// Draw parts from their original `lib/sources/*.kicad_sym` when one
    /// exists. `--no-vendor-symbols` forces the synthesised box everywhere.
    vendor: bool = true,
};

fn parseExportSchArgs(args: []const []const u8) ExportSchArgs {
    var parsed: ExportSchArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            parsed.project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            parsed.output = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output-dir") and i + 1 < args.len) {
            parsed.output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--flat")) {
            parsed.flat = true;
        } else if (std.mem.eql(u8, args[i], "--no-vendor-symbols")) {
            parsed.vendor = false;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            parsed.design = args[i];
        }
    }
    return parsed;
}

/// Path of the root sheet, from `--output` (verbatim), `--output-dir`
/// (`<dir>/<design>.kicad_sch`), or the design name in the working directory.
fn rootSchPath(allocator: std.mem.Allocator, parsed: ExportSchArgs) []const u8 {
    if (parsed.output) |o| return o;
    const dir = parsed.output_dir orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/{s}.kicad_sch", .{ dir, parsed.design }) catch {
        exit.fatal(out_of_memory_msg, .{});
    };
}

/// Write the root at `root_path` and every child beside it. Sibling names come
/// from the exporter, so they match the `Sheetfile` links exactly. The project
/// sidecars land in the same directory, but are only written when absent: an
/// export aimed at a live KiCad project directory must never overwrite the
/// `.kicad_pro` (board settings, net classes) or a hand-edited library table.
fn writeSchFiles(
    allocator: std.mem.Allocator,
    out: export_kicad_sch.Output,
    root_path: []const u8,
) void {
    const dir = std.fs.path.dirname(root_path) orelse ".";
    if (dir.len > 0) {
        infra_fs.cwd().makePath(dir) catch |err| exit.fatal(cannot_write_fmt, .{ dir, err });
    }
    for (out.files, 0..) |f, i| {
        const path = if (i == 0) root_path else joinDir(allocator, dir, f.name);
        infra_fs.cwd().writeFile(.{ .sub_path = path, .data = f.bytes }) catch |err| {
            exit.fatal(cannot_write_fmt, .{ path, err });
        };
        std.debug.print(wrote_bytes_fmt, .{ path, f.bytes.len });
    }
    for (out.sidecars) |f| {
        const path = joinDir(allocator, dir, f.name);
        if (infra_fs.cwd().access(path, .{})) |_| {
            std.debug.print("  Kept existing {s}\n", .{path});
            continue;
        } else |_| {}
        infra_fs.cwd().writeFile(.{ .sub_path = path, .data = f.bytes }) catch |err| {
            exit.fatal(cannot_write_fmt, .{ path, err });
        };
        std.debug.print(wrote_bytes_fmt, .{ path, f.bytes.len });
    }
}

fn joinDir(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) []const u8 {
    return std.fs.path.join(allocator, &.{ dir, name }) catch {
        exit.fatal(out_of_memory_msg, .{});
    };
}

/// CLI entry point for `netlisp export-kicad-sch`. Evaluates the design (or a
/// bare `lib/modules/<name>.sexp` module, like the other export commands),
/// resolves BOM identities so each symbol carries the same UUID the netlist and
/// board use, and writes a `.kicad_sch` hierarchy — a root sheet plus one child
/// per section / module — beside the chosen root path. The exporter re-parses
/// and checks every file's bytes, so nothing structurally broken reaches disk.
pub fn cmdExportKicadSch(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    const parsed = parseExportSchArgs(args);
    if (parsed.design.len == 0) exit.fatal(export_sch_usage, .{});

    var eval = Evaluator.init(allocator, parsed.project_dir);
    defer eval.deinit();
    const block = evalForExport(allocator, &eval, parsed.project_dir, parsed.design);

    if (paths.designSiblingPath(allocator, parsed.project_dir, parsed.design, ".bom")) |bom_path| {
        defer allocator.free(bom_path);
        // A missing `.bom` is normal (a standalone module never has one); the
        // symbols then carry ids derived from the design's stable 8-char ids.
        bom.resolveIdentities(allocator, block, bom_path, parsed.project_dir) catch |err| {
            std.debug.print("warning: BOM identity merge skipped: {s}\n", .{@errorName(err)});
        };
    } else |err| {
        std.debug.print("warning: no .bom sidecar path for {s}: {s}\n", .{ parsed.design, @errorName(err) });
    }

    const out = export_kicad_sch.exportSch(
        allocator,
        block,
        parsed.project_dir,
        parsed.design,
        .{ .flat = parsed.flat, .vendor = parsed.vendor },
    ) catch |err| {
        exit.fatal("Schematic export failed: {s}\n", .{@errorName(err)});
    };
    defer out.deinit(allocator);
    writeSchFiles(allocator, out, rootSchPath(allocator, parsed));
}

/// Parsed `sync-kicad-sch` invocation. There is no output selector: the whole
/// point is that the destination is the design's own KiCad project directory,
/// read from its `(kicad-pcb "<path>")` form.
const SyncSchArgs = struct {
    project_dir: []const u8 = ".",
    design: []const u8 = "",
    /// Print the per-file plan and write nothing.
    dry_run: bool = false,
    /// Replace a sheet that is neither netlisp's nor an empty stub. Never
    /// overrides a KiCad lock on the project.
    force: bool = false,
};

fn parseSyncSchArgs(args: []const []const u8) SyncSchArgs {
    var parsed: SyncSchArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            parsed.project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--dry-run")) {
            parsed.dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--force")) {
            parsed.force = true;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            parsed.design = args[i];
        }
    }
    return parsed;
}

/// CLI entry point for `netlisp sync-kicad-sch`. Exports the design's schematic
/// under its KiCad PROJECT's name (`Cyclops Digital.kicad_sch`, not
/// `stm32n6.kicad_sch`) and writes it into the directory holding the board the
/// design declares, so the KiCad project carries both halves.
///
/// It refuses rather than overwrites: an existing sheet is replaced only when
/// it is a previous netlisp push or an empty eeschema stub, a KiCad lock on the
/// project blocks the whole push (`--force` does NOT override that one), and
/// nothing is written at all if any one file would be refused. `--dry-run`
/// prints the same plan without touching disk.
pub fn cmdSyncKicadSch(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    const parsed = parseSyncSchArgs(args);
    if (parsed.design.len == 0) exit.fatal(sync_sch_usage, .{});

    var eval = Evaluator.init(allocator, parsed.project_dir);
    defer eval.deinit();
    const block = evalForExport(allocator, &eval, parsed.project_dir, parsed.design);

    if (paths.designSiblingPath(allocator, parsed.project_dir, parsed.design, ".bom")) |bom_path| {
        defer allocator.free(bom_path);
        bom.resolveIdentities(allocator, block, bom_path, parsed.project_dir) catch |err| {
            std.debug.print("warning: BOM identity merge skipped: {s}\n", .{@errorName(err)});
        };
    } else |err| {
        std.debug.print("warning: no .bom sidecar path for {s}: {s}\n", .{ parsed.design, @errorName(err) });
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const result = kicad_sch_push.run(allocator, arena_state.allocator(), block, parsed.project_dir, .{
        .dry_run = parsed.dry_run,
        .force = parsed.force,
    }) catch |err| exit.fatal("Schematic push failed: {s}\n", .{syncSchReason(err)});

    printSyncSchPlan(result, parsed.dry_run);
    if (result.plan.refusal) |why| exit.fatal("Refused: {s}\n", .{why});
}

/// One sentence per failure mode, so the CLI names the rule rather than an
/// error tag. Shared shape with the HTTP/CLI surfaces' own explanations.
fn syncSchReason(err: kicad_sch_push.PushError) []const u8 {
    return switch (err) {
        error.PcbPathUnset => "this design declares no (kicad-pcb \"<path>\") form, " ++
            "so there is no KiCad project directory to push the schematic into",
        error.PcbPathNotInDirectory => "the design's (kicad-pcb \"<path>\") is a bare filename " ++
            "with no directory, so there is nowhere to write the schematic",
        error.PushWriteFailed => "writing into the KiCad project directory failed",
        else => "the schematic export failed its own self-check",
    };
}

/// Print the plan as one line per file, then what was (or was not) done.
fn printSyncSchPlan(result: kicad_sch_push.Result, dry_run: bool) void {
    const plan = result.plan;
    std.debug.print("KiCad project: {s}\n  directory: {s}\n  root sheet: {s}\n", .{
        plan.target.project, plan.target.dir, plan.root,
    });
    for (plan.ops) |op| {
        std.debug.print("  {s: <10} {s}", .{ op.action.label(), op.name });
        if (op.bytes > 0) std.debug.print(" ({d} bytes)", .{op.bytes});
        if (op.note.len > 0) std.debug.print(" — {s}", .{op.note});
        std.debug.print("\n", .{});
    }
    if (plan.refusal != null) return;
    if (dry_run) {
        std.debug.print("Dry run — nothing written.\n", .{});
        return;
    }
    std.debug.print("Wrote {d} file(s) into {s} (replaced files rolled into backups/).\n", .{
        plan.count(.create) + plan.count(.overwrite),
        plan.target.dir,
    });
}

/// Parsed `export-pdf` invocation.
const ExportPdfArgs = struct {
    project_dir: []const u8 = ".",
    design: []const u8 = "",
    output: ?[]const u8 = null,
    /// `light` resolves the print palette (white page); `dark` keeps the web look.
    theme: export_pdf.Options = .{},
};

fn parseExportPdfArgs(args: []const []const u8) ExportPdfArgs {
    var parsed: ExportPdfArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            parsed.project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            parsed.output = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--theme") and i + 1 < args.len) {
            if (std.mem.eql(u8, args[i + 1], "light")) parsed.theme.theme = .print;
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            parsed.design = args[i];
        }
    }
    return parsed;
}

/// CLI entry point for `netlisp export-pdf`. Evaluates the design (or a bare
/// `lib/modules/<name>.sexp` module, via the same standalone instantiation
/// `build`/`check`/`export-kicad` use), builds the review document, and writes
/// the composed PDF. Read-only with respect to the project: the only file it
/// touches is the output.
pub fn cmdExportPdf(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    const parsed = parseExportPdfArgs(args);
    if (parsed.design.len == 0) exit.fatal(export_pdf_usage, .{});

    var eval = Evaluator.init(allocator, parsed.project_dir);
    defer eval.deinit();
    const block = evalForExport(allocator, &eval, parsed.project_dir, parsed.design);

    const doc = buildReviewFor(allocator, &eval, parsed.project_dir, parsed.design, block);
    var opts = parsed.theme;
    opts.build_id = build_id.current();
    opts.generated_at = doc.generated_at;
    opts.open_notes = countOpenNotes(allocator, parsed.project_dir, parsed.design);

    const bytes = export_pdf.compose(allocator, block, parsed.project_dir, parsed.design, doc, opts) catch |err| {
        exit.fatal("PDF compose error: {s}\n", .{@errorName(err)});
    };

    // The writer's own structural self-check (xref offsets, stream lengths,
    // q/Q + BT/ET balance). Cheap on bytes we just produced, and it means a
    // structurally broken file can never reach disk.
    pdf_mod.validate(bytes) catch |err| {
        exit.fatal("PDF self-check failed: {s}\n", .{@errorName(err)});
    };

    const out_path = parsed.output orelse std.fmt.allocPrint(allocator, "{s}.pdf", .{parsed.design}) catch {
        exit.fatal(out_of_memory_msg, .{});
    };
    infra_fs.cwd().writeFile(.{ .sub_path = out_path, .data = bytes }) catch |err| {
        exit.fatal(cannot_write_fmt, .{ out_path, err });
    };
    std.debug.print("Wrote {s} ({d} bytes, {d} pages)\n", .{
        out_path, bytes.len, export_pdf.pageCount(bytes),
    });
}

const ExportSchematicPngArgs = struct {
    project_dir: []const u8 = ".",
    design: []const u8 = "",
    output: ?[]const u8 = null,
    opts: render_schematic_png.Options = .{},
};

fn parseExportSchematicPngArgs(args: []const []const u8) ExportSchematicPngArgs {
    var parsed: ExportSchematicPngArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            parsed.project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            parsed.output = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--sub") and i + 1 < args.len) {
            parsed.opts.sub = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--ref") and i + 1 < args.len) {
            parsed.opts.ref = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--view") and i + 1 < args.len) {
            parsed.opts.view = render_schematic_png.parseView(args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--theme") and i + 1 < args.len) {
            parsed.opts.theme = render_schematic_png.parseTheme(args[i + 1]);
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--width") and i + 1 < args.len) {
            parsed.opts.width = std.fmt.parseInt(u32, args[i + 1], 10) catch 1600;
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            parsed.design = args[i];
        }
    }
    parsed.opts.width = std.math.clamp(parsed.opts.width, 320, 4000);
    return parsed;
}

/// Native, deterministic schematic-block image export. It evaluates the same
/// design/module and invokes the same renderer as HTTP/CLI, then writes only
/// the requested output file; Playwright/Chromium are not involved.
pub fn cmdExportSchematicPng(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    const parsed = parseExportSchematicPngArgs(args);
    if (parsed.design.len == 0 or (parsed.opts.sub != null and parsed.opts.ref != null)) {
        exit.fatal(export_schematic_png_usage, .{});
    }

    var eval = Evaluator.init(allocator, parsed.project_dir);
    defer eval.deinit();
    const block = evalForExport(allocator, &eval, parsed.project_dir, parsed.design);
    const bytes = render_schematic_png.render(allocator, block, parsed.project_dir, parsed.opts) catch |err| {
        exit.fatal("Schematic PNG render failed: {s}\n", .{@errorName(err)});
    };
    defer allocator.free(bytes);

    const view = @tagName(parsed.opts.view);
    const out_path = parsed.output orelse if (parsed.opts.sub) |sub|
        std.fmt.allocPrint(allocator, "{s}-{s}-{s}.png", .{ parsed.design, sub, view }) catch exit.fatal(out_of_memory_msg, .{})
    else if (parsed.opts.ref) |ref|
        std.fmt.allocPrint(allocator, "{s}-{s}-{s}.png", .{ parsed.design, ref, view }) catch exit.fatal(out_of_memory_msg, .{})
    else
        std.fmt.allocPrint(allocator, "{s}-{s}.png", .{ parsed.design, view }) catch exit.fatal(out_of_memory_msg, .{});
    infra_fs.cwd().writeFile(.{ .sub_path = out_path, .data = bytes }) catch |err| {
        exit.fatal(cannot_write_fmt, .{ out_path, err });
    };
    std.debug.print(wrote_bytes_fmt, .{ out_path, bytes.len });
}

// spec: Web Server - export-schematic-png parses native image focus, view, theme, width, and output options
test "parse export schematic png options" {
    const parsed = parseExportSchematicPngArgs(&.{
        "--project-dir", "demo",  "board",   "--sub", "pll",      "--view",  "sequential",
        "--theme",       "light", "--width", "1200",  "--output", "pll.png",
    });
    try std.testing.expectEqualStrings("demo", parsed.project_dir);
    try std.testing.expectEqualStrings("board", parsed.design);
    try std.testing.expectEqualStrings("pll", parsed.opts.sub.?);
    try std.testing.expectEqual(render_schematic_png.View.sequential, parsed.opts.view);
    try std.testing.expectEqual(render_schematic_png.Theme.light, parsed.opts.theme);
    try std.testing.expectEqual(@as(u32, 1200), parsed.opts.width);
    try std.testing.expectEqualStrings("pll.png", parsed.output.?);
}

/// Persist an export run's newly minted `(id …)` / `(ids …)` tokens back into
/// the design source, exactly as `cmdBuild` does.
///
/// Every one of these commands then calls `bom.resolveIdentities`, which is
/// itself a WRITE: it rewrites the `.bom` sidecar recording, per part, the
/// stable id it resolved and the `uuidFromId(id)` derived from it. `generateId`
/// is process randomness, so an id that never reaches the source makes that
/// sidecar name a token nothing carries — the next run mints a different id,
/// derives a different uuid, and the MPN/manufacturer carry-forward (keyed on
/// id) silently misses. The exporters' own doc comments promise "the same UUID
/// the netlist and board use"; pinning here is what makes that promise true
/// rather than true-only-for-already-built designs.
///
/// This is a deliberate source mutation on the user's checkout, and it is not a
/// new class of one: these commands already write the `.bom` beside the design,
/// and `netlisp build` has always written ids back. Best-effort, like the CLI
/// build — a failure is logged inside the wrapper and never fails the export.
fn persistIdsForExport(allocator: std.mem.Allocator, source_path: []const u8, eval: *const Evaluator) void {
    _ = id_insert.persistMintedIds(allocator, source_path, eval);
}

/// Evaluate `name` as a design, falling back to a standalone module
/// instantiation — the same resolution the other export commands use — and pin
/// the ids that evaluation minted back into the source (see
/// `persistIdsForExport`). Shared by export-kicad-sch, sync-kicad-sch,
/// export-pdf and export-schematic-png, so all four agree on identity.
fn evalForExport(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    project_dir: []const u8,
    name: []const u8,
) *env_mod.DesignBlock {
    const source_path = paths.designSourcePath(allocator, project_dir, name) catch {
        exit.fatal(out_of_memory_msg, .{});
    };
    defer allocator.free(source_path);
    const result = eval.evalFile(source_path) catch |err| {
        if (eval.last_error) |diag| {
            std.debug.print(diag_error_fmt, .{ source_path, diag.span.line, diag.span.col, diag.message });
        }
        exit.fatal(build_error_fmt, .{err});
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => moduleBlock(eval, name),
    };
    persistIdsForExport(allocator, source_path, eval);
    return block;
}

/// Assemble the review document the composer renders: persisted BOM identities
/// merged in, then ERC + requirement checks, exactly as the server's
/// export-review path does, so the PDF and the markdown report agree.
fn buildReviewFor(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    project_dir: []const u8,
    name: []const u8,
    block: *env_mod.DesignBlock,
) review_mod.ReviewDoc {
    if (paths.designSiblingPath(allocator, project_dir, name, ".bom")) |bom_path| {
        defer allocator.free(bom_path);
        // A missing or stale `.bom` sidecar is normal (a standalone module never
        // has one), so this is a warning, not a failure: the report just shows
        // library values instead of the persisted MPN/manufacturer edits.
        bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |err| {
            std.debug.print("warning: BOM identity merge skipped: {s}\n", .{@errorName(err)});
        };
    } else |err| {
        std.debug.print("warning: no .bom sidecar path for {s}: {s}\n", .{ name, @errorName(err) });
    }

    const violations = erc_mod.runErc(allocator, block, project_dir) catch &[_]erc_mod.Violation{};
    var results = req_checks.runChecks(allocator, eval, block) catch
        std.StringHashMapUnmanaged([]req_checks.Result).empty;
    req_checks.applyVerifications(&results, block, block.instances);
    var doc = review_mod.buildReview(allocator, name, block, eval.assertions.items, violations, &results) catch {
        exit.fatal("Review build error\n", .{});
    };
    // `buildReview` reads the block alone; the cooling-scenario ladder needs the
    // project directory and the design's saved layouts, which this command has.
    // A design with no placement gets the reason, and the report says so.
    doc.power.scenarios = thermal_api.scenariosFor(
        allocator,
        project_dir,
        name,
        doc.power.thermal,
        doc.power.thermal.ambient_c,
        // The review document describes the design's DEFAULT board, the one the
        // rest of it reports on; comparing named layouts is the thermal page's job.
        null,
    ) catch .{};
    return doc;
}

/// Open (uncompleted) tasks in the design's `<design>.notes.md` sidecar. A
/// missing or unreadable sidecar simply counts zero.
fn countOpenNotes(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) usize {
    var raw: ?[]u8 = null;
    const parsed = notes.loadNotes(allocator, project_dir, name, &raw) catch return 0;
    var open: usize = 0;
    for (parsed.tasks) |t| {
        if (t.completed == null) open += 1;
    }
    return open;
}

/// `netlisp import-kicad <board.kicad_pcb> [--project-dir <d>] [--name <n>]
/// [--title <t>] [--dry-run] [--fold-channels] [--fold-prefix <P>]` — migrate an
/// existing KiCad board into the project: family-map standard passives, generate
/// library files for the rest, and write `src/<name>.sexp` mirroring the board's
/// netlist. `--fold-channels` (optionally seeded by `--fold-prefix`) de-dups a
/// channelized board into one defmodule + per-channel sub-blocks.
pub fn cmdImportKicad(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var board_path: ?[]const u8 = null;
    var project_dir: []const u8 = ".";
    var name: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var dry_run = false;
    var fold_channels = false;
    var fold_prefix: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--name") and i + 1 < args.len) {
            name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--title") and i + 1 < args.len) {
            title = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, args[i], "--fold-channels")) {
            fold_channels = true;
        } else if (std.mem.eql(u8, args[i], "--fold-prefix") and i + 1 < args.len) {
            fold_prefix = args[i + 1];
            fold_channels = true;
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            board_path = args[i];
        }
    }

    const board = board_path orelse {
        exit.fatal("Usage: netlisp import-kicad <board.kicad_pcb> [--project-dir <d>] [--name <n>] [--title <t>] [--dry-run] [--fold-channels] [--fold-prefix <P>]\n", .{});
    };

    const base = std.fs.path.basename(board);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
    const design_name = name orelse try import_kicad.sanitizeName(arena, stem);
    const design_title = title orelse stem;

    const summary = import_kicad.importBoard(arena, .{
        .board_path = board,
        .project_dir = project_dir,
        .name = design_name,
        .title = design_title,
        .dry_run = dry_run,
        .fold_channels = fold_channels,
        .fold_prefix = fold_prefix,
    }) catch |err| {
        exit.fatal("Import error: {}\n", .{err});
    };

    std.debug.print("{s}{d} parts: {d} family-mapped passives, {d} custom components\n", .{
        if (dry_run) "[dry-run] " else "",
        summary.parts,
        summary.family_mapped,
        summary.custom_parts,
    });
    std.debug.print("library: {d} files generated, {d} components already present\n", .{ summary.lib_written, summary.lib_existing });
    std.debug.print("design: {d} nets, {d} unconnected pads dropped\n", .{ summary.nets, summary.dropped_pins });
    if (summary.folded_channels > 0) {
        std.debug.print("folded: {d} channels x {d} parts -> module {s}", .{ summary.folded_channels, summary.folded_parts_each, summary.fold_module });
        if (summary.fold_skipped > 0) {
            std.debug.print(" ({d} deviating channel(s) left flat)", .{summary.fold_skipped});
        }
        std.debug.print("\n", .{});
    } else if (fold_channels) {
        std.debug.print("folded: no repeating channel structure found\n", .{});
    }
    std.debug.print("Wrote {s}\n", .{summary.design_path});
    std.debug.print("Next: netlisp build --project-dir {s} --push {s}\n", .{ project_dir, design_name });
}

/// `netlisp inspect-kicad <board.kicad_pcb> [--nets]` — read a physical KiCad
/// board and adjacent project rules into the normalized routing snapshot and
/// print deterministic JSON. This command never writes either source file.
pub fn cmdInspectKicad(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) InspectCommandError!void {
    var board_path: ?[]const u8 = null;
    var include_nets = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--nets")) {
            include_nets = true;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            board_path = arg;
        }
    }
    const board = board_path orelse {
        exit.fatal("Usage: netlisp inspect-kicad <board.kicad_pcb> [--nets]\n", .{});
    };
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const report = kicad_inspect.load(arena, board) catch |err| {
        exit.fatal("KiCad inspection error: {s}\n", .{@errorName(err)});
    };
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try kicad_inspect.writeJson(
        arena,
        &out.writer,
        report,
        if (include_nets) .nets else .summary,
    );
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(infra_fs.currentIo(), &stdout_buffer);
    try stdout_writer.interface.writeAll(out.written());
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

/// Virtually erase selected KiCad routes and run the fixed-placement router.
pub fn cmdRouteKicadReference(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) InspectCommandError!void {
    return kicad_route_command.run(allocator, args);
}

/// Import a routed KiCad board's placement, outline, and copper into the
/// design's layout sidecar as its single starred layout (board read-only).
pub fn cmdImportKicadLayout(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) InspectCommandError!void {
    return kicad_import_layout_command.run(allocator, args);
}

/// Recover layouts that survive only in `history/` or git and append them to
/// each block's layout sidecar as named rows.
pub fn cmdBackfillLayouts(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) InspectCommandError!void {
    return layout_backfill_command.run(allocator, args);
}

/// Upsert one named layout from another sidecar without text-merging the
/// monolithic target JSON document.
pub fn cmdMergeLayout(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) InspectCommandError!void {
    return layout_merge_command.run(allocator, args);
}

fn pushToServer(allocator: std.mem.Allocator, url: []const u8, body: []const u8) !void {
    const argv = [_][]const u8{
        "curl", "-s",                       "-X",            "POST",
        "-H",   "Content-Type: text/plain", "--data-binary", "@-",
        url,
    };
    _ = allocator;
    const io = infra_fs.currentIo();
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stderr = .inherit,
    });

    if (child.stdin) |stdin| {
        try stdin.writeStreamingAll(io, body);
        stdin.close(io);
        child.stdin = null;
    }

    const term = try child.wait(io);
    // A signal-terminated curl yields `.Signal`, not `.Exited`; read the
    // `Exited` field only after confirming the tag, otherwise the field access
    // is illegal behaviour (panic in Debug, UB in the ReleaseSmall prod build).
    if (!term.success()) return error.PushFailed;
}

// ── Tests ─────────────────────────────────────────────────────────

test "parseSyncSchArgs: flags in any order, lone positional is the design" {
    // spec: kicad_sch_push - The sync-kicad-sch CLI reads --project-dir, --dry-run and --force in any order and takes the lone positional as the design
    const flags_first = [_][]const u8{ project_dir_flag, "projects/designs", "--dry-run", "stm32n6" };
    const a = parseSyncSchArgs(&flags_first);
    try std.testing.expectEqualStrings("projects/designs", a.project_dir);
    try std.testing.expectEqualStrings("stm32n6", a.design);
    try std.testing.expect(a.dry_run and !a.force);

    // The design may also lead, and --force is independent of --dry-run. The
    // whole argv reaches here verbatim: the dispatcher must not re-slice it,
    // which is exactly how the project-dir flag once went missing.
    const name_first = [_][]const u8{ "stm32n6", "--force", project_dir_flag, "/p" };
    const b = parseSyncSchArgs(&name_first);
    try std.testing.expectEqualStrings("/p", b.project_dir);
    try std.testing.expectEqualStrings("stm32n6", b.design);
    try std.testing.expect(b.force and !b.dry_run);
}

test "parseBuildArgs: bare positional does not imply push" {
    // spec: commands - a lone positional design name builds without pushing
    const args = [_][]const u8{ project_dir_flag, "projects/designs", "stm32n6" };
    const got = parseBuildArgs(&args);
    try std.testing.expectEqualStrings("projects/designs", got.project_dir);
    try std.testing.expectEqualStrings("stm32n6", got.design.?);
    try std.testing.expect(!got.want_push);
    try std.testing.expect(got.output_dir == null);
}

test "parseBuildArgs: --push <name> requests a push of that design" {
    // spec: commands - --push with an explicit name pushes that design
    const args = [_][]const u8{ "--push", "stm32n6" };
    const got = parseBuildArgs(&args);
    try std.testing.expect(got.want_push);
    try std.testing.expectEqualStrings("stm32n6", got.design.?);
}

test "parseBuildArgs: bare --push pushes the positional design" {
    // spec: commands - a bare --push flag pushes the positional design
    const args = [_][]const u8{ "--push", project_dir_flag, "d", "adf5901" };
    const got = parseBuildArgs(&args);
    try std.testing.expect(got.want_push);
    try std.testing.expectEqualStrings("d", got.project_dir);
    try std.testing.expectEqualStrings("adf5901", got.design.?);
}

test "parseBuildArgs: --output-dir without --push does not push" {
    // spec: commands - --output-dir writes a file without a network push
    const args = [_][]const u8{ output_dir_flag, "/tmp/out", "lt3045" };
    const got = parseBuildArgs(&args);
    try std.testing.expect(!got.want_push);
    try std.testing.expectEqualStrings("/tmp/out", got.output_dir.?);
    try std.testing.expectEqualStrings("lt3045", got.design.?);
}

// spec: id_insert - a CLI export pins the ids its evaluation minted, so a second export of an untouched design reproduces the same identity
test "evalForExport pins minted ids into the design source" {
    // page_allocator: the evaluator never frees (AST slices reference source
    // buffers), so testing.allocator would flag those intentional leaks.
    const alloc = std.heap.page_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);

    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/cap.sexp",
        .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/0402.sexp",
        .data = "(component 0402 (footprint \"0402.kicad_mod\"))",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "src/exportid.sexp",
        .data =
        \\(import cap)
        \\(design-block "Export Id"
        \\  (instance "C1" (cap "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
        ,
    });

    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/exportid.sexp", .{project_dir});
    defer alloc.free(design_path);

    var eval1 = Evaluator.init(alloc, project_dir);
    defer eval1.deinit();
    const block1 = evalForExport(alloc, &eval1, project_dir, "exportid");
    try std.testing.expectEqual(@as(usize, 1), block1.instances.len);
    const id1 = try alloc.dupe(u8, block1.instances[0].id);
    defer alloc.free(id1);

    const after1 = try infra_fs.cwd().readFileAlloc(alloc, design_path, 1 << 20);
    defer alloc.free(after1);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, after1, "(id "));

    // A second export of the untouched design reads the pinned id back instead
    // of minting a fresh one, so every uuid it derives reproduces exactly.
    var eval2 = Evaluator.init(alloc, project_dir);
    defer eval2.deinit();
    const block2 = evalForExport(alloc, &eval2, project_dir, "exportid");
    try std.testing.expectEqualStrings(id1, block2.instances[0].id);

    const after2 = try infra_fs.cwd().readFileAlloc(alloc, design_path, 1 << 20);
    defer alloc.free(after2);
    try std.testing.expectEqualStrings(after1, after2);
}
