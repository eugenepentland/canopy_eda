const std = @import("std");
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
const PROJECT_DIR_FLAG = "--project-dir";
const OUTPUT_DIR_FLAG = "--output-dir";
const OUT_OF_MEMORY_MSG = "Out of memory\n";
const BUILD_ERROR_FMT = "Build error: {}\n";
const DIAG_ERROR_FMT = "{s}:{d}:{d}: error: {s}\n";
const BUILD_FAILED_ASSERTION_MSG = "Build failed: assertion violations\n";
const CANNOT_WRITE_FMT = "Cannot write {s}: {}\n";
const PASS_FMT = "PASS: {s}\n";
const WARN_FMT = "WARN: {s}\n";
const FAIL_FMT = "FAIL: {s}\n";
const IDENTITY_RESOLUTION_ERROR_FMT = "Identity resolution error: {}\n";
const WROTE_BYTES_FMT = "Wrote {s} ({d} bytes)\n";

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
            std.debug.print(DIAG_ERROR_FMT, .{ name, diag.span.line, diag.span.col, diag.message });
        }
        std.debug.print("error: {s} is neither a design nor a buildable module ({s})\n", .{ name, @errorName(err) });
        std.process.exit(1);
    };
    return switch (result) {
        .design_block => |b| b,
        else => {
            std.debug.print("error: {s} did not evaluate to a design\n", .{name});
            std.process.exit(1);
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
        if (std.mem.eql(u8, args[i], PROJECT_DIR_FLAG) and i + 1 < args.len) {
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
        std.debug.print("Usage: netlisp check [--project-dir <d>] [--severity error|warning|info] <design-name>\n", .{});
        std.process.exit(1);
    };

    const board_path = try paths.designSourcePath(allocator, project_dir, design);
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch |err| {
        std.debug.print("Evaluate error: {}\n", .{err});
        std.process.exit(1);
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
    var w_buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = w_buf.writer(allocator);
    var shown: usize = 0;
    for (violations) |v| {
        if (severity_filter) |sf| if (!std.mem.eql(u8, @tagName(v.severity), sf)) continue;
        shown += 1;
        try w.print("{s:<9} {s:<26} ", .{ @tagName(v.severity), @tagName(v.kind) });
        if (v.ref_des.len > 0) try w.print("{s} ", .{v.ref_des});
        if (v.net.len > 0) try w.print("[{s}] ", .{v.net});
        try w.print("— {s}\n", .{v.message});
    }
    try w.print("\n{d} violation(s)\n", .{shown});
    try stdout.writeAll(w_buf.items);
}

/// CLI entry point for `netlisp build`. Evaluates `<design>.sexp`, runs assertions,
/// resolves identities into the `.bom`, and either prints the resolved design
/// to stdout, writes it to `--output-dir`, or pushes it to a running server
/// via `--push` so the browser viewer updates live.
/// `netlisp build [--project-dir <d>] [--output-dir <out>] [--push] <design>` —
/// evaluate a design, persist any newly generated `(id …)`/`(ids …)` tokens
/// back into source, and optionally push the rebuilt scene to a running server.
pub fn cmdBuild(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    var project_dir: []const u8 = ".";
    var push_name: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var server_url: []const u8 = "http://localhost:7050";
    var positional_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], PROJECT_DIR_FLAG) and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--push") and i + 1 < args.len) {
            push_name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], OUTPUT_DIR_FLAG) and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--server") and i + 1 < args.len) {
            server_url = args[i + 1];
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            positional_name = args[i];
        }
    }

    if (push_name == null and positional_name != null) push_name = positional_name;

    const design = push_name orelse {
        std.debug.print("Usage: netlisp build [--project-dir <d>] [--output-dir <out>] [--push] <design-name>\n", .{});
        std.process.exit(1);
    };

    const board_path = paths.designSourcePath(allocator, project_dir, design) catch {
        std.debug.print(OUT_OF_MEMORY_MSG, .{});
        std.process.exit(1);
    };
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch |err| {
        // Render the stashed diagnostic (span + message + module call
        // chain) when one exists — the bare error code is the fallback.
        if (eval.last_error) |diag| {
            std.debug.print(DIAG_ERROR_FMT, .{ board_path, diag.span.line, diag.span.col, diag.message });
        }
        std.debug.print(BUILD_ERROR_FMT, .{err});
        std.process.exit(1);
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

    // Freeze grouped ref-des assignments into the `<design>.refdes.json` sidecar.
    // Set by `ids.applyGroupedRefDes` only when `(grouped-refdes)` changed the
    // assignment, so a no-op rebuild rewrites nothing. Build is the canonical
    // identity-freeze step (like the id write-back above); read-only paths skip it.
    if (eval.refdes_sidecar_json) |json| {
        if (eval.refdes_sidecar_path) |refdes_path| {
            const file = infra_fs.cwd().createFile(refdes_path, .{}) catch null;
            if (file) |f| {
                defer f.close();
                f.writeAll(json) catch |err| std.debug.print("refdes sidecar write error: {}\n", .{err});
            }
        }
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
            std.debug.print(PASS_FMT, .{assertion.message});
        } else if (assertion.is_warning) {
            std.debug.print(WARN_FMT, .{assertion.message});
        } else {
            std.debug.print(FAIL_FMT, .{assertion.message});
            has_failure = true;
        }
    }

    if (has_failure) {
        std.debug.print(BUILD_FAILED_ASSERTION_MSG, .{});
        std.process.exit(1);
    }

    {
        {
            const design_name = push_name orelse "board";
            const ids_path = paths.designSiblingPath(allocator, project_dir, design_name, ".bom") catch {
                std.debug.print(OUT_OF_MEMORY_MSG, .{});
                std.process.exit(1);
            };
            defer allocator.free(ids_path);
            bom.resolveIdentities(allocator, block, ids_path, project_dir) catch |err| {
                std.debug.print(IDENTITY_RESOLUTION_ERROR_FMT, .{err});
                std.process.exit(1);
            };

            const output = emit.emitResolved(allocator, block) catch {
                std.debug.print("Emit error\n", .{});
                std.process.exit(1);
            };
            defer allocator.free(output);

            if (output_dir) |dir| {
                const name = push_name orelse "design";
                const out_path = std.fmt.allocPrint(allocator, "{s}/{s}.sexp", .{ dir, name }) catch {
                    std.debug.print(OUT_OF_MEMORY_MSG, .{});
                    std.process.exit(1);
                };
                defer allocator.free(out_path);
                const f = infra_fs.cwd().createFile(out_path, .{}) catch {
                    std.debug.print("Failed to write {s}\n", .{out_path});
                    std.process.exit(1);
                };
                defer f.close();
                f.writeAll(output) catch {
                    std.debug.print("Write error\n", .{});
                    std.process.exit(1);
                };
                std.debug.print("Wrote {s}\n", .{out_path});
            }

            if (push_name) |name| {
                const url = std.fmt.allocPrint(allocator, "{s}/api/push/{s}", .{ server_url, name }) catch {
                    std.debug.print(OUT_OF_MEMORY_MSG, .{});
                    std.process.exit(1);
                };
                defer allocator.free(url);
                pushToServer(allocator, url, output) catch {
                    std.debug.print("Push failed\n", .{});
                    std.process.exit(1);
                };
                std.debug.print("Pushed to {s}\n", .{url});
            }

            if (push_name == null and output_dir == null) {
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
        if (std.mem.eql(u8, args[i], PROJECT_DIR_FLAG) and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], OUTPUT_DIR_FLAG) and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        } else {
            design_name = args[i];
        }
    }

    const name = design_name orelse {
        std.debug.print("Usage: netlisp export-kicad --project-dir <d> --output-dir <out> <design-name>\n", .{});
        std.process.exit(1);
    };
    const out = output_dir orelse {
        std.debug.print("Usage: netlisp export-kicad --project-dir <d> --output-dir <out> <design-name>\n", .{});
        std.process.exit(1);
    };

    const board_path = paths.designSourcePath(allocator, project_dir, name) catch {
        std.debug.print(OUT_OF_MEMORY_MSG, .{});
        std.process.exit(1);
    };
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch |err| {
        // Render the stashed diagnostic (span + message + module call
        // chain) when one exists — the bare error code is the fallback.
        if (eval.last_error) |diag| {
            std.debug.print(DIAG_ERROR_FMT, .{ board_path, diag.span.line, diag.span.col, diag.message });
        }
        std.debug.print(BUILD_ERROR_FMT, .{err});
        std.process.exit(1);
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
            std.debug.print(PASS_FMT, .{assertion.message});
        } else if (assertion.is_warning) {
            std.debug.print(WARN_FMT, .{assertion.message});
        } else {
            std.debug.print(FAIL_FMT, .{assertion.message});
            has_failure = true;
        }
    }

    if (has_failure) {
        std.debug.print(BUILD_FAILED_ASSERTION_MSG, .{});
        std.process.exit(1);
    }

    {
        {
            const ids_path = paths.designSiblingPath(allocator, project_dir, name, ".bom") catch {
                std.debug.print(OUT_OF_MEMORY_MSG, .{});
                std.process.exit(1);
            };
            defer allocator.free(ids_path);
            bom.resolveIdentities(allocator, block, ids_path, project_dir) catch |err| {
                std.debug.print(IDENTITY_RESOLUTION_ERROR_FMT, .{err});
                std.process.exit(1);
            };

            export_kicad.exportKicad(allocator, block, project_dir, out, name) catch |err| {
                std.debug.print("Export error: {}\n", .{err});
                std.process.exit(1);
            };
            std.debug.print("KiCad export complete: {s}/\n", .{out});
        }
    }
}

/// `netlisp export-review --project-dir <d> [--output-dir <out>] [--zip] <design>`
///
/// Produces the same package the web button does: `<name>-review.md`
/// + `<name>-bom.csv`. Default writes both files to `--output-dir`
/// (created if missing). With `--zip` writes a single `<name>-review.zip`
/// instead — useful for CI artifacts.
pub fn cmdExportReview(allocator: std.mem.Allocator, args: []const []const u8) CommandError!void {
    const review_md = @import("review_md.zig");
    const review_mod = @import("review.zig");
    const req_checks = @import("req_checks.zig");
    const bom_html = @import("serve/bom_html.zig");
    const fp_mod = @import("export_kicad_footprint.zig");

    var project_dir: []const u8 = ".";
    var output_dir: []const u8 = ".";
    var design_name: ?[]const u8 = null;
    var as_zip = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], PROJECT_DIR_FLAG) and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], OUTPUT_DIR_FLAG) and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--zip")) {
            as_zip = true;
        } else {
            design_name = args[i];
        }
    }

    const name = design_name orelse {
        std.debug.print("Usage: netlisp export-review --project-dir <d> [--output-dir <dir>] [--zip] <design>\n", .{});
        std.process.exit(1);
    };

    const board_path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch |err| {
        // Render the stashed diagnostic (span + message + module call
        // chain) when one exists — the bare error code is the fallback.
        if (eval.last_error) |diag| {
            std.debug.print(DIAG_ERROR_FMT, .{ board_path, diag.span.line, diag.span.col, diag.message });
        }
        std.debug.print(BUILD_ERROR_FMT, .{err});
        std.process.exit(1);
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            std.debug.print("Build did not produce a design-block\n", .{});
            std.process.exit(1);
        },
    };

    const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
    defer allocator.free(bom_path);
    try bom.resolveIdentities(allocator, @constCast(block), bom_path, project_dir);

    const violations = erc_mod.runErc(allocator, block, project_dir) catch &[_]erc_mod.Violation{};

    var check_results = req_checks.runChecks(allocator, &eval, block) catch
        std.StringHashMapUnmanaged([]req_checks.Result).empty;
    req_checks.applyVerifications(&check_results, block, block.instances);

    const doc = try review_mod.buildReview(allocator, name, block, eval.assertions.items, violations, &check_results, project_dir);

    const source = infra_fs.cwd().readFileAlloc(allocator, board_path, 16 * 1024 * 1024) catch &[_]u8{};

    const md = try review_md.renderToMarkdown(allocator, block, project_dir, name, doc, source, &check_results);

    var csv_buf: std.ArrayListUnmanaged(u8) = .empty;
    try bom_html.writeBomCsv(allocator, csv_buf.writer(allocator), block);

    try infra_fs.cwd().makePath(output_dir);
    const md_name = try std.fmt.allocPrint(allocator, "{s}-review.md", .{name});
    const csv_name = try std.fmt.allocPrint(allocator, "{s}-bom.csv", .{name});

    if (as_zip) {
        const entries = [_]fp_mod.ZipEntry{
            .{ .name = md_name, .data = md },
            .{ .name = csv_name, .data = csv_buf.items },
        };
        const zip = try fp_mod.buildZip(allocator, &entries);
        defer allocator.free(zip);
        const zip_path = try std.fmt.allocPrint(allocator, "{s}/{s}-review.zip", .{ output_dir, name });
        defer allocator.free(zip_path);
        const f = infra_fs.cwd().createFile(zip_path, .{}) catch |err| {
            std.debug.print(CANNOT_WRITE_FMT, .{ zip_path, err });
            std.process.exit(1);
        };
        defer f.close();
        try f.writeAll(zip);
        std.debug.print(WROTE_BYTES_FMT, .{ zip_path, zip.len });
    } else {
        const md_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, md_name });
        defer allocator.free(md_path);
        const csv_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, csv_name });
        defer allocator.free(csv_path);
        var fmd = infra_fs.cwd().createFile(md_path, .{}) catch |err| {
            std.debug.print(CANNOT_WRITE_FMT, .{ md_path, err });
            std.process.exit(1);
        };
        defer fmd.close();
        try fmd.writeAll(md);
        var fcsv = infra_fs.cwd().createFile(csv_path, .{}) catch |err| {
            std.debug.print(CANNOT_WRITE_FMT, .{ csv_path, err });
            std.process.exit(1);
        };
        defer fcsv.close();
        try fcsv.writeAll(csv_buf.items);
        std.debug.print(WROTE_BYTES_FMT, .{ md_path, md.len });
        std.debug.print(WROTE_BYTES_FMT, .{ csv_path, csv_buf.items.len });
    }
}

/// `netlisp import-kicad <board.kicad_pcb> [--project-dir <d>] [--name <n>]
/// [--title <t>] [--dry-run]` — migrate an existing KiCad board into the
/// project: family-map standard passives, generate library files for the
/// rest, and write `src/<name>.sexp` mirroring the board's netlist.
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
        if (std.mem.eql(u8, args[i], PROJECT_DIR_FLAG) and i + 1 < args.len) {
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
        std.debug.print("Usage: netlisp import-kicad <board.kicad_pcb> [--project-dir <d>] [--name <n>] [--title <t>] [--dry-run]\n", .{});
        std.process.exit(1);
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
        std.debug.print("Import error: {}\n", .{err});
        std.process.exit(1);
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
    if (term.Exited != 0) return error.PushFailed;
}
