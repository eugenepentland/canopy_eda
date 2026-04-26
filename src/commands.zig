const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const emit = @import("emit.zig");
const export_kicad = @import("export_kicad.zig");
const export_kicad_pcb = @import("export_kicad_pcb.zig");
const bom = @import("bom.zig");
const id_insert = @import("id_insert.zig");
const erc_mod = @import("erc.zig");
const env_mod = @import("eval/env.zig");

/// `eda check <name>` — run ERC on a design and print violations.
pub fn cmdCheck(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var positional_name: ?[]const u8 = null;
    var severity_filter: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
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
        std.debug.print("Usage: eda check [--project-dir <d>] [--severity error|warning|info] <design-name>\n", .{});
        std.process.exit(1);
    };

    const board_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, design });
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch |err| {
        std.debug.print("Evaluate error: {}\n", .{err});
        std.process.exit(1);
    };
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| @as(*const env_mod.DesignBlock, b.design),
        else => {
            std.debug.print("error: {s} did not evaluate to a design\n", .{design});
            std.process.exit(1);
        },
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

/// CLI entry point for `eda build`. Evaluates `<design>.sexp`, runs assertions,
/// resolves identities into the `.bom`, and either prints the resolved design
/// to stdout, writes it to `--output-dir`, or pushes it to a running server
/// via `--push` so the browser viewer updates live.
pub fn cmdBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var push_name: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var server_url: []const u8 = "http://localhost:7050";
    var positional_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--push") and i + 1 < args.len) {
            push_name = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output-dir") and i + 1 < args.len) {
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
        std.debug.print("Usage: eda build [--project-dir <d>] [--output-dir <out>] [--push] <design-name>\n", .{});
        std.process.exit(1);
    };

    const board_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, design }) catch {
        std.debug.print("Out of memory\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch |err| {
        std.debug.print("Build error: {}\n", .{err});
        std.process.exit(1);
    };

    if (eval.pending_ids.items.len > 0) {
        id_insert.insertPendingIds(allocator, board_path, eval.pending_ids.items) catch |err| {
            std.debug.print("ID insertion error: {}\n", .{err});
        };
    }

    var has_failure = false;
    for (eval.assertions.items) |assertion| {
        if (assertion.passed) {
            std.debug.print("PASS: {s}\n", .{assertion.message});
        } else if (assertion.is_warning) {
            std.debug.print("WARN: {s}\n", .{assertion.message});
        } else {
            std.debug.print("FAIL: {s}\n", .{assertion.message});
            has_failure = true;
        }
    }

    if (has_failure) {
        std.debug.print("Build failed: assertion violations\n", .{});
        std.process.exit(1);
    }

    switch (result) {
        .design_block => |block| {
            const design_name = push_name orelse "board";
            const ids_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, design_name }) catch {
                std.debug.print("Out of memory\n", .{});
                std.process.exit(1);
            };
            defer allocator.free(ids_path);
            bom.resolveIdentities(allocator, block, ids_path, project_dir) catch |err| {
                std.debug.print("Identity resolution error: {}\n", .{err});
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
                    std.debug.print("Out of memory\n", .{});
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
                    std.debug.print("Out of memory\n", .{});
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
        },
        else => {
            std.debug.print("Build did not produce a design block\n", .{});
            std.process.exit(1);
        },
    }
}

/// CLI entry point for `eda export-kicad`. Builds the design, resolves the
/// BOM, and writes a KiCad-compatible netlist plus per-footprint
/// `.kicad_mod` files (and any associated STEP models) into `--output-dir`.
pub fn cmdExportKicad(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var output_dir: ?[]const u8 = null;
    var design_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output-dir") and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        } else {
            design_name = args[i];
        }
    }

    const name = design_name orelse {
        std.debug.print("Usage: eda export-kicad --project-dir <d> --output-dir <out> <design-name>\n", .{});
        std.process.exit(1);
    };
    const out = output_dir orelse {
        std.debug.print("Usage: eda export-kicad --project-dir <d> --output-dir <out> <design-name>\n", .{});
        std.process.exit(1);
    };

    const board_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name }) catch {
        std.debug.print("Out of memory\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch |err| {
        std.debug.print("Build error: {}\n", .{err});
        std.process.exit(1);
    };

    var has_failure = false;
    for (eval.assertions.items) |assertion| {
        if (assertion.passed) {
            std.debug.print("PASS: {s}\n", .{assertion.message});
        } else if (assertion.is_warning) {
            std.debug.print("WARN: {s}\n", .{assertion.message});
        } else {
            std.debug.print("FAIL: {s}\n", .{assertion.message});
            has_failure = true;
        }
    }

    if (has_failure) {
        std.debug.print("Build failed: assertion violations\n", .{});
        std.process.exit(1);
    }

    switch (result) {
        .design_block => |block| {
            const ids_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, name }) catch {
                std.debug.print("Out of memory\n", .{});
                std.process.exit(1);
            };
            defer allocator.free(ids_path);
            bom.resolveIdentities(allocator, block, ids_path, project_dir) catch |err| {
                std.debug.print("Identity resolution error: {}\n", .{err});
                std.process.exit(1);
            };

            export_kicad.exportKicad(allocator, block, project_dir, out, name) catch |err| {
                std.debug.print("Export error: {}\n", .{err});
                std.process.exit(1);
            };
            std.debug.print("KiCad export complete: {s}/\n", .{out});
        },
        else => {
            std.debug.print("Build did not produce a design block\n", .{});
            std.process.exit(1);
        },
    }
}

/// CLI entry point for `eda export-pcb`. Builds the design and emits a native
/// `.kicad_pcb` file, applying any stored `.layout` placements/traces and the
/// optional `(board …)` outline so the result opens directly in KiCad's PCB
/// editor.
pub fn cmdExportPcb(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var output_path: ?[]const u8 = null;
    var design_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            output_path = args[i + 1];
            i += 1;
        } else {
            design_name = args[i];
        }
    }

    const name = design_name orelse {
        std.debug.print("Usage: eda export-pcb --project-dir <d> --output <file.kicad_pcb> <design-name>\n", .{});
        std.process.exit(1);
    };

    const board_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name }) catch {
        std.debug.print("Out of memory\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch |err| {
        std.debug.print("Build error: {}\n", .{err});
        std.process.exit(1);
    };

    var has_failure = false;
    for (eval.assertions.items) |assertion| {
        if (assertion.passed) {
            std.debug.print("PASS: {s}\n", .{assertion.message});
        } else if (assertion.is_warning) {
            std.debug.print("WARN: {s}\n", .{assertion.message});
        } else {
            std.debug.print("FAIL: {s}\n", .{assertion.message});
            has_failure = true;
        }
    }

    if (has_failure) {
        std.debug.print("Build failed: assertion violations\n", .{});
        std.process.exit(1);
    }

    // Extract design block and optional board params
    const env = @import("eval/env.zig");
    var block: *env.DesignBlock = undefined;
    var board_def: ?*env.Board = null;
    switch (result) {
        .design_block => |db| block = db,
        .board => |b| {
            block = b.design;
            board_def = b;
        },
        else => {
            std.debug.print("Build did not produce a design-block or board\n", .{});
            std.process.exit(1);
        },
    }

    const ids_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, name }) catch {
        std.debug.print("Out of memory\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(ids_path);
    bom.resolveIdentities(allocator, block, ids_path, project_dir) catch |err| {
        std.debug.print("Identity resolution error: {}\n", .{err});
        std.process.exit(1);
    };

    // Determine output path
    const out = output_path orelse blk: {
        break :blk std.fmt.allocPrint(allocator, "{s}/out/{s}.kicad_pcb", .{ project_dir, name }) catch {
            std.debug.print("Out of memory\n", .{});
            std.process.exit(1);
        };
    };

    // Layout path for native placement data
    const layout_path = std.fmt.allocPrint(allocator, "{s}/src/{s}.layout", .{ project_dir, name }) catch null;

    // Use existing PCB for placement preservation if it exists
    const pcb_content = export_kicad_pcb.exportPcb(allocator, block, project_dir, name, out, board_def, layout_path) catch |err| {
        std.debug.print("PCB export error: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(pcb_content);

    // Ensure output directory exists
    if (std.fs.path.dirname(out)) |dir| {
        try infra_fs.cwd().makePath(dir);
    }

    const f = infra_fs.cwd().createFile(out, .{}) catch |err| {
        std.debug.print("Cannot write {s}: {}\n", .{ out, err });
        std.process.exit(1);
    };
    defer f.close();
    f.writeAll(pcb_content) catch |err| {
        std.debug.print("Write error: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("PCB export complete: {s}\n", .{out});
}

/// CLI entry point for `eda export-gerber`. Builds the design, applies the
/// stored `.layout` placements, and emits a Gerber/Excellon manufacturing
/// set as files (`--output-dir`) or as a single zip on disk when no
/// directory is given.
pub fn cmdExportGerber(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const export_gerber = @import("export_gerber.zig");
    const fp_mod = @import("export_kicad_footprint.zig");

    var project_dir: []const u8 = ".";
    var output_dir: ?[]const u8 = null;
    var design_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output-dir") and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        } else {
            design_name = args[i];
        }
    }

    const name = design_name orelse {
        std.debug.print("Usage: eda export-gerber --project-dir <d> --output-dir <dir> <design-name>\n", .{});
        std.process.exit(1);
    };

    const board_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch |err| {
        std.debug.print("Build error: {}\n", .{err});
        std.process.exit(1);
    };

    const env = @import("eval/env.zig");
    var block2: *env.DesignBlock = undefined;
    var board_def: ?*env.Board = null;
    switch (result) {
        .design_block => |db| block2 = db,
        .board => |b| {
            block2 = b.design;
            board_def = b;
        },
        else => {
            std.debug.print("Build did not produce a design-block or board\n", .{});
            std.process.exit(1);
        },
    }

    const ids_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, name });
    defer allocator.free(ids_path);
    try bom.resolveIdentities(allocator, block2, ids_path, project_dir);

    const layout_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.layout", .{ project_dir, name });
    defer allocator.free(layout_path);

    const files = export_gerber.exportGerber(allocator, block2, project_dir, name, board_def, layout_path) catch |err| {
        std.debug.print("Gerber export error: {}\n", .{err});
        std.process.exit(1);
    };

    if (output_dir) |dir| {
        // Write individual files
        try infra_fs.cwd().makePath(dir);
        for (files) |f| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, f.name });
            defer allocator.free(path);
            const file = infra_fs.cwd().createFile(path, .{}) catch |err| {
                std.debug.print("Cannot write {s}: {}\n", .{ path, err });
                continue;
            };
            defer file.close();
            try file.writeAll(f.data);
            std.debug.print("  {s}\n", .{f.name});
        }
        std.debug.print("Gerber export complete: {d} files in {s}\n", .{ files.len, dir });
    } else {
        // Write as zip to stdout
        var zip_entries: std.ArrayListUnmanaged(fp_mod.ZipEntry) = .empty;
        defer zip_entries.deinit(allocator);
        for (files) |f| {
            try zip_entries.append(allocator, .{ .name = f.name, .data = f.data });
        }
        const zip = try fp_mod.buildZip(allocator, zip_entries.items);
        defer allocator.free(zip);
        const out_path = try std.fmt.allocPrint(allocator, "{s}/out/{s}-gerber.zip", .{ project_dir, name });
        defer allocator.free(out_path);
        if (std.fs.path.dirname(out_path)) |dir2| {
            try infra_fs.cwd().makePath(dir2);
        }
        const zf = infra_fs.cwd().createFile(out_path, .{}) catch |err| {
            std.debug.print("Cannot write zip: {}\n", .{err});
            std.process.exit(1);
        };
        defer zf.close();
        try zf.writeAll(zip);
        std.debug.print("Gerber export complete: {s}\n", .{out_path});
    }
}

/// `eda export-review --project-dir <d> [--output-dir <out>] [--zip] <design>`
///
/// Produces the same package the web button does: `<name>-review.md`
/// + `<name>-bom.csv`. Default writes both files to `--output-dir`
/// (created if missing). With `--zip` writes a single `<name>-review.zip`
/// instead — useful for CI artifacts.
pub fn cmdExportReview(allocator: std.mem.Allocator, args: []const []const u8) !void {
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
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--output-dir") and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--zip")) {
            as_zip = true;
        } else {
            design_name = args[i];
        }
    }

    const name = design_name orelse {
        std.debug.print("Usage: eda export-review --project-dir <d> [--output-dir <dir>] [--zip] <design>\n", .{});
        std.process.exit(1);
    };

    const board_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch |err| {
        std.debug.print("Build error: {}\n", .{err});
        std.process.exit(1);
    };
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| @as(*const env_mod.DesignBlock, b.design),
        else => {
            std.debug.print("Build did not produce a design-block\n", .{});
            std.process.exit(1);
        },
    };

    const bom_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.bom", .{ project_dir, name });
    defer allocator.free(bom_path);
    try bom.resolveIdentities(allocator, @constCast(block), bom_path, project_dir);

    const violations = erc_mod.runErc(allocator, block, project_dir) catch &[_]erc_mod.Violation{};

    var check_results = req_checks.runChecks(allocator, &eval, block) catch
        std.StringHashMapUnmanaged([]req_checks.Result).empty;
    req_checks.applyVerifications(&check_results, block, block.instances);

    const doc = try review_mod.buildReview(allocator, name, block, eval.assertions.items, violations, &check_results);

    const source = infra_fs.cwd().readFileAlloc(allocator, board_path, 16 * 1024 * 1024) catch &[_]u8{};

    const md = try review_md.renderToMarkdown(allocator, block, project_dir, name, doc, source, &check_results);

    var csv_buf: std.ArrayListUnmanaged(u8) = .empty;
    try bom_html.writeBomCsv(csv_buf.writer(allocator), block);

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
            std.debug.print("Cannot write {s}: {}\n", .{ zip_path, err });
            std.process.exit(1);
        };
        defer f.close();
        try f.writeAll(zip);
        std.debug.print("Wrote {s} ({d} bytes)\n", .{ zip_path, zip.len });
    } else {
        const md_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, md_name });
        defer allocator.free(md_path);
        const csv_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, csv_name });
        defer allocator.free(csv_path);
        var fmd = infra_fs.cwd().createFile(md_path, .{}) catch |err| {
            std.debug.print("Cannot write {s}: {}\n", .{ md_path, err });
            std.process.exit(1);
        };
        defer fmd.close();
        try fmd.writeAll(md);
        var fcsv = infra_fs.cwd().createFile(csv_path, .{}) catch |err| {
            std.debug.print("Cannot write {s}: {}\n", .{ csv_path, err });
            std.process.exit(1);
        };
        defer fcsv.close();
        try fcsv.writeAll(csv_buf.items);
        std.debug.print("Wrote {s} ({d} bytes)\n", .{ md_path, md.len });
        std.debug.print("Wrote {s} ({d} bytes)\n", .{ csv_path, csv_buf.items.len });
    }
}

/// CLI entry point for `eda serve` in watcher mode. Polls source files under
/// the project's `src/`, `lib/components/`, and `lib/modules/` directories
/// and re-pushes the rebuilt design to a separately-running web server
/// whenever it sees a change.
pub fn cmdServe(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var server_url: []const u8 = "http://localhost:7050";
    var slug: []const u8 = "live";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        }
        if (std.mem.eql(u8, args[i], "--server") and i + 1 < args.len) {
            server_url = args[i + 1];
            i += 1;
        }
        if (std.mem.eql(u8, args[i], "--name") and i + 1 < args.len) {
            slug = args[i + 1];
            i += 1;
        }
    }

    std.debug.print("eda serve: watching {s}, pushing to {s}/api/push/{s}\n", .{ project_dir, server_url, slug });

    doServe(allocator, project_dir, server_url, slug) catch |err| {
        std.debug.print("Initial build failed: {}\n", .{err});
    };

    var last_mtime: i128 = 0;
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_s);

        const mtime = getNewestMtime(allocator, project_dir) catch continue;
        if (mtime > last_mtime) {
            last_mtime = mtime;
            std.debug.print("Change detected, rebuilding...\n", .{});
            doServe(allocator, project_dir, server_url, slug) catch |err| {
                std.debug.print("Build failed: {}\n", .{err});
                continue;
            };
            std.debug.print("Build complete.\n", .{});
        }
    }
}

fn doServe(allocator: std.mem.Allocator, project_dir: []const u8, server_url: []const u8, slug: []const u8) !void {
    const board_path = try std.fmt.allocPrint(allocator, "{s}/src/board.sexp", .{project_dir});
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = try eval.evalFile(board_path);

    for (eval.assertions.items) |assertion| {
        if (assertion.passed) {
            std.debug.print("  PASS: {s}\n", .{assertion.message});
        } else if (assertion.is_warning) {
            std.debug.print("  WARN: {s}\n", .{assertion.message});
        } else {
            std.debug.print("  FAIL: {s}\n", .{assertion.message});
        }
    }

    switch (result) {
        .design_block => |block| {
            const output = try emit.emitResolved(allocator, block);
            defer allocator.free(output);

            const url = try std.fmt.allocPrint(allocator, "{s}/api/push/{s}", .{ server_url, slug });
            defer allocator.free(url);

            pushToServer(allocator, url, output) catch |err| {
                std.debug.print("  Push failed: {}\n", .{err});
                return;
            };
            std.debug.print("  Pushed {s} to {s}\n", .{ block.name, url });
        },
        else => return error.InvalidFormat,
    }
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

fn getNewestMtime(allocator: std.mem.Allocator, project_dir: []const u8) !i128 {
    var newest: i128 = 0;

    const dirs = [_][]const u8{ "src", "lib/components", "lib/modules" };
    for (dirs) |sub| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, sub });
        defer allocator.free(dir_path);

        var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
                const stat = dir.statFile(entry.name) catch continue;
                if (stat.mtime > newest) newest = stat.mtime;
            }
        }
    }
    return newest;
}
