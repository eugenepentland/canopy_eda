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
const bom = @import("bom.zig");
const id_insert = @import("id_insert.zig");
const erc_mod = @import("erc.zig");
const env_mod = @import("eval/env.zig");
const eval_modules = @import("eval/modules.zig");
const import_kicad = @import("import_kicad.zig");

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

/// Error set for the CLI command handlers in this file. Wide on purpose:
/// each `cmd*` orchestrates the evaluator (`EvalError`), file IO, network
/// pushes, and writers, so we union the relevant std error sets up front
/// rather than computing a per-command set.
pub const CommandError = std.mem.Allocator.Error ||
    EvalError ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    std.fs.Dir.MakeError ||
    std.fs.Dir.RenameError ||
    std.posix.GetRandomError ||
    error{
        FileTooBig,
        StreamTooLong,
        EndOfStream,
        InvalidName,
        InvalidArgument,
        WriteFailed,
        Canceled,
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

/// `netlisp check <name>` — run ERC on a design and print violations.
pub fn cmdCheck(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    var project_dir: []const u8 = ".";
    var positional_name: ?[]const u8 = null;
    var severity_filter: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--severity") and i + 1 < args.len) {
            severity_filter = args[i + 1];
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            positional_name = args[i];
        }
    }
    const design = positional_name orelse {
        exit.fatal("Usage: netlisp check [--project-dir <d>] [--severity error|warning|info] <design-name>\n", .{});
    };

    const board_path = try paths.designSourcePath(allocator, project_dir, design);
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch |err| {
        // Render the stashed diagnostic (span + message, incl. a parse error's
        // file:line:col) when one exists — the bare error code is the fallback.
        if (eval.last_error) |diag| {
            std.debug.print(diag_error_fmt, .{ board_path, diag.span.line, diag.span.col, diag.message });
        }
        exit.fatal("Evaluate error: {}\n", .{err});
    };
    const block = switch (result) {
        .design_block => |b| b,
        // Not a top-level design — try resolving `design` as a bare
        // `lib/modules/<name>.sexp` module, instantiated standalone via its
        // parameter defaults (defaults-first). `evalFile` already ran the
        // `(defmodule …)` (→ .nil) and registered it, so this just calls it.
        else => moduleBlock(&eval, design),
    };

    const violations = try erc_mod.runErc(allocator, block, project_dir);
    const stdout = std.fs.File.stdout();
    var w_buf: std.ArrayList(u8) = .empty;
    const w = w_buf.writer(allocator);
    var shown: usize = 0;
    var errors: usize = 0;
    for (violations) |v| {
        if (severity_filter) |sf| if (!std.mem.eql(u8, @tagName(v.severity), sf)) continue;
        shown += 1;
        if (v.severity == .@"error") errors += 1;
        try w.print("{s:<9} {s:<26} ", .{ @tagName(v.severity), @tagName(v.kind) });
        if (v.ref_des.len > 0) try w.print("{s} ", .{v.ref_des});
        if (v.net.len > 0) try w.print("[{s}] ", .{v.net});
        try w.print("— {s}\n", .{v.message});
    }
    try w.print("\n{d} violation(s)\n", .{shown});
    try stdout.writeAll(w_buf.items);

    // Gate: `netlisp check` exits non-zero when any error-severity violation
    // survives the (optional) `--severity` filter, so CI / agents can rely on
    // the exit code. Warnings and info alone still exit 0.
    if (errors > 0) exit.failure();
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

    if (eval.pending_ids.items.len > 0 or eval.pending_child_ids.items.len > 0) {
        id_insert.insertPendingIds(allocator, board_path, eval.pending_ids.items, eval.pending_child_ids.items) catch |err| {
            std.debug.print("ID insertion error: {}\n", .{err});
        };
    }

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
                const file = std.fs.File.stdout();
                try file.writeAll(output);
                try file.writeAll("\n");
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
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], project_dir_flag) and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], output_dir_flag) and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            design_name = args[i];
        }
    }

    const name = design_name orelse {
        exit.fatal("Usage: netlisp export-kicad --project-dir <d> --output-dir <out> <design-name>\n", .{});
    };
    const out = output_dir orelse {
        exit.fatal("Usage: netlisp export-kicad --project-dir <d> --output-dir <out> <design-name>\n", .{});
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

            export_kicad.exportKicad(allocator, block, project_dir, out, name) catch |err| {
                exit.fatal("Export error: {}\n", .{err});
            };
            std.debug.print("KiCad export complete: {s}/\n", .{out});
        }
    }
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

fn pushToServer(allocator: std.mem.Allocator, url: []const u8, body: []const u8) !void {
    const argv = [_][]const u8{
        "curl", "-s",                       "-X",            "POST",
        "-H",   "Content-Type: text/plain", "--data-binary", "@-",
        url,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    if (child.stdin) |*stdin| {
        try stdin.writeAll(body);
        stdin.close();
        child.stdin = null;
    }

    const term = try child.wait();
    // A signal-terminated curl yields `.Signal`, not `.Exited`; read the
    // `Exited` field only after confirming the tag, otherwise the field access
    // is illegal behaviour (panic in Debug, UB in the ReleaseSmall prod build).
    if (term != .Exited or term.Exited != 0) return error.PushFailed;
}

// ── Tests ─────────────────────────────────────────────────────────

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
