const std = @import("std");
const parser = @import("sexpr/parser.zig");
const printer = @import("sexpr/printer.zig");
const footprint_conv = @import("convert/footprint.zig");
const symbol_conv = @import("convert/symbol.zig");
const alt_functions = @import("convert/alt_functions.zig");
const serve_mod = @import("serve.zig");
const commands = @import("commands.zig");
const plugin_tokens = @import("serve/plugin_tokens.zig");

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
        try commands.cmdBuild(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "check")) {
        try commands.cmdCheck(allocator, args[2..]);
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
    } else if (std.mem.eql(u8, command, "convert-package")) {
        if (args.len < 4) {
            std.debug.print("Usage: eda convert-package <file.kicad_sym> <file.kicad_mod> [--name <n>] [--filter <f>]\n", .{});
            std.process.exit(1);
        }
        var pkg_name: ?[]const u8 = null;
        var filter: ?[]const u8 = null;
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--name") and i + 1 < args.len) {
                pkg_name = args[i + 1];
                i += 1;
            }
            if (std.mem.eql(u8, args[i], "--filter") and i + 1 < args.len) {
                filter = args[i + 1];
                i += 1;
            }
        }
        try cmdConvertPackage(allocator, args[2], args[3], pkg_name orelse "package", filter);
    } else if (std.mem.eql(u8, command, "convert-pinout")) {
        if (args.len < 3) {
            std.debug.print("Usage: eda convert-pinout <file.kicad_sym> [--filter <name>]\n", .{});
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
        try cmdConvertPinout(allocator, args[2], filter);
    } else if (std.mem.eql(u8, command, "merge-alt-functions")) {
        if (args.len < 4) {
            std.debug.print("Usage: eda merge-alt-functions <pinout.sexp> <alts.csv|alts.xml> [--write]\n", .{});
            std.process.exit(1);
        }
        var write_back = false;
        var i: usize = 4;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--write")) write_back = true;
        }
        try cmdMergeAltFunctions(allocator, args[2], args[3], write_back);
    } else if (std.mem.eql(u8, command, "export-kicad")) {
        try commands.cmdExportKicad(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "export-pcb")) {
        try commands.cmdExportPcb(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "export-gerber")) {
        try commands.cmdExportGerber(allocator, args[2..]);
    } else if (std.mem.eql(u8, command, "serve")) {
        var project_dir: []const u8 = ".";
        var port: u16 = 7050;
        var si: usize = 2;
        while (si < args.len) : (si += 1) {
            if (std.mem.eql(u8, args[si], "--project-dir") and si + 1 < args.len) {
                project_dir = args[si + 1];
                si += 1;
            }
            if (std.mem.eql(u8, args[si], "--port") and si + 1 < args.len) {
                port = std.fmt.parseInt(u16, args[si + 1], 10) catch 7050;
                si += 1;
            }
        }
        try serve_mod.serve(allocator, port, project_dir);
    } else if (std.mem.eql(u8, command, "mint-plugin-token")) {
        var project_dir: []const u8 = ".";
        var label: []const u8 = "plugin";
        var mi: usize = 2;
        while (mi < args.len) : (mi += 1) {
            if (std.mem.eql(u8, args[mi], "--project-dir") and mi + 1 < args.len) {
                project_dir = args[mi + 1];
                mi += 1;
            } else if (std.mem.eql(u8, args[mi], "--label") and mi + 1 < args.len) {
                label = args[mi + 1];
                mi += 1;
            }
        }
        const raw = try plugin_tokens.mint(allocator, project_dir, label);
        defer allocator.free(raw);
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(raw);
        try stdout.writeAll("\n");
        try stdout.writeAll("Save this token — it will not be shown again.\n");
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage();
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        try printUsage();
        std.process.exit(1);
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

fn cmdConvertPackage(allocator: std.mem.Allocator, sym_path: []const u8, fp_path: []const u8, name: []const u8, filter: ?[]const u8) !void {
    const sym_source = std.fs.cwd().readFileAlloc(allocator, sym_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ sym_path, err });
        std.process.exit(1);
    };
    defer allocator.free(sym_source);
    const fp_source = std.fs.cwd().readFileAlloc(allocator, fp_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ fp_path, err });
        std.process.exit(1);
    };
    defer allocator.free(fp_source);

    const output = symbol_conv.generatePackage(allocator, sym_source, fp_source, name, filter) catch |err| {
        std.debug.print("Convert error: {}\n", .{err});
        std.process.exit(1);
    };
    defer allocator.free(output);

    const file = std.fs.File.stdout();
    try file.writeAll(output);
}

fn cmdMergeAltFunctions(allocator: std.mem.Allocator, pinout_path: []const u8, src_path: []const u8, write_back: bool) !void {
    const pinout_src = std.fs.cwd().readFileAlloc(allocator, pinout_path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ pinout_path, err });
        std.process.exit(1);
    };
    defer allocator.free(pinout_src);
    const alt_src = std.fs.cwd().readFileAlloc(allocator, src_path, 20 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ src_path, err });
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
        std.fs.cwd().writeFile(.{ .sub_path = pinout_path, .data = output }) catch |err| {
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
    const source = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch |err| {
        std.debug.print("Error reading {s}: {}\n", .{ path, err });
        std.process.exit(1);
    };
    defer allocator.free(source);

    const output = symbol_conv.generatePinout(allocator, source, filter) catch |err| {
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

fn printUsage() !void {
    const file = std.fs.File.stdout();
    try file.writeAll(
        \\eda — Electronic Design Automation CLI
        \\
        \\Usage:
        \\  eda parse <file>                   Parse and pretty-print an S-expression file
        \\  eda build [--project-dir <d>]       Evaluate and emit resolved design
        \\  eda check [--project-dir <d>] [--severity <s>] <name>  Run ERC on a design
        \\  eda serve [--project-dir <d>] [--port <n>]  Start web server (default port 7050)
        \\  eda mint-plugin-token [--project-dir <d>] [--label <l>]  Mint a bearer token for the KiCad plugin
        \\  eda export-kicad --project-dir <d> --output-dir <out> <name>  Export KiCad netlist + footprints
        \\  eda export-pcb --project-dir <d> [--output <file>] <name>   Export .kicad_pcb (native PCB)
        \\  eda convert-footprint <file>        Convert KiCad .kicad_mod to .sexp
        \\  eda convert-symbol <file> [--filter <name>]  Convert KiCad .kicad_sym to .sexp
        \\  eda convert-pinout <file> [--filter <name>]  Generate pinout from KiCad .kicad_sym
        \\  eda merge-alt-functions <pinout.sexp> <alts.csv|alts.xml> [--write]  Merge alt functions (CSV or ST open-pin-data XML)
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
    _ = @import("convert/alt_functions.zig");
    _ = @import("export_kicad.zig");
    _ = @import("export_kicad_pcb.zig");
    _ = @import("serve.zig");
    _ = @import("render_json.zig");
}
