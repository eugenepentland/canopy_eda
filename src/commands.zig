const std = @import("std");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const emit = @import("emit.zig");
const export_kicad = @import("export_kicad.zig");
const export_kicad_pcb = @import("export_kicad_pcb.zig");
const bom = @import("bom.zig");
const render_block = @import("render_block.zig");
const id_insert = @import("id_insert.zig");

pub fn cmdRender(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var design_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else {
            design_file = args[i];
        }
    }

    const board_path = if (design_file) |f|
        std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ project_dir, f }) catch {
            std.debug.print("Out of memory\n", .{});
            std.process.exit(1);
        }
    else
        std.fmt.allocPrint(allocator, "{s}/src/board.sexp", .{project_dir}) catch {
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

    switch (result) {
        .design_block => |block| {
            const render_svg = @import("render_svg.zig");
            const svg = render_svg.renderSchematic(allocator, block) catch {
                std.debug.print("Render error\n", .{});
                std.process.exit(1);
            };
            defer allocator.free(svg);
            const file = std.fs.File.stdout();
            try file.writeAll(svg);
            try file.writeAll("\n");
        },
        else => {
            std.debug.print("Build did not produce a design block\n", .{});
            std.process.exit(1);
        },
    }
}

pub fn cmdBlockDiagram(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var design_file: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        } else {
            design_file = args[i];
        }
    }

    const board_path = if (design_file) |f|
        std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ project_dir, f }) catch {
            std.debug.print("Out of memory\n", .{});
            std.process.exit(1);
        }
    else
        std.fmt.allocPrint(allocator, "{s}/src/board.sexp", .{project_dir}) catch {
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

    switch (result) {
        .design_block => |block| {
            const svg = render_block.renderBlockDiagram(allocator, block) catch {
                std.debug.print("Render error\n", .{});
                std.process.exit(1);
            };
            defer allocator.free(svg);
            const file = std.fs.File.stdout();
            try file.writeAll(svg);
        },
        else => {
            std.debug.print("Build did not produce a design block\n", .{});
            std.process.exit(1);
        },
    }
}

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

    const board_path = if (push_name) |name|
        std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name }) catch {
            std.debug.print("Out of memory\n", .{});
            std.process.exit(1);
        }
    else
        std.fmt.allocPrint(allocator, "{s}/src/board.sexp", .{project_dir}) catch {
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
                const f = std.fs.cwd().createFile(out_path, .{}) catch {
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
        std.fs.cwd().makePath(dir) catch {};
    }

    const f = std.fs.cwd().createFile(out, .{}) catch |err| {
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
    bom.resolveIdentities(allocator, block2, ids_path, project_dir) catch {};

    const layout_path = try std.fmt.allocPrint(allocator, "{s}/src/{s}.layout", .{ project_dir, name });
    defer allocator.free(layout_path);

    const files = export_gerber.exportGerber(allocator, block2, project_dir, name, board_def, layout_path) catch |err| {
        std.debug.print("Gerber export error: {}\n", .{err});
        std.process.exit(1);
    };

    if (output_dir) |dir| {
        // Write individual files
        std.fs.cwd().makePath(dir) catch {};
        for (files) |f| {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, f.name });
            defer allocator.free(path);
            const file = std.fs.cwd().createFile(path, .{}) catch |err| {
                std.debug.print("Cannot write {s}: {}\n", .{ path, err });
                continue;
            };
            defer file.close();
            file.writeAll(f.data) catch {};
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
            std.fs.cwd().makePath(dir2) catch {};
        }
        const zf = std.fs.cwd().createFile(out_path, .{}) catch |err| {
            std.debug.print("Cannot write zip: {}\n", .{err});
            std.process.exit(1);
        };
        defer zf.close();
        zf.writeAll(zip) catch {};
        std.debug.print("Gerber export complete: {s}\n", .{out_path});
    }
}

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
        stdin.writeAll(body) catch {};
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

        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
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
