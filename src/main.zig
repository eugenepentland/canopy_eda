const std = @import("std");
const parser = @import("sexpr/parser.zig");
const printer = @import("sexpr/printer.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const emit = @import("emit.zig");
const footprint_conv = @import("convert/footprint.zig");
const symbol_conv = @import("convert/symbol.zig");
const serve_mod = @import("serve.zig");

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
            std.debug.print("Usage: eda parse <file>\n", .{});
            std.process.exit(1);
        }
        try cmdParse(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "build")) {
        try cmdBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "render")) {
        try cmdRender(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "convert-footprint")) {
        if (args.len < 3) {
            std.debug.print("Usage: eda convert-footprint <file.kicad_mod>\n", .{});
            std.process.exit(1);
        }
        try cmdConvertFootprint(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "convert-symbol")) {
        if (args.len < 3) {
            std.debug.print("Usage: eda convert-symbol <file.kicad_sym> [--filter <name>]\n", .{});
            std.process.exit(1);
        }
        var filter: ?[]const u8 = null;
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
                filter = args[i + 1];
                i += 1;
            }
        }
        try cmdConvertSymbol(allocator, args[2], filter);
    } else if (std.mem.eql(u8, command, "serve")) {
        var project_dir: []const u8 = ".";
        var port: u16 = 7040;
        var si: usize = 2;
        while (si < args.len) : (si += 1) {
            if (std.mem.eql(u8, args[si], "--project-dir") and si + 1 < args.len) {
                project_dir = args[si + 1];
                si += 1;
            }
            if (std.mem.eql(u8, args[si], "--port") and si + 1 < args.len) {
                port = std.fmt.parseInt(u16, args[si + 1], 10) catch 7040;
                si += 1;
            }
        }
        try serve_mod.serve(allocator, port, project_dir);
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
        std.process.exit(1);
    }
}

fn cmdRender(allocator: std.mem.Allocator, args: []const []const u8) !void {
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

fn cmdParse(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const nodes = parser.parse(allocator, source) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        std.process.exit(1);
    };
    defer parser.freeNodes(allocator, nodes);

    const output = try printer.print(allocator, nodes);
    defer allocator.free(output);

    const file = std.fs.File.stdout();
    try file.writeAll(output);
    try file.writeAll("\n");
}

fn cmdBuild(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var push_name: ?[]const u8 = null;
    var output_dir: ?[]const u8 = null;
    var server_url: []const u8 = "http://localhost:9000";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
            project_dir = args[i + 1];
            i += 1;
        }
        if (std.mem.eql(u8, args[i], "--push") and i + 1 < args.len) {
            push_name = args[i + 1];
            i += 1;
        }
        if (std.mem.eql(u8, args[i], "--output-dir") and i + 1 < args.len) {
            output_dir = args[i + 1];
            i += 1;
        }
        if (std.mem.eql(u8, args[i], "--server") and i + 1 < args.len) {
            server_url = args[i + 1];
            i += 1;
        }
    }

    // If --push given, use it as the source file name
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

    var has_failure = false;
    for (eval.assertions.items) |assertion| {
        if (assertion.passed) {
            std.debug.print("PASS: {s}\n", .{assertion.message});
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
            const output = emit.emitResolved(allocator, block) catch {
                std.debug.print("Emit error\n", .{});
                std.process.exit(1);
            };
            defer allocator.free(output);

            // Write resolved file if --output-dir given
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

            // Push to server if --push given
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

            // If neither --push nor --output-dir, print to stdout
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

fn cmdConvertFootprint(allocator: std.mem.Allocator, path: []const u8) !void {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const output = footprint_conv.convertFootprint(allocator, source) catch |err| {
        std.debug.print("Convert error: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    const file = std.fs.File.stdout();
    try file.writeAll(output);
}

fn cmdConvertSymbol(allocator: std.mem.Allocator, path: []const u8, filter: ?[]const u8) !void {
    const source = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const output = symbol_conv.convertSymbol(allocator, source, filter) catch |err| {
        std.debug.print("Convert error: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    const file = std.fs.File.stdout();
    try file.writeAll(output);
}

fn cmdServe(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var project_dir: []const u8 = ".";
    var server_url: []const u8 = "http://localhost:9000";
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

    // Do initial build
    doServe(allocator, project_dir, server_url, slug) catch |err| {
        std.debug.print("Initial build failed: {}\n", .{err});
    };

    // Poll for changes every 1 second
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
        } else {
            std.debug.print("  FAIL: {s}\n", .{assertion.message});
        }
    }

    switch (result) {
        .design_block => |block| {
            const output = try emit.emitResolved(allocator, block);
            defer allocator.free(output);

            // POST resolved .sexp to Gleam server
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
        "curl", "-s", "-X", "POST",
        "-H",  "Content-Type: text/plain",
        "--data-binary", "@-",
        url,
    };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    // Write body to stdin, then close it so curl sends the request
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

    // Check src/ and lib/ directories
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

fn sanitizeFilename(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        buf[i] = switch (c) {
            ' ', '/', '\\' => '-',
            'A'...'Z' => c + 32,
            else => c,
        };
    }
    return buf;
}

fn printUsage() !void {
    const file = std.fs.File.stdout();
    try file.writeAll(
        \\eda — Electronic Design Automation CLI
        \\
        \\Usage:
        \\  eda parse <file>                   Parse and pretty-print an S-expression file
        \\  eda build [--project-dir <d>]       Evaluate and emit resolved design
        \\  eda serve [--project-dir <d>] [--port <n>]  Start web server (default port 7040)
        \\  eda convert-footprint <file>        Convert KiCad .kicad_mod to .sexp
        \\  eda convert-symbol <file> [--filter <name>]  Convert KiCad .kicad_sym to .sexp
        \\  eda help                            Show this help
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
    _ = @import("eval/builtins.zig");
    _ = @import("eval/fmt.zig");
    _ = @import("eval/evaluator.zig");
    _ = @import("emit.zig");
    _ = @import("convert/footprint.zig");
    _ = @import("convert/symbol.zig");
    _ = @import("serve.zig");
    _ = @import("render_svg.zig");
}
